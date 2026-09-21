#!/bin/bash

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# AmneziaWG 2.0 installation and configuration script for Ubuntu/Debian servers
# Author: @bivlked
# Version: 5.28.1
# Date: 2026-08-27
# Fork: https://github.com/SNPR/amneziawg-installer (upstream: bivlked)
# ==============================================================================

# --- Safe mode and Constants ---
set -o pipefail
SCRIPT_VERSION="5.28.1"

AWG_DIR="/root/awg"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
STATE_FILE="$AWG_DIR/setup_state"
BOOT_CRITICAL_SNAPSHOT_FILE="$AWG_DIR/boot-critical.pkgs"
LOG_FILE="$AWG_DIR/install_amneziawg.log"
KEYS_DIR="$AWG_DIR/keys"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
AWG0_DEPENDENCY_DROPIN="/etc/systemd/system/awg-quick@awg0.service.d/10-awgchain-dependency.conf"
AWG0_DEPENDENCY_MARKER="$AWG_DIR/.awg0_dependency_created_by_installer"
PINNED_HELPERS_REPOSITORY="SNPR/amneziawg-installer"
PINNED_HELPERS_REF="feat/v3"
AWG_REPOSITORY="${AWG_REPOSITORY:-$PINNED_HELPERS_REPOSITORY}"
AWG_BRANCH="${AWG_BRANCH:-$PINNED_HELPERS_REF}"
COMMON_SCRIPT_URL="https://raw.githubusercontent.com/${AWG_REPOSITORY}/${AWG_BRANCH}/awg_common_en.sh"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/${AWG_REPOSITORY}/${AWG_BRANCH}/manage_amneziawg_en.sh"
MANAGE_SCRIPT_PATH="$AWG_DIR/manage_amneziawg.sh"

# Installer's own directory — captured BEFORE any cd happens. step5 uses it
# to detect "run from a clone" and pick up awg_common.sh / manage_amneziawg.sh
# locally instead of fetching from the CDN. A late BASH_SOURCE[0] resolve
# AFTER initialize_setup has cd'd to $AWG_DIR would return $AWG_DIR and break
# the detection for any `sudo bash install_amneziawg.sh` invocation from the
# clone directory.
INSTALLER_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || INSTALLER_DIR=""
fi

# SHA256 checksums of downloaded scripts. Updated at each release.
# Verified in step5_download_scripts() after curl.
# Verification is skipped when AWG_REPOSITORY/AWG_BRANCH is overridden; the
# local pins cover only the published fork branch feat/v3.
# Format: sha256sum output (hex, 64 chars).
COMMON_SCRIPT_SHA256="e896670ecdae5cb7eb70b41374918afa590da0d6c24b06496d217eb57c6763e9"
MANAGE_SCRIPT_SHA256="a9d5d24746feb835ca9246cc6ed915606c594d5c46ba0e22e59acad93b7a1f74"

# AmneziaWG 2.0 pin (H0, 31 jul 2026). Upstream merged AmneziaWG 3.0 into the
# amneziawg-linux-kernel-module default branch, and the PPA switched to it. Back
# then the PPA DKMS build failed on nla_put_uint on kernels older than 6.7
# (Debian 12 = 6.1). Upstream fixed that the same evening on 31 jul
# (v3.0.20260731-04; verified by us on Debian 12 / 6.1.0-51 on 1 aug), so the pin
# went from FORCED to DELIBERATE: on older kernels we keep the module we have
# tested until 3.0 is validated separately. AWG2_PIN_COMMIT is checked after clone
# (integrity: more robust than a fragile tarball SHA - a tag can be moved, an
# immutable commit cannot).
AWG2_PIN_TAG="v1.0.20260725"
AWG2_PIN_COMMIT="ae0924ca700520ca34c5bdbcfd05b2f683ea9353"

# CLI flags
UNINSTALL=0; HELP=0; HELP_EXIT_RC=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; AUTO_YES=0; NO_TWEAKS=0; NO_CPS=0; KEEP_PACKAGES=""
FORCE_REINSTALL=0
_APT_UPDATED=0
CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"; CLI_SSH_PORT=""; CLI_I1_MODE=""
CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES=""; CLI_ENDPOINT=""; CLI_NO_TWEAKS=0; CLI_NO_CPS=0; CLI_KEEP_PACKAGES=0
# Multi-hop / cascade: node role and upstream tunnel parameters (for role=entry)
CLI_ROLE=""; CLI_UPSTREAM_CONF=""; CLI_UPSTREAM_IFACE=""
CLI_UPSTREAM_TABLE=""; CLI_UPSTREAM_FWMARK=""
# WARP egress: route client traffic through Cloudflare WARP (for role=exit|single)
CLI_EGRESS=""; CLI_WARP_IFACE=""; CLI_WARP_TABLE=""; CLI_WARP_PRIORITY=""; CLI_WARP_BYPASS=""
# AmneziaDNS: local dnsmasq on the tunnel gateway + "native" Amnezia vpn:// URI
CLI_AMNEZIA_DNS=""
# Optional dual-stack IPv6 inside the tunnel (upstream v5.15.0)
CLI_ALLOW_IPV6_TUNNEL="default"
CLI_ISOLATION="default"
CLI_SERVER_NAME=""
CLI_MOBILE=0

# --- Auto-cleanup of temporary files ---
_install_temp_files=()
_install_temp_dirs=()
_install_cleaned=0
_INSTALL_ROLLBACK_AWG0=0
_INSTALL_ROLLBACK_SERVER_BACKUP=""
_INSTALL_ROLLBACK_SERVER_EXISTED=0
_INSTALL_ROLLBACK_AWG0_WAS_ACTIVE=0
_INSTALL_ROLLBACK_AWG0_WAS_LINK=0
_INSTALL_ROLLBACK_AWG0_WAS_ENABLED=0
_INSTALL_ROLLBACK_DEP_ACTIVE=0
_INSTALL_ROLLBACK_DEP_EXISTED=0
_INSTALL_ROLLBACK_DEP_BACKUP=""
_INSTALL_ROLLBACK_WARP_PARKED=0
_INSTALL_ROLLBACK_UPSTREAM=0
_INSTALL_ROLLBACK_UPSTREAM_TARGET=""
_INSTALL_ROLLBACK_UPSTREAM_BACKUP=""
_INSTALL_ROLLBACK_UPSTREAM_EXISTED=0
_INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE=0
_INSTALL_ROLLBACK_UPSTREAM_WAS_LINK=0
_INSTALL_ROLLBACK_UPSTREAM_WAS_ENABLED=0
_INSTALL_ROLLBACK_OLD_SUPPORT=0
_INSTALL_ROLLBACK_OLD_SUPPORT_IFACE=""
_INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ACTIVE=0
_INSTALL_ROLLBACK_OLD_SUPPORT_WAS_LINK=0
_INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ENABLED=0
_INSTALL_ROLLBACK_UFW_MAIN_RULE=0
_INSTALL_ROLLBACK_UFW_MAIN_IFACE=""
_INSTALL_ROLLBACK_UFW_CASCADE_RULE=0
_INSTALL_ROLLBACK_UFW_CASCADE_IFACE=""
_INSTALL_UFW_MAIN_MARKER_RESOLVED=0
_INSTALL_INITIAL_STEP=1
declare -A _INSTALL_VALIDATED_WARP_ROUTES=()

_install_restore_upstream_config() {
    [[ "$_INSTALL_ROLLBACK_UPSTREAM" -eq 1 ]] || return 0
    local target="$_INSTALL_ROLLBACK_UPSTREAM_TARGET" iface="" unit="" state="" iface_present=0 tmp=""
    [[ "$target" =~ ^/etc/amnezia/amneziawg/([a-zA-Z][a-zA-Z0-9_-]{0,14})\.conf$ ]] || {
        printf '[ERROR] Invalid upstream rollback target: %s\n' "$target" >&2
        return 1
    }
    iface="${BASH_REMATCH[1]}"
    [[ "$iface" != "awg0" ]] || {
        printf '[ERROR] Refusing to use awg0 as an upstream rollback target.\n' >&2
        return 1
    }
    unit="awg-quick@${iface}"
    command -v ip >/dev/null 2>&1 || {
        printf '[ERROR] ip is unavailable; live upstream state cannot be checked, so config was NOT overwritten.\n' >&2
        return 1
    }
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    command -v ip >/dev/null 2>&1 && ip link show dev "$iface" >/dev/null 2>&1 \
        && iface_present=1
    if [[ "$state" =~ ^(active|activating|deactivating|reloading)$ || "$iface_present" -eq 1 ]]; then
        if [[ "$state" =~ ^(active|activating|deactivating|reloading)$ ]]; then
            systemctl stop "$unit" >/dev/null 2>&1 || {
                printf '[ERROR] Could not stop the new upstream %s; its live config was NOT overwritten. Backup: %s\n' \
                    "$iface" "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" >&2
                return 1
            }
        fi
        iface_present=0
        command -v ip >/dev/null 2>&1 && ip link show dev "$iface" >/dev/null 2>&1 \
            && iface_present=1
        if [[ "$iface_present" -eq 1 ]] \
           && { [[ ! -f "$target" || -L "$target" ]] \
                || ! timeout 15 awg-quick down "$target" >/dev/null 2>&1; }; then
            printf '[ERROR] Could not bring down the new upstream %s; its live config was NOT overwritten. Backup: %s\n' \
                "$iface" "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" >&2
            return 1
        fi
        if command -v ip >/dev/null 2>&1 && ip link show dev "$iface" >/dev/null 2>&1; then
            printf '[ERROR] New upstream %s is still live; its config was NOT overwritten.\n' "$iface" >&2
            return 1
        fi
    elif [[ "$state" != "inactive" && "$state" != "failed" && "$state" != "unknown" ]]; then
        printf '[ERROR] Could not determine upstream %s state; live config was NOT overwritten.\n' "$iface" >&2
        return 1
    fi

    if [[ "$_INSTALL_ROLLBACK_UPSTREAM_EXISTED" -eq 1 ]]; then
        [[ -f "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" && ! -L "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" ]] \
            || { printf '[ERROR] Upstream rollback backup is missing: %s\n' "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" >&2; return 1; }
        tmp=$(mktemp -p "$(dirname "$target")" '.upstream.rollback.XXXXXX' 2>/dev/null) || tmp=""
        [[ -n "$tmp" ]] && cp -- "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" "$tmp" \
            && chmod 600 "$tmp" && mv -f -- "$tmp" "$target" || {
                rm -f -- "$tmp" 2>/dev/null || true
                printf '[ERROR] Could not atomically restore upstream config from %s\n' \
                    "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" >&2
                return 1
            }
    else
        rm -f -- "$target" || { printf '[ERROR] Could not remove new upstream config %s\n' "$target" >&2; return 1; }
    fi

    if [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_ENABLED" -eq 1 ]]; then
        systemctl enable "$unit" >/dev/null 2>&1 || return 1
    else
        systemctl disable "$unit" >/dev/null 2>&1 || return 1
    fi
    if [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start "$unit" >/dev/null 2>&1 || {
            printf '[ERROR] Previous upstream %s was restored but did not start.\n' "$iface" >&2
            return 1
        }
    elif [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_LINK" -eq 1 ]]; then
        timeout 15 awg-quick up "$target" >/dev/null 2>&1 || {
            printf '[ERROR] Previous manually-raised upstream %s was restored on disk but did not come up.\n' "$iface" >&2
            return 1
        }
    fi
    _INSTALL_ROLLBACK_UPSTREAM=0
    return 0
}

# During a role switch the previous installer-owned upstream must be stopped
# before the new awg0 starts, otherwise its policy route keeps affecting the
# new mode. Only exact runtime/autostart state is restored here; its config and
# ownership marker are retained untouched until post-commit cleanup.
_install_restore_stopped_old_support() {
    [[ "$_INSTALL_ROLLBACK_OLD_SUPPORT" -eq 1 ]] || return 0
    local iface="$_INSTALL_ROLLBACK_OLD_SUPPORT_IFACE"
    local unit="awg-quick@${iface}" conf="/etc/amnezia/amneziawg/${iface}.conf"
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$iface" != "awg0" ]] || {
        printf '[ERROR] Invalid previous-upstream iface during rollback: %s\n' "$iface" >&2
        return 1
    }
    if [[ "$_INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ENABLED" -eq 1 ]]; then
        systemctl enable "$unit" >/dev/null 2>&1 || return 1
    else
        systemctl disable "$unit" >/dev/null 2>&1 || return 1
    fi
    if [[ "$_INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start "$unit" >/dev/null 2>&1 || {
            printf '[ERROR] Could not restart the previous upstream %s.\n' "$iface" >&2
            return 1
        }
    elif [[ "$_INSTALL_ROLLBACK_OLD_SUPPORT_WAS_LINK" -eq 1 ]]; then
        [[ -f "$conf" && ! -L "$conf" ]] \
            && timeout 15 awg-quick up "$conf" >/dev/null 2>&1 || {
                printf '[ERROR] Could not restore manually started previous upstream %s.\n' "$iface" >&2
                return 1
            }
    fi
    _INSTALL_ROLLBACK_OLD_SUPPORT=0
    return 0
}

_install_restore_awg0_dependency() {
    [[ "$_INSTALL_ROLLBACK_DEP_ACTIVE" -eq 1 ]] || return 0
    local target_dir="" tmp="" marker_tmp="" marker_value=""
    target_dir=$(dirname "$AWG0_DEPENDENCY_DROPIN")
    if [[ "$_INSTALL_ROLLBACK_DEP_EXISTED" -eq 1 ]]; then
        [[ -f "$_INSTALL_ROLLBACK_DEP_BACKUP" && ! -L "$_INSTALL_ROLLBACK_DEP_BACKUP" ]] || return 1
        mkdir -p "$target_dir" || return 1
        tmp=$(mktemp -p "$target_dir" '.dependency.rollback.XXXXXX') || return 1
        cp -p -- "$_INSTALL_ROLLBACK_DEP_BACKUP" "$tmp" \
            && mv -f -- "$tmp" "$AWG0_DEPENDENCY_DROPIN" || { rm -f -- "$tmp"; return 1; }
        marker_tmp=$(mktemp -p "$AWG_DIR" '.dependency-marker.rollback.XXXXXX') || return 1
        printf '%s\n' "$AWG0_DEPENDENCY_DROPIN" > "$marker_tmp" \
            && chmod 600 "$marker_tmp" \
            && mv -f -- "$marker_tmp" "$AWG0_DEPENDENCY_MARKER" \
            || { rm -f -- "$marker_tmp"; return 1; }
    else
        if [[ -e "$AWG0_DEPENDENCY_MARKER" || -L "$AWG0_DEPENDENCY_MARKER" ]]; then
            [[ -f "$AWG0_DEPENDENCY_MARKER" && ! -L "$AWG0_DEPENDENCY_MARKER" ]] || return 1
            IFS= read -r marker_value < "$AWG0_DEPENDENCY_MARKER" || marker_value=""
            [[ "$marker_value" == "$AWG0_DEPENDENCY_DROPIN" ]] || return 1
        fi
        [[ ! -L "$AWG0_DEPENDENCY_DROPIN" ]] || return 1
        rm -f -- "$AWG0_DEPENDENCY_DROPIN" "$AWG0_DEPENDENCY_MARKER" || return 1
        rmdir "$target_dir" 2>/dev/null || true
    fi
    systemctl daemon-reload >/dev/null 2>&1 || return 1
    _INSTALL_ROLLBACK_DEP_ACTIVE=0
    return 0
}

_install_restore_ufw_main_rule() {
    [[ "$_INSTALL_ROLLBACK_UFW_MAIN_RULE" -eq 1 ]] || return 0
    local iface="$_INSTALL_ROLLBACK_UFW_MAIN_IFACE"
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,14}$ ]] || return 1
    command -v ufw >/dev/null 2>&1 || return 1
    _inspect_exact_ufw_route "$iface" "AmneziaWG Routing" || return 1
    if [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 1 && "$_INSTALL_UFW_ROUTE_OWNED_COUNT" -eq 1 ]]; then
        _INSTALL_ROLLBACK_UFW_MAIN_RULE=0
        return 0
    fi
    [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 0 ]] || return 1
    ufw route allow in on awg0 out on "$iface" comment "AmneziaWG Routing" >/dev/null 2>&1 \
        || return 1
    _inspect_exact_ufw_route "$iface" "AmneziaWG Routing" \
        && [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 1 \
              && "$_INSTALL_UFW_ROUTE_OWNED_COUNT" -eq 1 ]] || return 1
    _INSTALL_ROLLBACK_UFW_MAIN_RULE=0
    return 0
}

# When the WARP interface name changes, old ownership is moved temporarily to
# dedicated markers. This frees the regular names for the new iface without
# losing ownership of the old resources. EXIT rollback restores a marker only
# when a new resource has not occupied its regular name.
_install_restore_parked_warp_ownership() {
    local -a live_markers=(
        "$AWG_DIR/.wgcf_enabled_by_installer"
        "$AWG_DIR/.wgcf_config_created_by_installer"
        "$AWG_DIR/.wgcf_config_managed_by_installer"
    )
    local -a parked_markers=(
        "$AWG_DIR/.warp_cleanup_service_owner"
        "$AWG_DIR/.warp_cleanup_created_config_owner"
        "$AWG_DIR/.warp_cleanup_managed_config_owner"
    )
    local i live parked parked_value live_value failed=0
    for i in "${!live_markers[@]}"; do
        live="${live_markers[$i]}"
        parked="${parked_markers[$i]}"
        [[ -e "$parked" || -L "$parked" ]] || continue
        if [[ ! -f "$parked" || -L "$parked" ]]; then
            printf '[ERROR] Unsafe parked WARP ownership marker retained: %s\n' "$parked" >&2
            failed=1
            continue
        fi
        IFS= read -r parked_value < "$parked" || parked_value=""
        if [[ ! -e "$live" && ! -L "$live" ]]; then
            mv -f -- "$parked" "$live" 2>/dev/null \
                || { printf '[ERROR] Could not restore WARP ownership marker %s\n' "$live" >&2; failed=1; }
        elif [[ -f "$live" && ! -L "$live" ]]; then
            IFS= read -r live_value < "$live" || live_value=""
            if [[ "$live_value" == "$parked_value" ]]; then
                rm -f -- "$parked" 2>/dev/null || failed=1
            else
                printf '[WARN] New WARP ownership already occupies %s; old ownership remains in %s\n' \
                    "$live" "$parked" >&2
                failed=1
            fi
        else
            printf '[WARN] Cannot safely restore WARP ownership to %s; old marker remains in %s\n' \
                "$live" "$parked" >&2
            failed=1
        fi
    done
    [[ "$failed" -eq 0 ]] && _INSTALL_ROLLBACK_WARP_PARKED=0
    return "$failed"
}

_install_cleanup() {
    # Idempotent: on INT/TERM it is called from the signal handler, then again on
    # EXIT - the second call must be a no-op.
    [[ "$_install_cleaned" -eq 1 || "$_install_cleaned" -eq 2 ]] && return 0
    _install_cleaned=1
    local rollback_attempted=0 rollback_can_restore=1 rollback_config_restored=0
    local rollback_state="" rollback_iface_present=0 rollback_tmp="" rollback_state_tmp=""

    # Arm the transaction for every target awg0.conf: an inactive previous
    # config as well as a first install. If the new awg0 came up, always run
    # its NEW PostDown before restoring/removing that file. Any uncertainty
    # leaves the live config untouched.
    if [[ "$_INSTALL_ROLLBACK_AWG0" -eq 1 ]]; then
        rollback_attempted=1
        if ! command -v ip >/dev/null 2>&1; then
            rollback_can_restore=0
            printf '[ERROR] ip is unavailable; live awg0 cannot be checked, so config was NOT overwritten.\n' >&2
        fi
        rollback_state=$(systemctl is-active awg-quick@awg0 2>/dev/null || true)
        command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1 \
            && rollback_iface_present=1
        if [[ "$rollback_can_restore" -eq 1 \
              && "$rollback_state" =~ ^(active|activating|deactivating|reloading)$ ]]; then
            if ! systemctl stop awg-quick@awg0 >/dev/null 2>&1; then
                rollback_can_restore=0
                printf '[ERROR] Could not stop the new awg0; live config was NOT overwritten. Backup: %s\n' \
                    "${_INSTALL_ROLLBACK_SERVER_BACKUP:-none (first install)}" >&2
            fi
        elif [[ "$rollback_can_restore" -eq 1 \
                && "$rollback_state" != "inactive" && "$rollback_state" != "failed" \
                && "$rollback_state" != "unknown" ]]; then
            rollback_can_restore=0
            printf '[ERROR] Could not determine awg0 state reliably (%s); live config was NOT overwritten. Backup: %s\n' \
                "${rollback_state:-no response}" "${_INSTALL_ROLLBACK_SERVER_BACKUP:-none}" >&2
        fi

        # A failed/inactive unit may still have a live link. systemctl stop
        # does not remove it, so run down against the still-NEW config before
        # restoring or removing that file.
        rollback_iface_present=0
        command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1 \
            && rollback_iface_present=1
        if [[ "$rollback_can_restore" -eq 1 && "$rollback_iface_present" -eq 1 ]]; then
            if [[ ! -f "$SERVER_CONF_FILE" || -L "$SERVER_CONF_FILE" ]] \
                || ! timeout 15 awg-quick down "$SERVER_CONF_FILE" >/dev/null 2>&1; then
                rollback_can_restore=0
                printf '[ERROR] Live awg0 was not removed with the new config; config was NOT overwritten.\n' >&2
            fi
        fi
        if [[ "$rollback_can_restore" -eq 1 ]] \
            && command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1; then
            rollback_can_restore=0
            printf '[ERROR] awg0 remains live after stop/down; config was NOT overwritten.\n' >&2
        fi

        if [[ "$rollback_can_restore" -eq 1 && "$_INSTALL_ROLLBACK_SERVER_EXISTED" -eq 1 ]]; then
            if [[ ! -f "$_INSTALL_ROLLBACK_SERVER_BACKUP" || -L "$_INSTALL_ROLLBACK_SERVER_BACKUP" ]]; then
                rollback_can_restore=0
                printf '[ERROR] Previous awg0.conf backup is missing; live config was NOT overwritten.\n' >&2
            else
                rollback_tmp=$(mktemp -p "$(dirname "$SERVER_CONF_FILE")" '.awg0.rollback.XXXXXX' 2>/dev/null) || rollback_tmp=""
                if [[ -n "$rollback_tmp" ]] \
                    && cp -- "$_INSTALL_ROLLBACK_SERVER_BACKUP" "$rollback_tmp" \
                    && chmod 600 "$rollback_tmp" && mv -f -- "$rollback_tmp" "$SERVER_CONF_FILE"; then
                    rollback_config_restored=1
                else
                    rm -f -- "$rollback_tmp" 2>/dev/null || true
                    printf '[ERROR] Could not atomically restore the previous awg0.conf from %s\n' \
                        "$_INSTALL_ROLLBACK_SERVER_BACKUP" >&2
                fi
            fi
        elif [[ "$rollback_can_restore" -eq 1 ]]; then
            if [[ -L "$SERVER_CONF_FILE" ]]; then
                printf '[ERROR] Refusing to remove an unexpected symlink in place of the new awg0.conf.\n' >&2
            elif rm -f -- "$SERVER_CONF_FILE"; then
                rollback_config_restored=1
            else
                printf '[ERROR] Could not remove awg0.conf from the aborted first install.\n' >&2
            fi
        fi

        if [[ "$rollback_config_restored" -eq 1 ]]; then
            # Bypass owns concrete routes in the policy table. Restore its
            # bundle/routes after the new awg0 is down, but before rolling the
            # WARP support interface back.
            if declare -F rollback_warp_bypass_state >/dev/null 2>&1; then
                rollback_warp_bypass_state || rollback_can_restore=0
            elif [[ "${_AWG_BYPASS_TX_ACTIVE:-0}" -eq 1 ]]; then
                printf '[ERROR] WARP bypass rollback function is unavailable; transaction left pending.\n' >&2
                rollback_can_restore=0
            fi
            _install_restore_awg0_dependency || rollback_can_restore=0
            _install_restore_upstream_config || rollback_can_restore=0
            if declare -F rollback_warp_egress_state >/dev/null 2>&1; then
                rollback_warp_egress_state || rollback_can_restore=0
            elif [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 1 ]]; then
                printf '[ERROR] WARP egress rollback function is unavailable; transaction left pending.\n' >&2
                rollback_can_restore=0
            fi
            if [[ "$_INSTALL_ROLLBACK_WARP_PARKED" -eq 1 ]]; then
                _install_restore_parked_warp_ownership || rollback_can_restore=0
            fi
            _install_restore_stopped_old_support || rollback_can_restore=0
            _install_restore_ufw_main_rule || rollback_can_restore=0
            _install_remove_new_ufw_cascade_rule || rollback_can_restore=0

            if [[ "$_INSTALL_ROLLBACK_AWG0_WAS_ENABLED" -eq 1 ]]; then
                systemctl enable awg-quick@awg0 >/dev/null 2>&1 || rollback_can_restore=0
            else
                systemctl disable awg-quick@awg0 >/dev/null 2>&1 || rollback_can_restore=0
            fi
            if [[ "$rollback_can_restore" -eq 1 && "$_INSTALL_ROLLBACK_AWG0_WAS_ACTIVE" -eq 1 ]]; then
                systemctl start awg-quick@awg0 >/dev/null 2>&1 || {
                    printf '[ERROR] Could not automatically restore the previous awg0. Backup: %s\n' \
                        "$_INSTALL_ROLLBACK_SERVER_BACKUP" >&2
                    rollback_can_restore=0
                }
            elif [[ "$rollback_can_restore" -eq 1 && "$_INSTALL_ROLLBACK_AWG0_WAS_LINK" -eq 1 ]]; then
                [[ -f "$SERVER_CONF_FILE" && ! -L "$SERVER_CONF_FILE" ]] \
                    && timeout 15 awg-quick up "$SERVER_CONF_FILE" >/dev/null 2>&1 || {
                        printf '[ERROR] Could not restore the manually started previous awg0.\n' >&2
                        rollback_can_restore=0
                    }
            fi
            # Restore the old DNS resolver/service only after its previous
            # tunnel gateway is back. On a first install this removes the new
            # attempt's DNS after the new awg0 has been fully removed.
            if [[ "$rollback_can_restore" -eq 1 ]] \
               && declare -F rollback_amnezia_dns_state >/dev/null 2>&1; then
                rollback_amnezia_dns_state || {
                    printf '[ERROR] Could not fully restore the previous AmneziaDNS state.\n' >&2
                    rollback_can_restore=0
                }
            elif [[ "$rollback_can_restore" -eq 1 \
                    && ( "${_AWG_DNS_TX_ACTIVE:-0}" -eq 1 \
                         || "${_AWG_DNS_TX_EXTERNAL:-0}" -eq 1 ) ]]; then
                printf '[ERROR] AmneziaDNS rollback function is unavailable; transaction left pending.\n' >&2
                rollback_can_restore=0
            fi
            if [[ "$rollback_can_restore" -eq 1 ]]; then
                rollback_state_tmp=$(mktemp -p "$(dirname "$STATE_FILE")" '.setup-state.rollback.XXXXXX' 2>/dev/null) || rollback_state_tmp=""
                [[ -n "$rollback_state_tmp" ]] && printf '6\n' > "$rollback_state_tmp" \
                    && mv -f -- "$rollback_state_tmp" "$STATE_FILE" || {
                        rm -f -- "$rollback_state_tmp" 2>/dev/null || true
                        printf '[ERROR] Network was restored, but setup_state could not be reset to step 6.\n' >&2
                        rollback_can_restore=0
                    }
            fi
            [[ "$rollback_can_restore" -eq 1 ]] && _INSTALL_ROLLBACK_AWG0=0
        fi
    fi

    # Standalone upstream rollback covers the narrow window before the server
    # transaction is armed. With an armed server it runs only after awg0 was
    # safely stopped and its config restored.
    if [[ "$_INSTALL_ROLLBACK_UPSTREAM" -eq 1 && "$rollback_attempted" -eq 0 ]]; then
        _install_restore_upstream_config || true
    fi
    if [[ "$_INSTALL_ROLLBACK_DEP_ACTIVE" -eq 1 && "$rollback_attempted" -eq 0 ]]; then
        _install_restore_awg0_dependency || true
    fi
    if [[ "$_INSTALL_ROLLBACK_UFW_MAIN_RULE" -eq 1 && "$rollback_attempted" -eq 0 ]]; then
        _install_restore_ufw_main_rule || true
    fi
    if [[ "$_INSTALL_ROLLBACK_UFW_CASCADE_RULE" -eq 1 && "$rollback_attempted" -eq 0 ]]; then
        _install_remove_new_ufw_cascade_rule || true
    fi
    if [[ "${_AWG_BYPASS_TX_ACTIVE:-0}" -eq 1 && "$rollback_attempted" -eq 0 ]] \
       && declare -F rollback_warp_bypass_state >/dev/null 2>&1; then
        rollback_warp_bypass_state || true
    fi
    if [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 1 && "$rollback_attempted" -eq 0 ]] \
       && declare -F rollback_warp_egress_state >/dev/null 2>&1; then
        rollback_warp_egress_state || true
    fi
    if [[ ( "${_AWG_DNS_TX_ACTIVE:-0}" -eq 1 || "${_AWG_DNS_TX_EXTERNAL:-0}" -eq 1 ) \
          && "$rollback_attempted" -eq 0 ]] \
       && declare -F rollback_amnezia_dns_state >/dev/null 2>&1; then
        rollback_amnezia_dns_state || true
    elif [[ "${_AWG_DNS_TX_ACTIVE:-0}" -eq 0 && "${_AWG_DNS_TX_EXTERNAL:-0}" -eq 1 ]] \
         && declare -F rollback_amnezia_dns_state >/dev/null 2>&1; then
        # Snapshot intent without mutations is always safe to disarm.
        rollback_amnezia_dns_state || true
    fi
    if [[ "$_INSTALL_ROLLBACK_WARP_PARKED" -eq 1 ]]; then
        _install_restore_parked_warp_ownership || true
    fi
    # Preserve snapshots/backups while rollback is incomplete: the signal
    # handler lets EXIT retry, and a normal fatal exit retains evidence for a
    # subsequent installer run or manual recovery.
    if [[ "$_INSTALL_ROLLBACK_AWG0" -eq 1 || "$_INSTALL_ROLLBACK_UPSTREAM" -eq 1 \
          || "$_INSTALL_ROLLBACK_DEP_ACTIVE" -eq 1 || "$_INSTALL_ROLLBACK_OLD_SUPPORT" -eq 1 \
          || "$_INSTALL_ROLLBACK_UFW_MAIN_RULE" -eq 1 \
          || "$_INSTALL_ROLLBACK_UFW_CASCADE_RULE" -eq 1 \
          || "$_INSTALL_ROLLBACK_WARP_PARKED" -eq 1 \
          || "${_AWG_BYPASS_TX_ACTIVE:-0}" -eq 1 \
          || "${_AWG_WARP_TX_ACTIVE:-0}" -eq 1 \
          || "${_AWG_DNS_TX_ACTIVE:-0}" -eq 1 \
          || "${_AWG_DNS_TX_EXTERNAL:-0}" -eq 1 ]]; then
        _install_cleaned=0
        printf '[WARN] Rollback is incomplete; snapshots were retained for retry.\n' >&2
        return 0
    fi
    local f
    for f in "${_install_temp_files[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done
    local d
    for d in "${_install_temp_dirs[@]}"; do [[ -d "$d" ]] && rmdir "$d" 2>/dev/null || true; done
    # Clean up temporary files from awg_common.sh (if already sourced)
    type _awg_cleanup &>/dev/null && _awg_cleanup
    _install_cleaned=2
}
# On INT/TERM the cleanup used to run but the script did NOT exit - execution
# continued past the interrupted command (dangerous mid apt/dpkg/config edits)
# and cleanup ran again on EXIT. A signal now means cleanup + explicit 130/143.
_install_on_signal() {
    _install_cleanup
    exit "$1"
}
trap _install_cleanup EXIT
trap '_install_on_signal 130' INT
trap '_install_on_signal 143' TERM

# --- Argument processing ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --uninstall)     UNINSTALL=1 ;;
        --help|-h)       HELP=1 ;;
        --diagnostic)    DIAGNOSTIC=1 ;;
        --verbose|-v)    VERBOSE=1 ;;
        --no-color)      NO_COLOR=1 ;;
        --port=*)        CLI_PORT="${1#*=}" ;;
        --ssh-port=*)    CLI_SSH_PORT="${1#*=}" ;;
        --subnet=*)      CLI_SUBNET="${1#*=}" ;;
        --allow-ipv6)        CLI_DISABLE_IPV6=0 ;;
        --disallow-ipv6)     CLI_DISABLE_IPV6=1 ;;
        --allow-ipv6-tunnel) CLI_ALLOW_IPV6_TUNNEL=1 ;;
        --disallow-ipv6-tunnel) CLI_ALLOW_IPV6_TUNNEL=0 ;;
        --route-all)     CLI_ROUTING_MODE=1 ;;
        --route-amnezia) CLI_ROUTING_MODE=2 ;;
        --route-custom=*) CLI_ROUTING_MODE=3; CLI_CUSTOM_ROUTES="${1#*=}" ;;
        --isolation=*)   CLI_ISOLATION="${1#*=}" ;;
        --endpoint=*)    CLI_ENDPOINT="${1#*=}" ;;
        --server-name=*) CLI_SERVER_NAME="${1#*=}" ;;
        --mobile)        CLI_MOBILE=1 ;;
        --yes|-y)        AUTO_YES=1 ;;
        --no-tweaks)     NO_TWEAKS=1; CLI_NO_TWEAKS=1 ;;
        --no-cps)        NO_CPS=1; CLI_NO_CPS=1 ;;
        --keep-packages) KEEP_PACKAGES=1; CLI_KEEP_PACKAGES=1 ;;
        --force|-f)      FORCE_REINSTALL=1 ;;
        --preset=*)      CLI_PRESET="${1#*=}" ;;
        --jc=*)          CLI_JC="${1#*=}" ;;
        --jmin=*)        CLI_JMIN="${1#*=}" ;;
        --jmax=*)        CLI_JMAX="${1#*=}" ;;
        --i1-mode=*)     CLI_I1_MODE="${1#*=}" ;;
        --role=*)        CLI_ROLE="${1#*=}" ;;
        --upstream-conf=*)    CLI_UPSTREAM_CONF="${1#*=}" ;;
        --upstream-iface=*)   CLI_UPSTREAM_IFACE="${1#*=}" ;;
        --upstream-table=*)   CLI_UPSTREAM_TABLE="${1#*=}" ;;
        --upstream-fwmark=*)  CLI_UPSTREAM_FWMARK="${1#*=}" ;;
        --egress=*)           CLI_EGRESS="${1#*=}" ;;
        --warp-iface=*)       CLI_WARP_IFACE="${1#*=}" ;;
        --warp-table=*)       CLI_WARP_TABLE="${1#*=}" ;;
        --warp-priority=*)    CLI_WARP_PRIORITY="${1#*=}" ;;
        --warp-bypass=*)      CLI_WARP_BYPASS="${1#*=}" ;;
        --amnezia-dns=*)      CLI_AMNEZIA_DNS="${1#*=}" ;;
        *) echo "Unknown argument: $1" >&2; HELP=1; HELP_EXIT_RC=1 ;;
    esac
    shift
done

# ==============================================================================
# Logging functions
# ==============================================================================

log_msg() {
    local type="$1" msg="$2"
    local ts
    ts=$(date +'%F %T')
    local entry="[$ts] $type: $msg"
    local color_start="" color_end=""

    if [[ "$NO_COLOR" -eq 0 ]]; then
        color_end="\033[0m"
        case "$type" in
            INFO)  color_start="\033[0;32m" ;;
            WARN)  color_start="\033[0;33m" ;;
            ERROR) color_start="\033[1;31m" ;;
            DEBUG) color_start="\033[0;36m" ;;
            *)     color_start=""; color_end="" ;;
        esac
    fi

    if ! mkdir -p "$(dirname "$LOG_FILE")" || ! echo "$entry" >> "$LOG_FILE"; then
        echo "[$ts] ERROR: Log write error $LOG_FILE" >&2
    fi

    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "$type" == "DEBUG" && "$VERBOSE" -eq 1 ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    elif [[ "$type" == "INFO" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry"
    elif [[ "$type" != "DEBUG" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry"
    fi
}

log()       { log_msg "INFO" "$1"; }
log_warn()  { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_debug() { if [[ "$VERBOSE" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }
die()       { log_error "CRITICAL ERROR: $1"; log_error "Installation aborted. Log: $LOG_FILE"; exit 1; }

# ==============================================================================
# apt-get update wrapper that tolerates 404s only for source packages (deb-src).
# INLINE: needed in steps 1-2 before awg_common.sh is downloaded (Step 5).
# Some mirrors (Hetzner, AWS) do not serve source packages, but the default
# ubuntu.sources contains 'Types: deb deb-src'. We do not need source packages
# (kernel module is built via DKMS using binary headers), so such 404s are safe
# to ignore. Returns 0 if update succeeded OR if all errors are on source markers.
# Any other error (GPG, binary-package network, silent crash / OOM / SIGKILL) → non-zero.
# ==============================================================================
apt_update_tolerant() {
    # --ppa-amnezia-tolerant: also ignore errors from the Amnezia PPA. Used
    # in step 2 — apt_wait_for_ppa_package below already retries for the
    # ppa.launchpadcontent.net outage scenario (issue #68). Without this
    # flag we must fail fast on any non-source error, otherwise the script
    # would continue installing on a stale apt-cache (PR #69 review finding).
    local ppa_tolerant=0
    if [[ "${1:-}" == "--ppa-amnezia-tolerant" ]]; then
        ppa_tolerant=1
        shift
    fi

    local err_output rc non_src_errors raw_had_non_src_errors=0
    err_output=$(LANG=C LC_ALL=C apt-get update -y 2>&1)
    rc=$?
    echo "$err_output"

    if [[ $rc -eq 0 ]]; then
        return 0
    fi

    # Filter error lines. Ignore:
    #   1. Lines about source packages (deb-src / /source/ / Sources)
    #   2. Generic 'Some index files failed to download' — symptom, not cause
    # Additionally exclude known informational W: lines that are never the
    # CAUSE of rc!=0 but used to survive the filters and turn a tolerable
    # failure (e.g. deb-src 404 with duplicated sources) into a false fatal:
    #   - "Target ... is configured multiple times" (duplicate sources entries)
    #   - "... stored in legacy trusted.gpg keyring" (old key format)
    non_src_errors=$(printf '%s\n' "$err_output" \
        | grep -E '^(E:|Err:|W:)' \
        | grep -vE '(deb-src|/source/|Sources([^[:alpha:]]|$))' \
        | grep -vE 'Some index files failed to download' \
        | grep -vE '^W: (Target .* is configured multiple times|.* stored in legacy trusted\.gpg)' || true)

    # Remember pre-PPA-filter state — we need to distinguish "real APT errors,
    # but all on Amnezia PPA" (tolerant OK) from "no classifiable errors at all"
    # (OOM / silent crash — NOT tolerant even if the output happens to mention
    # a PPA URL elsewhere).
    [[ -n "$non_src_errors" ]] && raw_had_non_src_errors=1

    # Optional (step 2): drop errors that are only on the Amnezia PPA — they
    # will be re-checked via apt_wait_for_ppa_package against apt-cache (issue #68).
    if [[ $ppa_tolerant -eq 1 && -n "$non_src_errors" ]]; then
        non_src_errors=$(printf '%s\n' "$non_src_errors" \
            | grep -vE 'ppa\.launchpadcontent\.net.*amnezia' || true)
    fi

    if [[ -z "$non_src_errors" ]]; then
        # Edge case: rc != 0 but no classifiable E:/Err:/W: lines found
        # (OOM-killer SIGKILL, silent crash, unknown apt output format).
        # Ignore ONLY if the output actually contains source-markers, or if
        # ppa-tolerant + there were real APT lines and all of them were on the
        # Amnezia PPA.
        if printf '%s\n' "$err_output" | grep -qE '(deb-src|/source/|Sources([^[:alpha:]]|$))'; then
            log_warn "apt update: source packages unavailable in mirror (expected, ignored)"
            return 0
        fi
        if [[ $ppa_tolerant -eq 1 && $raw_had_non_src_errors -eq 1 ]] \
            && printf '%s\n' "$err_output" | grep -qE 'ppa\.launchpadcontent\.net.*amnezia'; then
            log_warn "apt update: errors only on Amnezia PPA (issue #68), continuing with retry."
            return 0
        fi
        log_error "apt update exited with rc=$rc without any classifiable APT lines — possible silent crash / OOM / SIGKILL"
        return "$rc"
    fi

    log_error "apt update failed with non-source errors:"
    printf '%s\n' "$non_src_errors" | while IFS= read -r line; do
        log_error "  $line"
    done
    return "$rc"
}

# ==============================================================================
# apt_wait_for_ppa_package <package> [max_attempts] [initial_delay_seconds]
#   Waits until the given package becomes visible in apt-cache, with
#   exponential backoff between attempts. Needed in step 2 after the
#   Amnezia PPA is added: ppa.launchpadcontent.net sometimes briefly
#   goes down (issue #68), and without retries the first cold install
#   fails even though the PPA is back a minute later.
#
#   IMPORTANT: this checks apt-cache show, not the rc of apt-get update.
#   apt-get update returns 0 tolerantly even when an InRelease file did
#   not download — so a plain rc-based retry does not catch a PPA outage.
#   Package visibility in apt-cache is the only reliable signal that
#   the PPA actually got indexed.
#
#   With the defaults (3 attempts × initial=30s) the timeline is:
#   attempt 1 → sleep 30s → apt update + attempt 2 → sleep 60s →
#   apt update + attempt 3 (last). After the third fail we return 1.
#   Total wait between attempts is about 1.5 minutes.
#
#   The 1800s delay cap guards against arithmetic overflow if the helper
#   is ever called with a very large max.
# ==============================================================================
apt_wait_for_ppa_package() {
    local pkg="$1" max="${2:-3}" delay="${3:-30}" attempt
    for ((attempt = 1; attempt <= max; attempt++)); do
        if apt-cache show "$pkg" >/dev/null 2>&1; then
            return 0
        fi
        if (( attempt == max )); then
            return 1
        fi
        log_warn "Package '${pkg}' did not appear in apt-cache (attempt ${attempt}/${max}, PPA still unavailable), retrying in ${delay}s..."
        sleep "$delay"
        apt_update_tolerant >/dev/null 2>&1 || true
        delay=$(( delay * 2 > 1800 ? 1800 : delay * 2 ))
    done
    return 1
}

# ==============================================================================
# Help
# ==============================================================================

show_help() {
    cat << 'EOF'
Usage: sudo bash install_amneziawg_en.sh [OPTIONS]
Script for installation and configuration of AmneziaWG 2.0 on Ubuntu (24.04 / 25.10 / 26.04) and Debian (12 / 13).

Options:
  -h, --help            Show this help and exit
  --uninstall           Uninstall AmneziaWG and all its configurations
  --diagnostic          Generate diagnostic report and exit
  -v, --verbose         Verbose output for debugging (including DEBUG)
  --no-color            Disable colored terminal output
  --port=NUMBER         Set UDP port (1-65535) non-interactively.
                        Useful against mobile DPI: 500 (IKE/NAT-T), 443, 53.
  --ssh-port=PORT       SSH port for the UFW rule (auto-detected by default;
                        comma-separated list). Use if SSH runs on a non-standard
                        port and auto-detection is unavailable
  --subnet=SUBNET       Tunnel subnet, CIDR /16-/30 (e.g. 10.9.0.0/16) non-interactively
  --allow-ipv6          Keep IPv6 enabled non-interactively
  --disallow-ipv6       Force-disable IPv6 non-interactively
  --allow-ipv6-tunnel   Enable dual-stack IPv6 inside the tunnel (ULA, opt-in)
                        Not supported with --role=entry or --egress=warp
  --disallow-ipv6-tunnel Disable a previously enabled in-tunnel IPv6 setup
  --route-all           Use 'All traffic' mode non-interactively
  --route-amnezia       Use 'Amnezia' mode non-interactively
  --route-custom=NETS   Use 'Custom' mode non-interactively
  --isolation=on|off    Isolate VPN clients from each other (default on).
                        off: the tunnel subnet is added to client AllowedIPs
  --endpoint=ADDR       External server endpoint: FQDN, IPv4 or [IPv6] (NAT)
  --server-name=NAME    Server name shown in the Amnezia app on vpn:// import
                        (default 'AWG Server'; no quotes or control characters)
  --mobile              Mobile setup in one flag: --preset=mobile + port 443/udp
                        (mobile carriers often kill non-standard UDP ports).
                        An explicit --port=N wins over port 443
  -y, --yes             Auto-confirm (reboots, UFW, etc.)
  -f, --force           Force reinstall on top of an already-running AmneziaWG
                        (by default a run on a configured server aborts;
                        ENV: AWG_FORCE_REINSTALL=1 is equivalent to the flag)
  --no-tweaks           Skip the system cleanup, the optimization and the hardening
                        (UFW, Fail2Ban); the minimal forwarding sysctl is always applied
  --keep-packages       Do not remove system packages (snapd and others), but keep
                        the firewall, Fail2Ban and the optimization. Removing snapd
                        takes installed snaps and their data in /var/snap with it
  --preset=TYPE         Obfuscation parameter preset: default, mobile
                        mobile: Jc=3, narrow Jmax — for mobile carriers (Tele2, Yota, Megafon)
  --jc=N               Set Jc manually (1-128, overrides preset)
  --jmin=N             Set Jmin manually (0-1280, overrides preset)
  --jmax=N             Set Jmax manually (0-1280, overrides preset, must be >= Jmin)
  --i1-mode=MODE       random (default) | quic
                        random: <r N> random bytes (32-256) — uninformative noise.
                        quic:   <b 0x...> ≈1100-1250 bytes shaped as a valid
                                QUIC v1 Initial packet (RFC 9000 §17.2.2).
                                Masks the AWG handshake as ordinary QUIC browser
                                traffic. Strongest mode against mobile carrier
                                DPI. Pair with --preset=mobile --port=500.
  --no-cps              Disable CPS (the I1 parameter) - needed if the desktop
                        AmneziaVPN on macOS hangs on connect (issue #159)

Multi-hop (cascade of two AWG servers):
  --role=ROLE           single (default) | exit | entry
                        exit:  ordinary server that the entry attaches to
                        entry: additionally brings up an upstream tunnel to exit
  --upstream-conf=FILE  (for role=entry) path to the .conf from `manage add` on the exit node
  --upstream-iface=NAME upstream interface name (default awg1)
  --upstream-table=N    routing table for client traffic (default 123)
  --upstream-fwmark=HEX fwmark for upstream packets (default 0xca6d)

WARP egress (for role=exit or single — NOT compatible with role=entry):
  --egress=MODE         direct (default) | warp
                        warp: installs wgcf (Cloudflare WARP WireGuard client),
                        brings up wg-quick@wgcf with Table=off, and policy-routes
                        AWG client traffic into WARP. External sites see a
                        Cloudflare IP instead of the VPS IP.
  --warp-iface=NAME     WARP interface name (default wgcf)
  --warp-table=N        routing table for WARP traffic (default 2408)
  --warp-priority=N     WARP ip rule priority, 1..32764 (default 789)
  --warp-bypass=SPEC    WARP exceptions (traffic exits via main NIC directly).
                        Useful against CDNs that rate-limit or block WARP
                        address ranges (the classic case is YouTube /
                        googlevideo). SPEC = none (default) | youtube |
                        custom:<URL|/path>, comma-separated. `youtube` is the
                        CIDR list from touhidurrr/iplist-youtube (cidr4.txt).
                        For custom sources the format is auto-detected:
                        CIDR (1.2.3.4[/N]) or hostname (resolved via @1.1.1.1);
                        `#` comments and dnsmasq-style `full:`/`@tag`
                        decorations are accepted. Requires --egress=warp.
                        Auto-refreshes every 6 hours through a systemd timer.
                        Example: --warp-bypass=youtube,custom:https://example.com/list.txt

AmneziaDNS (for the built-in site-based split tunneling UI in the Amnezia VPN client):
  --amnezia-dns=MODE    off (default) | on
                        on: installs dnsmasq on the tunnel-gateway IP
                        (e.g. 10.8.0.1), emits the client vpn:// URI as a
                        "real Amnezia server" (isThirdPartyConfig:false +
                        amnezia-dns container). The Amnezia VPN client UI
                        unlocks the split tunneling site-list — sites marked
                        "bypass VPN" are resolved locally on the device and
                        go straight to the ISP (the destination sees the
                        user's real IP, not the VPS IP).
                        Allowed on --role=single and --role=entry (not exit).

Examples:
  sudo bash install_amneziawg_en.sh                             # Interactive installation
  sudo bash install_amneziawg_en.sh --port=51820 --route-all    # Non-interactive
  sudo bash install_amneziawg_en.sh --route-amnezia --yes       # Fully automated
  sudo bash install_amneziawg_en.sh --preset=mobile --yes       # Optimized for mobile networks
  sudo bash install_amneziawg_en.sh --preset=mobile --port=500 --i1-mode=quic --yes   # Max mobile-DPI bypass
  sudo bash install_amneziawg_en.sh --role=exit --yes           # Cascade exit node
  sudo bash install_amneziawg_en.sh --role=entry --upstream-conf=/root/from_exit.conf --yes
  sudo bash install_amneziawg_en.sh --egress=warp --yes         # Standalone server with WARP egress
  sudo bash install_amneziawg_en.sh --role=exit --egress=warp --yes   # Cascade exit with WARP egress
  sudo bash install_amneziawg_en.sh --role=exit --egress=warp --warp-bypass=youtube --yes   # Exit + WARP, YouTube goes direct
  sudo bash install_amneziawg_en.sh --amnezia-dns=on --yes      # Standalone server + site-based split tunneling in the client
  sudo bash install_amneziawg_en.sh --role=entry --upstream-conf=/root/from_exit.conf --amnezia-dns=on --yes
  sudo bash install_amneziawg_en.sh --uninstall                 # Uninstall
  sudo bash install_amneziawg_en.sh --diagnostic                # Diagnostics

Fork: https://github.com/SNPR/amneziawg-installer (upstream: bivlked)
EOF
    # Explicit --help exits 0; an unknown argument exits 1 (false success in CI).
    exit "${HELP_EXIT_RC:-0}"
}

# ==============================================================================
# Utilities and validation
# ==============================================================================

update_state() {
    local next_step=$1
    mkdir -p "$(dirname "$STATE_FILE")"
    # Atomic write: tmp-file + flock + mv. Protects against a truncated
    # state file if the process is killed / power-lost between write and close.
    (
        flock -x 200
        local tmp="${STATE_FILE}.tmp.$BASHPID"
        if printf '%s\n' "$next_step" > "$tmp" && mv -f "$tmp" "$STATE_FILE"; then
            exit 0
        fi
        rm -f "$tmp" 2>/dev/null
        exit 1
    ) 200>"${STATE_FILE}.lock" || die "Failed to write state"
    log "State: next step - $next_step"
}

request_reboot() {
    local next_step=$1
    update_state "$next_step"

    # Capture boot_id before the 1→2 reboot gate. On step 2 entry we
    # compare it with the current boot_id — if they match, the user did
    # not reboot, which means the step 1 upgrade may have staged a kernel on
    # disk but the running kernel is still the old one. DKMS would build
    # the module against the old kernel and modprobe would fail after
    # the next reboot. Fail fast instead.
    if [[ "$next_step" == "2" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        if cat /proc/sys/kernel/random/boot_id > "$AWG_DIR/.boot_id_before_step2" 2>/dev/null; then
            log_debug "boot_id captured before reboot"
        fi
    fi

    echo "" >> "$LOG_FILE"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log_warn "!!! SYSTEM REBOOT REQUIRED                                !!!"
    log_warn "!!! After reboot, run the script again:                   !!!"
    log_warn "!!! sudo bash $0 [with the same parameters, if any]      !!!"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "" >> "$LOG_FILE"
    local confirm="y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Reboot now? [y/N]: " confirm < /dev/tty
    else
        log "Auto-confirming reboot (--yes)."
    fi
    if [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
        log "Reboot initiated..."
        sleep 5
        if ! reboot; then die "Reboot command failed."; fi
        exit 1
    else
        log "Reboot cancelled. Reboot manually and run the script again."
        exit 1
    fi
}

# Early container detection (LXC/OpenVZ/Docker/WSL) - 4pda case: on a
# container VDS the install used to reach step 3 and die with a raw
# 'modprobe: FATAL: Module amneziawg not found' with no explanation. AmneziaWG
# installs a kernel module via DKMS, and containers share the host kernel and
# cannot load their own modules - it is more honest to stop right away.
# systemd-detect-virt exists on all supported Ubuntu/Debian; if it is somehow
# missing, the check is skipped (soft degradation, the install is not blocked).
check_container() {
    command -v systemd-detect-virt &>/dev/null || return 0
    local virt
    virt=$(systemd-detect-virt --container 2>/dev/null) || true
    [[ -z "$virt" || "$virt" == "none" ]] && return 0
    log_error "Container detected: ${virt}."
    log_error "AmneziaWG requires loading a kernel module (DKMS), and containers (LXC/OpenVZ/Docker/WSL) share the host kernel and cannot load their own modules."
    die "Use a full VPS (KVM/QEMU) or bare-metal. The container option is userspace amneziawg-go: ADVANCED.en.md, section 'LXC / Docker via amneziawg-go'."
}

check_os_version() {
    log "Checking OS..."

    # Detection via /etc/os-release (universal for Ubuntu and Debian)
    OS_ID=""
    OS_VERSION=""
    OS_CODENAME=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        OS_ID="$ID"
        OS_VERSION="$VERSION_ID"
        OS_CODENAME="$VERSION_CODENAME"
    elif command -v lsb_release &>/dev/null; then
        OS_ID=$(lsb_release -si | tr '[:upper:]' '[:lower:]')
        OS_VERSION=$(lsb_release -sr)
        OS_CODENAME=$(lsb_release -sc)
    else
        log_warn "Cannot detect OS (/etc/os-release and lsb_release not found)."
        return 0
    fi
    export OS_ID OS_VERSION OS_CODENAME

    # Supported OS
    local supported=0
    case "$OS_ID" in
        ubuntu)
            if [[ "$OS_VERSION" == "24.04" || "$OS_VERSION" == "25.10" || "$OS_VERSION" == "26.04" ]]; then
                supported=1
            fi
            ;;
        debian)
            if [[ "$OS_VERSION" == "12" || "$OS_VERSION" == "13" ]]; then
                supported=1
            fi
            ;;
    esac

    if [[ "$supported" -eq 1 ]]; then
        log "OS: ${OS_ID^} $OS_VERSION ($OS_CODENAME) — supported"
    else
        log_warn "Detected $OS_ID $OS_VERSION ($OS_CODENAME). Script tested on Ubuntu 24.04/25.10/26.04 and Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Cancelled."; fi
        else
            log "Continuing on $OS_ID $OS_VERSION (--yes)."
        fi
    fi
}

check_kernel_version() {
    # The AmneziaWG 2.0 module is built via DKMS against the host kernel. On
    # kernels older than 5.15 (Ubuntu < 22.04, e.g. 5.4 on 20.04) the build
    # usually fails at step 2 with an opaque package-failure. Warn EXPLICITLY and
    # early, before updates and reboots (issue #163). Not a die: on some older
    # kernels the module still builds (HWE and such), so WARN + confirm.
    local kver kmaj kmin
    kver=$(uname -r)
    if [[ "$kver" =~ ^([0-9]+)\.([0-9]+) ]]; then
        kmaj=${BASH_REMATCH[1]}; kmin=${BASH_REMATCH[2]}
    else
        log_warn "Could not parse the kernel version ('$kver') - skipping the minimum-version check."
        return 0
    fi
    if (( kmaj < 5 || (kmaj == 5 && kmin < 15) )); then
        log_warn "Kernel $kver is older than 5.15 - usually too old for the AmneziaWG 2.0 module."
        log_warn "The DKMS module build on such a kernel most often fails. Reinstall the VPS on Ubuntu 24.04 LTS or Debian 12 (or newer). Matrix: Ubuntu 24.04/25.10/26.04, Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue anyway? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Cancelled: kernel $kver is too old for the AmneziaWG 2.0 module."; fi
        else
            log "Continuing on kernel $kver (--yes)."
        fi
    else
        log "Kernel $kver (OK for the AmneziaWG 2.0 module)."
    fi
}

# shellcheck disable=SC2120  # called without args in the installer (uses uname -r); bats passes versions
_kernel_supports_awg3() {
    # Returns 0 if the kernel version is >= 6.7 - there we take the module from the
    # PPA as is. Returns 1 if the kernel is older than 6.7 - there we go the pinned
    # 2.0 route.
    # ⚠️ The name is historical, do not read it literally. The 6.7 threshold comes
    # from 30-31 jul 2026: the 3.0 code called nla_put_uint, absent before mainline
    # v6.7, and on 6.1 (Debian 12) the build died with 'implicit declaration of
    # nla_put_uint'. Upstream fixed that on 31 jul (v3.0.20260731-04), and the 3.0
    # module DOES build on 6.1 now - verified on a stand on 1 aug. The threshold is
    # kept deliberately: within a day the 3.0 line managed to break and fix the
    # build on old kernels specifically, so that is where it is least proven, while
    # the pinned 2.0 is checked against an immutable commit. Drop the threshold
    # after validating 3.0, not because the build passes again.
    # Arg $1: kernel release (default uname -r). An unparseable version is treated
    # as "NOT supported" -> pinned 2.0 (it builds on ANY of our kernels, so the
    # conservative choice never breaks connectivity, it only withholds 3.0 features
    # which H0 does not ship anyway).
    # Pure function with no external deps (bats: extracted via sed-range + source).
    local kver="${1:-$(uname -r)}" kmaj kmin
    local min_maj=6 min_min=7
    if [[ "$kver" =~ ^([0-9]+)\.([0-9]+) ]]; then
        kmaj=${BASH_REMATCH[1]}; kmin=${BASH_REMATCH[2]}
    else
        return 1
    fi
    if (( kmaj > min_maj || (kmaj == min_maj && kmin >= min_min) )); then
        return 0
    fi
    return 1
}

check_free_space() {
    log "Checking disk space..."
    local req=2048
    local avail
    avail=$(df -m / | awk 'NR==2 {print $4}')
    if [[ -z "$avail" ]]; then
        log_warn "Failed to determine free space."
        return 0
    fi
    if [ "$avail" -lt "$req" ]; then
        log_warn "Available $avail MB. Recommended >= $req MB."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Continue? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Cancelled."; fi
        else
            log "Continuing with $avail MB (--yes)."
        fi
    else
        log "Free: $avail MB (OK)"
    fi
}

check_port_availability() {
    local port=$1
    log "Checking port $port..."
    local proc
    proc=$(ss -lunp | grep ":${port} ")
    if [[ -n "$proc" ]]; then
        log_error "Port ${port}/udp already in use! Process: $proc"
        return 1
    else
        log "Port $port/udp is free."
        return 0
    fi
}

install_packages() {
    local packages=("$@")
    local to_install=()
    local pkg
    log "Checking packages: ${packages[*]}..."
    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            to_install+=("$pkg")
        fi
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        log "All packages already installed."
        return 0
    fi
    log "Installing: ${to_install[*]}..."
    if [[ "${_APT_UPDATED:-0}" -eq 0 ]]; then
        # C4: a hard apt_update_tolerant failure (GPG / binary-repo network / OOM)
        # is NOT source noise but a real error; continuing on a stale cache is not
        # safe (contract line ~138, same as callers 1975/2108). die aborts the
        # install, so _APT_UPDATED=1 is set only on success - otherwise a later
        # install_packages call in this session would silently skip the update.
        apt_update_tolerant || die "apt update error."
        _APT_UPDATED=1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}"; then
        # v5.13.0: typical failure on 25.10/26.04 after an in-place upgrade
        # from 24.04 — the amneziawg-dkms postinst runs `dkms autoinstall`
        # which iterates over ALL kernels in /lib/modules/. The leftover
        # 6.8.x headers were compiled with gcc-13, but 25.10 ships only
        # gcc-15 by default → autoinstall fails, dpkg leaves the dependent
        # amneziawg-tools / amneziawg unconfigured. Force-build the module
        # for the running kernel only and finish with dpkg --configure -a.
        if printf '%s\n' "${to_install[@]}" | grep -qx "amneziawg-dkms"; then
            log_warn "apt install did not complete — trying a DKMS build for the running kernel $(uname -r) only..."
            local _mver
            _mver="$(ls /var/lib/dkms/amneziawg/ 2>/dev/null | head -n1)"
            if [[ -n "$_mver" ]] \
               && dkms install -m amneziawg -v "$_mver" -k "$(uname -r)" --force \
               && DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
                log "DKMS module built for $(uname -r), dpkg configured."
                log "Packages installed."
                return 0
            fi
        fi
        die "Package installation error."
    fi
    log "Packages installed."
}

cleanup_apt() {
    log "Cleaning apt..."
    apt-get clean || log_warn "apt-get clean error"
    rm -rf /var/lib/apt/lists/* || log_warn "rm /var/lib/apt/lists/* error"
    log "apt cache cleared."
}

configure_ipv6() {
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then
        DISABLE_IPV6=$CLI_DISABLE_IPV6
        log "IPv6 from CLI: $DISABLE_IPV6"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        DISABLE_IPV6=1
        log "IPv6 disabled (--yes, default)."
    else
        read -rp "Disable IPv6 (recommended)? [Y/n]: " dis_ipv6 < /dev/tty
        if [[ "$dis_ipv6" =~ ^[Nn]$ ]]; then
            DISABLE_IPV6=0
        else
            DISABLE_IPV6=1
        fi
    fi
    export DISABLE_IPV6
    log "IPv6 disable: $(if [ "$DISABLE_IPV6" -eq 1 ]; then echo 'Yes'; else echo 'No'; fi)"
}

# Detect whether the VPS has native IPv6.
# Native IPv6 = a globally routable address (NOT ULA fc00::/7, NOT link-local
# fe80::) AND a default IPv6 route. Either condition alone is insufficient:
#   - a global address without a default route -> no IPv6 internet egress (a client
#     with ::/0 would black-hole);
#   - a ULA (fddd::/...) has global scope to `ip` but is not internet-routable.
# Echo 1 only when both conditions hold, otherwise 0.
detect_native_ipv6() {
    local have_addr=0 have_route=0
    if ip -6 addr show scope global 2>/dev/null \
        | grep -oP 'inet6\s+\K[0-9a-fA-F:]+' \
        | grep -qviE '^(fc|fd)'; then
        have_addr=1
    fi
    if ip -6 route show default 2>/dev/null | grep -q .; then
        have_route=1
    fi
    if [[ "$have_addr" -eq 1 && "$have_route" -eq 1 ]]; then
        echo 1
    else
        echo 0
    fi
}

# Only a compressed ULA /64 (...::/64) is supported: this is the shape the
# renderer and client allocator can transform deterministically. The first
# 16-bit group must be in fc00::/7; 1-4 groups may precede the `::`.
validate_ipv6_tunnel_subnet() {
    local subnet="$1" head prefix first group
    local -a groups
    [[ "$subnet" =~ ^([0-9A-Fa-f:]+)::/([0-9]{1,3})$ ]] || return 1
    head="${BASH_REMATCH[1]}"
    prefix="${BASH_REMATCH[2]}"
    [[ "$prefix" == "64" && "$head" != :* && "$head" != *: ]] || return 1
    IFS=':' read -r -a groups <<< "$head"
    (( ${#groups[@]} >= 1 && ${#groups[@]} <= 4 )) || return 1
    for group in "${groups[@]}"; do
        [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
    done
    first=$(( 16#${groups[0]} ))
    (( first >= 0xfc00 && first <= 0xfdff ))
}

configure_ipv6_tunnel() {
    case "$CLI_ALLOW_IPV6_TUNNEL" in
        1) ALLOW_IPV6_TUNNEL=1 ;;
        0) ALLOW_IPV6_TUNNEL=0 ;;
        default)
            case "${ALLOW_IPV6_TUNNEL:-}" in
                "") ALLOW_IPV6_TUNNEL=0 ;;
                0|1) : ;;
                *)
                    log_warn "ALLOW_IPV6_TUNNEL='${ALLOW_IPV6_TUNNEL}' in $CONFIG_FILE is invalid (expected 0|1) — disabling in-tunnel IPv6."
                    ALLOW_IPV6_TUNNEL=0
                    ;;
            esac
            ;;
        *) die "Internal CLI_ALLOW_IPV6_TUNNEL='$CLI_ALLOW_IPV6_TUNNEL' error." ;;
    esac
    : "${IPV6_SUBNET:=fddd:2c4:2c4:2c4::/64}"
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        validate_ipv6_tunnel_subnet "$IPV6_SUBNET" \
            || die "Invalid IPV6_SUBNET='$IPV6_SUBNET'. Expected a ULA /64 such as fddd:2c4:2c4:2c4::/64."
    elif ! validate_ipv6_tunnel_subnet "$IPV6_SUBNET"; then
        log_warn "Unused IPV6_SUBNET='$IPV6_SUBNET' is invalid; normalizing it while the IPv6 tunnel is disabled."
        IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    fi

    # Reject incompatible modes BEFORE the sysctl writes below: an invalid CLI
    # combination must not alter host IPv6 state before it fails.
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "${AWG_ROLE:-single}" == "entry" ]]; then
        die "--allow-ipv6-tunnel is not supported with --role=entry yet: the upstream cascade routes IPv4 only. Use --disallow-ipv6-tunnel."
    fi
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "${AWG_EGRESS:-direct}" == "warp" ]]; then
        die "--allow-ipv6-tunnel is not supported with --egress=warp yet: WARP policy routing is IPv4-only. Use --disallow-ipv6-tunnel."
    fi
    # The IPv6 tunnel requires host IPv6 enabled. Override --disallow-ipv6 AND
    # actively re-enable IPv6 at runtime BEFORE detection/render: on an upgrade
    # from a default past install (IPv6 was runtime-disabled), the kernel hides
    # all IPv6 addresses, so detect_native_ipv6 would false-negative and a client
    # would be rendered with an IPv6 Address while the kernel has IPv6 off
    # (awg-quick restart can fail).
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        if [[ "$DISABLE_IPV6" -eq 1 ]]; then
            log_warn "--allow-ipv6-tunnel requires host IPv6 forwarding; overriding --disallow-ipv6 (DISABLE_IPV6=0)"
            DISABLE_IPV6=0
        fi
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
    fi
    # Detect native IPv6 AFTER the runtime re-enable (cached in init for client render in Phase 4).
    SERVER_HAS_NATIVE_IPV6=$(detect_native_ipv6)
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "$SERVER_HAS_NATIVE_IPV6" -eq 0 ]]; then
        log_warn "Native IPv6 not detected on VPS - the IPv6 tunnel will work peer-to-peer only, without IPv6 internet egress."
    fi
    export ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6 DISABLE_IPV6
}

# Safe configuration loader (whitelist parser, no source/eval)
safe_load_config() {
    local config_file="${1:-$CONFIG_FILE}"
    if [[ ! -f "$config_file" ]]; then return 1; fi

    local line key value first_line=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" -eq 1 ]]; then
            line="${line#$'\xEF\xBB\xBF'}"
            first_line=0
        fi
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue
        line="${line#export }"
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"
                value="${value%\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            case "$key" in
                OS_ID|OS_VERSION|OS_CODENAME|AWG_PORT|AWG_TUNNEL_SUBNET|\
                DISABLE_IPV6|ALLOWED_IPS_MODE|ALLOWED_IPS|AWG_ENDPOINT|AWG_MTU|\
                AWG_Jc|AWG_Jmin|AWG_Jmax|AWG_S1|AWG_S2|AWG_S3|AWG_S4|\
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_I1_MODE|AWG_I2|AWG_I3|AWG_I4|AWG_I5|AWG_PRESET|NO_TWEAKS|NO_CPS|KEEP_PACKAGES|\
                AWG_APPLY_MODE|\
                ALLOW_IPV6_TUNNEL|IPV6_SUBNET|SERVER_HAS_NATIVE_IPV6|\
                PREV_AWG_PORT|CLIENT_ISOLATION|CLIENT_ISOLATION_NET|AWG_SERVER_NAME|\
                AWG_ROLE|AWG_UPSTREAM_IFACE|AWG_UPSTREAM_TABLE|AWG_UPSTREAM_FWMARK|AWG_UPSTREAM_PRIORITY|\
                AWG_EGRESS|AWG_WARP_IFACE|AWG_WARP_TABLE|AWG_WARP_PRIORITY|AWG_WARP_BYPASS|\
                AWG_AMNEZIA_DNS)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# Read a single key from config (for point queries)
safe_read_config_key() {
    local key="$1" config_file="${2:-$CONFIG_FILE}"
    local line first_line=1
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$first_line" -eq 1 ]]; then
            line="${line#$'\xEF\xBB\xBF'}"
            first_line=0
        fi
        line="${line%$'\r'}"
        line="${line#export }"
        if [[ "$line" =~ ^${key}=(.*)$ ]]; then
            local value="${BASH_REMATCH[1]}"
            if [[ "$value" == \'*\' ]]; then
                value="${value#\'}"
                value="${value%\'}"
            elif [[ "$value" == \"*\" ]]; then
                value="${value#\"}"
                value="${value%\"}"
            fi
            echo "$value"
            return 0
        fi
    done < "$config_file"
    return 1
}

validate_jc_value() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 1 ]] && [[ "$v" -le 128 ]]
}

validate_junk_size() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] && [[ "$v" -ge 0 ]] && [[ "$v" -le 1280 ]]
}

validate_port() {
    local port="$1"
    # Lower bound 1, not 1024: wg-quick runs as root under systemd, so
    # binding to privileged ports (500 IKE/NAT-T, 443, 53) is fine — and
    # actually useful for defeating mobile-carrier DPI, which typically
    # leaves "service" ports unfiltered.
    # The ^[1-9][0-9]{0,4}$ regex (from upstream) forbids leading zeros ('0080'
    # would otherwise be parsed as octal in arithmetic) and bounds the length:
    # without a limit 64-bit (( )) arithmetic wraps, so 2^64+51820 would pass the
    # range check. Comparison uses plain decimal.
    if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port < 1 )) || (( port > 65535 )); then
        die "Invalid port: '$port'. Allowed range: 1-65535."
    fi
}

# Routing table IDs are interpolated into `ip route/rule` commands. Bound the
# decimal representation before arithmetic (overflow-safe) and keep the three
# reserved Linux tables out of custom policy routing.
validate_policy_table() {
    local value="$1"
    [[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
    (( 10#$value <= 4294967295 )) || return 1
    (( 10#$value < 253 || 10#$value > 255 ))
}

validate_policy_priority() {
    local value="$1"
    [[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] || return 1
    # The source lookup and its fail-closed blackhole guard occupy P and P+1.
    # Both must precede Linux's main-table rule at priority 32766.
    (( 10#$value <= 32764 ))
}

validate_fwmark() {
    local value="$1" numeric
    if [[ "$value" =~ ^0x[0-9a-fA-F]{1,8}$ ]]; then
        numeric=$(( value ))
    elif [[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] && (( 10#$value <= 4294967295 )); then
        numeric=$(( 10#$value ))
    else
        return 1
    fi
    (( numeric != 0 && numeric != 0xca6c ))
}

# Atomic root-owned interface-name marker for cleanup after a reboot. Preserve
# an existing marker: it describes an older unfinished migration and must not
# be overwritten by a newer run.
write_pending_iface_marker() {
    local marker="$1" iface="$2" tmp existing=""
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$iface" != "awg0" ]] || return 1
    if [[ -e "$marker" || -L "$marker" ]]; then
        [[ -f "$marker" && ! -L "$marker" ]] || return 1
        IFS= read -r existing < "$marker" || existing=""
        [[ "$existing" == "$iface" ]]
        return $?
    fi
    tmp=$(mktemp -p "$AWG_DIR" ".iface-marker.XXXXXX") || return 1
    _install_temp_files+=("$tmp")
    printf '%s\n' "$iface" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$marker"
}

# A pending marker is a one-slot migration journal. If the saved init still
# requires that exact interface, a crash happened before the new init commit
# (or the operator returned to that interface): cleaning it would delete the
# current egress. Cancel such a marker before applying CLI overrides. A marker
# for a different saved interface is a real outstanding cleanup and is kept.
reconcile_pending_mode_markers() {
    local config_exists="$1" saved_role="$2" saved_upstream="$3"
    local saved_egress="$4" saved_warp="$5" marker iface=""

    marker="$AWG_DIR/.upstream_cleanup_pending"
    if [[ -e "$marker" || -L "$marker" ]]; then
        [[ "$config_exists" -eq 1 && -f "$marker" && ! -L "$marker" ]] || return 1
        IFS= read -r iface < "$marker" || iface=""
        [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$iface" != "awg0" ]] || return 1
        if [[ "$saved_role" == "entry" && "$saved_upstream" == "$iface" ]]; then
            rm -f -- "$marker" || return 1
            log_warn "Removed a stale upstream cleanup marker for current iface ${iface}; current support will not be deleted."
        fi
    fi

    marker="$AWG_DIR/.warp_cleanup_pending"
    if [[ -e "$marker" || -L "$marker" ]]; then
        [[ "$config_exists" -eq 1 && -f "$marker" && ! -L "$marker" ]] || return 1
        IFS= read -r iface < "$marker" || iface=""
        [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$iface" != "awg0" ]] || return 1
        if [[ "$saved_egress" == "warp" && "$saved_warp" == "$iface" ]]; then
            if [[ -e "$AWG_DIR/.warp_cleanup_service_owner" || -L "$AWG_DIR/.warp_cleanup_service_owner" \
                  || -e "$AWG_DIR/.warp_cleanup_created_config_owner" || -L "$AWG_DIR/.warp_cleanup_created_config_owner" \
                  || -e "$AWG_DIR/.warp_cleanup_managed_config_owner" || -L "$AWG_DIR/.warp_cleanup_managed_config_owner" ]]; then
                _INSTALL_ROLLBACK_WARP_PARKED=1
                _install_restore_parked_warp_ownership || return 1
            fi
            rm -f -- "$marker" || return 1
            log_warn "Removed a stale WARP cleanup marker for current iface ${iface}; current egress will not be deleted."
        fi
    fi
    return 0
}

# A main NIC may be a VLAN interface (for example eth0.100), while managed
# tunnel names deliberately use a stricter grammar. Keep a separate validator
# for the UFW marker with the same atomic/no-symlink guarantees.
write_pending_main_iface_marker() {
    local marker="$AWG_DIR/.ufw_main_cleanup_pending" iface="$1" tmp existing=""
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,14}$ ]] || return 1
    if [[ -e "$marker" || -L "$marker" ]]; then
        [[ -f "$marker" && ! -L "$marker" ]] || return 1
        IFS= read -r existing < "$marker" || existing=""
        [[ "$existing" == "$iface" ]]
        return $?
    fi
    tmp=$(mktemp -p "$AWG_DIR" '.ufw-main-marker.XXXXXX') || return 1
    _install_temp_files+=("$tmp")
    printf '%s\n' "$iface" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$marker"
}

# Stop the previous upstream marked by initialize_setup for deferred cleanup,
# but do not disable or delete it. This runs only after the old awg0 is down;
# EXIT restores its exact active/link/enabled state.
stop_pending_old_upstream_for_transition() {
    local marker="$AWG_DIR/.upstream_cleanup_pending" iface="" unit="" conf=""
    local state="" link_present=0
    [[ -e "$marker" || -L "$marker" ]] || return 0
    [[ -f "$marker" && ! -L "$marker" ]] \
        || { log_error "Unsafe upstream cleanup marker: $marker"; return 1; }
    IFS= read -r iface < "$marker" || iface=""
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$iface" != "awg0" ]] \
        || { log_error "Invalid previous upstream iface in cleanup marker."; return 1; }
    if [[ "${AWG_ROLE:-single}" == "entry" && "${AWG_UPSTREAM_IFACE:-awg1}" == "$iface" ]]; then
        log_error "Cleanup marker points at the currently required upstream ${iface}; stop cancelled."
        return 1
    fi
    unit="awg-quick@${iface}"
    conf="/etc/amnezia/amneziawg/${iface}.conf"
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    command -v ip >/dev/null 2>&1 && ip link show dev "$iface" >/dev/null 2>&1 \
        && link_present=1
    systemctl is-enabled --quiet "$unit" 2>/dev/null \
        && _INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ENABLED=1 \
        || _INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ENABLED=0
    [[ "$state" =~ ^(active|activating|deactivating|reloading)$ ]] \
        && _INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ACTIVE=1 \
        || _INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ACTIVE=0
    _INSTALL_ROLLBACK_OLD_SUPPORT_WAS_LINK="$link_present"
    _INSTALL_ROLLBACK_OLD_SUPPORT_IFACE="$iface"
    _INSTALL_ROLLBACK_OLD_SUPPORT=1

    if [[ "$_INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ACTIVE" -eq 1 ]]; then
        log "Temporarily stopping previous upstream ${iface} until the new awg0 commit..."
        systemctl stop "$unit" \
            || { log_error "Could not stop previous upstream ${iface}."; return 1; }
    elif [[ "$state" != "inactive" && "$state" != "failed" && "$state" != "unknown" ]]; then
        log_error "Could not determine previous upstream ${iface} state reliably: ${state:-no response}"
        return 1
    fi

    if command -v ip >/dev/null 2>&1 && ip link show dev "$iface" >/dev/null 2>&1; then
        [[ -f "$conf" && ! -L "$conf" ]] \
            && timeout 15 awg-quick down "$conf" >/dev/null 2>&1 || {
                log_error "Previous upstream ${iface} remains live; the new awg0 will not be started."
                return 1
            }
    fi
    if command -v ip >/dev/null 2>&1 && ip link show dev "$iface" >/dev/null 2>&1; then
        log_error "Previous upstream interface ${iface} remained after stop."
        return 1
    fi
    return 0
}

# Free the regular marker for a new WARP iface without removing the old unit
# or its config. The parked marker survives reboots/crashes and is removed only
# after the new awg0 has been started and verified.
_park_one_pending_warp_marker() {
    local live="$1" parked="$2" old_value="$3" new_value="$4" label="$5"
    local live_value="" parked_value=""

    if [[ -e "$parked" || -L "$parked" ]]; then
        _INSTALL_ROLLBACK_WARP_PARKED=1
        [[ -f "$parked" && ! -L "$parked" ]] \
            || { log_error "Unsafe parked WARP ${label} marker: $parked"; return 1; }
        parked_value=$(<"$parked")
        [[ "$parked_value" == "$old_value" ]] \
            || { log_error "Parked WARP ${label} marker does not match the previous iface."; return 1; }
    fi

    [[ -e "$live" || -L "$live" ]] || return 0
    [[ -f "$live" && ! -L "$live" ]] \
        || { log_error "Unsafe WARP ${label} marker: $live"; return 1; }
    live_value=$(<"$live")
    [[ "$live_value" == "$old_value" || "$live_value" == "$new_value" ]] \
        || { log_error "WARP ${label} marker points to an unexpected resource: $live_value"; return 1; }

    # A new-iface marker means this is a resume after parking had completed.
    [[ "$live_value" == "$old_value" ]] || return 0
    if [[ -e "$parked" ]]; then
        rm -f -- "$live" || return 1
    else
        mv -f -- "$live" "$parked" || return 1
        _INSTALL_ROLLBACK_WARP_PARKED=1
    fi
}

park_pending_warp_ownership() {
    local pending="$AWG_DIR/.warp_cleanup_pending" old_iface="" old_conf="" new_conf=""
    [[ -e "$pending" || -L "$pending" ]] || return 0
    [[ -f "$pending" && ! -L "$pending" ]] \
        || { log_error "Unsafe WARP cleanup marker: $pending"; return 1; }
    IFS= read -r old_iface < "$pending" || old_iface=""
    [[ "$old_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$old_iface" != "awg0" ]] \
        || { log_error "Invalid previous WARP iface in cleanup marker."; return 1; }
    if [[ "${AWG_EGRESS:-direct}" == "warp" && "${AWG_WARP_IFACE:-wgcf}" == "$old_iface" ]]; then
        log_error "Cleanup marker points at the currently required WARP ${old_iface}; parking cancelled."
        return 1
    fi

    # Parking is required only for WARP->WARP with an iface rename. Other new
    # modes do not use the regular WARP ownership markers during setup.
    [[ "${AWG_EGRESS:-direct}" == "warp" && "${AWG_WARP_IFACE:-wgcf}" != "$old_iface" ]] \
        || return 0
    old_conf="/etc/wireguard/${old_iface}.conf"
    new_conf="/etc/wireguard/${AWG_WARP_IFACE:-wgcf}.conf"

    _park_one_pending_warp_marker \
        "$AWG_DIR/.wgcf_enabled_by_installer" \
        "$AWG_DIR/.warp_cleanup_service_owner" \
        "$old_iface" "${AWG_WARP_IFACE:-wgcf}" "service" || return 1
    _park_one_pending_warp_marker \
        "$AWG_DIR/.wgcf_config_created_by_installer" \
        "$AWG_DIR/.warp_cleanup_created_config_owner" \
        "$old_conf" "$new_conf" "created-config" || return 1
    _park_one_pending_warp_marker \
        "$AWG_DIR/.wgcf_config_managed_by_installer" \
        "$AWG_DIR/.warp_cleanup_managed_config_owner" \
        "$old_conf" "$new_conf" "managed-config" || return 1

    if [[ -e "$AWG_DIR/.warp_cleanup_created_config_owner" \
          && -e "$AWG_DIR/.warp_cleanup_managed_config_owner" ]]; then
        log_error "Previous WARP config is marked as both created and managed."
        return 1
    fi
    log "Previous WARP iface '${old_iface}' ownership retained until post-commit cleanup."
}

# Stop an owned quick interface whether systemd or an operator brought it up.
# Marker/config deletion is allowed only after both the link and transitional
# unit state are proven absent.
stop_owned_tunnel_runtime() {
    local kind="$1" iface="$2" conf="$3" unit="" quick="" state=""
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$iface" != "awg0" ]] || return 1
    case "$kind" in
        awg) unit="awg-quick@${iface}"; quick="awg-quick" ;;
        wg) unit="wg-quick@${iface}"; quick="wg-quick" ;;
        *) return 1 ;;
    esac
    command -v ip >/dev/null 2>&1 || return 1
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    if [[ "$state" =~ ^(active|activating|deactivating|reloading)$ ]]; then
        systemctl stop "$unit" || return 1
    elif [[ "$state" != "inactive" && "$state" != "failed" && "$state" != "unknown" ]]; then
        return 1
    fi
    if ip link show dev "$iface" >/dev/null 2>&1; then
        [[ -f "$conf" && ! -L "$conf" ]] || return 1
        timeout 15 "$quick" down "$conf" >/dev/null 2>&1 || return 1
    fi
    ip link show dev "$iface" >/dev/null 2>&1 && return 1
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    [[ "$state" == "inactive" || "$state" == "failed" || "$state" == "unknown" ]]
}

# Old support units are removed only after the new awg0 passes verification.
# Any error retains the pending/ownership markers for a safe retry and does not
# roll back the already-working new configuration.
finalize_deferred_mode_cleanup() {
    local cleanup_failed=0 pending="" old_iface=""

    pending="$AWG_DIR/.upstream_cleanup_pending"
    if [[ -e "$pending" || -L "$pending" ]]; then
        if [[ ! -f "$pending" || -L "$pending" ]]; then
            log_warn "Post-commit cleanup: unsafe upstream marker retained: $pending"
            cleanup_failed=1
        else
            IFS= read -r old_iface < "$pending" || old_iface=""
            if [[ ! "$old_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ || "$old_iface" == "awg0" ]]; then
                log_warn "Post-commit cleanup: invalid upstream iface; marker retained."
                cleanup_failed=1
            elif [[ "${AWG_ROLE:-single}" == "entry" \
                    && "${AWG_UPSTREAM_IFACE:-awg1}" == "$old_iface" ]]; then
                log_warn "Post-commit cleanup: ${old_iface} is still the current upstream; marker retained without stop/delete."
                cleanup_failed=1
            elif ! stop_owned_tunnel_runtime awg "$old_iface" \
                    "/etc/amnezia/amneziawg/${old_iface}.conf"; then
                log_warn "Post-commit cleanup: old upstream ${old_iface} could not be removed from runtime completely; marker retained."
                cleanup_failed=1
            elif ! systemctl disable "awg-quick@${old_iface}" 2>/dev/null; then
                log_warn "Post-commit cleanup: could not disable old upstream ${old_iface}; marker retained."
                cleanup_failed=1
            else
                if command -v ufw &>/dev/null && ! ufw status 2>/dev/null | grep -q inactive \
                   && ! delete_exact_owned_ufw_route "$old_iface" "AmneziaWG cascade awg0->${old_iface}"; then
                    log_warn "Post-commit cleanup: cascade UFW rule ${old_iface} is ambiguous or foreign; marker retained."
                    cleanup_failed=1
                elif rm -f -- "$pending"; then
                    log "Previous upstream ${old_iface} removed from autostart after the new awg0 commit."
                else
                    log_warn "Post-commit cleanup: could not clear upstream marker $pending."
                    cleanup_failed=1
                fi
            fi
        fi
    fi

    pending="$AWG_DIR/.warp_cleanup_pending"
    if [[ -e "$pending" || -L "$pending" ]]; then
        local old_conf="" service_unit="" service_source="" created_source="" managed_source=""
        local regular_service="$AWG_DIR/.wgcf_enabled_by_installer"
        local regular_created="$AWG_DIR/.wgcf_config_created_by_installer"
        local regular_managed="$AWG_DIR/.wgcf_config_managed_by_installer"
        local parked_service="$AWG_DIR/.warp_cleanup_service_owner"
        local parked_created="$AWG_DIR/.warp_cleanup_created_config_owner"
        local parked_managed="$AWG_DIR/.warp_cleanup_managed_config_owner"
        local marker value expected_new_service="" expected_new_conf=""
        local warp_preflight_ok=1

        if [[ ! -f "$pending" || -L "$pending" ]]; then
            log_warn "Post-commit cleanup: unsafe WARP marker retained: $pending"
            warp_preflight_ok=0
        else
            IFS= read -r old_iface < "$pending" || old_iface=""
            if [[ ! "$old_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ || "$old_iface" == "awg0" ]]; then
                log_warn "Post-commit cleanup: invalid WARP iface; marker retained."
                warp_preflight_ok=0
            elif [[ "${AWG_EGRESS:-direct}" == "warp" \
                    && "${AWG_WARP_IFACE:-wgcf}" == "$old_iface" ]]; then
                log_warn "Post-commit cleanup: ${old_iface} is still the current WARP; marker retained without stop/delete."
                warp_preflight_ok=0
            fi
        fi
        old_conf="/etc/wireguard/${old_iface}.conf"
        if [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
            expected_new_service="${AWG_WARP_IFACE:-wgcf}"
            expected_new_conf="/etc/wireguard/${AWG_WARP_IFACE:-wgcf}.conf"
        fi

        # Validate ALL markers before changing the old WARP unit/config.
        for marker in "$parked_service" "$parked_created" "$parked_managed"; do
            [[ -e "$marker" || -L "$marker" ]] || continue
            if [[ ! -f "$marker" || -L "$marker" ]]; then
                log_warn "Post-commit cleanup: unsafe parked marker retained: $marker"
                warp_preflight_ok=0
                continue
            fi
            value=$(<"$marker")
            case "$marker" in
                "$parked_service") [[ "$value" == "$old_iface" ]] && service_source="$marker" || warp_preflight_ok=0 ;;
                "$parked_created") [[ "$value" == "$old_conf" ]] && created_source="$marker" || warp_preflight_ok=0 ;;
                "$parked_managed") [[ "$value" == "$old_conf" ]] && managed_source="$marker" || warp_preflight_ok=0 ;;
            esac
        done
        for marker in "$regular_service" "$regular_created" "$regular_managed"; do
            [[ -e "$marker" || -L "$marker" ]] || continue
            if [[ ! -f "$marker" || -L "$marker" ]]; then
                log_warn "Post-commit cleanup: unsafe WARP marker retained: $marker"
                warp_preflight_ok=0
                continue
            fi
            value=$(<"$marker")
            case "$marker" in
                "$regular_service")
                    if [[ "$value" == "$old_iface" && -z "$service_source" ]]; then service_source="$marker"
                    elif [[ "$value" != "$old_iface" && "$value" != "$expected_new_service" ]]; then warp_preflight_ok=0
                    fi ;;
                "$regular_created")
                    if [[ "$value" == "$old_conf" && -z "$created_source" ]]; then created_source="$marker"
                    elif [[ "$value" != "$old_conf" && "$value" != "$expected_new_conf" ]]; then warp_preflight_ok=0
                    fi ;;
                "$regular_managed")
                    if [[ "$value" == "$old_conf" && -z "$managed_source" ]]; then managed_source="$marker"
                    elif [[ "$value" != "$old_conf" && "$value" != "$expected_new_conf" ]]; then warp_preflight_ok=0
                    fi ;;
            esac
        done
        if [[ -n "$created_source" && -n "$managed_source" ]]; then
            log_warn "Post-commit cleanup: old WARP config is both created+managed; nothing was removed."
            warp_preflight_ok=0
        fi

        if [[ "$warp_preflight_ok" -eq 1 ]]; then
            service_unit="wg-quick@${old_iface}"
            if [[ -n "$service_source" ]]; then
                if ! stop_owned_tunnel_runtime wg "$old_iface" "$old_conf"; then
                    log_warn "Post-commit cleanup: old WARP ${old_iface} could not be removed from runtime completely; ownership retained."
                    warp_preflight_ok=0
                elif ! systemctl disable "$service_unit" 2>/dev/null; then
                    log_warn "Post-commit cleanup: could not disable old WARP ${old_iface}; ownership retained."
                    warp_preflight_ok=0
                fi
            elif systemctl is-active --quiet "$service_unit" 2>/dev/null \
                 || systemctl is-enabled --quiet "$service_unit" 2>/dev/null \
                 || { command -v ip >/dev/null 2>&1 \
                      && ip link show dev "$old_iface" >/dev/null 2>&1; }; then
                log_warn "Post-commit cleanup: old WARP ${old_iface} is active/enabled/live without proven service ownership; retained."
                warp_preflight_ok=0
            fi
        fi

        if [[ "$warp_preflight_ok" -eq 1 ]]; then
            if [[ -n "$created_source" ]] && ! rm -f -- "$old_conf"; then
                log_warn "Post-commit cleanup: could not remove installer-created $old_conf."
                warp_preflight_ok=0
            fi
        fi
        if [[ "$warp_preflight_ok" -eq 1 ]]; then
            if command -v ufw &>/dev/null && ! ufw status 2>/dev/null | grep -q inactive; then
                delete_exact_owned_ufw_route "$old_iface" "AmneziaWG→WARP egress" \
                    || warp_preflight_ok=0
            fi
            # Managed (but not created) configs are always retained; only the
            # old resource's ownership markers are removed.
            if [[ "$warp_preflight_ok" -eq 1 ]]; then
                for marker in "$service_source" "$created_source" "$managed_source"; do
                    [[ -n "$marker" ]] || continue
                    rm -f -- "$marker" || warp_preflight_ok=0
                done
            fi
            if [[ "$warp_preflight_ok" -eq 1 ]] && rm -f -- "$pending"; then
                log "Previous WARP ${old_iface} cleaned up after the new awg0 commit."
            else
                log_warn "Post-commit cleanup: WARP markers retained for a later retry."
                warp_preflight_ok=0
            fi
        fi
        [[ "$warp_preflight_ok" -eq 1 ]] || cleanup_failed=1
    fi

    return "$cleanup_failed"
}

# awg0 must never race its egress tunnel during boot. A narrowly-owned
# systemd drop-in gives systemd the ordering/activation edge while the
# blackhole policy routes in awg0.conf remain the runtime fail-closed guard.
configure_awg0_dependency() {
    local required_unit="" marker_value="" tmp=""
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        required_unit="awg-quick@${AWG_UPSTREAM_IFACE:-awg1}.service"
    elif [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
        required_unit="wg-quick@${AWG_WARP_IFACE:-wgcf}.service"
    fi

    if [[ -e "$AWG0_DEPENDENCY_MARKER" || -L "$AWG0_DEPENDENCY_MARKER" ]]; then
        [[ -f "$AWG0_DEPENDENCY_MARKER" && ! -L "$AWG0_DEPENDENCY_MARKER" ]] \
            || { log_error "Invalid systemd dependency marker: $AWG0_DEPENDENCY_MARKER"; return 1; }
        IFS= read -r marker_value < "$AWG0_DEPENDENCY_MARKER" || marker_value=""
        [[ "$marker_value" == "$AWG0_DEPENDENCY_DROPIN" ]] \
            || { log_error "Invalid path in the systemd dependency marker."; return 1; }
    elif [[ -e "$AWG0_DEPENDENCY_DROPIN" || -L "$AWG0_DEPENDENCY_DROPIN" ]]; then
        log_error "Refusing to overwrite foreign systemd drop-in $AWG0_DEPENDENCY_DROPIN"
        return 1
    fi

    if [[ -z "$required_unit" ]]; then
        if [[ -n "$marker_value" ]]; then
            rm -f -- "$AWG0_DEPENDENCY_DROPIN" || return 1
            rm -f -- "$AWG0_DEPENDENCY_MARKER" || return 1
            rmdir "$(dirname "$AWG0_DEPENDENCY_DROPIN")" 2>/dev/null || true
            systemctl daemon-reload || return 1
        fi
        return 0
    fi

    if [[ -z "$marker_value" ]]; then
        printf '%s\n' "$AWG0_DEPENDENCY_DROPIN" > "$AWG0_DEPENDENCY_MARKER" \
            && chmod 600 "$AWG0_DEPENDENCY_MARKER" \
            || { rm -f "$AWG0_DEPENDENCY_MARKER"; return 1; }
    fi
    mkdir -p "$(dirname "$AWG0_DEPENDENCY_DROPIN")" || return 1
    tmp=$(mktemp -p "$(dirname "$AWG0_DEPENDENCY_DROPIN")" '.awgchain-dependency.XXXXXX') \
        || return 1
    _install_temp_files+=("$tmp")
    if ! printf '[Unit]\nRequires=%s\nAfter=%s\n' "$required_unit" "$required_unit" > "$tmp" \
       || ! chmod 0644 "$tmp" \
       || ! mv -f "$tmp" "$AWG0_DEPENDENCY_DROPIN"; then
        rm -f "$tmp"
        [[ -z "$marker_value" ]] && rm -f "$AWG0_DEPENDENCY_MARKER"
        return 1
    fi
    systemctl daemon-reload || return 1
    log "awg0 boot dependency configured: $required_unit"
}

validate_subnet() {
    local subnet="$1" o
    # Self-contained (step 0, BEFORE awg_common.sh is downloaded): does not use
    # _valid_ipv4/_cidr_bounds. Octets without leading zeros ('010...' would
    # otherwise be parsed as octal).
    if ! [[ "$subnet" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([0-9]{1,2})$ ]]; then
        die "Invalid subnet: '$subnet'. Expected CIDR /16-/30, e.g. 10.9.0.0/16."
    fi
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}" prefix="${BASH_REMATCH[5]}"
    for o in "$a" "$b" "$c" "$d"; do
        (( 10#$o <= 255 )) || die "Invalid subnet: '$subnet'. Octet out of range 0-255."
    done
    (( 10#$prefix >= 16 && 10#$prefix <= 30 )) || die "Invalid subnet: '$subnet'. Only /16-/30 masks are supported."
    # Inline arithmetic: the address must be network or network+1.
    local ip=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    local mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
    local network=$(( ip & mask ))
    local n1=$(( network + 1 ))
    local srv="$(( (n1 >> 24) & 255 )).$(( (n1 >> 16) & 255 )).$(( (n1 >> 8) & 255 )).$(( n1 & 255 ))"
    if (( ip != network && ip != n1 )); then
        die "Invalid subnet: '$subnet'. Server address must be ${srv} (network+1), or specify the network."
    fi
    # Normalize the global to <network+1>/<prefix> (server = network+1).
    AWG_TUNNEL_SUBNET="${srv}/${prefix}"
}

# Tunnel network from a CIDR string (<network+1>/<prefix> -> <network>/<prefix>).
# Needed for client isolation (issue #178): with isolation disabled, it is the
# network address itself that goes into client AllowedIPs. Self-contained
# (step 0, BEFORE awg_common.sh is loaded): does not use _cidr_bounds/_int_to_ipv4.
tunnel_network_cidr() {
    local subnet="${1:-$AWG_TUNNEL_SUBNET}"
    if ! [[ "$subnet" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([0-9]{1,2})$ ]]; then
        return 1
    fi
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}" prefix="${BASH_REMATCH[5]}"
    (( 10#$prefix <= 32 )) || return 1
    local o
    for o in "$a" "$b" "$c" "$d"; do (( 10#$o <= 255 )) || return 1; done
    local ip=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    local mask
    if (( 10#$prefix == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF )); fi
    local net=$(( ip & mask ))
    echo "$(( (net >> 24) & 255 )).$(( (net >> 16) & 255 )).$(( (net >> 8) & 255 )).$(( net & 255 ))/${prefix}"
}

# Explicit client isolation choice (issue #178). Priority:
# CLI flag > saved config > interactive question (first run only, no --yes) >
# 1 (isolated). An old config without the key = 1: before this feature,
# split modes were isolated de facto, so the behaviour is preserved.
configure_client_isolation() {
    case "$CLI_ISOLATION" in
        on)  CLIENT_ISOLATION=1; log "Client isolation from CLI: enabled." ;;
        off) CLIENT_ISOLATION=0; log "Client isolation from CLI: disabled." ;;
        default)
            if [[ -n "${CLIENT_ISOLATION:-}" ]]; then
                log "Client isolation (from config): $( [[ "$CLIENT_ISOLATION" -eq 1 ]] && echo enabled || echo disabled )."
            elif [[ "${config_exists:-0}" -eq 1 ]]; then
                CLIENT_ISOLATION=1
                log "Client isolation: enabled (pre-v5.20 config - previous behaviour)."
            elif [[ "$AUTO_YES" -eq 1 ]]; then
                CLIENT_ISOLATION=1
                log "Client isolation: enabled (--yes, default)."
            else
                local r_iso
                read -rp "Isolate VPN clients from each other? [Y/n]: " r_iso < /dev/tty
                case "$r_iso" in
                    [nN]*) CLIENT_ISOLATION=0; log "Client isolation disabled: clients will see each other inside the VPN." ;;
                    *)     CLIENT_ISOLATION=1; log "Client isolation enabled." ;;
                esac
            fi
            ;;
        *) die "Invalid --isolation='$CLI_ISOLATION'. Allowed: on|off." ;;
    esac
    export CLIENT_ISOLATION
}

# Brings ALLOWED_IPS in line with CLIENT_ISOLATION (idempotent, called on every
# run after the routing mode is determined). Isolation OFF: the tunnel subnet
# is appended to the list (modes 2/3; in mode 1, 0.0.0.0/0 already covers it).
# Isolation ON: our token is removed from mode 2 (off->on round-trip); mode 3
# is left untouched - the custom list belongs to the user, and isolation is
# enforced by the server-side DROP rule regardless.
# CLIENT_ISOLATION_NET tracks ownership of our token (empty if the token is
# user-owned or isolation is enabled) - needed to clean up the previous route
# when the tunnel subnet changes (issue #178, final audit).
_apply_isolation_to_allowed_ips() {
    local net
    net=$(tunnel_network_cidr "$AWG_TUNNEL_SUBNET") || return 0
    # Strip ALL whitespace, not just spaces: validate_cidr_list accepts tabs
    # as separators, and a tab-carrying token would otherwise slip past the
    # pattern match below - duplicating instead of a no-op (PR #179 review).
    local compact=",${ALLOWED_IPS//[[:space:]]/},"

    # Tunnel subnet changed: our previous token (persisted CLIENT_ISOLATION_NET)
    # differs from the current network - remove it in any mode and regardless
    # of the isolation state: by construction the token was added by us, not
    # the user.
    if [[ -n "${CLIENT_ISOLATION_NET:-}" && "$CLIENT_ISOLATION_NET" != "$net" ]]; then
        if [[ "$compact" == *",${CLIENT_ISOLATION_NET},"* ]]; then
            # A loop, not a single replace: a corrupted list may carry the
            # token more than once - purge every copy (PR #179 review).
            while [[ "$compact" == *",${CLIENT_ISOLATION_NET},"* ]]; do
                compact="${compact/,${CLIENT_ISOLATION_NET},/,}"
            done
            compact="${compact#,}"; compact="${compact%,}"
            ALLOWED_IPS="${compact//,/, }"
            log "Tunnel subnet changed: previous route ${CLIENT_ISOLATION_NET} removed from client AllowedIPs."
            compact=",${ALLOWED_IPS// /},"
        fi
        CLIENT_ISOLATION_NET=""
    fi

    if [[ "${CLIENT_ISOLATION:-1}" -eq 0 ]]; then
        if [[ "$ALLOWED_IPS_MODE" == "1" ]]; then
            CLIENT_ISOLATION_NET=""
        elif [[ "$compact" == *",${net},"* ]]; then
            # Already present: our previous token (CLIENT_ISOLATION_NET==net kept)
            # or a user-owned one (CLIENT_ISOLATION_NET empty) - ownership unchanged.
            :
        else
            ALLOWED_IPS="${ALLOWED_IPS}, ${net}"
            CLIENT_ISOLATION_NET="$net"
            log "Isolation disabled: tunnel subnet ${net} added to client AllowedIPs."
        fi
    else
        # Isolation ON: mode 2 - the token is always removed (the list is
        # generated by us); mode 3 - only if we added the token (ownership
        # tracked in CLIENT_ISOLATION_NET).
        if [[ "$compact" == *",${net},"* ]] \
           && { [[ "$ALLOWED_IPS_MODE" == "2" ]] || [[ "${CLIENT_ISOLATION_NET:-}" == "$net" ]]; }; then
            while [[ "$compact" == *",${net},"* ]]; do
                compact="${compact/,${net},/,}"
            done
            compact="${compact#,}"; compact="${compact%,}"
            ALLOWED_IPS="${compact//,/, }"
            log "Isolation enabled: tunnel subnet ${net} removed from client AllowedIPs."
        fi
        CLIENT_ISOLATION_NET=""
    fi
    export CLIENT_ISOLATION_NET
}

# Server-name validation for the vpn:// URI (D#180): the description field is
# shown in the Amnezia app after import. The constraints follow from storage
# in awgsetup_cfg.init (the '...' wrapper) and JSON embedding: no quotes or
# backslash, no control characters (the whole [[:cntrl:]] class: an ESC from
# arrow keys in interactive input would break the JSON - je() does not escape
# controls), no leading/trailing spaces (the client would show a visually
# empty name). Length - up to 128 BYTES in the C locale (LC_ALL=C gives a
# predictable count on any system locale; 128 bytes fit 64 two-byte UTF-8
# characters).
validate_server_name() {
    local n="$1"
    local LC_ALL=C
    [[ -n "$n" ]] || return 1
    (( ${#n} <= 128 )) || return 1
    [[ "$n" == *"'"* || "$n" == *'"'* || "$n" == *'\'* ]] && return 1
    [[ "$n" == *[[:cntrl:]]* ]] && return 1
    [[ "$n" == " "* || "$n" == *" " ]] && return 1
    return 0
}

# Trim surrounding whitespace (friendliness: an accidental trailing space in
# --server-name or interactive input must not fail the install).
_trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# --mobile (D#38, field test 26 jun): mobile-setup shorthand =
# --preset=mobile + port 443/udp. The main mobile problem is the port: on MTS
# the default 39743/udp is dead while 443/udp (looks like QUIC/HTTP3) works.
# Expanded into CLI_PRESET/CLI_PORT BEFORE their consumers: an explicit
# user --port wins, a contradicting --preset is an error.
resolve_mobile_flag() {
    [[ "${CLI_MOBILE:-0}" -eq 1 ]] || return 0
    if [[ -n "${CLI_PRESET:-}" && "$CLI_PRESET" != "mobile" ]]; then
        die "--mobile is incompatible with --preset=${CLI_PRESET}: --mobile already implies preset mobile."
    fi
    CLI_PRESET="mobile"
    if [[ -z "$CLI_PORT" ]]; then
        CLI_PORT=443
        log "--mobile: port 443/udp (mobile carriers often kill non-standard UDP ports)."
    fi
}

# Server name in the Amnezia app (D#180). Priority: CLI flag > saved config >
# interactive question (first run only, no --yes) > 'AWG Server'. A config
# value is re-validated: the file can be hand-edited, and the name goes into
# the vpn:// URI JSON.
configure_server_name() {
    local _name
    if [[ -n "$CLI_SERVER_NAME" ]]; then
        _name=$(_trim_ws "$CLI_SERVER_NAME")
        validate_server_name "$_name" \
            || die "Invalid --server-name: no quotes, backslash or control characters, at most 128 bytes."
        AWG_SERVER_NAME="$_name"
        log "Server name from CLI: ${AWG_SERVER_NAME}"
    elif [[ -n "${AWG_SERVER_NAME:-}" ]]; then
        _name=$(_trim_ws "$AWG_SERVER_NAME")
        if validate_server_name "$_name"; then
            AWG_SERVER_NAME="$_name"
        else
            log_warn "AWG_SERVER_NAME from $CONFIG_FILE is invalid, using 'AWG Server'."
            AWG_SERVER_NAME="AWG Server"
        fi
    elif [[ "${config_exists:-0}" -eq 1 || "$AUTO_YES" -eq 1 ]]; then
        AWG_SERVER_NAME="AWG Server"
    else
        local input_name
        while true; do
            read -rp "Server name in the Amnezia app [AWG Server]: " input_name < /dev/tty
            input_name=$(_trim_ws "$input_name")
            if [[ -z "$input_name" ]]; then AWG_SERVER_NAME="AWG Server"; break; fi
            if validate_server_name "$input_name"; then AWG_SERVER_NAME="$input_name"; break; fi
            log_warn "No quotes, backslash or control characters, at most 128 bytes. Try again."
        done
    fi
    export AWG_SERVER_NAME
}

# Subnet-change guard: [Peer] blocks are carried over verbatim on reinstall
# (render_server_config), and their addresses were issued in the OLD subnet.
# Changing the subnet under live clients breaks them: old IPv4s can fall
# outside the new range, and IPv6 suffixes can collide (the decimal /24
# encoding vs hex for non-/24 masks yields two peers with the same ::x). So the
# install aborts when peers exist and the subnet differs (PR #167 review).
# Self-contained (step 0, BEFORE awg_common.sh is downloaded). The old
# subnet is the first Address value in the awg0.conf [Interface]: it is the
# normalized <network+1>/<prefix>, and the new AWG_TUNNEL_SUBNET has been
# normalized by validate_subnet by the time of the call - a plain string
# comparison is enough.
guard_subnet_change_with_peers() {
    [[ -f "$SERVER_CONF_FILE" ]] || return 0
    grep -q '^\[Peer\]' "$SERVER_CONF_FILE" 2>/dev/null || return 0
    local old_subnet
    # Address may be dual-stack ("IPv4/n, IPv6/n") in any order - pick the IPv4
    # element, not just the first comma field (an IPv6-first Address would
    # otherwise look like a subnet change). No IPv4 -> empty -> fail closed below.
    old_subnet=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" 2>/dev/null \
        | tr ',' '\n' | sed 's/[[:space:]]//g' \
        | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$')
    if [[ -z "$old_subnet" ]]; then
        # Peers exist but the old subnet cannot be determined - fail closed: a
        # silent continue would re-render the config in the new subnet and break
        # the clients.
        die "${SERVER_CONF_FILE} already contains peers, but the Address line in [Interface] is unreadable - the subnet-change check is impossible. Restore the Address line, or remove the clients (sudo bash $MANAGE_SCRIPT_PATH remove <name>), or run --uninstall and reinstall from scratch."
    fi
    if [[ "$old_subnet" != "$AWG_TUNNEL_SUBNET" ]]; then
        die "The tunnel subnet changed (${old_subnet} -> ${AWG_TUNNEL_SUBNET}), but ${SERVER_CONF_FILE} already contains peers: their addresses were issued in the old subnet, and changing it breaks the clients. Options: keep the previous subnet; remove all clients (sudo bash $MANAGE_SCRIPT_PATH remove <name>); or run --uninstall and reinstall from scratch."
    fi
    return 0
}

# Endpoint validation (FQDN / IPv4 / [IPv6]).
# Returns 0 if the endpoint is safe and matches one of the formats,
# otherwise 1 (the caller decides between die or log_warn + unset).
# Forbids newline/CR/quotes/backslash to prevent injection into
# awgsetup_cfg.init and client.conf via the --endpoint flag (audit).
validate_endpoint() {
    local ep="$1"
    [[ -n "$ep" ]] || return 1
    # Forbid characters that could break the config or inject content
    [[ "$ep" != *$'\n'* && "$ep" != *$'\r'* && \
       "$ep" != *"'"* && "$ep" != *'"'* && "$ep" != *'\\'* && \
       "$ep" != *' '* && "$ep" != *$'\t'* ]] || return 1
    # Bracketed [IPv6] form: structural check of the bracket contents. The previous
    # charset-only test let junk like [:::] / [1:2:3] through. Mirrors _valid_ipv6.
    if [[ "$ep" == \[*\] ]]; then
        local inner="${ep#\[}"; inner="${inner%\]}"
        [[ "$inner" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
        case "$inner" in
            *:::*|*::*::*) return 1 ;;
        esac
        [[ "$inner" == :* && "$inner" != ::* ]] && return 1
        [[ "$inner" == *: && "$inner" != *:: ]] && return 1
        local has_dcolon=0; [[ "$inner" == *::* ]] && has_dcolon=1
        local IFS=':' parts=() p ngroups=0
        read -ra parts <<< "$inner"
        for p in "${parts[@]}"; do
            [[ -z "$p" ]] && continue
            [[ "$p" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
            ngroups=$((ngroups + 1))
        done
        if [[ $has_dcolon -eq 1 ]]; then
            (( ngroups <= 7 )) || return 1
        else
            (( ngroups == 8 )) || return 1
        fi
        return 0
    fi
    # Otherwise FQDN or IPv4
    [[ "$ep" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*|[0-9]{1,3}(\.[0-9]{1,3}){3})$ ]] || return 1
    # If IPv4 format - additionally validate octet range 0-255
    if [[ "$ep" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        [[ "${BASH_REMATCH[1]}" -le 255 && "${BASH_REMATCH[2]}" -le 255 && \
           "${BASH_REMATCH[3]}" -le 255 && "${BASH_REMATCH[4]}" -le 255 ]] || return 1
    fi
    return 0
}

validate_cidr_list() {
    local input="$1" cidr o nospace
    input="${input//$'\r'/}"
    input="${input//$'\t'/ }"
    # A newline means injection into awgsetup_cfg.init (read <<< only sees the
    # first line, the rest would pass unchecked). Same policy as validate_endpoint.
    [[ "$input" != *$'\n'* ]] || return 1
    # Structural comma check before split: bash IFS drops a trailing empty element,
    # so '10.0.0.0/24,' used to pass. Reject leading/trailing/double comma and empty
    # input (spaces are ignored for this check).
    nospace="${input// /}"
    case "$nospace" in
        ""|,*|*,|*,,*) return 1 ;;
    esac
    IFS=',' read -ra cidrs <<< "$input"
    for cidr in "${cidrs[@]}"; do
        cidr="${cidr// /}"
        # Octets without leading zeros; prefix 0-32 enforced in the regex (no octal).
        if ! [[ "$cidr" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([0-9]|[12][0-9]|3[0-2])$ ]]; then
            return 1
        fi
        for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
            (( o <= 255 )) || return 1
        done
    done
}

configure_routing_mode() {
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then
        ALLOWED_IPS_MODE=$CLI_ROUTING_MODE
        if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then
            ALLOWED_IPS=$CLI_CUSTOM_ROUTES
            if [ -z "$ALLOWED_IPS" ]; then die "No networks specified for --route-custom."; fi
        fi
        log "Routing mode from CLI: $ALLOWED_IPS_MODE"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        ALLOWED_IPS_MODE=2
        log "Routing mode: Amnezia+DNS (--yes, default)."
    else
        echo ""
        log "Select routing mode (client AllowedIPs):"
        echo "  1) All traffic (0.0.0.0/0) - Max privacy, may block LAN"
        echo "  2) Amnezia List+DNS (default) - Recommended for bypassing restrictions"
        echo "  3) Only specified networks (Split Tunneling)"
        read -rp "Your choice [2]: " r_mode < /dev/tty
        ALLOWED_IPS_MODE=${r_mode:-2}
    fi
    case "$ALLOWED_IPS_MODE" in
        1) ALLOWED_IPS="0.0.0.0/0"
           log "Selected mode: All traffic." ;;
        3) if [[ -z "$CLI_CUSTOM_ROUTES" ]]; then
               read -rp "Enter networks (a.b.c.d/xx,...): " ALLOWED_IPS < /dev/tty
               while ! validate_cidr_list "$ALLOWED_IPS"; do
                   log_warn "Invalid CIDR format: '$ALLOWED_IPS'. Expected: x.x.x.x/y[,x.x.x.x/y]"
                   read -rp "Try again: " ALLOWED_IPS < /dev/tty
               done
           else
               ALLOWED_IPS=$CLI_CUSTOM_ROUTES
               if ! validate_cidr_list "$ALLOWED_IPS"; then
                   die "Invalid CIDR format: '$ALLOWED_IPS'. Expected: x.x.x.x/y[,x.x.x.x/y]"
               fi
           fi
           log "Selected mode: Custom ($ALLOWED_IPS)" ;;
        *) ALLOWED_IPS_MODE=2
           # iOS breaks the tunnel if the list starts with 0.0.0.0/5: that block covers
           # the reserved 0.0.0.0/8 which the iOS kernel chokes on, so it never reaches the
           # rest of the routes. 1.0.0.0/8 + 2.0.0.0/7 + 4.0.0.0/6 is the same range minus the
           # zero block (0.0.0.0/8 is non-routable anyway). Do not revert to 0.0.0.0/5 (Issue #42).
           ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
           log "Selected mode: Amnezia List+DNS." ;;
    esac
    if [ -z "$ALLOWED_IPS" ]; then die "Failed to determine AllowedIPs."; fi
    export ALLOWED_IPS_MODE ALLOWED_IPS
}

# ==============================================================================
# AWG 2.0 parameter generation (inline — needed in step 0, before downloading awg_common.sh)
# ==============================================================================

# Random number [min, max] via /dev/urandom (uint32 support)
rand_range() {
    local min=$1 max=$2
    local range=$((max - min + 1))
    local random_val
    random_val=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ')
    if [[ -z "$random_val" || ! "$random_val" =~ ^[0-9]+$ ]]; then
        # Fallback: three $RANDOM (15 bits each) with XOR overlap cover bits
        # 0-30, i.e. the full [0, 2^31-1]. The previous variant
        # (RANDOM<<15|RANDOM) gave only 30 bits - the upper half of the H
        # range could never come up.
        random_val=$(( (RANDOM << 16) ^ (RANDOM << 8) ^ RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Generate 4 non-overlapping ranges for AWG H1-H4.
# Algorithm: 8 random values → sort → 4 (low, high) pairs.
# Sorting gives low <= high; the strict checks below guarantee a gap between
# pairs (touching bounds = overlap at a single point) and a lower bound >= 5
# (values 1-4 are reserved for vanilla WireGuard message types).
# Minimum width per range = 1000 (for proper obfuscation).
# Prints 4 "low-high" lines to stdout. Returns 1 on failure.
# Mitigates Russian DPI fingerprinting of static H values (#38).
#
# Range: [0, 2^31-1] = [0, 2147483647]. The AmneziaWG spec allows the
# full uint32 (0-4294967295), but the standalone Windows client
# `amneziawg-windows-client` has a UI validator capped at 2^31-1 in
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, not yet fixed). Values above
# 2^31-1 work on the server, but the client's config editor underlines
# them as invalid and blocks saving. For compatibility we generate in
# the safe half of the range (#40).
#
# Optimization: a single `od -N32 -tu4` call reads 32 bytes = 8 uint32
# values in one operation, instead of 8 separate subprocess calls via
# rand_range. Falls back to rand_range if /dev/urandom is unavailable.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        raw=$(od -An -N32 -tu4 /dev/urandom 2>/dev/null | tr -s ' \n' '\n' | sed '/^$/d')
        if [[ -n "$raw" ]]; then
            local count=0
            while IFS= read -r _v; do
                [[ "$_v" =~ ^[0-9]+$ ]] || continue
                # Mask 0x7FFFFFFF: clears the top bit, value in [0, 2^31-1]
                # with no bias (each lower bit stays independent).
                arr+=("$(( _v & 2147483647 ))")
                count=$((count + 1))
                (( count == 8 )) && break
            done <<< "$raw"
        fi
        if (( ${#arr[@]} != 8 )); then
            arr=()
            local _i
            for _i in 1 2 3 4 5 6 7 8; do
                arr+=("$(rand_range 0 2147483647)")
            done
        fi
        local sorted
        sorted=$(printf '%s\n' "${arr[@]}" | sort -n)
        arr=()
        while IFS= read -r _v; do arr+=("$_v"); done <<< "$sorted"
        if (( ${arr[0]} >= 5 )) && \
           (( ${arr[1]} - ${arr[0]} >= 1000 )) && \
           (( ${arr[3]} - ${arr[2]} >= 1000 )) && \
           (( ${arr[5]} - ${arr[4]} >= 1000 )) && \
           (( ${arr[7]} - ${arr[6]} >= 1000 )) && \
           (( ${arr[2]} > ${arr[1]} )) && \
           (( ${arr[4]} > ${arr[3]} )) && \
           (( ${arr[6]} > ${arr[5]} )); then
            printf '%s-%s\n' "${arr[0]}" "${arr[1]}"
            printf '%s-%s\n' "${arr[2]}" "${arr[3]}"
            printf '%s-%s\n' "${arr[4]}" "${arr[5]}"
            printf '%s-%s\n' "${arr[6]}" "${arr[7]}"
            return 0
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

# Generate CPS string for I1
# Format: "<r N>" where N is the number of random bytes (32-256)
generate_cps_i1() {
    local n
    n=$(rand_range 32 256)
    echo "<r ${n}>"
}

# Generate I1 in "QUIC v1 Initial" mode — a literal `<b 0xHEX...>` whose HEX
# body forms a valid QUIC Initial packet (RFC 9000 §17.2.2). Idea: a
# mobile-carrier DPI looks at the first byte and a few bytes that follow,
# sees 0xc? + version 0x00000001 + a plausible structure, and lets the
# traffic through as "ordinary QUIC browser traffic". The real
# AWG handshake starts AFTER this blob; the server strips the same I1 from
# the incoming packet (it has the exact same I1 in its config).
#
# Layout:
#   [0]       type byte   — bits 7-6 = 11 (long + fixed), 5-4 = 00 (Initial),
#                           3-0 arbitrary (in real QUIC these are obscured by
#                           header-protection XOR — we emulate that with a
#                           random value in [0, 15]). Net: 0xc0..0xcf.
#   [1-4]    version      — 0x00000001 (QUIC v1)
#   [5]      dcid_len     — 16-20
#   [6..]    dcid         — random
#   [..]     scid_len     — 8-16
#   [..]     scid         — random
#   [..]     token_len    — 0 (1-byte varint 0x00)
#   [..]     length       — 2-byte varint = 3 (PN) + payload_len
#   [..]     packet_num   — 3 random bytes
#   [..]     payload      — random bytes (~1 KiB, looks like AEAD output)
#
# Target total size ≈1100-1250 bytes, matching a typical QUIC Initial.
generate_cps_i1_quic() {
    local dcid_len scid_len total overhead payload_len enc_len
    local type_byte version dcid scid enc_b1 enc_b2 pn payload
    local dcid_len_h scid_len_h
    dcid_len=$(rand_range 16 20)
    scid_len=$(rand_range 8 16)
    total=$(rand_range 1100 1250)
    overhead=$(( 1 + 4 + 1 + dcid_len + 1 + scid_len + 1 + 2 + 3 ))
    payload_len=$(( total - overhead ))
    (( payload_len < 1 )) && payload_len=1
    enc_len=$(( 3 + payload_len ))
    if (( enc_len > 16383 )); then
        enc_len=16383
        payload_len=$(( enc_len - 3 ))
    fi
    # 2-byte varint (top 2 bits = 01, remaining 14 bits = value BE)
    enc_b1=$(printf '%02x' $(( 0x40 | (enc_len >> 8) )))
    enc_b2=$(printf '%02x' $(( enc_len & 0xFF )))
    # First byte: 0xc0 | random(0..15). Emulates the header-protected bits.
    type_byte=$(printf '%02x' $(( 0xc0 | $(rand_range 0 15) )))
    version="00000001"
    dcid=$(od -An -tx1 -N"$dcid_len" /dev/urandom 2>/dev/null | tr -d ' \n')
    scid=$(od -An -tx1 -N"$scid_len" /dev/urandom 2>/dev/null | tr -d ' \n')
    pn=$(od -An -tx1 -N3 /dev/urandom 2>/dev/null | tr -d ' \n')
    payload=$(od -An -tx1 -N"$payload_len" /dev/urandom 2>/dev/null | tr -d ' \n')
    if [[ -z "$dcid" || -z "$scid" || -z "$pn" || -z "$payload" ]]; then
        log_error "generate_cps_i1_quic: failed to read /dev/urandom"
        return 1
    fi
    dcid_len_h=$(printf '%02x' "$dcid_len")
    scid_len_h=$(printf '%02x' "$scid_len")
    printf '<b 0x%s%s%s%s%s%s00%s%s%s%s>\n' \
        "$type_byte" "$version" \
        "$dcid_len_h" "$dcid" \
        "$scid_len_h" "$scid" \
        "$enc_b1" "$enc_b2" \
        "$pn" "$payload"
    return 0
}

# Change I1 only, without regenerating J/S/H or clearing manually configured
# I2-I5. On a repeat run with only --i1-mode, the full generator would make all
# previously issued client configs incompatible for no reason.
generate_i1_for_mode() {
    local mode="${1:-random}"
    case "$mode" in
        random)
            AWG_I1=$(generate_cps_i1)
            ;;
        quic)
            AWG_I1=$(generate_cps_i1_quic) || die "QUIC I1 generation failed"
            log "  I1 mode: quic (fake QUIC v1 Initial, $(( (${#AWG_I1} - 6) / 2 )) bytes)"
            ;;
        *)
            die "Invalid --i1-mode='$mode'. Allowed: random, quic."
            ;;
    esac
    AWG_I1_MODE="$mode"
    export AWG_I1 AWG_I1_MODE
}

# Generate all AWG 2.0 parameters
generate_awg_params() {
    local preset="${CLI_PRESET:-default}"
    log "Generating AWG 2.0 parameters (preset: $preset)..."

    case "$preset" in
        default)
            # Jc 3-6: balance between obfuscation and mobile compatibility (Discussion #38)
            AWG_Jc=$(rand_range 3 6)
            AWG_Jmin=$(rand_range 40 89)
            # Jmax = Jmin + 50..250 (~90-339 bytes, Issue #42)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 50 250) ))
            ;;
        mobile)
            # Jc=3 fixed: alkorrnd (Tele2) — Jc=3 >95%, Jc=4 ~30%, Jc=5 <5%
            # Narrow Jmax: markmokrenko (Yota) — Jmax=70 works, Jmax>300 blocked
            AWG_Jc=3
            AWG_Jmin=$(rand_range 30 50)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 20 80) ))
            log "  Preset 'mobile': Jc=3, narrow Jmax for mobile networks"
            ;;
        *)
            die "Unknown preset: '$preset'. Allowed: default, mobile"
            ;;
    esac

    # Individual CLI overrides (on top of preset)
    if [[ -n "${CLI_JC:-}" ]]; then
        validate_jc_value "$CLI_JC" || die "Invalid --jc=$CLI_JC (allowed: 1-128)"
        AWG_Jc="$CLI_JC"
    fi
    if [[ -n "${CLI_JMIN:-}" ]]; then
        validate_junk_size "$CLI_JMIN" || die "Invalid --jmin=$CLI_JMIN (allowed: 0-1280)"
        AWG_Jmin="$CLI_JMIN"
    fi
    if [[ -n "${CLI_JMAX:-}" ]]; then
        validate_junk_size "$CLI_JMAX" || die "Invalid --jmax=$CLI_JMAX (allowed: 0-1280)"
        AWG_Jmax="$CLI_JMAX"
    fi

    # Sanity: Jmax >= Jmin
    if [[ "$AWG_Jmax" -lt "$AWG_Jmin" ]]; then
        die "Jmax ($AWG_Jmax) cannot be less than Jmin ($AWG_Jmin)"
    fi

    AWG_PRESET="$preset"
    AWG_S1=$(rand_range 15 150)
    AWG_S2=$(rand_range 15 150)

    # Critical kernel constraint: S1+56 != S2
    # Prevents init and response messages from having the same size
    while [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; do
        AWG_S2=$(rand_range 15 150)
    done

    # ⚠️ The lower bounds of S3/S4 are incompatible with AmneziaWG 3.0 header
    # protection. There the ChaCha20 nonce is never transmitted: it is taken from
    # the first 12 bytes of the S padding of the message in question
    # (HEADER_PROTECTION_NONCE_SIZE = 12), so both implementations REJECT a config
    # where any of S1-S4 is below 12 while a header protection key is set. The
    # kernel module returns -EINVAL (src/netlink.c, has_protection && val16 <
    # HEADER_PROTECTION_NONCE_SIZE); amneziawg-go errors out in device/uapi.go
    # (present since v3.0.0). So the failure is LOUD - there is no silent crypto
    # weakening; verified against upstream sources on 2 aug 2026. While we stay on
    # 2.0 and set no header protection key, these ranges are safe. WHEN header
    # protection is enabled, raise both lower bounds to 12, otherwise a share of
    # installs will simply fail to bring the interface up. Keep this in step with
    # the _kernel_supports_awg3 gate.
    AWG_S3=$(rand_range 8 55)

    # Second size collision: response+S2 != cookie+S3, that is S3 != S2+28.
    # Message sizes (src/messages.h of the kernel module): init 148, response 92,
    # cookie reply 64. The first two were measured on the wire, the cookie one is
    # 4 (header) + 4 (receiver_index) + 24 (nonce) + 32 (cookie 16 + authtag 16).
    # That gives three ways for the final packet sizes to match:
    #   init/response   -> S2 = S1 + 56  (handled by the loop above)
    #   response/cookie -> S3 = S2 + 28  (handled here)
    #   init/cookie     -> S3 = S1 + 84  (unreachable: the minimum S1+84 is 99
    #                                     while S3 tops out at 55, no loop needed)
    # We regenerate S3 rather than S2, since S2 already passed the S1+56 check.
    while [[ $((AWG_S2 + 28)) -eq $AWG_S3 ]]; do
        AWG_S3=$(rand_range 8 55)
    done

    AWG_S4=$(rand_range 4 27)

    # H1-H4: 4 random non-overlapping uint32 ranges.
    # Per-install randomization protects against Russian DPI fingerprinting
    # of static H values (Discussion #38, elvaleto/Klavishnik).
    # Algorithm: 8 random uint32 → sort → 4 non-overlapping pairs.
    local _h_lines
    mapfile -t _h_lines < <(generate_awg_h_ranges) || true
    if [[ ${#_h_lines[@]} -ne 4 ]]; then
        die "Failed to generate H1-H4 ranges."
    fi
    AWG_H1="${_h_lines[0]}"
    AWG_H2="${_h_lines[1]}"
    AWG_H3="${_h_lines[2]}"
    AWG_H4="${_h_lines[3]}"

    # I1: CPS concealment. Two modes:
    #   random (default) — <r N>, N random bytes 32-256
    #   quic             — <b 0x...>, ≈1100-1250 bytes shaped as a QUIC v1
    #                      Initial packet. Strongest mode against mobile
    #                      carrier DPI. Server and clients receive the SAME
    #                      I1 via their configs; the AWG handshake follows
    #                      these bytes.
    generate_i1_for_mode "${CLI_I1_MODE:-${AWG_I1_MODE:-random}}"

    # I2-I5 are NOT generated here (the admin sets them manually in awg0.conf, issue #71).
    # A fresh param set (first install or --preset/--jc/--jmin/--jmax) clears any stale
    # I2-I5 loaded from awgsetup_cfg.init so the new obfuscation set does not carry old
    # values (--preset regenerates the whole set).
    unset AWG_I2 AWG_I3 AWG_I4 AWG_I5

    export AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_PRESET
    export AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_I1 AWG_I1_MODE

    log "  Jc=$AWG_Jc, Jmin=$AWG_Jmin, Jmax=$AWG_Jmax"
    log "  S1=$AWG_S1, S2=$AWG_S2, S3=$AWG_S3, S4=$AWG_S4"
    log "  H1=$AWG_H1"
    log "  H2=$AWG_H2"
    log "  H3=$AWG_H3"
    log "  H4=$AWG_H4"
    log "  I1=$AWG_I1"
    log "AWG 2.0 parameters generated."
}

# ==============================================================================
# System optimization (new in v5.0)
# ==============================================================================

# Detect hardware characteristics
detect_hardware() {
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    CPU_CORES=$(nproc)
    MAIN_NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    log "Hardware: RAM=${TOTAL_RAM_MB}MB, CPU=${CPU_CORES} cores, NIC=${MAIN_NIC}"
}

# _cleanup_package_list : the packages cleanup_system removes on this OS.
# One source for both the cleanup and the step 0 question, otherwise they drift apart.
# ⚠️ OS_ID deliberately has NO default: an unknown OS must not get the destructive
# superset (snapd, lxd-agent-loader and wiping the snap directories). Empty = not Ubuntu.
_cleanup_package_list() {
    local list="modemmanager networkd-dispatcher unattended-upgrades packagekit udisks2"
    [[ "${OS_ID:-}" == "ubuntu" ]] && list="snapd $list lxd-agent-loader"
    printf '%s' "$list"
}

# _boot_critical_package_list : packages whose loss leaves the server unable to
# boot or unable to reach the network. The core of the list comes from Issue
# #223: there `apt full-upgrade` in step 1 removed packages including udev,
# initramfs-tools and netplan.io among them, and the server stopped booting.
# Without udev there is no /dev/disk/by-label, systemd never sees the partitions
# that fstab refers to by label, and it drops into emergency mode (after 90
# seconds of waiting by default, see DefaultDeviceTimeoutSec; both partitions
# were waited for in parallel, not one after the other). Some names were added
# on reasoning rather than from that incident: losing openssh-server,
# systemd-resolved or ifupdown cuts off access just as reliably.
#
# How it gets there. cleanup_system purges its own list, and the ubuntu-server
# meta-package turns out to be a reverse dependency of what is being removed, so
# it goes along. On images where it was the only manual root, everything hanging
# under it (ubuntu-standard, ubuntu-minimal and their dependencies) becomes "no
# longer required". That alone is not a removal: apt lists such packages and
# suggests `apt autoremove`. But while resolving dependencies for the upgrade
# the resolver may pick removal over upgrading, and for a package nobody needs
# any more that is the cheap choice. In Issue #223 it made exactly that choice.
# We never reproduced the resolver's decision: the outcome is known, the motive
# is not.
#
# ⚠️ The names ubuntu-server/ubuntu-minimal/ubuntu-standard exist only on
# Ubuntu. Debian has no such chain, and there the list acts as ordinary
# insurance: _installed_boot_critical simply will not find the absent ones.
#
# ⚠️ This list is NOT the hold list from cleanup_system: that one guards during
# the purge, this one during the upgrade. They overlap; their purpose differs.
_boot_critical_package_list() {
    printf '%s' "udev initramfs-tools openssh-server netplan.io netplan-generator systemd-resolved ifupdown ubuntu-minimal ubuntu-standard"
}

# _pkg_present : 0 if the package is present in any working shape. We look at
# the third Status field rather than at the "ok installed" substring: right
# after a purge or an interrupted upgrade a package can sit as half-configured
# or unpacked. For our purposes it is present and has to be protected.
_pkg_present() {
    local state
    state="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null | awk '{print $3}')"
    case "$state" in
        ""|not-installed|config-files) return 1 ;;
        *) return 0 ;;
    esac
}

# _installed_boot_critical : the ones actually installed on this system.
# Prints one name per line; empty output is a reason to worry rather than a
# normal outcome, since udev is present on virtually every server.
_installed_boot_critical() {
    local critical_list
    critical_list="$(_boot_critical_package_list)"
    local pkg
    for pkg in $critical_list; do
        if _pkg_present "$pkg"; then
            printf '%s\n' "$pkg"
        fi
    done
}

# _pkg_installed_ok : 0 only if the package is fully installed AND configured.
# The difference from _pkg_present is deliberate and the risk is asymmetric. For
# the SNAPSHOT, "unpacked but not configured" counts as present: the package is
# there and has to be protected. For the VERDICT before the reboot it does not:
# initramfs-tools left unpacked means postinst never ran and no initramfs was
# built for the new kernel. The server will not boot, though the package
# formally "exists".
_pkg_installed_ok() {
    # We look at the THIRD field only. A full Status line is "<want> <error>
    # <status>", and anchoring the whole "install ok installed" pins the want
    # flag as well: `apt-mark hold` sets "hold ok installed", so a perfectly
    # healthy package would read as lost. That is not theoretical here -
    # cleanup_system goes out of its way to preserve operator holds. The
    # installed state still rejects what this predicate exists for: unpacked,
    # half-configured, half-installed, config-files.
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null | awk '{print $3}')" == "installed" ]]
}

# The snapshot SURVIVES installer restarts and can only grow.
#
# The installer itself asks the user to run it again after a failure, and by
# then a package may already be gone: apt can remove udev and then fail, in
# which case the check at the end of the step never runs at all. A snapshot
# taken afresh on the next run will not see the removed package, and the check
# will compare the system against an impoverished baseline - staying silent
# about exactly the state it was written for. So we merge with what was
# recorded earlier.
#
# ONLY known names are taken from the file: a corrupted or substituted file must
# not turn into a list of arbitrary packages to install.
_boot_critical_snapshot() {
    local now stored known union
    now="$(_installed_boot_critical)"
    stored=""
    if [[ -e "$BOOT_CRITICAL_SNAPSHOT_FILE" && ! -r "$BOOT_CRITICAL_SNAPSHOT_FILE" ]]; then
        # Otherwise an unreadable file is indistinguishable from a missing one:
        # the list would quietly shrink and the function would immediately
        # overwrite the history with it, while its contract is to only grow.
        log_warn "$BOOT_CRITICAL_SNAPSHOT_FILE exists but cannot be read. The list from previous runs will not be taken into account."
    elif [[ -r "$BOOT_CRITICAL_SNAPSHOT_FILE" ]]; then
        known="$(_boot_critical_package_list | tr ' ' '\n')"
        stored="$(grep -Fxf <(printf '%s\n' "$known") "$BOOT_CRITICAL_SNAPSHOT_FILE" 2>/dev/null || true)"
    fi
    union="$(printf '%s\n%s\n' "$now" "$stored" | grep -v '^$' | sort -u)"
    if [[ -n "$union" ]]; then
        mkdir -p "$AWG_DIR" 2>/dev/null || true
        printf '%s\n' "$union" > "$BOOT_CRITICAL_SNAPSHOT_FILE" 2>/dev/null \
            || log_warn "Could not save the protected package list to $BOOT_CRITICAL_SNAPSHOT_FILE. The check survives this run but not the next one."
    fi
    printf '%s' "$union"
}

# _verify_boot_critical : the last line of defence before the reboot. Takes the
# snapshot made BEFORE the upgrade and compares it against the state right now.
#
# The call sits right next to request_reboot and must not drift away from it.
# The whole point is that nothing capable of removing a package runs after it:
# step 1 still has install_packages between the upgrade and the reboot, and that
# calls apt install without --no-remove. A check placed before it would leave a
# window of exactly the class it is meant to close.
#
# Why this is needed at all: apt is allowed to remove packages in order to
# resolve dependencies, and in Issue #223 udev went that way - the server
# stopped booting, and the reboot is one we trigger ourselves. So the catch
# belongs here, while the server is still reachable: after the reboot the repair
# would need the hosting provider's console.
_verify_boot_critical() {
    local critical_before="$1"
    if [[ -z "$critical_before" ]]; then
        log_warn "The protected package list is empty, there is nothing to compare against. That is abnormal for Ubuntu and Debian: check dpkg-query -W udev, the server may fail to boot after the reboot."
        return 0
    fi
    local critical_lost=""
    local pkg
    for pkg in $critical_before; do
        _pkg_installed_ok "$pkg" || critical_lost+="$pkg "
    done
    [[ -n "$critical_lost" ]] || return 0
    critical_lost="${critical_lost% }"

    # Before blaming the upgrade: a broken dpkg produces exactly the same
    # picture, and a message saying "packages were removed" would send the
    # diagnosis the wrong way.
    _dpkg_usable || die "dpkg stopped answering, so there is no way to check the package state. Do NOT reboot the server. Run: dpkg --configure -a; apt-get check - then start the installer again."

    log_warn "Packages the server cannot boot without have disappeared: $critical_lost"
    log_warn "Restoring them..."
    local restore_out restore_rc

    # Stage 1: ONE transaction with every lost name at once.
    # What matters is WHAT becomes a resolver goal. One at a time, `apt-get
    # install udev` knows nothing about the other lost names: they are not
    # goals, and apt is free to leave them absent. In one command they all
    # become goals and apt looks for a version set that suits the group. In
    # Issue #223 the per-package pass produced five refusals and a single
    # transaction was never tried, which is the reason to start with it.
    # ⚠️ Not a guarantee, for two reasons.
    # First: if the old version is pinned by a package that is NOT in the lost
    # list (in Issue #223 that was systemd-resolved, with a Depends on exactly
    # 8.12 of both systemd and libsystemd-shared; the second link there is udev
    # declaring Breaks on a systemd older than 8.17, and together the two
    # conditions locked the group), it does not become a goal here either. apt
    # MAY touch it anyway and sometimes does, but that is its
    # choice, not an obligation: it prefers to leave non-goal packages alone.
    # Second: --no-remove aborts the transaction on ANY removal in the plan, not
    # only on removing something protected. A solution of the form "drop the
    # package in the way and install the group" is rejected outright.
    # Hence stage 2 below, and the final verdict from the full-set re-check. The
    # flag is still needed: restoring one package must not cost another.
    restore_out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove $critical_lost 2>&1)"
    restore_rc=$?
    # The wording is cautious on purpose: a zero from apt means "there was
    # nothing to do" just as much as "done". Whether the packages are back is
    # decided by stage 2 below and the full-set re-check, not by this line.
    if [[ "$restore_rc" -eq 0 ]]; then
        log "The single transaction completed without errors."
    elif [[ -n "$restore_out" ]]; then
        log_warn "Single transaction did not work (code $restore_rc), trying one by one. apt said: $(printf '%s' "$restore_out" | tr '\n' ' ' | tail -c 300)"
    else
        log_warn "Single transaction did not work (code $restore_rc) and apt produced no output. Trying one by one."
    fi

    # Stage 2: one at a time, and only for those still missing.
    # A separate pass is needed because a single name with no installation
    # candidate aborts the whole transaction, and then nothing is restored,
    # including packages that install perfectly well. This lesson is already
    # paid for in this project: cleanup_system (defined BELOW in this file)
    # installs netplan.io and netplan-generator separately, because on Debian
    # 12 the latter does not exist and it kills the whole transaction.
    for pkg in $critical_lost; do
        _pkg_installed_ok "$pkg" && continue
        restore_out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove "$pkg" 2>&1)"
        restore_rc=$?
        if [[ "$restore_rc" -eq 0 ]] && _pkg_installed_ok "$pkg"; then
            log "Restored: $pkg"
        elif [[ "$restore_rc" -eq 0 ]]; then
            # apt also returns zero when it decided there was nothing to do.
            # Without this branch the log would contradict itself: "Restored"
            # and three lines below "Boot-critical packages missing".
            log_warn "apt reported success, but $pkg is still not installed."
        elif [[ -n "$restore_out" ]]; then
            # Single line: log_msg timestamps only the first one, and a
            # multi-line answer breaks the log format exactly where it will
            # later be parsed.
            log_warn "Failed to install $pkg (code $restore_rc). apt said: $(printf '%s' "$restore_out" | tr '\n' ' ' | tail -c 300)"
        else
            log_warn "Failed to install $pkg (code $restore_rc) and apt produced no output: the command probably did not run at all."
        fi
    done

    # Re-check the WHOLE set, not just what went missing. The direct route to
    # losing a neighbour is closed by --no-remove above; this is the fallback for
    # the day that stops holding.
    local still_lost=""
    for pkg in $critical_before; do
        _pkg_installed_ok "$pkg" || still_lost+="$pkg "
    done
    if [[ -n "$still_lost" ]]; then
        still_lost="${still_lost% }"
        log_error "Do NOT reboot the server: in its current state it will not come back."
        log_error "Boot-critical packages missing: $still_lost"
        log_error "Try installing them in ONE command, every name at once: sudo apt-get install $still_lost"
        log_error "One command rather than one at a time: that way apt picks versions for the whole group at once."
        log_error "No -y on purpose: if apt then wants to REMOVE something, read the list before you confirm. Losing one more of the packages above only makes things worse."
        log_error "If apt answers that a package not in your command is in the way (of the form 'X : Breaks: Y' or 'X : Depends: Y'), add Y to the same command: in Issue #223 that turned out to be systemd, which is not in the list above."
        log_error "If apt refuses because of held packages, release the hold: sudo apt-mark unhold <name>"
        log_error "If a package is gone from the repositories (renamed by a release upgrade), drop its name from $BOOT_CRITICAL_SNAPSHOT_FILE"
        die "Stopping while the server is still reachable. Deal with the above, then run the installer again."
    fi
    log "Boot-critical packages restored."
}


# _die_upgrade_failed : name the cause of a failed upgrade and stop.
#
# Pulled out into its own function for a reason, not for tidiness. While this
# reasoning lived inline inside step1_update_and_optimize, tests could only
# check it by grepping the source, and an outside review showed that almost any
# mutation inside survived the whole suite green: deleting the second lock
# measurement, inverting the condition, dropping -s, dropping timeout. A test
# can load a function whole and assert WHICH verdict is printed for WHICH state.
#
# The rule of this block: name the cause by evidence, not by guess. The previous
# version blamed the dpkg lock unconditionally, including when fuser had found
# nothing, and sent the investigation the wrong way: in Issue #223 the real
# answer was a resolver refusal.
_die_upgrade_failed() {
    local lock_holder apt_why apt_why_rc
    # Measure AGAIN rather than reusing the sample taken before the retry:
    # dpkg --configure -a and a whole second apt run happened in between, and
    # the process found earlier may have exited while a new one appeared.
    lock_holder="$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | tr -s ' ' || true)"
    if [[ -n "$lock_holder" ]]; then
        die "System update failed and the dpkg lock is held by:${lock_holder}. Wait for those processes to finish or run: systemctl stop unattended-upgrades; dpkg --configure -a - then run the script again."
    fi
    # The dry run (-s) asks apt whether a plan resolves. Its refusal usually
    # means dependencies, but not always: an unparsable sources.list, missing
    # package lists or a damaged dpkg state fail exactly the same way. So its
    # answer is QUOTED, not interpreted.
    # The timeout belongs here, on the fatal path: the real attempts above go
    # without one deliberately, while hanging here is not acceptable - that SSH
    # session may be all the user has left. timeout itself is always there,
    # coreutils is Essential.
    apt_why="$(timeout 120 env DEBIAN_FRONTEND=noninteractive apt-get upgrade -s --with-new-pkgs 2>&1)"
    apt_why_rc=$?
    if [[ "$apt_why_rc" -eq 0 ]]; then
        die "System update failed, but the dependencies resolve on a re-check, so they are not the cause. Look at the apt output on screen, it is not written to the log file: usually network or mirror, disk space on / or /boot, or the package's own script."
    fi
    if [[ -n "$apt_why" ]]; then
        die "System update failed. The dependency re-check answered: $(printf '%s' "$apt_why" | tr '\n' ' ' | tail -c 400)"
    fi
    # Third outcome: the check failed and said nothing. Claiming anything about
    # dependencies here is exactly how an unknown turns into a confident wrong
    # diagnosis.
    die "System update failed, and the dependency re-check did not answer either (code $apt_why_rc, no output; code 124 means it did not finish within 120 seconds). Look at the apt output on screen, it is not written to the log file."
}

# _warn_kept_back : say out loud that not everything was upgraded.
# apt-get upgrade leaves a package at its current version when upgrading it
# would require removing a neighbour, and returns ZERO while doing so. That is
# the deliberate trade (see the upgrade block in step 1), but staying silent
# about it is not acceptable: with full-upgrade this outcome was rare (it held
# back little beyond packages under hold and whatever Ubuntu itself phases),
# whereas with upgrade it is routine, and without a dedicated line it would pass
# entirely unnoticed. A warning, not a failure: the server boots either way, but
# this list is what decides a future investigation.
#
# ⚠️ apt gives no machine-readable list of what it held back, so this uses
# upgradable, which is a SUPERSET: packages under hold and packages stuck on an
# unresolvable chain land there too. Passing it off as something narrower is not
# acceptable, and the message below does not.
_warn_kept_back() {
    local raw rc kept list
    raw="$(apt list --upgradable 2>/dev/null)"
    rc=$?
    # Take the exit code from apt ITSELF, not from the pipeline: in a pipeline
    # it comes from awk unless pipefail is set, and then a failing apt reads as
    # "nothing to upgrade". The branch below decides between silence and a
    # warning, so it must not rest on a global shell option.
    if [[ "$rc" -ne 0 ]]; then
        # A failure of the check itself must not turn into contented silence:
        # this function exists for diagnosability, so its own failure has to be
        # audible.
        log_warn "Could not obtain the list of packages left behind (apt list returned $rc). Check by hand: apt list --upgradable"
        return 0
    fi
    kept="$(printf '%s\n' "$raw" | awk -F/ '/\//{printf "%s ", $1}')"
    [[ -n "${kept// /}" ]] || return 0
    list="${kept% }"
    # Truncation is EXPLICIT and marked: on a server with months of pending
    # updates this list runs into thousands of characters, and silent truncation
    # nearby has already been called out as a defect.
    if [[ "${#list}" -gt 400 ]]; then
        list="${list:0:400}... (truncated, full list: apt list --upgradable)"
    fi
    log "Not every package was upgraded, these stayed at their current versions: $list"
    log "Most often this means upgrading such a package would have to remove another one, which we deliberately do not do (Issue #223), or that the release is still being phased in. The list is not exhaustive though: packages under hold and packages stuck on unresolvable dependencies show up here too. If the list is not empty and it worries you, look at the reason: apt-get -s upgrade"
}

# _boot_critical_guard : take the snapshot and verify it. The wrapper exists for
# the places that have not taken a snapshot yet, which is step 2.
#
# ⚠️ The self-tests sit HERE, before the assignment, and not inside
# _boot_critical_snapshot, and that matters: a die inside a command
# substitution would only end the subshell, the script would carry on with an
# empty snapshot, and the fatal check would silently become optional.
_boot_critical_guard() {
    _dpkg_usable || die "dpkg does not answer, and without it there is no way to tell whether udev and initramfs-tools survive the reboot (Issue #223). Run: dpkg --configure -a; apt-get check - then start the installer again."
    _pkg_present dpkg || die "Could not determine package state (dpkg-query or awk do not behave as expected). Without it there is no way to be sure the server will boot (Issue #223)."
    local snapshot
    snapshot="$(_boot_critical_snapshot)"
    _verify_boot_critical "$snapshot"
}

# _dpkg_usable : 0 if dpkg answers can be trusted.
# Telling "package not installed" from "dpkg database is broken" by return code is NOT
# possible: measured on Ubuntu 24.04, both give rc=1. So ask about a package that is
# certainly installed: if even that one is missing, the mechanism is broken, not the
# packages. Without this an empty list would silently skip the question, and step 1
# would later run with a working dpkg and remove what was never asked about.
_dpkg_usable() {
    command -v dpkg-query >/dev/null 2>&1 || return 1
    dpkg-query -W -f='${Status}' dpkg 2>/dev/null | grep -q "ok installed"
}

# _cloud_init_removable : 0 if an installed cloud-init will actually be removed.
# cloud-init sits outside the list above: it is removed only when it does NOT manage the
# network. That answer is needed in two places, the cleanup itself and the step 0
# question, so it lives here. Otherwise consent would be asked about one set while a
# different one gets removed, which is exactly the complaint behind issue #213.
# 🔴 Any FAILED check means "manages the network, leave it alone". The costs are not
# symmetric: a cloud-init left in place costs tens of megabytes, one removed by mistake
# costs the network after the next reboot on a remote server. That is why ls by glob is
# gone from here: it returns rc=2 both when the directory is missing and when nothing matched.
_cloud_init_removable() {
    dpkg-query -W -f='${Status}' cloud-init 2>/dev/null | grep -q "ok installed" || return 1
    local f
    if [ -d /etc/netplan ]; then
        [ -r /etc/netplan ] || return 1
        for f in /etc/netplan/*cloud-init*; do
            [ -e "$f" ] && return 1
        done
        grep -rq "cloud-init" /etc/netplan/ 2>/dev/null
        case $? in
            0) return 1 ;;
            1) : ;;
            *) return 1 ;;
        esac
    fi
    if [ -f /etc/network/interfaces ] && grep -q "cloud-init" /etc/network/interfaces 2>/dev/null; then
        return 1
    fi
    # On Debian cloud-init writes here rather than into the main file.
    if [ -d /etc/network/interfaces.d ] \
       && grep -rq "cloud-init" /etc/network/interfaces.d/ 2>/dev/null; then
        return 1
    fi
    return 0
}

# _snaps_dir_readable : 0 if the snap directory exists and is readable.
# An empty answer from _user_snaps with an unreadable directory means "could not look",
# not "no snaps". Confusing the two is not allowed: the default of a destructive question
# depends on it.
_snaps_dir_readable() {
    [ -d /var/lib/snapd/snaps ] && [ -r /var/lib/snapd/snaps ]
}

# _user_snaps : names of snaps installed by the USER, one per line, WITHOUT duplicates.
# The directory holds one file per RETAINED REVISION, so without the dedup a snap that
# has ever been refreshed would appear in the warning several times in a row.
# Only snaps that carry no user data count as base ones: snapd, bare and core*.
# 🔴 lxd is NOT filtered: LXD from a snap keeps its containers and their data in
# /var/snap/lxd, and calling such a host "nothing to lose" means wiping them silently.
# ⚠️ Read the files rather than the output of 'snap list': the snap binary may already be
# gone from an earlier run, and the list would silently come back empty.
_user_snaps() {
    local f name
    for f in /var/lib/snapd/snaps/*.snap; do
        [ -e "$f" ] || continue
        name="${f##*/}"; name="${name%_*.snap}"
        case "$name" in
            snapd|bare|core|core[0-9]*) continue ;;
        esac
        printf '%s\n' "$name"
    done | sort -u
}

# Consent for removing system packages (issue #213). Asked at STEP 0, where the other
# questions already live: everything after that should run without a human present.
# The answer is stored in awgsetup_cfg.init so a repeated or resumed run does not ask
# again and, more importantly, does not read silence as consent.
configure_package_cleanup() {
    [[ "$NO_TWEAKS" -eq 1 ]] && return 0
    # The decision already exists: a command line flag or a record from an earlier run.
    [[ -n "$KEEP_PACKAGES" ]] && return 0

    if ! _dpkg_usable; then
        KEEP_PACKAGES=1
        log_warn "Could not query dpkg, so I will leave the system packages alone."
        return 0
    fi

    local installed=() pkg
    for pkg in $(_cleanup_package_list); do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            installed+=("$pkg")
        fi
    done
    # cloud-init is removed by a separate branch of the cleanup and only when it does not
    # manage the network, so it joins the list under the same condition: the question has
    # to be about exactly what will actually be removed.
    if _cloud_init_removable; then
        installed+=("cloud-init")
    fi

    # The snap directories are wiped by a separate rm -rf that does NOT depend on snapd
    # making the list above: the package may sit in 'deinstall ok config-files' state.
    local snap_dirs=0
    if [[ "${OS_ID:-}" == "ubuntu" ]] && { [ -d /snap ] || [ -d /var/snap ]; }; then
        snap_dirs=1
    fi

    if [ ${#installed[@]} -eq 0 ] && [ "$snap_dirs" -eq 0 ]; then
        KEEP_PACKAGES=0
        return 0
    fi

    # Look for the user snaps only when something threatens them: on Debian snapd is not in the list.
    local snaps="" snaps_unknown=0
    if [ "$snap_dirs" -eq 1 ] || [[ " ${installed[*]} " == *" snapd "* ]]; then
        if _snaps_dir_readable; then
            snaps="$(_user_snaps | tr '\n' ' ')"; snaps="${snaps% }"
        else
            snaps_unknown=1
        fi
    fi

    log_warn "The server is being set up as single-purpose, so these packages will be removed:"
    [ ${#installed[@]} -gt 0 ] && log_warn "  ${installed[*]}"
    if [ "$snap_dirs" -eq 1 ]; then
        log_warn "  Plus the /snap, /var/snap and /var/lib/snapd directories with every snap and its data."
        if [ "$snaps_unknown" -eq 1 ]; then
            log_warn "  Could not check what you have installed: the snap directory is not accessible."
        elif [[ -n "$snaps" ]]; then
            log_warn "  Your snaps that would be lost: $snaps"
        fi
    fi
    if [[ " ${installed[*]} " == *" cloud-init "* ]]; then
        log_warn "  Removing cloud-init also wipes the /etc/cloud and /var/lib/cloud directories."
    fi

    if [[ "$AUTO_YES" -eq 1 ]]; then
        KEEP_PACKAGES=0
        log "Removal auto-confirmed (--yes). To keep the packages: --keep-packages."
        return 0
    fi

    # Something to lose means removing ONLY on an explicit yes (an allowlist, like every
    # other destructive question in the script). The earlier version tested the answer for
    # the letter n, so "no thanks", a stray key or any answer in another language meant REMOVE.
    local risky=0
    if [[ -n "$snaps" ]] || [ "$snaps_unknown" -eq 1 ]; then risky=1; fi

    local answer="" hint="[Y/n]"
    [ "$risky" -eq 1 ] && hint="[y/N]"
    if ! read -rp "Remove these packages? $hint: " answer < /dev/tty; then
        KEEP_PACKAGES=1
        log_warn "No terminal available, could not ask - keeping the packages."
        return 0
    fi
    # Trim spaces and CR: an answer from putty arrives with a trailing \r.
    answer="$(printf '%s' "$answer" | tr -d '[:space:]')"

    if [ "$risky" -eq 1 ]; then
        case "$answer" in
            [Yy]|[Yy][Ee][Ss]|да|Да|ДА|д|Д) KEEP_PACKAGES=0 ;;
            *)                              KEEP_PACKAGES=1 ;;
        esac
    else
        case "$answer" in
            [Nn]|[Nn][Oo]|нет|Нет|НЕТ|не|Не|н|Н) KEEP_PACKAGES=1 ;;
            *)                                    KEEP_PACKAGES=0 ;;
        esac
    fi

    if [[ "$KEEP_PACKAGES" -eq 1 ]]; then
        log "Keeping the packages. The firewall, Fail2Ban and the optimization stay in place."
    fi
    return 0
}

# Remove unnecessary packages and services
cleanup_system() {
    log "Cleaning system of unnecessary components..."

    # Snapshot default route BEFORE cleanup - detects when we break the network.
    # Issue #84: on clean Ubuntu 26.04 server (subiquity, no cloud-init netplan
    # markers) apt-get autoremove after purging cloud-init removed
    # netplan-generator as a transitive dep, and the server lost its IP on reboot.
    local pre_default_route
    pre_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    log_debug "Pre-cleanup default route: ${pre_default_route:-<none>}"

    # apt-mark hold for critical network stack packages: defence against
    # accidental removal via transitive deps. Covers both netplan naming
    # variants (netplan.io on 24.04, netplan-generator on 25.10/26.04) plus
    # systemd-resolved and netcfg/ifupdown legacy. There is no standalone
    # systemd-networkd package - the binary lives inside systemd, nothing to hold.
    # Before holding we snapshot the user's existing holds so we never strip
    # holds we did not place (e.g. on linux-image-* held by the user).
    local _hold_pkgs="netplan.io netplan-generator systemd-resolved netcfg ifupdown"
    local _preexisting_holds=""
    _preexisting_holds="$(apt-mark showhold 2>/dev/null || true)"
    local _held_actual=()
    local _hpkg
    for _hpkg in $_hold_pkgs; do
        if dpkg-query -W -f='${Status}' "$_hpkg" 2>/dev/null | grep -q "ok installed"; then
            # Skip if user already held - that hold is not ours to release.
            if grep -qxF "$_hpkg" <<<"$_preexisting_holds"; then
                continue
            fi
            apt-mark hold "$_hpkg" >/dev/null 2>&1 && _held_actual+=("$_hpkg")
        fi
    done
    [ ${#_held_actual[@]} -gt 0 ] && log_debug "Apt-mark hold: ${_held_actual[*]}"

    # Packages to remove (safe for VPS)
    # snapd and lxd-agent-loader — Ubuntu only, not present on Debian
    local packages_to_remove=()
    local pkg
    local cleanup_list
    cleanup_list="$(_cleanup_package_list)"
    for pkg in $cleanup_list; do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            packages_to_remove+=("$pkg")
        fi
    done

    if [ ${#packages_to_remove[@]} -gt 0 ]; then
        log "Removing: ${packages_to_remove[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}" || log_warn "Error removing some packages"
    fi

    # Cleaning snap artifacts (Ubuntu only)
    if [[ "${OS_ID:-}" == "ubuntu" && -d /snap ]]; then
        log "Cleaning snap artifacts..."
        rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || log_warn "snap cleanup error"
    fi

    # cloud-init: remove only if NOT managing network
    # Conservative approach: check cloud-init markers first, then renderer
    if dpkg-query -W -f='${Status}' cloud-init 2>/dev/null | grep -q "ok installed"; then
        if _cloud_init_removable; then
            log "Removing cloud-init (network doesn't depend on it)..."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y cloud-init 2>/dev/null || log_warn "cloud-init removal error"
            rm -rf /etc/cloud /var/lib/cloud 2>/dev/null
        else
            log_warn "cloud-init manages network — skipping removal."
        fi
    fi

    # apt-get autoremove dropped (was the source of Issue #84 on Ubuntu 26.04
    # ISO): autoremove zapped netplan-generator as a transitive dep of
    # cloud-init. Orphans left after purge take ~50-200 MB - acceptable trade
    # for stability. User can manually run apt-get autoremove --no-install-recommends.

    # Release apt-mark holds so packages do not stay frozen for the user.
    local _upkg
    for _upkg in "${_held_actual[@]}"; do
        apt-mark unhold "$_upkg" >/dev/null 2>&1 || true
    done

    # Verify default route is still present. If lost, attempt recovery.
    # We reinstall netplan.io unconditionally (present on every supported
    # distro). netplan-generator only ships from Ubuntu 25.10+ / Debian 13+ -
    # gate the install behind apt-cache show so Debian 12 does not abort the
    # transaction trying to fetch a non-existent package.
    local post_default_route
    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    if [[ -n "$pre_default_route" && -z "$post_default_route" ]]; then
        log_error "Default route lost after cleanup. Attempting recovery..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            netplan.io 2>/dev/null || true
        if apt-cache show netplan-generator &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                netplan-generator 2>/dev/null || true
        fi
        systemctl restart systemd-networkd 2>/dev/null || true
        netplan apply 2>/dev/null || true
        # Route-wait loop: up to ~26 seconds, polling every 1-5 seconds.
        # Fixed sleeps are unreliable - DHCP route appearance on slow VMs is
        # unpredictable.
        local _wait
        for _wait in 1 2 3 5 5 5 5; do
            post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
            [[ -n "$post_default_route" ]] && break
            sleep "$_wait"
        done
        # Last-ditch: bring up the interface from pre_default_route. Try
        # networkctl renew first (for systemd-networkd-managed link); if the
        # route still does not come back, fall through to dhclient (ifupdown).
        if [[ -z "$post_default_route" ]]; then
            local _iface
            _iface="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }' <<<"$pre_default_route")"
            if [[ -n "$_iface" ]]; then
                log_warn "Last-ditch attempt to bring $_iface up..."
                ip link set "$_iface" up 2>/dev/null || true
                if command -v networkctl &>/dev/null; then
                    networkctl renew "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
                # If networkctl did not bring the route back (or is absent) - dhclient.
                if [[ -z "$post_default_route" ]] && command -v dhclient &>/dev/null; then
                    dhclient -4 "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
            fi
        fi
        if [[ -z "$post_default_route" ]]; then
            die "Network did not recover after cleanup_system. Restore it from the console (e.g. sudo dhclient -4 <iface>) and retry the installer with --no-tweaks flag."
        fi
        log_warn "Network recovered: $post_default_route"
    fi

    log "System cleanup completed."
}

# Swap configuration
optimize_swap() {
    log "Optimizing swap..."
    local target_swap_mb

    if [[ $TOTAL_RAM_MB -le 2048 ]]; then
        target_swap_mb=1024
    else
        target_swap_mb=512
    fi

    # Check current swap
    local current_swap_mb
    current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')

    if [[ $current_swap_mb -ge $target_swap_mb ]]; then
        log "Swap is already sufficient: ${current_swap_mb}MB (target: ${target_swap_mb}MB)"
    else
        log "Creating swap file: ${target_swap_mb}MB"
        # Disable existing swap file if present
        if [[ -f /swapfile ]]; then
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
        fi
        dd if=/dev/zero of=/swapfile bs=1M count="$target_swap_mb" status=none 2>/dev/null || {
            log_warn "Error creating swap file"
            return 1
        }
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { log_warn "mkswap error"; return 1; }
        swapon /swapfile || { log_warn "swapon error"; return 1; }
        # Add to fstab if missing. Precise field match: ignore commented
        # lines and partial matches (e.g. `/swapfile.bak` or an old entry
        # left in a comment).
        if ! awk '!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap" {found=1} END {exit !(found+0)}' \
             /etc/fstab; then
            # Make sure the file ends with a newline. Without it our entry
            # would be glued onto the last fstab line, turning it into a
            # single malformed record of 11 fields instead of six. Command
            # substitution strips trailing newlines, so a properly
            # terminated file yields an empty string and no extra newline
            # is added.
            if [[ -s /etc/fstab && -n "$(tail -c1 /etc/fstab)" ]]; then
                echo >> /etc/fstab
            fi
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        log "Swap file created: ${target_swap_mb}MB"
    fi

    # Setting swappiness
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
}

# Network interface optimization
optimize_nic() {
    if [[ -z "$MAIN_NIC" ]]; then
        log_warn "Main NIC not detected, skipping optimization."
        return 1
    fi

    if ! command -v ethtool &>/dev/null; then
        log_debug "ethtool not found, skipping NIC optimization."
        return 0
    fi

    log "NIC optimization: $MAIN_NIC"
    # Disable GRO/GSO/TSO — may interfere with VPN traffic
    ethtool -K "$MAIN_NIC" gro off 2>/dev/null || log_debug "GRO: not supported/already off."
    ethtool -K "$MAIN_NIC" gso off 2>/dev/null || log_debug "GSO: not supported/already off."
    ethtool -K "$MAIN_NIC" tso off 2>/dev/null || log_debug "TSO: not supported/already off."
    log "NIC optimization completed."
}

# Full system optimization
optimize_system() {
    log "Optimizing system for VPN server..."
    detect_hardware
    optimize_swap
    optimize_nic
    log "System optimization completed."
}

# ==============================================================================
# Sysctl configuration (minimal, for --no-tweaks)
# ==============================================================================

setup_minimal_sysctl() {
    log "Configuring minimal sysctl (--no-tweaks)..."
    local f="/etc/sysctl.d/99-amneziawg-forwarding.conf"
    cat > "$f" << SYSEOF
# AmneziaWG — minimal settings (--no-tweaks)
net.ipv4.ip_forward = 1
# PMTU black-hole detection — critical for VPN tunnels behind mobile
# carriers or NATs that filter the ICMP "fragmentation needed" response.
# Without it, large TCP segments get silently dropped and heavy sites
# stall. Value 1 enables adaptive MSS probing only when a black-hole is
# actually detected, which is safe in any mode — we keep it even in
# --no-tweaks.
net.ipv4.tcp_mtu_probing = 1
SYSEOF
    if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
        cat >> "$f" << SYSEOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
SYSEOF
    else
        cat >> "$f" << SYSEOF
net.ipv6.conf.all.forwarding = 1
SYSEOF
    fi
    sysctl -p "$f" >/dev/null 2>&1 || log_warn "sysctl -p error"
    log "Minimal sysctl configured."
}

# ==============================================================================
# Sysctl configuration (extended)
# ==============================================================================

setup_advanced_sysctl() {
    log "Configuring sysctl..."
    local f="/etc/sysctl.d/99-amneziawg-security.conf"

    # Adaptive buffers and conntrack based on RAM.
    # conntrack_max: each entry is ~300 B, 256K ≈ 80 MB RAM. The previous
    # 65536 ceiling was tight on exit nodes running cascade + WARP bypass
    # (many simultaneous flows — a YouTube CDN alone opens dozens in
    # parallel).
    local rmem_max wmem_max netdev_backlog conntrack_max
    if [[ ${TOTAL_RAM_MB:-1024} -ge 2048 ]]; then
        rmem_max=16777216    # 16MB
        wmem_max=16777216
        netdev_backlog=5000
        conntrack_max=262144
    else
        rmem_max=4194304     # 4MB
        wmem_max=4194304
        netdev_backlog=2500
        conntrack_max=131072
    fi

    cat > "$f" << EOF
# AmneziaWG 2.0 Security/Performance Settings - $(date)
# Auto-generated by install_amneziawg_en.sh v${SCRIPT_VERSION}

# --- IP Forwarding ---
net.ipv4.ip_forward = 1
$(if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1"
    echo "net.ipv6.conf.default.disable_ipv6 = 1"
    echo "net.ipv6.conf.lo.disable_ipv6 = 1"
else
    echo "# IPv6 not disabled"
    echo "net.ipv6.conf.all.forwarding = 1"
fi)

# --- TCP/IP Hardening ---
# rp_filter = 2 (loose mode): validates source IP against ANY route in the
# table, not against the reverse path through the same interface. Strict mode
# (=1) breaks routing on cloud hosters (Hetzner and similar) where the gateway
# is in a different subnet than the VPS IP — reply packets fail the strict
# reverse path check. Loose mode is safe: spoofed source IPs are still dropped
# if no route exists for them at all. Discussion #41 (z036).
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.ipv4.tcp_rfc1337 = 1

# --- Redirects ---
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
$(if [[ "${DISABLE_IPV6:-1}" -ne 1 ]]; then
    echo "net.ipv6.conf.all.accept_redirects = 0"
    echo "net.ipv6.conf.default.accept_redirects = 0"
fi)

# --- BBR Congestion Control ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- Network Buffers (adaptive) ---
net.core.rmem_max = ${rmem_max}
net.core.wmem_max = ${wmem_max}
net.core.netdev_max_backlog = ${netdev_backlog}

# --- TCP Tuning ---
# Explicit per-socket TCP buffer ranges (min default max) scaled to
# rmem_max/wmem_max. Without these the individual sockets do not grow
# to the full global maximum.
net.ipv4.tcp_rmem = 4096 87380 ${rmem_max}
net.ipv4.tcp_wmem = 4096 65536 ${wmem_max}

# PMTU black-hole detection: when ICMP "fragmentation needed" is filtered
# somewhere along the path (typical for mobile carriers, tunnel joins,
# WARP bypass), classic Path MTU Discovery silently breaks, large TCP
# segments go missing, and sites "hang". Value 1 enables adaptive MSS
# probing ONLY when a black-hole is detected (not on every packet),
# which is safe everywhere. Fixes the class of "YouTube / heavy sites
# don't load through the cascade properly" issues.
net.ipv4.tcp_mtu_probing = 1

# Don't slow-start after idle: for long-lived VPN flows (persistent
# connections) keep the congestion window between active bursts — no
# speed drop on resume.
net.ipv4.tcp_slow_start_after_idle = 0

# Reuse TIME_WAIT sockets for outbound connections. Safe on modern
# kernels (RFC 6191 timestamp-based validation); useful on exit nodes
# with a high rate of egress flows through WARP or the primary NIC.
net.ipv4.tcp_tw_reuse = 1

# --- Conntrack (adaptive) ---
# ~256K flow entries (≈80 MB RAM) on 2+ GB VPSes, 128K on smaller.
# Cascade + WARP bypass create hundreds of concurrent TCP/UDP flows;
# the previous 65536 ceiling saturated under load and new connections
# started to be dropped.
net.netfilter.nf_conntrack_max = ${conntrack_max}

# --- Security ---
vm.swappiness = 10
kernel.sysrq = 0

# Suppress kernel warning/notice messages in the hoster VNC console.
# Without this, fail2ban UFW blocks spam the VNC window with "[UFW BLOCK]"
# lines and make the console unusable.
# Format: console_loglevel default_msg_loglevel min_console_loglevel default_console_loglevel
# Value 3 = KERN_ERR — only errors and above reach the console.
# Discussion #41 (z036).
kernel.printk = 3 4 1 3
EOF

    log "Applying sysctl..."
    if ! sysctl -p "$f" >/dev/null 2>&1; then
        # nf_conntrack may be unavailable before module is loaded
        log_warn "Some sysctl parameters did not apply (nf_conntrack will be available later)."
        sysctl -p "$f" 2>/dev/null || true
    fi
}

# ==============================================================================
# Firewall and security
# ==============================================================================

# Detect the real SSH port(s) so the UFW rule does not lock you out.
# Without this, ufw limit 22/tcp + default deny incoming cuts server access
# after ufw enable when SSH runs on a non-standard port (Issue #91).
# Self-contained: called at step 4, BEFORE awg_common.sh is sourced.
# Sources:
#   1. CLI_SSH_PORT (--ssh-port=, manual override, comma-separated list) - authoritative
#   otherwise UNION (not fallback - so we never miss the real port):
#   2. sshd -T   (effective config: `Port` AND `ListenAddress host:port`, honours drop-ins)
#   3. ss -tlnp  (real sshd listening sockets: ground truth for ListenAddress)
#   4. /etc/ssh/sshd_config + sshd_config.d/*.conf (parsing, only if 2-3 are empty)
#   5. 22 (default, if nothing is found)
# Prints unique valid ports (1-65535) space-separated to stdout.
# IMPORTANT: only log_warn/log_error (stderr) inside; log() writes to stdout
# and would corrupt the $(detect_ssh_ports) capture.
detect_ssh_ports() {
    local ports="" p pp valid=""
    # awk: pulls the port from `port N` and `listenaddress host:port` lines
    # (IPv4 and [IPv6]); a bare address without a port is skipped.
    local awk_ports='tolower($1)=="port"&&$2~/^[0-9]+$/{print $2} tolower($1)=="listenaddress"{v=$2; if(v~/\]:[0-9]+$/){sub(/.*\]:/,"",v); print v} else if(v~/^[0-9.]+:[0-9]+$/){sub(/.*:/,"",v); print v}}'

    if [[ -n "$CLI_SSH_PORT" ]]; then
        # 1. Manual override - authoritative source
        ports="${CLI_SSH_PORT//,/ }"
    else
        # 2. sshd -T: effective configuration (Port + ListenAddress, drop-ins)
        if command -v sshd &>/dev/null; then
            ports+=" $(sshd -T 2>/dev/null | awk "$awk_ports" | tr '\n' ' ')"
        fi
        # 3. ss: real sshd listening sockets. Merged, not fallback - catches the
        #    ListenAddress port even when sshd -T prints the default port 22.
        if command -v ss &>/dev/null; then
            ports+=" $(ss -H -tlnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' | tr '\n' ' ')"
        fi
        # 4. Parse config files - only if sshd -T and ss yielded nothing
        if [[ -z "${ports// }" ]]; then
            local cfgs=() d
            [[ -f /etc/ssh/sshd_config ]] && cfgs+=(/etc/ssh/sshd_config)
            for d in /etc/ssh/sshd_config.d/*.conf; do
                [[ -f "$d" ]] && cfgs+=("$d")
            done
            if [[ "${#cfgs[@]}" -gt 0 ]]; then
                ports+=" $(awk "$awk_ports" "${cfgs[@]}" 2>/dev/null | tr '\n' ' ')"
            fi
        fi
    fi

    # Validate (decimal 1-65535, 10# guards against octal) + dedup preserving order
    for p in $ports; do
        if [[ "$p" =~ ^[0-9]+$ ]]; then
            pp=$((10#$p))
            if (( pp >= 1 && pp <= 65535 )); then
                case " $valid " in
                    *" $pp "*) ;;
                    *) valid+="${valid:+ }$pp" ;;
                esac
            fi
        fi
    done

    # 5. Default if detection produced nothing valid
    if [[ -z "$valid" ]]; then
        [[ -n "$CLI_SSH_PORT" ]] && log_warn "--ssh-port has no valid ports, falling back to 22."
        valid="22"
    fi
    printf '%s' "$valid"
}

setup_improved_firewall() {
    log "Configuring UFW..."
    if ! command -v ufw &>/dev/null; then install_packages ufw; fi

    # Detect main network interface for route rule
    local main_nic
    main_nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$main_nic" ]]; then
        log_warn "Could not detect network interface for UFW route."
    fi

    # Detect the real SSH port(s) so we do not lock out access on a non-standard port (Issue #91)
    local ssh_ports _sp
    ssh_ports=$(detect_ssh_ports)
    log "SSH port(s) for the UFW rule: ${ssh_ports}"

    local ufw_errors=0
    # Do not remove the old UDP port or old awg0→main route here: EXIT may
    # still need the previous awg0. Both are cleaned up in step7.
    if ufw status 2>/dev/null | grep -q inactive; then
        log "UFW is inactive. Configuring..."
        ufw default deny incoming  || { log_warn "UFW: failed to set default deny incoming"; ufw_errors=1; }
        ufw default allow outgoing || { log_warn "UFW: failed to set default allow outgoing"; ufw_errors=1; }
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: failed to limit SSH (port ${_sp})"; ufw_errors=1; }
        done
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: failed to allow VPN port"; ufw_errors=1; }
        if [[ -n "$main_nic" ]] && ufw_main_route_required; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: failed to add route rule"; ufw_errors=1; }
            log "VPN routing rule added (awg0 → ${main_nic})."
        fi
        if [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
            ufw route allow in on awg0 out on "${AWG_WARP_IFACE:-wgcf}" comment "AmneziaWG→WARP egress" \
                || { log_warn "UFW: failed to add route awg0→${AWG_WARP_IFACE:-wgcf}"; ufw_errors=1; }
            log "WARP routing rule added (awg0 → ${AWG_WARP_IFACE:-wgcf})."
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "One or more UFW rules failed to apply. Check settings manually."
            return 1
        fi
        log "UFW rules added."
        log_warn "--- ENABLING UFW ---"
        log_warn "UFW will allow SSH ONLY on port(s): ${ssh_ports}. Make sure you connect over it."
        if [[ "$ssh_ports" != "22" ]]; then
            log_warn "NOTE: SSH on a non-standard port. If the port is detected wrong, you will lose server access."
            log_warn "Override if needed: --ssh-port=PORT"
        fi
        local confirm_ufw="y"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            sleep 5
            read -rp "Enable UFW? [y/N]: " confirm_ufw < /dev/tty
        else
            log "Auto-enabling UFW (--yes)."
        fi
        if ! [[ "$confirm_ufw" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
            log_warn "UFW configured but not activated by your choice."
            log_warn "The server is running WITHOUT a firewall. Enable later: sudo ufw enable"
            return 0
        fi
        if ! ufw --force enable; then die "UFW enable error."; fi
        log "UFW enabled."
        # Marker: UFW was enabled by our installer (not by the user beforehand).
        # Used in step_uninstall to decide whether disabling UFW is safe.
        # Protects against destructive uninstall on a VPS where UFW was used
        # for SSH/web hardening BEFORE our script was installed (audit).
        touch "$AWG_DIR/.ufw_enabled_by_installer" 2>/dev/null || \
            log_warn "Failed to create UFW marker — uninstall will not disable UFW automatically."
    else
        log "UFW is active. Updating rules..."
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: failed to limit SSH (port ${_sp})"; ufw_errors=1; }
        done
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: failed to allow VPN port"; ufw_errors=1; }
        if [[ -n "$main_nic" ]] && ufw_main_route_required; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: failed to add route rule"; ufw_errors=1; }
        fi
        if [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
            ufw route allow in on awg0 out on "${AWG_WARP_IFACE:-wgcf}" comment "AmneziaWG→WARP egress" \
                || { log_warn "UFW: failed to add route awg0→${AWG_WARP_IFACE:-wgcf}"; ufw_errors=1; }
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "One or more UFW rules failed to apply. Check settings manually."
            return 1
        fi
        ufw reload || log_warn "UFW reload error."
        log "Rules updated."
    fi
    log "UFW configured."
    log "$(ufw status verbose 2>&1)"
    return 0
}

secure_files() {
    log "Setting secure file permissions..."
    chmod 700 "$AWG_DIR" 2>/dev/null
    chmod 700 /etc/amnezia 2>/dev/null
    chmod 700 /etc/amnezia/amneziawg 2>/dev/null
    chmod 600 /etc/amnezia/amneziawg/*.conf 2>/dev/null
    find "$AWG_DIR" -name "*.conf" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.key" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.png" -type f -exec chmod 600 {} \; 2>/dev/null
    find "$AWG_DIR" -name "*.vpnuri" -type f -exec chmod 600 {} \; 2>/dev/null
    if [[ -d "$KEYS_DIR" ]]; then
        chmod 700 "$KEYS_DIR" 2>/dev/null
        chmod 600 "$KEYS_DIR"/* 2>/dev/null
    fi
    [[ -f "$CONFIG_FILE" ]] && chmod 600 "$CONFIG_FILE"
    [[ -f "$LOG_FILE" ]] && chmod 640 "$LOG_FILE"
    [[ -f "$MANAGE_SCRIPT_PATH" ]] && chmod 700 "$MANAGE_SCRIPT_PATH"
    [[ -f "$COMMON_SCRIPT_PATH" ]] && chmod 700 "$COMMON_SCRIPT_PATH"
    log "File permissions set."
}

setup_fail2ban() {
    log "Configuring Fail2Ban..."
    if ! command -v fail2ban-client &>/dev/null; then
        install_packages fail2ban
        # Marker: the fail2ban package was installed by our installer (rather
        # than being present before it). step_uninstall purges fail2ban only
        # when the marker exists, so it never wipes SSH protection the user
        # had set up beforehand (symmetric to .ufw_enabled_by_installer).
        if command -v fail2ban-client &>/dev/null; then
            touch "$AWG_DIR/.fail2ban_installed_by_installer" 2>/dev/null || \
                log_warn "Failed to create the fail2ban marker - uninstall will not remove the fail2ban package."
        fi
    fi
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2Ban not installed, skipping."
        return 1
    fi

    # banaction=ufw only takes effect with UFW active: if the user declined to
    # enable UFW at step 4, bans land in an inactive ruleset and effectively
    # do nothing (while fail2ban itself looks "green").
    if ufw status 2>/dev/null | grep -q inactive; then
        log_warn "UFW is not active: fail2ban bans (banaction=ufw) have no effect while UFW is off. Enable with: sudo ufw enable"
    fi

    # Debian: journald instead of rsyslog, needs python3-systemd
    if [[ "${OS_ID:-}" == "debian" ]]; then
        install_packages python3-systemd
    fi

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null

    # Backend: systemd for Debian and Ubuntu (no rsyslog)
    local f2b_backend="systemd"

    cat > /etc/fail2ban/jail.d/amneziawg.conf << JAILEOF || { log_warn "jail.d/amneziawg.conf write error"; return 1; }
# AmneziaWG — SSH protection (managed by amneziawg-installer)
[sshd]
enabled = true
backend = ${f2b_backend}
maxretry = 5
findtime = 10m
bantime  = 1h
banaction = ufw
JAILEOF

    systemctl restart fail2ban
    # Wait a second, service is restarting...
    sleep 1

    if systemctl is-active --quiet fail2ban; then
        log "Fail2Ban configured and restarted."
    else
        log_warn "fail2ban restart error"
    fi
    return 0
}

# ==============================================================================
# Service status check
# ==============================================================================

check_service_status() {
    log "Checking service status..."
    local ok=1

    if systemctl is-failed --quiet awg-quick@awg0; then
        log_error "Service FAILED!"
        ok=0
    fi

    if ! systemctl is-active --quiet awg-quick@awg0; then
        log_error "awg-quick@awg0 is not active!"
        ok=0
    fi

    if ! ip link show up dev awg0 &>/dev/null; then
        log_error "Interface awg0 is missing or not UP!"
        ok=0
    fi

    if ! awg show 2>/dev/null | grep -q "interface: awg0"; then
        log_error "awg show cannot see interface!"
        ok=0
    fi

    # Port check
    local port_check=${AWG_PORT:-0}
    if [[ "$port_check" -eq 0 ]] && [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        port_check=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
        port_check=${port_check:-0}
    fi
    if [[ "$port_check" -ne 0 ]]; then
        if ! ss -lunp | grep -q ":${port_check} "; then
            log_error "Port $port_check/udp is not listening!"
            ok=0
        fi
    fi

    # AWG 2.0 parameter check
    if awg show awg0 2>/dev/null | grep -q "jc:"; then
        log "AWG 2.0 parameters active."
    else
        log_warn "AWG 2.0 parameters not detected in awg show."
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Service and interface status OK."
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Diagnostics
# ==============================================================================

# The report is meant to be pasted into a PUBLIC issue: our own bug template asks
# for its contents. Key values are stripped by one shared function rather than by
# separate masking inside each section: sections get added over time and masking
# done inside one of them drifts apart from the rest. That is exactly how
# PresharedKey ended up in the report in clear text while PrivateKey was masked on
# the line next to it.
# Applied at TWO points (one implementation, not two sources of truth): at the
# report boundary and separately to the server config.
# NOTE: the second point covers the server config ONLY. awg show output and the
# journal do not pass through it, so those are what would leak if the outer
# pipeline were ever detached.
# NOTE: the AWG_ENDPOINT masking further down this function is a deliberate
# exception to the "one function" rule: it hides an address rather than a key.
#
# The expressions are CONTEXT BOUND. An unanchored version stripped a value wherever
# a key name appeared and damaged unrelated fields: the server name is free text
# allowing spaces and equals signs, so an AWG_SERVER_NAME line containing the text
# "PrivateKey = Office" lost both the value and its closing quote. Client names are
# protected from that by the ^[a-zA-Z0-9_-]+$ validation (which lives in
# manage_amneziawg.sh and awg_common.sh, not here), but a hand-edited #_Name may
# contain anything.
#
# Four contexts:
#   1. a configuration line AT START OF LINE, with an optional comment marker. The
#      marker is needed NOT because awg would parse such a line: it discards it
#      entirely (config_read_line truncates at the first hash BEFORE parsing). It is
#      needed because the value physically sits in a file that gets pasted into a
#      public issue. Masked TO END OF LINE: parsing strips whitespace beforehand, so
#      a record like "PrivateKey = AA BB=" is valid and cutting at the first space
#      would have left the tail of the key in the report.
#   2. an awg show label at start of line. HeaderProtectionKey is mandatory here:
#      awg show prints it IN CLEAR TEXT (show.c: key() instead of masked_key()),
#      unlike the private and preshared keys which it hides itself. This also
#      settles WG_HIDE_KEYS=never.
#   3. "Line unrecognized: ..." - unanchored. awg prints the line to stderr ALREADY
#      CLEANED (truncated at the hash, whitespace removed) and wrapped in a backtick
#      and a quote. Hence the ".?" in the expression: it skips that backtick.
#      DO NOT REMOVE ".?": without it the real line does not match at all.
#      The error branch fires on ANY unrecognized line: a typo in a key name, a key
#      in the wrong section (PrivateKey inside [Peer] goes to stderr in full), a key
#      from another implementation. A hand-added third-line parameter is one case
#      among them, not the only one.
#   4. "Key is not the correct length or format: ..." - same place, but the message
#      carries NO key name at all, so it cannot be matched by one.
# NOTE: the anchors on 1 and 2 mean those forms are NOT caught in the Service Status
# section, where systemctl status adds its own timestamped prefix. The journal
# section does not suffer from this: journalctl is called there with --output=cat,
# that is, without a prefix.
# Case insensitivity (flag I) because config parsing is case insensitive too
# (strncasecmp).
#
# FOUR UPSTREAM STRING LITERALS carry the whole thing: "private key:",
# "header protection key:", "Line unrecognized:", "Key is not the correct length or
# format:". Checked against amneziawg-tools ee0f0a9 (src/config.c, src/show.c) on
# 25 aug 2026. If any of them is reworded upstream the filter silently stops
# matching, and the tests stay green because they hard-code the same strings.
# RE-CHECK when bumping amneziawg-tools.
_mask_report_secrets() {
    sed -E \
        -e 's/^([[:space:]]*#?[[:space:]]*(PrivateKey|PresharedKey|HeaderProtectionKey)[[:space:]]*=[[:space:]]*).*/\1[HIDDEN]/I' \
        -e 's/^([[:space:]]*(private key|preshared key|header protection key)[[:space:]]*:[[:space:]]*).*/\1(hidden)/I' \
        -e 's/(Line unrecognized:[[:space:]]*.?(PrivateKey|PresharedKey|HeaderProtectionKey)[[:space:]]*=[[:space:]]*).*/\1[HIDDEN]/I' \
        -e 's/(Key is not the correct length or format:[[:space:]]*).*/\1[HIDDEN]/I'
}

create_diagnostic_report() {
    # --diagnostic runs BEFORE initialize_setup (home of the main root check):
    # as a regular user every log_msg write into /root/awg fails, the report
    # is not created, and exit 0 would look like a false success.
    if [ "$(id -u)" -ne 0 ]; then die "Run the script as root (sudo bash $0 --diagnostic)."; fi
    log "Creating diagnostics..."
    local rf _diag_umask
    rf="$AWG_DIR/diag_$(date +%F_%T).txt"
    # The file is created by redirection BEFORE chmod, so its mode at creation
    # time comes from the umask. Same idiom as for keys in awg_common.sh: narrow
    # the permissions up front instead of repairing them afterwards. --diagnostic
    # runs BEFORE secure_files, so /root/awg may exist with default permissions
    # and the 0644 window is genuinely reachable.
    _diag_umask=$(umask); umask 077
    {
        echo "=== AMNEZIAWG 2.0 DIAGNOSTIC REPORT ==="
        echo ""
        echo "!!! WARNING: PrivateKey, PresharedKey and HeaderProtectionKey values are"
        echo "!!! stripped wherever they are labelled by name or by an awg show label."
        echo "!!! What stays in the report: IP addresses, ports, routes, obfuscation"
        echo "!!! parameters, client names and public keys. The server endpoint is"
        echo "!!! additionally hidden. Review what of that you do not want to be"
        echo "!!! public before posting to a public issue."
        echo ""
        echo "Generated: $(date)"
        echo "Hostname: $(hostname)"
        echo "Installer: v${SCRIPT_VERSION}"
        echo ""
        echo "--- OS ---"
        lsb_release -ds 2>/dev/null || cat /etc/os-release
        uname -a
        echo ""
        echo "--- Hardware ---"
        echo "RAM: $(awk '/MemTotal/ {printf "%.0f MB", $2/1024}' /proc/meminfo)"
        echo "CPU: $(nproc) cores"
        echo "Swap: $(free -m | awk '/Swap:/ {print $2}') MB"
        echo ""
        echo "--- Configuration ($CONFIG_FILE) ---"
        if [[ -f "$CONFIG_FILE" ]]; then
            sed 's/AWG_ENDPOINT=.*/AWG_ENDPOINT=[HIDDEN]/' "$CONFIG_FILE"
        else
            echo "File not found"
        fi
        echo ""
        echo "--- Server Config ($SERVER_CONF_FILE) ---"
        # Second enforcement point, SAME function: one implementation, two places.
        # That is not a second source of truth, and if the outer filter is ever
        # detached from the block, the riskiest raw input stays covered.
        if [[ -f "$SERVER_CONF_FILE" ]]; then
            _mask_report_secrets < "$SERVER_CONF_FILE" || echo "ERROR: could not read or filter $SERVER_CONF_FILE"
        else
            echo "File not found"
        fi
        echo ""
        echo "--- Service Status ---"
        systemctl status awg-quick@awg0 --no-pager -l 2>/dev/null || echo "Service not found"
        echo ""
        echo "--- AWG Status ---"
        awg show 2>/dev/null || echo "awg show failed"
        echo ""
        echo "--- AWG Version ---"
        awg --version 2>/dev/null || echo "awg --version failed"
        echo ""
        echo "--- Network Interfaces ---"
        ip a 2>/dev/null
        echo ""
        echo "--- Listening Ports ---"
        ss -lunp 2>/dev/null
        echo ""
        echo "--- Firewall Status ---"
        if command -v ufw &>/dev/null; then ufw status verbose; else echo "UFW N/A"; fi
        echo ""
        echo "--- Routing Table ---"
        ip route 2>/dev/null
        echo ""
        echo "--- Cascade / Split Routing ---"
        # The cascade (CASCADE.en.md) lives outside awg0.conf: its own table, mark, ipset and mangle
        # rules. Without this block the report cannot tell whether the split is applied (issue #212).
        if [ -f "$AWG_DIR/awg-routing.sh" ] || ip link show awg1 &>/dev/null; then
            # is-active prints "inactive" AND returns non-zero, so $(... || echo N/A) would emit
            # BOTH strings at once. Take the output as is; N/A only when it comes back empty.
            local _casc_active _casc_enabled _casc_out
            _casc_active=$(systemctl is-active awg-routing 2>/dev/null || true)
            _casc_enabled=$(systemctl is-enabled awg-routing 2>/dev/null || true)
            echo "unit awg-routing: active=${_casc_active:-N/A}, enabled=${_casc_enabled:-N/A}"
            # "not found" and "could not check" are kept apart on purpose: silencing stderr and
            # printing the same line would turn a failed command into a claim that the rules are
            # absent, sending triage the wrong way. grep -m10 instead of | head -10: it does not
            # break the pipe, so pipefail cannot return 141 and fire the || branch after output.
            if _casc_out=$(ip rule show 2>&1); then
                grep -w fwmark <<< "$_casc_out" || echo "ip rule: no rules by mark"
            else
                echo "ip rule: CHECK FAILED: $(head -1 <<< "$_casc_out")"
            fi
            echo "table 100: $(ip route show table 100 2>/dev/null | tr '\n' '; ')"
            echo "ipset sets: $(ipset list -n 2>/dev/null | tr '\n' ' ' || echo 'N/A')"
            if _casc_out=$(ipset list ru 2>&1); then
                grep "Number of entries" <<< "$_casc_out" || echo "ipset ru: entry counter not found"
            else
                echo "ipset ru: set not present ($(head -1 <<< "$_casc_out"))"
            fi
            echo "ru.zone: $(stat -c '%y, %s bytes' "$AWG_DIR/ru.zone" 2>/dev/null || echo 'no file')"
            if _casc_out=$(iptables -t mangle -S PREROUTING 2>&1); then
                grep -m10 -E "match-set|MARK" <<< "$_casc_out" || echo "mangle PREROUTING: no cascade rules"
            else
                echo "mangle PREROUTING: CHECK FAILED: $(head -1 <<< "$_casc_out")"
            fi
            # Grep for "-o awg1" rather than MASQUERADE: a plain MASQUERADE on the external
            # interface is added by the installer itself in PostUp, it exists on EVERY install, and
            # matching it would make the "no rules" branch unreachable while the report showed NAT
            # as present with the cascade rule missing. NAT must be checked: the script applies it
            # LAST, so a run cut short
            # leaves everything else in place but not that rule. The symptom is deceptive: Russian
            # sites work and nothing else does, while a report without this line would show a
            # perfectly healthy cascade.
            if _casc_out=$(iptables -t nat -S POSTROUTING 2>&1); then
                grep -m10 -- "-o awg1" <<< "$_casc_out" || echo "nat POSTROUTING: no cascade rule (-o awg1)"
            else
                echo "nat POSTROUTING: CHECK FAILED: $(head -1 <<< "$_casc_out")"
            fi
        else
            echo "not configured"
        fi
        echo ""
        echo "--- Kernel Params ---"
        sysctl net.ipv4.ip_forward net.ipv6.conf.all.disable_ipv6 2>/dev/null
        echo ""
        echo "--- AWG Journal (last 50) ---"
        journalctl -u awg-quick@awg0 -n 50 --no-pager --output=cat 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Client List ---"
        grep "^#_Name = " "$SERVER_CONF_FILE" 2>/dev/null | sed 's/^#_Name = //' || echo "N/A"
        echo ""
        echo "--- DKMS Status ---"
        dkms status 2>/dev/null || echo "N/A"
        echo ""
        echo "--- Module Info ---"
        modinfo amneziawg 2>/dev/null || echo "N/A"
        echo ""
        echo "=== END ==="
    } | _mask_report_secrets > "$rf" || die "Report write error: $rf"
    umask "$_diag_umask"
    chmod 600 "$rf" || log_warn "Report chmod error."
    log "Report: $rf"
}

# ==============================================================================
# Uninstall
# ==============================================================================

step_uninstall() {
    log "### AMNEZIAWG UNINSTALL ###"
    echo ""
    echo "WARNING! Complete removal of AmneziaWG and configurations."
    echo "This process is irreversible!"
    echo ""
    local confirm="" backup="Y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Are you sure? (type 'yes'): " confirm < /dev/tty
        if [[ "$confirm" != "yes" ]]; then log "Uninstall cancelled."; exit 1; fi
        read -rp "Create backup before removal? [Y/n]: " backup < /dev/tty
    else
        log "Auto-confirming uninstall (--yes)."
    fi
    if [[ -z "$backup" || "$backup" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
        local bf _bp
        local -a _backup_paths=("${AWG_DIR#/}")
        for _bp in \
            etc/amnezia \
            etc/wireguard \
            etc/dnsmasq.d/amneziawg.conf \
            etc/systemd/resolved.conf.d/amneziawg.conf \
            etc/default/awg-warp-bypass \
            etc/systemd/system/awg-warp-bypass.service \
            etc/systemd/system/awg-warp-bypass.timer \
            etc/systemd/system/awg-quick@awg0.service.d/10-awgchain-dependency.conf \
            usr/local/sbin/awg-warp-bypass.sh \
            usr/local/bin/wgcf; do
            [[ -e "/$_bp" ]] && _backup_paths+=("$_bp")
        done
        bf="$HOME/awg_uninstall_backup_$(date +%F_%H-%M-%S).tar.gz"
        log "Creating backup: $bf"
        if ! tar -czf "$bf" -C / "${_backup_paths[@]}" 2>/dev/null || ! chmod 600 "$bf"; then
            rm -f "$bf"
            die "The requested backup failed; uninstall cancelled without deleting components."
        fi
        log "Backup created: $bf"
    fi
    # Load --no-tweaks flag from saved configuration
    local saved_no_tweaks=0
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        saved_no_tweaks=$(safe_read_config_key "NO_TWEAKS" "$CONFIG_FILE" 2>/dev/null) || saved_no_tweaks=0
        saved_no_tweaks=${saved_no_tweaks:-0}
    fi
    log "Stopping service..."
    command -v ip >/dev/null 2>&1 \
        || die "The ip command is required for mandatory live-awg0 verification; uninstall cancelled."
    local _uninstall_awg0_state=""
    _uninstall_awg0_state=$(systemctl is-active awg-quick@awg0 2>/dev/null || true)
    if [[ "$_uninstall_awg0_state" =~ ^(active|activating|deactivating|reloading)$ ]]; then
        systemctl stop awg-quick@awg0 || die "Could not stop active awg-quick@awg0; uninstall cancelled."
    fi
    if command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1; then
        [[ -f "$SERVER_CONF_FILE" && ! -L "$SERVER_CONF_FILE" ]] \
            && timeout 15 awg-quick down "$SERVER_CONF_FILE" >/dev/null 2>&1 \
            || die "Live awg0 could not be removed safely with the expected config; uninstall cancelled."
    fi
    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null \
        || { command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1; }; then
        die "awg0 is still active/live; support/config teardown cancelled."
    fi
    # Isolation DROP rules (issue #178): the on-disk config's PostDown may no
    # longer contain -D DROP (an on->off reinstall interrupted between steps
    # 6 and 7) - drain stale rules explicitly, same as step 7.
    while iptables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
    while ip6tables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
    systemctl disable awg-quick@awg0 2>/dev/null \
        || die "Could not disable awg-quick@awg0; uninstall cancelled before config removal."
    # Remove only the drop-in whose ownership is proven by the exact marker.
    # A foreign file at the same path without a marker is left untouched.
    if [[ -e "$AWG0_DEPENDENCY_MARKER" || -L "$AWG0_DEPENDENCY_MARKER" ]]; then
        local _dependency_path=""
        [[ -f "$AWG0_DEPENDENCY_MARKER" && ! -L "$AWG0_DEPENDENCY_MARKER" ]] \
            || die "Invalid systemd dependency marker; uninstall cancelled."
        IFS= read -r _dependency_path < "$AWG0_DEPENDENCY_MARKER" || _dependency_path=""
        [[ "$_dependency_path" == "$AWG0_DEPENDENCY_DROPIN" ]] \
            || die "Invalid path in the systemd dependency marker; uninstall cancelled."
        rm -f -- "$AWG0_DEPENDENCY_DROPIN" || die "Could not remove the awg0 dependency drop-in."
        rm -f -- "$AWG0_DEPENDENCY_MARKER" || die "Could not clear the awg0 dependency marker."
        rmdir "$(dirname "$AWG0_DEPENDENCY_DROPIN")" 2>/dev/null || true
        systemctl daemon-reload || die "systemctl daemon-reload failed after awg0 dependency removal."
    fi
    # Remove DNS and bypass before WARP: their timer/routes must not outlive
    # egress, and exact teardown requires the current common library.
    if [[ -e "$AWG_DIR/.amnezia_dns_enabled_by_installer" || -L "$AWG_DIR/.amnezia_dns_enabled_by_installer" \
          || -e "$AWG_DIR/.warp_bypass_enabled_by_installer" || -L "$AWG_DIR/.warp_bypass_enabled_by_installer" ]]; then
        local _cleanup_common="$COMMON_SCRIPT_PATH" _local_common=""
        if [[ -n "$INSTALLER_DIR" ]]; then
            _local_common="$INSTALLER_DIR/${COMMON_SCRIPT_URL##*/}"
            [[ -f "$_local_common" ]] && _cleanup_common="$_local_common"
        fi
        [[ -f "$_cleanup_common" && ! -L "$_cleanup_common" ]] \
            || die "The current awg_common_en.sh is required for safe DNS/WARP bypass cleanup."
        # shellcheck source=/dev/null
        source "$_cleanup_common" || die "Could not load $_cleanup_common for cleanup."
        declare -F teardown_amnezia_dns >/dev/null 2>&1 \
            && teardown_amnezia_dns || die "Safe AmneziaDNS removal failed."
        declare -F teardown_warp_bypass >/dev/null 2>&1 \
            && teardown_warp_bypass || die "Safe WARP bypass removal failed."
    fi
    # Multi-hop: tear down the upstream interface only when the saved role is
    # entry. AWG_UPSTREAM_IFACE is persisted for single too, so checking the
    # name alone could stop an unrelated awg-quick@awg1 on uninstall.
    local _saved_role="" _saved_egress="" _up_iface="" _warp_iface=""
    if [[ -f "$CONFIG_FILE" ]]; then
        _saved_role=$(safe_read_config_key "AWG_ROLE" "$CONFIG_FILE" 2>/dev/null || echo "")
        _saved_egress=$(safe_read_config_key "AWG_EGRESS" "$CONFIG_FILE" 2>/dev/null || echo "")
        _up_iface=$(safe_read_config_key "AWG_UPSTREAM_IFACE" "$CONFIG_FILE" 2>/dev/null || echo "")
        _warp_iface=$(safe_read_config_key "AWG_WARP_IFACE" "$CONFIG_FILE" 2>/dev/null || echo "")
    fi
    _up_iface="${_up_iface:-awg1}"
    _warp_iface="${_warp_iface:-wgcf}"
    local _pending_up_marker="$AWG_DIR/.upstream_cleanup_pending" _pending_up_iface=""
    if [[ -e "$_pending_up_marker" || -L "$_pending_up_marker" ]]; then
        [[ -f "$_pending_up_marker" && ! -L "$_pending_up_marker" ]] \
            || die "Unsafe upstream cleanup marker; uninstall cancelled."
        IFS= read -r _pending_up_iface < "$_pending_up_marker" || _pending_up_iface=""
        if [[ "$_pending_up_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$_pending_up_iface" != "awg0" ]]; then
            stop_owned_tunnel_runtime awg "$_pending_up_iface" \
                "/etc/amnezia/amneziawg/${_pending_up_iface}.conf" \
                || die "Could not remove previous upstream ${_pending_up_iface} from runtime completely; uninstall cancelled."
            systemctl disable "awg-quick@${_pending_up_iface}" 2>/dev/null \
                || die "Could not disable previous upstream ${_pending_up_iface}; marker retained."
            if command -v ufw >/dev/null 2>&1 && ! ufw status 2>/dev/null | grep -q inactive; then
                delete_owned_ufw_route_if_present "$_pending_up_iface" \
                    "AmneziaWG cascade awg0->${_pending_up_iface}" \
                    || die "Previous upstream owned UFW route is ambiguous; uninstall cancelled."
            fi
            rm -f "$_pending_up_marker" || die "Could not clear upstream cleanup marker."
        else
            die "Invalid upstream cleanup marker; safe uninstall is not possible."
        fi
    fi
    # An interrupted WARP→WARP migration keeps old-iface ownership in parked
    # markers. Clean it BEFORE processing the new iface's regular markers;
    # otherwise removing AWG_DIR would destroy the only proof of old ownership.
    local _pending_warp_marker="$AWG_DIR/.warp_cleanup_pending" _pending_warp_iface=""
    if [[ -e "$_pending_warp_marker" || -L "$_pending_warp_marker" ]]; then
        [[ -f "$_pending_warp_marker" && ! -L "$_pending_warp_marker" ]] \
            || die "Unsafe WARP cleanup marker; uninstall cancelled."
        IFS= read -r _pending_warp_iface < "$_pending_warp_marker" || _pending_warp_iface=""
        [[ "$_pending_warp_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ \
           && "$_pending_warp_iface" != "awg0" ]] \
            || die "Invalid WARP cleanup marker; safe uninstall is not possible."
        if [[ "$_saved_egress" == "warp" && "$_warp_iface" == "$_pending_warp_iface" ]]; then
            # A crash before the init commit leaves the current iface in the
            # cleanup journal. Restore its parked ownership to the regular
            # markers; the owned-current teardown below then removes it once.
            if [[ -e "$AWG_DIR/.warp_cleanup_service_owner" || -L "$AWG_DIR/.warp_cleanup_service_owner" \
                  || -e "$AWG_DIR/.warp_cleanup_created_config_owner" || -L "$AWG_DIR/.warp_cleanup_created_config_owner" \
                  || -e "$AWG_DIR/.warp_cleanup_managed_config_owner" || -L "$AWG_DIR/.warp_cleanup_managed_config_owner" ]]; then
                _INSTALL_ROLLBACK_WARP_PARKED=1
                _install_restore_parked_warp_ownership \
                    || die "Could not restore current WARP ownership; uninstall cancelled."
            fi
            rm -f -- "$_pending_warp_marker" \
                || die "Could not clear the stale current WARP cleanup marker."
        else
            local AWG_EGRESS="${_saved_egress:-direct}"
            local AWG_WARP_IFACE="${_warp_iface:-wgcf}"
            finalize_deferred_mode_cleanup \
                || die "Could not safely clean the pending WARP migration; ownership retained and uninstall cancelled."
        fi
    fi
    if [[ "$_saved_role" == "entry" && "$_up_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ \
          && "$_up_iface" != "awg0" ]]; then
        log "Stopping upstream interface ${_up_iface}..."
        stop_owned_tunnel_runtime awg "$_up_iface" "/etc/amnezia/amneziawg/${_up_iface}.conf" \
            || die "Could not remove upstream ${_up_iface} from runtime completely; uninstall cancelled."
        systemctl disable "awg-quick@${_up_iface}" 2>/dev/null \
            || die "Could not disable upstream ${_up_iface}; uninstall cancelled before config removal."
        if command -v ufw >/dev/null 2>&1 && ! ufw status 2>/dev/null | grep -q inactive; then
            delete_owned_ufw_route_if_present "$_up_iface" \
                "AmneziaWG cascade awg0->${_up_iface}" \
                || die "Upstream ${_up_iface} owned UFW route is ambiguous; uninstall cancelled."
        fi
    fi
    # WARP egress: every resource we create gets its own root-owned marker.
    # A single broad flag is not enough: the wgcf binary/account/config or the
    # unit itself may have existed before this install. Marker contents are
    # checked against a narrow path allowlist; symlink markers are ignored.
    local _warp_service_marker="$AWG_DIR/.wgcf_enabled_by_installer"
    local _warp_binary_marker="$AWG_DIR/.wgcf_binary_installed_by_installer"
    local _warp_config_marker="$AWG_DIR/.wgcf_config_created_by_installer"
    local _warp_managed_config_marker="$AWG_DIR/.wgcf_config_managed_by_installer"
    local _warp_account_marker="$AWG_DIR/.wgcf_account_created_by_installer"
    local _owned_warp_iface="" _owned_warp_path="" _warp_owned_removed=0 _warp_service_stopped=0
    if [[ -e "$_warp_service_marker" || -L "$_warp_service_marker" ]]; then
        [[ -f "$_warp_service_marker" && ! -L "$_warp_service_marker" ]] \
            || die "Invalid WARP service marker; uninstall cancelled."
        IFS= read -r _owned_warp_iface < "$_warp_service_marker" || _owned_warp_iface=""
        # An empty legacy marker did not preserve the unit's original state and
        # cannot prove ownership: preserve service/config/binary/account.
        if [[ -z "$_owned_warp_iface" ]]; then
            log "Empty legacy WARP marker is ambiguous; preserving wg-quick service as pre-existing."
        elif [[ "$_owned_warp_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ \
              && "$_owned_warp_iface" != "awg0" ]]; then
            log "Stopping Cloudflare WARP (wg-quick@${_owned_warp_iface})..."
            stop_owned_tunnel_runtime wg "$_owned_warp_iface" \
                "/etc/wireguard/${_owned_warp_iface}.conf" \
                || die "Could not remove WARP ${_owned_warp_iface} from runtime completely; uninstall cancelled."
            systemctl disable "wg-quick@${_owned_warp_iface}" 2>/dev/null \
                || die "Could not disable WARP ${_owned_warp_iface}; ownership marker retained."
            _warp_service_stopped=1
            _warp_owned_removed=1
        else
            die "Invalid WARP service marker; uninstall cancelled."
        fi
        rm -f "$_warp_service_marker" || die "Could not clear WARP service marker."
    fi
    if [[ -e "$_warp_config_marker" || -L "$_warp_config_marker" ]]; then
        [[ -f "$_warp_config_marker" && ! -L "$_warp_config_marker" ]] \
            || die "Invalid WARP config marker; uninstall cancelled."
        IFS= read -r _owned_warp_path < "$_warp_config_marker" || _owned_warp_path=""
        if [[ "$_owned_warp_path" =~ ^/etc/wireguard/([a-zA-Z][a-zA-Z0-9_-]{0,14})\.conf$ \
              && "${BASH_REMATCH[1]}" != "awg0" ]]; then
            local _created_warp_iface="${BASH_REMATCH[1]}"
            if [[ "$_warp_service_stopped" -eq 1 && "$_owned_warp_iface" != "$_created_warp_iface" ]]; then
                die "WARP service/config ownership markers point to different interfaces; uninstall cancelled."
            fi
            if [[ "$_warp_service_stopped" -eq 0 ]] \
               && { systemctl is-active --quiet "wg-quick@${_created_warp_iface}" 2>/dev/null \
                    || systemctl is-enabled --quiet "wg-quick@${_created_warp_iface}" 2>/dev/null \
                    || { command -v ip >/dev/null 2>&1 \
                         && ip link show dev "$_created_warp_iface" >/dev/null 2>&1; }; }; then
                die "Installer-created WARP config is used by an active/enabled/live interface without service ownership; uninstall cancelled."
            fi
            rm -f -- "$_owned_warp_path" || die "Could not remove $_owned_warp_path."
            _warp_owned_removed=1
        else
            die "Invalid WARP config marker; uninstall cancelled."
        fi
        rm -f "$_warp_config_marker" || die "Could not clear WARP config marker."
    fi
    if [[ -e "$_warp_managed_config_marker" || -L "$_warp_managed_config_marker" ]]; then
        [[ -f "$_warp_managed_config_marker" && ! -L "$_warp_managed_config_marker" ]] \
            || die "Invalid WARP managed-config marker; uninstall cancelled."
        IFS= read -r _owned_warp_path < "$_warp_managed_config_marker" || _owned_warp_path=""
        if [[ "$_owned_warp_path" =~ ^/etc/wireguard/([a-zA-Z][a-zA-Z0-9_-]{0,14})\.conf$ \
              && "${BASH_REMATCH[1]}" != "awg0" ]]; then
            log "Preserving managed legacy WARP config: $_owned_warp_path"
        else
            die "Invalid path in WARP managed-config marker; uninstall cancelled."
        fi
        rm -f "$_warp_managed_config_marker" \
            || die "Could not clear WARP managed-config marker."
    fi
    if [[ -e "$_warp_account_marker" || -L "$_warp_account_marker" ]]; then
        [[ -f "$_warp_account_marker" && ! -L "$_warp_account_marker" ]] \
            || die "Invalid WARP account marker; uninstall cancelled."
        IFS= read -r _owned_warp_path < "$_warp_account_marker" || _owned_warp_path=""
        if [[ "$_owned_warp_path" == "/etc/wireguard/wgcf-account.toml" ]]; then
            rm -f -- "$_owned_warp_path" || die "Could not remove $_owned_warp_path."
            _warp_owned_removed=1
        else
            die "Invalid WARP account marker; uninstall cancelled."
        fi
        rm -f "$_warp_account_marker" || die "Could not clear WARP account marker."
    fi
    if [[ -e "$_warp_binary_marker" || -L "$_warp_binary_marker" ]]; then
        [[ -f "$_warp_binary_marker" && ! -L "$_warp_binary_marker" ]] \
            || die "Invalid WARP binary marker; uninstall cancelled."
        IFS= read -r _owned_warp_path < "$_warp_binary_marker" || _owned_warp_path=""
        if [[ "$_owned_warp_path" == "/usr/local/bin/wgcf" ]]; then
            rm -f -- "$_owned_warp_path" || die "Could not remove $_owned_warp_path."
            _warp_owned_removed=1
        else
            die "Invalid WARP binary marker; uninstall cancelled."
        fi
        rm -f "$_warp_binary_marker" || die "Could not clear WARP binary marker."
    fi
    if [[ "$_saved_egress" == "warp" && "$_warp_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ \
          && "$_warp_iface" != "awg0" ]] \
       && command -v ufw >/dev/null 2>&1 && ! ufw status 2>/dev/null | grep -q inactive; then
        delete_owned_ufw_route_if_present "$_warp_iface" "AmneziaWG→WARP egress" \
            || die "WARP ${_warp_iface} owned UFW route is ambiguous; uninstall cancelled."
    fi
    [[ "$_warp_owned_removed" -eq 1 ]] && log "Installer-owned WARP components removed."
    modprobe -r amneziawg 2>/dev/null || true
    # v5.12.0+: kernel module auto-repair on kernel upgrade.
    # Remove apt hook and systemd unit BEFORE apt purge so the hook does not
    # fire during amneziawg-dkms purge (the helper would try to rebuild DKMS,
    # but the package is already gone). Files may be absent on installs from
    # before v5.12.0 — all operations are idempotent.
    log "Removing kernel module auto-repair components (v5.12.0+)..."
    if systemctl is-enabled amneziawg-ensure-module.service &>/dev/null; then
        systemctl disable amneziawg-ensure-module.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/amneziawg-ensure-module.service \
        /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        /etc/logrotate.d/amneziawg-ensure-module \
        /usr/local/sbin/amneziawg-ensure-module \
        2>/dev/null
    # Also clean up staging dotfiles that may be left over from an interrupted install (atomic deploy).
    rm -f /etc/systemd/system/.amneziawg-ensure-module.service.new \
        /etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new \
        /etc/logrotate.d/.amneziawg-ensure-module.new \
        /usr/local/sbin/.amneziawg-ensure-module.new \
        2>/dev/null || true
    rm -f /var/log/amneziawg-ensure-module.log* 2>/dev/null || true
    rm -rf /var/lib/amneziawg 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    log "Cleaning up AmneziaWG UFW rules..."
        if command -v ufw &>/dev/null; then
            local port_to_del
            if [[ -f "$CONFIG_FILE" ]]; then
                # shellcheck source=/dev/null
                port_to_del=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
            fi
            port_to_del=${port_to_del:-39743}
            delete_owned_ufw_udp_allow_if_present "$port_to_del" "AmneziaWG VPN" \
                || die "UFW allow ${port_to_del}/udp is foreign or ambiguous; it was preserved and uninstall cancelled."
            # Delete a route only when its shape and installer comment prove
            # ownership unambiguously. Preserve legacy uncommented rules and
            # foreign same-shaped rules instead of guessing during uninstall.
            local _nic
            _nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            if [[ "$_nic" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,14}$ && "$_nic" != "awg0" ]]; then
                delete_owned_ufw_route_if_present "$_nic" "AmneziaWG Routing" \
                    || die "UFW route awg0→${_nic} is foreign or ambiguous; it was preserved and uninstall cancelled."
            else
                log_warn "The main interface could not be determined; any legacy UFW route was preserved."
            fi

            # ufw disable runs ONLY if UFW was enabled by our installer.
            # Protects against destructive uninstall on a VPS where UFW was used
            # for SSH/web hardening BEFORE our script was installed (audit).
            # Backwards compat: older installs without the marker keep UFW active.
            if [[ -f "$AWG_DIR/.ufw_enabled_by_installer" ]]; then
                log "Disabling UFW (was enabled by our installer)..."
                ufw --force disable 2>/dev/null
                rm -f "$AWG_DIR/.ufw_enabled_by_installer"
            else
                log "Leaving UFW active (was active before installation, or older installer version)."
            fi
        fi
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        log "Removing Fail2Ban bans..."
        if command -v fail2ban-client &>/dev/null; then
            fail2ban-client unban --all 2>/dev/null || true
            systemctl stop fail2ban 2>/dev/null
        fi
    else
        log "Skipping Fail2Ban (installed with --no-tweaks); owned UFW rules were removed."
    fi
    log "Removing packages..."
    # Clear the hold on the PPA packages (set by the H0 pinned path) BEFORE the PPA
    # is removed: `apt-mark unhold` needs an installed or candidate version, and once
    # the PPA (below) is gone the candidate disappears and apt-mark fails with
    # 'Can't select ... version', leaving the hold in dpkg selections -> that blocks
    # a future reinstall. The dpkg fallback clears the selection directly if the PPA
    # was already removed by a prior run.
    local _hp
    for _hp in amneziawg amneziawg-dkms; do
        apt-mark unhold "$_hp" >/dev/null 2>&1 || true
        if dpkg --get-selections "$_hp" 2>/dev/null | grep -q '[[:space:]]hold$'; then
            echo "$_hp deinstall" | dpkg --set-selections >/dev/null 2>&1 || true
        fi
    done
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        local _purge_pkgs=(amneziawg-dkms amneziawg-tools qrencode)
        # Purge fail2ban only if we installed it ourselves (marker from
        # setup_fail2ban) - otherwise SSH protection the user had before the
        # installer must not disappear together with the VPN. Our jail file
        # is removed below in any case. Backwards compat: old installs
        # without the marker keep fail2ban installed.
        if [[ -f "$AWG_DIR/.fail2ban_installed_by_installer" ]]; then
            _purge_pkgs+=(fail2ban)
        else
            log "fail2ban left installed (was present before the installer or an older installer version)."
        fi
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${_purge_pkgs[@]}" 2>/dev/null || log_warn "Purge error."
    else
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools qrencode 2>/dev/null || log_warn "Purge error."
    fi
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || log_warn "Autoremove error."
    log "Removing PPA and files..."
    rm -f /etc/apt/sources.list.d/amnezia-ppa.sources \
        /etc/apt/sources.list.d/amnezia-ppa.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.sources \
        /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null
    rm -rf /etc/amnezia \
        /etc/modules-load.d/amneziawg.conf \
        /etc/sysctl.d/99-amneziawg-security.conf \
        /etc/sysctl.d/99-amneziawg-forwarding.conf \
        /etc/logrotate.d/amneziawg* || log_warn "File removal error."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        # Remove only our own jail file.
        # Previously there was a heuristic "if jail.local contains banaction = ufw,
        # remove the whole file" — too broad a filter, could wipe an unrelated
        # jail.local with custom jails. Heuristic removed (audit).
        # If a user still has a jail.local from very old installer versions,
        # leave it for them to deal with.
        rm -f /etc/fail2ban/jail.d/amneziawg.conf 2>/dev/null
        # If fail2ban was not purged (it predates us) - restart it without our
        # jail: it was stopped above (systemctl stop fail2ban).
        if command -v fail2ban-client &>/dev/null && [[ ! -f "$AWG_DIR/.fail2ban_installed_by_installer" ]]; then
            systemctl restart fail2ban 2>/dev/null || log_warn "Failed to restart fail2ban after removing our jail."
        fi
    fi
    log "Removing DKMS..."
    # Properly deregister the DKMS module (any amneziawg/* version) and remove the
    # source tree in /usr/src, not just the state in /var/lib/dkms. The hold on the
    # PPA packages was cleared above (before PPA removal). `dkms status`:
    # 'amneziawg/1.0.0, <kern>...'.
    if command -v dkms >/dev/null 2>&1; then
        local _dv
        while IFS= read -r _dv; do
            [[ -n "$_dv" ]] || continue
            if ! dkms remove -m amneziawg -v "$_dv" --all >/dev/null 2>&1; then
                log_warn "dkms remove amneziawg/$_dv failed - cleaning files manually."
            fi
        done < <(dkms status 2>/dev/null | awk -F'[,/ ]+' '/^amneziawg[,/]/{print $2}' | sort -u)
    fi
    rm -rf /var/lib/dkms/amneziawg* /usr/src/amneziawg-* || log_warn "DKMS removal error."
    # Clean up any leftover built .ko (if dkms remove did not run) + depmod.
    find /lib/modules -name 'amneziawg.ko*' -path '*/updates/dkms/*' -delete 2>/dev/null || true
    command -v depmod >/dev/null 2>&1 && depmod -a >/dev/null 2>&1 || true
    log "Restoring sysctl..."
    # Only the exact lines legacy versions of our installer wrote (=1 for
    # all/default/lo). Previously ANY line containing disable_ipv6 was removed -
    # including lines added by the user themselves (e.g. an =0 override).
    if grep -qE '^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$' /etc/sysctl.conf 2>/dev/null; then
        sed -i -E '/^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$/d' /etc/sysctl.conf || log_warn "sed sysctl.conf error"
    fi
    sysctl -p --system 2>/dev/null
    rm -f /etc/apt/sources.list.d/*.bak-* "$AWG_DIR"/ubuntu.sources.bak-* 2>/dev/null || true
    log "Removing cron and scripts..."
    rm -f /etc/cron.d/awg-expiry 2>/dev/null
    log "=== UNINSTALL COMPLETED ==="
    # Copy log and remove working directory
    cp "$LOG_FILE" "$HOME/awg_uninstall.log" 2>/dev/null || true
    rm -rf "$AWG_DIR" 2>/dev/null || true
    exit 0
}

# ==============================================================================
# STEP 0: Initialization
# ==============================================================================

initialize_setup() {
    if [ "$(id -u)" -ne 0 ]; then die "Run the script as root (sudo bash $0)."; fi

    mkdir -p "$AWG_DIR" || die "Error creating $AWG_DIR"
    chown root:root "$AWG_DIR"

    # Process-wide lock: prevents two install_amneziawg.sh instances from
    # running concurrently. Without it two parallel runs could read the
    # same setup_state, race each other on apt-get/dkms/ufw and corrupt
    # package state (audit).
    # FD 9 is fixed and does not conflict with update_state (uses 200).
    # The lock is held open for the whole process lifetime — released
    # automatically on exit.
    INSTALL_LOCK_FILE="$AWG_DIR/.install.lock"
    exec 9>"$INSTALL_LOCK_FILE" || die "Cannot open $INSTALL_LOCK_FILE"
    if ! flock -n 9; then
        die "Another install_amneziawg_en.sh instance is already running. Wait for it to finish, or if the process is hung, remove $INSTALL_LOCK_FILE and try again."
    fi

    touch "$LOG_FILE" || die "Failed to create log file $LOG_FILE"
    chmod 640 "$LOG_FILE"
    log "--- STARTING AmneziaWG 2.0 INSTALLATION (v${SCRIPT_VERSION}) ---"
    log "### STEP 0: Initialization and parameter check ###"
    cd "$AWG_DIR" || die "Error changing to $AWG_DIR"
    log "Working directory: $AWG_DIR"
    log "Log file: $LOG_FILE"

    check_os_version
    check_container
    check_kernel_version
    check_free_space

    local default_port=39743
    local default_subnet="10.9.9.1/24"
    local config_exists=0

    # Variable initialization
    AWG_PORT=$default_port
    AWG_TUNNEL_SUBNET=$default_subnet
    DISABLE_IPV6="default"
    ALLOWED_IPS_MODE="default"
    ALLOWED_IPS=""
    AWG_ENDPOINT=""
    CLIENT_ISOLATION=""
    # Hard reset (not ${VAR:-}): the internal ownership marker must not be
    # inherited from the environment - an externally exported variable would
    # otherwise reach the AllowedIPs route removal (PR #179 review).
    CLIENT_ISOLATION_NET=""

    # Hard reset before the config is loaded: the value must not come from env.
    AWG_SERVER_NAME=""
    ALLOW_IPV6_TUNNEL=""
    IPV6_SUBNET=""
    SERVER_HAS_NATIVE_IPV6=""

    # Fork-specific routing state follows the same rule: only the root-owned
    # init file and explicit CLI flags may select cascade/WARP/DNS behaviour.
    # Inheriting these values from `sudo -E` could otherwise rewrite firewall
    # and policy-routing rules without any matching command-line option.
    AWG_I1_MODE=""
    AWG_ROLE=""
    AWG_UPSTREAM_CONF=""
    AWG_UPSTREAM_IFACE=""
    AWG_UPSTREAM_TABLE=""
    AWG_UPSTREAM_FWMARK=""
    AWG_UPSTREAM_PRIORITY=""
    AWG_EGRESS=""
    AWG_WARP_IFACE=""
    AWG_WARP_TABLE=""
    AWG_WARP_PRIORITY=""
    AWG_WARP_BYPASS=""
    AWG_AMNEZIA_DNS=""

    # Load config
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Configuration file found $CONFIG_FILE. Loading settings..."
        config_exists=1
        # shellcheck source=/dev/null
        safe_load_config "$CONFIG_FILE" || log_warn "Failed to fully load settings from $CONFIG_FILE."
        AWG_PORT=${AWG_PORT:-$default_port}
        AWG_TUNNEL_SUBNET=${AWG_TUNNEL_SUBNET:-$default_subnet}
        DISABLE_IPV6=${DISABLE_IPV6:-"default"}
        ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE:-"default"}
        ALLOWED_IPS=${ALLOWED_IPS:-""}
        AWG_ENDPOINT=${AWG_ENDPOINT:-""}
        # CLIENT_ISOLATION from the config: strictly 0|1 (the whitelist parser
        # does not check values, and configs get edited by hand). Otherwise the
        # arithmetic context [[ "on" -eq 1 ]] dereferences the string as an
        # empty variable (=0) and silently INVERTS the security setting: wrote
        # on - got off (PR #179 review).
        case "${CLIENT_ISOLATION:-}" in
            ""|0|1) : ;;
            *)
                log_warn "CLIENT_ISOLATION='$CLIENT_ISOLATION' in $CONFIG_FILE is invalid (0|1 allowed) - enabling isolation (safe default)."
                CLIENT_ISOLATION=1
                ;;
        esac
        # CLIENT_ISOLATION_NET is an internal ownership marker: exactly one
        # canonical IPv4 CIDR (tunnel_network_cidr output). Comma-carrying
        # garbage would let the substring replace in
        # _apply_isolation_to_allowed_ips eat adjacent user routes in a single
        # substitution (PR #179 review).
        if [[ -n "${CLIENT_ISOLATION_NET:-}" ]] \
           && [[ "$(tunnel_network_cidr "$CLIENT_ISOLATION_NET" || true)" != "$CLIENT_ISOLATION_NET" ]]; then
            log_warn "CLIENT_ISOLATION_NET='$CLIENT_ISOLATION_NET' in $CONFIG_FILE is invalid (a single canonical CIDR expected) - resetting."
            CLIENT_ISOLATION_NET=""
        fi
        log "Settings loaded from file."
    else
        log "Configuration file $CONFIG_FILE not found."
    fi

    case "$CLI_I1_MODE" in
        ""|random|quic) : ;;
        *) die "Invalid --i1-mode='$CLI_I1_MODE'. Allowed values: random or quic." ;;
    esac
    # Legacy configs have no AWG_I1_MODE key. Recover it from the I1 shape and
    # do not persist a malformed enum value. I1 itself is deliberately left
    # untouched here: it is part of existing clients' wire contract.
    if [[ "$config_exists" -eq 1 ]]; then
        case "${AWG_I1_MODE:-}" in
            random|quic) : ;;
            "")
                if [[ "${AWG_I1:-}" == "<b 0x"*">" ]]; then AWG_I1_MODE=quic; else AWG_I1_MODE=random; fi
                ;;
            *)
                log_warn "AWG_I1_MODE='$AWG_I1_MODE' in $CONFIG_FILE is invalid — recovering the mode from the existing I1."
                if [[ "${AWG_I1:-}" == "<b 0x"*">" ]]; then AWG_I1_MODE=quic; else AWG_I1_MODE=random; fi
                ;;
        esac
    fi

    # Preserve the old fork-routing state for deferred cleanup after possible
    # reboots in steps 1/2. The new init is written below, so capture these
    # values before applying CLI overrides.
    local _cfg_awg_role="" _cfg_upstream_iface="" _cfg_awg_egress="" _cfg_warp_iface=""
    if [[ "$config_exists" -eq 1 ]]; then
        _cfg_awg_role="${AWG_ROLE:-single}"
        _cfg_upstream_iface="${AWG_UPSTREAM_IFACE:-awg1}"
        _cfg_awg_egress="${AWG_EGRESS:-direct}"
        _cfg_warp_iface="${AWG_WARP_IFACE:-wgcf}"
    fi
    reconcile_pending_mode_markers \
        "$config_exists" "$_cfg_awg_role" "$_cfg_upstream_iface" \
        "$_cfg_awg_egress" "$_cfg_warp_iface" \
        || die "The pending cleanup journal is corrupt or conflicts with the current fork mode; live egress was not changed."

    # The old port from awgsetup_cfg.init: step 4 needs it to delete the stale
    # UFW rule on a port change (Issue #175). Captured BEFORE the CLI override,
    # otherwise the old value is lost for good - uninstall reads the already
    # rewritten config and never learns the old port. PREV_AWG_PORT may already
    # be loaded from awgsetup_cfg.init via safe_load_config - that is a pending
    # delete from a previous run: step 1 ends in request_reboot, only a value
    # written to disk survives until step 4 (PR #176).
    PREV_AWG_PORT="${PREV_AWG_PORT:-}"
    _cfg_awg_port=""
    if [[ "$config_exists" -eq 1 ]]; then _cfg_awg_port="$AWG_PORT"; fi

    # Previous isolation value - for the change warning (issue #178).
    # A legacy config without the key = 1 (isolated): otherwise a legacy ->
    # --isolation=off transition would not warn about regen.
    _cfg_client_isolation=""
    if [[ "$config_exists" -eq 1 ]]; then _cfg_client_isolation="${CLIENT_ISOLATION:-1}"; fi

    # Previous server name - for the change warning (D#180).
    # A legacy config without the key = 'AWG Server' (the old hardcode).
    _cfg_server_name=""
    if [[ "$config_exists" -eq 1 ]]; then _cfg_server_name="${AWG_SERVER_NAME:-AWG Server}"; fi

    # --mobile expands into CLI_PRESET/CLI_PORT before their consumers.
    resolve_mobile_flag

    # CLI override
    AWG_PORT=${CLI_PORT:-$AWG_PORT}
    # The port changed in this run - the previous value becomes a pending
    # delete. If the port was changed back (matches the pending value), the
    # delete is cancelled: the rule is needed again.
    if [[ -n "$_cfg_awg_port" && "$_cfg_awg_port" != "$AWG_PORT" ]]; then
        PREV_AWG_PORT="$_cfg_awg_port"
    fi
    if [[ "$PREV_AWG_PORT" == "$AWG_PORT" ]]; then PREV_AWG_PORT=""; fi
    AWG_TUNNEL_SUBNET=${CLI_SUBNET:-$AWG_TUNNEL_SUBNET}
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then DISABLE_IPV6=$CLI_DISABLE_IPV6; fi
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then
        ALLOWED_IPS_MODE=$CLI_ROUTING_MODE
        # An explicit CLI mode overrides the list too: previously --route-all/
        # --route-amnezia on reinstall changed only the mode while ALLOWED_IPS
        # kept the old value from awgsetup_cfg.init - the flag silently had no
        # effect (Issue #170). An empty list forces configure_routing_mode to
        # recompute it for the new mode.
        ALLOWED_IPS=""
        # Ownership dies with the list it described: otherwise a stale
        # CLIENT_ISOLATION_NET could claim a user's token from a fresh
        # --route-custom list (issue #178).
        CLIENT_ISOLATION_NET=""
        if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then ALLOWED_IPS=$CLI_CUSTOM_ROUTES; fi
    fi
    if [[ -n "$CLI_ENDPOINT" ]]; then
        if ! validate_endpoint "$CLI_ENDPOINT"; then
            die "Invalid --endpoint: '$CLI_ENDPOINT'. Allowed formats: FQDN (vpn.example.com), IPv4 (1.2.3.4), [IPv6] ([2001:db8::1]). Spaces, tabs, quotes, backslashes and newlines are forbidden."
        fi
        AWG_ENDPOINT=$CLI_ENDPOINT
    fi
    if [[ "$CLI_NO_TWEAKS" -eq 1 ]]; then NO_TWEAKS=1; fi
    if [[ "$CLI_KEEP_PACKAGES" -eq 1 ]]; then KEEP_PACKAGES=1; fi

    # Multi-hop: node role and upstream tunnel parameters.
    # CLI > saved config > defaults. Value 'single' requires no upstream fields;
    # 'exit' is just an ordinary server marked with the role for manager and
    # documentation; 'entry' requires an upstream config.
    AWG_ROLE="${AWG_ROLE:-single}"
    if [[ -n "$CLI_ROLE" ]]; then AWG_ROLE="$CLI_ROLE"; fi
    case "$AWG_ROLE" in
        single|exit|entry) ;;
        *) die "Invalid --role='$AWG_ROLE'. Allowed: single, exit, entry." ;;
    esac
    AWG_UPSTREAM_IFACE="${CLI_UPSTREAM_IFACE:-${AWG_UPSTREAM_IFACE:-awg1}}"
    AWG_UPSTREAM_TABLE="${CLI_UPSTREAM_TABLE:-${AWG_UPSTREAM_TABLE:-123}}"
    AWG_UPSTREAM_FWMARK="${CLI_UPSTREAM_FWMARK:-${AWG_UPSTREAM_FWMARK:-0xca6d}}"
    AWG_UPSTREAM_PRIORITY="${AWG_UPSTREAM_PRIORITY:-456}"
    if [[ "$AWG_ROLE" == "entry" ]]; then
        if [[ "$AWG_UPSTREAM_IFACE" == "awg0" ]]; then
            die "--upstream-iface=awg0 clashes with the primary interface. Use awg1."
        fi
        if ! [[ "$AWG_UPSTREAM_IFACE" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]]; then
            die "Invalid --upstream-iface='$AWG_UPSTREAM_IFACE'."
        fi
        if ! validate_policy_table "$AWG_UPSTREAM_TABLE"; then
            die "Invalid --upstream-table='$AWG_UPSTREAM_TABLE' (1..4294967295 except reserved 253-255)."
        fi
        if ! validate_fwmark "$AWG_UPSTREAM_FWMARK"; then
            die "Invalid --upstream-fwmark='$AWG_UPSTREAM_FWMARK' (non-zero uint32, not 0xca6c)."
        fi
        if ! validate_policy_priority "$AWG_UPSTREAM_PRIORITY"; then
            die "Invalid AWG_UPSTREAM_PRIORITY='$AWG_UPSTREAM_PRIORITY' (1..32764; lookup and guard must precede main rule 32766)."
        fi
        # Upstream conf: CLI is mandatory only on the first run. If
        # awg1.conf already exists on disk (second run after reboot) we assume
        # it was created correctly earlier and do not require --upstream-conf.
        local _up_iface_conf="/etc/amnezia/amneziawg/${AWG_UPSTREAM_IFACE}.conf"
        local _up_staged_conf="$AWG_DIR/.upstream-${AWG_UPSTREAM_IFACE}.pending.conf"
        if [[ -n "$CLI_UPSTREAM_CONF" ]]; then
            if [[ ! -f "$CLI_UPSTREAM_CONF" ]]; then
                die "--upstream-conf not found: '$CLI_UPSTREAM_CONF'."
            fi
            # Steps 1/2 may reboot the VPS before step 6 renders this file.
            # Copy it into root-owned AWG_DIR so the resumed run does not rely
            # on the original path or on repeating the CLI argument.
            local _up_stage_tmp
            _up_stage_tmp=$(mktemp -p "$AWG_DIR" ".upstream-${AWG_UPSTREAM_IFACE}.XXXXXX") \
                || die "Could not create the upstream staging file."
            _install_temp_files+=("$_up_stage_tmp")
            cp -- "$CLI_UPSTREAM_CONF" "$_up_stage_tmp" \
                && chmod 600 "$_up_stage_tmp" \
                && mv -f "$_up_stage_tmp" "$_up_staged_conf" \
                || { rm -f "$_up_stage_tmp"; die "Could not safely stage --upstream-conf across reboot."; }
            AWG_UPSTREAM_CONF="$_up_staged_conf"
        elif [[ -s "$_up_staged_conf" ]]; then
            AWG_UPSTREAM_CONF="$_up_staged_conf"
        elif [[ -f "$_up_iface_conf" \
                && ( -n "$CLI_UPSTREAM_TABLE" || -n "$CLI_UPSTREAM_FWMARK" ) ]]; then
            # Policy-only intent must survive reboots in steps 1/2. Snapshot it
            # in the pending path; process-local AWG_UPSTREAM_CONF was lost.
            local _up_policy_tmp
            _up_policy_tmp=$(mktemp -p "$AWG_DIR" ".upstream-policy-${AWG_UPSTREAM_IFACE}.XXXXXX") \
                || die "Could not create a policy-only upstream staging file."
            _install_temp_files+=("$_up_policy_tmp")
            cp -- "$_up_iface_conf" "$_up_policy_tmp" \
                && chmod 600 "$_up_policy_tmp" \
                && mv -f "$_up_policy_tmp" "$_up_staged_conf" \
                || { rm -f "$_up_policy_tmp"; die "Could not persist policy-only upstream intent across reboot."; }
            AWG_UPSTREAM_CONF="$_up_staged_conf"
        elif [[ ! -f "$_up_iface_conf" ]]; then
            die "role=entry requires --upstream-conf=<file.conf> (from manage add on the exit node)."
        fi
        export AWG_UPSTREAM_CONF
    fi
    export AWG_ROLE AWG_UPSTREAM_IFACE AWG_UPSTREAM_TABLE AWG_UPSTREAM_FWMARK AWG_UPSTREAM_PRIORITY

    # WARP egress: client traffic flows out via Cloudflare WARP instead of
    # direct NAT on eth0. Available only for role=single or role=exit. On
    # entry the egress is already delegated to the upstream node — putting
    # WARP there would add a pointless third wrapper, so we reject it.
    AWG_EGRESS="${AWG_EGRESS:-direct}"
    if [[ -n "$CLI_EGRESS" ]]; then AWG_EGRESS="$CLI_EGRESS"; fi
    case "$AWG_EGRESS" in
        direct|warp) ;;
        *) die "Invalid --egress='$AWG_EGRESS'. Allowed: direct, warp." ;;
    esac
    if [[ "$AWG_EGRESS" == "warp" && "$AWG_ROLE" == "entry" ]]; then
        die "--egress=warp is incompatible with --role=entry. Put WARP on the exit node (or single), not on entry."
    fi
    AWG_WARP_IFACE="${CLI_WARP_IFACE:-${AWG_WARP_IFACE:-wgcf}}"
    AWG_WARP_TABLE="${CLI_WARP_TABLE:-${AWG_WARP_TABLE:-2408}}"
    AWG_WARP_PRIORITY="${CLI_WARP_PRIORITY:-${AWG_WARP_PRIORITY:-789}}"
    if [[ "$AWG_EGRESS" == "warp" ]]; then
        if ! [[ "$AWG_WARP_IFACE" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] \
           || [[ "$AWG_WARP_IFACE" == "awg0" || "$AWG_WARP_IFACE" == "wgcf-profile" ]]; then
            die "Invalid AWG_WARP_IFACE='$AWG_WARP_IFACE'."
        fi
        if ! validate_policy_table "$AWG_WARP_TABLE"; then
            die "Invalid --warp-table='$AWG_WARP_TABLE' (1..4294967295 except reserved 253-255)."
        fi
        if ! validate_policy_priority "$AWG_WARP_PRIORITY"; then
            die "Invalid --warp-priority='$AWG_WARP_PRIORITY' (1..32764; lookup and guard must precede main rule 32766)."
        fi
        # entry and WARP are mutually exclusive, so a persisted upstream table
        # is not an active consumer on single/exit and must not block the same
        # table number for WARP.
    fi
    # --warp-bypass: comma-separated list of sources for WARP exceptions.
    # Each item: `youtube` | `custom:URL` | `custom:/path`.
    # `none` (default) — nothing. Only meaningful with egress=warp.
    AWG_WARP_BYPASS="${CLI_WARP_BYPASS:-${AWG_WARP_BYPASS:-none}}"
    if [[ "$AWG_WARP_BYPASS" != "none" && "$AWG_EGRESS" != "warp" ]]; then
        die "--warp-bypass only makes sense together with --egress=warp (no WARP to bypass otherwise)."
    fi
    if (( ${#AWG_WARP_BYPASS} > 4096 )); then
        die "--warp-bypass is too long (4096 characters maximum)."
    fi
    if [[ "$AWG_WARP_BYPASS" =~ [[:cntrl:]] ]]; then
        die "--warp-bypass contains a control character."
    fi
    case "$AWG_WARP_BYPASS" in
        *" "*|*"'"*|*'"'*|*\\*)
            die "--warp-bypass does not allow spaces, quotes, or backslashes."
            ;;
    esac
    if [[ "$AWG_WARP_BYPASS" == ,* || "$AWG_WARP_BYPASS" == *, \
          || "$AWG_WARP_BYPASS" == *,,* ]]; then
        die "--warp-bypass contains an empty list item."
    fi
    if [[ "$AWG_WARP_BYPASS" != "none" ]]; then
        local -a _specs=()
        local _warp_bypass_url_re='^custom:https?://[A-Za-z0-9][A-Za-z0-9._~:/?#@!$&()*+;=%-]*$'
        local _warp_bypass_path_re='^custom:/[A-Za-z0-9._~+/@%=-]+$'
        IFS=',' read -r -a _specs <<< "$AWG_WARP_BYPASS"
        local _s
        for _s in "${_specs[@]}"; do
            case "$_s" in
                youtube) ;;
                *)
                    [[ "$_s" =~ $_warp_bypass_url_re || "$_s" =~ $_warp_bypass_path_re ]] \
                        || die "Invalid --warp-bypass: '$_s'. Allowed: youtube, a safe custom:http(s)://URL, or custom:/absolute/path — comma-separated."
                    ;;
            esac
        done
    fi
    export AWG_EGRESS AWG_WARP_IFACE AWG_WARP_TABLE AWG_WARP_PRIORITY AWG_WARP_BYPASS

    # A fork-routing mode change may cross two reboots before step 6. Persist
    # the old interface names so units carrying stale policy rules are stopped
    # before the new awg0 is started.
    local _fork_mode_transition=0
    if [[ "$config_exists" -eq 1 ]] \
       && { [[ "$_cfg_awg_role" != "$AWG_ROLE" ]] \
            || [[ "$_cfg_awg_role" == "entry" && "$AWG_ROLE" == "entry" \
                  && "$_cfg_upstream_iface" != "$AWG_UPSTREAM_IFACE" ]] \
            || [[ "$_cfg_awg_egress" != "$AWG_EGRESS" ]] \
            || [[ "$_cfg_awg_egress" == "warp" && "$AWG_EGRESS" == "warp" \
                  && "$_cfg_warp_iface" != "$AWG_WARP_IFACE" ]]; }; then
        _fork_mode_transition=1
    fi
    if [[ "$_fork_mode_transition" -eq 1 ]] \
       && { [[ -e "$AWG_DIR/.upstream_cleanup_pending" || -L "$AWG_DIR/.upstream_cleanup_pending" ]] \
            || [[ -e "$AWG_DIR/.warp_cleanup_pending" || -L "$AWG_DIR/.warp_cleanup_pending" ]] \
            || [[ -e "$AWG_DIR/.ufw_main_cleanup_pending" || -L "$AWG_DIR/.ufw_main_cleanup_pending" ]]; }; then
        die "A second fork-mode migration cannot start before the previous cleanup finishes. First rerun the installer without changing role/egress/iface."
    fi
    if [[ "$config_exists" -eq 1 && "$_cfg_awg_role" == "entry" \
          && ( "$AWG_ROLE" != "entry" || "$AWG_UPSTREAM_IFACE" != "$_cfg_upstream_iface" ) ]]; then
        write_pending_iface_marker "$AWG_DIR/.upstream_cleanup_pending" "$_cfg_upstream_iface" \
            || die "Could not preserve the old upstream iface for safe post-reboot cleanup."
    fi
    if [[ "$config_exists" -eq 1 && "$_cfg_awg_egress" == "warp" \
          && ( "$AWG_EGRESS" != "warp" || "$AWG_WARP_IFACE" != "$_cfg_warp_iface" ) ]]; then
        write_pending_iface_marker "$AWG_DIR/.warp_cleanup_pending" "$_cfg_warp_iface" \
            || die "Could not preserve the old WARP iface for safe post-reboot cleanup."
    fi
    # awg0→main is needed by direct mode and only by WARP with an explicit
    # bypass. In warp+bypass=none it would combine with main MASQUERADE into a
    # fail-open path. Remove only a confirmed previous owned rule and only at
    # the commit boundary so an early failure cannot damage rollback.
    local _old_main_route_required=0 _new_main_route_required=0
    # Older installer revisions added this route for every non-entry mode,
    # including warp+bypass=none. Exact UFW comment/shape checks remain the
    # final ownership boundary before deletion.
    if [[ "$config_exists" -eq 1 && "$_cfg_awg_role" =~ ^(single|exit)$ \
          && "$_cfg_awg_egress" =~ ^(direct|warp)$ ]]; then
        _old_main_route_required=1
    fi
    if [[ "$AWG_ROLE" =~ ^(single|exit)$ ]] \
       && { [[ "$AWG_EGRESS" == "direct" ]] \
            || [[ "$AWG_EGRESS" == "warp" && "$AWG_WARP_BYPASS" != "none" ]]; }; then
        _new_main_route_required=1
    fi
    if [[ "$_old_main_route_required" -eq 1 && "$_new_main_route_required" -eq 0 ]]; then
        local _old_main_nic=""
        _old_main_nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}')
        if [[ "$_old_main_nic" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,14}$ ]]; then
            write_pending_main_iface_marker "$_old_main_nic" \
                || die "Could not retain the previous main iface for deferred UFW cleanup."
        else
            log_warn "Could not safely determine the previous main iface; preserving the UFW awg0→main rule."
        fi
    fi

    # AmneziaDNS: local dnsmasq on the tunnel-gateway IP + vpn:// URI with
    # isThirdPartyConfig=false so the Amnezia VPN client unlocks the
    # built-in site-based split tunneling (sites in the "bypass VPN" list
    # use the device's real link; the site sees the user's real IP).
    # Allowed on role=single and role=entry. Rejected on exit: exit does
    # not serve configs to clients directly.
    AWG_AMNEZIA_DNS="${CLI_AMNEZIA_DNS:-${AWG_AMNEZIA_DNS:-off}}"
    case "$AWG_AMNEZIA_DNS" in
        on|off) ;;
        *) die "Invalid --amnezia-dns='$AWG_AMNEZIA_DNS'. Allowed: on, off." ;;
    esac
    if [[ "$AWG_AMNEZIA_DNS" == "on" && "$AWG_ROLE" == "exit" ]]; then
        die "--amnezia-dns=on is not compatible with --role=exit. AmneziaDNS belongs on the node that hands configs to clients (single or entry)."
    fi
    export AWG_AMNEZIA_DNS

    # Validate after CLI override
    validate_port "$AWG_PORT"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    # AWG_ENDPOINT may have come from CONFIG_FILE via safe_load_config (no CLI override).
    # If the value is present and invalid — log_warn + reset to "" so the installer
    # falls back to auto-detect via get_server_public_ip (audit).
    if [[ -n "$AWG_ENDPOINT" ]] && ! validate_endpoint "$AWG_ENDPOINT"; then
        log_warn "AWG_ENDPOINT='$AWG_ENDPOINT' from $CONFIG_FILE is invalid, falling back to auto-detect."
        AWG_ENDPOINT=""
    fi

    # Request settings from user only on first run
    if [[ "$config_exists" -eq 0 ]]; then
        log "Requesting settings from user (first run)."
        # Interactive input: a typo does not kill the install (the validator
        # runs in a subshell -> die prints the error but only terminates the
        # subshell, and the prompt repeats). The final validate_* calls
        # outside the loop stay authoritative for CLI/config values (die is
        # appropriate there).
        if [[ "$AUTO_YES" -eq 0 ]]; then
            while true; do
                read -rp "Enter AmneziaWG UDP port (1-65535) [${AWG_PORT}]: " input_port < /dev/tty
                [[ -z "$input_port" ]] && break
                if ( validate_port "$input_port" ); then AWG_PORT=$input_port; break; fi
                log_warn "Please re-enter the port."
            done
        fi
        validate_port "$AWG_PORT"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            while true; do
                read -rp "Enter tunnel subnet [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty
                [[ -z "$input_subnet" ]] && break
                if ( validate_subnet "$input_subnet" ); then AWG_TUNNEL_SUBNET=$input_subnet; break; fi
                log_warn "Please re-enter the subnet."
            done
        fi
        validate_subnet "$AWG_TUNNEL_SUBNET"
        if [[ "$DISABLE_IPV6" == "default" ]]; then configure_ipv6; fi
        if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then configure_routing_mode; fi
    else
        log "Using settings from $CONFIG_FILE."
        if [[ "$ALLOWED_IPS_MODE" == "3" ]] && [[ -n "$ALLOWED_IPS" ]]; then
            if ! validate_cidr_list "$ALLOWED_IPS"; then
                die "Invalid ALLOWED_IPS in config: '$ALLOWED_IPS'. Delete $CONFIG_FILE and re-run the installer."
            fi
        fi
    fi

    # Consent for removing system packages is asked OUTSIDE the branching above.
    # The call used to sit in the "no config" branch only, so a --force reinstall on an
    # already configured server walked straight past the question: step99 deletes the
    # state file, so a repeated run starts at step 1 and reaches the cleanup again. Configs
    # written before 5.27.0 have no KEEP_PACKAGES entry at all, and its absence read as
    # consent, which reproduced issue #213 on the very version that fixes it.
    # The function itself returns immediately when the decision is already made.
    if [[ -n "$KEEP_PACKAGES" && "$KEEP_PACKAGES" != "0" && "$KEEP_PACKAGES" != "1" ]]; then
        log_warn "KEEP_PACKAGES in $CONFIG_FILE has an invalid value '$KEEP_PACKAGES' - assuming the packages must be kept."
        KEEP_PACKAGES=1
    fi
    configure_package_cleanup

    # Changing the subnet with live peers is forbidden - check before the
    # init file is saved and before any on-disk changes (AWG_TUNNEL_SUBNET
    # is final here).
    guard_subnet_change_with_peers

    # Default values
    if [[ "$DISABLE_IPV6" == "default" ]]; then DISABLE_IPV6=1; fi
    configure_ipv6_tunnel
    if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then ALLOWED_IPS_MODE=2; fi
    if [[ -z "$ALLOWED_IPS" ]]; then configure_routing_mode; fi

    # Client isolation (issue #178): choice + AllowedIPs alignment. Called
    # before validate_cidr_list below - an appended subnet goes through the
    # same mandatory validation as the rest of the list.
    configure_client_isolation
    _apply_isolation_to_allowed_ips

    # Single mandatory AllowedIPs validation before saving the config: CLI
    # --route-custom on a first run assigned ALLOWED_IPS without checking it
    # (configure_routing_mode was skipped because the mode was already 3).
    # Validate any non-empty list regardless of its source (CLI / config / mode).
    if [[ -n "$ALLOWED_IPS" ]] && ! validate_cidr_list "$ALLOWED_IPS"; then
        die "Invalid ALLOWED_IPS: '$ALLOWED_IPS'. Expected a list x.x.x.x/y[,x.x.x.x/y]."
    fi

    # Server name for the vpn:// URI (D#180): source selection + validation.
    configure_server_name

    # For active awg0 skip the check only when it already listens on the
    # requested port. A new --port is checked before the VPN is stopped.
    local _live_awg_port=""
    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        _live_awg_port=$(sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$SERVER_CONF_FILE" 2>/dev/null | tail -1)
    fi
    if [[ -n "$_live_awg_port" && "$_live_awg_port" == "$AWG_PORT" ]]; then
        log "Active awg0 already listens on ${AWG_PORT}/udp — the expected service owns the port."
    else
        check_port_availability "$AWG_PORT" || die "Port $AWG_PORT/udp is occupied."
    fi

    # AWG 2.0 parameter generation
    # Full regeneration: first run or a J/S/H-set override. A lone --i1-mode
    # changes I1 only below and preserves every other parameter.
    if [[ -z "${AWG_Jc:-}" ]] || [[ -n "${CLI_PRESET:-}" ]] || [[ -n "${CLI_JC:-}" ]] \
        || [[ -n "${CLI_JMIN:-}" ]] || [[ -n "${CLI_JMAX:-}" ]]; then
        # generate_awg_params regenerates the WHOLE set (S1-S4, H1-H4, I1),
        # not just the requested parameter: on a reinstall over a live server
        # every issued client config still holds the old H1-H4 and will stop
        # connecting. Warn loudly.
        if [[ "$config_exists" -eq 1 && -n "${AWG_Jc:-}" ]]; then
            log_warn "WARNING: --preset/--jc/--jmin/--jmax on a reinstall regenerate ALL obfuscation parameters (including H1-H4/S1-S4/I1)."
            log_warn "All existing client configs will stop connecting - reissue them after the install: sudo bash $MANAGE_SCRIPT_PATH regen"
        fi
        generate_awg_params
    elif [[ -n "${CLI_I1_MODE:-}" ]]; then
        local _i1_matches_mode=0
        case "$CLI_I1_MODE" in
            random) [[ "${AWG_I1:-}" == "<r "*">" ]] && _i1_matches_mode=1 ;;
            quic)   [[ "${AWG_I1:-}" == "<b 0x"*">" ]] && _i1_matches_mode=1 ;;
        esac
        if [[ "${AWG_I1_MODE:-random}" == "$CLI_I1_MODE" && "$_i1_matches_mode" -eq 1 ]]; then
            log "I1 already matches --i1-mode=${CLI_I1_MODE}; preserving it (idempotent run)."
        else
            if [[ "$config_exists" -eq 1 ]]; then
                log_warn "WARNING: --i1-mode=${CLI_I1_MODE} changes I1. Existing client configs will stop connecting - reissue them: sudo bash $MANAGE_SCRIPT_PATH regen"
            fi
            generate_i1_for_mode "$CLI_I1_MODE"
        fi
    else
        log "AWG 2.0 parameters already set from config."
    fi

    # CPS (I1) toggle (issue #159): --no-cps drops the I1 parameter that makes the
    # desktop AmneziaVPN on macOS hang on connect (mobile and CLI clients handle
    # CPS fine). Only I1 is cleared, the rest of the obfuscation set (Jc/S1-S4/
    # H1-H4) is left intact. Explicit --preset/--jc/--jmin/--jmax/--i1-mode without --no-cps
    # re-enable CPS (a fresh set includes I1). Otherwise keep the state from init.
    if [[ "${CLI_NO_CPS:-0}" -eq 1 ]]; then
        NO_CPS=1
    elif [[ -n "${CLI_PRESET:-}" || -n "${CLI_JC:-}" || -n "${CLI_JMIN:-}" || -n "${CLI_JMAX:-}" || -n "${CLI_I1_MODE:-}" ]]; then
        NO_CPS=0
    fi
    if [[ "${NO_CPS:-0}" -eq 1 ]]; then
        if [[ -n "${AWG_I1:-}" && "$config_exists" -eq 1 ]]; then
            log_warn "WARNING: --no-cps drops the I1 (CPS) parameter. Existing client configs that still carry I1 will stop connecting - reissue them: sudo bash $MANAGE_SCRIPT_PATH regen"
        fi
        AWG_I1=''
        log "CPS (I1) disabled (--no-cps / persisted NO_CPS=1): the desktop AmneziaVPN on macOS does not support CPS."
    fi

    # Save configuration
    log "Saving settings to $CONFIG_FILE..."
    # temp in the target config's directory -> mv = atomic rename on the same
    # filesystem (not a cross-fs copy+unlink when /tmp is mounted as tmpfs).
    local temp_conf cfg_dir
    cfg_dir="$(dirname "$CONFIG_FILE")"
    mkdir -p "$cfg_dir" 2>/dev/null
    temp_conf=$(mktemp -p "$cfg_dir") || die "mktemp error."
    _install_temp_files+=("$temp_conf")
    cat > "$temp_conf" << EOF
# AmneziaWG 2.0 installation configuration (Auto-generated)
# Used by installation and management scripts
export OS_ID='${OS_ID:-ubuntu}'
export OS_VERSION='${OS_VERSION:-}'
export OS_CODENAME='${OS_CODENAME:-}'
export AWG_PORT=${AWG_PORT}
export AWG_TUNNEL_SUBNET='${AWG_TUNNEL_SUBNET}'
export DISABLE_IPV6=${DISABLE_IPV6}
export ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE}
export ALLOWED_IPS='${ALLOWED_IPS}'
export CLIENT_ISOLATION=${CLIENT_ISOLATION:-1}
export CLIENT_ISOLATION_NET='${CLIENT_ISOLATION_NET:-}'
export AWG_ENDPOINT='${AWG_ENDPOINT}'
export AWG_SERVER_NAME='${AWG_SERVER_NAME:-AWG Server}'
export AWG_MTU=${AWG_MTU:-1280}
# AWG 2.0 Parameters
export AWG_Jc=${AWG_Jc}
export AWG_Jmin=${AWG_Jmin}
export AWG_Jmax=${AWG_Jmax}
export AWG_S1=${AWG_S1}
export AWG_S2=${AWG_S2}
export AWG_S3=${AWG_S3}
export AWG_S4=${AWG_S4}
export AWG_H1='${AWG_H1}'
export AWG_H2='${AWG_H2}'
export AWG_H3='${AWG_H3}'
export AWG_H4='${AWG_H4}'
export AWG_I1='${AWG_I1}'
export AWG_I1_MODE='${AWG_I1_MODE:-random}'
export AWG_I2='${AWG_I2:-}'
export AWG_I3='${AWG_I3:-}'
export AWG_I4='${AWG_I4:-}'
export AWG_I5='${AWG_I5:-}'
export AWG_PRESET='${AWG_PRESET:-default}'
export NO_TWEAKS=${NO_TWEAKS}
export KEEP_PACKAGES=${KEEP_PACKAGES:-1}
export NO_CPS=${NO_CPS}
export AWG_APPLY_MODE='${AWG_APPLY_MODE:-syncconf}'
# Multi-hop (cascade)
export AWG_ROLE='${AWG_ROLE:-single}'
export AWG_UPSTREAM_IFACE='${AWG_UPSTREAM_IFACE:-awg1}'
export AWG_UPSTREAM_TABLE=${AWG_UPSTREAM_TABLE:-123}
export AWG_UPSTREAM_FWMARK='${AWG_UPSTREAM_FWMARK:-0xca6d}'
export AWG_UPSTREAM_PRIORITY=${AWG_UPSTREAM_PRIORITY:-456}
# WARP egress (Cloudflare)
export AWG_EGRESS='${AWG_EGRESS:-direct}'
export AWG_WARP_IFACE='${AWG_WARP_IFACE:-wgcf}'
export AWG_WARP_TABLE=${AWG_WARP_TABLE:-2408}
export AWG_WARP_PRIORITY=${AWG_WARP_PRIORITY:-789}
export AWG_WARP_BYPASS='${AWG_WARP_BYPASS:-none}'
# AmneziaDNS
export AWG_AMNEZIA_DNS='${AWG_AMNEZIA_DNS:-off}'
# IPv6 dual-stack tunnel (upstream v5.15.0)
export ALLOW_IPV6_TUNNEL=${ALLOW_IPV6_TUNNEL:-0}
export IPV6_SUBNET='${IPV6_SUBNET}'
export SERVER_HAS_NATIVE_IPV6=${SERVER_HAS_NATIVE_IPV6:-0}
EOF
    # The pending delete of the old port's UFW rule must survive a reboot:
    # step 4 runs in a different process after 1-2 reboots, a process variable
    # does not live that long (PR #176). Post-commit cleanup removes the key
    # only after an exact-owned UFW delete succeeds.
    if [[ "$PREV_AWG_PORT" =~ ^[0-9]+$ ]]; then
        echo "export PREV_AWG_PORT=${PREV_AWG_PORT}" >> "$temp_conf" \
            || die "Error writing PREV_AWG_PORT to $temp_conf"
    fi
    if ! mv "$temp_conf" "$CONFIG_FILE"; then
        rm -f "$temp_conf"
        die "Error saving $CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE" || log_warn "chmod $CONFIG_FILE error"
    log "Settings saved."
    export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS AWG_ENDPOINT
    log "Port: ${AWG_PORT}/udp"
    log "Subnet: ${AWG_TUNNEL_SUBNET}"
    log "IPv6 disable: $DISABLE_IPV6"
    log "AllowedIPs mode: $ALLOWED_IPS_MODE"
    log "Client isolation: $( [[ "${CLIENT_ISOLATION:-1}" -eq 1 ]] && echo enabled || echo disabled )"

    log "Server name: ${AWG_SERVER_NAME}"
    # Changing the routing mode is a client-config operation: new clients get
    # the new list, but for existing ones regen deliberately preserves
    # AllowedIPs (per-client modify customizations). Hint the explicit way to
    # apply the new mode to everyone (Issue #170).
    if [[ "$config_exists" -eq 1 && "$CLI_ROUTING_MODE" != "default" ]]; then
        log_warn "Routing mode changed. Existing client configs keep their old AllowedIPs."
        log_warn "Apply the new mode to all clients: sudo bash $MANAGE_SCRIPT_PATH regen --reset-routes"
    fi
    # Isolation change - the same operation on client configs as a routing
    # mode change: new clients get the new list, existing ones only via
    # regen --reset-routes (issue #178).
    if [[ "$config_exists" -eq 1 \
          && "$_cfg_client_isolation" != "$CLIENT_ISOLATION" ]]; then
        log_warn "Client isolation mode changed. Existing client configs keep their old AllowedIPs."
        log_warn "Apply the new mode to all clients: sudo bash $MANAGE_SCRIPT_PATH regen --reset-routes"
    fi
    # Port change: step 6 skips clients that already exist, their Endpoint
    # keeps the old port and they silently stop connecting. Hint the explicit
    # reissue - mirrors the routing-mode change warning (#170).
    if [[ "$config_exists" -eq 1 && -n "$PREV_AWG_PORT" ]]; then
        log_warn "Port changed (${PREV_AWG_PORT} -> ${AWG_PORT}). Existing client configs keep the old port in Endpoint and will lose connectivity."
        log_warn "Reissue all clients: sudo bash $MANAGE_SCRIPT_PATH regen"
    fi
    # Server-name change (D#180): affects only the vpn:// URI; existing
    # .vpnuri files keep the old name until reissued.
    if [[ "$config_exists" -eq 1 && "$_cfg_server_name" != "$AWG_SERVER_NAME" ]]; then
        log_warn "Server name changed ('${_cfg_server_name}' -> '${AWG_SERVER_NAME}'). Existing vpn:// links keep the old name."
        log_warn "Reissue with the new name: sudo bash $MANAGE_SCRIPT_PATH regen"
    fi

    # Loading state
    if [[ -f "$STATE_FILE" ]]; then
        current_step=$(cat "$STATE_FILE")
        if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then
            log_warn "$STATE_FILE corrupted."
            current_step=1
            update_state 1
        else
            log "Resuming from step $current_step."
        fi
    else
        current_step=1
        log "Starting from step 1."
        update_state 1
    fi

    # Stale state (an interrupted step 7 leaves setup_state=7/99) + CLI flags
    # affecting the firewall/configs: without the rollback the loop would skip
    # steps 4-6, the new values would live only in awgsetup_cfg.init while
    # awg0.conf, client configs and UFW rules silently kept the old ones
    # (Issue #175). Roll back to step 4: firewall (port) + config regen (step 6).
    if (( current_step > 4 )) && { [[ -n "$CLI_PORT" ]] || [[ -n "$CLI_SUBNET" ]] \
        || [[ -n "$CLI_SSH_PORT" ]] || [[ "$CLI_ROUTING_MODE" != "default" ]] \
        || [[ -n "$CLI_ENDPOINT" ]] || [[ "$CLI_DISABLE_IPV6" != "default" ]] \
        || [[ "${CLI_ALLOW_IPV6_TUNNEL:-default}" != "default" ]] || [[ -n "${CLI_PRESET:-}" ]] \
        || [[ -n "${CLI_JC:-}" ]] || [[ -n "${CLI_JMIN:-}" ]] || [[ -n "${CLI_JMAX:-}" ]] \
        || [[ "${CLI_ISOLATION:-default}" != "default" ]] \
        || [[ "${CLI_NO_CPS:-0}" -eq 1 ]] || [[ -n "${CLI_I1_MODE:-}" ]] \
        || [[ -n "${CLI_ROLE:-}" ]] || [[ -n "${CLI_UPSTREAM_CONF:-}" ]] \
        || [[ -n "${CLI_UPSTREAM_IFACE:-}" ]] || [[ -n "${CLI_UPSTREAM_TABLE:-}" ]] \
        || [[ -n "${CLI_UPSTREAM_FWMARK:-}" ]] || [[ -n "${CLI_EGRESS:-}" ]] \
        || [[ -n "${CLI_WARP_IFACE:-}" ]] || [[ -n "${CLI_WARP_TABLE:-}" ]] || [[ -n "${CLI_WARP_PRIORITY:-}" ]] \
        || [[ -n "${CLI_WARP_BYPASS:-}" ]] || [[ -n "${CLI_AMNEZIA_DNS:-}" ]]; }; then
        log_warn "Unfinished install (step $current_step) + configuration CLI flags: rolling back to step 4 so the firewall and configs are regenerated with the new values."
        current_step=4
        update_state 4
    fi
    _INSTALL_INITIAL_STEP="$current_step"
    log "Step 0 completed."
}

# ==============================================================================
# STEP 1: System update, cleanup, and optimization
# ==============================================================================

step1_update_and_optimize() {
    update_state 1
    log "### STEP 1: System update, cleanup, and optimization ###"

    # First-boot dpkg-lock resilience: unattended-upgrades and apt-daily often
    # hold the lock for several minutes (issue #150 - apt full-upgrade used to
    # fail immediately). DPkg::Lock::Timeout makes apt wait for the lock to be
    # released instead of erroring out.
    mkdir -p /etc/apt/apt.conf.d
    printf 'DPkg::Lock::Timeout "300";\n' > /etc/apt/apt.conf.d/99-amneziawg-lock-timeout \
        || log_warn "Failed to write apt lock-timeout (issue #150 mitigation)."

    # Clean unnecessary components (BEFORE update to save bandwidth/time)
    if [[ "$NO_TWEAKS" -eq 1 ]]; then
        log "Skipping system cleanup (--no-tweaks)."
    elif [[ "$KEEP_PACKAGES" != "0" ]]; then
        # Not a strict zero means either an explicit refusal or an unknown decision (empty
        # or mangled value from a hand-edited config). Irreversible removal happens only on
        # recorded consent; everything else is treated as "leave it alone".
        log "Skipping the system cleanup: the packages are kept."
        [[ -z "$KEEP_PACKAGES" ]]             && log_warn "No consent for removing system packages is recorded - removing nothing."
    else
        cleanup_system
    fi


    log "Updating package lists..."
    apt_update_tolerant || die "apt update error."
    # Cache is fresh: install_packages below must not rerun apt update
    # (sources do not change in step 1).
    _APT_UPDATED=1

    log "Unlocking dpkg..."
    if ! apt-get check &>/dev/null; then
        log_warn "dpkg locked or corrupted, fixing..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."
    fi

    # The meta-packages that udev, initramfs-tools and the network stack hang
    # from may have been orphaned: the cleanup above does that, but they can
    # equally arrive orphaned with the image itself. So this block runs
    # UNCONDITIONALLY, --no-tweaks and --keep-packages included, when no cleanup
    # happened at all. Mark such packages manual again. The upgrade below can no
    # longer drop them (the command was changed over Issue #223: apt-get
    # upgrade has no such right), but the "no longer required" status stays a
    # trap for later: any subsequent apt operation is free to act on it. Ours
    # included - install_packages below calls apt install without --no-remove -
    # and so is any autoremove the user runs afterwards.
    # Manual rather than hold on purpose: a hold would block the upgrade, and
    # upgrading them is exactly what we want; manual only clears the status.
    # ⚠️ The marking guarantees nothing: apt may drop a manual package too while
    # resolving dependencies. The guarantee is the _verify_boot_critical check
    # before the reboot.
    #
    # This block sits AFTER the dpkg repair above, and that is not cosmetic: the
    # snapshot is built by asking dpkg. A locked database still answers fine, but
    # an unreachable or damaged one answers empty for everything at once, and the
    # protection would then switch itself off silently along with the
    # post-upgrade check, on exactly the machines where the defect bites. The
    # self-test below catches that case too.
    _dpkg_usable || die "dpkg does not answer, and without it there is no way to tell whether udev and initramfs-tools survive the upgrade (Issue #223). Run: dpkg --configure -a; apt-get check - then start the installer again."
    # Self-test of the predicate. _dpkg_usable only answers for dpkg, while the
    # predicate also leans on awk: a broken awk would return an empty status,
    # that is "absent" for everything at once, and the guard would switch itself
    # off in silence.
    _pkg_present dpkg || die "Could not determine package state (dpkg-query or awk do not behave as expected). Without it there is no way to make sure the upgrade will not take udev away (Issue #223)."
    local critical_before
    critical_before="$(_boot_critical_snapshot)"
    if [[ -n "$critical_before" ]]; then
        log "Protected from removal: $(printf '%s' "$critical_before" | tr '\n' ' ')"
        # udev is present on virtually every Ubuntu and Debian server. Its
        # absence means not "nothing to protect" but that the machine may
        # already be damaged, by an interrupted earlier run for instance.
        _pkg_installed_ok udev \
            || log_warn "udev is not installed or not configured. That is abnormal for Ubuntu and Debian: check dpkg-query -W udev, the server may fail to boot."
        # Unquoted on purpose: the list arrives as newline-separated names and
        # splitting it into arguments is exactly what is wanted here.
        apt-mark manual $critical_before >/dev/null 2>&1 \
            || log_warn "Failed to restore the manual mark on: $(printf '%s' "$critical_before" | tr '\n' ' ') - they stay flagged \"no longer required\", the check before the reboot will catch that."
    else
        log_warn "Not a single boot-critical package was found installed. That is unusual for Ubuntu and Debian; check: dpkg-query -W udev"
    fi
    log "Updating system..."
    # Deliberately upgrade --with-new-pkgs rather than full-upgrade. The
    # difference is not cosmetic: full-upgrade is by definition allowed to
    # REMOVE installed packages to resolve dependencies, and in Issue #223 it
    # used that right - it took udev away and the server stopped booting.
    # upgrade has no such right at all: a package that cannot be upgraded
    # without removing a neighbour is simply left at its current version.
    # --with-new-pkgs keeps the only reason full-upgrade was needed here: a new
    # kernel arrives as a package with a NEW name
    # (linux-image-6.8.0-NNN-generic), and a plain upgrade refuses to install
    # new names.
    # The trade is deliberate: a VPN server does not need systemd to be the
    # freshest, it needs the machine to boot. The pre-reboot verification below
    # stays as the second line of defence.
    if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --with-new-pkgs; then
        local _lock_holder
        _lock_holder="$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | tr -s ' ' || true)"
        if [[ -n "$_lock_holder" ]]; then
            log_warn "dpkg-lock is held by:${_lock_holder} (usually first-boot unattended-upgrades)."
        fi
        log_warn "Update failed, fixing dpkg and retrying..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --with-new-pkgs || _die_upgrade_failed
    fi
    _warn_kept_back
    log "System updated."


    install_packages curl wget gpg sudo ethtool

    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        # System optimization
        optimize_system
        # Sysctl configuration
        setup_advanced_sysctl
    else
        log "Skipping optimization and hardening (--no-tweaks)."
        setup_minimal_sysctl
    fi

    # Checked as the very last action of the step: nothing capable of
    # removing a package runs after this line.
    _verify_boot_critical "$critical_before"

    log "Step 1 completed successfully."
    request_reboot 2
}

# ==============================================================================
# ARM prebuilt support
# ==============================================================================

# _try_install_prebuilt_arm — download and install a prebuilt amneziawg .deb
# for the current ARM kernel from the arm-packages GitHub release.
#
# Returns 0 if a matching prebuilt was installed successfully.
# Returns 1 if no match was found or installation failed (caller falls back to DKMS).
#
# Prebuilt packages are built by .github/workflows/arm-build.yml and published
# to the arm-packages release tag. The filename encodes both the target ID and
# the exact kernel version: amneziawg-kmod-<target-id>_<kernel-version>_<arch>.deb
#
# Kernel version matching is exact — the module vermagic must match uname -r.
# DKMS is the preferred path for kernels that haven't been pre-built yet.
_try_install_prebuilt_arm() {
    local kernel arch target_id asset_name asset_url tmpfile tmpsha expected_sha actual_sha
    kernel="$(uname -r)"
    arch="$(dpkg --print-architecture)"

    # Map kernel string to a build target ID
    if [[ "$kernel" == *+rpt-rpi-2712* ]]; then
        target_id="rpi5-bookworm-arm64"
    elif [[ "$kernel" == *+rpt* && "$arch" == "arm64" ]]; then
        target_id="rpi-bookworm-arm64"
    elif [[ "$kernel" == *+rpt* && "$arch" == "armhf" ]]; then
        target_id="rpi-bookworm-armhf"
    elif [[ "$kernel" == *-generic* && "${OS_VERSION:-}" == "24.04" ]]; then
        target_id="ubuntu-2404-arm64"
    elif [[ "$kernel" == *-generic* && "${OS_VERSION:-}" == "25.10" ]]; then
        target_id="ubuntu-2510-arm64"
    elif [[ "$kernel" == *-arm64* && "${OS_ID:-}" == "debian" && "${OS_VERSION:-}" == "13" ]]; then
        target_id="debian-trixie-arm64"
    elif [[ "$kernel" == *-arm64* && "${OS_ID:-}" == "debian" ]]; then
        target_id="debian-bookworm-arm64"
    else
        log "No prebuilt target for kernel $kernel ($arch)"
        return 1
    fi

    # Asset filename encodes the exact kernel version
    asset_name="amneziawg-kmod-${target_id}_${kernel}_${arch}.deb"
    asset_url="https://github.com/bivlked/amneziawg-installer/releases/download/arm-packages/${asset_name}"

    log "Trying prebuilt: $asset_name"
    tmpfile="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb)"
    tmpsha="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb.sha256)"

    # Download SHA256 checksum first
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpsha" "${asset_url}.sha256" 2>/dev/null; then
        log "Prebuilt not available for $kernel — using DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi

    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpfile" "$asset_url" 2>/dev/null; then
        # Verify integrity before installing a kernel module
        expected_sha="$(cat "$tmpsha")"
        actual_sha="$(sha256sum "$tmpfile" | awk '{print $1}')"
        rm -f "$tmpsha"
        if [[ "$expected_sha" != "$actual_sha" ]]; then
            log_warn "Prebuilt SHA256 mismatch — discarding download"
            rm -f "$tmpfile"
            return 1
        fi

        log "Downloaded prebuilt (SHA256 OK), installing..."
        if dpkg -i "$tmpfile" 2>/dev/null; then
            rm -f "$tmpfile"
            log "Prebuilt installed: $asset_name"
            return 0
        else
            log_warn "Prebuilt install failed (vermagic mismatch or corrupt package)"
            rm -f "$tmpfile"
            return 1
        fi
    else
        log "Prebuilt not available for $kernel — using DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi
}

# H0 (AWG 3.0, 31 jul 2026): on kernels < 6.7 the current PPA module is AmneziaWG
# 3.0, and we deliberately keep it out of there (why exactly - see
# _kernel_supports_awg3). We install the last pinned 2.0 module (the 1.0.x line)
# from source via DKMS:
#   1. git clone the pinned tag --depth=1;
#   2. VERIFY the commit against AWG2_PIN_COMMIT (integrity: an immutable commit is
#      more robust than the GitHub auto-tarball SHA, which changes on recompression);
#   3. the upstream `make dkms-install` mechanism (lays it into /usr/src/amneziawg-1.0.0);
#   4. dkms add/build/install for the current kernel;
#   5. a modprobe check (built != loadable: Secure Boot may block it).
# The source dkms.conf carries AUTOINSTALL=yes, so our amneziawg-ensure-module helper
# (apt hook + systemd) rebuilds the pinned module on a kernel upgrade by itself - no
# separate maintenance code is needed. Returns: 0 success, 1 failure (logged to ERROR).
_install_pinned_awg2_module() {
    local repo="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
    local kver work got_commit
    local dkms_ver="1.0.0"   # WIREGUARD_VERSION in the upstream Makefile (name of /usr/src/amneziawg-<ver>)
    kver="$(uname -r)"

    if ! command -v git >/dev/null 2>&1; then
        log_error "git is not installed - cannot fetch the pinned module source."
        return 1
    fi

    work="$(mktemp -d /tmp/awg2-pin-XXXXXX)" || { log_error "mktemp -d failed."; return 1; }

    log "Cloning the pinned AmneziaWG 2.0 source ($AWG2_PIN_TAG)..."
    if ! git clone --depth=1 --branch "$AWG2_PIN_TAG" "$repo" "$work/src" >/dev/null 2>&1; then
        log_error "Failed to clone $repo (tag $AWG2_PIN_TAG). Check access to github.com."
        rm -rf "$work"; return 1
    fi

    got_commit="$(git -C "$work/src" rev-parse HEAD 2>/dev/null || echo "")"
    if [[ "$got_commit" != "$AWG2_PIN_COMMIT" ]]; then
        log_error "Pin check failed: tag $AWG2_PIN_TAG -> commit '${got_commit:-<empty>}',"
        log_error "expected $AWG2_PIN_COMMIT. Refusing (the tag may have been moved/tampered with)."
        rm -rf "$work"; return 1
    fi
    log "Pinned commit confirmed: $got_commit"

    # Lay out the DKMS source via the upstream mechanism (the Makefile is in src/).
    # Save make output to a log: otherwise the real cause of a failure (environment /
    # coreutils) is invisible - unlike the dkms build path, no make.log is created here.
    local _mklog="/var/log/amneziawg-pin-dkms-install.log"
    if ! make -C "$work/src/src" dkms-install PREFIX=/usr >"$_mklog" 2>&1; then
        log_error "make dkms-install failed. Details: $_mklog"
        rm -rf "$work"; return 1
    fi
    rm -rf "$work"

    if [[ ! -f "/usr/src/amneziawg-${dkms_ver}/dkms.conf" ]]; then
        log_error "/usr/src/amneziawg-${dkms_ver}/dkms.conf did not appear after dkms-install."
        return 1
    fi

    # add is idempotent: on a re-run it is already added -> not fatal.
    dkms add -m amneziawg -v "$dkms_ver" >/dev/null 2>&1 || true
    # Idempotency (the installer is a resumable state machine): dkms build errors
    # with "already built" for a kernel already done -> build ONLY if there is no
    # build for this kernel yet. install --force below is idempotent by itself.
    if dkms status -m amneziawg -v "$dkms_ver" -k "$kver" 2>/dev/null | grep -qE ': (built|installed)'; then
        log "The pinned 2.0 module is already built for kernel $kver - skipping dkms build."
    else
        log "Building the pinned 2.0 module via DKMS (kernel $kver)..."
        if ! dkms build -m amneziawg -v "$dkms_ver" -k "$kver" >/dev/null 2>&1; then
            log_error "DKMS build of the pinned 2.0 module failed. See /var/lib/dkms/amneziawg/${dkms_ver}/${kver}/*/log/make.log"
            return 1
        fi
    fi
    if ! dkms install -m amneziawg -v "$dkms_ver" -k "$kver" --force >/dev/null 2>&1; then
        log_error "DKMS install of the pinned 2.0 module failed."
        return 1
    fi

    # Built != loadable: with Secure Boot enabled an unsigned module will not load.
    if ! modprobe amneziawg 2>/dev/null; then
        log_error "The module was built but modprobe amneziawg did not load it."
        log_error "The likely cause is Secure Boot: an unsigned DKMS module is blocked."
        log_error "Disable Secure Boot in the VPS BIOS/UEFI or enroll a MOK key."
        return 1
    fi
    log "The pinned AmneziaWG 2.0 module is built and loaded (DKMS $dkms_ver, kernel $kver)."
    return 0
}

# ==============================================================================
# STEP 2: Installing AmneziaWG and dependencies
# ==============================================================================

step2_install_amnezia() {
    update_state 2

    # Guard: make sure the user actually rebooted before step 2.
    # If boot_id matches the one saved in request_reboot 2 — the reboot
    # did not happen (e.g. user re-ran the script by mistake). The step 1
    # upgrade may have staged a new kernel on disk, but the running
    # kernel is still the old one → DKMS would build the module against
    # the old kernel and modprobe would fail after the next reboot.
    local boot_id_file="$AWG_DIR/.boot_id_before_step2"
    if [[ -f "$boot_id_file" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        local saved_boot_id current_boot_id
        saved_boot_id=$(< "$boot_id_file")
        current_boot_id=$(< /proc/sys/kernel/random/boot_id)
        if [[ -n "$saved_boot_id" ]] && [[ "$saved_boot_id" == "$current_boot_id" ]]; then
            die "Reboot expected before step 2 (kernel upgrade is only activated after reboot). Run: sudo reboot — then re-run the script."
        fi
        log "Reboot confirmed (boot_id changed) — continuing with step 2"
        rm -f "$boot_id_file" 2>/dev/null || true
    fi

    log "### STEP 2: Installing AmneziaWG and dependencies ###"
    _APT_UPDATED=0  # Reset: new sources will be added in this step

    # --ppa-amnezia-tolerant is REQUIRED already here: if a PPA file with a
    # broken suite is left on disk (404 Release; e.g. questing from an older
    # version or after an in-place upgrade), a strict update died BEFORE the
    # repair blocks below ever ran, so the repair never fired (live repro on
    # Debian 12, v5.16.0 cycle). Base repository errors remain fail-closed;
    # PPA errors are handled by the repair + post-PPA update +
    # apt_wait_for_ppa_package below.
    apt_update_tolerant --ppa-amnezia-tolerant || die "apt update error."

    # PPA Amnezia (without software-properties-common)
    log "Adding Amnezia PPA..."

    # Determine codename for PPA
    # On Debian, map to nearest Ubuntu codename since PPA is Launchpad (Ubuntu)
    # Debian 12 (bookworm) → focal, Debian 13 (trixie) → noble
    local codename ppa_codename
    codename="${OS_CODENAME:-$(lsb_release -sc 2>/dev/null || echo "noble")}"
    case "${OS_ID:-ubuntu}" in
        debian)
            case "$codename" in
                bookworm) ppa_codename="focal" ;;
                trixie)   ppa_codename="noble" ;;
                *)        ppa_codename="noble" ;;
            esac
            log "Debian ($codename) → PPA codename: $ppa_codename"
            ;;
        *)
            ppa_codename="$codename"
            # For Ubuntu non-LTS (questing/plucky/oracular/...) Amnezia PPA does
            # not publish packages — dists/<codename>/Release returns 404.
            # Pre-check via HEAD and fall back to noble (LTS): the noble build
            # gets DKMS-compiled against the running kernel.
            # Upstream: amnezia-vpn/amneziawg-linux-kernel-module#118
            case "$ppa_codename" in
                noble|jammy|focal)
                    # Known LTS — skip pre-check (PPA is reliably published)
                    ;;
                *)
                    log "Checking Amnezia PPA availability for Ubuntu '${ppa_codename}'..."
                    if ! curl -fsI --max-time 15 --retry 2 --retry-delay 5 \
                        "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/${ppa_codename}/Release" \
                        >/dev/null 2>&1; then
                        log_warn "Amnezia PPA does not publish packages for Ubuntu '${ppa_codename}' (HTTP 404 or host unreachable)."
                        log_warn "Falling back to 'noble' — DKMS will build the module against the running kernel."
                        log_warn "Context: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/118"
                        ppa_codename="noble"
                    else
                        log "Amnezia PPA is available for '${ppa_codename}'."
                    fi
                    ;;
            esac
            ;;
    esac

    local keyring_dir="/etc/apt/keyrings"
    local keyring_file="${keyring_dir}/amnezia-ppa.gpg"
    local ppa_sources="/etc/apt/sources.list.d/amnezia-ppa.sources"
    local ppa_list="/etc/apt/sources.list.d/amnezia-ppa.list"
    # Check for legacy files (from add-apt-repository of previous versions)
    local legacy_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.list"
    local legacy_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.sources"
    # Re-run on a server where a previous run (≤ v5.12.1) wrote a broken
    # .sources file with Suites=questing/plucky/etc.: if the existing suite
    # doesn't match the target ppa_codename, remove the file so it gets
    # recreated below with the correct suite. Same check for legacy
    # .sources (add-apt-repository format).
    # If the file exists but `Suites:` can't be parsed — treat as corrupt
    # and recreate, otherwise the broken file would slip through as
    # "PPA already added".
    local existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    if [[ -f "$ppa_sources" && ( -z "$existing_suite" || "$existing_suite" != "$ppa_codename" ) ]]; then
        if [[ -z "$existing_suite" ]]; then
            log_warn "$ppa_sources exists but no Suites: line found — recreating."
        else
            log_warn "Existing PPA suite='${existing_suite}', target='${ppa_codename}' — recreating $ppa_sources."
        fi
        rm -f "$ppa_sources" "$ppa_list"
    fi
    local legacy_suite=""
    if [[ -f "$legacy_sources" ]]; then
        legacy_suite=$(awk '/^Suites:/{print $2; exit}' "$legacy_sources" 2>/dev/null)
    fi
    if [[ -f "$legacy_sources" && ( -z "$legacy_suite" || "$legacy_suite" != "$ppa_codename" ) ]]; then
        log_warn "Legacy PPA $legacy_sources (suite='${legacy_suite:-<empty>}') does not match target '${ppa_codename}' — removing."
        rm -f "$legacy_sources" "$legacy_list"
    fi
    # Same repair for the traditional .list (Debian 12): the suite is the token
    # after the URL in a 'deb [opts] URL <suite> main' line. Without this check
    # a file with an old/foreign suite (e.g. after an in-place upgrade
    # bookworm->trixie) would slip through below as "PPA already added" and apt
    # would keep pulling the wrong suite.
    local list_suite=""
    if [[ -f "$ppa_list" ]]; then
        list_suite=$(awk '/^deb([[:space:]]|$)/ {
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^https?:/) { print $(i+1); exit }
            }
        }' "$ppa_list" 2>/dev/null)
        if [[ -z "$list_suite" || "$list_suite" != "$ppa_codename" ]]; then
            log_warn "Existing $ppa_list (suite='${list_suite:-<empty>}') does not match target '${ppa_codename}' - recreating."
            rm -f "$ppa_list"
        fi
    fi
    if [[ -f "$legacy_list" ]] || [[ -f "$legacy_sources" ]]; then
        log "PPA already added (legacy format)."
    elif [[ -f "$ppa_sources" ]] || [[ -f "$ppa_list" ]]; then
        log "PPA already added."
    else
        mkdir -p "$keyring_dir"
        log "Importing Amnezia PPA GPG key..."
        # Atomic: pipe into temp, then mv — a half-written keyring never
        # lives on the target path, even if curl/gpg die mid-way.
        local _kf_tmp
        _kf_tmp=$(mktemp -p "$keyring_dir" ".amnezia-ppa.gpg.tmp.XXXXXX") \
            || die "Failed to create temp file for GPG key."
        # --batch --no-tty --yes: gpg must not open /dev/tty (non-interactive
        # SSH, cloud-init, Ansible, etc.) and must not abort with "File exists"
        # when overwriting the mktemp-created tmp file. Without --yes gpg in
        # batch mode refuses to write into the pre-existing empty tmp file.
        # Request by the FULL 40-character fingerprint, not the short ID:
        # short 32-bit IDs have preimage collisions (evil32), and
        # keyserver.ubuntu.com accepts uploads of arbitrary keys. A swapped
        # key would not give RCE (package signatures would not match), but it
        # would break the install with a cryptic apt error.
        local _ppa_key_fpr="75C9DD72C799870E310542E24166F2C257290828"
        if ! curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${_ppa_key_fpr}" \
             | gpg --batch --no-tty --yes --dearmor -o "$_kf_tmp"; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Amnezia PPA GPG key import error."
        fi
        # Verify the downloaded key fingerprint against the expected one (pin).
        local _got_fpr
        _got_fpr=$(gpg --batch --no-tty --show-keys --with-colons "$_kf_tmp" 2>/dev/null \
            | awk -F: '/^fpr:/{print $10; exit}')
        if [[ "$_got_fpr" != "$_ppa_key_fpr" ]]; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Amnezia PPA GPG key failed the fingerprint check (got: '${_got_fpr:-<empty>}')."
        fi
        chmod 644 "$_kf_tmp" || { rm -f "$_kf_tmp" 2>/dev/null; die "chmod GPG key error."; }
        mv -f "$_kf_tmp" "$keyring_file" \
            || { rm -f "$_kf_tmp" 2>/dev/null; die "Failed to move GPG key to target path."; }

        # Debian 12 uses traditional .list format, Debian 13+ and Ubuntu 24.04+ use DEB822 .sources
        if [[ "${OS_ID:-ubuntu}" == "debian" && "${OS_VERSION}" == "12" ]]; then
            log "Debian 12: using traditional .list format"
            echo "deb [signed-by=${keyring_file}] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main" \
                > "$ppa_list" || die "Failed to create $ppa_list"
            chmod 644 "$ppa_list"
        else
            cat > "$ppa_sources" <<PPASRC || die "PPA sources creation error."
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${ppa_codename}
Components: main
Signed-By: ${keyring_file}
PPASRC
            chmod 644 "$ppa_sources"
        fi
        log "PPA added."
    fi
    # apt-get update + error classification:
    #   - Errors only on the Amnezia PPA → continue, apt_wait_for_ppa_package
    #     below will retry (issue #68: ppa.launchpadcontent.net briefly down).
    #   - Any other non-source error (DNS / GPG mismatch / dpkg lock on the
    #     base mirror) → fail fast. Continuing on a stale apt-cache is unsafe —
    #     the next apt-get install would fail with a less actionable error
    #     (PR #69 review finding).
    if ! apt_update_tolerant --ppa-amnezia-tolerant; then
        log_error "apt-get update failed with a hard error — not a PPA outage (issue #68)."
        log_error "Check: DNS, access to archive.ubuntu.com / deb.debian.org,"
        log_error "integrity of keys in /etc/apt/keyrings, dpkg lock contention."
        die "apt update returned an error (rc!=0, not the Amnezia PPA)."
    fi
    # PPA added, cache refreshed: sources do not change further in step 2, so
    # install_packages must not repeat apt update (on slow mirrors every run
    # is 10-60 seconds).
    _APT_UPDATED=1
    # apt-get update is tolerant to an unreachable InRelease (rc=0 even when
    # the PPA is down). So we check that amneziawg-dkms actually appears in
    # apt-cache, with three attempts and 30s/60s backoff (~1.5 min total).
    # A brief ppa.launchpadcontent.net outage (issue #68) must not break
    # the install.
    if ! apt_wait_for_ppa_package amneziawg-dkms 3 30; then
        log_error "Package amneziawg-dkms did not appear in apt-cache after 3 attempts."
        log_error "ppa.launchpadcontent.net appears to be down — this is a"
        log_error "Launchpad infrastructure outage, not a script bug."
        log_error "Wait 10–15 minutes and re-run the script with the same args."
        log_error "Details: https://github.com/bivlked/amneziawg-installer/issues/68"
        die "Amnezia PPA is temporarily unavailable."
    fi

    # AmneziaWG + qrencode packages (NO Python!)
    log "Installing AmneziaWG packages..."

    # H0 (AWG 3.0, 31 jul 2026): decide the pinned 2.0 module path BEFORE installing
    # any package - the hold must be in place before even the ARM prebuilt path, where
    # install_packages installs amneziawg-tools whose Recommends would otherwise pull
    # in the 3.0 module behind the gate. On kernels < 6.7 the PPA module is AmneziaWG
    # 3.0; we do not install it here (deliberately, see _kernel_supports_awg3) and
    # build the pinned 2.0 from source instead; only tools come from the PPA
    # (version-aware, they do work with 2.0 - verified).
    local use_pinned_awg2=0
    if ! _kernel_supports_awg3; then
        use_pinned_awg2=1
        log "Kernel $(uname -r) is older than 6.7 - installing the tested AmneziaWG 2.0 module here, not 3.0 from the PPA."
        log "Activated the pinned AmneziaWG 2.0 module path from source ($AWG2_PIN_TAG)."
        # Re-entry: if a prior run / the stock installer already installed (or left
        # half-configured) the 3.0 package - remove it and its source, otherwise its
        # failing postinst and /usr/src/amneziawg-* ownership conflict with the build.
        if dpkg -l amneziawg-dkms 2>/dev/null | grep -qE '^(ii|iU|iF|iH|rc)'; then
            log "Found a previously installed amneziawg-dkms (AmneziaWG 3.0) - removing it before the pinned build."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg >/dev/null 2>&1 \
                || dpkg --purge --force-all amneziawg-dkms amneziawg >/dev/null 2>&1 \
                || log_warn "Could not fully remove the previously installed amneziawg-dkms - the install below may fail."
            command -v dkms >/dev/null 2>&1 && dkms remove -m amneziawg -v 1.0.0 --all >/dev/null 2>&1 || true
            rm -rf /var/lib/dkms/amneziawg* /usr/src/amneziawg-* 2>/dev/null || true
        fi
        # ⚠️ Hold BEFORE any install: amneziawg-tools RECOMMENDS amneziawg-dkms, apt
        # installs recommends by default -> without a hold, installing tools (incl. on
        # the ARM path) would drag in the 3.0 dkms, leaving TWO DKMS trees under the
        # same module name amneziawg - the pinned 2.0 one and the packaged 3.0 one.
        # This is a safety mechanism, so its failure is fatal (we verify the hold took
        # effect).
        apt-mark hold amneziawg-dkms amneziawg >/dev/null 2>&1 || true
        # We verify amneziawg-dkms specifically - it is the load-bearing package: it
        # is what amneziawg-tools Recommends and what carries the 3.0 module. The
        # metapackage amneziawg need not be held (its Depends: amneziawg-dkms is held
        # anyway), so we do not verify it separately.
        if ! apt-mark showhold 2>/dev/null | grep -qx "amneziawg-dkms"; then
            die "Failed to hold amneziawg-dkms. Without it, installing amneziawg-tools would pull the AmneziaWG 3.0 module from the PPA, bypassing the chosen path. Aborted (check for an apt/dpkg lock)."
        fi
    else
        # Kernel >= 6.7: the normal path installs amneziawg-dkms from the PPA. Clear a
        # possible hold left by an earlier pinned run (else apt install -y aborts on hold).
        apt-mark unhold amneziawg-dkms amneziawg >/dev/null 2>&1 || true
    fi

    # On ARM: try prebuilt .deb first (no build tools or headers required).
    # Falls back to DKMS if no matching prebuilt is available or download fails.
    # ⚠️ On a kernel < 6.7 (use_pinned_awg2=1) using the prebuilt .deb is SAFE: our ARM
    # prebuilts are built from scripts/arm-module-version.txt, pinned to the same 2.0
    # tag (v1.0.20260725) and locked by a test, so it is a KNOWN 2.0 module, not 3.0.
    # ⚠️ That is the ONLY guarantee, and it is enough. The former second argument -
    # "3.0 cannot compile for a kernel < 6.7 anyway, so a 3.0 asset for a target like
    # debian-bookworm-arm64 cannot exist in the release" - is WRONG as of 31 jul 2026
    # (upstream fixed the build, v3.0.20260731-04); do not lean on it. On no match
    # _try_install_prebuilt_arm returns 1 and we fall through to the verified source
    # build below. The hold set above also applies here (keeps tools from pulling the
    # 3.0 dkms via Recommends).
    local arch
    arch="$(uname -m)"
    if [[ "$arch" == "aarch64" || "$arch" == "armv7l" ]]; then
        if _try_install_prebuilt_arm; then
            log "Prebuilt kernel module installed. Installing userspace tools from PPA..."
            # 🔴 The hold is REQUIRED here too, REGARDLESS of the kernel version.
            # Above it is set only on the pinned path (kernel < 6.7), while the
            # >= 6.7 branch does apt-mark unhold - and this ARM block runs AFTER
            # that gate. The prebuilt package is named amneziawg-kmod-<KERNEL_ID>
            # and declares no "Provides: amneziawg-modules", so it does NOT
            # satisfy the alternative in amneziawg-tools' Recommends (live PPA
            # metadata: "amneziawg-modules (>= 0.0.20171001) | amneziawg-dkms
            # (>= ...)"), and amneziawg-modules itself is absent from the PPA.
            # install_packages installs via apt install -y WITH recommends, so
            # without the hold apt would pull amneziawg-dkms from the PPA, and a
            # 3.0 tree in updates/dkms/ would land next to our 2.0 module in
            # extra/. Two trees carrying a module of the SAME name is exactly what
            # the hold exists to prevent. Reachable: the ubuntu-2510-arm64 and
            # debian-trixie-arm64 prebuilt targets ship kernels 6.7+.
            apt-mark hold amneziawg-dkms amneziawg >/dev/null 2>&1 || true
            if ! apt-mark showhold 2>/dev/null | grep -qx "amneziawg-dkms"; then
                die "Failed to put amneziawg-dkms on hold before installing amneziawg-tools. Without it the PPA module would land next to the prebuilt one - two trees named amneziawg. Check the apt/dpkg lock and run the script again: the prebuilt package is already installed, this step will simply repeat."
            fi
            install_packages "amneziawg-tools" "wireguard-tools" "qrencode"
            # POSTCONDITION. The PRECONDITION (the hold is in place) is verified
            # above, but nobody checked the result - in between apt could have
            # installed the package for a reason we did not foresee, or dkms may
            # be left over from an earlier install on this very host. Check the
            # fact rather than the precondition: the fact is what catches a real
            # failure.
            # ⚠️ Deliberately NOT a die: "dkms left over from a previous run" is
            # already a broken state, but aborting the install over it is not
            # something to ship without a run on an ARM bench, and an abort with
            # no path to a fix leaves the person with nothing. Hence a loud
            # warning with the exact command. Tightening this to a die is a
            # separate task.
            if dpkg-query -W -f='${Status}' amneziawg-dkms 2>/dev/null | grep -q "ok installed"; then
                log_warn "WARNING: the amneziawg-dkms package is installed next to the prebuilt module."
                log_warn "  How that ends was measured on a bench rather than guessed: as soon as kernel"
                log_warn "  headers are present, DKMS builds, DISPLACES the prebuilt file from extra/, and"
                log_warn "  after a reboot it is the one that loads - the server silently moves to the"
                log_warn "  other protocol line. The tunnel keeps working, and dpkg still believes the"
                log_warn "  prebuilt package is installed."
                log_warn "  Remove the extra one: sudo apt-mark unhold amneziawg-dkms && sudo apt-get purge -y amneziawg-dkms"
                log_warn "  then sudo apt-mark hold amneziawg-dkms, reinstall the module and reboot."
            fi
            log "Step 2 completed (prebuilt ARM)."
            _boot_critical_guard
            # request_reboot always terminates the process (exit), we never return here.
            request_reboot 3
        fi
        log "No matching prebuilt — falling back to DKMS build."
    fi

    # Packages: on the pinned path (kernel < 6.7) we do NOT install amneziawg-dkms
    # (it would be the 3.0 module); git is added instead to build the pinned 2.0
    # source. The gate, hold and cleanup of a previously installed 3.0 were done
    # above (before the ARM block).
    local packages
    if [[ "$use_pinned_awg2" -eq 1 ]]; then
        packages=("amneziawg-tools" "wireguard-tools" "dkms"
                  "build-essential" "dpkg-dev" "git" "qrencode")
    else
        packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms"
                  "build-essential" "dpkg-dev" "qrencode")
    fi

    # Linux headers: on Debian, exact linux-headers-$(uname -r) may not be available
    local current_headers
    current_headers="linux-headers-$(uname -r)"
    if dpkg -s "$current_headers" &>/dev/null || apt-cache show "$current_headers" &>/dev/null 2>&1; then
        packages+=("$current_headers")
    else
        log_warn "No headers for $(uname -r), installing generic package..."
        local kernel_release
        kernel_release="$(uname -r)"
        if [[ "$kernel_release" == *+rpt* || "$kernel_release" == *-rpi* ]]; then
            # Raspberry Pi Foundation kernel (+rpt suffix) — use RPi meta-package
            # linux-headers-rpi-2712: Pi 5 / Cortex-A76; linux-headers-rpi-v8: Pi 3/4 arm64
            local rpi_headers
            if [[ "$kernel_release" == *2712* ]]; then
                rpi_headers="linux-headers-rpi-2712"
            else
                rpi_headers="linux-headers-rpi-v8"
            fi
            log "Raspberry Pi kernel detected, using $rpi_headers"
            packages+=("$rpi_headers")
        elif [[ "${OS_ID:-ubuntu}" == "debian" ]]; then
            # On Debian: linux-headers-$(dpkg --print-architecture)
            local arch_pkg
            arch_pkg="linux-headers-$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
            packages+=("$arch_pkg")
        else
            packages+=("linux-headers-generic")
        fi
    fi
    # v5.13.0: on 25.10/26.04 after an in-place upgrade from 24.04, the
    # system may still carry kernel headers from 24.04 (6.8.x) compiled with
    # gcc-13. 25.10 ships gcc-15 by default → dkms autoinstall in the
    # amneziawg-dkms postinst fails when building against stale kernels, and
    # dpkg leaves amneziawg* unconfigured. If we detect kernel headers other
    # than the running one, install gcc-13 ahead of time (available in
    # questing/universe and 26.04 archive) so autoinstall succeeds for every
    # kernel.
    local _running_kernel _has_stale=0 _hd _hd_kern
    _running_kernel="$(uname -r)"
    for _hd in /lib/modules/*/build; do
        [[ -e "$_hd" ]] || continue
        _hd_kern="${_hd#/lib/modules/}"
        _hd_kern="${_hd_kern%/build}"
        if [[ "$_hd_kern" != "$_running_kernel" ]]; then
            _has_stale=1
            break
        fi
    done
    if [[ "$_has_stale" -eq 1 ]] && ! command -v gcc-13 >/dev/null 2>&1; then
        if apt-cache madison gcc-13 2>/dev/null | grep -q .; then
            log "Stale kernel headers detected (other than $_running_kernel) — installing gcc-13 for DKMS autoinstall compatibility."
            DEBIAN_FRONTEND=noninteractive apt install -y gcc-13 \
                || log_warn "gcc-13 install failed — DKMS autoinstall may fail on stale kernels."
        else
            log_warn "Stale kernel headers detected, but gcc-13 is not in the repo — DKMS autoinstall may fail."
        fi
    fi
    install_packages "${packages[@]}"

    # H0: pinned path - build the 2.0 module from source INSTEAD of PPA amneziawg-dkms.
    # Headers for the current kernel are already installed above (in packages); the
    # hold was set earlier.
    if [[ "$use_pinned_awg2" -eq 1 ]]; then
        if ! _install_pinned_awg2_module; then
            log_error "Failed to install the pinned AmneziaWG 2.0 module."
            log_error "On kernels older than 6.7 (yours is $(uname -r)) the installer does not take"
            log_error "the module from the PPA but builds it from source, and that step did not go"
            log_error "through. The exact reason is in the lines above; usually it is missing kernel"
            log_error "headers, no free space, a dropped network, or a module that built but will"
            log_error "not load (Secure Boot). Fallback option: deploy the server on Ubuntu"
            log_error "24.04/25.10 or Debian 13, where the module comes as a package from the PPA."
            log_error "See README/INSTALL_VPS for details."
            die "The pinned AmneziaWG 2.0 module was not installed."
        fi
        log "The pinned AmneziaWG 2.0 module is installed; PPA dkms is held (3.0 protection)."
    fi

    # v5.12.0: install a kernel-headers meta-package so apt automatically
    # pulls matching headers on every kernel upgrade. Without the meta only
    # linux-headers-$(uname -r) is installed, which does not track new
    # kernels and the DKMS module fails to rebuild on the next apt upgrade.
    #
    # Detect kernel flavor (Ubuntu cloud images: aws/azure/gcp/oracle/kvm/
    # lowlatency/raspi; Debian cloud-amd64) — a plain linux-headers-generic
    # on an Azure VM does not track the right kernel pipeline. Take the
    # uname -r suffix, try the flavor-specific meta first, fall back to
    # generic / arch.
    local arch_meta kernel_rel
    arch_meta="$(dpkg --print-architecture 2>/dev/null || echo '')"
    kernel_rel="$(uname -r)"
    local -a meta_candidates=()
    if [[ "$kernel_rel" == *+rpt* || "$kernel_rel" == *-rpi* ]]; then
        : # RPi: linux-headers-rpi-{2712,v8} meta is already in packages above.
    elif [[ "${OS_ID:-ubuntu}" == "ubuntu" ]]; then
        # Ubuntu uname -r format: 6.8.0-49-generic / 6.8.0-1009-aws / ...
        local flavor="${kernel_rel##*-}"
        if [[ -n "$flavor" && "$flavor" != "$kernel_rel" ]]; then
            meta_candidates+=("linux-headers-${flavor}")
        fi
        meta_candidates+=("linux-headers-generic")
    elif [[ "${OS_ID:-}" == "debian" && -n "$arch_meta" ]]; then
        # Debian: stock kernel 6.12.85+deb13-amd64, cloud — 6.12.85+deb13-cloud-amd64.
        [[ "$kernel_rel" == *-cloud-* ]] \
            && meta_candidates+=("linux-headers-cloud-${arch_meta}")
        meta_candidates+=("linux-headers-${arch_meta}")
    fi
    local meta meta_installed=0
    for meta in "${meta_candidates[@]}"; do
        if dpkg-query -W -f='${Status}' "$meta" 2>/dev/null \
                | grep -q 'install ok installed'; then
            log "$meta is already installed (auto-tracking kernel upgrades)."
            meta_installed=1
            break
        fi
        log "Installing meta-package $meta..."
        if DEBIAN_FRONTEND=noninteractive apt install -y "$meta" 2>/dev/null; then
            log "$meta installed."
            meta_installed=1
            break
        fi
        log_warn "Failed to install $meta — trying next candidate."
    done
    if [[ ${#meta_candidates[@]} -gt 0 && $meta_installed -eq 0 ]]; then
        log_warn "No kernel-headers meta-package installed — auto-rebuild on kernel upgrade may not work."
    fi

    # v5.12.0: deploy the standalone helper /usr/local/sbin/amneziawg-ensure-module.
    # It is invoked from the apt hook (DPkg::Post-Invoke) and from the Phase 4
    # systemd unit. The helper is self-contained — it does NOT source
    # awg_common.sh — so it keeps working even if /root/awg/ is moved.
    #
    # Deploy uses a staging file in the SAME filesystem as the destination
    # plus a final `mv -f` — guaranteeing atomic replacement (a cross-FS
    # rename is copy+remove, NOT atomic). The staging file starts with a
    # dot so apt and logrotate skip dotfiles when scanning the directory.
    log "Deploying DKMS auto-repair helper..."
    mkdir -p /usr/local/sbin
    local _stage_helper=/usr/local/sbin/.amneziawg-ensure-module.new
    cat > "$_stage_helper" <<'AWG_ENSURE_HELPER_EOF'
#!/bin/bash
# amneziawg-ensure-module — rebuilds the AmneziaWG DKMS module after a
# kernel upgrade.
#
# Generated by install_amneziawg.sh (v5.12.0+). Do not edit; re-run the
# installer to refresh.
#
# Modes:
#   --hook     — invoked from /etc/apt/apt.conf.d/99-amneziawg-post-kernel
#                (DPkg::Post-Invoke). Constraints:
#                  - MUST NOT call apt-get install: the parent apt still
#                    holds /var/lib/dpkg/lock-frontend, a nested install
#                    would deadlock.
#                  - Skips modprobe and systemctl: the running kernel may
#                    still be the old one. The newly-built module is
#                    loaded after reboot via the systemd unit, or via
#                    `manage repair-module`.
#                Stamp-file fast-path keeps routine apt ops noise-free.
#
#   --systemd  — invoked from amneziawg-ensure-module.service at boot,
#                ordered Before=awg-quick@awg0.service. Builds for every
#                target kernel (same as --hook), then loads the module
#                via modprobe so awg-quick can start. No stamp fast-path
#                — boot must always verify load state, even if /lib/modules
#                hasn't changed since the last build (module not loaded
#                across reboots). Exit 1 if modprobe fails so systemd
#                marks the unit as failed (visible via systemctl status).
#
# Iteration target: every kernel that exposes /lib/modules/<ver>/build
# (= a directory with installed headers). uname -r alone is insufficient
# in apt-hook context because it returns the OLD running kernel while
# the new kernel's headers are already on disk.
#
# Output: stdout / stderr; --hook appends to
# /var/log/amneziawg-ensure-module.log (rotated weekly via
# /etc/logrotate.d/amneziawg-ensure-module). --systemd writes to journal
# (StandardOutput=journal, StandardError=journal in the unit file).

set -euo pipefail

MODE="${1:-}"
case "$MODE" in
    --hook|--systemd) ;;
    --help|-h) echo "Usage: $0 --hook | --systemd"; exit 0 ;;
    *) echo "amneziawg-ensure-module: missing or unknown mode (use --hook or --systemd)" >&2; exit 2 ;;
esac

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log_line() { printf '[%s] [%s] %s\n' "$(ts)" "$MODE" "$*"; }

if [[ $(id -u) -ne 0 ]]; then
    log_line "ERROR: root privileges required" >&2
    exit 1
fi

if ! command -v dkms >/dev/null 2>&1; then
    log_line "WARN: dkms is not installed — nothing to do"
    exit 0
fi

declare -a target_kernels=()
shopt -s nullglob
for build_dir in /lib/modules/*/build; do
    [[ -d "$build_dir" || -L "$build_dir" ]] || continue
    target_kernels+=("$(basename "$(dirname "$build_dir")")")
done
shopt -u nullglob

if [[ ${#target_kernels[@]} -eq 0 ]]; then
    log_line "WARN: no /lib/modules/*/build directories — kernel headers missing"
    exit 0
fi

# Build per-run state signature (mtime + kver) used by both modes:
#   --hook     — for stamp-file fast-path comparison (silent exit if equal)
#   --systemd  — recorded after success so subsequent --hook calls can skip
STAMP_DIR=/var/lib/amneziawg
STAMP_FILE="${STAMP_DIR}/ensure-module.stamp"
current_state=""
for kver in "${target_kernels[@]}"; do
    # stat may fail (build dir removed in flight) — guard against set -e abort.
    # Empty mtime → comparison differs → we re-run dkms autoinstall (acceptable).
    mtime="$(stat -c '%Y' "/lib/modules/${kver}/build" 2>/dev/null || true)"
    current_state+="${mtime} ${kver} "
done

# Fast-path applies ONLY to --hook. Boot (--systemd) must always run the
# full path — module is not loaded across reboots even when /lib/modules
# state is unchanged.
if [[ "$MODE" == "--hook" ]] \
        && [[ -f "$STAMP_FILE" && "$(cat "$STAMP_FILE" 2>/dev/null)" == "$current_state" ]]; then
    # Silent exit — routine apt ops don't add log noise.
    exit 0
fi

# Strip the deprecated REMAKE_INITRD directive (triggers noisy warnings
# on modern DKMS releases).
for cfg in /var/lib/dkms/amneziawg/*/source/dkms.conf; do
    [[ -f "$cfg" ]] && sed -i '/^REMAKE_INITRD=/d' "$cfg" 2>/dev/null || true
done

build_rc=0
for kver in "${target_kernels[@]}"; do
    log_line "dkms autoinstall -k $kver"
    if ! dkms autoinstall -k "$kver"; then
        log_line "WARN: dkms autoinstall failed for kernel $kver" >&2
        build_rc=1
    fi
done

depmod -a 2>/dev/null || true

# --systemd: load the module so awg-quick can start. Exit 1 on modprobe
# failure — systemd marks the unit failed; visible via `systemctl status
# amneziawg-ensure-module.service`. awg-quick still starts (Before= is
# ordering only, not a dependency) and surfaces its own error if the
# module is unavailable.
if [[ "$MODE" == "--systemd" ]]; then
    log_line "modprobe amneziawg"
    if ! modprobe amneziawg 2>&1; then
        log_line "ERROR: modprobe amneziawg failed for running kernel $(uname -r)" >&2
        log_line "  Check: /var/lib/dkms/amneziawg/<ver>/<kernel>/log/make.log" >&2
        exit 1
    fi
    if ! lsmod 2>/dev/null | grep -q '^amneziawg '; then
        log_line "ERROR: amneziawg module not present in lsmod after modprobe" >&2
        exit 1
    fi
    log_line "amneziawg module loaded for $(uname -r)"
    # Update stamp on --systemd success (current kernel is usable, what matters
    # for boot) even if some other kernel's build failed (build_rc=1).
    mkdir -p "$STAMP_DIR" 2>/dev/null || true
    printf '%s' "$current_state" > "$STAMP_FILE" 2>/dev/null || true
    log_line "done"
    exit 0
fi

# --hook: update stamp only on full success — partial failures retry next run.
if [[ $build_rc -eq 0 ]]; then
    mkdir -p "$STAMP_DIR" 2>/dev/null || true
    printf '%s' "$current_state" > "$STAMP_FILE" 2>/dev/null || true
fi

log_line "done (rc=$build_rc)"
exit "$build_rc"
AWG_ENSURE_HELPER_EOF
    chown root:root "$_stage_helper" 2>/dev/null || true
    chmod 0755 "$_stage_helper" \
        || { rm -f "$_stage_helper"; die "Failed to chmod helper."; }
    mv -f "$_stage_helper" /usr/local/sbin/amneziawg-ensure-module \
        || { rm -f "$_stage_helper"; die "Failed to deploy amneziawg-ensure-module helper."; }
    log "Helper /usr/local/sbin/amneziawg-ensure-module deployed."

    # v5.12.0: apt hook DPkg::Post-Invoke calls the helper after a kernel upgrade.
    mkdir -p /etc/apt/apt.conf.d
    local _stage_hook=/etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new
    cat > "$_stage_hook" <<'AWG_APT_HOOK_EOF'
// amneziawg-installer (v5.12.0+): rebuild DKMS module after kernel upgrades.
// Generated by install_amneziawg.sh — do not edit; re-run the installer to refresh.
DPkg::Post-Invoke {"if [ -x /usr/local/sbin/amneziawg-ensure-module ]; then /usr/local/sbin/amneziawg-ensure-module --hook >>/var/log/amneziawg-ensure-module.log 2>&1 || true; fi";};
AWG_APT_HOOK_EOF
    chown root:root "$_stage_hook" 2>/dev/null || true
    chmod 0644 "$_stage_hook" \
        || { rm -f "$_stage_hook"; die "Failed to chmod apt hook."; }
    mv -f "$_stage_hook" /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        || { rm -f "$_stage_hook"; die "Failed to deploy apt hook."; }
    log "Apt hook 99-amneziawg-post-kernel installed (auto-rebuild on apt kernel upgrade)."

    # v5.12.0: logrotate config for /var/log/amneziawg-ensure-module.log
    mkdir -p /etc/logrotate.d
    local _stage_logrotate=/etc/logrotate.d/.amneziawg-ensure-module.new
    cat > "$_stage_logrotate" <<'AWG_LOGROTATE_EOF'
/var/log/amneziawg-ensure-module.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
AWG_LOGROTATE_EOF
    chown root:root "$_stage_logrotate" 2>/dev/null || true
    chmod 0644 "$_stage_logrotate" \
        || { rm -f "$_stage_logrotate"; die "Failed to chmod logrotate config."; }
    mv -f "$_stage_logrotate" /etc/logrotate.d/amneziawg-ensure-module \
        || { rm -f "$_stage_logrotate"; die "Failed to deploy logrotate config."; }
    log "Logrotate config /etc/logrotate.d/amneziawg-ensure-module installed (weekly, rotate 4)."

    # v5.12.0 Phase 4: systemd unit guarantees the kernel module is built
    # and loaded BEFORE awg-quick@awg0 starts on every boot. Type=oneshot +
    # RemainAfterExit=yes + Before=awg-quick@awg0.service — the standard
    # pre-load pattern (after a kernel upgrade DKMS may need to rebuild on
    # the very first boot of the new kernel).
    log "Deploying systemd unit amneziawg-ensure-module.service..."
    mkdir -p /etc/systemd/system
    local _stage_unit=/etc/systemd/system/.amneziawg-ensure-module.service.new
    cat > "$_stage_unit" <<'AWG_SYSTEMD_UNIT_EOF'
[Unit]
Description=Ensure amneziawg kernel module is built and loaded
Documentation=https://github.com/bivlked/amneziawg-installer
Before=awg-quick@awg0.service
After=systemd-modules-load.service local-fs.target
ConditionPathExists=/usr/local/sbin/amneziawg-ensure-module

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/amneziawg-ensure-module --systemd
TimeoutStartSec=300
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
AWG_SYSTEMD_UNIT_EOF
    chown root:root "$_stage_unit" 2>/dev/null || true
    chmod 0644 "$_stage_unit" \
        || { rm -f "$_stage_unit"; die "Failed to chmod systemd unit."; }
    mv -f "$_stage_unit" /etc/systemd/system/amneziawg-ensure-module.service \
        || { rm -f "$_stage_unit"; die "Failed to deploy systemd unit."; }
    if ! systemctl daemon-reload; then
        log_warn "systemctl daemon-reload failed — the unit may not activate until reboot."
    fi
    if ! systemctl enable amneziawg-ensure-module.service; then
        log_warn "Failed to enable amneziawg-ensure-module.service — boot-time auto-rebuild will not run."
    fi
    log "Systemd unit amneziawg-ensure-module.service installed and enabled (Before=awg-quick@awg0)."

    # DKMS status
    log "Checking DKMS status..."
    local dkms_stat
    dkms_stat=$(dkms status 2>&1)
    if ! echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then
        log_warn "DKMS status not OK."
        log_msg "WARN" "$dkms_stat"
    else
        log "DKMS status OK."
    fi

    # Step 2 installs packages and reboots the machine as well, so it needs
    # the same line of defence.
    _boot_critical_guard

    log "Step 2 completed."
    request_reboot 3
}

# ==============================================================================
# STEP 3: Kernel module check
# ==============================================================================

step3_check_module() {
    update_state 3
    log "### STEP 3: Kernel module check ###"
    sleep 2

    if ! lsmod | grep -q -w amneziawg; then
        log "Module not loaded. Loading..."
        modprobe amneziawg || die "modprobe amneziawg error."
        log "Module loaded."
        local mf="/etc/modules-load.d/amneziawg.conf"
        mkdir -p "$(dirname "$mf")"
        if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then
            echo "amneziawg" > "$mf" || log_warn "Write error $mf"
            log "Added to $mf."
        fi
    else
        log "amneziawg module loaded."
    fi

    log "Module information:"
    modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" | while IFS= read -r line; do
        log "  $line"
    done

    local cv kr
    cv=$(modinfo amneziawg 2>/dev/null | awk '/^vermagic:/{print $2}')
    if [[ -z "$cv" ]]; then
        die "Failed to read amneziawg vermagic. Check: modprobe amneziawg && modinfo amneziawg"
    fi
    kr=$(uname -r)
    if [[ "$cv" != "$kr" ]]; then
        log_warn "VerMagic MISMATCH: Module($cv) != Kernel($kr)!"
    else
        log "VerMagic matches."
    fi

    # Check awg version
    if command -v awg &>/dev/null; then
        local awg_ver
        awg_ver=$(awg --version 2>/dev/null || echo "unknown")
        log "awg version: $awg_ver"
    else
        log_warn "awg command not found!"
    fi

    log "Step 3 completed."
    update_state 4
}

# ==============================================================================
# STEP 4: Firewall configuration
# ==============================================================================

step4_setup_firewall() {
    update_state 4
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        log "### STEP 4: UFW firewall configuration ###"
        install_packages ufw
        setup_improved_firewall || die "UFW configuration error."
        log "Step 4 completed."
    else
        log "### STEP 4: Skipping UFW configuration (--no-tweaks) ###"
    fi
    update_state 5
}

# ==============================================================================
# STEP 5: Downloading scripts (NO Python!)
# ==============================================================================

verify_sha256() {
    local file="$1" expected="$2" label="$3"
    # Skip verification when:
    # - SHA is not set (RELEASE_PLACEHOLDER — release not yet published)
    # - the source is overridden (test/local branch)
    if [[ "$expected" == "RELEASE_PLACEHOLDER" ]]; then
        log_debug "SHA256 for $label: skipped (placeholder, pre-release)."
        return 0
    fi
    if [[ "$AWG_REPOSITORY" != "$PINNED_HELPERS_REPOSITORY" \
          || "$AWG_BRANCH" != "$PINNED_HELPERS_REF" ]]; then
        log_warn "SHA256 for $label: verification skipped for override ${AWG_REPOSITORY}@${AWG_BRANCH}. File not verified."
        return 0
    fi
    local actual
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        log_error "SHA256 mismatch for $label!"
        log_error "  Expected: $expected"
        log_error "  Got:      $actual"
        log_error "  File may have been tampered with. Re-download the installer from GitHub."
        return 1
    fi
    log_debug "SHA256 $label: OK ($actual)"
    return 0
}

# _secure_download <url> <target> <expected_sha256> <label>
# Atomic download:
#   1. curl → mktemp on the same FS as target;
#   2. verify_sha256 on the temp file (not on target, so a corrupt file
#      never lives on the target path even for a fraction of a second);
#   3. chmod 700 on temp;
#   4. mv -f temp → target (atomic rename).
# If any step fails, temp is removed and target is untouched.
_secure_download() {
    local url="$1" target="$2" expected_sha256="$3" label="$4"
    local tmp target_dir
    target_dir=$(dirname "$target")
    tmp=$(mktemp -p "$target_dir" ".${label//\//_}.tmp.XXXXXX") \
        || die "Failed to create temp file for $label"
    if ! curl -fLso "$tmp" --max-time 60 --retry 2 "$url"; then
        rm -f "$tmp" 2>/dev/null
        die "$label download error"
    fi
    if ! verify_sha256 "$tmp" "$expected_sha256" "$label"; then
        rm -f "$tmp" 2>/dev/null
        die "$label integrity check failed (SHA256 mismatch). Installation aborted."
    fi
    if ! chmod 700 "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        die "chmod $label error"
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp" 2>/dev/null
        die "Failed to move $label to target path"
    fi
    log "$label downloaded and verified."
}

# Commit two already-verified helpers as one logical transaction. Both staged
# files live in AWG_DIR (same filesystem): validate the pair before the first
# rename and restore the old common helper if the second rename fails.
_commit_helper_pair() {
    local common_stage="$1" manage_stage="$2" common_label="$3" manage_label="$4"
    local old_common_tmp="" common_existed=0
    [[ -f "$common_stage" && ! -L "$common_stage" \
       && -f "$manage_stage" && ! -L "$manage_stage" ]] || {
        log_error "Helper pair commit: staging files are missing or unsafe."
        return 1
    }
    chmod 700 "$common_stage" "$manage_stage" || return 1
    if [[ ( -e "$COMMON_SCRIPT_PATH" || -L "$COMMON_SCRIPT_PATH" ) \
          && ( ! -f "$COMMON_SCRIPT_PATH" || -L "$COMMON_SCRIPT_PATH" ) \
          || ( -e "$MANAGE_SCRIPT_PATH" || -L "$MANAGE_SCRIPT_PATH" ) \
          && ( ! -f "$MANAGE_SCRIPT_PATH" || -L "$MANAGE_SCRIPT_PATH" ) ]]; then
        log_error "Refusing to replace a helper that is not a regular file."
        return 1
    fi
    if [[ -e "$COMMON_SCRIPT_PATH" ]]; then
        old_common_tmp=$(mktemp -p "$AWG_DIR" '.old-common.XXXXXX') || return 1
        cp -p -- "$COMMON_SCRIPT_PATH" "$old_common_tmp" \
            || { rm -f -- "$old_common_tmp"; return 1; }
        common_existed=1
    fi

    # Do not permit INT/TERM in the tiny window between the two renames.
    trap '' INT TERM
    if ! mv -f -- "$common_stage" "$COMMON_SCRIPT_PATH"; then
        trap '_install_on_signal 130' INT
        trap '_install_on_signal 143' TERM
        rm -f -- "$old_common_tmp"
        log_error "Could not atomically replace $common_label"
        return 1
    fi
    if ! mv -f -- "$manage_stage" "$MANAGE_SCRIPT_PATH"; then
        if [[ "$common_existed" -eq 1 ]]; then
            mv -f -- "$old_common_tmp" "$COMMON_SCRIPT_PATH" \
                || log_error "CRITICAL: common-helper rollback failed; backup: $old_common_tmp"
        else
            rm -f -- "$COMMON_SCRIPT_PATH" \
                || log_error "CRITICAL: could not remove the new common helper after pair-update failure."
        fi
        trap '_install_on_signal 130' INT
        trap '_install_on_signal 143' TERM
        log_error "Could not atomically replace $manage_label; pair update rolled back."
        return 1
    fi
    trap '_install_on_signal 130' INT
    trap '_install_on_signal 143' TERM
    rm -f -- "$old_common_tmp"
    return 0
}

step5_download_scripts() {
    update_state 5
    log "### STEP 5: Installing management scripts ###"
    cd "$AWG_DIR" || die "Error changing to $AWG_DIR"

    # Local path PREFERRED: if the installer is launched from a cloned
    # repository (i.e. awg_common.sh / manage_amneziawg.sh live next to the
    # installer), stage and SHA256-check BOTH files before replacing either
    # live helper. The standard repo/ref uses the same mandatory pin as CDN;
    # an explicit source override is clearly logged.
    # This makes the workflow "git clone → sudo bash install_amneziawg.sh"
    # work for forks: without this branch step5 would fetch upstream
    # versions from the CDN and our local fork modifications would be
    # silently discarded. The CDN path remains as a fallback for
    # `curl | bash` usage.
    #
    # $INSTALLER_DIR is captured at the top of the script, BEFORE any cd —
    # a late BASH_SOURCE[0] resolve with a relative path used to return
    # $AWG_DIR (because initialize_setup already cd'd there) and the
    # "script_dir != AWG_DIR" guard would wrongly trip for every
    # `sudo bash install_amneziawg.sh` invocation from the clone directory.
    local script_dir="${INSTALLER_DIR:-}"
    # Derive basenames from the URLs — the EN installer references *_en.sh
    # files, and those are what sits next to install_amneziawg_en.sh in a clone.
    local _common_basename="${COMMON_SCRIPT_URL##*/}"
    local _manage_basename="${MANAGE_SCRIPT_URL##*/}"
    if [[ -n "$script_dir" && "$script_dir" != "$AWG_DIR" \
          && -f "$script_dir/$_common_basename" \
          && ! -L "$script_dir/$_common_basename" \
          && -f "$script_dir/$_manage_basename" \
          && ! -L "$script_dir/$_manage_basename" ]]; then
        local _local_common_tmp="" _local_manage_tmp=""
        local _local_verify_failed=0
        log "Found local clone ($script_dir) — staging and verifying both helpers."
        _local_common_tmp=$(mktemp -p "$AWG_DIR" '.local-common.XXXXXX') \
            || die "Could not create staging for $_common_basename"
        _local_manage_tmp=$(mktemp -p "$AWG_DIR" '.local-manage.XXXXXX') \
            || { rm -f -- "$_local_common_tmp"; die "Could not create staging for $_manage_basename"; }
        _install_temp_files+=("$_local_common_tmp" "$_local_manage_tmp")
        cp -- "$script_dir/$_common_basename" "$_local_common_tmp" \
            && cp -- "$script_dir/$_manage_basename" "$_local_manage_tmp" \
            && chmod 700 "$_local_common_tmp" "$_local_manage_tmp" \
            || { rm -f -- "$_local_common_tmp" "$_local_manage_tmp"; die "Failed to stage local helpers"; }
        verify_sha256 "$_local_common_tmp" "$COMMON_SCRIPT_SHA256" "$_common_basename" \
            || _local_verify_failed=1
        verify_sha256 "$_local_manage_tmp" "$MANAGE_SCRIPT_SHA256" "$_manage_basename" \
            || _local_verify_failed=1
        if [[ "$_local_verify_failed" -eq 1 ]]; then
            rm -f -- "$_local_common_tmp" "$_local_manage_tmp"
            die "Local helper integrity could not be verified; live files were not changed."
        fi
        _commit_helper_pair "$_local_common_tmp" "$_local_manage_tmp" \
            "$_common_basename" "$_manage_basename" \
            || die "Transactional installation of the local helper pair failed."
        log "Both helper scripts installed from the local clone after staging and SHA256 verification."
        log "Step 5 completed."
        update_state 6
        return 0
    fi
    log_debug "No local clone detected (INSTALLER_DIR='${script_dir}', AWG_DIR='$AWG_DIR') — fetching from CDN."

    # The CDN fallback uses the same pair transaction: download and verify both
    # helpers in staging first, then replace the two live files only after both
    # SHA256 checks have succeeded.
    local _cdn_common_tmp="" _cdn_manage_tmp=""
    _cdn_common_tmp=$(mktemp -p "$AWG_DIR" '.cdn-common.XXXXXX') \
        || die "Could not create CDN staging for $_common_basename"
    _cdn_manage_tmp=$(mktemp -p "$AWG_DIR" '.cdn-manage.XXXXXX') \
        || { rm -f -- "$_cdn_common_tmp"; die "Could not create CDN staging for $_manage_basename"; }
    _install_temp_files+=("$_cdn_common_tmp" "$_cdn_manage_tmp")

    log "Downloading and verifying $_common_basename in staging..."
    _secure_download "$COMMON_SCRIPT_URL" "$_cdn_common_tmp" \
        "$COMMON_SCRIPT_SHA256" "$_common_basename"
    log "Downloading and verifying $_manage_basename in staging..."
    _secure_download "$MANAGE_SCRIPT_URL" "$_cdn_manage_tmp" \
        "$MANAGE_SCRIPT_SHA256" "$_manage_basename"
    _commit_helper_pair "$_cdn_common_tmp" "$_cdn_manage_tmp" \
        "$_common_basename" "$_manage_basename" \
        || die "Transactional installation of the CDN helper pair failed."
    log "Both helper scripts installed from CDN after pair verification."

    log "Step 5 completed."
    update_state 6
}

# ==============================================================================
# STEP 6: Config generation (native, without awgcfg.py)
# ==============================================================================

step6_generate_configs() {
    update_state 6
    log "### STEP 6: AWG 2.0 config generation ###"
    cd "$AWG_DIR" || die "cd $AWG_DIR error"

    # Load shared library
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        die "awg_common.sh not found. Step 5 not completed?"
    fi
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH"
    command -v ip >/dev/null 2>&1 \
        || die "The ip command is unavailable; live tunnels cannot be checked safely before replacing configs."

    # Migrate the empty marker used by older WARP versions into the granular
    # ownership model before stopping live awg0. Corrupt legacy state therefore
    # fails without taking the working VPN offline.
    local _legacy_warp_iface="${AWG_WARP_IFACE:-wgcf}"
    if [[ -e "$AWG_DIR/.warp_cleanup_pending" ]]; then
        [[ -f "$AWG_DIR/.warp_cleanup_pending" && ! -L "$AWG_DIR/.warp_cleanup_pending" ]] \
            || die "Unsafe WARP cleanup marker before preflight."
        IFS= read -r _legacy_warp_iface < "$AWG_DIR/.warp_cleanup_pending" || _legacy_warp_iface=""
    fi
    if [[ -e "$AWG_DIR/.wgcf_enabled_by_installer" || -L "$AWG_DIR/.wgcf_enabled_by_installer" ]]; then
        [[ "$_legacy_warp_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$_legacy_warp_iface" != "awg0" ]] \
            || die "Invalid WARP iface before legacy preflight."
        migrate_legacy_warp_ownership "$_legacy_warp_iface" \
            || die "Legacy WARP ownership could not be migrated safely; awg0 was left unchanged."
    fi

    # Create key directory
    mkdir -p "$KEYS_DIR" || die "Error creating $KEYS_DIR"

    # Generate server keys (if not yet present)
    if [[ ! -f "$AWG_DIR/server_private.key" ]]; then
        log "Generating server keys..."
        generate_server_keys || die "Server key generation error."
    else
        log "Server keys already exist."
    fi

    # Backup existing server config BEFORE overwriting
    if [[ -e "$SERVER_CONF_FILE" || -L "$SERVER_CONF_FILE" ]]; then
        [[ -f "$SERVER_CONF_FILE" && ! -L "$SERVER_CONF_FILE" ]] \
            || die "Refusing to back up an awg0.conf that is not a regular file."
        local s_bak
        s_bak="${SERVER_CONF_FILE}.bak-$(date +%F_%H%M%S)"
        cp "$SERVER_CONF_FILE" "$s_bak" || { rm -f "$s_bak"; die "Backup failed at $s_bak — live config left unchanged."; }
        log "Server config backup: $s_bak"
    fi

    # Render and validate the complete new awg0.conf BEFORE stopping the live
    # interface. The critical section then needs only an atomic rename.
    local _staged_server_conf _staged_server_dir
    _staged_server_dir=$(mktemp -d -p "$(dirname "$SERVER_CONF_FILE")" '.awg0-stage.XXXXXX') \
        || die "Could not create the awg0.conf staging directory."
    _install_temp_dirs+=("$_staged_server_dir")
    _staged_server_conf="$_staged_server_dir/awg0.conf"
    _install_temp_files+=("$_staged_server_conf")
    render_server_config "${s_bak:-}" "$_staged_server_conf" \
        || die "Server config pre-render failed; live awg0 was not stopped."
    validate_awg_config "$_staged_server_conf" \
        || die "The new awg0.conf failed validation; live awg0 was not stopped."
    timeout 10 awg-quick strip "$_staged_server_conf" >/dev/null 2>&1 \
        || die "The new awg0.conf failed awg-quick strip; live awg0 was not stopped."

    # Fully render and validate upstream BEFORE stopping awg0 or the old
    # upstream. render_upstream_config derives its output directory from
    # SERVER_CONF_FILE, so point it at an isolated staging directory briefly.
    local _staged_upstream_conf="" _staged_upstream_dir=""
    if [[ "${AWG_ROLE:-single}" == "entry" && -n "${AWG_UPSTREAM_CONF:-}" ]]; then
        local _saved_server_conf_file="$SERVER_CONF_FILE" _up_render_rc=0
        _staged_upstream_dir=$(mktemp -d -p "$AWG_DIR" '.upstream-stage.XXXXXX') \
            || die "Could not create an upstream-config staging directory."
        _install_temp_dirs+=("$_staged_upstream_dir")
        SERVER_CONF_FILE="$_staged_upstream_dir/awg0.conf"
        render_upstream_config || _up_render_rc=$?
        SERVER_CONF_FILE="$_saved_server_conf_file"
        [[ "$_up_render_rc" -eq 0 ]] \
            || die "Upstream pre-render failed; live units/configs were not changed."
        _staged_upstream_conf="$_staged_upstream_dir/${AWG_UPSTREAM_IFACE:-awg1}.conf"
        [[ -f "$_staged_upstream_conf" && ! -L "$_staged_upstream_conf" ]] \
            || die "Upstream pre-render did not create the expected config."
        _install_temp_files+=("$_staged_upstream_conf")
        timeout 10 awg-quick strip "$_staged_upstream_conf" >/dev/null 2>&1 \
            || die "The new upstream config failed awg-quick strip; live units/configs were not changed."
        log "New upstream config rendered and validated in staging."
    fi

    # Preflight + snapshot of the installer-owned systemd dependency for EXIT rollback.
    if [[ -e "$AWG0_DEPENDENCY_MARKER" || -L "$AWG0_DEPENDENCY_MARKER" ]]; then
        local _old_dep_path=""
        [[ -f "$AWG0_DEPENDENCY_MARKER" && ! -L "$AWG0_DEPENDENCY_MARKER" ]] \
            || die "Invalid awg0 dependency marker; live awg0 was not stopped."
        IFS= read -r _old_dep_path < "$AWG0_DEPENDENCY_MARKER" || _old_dep_path=""
        [[ "$_old_dep_path" == "$AWG0_DEPENDENCY_DROPIN" && -f "$AWG0_DEPENDENCY_DROPIN" \
           && ! -L "$AWG0_DEPENDENCY_DROPIN" ]] \
            || die "Stale/invalid awg0 dependency ownership; live awg0 was not stopped."
        _INSTALL_ROLLBACK_DEP_BACKUP=$(mktemp -p "$AWG_DIR" '.dependency.rollback.XXXXXX') \
            || die "Could not create an awg0 dependency backup."
        _install_temp_files+=("$_INSTALL_ROLLBACK_DEP_BACKUP")
        cp -- "$AWG0_DEPENDENCY_DROPIN" "$_INSTALL_ROLLBACK_DEP_BACKUP" \
            || die "Could not save awg0 dependency for rollback."
        _INSTALL_ROLLBACK_DEP_EXISTED=1
    elif [[ -e "$AWG0_DEPENDENCY_DROPIN" || -L "$AWG0_DEPENDENCY_DROPIN" ]]; then
        die "A foreign awg0 dependency drop-in exists without an ownership marker; live awg0 was not stopped."
    fi
    _INSTALL_ROLLBACK_DEP_ACTIVE=1

    # Snapshot config and exact runtime/autostart independently of active state:
    # an inactive old config must not be lost, and a first install must remove
    # its new target on abort. Arm the transaction BEFORE the first stop.
    local _old_awg0_state="" _old_awg0_link=0
    _INSTALL_ROLLBACK_SERVER_BACKUP="${s_bak:-}"
    [[ -n "${s_bak:-}" ]] && _INSTALL_ROLLBACK_SERVER_EXISTED=1 \
        || _INSTALL_ROLLBACK_SERVER_EXISTED=0
    _old_awg0_state=$(systemctl is-active awg-quick@awg0 2>/dev/null || true)
    command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1 \
        && _old_awg0_link=1
    [[ "$_old_awg0_state" =~ ^(active|activating|deactivating|reloading)$ ]] \
        && _INSTALL_ROLLBACK_AWG0_WAS_ACTIVE=1 \
        || _INSTALL_ROLLBACK_AWG0_WAS_ACTIVE=0
    _INSTALL_ROLLBACK_AWG0_WAS_LINK="$_old_awg0_link"
    systemctl is-enabled --quiet awg-quick@awg0 2>/dev/null \
        && _INSTALL_ROLLBACK_AWG0_WAS_ENABLED=1 \
        || _INSTALL_ROLLBACK_AWG0_WAS_ENABLED=0
    if [[ "$_old_awg0_link" -eq 1 && "$_INSTALL_ROLLBACK_SERVER_EXISTED" -eq 0 ]]; then
        die "A live awg0 exists without the expected $SERVER_CONF_FILE; safe rollback is impossible."
    fi
    _INSTALL_ROLLBACK_AWG0=1

    # Stop awg0 WHILE the old config is still on disk so its old PostDown
    # removes the previous direct/entry/WARP rules.
    if [[ "$_INSTALL_ROLLBACK_AWG0_WAS_ACTIVE" -eq 1 ]]; then
        log "Stopping awg0 before the atomic config replacement..."
        systemctl stop awg-quick@awg0 \
            || die "Could not stop awg-quick@awg0; old config preserved."
    elif [[ "$_old_awg0_state" != "inactive" && "$_old_awg0_state" != "failed" \
            && "$_old_awg0_state" != "unknown" ]]; then
        die "Could not determine awg0 state reliably; old config preserved."
    fi
    if command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1; then
        timeout 15 awg-quick down "$SERVER_CONF_FILE" >/dev/null 2>&1 \
            || die "Could not remove live awg0 with the old config; config was not overwritten."
    fi
    if command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1; then
        die "awg0 remained live after stop/down; config was not overwritten."
    fi

    # A previous upstream with its own routing table must not influence the new
    # mode. Stop it temporarily only; disabling/deletion remains post-commit.
    stop_pending_old_upstream_for_transition \
        || die "Could not safely stop the previous upstream before starting the new awg0."

    # Keep old units/configs intact until the new awg0 is committed. For a
    # WARP->WARP iface rename, move ownership markers only; EXIT restores them.
    park_pending_warp_ownership \
        || die "Could not retain previous WARP ownership safely until commit."

    # WARP egress: bring wgcf up BEFORE rendering awg0.conf — the PostUp in
    # the resulting config references the wgcf interface, which must exist
    # by the time systemctl start awg-quick@awg0 fires in step 7.
    if [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
        log "Installing WARP egress (Cloudflare)..."
        snapshot_warp_egress_state \
            || die "Could not create a complete WARP egress snapshot before mutation."
        setup_warp_egress || die "setup_warp_egress failed. See log."
    fi

    configure_awg0_dependency \
        || die "Could not configure the awg0 boot dependency on its egress tunnel."

    # Create the AWG 2.0 server config, carrying ALL existing [Peer] blocks
    # over from the backup in ONE atomic write (render_server_config appends
    # the peers into the temp BEFORE mv). Previously the append ran AFTER
    # render as a separate operation: a failure in the window between them
    # left the live config peer-less, and the next run of step 6 backed up
    # the already peer-less file - all clients were lost on --force reinstall
    # (recovery only by hand from a timestamped .bak).
    # C5 history (semantics worth keeping): ALL blocks are restored, including
    # the defaults my_phone/my_laptop - the idempotent loop below skips peers
    # that already exist, and the guard in generate_client refuses to recreate
    # one whose artifacts exist.
    log "Atomically deploying the validated server config..."
    mv -f "$_staged_server_conf" "$SERVER_CONF_FILE" \
        && chmod 600 "$SERVER_CONF_FILE" \
        || die "Validated server config deployment failed."
    _staged_server_conf=""
    rmdir "$_staged_server_dir" 2>/dev/null || true
    if [[ -n "${s_bak:-}" && -f "$s_bak" ]] && grep -q '^\[Peer\]' "$s_bak" 2>/dev/null; then
        log "Existing peers restored from backup."
    fi

    # Generate default clients
    log "Creating default clients..."
    local client_name
    for client_name in my_phone my_laptop; do
        if grep -qxF "#_Name = ${client_name}" "$SERVER_CONF_FILE" 2>/dev/null; then
            log "Client '$client_name' already exists."
        else
            log "Creating client '$client_name'..."
            generate_client "$client_name" || log_warn "Client creation error '$client_name'"
        fi
    done

    # Multi-hop: deploy the upstream interface (awg1) for role=entry.
    # If --upstream-conf is not given on a repeat run, keep the existing
    # ${AWG_UPSTREAM_IFACE}.conf as-is.
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        local _up_conf_out="/etc/amnezia/amneziawg/${AWG_UPSTREAM_IFACE:-awg1}.conf"
        local _up_runtime_state="" _up_live_link=0 _up_bak=""
        if [[ -e "$_up_conf_out" || -L "$_up_conf_out" ]]; then
            [[ -f "$_up_conf_out" && ! -L "$_up_conf_out" ]] \
                || die "Refusing to use an upstream config that is not a regular file."
            _up_bak="${_up_conf_out}.bak-$(date +%F_%H%M%S)"
            cp "$_up_conf_out" "$_up_bak" \
                || { rm -f "$_up_bak"; die "Backup failed at $_up_bak; upstream config was not changed."; }
            log "Upstream config backup: $_up_bak"
            _INSTALL_ROLLBACK_UPSTREAM_BACKUP="$_up_bak"
            _INSTALL_ROLLBACK_UPSTREAM_EXISTED=1
        elif [[ -z "${AWG_UPSTREAM_CONF:-}" ]]; then
            die "role=entry: no upstream config in CLI or on disk ($_up_conf_out)."
        else
            _INSTALL_ROLLBACK_UPSTREAM_BACKUP=""
            _INSTALL_ROLLBACK_UPSTREAM_EXISTED=0
        fi
        _INSTALL_ROLLBACK_UPSTREAM_TARGET="$_up_conf_out"
        _up_runtime_state=$(systemctl is-active "awg-quick@${AWG_UPSTREAM_IFACE:-awg1}" 2>/dev/null || true)
        [[ "$_up_runtime_state" =~ ^(active|activating|deactivating|reloading)$ ]] \
            && _INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE=1 \
            || _INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE=0
        command -v ip >/dev/null 2>&1 \
            && ip link show dev "${AWG_UPSTREAM_IFACE:-awg1}" >/dev/null 2>&1 \
            && _up_live_link=1
        _INSTALL_ROLLBACK_UPSTREAM_WAS_LINK="$_up_live_link"
        systemctl is-enabled --quiet "awg-quick@${AWG_UPSTREAM_IFACE:-awg1}" 2>/dev/null \
            && _INSTALL_ROLLBACK_UPSTREAM_WAS_ENABLED=1 \
            || _INSTALL_ROLLBACK_UPSTREAM_WAS_ENABLED=0
        if [[ "$_up_live_link" -eq 1 && "$_INSTALL_ROLLBACK_UPSTREAM_EXISTED" -eq 0 ]]; then
            die "A live upstream exists without regular $_up_conf_out; safe rollback is impossible."
        fi
        # Step 7 mutates enable/start even when reusing an unchanged config. Arm
        # rollback now so any later error restores exact active/link/enabled state.
        _INSTALL_ROLLBACK_UPSTREAM=1
        if [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE" -eq 0 && "$_up_live_link" -eq 1 ]]; then
            timeout 15 awg-quick down "$_up_conf_out" >/dev/null 2>&1 \
                || die "Could not temporarily bring down manually-live upstream ${AWG_UPSTREAM_IFACE:-awg1}."
            if ip link show dev "${AWG_UPSTREAM_IFACE:-awg1}" >/dev/null 2>&1; then
                die "Manually-live upstream ${AWG_UPSTREAM_IFACE:-awg1} remained after awg-quick down."
            fi
        fi
        if [[ -n "${AWG_UPSTREAM_CONF:-}" ]]; then
            log "Deploying upstream interface ${AWG_UPSTREAM_IFACE:-awg1} from ${AWG_UPSTREAM_CONF}..."
            [[ -n "$_staged_upstream_conf" && -f "$_staged_upstream_conf" ]] \
                || die "Validated upstream staging was lost; live config was not changed."
            if [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE" -eq 1 ]]; then
                log "Stopping ${AWG_UPSTREAM_IFACE:-awg1} before replacing the upstream config..."
                systemctl stop "awg-quick@${AWG_UPSTREAM_IFACE:-awg1}" \
                    || die "Could not stop upstream ${AWG_UPSTREAM_IFACE:-awg1}; old config preserved."
            elif [[ "$_up_runtime_state" != "inactive" && "$_up_runtime_state" != "failed" \
                    && "$_up_runtime_state" != "unknown" ]]; then
                die "Could not reliably determine upstream ${AWG_UPSTREAM_IFACE:-awg1} state; old config preserved."
            fi
            if command -v ip >/dev/null 2>&1 \
               && ip link show dev "${AWG_UPSTREAM_IFACE:-awg1}" >/dev/null 2>&1; then
                timeout 15 awg-quick down "$_up_conf_out" >/dev/null 2>&1 \
                    || die "Could not bring down live upstream ${AWG_UPSTREAM_IFACE:-awg1} with the old config; config was not overwritten."
            fi
            if command -v ip >/dev/null 2>&1 \
               && ip link show dev "${AWG_UPSTREAM_IFACE:-awg1}" >/dev/null 2>&1; then
                die "Upstream ${AWG_UPSTREAM_IFACE:-awg1} remained live after stop/down; config was not overwritten."
            fi
            mv -f -- "$_staged_upstream_conf" "$_up_conf_out" \
                && chmod 600 "$_up_conf_out" \
                || die "Could not atomically deploy upstream config (${AWG_UPSTREAM_IFACE:-awg1})."
            _staged_upstream_conf=""
            rmdir "$_staged_upstream_dir" 2>/dev/null || true
            local _expected_staged="$AWG_DIR/.upstream-${AWG_UPSTREAM_IFACE:-awg1}.pending.conf"
            if [[ "$AWG_UPSTREAM_CONF" == "$_expected_staged" ]]; then
                rm -f -- "$_expected_staged" || log_warn "Could not remove the consumed upstream staging file."
                AWG_UPSTREAM_CONF=""
            fi
        else
            log "Upstream config already exists: $_up_conf_out — skipping render."
        fi
    fi

    # Set file permissions
    secure_files

    log "Configuration files in $AWG_DIR:"
    ls -la "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | while IFS= read -r line; do
        log "  $line"
    done

    log "Step 6 completed."
    update_state 7
}

# Load only a v2 ledger that passes the same bounds as common teardown: exact
# table, at most 2048 unique public /19../32 prefixes. The result is a
# process-local associative set made from one read snapshot rather than a
# second grep of a ledger that may have changed.
load_validated_warp_bypass_ledger() {
    local expected_table="$1" marker="$AWG_DIR/.warp_bypass_enabled_by_installer"
    local ledger="/etc/amnezia/amneziawg/warp-bypass.routes" marker_value="" line="" line_no=0 route_count=0
    _INSTALL_VALIDATED_WARP_ROUTES=()
    [[ -f "$marker" && ! -L "$marker" && -f "$ledger" && ! -L "$ledger" ]] || return 1
    marker_value=$(<"$marker")
    [[ "$marker_value" == "v2" ]] || return 1
    declare -F _valid_warp_bypass_ledger_route >/dev/null 2>&1 || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$(( line_no + 1 ))
        if (( line_no == 1 )); then
            [[ "$line" == "table=${expected_table}" ]] || return 1
            continue
        fi
        (( route_count < 2048 )) || return 1
        _valid_warp_bypass_ledger_route "$line" || return 1
        [[ -z "${_INSTALL_VALIDATED_WARP_ROUTES[$line]+present}" ]] || return 1
        _INSTALL_VALIDATED_WARP_ROUTES["$line"]=1
        route_count=$(( route_count + 1 ))
    done < "$ledger"
    (( line_no >= 2 && route_count >= 1 ))
}

_validate_expected_table_default() {
    local line="$1" kind="$2" iface="$3" expected_metric="$4"
    local -a fields=()
    read -r -a fields <<< "$line"
    if [[ "$kind" == "blackhole" ]]; then
        (( ${#fields[@]} == 4 )) \
            && [[ "${fields[0]}" == "blackhole" && "${fields[1]}" == "default" \
               && "${fields[2]}" == "metric" && "${fields[3]}" == "$expected_metric" ]]
    elif [[ -n "$expected_metric" ]]; then
        (( ${#fields[@]} == 7 )) \
            && [[ "${fields[0]}" == "default" && "${fields[1]}" == "dev" \
               && "${fields[2]}" == "$iface" && "${fields[3]}" == "scope" \
               && "${fields[4]}" == "link" && "${fields[5]}" == "metric" \
               && "${fields[6]}" == "$expected_metric" ]]
    else
        (( ${#fields[@]} == 5 )) \
            && [[ "${fields[0]}" == "default" && "${fields[1]}" == "dev" \
               && "${fields[2]}" == "$iface" && "${fields[3]}" == "scope" \
               && "${fields[4]}" == "link" ]]
    fi
}

# Validate bypass routes by both the destination in the ledger and the exact
# current main nexthop used by the owned refresh service.
validate_owned_warp_bypass_route_set() {
    local routes="$1" table="$2" require_complete="${3:-0}"
    local main_route="" main_nic="" main_gw="" main_defaults="" main_default=""
    local main_default_nic="" main_default_gw="" main_default_match=0
    local line="" dst=""
    local -a fields=()
    local -A seen=()
    if [[ -z "$routes" ]]; then
        [[ "$require_complete" != "1" || "${AWG_WARP_BYPASS:-none}" == "none" ]] \
            && return 0
        # After successful setup a requested bypass must have both its ledger
        # and at least one exact route. An empty/lost set is not success.
        load_validated_warp_bypass_ledger "$table" || return 1
        return 1
    fi
    load_validated_warp_bypass_ledger "$table" || return 1
    main_route=$(ip -4 route get 1.1.1.1 2>/dev/null) || return 1
    main_nic=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$main_route")
    main_gw=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<< "$main_route")
    _valid_warp_bypass_route_iface "$main_nic" || return 1
    ip link show up dev "$main_nic" >/dev/null 2>&1 || return 1
    [[ -z "$main_gw" ]] || _valid_ipv4 "$main_gw" || return 1
    main_defaults=$(ip -o -4 route show table main default 2>/dev/null) || return 1
    while IFS= read -r main_default || [[ -n "$main_default" ]]; do
        [[ -n "$main_default" ]] || continue
        [[ "$main_default" != *" linkdown"* ]] || continue
        main_default_nic=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$main_default")
        main_default_gw=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<< "$main_default")
        if [[ "$main_default_nic" == "$main_nic" && "$main_default_gw" == "$main_gw" ]]; then
            main_default_match=1
            break
        fi
    done <<< "$main_defaults"
    (( main_default_match == 1 )) || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        fields=(); read -r -a fields <<< "$line"
        dst="${fields[0]:-}"
        if [[ "$dst" != */* ]]; then
            _valid_ipv4 "$dst" || return 1
            dst="${dst}/32"
        fi
        [[ -n "$dst" && -n "${_INSTALL_VALIDATED_WARP_ROUTES[$dst]+present}" \
           && -z "${seen[$dst]+present}" ]] || return 1
        seen["$dst"]=1
        if [[ -n "$main_gw" ]]; then
            (( ${#fields[@]} == 5 )) \
                && [[ "${fields[1]}" == "via" && "${fields[2]}" == "$main_gw" \
                   && "${fields[3]}" == "dev" && "${fields[4]}" == "$main_nic" ]] \
                || return 1
        else
            { (( ${#fields[@]} == 5 )) \
                && [[ "${fields[1]}" == "dev" && "${fields[2]}" == "$main_nic" \
                   && "${fields[3]}" == "scope" && "${fields[4]}" == "link" ]]; } \
                || return 1
        fi
    done <<< "$routes"
    if [[ "$require_complete" == "1" ]]; then
        [[ "${AWG_WARP_BYPASS:-none}" != "none" ]] || return 1
        (( ${#seen[@]} == ${#_INSTALL_VALIDATED_WARP_ROUTES[@]} )) || return 1
    fi
    return 0
}

# Before support/awg0 starts, both priorities must be free and no other rule
# may reference the selected table. Entry permits only the existing default of
# its active upstream; WARP permits only exact routes from a strict owned ledger.
preflight_fork_policy_namespace() {
    local iface="" table="" priority="" guard_priority="" rules="" routes="" line="" defaults=0
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        iface="${AWG_UPSTREAM_IFACE:-awg1}"
        table="${AWG_UPSTREAM_TABLE:-123}"
        priority="${AWG_UPSTREAM_PRIORITY:-456}"
    elif [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
        iface="${AWG_WARP_IFACE:-wgcf}"
        table="${AWG_WARP_TABLE:-2408}"
        priority="${AWG_WARP_PRIORITY:-789}"
    else
        return 0
    fi
    guard_priority=$(( 10#$priority + 1 ))
    rules=$(ip -N -4 rule show 2>/dev/null) || return 1
    printf '%s\n' "$rules" | awk -v pn="$priority" -v p="${priority}:" -v g="${guard_priority}:" -v t="$table" '
        $1 == p || $1 == g { collision=1 }
        {
            prio=$1
            sub(/:$/, "", prio)
            if (prio == 0) {
                zero_total++
                if ($2 == "from" && $3 == "all" \
                    && ($4 == "lookup" || $4 == "table") \
                    && ($5 == "local" || $5 == "255") && NF == 5) zero_local++
                else collision=1
            # sub() leaves a string: force numeric ordering (32766 > 789).
            } else if (prio ~ /^[0-9]+$/ && (prio + 0) < (pn + 0)) collision=1
            for (i=2; i<NF; i++)
                if (($i == "lookup" || $i == "table") && $(i+1) == t) collision=1
        }
        END { exit(!collision && zero_total == 1 && zero_local == 1 ? 0 : 1) }
    ' \
        || return 1
    if ! routes=$(LC_ALL=C ip -4 route show table "$table" 2>&1); then
        [[ "$routes" == *"FIB table does not exist"* ]] || return 1
        routes=""
    fi
    [[ -n "$routes" ]] || return 0
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            [[ -n "$line" ]] || continue
            _validate_expected_table_default "$line" real "$iface" "" || return 1
            defaults=$(( defaults + 1 ))
        done <<< "$routes"
        (( defaults == 1 )) || return 1
    else
        validate_owned_warp_bypass_route_set "$routes" "$table" || return 1
    fi
    return 0
}

# PostUp is a `;`-separated shell chain, so a unit may become active even when
# an iptables command failed. Verify critical FORWARD/NAT/MSS rules exactly,
# including the direct-NAT path used by WARP bypass.
verify_fork_firewall_runtime() {
    local iface="$1" source_net="$2" path_mtu="${AWG_MTU:-1280}" mss4=""
    local main_route="" main_nic=""
    command -v iptables >/dev/null 2>&1 || return 1
    iptables -w 5 -C FORWARD -i awg0 -o "$iface" -j ACCEPT >/dev/null 2>&1 || return 1
    iptables -w 5 -C FORWARD -i "$iface" -o awg0 \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT >/dev/null 2>&1 || return 1
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        iptables -w 5 -t nat -C POSTROUTING -o "$iface" -j MASQUERADE >/dev/null 2>&1 \
            || return 1
    else
        iptables -w 5 -t nat -C POSTROUTING -s "$source_net" -o "$iface" \
            -j MASQUERADE >/dev/null 2>&1 || return 1
        if [[ "${AWG_WARP_BYPASS:-none}" != "none" ]]; then
            main_route=$(ip -4 route get 1.1.1.1 2>/dev/null) || return 1
            main_nic=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$main_route")
            _valid_warp_bypass_route_iface "$main_nic" || return 1
            iptables -w 5 -t nat -C POSTROUTING -s "$source_net" -o "$main_nic" \
                -j MASQUERADE >/dev/null 2>&1 || return 1
        fi
    fi
    _validate_mtu "$path_mtu" || path_mtu=1280
    path_mtu=$(( 10#$path_mtu ))
    if [[ "${AWG_EGRESS:-direct}" == "warp" && "$path_mtu" -gt 1280 ]]; then
        path_mtu=1280
    elif [[ "${AWG_ROLE:-single}" == "entry" && "$path_mtu" -gt 1380 ]]; then
        path_mtu=1380
    fi
    mss4=$(( path_mtu - 40 ))
    iptables -w 5 -t mangle -C FORWARD -o awg0 -p tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss4" >/dev/null 2>&1 || return 1
    iptables -w 5 -t mangle -C FORWARD -i awg0 -p tcp \
        --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$mss4" >/dev/null 2>&1 || return 1
    if [[ "${CLIENT_ISOLATION:-1}" -eq 1 ]]; then
        iptables -w 5 -C FORWARD -i awg0 -o awg0 -j DROP >/dev/null 2>&1 || return 1
    fi
    return 0
}

# Before commit, verify exact live fail-closed routing and firewall state rather
# than trusting config intent.
verify_fork_egress_runtime() {
    local require_complete_bypass="${1:-0}"
    local iface="" unit="" table="" priority="" guard_priority="" source_net="" routes=""
    local rules="" line="" specific_routes="" blackholes=0 defaults=0
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        iface="${AWG_UPSTREAM_IFACE:-awg1}"
        unit="awg-quick@${iface}"
        table="${AWG_UPSTREAM_TABLE:-123}"
        priority="${AWG_UPSTREAM_PRIORITY:-456}"
    elif [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
        iface="${AWG_WARP_IFACE:-wgcf}"
        unit="wg-quick@${iface}"
        table="${AWG_WARP_TABLE:-2408}"
        priority="${AWG_WARP_PRIORITY:-789}"
    else
        return 0
    fi
    guard_priority=$(( 10#$priority + 1 ))
    source_net=$(_awg_network_cidr "${AWG_TUNNEL_SUBNET:-}") || return 1
    systemctl is-active --quiet "$unit" 2>/dev/null || return 1
    ip link show up dev "$iface" >/dev/null 2>&1 || return 1
    rules=$(ip -N -4 rule show 2>/dev/null) || return 1
    printf '%s\n' "$rules" | awk -v pn="$priority" -v p="${priority}:" -v g="${guard_priority}:" -v s="$source_net" -v t="$table" '
        $1 == p {
            primary_total++
            if ($2 == "from" && $3 == s \
                && ($4 == "lookup" || $4 == "table") && $5 == t && NF == 5) primary++
        }
        $1 == g {
            guard_total++
            if ((($2 == "from" && $3 == s && $4 == "blackhole") \
                 || ($2 == "blackhole" && $3 == "from" && $4 == s)) && NF == 4) guard++
        }
        {
            prio=$1
            sub(/:$/, "", prio)
            if (prio == 0) {
                zero_total++
                if ($2 == "from" && $3 == "all" \
                    && ($4 == "lookup" || $4 == "table") \
                    && ($5 == "local" || $5 == "255") && NF == 5) zero_local++
                else earlier=1
            # sub() leaves a string: force numeric ordering (32766 > 789).
            } else if (prio ~ /^[0-9]+$/ && (prio + 0) < (pn + 0)) earlier=1
            for (i=2; i<NF; i++)
                if (($i == "lookup" || $i == "table") && $(i+1) == t) table_lookups++
        }
        END {
            exit(primary_total == 1 && primary == 1 \
                 && guard_total == 1 && guard == 1 && table_lookups == 1 \
                 && zero_total == 1 && zero_local == 1 && !earlier ? 0 : 1)
        }
    ' || return 1
    routes=$(ip -4 route show table "$table" 2>/dev/null) || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        if [[ "$line" == blackhole\ default* ]]; then
            _validate_expected_table_default "$line" blackhole "" 42760 || return 1
            blackholes=$(( blackholes + 1 ))
        elif [[ "$line" == default* ]]; then
            if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
                _validate_expected_table_default "$line" real "$iface" "" || return 1
            else
                _validate_expected_table_default "$line" real "$iface" 10 || return 1
            fi
            defaults=$(( defaults + 1 ))
        elif [[ "${AWG_ROLE:-single}" == "entry" ]]; then
            return 1
        else
            specific_routes+="${specific_routes:+$'\n'}${line}"
        fi
    done <<< "$routes"
    (( blackholes == 1 && defaults == 1 )) || return 1
    if [[ "${AWG_ROLE:-single}" != "entry" ]]; then
        validate_owned_warp_bypass_route_set \
            "$specific_routes" "$table" "$require_complete_bypass" || return 1
    fi
    verify_fork_firewall_runtime "$iface" "$source_net" || return 1
    return 0
}

ufw_main_route_required() {
    [[ "${AWG_ROLE:-single}" != "entry" \
       && ( "${AWG_EGRESS:-direct}" != "warp" || "${AWG_WARP_BYPASS:-none}" != "none" ) ]]
}

_inspect_exact_ufw_route() {
    local iface="$1" comment="$2" output="" line=""
    local base="ufw route allow in on awg0 out on ${iface}"
    _INSTALL_UFW_ROUTE_SHAPE_COUNT=0
    _INSTALL_UFW_ROUTE_OWNED_COUNT=0
    command -v ufw >/dev/null 2>&1 || return 1
    output=$(ufw show added 2>/dev/null) || return 1
    while IFS= read -r line; do
        case "$line" in
            "$base"|"$base comment "*)
                _INSTALL_UFW_ROUTE_SHAPE_COUNT=$(( _INSTALL_UFW_ROUTE_SHAPE_COUNT + 1 ))
                ;;
        esac
        case "$line" in
            "$base comment $comment"|\
            "$base comment '$comment'"|\
            "$base comment \"$comment\"")
                _INSTALL_UFW_ROUTE_OWNED_COUNT=$(( _INSTALL_UFW_ROUTE_OWNED_COUNT + 1 ))
                ;;
        esac
    done <<< "$output"
}

delete_exact_owned_ufw_route() {
    local iface="$1" comment="$2"
    _inspect_exact_ufw_route "$iface" "$comment" || return 1
    if [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 0 ]]; then return 0; fi
    [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 1 && "$_INSTALL_UFW_ROUTE_OWNED_COUNT" -eq 1 ]] \
        || return 1
    ufw route delete allow in on awg0 out on "$iface" comment "$comment" >/dev/null 2>&1 \
        || return 1
    _inspect_exact_ufw_route "$iface" "$comment" \
        && [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 0 ]]
}

delete_owned_ufw_route_if_present() {
    local iface="$1" comment="$2"
    _inspect_exact_ufw_route "$iface" "$comment" || return 1
    [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 0 ]] && return 0
    delete_exact_owned_ufw_route "$iface" "$comment"
}

_inspect_exact_ufw_udp_allow() {
    local port="$1" comment="$2" output="" line=""
    local base="ufw allow ${port}/udp"
    _INSTALL_UFW_UDP_SHAPE_COUNT=0
    _INSTALL_UFW_UDP_OWNED_COUNT=0
    [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
    command -v ufw >/dev/null 2>&1 || return 1
    output=$(ufw show added 2>/dev/null) || return 1
    while IFS= read -r line; do
        case "$line" in
            "$base"|"$base comment "*)
                _INSTALL_UFW_UDP_SHAPE_COUNT=$(( _INSTALL_UFW_UDP_SHAPE_COUNT + 1 ))
                ;;
        esac
        case "$line" in
            "$base comment $comment"|\
            "$base comment '$comment'"|\
            "$base comment \"$comment\"")
                _INSTALL_UFW_UDP_OWNED_COUNT=$(( _INSTALL_UFW_UDP_OWNED_COUNT + 1 ))
                ;;
        esac
    done <<< "$output"
}

delete_owned_ufw_udp_allow_if_present() {
    local port="$1" comment="$2"
    _inspect_exact_ufw_udp_allow "$port" "$comment" || return 1
    [[ "$_INSTALL_UFW_UDP_SHAPE_COUNT" -eq 0 ]] && return 0
    [[ "$_INSTALL_UFW_UDP_SHAPE_COUNT" -eq 1 && "$_INSTALL_UFW_UDP_OWNED_COUNT" -eq 1 ]] \
        || return 1
    ufw delete allow "${port}/udp" comment "$comment" >/dev/null 2>&1 || return 1
    _inspect_exact_ufw_udp_allow "$port" "$comment" \
        && [[ "$_INSTALL_UFW_UDP_SHAPE_COUNT" -eq 0 ]]
}

ensure_owned_cascade_ufw_route() {
    local iface="$1" comment=""
    comment="AmneziaWG cascade awg0->${iface}"
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$iface" != "awg0" ]] || return 1
    _inspect_exact_ufw_route "$iface" "$comment" || return 1
    if [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 1 && "$_INSTALL_UFW_ROUTE_OWNED_COUNT" -eq 1 ]]; then
        return 0
    fi
    [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 0 ]] || return 1
    ufw route allow in on awg0 out on "$iface" comment "$comment" >/dev/null 2>&1 || return 1
    _INSTALL_ROLLBACK_UFW_CASCADE_IFACE="$iface"
    _INSTALL_ROLLBACK_UFW_CASCADE_RULE=1
    _inspect_exact_ufw_route "$iface" "$comment" \
        && [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 1 \
              && "$_INSTALL_UFW_ROUTE_OWNED_COUNT" -eq 1 ]]
}

_install_remove_new_ufw_cascade_rule() {
    [[ "$_INSTALL_ROLLBACK_UFW_CASCADE_RULE" -eq 1 ]] || return 0
    local iface="$_INSTALL_ROLLBACK_UFW_CASCADE_IFACE"
    delete_exact_owned_ufw_route "$iface" "AmneziaWG cascade awg0->${iface}" || return 1
    _INSTALL_ROLLBACK_UFW_CASCADE_RULE=0
    return 0
}

cleanup_pending_ufw_main_route_for_entry() {
    local marker="$AWG_DIR/.ufw_main_cleanup_pending" iface=""
    [[ -e "$marker" || -L "$marker" ]] || return 0
    if ufw_main_route_required; then
        log_warn "Deferred UFW main-route marker retained: the new mode still needs awg0→main."
        return 0
    fi
    [[ -f "$marker" && ! -L "$marker" ]] || {
        log_warn "Unsafe UFW main-route marker retained: $marker"
        return 0
    }
    IFS= read -r iface < "$marker" || iface=""
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,14}$ ]] || {
        log_warn "Invalid iface in UFW main-route marker; rule retained."
        return 0
    }
    command -v ufw >/dev/null 2>&1 || {
        log_warn "UFW unavailable; old awg0→main rule retained."
        return 0
    }
    _inspect_exact_ufw_route "$iface" "AmneziaWG Routing" || {
        log_warn "Could not verify UFW awg0→main ownership; rule retained."
        return 0
    }
    if [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 0 ]]; then
        _INSTALL_UFW_MAIN_MARKER_RESOLVED=1
        return 0
    fi
    if [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -ne 1 || "$_INSTALL_UFW_ROUTE_OWNED_COUNT" -ne 1 ]]; then
        log_warn "UFW awg0→main does not have exactly one installer-owned match; ambiguous rule retained."
        return 0
    fi
    _INSTALL_ROLLBACK_UFW_MAIN_IFACE="$iface"
    _INSTALL_ROLLBACK_UFW_MAIN_RULE=1
    delete_exact_owned_ufw_route "$iface" "AmneziaWG Routing" || return 1
    log "UFW: previous installer-owned awg0→${iface} route removed before the new-mode commit."
    return 0
}

# ==============================================================================
# STEP 7: Service startup
# ==============================================================================

# A step-7 resume has lost step 6's process-local snapshot. Before enable/start,
# capture the exact runtime/autostart state of a reused upstream again so a late
# abort cannot leave a previously inactive/manual unit mutated.
arm_step7_upstream_rollback() {
    [[ "${AWG_ROLE:-single}" == "entry" ]] || return 0
    [[ "$_INSTALL_ROLLBACK_UPSTREAM" -eq 0 ]] || return 0
    local iface="${AWG_UPSTREAM_IFACE:-awg1}" target="" backup="" state="" link=0
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$iface" != "awg0" ]] || return 1
    target="/etc/amnezia/amneziawg/${iface}.conf"
    [[ -f "$target" && ! -L "$target" ]] || return 1
    command -v ip >/dev/null 2>&1 || return 1
    backup=$(mktemp -p "$AWG_DIR" '.step7-upstream.rollback.XXXXXX') || return 1
    _install_temp_files+=("$backup")
    cp -p -- "$target" "$backup" || return 1
    state=$(systemctl is-active "awg-quick@${iface}" 2>/dev/null || true)
    [[ "$state" =~ ^(active|activating|deactivating|reloading|inactive|failed|unknown)$ ]] || return 1
    ip link show dev "$iface" >/dev/null 2>&1 && link=1
    _INSTALL_ROLLBACK_UPSTREAM_TARGET="$target"
    _INSTALL_ROLLBACK_UPSTREAM_BACKUP="$backup"
    _INSTALL_ROLLBACK_UPSTREAM_EXISTED=1
    [[ "$state" =~ ^(active|activating|deactivating|reloading)$ ]] \
        && _INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE=1 \
        || _INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE=0
    _INSTALL_ROLLBACK_UPSTREAM_WAS_LINK="$link"
    systemctl is-enabled --quiet "awg-quick@${iface}" 2>/dev/null \
        && _INSTALL_ROLLBACK_UPSTREAM_WAS_ENABLED=1 \
        || _INSTALL_ROLLBACK_UPSTREAM_WAS_ENABLED=0
    _INSTALL_ROLLBACK_UPSTREAM=1
    if [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE" -eq 0 && "$link" -eq 1 ]]; then
        timeout 15 awg-quick down "$target" >/dev/null 2>&1 || return 1
        ip link show dev "$iface" >/dev/null 2>&1 && return 1
    fi
    return 0
}

step7_start_service() {
    update_state 7
    log "### STEP 7: Service startup and security configuration ###"

    # On a direct resume from setup_state=7 the shared library has not been
    # sourced in this process yet. Without it awg_record_device_params below
    # used to fail with command-not-found.
    if ! declare -F awg_record_device_params >/dev/null 2>&1; then
        [[ -f "$COMMON_SCRIPT_PATH" ]] || die "awg_common.sh is missing while resuming step 7."
        # shellcheck source=/dev/null
        source "$COMMON_SCRIPT_PATH"
    fi
    declare -F awg_record_device_params >/dev/null 2>&1 \
        || die "awg_common.sh does not provide awg_record_device_params."

    # Reconcile an existing owned bypass BEFORE namespace preflight/start. On a
    # WARP→entry transition that reuses the table, old specific routes otherwise
    # block entry preflight; on bypass→none they transiently outlive the new awg0.
    # The snapshot makes this early mutation fully reversible by EXIT rollback.
    local _bypass_marker="$AWG_DIR/.warp_bypass_enabled_by_installer"
    local _bypass_tx_needed=0 _bypass_tx_prepared=0
    if [[ -e "$_bypass_marker" || -L "$_bypass_marker" ]]; then
        # The snapshot stops the owned timer/service before the transaction is
        # fully armed. Block INT/TERM across that window and keep them blocked
        # until the shared installer commit/state99 below.
        trap '' INT TERM
        declare -F snapshot_warp_bypass_state >/dev/null 2>&1 \
            && declare -F setup_warp_bypass >/dev/null 2>&1 \
            || die "The current awg_common.sh does not support transactional WARP bypass."
        snapshot_warp_bypass_state \
            || die "Could not snapshot the previous WARP bypass before policy preflight."
        setup_warp_bypass \
            || die "Previous WARP bypass did not reach the requested state before policy preflight; rolling back."
        _bypass_tx_prepared=1
    fi

    local _resume_owned_live=0 _resume_awg0_active=0 _resume_awg0_link=0
    if [[ "${_INSTALL_INITIAL_STEP:-1}" -eq 7 ]]; then
        systemctl is-active --quiet awg-quick@awg0 2>/dev/null && _resume_awg0_active=1
        command -v ip >/dev/null 2>&1 \
            && ip link show dev awg0 >/dev/null 2>&1 && _resume_awg0_link=1
        if [[ "$_resume_awg0_active" -ne "$_resume_awg0_link" ]]; then
            die "Step 7 resume: awg0 has an ambiguous unit/link state; live networking was not changed."
        fi
        if [[ "$_resume_awg0_active" -eq 1 ]]; then
            [[ -f "$SERVER_CONF_FILE" && ! -L "$SERVER_CONF_FILE" ]] \
                || die "Step 7 resume: live awg0 has no regular managed config; networking was not changed."
            validate_awg_config "$SERVER_CONF_FILE" \
                || die "Step 7 resume: live awg0.conf failed strict validation; networking was not changed."
            timeout 10 awg-quick strip "$SERVER_CONF_FILE" >/dev/null 2>&1 \
                || die "Step 7 resume: live awg0.conf failed awg-quick strip; networking was not changed."
            check_service_status >/dev/null 2>&1 \
                || die "Step 7 resume: live awg0 failed its service postcondition; networking was not changed."
            verify_fork_egress_runtime 0 \
                || die "Step 7 resume: live fork egress does not match exact owned state; networking was not changed."
            _resume_owned_live=1
            log "Step 7 resume: exact live awg0 state is already verified; disruptive restart skipped."
        fi
    fi
    if [[ "$_resume_owned_live" -eq 0 ]]; then
        preflight_fork_policy_namespace \
            || die "Selected policy table/priority contains foreign or ambiguous routes/rules."
        arm_step7_upstream_rollback \
            || die "Could not arm reused-upstream rollback before resuming step 7."
    fi
    configure_awg0_dependency || die "Could not configure the awg0 boot dependency."

    # Bring the required egress up first. Requires/After preserves the same
    # order after reboot; the explicit start fails clearly before awg0 starts.
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        local _up="${AWG_UPSTREAM_IFACE:-awg1}"
        log "Enabling and starting awg-quick@${_up} (upstream cascade)..."
        systemctl enable --now "awg-quick@${_up}" \
            || die "awg-quick@${_up} did not start. Check: systemctl status awg-quick@${_up}"
        systemctl is-active --quiet "awg-quick@${_up}" \
            || die "Upstream tunnel ${_up} is not active; awg0 was left stopped."
    elif [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
        local _warp_unit="wg-quick@${AWG_WARP_IFACE:-wgcf}"
        log "Starting required WARP egress (${_warp_unit})..."
        systemctl start "$_warp_unit" \
            || die "$_warp_unit did not start; awg0 was left stopped."
        systemctl is-active --quiet "$_warp_unit" \
            || die "$_warp_unit is not active; awg0 was left stopped."
    fi

    log "Enabling and starting awg-quick@awg0..."

    # Isolation switched on->off: the new config's PostDown no longer has the
    # DROP rule to remove, and the restart's down phase already runs against
    # the new on-disk config. Remove stale rules explicitly, in a loop - a
    # repeated interrupted run may have left more than one (issue #178,
    # same deferred-cleanup pattern as PREV_AWG_PORT in #175).
    if [[ "${CLIENT_ISOLATION:-1}" -eq 0 ]]; then
        while iptables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
        while ip6tables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
    fi

    if [[ "$_resume_owned_live" -eq 1 ]]; then
        systemctl enable awg-quick@awg0 \
            || die "Could not enable the already verified awg-quick@awg0 unit."
    elif systemctl is-active --quiet awg-quick@awg0; then
        log "Service already active — restarting to apply configuration..."
        systemctl enable awg-quick@awg0 \
            || die "Failed to enable awg-quick@awg0; installation will not be marked complete."
        systemctl restart awg-quick@awg0 || die "restart awg-quick@awg0 error."
    else
        systemctl enable --now awg-quick@awg0 || die "enable --now error."
    fi
    log "Service enabled and started."

    log "Checking service status..."
    local _attempt
    for _attempt in 1 2 3 4 5; do
        sleep 1
        check_service_status 2>/dev/null && break
        [[ $_attempt -lt 5 ]] && log_debug "Waiting for service startup... (attempt $_attempt/5)"
    done
    check_service_status || die "Service status check failed."

    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then log "Upstream tunnel ${_up} started."; fi

    # Fail2Ban
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        setup_fail2ban
    else
        log "Skipping Fail2Ban (--no-tweaks)."
    fi

    verify_fork_egress_runtime \
        || die "Fork egress live verification failed: support/rule/blackhole/default route is incomplete."
    # Record the snapshot only after service + exact egress postconditions pass.
    awg_record_device_params
    # A signal must not split the critical UFW-delete → bypass/DNS
    # transactions → commit window. EXIT can restore every snapshot until
    # the installer explicitly closes them below.
    trap '' INT TERM
    if [[ "${AWG_ROLE:-single}" == "entry" ]] \
       && command -v ufw &>/dev/null && ! ufw status 2>/dev/null | grep -q inactive; then
        ensure_owned_cascade_ufw_route "${_up}" \
            || die "UFW: required owned route awg0→${_up} is ambiguous or could not be added; rolling back."
    fi
    if ! cleanup_pending_ufw_main_route_for_entry; then
        die "Could not remove the confirmed previous UFW awg0→main route; rolling back."
    fi

    # Bypass participates in the same install-level commit as awg0/WARP. Both
    # creating the requested bypass and removing a previous owned bundle start
    # with a full snapshot of files, unit state and exact kernel routes.
    if [[ "${AWG_EGRESS:-direct}" == "warp" && "${AWG_WARP_BYPASS:-none}" != "none" ]] \
       || [[ -e "$_bypass_marker" || -L "$_bypass_marker" ]] \
       || [[ "$_bypass_tx_prepared" -eq 1 ]]; then
        _bypass_tx_needed=1
    fi
    if [[ "$_bypass_tx_needed" -eq 1 ]]; then
        if [[ "$_bypass_tx_prepared" -eq 0 ]]; then
            declare -F snapshot_warp_bypass_state >/dev/null 2>&1 \
                && declare -F setup_warp_bypass >/dev/null 2>&1 \
                || die "The current awg_common.sh does not support transactional WARP bypass."
            snapshot_warp_bypass_state \
                || die "Could not create a complete WARP bypass snapshot before mutation."
            if [[ "${AWG_EGRESS:-direct}" == "warp" && "${AWG_WARP_BYPASS:-none}" != "none" ]]; then
                log "Transactionally configuring WARP bypass (${AWG_WARP_BYPASS})..."
            else
                log "Transactionally removing the previous installer-owned WARP bypass..."
            fi
            setup_warp_bypass \
                || die "WARP bypass did not reach the requested state; rolling back."
        fi
        verify_fork_egress_runtime 1 \
            || die "Fork egress failed the exact route/rule check after WARP bypass setup."
    fi

    # DNS is the final mandatory fallible setup. Its snapshot remains active
    # until the shared commit, so a later error restores the old awg0/gateway
    # first and then the previous resolver files, UFW rules and unit state.
    if [[ "${AWG_AMNEZIA_DNS:-off}" == "on" ]]; then
        log "Configuring AmneziaDNS (dnsmasq on the tunnel gateway)..."
        declare -F snapshot_amnezia_dns_state >/dev/null 2>&1 \
            && declare -F setup_amnezia_dns >/dev/null 2>&1 \
            || die "The current awg_common.sh does not support transactional AmneziaDNS."
        snapshot_amnezia_dns_state \
            || die "Could not arm the installer-level AmneziaDNS snapshot."
        if ! setup_amnezia_dns; then
            die "setup_amnezia_dns failed. See log."
        fi
    fi

    # Commit point: the new awg0 is active and fully verified. Cleanup failures
    # must not put the old config back over this working interface. Old
    # resources are removed best-effort and retain their markers on any error.
    _INSTALL_ROLLBACK_AWG0=0
    _INSTALL_ROLLBACK_UPSTREAM=0
    _INSTALL_ROLLBACK_DEP_ACTIVE=0
    _INSTALL_ROLLBACK_OLD_SUPPORT=0
    _INSTALL_ROLLBACK_UFW_CASCADE_RULE=0
    if [[ "$_INSTALL_ROLLBACK_UFW_MAIN_RULE" -eq 1 || "$_INSTALL_UFW_MAIN_MARKER_RESOLVED" -eq 1 ]]; then
        _INSTALL_ROLLBACK_UFW_MAIN_RULE=0
        _INSTALL_UFW_MAIN_MARKER_RESOLVED=0
        rm -f -- "$AWG_DIR/.ufw_main_cleanup_pending" \
            || log_warn "Post-commit: could not remove the UFW main-route marker."
    elif ufw_main_route_required \
         && [[ -e "$AWG_DIR/.ufw_main_cleanup_pending" || -L "$AWG_DIR/.ufw_main_cleanup_pending" ]]; then
        if [[ -f "$AWG_DIR/.ufw_main_cleanup_pending" && ! -L "$AWG_DIR/.ufw_main_cleanup_pending" ]]; then
            rm -f -- "$AWG_DIR/.ufw_main_cleanup_pending" \
                || log_warn "Post-commit: could not clear the no-longer-needed UFW main-route marker."
        else
            log_warn "Post-commit: unsafe UFW main-route marker retained."
        fi
    fi
    # Close every common transaction while INT/TERM are still blocked. These
    # commit hooks only remove snapshots: the working new awg0 is already
    # disarmed and must not fail because backup removal was incomplete.
    if declare -F commit_warp_bypass_state >/dev/null 2>&1; then
        commit_warp_bypass_state \
            || log_warn "Post-commit: could not remove the temporary WARP bypass snapshot."
    fi
    if declare -F commit_warp_egress_state >/dev/null 2>&1; then
        commit_warp_egress_state \
            || log_warn "Post-commit: could not remove the temporary WARP egress snapshot."
    fi
    if declare -F commit_amnezia_dns_state >/dev/null 2>&1; then
        commit_amnezia_dns_state \
            || log_warn "Post-commit: could not remove the temporary AmneziaDNS snapshot."
    fi
    # Parked proof stays on disk for best-effort/next-run cleanup, but after
    # commit INT/TERM must never restore it into the live ownership markers.
    _INSTALL_ROLLBACK_WARP_PARKED=0
    local _post_commit_cleanup_failed=0
    if [[ -n "${PREV_AWG_PORT:-}" && "$PREV_AWG_PORT" =~ ^[0-9]+$ \
          && "$PREV_AWG_PORT" != "$AWG_PORT" ]]; then
        if delete_owned_ufw_udp_allow_if_present "$PREV_AWG_PORT" "AmneziaWG VPN"; then
            log "Post-commit UFW: old port rule ${PREV_AWG_PORT}/udp removed."
            sed -i '/^export PREV_AWG_PORT=/d' "$CONFIG_FILE" 2>/dev/null \
                || log_warn "Could not remove PREV_AWG_PORT from $CONFIG_FILE."
            PREV_AWG_PORT=""
        else
            log_warn "Post-commit UFW: old port ${PREV_AWG_PORT}/udp was not removed; cleanup will be retried."
            _post_commit_cleanup_failed=1
        fi
    fi
    if [[ "${AWG_AMNEZIA_DNS:-off}" != "on" || "${AWG_ROLE:-single}" == "exit" ]]; then
        teardown_amnezia_dns || {
            log_warn "Post-commit cleanup: previous AmneziaDNS was not removed completely; new awg0 remains active."
            _post_commit_cleanup_failed=1
        }
    fi
    finalize_deferred_mode_cleanup || _post_commit_cleanup_failed=1
    if [[ "$_post_commit_cleanup_failed" -eq 1 ]]; then
        log_warn "The new awg0 is working, but some old owned resources were retained for a safe cleanup retry."
    fi

    log "Step 7 completed successfully."
    # Keep INT/TERM blocked until state=99 is durable. SIGKILL/power loss leaves
    # state=7, which the exact owned-live resume path recognizes safely.
    update_state 99
    trap '_install_on_signal 130' INT
    trap '_install_on_signal 143' TERM
}

# ==============================================================================
# STEP 99: Completion
# ==============================================================================

step99_finish() {
    log "### INSTALLATION COMPLETE ###"
    log "=============================================================================="
    log "AmneziaWG 2.0 installation and configuration COMPLETED SUCCESSFULLY!"
    log " "
    log "CLIENT FILES:"
    log "  Configs (.conf) and QR codes (.png) in: $AWG_DIR"
    log "  Copy them securely."
    log "  Example (on your PC):"
    log "    scp root@<SERVER_IP>:$AWG_DIR/*.conf ./"
    log " "
    log "USEFUL COMMANDS:"
    log "  sudo bash $MANAGE_SCRIPT_PATH help   # Client management"
    log "  systemctl status awg-quick@awg0      # VPN status"
    log "  awg show                              # AmneziaWG status"
    log "  ufw status verbose                    # Firewall status"
    log " "
    log "IMPORTANT: Use Amnezia VPN client >= 4.8.12.7 to connect"
    log "           with AWG 2.0 protocol support"
    log " "
    cleanup_apt
    log " "

    # Final checks
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Settings file $CONFIG_FILE: OK"
    else
        log_error "Settings file $CONFIG_FILE MISSING!"
    fi

    # Remove state file
    log "Removing installation state file..."
    # The protected package snapshot goes too: it is needed between the steps,
    # but surviving the install it would only grow stale. A stale name (a
    # package renamed by a release upgrade) would stop the next install for no
    # reason the user can see.
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$AWG_DIR/.boot_id_before_step2" \
          "$BOOT_CRITICAL_SNAPSHOT_FILE" || log_warn "Failed to remove $STATE_FILE"
    log "Installation fully completed. Log: $LOG_FILE"
    log "=============================================================================="
}

# ==============================================================================
# Main execution loop
# ==============================================================================

if [[ "$HELP" -eq 1 ]]; then show_help; fi
if [[ "$UNINSTALL" -eq 1 ]]; then
    [[ "$(id -u)" -eq 0 ]] || die "Uninstall requires root (sudo bash $0 --uninstall)."
    mkdir -p "$AWG_DIR" || die "Could not open working directory $AWG_DIR."
    INSTALL_LOCK_FILE="$AWG_DIR/.install.lock"
    exec 9>"$INSTALL_LOCK_FILE" || die "Cannot open $INSTALL_LOCK_FILE"
    flock -n 9 || die "Another install/uninstall is already running. Wait for it to finish."
    touch "$LOG_FILE" && chmod 640 "$LOG_FILE" || die "Could not prepare $LOG_FILE."
    step_uninstall
fi
if [[ "$DIAGNOSTIC" -eq 1 ]]; then create_diagnostic_report; exit 0; fi
if [[ "$VERBOSE" -eq 1 ]]; then set -x; fi

# v5.13.0: idempotency guard — if AmneziaWG is already installed and
# running, a re-run wastes ~20 minutes (Step 1 re-tunes sysctl/swap/BBR,
# `apt-get upgrade` can pull a new kernel and force another reboot, Step 7
# restarts awg-quick@awg0 — handshakes drop for a few seconds). Server
# keys, peers and obfuscation parameters survive a re-run, but without
# explicit opt-in this behaviour looks like a silent reinstall. Guarded by
# an explicit flag.
# AWG_FORCE_REINSTALL=1 in the environment is equivalent to --force.
if [[ "${AWG_FORCE_REINSTALL:-0}" == "1" ]]; then
    FORCE_REINSTALL=1
fi
# A valid unfinished setup_state takes precedence over the idempotency guard:
# after a forced reinstall reboot the user does not have to repeat --force.
_resume_install_in_progress=0
if [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]]; then
    IFS= read -r _resume_state < "$STATE_FILE" || _resume_state=""
    [[ "$_resume_state" =~ ^[1-7]$ ]] && _resume_install_in_progress=1
fi
if [[ "$FORCE_REINSTALL" -ne 1 && "$_resume_install_in_progress" -ne 1 ]] && [[ -f "$SERVER_CONF_FILE" ]] \
   && systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
    log_error "AmneziaWG is already installed and running."
    log_error "To reinstall — pass --force (or AWG_FORCE_REINSTALL=1)."
    log_error "WARNING: a reinstall will rerun Step 1 (sysctl/swap/BBR) and Step 7 (service restart)."
    log_error "         Obfuscation parameters (Jc/Jmin/Jmax/H1-H4/I1) survive UNLESS you pass"
    log_error "         --preset/--jc/--jmin/--jmax (those flags regenerate the whole set - every"
    log_error "         issued client config would have to be reissued via regen)."
    log_error "To manage clients:  sudo bash $MANAGE_SCRIPT_PATH help"
    log_error "To fully uninstall: sudo bash $0 --uninstall"
    exit 0
fi

initialize_setup

while (( current_step < 99 )); do
    log "Executing step $current_step..."
    case $current_step in
        1) step1_update_and_optimize ;;
        2) step2_install_amnezia ;;
        3) step3_check_module; current_step=4 ;;
        4) step4_setup_firewall; current_step=5 ;;
        5) step5_download_scripts; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service; current_step=99 ;;
        *) die "Error: Unknown step $current_step." ;;
    esac
done

if (( current_step == 99 )); then step99_finish; fi
exit 0
