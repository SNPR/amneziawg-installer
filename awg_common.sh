#!/bin/bash

# ==============================================================================
# Общая библиотека функций для AmneziaWG 2.0
# Автор: @bivlked
# Версия: 5.28.1
# Дата: 2026-08-27
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

# Версия библиотеки. manage-скрипт сверяет её со своей по MAJOR.MINOR после
# source и падает с понятной ошибкой, если awg_common.sh и manage разъехались
# (обновили один файл, забыли второй) - иначе рассинхрон всплывает как
# "command not found" в случайном месте. Бампается вместе с остальными версиями.
# shellcheck disable=SC2034  # используется в manage-скрипте после source
AWG_COMMON_VERSION="5.28.1"

# --- Автоочистка временных файлов ---
# ВАЖНО: trap НЕ устанавливается здесь, чтобы не перезаписать trap вызывающего скрипта.
# Вызывающий скрипт должен вызвать _awg_cleanup() в своём обработчике EXIT.
_AWG_TEMP_FILES=()
# Файл-реестр temp-файлов: awg_mktemp часто вызывается через $(...) (subshell),
# где правка массива _AWG_TEMP_FILES теряется в родителе. Файл переживает
# subshell, поэтому _awg_cleanup надёжно удалит даже temp, созданный в
# подстановке команды (например прерванная запись конфига между mktemp и mv).
# $$ = PID вызывающего скрипта, стабилен для всех его subshell.
# Реестр лежит в $AWG_DIR (root-only 0700), а НЕ в общедоступном /tmp:
# предсказуемое имя в /tmp позволяло бы локальному пользователю заранее
# подложить файл со списком чужих путей, которые _awg_cleanup удалил бы от root.
_AWG_TEMP_REGISTRY="${AWG_DIR}/.awg_temp_registry.$$"

