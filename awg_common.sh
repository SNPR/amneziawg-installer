#!/bin/bash

# ==============================================================================
# Общая библиотека функций для AmneziaWG 2.0
# Автор: @bivlked
# Версия: 5.15.6
# Дата: 2026-06-08
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================
#
# Этот файл содержит общие функции для генерации ключей, конфигураций,
# управления пирами и работы с AWG 2.0 параметрами.
# Предназначен для подключения через source из install и manage скриптов.
# ==============================================================================

# --- Константы (могут быть переопределены до source) ---
AWG_DIR="${AWG_DIR:-/root/awg}"
CONFIG_FILE="${CONFIG_FILE:-$AWG_DIR/awgsetup_cfg.init}"
SERVER_CONF_FILE="${SERVER_CONF_FILE:-/etc/amnezia/amneziawg/awg0.conf}"
KEYS_DIR="${KEYS_DIR:-$AWG_DIR/keys}"

# --- Автоочистка временных файлов ---
# ВАЖНО: trap НЕ устанавливается здесь, чтобы не перезаписать trap вызывающего скрипта.
# Вызывающий скрипт должен вызвать _awg_cleanup() в своём обработчике EXIT.
_AWG_TEMP_FILES=()
# Файл-реестр temp-файлов: awg_mktemp часто вызывается через $(...) (subshell),
# где правка массива _AWG_TEMP_FILES теряется в родителе. Файл переживает
# subshell, поэтому _awg_cleanup надёжно удалит даже temp, созданный в
# подстановке команды (например прерванная запись конфига между mktemp и mv).
# $$ = PID вызывающего скрипта, стабилен для всех его subshell.
_AWG_TEMP_REGISTRY="${TMPDIR:-/tmp}/.awg_temp_registry.$$"

_awg_cleanup() {
    local f
    for f in "${_AWG_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    if [[ -n "${_AWG_TEMP_REGISTRY:-}" && -f "$_AWG_TEMP_REGISTRY" ]]; then
        while IFS= read -r f; do
            [[ -n "$f" && -f "$f" ]] && rm -f "$f"
        done < "$_AWG_TEMP_REGISTRY"
        rm -f "$_AWG_TEMP_REGISTRY"
    fi
}

# Обёртка mktemp с автоочисткой.
# Опциональный 1-й аргумент - целевой каталог: temp создаётся в нём же, где
# окажется итоговый файл, чтобы последующий mv был атомарным rename в пределах
# одной ФС, а не cross-fs copy+unlink (важно, когда /tmp смонтирован как tmpfs).
# Без аргумента поведение прежнее (/tmp или $TMPDIR) - обратная совместимость.
awg_mktemp() {
    local dir="${1:-}" f
    if [[ -n "$dir" ]]; then
        mkdir -p "$dir" 2>/dev/null
        f=$(mktemp -p "$dir") || return 1
    else
        f=$(mktemp) || return 1
    fi
    _AWG_TEMP_FILES+=("$f")
    # Дублируем путь в файл-реестр - он переживает subshell ($(awg_mktemp ...)),
    # в отличие от массива выше.
    [[ -n "${_AWG_TEMP_REGISTRY:-}" ]] && printf '%s\n' "$f" >> "$_AWG_TEMP_REGISTRY" 2>/dev/null
    echo "$f"
}

# --- Заглушки для логирования (переопределяются вызывающим скриптом) ---
if ! declare -f log >/dev/null 2>&1; then
    log()       { echo "[INFO] $1"; }
    log_warn()  { echo "[WARN] $1" >&2; }
    log_error() { echo "[ERROR] $1" >&2; }
    log_debug() { echo "[DEBUG] $1"; }
fi

# ==============================================================================
# Утилиты
# ==============================================================================

# --- Валидаторы IP / CIDR (общие для install и manage) ---
# Проверяют не только форму, но и числовые диапазоны: октеты IPv4 0-255,
# префикс IPv4 0-32, IPv6 0-128. Без префикса адрес валиден (wireguard-tools
# трактует голый IPv4 как /32, IPv6 как /128 - host-route).

# _valid_ipv4 <addr> : ровно 4 октета, каждый 0-255 (10# защищает от трактовки
# ведущего нуля как восьмеричного числа в (( )) ).
_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"; do
        (( 10#$o <= 255 )) || return 1
    done
    return 0
}

# _valid_ipv6 <addr> : структурная проверка (не только charset). Допускает одну
# компрессию "::"; без неё требует ровно 8 групп по 1-4 hex; с ней - не более 7.
# Встроенный IPv4 (::ffff:1.2.3.4) намеренно не поддержан - в AllowedIPs туннеля
# не встречается, а точки уже отсекаются charset-проверкой.
_valid_ipv6() {
    local ip="$1"
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    case "$ip" in
        *:::*)   return 1 ;;                     # три и более ":" подряд
        *::*::*) return 1 ;;                     # более одной "::"
    esac
    [[ "$ip" == :* && "$ip" != ::* ]] && return 1   # одиночное ведущее ":"
    [[ "$ip" == *: && "$ip" != *:: ]] && return 1   # одиночное хвостовое ":"
    local has_dcolon=0
    [[ "$ip" == *::* ]] && has_dcolon=1
    local IFS=':' parts=() p ngroups=0
    read -ra parts <<< "$ip"
    for p in "${parts[@]}"; do
        [[ -z "$p" ]] && continue                 # пустые поля от "::"
        [[ "$p" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        (( ngroups++ ))
    done
    if [[ $has_dcolon -eq 1 ]]; then
        (( ngroups <= 7 )) || return 1            # "::" заменяет >=1 группу
    else
        (( ngroups == 8 )) || return 1
    fi
    return 0
}

# _valid_cidr <token> : IPv4/IPv6 адрес с опциональным префиксом. Префикс, если
# задан, обязан быть числом в допустимом диапазоне (IPv4 0-32, IPv6 0-128).
# Пустой префикс после "/" (например "1.2.3.4/") отвергается.
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

# _valid_host_or_ipv4 <host> : для Endpoint - корректный IPv4 ИЛИ FQDN.
_valid_host_or_ipv4() {
    local host="$1"
    _valid_ipv4 "$host" && return 0
    [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1
    # Полностью числовая последняя метка = не настоящий TLD (RFC 3696), а скорее
    # битый IPv4 (например "999.1.1.1"); отвергаем, чтобы не принять опечатку в IP.
    local last="${host##*.}"
    [[ "$last" =~ ^[0-9]+$ ]] && return 1
    return 0
}

# Определение основного сетевого интерфейса
get_main_nic() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}'
}

# Определение внешнего IP-адреса сервера (с кэшированием).
#
# Список 6 сервисов покрывает основные NAT и cloud-сценарии без
# жёсткого ранжирования по uptime: ifconfig.me исторически стабилен
# на обычных VPS (Hetzner, Vultr, OVH), checkip.amazonaws.com -
# доступен даже из AWS / GCP / OCI private subnet за NAT Gateway,
# ipinfo.io / icanhazip / ifconfig.io - дополнительные fallback'и
# на случай rate-limit одного из endpoint'ов. Порядок alphabetical
# (детерминирован для тестов и diff'ов). First-wins: при первом
# валидном ответе остальные не запрашиваются.
_CACHED_PUBLIC_IP=""
get_server_public_ip() {
    if [[ -n "$_CACHED_PUBLIC_IP" ]]; then
        echo "$_CACHED_PUBLIC_IP"
        return 0
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

# Fallback: первый non-loopback IPv4 с сетевого интерфейса.
# Нужен когда curl до ifconfig.me / ipify / ... не проходит (LXC без egress,
# fail2ban на outbound, firewall, и т.п.). На bare metal / обычных VPS
# обычно совпадает с public IP; на NAT'нутом хосте даёт private IP — в
# этом случае вызывающий код должен написать log_warn чтобы пользователь
# сам исправил Endpoint в клиентских .conf.
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

# Note: apt_update_tolerant() определена inline в install_amneziawg.sh
# (нужна в шагах 1-2 до скачивания этого файла). Здесь её нет — мёртвый код.

# ==============================================================================
# Генерация AWG 2.0 параметров (используется в тестах + manage)
# ==============================================================================

# Случайное число [min, max] через /dev/urandom (поддержка uint32).
# Дублирует install_amneziawg.sh:rand_range — нужно здесь для тестов и regen.
rand_range() {
    local min=$1 max=$2
    local range=$((max - min + 1))
    local random_val
    random_val=$(od -An -tu4 -N4 /dev/urandom 2>/dev/null | tr -d ' ')
    if [[ -z "$random_val" || ! "$random_val" =~ ^[0-9]+$ ]]; then
        random_val=$(( (RANDOM << 15) | RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Генерация 4 непересекающихся диапазонов для AWG H1-H4.
# Алгоритм: 8 случайных значений → sort → 4 пары (low, high).
# Сортировка гарантирует low ≤ high и непересечение между парами.
# Минимальная ширина каждого диапазона = 1000.
# Печатает 4 строки "low-high" в stdout. Возвращает 1 при неудаче.
# Защита от ТСПУ-фингерпринта по статическим H-значениям (#38).
#
# Диапазон: [0, 2^31-1] = [0, 2147483647]. Спецификация AmneziaWG
# допускает полный uint32 (0-4294967295), но standalone Windows-клиент
# `amneziawg-windows-client` имеет UI-валидатор ограниченный 2^31-1 в
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, не исправлен). Значения
# выше 2^31-1 на сервере работают, но клиентский редактор подчёркивает
# их красным и не даёт сохранять правки. Для совместимости генерируем
# в безопасной половине диапазона (#40).
#
# Оптимизация: один вызов `od -N32 -tu4` читает 32 байта = 8 uint32 значений
# одной операцией, вместо 8 отдельных subprocess через rand_range.
# Fallback на rand_range если /dev/urandom недоступен.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
        # Один read 32 байт из /dev/urandom = 8 uint32 значений
        raw=$(od -An -N32 -tu4 /dev/urandom 2>/dev/null | tr -s ' \n' '\n' | sed '/^$/d')
        if [[ -n "$raw" ]]; then
            local count=0
            while IFS= read -r _v; do
                [[ "$_v" =~ ^[0-9]+$ ]] || continue
                # Маска 0x7FFFFFFF: очищает старший бит, значение в [0, 2^31-1]
                # без bias (каждый младший бит независим).
                arr+=("$(( _v & 2147483647 ))")
                count=$((count + 1))
                (( count == 8 )) && break
            done <<< "$raw"
        fi
        # Fallback: 8 отдельных вызовов rand_range (если urandom недоступен)
        if (( ${#arr[@]} != 8 )); then
            arr=()
            local _i
            for _i in 1 2 3 4 5 6 7 8; do
                arr+=("$(rand_range 0 2147483647)")
            done
        fi
        # Сортировка
        local sorted
        sorted=$(printf '%s\n' "${arr[@]}" | sort -n)
        arr=()
        while IFS= read -r _v; do arr+=("$_v"); done <<< "$sorted"
        # Проверка минимальной ширины каждой пары
        if (( ${arr[1]} - ${arr[0]} >= 1000 )) && \
           (( ${arr[3]} - ${arr[2]} >= 1000 )) && \
           (( ${arr[5]} - ${arr[4]} >= 1000 )) && \
           (( ${arr[7]} - ${arr[6]} >= 1000 )); then
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
# DKMS / Автовосстановление модуля ядра amneziawg
# ==============================================================================
#
# После apt upgrade ядра DKMS-модуль должен пересобраться для нового kernel.
# Если это не произошло (или модуль был отвязан), 4 функции ниже выполняют
# idempotent восстановление:
#
#   _sanitize_awg_dkms_conf       — убрать deprecated REMAKE_INITRD= из dkms.conf
#   _install_kernel_headers       — distro-aware fallback chain (Ubuntu/Debian)
#   _ensure_awg_quick_running     — стартовать awg-quick@awg0 если неактивен
#   ensure_amneziawg_kernel_module — master, публичная точка входа
#
# === Контекст использования и safety contract ===
#
# Master ensure_amneziawg_kernel_module() исходит из того, что running kernel
# (uname -r) и есть target kernel — то есть подходит только для post-reboot
# контекстов: manage repair-module, manage add/remove (после reboot user'а),
# systemd unit (стартует на boot когда ядро уже новое). Из DPkg::Post-Invoke
# хука uname -r всё ещё возвращает СТАРОЕ ядро — для этого случая Phase 3
# Apt hook helper будет использовать отдельную обёртку, итерирующую target
# ядра через /lib/modules/*/build.
#
# Master НЕ вызывает apt-get install по умолчанию (это deadlock в любом
# контексте где parent держит /var/lib/dpkg/lock-frontend). Вызов apt
# гейтится переменной окружения AWG_ALLOW_APT_IN_ENSURE=1 — её устанавливает
# только install_amneziawg step 2 / manage repair-module. Apt hook helper
# и systemd unit её НЕ устанавливают, master skip'ит шаг с headers.
#
# Headers нужно ставить отдельно — на этапе install через мета-пакет
# (linux-headers-$(arch) для Debian, linux-headers-generic для Ubuntu) —
# apt сам подтянет matching headers при apt upgrade ядра.

# Удаление deprecated директивы REMAKE_INITRD= из dkms.conf модуля amneziawg.
# Современные версии DKMS считают её deprecated и печатают noisy warnings.
_sanitize_awg_dkms_conf() {
    local conf
    for conf in /var/lib/dkms/amneziawg/*/source/dkms.conf; do
        [[ -f "$conf" ]] && sed -i '/^REMAKE_INITRD=/d' "$conf"
    done
}

# Установка пакета kernel headers через distro-aware fallback chain.
# Аргумент: версия ядра (по умолчанию $(uname -r)).
# Возвращает: 0 если хотя бы один кандидат установлен успешно, 1 если все провалились.
#
# ВАЖНО: вызывается только из контекстов где apt lock доступен (install_amneziawg
# step 2 или manage repair-module). НЕ должна вызываться из DPkg::Post-Invoke хука.
#
# Поддерживается распознавание Raspberry Pi Foundation kernel (+rpt/-rpi suffix):
# linux-headers-rpi-2712 (Pi 5 / Cortex-A76) или linux-headers-rpi-v8 (Pi 3/4 arm64).
_install_kernel_headers() {
    # Defense-in-depth: эта функция вызывает apt-get install и не должна
    # запускаться из hook-context (deadlock на dpkg lock). Master уже гейтит
    # её через AWG_ALLOW_APT_IN_ENSURE, но _ префикс не enforced — добавляем
    # тот же гард сюда чтобы случайный direct call из чужого скрипта не
    # обошёл защиту.
    if [[ "${AWG_ALLOW_APT_IN_ENSURE:-0}" != "1" ]]; then
        log_error "_install_kernel_headers: AWG_ALLOW_APT_IN_ENSURE не выставлен — apt-вызов запрещён в этом контексте."
        return 1
    fi

    local kernel_ver="${1:-$(uname -r)}"
    local candidates=()

    # RPi Foundation kernel (suffix +rpt или -rpi) — отдельный мета-пакет
    # независимо от distro. Pattern check order: 2712 → v7l → v7 → v8 (default).
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
                # Cloud-images Debian используют отдельный мета-пакет
                # linux-headers-cloud-${arch} вместо обычного linux-headers-${arch}
                # (kernel ABI в них другая — sched/IRQ-таймеры урезаны под VM).
                # Prefer cloud-meta когда running kernel явно cloud — иначе
                # repair-module падает на AWS/Azure/GCP/cloud-Hetzner после
                # kernel upgrade, хотя headers доступны через cloud-meta.
                if [[ "$kernel_ver" == *-cloud-* ]]; then
                    candidates+=("linux-headers-cloud-${arch}")
                fi
                candidates+=("linux-headers-${arch}")
            fi
            ;;
        *)
            log_error "Установка kernel headers: неизвестный OS_ID='${OS_ID:-}' (поддерживаются только ubuntu/debian)."
            return 1
            ;;
    esac

    local pkg
    for pkg in "${candidates[@]}"; do
        if apt-get install -y "$pkg" >/dev/null 2>&1; then
            log "Установлены kernel headers: $pkg"
            return 0
        fi
        log_warn "Не удалось установить $pkg, пробую следующий кандидат..."
    done
    log_error "Не удалось установить ни один из пакетов kernel headers (${candidates[*]})."
    return 1
}

# Запуск awg-quick@<iface>, если сервис не активен.
# Аргумент: имя интерфейса (по умолчанию awg0).
# Возвращает: 0 при успешном старте или если сервис уже активен, 1 при сбое.
_ensure_awg_quick_running() {
    local iface="${1:-awg0}"
    local svc="awg-quick@${iface}.service"

    if systemctl is-active --quiet "$svc"; then
        return 0
    fi

    log "Запуск $svc (был неактивен)..."
    if systemctl start "$svc"; then
        log "$svc запущен."
        return 0
    fi
    log_error "Не удалось запустить $svc. Подробности: systemctl status $svc"
    return 1
}

# Master: гарантирует что модуль ядра amneziawg собран и загружен для running kernel.
# Idempotent: fast-path возвращает 0 если модуль уже loaded.
#
# Аргумент: режим — "full" (по умолчанию: модуль + старт awg-quick) или
#                  "module-only" (только модуль, без старта сервиса).
#
# ВАЖНО: master рассчитан на post-reboot контексты (manage repair-module,
# manage add/remove после reboot, systemd unit на boot). Apt/dpkg хук код
# НЕ должен звать master — uname -r в Post-Invoke возвращает старое ядро,
# поэтому хук должен использовать отдельную обёртку, итерирующую target
# kernels через /lib/modules/*/build (Phase 3 helper).
#
# Окружение: AWG_ALLOW_APT_IN_ENSURE=1 разрешает шаг установки kernel headers
# через apt-get install (опасно в hook context — deadlock на dpkg lock).
# Не установлено → шаг с headers пропускается с warn (предполагается что
# headers уже на диске через мета-пакет linux-headers-$(arch)).
#
# При необходимости запускает 5-шаговое восстановление:
#   headers → sanitize → dkms autoinstall → depmod → modprobe.
#
# Возвращает:
#   0 — модуль успешно загружен (и в "full" режиме awg-quick активен).
#   1 — финальный modprobe провалился, либо невалидный режим
#       (с печатью 4-шагового manual recovery).
ensure_amneziawg_kernel_module() {
    local mode="${1:-full}"
    case "$mode" in
        full|module-only) ;;
        *)
            log_error "ensure_amneziawg_kernel_module: невалидный режим '$mode' (ожидается 'full' или 'module-only')."
            return 1
            ;;
    esac
    local kernel_ver
    kernel_ver="$(uname -r)"

    # Fast-path: модуль уже загружен.
    if lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
        if [[ "$mode" == "full" ]]; then
            _ensure_awg_quick_running awg0 || \
                log_warn "Модуль активен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
        fi
        return 0
    fi

    # Модуль на диске для running kernel — пробуем modprobe до full repair.
    if find "/lib/modules/${kernel_ver}" -name 'amneziawg.ko*' -print -quit 2>/dev/null | grep -q .; then
        if modprobe amneziawg 2>/dev/null && \
           lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
            log "amneziawg-модуль найден на диске и успешно загружен."
            if [[ "$mode" == "full" ]]; then
                _ensure_awg_quick_running awg0 || \
                    log_warn "Модуль загружен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
            fi
            return 0
        fi
    fi

    log_warn "amneziawg-модуль не загружен и не собран для ядра ${kernel_ver}."
    log_warn "Запускаю автоматическое восстановление..."

    # Step 1: kernel headers — только если apt разрешён вызвавшим контекстом.
    if [[ "${AWG_ALLOW_APT_IN_ENSURE:-0}" == "1" ]]; then
        case "${OS_ID:-}" in
            ubuntu|debian)
                local headers_pkg="linux-headers-${kernel_ver}"
                if ! dpkg-query -W -f='${Status}' "$headers_pkg" 2>/dev/null | grep -q 'install ok installed'; then
                    log "Kernel headers ($headers_pkg) не установлены. Устанавливаю..."
                    _install_kernel_headers "$kernel_ver" || \
                        log_warn "Не удалось установить kernel headers. Сборка DKMS-модуля может провалиться."
                fi
                ;;
        esac
    elif [[ ! -d "/lib/modules/${kernel_ver}/build" ]]; then
        log_warn "/lib/modules/${kernel_ver}/build отсутствует, headers не установлены."
        log_warn "Apt-установка пропущена (контекст не разрешает apt). Сборка DKMS-модуля скорее всего провалится."
    fi

    # Step 2: убрать deprecated REMAKE_INITRD из dkms.conf
    _sanitize_awg_dkms_conf

    # Step 3: dkms autoinstall для running kernel.
    # Если шаг ошибётся, всё равно пробуем modprobe ниже — он окончательный indicator.
    if command -v dkms >/dev/null 2>&1; then
        log "Запуск: dkms autoinstall -k ${kernel_ver}"
        if ! dkms autoinstall -k "${kernel_ver}" >/dev/null 2>&1; then
            log_warn "dkms autoinstall завершился с ошибкой для ядра ${kernel_ver}."
            local dkms_log
            dkms_log=$(find /var/lib/dkms/amneziawg -name 'make.log' -path "*${kernel_ver}*" 2>/dev/null | head -n 1)
            if [[ -n "$dkms_log" ]]; then
                log_warn "Последние 20 строк лога сборки DKMS (${dkms_log}):"
                tail -20 "$dkms_log" | while IFS= read -r line; do log_warn "  $line"; done
            else
                log_warn "Лог сборки не найден. Подробности в /var/lib/dkms/amneziawg/."
            fi
        fi
    else
        log_warn "Пакет dkms не установлен. Пересборка модуля ядра невозможна."
    fi

    # Step 4: обновить module dependency cache для конкретного ядра.
    if command -v depmod >/dev/null 2>&1; then
        depmod -a "$kernel_ver" 2>/dev/null || \
            log_warn "depmod -a $kernel_ver завершился с ошибкой; modprobe ниже даст финальный диагноз."
    fi

    # Step 5: финальная попытка modprobe.
    if ! modprobe amneziawg 2>/dev/null; then
        log_error "Модуль ядра amneziawg не удалось загрузить для ядра ${kernel_ver}."
        log_error "Модуль отсутствует в /lib/modules/${kernel_ver}/."
        log_error "Ручное восстановление:"
        log_error "  1. apt install -y \"linux-headers-${kernel_ver}\""
        log_error "  2. dkms autoinstall -k \"${kernel_ver}\" && depmod -a"
        log_error "  3. modprobe amneziawg"
        log_error "  4. systemctl start \"awg-quick@awg0\""
        return 1
    fi

    log "Модуль amneziawg успешно загружен для ядра ${kernel_ver}."
    if [[ "$mode" == "full" ]]; then
        _ensure_awg_quick_running awg0 || \
            log_warn "Модуль загружен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
    fi
    return 0
}

# ==============================================================================
# Загрузка / сохранение параметров
# ==============================================================================

# Безопасная загрузка конфигурации (whitelist-парсер, без source/eval)
# Парсит только разрешённые ключи формата KEY=VALUE или export KEY=VALUE
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
                AWG_H1|AWG_H2|AWG_H3|AWG_H4|AWG_I1|AWG_I1_MODE|AWG_PRESET|NO_TWEAKS|AWG_APPLY_MODE|\
                ALLOW_IPV6_TUNNEL|IPV6_SUBNET|SERVER_HAS_NATIVE_IPV6|\
                AWG_ROLE|AWG_UPSTREAM_IFACE|AWG_UPSTREAM_TABLE|AWG_UPSTREAM_FWMARK|AWG_UPSTREAM_PRIORITY|\
                AWG_EGRESS|AWG_WARP_IFACE|AWG_WARP_TABLE|AWG_WARP_PRIORITY|AWG_WARP_BYPASS|\
                AWG_AMNEZIA_DNS)
                    export "$key=$value"
                    ;;
            esac
        fi
    done < "$config_file"
}

# Парсер живого серверного конфига AmneziaWG (источник истины для AWG_*).
# Читает секцию [Interface] из awg0.conf и экспортирует AWG_* переменные
# АТОМАРНО: либо все 11 обязательных параметров (Jc/Jmin/Jmax/S1-S4/H1-H4)
# найдены и экспортированы, либо ничего не меняется в окружении и возврат 1.
# Это защищает от mixed-state при частично corrupt awg0.conf.
# I1, ListenPort — опциональные, экспортируются если нашлись.
# Решает баг #38: regen использовал устаревшие значения из init-файла,
# а не актуальные из awg0.conf после ручной правки.
# shellcheck disable=SC2120  # Опциональный аргумент используется только в тестах
load_awg_params_from_server_conf() {
    local conf="${1:-$SERVER_CONF_FILE}"
    [[ -f "$conf" ]] || return 1

    # Локальное накопление — экспортируем всё-или-ничего в конце
    local _Jc="" _Jmin="" _Jmax=""
    local _S1="" _S2="" _S3="" _S4=""
    local _H1="" _H2="" _H3="" _H4=""
    local _I1="" _Port="" _MTU=""

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
            # Trim trailing whitespace
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
                ListenPort) _Port="$value" ;;
                MTU)        _MTU="$value" ;;
            esac
        fi
    done < "$conf"

    # Atomic check: все 11 обязательных полей найдены?
    [[ -n "$_Jc" && -n "$_Jmin" && -n "$_Jmax" && \
       -n "$_S1" && -n "$_S2" && -n "$_S3" && -n "$_S4" && \
       -n "$_H1" && -n "$_H2" && -n "$_H3" && -n "$_H4" ]] || return 1

    # Atomic export — окружение модифицируется только при полном успехе
    export AWG_Jc="$_Jc" AWG_Jmin="$_Jmin" AWG_Jmax="$_Jmax"
    export AWG_S1="$_S1" AWG_S2="$_S2" AWG_S3="$_S3" AWG_S4="$_S4"
    export AWG_H1="$_H1" AWG_H2="$_H2" AWG_H3="$_H3" AWG_H4="$_H4"
    [[ -n "$_I1"   ]] && export AWG_I1="$_I1"
    [[ -n "$_Port" ]] && export AWG_PORT="$_Port"
    if _validate_mtu "${_MTU:-}"; then
        export AWG_MTU="$_MTU"
    fi
    return 0
}

