#!/usr/bin/env bats
# Tests for apply_config() modes in awg_common.sh
#
# NOTE: This file uses its own setup() (not just test_helper's) because it
# needs to set up a $MOCK_BIN directory with stub systemctl/awg/awg-quick
# and source awg_common.sh directly. test_helper is still loaded for helper
# functions (require_flock etc.) but its setup() is overridden here.

load test_helper

setup() {
    # Call parent setup
    TEST_DIR=$(mktemp -d)
    export AWG_DIR="$TEST_DIR"
    export CONFIG_FILE="$TEST_DIR/awgsetup_cfg.init"
    export SERVER_CONF_FILE="$TEST_DIR/awg0.conf"
    export KEYS_DIR="$TEST_DIR/keys"
    mkdir -p "$KEYS_DIR"

    write_apply_conf "$SERVER_CONF_FILE" server
    write_apply_conf "$TEST_DIR/awg1.conf" upstream

    # Silent log stubs
    log()       { :; }
    log_warn()  { :; }
    log_error() { :; }
    log_debug() { :; }
    export -f log log_warn log_error log_debug

    # Mock PATH: create stub commands
    MOCK_BIN="$TEST_DIR/mock_bin"
    mkdir -p "$MOCK_BIN"
    export PATH="$MOCK_BIN:$PATH"

    # Stub systemctl
    cat > "$MOCK_BIN/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "${AWG_DIR}/.mock_calls"
exit 0
STUB
    chmod +x "$MOCK_BIN/systemctl"

    # Stub awg-quick
    cat > "$MOCK_BIN/awg-quick" << 'STUB'
#!/bin/bash
echo "awg-quick $*" >> "${AWG_DIR}/.mock_calls"
echo "[Interface]"
echo "PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
exit 0
STUB
    chmod +x "$MOCK_BIN/awg-quick"

    # Stub awg
    cat > "$MOCK_BIN/awg" << 'STUB'
#!/bin/bash
echo "awg $*" >> "${AWG_DIR}/.mock_calls"
exit 0
STUB
    chmod +x "$MOCK_BIN/awg"

    # Stub timeout (pass-through)
    cat > "$MOCK_BIN/timeout" << 'STUB'
#!/bin/bash
shift  # skip timeout value
"$@"
STUB
    chmod +x "$MOCK_BIN/timeout"

    source "$BATS_TEST_DIRNAME/../awg_common.sh"
}

write_apply_conf() {
    local path="$1"
    local mode="${2:-server}" quick_fields
    if [[ "$mode" == upstream ]]; then
        quick_fields=$'Table = 123\nFwMark = 0xca6d\nPostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE\nPreDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE'
    else
        quick_fields='ListenPort = 51820'
    fi
    cat > "$path" << CONF
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Address = 10.9.0.2/32
MTU = 1380
${quick_fields}
Jc = 5
Jmin = 50
Jmax = 300
S1 = 50
S2 = 100
S3 = 18
S4 = 16
H1 = 100000-200000
H2 = 300000-400000
H3 = 500000-600000
H4 = 700000-800000

[Peer]
PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBA=
Endpoint = 198.51.100.20:51820
AllowedIPs = 0.0.0.0/0
CONF
}

teardown() {
    rm -rf "$TEST_DIR"
}

@test "apply_config: AWG_SKIP_APPLY=1 returns 0 without calling anything" {
    export AWG_SKIP_APPLY=1
    run apply_config
    [ "$status" -eq 0 ]
    [ ! -f "$AWG_DIR/.mock_calls" ]
}

@test "apply_config: AWG_APPLY_MODE=restart calls systemctl restart" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart
    run apply_config
    [ "$status" -eq 0 ]
    grep -qx "awg-quick strip $SERVER_CONF_FILE" "$AWG_DIR/.mock_calls"
    grep -q "systemctl restart awg-quick@awg0" "$AWG_DIR/.mock_calls"
    grep -q "systemctl is-active --quiet awg-quick@awg0" "$AWG_DIR/.mock_calls"
}

@test "apply_config: default mode calls awg-quick strip + awg syncconf" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    run apply_config
    [ "$status" -eq 0 ]
    grep -qx "awg-quick strip $SERVER_CONF_FILE" "$AWG_DIR/.mock_calls"
    grep -qx "awg syncconf awg0 /dev/stdin" "$AWG_DIR/.mock_calls"
}

