#!/usr/bin/env bats
# Tests for multi-hop / cascade helpers in awg_common.sh:
#   _validate_iface_name, _extract_upstream_field, render_upstream_config
# and for AWG_ROLE=entry branching inside render_server_config.

# `run !` flag form requires bats-core 1.5.0+.
bats_require_minimum_version 1.5.0

load test_helper

# Helper: write a minimal valid "upstream" client conf (as produced by
# manage add on the exit node) into a given path.
create_upstream_conf() {
    local path="$1"
    local header_key="${2:-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=}"
    local rekey_timeout="${3:-5-15}"
    local s4="${4:-16}"
    cat > "$path" << UPSTREAM
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 2001:db8::2/64, 10.9.0.2/24
DNS = 1.1.1.1
MTU = 1280
Jc = 5
Jmin = 50
Jmax = 300
S1 = 50
S2 = 100
S3 = 18
S4 = ${s4}
H1 = 100000-200000
H2 = 300000-400000
H3 = 500000-600000
H4 = 700000-800000
I1 = <r 128>
I2 = <r 64>
I3 = <r 96>
I4 = <r 32>
I5 = <r 16>
ContentPaddingAddition = 0-128
HeaderProtectionKey = ${header_key}
MaxHandshakeAttempts = 5-10
KeepaliveTimeout = 20
RejectAfterTime = 180-360
RekeyAfterTime = 120
RekeyTimeout = ${rekey_timeout}

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=
PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA=
Endpoint = 198.51.100.20:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 33
UPSTREAM
}

@test "_validate_iface_name accepts common iface names" {
    run _validate_iface_name "awg1"
    [ "$status" -eq 0 ]
    run _validate_iface_name "wg0"
    [ "$status" -eq 0 ]
    run _validate_iface_name "cascade-up"
    [ "$status" -eq 0 ]
}

@test "_validate_iface_name rejects injection attempts" {
    run _validate_iface_name "awg1; rm -rf /"
    [ "$status" -ne 0 ]
    run _validate_iface_name "awg1 && id"
    [ "$status" -ne 0 ]
    run _validate_iface_name ""
    [ "$status" -ne 0 ]
    # Starts with a digit — Linux allows it, but wg-quick systemd template
    # expects the letter prefix; we reject for safety.
    run _validate_iface_name "1wg"
    [ "$status" -ne 0 ]
    # Too long (>15 chars, IFNAMSIZ-1)
    run _validate_iface_name "verylonginterfacename"
    [ "$status" -ne 0 ]
}

@test "_extract_upstream_field reads [Interface] fields" {
    local src="$TEST_DIR/upstream.conf"
    create_upstream_conf "$src"
    run _extract_upstream_field "$src" Interface PrivateKey
    [ "$status" -eq 0 ]
    [ "$output" = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ]
    run _extract_upstream_field "$src" Interface H3
    [ "$output" = "500000-600000" ]
}

@test "_extract_upstream_field reads [Peer] fields without bleed-through" {
    local src="$TEST_DIR/upstream.conf"
    create_upstream_conf "$src"
    run _extract_upstream_field "$src" Peer Endpoint
    [ "$output" = "198.51.100.20:51820" ]
    # PrivateKey lives in [Interface], not [Peer] — must not be returned.
    run _extract_upstream_field "$src" Peer PrivateKey
    [ -z "$output" ]
}

@test "upstream endpoint and AWG 3.0 range validators enforce their domains" {
    run _valid_upstream_endpoint "exit.example.com:51820"
    [ "$status" -eq 0 ]
    run _valid_upstream_endpoint "[2001:db8::1]:51820"
    [ "$status" -eq 0 ]
    run _valid_upstream_endpoint "exit.example.com:0"
    [ "$status" -ne 0 ]
    run _valid_upstream_endpoint 'exit.example.com;id:51820'
    [ "$status" -ne 0 ]

    run _valid_awg_u16_range "0-65535"
    [ "$status" -eq 0 ]
    run _valid_awg_u16_range "65535"
    [ "$status" -eq 0 ]
    run _valid_awg_u16_range "20-10"
    [ "$status" -ne 0 ]
    run _valid_awg_u16_range "65536"
    [ "$status" -ne 0 ]
}

