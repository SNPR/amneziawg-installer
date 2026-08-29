#!/usr/bin/env bats
# Tests for WARP egress branch in render_server_config. setup_warp_egress
# performs network and systemd operations, so its ownership/lifecycle contract
# is covered statically while the pure config renderer is exercised normally.

# `run !` flag form requires bats-core 1.5.0+.
bats_require_minimum_version 1.5.0

load test_helper

write_restorable_warp_conf() {
    local path="$1"
    cat > "$path" << 'CONF'
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 172.16.0.2/32, 2606:4700:110:8765::2/128
DNS = 1.1.1.1
MTU = 1280
Table = off

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
CONF
}

@test "WARP baseline validator rejects non-restorable typed configs" {
    local conf="$TEST_DIR/wgcf.conf" field
    write_restorable_warp_conf "$conf"
    run _validate_quick_config_semantics "$conf" warp
    [ "$status" -eq 0 ]

    for field in PrivateKey Address AddressLeadingZero Prefix Table MTU PublicKey Endpoint EndpointLeadingZero AllowedIPs AllowedIPsLeadingZero EmptyEndpoint Hook UnknownKey PeerCount; do
        write_restorable_warp_conf "$conf"
        case "$field" in
            PrivateKey) sed -i 's|^PrivateKey = .*|PrivateKey = bad|' "$conf" ;;
            Address) sed -i 's|^Address = .*|Address = 172.16.999.2/32|' "$conf" ;;
            AddressLeadingZero) sed -i 's|^Address = .*|Address = 172.016.000.002/32|' "$conf" ;;
            Prefix) sed -i 's|^Address = .*|Address = 172.16.0.2/33|' "$conf" ;;
            Table) sed -i 's|^Table = .*|Table = unsafe|' "$conf" ;;
            MTU) sed -i 's|^MTU = .*|MTU = 12|' "$conf" ;;
            PublicKey) sed -i 's|^PublicKey = .*|PublicKey = bad|' "$conf" ;;
            Endpoint) sed -i 's|^Endpoint = .*|Endpoint = engage.cloudflareclient.com:70000|' "$conf" ;;
            EndpointLeadingZero) sed -i 's|^Endpoint = .*|Endpoint = 010.009.000.002:2408|' "$conf" ;;
            AllowedIPs) sed -i 's|^AllowedIPs = .*|AllowedIPs = ::/0|' "$conf" ;;
            AllowedIPsLeadingZero) sed -i 's|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/0, 010.009.000.002/32|' "$conf" ;;
            EmptyEndpoint) sed -i 's|^Endpoint = .*|Endpoint =|' "$conf" ;;
            Hook) sed -i '/^MTU =/a PostUp = false' "$conf" ;;
            UnknownKey) sed -i '/^MTU =/a Unsafe = value' "$conf" ;;
            PeerCount) printf '\n[Peer]\nPublicKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA=\nAllowedIPs = 0.0.0.0/0\nEndpoint = 1.1.1.1:2408\n' >> "$conf" ;;
        esac
        run _validate_quick_config_semantics "$conf" warp
        [ "$status" -ne 0 ]
    done
}

@test "render_server_config with AWG_EGRESS=warp emits WARP policy routing" {
    create_init_config
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE"
    echo "TESTKEY" > "$AWG_DIR/server_private.key"
    chmod 600 "$AWG_DIR/server_private.key"
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic

    export AWG_EGRESS="warp"
    export AWG_WARP_IFACE="wgcf"
    export AWG_WARP_TABLE="2408"
    export AWG_WARP_PRIORITY="789"
    export AWG_WARP_BYPASS="youtube"
    export AWG_MTU="1220"
    unset AWG_ROLE

    run render_server_config
    [ "$status" -eq 0 ]
    [ -f "$SERVER_CONF_FILE" ]

    # Policy-routing primitives must be present
    grep -q 'ip route replace blackhole default metric 42760 table 2408' "$SERVER_CONF_FILE"
    grep -q 'ip route replace default dev wgcf metric 10 table 2408' "$SERVER_CONF_FILE"
    grep -q 'ip rule add from 10.9.9.0/24 table 2408 priority 789' "$SERVER_CONF_FILE"
    grep -qF 'ip rule add blackhole from 10.9.9.0/24 priority 790 || exit $?' "$SERVER_CONF_FILE"
    grep -qF 'ip route replace default dev wgcf metric 10 table 2408 || exit $?' "$SERVER_CONF_FILE"
    local postup
    postup=$(sed -n 's/^PostUp = //p' "$SERVER_CONF_FILE")
    [[ "$postup" == *"ip rule add blackhole from 10.9.9.0/24 priority 790"*"ip rule add from 10.9.9.0/24 table 2408 priority 789"* ]]
    run ! grep -q 'systemctl.*awg-warp-bypass' "$SERVER_CONF_FILE"
    # FORWARD + MASQUERADE happen on wgcf, not on eth0
    grep -q 'iptables -I FORWARD -i %i -o wgcf -j ACCEPT' "$SERVER_CONF_FILE"
    grep -q 'iptables -t nat -A POSTROUTING -s 10.9.9.0/24 -o wgcf -j MASQUERADE' "$SERVER_CONF_FILE"
    # Direct-NIC bypass NAT must be scoped to VPN clients, never all host traffic.
    grep -q 'iptables -t nat -A POSTROUTING -s 10.9.9.0/24 -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"
    run ! grep -q 'POSTROUTING -o wgcf -j MASQUERADE' "$SERVER_CONF_FILE"
    run ! grep -q 'POSTROUTING -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"
    # No stray MASQUERADE on eth0 — that would bypass WARP for some packets
    run ! grep -qE 'POSTROUTING -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"

    # MSS is derived from AWG_MTU (1220 - 40), in both directions.
    grep -q 'iptables -t mangle -A FORWARD -o %i .*TCPMSS --set-mss 1180' "$SERVER_CONF_FILE"
    grep -q 'iptables -t mangle -A FORWARD -i %i .*TCPMSS --set-mss 1180' "$SERVER_CONF_FILE"
    grep -q 'iptables -t mangle -D FORWARD -o %i .*TCPMSS --set-mss 1180' "$SERVER_CONF_FILE"
    grep -q 'iptables -t mangle -D FORWARD -i %i .*TCPMSS --set-mss 1180' "$SERVER_CONF_FILE"

    # Client isolation is drained before insertion and removed on teardown.
    grep -q 'while iptables -D FORWARD -i %i -o %i -j DROP .*iptables -I FORWARD -i %i -o %i -j DROP' "$SERVER_CONF_FILE"
    grep -q 'iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true' "$SERVER_CONF_FILE"

    # PostDown reverses all stateful routing/firewall hooks.
    grep -q 'iptables -D FORWARD -i %i -o wgcf -j ACCEPT' "$SERVER_CONF_FILE"
    grep -q 'iptables -D FORWARD -i wgcf -o %i .*RELATED,ESTABLISHED.*-j ACCEPT' "$SERVER_CONF_FILE"
    grep -q 'iptables -t nat -D POSTROUTING -s 10.9.9.0/24 -o wgcf -j MASQUERADE' "$SERVER_CONF_FILE"
    grep -q 'iptables -t nat -D POSTROUTING -s 10.9.9.0/24 -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"
    grep -q 'ip rule del from 10.9.9.0/24 table 2408 priority 789' "$SERVER_CONF_FILE"
    grep -q 'ip route del default dev wgcf metric 10 table 2408' "$SERVER_CONF_FILE"
    grep -q 'ip route del blackhole default metric 42760 table 2408' "$SERVER_CONF_FILE"
}

