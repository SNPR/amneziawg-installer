#!/bin/bash

# ==============================================================================
# Shared function library for AmneziaWG 2.0
# Author: @bivlked
# Version: 5.28.1
# Date: 2026-08-27
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================
#
# This file contains shared functions for key generation, config rendering,
# peer management, and working with AWG 2.0 parameters.
# Intended to be included via source from the install and manage scripts.
# ==============================================================================

# --- Constants (can be overridden before source) ---
AWG_DIR="${AWG_DIR:-/root/awg}"
CONFIG_FILE="${CONFIG_FILE:-$AWG_DIR/awgsetup_cfg.init}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
KEYS_DIR="${KEYS_DIR:-$AWG_DIR/keys}"

# Library version. The manage script compares it against its own by MAJOR.MINOR
# after sourcing and dies with a clear message if awg_common.sh and manage have
# drifted apart (one file updated, the other not) - otherwise the mismatch shows
# up as a "command not found" somewhere random. Bumped with the other versions.
# shellcheck disable=SC2034  # used by the manage script after sourcing
AWG_COMMON_VERSION="5.28.1"

# --- Auto-cleanup of temporary files ---
# NOTE: trap is NOT set here to avoid overwriting the caller's trap handler.
# The calling script must invoke _awg_cleanup() in its own EXIT handler.
_AWG_TEMP_FILES=()
# File-backed temp registry: awg_mktemp is usually called via $(...) (a
# subshell), where the _AWG_TEMP_FILES array mutation is lost in the parent. A
# file survives the subshell, so _awg_cleanup can reliably remove even a temp
# created inside command substitution (e.g. an interrupted config write between
# mktemp and mv). $$ is the calling script's PID, stable across its subshells.
# The registry lives in $AWG_DIR (root-only 0700), NOT in world-writable /tmp:
# a predictable name in /tmp would let a local user pre-plant a file listing
# arbitrary paths, which _awg_cleanup would then delete as root.
_AWG_TEMP_REGISTRY="${AWG_DIR}/.awg_temp_registry.$$"

_awg_cleanup() {
    local f
    for f in "${_AWG_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    # File-backed public IP cache (see get_server_public_ip) - per-PID, clean it up.
    rm -f "${AWG_DIR}/.public_ip.cache.$$" 2>/dev/null
    # Guard against symlink substitution of the registry: read regular files only.
    if [[ -n "${_AWG_TEMP_REGISTRY:-}" && -f "$_AWG_TEMP_REGISTRY" && ! -L "$_AWG_TEMP_REGISTRY" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" && -f "$f" ]] && rm -f "$f"
        done < "$_AWG_TEMP_REGISTRY"
        rm -f "$_AWG_TEMP_REGISTRY"
    fi
}

# mktemp wrapper with auto-cleanup.
# Optional 1st argument - target directory: the temp file is created in the same
# directory where the final file will live, so the subsequent mv is an atomic
# rename within one filesystem rather than a cross-fs copy+unlink (matters when
# /tmp is mounted as tmpfs). With no argument the behaviour is unchanged (/tmp
# or $TMPDIR) - backward compatible.
awg_mktemp() {
    local dir="${1:-}" f
    if [[ -n "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null
        f=$(mktemp -p "$dir") || return 1
    else
        f=$(mktemp) || return 1
    fi
    _AWG_TEMP_FILES+=("$f")
    # Mirror the path into the file registry - it survives a subshell
    # ($(awg_mktemp ...)), unlike the array above.
    [[ -n "${_AWG_TEMP_REGISTRY:-}" ]] && printf '%s\n' "$f" >> "$_AWG_TEMP_REGISTRY" 2>/dev/null
    echo "$f"
}

# --- Logging stubs (overridden by the calling script) ---
if ! declare -f log >/dev/null 2>&1; then
    log()       { echo "[INFO] $1"; }
    log_warn()  { echo "[WARN] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_debug() { echo "[DEBUG] $1"; }
fi

# ==============================================================================
# Utilities
# ==============================================================================

# --- IP / CIDR validators (shared by install and manage) ---
# These check numeric ranges, not just shape: IPv4 octets 0-255, IPv4 prefix
# 0-32, IPv6 0-128. A bare address (no prefix) is valid (wireguard-tools treats
# a bare IPv4 as /32 and a bare IPv6 as /128 - a host route).

# _valid_ipv4 <addr> : exactly 4 octets, each 0-255 (10# avoids a leading-zero
# octet being read as octal inside (( )) ).
_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

# Canonical textual IPv4 accepted by inet_pton(3): no leading zeroes except
# for the single digit zero itself.  Generated quick configs use this stricter
# form so preflight cannot disagree with awg/iproute2 parsing after a stop.
_valid_canonical_ipv4() {
    _valid_ipv4 "$1" || return 1
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]
}

# _valid_ipv6 <addr> : structural check (not just charset). Allows one "::"
# compression; without it requires exactly 8 groups of 1-4 hex digits, with it
# at most 7. Embedded IPv4 (::ffff:1.2.3.4) is intentionally unsupported - it
# does not occur in tunnel AllowedIPs and the dots are rejected by the charset.
_valid_ipv6() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    case "$ip" in
        *:::*)   return 1 ;;                     # three or more ":" in a row
        *::*::*) return 1 ;;                     # more than one "::"
    esac
    [[ "$ip" == :* && "$ip" != ::* ]] && return 1   # lone leading ":"
    [[ "$ip" == *: && "$ip" != *:: ]] && return 1   # lone trailing ":"
    local has_dcolon=0
    [[ "$ip" == *::* ]] && has_dcolon=1
    local IFS=':' parts=() p ngroups=0
    read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do
        [[ -z "$p" ]] && continue                 # empty fields from "::"
        [[ "$p" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        (( ngroups++ ))
    done
    if [[ $has_dcolon -eq 1 ]]; then
        (( ngroups <= 7 )) || return 1            # "::" stands for >=1 group
    else
        (( ngroups == 8 )) || return 1
    fi
    return 0
}

# _valid_cidr <token> : IPv4/IPv6 address with an optional prefix. If present,
# the prefix must be a number in range (IPv4 0-32, IPv6 0-128). An empty prefix
# after "/" (e.g. "1.2.3.4/") is rejected.
_valid_cidr() {
    local tok="$1" addr prefix
    if [[ "$tok" == */* ]]; then
        addr="${tok%/*}"; prefix="${tok##*/}"
        [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    else
        addr="$tok"; prefix=""
    fi
    if _valid_ipv4 "$addr"; then
        [[ -z "$prefix" ]] && return 0
        (( 10#$prefix <= 32 )) || return 1
        return 0
    elif _valid_ipv6 "$addr"; then
        [[ -z "$prefix" ]] && return 0
        (( 10#$prefix <= 128 )) || return 1
        return 0
    fi
    return 1
}

# _valid_host_or_ipv4 <host> : for Endpoint - a valid IPv4 OR an FQDN.
_valid_host_or_ipv4() {
    local host="$1" label
    _valid_canonical_ipv4 "$host" && return 0
    (( ${#host} >= 1 && ${#host} <= 253 )) || return 1
    [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1
    local IFS=.
    read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
    done
    # An all-numeric last label is not a real TLD (RFC 3696) but more likely a
    # malformed IPv4 (e.g. "999.1.1.1"); reject it so a typo'd IP is not accepted.
    local last="${host##*.}"
    [[ "$last" =~ ^[0-9]+$ ]] && return 1
    return 0
}

# The port from the config cannot be trusted before it is checked: both
# awgsetup_cfg.init and the ListenPort in the live awg0.conf are hand-edited and
# end up holding anything. The value goes into the 'Endpoint = IP:PORT' line of
# the client .conf (add/regen), into JSON unquoted ("number":abc does not parse)
# and into arithmetic comparisons (where bash runs command substitution from a
# value like a[$(...)]) in check, and into the UFW rule regex in diagnose. A
# function, not two lines in place: this way the test runs the real code.
_sanitize_port() {
    local p="${1:-}"
    # Surrounding whitespace is trimmed: 'AWG_PORT=39743 ' is an ordinary
    # leftover of a hand edit and means the same port. Such a config used to
    # fail the check for nothing.
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    # {1,5} rules out 64-bit arithmetic overflow: a long digit string would
    # quietly land inside the valid range. 10# rules out octal reading of
    # values with a leading zero (0070 would otherwise be 56).
    if [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )); then
        printf '%s' "$((10#$p))"
    else
        printf '0'
    fi
}

# --- CIDR arithmetic (shared by the IPv4/IPv6 allocator) ---
# Pure functions, bash arithmetic only ($(( ))), no external dependencies.
# set-e-safe: read values via $(( ))/local, guard with "|| return".

# _ipv4_to_int <a.b.c.d> : 32-bit integer from IPv4. Input guard is _valid_ipv4
# (do not reinvent octet checks). 10# guards against a leading-zero octet being
# parsed as octal.
_ipv4_to_int() {
    _valid_ipv4 "$1" || return 1
    local IFS=. o
    read -ra o <<< "$1"
    echo $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}

# _int_to_ipv4 <int> : IPv4 from a 32-bit integer.
_int_to_ipv4() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# _cidr_bounds <addr/prefix> : prints "network_int broadcast_int".
# The single source of the network/broadcast formula in awg_common.
_cidr_bounds() {
    local cidr="$1" addr prefix ip mask net bcast
    addr="${cidr%/*}"; prefix="${cidr##*/}"
    [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
    (( 10#$prefix >= 0 && 10#$prefix <= 32 )) || return 1
    ip=$(_ipv4_to_int "$addr") || return 1
    if (( 10#$prefix == 0 )); then mask=0; else mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF )); fi
    net=$(( ip & mask ))
    bcast=$(( net | (0xFFFFFFFF ^ mask) ))
    echo "$net $bcast"
}

# _awg_network_cidr <addr/prefix>: canonical IPv4 CIDR (network/prefix).
# Policy-routing shell hooks consume this value, so an address from the init
# file must not be normalized with string operations that only work for /24.
_awg_network_cidr() {
    local cidr="$1" prefix net bcast
    prefix="${cidr##*/}"
    read -r net bcast < <(_cidr_bounds "$cidr" 2>/dev/null) || return 1
    [[ -n "$net" && "$prefix" =~ ^[0-9]+$ ]] || return 1
    printf '%s/%s' "$(_int_to_ipv4 "$net")" "$((10#$prefix))"
}

# Detect primary (egress) network interface.
# Fallback chain so we don't abort on hosts where the 1.1.1.1 probe returns no
# interface: the provider null-routes/blocks the address, policy-routing, or
# IPv6-only egress (seen on Ubuntu 26.04 / Timeweb, issue #166).
# Manual override: export AWG_MAIN_NIC=<iface> before running.
get_main_nic() {
    # Accept a manual override only if it is an existing, safe ifname: the value
    # ends up in PostUp/PostDown (iptables -o ...), so reject names with shell
    # metacharacters and non-existent interfaces (fall through to auto-detect).
    if [[ -n "${AWG_MAIN_NIC:-}" ]]; then
        if [[ "$AWG_MAIN_NIC" =~ ^[A-Za-z0-9._-]+$ ]] \
            && ip link show dev "$AWG_MAIN_NIC" &>/dev/null; then
            printf '%s\n' "$AWG_MAIN_NIC"
            return 0
        fi
        # Reject an invalid override LOUDLY (log_warn goes to stderr, so the $()
        # output stays clean): a silent fall-through would confuse a user who
        # already followed the export AWG_MAIN_NIC=... hint with a typo.
        log_warn "AWG_MAIN_NIC='${AWG_MAIN_NIC}' ignored: interface not found or the name is invalid - continuing with auto-detection."
    fi
    local nic
    # 1) Real egress to a public address (FIB lookup, fast path for most hosts).
    nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # 2) Default IPv4 route (when the probe is unreachable/blocked).
    [[ -z "$nic" ]] && nic=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # 3) First UP interface with a global IPv4 (no default route). Exclude
    #    tunnel/virtual interfaces (awg0 itself is UP with a 10.x scope-global
    #    address on a --force reinstall, docker0/br-*/veth* on container hosts):
    #    otherwise the NAT would hairpin through the tunnel itself, and the
    #    IPv6-only warning would be silently suppressed (awg0 has a global IPv4).
    [[ -z "$nic" ]] && nic=$(ip -o -4 addr show up scope global 2>/dev/null \
        | awk '{sub(/@.*/,"",$2); if ($2!="lo" && $2 !~ /^(awg|wg|docker|br-|virbr|veth|lxc|tun|tap)/) { print $2; exit }}')
    # 4) Default IPv6 route (IPv6-only egress).
    [[ -z "$nic" ]] && nic=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$nic" ]] || return 1
    printf '%s\n' "$nic"
}

# Returns 0 if the host has no IPv4 egress: no default IPv4 route AND interface
# $1 has no global IPv4 address. Such a host is IPv6-only (issue #166: Timeweb
# Ubuntu 26.04) - the IPv4 tunnel (10.x) cannot be NATed out. Both conditions
# must hold: on dual-stack/IPv4 hosts the function returns 1.
host_lacks_ipv4_egress() {
    local nic="$1"
    # [[ -z $(...) ]] instead of "| grep -q .": grep -q exits on the first line,
    # and under pipefail a multi-line ip output (several default routes) could
    # yield SIGPIPE=141 -> a spurious "no route" on a healthy dual-stack host.
    [[ -z "$(ip -4 route show default 2>/dev/null)" ]] \
        && [[ -z "$(ip -o -4 addr show dev "$nic" up scope global 2>/dev/null)" ]]
}

# Detect server public IP (with caching).
#
# The 6-service list covers common NAT and cloud scenarios without
# hard ranking by uptime: ifconfig.me has been historically stable on
# regular VPS (Hetzner, Vultr, OVH), checkip.amazonaws.com remains
# reachable from AWS / GCP / OCI private subnets behind a NAT Gateway,
# ipinfo.io / icanhazip / ifconfig.io are extra fallbacks against
# rate-limit on any single endpoint. Order is alphabetical (deterministic
# for tests and diffs). First-wins: when one service returns a valid IP,
# the rest are skipped.
_CACHED_PUBLIC_IP=""
# File-backed twin of the cache: get_server_public_ip is almost always called
# as $(...) (a subshell), where the _CACHED_PUBLIC_IP assignment is lost in the
# parent and the cache variable never kicks in. A PID-suffixed file survives
# the subshell (same trick as _AWG_TEMP_REGISTRY) and is removed in
# _awg_cleanup. Without it `manage regen` over N clients would do N curl
# rounds (up to 6 services at 5 sec each) when AWG_ENDPOINT is empty.
_PUBLIC_IP_CACHE="${AWG_DIR}/.public_ip.cache.$$"
get_server_public_ip() {
    if [[ -n "$_CACHED_PUBLIC_IP" ]]; then
        echo "$_CACHED_PUBLIC_IP"
        return 0
    fi
    if [[ -f "$_PUBLIC_IP_CACHE" && ! -L "$_PUBLIC_IP_CACHE" ]]; then
        local cached
        cached=$(<"$_PUBLIC_IP_CACHE")
        if [[ -n "$cached" ]] && _valid_ipv4 "$cached"; then
            _CACHED_PUBLIC_IP="$cached"
            echo "$cached"
            return 0
        fi
    fi
    local ip="" svc
    for svc in \
        https://api.ipify.org \
        https://checkip.amazonaws.com \
        https://icanhazip.com \
        https://ifconfig.io \
        https://ifconfig.me \
        https://ipinfo.io/ip
    do
        ip=$(curl -4 -sf --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$ip" ]] && _valid_ipv4 "$ip"; then
            _CACHED_PUBLIC_IP="$ip"
            printf '%s\n' "$ip" > "$_PUBLIC_IP_CACHE" 2>/dev/null || true
            # Observability: write trace to LOG_FILE directly. Never to stdout
            # (the function's stdout IS the IP; any extra bytes corrupt the
            # caller's $(get_server_public_ip) capture and the generated
            # client Endpoint line).
            if [[ -n "${LOG_FILE:-}" && -w "$(dirname "${LOG_FILE}")" ]]; then
                printf '[%s] DEBUG: public IP detected: %s (via %s)\n' \
                    "$(date +'%F %T')" "$ip" "$svc" >>"$LOG_FILE" 2>/dev/null || true
            fi
            echo "$ip"
            return 0
        fi
    done
    if [[ -n "${LOG_FILE:-}" && -w "$(dirname "${LOG_FILE}")" ]]; then
        printf '[%s] DEBUG: public IP detection failed (all 6 services unreachable or invalid)\n' \
            "$(date +'%F %T')" >>"$LOG_FILE" 2>/dev/null || true
    fi
    echo ""
    return 1
}

# Fallback: first non-loopback IPv4 on a network interface.
# Used when curl to ifconfig.me / ipify / ... does not go through
# (LXC without egress, outbound firewall, etc.). On bare metal / regular
# VPS this usually matches the public IP; on a NAT'd host it returns a
# private address — in that case the caller must emit log_warn so the
# user can hand-edit the Endpoint in the client .conf files.
_try_local_ip() {
    local ip
    ip=$(ip -4 -o addr show scope global 2>/dev/null \
        | awk '{print $4}' \
        | cut -d/ -f1 \
        | grep -v '^127\.' \
        | head -1)
    { [[ -n "$ip" ]] && _valid_ipv4 "$ip"; } || return 1
    echo "$ip"
    return 0
}

# Note: apt_update_tolerant() is defined inline in install_amneziawg_en.sh
# (needed in steps 1-2 before this file is downloaded). Not duplicated here.

# ==============================================================================
# AWG 2.0 parameter generation (used in tests + manage)
# ==============================================================================

# Random number [min, max] via /dev/urandom (uint32 support).
# Mirrors install_amneziawg_en.sh:rand_range — needed here for tests and regen.
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
# Minimum width per range = 1000.
# Prints 4 "low-high" lines to stdout. Returns 1 on failure.
# Mitigates Russian DPI fingerprinting of static H values (#38).
#
# Range: [0, 2^31-1] = [0, 2147483647]. The AmneziaWG spec allows the
# full uint32 (0-4294967295), but the standalone Windows client
# `amneziawg-windows-client` has a UI validator capped at 2^31-1 in
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, not yet fixed). Values
# above 2^31-1 work on the server, but the client's config editor
# underlines them as invalid and blocks saving. For compatibility we
# generate in the safe half of the range (#40).
#
# Optimization: a single `od -N32 -tu4` call reads 32 bytes = 8 uint32
# values in one operation, instead of 8 separate subprocess calls via
# rand_range. Falls back to rand_range if /dev/urandom is unavailable.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        # One 32-byte read from /dev/urandom = 8 uint32 values
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
        # Fallback: 8 separate rand_range calls (if urandom unavailable)
        if (( ${#arr[@]} != 8 )); then
            arr=()
            local _i
            for _i in 1 2 3 4 5 6 7 8; do
                arr+=("$(rand_range 0 2147483647)")
            done
        fi
        # Sort
        local sorted
        sorted=$(printf '%s\n' "${arr[@]}" | sort -n)
        arr=()
        while IFS= read -r _v; do arr+=("$_v"); done <<< "$sorted"
        # Check: minimum width per pair, strict gap between pairs (no
        # touching bounds) and lower bound outside the reserved values 1-4
        # (vanilla WireGuard message types).
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

# ==============================================================================
# DKMS / amneziawg kernel module auto-recovery
# ==============================================================================

# awg_module_version : version of the amneziawg module (empty string if it
# cannot be determined). Asks the LOADED module first, the file second.
#
# ⚠️ Why not just modinfo: modinfo reads the metadata of the .ko that was
# SELECTED on disk via modules.dep, not of the object running in the kernel.
# Normally these are the same, which is why the divergence never surfaced. But
# if a host ends up with TWO trees carrying a module of the same name - the
# pinned 2.0 in extra/ and DKMS 3.0 in updates/dkms/ - modinfo reports whichever
# won the search order, while a different one may be loaded (for instance the
# previous one, before a reboot). Our own diagnostics would then name a version
# that is not in the kernel.
# /sys/module/amneziawg/version reflects exactly what is loaded, and it exists
# in BOTH lines: MODULE_VERSION(WIREGUARD_VERSION) is declared in src/main.c in
# the pinned 2.0 tag as well as in 3.0.
# modinfo stays as the second path - it works when the module is not loaded.
#
# AWG_MODULE_VERSION_PATH is overridden by tests (bats) only: /sys cannot be
# faked otherwise, and the priority "loaded beats file" is exactly what needs
# verifying.
awg_module_version() {
    local ver="" sysfile="${AWG_MODULE_VERSION_PATH:-/sys/module/amneziawg/version}"
    if [[ -r "$sysfile" ]]; then
        # ⚠️ `|| true`, NOT `|| ver=""`: on a file without a trailing newline
        # read returns 1 having ALREADY assigned what it read. Resetting to an
        # empty string would wipe a correct value and silently fall to modinfo.
        # ⚠️ And `2>/dev/null` comes BEFORE `<`, not after: redirections are
        # applied left to right, so with the opposite order a file-open error
        # still reaches the original stderr - verified, a raw `bash: ...` line
        # appeared in the middle of `manage check` output.
        IFS= read -r ver 2>/dev/null < "$sysfile" || true
        ver="${ver//[[:space:]]/}"
        # 🔴 The file was readable, so answer with what it gave, even if that
        # is empty, and do NOT fall through to modinfo. Substituting the on-disk
        # answer is exactly what this function exists to avoid: with two trees
        # modinfo names a version that is not in the kernel, and diagnose would
        # then declare a protocol line from it. An empty version is more honest
        # than a wrong one - consumers print the line without a version.
        printf '%s' "$ver"
        return 0
    fi
    ver=$(modinfo amneziawg 2>/dev/null | awk '/^version:/{print $2; exit}')
    printf '%s' "$ver"
}

#
# After an apt kernel upgrade the DKMS module must be rebuilt for the new
# kernel. If that did not happen automatically (or the module was unbound),
# the 4 functions below perform an idempotent recovery:
#
#   _sanitize_awg_dkms_conf       — strip the deprecated REMAKE_INITRD= directive
#   _install_kernel_headers       — distro-aware fallback chain (Ubuntu/Debian)
#   _ensure_awg_quick_running     — start awg-quick@awg0 if inactive
#   ensure_amneziawg_kernel_module — master, public entry point
#
# === Use context and safety contract ===
#
# Master ensure_amneziawg_kernel_module() assumes that the running kernel
# (uname -r) is the target kernel — i.e. it is suited for post-reboot
# contexts only: manage repair-module, manage add/remove (after the user
# rebooted), the systemd unit (which fires at boot when the new kernel is
# already running). From a DPkg::Post-Invoke hook uname -r still returns the
# OLD kernel — for that case the Phase 3 apt-hook helper will use a separate
# wrapper that iterates target kernels via /lib/modules/*/build.
#
# Master does NOT call apt-get install by default (deadlock in any context
# where a parent process holds /var/lib/dpkg/lock-frontend). The apt step is
# gated by the AWG_ALLOW_APT_IN_ENSURE=1 environment variable, which is set
# only by install_amneziawg step 2 / manage repair-module. The apt hook
# helper and the systemd unit do NOT set it; master skips the headers step.
#
# Headers must be set up separately at install time via a meta-package
# (linux-headers-$(arch) on Debian, linux-headers-generic on Ubuntu) — apt
# then pulls matching headers automatically on apt kernel upgrade.

# Strip the deprecated REMAKE_INITRD= directive from the amneziawg dkms.conf.
# Modern DKMS versions consider it deprecated and print noisy warnings.
_sanitize_awg_dkms_conf() {
    local conf
    for conf in /var/lib/dkms/amneziawg/*/source/dkms.conf; do
        [[ -f "$conf" ]] && sed -i '/^REMAKE_INITRD=/d' "$conf"
    done
}

# Install a kernel headers package via a distro-aware fallback chain.
# Argument: kernel version (defaults to $(uname -r)).
# Returns: 0 if at least one candidate installed successfully, 1 if all failed.
#
# IMPORTANT: only call from contexts where the apt lock is available
# (install_amneziawg step 2 or manage repair-module). MUST NOT be called from
# the DPkg::Post-Invoke hook.
#
# Recognises Raspberry Pi Foundation kernels (+rpt/-rpi suffix):
# linux-headers-rpi-2712 (Pi 5 / Cortex-A76) or linux-headers-rpi-v8 (Pi 3/4 arm64).
_install_kernel_headers() {
    # Defense-in-depth: this function calls apt-get install and must never
    # run from a hook context (deadlock on dpkg lock). Master already gates
    # it via AWG_ALLOW_APT_IN_ENSURE, but the _ prefix is not enforced — the
    # same gate is added here so an accidental direct call from a third-party
    # script still cannot bypass the protection.
    if [[ "${AWG_ALLOW_APT_IN_ENSURE:-0}" != "1" ]]; then
        log_error "_install_kernel_headers: AWG_ALLOW_APT_IN_ENSURE is not set — apt invocation forbidden in this context."
        return 1
    fi

    local kernel_ver="${1:-$(uname -r)}"
    local candidates=()

    # RPi Foundation kernel (suffix +rpt or -rpi) — separate meta-package
    # regardless of distro. Pattern check order: 2712 → v7l → v7 → v8 (default).
    if [[ "$kernel_ver" == *+rpt* || "$kernel_ver" == *-rpi* ]]; then
        if [[ "$kernel_ver" == *2712* ]]; then
            candidates+=("linux-headers-rpi-2712")  # Pi 5 / Cortex-A76
        elif [[ "$kernel_ver" == *-rpi-v7l* ]]; then
            candidates+=("linux-headers-rpi-v7l")   # armhf 32-bit (LPAE)
        elif [[ "$kernel_ver" == *-rpi-v7* ]]; then
            candidates+=("linux-headers-rpi-v7")    # armhf 32-bit older
        else
            candidates+=("linux-headers-rpi-v8")    # Pi 3/4 arm64 default
        fi
    fi

    case "${OS_ID:-}" in
        ubuntu)
            candidates+=(
                "linux-headers-${kernel_ver}"
                "linux-headers-generic"
                "raspberrypi-kernel-headers"
            )
            ;;
        debian)
            local arch
            arch=$(dpkg --print-architecture 2>/dev/null)
            candidates+=("linux-headers-${kernel_ver}")
            if [[ -n "$arch" ]]; then
                # Debian cloud images use a dedicated meta-package
                # linux-headers-cloud-${arch} instead of the generic
                # linux-headers-${arch} (different kernel ABI — sched/IRQ
                # timers trimmed for VMs). Prefer cloud-meta when the
                # running kernel is explicitly a cloud build — otherwise
                # repair-module fails on AWS/Azure/GCP/cloud-Hetzner after
                # a kernel upgrade, even though headers are available via
                # the cloud meta-package.
                if [[ "$kernel_ver" == *-cloud-* ]]; then
                    candidates+=("linux-headers-cloud-${arch}")
                fi
                candidates+=("linux-headers-${arch}")
            fi
            ;;
        *)
            log_error "Installing kernel headers: unknown OS_ID='${OS_ID:-}' (only ubuntu/debian are supported)."
            return 1
            ;;
    esac

    local pkg
    for pkg in "${candidates[@]}"; do
        if apt-get install -y "$pkg" >/dev/null 2>&1; then
            log "Installed kernel headers: $pkg"
            return 0
        fi
        log_warn "Failed to install $pkg, trying next candidate..."
    done
    log_error "Failed to install any kernel headers package (${candidates[*]})."
    return 1
}

# Start awg-quick@<iface> if the service is inactive.
# Argument: interface name (defaults to awg0).
# Returns: 0 on successful start or if already active, 1 on failure.
_ensure_awg_quick_running() {
    local iface="${1:-awg0}"
    local svc="awg-quick@${iface}.service"

    if systemctl is-active --quiet "$svc"; then
        return 0
    fi

    log "Starting $svc (was inactive)..."
    if systemctl start "$svc"; then
        log "$svc started."
        return 0
    fi
    log_error "Failed to start $svc. Details: systemctl status $svc"
    return 1
}

# Master: ensure that the amneziawg kernel module is built and loaded for the running kernel.
# Idempotent: fast-path returns 0 if the module is already loaded.
#
# Argument: mode — "full" (default: module + start awg-quick) or
#                  "module-only" (module only, no service start).
#
# IMPORTANT: master is intended for post-reboot contexts (manage repair-module,
# manage add/remove after a reboot, the systemd unit at boot). Apt/dpkg hook
# code MUST NOT call master — uname -r inside Post-Invoke still returns the
# OLD kernel, so the hook must use a separate wrapper that iterates target
# kernels via /lib/modules/*/build (Phase 3 helper).
#
# Environment: AWG_ALLOW_APT_IN_ENSURE=1 enables the kernel-headers install step
# via apt-get install (dangerous in hook context — deadlock on dpkg lock).
# When unset → headers step is skipped with a warning (assumes headers are
# already on disk via the linux-headers-$(arch) meta-package).
#
# When needed, runs a 5-step recovery:
#   headers → sanitize → dkms autoinstall → depmod → modprobe.
#
# Returns:
#   0 — module loaded successfully (and in "full" mode awg-quick is active).
#   1 — final modprobe failed, or invalid mode argument
#       (with a 4-step manual recovery printed to the log).
#   2 - "full" mode only: the module is fine but awg-quick@awg0 did not
#       start (a service problem: broken config, busy port, etc.).
#       Previously this was swallowed into log_warn + return 0 and
#       repair-module claimed "service is active" while it was down
#       (Issue #175).
ensure_amneziawg_kernel_module() {
    local mode="${1:-full}"
    case "$mode" in
        full|module-only) ;;
        *)
            log_error "ensure_amneziawg_kernel_module: invalid mode '$mode' (expected 'full' or 'module-only')."
            return 1
            ;;
    esac
    local kernel_ver
    kernel_ver="$(uname -r)"

    # Fast-path: module already loaded.
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
        if [[ "$mode" == "full" ]]; then
            _ensure_awg_quick_running awg0 || {
                log_warn "Module is active but awg-quick@awg0 did not start (module OK, this is a service issue)."
                return 2
            }
        fi
        return 0
    fi

    # Module on disk for the running kernel — try modprobe before full repair.
    if find "/lib/modules/${kernel_ver}" -name 'amneziawg.ko*' -print -quit 2>/dev/null | grep -q .; then
        if modprobe amneziawg 2>/dev/null && \
           lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
            log "amneziawg module found on disk and loaded successfully."
            if [[ "$mode" == "full" ]]; then
                _ensure_awg_quick_running awg0 || {
                    log_warn "Module loaded but awg-quick@awg0 did not start (module OK, this is a service issue)."
                    return 2
                }
            fi
            return 0
        fi
    fi

    log_warn "amneziawg module is not loaded and not built for kernel ${kernel_ver}."
    log_warn "Starting automatic recovery..."

    # Step 1: kernel headers — only when apt is allowed by the calling context.
    if [[ "${AWG_ALLOW_APT_IN_ENSURE:-0}" == "1" ]]; then
        case "${OS_ID:-}" in
            ubuntu|debian)
                local headers_pkg="linux-headers-${kernel_ver}"
                if ! dpkg-query -W -f='${Status}' "$headers_pkg" 2>/dev/null | grep -q 'install ok installed'; then
                    log "Kernel headers ($headers_pkg) are not installed. Installing..."
                    _install_kernel_headers "$kernel_ver" || \
                        log_warn "Failed to install kernel headers. The DKMS module build may fail."
                fi
                ;;
        esac
    elif [[ ! -d "/lib/modules/${kernel_ver}/build" ]]; then
        log_warn "/lib/modules/${kernel_ver}/build is missing, headers are not installed."
        log_warn "Apt install skipped (context does not allow apt). The DKMS build will most likely fail."
    fi

    # Step 2: strip the deprecated REMAKE_INITRD from dkms.conf
    _sanitize_awg_dkms_conf

    # Step 3: dkms autoinstall for the running kernel.
    # If this step reports an error, still try modprobe below — that's the definitive check.
    if command -v dkms >/dev/null 2>&1; then
        log "Running: dkms autoinstall -k ${kernel_ver}"
        if ! dkms autoinstall -k "${kernel_ver}" >/dev/null 2>&1; then
            log_warn "dkms autoinstall reported an error for kernel ${kernel_ver}."
            local dkms_log
            dkms_log=$(find /var/lib/dkms/amneziawg -name 'make.log' -path "*${kernel_ver}*" 2>/dev/null | head -n 1)
            if [[ -n "$dkms_log" ]]; then
                log_warn "Last 20 lines of the DKMS build log (${dkms_log}):"
                tail -20 "$dkms_log" | while IFS= read -r line; do log_warn "  $line"; done
            else
                log_warn "Build log not found. Details under /var/lib/dkms/amneziawg/."
            fi
        fi
    else
        log_warn "The dkms package is not installed. Cannot rebuild the kernel module."
    fi

    # Step 4: rebuild module dependency cache for the specific kernel.
    if command -v depmod >/dev/null 2>&1; then
        depmod -a "$kernel_ver" >/dev/null 2>&1 || \
            log_warn "depmod -a $kernel_ver reported an error; modprobe below will give the final diagnosis."
    fi

    # Step 5: final modprobe attempt.
    if ! modprobe amneziawg 2>/dev/null; then
        log_error "amneziawg kernel module could not be loaded for kernel ${kernel_ver}."
        log_error "The module is not present in /lib/modules/${kernel_ver}/."
        log_error "Manual recovery:"
        log_error "  1. apt install -y \"linux-headers-${kernel_ver}\""
        log_error "  2. dkms autoinstall -k \"${kernel_ver}\" && depmod -a"
        log_error "  3. modprobe amneziawg"
        log_error "  4. systemctl start \"awg-quick@awg0\""
        return 1
    fi

    log "amneziawg module loaded successfully for kernel ${kernel_ver}."
    if [[ "$mode" == "full" ]]; then
        _ensure_awg_quick_running awg0 || {
            log_warn "Module loaded but awg-quick@awg0 did not start (module OK, this is a service issue)."
            return 2
        }
    fi
    return 0
}

# ==============================================================================
# Loading / saving parameters
# ==============================================================================

# Safe configuration loader (whitelist parser, no source/eval)
# Parses only allowed keys in KEY=VALUE or export KEY=VALUE format
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
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_I2|AWG_I3|AWG_I4|AWG_I5|\
                AWG_I1_MODE|AWG_PRESET|NO_TWEAKS|NO_CPS|KEEP_PACKAGES|AWG_APPLY_MODE|\
                ALLOW_IPV6_TUNNEL|IPV6_SUBNET|SERVER_HAS_NATIVE_IPV6|PREV_AWG_PORT|\
                CLIENT_ISOLATION|CLIENT_ISOLATION_NET|AWG_SERVER_NAME|\
                AWG_ROLE|AWG_UPSTREAM_IFACE|AWG_UPSTREAM_TABLE|AWG_UPSTREAM_FWMARK|AWG_UPSTREAM_PRIORITY|\
                AWG_EGRESS|AWG_WARP_IFACE|AWG_WARP_TABLE|AWG_WARP_PRIORITY|AWG_WARP_BYPASS|\
                AWG_AMNEZIA_DNS)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# Parser for the live AmneziaWG server config (source of truth for AWG_*).
# Reads the [Interface] section of awg0.conf and exports AWG_* variables
# ATOMICALLY: either all 11 required parameters (Jc/Jmin/Jmax/S1-S4/H1-H4)
# are found and exported, or nothing changes in the environment and 1
# is returned. Protects against mixed state when awg0.conf is partially
# corrupt. I1-I5, ListenPort are optional - exported only if found.
# Fixes #38: regen used stale values from the init file instead of the
# actual awg0.conf after manual edits.
# shellcheck disable=SC2120  # Optional argument is only used in tests
load_awg_params_from_server_conf() {
    local conf="${1:-$SERVER_CONF_FILE}"
    [[ -f "$conf" ]] || return 1

    # Local accumulation — all-or-nothing export at the end
    local _Jc="" _Jmin="" _Jmax=""
    local _S1="" _S2="" _S3="" _S4=""
    local _H1="" _H2="" _H3="" _H4=""
    local _I1="" _I2="" _I3="" _I4="" _I5="" _Port="" _MTU=""

    local in_iface=0 line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^\[Interface\] ]]; then in_iface=1; continue; fi
        if [[ "$line" =~ ^\[ ]]; then in_iface=0; continue; fi
        (( in_iface )) || continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// /}" ]] && continue

        if [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            value="${value%"${value##*[![:space:]]}"}"
            case "$key" in
                Jc)         _Jc="$value" ;;
                Jmin)       _Jmin="$value" ;;
                Jmax)       _Jmax="$value" ;;
                S1)         _S1="$value" ;;
                S2)         _S2="$value" ;;
                S3)         _S3="$value" ;;
                S4)         _S4="$value" ;;
                H1)         _H1="$value" ;;
                H2)         _H2="$value" ;;
                H3)         _H3="$value" ;;
                H4)         _H4="$value" ;;
                I1)         _I1="$value" ;;
                I2)         _I2="$value" ;;
                I3)         _I3="$value" ;;
                I4)         _I4="$value" ;;
                I5)         _I5="$value" ;;
                ListenPort) _Port="$value" ;;
                MTU)        _MTU="$value" ;;
            esac
        fi
    done < "$conf"

    # Atomic check: are all 11 required fields present?
    [[ -n "$_Jc" && -n "$_Jmin" && -n "$_Jmax" && \
       -n "$_S1" && -n "$_S2" && -n "$_S3" && -n "$_S4" && \
       -n "$_H1" && -n "$_H2" && -n "$_H3" && -n "$_H4" ]] || return 1

    # Atomic export — environment is modified only on full success
    export AWG_Jc="$_Jc" AWG_Jmin="$_Jmin" AWG_Jmax="$_Jmax"
    export AWG_S1="$_S1" AWG_S2="$_S2" AWG_S3="$_S3" AWG_S4="$_S4"
    export AWG_H1="$_H1" AWG_H2="$_H2" AWG_H3="$_H3" AWG_H4="$_H4"
    [[ -n "$_I1"   ]] && export AWG_I1="$_I1"
    [[ -n "$_I2"   ]] && export AWG_I2="$_I2"
    [[ -n "$_I3"   ]] && export AWG_I3="$_I3"
    [[ -n "$_I4"   ]] && export AWG_I4="$_I4"
    [[ -n "$_I5"   ]] && export AWG_I5="$_I5"
    [[ -n "$_Port" ]] && export AWG_PORT="$_Port"
    if _validate_mtu "${_MTU:-}"; then
        export AWG_MTU="$_MTU"
    fi
    return 0
}

# Load AWG parameters.
#
# Source semantics (important for preventing split-brain between server
# and client configs, see #38):
#
#   * init file ($CONFIG_FILE = awgsetup_cfg.init) — for NON-AWG settings
#     (OS_ID, ALLOWED_IPS, AWG_PORT, AWG_ENDPOINT etc.). Always loaded
#     when present.
#   * Live server config ($SERVER_CONF_FILE = /etc/amnezia/amneziawg/awg0.conf)
#     — the SOLE source of truth for AWG protocol parameters
#     (Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5) when the file exists.
#
# If the live server config exists but does NOT contain a complete set of
# AWG parameters (corruption / incomplete manual edit) — the function
# returns 1 with an explicit error. Silently falling back to stale values
# from the init file would create split-brain: the server runs the new
# awg0.conf while regen would issue clients old J*/S*/H*. This is exactly
# the class of issue reported by elvaleto and Klavishnik in Discussion #38.
#
# The init file is used for AWG parameters ONLY when the live server
# config is missing entirely — that is the bootstrap path of the first
# install when awg0.conf has not been written yet but generate_awg_params
# has already stored values in the init file.
load_awg_params() {
    # 1. Base settings from init (always, for non-AWG keys)
    if [[ -f "$CONFIG_FILE" ]]; then
        safe_load_config "$CONFIG_FILE" || log_warn "Failed to load $CONFIG_FILE"
    fi

    # 2. AWG protocol parameters
    # If CLI specified --preset/--jc/--jmin/--jmax, params are already set via generate_awg_params.
    # Skip reload from awg0.conf to preserve the fresh values.
    if [[ -n "${CLI_PRESET:-}" || -n "${CLI_JC:-}" || -n "${CLI_JMIN:-}" || -n "${CLI_JMAX:-}" ]]; then
        log_debug "CLI overrides set — AWG params from generate_awg_params, not from $SERVER_CONF_FILE"
    elif [[ -f "$SERVER_CONF_FILE" ]]; then
        # Live config exists — it is the sole source of truth.
        # No fallback to init: that would create split-brain.
        # Unset I1-I5 before parsing: they are optional, if absent from live conf
        # they must not leak stale values from init file.
        unset AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5
        if ! load_awg_params_from_server_conf; then
            log_error "$SERVER_CONF_FILE is missing required AWG parameters"
            log_error "(Jc/Jmin/Jmax/S1-S4/H1-H4). Refusing to use stale values from"
            log_error "$CONFIG_FILE, that would create a split-brain between server"
            log_error "and client configs. Restore the [Interface] section in"
            log_error "$SERVER_CONF_FILE or restore awg0.conf from a backup."
            return 1
        fi
        log_debug "AWG parameters loaded from $SERVER_CONF_FILE (live config)"
    else
        # Bootstrap: server config does not exist yet (first install).
        # AWG_* must be in env via safe_load_config above.
        log_debug "$SERVER_CONF_FILE missing — using AWG params from $CONFIG_FILE (bootstrap)"
    fi

    # 3. Check required AWG 2.0 parameters
    local missing=0
    local param
    for param in AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4; do
        if [[ -z "${!param:-}" ]]; then
            log_error "Parameter $param not found"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    return 0
}

# Warn when awgsetup_cfg.init disagrees with the live awg0.conf (issue #196).
#
# After the install, awg0.conf is the only source of the obfuscation parameters,
# and the init file is read for them only during the bootstrap of a first
# install (see load_awg_params above). Editing AWG_* in the init file afterwards
# has no effect on clients, and until this check it was ignored SILENTLY: the
# file is named like the installation config, so someone edits it and gets no
# hint that the answer lives elsewhere.
#
# The modification-time gate removes false positives on the supported path.
# The recommended way to tune (edit [Interface] in awg0.conf, then regen) also
# makes the two files disagree, but nothing rewrites the init file after the
# install, so there it stays OLDER than the live config. We warn only when the
# init file was touched LATER than awg0.conf, which is the "edited init, nothing
# happened" case.
#
# Deliberately not hooked into load_awg_params: the installer calls that on
# step 6, where the init file is necessarily newer than an awg0.conf that has
# not been rewritten yet, and the warning would surface mid-install.
_AWG_DRIFT_KEYS=(AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 \
                 AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5)

# _awg_drift_dump <init|live> <file>: one line per key in the order of the array
# above, so the dumps of the two sources compare line by line. Read in a subshell
# to leave the caller's environment alone - the function can be called at any
# point without the risk of clobbering already loaded parameters.
_awg_drift_dump() {
    local mode="$1" src="$2"
    (
        # Clear inherited values: otherwise a key missing from the source would
        # look equal to whatever is already in the environment. If clearing
        # fails (the variable is readonly in the calling environment) there is
        # nothing to compare, so leave without the marker.
        unset "${_AWG_DRIFT_KEYS[@]}" 2>/dev/null || exit 1
        if [[ "$mode" == "init" ]]; then
            safe_load_config "$src" >/dev/null 2>&1 || exit 1
        else
            load_awg_params_from_server_conf "$src" >/dev/null 2>&1 || exit 1
        fi
        # Success marker on the first line: mapfile does not expose the exit
        # status of the producing process, so without it a parser failure is
        # indistinguishable from a set of empty values.
        printf 'ok\n'
        local k
        for k in "${_AWG_DRIFT_KEYS[@]}"; do
            printf '%s\n' "${!k:-}"
        done
    )
}

warn_awg_init_drift() {
    local init="${CONFIG_FILE:-}" live="${SERVER_CONF_FILE:-}"
    [[ -n "$init" && -n "$live" ]] || return 0
    [[ -f "$init" && -f "$live" ]] || return 0
    # The init file is not newer than the live one, so any disagreement was
    # created by editing awg0.conf itself, which is the supported path. Stay quiet.
    [[ "$init" -nt "$live" ]] || return 0

    local -a ivals lvals
    mapfile -t ivals < <(_awg_drift_dump init "$init")
    mapfile -t lvals < <(_awg_drift_dump live "$live")
    # Without the marker the comparison is not trustworthy: one of the sources
    # failed to parse. Stay quiet instead of declaring every key as differing -
    # load_awg_params will name the real cause (an incomplete [Interface], say).
    [[ "${ivals[0]:-}" == "ok" && "${lvals[0]:-}" == "ok" ]] || return 0

    local drift="" i
    for i in "${!_AWG_DRIFT_KEYS[@]}"; do
        [[ "${ivals[i+1]:-}" == "${lvals[i+1]:-}" ]] || drift+="${_AWG_DRIFT_KEYS[i]#AWG_} "
    done
    [[ -n "$drift" ]] || return 0

    log_warn "$init was modified later than $live, and their obfuscation parameters disagree: ${drift% }"
    log_warn "The values from $live are the ones in effect - after the install it is the only source of these parameters. If you edited them in $init, the edit will not reach clients: change the [Interface] section in $live instead, then restart awg-quick@awg0 and regen the clients you need."
    return 0
}

# ==============================================================================
# Key generation
# ==============================================================================

# Generate keypair (private + public)
# generate_keypair <name>
# Result: keys/<name>.private, keys/<name>.public
generate_keypair() {
    local name="$1"
    if [[ -z "$name" ]]; then
        log_error "generate_keypair: name not specified"
        return 1
    fi
    mkdir -p "$KEYS_DIR" || {
        log_error "Failed to create $KEYS_DIR"
        return 1
    }
    # 700 right at creation: mkdir -p with the default umask would give 755,
    # and until the installer's secure_files the keys directory would be
    # world-readable.
    chmod 700 "$KEYS_DIR"

    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Failed to generate private key for '$name'"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Failed to generate public key for '$name'"
        return 1
    }

    # umask 077 in a subshell: the file is born 600 right away, no
    # world-readable window between write and chmod (with the default umask
    # 022 the key would briefly be 644).
    ( umask 077; echo "$privkey" > "$KEYS_DIR/${name}.private" ) || {
        log_error "Failed to write private key for '$name'"
        return 1
    }
    ( umask 077; echo "$pubkey" > "$KEYS_DIR/${name}.public" ) || {
        log_error "Failed to write public key for '$name'"
        return 1
    }
    chmod 600 "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public" || {
        log_error "Failed to set permissions on keys for '$name'"
        return 1
    }
    log_debug "Keys for '$name' generated."
    return 0
}

# Generate server keys
# Result: server_private.key, server_public.key in AWG_DIR
generate_server_keys() {
    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Failed to generate server private key"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Failed to generate server public key"
        return 1
    }

    # umask 077: no world-readable window between write and chmod (see generate_keypair).
    ( umask 077; echo "$privkey" > "$AWG_DIR/server_private.key" ) || return 1
    ( umask 077; echo "$pubkey" > "$AWG_DIR/server_public.key" ) || return 1
    chmod 600 "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" || {
        log_error "Failed to set permissions on server keys"
        return 1
    }
    log "Server keys generated."
    return 0
}

# Ensure $AWG_DIR/server_public.key is present.
# If missing — tries to reconstruct it from the PrivateKey in awg0.conf
# (useful for manual setups outside my installer, where the cached
# server pubkey from install step 6 does not exist). Returns 0 if the
# key is already there or has been reconstructed, 1 otherwise.
_ensure_server_public_key() {
    [[ -f "$AWG_DIR/server_public.key" ]] && return 0

    [[ -f "$SERVER_CONF_FILE" ]] || {
        log_error "Cannot reconstruct server_public.key — $SERVER_CONF_FILE is missing"
        return 1
    }
    local _srv_priv
    _srv_priv=$(awk '
        /^\[Interface\]/ {in_iface=1; next}
        in_iface && /^[ \t]*PrivateKey[ \t]*=/ {
            sub(/^[ \t]*PrivateKey[ \t]*=[ \t]*/, "")
            gsub(/[[:space:]]/, "")
            print
            exit
        }
        /^\[/ && !/^\[Interface\]/ {in_iface=0}
    ' "$SERVER_CONF_FILE")
    if [[ -z "$_srv_priv" ]]; then
        log_error "PrivateKey not found in $SERVER_CONF_FILE — cannot reconstruct server_public.key"
        return 1
    fi
    mkdir -p "$AWG_DIR"
    local _tmp
    _tmp=$(awg_mktemp "$AWG_DIR") || return 1
    if ! echo "$_srv_priv" | awg pubkey > "$_tmp"; then
        rm -f "$_tmp"
        log_error "awg pubkey failed to compute the public key"
        return 1
    fi
    if ! mv -f "$_tmp" "$AWG_DIR/server_public.key"; then
        rm -f "$_tmp"
        log_error "Failed to move to $AWG_DIR/server_public.key"
        return 1
    fi
    chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    log "server_public.key reconstructed from awg0.conf PrivateKey."
    return 0
}

# ==============================================================================
# Config rendering
# ==============================================================================

# Derive the server IPv6 address (host ::1) from the tunnel subnet.
# Input: PREFIX::/MASK (e.g. fddd:2c4:2c4:2c4::/64).
# Output: PREFIX::1/MASK (e.g. fddd:2c4:2c4:2c4::1/64).
# Assumption: subnet always ends with ::/MASK (that is how the installer writes it).
# If no trailing ::/ is present I return the input unchanged (defensive fallback).
_derive_ipv6_server_addr() {
    local subnet="$1"
    if [[ "$subnet" == *"::/"* ]]; then
        echo "${subnet/::\//::1\/}"
    else
        echo "$subnet"
    fi
}

# Render server config for AWG 2.0
# render_server_config [peers_source_file]
# Uses global variables from load_awg_params()
# peers_source_file (optional): a file whose [Peer] blocks are carried over
# into the new config BEFORE the atomic mv (usually a backup of the live
# awg0.conf). Thanks to this the live config is never left peer-less even for
# an instant - a failure between render and a separate append would leave a
# peer-less file, and the next run of step 6 would back up that already
# peer-less file (losing all peers on --force reinstall).
# shellcheck disable=SC2154  # AWG_* vars loaded via load_awg_params -> source
render_server_config() {
    local peers_source="${1:-}"
    local output_file="${2:-$SERVER_CONF_FILE}"
    load_awg_params || return 1

    # --no-cps (issue #159): load_awg_params re-reads I1 from the live awg0.conf
    # on a reinstall. When NO_CPS=1 clear I1 intentionally, otherwise the server
    # config would silently restore CPS against the flag.
    if grep -qE '^[[:space:]]*(export[[:space:]]+)?NO_CPS=1' "$CONFIG_FILE" 2>/dev/null; then
        AWG_I1=''
    fi

    # Port for the NEW awg0.conf comes from the init file (the user's intent:
    # the --port flag or the previously saved port), NOT from the old awg0.conf
    # being overwritten. load_awg_params re-reads ListenPort from the live
    # config, so without this --port on --force would be silently ignored.
    # render_server_config is only called from install; client regen
    # (regenerate_client) takes its own path and is unaffected.
    local _init_port
    _init_port=$(grep -oP '^\s*export AWG_PORT=\K[0-9]+' "$CONFIG_FILE" 2>/dev/null | head -n1)
    [[ -n "$_init_port" ]] && AWG_PORT="$_init_port"

    local server_privkey
    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        server_privkey=$(cat "$AWG_DIR/server_private.key")
    else
        log_error "Server private key not found: $AWG_DIR/server_private.key"
        return 1
    fi

    local nic
    nic=$(get_main_nic)
    if [[ -z "$nic" ]]; then
        log_error "Failed to detect network interface."
        log_error "Set it manually and re-run step 6: export AWG_MAIN_NIC=<iface>"
        log_error "Available interfaces: $(ip -br link 2>/dev/null | awk '$1!="lo"{printf "%s ", $1}')"
        return 1
    fi

    # IPv6-only egress: interface exists, but there is no IPv4 egress. The IPv4
    # tunnel (10.x) is NATed via MASQUERADE - on such a host IPv4 client traffic
    # will not leave (issue #166). Warn, do not block: peer-to-peer inside the
    # tunnel and the IPv6 tunnel in direct mode (--allow-ipv6-tunnel) still work.
    if host_lacks_ipv4_egress "$nic"; then
        log_warn "Host appears to be IPv6-only: $nic has no IPv4 egress."
        log_warn "The VPN tunnels IPv4, so IPv4 client traffic will not leave the host."
        log_warn "A host with an IPv4 address (dual-stack) or NAT64 is required."
    fi

    local server_ip subnet_mask client_net
    server_ip=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
    subnet_mask=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f2)
    client_net=$(_awg_network_cidr "$AWG_TUNNEL_SUBNET") || {
        log_error "Failed to canonicalize the tunnel subnet: '$AWG_TUNNEL_SUBNET'"
        return 1
    }

    # [Interface] Address: IPv4 always, IPv6 only when the tunnel is enabled.
    # The server takes host ::1 in the tunnel IPv6 subnet.
    # IPV6_SUBNET has the form PREFIX::/MASK (default fddd:2c4:2c4:2c4::/64),
    # so I derive the server address by replacing trailing ::/MASK with ::1/MASK.
    local address_line="${server_ip}/${subnet_mask}"
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" \
          && ( "${AWG_ROLE:-single}" == "entry" || "${AWG_EGRESS:-direct}" == "warp" ) ]]; then
        log_error "IPv6 tunneling is not yet compatible with role=entry or egress=warp: their policy routing is IPv4-only."
        return 1
    fi
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" ]]; then
        local ipv6_subnet="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
        local ipv6_server_addr
        ipv6_server_addr=$(_derive_ipv6_server_addr "$ipv6_subnet")
        address_line="${address_line}, ${ipv6_server_addr}"
    fi

    local conf_dir
    conf_dir=$(dirname "$output_file")
    mkdir -p "$conf_dir" || {
        log_error "Failed to create $conf_dir"
        return 1
    }

    # PostUp/PostDown rules for routing. Three modes:
    #   role=entry          — FORWARD into $AWG_UPSTREAM_IFACE + TCPMSS clamp;
    #                         MASQUERADE is performed on the upstream side
    #   egress=warp         — policy-route the client subnet into Cloudflare
    #                         WARP (wg-quick@wgcf with Table=off) via a
    #                         dedicated table; the NIC stays free for the
    #                         node's own egress (SSH, apt)
    #   plain mode          — FORWARD + MASQUERADE on the primary NIC
    local postup postdown
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        local up_iface="${AWG_UPSTREAM_IFACE:-awg1}"
        local up_tbl="${AWG_UPSTREAM_TABLE:-123}"
        local up_prio="${AWG_UPSTREAM_PRIORITY:-456}"
        if ! _validate_iface_name "$up_iface"; then
            log_error "Invalid upstream interface name: '$up_iface'"
            return 1
        fi
        if ! [[ "$up_tbl" =~ ^[0-9]{1,10}$ ]] \
            || (( 10#$up_tbl < 1 || 10#$up_tbl > 4294967295 \
                  || (10#$up_tbl >= 253 && 10#$up_tbl <= 255) )); then
            log_error "Invalid upstream table: '$up_tbl'"
            return 1
        fi
        if ! [[ "$up_prio" =~ ^[0-9]{1,5}$ ]] \
            || (( 10#$up_prio < 1 || 10#$up_prio > 32764 )); then
            log_error "Invalid upstream priority: '$up_prio'"
            return 1
        fi
        # Keep the policy rule with awg0 rather than awg1. If upstream drops,
        # the table cannot fall through to main: a high-metric blackhole default
        # remains while client-facing awg0 is active. The real awg1 default has
        # a lower metric and wins, as do more-specific routes.
        local up_guard_prio=$(( 10#$up_prio + 1 ))
        postup="ip route replace blackhole default metric 42760 table ${up_tbl} || exit \$?"
        postup="${postup}; while ip rule del blackhole from ${client_net} priority ${up_guard_prio} 2>/dev/null; do :; done"
        postup="${postup}; while ip rule del from ${client_net} table ${up_tbl} priority ${up_prio} 2>/dev/null; do :; done"
        postup="${postup}; ip rule add blackhole from ${client_net} priority ${up_guard_prio} || exit \$?"
        postup="${postup}; ip rule add from ${client_net} table ${up_tbl} priority ${up_prio} || exit \$?"
        postup="${postup}; iptables -I FORWARD -i %i -o ${up_iface} -j ACCEPT"
        postup="${postup}; iptables -I FORWARD -i ${up_iface} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        postdown="iptables -D FORWARD -i %i -o ${up_iface} -j ACCEPT"
        postdown="${postdown}; iptables -D FORWARD -i ${up_iface} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        postdown="${postdown}; while ip rule del from ${client_net} table ${up_tbl} priority ${up_prio} 2>/dev/null; do :; done"
        postdown="${postdown}; while ip rule del blackhole from ${client_net} priority ${up_guard_prio} 2>/dev/null; do :; done"
        postdown="${postdown}; ip route del blackhole default metric 42760 table ${up_tbl} 2>/dev/null || true"
    elif [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
        local warp_iface="${AWG_WARP_IFACE:-wgcf}"
        local warp_tbl="${AWG_WARP_TABLE:-2408}"
        local warp_prio="${AWG_WARP_PRIORITY:-789}"
        if ! _validate_iface_name "$warp_iface"; then
            log_error "Invalid WARP interface name: '$warp_iface'"
            return 1
        fi
        if ! [[ "$warp_tbl" =~ ^[0-9]{1,10}$ ]] \
            || (( 10#$warp_tbl < 1 || 10#$warp_tbl > 4294967295 \
                  || (10#$warp_tbl >= 253 && 10#$warp_tbl <= 255) )); then
            log_error "Invalid WARP routing table: '$warp_tbl'"
            return 1
        fi
        if ! [[ "$warp_prio" =~ ^[0-9]{1,5}$ ]] \
            || (( 10#$warp_prio < 1 || 10#$warp_prio > 32764 )); then
            log_error "Invalid WARP rule priority: '$warp_prio'"
            return 1
        fi
        # Clients arrive from AWG_TUNNEL_SUBNET (after MASQUERADE on entry in
        # a cascade, or straight from the client in single mode). The from-rule
        # only catches them; the server's own traffic uses the main table.
        #
        # MASQUERADE on BOTH outbound paths:
        #   -o wgcf  — the primary case; client traffic is routed into WARP,
        #              src=10.9.0.2 becomes src=172.16.0.2 (wgcf addr).
        #   -o $nic  — the bypass case: table ${warp_tbl} may contain more
        #              specific routes `<CIDR> via <GW> dev $nic` so that
        #              certain destinations (YouTube / Google / banking etc.)
        #              skip WARP — WARP IPs are often rate-limited by those
        #              services. Longest-prefix-match sends those packets via
        #              $nic. Without MASQUERADE on $nic they'd leave with
        #              src=10.9.0.2 (private entry IP), replies never come
        #              back. SNAT rewrites src to the VPS public IP.
        # A persistent blackhole keeps WARP fail-closed: if wgcf disappears and
        # its device route is removed, policy lookup must not fall through to
        # main and reveal the VPS IP. Specific bypass routes still win by prefix.
        local warp_guard_prio=$(( 10#$warp_prio + 1 ))
        local warp_bypass="${AWG_WARP_BYPASS:-none}"
        postup="ip route replace blackhole default metric 42760 table ${warp_tbl} || exit \$?"
        postup="${postup}; ip route replace default dev ${warp_iface} metric 10 table ${warp_tbl} || exit \$?"
        postup="${postup}; while ip rule del blackhole from ${client_net} priority ${warp_guard_prio} 2>/dev/null; do :; done"
        postup="${postup}; while ip rule del from ${client_net} table ${warp_tbl} priority ${warp_prio} 2>/dev/null; do :; done"
        postup="${postup}; ip rule add blackhole from ${client_net} priority ${warp_guard_prio} || exit \$?"
        postup="${postup}; ip rule add from ${client_net} table ${warp_tbl} priority ${warp_prio} || exit \$?"
        postup="${postup}; iptables -I FORWARD -i %i -o ${warp_iface} -j ACCEPT"
        postup="${postup}; iptables -I FORWARD -i ${warp_iface} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        postup="${postup}; iptables -t nat -A POSTROUTING -s ${client_net} -o ${warp_iface} -j MASQUERADE"
        if [[ "$warp_bypass" != "none" ]]; then
            postup="${postup}; iptables -t nat -A POSTROUTING -s ${client_net} -o ${nic} -j MASQUERADE"
        fi
        # Bypass routes survive awg0 restarts and are refreshed by their owned
        # timer/service. PostUp does not start that service: doing so could race
        # an installer transaction that snapshots and replaces its ledger.
        if [[ "$warp_bypass" != "none" ]]; then
            postdown="iptables -t nat -D POSTROUTING -s ${client_net} -o ${nic} -j MASQUERADE"
            postdown="${postdown}; iptables -t nat -D POSTROUTING -s ${client_net} -o ${warp_iface} -j MASQUERADE"
        else
            postdown="iptables -t nat -D POSTROUTING -s ${client_net} -o ${warp_iface} -j MASQUERADE"
        fi
        postdown="${postdown}; iptables -D FORWARD -i ${warp_iface} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        postdown="${postdown}; iptables -D FORWARD -i %i -o ${warp_iface} -j ACCEPT"
        postdown="${postdown}; while ip rule del from ${client_net} table ${warp_tbl} priority ${warp_prio} 2>/dev/null; do :; done"
        postdown="${postdown}; while ip rule del blackhole from ${client_net} priority ${warp_guard_prio} 2>/dev/null; do :; done"
        postdown="${postdown}; ip route del default dev ${warp_iface} metric 10 table ${warp_tbl} 2>/dev/null || true"
        postdown="${postdown}; ip route del blackhole default metric 42760 table ${warp_tbl} 2>/dev/null || true"
    else
        postup="iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE"
        postdown="iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE"
    fi

    # MSS/PMTU clamp: pin the TCP MSS to the tunnel MTU so large segments do not
    # stall against the 1280 tunnel when ICMP "frag needed" is filtered (PMTU
    # blackhole: VPN connects but large pages/downloads hang on mobile/double-NAT/
    # cascade paths). A fixed MSS derived from AWG_MTU is deterministic with the
    # hard-set MTU and auto-syncs with it; clamp-to-pmtu would depend on the egress
    # route. Bidirectional (-o %i and -i %i) caps the MSS both ways. IPv4: MTU-40,
    # IPv6: MTU-60. SYN only, mangle table (separate from UFW/filter). The -A/-D
    # style mirrors the MASQUERADE rules above.
    local awg_mtu="${AWG_MTU:-1280}"
    if ! _validate_mtu "$awg_mtu"; then
        log_warn "Invalid AWG_MTU='$awg_mtu'; using the safe MTU 1280."
        awg_mtu=1280
    else
        awg_mtu=$((10#$awg_mtu))
    fi
    local path_mtu="$awg_mtu"
    # The outer legs have their own limits: wgcf defaults to 1280 and awg1 is
    # 1380. Do not raise MSS above the narrowest leg for a custom AWG_MTU.
    if [[ "${AWG_EGRESS:-direct}" == "warp" ]] && (( path_mtu > 1280 )); then
        path_mtu=1280
    elif [[ "${AWG_ROLE:-single}" == "entry" ]] && (( path_mtu > 1380 )); then
        path_mtu=1380
    fi
    local mss4=$(( path_mtu - 40 ))
    local mss6=$(( awg_mtu - 60 ))
    postup="${postup}; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"
    postdown="${postdown}; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"

    # Client isolation (issue #178): DROP awg0->awg0 before the general ACCEPT.
    # PostUp runs left to right, -I inserts at the head of the chain - so a
    # rule added ON A LATER LINE ends up HIGHER IN THE CHAIN, which is why the
    # DROP is appended at the end of postup. Before -I we drain stale copies
    # with a -D loop: after a failed PostDown a DROP copy would otherwise pile
    # up on every up (PR #179 review). A drain, deliberately not -C: by this
    # point the stale copy sits BELOW the freshly inserted ACCEPT, -C would
    # find it, skip the insert - and awg0->awg0 traffic would hit ACCEPT
    # (isolation silently broken). PostDown uses '2>/dev/null || true':
    # after an on->off reinstall the rule is not in the running set, and a
    # failing -D must not fail awg-quick down (the down phase of restart already
    # runs against the new config). Unset CLIENT_ISOLATION = 1: configs from
    # before v5.20 are isolated.
    if [[ "${CLIENT_ISOLATION:-1}" == "1" ]]; then
        postup="${postup}; while iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; iptables -I FORWARD -i %i -o %i -j DROP"
        postdown="${postdown}; iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
    fi

    # IPv6 rules: enabled when the IPv6 tunnel is on (FORWARD inside the tunnel +
    # MASQUERADE to the public interface). MASQUERADE is harmless without native
    # IPv6 on the VPS - it is a no-op while there is no IPv6 default route, while
    # peer-to-peer traffic inside the tunnel still works. I reuse the same nic as
    # the IPv4 MASQUERADE (no hardcoded interface).
    # The DISABLE_IPV6=0 condition is kept for byte-identical compatibility with v5.14.x:
    # an install with --allow-ipv6 (no tunnel) gets the same IPv6 filter rules as before.
    if [[ ( "${ALLOW_IPV6_TUNNEL:-0}" == "1" || "${DISABLE_IPV6:-1}" == "0" ) \
          && "${AWG_ROLE:-single}" != "entry" && "${AWG_EGRESS:-direct}" != "warp" ]]; then
        postup="${postup}; ip6tables -I FORWARD -i %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE; ip6tables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}; ip6tables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        postdown="${postdown}; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE; ip6tables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}; ip6tables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        # Isolation for the IPv6 tunnel too: without the DROP, dual-stack
        # clients in split modes can reach each other over fddd::/64
        # (IPV6_SUBNET is already in their AllowedIPs via render_client_config)
        # - issue #178.
        if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" && "${CLIENT_ISOLATION:-1}" == "1" ]]; then
            postup="${postup}; while ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; ip6tables -I FORWARD -i %i -o %i -j DROP"
            postdown="${postdown}; ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
        fi
    fi

    # Build config via temp file (atomic write).
    # Create temp in the target config's directory so mv is an atomic rename on
    # the same filesystem (not a cross-fs copy+unlink when /tmp is tmpfs).
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$output_file")") || { log_error "mktemp failed"; return 1; }

    cat > "$tmpfile" << EOF
[Interface]
PrivateKey = ${server_privkey}
Address = ${address_line}
MTU = ${awg_mtu}
ListenPort = ${AWG_PORT}
PostUp = ${postup}
PostDown = ${postdown}
Jc = ${AWG_Jc}
Jmin = ${AWG_Jmin}
Jmax = ${AWG_Jmax}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF

    # Add I1-I5 only if set (CPS params are optional).
    # I2-I5 are set by the admin manually in awg0.conf (issue #71), copied as-is.
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"

    # Carry [Peer] blocks from peers_source into the temp BEFORE mv (see doc comment).
    # The buffer is flushed on every new [Peer]: ALL blocks are carried over.
    if [[ -n "$peers_source" && -f "$peers_source" ]]; then
        local _peers
        _peers=$(awk '
            /^\[Peer\]/ { if (in_peer) printf "%s", buf; buf=$0"\n"; in_peer=1; next }
            in_peer && /^\[/ { printf "%s", buf; buf=""; in_peer=0; next }
            in_peer { buf=buf $0"\n"; next }
            END { if (in_peer) printf "%s", buf }
        ' "$peers_source")
        if [[ -n "$_peers" ]]; then
            printf '\n%s' "$_peers" >> "$tmpfile" || {
                rm -f "$tmpfile"
                log_error "Failed to carry [Peer] blocks into the new config"
                return 1
            }
        fi
    fi

    if ! mv "$tmpfile" "$output_file"; then
        rm -f "$tmpfile"
        log_error "Failed to write server config"
        return 1
    fi
    chmod 600 "$output_file"
    log "Server config created: $output_file"
    return 0
}

# Warn that a list value was given on several lines and they were joined.
# Staying silent here is not an option: joining changes what the user typed by
# hand, and if they made a mistake they should hear it from us, not from the
# client.
_awg_warn_multiline() {
    local raw="$1" key="$2" name="$3" n
    n=$(printf '%s\n' "$raw" | grep -c '[^[:space:]]') || n=0
    (( n > 1 )) && log_warn "'${key}' of client '${name}' is given on ${n} lines - the values were joined into one."
    return 0
}

# Normalise a comma-separated list to the canonical "a, b, c" form.
#
# Why: the installer writes AllowedIPs and DNS with a space after each comma,
# while regenerate_client read those values through `tr -d '[:space:]'` and
# wrote what it had read straight back, so the very first regen left a
# collapsed list in .conf (D#38 @humowns). Here the list is split per element
# and the separator is rebuilt canonically, so a repeated regen REPAIRS configs
# that were already damaged.
#
# 🔴 Do NOT apply this to the value that feeds the allowed_ips JSON array in the
# vpn:// builder (see the comment at generate_vpn_uri): that one needs the
# COMPACT form. One revision of this very fix did normalise it there, and on a
# test server that put a leading space inside 33 of the 34 array elements.
#
# Whitespace is stripped INSIDE each element, not only at its edges: elements of
# these two lists (CIDRs and resolver addresses) never contain spaces, and the
# `manage modify` validator cleans them the same way, via `${tok//[[:space:]]/}`.
# That also repairs values like "1.1.1. 1", which the old `tr` cleaned by luck.
#
# Split via `read -a` rather than `for x in $raw` so the value is not subject to
# glob expansion. The trim is inline rather than a function call: a substitution
# per element forks a subshell, and on a 2000-entry list that is 18 seconds
# against 0.1 - while regen without a name walks every client at once.
#
# ⚠️ Contract: the input is SINGLE-LINE. `read` without `-d` would take only the
# first line, so a multi-line value must be joined by the caller (`paste -sd, -`).
awg_normalize_csv() {
    local out="" item
    local -a parts
    IFS=',' read -r -a parts <<< "$1"
    for item in "${parts[@]}"; do
        item="${item//[[:space:]]/}"
        [[ -z "$item" ]] && continue
        out+="${out:+, }$item"
    done
    printf '%s' "$out"
}

# Acceptable MTU range for AWG / WireGuard.
# Lower bound 576 (classic IPv4 minimum), upper bound 9100 (just under jumbo).
# Values outside the range are treated as invalid and dropped (fallback to 1280).
_validate_mtu() {
    local v="$1"
    [[ "$v" =~ ^[0-9]{1,4}$ ]] || return 1
    (( 10#$v >= 576 && 10#$v <= 9100 )) || return 1
    return 0
}

# Extract MTU from the [Interface] section of server awg0.conf (if the file
# exists). Prints the integer on stdout, or nothing if MTU is missing or the
# file is unreadable. Last-wins: if [Interface] holds several MTU = ... lines,
# the last one is returned (matching the way awg-quick applies the final
# assignment). Used by render_client_config to sync the client MTU with the
# server (v5.14.0 bug: manual MTU edit in awg0.conf was not picked up by regen).
_extract_mtu_from_server_conf() {
    local conf="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
    [[ -r "$conf" ]] || return 1
    local val
    val=$(awk '
        /^\[Interface\]/ {in_iface=1; next}
        /^\[/ {in_iface=0}
        in_iface && /^[[:space:]]*MTU[[:space:]]*=/ {
            gsub(/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*/, "")
            gsub(/[[:space:]].*$/, "")
            if ($0 ~ /^[0-9]+$/) { mtu=$0 }
        }
        END { if (mtu != "") print mtu }
    ' "$conf")
    _validate_mtu "$val" || return 1
    echo "$val"
}

# Render client config for AWG 2.0
# render_client_config <name> <client_ip> <client_privkey> <server_pubkey> <endpoint> <port> [client_ipv6]
#
# client_ipv6 (optional 7th argument): client IPv6 address without prefix
# length (e.g. fddd:2c4:2c4:2c4::5). If non-empty and ALLOW_IPV6_TUNNEL=1:
#   - Address = <ipv4>/32, <ipv6>/128
#   - AllowedIPs (mirror the IPv4 routing mode into IPv6, intent-mirroring):
#       full tunnel (ALLOWED_IPS=0.0.0.0/0): + ::/0 (native) or + <IPV6_SUBNET> (no-native)
#       split tunnel (custom ALLOWED_IPS):   IPv4 list UNCHANGED + ONLY <IPV6_SUBNET>,
#         NEVER ::/0 - there is no IPv6 split-list, hijacking all IPv6 breaks split-tunnel.
# If empty (legacy client): Address = <ipv4>/32, AllowedIPs unchanged.
render_client_config() {
    local name="$1"
    local client_ip="$2"
    local client_privkey="$3"
    local server_pubkey="$4"
    local endpoint="$5"
    local port="$6"
    local client_ipv6="${7:-}"

    load_awg_params || return 1

    if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" \
          && ( "${AWG_ROLE:-single}" == "entry" || "${AWG_EGRESS:-direct}" == "warp" ) ]]; then
        log_error "Cannot issue an IPv6 client for role=entry/egress=warp: that path routes IPv4 only."
        return 1
    fi

    local conf_file="$AWG_DIR/${name}.conf"
    local allowed_ips
    if [[ -n "$client_ipv6" ]]; then
        # Dual-stack: mirror the IPv4 routing intent into IPv6.
        # full tunnel (IPv4=0.0.0.0/0) -> ::/0 (native) or tunnel ULA (no-native).
        # split tunnel (custom ALLOWED_IPS) -> IPv4 split AS-IS + ONLY tunnel ULA,
        # never ::/0 (no IPv6 split-list, must not hijack all IPv6).
        local ipv4_part ipv6_part
        ipv4_part="${ALLOWED_IPS:-0.0.0.0/0}"
        if [[ "$ipv4_part" == "0.0.0.0/0" && "${SERVER_HAS_NATIVE_IPV6:-0}" == "1" ]]; then
            ipv6_part="::/0"
        else
            ipv6_part="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
        fi
        # Defensive de-dup: ALLOWED_IPS is IPv4-only by construction, but do not
        # duplicate ipv6_part if it is already present as a token in the list.
        case ",${ipv4_part// /}," in
            *",${ipv6_part},"*) allowed_ips="$ipv4_part" ;;
            *)                  allowed_ips="${ipv4_part}, ${ipv6_part}" ;;
        esac
    else
        allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
        # iOS AmneziaVPN in "all traffic" mode requires both address families:
        # with a bare 0.0.0.0/0 it treats the config as incomplete split routing
        # and refuses to bring the tunnel up. For full tunnel we add ::/0 - IPv6
        # goes into the tunnel (and is dropped if the server has no native IPv6),
        # so it never leaks past the VPN. Affects mode-1 only: split mode uses a
        # custom list that is not equal to 0.0.0.0/0 and skips this branch.
        if [[ "$allowed_ips" == "0.0.0.0/0" ]]; then
            allowed_ips="0.0.0.0/0, ::/0"
        fi
    fi

    # DNS + AllowedIPs when AmneziaDNS=on.
    # 1) DNS: we hand out the tunnel-gateway IP (e.g. 10.9.9.1) — our dnsmasq
    #    lives there. The Amnezia VPN client picks it up as dns1 and resolves
    #    "bypass-VPN" sites from the site-list locally on the device → the
    #    destination site sees the user's real IP, not the VPS IP.
    # 2) AllowedIPs MUST be exactly "0.0.0.0/0, ::/0" (with the space!). If
    #    anything more specific leaks through, the gate in the Amnezia client
    #    (servers_model.cpp::isDefaultServerDefaultContainerHasSplitTunneling,
    #    dev branch, lines 837-863) treats the server as "already doing split
    #    tunneling by itself" and disables its own UI with the toast
    #    "Default server does not support split tunneling function".
    #    Route-all in the client config is NOT "send all traffic through the
    #    VPN no matter what" — it's "trust the client to route per its site
    #    list UI". Sites on the bypass list get dropped from the route
    #    dynamically, via dnsmasq resolution and NotAllowedIPs.
    # Otherwise (amnezia-dns=off): two upstream DNS servers, AllowedIPs from ALLOWED_IPS.
    local client_dns="1.1.1.1, 1.0.0.1"
    if [[ "${AWG_AMNEZIA_DNS:-off}" == "on" && -n "${AWG_TUNNEL_SUBNET:-}" ]]; then
        client_dns=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
        [[ -z "$client_dns" ]] && client_dns="1.1.1.1"
        allowed_ips="0.0.0.0/0, ::/0"
    fi

    # MTU resolution order: server awg0.conf > AWG_MTU from awgsetup_cfg.init >
    # 1280 fallback. Server config is the source of truth for a running server -
    # the user could have hand-edited MTU in /etc/amnezia/amneziawg/awg0.conf
    # and regen has to pick that up (Discussion #38). Out-of-range
    # values (outside 576..9100) at any stage roll back to 1280.
    local mtu
    mtu=$(_extract_mtu_from_server_conf) || mtu=""
    if [[ -z "$mtu" ]]; then
        if _validate_mtu "${AWG_MTU:-}"; then
            mtu="$AWG_MTU"
        else
            mtu=1280
        fi
    fi

    # temp in the client config dir ($AWG_DIR) -> mv = atomic rename.
    local tmpfile
    tmpfile=$(awg_mktemp "$AWG_DIR") || { log_error "mktemp failed"; return 1; }

    local address_line
    if [[ -n "$client_ipv6" ]]; then
        address_line="${client_ip}/32, ${client_ipv6}/128"
    else
        address_line="${client_ip}/32"
    fi

    cat > "$tmpfile" << EOF
[Interface]
PrivateKey = ${client_privkey}
Address = ${address_line}
DNS = ${client_dns}
MTU = ${mtu}
Jc = ${AWG_Jc}
Jmin = ${AWG_Jmin}
Jmax = ${AWG_Jmax}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
S3 = ${AWG_S3}
S4 = ${AWG_S4}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
EOF

    # I1-I5: copy the set CPS params into the client config (issue #71).
    # They do not have to match the server side - the receiver never validates
    # them; regen simply distributes whatever the server has.
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"

    cat >> "$tmpfile" << EOF

[Peer]
PublicKey = ${server_pubkey}
EOF
    # Optional PresharedKey — extra layer on top of AWG 2.0 obfuscation
    # (enabled via `manage add --psk`). Must match on server peer and
    # client [Peer].
    if [[ -n "${CLIENT_PSK:-}" ]]; then
        echo "PresharedKey = ${CLIENT_PSK}" >> "$tmpfile"
    fi
    cat >> "$tmpfile" << EOF
Endpoint = ${endpoint}:${port}
AllowedIPs = ${allowed_ips}
PersistentKeepalive = 33
EOF

    if ! mv "$tmpfile" "$conf_file"; then
        rm -f "$tmpfile"
        log_error "Failed to write config for client '$name'"
        return 1
    fi
    chmod 600 "$conf_file"
    log_debug "Config for '$name' created: $conf_file"
    return 0
}

# ==============================================================================
# Operations that restart the interface: warning and reversibility
# ==============================================================================

# awg_ssh_client_addr : source address of the current SSH session (empty if this
# is not SSH or it cannot be determined).
#
# ⚠️ $SSH_CONNECTION alone is NOT ENOUGH: the script is run through sudo, sudo
# does env_reset by default, and SSH_CONNECTION is not in the Debian/Ubuntu
# env_keep list. Hence the second path - who, matched against our own tty.
# who may report a hostname instead of an address (with UseDNS yes); the subnet
# comparison then cannot be made, and the caller gets "could not determine",
# which is more honest than guessing.
awg_ssh_client_addr() {
    local from_tty="" from_env="" mytty
    mytty=$(ps -o tty= -p $$ 2>/dev/null | tr -d '[:space:]')
    if [[ -n "$mytty" && "$mytty" != "?" ]]; then
        from_tty=$(who 2>/dev/null | awk -v t="$mytty" '
            $2 == t && match($0, /\(([^)]+)\)/) {
                print substr($0, RSTART + 1, RLENGTH - 2); exit
            }')
    fi
    [[ -n "${SSH_CONNECTION:-}" ]] && from_env="${SSH_CONNECTION%% *}"
    # ⚠️ Data keyed on OUR tty wins over the inherited variable.
    # SSH_CONNECTION comes from the environment, and in a reattached tmux/screen
    # session it can point at the PREVIOUS connection - we would then produce a
    # confidently wrong verdict. utmp keyed on our own tty describes the current
    # one. But if the tty path yielded something that is not an address (with
    # UseDNS yes it will be a hostname), take the variable: a usable address
    # beats an honest "unknown".
    if _valid_ipv4 "$from_tty" 2>/dev/null; then
        printf '%s' "$from_tty"
    elif _valid_ipv4 "$from_env" 2>/dev/null; then
        printf '%s' "$from_env"
    elif [[ -n "$from_tty" ]]; then
        printf '%s' "$from_tty"
    else
        printf '%s' "$from_env"
    fi
}

# awg_session_via_tunnel : is the current session going THROUGH the VPN tunnel.
#   0 - yes, the source address is inside the tunnel subnet (a restart will cut
#       off access);
#   1 - no, the address is outside the subnet;
#   2 - could not determine (not SSH, address not IPv4, subnet not parsed).
# Three states rather than two, deliberately: "unknown" and "not through the
# tunnel" need DIFFERENT wording, and collapsing them into 1 would present a
# guess as a fact.
# _awg_tunnel_subnet : the tunnel subnet as addr/prefix, or an empty string.
#
# 🔴 THERE IS DELIBERATELY NO DEFAULT HERE, and that fixes a critical defect.
# An earlier revision substituted the literal 10.9.9.1/24, while manage does NOT
# load awgsetup_cfg.init on the restart path - so AWG_TUNNEL_SUBNET is empty
# there. For anyone who installed with --subnet, a session from their own subnet
# (say 10.66.66.2) was compared against a foreign 10.9.9.0/24 and declared "not
# through the tunnel": the script confidently asserted THE OPPOSITE OF THE TRUTH
# in exactly the scenario the check was written for, and showed neither the
# warning nor the hint about the provider console. A substituted literal turns
# "there is no data" into "there is data, and it says this".
#
# Sources by descending trustworthiness: the live interface, the server config,
# the variable (which load_awg_params sets on other paths). Nothing found means
# empty, and the caller must say "unknown" rather than guess.
_awg_tunnel_subnet() {
    local out=""
    out=$(ip -4 -o addr show awg0 2>/dev/null \
        | awk '{ for (i = 1; i <= NF; i++) if ($i == "inet") { print $(i + 1); exit } }')
    if [[ -z "$out" && -r "$SERVER_CONF_FILE" ]]; then
        out=$(awk '
            /^[[:space:]]*#/ { next }
            /^[[:space:]]*\[/ { inif = (tolower($0) ~ /^[[:space:]]*\[interface\]/) ? 1 : 0; next }
            inif && tolower($0) ~ /^[[:space:]]*address[[:space:]]*=/ {
                sub(/^[^=]*=[[:space:]]*/, "")
                n = split($0, parts, ",")
                for (i = 1; i <= n; i++) {
                    gsub(/[[:space:]]/, "", parts[i])
                    if (parts[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) { print parts[i]; exit }
                }
            }' "$SERVER_CONF_FILE")
    fi
    [[ -z "$out" && -n "${AWG_TUNNEL_SUBNET:-}" ]] && out="$AWG_TUNNEL_SUBNET"
    printf '%s' "$out"
}

awg_session_via_tunnel() {
    local addr="${1:-}" subnet net_int bcast_int addr_int
    [[ -n "$addr" ]] || addr="$(awg_ssh_client_addr)"
    [[ -n "$addr" ]] || return 2
    [[ "$addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 2
    subnet="$(_awg_tunnel_subnet)"
    [[ -n "$subnet" ]] || return 2
    # 🔴 A /31 or /32 prefix carries no host range, so it cannot answer our
    # question: any address other than the server one lands "outside the
    # subnet", and we would confidently tell someone sitting in the tunnel
    # that access is unaffected. Our generator writes /16../30, but the live
    # interface path inherits WHATEVER prefix is there, and /32 in
    # [Interface] is common WireGuard practice. Answer "unknown" (verified).
    [[ "${subnet##*/}" =~ ^[0-9]+$ ]] || return 2
    (( 10#${subnet##*/} <= 30 )) || return 2
    read -r net_int bcast_int < <(_cidr_bounds "$subnet" 2>/dev/null) || return 2
    [[ -n "$net_int" && -n "$bcast_int" ]] || return 2
    addr_int="$(_ipv4_to_int "$addr" 2>/dev/null)" || return 2
    [[ -n "$addr_int" ]] || return 2
    (( addr_int >= net_int && addr_int <= bcast_int )) && return 0
    return 1
}

# awg_warn_interface_disruption : warn BEFORE an operation that restarts the
# interface. Call it before confirm_action so the warning is visible with --yes
# as well (a non-interactive run can cut people off from the server too).
awg_warn_interface_disruption() {
    local rc addr subnet
    log_warn "The awg0 interface will be restarted - every client connection drops for a few seconds."
    # Ask for the address ONCE and pass it into the check: two independent
    # calls could give a verdict about one address and text about another.
    addr="$(awg_ssh_client_addr)"
    # The subnet is resolved ONCE and BEFORE the verdict as well: an earlier
    # revision asked for it a second time afterwards, so the printed subnet
    # could differ from the one the verdict was based on.
    subnet="$(_awg_tunnel_subnet)"
    # rc is taken with `|| rc=$?` rather than `cmd; rc=$?`: under set -e the
    # latter aborts the function on a non-zero status, cutting the warning off
    # halfway. The repository does contain an embedded script with set -euo
    # pipefail, so this is not hypothetical.
    rc=0
    awg_session_via_tunnel "$addr" || rc=$?
    case "$rc" in
        0)
            log_warn "WARNING: it looks like you are connected to this server THROUGH this very VPN."
            log_warn "  Your session address $addr belongs to the tunnel subnet ${subnet},"
            log_warn "  so the current connection will drop after the restart."
            log_warn "  If access does not come back on its own, use the console or VNC in your"
            log_warn "  provider's panel: it works independently of the VPN."
            ;;
        1)
            log_debug "Session is not going through the tunnel (address $addr) - server access is unaffected."
            ;;
        *)
            log_warn "  If you are connected to this server THROUGH this VPN, you will lose access."
            log_warn "  The fallback for that case is the console or VNC in your provider's panel."
            ;;
    esac
}

# _awg_device_param_names : names of the AWG device parameters (2.0 and 3.0)
# that live in the [Interface] section and that syncconf does NOT clear.
_awg_device_param_names() {
    printf '%s\n' Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 \
        ContentPaddingAddition HeaderProtectionKey MaxHandshakeAttempts \
        KeepaliveTimeout RejectAfterTime RekeyAfterTime RekeyTimeout
}

# _awg_device_params_fingerprint [config] : sorted list of device parameter
# NAMES present in the [Interface] section, on a single line.
# Names only: syncconf applies values correctly, the problem is exactly removal.
_awg_device_params_fingerprint() {
    local conf="${1:-$SERVER_CONF_FILE}" known
    [[ -r "$conf" ]] || return 1
    known="$(_awg_device_param_names | tr '\n' '|')"
    known="${known%|}"
    awk -v known="$known" '
        BEGIN { n = split(known, k, "|"); for (i = 1; i <= n; i++) low[tolower(k[i])] = k[i] }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*\[/ { inif = (tolower($0) ~ /^[[:space:]]*\[interface\]/) ? 1 : 0; next }
        inif && /=/ {
            name = $1
            sub(/[[:space:]]*=.*$/, "", name)
            gsub(/[[:space:]]/, "", name)
            if (tolower(name) in low) print low[tolower(name)]
        }
    ' "$conf" | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# _awg_save_device_params <state file> <fingerprint> : remember the applied set.
# The file lives in AWG_DIR (root-only); losing it degrades gracefully - the
# next check simply does not fire, and no spurious restart happens.
# The write is ATOMIC (temp + mv): a truncated write would leave a half-empty
# snapshot, which reads as "the parameters were removed" and produces a false
# warning. A failure is not swallowed entirely - it goes to debug, otherwise a
# silent loss of state would look like success.
_awg_save_device_params() {
    local state="$1" fp="$2" tmp="${1}.tmp"
    if ! printf '%s\n' "$fp" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        log_warn "Failed to write the interface parameter snapshot ($state) - check free space and permissions."
        return 0
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$state" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        log_warn "Failed to replace the interface parameter snapshot ($state) - check free space and permissions."
    fi
    return 0
}

# awg_record_device_params : remember which set of device parameters the config
# holds RIGHT NOW. Call it AFTER a successful apply or interface recreation - the
# snapshot has to mean "what is actually on the live interface", otherwise
# removal detection starts lying in both directions.
#
# 🔴 Two rules, each closing a defect found in review:
# 1. The fingerprint is recomputed rather than reusing the one taken before the
#    apply: if the file was being rewritten at that moment, what was computed was
#    incomplete, and saving it would have frozen a wrong set.
# 2. An EMPTY set is NEVER written. An empty snapshot disables the check forever
#    (nothing to compare against), and emptiness almost always means a partially
#    read file: our generator always writes Jc/S/H. Keeping the previous good
#    snapshot is better.
awg_record_device_params() {
    local state="${AWG_DIR}/.awg_device_params" fp
    [[ -r "$SERVER_CONF_FILE" ]] || return 0
    fp="$(_awg_device_params_fingerprint "$SERVER_CONF_FILE" 2>/dev/null)" || return 0
    [[ -n "$fp" ]] || return 0
    _awg_save_device_params "$state" "$fp"
}

# ==============================================================================
# Config application (syncconf)
# ==============================================================================

# Apply configuration changes
# Arguments: [iface=awg0] — interface name (for multi-hop: awg1 etc.)
# AWG_SKIP_APPLY=1: skip apply (for batch automation)
# AWG_APPLY_MODE=syncconf|restart: apply method (config or --apply-mode CLI)
# flock on .awg_apply.lock: prevents concurrent apply calls
# shellcheck disable=SC2120  # iface is an optional positional arg (multi-hop awg1)
apply_config() {
    local iface="${1:-awg0}"
    if ! _validate_iface_name "$iface"; then
        log_error "apply_config: invalid interface name '$iface'"
        return 1
    fi
    # Skip apply (AWG_SKIP_APPLY=1 manage add/remove ...)
    if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
        log_debug "apply_config skipped (AWG_SKIP_APPLY=1)."
        return 0
    fi

    # Inter-process lock for apply_config
    local apply_lockfile="${AWG_DIR}/.awg_apply.lock"
    local apply_fd
    exec {apply_fd}>"$apply_lockfile"
    if ! flock -x -w 120 "$apply_fd"; then
        log_warn "Failed to acquire apply_config lock."
        exec {apply_fd}>&-
        return 1
    fi

    local rc=0 iface_conf strip_out preflight_mode=server
    if [[ "$iface" == awg0 ]]; then
        iface_conf="$SERVER_CONF_FILE"
    else
        iface_conf="$(dirname "$SERVER_CONF_FILE")/${iface}.conf"
        preflight_mode=upstream
    fi
    # Validate and parse the on-disk config before any possible stop. A failed
    # preflight must never trigger a disruptive fallback restart.
    if [[ "$iface" != awg0 ]] && ! _validate_upstream_structure "$iface_conf"; then
        log_error "apply_config: upstream structure preflight failed for $iface_conf"
        exec {apply_fd}>&-
        return 1
    fi
    if ! _validate_quick_config_semantics "$iface_conf" "$preflight_mode"; then
        log_error "apply_config: semantic preflight failed for $iface_conf"
        exec {apply_fd}>&-
        return 1
    fi
    strip_out=$(timeout 10 awg-quick strip "$iface_conf" 2>/dev/null) || {
        log_warn "awg-quick strip ${iface} failed or timed out; live interface unchanged."
        exec {apply_fd}>&-
        return 1
    }

    # 🔴 syncconf DOES NOT CLEAR AWG device parameters. Verified on module
    # 3.0.20260731-04: Jc/S4/H1/I1/ContentPaddingAddition/RekeyAfterTime that had
    # been set stayed on the live interface after applying a config without them.
    # The WireGuard semantics ("setconf = the complete picture") does not hold for
    # AWG parameters, it is additive. So the operation "remove a parameter from
    # awg0.conf and apply" would silently not work: the file changes, the
    # interface does not, and nothing catches that divergence. A parameter can
    # only be cleared by recreating the interface, i.e. by restarting the service.
    #
    # We compare the SET OF NAMES against what was applied last time, not against
    # the live interface: `awg showconf` prints neutral values too (S4 = 0,
    # H1 = 1), so comparing with it would produce false positives on every apply.
    # Values are not compared at all - syncconf applies those correctly, the
    # problem is exactly removal.
    # No state (first install, lost file) - stay quiet: there is nothing to
    # compare against, and guessing at a warning is worse than not warning.
    # The historical upstream snapshot describes awg0 only. Applying awg1 must
    # not read or overwrite the primary interface's fingerprint.
    local track_device_params=0
    [[ "$iface" == "awg0" ]] && track_device_params=1
    local params_state="${AWG_DIR}/.awg_device_params"
    local now_fp="" prev_fp="" removed=""
    if [[ "$track_device_params" -eq 1 && -r "$SERVER_CONF_FILE" ]]; then
        # The path is passed explicitly even though it is also the default:
        # otherwise shellcheck 0.9 (the version CI installs) rightly raises
        # SC2120 about a parameter nobody ever passes.
        now_fp="$(_awg_device_params_fingerprint "$SERVER_CONF_FILE" 2>/dev/null)" || now_fp=""
        [[ -r "$params_state" ]] && IFS= read -r prev_fp 2>/dev/null < "$params_state"
        # ⚠️ An empty set against a non-empty previous one is NOT treated as
        # "everything was removed". Our generator always writes Jc/S/H, so
        # emptiness means a partially read or currently rewritten file rather
        # than a real cleanup. Stay quiet: a false alarm costs more here than a
        # missed one.
        if [[ -n "$prev_fp" && -n "$now_fp" ]]; then
            local _p
            for _p in $prev_fp; do
                [[ " $now_fp " == *" $_p "* ]] || removed+="${removed:+, }$_p"
            done
        fi
    fi

    if [[ "${AWG_APPLY_MODE:-syncconf}" == "restart" || "$iface" != awg0 ]]; then
        # An explicit restart mode drops client connections, SSH through the
        # tunnel included, so warn exactly as manage restart does.
        [[ "$track_device_params" -eq 1 ]] && awg_warn_interface_disruption
        log "Restarting service ${iface} (preflight passed; routing/device changes require restart)..."
        if systemctl restart "awg-quick@${iface}" 2>/dev/null; then
            systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; rc=$?
        else
            rc=$?
        fi
        if [[ $rc -ne 0 ]]; then
            log_warn "Service restart error (${iface})."
        elif [[ "$track_device_params" -eq 1 ]]; then
            awg_record_device_params
        fi
        exec {apply_fd}>&-
        return $rc
    fi

    # 🔴 A detected removal is NOT restarted for you - it is reported.
    # The first revision of this change restarted the service automatically, and
    # that was WORSE than the trap it closed: a restart drops EVERY client
    # connection, and the state can fall behind through no fault of the user.
    # Example: someone drops the line and applies it with `manage restart` - the
    # interface is already recreated and the parameter already cleared, but the
    # snapshot still holds the old set, so the next ordinary `add` would see the
    # "removal" a second time and cut everyone off again. A false warning costs
    # a log line; a false restart costs everyone's connection. So we speak, and
    # the human decides.
    # ⚠️ The snapshot is NOT updated here. It is updated only AFTER a successful
    # apply, below. An earlier revision updated it right away, and that silenced
    # the warning forever whenever the apply then failed: the state had already
    # "caught up" with the file while nothing had changed on the live interface.
    if [[ -n "$removed" ]]; then
        log_warn "Removed from the [Interface] section: ${removed}."
        log_warn "  syncconf does NOT clear such parameters - they stay on the live interface."
        log_warn "  To make the removal take effect the interface has to be recreated:"
        log_warn "    systemctl restart awg-quick@awg0"
        log_warn "  That drops every client connection for a few seconds, which is why we do"
        log_warn "  not do it for you. If you have already restarted the service by hand, this"
        log_warn "  warning can be ignored: after a successful apply the snapshot is"
        log_warn "  refreshed and this line will not appear on later runs."
    fi

    printf '%s\n' "$strip_out" | timeout 10 awg syncconf "${iface}" /dev/stdin 2>/dev/null || {
        log_warn "awg syncconf ${iface} failed or timed out; no automatic full restart is attempted."
        exec {apply_fd}>&-
        return 1
    }
    log_debug "Config ${iface} applied (syncconf)."
    [[ "$track_device_params" -eq 1 ]] && awg_record_device_params
    exec {apply_fd}>&-
    return 0
}

# ==============================================================================
# Multi-hop (cascade): upstream tunnel for role=entry
# ==============================================================================
#
# On the entry node we bring up a second interface (default awg1) that acts as
# a client to the upstream exit server. Client traffic (from
# $AWG_TUNNEL_SUBNET) is policy-routed into that interface:
#
#   Table=<N>       — awg-quick places AllowedIPs routes in table N instead of
#                     main (without touching the entry node's own egress)
#   FwMark=<mark>   — distinct from 0xca6c (wg-quick default) to avoid clash
#                     with awg0 policy rules
#   ip rule from <subnet> table N  — sends only client packets into the
#                                    cascade; entry's own traffic (SSH, awg1
#                                    keepalive) goes via main table
#   MASQUERADE -o %i — rewrites client src (10.X.X.X) to entry's awg1 IP,
#                     otherwise the exit server would drop it on AllowedIPs
#
# Between awg1 and the exit, S1-S4/H1-H4 and HeaderProtectionKey (when set)
# must match. The receiver does not compare Jc/Jmin/Jmax or I1-I5.
#
# Command-injection hardening: values extracted from the upstream conf (keys,
# IP and Endpoint) go through typed/control checks and are written to the output
# via awg_mktemp + mv, never through eval.

# Validate interface name (protect systemctl/iptables from injection)
_validate_iface_name() {
    local n="$1"
    [[ "$n" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]]
}

# AWG 3.0 stores six timers/counters as a u16 range: "N" or "N-M".
# Validate the format before copying it from an external client config.
_valid_awg_u16_range() {
    local value="$1" lo hi
    [[ "$value" =~ ^([0-9]{1,5})(-([0-9]{1,5}))?$ ]] || return 1
    lo="${BASH_REMATCH[1]}"
    hi="${BASH_REMATCH[3]:-${BASH_REMATCH[1]}}"
    (( 10#$lo <= 65535 && 10#$hi <= 65535 && 10#$lo <= 10#$hi ))
}

_valid_awg_decimal() {
    local value="$1" min="$2" max="$3"
    [[ "$value" =~ ^[0-9]{1,10}$ ]] || return 1
    (( 10#$value >= min && 10#$value <= max ))
}

_valid_awg_h_range() {
    local value="$1" lo hi
    [[ "$value" =~ ^([0-9]{1,10})-([0-9]{1,10})$ ]] || return 1
    lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
    (( 10#$lo <= 4294967295 && 10#$hi <= 4294967295 && 10#$lo < 10#$hi ))
}

# Canonical base64 for exactly 32 bytes: the final sextet has zero pad bits.
_valid_wg_key_b64() {
    [[ "$1" =~ ^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$ ]]
}

# Endpoint from the imported config: IPv4/FQDN:port or [IPv6]:port.
_valid_upstream_endpoint() {
    local value="$1" host port
    if [[ "$value" =~ ^\[([^]]+)\]:([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        _valid_ipv6 "$host" || return 1
    elif [[ "$value" =~ ^([^:]+):([0-9]{1,5})$ ]]; then
        host="${BASH_REMATCH[1]}"
        port="${BASH_REMATCH[2]}"
        _valid_host_or_ipv4 "$host" || return 1
    else
        return 1
    fi
    (( 10#$port >= 1 && 10#$port <= 65535 ))
}

_validate_upstream_structure() {
    local f="$1"
    [[ -f "$f" && ! -L "$f" ]] || return 1
    awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[/ {
            line=$0; gsub(/[[:space:]]/, "", line)
            if (line == "[Interface]") { section="Interface"; interfaces++; next }
            if (line == "[Peer]") { section="Peer"; peers++; next }
            exit 10
        }
        index($0, "=") && (section == "Interface" || section == "Peer") {
            key=$0; sub(/=.*/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == "" || ++seen[section SUBSEP key] > 1) exit 11
        }
        END { if (interfaces != 1 || peers != 1) exit 12 }
    ' "$f"
}

# Extract a key's value from the [Interface] or [Peer] section of an upstream
# config. _extract_upstream_field <file> <section: Interface|Peer> <key>
# Prints the value to stdout; returns 1 if not found.
_extract_upstream_field() {
    local f="$1" sect="$2" key="$3"
    [[ -f "$f" ]] || return 1
    awk -v sect="$sect" -v key="$key" '
        /^\[/ { in_sect = ($0 == "[" sect "]"); next }
        in_sect && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
            sub("[[:space:]]+$", "")
            value=$0; found=1
        }
        END { if (found) print value; else exit 1 }
    ' "$f"
}

# Typed, side-effect-free preflight for configs which may be followed by a
# disruptive wg/awg-quick restart. `awg-quick strip` is intentionally not used
# as a validator: upstream wg-quick only removes its own keys and echoes the
# remaining config without asking wg/awg to parse it.
#
# Modes:
#   server   - generated awg0.conf (one Interface, zero or more Peers)
#   upstream - generated cascade client (one Interface and one Peer)
#   warp     - wgcf/wg-quick config (one Interface and one Peer, no AWG keys)
_quick_config_structure_valid() {
    local f="$1" mode="$2"
    [[ -f "$f" && ! -L "$f" ]] || return 1
    [[ "$mode" == server || "$mode" == upstream || "$mode" == warp ]] || return 1
    awk -v mode="$mode" '
        function iface_key_ok(k) {
            if (mode == "upstream" && k ~ /^(DNS|ListenPort|SaveConfig|PreUp|PostDown)$/) return 0
            if (mode == "warp" && k ~ /^(PreUp|PostUp|PreDown|PostDown)$/) return 0
            if (k ~ /^(PrivateKey|Address|DNS|MTU|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig|ListenPort|FwMark)$/) return 1
            if (mode != "warp" && k ~ /^(Jc|Jmin|Jmax|S1|S2|S3|S4|H1|H2|H3|H4|I1|I2|I3|I4|I5|ContentPaddingAddition|HeaderProtectionKey|MaxHandshakeAttempts|KeepaliveTimeout|RejectAfterTime|RekeyAfterTime|RekeyTimeout)$/) return 1
            return 0
        }
        function peer_key_ok(k) {
            return k ~ /^(PublicKey|PresharedKey|Endpoint|AllowedIPs|PersistentKeepalive)$/
        }
        function repeatable(k) {
            if (k ~ /^(PreUp|PostUp|PreDown|PostDown)$/) return 1
            return mode == "warp" && k ~ /^(Address|DNS)$/
        }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[/ {
            header=$0; gsub(/[[:space:]]/, "", header)
            if (header == "[Interface]") {
                interfaces++
                if (interfaces != 1 || peers != 0) bad=1
                section="I"; sid="I"
            } else if (header == "[Peer]") {
                if (interfaces != 1) bad=1
                peers++; section="P"; sid="P" peers
            } else {
                bad=1; section=""; sid=""
            }
            next
        }
        {
            if (section == "" || index($0, "=") == 0 || index($0, "\r") != 0) { bad=1; next }
            key=$0; sub(/=.*/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]+$/, "", value)
            if (key == "" || value == "" || index(value, "\t") != 0) { bad=1; next }
            if ((section == "I" && !iface_key_ok(key)) || (section == "P" && !peer_key_ok(key))) { bad=1; next }
            count[sid SUBSEP key]++
            if (count[sid SUBSEP key] > 1 && !repeatable(key)) bad=1
        }
        END {
            if (bad || interfaces != 1) exit 20
            if ((mode == "upstream" || mode == "warp") && peers != 1) exit 21
            if (count["I" SUBSEP "PrivateKey"] != 1 || count["I" SUBSEP "Address"] < 1) exit 22
            if (mode == "server" && (count["I" SUBSEP "Address"] != 1 || count["I" SUBSEP "MTU"] != 1 || count["I" SUBSEP "ListenPort"] != 1)) exit 23
            if (mode == "upstream" && (count["I" SUBSEP "Address"] != 1 || count["I" SUBSEP "MTU"] != 1 || count["I" SUBSEP "Table"] != 1 || count["I" SUBSEP "FwMark"] != 1)) exit 24
            if (mode != "warp") {
                required="Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4"
                n=split(required, req, " ")
                for (i=1; i<=n; i++) if (count["I" SUBSEP req[i]] != 1) exit 25
            }
            for (p=1; p<=peers; p++) {
                psid="P" p
                if (count[psid SUBSEP "PublicKey"] != 1 || count[psid SUBSEP "AllowedIPs"] != 1) exit 26
                if ((mode == "upstream" || mode == "warp") && count[psid SUBSEP "Endpoint"] != 1) exit 27
            }
        }
    ' "$f"
}

_quick_config_field_values() {
    local f="$1" wanted_section="$2" wanted_key="$3"
    awk -v wanted_section="$wanted_section" -v wanted_key="$wanted_key" '
        /^[[:space:]]*\[/ {
            header=$0; gsub(/[[:space:]]/, "", header)
            section=(header == "[" wanted_section "]")
            next
        }
        section && index($0, "=") {
            key=$0; sub(/=.*/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (key == wanted_key) {
                value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]+$/, "", value)
                print value
            }
        }
    ' "$f"
}

_quick_config_peer_records() {
    local f="$1"
    awk '
        /^[[:space:]]*\[/ {
            header=$0; gsub(/[[:space:]]/, "", header)
            if (header == "[Peer]") { peer++; in_peer=1 } else in_peer=0
            next
        }
        in_peer && index($0, "=") {
            key=$0; sub(/=.*/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]+$/, "", value)
            print peer "\t" key "\t" value
        }
    ' "$f"
}

_AWG_QUICK_CIDR_COUNT=0
_AWG_QUICK_CIDR_V4=0
_AWG_QUICK_CIDR_V6=0
_validate_quick_cidr_list() {
    local raw="$1" compact item addr prefix
    local -a items=()
    _AWG_QUICK_CIDR_COUNT=0; _AWG_QUICK_CIDR_V4=0; _AWG_QUICK_CIDR_V6=0
    compact="${raw//[[:space:]]/}"
    [[ -n "$compact" && "$compact" != ,* && "$compact" != *, && "$compact" != *,,* ]] || return 1
    IFS=',' read -r -a items <<< "$raw"
    for item in "${items[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" && "$item" == */* && "$item" != *[[:space:]]* ]] || return 1
        addr="${item%/*}"; prefix="${item##*/}"
        [[ "$prefix" =~ ^[0-9]{1,3}$ ]] || return 1
        _valid_cidr "$item" || return 1
        if _valid_ipv4 "$addr"; then
            _valid_canonical_ipv4 "$addr" || return 1
            _AWG_QUICK_CIDR_V4=$(( _AWG_QUICK_CIDR_V4 + 1 ))
        else
            _AWG_QUICK_CIDR_V6=$(( _AWG_QUICK_CIDR_V6 + 1 ))
        fi
        _AWG_QUICK_CIDR_COUNT=$(( _AWG_QUICK_CIDR_COUNT + 1 ))
    done
    (( _AWG_QUICK_CIDR_COUNT > 0 ))
}

_AWG_QUICK_FWMARK_NUM=0
_validate_quick_fwmark() {
    local value="$1"
    _AWG_QUICK_FWMARK_NUM=0
    [[ "$value" != off ]] || return 0
    if [[ "$value" =~ ^0x[0-9A-Fa-f]{1,8}$ ]]; then
        _AWG_QUICK_FWMARK_NUM=$((16#${value#0x}))
    elif [[ "$value" =~ ^[0-9]{1,10}$ ]] && (( 10#$value <= 4294967295 )); then
        _AWG_QUICK_FWMARK_NUM=$((10#$value))
    else
        return 1
    fi
}

_validate_quick_table() {
    local value="$1"
    [[ "$value" == auto || "$value" == off ]] && return 0
    [[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] && (( 10#$value <= 4294967295 ))
}

_validate_quick_config_semantics() {
    local f="$1" mode="$2" value compact addr prefix peer key
    local address_lines=0 address_v4=0 address_v6=0
    _quick_config_structure_valid "$f" "$mode" || return 1

    value=$(_extract_upstream_field "$f" Interface PrivateKey) || value=""
    _valid_wg_key_b64 "$value" || return 1

    while IFS= read -r value; do
        address_lines=$(( address_lines + 1 ))
        _validate_quick_cidr_list "$value" || return 1
        address_v4=$(( address_v4 + _AWG_QUICK_CIDR_V4 ))
        address_v6=$(( address_v6 + _AWG_QUICK_CIDR_V6 ))
        if [[ "$mode" == upstream ]]; then
            compact="${value//[[:space:]]/}"
            (( _AWG_QUICK_CIDR_COUNT == 1 && _AWG_QUICK_CIDR_V4 == 1 )) || return 1
            addr="${compact%/*}"; prefix="${compact##*/}"
            _valid_canonical_ipv4 "$addr" && (( 10#$prefix == 32 )) || return 1
        fi
    done < <(_quick_config_field_values "$f" Interface Address)
    (( address_lines > 0 && address_v4 > 0 )) || return 1
    if [[ "$mode" == server ]]; then
        (( address_lines == 1 && address_v4 == 1 && address_v6 <= 1 )) || return 1
    fi

    value=$(_extract_upstream_field "$f" Interface MTU) || value=""
    [[ -z "$value" ]] || _validate_mtu "$value" || return 1
    if [[ "$mode" == server || "$mode" == upstream ]]; then [[ -n "$value" ]] || return 1; fi
    if [[ "$mode" == upstream && "$value" != 1380 ]]; then return 1; fi

    value=$(_extract_upstream_field "$f" Interface ListenPort) || value=""
    if [[ -n "$value" ]]; then
        [[ "$value" =~ ^[0-9]{1,5}$ ]] && (( 10#$value >= 1 && 10#$value <= 65535 )) || return 1
    elif [[ "$mode" == server ]]; then
        return 1
    fi

    value=$(_extract_upstream_field "$f" Interface Table) || value=""
    [[ -z "$value" ]] || _validate_quick_table "$value" || return 1
    if [[ "$mode" == upstream ]]; then
        local expected_table="${AWG_UPSTREAM_TABLE:-123}"
        [[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] \
            && (( 10#$value <= 4294967295 )) \
            && (( 10#$value < 253 || 10#$value > 255 )) || return 1
        [[ "$expected_table" =~ ^[0-9]{1,10}$ ]] \
            && (( 10#$expected_table >= 1 && 10#$expected_table <= 4294967295 )) \
            && (( 10#$expected_table < 253 || 10#$expected_table > 255 )) \
            && (( 10#$value == 10#$expected_table )) || return 1
    fi

    value=$(_extract_upstream_field "$f" Interface FwMark) || value=""
    if [[ -n "$value" ]]; then
        _validate_quick_fwmark "$value" || return 1
        if [[ "$mode" == upstream ]]; then
            local actual_mark_num="$_AWG_QUICK_FWMARK_NUM"
            local expected_mark="${AWG_UPSTREAM_FWMARK:-0xca6d}" expected_mark_num
            (( _AWG_QUICK_FWMARK_NUM != 0 && _AWG_QUICK_FWMARK_NUM != 0xca6c )) || return 1
            _validate_quick_fwmark "$expected_mark" || return 1
            expected_mark_num="$_AWG_QUICK_FWMARK_NUM"
            (( expected_mark_num != 0 && expected_mark_num != 0xca6c \
               && actual_mark_num == expected_mark_num )) || return 1
        fi
    elif [[ "$mode" == upstream ]]; then
        return 1
    fi

    value=$(_extract_upstream_field "$f" Interface SaveConfig) || value=""
    [[ -z "$value" || "$value" == true || "$value" == false ]] || return 1

    # The cascade config is installer-generated, so its two firewall hooks are
    # invariants rather than arbitrary user shell. Exact matching gives restart
    # preflight a side-effect-free guarantee that these commands cannot fail due
    # to a malformed or injected replacement after the live iface is stopped.
    if [[ "$mode" == upstream ]]; then
        [[ -z "$(_quick_config_field_values "$f" Interface DNS)" ]] || return 1
        [[ -z "$(_quick_config_field_values "$f" Interface ListenPort)" ]] || return 1
        [[ -z "$(_quick_config_field_values "$f" Interface SaveConfig)" ]] || return 1
        value=$(_quick_config_field_values "$f" Interface PostUp)
        [[ "$value" == 'iptables -t nat -A POSTROUTING -o %i -j MASQUERADE' ]] || return 1
        value=$(_quick_config_field_values "$f" Interface PreDown)
        [[ "$value" == 'iptables -t nat -D POSTROUTING -o %i -j MASQUERADE' ]] || return 1
        [[ -z "$(_quick_config_field_values "$f" Interface PreUp)" ]] || return 1
        [[ -z "$(_quick_config_field_values "$f" Interface PostDown)" ]] || return 1
    fi

    if [[ "$mode" != warp ]]; then
        validate_awg_config "$f" || return 1
        local optional_range
        for optional_range in ContentPaddingAddition MaxHandshakeAttempts KeepaliveTimeout \
                              RejectAfterTime RekeyAfterTime RekeyTimeout; do
            value=$(_extract_upstream_field "$f" Interface "$optional_range") || value=""
            [[ -z "$value" ]] || _valid_awg_u16_range "$value" || return 1
        done
        value=$(_extract_upstream_field "$f" Interface HeaderProtectionKey) || value=""
        if [[ -n "$value" ]]; then
            _valid_wg_key_b64 "$value" || return 1
            local header_s
            for header_s in S1 S2 S3 S4; do
                compact=$(_extract_upstream_field "$f" Interface "$header_s") || compact=""
                _valid_awg_decimal "$compact" 12 65535 || return 1
            done
        fi
        local instruction
        for instruction in I1 I2 I3 I4 I5; do
            value=$(_extract_upstream_field "$f" Interface "$instruction") || value=""
            [[ -z "$value" || ( "$value" != *$'\r'* && "$value" != *$'\n'* && "$value" != *\'* && "$value" != *\"* ) ]] || return 1
        done
    fi

    while IFS=$'\t' read -r peer key value; do
        [[ -n "$peer" && -n "$key" ]] || continue
        case "$key" in
            PublicKey|PresharedKey)
                _valid_wg_key_b64 "$value" || return 1
                ;;
            Endpoint)
                _valid_upstream_endpoint "$value" || return 1
                ;;
            AllowedIPs)
                _validate_quick_cidr_list "$value" || return 1
                if [[ "$mode" == upstream ]]; then
                    compact="${value//[[:space:]]/}"
                    [[ "$compact" == "0.0.0.0/0" ]] || return 1
                elif [[ "$mode" == warp ]]; then
                    compact=",${value//[[:space:]]/},"
                    [[ "$compact" == *",0.0.0.0/0,"* ]] || return 1
                fi
                ;;
            PersistentKeepalive)
                _valid_awg_decimal "$value" 0 65535 || return 1
                ;;
        esac
    done < <(_quick_config_peer_records "$f")
    return 0
}

# Build and write the upstream (awg1) interface config for the cascade.
# Expects env:
#   AWG_UPSTREAM_CONF     — path to .conf from `manage add` on the exit node
#   AWG_UPSTREAM_IFACE    — interface name (default awg1)
#   AWG_UPSTREAM_TABLE    — routing table number (default 123)
#   AWG_UPSTREAM_FWMARK   — fwmark (default 0xca6d, not 0xca6c like wg-quick)
#   AWG_UPSTREAM_PRIORITY — ip rule priority (default 456)
#   AWG_TUNNEL_SUBNET     — client subnet for the from-rule
render_upstream_config() {
    local src="${AWG_UPSTREAM_CONF:-}"
    local iface="${AWG_UPSTREAM_IFACE:-awg1}"
    local tbl="${AWG_UPSTREAM_TABLE:-123}"
    local fwmark="${AWG_UPSTREAM_FWMARK:-0xca6d}"
    local prio="${AWG_UPSTREAM_PRIORITY:-456}"
    local client_subnet="${AWG_TUNNEL_SUBNET:-}" client_subnet_raw

    if [[ -z "$src" || ! -f "$src" ]]; then
        log_error "render_upstream_config: AWG_UPSTREAM_CONF not set or file missing: '$src'"
        return 1
    fi
    if ! _validate_upstream_structure "$src"; then
        log_error "render_upstream_config: exactly one [Interface], one [Peer], and unique section keys are required"
        return 1
    fi
    if ! _validate_iface_name "$iface"; then
        log_error "render_upstream_config: invalid interface name '$iface'"
        return 1
    fi
    if ! [[ "$tbl" =~ ^[0-9]{1,10}$ ]] \
        || (( 10#$tbl < 1 || 10#$tbl > 4294967295 \
              || (10#$tbl >= 253 && 10#$tbl <= 255) )); then
        log_error "render_upstream_config: invalid Table='$tbl'"
        return 1
    fi
    local fwmark_num
    if [[ "$fwmark" =~ ^0x[0-9a-fA-F]{1,8}$ ]]; then
        fwmark_num=$((16#${fwmark#0x}))
    elif ! [[ "$fwmark" =~ ^[0-9]{1,10}$ ]] \
        || (( 10#$fwmark > 4294967295 )); then
        log_error "render_upstream_config: invalid FwMark='$fwmark'"
        return 1
    else
        fwmark_num=$((10#$fwmark))
    fi
    if (( fwmark_num == 0 || fwmark_num == 0xca6c )); then
        log_error "render_upstream_config: FwMark='$fwmark' is zero or conflicts with awg0"
        return 1
    fi
    if ! [[ "$prio" =~ ^[0-9]{1,5}$ ]] \
        || (( 10#$prio < 1 || 10#$prio > 32764 )); then
        log_error "render_upstream_config: invalid priority='$prio'"
        return 1
    fi
    if [[ -z "$client_subnet" ]]; then
        log_error "render_upstream_config: AWG_TUNNEL_SUBNET not set"
        return 1
    fi
    client_subnet_raw="$client_subnet"
    client_subnet=$(_awg_network_cidr "$client_subnet") || {
        log_error "render_upstream_config: invalid client subnet '$client_subnet_raw'"
        return 1
    }
    tbl=$((10#$tbl))
    prio=$((10#$prio))
    [[ "$fwmark" == 0x* ]] || fwmark=$((10#$fwmark))

    # Extract fields from the upstream config
    local u_priv u_addr u_pub u_psk u_endpoint u_keepalive
    local u_jc u_jmin u_jmax u_s1 u_s2 u_s3 u_s4 u_h1 u_h2 u_h3 u_h4
    local u_i1 u_i2 u_i3 u_i4 u_i5
    local u_padding u_header_key u_max_handshakes u_keepalive_timeout
    local u_reject_after u_rekey_after u_rekey_timeout
    u_priv=$(_extract_upstream_field "$src" Interface PrivateKey) || u_priv=""
    u_addr=$(_extract_upstream_field "$src" Interface Address) || u_addr=""
    u_jc=$(_extract_upstream_field   "$src" Interface Jc) || u_jc=""
    u_jmin=$(_extract_upstream_field "$src" Interface Jmin) || u_jmin=""
    u_jmax=$(_extract_upstream_field "$src" Interface Jmax) || u_jmax=""
    u_s1=$(_extract_upstream_field   "$src" Interface S1) || u_s1=""
    u_s2=$(_extract_upstream_field   "$src" Interface S2) || u_s2=""
    u_s3=$(_extract_upstream_field   "$src" Interface S3) || u_s3=""
    u_s4=$(_extract_upstream_field   "$src" Interface S4) || u_s4=""
    u_h1=$(_extract_upstream_field   "$src" Interface H1) || u_h1=""
    u_h2=$(_extract_upstream_field   "$src" Interface H2) || u_h2=""
    u_h3=$(_extract_upstream_field   "$src" Interface H3) || u_h3=""
    u_h4=$(_extract_upstream_field   "$src" Interface H4) || u_h4=""
    u_i1=$(_extract_upstream_field   "$src" Interface I1) || u_i1=""
    u_i2=$(_extract_upstream_field   "$src" Interface I2) || u_i2=""
    u_i3=$(_extract_upstream_field   "$src" Interface I3) || u_i3=""
    u_i4=$(_extract_upstream_field   "$src" Interface I4) || u_i4=""
    u_i5=$(_extract_upstream_field   "$src" Interface I5) || u_i5=""
    u_padding=$(_extract_upstream_field "$src" Interface ContentPaddingAddition) || u_padding=""
    u_header_key=$(_extract_upstream_field "$src" Interface HeaderProtectionKey) || u_header_key=""
    u_max_handshakes=$(_extract_upstream_field "$src" Interface MaxHandshakeAttempts) || u_max_handshakes=""
    u_keepalive_timeout=$(_extract_upstream_field "$src" Interface KeepaliveTimeout) || u_keepalive_timeout=""
    u_reject_after=$(_extract_upstream_field "$src" Interface RejectAfterTime) || u_reject_after=""
    u_rekey_after=$(_extract_upstream_field "$src" Interface RekeyAfterTime) || u_rekey_after=""
    u_rekey_timeout=$(_extract_upstream_field "$src" Interface RekeyTimeout) || u_rekey_timeout=""
    u_pub=$(_extract_upstream_field      "$src" Peer PublicKey) || u_pub=""
    u_psk=$(_extract_upstream_field      "$src" Peer PresharedKey) || u_psk=""
    u_endpoint=$(_extract_upstream_field "$src" Peer Endpoint) || u_endpoint=""
    u_keepalive=$(_extract_upstream_field "$src" Peer PersistentKeepalive) || u_keepalive=""

    if [[ -z "$u_priv" || -z "$u_addr" || -z "$u_pub" || -z "$u_endpoint" ]]; then
        log_error "render_upstream_config: $src is missing required fields"
        log_error "  (Interface.PrivateKey/Address, Peer.PublicKey/Endpoint)"
        return 1
    fi
    # All 11 AWG 2.0 fields must be in the upstream config (else handshake fails)
    local f miss=0
    for f in u_jc u_jmin u_jmax u_s1 u_s2 u_s3 u_s4 u_h1 u_h2 u_h3 u_h4; do
        if [[ -z "${!f}" ]]; then
            log_error "render_upstream_config: $src is missing ${f#u_}"
            miss=1
        fi
    done
    (( miss == 0 )) || return 1

    # Reject newline/CR/quotes in extracted values — defence against injection
    # into the output config via a forged upstream .conf
    for f in u_priv u_addr u_pub u_psk u_endpoint u_keepalive \
             u_jc u_jmin u_jmax u_s1 u_s2 u_s3 u_s4 u_h1 u_h2 u_h3 u_h4 \
             u_i1 u_i2 u_i3 u_i4 u_i5 u_padding u_header_key u_max_handshakes \
             u_keepalive_timeout u_reject_after u_rekey_after u_rekey_timeout; do
        local v="${!f}"
        if [[ "$v" == *$'\n'* || "$v" == *$'\r'* || "$v" == *\'* || "$v" == *\"* ]]; then
            log_error "render_upstream_config: suspicious chars in ${f#u_}, rejected"
            return 1
        fi
    done

    if ! _valid_wg_key_b64 "$u_priv" || ! _valid_wg_key_b64 "$u_pub" \
        || { [[ -n "$u_psk" ]] && ! _valid_wg_key_b64 "$u_psk"; }; then
        log_error "render_upstream_config: invalid 32-byte base64 WireGuard key"
        return 1
    fi
    if ! _valid_awg_decimal "$u_jc" 1 128 \
        || ! _valid_awg_decimal "$u_jmin" 0 1280 \
        || ! _valid_awg_decimal "$u_jmax" 0 1280 \
        || (( 10#$u_jmin > 10#$u_jmax )); then
        log_error "render_upstream_config: invalid Jc/Jmin/Jmax (Jc=1-128, J=0-1280, Jmin<=Jmax)"
        return 1
    fi
    if ! _valid_awg_decimal "$u_s1" 0 65535 \
        || ! _valid_awg_decimal "$u_s2" 0 65535 \
        || ! _valid_awg_decimal "$u_s3" 0 64 \
        || ! _valid_awg_decimal "$u_s4" 0 32; then
        log_error "render_upstream_config: invalid S1-S4"
        return 1
    fi
    local -a h_lows=() h_highs=() h_names=()
    local h_value h_i h_j
    for f in u_h1 u_h2 u_h3 u_h4; do
        h_value="${!f}"
        if ! _valid_awg_h_range "$h_value"; then
            log_error "render_upstream_config: invalid ${f#u_} range '$h_value'"
            return 1
        fi
        h_lows+=("$((10#${h_value%-*}))")
        h_highs+=("$((10#${h_value#*-}))")
        h_names+=("${f#u_}")
    done
    for ((h_i = 0; h_i < 4; h_i++)); do
        for ((h_j = h_i + 1; h_j < 4; h_j++)); do
            if (( h_lows[h_i] <= h_highs[h_j] && h_lows[h_j] <= h_highs[h_i] )); then
                log_error "render_upstream_config: ${h_names[h_i]} and ${h_names[h_j]} ranges overlap"
                return 1
            fi
        done
    done

    # Select IPv4 from a dual-stack Address and canonicalize the interface
    # address to /32. Never interpolate an external config before type checks.
    local address_item address_ip="" address_prefix
    local -a address_items=()
    IFS=',' read -ra address_items <<< "$u_addr"
    for address_item in "${address_items[@]}"; do
        address_item="${address_item#"${address_item%%[![:space:]]*}"}"
        address_item="${address_item%"${address_item##*[![:space:]]}"}"
        [[ "$address_item" == */* ]] || continue
        address_ip="${address_item%/*}"
        address_prefix="${address_item##*/}"
        if _valid_ipv4 "$address_ip" \
            && [[ "$address_prefix" =~ ^[0-9]{1,2}$ ]] \
            && (( 10#$address_prefix <= 32 )); then
            u_addr="${address_ip}/32"
            break
        fi
        address_ip=""
    done
    if [[ -z "$address_ip" ]]; then
        log_error "render_upstream_config: invalid IPv4 Address='$u_addr'"
        return 1
    fi
    if ! _valid_upstream_endpoint "$u_endpoint"; then
        log_error "render_upstream_config: invalid Endpoint='$u_endpoint'"
        return 1
    fi
    if [[ -n "$u_keepalive" ]] \
        && { ! [[ "$u_keepalive" =~ ^[0-9]{1,5}$ ]] || (( 10#$u_keepalive > 65535 )); }; then
        log_error "render_upstream_config: invalid PersistentKeepalive='$u_keepalive'"
        return 1
    fi
    if [[ -n "$u_header_key" ]] && ! _valid_wg_key_b64 "$u_header_key"; then
        log_error "render_upstream_config: invalid HeaderProtectionKey"
        return 1
    fi
    if [[ -n "$u_header_key" ]]; then
        local header_s
        for header_s in u_s1 u_s2 u_s3 u_s4; do
            if ! [[ "${!header_s}" =~ ^[0-9]{1,5}$ ]] \
                || (( 10#${!header_s} < 12 || 10#${!header_s} > 65535 )); then
                log_error "render_upstream_config: HeaderProtectionKey requires S1-S4 in the 12-65535 range"
                return 1
            fi
        done
    fi
    local range_field
    for range_field in u_padding u_max_handshakes u_keepalive_timeout \
                       u_reject_after u_rekey_after u_rekey_timeout; do
        if [[ -n "${!range_field}" ]] && ! _valid_awg_u16_range "${!range_field}"; then
            log_error "render_upstream_config: invalid ${range_field#u_} range '${!range_field}'"
            return 1
        fi
    done

    local out_conf
    out_conf="$(dirname "$SERVER_CONF_FILE")/${iface}.conf"

    local conf_dir
    conf_dir=$(dirname "$out_conf")
    mkdir -p "$conf_dir" || { log_error "Failed to create $conf_dir"; return 1; }

    local tmpfile
    tmpfile=$(awg_mktemp "$conf_dir") || { log_error "mktemp failed"; return 1; }

    local write_failed=0
    if ! {
        printf '%s\n' \
            '[Interface]' \
            "PrivateKey = ${u_priv}" \
            "Address = ${u_addr}" \
            'MTU = 1380' \
            "Table = ${tbl}" \
            "FwMark = ${fwmark}" \
            'PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE' \
            'PreDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE' \
            "Jc = ${u_jc}" "Jmin = ${u_jmin}" "Jmax = ${u_jmax}" \
            "S1 = ${u_s1}" "S2 = ${u_s2}" "S3 = ${u_s3}" "S4 = ${u_s4}" \
            "H1 = ${u_h1}" "H2 = ${u_h2}" "H3 = ${u_h3}" "H4 = ${u_h4}" \
            || write_failed=1
        [[ -z "$u_i1" ]] || printf 'I1 = %s\n' "$u_i1" || write_failed=1
        [[ -z "$u_i2" ]] || printf 'I2 = %s\n' "$u_i2" || write_failed=1
        [[ -z "$u_i3" ]] || printf 'I3 = %s\n' "$u_i3" || write_failed=1
        [[ -z "$u_i4" ]] || printf 'I4 = %s\n' "$u_i4" || write_failed=1
        [[ -z "$u_i5" ]] || printf 'I5 = %s\n' "$u_i5" || write_failed=1
        [[ -z "$u_padding" ]] || printf 'ContentPaddingAddition = %s\n' "$u_padding" || write_failed=1
        [[ -z "$u_header_key" ]] || printf 'HeaderProtectionKey = %s\n' "$u_header_key" || write_failed=1
        [[ -z "$u_max_handshakes" ]] || printf 'MaxHandshakeAttempts = %s\n' "$u_max_handshakes" || write_failed=1
        [[ -z "$u_keepalive_timeout" ]] || printf 'KeepaliveTimeout = %s\n' "$u_keepalive_timeout" || write_failed=1
        [[ -z "$u_reject_after" ]] || printf 'RejectAfterTime = %s\n' "$u_reject_after" || write_failed=1
        [[ -z "$u_rekey_after" ]] || printf 'RekeyAfterTime = %s\n' "$u_rekey_after" || write_failed=1
        [[ -z "$u_rekey_timeout" ]] || printf 'RekeyTimeout = %s\n' "$u_rekey_timeout" || write_failed=1
        printf '\n[Peer]\nPublicKey = %s\n' "$u_pub" || write_failed=1
        [[ -z "$u_psk" ]] || printf 'PresharedKey = %s\n' "$u_psk" || write_failed=1
        printf 'Endpoint = %s\nAllowedIPs = 0.0.0.0/0\nPersistentKeepalive = %s\n' \
            "$u_endpoint" "${u_keepalive:-25}" || write_failed=1
        (( write_failed == 0 ))
    } > "$tmpfile"; then
        rm -f "$tmpfile"
        log_error "Failed to write temporary upstream config"
        return 1
    fi

    chmod 600 "$tmpfile" || { rm -f "$tmpfile"; log_error "Failed to chmod upstream config"; return 1; }
    if ! mv -f "$tmpfile" "$out_conf"; then
        rm -f "$tmpfile"
        log_error "Failed to write upstream config $out_conf"
        return 1
    fi
    log "Upstream interface ${iface} written: $out_conf (table=${tbl}, fwmark=${fwmark})"
    return 0
}

# ==============================================================================
# WARP egress: route client traffic through Cloudflare WARP
# ==============================================================================
#
# Used on role=exit / role=single when the operator wants external sites to
# see a Cloudflare IP instead of the VPS IP. Implementation:
#
#   1. wgcf is fetched from github.com/ViRb3/wgcf (a pinned release with
#      prebuilt binaries for amd64/arm64/armv7) and verified with SHA-256.
#   2. `wgcf register` creates a free WARP Cloudflare account (account.toml).
#   3. `wgcf generate` produces a wg-quick config with real account keys.
#   4. We patch the config: Table=off (do NOT touch the host default route —
#      otherwise SSH dies) and strip DNS=... (otherwise resolv.conf is
#      overwritten with WARP's).
#   5. Enable wg-quick@wgcf — wgcf link comes up without installing routes
#      into the main table thanks to Table=off.
#
# The concrete iptables/ip rule rules that steer clients into wgcf live in
# awg0's PostUp/PostDown (see render_server_config, AWG_EGRESS=warp branch).
# This function prepares only the wgcf side.

# Download the wgcf binary from GitHub Releases for the current arch.
# Idempotent: if /usr/local/bin/wgcf is already present, does nothing.
_download_wgcf_binary() {
    local mode="${1:-apply}" arch expected_sha
    [[ "$mode" == apply || "$mode" == preflight ]] || return 1
    local wgcf_version="2.2.32"
    case "$(uname -m)" in
        x86_64|amd64)
            arch="amd64"
            expected_sha="2ff97f2201972ce582a424455d50a3719a380eef0cd1f3144f7779348e122a2c"
            ;;
        aarch64|arm64)
            arch="arm64"
            expected_sha="21fe21d9f61db9b381d71200f6f59c7949e0bb455446edcb33dda6ad6a8fcf8f"
            ;;
        armv7l|armv7)
            arch="armv7"
            expected_sha="5e25a45b52d2183dc4d9d594d82fda70fa8b421753c4544351c31bca12c36822"
            ;;
        *) log_error "Architecture $(uname -m) is not supported by wgcf"; return 1 ;;
    esac
    command -v sha256sum >/dev/null 2>&1 \
        || { log_error "sha256sum was not found; wgcf cannot be installed safely"; return 1; }
    local target="/usr/local/bin/wgcf"
    local binary_marker="${AWG_DIR}/.wgcf_binary_installed_by_installer"
    local owned_binary="" actual_sha=""
    if [[ -e "$binary_marker" || -L "$binary_marker" ]]; then
        [[ -f "$binary_marker" && ! -L "$binary_marker" ]] \
            || { log_error "Invalid ownership marker $binary_marker"; return 1; }
        owned_binary=$(<"$binary_marker")
        [[ "$owned_binary" == "$target" && "$owned_binary" != *$'\n'* ]] \
            || { log_error "Invalid ownership marker $binary_marker"; return 1; }
    fi
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] \
            || { log_error "Refusing to use unsafe $target"; return 1; }
        actual_sha=$(sha256sum -- "$target" 2>/dev/null | awk '{print $1}') \
            || { log_error "Failed to verify SHA-256 for $target"; return 1; }
        if [[ "$actual_sha" == "$expected_sha" ]]; then
            log_debug "Verified wgcf v${wgcf_version} is already installed: $target"
            return 0
        fi
        if [[ "$owned_binary" != "$target" ]]; then
            log_error "Refusing to overwrite unverified $target without an ownership marker."
            return 1
        fi
    elif [[ -n "$owned_binary" ]]; then
        log_error "Stale ownership marker $binary_marker: $target is missing."
        return 1
    fi
    [[ "$mode" == apply ]] || return 0
    if command -v wgcf >/dev/null 2>&1 && [[ "$(command -v wgcf)" != "$target" ]]; then
        log_warn "Ignoring third-party wgcf from PATH: $(command -v wgcf); installing verified $target."
    fi
    local url="https://github.com/ViRb3/wgcf/releases/download/v${wgcf_version}/wgcf_${wgcf_version}_linux_${arch}"
    log "Downloading wgcf v${wgcf_version}: $url"
    mkdir -p /usr/local/bin || { log_error "mkdir /usr/local/bin"; return 1; }
    local wgcf_tmp
    wgcf_tmp=$(awg_mktemp /usr/local/bin) || { log_error "mktemp for wgcf"; return 1; }
    if ! curl -fsSL --max-time 60 --retry 2 -o "$wgcf_tmp" "$url"; then
        log_error "Failed to download wgcf"
        rm -f "$wgcf_tmp"
        return 1
    fi
    if ! printf '%s  %s\n' "$expected_sha" "$wgcf_tmp" \
        | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$wgcf_tmp"
        log_error "wgcf v${wgcf_version} (${arch}) SHA-256 mismatch; installation aborted"
        return 1
    fi
    chmod 0755 "$wgcf_tmp" || { rm -f "$wgcf_tmp"; log_error "chmod wgcf"; return 1; }
    [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] || _AWG_WARP_TX_DIRTY=1
    mv -f "$wgcf_tmp" "$target" \
        || { rm -f "$wgcf_tmp"; log_error "install wgcf"; return 1; }
    log "wgcf installed: $target"
    return 0
}

# Migrate ownership left by older fork versions to the granular model. Legacy
# code always left an empty service marker and modified an existing wgcf.conf,
# so the config is managed (may be normalized) but not installer-created
# (uninstall must preserve it). The legacy implementation only used iface=wgcf.
_AWG_WARP_LEGACY_MIGRATION_NEEDED=0
migrate_legacy_warp_ownership() {
    local warp_iface="${1:-${AWG_WARP_IFACE:-wgcf}}" mode="${2:-apply}"
    local marker="${AWG_DIR}/.wgcf_enabled_by_installer"
    local warp_conf="/etc/wireguard/${warp_iface}.conf"
    local managed_marker="${AWG_DIR}/.wgcf_config_managed_by_installer"
    local created_marker="${AWG_DIR}/.wgcf_config_created_by_installer"

    _AWG_WARP_LEGACY_MIGRATION_NEEDED=0
    [[ "$mode" == apply || "$mode" == preflight ]] || return 1
    [[ -e "$marker" || -L "$marker" ]] || return 0
    [[ -f "$marker" && ! -L "$marker" ]] || {
        log_error "Invalid legacy WARP marker $marker"; return 1;
    }
    [[ ! -s "$marker" ]] || return 0
    if [[ "$warp_iface" != "wgcf" || ! -f "$warp_conf" || -L "$warp_conf" ]]; then
        log_error "An empty legacy WARP marker can only be migrated safely with a regular /etc/wireguard/wgcf.conf."
        return 1
    fi
    if [[ -e "$created_marker" || -L "$created_marker" ]]; then
        log_error "Legacy WARP marker conflicts with $created_marker."
        return 1
    fi
    if [[ -e "$managed_marker" || -L "$managed_marker" ]]; then
        [[ -f "$managed_marker" && ! -L "$managed_marker" \
           && "$(<"$managed_marker")" == "$warp_conf" ]] || {
            log_error "Invalid WARP managed marker $managed_marker"; return 1;
        }
    fi
    _AWG_WARP_LEGACY_MIGRATION_NEEDED=1
    [[ "$mode" == apply ]] || return 0
    [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] || _AWG_WARP_TX_DIRTY=1
    if [[ ! -e "$managed_marker" && ! -L "$managed_marker" ]]; then
        printf '%s\n' "$warp_conf" > "$managed_marker" \
            && chmod 600 "$managed_marker" \
            || { rm -f "$managed_marker"; log_error "Failed to write $managed_marker"; return 1; }
    fi
    # The old coarse marker did not preserve the unit's original state and
    # cannot prove service ownership. Drop that ambiguous claim; the config
    # remains managed+preserved and the service is treated as pre-existing.
    rm -f -- "$marker" || {
        log_error "Failed to clear ambiguous legacy WARP service marker $marker"
        return 1
    }
    log "Migrated legacy WARP conservatively: config managed, service preserved."
    return 0
}

_restore_warp_setup_state() {
    local unit="$1" was_enabled="$2" was_active="$3"
    local conf_existed="$4" conf_backup="$5" conf_path="$6"
    local failed=0 conf_dir tmp
    if systemctl is-active --quiet "$unit" 2>/dev/null \
        || ip link show "${unit#wg-quick@}" >/dev/null 2>&1; then
        systemctl stop "$unit" >/dev/null 2>&1 || true
        if ip link show "${unit#wg-quick@}" >/dev/null 2>&1; then
            if command -v wg-quick >/dev/null 2>&1 \
                && [[ -f "$conf_path" && ! -L "$conf_path" ]]; then
                wg-quick down "$conf_path" >/dev/null 2>&1 || true
            fi
        fi
        if systemctl is-active --quiet "$unit" 2>/dev/null \
            || ip link show "${unit#wg-quick@}" >/dev/null 2>&1; then
            log_error "WARP interface is still active; config rollback cancelled."
            return 1
        fi
    fi
    if [[ "$conf_existed" -eq 1 ]]; then
        conf_dir=$(dirname "$conf_path")
        if [[ ! -L "$conf_path" && ! -L "$conf_dir" && -d "$conf_dir" \
              && -f "$conf_backup" && ! -L "$conf_backup" ]]; then
            tmp=$(awg_mktemp "$conf_dir") || failed=1
            if [[ -n "${tmp:-}" ]]; then
                cp -p -- "$conf_backup" "$tmp" && mv -f -- "$tmp" "$conf_path" \
                    || failed=1
            fi
        else
            failed=1
        fi
    fi
    if [[ "$was_enabled" -eq 1 ]]; then
        systemctl enable "$unit" >/dev/null 2>&1 || failed=1
    elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        systemctl disable "$unit" >/dev/null 2>&1 || failed=1
    fi
    if [[ "$was_active" -eq 1 ]]; then
        systemctl restart "$unit" >/dev/null 2>&1 || failed=1
    elif systemctl is-active --quiet "$unit" 2>/dev/null; then
        systemctl stop "$unit" >/dev/null 2>&1 || failed=1
    fi
    return "$failed"
}

_AWG_WARP_TX_ACTIVE=0
_AWG_WARP_TX_DIRTY=0
_AWG_WARP_TX_IFACE=""
_AWG_WARP_TX_WAS_ENABLED=0
_AWG_WARP_TX_WAS_ACTIVE=0
declare -a _AWG_WARP_TX_PATHS=() _AWG_WARP_TX_HAD=() _AWG_WARP_TX_BACKUPS=()

commit_warp_egress_state() {
    local backup
    for backup in "${_AWG_WARP_TX_BACKUPS[@]}"; do
        [[ -z "$backup" || ! -f "$backup" || -L "$backup" ]] || rm -f -- "$backup"
    done
    _AWG_WARP_TX_ACTIVE=0; _AWG_WARP_TX_IFACE=""
    _AWG_WARP_TX_DIRTY=0
    _AWG_WARP_TX_WAS_ENABLED=0; _AWG_WARP_TX_WAS_ACTIVE=0
    _AWG_WARP_TX_PATHS=(); _AWG_WARP_TX_HAD=(); _AWG_WARP_TX_BACKUPS=()
}

snapshot_warp_egress_state() {
    [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] \
        || { log_error "A WARP transaction snapshot is already active."; return 1; }
    local iface="${AWG_WARP_IFACE:-wgcf}" path backup
    _validate_iface_name "$iface" && [[ "$iface" != awg0 ]] \
        || { log_error "Invalid WARP iface for snapshot: '$iface'"; return 1; }
    local conf="/etc/wireguard/${iface}.conf"
    local was_enabled=0 was_active=0
    systemctl is-enabled --quiet "wg-quick@${iface}" 2>/dev/null && was_enabled=1
    systemctl is-active --quiet "wg-quick@${iface}" 2>/dev/null && was_active=1
    if [[ "$was_active" -eq 1 ]]; then
        if [[ ! -f "$conf" || -L "$conf" || -L "$(dirname "$conf")" ]]; then
            log_error "Active wg-quick@${iface} has no restorable regular config at $conf."
            return 1
        fi
        if ! _validate_quick_config_semantics "$conf" warp; then
            log_error "Active wg-quick@${iface} has an invalid, non-restorable config at $conf."
            return 1
        fi
    fi
    if [[ "$was_active" -eq 0 ]] \
        && ip link show "$iface" >/dev/null 2>&1; then
        log_error "WARP iface $iface is up outside systemd; safe snapshot/rollback is impossible."
        return 1
    fi
    _AWG_WARP_TX_PATHS=(
        /usr/local/bin/wgcf "$conf" /etc/wireguard/wgcf-account.toml
        /etc/wireguard/wgcf-profile.conf
        "${AWG_DIR}/.wgcf_enabled_by_installer"
        "${AWG_DIR}/.wgcf_binary_installed_by_installer"
        "${AWG_DIR}/.wgcf_config_created_by_installer"
        "${AWG_DIR}/.wgcf_config_managed_by_installer"
        "${AWG_DIR}/.wgcf_account_created_by_installer"
    )
    _AWG_WARP_TX_HAD=(); _AWG_WARP_TX_BACKUPS=()
    for path in "${_AWG_WARP_TX_PATHS[@]}"; do
        if [[ -e "$path" || -L "$path" ]]; then
            if [[ ! -f "$path" || -L "$path" || -L "$(dirname "$path")" ]]; then
                log_error "Unsafe WARP resource for snapshot: $path"
                commit_warp_egress_state
                return 1
            fi
            backup=$(awg_mktemp "$AWG_DIR") || { commit_warp_egress_state; return 1; }
            cp -p -- "$path" "$backup" \
                || { log_error "Failed to snapshot $path"; commit_warp_egress_state; return 1; }
            _AWG_WARP_TX_HAD+=(1); _AWG_WARP_TX_BACKUPS+=("$backup")
        else
            _AWG_WARP_TX_HAD+=(0); _AWG_WARP_TX_BACKUPS+=("")
        fi
    done
    _AWG_WARP_TX_IFACE="$iface"
    _AWG_WARP_TX_WAS_ENABLED="$was_enabled"
    _AWG_WARP_TX_WAS_ACTIVE="$was_active"
    _AWG_WARP_TX_DIRTY=0
    _AWG_WARP_TX_ACTIVE=1
}

rollback_warp_egress_state() {
    [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 1 ]] || return 0
    if [[ "${_AWG_WARP_TX_DIRTY:-0}" -eq 0 ]]; then
        commit_warp_egress_state
        return 0
    fi
    local iface="$_AWG_WARP_TX_IFACE" unit="wg-quick@${_AWG_WARP_TX_IFACE}"
    local i path had backup dir tmp failed=0
    # Never replace a config which may still be backing a live interface.
    if systemctl is-active --quiet "$unit" 2>/dev/null \
        || ip link show "$iface" >/dev/null 2>&1; then
        systemctl stop "$unit" >/dev/null 2>&1 || true
        if ip link show "$iface" >/dev/null 2>&1 \
            && command -v wg-quick >/dev/null 2>&1 \
            && [[ -f "/etc/wireguard/${iface}.conf" && ! -L "/etc/wireguard/${iface}.conf" ]]; then
            wg-quick down "/etc/wireguard/${iface}.conf" >/dev/null 2>&1 || true
        fi
        if systemctl is-active --quiet "$unit" 2>/dev/null \
            || ip link show "$iface" >/dev/null 2>&1; then
            log_error "$unit/interface is still active; WARP config was not overwritten."
            return 1
        fi
    fi
    for i in "${!_AWG_WARP_TX_PATHS[@]}"; do
        path="${_AWG_WARP_TX_PATHS[$i]}"; had="${_AWG_WARP_TX_HAD[$i]}"; backup="${_AWG_WARP_TX_BACKUPS[$i]}"
        dir=$(dirname "$path")
        if [[ -L "$path" || -L "$dir" || ( -e "$path" && ! -f "$path" ) ]]; then
            log_error "Unsafe WARP resource during rollback: $path"; failed=1; continue
        fi
        if [[ "$had" -eq 1 ]]; then
            if [[ ! -f "$backup" || -L "$backup" ]]; then failed=1; continue; fi
            tmp=$(awg_mktemp "$dir") || { failed=1; continue; }
            cp -p -- "$backup" "$tmp" && mv -f -- "$tmp" "$path" || failed=1
            continue
        fi
        [[ -e "$path" ]] || continue
        # Absence in the transaction snapshot is itself the ownership proof.
        # This also closes the signal window between atomic resource creation
        # and writing its granular marker.
        rm -f -- "$path" || failed=1
    done
    if [[ "$failed" -ne 0 ]]; then
        log_error "WARP resources were not fully restored; the unit remains stopped."
        return 1
    fi
    _restore_warp_setup_state "$unit" "$_AWG_WARP_TX_WAS_ENABLED" "$_AWG_WARP_TX_WAS_ACTIVE" \
        0 "" "/etc/wireguard/${iface}.conf" \
        || { log_error "Failed to restore $unit state."; return 1; }
    commit_warp_egress_state
}

# Register the Cloudflare WARP account and generate wgcf.conf with Table=off.
# Idempotent: if both files already exist, only verifies/restores Table=off.
setup_warp_egress() {
    local warp_iface="${AWG_WARP_IFACE:-wgcf}"
    local warp_conf="/etc/wireguard/${warp_iface}.conf"
    local warp_account="/etc/wireguard/wgcf-account.toml"
    local marker="${AWG_DIR}/.wgcf_enabled_by_installer"
    local binary_marker="${AWG_DIR}/.wgcf_binary_installed_by_installer"
    local config_marker="${AWG_DIR}/.wgcf_config_created_by_installer"
    local managed_config_marker="${AWG_DIR}/.wgcf_config_managed_by_installer"
    local account_marker="${AWG_DIR}/.wgcf_account_created_by_installer"

    if [[ "${AWG_EGRESS:-direct}" != "warp" ]]; then
        log_debug "setup_warp_egress: AWG_EGRESS != warp, skipping"
        return 0
    fi

    if ! _validate_iface_name "$warp_iface" || [[ "$warp_iface" == "awg0" ]]; then
        log_error "setup_warp_egress: invalid AWG_WARP_IFACE='$warp_iface'"
        return 1
    fi

    # Validate a live baseline before migration/download/marker/config mutations.
    # Rollback can safely restart it only when the complete quick config is
    # structurally and semantically restorable.
    local warp_unit="wg-quick@${warp_iface}"
    local service_was_enabled=0 service_was_active=0
    systemctl is-enabled --quiet "$warp_unit" >/dev/null 2>&1 && service_was_enabled=1
    systemctl is-active --quiet "$warp_unit" >/dev/null 2>&1 && service_was_active=1
    if [[ "$service_was_active" -eq 1 ]]; then
        if [[ ! -f "$warp_conf" || -L "$warp_conf" || -L "$(dirname "$warp_conf")" ]]; then
            log_error "Active $warp_unit has no restorable regular config at $warp_conf."
            return 1
        fi
        if ! _validate_quick_config_semantics "$warp_conf" warp; then
            log_error "Active $warp_unit has an invalid, non-restorable config at $warp_conf."
            return 1
        fi
    fi
    if [[ "$service_was_active" -eq 0 ]] && ip link show "$warp_iface" >/dev/null 2>&1; then
        log_error "$warp_iface is up outside active $warp_unit; automatic modification is unsafe."
        return 1
    fi
    if [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 1 && "$_AWG_WARP_TX_IFACE" != "$warp_iface" ]]; then
        log_error "WARP transaction snapshot belongs to iface '$_AWG_WARP_TX_IFACE', not '$warp_iface'."
        return 1
    fi

    migrate_legacy_warp_ownership "$warp_iface" preflight || return 1
    local legacy_migration_needed="$_AWG_WARP_LEGACY_MIGRATION_NEEDED"

    if [[ ( -e "$config_marker" || -L "$config_marker" ) \
          && ( -e "$managed_config_marker" || -L "$managed_config_marker" ) ]]; then
        log_error "Both created/managed WARP config markers exist; repair ownership manually."
        return 1
    fi

    # A granular marker must be a regular one-line file, name exactly the
    # expected resource, and that resource must exist. Otherwise this is stale/
    # corrupt state where overwriting the marker could claim somebody else's
    # file or make a correct uninstall impossible.
    local ownership_marker ownership_path ownership_value
    for ownership_marker in "$binary_marker" "$config_marker" "$managed_config_marker" "$account_marker"; do
        case "$ownership_marker" in
            "$binary_marker")  ownership_path="/usr/local/bin/wgcf" ;;
            "$config_marker")  ownership_path="$warp_conf" ;;
            "$managed_config_marker") ownership_path="$warp_conf" ;;
            "$account_marker") ownership_path="$warp_account" ;;
        esac
        if [[ -e "$ownership_marker" || -L "$ownership_marker" ]]; then
            if [[ ! -f "$ownership_marker" || -L "$ownership_marker" ]]; then
                log_error "Invalid ownership marker $ownership_marker"
                return 1
            fi
            ownership_value=$(<"$ownership_marker")
            if [[ "$ownership_value" != "$ownership_path" \
                  || "$ownership_value" == *$'\n'* \
                  || ! -f "$ownership_path" || -L "$ownership_path" ]]; then
                log_error "Stale or corrupt ownership marker $ownership_marker; repair it manually."
                return 1
            fi
        fi
    done

    # Do not mutate somebody else's WARP config: the code below removes DNS/
    # IPv6 and inserts Table=off. Without an ownership marker that is not
    # reliably reversible.
    if [[ -e "$warp_conf" || -L "$warp_conf" ]]; then
        local owned_warp_conf=""
        [[ "$legacy_migration_needed" -eq 1 ]] && owned_warp_conf="$warp_conf"
        [[ -r "$config_marker" ]] && IFS= read -r owned_warp_conf < "$config_marker"
        [[ -z "$owned_warp_conf" && -r "$managed_config_marker" ]] \
            && IFS= read -r owned_warp_conf < "$managed_config_marker"
        if [[ "$owned_warp_conf" != "$warp_conf" ]]; then
            log_error "Refusing to modify existing $warp_conf: it was not created by this installer."
            log_error "Set an unused AWG_WARP_IFACE in the configuration or migrate the config manually."
            return 1
        fi
    fi

    # Fail before binary/account mutations on wgcf generate's fixed temp path.
    if [[ ! -f "$warp_conf" ]]; then
        if [[ "$warp_conf" == "/etc/wireguard/wgcf-profile.conf" ]]; then
            log_error "AWG_WARP_IFACE='wgcf-profile' conflicts with wgcf generate's temporary name."
            return 1
        fi
        if [[ -e /etc/wireguard/wgcf-profile.conf || -L /etc/wireguard/wgcf-profile.conf ]]; then
            log_error "Refusing to use existing /etc/wireguard/wgcf-profile.conf; move it manually."
            return 1
        fi
    fi

    # One service marker describes exactly one iface. Changing the name
    # without teardown would leave the previous unit enabled, so fail safely.
    if [[ -e "$marker" || -L "$marker" ]]; then
        local owned_warp_iface=""
        if [[ "$legacy_migration_needed" -eq 1 ]]; then
            : # Empty regular legacy marker was fully validated by preflight.
        elif [[ ! -f "$marker" || -L "$marker" ]] \
            || ! owned_warp_iface=$(<"$marker") \
            || [[ "$owned_warp_iface" == *$'\n'* ]] \
            || ! _validate_iface_name "$owned_warp_iface"; then
            log_error "Invalid or legacy ownership marker $marker; automatic management is unsafe."
            return 1
        fi
        if [[ "$legacy_migration_needed" -eq 0 && "$owned_warp_iface" != "$warp_iface" ]]; then
            log_error "WARP is already installer-managed through iface '$owned_warp_iface'; remove the old configuration first."
            return 1
        fi
    fi

    # The binary ownership/hash checks are read-only in preflight mode.
    _download_wgcf_binary preflight || return 1

    if [[ "$legacy_migration_needed" -eq 1 ]]; then
        migrate_legacy_warp_ownership "$warp_iface" \
            && [[ "$_AWG_WARP_LEGACY_MIGRATION_NEEDED" -eq 1 ]] || return 1
    fi

    local warp_conf_existed=0 warp_conf_backup=""
    if [[ -f "$warp_conf" ]]; then
        warp_conf_existed=1
        warp_conf_backup=$(awg_mktemp "$AWG_DIR") \
            || { log_error "mktemp for $warp_conf snapshot"; return 1; }
        cp -p -- "$warp_conf" "$warp_conf_backup" \
            || { log_error "Failed to preserve the original $warp_conf"; return 1; }
    fi

    local wgcf_was_present=0
    [[ -f /usr/local/bin/wgcf && ! -L /usr/local/bin/wgcf ]] && wgcf_was_present=1
    _download_wgcf_binary || return 1
    if [[ "$wgcf_was_present" -eq 0 ]]; then
        if ! printf '%s\n' /usr/local/bin/wgcf > "$binary_marker" \
            || ! chmod 600 "$binary_marker"; then
            rm -f /usr/local/bin/wgcf "$binary_marker"
            log_error "Failed to write ownership marker $binary_marker"
            return 1
        fi
    fi

    if [[ ! -d /etc/wireguard ]]; then
        [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] || _AWG_WARP_TX_DIRTY=1
        mkdir -p /etc/wireguard || { log_error "mkdir /etc/wireguard"; return 1; }
    fi
    [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] || _AWG_WARP_TX_DIRTY=1
    chmod 700 /etc/wireguard

    # Account registration (only if account.toml is missing).
    #
    # Source of truth is the presence of a non-empty $warp_account, NOT
    # wgcf's exit code: wgcf 2.2.30 `register --accept-tos` is observed to
    # successfully write the file and then return non-zero (version quirk).
    # If we relied on the exit code, the code would fall through to the
    # `wgcf register` fallback (no flag), which sees the just-written file
    # and errors out with "existing account detected, refusing to
    # overwrite" — and the install fails even though the registration
    # actually succeeded.
    #
    # Logic: try --accept-tos (modern wgcf); if the file still isn't there,
    # try without the flag (ancient wgcf that expects `y` on stdin).
    # stderr from both attempts accumulates in one file so we don't lose
    # the diagnostic if both really did fail (API block, rate-limit, TLS).
    if [[ ! -f "$warp_account" ]]; then
        log "Registering WARP account via wgcf..."
        local _wgcf_err
        _wgcf_err=$(awg_mktemp "$AWG_DIR") \
            || { log_error "mktemp for wgcf register stderr"; return 1; }

        ( cd /etc/wireguard && yes 2>/dev/null | /usr/local/bin/wgcf register --accept-tos >/dev/null 2>>"$_wgcf_err" ) || true

        if [[ ! -s "$warp_account" ]]; then
            # --accept-tos didn't work (old wgcf, or a real network failure).
            # Try the legacy variant without the flag.
            ( cd /etc/wireguard && yes 2>/dev/null | /usr/local/bin/wgcf register >/dev/null 2>>"$_wgcf_err" ) || true
        fi

        if [[ ! -s "$warp_account" ]]; then
            log_error "wgcf register failed. Check reachability of api.cloudflareclient.com"
            if [[ -s "$_wgcf_err" ]]; then
                log_error "wgcf stderr:"
                while IFS= read -r _ln; do log_error "  $_ln"; done < "$_wgcf_err"
            fi
            # Clean up an empty account.toml wgcf may have created and then
            # bailed on — otherwise the next run would see it and skip
            # register.
            rm -f "$warp_account"
            return 1
        fi
        if ! chmod 600 "$warp_account"; then
            rm -f "$warp_account"
            log_error "Failed to secure permissions on $warp_account"
            return 1
        fi
        if ! printf '%s\n' "$warp_account" > "$account_marker" \
            || ! chmod 600 "$account_marker"; then
            rm -f "$warp_account" "$account_marker"
            log_error "Failed to write ownership marker $account_marker"
            return 1
        fi
        log "WARP account registered."
    else
        log_debug "WARP account already registered ($warp_account)"
    fi

    # Profile generation (only if missing). wgcf always writes the fixed
    # temporary name wgcf-profile.conf; never remove somebody else's file.
    if [[ ! -f "$warp_conf" ]]; then
        if [[ "$warp_conf" == "/etc/wireguard/wgcf-profile.conf" ]]; then
            log_error "AWG_WARP_IFACE='wgcf-profile' conflicts with the temporary name used by wgcf generate."
            return 1
        fi
        if [[ -e /etc/wireguard/wgcf-profile.conf || -L /etc/wireguard/wgcf-profile.conf ]]; then
            log_error "Refusing to remove existing /etc/wireguard/wgcf-profile.conf; move it manually."
            return 1
        fi
        log "Generating WARP config..."
        ( cd /etc/wireguard && /usr/local/bin/wgcf generate >/dev/null 2>&1 ) || {
            rm -f /etc/wireguard/wgcf-profile.conf
            log_error "wgcf generate failed"
            return 1
        }
        [[ -f /etc/wireguard/wgcf-profile.conf ]] || {
            log_error "wgcf generate did not create wgcf-profile.conf"
            return 1
        }
        mv /etc/wireguard/wgcf-profile.conf "$warp_conf" \
            || { rm -f /etc/wireguard/wgcf-profile.conf; log_error "Failed to write $warp_conf"; return 1; }
        chmod 600 "$warp_conf" \
            || { rm -f "$warp_conf"; log_error "chmod $warp_conf"; return 1; }
        if ! printf '%s\n' "$warp_conf" > "$config_marker" \
            || ! chmod 600 "$config_marker"; then
            rm -f "$warp_conf" "$config_marker"
            log_error "Failed to write ownership marker $config_marker"
            return 1
        fi
    else
        log_debug "WARP config already exists ($warp_conf)"
    fi

    # In one atomic pass enforce Table=off, remove DNS, and strip IPv6 Address.
    # Two sequential in-place edits could leave a half-config on failure; a
    # later duplicate `Table = auto` could also override an inserted `off`.
    # Every Table line is replaced by exactly one canonical value here.
    local warp_tmp
    warp_tmp=$(awg_mktemp /etc/wireguard) || { log_error "mktemp"; return 1; }
    if ! awk '
        BEGIN { inif=0; sawif=0; sawtable=0; hasv4=0; invalid=0 }
        /^[[:space:]]*\[/ {
            if (inif && !sawtable) print "Table = off"
            low=tolower($0)
            inif=(low ~ /^[[:space:]]*\[interface\][[:space:]]*$/)
            if (inif) { sawif=1; sawtable=0 }
            print
            next
        }
        inif && tolower($0) ~ /^[[:space:]]*dns[[:space:]]*=/ { next }
        inif && tolower($0) ~ /^[[:space:]]*table[[:space:]]*=/ {
            if (!sawtable) print "Table = off"
            sawtable=1
            next
        }
        inif && tolower($0) ~ /^[[:space:]]*address[[:space:]]*=/ {
            line=$0
            sub(/^[^=]*=[[:space:]]*/, "", line)
            n=split(line, parts, /[[:space:]]*,[[:space:]]*/)
            out=""
            for (i=1; i<=n; i++) {
                p=parts[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
                if (p == "") continue
                if (p ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/) {
                    out=(out ? out ", " : "") p
                    hasv4=1
                } else if (p !~ /:/) {
                    invalid=1
                }
            }
            if (out != "") print "Address = " out
            next
        }
        { print }
        END {
            if (inif && !sawtable) print "Table = off"
            if (!sawif || !hasv4 || invalid) exit 20
        }
    ' "$warp_conf" > "$warp_tmp"; then
        rm -f "$warp_tmp"
        log_error "Invalid $warp_conf: [Interface] with an IPv4 Address is required"
        return 1
    fi
    chmod 600 "$warp_tmp" \
        || { rm -f "$warp_tmp"; log_error "chmod $warp_tmp"; return 1; }
    mv -f "$warp_tmp" "$warp_conf" \
        || { rm -f "$warp_tmp"; log_error "could not atomically update $warp_conf"; return 1; }
    local marker_created_this_attempt=0
    log "WARP config normalized: Table=off, DNS/IPv6 disabled ($warp_conf)."

    # Upstream WireGuard module needed by wg-quick@wgcf. The amneziawg module
    # is separate and does NOT pull `wireguard` with it, without which
    # `ip link add dev wgcf type wireguard` fails. On Ubuntu 24.04 / Debian 13
    # the module is either built-in or available from linux-modules —
    # modprobe usually works without extra packages. Don't fail if modprobe
    # errors out: wg-quick will try it again itself.
    if ! lsmod 2>/dev/null | grep -q -w wireguard; then
        log "Loading wireguard module (required by wg-quick@wgcf)..."
        modprobe wireguard 2>/dev/null || log_warn "modprobe wireguard failed — wg-quick will retry."
    fi

    local service_action
    if [[ "$service_was_active" -eq 1 ]]; then
        # restart applies the atomically normalized config without changing
        # the enabled/disabled state of a pre-existing unit.
        service_action="restart"
    elif [[ "$service_was_enabled" -eq 1 ]]; then
        service_action="start"
    else
        service_action="enable-now"
    fi
    log "Starting wg-quick@${warp_iface} (action: ${service_action})..."
    local _sc_err
    _sc_err=$(awg_mktemp "$AWG_DIR") \
        || {
            _restore_warp_setup_state "$warp_unit" "$service_was_enabled" "$service_was_active" \
                "$warp_conf_existed" "$warp_conf_backup" "$warp_conf" \
                || log_error "WARP config/service rollback was incomplete."
            log_error "mktemp for WARP systemctl stderr"
            return 1
        }
    local service_rc=0
    case "$service_action" in
        restart)    systemctl restart "$warp_unit" 2>"$_sc_err" || service_rc=$? ;;
        start)      systemctl start "$warp_unit" 2>"$_sc_err" || service_rc=$? ;;
        enable-now) systemctl enable --now "$warp_unit" 2>"$_sc_err" || service_rc=$? ;;
    esac
    if [[ "$service_rc" -ne 0 ]]; then
        log_error "systemctl ${service_action} wg-quick@${warp_iface} failed"
        [[ -s "$_sc_err" ]] && while IFS= read -r _ln; do log_error "  $_ln"; done < "$_sc_err"
        # Dump the unit status for diagnostics (ExecStart exit code, logs)
        systemctl status "wg-quick@${warp_iface}" --no-pager -l 2>&1 | head -30 \
            | while IFS= read -r _ln; do log_error "status: $_ln"; done
        _restore_warp_setup_state "$warp_unit" "$service_was_enabled" "$service_was_active" \
            "$warp_conf_existed" "$warp_conf_backup" "$warp_conf" \
            || log_error "WARP config/service rollback was incomplete."
        return "$service_rc"
    fi

    # Mark service ownership only if the unit was neither enabled nor active
    # before us. Uninstall must stop/disable it only when this marker exists.
    if [[ ! -e "$marker" && ! -L "$marker" \
          && "$service_was_enabled" -eq 0 && "$service_was_active" -eq 0 ]]; then
        if ! printf '%s\n' "$warp_iface" > "$marker" 2>/dev/null \
            || ! chmod 600 "$marker" 2>/dev/null; then
            rm -f "$marker" 2>/dev/null
            _restore_warp_setup_state "$warp_unit" "$service_was_enabled" "$service_was_active" \
                "$warp_conf_existed" "$warp_conf_backup" "$warp_conf" \
                || log_error "WARP config/service rollback was incomplete."
            log_error "Failed to write service ownership marker $marker"
            return 1
        fi
        marker_created_this_attempt=1
    elif [[ ! -e "$marker" && ! -L "$marker" ]]; then
        log_warn "$warp_unit pre-dated this install; the installer will not claim service ownership."
    fi

    # Wait for the interface (up to 5 s)
    local _i
    for _i in 1 2 3 4 5; do
        if ip link show "$warp_iface" >/dev/null 2>&1; then
            log "$warp_iface interface is up."
            return 0
        fi
        sleep 1
    done
    log_error "$warp_iface interface never came up within 5 s."
    log_error "systemctl status wg-quick@${warp_iface}:"
    systemctl status "wg-quick@${warp_iface}" --no-pager -l 2>&1 | head -30 \
        | while IFS= read -r _ln; do log_error "  $_ln"; done
    log_error "journalctl -u wg-quick@${warp_iface} -n 20:"
    journalctl -u "wg-quick@${warp_iface}" -n 20 --no-pager 2>&1 \
        | while IFS= read -r _ln; do log_error "  $_ln"; done
    [[ "$marker_created_this_attempt" -eq 0 ]] || rm -f -- "$marker"
    _restore_warp_setup_state "$warp_unit" "$service_was_enabled" "$service_was_active" \
        "$warp_conf_existed" "$warp_conf_backup" "$warp_conf" \
        || log_error "WARP config/service rollback was incomplete."
    return 1
}

# Install WARP bypass (specific destinations go around WARP, e.g. YouTube /
# Google / banking CDNs that rate-limit Cloudflare IPs). Writes
# /usr/local/sbin/awg-warp-bypass.sh, the systemd unit + timer, and the
# config /etc/amnezia/amneziawg/warp-bypass.conf from AWG_WARP_BYPASS
# (comma-separated: youtube | custom:URL | custom:/path).
# The timer/service own refresh independently; awg0 PostUp does not start them
# so it cannot race the installer's transactional bundle/ledger replacement.
_AWG_BYPASS_TX_ACTIVE=0
_AWG_BYPASS_TX_TIMER_WAS_ENABLED=0
_AWG_BYPASS_TX_TIMER_WAS_ACTIVE=0
_AWG_BYPASS_TX_SERVICE_WAS_ENABLED=0
_AWG_BYPASS_TX_SERVICE_WAS_ACTIVE=0
_AWG_BYPASS_TX_EXPECT_CURRENT_ABSENT=0
_AWG_BYPASS_TX_SNAPSHOT_READY=0
_AWG_BYPASS_TX_TIMER_QUIESCE_STARTED=0
_AWG_BYPASS_TX_SERVICE_QUIESCE_STARTED=0
_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD=""
declare -a _AWG_BYPASS_TX_PATHS=() _AWG_BYPASS_TX_HAD=() _AWG_BYPASS_TX_BACKUPS=()
_AWG_BYPASS_TX_ROUTE_TABLE=""
declare -a _AWG_BYPASS_TX_ROUTES=()
declare -A _AWG_BYPASS_TX_ROUTE_PRESENT=() _AWG_BYPASS_TX_ROUTE_DEV=() _AWG_BYPASS_TX_ROUTE_GW=()
_AWG_BYPASS_PARSED_TABLE=""
declare -a _AWG_BYPASS_PARSED_ROUTES=()

# Kernel route nexthops may legitimately be VLAN/bridge-style names such as
# eth0.100.  This grammar intentionally differs from managed AWG iface names.
_valid_warp_bypass_route_iface() {
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]
}

_release_warp_bypass_snapshot_lock() {
    if [[ -n "${_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD:-}" ]]; then
        exec {_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD}>&- || return 1
        _AWG_BYPASS_TX_SNAPSHOT_LOCK_FD=""
    fi
}

_commit_warp_bypass_setup_state() {
    local backup
    _release_warp_bypass_snapshot_lock || return 1
    for backup in "${_AWG_BYPASS_TX_BACKUPS[@]}"; do
        [[ -z "$backup" || ! -f "$backup" || -L "$backup" ]] || rm -f -- "$backup"
    done
    _AWG_BYPASS_TX_ACTIVE=0
    _AWG_BYPASS_TX_TIMER_WAS_ENABLED=0; _AWG_BYPASS_TX_TIMER_WAS_ACTIVE=0
    _AWG_BYPASS_TX_SERVICE_WAS_ENABLED=0; _AWG_BYPASS_TX_SERVICE_WAS_ACTIVE=0
    _AWG_BYPASS_TX_EXPECT_CURRENT_ABSENT=0
    _AWG_BYPASS_TX_SNAPSHOT_READY=0
    _AWG_BYPASS_TX_TIMER_QUIESCE_STARTED=0
    _AWG_BYPASS_TX_SERVICE_QUIESCE_STARTED=0
    _AWG_BYPASS_TX_PATHS=(); _AWG_BYPASS_TX_HAD=(); _AWG_BYPASS_TX_BACKUPS=()
    _AWG_BYPASS_TX_ROUTE_TABLE=""; _AWG_BYPASS_TX_ROUTES=()
    _AWG_BYPASS_TX_ROUTE_PRESENT=(); _AWG_BYPASS_TX_ROUTE_DEV=(); _AWG_BYPASS_TX_ROUTE_GW=()
}

_parse_warp_bypass_ledger() {
    local ledger="$1" line="" line_no=0
    local -A route_seen=()
    _AWG_BYPASS_PARSED_TABLE=""; _AWG_BYPASS_PARSED_ROUTES=()
    [[ -f "$ledger" && ! -L "$ledger" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$(( line_no + 1 ))
        if (( line_no == 1 )); then
            [[ "$line" =~ ^table=([1-9][0-9]{0,9})$ ]] || return 1
            _AWG_BYPASS_PARSED_TABLE="${BASH_REMATCH[1]}"
            (( 10#$_AWG_BYPASS_PARSED_TABLE <= 4294967295 )) \
                && (( 10#$_AWG_BYPASS_PARSED_TABLE < 253 || 10#$_AWG_BYPASS_PARSED_TABLE > 255 )) \
                || return 1
            continue
        fi
        (( ${#_AWG_BYPASS_PARSED_ROUTES[@]} < 2048 )) || return 1
        _valid_warp_bypass_ledger_route "$line" || return 1
        [[ -z "${route_seen[$line]+present}" ]] || return 1
        route_seen["$line"]=1
        _AWG_BYPASS_PARSED_ROUTES+=("$line")
    done < "$ledger"
    (( line_no >= 2 && ${#_AWG_BYPASS_PARSED_ROUTES[@]} >= 1 ))
}

_restore_warp_bypass_units_after_snapshot_failure() {
    local failed=0
    _release_warp_bypass_snapshot_lock || failed=1
    if [[ "$_AWG_BYPASS_TX_SERVICE_QUIESCE_STARTED" -eq 1 \
          && "$_AWG_BYPASS_TX_SERVICE_WAS_ACTIVE" -eq 1 ]] \
        && ! systemctl is-active --quiet awg-warp-bypass.service 2>/dev/null; then
        systemctl start awg-warp-bypass.service >/dev/null 2>&1 || failed=1
    fi
    if [[ "$_AWG_BYPASS_TX_TIMER_QUIESCE_STARTED" -eq 1 \
          && "$_AWG_BYPASS_TX_TIMER_WAS_ACTIVE" -eq 1 ]] \
        && ! systemctl is-active --quiet awg-warp-bypass.timer 2>/dev/null; then
        systemctl start awg-warp-bypass.timer >/dev/null 2>&1 || failed=1
    fi
    if [[ "$failed" -ne 0 ]]; then
        log_error "Failed to restore WARP bypass units after snapshot failure; transaction left pending."
        return 1
    fi
    _commit_warp_bypass_setup_state
    return "$failed"
}

_snapshot_warp_bypass_setup_state() {
    [[ "${_AWG_BYPASS_TX_ACTIVE:-0}" -eq 0 ]] \
        || { log_error "A WARP bypass transaction is already active."; return 1; }
    local conf_dir="/etc/amnezia/amneziawg" routes_file marker marker_value=""
    local path dir backup route route_line route_dst route_dev route_gw
    routes_file="$conf_dir/warp-bypass.routes"
    marker="${AWG_DIR}/.warp_bypass_enabled_by_installer"
    _AWG_BYPASS_TX_PATHS=(
        "$conf_dir/warp-bypass.conf"
        /etc/default/awg-warp-bypass
        /usr/local/sbin/awg-warp-bypass.sh
        /etc/systemd/system/awg-warp-bypass.service
        /etc/systemd/system/awg-warp-bypass.timer
        "$routes_file"
        "$marker"
    )
    [[ -d "$AWG_DIR" && ! -L "$AWG_DIR" ]] \
        || { log_error "Unsafe AWG_DIR for WARP bypass snapshot: $AWG_DIR"; return 1; }
    if [[ -e "$marker" || -L "$marker" ]]; then
        [[ -f "$marker" && ! -L "$marker" ]] || return 1
        marker_value=$(<"$marker")
        [[ -z "$marker_value" || "$marker_value" == v2 ]] || return 1
    else
        for path in "${_AWG_BYPASS_TX_PATHS[@]}"; do
            [[ "$path" == "$marker" || ( ! -e "$path" && ! -L "$path" ) ]] \
                || { log_error "Foreign WARP bypass resource without ownership marker: $path"; return 1; }
        done
    fi
    for path in "${_AWG_BYPASS_TX_PATHS[@]}"; do
        dir=$(dirname "$path")
        if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) \
              || -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
            log_error "Unsafe WARP bypass resource for snapshot: $path"
            return 1
        fi
    done
    if [[ ! -f /etc/systemd/system/awg-warp-bypass.service ]] \
        && systemctl cat --no-pager awg-warp-bypass.service >/dev/null 2>&1; then
        log_error "A foreign/loaded awg-warp-bypass.service exists without the owned unit file."
        return 1
    fi
    if [[ ! -f /etc/systemd/system/awg-warp-bypass.timer ]] \
        && systemctl cat --no-pager awg-warp-bypass.timer >/dev/null 2>&1; then
        log_error "A foreign/loaded awg-warp-bypass.timer exists without the owned unit file."
        return 1
    fi

    # Stop future timer activations, wait for an in-flight refresh through its
    # own flock, and leave both units quiescent for the whole transaction.
    _AWG_BYPASS_TX_TIMER_WAS_ENABLED=0; _AWG_BYPASS_TX_TIMER_WAS_ACTIVE=0
    _AWG_BYPASS_TX_SERVICE_WAS_ENABLED=0; _AWG_BYPASS_TX_SERVICE_WAS_ACTIVE=0
    _AWG_BYPASS_TX_EXPECT_CURRENT_ABSENT=0
    systemctl is-enabled --quiet awg-warp-bypass.timer 2>/dev/null && _AWG_BYPASS_TX_TIMER_WAS_ENABLED=1
    systemctl is-active --quiet awg-warp-bypass.timer 2>/dev/null && _AWG_BYPASS_TX_TIMER_WAS_ACTIVE=1
    systemctl is-enabled --quiet awg-warp-bypass.service 2>/dev/null && _AWG_BYPASS_TX_SERVICE_WAS_ENABLED=1
    systemctl is-active --quiet awg-warp-bypass.service 2>/dev/null && _AWG_BYPASS_TX_SERVICE_WAS_ACTIVE=1
    _AWG_BYPASS_TX_SNAPSHOT_READY=0
    _AWG_BYPASS_TX_TIMER_QUIESCE_STARTED=0
    _AWG_BYPASS_TX_SERVICE_QUIESCE_STARTED=0
    # Arm the partial-snapshot rollback before the first command that can
    # quiesce runtime state.  A signal must never observe an inactive tx here.
    _AWG_BYPASS_TX_ACTIVE=1
    if systemctl is-active --quiet awg-warp-bypass.timer 2>/dev/null; then
        _AWG_BYPASS_TX_TIMER_QUIESCE_STARTED=1
        if ! systemctl stop awg-warp-bypass.timer >/dev/null 2>&1; then
            _restore_warp_bypass_units_after_snapshot_failure || true
            return 1
        fi
    fi
    exec {_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD}>/run/awg-warp-bypass.lock || {
        _restore_warp_bypass_units_after_snapshot_failure || true
        return 1
    }
    if ! flock -x -w 60 "$_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD"; then
        _release_warp_bypass_snapshot_lock || true
        log_error "Timed out waiting for the WARP bypass refresh lock."
        _restore_warp_bypass_units_after_snapshot_failure || true
        return 1
    fi
    if systemctl is-active --quiet awg-warp-bypass.timer 2>/dev/null; then
        _AWG_BYPASS_TX_TIMER_QUIESCE_STARTED=1
        systemctl stop awg-warp-bypass.timer >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet awg-warp-bypass.service 2>/dev/null; then
        _AWG_BYPASS_TX_SERVICE_QUIESCE_STARTED=1
        systemctl stop awg-warp-bypass.service >/dev/null 2>&1 || true
    else
        # A normal oneshot may have been active when observed but completed
        # while flock waited.  The stable snapshot baseline is now inactive.
        _AWG_BYPASS_TX_SERVICE_WAS_ACTIVE=0
    fi
    if systemctl is-active --quiet awg-warp-bypass.timer 2>/dev/null \
        || systemctl is-active --quiet awg-warp-bypass.service 2>/dev/null; then
        _release_warp_bypass_snapshot_lock || true
        log_error "Failed to quiesce WARP bypass units before snapshot."
        _restore_warp_bypass_units_after_snapshot_failure || true
        return 1
    fi

    _AWG_BYPASS_TX_HAD=(); _AWG_BYPASS_TX_BACKUPS=()
    for path in "${_AWG_BYPASS_TX_PATHS[@]}"; do
        dir=$(dirname "$path")
        if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) \
              || -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
            _release_warp_bypass_snapshot_lock || true
            log_error "Unsafe WARP bypass resource for snapshot: $path"
            _restore_warp_bypass_units_after_snapshot_failure || true
            return 1
        fi
        if [[ -f "$path" ]]; then
            backup=$(awg_mktemp "$AWG_DIR") || {
                _release_warp_bypass_snapshot_lock || true
                _restore_warp_bypass_units_after_snapshot_failure || true
                return 1
            }
            if ! cp -p -- "$path" "$backup"; then
                _release_warp_bypass_snapshot_lock || true
                log_error "Failed to snapshot $path"
                _restore_warp_bypass_units_after_snapshot_failure || true
                return 1
            fi
            _AWG_BYPASS_TX_HAD+=(1); _AWG_BYPASS_TX_BACKUPS+=("$backup")
        else
            _AWG_BYPASS_TX_HAD+=(0); _AWG_BYPASS_TX_BACKUPS+=("")
        fi
    done
    _AWG_BYPASS_TX_ROUTE_TABLE=""; _AWG_BYPASS_TX_ROUTES=()
    _AWG_BYPASS_TX_ROUTE_PRESENT=(); _AWG_BYPASS_TX_ROUTE_DEV=(); _AWG_BYPASS_TX_ROUTE_GW=()
    if [[ -f "$routes_file" ]]; then
        if ! _parse_warp_bypass_ledger "$routes_file"; then
            _release_warp_bypass_snapshot_lock || true
            log_error "Unsafe WARP bypass route ledger at snapshot."
            _restore_warp_bypass_units_after_snapshot_failure || true
            return 1
        fi
        _AWG_BYPASS_TX_ROUTE_TABLE="$_AWG_BYPASS_PARSED_TABLE"
        _AWG_BYPASS_TX_ROUTES=("${_AWG_BYPASS_PARSED_ROUTES[@]}")
        for route in "${_AWG_BYPASS_TX_ROUTES[@]}"; do
            if ! route_line=$(ip -o -4 route show table "$_AWG_BYPASS_TX_ROUTE_TABLE" exact "$route" 2>/dev/null); then
                _release_warp_bypass_snapshot_lock || true
                _restore_warp_bypass_units_after_snapshot_failure || true
                return 1
            fi
            if [[ -z "$route_line" ]]; then
                _AWG_BYPASS_TX_ROUTE_PRESENT["$route"]=0
                continue
            fi
            if [[ "$route_line" == *$'\n'* ]]; then
                _release_warp_bypass_snapshot_lock || true
                _restore_warp_bypass_units_after_snapshot_failure || true
                return 1
            fi
            route_dst=$(awk '{print $1}' <<< "$route_line")
            if _valid_ipv4 "$route_dst"; then route_dst="${route_dst}/32"; fi
            route_dev=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$route_line")
            route_gw=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<< "$route_line")
            if [[ "$route_dst" != "$route" || -z "$route_dev" ]] \
                || ! _valid_warp_bypass_route_iface "$route_dev" \
                || { [[ -n "$route_gw" ]] && ! _valid_ipv4 "$route_gw"; }; then
                _release_warp_bypass_snapshot_lock || true
                log_error "Unsafe installed WARP bypass route at snapshot: $route"
                _restore_warp_bypass_units_after_snapshot_failure || true
                return 1
            fi
            _AWG_BYPASS_TX_ROUTE_PRESENT["$route"]=1
            _AWG_BYPASS_TX_ROUTE_DEV["$route"]="$route_dev"
            _AWG_BYPASS_TX_ROUTE_GW["$route"]="$route_gw"
        done
    fi
    # Keep the refresh flock across bundle publication. setup/teardown hands
    # it off or releases it only when no mixed generation can be observed.
    _AWG_BYPASS_TX_SNAPSHOT_READY=1
}

_rollback_warp_bypass_setup_state() {
    [[ "${_AWG_BYPASS_TX_ACTIVE:-0}" -eq 1 ]] || return 0
    if [[ "${_AWG_BYPASS_TX_SNAPSHOT_READY:-0}" -ne 1 ]]; then
        _restore_warp_bypass_units_after_snapshot_failure
        return
    fi
    local i path had backup dir tmp failed=0 route route_line route_dst route_dev route_gw bypass_lock_fd=""
    local routes_file="/etc/amnezia/amneziawg/warp-bypass.routes" new_table=""
    local -a new_routes=()
    local -A old_route_set=() new_route_present=() new_route_dev=() new_route_gw=()
    for route in "${_AWG_BYPASS_TX_ROUTES[@]}"; do old_route_set["$route"]=1; done

    # Stop new timer activations, then wait for an in-flight refresh to finish
    # naturally.  Parsing the current ledger before this lock would mix two
    # atomic generations and make rollback restore routes without their ledger.
    systemctl stop awg-warp-bypass.timer >/dev/null 2>&1 || true
    if [[ -n "${_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD:-}" ]]; then
        bypass_lock_fd="$_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD"
        _AWG_BYPASS_TX_SNAPSHOT_LOCK_FD=""
    else
        exec {bypass_lock_fd}>/run/awg-warp-bypass.lock || return 1
        if ! flock -x -w 60 "$bypass_lock_fd"; then
            exec {bypass_lock_fd}>&-
            log_error "Timed out waiting for the WARP bypass refresh lock during rollback."
            return 1
        fi
    fi
    if systemctl is-active --quiet awg-warp-bypass.service 2>/dev/null; then
        systemctl stop awg-warp-bypass.service >/dev/null 2>&1 || true
    fi
    if systemctl is-active --quiet awg-warp-bypass.timer 2>/dev/null \
        || systemctl is-active --quiet awg-warp-bypass.service 2>/dev/null; then
        exec {bypass_lock_fd}>&-
        log_error "Failed to quiesce WARP bypass units; resource rollback cancelled."
        return 1
    fi

    local capture_failed=0
    if [[ -e "$routes_file" || -L "$routes_file" ]]; then
        if ! _parse_warp_bypass_ledger "$routes_file"; then
            capture_failed=1
        else
            new_table="$_AWG_BYPASS_PARSED_TABLE"
            new_routes=("${_AWG_BYPASS_PARSED_ROUTES[@]}")
            for route in "${new_routes[@]}"; do
                if ! route_line=$(ip -o -4 route show table "$new_table" exact "$route" 2>/dev/null); then
                    capture_failed=1; break
                fi
                if [[ -z "$route_line" ]]; then new_route_present["$route"]=0; continue; fi
                if [[ "$route_line" == *$'\n'* ]]; then capture_failed=1; break; fi
                route_dst=$(awk '{print $1}' <<< "$route_line")
                if _valid_ipv4 "$route_dst"; then route_dst="${route_dst}/32"; fi
                route_dev=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$route_line")
                route_gw=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<< "$route_line")
                if [[ "$route_dst" != "$route" || -z "$route_dev" ]] \
                    || ! _valid_warp_bypass_route_iface "$route_dev" \
                    || { [[ -n "$route_gw" ]] && ! _valid_ipv4 "$route_gw"; }; then
                    capture_failed=1; break
                fi
                new_route_present["$route"]=1
                new_route_dev["$route"]="$route_dev"
                new_route_gw["$route"]="$route_gw"
            done
        fi
    elif [[ -n "$_AWG_BYPASS_TX_ROUTE_TABLE" \
            && "${_AWG_BYPASS_TX_EXPECT_CURRENT_ABSENT:-0}" -ne 1 ]]; then
        capture_failed=1
    fi
    if [[ "$capture_failed" -ne 0 ]]; then
        exec {bypass_lock_fd}>&-
        log_error "Unsafe current WARP bypass ledger/routes; rollback left pending."
        return 1
    fi
    # Reconcile kernel routes while both ledgers are still available. Delete
    # only exact new nexthops, then restore every route present at snapshot.
    for route in "${new_routes[@]}"; do
        [[ "${new_route_present[$route]:-0}" -eq 1 ]] || continue
        if [[ "$new_table" == "$_AWG_BYPASS_TX_ROUTE_TABLE" \
              && -n "${old_route_set[$route]+x}" \
              && "${_AWG_BYPASS_TX_ROUTE_PRESENT[$route]:-0}" -eq 1 ]]; then
            continue
        fi
        if [[ -n "${new_route_gw[$route]}" ]]; then
            ip -4 route del "$route" via "${new_route_gw[$route]}" \
                dev "${new_route_dev[$route]}" table "$new_table" 2>/dev/null || failed=1
        else
            ip -4 route del "$route" dev "${new_route_dev[$route]}" \
                table "$new_table" 2>/dev/null || failed=1
        fi
    done
    for route in "${_AWG_BYPASS_TX_ROUTES[@]}"; do
        [[ "${_AWG_BYPASS_TX_ROUTE_PRESENT[$route]:-0}" -eq 1 ]] || continue
        if [[ -n "${_AWG_BYPASS_TX_ROUTE_GW[$route]}" ]]; then
            ip -4 route replace "$route" via "${_AWG_BYPASS_TX_ROUTE_GW[$route]}" \
                dev "${_AWG_BYPASS_TX_ROUTE_DEV[$route]}" \
                table "$_AWG_BYPASS_TX_ROUTE_TABLE" 2>/dev/null || failed=1
        else
            ip -4 route replace "$route" dev "${_AWG_BYPASS_TX_ROUTE_DEV[$route]}" \
                table "$_AWG_BYPASS_TX_ROUTE_TABLE" 2>/dev/null || failed=1
        fi
    done
    if [[ "$failed" -ne 0 ]]; then
        exec {bypass_lock_fd}>&-
        log_error "WARP bypass routes restored incompletely; bundle rollback left pending."
        return 1
    fi
    for i in "${!_AWG_BYPASS_TX_PATHS[@]}"; do
        path="${_AWG_BYPASS_TX_PATHS[$i]}"; had="${_AWG_BYPASS_TX_HAD[$i]}"; backup="${_AWG_BYPASS_TX_BACKUPS[$i]}"
        dir=$(dirname "$path")
        if [[ -L "$dir" || ( -e "$dir" && ! -d "$dir" ) \
              || -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
            log_error "Unsafe WARP bypass resource during rollback: $path"
            failed=1; continue
        fi
        if [[ "$had" -eq 1 ]]; then
            if [[ ! -f "$backup" || -L "$backup" ]]; then failed=1; continue; fi
            mkdir -p "$dir" || { failed=1; continue; }
            tmp=$(awg_mktemp "$dir") || { failed=1; continue; }
            cp -p -- "$backup" "$tmp" && mv -f -- "$tmp" "$path" || failed=1
        else
            rm -f -- "$path" || failed=1
        fi
    done
    if [[ "$failed" -ne 0 ]]; then
        exec {bypass_lock_fd}>&-
        log_error "WARP bypass bundle was not restored completely; units remain stopped."
        return 1
    fi
    if ! systemctl daemon-reload >/dev/null 2>&1; then
        exec {bypass_lock_fd}>&-
        return 1
    fi
    exec {bypass_lock_fd}>&-
    if [[ "$_AWG_BYPASS_TX_SERVICE_WAS_ENABLED" -eq 1 ]]; then
        systemctl enable awg-warp-bypass.service >/dev/null 2>&1 || failed=1
    elif systemctl is-enabled --quiet awg-warp-bypass.service 2>/dev/null; then
        systemctl disable awg-warp-bypass.service >/dev/null 2>&1 || failed=1
    fi
    if [[ "$_AWG_BYPASS_TX_TIMER_WAS_ENABLED" -eq 1 ]]; then
        systemctl enable awg-warp-bypass.timer >/dev/null 2>&1 || failed=1
    elif systemctl is-enabled --quiet awg-warp-bypass.timer 2>/dev/null; then
        systemctl disable awg-warp-bypass.timer >/dev/null 2>&1 || failed=1
    fi
    if [[ "$_AWG_BYPASS_TX_SERVICE_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start awg-warp-bypass.service >/dev/null 2>&1 || failed=1
    fi
    if [[ "$_AWG_BYPASS_TX_TIMER_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start awg-warp-bypass.timer >/dev/null 2>&1 || failed=1
    fi
    [[ "$failed" -eq 0 ]] || return 1
    _commit_warp_bypass_setup_state
}

_abort_warp_bypass_setup() {
    log_error "$1"
    _rollback_warp_bypass_setup_state \
        || log_error "WARP bypass rollback incomplete; manual inspection is required."
    return 1
}

snapshot_warp_bypass_state() { _snapshot_warp_bypass_setup_state; }
rollback_warp_bypass_state() { _rollback_warp_bypass_setup_state; }
commit_warp_bypass_state() { _commit_warp_bypass_setup_state; }

setup_warp_bypass() {
    local conf_dir="/etc/amnezia/amneziawg"
    local bypass_conf="$conf_dir/warp-bypass.conf"
    local bypass_envfile="/etc/default/awg-warp-bypass"
    local bypass_script="/usr/local/sbin/awg-warp-bypass.sh"
    local bypass_svc="/etc/systemd/system/awg-warp-bypass.service"
    local bypass_timer="/etc/systemd/system/awg-warp-bypass.timer"
    local routes_file="$conf_dir/warp-bypass.routes"
    local marker="${AWG_DIR}/.warp_bypass_enabled_by_installer"
    local warp_tbl="${AWG_WARP_TABLE:-2408}"
    local marker_value="" owned_path marker_tmp bypass_tx_owned_here=0

    # `none` and non-WARP modes are state transitions, not no-ops. An owned
    # previous bundle is removed inside the same snapshot so a later installer
    # failure can restore files, exact routes and unit state.
    if [[ "${AWG_EGRESS:-direct}" != "warp" || "${AWG_WARP_BYPASS:-none}" == "none" ]]; then
        if [[ -e "$marker" || -L "$marker" ]]; then
            if [[ "${_AWG_BYPASS_TX_ACTIVE:-0}" -eq 0 ]]; then
                _snapshot_warp_bypass_setup_state || return 1
                bypass_tx_owned_here=1
            fi
            if ! teardown_warp_bypass; then
                _abort_warp_bypass_setup "Failed to disable the previous WARP bypass"
                return 1
            fi
            [[ "$bypass_tx_owned_here" -eq 0 ]] || _commit_warp_bypass_setup_state
        fi
        return 0
    fi

    # Fixed paths are modified only under an explicit ownership marker. Empty
    # markers are accepted as the legacy format created by older fork builds.
    if [[ -e "$marker" || -L "$marker" ]]; then
        [[ -f "$marker" && ! -L "$marker" ]] \
            || { log_error "Invalid WARP bypass marker: $marker"; return 1; }
        marker_value=$(<"$marker")
        [[ -z "$marker_value" || "$marker_value" == "v2" ]] \
            || { log_error "Unknown WARP bypass marker format: $marker"; return 1; }
        for owned_path in "$bypass_conf" "$bypass_envfile" "$bypass_script" "$bypass_svc" "$bypass_timer" "$routes_file"; do
            [[ ! -L "$owned_path" && ( ! -e "$owned_path" || -f "$owned_path" ) ]] \
                || { log_error "Refusing to modify an unsafe WARP bypass resource: $owned_path"; return 1; }
        done
    else
        for owned_path in "$bypass_conf" "$bypass_envfile" "$bypass_script" "$bypass_svc" "$bypass_timer" "$routes_file"; do
            if [[ -e "$owned_path" || -L "$owned_path" ]]; then
                log_error "Refusing to overwrite a foreign WARP bypass resource without a marker: $owned_path"
                return 1
            fi
        done
        marker_value="new"
    fi

    if [[ "${_AWG_BYPASS_TX_ACTIVE:-0}" -eq 0 ]]; then
        _snapshot_warp_bypass_setup_state || return 1
        bypass_tx_owned_here=1
    fi
    if [[ "$marker_value" == "new" ]]; then
        marker_tmp=$(awg_mktemp "$AWG_DIR") \
            || { _abort_warp_bypass_setup "mktemp marker"; return 1; }
        printf 'v2\n' > "$marker_tmp" && chmod 600 "$marker_tmp" && mv -f "$marker_tmp" "$marker" \
            || { rm -f "$marker_tmp"; _abort_warp_bypass_setup "Could not create $marker"; return 1; }
        marker_value="v2"
    fi

    mkdir -p "$conf_dir" /etc/default /usr/local/sbin || {
        _abort_warp_bypass_setup "setup_warp_bypass: mkdir"; return 1;
    }

    # dig is needed to resolve domains (custom sources can be domains, not
    # only CIDRs). Install quietly if missing.
    if ! command -v dig >/dev/null 2>&1; then
        log "Installing dnsutils (dig) for WARP bypass domain resolution..."
        DEBIAN_FRONTEND=noninteractive apt install -y dnsutils >/dev/null 2>&1 \
            || log_warn "apt install dnsutils failed; CIDR sources will work, domain resolution won't."
    fi

    # 1. Config: list of sources, one per line.
    local tmp_conf
    tmp_conf=$(awg_mktemp "$conf_dir") || { _abort_warp_bypass_setup "mktemp config"; return 1; }
    if ! {
        echo "# WARP bypass sources (auto-generated by install_amneziawg.sh)"
        echo "# One source per line. Allowed:"
        echo "#   youtube                        — YouTube CIDRs (touhidurrr/iplist-youtube)"
        echo "#   https://example.com/list.txt   — remote URL"
        echo "#   /path/to/local/list.txt        — local file"
        echo "# Each source's content may be CIDRs (1.2.3.4/24) or domains"
        echo "# (resolved via @1.1.1.1), one per line. dnsmasq-style decorations"
        echo "# (full:, @tag, # comments) are accepted."
        local _OLDIFS="$IFS"
        IFS=','
        local _s
        for _s in $AWG_WARP_BYPASS; do
            _s="${_s## }"; _s="${_s%% }"
            [[ -z "$_s" ]] && continue
            case "$_s" in
                youtube)  echo "youtube" ;;
                custom:*) echo "${_s#custom:}" ;;
            esac
        done
        IFS="$_OLDIFS"
    } > "$tmp_conf"; then
        rm -f "$tmp_conf"
        _abort_warp_bypass_setup "write temporary $bypass_conf"
        return 1
    fi
    chmod 600 "$tmp_conf" && mv -f "$tmp_conf" "$bypass_conf" \
        || { rm -f "$tmp_conf"; _abort_warp_bypass_setup "write $bypass_conf"; return 1; }

    # 2. Env file with the table number for the script and the systemd unit.
    local tmp_env
    tmp_env=$(awg_mktemp "$(dirname "$bypass_envfile")") \
        || { _abort_warp_bypass_setup "mktemp env"; return 1; }
    printf 'WARP_TABLE=%s\n' "$warp_tbl" > "$tmp_env" \
        && chmod 0644 "$tmp_env" && mv -f "$tmp_env" "$bypass_envfile" \
        || { rm -f "$tmp_env"; _abort_warp_bypass_setup "write $bypass_envfile"; return 1; }

    # 3. /usr/local/sbin/awg-warp-bypass.sh — the core logic.
    # Quoted heredoc so bash doesn't interpolate ${...}/$... at install time.
    local tmp_script
    tmp_script=$(awg_mktemp "$(dirname "$bypass_script")") \
        || { _abort_warp_bypass_setup "mktemp script"; return 1; }
    if ! cat > "$tmp_script" <<'EOF_AWG_WARP_BYPASS'
#!/bin/bash
# Apply WARP bypass routes: CIDRs or resolved domains → routing table via main NIC.
# Auto-installed by install_amneziawg.sh (--warp-bypass=...).
# Refresh via the owned systemd timer.

set -o pipefail

CONFIG_FILE="/etc/amnezia/amneziawg/warp-bypass.conf"
ENV_FILE="/etc/default/awg-warp-bypass"
YOUTUBE_URL="https://raw.githubusercontent.com/touhidurrr/iplist-youtube/main/lists/cidr4.txt"
LOCK_FILE="/run/awg-warp-bypass.lock"
ROUTES_FILE="/etc/amnezia/amneziawg/warp-bypass.routes"

WARP_TABLE=$(sed -nE 's/^WARP_TABLE=([0-9]+)$/\1/p' "$ENV_FILE" 2>/dev/null | head -1)
WARP_TABLE="${WARP_TABLE:-2408}"
log() { printf '[awg-warp-bypass] %s\n' "$*"; }
[[ "$WARP_TABLE" =~ ^[1-9][0-9]{0,9}$ ]] \
    && (( 10#$WARP_TABLE <= 4294967295 )) \
    && (( 10#$WARP_TABLE < 253 || 10#$WARP_TABLE > 255 )) \
    || { log "invalid WARP_TABLE=$WARP_TABLE"; exit 1; }

[[ -f "$CONFIG_FILE" ]] || { log "no config at $CONFIG_FILE, exit"; exit 0; }

exec 200>"$LOCK_FILE"
flock -n 200 || { log "another instance running, exit"; exit 0; }

ROUTE_GET=$(ip -4 route get 1.1.1.1 2>/dev/null) || ROUTE_GET=""
NIC=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$ROUTE_GET")
GW=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<< "$ROUTE_GET")
ROUTE_TABLE=$(awk '{for (i=1; i<=NF; i++) if ($i=="table") {print $(i+1); exit}}' <<< "$ROUTE_GET")
valid_iface() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]; }
valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] \
        && (( 10#${BASH_REMATCH[1]} <= 255 && 10#${BASH_REMATCH[2]} <= 255 \
              && 10#${BASH_REMATCH[3]} <= 255 && 10#${BASH_REMATCH[4]} <= 255 ))
}
if [[ -z "$NIC" ]] || ! valid_iface "$NIC"; then
    log "no usable IPv4 route — cannot determine bypass egress, exit 1"
    exit 1
fi
if [[ -n "$ROUTE_TABLE" && "$ROUTE_TABLE" != main && "$ROUTE_TABLE" != 254 ]]; then
    log "route-get selected non-main table $ROUTE_TABLE; refusing a possibly tunneled bypass egress"
    exit 1
fi
if [[ -n "$GW" ]] && ! valid_ipv4 "$GW"; then
    log "invalid bypass gateway: $GW"
    exit 1
fi
case "$NIC" in
    awg*|wg*|warp*|tun*|tap*)
        log "route-get selected a tunnel-like interface $NIC; refusing bypass egress"
        exit 1
        ;;
esac

# `ip route get` follows the live RPDB and may therefore select a tunnel even
# when it omits the `table` token. Require the chosen nexthop to match an
# actual default in table main before installing any direct-bypass route.
MAIN_DEFAULTS=$(ip -o -4 route show table main default 2>/dev/null) || MAIN_DEFAULTS=""
main_default_match=0
while IFS= read -r main_default; do
    [[ -n "$main_default" ]] || continue
    main_dev=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$main_default")
    main_gw=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<< "$main_default")
    if [[ "$main_dev" == "$NIC" && "$main_gw" == "$GW" ]]; then
        main_default_match=1
        break
    fi
done <<< "$MAIN_DEFAULTS"
if (( main_default_match == 0 )); then
    log "route-get nexthop is not an exact table-main default; refusing bypass egress"
    exit 1
fi

log "bypass egress: ${GW:+via $GW }dev $NIC, table $WARP_TABLE"

cidr_re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'
ipv4_re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
added=0; failed_resolve=0; rejected=0; queued=0; address_budget=0
MAX_ROUTES=2048
MAX_ADDRESSES=1048576
MAX_CONTENT_BYTES=2097152
CANDIDATE_FILE=$(mktemp -p "$(dirname "$ROUTES_FILE")" '.warp-bypass.candidates.XXXXXX') || exit 1
LEDGER_TMP=$(mktemp -p "$(dirname "$ROUTES_FILE")" '.warp-bypass.routes.XXXXXX') || { rm -f "$CANDIDATE_FILE"; exit 1; }
cleanup() { rm -f "$CANDIDATE_FILE" "$LEDGER_TMP"; }
trap cleanup EXIT

add_route() {
    local route="$1" a b c d prefix span ip_int route_end
    if ! [[ "$route" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([12][0-9]|3[0-2])$ ]]; then
        rejected=$(( rejected + 1 )); return
    fi
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"; prefix="${BASH_REMATCH[5]}"
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 \
       && 10#$prefix >= 19 && 10#$prefix <= 32 )) \
        || { rejected=$(( rejected + 1 )); return; }
    # Never bypass WARP for private or RFC 6890 special-use destinations.
    if (( 10#$a == 0 || 10#$a == 10 || 10#$a == 127 || 10#$a >= 224 \
          || (10#$a == 100 && 10#$b >= 64 && 10#$b <= 127) \
          || (10#$a == 169 && 10#$b == 254) \
          || (10#$a == 172 && 10#$b >= 16 && 10#$b <= 31) \
          || (10#$a == 192 && 10#$b == 168) \
          || (10#$a == 192 && ((10#$b == 0 && (10#$c == 0 || 10#$c == 2)) \
              || (10#$b == 31 && 10#$c == 196) || (10#$b == 52 && 10#$c == 193) \
              || (10#$b == 88 && 10#$c == 99) || (10#$b == 175 && 10#$c == 48))) \
          || (10#$a == 198 && (10#$b == 18 || 10#$b == 19 || (10#$b == 51 && 10#$c == 100))) \
          || (10#$a == 203 && 10#$b == 0 && 10#$c == 113) )); then
        rejected=$(( rejected + 1 )); return
    fi
    span=$(( 1 << (32 - 10#$prefix) ))
    ip_int=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    if (( ip_int % span != 0 )); then
        rejected=$(( rejected + 1 )); return
    fi
    route_end=$(( ip_int + span - 1 ))
    # A broader /19-/23 must not smuggle a special-use /24 inside it.
    if (( (ip_int <= 0xC00000FF && route_end >= 0xC0000000) \
          || (ip_int <= 0xC00002FF && route_end >= 0xC0000200) \
          || (ip_int <= 0xC01FC4FF && route_end >= 0xC01FC400) \
          || (ip_int <= 0xC034C1FF && route_end >= 0xC034C100) \
          || (ip_int <= 0xC05863FF && route_end >= 0xC0586300) \
          || (ip_int <= 0xC0AF30FF && route_end >= 0xC0AF3000) \
          || (ip_int <= 0xC63364FF && route_end >= 0xC6336400) \
          || (ip_int <= 0xCB0071FF && route_end >= 0xCB007100) )); then
        rejected=$(( rejected + 1 )); return
    fi
    if (( queued >= MAX_ROUTES || address_budget + span > MAX_ADDRESSES )); then
        rejected=$(( rejected + 1 )); return
    fi
    printf '%s\n' "$route" >> "$CANDIDATE_FILE" || return 1
    queued=$(( queued + 1 )); address_budget=$(( address_budget + span ))
}

valid_hostname() {
    local host="$1" label
    (( ${#host} >= 1 && ${#host} <= 253 )) || return 1
    [[ "$host" != .* && "$host" != -* && "$host" != *. && "$host" != *..* ]] || return 1
    local IFS=.
    read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
        [[ "$label" =~ ^[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?$ ]] || return 1
    done
}

process_entry() {
    local raw="$1"
    raw="${raw%%#*}"
    raw="$(echo "$raw" | xargs)"
    [[ -z "$raw" ]] && return
    local e="${raw%% *}"
    e="${e#full:}"
    e="${e%%@*}"
    [[ -z "$e" ]] && return
    if [[ "$e" =~ $cidr_re ]]; then
        [[ "$e" == */* ]] || e="${e}/32"
        add_route "$e" || return 1
    else
        if ! valid_hostname "$e"; then
            rejected=$(( rejected + 1 ))
            return
        fi
        local ips
        if command -v dig >/dev/null 2>&1; then
            ips=$(dig +short +time=2 +tries=1 @1.1.1.1 "$e" A 2>/dev/null)
        else
            ips=$(getent ahostsv4 "$e" 2>/dev/null | awk '{print $1}')
        fi
        if [[ -z "$ips" ]]; then
            failed_resolve=$(( failed_resolve + 1 ))
            return
        fi
        while IFS= read -r ip; do
            [[ "$ip" =~ $ipv4_re ]] || continue
            add_route "${ip}/32" || return 1
        done <<< "$ips"
    fi
}

process_content() {
    local content="$1"
    [[ -z "$content" ]] && return
    while IFS= read -r line; do
        process_entry "$line" || return 1
    done <<< "$content"
}

while IFS= read -r src; do
    src="${src%%#*}"
    src="$(echo "$src" | xargs)"
    [[ -z "$src" ]] && continue
    case "$src" in
        youtube)
            log "source: youtube (touhidurrr/iplist-youtube cidr4.txt)"
            if ! content=$(curl -fsSL --max-filesize "$MAX_CONTENT_BYTES" --max-time 30 --retry 2 "$YOUTUBE_URL"); then
                log "fetch failed: $YOUTUBE_URL"
                continue
            fi
            process_content "$content" || { log "cannot write bypass candidates"; exit 1; }
            ;;
        http://*|https://*)
            log "source: URL $src"
            if ! content=$(curl -fsSL --max-filesize "$MAX_CONTENT_BYTES" --max-time 30 --retry 2 "$src"); then
                log "fetch failed: $src"
                continue
            fi
            process_content "$content" || { log "cannot write bypass candidates"; exit 1; }
            ;;
        /*)
            log "source: file $src"
            if [[ ! -r "$src" ]]; then
                log "cannot read $src"
                continue
            fi
            if [[ $(wc -c < "$src") -gt "$MAX_CONTENT_BYTES" ]]; then
                log "source too large: $src"
                continue
            fi
            content=$(cat "$src")
            process_content "$content" || { log "cannot write bypass candidates"; exit 1; }
            ;;
        *)
            log "unknown source spec: $src"
            ;;
    esac
done < "$CONFIG_FILE"

sort -u -o "$CANDIDATE_FILE" "$CANDIDATE_FILE" \
    || { log "cannot normalize bypass candidates"; exit 1; }
if (( queued == 0 )); then
    log "no safe bypass candidates; preserving the previous route ledger"
    exit 1
fi

# Validate the complete previous ledger before touching either routes or the
# ledger itself. A corrupt/symlinked ledger is an ownership boundary violation:
# fail closed and leave the last-known routes intact for an operator to inspect.
ledger_route_valid() {
    local route="$1" a b c d prefix span ip_int route_end
    [[ "$route" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([12][0-9]|3[0-2])$ ]] || return 1
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"; prefix="${BASH_REMATCH[5]}"
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 \
       && 10#$prefix >= 19 && 10#$prefix <= 32 )) || return 1
    (( 10#$a != 0 && 10#$a != 10 && 10#$a != 127 && 10#$a < 224 \
       && !(10#$a == 100 && 10#$b >= 64 && 10#$b <= 127) \
       && !(10#$a == 169 && 10#$b == 254) \
       && !(10#$a == 172 && 10#$b >= 16 && 10#$b <= 31) \
       && !(10#$a == 192 && 10#$b == 168) \
       && !(10#$a == 192 && ((10#$b == 0 && (10#$c == 0 || 10#$c == 2)) \
            || (10#$b == 31 && 10#$c == 196) || (10#$b == 52 && 10#$c == 193) \
            || (10#$b == 88 && 10#$c == 99) || (10#$b == 175 && 10#$c == 48))) \
       && !(10#$a == 198 && (10#$b == 18 || 10#$b == 19 || (10#$b == 51 && 10#$c == 100))) \
       && !(10#$a == 203 && 10#$b == 0 && 10#$c == 113) )) || return 1
    span=$(( 1 << (32 - 10#$prefix) ))
    ip_int=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    (( ip_int % span == 0 )) || return 1
    route_end=$(( ip_int + span - 1 ))
    (( !(ip_int <= 0xC00000FF && route_end >= 0xC0000000) \
       && !(ip_int <= 0xC00002FF && route_end >= 0xC0000200) \
       && !(ip_int <= 0xC01FC4FF && route_end >= 0xC01FC400) \
       && !(ip_int <= 0xC034C1FF && route_end >= 0xC034C100) \
       && !(ip_int <= 0xC05863FF && route_end >= 0xC0586300) \
       && !(ip_int <= 0xC0AF30FF && route_end >= 0xC0AF3000) \
       && !(ip_int <= 0xC63364FF && route_end >= 0xC6336400) \
       && !(ip_int <= 0xCB0071FF && route_end >= 0xCB007100) ))
}

old_table=""
old_routes=()
declare -A old_route_seen=()
if [[ -e "$ROUTES_FILE" || -L "$ROUTES_FILE" ]]; then
    [[ -f "$ROUTES_FILE" && ! -L "$ROUTES_FILE" ]] \
        || { log "unsafe route ledger (not a regular file): $ROUTES_FILE"; exit 1; }
    ledger_line_no=0
    while IFS= read -r ledger_line || [[ -n "$ledger_line" ]]; do
        ledger_line_no=$(( ledger_line_no + 1 ))
        if (( ledger_line_no == 1 )); then
            [[ "$ledger_line" =~ ^table=([1-9][0-9]{0,9})$ ]] \
                || { log "malformed route ledger header"; exit 1; }
            old_table="${BASH_REMATCH[1]}"
            (( 10#$old_table <= 4294967295 )) \
                && (( 10#$old_table < 253 || 10#$old_table > 255 )) \
                || { log "invalid route ledger table=$old_table"; exit 1; }
            continue
        fi
        (( ${#old_routes[@]} < MAX_ROUTES )) \
            || { log "route ledger exceeds $MAX_ROUTES entries"; exit 1; }
        ledger_route_valid "$ledger_line" \
            || { log "malformed or unsafe route ledger entry: $ledger_line"; exit 1; }
        [[ -z "${old_route_seen[$ledger_line]+present}" ]] \
            || { log "duplicate route ledger entry: $ledger_line"; exit 1; }
        old_route_seen["$ledger_line"]=1
        old_routes+=("$ledger_line")
    done < "$ROUTES_FILE"
    (( ledger_line_no >= 2 && ${#old_routes[@]} >= 1 )) \
        || { log "route ledger has no routes"; exit 1; }
fi

# Install the complete new set before retiring anything from the last-known
# good ledger. A partial refresh is rolled back for routes not owned before.
declare -A old_route_set=() old_route_present=() old_route_dev=() old_route_gw=() new_route_set=()
for old_route in "${old_routes[@]}"; do old_route_set["$old_route"]=1; done

# A route replace mutates an existing prefix in place. Snapshot the exact
# installer-created nexthop before the first mutation so a partial refresh can
# restore both replaced and retired routes while preserving the old ledger.
if [[ -n "$old_table" ]]; then
    for old_route in "${old_routes[@]}"; do
        if ! old_route_line=$(ip -o -4 route show table "$old_table" exact "$old_route" 2>/dev/null); then
            log "cannot snapshot previous route $old_route; preserving previous ledger"
            exit 1
        fi
        if [[ -z "$old_route_line" ]]; then
            old_route_present["$old_route"]=0
            continue
        fi
        if [[ "$old_route_line" == *$'\n'* ]]; then
            log "ambiguous previous route $old_route; preserving previous ledger"
            exit 1
        fi
        old_dst=$(awk '{print $1}' <<< "$old_route_line")
        if valid_ipv4 "$old_dst"; then old_dst="${old_dst}/32"; fi
        old_dev=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$old_route_line")
        old_gw=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<< "$old_route_line")
        if [[ "$old_dst" != "$old_route" || -z "$old_dev" ]] || ! valid_iface "$old_dev" \
            || { [[ -n "$old_gw" ]] && ! valid_ipv4 "$old_gw"; }; then
            log "unsafe previous route state for $old_route; preserving previous ledger"
            exit 1
        fi
        old_route_present["$old_route"]=1
        old_route_dev["$old_route"]="$old_dev"
        old_route_gw["$old_route"]="$old_gw"
    done
fi

# A candidate absent from the previous owned ledger must not replace a route
# created by an operator or another service in the same policy table.
while IFS= read -r candidate_route; do
    [[ -n "$candidate_route" ]] || continue
    if [[ "$old_table" != "$WARP_TABLE" || -z "${old_route_set[$candidate_route]+present}" ]]; then
        candidate_existing=$(ip -o -4 route show table "$WARP_TABLE" exact "$candidate_route" 2>/dev/null) \
            || { log "cannot inspect candidate route $candidate_route"; exit 1; }
        [[ -z "$candidate_existing" ]] \
            || { log "foreign same-prefix route collision: $candidate_route"; exit 1; }
    fi
done < "$CANDIDATE_FILE"

delete_new_route_exact() {
    local route="$1" current line current_dst current_dev current_gw
    # The delete is scoped to the complete nexthop installed above. Its exit
    # status alone is not authoritative: a concurrent replacement can make it
    # fail even though our route is already gone, so verify the postcondition.
    if [[ -n "$GW" ]]; then
        if ip -4 route del "$route" via "$GW" dev "$NIC" table "$WARP_TABLE" 2>/dev/null; then :; fi
    else
        if ip -4 route del "$route" dev "$NIC" table "$WARP_TABLE" 2>/dev/null; then :; fi
    fi
    current=$(ip -o -4 route show table "$WARP_TABLE" exact "$route" 2>/dev/null) || return 1
    [[ -n "$current" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        current_dst=$(awk '{print $1}' <<< "$line")
        if valid_ipv4 "$current_dst"; then current_dst="${current_dst}/32"; fi
        current_dev=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$line")
        current_gw=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<< "$line")
        [[ "$current_dst" == "$route" ]] || return 1
        if [[ "$current_dev" == "$NIC" && "$current_gw" == "$GW" ]]; then
            return 1
        fi
    done <<< "$current"
    return 0
}

restore_old_route() {
    local route="$1"
    if [[ "${old_route_present[$route]:-0}" -eq 0 ]]; then
        delete_new_route_exact "$route"
    elif [[ -n "${old_route_gw[$route]}" ]]; then
        ip -4 route replace "$route" via "${old_route_gw[$route]}" \
            dev "${old_route_dev[$route]}" table "$old_table" 2>/dev/null
    else
        ip -4 route replace "$route" dev "${old_route_dev[$route]}" \
            table "$old_table" 2>/dev/null
    fi
}

delete_old_route_exact() {
    local route="$1"
    [[ "${old_route_present[$route]:-0}" -eq 1 ]] || return 0
    if [[ -n "${old_route_gw[$route]}" ]]; then
        ip -4 route del "$route" via "${old_route_gw[$route]}" \
            dev "${old_route_dev[$route]}" table "$old_table" 2>/dev/null
    else
        ip -4 route del "$route" dev "${old_route_dev[$route]}" \
            table "$old_table" 2>/dev/null
    fi
}

rollback_new_routes() {
    local route rollback_failed=0
    for route in "${new_routes[@]}"; do
        if [[ "$old_table" == "$WARP_TABLE" && -n "${old_route_set[$route]+x}" ]]; then
            restore_old_route "$route" || rollback_failed=1
        else
            delete_new_route_exact "$route" || rollback_failed=1
        fi
    done
    return "$rollback_failed"
}

restore_retired_old_routes() {
    local route restore_failed=0
    for route in "${retired_old_routes[@]}"; do
        restore_old_route "$route" || restore_failed=1
    done
    return "$restore_failed"
}

new_routes=()
retired_old_routes=()
install_failed=0
printf 'table=%s\n' "$WARP_TABLE" > "$LEDGER_TMP" \
    || { log "cannot initialize route ledger"; exit 1; }
while IFS= read -r route; do
    [[ -n "$route" ]] || continue
    if { [[ -n "$GW" ]] \
            && ip -4 route replace "$route" via "$GW" dev "$NIC" table "$WARP_TABLE" 2>/dev/null; } \
        || { [[ -z "$GW" ]] \
            && ip -4 route replace "$route" dev "$NIC" table "$WARP_TABLE" 2>/dev/null; }; then
        new_routes+=("$route")
        if ! printf '%s\n' "$route" >> "$LEDGER_TMP"; then
            install_failed=$(( install_failed + 1 ))
            break
        fi
        new_route_set["$route"]=1
        added=$(( added + 1 ))
    else
        install_failed=$(( install_failed + 1 ))
    fi
done < "$CANDIDATE_FILE"
if (( added == 0 || install_failed != 0 )); then
    rollback_new_routes \
        || log "warning: previous route nexthops were not restored completely"
    log "route refresh incomplete ($added installed, $install_failed failed); preserving previous ledger"
    exit 1
fi

# Re-parse the complete temporary ledger before retiring old routes. Every
# successfully installed route must appear exactly once after the exact header;
# a short/failed write must roll routes back and can never be renamed into place.
ledger_verify_line_no=0
ledger_verify_count=0
ledger_verify_failed=0
declare -A ledger_verify_seen=()
while IFS= read -r ledger_verify_line || [[ -n "$ledger_verify_line" ]]; do
    ledger_verify_line_no=$(( ledger_verify_line_no + 1 ))
    if (( ledger_verify_line_no == 1 )); then
        [[ "$ledger_verify_line" == "table=$WARP_TABLE" ]] || ledger_verify_failed=1
        continue
    fi
    if ! ledger_route_valid "$ledger_verify_line" \
        || [[ -n "${ledger_verify_seen[$ledger_verify_line]+present}" ]] \
        || [[ -z "${new_route_set[$ledger_verify_line]+present}" ]]; then
        ledger_verify_failed=1
        continue
    fi
    ledger_verify_seen["$ledger_verify_line"]=1
    ledger_verify_count=$(( ledger_verify_count + 1 ))
done < "$LEDGER_TMP"
if (( ledger_verify_failed != 0 || ledger_verify_line_no != added + 1 \
      || ledger_verify_count != added || ${#new_routes[@]} != added )); then
    rollback_new_routes \
        || log "warning: previous route nexthops were not restored completely"
    log "temporary route ledger is incomplete; preserving previous ledger"
    exit 1
fi

# Retire obsolete routes before committing the new ledger. Deletion is exact
# (prefix+nexthop+device+table); on any failure all completed mutations roll
# back while the old ledger is still authoritative.
retire_failed=0
if [[ -n "$old_table" ]]; then
    for old_route in "${old_routes[@]}"; do
        if [[ "$old_table" != "$WARP_TABLE" || -z "${new_route_set[$old_route]+x}" ]]; then
            if delete_old_route_exact "$old_route"; then
                [[ "${old_route_present[$old_route]:-0}" -eq 0 ]] \
                    || retired_old_routes+=("$old_route")
            else
                retire_failed=1
                break
            fi
        fi
    done
fi
if (( retire_failed != 0 )); then
    restore_retired_old_routes \
        || log "warning: retired routes were not restored completely"
    rollback_new_routes \
        || log "warning: previous route nexthops were not restored completely"
    log "cannot retire previous bypass routes; preserving previous ledger"
    exit 1
fi

if ! { chmod 0600 "$LEDGER_TMP" && mv -f "$LEDGER_TMP" "$ROUTES_FILE"; }; then
    restore_retired_old_routes \
        || log "warning: retired routes were not restored completely"
    rollback_new_routes \
        || log "warning: previous route nexthops were not restored completely"
    log "cannot update route ledger; preserving previous ledger"
    exit 1
fi
log "done: installed $added routes; rejected $rejected unsafe/excess entries; $failed_resolve domains failed to resolve"
EOF_AWG_WARP_BYPASS
    then
        rm -f "$tmp_script"
        _abort_warp_bypass_setup "write temporary $bypass_script"
        return 1
    fi
    chmod 0755 "$tmp_script" && mv -f "$tmp_script" "$bypass_script" \
        || { rm -f "$tmp_script"; _abort_warp_bypass_setup "write $bypass_script"; return 1; }

    # 4. systemd service — oneshot, no RemainAfterExit so each `start`
    # re-runs ExecStart (needed for timer + awg0 PostUp on restart).
    local tmp_svc
    tmp_svc=$(awg_mktemp "$(dirname "$bypass_svc")") \
        || { _abort_warp_bypass_setup "mktemp service"; return 1; }
    if ! cat > "$tmp_svc" <<'EOF_BYPASS_SVC'
[Unit]
Description=Apply WARP bypass routes (YouTube CIDRs / custom CIDRs / domain list)
Documentation=https://github.com/SNPR/amneziawg-installer
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/awg-warp-bypass
ExecStart=/usr/local/sbin/awg-warp-bypass.sh

[Install]
WantedBy=multi-user.target
EOF_BYPASS_SVC
    then
        rm -f "$tmp_svc"
        _abort_warp_bypass_setup "write temporary $bypass_svc"
        return 1
    fi
    chmod 0644 "$tmp_svc" && mv -f "$tmp_svc" "$bypass_svc" \
        || { rm -f "$tmp_svc"; _abort_warp_bypass_setup "write $bypass_svc"; return 1; }

    # 5. systemd timer — refresh every 6h (YouTube/CDN CIDRs and DNS records
    # drift noticeably faster than we re-roll the installer). Persistent=true
    # so a missed firing runs after boot.
    local tmp_timer
    tmp_timer=$(awg_mktemp "$(dirname "$bypass_timer")") \
        || { _abort_warp_bypass_setup "mktemp timer"; return 1; }
    if ! cat > "$tmp_timer" <<'EOF_BYPASS_TIMER'
[Unit]
Description=Refresh WARP bypass routes periodically

[Timer]
OnActiveSec=10min
OnUnitActiveSec=6h
Persistent=true
Unit=awg-warp-bypass.service

[Install]
WantedBy=timers.target
EOF_BYPASS_TIMER
    then
        rm -f "$tmp_timer"
        _abort_warp_bypass_setup "write temporary $bypass_timer"
        return 1
    fi
    chmod 0644 "$tmp_timer" && mv -f "$tmp_timer" "$bypass_timer" \
        || { rm -f "$tmp_timer"; _abort_warp_bypass_setup "write $bypass_timer"; return 1; }

    # 6. Marker for uninstall + activation.
    if [[ "$marker_value" != "v2" ]]; then
        marker_tmp=$(awg_mktemp "$AWG_DIR") \
            || { _abort_warp_bypass_setup "mktemp marker"; return 1; }
        printf 'v2\n' > "$marker_tmp" && chmod 600 "$marker_tmp" && mv -f "$marker_tmp" "$marker" \
            || { rm -f "$marker_tmp"; _abort_warp_bypass_setup "Could not update $marker"; return 1; }
    fi
    systemctl daemon-reload \
        || { _abort_warp_bypass_setup "systemctl daemon-reload"; return 1; }
    # Commit the first complete ledger synchronously; a Persistent timer must
    # not launch a second refresh over an unfinished first one.
    _release_warp_bypass_snapshot_lock \
        || { _abort_warp_bypass_setup "Failed to release the WARP bypass refresh lock"; return 1; }
    systemctl start awg-warp-bypass.service >/dev/null 2>&1 \
        || { _abort_warp_bypass_setup "awg-warp-bypass.service: initial start failed"; return 1; }
    systemctl enable --now awg-warp-bypass.timer >/dev/null 2>&1 \
        || { _abort_warp_bypass_setup "awg-warp-bypass.timer: enable --now failed"; return 1; }

    local src_count
    src_count=$(grep -c -v -E '^[[:space:]]*(#|$)' "$bypass_conf" 2>/dev/null || true)
    src_count="${src_count:-0}"
    [[ "$bypass_tx_owned_here" -eq 0 ]] || _commit_warp_bypass_setup_state
    log "WARP bypass installed: $src_count sources (see $bypass_conf), auto-refresh every 6 hours."
    return 0
}

# Remove only bypass resources proven by the fixed-path ownership marker.
# The caller stops awg0 first, so a legacy table flush cannot disturb live
# fail-closed defaults. v2 installs remove only routes from their ledger.
_valid_warp_bypass_ledger_route() {
    local route="$1" a b c d prefix span ip_int route_end
    [[ "$route" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([12][0-9]|3[0-2])$ ]] || return 1
    a="${BASH_REMATCH[1]}"; b="${BASH_REMATCH[2]}"; c="${BASH_REMATCH[3]}"; d="${BASH_REMATCH[4]}"; prefix="${BASH_REMATCH[5]}"
    (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 \
       && 10#$prefix >= 19 && 10#$prefix <= 32 )) || return 1
    (( 10#$a != 0 && 10#$a != 10 && 10#$a != 127 && 10#$a < 224 \
       && !(10#$a == 100 && 10#$b >= 64 && 10#$b <= 127) \
       && !(10#$a == 169 && 10#$b == 254) \
       && !(10#$a == 172 && 10#$b >= 16 && 10#$b <= 31) \
       && !(10#$a == 192 && 10#$b == 168) \
       && !(10#$a == 192 && ((10#$b == 0 && (10#$c == 0 || 10#$c == 2)) \
            || (10#$b == 31 && 10#$c == 196) || (10#$b == 52 && 10#$c == 193) \
            || (10#$b == 88 && 10#$c == 99) || (10#$b == 175 && 10#$c == 48))) \
       && !(10#$a == 198 && (10#$b == 18 || 10#$b == 19 || (10#$b == 51 && 10#$c == 100))) \
       && !(10#$a == 203 && 10#$b == 0 && 10#$c == 113) )) || return 1
    span=$(( 1 << (32 - 10#$prefix) ))
    ip_int=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    (( ip_int % span == 0 )) || return 1
    route_end=$(( ip_int + span - 1 ))
    (( !(ip_int <= 0xC00000FF && route_end >= 0xC0000000) \
       && !(ip_int <= 0xC00002FF && route_end >= 0xC0000200) \
       && !(ip_int <= 0xC01FC4FF && route_end >= 0xC01FC400) \
       && !(ip_int <= 0xC034C1FF && route_end >= 0xC034C100) \
       && !(ip_int <= 0xC05863FF && route_end >= 0xC0586300) \
       && !(ip_int <= 0xC0AF30FF && route_end >= 0xC0AF3000) \
       && !(ip_int <= 0xC63364FF && route_end >= 0xC6336400) \
       && !(ip_int <= 0xCB0071FF && route_end >= 0xCB007100) ))
}

teardown_warp_bypass() {
    local conf_dir="/etc/amnezia/amneziawg"
    local bypass_conf="$conf_dir/warp-bypass.conf"
    local bypass_envfile="/etc/default/awg-warp-bypass"
    local bypass_script="/usr/local/sbin/awg-warp-bypass.sh"
    local bypass_svc="/etc/systemd/system/awg-warp-bypass.service"
    local bypass_timer="/etc/systemd/system/awg-warp-bypass.timer"
    local routes_file="$conf_dir/warp-bypass.routes"
    local marker="${AWG_DIR}/.warp_bypass_enabled_by_installer"
    local marker_value="" owned_path table="" line="" route_line route_dev route_gw route_dst
    local bypass_lock_fd="" teardown_failed=0 teardown_tx_owned_here=0
    local -a old_routes=()
    local -A route_present=() route_devs=() route_gws=()

    [[ -e "$marker" || -L "$marker" ]] || return 0
    # Direct uninstall did not arm an outer installer transaction. Reuse the
    # same full snapshot/rollback contract so a partial teardown cannot strand
    # routes, files or unit state. setup_warp_bypass already supplies one.
    if [[ "${_AWG_BYPASS_TX_ACTIVE:-0}" -eq 0 ]]; then
        _snapshot_warp_bypass_setup_state || return 1
        teardown_tx_owned_here=1
    fi

    # The snapshot leaves units quiescent and hands us its refresh lock. If this
    # is a retry without that handoff, reacquire it before parsing/deleting.
    if [[ -n "${_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD:-}" ]]; then
        bypass_lock_fd="$_AWG_BYPASS_TX_SNAPSHOT_LOCK_FD"
        _AWG_BYPASS_TX_SNAPSHOT_LOCK_FD=""
    else
        exec {bypass_lock_fd}>/run/awg-warp-bypass.lock || teardown_failed=1
        if [[ "$teardown_failed" -eq 0 ]] \
            && ! flock -x -w 60 "$bypass_lock_fd"; then
            log_error "Timed out waiting for the WARP bypass lock during teardown."
            exec {bypass_lock_fd}>&-
            bypass_lock_fd=""
            teardown_failed=1
        fi
    fi
    if [[ "$teardown_failed" -eq 0 ]]; then
        if systemctl is-active --quiet awg-warp-bypass.timer 2>/dev/null \
            && ! systemctl stop awg-warp-bypass.timer >/dev/null 2>&1; then
            log_error "Failed to stop the WARP bypass timer before teardown."
            teardown_failed=1
        fi
        if systemctl is-active --quiet awg-warp-bypass.service 2>/dev/null \
            && ! systemctl stop awg-warp-bypass.service >/dev/null 2>&1; then
            log_error "Failed to stop the WARP bypass service before teardown."
            teardown_failed=1
        fi
        if systemctl is-active --quiet awg-warp-bypass.timer 2>/dev/null \
            || systemctl is-active --quiet awg-warp-bypass.service 2>/dev/null; then
            log_error "WARP bypass units did not reach a quiescent state; teardown cancelled."
            teardown_failed=1
        fi
    fi

    # Revalidate marker, every owned path, ledger and exact kernel nexthops
    # only after timer/service are stopped and while holding the refresh lock.
    if [[ "$teardown_failed" -eq 0 ]]; then
        if [[ ! -f "$marker" || -L "$marker" ]]; then
            log_error "Invalid WARP bypass marker: $marker"
            teardown_failed=1
        else
            marker_value=$(<"$marker")
            if [[ -n "$marker_value" && "$marker_value" != "v2" ]]; then
                log_error "Unknown WARP bypass marker format: $marker"
                teardown_failed=1
            fi
        fi
    fi
    if [[ "$teardown_failed" -eq 0 ]]; then
        for owned_path in "$bypass_conf" "$bypass_envfile" "$bypass_script" "$bypass_svc" "$bypass_timer" "$routes_file"; do
            if [[ -L "$owned_path" || ( -e "$owned_path" && ! -f "$owned_path" ) ]]; then
                log_error "Symlink/unusual file in WARP bypass ownership: $owned_path"
                teardown_failed=1
                break
            fi
        done
    fi
    if [[ "$teardown_failed" -eq 0 && "$marker_value" == "v2" ]]; then
        if ! _parse_warp_bypass_ledger "$routes_file"; then
            log_error "Invalid or empty WARP bypass route ledger."
            teardown_failed=1
        else
            table="$_AWG_BYPASS_PARSED_TABLE"
            old_routes=("${_AWG_BYPASS_PARSED_ROUTES[@]}")
        fi
        if [[ "$teardown_failed" -eq 0 ]]; then
            for line in "${old_routes[@]}"; do
                if ! route_line=$(ip -o -4 route show table "$table" exact "$line" 2>/dev/null); then
                    log_error "Failed to inspect route $line in table $table."
                    teardown_failed=1
                    break
                fi
                if [[ -z "$route_line" ]]; then
                    route_present["$line"]=0
                    continue
                fi
                if [[ "$route_line" == *$'\n'* ]]; then
                    log_error "Ambiguous owned route $line in table $table."
                    teardown_failed=1
                    break
                fi
                route_dst=$(awk '{print $1}' <<< "$route_line")
                if _valid_ipv4 "$route_dst"; then route_dst="${route_dst}/32"; fi
                route_dev=$(awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$route_line")
                route_gw=$(awk '{for (i=1; i<=NF; i++) if ($i=="via") {print $(i+1); exit}}' <<< "$route_line")
                if [[ "$route_dst" != "$line" || -z "$route_dev" ]] \
                    || ! _valid_warp_bypass_route_iface "$route_dev" \
                    || { [[ -n "$route_gw" ]] && ! _valid_ipv4 "$route_gw"; }; then
                    log_error "Unsafe current state for owned route $line; teardown cancelled."
                    teardown_failed=1
                    break
                fi
                route_present["$line"]=1
                route_devs["$line"]="$route_dev"
                route_gws["$line"]="$route_gw"
            done
        fi
    elif [[ "$teardown_failed" -eq 0 && -f "$bypass_envfile" ]]; then
        table=$(sed -nE 's/^WARP_TABLE=([0-9]+)$/\1/p' "$bypass_envfile" | head -1)
        [[ "$table" =~ ^[1-9][0-9]{0,9}$ ]] || table=""
    fi

    if [[ "$teardown_failed" -eq 0 ]] \
        && systemctl is-enabled --quiet awg-warp-bypass.timer 2>/dev/null \
        && ! systemctl disable awg-warp-bypass.timer >/dev/null 2>&1; then
        log_error "Failed to disable the WARP bypass timer."
        teardown_failed=1
    fi
    if [[ "$teardown_failed" -eq 0 ]] \
        && systemctl is-enabled --quiet awg-warp-bypass.service 2>/dev/null \
        && ! systemctl disable awg-warp-bypass.service >/dev/null 2>&1; then
        log_error "Failed to disable the WARP bypass service."
        teardown_failed=1
    fi

    if [[ "$teardown_failed" -eq 0 ]]; then
        # Rollback may now legitimately observe no current ledger: that is the
        # explicit terminal generation of an owned teardown, not corruption.
        _AWG_BYPASS_TX_EXPECT_CURRENT_ABSENT=1
        if [[ "$marker_value" == "v2" ]]; then
            for line in "${old_routes[@]}"; do
                [[ "${route_present[$line]:-0}" -eq 1 ]] || continue
                if [[ -n "${route_gws[$line]}" ]]; then
                    ip -4 route del "$line" via "${route_gws[$line]}" \
                        dev "${route_devs[$line]}" table "$table" 2>/dev/null \
                        || teardown_failed=1
                else
                    ip -4 route del "$line" dev "${route_devs[$line]}" \
                        table "$table" 2>/dev/null || teardown_failed=1
                fi
                if [[ "$teardown_failed" -ne 0 ]]; then
                    log_error "Failed to delete owned route $line; rolling back."
                    teardown_failed=1
                    break
                fi
            done
        elif [[ -n "$table" ]]; then
            # A legacy marker proves no per-route ownership, so never flush its table.
            log_warn "Legacy WARP bypass has no route ledger; unknown routes in table $table were left without an active policy rule."
        fi
    fi
    if [[ "$teardown_failed" -eq 0 ]]; then
        for owned_path in "$bypass_svc" "$bypass_timer" "$bypass_script" "$bypass_conf" "$bypass_envfile" "$routes_file"; do
            if ! rm -f -- "$owned_path"; then
                log_error "Failed to remove owned WARP bypass resource: $owned_path"
                teardown_failed=1
                break
            fi
        done
    fi
    if [[ "$teardown_failed" -eq 0 ]] && ! systemctl daemon-reload; then
        log_error "systemctl daemon-reload failed after WARP bypass teardown."
        teardown_failed=1
    fi
    if [[ "$teardown_failed" -eq 0 ]] && ! rm -f -- "$marker"; then
        log_error "Failed to remove WARP bypass marker: $marker"
        teardown_failed=1
    fi

    if [[ -n "$bypass_lock_fd" ]]; then
        _AWG_BYPASS_TX_SNAPSHOT_LOCK_FD="$bypass_lock_fd"
        bypass_lock_fd=""
    fi
    if [[ "$teardown_failed" -ne 0 ]]; then
        if [[ "$teardown_tx_owned_here" -eq 1 ]]; then
            _rollback_warp_bypass_setup_state \
                || log_error "WARP bypass teardown rollback was incomplete."
        fi
        return 1
    fi
    [[ "$teardown_tx_owned_here" -eq 0 ]] || _commit_warp_bypass_setup_state
    log "WARP bypass removed completely."
}

# ==============================================================================
# AmneziaDNS (dnsmasq on the tunnel gateway)
# ==============================================================================
#
# Why. A default Amnezia VPN client tunnels everything (AllowedIPs=0.0.0.0/0),
# and the site-based split tunneling UI (include/exclude per site) only lights
# up when the client was handed "a vpn:// URI from a real Amnezia server" —
# the URI with `isThirdPartyConfig:false` and an `amnezia-dns` container
# inside. Without that flag Amnezia's UI greys site-lists out with
# "Default server does not support split tunneling function".
#
# What we do. Bring up dnsmasq on the tunnel gateway (first address of
# $AWG_TUNNEL_SUBNET — e.g. 10.8.0.1) and emit the client vpn:// URI as a
# "real Amnezia server" (isThirdPartyConfig:false + amnezia-dns container).
# The client UI opens up the site-list: the user manually marks `youtube.com`,
# `vk.com`, etc. as "bypass VPN" and the DNS for those names is resolved
# locally on the device (not through our dnsmasq), traffic leaves the device
# straight to the ISP. The destination site sees the user's real IP.
#
# role=single or role=entry only. On the exit node it has no meaning: exit
# does not serve AWG clients directly, so its DNS would never reach a config.
#
# Conflict with systemd-resolved: we do NOT touch the 127.0.0.53:53 stub
# listener (we bind to the tunnel gateway IP, not 0.0.0.0). Only collide
# when someone ran a system with DNSStubListener pinned to 0.0.0.0. On stock
# Ubuntu 24.04 the stub is on 127.0.0.53 and we're on 10.x.x.1 — no clash.
# bind-dynamic is mandatory so dnsmasq does not wildcard-bind and survives
# the "awg0 comes up later" case (see the config-file comment below).
_read_amnezia_dns_marker() {
    local marker="$1" line key value
    _DNS_MARKER_VERSION=0; _DNS_MARKER_LEGACY=0; _DNS_MARKER_GATEWAY=""; _DNS_MARKER_RESOLVED=0
    _DNS_MARKER_WAS_ENABLED=1; _DNS_MARKER_WAS_ACTIVE=1
    _DNS_MARKER_UFW_UDP=0; _DNS_MARKER_UFW_TCP=0
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    if [[ $(wc -l < "$marker") -eq 1 ]] && grep -qE '^gateway=[0-9]+(\.[0-9]+){3}$' "$marker"; then
        line=$(<"$marker")
        _DNS_MARKER_GATEWAY="${line#gateway=}"
        _valid_ipv4 "$_DNS_MARKER_GATEWAY" || return 1
        _DNS_MARKER_VERSION=1; _DNS_MARKER_LEGACY=1
        # Legacy did not record ownership. Never infer it from a fixed path.
        return 0
    fi
    local marker_version="" seen_version=0 seen_gateway=0 seen_resolved=0
    local seen_enabled=0 seen_active=0 seen_udp=0 seen_tcp=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        key="${line%%=*}"; value="${line#*=}"
        case "$key" in
            version) [[ "$value" =~ ^[23]$ && "$seen_version" -eq 0 ]] || return 1; marker_version="$value"; seen_version=1 ;;
            gateway) _valid_ipv4 "$value" && [[ "$seen_gateway" -eq 0 ]] || return 1; _DNS_MARKER_GATEWAY="$value"; seen_gateway=1 ;;
            resolved_dropin) [[ "$value" =~ ^[01]$ && "$seen_resolved" -eq 0 ]] || return 1; _DNS_MARKER_RESOLVED="$value"; seen_resolved=1 ;;
            dnsmasq_was_enabled) [[ "$value" =~ ^[01]$ && "$seen_enabled" -eq 0 ]] || return 1; _DNS_MARKER_WAS_ENABLED="$value"; seen_enabled=1 ;;
            dnsmasq_was_active) [[ "$value" =~ ^[01]$ && "$seen_active" -eq 0 ]] || return 1; _DNS_MARKER_WAS_ACTIVE="$value"; seen_active=1 ;;
            ufw_udp_owned) [[ "$value" =~ ^[01]$ && "$seen_udp" -eq 0 ]] || return 1; _DNS_MARKER_UFW_UDP="$value"; seen_udp=1 ;;
            ufw_tcp_owned) [[ "$value" =~ ^[01]$ && "$seen_tcp" -eq 0 ]] || return 1; _DNS_MARKER_UFW_TCP="$value"; seen_tcp=1 ;;
            *) return 1 ;;
        esac
    done < "$marker"
    [[ "$seen_version" -eq 1 && "$seen_gateway" -eq 1 && "$seen_resolved" -eq 1 \
       && "$seen_enabled" -eq 1 && "$seen_active" -eq 1 ]] || return 1
    if [[ "$marker_version" == 2 ]]; then
        # v2 never recorded UFW ownership: an existing rule is foreign.
        [[ "$seen_udp" -eq 0 && "$seen_tcp" -eq 0 ]] || return 1
        _DNS_MARKER_UFW_UDP=0; _DNS_MARKER_UFW_TCP=0
    else
        [[ "$seen_udp" -eq 1 && "$seen_tcp" -eq 1 ]] || return 1
    fi
    _DNS_MARKER_VERSION="$marker_version"
}

_write_amnezia_dns_marker() {
    local marker="$1" gateway="$2" resolved="$3" was_enabled="$4" was_active="$5"
    local ufw_udp="$6" ufw_tcp="$7" tmp
    _valid_ipv4 "$gateway" || return 1
    [[ "$resolved" =~ ^[01]$ && "$was_enabled" =~ ^[01]$ && "$was_active" =~ ^[01]$ \
       && "$ufw_udp" =~ ^[01]$ && "$ufw_tcp" =~ ^[01]$ ]] || return 1
    tmp=$(awg_mktemp "$AWG_DIR") || return 1
    if printf 'version=3\ngateway=%s\nresolved_dropin=%s\ndnsmasq_was_enabled=%s\ndnsmasq_was_active=%s\nufw_udp_owned=%s\nufw_tcp_owned=%s\n' \
        "$gateway" "$resolved" "$was_enabled" "$was_active" "$ufw_udp" "$ufw_tcp" > "$tmp" \
        && chmod 600 "$tmp" && mv -f "$tmp" "$marker"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

_AMNEZIA_DNS_UFW_COMMENT="AWG-DNS-v3"

# Return 0 only for our exact, comment-tagged rule; 1 means absent, 2 means
# UFW state could not be read. A same-shaped untagged rule is never ours.
_amnezia_dns_ufw_rule_exists() {
    local gateway="$1" proto="$2" output line
    command -v ufw >/dev/null 2>&1 || return 2
    output=$(ufw show added 2>/dev/null) || return 2
    local base="ufw allow in on awg0 to ${gateway} port 53 proto ${proto} comment"
    while IFS= read -r line; do
        case "$line" in
            "$base ${_AMNEZIA_DNS_UFW_COMMENT}"|\
            "$base '${_AMNEZIA_DNS_UFW_COMMENT}'"|\
            "$base \"${_AMNEZIA_DNS_UFW_COMMENT}\"") return 0 ;;
        esac
    done <<< "$output"
    return 1
}

_amnezia_dns_ufw_rule_count() {
    local gateway="$1" proto="$2" output line count=0
    command -v ufw >/dev/null 2>&1 || return 2
    output=$(ufw show added 2>/dev/null) || return 2
    local base="ufw allow in on awg0 to ${gateway} port 53 proto ${proto}"
    while IFS= read -r line; do
        case "$line" in
            "$base"|"$base comment "*) count=$(( count + 1 )) ;;
        esac
    done <<< "$output"
    printf '%s\n' "$count"
}

_amnezia_dns_add_ufw_rule() {
    local gateway="$1" proto="$2" count rc
    _amnezia_dns_ufw_rule_exists "$gateway" "$proto"; rc=$?
    (( rc == 0 )) && return 0
    (( rc == 1 )) || return 1
    count=$(_amnezia_dns_ufw_rule_count "$gateway" "$proto") || return 1
    # UFW treats a different comment as an update to an existing rule. Never
    # attach our ownership tag to a same-shaped foreign rule.
    [[ "$count" -eq 0 ]] || return 1
    ufw allow in on awg0 to "$gateway" port 53 proto "$proto" \
        comment "$_AMNEZIA_DNS_UFW_COMMENT" >/dev/null 2>&1 || return 1
    _amnezia_dns_ufw_rule_exists "$gateway" "$proto"
}

_amnezia_dns_delete_ufw_rule() {
    local gateway="$1" proto="$2" count rc
    _amnezia_dns_ufw_rule_exists "$gateway" "$proto"; rc=$?
    (( rc == 1 )) && return 0
    (( rc == 0 )) || return 1
    count=$(_amnezia_dns_ufw_rule_count "$gateway" "$proto") || return 1
    # A comment is not part of UFW rule identity. Refuse deletion if a duplicate
    # same-shaped rule exists, because UFW could otherwise remove the foreign one.
    [[ "$count" -eq 1 ]] || return 1
    ufw delete allow in on awg0 to "$gateway" port 53 proto "$proto" \
        comment "$_AMNEZIA_DNS_UFW_COMMENT" >/dev/null 2>&1 || return 1
    _amnezia_dns_ufw_rule_exists "$gateway" "$proto"; rc=$?
    (( rc == 1 ))
}

_amnezia_dns_restore_file() {
    local target="$1" existed="$2" backup="$3" dir tmp
    [[ ! -L "$target" ]] || return 1
    dir=$(dirname "$target")
    [[ ! -L "$dir" && ( ! -e "$dir" || -d "$dir" ) ]] || return 1
    if [[ "$existed" -eq 0 ]]; then
        rm -f -- "$target"
        return
    fi
    [[ -f "$backup" && ! -L "$backup" ]] || return 1
    mkdir -p "$dir" || return 1
    tmp=$(awg_mktemp "$dir") || return 1
    cp -p -- "$backup" "$tmp" && mv -f -- "$tmp" "$target"
}

_amnezia_dns_restore_unit_state() {
    local unit="$1" was_enabled="$2" was_active="$3" failed=0
    if [[ "$was_enabled" -eq 1 ]]; then
        systemctl enable "$unit" >/dev/null 2>&1 || failed=1
    elif systemctl is-enabled --quiet "$unit" 2>/dev/null; then
        systemctl disable "$unit" >/dev/null 2>&1 || failed=1
    fi
    if [[ "$was_active" -eq 1 ]]; then
        systemctl restart "$unit" >/dev/null 2>&1 || failed=1
    elif systemctl is-active --quiet "$unit" 2>/dev/null; then
        systemctl stop "$unit" >/dev/null 2>&1 || failed=1
    fi
    return "$failed"
}

_AWG_DNS_TX_ACTIVE=0
_AWG_DNS_TX_SERVER_IP=""; _AWG_DNS_TX_OLD_GATEWAY=""
_AWG_DNS_TX_MARKER_HAD=0; _AWG_DNS_TX_CONF_HAD=0; _AWG_DNS_TX_RESOLVED_HAD=0
_AWG_DNS_TX_MARKER_BAK=""; _AWG_DNS_TX_CONF_BAK=""; _AWG_DNS_TX_RESOLVED_BAK=""
_AWG_DNS_TX_DNS_ENABLED=0; _AWG_DNS_TX_DNS_ACTIVE=0
_AWG_DNS_TX_RESOLVED_ENABLED=0; _AWG_DNS_TX_RESOLVED_ACTIVE=0
_AWG_DNS_TX_ATTEMPT_UDP=0; _AWG_DNS_TX_ATTEMPT_TCP=0
_AWG_DNS_TX_REMOVED_OLD_UDP=0; _AWG_DNS_TX_REMOVED_OLD_TCP=0
_AWG_DNS_TX_EXTERNAL=0

# Installer-level transaction hook. setup_amnezia_dns takes the actual
# snapshot after preflight and before its first mutation.
snapshot_amnezia_dns_state() {
    [[ "${_AWG_DNS_TX_ACTIVE:-0}" -eq 0 && "${_AWG_DNS_TX_EXTERNAL:-0}" -eq 0 ]] \
        || return 1
    _AWG_DNS_TX_EXTERNAL=1
}

commit_amnezia_dns_state() {
    local backup
    for backup in "$_AWG_DNS_TX_MARKER_BAK" "$_AWG_DNS_TX_CONF_BAK" "$_AWG_DNS_TX_RESOLVED_BAK"; do
        [[ -z "$backup" || ! -f "$backup" || -L "$backup" ]] || rm -f -- "$backup"
    done
    _AWG_DNS_TX_ACTIVE=0
    _AWG_DNS_TX_SERVER_IP=""; _AWG_DNS_TX_OLD_GATEWAY=""
    _AWG_DNS_TX_MARKER_HAD=0; _AWG_DNS_TX_CONF_HAD=0; _AWG_DNS_TX_RESOLVED_HAD=0
    _AWG_DNS_TX_MARKER_BAK=""; _AWG_DNS_TX_CONF_BAK=""; _AWG_DNS_TX_RESOLVED_BAK=""
    _AWG_DNS_TX_DNS_ENABLED=0; _AWG_DNS_TX_DNS_ACTIVE=0
    _AWG_DNS_TX_RESOLVED_ENABLED=0; _AWG_DNS_TX_RESOLVED_ACTIVE=0
    _AWG_DNS_TX_ATTEMPT_UDP=0; _AWG_DNS_TX_ATTEMPT_TCP=0
    _AWG_DNS_TX_REMOVED_OLD_UDP=0; _AWG_DNS_TX_REMOVED_OLD_TCP=0
    _AWG_DNS_TX_EXTERNAL=0
}

rollback_amnezia_dns_state() {
    if [[ "${_AWG_DNS_TX_ACTIVE:-0}" -ne 1 ]]; then
        _AWG_DNS_TX_EXTERNAL=0
        return 0
    fi
    local failed=0 conf_restored=0 resolved_restored=0
    local conf_file="/etc/dnsmasq.d/amneziawg.conf"
    local resolved_file="/etc/systemd/resolved.conf.d/amneziawg.conf"
    local marker="${AWG_DIR}/.amnezia_dns_enabled_by_installer"
    if [[ "$_AWG_DNS_TX_ATTEMPT_UDP" -eq 1 ]] \
        && ! _amnezia_dns_delete_ufw_rule "$_AWG_DNS_TX_SERVER_IP" udp; then failed=1; fi
    if [[ "$_AWG_DNS_TX_ATTEMPT_TCP" -eq 1 ]] \
        && ! _amnezia_dns_delete_ufw_rule "$_AWG_DNS_TX_SERVER_IP" tcp; then failed=1; fi
    if [[ "$_AWG_DNS_TX_REMOVED_OLD_UDP" -eq 1 ]] \
        && ! _amnezia_dns_add_ufw_rule "$_AWG_DNS_TX_OLD_GATEWAY" udp; then failed=1; fi
    if [[ "$_AWG_DNS_TX_REMOVED_OLD_TCP" -eq 1 ]] \
        && ! _amnezia_dns_add_ufw_rule "$_AWG_DNS_TX_OLD_GATEWAY" tcp; then failed=1; fi
    if _amnezia_dns_restore_file "$conf_file" "$_AWG_DNS_TX_CONF_HAD" "$_AWG_DNS_TX_CONF_BAK"; then
        conf_restored=1
    else
        failed=1
    fi
    if _amnezia_dns_restore_file "$resolved_file" "$_AWG_DNS_TX_RESOLVED_HAD" "$_AWG_DNS_TX_RESOLVED_BAK"; then
        resolved_restored=1
    else
        failed=1
    fi
    _amnezia_dns_restore_file "$marker" "$_AWG_DNS_TX_MARKER_HAD" "$_AWG_DNS_TX_MARKER_BAK" || failed=1
    if [[ "$resolved_restored" -eq 1 ]]; then
        _amnezia_dns_restore_unit_state systemd-resolved \
            "$_AWG_DNS_TX_RESOLVED_ENABLED" "$_AWG_DNS_TX_RESOLVED_ACTIVE" || failed=1
    else
        systemctl stop systemd-resolved >/dev/null 2>&1 || true
        systemctl is-active --quiet systemd-resolved 2>/dev/null && failed=1
    fi
    if [[ "$conf_restored" -eq 1 ]]; then
        _amnezia_dns_restore_unit_state dnsmasq \
            "$_AWG_DNS_TX_DNS_ENABLED" "$_AWG_DNS_TX_DNS_ACTIVE" || failed=1
    else
        systemctl stop dnsmasq >/dev/null 2>&1 || true
        systemctl is-active --quiet dnsmasq 2>/dev/null && failed=1
    fi
    [[ "$failed" -eq 0 ]] || return 1
    commit_amnezia_dns_state
}

setup_amnezia_dns() {
    [[ "${AWG_AMNEZIA_DNS:-off}" == "on" ]] || return 0
    [[ "${_AWG_DNS_TX_ACTIVE:-0}" -eq 0 ]] \
        || { log_error "A previous AmneziaDNS transaction is still pending."; return 1; }
    case "${AWG_ROLE:-single}" in
        single|entry) ;;
        *) log_error "setup_amnezia_dns: role=${AWG_ROLE} (need single or entry)"; return 1 ;;
    esac

    local server_ip="${AWG_TUNNEL_SUBNET%%/*}"
    _valid_ipv4 "$server_ip" \
        || { log_error "Invalid tunnel gateway '$server_ip' for AmneziaDNS"; return 1; }
    local conf_file="/etc/dnsmasq.d/amneziawg.conf"
    local resolved_file="/etc/systemd/resolved.conf.d/amneziawg.conf"
    local marker="${AWG_DIR}/.amnezia_dns_enabled_by_installer"
    local conf_dir resolved_dir
    conf_dir=$(dirname "$conf_file"); resolved_dir=$(dirname "$resolved_file")
    local old_gateway="$server_ip" resolved_owned=0 was_enabled=0 was_active=0
    local old_udp=0 old_tcp=0 final_udp=0 final_tcp=0 tmp rc proto owned
    local rule_count rule_owned
    local marker_had=0 conf_had=0 resolved_had=0
    local marker_bak="" conf_bak="" resolved_bak=""
    local dns_before_enabled=0 dns_before_active=0
    local resolved_before_enabled=0 resolved_before_active=0
    local ufw_available=0 tx_failed=0 tx_error="" dns_tx_owned_here=1
    [[ "${_AWG_DNS_TX_EXTERNAL:-0}" -eq 1 ]] && dns_tx_owned_here=0

    for tmp in "$AWG_DIR" "$conf_dir" "$resolved_dir"; do
        if [[ -L "$tmp" || ( -e "$tmp" && ! -d "$tmp" ) ]]; then
            log_error "Unsafe AmneziaDNS directory: $tmp"
            return 1
        fi
    done
    for tmp in "$marker" "$conf_file" "$resolved_file"; do
        if [[ -L "$tmp" || ( -e "$tmp" && ! -f "$tmp" ) ]]; then
            log_error "Unsafe AmneziaDNS fixed path: $tmp"
            return 1
        fi
    done

    if [[ -e "$marker" ]]; then
        _read_amnezia_dns_marker "$marker" \
            || { log_error "Invalid AmneziaDNS marker: $marker"; return 1; }
        old_gateway="$_DNS_MARKER_GATEWAY"; resolved_owned="$_DNS_MARKER_RESOLVED"
        was_enabled="$_DNS_MARKER_WAS_ENABLED"; was_active="$_DNS_MARKER_WAS_ACTIVE"
        old_udp="$_DNS_MARKER_UFW_UDP"; old_tcp="$_DNS_MARKER_UFW_TCP"
        marker_had=1
        if [[ "$resolved_owned" -eq 0 && -e "$resolved_file" ]]; then
            log_error "A foreign resolved drop-in appeared at $resolved_file; refusing to overwrite it."
            return 1
        fi
    else
        if [[ -e "$conf_file" || -e "$resolved_file" ]]; then
            log_error "Refusing to overwrite an existing AmneziaDNS/dnsmasq resource without an ownership marker."
            return 1
        fi
        systemctl is-enabled --quiet dnsmasq 2>/dev/null && was_enabled=1
        systemctl is-active --quiet dnsmasq 2>/dev/null && was_active=1
    fi

    systemctl is-enabled --quiet dnsmasq 2>/dev/null && dns_before_enabled=1
    systemctl is-active --quiet dnsmasq 2>/dev/null && dns_before_active=1
    systemctl is-enabled --quiet systemd-resolved 2>/dev/null && resolved_before_enabled=1
    systemctl is-active --quiet systemd-resolved 2>/dev/null && resolved_before_active=1

    if [[ "$marker_had" -eq 1 ]]; then
        marker_bak=$(awg_mktemp "$AWG_DIR") || return 1
        cp -p -- "$marker" "$marker_bak" || { log_error "Failed to preserve the AmneziaDNS marker"; return 1; }
    fi
    if [[ -f "$conf_file" ]]; then
        conf_had=1; conf_bak=$(awg_mktemp "$AWG_DIR") || return 1
        cp -p -- "$conf_file" "$conf_bak" || { log_error "Failed to preserve $conf_file"; return 1; }
    fi
    if [[ -f "$resolved_file" ]]; then
        resolved_had=1; resolved_bak=$(awg_mktemp "$AWG_DIR") || return 1
        cp -p -- "$resolved_file" "$resolved_bak" || { log_error "Failed to preserve $resolved_file"; return 1; }
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw_available=1
        for proto in udp tcp; do
            _amnezia_dns_ufw_rule_exists "$server_ip" "$proto"; rc=$?
            if (( rc == 2 )); then
                log_error "Failed to inspect UFW ownership for AmneziaDNS."
                return 1
            fi
            owned="$old_udp"; [[ "$proto" == tcp ]] && owned="$old_tcp"
            if (( rc == 0 )) && { [[ "$old_gateway" != "$server_ip" ]] || [[ "$owned" -ne 1 ]]; }; then
                log_error "A UFW rule tagged ${_AMNEZIA_DNS_UFW_COMMENT} is not owned by the current marker."
                return 1
            fi
            if [[ "$old_gateway" != "$server_ip" ]]; then
                _amnezia_dns_ufw_rule_exists "$old_gateway" "$proto"; rc=$?
                if (( rc == 2 )); then
                    log_error "Failed to inspect the previous AmneziaDNS UFW rule."
                    return 1
                fi
                if (( rc == 0 )) && [[ "$owned" -ne 1 ]]; then
                    log_error "The previous UFW rule tagged for AmneziaDNS is not confirmed by the marker."
                    return 1
                fi
            fi
        done
    elif [[ "$old_gateway" != "$server_ip" && ( "$old_udp" -eq 1 || "$old_tcp" -eq 1 ) ]]; then
        log_error "UFW is unavailable; owned AmneziaDNS rules cannot be moved safely."
        return 1
    fi

    local need_resolved=0
    if [[ "$resolved_before_active" -eq 1 ]] && {
        ss -H -uln 'sport = :53' 2>/dev/null \
            | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]|::):53([[:space:]]|$)' \
        || ss -H -tln 'sport = :53' 2>/dev/null \
            | grep -qE '(^|[[:space:]])(0\.0\.0\.0|\*|\[::\]|::):53([[:space:]]|$)'
    }; then
        need_resolved=1
    fi

    _AWG_DNS_TX_SERVER_IP="$server_ip"; _AWG_DNS_TX_OLD_GATEWAY="$old_gateway"
    _AWG_DNS_TX_MARKER_HAD="$marker_had"; _AWG_DNS_TX_CONF_HAD="$conf_had"; _AWG_DNS_TX_RESOLVED_HAD="$resolved_had"
    _AWG_DNS_TX_MARKER_BAK="$marker_bak"; _AWG_DNS_TX_CONF_BAK="$conf_bak"; _AWG_DNS_TX_RESOLVED_BAK="$resolved_bak"
    _AWG_DNS_TX_DNS_ENABLED="$dns_before_enabled"; _AWG_DNS_TX_DNS_ACTIVE="$dns_before_active"
    _AWG_DNS_TX_RESOLVED_ENABLED="$resolved_before_enabled"; _AWG_DNS_TX_RESOLVED_ACTIVE="$resolved_before_active"
    _AWG_DNS_TX_ATTEMPT_UDP=0; _AWG_DNS_TX_ATTEMPT_TCP=0
    _AWG_DNS_TX_REMOVED_OLD_UDP=0; _AWG_DNS_TX_REMOVED_OLD_TCP=0
    _AWG_DNS_TX_ACTIVE=1

    while :; do
        if ! command -v dnsmasq >/dev/null 2>&1; then
            log "Installing dnsmasq for AmneziaDNS..."
            if ! DEBIAN_FRONTEND=noninteractive apt install -y dnsmasq >/dev/null 2>&1; then
                tx_failed=1; tx_error="apt install dnsmasq failed"; break
            fi
            if ! systemctl stop dnsmasq >/dev/null 2>&1; then
                tx_failed=1; tx_error="dnsmasq: stop after installation failed"; break
            fi
        fi

        if [[ "$need_resolved" -eq 1 ]]; then
            if ! mkdir -p "$resolved_dir"; then tx_failed=1; tx_error="mkdir $resolved_dir"; break; fi
            tmp=$(awg_mktemp "$resolved_dir") \
                || { tx_failed=1; tx_error="mktemp resolved"; break; }
            if ! { printf '%s\n' '# Managed by install_amneziawg_en.sh (--amnezia-dns=on).' '[Resolve]' 'DNSStubListener=no' > "$tmp" \
                && chmod 0644 "$tmp" && mv -f -- "$tmp" "$resolved_file"; }; then
                rm -f -- "$tmp"; tx_failed=1; tx_error="write $resolved_file"; break
            fi
            resolved_owned=1
            if [[ "$resolved_before_active" -eq 1 ]] && ! systemctl restart systemd-resolved; then
                tx_failed=1; tx_error="systemd-resolved restart failed"; break
            fi
        elif [[ "$resolved_owned" -eq 1 ]]; then
            if ! rm -f -- "$resolved_file"; then tx_failed=1; tx_error="remove $resolved_file"; break; fi
            resolved_owned=0
            if [[ "$resolved_before_active" -eq 1 ]] && ! systemctl restart systemd-resolved; then
                tx_failed=1; tx_error="systemd-resolved restart failed"; break
            fi
        fi

        if ! mkdir -p "$conf_dir"; then tx_failed=1; tx_error="mkdir $conf_dir"; break; fi
        tmp=$(awg_mktemp "$conf_dir") || { tx_failed=1; tx_error="mktemp dnsmasq"; break; }
        if ! cat > "$tmp" <<EOF
# AmneziaDNS — local resolver for AWG clients.
# Managed by install_amneziawg_en.sh (--amnezia-dns=on).
listen-address=$server_ip
bind-dynamic
no-resolv
no-poll
server=1.1.1.1
server=1.0.0.1
cache-size=1000
domain-needed
bogus-priv
EOF
        then
            tx_failed=1; tx_error="write temporary dnsmasq config"; break
        fi
        if ! { chmod 0644 "$tmp" && mv -f -- "$tmp" "$conf_file"; }; then
            rm -f -- "$tmp"; tx_failed=1; tx_error="write $conf_file"; break
        fi

        if [[ "$ufw_available" -eq 1 ]]; then
            for proto in udp tcp; do
                owned=0
                if [[ "$old_gateway" == "$server_ip" ]]; then
                    owned="$old_udp"; [[ "$proto" == tcp ]] && owned="$old_tcp"
                fi
                _amnezia_dns_ufw_rule_exists "$server_ip" "$proto"; rc=$?
                if (( rc == 2 )); then tx_failed=1; tx_error="read UFW"; break; fi
                rule_owned=0
                if (( rc == 0 )); then
                    [[ "$owned" -eq 1 ]] \
                        || { tx_failed=1; tx_error="UFW ownership collision"; break; }
                    rule_owned=1
                else
                    rule_count=$(_amnezia_dns_ufw_rule_count "$server_ip" "$proto") \
                        || { tx_failed=1; tx_error="read UFW"; break; }
                    if [[ "$rule_count" -eq 0 ]]; then
                        if [[ "$proto" == udp ]]; then
                            _AWG_DNS_TX_ATTEMPT_UDP=1
                        else
                            _AWG_DNS_TX_ATTEMPT_TCP=1
                        fi
                        if ! _amnezia_dns_add_ufw_rule "$server_ip" "$proto"; then
                            tx_failed=1; tx_error="add UFW ${proto}/53"; break
                        fi
                        rule_owned=1
                    fi
                fi
                [[ "$proto" == udp ]] && final_udp="$rule_owned" || final_tcp="$rule_owned"
            done
            [[ "$tx_failed" -eq 0 ]] || break
        elif [[ "$old_gateway" == "$server_ip" ]]; then
            final_udp="$old_udp"; final_tcp="$old_tcp"
        fi

        if ! systemctl enable --now dnsmasq >/dev/null 2>&1; then
            tx_failed=1; tx_error="dnsmasq: enable --now failed"; break
        fi
        if ! systemctl restart dnsmasq >/dev/null 2>&1; then
            tx_failed=1; tx_error="dnsmasq: restart failed"; break
        fi

        if [[ "$ufw_available" -eq 1 && "$old_gateway" != "$server_ip" ]]; then
            if [[ "$old_udp" -eq 1 ]]; then
                _amnezia_dns_ufw_rule_exists "$old_gateway" udp; rc=$?
                if (( rc == 2 )); then tx_failed=1; tx_error="read previous UDP UFW"; break; fi
                if (( rc == 0 )); then
                    _AWG_DNS_TX_REMOVED_OLD_UDP=1
                    if ! _amnezia_dns_delete_ufw_rule "$old_gateway" udp; then
                        tx_failed=1; tx_error="delete previous UDP UFW"; break
                    fi
                fi
            fi
            if [[ "$old_tcp" -eq 1 ]]; then
                _amnezia_dns_ufw_rule_exists "$old_gateway" tcp; rc=$?
                if (( rc == 2 )); then tx_failed=1; tx_error="read previous TCP UFW"; break; fi
                if (( rc == 0 )); then
                    _AWG_DNS_TX_REMOVED_OLD_TCP=1
                    if ! _amnezia_dns_delete_ufw_rule "$old_gateway" tcp; then
                        tx_failed=1; tx_error="delete previous TCP UFW"; break
                    fi
                fi
            fi
        fi

        if ! _write_amnezia_dns_marker "$marker" "$server_ip" "$resolved_owned" \
            "$was_enabled" "$was_active" "$final_udp" "$final_tcp"; then
            tx_failed=1; tx_error="write AmneziaDNS marker"; break
        fi
        break
    done

    if [[ "$tx_failed" -eq 1 ]]; then
        log_error "AmneziaDNS setup rolled back: $tx_error"
        rollback_amnezia_dns_state \
            || log_error "AmneziaDNS rollback incomplete; snapshot remains pending."
        return 1
    fi

    [[ "$dns_tx_owned_here" -eq 0 ]] || commit_amnezia_dns_state
    log "AmneziaDNS configured: dnsmasq listens on ${server_ip}:53."
}

teardown_amnezia_dns() {
    local conf_file="/etc/dnsmasq.d/amneziawg.conf"
    local resolved_file="/etc/systemd/resolved.conf.d/amneziawg.conf"
    local marker="${AWG_DIR}/.amnezia_dns_enabled_by_installer"
    local path rc
    [[ -e "$marker" || -L "$marker" ]] || return 0
    _read_amnezia_dns_marker "$marker" \
        || { log_error "Invalid AmneziaDNS marker: $marker"; return 1; }
    for path in "$AWG_DIR" "$(dirname "$conf_file")" "$(dirname "$resolved_file")"; do
        if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
            log_error "Unsafe AmneziaDNS directory; cleanup cancelled: $path"
            return 1
        fi
    done
    for path in "$conf_file" "$resolved_file"; do
        if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
            log_error "Unsafe AmneziaDNS fixed path; cleanup cancelled: $path"
            return 1
        fi
    done

    if [[ "$_DNS_MARKER_UFW_UDP" -eq 1 || "$_DNS_MARKER_UFW_TCP" -eq 1 ]]; then
        command -v ufw >/dev/null 2>&1 \
            || { log_error "UFW is unavailable; owned AmneziaDNS rules were left intact."; return 1; }
        if [[ "$_DNS_MARKER_UFW_UDP" -eq 1 ]]; then
            _amnezia_dns_ufw_rule_exists "$_DNS_MARKER_GATEWAY" udp; rc=$?
            (( rc != 2 )) || { log_error "Failed to read UFW; cleanup cancelled."; return 1; }
            _amnezia_dns_delete_ufw_rule "$_DNS_MARKER_GATEWAY" udp \
                || { log_error "Failed to delete the owned AmneziaDNS UDP rule."; return 1; }
        fi
        if [[ "$_DNS_MARKER_UFW_TCP" -eq 1 ]]; then
            _amnezia_dns_ufw_rule_exists "$_DNS_MARKER_GATEWAY" tcp; rc=$?
            (( rc != 2 )) || { log_error "Failed to read UFW; cleanup cancelled."; return 1; }
            _amnezia_dns_delete_ufw_rule "$_DNS_MARKER_GATEWAY" tcp \
                || { log_error "Failed to delete the owned AmneziaDNS TCP rule."; return 1; }
        fi
    fi
    rm -f -- "$conf_file" || return 1
    if [[ "$_DNS_MARKER_RESOLVED" -eq 1 ]]; then
        rm -f -- "$resolved_file" || return 1
        if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
            systemctl restart systemd-resolved || return 1
        fi
    fi
    _amnezia_dns_restore_unit_state dnsmasq "$_DNS_MARKER_WAS_ENABLED" "$_DNS_MARKER_WAS_ACTIVE" \
        || { log_error "Failed to restore the previous dnsmasq state."; return 1; }
    rm -f -- "$marker" || return 1
    log "AmneziaDNS removed; the previous dnsmasq state has been restored."
}

# ==============================================================================
# Peer management
# ==============================================================================

# Get the next free IP in the subnet (arbitrary /16-/30 mask). Server = network+1;
# host range is [network+1 .. broadcast-1]. Returns the lowest free address
# (early exit) - up to 65534 slots for /16, but no full scan in the common case.
get_next_client_ip() {
    local subnet="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}"
    local net_int bcast_int
    read -r net_int bcast_int < <(_cidr_bounds "$subnet") || {
        log_error "get_next_client_ip: could not parse subnet '$subnet'"
        return 1
    }
    local server_int=$(( net_int + 1 ))

    # Associative array for O(1) lookup. Server (network+1) is taken.
    declare -A used_set
    used_set["$(_int_to_ipv4 "$server_int")"]=1
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        while IFS= read -r ip; do
            used_set["$ip"]=1
        done < <(grep -oP 'AllowedIPs\s*=\s*\K[0-9.]+' "$SERVER_CONF_FILE")
    fi

    local i candidate
    for (( i = net_int + 1; i <= bcast_int - 1; i++ )); do
        candidate=$(_int_to_ipv4 "$i")
        if [[ -z "${used_set[$candidate]+x}" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    log_error "No free IPs in subnet ${subnet}"
    return 1
}

# Derive the client IPv6 from its IPv4. Used only when ALLOW_IPV6_TUNNEL=1.
# Index = host offset in the subnet (offset = ipv4 - network), which is unique
# for any mask. Suffix encoding depends on the mask:
#   prefix == 24 -> decimal offset (== last octet; byte-identical to before),
#   otherwise    -> proper hex (printf '%x').
# The server (network+1, offset 1) yields "1" in both modes -> ::1 (see
# _derive_ipv6_server_addr, unchanged). Clients have offset >= 2.
# Returns the address string without a prefix length.
#
# get_next_client_ipv6 <ipv4_addr>
get_next_client_ipv6() {
    local ipv4="$1"
    if [[ -z "$ipv4" ]]; then
        log_error "get_next_client_ipv6: no IPv4 address supplied"
        return 1
    fi
    local tunnel="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}"
    local tprefix="${tunnel##*/}"
    local net_int bcast_int ip_int offset suffix
    read -r net_int bcast_int < <(_cidr_bounds "$tunnel") || {
        log_error "get_next_client_ipv6: could not parse subnet '$tunnel'"
        return 1
    }
    ip_int=$(_ipv4_to_int "$ipv4") || {
        log_error "get_next_client_ipv6: invalid IPv4 '$ipv4'"
        return 1
    }
    offset=$(( ip_int - net_int ))
    (( offset >= 1 && offset < bcast_int - net_int )) || { log_error "get_next_client_ipv6: IPv4 '$ipv4' outside subnet '$tunnel'"; return 1; }
    if [[ "$tprefix" == "24" ]]; then
        suffix="$offset"
    else
        suffix=$(printf '%x' "$offset")
    fi
    local subnet="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
    [[ "$subnet" =~ ^[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,3}::/64$ ]] \
        || { log_error "get_next_client_ipv6: invalid IPV6_SUBNET '$subnet'"; return 1; }
    local prefix="${subnet%%::*}"
    echo "${prefix}::${suffix}"
    return 0
}

# [Peer] addition to server config (atomic via tmpfile + mv).
#
# LOCKING CONTRACT: the caller MUST hold an exclusive flock on
# ${AWG_DIR}/.awg_config.lock when invoking this function. The lock is
# acquired by generate_client() — the only current caller. Do not call
# add_peer_to_server directly without holding the lock.
#
# Why an inner flock is not possible here: bash flock is not re-entrant
# across different file descriptors on the same file. generate_client()
# opens .awg_config.lock on its own fd and holds an exclusive lock; an
# attempt to open the same file on a new fd inside add_peer_to_server
# and take an exclusive lock there would self-deadlock (the parent lock
# is seen as foreign). Contract-based locking is the only reliable
# option in this situation. Re-entrant behaviour is possible only if
# the sub-function uses the SAME fd as the parent (via inheritance),
# which would require passing the fd as an argument.
#
# add_peer_to_server <name> <pubkey> <client_ip> [client_ipv6]
#
# client_ipv6 (optional 4th argument): IPv6 address without prefix length.
# If non-empty: AllowedIPs = <ipv4>/32, <ipv6>/128
# If empty (legacy): AllowedIPs = <ipv4>/32
add_peer_to_server() {
    local name="$1"
    local pubkey="$2"
    local client_ip="$3"
    local client_ipv6="${4:-}"

    if [[ -z "$name" || -z "$pubkey" || -z "$client_ip" ]]; then
        log_error "add_peer_to_server: insufficient arguments"
        return 1
    fi
    # The name goes into the config heredoc (#_Name = ...): a newline in the
    # name would inject a [Peer] section. Defense-in-depth, see generate_client.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "add_peer_to_server: invalid client name '$name'"
        return 1
    fi

    if grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Peer '$name' already exists in config"
        return 1
    fi

    # Add peer via temp file (atomic).
    # temp in the server config dir -> mv = atomic rename on the same filesystem.
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "mktemp failed"; return 1; }

    cp "$SERVER_CONF_FILE" "$tmpfile" || {
        rm -f "$tmpfile"
        log_error "Failed to copy server config"
        return 1
    }

    cat >> "$tmpfile" << EOF

[Peer]
#_Name = ${name}
PublicKey = ${pubkey}
EOF
    # PresharedKey — optional, written if passed via CLIENT_PSK env.
    # Must match the server peer and client [Peer].
    if [[ -n "${CLIENT_PSK:-}" ]]; then
        echo "PresharedKey = ${CLIENT_PSK}" >> "$tmpfile"
    fi
    if [[ -n "$client_ipv6" ]]; then
        echo "AllowedIPs = ${client_ip}/32, ${client_ipv6}/128" >> "$tmpfile"
    else
        echo "AllowedIPs = ${client_ip}/32" >> "$tmpfile"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Failed to update server config"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Peer '$name' added to server config."
    return 0
}

# Remove [Peer] from server config by name (with locking)
# remove_peer_from_server <name>
remove_peer_from_server() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "remove_peer_from_server: name not specified"
        return 1
    fi
    # Defense-in-depth: same contract as in add_peer_to_server.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "remove_peer_from_server: invalid client name '$name'"
        return 1
    fi

    # Inter-process lock
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Failed to acquire config lock"
        exec {lock_fd}>&-
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Peer '$name' not found in config"
        exec {lock_fd}>&-
        return 1
    fi

    # temp in the server config dir -> the final mv is an atomic rename.
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "mktemp failed"; exec {lock_fd}>&-; return 1; }

    # Remove [Peer] block containing #_Name = name
    # Logic: buffer each [Peer] block, check name, print only if not matching
    awk -v target="$name" '
    BEGIN { buf=""; is_target=0 }
    /^\[Peer\]/ {
        # Print previous buffer if not target
        if (buf != "" && !is_target) printf "%s", buf
        buf = $0 "\n"
        is_target = 0
        next
    }
    /^\[/ && !/^\[Peer\]/ {
        # Any other section — flush buffer
        if (buf != "" && !is_target) printf "%s", buf
        buf = ""
        is_target = 0
        print
        next
    }
    {
        if (buf != "") {
            buf = buf $0 "\n"
            if ($0 == "#_Name = " target) is_target = 1
        } else {
            print
        }
    }
    END {
        if (buf != "" && !is_target) printf "%s", buf
    }
    ' "$SERVER_CONF_FILE" > "$tmpfile" || {
        log_error "Failed to filter the server config (awk)"
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    }

    # Sanity-check BEFORE mv: on ENOSPC/I/O failure awk would leave an
    # empty/truncated tmpfile, and the atomic mv would replace a working
    # config with a broken one (losing the server PrivateKey and all peers).
    # [Interface] must survive.
    if ! grep -q '^\[Interface\]' "$tmpfile"; then
        log_error "Peer removal result looks corrupt ([Interface] is missing) - config left unchanged"
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    fi

    # Normalize: squeeze multiple blank lines into one.
    # tmpclean lives on the same filesystem as tmpfile (mv tmpclean->tmpfile atomic).
    local tmpclean
    tmpclean=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "mktemp failed"; exec {lock_fd}>&-; return 1; }
    if cat -s "$tmpfile" > "$tmpclean" 2>/dev/null; then
        mv "$tmpclean" "$tmpfile"
    else
        rm -f "$tmpclean"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Failed to update server config"
        exec {lock_fd}>&-
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    exec {lock_fd}>&-
    log "Peer '$name' removed from server config."
    return 0
}

# ==============================================================================
# Full client lifecycle
# ==============================================================================

# Generate QR code for client
# generate_qr <name>
generate_qr() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local png_file="$AWG_DIR/${name}.png"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Client config '$name' not found: $conf_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode is not installed, QR code not created for '$name'."
        return 1
    fi

    # C4: generate into a temp file and move it into place atomically, so an
    # interrupted qrencode cannot leave a partial/corrupt PNG over the working one.
    # awg_mktemp "$AWG_DIR" puts the tmp in the same directory (mv = atomic rename
    # on one filesystem) AND registers it in the shared cleanup registry, so a
    # SIGKILL between qrencode and mv leaves no orphan tmp.
    local tmp_png
    tmp_png=$(awg_mktemp "$AWG_DIR") || { log_error "mktemp error for QR '$name'"; return 1; }
    if ! qrencode -t png -o "$tmp_png" < "$conf_file"; then
        log_error "Failed to generate QR code for '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    chmod 600 "$tmp_png" 2>/dev/null
    if ! mv -f "$tmp_png" "$png_file"; then
        log_error "Failed to save QR code for '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    log_debug "QR code for '$name' created: $png_file"
    return 0
}

# Generate vpn:// URI for import into Amnezia Client
# generate_vpn_uri <name>
generate_vpn_uri() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local uri_file="$AWG_DIR/${name}.vpnuri"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Client config '$name' not found: $conf_file"
        return 1
    fi

    if ! command -v perl &>/dev/null; then
        log_warn "perl not found, vpn:// URI not created for '$name'."
        return 1
    fi

    if ! perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null; then
        log_warn "Perl modules Compress::Zlib/MIME::Base64 not found, vpn:// URI not created."
        return 1
    fi

    load_awg_params || return 1

    # AWG_PORT is the only UNquoted numeric field of the inner JSON ("port":N).
    # An empty/non-numeric value would produce "port":, - syntactically broken
    # JSON, which Amnezia Client silently fails to import.
    if ! [[ "${AWG_PORT:-}" =~ ^[0-9]+$ ]]; then
        log_warn "AWG_PORT is unset or not a number ('${AWG_PORT:-}') - vpn:// URI not created for '$name'."
        return 1
    fi

    local client_privkey client_ip client_ipv6 server_pubkey endpoint allowed_ips client_psk
    client_privkey=$(grep -oP 'PrivateKey\s*=\s*\K\S+' "$conf_file") || return 1
    # Extract IPv4 from Address (first field before comma, without /prefix).
    # Regex stops at digits and dots - does not capture IPv6 in dual-stack configs.
    client_ip=$(awk '/^Address[[:space:]]*=/{
        sub(/^Address[[:space:]]*=[[:space:]]*/, "")
        sub(/\r$/, "")
        n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
        sub(/\/[0-9]+$/, "", parts[1])
        print parts[1]; exit
    }' "$conf_file") || return 1
    # Extract IPv6 from Address (second field, if present), without /prefix.
    client_ipv6=$(awk '/^Address[[:space:]]*=/{
        sub(/^Address[[:space:]]*=[[:space:]]*/, "")
        sub(/\r$/, "")
        n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
        if (n >= 2) {
            sub(/\/[0-9]+$/, "", parts[2])
            gsub(/[[:space:]]/, "", parts[2])
            print parts[2]
        }
        exit
    }' "$conf_file" 2>/dev/null)
    client_ipv6="${client_ipv6:-}"
    _ensure_server_public_key || return 1
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || return 1
    # PresharedKey is optional. awk instead of grep so an empty result is not
    # treated as failure (grep -P without a match → rc=1, not what we want here).
    # Also strip a trailing CR (CRLF from Windows editors) and trailing spaces
    # — leaking them into the JSON psk_key would break the handshake just as
    # cleanly as the missing field. Without psk_key in inner JSON AmneziaVPN
    # import via vpn:// loses the PSK and the handshake fails (issue #67,
    # fix v5.11.4).
    client_psk=$(awk '/^[[:space:]]*PresharedKey[[:space:]]*=/{sub(/^[[:space:]]*PresharedKey[[:space:]]*=[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[ \t]+$/, ""); print; exit}' "$conf_file" 2>/dev/null)
    local raw_endpoint
    raw_endpoint=$(grep -oP 'Endpoint\s*=\s*\K\S+' "$conf_file") || return 1
    if [[ "$raw_endpoint" == \[* ]]; then
        # IPv6: [addr]:port
        endpoint="${raw_endpoint%%]:*}"
        endpoint="${endpoint#\[}"
    else
        # IPv4/hostname: addr:port
        endpoint="${raw_endpoint%:*}"
    fi
    # tr -d ' \r' - strips spaces AND CR (on CRLF configs '.+' greedily
    # captures \r into the value, which breaks JSON.allowed_ips).
    #
    # v5.27.1: do NOT touch. The value goes into the allowed_ips JSON array via
    # split(/,/), so spaces here are harmful - they would end up inside the
    # array elements. This path does not damage the spaces in the client
    # .conf: the embedded config is inlined from the file as it is.
    allowed_ips=$(grep -oP 'AllowedIPs\s*=\s*\K.+' "$conf_file" | paste -sd, - | tr -d ' \r')
    # Test for EMPTINESS, not for the exit status: the `||` did not fire even
    # on a valueless "AllowedIPs = " line, because grep matched the space and
    # exited zero, and a pipeline with paste makes the status useless anyway.
    [[ -n "$allowed_ips" ]] || { log_warn "AllowedIPs could not be read from '$conf_file' - the link will carry a full tunnel."; allowed_ips="0.0.0.0/0"; }

    # MTU/PersistentKeepalive/DNS from .conf - these can be changed via manage modify.
    # On vpn:// import the Amnezia client uses the structured inner-JSON fields
    # (awgConfigurator takes mtu from the structured field, not the embedded config),
    # so hardcoding them would desync from .conf - same class as issue #67 (the
    # structured psk_key field was authoritative).
    local mtu keepalive dns_line dns1 dns2
    mtu=$(grep -oP '^MTU\s*=\s*\K[0-9]+' "$conf_file" | head -n1); mtu="${mtu:-1280}"
    keepalive=$(grep -oP '^PersistentKeepalive\s*=\s*\K[0-9]+' "$conf_file" | head -n1); keepalive="${keepalive:-33}"
    dns_line=$(grep -oP '^DNS\s*=\s*\K.+' "$conf_file" | paste -sd, - | tr -d ' \r')
    dns1="${dns_line%%,*}"; dns1="${dns1:-1.1.1.1}"
    if [[ "$dns_line" == *,* ]]; then dns2="${dns_line#*,}"; dns2="${dns2%%,*}"; else dns2="$dns1"; fi

    # AmneziaDNS: "real Amnezia server" mode (isThirdPartyConfig:false +
    # amnezia-dns container + dns1=tunnel-gateway). This unlocks the
    # site-based split tunneling UI in the client.
    # dns1/dns2 are already derived from the .conf above (respecting manage modify);
    # here we only override them in adns=on mode — we must NOT clobber the .conf
    # values when adns=off.
    local amnezia_dns_flag="0"
    if [[ "${AWG_AMNEZIA_DNS:-off}" == "on" && -n "${AWG_TUNNEL_SUBNET:-}" ]]; then
        local _gw
        _gw=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
        if [[ -n "$_gw" ]]; then
            amnezia_dns_flag="1"
            dns1="$_gw"
            # dns2 stays public as a fallback — when the VPN is not up or
            # the client hasn't installed the route to $_gw yet.
            dns2="1.1.1.1"
        fi
    fi

    local vpn_uri perl_err
    perl_err=$(awg_mktemp "$AWG_DIR") || { log_warn "mktemp failed - vpn:// URI not created for '$name'."; return 1; }
    # Secrets (client privkey, PSK) are passed to perl via env, NOT via argv:
    # the process command line is visible to all users in /proc/<pid>/cmdline
    # while perl runs. server_pubkey is not a secret but travels with the group.
    # shellcheck disable=SC2016
    vpn_uri=$(AWG_URI_CPK="$client_privkey" AWG_URI_PSK="$client_psk" AWG_URI_SPK="$server_pubkey" \
      perl -MCompress::Zlib -MMIME::Base64 -e '
        my ($conf_path, $h1,$h2,$h3,$h4, $jc,$jmin,$jmax,
            $s1,$s2,$s3,$s4, $i1,$i2,$i3,$i4,$i5, $port, $ep, $cip, $cipv6, $aips,
            $mtu, $keepalive, $adns, $dns1, $dns2, $srvname) = @ARGV;
        my $cpk = $ENV{AWG_URI_CPK} // "";
        my $psk = $ENV{AWG_URI_PSK} // "";
        my $spk = $ENV{AWG_URI_SPK} // "";

        open my $fh, "<", $conf_path or die;
        local $/; my $raw = <$fh>; close $fh;
        chomp $raw;

        sub je {
            my $s = shift;
            $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g;
            $s =~ s/\n/\\n/g;  $s =~ s/\r/\\r/g;
            $s =~ s/\t/\\t/g;  return $s;
        }

        my $inner = "{";
        $inner .= qq("H1":"$h1","H2":"$h2","H3":"$h3","H4":"$h4",);
        $inner .= qq("Jc":"$jc","Jmin":"$jmin","Jmax":"$jmax",);
        $inner .= qq("S1":"$s1","S2":"$s2","S3":"$s3","S4":"$s4",);
        if ($i1 ne "" || $i2 ne "" || $i3 ne "" || $i4 ne "" || $i5 ne "") {
            my $ei1 = je($i1); my $ei2 = je($i2); my $ei3 = je($i3);
            my $ei4 = je($i4); my $ei5 = je($i5);
            $inner .= qq("I1":"$ei1","I2":"$ei2","I3":"$ei3","I4":"$ei4","I5":"$ei5",);
        }
        my $eraw = je($raw);
        my @ips = split(/,/, $aips);
        my $ips_json = join(",", map { qq("$_") } @ips);
        $inner .= qq("allowed_ips":[$ips_json],);
        $inner .= qq("client_ip":"$cip",);
        $cipv6 //= "";
        $inner .= qq("client_ipv6":"$cipv6",);
        $inner .= qq("client_priv_key":"$cpk",);
        if (defined $psk && $psk ne "") {
            my $epsk = je($psk);
            $inner .= qq("psk_key":"$epsk",);
        }
        $inner .= qq("config":"$eraw",);
        $inner .= qq("hostName":"$ep","mtu":"$mtu",);
        $inner .= qq("persistent_keep_alive":"$keepalive","port":$port,);
        $inner .= qq("server_pub_key":"$spk"});

        my $einner = je($inner);
        my $is_tpc = ($adns eq "1") ? "false" : "true";
        # Container: "amnezia-awg" maps in the Amnezia-Client classifier to
        # DockerContainer::Awg → label "AmneziaWG Legacy", site-based split
        # tunneling UI stays hidden. "amnezia-awg2" → DockerContainer::Awg2
        # → label "AmneziaWG (version 2)", the UI is unlocked. Both
        # containers share the same "awg" protocol key and last_config —
        # the only difference is labeling, and that the Legacy branch
        # disables the UI. We use amnezia-awg2 only in Amnezia mode (adns=1).
        my $cname = ($adns eq "1") ? "amnezia-awg2" : "amnezia-awg";
        my $containers = qq({"awg":{"isThirdPartyConfig":$is_tpc,"last_config":"$einner","port":"$port","protocol_version":"2","transport_proto":"udp"\},"container":"$cname"\});
        if ($adns eq "1") {
            # amnezia-dns container — signal to the client that this server
            # understands split tunneling. dns1 is handed in as the
            # tunnel-gateway IP.
            $containers .= qq(,{"dns":{},"container":"amnezia-dns"\});
        }
        my $outer = "{";
        $outer .= qq("containers":[$containers],);
        $outer .= qq("defaultContainer":"$cname",);
        my $esrv = je($srvname);
        $outer .= qq("description":"$esrv",);
        my $ed1 = je($dns1); my $ed2 = je($dns2);
        $outer .= qq("dns1":"$ed1","dns2":"$ed2",);
        $outer .= qq("hostName":"$ep"});

        my $compressed = compress($outer);
        my $payload = pack("N", length($outer)) . $compressed;
        my $b64 = encode_base64($payload, "");
        $b64 =~ tr|+/|-_|;
        $b64 =~ s/=+$//;
        print "vpn://" . $b64;
    ' "$conf_file" \
        "$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4" \
        "$AWG_Jc" "$AWG_Jmin" "$AWG_Jmax" \
        "$AWG_S1" "$AWG_S2" "$AWG_S3" "$AWG_S4" \
        "$AWG_I1" "${AWG_I2:-}" "${AWG_I3:-}" "${AWG_I4:-}" "${AWG_I5:-}" "$AWG_PORT" "$endpoint" \
        "$client_ip" "$client_ipv6" "$allowed_ips" \
        "$mtu" "$keepalive" "$amnezia_dns_flag" "$dns1" "$dns2" "${AWG_SERVER_NAME:-AWG Server}" 2>"$perl_err"
    )

    if [[ -z "$vpn_uri" ]]; then
        log_warn "Failed to generate vpn:// URI for '$name'."
        [[ -s "$perl_err" ]] && log_warn "Perl: $(cat "$perl_err")"
        rm -f "$perl_err"
        return 1
    fi
    rm -f "$perl_err"

    # Write via tmp + atomic mv (like .conf/.png) so an interrupted write never
    # leaves an empty/truncated .vpnuri on top of a working one.
    local _uri_tmp
    _uri_tmp=$(awg_mktemp "$AWG_DIR") || { log_error "mktemp error for vpn:// URI '$name'"; return 1; }
    printf '%s\n' "$vpn_uri" > "$_uri_tmp" || { rm -f "$_uri_tmp"; log_error "Error writing vpn:// URI for '$name'"; return 1; }
    chmod 600 "$_uri_tmp"
    if ! mv -f "$_uri_tmp" "$uri_file"; then
        rm -f "$_uri_tmp"
        log_error "Error saving vpn:// URI for '$name'"
        return 1
    fi
    log_debug "vpn:// URI for '$name' created: $uri_file"
    return 0
}

# Generate QR code from vpn:// URI (for one-tap import into Amnezia VPN app Android/iOS/Desktop)
# generate_qr_vpnuri <name>
#
# Writes via a temp file in the same directory + atomic mv so that on
# qrencode or chmod failure the user never sees a truncated `.vpnuri.png`:
# the previous version stays intact and the new one only appears whole.
generate_qr_vpnuri() {
    local name="$1"
    local uri_file="$AWG_DIR/${name}.vpnuri"
    local png_file="$AWG_DIR/${name}.vpnuri.png"
    local tmp_png

    if [[ ! -f "$uri_file" ]]; then
        log_error "vpn:// URI for '$name' not found: $uri_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode is not installed, vpn:// QR not created for '$name'."
        return 1
    fi

    # tmp via awg_mktemp (shared cleanup registry + atomic mv on the same FS).
    tmp_png=$(awg_mktemp "$AWG_DIR") || { log_error "mktemp error for vpn:// QR '$name'"; return 1; }

    # qrencode flags for long vpn:// URIs with PSK (issue #72):
    #   -8    single 8-bit byte mode. Without it qrencode's optimizer splits the
    #         base64 URI into alternating alnum/byte segments, and the mode-switch
    #         overhead inflates the stream past the v40-L capacity (2953 bytes).
    #         Large I1-I5/CPS configs failed with "Input data too large" even
    #         though the data itself is under the limit (URI ~2929 bytes < 2953)
    #         and fits in a single byte segment. Reporter: pqqsnupl (ntc.party).
    #   -s 6  module size of 6 pixels instead of the default 3 - this is the real fix.
    #         At the default scale modules were too small for the iPhone camera to
    #         distinguish when scanning the PNG off a computer screen, producing
    #         error 900 ImportInvalidConfigError in AmneziaVPN iOS for @haritos90
    #         in issue #72.
    #   -l L  lowest error correction level - this is already the qrencode default,
    #         pinned explicitly to guard against future default changes in libqrencode.
    #   -m 4  standard quiet zone of 4 modules - also the default, pinned explicitly.
    if ! qrencode -8 -t png -l L -s 6 -m 4 -o "$tmp_png" < "$uri_file"; then
        log_error "Failed to generate vpn:// QR for '$name' (config may be too large for a single QR - import the vpn:// from ${name}.vpnuri manually)."
        rm -f "$tmp_png"
        return 1
    fi

    if ! chmod 600 "$tmp_png"; then
        log_error "Failed to chmod 600 $tmp_png"
        rm -f "$tmp_png"
        return 1
    fi

    if ! mv -f "$tmp_png" "$png_file"; then
        log_error "Failed to save vpn:// QR for '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    log_debug "vpn:// QR for '$name' created: $png_file"
    return 0
}

# Removes partially created client artifacts (keys + .conf). Used by the
# early-error paths of generate_client - C10: do not leave orphan keys when a
# step fails before the peer is committed to the server config.
_rollback_client_artifacts() {
    rm -f "$KEYS_DIR/$1.private" "$KEYS_DIR/$1.public" "$AWG_DIR/$1.conf"
}

# Full set of client artifacts (conf/png/vpnuri/vpnuri.png + keys). A single
# list for `manage remove` and expired-client auto-removal so the paths do not
# diverge (expiry-cleanup used to forget .vpnuri.png). Does NOT touch the expiry
# marker or cron - the caller does that (remove_client_expiry / rm "$efile").
_remove_client_files() {
    local name="$1"
    rm -f "$AWG_DIR/${name}.conf" "$AWG_DIR/${name}.png" \
        "$AWG_DIR/${name}.vpnuri" "$AWG_DIR/${name}.vpnuri.png" \
        "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
}

# Full client creation cycle:
# keypair -> next IP -> client config -> add peer -> QR
# generate_client <name> [endpoint]
#
# Env var contract:
#   CLIENT_PSK — optional. If set to "auto", a fresh PSK is generated via
#     `awg genpsk` and written to both the server [Peer] and the client
#     [Peer]. If set to a concrete value (32-byte base64), it is used as
#     is without regenerating. Empty/unset — no PSK is added (default).
generate_client() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "generate_client: name not specified"
        return 1
    fi
    # Library contract (defense-in-depth): a name with metacharacters/newlines
    # would inject into paths and the server config heredoc. Same regex as
    # validate_client_name in manage and set_client_expiry here.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "generate_client: invalid client name '$name'"
        return 1
    fi

    # Load parameters
    load_awg_params || return 1

    # Optional PresharedKey: "auto" -> `awg genpsk`, otherwise use the
    # given value as-is. Empty/unset -> no PSK.
    if [[ "${CLIENT_PSK:-}" == "auto" ]]; then
        # --psk was requested explicitly: on awg genpsk failure do NOT silently
        # degrade to a PSK-less client (that would weaken the requested security).
        # Fail-closed; no artifacts exist yet (keys/config are created below), so
        # no rollback is needed.
        CLIENT_PSK=$(awg genpsk) || {
            log_error "awg genpsk failed - client with PresharedKey (--psk) NOT created. Please retry."
            return 1
        }
    fi

    # Inter-process lock: atomicity of IP allocation + peer addition
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 30 "$lock_fd"; then
        log_error "Failed to acquire config lock"
        exec {lock_fd}>&-
        return 1
    fi

    # C6: the client must not already exist. Check UNDER the lock, BEFORE
    # generating keys - otherwise `add <existing_name>` would silently overwrite
    # a live client's keys (generate_keypair overwrites unconditionally), and a
    # concurrent same-name add would race to overwrite.
    if [[ -e "$KEYS_DIR/${name}.private" || -e "$KEYS_DIR/${name}.public" || -e "$AWG_DIR/${name}.conf" ]]; then
        log_error "Client '$name' already exists. Use 'remove' or a different name."
        exec {lock_fd}>&-
        return 1
    fi

    # Generate keys. From here on, any early failure must remove the freshly
    # created keys/conf (C10) via _rollback_client_artifacts.
    generate_keypair "$name" || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Next free IP
    local client_ip
    client_ip=$(get_next_client_ip) || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # IPv6 address for client (when ALLOW_IPV6_TUNNEL=1)
    local client_ipv6=""
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" ]]; then
        client_ipv6=$(get_next_client_ipv6 "$client_ip") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
        log_debug "Allocated IPv6 address ${client_ipv6} for client ${name}"
    fi

    # Read keys
    local client_privkey client_pubkey server_pubkey
    client_privkey=$(cat "$KEYS_DIR/${name}.private") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
    client_pubkey=$(cat "$KEYS_DIR/${name}.public") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Try to reconstruct server_public.key from awg0.conf when the cache
    # is missing (supports manual setups without the installer step 6).
    _ensure_server_public_key || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Endpoint: argument → AWG_ENDPOINT (awgsetup_cfg.init) → curl to
    # external services → local IP on a network interface.
    # The last fallback targets LXC / egress-restricted setups: it may be a
    # NAT address, so we warn the user via the log.
    if [[ -z "$endpoint" ]]; then
        endpoint="${AWG_ENDPOINT:-}"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(get_server_public_ip)
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(_try_local_ip) && log_warn "Using local server IP as Endpoint ('$endpoint') — curl to external services did not go through. If the server is behind NAT, hand-edit the Endpoint in the client .conf files."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Failed to detect the server public IP. Set AWG_ENDPOINT in awgsetup_cfg.init (or reinstall with --endpoint=IP)."
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # The server port comes from the live awg0.conf (ListenPort), else from
    # awgsetup_cfg.init - both are hand-edited. render puts it into the
    # 'Endpoint = IP:PORT' line of the client .conf: a broken port is carried
    # onto the device and debugged blind. We refuse explicitly, just as
    # generate_vpn_uri does for the vpn:// URI. _rollback below removes the
    # artifacts.
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT is invalid ('${AWG_PORT:-}') - client config for '$name' was not created. Check ListenPort in $SERVER_CONF_FILE (or AWG_PORT in $CONFIG_FILE)."
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Client config
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6" || {
        log_error "Rollback: removing artifacts for '$name'"
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    }

    # Add peer to server config
    if ! add_peer_to_server "$name" "$client_pubkey" "$client_ip" "$client_ipv6"; then
        log_error "Rollback: removing artifacts for '$name'"
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Release lock — peer written, remaining operations are non-critical
    exec {lock_fd}>&-

    # QR code (optional, failure is non-fatal)
    if ! generate_qr "$name"; then
        log_warn "QR code not created. Config: $AWG_DIR/${name}.conf"
    fi

    # vpn:// URI and QR for Amnezia VPN app (optional).
    # QR vpn:// is attempted only if URI was generated successfully — no source otherwise.
    if ! generate_vpn_uri "$name"; then
        log_warn "vpn:// URI not created for '$name'."
    elif ! generate_qr_vpnuri "$name"; then
        log_warn "vpn:// QR not created for '$name'."
    fi

    log "Client '$name' created (IP: $client_ip)."
    return 0
}

# Regenerate config and QR for existing client
# regenerate_client <name> [endpoint]
#
# v5.11.0 A5.3: protected by .awg_config.lock (serializes with
# modify_client / remove and concurrent regens on the same client) and
# checks the return code of each sed -i that restores user settings —
# previously sed failures were silently ignored.
#
# Lock scope: held only while mutating $AWG_DIR/${name}.conf.
# generate_qr / generate_vpn_uri / generate_qr_vpnuri are called OUTSIDE
# the lock as best-effort derived artifacts — if a concurrent modify
# changes the conf between our sed and QR generation, the QR may be
# stale by one tick. A concurrent `manage remove <name>` may also delete
# the client after we release the lock, and regen will "resurrect"
# `.conf` / `.png` / `.vpnuri` / `.vpnuri.png` for an already-removed
# peer (stale artefacts in $AWG_DIR). Acceptable: the user gets correct
# state on the next operation (repeat `remove` or `regen`), and the
# peer is already out of the server config — no traffic flows through
# it. Including QR/URI in the lock is more expensive (holding the lock
# for several seconds) with no server-state integrity gain.
regenerate_client() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "regenerate_client: name not specified"
        return 1
    fi
    # Library contract (defense-in-depth): the name is interpolated into paths
    # and the config, so validate it right here instead of relying on the
    # caller (manage does its own validate_client_name, but cron / third-party
    # scripts do not).
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "regenerate_client: invalid client name '$name'"
        return 1
    fi

    # Cross-process lock: guards against races with modify_client/remove
    # and concurrent regens on the same client name.
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Failed to acquire config lock (another operation is running)"
        exec {lock_fd}>&-
        return 1
    fi

    load_awg_params || { exec {lock_fd}>&-; return 1; }

    # Check that client exists in server config
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Client '$name' not found in server config"
        exec {lock_fd}>&-
        return 1
    fi

    # Read client private key
    local client_privkey client_ip server_pubkey
    if [[ -f "$KEYS_DIR/${name}.private" ]]; then
        client_privkey=$(cat "$KEYS_DIR/${name}.private")
    elif [[ -f "$AWG_DIR/${name}.conf" ]]; then
        # Try to extract from existing config
        client_privkey=$(sed -n 's/^PrivateKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
    fi

    if [[ -z "$client_privkey" ]]; then
        log_error "Private key for client '$name' not found"
        exec {lock_fd}>&-
        return 1
    fi

    # Client IP from server config
    # Find [Peer] block with #_Name = name, then AllowedIPs
    # For dual-stack: ips[1] = IPv4/32, ips[2] = IPv6/128 (if present)
    local _regen_awk_out
    _regen_awk_out=$(awk -v target="$name" '
    /^\[Peer\]/ { in_peer=1; found=0; next }
    in_peer && $0 == "#_Name = " target { found=1; next }
    in_peer && found && /^AllowedIPs/ {
      sub(/^AllowedIPs[ \t]*=[ \t]*/, "")
      n = split($0, ips, /[ \t]*,[ \t]*/)
      sub(/\/[0-9]+$/, "", ips[1])
      gsub(/^[ \t]+|[ \t]+$/, "", ips[1])
      ipv4 = ips[1]
      ipv6 = ""
      if (n >= 2) {
        sub(/\/[0-9]+$/, "", ips[2])
        gsub(/^[ \t]+|[ \t]+$/, "", ips[2])
        ipv6 = ips[2]
      }
      print ipv4 " " ipv6
      exit
    }
    /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
    ' "$SERVER_CONF_FILE")

    client_ip="${_regen_awk_out%% *}"
    local client_ipv6="${_regen_awk_out#* }"
    # Defensive guard: awk always prints trailing space, so client_ipv6 is "" for IPv4-only.
    # This guard fires only if awk produces no trailing space (not expected in practice).
    if [[ "$client_ipv6" == "$client_ip" ]]; then
        client_ipv6=""
    fi

    # Only carry IPv6 forward if ALLOW_IPV6_TUNNEL is enabled
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" != "1" ]]; then
        client_ipv6=""
    fi

    if [[ -z "$client_ip" ]]; then
        log_error "Client IP for '$name' not found in server config"
        exec {lock_fd}>&-
        return 1
    fi

    # Auto-gen from awg0.conf if the cache is missing (manual setup)
    _ensure_server_public_key || { exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || {
        log_error "Server public key not found"
        exec {lock_fd}>&-
        return 1
    }

    # Endpoint chain: arg → AWG_ENDPOINT → curl → local IP (best-effort).
    if [[ -z "$endpoint" ]]; then
        endpoint="${AWG_ENDPOINT:-}"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(get_server_public_ip)
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(_try_local_ip) && log_warn "Using local server IP as Endpoint ('$endpoint') — curl to external services did not go through."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Failed to determine server public IP."
        exec {lock_fd}>&-
        return 1
    fi

    # Preserve user settings from current .conf (modified via modify command)
    local current_dns="1.1.1.1, 1.0.0.1" current_keepalive="33" current_allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
    if [[ -f "$AWG_DIR/${name}.conf" ]]; then
        local _v _raw
        # tr -d '[:space:]' stripped the spaces after commas here, so regen
        # wrote the collapsed list into .conf (D#38). Normalise, do not strip.
        #
        # The lines are JOINED rather than taking the first one: wg allows DNS
        # and AllowedIPs to repeat, and the values add up. The old `tr` glued
        # them into a plainly invalid CIDR and awg-quick refused to bring the
        # interface up LOUDLY; taking the first line would instead hand the user
        # a valid config with part of the networks silently gone.
        _raw=$(sed -n 's/^DNS[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf")
        _awg_warn_multiline "$_raw" "DNS" "$name"
        _v=$(awg_normalize_csv "$(printf '%s' "$_raw" | paste -sd, -)")
        [[ -n "$_v" ]] && current_dns="$_v"
        _v=$(sed -n 's/^PersistentKeepalive[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_keepalive="$_v"
        _raw=$(sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf")
        _awg_warn_multiline "$_raw" "AllowedIPs" "$name"
        _v=$(awg_normalize_csv "$(printf '%s' "$_raw" | paste -sd, -)")
        [[ -n "$_v" ]] && current_allowed_ips="$_v"
        # v5.11.1: preserve PresharedKey through regen. Without this,
        # clients added with `manage add --psk` would lose their PSK on
        # regen — the server peer still holds the PSK but the client
        # conf would drop it, breaking the handshake. CLIENT_PSK is
        # passed through to render_client_config.
        local _psk
        _psk=$(sed -n '/^\[Peer\]/,$ s/^PresharedKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        if [[ -n "$_psk" ]]; then
            export CLIENT_PSK="$_psk"
        else
            unset CLIENT_PSK
        fi
    else
        # The client .conf is lost (regen as recovery): restore the
        # PresharedKey from the server [Peer] block, otherwise the recreated
        # config would come out without a PSK while the server still has one -
        # the handshake silently breaks. We control the field order in the
        # block (add_peer_to_server writes #_Name first), so found-then-PSK
        # is sufficient.
        local _psk
        _psk=$(awk -v target="$name" '
            /^\[Peer\]/ { in_peer=1; found=0; next }
            in_peer && $0 == "#_Name = " target { found=1; next }
            in_peer && found && /^PresharedKey[ \t]*=/ {
                sub(/^PresharedKey[ \t]*=[ \t]*/, ""); sub(/\r$/, ""); print; exit
            }
            /^\[/ && !/^\[Peer\]/ { in_peer=0; found=0 }
        ' "$SERVER_CONF_FILE" 2>/dev/null | tr -d '[:space:]')
        if [[ -n "$_psk" ]]; then
            export CLIENT_PSK="$_psk"
        else
            unset CLIENT_PSK
        fi
    fi

    # Same port guard as generate_client: a broken AWG_PORT must not reach the
    # Endpoint of the regenerated .conf.
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT is invalid ('${AWG_PORT:-}') - config for '$name' was not regenerated. Check ListenPort in $SERVER_CONF_FILE (or AWG_PORT in $CONFIG_FILE)."
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi

    # AmneziaDNS mode forces a hard-coded client AllowedIPs "0.0.0.0/0, ::/0"
    # (required by the Amnezia-Client per-site routing UI gate — see
    # render_client_config). A "preserved" old value from the previous .conf
    # would just re-lock the gate on the first regen/modify call. DNS is
    # similarly forced to the tunnel-gateway IP rather than 1.1.1.1.
    if [[ "${AWG_AMNEZIA_DNS:-off}" == "on" ]]; then
        current_allowed_ips="0.0.0.0/0, ::/0"
        if [[ -n "${AWG_TUNNEL_SUBNET:-}" ]]; then
            current_dns=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
        fi
    fi

    # Config regeneration (pass client_ipv6 if dual-stack)
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6" || {
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }

    # On regen, pull in the new defaults for non-customized clients: a
    # full-tunnel 0.0.0.0/0 gets ::/0 (needed by iOS AmneziaVPN), a single DNS
    # 1.1.1.1 becomes a pair with a fallback. Values set by the user via modify
    # differ from the old defaults and are therefore kept as-is.
    [[ "$current_allowed_ips" == "0.0.0.0/0" ]] && current_allowed_ips="0.0.0.0/0, ::/0"
    [[ "$current_dns" == "1.1.1.1" ]] && current_dns="1.1.1.1, 1.0.0.1"

    # Restore user settings (escape & and \ for sed replacement)
    local _dns _ka _aip
    _dns=$(printf '%s' "$current_dns" | sed 's/[&\\/]/\\&/g')
    _ka=$(printf '%s' "$current_keepalive" | sed 's/[&\\/]/\\&/g')
    _aip=$(printf '%s' "$current_allowed_ips" | sed 's/[&\\/]/\\&/g')
    local _client_conf="$AWG_DIR/${name}.conf"
    if ! sed -i "s/^DNS = .*/DNS = ${_dns}/" "$_client_conf"; then
        log_error "sed error writing DNS to $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    if ! sed -i "s/^PersistentKeepalive = .*/PersistentKeepalive = ${_ka}/" "$_client_conf"; then
        log_error "sed error writing PersistentKeepalive to $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    # Delimiter '/' (not '|'): the escaping class above covers & \ / - a '|'
    # character in the value would break a sed expression using the '|' delimiter.
    # regen --reset-routes (Issue #170): do NOT restore the client's old
    # AllowedIPs - keep the value from render_client_config, computed from the
    # global routing mode (awgsetup_cfg.init) with correct IPv6 mirroring.
    # A regular regen still preserves per-client customizations.
    if [[ "${AWG_REGEN_RESET_ROUTES:-0}" == "1" ]]; then
        log "AllowedIPs of client '$name' reset to the global routing mode (--reset-routes)."
    elif ! sed -i "s/^AllowedIPs = .*/AllowedIPs = ${_aip}/" "$_client_conf"; then
        log_error "sed error writing AllowedIPs to $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi

    # Release lock — config written, remaining ops are non-critical
    exec {lock_fd}>&-

    # QR code
    generate_qr "$name"

    # vpn:// URI and QR for Amnezia VPN app (best-effort).
    # QR vpn:// is attempted only if URI was regenerated successfully.
    if generate_vpn_uri "$name"; then
        generate_qr_vpnuri "$name" || log_warn "vpn:// QR not updated for '$name'."
    else
        log_warn "vpn:// URI not updated for '$name'."
    fi

    # Hygiene: do not let PSK leak into later operations in the same shell
    unset CLIENT_PSK

    log "Client config for '$name' regenerated."
    return 0
}

# ==============================================================================
# Validation
# ==============================================================================

_validate_server_wg_keys() {
    local config_path="$1" server_priv kind value
    if ! awk '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[/ {
            line=$0; gsub(/[[:space:]]/, "", line)
            if (line == "[Interface]") { section="I"; interfaces++; next }
            if (line == "[Peer]") { section="P"; peer++; next }
            section="X"; next
        }
        index($0, "=") {
            key=$0; sub(/=.*/, "", key); gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
            if (section == "I" && key == "PrivateKey") interface_private++
            if (section == "P" && key == "PublicKey") peer_public[peer]++
            if (section == "P" && key == "PresharedKey") peer_psk[peer]++
        }
        END {
            if (interfaces != 1 || interface_private != 1) exit 20
            for (i=1; i<=peer; i++) if (peer_public[i] != 1 || peer_psk[i] > 1) exit 21
        }
    ' "$config_path"; then
        log_error "Invalid WG key structure: one Interface PrivateKey and exactly one PublicKey per Peer are required"
        return 1
    fi
    server_priv=$(_extract_upstream_field "$config_path" Interface PrivateKey) || server_priv=""
    _valid_wg_key_b64 "$server_priv" \
        || { log_error "Invalid Interface PrivateKey"; return 1; }
    while IFS=$'\t' read -r kind value; do
        [[ -n "$kind" ]] || continue
        if ! _valid_wg_key_b64 "$value"; then
            log_error "Invalid Peer ${kind}"
            return 1
        fi
    done < <(awk '
        /^[[:space:]]*\[/ {
            line=$0; gsub(/[[:space:]]/, "", line); inpeer=(line == "[Peer]"); next
        }
        inpeer && /^[[:space:]]*(PublicKey|PresharedKey)[[:space:]]*=/ {
            key=$0; sub(/[[:space:]]*=.*/, "", key); gsub(/[[:space:]]/, "", key)
            value=$0; sub(/^[^=]*=[[:space:]]*/, "", value); sub(/[[:space:]]+$/, "", value)
            print key "\t" value
        }
    ' "$config_path")
}

# Validate AWG 2.0 server config
validate_awg_config() {
    local config_path="${1:-$SERVER_CONF_FILE}"
    if [[ ! -f "$config_path" ]]; then
        log_error "Server config not found: $config_path"
        return 1
    fi
    _validate_server_wg_keys "$config_path" || return 1

    local ok=1
    local param val
    local int_params=("Jc" "Jmin" "Jmax" "S1" "S2" "S3" "S4")
    local range_params=("H1" "H2" "H3" "H4")

    # Parsing aligned with load_awg_params_from_server_conf: arbitrary spaces
    # around '=', last-wins for duplicate lines (validate the value that will
    # actually load), trim spaces/CR. Previously the validator required exactly
    # one space and took first-wins - a hand-edited 'Jc=4' loaded fine but
    # failed validation with a bogus "parameter not found".
    for param in "${int_params[@]}"; do
        val=$(_extract_upstream_field "$config_path" Interface "$param") || val=""
        if [[ -z "$val" ]]; then
            log_error "Parameter '$param' not found in server config"
            ok=0
        elif ! [[ "$val" =~ ^[0-9]{1,10}$ ]]; then
            log_error "Parameter '$param' has invalid value: '$val' (expected integer)"
            ok=0
        fi
    done

    # Protocol boundary checks (defense-in-depth for restored backups)
    local jc jmin jmax s1 s2 s3 s4
    jc=$(_extract_upstream_field "$config_path" Interface Jc) || jc=""
    jmin=$(_extract_upstream_field "$config_path" Interface Jmin) || jmin=""
    jmax=$(_extract_upstream_field "$config_path" Interface Jmax) || jmax=""
    s1=$(_extract_upstream_field "$config_path" Interface S1) || s1=""
    s2=$(_extract_upstream_field "$config_path" Interface S2) || s2=""
    s3=$(_extract_upstream_field "$config_path" Interface S3) || s3=""
    s4=$(_extract_upstream_field "$config_path" Interface S4) || s4=""
    if [[ "$jc" =~ ^[0-9]{1,10}$ ]]; then
        if ! _valid_awg_decimal "$jc" 1 128; then
            log_error "Jc=$jc is out of range (1-128)"
            ok=0
        fi
    fi
    if [[ "$jmin" =~ ^[0-9]{1,10}$ && "$jmax" =~ ^[0-9]{1,10}$ ]]; then
        if ! _valid_awg_decimal "$jmin" 0 1280; then
            log_error "Jmin=$jmin exceeds 1280"
            ok=0
        fi
        if ! _valid_awg_decimal "$jmax" 0 1280; then
            log_error "Jmax=$jmax exceeds 1280"
            ok=0
        fi
        if _valid_awg_decimal "$jmin" 0 1280 && _valid_awg_decimal "$jmax" 0 1280 \
            && (( 10#$jmax < 10#$jmin )); then
            log_error "Jmax ($jmax) is less than Jmin ($jmin)"
            ok=0
        fi
    fi
    if [[ "$s3" =~ ^[0-9]{1,10}$ ]] && ! _valid_awg_decimal "$s3" 0 64; then
        log_error "S3=$s3 exceeds maximum (64)"
        ok=0
    fi
    if [[ "$s1" =~ ^[0-9]{1,10}$ ]] && ! _valid_awg_decimal "$s1" 0 65535; then
        log_error "S1=$s1 exceeds uint16"
        ok=0
    fi
    if [[ "$s2" =~ ^[0-9]{1,10}$ ]] && ! _valid_awg_decimal "$s2" 0 65535; then
        log_error "S2=$s2 exceeds uint16"
        ok=0
    fi
    if [[ "$s4" =~ ^[0-9]{1,10}$ ]] && ! _valid_awg_decimal "$s4" 0 32; then
        log_error "S4=$s4 exceeds maximum (32)"
        ok=0
    fi

    local _h_ranges=()
    for param in "${range_params[@]}"; do
        val=$(_extract_upstream_field "$config_path" Interface "$param") || val=""
        if [[ -z "$val" ]]; then
            log_error "Parameter '$param' not found in server config"
            ok=0
        elif ! _valid_awg_h_range "$val"; then
            log_error "Parameter '$param' has invalid value: '$val' (expected MIN-MAX format)"
            ok=0
        else
            local range_lo="${val%-*}" range_hi="${val#*-}"
            _h_ranges+=("$((10#$range_lo)) $((10#$range_hi)) $param")
        fi
    done

    # Pairwise non-overlap of H1-H4 is a key AWG 2.0 invariant. Without this
    # check a config from a foreign backup with overlapping ranges passed
    # validation even though the protocol does not allow it.
    if [[ ${#_h_ranges[@]} -eq 4 ]]; then
        local _i _j _lo1 _hi1 _n1 _lo2 _hi2 _n2
        for ((_i = 0; _i < 4; _i++)); do
            for ((_j = _i + 1; _j < 4; _j++)); do
                read -r _lo1 _hi1 _n1 <<< "${_h_ranges[$_i]}"
                read -r _lo2 _hi2 _n2 <<< "${_h_ranges[$_j]}"
                if (( _lo1 <= _hi2 && _lo2 <= _hi1 )); then
                    log_error "Ranges ${_n1} (${_lo1}-${_hi1}) and ${_n2} (${_lo2}-${_hi2}) overlap"
                    ok=0
                fi
            done
        done
    fi

    # I1 is optional. Absent = either not set, or intentionally disabled via
    # --no-cps (issue #159): the desktop AmneziaVPN on macOS does not support CPS.
    if ! grep -qE '^[[:space:]]*I1[[:space:]]*=' "$config_path"; then
        if grep -qE '^[[:space:]]*(export[[:space:]]+)?NO_CPS=1' "$CONFIG_FILE" 2>/dev/null; then
            log "I1 (CPS) intentionally disabled (--no-cps) - expected for the desktop AmneziaVPN on macOS"
        else
            log_warn "Parameter I1 (CPS) not found - CPS concealment is not active"
        fi
    fi

    if [[ $ok -eq 1 ]]; then
        log "AWG 2.0 config validation: OK"
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Client expiry
# ==============================================================================

EXPIRY_DIR="${AWG_DIR}/expiry"
EXPIRY_CRON="${EXPIRY_CRON:-/etc/cron.d/awg-expiry}"

# Parse duration string to seconds: 1h, 12h, 1d, 7d, 30d
# parse_duration <duration_string>
parse_duration() {
    local input="$1"
    local num unit
    if [[ "$input" =~ ^([0-9]+)([hdw])$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        log_error "Invalid duration format: '$input'. Use: 1h, 12h, 1d, 7d, 4w"
        return 1
    fi
    case "$unit" in
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        w) echo $((num * 604800)) ;; # 7 days
        *) return 1 ;;
    esac
}

# Set client expiry
# set_client_expiry <name> <duration>
set_client_expiry() {
    local name="$1"
    local duration="$2"
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Invalid client name: '$name'"
        return 1
    fi
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Client '$name' not found."
        return 1
    fi
    local seconds
    seconds=$(parse_duration "$duration") || return 1
    local now
    now=$(date +%s)
    local expires_at=$((now + seconds))

    mkdir -p "$EXPIRY_DIR" || {
        log_error "Failed to create $EXPIRY_DIR"
        return 1
    }
    echo "$expires_at" > "$EXPIRY_DIR/$name" || {
        log_error "Failed to write expiry for '$name'"
        return 1
    }
    chmod 600 "$EXPIRY_DIR/$name"
    local expires_date
    expires_date=$(date -d "@$expires_at" '+%F %T' 2>/dev/null || echo "$expires_at")
    log "Expiry for '$name': $expires_date ($duration)"
    return 0
}

# Get client expiry (unix timestamp or empty)
# get_client_expiry <name>
get_client_expiry() {
    local name="$1"
    local efile="$EXPIRY_DIR/$name"
    if [[ -f "$efile" ]]; then
        cat "$efile"
    fi
}

# Format remaining time
# format_remaining <expires_at_timestamp>
format_remaining() {
    local expires_at="$1"
    local now
    now=$(date +%s)
    local diff=$((expires_at - now))
    if [[ $diff -le 0 ]]; then
        local ago=$(( (-diff) / 3600 ))
        if [[ $ago -ge 24 ]]; then
            echo "expired $(( ago / 24 ))d ago"
        elif [[ $ago -ge 1 ]]; then
            echo "expired ${ago}h ago"
        else
            local ago_mins=$(( (-diff) / 60 ))
            if [[ $ago_mins -ge 1 ]]; then
                echo "expired ${ago_mins}m ago"
            else
                echo "just expired"
            fi
        fi
        return 0
    fi
    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    if [[ $days -gt 0 ]]; then
        echo "${days}d ${hours}h"
    else
        local mins=$(( (diff % 3600) / 60 ))
        echo "${hours}h ${mins}m"
    fi
}

# Check and remove expired clients
check_expired_clients() {
    if [[ ! -d "$EXPIRY_DIR" ]]; then return 0; fi

    local removed=0
    local efile
    for efile in "$EXPIRY_DIR"/*; do
        [[ -f "$efile" ]] || continue
        local name
        name=$(basename "$efile")
        # Name validation: same regex as validate_client_name in manage_amneziawg.sh.
        # Defense-in-depth — EXPIRY_DIR is root-only, but protection against an
        # accidentally placed invalid file (or symlink attack if expiry_dir
        # ever becomes shared) is needed before using $name in paths and
        # passing it to remove_peer_from_server (self-audit).
        if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_warn "Skipping invalid expiry file: '$name'"
            continue
        fi
        local expires_at
        expires_at=$(cat "$efile" 2>/dev/null)
        if [[ -z "$expires_at" || ! "$expires_at" =~ ^[0-9]+$ ]]; then
            log_warn "Malformed expiry data for '$name': '$(head -c 50 "$efile" 2>/dev/null)'"
            continue
        fi

        local now
        now=$(date +%s)
        if [[ $now -ge $expires_at ]]; then
            log "Client '$name' expired. Removing..."
            if [[ -r "$SERVER_CONF_FILE" ]] && ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
                # Orphan marker: the peer is already gone from the config
                # (removed manually, via awg, or by restoring an old backup).
                # Without this branch cron would forever retry
                # remove_peer_from_server every 5 minutes, piling warns into
                # expiry.log, and the client artifacts would never be cleaned.
                # The [[ -r ]] guard: a temporarily missing/unreadable config
                # (mid-restore, fs failure) is NOT a reason to wipe client
                # artifacts - that case falls through to the warn branch and
                # is retried later.
                _remove_client_files "$name"
                remove_client_expiry "$name"
                log "Client '$name': peer is absent from the config - cleaned up orphaned artifacts and the expiry marker."
            elif remove_peer_from_server "$name" 2>/dev/null; then
                _remove_client_files "$name"
                remove_client_expiry "$name"
                log "Client '$name' removed (expired)."
                ((removed++))
            else
                log_warn "Failed to remove expired client '$name'."
            fi
        fi
    done

    if [[ $removed -gt 0 ]]; then
        log "Expired clients removed: $removed. Applying config..."
        if ! apply_config; then
            log_error "apply_config failed after removing expired clients. Peers removed from config and expiry/, but may still be present on live interface. Manual restart required: systemctl restart awg-quick@awg0"
            return 1
        fi
    fi
    return 0
}

# Install cron job for auto-removal
install_expiry_cron() {
    # Idempotent by CONTENT, not by file existence. The old early-out on "file
    # exists" left stale paths after restore/migration/--conf-dir: the cron kept
    # pointing at the old AWG_DIR. Generate the expected text and replace the file
    # only when it differs.
    local _cron_tmp
    _cron_tmp=$(awg_mktemp "$(dirname "$EXPIRY_CRON")") || { log_error "mktemp error for expiry cron"; return 1; }
    # Check the write succeeded BEFORE cmp/mv: otherwise a failure (disk/perms)
    # could atomically replace a working cron with an empty/partial tmp.
    if ! cat > "$_cron_tmp" << CRONEOF
# AmneziaWG client expiry check - every 5 minutes
AWG_DIR="${AWG_DIR}"
CONFIG_FILE="${CONFIG_FILE}"
SERVER_CONF_FILE="${SERVER_CONF_FILE}"
*/5 * * * * root /bin/bash -c 'source "${AWG_DIR}/awg_common.sh" || exit 1; trap _awg_cleanup EXIT; check_expired_clients' >> "${AWG_DIR}/expiry.log" 2>&1
CRONEOF
    then
        rm -f "$_cron_tmp"
        log_error "Error writing expiry cron job"
        return 1
    fi
    if [[ -f "$EXPIRY_CRON" ]] && cmp -s "$_cron_tmp" "$EXPIRY_CRON"; then
        rm -f "$_cron_tmp"
        log_debug "Expiry cron job already current."
        return 0
    fi
    chmod 644 "$_cron_tmp"
    if ! mv -f "$_cron_tmp" "$EXPIRY_CRON"; then
        rm -f "$_cron_tmp"
        log_error "Error installing expiry cron job: $EXPIRY_CRON"
        return 1
    fi
    log "Expiry cron job installed/updated: $EXPIRY_CRON"
}

# Remove client expiry data
remove_client_expiry() {
    local name="$1"
    rm -f "$EXPIRY_DIR/$name" 2>/dev/null
    # Remove cron if no more clients with expiry
    if [[ -d "$EXPIRY_DIR" ]] && [[ -z "$(ls -A "$EXPIRY_DIR" 2>/dev/null)" ]]; then
        rm -f "$EXPIRY_CRON" 2>/dev/null
        log_debug "Expiry cron job removed (no clients with expiry)."
    fi
}