@test "render_upstream_config produces a valid awg1.conf from upstream .conf" {
    local src="$TEST_DIR/upstream.conf"
    create_upstream_conf "$src"
    # Place SERVER_CONF_FILE in a writable temp — render_upstream_config
    # writes next to it as <iface>.conf.
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_UPSTREAM_CONF="$src"
    export AWG_UPSTREAM_IFACE="awg1"
    export AWG_UPSTREAM_TABLE="123"
    export AWG_UPSTREAM_FWMARK="0xca6d"
    export AWG_UPSTREAM_PRIORITY="456"
    # A non-/24 host CIDR is validated even though the fail-closed source rule
    # is now owned by awg0 rather than the support interface.
    export AWG_TUNNEL_SUBNET="10.8.17.1/20"

    run render_upstream_config
    [ "$status" -eq 0 ]

    local out="$TEST_DIR/awg1.conf"
    [ -f "$out" ]
    run _validate_quick_config_semantics "$out" upstream
    [ "$status" -eq 0 ]
    grep -q "^\[Interface\]$" "$out"
    grep -q "^PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=$" "$out"
    grep -q "^Address = 10.9.0.2/32$" "$out"
    grep -q "^Table = 123$" "$out"
    grep -q "^FwMark = 0xca6d$" "$out"
    run ! grep -q '^PostUp = ip rule ' "$out"
    grep -q '^PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE$' "$out"
    run ! grep -q '^PreDown = ip rule ' "$out"
    # Legacy AWG fields plus the upstream v5.28 / AWG 3.0 union are carried over.
    grep -q '^Jc = 5$' "$out"
    grep -q '^S3 = 18$' "$out"
    grep -q '^H4 = 700000-800000$' "$out"
    grep -q '^I1 = <r 128>$' "$out"
    grep -q '^I2 = <r 64>$' "$out"
    grep -q '^I5 = <r 16>$' "$out"
    grep -q '^ContentPaddingAddition = 0-128$' "$out"
    grep -q '^HeaderProtectionKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=$' "$out"
    grep -q '^MaxHandshakeAttempts = 5-10$' "$out"
    grep -q '^KeepaliveTimeout = 20$' "$out"
    grep -q '^RejectAfterTime = 180-360$' "$out"
    grep -q '^RekeyAfterTime = 120$' "$out"
    grep -q '^RekeyTimeout = 5-15$' "$out"
    # [Peer] present with forced AllowedIPs=0.0.0.0/0
    grep -q '^\[Peer\]$' "$out"
    grep -q '^PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=$' "$out"
    grep -q '^PresharedKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA=$' "$out"
    grep -q '^Endpoint = 198.51.100.20:51820$' "$out"
    grep -q '^AllowedIPs = 0.0.0.0/0$' "$out"
    # Mode 600
    local perms
    perms=$(stat -c '%a' "$out" 2>/dev/null || stat -f '%Lp' "$out")
    [ "$perms" = "600" ]
}

@test "render_upstream_config propagates every temporary config write failure (static)" {
    local common
    for common in \
        "$BATS_TEST_DIRNAME/../awg_common.sh" \
        "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        grep -qF 'local write_failed=0' "$common"
        grep -qF '|| write_failed=1' "$common"
        grep -qF '(( write_failed == 0 ))' "$common"
        grep -qF '} > "$tmpfile"; then' "$common"
    done
}