# Загрузка AWG параметров.
#
# Семантика источников (важно для предотвращения split-brain между сервером
# и клиентскими конфигами, см. #38):
#
#   * init-файл ($CONFIG_FILE = awgsetup_cfg.init) — для НЕ-AWG настроек
#     (OS_ID, ALLOWED_IPS, AWG_PORT, AWG_ENDPOINT и т.п.). Загружается всегда
#     если существует.
#   * Live server config ($SERVER_CONF_FILE = /etc/amnezia/amneziawg/awg0.conf)
#     — ЕДИНСТВЕННЫЙ источник истины для AWG протокольных параметров
#     (Jc/Jmin/Jmax/S1-S4/H1-H4/I1) когда файл существует.
#
# Если live server config существует но НЕ содержит полного набора AWG
# параметров (повреждение / неполная ручная правка) — функция возвращает 1
# с явной ошибкой. Молчаливый fallback на устаревшие значения из init-файла
# создал бы split-brain: сервер живёт по новому awg0.conf, а regen выпускал
# бы клиентам старые J*/S*/H*. Это именно тот класс проблем, который
# elvaleto и Klavishnik сообщили в Discussion #38.
#
# Init-файл используется для AWG параметров ТОЛЬКО когда live server config
# вообще отсутствует — это путь bootstrap первой установки, когда awg0.conf
# ещё не записан, а generate_awg_params уже сохранил значения в init.
load_awg_params() {
    # 1. Базовые настройки из init (всегда, для не-AWG ключей)
    if [[ -f "$CONFIG_FILE" ]]; then
        safe_load_config "$CONFIG_FILE" || log_warn "Не удалось загрузить $CONFIG_FILE"
    fi

    # 2. AWG протокольные параметры
    # Если CLI задал --preset/--jc/--jmin/--jmax, параметры уже set через generate_awg_params.
    # Пропускаем перезагрузку из awg0.conf чтобы не перезатереть свежие значения.
    if [[ -n "${CLI_PRESET:-}" || -n "${CLI_JC:-}" || -n "${CLI_JMIN:-}" || -n "${CLI_JMAX:-}" ]]; then
        log_debug "CLI overrides заданы — AWG params из generate_awg_params, не из $SERVER_CONF_FILE"
    elif [[ -f "$SERVER_CONF_FILE" ]]; then
        # Live config существует — он единственный источник истины.
        # Никакого fallback на init: иначе получим split-brain.
        # Unset I1 перед парсингом: I1 опционален, если его нет в live conf —
        # не должен утечь stale из init-файла.
        unset AWG_I1
        if ! load_awg_params_from_server_conf; then
            log_error "В $SERVER_CONF_FILE отсутствуют обязательные AWG-параметры"
            log_error "(Jc/Jmin/Jmax/S1-S4/H1-H4). Не использую устаревшие значения"
            log_error "из $CONFIG_FILE, чтобы не создавать split-brain между сервером"
            log_error "и клиентскими конфигами. Восстановите [Interface] секцию в"
            log_error "$SERVER_CONF_FILE или восстановите awg0.conf из бэкапа."
            return 1
        fi
        log_debug "AWG параметры загружены из $SERVER_CONF_FILE (live config)"
    else
        # Bootstrap: server config ещё не существует (первая установка).
        # AWG_* должны быть в env через safe_load_config выше.
        log_debug "$SERVER_CONF_FILE не существует — использую AWG params из $CONFIG_FILE (bootstrap)"
    fi

    # 3. Проверка обязательных AWG 2.0 параметров
    local missing=0
    local param
    for param in AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4; do
        if [[ -z "${!param:-}" ]]; then
            log_error "Параметр $param не найден"
            missing=1
        fi
    done
    if [[ $missing -eq 1 ]]; then
        return 1
    fi
    return 0
}

# ==============================================================================
# Генерация ключей
# ==============================================================================

# Генерация пары ключей (приватный + публичный)
# generate_keypair <name>
# Результат: keys/<name>.private, keys/<name>.public
generate_keypair() {
    local name="$1"
    if [[ -z "$name" ]]; then
        log_error "generate_keypair: не указано имя"
        return 1
    fi
    mkdir -p "$KEYS_DIR" || {
        log_error "Ошибка создания $KEYS_DIR"
        return 1
    }

    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Ошибка генерации приватного ключа для '$name'"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Ошибка генерации публичного ключа для '$name'"
        return 1
    }

    echo "$privkey" > "$KEYS_DIR/${name}.private" || {
        log_error "Ошибка записи приватного ключа для '$name'"
        return 1
    }
    echo "$pubkey" > "$KEYS_DIR/${name}.public" || {
        log_error "Ошибка записи публичного ключа для '$name'"
        return 1
    }
    chmod 600 "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public" || {
        log_error "Ошибка установки прав на ключи '$name'"
        return 1
    }
    log_debug "Ключи для '$name' сгенерированы."
    return 0
}

# Генерация серверных ключей
# Результат: server_private.key, server_public.key в AWG_DIR
generate_server_keys() {
    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Ошибка генерации приватного ключа сервера"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Ошибка генерации публичного ключа сервера"
        return 1
    }

    echo "$privkey" > "$AWG_DIR/server_private.key" || return 1
    echo "$pubkey" > "$AWG_DIR/server_public.key" || return 1
    chmod 600 "$AWG_DIR/server_private.key" "$AWG_DIR/server_public.key" || {
        log_error "Ошибка установки прав на серверные ключи"
        return 1
    }
    log "Серверные ключи сгенерированы."
    return 0
}

