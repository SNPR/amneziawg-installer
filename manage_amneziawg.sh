#!/bin/bash

# Проверка минимальной версии Bash
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# Скрипт для управления пользователями (пирами) AmneziaWG 2.0
# Автор: @bivlked
# Версия: 5.7.7
# Дата: 2026-03-20
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
# shellcheck disable=SC2034
SCRIPT_VERSION="5.7.7"
set -o pipefail
AWG_DIR="/root/awg"
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"
NO_COLOR=0
VERBOSE_LIST=0
JSON_OUTPUT=0
EXPIRES_DURATION=""

# --- Автоочистка временных файлов ---
_manage_cleanup() {
    type _awg_cleanup &>/dev/null && _awg_cleanup
}
trap _manage_cleanup EXIT INT TERM

# --- Обработка аргументов ---
COMMAND=""
ARGS=()
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)         COMMAND="help"; break ;;
        -v|--verbose)      VERBOSE_LIST=1; shift ;;
        --no-color)        NO_COLOR=1; shift ;;
        --json)            JSON_OUTPUT=1; shift ;;
        --expires=*)       EXPIRES_DURATION="${1#*=}"; shift ;;
        --conf-dir=*)      AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*)   SERVER_CONF_FILE="${1#*=}"; shift ;;
        --*)               echo "Неизвестная опция: $1" >&2; COMMAND="help"; break ;;
        *)
            if [[ -z "$COMMAND" ]]; then
                COMMAND=$1
            else
                ARGS+=("$1")
            fi
            shift ;;
    esac
done
CLIENT_NAME="${ARGS[0]}"
PARAM="${ARGS[1]}"
VALUE="${ARGS[2]}"

# Обновляем пути после возможного переопределения --conf-dir
CONFIG_FILE="$AWG_DIR/awgsetup_cfg.init"
KEYS_DIR="$AWG_DIR/keys"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

# ==============================================================================
# Функции логирования
# ==============================================================================

log_msg() {
    local type="$1" msg="$2"
    local ts
    ts=$(date +'%F %T')
    local safe_msg
    safe_msg="${msg//%/%%}"
    local entry="[$ts] $type: $safe_msg"
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
        echo "[$ts] ERROR: Ошибка записи лога $LOG_FILE" >&2
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
# Утилиты
# ==============================================================================

is_interactive() { [[ -t 0 && -t 1 ]]; }

# Экранирование спецсимволов для sed (предотвращает command injection)
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
    read -rp "Вы действительно хотите $action $subject? [y/N]: " confirm < /dev/tty
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        return 0
    else
        log "Действие отменено."
        return 1
    fi
}