@test "render_upstream_config writes the configured custom iface path" {
    local src="$TEST_DIR/upstream.conf"
    create_upstream_conf "$src"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_UPSTREAM_CONF="$src"
    export AWG_UPSTREAM_IFACE="cascade-up"
    export AWG_UPSTREAM_TABLE="321"
    export AWG_UPSTREAM_FWMARK="0xca70"
    export AWG_UPSTREAM_PRIORITY="654"
    export AWG_TUNNEL_SUBNET="10.42.7.1/23"

    run render_upstream_config
    [ "$status" -eq 0 ]
    [ -f "$TEST_DIR/cascade-up.conf" ]
    [ ! -e "$TEST_DIR/awg1.conf" ]
    grep -q '^Table = 321$' "$TEST_DIR/cascade-up.conf"
    grep -q '^FwMark = 0xca70$' "$TEST_DIR/cascade-up.conf"
}

@test "render_upstream_config rejects unsafe routing identifiers" {
    local src="$TEST_DIR/upstream.conf"
    local name value
    create_upstream_conf "$src"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_UPSTREAM_CONF="$src"
    export AWG_UPSTREAM_IFACE="awg1"
    export AWG_TUNNEL_SUBNET="10.8.0.1/24"

    while read -r name value; do
        export AWG_UPSTREAM_TABLE="123"
        export AWG_UPSTREAM_FWMARK="0xca6d"
        export AWG_UPSTREAM_PRIORITY="456"
        case "$name" in
            AWG_UPSTREAM_TABLE)    export AWG_UPSTREAM_TABLE="$value" ;;
            AWG_UPSTREAM_FWMARK)   export AWG_UPSTREAM_FWMARK="$value" ;;
            AWG_UPSTREAM_PRIORITY) export AWG_UPSTREAM_PRIORITY="$value" ;;
        esac

        run render_upstream_config
        [ "$status" -ne 0 ]
        [ ! -e "$TEST_DIR/awg1.conf" ]
    done << 'CASES'
AWG_UPSTREAM_TABLE 254
AWG_UPSTREAM_FWMARK 0xca6c
AWG_UPSTREAM_PRIORITY 0
CASES
}

@test "render_upstream_config rejects invalid v5.28 fields without clobbering output" {
    local src="$TEST_DIR/upstream.conf"
    local out="$TEST_DIR/awg1.conf"
    local baseline="$TEST_DIR/awg1.baseline"
    local valid_header="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_UPSTREAM_CONF="$src"
    export AWG_UPSTREAM_IFACE="awg1"
    export AWG_UPSTREAM_TABLE="123"
    export AWG_UPSTREAM_FWMARK="0xca6d"
    export AWG_UPSTREAM_PRIORITY="456"
    export AWG_TUNNEL_SUBNET="10.8.0.1/24"

    create_upstream_conf "$src"
    run render_upstream_config
    [ "$status" -eq 0 ]
    cp "$out" "$baseline"

    create_upstream_conf "$src"
    sed -i 's/^PrivateKey = .*/PrivateKey = ZZZ/' "$src"
    run render_upstream_config
    [ "$status" -ne 0 ]
    cmp -s "$out" "$baseline"

    create_upstream_conf "$src"
    sed -i 's/^PublicKey = .*/PublicKey = PPP/' "$src"
    run render_upstream_config
    [ "$status" -ne 0 ]
    cmp -s "$out" "$baseline"

    create_upstream_conf "$src"
    sed -i 's/^Jc = .*/Jc = 999/' "$src"
    run render_upstream_config
    [ "$status" -ne 0 ]
    cmp -s "$out" "$baseline"

    create_upstream_conf "$src"
    sed -i 's/^Jmin = .*/Jmin = 301/' "$src"
    run render_upstream_config
    [ "$status" -ne 0 ]
    cmp -s "$out" "$baseline"

    create_upstream_conf "$src"
    sed -i 's/^H2 = .*/H2 = 150000-350000/' "$src"
    run render_upstream_config
    [ "$status" -ne 0 ]
    cmp -s "$out" "$baseline"

    create_upstream_conf "$src" "not-a-base64-key" "5-15"
    run render_upstream_config
    [ "$status" -ne 0 ]
    cmp -s "$out" "$baseline"

    create_upstream_conf "$src" "$valid_header" "65536"
    run render_upstream_config
    [ "$status" -ne 0 ]
    cmp -s "$out" "$baseline"

    # HeaderProtectionKey is only valid with all S1-S4 in 12..65535.
    create_upstream_conf "$src" "$valid_header" "5-15" "11"
    run render_upstream_config
    [ "$status" -ne 0 ]
    cmp -s "$out" "$baseline"
}