# Гарантирует наличие $AWG_DIR/server_public.key.
# Если файла нет — пытается восстановить его из PrivateKey в awg0.conf
# (полезно для ручных установок вне нашего installer, где кеш серверного
# pubkey не создаётся на шаге 6). Возвращает 0 если ключ уже есть или
# успешно восстановлен, 1 если ни того ни другого.
_ensure_server_public_key() {
    [[ -f "$AWG_DIR/server_public.key" ]] && return 0

    [[ -f "$SERVER_CONF_FILE" ]] || {
        log_error "Не могу восстановить server_public.key — отсутствует $SERVER_CONF_FILE"
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
        log_error "Не найден PrivateKey в $SERVER_CONF_FILE — восстановить server_public.key невозможно"
        return 1
    fi
    mkdir -p "$AWG_DIR"
    local _tmp
    _tmp=$(awg_mktemp "$AWG_DIR") || return 1
    if ! echo "$_srv_priv" | awg pubkey > "$_tmp"; then
        rm -f "$_tmp"
        log_error "Не удалось вычислить публичный ключ через awg pubkey"
        return 1
    fi
    if ! mv -f "$_tmp" "$AWG_DIR/server_public.key"; then
        rm -f "$_tmp"
        log_error "Ошибка перемещения в $AWG_DIR/server_public.key"
        return 1
    fi
    chmod 600 "$AWG_DIR/server_public.key" 2>/dev/null || true
    log "server_public.key восстановлен из awg0.conf PrivateKey."
    return 0
}

# ==============================================================================
# Рендеринг конфигураций
# ==============================================================================

# Вычисление IPv6-адреса сервера (хост ::1) из туннельной подсети.
# Вход: PREFIX::/MASK (например fddd:2c4:2c4:2c4::/64).
# Выход: PREFIX::1/MASK (например fddd:2c4:2c4:2c4::1/64).
# Допущение: подсеть всегда оканчивается на ::/MASK (так формирует install-скрипт).
# Если завершающего ::/ нет - возвращаю вход без изменений (defensive fallback).
_derive_ipv6_server_addr() {
    local subnet="$1"
    if [[ "$subnet" == *"::/"* ]]; then
        echo "${subnet/::\//::1\/}"
    else
        echo "$subnet"
    fi
}

# Рендер серверного конфига AWG 2.0
# Использует глобальные переменные из load_awg_params()
# shellcheck disable=SC2154  # AWG_* vars loaded via load_awg_params -> source
render_server_config() {
    load_awg_params || return 1

    local server_privkey
    if [[ -f "$AWG_DIR/server_private.key" ]]; then
        server_privkey=$(cat "$AWG_DIR/server_private.key")
    else
        log_error "Приватный ключ сервера не найден: $AWG_DIR/server_private.key"
        return 1
    fi

    local nic
    nic=$(get_main_nic)
    if [[ -z "$nic" ]]; then
        log_error "Не удалось определить сетевой интерфейс."
        return 1
    fi

    local server_ip subnet_mask
    server_ip=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
    subnet_mask=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f2)

    # Адрес [Interface]: IPv4 всегда, IPv6 только при включённом туннеле.
    # Сервер берёт хост ::1 в туннельной IPv6-подсети.
    # IPV6_SUBNET имеет форму PREFIX::/MASK (по умолчанию fddd:2c4:2c4:2c4::/64),
    # поэтому адрес сервера получаю заменой завершающего ::/MASK на ::1/MASK.
    local address_line="${server_ip}/${subnet_mask}"
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" -eq 1 ]]; then
        local ipv6_subnet="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
        local ipv6_server_addr
        ipv6_server_addr=$(_derive_ipv6_server_addr "$ipv6_subnet")
        address_line="${address_line}, ${ipv6_server_addr}"
    fi

    local conf_dir
    conf_dir=$(dirname "$SERVER_CONF_FILE")
    mkdir -p "$conf_dir" || {
        log_error "Ошибка создания $conf_dir"
        return 1
    }

    # PostUp/PostDown правила для маршрутизации.
    # Три режима:
    #   role=entry          — FORWARD на $AWG_UPSTREAM_IFACE + TCPMSS clamp,
    #                         MASQUERADE делается на upstream-стороне
    #   egress=warp         — policy routing клиентской подсети в Cloudflare WARP
    #                         (wg-quick@wgcf с Table=off) через отдельную таблицу;
    #                         NIC остаётся для собственного egress ноды (SSH, apt)
    #   обычный режим       — FORWARD + MASQUERADE на основном NIC
    local postup postdown
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        local up_iface="${AWG_UPSTREAM_IFACE:-awg1}"
        postup="iptables -I FORWARD -i %i -o ${up_iface} -j ACCEPT"
        postup="${postup}; iptables -I FORWARD -i ${up_iface} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        postup="${postup}; iptables -t mangle -A FORWARD -o ${up_iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
        postdown="iptables -D FORWARD -i %i -o ${up_iface} -j ACCEPT"
        postdown="${postdown}; iptables -D FORWARD -i ${up_iface} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        postdown="${postdown}; iptables -t mangle -D FORWARD -o ${up_iface} -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
    elif [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
        local warp_iface="${AWG_WARP_IFACE:-wgcf}"
        local warp_tbl="${AWG_WARP_TABLE:-2408}"
        local warp_prio="${AWG_WARP_PRIORITY:-789}"
        # Клиенты на exit-ноде приходят из AWG_TUNNEL_SUBNET (после MASQUERADE
        # на entry в каскаде или напрямую в single-режиме). from-rule берёт
        # только их, собственный трафик сервера идёт через main таблицу.
        #
        # MASQUERADE на обоих исходящих путях:
        #   -o wgcf  — основной case, клиентский трафик заворачивается в WARP,
        #              src=10.9.0.2 превращается в src=172.16.0.2 (wgcf addr).
        #   -o $nic  — bypass случаи: в table ${warp_tbl} могут быть более
        #              специфичные маршруты `<CIDR> via <GW> dev $nic` (чтобы
        #              обойти WARP для YouTube/Google/banking/etc. — WARP IP
        #              у них бывает rate-limited). Longest-prefix-match такие
        #              пакеты уходят через $nic. Без MASQUERADE на $nic они
        #              выйдут с src=10.9.0.2 (приватный IP entry-ноды) →
        #              ответ никогда не вернётся. SNAT приводит src к IP VPS.
        postup="ip route replace default dev ${warp_iface} table ${warp_tbl}"
        postup="${postup}; ip rule add from ${server_ip%.*}.0/${subnet_mask} table ${warp_tbl} priority ${warp_prio}"
        postup="${postup}; iptables -I FORWARD -i %i -o ${warp_iface} -j ACCEPT"
        postup="${postup}; iptables -I FORWARD -i ${warp_iface} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        postup="${postup}; iptables -t nat -A POSTROUTING -o ${warp_iface} -j MASQUERADE"
        postup="${postup}; iptables -t nat -A POSTROUTING -s ${server_ip%.*}.0/${subnet_mask} -o ${nic} -j MASQUERADE"
        # TCPMSS clamp на ОБА направления (без -o): нужен и для awg0→wgcf, и
        # для bypass-пути awg0→eth0, и для обратного потока от bypass-назначений
        # к awg0 (MTU 1280). Без универсального clamp'а большие TCP-сегменты
        # от YouTube/Google (MSS 1460) терялись при forward из eth0 в awg0
        # (1280 MTU), PMTU discovery глушился ISP-шным ICMP-фильтром → видео
        # не грузились.
        postup="${postup}; iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
        # Триггерим awg-warp-bypass.service если он установлен (--warp-bypass
        # не none). awg-quick@awg0 перезапуск чистит table ${warp_tbl} (кроме
        # наших specific routes — мы не flush'им таблицу в PostDown), но
        # default dev wgcf переустанавливается в PostUp выше. bypass-маршруты
        # в table ${warp_tbl} выживают по умолчанию; сервис вызываем на
        # случай первого старта после boot или если их кто-то чистил руками.
        # --no-block не ждёт завершения — awg-quick не застрянет.
        postup="${postup}; systemctl --no-block start awg-warp-bypass.service 2>/dev/null || true"
        postdown="iptables -t mangle -D FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
        postdown="${postdown}; iptables -t nat -D POSTROUTING -s ${server_ip%.*}.0/${subnet_mask} -o ${nic} -j MASQUERADE"
        postdown="${postdown}; iptables -t nat -D POSTROUTING -o ${warp_iface} -j MASQUERADE"
        postdown="${postdown}; iptables -D FORWARD -i ${warp_iface} -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
        postdown="${postdown}; iptables -D FORWARD -i %i -o ${warp_iface} -j ACCEPT"
        postdown="${postdown}; ip rule del from ${server_ip%.*}.0/${subnet_mask} table ${warp_tbl} priority ${warp_prio}"
        postdown="${postdown}; ip route del default dev ${warp_iface} table ${warp_tbl}"
    else
        postup="iptables -I FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE"
        postdown="iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE"
    fi

    # IPv6 правила: при включённом IPv6-туннеле (--allow-ipv6-tunnel) ИЛИ при
    # не отключённом host-IPv6 (FORWARD внутри туннеля + MASQUERADE на публичный
    # интерфейс). MASQUERADE безвреден если у VPS нет native IPv6 - это no-op,
    # пока нет IPv6 default route, зато peer-to-peer внутри туннеля работает.
    # Использую тот же nic, что и IPv4 MASQUERADE (не хардкожу интерфейс).
    # Условие DISABLE_IPV6=0 сохранено для байт-в-байт совместимости с v5.14.x.
    # НО: на entry-ноде каскада и при WARP-egress трафик уходит через v4, поэтому
    # IPv6-forwarding на них осмысленно не настраивается (исключаем эти роли).
    if [[ ( "${ALLOW_IPV6_TUNNEL:-0}" -eq 1 || "${DISABLE_IPV6:-1}" -eq 0 ) \
          && "${AWG_ROLE:-single}" != "entry" && "${AWG_EGRESS:-direct}" != "warp" ]]; then
        postup="${postup}; ip6tables -I FORWARD -i %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE"
        postdown="${postdown}; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE"
    fi

    # Формируем конфиг через временный файл (атомарная запись).
    # temp создаём в каталоге итогового конфига, чтобы mv был атомарным rename
    # на той же ФС (а не cross-fs copy+unlink, если /tmp = tmpfs).
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; return 1; }

    cat > "$tmpfile" << EOF
[Interface]
PrivateKey = ${server_privkey}
Address = ${address_line}
MTU = ${AWG_MTU:-1280}
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

    # Добавляем I1 только если задан (CPS опционален)
    if [[ -n "${AWG_I1}" ]]; then
        echo "I1 = ${AWG_I1}" >> "$tmpfile"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Ошибка записи серверного конфига"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Серверный конфиг создан: $SERVER_CONF_FILE"
    return 0
}

# Допустимый диапазон MTU для AWG / WireGuard.
# Минимум 576 (классический минимум IPv4), максимум 9100 (verge на jumbo frame).
# Значения вне диапазона трактуются как ошибочные и игнорируются (fallback к 1280).
_validate_mtu() {
    local v="$1"
    [[ "$v" =~ ^[0-9]+$ ]] || return 1
    (( v >= 576 && v <= 9100 )) || return 1
    return 0
}

# Извлечение MTU из секции [Interface] серверного awg0.conf (если файл существует).
# Печатает целое число в stdout, либо ничего если MTU не найден / файл недоступен.
# Last-wins: если в [Interface] несколько строк MTU = ..., возвращается последняя
# (так же как awg-quick применяет последнее присвоение).
# Используется render_client_config для синхронизации MTU клиента с сервером
# (баг v5.14.0: ручная правка MTU в awg0.conf не подхватывалась regen-ом).
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

# Рендер клиентского конфига AWG 2.0
# render_client_config <name> <client_ip> <client_privkey> <server_pubkey> <endpoint> <port> [client_ipv6]
#
# client_ipv6 (необязательный, 7-й аргумент): IPv6-адрес клиента без префикса
# длины (например fddd:2c4:2c4:2c4::5). Если непустой и ALLOW_IPV6_TUNNEL=1:
#   - Address = <ipv4>/32, <ipv6>/128
#   - AllowedIPs (зеркалю IPv4 routing mode в IPv6, intent-mirroring):
#       full tunnel (ALLOWED_IPS=0.0.0.0/0): + ::/0 (native) или + <IPV6_SUBNET> (no-native)
#       split tunnel (кастомный ALLOWED_IPS): IPv4-список БЕЗ изменений + ТОЛЬКО <IPV6_SUBNET>,
#         НИКОГДА ::/0 - нет IPv6 split-list, нельзя угонять весь IPv6 (ломает split-tunnel).
# Если пустой (legacy-клиент): Address = <ipv4>/32, AllowedIPs без изменений.
render_client_config() {
    local name="$1"
    local client_ip="$2"
    local client_privkey="$3"
    local server_pubkey="$4"
    local endpoint="$5"
    local port="$6"
    local client_ipv6="${7:-}"

    load_awg_params || return 1

    local conf_file="$AWG_DIR/${name}.conf"
    local allowed_ips
    if [[ -n "$client_ipv6" ]]; then
        # Dual-stack: зеркалю IPv4 routing intent в IPv6.
        # full tunnel (IPv4=0.0.0.0/0) -> ::/0 (native) или tunnel-ULA (no-native).
        # split tunnel (кастомный ALLOWED_IPS) -> IPv4-split AS-IS + ТОЛЬКО tunnel-ULA,
        # никогда ::/0 (нет IPv6 split-list, нельзя угонять весь IPv6).
        local ipv4_part ipv6_part
        ipv4_part="${ALLOWED_IPS:-0.0.0.0/0}"
        if [[ "$ipv4_part" == "0.0.0.0/0" && "${SERVER_HAS_NATIVE_IPV6:-0}" == "1" ]]; then
            ipv6_part="::/0"
        else
            ipv6_part="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
        fi
        # Защитный de-dup: ALLOWED_IPS по конструкции IPv4-only, но не дублирую
        # ipv6_part если он уже присутствует токеном в списке.
        case ",${ipv4_part// /}," in
            *",${ipv6_part},"*) allowed_ips="$ipv4_part" ;;
            *)                  allowed_ips="${ipv4_part}, ${ipv6_part}" ;;
        esac
    else
        allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
    fi

    # DNS + AllowedIPs для режима AmneziaDNS=on.
    # 1) DNS: отдаём tunnel-gateway IP (напр. 10.9.9.1), там живёт наш dnsmasq.
    #    Клиент Amnezia VPN автоматически использует его как dns1, а в сайт-
    #    листе (split tunneling) DNS для «в обход VPN» имён резолвится локально
    #    на устройстве → сайт видит реальный IP пользователя.
    # 2) AllowedIPs: обязан быть РОВНО "0.0.0.0/0, ::/0" (с пробелом!). Иначе
    #    гейт в Amnezia-клиенте (servers_model.cpp::isDefaultServerDefault-
    #    ContainerHasSplitTunneling, dev-ветка, строки 837-863) сработает:
    #    любой более конкретный AllowedIPs клиент интерпретирует как «сервер
    #    уже делает split tunneling сам» и отключает свой UI с тостом
    #    «Default server does not support split tunneling function».
    #    Route-all в клиенте — это НЕ про «весь трафик в VPN по факту»,
    #    а про «доверяй клиенту самому решать что куда роутить через UI
    #    site-list». Сайты из bypass-списка клиент снимет с маршрута
    #    динамически, через резолв в dnsmasq и NotAllowedIPs.
    # Иначе (amnezia-dns=off): DNS=1.1.1.1, AllowedIPs из ALLOWED_IPS.
    local client_dns="1.1.1.1"
    if [[ "${AWG_AMNEZIA_DNS:-off}" == "on" && -n "${AWG_TUNNEL_SUBNET:-}" ]]; then
        client_dns=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
        [[ -z "$client_dns" ]] && client_dns="1.1.1.1"
        allowed_ips="0.0.0.0/0, ::/0"
    fi

    # MTU: приоритет server awg0.conf > AWG_MTU из awgsetup_cfg.init > 1280 fallback.
    # Server config - источник правды для уже работающего сервера: пользователь
    # мог поправить MTU в /etc/amnezia/amneziawg/awg0.conf руками, и regen должен
    # это подхватить (MyAI-sdge, Discussion #38). Невалидные значения (вне 576-9100)
    # на любом этапе откатываются к 1280.
    local mtu
    mtu=$(_extract_mtu_from_server_conf) || mtu=""
    if [[ -z "$mtu" ]]; then
        if _validate_mtu "${AWG_MTU:-}"; then
            mtu="$AWG_MTU"
        else
            mtu=1280
        fi
    fi

    # temp в каталоге клиентского конфига ($AWG_DIR) -> mv = атомарный rename.
    local tmpfile
    tmpfile=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp"; return 1; }

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

    if [[ -n "${AWG_I1}" ]]; then
        echo "I1 = ${AWG_I1}" >> "$tmpfile"
    fi

    cat >> "$tmpfile" << EOF

[Peer]
PublicKey = ${server_pubkey}
EOF
    # PresharedKey — опциональный дополнительный слой поверх AWG 2.0
    # обфускации (включается через `manage add --psk`). Должен совпадать
    # в server peer и client [Peer].
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
        log_error "Ошибка записи конфига клиента '$name'"
        return 1
    fi
    chmod 600 "$conf_file"
    log_debug "Конфиг для '$name' создан: $conf_file"
    return 0
}

# ==============================================================================
# Применение конфигурации (syncconf)
# ==============================================================================

