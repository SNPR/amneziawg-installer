#!/usr/bin/env bats
# Static contracts for the feat/v3 installer transaction hardening.
#
# These checks intentionally never source or execute either installer: both
# files run top-to-bottom and contain privileged/network mutations.  The tests
# pin the safety-critical control-flow and RU/EN parity at source level.

ROOT="$BATS_TEST_DIRNAME/.."
INSTALLERS=(install_amneziawg.sh install_amneziawg_en.sh)

function_body() {
    local file="$1" name="$2"
    awk -v fn="$name" '
        $0 == fn "() {" { in_fn=1 }
        in_fn { print }
        in_fn && /^}/ { exit }
    ' "$ROOT/$file"
}

assert_has() {
    local text="$1" needle="$2" context="$3"
    [[ "$text" == *"$needle"* ]] || {
        echo "$context: missing static contract: $needle"
        return 1
    }
}

line_in_text() {
    local text="$1" needle="$2"
    printf '%s\n' "$text" | grep -nF -- "$needle" | sed -n '1s/:.*//p'
}

assert_before() {
    local text="$1" first="$2" second="$3" context="$4"
    local first_line second_line
    first_line=$(line_in_text "$text" "$first")
    second_line=$(line_in_text "$text" "$second")
    [[ -n "$first_line" && -n "$second_line" ]] || {
        echo "$context: order anchor missing: [$first] -> [$second]"
        return 1
    }
    (( first_line < second_line )) || {
        echo "$context: wrong order: [$first] must precede [$second]"
        return 1
    }
}

@test "feat/v3 RU/EN: pending mode journals reconcile current resources and reject chained transitions" {
    local file reconcile writer main_writer stop_old park finalize init
    for file in "${INSTALLERS[@]}"; do
        reconcile=$(function_body "$file" reconcile_pending_mode_markers)
        writer=$(function_body "$file" write_pending_iface_marker)
        main_writer=$(function_body "$file" write_pending_main_iface_marker)
        stop_old=$(function_body "$file" stop_pending_old_upstream_for_transition)
        park=$(function_body "$file" park_pending_warp_ownership)
        finalize=$(function_body "$file" finalize_deferred_mode_cleanup)
        init=$(function_body "$file" initialize_setup)

        assert_has "$writer" '[[ "$existing" == "$iface" ]]' "$file writer"
        assert_has "$main_writer" '[[ "$existing" == "$iface" ]]' "$file main writer"
        assert_has "$reconcile" '"$saved_role" == "entry" && "$saved_upstream" == "$iface"' "$file reconcile upstream"
        assert_has "$reconcile" '"$saved_egress" == "warp" && "$saved_warp" == "$iface"' "$file reconcile WARP"
        assert_has "$reconcile" '_install_restore_parked_warp_ownership || return 1' "$file parked restore"
        assert_has "$stop_old" '"${AWG_UPSTREAM_IFACE:-awg1}" == "$iface"' "$file current upstream guard"
        assert_has "$park" '"${AWG_WARP_IFACE:-wgcf}" == "$old_iface"' "$file current WARP guard"
        assert_has "$finalize" '"${AWG_UPSTREAM_IFACE:-awg1}" == "$old_iface"' "$file finalize upstream guard"
        assert_has "$finalize" '"${AWG_WARP_IFACE:-wgcf}" == "$old_iface"' "$file finalize WARP guard"
        assert_has "$init" '_fork_mode_transition' "$file transition journal"
        assert_has "$init" '.upstream_cleanup_pending' "$file upstream pending marker"
        assert_has "$init" '.warp_cleanup_pending' "$file WARP pending marker"
        assert_before "$init" 'reconcile_pending_mode_markers' 'AWG_ROLE="${AWG_ROLE:-single}"' "$file reconcile-before-role-defaults"
    done
}