@test "render_upstream_config rejects upstream conf missing AWG 2.0 params" {
    local src="$TEST_DIR/bad_upstream.conf"
    cat > "$src" << 'BAD'
[Interface]
PrivateKey = ZZZ
Address = 10.9.0.2/32
Jc = 5
Jmin = 50
Jmax = 300

[Peer]
PublicKey = PPP
Endpoint = 1.2.3.4:51820
AllowedIPs = 0.0.0.0/0
BAD
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_UPSTREAM_CONF="$src"
    export AWG_UPSTREAM_IFACE="awg1"
    export AWG_UPSTREAM_TABLE="123"
    export AWG_UPSTREAM_FWMARK="0xca6d"
    export AWG_TUNNEL_SUBNET="10.8.0.1/24"

    run render_upstream_config
    [ "$status" -ne 0 ]
    [ ! -f "$TEST_DIR/awg1.conf" ]
}

@test "render_upstream_config rejects an unsafe iface name" {
    local src="$TEST_DIR/upstream.conf"
    create_upstream_conf "$src"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_UPSTREAM_CONF="$src"
    export AWG_UPSTREAM_IFACE="awg1; rm -rf /"
    export AWG_UPSTREAM_TABLE="123"
    export AWG_UPSTREAM_FWMARK="0xca6d"
    export AWG_TUNNEL_SUBNET="10.8.0.1/24"

    run render_upstream_config
    [ "$status" -ne 0 ]
}

@test "render_upstream_config rejects an upstream with shell metachars in values" {
    local src="$TEST_DIR/injected.conf"
    local pwned="$TEST_DIR/pwned"
    create_upstream_conf "$src"
    sed -i "s|^PrivateKey = .*|PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=; touch ${pwned};|" "$src"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_UPSTREAM_CONF="$src"
    export AWG_UPSTREAM_IFACE="awg1"
    export AWG_UPSTREAM_TABLE="123"
    export AWG_UPSTREAM_FWMARK="0xca6d"
    export AWG_TUNNEL_SUBNET="10.8.0.1/24"

    run render_upstream_config
    [ "$status" -ne 0 ]
    [ ! -e "$pwned" ]
}

@test "render_upstream_config rejects multiple Peer sections instead of mixing them" {
    local src="$TEST_DIR/two-peers.conf"
    create_upstream_conf "$src"
    cat >> "$src" << 'PEER'

[Peer]
PublicKey = DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDA=
PresharedKey = EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEA=
Endpoint = 203.0.113.20:51820
AllowedIPs = 0.0.0.0/0
PEER
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_UPSTREAM_CONF="$src"
    export AWG_UPSTREAM_IFACE="awg1"
    export AWG_UPSTREAM_TABLE="123"
    export AWG_UPSTREAM_FWMARK="0xca6d"
    export AWG_UPSTREAM_PRIORITY="456"
    export AWG_TUNNEL_SUBNET="10.8.0.1/24"

    run render_upstream_config
    [ "$status" -ne 0 ]
    [ ! -e "$TEST_DIR/awg1.conf" ]
}