# Применение изменений конфигурации
# Аргументы: [iface=awg0] — имя интерфейса (для multi-hop: awg1 и т.п.)
# AWG_SKIP_APPLY=1: пропустить apply (для batch-автоматизации)
# AWG_APPLY_MODE=syncconf|restart: режим применения (конфиг или --apply-mode CLI)
# flock на .awg_apply.lock: защита от параллельных вызовов
# shellcheck disable=SC2120  # iface — опциональный позиционный аргумент (multi-hop awg1)
apply_config() {
    local iface="${1:-awg0}"
    # Пропуск apply (AWG_SKIP_APPLY=1 manage add/remove ...)
    if [[ "${AWG_SKIP_APPLY:-0}" == "1" ]]; then
        log_debug "apply_config пропущен (AWG_SKIP_APPLY=1)."
        return 0
    fi

    # Межпроцессная блокировка apply_config
    local apply_lockfile="${AWG_DIR}/.awg_apply.lock"
    local apply_fd
    exec {apply_fd}>"$apply_lockfile"
    if ! flock -x -w 120 "$apply_fd"; then
        log_warn "Не удалось получить блокировку apply_config."
        exec {apply_fd}>&-
        return 1
    fi

    local rc=0

    if [[ "${AWG_APPLY_MODE:-syncconf}" == "restart" ]]; then
        log "Перезапуск сервиса ${iface} (apply-mode=restart)..."
        systemctl restart "awg-quick@${iface}" 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Ошибка перезапуска ${iface}."
        exec {apply_fd}>&-
        return $rc
    fi

    local strip_out
    strip_out=$(timeout 10 awg-quick strip "${iface}" 2>/dev/null) || {
        log_warn "awg-quick strip ${iface} не удался или timeout, использую полный перезапуск."
        systemctl restart "awg-quick@${iface}" 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Ошибка перезапуска ${iface}."
        exec {apply_fd}>&-
        return $rc
    }
    echo "$strip_out" | timeout 10 awg syncconf "${iface}" /dev/stdin 2>/dev/null || {
        log_warn "awg syncconf ${iface} не удался или timeout, использую полный перезапуск."
        systemctl restart "awg-quick@${iface}" 2>/dev/null; rc=$?
        [[ $rc -ne 0 ]] && log_warn "Ошибка перезапуска ${iface}."
        exec {apply_fd}>&-
        return $rc
    }
    log_debug "Конфигурация ${iface} применена (syncconf)."
    exec {apply_fd}>&-
    return 0
}

# ==============================================================================
# Multi-hop (каскад): upstream-туннель для role=entry
# ==============================================================================
#
# Логика: на entry-ноде поднимается второй интерфейс (по умолчанию awg1), который
# является клиентом к вышестоящему exit-серверу. Трафик клиентов (из
# $AWG_TUNNEL_SUBNET) заворачивается в этот интерфейс через policy routing:
#
#   Table=<N>       — awg-quick кладёт маршруты из AllowedIPs в таблицу N вместо
#                     main (не затрагивая egress самой entry-ноды)
#   FwMark=<mark>   — отличается от 0xca6c (дефолт wg-quick) чтобы избежать
#                     коллизии с policy-рулзами awg0
#   ip rule from <subnet> table N  — направляет в каскад только клиентские пакеты,
#                                    собственный трафик entry (SSH, keepalive
#                                    awg1) уходит через main таблицу
#   MASQUERADE -o %i — перекрывает src клиента (10.X.X.X) на awg1-IP entry-ноды,
#                     иначе exit-сервер отбросит пакет по AllowedIPs-проверке
#
# Совпадение obfuscation params между awg1 (entry) и awg0 (exit) — обязательное
# условие каскада, но S/H/I могут отличаться от клиентского профиля awg0.
#
# Защита от command injection: извлекаемые из upstream-конфига значения (ключи,
# IP, Endpoint) проходят через allowlist-регексп, потом интерполируются в файл
# через awg_mktemp + mv, никогда не через eval.

# Проверка имени интерфейса (защита от injection в systemctl/iptables)
_validate_iface_name() {
    local n="$1"
    [[ "$n" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]]
}

# Извлечение значения ключа из секции [Interface] или [Peer] upstream-конфига.
# _extract_upstream_field <file> <section: Interface|Peer> <key>
# Пишет значение в stdout, возвращает 1 если не найдено.
_extract_upstream_field() {
    local f="$1" sect="$2" key="$3"
    [[ -f "$f" ]] || return 1
    awk -v sect="$sect" -v key="$key" '
        /^\[/ { in_sect = ($0 == "[" sect "]"); next }
        in_sect && $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
            sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "")
            sub("[[:space:]]+$", "")
            print; exit
        }
    ' "$f"
}