@test "render_server_config WARP without bypass has no direct-NIC NAT path" {
    create_init_config
    safe_load_config "$CONFIG_FILE"
    echo "TESTKEY" > "$AWG_DIR/server_private.key"
    chmod 600 "$AWG_DIR/server_private.key"
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
    export AWG_EGRESS="warp"
    export AWG_WARP_IFACE="wgcf"
    export AWG_WARP_TABLE="2408"
    export AWG_WARP_PRIORITY="789"
    export AWG_WARP_BYPASS="none"
    unset AWG_ROLE

    run render_server_config
    [ "$status" -eq 0 ]
    grep -q 'POSTROUTING -s 10.9.9.0/24 -o wgcf -j MASQUERADE' "$SERVER_CONF_FILE"
    run ! grep -q 'POSTROUTING -s 10.9.9.0/24 -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"
}

@test "render_server_config reserves guard priority before Linux main" {
    create_init_config
    safe_load_config "$CONFIG_FILE"
    echo "TESTKEY" > "$AWG_DIR/server_private.key"
    chmod 600 "$AWG_DIR/server_private.key"
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
    export AWG_EGRESS="warp"
    export AWG_WARP_IFACE="wgcf"
    export AWG_WARP_TABLE="2408"
    export AWG_WARP_BYPASS="none"
    unset AWG_ROLE

    export AWG_WARP_PRIORITY="32764"
    run render_server_config
    [ "$status" -eq 0 ]
    grep -q 'priority 32765' "$SERVER_CONF_FILE"
    local priority
    for priority in 32765 32766 4294967295; do
        rm -f "$SERVER_CONF_FILE"
        export AWG_WARP_PRIORITY="$priority"
        run render_server_config
        [ "$status" -ne 0 ]
        [ ! -e "$SERVER_CONF_FILE" ]
    done
}

@test "render_server_config with AWG_EGRESS=direct falls back to NIC MASQUERADE" {
    create_init_config
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE"
    echo "TESTKEY" > "$AWG_DIR/server_private.key"
    chmod 600 "$AWG_DIR/server_private.key"
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
    export AWG_EGRESS="direct"
    unset AWG_ROLE

    run render_server_config
    [ "$status" -eq 0 ]
    grep -qE 'POSTROUTING -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"
    run ! grep -q 'wgcf' "$SERVER_CONF_FILE"
    run ! grep -q 'table 2408' "$SERVER_CONF_FILE"
}

@test "render_server_config: role=entry takes precedence over AWG_EGRESS=warp" {
    # Guarding the semantic chosen in initialize_setup: entry forwards to
    # upstream; WARP would be a nonsensical third hop. Even if a mis-saved
    # config has both AWG_ROLE=entry and AWG_EGRESS=warp, the renderer
    # should emit the entry branch, not the WARP branch.
    create_init_config
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE"
    echo "TESTKEY" > "$AWG_DIR/server_private.key"
    chmod 600 "$AWG_DIR/server_private.key"
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic

    export AWG_ROLE="entry"
    export AWG_UPSTREAM_IFACE="awg1"
    export AWG_EGRESS="warp"

    run render_server_config
    [ "$status" -eq 0 ]
    # Entry-mode markers present
    grep -q 'iptables -I FORWARD -i %i -o awg1 -j ACCEPT' "$SERVER_CONF_FILE"
    # WARP markers absent
    run ! grep -q 'wgcf' "$SERVER_CONF_FILE"
    run ! grep -q 'table 2408' "$SERVER_CONF_FILE"
}