@test "render_upstream_config keeps lookup and guard priorities before main" {
    local src="$TEST_DIR/upstream.conf"
    local out="$TEST_DIR/awg1.conf"
    local baseline="$TEST_DIR/awg1.baseline"
    create_upstream_conf "$src"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_UPSTREAM_CONF="$src"
    export AWG_UPSTREAM_IFACE="awg1"
    export AWG_UPSTREAM_TABLE="123"
    export AWG_UPSTREAM_FWMARK="0xca6d"
    export AWG_TUNNEL_SUBNET="10.8.0.1/24"

    export AWG_UPSTREAM_PRIORITY="32764"
    run render_upstream_config
    [ "$status" -eq 0 ]
    cp "$out" "$baseline"
    local priority
    for priority in 32765 32766 4294967295; do
        export AWG_UPSTREAM_PRIORITY="$priority"
        run render_upstream_config
        [ "$status" -ne 0 ]
        cmp -s "$out" "$baseline"
    done
}

@test "render_server_config with AWG_ROLE=entry emits forward-to-upstream PostUp" {
    # Seed required AWG params and a server keyfile; render into isolated tmp.
    create_init_config
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE"
    echo "TESTKEY" > "$AWG_DIR/server_private.key"
    chmod 600 "$AWG_DIR/server_private.key"
    # Stub get_main_nic so the test runs on machines without `ip` (macOS).
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
    export AWG_ROLE="entry"
    export AWG_UPSTREAM_IFACE="awg1"
    # SERVER_CONF_FILE from test_helper already lives under TEST_DIR.

    run render_server_config
    [ "$status" -eq 0 ]
    [ -f "$SERVER_CONF_FILE" ]

    # Entry PostUp must forward to the upstream iface and add the TCPMSS clamp.
    grep -q 'iptables -I FORWARD -i %i -o awg1 -j ACCEPT' "$SERVER_CONF_FILE"
    grep -q 'iptables -I FORWARD -i awg1 -o %i -m conntrack --ctstate RELATED,ESTABLISHED' "$SERVER_CONF_FILE"
    grep -q 'ip route replace blackhole default metric 42760 table 123' "$SERVER_CONF_FILE"
    grep -q 'ip rule add from 10.9.9.0/24 table 123 priority 456' "$SERVER_CONF_FILE"
    grep -q 'ip rule add blackhole from 10.9.9.0/24 priority 457' "$SERVER_CONF_FILE"
    grep -q 'TCPMSS --set-mss 1240' "$SERVER_CONF_FILE"
    # It must NOT add a MASQUERADE to an external NIC — egress happens on the
    # exit node, and a stray MASQUERADE here would mask the cascade.
    ! grep -q 'POSTROUTING.*MASQUERADE' "$SERVER_CONF_FILE"
}

@test "render_server_config with AWG_ROLE=single keeps MASQUERADE on NIC" {
    create_init_config
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE"
    echo "TESTKEY" > "$AWG_DIR/server_private.key"
    chmod 600 "$AWG_DIR/server_private.key"
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
    unset AWG_ROLE
    run render_server_config
    [ "$status" -eq 0 ]
    grep -q 'POSTROUTING.*MASQUERADE' "$SERVER_CONF_FILE"
    ! grep -q 'TCPMSS --clamp-mss-to-pmtu' "$SERVER_CONF_FILE"
}

@test "safe_load_config exports AWG_ROLE / AWG_UPSTREAM_* from init file" {
    cat > "$CONFIG_FILE" << 'CFG'
export AWG_ROLE='entry'
export AWG_UPSTREAM_IFACE='awg1'
export AWG_UPSTREAM_TABLE=123
export AWG_UPSTREAM_FWMARK='0xca6d'
export AWG_UPSTREAM_PRIORITY=456
CFG
    unset AWG_ROLE AWG_UPSTREAM_IFACE AWG_UPSTREAM_TABLE AWG_UPSTREAM_FWMARK AWG_UPSTREAM_PRIORITY
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_ROLE" = "entry" ]
    [ "$AWG_UPSTREAM_IFACE" = "awg1" ]
    [ "$AWG_UPSTREAM_TABLE" = "123" ]
    [ "$AWG_UPSTREAM_FWMARK" = "0xca6d" ]
    [ "$AWG_UPSTREAM_PRIORITY" = "456" ]
}