# Формирование и запись конфига upstream-интерфейса (awg1) для каскада.
# Ожидает env:
#   AWG_UPSTREAM_CONF     — путь к .conf от manage add (на exit-ноде)
#   AWG_UPSTREAM_IFACE    — имя интерфейса (по умолчанию awg1)
#   AWG_UPSTREAM_TABLE    — номер routing table (по умолчанию 123)
#   AWG_UPSTREAM_FWMARK   — fwmark (по умолчанию 0xca6d, не 0xca6c как у wg-quick)
#   AWG_UPSTREAM_PRIORITY — приоритет ip rule (по умолчанию 456)
#   AWG_TUNNEL_SUBNET     — клиентская подсеть для from-rule
render_upstream_config() {
    local src="${AWG_UPSTREAM_CONF:-}"
    local iface="${AWG_UPSTREAM_IFACE:-awg1}"
    local tbl="${AWG_UPSTREAM_TABLE:-123}"
    local fwmark="${AWG_UPSTREAM_FWMARK:-0xca6d}"
    local prio="${AWG_UPSTREAM_PRIORITY:-456}"
    local client_subnet="${AWG_TUNNEL_SUBNET:-}"

    if [[ -z "$src" || ! -f "$src" ]]; then
        log_error "render_upstream_config: AWG_UPSTREAM_CONF не задан или файл не найден: '$src'"
        return 1
    fi
    if ! _validate_iface_name "$iface"; then
        log_error "render_upstream_config: недопустимое имя интерфейса '$iface'"
        return 1
    fi
    if ! [[ "$tbl" =~ ^[0-9]+$ && "$tbl" -ge 1 && "$tbl" -le 4294967295 ]]; then
        log_error "render_upstream_config: недопустимый Table='$tbl'"
        return 1
    fi
    if ! [[ "$fwmark" =~ ^(0x[0-9a-fA-F]{1,8}|[0-9]+)$ ]]; then
        log_error "render_upstream_config: недопустимый FwMark='$fwmark'"
        return 1
    fi
    if ! [[ "$prio" =~ ^[0-9]+$ ]]; then
        log_error "render_upstream_config: недопустимый priority='$prio'"
        return 1
    fi
    if [[ -z "$client_subnet" ]]; then
        log_error "render_upstream_config: AWG_TUNNEL_SUBNET не задан"
        return 1
    fi

    # Извлекаем поля из upstream-конфига
    local u_priv u_addr u_pub u_psk u_endpoint u_keepalive
    local u_jc u_jmin u_jmax u_s1 u_s2 u_s3 u_s4 u_h1 u_h2 u_h3 u_h4 u_i1
    u_priv=$(_extract_upstream_field "$src" Interface PrivateKey)
    u_addr=$(_extract_upstream_field "$src" Interface Address)
    u_jc=$(_extract_upstream_field   "$src" Interface Jc)
    u_jmin=$(_extract_upstream_field "$src" Interface Jmin)
    u_jmax=$(_extract_upstream_field "$src" Interface Jmax)
    u_s1=$(_extract_upstream_field   "$src" Interface S1)
    u_s2=$(_extract_upstream_field   "$src" Interface S2)
    u_s3=$(_extract_upstream_field   "$src" Interface S3)
    u_s4=$(_extract_upstream_field   "$src" Interface S4)
    u_h1=$(_extract_upstream_field   "$src" Interface H1)
    u_h2=$(_extract_upstream_field   "$src" Interface H2)
    u_h3=$(_extract_upstream_field   "$src" Interface H3)
    u_h4=$(_extract_upstream_field   "$src" Interface H4)
    u_i1=$(_extract_upstream_field   "$src" Interface I1)
    u_pub=$(_extract_upstream_field      "$src" Peer PublicKey)
    u_psk=$(_extract_upstream_field      "$src" Peer PresharedKey)
    u_endpoint=$(_extract_upstream_field "$src" Peer Endpoint)
    u_keepalive=$(_extract_upstream_field "$src" Peer PersistentKeepalive)

    if [[ -z "$u_priv" || -z "$u_addr" || -z "$u_pub" || -z "$u_endpoint" ]]; then
        log_error "render_upstream_config: $src не содержит обязательных полей"
        log_error "  (Interface.PrivateKey/Address, Peer.PublicKey/Endpoint)"
        return 1
    fi
    # Все 11 AWG 2.0 полей должны быть в upstream-конфиге (иначе хендшейк упадёт)
    local f miss=0
    for f in u_jc u_jmin u_jmax u_s1 u_s2 u_s3 u_s4 u_h1 u_h2 u_h3 u_h4; do
        if [[ -z "${!f}" ]]; then
            log_error "render_upstream_config: $src отсутствует ${f#u_}"
            miss=1
        fi
    done
    (( miss == 0 )) || return 1

    # Запрещаем newline/CR/quotes в извлечённых значениях — защита от injection
    # в выходной файл конфига через подделанный upstream .conf
    for f in u_priv u_addr u_pub u_psk u_endpoint u_keepalive \
             u_jc u_jmin u_jmax u_s1 u_s2 u_s3 u_s4 u_h1 u_h2 u_h3 u_h4 u_i1; do
        local v="${!f}"
        if [[ "$v" == *$'\n'* || "$v" == *$'\r'* || "$v" == *\'* || "$v" == *\"* ]]; then
            log_error "render_upstream_config: подозрительные символы в ${f#u_}, отклонено"
            return 1
        fi
    done

    # Address в клиентском конфиге — a.b.c.d/32, оставляем как есть; если /24
    # попал из ручного примера — приводим к /32
    if [[ "$u_addr" =~ ^([0-9.]+)/([0-9]+)$ ]]; then
        u_addr="${BASH_REMATCH[1]}/32"
    fi

    local out_conf
    out_conf="$(dirname "$SERVER_CONF_FILE")/${iface}.conf"

    local conf_dir
    conf_dir=$(dirname "$out_conf")
    mkdir -p "$conf_dir" || { log_error "Ошибка создания $conf_dir"; return 1; }

    local tmpfile
    tmpfile=$(awg_mktemp) || { log_error "Ошибка mktemp"; return 1; }

    {
        echo "[Interface]"
        echo "PrivateKey = ${u_priv}"
        echo "Address = ${u_addr}"
        echo "MTU = 1380"
        echo "Table = ${tbl}"
        echo "FwMark = ${fwmark}"
        echo "PostUp = ip rule add from ${client_subnet%/*}/${client_subnet##*/} table ${tbl} priority ${prio}"
        echo "PostUp = iptables -t nat -A POSTROUTING -o %i -j MASQUERADE"
        echo "PreDown = ip rule del from ${client_subnet%/*}/${client_subnet##*/} table ${tbl} priority ${prio}"
        echo "PreDown = iptables -t nat -D POSTROUTING -o %i -j MASQUERADE"
        echo "Jc = ${u_jc}"
        echo "Jmin = ${u_jmin}"
        echo "Jmax = ${u_jmax}"
        echo "S1 = ${u_s1}"
        echo "S2 = ${u_s2}"
        echo "S3 = ${u_s3}"
        echo "S4 = ${u_s4}"
        echo "H1 = ${u_h1}"
        echo "H2 = ${u_h2}"
        echo "H3 = ${u_h3}"
        echo "H4 = ${u_h4}"
        [[ -n "$u_i1" ]] && echo "I1 = ${u_i1}"
        echo ""
        echo "[Peer]"
        echo "PublicKey = ${u_pub}"
        [[ -n "$u_psk" ]] && echo "PresharedKey = ${u_psk}"
        echo "Endpoint = ${u_endpoint}"
        echo "AllowedIPs = 0.0.0.0/0"
        echo "PersistentKeepalive = ${u_keepalive:-25}"
    } > "$tmpfile"

    if ! mv "$tmpfile" "$out_conf"; then
        rm -f "$tmpfile"
        log_error "Ошибка записи upstream-конфига $out_conf"
        return 1
    fi
    chmod 600 "$out_conf"
    log "Upstream-интерфейс ${iface} записан: $out_conf (table=${tbl}, fwmark=${fwmark})"
    return 0
}

# ==============================================================================
# WARP egress: вывод клиентского трафика через Cloudflare WARP
# ==============================================================================
#
# Используется на role=exit / role=single когда пользователь хочет чтобы
# внешние сайты видели IP Cloudflare вместо IP VPS. Реализация:
#
#   1. wgcf скачивается с github.com/ViRb3/wgcf (релизы с готовыми бинарями
#      под amd64/arm64/armv7). TLS-проверка curl, SHA256-пин НЕ делаем —
#      релизы wgcf подписаны автором и меняются часто; SHA потерял бы смысл.
#   2. wgcf register создаёт Cloudflare-аккаунт бесплатного WARP (account.toml).
#   3. wgcf generate собирает wg-quick-конфиг с реальными ключами аккаунта.
#   4. Патчим конфиг: Table=off (НЕ трогаем дефолтный маршрут хоста — иначе SSH
#      отвалится), убираем DNS=... (иначе resolv.conf перепишется на WARP).
#   5. Включаем wg-quick@wgcf — поднимется wgcf интерфейс, маршрутов в main
#      таблицу не добавится благодаря Table=off.
#
# Конкретные iptables/ip rule правила для заворота клиентов в wgcf ставятся
# в PostUp/PostDown самого awg0 (см. render_server_config, ветка AWG_EGRESS=warp).
# Эта функция готовит только wgcf-side.

# Скачать бинарь wgcf с GitHub Releases для текущей архитектуры.
# Идемпотентно: если /usr/local/bin/wgcf уже есть — ничего не делает.
_download_wgcf_binary() {
    if command -v wgcf >/dev/null 2>&1; then
        log_debug "wgcf уже установлен: $(command -v wgcf)"
        return 0
    fi
    local arch url=""
    case "$(uname -m)" in
        x86_64|amd64)   arch="amd64" ;;
        aarch64|arm64)  arch="arm64" ;;
        armv7l|armv7)   arch="armv7" ;;
        *) log_error "Архитектура $(uname -m) не поддерживается wgcf"; return 1 ;;
    esac

    # Стратегия 1 (основная): HTTP-редирект `/releases/latest` → `/releases/tag/vX.Y.Z`.
    # Не требует GitHub API, не имеет anonymous rate-limit (60 req/hour),
    # устойчив к изменениям формата JSON-ответа API. curl -w '%{redirect_url}'
    # отдаёт первый target Location, без следования всей цепочки.
    local redirect tag
    redirect=$(curl -sI -o /dev/null -w '%{redirect_url}' \
               --max-time 15 \
               https://github.com/ViRb3/wgcf/releases/latest 2>/dev/null)
    tag=$(echo "$redirect" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+')
    if [[ -n "$tag" ]]; then
        url="https://github.com/ViRb3/wgcf/releases/download/${tag}/wgcf_${tag#v}_linux_${arch}"
        log_debug "wgcf версия определена через HTTP-редирект: $tag"
    fi

    # Стратегия 2 (fallback): GitHub API — на случай если releases/latest
    # не редиректит (обновление структуры github.com и т.п.). Может упасть
    # с 403 rate-limit для анонимов.
    if [[ -z "$url" ]]; then
        log_debug "HTTP-редирект не дал версию — пробую GitHub API fallback"
        url=$(curl -fsSL --max-time 15 https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null \
            | grep '"browser_download_url"' \
            | grep -E "linux_${arch}\"?$" \
            | head -1 \
            | sed -E 's/.*"(https[^"]+)".*/\1/')
    fi

    if [[ -z "$url" ]]; then
        log_error "Не удалось определить URL релиза wgcf (ни редирект, ни API не отработали)."
        log_error "  Проверь вручную:"
        log_error "    curl -sI https://github.com/ViRb3/wgcf/releases/latest | grep -i location"
        log_error "  Затем скачай wgcf_<VER>_linux_${arch} в /usr/local/bin/wgcf и chmod +x."
        return 1
    fi
    log "Скачивание wgcf: $url"
    if ! curl -fsSL --max-time 60 --retry 2 -o /usr/local/bin/wgcf "$url"; then
        log_error "Ошибка скачивания wgcf"
        rm -f /usr/local/bin/wgcf
        return 1
    fi
    chmod 0755 /usr/local/bin/wgcf || { log_error "chmod wgcf"; return 1; }
    log "wgcf установлен: /usr/local/bin/wgcf"
    return 0
}

# Зарегистрировать Cloudflare WARP-аккаунт и сгенерировать wgcf.conf с Table=off.
# Идемпотентно: если оба файла уже есть — только проверяет/исправляет Table=off.
setup_warp_egress() {
    local warp_conf="/etc/wireguard/wgcf.conf"
    local warp_account="/etc/wireguard/wgcf-account.toml"
    local marker="${AWG_DIR}/.wgcf_enabled_by_installer"

    if [[ "${AWG_EGRESS:-direct}" != "warp" ]]; then
        log_debug "setup_warp_egress: AWG_EGRESS != warp, пропуск"
        return 0
    fi

    _download_wgcf_binary || return 1

    mkdir -p /etc/wireguard || { log_error "mkdir /etc/wireguard"; return 1; }
    chmod 700 /etc/wireguard

    # Регистрация аккаунта (только если ещё нет account.toml).
    #
    # Источник истины — наличие непустого $warp_account, а НЕ exit code wgcf:
    # наблюдается что wgcf 2.2.30 `register --accept-tos` успешно создаёт
    # файл, но иногда возвращает non-zero (похоже на квирк версии). Если бы
    # мы полагались на exit code, код свалился бы в fallback `wgcf register`
    # без флага, который видит уже существующий файл и бросает
    # "existing account detected, refusing to overwrite" — и установка рушится
    # несмотря на то что регистрация фактически прошла.
    #
    # Логика: пробуем с --accept-tos (современный wgcf), затем, если файл
    # так и не появился — без флага (древние wgcf, ожидающие `y` на stdin).
    # stderr обоих попыток аккумулируется в один файл — чтобы не потерять
    # диагностику если обе реально упали (API блок, rate-limit, TLS).
    if [[ ! -f "$warp_account" ]]; then
        log "Регистрация WARP-аккаунта через wgcf..."
        local _wgcf_err
        _wgcf_err=$(awg_mktemp) || _wgcf_err="/tmp/wgcf_register.err.$$"

        ( cd /etc/wireguard && yes 2>/dev/null | wgcf register --accept-tos >/dev/null 2>>"$_wgcf_err" ) || true

        if [[ ! -s "$warp_account" ]]; then
            # --accept-tos не сработало (старый wgcf или реальная сетевая ошибка).
            # Пробуем legacy вариант без флага.
            ( cd /etc/wireguard && yes 2>/dev/null | wgcf register >/dev/null 2>>"$_wgcf_err" ) || true
        fi

        if [[ ! -s "$warp_account" ]]; then
            log_error "wgcf register не удался. Проверьте доступ к api.cloudflareclient.com"
            if [[ -s "$_wgcf_err" ]]; then
                log_error "wgcf stderr:"
                while IFS= read -r _ln; do log_error "  $_ln"; done < "$_wgcf_err"
            fi
            # Чистим пустой account.toml, если wgcf успел создать нулевой файл
            # и упасть — иначе следующий запуск увидит его и пропустит register.
            rm -f "$warp_account"
            return 1
        fi
        chmod 600 "$warp_account"
        log "WARP-аккаунт зарегистрирован."
    else
        log_debug "WARP-аккаунт уже зарегистрирован ($warp_account)"
    fi

    # Генерация wgcf.conf (только если нет)
    if [[ ! -f "$warp_conf" ]]; then
        log "Генерация WARP-конфига..."
        ( cd /etc/wireguard && rm -f wgcf-profile.conf && wgcf generate >/dev/null 2>&1 ) || {
            log_error "wgcf generate не удался"
            return 1
        }
        [[ -f /etc/wireguard/wgcf-profile.conf ]] || {
            log_error "wgcf generate не создал wgcf-profile.conf"
            return 1
        }
        mv /etc/wireguard/wgcf-profile.conf "$warp_conf"
        chmod 600 "$warp_conf"
    else
        log_debug "WARP-конфиг уже существует ($warp_conf)"
    fi

    # Патч: Table=off (обязательно, иначе default route хоста уходит в wgcf и
    # разрывает SSH) + убираем DNS=... (чтобы не перехватывало resolv.conf)
    sed -i '/^DNS[[:space:]]*=/d' "$warp_conf" || log_warn "sed DNS удаление"
    if ! grep -qE '^Table[[:space:]]*=[[:space:]]*off$' "$warp_conf"; then
        # Вставляем Table=off сразу после [Interface]
        local tmp
        tmp=$(awg_mktemp) || { log_error "mktemp"; return 1; }
        awk '/^\[Interface\]/{print; print "Table = off"; next} {print}' "$warp_conf" > "$tmp" \
            && mv "$tmp" "$warp_conf" \
            || { rm -f "$tmp"; log_error "не удалось добавить Table=off"; return 1; }
        chmod 600 "$warp_conf"
        log "Table=off добавлен в $warp_conf"
    fi

    # Стрипаем IPv6 из Address-строк. wgcf generate пишет
    #   Address = 172.16.0.2/32, 2606:4700:...:6d74/128
    # При DISABLE_IPV6=1 (наш дефолт) net.ipv6.conf.all.disable_ipv6 отключает
    # v6 на всех интерфейсах, и `ip -6 address add` в wg-quick падает с
    # "IPv6 is disabled on this device" — весь wg-quick@wgcf срывается.
    # Для нашей схемы v6 не нужен: policy routing `ip rule from <подсеть>`
    # на v4, клиентский AWG-трафик тоже v4 (см. render_server_config).
    # Идемпотентно: если Address уже v4-only, awk просто перевыписывает без
    # изменений.
    local v6tmp
    v6tmp=$(awg_mktemp) || { log_error "mktemp"; return 1; }
    # had_v6 живёт в awk-скрипте; его значение пробрасывается наружу через
    # exit code (10 если в Address был IPv6, 0 если не было)
    awk '
        /^[[:space:]]*Address[[:space:]]*=/ {
            sub(/^[[:space:]]*Address[[:space:]]*=[[:space:]]*/, "")
            n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
            out = ""
            for (i = 1; i <= n; i++) {
                p = parts[i]
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", p)
                if (p == "") continue
                # v4: содержит точку, без двоеточия; v6: есть двоеточие
                if (p ~ /:/) { had_v6 = 1; continue }
                out = (out ? out ", " : "") p
            }
            if (out != "") print "Address = " out
            # если v4 не было — строка вовсе выкидывается (деградируем в no-address,
            # что вряд ли случится — wgcf всегда даёт хоть один v4)
            next
        }
        { print }
        END { exit had_v6 ? 10 : 0 }
    ' "$warp_conf" > "$v6tmp"
    local _awk_rc=$?
    if [[ $_awk_rc -eq 10 ]]; then
        mv "$v6tmp" "$warp_conf" && chmod 600 "$warp_conf" \
            || { rm -f "$v6tmp"; log_error "не удалось записать $warp_conf без IPv6"; return 1; }
        log "IPv6 убран из Address в $warp_conf (host без v6)."
    elif [[ $_awk_rc -eq 0 ]]; then
        # v6 не было — просто оставляем исходный файл
        rm -f "$v6tmp"
    else
        rm -f "$v6tmp"
        log_error "awk на $warp_conf вернул rc=$_awk_rc"
        return 1
    fi

    # Маркер того что wgcf поднят нашим инсталлятором (нужен для uninstall —
    # чтобы не снести wgcf пользователя если он был до нас)
    touch "$marker" 2>/dev/null || log_warn "Не создан маркер $marker"

    # Upstream WireGuard module для wg-quick@wgcf. amneziawg — отдельный модуль,
    # его загрузка не подтягивает `wireguard`, без которого `ip link add dev
    # wgcf type wireguard` падает. На Ubuntu 24.04/Debian 13 модуль встроен в
    # ядро или доступен из linux-modules — modprobe обычно работает без доп.
    # пакетов. Не фейлим установку если modprobe упал: wg-quick сам попробует.
    if ! lsmod 2>/dev/null | grep -q -w wireguard; then
        log "Загрузка модуля wireguard (нужен для wg-quick@wgcf)..."
        modprobe wireguard 2>/dev/null || log_warn "modprobe wireguard не удался — wg-quick попробует сам."
    fi

    log "Запуск wg-quick@wgcf..."
    local _sc_err
    _sc_err=$(awg_mktemp) || _sc_err="/tmp/wgcf_systemctl.err.$$"
    if ! systemctl enable --now wg-quick@wgcf 2>"$_sc_err"; then
        log_error "systemctl enable --now wg-quick@wgcf упал"
        [[ -s "$_sc_err" ]] && while IFS= read -r _ln; do log_error "  $_ln"; done < "$_sc_err"
        # Дамп статуса сервиса для диагностики (ExecStart exit code, logs)
        systemctl status wg-quick@wgcf --no-pager -l 2>&1 | head -30 \
            | while IFS= read -r _ln; do log_error "status: $_ln"; done
        return 1
    fi

    # Ждём появления интерфейса (до 5 сек)
    local _i
    for _i in 1 2 3 4 5; do
        if ip link show wgcf >/dev/null 2>&1; then
            log "Интерфейс wgcf поднят."
            return 0
        fi
        sleep 1
    done
    log_error "Интерфейс wgcf так и не поднялся за 5 сек."
    log_error "systemctl status wg-quick@wgcf:"
    systemctl status wg-quick@wgcf --no-pager -l 2>&1 | head -30 \
        | while IFS= read -r _ln; do log_error "  $_ln"; done
    log_error "journalctl -u wg-quick@wgcf -n 20:"
    journalctl -u wg-quick@wgcf -n 20 --no-pager 2>&1 \
        | while IFS= read -r _ln; do log_error "  $_ln"; done
    return 1
}

# Установка WARP bypass (обход WARP для специфичных dst — YouTube/CDN/etc.).
# Пишет /usr/local/sbin/awg-warp-bypass.sh, systemd unit + timer, конфиг
# /etc/amnezia/amneziawg/warp-bypass.conf по значению AWG_WARP_BYPASS
# (comma-separated: youtube | custom:URL | custom:/path).
# Вызывается из step6 установщика ПОСЛЕ setup_warp_egress и ДО
# render_server_config — сервис должен уже существовать к моменту старта
# awg-quick@awg0 в step7 (его PostUp дёргает start --no-block).
setup_warp_bypass() {
    [[ "${AWG_EGRESS:-direct}" == "warp" ]] || return 0
    [[ "${AWG_WARP_BYPASS:-none}" != "none" ]] || return 0

    local conf_dir="/etc/amnezia/amneziawg"
    local bypass_conf="$conf_dir/warp-bypass.conf"
    local bypass_envfile="/etc/default/awg-warp-bypass"
    local bypass_script="/usr/local/sbin/awg-warp-bypass.sh"
    local bypass_svc="/etc/systemd/system/awg-warp-bypass.service"
    local bypass_timer="/etc/systemd/system/awg-warp-bypass.timer"
    local marker="${AWG_DIR}/.warp_bypass_enabled_by_installer"
    local warp_tbl="${AWG_WARP_TABLE:-2408}"

    mkdir -p "$conf_dir" /etc/default /usr/local/sbin || {
        log_error "setup_warp_bypass: mkdir"; return 1;
    }

    # dig нужен для резолва доменов (custom-источники могут быть доменами,
    # не только CIDR). Устанавливаем тихо если нет.
    if ! command -v dig >/dev/null 2>&1; then
        log "Установка dnsutils (dig) для резолва доменов в WARP bypass..."
        DEBIAN_FRONTEND=noninteractive apt install -y dnsutils >/dev/null 2>&1 \
            || log_warn "apt install dnsutils не удался; CIDR-источники работать будут, резолв доменов — нет."
    fi

    # 1. Конфиг: список источников по одному на строку.
    local tmp_conf
    tmp_conf=$(awg_mktemp) || { log_error "mktemp"; return 1; }
    {
        echo "# Источники WARP bypass (авто-генерация install_amneziawg.sh)"
        echo "# Один источник на строку. Допустимо:"
        echo "#   youtube                        — YouTube CIDR (touhidurrr/iplist-youtube)"
        echo "#   https://example.com/list.txt   — удалённый URL"
        echo "#   /path/to/local/list.txt        — локальный файл"
        echo "# Содержимое каждого источника — CIDR (1.2.3.4/24) или домен"
        echo "# (резолвится через @1.1.1.1), по одному на строку. dnsmasq-стиль"
        echo "# (full:, @tag, # комменты) поддерживается."
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
    } > "$tmp_conf"
    mv "$tmp_conf" "$bypass_conf" || { rm -f "$tmp_conf"; log_error "запись $bypass_conf"; return 1; }
    chmod 600 "$bypass_conf"

    # 2. Env-файл с номером table для скрипта и systemd unit.
    echo "WARP_TABLE=${warp_tbl}" > "$bypass_envfile"
    chmod 644 "$bypass_envfile"

    # 3. /usr/local/sbin/awg-warp-bypass.sh — ядро логики.
    # Heredoc в кавычках чтобы bash не интерполировал ${...} и $... здесь.
    cat > "$bypass_script" <<'EOF_AWG_WARP_BYPASS'
#!/bin/bash
# Apply WARP bypass routes: CIDRs or resolved domains → routing table via main NIC.
# Auto-installed by install_amneziawg.sh (--warp-bypass=...).
# Refresh via systemd timer + on awg-quick@awg0 PostUp.

set -o pipefail

CONFIG_FILE="/etc/amnezia/amneziawg/warp-bypass.conf"
ENV_FILE="/etc/default/awg-warp-bypass"
YOUTUBE_URL="https://raw.githubusercontent.com/touhidurrr/iplist-youtube/main/lists/cidr4.txt"
LOCK_FILE="/run/awg-warp-bypass.lock"

[[ -r "$ENV_FILE" ]] && . "$ENV_FILE"
WARP_TABLE="${WARP_TABLE:-2408}"

log() { printf '[awg-warp-bypass] %s\n' "$*"; }

[[ -f "$CONFIG_FILE" ]] || { log "no config at $CONFIG_FILE, exit"; exit 0; }

exec 200>"$LOCK_FILE"
flock -n 200 || { log "another instance running, exit"; exit 0; }

GW=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $3; exit}')
NIC=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
if [[ -z "$GW" || -z "$NIC" ]]; then
    log "no default route — cannot determine bypass egress, exit 1"
    exit 1
fi

log "bypass egress: via $GW dev $NIC, table $WARP_TABLE"

cidr_re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$'
ipv4_re='^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
added=0; failed_resolve=0

add_route() {
    ip route add "$1" via "$GW" dev "$NIC" table "$WARP_TABLE" 2>/dev/null && added=$(( added + 1 ))
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
        add_route "$e"
    else
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
            add_route "${ip}/32"
        done <<< "$ips"
    fi
}

process_content() {
    local content="$1"
    [[ -z "$content" ]] && return
    while IFS= read -r line; do
        process_entry "$line"
    done <<< "$content"
}

while IFS= read -r src; do
    src="${src%%#*}"
    src="$(echo "$src" | xargs)"
    [[ -z "$src" ]] && continue
    case "$src" in
        youtube)
            log "source: youtube (touhidurrr/iplist-youtube cidr4.txt)"
            if ! content=$(curl -fsSL --max-time 30 --retry 2 "$YOUTUBE_URL"); then
                log "fetch failed: $YOUTUBE_URL"
                continue
            fi
            process_content "$content"
            ;;
        http://*|https://*)
            log "source: URL $src"
            if ! content=$(curl -fsSL --max-time 30 --retry 2 "$src"); then
                log "fetch failed: $src"
                continue
            fi
            process_content "$content"
            ;;
        /*)
            log "source: file $src"
            if [[ ! -r "$src" ]]; then
                log "cannot read $src"
                continue
            fi
            content=$(cat "$src")
            process_content "$content"
            ;;
        *)
            log "unknown source spec: $src"
            ;;
    esac
done < "$CONFIG_FILE"

log "done: added $added routes; $failed_resolve domains failed to resolve"
EOF_AWG_WARP_BYPASS
    chmod 0755 "$bypass_script"

    # 4. systemd service — oneshot, без RemainAfterExit, чтобы каждый start
    # запускал ExecStart заново (нужно для timer + PostUp awg0 на restart).
    cat > "$bypass_svc" <<'EOF_BYPASS_SVC'
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

    # 5. systemd timer — раз в 6 часов обновляем (IP-диапазоны YouTube/CDN
    # и DNS-записи меняются заметно чаще чем мы перекатываем установщик).
    # Persistent=true: прогоняется после reboot если пропустили срабатывание.
    cat > "$bypass_timer" <<'EOF_BYPASS_TIMER'
[Unit]
Description=Refresh WARP bypass routes periodically

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
Persistent=true
Unit=awg-warp-bypass.service

[Install]
WantedBy=timers.target
EOF_BYPASS_TIMER

    # 6. Маркер для uninstall + активация.
    touch "$marker" 2>/dev/null || log_warn "маркер $marker не создан"
    systemctl daemon-reload
    systemctl enable --now awg-warp-bypass.timer >/dev/null 2>&1 \
        || log_warn "awg-warp-bypass.timer: enable --now не удался"
    systemctl start awg-warp-bypass.service >/dev/null 2>&1 \
        || log_warn "awg-warp-bypass.service: начальный запуск не удался"

    local src_count
    src_count=$(grep -c -v -E '^[[:space:]]*(#|$)' "$bypass_conf" 2>/dev/null || echo 0)
    log "WARP bypass настроен: $src_count источников (см. $bypass_conf), автообновление каждые 6 часов."
    return 0
}

# ==============================================================================
# AmneziaDNS (dnsmasq на tunnel-gateway)
# ==============================================================================
#
# Зачем. Стандартный режим AWG-клиента в Amnezia VPN отправляет весь трафик
# клиента через туннель (AllowedIPs=0.0.0.0/0), и весь split tunneling (site-based
# включение/исключение сайтов) доступен только когда клиент получил «vpn:// URI
# от полноценного Amnezia-сервера» — тот самый URI с `isThirdPartyConfig:false`
# и контейнером `amnezia-dns` внутри. Без этого флага UI Amnezia выключает
# site-list'ы: «Default server does not support split tunneling function».
#
# Что делаем. Поднимаем dnsmasq на tunnel-gateway ($AWG_TUNNEL_SUBNET первый
# адрес — напр. 10.8.0.1) и генерим клиентский vpn:// URI как «полноценный
# Amnezia-сервер» (isThirdPartyConfig:false + amnezia-dns контейнер). После
# этого UI клиента открывает сайт-лист: пользователь руками помечает
# `youtube.com`, `vk.com`, и т.д. как «в обход VPN» — и DNS-запросы по этим
# именам в клиенте резолвятся локально (не через наш dnsmasq), а трафик
# уходит мимо туннеля напрямую к ISP. Сайт видит реальный IP пользователя.
#
# Только role=single или role=entry. На exit-ноде смысла нет: exit не
# обслуживает AWG-клиентов напрямую, его DNS-сервер никто не получит в конфиге.
#
# Конфликт с systemd-resolved: stub listener на 127.0.0.53:53 НЕ трогаем
# (мы биндимся на tunnel-gateway IP, не на 0.0.0.0), — conflict только если
# кто-то поставил систему с DNSStubListener=на 0.0.0.0. На стандартной Ubuntu
# 24.04 stub слушает на 127.0.0.53, а мы на 10.x.x.1 — без коллизии. Но
# bind-dynamic обязателен чтобы dnsmasq не пытался забиндить wildcard и
# переживал ситуацию «awg0 поднимется позже» (см. комментарий у конфига).
setup_amnezia_dns() {
    [[ "${AWG_AMNEZIA_DNS:-off}" == "on" ]] || return 0

    case "${AWG_ROLE:-single}" in
        single|entry) ;;
        *) log_error "setup_amnezia_dns: role=${AWG_ROLE} (нужен single или entry)"; return 1 ;;
    esac

    if [[ -z "${AWG_TUNNEL_SUBNET:-}" ]]; then
        log_error "setup_amnezia_dns: AWG_TUNNEL_SUBNET не задан"
        return 1
    fi

    local server_ip
    server_ip=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
    if [[ -z "$server_ip" ]]; then
        log_error "setup_amnezia_dns: не удалось извлечь tunnel-gateway IP из '$AWG_TUNNEL_SUBNET'"
        return 1
    fi

    local conf_file="/etc/dnsmasq.d/amneziawg.conf"
    local marker="${AWG_DIR}/.amnezia_dns_enabled_by_installer"

    if ! command -v dnsmasq >/dev/null 2>&1; then
        log "Установка dnsmasq для AmneziaDNS..."
        DEBIAN_FRONTEND=noninteractive apt install -y dnsmasq >/dev/null 2>&1 \
            || { log_error "apt install dnsmasq не удался"; return 1; }
        # apt install dnsmasq может автозапустить сервис с дефолтной конфигой
        # (listen на 0.0.0.0:53), — тут же его гасим, настроим и поднимем заново.
        systemctl stop dnsmasq 2>/dev/null || true
    fi

    # systemd-resolved на Ubuntu 24.04 держит stub на 127.0.0.53 (не wildcard).
    # Мы биндимся на $server_ip, так что коллизии портов нет. Но на некоторых
    # минимальных образах DNSStubListener=yes + ListenAddress=0.0.0.0 → порт 53
    # занят целиком. В этом случае подкладываем drop-in с DNSStubListener=no.
    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        if ss -uln 2>/dev/null | awk '/:53 /{print $5}' | grep -qE '(^|[^0-9])(0\.0\.0\.0|\*):53$'; then
            log "systemd-resolved слушает на 0.0.0.0:53 — отключаю stub listener для AmneziaDNS."
            mkdir -p /etc/systemd/resolved.conf.d || {
                log_error "mkdir /etc/systemd/resolved.conf.d"; return 1;
            }
            cat > /etc/systemd/resolved.conf.d/amneziawg.conf <<'EOF'
# Отключает stub listener systemd-resolved на 0.0.0.0:53 ради порта 53 для dnsmasq.
# Управляется install_amneziawg.sh (--amnezia-dns=on); удаляется на uninstall.
[Resolve]
DNSStubListener=no
EOF
            systemctl restart systemd-resolved 2>/dev/null || log_warn "systemd-resolved restart не удался"
        fi
    fi

    mkdir -p "$(dirname "$conf_file")" || { log_error "mkdir $(dirname "$conf_file")"; return 1; }
    cat > "$conf_file" <<EOF
# AmneziaDNS — локальный резолвер для AWG-клиентов.
# Автогенерация install_amneziawg.sh (--amnezia-dns=on).
# Биндимся ТОЛЬКО на tunnel-gateway $server_ip, чтобы не конфликтовать с
# systemd-resolved stub на 127.0.0.53:53 и не торчать наружу.
# bind-dynamic (а не bind-interfaces!): dnsmasq стартует даже если awg0
# ещё не поднят (установщик делает setup_amnezia_dns в step6, а
# awg-quick@awg0 — только в step7; и на reboot порядок запуска тот же).
# bind-dynamic отслеживает появление/исчезновение адресов на интерфейсах
# и перепривязывается автоматически. bind-interfaces требует наличия IP
# на момент старта и падает с "Cannot assign requested address".
# upstream — Cloudflare 1.1.1.1 / 1.0.0.1 (без рекурсии внутрь).
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
    chmod 644 "$conf_file"

    # UFW: открываем 53/udp только на tunnel-gateway IP. На role=entry клиенты
    # приходят из AWG_TUNNEL_SUBNET через awg0 — правила INPUT на awg0 уже
    # подразумеваются (UFW default allow forward нас не трогает, dnsmasq
    # слушает INPUT на awg0-ip). Добавляем явное правило для ясности.
    if command -v ufw >/dev/null 2>&1; then
        ufw allow in on awg0 to "$server_ip" port 53 proto udp >/dev/null 2>&1 || true
        ufw allow in on awg0 to "$server_ip" port 53 proto tcp >/dev/null 2>&1 || true
    fi

    systemctl enable --now dnsmasq >/dev/null 2>&1 \
        || { log_error "dnsmasq: enable --now не удался (см. systemctl status dnsmasq / journalctl -u dnsmasq)"; return 1; }
    # Restart на случай если был запущен до нашей конфиги.
    systemctl restart dnsmasq >/dev/null 2>&1 || log_warn "dnsmasq: restart не удался"

    echo "gateway=$server_ip" > "$marker" 2>/dev/null || log_warn "Не удалось записать marker $marker"
    chmod 600 "$marker" 2>/dev/null || true

    log "AmneziaDNS настроен: dnsmasq слушает на ${server_ip}:53, upstream 1.1.1.1 / 1.0.0.1."
    return 0
}

# ==============================================================================
# Управление пирами
# ==============================================================================

# Получить следующий свободный IP в подсети
get_next_client_ip() {
    local subnet_base
    subnet_base=$(echo "${AWG_TUNNEL_SUBNET:-10.9.9.1/24}" | cut -d'/' -f1 | cut -d'.' -f1-3)

    # Ассоциативный массив для O(1) lookup
    declare -A used_set
    used_set["${subnet_base}.1"]=1
    if [[ -f "$SERVER_CONF_FILE" ]]; then
        while IFS= read -r ip; do
            used_set["$ip"]=1
        done < <(grep -oP 'AllowedIPs\s*=\s*\K[0-9.]+' "$SERVER_CONF_FILE")
    fi

    local i candidate
    for i in $(seq 2 254); do
        candidate="${subnet_base}.${i}"
        if [[ -z "${used_set[$candidate]+x}" ]]; then
            echo "$candidate"
            return 0
        fi
    done

    log_error "Нет свободных IP в подсети ${subnet_base}.0/24"
    return 1
}

# Получить IPv6-адрес клиента из его IPv4 (детерминировано по последнему октету).
# Используется только при ALLOW_IPV6_TUNNEL=1. Аллокация зеркальна IPv4:
# клиент 10.9.9.N получает fddd:2c4:2c4:2c4::N (тот же индекс N, /128).
# Аргумент: IPv4-адрес клиента, например 10.9.9.5 -> fddd:2c4:2c4:2c4::5
# Возвращает строку без префикса длины (только адрес).
#
# get_next_client_ipv6 <ipv4_addr>
get_next_client_ipv6() {
    local ipv4="$1"
    if [[ -z "$ipv4" ]]; then
        log_error "get_next_client_ipv6: не передан IPv4-адрес"
        return 1
    fi
    local n="${ipv4##*.}"
    local subnet="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
    local prefix="${subnet%%::*}"
    [[ "$prefix" == *:* ]] || { log_error "get_next_client_ipv6: IPV6_SUBNET не содержит :: (значение: $subnet)"; return 1; }
    echo "${prefix}::${n}"
    return 0
}

# Добавление [Peer] в серверный конфиг (атомарно через tmpfile + mv).
#
# КОНТРАКТ БЛОКИРОВКИ: вызывающий код ОБЯЗАН держать exclusive flock на
# ${AWG_DIR}/.awg_config.lock когда вызывает эту функцию. Эту блокировку
# берёт generate_client() — единственный текущий caller. Не вызывать
# add_peer_to_server напрямую без удержания lock'а.
#
# Почему inner flock здесь невозможен: bash flock не re-entrant между
# разными file descriptors на тот же файл. generate_client() открывает
# .awg_config.lock на свой fd и держит exclusive lock, а попытка
# открыть тот же файл на новый fd внутри add_peer_to_server и взять
# на нём exclusive lock приводит к самоблокировке (родительский lock
# виден как чужой). Контракт-based locking — единственный надёжный
# вариант для bash в этой ситуации. Re-entrant поведение возможно
# только если sub-функция использует TOТ ЖЕ fd что родитель (через
# inheritance), но это требует передачи fd как аргумента.
#
# add_peer_to_server <name> <pubkey> <client_ip> [client_ipv6]
#
# client_ipv6 (необязательный, 4-й аргумент): IPv6-адрес без префикса длины.
# Если непустой: AllowedIPs = <ipv4>/32, <ipv6>/128
# Если пустой (legacy): AllowedIPs = <ipv4>/32
add_peer_to_server() {
    local name="$1"
    local pubkey="$2"
    local client_ip="$3"
    local client_ipv6="${4:-}"

    if [[ -z "$name" || -z "$pubkey" || -z "$client_ip" ]]; then
        log_error "add_peer_to_server: недостаточно аргументов"
        return 1
    fi

    if grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Пир '$name' уже существует в конфиге"
        return 1
    fi

    # Добавляем пир через временный файл (атомарно).
    # temp в каталоге серверного конфига -> mv = атомарный rename на той же ФС.
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; return 1; }

    cp "$SERVER_CONF_FILE" "$tmpfile" || {
        rm -f "$tmpfile"
        log_error "Ошибка копирования серверного конфига"
        return 1
    }

    cat >> "$tmpfile" << EOF

[Peer]
#_Name = ${name}
PublicKey = ${pubkey}
EOF
    # PresharedKey — опционально, пишется если передан через CLIENT_PSK env.
    # Должен совпадать у server peer и client [Peer].
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
        log_error "Ошибка обновления серверного конфига"
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    log "Пир '$name' добавлен в серверный конфиг."
    return 0
}

# Удаление [Peer] из серверного конфига по имени (с блокировкой)
# remove_peer_from_server <name>
remove_peer_from_server() {
    local name="$1"

    if [[ -z "$name" ]]; then
        log_error "remove_peer_from_server: не указано имя"
        return 1
    fi

    # Межпроцессная блокировка
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига"
        exec {lock_fd}>&-
        return 1
    fi

    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Пир '$name' не найден в конфиге"
        exec {lock_fd}>&-
        return 1
    fi

    # temp в каталоге серверного конфига -> финальный mv = атомарный rename.
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; exec {lock_fd}>&-; return 1; }

    # Удаляем блок [Peer] содержащий #_Name = name
    # Логика: буферизуем каждый [Peer] блок, проверяем имя, выводим только если не совпадает
    awk -v target="$name" '
    BEGIN { buf=""; is_target=0 }
    /^\[Peer\]/ {
        # Вывести предыдущий буфер если он не target
        if (buf != "" && !is_target) printf "%s", buf
        buf = $0 "\n"
        is_target = 0
        next
    }
    /^\[/ && !/^\[Peer\]/ {
        # Любая другая секция — сбросить буфер
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
    ' "$SERVER_CONF_FILE" > "$tmpfile"

    # Нормализация: сжать множественные пустые строки в одну.
    # tmpclean - на той же ФС, что и tmpfile (mv tmpclean->tmpfile атомарен).
    local tmpclean
    tmpclean=$(awg_mktemp "$(dirname "$SERVER_CONF_FILE")") || { log_error "Ошибка mktemp"; exec {lock_fd}>&-; return 1; }
    if cat -s "$tmpfile" > "$tmpclean" 2>/dev/null; then
        mv "$tmpclean" "$tmpfile"
    else
        rm -f "$tmpclean"
    fi

    if ! mv "$tmpfile" "$SERVER_CONF_FILE"; then
        rm -f "$tmpfile"
        log_error "Ошибка обновления серверного конфига"
        exec {lock_fd}>&-
        return 1
    fi
    chmod 600 "$SERVER_CONF_FILE"
    exec {lock_fd}>&-
    log "Пир '$name' удалён из серверного конфига."
    return 0
}

# ==============================================================================
# Полный цикл работы с клиентом
# ==============================================================================

# Генерация QR-кода для клиента
# generate_qr <name>
generate_qr() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local png_file="$AWG_DIR/${name}.png"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Конфиг клиента '$name' не найден: $conf_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode не установлен, QR-код не создан для '$name'."
        return 1
    fi

    # C4: генерируем во временный файл и атомарно переносим (mv) - чтобы
    # прерывание qrencode не оставило частичный/битый PNG поверх рабочего.
    # awg_mktemp "$AWG_DIR" кладёт tmp в ту же папку (mv = атомарный rename на
    # одной ФС) И регистрирует его в общем cleanup-реестре, поэтому SIGKILL
    # между qrencode и mv не оставит осиротевший tmp.
    local tmp_png
    tmp_png=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp для QR '$name'"; return 1; }
    if ! qrencode -t png -o "$tmp_png" < "$conf_file"; then
        log_error "Ошибка генерации QR-кода для '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    chmod 600 "$tmp_png" 2>/dev/null
    if ! mv -f "$tmp_png" "$png_file"; then
        log_error "Ошибка сохранения QR-кода для '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    log_debug "QR-код для '$name' создан: $png_file"
    return 0
}

# Генерация vpn:// URI для импорта в Amnezia Client
# generate_vpn_uri <name>
generate_vpn_uri() {
    local name="$1"
    local conf_file="$AWG_DIR/${name}.conf"
    local uri_file="$AWG_DIR/${name}.vpnuri"

    if [[ ! -f "$conf_file" ]]; then
        log_error "Конфиг клиента '$name' не найден: $conf_file"
        return 1
    fi

    if ! command -v perl &>/dev/null; then
        log_warn "perl не найден, vpn:// URI не создан для '$name'."
        return 1
    fi

    if ! perl -MCompress::Zlib -MMIME::Base64 -e '1' 2>/dev/null; then
        log_warn "Perl модули Compress::Zlib/MIME::Base64 не найдены, vpn:// URI не создан."
        return 1
    fi

    load_awg_params || return 1

    local client_privkey client_ip client_ipv6 server_pubkey endpoint allowed_ips client_psk
    client_privkey=$(grep -oP 'PrivateKey\s*=\s*\K\S+' "$conf_file") || return 1
    # Извлекаем IPv4 из Address (первое поле до запятой, без /prefix).
    # Regex останавливается на цифрах и точках - не захватывает IPv6 при dual-stack.
    client_ip=$(awk '/^Address[[:space:]]*=/{
        sub(/^Address[[:space:]]*=[[:space:]]*/, "")
        sub(/\r$/, "")
        n = split($0, parts, /[[:space:]]*,[[:space:]]*/)
        sub(/\/[0-9]+$/, "", parts[1])
        print parts[1]; exit
    }' "$conf_file") || return 1
    # Извлекаем IPv6 из Address (второе поле, если присутствует), без /prefix.
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
    # PresharedKey — опциональный. awk вместо grep чтобы пустой результат
    # не считался ошибкой (grep -P без match → rc=1, нам это здесь не нужно).
    # Дополнительно срезаем CR (CRLF от Windows-редакторов) и хвостовые
    # пробелы — иначе они улетят в JSON psk_key и сломают handshake так же,
    # как полное отсутствие поля. Без psk_key в inner JSON AmneziaVPN импорт
    # vpn:// теряет PSK и handshake падает (issue #67, fix v5.11.4).
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
    # tr -d ' \r' — спирает пробелы И CR (на CRLF-конфигах '.+' жадно
    # затягивает \r в значение, что ломает JSON.allowed_ips).
    allowed_ips=$(grep -oP 'AllowedIPs\s*=\s*\K.+' "$conf_file" | tr -d ' \r') || allowed_ips="0.0.0.0/0"

    # MTU/PersistentKeepalive/DNS из .conf - могли быть изменены через manage modify.
    # Клиент Amnezia при импорте vpn:// использует структурные поля inner JSON
    # (awgConfigurator берёт mtu именно из структурного поля, не из embedded config),
    # поэтому хардкод рассинхронизировал бы их с .conf - тот же класс, что issue #67
    # (structured-поле psk_key было авторитетным).
    local mtu keepalive dns_line dns1 dns2
    mtu=$(grep -oP '^MTU\s*=\s*\K[0-9]+' "$conf_file" | head -n1); mtu="${mtu:-1280}"
    keepalive=$(grep -oP '^PersistentKeepalive\s*=\s*\K[0-9]+' "$conf_file" | head -n1); keepalive="${keepalive:-33}"
    dns_line=$(grep -oP '^DNS\s*=\s*\K.+' "$conf_file" | head -n1 | tr -d ' \r')
    dns1="${dns_line%%,*}"; dns1="${dns1:-1.1.1.1}"
    if [[ "$dns_line" == *,* ]]; then dns2="${dns_line#*,}"; dns2="${dns2%%,*}"; else dns2="$dns1"; fi

    # AmneziaDNS: режим «настоящего Amnezia-сервера» (isThirdPartyConfig:false
    # + amnezia-dns контейнер + dns1=tunnel-gateway). Активирует в клиенте UI
    # split tunneling по сайтам.
    # dns1/dns2 уже вычислены выше из .conf (уважая manage modify); здесь только
    # переопределяем их в adns=on режиме — НЕ затираем .conf-значения при adns=off.
    local amnezia_dns_flag="0"
    if [[ "${AWG_AMNEZIA_DNS:-off}" == "on" && -n "${AWG_TUNNEL_SUBNET:-}" ]]; then
        local _gw
        _gw=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
        if [[ -n "$_gw" ]]; then
            amnezia_dns_flag="1"
            dns1="$_gw"
            # dns2 оставляем публичный — fallback когда VPN не поднят или
            # клиент не успел получить маршрут к $_gw.
            dns2="1.1.1.1"
        fi
    fi

    local vpn_uri perl_err
    perl_err=$(awg_mktemp) || perl_err="/tmp/awg_perl_err.$$"
    # shellcheck disable=SC2016
    vpn_uri=$(perl -MCompress::Zlib -MMIME::Base64 -e '
        my ($conf_path, $h1,$h2,$h3,$h4, $jc,$jmin,$jmax,
            $s1,$s2,$s3,$s4, $i1, $port, $ep, $cip, $cipv6, $cpk, $spk, $aips, $psk,
            $mtu, $keepalive, $adns, $dns1, $dns2) = @ARGV;

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
        if ($i1 ne "") {
            my $ei1 = je($i1);
            $inner .= qq("I1":"$ei1","I2":"","I3":"","I4":"","I5":"",);
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
        # Контейнер: "amnezia-awg" → в Amnezia-Client классификаторе =
        # DockerContainer::Awg → label «AmneziaWG Legacy», site-based split
        # tunneling UI не появляется. "amnezia-awg2" → DockerContainer::Awg2
        # → label «AmneziaWG (version 2)», UI разблокируется. Оба контейнера
        # используют один protocol-key "awg" и одинаковый last_config —
        # разница только в лейблинге и в том, что Legacy-ветка отрубает UI.
        # Используем amnezia-awg2 когда просим Amnezia-режим (adns=1).
        my $cname = ($adns eq "1") ? "amnezia-awg2" : "amnezia-awg";
        my $containers = qq({"awg":{"isThirdPartyConfig":$is_tpc,"last_config":"$einner","port":"$port","protocol_version":"2","transport_proto":"udp"\},"container":"$cname"\});
        if ($adns eq "1") {
            # amnezia-dns контейнер — сигнал клиенту, что сервер понимает
            # split tunneling. dns1 получаем как tunnel-gateway IP.
            $containers .= qq(,{"dns":{},"container":"amnezia-dns"\});
        }
        my $outer = "{";
        $outer .= qq("containers":[$containers],);
        $outer .= qq("defaultContainer":"$cname",);
        $outer .= qq("description":"AWG Server",);
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
        "$AWG_I1" "$AWG_PORT" "$endpoint" \
        "$client_ip" "$client_ipv6" "$client_privkey" "$server_pubkey" "$allowed_ips" "$client_psk" \
        "$mtu" "$keepalive" "$amnezia_dns_flag" "$dns1" "$dns2" 2>"$perl_err"
    )

    if [[ -z "$vpn_uri" ]]; then
        log_warn "Ошибка генерации vpn:// URI для '$name'."
        [[ -s "$perl_err" ]] && log_warn "Perl: $(cat "$perl_err")"
        rm -f "$perl_err"
        return 1
    fi
    rm -f "$perl_err"

    # Пишем через tmp + atomic mv (как .conf/.png), чтобы обрыв записи не оставил
    # пустой/обрезанный .vpnuri поверх рабочего.
    local _uri_tmp
    _uri_tmp=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp для vpn:// URI '$name'"; return 1; }
    printf '%s\n' "$vpn_uri" > "$_uri_tmp" || { rm -f "$_uri_tmp"; log_error "Ошибка записи vpn:// URI для '$name'"; return 1; }
    chmod 600 "$_uri_tmp"
    if ! mv -f "$_uri_tmp" "$uri_file"; then
        rm -f "$_uri_tmp"
        log_error "Ошибка сохранения vpn:// URI для '$name'"
        return 1
    fi
    log_debug "vpn:// URI для '$name' создан: $uri_file"
    return 0
}