@test "apply_config: custom iface is preflighted by path and restarted" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf

    run apply_config awg1
    [ "$status" -eq 0 ]
    grep -qx "awg-quick strip $TEST_DIR/awg1.conf" "$AWG_DIR/.mock_calls"
    grep -qx "systemctl restart awg-quick@awg1" "$AWG_DIR/.mock_calls"
    grep -qx "systemctl is-active --quiet awg-quick@awg1" "$AWG_DIR/.mock_calls"
    ! grep -q "awg syncconf awg1" "$AWG_DIR/.mock_calls"
}

@test "apply_config: custom iface restart targets its own systemd unit" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart

    run apply_config awg1
    [ "$status" -eq 0 ]
    grep -qx "systemctl restart awg-quick@awg1" "$AWG_DIR/.mock_calls"
    ! grep -q "awg-quick@awg0" "$AWG_DIR/.mock_calls"
}

@test "apply_config: strip failure is non-disruptive for a custom iface" {
    require_flock
    cat > "$MOCK_BIN/awg-quick" << 'STUB'
#!/bin/bash
echo "awg-quick $*" >> "${AWG_DIR}/.mock_calls"
exit 1
STUB
    chmod +x "$MOCK_BIN/awg-quick"

    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    run apply_config awg1
    [ "$status" -ne 0 ]
    grep -qx "awg-quick strip $TEST_DIR/awg1.conf" "$AWG_DIR/.mock_calls"
    ! grep -q "systemctl" "$AWG_DIR/.mock_calls"
}

@test "apply_config: applying awg1 does not overwrite awg0 device-param state" {
    require_flock
    printf '%s\n' "H1 I1 Jc S1" > "$AWG_DIR/.awg_device_params"
    cat > "$SERVER_CONF_FILE" << 'CONF'
[Interface]
Jc = 6
S1 = 72
H1 = 100000-800000
CONF

    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    run apply_config awg1
    [ "$status" -eq 0 ]
    [ "$(cat "$AWG_DIR/.awg_device_params")" = "H1 I1 Jc S1" ]
}

@test "apply_config: rejects an unsafe custom iface before invoking tools" {
    export AWG_SKIP_APPLY=0
    run apply_config 'awg1;id'
    [ "$status" -ne 0 ]
    [ ! -f "$AWG_DIR/.mock_calls" ]
}

@test "apply_config: rejects a custom config with multiple Peer sections before strip" {
    cat >> "$TEST_DIR/awg1.conf" << 'CONF'

[Peer]
PublicKey = CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCA=
Endpoint = 203.0.113.20:51820
AllowedIPs = 0.0.0.0/0
CONF
    export AWG_SKIP_APPLY=0
    run apply_config awg1
    [ "$status" -ne 0 ]
    [ ! -f "$AWG_DIR/.mock_calls" ]
}

@test "apply_config: typed custom preflight rejects malformed quick and AWG3 fields without disruption" {
    require_flock
    local field
    for field in Address AddressLeadingZero Endpoint EndpointLeadingZero AllowedIPs Table FwMark MTU DNS ListenPort EmptyListenPort SaveConfig PostUp RekeyTimeout EmptyRekeyTimeout HeaderProtectionKey EmptyHeaderProtectionKey; do
        write_apply_conf "$TEST_DIR/awg1.conf" upstream
        rm -f "$AWG_DIR/.mock_calls"
        case "$field" in
            Address) sed -i 's|^Address = .*|Address = 999.1.1.1/32|' "$TEST_DIR/awg1.conf" ;;
            AddressLeadingZero) sed -i 's|^Address = .*|Address = 010.009.000.002/32|' "$TEST_DIR/awg1.conf" ;;
            Endpoint) sed -i 's|^Endpoint = .*|Endpoint = 198.51.100.20:99999|' "$TEST_DIR/awg1.conf" ;;
            EndpointLeadingZero) sed -i 's|^Endpoint = .*|Endpoint = 010.009.000.002:51820|' "$TEST_DIR/awg1.conf" ;;
            AllowedIPs) sed -i 's|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/33|' "$TEST_DIR/awg1.conf" ;;
            Table) sed -i 's|^Table = .*|Table = 124|' "$TEST_DIR/awg1.conf" ;;
            FwMark) sed -i 's|^FwMark = .*|FwMark = 0xca6e|' "$TEST_DIR/awg1.conf" ;;
            MTU) sed -i 's|^MTU = .*|MTU = 12|' "$TEST_DIR/awg1.conf" ;;
            DNS) sed -i '/^MTU =/a DNS = 1.1.1.1' "$TEST_DIR/awg1.conf" ;;
            ListenPort) sed -i '/^MTU =/a ListenPort = 51820' "$TEST_DIR/awg1.conf" ;;
            EmptyListenPort) sed -i '/^MTU =/a ListenPort =' "$TEST_DIR/awg1.conf" ;;
            SaveConfig) sed -i '/^MTU =/a SaveConfig = true' "$TEST_DIR/awg1.conf" ;;
            PostUp) sed -i 's|^PostUp = .*|PostUp = false|' "$TEST_DIR/awg1.conf" ;;
            RekeyTimeout) sed -i '/^\[Peer\]/i RekeyTimeout = 9-3' "$TEST_DIR/awg1.conf" ;;
            EmptyRekeyTimeout) sed -i '/^\[Peer\]/i RekeyTimeout =' "$TEST_DIR/awg1.conf" ;;
            HeaderProtectionKey) sed -i '/^\[Peer\]/i HeaderProtectionKey = not-a-key' "$TEST_DIR/awg1.conf" ;;
            EmptyHeaderProtectionKey) sed -i '/^\[Peer\]/i HeaderProtectionKey =' "$TEST_DIR/awg1.conf" ;;
        esac

        run apply_config awg1
        [ "$status" -ne 0 ]
        [ ! -f "$AWG_DIR/.mock_calls" ]
    done
}