@test "manage upstream preserves the one-document JSON contract (static)" {
    local manage
    for manage in \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        grep -qF 'json_out "{\"command\":\"upstream\",\"action\":' "$manage"
        grep -qF '\"upstream_active\":$_jupactive,\"awg0_active\":$_jmainactive}' "$manage"
        grep -qF '_manage_iface_is_live "$AWG_UPSTREAM_IFACE" && _jupactive=true' "$manage"
        grep -qF '_manage_iface_is_live awg0 && _jmainactive=true' "$manage"
    done
}

@test "manage upstream lifecycle handles manual links and stays fail-closed (static)" {
    local manage
    for manage in \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        grep -qF '_manage_iface_link_present "$iface"' "$manage"
        grep -qF '_ensure_awg0_down() {' "$manage"
        grep -qF '_ensure_interface_down awg0 "$SERVER_CONF_FILE"' "$manage"
        grep -qF '_ensure_upstream_down() {' "$manage"
        grep -qF 'timeout 15 awg-quick down "$conf"' "$manage"
        grep -qF '_manage_iface_link_present awg0 && _main_was_link=1' "$manage"
        grep -qF '_restore_awg0_state "$_main_was_active" "$_main_was_link"' "$manage"
        grep -qF 'if _ensure_awg0_down; then' "$manage"
        grep -qF 'if _ensure_upstream_down; then' "$manage"
        grep -qF '_manage_iface_is_healthy() {' "$manage"
        [ "$(grep -cF '_manage_iface_is_healthy "$AWG_UPSTREAM_IFACE"' "$manage")" -eq 3 ]
        grep -qF 'if _manage_iface_is_healthy awg0; then' "$manage"
        grep -qF '_manage_quick_conf_matches_iface "$iface" "$conf"' "$manage"
        grep -qF '_manage_quick_conf_matches_iface awg0 "$SERVER_CONF_FILE" || return 1' "$manage"
        grep -qF 'timeout 15 awg-quick down "$SERVER_CONF_FILE" >/dev/null 2>&1 || true' "$manage"
    done
}

@test "manage mutation health rejects active unit without its live link" {
    local manage fn
    for manage in \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        for fn in _manage_iface_link_present _manage_iface_is_live _manage_iface_is_healthy; do
            eval "$(awk -v fn="$fn" '$0 ~ "^" fn "\\(\\)" {p=1} p{print} p && /^}$/ {exit}' "$manage")"
        done
        systemctl() { return 0; }
        ip() { return 1; }
        run _manage_iface_is_live awg1
        [ "$status" -eq 0 ]
        run _manage_iface_is_healthy awg1
        [ "$status" -ne 0 ]
        unset -f systemctl ip _manage_iface_link_present _manage_iface_is_live _manage_iface_is_healthy
    done
}

@test "manual quick fallback cannot use a config basename for another interface" {
    local manage
    for manage in \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        eval "$(awk '/^_manage_quick_conf_matches_iface\(\)/{p=1} p{print} p && /^}$/{exit}' "$manage")"
        run _manage_quick_conf_matches_iface awg0 /trusted/awg0.conf
        [ "$status" -eq 0 ]
        run _manage_quick_conf_matches_iface awg0 /trusted/custom.conf
        [ "$status" -ne 0 ]
        unset -f _manage_quick_conf_matches_iface
    done
}