# Генерация QR-кода из vpn:// URI (для импорта в Amnezia VPN app Android/iOS/Desktop)
# generate_qr_vpnuri <name>
#
# Пишет через tmp в той же директории + atomic mv, чтобы при сбое qrencode
# или chmod пользователь никогда не увидел обрезанный `.vpnuri.png`:
# старая версия файла остаётся на месте, новая появляется только целиком.
generate_qr_vpnuri() {
    local name="$1"
    local uri_file="$AWG_DIR/${name}.vpnuri"
    local png_file="$AWG_DIR/${name}.vpnuri.png"
    local tmp_png

    if [[ ! -f "$uri_file" ]]; then
        log_error "vpn:// URI для '$name' не найден: $uri_file"
        return 1
    fi

    if ! command -v qrencode &>/dev/null; then
        log_warn "qrencode не установлен, QR vpn:// не создан для '$name'."
        return 1
    fi

    # tmp через awg_mktemp (общий cleanup-реестр + atomic mv в той же ФС).
    tmp_png=$(awg_mktemp "$AWG_DIR") || { log_error "Ошибка mktemp для QR vpn:// '$name'"; return 1; }

    # Флаги qrencode для длинных vpn:// URI с PSK (issue #72):
    #   -s 6  размер модуля 6 пикселей вместо дефолтных 3 - это и есть основной фикс.
    #         На дефолтном масштабе модули были слишком мелкими, чтобы камера iPhone
    #         различала их при сканировании PNG с экрана компьютера - отсюда ошибка 900
    #         ImportInvalidConfigError в AmneziaVPN iOS у @haritos90 в issue #72.
    #   -l L  низший уровень коррекции ошибок - это уже дефолт qrencode, фиксируем явно
    #         для защиты от смены дефолта в будущих версиях библиотеки.
    #   -m 4  стандартная тихая зона из 4 модулей - тоже дефолт, фиксируем явно.
    if ! qrencode -t png -l L -s 6 -m 4 -o "$tmp_png" < "$uri_file"; then
        log_error "Ошибка генерации QR vpn:// для '$name'"
        rm -f "$tmp_png"
        return 1
    fi

    if ! chmod 600 "$tmp_png"; then
        log_error "Не удалось выставить права 600 на $tmp_png"
        rm -f "$tmp_png"
        return 1
    fi

    if ! mv -f "$tmp_png" "$png_file"; then
        log_error "Ошибка сохранения QR vpn:// для '$name'"
        rm -f "$tmp_png"
        return 1
    fi
    log_debug "QR vpn:// для '$name' создан: $png_file"
    return 0
}