validate_client_name() {
    local name="$1"
    if [[ -z "$name" ]]; then log_error "Имя пустое."; return 1; fi
    if [[ ${#name} -gt 63 ]]; then log_error "Имя > 63 симв."; return 1; fi
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Имя содержит недоп. символы."; return 1; fi
    return 0
}

# ==============================================================================
# Проверка зависимостей
# ==============================================================================

check_dependencies() {
    log "Проверка зависимостей..."
    local ok=1

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Не найден: $CONFIG_FILE"
        ok=0
    fi
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        log_error "Не найден: $COMMON_SCRIPT_PATH"
        ok=0
    fi
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Не найден: $SERVER_CONF_FILE"
        ok=0
    fi
    if [[ "$ok" -eq 0 ]]; then
        die "Не найдены файлы установки. Запустите install_amneziawg.sh."
    fi

    if ! command -v awg &>/dev/null; then die "'awg' не найден."; fi
    if ! command -v qrencode &>/dev/null; then log_warn "qrencode не найден (QR-коды не будут созданы)."; fi

    # Подключаем общую библиотеку
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH" || die "Ошибка загрузки $COMMON_SCRIPT_PATH"

    log "Зависимости OK."
}

# ==============================================================================
# Резервное копирование
# ==============================================================================

backup_configs() {
    log "Создание бэкапа..."
    local bd="$AWG_DIR/backups"
    mkdir -p "$bd" || die "Ошибка mkdir $bd"
    chmod 700 "$bd" 2>/dev/null
    local ts bf td
    ts=$(date +%F_%T)
    bf="$bd/awg_backup_${ts}.tar.gz"
    td=$(mktemp -d)

    mkdir -p "$td/server" "$td/clients" "$td/keys"
    cp -a "$SERVER_CONF_FILE"* "$td/server/" 2>/dev/null
    cp -a "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$AWG_DIR"/*.vpnuri "$CONFIG_FILE" "$td/clients/" 2>/dev/null || true
    cp -a "$KEYS_DIR"/* "$td/keys/" 2>/dev/null || true
    cp -a "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" "$td/" 2>/dev/null || true
    if [[ -d "${EXPIRY_DIR:-$AWG_DIR/expiry}" ]]; then
        cp -a "${EXPIRY_DIR:-$AWG_DIR/expiry}" "$td/expiry" 2>/dev/null || true
    fi
    [[ -f /etc/cron.d/awg-expiry ]] && cp -a /etc/cron.d/awg-expiry "$td/" 2>/dev/null || true

    tar -czf "$bf" -C "$td" . || { rm -rf "$td"; die "Ошибка tar $bf"; }
    log_debug "tar: архив создан $bf"
    rm -rf "$td"
    chmod 600 "$bf" || log_warn "Ошибка chmod бэкапа"

    # Оставляем максимум 10 бэкапов
    find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" -printf '%T@ %p\n' | \
        sort -nr | tail -n +11 | cut -d' ' -f2- | xargs -r rm -f || \
        log_warn "Ошибка удаления старых бэкапов"

    log "Бэкап создан: $bf"
}

restore_backup() {
    local bf="$1"
    local bd="$AWG_DIR/backups"

    if [[ -z "$bf" ]]; then
        if ! is_interactive; then
            die "Путь к бэкапу обязателен в неинтерактивном режиме: restore <файл>"
        fi
        if [[ ! -d "$bd" ]] || [[ -z "$(ls -A "$bd" 2>/dev/null)" ]]; then
            die "Бэкапы не найдены в $bd."
        fi
        local backups
        backups=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | sort -r)
        if [[ -z "$backups" ]]; then die "Бэкапы не найдены."; fi

        echo "Доступные бэкапы:"
        local i=1
        local bl=()
        while IFS= read -r f; do
            echo "  $i) $(basename "$f")"
            bl[$i]="$f"
            ((i++))
        done <<< "$backups"

        read -rp "Номер для восстановления (0-отмена): " choice < /dev/tty
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -eq 0 ]] || [[ "$choice" -ge "$i" ]]; then
            log "Отмена."
            return 1
        fi
        bf="${bl[$choice]}"
    fi

    if [[ ! -f "$bf" ]]; then die "Файл бэкапа '$bf' не найден."; fi
    log "Восстановление из $bf"
    if ! confirm_action "восстановить" "конфигурацию из '$bf'"; then return 1; fi

    log "Создание бэкапа текущей..."
    backup_configs

    local td restore_errors=0
    td=$(mktemp -d)
    if ! tar -xzf "$bf" -C "$td"; then
        log_error "Ошибка tar $bf"
        rm -rf "$td"
        return 1
    fi

    log "Остановка сервиса..."
    systemctl stop awg-quick@awg0 || log_warn "Сервис не остановлен."

    if [[ -d "$td/server" ]]; then
        log "Восстановление конфига сервера..."
        local server_conf_dir
        server_conf_dir=$(dirname "$SERVER_CONF_FILE")
        mkdir -p "$server_conf_dir"
        cp -a "$td/server/"* "$server_conf_dir/" || { log_error "Ошибка копирования server"; restore_errors=1; }
        chmod 600 "$server_conf_dir"/*.conf 2>/dev/null
        chmod 700 "$server_conf_dir"
        log_debug "Конфиг сервера восстановлен в $server_conf_dir"
    fi

    if [[ -d "$td/clients" ]]; then
        log "Восстановление файлов клиентов..."
        cp -a "$td/clients/"* "$AWG_DIR/" || { log_error "Ошибка копирования clients"; restore_errors=1; }
        chmod 600 "$AWG_DIR"/*.conf 2>/dev/null
        chmod 600 "$CONFIG_FILE" 2>/dev/null
        log_debug "Файлы клиентов восстановлены в $AWG_DIR"
    fi

    if [[ -d "$td/keys" ]]; then
        log "Восстановление ключей..."
        mkdir -p "$KEYS_DIR"
        cp -a "$td/keys/"* "$KEYS_DIR/" || { log_error "Ошибка копирования keys"; restore_errors=1; }
        chmod 600 "$KEYS_DIR"/* 2>/dev/null
        log_debug "Ключи восстановлены в $KEYS_DIR"
    fi

    # Серверные ключи
    [[ -f "$td/server_private.key" ]] && cp -a "$td/server_private.key" "$AWG_DIR/"
    [[ -f "$td/server_public.key" ]] && cp -a "$td/server_public.key" "$AWG_DIR/"

    if [[ -d "$td/expiry" ]]; then
        log "Восстановление данных expiry..."
        mkdir -p "${EXPIRY_DIR:-$AWG_DIR/expiry}"
        cp -a "$td/expiry/"* "${EXPIRY_DIR:-$AWG_DIR/expiry}/" 2>/dev/null || true
        chmod 600 "${EXPIRY_DIR:-$AWG_DIR/expiry}"/* 2>/dev/null
    fi
    if [[ -f "$td/awg-expiry" ]]; then
        cp -a "$td/awg-expiry" /etc/cron.d/awg-expiry
        chmod 644 /etc/cron.d/awg-expiry
    fi

    rm -rf "$td"

    log "Запуск сервиса..."
    if ! systemctl start awg-quick@awg0; then
        log_error "Ошибка запуска сервиса!"
        local status_out
        status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
        while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
        return 1
    fi
    if [[ "$restore_errors" -ne 0 ]]; then
        log_warn "Восстановление завершено с ошибками. Проверьте конфигурацию."
        return 1
    fi
    log "Восстановление завершено."
}

# ==============================================================================
# Изменение параметра клиента
# ==============================================================================

modify_client() {
    local name="$1" param="$2" value="$3"

    if [[ -z "$name" || -z "$param" || -z "$value" ]]; then
        log_error "Использование: modify <имя> <параметр> <значение>"
        return 1
    fi

    # Допустимые для модификации параметры
    local allowed_params="DNS|Endpoint|AllowedIPs|PersistentKeepalive"
    if ! [[ "$param" =~ ^($allowed_params)$ ]]; then
        log_error "Параметр '$param' нельзя изменить через modify."
        log_error "Допустимые параметры: ${allowed_params//|/, }"
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
        die "Клиент '$name' не найден."
    fi

    local cf="$AWG_DIR/$name.conf"
    if [[ ! -f "$cf" ]]; then die "Файл $cf не найден."; fi

    if ! grep -q -E "^${param}[[:space:]]*=" "$cf"; then
        log_error "Параметр '$param' не найден в $cf."
        return 1
    fi

    log "Изменение '$param' на '$value' для '$name'..."
    local bak
    bak="${cf}.bak-$(date +%F_%T)"
    cp "$cf" "$bak" || log_warn "Ошибка бэкапа $bak"
    log "Бэкап: $bak"

    local escaped_value
    escaped_value=$(escape_sed "$value")
    if ! sed -i "s#^${param}[[:space:]]*=[[:space:]]*.*#${param} = ${escaped_value}#" "$cf"; then
        log_error "Ошибка sed. Восстановление..."
        cp "$bak" "$cf" || log_warn "Ошибка восстановления."
        return 1
    fi
    if ! grep -q -E "^${param} = " "$cf"; then
        log_error "Замена не выполнена для '$param'. Восстановление..."
        cp "$bak" "$cf" || log_warn "Ошибка восстановления."
        return 1
    fi
    log_debug "sed: ${param} = ${value} в $cf"

    log "Параметр '$param' изменен."

    log "Перегенерация QR-кода и vpn:// URI..."
    generate_qr "$name" || log_warn "Не удалось обновить QR-код."
    generate_vpn_uri "$name" || log_warn "Не удалось обновить vpn:// URI."

    return 0
}

# ==============================================================================
# Проверка состояния сервера
# ==============================================================================

check_server() {
    log "Проверка состояния сервера AmneziaWG 2.0..."
    local ok=1

    log "Статус сервиса:"
    if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi

    log "Интерфейс awg0:"
    if ! ip addr show awg0 &>/dev/null; then
        log_error " - Интерфейс не найден!"
        ok=0
    else
        while IFS= read -r line; do log "  $line"; done < <(ip addr show awg0)
    fi

    log "Прослушивание порта:"
    # shellcheck source=/dev/null
    safe_load_config "$CONFIG_FILE" 2>/dev/null
    local port=${AWG_PORT:-0}
    if [[ "$port" -eq 0 ]]; then
        log_warn " - Не удалось определить порт."
    else
        if ! ss -lunp | grep -qP ":${port}\s"; then
            log_error " - Порт ${port}/udp НЕ прослушивается!"
            ok=0
        else
            log " - Порт ${port}/udp прослушивается."
        fi
    fi

    log "Настройки ядра:"
    local fwd
    fwd=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$fwd" != "1" ]]; then
        log_error " - IP Forwarding выключен ($fwd)!"
        ok=0
    else
        log " - IP Forwarding включен."
    fi

    log "Правила UFW:"
    if command -v ufw &>/dev/null; then
        if ! ufw status | grep -qw "${port}/udp"; then
            log_warn " - Правило UFW для ${port}/udp не найдено!"
        else
            log " - Правило UFW для ${port}/udp есть."
        fi
    else
        log_warn " - UFW не установлен."
    fi

    log "Статус AmneziaWG 2.0:"
    while IFS= read -r line; do log "  $line"; done < <(awg show)

    # AWG 2.0 диагностика
    if awg show awg0 2>/dev/null | grep -q "jc:"; then
        log " - AWG 2.0 параметры обфускации: активны"
    else
        log_warn " - AWG 2.0 параметры обфускации не обнаружены"
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Проверка завершена: Состояние OK."
        return 0
    else
        log_error "Проверка завершена: ОБНАРУЖЕНЫ ПРОБЛЕМЫ!"
        return 1
    fi
}

# ==============================================================================
# Список клиентов
# ==============================================================================

list_clients() {
    log "Получение списка клиентов..."
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        log "Клиенты не найдены."
        return 0
    fi

    local verbose=$VERBOSE_LIST
    local act=0 tot=0

    # Однопроходный парсинг серверного конфига: name → pubkey
    local -A _name_to_pk
    local _cn=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            _cn="${line#\#_Name = }"
            _cn="${_cn## }"; _cn="${_cn%% }"
        elif [[ -n "$_cn" && "$line" == "PublicKey = "* ]]; then
            local _pk="${line#PublicKey = }"
            _pk="${_pk## }"; _pk="${_pk%% }"
            [[ -n "$_pk" ]] && _name_to_pk["$_cn"]="$_pk"
            _cn=""
        fi
    done < "$SERVER_CONF_FILE"

    # Однопроходный парсинг awg show dump: pubkey → handshake timestamp
    local -A _pk_to_hs
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || awg_dump=""
    if [[ -n "$awg_dump" ]]; then
        # shellcheck disable=SC2034
        while IFS=$'\t' read -r _dpk _dpsk _dep _daips _dhs _drx _dtx _dka; do
            _pk_to_hs["$_dpk"]="$_dhs"
        done < <(echo "$awg_dump" | tail -n +2)
    fi

    if [[ $verbose -eq 1 ]]; then
        printf "%-20s | %-7s | %-7s | %-15s | %-15s | %s\n" "Имя клиента" "Conf" "QR" "IP-адрес" "Ключ (нач.)" "Статус"
        printf -- "-%.0s" {1..95}
        echo
    else
        printf "%-20s | %-7s | %-7s | %s\n" "Имя клиента" "Conf" "QR" "Статус"
        printf -- "-%.0s" {1..50}
        echo
    fi

    local now
    now=$(date +%s)

    while IFS= read -r name; do
        name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"
        if [[ -z "$name" ]]; then continue; fi
        ((tot++))

        local cf="?" png="?" pk="-" ip="-" st="Нет данных"
        local color_start="" color_end=""
        if [[ "$NO_COLOR" -eq 0 ]]; then
            color_end="\033[0m"
            color_start="\033[0;37m"
        fi

        [[ -f "$AWG_DIR/${name}.conf" ]] && cf="+"
        [[ -f "$AWG_DIR/${name}.png" ]] && png="+"

        if [[ "$cf" == "+" ]]; then
            ip=$(grep -oP 'Address = \K[0-9.]+' "$AWG_DIR/${name}.conf" 2>/dev/null) || ip="?"

            local current_pk="${_name_to_pk[$name]:-}"

            if [[ -n "$current_pk" ]]; then
                pk="${current_pk:0:10}..."
                local handshake="${_pk_to_hs[$current_pk]:-0}"
                if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
                    local diff=$((now - handshake))
                    if [[ $diff -lt 180 ]]; then
                        st="Активен"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;32m"
                        ((act++))
                    elif [[ $diff -lt 86400 ]]; then
                        st="Недавно"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;33m"
                        ((act++))
                    else
                        st="Нет handshake"
                        [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                    fi
                else
                    st="Нет handshake"
                    [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;37m"
                fi
            else
                pk="?"
                st="Ошибка ключа"
                [[ "$NO_COLOR" -eq 0 ]] && color_start="\033[0;31m"
            fi
        fi

        # Expiry info
        local exp_str=""
        local exp_ts
        exp_ts=$(get_client_expiry "$name" 2>/dev/null)
        if [[ -n "$exp_ts" ]]; then
            exp_str=" [$(format_remaining "$exp_ts")]"
        fi

        if [[ $verbose -eq 1 ]]; then
            printf "%-20s | %-7s | %-7s | %-15s | %-15s | ${color_start}%s${color_end}%s\n" "$name" "$cf" "$png" "$ip" "$pk" "$st" "$exp_str"
        else
            printf "%-20s | %-7s | %-7s | ${color_start}%s${color_end}%s\n" "$name" "$cf" "$png" "$st" "$exp_str"
        fi
    done <<< "$clients"
    echo ""
    log "Всего клиентов: $tot, Активных/Недавно: $act"
}

# ==============================================================================
# Статистика трафика
# ==============================================================================

# Экранирование строки для безопасного включения в JSON
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    printf '%s' "$s"
}

# Форматирование размера в человекочитаемый формат
format_bytes() {
    local bytes="${1:-0}"
    if [[ ! "$bytes" =~ ^[0-9]+$ ]]; then printf "0 B"; return; fi
    if [[ "$bytes" -ge 1073741824 ]]; then
        awk "BEGIN{printf \"%.2f GiB\", $bytes/1073741824}"
    elif [[ "$bytes" -ge 1048576 ]]; then
        awk "BEGIN{printf \"%.2f MiB\", $bytes/1048576}"
    elif [[ "$bytes" -ge 1024 ]]; then
        awk "BEGIN{printf \"%.1f KiB\", $bytes/1024}"
    else
        printf "%d B" "$bytes"
    fi
}

stats_clients() {
    local clients
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients=""
    if [[ -z "$clients" ]]; then
        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            echo "[]"
        else
            log "Клиенты не найдены."
        fi
        return 0
    fi

    # Получаем данные awg show awg0
    local awg_dump
    awg_dump=$(awg show awg0 dump 2>/dev/null) || {
        log_error "Ошибка получения данных awg show."
        return 1
    }

    # Маппинг: публичный ключ → имя клиента (single-pass)
    local -A pk_to_name
    local _current_name=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" == "#_Name = "* ]]; then
            _current_name="${line#\#_Name = }"
            _current_name="${_current_name## }"; _current_name="${_current_name%% }"
        elif [[ -n "$_current_name" && "$line" == "PublicKey = "* ]]; then
            local _pk="${line#PublicKey = }"
            _pk="${_pk## }"; _pk="${_pk%% }"
            [[ -n "$_pk" ]] && pk_to_name["$_pk"]="$_current_name"
            _current_name=""
        fi
    done < "$SERVER_CONF_FILE"

    local json_entries=()
    local table_rows=()
    local total_rx=0 total_tx=0

    # awg show dump: каждая строка пира = pubkey psk endpoint allowed-ips latest-handshake rx tx keepalive
    # shellcheck disable=SC2034
    while IFS=$'\t' read -r pk psk ep aips handshake rx tx keepalive; do
        local cname="${pk_to_name[$pk]:-unknown}"
        if [[ "$cname" == "unknown" ]]; then continue; fi

        local ip="-"
        if [[ -f "$AWG_DIR/${cname}.conf" ]]; then
            ip=$(grep -oP 'Address = \K[0-9.]+' "$AWG_DIR/${cname}.conf" 2>/dev/null) || ip="?"
        fi

        local hs_str="никогда"
        local status="Неактивен"
        if [[ "$handshake" =~ ^[0-9]+$ && "$handshake" -gt 0 ]]; then
            local now
            now=$(date +%s)
            local diff=$((now - handshake))
            if [[ $diff -lt 180 ]]; then
                status="Активен"
            elif [[ $diff -lt 86400 ]]; then
                status="Недавно"
            fi
            hs_str=$(date -d "@$handshake" '+%F %T' 2>/dev/null || echo "$handshake")
        fi

        total_rx=$((total_rx + rx))
        total_tx=$((total_tx + tx))

        if [[ "$JSON_OUTPUT" -eq 1 ]]; then
            json_entries+=("{\"name\":\"$(json_escape "$cname")\",\"ip\":\"$(json_escape "$ip")\",\"rx\":$rx,\"tx\":$tx,\"last_handshake\":$handshake,\"status\":\"$(json_escape "$status")\"}")
        else
            local rx_h tx_h
            rx_h=$(format_bytes "$rx")
            tx_h=$(format_bytes "$tx")
            table_rows+=("$(printf "%-15s | %-15s | %-12s | %-12s | %-19s | %s" "$cname" "$ip" "$rx_h" "$tx_h" "$hs_str" "$status")")
        fi
    done < <(echo "$awg_dump" | tail -n +2)

    if [[ "$JSON_OUTPUT" -eq 1 ]]; then
        ( IFS=","; echo "[${json_entries[*]}]" )
    else
        log "Статистика трафика клиентов:"
        echo ""
        printf "%-15s | %-15s | %-12s | %-12s | %-19s | %s\n" "Имя" "IP" "Получено" "Отправлено" "Последний handshake" "Статус"
        printf -- "-%.0s" {1..95}
        echo
        for row in "${table_rows[@]}"; do
            echo "$row"
        done
        echo ""
        log "Итого: Получено $(format_bytes "$total_rx"), Отправлено $(format_bytes "$total_tx")"
    fi
}

# ==============================================================================
# Справка
# ==============================================================================

usage() {
    exec >&2
    echo ""
    echo "Скрипт управления AmneziaWG 2.0 (v${SCRIPT_VERSION})"
    echo "=============================================="
    echo "Использование: $0 [ОПЦИИ] <КОМАНДА> [АРГУМЕНТЫ]"
    echo ""
    echo "Опции:"
    echo "  -h, --help            Показать эту справку"
    echo "  -v, --verbose         Расширенный вывод (для команды list)"
    echo "  --no-color            Отключить цветной вывод"
    echo "  --json                JSON-вывод (для команды stats)"
    echo "  --expires=ВРЕМЯ       Срок действия при add (1h, 12h, 1d, 7d, 30d, 4w)"
    echo "  --conf-dir=ПУТЬ       Указать директорию AWG (умолч: $AWG_DIR)"
    echo "  --server-conf=ПУТЬ    Указать файл конфига сервера"
    echo ""
    echo "Команды:"
    echo "  add <имя> [--expires=ВРЕМЯ]  Добавить клиента (с опц. сроком действия)"
    echo "  remove <имя>          Удалить клиента"
    echo "  list [-v]             Показать список клиентов"
    echo "  stats [--json]        Статистика трафика по клиентам"
    echo "  regen [имя]           Перегенерировать файлы клиента(ов)"
    echo "  modify <имя> <пар> <зн> Изменить параметр клиента"
    echo "  backup                Создать бэкап"
    echo "  restore [файл]        Восстановить из бэкапа"
    echo "  check | status        Проверить состояние сервера"
    echo "  show                  Показать статус \`awg show\`"
    echo "  restart               Перезапустить сервис AmneziaWG"
    echo "  help                  Показать эту справку"
    echo ""
    exit 1
}

# ==============================================================================
# Основная логика
# ==============================================================================

if [[ "$COMMAND" == "help" || -z "$COMMAND" ]]; then
    usage
fi

check_dependencies || exit 1
cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"

log "Запуск команды '$COMMAND'..."
_cmd_rc=0

case $COMMAND in
    add)
        [[ -z "$CLIENT_NAME" ]] && die "Не указано имя клиента."
        validate_client_name "$CLIENT_NAME" || exit 1

        if grep -qxF "#_Name = ${CLIENT_NAME}" "$SERVER_CONF_FILE"; then
            die "Клиент '$CLIENT_NAME' уже существует."
        fi

        log "Добавление '$CLIENT_NAME'..."
        if generate_client "$CLIENT_NAME"; then
            log_debug "Пир '$CLIENT_NAME' добавлен в серверный конфиг."
            log "Клиент '$CLIENT_NAME' добавлен."
            log "Файлы: $AWG_DIR/${CLIENT_NAME}.conf, $AWG_DIR/${CLIENT_NAME}.png"
            if [[ -f "$AWG_DIR/${CLIENT_NAME}.vpnuri" ]]; then
                log "vpn:// URI: $AWG_DIR/${CLIENT_NAME}.vpnuri"
                log "Для импорта в Amnezia Client скопируйте содержимое файла .vpnuri"
            fi
            if [[ -n "$EXPIRES_DURATION" ]]; then
                if set_client_expiry "$CLIENT_NAME" "$EXPIRES_DURATION"; then
                    install_expiry_cron
                fi
            fi
            apply_config
        else
            log_error "Ошибка добавления клиента '$CLIENT_NAME'."
            _cmd_rc=1
        fi
        ;;

    remove)
        [[ -z "$CLIENT_NAME" ]] && die "Не указано имя клиента."
        validate_client_name "$CLIENT_NAME" || exit 1
        if ! grep -qxF "#_Name = ${CLIENT_NAME}" "$SERVER_CONF_FILE"; then
            die "Клиент '$CLIENT_NAME' не найден."
        fi
        if ! confirm_action "удалить" "клиента '$CLIENT_NAME'"; then exit 1; fi

        log "Удаление '$CLIENT_NAME'..."
        if remove_peer_from_server "$CLIENT_NAME"; then
            log_debug "Пир '$CLIENT_NAME' удалён из серверного конфига."
            log "Клиент '$CLIENT_NAME' удалён из серверного конфига."
            rm -f "$AWG_DIR/$CLIENT_NAME.conf" "$AWG_DIR/$CLIENT_NAME.png" "$AWG_DIR/$CLIENT_NAME.vpnuri"
            rm -f "$KEYS_DIR/${CLIENT_NAME}.private" "$KEYS_DIR/${CLIENT_NAME}.public"
            remove_client_expiry "$CLIENT_NAME"
            log "Файлы клиента удалены."
            apply_config
        else
            log_error "Ошибка удаления клиента '$CLIENT_NAME'."
            _cmd_rc=1
        fi
        ;;

    list)
        list_clients || _cmd_rc=1
        ;;

    stats)
        stats_clients || _cmd_rc=1
        ;;

    regen)
        log "Перегенерация файлов конфигурации и QR..."
        if [[ -n "$CLIENT_NAME" ]]; then
            # Перегенерация одного клиента
            validate_client_name "$CLIENT_NAME" || exit 1
            if ! grep -qxF "#_Name = ${CLIENT_NAME}" "$SERVER_CONF_FILE"; then
                die "Клиент '$CLIENT_NAME' не найден."
            fi
            regenerate_client "$CLIENT_NAME" || { log_error "Ошибка перегенерации '$CLIENT_NAME'."; _cmd_rc=1; }
        else
            # Перегенерация всех клиентов
            all_clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //')
            if [[ -z "$all_clients" ]]; then
                log "Клиенты не найдены."
            else
                while IFS= read -r cname; do
                    cname="${cname## }"; cname="${cname%% }"
                    [[ -z "$cname" ]] && continue
                    log "Перегенерация '$cname'..."
                    regenerate_client "$cname" || { log_warn "Ошибка перегенерации '$cname'"; _cmd_rc=1; }
                done <<< "$all_clients"
                log "Перегенерация завершена."
            fi
        fi
        ;;

    modify)
        [[ -z "$CLIENT_NAME" ]] && die "Не указано имя клиента."
        validate_client_name "$CLIENT_NAME" || exit 1
        modify_client "$CLIENT_NAME" "$PARAM" "$VALUE" || _cmd_rc=1
        ;;

    backup)
        backup_configs || _cmd_rc=1
        ;;

    restore)
        restore_backup "$CLIENT_NAME" || _cmd_rc=1 # CLIENT_NAME используется как [файл]
        ;;

    check|status)
        check_server || _cmd_rc=1
        ;;

    show)
        log "Статус AmneziaWG 2.0..."
        if ! awg show; then log_error "Ошибка awg show."; _cmd_rc=1; fi
        ;;

    restart)
        log "Перезапуск сервиса..."
        if ! confirm_action "перезапустить" "сервис"; then exit 1; fi
        if ! systemctl restart awg-quick@awg0; then
            log_error "Ошибка перезапуска."
            status_out=$(systemctl status awg-quick@awg0 --no-pager 2>&1) || true
            while IFS= read -r line; do log_error "  $line"; done <<< "$status_out"
            exit 1
        else
            log "Сервис перезапущен."
        fi
        ;;

    help)
        usage
        ;;

    *)
        log_error "Неизвестная команда: '$COMMAND'"
        _cmd_rc=1
        usage
        ;;
esac

log "Скрипт управления завершил работу."
exit $_cmd_rc