@test "feat/v3 RU/EN: reused upstream snapshots exact state and quiesces a manual live link" {
    local file step6
    for file in "${INSTALLERS[@]}"; do
        step6=$(function_body "$file" step6_generate_configs)
        assert_has "$step6" '_INSTALL_ROLLBACK_UPSTREAM_TARGET="$_up_conf_out"' "$file upstream target snapshot"
        assert_has "$step6" '_INSTALL_ROLLBACK_UPSTREAM_BACKUP="$_up_bak"' "$file upstream config snapshot"
        assert_has "$step6" '_INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE=1' "$file upstream active snapshot"
        assert_has "$step6" '_INSTALL_ROLLBACK_UPSTREAM_WAS_LINK="$_up_live_link"' "$file upstream link snapshot"
        assert_has "$step6" '_INSTALL_ROLLBACK_UPSTREAM_WAS_ENABLED=1' "$file upstream enabled snapshot"
        assert_has "$step6" '_INSTALL_ROLLBACK_UPSTREAM=1' "$file upstream rollback arm"
        assert_has "$step6" '"$_INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE" -eq 0 && "$_up_live_link" -eq 1' "$file manual-live branch"
        assert_has "$step6" 'timeout 15 awg-quick down "$_up_conf_out"' "$file manual-live down"
        assert_has "$step6" 'ip link show dev "${AWG_UPSTREAM_IFACE:-awg1}"' "$file manual-live recheck"
        assert_before "$step6" '_INSTALL_ROLLBACK_UPSTREAM=1' 'timeout 15 awg-quick down "$_up_conf_out"' "$file arm-before-down"
        assert_before "$step6" 'timeout 15 awg-quick down "$_up_conf_out"' 'if [[ -n "${AWG_UPSTREAM_CONF:-}" ]]' "$file manual-down-before-replace"
    done
}

@test "feat/v3 RU/EN: state 7 exact owned-live resume skips namespace preflight and disruptive awg0 restart" {
    local file step7
    for file in "${INSTALLERS[@]}"; do
        step7=$(function_body "$file" step7_start_service)
        assert_has "$step7" '"${_INSTALL_INITIAL_STEP:-1}" -eq 7' "$file initial state gate"
        assert_has "$step7" 'systemctl is-active --quiet awg-quick@awg0' "$file live unit proof"
        assert_has "$step7" 'ip link show dev awg0' "$file live link proof"
        assert_has "$step7" 'validate_awg_config "$SERVER_CONF_FILE"' "$file live config validation"
        assert_has "$step7" 'timeout 10 awg-quick strip "$SERVER_CONF_FILE"' "$file live config parser proof"
        assert_has "$step7" 'verify_fork_egress_runtime 0' "$file exact fork proof"
        assert_has "$step7" '_resume_owned_live=1' "$file owned-live arm"
        assert_has "$step7" 'if [[ "$_resume_owned_live" -eq 0 ]]; then' "$file preflight skip gate"
        assert_has "$step7" 'arm_step7_upstream_rollback' "$file resumed upstream rollback arm"
        assert_has "$step7" 'if [[ "$_resume_owned_live" -eq 1 ]]; then' "$file restart skip gate"
        assert_before "$step7" 'verify_fork_egress_runtime 0' '_resume_owned_live=1' "$file verify-before-owned"
        assert_before "$step7" '_resume_owned_live=1' 'preflight_fork_policy_namespace' "$file owned-before-preflight"
        assert_before "$step7" 'if [[ "$_resume_owned_live" -eq 1 ]]; then' 'systemctl restart awg-quick@awg0' "$file skip-before-restart"
    done
}

@test "feat/v3 RU/EN: durable state 99 is written before INT/TERM traps are restored" {
    local file step7
    for file in "${INSTALLERS[@]}"; do
        step7=$(function_body "$file" step7_start_service)
        assert_has "$step7" "trap '' INT TERM" "$file signal block"
        assert_before "$step7" "trap '' INT TERM" 'snapshot_warp_bypass_state' "$file signal-block-before-early-snapshot"
        assert_before "$step7" 'commit_warp_bypass_state' '_INSTALL_ROLLBACK_WARP_PARKED=0' "$file common-commit-before-parked-disarm"
        assert_before "$step7" 'commit_warp_egress_state' '_INSTALL_ROLLBACK_WARP_PARKED=0' "$file WARP-commit-before-parked-disarm"
        assert_before "$step7" '_INSTALL_ROLLBACK_WARP_PARKED=0' 'update_state 99' "$file parked-disarm-before-state99"
        assert_before "$step7" 'update_state 99' "trap '_install_on_signal 130' INT" "$file state99-before-INT"
        assert_before "$step7" 'update_state 99' "trap '_install_on_signal 143' TERM" "$file state99-before-TERM"
    done
}