_awg_cleanup() {
    local f
    for f in "${_AWG_TEMP_FILES[@]}"; do
        [[ -f "$f" ]] && rm -f "$f"
    done
    # Файловый кэш public IP (см. get_server_public_ip) - per-PID, подчищаем.
    rm -f "${AWG_DIR}/.public_ip.cache.$$" 2>/dev/null
    # Guard от symlink-подмены реестра: читаем только обычный файл.
    if [[ -n "${_AWG_TEMP_REGISTRY:-}" && -f "$_AWG_TEMP_REGISTRY" && ! -L "$_AWG_TEMP_REGISTRY" ]]; then
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

# Canonical textual IPv4 accepted by inet_pton(3): no leading zeroes except
# for the single digit zero itself.  Generated quick configs use this stricter
# form so preflight cannot disagree with awg/iproute2 parsing after a stop.
_valid_canonical_ipv4() {
    _valid_ipv4 "$1" || return 1
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$ ]]
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
    local host="$1" label
    _valid_canonical_ipv4 "$host" && return 0
    (( ${#host} >= 1 && ${#host} <= 253 )) || return 1
    [[ "$host" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || return 1
    local IFS=.
    read -r -a labels <<< "$host"
    for label in "${labels[@]}"; do
        (( ${#label} >= 1 && ${#label} <= 63 )) || return 1
    done
    # Полностью числовая последняя метка = не настоящий TLD (RFC 3696), а скорее
    # битый IPv4 (например "999.1.1.1"); отвергаем, чтобы не принять опечатку в IP.
    local last="${host##*.}"
    [[ "$last" =~ ^[0-9]+$ ]] && return 1
    return 0
}

# Порту из конфига нельзя доверять до проверки: и awgsetup_cfg.init, и ListenPort
# в живом awg0.conf правят руками, и там оказывается что угодно. Значение уходит
# в 'Endpoint = IP:PORT' клиентского .conf (add/regen), в JSON без кавычек
# ("number":abc не разбирается) и в арифметические сравнения (где bash выполняет
# подстановку команд из строки вида a[$(...)]) у check, и в regex правил UFW у
# diagnose. Функция, а не пара строк по месту: так её исполняет тест, а не копия
# логики.
_sanitize_port() {
    local p="${1:-}"
    # Пробелы по краям срезаю: 'AWG_PORT=39743 ' - обычный след ручной правки,
    # и это тот же самый порт. Раньше такой конфиг ронял проверку впустую.
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    # {1,5} отсекает переполнение 64-битной арифметики: длинная строка цифр
    # молча приземлилась бы внутрь допустимого диапазона. 10# снимает
    # восьмеричную трактовку значений с ведущим нулём (0070 иначе даст 56).
    if [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( 10#$p >= 1 && 10#$p <= 65535 )); then
        printf '%s' "$((10#$p))"
    else
        printf '0'
    fi
}

# --- CIDR-арифметика (общая для аллокатора IPv4/IPv6) ---
# Чистые функции, только bash-арифметика ($(( ))), без внешних зависимостей.
# set-e-safe: значения берём через $(( ))/local, guard'ы через "|| return".

# _ipv4_to_int <a.b.c.d> : 32-битное целое из IPv4. Guard входа - _valid_ipv4
# (не переизобретаем проверку октетов). 10# защищает от трактовки ведущего нуля
# как восьмеричного числа.
_ipv4_to_int() {
    _valid_ipv4 "$1" || return 1
    local IFS=. o
    read -ra o <<< "$1"
    echo $(( (10#${o[0]} << 24) | (10#${o[1]} << 16) | (10#${o[2]} << 8) | 10#${o[3]} ))
}

# _int_to_ipv4 <int> : IPv4 из 32-битного целого.
_int_to_ipv4() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

# _cidr_bounds <addr/prefix> : печатает "network_int broadcast_int".
# Единственный источник формулы network/broadcast в awg_common.
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

# _awg_network_cidr <addr/prefix> : канонический IPv4 CIDR (network/prefix).
# Используется в shell-hook'ах policy routing, поэтому адрес из init-файла
# нельзя собирать строковыми операциями, корректными только для /24.
_awg_network_cidr() {
    local cidr="$1" prefix net bcast
    prefix="${cidr##*/}"
    read -r net bcast < <(_cidr_bounds "$cidr" 2>/dev/null) || return 1
    [[ -n "$net" && "$prefix" =~ ^[0-9]+$ ]] || return 1
    printf '%s/%s' "$(_int_to_ipv4 "$net")" "$((10#$prefix))"
}

# Определение основного сетевого интерфейса (egress).
# Цепочка fallback, чтобы не падать на хостах, где зонд к 1.1.1.1 не отдаёт
# интерфейс: провайдер null-route'ит/блокирует адрес, policy-routing или
# IPv6-only egress (наблюдалось на Ubuntu 26.04 / Timeweb, issue #166).
# Ручное переопределение: export AWG_MAIN_NIC=<iface> перед запуском.
get_main_nic() {
    # Ручной оверрайд принимаем только если это существующий безопасный ifname:
    # значение попадает в PostUp/PostDown (iptables -o ...), поэтому имена с
    # shell-метасимволами и несуществующие интерфейсы отвергаем (fall-through
    # к авто-детекту).
    if [[ -n "${AWG_MAIN_NIC:-}" ]]; then
        if [[ "$AWG_MAIN_NIC" =~ ^[A-Za-z0-9._-]+$ ]] \
            && ip link show dev "$AWG_MAIN_NIC" &>/dev/null; then
            printf '%s\n' "$AWG_MAIN_NIC"
            return 0
        fi
        # Невалидный оверрайд отбрасываем ГРОМКО (log_warn идёт в stderr, вывод
        # $() не загрязняет): молчаливый fall-through путал бы пользователя,
        # который уже выполнил подсказку export AWG_MAIN_NIC=... с опечаткой.
        log_warn "AWG_MAIN_NIC='${AWG_MAIN_NIC}' проигнорирован: интерфейс не найден или имя некорректно - продолжаю авто-детект."
    fi
    local nic
    # 1) Реальный egress к публичному адресу (FIB-lookup, быстрый путь для большинства хостов).
    nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # 2) Дефолтный IPv4-маршрут (когда зонд недостижим/заблокирован).
    [[ -z "$nic" ]] && nic=$(ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    # 3) Первый UP-интерфейс с глобальным IPv4 (нет дефолт-маршрута). Исключаем
    #    туннельные/виртуальные (awg0 сам UP с 10.x scope global при --force
    #    переустановке, docker0/br-*/veth* на хостах с контейнерами) - иначе
    #    NAT ушёл бы в hairpin через сам туннель, а IPv6-only warning молча
    #    подавился бы (у awg0 есть глобальный IPv4).
    [[ -z "$nic" ]] && nic=$(ip -o -4 addr show up scope global 2>/dev/null \
        | awk '{sub(/@.*/,"",$2); if ($2!="lo" && $2 !~ /^(awg|wg|docker|br-|virbr|veth|lxc|tun|tap)/) { print $2; exit }}')
    # 4) Дефолтный IPv6-маршрут (IPv6-only egress).
    [[ -z "$nic" ]] && nic=$(ip -6 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [[ -n "$nic" ]] || return 1
    printf '%s\n' "$nic"
}

# Возвращает 0, если у хоста нет IPv4-выхода: нет дефолтного IPv4-маршрута И у
# интерфейса $1 нет глобального IPv4-адреса. Такой хост IPv6-only (issue #166:
# Timeweb Ubuntu 26.04) - IPv4-туннель (10.x) не сможет NAT'иться наружу.
# Оба условия должны совпасть: на dual-stack/IPv4 хостах функция вернёт 1.
host_lacks_ipv4_egress() {
    local nic="$1"
    # [[ -z $(...) ]] вместо "| grep -q .": grep -q выходит на первой строке, и
    # под pipefail многострочный вывод ip (несколько default-маршрутов) мог бы
    # дать SIGPIPE=141 -> ложное "маршрута нет" на здоровом dual-stack хосте.
    [[ -z "$(ip -4 route show default 2>/dev/null)" ]] \
        && [[ -z "$(ip -o -4 addr show dev "$nic" up scope global 2>/dev/null)" ]]
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
# Файловый дубль кэша: get_server_public_ip практически всегда вызывается как
# $(...) (subshell), где присваивание _CACHED_PUBLIC_IP теряется в родителе и
# кэш-переменная никогда не срабатывает. Файл с PID-суффиксом переживает
# subshell (тот же приём, что _AWG_TEMP_REGISTRY) и удаляется в _awg_cleanup.
# Без него `manage regen` по N клиентам делал бы N curl-раундов (до 6 сервисов
# по 5 сек каждый) при пустом AWG_ENDPOINT.
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
        # Fallback: три $RANDOM (15 бит каждый) с XOR-перекрытием покрывают
        # биты 0-30, т.е. весь [0, 2^31-1]. Прежний вариант (RANDOM<<15|RANDOM)
        # давал только 30 бит - верхняя половина диапазона H никогда не выпадала.
        random_val=$(( (RANDOM << 16) ^ (RANDOM << 8) ^ RANDOM ))
    fi
    echo $(( (random_val % range) + min ))
}

# Генерация 4 непересекающихся диапазонов для AWG H1-H4.
# Алгоритм: 8 случайных значений → sort → 4 пары (low, high).
# Сортировка даёт low <= high; строгие проверки ниже гарантируют зазор между
# парами (касание границ = пересечение в одной точке) и нижнюю границу >= 5
# (значения 1-4 зарезервированы под типы сообщений vanilla WireGuard).
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
        # Проверка: минимальная ширина каждой пары, строгий зазор между
        # парами (без касания границ) и нижняя граница вне зарезервированных
        # значений 1-4 (типы сообщений vanilla WireGuard).
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
# DKMS / Автовосстановление модуля ядра amneziawg
# ==============================================================================

# awg_module_version : версия модуля amneziawg (пустая строка, если определить
# не удалось). Сначала спрашиваем ЗАГРУЖЕННЫЙ модуль, и только потом файл.
#
# ⚠️ Почему не просто modinfo: modinfo читает метаданные того .ko, который
# ВЫБРАН на диске по modules.dep, а не того объекта, что работает в ядре.
# В норме это одно и то же, поэтому расхождение не всплывало. Но если на хосте
# оказались ДВА дерева с модулем одного имени - закреплённый 2.0 в extra/ и
# DKMS-3.0 в updates/dkms/ - modinfo назовёт тот, что выиграл по приоритету
# поиска, а загружен может быть другой (например, прежний, до перезагрузки).
# Тогда наша же диагностика сообщила бы версию, которой в ядре нет.
# /sys/module/amneziawg/version отражает именно загруженное и существует в
# ОБЕИХ линиях: MODULE_VERSION(WIREGUARD_VERSION) объявлен в src/main.c и в
# закреплённом 2.0-теге, и в 3.0.
# modinfo остаётся вторым путём - он работает, когда модуль не загружен.
#
# AWG_MODULE_VERSION_PATH переопределяется только тестами (bats): подменить
# /sys иначе нельзя, а проверить надо именно приоритет «загруженное важнее файла».
awg_module_version() {
    local ver="" sysfile="${AWG_MODULE_VERSION_PATH:-/sys/module/amneziawg/version}"
    if [[ -r "$sysfile" ]]; then
        # ⚠️ `|| true`, а НЕ `|| ver=""`: на файле без завершающего перевода
        # строки read возвращает 1, УЖЕ присвоив прочитанное. Сброс в пустую
        # строку затёр бы верное значение и молча уронил нас на modinfo.
        # ⚠️ И `2>/dev/null` стоит ДО `<`, а не после: перенаправления
        # применяются слева направо, поэтому при обратном порядке ошибка
        # открытия файла успевает уйти в исходный stderr - проверено, сырая
        # строка `bash: ...` вылезала посреди вывода manage check.
        IFS= read -r ver 2>/dev/null < "$sysfile" || true
        ver="${ver//[[:space:]]/}"
        # 🔴 Файл был читаем - отвечаем тем, что он дал, даже если это пустота,
        # и на modinfo НЕ уходим. Подмена ответом с диска - ровно то, от чего
        # эта функция создана уходить: при двух деревьях modinfo назовёт версию,
        # которой в ядре нет, а diagnose на её основании объявит линию протокола.
        # Пустая версия честнее неверной: потребители печатают строку без версии.
        printf '%s' "$ver"
        return 0
    fi
    ver=$(modinfo amneziawg 2>/dev/null | awk '/^version:/{print $2; exit}')
    printf '%s' "$ver"
}

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
#   2 - только "full": модуль в порядке, но awg-quick@awg0 не стартовал
#       (сервис-проблема: битый конфиг, занятый порт и т.п.). Раньше это
#       гасилось в log_warn + return 0, и repair-module рапортовал
#       "сервис активен" при лежащем сервисе (Issue #175).
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
            _ensure_awg_quick_running awg0 || {
                log_warn "Модуль активен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
                return 2
            }
        fi
        return 0
    fi

    # Модуль на диске для running kernel — пробуем modprobe до full repair.
    if find "/lib/modules/${kernel_ver}" -name 'amneziawg.ko*' -print -quit 2>/dev/null | grep -q .; then
        if modprobe amneziawg 2>/dev/null && \
           lsmod 2>/dev/null | awk '{print $1}' | grep -qx 'amneziawg'; then
            log "amneziawg-модуль найден на диске и успешно загружен."
            if [[ "$mode" == "full" ]]; then
                _ensure_awg_quick_running awg0 || {
                    log_warn "Модуль загружен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
                    return 2
                }
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
        depmod -a "$kernel_ver" >/dev/null 2>&1 || \
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
        _ensure_awg_quick_running awg0 || {
            log_warn "Модуль загружен, но awg-quick@awg0 не стартовал (модуль OK, это сервис-проблема)."
            return 2
        }
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

# Парсер живого серверного конфига AmneziaWG (источник истины для AWG_*).
# Читает секцию [Interface] из awg0.conf и экспортирует AWG_* переменные
# АТОМАРНО: либо все 11 обязательных параметров (Jc/Jmin/Jmax/S1-S4/H1-H4)
# найдены и экспортированы, либо ничего не меняется в окружении и возврат 1.
# Это защищает от mixed-state при частично corrupt awg0.conf.
# I1-I5, ListenPort - опциональные, экспортируются если нашлись.
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
                I2)         _I2="$value" ;;
                I3)         _I3="$value" ;;
                I4)         _I4="$value" ;;
                I5)         _I5="$value" ;;
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
#     (Jc/Jmin/Jmax/S1-S4/H1-H4/I1-I5) когда файл существует.
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
        # Unset I1-I5 перед парсингом: они опциональны, если их нет в live conf -
        # не должны утечь stale из init-файла.
        unset AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5
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

# Предупреждение о расхождении awgsetup_cfg.init с живым awg0.conf (issue #196).
#
# После установки awg0.conf - единственный источник параметров обфускации, а
# init читается для них только на bootstrap первой установки (см. load_awg_params
# выше). Правка AWG_* в init после установки на клиентов не влияет, и до этой
# проверки она игнорировалась МОЛЧА: файл назван как конфиг установки, человек
# правит его и не получает ни намёка, что смотреть надо в другое место.
#
# Гейт по времени модификации отсекает ложные срабатывания на штатном пути.
# Рекомендованный способ тюнинга (правка [Interface] в awg0.conf + regen) тоже
# разводит эти файлы, но init после установки никто не перезаписывает, поэтому
# там он остаётся СТАРШЕ live-конфига. Предупреждаем только когда init тронут
# ПОЗЖЕ awg0.conf - это и есть случай "поправил init, эффекта нет".
#
# Проверку намеренно не вешаем на load_awg_params: её зовёт и установщик на
# шаге 6, где init заведомо свежее ещё не перезаписанного awg0.conf, и
# предупреждение всплывало бы посреди штатной установки.
_AWG_DRIFT_KEYS=(AWG_Jc AWG_Jmin AWG_Jmax AWG_S1 AWG_S2 AWG_S3 AWG_S4 \
                 AWG_H1 AWG_H2 AWG_H3 AWG_H4 AWG_I1 AWG_I2 AWG_I3 AWG_I4 AWG_I5)

# _awg_drift_dump <init|live> <файл>: по строке на ключ в порядке массива выше,
# поэтому дампы двух источников сравнимы построчно. Читаем в subshell, чтобы не
# трогать окружение вызывающего - функцию можно звать в любой момент, не рискуя
# перетереть уже загруженные параметры.
_awg_drift_dump() {
    local mode="$1" src="$2"
    (
        # Наследованные значения гасим: иначе ключ, которого в источнике нет,
        # показался бы равным тому, что уже лежит в окружении. Если погасить
        # не удалось (переменная readonly в вызывающем окружении), сравнивать
        # нечего - выходим без маркера.
        unset "${_AWG_DRIFT_KEYS[@]}" 2>/dev/null || exit 1
        if [[ "$mode" == "init" ]]; then
            safe_load_config "$src" >/dev/null 2>&1 || exit 1
        else
            load_awg_params_from_server_conf "$src" >/dev/null 2>&1 || exit 1
        fi
        # Маркер успеха первой строкой: mapfile не отдаёт код возврата
        # процесса-поставщика, поэтому без него отказ парсера не отличить от
        # набора пустых значений.
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
    # init не новее live - значит расхождение, если оно есть, создано правкой
    # самого awg0.conf, то есть штатным путём. Молчим.
    [[ "$init" -nt "$live" ]] || return 0

    local -a ivals lvals
    mapfile -t ivals < <(_awg_drift_dump init "$init")
    mapfile -t lvals < <(_awg_drift_dump live "$live")
    # Без маркера сравнение недостоверно: разбор одного из источников отказал.
    # Молчим, а не объявляем разошедшимися все ключи разом - реальную причину
    # (например неполный [Interface]) дальше назовёт load_awg_params.
    [[ "${ivals[0]:-}" == "ok" && "${lvals[0]:-}" == "ok" ]] || return 0

    local drift="" i
    for i in "${!_AWG_DRIFT_KEYS[@]}"; do
        [[ "${ivals[i+1]:-}" == "${lvals[i+1]:-}" ]] || drift+="${_AWG_DRIFT_KEYS[i]#AWG_} "
    done
    [[ -n "$drift" ]] || return 0

    log_warn "Файл $init изменён позже $live, и параметры обфускации в них расходятся: ${drift% }"
    log_warn "Действуют значения из $live - после установки он единственный источник этих параметров. Если вы правили их в $init, до клиентов правка не дойдёт: меняйте секцию [Interface] в $live, затем перезапустите awg-quick@awg0 и выполните regen нужных клиентов."
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
    # 700 сразу при создании: mkdir -p с дефолтным umask дал бы 755, и до
    # secure_files инсталлера каталог ключей был бы доступен на чтение всем.
    chmod 700 "$KEYS_DIR"

    local privkey pubkey
    privkey=$(awg genkey) || {
        log_error "Ошибка генерации приватного ключа для '$name'"
        return 1
    }
    pubkey=$(echo "$privkey" | awg pubkey) || {
        log_error "Ошибка генерации публичного ключа для '$name'"
        return 1
    }

    # umask 077 в subshell: файл рождается сразу 600, без окна world-readable
    # между записью и chmod (при дефолтном umask 022 ключ был бы 644 на миг).
    ( umask 077; echo "$privkey" > "$KEYS_DIR/${name}.private" ) || {
        log_error "Ошибка записи приватного ключа для '$name'"
        return 1
    }
    ( umask 077; echo "$pubkey" > "$KEYS_DIR/${name}.public" ) || {
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

    # umask 077: без окна world-readable между записью и chmod (см. generate_keypair).
    ( umask 077; echo "$privkey" > "$AWG_DIR/server_private.key" ) || return 1
    ( umask 077; echo "$pubkey" > "$AWG_DIR/server_public.key" ) || return 1
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
# render_server_config [peers_source_file]
# Использует глобальные переменные из load_awg_params()
# peers_source_file (необязательный): файл, чьи [Peer]-блоки переносятся в
# новый конфиг ДО атомарного mv (обычно бэкап живого awg0.conf). Благодаря
# этому живой конфиг ни на мгновение не остаётся без пиров - сбой между
# render и отдельным append оставлял бы безпировый файл, а повторный запуск
    # шага 6 уже бэкапил бы его (потеря всех пиров при --force reinstall).
# shellcheck disable=SC2154  # AWG_* vars loaded via load_awg_params -> source
render_server_config() {
    local peers_source="${1:-}"
    local output_file="${2:-$SERVER_CONF_FILE}"
    load_awg_params || return 1

    # --no-cps (issue #159): load_awg_params перечитывает I1 из живого awg0.conf
    # при переустановке. При NO_CPS=1 намеренно обнуляем I1, иначе серверный
    # конфиг тихо восстановил бы CPS вопреки флагу.
    if grep -qE '^[[:space:]]*(export[[:space:]]+)?NO_CPS=1' "$CONFIG_FILE" 2>/dev/null; then
        AWG_I1=''
    fi

    # Порт для НОВОГО awg0.conf берём из init-файла (намерение пользователя:
    # флаг --port или сохранённый прежний порт), а НЕ из перезаписываемого
    # старого awg0.conf. load_awg_params перечитывает ListenPort из живого
    # конфига, поэтому без этого --port при --force молча игнорировался бы.
    # render_server_config вызывается только из install, regen клиентов
    # (regenerate_client) идёт своим путём и не затрагивается.
    local _init_port
    _init_port=$(grep -oP '^\s*export AWG_PORT=\K[0-9]+' "$CONFIG_FILE" 2>/dev/null | head -n1)
    [[ -n "$_init_port" ]] && AWG_PORT="$_init_port"

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
        log_error "Укажите его вручную и перезапустите шаг 6: export AWG_MAIN_NIC=<iface>"
        log_error "Доступные интерфейсы: $(ip -br link 2>/dev/null | awk '$1!="lo"{printf "%s ", $1}')"
        return 1
    fi

    # IPv6-only egress: интерфейс есть, но IPv4-выхода нет. Туннель на IPv4 (10.x)
    # NAT'ится через MASQUERADE - на таком хосте IPv4-трафик клиентов наружу не
    # пойдёт (issue #166). Предупреждаем, не блокируем: peer-to-peer внутри
    # туннеля и IPv6-туннель в direct-режиме (--allow-ipv6-tunnel) работают.
    if host_lacks_ipv4_egress "$nic"; then
        log_warn "Похоже, хост IPv6-only: у $nic нет IPv4-выхода."
        log_warn "VPN туннелирует IPv4, поэтому IPv4-трафик клиентов наружу не пойдёт."
        log_warn "Нужен хост с IPv4-адресом (dual-stack) или NAT64."
    fi

    local server_ip subnet_mask client_net
    server_ip=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
    subnet_mask=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f2)
    client_net=$(_awg_network_cidr "$AWG_TUNNEL_SUBNET") || {
        log_error "Не удалось привести подсеть туннеля к каноническому CIDR: '$AWG_TUNNEL_SUBNET'"
        return 1
    }

    # Адрес [Interface]: IPv4 всегда, IPv6 только при включённом туннеле.
    # Сервер берёт хост ::1 в туннельной IPv6-подсети.
    # IPV6_SUBNET имеет форму PREFIX::/MASK (по умолчанию fddd:2c4:2c4:2c4::/64),
    # поэтому адрес сервера получаю заменой завершающего ::/MASK на ::1/MASK.
    local address_line="${server_ip}/${subnet_mask}"
    if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" \
          && ( "${AWG_ROLE:-single}" == "entry" || "${AWG_EGRESS:-direct}" == "warp" ) ]]; then
        log_error "IPv6-туннель пока несовместим с role=entry и egress=warp: их policy routing реализован только для IPv4."
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
        local up_tbl="${AWG_UPSTREAM_TABLE:-123}"
        local up_prio="${AWG_UPSTREAM_PRIORITY:-456}"
        if ! _validate_iface_name "$up_iface"; then
            log_error "Недопустимое имя upstream-интерфейса: '$up_iface'"
            return 1
        fi
        if ! [[ "$up_tbl" =~ ^[0-9]{1,10}$ ]] \
            || (( 10#$up_tbl < 1 || 10#$up_tbl > 4294967295 \
                  || (10#$up_tbl >= 253 && 10#$up_tbl <= 255) )); then
            log_error "Недопустимая таблица upstream: '$up_tbl'"
            return 1
        fi
        if ! [[ "$up_prio" =~ ^[0-9]{1,5}$ ]] \
            || (( 10#$up_prio < 1 || 10#$up_prio > 32764 )); then
            log_error "Недопустимый приоритет upstream: '$up_prio'"
            return 1
        fi
        # Policy rule живёт вместе с awg0, а не awg1. Поэтому при падении
        # upstream таблица не проваливается в main: худший blackhole default
        # остаётся, пока клиентский awg0 активен. Реальный default от awg1
        # имеет меньшую metric и выигрывает; более специфичные routes тоже.
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
            log_error "Недопустимое имя WARP-интерфейса: '$warp_iface'"
            return 1
        fi
        if ! [[ "$warp_tbl" =~ ^[0-9]{1,10}$ ]] \
            || (( 10#$warp_tbl < 1 || 10#$warp_tbl > 4294967295 \
                  || (10#$warp_tbl >= 253 && 10#$warp_tbl <= 255) )); then
            log_error "Недопустимая таблица WARP: '$warp_tbl'"
            return 1
        fi
        if ! [[ "$warp_prio" =~ ^[0-9]{1,5}$ ]] \
            || (( 10#$warp_prio < 1 || 10#$warp_prio > 32764 )); then
            log_error "Недопустимый приоритет WARP: '$warp_prio'"
            return 1
        fi
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
        # Persistent blackhole keeps WARP fail-closed: if wgcf disappears and
        # its device route is removed, policy lookup must not fall through to
        # main and expose the VPS IP. Specific bypass routes still win by prefix.
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

    # MSS/PMTU-clamp: фиксируем TCP MSS под туннельный MTU, чтобы крупные сегменты
    # не упирались в 1280-туннель при фильтрованном ICMP "frag needed" (PMTUD-блэкхол:
    # VPN подключается, но крупные страницы/закачки виснут на мобильных/double-NAT/
    # каскадных путях). Фикс из AWG_MTU детерминирован при жёстко заданном MTU и
    # авто-синхронен с ним; clamp-to-pmtu зависел бы от egress-маршрута. Би-directional
    # (-o %i и -i %i) кэпит MSS в обе стороны. IPv4: MTU-40, IPv6: MTU-60. Только SYN,
    # таблица mangle (отдельная от UFW/filter). Стиль -A/-D зеркалит MASQUERADE выше.
    local awg_mtu="${AWG_MTU:-1280}"
    if ! _validate_mtu "$awg_mtu"; then
        log_warn "Некорректный AWG_MTU='$awg_mtu', использую безопасный MTU 1280."
        awg_mtu=1280
    else
        awg_mtu=$((10#$awg_mtu))
    fi
    local path_mtu="$awg_mtu"
    # Внешние плечи имеют собственный предел: wgcf по умолчанию 1280, awg1 —
    # 1380. Не повышаем MSS выше самого узкого плеча при нестандартном AWG_MTU.
    if [[ "${AWG_EGRESS:-direct}" == "warp" ]] && (( path_mtu > 1280 )); then
        path_mtu=1280
    elif [[ "${AWG_ROLE:-single}" == "entry" ]] && (( path_mtu > 1380 )); then
        path_mtu=1380
    fi
    local mss4=$(( path_mtu - 40 ))
    local mss6=$(( awg_mtu - 60 ))
    postup="${postup}; iptables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}; iptables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"
    postdown="${postdown}; iptables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}; iptables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss4}"

    # Изоляция клиентов (issue #178): DROP awg0->awg0 до общего ACCEPT.
    # PostUp выполняется слева направо, -I вставляет в начало цепочки -
    # правило, добавленное В СТРОКЕ ПОЗЖЕ, оказывается В ЦЕПОЧКЕ ВЫШЕ, поэтому
    # DROP дописывается в конец postup. Перед -I дренируем stale-копии циклом
    # -D: после сбойного PostDown копия DROP иначе копилась бы с каждым up
    # (ревью PR #179). Именно drain, а не -C: stale-копия к этому моменту
    # лежит НИЖЕ свежевставленного ACCEPT, -C нашёл бы её, пропустил вставку -
    # и awg0->awg0 трафик уходил бы в ACCEPT (изоляция молча сломана).
    # PostDown с '2>/dev/null || true': после переустановки on->off правила в
    # running-наборе нет, и упавший -D не должен ронять awg-quick down
    # (down-фаза restart работает уже с новым конфигом). Unset
    # CLIENT_ISOLATION = 1: конфиги до v5.20 изолированы.
    if [[ "${CLIENT_ISOLATION:-1}" == "1" ]]; then
        postup="${postup}; while iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; iptables -I FORWARD -i %i -o %i -j DROP"
        postdown="${postdown}; iptables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
    fi

    # IPv6 правила: при включённом IPv6-туннеле (FORWARD внутри туннеля + MASQUERADE
    # на публичный интерфейс). MASQUERADE безвреден если у VPS нет native IPv6 -
    # это no-op, пока нет IPv6 default route, зато peer-to-peer внутри туннеля работает.
    # Использую тот же nic, что и IPv4 MASQUERADE (не хардкожу интерфейс).
    # Условие DISABLE_IPV6=0 сохранено для байт-в-байт совместимости с v5.14.x:
    # установка с --allow-ipv6 (без туннеля) получает те же IPv6-правила фильтра, что и раньше.
    if [[ ( "${ALLOW_IPV6_TUNNEL:-0}" == "1" || "${DISABLE_IPV6:-1}" == "0" ) \
          && "${AWG_ROLE:-single}" != "entry" && "${AWG_EGRESS:-direct}" != "warp" ]]; then
        postup="${postup}; ip6tables -I FORWARD -i %i -j ACCEPT; ip6tables -t nat -A POSTROUTING -o ${nic} -j MASQUERADE; ip6tables -t mangle -A FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}; ip6tables -t mangle -A FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        postdown="${postdown}; ip6tables -D FORWARD -i %i -j ACCEPT; ip6tables -t nat -D POSTROUTING -o ${nic} -j MASQUERADE; ip6tables -t mangle -D FORWARD -o %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}; ip6tables -t mangle -D FORWARD -i %i -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss ${mss6}"
        # Изоляция и для IPv6-туннеля: без DROP dual-stack клиенты в split-
        # режимах достижимы друг для друга по fddd::/64 (IPV6_SUBNET уже в их
        # AllowedIPs через render_client_config) - issue #178.
        if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" && "${CLIENT_ISOLATION:-1}" == "1" ]]; then
            postup="${postup}; while ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null; do :; done; ip6tables -I FORWARD -i %i -o %i -j DROP"
            postdown="${postdown}; ip6tables -D FORWARD -i %i -o %i -j DROP 2>/dev/null || true"
        fi
    fi

    # Формируем конфиг через временный файл (атомарная запись).
    # temp создаём в каталоге итогового конфига, чтобы mv был атомарным rename
    # на той же ФС (а не cross-fs copy+unlink, если /tmp = tmpfs).
    local tmpfile
    tmpfile=$(awg_mktemp "$(dirname "$output_file")") || { log_error "Ошибка mktemp"; return 1; }

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

    # Добавляем I1-I5 только если заданы (CPS-параметры опциональны).
    # I2-I5 задаются админом вручную в awg0.conf (issue #71), переносятся как есть.
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"

    # Перенос [Peer]-блоков из peers_source в temp ДО mv (см. док-комментарий).
    # Буфер сбрасывается на каждом новом [Peer]: переносятся ВСЕ блоки.
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
                log_error "Ошибка переноса [Peer]-блоков в новый конфиг"
                return 1
            }
        fi
    fi

    if ! mv "$tmpfile" "$output_file"; then
        rm -f "$tmpfile"
        log_error "Ошибка записи серверного конфига"
        return 1
    fi
    chmod 600 "$output_file"
    log "Серверный конфиг создан: $output_file"
    return 0
}

# Предупредить, что списочное значение задано несколькими строками и они были
# объединены. Молчать тут нельзя: объединение меняет то, что человек написал
# руками, и если он ошибся, узнать об этом он должен от нас, а не от клиента.
_awg_warn_multiline() {
    local raw="$1" key="$2" name="$3" n
    n=$(printf '%s\n' "$raw" | grep -c '[^[:space:]]') || n=0
    (( n > 1 )) && log_warn "'${key}' у клиента '${name}' задан ${n} строками - значения объединены в одну."
    return 0
}

# Нормализация списка через запятую к каноническому виду "a, b, c".
#
# Зачем: установщик пишет AllowedIPs и DNS через запятую С ПРОБЕЛОМ, а
# regenerate_client читал эти значения через `tr -d '[:space:]'` и записывал
# прочитанное обратно, поэтому первый же regen оставлял в .conf слипшийся
# список (D#38 @humowns). Здесь список разбирается поэлементно, а разделитель
# ставится канонически, и повторный regen ЛЕЧИТ уже испорченные конфиги.
#
# 🔴 НЕ применять к значению, которое уходит в JSON-массив allowed_ips сборщика
# vpn:// (см. комментарий у generate_vpn_uri): там нужна КОМПАКТНАЯ форма.
# Одна редакция этой правки нормализацию туда уже завела, и на стенде это дало
# ведущий пробел внутри 33 элементов массива из 34.
#
# Пробелы срезаются ВНУТРИ элемента, а не только по краям: элементы этих двух
# списков (CIDR и адреса резолверов) пробелов не содержат никогда, а валидатор
# `manage modify` чистит их так же, через `${tok//[[:space:]]/}`. Заодно это
# лечит значения вида "1.1.1. 1", которые прежний `tr` вычищал случайно.
#
# Разбор через `read -a`, а не `for x in $raw`, чтобы значение не попало под
# glob-раскрутку. Trim инлайном, без вызова функции: подстановка на КАЖДЫЙ
# элемент порождает subshell, и на списке в 2000 записей это 18 секунд против
# 0.1 - а regen без имени идёт по всем клиентам сразу.
#
# ⚠️ Контракт: вход ОДНОСТРОЧНЫЙ. `read` без `-d` возьмёт только первую строку,
# поэтому многострочное значение вызывающий обязан склеить сам (`paste -sd, -`).
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

# Допустимый диапазон MTU для AWG / WireGuard.
# Минимум 576 (классический минимум IPv4), максимум 9100 (verge на jumbo frame).
# Значения вне диапазона трактуются как ошибочные и игнорируются (fallback к 1280).
_validate_mtu() {
    local v="$1"
    [[ "$v" =~ ^[0-9]{1,4}$ ]] || return 1
    (( 10#$v >= 576 && 10#$v <= 9100 )) || return 1
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

    if [[ "${ALLOW_IPV6_TUNNEL:-0}" == "1" \
          && ( "${AWG_ROLE:-single}" == "entry" || "${AWG_EGRESS:-direct}" == "warp" ) ]]; then
        log_error "Нельзя выпускать IPv6-клиента для role=entry/egress=warp: этот путь маршрутизирует только IPv4."
        return 1
    fi

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
        # iOS AmneziaVPN в режиме "весь трафик" требует обе семьи адресов: при
        # голом 0.0.0.0/0 он считает это незавершённой раздельной маршрутизацией
        # и не поднимает туннель. Для full-tunnel добавляем ::/0 - IPv6 уходит в
        # туннель (и отсекается, если у сервера нет нативного IPv6), наружу мимо
        # VPN не утекает. Затрагивает только mode-1: split-режим = кастомный
        # список, не равен 0.0.0.0/0 и под условие не попадает.
        if [[ "$allowed_ips" == "0.0.0.0/0" ]]; then
            allowed_ips="0.0.0.0/0, ::/0"
        fi
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
    # Иначе (amnezia-dns=off): два upstream DNS, AllowedIPs из ALLOWED_IPS.
    local client_dns="1.1.1.1, 1.0.0.1"
    if [[ "${AWG_AMNEZIA_DNS:-off}" == "on" && -n "${AWG_TUNNEL_SUBNET:-}" ]]; then
        client_dns=$(echo "$AWG_TUNNEL_SUBNET" | cut -d'/' -f1)
        [[ -z "$client_dns" ]] && client_dns="1.1.1.1"
        allowed_ips="0.0.0.0/0, ::/0"
    fi

    # MTU: приоритет server awg0.conf > AWG_MTU из awgsetup_cfg.init > 1280 fallback.
    # Server config - источник правды для уже работающего сервера: пользователь
    # мог поправить MTU в /etc/amnezia/amneziawg/awg0.conf руками, и regen должен
    # это подхватить (Discussion #38). Невалидные значения (вне 576-9100)
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

    # I1-I5: переносим заданные CPS-параметры в клиентский конфиг (issue #71).
    # Совпадать с серверными не обязаны - приёмник их не валидирует; regen
    # просто разносит по клиентам то, что задано на сервере.
    [[ -n "${AWG_I1:-}" ]] && echo "I1 = ${AWG_I1}" >> "$tmpfile"
    [[ -n "${AWG_I2:-}" ]] && echo "I2 = ${AWG_I2}" >> "$tmpfile"
    [[ -n "${AWG_I3:-}" ]] && echo "I3 = ${AWG_I3}" >> "$tmpfile"
    [[ -n "${AWG_I4:-}" ]] && echo "I4 = ${AWG_I4}" >> "$tmpfile"
    [[ -n "${AWG_I5:-}" ]] && echo "I5 = ${AWG_I5}" >> "$tmpfile"

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
# Операции, перезапускающие интерфейс: предупреждение и обратимость
# ==============================================================================

# awg_ssh_client_addr : адрес источника текущей SSH-сессии (пусто, если это не
# SSH или определить не удалось).
#
# ⚠️ Одного $SSH_CONNECTION НЕДОСТАТОЧНО: скрипт запускают через sudo, а sudo по
# умолчанию делает env_reset, и SSH_CONNECTION в env_keep Debian/Ubuntu не
# входит. Поэтому второй путь - who по нашему собственному tty.
# who может отдать имя хоста вместо адреса (при UseDNS yes); тогда сверка с
# подсетью не состоится, и вызывающий получит "определить не удалось" - это
# честнее, чем угадывать.
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
    # ⚠️ Приоритет у данных ПО НАШЕМУ tty, а не у унаследованной переменной.
    # SSH_CONNECTION приезжает из окружения и в переподключённой сессии
    # tmux/screen может указывать на ПРЕЖНЕЕ подключение - тогда мы выдали бы
    # уверенно неверный вердикт. utmp по своему tty описывает текущее.
    # Но если tty-путь дал не адрес (при UseDNS yes там будет имя хоста),
    # берём переменную: годный адрес полезнее честного «не знаю».
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

# _awg_tunnel_subnet : подсеть туннеля как addr/prefix, либо пустая строка.
#
# 🔴 ДЕФОЛТА ЗДЕСЬ НЕТ СОЗНАТЕЛЬНО, и это исправление критического дефекта.
# Прежняя редакция подставляла литерал 10.9.9.1/24, а manage на пути команды
# restart НЕ загружает awgsetup_cfg.init - значит AWG_TUNNEL_SUBNET там пуст.
# У любого, кто поставил сервер с --subnet, сессия из его подсети (например
# 10.66.66.2) сравнивалась с чужой 10.9.9.0/24 и объявлялась "не через туннель":
# скрипт уверенно утверждал ОБРАТНОЕ ИСТИНЕ ровно в том сценарии, ради которого
# проверка написана, и не показывал ни предупреждения, ни подсказки про консоль.
# Подставленный литерал превращает "данных нет" в "данные есть, и они такие".
#
# Источники по убыванию достоверности: живой интерфейс, конфиг сервера,
# переменная (её выставляет load_awg_params на других путях). Ничего не нашли -
# пусто, и вызывающий обязан сказать "не знаю", а не угадывать.
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

# awg_session_via_tunnel [адрес] : идёт ли текущая сессия ЧЕРЕЗ туннель VPN.
#   0 - да, адрес источника лежит в подсети туннеля (перезапуск оборвёт доступ);
#   1 - нет, адрес вне подсети;
#   2 - определить не удалось (не SSH, адрес не IPv4, подсеть НЕИЗВЕСТНА).
# Три состояния, а не два, сознательно: "не знаю" и "не через туннель" требуют
# РАЗНЫХ формулировок, а склеивание их в 1 выдавало бы догадку за факт.
# Адрес можно передать аргументом, чтобы вызывающий не спрашивал utmp дважды и
# не получил вердикт по одному адресу с текстом про другой.
awg_session_via_tunnel() {
    local addr="${1:-}" subnet net_int bcast_int addr_int
    [[ -n "$addr" ]] || addr="$(awg_ssh_client_addr)"
    [[ -n "$addr" ]] || return 2
    [[ "$addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 2
    subnet="$(_awg_tunnel_subnet)"
    [[ -n "$subnet" ]] || return 2
    # 🔴 Префикс /31 и /32 не несёт диапазона хостов, поэтому по нему нельзя
    # ответить на наш вопрос: любой адрес кроме серверного окажется "вне
    # подсети", и мы уверенно сказали бы "доступ не пострадает" человеку,
    # сидящему в туннеле. Наш генератор пишет /16../30, но путь через живой
    # интерфейс наследует ЛЮБОЙ префикс, а /32 в [Interface] - обычная
    # практика WireGuard. Отвечаем "не знаю" (проверено на стенде).
    [[ "${subnet##*/}" =~ ^[0-9]+$ ]] || return 2
    (( 10#${subnet##*/} <= 30 )) || return 2
    read -r net_int bcast_int < <(_cidr_bounds "$subnet" 2>/dev/null) || return 2
    [[ -n "$net_int" && -n "$bcast_int" ]] || return 2
    addr_int="$(_ipv4_to_int "$addr" 2>/dev/null)" || return 2
    [[ -n "$addr_int" ]] || return 2
    (( addr_int >= net_int && addr_int <= bcast_int )) && return 0
    return 1
}

# awg_warn_interface_disruption : предупредить ДО операции, перезапускающей
# интерфейс. Вызывать раньше confirm_action, чтобы предупреждение было видно и
# при --yes (неинтерактивные запуски тоже отрезают людей от сервера).
awg_warn_interface_disruption() {
    local rc addr subnet
    log_warn "Интерфейс awg0 будет перезапущен - соединения всех клиентов прервутся на несколько секунд."
    # Адрес спрашиваем ОДИН раз и передаём в проверку: два независимых вызова
    # могли дать вердикт по одному адресу и текст про другой (или пустой).
    addr="$(awg_ssh_client_addr)"
    # Подсеть тоже резолвим ОДИН раз и ДО вердикта: прежняя редакция
    # спрашивала её второй раз уже после, и напечатанная подсеть могла
    # оказаться не той, по которой вердикт вынесен.
    subnet="$(_awg_tunnel_subnet)"
    # rc берём формой `|| rc=$?`, а НЕ `cmd; rc=$?`: под set -e вторая форма
    # прерывает функцию на ненулевом коде, то есть предупреждение оборвалось
    # бы на середине. В репозитории есть встроенный скрипт с set -euo
    # pipefail, поэтому это не гипотетический случай.
    rc=0
    awg_session_via_tunnel "$addr" || rc=$?
    case "$rc" in
        0)
            log_warn "ВНИМАНИЕ: похоже, вы подключены к серверу ЧЕРЕЗ этот же VPN."
            log_warn "  Адрес вашей сессии $addr входит в подсеть туннеля ${subnet},"
            log_warn "  значит после перезапуска текущее подключение оборвётся."
            log_warn "  Если доступ не вернётся сам - заходите через консоль или VNC в панели"
            log_warn "  вашего провайдера: она работает в обход VPN."
            ;;
        1)
            log_debug "Сессия идёт не через туннель (адрес $addr) - доступ к серверу не пострадает."
            ;;
        *)
            log_warn "  Если вы подключены к серверу ЧЕРЕЗ этот VPN, вы потеряете доступ."
            log_warn "  Запасной путь на такой случай - консоль или VNC в панели провайдера."
            ;;
    esac
}

# _awg_device_param_names : имена device-параметров AWG (2.0 и 3.0), которые
# живут в секции [Interface] и которые syncconf НЕ снимает.
_awg_device_param_names() {
    printf '%s\n' Jc Jmin Jmax S1 S2 S3 S4 H1 H2 H3 H4 I1 I2 I3 I4 I5 \
        ContentPaddingAddition HeaderProtectionKey MaxHandshakeAttempts \
        KeepaliveTimeout RejectAfterTime RekeyAfterTime RekeyTimeout
}

# _awg_device_params_fingerprint [конфиг] : отсортированный список ИМЁН
# device-параметров, присутствующих в секции [Interface]. Одной строкой.
# Только имена: значения syncconf применяет корректно, проблема ровно в снятии.
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

# _awg_save_device_params <файл состояния> <отпечаток> : запомнить применённый
# набор. Файл в AWG_DIR (root-only), потеря = мягкая деградация: следующая
# проверка просто не сработает, лишнего перезапуска не будет.
# Запись АТОМАРНАЯ (temp + mv): оборванная запись оставила бы полупустой
# снимок, а он читается как «параметры убрали» и порождает ложное
# предупреждение. Отказ не глушим совсем - пишем в debug, иначе тихая потеря
# состояния выглядела бы как успех.
# Имя temp-файла ФИКСИРОВАННОЕ, а не с $$: если процесс убьют между записью и
# mv, следующий запуск перезапишет тот же файл, а не оставит россыпь сирот.
# Гонки нет - весь участок держит flock apply_config.
# ⚠️ Отказ записи идёт в log_warn, а НЕ в log_debug. log_debug печатает только
# при --verbose и в лог-файл при этом не попадает вовсе, то есть прежняя
# редакция обещала «не глушим совсем», а по факту глушила полностью. Причины
# отказа под root (ENOSPC, remount read-only, пропавший AWG_DIR) не мягкие: в
# этот момент под угрозой и awg0.conf, и бэкапы, и лог. return 0 оставлен -
# применение конфигурации не должно падать из-за диагностического снимка.
_awg_save_device_params() {
    local state="$1" fp="$2" tmp="${1}.tmp"
    if ! printf '%s\n' "$fp" > "$tmp" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        log_warn "Не удалось записать снимок параметров интерфейса ($state) - проверьте место на диске и права."
        return 0
    fi
    chmod 600 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$state" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        log_warn "Не удалось заменить снимок параметров интерфейса ($state) - проверьте место на диске и права."
    fi
    return 0
}

# awg_record_device_params : запомнить, какой набор device-параметров стоит в
# конфиге СЕЙЧАС. Вызывать ПОСЛЕ успешного применения или пересоздания
# интерфейса - снимок обязан означать «то, что реально стоит на живом
# интерфейсе», иначе обнаружение снятия начинает врать в обе стороны.
#
# 🔴 Два правила, каждое из которых закрывает найденный ревью дефект:
# 1. Отпечаток считается ЗАНОВО, а не берётся посчитанный до применения: если в
#    тот момент файл перезаписывался, посчитанное было неполным, и сохранение
#    его закрепило бы неверный набор.
# 2. ПУСТОЙ набор не пишем НИКОГДА. Пустой снимок отключает проверку навсегда
#    (сравнивать не с чем), а пустота почти всегда означает недочитанный файл:
#    наш генератор всегда пишет Jc/S/H. Лучше сохранить прежний хороший снимок.
awg_record_device_params() {
    local state="${AWG_DIR}/.awg_device_params" fp
    [[ -r "$SERVER_CONF_FILE" ]] || return 0
    fp="$(_awg_device_params_fingerprint "$SERVER_CONF_FILE" 2>/dev/null)" || return 0
    [[ -n "$fp" ]] || return 0
    _awg_save_device_params "$state" "$fp"
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
    if ! _validate_iface_name "$iface"; then
        log_error "apply_config: недопустимое имя интерфейса '$iface'"
        return 1
    fi
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
        log_warn "awg-quick strip ${iface} не удался или timeout; live interface не изменён."
        exec {apply_fd}>&-
        return 1
    }

    # 🔴 syncconf НЕ СНИМАЕТ device-параметры AWG. Проверено на модуле
    # 3.0.20260731-04: поставленные Jc/S4/H1/I1/ContentPaddingAddition/
    # RekeyAfterTime остались на живом интерфейсе после применения конфига, где
    # их нет. Семантика WireGuard («setconf = полная картина») для AWG-параметров
    # не действует, она аддитивна. Значит операция «убрать параметр из awg0.conf
    # и применить» тихо не сработала бы: файл изменился, интерфейс нет, и такое
    # расхождение ничем не ловится. Снять параметр можно только пересозданием
    # интерфейса, то есть перезапуском сервиса.
    #
    # Сравниваем НАБОР ИМЁН параметров с тем, что применяли в прошлый раз, а не
    # с живым интерфейсом: `awg showconf` печатает и нейтральные значения
    # (S4 = 0, H1 = 1), поэтому сверка с ним давала бы ложные срабатывания на
    # каждом применении. Значения не сравниваем вовсе - их syncconf применяет
    # корректно, проблема ровно в снятии.
    # Состояния нет (первая установка, потерянный файл) - молчим: сравнивать не
    # с чем, а предупреждать наугад хуже, чем не предупреждать.
    # Исторический snapshot upstream описывает только awg0. Применение awg1
    # не должно читать или перезаписывать fingerprint основного интерфейса.
    local track_device_params=0
    [[ "$iface" == "awg0" ]] && track_device_params=1
    local params_state="${AWG_DIR}/.awg_device_params"
    local now_fp="" prev_fp="" removed=""
    if [[ "$track_device_params" -eq 1 && -r "$SERVER_CONF_FILE" ]]; then
        # Путь передаём явно, хотя он же и по умолчанию: иначе shellcheck 0.9
        # (та версия, что стоит в CI) справедливо ругается SC2120 на параметр,
        # который никто никогда не передаёт.
        now_fp="$(_awg_device_params_fingerprint "$SERVER_CONF_FILE" 2>/dev/null)" || now_fp=""
        [[ -r "$params_state" ]] && IFS= read -r prev_fp 2>/dev/null < "$params_state"
        # ⚠️ Пустой набор при непустом прежнем НЕ считаем удалением всего.
        # Наш генератор всегда пишет Jc/S/H, поэтому пустота означает скорее
        # недочитанный или переписываемый в этот момент файл, чем реальную
        # чистку. Молчим: ложная тревога тут дороже пропущенной.
        if [[ -n "$prev_fp" && -n "$now_fp" ]]; then
            local _p
            for _p in $prev_fp; do
                [[ " $now_fp " == *" $_p "* ]] || removed+="${removed:+, }$_p"
            done
        fi
    fi

    if [[ "${AWG_APPLY_MODE:-syncconf}" == "restart" || "$iface" != awg0 ]]; then
        # Явный restart-режим рвёт соединения клиентов, в том числе SSH через
        # туннель, поэтому предупреждаем так же, как при manage restart.
        [[ "$track_device_params" -eq 1 ]] && awg_warn_interface_disruption
        log "Перезапуск сервиса ${iface} (preflight выполнен; routing/device changes требуют restart)..."
        if systemctl restart "awg-quick@${iface}" 2>/dev/null; then
            systemctl is-active --quiet "awg-quick@${iface}" 2>/dev/null; rc=$?
        else
            rc=$?
        fi
        if [[ $rc -ne 0 ]]; then
            log_warn "Ошибка перезапуска ${iface}."
        elif [[ "$track_device_params" -eq 1 ]]; then
            awg_record_device_params
        fi
        exec {apply_fd}>&-
        return $rc
    fi

    # 🔴 Обнаруженное снятие параметра НЕ перезапускаем сами - предупреждаем.
    # Первая редакция этой правки перезапускала сервис автоматически, и это было
    # ХУЖЕ той ловушки, которую закрывало: перезапуск рвёт соединения ВСЕХ
    # клиентов, а состояние может отстать без всякой вины пользователя. Пример:
    # человек убрал строку и применил её через `manage restart` - интерфейс уже
    # пересоздан, параметр уже снят, но снимок набора остался прежним, и
    # следующий обычный `add` увидел бы "удаление" второй раз и оборвал всех
    # заново. Цена ложного предупреждения - строка в журнале; цена ложного
    # перезапуска - обрыв у всех. Поэтому говорим, а решает человек.
    # ⚠️ Снимок здесь НЕ обновляем. Он обновляется только ПОСЛЕ успешного
    # применения, ниже. Прежняя редакция обновляла его сразу, и это гасило
    # предупреждение навсегда, если применение потом падало: состояние уже
    # «догнало» файл, а на живом интерфейсе не изменилось ничего.
    if [[ -n "$removed" ]]; then
        log_warn "Из секции [Interface] убрано: ${removed}."
        log_warn "  syncconf такие параметры НЕ снимает - на живом интерфейсе они останутся."
        log_warn "  Чтобы снятие вступило в силу, интерфейс надо пересоздать:"
        log_warn "    systemctl restart awg-quick@awg0"
        log_warn "  Это оборвёт соединения всех клиентов на несколько секунд, поэтому"
        log_warn "  сами мы этого не делаем. Если вы уже перезапускали сервис вручную,"
        log_warn "  предупреждение можно игнорировать: после успешного применения снимок"
        log_warn "  обновится, и на следующих запусках этой строки не будет."
    fi

    printf '%s\n' "$strip_out" | timeout 10 awg syncconf "${iface}" /dev/stdin 2>/dev/null || {
        log_warn "awg syncconf ${iface} не удался или timeout; полный restart не выполняется автоматически."
        exec {apply_fd}>&-
        return 1
    }
    log_debug "Конфигурация ${iface} применена (syncconf)."
    [[ "$track_device_params" -eq 1 ]] && awg_record_device_params
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
# Между awg1 и exit обязаны совпасть S1-S4/H1-H4 и, если задан,
# HeaderProtectionKey. Jc/Jmin/Jmax и I1-I5 принимающая сторона не сверяет.
#
# Защита от command injection: извлекаемые из upstream-конфига значения (ключи,
# IP, Endpoint) проходят типовые и контрольные проверки, потом пишутся в файл
# через awg_mktemp + mv, никогда не через eval.

# Проверка имени интерфейса (защита от injection в systemctl/iptables)
_validate_iface_name() {
    local n="$1"
    [[ "$n" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]]
}

# AWG 3.0 хранит шесть таймеров/счётчиков как u16 range: "N" или "N-M".
# Проверяем формат до переноса из внешнего клиентского конфига в awg1.conf.
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

# Endpoint из импортируемого конфига: IPv4/FQDN:port или [IPv6]:port.
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
    local client_subnet="${AWG_TUNNEL_SUBNET:-}" client_subnet_raw

    if [[ -z "$src" || ! -f "$src" ]]; then
        log_error "render_upstream_config: AWG_UPSTREAM_CONF не задан или файл не найден: '$src'"
        return 1
    fi
    if ! _validate_upstream_structure "$src"; then
        log_error "render_upstream_config: нужен ровно один [Interface], один [Peer] и уникальные ключи секций"
        return 1
    fi
    if ! _validate_iface_name "$iface"; then
        log_error "render_upstream_config: недопустимое имя интерфейса '$iface'"
        return 1
    fi
    if ! [[ "$tbl" =~ ^[0-9]{1,10}$ ]] \
        || (( 10#$tbl < 1 || 10#$tbl > 4294967295 \
              || (10#$tbl >= 253 && 10#$tbl <= 255) )); then
        log_error "render_upstream_config: недопустимый Table='$tbl'"
        return 1
    fi
    local fwmark_num
    if [[ "$fwmark" =~ ^0x[0-9a-fA-F]{1,8}$ ]]; then
        fwmark_num=$((16#${fwmark#0x}))
    elif ! [[ "$fwmark" =~ ^[0-9]{1,10}$ ]] \
        || (( 10#$fwmark > 4294967295 )); then
        log_error "render_upstream_config: недопустимый FwMark='$fwmark'"
        return 1
    else
        fwmark_num=$((10#$fwmark))
    fi
    if (( fwmark_num == 0 || fwmark_num == 0xca6c )); then
        log_error "render_upstream_config: FwMark='$fwmark' равен нулю или конфликтует с awg0"
        return 1
    fi
    if ! [[ "$prio" =~ ^[0-9]{1,5}$ ]] \
        || (( 10#$prio < 1 || 10#$prio > 32764 )); then
        log_error "render_upstream_config: недопустимый priority='$prio'"
        return 1
    fi
    if [[ -z "$client_subnet" ]]; then
        log_error "render_upstream_config: AWG_TUNNEL_SUBNET не задан"
        return 1
    fi
    client_subnet_raw="$client_subnet"
    client_subnet=$(_awg_network_cidr "$client_subnet") || {
        log_error "render_upstream_config: недопустимая подсеть клиентов '$client_subnet_raw'"
        return 1
    }
    tbl=$((10#$tbl))
    prio=$((10#$prio))
    [[ "$fwmark" == 0x* ]] || fwmark=$((10#$fwmark))

    # Извлекаем поля из upstream-конфига
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
             u_jc u_jmin u_jmax u_s1 u_s2 u_s3 u_s4 u_h1 u_h2 u_h3 u_h4 \
             u_i1 u_i2 u_i3 u_i4 u_i5 u_padding u_header_key u_max_handshakes \
             u_keepalive_timeout u_reject_after u_rekey_after u_rekey_timeout; do
        local v="${!f}"
        if [[ "$v" == *$'\n'* || "$v" == *$'\r'* || "$v" == *\'* || "$v" == *\"* ]]; then
            log_error "render_upstream_config: подозрительные символы в ${f#u_}, отклонено"
            return 1
        fi
    done

    if ! _valid_wg_key_b64 "$u_priv" || ! _valid_wg_key_b64 "$u_pub" \
        || { [[ -n "$u_psk" ]] && ! _valid_wg_key_b64 "$u_psk"; }; then
        log_error "render_upstream_config: некорректный 32-byte base64 ключ WireGuard"
        return 1
    fi
    if ! _valid_awg_decimal "$u_jc" 1 128 \
        || ! _valid_awg_decimal "$u_jmin" 0 1280 \
        || ! _valid_awg_decimal "$u_jmax" 0 1280 \
        || (( 10#$u_jmin > 10#$u_jmax )); then
        log_error "render_upstream_config: недопустимые Jc/Jmin/Jmax (Jc=1-128, J=0-1280, Jmin<=Jmax)"
        return 1
    fi
    if ! _valid_awg_decimal "$u_s1" 0 65535 \
        || ! _valid_awg_decimal "$u_s2" 0 65535 \
        || ! _valid_awg_decimal "$u_s3" 0 64 \
        || ! _valid_awg_decimal "$u_s4" 0 32; then
        log_error "render_upstream_config: недопустимые S1-S4"
        return 1
    fi
    local -a h_lows=() h_highs=() h_names=()
    local h_value h_i h_j
    for f in u_h1 u_h2 u_h3 u_h4; do
        h_value="${!f}"
        if ! _valid_awg_h_range "$h_value"; then
            log_error "render_upstream_config: недопустимый диапазон ${f#u_}='$h_value'"
            return 1
        fi
        h_lows+=("$((10#${h_value%-*}))")
        h_highs+=("$((10#${h_value#*-}))")
        h_names+=("${f#u_}")
    done
    for ((h_i = 0; h_i < 4; h_i++)); do
        for ((h_j = h_i + 1; h_j < 4; h_j++)); do
            if (( h_lows[h_i] <= h_highs[h_j] && h_lows[h_j] <= h_highs[h_i] )); then
                log_error "render_upstream_config: диапазоны ${h_names[h_i]} и ${h_names[h_j]} пересекаются"
                return 1
            fi
        done
    done

    # Из dual-stack Address берём IPv4 и канонизируем адрес интерфейса до /32.
    # Внешний конфиг нельзя интерполировать в awg1.conf до типовой проверки.
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
        log_error "render_upstream_config: недопустимый IPv4 Address='$u_addr'"
        return 1
    fi
    if ! _valid_upstream_endpoint "$u_endpoint"; then
        log_error "render_upstream_config: недопустимый Endpoint='$u_endpoint'"
        return 1
    fi
    if [[ -n "$u_keepalive" ]] \
        && { ! [[ "$u_keepalive" =~ ^[0-9]{1,5}$ ]] || (( 10#$u_keepalive > 65535 )); }; then
        log_error "render_upstream_config: недопустимый PersistentKeepalive='$u_keepalive'"
        return 1
    fi
    if [[ -n "$u_header_key" ]] && ! _valid_wg_key_b64 "$u_header_key"; then
        log_error "render_upstream_config: недопустимый HeaderProtectionKey"
        return 1
    fi
    if [[ -n "$u_header_key" ]]; then
        local header_s
        for header_s in u_s1 u_s2 u_s3 u_s4; do
            if ! [[ "${!header_s}" =~ ^[0-9]{1,5}$ ]] \
                || (( 10#${!header_s} < 12 || 10#${!header_s} > 65535 )); then
                log_error "render_upstream_config: HeaderProtectionKey требует S1-S4 в диапазоне 12-65535"
                return 1
            fi
        done
    fi
    local range_field
    for range_field in u_padding u_max_handshakes u_keepalive_timeout \
                       u_reject_after u_rekey_after u_rekey_timeout; do
        if [[ -n "${!range_field}" ]] && ! _valid_awg_u16_range "${!range_field}"; then
            log_error "render_upstream_config: недопустимый диапазон ${range_field#u_}='${!range_field}'"
            return 1
        fi
    done

    local out_conf
    out_conf="$(dirname "$SERVER_CONF_FILE")/${iface}.conf"

    local conf_dir
    conf_dir=$(dirname "$out_conf")
    mkdir -p "$conf_dir" || { log_error "Ошибка создания $conf_dir"; return 1; }

    local tmpfile
    tmpfile=$(awg_mktemp "$conf_dir") || { log_error "Ошибка mktemp"; return 1; }

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
        log_error "Ошибка записи временного upstream-конфига"
        return 1
    fi

    chmod 600 "$tmpfile" || { rm -f "$tmpfile"; log_error "Ошибка chmod upstream-конфига"; return 1; }
    if ! mv -f "$tmpfile" "$out_conf"; then
        rm -f "$tmpfile"
        log_error "Ошибка записи upstream-конфига $out_conf"
        return 1
    fi
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
#   1. wgcf скачивается с github.com/ViRb3/wgcf (фиксированный релиз с
#      готовыми бинарями под amd64/arm64/armv7) и проверяется по SHA-256.
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
        *) log_error "Архитектура $(uname -m) не поддерживается wgcf"; return 1 ;;
    esac
    command -v sha256sum >/dev/null 2>&1 \
        || { log_error "sha256sum не найден; безопасная установка wgcf невозможна"; return 1; }
    local target="/usr/local/bin/wgcf"
    local binary_marker="${AWG_DIR}/.wgcf_binary_installed_by_installer"
    local owned_binary="" actual_sha=""
    if [[ -e "$binary_marker" || -L "$binary_marker" ]]; then
        [[ -f "$binary_marker" && ! -L "$binary_marker" ]] \
            || { log_error "Некорректный ownership-marker $binary_marker"; return 1; }
        owned_binary=$(<"$binary_marker")
        [[ "$owned_binary" == "$target" && "$owned_binary" != *$'\n'* ]] \
            || { log_error "Некорректный ownership-marker $binary_marker"; return 1; }
    fi
    if [[ -e "$target" || -L "$target" ]]; then
        [[ -f "$target" && ! -L "$target" ]] \
            || { log_error "Отказ использовать небезопасный $target"; return 1; }
        actual_sha=$(sha256sum -- "$target" 2>/dev/null | awk '{print $1}') \
            || { log_error "Не удалось проверить SHA-256 $target"; return 1; }
        if [[ "$actual_sha" == "$expected_sha" ]]; then
            log_debug "Проверенный wgcf v${wgcf_version} уже установлен: $target"
            return 0
        fi
        if [[ "$owned_binary" != "$target" ]]; then
            log_error "Отказ перезаписывать непроверенный $target без ownership-marker."
            return 1
        fi
    elif [[ -n "$owned_binary" ]]; then
        log_error "Stale ownership-marker $binary_marker: $target отсутствует."
        return 1
    fi
    [[ "$mode" == apply ]] || return 0
    if command -v wgcf >/dev/null 2>&1 && [[ "$(command -v wgcf)" != "$target" ]]; then
        log_warn "Игнорируется сторонний wgcf из PATH: $(command -v wgcf); будет установлен проверенный $target."
    fi
    local url="https://github.com/ViRb3/wgcf/releases/download/v${wgcf_version}/wgcf_${wgcf_version}_linux_${arch}"
    log "Скачивание wgcf v${wgcf_version}: $url"
    mkdir -p /usr/local/bin || { log_error "mkdir /usr/local/bin"; return 1; }
    local wgcf_tmp
    wgcf_tmp=$(awg_mktemp /usr/local/bin) || { log_error "mktemp для wgcf"; return 1; }
    if ! curl -fsSL --max-time 60 --retry 2 -o "$wgcf_tmp" "$url"; then
        log_error "Ошибка скачивания wgcf"
        rm -f "$wgcf_tmp"
        return 1
    fi
    if ! printf '%s  %s\n' "$expected_sha" "$wgcf_tmp" \
        | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$wgcf_tmp"
        log_error "SHA-256 wgcf v${wgcf_version} (${arch}) не совпадает; установка отменена"
        return 1
    fi
    chmod 0755 "$wgcf_tmp" || { rm -f "$wgcf_tmp"; log_error "chmod wgcf"; return 1; }
    [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] || _AWG_WARP_TX_DIRTY=1
    mv -f "$wgcf_tmp" "$target" \
        || { rm -f "$wgcf_tmp"; log_error "установка wgcf"; return 1; }
    log "wgcf установлен: $target"
    return 0
}

# Перевести ownership от старых версий форка в гранулярную модель. Legacy-код
# всегда оставлял пустой service-marker и правил существующий wgcf.conf, поэтому
# конфиг считаем управляемым (его можно нормализовать), но не созданным нами
# (uninstall обязан оставить файл). Старый код поддерживал только iface=wgcf.
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
        log_error "Некорректный legacy WARP marker $marker"; return 1;
    }
    [[ ! -s "$marker" ]] || return 0
    if [[ "$warp_iface" != "wgcf" || ! -f "$warp_conf" || -L "$warp_conf" ]]; then
        log_error "Пустой legacy WARP marker можно безопасно мигрировать только с обычным /etc/wireguard/wgcf.conf."
        return 1
    fi
    if [[ -e "$created_marker" || -L "$created_marker" ]]; then
        log_error "Legacy WARP marker конфликтует с $created_marker."
        return 1
    fi
    if [[ -e "$managed_marker" || -L "$managed_marker" ]]; then
        [[ -f "$managed_marker" && ! -L "$managed_marker" \
           && "$(<"$managed_marker")" == "$warp_conf" ]] || {
            log_error "Некорректный WARP managed-marker $managed_marker"; return 1;
        }
    fi
    _AWG_WARP_LEGACY_MIGRATION_NEEDED=1
    [[ "$mode" == apply ]] || return 0
    [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] || _AWG_WARP_TX_DIRTY=1
    if [[ ! -e "$managed_marker" && ! -L "$managed_marker" ]]; then
        printf '%s\n' "$warp_conf" > "$managed_marker" \
            && chmod 600 "$managed_marker" \
            || { rm -f "$managed_marker"; log_error "Не удалось записать $managed_marker"; return 1; }
    fi
    # Старый coarse marker не сохранял исходное состояние unit и не доказывает
    # service ownership. Снимаем двусмысленную претензию; config остаётся
    # managed+preserved, а service считается pre-existing.
    rm -f -- "$marker" || {
        log_error "Не удалось снять двусмысленный legacy WARP service-marker $marker"
        return 1
    }
    log "Legacy WARP мигрирован консервативно: config managed, service сохранён."
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
            log_error "WARP interface остался активен; config rollback отменён."
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
        || { log_error "WARP transaction snapshot уже активен."; return 1; }
    local iface="${AWG_WARP_IFACE:-wgcf}" path backup
    _validate_iface_name "$iface" && [[ "$iface" != awg0 ]] \
        || { log_error "Некорректный WARP iface для snapshot: '$iface'"; return 1; }
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
        log_error "WARP iface $iface поднят вне systemd; безопасный snapshot/rollback невозможен."
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
                log_error "Небезопасный WARP resource для snapshot: $path"
                commit_warp_egress_state
                return 1
            fi
            backup=$(awg_mktemp "$AWG_DIR") || { commit_warp_egress_state; return 1; }
            cp -p -- "$path" "$backup" \
                || { log_error "Не удалось snapshot $path"; commit_warp_egress_state; return 1; }
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
            log_error "$unit/interface всё ещё активен; WARP config не перезаписан."
            return 1
        fi
    fi
    for i in "${!_AWG_WARP_TX_PATHS[@]}"; do
        path="${_AWG_WARP_TX_PATHS[$i]}"; had="${_AWG_WARP_TX_HAD[$i]}"; backup="${_AWG_WARP_TX_BACKUPS[$i]}"
        dir=$(dirname "$path")
        if [[ -L "$path" || -L "$dir" || ( -e "$path" && ! -f "$path" ) ]]; then
            log_error "Небезопасный WARP resource при rollback: $path"; failed=1; continue
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
        log_error "WARP resources восстановлены не полностью; unit оставлен остановленным."
        return 1
    fi
    _restore_warp_setup_state "$unit" "$_AWG_WARP_TX_WAS_ENABLED" "$_AWG_WARP_TX_WAS_ACTIVE" \
        0 "" "/etc/wireguard/${iface}.conf" \
        || { log_error "Не удалось восстановить состояние $unit."; return 1; }
    commit_warp_egress_state
}

# Зарегистрировать Cloudflare WARP-аккаунт и сгенерировать wgcf.conf с Table=off.
# Идемпотентно: если оба файла уже есть — только проверяет/исправляет Table=off.
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
        log_debug "setup_warp_egress: AWG_EGRESS != warp, пропуск"
        return 0
    fi

    if ! _validate_iface_name "$warp_iface" || [[ "$warp_iface" == "awg0" ]]; then
        log_error "setup_warp_egress: недопустимый AWG_WARP_IFACE='$warp_iface'"
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
        log_error "Интерфейс $warp_iface поднят вне active $warp_unit; автоматическое изменение небезопасно."
        return 1
    fi
    if [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 1 && "$_AWG_WARP_TX_IFACE" != "$warp_iface" ]]; then
        log_error "WARP transaction snapshot принадлежит iface '$_AWG_WARP_TX_IFACE', а не '$warp_iface'."
        return 1
    fi

    migrate_legacy_warp_ownership "$warp_iface" preflight || return 1
    local legacy_migration_needed="$_AWG_WARP_LEGACY_MIGRATION_NEEDED"

    if [[ ( -e "$config_marker" || -L "$config_marker" ) \
          && ( -e "$managed_config_marker" || -L "$managed_config_marker" ) ]]; then
        log_error "Одновременно заданы created/managed WARP config markers; исправьте ownership вручную."
        return 1
    fi

    # Granular marker обязан быть обычным однострочным файлом, указывать ровно
    # на ожидаемый ресурс, а сам ресурс обязан существовать. Иначе это stale/
    # повреждённое состояние, в котором перезапись marker могла бы присвоить
    # чужой файл или потерять возможность корректного uninstall.
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
                log_error "Некорректный ownership-marker $ownership_marker"
                return 1
            fi
            ownership_value=$(<"$ownership_marker")
            if [[ "$ownership_value" != "$ownership_path" \
                  || "$ownership_value" == *$'\n'* \
                  || ! -f "$ownership_path" || -L "$ownership_path" ]]; then
                log_error "Stale или повреждённый ownership-marker $ownership_marker; исправьте его вручную."
                return 1
            fi
        fi
    done

    # Не меняем чужой WARP-конфиг: ниже удаляются DNS/IPv6 и добавляется
    # Table=off. Без ownership-marker такую правку нельзя надёжно откатить.
    if [[ -e "$warp_conf" || -L "$warp_conf" ]]; then
        local owned_warp_conf=""
        [[ "$legacy_migration_needed" -eq 1 ]] && owned_warp_conf="$warp_conf"
        [[ -r "$config_marker" ]] && IFS= read -r owned_warp_conf < "$config_marker"
        [[ -z "$owned_warp_conf" && -r "$managed_config_marker" ]] \
            && IFS= read -r owned_warp_conf < "$managed_config_marker"
        if [[ "$owned_warp_conf" != "$warp_conf" ]]; then
            log_error "Отказ изменять существующий $warp_conf: он не создан этим инсталлятором."
            log_error "Задайте свободный AWG_WARP_IFACE в конфигурации или перенесите конфиг вручную."
            return 1
        fi
    fi

    # Fail before binary/account mutations on wgcf generate's fixed temp path.
    if [[ ! -f "$warp_conf" ]]; then
        if [[ "$warp_conf" == "/etc/wireguard/wgcf-profile.conf" ]]; then
            log_error "AWG_WARP_IFACE='wgcf-profile' конфликтует с временным именем wgcf generate."
            return 1
        fi
        if [[ -e /etc/wireguard/wgcf-profile.conf || -L /etc/wireguard/wgcf-profile.conf ]]; then
            log_error "Отказ использовать существующий /etc/wireguard/wgcf-profile.conf; перенесите его вручную."
            return 1
        fi
    fi

    # Один service-marker описывает ровно один iface. Смена имени без teardown
    # оставила бы старый unit включённым, поэтому здесь безопаснее остановиться.
    if [[ -e "$marker" || -L "$marker" ]]; then
        local owned_warp_iface=""
        if [[ "$legacy_migration_needed" -eq 1 ]]; then
            : # Empty regular legacy marker was fully validated by preflight.
        elif [[ ! -f "$marker" || -L "$marker" ]] \
            || ! owned_warp_iface=$(<"$marker") \
            || [[ "$owned_warp_iface" == *$'\n'* ]] \
            || ! _validate_iface_name "$owned_warp_iface"; then
            log_error "Некорректный или legacy ownership-marker $marker; автоматическое управление небезопасно."
            return 1
        fi
        if [[ "$legacy_migration_needed" -eq 0 && "$owned_warp_iface" != "$warp_iface" ]]; then
            log_error "WARP уже управляется инсталлятором через iface '$owned_warp_iface'; сначала удалите старую конфигурацию."
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
            || { log_error "mktemp для snapshot $warp_conf"; return 1; }
        cp -p -- "$warp_conf" "$warp_conf_backup" \
            || { log_error "Не удалось сохранить исходный $warp_conf"; return 1; }
    fi

    local wgcf_was_present=0
    [[ -f /usr/local/bin/wgcf && ! -L /usr/local/bin/wgcf ]] && wgcf_was_present=1
    _download_wgcf_binary || return 1
    if [[ "$wgcf_was_present" -eq 0 ]]; then
        if ! printf '%s\n' /usr/local/bin/wgcf > "$binary_marker" \
            || ! chmod 600 "$binary_marker"; then
            rm -f /usr/local/bin/wgcf "$binary_marker"
            log_error "Не удалось записать маркер владельца $binary_marker"
            return 1
        fi
    fi

    if [[ ! -d /etc/wireguard ]]; then
        [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] || _AWG_WARP_TX_DIRTY=1
        mkdir -p /etc/wireguard || { log_error "mkdir /etc/wireguard"; return 1; }
    fi
    [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 0 ]] || _AWG_WARP_TX_DIRTY=1
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
        _wgcf_err=$(awg_mktemp "$AWG_DIR") \
            || { log_error "mktemp для stderr wgcf register"; return 1; }

        ( cd /etc/wireguard && yes 2>/dev/null | /usr/local/bin/wgcf register --accept-tos >/dev/null 2>>"$_wgcf_err" ) || true

        if [[ ! -s "$warp_account" ]]; then
            # --accept-tos не сработало (старый wgcf или реальная сетевая ошибка).
            # Пробуем legacy вариант без флага.
            ( cd /etc/wireguard && yes 2>/dev/null | /usr/local/bin/wgcf register >/dev/null 2>>"$_wgcf_err" ) || true
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
        if ! chmod 600 "$warp_account"; then
            rm -f "$warp_account"
            log_error "Не удалось защитить права $warp_account"
            return 1
        fi
        if ! printf '%s\n' "$warp_account" > "$account_marker" \
            || ! chmod 600 "$account_marker"; then
            rm -f "$warp_account" "$account_marker"
            log_error "Не удалось записать маркер владельца $account_marker"
            return 1
        fi
        log "WARP-аккаунт зарегистрирован."
    else
        log_debug "WARP-аккаунт уже зарегистрирован ($warp_account)"
    fi

    # Генерация wgcf.conf (только если нет). wgcf всегда пишет во временное
    # имя wgcf-profile.conf; чужой файл с таким именем не удаляем.
    if [[ ! -f "$warp_conf" ]]; then
        if [[ "$warp_conf" == "/etc/wireguard/wgcf-profile.conf" ]]; then
            log_error "AWG_WARP_IFACE='wgcf-profile' конфликтует с временным именем, используемым wgcf generate."
            return 1
        fi
        if [[ -e /etc/wireguard/wgcf-profile.conf || -L /etc/wireguard/wgcf-profile.conf ]]; then
            log_error "Отказ удалять существующий /etc/wireguard/wgcf-profile.conf; перенесите его вручную."
            return 1
        fi
        log "Генерация WARP-конфига..."
        ( cd /etc/wireguard && /usr/local/bin/wgcf generate >/dev/null 2>&1 ) || {
            rm -f /etc/wireguard/wgcf-profile.conf
            log_error "wgcf generate не удался"
            return 1
        }
        [[ -f /etc/wireguard/wgcf-profile.conf ]] || {
            log_error "wgcf generate не создал wgcf-profile.conf"
            return 1
        }
        mv /etc/wireguard/wgcf-profile.conf "$warp_conf" \
            || { rm -f /etc/wireguard/wgcf-profile.conf; log_error "Не удалось записать $warp_conf"; return 1; }
        chmod 600 "$warp_conf" \
            || { rm -f "$warp_conf"; log_error "chmod $warp_conf"; return 1; }
        if ! printf '%s\n' "$warp_conf" > "$config_marker" \
            || ! chmod 600 "$config_marker"; then
            rm -f "$warp_conf" "$config_marker"
            log_error "Не удалось записать маркер владельца $config_marker"
            return 1
        fi
    else
        log_debug "WARP-конфиг уже существует ($warp_conf)"
    fi

    # Одним атомарным проходом ставим Table=off, удаляем DNS и IPv6 Address.
    # Две последовательные in-place правки оставляли бы полуконфиг при сбое;
    # дублирующий `Table = auto` после вставленного `off` мог вернуть default
    # route хоста в WARP. Здесь все Table-строки заменяются ровно одной.
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
        log_error "Некорректный $warp_conf: нужен [Interface] с IPv4 Address"
        return 1
    fi
    chmod 600 "$warp_tmp" \
        || { rm -f "$warp_tmp"; log_error "chmod $warp_tmp"; return 1; }
    mv -f "$warp_tmp" "$warp_conf" \
        || { rm -f "$warp_tmp"; log_error "не удалось атомарно обновить $warp_conf"; return 1; }
    local marker_created_this_attempt=0
    log "WARP-конфиг нормализован: Table=off, DNS/IPv6 отключены ($warp_conf)."

    # Upstream WireGuard module для wg-quick@wgcf. amneziawg — отдельный модуль,
    # его загрузка не подтягивает `wireguard`, без которого `ip link add dev
    # wgcf type wireguard` падает. На Ubuntu 24.04/Debian 13 модуль встроен в
    # ядро или доступен из linux-modules — modprobe обычно работает без доп.
    # пакетов. Не фейлим установку если modprobe упал: wg-quick сам попробует.
    if ! lsmod 2>/dev/null | grep -q -w wireguard; then
        log "Загрузка модуля wireguard (нужен для wg-quick@wgcf)..."
        modprobe wireguard 2>/dev/null || log_warn "modprobe wireguard не удался — wg-quick попробует сам."
    fi

    local service_action
    if [[ "$service_was_active" -eq 1 ]]; then
        # restart применяет атомарно нормализованный конфиг и не меняет
        # enabled/disabled-состояние ранее существовавшего unit.
        service_action="restart"
    elif [[ "$service_was_enabled" -eq 1 ]]; then
        service_action="start"
    else
        service_action="enable-now"
    fi
    log "Запуск wg-quick@${warp_iface} (действие: ${service_action})..."
    local _sc_err
    _sc_err=$(awg_mktemp "$AWG_DIR") \
        || {
            _restore_warp_setup_state "$warp_unit" "$service_was_enabled" "$service_was_active" \
                "$warp_conf_existed" "$warp_conf_backup" "$warp_conf" \
                || log_error "Rollback WARP config/service завершён не полностью."
            log_error "mktemp для stderr systemctl WARP"
            return 1
        }
    local service_rc=0
    case "$service_action" in
        restart)    systemctl restart "$warp_unit" 2>"$_sc_err" || service_rc=$? ;;
        start)      systemctl start "$warp_unit" 2>"$_sc_err" || service_rc=$? ;;
        enable-now) systemctl enable --now "$warp_unit" 2>"$_sc_err" || service_rc=$? ;;
    esac
    if [[ "$service_rc" -ne 0 ]]; then
        log_error "systemctl ${service_action} wg-quick@${warp_iface} упал"
        [[ -s "$_sc_err" ]] && while IFS= read -r _ln; do log_error "  $_ln"; done < "$_sc_err"
        # Дамп статуса сервиса для диагностики (ExecStart exit code, logs)
        systemctl status "wg-quick@${warp_iface}" --no-pager -l 2>&1 | head -30 \
            | while IFS= read -r _ln; do log_error "status: $_ln"; done
        _restore_warp_setup_state "$warp_unit" "$service_was_enabled" "$service_was_active" \
            "$warp_conf_existed" "$warp_conf_backup" "$warp_conf" \
            || log_error "Rollback WARP config/service завершён не полностью."
        return "$service_rc"
    fi

    # Маркер сервиса появляется только если unit не был enabled/active до нас.
    # Uninstall обязан останавливать/disable только при наличии этого маркера.
    if [[ ! -e "$marker" && ! -L "$marker" \
          && "$service_was_enabled" -eq 0 && "$service_was_active" -eq 0 ]]; then
        if ! printf '%s\n' "$warp_iface" > "$marker" 2>/dev/null \
            || ! chmod 600 "$marker" 2>/dev/null; then
            rm -f "$marker" 2>/dev/null
            _restore_warp_setup_state "$warp_unit" "$service_was_enabled" "$service_was_active" \
                "$warp_conf_existed" "$warp_conf_backup" "$warp_conf" \
                || log_error "Rollback WARP config/service завершён не полностью."
            log_error "Не удалось записать ownership-marker сервиса $marker"
            return 1
        fi
        marker_created_this_attempt=1
    elif [[ ! -e "$marker" && ! -L "$marker" ]]; then
        log_warn "$warp_unit существовал до установки; инсталлятор не будет считать сервис своим."
    fi

    # Ждём появления интерфейса (до 5 сек)
    local _i
    for _i in 1 2 3 4 5; do
        if ip link show "$warp_iface" >/dev/null 2>&1; then
            log "Интерфейс $warp_iface поднят."
            return 0
        fi
        sleep 1
    done
    log_error "Интерфейс $warp_iface так и не поднялся за 5 сек."
    log_error "systemctl status wg-quick@${warp_iface}:"
    systemctl status "wg-quick@${warp_iface}" --no-pager -l 2>&1 | head -30 \
        | while IFS= read -r _ln; do log_error "  $_ln"; done
    log_error "journalctl -u wg-quick@${warp_iface} -n 20:"
    journalctl -u "wg-quick@${warp_iface}" -n 20 --no-pager 2>&1 \
        | while IFS= read -r _ln; do log_error "  $_ln"; done
    [[ "$marker_created_this_attempt" -eq 0 ]] || rm -f -- "$marker"
    _restore_warp_setup_state "$warp_unit" "$service_was_enabled" "$service_was_active" \
        "$warp_conf_existed" "$warp_conf_backup" "$warp_conf" \
        || log_error "Rollback WARP config/service завершён не полностью."
    return 1
}

# Установка WARP bypass (обход WARP для специфичных dst — YouTube/CDN/etc.).
# Пишет /usr/local/sbin/awg-warp-bypass.sh, systemd unit + timer, конфиг
# /etc/amnezia/amneziawg/warp-bypass.conf по значению AWG_WARP_BYPASS
# (comma-separated: youtube | custom:URL | custom:/path).
# Timer/service самостоятельно владеют refresh; awg0 PostUp их не запускает,
# чтобы не гоняться с транзакционной заменой bundle/ledger в установщике.
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
                _abort_warp_bypass_setup "Не удалось отключить прежний WARP bypass"
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
            || { log_error "Некорректный WARP bypass marker: $marker"; return 1; }
        marker_value=$(<"$marker")
        [[ -z "$marker_value" || "$marker_value" == "v2" ]] \
            || { log_error "Неизвестный формат WARP bypass marker: $marker"; return 1; }
        for owned_path in "$bypass_conf" "$bypass_envfile" "$bypass_script" "$bypass_svc" "$bypass_timer" "$routes_file"; do
            [[ ! -L "$owned_path" && ( ! -e "$owned_path" || -f "$owned_path" ) ]] \
                || { log_error "Отказ изменять небезопасный WARP bypass resource: $owned_path"; return 1; }
        done
    else
        for owned_path in "$bypass_conf" "$bypass_envfile" "$bypass_script" "$bypass_svc" "$bypass_timer" "$routes_file"; do
            if [[ -e "$owned_path" || -L "$owned_path" ]]; then
                log_error "Отказ перезаписывать чужой WARP bypass ресурс без marker: $owned_path"
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
            || { rm -f "$marker_tmp"; _abort_warp_bypass_setup "Не удалось создать $marker"; return 1; }
        marker_value="v2"
    fi

    mkdir -p "$conf_dir" /etc/default /usr/local/sbin || {
        _abort_warp_bypass_setup "setup_warp_bypass: mkdir"; return 1;
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
    tmp_conf=$(awg_mktemp "$conf_dir") || { _abort_warp_bypass_setup "mktemp config"; return 1; }
    if ! {
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
    } > "$tmp_conf"; then
        rm -f "$tmp_conf"
        _abort_warp_bypass_setup "запись временного $bypass_conf"
        return 1
    fi
    chmod 600 "$tmp_conf" && mv -f "$tmp_conf" "$bypass_conf" \
        || { rm -f "$tmp_conf"; _abort_warp_bypass_setup "запись $bypass_conf"; return 1; }

    # 2. Env-файл с номером table для скрипта и systemd unit.
    local tmp_env
    tmp_env=$(awg_mktemp "$(dirname "$bypass_envfile")") \
        || { _abort_warp_bypass_setup "mktemp env"; return 1; }
    printf 'WARP_TABLE=%s\n' "$warp_tbl" > "$tmp_env" \
        && chmod 0644 "$tmp_env" && mv -f "$tmp_env" "$bypass_envfile" \
        || { rm -f "$tmp_env"; _abort_warp_bypass_setup "запись $bypass_envfile"; return 1; }

    # 3. /usr/local/sbin/awg-warp-bypass.sh — ядро логики.
    # Heredoc в кавычках чтобы bash не интерполировал ${...} и $... здесь.
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
        _abort_warp_bypass_setup "запись временного $bypass_script"
        return 1
    fi
    chmod 0755 "$tmp_script" && mv -f "$tmp_script" "$bypass_script" \
        || { rm -f "$tmp_script"; _abort_warp_bypass_setup "запись $bypass_script"; return 1; }

    # 4. systemd service — oneshot, без RemainAfterExit, чтобы каждый start
    # запускал ExecStart заново (нужно для timer + PostUp awg0 на restart).
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
        _abort_warp_bypass_setup "запись временного $bypass_svc"
        return 1
    fi
    chmod 0644 "$tmp_svc" && mv -f "$tmp_svc" "$bypass_svc" \
        || { rm -f "$tmp_svc"; _abort_warp_bypass_setup "запись $bypass_svc"; return 1; }

    # 5. systemd timer — раз в 6 часов обновляем (IP-диапазоны YouTube/CDN
    # и DNS-записи меняются заметно чаще чем мы перекатываем установщик).
    # Persistent=true: прогоняется после reboot если пропустили срабатывание.
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
        _abort_warp_bypass_setup "запись временного $bypass_timer"
        return 1
    fi
    chmod 0644 "$tmp_timer" && mv -f "$tmp_timer" "$bypass_timer" \
        || { rm -f "$tmp_timer"; _abort_warp_bypass_setup "запись $bypass_timer"; return 1; }

    # 6. Маркер для uninstall + активация.
    if [[ "$marker_value" != "v2" ]]; then
        marker_tmp=$(awg_mktemp "$AWG_DIR") \
            || { _abort_warp_bypass_setup "mktemp marker"; return 1; }
        printf 'v2\n' > "$marker_tmp" && chmod 600 "$marker_tmp" && mv -f "$marker_tmp" "$marker" \
            || { rm -f "$marker_tmp"; _abort_warp_bypass_setup "Не удалось обновить $marker"; return 1; }
    fi
    systemctl daemon-reload \
        || { _abort_warp_bypass_setup "systemctl daemon-reload"; return 1; }
    # Сначала синхронно фиксируем полный ledger; Persistent timer не должен
    # запустить второй refresh поверх незавершённого первого.
    _release_warp_bypass_snapshot_lock \
        || { _abort_warp_bypass_setup "Не удалось освободить WARP bypass refresh lock"; return 1; }
    systemctl start awg-warp-bypass.service >/dev/null 2>&1 \
        || { _abort_warp_bypass_setup "awg-warp-bypass.service: начальный запуск не удался"; return 1; }
    systemctl enable --now awg-warp-bypass.timer >/dev/null 2>&1 \
        || { _abort_warp_bypass_setup "awg-warp-bypass.timer: enable --now не удался"; return 1; }

    local src_count
    src_count=$(grep -c -v -E '^[[:space:]]*(#|$)' "$bypass_conf" 2>/dev/null || true)
    src_count="${src_count:-0}"
    [[ "$bypass_tx_owned_here" -eq 0 ]] || _commit_warp_bypass_setup_state
    log "WARP bypass настроен: $src_count источников (см. $bypass_conf), автообновление каждые 6 часов."
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
            log_error "Таймаут ожидания lock WARP bypass при удалении."
            exec {bypass_lock_fd}>&-
            bypass_lock_fd=""
            teardown_failed=1
        fi
    fi
    if [[ "$teardown_failed" -eq 0 ]]; then
        if systemctl is-active --quiet awg-warp-bypass.timer 2>/dev/null \
            && ! systemctl stop awg-warp-bypass.timer >/dev/null 2>&1; then
            log_error "Не удалось остановить WARP bypass timer перед удалением."
            teardown_failed=1
        fi
        if systemctl is-active --quiet awg-warp-bypass.service 2>/dev/null \
            && ! systemctl stop awg-warp-bypass.service >/dev/null 2>&1; then
            log_error "Не удалось остановить WARP bypass service перед удалением."
            teardown_failed=1
        fi
        if systemctl is-active --quiet awg-warp-bypass.timer 2>/dev/null \
            || systemctl is-active --quiet awg-warp-bypass.service 2>/dev/null; then
            log_error "WARP bypass units не перешли в quiescent state; удаление отменено."
            teardown_failed=1
        fi
    fi

    # Revalidate marker, every owned path, ledger and exact kernel nexthops
    # only after timer/service are stopped and while holding the refresh lock.
    if [[ "$teardown_failed" -eq 0 ]]; then
        if [[ ! -f "$marker" || -L "$marker" ]]; then
            log_error "Некорректный WARP bypass marker: $marker"
            teardown_failed=1
        else
            marker_value=$(<"$marker")
            if [[ -n "$marker_value" && "$marker_value" != "v2" ]]; then
                log_error "Неизвестный формат WARP bypass marker: $marker"
                teardown_failed=1
            fi
        fi
    fi
    if [[ "$teardown_failed" -eq 0 ]]; then
        for owned_path in "$bypass_conf" "$bypass_envfile" "$bypass_script" "$bypass_svc" "$bypass_timer" "$routes_file"; do
            if [[ -L "$owned_path" || ( -e "$owned_path" && ! -f "$owned_path" ) ]]; then
                log_error "Symlink/необычный файл в WARP bypass ownership: $owned_path"
                teardown_failed=1
                break
            fi
        done
    fi
    if [[ "$teardown_failed" -eq 0 && "$marker_value" == "v2" ]]; then
        if ! _parse_warp_bypass_ledger "$routes_file"; then
            log_error "Некорректный или пустой WARP bypass route ledger."
            teardown_failed=1
        else
            table="$_AWG_BYPASS_PARSED_TABLE"
            old_routes=("${_AWG_BYPASS_PARSED_ROUTES[@]}")
        fi
        if [[ "$teardown_failed" -eq 0 ]]; then
            for line in "${old_routes[@]}"; do
                if ! route_line=$(ip -o -4 route show table "$table" exact "$line" 2>/dev/null); then
                    log_error "Не удалось проверить route $line в table $table."
                    teardown_failed=1
                    break
                fi
                if [[ -z "$route_line" ]]; then
                    route_present["$line"]=0
                    continue
                fi
                if [[ "$route_line" == *$'\n'* ]]; then
                    log_error "Неоднозначный owned route $line в table $table."
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
                    log_error "Небезопасное текущее состояние owned route $line; teardown отменён."
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
        log_error "Не удалось disable WARP bypass timer."
        teardown_failed=1
    fi
    if [[ "$teardown_failed" -eq 0 ]] \
        && systemctl is-enabled --quiet awg-warp-bypass.service 2>/dev/null \
        && ! systemctl disable awg-warp-bypass.service >/dev/null 2>&1; then
        log_error "Не удалось disable WARP bypass service."
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
                    log_error "Не удалось удалить owned route $line; выполняется rollback."
                    teardown_failed=1
                    break
                fi
            done
        elif [[ -n "$table" ]]; then
            # Legacy marker proves no per-route ownership, so never flush its table.
            log_warn "Legacy WARP bypass без route ledger: неизвестные routes в table $table оставлены без active policy rule."
        fi
    fi
    if [[ "$teardown_failed" -eq 0 ]]; then
        for owned_path in "$bypass_svc" "$bypass_timer" "$bypass_script" "$bypass_conf" "$bypass_envfile" "$routes_file"; do
            if ! rm -f -- "$owned_path"; then
                log_error "Не удалось удалить owned WARP bypass resource: $owned_path"
                teardown_failed=1
                break
            fi
        done
    fi
    if [[ "$teardown_failed" -eq 0 ]] && ! systemctl daemon-reload; then
        log_error "systemctl daemon-reload после WARP bypass teardown не удался."
        teardown_failed=1
    fi
    if [[ "$teardown_failed" -eq 0 ]] && ! rm -f -- "$marker"; then
        log_error "Не удалось удалить WARP bypass marker: $marker"
        teardown_failed=1
    fi

    if [[ -n "$bypass_lock_fd" ]]; then
        _AWG_BYPASS_TX_SNAPSHOT_LOCK_FD="$bypass_lock_fd"
        bypass_lock_fd=""
    fi
    if [[ "$teardown_failed" -ne 0 ]]; then
        if [[ "$teardown_tx_owned_here" -eq 1 ]]; then
            _rollback_warp_bypass_setup_state \
                || log_error "Rollback WARP bypass teardown завершён не полностью."
        fi
        return 1
    fi
    [[ "$teardown_tx_owned_here" -eq 0 ]] || _commit_warp_bypass_setup_state
    log "WARP bypass полностью снят."
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
        || { log_error "Предыдущая AmneziaDNS transaction ещё не завершена."; return 1; }
    case "${AWG_ROLE:-single}" in
        single|entry) ;;
        *) log_error "setup_amnezia_dns: role=${AWG_ROLE} (нужен single или entry)"; return 1 ;;
    esac

    local server_ip="${AWG_TUNNEL_SUBNET%%/*}"
    _valid_ipv4 "$server_ip" \
        || { log_error "Некорректный tunnel-gateway '$server_ip' для AmneziaDNS"; return 1; }
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
            log_error "Небезопасный каталог AmneziaDNS: $tmp"
            return 1
        fi
    done
    for tmp in "$marker" "$conf_file" "$resolved_file"; do
        if [[ -L "$tmp" || ( -e "$tmp" && ! -f "$tmp" ) ]]; then
            log_error "Небезопасный fixed path AmneziaDNS: $tmp"
            return 1
        fi
    done

    if [[ -e "$marker" ]]; then
        _read_amnezia_dns_marker "$marker" \
            || { log_error "Некорректный AmneziaDNS marker: $marker"; return 1; }
        old_gateway="$_DNS_MARKER_GATEWAY"; resolved_owned="$_DNS_MARKER_RESOLVED"
        was_enabled="$_DNS_MARKER_WAS_ENABLED"; was_active="$_DNS_MARKER_WAS_ACTIVE"
        old_udp="$_DNS_MARKER_UFW_UDP"; old_tcp="$_DNS_MARKER_UFW_TCP"
        marker_had=1
        if [[ "$resolved_owned" -eq 0 && -e "$resolved_file" ]]; then
            log_error "Чужой resolved drop-in появился по $resolved_file; отказ от перезаписи."
            return 1
        fi
    else
        if [[ -e "$conf_file" || -e "$resolved_file" ]]; then
            log_error "Отказ перезаписывать существующий AmneziaDNS/dnsmasq ресурс без ownership marker."
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
        cp -p -- "$marker" "$marker_bak" || { log_error "Не удалось сохранить AmneziaDNS marker"; return 1; }
    fi
    if [[ -f "$conf_file" ]]; then
        conf_had=1; conf_bak=$(awg_mktemp "$AWG_DIR") || return 1
        cp -p -- "$conf_file" "$conf_bak" || { log_error "Не удалось сохранить $conf_file"; return 1; }
    fi
    if [[ -f "$resolved_file" ]]; then
        resolved_had=1; resolved_bak=$(awg_mktemp "$AWG_DIR") || return 1
        cp -p -- "$resolved_file" "$resolved_bak" || { log_error "Не удалось сохранить $resolved_file"; return 1; }
    fi

    if command -v ufw >/dev/null 2>&1; then
        ufw_available=1
        for proto in udp tcp; do
            _amnezia_dns_ufw_rule_exists "$server_ip" "$proto"; rc=$?
            if (( rc == 2 )); then
                log_error "Не удалось проверить UFW ownership для AmneziaDNS."
                return 1
            fi
            owned="$old_udp"; [[ "$proto" == tcp ]] && owned="$old_tcp"
            if (( rc == 0 )) && { [[ "$old_gateway" != "$server_ip" ]] || [[ "$owned" -ne 1 ]]; }; then
                log_error "Правило UFW с тегом ${_AMNEZIA_DNS_UFW_COMMENT} не принадлежит текущему marker."
                return 1
            fi
            if [[ "$old_gateway" != "$server_ip" ]]; then
                _amnezia_dns_ufw_rule_exists "$old_gateway" "$proto"; rc=$?
                if (( rc == 2 )); then
                    log_error "Не удалось проверить прежнее правило UFW AmneziaDNS."
                    return 1
                fi
                if (( rc == 0 )) && [[ "$owned" -ne 1 ]]; then
                    log_error "Прежнее правило UFW с тегом AmneziaDNS не подтверждено marker."
                    return 1
                fi
            fi
        done
    elif [[ "$old_gateway" != "$server_ip" && ( "$old_udp" -eq 1 || "$old_tcp" -eq 1 ) ]]; then
        log_error "UFW недоступен: нельзя безопасно перенести принадлежащие AmneziaDNS правила."
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
            log "Установка dnsmasq для AmneziaDNS..."
            if ! DEBIAN_FRONTEND=noninteractive apt install -y dnsmasq >/dev/null 2>&1; then
                tx_failed=1; tx_error="apt install dnsmasq не удался"; break
            fi
            if ! systemctl stop dnsmasq >/dev/null 2>&1; then
                tx_failed=1; tx_error="dnsmasq: stop после установки не удался"; break
            fi
        fi

        if [[ "$need_resolved" -eq 1 ]]; then
            if ! mkdir -p "$resolved_dir"; then tx_failed=1; tx_error="mkdir $resolved_dir"; break; fi
            tmp=$(awg_mktemp "$resolved_dir") \
                || { tx_failed=1; tx_error="mktemp resolved"; break; }
            if ! { printf '%s\n' '# Managed by install_amneziawg.sh (--amnezia-dns=on).' '[Resolve]' 'DNSStubListener=no' > "$tmp" \
                && chmod 0644 "$tmp" && mv -f -- "$tmp" "$resolved_file"; }; then
                rm -f -- "$tmp"; tx_failed=1; tx_error="запись $resolved_file"; break
            fi
            resolved_owned=1
            if [[ "$resolved_before_active" -eq 1 ]] && ! systemctl restart systemd-resolved; then
                tx_failed=1; tx_error="systemd-resolved restart не удался"; break
            fi
        elif [[ "$resolved_owned" -eq 1 ]]; then
            if ! rm -f -- "$resolved_file"; then tx_failed=1; tx_error="удаление $resolved_file"; break; fi
            resolved_owned=0
            if [[ "$resolved_before_active" -eq 1 ]] && ! systemctl restart systemd-resolved; then
                tx_failed=1; tx_error="systemd-resolved restart не удался"; break
            fi
        fi

        if ! mkdir -p "$conf_dir"; then tx_failed=1; tx_error="mkdir $conf_dir"; break; fi
        tmp=$(awg_mktemp "$conf_dir") || { tx_failed=1; tx_error="mktemp dnsmasq"; break; }
        if ! cat > "$tmp" <<EOF
# AmneziaDNS — локальный резолвер для AWG-клиентов.
# Управляется install_amneziawg.sh (--amnezia-dns=on).
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
            tx_failed=1; tx_error="запись временного dnsmasq-конфига"; break
        fi
        if ! { chmod 0644 "$tmp" && mv -f -- "$tmp" "$conf_file"; }; then
            rm -f -- "$tmp"; tx_failed=1; tx_error="запись $conf_file"; break
        fi

        if [[ "$ufw_available" -eq 1 ]]; then
            for proto in udp tcp; do
                owned=0
                if [[ "$old_gateway" == "$server_ip" ]]; then
                    owned="$old_udp"; [[ "$proto" == tcp ]] && owned="$old_tcp"
                fi
                _amnezia_dns_ufw_rule_exists "$server_ip" "$proto"; rc=$?
                if (( rc == 2 )); then tx_failed=1; tx_error="чтение UFW"; break; fi
                rule_owned=0
                if (( rc == 0 )); then
                    [[ "$owned" -eq 1 ]] \
                        || { tx_failed=1; tx_error="коллизия UFW ownership"; break; }
                    rule_owned=1
                else
                    rule_count=$(_amnezia_dns_ufw_rule_count "$server_ip" "$proto") \
                        || { tx_failed=1; tx_error="чтение UFW"; break; }
                    if [[ "$rule_count" -eq 0 ]]; then
                        if [[ "$proto" == udp ]]; then
                            _AWG_DNS_TX_ATTEMPT_UDP=1
                        else
                            _AWG_DNS_TX_ATTEMPT_TCP=1
                        fi
                        if ! _amnezia_dns_add_ufw_rule "$server_ip" "$proto"; then
                            tx_failed=1; tx_error="добавление UFW ${proto}/53"; break
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
            tx_failed=1; tx_error="dnsmasq: enable --now не удался"; break
        fi
        if ! systemctl restart dnsmasq >/dev/null 2>&1; then
            tx_failed=1; tx_error="dnsmasq: restart не удался"; break
        fi

        if [[ "$ufw_available" -eq 1 && "$old_gateway" != "$server_ip" ]]; then
            if [[ "$old_udp" -eq 1 ]]; then
                _amnezia_dns_ufw_rule_exists "$old_gateway" udp; rc=$?
                if (( rc == 2 )); then tx_failed=1; tx_error="чтение прежнего UDP UFW"; break; fi
                if (( rc == 0 )); then
                    _AWG_DNS_TX_REMOVED_OLD_UDP=1
                    if ! _amnezia_dns_delete_ufw_rule "$old_gateway" udp; then
                        tx_failed=1; tx_error="удаление прежнего UDP UFW"; break
                    fi
                fi
            fi
            if [[ "$old_tcp" -eq 1 ]]; then
                _amnezia_dns_ufw_rule_exists "$old_gateway" tcp; rc=$?
                if (( rc == 2 )); then tx_failed=1; tx_error="чтение прежнего TCP UFW"; break; fi
                if (( rc == 0 )); then
                    _AWG_DNS_TX_REMOVED_OLD_TCP=1
                    if ! _amnezia_dns_delete_ufw_rule "$old_gateway" tcp; then
                        tx_failed=1; tx_error="удаление прежнего TCP UFW"; break
                    fi
                fi
            fi
        fi

        if ! _write_amnezia_dns_marker "$marker" "$server_ip" "$resolved_owned" \
            "$was_enabled" "$was_active" "$final_udp" "$final_tcp"; then
            tx_failed=1; tx_error="запись AmneziaDNS marker"; break
        fi
        break
    done

    if [[ "$tx_failed" -eq 1 ]]; then
        log_error "AmneziaDNS setup отменён: $tx_error"
        rollback_amnezia_dns_state \
            || log_error "Rollback AmneziaDNS завершён не полностью; snapshot оставлен pending."
        return 1
    fi

    [[ "$dns_tx_owned_here" -eq 0 ]] || commit_amnezia_dns_state
    log "AmneziaDNS настроен: dnsmasq слушает на ${server_ip}:53."
}

teardown_amnezia_dns() {
    local conf_file="/etc/dnsmasq.d/amneziawg.conf"
    local resolved_file="/etc/systemd/resolved.conf.d/amneziawg.conf"
    local marker="${AWG_DIR}/.amnezia_dns_enabled_by_installer"
    local path rc
    [[ -e "$marker" || -L "$marker" ]] || return 0
    _read_amnezia_dns_marker "$marker" \
        || { log_error "Некорректный AmneziaDNS marker: $marker"; return 1; }
    for path in "$AWG_DIR" "$(dirname "$conf_file")" "$(dirname "$resolved_file")"; do
        if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
            log_error "Небезопасный каталог AmneziaDNS; очистка отменена: $path"
            return 1
        fi
    done
    for path in "$conf_file" "$resolved_file"; do
        if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
            log_error "Небезопасный fixed path AmneziaDNS; очистка отменена: $path"
            return 1
        fi
    done

    if [[ "$_DNS_MARKER_UFW_UDP" -eq 1 || "$_DNS_MARKER_UFW_TCP" -eq 1 ]]; then
        command -v ufw >/dev/null 2>&1 \
            || { log_error "UFW недоступен; принадлежащие AmneziaDNS правила оставлены."; return 1; }
        if [[ "$_DNS_MARKER_UFW_UDP" -eq 1 ]]; then
            _amnezia_dns_ufw_rule_exists "$_DNS_MARKER_GATEWAY" udp; rc=$?
            (( rc != 2 )) || { log_error "Не удалось прочитать UFW; очистка отменена."; return 1; }
            _amnezia_dns_delete_ufw_rule "$_DNS_MARKER_GATEWAY" udp \
                || { log_error "Не удалось удалить принадлежащее AmneziaDNS UDP-правило."; return 1; }
        fi
        if [[ "$_DNS_MARKER_UFW_TCP" -eq 1 ]]; then
            _amnezia_dns_ufw_rule_exists "$_DNS_MARKER_GATEWAY" tcp; rc=$?
            (( rc != 2 )) || { log_error "Не удалось прочитать UFW; очистка отменена."; return 1; }
            _amnezia_dns_delete_ufw_rule "$_DNS_MARKER_GATEWAY" tcp \
                || { log_error "Не удалось удалить принадлежащее AmneziaDNS TCP-правило."; return 1; }
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
        || { log_error "Не удалось восстановить прежнее состояние dnsmasq."; return 1; }
    rm -f -- "$marker" || return 1
    log "AmneziaDNS снят; предыдущее состояние dnsmasq восстановлено."
}

# ==============================================================================
# Управление пирами
# ==============================================================================

# Получить следующий свободный IP в подсети (произвольная маска /16-/30).
# Сервер = network+1; диапазон хостов [network+1 .. broadcast-1]. Возвращает
# наименьший свободный (ранний выход) - для /16 это до 65534 позиций, но без
# полного скана в типичном случае.
get_next_client_ip() {
    local subnet="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}"
    local net_int bcast_int
    read -r net_int bcast_int < <(_cidr_bounds "$subnet") || {
        log_error "get_next_client_ip: не удалось разобрать подсеть '$subnet'"
        return 1
    }
    local server_int=$(( net_int + 1 ))

    # Ассоциативный массив для O(1) lookup. Сервер (network+1) занят.
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

    log_error "Нет свободных IP в подсети ${subnet}"
    return 1
}

# Получить IPv6-адрес клиента из его IPv4. Используется только при
# ALLOW_IPV6_TUNNEL=1. Индекс = смещение хоста в подсети (offset = ipv4 - network),
# что даёт уникальность при любой маске. Кодирование суффикса зависит от маски:
#   prefix == 24 -> десятичный offset (== последний октет; байт-в-байт как ранее),
#   иначе        -> корректный hex (printf '%x').
# Сервер (network+1, offset 1) даёт "1" в обоих режимах -> ::1 (см.
# _derive_ipv6_server_addr, не меняется). Клиенты имеют offset >= 2.
# Возвращает строку без префикса длины.
#
# get_next_client_ipv6 <ipv4_addr>
get_next_client_ipv6() {
    local ipv4="$1"
    if [[ -z "$ipv4" ]]; then
        log_error "get_next_client_ipv6: не передан IPv4-адрес"
        return 1
    fi
    local tunnel="${AWG_TUNNEL_SUBNET:-10.9.9.1/24}"
    local tprefix="${tunnel##*/}"
    local net_int bcast_int ip_int offset suffix
    read -r net_int bcast_int < <(_cidr_bounds "$tunnel") || {
        log_error "get_next_client_ipv6: не удалось разобрать подсеть '$tunnel'"
        return 1
    }
    ip_int=$(_ipv4_to_int "$ipv4") || {
        log_error "get_next_client_ipv6: некорректный IPv4 '$ipv4'"
        return 1
    }
    offset=$(( ip_int - net_int ))
    (( offset >= 1 && offset < bcast_int - net_int )) || { log_error "get_next_client_ipv6: IPv4 '$ipv4' вне подсети '$tunnel'"; return 1; }
    if [[ "$tprefix" == "24" ]]; then
        suffix="$offset"
    else
        suffix=$(printf '%x' "$offset")
    fi
    local subnet="${IPV6_SUBNET:-fddd:2c4:2c4:2c4::/64}"
    [[ "$subnet" =~ ^[0-9A-Fa-f]{1,4}(:[0-9A-Fa-f]{1,4}){0,3}::/64$ ]] \
        || { log_error "get_next_client_ipv6: некорректный IPV6_SUBNET '$subnet'"; return 1; }
    local prefix="${subnet%%::*}"
    echo "${prefix}::${suffix}"
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
    # Имя уходит в heredoc конфига (#_Name = ...): перевод строки в имени
    # дал бы инъекцию секции [Peer]. Defense-in-depth, см. generate_client.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "add_peer_to_server: невалидное имя клиента '$name'"
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
    # Defense-in-depth: тот же контракт, что в add_peer_to_server.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "remove_peer_from_server: невалидное имя клиента '$name'"
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
    ' "$SERVER_CONF_FILE" > "$tmpfile" || {
        log_error "Ошибка фильтрации серверного конфига (awk)"
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    }

    # Sanity-check ДО mv: при ENOSPC/I/O-сбое awk оставил бы пустой/обрезанный
    # tmpfile, и атомарный mv заменил бы рабочий конфиг битым (потеря
    # PrivateKey сервера и всех пиров). [Interface] обязан сохраниться.
    if ! grep -q '^\[Interface\]' "$tmpfile"; then
        log_error "Результат удаления пира выглядит битым ([Interface] отсутствует) - конфиг не изменён"
        rm -f "$tmpfile"
        exec {lock_fd}>&-
        return 1
    fi

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

    # AWG_PORT - единственное НЕкавыченное числовое поле inner JSON ("port":N).
    # Пустое/нечисловое значение дало бы "port":, - синтаксически битый JSON,
    # который Amnezia Client молча не импортирует.
    if ! [[ "${AWG_PORT:-}" =~ ^[0-9]+$ ]]; then
        log_warn "AWG_PORT не определён или не число ('${AWG_PORT:-}') - vpn:// URI не создан для '$name'."
        return 1
    fi

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
    # tr -d ' \r' - стирает пробелы И CR (на CRLF-конфигах '.+' жадно
    # затягивает \r в значение, что ломает JSON.allowed_ips).
    #
    # v5.27.1: НЕ трогать. Значение уходит в JSON-массив allowed_ips через
    # split(/,/), поэтому пробелы тут вредны - они уехали бы внутрь элементов
    # массива. Пробелы в клиентском .conf этот путь не портит: встроенный
    # конфиг вкладывается из файла как есть.
    allowed_ips=$(grep -oP 'AllowedIPs\s*=\s*\K.+' "$conf_file" | paste -sd, - | tr -d ' \r')
    # Проверяем ПУСТОТУ, а не код возврата: `||` тут не срабатывал даже на
    # строке "AllowedIPs = " без значения, потому что grep находил пробел и
    # выходил с нулём, а конвейер с paste делает статус тем более бесполезным.
    [[ -n "$allowed_ips" ]] || { log_warn "AllowedIPs не прочитан из '$conf_file' - в ссылку уйдёт полный туннель."; allowed_ips="0.0.0.0/0"; }

    # MTU/PersistentKeepalive/DNS из .conf - могли быть изменены через manage modify.
    # Клиент Amnezia при импорте vpn:// использует структурные поля inner JSON
    # (awgConfigurator берёт mtu именно из структурного поля, не из embedded config),
    # поэтому хардкод рассинхронизировал бы их с .conf - тот же класс, что issue #67
    # (structured-поле psk_key было авторитетным).
    local mtu keepalive dns_line dns1 dns2
    mtu=$(grep -oP '^MTU\s*=\s*\K[0-9]+' "$conf_file" | head -n1); mtu="${mtu:-1280}"
    keepalive=$(grep -oP '^PersistentKeepalive\s*=\s*\K[0-9]+' "$conf_file" | head -n1); keepalive="${keepalive:-33}"
    dns_line=$(grep -oP '^DNS\s*=\s*\K.+' "$conf_file" | paste -sd, - | tr -d ' \r')
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
    perl_err=$(awg_mktemp "$AWG_DIR") || { log_warn "Ошибка mktemp - vpn:// URI не создан для '$name'."; return 1; }
    # Секреты (privkey клиента, PSK) передаются в perl через env, НЕ через argv:
    # командная строка процесса видна всем пользователям в /proc/<pid>/cmdline
    # на время работы perl. server_pubkey не секрет, но идёт той же группой.
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
    #   -8    единый 8-битный byte-режим. Без него оптимизатор qrencode дробит
    #         base64-URI на чередующиеся alnum/byte сегменты, и overhead смены
    #         режимов раздувает поток за ёмкость v40-L (2953 байта). Большие
    #         конфиги с I1-I5/CPS падали с "Input data too large", хотя сами
    #         данные под лимитом (URI ~2929 байт < 2953) - в один byte-сегмент
    #         влезают. Репортёр: pqqsnupl (ntc.party).
    #   -s 6  размер модуля 6 пикселей вместо дефолтных 3 - это и есть основной фикс.
    #         На дефолтном масштабе модули были слишком мелкими, чтобы камера iPhone
    #         различала их при сканировании PNG с экрана компьютера - отсюда ошибка 900
    #         ImportInvalidConfigError в AmneziaVPN iOS у @haritos90 в issue #72.
    #   -l L  низший уровень коррекции ошибок - это уже дефолт qrencode, фиксируем явно
    #         для защиты от смены дефолта в будущих версиях библиотеки.
    #   -m 4  стандартная тихая зона из 4 модулей - тоже дефолт, фиксируем явно.
    if ! qrencode -8 -t png -l L -s 6 -m 4 -o "$tmp_png" < "$uri_file"; then
        log_error "Ошибка генерации QR vpn:// для '$name' (возможно, конфиг слишком велик для одного QR - импортируйте vpn:// из файла ${name}.vpnuri вручную)."
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
    # Контракт библиотеки (defense-in-depth): имя с метасимволами/переводами
    # строк дало бы инъекцию в пути и heredoc серверного конфига. Тот же
    # regex, что validate_client_name в manage и set_client_expiry здесь.
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "generate_client: невалидное имя клиента '$name'"
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
        log_error "Не удалось определить внешний IP сервера. Задайте AWG_ENDPOINT в awgsetup_cfg.init (или переустановите с --endpoint=IP)."
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Порт сервера приходит из живого awg0.conf (ListenPort), иначе из
    # awgsetup_cfg.init - оба правятся руками. render ставит его в
    # 'Endpoint = IP:PORT' клиентского .conf: битый порт уносится на устройство
    # и отлаживается вслепую. Отказываем явно, как generate_vpn_uri для vpn://
    # URI. Артефакты откатит _rollback ниже.
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT некорректен ('${AWG_PORT:-}') - клиентский конфиг для '$name' не создан. Проверьте ListenPort в $SERVER_CONF_FILE (или AWG_PORT в $CONFIG_FILE)."
        _rollback_client_artifacts "$name"
        exec {lock_fd}>&-
        return 1
    fi

    # Конфиг клиента
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6" || {
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
    # Контракт библиотеки (defense-in-depth): имя интерполируется в пути и
    # конфиг, поэтому валидируем здесь же, не полагаясь на вызывающего
    # (manage делает свой validate_client_name, но cron/чужой скрипт - нет).
    if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "regenerate_client: невалидное имя клиента '$name'"
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
    local current_dns="1.1.1.1, 1.0.0.1" current_keepalive="33" current_allowed_ips="${ALLOWED_IPS:-0.0.0.0/0}"
    if [[ -f "$AWG_DIR/${name}.conf" ]]; then
        local _v _raw
        # tr -d '[:space:]' стирал здесь пробелы после запятых, и regen писал
        # в .conf слипшийся список (D#38). Нормализуем, а не выкусываем.
        #
        # Строки СКЛЕИВАЮТСЯ, а не берётся первая: wg допускает повтор DNS и
        # AllowedIPs, значения при этом складываются. Прежний `tr` слеплял их в
        # заведомо невалидный CIDR, и awg-quick отказывался поднимать интерфейс
        # ГРОМКО; взять первую строку означало бы отдать пользователю валидный
        # конфиг, из которого часть сетей исчезла молча.
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
    else
        # Клиентский .conf утерян (regen как восстановление): PresharedKey
        # восстанавливаем из server [Peer]-блока, иначе пересозданный конфиг
        # вышел бы без PSK при живом PSK на сервере - handshake молча ломается.
        # Порядок полей в блоке контролируем мы (add_peer_to_server пишет
        # #_Name первым), поэтому found-then-PSK достаточно.
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

    # Тот же port-контроль, что в generate_client: битый AWG_PORT не должен
    # уйти в Endpoint пересозданного .conf.
    local _cport
    _cport=$(_sanitize_port "${AWG_PORT:-}")
    if [[ "$_cport" == "0" ]]; then
        log_error "AWG_PORT некорректен ('${AWG_PORT:-}') - конфиг '$name' не перегенерирован. Проверьте ListenPort в $SERVER_CONF_FILE (или AWG_PORT в $CONFIG_FILE)."
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
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
    render_client_config "$name" "$client_ip" "$client_privkey" "$server_pubkey" "$endpoint" "$_cport" "$client_ipv6" || {
        exec {lock_fd}>&-
        unset CLIENT_PSK
        return 1
    }

    # При regen подтягиваем новые дефолты для НЕ-кастомизированных клиентов:
    # полнотуннельный 0.0.0.0/0 получает ::/0 (нужно iOS AmneziaVPN), одиночный
    # DNS 1.1.1.1 становится парой с резервом. Значения, заданные пользователем
    # через modify, не равны старым дефолтам и потому сохраняются как есть.
    [[ "$current_allowed_ips" == "0.0.0.0/0" ]] && current_allowed_ips="0.0.0.0/0, ::/0"
    [[ "$current_dns" == "1.1.1.1" ]] && current_dns="1.1.1.1, 1.0.0.1"

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
    # Делимитер '/' (а не '|'): класс экранирования выше покрывает & \ / -
    # символ '|' в значении сломал бы sed-выражение с '|'-делимитером.
    # regen --reset-routes (Issue #170): НЕ восстанавливаем старый AllowedIPs
    # клиента - оставляем значение из render_client_config, вычисленное из
    # глобального режима маршрутизации (awgsetup_cfg.init) с корректным
    # IPv6-зеркалированием. Обычный regen сохраняет индивидуальные настройки.
    if [[ "${AWG_REGEN_RESET_ROUTES:-0}" == "1" ]]; then
        log "AllowedIPs клиента '$name' сброшен на глобальный режим маршрутизации (--reset-routes)."
    elif ! sed -i "s/^AllowedIPs = .*/AllowedIPs = ${_aip}/" "$_client_conf"; then
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
        log_error "Некорректная структура WG-ключей: нужен один Interface PrivateKey и ровно один PublicKey на Peer"
        return 1
    fi
    server_priv=$(_extract_upstream_field "$config_path" Interface PrivateKey) || server_priv=""
    _valid_wg_key_b64 "$server_priv" \
        || { log_error "Некорректный Interface PrivateKey"; return 1; }
    while IFS=$'\t' read -r kind value; do
        [[ -n "$kind" ]] || continue
        if ! _valid_wg_key_b64 "$value"; then
            log_error "Некорректный Peer ${kind}"
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

# Проверка AWG 2.0 конфигурации серверного конфига
validate_awg_config() {
    local config_path="${1:-$SERVER_CONF_FILE}"
    if [[ ! -f "$config_path" ]]; then
        log_error "Серверный конфиг не найден: $config_path"
        return 1
    fi
    _validate_server_wg_keys "$config_path" || return 1

    local ok=1
    local param val
    local int_params=("Jc" "Jmin" "Jmax" "S1" "S2" "S3" "S4")
    local range_params=("H1" "H2" "H3" "H4")

    # Парсинг выровнен с load_awg_params_from_server_conf: произвольные пробелы
    # вокруг '=', last-wins при дублях строк (валидируем то значение, которое
    # реально загрузится), trim пробелов/CR. Раньше валидатор требовал ровно
    # один пробел и брал first-wins - вручную поправленный 'Jc=4' успешно
    # загружался, но проваливал валидацию с ложным "параметр не найден".
    for param in "${int_params[@]}"; do
        val=$(_extract_upstream_field "$config_path" Interface "$param") || val=""
        if [[ -z "$val" ]]; then
            log_error "Параметр '$param' не найден в серверном конфиге"
            ok=0
        elif ! [[ "$val" =~ ^[0-9]{1,10}$ ]]; then
            log_error "Параметр '$param' содержит невалидное значение: '$val' (ожидается целое число)"
            ok=0
        fi
    done

    # Протокольные границы (defense-in-depth для восстановленных бэкапов)
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
            log_error "Jc=$jc вне допустимого диапазона (1-128)"
            ok=0
        fi
    fi
    if [[ "$jmin" =~ ^[0-9]{1,10}$ && "$jmax" =~ ^[0-9]{1,10}$ ]]; then
        if ! _valid_awg_decimal "$jmin" 0 1280; then
            log_error "Jmin=$jmin превышает 1280"
            ok=0
        fi
        if ! _valid_awg_decimal "$jmax" 0 1280; then
            log_error "Jmax=$jmax превышает 1280"
            ok=0
        fi
        if _valid_awg_decimal "$jmin" 0 1280 && _valid_awg_decimal "$jmax" 0 1280 \
            && (( 10#$jmax < 10#$jmin )); then
            log_error "Jmax ($jmax) меньше Jmin ($jmin)"
            ok=0
        fi
    fi
    if [[ "$s3" =~ ^[0-9]{1,10}$ ]] && ! _valid_awg_decimal "$s3" 0 64; then
        log_error "S3=$s3 превышает максимум (64)"
        ok=0
    fi
    if [[ "$s1" =~ ^[0-9]{1,10}$ ]] && ! _valid_awg_decimal "$s1" 0 65535; then
        log_error "S1=$s1 превышает uint16"
        ok=0
    fi
    if [[ "$s2" =~ ^[0-9]{1,10}$ ]] && ! _valid_awg_decimal "$s2" 0 65535; then
        log_error "S2=$s2 превышает uint16"
        ok=0
    fi
    if [[ "$s4" =~ ^[0-9]{1,10}$ ]] && ! _valid_awg_decimal "$s4" 0 32; then
        log_error "S4=$s4 превышает максимум (32)"
        ok=0
    fi

    local _h_ranges=()
    for param in "${range_params[@]}"; do
        val=$(_extract_upstream_field "$config_path" Interface "$param") || val=""
        if [[ -z "$val" ]]; then
            log_error "Параметр '$param' не найден в серверном конфиге"
            ok=0
        elif ! _valid_awg_h_range "$val"; then
            log_error "Параметр '$param' содержит невалидное значение: '$val' (ожидается формат MIN-MAX)"
            ok=0
        else
            local range_lo="${val%-*}" range_hi="${val#*-}"
            _h_ranges+=("$((10#$range_lo)) $((10#$range_hi)) $param")
        fi
    done

    # Попарное непересечение H1-H4 - ключевой инвариант AWG 2.0. Без этой
    # проверки конфиг из чужого бэкапа с пересекающимися диапазонами
    # проходил валидацию, хотя протокол его не допускает.
    if [[ ${#_h_ranges[@]} -eq 4 ]]; then
        local _i _j _lo1 _hi1 _n1 _lo2 _hi2 _n2
        for ((_i = 0; _i < 4; _i++)); do
            for ((_j = _i + 1; _j < 4; _j++)); do
                read -r _lo1 _hi1 _n1 <<< "${_h_ranges[$_i]}"
                read -r _lo2 _hi2 _n2 <<< "${_h_ranges[$_j]}"
                if (( _lo1 <= _hi2 && _lo2 <= _hi1 )); then
                    log_error "Диапазоны ${_n1} (${_lo1}-${_hi1}) и ${_n2} (${_lo2}-${_hi2}) пересекаются"
                    ok=0
                fi
            done
        done
    fi

    # I1 опционален. Отсутствие = либо не задан, либо намеренно отключён через
    # --no-cps (issue #159): десктопный AmneziaVPN на macOS не поддерживает CPS.
    if ! grep -qE '^[[:space:]]*I1[[:space:]]*=' "$config_path"; then
        if grep -qE '^[[:space:]]*(export[[:space:]]+)?NO_CPS=1' "$CONFIG_FILE" 2>/dev/null; then
            log "I1 (CPS) отключён намеренно (--no-cps) - ожидаемо для десктопного AmneziaVPN на macOS"
        else
            log_warn "Параметр I1 (CPS) не найден - CPS concealment не активен"
        fi
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
            if [[ -r "$SERVER_CONF_FILE" ]] && ! grep -qxF "#_Name = ${name}" "$SERVER_CONF_FILE"; then
                # Orphan-метка: peer уже удалён из конфига (вручную, через awg
                # или restore старого бэкапа). Без этой ветки cron каждые 5
                # минут вечно ретраил бы remove_peer_from_server и копил warn
                # в expiry.log, а артефакты клиента никогда не зачищались.
                # Гард [[ -r ]]: временно отсутствующий/нечитаемый конфиг
                # (mid-restore, сбой ФС) НЕ повод стирать артефакты клиента -
                # такой случай уходит в обычную ветку с warn и повтором позже.
                _remove_client_files "$name"
                remove_client_expiry "$name"
                log "Клиент '$name': peer отсутствует в конфиге - зачищены осиротевшие артефакты и expiry-метка."
            elif remove_peer_from_server "$name" 2>/dev/null; then
                _remove_client_files "$name"
                remove_client_expiry "$name"
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
*/5 * * * * root /bin/bash -c 'source "${AWG_DIR}/awg_common.sh" || exit 1; trap _awg_cleanup EXIT; check_expired_clients' >> "${AWG_DIR}/expiry.log" 2>&1
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