@test "safe_load_config exports AWG_EGRESS / AWG_WARP_* fields" {
    cat > "$CONFIG_FILE" << 'CFG'
export AWG_EGRESS='warp'
export AWG_WARP_IFACE='wgcf'
export AWG_WARP_TABLE=2408
export AWG_WARP_PRIORITY=789
CFG
    unset AWG_EGRESS AWG_WARP_IFACE AWG_WARP_TABLE AWG_WARP_PRIORITY
    safe_load_config "$CONFIG_FILE"
    [ "$AWG_EGRESS" = "warp" ]
    [ "$AWG_WARP_IFACE" = "wgcf" ]
    [ "$AWG_WARP_TABLE" = "2408" ]
    [ "$AWG_WARP_PRIORITY" = "789" ]
}

@test "render_server_config WARP: honours custom table and priority" {
    create_init_config
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE"
    echo "TESTKEY" > "$AWG_DIR/server_private.key"
    chmod 600 "$AWG_DIR/server_private.key"
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic

    export AWG_EGRESS="warp"
    export AWG_WARP_IFACE="warp9"
    export AWG_WARP_TABLE="5555"
    export AWG_WARP_PRIORITY="1234"
    unset AWG_ROLE

    run render_server_config
    [ "$status" -eq 0 ]
    grep -q 'default dev warp9 metric 10 table 5555' "$SERVER_CONF_FILE"
    grep -q 'POSTROUTING -s 10.9.9.0/24 -o warp9 -j MASQUERADE' "$SERVER_CONF_FILE"
    grep -q 'table 5555' "$SERVER_CONF_FILE"
    grep -q 'priority 1234' "$SERVER_CONF_FILE"
    run ! grep -q 'wgcf' "$SERVER_CONF_FILE"
}

@test "render_server_config WARP preserves all peer blocks atomically" {
    local peers_source="$TEST_DIR/existing-awg0.conf"
    create_init_config
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE"
    echo "TESTKEY" > "$AWG_DIR/server_private.key"
    chmod 600 "$AWG_DIR/server_private.key"
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
    cat > "$peers_source" << 'CONF'
[Interface]
PrivateKey = OLD

[Peer]
#_Name = alice
PublicKey = ALICEKEY
AllowedIPs = 10.9.9.2/32

[Peer]
#_Name = bob
PublicKey = BOBKEY
PresharedKey = BOBPSK
AllowedIPs = 10.9.9.3/32
CONF
    export AWG_EGRESS="warp"
    export AWG_WARP_IFACE="wgcf"
    export AWG_WARP_TABLE="2408"
    export AWG_WARP_PRIORITY="789"
    unset AWG_ROLE

    run render_server_config "$peers_source"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^\[Peer\]$' "$SERVER_CONF_FILE")" -eq 2 ]
    grep -q '^#_Name = alice$' "$SERVER_CONF_FILE"
    grep -q '^#_Name = bob$' "$SERVER_CONF_FILE"
    grep -q '^PresharedKey = BOBPSK$' "$SERVER_CONF_FILE"
}

@test "render_server_config rejects the unsupported WARP plus IPv6 combination" {
    create_init_config
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE"
    echo "TESTKEY" > "$AWG_DIR/server_private.key"
    chmod 600 "$AWG_DIR/server_private.key"
    get_main_nic() { echo "eth0"; }
    export -f get_main_nic
    export AWG_EGRESS="warp"
    export AWG_WARP_IFACE="wgcf"
    export ALLOW_IPV6_TUNNEL=1
    unset AWG_ROLE

    run render_server_config
    [ "$status" -ne 0 ]
    [ ! -e "$SERVER_CONF_FILE" ]
}

@test "IPv6 tunnel CLI keeps an explicit opt-out in both installers (static)" {
    local installer
    for installer in \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh" \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        grep -qF -- 'CLI_ALLOW_IPV6_TUNNEL="default"' "$installer"
        grep -qF -- '--allow-ipv6-tunnel) CLI_ALLOW_IPV6_TUNNEL=1 ;;' "$installer"
        grep -qF -- '--disallow-ipv6-tunnel) CLI_ALLOW_IPV6_TUNNEL=0 ;;' "$installer"
        grep -qF -- '0) ALLOW_IPV6_TUNNEL=0 ;;' "$installer"
        grep -qF -- '[[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "${AWG_EGRESS:-direct}" == "warp" ]]' "$installer"
    done
}

