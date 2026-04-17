#!/usr/bin/env bats
# Tests for multi-hop / cascade helpers in awg_common.sh:
#   _validate_iface_name, _extract_upstream_field, render_upstream_config
# and for AWG_ROLE=entry branching inside render_server_config.

load test_helper

# Helper: write a minimal valid "upstream" client conf (as produced by
# manage add on the exit node) into a given path.
create_upstream_conf() {
    local path="$1"
    cat > "$path" << 'UPSTREAM'
[Interface]
PrivateKey = ZEntryPrivKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.9.0.2/32
DNS = 1.1.1.1
MTU = 1280
Jc = 5
Jmin = 50
Jmax = 300
S1 = 50
S2 = 100
S3 = 18
S4 = 0
H1 = 1234567
H2 = 2345678
H3 = 3456789
H4 = 4567890
I1 = <r 128>

[Peer]
PublicKey = ExitServerPublicKeyAAAAAAAAAAAAAAAAAAAAAAAA=
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
    [ "$output" = "ZEntryPrivKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" ]
    run _extract_upstream_field "$src" Interface H3
    [ "$output" = "3456789" ]
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
    export AWG_TUNNEL_SUBNET="10.8.0.1/24"

    run render_upstream_config
    [ "$status" -eq 0 ]

    local out="$TEST_DIR/awg1.conf"
    [ -f "$out" ]
    grep -q "^\[Interface\]$" "$out"
    grep -q "^PrivateKey = ZEntryPrivKeyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=$" "$out"
    grep -q "^Address = 10.9.0.2/32$" "$out"
    grep -q "^Table = 123$" "$out"
    grep -q "^FwMark = 0xca6d$" "$out"
    grep -q '^PostUp = ip rule add from 10.8.0.1/24 table 123 priority 456$' "$out"
    grep -q '^PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE$' "$out"
    grep -q '^PreDown = ip rule del from 10.8.0.1/24 table 123 priority 456$' "$out"
    # All 11 AWG 2.0 params carried over
    grep -q '^Jc = 5$' "$out"
    grep -q '^S3 = 18$' "$out"
    grep -q '^H4 = 4567890$' "$out"
    grep -q '^I1 = <r 128>$' "$out"
    # [Peer] present with forced AllowedIPs=0.0.0.0/0
    grep -q '^\[Peer\]$' "$out"
    grep -q '^PublicKey = ExitServerPublicKeyAAAAAAAAAAAAAAAAAAAAAAAA=$' "$out"
    grep -q '^Endpoint = 198.51.100.20:51820$' "$out"
    grep -q '^AllowedIPs = 0.0.0.0/0$' "$out"
    # Mode 600
    local perms
    perms=$(stat -c '%a' "$out" 2>/dev/null || stat -f '%Lp' "$out")
    [ "$perms" = "600" ]
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
    cat > "$src" << 'INJ'
[Interface]
PrivateKey = ZZZ"; touch /tmp/pwned; "
Address = 10.9.0.2/32
Jc = 5
Jmin = 50
Jmax = 300
S1 = 50
S2 = 100
S3 = 18
S4 = 0
H1 = 1
H2 = 2
H3 = 3
H4 = 4

[Peer]
PublicKey = PPP
Endpoint = 1.2.3.4:51820
AllowedIPs = 0.0.0.0/0
INJ
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export AWG_UPSTREAM_CONF="$src"
    export AWG_UPSTREAM_IFACE="awg1"
    export AWG_UPSTREAM_TABLE="123"
    export AWG_UPSTREAM_FWMARK="0xca6d"
    export AWG_TUNNEL_SUBNET="10.8.0.1/24"

    run render_upstream_config
    [ "$status" -ne 0 ]
    [ ! -e /tmp/pwned ]
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
    grep -q 'TCPMSS --clamp-mss-to-pmtu' "$SERVER_CONF_FILE"
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
