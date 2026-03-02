#!/bin/bash

# Minimum Bash version check
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ERROR: Bash >= 4.0 required (current: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# AmneziaWG 2.0 peer management script
# Author: @bivlked
# Version: 5.2
# Date: 2026-03-03
# Repository: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Safe mode and Constants ---
set -o pipefail
AWG_DIR="/root/awg"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"
NO_COLOR=0
VERBOSE_LIST=0

# --- Argument handling ---
COMMAND=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)         COMMAND="help"; break ;;
        -v|--verbose)      VERBOSE_LIST=1; shift ;;
        --no-color)        NO_COLOR=1; shift ;;
        --conf-dir=*)      AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*)   SERVER_CONF_FILE="${1#*=}"; shift ;;
        --*)               echo "Unknown option: $1" >&2; COMMAND="help"; break ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND=$1
            else
                ARGS+=("$1")
            fi
            shift ;;
    esac
done
ARGS+=("$@")
CLIENT_NAME="${ARGS[0]}"
PARAM="${ARGS[1]}"
VALUE="${ARGS[2]}"

# Update paths after possible --conf-dir override
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

# ==============================================================================
# Logging functions
# ==============================================================================

log_msg() {
    local type="$1" msg="$2"
    local ts
    ts=$(date +'%F %T')
    local safe_msg
    safe_msg=$(echo "$msg" | sed 's/%/%%/g')
    local entry="[$ts] $type: $safe_msg"
    local color_start="" color_end="\033[0m"

    if [[ "$NO_COLOR" -eq 0 ]]; then
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

    if [[ "$type" == "ERROR" ]]; then
        printf "${color_start}%s${color_end}\n" "$entry" >&2
    else
        printf "${color_start}%s${color_end}\n" "$entry"
    fi
}

log()       { log_msg "INFO" "$1"; }
log_warn()  { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
log_debug() { if [[ "$VERBOSE_LIST" -eq 1 ]]; then log_msg "DEBUG" "$1"; fi; }
die()       { log_error "$1"; exit 1; }

# ==============================================================================
# Utilities
# ==============================================================================

is_interactive() { [[ -t 0 && -t 1 ]]; }

# Escape special characters for sed (prevents command injection)
escape_sed() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//&/\\&}"
    s="${s//#/\\#}"
    s="${s////\\/}"
    printf '%s' "$s"
}

confirm_action() {
    if ! is_interactive; then return 0; fi
    local action="$1" subject="$2"
    read -p "Are you sure you want to $action $subject? [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    else
        log "Action cancelled."
        return 1
    fi
}