@test "WARP setup uses granular ownership and preserves pre-existing files (static)" {
    local common setup_start setup_end ownership_line download_line probe_line action_line marker_line
    local baseline_validate_line migrate_line migrate_apply_line download_preflight_line
    local snapshot_start snapshot_end snapshot_probe snapshot_validate snapshot_copy rollback_clean rollback_stop_runtime
    local download_start legacy_start restore_start download_dirty download_mv legacy_dirty legacy_write
    for common in \
        "$BATS_TEST_DIRNAME/../awg_common.sh" \
        "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        grep -qF 'local warp_conf="/etc/wireguard/${warp_iface}.conf"' "$common"
        grep -qF 'local binary_marker="${AWG_DIR}/.wgcf_binary_installed_by_installer"' "$common"
        grep -qF 'local config_marker="${AWG_DIR}/.wgcf_config_created_by_installer"' "$common"
        grep -qF 'local managed_config_marker="${AWG_DIR}/.wgcf_config_managed_by_installer"' "$common"
        grep -qF 'local account_marker="${AWG_DIR}/.wgcf_account_created_by_installer"' "$common"
        grep -qF 'for ownership_marker in "$binary_marker" "$config_marker" "$managed_config_marker" "$account_marker"; do' "$common"
        grep -qF 'if [[ ! -f "$ownership_marker" || -L "$ownership_marker" ]]; then' "$common"
        grep -qF 'if [[ "$ownership_value" != "$ownership_path" \' "$common"
        grep -qF '|| ! -f "$ownership_path" || -L "$ownership_path" ]]; then' "$common"
        grep -qF 'if [[ "$owned_warp_conf" != "$warp_conf" ]]; then' "$common"
        grep -qF 'if [[ ! -f "$marker" || -L "$marker" ]] \' "$common"
        grep -qF '|| [[ "$owned_warp_iface" == *$'\''\n'\''* ]] \' "$common"
        grep -qF 'printf '\''%s\n'\'' "$warp_conf" > "$config_marker"' "$common"
        grep -qF 'printf '\''%s\n'\'' "$warp_iface" > "$marker"' "$common"
        grep -qF 'if [[ "$warp_conf" == "/etc/wireguard/wgcf-profile.conf" ]]; then' "$common"
        grep -qF 'if [[ -e /etc/wireguard/wgcf-profile.conf || -L /etc/wireguard/wgcf-profile.conf ]]; then' "$common"

        setup_start=$(grep -n '^setup_warp_egress()' "$common" | cut -d: -f1)
        setup_end=$(grep -n '^_AWG_BYPASS_TX_ACTIVE=0' "$common" | cut -d: -f1)
        baseline_validate_line=$(grep -nF '_validate_quick_config_semantics "$warp_conf" warp' "$common" \
            | awk -F: -v start="$setup_start" -v end="$setup_end" '$1 > start && $1 < end { print $1; exit }')
        migrate_line=$(grep -nF 'migrate_legacy_warp_ownership "$warp_iface" preflight || return 1' "$common" \
            | awk -F: -v start="$setup_start" -v end="$setup_end" '$1 > start && $1 < end { print $1; exit }')
        migrate_apply_line=$(grep -nF 'migrate_legacy_warp_ownership "$warp_iface" \' "$common" \
            | awk -F: -v start="$setup_start" -v end="$setup_end" '$1 > start && $1 < end { print $1; exit }')
        ownership_line=$(grep -nF 'if [[ -e "$warp_conf" || -L "$warp_conf" ]]; then' "$common" \
            | awk -F: -v start="$setup_start" -v end="$setup_end" '$1 > start && $1 < end { print $1; exit }')
        download_line=$(grep -nF '_download_wgcf_binary || return 1' "$common" \
            | awk -F: -v start="$setup_start" -v end="$setup_end" '$1 > start && $1 < end { print $1; exit }')
        download_preflight_line=$(grep -nF '_download_wgcf_binary preflight || return 1' "$common" \
            | awk -F: -v start="$setup_start" -v end="$setup_end" '$1 > start && $1 < end { print $1; exit }')
        probe_line=$(grep -nF 'systemctl is-active --quiet "$warp_unit"' "$common" \
            | awk -F: -v start="$setup_start" -v end="$setup_end" '$1 > start && $1 < end { print $1; exit }')
        action_line=$(grep -nF 'case "$service_action" in' "$common" \
            | awk -F: -v start="$setup_start" -v end="$setup_end" '$1 > start && $1 < end { print $1; exit }')
        marker_line=$(grep -nF 'printf '\''%s\n'\'' "$warp_iface" > "$marker"' "$common" \
            | awk -F: -v start="$setup_start" -v end="$setup_end" '$1 > start && $1 < end { print $1; exit }')
        [ -n "$setup_start" ]
        [ -n "$setup_end" ]
        [ -n "$baseline_validate_line" ]
        [ -n "$migrate_line" ]
        [ -n "$migrate_apply_line" ]
        [ -n "$ownership_line" ]
        [ -n "$download_line" ]
        [ -n "$download_preflight_line" ]
        [ -n "$probe_line" ]
        [ -n "$action_line" ]
        [ -n "$marker_line" ]
        [ "$probe_line" -lt "$baseline_validate_line" ]
        [ "$baseline_validate_line" -lt "$migrate_line" ]
        [ "$migrate_line" -lt "$ownership_line" ]
        [ "$ownership_line" -lt "$download_preflight_line" ]
        [ "$download_preflight_line" -lt "$migrate_apply_line" ]
        [ "$migrate_apply_line" -lt "$download_line" ]
        [ "$baseline_validate_line" -lt "$action_line" ]
        [ "$action_line" -lt "$marker_line" ]

        snapshot_start=$(grep -n '^snapshot_warp_egress_state()' "$common" | cut -d: -f1)
        snapshot_end=$(grep -n '^rollback_warp_egress_state()' "$common" | cut -d: -f1)
        snapshot_probe=$(grep -nF 'systemctl is-active --quiet "wg-quick@${iface}"' "$common" \
            | awk -F: -v start="$snapshot_start" -v end="$snapshot_end" '$1 > start && $1 < end { print $1; exit }')
        snapshot_validate=$(grep -nF '_validate_quick_config_semantics "$conf" warp' "$common" \
            | awk -F: -v start="$snapshot_start" -v end="$snapshot_end" '$1 > start && $1 < end { print $1; exit }')
        snapshot_copy=$(grep -nF 'for path in "${_AWG_WARP_TX_PATHS[@]}"; do' "$common" \
            | awk -F: -v start="$snapshot_start" -v end="$snapshot_end" '$1 > start && $1 < end { print $1; exit }')
        [ -n "$snapshot_probe" ]
        [ -n "$snapshot_validate" ]
        [ -n "$snapshot_copy" ]
        [ "$snapshot_probe" -lt "$snapshot_validate" ]
        [ "$snapshot_validate" -lt "$snapshot_copy" ]

        rollback_clean=$(grep -nF 'if [[ "${_AWG_WARP_TX_DIRTY:-0}" -eq 0 ]]; then' "$common" \
            | awk -F: -v start="$snapshot_end" '$1 > start { print $1; exit }')
        rollback_stop_runtime=$(grep -nF 'systemctl stop "$unit" >/dev/null 2>&1 || true' "$common" \
            | awk -F: -v start="$snapshot_end" '$1 > start { print $1; exit }')
        [ -n "$rollback_clean" ]
        [ -n "$rollback_stop_runtime" ]
        [ "$rollback_clean" -lt "$rollback_stop_runtime" ]

        download_start=$(grep -n '^_download_wgcf_binary()' "$common" | cut -d: -f1)
        legacy_start=$(grep -n '^migrate_legacy_warp_ownership()' "$common" | cut -d: -f1)
        restore_start=$(grep -n '^_restore_warp_setup_state()' "$common" | cut -d: -f1)
        download_dirty=$(grep -nF '[[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] || _AWG_WARP_TX_DIRTY=1' "$common" \
            | awk -F: -v start="$download_start" -v end="$legacy_start" '$1 > start && $1 < end { print $1; exit }')
        download_mv=$(grep -nF 'mv -f "$wgcf_tmp" "$target" \' "$common" | cut -d: -f1)
        legacy_dirty=$(grep -nF '[[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] || _AWG_WARP_TX_DIRTY=1' "$common" \
            | awk -F: -v start="$legacy_start" -v end="$restore_start" '$1 > start && $1 < end { print $1; exit }')
        legacy_write=$(grep -nF "printf '%s\\n' \"\$warp_conf\" > \"\$managed_marker\"" "$common" | cut -d: -f1)
        [ "$download_dirty" -lt "$download_mv" ]
        [ "$legacy_dirty" -lt "$legacy_write" ]

        grep -qF 'restart)    systemctl restart "$warp_unit"' "$common"
        grep -qF 'start)      systemctl start "$warp_unit"' "$common"
        grep -qF 'enable-now) systemctl enable --now "$warp_unit"' "$common"
        grep -qF '&& "$service_was_enabled" -eq 0 && "$service_was_active" -eq 0' "$common"
    done
}

@test "wgcf download is release-pinned and SHA-256 verified (static)" {
    local common
    for common in \
        "$BATS_TEST_DIRNAME/../awg_common.sh" \
        "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        grep -qF 'local wgcf_version="2.2.32"' "$common"
        [ "$(grep -cE 'expected_sha="[0-9a-f]{64}"' "$common")" -eq 3 ]
        grep -qF '| sha256sum -c - >/dev/null 2>&1' "$common"
        ! grep -q 'releases/latest' "$common"
    done
}

@test "WARP bypass validates table-main egress and RFC6890 destinations (static)" {
    local common
    for common in \
        "$BATS_TEST_DIRNAME/../awg_common.sh" \
        "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        grep -qF 'ip -o -4 route show table main default' "$common"
        grep -qF 'route-get selected a tunnel-like interface' "$common"
        [ "$(grep -cF '10#$b == 51 && 10#$c == 100' "$common")" -eq 3 ]
        [ "$(grep -cF '10#$b == 0 && 10#$c == 113' "$common")" -eq 3 ]
        [ "$(grep -cF '10#$b == 0 && (10#$c == 0 || 10#$c == 2)' "$common")" -eq 3 ]
    done
}

@test "WARP bypass ledger and refresh transaction fail closed (static)" {
    local common snapshot rollback snapshot_arm snapshot_stop snapshot_lock snapshot_parse snapshot_ready
    local rollback_partial rollback_array_read rollback_stop rollback_lock rollback_parse
    local setup timer_publish setup_release first_service timer_enable
    local teardown teardown_snapshot teardown_lock teardown_parse teardown_absent teardown_remove
    for common in \
        "$BATS_TEST_DIRNAME/../awg_common.sh" \
        "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        # Canonical CIDRs only: leading-zero forms must never enter a ledger.
        [ "$(grep -cF '^(0|[1-9][0-9]{0,2})\.' "$common")" -eq 4 ]
        grep -qF '[[ -z "${route_seen[$line]+present}" ]] || return 1' "$common"
        grep -qF 'duplicate route ledger entry: $ledger_line' "$common"
        grep -qF '[[ -z "${ledger_seen[$line]+present}" ]] \' "$common"
        grep -qF 'ledger_line_no >= 2 && ${#old_routes[@]} >= 1' "$common"
        grep -qF 'foreign same-prefix route collision: $candidate_route' "$common"
        grep -qF 'delete_new_route_exact() {' "$common"
        grep -qF 'ip -4 route del "$route" via "$GW" dev "$NIC" table "$WARP_TABLE"' "$common"
        grep -qF 'ip -4 route del "$route" dev "$NIC" table "$WARP_TABLE"' "$common"
        grep -qF 'current=$(ip -o -4 route show table "$WARP_TABLE" exact "$route"' "$common"
        grep -qF 'delete_new_route_exact "$route" || rollback_failed=1' "$common"
        ! grep -qF 'ip -4 route del "$route" table "$WARP_TABLE" 2>/dev/null || true' "$common"
        [ "$(grep -cF 'if _valid_ipv4 "$route_dst"; then route_dst="${route_dst}/32"; fi' "$common")" -eq 3 ]
        grep -qF 'if valid_ipv4 "$old_dst"; then old_dst="${old_dst}/32"; fi' "$common"
        grep -qF 'if valid_ipv4 "$current_dst"; then current_dst="${current_dst}/32"; fi' "$common"
        grep -qF "printf '%s\\n' \"\$route\" >> \"\$CANDIDATE_FILE\" || return 1" "$common"
        grep -qF "printf 'table=%s\\n' \"\$WARP_TABLE\" > \"\$LEDGER_TMP\"" "$common"
        grep -qF "if ! printf '%s\\n' \"\$route\" >> \"\$LEDGER_TMP\"; then" "$common"
        grep -qF 'ledger_verify_line_no != added + 1' "$common"
        grep -qF 'ledger_verify_count != added || ${#new_routes[@]} != added' "$common"
        grep -qF '_valid_warp_bypass_route_iface() {' "$common"
        [ "$(grep -cF '! _valid_warp_bypass_route_iface "$route_dev"' "$common")" -eq 3 ]

        snapshot=$(grep -n '^_snapshot_warp_bypass_setup_state()' "$common" | cut -d: -f1)
        rollback=$(grep -n '^_rollback_warp_bypass_setup_state()' "$common" | cut -d: -f1)
        snapshot_arm=$(grep -nF '_AWG_BYPASS_TX_ACTIVE=1' "$common" \
            | awk -F: -v start="$snapshot" -v end="$rollback" '$1 > start && $1 < end { print $1; exit }')
        snapshot_stop=$(grep -nF 'if ! systemctl stop awg-warp-bypass.timer' "$common" \
            | awk -F: -v start="$snapshot" -v end="$rollback" '$1 > start && $1 < end { print $1; exit }')
        snapshot_lock=$(grep -nF 'exec {_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD}>/run/awg-warp-bypass.lock' "$common" \
            | awk -F: -v start="$snapshot" -v end="$rollback" '$1 > start && $1 < end { print $1; exit }')
        snapshot_parse=$(grep -nF 'if ! _parse_warp_bypass_ledger "$routes_file"; then' "$common" \
            | awk -F: -v start="$snapshot" -v end="$rollback" '$1 > start && $1 < end { print $1; exit }')
        snapshot_ready=$(grep -nF '_AWG_BYPASS_TX_SNAPSHOT_READY=1' "$common" \
            | awk -F: -v start="$snapshot" -v end="$rollback" '$1 > start && $1 < end { print $1; exit }')
        rollback_partial=$(grep -nF 'if [[ "${_AWG_BYPASS_TX_SNAPSHOT_READY:-0}" -ne 1 ]]; then' "$common" \
            | awk -F: -v start="$rollback" '$1 > start { print $1; exit }')
        rollback_array_read=$(grep -nF 'for route in "${_AWG_BYPASS_TX_ROUTES[@]}"; do' "$common" \
            | awk -F: -v start="$rollback" '$1 > start { print $1; exit }')
        rollback_stop=$(grep -nF 'systemctl stop awg-warp-bypass.timer' "$common" \
            | awk -F: -v start="$rollback" '$1 > start { print $1; exit }')
        rollback_lock=$(grep -nF 'exec {bypass_lock_fd}>/run/awg-warp-bypass.lock' "$common" \
            | awk -F: -v start="$rollback" '$1 > start { print $1; exit }')
        rollback_parse=$(grep -nF 'if ! _parse_warp_bypass_ledger "$routes_file"; then' "$common" \
            | awk -F: -v start="$rollback" '$1 > start { print $1; exit }')
        setup=$(grep -n '^setup_warp_bypass()' "$common" | cut -d: -f1)
        timer_publish=$(grep -nF 'chmod 0644 "$tmp_timer" && mv -f "$tmp_timer" "$bypass_timer" \' "$common" \
            | awk -F: -v start="$setup" '$1 > start { print $1; exit }')
        setup_release=$(grep -nF '_release_warp_bypass_snapshot_lock \' "$common" \
            | awk -F: -v start="$setup" '$1 > start { print $1; exit }')
        first_service=$(grep -nF 'systemctl start awg-warp-bypass.service >/dev/null 2>&1 \' "$common" | tail -n1 | cut -d: -f1)
        timer_enable=$(grep -nF 'systemctl enable --now awg-warp-bypass.timer >/dev/null 2>&1 \' "$common" | tail -n1 | cut -d: -f1)
        teardown=$(grep -n '^teardown_warp_bypass()' "$common" | cut -d: -f1)
        teardown_snapshot=$(grep -nF '_snapshot_warp_bypass_setup_state || return 1' "$common" \
            | awk -F: -v start="$teardown" '$1 > start { print $1; exit }')
        teardown_lock=$(grep -nF 'exec {bypass_lock_fd}>/run/awg-warp-bypass.lock || teardown_failed=1' "$common" \
            | awk -F: -v start="$teardown" '$1 > start { print $1; exit }')
        teardown_parse=$(grep -nF 'if ! _parse_warp_bypass_ledger "$routes_file"; then' "$common" \
            | awk -F: -v start="$teardown" '$1 > start { print $1; exit }')
        teardown_absent=$(grep -nF '_AWG_BYPASS_TX_EXPECT_CURRENT_ABSENT=1' "$common" \
            | awk -F: -v start="$teardown" '$1 > start { print $1; exit }')
        teardown_remove=$(grep -nF 'for owned_path in "$bypass_svc" "$bypass_timer" "$bypass_script"' "$common" \
            | awk -F: -v start="$teardown" '$1 > start { print $1; exit }')

        [ -n "$snapshot_arm" ]
        [ -n "$snapshot_stop" ]
        [ -n "$snapshot_lock" ]
        [ -n "$snapshot_parse" ]
        [ -n "$snapshot_ready" ]
        [ -n "$rollback_partial" ]
        [ -n "$rollback_array_read" ]
        [ -n "$rollback_stop" ]
        [ -n "$rollback_lock" ]
        [ -n "$rollback_parse" ]
        [ -n "$timer_publish" ]
        [ -n "$setup_release" ]
        [ "$snapshot_arm" -lt "$snapshot_stop" ]
        [ "$snapshot_stop" -lt "$snapshot_lock" ]
        [ "$snapshot_lock" -lt "$snapshot_parse" ]
        [ "$snapshot_parse" -lt "$snapshot_ready" ]
        [ "$rollback_partial" -lt "$rollback_array_read" ]
        [ "$rollback_stop" -lt "$rollback_lock" ]
        [ "$rollback_lock" -lt "$rollback_parse" ]
        [ "$timer_publish" -lt "$setup_release" ]
        [ "$setup_release" -lt "$first_service" ]
        [ "$first_service" -lt "$timer_enable" ]
        [ -n "$teardown_snapshot" ]
        [ -n "$teardown_lock" ]
        [ -n "$teardown_parse" ]
        [ -n "$teardown_absent" ]
        [ -n "$teardown_remove" ]
        [ "$teardown_snapshot" -lt "$teardown_lock" ]
        [ "$teardown_lock" -lt "$teardown_parse" ]
        [ "$teardown_parse" -lt "$teardown_absent" ]
        [ "$teardown_absent" -lt "$teardown_remove" ]
        grep -qF '&& "${_AWG_BYPASS_TX_EXPECT_CURRENT_ABSENT:-0}" -ne 1 ]]; then' "$common"
        grep -qF '_AWG_BYPASS_TX_TIMER_QUIESCE_STARTED=1' "$common"
        grep -qF '_AWG_BYPASS_TX_SERVICE_QUIESCE_STARTED=1' "$common"
        grep -qF '_release_warp_bypass_snapshot_lock || failed=1' "$common"
        grep -qF 'snapshot failure; transaction left pending.' "$common"
        grep -qF '# Keep the refresh flock across bundle publication.' "$common"
        [ "$(grep -cF 'bypass_lock_fd="$_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD"' "$common")" -eq 2 ]
        [ "$(grep -cF '_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD="$bypass_lock_fd"' "$common")" -eq 1 ]
        grep -qF 'OnActiveSec=10min' "$common"
        ! grep -qF 'OnBootSec=' "$common"

        grep -qF 'Active wg-quick@${iface} has no restorable regular config at $conf.' "$common"
        grep -qF 'Active $warp_unit has no restorable regular config at $warp_conf.' "$common"
    done

    local installer
    for installer in \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh" \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        grep -qF '_valid_warp_bypass_route_iface "$main_nic" || return 1' "$installer"
        grep -qF 'main_defaults=$(ip -o -4 route show table main default 2>/dev/null) || return 1' "$installer"
        grep -qF '(( ${#seen[@]} == ${#_INSTALL_VALIDATED_WARP_ROUTES[@]} )) || return 1' "$installer"
        grep -qF 'verify_fork_egress_runtime 1 \' "$installer"
    done
}

@test "AmneziaDNS rollback never restarts a unit over an unrestored file (static)" {
    local common rollback setup conf_restore resolved_restore resolved_guard resolved_unit conf_guard dns_unit
    for common in \
        "$BATS_TEST_DIRNAME/../awg_common.sh" \
        "$BATS_TEST_DIRNAME/../awg_common_en.sh"; do
        rollback=$(grep -n '^rollback_amnezia_dns_state()' "$common" | cut -d: -f1)
        setup=$(grep -n '^setup_amnezia_dns()' "$common" | cut -d: -f1)
        conf_restore=$(grep -nF 'if _amnezia_dns_restore_file "$conf_file"' "$common" \
            | awk -F: -v start="$rollback" -v end="$setup" '$1 > start && $1 < end { print $1; exit }')
        resolved_restore=$(grep -nF 'if _amnezia_dns_restore_file "$resolved_file"' "$common" \
            | awk -F: -v start="$rollback" -v end="$setup" '$1 > start && $1 < end { print $1; exit }')
        resolved_guard=$(grep -nF 'if [[ "$resolved_restored" -eq 1 ]]; then' "$common" \
            | awk -F: -v start="$rollback" -v end="$setup" '$1 > start && $1 < end { print $1; exit }')
        resolved_unit=$(grep -nF '_amnezia_dns_restore_unit_state systemd-resolved' "$common" \
            | awk -F: -v start="$rollback" -v end="$setup" '$1 > start && $1 < end { print $1; exit }')
        conf_guard=$(grep -nF 'if [[ "$conf_restored" -eq 1 ]]; then' "$common" \
            | awk -F: -v start="$rollback" -v end="$setup" '$1 > start && $1 < end { print $1; exit }')
        dns_unit=$(grep -nF '_amnezia_dns_restore_unit_state dnsmasq' "$common" \
            | awk -F: -v start="$rollback" -v end="$setup" '$1 > start && $1 < end { print $1; exit }')

        [ -n "$conf_restore" ]
        [ -n "$resolved_restore" ]
        [ -n "$resolved_guard" ]
        [ -n "$resolved_unit" ]
        [ -n "$conf_guard" ]
        [ -n "$dns_unit" ]
        [ "$resolved_restore" -lt "$resolved_guard" ]
        [ "$resolved_guard" -lt "$resolved_unit" ]
        [ "$conf_restore" -lt "$conf_guard" ]
        [ "$conf_guard" -lt "$dns_unit" ]
        grep -qF 'systemctl stop systemd-resolved >/dev/null 2>&1 || true' "$common"
        grep -qF 'systemctl is-active --quiet systemd-resolved 2>/dev/null && failed=1' "$common"
        grep -qF 'systemctl stop dnsmasq >/dev/null 2>&1 || true' "$common"
        grep -qF 'systemctl is-active --quiet dnsmasq 2>/dev/null && failed=1' "$common"
    done
}

@test "installer commits WARP bypass and DNS in one signal-safe transaction (static)" {
    local installer
    local bypass_snapshot bypass_setup bypass_verify dns_snapshot dns_setup
    local disarm_awg0 commit_bypass commit_warp commit_dns parked_disarm
    local restore_int restore_term deferred_cleanup
    for installer in \
        "$BATS_TEST_DIRNAME/../install_amneziawg.sh" \
        "$BATS_TEST_DIRNAME/../install_amneziawg_en.sh"; do
        bypass_snapshot=$(grep -nF '        snapshot_warp_bypass_state \' "$installer" | tail -n1 | cut -d: -f1)
        bypass_setup=$(grep -nF '        setup_warp_bypass \' "$installer" | tail -n1 | cut -d: -f1)
        bypass_verify=$(grep -nF '        verify_fork_egress_runtime 1 \' "$installer" \
            | awk -F: -v start="$bypass_setup" '$1 > start { print $1; exit }')
        dns_snapshot=$(grep -nF '        snapshot_amnezia_dns_state \' "$installer" | tail -n1 | cut -d: -f1)
        dns_setup=$(grep -nF '        if ! setup_amnezia_dns; then' "$installer" | tail -n1 | cut -d: -f1)
        disarm_awg0=$(grep -nF '    _INSTALL_ROLLBACK_AWG0=0' "$installer" \
            | awk -F: -v start="$dns_setup" '$1 > start { print $1; exit }')
        commit_bypass=$(grep -nF '        commit_warp_bypass_state \' "$installer" | tail -n1 | cut -d: -f1)
        commit_warp=$(grep -nF '        commit_warp_egress_state \' "$installer" | tail -n1 | cut -d: -f1)
        commit_dns=$(grep -nF '        commit_amnezia_dns_state \' "$installer" | tail -n1 | cut -d: -f1)
        parked_disarm=$(grep -nF '    _INSTALL_ROLLBACK_WARP_PARKED=0' "$installer" \
            | awk -F: -v start="$commit_dns" '$1 > start { print $1; exit }')
        restore_int=$(grep -nF "    trap '_install_on_signal 130' INT" "$installer" \
            | awk -F: -v start="$parked_disarm" '$1 > start { print $1; exit }')
        restore_term=$(grep -nF "    trap '_install_on_signal 143' TERM" "$installer" \
            | awk -F: -v start="$restore_int" '$1 > start { print $1; exit }')
        deferred_cleanup=$(grep -nF '    finalize_deferred_mode_cleanup || _post_commit_cleanup_failed=1' "$installer" \
            | awk -F: -v start="$restore_term" '$1 > start { print $1; exit }')

        [ -n "$bypass_snapshot" ]
        [ -n "$bypass_setup" ]
        [ -n "$bypass_verify" ]
        [ -n "$dns_snapshot" ]
        [ -n "$dns_setup" ]
        [ -n "$disarm_awg0" ]
        [ -n "$commit_bypass" ]
        [ -n "$commit_warp" ]
        [ -n "$commit_dns" ]
        [ -n "$parked_disarm" ]
        [ -n "$restore_int" ]
        [ -n "$restore_term" ]
        [ -n "$deferred_cleanup" ]

        [ "$bypass_snapshot" -lt "$bypass_setup" ]
        [ "$bypass_setup" -lt "$bypass_verify" ]
        [ "$bypass_verify" -lt "$dns_snapshot" ]
        [ "$dns_snapshot" -lt "$dns_setup" ]
        [ "$dns_setup" -lt "$disarm_awg0" ]
        [ "$disarm_awg0" -lt "$commit_bypass" ]
        [ "$commit_bypass" -lt "$commit_warp" ]
        [ "$commit_warp" -lt "$commit_dns" ]
        [ "$commit_dns" -lt "$parked_disarm" ]
        [ "$parked_disarm" -lt "$restore_int" ]
        [ "$restore_int" -lt "$restore_term" ]
        [ "$restore_term" -lt "$deferred_cleanup" ]
    done
}