# Удаляет частично созданные артефакты клиента (ключи + .conf). Используется
# в early-error путях generate_client - C10: не оставлять orphan-ключи при сбое
# до коммита пира в серверный конфиг.
_rollback_client_artifacts() {
    rm -f "$KEYS_DIR/$1.private" "$KEYS_DIR/$1.public" "$AWG_DIR/$1.conf"
}

# Полный набор клиентских артефактов (conf/png/vpnuri/vpnuri.png + ключи).
# Единый список для `manage remove` и автоудаления истёкших, чтобы пути не
# расходились (раньше expiry-cleanup забывал .vpnuri.png). НЕ трогает expiry-метку
# и cron - это делает вызывающий (remove_client_expiry / rm "$efile").
_remove_client_files() {
    local name="$1"
    rm -f "$AWG_DIR/${name}.conf" "$AWG_DIR/${name}.png" \
        "$AWG_DIR/${name}.vpnuri" "$AWG_DIR/${name}.vpnuri.png" \
        "$KEYS_DIR/${name}.private" "$KEYS_DIR/${name}.public"
}

# Полный цикл создания клиента:
# keypair → next IP → client config → add peer → QR
# generate_client <name> [endpoint]
#
# Env var contract:
#   CLIENT_PSK — необязательный. Если установлен в "auto", генерирует
#     свежий PSK через `awg genpsk` и прописывает его и в серверный
#     [Peer], и в клиентский [Peer]. Если установлен в конкретное
#     значение (32-байт base64) — использует его без генерации. Если
#     пуст/не установлен — PSK не добавляется (default behaviour).
generate_client() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "generate_client: не указано имя"
        return 1
    fi

    # Загружаем параметры
    load_awg_params || return 1

    # Опциональный PresharedKey: "auto" → `awg genpsk`, иначе используем
    # переданное значение как есть. Пустое/unset → без PSK.
    if [[ "${CLIENT_PSK:-}" == "auto" ]]; then
        # --psk запрошен явно: при сбое awg genpsk НЕ деградируем молча в клиента
        # без PSK (это ослабило бы запрошенную безопасность). Fail-closed; здесь
        # ещё нет созданных артефактов (ключи/конфиг создаются ниже), откат не нужен.
        CLIENT_PSK=$(awg genpsk) || {
            log_error "awg genpsk не сработал - клиент с PresharedKey (--psk) НЕ создан. Повторите."
            return 1
        }
    fi

    # Межпроцессная блокировка: атомарность IP-аллокации + добавления пира
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 30 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига"
        exec {lock_fd}>&-
        return 1
    fi

    # C6: клиент не должен уже существовать. Проверяю ПОД локом, ДО генерации
    # ключей - иначе `add <существующее_имя>` молча перезатёр бы ключи живого
    # клиента (generate_keypair перезаписывает безусловно), а параллельный add
    # того же имени гонялся бы за перезапись.
    if [[ -e "$KEYS_DIR/${name}.private" || -e "$KEYS_DIR/${name}.public" || -e "$AWG_DIR/${name}.conf" ]]; then
        log_error "Клиент '$name' уже существует. Используйте 'remove' или другое имя."
        exec {lock_fd}>&-
        return 1
    fi

    # Генерация ключей. С этого момента любой ранний сбой обязан удалить уже
    # созданные ключи/conf (C10) через _rollback_client_artifacts.
    generate_keypair "$name" || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Следующий свободный IP
    local client_ip
    client_ip=$(get_next_client_ip) || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # IPv6-адрес клиента (при ALLOW_IPV6_TUNNEL=1)
    local client_ipv6=""
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" ]]; then
        client_ipv6=$(get_next_client_ipv6 "$client_ip") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
        log_debug "Выделен IPv6-адрес ${client_ipv6} для клиента ${name}"
    fi

    # Читаем ключи
    local client_privkey client_pubkey server_pubkey
    client_privkey=$(cat "$KEYS_DIR/${name}.private") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
    client_pubkey=$(cat "$KEYS_DIR/${name}.public") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Пытаемся восстановить server_public.key из awg0.conf если кеша нет
    # (поддержка ручных установок без installer-шага 6).
    _ensure_server_public_key || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key") || { _rollback_client_artifacts "$name"; exec {lock_fd}>&-; return 1; }

    # Endpoint: из аргумента → AWG_ENDPOINT (awgsetup_cfg.init) → curl до
    # внешних сервисов → локальный IP с сетевого интерфейса.
    # Последний fallback для LXC / сред без egress: может быть NAT-адресом,
    # поэтому предупреждаем пользователя в лог.
    if [[ -z "$endpoint" ]]; then
        endpoint="${AWG_ENDPOINT:-}"
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(get_server_public_ip)
    fi
    if [[ -z "$endpoint" ]]; then
        endpoint=$(_try_local_ip) && log_warn "Используется локальный IP сервера как Endpoint ('$endpoint') — curl до внешних сервисов не прошёл. Если сервер за NAT, поправьте Endpoint в клиентских .conf вручную."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Не удалось определить внешний IP сервера. Используйте --endpoint=IP"
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Конфиг клиента
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "${AWG_PORT}" "$client_ipv6" || {
        log_error "Откат: удаление артефактов '$name'"
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    }

    # Добавляем пир в серверный конфиг
    if ! add_peer_to_server "$name" "$client_pubkey" "$client_ip" "$client_ipv6"; then
        log_error "Откат: удаление артефактов '$name'"
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Освобождаем блокировку — пир записан, дальше некритичные операции
    exec {lock_fd}>&-

    # QR-код (необязательный, ошибка не фатальна)
    if ! generate_qr "$name"; then
        log_warn "QR-код не создан. Конфиг: $AWG_DIR/${name}.conf"
    fi

    # vpn:// URI и QR для Amnezia VPN app (необязательные).
    # QR vpn:// пробуем только если URI создан успешно — иначе читать нечего.
    if ! generate_vpn_uri "$name"; then
        log_warn "vpn:// URI не создан для '$name'."
    elif ! generate_qr_vpnuri "$name"; then
        log_warn "QR vpn:// не создан для '$name'."
    fi

    log "Клиент '$name' создан (IP: $client_ip)."
    return 0
}