@test "feat/v3 RU/EN: policy preflight and runtime reject every earlier RPDB rule and table collision" {
    local file preflight runtime
    for file in "${INSTALLERS[@]}"; do
        preflight=$(function_body "$file" preflight_fork_policy_namespace)
        runtime=$(function_body "$file" verify_fork_egress_runtime)
        assert_has "$preflight" 'if (prio == 0)' "$file preflight priority-zero gate"
        assert_has "$runtime" 'if (prio == 0)' "$file runtime priority-zero gate"
        assert_has "$preflight" '($5 == "local" || $5 == "255")' "$file canonical local rule"
        assert_has "$runtime" 'zero_total == 1 && zero_local == 1' "$file exact local-rule count"
        assert_has "$preflight" 'else if (prio ~ /^[0-9]+$/ && (prio + 0) < (pn + 0))' "$file preflight numeric earlier-rule rejection"
        assert_has "$runtime" 'else if (prio ~ /^[0-9]+$/ && (prio + 0) < (pn + 0))' "$file runtime numeric earlier-rule rejection"
        assert_has "$preflight" '$1 == p || $1 == g { collision=1 }' "$file primary/guard collision"
        assert_has "$preflight" '($i == "lookup" || $i == "table") && $(i+1) == t' "$file preflight table collision"
        assert_has "$runtime" '($i == "lookup" || $i == "table") && $(i+1) == t' "$file runtime table ownership"
        assert_has "$runtime" 'table_lookups == 1' "$file exact table lookup count"
        assert_has "$runtime" 'primary_total == 1 && primary == 1' "$file exact primary rule count"
        assert_has "$runtime" 'guard_total == 1 && guard == 1' "$file exact guard rule count"
    done
}

@test "feat/v3 RU/EN: fork runtime requires an UP support link and rejects linkdown defaults" {
    local file route_validator bypass_validator runtime status
    for file in "${INSTALLERS[@]}"; do
        route_validator=$(function_body "$file" _validate_expected_table_default)
        bypass_validator=$(function_body "$file" validate_owned_warp_bypass_route_set)
        runtime=$(function_body "$file" verify_fork_egress_runtime)
        status=$(function_body "$file" check_service_status)
        assert_has "$route_validator" '${#fields[@]} == 4' "$file exact blackhole shape"
        assert_has "$route_validator" '${#fields[@]} == 7' "$file exact metric-default shape"
        assert_has "$route_validator" '"${fields[3]}" == "scope"' "$file canonical link scope"
        assert_has "$runtime" 'ip link show up dev "$iface"' "$file support UP proof"
        assert_has "$bypass_validator" 'ip link show up dev "$main_nic"' "$file main nexthop UP proof"
        assert_has "$bypass_validator" '[[ "$main_default" != *" linkdown"* ]]' "$file bypass linkdown rejection"
        assert_has "$bypass_validator" 'if [[ "$dst" != */* ]]; then' "$file host-route canonicalization"
        assert_has "$bypass_validator" 'dst="${dst}/32"' "$file canonical ledger host prefix"
        assert_has "$bypass_validator" '${#fields[@]} == 5' "$file exact bypass route shape"
        assert_has "$status" 'systemctl is-active --quiet awg-quick@awg0' "$file awg0 active proof"
        assert_has "$status" 'ip link show up dev awg0' "$file awg0 UP proof"
        assert_has "$runtime" '_validate_expected_table_default "$line" blackhole "" 42760' "$file blackhole default"
        assert_has "$runtime" '_validate_expected_table_default "$line" real "$iface" 10' "$file WARP real default"
        assert_has "$runtime" 'blackholes == 1 && defaults == 1' "$file exact default counts"
    done
}

@test "feat/v3 RU/EN: fork firewall postcondition covers FORWARD NAT MSS and direct bypass NAT" {
    local file firewall runtime
    for file in "${INSTALLERS[@]}"; do
        firewall=$(function_body "$file" verify_fork_firewall_runtime)
        runtime=$(function_body "$file" verify_fork_egress_runtime)
        assert_has "$firewall" 'iptables -w 5 -C FORWARD -i awg0 -o "$iface" -j ACCEPT' "$file forward egress"
        assert_has "$firewall" 'iptables -w 5 -C FORWARD -i "$iface" -o awg0' "$file forward return"
        assert_has "$firewall" '--ctstate RELATED,ESTABLISHED -j ACCEPT' "$file conntrack return"
        assert_has "$firewall" 'POSTROUTING -o "$iface" -j MASQUERADE' "$file entry NAT"
        assert_has "$firewall" 'POSTROUTING -s "$source_net" -o "$iface"' "$file WARP NAT"
        assert_has "$firewall" 'POSTROUTING -s "$source_net" -o "$main_nic"' "$file bypass direct NAT"
        assert_has "$firewall" '-t mangle -C FORWARD -o awg0 -p tcp' "$file outbound MSS"
        assert_has "$firewall" '-t mangle -C FORWARD -i awg0 -p tcp' "$file inbound MSS"
        assert_has "$firewall" '--tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss4"' "$file exact MSS"
        assert_has "$runtime" 'verify_fork_firewall_runtime "$iface" "$source_net"' "$file firewall postcondition call"
    done
}