@test "manage validates root path trust before logging or sourcing (static)" {
    local manage trust_line log_line source_line
    for manage in \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        grep -qF '(( EUID == 0 )) || return 0' "$manage"
        grep -qF '[[ -n "$path" && ! -L "$path" ]] || return 1' "$manage"
        grep -qF "stat -c '%u %a' -- \"\$path\"" "$manage"
        grep -qF '_manage_root_parent_chain_trusted "$path"' "$manage"

        trust_line=$(grep -nF 'if ! _manage_validate_privileged_paths; then' "$manage" | head -n1 | cut -d: -f1)
        log_line=$(grep -nF 'log "' "$manage" | awk -F: -v start="$trust_line" '$1 > start { print $1; exit }')
        source_line=$(grep -nF 'source "$COMMON_SCRIPT_PATH"' "$manage" | head -n1 | cut -d: -f1)
        [ -n "$trust_line" ]
        [ -n "$log_line" ]
        [ -n "$source_line" ]
        [ "$trust_line" -lt "$log_line" ]
        [ "$trust_line" -lt "$source_line" ]
    done
}

@test "manage strict topology loader keeps legacy defaults and rejects explicit corruption (static)" {
    local manage
    for manage in \
        "$BATS_TEST_DIRNAME/../manage_amneziawg.sh" \
        "$BATS_TEST_DIRNAME/../manage_amneziawg_en.sh"; do
        # Honest absence is the legacy format: single role and awg1 default.
        grep -qF 'local role="single" iface="awg1" role_seen=0 iface_seen=0' "$manage"
        grep -qF '(( role_seen == 1 )) || {' "$manage"
        grep -qF '(( iface_seen == 1 )) || {' "$manage"
        grep -qF '_MANAGE_CONFIG_ROLE="$role"' "$manage"
        grep -qF '_MANAGE_CONFIG_UPSTREAM_IFACE="$iface"' "$manage"
        grep -qF 'AWG_ROLE="$_MANAGE_CONFIG_ROLE"' "$manage"
        grep -qF 'AWG_UPSTREAM_IFACE="$_MANAGE_CONFIG_UPSTREAM_IFACE"' "$manage"
    done
}

@test "RU and EN docs describe current cascade ownership and WARP guard contracts" {
    local doc
    for doc in \
        "$BATS_TEST_DIRNAME/../MULTIHOP.md" \
        "$BATS_TEST_DIRNAME/../MULTIHOP.en.md"; do
        grep -qF '`awg0.conf`' "$doc"
        grep -qF '`PostUp`/`PostDown`' "$doc"
        grep -qF '42760' "$doc"
        grep -qF 'priority 456' "$doc"
        grep -qF '`P+1`' "$doc"
        grep -qF '`awg1.conf`' "$doc"
        grep -qF '`Table=123`' "$doc"
        grep -qF '`FwMark=0xca6d`' "$doc"
        grep -qF '`AllowedIPs = 0.0.0.0/0`' "$doc"
        grep -qF -- '--warp-priority=N' "$doc"
        grep -qF '1..32764' "$doc"
        grep -qF -- '--warp-bypass=SPEC' "$doc"
        grep -qF '`32766`' "$doc"
    done
}

@test "installers preserve an I1 value that already matches its mode (static)" {
    local installer guard_line regenerate_line
    for installer in \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh" \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        grep -qF 'local _i1_matches_mode=0' "$installer"
        grep -qF 'random) [[ "${AWG_I1:-}" == "<r "*">" ]] && _i1_matches_mode=1 ;;' "$installer"
        grep -qF 'quic)   [[ "${AWG_I1:-}" == "<b 0x"*">" ]] && _i1_matches_mode=1 ;;' "$installer"
        grep -qF 'if [[ "${AWG_I1_MODE:-random}" == "$CLI_I1_MODE" && "$_i1_matches_mode" -eq 1 ]]; then' "$installer"

        guard_line=$(grep -nF 'if [[ "${AWG_I1_MODE:-random}" == "$CLI_I1_MODE" && "$_i1_matches_mode" -eq 1 ]]; then' "$installer" | head -n1 | cut -d: -f1)
        regenerate_line=$(grep -nF 'generate_i1_for_mode "$CLI_I1_MODE"' "$installer" | head -n1 | cut -d: -f1)
        [ -n "$guard_line" ]
        [ -n "$regenerate_line" ]
        [ "$guard_line" -lt "$regenerate_line" ]
    done
}