# Перегенерация конфига и QR для существующего клиента
# regenerate_client <name> [endpoint]
#
# v5.11.0 A5.3: защищается блокировкой .awg_config.lock (сериализация
# с modify_client / remove и параллельными regen на том же имени) и
# проверяет возврат каждого sed -i при восстановлении пользовательских
# настроек — прежде молча игнорировались ошибки sed.
#
# Lock scope: держится только пока мутируется $AWG_DIR/${name}.conf.
# generate_qr / generate_vpn_uri / generate_qr_vpnuri вызываются ВНЕ lock
# как best-effort derived artifacts — если между sed-ом и QR-генерацией
# concurrent modify успеет изменить conf, QR может устареть на один такт.
# Также concurrent `manage remove <name>` может удалить клиента после
# release lock, и regen «воскресит» `.conf` / `.png` / `.vpnuri` /
# `.vpnuri.png` для уже удалённого peer-а (stale artefacts в $AWG_DIR).
# Это приемлемо: пользователь получит актуальное состояние на следующей
# операции (повторный `remove` или `regen`), и peer уже удалён из server-
# конфига — трафик через него не идёт. Включать QR/URI в lock дороже
# (lock на несколько секунд — блокирует другие клиенты) без выигрыша
# по целостности server-state.
regenerate_client() {
    local name="$1"
    local endpoint="${2:-}"

    if [[ -z "$name" ]]; then
        log_error "regenerate_client: не указано имя"
        return 1
    fi

    # Межпроцессная блокировка: защита от race с modify_client/remove и
    # параллельных regen на одном имени клиента.
    local lockfile="${AWG_DIR}/.awg_config.lock"
    local lock_fd
    exec {lock_fd}>"$lockfile"
    if ! flock -x -w 10 "$lock_fd"; then
        log_error "Не удалось получить блокировку конфига (другая операция выполняется)"
        exec {lock_fd}>&-
        return 1
    fi

    load_awg_params || { exec {lock_fd}>&-; return 1; }

    # Проверяем, что клиент существует в серверном конфиге
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Клиент '$name' не найден в серверном конфиге"
        exec {lock_fd}>&-
        return 1
    fi

    # Читаем приватный ключ клиента
    local client_privkey client_ip server_pubkey
    if [[ -f "$KEYS_DIR/${name}.private" ]]; then
        client_privkey=$(cat "$KEYS_DIR/${name}.private")
    elif [[ -f "$AWG_DIR/${name}.conf" ]]; then
        # Пробуем извлечь из существующего конфига
        client_privkey=$(sed -n 's/^PrivateKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
    fi

    if [[ -z "$client_privkey" ]]; then
        log_error "Приватный ключ клиента '$name' не найден"
        exec {lock_fd}>&-
        return 1
    fi

    # IP клиента из серверного конфига
    # Ищем блок [Peer] с #_Name = name, затем AllowedIPs
    # Для dual-stack: ips[1] = IPv4/32, ips[2] = IPv6/128 (если есть)
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
        log_error "IP клиента '$name' не найден в серверном конфиге"
        exec {lock_fd}>&-
        return 1
    fi

    # Auto-gen из awg0.conf если кеша нет (ручная установка)
    _ensure_server_public_key || { exec {lock_fd}>&-; return 1; }
    server_pubkey=$(cat "$AWG_DIR/server_public.key" 2>/dev/null) || {
        log_error "Публичный ключ сервера не найден"
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
        endpoint=$(_try_local_ip) && log_warn "Используется локальный IP сервера как Endpoint ('$endpoint') — curl до внешних сервисов не прошёл."
    fi
    if [[ -z "$endpoint" ]]; then
        log_error "Не удалось определить внешний IP сервера."
        exec {lock_fd}>&-
        return 1
    fi

    # Сохраняем пользовательские настройки из текущего .conf (modify)
    local current_dns="1.1.1.1" current_keepalive="33" current_allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
    if [[ -f "$AWG_DIR/${name}.conf" ]]; then
        local _v
        _v=$(sed -n 's/^DNS[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_dns="$_v"
        _v=$(sed -n 's/^PersistentKeepalive[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_keepalive="$_v"
        _v=$(sed -n '/^\[Peer\]/,$ s/^AllowedIPs[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        [[ -n "$_v" ]] && current_allowed_ips="$_v"
        # v5.11.1: preserve PresharedKey через regen — если у клиента
        # был PSK (создан с manage add --psk), regen без этого сохранения
        # выбросил бы его и сломал handshake (server peer всё ещё с PSK,
        # client conf уже без). CLIENT_PSK передаётся в render_client_config.
        local _psk
        _psk=$(sed -n '/^\[Peer\]/,$ s/^PresharedKey[ \t]*=[ \t]*//p' "$AWG_DIR/${name}.conf" | tr -d '[:space:]')
        if [[ -n "$_psk" ]]; then
            export CLIENT_PSK="$_psk"
        else
            unset CLIENT_PSK
        fi
    fi

    # В режиме AmneziaDNS клиентский AllowedIPs жёстко фиксирован в
    # "0.0.0.0/0, ::/0" (требование UI-гейта раздельного туннелирования Amnezia —
    # см. render_client_config). «Сохранённое» старое значение из .conf
    # вернуло бы инсталл в сломанное состояние при первом же regen/modify.
    # Аналогично DNS: всегда tunnel-gateway IP, а не 1.1.1.1 из прошлого .conf.
    if [[ "${AWG_AMNEZIA_DNS:-off}" == "on" ]]; then
        current_allowed_ips="0.0.0.0/0, ::/0"
        if [[ -n "${AWG_TUNNEL_SUBNET:-}" ]]; then
            current_dns=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
        fi
    fi

    # Перегенерация конфига (передаём client_ipv6 если dual-stack)
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "${AWG_PORT}" "$client_ipv6" || {
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }

    # Восстанавливаем пользовательские настройки (экранируем & и \ для sed replacement)
    local _dns _ka _aip
    _dns=$(printf '%s' "$current_dns" | sed 's/[&\\/]/\\&/g')
    _ka=$(printf '%s' "$current_keepalive" | sed 's/[&\\/]/\\&/g')
    _aip=$(printf '%s' "$current_allowed_ips" | sed 's/[&\\/]/\\&/g')
    local _client_conf="$AWG_DIR/${name}.conf"
    if ! sed -i "s/^DNS = .*/DNS = ${_dns}/" "$_client_conf"; then
        log_error "Ошибка sed при записи DNS в $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    if ! sed -i "s/^PersistentKeepalive = .*/PersistentKeepalive = ${_ka}/" "$_client_conf"; then
        log_error "Ошибка sed при записи PersistentKeepalive в $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi
    if ! sed -i "s|^AllowedIPs = .*|AllowedIPs = ${_aip}|" "$_client_conf"; then
        log_error "Ошибка sed при записи AllowedIPs в $_client_conf"
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    fi

    # Освобождаем блокировку — конфиг записан, дальше некритичные операции
    exec {lock_fd}>&-

    # QR-код
    generate_qr "$name"

    # vpn:// URI и QR для Amnezia VPN app (best-effort).
    # QR vpn:// пробуем только если URI пересоздан успешно.
    if generate_vpn_uri "$name"; then
        generate_qr_vpnuri "$name" || log_warn "QR vpn:// не обновлён для '$name'."
    else
        log_warn "vpn:// URI не обновлён для '$name'."
    fi

    # Hygiene: PSK не должен протекать в следующие операции в том же shell
    unset CLIENT_PSK

    log "Конфиг клиента '$name' перегенерирован."
    return 0
}

# ==============================================================================
# Валидация
# ==============================================================================

# Проверка AWG 2.0 конфигурации серверного конфига
validate_awg_config() {
    if [[ ! -f "$SERVER_CONF_FILE" ]]; then
        log_error "Серверный конфиг не найден: $SERVER_CONF_FILE"
        return 1
    fi

    local ok=1
    local param val
    local int_params=("Jc" "Jmin" "Jmax" "S1" "S2" "S3" "S4")
    local range_params=("H1" "H2" "H3" "H4")

    for param in "${int_params[@]}"; do
        val=$(sed -n "s/^${param} = //p" "$SERVER_CONF_FILE" | head -1)
        if [[ -z "$val" ]]; then
            log_error "Параметр '$param' не найден в серверном конфиге"
            ok=0
        elif ! [[ "$val" =~ ^[0-9]+$ ]]; then
            log_error "Параметр '$param' содержит невалидное значение: '$val' (ожидается целое число)"
            ok=0
        fi
    done

    # Протокольные границы (defense-in-depth для восстановленных бэкапов)
    local jc jmin jmax s3 s4
    jc=$(sed -n 's/^Jc = //p' "$SERVER_CONF_FILE" | head -1)
    jmin=$(sed -n 's/^Jmin = //p' "$SERVER_CONF_FILE" | head -1)
    jmax=$(sed -n 's/^Jmax = //p' "$SERVER_CONF_FILE" | head -1)
    s3=$(sed -n 's/^S3 = //p' "$SERVER_CONF_FILE" | head -1)
    s4=$(sed -n 's/^S4 = //p' "$SERVER_CONF_FILE" | head -1)
    if [[ "$jc" =~ ^[0-9]+$ ]]; then
        if [[ "$jc" -lt 1 || "$jc" -gt 128 ]]; then
            log_error "Jc=$jc вне допустимого диапазона (1-128)"
            ok=0
        fi
    fi
    if [[ "$jmin" =~ ^[0-9]+$ && "$jmax" =~ ^[0-9]+$ ]]; then
        if [[ "$jmin" -gt 1280 ]]; then
            log_error "Jmin=$jmin превышает 1280"
            ok=0
        fi
        if [[ "$jmax" -gt 1280 ]]; then
            log_error "Jmax=$jmax превышает 1280"
            ok=0
        fi
        if [[ "$jmax" -lt "$jmin" ]]; then
            log_error "Jmax ($jmax) меньше Jmin ($jmin)"
            ok=0
        fi
    fi
    if [[ "$s3" =~ ^[0-9]+$ && "$s3" -gt 64 ]]; then
        log_error "S3=$s3 превышает максимум (64)"
        ok=0
    fi
    if [[ "$s4" =~ ^[0-9]+$ && "$s4" -gt 32 ]]; then
        log_error "S4=$s4 превышает максимум (32)"
        ok=0
    fi

    for param in "${range_params[@]}"; do
        val=$(sed -n "s/^${param} = //p" "$SERVER_CONF_FILE" | head -1)
        if [[ -z "$val" ]]; then
            log_error "Параметр '$param' не найден в серверном конфиге"
            ok=0
        elif ! [[ "$val" =~ ^[0-9]+-[0-9]+$ ]]; then
            log_error "Параметр '$param' содержит невалидное значение: '$val' (ожидается формат MIN-MAX)"
            ok=0
        else
            local range_lo="${val%-*}" range_hi="${val#*-}"
            if [[ "$range_lo" -ge "$range_hi" ]]; then
                log_error "Параметр '$param': нижняя граница ($range_lo) >= верхней ($range_hi)"
                ok=0
            fi
        fi
    done

    # I1 опционален, но рекомендован для AWG 2.0
    if ! grep -q "^I1 = " "$SERVER_CONF_FILE"; then
        log_warn "Параметр I1 (CPS) не найден — CPS concealment не активен"
    fi

    if [[ $ok -eq 1 ]]; then
        log "Валидация AWG 2.0 конфига: OK"
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Срок действия клиентов (expiry)
# ==============================================================================

EXPIRY_DIR="${AWG_DIR}/expiry"
EXPIRY_CRON="${EXPIRY_CRON:-/etc/cron.d/awg-expiry}"

# Парсинг длительности в секунды: 1h, 12h, 1d, 7d, 30d
# parse_duration <duration_string>
parse_duration() {
    local input="$1"
    local num unit
    if [[ "$input" =~ ^([0-9]+)([hdw])$ ]]; then
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
    else
        log_error "Некорректный формат длительности: '$input'. Используйте: 1h, 12h, 1d, 7d, 4w"
        return 1
    fi
    case "$unit" in
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        w) echo $((num * 604800)) ;; # 7 дней
        *) return 1 ;;
    esac
}

# Установка срока действия клиента
# set_client_expiry <name> <duration>
set_client_expiry() {
    local name="$1"
    local duration="$2"
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "Невалидное имя клиента: '$name'"
        return 1
    fi
    if ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE" 2>/dev/null; then
        log_error "Клиент '$name' не найден."
        return 1
    fi
    local seconds
    seconds=$(parse_duration "$duration") || return 1
    local now
    now=$(date +%s)
    local expires_at=$((now + seconds))

    mkdir -p "$EXPIRY_DIR" || {
        log_error "Ошибка создания $EXPIRY_DIR"
        return 1
    }
    echo "$expires_at" > "$EXPIRY_DIR/$name" || {
        log_error "Ошибка записи expiry для '$name'"
        return 1
    }
    chmod 600 "$EXPIRY_DIR/$name"
    local expires_date
    expires_date=$(date -d "@$expires_at" '+%F %T' 2>/dev/null || echo "$expires_at")
    log "Срок действия '$name': $expires_date ($duration)"
    return 0
}

# Получение срока действия клиента (unix timestamp или пустая строка)
# get_client_expiry <name>
get_client_expiry() {
    local name="$1"
    local efile="$EXPIRY_DIR/$name"
    if [[ -f "$efile" ]]; then
        cat "$efile"
    fi
}

# Форматирование оставшегося времени
# format_remaining <expires_at_timestamp>
format_remaining() {
    local expires_at="$1"
    local now
    now=$(date +%s)
    local diff=$((expires_at - now))
    if [[ $diff -le 0 ]]; then
        local ago=$(( (-diff) / 3600 ))
        if [[ $ago -ge 24 ]]; then
            echo "истёк $(( ago / 24 ))д назад"
        elif [[ $ago -ge 1 ]]; then
            echo "истёк ${ago}ч назад"
        else
            local ago_mins=$(( (-diff) / 60 ))
            if [[ $ago_mins -ge 1 ]]; then
                echo "истёк ${ago_mins}м назад"
            else
                echo "только что истёк"
            fi
        fi
        return 0
    fi
    local days=$((diff / 86400))
    local hours=$(( (diff % 86400) / 3600 ))
    if [[ $days -gt 0 ]]; then
        echo "${days}д ${hours}ч"
    else
        local mins=$(( (diff % 3600) / 60 ))
        echo "${hours}ч ${mins}м"
    fi
}

# Проверка и удаление истёкших клиентов
check_expired_clients() {
    if [[ ! -d "$EXPIRY_DIR" ]]; then return 0; fi

    local removed=0
    local efile
    for efile in "$EXPIRY_DIR"/*; do
        [[ -f "$efile" ]] || continue
        local name
        name=$(basename "$efile")
        # Валидация имени: тот же regex что validate_client_name в manage_amneziawg.sh.
        # Defense-in-depth — EXPIRY_DIR доступен только root, но защита от
        # случайно попавшего невалидного файла (или symlink attack если expiry_dir
        # когда-то станет shared) нужна перед использованием $name в путях
        # и передачей в remove_peer_from_server (self-audit).
        if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            log_warn "Пропуск невалидного expiry файла: '$name'"
            continue
        fi
        local expires_at
        expires_at=$(cat "$efile" 2>/dev/null)
        if [[ -z "$expires_at" || ! "$expires_at" =~ ^[0-9]+$ ]]; then
            log_warn "Некорректные данные expiry для '$name': '$(head -c 50 "$efile" 2>/dev/null)'"
            continue
        fi

        local now
        now=$(date +%s)
        if [[ $now -ge $expires_at ]]; then
            log "Клиент '$name' истёк. Удаление..."
            if remove_peer_from_server "$name" 2>/dev/null; then
                _remove_client_files "$name"
                rm -f "$efile"
                log "Клиент '$name' удалён (истёк)."
                ((removed++))
            else
                log_warn "Не удалось удалить истёкшего клиента '$name'."
            fi
        fi
    done

    if [[ $removed -gt 0 ]]; then
        log "Удалено истёкших клиентов: $removed. Применение конфигурации..."
        if ! apply_config; then
            log_error "apply_config упал после удаления истёкших клиентов. Peer-ы убраны из конфига и expiry/, но могут оставаться на live интерфейсе. Требуется ручной перезапуск: systemctl restart awg-quick@awg0"
            return 1
        fi
    fi
    return 0
}

# Установка cron-задачи для автоудаления
install_expiry_cron() {
    # Идемпотентность по СОДЕРЖИМОМУ, не по факту существования файла. Раньше
    # ранний выход «файл есть» оставлял stale-пути после restore/переноса/
    # --conf-dir: cron продолжал смотреть в старый AWG_DIR. Генерируем ожидаемый
    # текст и заменяем файл, только если он отличается.
    local _cron_tmp
    _cron_tmp=$(awg_mktemp "$(dirname "$EXPIRY_CRON")") || { log_error "Ошибка mktemp для cron expiry"; return 1; }
    # Проверяем успех записи ДО cmp/mv: иначе сбой (диск/права) мог бы атомарно
    # заменить рабочий cron пустым/частичным tmp.
    if ! cat > "$_cron_tmp" << CRONEOF
# AmneziaWG client expiry check - every 5 minutes
AWG_DIR="${AWG_DIR}"
CONFIG_FILE="${CONFIG_FILE}"
SERVER_CONF_FILE="${SERVER_CONF_FILE}"
*/5 * * * * root /bin/bash -c 'source "${AWG_DIR}/awg_common.sh" || exit 1; check_expired_clients' >> "${AWG_DIR}/expiry.log" 2>&1
CRONEOF
    then
        rm -f "$_cron_tmp"
        log_error "Ошибка записи cron-задачи expiry"
        return 1
    fi
    if [[ -f "$EXPIRY_CRON" ]] && cmp -s "$_cron_tmp" "$EXPIRY_CRON"; then
        rm -f "$_cron_tmp"
        log_debug "Cron-задача expiry уже актуальна."
        return 0
    fi
    chmod 644 "$_cron_tmp"
    if ! mv -f "$_cron_tmp" "$EXPIRY_CRON"; then
        rm -f "$_cron_tmp"
        log_error "Ошибка установки cron-задачи expiry: $EXPIRY_CRON"
        return 1
    fi
    log "Cron-задача expiry установлена/обновлена: $EXPIRY_CRON"
}

# Удаление expiry-данных клиента
remove_client_expiry() {
    local name="$1"
    rm -f "$EXPIRY_DIR/$name" 2>/dev/null
    # Удаляем cron если больше нет клиентов с expiry
    if [[ -d "$EXPIRY_DIR" ]] && [[ -z "$(ls -A "$EXPIRY_DIR" 2>/dev/null)" ]]; then
        rm -f "$EXPIRY_CRON" 2>/dev/null
        log_debug "Cron-задача expiry удалена (нет клиентов с expiry)."
    fi
}