@test "feat/v3 RU/EN: an existing bypass is transactionally reconciled before policy preflight" {
    local file step7
    for file in "${INSTALLERS[@]}"; do
        step7=$(function_body "$file" step7_start_service)
        assert_has "$step7" 'if [[ -e "$_bypass_marker" || -L "$_bypass_marker" ]]; then' "$file existing bypass gate"
        assert_has "$step7" 'snapshot_warp_bypass_state' "$file early bypass snapshot"
        assert_has "$step7" 'setup_warp_bypass' "$file early bypass setup"
        assert_has "$step7" '_bypass_tx_prepared=1' "$file prepared transaction flag"
        assert_has "$step7" 'if [[ "$_bypass_tx_prepared" -eq 0 ]]; then' "$file no double snapshot gate"
        assert_has "$step7" 'verify_fork_egress_runtime 1' "$file complete bypass postcondition"
        assert_before "$step7" 'snapshot_warp_bypass_state' 'preflight_fork_policy_namespace' "$file snapshot-before-preflight"
        assert_before "$step7" 'setup_warp_bypass' 'preflight_fork_policy_namespace' "$file setup-before-preflight"
    done
}

@test "feat/v3 RU/EN: finalize and uninstall quiesce owned tunnels before marker or config deletion" {
    local file stop finalize uninstall udp_inspect udp_delete
    for file in "${INSTALLERS[@]}"; do
        stop=$(function_body "$file" stop_owned_tunnel_runtime)
        finalize=$(function_body "$file" finalize_deferred_mode_cleanup)
        uninstall=$(function_body "$file" step_uninstall)
        udp_inspect=$(function_body "$file" _inspect_exact_ufw_udp_allow)
        udp_delete=$(function_body "$file" delete_owned_ufw_udp_allow_if_present)

        assert_has "$stop" 'systemctl stop "$unit"' "$file owned unit stop"
        assert_has "$stop" 'ip link show dev "$iface"' "$file owned live-link check"
        assert_has "$stop" '[[ -f "$conf" && ! -L "$conf" ]]' "$file regular config guard"
        assert_has "$stop" 'timeout 15 "$quick" down "$conf"' "$file manual-link down"
        assert_has "$stop" '[[ "$state" == "inactive" || "$state" == "failed" || "$state" == "unknown" ]]' "$file final unit proof"
        assert_has "$finalize" 'stop_owned_tunnel_runtime awg "$old_iface"' "$file finalize upstream stop"
        assert_has "$finalize" 'stop_owned_tunnel_runtime wg "$old_iface" "$old_conf"' "$file finalize WARP stop"
        assert_has "$uninstall" 'stop_owned_tunnel_runtime awg "$_pending_up_iface"' "$file uninstall pending upstream stop"
        assert_has "$uninstall" 'stop_owned_tunnel_runtime awg "$_up_iface"' "$file uninstall current upstream stop"
        assert_has "$uninstall" 'stop_owned_tunnel_runtime wg "$_owned_warp_iface"' "$file uninstall owned WARP stop"
        assert_has "$uninstall" '"$_saved_egress" == "warp" && "$_warp_iface" == "$_pending_warp_iface"' "$file current WARP journal"
        assert_has "$uninstall" '_install_restore_parked_warp_ownership' "$file current WARP ownership restore"
        assert_has "$uninstall" 'delete_owned_ufw_route_if_present "$_nic" "AmneziaWG Routing"' "$file exact main UFW cleanup"
        assert_has "$uninstall" 'delete_owned_ufw_udp_allow_if_present "$port_to_del" "AmneziaWG VPN"' "$file exact UDP cleanup"
        assert_has "$udp_inspect" '_INSTALL_UFW_UDP_SHAPE_COUNT' "$file UDP shape count"
        assert_has "$udp_inspect" '_INSTALL_UFW_UDP_OWNED_COUNT' "$file UDP ownership count"
        assert_has "$udp_delete" '"$_INSTALL_UFW_UDP_SHAPE_COUNT" -eq 1 && "$_INSTALL_UFW_UDP_OWNED_COUNT" -eq 1' "$file UDP exact ownership gate"
        assert_has "$udp_delete" 'comment "$comment"' "$file commented UDP deletion"
        assert_has "$uninstall" '"$_warp_service_stopped" -eq 0' "$file created-config ownership gate"
        assert_has "$uninstall" 'systemctl is-active --quiet "wg-quick@${_created_warp_iface}"' "$file created-config active guard"
        assert_has "$uninstall" 'systemctl is-enabled --quiet "wg-quick@${_created_warp_iface}"' "$file created-config enabled guard"
        assert_has "$uninstall" 'ip link show dev "$_created_warp_iface"' "$file created-config live guard"
        assert_before "$uninstall" '"$_warp_service_stopped" -eq 0' 'rm -f -- "$_owned_warp_path"' "$file guard-before-created-config-delete"
    done
}
