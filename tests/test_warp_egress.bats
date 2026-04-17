#!/usr/bin/env bats
# Tests for WARP egress branch in render_server_config.
# setup_warp_egress itself performs network I/O (GitHub, Cloudflare) and
# cannot be unit-tested offline — here we exercise only the config renderer.

# `run !` flag form requires bats-core 1.5.0+.
bats_require_minimum_version 1.5.0

load test_helper

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
    unset AWG_ROLE

    run render_server_config
    [ "$status" -eq 0 ]
    [ -f "$SERVER_CONF_FILE" ]

    # Policy-routing primitives must be present
    grep -q 'ip route replace default dev wgcf table 2408' "$SERVER_CONF_FILE"
    grep -q 'ip rule add from 10.9.9.0/24 table 2408 priority 789' "$SERVER_CONF_FILE"
    # FORWARD + MASQUERADE happen on wgcf, not on eth0
    grep -q 'iptables -I FORWARD -i %i -o wgcf -j ACCEPT' "$SERVER_CONF_FILE"
    grep -q 'iptables -t nat -A POSTROUTING -o wgcf -j MASQUERADE' "$SERVER_CONF_FILE"
    grep -q 'TCPMSS --clamp-mss-to-pmtu' "$SERVER_CONF_FILE"
    # No stray MASQUERADE on eth0 — that would bypass WARP for some packets
    run ! grep -qE 'POSTROUTING -o eth0 -j MASQUERADE' "$SERVER_CONF_FILE"

    # PreDown/PostDown must reverse every up-hook in LIFO-friendly order
    grep -q 'ip rule del from 10.9.9.0/24 table 2408 priority 789' "$SERVER_CONF_FILE"
    grep -q 'ip route del default dev wgcf table 2408' "$SERVER_CONF_FILE"
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
    export AWG_WARP_IFACE="wgcf"
    export AWG_WARP_TABLE="5555"
    export AWG_WARP_PRIORITY="1234"
    unset AWG_ROLE

    run render_server_config
    [ "$status" -eq 0 ]
    grep -q 'table 5555' "$SERVER_CONF_FILE"
    grep -q 'priority 1234' "$SERVER_CONF_FILE"
}