@test "apply_config: malformed awg0 fails before restart or strip" {
    require_flock
    sed -i 's|^AllowedIPs = .*|AllowedIPs = 0.0.0.0/99|' "$SERVER_CONF_FILE"
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart

    run apply_config awg0
    [ "$status" -ne 0 ]
    [ ! -f "$AWG_DIR/.mock_calls" ]
}

@test "apply_config: non-canonical IPv4 in awg0 fails before restart or strip" {
    require_flock
    sed -i 's|^AllowedIPs = .*|AllowedIPs = 010.009.000.002/32|' "$SERVER_CONF_FILE"
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart

    run apply_config awg0
    [ "$status" -ne 0 ]
    [ ! -f "$AWG_DIR/.mock_calls" ]
}

@test "apply_config: unknown mode falls through to syncconf" {
    require_flock
    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=invalid_mode
    run apply_config
    [ "$status" -eq 0 ]
    grep -qx "awg-quick strip $SERVER_CONF_FILE" "$AWG_DIR/.mock_calls"
}

@test "apply_config: flock failure returns 1" {
    require_flock
    # Mock flock to always return 1, simulating lock acquisition failure
    # (e.g. timeout waiting for .awg_apply.lock held by another process).
    # Precondition: $AWG_DIR exists (guaranteed by setup's TEST_DIR=$(mktemp -d)),
    # so exec {apply_fd}>"$apply_lockfile" succeeds and the flock binary is called.
    # apply_config() makes exactly one flock call; returning 1 here exercises
    # the "! flock -x -w 120 $apply_fd → return 1" path in awg_common.sh.
    cat > "$MOCK_BIN/flock" << 'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$MOCK_BIN/flock"

    export AWG_SKIP_APPLY=0
    run apply_config
    [ "$status" -eq 1 ]
}

@test "apply_config: systemctl restart failure returns non-zero" {
    require_flock
    # Override systemctl stub to exit 1 (simulate restart failure)
    cat > "$MOCK_BIN/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "${AWG_DIR}/.mock_calls"
exit 1
STUB
    chmod +x "$MOCK_BIN/systemctl"

    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart
    run apply_config
    [ "$status" -ne 0 ]
}

@test "apply_config: restart success still requires an active unit" {
    require_flock
    cat > "$MOCK_BIN/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "${AWG_DIR}/.mock_calls"
[[ "$1" != "is-active" ]]
STUB
    chmod +x "$MOCK_BIN/systemctl"

    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=restart
    run apply_config
    [ "$status" -ne 0 ]
    grep -qx "systemctl is-active --quiet awg-quick@awg0" "$AWG_DIR/.mock_calls"
}

@test "apply_config: syncconf failure never falls back to restart" {
    require_flock
    cat > "$MOCK_BIN/awg" << 'STUB'
#!/bin/bash
echo "awg $*" >> "${AWG_DIR}/.mock_calls"
exit 1
STUB
    chmod +x "$MOCK_BIN/awg"

    export AWG_SKIP_APPLY=0
    export AWG_APPLY_MODE=syncconf
    run apply_config
    [ "$status" -ne 0 ]
    grep -qx "awg syncconf awg0 /dev/stdin" "$AWG_DIR/.mock_calls"
    ! grep -q "systemctl" "$AWG_DIR/.mock_calls"
}