validate_client_name() {
    local name="$1"
    if [[ -z "$name" ]]; then log_error "Name is empty."; return 1; fi
    if [[ ${#name} -gt 63 ]]; then log_error "Name exceeds 63 chars."; return 1; fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Name contains invalid characters."; return 1; fi
    return 0
}

# ==============================================================================
# Dependency check
# ==============================================================================

check_dependencies() {
    log "Checking dependencies..."
    local ok=1

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Not found: $CONFIG_FILE"
        ok=0
    fi
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        log_error "Not found: $COMMON_SCRIPT_PATH"
        ok=0
    fi
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Not found: $SERVER_CONF_FILE"
        ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        die "Installation files not found. Run install_amneziawg.sh."
    fi

    if ! command -v awg &>/dev/null; then die "'awg' not found."; fi
    if ! command -v qrencode &>/dev/null; then log_warn "qrencode not found (QR codes will not be created)."; fi

    # Load common library
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH" || die "Failed to load $COMMON_SCRIPT_PATH"

    log "Dependencies OK."
}

# ==============================================================================
# Backup
# ==============================================================================

backup_configs() {
    log "Creating backup..."
    local bd="$AWG_DIR/backups"
    mkdir -p "$bd" || die "mkdir error $bd"
    local ts bf td
    ts=$(date +%F_%T)
    bf="$bd/awg_backup_${ts}.tar.gz"
    td=$(mktemp -d)

    mkdir -p "$td/server" "$td/clients" "$td/keys"
    cp -a "$SERVER_CONF_FILE"* "$td/server/" 2>/dev/null
    cp -a "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$CONFIG_FILE" "$td/clients/" 2>/dev/null || true
    cp -a "$KEYS_DIR"/* "$td/keys/" 2>/dev/null || true
    cp -a "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" "$td/" 2>/dev/null || true

    tar -czf "$bf" -C "$td" . || { rm -rf "$td"; die "tar error $bf"; }
    rm -rf "$td"
    chmod 600 "$bf" || log_warn "chmod error on backup"

    # Keep maximum 10 backups
    find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" -printf '%T@ %p\n' | \
        sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f || \
        log_warn "Error deleting old backups"

    log "Backup created: $bf"
}

restore_backup() {
    local bf="$1"
    local bd="$AWG_DIR/backups"

    if [[ -z "$bf" ]]; then
        if [[ ! -d "$bd" ]] || [[ -z "$(ls -A "$bd" 2>/dev/null)" ]]; then
            die "No backups found in $bd."
        fi
        local backups
        backups=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | sort -r)
        if [[ -z "$backups" ]]; then die "No backups found."; fi

        echo "Available backups:"
        local i=1
        local bl=()
        while IFS= read -r f; do
            echo "  $i) $(basename "$f")"
            bl[$i]="$f"
            ((i++))
        done <<< "$backups"

        read -p "Number to restore (0-cancel): " choice < /dev/tty
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -eq 0 ]] || [[ "$choice" -ge "$i" ]]; then
            log "Cancelled."
            return 1
        fi
        bf="${bl[$choice]}"
    fi

    if [[ ! -f "$bf" ]]; then die "Backup file '$bf' not found."; fi
    log "Restoring from $bf"
    if ! confirm_action "restore" "configuration from '$bf'"; then return 1; fi

    log "Backing up current config..."
    backup_configs

    local td
    td=$(mktemp -d)
    if ! tar -xzf "$bf" -C "$td"; then
        log_error "tar error $bf"
        rm -rf "$td"
        return 1
    fi

    log "Stopping service..."
    systemctl stop awg-quick@awg0 || log_warn "Service not stopped."

    if [[ -d "$td/server" ]]; then
        log "Restoring server config..."
        local server_conf_dir
        server_conf_dir=$(dirname "$SERVER_CONF_FILE")
        mkdir -p "$server_conf_dir"
        cp -a "$td/server/"* "$server_conf_dir/" || log_error "Error copying server"
        chmod 600 "$server_conf_dir"/*.conf 2>/dev/null
        chmod 700 "$server_conf_dir"
    fi

    if [[ -d "$td/clients" ]]; then
        log "Restoring client files..."
        cp -a "$td/clients/"* "$AWG_DIR/" || log_error "Error copying clients"
        chmod 600 "$AWG_DIR"/*.conf 2>/dev/null
        chmod 600 "$CONFIG_FILE" 2>/dev/null
    fi

    if [[ -d "$td/keys" ]]; then
        log "Restoring keys..."
        mkdir -p "$KEYS_DIR"
        cp -a "$td/keys/"* "$KEYS_DIR/" || log_error "Error copying keys"
        chmod 600 "$KEYS_DIR"/* 2>/dev/null
    fi

    # Server keys
    [[ -f "$td/server_private.key" ]] && cp -a "$td/server_private.key" "$AWG_DIR/"
    [[ -f "$td/server_public.key" ]] && cp -a "$td/server_public.key" "$AWG_DIR/"

    rm -rf "$td"

    log "Starting service..."
    if ! systemctl start awg-quick@awg0; then
        log_error "Service start error!"
        local status_out
        status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
        while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
        return 1
    fi
    log "Restore completed."
}

# ==============================================================================
# Modify client parameter
# ==============================================================================

modify_client() {
    local name="$1" param="$2" value="$3"

    if [[ -z "$name" || -z "$param" || -z "$value" ]]; then
        log_error "Usage: modify <name> <param> <value>"
        return 1
    fi

    # Parameters allowed for modification
    local allowed_params="DNS|Endpoint|AllowedIPs|Address|PersistentKeepalive|MTU"
    if ! [[ "$param" =~ ^($allowed_params)$ ]]; then
        log_error "Parameter '$param' cannot be changed via modify."
        log_error "Allowed parameters: ${allowed_params//|/, }"
        return 1
    fi

    if ! grep -q "^#_Name = ${name}$" "$SERVER_CONF_FILE"; then
        die "Client '$name' not found."
    fi

    local cf="$AWG_DIR/$name.conf"
    if [[ ! -f "$cf" ]]; then die "File $cf not found."; fi

    if ! grep -q -E "^${param}\s*=" "$cf"; then
        log_error "Parameter '$param' not found in $cf."
        return 1
    fi

    log "Changing '$param' to '$value' for '$name'..."
    local bak
    bak="${cf}.bak-$(date +%F_%T)"
    cp "$cf" "$bak" || log_warn "Backup error $bak"
    log "Backup: $bak"

    local escaped_value
    escaped_value=$(escape_sed "$value")
    if ! sed -i "s#^${param} = .*#${param} = ${escaped_value}#" "$cf"; then
        log_error "sed error. Restoring..."
        cp "$bak" "$cf" || log_warn "Restore error."
        return 1
    fi

    log "Parameter '$param' changed."

    # Regenerate QR for important parameters
    if [[ "$param" =~ ^(AllowedIPs|Address|PublicKey|Endpoint|PrivateKey|DNS)$ ]]; then
        log "Regenerating QR code..."
        generate_qr "$name" || log_warn "Failed to update QR code."
    fi

    return 0
}

# ==============================================================================
# Server status check
# ==============================================================================

check_server() {
    log "Checking AmneziaWG 2.0 server status..."
    local ok=1

    log "Service status:"
    if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi

    log "Interface awg0:"
    if ! ip addr show awg0 &>/dev/null; then
        log_error " - Interface not found!"
        ok=0
    else
        while IFS= read -r line; do log "  $line"; done < <(ip addr show awg0)
    fi

    log "Port listening:"
    # shellcheck source=/dev/null
    source "$CONFIG_FILE" 2>/dev/null
    local port=${AWG_PORT:-0}
    if [[ "$port" -eq 0 ]]; then
        log_warn " - Failed to determine port."
    else
        if ! ss -lunp | grep -q ":${port} "; then
            log_error " - Port ${port}/udp is NOT listening!"
            ok=0
        else
            log " - Port ${port}/udp is listening."
        fi
    fi

    log "Kernel settings:"
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$fwd" != "1" ]]; then
        log_error " - IP Forwarding is disabled ($fwd)!"
        ok=0
    else
        log " - IP Forwarding is enabled."
    fi

    log "UFW rules:"
    if command -v ufw &>/dev/null; then
        if ! ufw status | grep -qw "${port}/udp"; then
            log_warn " - UFW rule for ${port}/udp not found!"
        else
            log " - UFW rule for ${port}/udp is present."
        fi
    else
        log_warn " - UFW is not installed."
    fi

    log "AmneziaWG 2.0 status:"
    while IFS= read -r line; do log "  $line"; done < <(awg show)

    # AWG 2.0 diagnostics
    if awg show awg0 2>/dev/null | grep -q "jc:"; then
        log " - AWG 2.0 obfuscation parameters: active"
    else
        log_warn " - AWG 2.0 obfuscation parameters not detected"
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Check completed: Status OK."
        return 0
    else
        log_error "Check completed: ISSUES FOUND!"
        return 1
    fi
}

# ==============================================================================
# Client list
# ==============================================================================

list_clients() {
    log "Getting client list..."
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        log "No clients found."
        return 0
    fi

    local verbose=$VERBOSE_LIST
    local awg_stat act=0 tot=0
    awg_stat=$(awg show 2>/dev/null) || awg_stat=""

    if [[ $verbose -eq 1 ]]; then
        printf "%-20s | %-7s | %-7s | %-15s | %-15s | %s\n" "Client name" "Conf" "QR" "IP address" "Key (start)" "Status"
        printf -- "-%.0s" {1..85}
        echo
    else
        printf "%-20s | %-7s | %-7s | %s\n" "Client name" "Conf" "QR" "Status"
        printf -- "-%.0s" {1..50}
        echo
    fi

    while IFS= read -r name; do
        name=$(echo "$name" | xargs)
        if [[ -z "$name" ]]; then continue; fi
        ((tot++))

        local cf="?" png="?" pk="-" ip="-" st="No data"
        local color_start="\033[0m" color_end="\033[0m"
        if [[ "$NO_COLOR" -eq 0 ]]; then color_start="\033[0;37m"; fi

        [[ -f "$AWG_DIR/${name}.conf" ]] && cf="+"
        [[ -f "$AWG_DIR/${name}.png" ]] && png="+"

        if [[ "$cf" == "+" ]]; then
            ip=$(grep -oP 'Address = \K[0-9.]+' "$AWG_DIR/${name}.conf" 2>/dev/null) || ip="?"

            # Extract public key from server config
            local current_pk=""
            local peer_block_started=0
            while IFS= read -r line || [[ -n "$line" ]]; do
                if [[ "$line" == "[Peer]"* && "$peer_block_started" -eq 1 ]]; then break; fi
                if [[ "$line" == "#_Name = ${name}" ]]; then peer_block_started=1; fi
                if [[ "$peer_block_started" -eq 1 && "$line" == "PublicKey = "* ]]; then
                    current_pk=$(echo "$line" | cut -d' ' -f3)
                    break
                fi
            done < "$SERVER_CONF_FILE"

            if [[ -n "$current_pk" ]]; then
                pk=$(echo "$current_pk" | head -c 10)"..."
                if echo "$awg_stat" | grep -qF "$current_pk"; then
                    local handshake_line
                    handshake_line=$(echo "$awg_stat" | grep -A 3 -F "$current_pk" | grep 'latest handshake:')
                    if [[ -n "$handshake_line" && ! "$handshake_line" =~ "never" ]]; then
                        if echo "$handshake_line" | grep -q "seconds ago"; then
                            local sec
                            sec=$(echo "$handshake_line" | grep -oP '\d+(?= seconds ago)')
                            if [[ "$sec" -lt 180 ]]; then
                                st="Active"
                                color_start="\033[0;32m"
                                ((act++))
                            else
                                st="Recent"
                                color_start="\033[0;33m"
                                ((act++))
                            fi
                        else
                            st="Recent"
                            color_start="\033[0;33m"
                            ((act++))
                        fi
                    else
                        st="No handshake"
                        color_start="\033[0;37m"
                    fi
                else
                    st="Not found"
                    color_start="\033[0;31m"
                fi
            else
                pk="?"
                st="Key error"
                color_start="\033[0;31m"
            fi
        fi

        if [[ $verbose -eq 1 ]]; then
            printf "%-20s | %-7s | %-7s | %-15s | %-15s | ${color_start}%s${color_end}\n" "$name" "$cf" "$png" "$ip" "$pk" "$st"
        else
            printf "%-20s | %-7s | %-7s | ${color_start}%s${color_end}\n" "$name" "$cf" "$png" "$st"
        fi
    done <<< "$clients"
    echo ""
    log "Total clients: $tot, Active/Recent: $act"
}

# ==============================================================================
# Help
# ==============================================================================

usage() {
    exec >&2
    echo ""
    echo "AmneziaWG 2.0 management script (v5.2)"
    echo "=============================================="
    echo "Usage: $0 [OPTIONS] <COMMAND> [ARGUMENTS]"
    echo ""
    echo "Options:"
    echo "  -h, --help            Show this help"
    echo "  -v, --verbose         Verbose output (for list command)"
    echo "  --no-color            Disable colored output"
    echo "  --conf-dir=PATH       Specify AWG directory (default: $AWG_DIR)"
    echo "  --server-conf=PATH    Specify server config file"
    echo ""
    echo "Commands:"
    echo "  add <name>            Add a client"
    echo "  remove <name>         Remove a client"
    echo "  list [-v]             List clients"
    echo "  regen [name]          Regenerate client file(s)"
    echo "  modify <name> <p> <v> Modify a client parameter"
    echo "  backup                Create a backup"
    echo "  restore [file]        Restore from backup"
    echo "  check | status        Check server status"
    echo "  show                  Show \`awg show\` status"
    echo "  restart               Restart AmneziaWG service"
    echo "  help                  Show this help"
    echo ""
    echo "IMPORTANT: After 'add', 'remove' restart the service:"
    echo "  sudo systemctl restart awg-quick@awg0 (or $0 restart)"
    echo ""
    exit 1
}

# ==============================================================================
# Main logic
# ==============================================================================

check_dependencies || exit 1
cd "$AWG_DIR" || die "Failed to change to $AWG_DIR"

if [[ -z "$COMMAND" ]]; then usage; fi

log "Running command '$COMMAND'..."

case $COMMAND in
    add)
        [[ -z "$CLIENT_NAME" ]] && die "Client name not specified."
        validate_client_name "$CLIENT_NAME" || exit 1

        if grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
            die "Client '$CLIENT_NAME' already exists."
        fi

        log "Adding '$CLIENT_NAME'..."
        if generate_client "$CLIENT_NAME"; then
            log "Client '$CLIENT_NAME' added."
            log "Files: $AWG_DIR/${CLIENT_NAME}.conf, $AWG_DIR/${CLIENT_NAME}.png"
            log "IMPORTANT: Service restart required: sudo systemctl restart awg-quick@awg0"
        else
            log_error "Error adding client '$CLIENT_NAME'."
        fi
        ;;

    remove)
        [[ -z "$CLIENT_NAME" ]] && die "Client name not specified."
        if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
            die "Client '$CLIENT_NAME' not found."
        fi
        if ! confirm_action "remove" "client '$CLIENT_NAME'"; then exit 1; fi

        log "Removing '$CLIENT_NAME'..."
        if remove_peer_from_server "$CLIENT_NAME"; then
            log "Client '$CLIENT_NAME' removed from server config."
            rm -f "$AWG_DIR/$CLIENT_NAME.conf" "$AWG_DIR/$CLIENT_NAME.png"
            rm -f "$KEYS_DIR/${CLIENT_NAME}.private" "$KEYS_DIR/${CLIENT_NAME}.public"
            log "Client files deleted."
            log "IMPORTANT: Service restart required: sudo systemctl restart awg-quick@awg0"
        else
            log_error "Error removing client '$CLIENT_NAME'."
        fi
        ;;

    list)
        list_clients
        ;;

    regen)
        log "Regenerating config and QR files..."
        if [[ -n "$CLIENT_NAME" ]]; then
            # Regenerate single client
            validate_client_name "$CLIENT_NAME" || exit 1
            if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
                die "Client '$CLIENT_NAME' not found."
            fi
            regenerate_client "$CLIENT_NAME" || log_error "Regeneration error '$CLIENT_NAME'."
        else
            # Regenerate all clients
            all_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
            if [[ -z "$all_clients" ]]; then
                log "No clients found."
            else
                echo "$all_clients" | while IFS= read -r cname; do
                    cname=$(echo "$cname" | xargs)
                    [[ -z "$cname" ]] && continue
                    log "Regenerating '$cname'..."
                    regenerate_client "$cname" || log_warn "Regeneration error '$cname'"
                done
                log "Regeneration completed."
            fi
        fi
        ;;

    modify)
        modify_client "$CLIENT_NAME" "$PARAM" "$VALUE"
        ;;

    backup)
        backup_configs
        ;;

    restore)
        restore_backup "$CLIENT_NAME" # CLIENT_NAME is used as [file]
        ;;

    check|status)
        check_server
        ;;

    show)
        log "AmneziaWG 2.0 status..."
        if ! awg show; then log_error "awg show error."; fi
        ;;

    restart)
        log "Restarting service..."
        if ! confirm_action "restart" "service"; then exit 1; fi
        if ! systemctl restart awg-quick@awg0; then
            log_error "Restart error."
            status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
            while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
            exit 1
        else
            log "Service restarted."
        fi
        ;;

    help)
        usage
        ;;

    *)
        log_error "Unknown command: '$COMMAND'"
        usage
        ;;
esac

log "Management script finished."
exit 0
