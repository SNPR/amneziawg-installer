#!/bin/bash

# Проверка минимальной версии Bash
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    echo "ОШИБКА: Требуется Bash >= 4.0 (текущая: ${BASH_VERSION})" >&2; exit 1
fi

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG 2.0 на Ubuntu/Debian серверах
# Автор: @bivlked
# Версия: 5.28.1
# Дата: 2026-08-27
# Форк: https://github.com/SNPR/amneziawg-installer (upstream: bivlked)
# ==============================================================================

# --- Безопасный режим и Константы ---
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
COMMON_SCRIPT_URL="https://raw.githubusercontent.com/${AWG_REPOSITORY}/${AWG_BRANCH}/awg_common.sh"
COMMON_SCRIPT_PATH="$AWG_DIR/awg_common.sh"
MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/${AWG_REPOSITORY}/${AWG_BRANCH}/manage_amneziawg.sh"
MANAGE_SCRIPT_PATH="$AWG_DIR/manage_amneziawg.sh"

# Путь к директории installer'а — фиксируем ДО первого cd. Нужен step5'у
# чтобы обнаружить "запуск из клона" и взять awg_common.sh / manage_amneziawg.sh
# локально, не качая их из CDN. Резолв через relative BASH_SOURCE[0] ПОСЛЕ
# того, как initialize_setup сделала `cd "$AWG_DIR"`, давал $AWG_DIR и ломал
# детекцию. Фиксируем здесь, пока cwd ещё равна пользовательской папке.
INSTALLER_DIR=""
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)" || INSTALLER_DIR=""
fi

# SHA256 checksums скачиваемых скриптов. Обновляются при каждом релизе.
# Проверяются в step5_download_scripts() после curl.
# При override AWG_REPOSITORY/AWG_BRANCH проверка пропускается: локальные pins
# относятся только к опубликованной ветке форка feat/v3.
# Формат: sha256sum output (hex, 64 chars).
COMMON_SCRIPT_SHA256="6279100d3c44895854ea7e3f526ec247e84a2bbf9502c1a03ff71449b7f3e086"
MANAGE_SCRIPT_SHA256="7a3e8af94ef48549ef5aaa10c479fea58eccf7cc0eb77aeeace851be48af770e"

# AmneziaWG 2.0 пин (H0, 31 jul 2026). Upstream влил AmneziaWG 3.0 в default-ветку
# amneziawg-linux-kernel-module, и PPA переключился на 3.0. Тогда на ядрах старее
# 6.7 (Debian 12 = 6.1) DKMS-сборка из PPA падала на nla_put_uint. 31 jul вечером
# upstream это исправил (v3.0.20260731-04; проверено нами на Debian 12 / 6.1.0-51
# 1 aug), поэтому пин из ВЫНУЖДЕННОГО стал СОЗНАТЕЛЬНЫМ: на старых ядрах держим
# проверенный 2.0-модуль, пока 3.0 не валидирован отдельно. AWG2_PIN_COMMIT
# сверяется после clone (integrity: надёжнее хрупкого tarball-SHA - тег
# теоретически можно переместить, immutable-коммит нельзя).
AWG2_PIN_TAG="v1.0.20260725"
AWG2_PIN_COMMIT="ae0924ca700520ca34c5bdbcfd05b2f683ea9353"

# Флаги CLI
UNINSTALL=0; HELP=0; HELP_EXIT_RC=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; AUTO_YES=0; NO_TWEAKS=0; NO_CPS=0; KEEP_PACKAGES=""
FORCE_REINSTALL=0
_APT_UPDATED=0
CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"; CLI_SSH_PORT=""; CLI_I1_MODE=""
CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES=""; CLI_ENDPOINT=""; CLI_NO_TWEAKS=0; CLI_NO_CPS=0; CLI_KEEP_PACKAGES=0
# Multi-hop / каскад: роль ноды и параметры upstream-туннеля (для role=entry)
CLI_ROLE=""; CLI_UPSTREAM_CONF=""; CLI_UPSTREAM_IFACE=""
CLI_UPSTREAM_TABLE=""; CLI_UPSTREAM_FWMARK=""
# WARP egress: заворот клиентского трафика в Cloudflare WARP (для role=exit|single)
CLI_EGRESS=""; CLI_WARP_IFACE=""; CLI_WARP_TABLE=""; CLI_WARP_PRIORITY=""; CLI_WARP_BYPASS=""
# AmneziaDNS: локальный dnsmasq на tunnel-gateway + «родной» Amnezia vpn://-URI
CLI_AMNEZIA_DNS=""
# Опциональный dual-stack IPv6 внутри туннеля (upstream v5.15.0)
CLI_ALLOW_IPV6_TUNNEL="default"
CLI_ISOLATION="default"
CLI_SERVER_NAME=""
CLI_MOBILE=0

# --- Автоочистка временных файлов ---
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
        printf '[ERROR] Некорректный upstream rollback target: %s\n' "$target" >&2
        return 1
    }
    iface="${BASH_REMATCH[1]}"
    [[ "$iface" != "awg0" ]] || {
        printf '[ERROR] Отказ использовать awg0 как upstream rollback target.\n' >&2
        return 1
    }
    unit="awg-quick@${iface}"
    command -v ip >/dev/null 2>&1 || {
        printf '[ERROR] ip недоступен; состояние live upstream нельзя проверить, config НЕ перезаписан.\n' >&2
        return 1
    }
    state=$(systemctl is-active "$unit" 2>/dev/null || true)
    command -v ip >/dev/null 2>&1 && ip link show dev "$iface" >/dev/null 2>&1 \
        && iface_present=1
    if [[ "$state" =~ ^(active|activating|deactivating|reloading)$ || "$iface_present" -eq 1 ]]; then
        if [[ "$state" =~ ^(active|activating|deactivating|reloading)$ ]]; then
            systemctl stop "$unit" >/dev/null 2>&1 || {
                printf '[ERROR] Не удалось остановить новый upstream %s; его live config НЕ перезаписан. Backup: %s\n' \
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
            printf '[ERROR] Не удалось снять новый upstream %s; его live config НЕ перезаписан. Backup: %s\n' \
                "$iface" "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" >&2
            return 1
        fi
        if command -v ip >/dev/null 2>&1 && ip link show dev "$iface" >/dev/null 2>&1; then
            printf '[ERROR] Новый upstream %s остался live; его config НЕ перезаписан.\n' "$iface" >&2
            return 1
        fi
    elif [[ "$state" != "inactive" && "$state" != "failed" && "$state" != "unknown" ]]; then
        printf '[ERROR] Не удалось определить состояние upstream %s; live config НЕ перезаписан.\n' "$iface" >&2
        return 1
    fi

    if [[ "$_INSTALL_ROLLBACK_UPSTREAM_EXISTED" -eq 1 ]]; then
        [[ -f "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" && ! -L "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" ]] \
            || { printf '[ERROR] Upstream rollback backup отсутствует: %s\n' "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" >&2; return 1; }
        tmp=$(mktemp -p "$(dirname "$target")" '.upstream.rollback.XXXXXX' 2>/dev/null) || tmp=""
        [[ -n "$tmp" ]] && cp -- "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" "$tmp" \
            && chmod 600 "$tmp" && mv -f -- "$tmp" "$target" || {
                rm -f -- "$tmp" 2>/dev/null || true
                printf '[ERROR] Не удалось атомарно восстановить upstream config из %s\n' \
                    "$_INSTALL_ROLLBACK_UPSTREAM_BACKUP" >&2
                return 1
            }
    else
        rm -f -- "$target" || { printf '[ERROR] Не удалось удалить новый upstream config %s\n' "$target" >&2; return 1; }
    fi

    if [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_ENABLED" -eq 1 ]]; then
        systemctl enable "$unit" >/dev/null 2>&1 || return 1
    else
        systemctl disable "$unit" >/dev/null 2>&1 || return 1
    fi
    if [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start "$unit" >/dev/null 2>&1 || {
            printf '[ERROR] Старый upstream %s восстановлен, но не запустился.\n' "$iface" >&2
            return 1
        }
    elif [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_LINK" -eq 1 ]]; then
        timeout 15 awg-quick up "$target" >/dev/null 2>&1 || {
            printf '[ERROR] Прежний вручную поднятый upstream %s восстановлен на диске, но не поднялся.\n' "$iface" >&2
            return 1
        }
    fi
    _INSTALL_ROLLBACK_UPSTREAM=0
    return 0
}

# При смене роли старый installer-owned upstream нужно остановить до запуска
# нового awg0: иначе его policy route продолжит влиять на новый режим. Здесь
# восстанавливается только точное runtime/autostart-состояние; config и marker
# до post-commit cleanup вообще не удаляются.
_install_restore_stopped_old_support() {
    [[ "$_INSTALL_ROLLBACK_OLD_SUPPORT" -eq 1 ]] || return 0
    local iface="$_INSTALL_ROLLBACK_OLD_SUPPORT_IFACE"
    local unit="awg-quick@${iface}" conf="/etc/amnezia/amneziawg/${iface}.conf"
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$iface" != "awg0" ]] || {
        printf '[ERROR] Некорректный iface прежнего upstream при rollback: %s\n' "$iface" >&2
        return 1
    }
    if [[ "$_INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ENABLED" -eq 1 ]]; then
        systemctl enable "$unit" >/dev/null 2>&1 || return 1
    else
        systemctl disable "$unit" >/dev/null 2>&1 || return 1
    fi
    if [[ "$_INSTALL_ROLLBACK_OLD_SUPPORT_WAS_ACTIVE" -eq 1 ]]; then
        systemctl start "$unit" >/dev/null 2>&1 || {
            printf '[ERROR] Не удалось снова запустить прежний upstream %s.\n' "$iface" >&2
            return 1
        }
    elif [[ "$_INSTALL_ROLLBACK_OLD_SUPPORT_WAS_LINK" -eq 1 ]]; then
        [[ -f "$conf" && ! -L "$conf" ]] \
            && timeout 15 awg-quick up "$conf" >/dev/null 2>&1 || {
                printf '[ERROR] Не удалось восстановить вручную поднятый прежний upstream %s.\n' "$iface" >&2
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

# При смене имени WARP-интерфейса old ownership временно переносится в
# отдельные marker'ы: это освобождает штатные имена для нового iface, но не
# теряет право собственности на старые ресурсы. EXIT rollback возвращает
# marker'ы только когда новые ещё не заняли штатные имена.
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
            printf '[ERROR] Небезопасный parked WARP ownership marker сохранён: %s\n' "$parked" >&2
            failed=1
            continue
        fi
        IFS= read -r parked_value < "$parked" || parked_value=""
        if [[ ! -e "$live" && ! -L "$live" ]]; then
            mv -f -- "$parked" "$live" 2>/dev/null \
                || { printf '[ERROR] Не удалось вернуть WARP ownership marker %s\n' "$live" >&2; failed=1; }
        elif [[ -f "$live" && ! -L "$live" ]]; then
            IFS= read -r live_value < "$live" || live_value=""
            if [[ "$live_value" == "$parked_value" ]]; then
                rm -f -- "$parked" 2>/dev/null || failed=1
            else
                printf '[WARN] Новый WARP ownership уже занимает %s; старый сохранён в %s\n' \
                    "$live" "$parked" >&2
                failed=1
            fi
        else
            printf '[WARN] Нельзя безопасно вернуть WARP ownership в %s; старый marker сохранён в %s\n' \
                "$live" "$parked" >&2
            failed=1
        fi
    done
    [[ "$failed" -eq 0 ]] && _INSTALL_ROLLBACK_WARP_PARKED=0
    return "$failed"
}

_install_cleanup() {
    # Идемпотентно: на INT/TERM зовётся из сигнального обработчика, затем ещё раз
    # на EXIT - второй вызов должен быть no-op.
    [[ "$_install_cleaned" -eq 1 || "$_install_cleaned" -eq 2 ]] && return 0
    _install_cleaned=1
    local rollback_attempted=0 rollback_can_restore=1 rollback_config_restored=0
    local rollback_state="" rollback_iface_present=0 rollback_tmp="" rollback_state_tmp=""

    # Транзакция взводится для любого целевого awg0.conf: и для
    # старого inactive config, и для первой установки. Если новый
    # awg0 успел подняться, сначала обязательно выполняем его
    # НОВЫЙ PostDown. При любой неуверенности live config не переписываем.
    if [[ "$_INSTALL_ROLLBACK_AWG0" -eq 1 ]]; then
        rollback_attempted=1
        if ! command -v ip >/dev/null 2>&1; then
            rollback_can_restore=0
            printf '[ERROR] ip недоступен; live awg0 нельзя проверить, config НЕ перезаписан.\n' >&2
        fi
        rollback_state=$(systemctl is-active awg-quick@awg0 2>/dev/null || true)
        command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1 \
            && rollback_iface_present=1
        if [[ "$rollback_can_restore" -eq 1 \
              && "$rollback_state" =~ ^(active|activating|deactivating|reloading)$ ]]; then
            if ! systemctl stop awg-quick@awg0 >/dev/null 2>&1; then
                rollback_can_restore=0
                printf '[ERROR] Не удалось остановить новый awg0; live config НЕ перезаписан. Backup: %s\n' \
                    "${_INSTALL_ROLLBACK_SERVER_BACKUP:-нет (первая установка)}" >&2
            fi
        elif [[ "$rollback_can_restore" -eq 1 \
                && "$rollback_state" != "inactive" && "$rollback_state" != "failed" \
                && "$rollback_state" != "unknown" ]]; then
            rollback_can_restore=0
            printf '[ERROR] Не удалось надёжно определить состояние awg0 (%s); live config НЕ перезаписан. Backup: %s\n' \
                "${rollback_state:-нет ответа}" "${_INSTALL_ROLLBACK_SERVER_BACKUP:-нет}" >&2
        fi

        # failed/inactive systemd unit может всё ещё иметь live link. Обычный
        # systemctl stop его не снимет, поэтому down идёт по ещё НОВОМУ
        # файлу, до его восстановления/удаления.
        rollback_iface_present=0
        command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1 \
            && rollback_iface_present=1
        if [[ "$rollback_can_restore" -eq 1 && "$rollback_iface_present" -eq 1 ]]; then
            if [[ ! -f "$SERVER_CONF_FILE" || -L "$SERVER_CONF_FILE" ]] \
                || ! timeout 15 awg-quick down "$SERVER_CONF_FILE" >/dev/null 2>&1; then
                rollback_can_restore=0
                printf '[ERROR] Live awg0 не снят новым config; config НЕ перезаписан.\n' >&2
            fi
        fi
        if [[ "$rollback_can_restore" -eq 1 ]] \
            && command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1; then
            rollback_can_restore=0
            printf '[ERROR] awg0 всё ещё live после stop/down; config НЕ перезаписан.\n' >&2
        fi

        if [[ "$rollback_can_restore" -eq 1 && "$_INSTALL_ROLLBACK_SERVER_EXISTED" -eq 1 ]]; then
            if [[ ! -f "$_INSTALL_ROLLBACK_SERVER_BACKUP" || -L "$_INSTALL_ROLLBACK_SERVER_BACKUP" ]]; then
                rollback_can_restore=0
                printf '[ERROR] Backup прежнего awg0.conf отсутствует; live config НЕ перезаписан.\n' >&2
            else
                rollback_tmp=$(mktemp -p "$(dirname "$SERVER_CONF_FILE")" '.awg0.rollback.XXXXXX' 2>/dev/null) || rollback_tmp=""
                if [[ -n "$rollback_tmp" ]] \
                    && cp -- "$_INSTALL_ROLLBACK_SERVER_BACKUP" "$rollback_tmp" \
                    && chmod 600 "$rollback_tmp" && mv -f -- "$rollback_tmp" "$SERVER_CONF_FILE"; then
                    rollback_config_restored=1
                else
                    rm -f -- "$rollback_tmp" 2>/dev/null || true
                    printf '[ERROR] Не удалось атомарно восстановить прежний awg0.conf из %s\n' \
                        "$_INSTALL_ROLLBACK_SERVER_BACKUP" >&2
                fi
            fi
        elif [[ "$rollback_can_restore" -eq 1 ]]; then
            if [[ -L "$SERVER_CONF_FILE" ]]; then
                printf '[ERROR] Отказ удалять неожиданный symlink вместо нового awg0.conf.\n' >&2
            elif rm -f -- "$SERVER_CONF_FILE"; then
                rollback_config_restored=1
            else
                printf '[ERROR] Не удалось удалить awg0.conf незавершённой первой установки.\n' >&2
            fi
        fi

        if [[ "$rollback_config_restored" -eq 1 ]]; then
            # Bypass owns concrete routes in the policy table. Restore its
            # bundle/routes while the new awg0 is already down, but before
            # rolling the WARP support interface back.
            if declare -F rollback_warp_bypass_state >/dev/null 2>&1; then
                rollback_warp_bypass_state || rollback_can_restore=0
            elif [[ "${_AWG_BYPASS_TX_ACTIVE:-0}" -eq 1 ]]; then
                printf '[ERROR] Функция rollback WARP bypass недоступна; transaction оставлена pending.\n' >&2
                rollback_can_restore=0
            fi
            _install_restore_awg0_dependency || rollback_can_restore=0
            _install_restore_upstream_config || rollback_can_restore=0
            if declare -F rollback_warp_egress_state >/dev/null 2>&1; then
                rollback_warp_egress_state || rollback_can_restore=0
            elif [[ "${_AWG_WARP_TX_ACTIVE:-0}" -eq 1 ]]; then
                printf '[ERROR] Функция rollback WARP egress недоступна; transaction оставлена pending.\n' >&2
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
                    printf '[ERROR] Не удалось автоматически восстановить прежний awg0. Backup: %s\n' \
                        "$_INSTALL_ROLLBACK_SERVER_BACKUP" >&2
                    rollback_can_restore=0
                }
            elif [[ "$rollback_can_restore" -eq 1 && "$_INSTALL_ROLLBACK_AWG0_WAS_LINK" -eq 1 ]]; then
                [[ -f "$SERVER_CONF_FILE" && ! -L "$SERVER_CONF_FILE" ]] \
                    && timeout 15 awg-quick up "$SERVER_CONF_FILE" >/dev/null 2>&1 || {
                        printf '[ERROR] Не удалось восстановить вручную поднятый прежний awg0.\n' >&2
                        rollback_can_restore=0
                    }
            fi
            # Старый DNS resolver/service возвращаем только после старого
            # tunnel-gateway. Для первой установки это удаляет DNS новой
            # попытки уже после полного снятия нового awg0.
            if [[ "$rollback_can_restore" -eq 1 ]] \
               && declare -F rollback_amnezia_dns_state >/dev/null 2>&1; then
                rollback_amnezia_dns_state || {
                    printf '[ERROR] Не удалось полностью восстановить прежний AmneziaDNS.\n' >&2
                    rollback_can_restore=0
                }
            elif [[ "$rollback_can_restore" -eq 1 \
                    && ( "${_AWG_DNS_TX_ACTIVE:-0}" -eq 1 \
                         || "${_AWG_DNS_TX_EXTERNAL:-0}" -eq 1 ) ]]; then
                printf '[ERROR] Функция rollback AmneziaDNS недоступна; transaction оставлена pending.\n' >&2
                rollback_can_restore=0
            fi
            if [[ "$rollback_can_restore" -eq 1 ]]; then
                rollback_state_tmp=$(mktemp -p "$(dirname "$STATE_FILE")" '.setup-state.rollback.XXXXXX' 2>/dev/null) || rollback_state_tmp=""
                [[ -n "$rollback_state_tmp" ]] && printf '6\n' > "$rollback_state_tmp" \
                    && mv -f -- "$rollback_state_tmp" "$STATE_FILE" || {
                        rm -f -- "$rollback_state_tmp" 2>/dev/null || true
                        printf '[ERROR] Сеть восстановлена, но setup_state не удалось вернуть на шаг 6.\n' >&2
                        rollback_can_restore=0
                    }
            fi
            [[ "$rollback_can_restore" -eq 1 ]] && _INSTALL_ROLLBACK_AWG0=0
        fi
    fi

    # Самостоятельный upstream rollback нужен для ошибки в узком
    # окне до взведения server-транзакции. При active server
    # он выполняется только после безопасного stop/restore awg0.
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
        # snapshot intent without mutations is always safe to disarm.
        rollback_amnezia_dns_state || true
    fi
    if [[ "$_INSTALL_ROLLBACK_WARP_PARKED" -eq 1 ]]; then
        _install_restore_parked_warp_ownership || true
    fi
    # При незавершённом rollback не удаляем snapshots/backups: signal-handler
    # даст EXIT повторить попытку, а обычный fatal exit оставит доказательства
    # для следующего запуска/ручного восстановления.
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
        printf '[WARN] Rollback завершён не полностью; snapshots сохранены для повторной попытки.\n' >&2
        return 0
    fi
    local f
    for f in "${_install_temp_files[@]}"; do [[ -f "$f" ]] && rm -f "$f"; done
    local d
    for d in "${_install_temp_dirs[@]}"; do [[ -d "$d" ]] && rmdir "$d" 2>/dev/null || true; done
    # Очистка временных файлов из awg_common.sh (если уже подключён через source)
    type _awg_cleanup &>/dev/null && _awg_cleanup
    _install_cleaned=2
}
# На INT/TERM раньше cleanup срабатывал, но скрипт НЕ завершался - выполнение
# продолжалось после прерванной команды (опасно посреди apt/dpkg/правки конфигов),
# и cleanup ещё раз шёл на EXIT. Теперь сигнал = cleanup + явный выход 130/143.
_install_on_signal() {
    _install_cleanup
    exit "$1"
}
trap _install_cleanup EXIT
trap '_install_on_signal 130' INT
trap '_install_on_signal 143' TERM

# --- Обработка аргументов ---
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
        *) echo "Неизвестный аргумент: $1" >&2; HELP=1; HELP_EXIT_RC=1 ;;
    esac
    shift
done

# ==============================================================================
# Функции логирования
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
        echo "[$ts] ERROR: Ошибка записи лога $LOG_FILE" >&2
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
die()       { log_error "КРИТИЧЕСКАЯ ОШИБКА: $1"; log_error "Установка прервана. Лог: $LOG_FILE"; exit 1; }

# ==============================================================================
# apt-get update wrapper, игнорирующий 404 только на source packages (deb-src).
# INLINE: нужна в шагах 1-2 до скачивания awg_common.sh (Step 5).
# Некоторые зеркала (Hetzner, AWS) не раздают source, но дефолтный ubuntu.sources
# содержит 'Types: deb deb-src'. Source не нужен (DKMS + бинарные headers).
# Возвращает 0 если update прошёл ИЛИ если все ошибки — только на source-маркерах.
# Любая другая ошибка (GPG, сетевая на binary, silent crash/OOM/SIGKILL) → non-zero.
# ==============================================================================
apt_update_tolerant() {
    # --ppa-amnezia-tolerant: дополнительно игнорируем ошибки от PPA Amnezia.
    # Используется на step 2 — там apt_wait_for_ppa_package сам делает retry
    # для outage'а ppa.launchpadcontent.net (issue #68). Без этого флага мы
    # должны fall-fail на любых non-source ошибках, иначе скрипт продолжит
    # установку на stale apt-cache (PR #69 review finding).
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

    # Фильтруем строки ошибок. Игнорируем:
    #   1. Строки про source-пакеты (deb-src / /source/ / Sources)
    #   2. Generic 'Some index files failed to download' — симптом, не причина
    # Дополнительно исключаем заведомо информационные W:-строки, которые не
    # бывают ПРИЧИНОЙ rc!=0, но переживали фильтры и превращали tolerable-сбой
    # (например deb-src 404 при задвоенных sources) в ложный fatal:
    #   - "Target ... is configured multiple times" (дубль sources-записей)
    #   - "... stored in legacy trusted.gpg keyring" (старый формат ключей)
    non_src_errors=$(printf '%s\n' "$err_output" \
        | grep -E '^(E:|Err:|W:)' \
        | grep -vE '(deb-src|/source/|Sources([^[:alpha:]]|$))' \
        | grep -vE 'Some index files failed to download' \
        | grep -vE '^W: (Target .* is configured multiple times|.* stored in legacy trusted\.gpg)' || true)

    # Запоминаем pre-PPA filter состояние: нужно различать «были реальные APT-ошибки,
    # но все на PPA Amnezia» (tolerant OK) от «классифицируемых ошибок не было
    # вообще» (OOM / silent crash — НЕ tolerant даже если в выводе мелькает PPA URL).
    [[ -n "$non_src_errors" ]] && raw_had_non_src_errors=1

    # Опционально (step 2): убираем ошибки только на PPA Amnezia — они будут
    # повторно проверены через apt_wait_for_ppa_package по apt-cache (issue #68).
    if [[ $ppa_tolerant -eq 1 && -n "$non_src_errors" ]]; then
        non_src_errors=$(printf '%s\n' "$non_src_errors" \
            | grep -vE 'ppa\.launchpadcontent\.net.*amnezia' || true)
    fi

    if [[ -z "$non_src_errors" ]]; then
        # Граничный случай: rc != 0, но ни одной классифицируемой строки E:/Err:/W:
        # не найдено (SIGKILL от OOM, silent crash, неизвестный формат вывода apt).
        # Игнорировать можно ТОЛЬКО если в выводе есть явные source-маркеры,
        # либо ppa-tolerant + были реальные APT-строки и все они — на PPA Amnezia.
        if printf '%s\n' "$err_output" | grep -qE '(deb-src|/source/|Sources([^[:alpha:]]|$))'; then
            log_warn "apt update: source packages недоступны в зеркале (ожидаемо, игнорируется)"
            return 0
        fi
        if [[ $ppa_tolerant -eq 1 && $raw_had_non_src_errors -eq 1 ]] \
            && printf '%s\n' "$err_output" | grep -qE 'ppa\.launchpadcontent\.net.*amnezia'; then
            log_warn "apt update: ошибки только на PPA Amnezia (issue #68), продолжаем с retry."
            return 0
        fi
        log_error "apt update завершился с rc=$rc без классифицируемых APT-строк — возможен silent crash / OOM / SIGKILL"
        return "$rc"
    fi

    log_error "apt update завершился с non-source ошибками:"
    printf '%s\n' "$non_src_errors" | while IFS= read -r line; do
        log_error "  $line"
    done
    return "$rc"
}

# ==============================================================================
# apt_wait_for_ppa_package <package> [max_attempts] [initial_delay_seconds]
#   Ждёт, пока пакет станет видимым в apt-cache, с экспоненциальным
#   backoff между попытками. Нужно на шаге 2 после добавления PPA
#   Amnezia: ppa.launchpadcontent.net иногда коротко лежит (issue #68),
#   и без ретрая первая холодная установка валится, хотя через минуту
#   PPA уже доступен.
#
#   ВАЖНО: проверяется именно apt-cache show, а не rc от apt-get update.
#   apt-get update toлerantно возвращает 0 даже когда какой-то InRelease
#   не скачался — поэтому простого retry на rc недостаточно для outage
#   PPA. Видимость пакета в apt-cache — единственный надёжный сигнал,
#   что PPA реально проиндексировался.
#
#   С дефолтами (3 попытки × initial=30с) сценарий такой: попытка 1 →
#   sleep 30с → apt update + попытка 2 → sleep 60с → apt update +
#   попытка 3 (последняя). После третьего fail возвращаем 1.
#   Итого ожидание между попытками ≈1.5 минуты.
#
#   Cap на delay (1800с) защищает от арифметического переполнения, если
#   кто-то вызовет helper с очень большим max.
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
        log_warn "Пакет '${pkg}' не появился в apt-cache (попытка ${attempt}/${max}, PPA пока недоступен), повтор через ${delay}с..."
        sleep "$delay"
        apt_update_tolerant >/dev/null 2>&1 || true
        delay=$(( delay * 2 > 1800 ? 1800 : delay * 2 ))
    done
    return 1
}

# ==============================================================================
# Справка
# ==============================================================================

show_help() {
    cat << 'EOF'
Использование: sudo bash install_amneziawg.sh [ОПЦИИ]
Скрипт для установки и настройки AmneziaWG 2.0 на Ubuntu (24.04 / 25.10 / 26.04) и Debian (12 / 13).

Опции:
  -h, --help            Показать эту справку и выйти
  --uninstall           Удалить AmneziaWG и все его конфигурации
  --diagnostic          Создать диагностический отчет и выйти
  -v, --verbose         Расширенный вывод для отладки (включая DEBUG)
  --no-color            Отключить цветной вывод в терминале
  --port=НОМЕР          Установить UDP порт (1-65535) неинтерактивно.
                        Полезно для обхода DPI: 500 (IKE/NAT-T), 443, 53.
  --ssh-port=ПОРТ       SSH-порт для правила UFW (по умолчанию определяется
                        автоматически; список через запятую). Используйте, если
                        SSH на нестандартном порту и автодетект недоступен
  --subnet=ПОДСЕТЬ      Подсеть туннеля, CIDR /16-/30 (напр. 10.9.0.0/16) неинтерактивно
  --allow-ipv6          Оставить IPv6 включенным неинтерактивно
  --disallow-ipv6       Принудительно отключить IPv6 неинтерактивно
  --allow-ipv6-tunnel   Включить dual-stack IPv6 внутри туннеля (ULA, opt-in)
                        Не поддерживается вместе с --role=entry или --egress=warp
  --disallow-ipv6-tunnel Отключить ранее включённый IPv6 внутри туннеля
  --route-all           Использовать режим 'Весь трафик' неинтерактивно
  --route-amnezia       Использовать режим 'Amnezia' неинтерактивно
  --route-custom=СЕТИ   Использовать режим 'Пользовательский' неинтерактивно
  --isolation=on|off    Изоляция клиентов VPN друг от друга (по умолчанию on).
                        off: подсеть туннеля добавляется в AllowedIPs клиентов
  --endpoint=АДРЕС      Внешний endpoint сервера: FQDN, IPv4 или [IPv6] (для NAT)
  --server-name=ИМЯ     Имя сервера в приложении Amnezia при импорте vpn://
                        (по умолчанию 'AWG Server'; без кавычек и управляющих символов)
  --mobile              Мобильный сетап одним флагом: --preset=mobile + порт 443/udp
                        (мобильные операторы часто глушат нестандартные UDP-порты).
                        Явный --port=N выигрывает над портом 443
  -y, --yes             Автоматическое подтверждение (перезагрузки, UFW и т.д.)
  -f, --force           Принудительная переустановка поверх уже работающего AmneziaWG
                        (по умолчанию запуск на сконфигурированном сервере прерывается;
                        ENV: AWG_FORCE_REINSTALL=1 эквивалентен флагу)
  --no-tweaks           Пропустить очистку системы, оптимизацию и hardening (UFW,
                        Fail2Ban); минимальный forwarding-sysctl применяется всегда
  --keep-packages       Не удалять системные пакеты (snapd и др.), но оставить
                        фаервол, Fail2Ban и оптимизацию. Снос snapd уносит
                        установленные снапы и их данные в /var/snap
  --preset=ТИП          Набор параметров обфускации: default, mobile
                        mobile: Jc=3, узкий Jmax — для мобильных операторов (Tele2, Yota, Megafon)
  --jc=N               Задать Jc вручную (1-128, поверх preset)
  --jmin=N             Задать Jmin вручную (0-1280, поверх preset)
  --jmax=N             Задать Jmax вручную (0-1280, поверх preset, должно быть >= Jmin)
  --i1-mode=РЕЖИМ       random (умолч.) | quic
                        random: <r N> случайных байт (32-256) — неинформативный шум.
                        quic:   <b 0x...> ≈1100-1250 байт, сформированных как
                                валидный QUIC v1 Initial-пакет (RFC 9000 §17.2.2).
                                Маскирует AWG-handshake под обычный QUIC-трафик
                                браузера. Самый сильный режим против DPI мобильных
                                операторов. Парно с --preset=mobile --port=500.
  --no-cps              Отключить CPS (параметр I1) - нужно, если десктопный
                        AmneziaVPN на macOS виснет при подключении (issue #159)

Multi-hop (каскад из двух AWG-серверов):
  --role=РОЛЬ           single (умолч.) | exit | entry
                        exit:  обычный сервер, к которому цепляется entry
                        entry: дополнительно поднимает upstream-туннель к exit
  --upstream-conf=ФАЙЛ  (для role=entry) путь к .conf от manage add на exit-ноде
  --upstream-iface=ИМЯ  имя upstream-интерфейса (умолч. awg1)
  --upstream-table=N    routing table для клиентского трафика (умолч. 123)
  --upstream-fwmark=HEX fwmark для upstream-пакетов (умолч. 0xca6d)

WARP egress (для role=exit или single — НЕ совместимо с role=entry):
  --egress=РЕЖИМ        direct (умолч.) | warp
                        warp: ставит wgcf (Cloudflare WARP WireGuard), поднимает
                        wg-quick@wgcf с Table=off и заворачивает клиентский
                        трафик AWG в WARP через policy routing. Внешние сайты
                        видят IP Cloudflare, не IP VPS.
  --warp-iface=ИМЯ      Имя WARP-интерфейса (умолч. wgcf)
  --warp-table=N        routing table для WARP-трафика (умолч. 2408)
  --warp-priority=N     приоритет ip rule для WARP, 1..32764 (умолч. 789)
  --warp-bypass=SPEC    Исключения из WARP (уходят через основной NIC напрямую).
                        Полезно против CDN, которые режут или блокируют
                        WARP-диапазоны (классика — YouTube / googlevideo).
                        SPEC = none (умолч.) | youtube | custom:<URL|/path>,
                        через запятую. `youtube` — CIDR-список из
                        touhidurrr/iplist-youtube (cidr4.txt). Формат custom-
                        списка автоопределяется: CIDR (1.2.3.4[/N]) или домен
                        (резолвится через @1.1.1.1), поддерживаются комментарии
                        # и dnsmasq-стиль full:/@tag. Пример:
                        --warp-bypass=youtube,custom:https://example.com/list.txt
                        Работает только с --egress=warp. Автообновление раз
                        в 6 часов через systemd timer.

AmneziaDNS (для встроенного site-based split tunneling в Amnezia VPN клиенте):
  --amnezia-dns=РЕЖИМ   off (умолч.) | on
                        on: ставит dnsmasq на tunnel-gateway IP (напр. 10.8.0.1),
                        генерит клиентский vpn:// URI как «полноценный
                        Amnezia-сервер» (isThirdPartyConfig:false + контейнер
                        amnezia-dns). В UI Amnezia VPN открывается сайт-список
                        split tunneling — сайты «в обход VPN» резолвятся
                        локально на устройстве и уходят напрямую к ISP
                        (сайт видит реальный IP пользователя, не IP VPS).
                        Доступно на --role=single и --role=entry (не exit).

Примеры:
  sudo bash install_amneziawg.sh                             # Интерактивная установка
  sudo bash install_amneziawg.sh --port=51820 --route-all    # Неинтерактивная
  sudo bash install_amneziawg.sh --route-amnezia --yes       # Полностью автоматическая
  sudo bash install_amneziawg.sh --preset=mobile --yes       # Оптимизация для мобильных сетей
  sudo bash install_amneziawg.sh --preset=mobile --port=500 --i1-mode=quic --yes   # Макс обход DPI мобильных
  sudo bash install_amneziawg.sh --role=exit --yes           # Exit-нода каскада
  sudo bash install_amneziawg.sh --role=entry --upstream-conf=/root/from_exit.conf --yes
  sudo bash install_amneziawg.sh --egress=warp --yes         # Single-сервер с WARP egress
  sudo bash install_amneziawg.sh --role=exit --egress=warp --yes   # Exit-нода каскада с WARP
  sudo bash install_amneziawg.sh --role=exit --egress=warp --warp-bypass=youtube --yes   # Exit + WARP, YouTube напрямую
  sudo bash install_amneziawg.sh --amnezia-dns=on --yes      # Single-сервер + site-based split tunneling в клиенте
  sudo bash install_amneziawg.sh --role=entry --upstream-conf=/root/from_exit.conf --amnezia-dns=on --yes
  sudo bash install_amneziawg.sh --uninstall                 # Удаление
  sudo bash install_amneziawg.sh --diagnostic                # Диагностика

Форк: https://github.com/SNPR/amneziawg-installer (upstream: bivlked)
EOF
    # Явный --help завершается с 0; неизвестный аргумент - с 1 (ложный успех в CI).
    exit "${HELP_EXIT_RC:-0}"
}

# ==============================================================================
# Утилиты и валидация
# ==============================================================================

update_state() {
    local next_step=$1
    mkdir -p "$(dirname "$STATE_FILE")"
    # Атомарная запись: tmp-файл + flock + mv. Защита от битого
    # состояния при crash/power-loss между write и close.
    (
        flock -x 200
        local tmp="${STATE_FILE}.tmp.$BASHPID"
        if printf '%s\n' "$next_step" > "$tmp" && mv -f "$tmp" "$STATE_FILE"; then
            exit 0
        fi
        rm -f "$tmp" 2>/dev/null
        exit 1
    ) 200>"${STATE_FILE}.lock" || die "Ошибка записи состояния"
    log "Состояние: следующий шаг - $next_step"
}

request_reboot() {
    local next_step=$1
    update_state "$next_step"

    # Перед reboot-gate 1→2 сохраняем boot_id. На входе step 2
    # сравниваем с текущим — если совпадает, reboot не произошёл
    # и DKMS соберёт модуль под старое ядро (которое после следующего
    # reboot будет уже обновлённым на шаге 1 и не подхватит модуль).
    if [[ "$next_step" == "2" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        if cat /proc/sys/kernel/random/boot_id > "$AWG_DIR/.boot_id_before_step2" 2>/dev/null; then
            log_debug "boot_id captured before reboot"
        fi
    fi

    echo "" >> "$LOG_FILE"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log_warn "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ                        !!!"
    log_warn "!!! После перезагрузки, запустите скрипт снова командой:   !!!"
    log_warn "!!! sudo bash $0 [с теми же параметрами, если были]       !!!"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "" >> "$LOG_FILE"
    local confirm="y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Перезагрузить сейчас? [y/N]: " confirm < /dev/tty
    else
        log "Автоматическое подтверждение перезагрузки (--yes)."
    fi
    if [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
        log "Инициирована перезагрузка..."
        sleep 5
        if ! reboot; then die "Команда reboot не удалась."; fi
        exit 1
    else
        log "Перезагрузка отменена. Перезагрузитесь вручную и запустите скрипт снова."
        exit 1
    fi
}

# Ранний детект контейнера (LXC/OpenVZ/Docker/WSL) - кейс с 4pda: на
# контейнерном VDS установка доходила до шага 3 и падала сырым 'modprobe:
# FATAL: Module amneziawg not found' без объяснения причины. AmneziaWG ставит
# модуль ядра через DKMS, а контейнеры разделяют ядро с хостом и не дают
# загружать свои модули - честнее остановиться сразу и объяснить.
# systemd-detect-virt есть на всех поддерживаемых Ubuntu/Debian; если его
# вдруг нет - проверку пропускаем (мягкая деградация, установку не блокируем).
check_container() {
    command -v systemd-detect-virt &>/dev/null || return 0
    local virt
    virt=$(systemd-detect-virt --container 2>/dev/null) || true
    [[ -z "$virt" || "$virt" == "none" ]] && return 0
    log_error "Обнаружен контейнер: ${virt}."
    log_error "AmneziaWG требует загрузки модуля ядра (DKMS), а контейнеры (LXC/OpenVZ/Docker/WSL) разделяют ядро с хостом и не позволяют загружать свои модули."
    die "Возьмите полноценный VPS (KVM/QEMU) или bare-metal. Вариант для контейнеров - userspace amneziawg-go: ADVANCED.md, раздел 'LXC / Docker через amneziawg-go'."
}

check_os_version() {
    log "Проверка ОС..."

    # Определение через /etc/os-release (универсально для Ubuntu и Debian)
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
        log_warn "Не удалось определить ОС (/etc/os-release и lsb_release не найдены)."
        return 0
    fi
    export OS_ID OS_VERSION OS_CODENAME

    # Поддерживаемые ОС
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
        log "ОС: ${OS_ID^} $OS_VERSION ($OS_CODENAME) — поддерживается"
    else
        log_warn "Обнаружена $OS_ID $OS_VERSION ($OS_CODENAME). Скрипт протестирован на Ubuntu 24.04/25.10/26.04 и Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Продолжить? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Отмена."; fi
        else
            log "Продолжаем на $OS_ID $OS_VERSION (--yes)."
        fi
    fi
}

check_kernel_version() {
    # Модуль AmneziaWG 2.0 собирается через DKMS против ядра хоста. На ядрах
    # старше 5.15 (Ubuntu < 22.04, напр. 5.4 на 20.04) сборка обычно падает уже
    # на шаге 2 - невнятным package-failure. Предупреждаем ЯВНО и рано, до
    # обновлений и перезагрузок (issue #163). Не die: на части старых ядер модуль
    # всё же собирается (HWE и подобное), поэтому WARN + подтверждение.
    local kver kmaj kmin
    kver=$(uname -r)
    if [[ "$kver" =~ ^([0-9]+)\.([0-9]+) ]]; then
        kmaj=${BASH_REMATCH[1]}; kmin=${BASH_REMATCH[2]}
    else
        log_warn "Не удалось разобрать версию ядра ('$kver') - пропускаю проверку минимальной версии."
        return 0
    fi
    if (( kmaj < 5 || (kmaj == 5 && kmin < 15) )); then
        log_warn "Ядро $kver старее 5.15 - для модуля AmneziaWG 2.0 это обычно слишком старо."
        log_warn "DKMS-сборка модуля на таком ядре чаще всего падает. Рекомендуется переустановить VPS на Ubuntu 24.04 LTS или Debian 12 (либо новее). Матрица: Ubuntu 24.04/25.10/26.04, Debian 12/13."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Всё равно продолжить? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Отмена: ядро $kver слишком старое для модуля AmneziaWG 2.0."; fi
        else
            log "Продолжаем на ядре $kver (--yes)."
        fi
    else
        log "Ядро $kver (OK для модуля AmneziaWG 2.0)."
    fi
}

# shellcheck disable=SC2120  # в установщике зовётся без аргументов (берёт uname -r); bats передаёт версии
_kernel_supports_awg3() {
    # Возвращает 0, если версия ядра >= 6.7 - там модуль берём из PPA как есть.
    # Возвращает 1, если ядро старее 6.7 - там идём пиновым 2.0-путём.
    # ⚠️ Имя историческое, читать его буквально НЕЛЬЗЯ. Порог 6.7 появился 30-31 jul
    # 2026: 3.0-код звал nla_put_uint, которой до mainline v6.7 не было, и на 6.1
    # (Debian 12) сборка падала с 'implicit declaration of nla_put_uint'. 31 jul
    # upstream это починил (v3.0.20260731-04), и на 6.1 3.0-модуль СОБИРАЕТСЯ -
    # проверено на стенде 1 aug. Порог оставлен сознательно: линия 3.0 за сутки
    # успела сломать и починить сборку именно на старых ядрах, то есть там она
    # обкатана меньше всего, а пиновый 2.0 сверяется по immutable-коммиту. Снимать
    # порог после отдельной валидации 3.0, а не потому, что сборка снова проходит.
    # Arg $1: kernel release (default uname -r). Неразбираемую версию считаем
    # "НЕ поддерживает" -> пиновый 2.0 (он собирается на ЛЮБОМ нашем ядре, так что
    # консервативный выбор не ломает связь, лишь не даёт 3.0-фич, которых в H0 нет).
    # Чистая функция без внешних зависимостей (bats: извлекается sed-range + source).
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
    log "Проверка места..."
    local req=2048
    local avail
    avail=$(df -m / | awk 'NR==2 {print $4}')
    if [[ -z "$avail" ]]; then
        log_warn "Не удалось определить свободное место."
        return 0
    fi
    if [ "$avail" -lt "$req" ]; then
        log_warn "Доступно $avail МБ. Рекомендуется >= $req МБ."
        if [[ "$AUTO_YES" -eq 0 ]]; then
            read -rp "Продолжить? [y/N]: " confirm < /dev/tty
            if ! [[ "$confirm" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then die "Отмена."; fi
        else
            log "Продолжаем с $avail МБ (--yes)."
        fi
    else
        log "Свободно: $avail МБ (OK)"
    fi
}

check_port_availability() {
    local port=$1
    log "Проверка порта $port..."
    local proc
    proc=$(ss -lunp | grep ":${port} ")
    if [[ -n "$proc" ]]; then
        log_error "Порт ${port}/udp уже используется! Процесс: $proc"
        return 1
    else
        log "Порт $port/udp свободен."
        return 0
    fi
}

install_packages() {
    local packages=("$@")
    local to_install=()
    local pkg
    log "Проверка пакетов: ${packages[*]}..."
    for pkg in "${packages[@]}"; do
        if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            to_install+=("$pkg")
        fi
    done
    if [ ${#to_install[@]} -eq 0 ]; then
        log "Все пакеты уже установлены."
        return 0
    fi
    log "Установка: ${to_install[*]}..."
    if [[ "${_APT_UPDATED:-0}" -eq 0 ]]; then
        # C4: жёсткая ошибка apt_update_tolerant (GPG / сеть на binary-репо / OOM) -
        # это НЕ source-шум, а реальный сбой; продолжать на устаревшем кэше нельзя
        # (контракт стр.138, как у вызовов 1975/2108). die завершает установку, так
        # что _APT_UPDATED=1 проставляется только при успехе - иначе повторный
        # install_packages в этой сессии молча пропустил бы update.
        apt_update_tolerant || die "Ошибка apt update."
        _APT_UPDATED=1
    fi
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}"; then
        # v5.13.0: типичный сбой на 25.10/26.04 после in-place upgrade с 24.04 —
        # dpkg postinst пакета amneziawg-dkms запускает `dkms autoinstall`,
        # который итерируется по ВСЕМ ядрам в /lib/modules/. Старые 6.8.x
        # headers скомпилированы gcc-13, а в 25.10 по умолчанию только
        # gcc-15 → autoinstall фолится, dpkg не configure'ит зависящие
        # amneziawg-tools / amneziawg. Принудительно собираем модуль для
        # running ядра и завершаем dpkg --configure -a.
        if printf '%s\n' "${to_install[@]}" | grep -qx "amneziawg-dkms"; then
            log_warn "apt install не завершился — пробую DKMS-сборку только для текущего ядра $(uname -r)..."
            local _mver
            _mver="$(ls /var/lib/dkms/amneziawg/ 2>/dev/null | head -n1)"
            if [[ -n "$_mver" ]] \
               && dkms install -m amneziawg -v "$_mver" -k "$(uname -r)" --force \
               && DEBIAN_FRONTEND=noninteractive dpkg --configure -a; then
                log "DKMS-модуль собран для $(uname -r), dpkg сконфигурирован."
                log "Пакеты установлены."
                return 0
            fi
        fi
        die "Ошибка установки пакетов."
    fi
    log "Пакеты установлены."
}

cleanup_apt() {
    log "Очистка apt..."
    apt-get clean || log_warn "Ошибка apt-get clean"
    rm -rf /var/lib/apt/lists/* || log_warn "Ошибка rm /var/lib/apt/lists/*"
    log "Кэш apt очищен."
}

configure_ipv6() {
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then
        DISABLE_IPV6=$CLI_DISABLE_IPV6
        log "IPv6 из CLI: $DISABLE_IPV6"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        DISABLE_IPV6=1
        log "IPv6 отключен (--yes, по умолчанию)."
    else
        read -rp "Отключить IPv6 (рекомендуется)? [Y/n]: " dis_ipv6 < /dev/tty
        if [[ "$dis_ipv6" =~ ^[Nn]$ ]]; then
            DISABLE_IPV6=0
        else
            DISABLE_IPV6=1
        fi
    fi
    export DISABLE_IPV6
    log "Отключение IPv6: $(if [ "$DISABLE_IPV6" -eq 1 ]; then echo 'Да'; else echo 'Нет'; fi)"
}

# Определение наличия native IPv6 на VPS.
# Native IPv6 = глобально маршрутизируемый адрес (НЕ ULA fc00::/7, НЕ link-local
# fe80::) И наличие IPv6 default-маршрута. Любого из условий по отдельности мало:
#   - global-адрес без default route -> нет выхода в IPv6-интернет (клиент с ::/0
#     получит black-hole);
#   - ULA (fddd::/...) для `ip` имеет scope global, но в интернет не маршрутизируется.
# Эхо 1 только когда выполнены оба условия, иначе 0.
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

# Поддерживаем только ULA /64 в сжатой форме (...::/64), которую умеют
# детерминированно преобразовывать renderer и allocator клиентов. Первый
# 16-битный блок обязан попадать в fc00::/7; до `::` допустимо 1-4 блока.
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
                    log_warn "ALLOW_IPV6_TUNNEL='${ALLOW_IPV6_TUNNEL}' в $CONFIG_FILE не валиден (допустимо 0|1) — отключаю IPv6-туннель."
                    ALLOW_IPV6_TUNNEL=0
                    ;;
            esac
            ;;
        *) die "Внутренняя ошибка CLI_ALLOW_IPV6_TUNNEL='$CLI_ALLOW_IPV6_TUNNEL'." ;;
    esac
    : "${IPV6_SUBNET:=fddd:2c4:2c4:2c4::/64}"
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        validate_ipv6_tunnel_subnet "$IPV6_SUBNET" \
            || die "Некорректный IPV6_SUBNET='$IPV6_SUBNET'. Ожидается ULA /64 вида fddd:2c4:2c4:2c4::/64."
    elif ! validate_ipv6_tunnel_subnet "$IPV6_SUBNET"; then
        log_warn "Неиспользуемый IPV6_SUBNET='$IPV6_SUBNET' невалиден; нормализую при отключённом IPv6-туннеле."
        IPV6_SUBNET='fddd:2c4:2c4:2c4::/64'
    fi

    # Несовместимость проверяем ДО sysctl ниже: невалидная комбинация CLI не
    # должна успеть изменить IPv6-состояние хоста перед отказом.
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "${AWG_ROLE:-single}" == "entry" ]]; then
        die "--allow-ipv6-tunnel пока не поддерживается с --role=entry: upstream-каскад маршрутизирует только IPv4. Используйте --disallow-ipv6-tunnel."
    fi
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "${AWG_EGRESS:-direct}" == "warp" ]]; then
        die "--allow-ipv6-tunnel пока не поддерживается с --egress=warp: WARP policy routing настроен только для IPv4. Используйте --disallow-ipv6-tunnel."
    fi
    # IPv6-туннель требует включённого IPv6 на хосте. Снимаю --disallow-ipv6 И
    # активно включаю IPv6 в рантайме ДО detection/render: при upgrade с дефолтной
    # прошлой установки (IPv6 был выключен в рантайме) ядро скрывает все IPv6-адреса,
    # поэтому detect_native_ipv6 дал бы false-negative, а клиент отрендерился бы с
    # IPv6 Address при выключенном в ядре IPv6 (awg-quick restart может упасть).
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 ]]; then
        if [[ "$DISABLE_IPV6" -eq 1 ]]; then
            log_warn "--allow-ipv6-tunnel requires host IPv6 forwarding; overriding --disallow-ipv6 (DISABLE_IPV6=0)"
            DISABLE_IPV6=0
        fi
        sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
        sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
    fi
    # Native IPv6 определяю ПОСЛЕ runtime-включения (кэширую в init для client render Phase 4).
    SERVER_HAS_NATIVE_IPV6=$(detect_native_ipv6)
    if [[ "$ALLOW_IPV6_TUNNEL" -eq 1 && "$SERVER_HAS_NATIVE_IPV6" -eq 0 ]]; then
        log_warn "Native IPv6 не обнаружен на VPS - туннель IPv6 будет работать peer-to-peer без выхода в IPv6-интернет."
    fi
    export ALLOW_IPV6_TUNNEL IPV6_SUBNET SERVER_HAS_NATIVE_IPV6 DISABLE_IPV6
}

# Безопасная загрузка конфигурации (whitelist-парсер, без source/eval)
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

# Чтение одного ключа из конфига (для точечных запросов)
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
    # Нижняя граница 1, а не 1024: wg-quick запускается из systemd от root,
    # биндиться на привилегированные порты (500 IKE/NAT-T, 443, 53) ему ничто
    # не мешает — это наоборот полезный трюк для обхода DPI мобильных
    # операторов, которые обычно не режут "служебные" порты.
    # Регэксп ^[1-9][0-9]{0,4}$ (из upstream) запрещает ведущие нули ('0080'
    # иначе трактуется как octal в арифметике) и ограничивает длину: без лимита
    # 64-битная арифметика (( )) переполняется и 2^64+51820 проскакивал бы
    # range-check. Сравнение — на чистом decimal.
    if ! [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || (( port < 1 )) || (( port > 65535 )); then
        die "Некорректный порт: '$port'. Допустимый диапазон: 1-65535."
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

# Атомарный root-owned marker имени интерфейса для cleanup после reboot.
# Уже существующий marker сохраняем: он описывает более раннюю незавершённую
# миграцию и не должен быть затёрт новым запуском.
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
            log_warn "Снят stale upstream cleanup marker для текущего iface ${iface}; current support не будет удалён."
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
            log_warn "Снят stale WARP cleanup marker для текущего iface ${iface}; current egress не будет удалён."
        fi
    fi
    return 0
}

# Main NIC может быть VLAN-интерфейсом (например, eth0.100), тогда как имена
# управляемых tunnel iface намеренно строже. Поэтому UFW marker имеет отдельный
# валидатор, но сохраняет те же atomic/no-symlink свойства.
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

# Останавливает старый upstream, отмеченный initialize_setup для отложенной
# уборки, но не disable'ит и не удаляет его. Вызывается только после успешного
# down старого awg0; EXIT возвращает точные active/link/enabled состояния.
stop_pending_old_upstream_for_transition() {
    local marker="$AWG_DIR/.upstream_cleanup_pending" iface="" unit="" conf=""
    local state="" link_present=0
    [[ -e "$marker" || -L "$marker" ]] || return 0
    [[ -f "$marker" && ! -L "$marker" ]] \
        || { log_error "Небезопасный upstream cleanup marker: $marker"; return 1; }
    IFS= read -r iface < "$marker" || iface=""
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$iface" != "awg0" ]] \
        || { log_error "Некорректный прежний upstream iface в cleanup marker."; return 1; }
    if [[ "${AWG_ROLE:-single}" == "entry" && "${AWG_UPSTREAM_IFACE:-awg1}" == "$iface" ]]; then
        log_error "Cleanup marker указывает на текущий обязательный upstream ${iface}; stop отменён."
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
        log "Временная остановка прежнего upstream ${iface} до commit нового awg0..."
        systemctl stop "$unit" \
            || { log_error "Не удалось остановить прежний upstream ${iface}."; return 1; }
    elif [[ "$state" != "inactive" && "$state" != "failed" && "$state" != "unknown" ]]; then
        log_error "Не удалось надёжно определить состояние прежнего upstream ${iface}: ${state:-нет ответа}"
        return 1
    fi

    if command -v ip >/dev/null 2>&1 && ip link show dev "$iface" >/dev/null 2>&1; then
        [[ -f "$conf" && ! -L "$conf" ]] \
            && timeout 15 awg-quick down "$conf" >/dev/null 2>&1 || {
                log_error "Прежний upstream ${iface} остался live; новый awg0 не будет запущен."
                return 1
            }
    fi
    if command -v ip >/dev/null 2>&1 && ip link show dev "$iface" >/dev/null 2>&1; then
        log_error "Интерфейс прежнего upstream ${iface} не исчез после stop."
        return 1
    fi
    return 0
}

# Освободить штатный marker для нового WARP iface, не удаляя ни старый unit,
# ни его конфиг. Parked marker переживает reboot/crash и удаляется только
# после подтверждённого запуска нового awg0.
_park_one_pending_warp_marker() {
    local live="$1" parked="$2" old_value="$3" new_value="$4" label="$5"
    local live_value="" parked_value=""

    if [[ -e "$parked" || -L "$parked" ]]; then
        _INSTALL_ROLLBACK_WARP_PARKED=1
        [[ -f "$parked" && ! -L "$parked" ]] \
            || { log_error "Небезопасный parked WARP ${label} marker: $parked"; return 1; }
        parked_value=$(<"$parked")
        [[ "$parked_value" == "$old_value" ]] \
            || { log_error "Parked WARP ${label} marker не соответствует прежнему iface."; return 1; }
    fi

    [[ -e "$live" || -L "$live" ]] || return 0
    [[ -f "$live" && ! -L "$live" ]] \
        || { log_error "Небезопасный WARP ${label} marker: $live"; return 1; }
    live_value=$(<"$live")
    [[ "$live_value" == "$old_value" || "$live_value" == "$new_value" ]] \
        || { log_error "WARP ${label} marker указывает на неожиданный ресурс: $live_value"; return 1; }

    # Marker нового iface означает resume после прерывания уже после parking.
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
        || { log_error "Небезопасный WARP cleanup marker: $pending"; return 1; }
    IFS= read -r old_iface < "$pending" || old_iface=""
    [[ "$old_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$old_iface" != "awg0" ]] \
        || { log_error "Некорректный старый WARP iface в cleanup marker."; return 1; }
    if [[ "${AWG_EGRESS:-direct}" == "warp" && "${AWG_WARP_IFACE:-wgcf}" == "$old_iface" ]]; then
        log_error "Cleanup marker указывает на текущий обязательный WARP ${old_iface}; parking отменён."
        return 1
    fi

    # Parking нужен только при WARP→WARP со сменой имени: в остальных режимах
    # setup нового egress не использует штатные WARP ownership marker'ы.
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
        log_error "Прежний WARP config одновременно помечен created и managed."
        return 1
    fi
    log "Ownership прежнего WARP iface '${old_iface}' сохранён до post-commit cleanup."
}

# Останавливает owned quick-интерфейс независимо от того, поднят ли он через
# systemd или вручную. Удалять marker/config разрешено только после доказанного
# отсутствия link и завершённого unit-state.
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

# Удаление старых support-unit'ов выполняется только после успешной проверки
# нового awg0. Любая ошибка оставляет pending/ownership marker для безопасной
# повторной попытки и не откатывает уже рабочую новую конфигурацию.
finalize_deferred_mode_cleanup() {
    local cleanup_failed=0 pending="" old_iface=""

    pending="$AWG_DIR/.upstream_cleanup_pending"
    if [[ -e "$pending" || -L "$pending" ]]; then
        if [[ ! -f "$pending" || -L "$pending" ]]; then
            log_warn "Post-commit cleanup: небезопасный upstream marker сохранён: $pending"
            cleanup_failed=1
        else
            IFS= read -r old_iface < "$pending" || old_iface=""
            if [[ ! "$old_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ || "$old_iface" == "awg0" ]]; then
                log_warn "Post-commit cleanup: некорректный upstream iface; marker сохранён."
                cleanup_failed=1
            elif [[ "${AWG_ROLE:-single}" == "entry" \
                    && "${AWG_UPSTREAM_IFACE:-awg1}" == "$old_iface" ]]; then
                log_warn "Post-commit cleanup: ${old_iface} всё ещё current upstream; marker сохранён без stop/delete."
                cleanup_failed=1
            elif ! stop_owned_tunnel_runtime awg "$old_iface" \
                    "/etc/amnezia/amneziawg/${old_iface}.conf"; then
                log_warn "Post-commit cleanup: старый upstream ${old_iface} не удалось полностью снять; marker сохранён."
                cleanup_failed=1
            elif ! systemctl disable "awg-quick@${old_iface}" 2>/dev/null; then
                log_warn "Post-commit cleanup: не удалось disable старый upstream ${old_iface}; marker сохранён."
                cleanup_failed=1
            else
                if command -v ufw &>/dev/null && ! ufw status 2>/dev/null | grep -q inactive \
                   && ! delete_exact_owned_ufw_route "$old_iface" "AmneziaWG cascade awg0->${old_iface}"; then
                    log_warn "Post-commit cleanup: cascade UFW rule ${old_iface} неоднозначно или чужое; marker сохранён."
                    cleanup_failed=1
                elif rm -f -- "$pending"; then
                    log "Прежний upstream ${old_iface} удалён из автозапуска после commit нового awg0."
                else
                    log_warn "Post-commit cleanup: не удалось снять upstream marker $pending."
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
            log_warn "Post-commit cleanup: небезопасный WARP marker сохранён: $pending"
            warp_preflight_ok=0
        else
            IFS= read -r old_iface < "$pending" || old_iface=""
            if [[ ! "$old_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ || "$old_iface" == "awg0" ]]; then
                log_warn "Post-commit cleanup: некорректный WARP iface; marker сохранён."
                warp_preflight_ok=0
            elif [[ "${AWG_EGRESS:-direct}" == "warp" \
                    && "${AWG_WARP_IFACE:-wgcf}" == "$old_iface" ]]; then
                log_warn "Post-commit cleanup: ${old_iface} всё ещё current WARP; marker сохранён без stop/delete."
                warp_preflight_ok=0
            fi
        fi
        old_conf="/etc/wireguard/${old_iface}.conf"
        if [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
            expected_new_service="${AWG_WARP_IFACE:-wgcf}"
            expected_new_conf="/etc/wireguard/${AWG_WARP_IFACE:-wgcf}.conf"
        fi

        # Сначала валидируем ВСЕ marker'ы; до завершения preflight unit/config
        # прежнего WARP не изменяются.
        for marker in "$parked_service" "$parked_created" "$parked_managed"; do
            [[ -e "$marker" || -L "$marker" ]] || continue
            if [[ ! -f "$marker" || -L "$marker" ]]; then
                log_warn "Post-commit cleanup: небезопасный parked marker $marker сохранён."
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
                log_warn "Post-commit cleanup: небезопасный WARP marker $marker сохранён."
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
            log_warn "Post-commit cleanup: старый WARP config одновременно created+managed; ничего не удалено."
            warp_preflight_ok=0
        fi

        if [[ "$warp_preflight_ok" -eq 1 ]]; then
            service_unit="wg-quick@${old_iface}"
            if [[ -n "$service_source" ]]; then
                if ! stop_owned_tunnel_runtime wg "$old_iface" "$old_conf"; then
                    log_warn "Post-commit cleanup: старый WARP ${old_iface} не удалось полностью снять; ownership сохранён."
                    warp_preflight_ok=0
                elif ! systemctl disable "$service_unit" 2>/dev/null; then
                    log_warn "Post-commit cleanup: не удалось disable старый WARP ${old_iface}; ownership сохранён."
                    warp_preflight_ok=0
                fi
            elif systemctl is-active --quiet "$service_unit" 2>/dev/null \
                 || systemctl is-enabled --quiet "$service_unit" 2>/dev/null \
                 || { command -v ip >/dev/null 2>&1 \
                      && ip link show dev "$old_iface" >/dev/null 2>&1; }; then
                log_warn "Post-commit cleanup: старый WARP ${old_iface} active/enabled/live без доказанного service ownership; сохранён."
                warp_preflight_ok=0
            fi
        fi

        if [[ "$warp_preflight_ok" -eq 1 ]]; then
            if [[ -n "$created_source" ]] && ! rm -f -- "$old_conf"; then
                log_warn "Post-commit cleanup: не удалось удалить installer-created $old_conf."
                warp_preflight_ok=0
            fi
        fi
        if [[ "$warp_preflight_ok" -eq 1 ]]; then
            if command -v ufw &>/dev/null && ! ufw status 2>/dev/null | grep -q inactive; then
                delete_exact_owned_ufw_route "$old_iface" "AmneziaWG→WARP egress" \
                    || warp_preflight_ok=0
            fi
            # Config managed (но не created) всегда сохраняется; удаляются
            # только ownership marker'ы старого ресурса.
            if [[ "$warp_preflight_ok" -eq 1 ]]; then
                for marker in "$service_source" "$created_source" "$managed_source"; do
                    [[ -n "$marker" ]] || continue
                    rm -f -- "$marker" || warp_preflight_ok=0
                done
            fi
            if [[ "$warp_preflight_ok" -eq 1 ]] && rm -f -- "$pending"; then
                log "Прежний WARP ${old_iface} очищен после commit нового awg0."
            else
                log_warn "Post-commit cleanup: WARP marker'ы сохранены для повторной очистки."
                warp_preflight_ok=0
            fi
        fi
        [[ "$warp_preflight_ok" -eq 1 ]] || cleanup_failed=1
    fi

    return "$cleanup_failed"
}

# awg0 must never race its egress tunnel during boot.  A narrowly-owned
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
            || { log_error "Некорректный systemd dependency marker: $AWG0_DEPENDENCY_MARKER"; return 1; }
        IFS= read -r marker_value < "$AWG0_DEPENDENCY_MARKER" || marker_value=""
        [[ "$marker_value" == "$AWG0_DEPENDENCY_DROPIN" ]] \
            || { log_error "Некорректный путь в systemd dependency marker."; return 1; }
    elif [[ -e "$AWG0_DEPENDENCY_DROPIN" || -L "$AWG0_DEPENDENCY_DROPIN" ]]; then
        log_error "Отказ перезаписывать чужой systemd drop-in $AWG0_DEPENDENCY_DROPIN"
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
    log "Загрузочная зависимость awg0 настроена: $required_unit"
}

validate_subnet() {
    local subnet="$1" o
    # Самодостаточно (шаг 0, ДО загрузки awg_common.sh): не используем _valid_ipv4/
    # _cidr_bounds. Октеты без ведущих нулей ('010...' иначе трактуется как octal).
    if ! [[ "$subnet" =~ ^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})/([0-9]{1,2})$ ]]; then
        die "Некорректная подсеть: '$subnet'. Ожидается CIDR /16-/30, напр. 10.9.0.0/16."
    fi
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}" c="${BASH_REMATCH[3]}" d="${BASH_REMATCH[4]}" prefix="${BASH_REMATCH[5]}"
    for o in "$a" "$b" "$c" "$d"; do
        (( 10#$o <= 255 )) || die "Некорректная подсеть: '$subnet'. Октет вне диапазона 0-255."
    done
    (( 10#$prefix >= 16 && 10#$prefix <= 30 )) || die "Некорректная подсеть: '$subnet'. Поддерживается только маска /16-/30."
    # Инлайн-арифметика: адрес обязан быть network или network+1.
    local ip=$(( (10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d ))
    local mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
    local network=$(( ip & mask ))
    local n1=$(( network + 1 ))
    local srv="$(( (n1 >> 24) & 255 )).$(( (n1 >> 16) & 255 )).$(( (n1 >> 8) & 255 )).$(( n1 & 255 ))"
    if (( ip != network && ip != n1 )); then
        die "Некорректная подсеть: '$subnet'. Адрес сервера должен быть ${srv} (network+1) или укажите сеть."
    fi
    # Нормализация глобала к <network+1>/<prefix> (сервер = network+1).
    AWG_TUNNEL_SUBNET="${srv}/${prefix}"
}

# Сеть туннеля из CIDR-строки (<network+1>/<prefix> -> <network>/<prefix>).
# Нужен изоляции клиентов (issue #178): при отключённой изоляции в AllowedIPs
# клиентов уходит именно network-адрес. Самодостаточно (шаг 0, ДО загрузки
# awg_common.sh): не используем _cidr_bounds/_int_to_ipv4.
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

# Явный выбор изоляции клиентов (issue #178). Приоритет:
# CLI-флаг > сохранённый конфиг > интерактивный вопрос (только первый запуск,
# без --yes) > 1 (изолированно). Старый конфиг без ключа = 1: до этой фичи
# split-режимы были изолированы де-факто, поведение сохраняется.
configure_client_isolation() {
    case "$CLI_ISOLATION" in
        on)  CLIENT_ISOLATION=1; log "Изоляция клиентов из CLI: включена." ;;
        off) CLIENT_ISOLATION=0; log "Изоляция клиентов из CLI: отключена." ;;
        default)
            if [[ -n "${CLIENT_ISOLATION:-}" ]]; then
                log "Изоляция клиентов (из конфига): $( [[ "$CLIENT_ISOLATION" -eq 1 ]] && echo включена || echo отключена )."
            elif [[ "${config_exists:-0}" -eq 1 ]]; then
                CLIENT_ISOLATION=1
                log "Изоляция клиентов: включена (конфиг до v5.20 - прежнее поведение)."
            elif [[ "$AUTO_YES" -eq 1 ]]; then
                CLIENT_ISOLATION=1
                log "Изоляция клиентов: включена (--yes, по умолчанию)."
            else
                local r_iso
                read -rp "Изолировать клиентов VPN друг от друга? [Y/n]: " r_iso < /dev/tty
                case "$r_iso" in
                    [nN]*) CLIENT_ISOLATION=0; log "Изоляция клиентов отключена: клиенты будут видеть друг друга внутри VPN." ;;
                    *)     CLIENT_ISOLATION=1; log "Изоляция клиентов включена." ;;
                esac
            fi
            ;;
        *) die "Некорректное значение --isolation='$CLI_ISOLATION'. Допустимо: on|off." ;;
    esac
    export CLIENT_ISOLATION
}

# Приводит ALLOWED_IPS в соответствие с CLIENT_ISOLATION (идемпотентно,
# вызывается на каждом запуске после определения режима маршрутизации).
# Изоляция ВЫКЛ: сеть туннеля дописывается в список (режимы 2/3; в режиме 1
# 0.0.0.0/0 уже покрывает её). Изоляция ВКЛ: наш токен убирается из режима 2
# (round-trip off->on); режим 3 не трогаем - кастомный список принадлежит
# пользователю, а изоляцию всё равно обеспечивает DROP-правило на сервере.
# CLIENT_ISOLATION_NET хранит ownership нашего токена (пуст, если токен
# пользовательский или изоляция включена) - нужен, чтобы вычистить прежний
# маршрут при смене подсети туннеля (issue #178, финальный аудит).
_apply_isolation_to_allowed_ips() {
    local net
    net=$(tunnel_network_cidr "$AWG_TUNNEL_SUBNET") || return 0
    # Убираем ВЕСЬ whitespace, не только пробелы: validate_cidr_list принимает
    # табы как разделители, и токен с табом иначе не распознавался бы pattern-
    # матчем ниже - задваивание вместо no-op (ревью PR #179).
    local compact=",${ALLOWED_IPS//[[:space:]]/},"

    # Смена подсети туннеля: наш прежний токен (persisted CLIENT_ISOLATION_NET)
    # отличается от текущей сети - убираем в любом режиме и при любом состоянии
    # изоляции: токен по конструкции добавлен нами, а не пользователем.
    if [[ -n "${CLIENT_ISOLATION_NET:-}" && "$CLIENT_ISOLATION_NET" != "$net" ]]; then
        if [[ "$compact" == *",${CLIENT_ISOLATION_NET},"* ]]; then
            # Цикл, а не одиночный replace: в испорченном списке токен может
            # встречаться несколько раз - вычищаем все копии (ревью PR #179).
            while [[ "$compact" == *",${CLIENT_ISOLATION_NET},"* ]]; do
                compact="${compact/,${CLIENT_ISOLATION_NET},/,}"
            done
            compact="${compact#,}"; compact="${compact%,}"
            ALLOWED_IPS="${compact//,/, }"
            log "Смена подсети туннеля: прежний маршрут ${CLIENT_ISOLATION_NET} убран из AllowedIPs клиентов."
            compact=",${ALLOWED_IPS// /},"
        fi
        CLIENT_ISOLATION_NET=""
    fi

    if [[ "${CLIENT_ISOLATION:-1}" -eq 0 ]]; then
        if [[ "$ALLOWED_IPS_MODE" == "1" ]]; then
            CLIENT_ISOLATION_NET=""
        elif [[ "$compact" == *",${net},"* ]]; then
            # Уже есть: наш прежний (CLIENT_ISOLATION_NET==net сохранён) или
            # пользовательский (CLIENT_ISOLATION_NET пуст) - ownership не меняем.
            :
        else
            ALLOWED_IPS="${ALLOWED_IPS}, ${net}"
            CLIENT_ISOLATION_NET="$net"
            log "Изоляция отключена: подсеть туннеля ${net} добавлена в AllowedIPs клиентов."
        fi
    else
        # Изоляция ВКЛ: режим 2 - токен убираем всегда (список генерируется нами);
        # режим 3 - только если токен добавили мы (ownership в CLIENT_ISOLATION_NET).
        if [[ "$compact" == *",${net},"* ]] \
           && { [[ "$ALLOWED_IPS_MODE" == "2" ]] || [[ "${CLIENT_ISOLATION_NET:-}" == "$net" ]]; }; then
            while [[ "$compact" == *",${net},"* ]]; do
                compact="${compact/,${net},/,}"
            done
            compact="${compact#,}"; compact="${compact%,}"
            ALLOWED_IPS="${compact//,/, }"
            log "Изоляция включена: подсеть туннеля ${net} убрана из AllowedIPs клиентов."
        fi
        CLIENT_ISOLATION_NET=""
    fi
    export CLIENT_ISOLATION_NET
}

# Валидация имени сервера для vpn:// URI (D#180): поле description показывается
# в приложении Amnezia после импорта. Ограничения продиктованы хранением в
# awgsetup_cfg.init (обёртка '...') и вложением в JSON: без кавычек и бэкслеша,
# без управляющих символов ([[:cntrl:]] целиком: ESC от стрелок в интерактивном
# вводе ломал бы JSON - je() контролы не экранирует), без пробелов по краям
# (клиент показал бы визуально пустое имя). Длина - до 128 БАЙТ в C-локали
# (LC_ALL=C даёт предсказуемый счёт на любой системной локали; 128 байт
# вмещают 64 кириллических символа UTF-8).
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

# Срез пробелов по краям (для дружелюбия: случайный хвостовой пробел в
# --server-name или интерактивном вводе не должен валить установку).
_trim_ws() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# --mobile (D#38, полевой тест 26 jun): shorthand мобильного сетапа =
# --preset=mobile + порт 443/udp. Главная мобильная проблема - порт: на МТС
# дефолтный 39743/udp глушится, 443/udp (похож на QUIC/HTTP3) работает.
# Разворачивается в CLI_PRESET/CLI_PORT ДО их потребителей: явный --port
# пользователя выигрывает, противоречащий --preset - ошибка.
resolve_mobile_flag() {
    [[ "${CLI_MOBILE:-0}" -eq 1 ]] || return 0
    if [[ -n "${CLI_PRESET:-}" && "$CLI_PRESET" != "mobile" ]]; then
        die "--mobile несовместим с --preset=${CLI_PRESET}: --mobile уже включает preset mobile."
    fi
    CLI_PRESET="mobile"
    if [[ -z "$CLI_PORT" ]]; then
        CLI_PORT=443
        log "--mobile: порт 443/udp (мобильные операторы часто глушат нестандартные UDP-порты)."
    fi
}

# Имя сервера в приложении Amnezia (D#180). Приоритет: CLI-флаг > сохранённый
# конфиг > интерактивный вопрос (первый запуск без --yes) > 'AWG Server'.
# Значение из конфига перепроверяется: файл могли править руками, а имя
# уходит в JSON vpn:// URI.
configure_server_name() {
    local _name
    if [[ -n "$CLI_SERVER_NAME" ]]; then
        _name=$(_trim_ws "$CLI_SERVER_NAME")
        validate_server_name "$_name" \
            || die "Некорректное --server-name: без кавычек, бэкслеша и управляющих символов, не длиннее 128 байт."
        AWG_SERVER_NAME="$_name"
        log "Имя сервера из CLI: ${AWG_SERVER_NAME}"
    elif [[ -n "${AWG_SERVER_NAME:-}" ]]; then
        _name=$(_trim_ws "$AWG_SERVER_NAME")
        if validate_server_name "$_name"; then
            AWG_SERVER_NAME="$_name"
        else
            log_warn "AWG_SERVER_NAME из $CONFIG_FILE не валидно, использую 'AWG Server'."
            AWG_SERVER_NAME="AWG Server"
        fi
    elif [[ "${config_exists:-0}" -eq 1 || "$AUTO_YES" -eq 1 ]]; then
        AWG_SERVER_NAME="AWG Server"
    else
        local input_name
        while true; do
            read -rp "Имя сервера в приложении Amnezia [AWG Server]: " input_name < /dev/tty
            input_name=$(_trim_ws "$input_name")
            if [[ -z "$input_name" ]]; then AWG_SERVER_NAME="AWG Server"; break; fi
            if validate_server_name "$input_name"; then AWG_SERVER_NAME="$input_name"; break; fi
            log_warn "Без кавычек, бэкслеша и управляющих символов, не длиннее 128 байт. Повторите ввод."
        done
    fi
    export AWG_SERVER_NAME
}

# Guard смены подсети: [Peer]-блоки переносятся при переустановке как есть
# (render_server_config), их адреса выданы в СТАРОЙ подсети. Смена подсети
# под живыми клиентами ломает их: старые IPv4 могут выпасть из нового
# диапазона, а IPv6-суффиксы - столкнуться (decimal-кодировка /24 против
# hex у не-/24 масок даёт два пира с одним ::x). Поэтому при наличии пиров
# установка с другой подсетью прерывается (ревью PR #167). Самодостаточно
# (шаг 0, ДО загрузки awg_common.sh). Старая подсеть - первое значение
# Address в [Interface] awg0.conf: это нормализованный <network+1>/<prefix>,
# а новый AWG_TUNNEL_SUBNET к моменту вызова нормализован validate_subnet -
# строкового сравнения достаточно.
guard_subnet_change_with_peers() {
    [[ -f "$SERVER_CONF_FILE" ]] || return 0
    grep -q '^\[Peer\]' "$SERVER_CONF_FILE" 2>/dev/null || return 0
    local old_subnet
    # Address может быть dual-stack ("IPv4/n, IPv6/n") в любом порядке - берём
    # именно IPv4-элемент, а не просто первый через запятую (иначе IPv6-первый
    # Address дал бы ложную смену подсети). Нет IPv4 -> пусто -> fail-closed ниже.
    old_subnet=$(sed -n 's/^[[:space:]]*Address[[:space:]]*=[[:space:]]*//p' "$SERVER_CONF_FILE" 2>/dev/null \
        | tr ',' '\n' | sed 's/[[:space:]]//g' \
        | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$')
    if [[ -z "$old_subnet" ]]; then
        # Пиры есть, а старую подсеть определить нельзя - fail-closed: молчаливое
        # продолжение перерендерило бы конфиг в новой подсети и сломало клиентов.
        die "В ${SERVER_CONF_FILE} уже есть пиры, но строка Address в [Interface] не читается - проверить смену подсети невозможно. Восстановите Address, либо удалите клиентов (sudo bash $MANAGE_SCRIPT_PATH remove <имя>), либо --uninstall и чистая установка."
    fi
    if [[ "$old_subnet" != "$AWG_TUNNEL_SUBNET" ]]; then
        die "Подсеть туннеля изменена (${old_subnet} -> ${AWG_TUNNEL_SUBNET}), но в ${SERVER_CONF_FILE} уже есть пиры: их адреса выданы в старой подсети, смена сломает клиентов. Варианты: оставьте прежнюю подсеть; удалите всех клиентов (sudo bash $MANAGE_SCRIPT_PATH remove <имя>); либо --uninstall и чистая установка."
    fi
    return 0
}

# Валидация endpoint (FQDN / IPv4 / [IPv6]).
# Возвращает 0 если endpoint безопасен и попадает под один из форматов,
# иначе 1 (caller сам решает die или log_warn + unset).
# Запрещает newline/CR/quotes/backslash чтобы предотвратить injection в
# awgsetup_cfg.init и client.conf через --endpoint флаг (audit).
validate_endpoint() {
    local ep="$1"
    [[ -n "$ep" ]] || return 1
    # Запрещаем символы которые могут сломать конфиг или внести injection
    [[ "$ep" != *$'\n'* && "$ep" != *$'\r'* && \
       "$ep" != *"'"* && "$ep" != *'"'* && "$ep" != *'\\'* && \
       "$ep" != *' '* && "$ep" != *$'\t'* ]] || return 1
    # Форма [IPv6]: структурная проверка содержимого скобок. Прежний charset-only
    # пропускал мусор вроде [:::] / [1:2:3]. Зеркало _valid_ipv6 из awg_common.sh.
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
    # Иначе FQDN или IPv4
    [[ "$ep" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*|[0-9]{1,3}(\.[0-9]{1,3}){3})$ ]] || return 1
    # Если IPv4 формат - дополнительно проверяем диапазон октетов 0-255
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
    # Перевод строки = инъекция в awgsetup_cfg.init (read <<< видит только первую
    # строку, остальное прошло бы без проверки). Аналогично validate_endpoint.
    [[ "$input" != *$'\n'* ]] || return 1
    # Структурная проверка запятых до split: bash IFS отбрасывает хвостовой пустой
    # элемент, поэтому '10.0.0.0/24,' раньше проходил. Отвергаем ведущую/хвостовую/
    # двойную запятую и пустой ввод (пробелы игнорируем при этой проверке).
    nospace="${input// /}"
    case "$nospace" in
        ""|,*|*,|*,,*) return 1 ;;
    esac
    IFS=',' read -ra cidrs <<< "$input"
    for cidr in "${cidrs[@]}"; do
        cidr="${cidr// /}"
        # Октеты без ведущих нулей; префикс 0-32 прямо в regex (без octal-арифметики).
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
            if [ -z "$ALLOWED_IPS" ]; then die "Не указаны сети для --route-custom."; fi
        fi
        log "Режим маршрутизации из CLI: $ALLOWED_IPS_MODE"
    elif [[ "$AUTO_YES" -eq 1 ]]; then
        ALLOWED_IPS_MODE=2
        log "Режим маршрутизации: Amnezia+DNS (--yes, по умолчанию)."
    else
        echo ""
        log "Выберите режим маршрутизации (AllowedIPs клиента):"
        echo "  1) Весь трафик (0.0.0.0/0) - Макс. приватность, может блокировать LAN"
        echo "  2) Список Amnezia+DNS (умолч.) - Рекомендуется для обхода блокировок"
        echo "  3) Только указанные сети (Split Tunneling)"
        read -rp "Ваш выбор [2]: " r_mode < /dev/tty
        ALLOWED_IPS_MODE=${r_mode:-2}
    fi
    case "$ALLOWED_IPS_MODE" in
        1) ALLOWED_IPS="0.0.0.0/0"
           log "Выбран режим: Весь трафик." ;;
        3) if [[ -z "$CLI_CUSTOM_ROUTES" ]]; then
               read -rp "Введите сети (a.b.c.d/xx,...): " ALLOWED_IPS < /dev/tty
               while ! validate_cidr_list "$ALLOWED_IPS"; do
                   log_warn "Некорректный формат CIDR: '$ALLOWED_IPS'. Ожидается: x.x.x.x/y[,x.x.x.x/y]"
                   read -rp "Повторите ввод: " ALLOWED_IPS < /dev/tty
               done
           else
               ALLOWED_IPS=$CLI_CUSTOM_ROUTES
               if ! validate_cidr_list "$ALLOWED_IPS"; then
                   die "Некорректный формат CIDR: '$ALLOWED_IPS'. Ожидается: x.x.x.x/y[,x.x.x.x/y]"
               fi
           fi
           log "Выбран режим: Пользовательский ($ALLOWED_IPS)" ;;
        *) ALLOWED_IPS_MODE=2
           # iOS рвёт туннель, если список начинается с 0.0.0.0/5: этот блок включает
           # служебный 0.0.0.0/8, на котором ядро iOS спотыкается и не доходит до остальных
           # маршрутов. 1.0.0.0/8 + 2.0.0.0/7 + 4.0.0.0/6 = тот же охват без нулевого блока
           # (0.0.0.0/8 всё равно не маршрутизируется). Не возвращать к 0.0.0.0/5 (Issue #42).
           ALLOWED_IPS="1.0.0.0/8, 2.0.0.0/7, 4.0.0.0/6, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
           log "Выбран режим: Список Amnezia+DNS." ;;
    esac
    if [ -z "$ALLOWED_IPS" ]; then die "Не удалось определить AllowedIPs."; fi
    export ALLOWED_IPS_MODE ALLOWED_IPS
}

# ==============================================================================
# Генерация AWG 2.0 параметров (inline — нужны в шаге 0, до скачивания awg_common.sh)
# ==============================================================================

# Случайное число [min, max] через /dev/urandom (поддержка uint32)
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
# Минимальная ширина каждого диапазона = 1000 (для нормальной обфускации).
# Печатает 4 строки формата "low-high" в stdout.
# Возвращает 1 если за 20 попыток не удалось получить корректные диапазоны.
#
# Диапазон: [0, 2^31-1] = [0, 2147483647]. Спецификация AmneziaWG допускает
# полный uint32 (0-4294967295), но standalone Windows-клиент
# `amneziawg-windows-client` имеет UI-валидатор ограниченный 2^31-1 в
# `ui/syntax/highlighter.go:isValidHField()` (upstream bug
# amnezia-vpn/amneziawg-windows-client#85, не исправлен). Значения выше
# 2^31-1 на сервере работают, но клиентский редактор подчёркивает их
# красным и не даёт сохранять правки. Для совместимости генерируем в
# безопасной половине диапазона (#40).
#
# Оптимизация: один вызов `od -N32 -tu4` читает 32 байта = 8 uint32 значений
# одной операцией, вместо 8 отдельных subprocess через rand_range.
# Fallback на rand_range если /dev/urandom недоступен.
generate_awg_h_ranges() {
    local attempt=0 max_attempts=20
    while (( attempt < max_attempts )); do
        local raw arr=() _v
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

# Генерация CPS строки для I1
# Формат: "<r N>" где N — количество случайных байт (32-256)
generate_cps_i1() {
    local n
    n=$(rand_range 32 256)
    echo "<r ${n}>"
}

# Генерация I1 в режиме "QUIC v1 Initial" — литерал `<b 0xHEX...>`, где HEX
# формирует валидный QUIC Initial-пакет (RFC 9000 §17.2.2). Идея: DPI
# мобильных операторов смотрит на первый байт и несколько последующих,
# видит 0xc? + version 0x00000001 + разумную структуру — и пропускает как
# обычный QUIC-трафик браузера. AWG-handshake идёт ПОСЛЕ этих байт, сервер
# их срезает (у него тот же I1 в конфиге).
#
# Структура:
#   [0]       type byte   — биты 7-6 = 11 (long + fixed), 5-4 = 00 (Initial),
#                          3-0 произвольные (в реальном QUIC защищены
#                          header-protection XOR — мы эмулируем случайным
#                          значением в [0, 15]). Итого 0xc0..0xcf.
#   [1-4]    version      — 0x00000001 (QUIC v1)
#   [5]      dcid_len     — 16-20
#   [6..]    dcid         — random
#   [..]     scid_len     — 8-16
#   [..]     scid         — random
#   [..]     token_len    — 0 (1-байтовый varint 0x00)
#   [..]     length       — 2-байтовый varint = 3 (PN) + payload_len
#   [..]     packet_num   — 3 random bytes
#   [..]     payload      — random bytes (~1 KiB, "похоже на AEAD output")
#
# Итоговая длина блоба ≈1100-1250 байт, как у типичного QUIC Initial.
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
    # 2-byte varint (2MSB=01, остальные 14 бит — значение BE)
    enc_b1=$(printf '%02x' $(( 0x40 | (enc_len >> 8) )))
    enc_b2=$(printf '%02x' $(( enc_len & 0xFF )))
    # Первый байт: 0xc0 | random(0..15). Эмулирует header-protected бит.
    type_byte=$(printf '%02x' $(( 0xc0 | $(rand_range 0 15) )))
    version="00000001"
    dcid=$(od -An -tx1 -N"$dcid_len" /dev/urandom 2>/dev/null | tr -d ' \n')
    scid=$(od -An -tx1 -N"$scid_len" /dev/urandom 2>/dev/null | tr -d ' \n')
    pn=$(od -An -tx1 -N3 /dev/urandom 2>/dev/null | tr -d ' \n')
    payload=$(od -An -tx1 -N"$payload_len" /dev/urandom 2>/dev/null | tr -d ' \n')
    if [[ -z "$dcid" || -z "$scid" || -z "$pn" || -z "$payload" ]]; then
        log_error "generate_cps_i1_quic: не удалось прочитать /dev/urandom"
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

# Меняет только I1, не перегенерируя J/S/H и не сбрасывая ручные I2-I5.
# Это важно для повторного запуска с одним --i1-mode: полный генератор сделал
# бы все ранее выданные клиентские конфиги несовместимыми без необходимости.
generate_i1_for_mode() {
    local mode="${1:-random}"
    case "$mode" in
        random)
            AWG_I1=$(generate_cps_i1)
            ;;
        quic)
            AWG_I1=$(generate_cps_i1_quic) || die "Ошибка генерации QUIC I1"
            log "  I1 mode: quic (фейковый QUIC v1 Initial, $(( (${#AWG_I1} - 6) / 2 )) байт)"
            ;;
        *)
            die "Некорректный --i1-mode='$mode'. Допустимо: random, quic."
            ;;
    esac
    AWG_I1_MODE="$mode"
    export AWG_I1 AWG_I1_MODE
}

# Генерация всех AWG 2.0 параметров
# Поддерживает --preset=default|mobile и точечные --jc/--jmin/--jmax overrides
generate_awg_params() {
    local preset="${CLI_PRESET:-default}"
    log "Генерация параметров AWG 2.0 (preset: $preset)..."

    case "$preset" in
        default)
            # Jc 3-6: компромисс между обфускацией и совместимостью с мобильными (Discussion #38)
            AWG_Jc=$(rand_range 3 6)
            AWG_Jmin=$(rand_range 40 89)
            # Jmax = Jmin + 50..250 (~90-339 байт, Issue #42)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 50 250) ))
            ;;
        mobile)
            # Jc=3 фиксированный: alkorrnd (Tele2) — Jc=3 >95%, Jc=4 ~30%, Jc=5 <5%
            # Узкий Jmax: markmokrenko (Yota) — Jmax=70 работает, Jmax>300 блокируется
            AWG_Jc=3
            AWG_Jmin=$(rand_range 30 50)
            AWG_Jmax=$(( AWG_Jmin + $(rand_range 20 80) ))
            log "  Preset 'mobile': Jc=3, узкий Jmax для мобильных сетей"
            ;;
        *)
            die "Неизвестный preset: '$preset'. Допустимые: default, mobile"
            ;;
    esac

    # Точечные CLI overrides (поверх preset)
    if [[ -n "${CLI_JC:-}" ]]; then
        validate_jc_value "$CLI_JC" || die "Невалидный --jc=$CLI_JC (допустимо: 1-128)"
        AWG_Jc="$CLI_JC"
    fi
    if [[ -n "${CLI_JMIN:-}" ]]; then
        validate_junk_size "$CLI_JMIN" || die "Невалидный --jmin=$CLI_JMIN (допустимо: 0-1280)"
        AWG_Jmin="$CLI_JMIN"
    fi
    if [[ -n "${CLI_JMAX:-}" ]]; then
        validate_junk_size "$CLI_JMAX" || die "Невалидный --jmax=$CLI_JMAX (допустимо: 0-1280)"
        AWG_Jmax="$CLI_JMAX"
    fi

    # Sanity: Jmax >= Jmin
    if [[ "$AWG_Jmax" -lt "$AWG_Jmin" ]]; then
        die "Jmax ($AWG_Jmax) не может быть меньше Jmin ($AWG_Jmin)"
    fi

    AWG_PRESET="$preset"
    AWG_S1=$(rand_range 15 150)
    AWG_S2=$(rand_range 15 150)

    # Критическое ограничение из kernel: S1+56 != S2
    # Предотвращает одинаковый размер init и response сообщений
    while [[ $((AWG_S1 + 56)) -eq $AWG_S2 ]]; do
        AWG_S2=$(rand_range 15 150)
    done

    # ⚠️ Нижние границы S3/S4 несовместимы с header protection из AmneziaWG 3.0.
    # Там nonce для ChaCha20 нигде не передаётся, а берётся из первых 12 байт
    # S-паддинга соответствующего сообщения (HEADER_PROTECTION_NONCE_SIZE = 12),
    # поэтому обе реализации ОТКАЗЫВАЮТ в конфиге, если при заданном ключе
    # защиты заголовков любой из S1-S4 меньше 12: модуль ядра возвращает -EINVAL
    # (src/netlink.c, проверка has_protection && val16 < HEADER_PROTECTION_NONCE_SIZE),
    # amneziawg-go отдаёт ошибку из device/uapi.go (есть с v3.0.0). То есть отказ
    # ГРОМКИЙ, тихого ослабления шифра нет - проверено по исходникам 2 aug 2026.
    # Пока мы на 2.0 и ключа защиты заголовков не ставим, эти диапазоны безопасны.
    # ПРИ ВКЛЮЧЕНИИ header protection поднять обе нижние границы до 12, иначе
    # часть установок просто не поднимет интерфейс. Держать в паре с гейтом
    # _kernel_supports_awg3.
    AWG_S3=$(rand_range 8 55)

    # Вторая коллизия размеров: response+S2 != cookie+S3, то есть S3 != S2+28.
    # Размеры сообщений (src/messages.h модуля ядра): init 148, response 92,
    # cookie reply 64. Первые два измерены в проводе, cookie считается как
    # 4 (header) + 4 (receiver_index) + 24 (nonce) + 32 (cookie 16 + authtag 16).
    # Отсюда три условия совпадения итоговых размеров:
    #   init/response   -> S2 = S1 + 56  (проверено циклом выше)
    #   response/cookie -> S3 = S2 + 28  (проверяем здесь)
    #   init/cookie     -> S3 = S1 + 84  (недостижимо: минимум S1+84 = 99 при
    #                                     максимуме S3 = 55, цикл не нужен)
    # Перегенерируем именно S3, а не S2: S2 уже прошёл проверку на S1+56.
    while [[ $((AWG_S2 + 28)) -eq $AWG_S3 ]]; do
        AWG_S3=$(rand_range 8 55)
    done

    AWG_S4=$(rand_range 4 27)

    # H1-H4: 4 случайных непересекающихся uint32 диапазона.
    # Рандомизация на каждую установку защищает от ТСПУ-фингерпринта
    # по статическим H-значениям (Discussion #38, elvaleto/Klavishnik).
    # Алгоритм: 8 случайных uint32 → sort → 4 непересекающиеся пары.
    local _h_lines
    mapfile -t _h_lines < <(generate_awg_h_ranges) || true
    if [[ ${#_h_lines[@]} -ne 4 ]]; then
        die "Не удалось сгенерировать H1-H4 диапазоны."
    fi
    AWG_H1="${_h_lines[0]}"
    AWG_H2="${_h_lines[1]}"
    AWG_H3="${_h_lines[2]}"
    AWG_H4="${_h_lines[3]}"

    # I1: CPS concealment. Два режима:
    #   random (умолч.) — <r N>, N случайных байт 32-256
    #   quic            — <b 0x...> ≈1100-1250 байт, маскированных под QUIC v1
    #                     Initial. Самый сильный режим против DPI мобильных
    #                     операторов. Сервер и клиенты получают ТОТ ЖЕ I1
    #                     из конфига, AWG handshake идёт после этих байт.
    generate_i1_for_mode "${CLI_I1_MODE:-${AWG_I1_MODE:-random}}"

    # I2-I5 здесь НЕ генерируются (admin задаёт их вручную в awg0.conf, issue #71).
    # Свежая генерация набора (первая установка или --preset/--jc/--jmin/--jmax)
    # сбрасывает возможные stale I2-I5, загруженные из awgsetup_cfg.init, чтобы новый
    # набор обфускации не тащил старые значения (--preset перегенерирует весь набор).
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
    log "Параметры AWG 2.0 сгенерированы."
}

# ==============================================================================
# Системная оптимизация (новое в v5.0)
# ==============================================================================

# Определение характеристик железа
detect_hardware() {
    TOTAL_RAM_MB=$(awk '/MemTotal/ {printf "%.0f", $2/1024}' /proc/meminfo)
    CPU_CORES=$(nproc)
    MAIN_NIC=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    log "Железо: RAM=${TOTAL_RAM_MB}MB, CPU=${CPU_CORES} ядер, NIC=${MAIN_NIC}"
}

# _cleanup_package_list : имена пакетов, которые cleanup_system удалит на этой ОС.
# Один источник для очистки и для вопроса на шаге 0 - иначе они разъедутся.
# ⚠️ У OS_ID НЕТ дефолта намеренно: неизвестная ОС не должна получать разрушительный
# суперсет (snapd, lxd-agent-loader и снос каталогов снапов). Пусто = считаем не Ubuntu.
_cleanup_package_list() {
    local list="modemmanager networkd-dispatcher unattended-upgrades packagekit udisks2"
    [[ "${OS_ID:-}" == "ubuntu" ]] && list="snapd $list lxd-agent-loader"
    printf '%s' "$list"
}

# _boot_critical_package_list : пакеты, потеря которых оставляет сервер без
# загрузки или без сети. Ядро списка пришло из разбора Issue #223: там
# `apt full-upgrade` на шаге 1 удалил пакеты, включая udev, initramfs-tools
# и netplan.io, после чего сервер перестал грузиться. Без udev не создаётся
# /dev/disk/by-label, systemd не дожидается разделов, записанных в fstab
# метками, и уходит в аварийный режим (по умолчанию через 90 секунд ожидания,
# см. DefaultDeviceTimeoutSec; оба раздела ждались параллельно, а не по
# очереди). Часть имён добавлена по смыслу, а не по тому инциденту: потеря
# openssh-server, systemd-resolved или ifupdown отрезает доступ так же надёжно.
#
# Как до этого доходит. cleanup_system удаляет свой список, а метапакет
# ubuntu-server оказывается обратной зависимостью удаляемого и уходит вместе с
# ним. На образах, где он был единственным manual-корнем, всё висевшее под ним
# (ubuntu-standard, ubuntu-minimal и их зависимости) получает статус "больше не
# требуется". Само по себе это ещё не удаление: apt такие пакеты перечисляет и
# предлагает `apt autoremove`. Но при разрешении зависимостей во время
# обновления резолвер вправе выбрать удаление вместо обновления, и для пакета,
# который больше никому не нужен, это дешёвый выбор. В Issue #223 он его и
# сделал. Решение резолвера мы не воспроизводили: известен исход, а не мотив.
#
# ⚠️ Имена ubuntu-server/ubuntu-minimal/ubuntu-standard существуют только в
# Ubuntu. На Debian той же цепочки нет, и там список работает как обычная
# страховка: _installed_boot_critical просто не найдёт отсутствующих.
#
# ⚠️ Список НЕ равен hold-списку из cleanup_system: тот защищает во время
# purge, этот - во время обновления. Пересечение есть, назначение разное.
_boot_critical_package_list() {
    printf '%s' "udev initramfs-tools openssh-server netplan.io netplan-generator systemd-resolved ifupdown ubuntu-minimal ubuntu-standard"
}

# _pkg_present : 0, если пакет присутствует в системе в любом рабочем виде.
# Смотрим на третье поле Status, а не на подстроку "ok installed": сразу после
# purge или прерванного обновления пакет может стоять как half-configured или
# unpacked. Для наших целей он присутствует, и защищать его надо.
_pkg_present() {
    local state
    state="$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null | awk '{print $3}')"
    case "$state" in
        ""|not-installed|config-files) return 1 ;;
        *) return 0 ;;
    esac
}

# _installed_boot_critical : те из них, что реально стоят в этой системе.
# Печатает по одному имени в строке; пустой вывод - повод насторожиться,
# а не нормальная ситуация: udev есть практически на любом сервере.
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

# _pkg_installed_ok : 0 только если пакет полностью установлен И настроен.
# Отличие от _pkg_present намеренное, и оно несимметрично по риску. Для СНИМКА
# "распакован, но не настроен" - это присутствие: пакет есть, его надо
# защищать. Для ВЕРДИКТА перед перезагрузкой - нет: initramfs-tools в
# состоянии unpacked означает, что postinst не отработал и initramfs под новое
# ядро не собран. Сервер не загрузится, хотя пакет формально "есть".
_pkg_installed_ok() {
    # Смотрим ТОЛЬКО третье поле. Полная строка Status это "<желание> <ошибка>
    # <состояние>", и привязка к "install ok installed" целиком пинит заодно
    # флаг желания: `apt-mark hold` ставит "hold ok installed", то есть
    # полностью исправный пакет читался бы как потерянный. Для нас это не
    # теория - cleanup_system специально бережёт пользовательские hold'ы.
    # Состояние installed отсекает то, ради чего предикат и заведён:
    # unpacked, half-configured, half-installed, config-files.
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null | awk '{print $3}')" == "installed" ]]
}

# Снимок ПЕРЕЖИВАЕТ перезапуски установщика и умеет только расти.
#
# Установщик сам просит запустить себя заново после отказа, а к этому моменту
# пакет уже может быть удалён: apt способен снести udev и следом упасть, и
# тогда проверка в конце шага просто не выполнится. Снимок, взятый заново в
# следующем запуске, удалённого пакета уже не увидит, и проверка сверит
# систему с обеднённым эталоном - то есть промолчит ровно про то состояние,
# ради которого написана. Поэтому объединяем с записанным ранее.
#
# Из файла берутся ТОЛЬКО известные имена: испорченный или подменённый файл не
# должен превращаться в список произвольных пакетов для установки.
_boot_critical_snapshot() {
    local now stored known union
    now="$(_installed_boot_critical)"
    stored=""
    if [[ -e "$BOOT_CRITICAL_SNAPSHOT_FILE" && ! -r "$BOOT_CRITICAL_SNAPSHOT_FILE" ]]; then
        # Иначе нечитаемый файл был бы неотличим от отсутствующего: список
        # молча ужался бы, и функция тут же перезаписала бы им историю, хотя
        # её договор - только расти.
        log_warn "Файл $BOOT_CRITICAL_SNAPSHOT_FILE существует, но не читается. Список за прошлые запуски не будет учтён."
    elif [[ -r "$BOOT_CRITICAL_SNAPSHOT_FILE" ]]; then
        known="$(_boot_critical_package_list | tr ' ' '\n')"
        stored="$(grep -Fxf <(printf '%s\n' "$known") "$BOOT_CRITICAL_SNAPSHOT_FILE" 2>/dev/null || true)"
    fi
    union="$(printf '%s\n%s\n' "$now" "$stored" | grep -v '^$' | sort -u)"
    if [[ -n "$union" ]]; then
        mkdir -p "$AWG_DIR" 2>/dev/null || true
        printf '%s\n' "$union" > "$BOOT_CRITICAL_SNAPSHOT_FILE" 2>/dev/null \
            || log_warn "Не удалось сохранить список защищаемых пакетов в $BOOT_CRITICAL_SNAPSHOT_FILE. Проверка переживёт этот запуск, но не следующий."
    fi
    printf '%s' "$union"
}

# _verify_boot_critical : последний рубеж перед перезагрузкой. Принимает снимок,
# снятый ДО обновления, и сверяет его с состоянием прямо сейчас.
#
# Вызов стоит вплотную к request_reboot и не должен от него отрываться. Смысл
# проверки в том, что после неё не выполняется больше ничего, способного
# удалить пакет: в шаге 1 между обновлением и перезагрузкой живёт ещё
# install_packages, а он зовёт apt install без --no-remove. Проверка, стоящая
# раньше него, оставила бы окно ровно того же класса, который она закрывает.
#
# Почему это вообще нужно: apt вправе удалять пакеты ради разрешения
# зависимостей, и в Issue #223 так ушёл udev - сервер перестал грузиться, а
# перезагрузку инициируем мы сами. Значит ловить надо здесь, пока доступ к
# серверу есть: после reboot чинить придётся через консоль хостера.
_verify_boot_critical() {
    local critical_before="$1"
    if [[ -z "$critical_before" ]]; then
        log_warn "Список защищаемых пакетов пуст, сверять нечего. Это ненормально для Ubuntu и Debian: проверьте dpkg-query -W udev, сервер может не загрузиться после перезагрузки."
        return 0
    fi
    local critical_lost=""
    local pkg
    for pkg in $critical_before; do
        _pkg_installed_ok "$pkg" || critical_lost+="$pkg "
    done
    [[ -n "$critical_lost" ]] || return 0
    critical_lost="${critical_lost% }"

    # Прежде чем винить обновление: неисправный dpkg даёт ровно ту же картину,
    # и сообщение "пакеты удалены" увело бы разбор не туда.
    _dpkg_usable || die "dpkg перестал отвечать, состояние пакетов проверить нечем. НЕ ПЕРЕЗАГРУЖАЙТЕ сервер. Выполните: dpkg --configure -a; apt-get check - и запустите установщик снова."

    log_warn "Исчезли пакеты, без которых сервер не загрузится: $critical_lost"
    log_warn "Восстанавливаю их..."
    local restore_out restore_rc

    # Ступень 1: ОДНА транзакция, все потерянные имена сразу.
    # Дело в том, ЧТО становится целью резолвера. Поштучно `apt-get install
    # udev` не знает про остальные потерянные имена: они не цели, и apt волен
    # оставить их отсутствующими. Одной командой целями становятся все, и apt
    # ищет набор версий, устраивающий группу целиком. В Issue #223 поштучный
    # проход дал пять отказов, а одной транзакцией там не пробовали вовсе, и
    # это причина начинать именно с неё.
    # ⚠️ Не гарантия, по двум причинам.
    # Первая: если старую версию держит пакет, которого в списке потерянных НЕТ
    # (в Issue #223 это systemd-resolved с Depends на точные 8.12 у systemd и
    # libsystemd-shared; вторым звеном там udev объявляет Breaks на systemd
    # старше 8.17, и вместе эти два условия и заперли группу), целью он не
    # станет и здесь. Тронуть его apt ВПРАВЕ и
    # иногда трогает, но это его выбор, а не обязанность: нецелевые пакеты он
    # предпочитает оставлять как есть.
    # Вторая: --no-remove прерывает транзакцию при ЛЮБОМ удалении в плане, а не
    # только при удалении защищаемого. Решение вида "снести мешающий пакет и
    # поставить группу" будет отвергнуто целиком.
    # Поэтому ступень 2 сохранена, а окончательный вердикт выносит сверка всего
    # набора. Флаг всё равно нужен: восстанавливать одно, теряя другое, нельзя.
    restore_out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove $critical_lost 2>&1)"
    restore_rc=$?
    # Формулировка осторожная намеренно: нулевой код у apt означает "делать было
    # нечего" ровно так же, как "сделано". Что пакеты на месте, решает не эта
    # строка, а ступень 2 ниже и сверка всего набора в конце.
    if [[ "$restore_rc" -eq 0 ]]; then
        log "Одна транзакция отработала без ошибок."
    elif [[ -n "$restore_out" ]]; then
        log_warn "Одной транзакцией не вышло (код $restore_rc), пробую по одному. Ответ apt: $(printf '%s' "$restore_out" | tr '\n' ' ' | tail -c 300)"
    else
        log_warn "Одной транзакцией не вышло (код $restore_rc), причём apt не выдал ни строки. Пробую по одному."
    fi

    # Ступень 2: по одному, и только для тех, кто всё ещё отсутствует.
    # Отдельный проход нужен потому, что одно имя без кандидата на установку
    # отменяет транзакцию целиком, и тогда не восстановится ничего, включая
    # пакеты, которые ставятся прекрасно. Этот урок в проекте уже оплачен:
    # cleanup_system (она определена НИЖЕ по файлу) ставит netplan.io и
    # netplan-generator по отдельности, потому что на Debian 12 второго пакета
    # нет и он валит всю транзакцию.
    for pkg in $critical_lost; do
        _pkg_installed_ok "$pkg" && continue
        restore_out="$(DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove "$pkg" 2>&1)"
        restore_rc=$?
        if [[ "$restore_rc" -eq 0 ]] && _pkg_installed_ok "$pkg"; then
            log "Восстановлен: $pkg"
        elif [[ "$restore_rc" -eq 0 ]]; then
            # apt возвращает ноль и когда решил, что делать нечего. Без этой
            # ветки журнал противоречил бы сам себе: "Восстановлен", а тремя
            # строками ниже "Отсутствуют критичные пакеты".
            log_warn "apt отчитался об успехе, но $pkg по-прежнему не установлен."
        elif [[ -n "$restore_out" ]]; then
            # В одну строку: log_msg ставит отметку времени только на первую,
            # а многострочный ответ ломает формат журнала ровно там, где его
            # потом будут разбирать.
            log_warn "Не удалось установить $pkg (код $restore_rc). Ответ apt: $(printf '%s' "$restore_out" | tr '\n' ' ' | tail -c 300)"
        else
            log_warn "Не удалось установить $pkg (код $restore_rc), причём apt не выдал ни строки: похоже, команда не запустилась вовсе."
        fi
    done

    # Сверяем ВЕСЬ набор, а не только пропавшее. Прямой путь к потере соседа
    # закрыт флагом --no-remove выше; это страховка на случай, если он
    # перестанет действовать.
    local still_lost=""
    for pkg in $critical_before; do
        _pkg_installed_ok "$pkg" || still_lost+="$pkg "
    done
    if [[ -n "$still_lost" ]]; then
        still_lost="${still_lost% }"
        log_error "НЕ ПЕРЕЗАГРУЖАЙТЕ сервер: в текущем состоянии он не загрузится."
        log_error "Отсутствуют критичные пакеты: $still_lost"
        log_error "Попробуйте поставить их ОДНОЙ командой, всеми именами сразу: sudo apt-get install $still_lost"
        log_error "Одной, а не по очереди: так apt подбирает версии сразу для всей группы."
        log_error "Без -y намеренно: если apt при этом захочет что-то УДАЛИТЬ, прочитайте список перед подтверждением. Потеря ещё одного пакета из перечисленных выше только усугубит положение."
        log_error "Если apt ответит, что мешает пакет, которого в команде нет (вида 'X : Breaks: Y' или 'X : Depends: Y'), допишите Y туда же: в Issue #223 так потребовался systemd, а его в списке выше нет."
        log_error "Если apt отказывается ставить из-за удержанных пакетов, снимите удержание: sudo apt-mark unhold <имя>"
        log_error "Если пакета больше нет в репозиториях (переименован после смены выпуска), уберите его имя из $BOOT_CRITICAL_SNAPSHOT_FILE"
        die "Останавливаюсь, пока доступ к серверу есть. Разберитесь с перечисленным и запустите установщик снова."
    fi
    log "Критичные пакеты восстановлены."
}


# _die_upgrade_failed : назвать причину неудачного обновления и остановиться.
#
# Вынесено в отдельную функцию не ради красоты. Пока разбор жил инлайном внутри
# step1_update_and_optimize, тесты могли проверять его только грепом по
# исходнику, и стороннее ревью показало, что почти любая мутация внутри
# переживала весь набор зелёной: удаление повторного замера блокировки,
# инверсия условия, потеря -s, потеря timeout. Функцию тест поднимает целиком и
# проверяет, КАКОЙ вердикт печатается при каком состоянии системы.
#
# Правило блока: причину называем по факту, а не по догадке. Прежняя редакция
# винила dpkg-lock безусловно, включая случай, когда fuser ничего не нашёл, и
# уводила разбор в сторону: в Issue #223 настоящим ответом был отказ резолвера.
_die_upgrade_failed() {
    local lock_holder apt_why apt_why_rc
    # Замер берём ЗАНОВО, а не переиспользуем сделанный до повторной попытки:
    # между ними прошли dpkg --configure -a и целый второй прогон apt, за
    # которые найденный процесс мог завершиться, а новый появиться.
    lock_holder="$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | tr -s ' ' || true)"
    if [[ -n "$lock_holder" ]]; then
        die "Обновление системы не прошло, и dpkg-lock занят процессами:${lock_holder}. Дождитесь их завершения либо выполните: systemctl stop unattended-upgrades; dpkg --configure -a - и запустите скрипт снова."
    fi
    # Холостой прогон (-s) спрашивает apt, сходится ли план. Чаще всего его
    # отказ означает зависимости, но не только: непарсимый sources.list,
    # отсутствующие списки пакетов или повреждённое состояние dpkg дадут отказ
    # ровно так же. Поэтому его ответ мы ЦИТИРУЕМ, а не толкуем.
    # timeout нужен именно здесь, на фатальном пути: боевые попытки выше идут
    # без него намеренно, а тут висеть нельзя - у пользователя может остаться
    # только эта SSH-сессия. Сам timeout есть всегда, coreutils Essential.
    apt_why="$(timeout 120 env DEBIAN_FRONTEND=noninteractive apt-get upgrade -s --with-new-pkgs 2>&1)"
    apt_why_rc=$?
    if [[ "$apt_why_rc" -eq 0 ]]; then
        die "Обновление системы не прошло, но зависимости при повторной проверке сходятся - значит причина не в них. Смотрите вывод apt на экране, в файл журнала он не пишется: чаще всего это сеть или зеркало, нехватка места на диске или в /boot, либо скрипт самого пакета."
    fi
    if [[ -n "$apt_why" ]]; then
        die "Обновление системы не прошло. Повторная проверка зависимостей ответила: $(printf '%s' "$apt_why" | tr '\n' ' ' | tail -c 400)"
    fi
    # Третий исход: проверка не прошла и при этом ничего не сказала. Заявлять
    # здесь что-либо о зависимостях нельзя - ровно так неизвестное превращается
    # в уверенный неверный диагноз.
    die "Обновление системы не прошло, и повторная проверка зависимостей тоже не ответила (код $apt_why_rc, вывода нет; код 124 означает, что она не уложилась в 120 секунд). Смотрите вывод apt на экране, в файл журнала он не пишется."
}

# _warn_kept_back : сказать вслух, что обновилось не всё.
# apt-get upgrade оставляет необновлённым пакет, которому для обновления
# потребовалось бы удаление соседа, и возвращает при этом НОЛЬ. Это осознанный
# размен (см. блок обновления шага 1), но молчать о нём нельзя: у full-upgrade
# этот исход был редким (он придерживал разве что пакеты под hold и то, что
# придерживает сама Ubuntu), а у upgrade он штатный, и без отдельной строки
# он проходил бы совсем незаметно. Предупреждение, не отказ: сервер загрузится
# в любом случае, а вот при разборе будущей жалобы этот список решает.
#
# ⚠️ Точного списка "отложено" apt в машиночитаемом виде не даёт, поэтому берём
# upgradable, а это НАДМНОЖЕСТВО: туда же попадают пакеты под удержанием и
# застрявшие на неразрешимой цепочке зависимостей. Выдавать его за более узкий
# нельзя, и сообщение ниже этого не делает.
_warn_kept_back() {
    local raw rc kept list
    raw="$(apt list --upgradable 2>/dev/null)"
    rc=$?
    # Код возврата снимаем с САМОГО apt, а не с конвейера: в конвейере он
    # достаётся от awk, если не включён pipefail, и тогда отказ apt читается как
    # "обновлять нечего". Ветка ниже решает, молчать или предупредить, поэтому
    # опираться на глобальную опцию оболочки здесь нельзя.
    if [[ "$rc" -ne 0 ]]; then
        # Отказ самой проверки нельзя превращать в благополучное молчание:
        # функция существует ради диагностируемости, и её собственный отказ
        # обязан быть слышен.
        log_warn "Не удалось получить список необновившихся пакетов (apt list вернул $rc). Посмотрите вручную: apt list --upgradable"
        return 0
    fi
    kept="$(printf '%s\n' "$raw" | awk -F/ '/\//{printf "%s ", $1}')"
    [[ -n "${kept// /}" ]] || return 0
    list="${kept% }"
    # Обрезка ЯВНАЯ, с пометкой: на сервере с месяцами накопленных обновлений
    # список уходит в тысячи символов, а молчаливое усечение рядом уже названо
    # дефектом.
    if [[ "${#list}" -gt 400 ]]; then
        list="${list:0:400}... (обрезано, полный список: apt list --upgradable)"
    fi
    log "Обновились не все пакеты, на прежних версиях остались: $list"
    log "Чаще всего это значит, что обновление такого пакета потребовало бы удалить другой, и мы этого намеренно не делаем (Issue #223), либо что выпуск ещё раскатывается поэтапно. Но перечень не исчерпывающий: сюда же попадают пакеты под удержанием и застрявшие на неразрешимых зависимостях. Если список непустой и вас это беспокоит, посмотрите причину: apt-get -s upgrade"
}

# _boot_critical_guard : снять снимок и проверить его. Обёртка нужна для тех
# точек, где до неё снимок ещё не брали, то есть для шага 2.
#
# ⚠️ Самопроверки стоят ЗДЕСЬ, до присваивания, а не внутри
# _boot_critical_snapshot, и это принципиально: die внутри подстановки команд
# завершил бы только подоболочку, скрипт продолжил бы работу с пустым снимком,
# и фатальная проверка молча превратилась бы в необязательную.
_boot_critical_guard() {
    _dpkg_usable || die "dpkg не отвечает, а без него не проверить, переживут ли перезагрузку udev и initramfs-tools (Issue #223). Выполните: dpkg --configure -a; apt-get check - и запустите установщик снова."
    _pkg_present dpkg || die "Проверить состояние пакетов не удалось (dpkg-query или awk работают не так, как ожидается). Без этого нельзя убедиться, что сервер загрузится (Issue #223)."
    local snapshot
    snapshot="$(_boot_critical_snapshot)"
    _verify_boot_critical "$snapshot"
}

# _dpkg_usable : 0, если ответам dpkg можно верить.
# Отличить "пакет не установлен" от "база dpkg сломана" по коду возврата НЕЛЬЗЯ:
# замер на Ubuntu 24.04 дал rc=1 в обоих случаях. Поэтому спрашиваем про заведомо
# установленный пакет: не нашёлся и он - значит сломан сам механизм, а не пакеты.
# Без этой проверки пустой список молча пропустил бы вопрос, а шаг 1 позже отработал
# бы уже с исправным dpkg и снёс то, о чём не спрашивали.
_dpkg_usable() {
    command -v dpkg-query >/dev/null 2>&1 || return 1
    dpkg-query -W -f='${Status}' dpkg 2>/dev/null | grep -q "ok installed"
}

# _cloud_init_removable : 0, если установленный cloud-init действительно будет удалён.
# cloud-init стоит отдельно от списка выше: его удаляют только когда он НЕ управляет
# сетью. Ответ нужен в двух местах - в самой очистке и в вопросе на шаге 0, поэтому он
# живёт здесь. Иначе согласие спрашивалось бы про один набор, а удалялся другой, то есть
# ровно та претензия, из-за которой заведён issue #213.
# 🔴 Любая НЕудача проверки означает "управляет сетью, не трогаем". Цена ошибок
# несимметрична: лишний оставленный cloud-init стоит десятков мегабайт, а удалённый по
# ошибке - потери сети после перезагрузки на удалённом сервере. Поэтому от ls по маске
# здесь отказались: он отдаёт rc=2 и когда каталога нет, и когда маска не совпала.
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
    # На Debian cloud-init пишет именно сюда, а не в основной файл.
    if [ -d /etc/network/interfaces.d ] \
       && grep -rq "cloud-init" /etc/network/interfaces.d/ 2>/dev/null; then
        return 1
    fi
    return 0
}

# _snaps_dir_readable : 0, если каталог снапов есть и читается.
# Пустой ответ _user_snaps при нечитаемом каталоге означает "не смог посмотреть", а не
# "снапов нет". Путать эти случаи нельзя: от них зависит дефолт разрушительного вопроса.
_snaps_dir_readable() {
    [ -d /var/lib/snapd/snaps ] && [ -r /var/lib/snapd/snaps ]
}

# _user_snaps : имена снапов, поставленных ПОЛЬЗОВАТЕЛЕМ, по одному в строке, БЕЗ ПОВТОРОВ.
# В каталоге лежит по файлу на КАЖДУЮ удержанную ревизию, поэтому без dedup обновлённый
# однажды снап попал бы в предупреждение несколько раз подряд.
# Базовыми считаем только те, что не несут пользовательских данных: snapd, bare и core*.
# 🔴 lxd НЕ фильтруем: LXD из снапа держит контейнеры и их данные в /var/snap/lxd, и
# назвать такой хост "терять нечего" значит молча снести их.
# ⚠️ Читаем файлы, а не вывод 'snap list': бинарь snap к этому моменту мог быть уже снесён
# прошлым прогоном, и список молча оказался бы пуст.
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

# Согласие на удаление системных пакетов (issue #213). Спрашиваем на ШАГЕ 0, где и так
# задаются остальные вопросы: дальше установка должна идти без участия человека.
# Ответ сохраняется в awgsetup_cfg.init, чтобы повторный или возобновлённый запуск не
# спрашивал заново и, главное, не считал молчание согласием.
configure_package_cleanup() {
    [[ "$NO_TWEAKS" -eq 1 ]] && return 0
    # Решение уже есть: флаг командной строки или запись из прошлого запуска.
    [[ -n "$KEEP_PACKAGES" ]] && return 0

    if ! _dpkg_usable; then
        KEEP_PACKAGES=1
        log_warn "Опросить dpkg не удалось, поэтому системные пакеты трогать не буду."
        return 0
    fi

    local installed=() pkg
    for pkg in $(_cleanup_package_list); do
        if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
            installed+=("$pkg")
        fi
    done
    # cloud-init удаляется отдельной веткой очистки и только когда не управляет сетью,
    # поэтому в список берём его по тому же условию: спросить надо ровно про то, что
    # реально удалят.
    if _cloud_init_removable; then
        installed+=("cloud-init")
    fi

    # Каталоги снапов сносит отдельный rm -rf, и он НЕ зависит от того, попал ли snapd
    # в список выше: пакет мог остаться в состоянии 'deinstall ok config-files'.
    local snap_dirs=0
    if [[ "${OS_ID:-}" == "ubuntu" ]] && { [ -d /snap ] || [ -d /var/snap ]; }; then
        snap_dirs=1
    fi

    if [ ${#installed[@]} -eq 0 ] && [ "$snap_dirs" -eq 0 ]; then
        KEEP_PACKAGES=0
        return 0
    fi

    # Свои снапы ищем только когда им что-то грозит: на Debian snapd в список не входит.
    local snaps="" snaps_unknown=0
    if [ "$snap_dirs" -eq 1 ] || [[ " ${installed[*]} " == *" snapd "* ]]; then
        if _snaps_dir_readable; then
            snaps="$(_user_snaps | tr '\n' ' ')"; snaps="${snaps% }"
        else
            snaps_unknown=1
        fi
    fi

    log_warn "Сервер настраивается как однозадачный, поэтому будут удалены пакеты:"
    [ ${#installed[@]} -gt 0 ] && log_warn "  ${installed[*]}"
    if [ "$snap_dirs" -eq 1 ]; then
        log_warn "  Плюс каталоги /snap, /var/snap и /var/lib/snapd со всеми снапами и их данными."
        if [ "$snaps_unknown" -eq 1 ]; then
            log_warn "  Что именно у вас установлено, проверить не удалось: каталог снапов недоступен."
        elif [[ -n "$snaps" ]]; then
            log_warn "  Ваши снапы, которые будут потеряны: $snaps"
        fi
    fi
    if [[ " ${installed[*]} " == *" cloud-init "* ]]; then
        log_warn "  Вместе с cloud-init удаляются каталоги /etc/cloud и /var/lib/cloud."
    fi

    if [[ "$AUTO_YES" -eq 1 ]]; then
        KEEP_PACKAGES=0
        log "Удаление подтверждено автоматически (--yes). Сохранить пакеты: --keep-packages."
        return 0
    fi

    # Есть что терять - удаляем ТОЛЬКО по явному "да" (allowlist, как у остальных
    # разрушительных вопросов скрипта). Прежний вариант проверял ответ на букву n, и
    # тогда "нет", "не", "ok" и любая случайная клавиша означали УДАЛИТЬ.
    local risky=0
    if [[ -n "$snaps" ]] || [ "$snaps_unknown" -eq 1 ]; then risky=1; fi

    local answer="" hint="[Y/n]"
    [ "$risky" -eq 1 ] && hint="[y/N]"
    if ! read -rp "Удалить эти пакеты? $hint: " answer < /dev/tty; then
        KEEP_PACKAGES=1
        log_warn "Терминал недоступен, вопрос задать не смог - пакеты сохраняю."
        return 0
    fi
    # Обрезаем пробелы и CR: ответ из putty приходит с \r.
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
        log "Пакеты сохраняются. Фаервол, Fail2Ban и оптимизация при этом остаются."
    fi
    return 0
}

# Удаление ненужных пакетов и сервисов
cleanup_system() {
    log "Очистка системы от ненужных компонентов..."

    # Снимок default route ДО очистки - для проверки что мы не сломали сеть.
    # Issue #84: на чистой Ubuntu 26.04 server (subiquity, без cloud-init
    # netplan-маркеров) apt-get autoremove после purge cloud-init сносил
    # netplan-generator как transitive dep, и сервер терял IP после reboot.
    local pre_default_route
    pre_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    log_debug "Pre-cleanup default route: ${pre_default_route:-<none>}"

    # apt-mark hold на критичные пакеты сетевого стека: защита от случайного
    # удаления через transitive deps. Покрываем оба варианта именования netplan
    # (netplan.io на 24.04, netplan-generator на 25.10/26.04), а также
    # systemd-resolved и netcfg/ifupdown legacy. Пакета systemd-networkd
    # отдельно не существует - бинарь живёт внутри systemd, hold-ить нечего.
    # Перед hold снимаем снимок текущих hold-ов пользователя, чтобы при unhold
    # не затереть его pre-existing holds (например на linux-image-*).
    local _hold_pkgs="netplan.io netplan-generator systemd-resolved netcfg ifupdown"
    local _preexisting_holds=""
    _preexisting_holds="$(apt-mark showhold 2>/dev/null || true)"
    local _held_actual=()
    local _hpkg
    for _hpkg in $_hold_pkgs; do
        if dpkg-query -W -f='${Status}' "$_hpkg" 2>/dev/null | grep -q "ok installed"; then
            # Пропускаем уже залоченные пользователем - их hold не наш и снимать его нельзя.
            if grep -qxF "$_hpkg" <<<"$_preexisting_holds"; then
                continue
            fi
            apt-mark hold "$_hpkg" >/dev/null 2>&1 && _held_actual+=("$_hpkg")
        fi
    done
    [ ${#_held_actual[@]} -gt 0 ] && log_debug "Apt-mark hold: ${_held_actual[*]}"

    # Пакеты для удаления (безопасные для VPS)
    # snapd и lxd-agent-loader — только на Ubuntu, на Debian их нет
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
        log "Удаление: ${packages_to_remove[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${packages_to_remove[@]}" || log_warn "Ошибка удаления некоторых пакетов"
    fi

    # Очистка snap артефактов (только Ubuntu)
    if [[ "${OS_ID:-}" == "ubuntu" && -d /snap ]]; then
        log "Очистка snap артефактов..."
        rm -rf /snap /var/snap /var/lib/snapd 2>/dev/null || log_warn "Ошибка очистки snap"
    fi

    # cloud-init: удалять только если НЕ управляет сетью
    # Консервативный подход: сначала проверяем маркеры cloud-init, затем renderer
    if dpkg-query -W -f='${Status}' cloud-init 2>/dev/null | grep -q "ok installed"; then
        if _cloud_init_removable; then
            log "Удаление cloud-init (сеть не зависит от него)..."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y cloud-init 2>/dev/null || log_warn "Ошибка удаления cloud-init"
            rm -rf /etc/cloud /var/lib/cloud 2>/dev/null
        else
            log_warn "cloud-init управляет сетью — пропускаем удаление."
        fi
    fi

    # apt-get autoremove убран (был источник Issue #84 на Ubuntu 26.04 ISO):
    # autoremove зачищал netplan-generator как transitive dep cloud-init.
    # Орфанные пакеты после purge займут ~50-200 МБ - приемлемо ради стабильности.
    # Пользователь может вручную: apt-get autoremove --no-install-recommends.

    # Снимаем hold, чтобы не оставлять "застывшие" пакеты в состоянии hold.
    local _upkg
    for _upkg in "${_held_actual[@]}"; do
        apt-mark unhold "$_upkg" >/dev/null 2>&1 || true
    done

    # Проверка что default route не пропал. Если пропал - пробуем восстановить.
    # Восстанавливаем netplan.io безусловно (есть на всех supported distro),
    # netplan-generator - только если он реально доступен в архивах данной
    # системы (на Debian 12 этого пакета ещё нет, apt-get install <missing>
    # абортит транзакцию даже с || true для всей строки).
    local post_default_route
    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
    if [[ -n "$pre_default_route" && -z "$post_default_route" ]]; then
        log_error "Маршрут по умолчанию потерян после очистки. Попытка восстановления..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            netplan.io 2>/dev/null || true
        if apt-cache show netplan-generator &>/dev/null; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
                netplan-generator 2>/dev/null || true
        fi
        systemctl restart systemd-networkd 2>/dev/null || true
        netplan apply 2>/dev/null || true
        # Цикл ожидания маршрута: до ~26 секунд, проверка раз в 1-5 секунд.
        # Фиксированные sleep не годятся - время появления DHCP-маршрута
        # на медленных VM непредсказуемо.
        local _wait
        for _wait in 1 2 3 5 5 5 5; do
            post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
            [[ -n "$post_default_route" ]] && break
            sleep "$_wait"
        done
        # Last-ditch: поднять интерфейс из pre_default_route. Сначала пробуем
        # networkctl renew (для systemd-networkd-managed link), если маршрут не
        # появился - переходим на dhclient (для ifupdown-managed link).
        if [[ -z "$post_default_route" ]]; then
            local _iface
            _iface="$(awk '{for (i=1; i<=NF; i++) if ($i == "dev") { print $(i+1); exit } }' <<<"$pre_default_route")"
            if [[ -n "$_iface" ]]; then
                log_warn "Финальная попытка поднять интерфейс $_iface..."
                ip link set "$_iface" up 2>/dev/null || true
                if command -v networkctl &>/dev/null; then
                    networkctl renew "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
                # Если networkctl не привёл маршрут к жизни (или его нет) - dhclient.
                if [[ -z "$post_default_route" ]] && command -v dhclient &>/dev/null; then
                    dhclient -4 "$_iface" 2>/dev/null || true
                    sleep 3
                    post_default_route="$(ip -4 route show default 2>/dev/null | head -1 || true)"
                fi
            fi
        fi
        if [[ -z "$post_default_route" ]]; then
            die "Сеть не восстановилась после cleanup_system. Восстановите её с консоли (например: sudo dhclient -4 <интерфейс>) и перезапустите установщик с флагом --no-tweaks."
        fi
        log_warn "Сеть восстановлена: $post_default_route"
    fi

    log "Очистка системы завершена."
}

# Настройка swap
optimize_swap() {
    log "Оптимизация swap..."
    local target_swap_mb

    if [[ $TOTAL_RAM_MB -le 2048 ]]; then
        target_swap_mb=1024
    else
        target_swap_mb=512
    fi

    # Проверяем текущий swap
    local current_swap_mb
    current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')

    if [[ $current_swap_mb -ge $target_swap_mb ]]; then
        log "Swap уже достаточен: ${current_swap_mb}MB (цель: ${target_swap_mb}MB)"
    else
        log "Создание swap файла: ${target_swap_mb}MB"
        # Отключаем существующий swap файл если есть
        if [[ -f /swapfile ]]; then
            swapoff /swapfile 2>/dev/null
            rm -f /swapfile
        fi
        dd if=/dev/zero of=/swapfile bs=1M count="$target_swap_mb" status=none 2>/dev/null || {
            log_warn "Ошибка создания swap файла"
            return 1
        }
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || { log_warn "Ошибка mkswap"; return 1; }
        swapon /swapfile || { log_warn "Ошибка swapon"; return 1; }
        # Добавляем в fstab если отсутствует. Точная проверка по полям:
        # игнорируем закомментированные строки и partial matches (например,
        # `/swapfile.bak` или старая строка в комментарии).
        if ! awk '!/^[[:space:]]*#/ && $1 == "/swapfile" && $3 == "swap" {found=1} END {exit !(found+0)}' \
             /etc/fstab; then
            # Гарантируем перевод строки в конце файла. Без него запись
            # приклеится к последней строке fstab, и та станет некорректной:
            # получится одна строка из 11 полей вместо шести. Подстановка
            # команды срезает завершающие переводы строки, поэтому у
            # нормально завершённого файла проверка даёт пустую строку и
            # лишний перевод НЕ добавляется.
            if [[ -s /etc/fstab && -n "$(tail -c1 /etc/fstab)" ]]; then
                echo >> /etc/fstab
            fi
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        fi
        log "Swap файл создан: ${target_swap_mb}MB"
    fi

    # Настройка swappiness
    sysctl -w vm.swappiness=10 >/dev/null 2>&1
}

# Оптимизация сетевого интерфейса
optimize_nic() {
    if [[ -z "$MAIN_NIC" ]]; then
        log_warn "Основной NIC не определён, пропуск оптимизации."
        return 1
    fi

    if ! command -v ethtool &>/dev/null; then
        log_debug "ethtool не найден, пропуск NIC оптимизации."
        return 0
    fi

    log "Оптимизация NIC: $MAIN_NIC"
    # Отключение GRO/GSO/TSO — могут мешать VPN-трафику
    ethtool -K "$MAIN_NIC" gro off 2>/dev/null || log_debug "GRO: не поддерживается/уже выкл."
    ethtool -K "$MAIN_NIC" gso off 2>/dev/null || log_debug "GSO: не поддерживается/уже выкл."
    ethtool -K "$MAIN_NIC" tso off 2>/dev/null || log_debug "TSO: не поддерживается/уже выкл."
    log "NIC оптимизация завершена."
}

# Полная оптимизация системы
optimize_system() {
    log "Оптимизация системы под VPN-сервер..."
    detect_hardware
    optimize_swap
    optimize_nic
    log "Оптимизация системы завершена."
}

# ==============================================================================
# Настройка sysctl (минимальная, для --no-tweaks)
# ==============================================================================

setup_minimal_sysctl() {
    log "Настройка минимального sysctl (--no-tweaks)..."
    local f="/etc/sysctl.d/99-amneziawg-forwarding.conf"
    cat > "$f" << SYSEOF
# AmneziaWG — минимальные настройки (--no-tweaks)
net.ipv4.ip_forward = 1
# PMTU black-hole detection — критично для VPN-туннелей за мобильным
# оператором/NAT'ом, который фильтрует ICMP "needs-frag". Без этого
# большие TCP-сегменты молча теряются, тяжёлые сайты не открываются.
# Значение 1 активирует адаптивный MSS-пробинг только при детекте black-hole,
# безопасно в любом режиме — оставляем даже в --no-tweaks.
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
    sysctl -p "$f" >/dev/null 2>&1 || log_warn "Ошибка sysctl -p"
    log "Минимальный sysctl настроен."
}

# ==============================================================================
# Настройка sysctl (расширенная)
# ==============================================================================

setup_advanced_sysctl() {
    log "Настройка sysctl..."
    local f="/etc/sysctl.d/99-amneziawg-security.conf"

    # Адаптивные буферы и conntrack по объёму RAM.
    # conntrack_max: каждая запись ~300 байт, 256K ≈ 80 MB RAM. Прежний потолок
    # 65536 становился узким на exit-нодах с каскадом + WARP bypass (много
    # одновременных потоков — YouTube-CDN сам даёт десятки параллельных).
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
# Автоматически сгенерировано install_amneziawg.sh v${SCRIPT_VERSION}

# --- IP Forwarding ---
net.ipv4.ip_forward = 1
$(if [[ "${DISABLE_IPV6:-1}" -eq 1 ]]; then
    echo "net.ipv6.conf.all.disable_ipv6 = 1"
    echo "net.ipv6.conf.default.disable_ipv6 = 1"
    echo "net.ipv6.conf.lo.disable_ipv6 = 1"
else
    echo "# IPv6 не отключен"
    echo "net.ipv6.conf.all.forwarding = 1"
fi)

# --- TCP/IP Hardening ---
# rp_filter = 2 (loose mode): проверяет source IP по ANY маршруту в таблице,
# а не по обратному маршруту через тот же интерфейс. Strict mode (=1) ломает
# routing на облачных хостерах (Hetzner и подобных) где шлюз в другой подсети,
# чем IP самой VPS — ответные пакеты не проходят strict reverse path check.
# Loose mode безопасен: подделанные source IP всё равно отсеиваются если для
# них нет маршрута вообще. Discussion #41 (z036).
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
# Явные per-socket TCP-буферы (min default max) масштабируются под rmem_max/
# wmem_max. Без этого отдельные сокеты не раскручиваются до полного max'а.
net.ipv4.tcp_rmem = 4096 87380 ${rmem_max}
net.ipv4.tcp_wmem = 4096 65536 ${wmem_max}

# PMTU black-hole detection: если ICMP "needs-frag" фильтруется где-то по
# пути (типично для мобильных операторов, туннельных стыков, WARP-bypass),
# классический Path MTU Discovery молча ломается → большие TCP-сегменты
# теряются → сайты «висят». Значение 1 включает адаптивный MSS-пробинг
# ТОЛЬКО при детекте black-hole (не каждый пакет), это безопасно всегда.
# Решает класс проблем «YouTube/heavy-сайты грузятся через каскад криво».
net.ipv4.tcp_mtu_probing = 1

# Не скатываться в slow-start после idle: для long-lived VPN-потоков
# (постоянные соединения) держим congestion window между активными фазами,
# нет просадки скорости при возобновлении.
net.ipv4.tcp_slow_start_after_idle = 0

# Реюз TIME_WAIT-сокетов для исходящих соединений. Безопасно на современных
# ядрах (RFC 6191 timestamp-based validation); полезно на exit-нодах с
# большим количеством egress-flows через WARP или прямой NIC.
net.ipv4.tcp_tw_reuse = 1

# --- Conntrack (adaptive) ---
# ~256K flow entries (≈80 MB RAM) на 2+ GB VPS, 128K на меньших.
# Каскад + WARP-bypass создают сотни одновременных TCP/UDP-потоков,
# прежний потолок 65536 заполнялся под нагрузкой и новые соединения
# начинали дропаться.
net.netfilter.nf_conntrack_max = ${conntrack_max}

# --- Security ---
vm.swappiness = 10
kernel.sysrq = 0

# Подавление kernel warning/notice messages в VNC-консоли хостера.
# Без этого fail2ban UFW-блокировки спамят VNC окно строками типа
# "[UFW BLOCK]" и делают консоль непригодной для работы.
# Format: console_loglevel default_msg_loglevel min_console_loglevel default_console_loglevel
# Значение 3 = KERN_ERR — на консоль идут только ошибки и критические.
# Discussion #41 (z036).
kernel.printk = 3 4 1 3
EOF

    log "Применение sysctl..."
    if ! sysctl -p "$f" >/dev/null 2>&1; then
        # nf_conntrack может быть недоступен до загрузки модуля
        log_warn "Некоторые параметры sysctl не применились (nf_conntrack будет доступен позже)."
        sysctl -p "$f" 2>/dev/null || true
    fi
}

# ==============================================================================
# Фаервол и безопасность
# ==============================================================================

# Определение реального SSH-порта(ов) для корректного правила UFW.
# Без этого ufw limit 22/tcp + default deny incoming отрезает доступ к серверу
# после ufw enable, если SSH поднят на нестандартном порту (Issue #91).
# Функция самодостаточна: вызывается на шаге 4, ДО подключения awg_common.sh.
# Источники:
#   1. CLI_SSH_PORT (--ssh-port=, ручной override, список через запятую) - авторитетно
#   иначе ОБЪЕДИНЕНИЕ (union, не fallback - так не пропустим реальный порт):
#   2. sshd -T   (эффективный конфиг: `Port` И `ListenAddress host:port`, учитывает drop-ins)
#   3. ss -tlnp  (реальные listening-сокеты sshd: ground truth для ListenAddress)
#   4. /etc/ssh/sshd_config + sshd_config.d/*.conf (парсинг, только если 2-3 пусты)
#   5. 22 (дефолт, если ничего не найдено)
# Выводит уникальные валидные порты (1-65535) через пробел в stdout.
# ВАЖНО: внутри только log_warn/log_error (stderr); log() пишет в stdout и
# испортил бы перехват $(detect_ssh_ports).
detect_ssh_ports() {
    local ports="" p pp valid=""
    # awk: достаёт порт из строк `port N` и `listenaddress host:port`
    # (IPv4 и [IPv6]); голый адрес без порта пропускается.
    local awk_ports='tolower($1)=="port"&&$2~/^[0-9]+$/{print $2} tolower($1)=="listenaddress"{v=$2; if(v~/\]:[0-9]+$/){sub(/.*\]:/,"",v); print v} else if(v~/^[0-9.]+:[0-9]+$/){sub(/.*:/,"",v); print v}}'

    if [[ -n "$CLI_SSH_PORT" ]]; then
        # 1. Ручной override - авторитетный источник
        ports="${CLI_SSH_PORT//,/ }"
    else
        # 2. sshd -T: эффективная конфигурация (Port + ListenAddress, drop-ins)
        if command -v sshd &>/dev/null; then
            ports+=" $(sshd -T 2>/dev/null | awk "$awk_ports" | tr '\n' ' ')"
        fi
        # 3. ss: реальные listening-сокеты sshd. Объединяем, не fallback -
        #    ловит ListenAddress-порт, даже если sshd -T печатает дефолтный port 22.
        if command -v ss &>/dev/null; then
            ports+=" $(ss -H -tlnp 2>/dev/null | awk '/"sshd"/{n=split($4,a,":"); print a[n]}' | tr '\n' ' ')"
        fi
        # 4. Парсинг конфигов - только если sshd -T и ss ничего не дали
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

    # Валидация (десятичная 1-65535, 10# против octal) + дедуп с сохранением порядка
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

    # 5. Дефолт, если детект ничего валидного не дал
    if [[ -z "$valid" ]]; then
        [[ -n "$CLI_SSH_PORT" ]] && log_warn "--ssh-port не содержит валидных портов, использую 22."
        valid="22"
    fi
    printf '%s' "$valid"
}

setup_improved_firewall() {
    log "Настройка UFW..."
    if ! command -v ufw &>/dev/null; then install_packages ufw; fi

    # Определяем основной сетевой интерфейс для правила маршрутизации
    local main_nic
    main_nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
    if [[ -z "$main_nic" ]]; then
        log_warn "Не удалось определить сетевой интерфейс для UFW route."
    fi

    # Определяем реальный SSH-порт(ы), чтобы не отрезать доступ при нестандартном порту (Issue #91)
    local ssh_ports _sp
    ssh_ports=$(detect_ssh_ports)
    log "SSH-порт(ы) для правила UFW: ${ssh_ports}"

    local ufw_errors=0
    # Старый UDP-порт и old awg0→main route здесь не удаляем: прежний awg0
    # ещё может понадобиться EXIT rollback. Оба cleanup выполняются в step7.
    if ufw status 2>/dev/null | grep -q inactive; then
        log "UFW неактивен. Настройка..."
        ufw default deny incoming  || { log_warn "UFW: ошибка default deny incoming"; ufw_errors=1; }
        ufw default allow outgoing || { log_warn "UFW: ошибка default allow outgoing"; ufw_errors=1; }
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: ошибка limit SSH (порт ${_sp})"; ufw_errors=1; }
        done
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: ошибка allow VPN port"; ufw_errors=1; }
        if [[ -n "$main_nic" ]] && ufw_main_route_required; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: ошибка route rule"; ufw_errors=1; }
            log "Правило маршрутизации VPN добавлено (awg0 → ${main_nic})."
        fi
        if [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
            ufw route allow in on awg0 out on "${AWG_WARP_IFACE:-wgcf}" comment "AmneziaWG→WARP egress" \
                || { log_warn "UFW: ошибка route awg0→${AWG_WARP_IFACE:-wgcf}"; ufw_errors=1; }
            log "Правило маршрутизации WARP добавлено (awg0 → ${AWG_WARP_IFACE:-wgcf})."
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "Одна или несколько правил UFW не применились. Проверьте настройки вручную."
            return 1
        fi
        log "Правила UFW добавлены."
        log_warn "--- ВКЛЮЧЕНИЕ UFW ---"
        log_warn "UFW разрешит SSH ТОЛЬКО на порту(ах): ${ssh_ports}. Убедитесь, что подключаетесь по нему."
        if [[ "$ssh_ports" != "22" ]]; then
            log_warn "ВНИМАНИЕ: SSH на нестандартном порту. Если порт определён неверно - доступ к серверу пропадёт."
            log_warn "Override при необходимости: --ssh-port=ПОРТ"
        fi
        local confirm_ufw="y"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            sleep 5
            read -rp "Включить UFW? [y/N]: " confirm_ufw < /dev/tty
        else
            log "Автоматическое включение UFW (--yes)."
        fi
        if ! [[ "$confirm_ufw" =~ ^[[:space:]]*[Yy]([Ee][Ss])?[[:space:]]*$ ]]; then
            log_warn "UFW настроен, но не активирован по вашему выбору."
            log_warn "Сервер работает БЕЗ фаервола. Включить позже: sudo ufw enable"
            return 0
        fi
        if ! ufw --force enable; then die "Ошибка включения UFW."; fi
        log "UFW включен."
        # Маркер: UFW был включён нашим установщиком (а не пользователем заранее).
        # Используется в step_uninstall чтобы решить, безопасно ли отключать UFW.
        # Защита от destructive uninstall на VPS где UFW использовался для SSH/web
        # hardening ДО установки нашего скрипта (audit).
        touch "$AWG_DIR/.ufw_enabled_by_installer" 2>/dev/null || \
            log_warn "Не удалось создать UFW marker — uninstall не сможет отключить UFW автоматически."
    else
        log "UFW активен. Обновление правил..."
        for _sp in $ssh_ports; do
            ufw limit "${_sp}/tcp" comment "SSH Rate Limit" || { log_warn "UFW: ошибка limit SSH (порт ${_sp})"; ufw_errors=1; }
        done
        ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || { log_warn "UFW: ошибка allow VPN port"; ufw_errors=1; }
        if [[ -n "$main_nic" ]] && ufw_main_route_required; then
            ufw route allow in on awg0 out on "$main_nic" comment "AmneziaWG Routing" \
                || { log_warn "UFW: ошибка route rule"; ufw_errors=1; }
        fi
        if [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
            ufw route allow in on awg0 out on "${AWG_WARP_IFACE:-wgcf}" comment "AmneziaWG→WARP egress" \
                || { log_warn "UFW: ошибка route awg0→${AWG_WARP_IFACE:-wgcf}"; ufw_errors=1; }
        fi
        if [[ "$ufw_errors" -ne 0 ]]; then
            log_error "Одна или несколько правил UFW не применились. Проверьте настройки вручную."
            return 1
        fi
        ufw reload || log_warn "Ошибка перезагрузки UFW."
        log "Правила обновлены."
    fi
    log "UFW настроен."
    log "$(ufw status verbose 2>&1)"
    return 0
}

secure_files() {
    log "Установка безопасных прав доступа..."
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
    log "Права доступа установлены."
}

setup_fail2ban() {
    log "Настройка Fail2Ban..."
    if ! command -v fail2ban-client &>/dev/null; then
        install_packages fail2ban
        # Маркер: пакет fail2ban доустановлен нашим установщиком (а не стоял
        # до него). step_uninstall выполняет purge fail2ban только при наличии
        # маркера, чтобы не снести SSH-защиту, настроенную пользователем заранее
        # (симметрично .ufw_enabled_by_installer).
        if command -v fail2ban-client &>/dev/null; then
            touch "$AWG_DIR/.fail2ban_installed_by_installer" 2>/dev/null || \
                log_warn "Не удалось создать fail2ban marker - uninstall не будет удалять пакет fail2ban."
        fi
    fi
    if ! command -v fail2ban-client &>/dev/null; then
        log_warn "Fail2ban не установлен, пропускаем."
        return 1
    fi

    # banaction=ufw действует только при активном UFW: если на шаге 4
    # пользователь отказался включать UFW, баны добавляются в неактивный
    # набор правил и фактически не работают (fail2ban при этом "зелёный").
    if ufw status 2>/dev/null | grep -q inactive; then
        log_warn "UFW не активен: fail2ban-баны (banaction=ufw) не действуют, пока UFW выключен. Включить: sudo ufw enable"
    fi

    # Debian: journald вместо rsyslog, нужен python3-systemd
    if [[ "${OS_ID:-}" == "debian" ]]; then
        install_packages python3-systemd
    fi

    mkdir -p /etc/fail2ban/jail.d 2>/dev/null

    # Backend: systemd для Debian и Ubuntu (нет rsyslog)
    local f2b_backend="systemd"

    cat > /etc/fail2ban/jail.d/amneziawg.conf << JAILEOF || { log_warn "Ошибка записи jail.d/amneziawg.conf"; return 1; }
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
    # Одну секунду, сервис перезапускается...
    sleep 1

    if systemctl is-active --quiet fail2ban; then
        log "Fail2Ban настроен и перезапущен."
    else
        log_warn "Ошибка перезапуска fail2ban"
    fi
    return 0
}

# ==============================================================================
# Проверка статуса сервиса
# ==============================================================================

check_service_status() {
    log "Проверка статуса сервиса..."
    local ok=1

    if systemctl is-failed --quiet awg-quick@awg0; then
        log_error "Сервис FAILED!"
        ok=0
    fi

    if ! systemctl is-active --quiet awg-quick@awg0; then
        log_error "Сервис awg-quick@awg0 не active!"
        ok=0
    fi

    if ! ip link show up dev awg0 &>/dev/null; then
        log_error "Интерфейс awg0 не найден или не UP!"
        ok=0
    fi

    if ! awg show 2>/dev/null | grep -q "interface: awg0"; then
        log_error "awg show не видит интерфейс!"
        ok=0
    fi

    # Проверка порта
    local port_check=${AWG_PORT:-0}
    if [[ "$port_check" -eq 0 ]] && [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        port_check=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
        port_check=${port_check:-0}
    fi
    if [[ "$port_check" -ne 0 ]]; then
        if ! ss -lunp | grep -q ":${port_check} "; then
            log_error "Порт $port_check/udp не прослушивается!"
            ok=0
        fi
    fi

    # Проверка AWG 2.0 параметров
    if awg show awg0 2>/dev/null | grep -q "jc:"; then
        log "AWG 2.0 параметры активны."
    else
        log_warn "AWG 2.0 параметры не обнаружены в awg show."
    fi

    if [[ "$ok" -eq 1 ]]; then
        log "Статус сервиса и интерфейса OK."
        return 0
    else
        return 1
    fi
}

# ==============================================================================
# Диагностика
# ==============================================================================

# Отчёт собирают для вставки в ПУБЛИЧНЫЙ issue: наш же шаблон бага просит приложить
# его содержимое. Значения ключей вырезает одна общая функция, а не отдельная
# маскировка в каждой секции: секции со временем добавляются, и разовая маскировка
# внутри одной из них расходится с остальными. Именно так PresharedKey и оказался в
# отчёте открытым, пока в соседней строке маскировался PrivateKey.
# Применяется в ДВУХ точках (одна реализация, не два источника правды): на выходе
# всего отчёта и отдельно к серверному конфигу.
# ВАЖНО: второй рубеж закрывает ТОЛЬКО серверный конфиг. Вывод awg show и журнал
# через него не проходят, так что при отвязанном внешнем конвейере утекут именно они.
# ВАЖНО: маскировка AWG_ENDPOINT ниже по функции - осознанное исключение из правила
# "одна функция": она прячет адрес, а не ключ, и живёт своей строкой.
#
# Выражения КОНТЕКСТНЫЕ. Безъякорная редакция резала значение всюду, где встречалось
# имя ключа, и портила чужие поля: имя сервера - свободный текст, где разрешены
# пробелы и знак равенства, поэтому строка вида AWG_SERVER_NAME с текстом
# "PrivateKey = Office" внутри теряла и значение, и закрывающую кавычку. Имена
# клиентов от этого защищены валидацией ^[a-zA-Z0-9_-]+$ (она живёт в
# manage_amneziawg.sh и awg_common.sh, не здесь), но правленный руками #_Name может
# содержать что угодно.
#
# Четыре контекста:
#   1. строка конфигурации В НАЧАЛЕ СТРОКИ, с необязательным символом комментария.
#      Он нужен НЕ потому, что awg разберёт такую строку: он её как раз отбрасывает
#      целиком (config_read_line обрезает всё от первой решётки ДО разбора). Нужен
#      потому, что значение физически лежит в файле, который вставят в публичный
#      issue. Маскируем ДО КОНЦА СТРОКИ: разбор вычищает пробелы перед разбором,
#      поэтому запись вида "PrivateKey = AA BB=" валидна, и обрезка по первому
#      пробелу оставила бы хвост ключа в отчёте.
#   2. метка вывода awg show в начале строки. HeaderProtectionKey здесь обязателен:
#      awg show печатает его ОТКРЫТЫМ ТЕКСТОМ (show.c: key() вместо masked_key()),
#      в отличие от приватного и общего ключей, которые прячет сам. Заодно снимается
#      вопрос про WG_HIDE_KEYS=never.
#   3. "Line unrecognized: ..." - без якоря. awg печатает в stderr строку УЖЕ
#      ОЧИЩЕННУЮ (обрезана по решётке, пробелы удалены) и обёрнутую в обратный
#      апостроф с закрывающей кавычкой. Отсюда ".?" в выражении: он пропускает этот
#      апостроф. НЕ УДАЛЯТЬ ".?": без него настоящая строка не совпадает вовсе.
#      Ветка error срабатывает на ЛЮБОЙ неопознанной строке: опечатка в имени ключа,
#      ключ не в своей секции (PrivateKey внутри [Peer] уедет в stderr целиком),
#      ключ чужой реализации. Дописанный руками параметр третьей линии - лишь один
#      из случаев, а не единственный.
#   4. "Key is not the correct length or format: ..." - то же место, но имени ключа
#      в сообщении НЕТ вовсе, поэтому по имени его не поймать.
# ВАЖНО: якоря у 1 и 2 означают, что эти формы НЕ ловятся в секции Service Status,
# где systemctl status добавляет свой префикс со штампом времени. Журнальная секция
# этим не страдает: journalctl вызывается там с --output=cat, то есть без префикса.
# Регистронезависимость (флаг I) - разбор конфига тоже регистронезависим (strncasecmp).
#
# ЧЕТЫРЕ СТРОКОВЫХ ЛИТЕРАЛА UPSTREAM, на которых всё держится: "private key:",
# "header protection key:", "Line unrecognized:", "Key is not the correct length or
# format:". Сверены с amneziawg-tools ee0f0a9 (src/config.c, src/show.c) 25 aug 2026.
# Переформулируют любой - фильтр молча перестанет совпадать, а тесты останутся
# зелёными, потому что зашивают те же строки. ПЕРЕСВЕРЯТЬ при обновлении tools.
_mask_report_secrets() {
    sed -E \
        -e 's/^([[:space:]]*#?[[:space:]]*(PrivateKey|PresharedKey|HeaderProtectionKey)[[:space:]]*=[[:space:]]*).*/\1[HIDDEN]/I' \
        -e 's/^([[:space:]]*(private key|preshared key|header protection key)[[:space:]]*:[[:space:]]*).*/\1(hidden)/I' \
        -e 's/(Line unrecognized:[[:space:]]*.?(PrivateKey|PresharedKey|HeaderProtectionKey)[[:space:]]*=[[:space:]]*).*/\1[HIDDEN]/I' \
        -e 's/(Key is not the correct length or format:[[:space:]]*).*/\1[HIDDEN]/I'
}

create_diagnostic_report() {
    # --diagnostic вызывается ДО initialize_setup (где живёт основной root-check):
    # под обычным пользователем запись в /root/awg падает на каждом log_msg,
    # отчёт не создаётся, а exit 0 выглядел бы как ложный успех.
    if [ "$(id -u)" -ne 0 ]; then die "Запустите скрипт от root (sudo bash $0 --diagnostic)."; fi
    log "Создание диагностики..."
    local rf _diag_umask
    rf="$AWG_DIR/diag_$(date +%F_%T).txt"
    # Файл создаётся редиректом ДО chmod, поэтому режим на момент создания задаёт
    # umask. Тот же приём, что для ключей в awg_common.sh: сузить права сразу, а не
    # чинить после. --diagnostic отрабатывает ДО secure_files, поэтому /root/awg
    # может быть создан с правами по умолчанию, и окно 0644 реально достижимо.
    _diag_umask=$(umask); umask 077
    {
        echo "=== AMNEZIAWG 2.0 DIAGNOSTIC REPORT ==="
        echo ""
        echo "!!! ВНИМАНИЕ: значения PrivateKey, PresharedKey и HeaderProtectionKey"
        echo "!!! вырезаны везде, где они подписаны своим именем или меткой awg show."
        echo "!!! В отчёте остаются: IP-адреса, порты, маршруты, параметры обфускации,"
        echo "!!! имена и публичные ключи клиентов. Адрес сервера дополнительно скрыт."
        echo "!!! Перед публикацией в issue проверьте, что из этого вы не хотите раскрывать."
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
        # Второй рубеж ТОЙ ЖЕ функцией: одна реализация, две точки применения.
        # Дубля правды это не создаёт, а если внешний фильтр когда-нибудь отвяжут
        # от блока, самый опасный сырой ввод останется прикрытым.
        if [[ -f "$SERVER_CONF_FILE" ]]; then
            _mask_report_secrets < "$SERVER_CONF_FILE" || echo "ОШИБКА: не удалось прочитать или отфильтровать $SERVER_CONF_FILE"
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
        # Каскад (CASCADE.md) живёт вне awg0.conf: своя таблица, метка, ipset и правила mangle.
        # Без этого блока по отчёту нельзя понять, применено деление или нет (issue #212).
        if [ -f "$AWG_DIR/awg-routing.sh" ] || ip link show awg1 &>/dev/null; then
            # is-active печатает "inactive" И возвращает ненулевой код, поэтому подстановка
            # вида $(... || echo N/A) выдала бы ОБЕ строки сразу. Берём вывод, N/A - только на пустом.
            local _casc_active _casc_enabled _casc_out
            _casc_active=$(systemctl is-active awg-routing 2>/dev/null || true)
            _casc_enabled=$(systemctl is-enabled awg-routing 2>/dev/null || true)
            echo "unit awg-routing: active=${_casc_active:-N/A}, enabled=${_casc_enabled:-N/A}"
            # Ниже намеренно разделены "не нашёл" и "не смог посмотреть": если гасить stderr и
            # печатать одно и то же, отчёт превратит отказ команды в утверждение "правил нет",
            # и разбор уйдёт не туда. grep -m10 вместо | head -10: он не рвёт пайп, поэтому
            # pipefail не отдаёт 141 и ветка || не срабатывает после уже напечатанных строк.
            if _casc_out=$(ip rule show 2>&1); then
                grep -w fwmark <<< "$_casc_out" || echo "ip rule: правил по метке нет"
            else
                echo "ip rule: ПРОВЕРИТЬ НЕ УДАЛОСЬ: $(head -1 <<< "$_casc_out")"
            fi
            echo "table 100: $(ip route show table 100 2>/dev/null | tr '\n' '; ')"
            echo "ipset sets: $(ipset list -n 2>/dev/null | tr '\n' ' ' || echo 'N/A')"
            if _casc_out=$(ipset list ru 2>&1); then
                grep "Number of entries" <<< "$_casc_out" || echo "ipset ru: счётчик не найден"
            else
                echo "ipset ru: набора нет ($(head -1 <<< "$_casc_out"))"
            fi
            echo "ru.zone: $(stat -c '%y, %s байт' "$AWG_DIR/ru.zone" 2>/dev/null || echo 'файла нет')"
            if _casc_out=$(iptables -t mangle -S PREROUTING 2>&1); then
                grep -m10 -E "match-set|MARK" <<< "$_casc_out" || echo "mangle PREROUTING: правил каскада нет"
            else
                echo "mangle PREROUTING: ПРОВЕРИТЬ НЕ УДАЛОСЬ: $(head -1 <<< "$_casc_out")"
            fi
            # Грепаем именно "-o awg1", а не MASQUERADE: обычное MASQUERADE на внешний интерфейс
            # ставит сам установщик в PostUp, оно есть на ЛЮБОЙ установке, и по нему ветка "нет
            # правил" была бы недостижима, а отчёт показывал бы NAT на месте при отсутствующем
            # каскадном правиле. NAT проверяем обязательно: его скрипт ставит ПОСЛЕДНИМ, поэтому
            # оборванный запуск оставляет всё остальное на месте, а его - нет. Симптом при этом
            # обманчивый: российские сайты работают, остальное молчит, а отчёт без этой строки
            # показывал бы полностью исправный каскад.
            if _casc_out=$(iptables -t nat -S POSTROUTING 2>&1); then
                grep -m10 -- "-o awg1" <<< "$_casc_out" || echo "nat POSTROUTING: правила каскада (-o awg1) нет"
            else
                echo "nat POSTROUTING: ПРОВЕРИТЬ НЕ УДАЛОСЬ: $(head -1 <<< "$_casc_out")"
            fi
        else
            echo "не настроен"
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
    } | _mask_report_secrets > "$rf" || die "Ошибка записи отчета: $rf"
    umask "$_diag_umask"
    chmod 600 "$rf" || log_warn "Ошибка chmod отчета."
    log "Отчет: $rf"
}

# ==============================================================================
# Деинсталляция
# ==============================================================================

step_uninstall() {
    log "### ДЕИНСТАЛЛЯЦИЯ AMNEZIAWG ###"
    echo ""
    echo "ВНИМАНИЕ! Полное удаление AmneziaWG и конфигураций."
    echo "Процесс необратим!"
    echo ""
    local confirm="" backup="Y"
    if [[ "$AUTO_YES" -eq 0 ]]; then
        read -rp "Уверены? (введите 'yes'): " confirm < /dev/tty
        if [[ "$confirm" != "yes" ]]; then log "Деинсталляция отменена."; exit 1; fi
        read -rp "Создать бэкап перед удалением? [Y/n]: " backup < /dev/tty
    else
        log "Автоматическое подтверждение деинсталляции (--yes)."
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
        log "Создание бэкапа: $bf"
        if ! tar -czf "$bf" -C / "${_backup_paths[@]}" 2>/dev/null || ! chmod 600 "$bf"; then
            rm -f "$bf"
            die "Запрошенный бэкап не удался; деинсталляция отменена без удаления компонентов."
        fi
        log "Бэкап создан: $bf"
    fi
    # Загружаем флаг --no-tweaks из сохранённой конфигурации
    local saved_no_tweaks=0
    if [[ -f "$CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        saved_no_tweaks=$(safe_read_config_key "NO_TWEAKS" "$CONFIG_FILE" 2>/dev/null) || saved_no_tweaks=0
        saved_no_tweaks=${saved_no_tweaks:-0}
    fi
    log "Остановка сервиса..."
    command -v ip >/dev/null 2>&1 \
        || die "Команда ip нужна для обязательной проверки live awg0; удаление отменено."
    local _uninstall_awg0_state=""
    _uninstall_awg0_state=$(systemctl is-active awg-quick@awg0 2>/dev/null || true)
    if [[ "$_uninstall_awg0_state" =~ ^(active|activating|deactivating|reloading)$ ]]; then
        systemctl stop awg-quick@awg0 || die "Не удалось остановить active awg-quick@awg0; удаление отменено."
    fi
    if command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1; then
        [[ -f "$SERVER_CONF_FILE" && ! -L "$SERVER_CONF_FILE" ]] \
            && timeout 15 awg-quick down "$SERVER_CONF_FILE" >/dev/null 2>&1 \
            || die "Live awg0 не снят безопасно по штатному config; удаление отменено."
    fi
    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null \
        || { command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1; }; then
        die "awg0 всё ещё active/live; support/config teardown отменён."
    fi
    # Изоляционные DROP-правила (issue #178): PostDown конфига на диске мог
    # уже не содержать -D DROP (прерванная переустановка on->off между шагами
    # 6 и 7) - добираем stale-правила явно, как в шаге 7.
    while iptables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
    while ip6tables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
    systemctl disable awg-quick@awg0 2>/dev/null \
        || die "Не удалось disable awg-quick@awg0; удаление отменено до удаления конфига."
    # Удаляем только drop-in, ownership которого подтверждён точным marker.
    # Чужой файл под тем же именем без marker не трогаем.
    if [[ -e "$AWG0_DEPENDENCY_MARKER" || -L "$AWG0_DEPENDENCY_MARKER" ]]; then
        local _dependency_path=""
        [[ -f "$AWG0_DEPENDENCY_MARKER" && ! -L "$AWG0_DEPENDENCY_MARKER" ]] \
            || die "Некорректный systemd dependency marker; удаление отменено."
        IFS= read -r _dependency_path < "$AWG0_DEPENDENCY_MARKER" || _dependency_path=""
        [[ "$_dependency_path" == "$AWG0_DEPENDENCY_DROPIN" ]] \
            || die "Некорректный путь в systemd dependency marker; удаление отменено."
        rm -f -- "$AWG0_DEPENDENCY_DROPIN" || die "Не удалось удалить awg0 dependency drop-in."
        rm -f -- "$AWG0_DEPENDENCY_MARKER" || die "Не удалось снять awg0 dependency marker."
        rmdir "$(dirname "$AWG0_DEPENDENCY_DROPIN")" 2>/dev/null || true
        systemctl daemon-reload || die "systemctl daemon-reload не удался после удаления awg0 dependency."
    fi
    # DNS и bypass снимаются до остановки WARP: их timer/маршруты не должны
    # пережить egress, а exact teardown требует функций текущей common-библиотеки.
    if [[ -e "$AWG_DIR/.amnezia_dns_enabled_by_installer" || -L "$AWG_DIR/.amnezia_dns_enabled_by_installer" \
          || -e "$AWG_DIR/.warp_bypass_enabled_by_installer" || -L "$AWG_DIR/.warp_bypass_enabled_by_installer" ]]; then
        local _cleanup_common="$COMMON_SCRIPT_PATH" _local_common=""
        if [[ -n "$INSTALLER_DIR" ]]; then
            _local_common="$INSTALLER_DIR/${COMMON_SCRIPT_URL##*/}"
            [[ -f "$_local_common" ]] && _cleanup_common="$_local_common"
        fi
        [[ -f "$_cleanup_common" && ! -L "$_cleanup_common" ]] \
            || die "Текущая awg_common.sh нужна для безопасной очистки DNS/WARP bypass."
        # shellcheck source=/dev/null
        source "$_cleanup_common" || die "Не удалось загрузить $_cleanup_common для cleanup."
        declare -F teardown_amnezia_dns >/dev/null 2>&1 \
            && teardown_amnezia_dns || die "Безопасное удаление AmneziaDNS не удалось."
        declare -F teardown_warp_bypass >/dev/null 2>&1 \
            && teardown_warp_bypass || die "Безопасное удаление WARP bypass не удалось."
    fi
    # Multi-hop: гасим upstream-интерфейс только если сохранённая роль entry.
    # AWG_UPSTREAM_IFACE пишется и для single, поэтому проверка одного имени
    # могла остановить чужой awg-quick@awg1 при удалении обычной установки.
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
            || die "Небезопасный upstream cleanup marker; uninstall отменён."
        IFS= read -r _pending_up_iface < "$_pending_up_marker" || _pending_up_iface=""
        if [[ "$_pending_up_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$_pending_up_iface" != "awg0" ]]; then
            stop_owned_tunnel_runtime awg "$_pending_up_iface" \
                "/etc/amnezia/amneziawg/${_pending_up_iface}.conf" \
                || die "Не удалось полностью снять прежний upstream ${_pending_up_iface}; удаление отменено."
            systemctl disable "awg-quick@${_pending_up_iface}" 2>/dev/null \
                || die "Не удалось disable прежний upstream ${_pending_up_iface}; marker сохранён."
            if command -v ufw >/dev/null 2>&1 && ! ufw status 2>/dev/null | grep -q inactive; then
                delete_owned_ufw_route_if_present "$_pending_up_iface" \
                    "AmneziaWG cascade awg0->${_pending_up_iface}" \
                    || die "Owned UFW route прежнего upstream неоднозначен; uninstall отменён."
            fi
            rm -f "$_pending_up_marker" || die "Не удалось снять upstream cleanup marker."
        else
            die "Некорректный upstream cleanup marker; безопасная деинсталляция невозможна."
        fi
    fi
    # Прерванная WARP→WARP миграция хранит ownership прежнего iface в parked
    # marker'ах. Очищаем её ДО обычных markers нового iface; иначе удаление
    # AWG_DIR уничтожило бы единственное доказательство ownership старого unit.
    local _pending_warp_marker="$AWG_DIR/.warp_cleanup_pending" _pending_warp_iface=""
    if [[ -e "$_pending_warp_marker" || -L "$_pending_warp_marker" ]]; then
        [[ -f "$_pending_warp_marker" && ! -L "$_pending_warp_marker" ]] \
            || die "Небезопасный WARP cleanup marker; uninstall отменён."
        IFS= read -r _pending_warp_iface < "$_pending_warp_marker" || _pending_warp_iface=""
        [[ "$_pending_warp_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ \
           && "$_pending_warp_iface" != "awg0" ]] \
            || die "Некорректный WARP cleanup marker; безопасная деинсталляция невозможна."
        if [[ "$_saved_egress" == "warp" && "$_warp_iface" == "$_pending_warp_iface" ]]; then
            # Crash до commit init оставляет current iface в cleanup journal.
            # Возвращаем его parked ownership в штатные marker'ы: ниже обычный
            # owned-current teardown удалит тот же iface ровно один раз.
            if [[ -e "$AWG_DIR/.warp_cleanup_service_owner" || -L "$AWG_DIR/.warp_cleanup_service_owner" \
                  || -e "$AWG_DIR/.warp_cleanup_created_config_owner" || -L "$AWG_DIR/.warp_cleanup_created_config_owner" \
                  || -e "$AWG_DIR/.warp_cleanup_managed_config_owner" || -L "$AWG_DIR/.warp_cleanup_managed_config_owner" ]]; then
                _INSTALL_ROLLBACK_WARP_PARKED=1
                _install_restore_parked_warp_ownership \
                    || die "Не удалось восстановить current WARP ownership; uninstall отменён."
            fi
            rm -f -- "$_pending_warp_marker" \
                || die "Не удалось снять stale current WARP cleanup marker."
        else
            local AWG_EGRESS="${_saved_egress:-direct}"
            local AWG_WARP_IFACE="${_warp_iface:-wgcf}"
            finalize_deferred_mode_cleanup \
                || die "Не удалось безопасно очистить pending WARP migration; ownership сохранён, uninstall отменён."
        fi
    fi
    if [[ "$_saved_role" == "entry" && "$_up_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ \
          && "$_up_iface" != "awg0" ]]; then
        log "Остановка upstream-интерфейса ${_up_iface}..."
        stop_owned_tunnel_runtime awg "$_up_iface" "/etc/amnezia/amneziawg/${_up_iface}.conf" \
            || die "Не удалось полностью снять upstream ${_up_iface}; удаление отменено."
        systemctl disable "awg-quick@${_up_iface}" 2>/dev/null \
            || die "Не удалось disable upstream ${_up_iface}; удаление отменено до удаления конфига."
        if command -v ufw >/dev/null 2>&1 && ! ufw status 2>/dev/null | grep -q inactive; then
            delete_owned_ufw_route_if_present "$_up_iface" \
                "AmneziaWG cascade awg0->${_up_iface}" \
                || die "Owned UFW route upstream ${_up_iface} неоднозначен; uninstall отменён."
        fi
    fi
    # WARP egress: каждый созданный ресурс имеет отдельный root-owned marker.
    # Нельзя удалять всё только по общему флагу: wgcf binary/account/config или
    # сам unit могли существовать до установки. Содержимое marker'ов сверяем с
    # узким allowlist путей; symlink-marker игнорируем.
    local _warp_service_marker="$AWG_DIR/.wgcf_enabled_by_installer"
    local _warp_binary_marker="$AWG_DIR/.wgcf_binary_installed_by_installer"
    local _warp_config_marker="$AWG_DIR/.wgcf_config_created_by_installer"
    local _warp_managed_config_marker="$AWG_DIR/.wgcf_config_managed_by_installer"
    local _warp_account_marker="$AWG_DIR/.wgcf_account_created_by_installer"
    local _owned_warp_iface="" _owned_warp_path="" _warp_owned_removed=0 _warp_service_stopped=0
    if [[ -e "$_warp_service_marker" || -L "$_warp_service_marker" ]]; then
        [[ -f "$_warp_service_marker" && ! -L "$_warp_service_marker" ]] \
            || die "Некорректный WARP service marker; удаление отменено."
        IFS= read -r _owned_warp_iface < "$_warp_service_marker" || _owned_warp_iface=""
        # Пустой legacy marker не сохранял исходное состояние unit и не может
        # доказать ownership: service/config/binary/account сохраняем.
        if [[ -z "$_owned_warp_iface" ]]; then
            log "Пустой legacy WARP marker двусмысленен; wg-quick service сохранён как pre-existing."
        elif [[ "$_owned_warp_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ \
              && "$_owned_warp_iface" != "awg0" ]]; then
            log "Остановка Cloudflare WARP (wg-quick@${_owned_warp_iface})..."
            stop_owned_tunnel_runtime wg "$_owned_warp_iface" \
                "/etc/wireguard/${_owned_warp_iface}.conf" \
                || die "Не удалось полностью снять WARP ${_owned_warp_iface}; удаление отменено."
            systemctl disable "wg-quick@${_owned_warp_iface}" 2>/dev/null \
                || die "Не удалось disable WARP ${_owned_warp_iface}; ownership marker сохранён."
            _warp_service_stopped=1
            _warp_owned_removed=1
        else
            die "Некорректный WARP service marker; удаление отменено."
        fi
        rm -f "$_warp_service_marker" || die "Не удалось снять WARP service marker."
    fi
    if [[ -e "$_warp_config_marker" || -L "$_warp_config_marker" ]]; then
        [[ -f "$_warp_config_marker" && ! -L "$_warp_config_marker" ]] \
            || die "Некорректный WARP config marker; удаление отменено."
        IFS= read -r _owned_warp_path < "$_warp_config_marker" || _owned_warp_path=""
        if [[ "$_owned_warp_path" =~ ^/etc/wireguard/([a-zA-Z][a-zA-Z0-9_-]{0,14})\.conf$ \
              && "${BASH_REMATCH[1]}" != "awg0" ]]; then
            local _created_warp_iface="${BASH_REMATCH[1]}"
            if [[ "$_warp_service_stopped" -eq 1 && "$_owned_warp_iface" != "$_created_warp_iface" ]]; then
                die "WARP service/config ownership marker'ы указывают на разные iface; удаление отменено."
            fi
            if [[ "$_warp_service_stopped" -eq 0 ]] \
               && { systemctl is-active --quiet "wg-quick@${_created_warp_iface}" 2>/dev/null \
                    || systemctl is-enabled --quiet "wg-quick@${_created_warp_iface}" 2>/dev/null \
                    || { command -v ip >/dev/null 2>&1 \
                         && ip link show dev "$_created_warp_iface" >/dev/null 2>&1; }; }; then
                die "Installer-created WARP config используется active/enabled/live интерфейсом без service ownership; удаление отменено."
            fi
            rm -f -- "$_owned_warp_path" || die "Не удалось удалить $_owned_warp_path."
            _warp_owned_removed=1
        else
            die "Некорректный WARP config marker; удаление отменено."
        fi
        rm -f "$_warp_config_marker" || die "Не удалось снять WARP config marker."
    fi
    if [[ -e "$_warp_managed_config_marker" || -L "$_warp_managed_config_marker" ]]; then
        [[ -f "$_warp_managed_config_marker" && ! -L "$_warp_managed_config_marker" ]] \
            || die "Некорректный WARP managed-config marker; удаление отменено."
        IFS= read -r _owned_warp_path < "$_warp_managed_config_marker" || _owned_warp_path=""
        if [[ "$_owned_warp_path" =~ ^/etc/wireguard/([a-zA-Z][a-zA-Z0-9_-]{0,14})\.conf$ \
              && "${BASH_REMATCH[1]}" != "awg0" ]]; then
            log "Управляемый legacy WARP-конфиг оставлен: $_owned_warp_path"
        else
            die "Некорректный путь в WARP managed-config marker; удаление отменено."
        fi
        rm -f "$_warp_managed_config_marker" \
            || die "Не удалось снять WARP managed-config marker."
    fi
    if [[ -e "$_warp_account_marker" || -L "$_warp_account_marker" ]]; then
        [[ -f "$_warp_account_marker" && ! -L "$_warp_account_marker" ]] \
            || die "Некорректный WARP account marker; удаление отменено."
        IFS= read -r _owned_warp_path < "$_warp_account_marker" || _owned_warp_path=""
        if [[ "$_owned_warp_path" == "/etc/wireguard/wgcf-account.toml" ]]; then
            rm -f -- "$_owned_warp_path" || die "Не удалось удалить $_owned_warp_path."
            _warp_owned_removed=1
        else
            die "Некорректный WARP account marker; удаление отменено."
        fi
        rm -f "$_warp_account_marker" || die "Не удалось снять WARP account marker."
    fi
    if [[ -e "$_warp_binary_marker" || -L "$_warp_binary_marker" ]]; then
        [[ -f "$_warp_binary_marker" && ! -L "$_warp_binary_marker" ]] \
            || die "Некорректный WARP binary marker; удаление отменено."
        IFS= read -r _owned_warp_path < "$_warp_binary_marker" || _owned_warp_path=""
        if [[ "$_owned_warp_path" == "/usr/local/bin/wgcf" ]]; then
            rm -f -- "$_owned_warp_path" || die "Не удалось удалить $_owned_warp_path."
            _warp_owned_removed=1
        else
            die "Некорректный WARP binary marker; удаление отменено."
        fi
        rm -f "$_warp_binary_marker" || die "Не удалось снять WARP binary marker."
    fi
    if [[ "$_saved_egress" == "warp" && "$_warp_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ \
          && "$_warp_iface" != "awg0" ]] \
       && command -v ufw >/dev/null 2>&1 && ! ufw status 2>/dev/null | grep -q inactive; then
        delete_owned_ufw_route_if_present "$_warp_iface" "AmneziaWG→WARP egress" \
            || die "Owned UFW route WARP ${_warp_iface} неоднозначен; uninstall отменён."
    fi
    [[ "$_warp_owned_removed" -eq 1 ]] && log "Компоненты WARP, созданные установщиком, удалены."
    modprobe -r amneziawg 2>/dev/null || true
    # v5.12.0+: автовосстановление модуля при обновлении ядра.
    # Удаляем apt hook и systemd unit ДО apt purge, чтобы хук не сработал
    # во время purge amneziawg-dkms (helper попытался бы пересобрать DKMS,
    # но пакета уже нет). Файлы могут отсутствовать у установок до v5.12.0 —
    # все операции idempotent.
    log "Удаление компонентов автовосстановления модуля (v5.12.0+)..."
    if systemctl is-enabled amneziawg-ensure-module.service &>/dev/null; then
        systemctl disable amneziawg-ensure-module.service 2>/dev/null || true
    fi
    rm -f /etc/systemd/system/amneziawg-ensure-module.service \
        /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        /etc/logrotate.d/amneziawg-ensure-module \
        /usr/local/sbin/amneziawg-ensure-module \
        2>/dev/null
    # Также подчищаем staging dotfiles, оставшиеся от прерванного install (atomic deploy).
    rm -f /etc/systemd/system/.amneziawg-ensure-module.service.new \
        /etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new \
        /etc/logrotate.d/.amneziawg-ensure-module.new \
        /usr/local/sbin/.amneziawg-ensure-module.new \
        2>/dev/null || true
    rm -f /var/log/amneziawg-ensure-module.log* 2>/dev/null || true
    rm -rf /var/lib/amneziawg 2>/dev/null || true
    systemctl daemon-reload 2>/dev/null || true
    log "Очистка правил UFW для AmneziaWG..."
        if command -v ufw &>/dev/null; then
            local port_to_del
            if [[ -f "$CONFIG_FILE" ]]; then
                # shellcheck source=/dev/null
                port_to_del=$(safe_read_config_key "AWG_PORT" "$CONFIG_FILE")
            fi
            port_to_del=${port_to_del:-39743}
            delete_owned_ufw_udp_allow_if_present "$port_to_del" "AmneziaWG VPN" \
                || die "UFW allow ${port_to_del}/udp чужой или неоднозначный; он сохранён, uninstall отменён."
            # Route удаляется только когда форма и installer-comment дают
            # однозначное доказательство ownership. Старые rules без comment и
            # чужие same-shaped rules сохраняются: угадывать при uninstall нельзя.
            local _nic
            _nic=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1); exit}')
            if [[ "$_nic" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,14}$ && "$_nic" != "awg0" ]]; then
                delete_owned_ufw_route_if_present "$_nic" "AmneziaWG Routing" \
                    || die "UFW route awg0→${_nic} чужой или неоднозначный; он сохранён, uninstall отменён."
            else
                log_warn "Main iface не определён; возможный legacy UFW route сохранён."
            fi

            # ufw disable выполняется ТОЛЬКО если UFW был включён нашим установщиком.
            # Защита от destructive uninstall на VPS где UFW использовался для
            # SSH/web hardening ДО установки нашего скрипта (audit).
            # Backwards compat: старые установки без маркера сохраняют UFW активным.
            if [[ -f "$AWG_DIR/.ufw_enabled_by_installer" ]]; then
                log "Отключение UFW (был включён нашим установщиком)..."
                ufw --force disable 2>/dev/null
                rm -f "$AWG_DIR/.ufw_enabled_by_installer"
            else
                log "UFW оставлен активным (использовался до установки или старая версия инсталлятора)."
            fi
        fi
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        log "Снятие блокировок Fail2Ban..."
        if command -v fail2ban-client &>/dev/null; then
            fail2ban-client unban --all 2>/dev/null || true
            systemctl stop fail2ban 2>/dev/null
        fi
    else
        log "Пропуск Fail2Ban (установка с --no-tweaks); owned UFW-правила удалены."
    fi
    log "Удаление пакетов..."
    # Снять hold с PPA-пакетов (ставился на пиновом пути H0) ДО удаления PPA:
    # `apt-mark unhold` требует installed- или candidate-версию, а после удаления
    # PPA (ниже) кандидат исчезает и apt-mark падает 'Can't select ... version',
    # оставляя hold в dpkg-selection -> блокирует будущую переустановку. dpkg-
    # fallback чистит selection напрямую, если PPA уже убран прошлым прогоном.
    local _hp
    for _hp in amneziawg amneziawg-dkms; do
        apt-mark unhold "$_hp" >/dev/null 2>&1 || true
        if dpkg --get-selections "$_hp" 2>/dev/null | grep -q '[[:space:]]hold$'; then
            echo "$_hp deinstall" | dpkg --set-selections >/dev/null 2>&1 || true
        fi
    done
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        local _purge_pkgs=(amneziawg-dkms amneziawg-tools qrencode)
        # fail2ban purge-им только если сами его доустановили (маркер из
        # setup_fail2ban) - иначе пользовательская SSH-защита, стоявшая до
        # установщика, не должна исчезать вместе с VPN. Наш jail-файл
        # удаляется ниже в любом случае. Backwards compat: старые установки
        # без маркера сохраняют fail2ban установленным.
        if [[ -f "$AWG_DIR/.fail2ban_installed_by_installer" ]]; then
            _purge_pkgs+=(fail2ban)
        else
            log "fail2ban оставлен установленным (стоял до установщика или старая версия инсталлятора)."
        fi
        DEBIAN_FRONTEND=noninteractive apt-get purge -y "${_purge_pkgs[@]}" 2>/dev/null || log_warn "Ошибка purge."
    else
        DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools qrencode 2>/dev/null || log_warn "Ошибка purge."
    fi
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || log_warn "Ошибка autoremove."
    log "Удаление PPA и файлов..."
    rm -f /etc/apt/sources.list.d/amnezia-ppa.sources \
        /etc/apt/sources.list.d/amnezia-ppa.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.list \
        /etc/apt/sources.list.d/amnezia-ubuntu-ppa-*.sources \
        /etc/apt/keyrings/amnezia-ppa.gpg 2>/dev/null
    rm -rf /etc/amnezia \
        /etc/modules-load.d/amneziawg.conf \
        /etc/sysctl.d/99-amneziawg-security.conf \
        /etc/sysctl.d/99-amneziawg-forwarding.conf \
        /etc/logrotate.d/amneziawg* || log_warn "Ошибка удаления файлов."
    if [[ "$saved_no_tweaks" -eq 0 ]]; then
        # Удаляем только наш собственный jail-файл.
        # Раньше здесь была эвристика "если jail.local содержит banaction = ufw,
        # удалить весь файл" — слишком широкий фильтр, мог снести чужой
        # jail.local с custom jails. Эвристика убрана (audit).
        # Если у юзера остался jail.local от очень старых версий нашего
        # инсталлятора — пусть сам решает что с ним делать.
        rm -f /etc/fail2ban/jail.d/amneziawg.conf 2>/dev/null
        # Если fail2ban не purge-ился (стоял до нас) - перезапускаем его без
        # нашего jail: выше он был остановлен (systemctl stop fail2ban).
        if command -v fail2ban-client &>/dev/null && [[ ! -f "$AWG_DIR/.fail2ban_installed_by_installer" ]]; then
            systemctl restart fail2ban 2>/dev/null || log_warn "Не удалось перезапустить fail2ban после удаления нашего jail."
        fi
    fi
    log "Удаление DKMS..."
    # Корректно снять DKMS-регистрацию (для всех версий amneziawg/*) и убрать
    # исходник в /usr/src, а не только состояние в /var/lib/dkms. Hold с PPA-
    # пакетов снят выше (до удаления PPA). `dkms status`: 'amneziawg/1.0.0, <kern>...'.
    if command -v dkms >/dev/null 2>&1; then
        local _dv
        while IFS= read -r _dv; do
            [[ -n "$_dv" ]] || continue
            if ! dkms remove -m amneziawg -v "$_dv" --all >/dev/null 2>&1; then
                log_warn "dkms remove amneziawg/$_dv не удался - дочищаю файлы вручную."
            fi
        done < <(dkms status 2>/dev/null | awk -F'[,/ ]+' '/^amneziawg[,/]/{print $2}' | sort -u)
    fi
    rm -rf /var/lib/dkms/amneziawg* /usr/src/amneziawg-* || log_warn "Ошибка удаления DKMS."
    # Подчистить возможно оставшийся собранный .ko (если dkms remove не отработал) + depmod.
    find /lib/modules -name 'amneziawg.ko*' -path '*/updates/dkms/*' -delete 2>/dev/null || true
    command -v depmod >/dev/null 2>&1 && depmod -a >/dev/null 2>&1 || true
    log "Восстановление sysctl..."
    # Только точные строки, которые писали legacy-версии нашего инсталлятора
    # (=1 для all/default/lo). Раньше удалялась ЛЮБАЯ строка с disable_ipv6 -
    # включая добавленные самим пользователем (например =0 override).
    if grep -qE '^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$' /etc/sysctl.conf 2>/dev/null; then
        sed -i -E '/^net\.ipv6\.conf\.(all|default|lo)\.disable_ipv6[[:space:]]*=[[:space:]]*1[[:space:]]*$/d' /etc/sysctl.conf || log_warn "Ошибка sed sysctl.conf"
    fi
    sysctl -p --system 2>/dev/null
    rm -f /etc/apt/sources.list.d/*.bak-* "$AWG_DIR"/ubuntu.sources.bak-* 2>/dev/null || true
    log "Удаление cron и скриптов..."
    rm -f /etc/cron.d/awg-expiry 2>/dev/null
    log "=== ДЕИНСТАЛЛЯЦИЯ ЗАВЕРШЕНА ==="
    # Копируем лог и удаляем рабочую директорию
    cp "$LOG_FILE" "$HOME/awg_uninstall.log" 2>/dev/null || true
    rm -rf "$AWG_DIR" 2>/dev/null || true
    exit 0
}

# ==============================================================================
# ШАГ 0: Инициализация
# ==============================================================================

initialize_setup() {
    if [ "$(id -u)" -ne 0 ]; then die "Запустите скрипт от root (sudo bash $0)."; fi

    mkdir -p "$AWG_DIR" || die "Ошибка создания $AWG_DIR"
    chown root:root "$AWG_DIR"

    # Process-wide lock: предотвращает запуск двух экземпляров install_amneziawg.sh
    # одновременно. Без него два concurrent запуска могли бы прочитать одинаковый
    # setup_state, конкурентно дёргать apt-get/dkms/ufw и сломать package state
    # (audit).
    # FD выбран фиксированным (9) и не конфликтует с update_state (использует 200).
    # Lock держится открытым весь lifetime процесса — release автоматически на exit.
    INSTALL_LOCK_FILE="$AWG_DIR/.install.lock"
    exec 9>"$INSTALL_LOCK_FILE" || die "Не могу открыть $INSTALL_LOCK_FILE"
    if ! flock -n 9; then
        die "Другой экземпляр install_amneziawg.sh уже запущен. Подождите завершения, либо если процесс висит — удалите $INSTALL_LOCK_FILE и попробуйте снова."
    fi

    touch "$LOG_FILE" || die "Не удалось создать лог-файл $LOG_FILE"
    chmod 640 "$LOG_FILE"
    log "--- НАЧАЛО УСТАНОВКИ AmneziaWG 2.0 (v${SCRIPT_VERSION}) ---"
    log "### ШАГ 0: Инициализация и проверка параметров ###"
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"
    log "Рабочая директория: $AWG_DIR"
    log "Лог файл: $LOG_FILE"

    check_os_version
    check_container
    check_kernel_version
    check_free_space

    local default_port=39743
    local default_subnet="10.9.9.1/24"
    local config_exists=0

    # Инициализация переменных
    AWG_PORT=$default_port
    AWG_TUNNEL_SUBNET=$default_subnet
    DISABLE_IPV6="default"
    ALLOWED_IPS_MODE="default"
    ALLOWED_IPS=""
    AWG_ENDPOINT=""
    CLIENT_ISOLATION=""
    # Жёсткий сброс (не ${VAR:-}): внутренний ownership-маркер не должен
    # наследоваться из окружения - экспортированная снаружи переменная иначе
    # дотянется до удаления маршрутов из AllowedIPs (ревью PR #179).
    CLIENT_ISOLATION_NET=""

    # Жёсткий сброс до загрузки конфига: значение не должно приезжать из env.
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

    # Загрузка конфига
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Найден файл конфигурации $CONFIG_FILE. Загрузка настроек..."
        config_exists=1
        # shellcheck source=/dev/null
        safe_load_config "$CONFIG_FILE" || log_warn "Не удалось полностью загрузить настройки из $CONFIG_FILE."
        AWG_PORT=${AWG_PORT:-$default_port}
        AWG_TUNNEL_SUBNET=${AWG_TUNNEL_SUBNET:-$default_subnet}
        DISABLE_IPV6=${DISABLE_IPV6:-"default"}
        ALLOWED_IPS_MODE=${ALLOWED_IPS_MODE:-"default"}
        ALLOWED_IPS=${ALLOWED_IPS:-""}
        AWG_ENDPOINT=${AWG_ENDPOINT:-""}
        # CLIENT_ISOLATION из конфига: строго 0|1 (whitelist-парсер значения не
        # проверяет, а конфиг правят руками). Иначе арифметический контекст
        # [[ "on" -eq 1 ]] разыменует строку как пустую переменную (=0) и молча
        # ИНВЕРТИРУЕТ security-настройку: написал on - получил off (ревью PR #179).
        case "${CLIENT_ISOLATION:-}" in
            ""|0|1) : ;;
            *)
                log_warn "CLIENT_ISOLATION='$CLIENT_ISOLATION' в $CONFIG_FILE не валиден (допустимо 0|1) - включаю изоляцию (безопасный дефолт)."
                CLIENT_ISOLATION=1
                ;;
        esac
        # CLIENT_ISOLATION_NET - внутренний ownership-маркер: ровно один
        # канонический IPv4 CIDR (вывод tunnel_network_cidr). Мусор с запятыми
        # в substring-замене _apply_isolation_to_allowed_ips съел бы соседние
        # пользовательские маршруты одной заменой (ревью PR #179).
        if [[ -n "${CLIENT_ISOLATION_NET:-}" ]] \
           && [[ "$(tunnel_network_cidr "$CLIENT_ISOLATION_NET" || true)" != "$CLIENT_ISOLATION_NET" ]]; then
            log_warn "CLIENT_ISOLATION_NET='$CLIENT_ISOLATION_NET' в $CONFIG_FILE не валиден (ожидается один канонический CIDR) - сбрасываю."
            CLIENT_ISOLATION_NET=""
        fi
        log "Настройки из файла загружены."
    else
        log "Файл конфигурации $CONFIG_FILE не найден."
    fi

    case "$CLI_I1_MODE" in
        ""|random|quic) : ;;
        *) die "Некорректный --i1-mode='$CLI_I1_MODE'. Допустимо: random или quic." ;;
    esac
    # В legacy-конфигах ключа AWG_I1_MODE нет. Восстанавливаем его по форме I1,
    # а мусорное enum-значение не даём персистить дальше. Сам I1 здесь не
    # меняем: это wire-контракт уже выданных клиентов.
    if [[ "$config_exists" -eq 1 ]]; then
        case "${AWG_I1_MODE:-}" in
            random|quic) : ;;
            "")
                if [[ "${AWG_I1:-}" == "<b 0x"*">" ]]; then AWG_I1_MODE=quic; else AWG_I1_MODE=random; fi
                ;;
            *)
                log_warn "AWG_I1_MODE='$AWG_I1_MODE' в $CONFIG_FILE не валиден — восстанавливаю режим по существующему I1."
                if [[ "${AWG_I1:-}" == "<b 0x"*">" ]]; then AWG_I1_MODE=quic; else AWG_I1_MODE=random; fi
                ;;
        esac
    fi

    # Старый fork routing state нужен для отложенной очистки после возможных
    # reboot на шагах 1/2. Новый init будет записан ниже, поэтому захватываем
    # значения до CLI override.
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
        || die "Pending cleanup journal повреждён или конфликтует с current fork mode; live egress не изменён."

    # Старый порт из awgsetup_cfg.init: нужен шагу 4, чтобы удалить устаревшее
    # UFW-правило при смене порта (Issue #175). Захват ДО CLI-override, иначе
    # старое значение теряется навсегда - uninstall читает уже перезаписанный
    # конфиг и старый порт не узнает. PREV_AWG_PORT мог уже загрузиться из
    # awgsetup_cfg.init через safe_load_config - это отложенное удаление с
    # прошлого запуска: шаг 1 завершается request_reboot, до шага 4 доживает
    # только значение, записанное на диск (PR #176).
    PREV_AWG_PORT="${PREV_AWG_PORT:-}"
    _cfg_awg_port=""
    if [[ "$config_exists" -eq 1 ]]; then _cfg_awg_port="$AWG_PORT"; fi

    # Прежнее значение изоляции - для предупреждения о смене (issue #178).
    # Legacy-конфиг без ключа = 1 (изолированно): иначе переход legacy -> --isolation=off не даёт предупреждения о regen.
    _cfg_client_isolation=""
    if [[ "$config_exists" -eq 1 ]]; then _cfg_client_isolation="${CLIENT_ISOLATION:-1}"; fi

    # Прежнее имя сервера - для предупреждения о смене (D#180).
    # Legacy-конфиг без ключа = 'AWG Server' (прежний хардкод).
    _cfg_server_name=""
    if [[ "$config_exists" -eq 1 ]]; then _cfg_server_name="${AWG_SERVER_NAME:-AWG Server}"; fi

    # --mobile разворачивается в CLI_PRESET/CLI_PORT до их потребителей.
    resolve_mobile_flag

    # Переопределение из CLI
    AWG_PORT=${CLI_PORT:-$AWG_PORT}
    # Порт изменился этим запуском - прежнее значение становится отложенным
    # удалением. Если порт вернули обратно (совпал с отложенным) - удаление
    # снимается: правило снова нужно.
    if [[ -n "$_cfg_awg_port" && "$_cfg_awg_port" != "$AWG_PORT" ]]; then
        PREV_AWG_PORT="$_cfg_awg_port"
    fi
    if [[ "$PREV_AWG_PORT" == "$AWG_PORT" ]]; then PREV_AWG_PORT=""; fi
    AWG_TUNNEL_SUBNET=${CLI_SUBNET:-$AWG_TUNNEL_SUBNET}
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then DISABLE_IPV6=$CLI_DISABLE_IPV6; fi
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then
        ALLOWED_IPS_MODE=$CLI_ROUTING_MODE
        # Явный CLI-режим вытесняет и список: раньше --route-all/--route-amnezia
        # при переустановке меняли только режим, а ALLOWED_IPS оставался старым
        # из awgsetup_cfg.init - флаг молча не действовал (Issue #170). Пустой
        # список заставит configure_routing_mode пересчитать его под новый режим.
        ALLOWED_IPS=""
        # Ownership умирает вместе со списком, который он описывал: иначе
        # stale CLIENT_ISOLATION_NET может присвоить себе токен пользователя
        # из свежего --route-custom (issue #178).
        CLIENT_ISOLATION_NET=""
        if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then ALLOWED_IPS=$CLI_CUSTOM_ROUTES; fi
    fi
    if [[ -n "$CLI_ENDPOINT" ]]; then
        if ! validate_endpoint "$CLI_ENDPOINT"; then
            die "Некорректный --endpoint: '$CLI_ENDPOINT'. Допустимые форматы: FQDN (vpn.example.com), IPv4 (1.2.3.4), [IPv6] ([2001:db8::1]). Запрещены пробелы, табы, кавычки, обратный слеш и переводы строк."
        fi
        AWG_ENDPOINT=$CLI_ENDPOINT
    fi
    if [[ "$CLI_NO_TWEAKS" -eq 1 ]]; then NO_TWEAKS=1; fi
    if [[ "$CLI_KEEP_PACKAGES" -eq 1 ]]; then KEEP_PACKAGES=1; fi

    # Multi-hop: роль ноды и параметры upstream-туннеля.
    # CLI > сохранённый конфиг > дефолты. Значение 'single' не требует никаких
    # upstream-полей; 'exit' тоже (это обычный сервер, просто маркируется ролью
    # для манагера и документации); 'entry' требует upstream-конфига.
    AWG_ROLE="${AWG_ROLE:-single}"
    if [[ -n "$CLI_ROLE" ]]; then AWG_ROLE="$CLI_ROLE"; fi
    case "$AWG_ROLE" in
        single|exit|entry) ;;
        *) die "Некорректная --role='$AWG_ROLE'. Допустимые: single, exit, entry." ;;
    esac
    AWG_UPSTREAM_IFACE="${CLI_UPSTREAM_IFACE:-${AWG_UPSTREAM_IFACE:-awg1}}"
    AWG_UPSTREAM_TABLE="${CLI_UPSTREAM_TABLE:-${AWG_UPSTREAM_TABLE:-123}}"
    AWG_UPSTREAM_FWMARK="${CLI_UPSTREAM_FWMARK:-${AWG_UPSTREAM_FWMARK:-0xca6d}}"
    AWG_UPSTREAM_PRIORITY="${AWG_UPSTREAM_PRIORITY:-456}"
    if [[ "$AWG_ROLE" == "entry" ]]; then
        if [[ "$AWG_UPSTREAM_IFACE" == "awg0" ]]; then
            die "--upstream-iface=awg0 конфликтует с основным интерфейсом. Используйте awg1."
        fi
        if ! [[ "$AWG_UPSTREAM_IFACE" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]]; then
            die "Некорректное --upstream-iface='$AWG_UPSTREAM_IFACE'."
        fi
        if ! validate_policy_table "$AWG_UPSTREAM_TABLE"; then
            die "Некорректное --upstream-table='$AWG_UPSTREAM_TABLE' (1..4294967295, кроме зарезервированных 253-255)."
        fi
        if ! validate_fwmark "$AWG_UPSTREAM_FWMARK"; then
            die "Некорректное --upstream-fwmark='$AWG_UPSTREAM_FWMARK' (ненулевой uint32, не 0xca6c)."
        fi
        if ! validate_policy_priority "$AWG_UPSTREAM_PRIORITY"; then
            die "Некорректный AWG_UPSTREAM_PRIORITY='$AWG_UPSTREAM_PRIORITY' (1..32764; lookup и guard должны быть раньше main rule 32766)."
        fi
        # Upstream-конфиг: CLI обязателен только на первом запуске. Если
        # awg1.conf уже лежит на диске (второй запуск после reboot) — считаем,
        # что он был корректно создан ранее и не требуем --upstream-conf повторно.
        local _up_iface_conf="/etc/amnezia/amneziawg/${AWG_UPSTREAM_IFACE}.conf"
        local _up_staged_conf="$AWG_DIR/.upstream-${AWG_UPSTREAM_IFACE}.pending.conf"
        if [[ -n "$CLI_UPSTREAM_CONF" ]]; then
            if [[ ! -f "$CLI_UPSTREAM_CONF" ]]; then
                die "--upstream-conf не найден: '$CLI_UPSTREAM_CONF'."
            fi
            # Шаги 1/2 могут перезагрузить VPS до render в шаге 6. Копируем
            # входной конфиг в root-owned AWG_DIR, чтобы повторный запуск не
            # зависел от исходного пути и повторной передачи CLI-флага.
            local _up_stage_tmp
            _up_stage_tmp=$(mktemp -p "$AWG_DIR" ".upstream-${AWG_UPSTREAM_IFACE}.XXXXXX") \
                || die "Не удалось создать staging-файл upstream-конфига."
            _install_temp_files+=("$_up_stage_tmp")
            cp -- "$CLI_UPSTREAM_CONF" "$_up_stage_tmp" \
                && chmod 600 "$_up_stage_tmp" \
                && mv -f "$_up_stage_tmp" "$_up_staged_conf" \
                || { rm -f "$_up_stage_tmp"; die "Не удалось безопасно сохранить --upstream-conf до reboot."; }
            AWG_UPSTREAM_CONF="$_up_staged_conf"
        elif [[ -s "$_up_staged_conf" ]]; then
            AWG_UPSTREAM_CONF="$_up_staged_conf"
        elif [[ -f "$_up_iface_conf" \
                && ( -n "$CLI_UPSTREAM_TABLE" || -n "$CLI_UPSTREAM_FWMARK" ) ]]; then
            # Policy-only intent обязан пережить reboot шагов 1/2. Сохраняем
            # snapshot в pending path: process-local AWG_UPSTREAM_CONF терялся.
            local _up_policy_tmp
            _up_policy_tmp=$(mktemp -p "$AWG_DIR" ".upstream-policy-${AWG_UPSTREAM_IFACE}.XXXXXX") \
                || die "Не удалось создать staging policy-only upstream-конфига."
            _install_temp_files+=("$_up_policy_tmp")
            cp -- "$_up_iface_conf" "$_up_policy_tmp" \
                && chmod 600 "$_up_policy_tmp" \
                && mv -f "$_up_policy_tmp" "$_up_staged_conf" \
                || { rm -f "$_up_policy_tmp"; die "Не удалось сохранить policy-only upstream intent до reboot."; }
            AWG_UPSTREAM_CONF="$_up_staged_conf"
        elif [[ ! -f "$_up_iface_conf" ]]; then
            die "role=entry требует --upstream-conf=<файл.conf> (от manage add на exit-ноде)."
        fi
        export AWG_UPSTREAM_CONF
    fi
    export AWG_ROLE AWG_UPSTREAM_IFACE AWG_UPSTREAM_TABLE AWG_UPSTREAM_FWMARK AWG_UPSTREAM_PRIORITY

    # WARP egress: клиентский трафик уходит в Cloudflare WARP вместо прямого
    # NAT на eth0. Доступен только на role=single или role=exit. На entry
    # egress уже делегирован upstream-ноде — WARP там был бы третьей обёрткой
    # без смысла, явно отвергаем.
    AWG_EGRESS="${AWG_EGRESS:-direct}"
    if [[ -n "$CLI_EGRESS" ]]; then AWG_EGRESS="$CLI_EGRESS"; fi
    case "$AWG_EGRESS" in
        direct|warp) ;;
        *) die "Некорректный --egress='$AWG_EGRESS'. Допустимо: direct, warp." ;;
    esac
    if [[ "$AWG_EGRESS" == "warp" && "$AWG_ROLE" == "entry" ]]; then
        die "--egress=warp несовместим с --role=entry. WARP ставится на exit-ноде (или single), не на entry."
    fi
    AWG_WARP_IFACE="${CLI_WARP_IFACE:-${AWG_WARP_IFACE:-wgcf}}"
    AWG_WARP_TABLE="${CLI_WARP_TABLE:-${AWG_WARP_TABLE:-2408}}"
    AWG_WARP_PRIORITY="${CLI_WARP_PRIORITY:-${AWG_WARP_PRIORITY:-789}}"
    if [[ "$AWG_EGRESS" == "warp" ]]; then
        if ! [[ "$AWG_WARP_IFACE" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] \
           || [[ "$AWG_WARP_IFACE" == "awg0" || "$AWG_WARP_IFACE" == "wgcf-profile" ]]; then
            die "Некорректный AWG_WARP_IFACE='$AWG_WARP_IFACE'."
        fi
        if ! validate_policy_table "$AWG_WARP_TABLE"; then
            die "Некорректное --warp-table='$AWG_WARP_TABLE' (1..4294967295, кроме зарезервированных 253-255)."
        fi
        if ! validate_policy_priority "$AWG_WARP_PRIORITY"; then
            die "Некорректное --warp-priority='$AWG_WARP_PRIORITY' (1..32764; lookup и guard должны быть раньше main rule 32766)."
        fi
        # entry и WARP взаимоисключающие, поэтому persisted upstream table в
        # single/exit не является активным consumer и не должна блокировать
        # выбор такого же номера для WARP.
    fi
    # --warp-bypass: список источников (comma-separated) для обхода WARP для
    # специфичных dst. Каждый элемент: `youtube` | `custom:URL` | `custom:/path`.
    # `none` (default) — ничего не делаем. Смысл только при egress=warp.
    AWG_WARP_BYPASS="${CLI_WARP_BYPASS:-${AWG_WARP_BYPASS:-none}}"
    if [[ "$AWG_WARP_BYPASS" != "none" && "$AWG_EGRESS" != "warp" ]]; then
        die "--warp-bypass имеет смысл только вместе с --egress=warp (иначе нет WARP, который нужно обходить)."
    fi
    if (( ${#AWG_WARP_BYPASS} > 4096 )); then
        die "--warp-bypass слишком длинный (максимум 4096 символов)."
    fi
    if [[ "$AWG_WARP_BYPASS" =~ [[:cntrl:]] ]]; then
        die "--warp-bypass содержит управляющий символ."
    fi
    case "$AWG_WARP_BYPASS" in
        *" "*|*"'"*|*'"'*|*\\*)
            die "--warp-bypass не допускает пробелы, кавычки или обратный слеш."
            ;;
    esac
    if [[ "$AWG_WARP_BYPASS" == ,* || "$AWG_WARP_BYPASS" == *, \
          || "$AWG_WARP_BYPASS" == *,,* ]]; then
        die "--warp-bypass содержит пустой элемент списка."
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
                        || die "Некорректный --warp-bypass: '$_s'. Допустимо: youtube, безопасный custom:http(s)://URL или custom:/абсолютный/путь — через запятую."
                    ;;
            esac
        done
    fi
    export AWG_EGRESS AWG_WARP_IFACE AWG_WARP_TABLE AWG_WARP_PRIORITY AWG_WARP_BYPASS

    # Смена fork routing режима может пережить два reboot до шага 6. Сохраняем
    # старые интерфейсы отдельными marker'ами, чтобы перед запуском нового awg0
    # гарантированно остановить unit'ы со stale policy rules.
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
        die "Нельзя начать вторую fork-mode migration, пока cleanup предыдущей не завершён. Сначала повторите установку без смены role/egress/iface."
    fi
    if [[ "$config_exists" -eq 1 && "$_cfg_awg_role" == "entry" \
          && ( "$AWG_ROLE" != "entry" || "$AWG_UPSTREAM_IFACE" != "$_cfg_upstream_iface" ) ]]; then
        write_pending_iface_marker "$AWG_DIR/.upstream_cleanup_pending" "$_cfg_upstream_iface" \
            || die "Не удалось сохранить старый upstream iface для безопасной очистки после reboot."
    fi
    if [[ "$config_exists" -eq 1 && "$_cfg_awg_egress" == "warp" \
          && ( "$AWG_EGRESS" != "warp" || "$AWG_WARP_IFACE" != "$_cfg_warp_iface" ) ]]; then
        write_pending_iface_marker "$AWG_DIR/.warp_cleanup_pending" "$_cfg_warp_iface" \
            || die "Не удалось сохранить старый WARP iface для безопасной очистки после reboot."
    fi
    # awg0→main нужен direct-режиму и только WARP с явным bypass. Для
    # warp+bypass=none это правило вместе с main MASQUERADE создало бы
    # fail-open путь. Удаляем лишь подтверждённое прежнее owned-правило и
    # только у commit boundary, чтобы early failure не повредил rollback.
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
                || die "Не удалось сохранить прежний main iface для отложенной UFW cleanup."
        else
            log_warn "Не удалось безопасно определить прежний main iface; UFW awg0→main будет сохранён."
        fi
    fi

    # AmneziaDNS: локальный dnsmasq на tunnel-gateway IP + vpn:// URI с
    # isThirdPartyConfig=false, чтобы Amnezia VPN клиент включил встроенный
    # site-based split tunneling (сайты из списка «в обход VPN» → трафик
    # уходит через реальное подключение устройства; сайт видит реальный IP).
    # Доступно на role=single и role=entry. На exit не имеет смысла: exit
    # не отдаёт конфиги клиентам напрямую.
    AWG_AMNEZIA_DNS="${CLI_AMNEZIA_DNS:-${AWG_AMNEZIA_DNS:-off}}"
    case "$AWG_AMNEZIA_DNS" in
        on|off) ;;
        *) die "Некорректный --amnezia-dns='$AWG_AMNEZIA_DNS'. Допустимо: on, off." ;;
    esac
    if [[ "$AWG_AMNEZIA_DNS" == "on" && "$AWG_ROLE" == "exit" ]]; then
        die "--amnezia-dns=on несовместим с --role=exit. AmneziaDNS поднимается на ноде, которая отдаёт конфиги клиентам (single или entry)."
    fi
    export AWG_AMNEZIA_DNS

    # Валидация после CLI override
    validate_port "$AWG_PORT"
    validate_subnet "$AWG_TUNNEL_SUBNET"
    # AWG_ENDPOINT мог прийти из CONFIG_FILE через safe_load_config (без CLI override).
    # Если значение есть и не валидно — log_warn + сброс в "" чтобы инсталлятор
    # вернулся к auto-detect через get_server_public_ip (audit).
    if [[ -n "$AWG_ENDPOINT" ]] && ! validate_endpoint "$AWG_ENDPOINT"; then
        log_warn "AWG_ENDPOINT='$AWG_ENDPOINT' из $CONFIG_FILE не валиден, использую auto-detect."
        AWG_ENDPOINT=""
    fi

    # Запрос у пользователя только на первом запуске
    if [[ "$config_exists" -eq 0 ]]; then
        log "Запрос настроек у пользователя (первый запуск)."
        # Интерактивный ввод: опечатка не убивает установку (валидатор в
        # subshell -> die печатает ошибку, но завершает только subshell, и
        # запрос повторяется). Финальные validate_* вне цикла остаются
        # авторитетными для CLI/конфиг-значений (там die уместен).
        if [[ "$AUTO_YES" -eq 0 ]]; then
            while true; do
                read -rp "Введите UDP порт AmneziaWG (1-65535) [${AWG_PORT}]: " input_port < /dev/tty
                [[ -z "$input_port" ]] && break
                if ( validate_port "$input_port" ); then AWG_PORT=$input_port; break; fi
                log_warn "Повторите ввод порта."
            done
        fi
        validate_port "$AWG_PORT"
        if [[ "$AUTO_YES" -eq 0 ]]; then
            while true; do
                read -rp "Введите подсеть туннеля [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty
                [[ -z "$input_subnet" ]] && break
                if ( validate_subnet "$input_subnet" ); then AWG_TUNNEL_SUBNET=$input_subnet; break; fi
                log_warn "Повторите ввод подсети."
            done
        fi
        validate_subnet "$AWG_TUNNEL_SUBNET"
        if [[ "$DISABLE_IPV6" == "default" ]]; then configure_ipv6; fi
        if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then configure_routing_mode; fi
    else
        log "Используются настройки из $CONFIG_FILE."
        if [[ "$ALLOWED_IPS_MODE" == "3" ]] && [[ -n "$ALLOWED_IPS" ]]; then
            if ! validate_cidr_list "$ALLOWED_IPS"; then
                die "Некорректный ALLOWED_IPS в конфиге: '$ALLOWED_IPS'. Удалите $CONFIG_FILE и запустите установку заново."
            fi
        fi
    fi

    # Согласие на удаление системных пакетов спрашиваем ВНЕ ветвления выше.
    # Раньше вызов стоял только в ветке "конфига нет", и переустановка с --force на
    # уже настроенном сервере проходила мимо вопроса: step99 удаляет файл состояния,
    # поэтому повторный запуск начинается с шага 1 и снова доходит до очистки. У
    # конфигов версий до 5.27.0 записи KEEP_PACKAGES нет вовсе, и она читалась как
    # согласие - то есть issue #213 воспроизводился на версии, которая его чинит.
    # Сама функция выходит сразу, если решение уже принято.
    if [[ -n "$KEEP_PACKAGES" && "$KEEP_PACKAGES" != "0" && "$KEEP_PACKAGES" != "1" ]]; then
        log_warn "В $CONFIG_FILE у KEEP_PACKAGES недопустимое значение '$KEEP_PACKAGES' - считаю, что пакеты надо сохранить."
        KEEP_PACKAGES=1
    fi
    configure_package_cleanup

    # Смена подсети при живых пирах запрещена - проверка до сохранения
    # init-файла и любых изменений на диске (AWG_TUNNEL_SUBNET финален).
    guard_subnet_change_with_peers

    # Значения по умолчанию
    if [[ "$DISABLE_IPV6" == "default" ]]; then DISABLE_IPV6=1; fi
    configure_ipv6_tunnel
    if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then ALLOWED_IPS_MODE=2; fi
    if [[ -z "$ALLOWED_IPS" ]]; then configure_routing_mode; fi

    # Изоляция клиентов (issue #178): выбор + приведение AllowedIPs.
    # Вызов до validate_cidr_list ниже - дописанная подсеть проходит ту же
    # обязательную валидацию, что и остальной список.
    configure_client_isolation
    _apply_isolation_to_allowed_ips

    # Единая обязательная валидация AllowedIPs до сохранения конфига: CLI
    # --route-custom на первом запуске присваивал ALLOWED_IPS без проверки
    # (configure_routing_mode пропускался, т.к. режим уже был 3). Проверяем
    # любой непустой список независимо от источника (CLI / конфиг / выбор режима).
    if [[ -n "$ALLOWED_IPS" ]] && ! validate_cidr_list "$ALLOWED_IPS"; then
        die "Некорректный ALLOWED_IPS: '$ALLOWED_IPS'. Ожидается список x.x.x.x/y[,x.x.x.x/y]."
    fi

    # Имя сервера для vpn:// URI (D#180): выбор источника + валидация.
    configure_server_name

    # Для active awg0 пропускаем проверку только когда он уже слушает именно
    # запрошенный порт. При --port=<новый> проверяем его до остановки VPN.
    local _live_awg_port=""
    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        _live_awg_port=$(sed -n 's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$SERVER_CONF_FILE" 2>/dev/null | tail -1)
    fi
    if [[ -n "$_live_awg_port" && "$_live_awg_port" == "$AWG_PORT" ]]; then
        log "Активный awg0 уже слушает ${AWG_PORT}/udp — порт занят ожидаемым сервисом."
    else
        check_port_availability "$AWG_PORT" || die "Порт $AWG_PORT/udp занят."
    fi

    # Генерация AWG 2.0 параметров
    # Полная перегенерация: первый запуск или override J/S/H-набора.
    # Один --i1-mode меняет только I1 ниже и сохраняет остальные параметры.
    if [[ -z "${AWG_Jc:-}" ]] || [[ -n "${CLI_PRESET:-}" ]] || [[ -n "${CLI_JC:-}" ]] \
        || [[ -n "${CLI_JMIN:-}" ]] || [[ -n "${CLI_JMAX:-}" ]]; then
        # generate_awg_params перегенерирует ВЕСЬ набор (S1-S4, H1-H4, I1), а
        # не только запрошенный параметр: при переустановке поверх живого
        # сервера все выданные клиентские конфиги хранят старые H1-H4 и
        # перестанут подключаться. Предупреждаем громко.
        if [[ "$config_exists" -eq 1 && -n "${AWG_Jc:-}" ]]; then
            log_warn "ВНИМАНИЕ: --preset/--jc/--jmin/--jmax при переустановке перегенерируют ВСЕ параметры обфускации (включая H1-H4/S1-S4/I1)."
            log_warn "Все существующие клиентские конфиги перестанут подключаться - перевыпустите их после установки: sudo bash $MANAGE_SCRIPT_PATH regen"
        fi
        generate_awg_params
    elif [[ -n "${CLI_I1_MODE:-}" ]]; then
        local _i1_matches_mode=0
        case "$CLI_I1_MODE" in
            random) [[ "${AWG_I1:-}" == "<r "*">" ]] && _i1_matches_mode=1 ;;
            quic)   [[ "${AWG_I1:-}" == "<b 0x"*">" ]] && _i1_matches_mode=1 ;;
        esac
        if [[ "${AWG_I1_MODE:-random}" == "$CLI_I1_MODE" && "$_i1_matches_mode" -eq 1 ]]; then
            log "I1 уже соответствует --i1-mode=${CLI_I1_MODE}; сохраняю существующее значение (идемпотентный запуск)."
        else
            if [[ "$config_exists" -eq 1 ]]; then
                log_warn "ВНИМАНИЕ: --i1-mode=${CLI_I1_MODE} изменяет I1. Существующие клиентские конфиги перестанут подключаться - перевыпустите их: sudo bash $MANAGE_SCRIPT_PATH regen"
            fi
            generate_i1_for_mode "$CLI_I1_MODE"
        fi
    else
        log "AWG 2.0 параметры уже заданы из конфига."
    fi

    # CPS (I1) toggle (issue #159): --no-cps убирает параметр I1, из-за которого
    # десктопный AmneziaVPN на macOS виснет при подключении (мобильные и CLI-клиенты
    # CPS понимают). Обнуляем ТОЛЬКО I1, остальной набор обфускации (Jc/S1-S4/H1-H4)
    # не трогаем. Явные --preset/--jc/--jmin/--jmax/--i1-mode без --no-cps возвращают CPS
    # (свежая генерация набора включает I1). Иначе держим состояние из init.
    if [[ "${CLI_NO_CPS:-0}" -eq 1 ]]; then
        NO_CPS=1
    elif [[ -n "${CLI_PRESET:-}" || -n "${CLI_JC:-}" || -n "${CLI_JMIN:-}" || -n "${CLI_JMAX:-}" || -n "${CLI_I1_MODE:-}" ]]; then
        NO_CPS=0
    fi
    if [[ "${NO_CPS:-0}" -eq 1 ]]; then
        if [[ -n "${AWG_I1:-}" && "$config_exists" -eq 1 ]]; then
            log_warn "ВНИМАНИЕ: --no-cps убирает параметр I1 (CPS). Существующие клиентские конфиги с I1 перестанут подключаться - перевыпустите их: sudo bash $MANAGE_SCRIPT_PATH regen"
        fi
        AWG_I1=''
        log "CPS (I1) отключён (--no-cps / сохранённый NO_CPS=1): десктопный AmneziaVPN на macOS не поддерживает CPS."
    fi

    # Сохранение конфигурации
    log "Сохранение настроек в $CONFIG_FILE..."
    # temp в каталоге итогового конфига -> mv = атомарный rename на той же ФС
    # (а не cross-fs copy+unlink, если /tmp смонтирован как tmpfs).
    local temp_conf cfg_dir
    cfg_dir="$(dirname "$CONFIG_FILE")"
    mkdir -p "$cfg_dir" 2>/dev/null
    temp_conf=$(mktemp -p "$cfg_dir") || die "Ошибка mktemp."
    _install_temp_files+=("$temp_conf")
    cat > "$temp_conf" << EOF
# Конфигурация установки AmneziaWG 2.0 (Авто-генерация)
# Используется скриптами установки и управления
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
# Multi-hop (каскад)
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
# IPv6 dual-stack туннель (upstream v5.15.0)
export ALLOW_IPV6_TUNNEL=${ALLOW_IPV6_TUNNEL:-0}
export IPV6_SUBNET='${IPV6_SUBNET}'
export SERVER_HAS_NATIVE_IPV6=${SERVER_HAS_NATIVE_IPV6:-0}
EOF
    # Отложенное удаление UFW-правила старого порта обязано пережить reboot:
    # шаг 4 выполняется в другом процессе после 1-2 перезагрузок, переменная
    # процесса до него не доживает (PR #176). Ключ снимается только на
    # post-commit cleanup после exact-owned UFW delete.
    if [[ "$PREV_AWG_PORT" =~ ^[0-9]+$ ]]; then
        echo "export PREV_AWG_PORT=${PREV_AWG_PORT}" >> "$temp_conf" \
            || die "Ошибка записи PREV_AWG_PORT в $temp_conf"
    fi
    if ! mv "$temp_conf" "$CONFIG_FILE"; then
        rm -f "$temp_conf"
        die "Ошибка сохранения $CONFIG_FILE"
    fi
    chmod 600 "$CONFIG_FILE" || log_warn "Ошибка chmod $CONFIG_FILE"
    log "Настройки сохранены."
    export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS AWG_ENDPOINT
    log "Порт: ${AWG_PORT}/udp"
    log "Подсеть: ${AWG_TUNNEL_SUBNET}"
    log "Откл. IPv6: $DISABLE_IPV6"
    log "Режим AllowedIPs: $ALLOWED_IPS_MODE"
    log "Изоляция клиентов: $( [[ "${CLIENT_ISOLATION:-1}" -eq 1 ]] && echo включена || echo отключена )"

    log "Имя сервера: ${AWG_SERVER_NAME}"
    # Смена режима маршрутизации - операция над клиентскими конфигами: новые
    # клиенты получат новый список, но у существующих regen сознательно
    # сохраняет AllowedIPs (индивидуальные настройки modify). Подсказываем
    # явный способ применить новый режим ко всем (Issue #170).
    if [[ "$config_exists" -eq 1 && "$CLI_ROUTING_MODE" != "default" ]]; then
        log_warn "Режим маршрутизации изменён. Существующие клиентские конфиги сохраняют старые AllowedIPs."
        log_warn "Применить новый режим ко всем клиентам: sudo bash $MANAGE_SCRIPT_PATH regen --reset-routes"
    fi
    # Смена изоляции - та же операция над клиентскими конфигами, что и смена
    # режима маршрутизации: новые клиенты получат новый список, существующие -
    # только через regen --reset-routes (issue #178).
    if [[ "$config_exists" -eq 1 \
          && "$_cfg_client_isolation" != "$CLIENT_ISOLATION" ]]; then
        log_warn "Режим изоляции клиентов изменён. Существующие клиентские конфиги сохраняют старые AllowedIPs."
        log_warn "Применить новый режим ко всем клиентам: sudo bash $MANAGE_SCRIPT_PATH regen --reset-routes"
    fi
    # Смена порта: шаг 6 пропускает уже существующих клиентов, их Endpoint
    # остаётся со старым портом и они молча перестают подключаться. Подсказываем
    # явный перевыпуск - по аналогии с предупреждением о смене режима (#170).
    if [[ "$config_exists" -eq 1 && -n "$PREV_AWG_PORT" ]]; then
        log_warn "Порт изменён (${PREV_AWG_PORT} -> ${AWG_PORT}). Существующие клиентские конфиги сохраняют старый порт в Endpoint и потеряют связь."
        log_warn "Перевыпустить всех клиентов: sudo bash $MANAGE_SCRIPT_PATH regen"
    fi
    # Смена имени сервера (D#180): влияет только на vpn:// URI, существующие
    # .vpnuri сохраняют старое имя до перевыпуска.
    if [[ "$config_exists" -eq 1 && "$_cfg_server_name" != "$AWG_SERVER_NAME" ]]; then
        log_warn "Имя сервера изменено ('${_cfg_server_name}' -> '${AWG_SERVER_NAME}'). Существующие vpn:// ссылки сохраняют старое имя."
        log_warn "Перевыпустить с новым именем: sudo bash $MANAGE_SCRIPT_PATH regen"
    fi

    # Загрузка состояния
    if [[ -f "$STATE_FILE" ]]; then
        current_step=$(cat "$STATE_FILE")
        if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then
            log_warn "$STATE_FILE поврежден."
            current_step=1
            update_state 1
        else
            log "Продолжение с шага $current_step."
        fi
    else
        current_step=1
        log "Начало с шага 1."
        update_state 1
    fi

    # Stale state (прерванный шаг 7 оставляет setup_state=7/99) + CLI-параметры,
    # влияющие на firewall/конфиги: без отката цикл пропустил бы шаги 4-6, новые
    # значения остались бы только в awgsetup_cfg.init, а awg0.conf, клиентские
    # конфиги и правила UFW продолжили бы жить со старыми - молча (Issue #175).
    # Возврат к шагу 4: firewall (порт) + перегенерация конфигов (шаг 6).
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
        log_warn "Незавершённая установка (шаг $current_step) + CLI-параметры конфигурации: возврат к шагу 4, чтобы firewall и конфиги были перегенерированы с новыми значениями."
        current_step=4
        update_state 4
    fi
    _INSTALL_INITIAL_STEP="$current_step"
    log "Шаг 0 завершен."
}

# ==============================================================================
# ШАГ 1: Обновление системы, очистка и оптимизация
# ==============================================================================

step1_update_and_optimize() {
    update_state 1
    log "### ШАГ 1: Обновление, очистка и оптимизация системы ###"

    # Устойчивость к dpkg-lock на первой загрузке сервера: unattended-upgrades
    # и apt-daily нередко держат блокировку несколько минут (issue #150 - тогда
    # apt full-upgrade падал сразу). DPkg::Lock::Timeout заставляет apt дождаться
    # освобождения блокировки, а не завершаться с ошибкой.
    mkdir -p /etc/apt/apt.conf.d
    printf 'DPkg::Lock::Timeout "300";\n' > /etc/apt/apt.conf.d/99-amneziawg-lock-timeout \
        || log_warn "Не удалось записать apt lock-timeout (митигация issue #150)."

    # Очистка ненужных компонентов (ДО обновления для экономии трафика/времени)
    if [[ "$NO_TWEAKS" -eq 1 ]]; then
        log "Пропуск очистки системы (--no-tweaks)."
    elif [[ "$KEEP_PACKAGES" != "0" ]]; then
        # Не строгий ноль - значит либо явный отказ, либо решение неизвестно (пустое или
        # испорченное значение из отредактированного руками конфига). Необратимое удаление
        # делаем только по записанному согласию, всё остальное трактуем как "не трогать".
        log "Пропуск очистки системы: пакеты сохраняются."
        [[ -z "$KEEP_PACKAGES" ]] \
            && log_warn "Согласие на удаление системных пакетов не записано - ничего не удаляю."
    else
        cleanup_system
    fi


    log "Обновление списка пакетов..."
    apt_update_tolerant || die "Ошибка apt update."
    # Кэш свежий: install_packages ниже не должен гонять apt update повторно
    # (источники в шаге 1 не меняются).
    _APT_UPDATED=1

    log "Разблокировка dpkg..."
    if ! apt-get check &>/dev/null; then
        log_warn "dpkg заблокирован или повреждён, исправление..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."
    fi

    # Метапакеты, под которыми висят udev, initramfs-tools и сетевой стек,
    # могли осиротеть: их роняет очистка выше, но точно так же они могут
    # прийти осиротевшими с самим образом. Поэтому блок выполняется БЕЗУСЛОВНО,
    # включая --no-tweaks и --keep-packages, когда очистки не было вовсе.
    # Возвращаем таким пакетам признак manual. Само обновление ниже удалить
    # их уже не может (по Issue #223 команда заменена: у apt-get upgrade
    # такого права нет), но статус "больше не нужен" остаётся ловушкой на
    # будущее: на него вправе опереться любая следующая операция apt. В том
    # числе НАША - install_packages ниже зовёт apt install без --no-remove, -
    # и любой autoremove, который пользователь запустит потом сам.
    # Именно manual, а не hold: hold запретил бы обновление, а обновлять их как
    # раз надо; manual лишь снимает статус "больше не нужен".
    # ⚠️ Разметка ничего не гарантирует: manual-пакет apt тоже вправе снести
    # ради разрешения зависимостей. Гарантией служит проверка
    # _verify_boot_critical перед перезагрузкой.
    #
    # Блок стоит ПОСЛЕ ремонта dpkg выше, и это не косметика: снимок строится
    # опросом dpkg. Заблокированная база отвечает нормально, а вот недоступная
    # или повреждённая даёт пустой ответ на всё сразу, и тогда защита
    # выключилась бы молча вместе с проверкой после обновления, то есть ровно
    # на тех машинах, где дефект и срабатывает. Самопроверка ниже ловит и это.
    _dpkg_usable || die "dpkg не отвечает, а без него не проверить, переживут ли обновление udev и initramfs-tools (Issue #223). Выполните: dpkg --configure -a; apt-get check - и запустите установщик снова."
    # Самопроверка предиката. _dpkg_usable отвечает только за dpkg, а предикат
    # опирается ещё и на awk: сломанный awk вернул бы пустой статус, то есть
    # "отсутствует" сразу для всех, и защита выключилась бы молча.
    _pkg_present dpkg || die "Проверить состояние пакетов не удалось (dpkg-query или awk работают не так, как ожидается). Без этого нельзя убедиться, что обновление не унесёт udev (Issue #223)."
    local critical_before
    critical_before="$(_boot_critical_snapshot)"
    if [[ -n "$critical_before" ]]; then
        log "Под защитой от удаления: $(printf '%s' "$critical_before" | tr '\n' ' ')"
        # udev есть практически на любом сервере Ubuntu и Debian. Его
        # отсутствие означает не "нечего защищать", а что машина, возможно, уже
        # повреждена - например, прерванным прошлым запуском.
        _pkg_installed_ok udev \
            || log_warn "udev не установлен или не настроен. Для Ubuntu и Debian это ненормально: проверьте dpkg-query -W udev, сервер может не загрузиться."
        # Без кавычек намеренно: список приходит именами через перевод строки,
        # и разбиение на аргументы здесь и нужно.
        apt-mark manual $critical_before >/dev/null 2>&1 \
            || log_warn "Не удалось вернуть признак manual пакетам: $(printf '%s' "$critical_before" | tr '\n' ' ') - они останутся в статусе \"больше не нужен\", проверка перед перезагрузкой это поймает."
    else
        log_warn "Ни один пакет из критичного набора не найден установленным. Для Ubuntu и Debian это необычно; проверьте: dpkg-query -W udev"
    fi
    log "Обновление системы..."
    # Именно upgrade --with-new-pkgs, а не full-upgrade. Разница здесь не
    # стилистическая: full-upgrade по определению вправе УДАЛЯТЬ установленные
    # пакеты ради разрешения зависимостей, и в Issue #223 он этим правом
    # воспользовался: унёс udev, после чего сервер перестал грузиться. У
    # upgrade такого права нет вовсе: пакет, который нельзя обновить без
    # удаления соседа, просто остаётся необновлённым.
    # --with-new-pkgs сохраняет единственное, ради чего здесь был нужен
    # full-upgrade: новое ядро приезжает пакетом с НОВЫМ именем
    # (linux-image-6.8.0-NNN-generic), а обычный upgrade новые имена ставить
    # отказывается.
    # Размен осознанный: VPN-серверу нужно не то, чтобы systemd был
    # непременно свежим, а то, чтобы машина загрузилась. Проверка
    # перед перезагрузкой остаётся вторым рубежом.
    if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --with-new-pkgs; then
        local _lock_holder
        _lock_holder="$(fuser /var/lib/dpkg/lock-frontend 2>/dev/null | tr -s ' ' || true)"
        if [[ -n "$_lock_holder" ]]; then
            log_warn "dpkg-lock занят процессами:${_lock_holder} (обычно first-boot unattended-upgrades)."
        fi
        log_warn "Обновление не прошло, чиню dpkg и повторяю..."
        DEBIAN_FRONTEND=noninteractive dpkg --configure -a || true
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --with-new-pkgs || _die_upgrade_failed
    fi
    _warn_kept_back
    log "Система обновлена."


    install_packages curl wget gpg sudo ethtool

    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        # Оптимизация системы
        optimize_system
        # Настройка sysctl
        setup_advanced_sysctl
    else
        log "Пропуск оптимизации и hardening (--no-tweaks)."
        setup_minimal_sysctl
    fi

    # Проверяем ПОСЛЕДНИМ действием шага: после этой строки не выполняется
    # ничего, что могло бы удалить пакет.
    _verify_boot_critical "$critical_before"

    log "Шаг 1 успешно завершен."
    request_reboot 2
}

# ==============================================================================
# Поддержка предсобранных пакетов для ARM
# ==============================================================================

# _try_install_prebuilt_arm — скачать и установить предсобранный .deb для
# текущего ARM-ядра из релиза arm-packages на GitHub.
#
# Возвращает 0 при успехе, 1 если совпадений нет или установка не удалась
# (в этом случае вызывающий код переходит к DKMS).
_try_install_prebuilt_arm() {
    local kernel arch target_id asset_name asset_url tmpfile tmpsha expected_sha actual_sha
    kernel="$(uname -r)"
    arch="$(dpkg --print-architecture)"

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
        log "Предсобранный пакет для ядра $kernel ($arch) не найден"
        return 1
    fi

    asset_name="amneziawg-kmod-${target_id}_${kernel}_${arch}.deb"
    asset_url="https://github.com/bivlked/amneziawg-installer/releases/download/arm-packages/${asset_name}"

    log "Попытка установки предсобранного пакета: $asset_name"
    tmpfile="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb)"
    tmpsha="$(mktemp /tmp/amneziawg-prebuilt-XXXXXX.deb.sha256)"

    # Сначала скачиваем контрольную сумму SHA256
    if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpsha" "${asset_url}.sha256" 2>/dev/null; then
        log "Предсобранный пакет недоступен для $kernel — используется DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi

    if curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
            -o "$tmpfile" "$asset_url" 2>/dev/null; then
        # Проверяем целостность перед установкой модуля ядра
        expected_sha="$(cat "$tmpsha")"
        actual_sha="$(sha256sum "$tmpfile" | awk '{print $1}')"
        rm -f "$tmpsha"
        if [[ "$expected_sha" != "$actual_sha" ]]; then
            log_warn "Несовпадение SHA256 предсобранного пакета — скачивание отклонено"
            rm -f "$tmpfile"
            return 1
        fi

        log "Пакет скачан (SHA256 OK), установка..."
        if dpkg -i "$tmpfile" 2>/dev/null; then
            rm -f "$tmpfile"
            log "Предсобранный пакет установлен: $asset_name"
            return 0
        else
            log_warn "Ошибка установки (несовпадение vermagic или повреждённый пакет)"
            rm -f "$tmpfile"
            return 1
        fi
    else
        log "Предсобранный пакет недоступен для $kernel — используется DKMS"
        rm -f "$tmpfile" "$tmpsha"
        return 1
    fi
}

# H0 (AWG 3.0, 31 jul 2026): на ядрах < 6.7 актуальный PPA-модуль = AmneziaWG 3.0,
# и мы его туда сознательно не пускаем (почему именно - см. _kernel_supports_awg3).
# Устанавливаем ПИНОВЫЙ последний 2.0-модуль (линия 1.0.x) из исходника через DKMS:
#   1. git clone пинового тега --depth=1;
#   2. СВЕРКА commit с AWG2_PIN_COMMIT (integrity: immutable-коммит надёжнее, чем
#      SHA авто-tarball GitHub, который меняется при смене компрессии);
#   3. upstream-механизм `make dkms-install` (кладёт в /usr/src/amneziawg-1.0.0);
#   4. dkms add/build/install под текущее ядро;
#   5. modprobe-проверка (собран != загружаем: Secure Boot может блокировать).
# dkms.conf исходника несёт AUTOINSTALL=yes, поэтому наш helper amneziawg-ensure-
# module (apt-hook + systemd) пересоберёт пиновый модуль при апгрейде ядра сам -
# отдельный maintenance-код не нужен. Возврат: 0 успех, 1 провал (лог в ERROR).
_install_pinned_awg2_module() {
    local repo="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git"
    local kver work got_commit
    local dkms_ver="1.0.0"   # WIREGUARD_VERSION в upstream Makefile (имя /usr/src/amneziawg-<ver>)
    kver="$(uname -r)"

    if ! command -v git >/dev/null 2>&1; then
        log_error "git не установлен - невозможно получить пиновый исходник модуля."
        return 1
    fi

    work="$(mktemp -d /tmp/awg2-pin-XXXXXX)" || { log_error "mktemp -d не удался."; return 1; }

    log "Клонирование пинового исходника AmneziaWG 2.0 ($AWG2_PIN_TAG)..."
    if ! git clone --depth=1 --branch "$AWG2_PIN_TAG" "$repo" "$work/src" >/dev/null 2>&1; then
        log_error "Не удалось клонировать $repo (тег $AWG2_PIN_TAG). Проверьте доступ к github.com."
        rm -rf "$work"; return 1
    fi

    got_commit="$(git -C "$work/src" rev-parse HEAD 2>/dev/null || echo "")"
    if [[ "$got_commit" != "$AWG2_PIN_COMMIT" ]]; then
        log_error "Пин-проверка не пройдена: тег $AWG2_PIN_TAG -> commit '${got_commit:-<пусто>}',"
        log_error "ожидался $AWG2_PIN_COMMIT. Отказ (возможна подмена/перемещение тега)."
        rm -rf "$work"; return 1
    fi
    log "Пин-коммит подтверждён: $got_commit"

    # Разложить DKMS-исходник upstream-механизмом (Makefile лежит в src/ подпапке).
    # Вывод make сохраняем в лог: реальную причину сбоя (окружение/coreutils) иначе
    # не увидеть - в отличие от dkms build, тут make.log не создаётся.
    local _mklog="/var/log/amneziawg-pin-dkms-install.log"
    if ! make -C "$work/src/src" dkms-install PREFIX=/usr >"$_mklog" 2>&1; then
        log_error "make dkms-install не удался. Подробности: $_mklog"
        rm -rf "$work"; return 1
    fi
    rm -rf "$work"

    if [[ ! -f "/usr/src/amneziawg-${dkms_ver}/dkms.conf" ]]; then
        log_error "/usr/src/amneziawg-${dkms_ver}/dkms.conf не появился после dkms-install."
        return 1
    fi

    # add идемпотентен: при повторном запуске уже добавлен -> не фатально.
    dkms add -m amneziawg -v "$dkms_ver" >/dev/null 2>&1 || true
    # Идемпотентность (установщик - возобновляемая машина состояний): dkms build на
    # уже собранном ядре возвращает ошибку "already built" -> собираем ТОЛЬКО если
    # для этого ядра сборки ещё нет. install --force ниже идемпотентен сам по себе.
    if dkms status -m amneziawg -v "$dkms_ver" -k "$kver" 2>/dev/null | grep -qE ': (built|installed)'; then
        log "Пиновый 2.0-модуль уже собран для ядра $kver - пропускаю dkms build."
    else
        log "Сборка пинового 2.0-модуля через DKMS (ядро $kver)..."
        if ! dkms build -m amneziawg -v "$dkms_ver" -k "$kver" >/dev/null 2>&1; then
            log_error "DKMS build пинового 2.0-модуля не удался. Смотрите /var/lib/dkms/amneziawg/${dkms_ver}/${kver}/*/log/make.log"
            return 1
        fi
    fi
    if ! dkms install -m amneziawg -v "$dkms_ver" -k "$kver" --force >/dev/null 2>&1; then
        log_error "DKMS install пинового 2.0-модуля не удался."
        return 1
    fi

    # Собран != загружаем: при включённом Secure Boot неподписанный модуль не грузится.
    if ! modprobe amneziawg 2>/dev/null; then
        log_error "Модуль собран, но modprobe amneziawg не загрузил его."
        log_error "Вероятная причина - Secure Boot: неподписанный DKMS-модуль блокируется."
        log_error "Отключите Secure Boot в BIOS/UEFI VPS либо зарегистрируйте MOK-ключ."
        return 1
    fi
    log "Пиновый AmneziaWG 2.0-модуль собран и загружен (DKMS $dkms_ver, ядро $kver)."
    return 0
}

# ==============================================================================
# ШАГ 2: Установка AmneziaWG и зависимостей
# ==============================================================================

step2_install_amnezia() {
    update_state 2

    # Guard: убедиться что юзер действительно перезагрузился перед step 2.
    # Если boot_id совпадает с сохранённым в request_reboot 2 — reboot
    # не произошёл (например, юзер случайно запустил скрипт повторно).
    # В этом случае обновление из step 1 могло подложить новое ядро на диск,
    # но работающее ядро всё ещё старое → DKMS соберёт модуль под старое,
    # после следующего reboot modprobe упадёт.
    local boot_id_file="$AWG_DIR/.boot_id_before_step2"
    if [[ -f "$boot_id_file" ]] && [[ -r /proc/sys/kernel/random/boot_id ]]; then
        local saved_boot_id current_boot_id
        saved_boot_id=$(< "$boot_id_file")
        current_boot_id=$(< /proc/sys/kernel/random/boot_id)
        if [[ -n "$saved_boot_id" ]] && [[ "$saved_boot_id" == "$current_boot_id" ]]; then
            die "Ожидалась перезагрузка перед шагом 2 (kernel upgrade активируется только после reboot). Выполните: sudo reboot — и запустите скрипт снова."
        fi
        log "Подтверждена перезагрузка (boot_id изменился) — продолжаем шаг 2"
        rm -f "$boot_id_file" 2>/dev/null || true
    fi

    log "### ШАГ 2: Установка AmneziaWG и зависимостей ###"
    _APT_UPDATED=0  # Reset: new sources will be added in this step

    # --ppa-amnezia-tolerant ОБЯЗАТЕЛЕН уже здесь: если на диске остался
    # PPA-файл с битым suite (404 Release; например questing от старой версии
    # или после in-place upgrade), строгий update умирал ДО repair-блоков ниже
    # и ремонт никогда не срабатывал (live-репро на Debian 12, v5.16.0 cycle).
    # Ошибки базовых репозиториев по-прежнему fail-closed; PPA-ошибки чинит
    # repair + post-PPA update + apt_wait_for_ppa_package ниже.
    apt_update_tolerant --ppa-amnezia-tolerant || die "Ошибка apt update."

    # PPA Amnezia (без software-properties-common)
    log "Добавление PPA Amnezia..."

    # Определение codename для PPA
    # На Debian маппим на ближайший Ubuntu codename, т.к. PPA — это Launchpad (Ubuntu)
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
            # Для Ubuntu non-LTS (questing/plucky/oracular/...) PPA Amnezia
            # пакетов не публикует — там 404 на dists/<codename>/Release.
            # Проверяем доступность через HEAD-запрос и переключаемся на
            # noble (LTS): сборка для noble корректно DKMS-собирается под
            # текущее ядро.
            # Связано: amnezia-vpn/amneziawg-linux-kernel-module#118
            case "$ppa_codename" in
                noble|jammy|focal)
                    # Known LTS — пропускаем pre-check (PPA точно опубликован)
                    ;;
                *)
                    log "Проверка доступности PPA Amnezia для Ubuntu '${ppa_codename}'..."
                    if ! curl -fsI --max-time 15 --retry 2 --retry-delay 5 \
                        "https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/${ppa_codename}/Release" \
                        >/dev/null 2>&1; then
                        log_warn "PPA Amnezia не публикует пакеты для Ubuntu '${ppa_codename}' (HTTP 404 или host недоступен)."
                        log_warn "Переключаюсь на 'noble' — DKMS соберёт модуль под текущее ядро."
                        log_warn "Контекст: https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/118"
                        ppa_codename="noble"
                    else
                        log "PPA Amnezia доступен для '${ppa_codename}'."
                    fi
                    ;;
            esac
            ;;
    esac

    local keyring_dir="/etc/apt/keyrings"
    local keyring_file="${keyring_dir}/amnezia-ppa.gpg"
    local ppa_sources="/etc/apt/sources.list.d/amnezia-ppa.sources"
    local ppa_list="/etc/apt/sources.list.d/amnezia-ppa.list"
    # Проверка на legacy-файлы (от add-apt-repository предыдущих версий)
    local legacy_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.list"
    local legacy_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-${codename}.sources"
    # Повторный запуск на сервере, где предыдущий (≤ v5.12.1) создал .sources
    # с «битым» Suites=questing/plucky/etc.: если найденный suite не совпадает
    # с целевым ppa_codename — удаляем файл, чтобы пересоздать ниже с правильным.
    # Та же проверка для устаревшего .sources (формат от add-apt-repository).
    # Если файл существует, но строка `Suites:` не парсится — считаем повреждённым
    # и тоже пересоздаём, иначе сломанный файл проскочит как «PPA уже добавлен».
    local existing_suite=""
    if [[ -f "$ppa_sources" ]]; then
        existing_suite=$(awk '/^Suites:/{print $2; exit}' "$ppa_sources" 2>/dev/null)
    fi
    if [[ -f "$ppa_sources" && ( -z "$existing_suite" || "$existing_suite" != "$ppa_codename" ) ]]; then
        if [[ -z "$existing_suite" ]]; then
            log_warn "$ppa_sources существует, но строка Suites: не найдена — пересоздание."
        else
            log_warn "Существующий PPA suite='${existing_suite}', целевой='${ppa_codename}' — пересоздание $ppa_sources."
        fi
        rm -f "$ppa_sources" "$ppa_list"
    fi
    local legacy_suite=""
    if [[ -f "$legacy_sources" ]]; then
        legacy_suite=$(awk '/^Suites:/{print $2; exit}' "$legacy_sources" 2>/dev/null)
    fi
    if [[ -f "$legacy_sources" && ( -z "$legacy_suite" || "$legacy_suite" != "$ppa_codename" ) ]]; then
        log_warn "Устаревший PPA-файл $legacy_sources (suite='${legacy_suite:-<пусто>}') не соответствует целевому '${ppa_codename}' — удаление."
        rm -f "$legacy_sources" "$legacy_list"
    fi
    # Тот же ремонт для traditional .list (Debian 12): suite - токен после URL
    # в строке 'deb [opts] URL <suite> main'. Без проверки файл со старым/чужим
    # suite (например после in-place upgrade bookworm->trixie) проскочил бы
    # ниже как "PPA уже добавлен", и apt продолжил бы тянуть не тот suite.
    local list_suite=""
    if [[ -f "$ppa_list" ]]; then
        list_suite=$(awk '/^deb([[:space:]]|$)/ {
            for (i = 2; i <= NF; i++) {
                if ($i ~ /^https?:/) { print $(i+1); exit }
            }
        }' "$ppa_list" 2>/dev/null)
        if [[ -z "$list_suite" || "$list_suite" != "$ppa_codename" ]]; then
            log_warn "Существующий $ppa_list (suite='${list_suite:-<пусто>}') не соответствует целевому '${ppa_codename}' - пересоздание."
            rm -f "$ppa_list"
        fi
    fi
    if [[ -f "$legacy_list" ]] || [[ -f "$legacy_sources" ]]; then
        log "PPA уже добавлен (legacy-формат)."
    elif [[ -f "$ppa_sources" ]] || [[ -f "$ppa_list" ]]; then
        log "PPA уже добавлен."
    else
        mkdir -p "$keyring_dir"
        log "Импорт GPG ключа Amnezia PPA..."
        # Atomic: pipe в temp, затем mv — полу-записанный keyring никогда не
        # окажется на целевом пути, даже если curl/gpg упали mid-way.
        local _kf_tmp
        _kf_tmp=$(mktemp -p "$keyring_dir" ".amnezia-ppa.gpg.tmp.XXXXXX") \
            || die "Не удалось создать временный файл для GPG ключа."
        # --batch --no-tty --yes: gpg не открывает /dev/tty (non-interactive
        # SSH, cloud-init, Ansible и т.п.) и не падает с "File exists" при
        # overwrite mktemp-файла. Без этих флагов gpg в батч-режиме откажется
        # писать в уже существующий пустой tmp-файл от mktemp.
        # Запрос по ПОЛНОМУ 40-символьному fingerprint, не по короткому ID:
        # для коротких 32-битных ID существуют preimage-коллизии (evil32), а
        # keyserver.ubuntu.com принимает загрузку чужих ключей. Подменённый
        # ключ не дал бы RCE (подпись пакетов не сойдётся), но ломал бы
        # установку малопонятной ошибкой apt.
        local _ppa_key_fpr="75C9DD72C799870E310542E24166F2C257290828"
        if ! curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${_ppa_key_fpr}" \
             | gpg --batch --no-tty --yes --dearmor -o "$_kf_tmp"; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "Ошибка импорта GPG ключа Amnezia PPA."
        fi
        # Сверка fingerprint скачанного ключа с ожидаемым (pin).
        local _got_fpr
        _got_fpr=$(gpg --batch --no-tty --show-keys --with-colons "$_kf_tmp" 2>/dev/null \
            | awk -F: '/^fpr:/{print $10; exit}')
        if [[ "$_got_fpr" != "$_ppa_key_fpr" ]]; then
            rm -f "$_kf_tmp" 2>/dev/null
            die "GPG ключ Amnezia PPA не прошёл проверку fingerprint (получен: '${_got_fpr:-<пусто>}')."
        fi
        chmod 644 "$_kf_tmp" || { rm -f "$_kf_tmp" 2>/dev/null; die "Ошибка chmod GPG ключа."; }
        mv -f "$_kf_tmp" "$keyring_file" \
            || { rm -f "$_kf_tmp" 2>/dev/null; die "Ошибка перемещения GPG ключа."; }

        # Debian 12 использует traditional .list формат, Debian 13+ и Ubuntu 24.04+ — DEB822 .sources
        if [[ "${OS_ID:-ubuntu}" == "debian" && "${OS_VERSION}" == "12" ]]; then
            log "Debian 12: используем традиционный формат .list"
            echo "deb [signed-by=${keyring_file}] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${ppa_codename} main" \
                > "$ppa_list" || die "Ошибка создания $ppa_list"
            chmod 644 "$ppa_list"
        else
            cat > "$ppa_sources" <<PPASRC || die "Ошибка создания sources PPA."
Types: deb
URIs: https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu
Suites: ${ppa_codename}
Components: main
Signed-By: ${keyring_file}
PPASRC
            chmod 644 "$ppa_sources"
        fi
        log "PPA добавлен."
    fi
    # apt-get update + классификация ошибок:
    #   - Ошибки ТОЛЬКО на PPA Amnezia → продолжаем, apt_wait_for_ppa_package
    #     ниже сделает retry (issue #68: ppa.launchpadcontent.net коротко лежит).
    #   - Любая другая non-source ошибка (DNS / GPG mismatch / dpkg lock на base
    #     mirror) → fall-fail. Продолжать на stale apt-cache небезопасно —
    #     следующий apt-get install упадёт с менее actionable сообщением
    #     (PR #69 review finding).
    if ! apt_update_tolerant --ppa-amnezia-tolerant; then
        log_error "apt-get update завершился с hard error — не PPA outage (issue #68)."
        log_error "Проверьте: DNS, доступ к archive.ubuntu.com / deb.debian.org,"
        log_error "целостность ключей в /etc/apt/keyrings, занятость dpkg lock."
        die "apt update вернул ошибку (rc!=0, не PPA Amnezia)."
    fi
    # PPA добавлен, кэш обновлён: дальше в шаге 2 источники не меняются,
    # поэтому install_packages не должен повторять apt update (на медленных
    # зеркалах каждый прогон = 10-60 секунд).
    _APT_UPDATED=1
    # apt-get update толерантен к недоступному InRelease (rc=0 даже когда PPA
    # лежит). Поэтому проверяем именно появление пакета amneziawg-dkms в
    # apt-cache, с тремя попытками и backoff 30с/60с (≈1.5 мин total).
    # Кратковременный outage ppa.launchpadcontent.net (issue #68) не должен
    # валить установку.
    if ! apt_wait_for_ppa_package amneziawg-dkms 3 30; then
        log_error "Пакет amneziawg-dkms не появился в apt-cache после 3 попыток."
        log_error "Похоже, ppa.launchpadcontent.net сейчас недоступен — это outage"
        log_error "инфраструктуры Launchpad, не баг скрипта."
        log_error "Подождите 10–15 минут и запустите скрипт снова той же командой."
        log_error "Подробнее: https://github.com/bivlked/amneziawg-installer/issues/68"
        die "PPA Amnezia временно недоступен."
    fi

    # Пакеты AmneziaWG + qrencode (БЕЗ Python!)
    log "Установка пакетов AmneziaWG..."

    # H0 (AWG 3.0, 31 jul 2026): путь пинового 2.0-модуля определяем ДО любой
    # установки пакетов - hold обязан стоять раньше даже ARM-пути с предсобранным
    # .deb, где install_packages ставит amneziawg-tools, чьи Recommends иначе
    # подтянут 3.0-модуль в обход гейта. На ядрах < 6.7 PPA-модуль = AmneziaWG 3.0,
    # его здесь не ставим (сознательно, см. _kernel_supports_awg3), а собираем
    # пиновый 2.0 из исходника; из PPA берём только tools (version-aware, с 2.0
    # работают - проверено).
    local use_pinned_awg2=0
    if ! _kernel_supports_awg3; then
        use_pinned_awg2=1
        log "Ядро $(uname -r) старее 6.7 - здесь ставим проверенный модуль AmneziaWG 2.0, а не 3.0 из PPA."
        log "Активирован путь пинового AmneziaWG 2.0-модуля из исходника ($AWG2_PIN_TAG)."
        # Re-entry: если прошлый прогон/стоковый установщик успел поставить (или
        # оставить полу-настроенным) 3.0-пакет - убрать его и его исходник, иначе
        # его failing postinst и владение /usr/src/amneziawg-* конфликтуют со сборкой.
        if dpkg -l amneziawg-dkms 2>/dev/null | grep -qE '^(ii|iU|iF|iH|rc)'; then
            log "Обнаружен ранее установленный amneziawg-dkms (AmneziaWG 3.0) - удаляю перед пиновой сборкой."
            DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg >/dev/null 2>&1 \
                || dpkg --purge --force-all amneziawg-dkms amneziawg >/dev/null 2>&1 \
                || log_warn "Не удалось полностью удалить ранее установленный amneziawg-dkms - установка ниже может упасть."
            command -v dkms >/dev/null 2>&1 && dkms remove -m amneziawg -v 1.0.0 --all >/dev/null 2>&1 || true
            rm -rf /var/lib/dkms/amneziawg* /usr/src/amneziawg-* 2>/dev/null || true
        fi
        # ⚠️ Hold ДО любой установки: amneziawg-tools РЕКОМЕНДУЕТ amneziawg-dkms, apt
        # по умолчанию ставит recommends -> без hold установка tools (в т.ч. на ARM-
        # пути) притащила бы 3.0-dkms, и в системе оказались бы ДВА DKMS-дерева с
        # одним именем модуля amneziawg - пиновое 2.0 и пакетное 3.0. Это защитный
        # механизм, поэтому провал фатален (проверяем, что hold реально встал).
        apt-mark hold amneziawg-dkms amneziawg >/dev/null 2>&1 || true
        # Проверяем именно amneziawg-dkms - это несущий пакет: его РЕКОМЕНДУЕТ
        # amneziawg-tools и он несёт 3.0-модуль. Метапакет amneziawg держать не
        # обязательно (его Depends: amneziawg-dkms всё равно held), поэтому его
        # отдельно не верифицируем.
        if ! apt-mark showhold 2>/dev/null | grep -qx "amneziawg-dkms"; then
            die "Не удалось зафиксировать amneziawg-dkms в hold. Без этого установка amneziawg-tools подтянет из PPA модуль AmneziaWG 3.0 в обход выбранного пути. Прервано (проверьте apt/dpkg lock)."
        fi
    else
        # Ядро >= 6.7: нормальный путь ставит amneziawg-dkms из PPA. Снять возможный
        # hold от прежнего пинового прогона (иначе apt install -y прервётся на held).
        apt-mark unhold amneziawg-dkms amneziawg >/dev/null 2>&1 || true
    fi

    # На ARM: сначала пробуем предсобранный .deb (не требует build-tools и headers).
    # Откат на DKMS если совпадения нет или скачивание не удалось.
    # ⚠️ На ядре < 6.7 (use_pinned_awg2=1) предсобранный .deb использовать БЕЗОПАСНО:
    # наши ARM-пребилты собираются из scripts/arm-module-version.txt, запиненного на
    # тот же 2.0-тег (v1.0.20260725) и залоченного тестом, то есть это ЗАВЕДОМО 2.0-
    # модуль, а не 3.0. ⚠️ Это ЕДИНСТВЕННАЯ гарантия, и её достаточно. Прежний второй
    # довод - "3.0 под ядро < 6.7 всё равно не скомпилируется, значит 3.0-ассета для
    # debian-bookworm-arm64 в релизе быть не может" - с 31 jul 2026 НЕВЕРЕН (upstream
    # починил сборку, v3.0.20260731-04), опираться на него нельзя. При отсутствии
    # совпадения _try_install_prebuilt_arm вернёт 1 и мы уйдём в проверяемую сборку
    # из исходника ниже. hold, выставленный выше, здесь тоже в силе (не даёт tools
    # подтянуть 3.0-dkms через Recommends).
    local arch
    arch="$(uname -m)"
    if [[ "$arch" == "aarch64" || "$arch" == "armv7l" ]]; then
        if _try_install_prebuilt_arm; then
            log "Модуль ядра установлен из предсобранного пакета. Установка утилит из PPA..."
            # 🔴 Hold ОБЯЗАТЕЛЕН и здесь, НЕЗАВИСИМО от версии ядра. Выше он
            # ставится только на пиновом пути (ядро < 6.7), а в ветке >= 6.7
            # делается apt-mark unhold - и этот ARM-блок идёт ПОСЛЕ гейта.
            # Предсобранный пакет называется amneziawg-kmod-<KERNEL_ID> и не
            # объявляет Provides: amneziawg-modules, поэтому альтернативу из
            # Recommends пакета amneziawg-tools (по живым метаданным PPA:
            # "amneziawg-modules (>= 0.0.20171001) | amneziawg-dkms (>= ...)")
            # он НЕ удовлетворяет, а самого amneziawg-modules в PPA нет.
            # install_packages ставит через apt install -y С рекомендациями,
            # значит без hold apt дотянул бы amneziawg-dkms из PPA, и рядом с
            # нашим 2.0-модулем в extra/ встало бы 3.0-дерево в updates/dkms/.
            # Два дерева с модулем ОДНОГО имени - ровно то, от чего hold нужен.
            # Достижимо: target-ы пребилдов ubuntu-2510-arm64 и
            # debian-trixie-arm64 - это ядра 6.7+.
            apt-mark hold amneziawg-dkms amneziawg >/dev/null 2>&1 || true
            if ! apt-mark showhold 2>/dev/null | grep -qx "amneziawg-dkms"; then
                die "Не удалось зафиксировать amneziawg-dkms в hold перед установкой amneziawg-tools. Без этого рядом с предсобранным модулем встал бы модуль из PPA - два дерева с именем amneziawg. Проверьте apt/dpkg lock и запустите скрипт снова: предсобранный пакет уже установлен, шаг выполнится заново."
            fi
            install_packages "amneziawg-tools" "wireguard-tools" "qrencode"
            # ПОСТУСЛОВИЕ. Выше проверена ПРЕДПОСЫЛКА (hold стоит), а результат
            # не проверял никто - между ними apt мог поставить пакет по любой
            # причине, которую мы не предусмотрели, либо dkms остался с прошлой
            # установки этого же хоста. Проверяем факт, а не предпосылку: именно
            # он ловит настоящий отказ.
            # ⚠️ Здесь НЕ die, и это осознанно: сценарий "dkms остался с прошлого
            # прогона" - это уже сломанное состояние, но обрывать установку на
            # нём мы не готовы без прогона на ARM-стенде, а без пути к починке
            # обрыв оставит человека ни с чем. Поэтому громкое предупреждение с
            # точной командой. Ужесточение до die - отдельная задача.
            if dpkg-query -W -f='${Status}' amneziawg-dkms 2>/dev/null | grep -q "ok installed"; then
                log_warn "ВНИМАНИЕ: рядом с предсобранным модулем в системе стоит пакет amneziawg-dkms."
                log_warn "  Чем это кончится - измерено на стенде, а не предположено: как только в"
                log_warn "  системе окажутся kernel-headers, DKMS соберётся, ВЫТЕСНИТ файл пребилда из"
                log_warn "  extra/ и после перезагрузки загрузится он, то есть сервер молча перейдёт"
                log_warn "  на другую линию протокола. Туннель при этом работать не перестанет, а"
                log_warn "  dpkg продолжит считать предсобранный пакет установленным."
                log_warn "  Убрать лишнее: sudo apt-mark unhold amneziawg-dkms && sudo apt-get purge -y amneziawg-dkms"
                log_warn "  затем sudo apt-mark hold amneziawg-dkms, переустановка модуля и перезагрузка."
            fi
            log "Шаг 2 завершен (prebuilt ARM)."
            _boot_critical_guard
            # request_reboot всегда завершает процесс (exit), сюда не вернёмся.
            request_reboot 3
        fi
        log "Совпадений не найдено — откат на DKMS."
    fi

    # Пакеты: на пиновом пути (ядро < 6.7) amneziawg-dkms НЕ ставим (это был бы
    # 3.0-модуль), вместо него git для сборки пинового 2.0-исходника. Гейт, hold и
    # очистка ранее установленного 3.0 выполнены выше (до ARM-блока).
    local packages
    if [[ "$use_pinned_awg2" -eq 1 ]]; then
        packages=("amneziawg-tools" "wireguard-tools" "dkms"
                  "build-essential" "dpkg-dev" "git" "qrencode")
    else
        packages=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms"
                  "build-essential" "dpkg-dev" "qrencode")
    fi

    # Linux headers: на Debian может не быть точного linux-headers-$(uname -r)
    local current_headers
    current_headers="linux-headers-$(uname -r)"
    if dpkg -s "$current_headers" &>/dev/null || apt-cache show "$current_headers" &>/dev/null 2>&1; then
        packages+=("$current_headers")
    else
        log_warn "Нет headers для $(uname -r), установка общего пакета..."
        local kernel_release
        kernel_release="$(uname -r)"
        if [[ "$kernel_release" == *+rpt* || "$kernel_release" == *-rpi* ]]; then
            # Ядро Raspberry Pi Foundation (+rpt suffix) — использовать мета-пакет RPi
            # linux-headers-rpi-2712: Pi 5 / Cortex-A76; linux-headers-rpi-v8: Pi 3/4 arm64
            local rpi_headers
            if [[ "$kernel_release" == *2712* ]]; then
                rpi_headers="linux-headers-rpi-2712"
            else
                rpi_headers="linux-headers-rpi-v8"
            fi
            log "Обнаружено ядро Raspberry Pi, используем $rpi_headers"
            packages+=("$rpi_headers")
        elif [[ "${OS_ID:-ubuntu}" == "debian" ]]; then
            # На Debian: linux-headers-$(dpkg --print-architecture)
            local arch_pkg
            arch_pkg="linux-headers-$(dpkg --print-architecture 2>/dev/null || echo "amd64")"
            packages+=("$arch_pkg")
        else
            packages+=("linux-headers-generic")
        fi
    fi
    # v5.13.0: на 25.10/26.04 после in-place upgrade с 24.04 в системе могут
    # остаться kernel headers от 24.04 (6.8.x), скомпилированные gcc-13. В
    # 25.10 по умолчанию ставится только gcc-15 → dkms autoinstall в postinst
    # пакета amneziawg-dkms падает при сборке под устаревшие ядра, и dpkg
    # оставляет amneziawg* unconfigured. Если в системе обнаружены kernel
    # headers, отличные от running, заранее доставляем gcc-13 (доступен в
    # questing/universe и 26.04 archive), чтобы autoinstall прошёл для всех
    # ядер.
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
            log "Обнаружены устаревшие kernel headers (≠ $_running_kernel) — устанавливаю gcc-13 для совместимости DKMS autoinstall."
            DEBIAN_FRONTEND=noninteractive apt install -y gcc-13 \
                || log_warn "Не удалось установить gcc-13 — DKMS autoinstall может падать на устаревших ядрах."
        else
            log_warn "Обнаружены устаревшие kernel headers, но gcc-13 недоступен в repo — DKMS autoinstall может падать."
        fi
    fi
    install_packages "${packages[@]}"

    # H0: пиновый путь - собрать 2.0-модуль из исходника ВМЕСТО PPA-amneziawg-dkms.
    # Headers текущего ядра уже установлены выше (в packages); hold выставлен ранее.
    if [[ "$use_pinned_awg2" -eq 1 ]]; then
        if ! _install_pinned_awg2_module; then
            log_error "Не удалось установить пиновый AmneziaWG 2.0-модуль."
            log_error "На ядрах старее 6.7 (у вас $(uname -r)) установщик берёт модуль не из"
            log_error "PPA, а собирает из исходника, и этот шаг не прошёл. Конкретная причина -"
            log_error "в строках выше; чаще всего это отсутствующие kernel headers, нехватка"
            log_error "места, оборванная сеть или собранный, но не загружаемый модуль (Secure"
            log_error "Boot). Запасной вариант: развернуть сервер на Ubuntu 24.04/25.10 или"
            log_error "Debian 13, где модуль приходит пакетом из PPA. См. README/INSTALL_VPS."
            die "Пиновый AmneziaWG 2.0-модуль не установлен."
        fi
        log "Пиновый AmneziaWG 2.0-модуль установлен; PPA-dkms в hold (защита от 3.0)."
    fi

    # v5.12.0: мета-пакет linux-headers, чтобы apt автоматически подтягивал
    # заголовки при kernel upgrade. Без меты ставится только
    # linux-headers-$(uname -r) — он не tracking новые ядра, и на следующем
    # apt upgrade DKMS-модуль не успеет пересобраться.
    #
    # Detect kernel flavor (Ubuntu cloud images: aws/azure/gcp/oracle/kvm/
    # lowlatency/raspi; Debian cloud-amd64) — обычный linux-headers-generic
    # на Azure-VM tracking не тот kernel-pipeline. Берём суффикс uname -r,
    # пробуем flavor-specific meta, fallback на generic/arch.
    local arch_meta kernel_rel
    arch_meta="$(dpkg --print-architecture 2>/dev/null || echo '')"
    kernel_rel="$(uname -r)"
    local -a meta_candidates=()
    if [[ "$kernel_rel" == *+rpt* || "$kernel_rel" == *-rpi* ]]; then
        : # RPi: мета linux-headers-rpi-{2712,v8} уже добавлена в packages выше.
    elif [[ "${OS_ID:-ubuntu}" == "ubuntu" ]]; then
        # Ubuntu uname -r формат: 6.8.0-49-generic / 6.8.0-1009-aws / ...
        local flavor="${kernel_rel##*-}"
        if [[ -n "$flavor" && "$flavor" != "$kernel_rel" ]]; then
            meta_candidates+=("linux-headers-${flavor}")
        fi
        meta_candidates+=("linux-headers-generic")
    elif [[ "${OS_ID:-}" == "debian" && -n "$arch_meta" ]]; then
        # Debian: обычное ядро 6.12.85+deb13-amd64, cloud — 6.12.85+deb13-cloud-amd64.
        [[ "$kernel_rel" == *-cloud-* ]] \
            && meta_candidates+=("linux-headers-cloud-${arch_meta}")
        meta_candidates+=("linux-headers-${arch_meta}")
    fi
    local meta meta_installed=0
    for meta in "${meta_candidates[@]}"; do
        if dpkg-query -W -f='${Status}' "$meta" 2>/dev/null \
                | grep -q 'install ok installed'; then
            log "$meta уже установлен (auto-tracking ядерных обновлений)."
            meta_installed=1
            break
        fi
        log "Установка мета-пакета $meta..."
        if DEBIAN_FRONTEND=noninteractive apt install -y "$meta" 2>/dev/null; then
            log "$meta установлен."
            meta_installed=1
            break
        fi
        log_warn "Не удалось установить $meta — пробуем следующий вариант."
    done
    if [[ ${#meta_candidates[@]} -gt 0 && $meta_installed -eq 0 ]]; then
        log_warn "Ни один meta-пакет kernel-headers не установлен — auto-rebuild при kernel upgrade может не работать."
    fi

    # v5.12.0: standalone helper /usr/local/sbin/amneziawg-ensure-module
    # вызывается из apt hook (DPkg::Post-Invoke) и из Phase 4 systemd-юнита.
    # Helper самодостаточен — не source awg_common.sh, чтобы оставаться
    # рабочим даже после ручного перемещения /root/awg/.
    #
    # Развёртывание делается через staging-файл в той же FS, что и target,
    # с финальным `mv -f` — гарантирует atomic-подмену (cross-FS rename
    # = copy+remove, НЕ atomic). Стейджинг-файл начинается с точки —
    # apt и logrotate пропускают dotfiles при сканировании каталога.
    log "Развёртывание helper'а DKMS auto-repair..."
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
        || { rm -f "$_stage_helper"; die "Не удалось chmod helper'а."; }
    mv -f "$_stage_helper" /usr/local/sbin/amneziawg-ensure-module \
        || { rm -f "$_stage_helper"; die "Не удалось развернуть helper amneziawg-ensure-module."; }
    log "Helper /usr/local/sbin/amneziawg-ensure-module развёрнут."

    # v5.12.0: apt hook DPkg::Post-Invoke вызывает helper после kernel upgrade.
    mkdir -p /etc/apt/apt.conf.d
    local _stage_hook=/etc/apt/apt.conf.d/.99-amneziawg-post-kernel.new
    cat > "$_stage_hook" <<'AWG_APT_HOOK_EOF'
// amneziawg-installer (v5.12.0+): rebuild DKMS module after kernel upgrades.
// Generated by install_amneziawg.sh — do not edit; re-run the installer to refresh.
DPkg::Post-Invoke {"if [ -x /usr/local/sbin/amneziawg-ensure-module ]; then /usr/local/sbin/amneziawg-ensure-module --hook >>/var/log/amneziawg-ensure-module.log 2>&1 || true; fi";};
AWG_APT_HOOK_EOF
    chown root:root "$_stage_hook" 2>/dev/null || true
    chmod 0644 "$_stage_hook" \
        || { rm -f "$_stage_hook"; die "Не удалось chmod apt-hook."; }
    mv -f "$_stage_hook" /etc/apt/apt.conf.d/99-amneziawg-post-kernel \
        || { rm -f "$_stage_hook"; die "Не удалось развернуть apt-hook."; }
    log "Apt-hook 99-amneziawg-post-kernel установлен (auto-rebuild при apt upgrade ядра)."

    # v5.12.0: logrotate для /var/log/amneziawg-ensure-module.log
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
        || { rm -f "$_stage_logrotate"; die "Не удалось chmod logrotate-конфиг."; }
    mv -f "$_stage_logrotate" /etc/logrotate.d/amneziawg-ensure-module \
        || { rm -f "$_stage_logrotate"; die "Не удалось развернуть logrotate-конфиг."; }
    log "Logrotate-конфиг /etc/logrotate.d/amneziawg-ensure-module установлен (weekly, rotate 4)."

    # v5.12.0 Phase 4: systemd unit гарантирует, что модуль ядра построен
    # и загружен ДО старта awg-quick@awg0 на каждом boot. Type=oneshot +
    # RemainAfterExit=yes + Before=awg-quick@awg0.service — стандартный
    # pre-load pattern (после kernel upgrade DKMS пересборка может
    # понадобиться сразу при первом boot нового ядра).
    log "Развёртывание systemd-юнита amneziawg-ensure-module.service..."
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
        || { rm -f "$_stage_unit"; die "Не удалось chmod systemd unit."; }
    mv -f "$_stage_unit" /etc/systemd/system/amneziawg-ensure-module.service \
        || { rm -f "$_stage_unit"; die "Не удалось развернуть systemd unit."; }
    if ! systemctl daemon-reload; then
        log_warn "systemctl daemon-reload завершился с ошибкой — unit может не активироваться до перезагрузки."
    fi
    if ! systemctl enable amneziawg-ensure-module.service; then
        log_warn "Не удалось enable amneziawg-ensure-module.service — boot-time auto-rebuild не будет срабатывать."
    fi
    log "Systemd-юнит amneziawg-ensure-module.service установлен и enabled (Before=awg-quick@awg0)."

    # DKMS статус
    log "Проверка статуса DKMS..."
    local dkms_stat
    dkms_stat=$(dkms status 2>&1)
    if ! echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then
        log_warn "DKMS статус не OK."
        log_msg "WARN" "$dkms_stat"
    else
        log "DKMS статус OK."
    fi

    # Шаг 2 тоже ставит пакеты и тоже перезагружает машину, значит тот же
    # рубеж нужен и здесь.
    _boot_critical_guard

    log "Шаг 2 завершен."
    request_reboot 3
}

# ==============================================================================
# ШАГ 3: Проверка модуля ядра
# ==============================================================================

step3_check_module() {
    update_state 3
    log "### ШАГ 3: Проверка модуля ядра ###"
    sleep 2

    if ! lsmod | grep -q -w amneziawg; then
        log "Модуль не загружен. Загрузка..."
        modprobe amneziawg || die "Ошибка modprobe amneziawg."
        log "Модуль загружен."
        local mf="/etc/modules-load.d/amneziawg.conf"
        mkdir -p "$(dirname "$mf")"
        if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then
            echo "amneziawg" > "$mf" || log_warn "Ошибка записи $mf"
            log "Добавлено в $mf."
        fi
    else
        log "Модуль amneziawg загружен."
    fi

    log "Информация о модуле:"
    modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" | while IFS= read -r line; do
        log "  $line"
    done

    local cv kr
    cv=$(modinfo amneziawg 2>/dev/null | awk '/^vermagic:/{print $2}')
    if [[ -z "$cv" ]]; then
        die "Не удалось прочитать vermagic модуля amneziawg. Проверьте: modprobe amneziawg && modinfo amneziawg"
    fi
    kr=$(uname -r)
    if [[ "$cv" != "$kr" ]]; then
        log_warn "VerMagic НЕ совпадает: Модуль($cv) != Ядро($kr)!"
    else
        log "VerMagic совпадает."
    fi

    # Проверка версии awg
    if command -v awg &>/dev/null; then
        local awg_ver
        awg_ver=$(awg --version 2>/dev/null || echo "неизвестна")
        log "Версия awg: $awg_ver"
    else
        log_warn "Команда awg не найдена!"
    fi

    log "Шаг 3 завершен."
    update_state 4
}

# ==============================================================================
# ШАГ 4: Настройка фаервола
# ==============================================================================

step4_setup_firewall() {
    update_state 4
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        log "### ШАГ 4: Настройка фаервола UFW ###"
        install_packages ufw
        setup_improved_firewall || die "Ошибка настройки UFW."
        log "Шаг 4 завершен."
    else
        log "### ШАГ 4: Пропуск настройки UFW (--no-tweaks) ###"
    fi
    update_state 5
}

# ==============================================================================
# ШАГ 5: Скачивание скриптов (БЕЗ Python!)
# ==============================================================================

verify_sha256() {
    local file="$1" expected="$2" label="$3"
    # Пропускаем проверку если:
    # - SHA не установлен (RELEASE_PLACEHOLDER — ещё не выпущен release)
    # - источник переопределён (тестовая/локальная ветка)
    if [[ "$expected" == "RELEASE_PLACEHOLDER" ]]; then
        log_debug "SHA256 для $label: пропуск (placeholder, до release)."
        return 0
    fi
    if [[ "$AWG_REPOSITORY" != "$PINNED_HELPERS_REPOSITORY" \
          || "$AWG_BRANCH" != "$PINNED_HELPERS_REF" ]]; then
        log_warn "SHA256 для $label: проверка пропущена для override ${AWG_REPOSITORY}@${AWG_BRANCH}. Файл не верифицирован."
        return 0
    fi
    local actual
    actual=$(sha256sum "$file" 2>/dev/null | awk '{print $1}')
    if [[ "$actual" != "$expected" ]]; then
        log_error "SHA256 $label НЕ совпадает!"
        log_error "  Ожидался: $expected"
        log_error "  Получен:  $actual"
        log_error "  Файл мог быть подменён. Скачайте installer заново с GitHub."
        return 1
    fi
    log_debug "SHA256 $label: OK ($actual)"
    return 0
}

# _secure_download <url> <target> <expected_sha256> <label>
# Atomic download:
#   1. curl → mktemp на том же FS, что и target;
#   2. verify_sha256 на temp (не на target, чтобы corrupt-файл не оказался
#      на целевом пути даже на долю секунды);
#   3. chmod 700 на temp;
#   4. mv -f temp → target (атомарный rename).
# Если любой шаг падает — temp удаляется, target не трогается.
_secure_download() {
    local url="$1" target="$2" expected_sha256="$3" label="$4"
    local tmp target_dir
    target_dir=$(dirname "$target")
    tmp=$(mktemp -p "$target_dir" ".${label//\//_}.tmp.XXXXXX") \
        || die "Не удалось создать временный файл для $label"
    if ! curl -fLso "$tmp" --max-time 60 --retry 2 "$url"; then
        rm -f "$tmp" 2>/dev/null
        die "Ошибка скачивания $label"
    fi
    if ! verify_sha256 "$tmp" "$expected_sha256" "$label"; then
        rm -f "$tmp" 2>/dev/null
        die "Целостность $label не подтверждена (SHA256 mismatch). Установка прервана."
    fi
    if ! chmod 700 "$tmp"; then
        rm -f "$tmp" 2>/dev/null
        die "Ошибка chmod $label"
    fi
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp" 2>/dev/null
        die "Ошибка перемещения $label на целевой путь"
    fi
    log "$label скачан и верифицирован."
}

# Commit двух уже проверенных helpers как одной логической транзакции. Оба
# staged-файла должны лежать в AWG_DIR (тот же FS): до первого rename проверяем
# пару целиком, а при ошибке второго rename возвращаем прежний common helper.
_commit_helper_pair() {
    local common_stage="$1" manage_stage="$2" common_label="$3" manage_label="$4"
    local old_common_tmp="" common_existed=0
    [[ -f "$common_stage" && ! -L "$common_stage" \
       && -f "$manage_stage" && ! -L "$manage_stage" ]] || {
        log_error "Helper pair commit: staging-файлы отсутствуют или небезопасны."
        return 1
    }
    chmod 700 "$common_stage" "$manage_stage" || return 1
    if [[ ( -e "$COMMON_SCRIPT_PATH" || -L "$COMMON_SCRIPT_PATH" ) \
          && ( ! -f "$COMMON_SCRIPT_PATH" || -L "$COMMON_SCRIPT_PATH" ) \
          || ( -e "$MANAGE_SCRIPT_PATH" || -L "$MANAGE_SCRIPT_PATH" ) \
          && ( ! -f "$MANAGE_SCRIPT_PATH" || -L "$MANAGE_SCRIPT_PATH" ) ]]; then
        log_error "Отказ заменять helper, который не является обычным файлом."
        return 1
    fi
    if [[ -e "$COMMON_SCRIPT_PATH" ]]; then
        old_common_tmp=$(mktemp -p "$AWG_DIR" '.old-common.XXXXXX') || return 1
        cp -p -- "$COMMON_SCRIPT_PATH" "$old_common_tmp" \
            || { rm -f -- "$old_common_tmp"; return 1; }
        common_existed=1
    fi

    # Не допускаем INT/TERM в микроскопическом окне между двумя rename.
    trap '' INT TERM
    if ! mv -f -- "$common_stage" "$COMMON_SCRIPT_PATH"; then
        trap '_install_on_signal 130' INT
        trap '_install_on_signal 143' TERM
        rm -f -- "$old_common_tmp"
        log_error "Не удалось атомарно заменить $common_label"
        return 1
    fi
    if ! mv -f -- "$manage_stage" "$MANAGE_SCRIPT_PATH"; then
        if [[ "$common_existed" -eq 1 ]]; then
            mv -f -- "$old_common_tmp" "$COMMON_SCRIPT_PATH" \
                || log_error "CRITICAL: rollback common helper не удался; backup: $old_common_tmp"
        else
            rm -f -- "$COMMON_SCRIPT_PATH" \
                || log_error "CRITICAL: не удалось снять новый common helper после ошибки pair-update."
        fi
        trap '_install_on_signal 130' INT
        trap '_install_on_signal 143' TERM
        log_error "Не удалось атомарно заменить $manage_label; pair-update отменён."
        return 1
    fi
    trap '_install_on_signal 130' INT
    trap '_install_on_signal 143' TERM
    rm -f -- "$old_common_tmp"
    return 0
}

step5_download_scripts() {
    update_state 5
    log "### ШАГ 5: Установка скриптов управления ###"
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"

    # Локальный путь ПРЕФЕРЕН: если installer запущен из склонированного
    # репозитория (т.е. рядом с install_amneziawg.sh лежат awg_common.sh и
    # manage_amneziawg.sh), сначала staging+SHA256 проверка ОБОИХ файлов и
    # только затем атомарная замена live helpers. При стандартном repo/ref это
    # тот же обязательный pin, что и для CDN; override явно логируется.
    # Это делает workflow "git clone → sudo bash install_amneziawg.sh"
    # рабочим для форков: без этого ветвления step5 тянул бы upstream-версии
    # из CDN, а наши локальные модификации в форке игнорировались бы.
    # CDN остаётся как fallback для `curl | bash` сценария.
    #
    # $INSTALLER_DIR зафиксирован наверху скрипта ДО первого cd — поздний
    # резолв BASH_SOURCE[0] с относительным путём давал AWG_DIR (потому что
    # initialize_setup уже успела туда cd), и условие script_dir != AWG_DIR
    # ложно срабатывало на любой инвокации вида `sudo bash install_amneziawg.sh`
    # из папки клона.
    local script_dir="${INSTALLER_DIR:-}"
    # basename'ы берём из URL — EN-инсталлятор ссылается на *_en.sh файлы,
    # и рядом с install_amneziawg_en.sh в клоне лежат именно они.
    local _common_basename="${COMMON_SCRIPT_URL##*/}"
    local _manage_basename="${MANAGE_SCRIPT_URL##*/}"
    if [[ -n "$script_dir" && "$script_dir" != "$AWG_DIR" \
          && -f "$script_dir/$_common_basename" \
          && ! -L "$script_dir/$_common_basename" \
          && -f "$script_dir/$_manage_basename" \
          && ! -L "$script_dir/$_manage_basename" ]]; then
        local _local_common_tmp="" _local_manage_tmp=""
        local _local_verify_failed=0
        log "Найден локальный клон ($script_dir) — staging и проверка обоих helpers."
        _local_common_tmp=$(mktemp -p "$AWG_DIR" '.local-common.XXXXXX') \
            || die "Не удалось создать staging для $_common_basename"
        _local_manage_tmp=$(mktemp -p "$AWG_DIR" '.local-manage.XXXXXX') \
            || { rm -f -- "$_local_common_tmp"; die "Не удалось создать staging для $_manage_basename"; }
        _install_temp_files+=("$_local_common_tmp" "$_local_manage_tmp")
        cp -- "$script_dir/$_common_basename" "$_local_common_tmp" \
            && cp -- "$script_dir/$_manage_basename" "$_local_manage_tmp" \
            && chmod 700 "$_local_common_tmp" "$_local_manage_tmp" \
            || { rm -f -- "$_local_common_tmp" "$_local_manage_tmp"; die "Ошибка staging локальных helpers"; }
        verify_sha256 "$_local_common_tmp" "$COMMON_SCRIPT_SHA256" "$_common_basename" \
            || _local_verify_failed=1
        verify_sha256 "$_local_manage_tmp" "$MANAGE_SCRIPT_SHA256" "$_manage_basename" \
            || _local_verify_failed=1
        if [[ "$_local_verify_failed" -eq 1 ]]; then
            rm -f -- "$_local_common_tmp" "$_local_manage_tmp"
            die "Целостность локальных helpers не подтверждена; live-файлы не изменены."
        fi
        _commit_helper_pair "$_local_common_tmp" "$_local_manage_tmp" \
            "$_common_basename" "$_manage_basename" \
            || die "Транзакционная установка локальной пары helpers не удалась."
        log "Оба helper-скрипта установлены из локального клона после staging и проверки SHA256."
        log "Шаг 5 завершен."
        update_state 6
        return 0
    fi
    log_debug "Локальный клон не обнаружен (INSTALLER_DIR='${script_dir}', AWG_DIR='$AWG_DIR') — качаю из CDN."

    # CDN fallback использует ту же pair-транзакцию: сначала оба
    # helper'а скачиваются и SHA256-проверяются в staging, и только
    # после успеха обоих меняются live-файлы.
    local _cdn_common_tmp="" _cdn_manage_tmp=""
    _cdn_common_tmp=$(mktemp -p "$AWG_DIR" '.cdn-common.XXXXXX') \
        || die "Не удалось создать CDN staging для $_common_basename"
    _cdn_manage_tmp=$(mktemp -p "$AWG_DIR" '.cdn-manage.XXXXXX') \
        || { rm -f -- "$_cdn_common_tmp"; die "Не удалось создать CDN staging для $_manage_basename"; }
    _install_temp_files+=("$_cdn_common_tmp" "$_cdn_manage_tmp")

    log "Скачивание и проверка $_common_basename в staging..."
    _secure_download "$COMMON_SCRIPT_URL" "$_cdn_common_tmp" \
        "$COMMON_SCRIPT_SHA256" "$_common_basename"
    log "Скачивание и проверка $_manage_basename в staging..."
    _secure_download "$MANAGE_SCRIPT_URL" "$_cdn_manage_tmp" \
        "$MANAGE_SCRIPT_SHA256" "$_manage_basename"
    _commit_helper_pair "$_cdn_common_tmp" "$_cdn_manage_tmp" \
        "$_common_basename" "$_manage_basename" \
        || die "Транзакционная установка CDN-пары helpers не удалась."
    log "Оба helper-скрипта установлены из CDN после проверки пары."

    log "Шаг 5 завершен."
    update_state 6
}

# ==============================================================================
# ШАГ 6: Генерация конфигураций (нативная, без awgcfg.py)
# ==============================================================================

step6_generate_configs() {
    update_state 6
    log "### ШАГ 6: Генерация конфигураций AWG 2.0 ###"
    cd "$AWG_DIR" || die "Ошибка cd $AWG_DIR"

    # Подключаем общую библиотеку
    if [[ ! -f "$COMMON_SCRIPT_PATH" ]]; then
        die "awg_common.sh не найден. Шаг 5 не выполнен?"
    fi
    # shellcheck source=/dev/null
    source "$COMMON_SCRIPT_PATH"
    command -v ip >/dev/null 2>&1 \
        || die "Команда ip недоступна; безопасно проверить live tunnel перед заменой config невозможно."

    # До остановки живого awg0 переводим пустой marker старых WARP-версий в
    # безопасную гранулярную модель. Если legacy-состояние повреждено, VPN
    # остаётся поднятым и установка отказывает без сетевого простоя.
    local _legacy_warp_iface="${AWG_WARP_IFACE:-wgcf}"
    if [[ -e "$AWG_DIR/.warp_cleanup_pending" ]]; then
        [[ -f "$AWG_DIR/.warp_cleanup_pending" && ! -L "$AWG_DIR/.warp_cleanup_pending" ]] \
            || die "Небезопасный WARP cleanup marker до preflight."
        IFS= read -r _legacy_warp_iface < "$AWG_DIR/.warp_cleanup_pending" || _legacy_warp_iface=""
    fi
    if [[ -e "$AWG_DIR/.wgcf_enabled_by_installer" || -L "$AWG_DIR/.wgcf_enabled_by_installer" ]]; then
        [[ "$_legacy_warp_iface" =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ && "$_legacy_warp_iface" != "awg0" ]] \
            || die "Некорректный WARP iface до legacy preflight."
        migrate_legacy_warp_ownership "$_legacy_warp_iface" \
            || die "Legacy WARP ownership не удалось безопасно мигрировать; awg0 оставлен без изменений."
    fi

    # Создаём директорию для ключей
    mkdir -p "$KEYS_DIR" || die "Ошибка создания $KEYS_DIR"

    # Генерация серверных ключей (если ещё нет)
    if [[ ! -f "$AWG_DIR/server_private.key" ]]; then
        log "Генерация серверных ключей..."
        generate_server_keys || die "Ошибка генерации серверных ключей."
    else
        log "Серверные ключи уже существуют."
    fi

    # Бэкап существующего серверного конфига ДО перезаписи
    if [[ -e "$SERVER_CONF_FILE" || -L "$SERVER_CONF_FILE" ]]; then
        [[ -f "$SERVER_CONF_FILE" && ! -L "$SERVER_CONF_FILE" ]] \
            || die "Отказ делать backup awg0.conf, который не является обычным файлом."
        local s_bak
        s_bak="${SERVER_CONF_FILE}.bak-$(date +%F_%H%M%S)"
        cp "$SERVER_CONF_FILE" "$s_bak" || { rm -f "$s_bak"; die "Ошибка бэкапа $s_bak — живой конфиг не изменён."; }
        log "Бэкап серверного конфига: $s_bak"
    fi

    # Полностью рендерим и валидируем новый awg0.conf ДО остановки живого
    # интерфейса. В критической секции останется только atomic rename.
    local _staged_server_conf _staged_server_dir
    _staged_server_dir=$(mktemp -d -p "$(dirname "$SERVER_CONF_FILE")" '.awg0-stage.XXXXXX') \
        || die "Не удалось создать staging-dir awg0.conf."
    _install_temp_dirs+=("$_staged_server_dir")
    _staged_server_conf="$_staged_server_dir/awg0.conf"
    _install_temp_files+=("$_staged_server_conf")
    render_server_config "${s_bak:-}" "$_staged_server_conf" \
        || die "Ошибка предварительного рендера серверного конфига; живой awg0 не остановлен."
    validate_awg_config "$_staged_server_conf" \
        || die "Валидация нового awg0.conf не пройдена; живой awg0 не остановлен."
    timeout 10 awg-quick strip "$_staged_server_conf" >/dev/null 2>&1 \
        || die "Новый awg0.conf не прошёл awg-quick strip; живой awg0 не остановлен."

    # Upstream тоже полностью рендерим и проверяем ДО остановки awg0/старого
    # upstream. render_upstream_config выбирает output через dirname
    # SERVER_CONF_FILE, поэтому временно направляем его в отдельный staging dir.
    local _staged_upstream_conf="" _staged_upstream_dir=""
    if [[ "${AWG_ROLE:-single}" == "entry" && -n "${AWG_UPSTREAM_CONF:-}" ]]; then
        local _saved_server_conf_file="$SERVER_CONF_FILE" _up_render_rc=0
        _staged_upstream_dir=$(mktemp -d -p "$AWG_DIR" '.upstream-stage.XXXXXX') \
            || die "Не удалось создать staging-dir upstream-конфига."
        _install_temp_dirs+=("$_staged_upstream_dir")
        SERVER_CONF_FILE="$_staged_upstream_dir/awg0.conf"
        render_upstream_config || _up_render_rc=$?
        SERVER_CONF_FILE="$_saved_server_conf_file"
        [[ "$_up_render_rc" -eq 0 ]] \
            || die "Ошибка предварительного рендера upstream; живые unit/config не изменены."
        _staged_upstream_conf="$_staged_upstream_dir/${AWG_UPSTREAM_IFACE:-awg1}.conf"
        [[ -f "$_staged_upstream_conf" && ! -L "$_staged_upstream_conf" ]] \
            || die "Предварительный рендер не создал ожидаемый upstream-конфиг."
        _install_temp_files+=("$_staged_upstream_conf")
        timeout 10 awg-quick strip "$_staged_upstream_conf" >/dev/null 2>&1 \
            || die "Новый upstream-конфиг не прошёл awg-quick strip; живые unit/config не изменены."
        log "Новый upstream-конфиг отрендерен и проверен в staging."
    fi

    # Preflight + снимок installer-owned systemd dependency для EXIT rollback.
    if [[ -e "$AWG0_DEPENDENCY_MARKER" || -L "$AWG0_DEPENDENCY_MARKER" ]]; then
        local _old_dep_path=""
        [[ -f "$AWG0_DEPENDENCY_MARKER" && ! -L "$AWG0_DEPENDENCY_MARKER" ]] \
            || die "Некорректный awg0 dependency marker; живой awg0 не остановлен."
        IFS= read -r _old_dep_path < "$AWG0_DEPENDENCY_MARKER" || _old_dep_path=""
        [[ "$_old_dep_path" == "$AWG0_DEPENDENCY_DROPIN" && -f "$AWG0_DEPENDENCY_DROPIN" \
           && ! -L "$AWG0_DEPENDENCY_DROPIN" ]] \
            || die "Stale/некорректный awg0 dependency ownership; живой awg0 не остановлен."
        _INSTALL_ROLLBACK_DEP_BACKUP=$(mktemp -p "$AWG_DIR" '.dependency.rollback.XXXXXX') \
            || die "Не удалось создать backup awg0 dependency."
        _install_temp_files+=("$_INSTALL_ROLLBACK_DEP_BACKUP")
        cp -- "$AWG0_DEPENDENCY_DROPIN" "$_INSTALL_ROLLBACK_DEP_BACKUP" \
            || die "Не удалось сохранить awg0 dependency для rollback."
        _INSTALL_ROLLBACK_DEP_EXISTED=1
    elif [[ -e "$AWG0_DEPENDENCY_DROPIN" || -L "$AWG0_DEPENDENCY_DROPIN" ]]; then
        die "Чужой awg0 dependency drop-in существует без ownership marker; живой awg0 не остановлен."
    fi
    _INSTALL_ROLLBACK_DEP_ACTIVE=1

    # Снимок config + точного runtime/autostart делается независимо от active:
    # inactive старый config тоже нельзя терять, а первая установка должна
    # удалить новый target при abort. Транзакция взводится ДО первой остановки.
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
        die "Обнаружен live awg0 без штатного $SERVER_CONF_FILE; безопасный rollback невозможен."
    fi
    _INSTALL_ROLLBACK_AWG0=1

    # Останавливаем awg0 ПОКА на диске ещё старый config, чтобы выполнить его
    # старый PostDown и снять прежние direct/entry/WARP rules.
    if [[ "$_INSTALL_ROLLBACK_AWG0_WAS_ACTIVE" -eq 1 ]]; then
        log "Остановка awg0 перед атомарной заменой конфига..."
        systemctl stop awg-quick@awg0 \
            || die "Не удалось остановить awg-quick@awg0; старый config сохранён."
    elif [[ "$_old_awg0_state" != "inactive" && "$_old_awg0_state" != "failed" \
            && "$_old_awg0_state" != "unknown" ]]; then
        die "Не удалось надёжно определить состояние awg0; старый config сохранён."
    fi
    if command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1; then
        timeout 15 awg-quick down "$SERVER_CONF_FILE" >/dev/null 2>&1 \
            || die "Не удалось снять live awg0 по старому config; config не перезаписан."
    fi
    if command -v ip >/dev/null 2>&1 && ip link show dev awg0 >/dev/null 2>&1; then
        die "awg0 остался live после stop/down; config не перезаписан."
    fi

    # Старый upstream со своим routing table больше не должен влиять на новый
    # режим. Только временно stop; disable/delete остаются post-commit.
    stop_pending_old_upstream_for_transition \
        || die "Не удалось безопасно остановить прежний upstream до запуска нового awg0."

    # Старые unit/config не трогаем до commit нового awg0. При WARP→WARP со
    # сменой iface переносим только ownership marker'ы; EXIT rollback вернёт их.
    park_pending_warp_ownership \
        || die "Не удалось безопасно сохранить ownership прежнего WARP до commit."

    # WARP egress: поднимаем wgcf ДО рендера awg0.conf — PostUp в конфиге
    # уже будет ссылаться на wgcf-интерфейс, а он должен существовать к
    # моменту systemctl start awg-quick@awg0 в шаге 7.
    if [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
        log "Установка WARP egress (Cloudflare)..."
        snapshot_warp_egress_state \
            || die "Не удалось создать полный снимок WARP egress до изменения."
        setup_warp_egress || die "Ошибка setup_warp_egress. См. лог."
    fi

    configure_awg0_dependency \
        || die "Не удалось настроить загрузочную зависимость awg0 от egress-туннеля."

    # Создание серверного конфига AWG 2.0 с переносом ВСЕХ существующих
    # [Peer]-блоков из бэкапа ОДНОЙ атомарной записью (render_server_config
    # доклеивает пиры в temp ДО mv). Раньше append шёл ПОСЛЕ render отдельной
    # операцией: сбой в окне между ними оставлял живой конфиг без пиров, а
    # повторный запуск шага 6 бэкапил уже безпировый файл - все клиенты
    # терялись при --force reinstall (восстановление только вручную из
    # timestamped .bak).
    # C5-история (важно сохранить семантику): восстанавливаются ВСЕ блоки,
    # включая дефолтные my_phone/my_laptop - идемпотентный цикл ниже
    # пропускает уже существующие пиры, а guard в generate_client отвергает
    # повторное создание при наличии артефактов.
    log "Атомарное развёртывание проверенного серверного конфига..."
    mv -f "$_staged_server_conf" "$SERVER_CONF_FILE" \
        && chmod 600 "$SERVER_CONF_FILE" \
        || die "Ошибка развёртывания проверенного серверного конфига."
    _staged_server_conf=""
    rmdir "$_staged_server_dir" 2>/dev/null || true
    if [[ -n "${s_bak:-}" && -f "$s_bak" ]] && grep -q '^\[Peer\]' "$s_bak" 2>/dev/null; then
        log "Существующие пиры восстановлены из бэкапа."
    fi

    # Генерация клиентов по умолчанию
    log "Создание клиентов по умолчанию..."
    local client_name
    for client_name in my_phone my_laptop; do
        if grep -qxF "#_Name = ${client_name}" "$SERVER_CONF_FILE" 2>/dev/null; then
            log "Клиент '$client_name' уже существует."
        else
            log "Создание клиента '$client_name'..."
            generate_client "$client_name" || log_warn "Ошибка создания клиента '$client_name'"
        fi
    done

    # Multi-hop: развёртываем upstream-интерфейс (awg1) для role=entry.
    # Если --upstream-conf не передан на повторном запуске — сохраняем уже
    # существующий ${AWG_UPSTREAM_IFACE}.conf как есть.
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        local _up_conf_out="/etc/amnezia/amneziawg/${AWG_UPSTREAM_IFACE:-awg1}.conf"
        local _up_runtime_state="" _up_live_link=0 _up_bak=""
        if [[ -e "$_up_conf_out" || -L "$_up_conf_out" ]]; then
            [[ -f "$_up_conf_out" && ! -L "$_up_conf_out" ]] \
                || die "Отказ использовать upstream config, который не является обычным файлом."
            _up_bak="${_up_conf_out}.bak-$(date +%F_%H%M%S)"
            cp "$_up_conf_out" "$_up_bak" \
                || { rm -f "$_up_bak"; die "Ошибка бэкапа $_up_bak — upstream-конфиг не изменён."; }
            log "Бэкап upstream-конфига: $_up_bak"
            _INSTALL_ROLLBACK_UPSTREAM_BACKUP="$_up_bak"
            _INSTALL_ROLLBACK_UPSTREAM_EXISTED=1
        elif [[ -z "${AWG_UPSTREAM_CONF:-}" ]]; then
            die "role=entry: нет upstream-конфига ни в CLI, ни на диске ($_up_conf_out)."
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
            die "Обнаружен live upstream без штатного $_up_conf_out; безопасный rollback невозможен."
        fi
        # Даже неизменённый config будет enable/start в шаге 7. Взводим rollback
        # до этого, чтобы поздняя ошибка вернула exact active/link/enabled state.
        _INSTALL_ROLLBACK_UPSTREAM=1
        if [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE" -eq 0 && "$_up_live_link" -eq 1 ]]; then
            timeout 15 awg-quick down "$_up_conf_out" >/dev/null 2>&1 \
                || die "Не удалось временно снять вручную поднятый upstream ${AWG_UPSTREAM_IFACE:-awg1}."
            if ip link show dev "${AWG_UPSTREAM_IFACE:-awg1}" >/dev/null 2>&1; then
                die "Вручную поднятый upstream ${AWG_UPSTREAM_IFACE:-awg1} остался live после down."
            fi
        fi
        if [[ -n "${AWG_UPSTREAM_CONF:-}" ]]; then
            log "Развёртывание upstream-интерфейса ${AWG_UPSTREAM_IFACE:-awg1} из ${AWG_UPSTREAM_CONF}..."
            [[ -n "$_staged_upstream_conf" && -f "$_staged_upstream_conf" ]] \
                || die "Проверенный staging upstream-конфига потерян; live config не изменён."
            if [[ "$_INSTALL_ROLLBACK_UPSTREAM_WAS_ACTIVE" -eq 1 ]]; then
                log "Остановка ${AWG_UPSTREAM_IFACE:-awg1} перед заменой upstream-конфига..."
                systemctl stop "awg-quick@${AWG_UPSTREAM_IFACE:-awg1}" \
                    || die "Не удалось остановить upstream ${AWG_UPSTREAM_IFACE:-awg1}; старый конфиг сохранён."
            elif [[ "$_up_runtime_state" != "inactive" && "$_up_runtime_state" != "failed" \
                    && "$_up_runtime_state" != "unknown" ]]; then
                die "Не удалось надёжно определить состояние upstream ${AWG_UPSTREAM_IFACE:-awg1}; старый конфиг сохранён."
            fi
            if command -v ip >/dev/null 2>&1 \
               && ip link show dev "${AWG_UPSTREAM_IFACE:-awg1}" >/dev/null 2>&1; then
                timeout 15 awg-quick down "$_up_conf_out" >/dev/null 2>&1 \
                    || die "Не удалось снять live upstream ${AWG_UPSTREAM_IFACE:-awg1} по старому конфигу; config не перезаписан."
            fi
            if command -v ip >/dev/null 2>&1 \
               && ip link show dev "${AWG_UPSTREAM_IFACE:-awg1}" >/dev/null 2>&1; then
                die "Upstream ${AWG_UPSTREAM_IFACE:-awg1} остался live после stop/down; config не перезаписан."
            fi
            mv -f -- "$_staged_upstream_conf" "$_up_conf_out" \
                && chmod 600 "$_up_conf_out" \
                || die "Ошибка атомарного развёртывания upstream-конфига (${AWG_UPSTREAM_IFACE:-awg1})."
            _staged_upstream_conf=""
            rmdir "$_staged_upstream_dir" 2>/dev/null || true
            local _expected_staged="$AWG_DIR/.upstream-${AWG_UPSTREAM_IFACE:-awg1}.pending.conf"
            if [[ "$AWG_UPSTREAM_CONF" == "$_expected_staged" ]]; then
                rm -f -- "$_expected_staged" || log_warn "Не удалось удалить использованный staging upstream-конфига."
                AWG_UPSTREAM_CONF=""
            fi
        else
            log "Upstream-конфиг уже существует: $_up_conf_out — пропуск рендеринга."
        fi
    fi

    # Установка прав доступа
    secure_files

    log "Конфигурационные файлы в $AWG_DIR:"
    ls -la "$AWG_DIR"/*.conf "$AWG_DIR"/*.png 2>/dev/null | while IFS= read -r line; do
        log "  $line"
    done

    log "Шаг 6 завершен."
    update_state 7
}

# Загружает только v2-ledger, полностью прошедший те же ограничения, что и
# common teardown: exact table, максимум 2048 уникальных публичных /19../32.
# Результат остаётся в process-local associative set и относится к одному
# прочитанному snapshot файла, а не к повторному grep потенциально сменившегося
# ledger.
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

# Проверяет конкретные bypass routes не только по destination из ledger, но и
# по exact current main nexthop, который использует owned refresh-service.
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
        # После успешного setup запрошенный bypass обязан иметь и ledger, и
        # хотя бы один exact route. Пустой/пропавший набор — не успех.
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

# До запуска support/awg0 выбранные priority/table не должны захватывать чужое
# состояние. Оба priority обязаны быть свободны, и никакое иное rule не должно
# ссылаться на выбранную table. Entry допускает только уже существующий default
# своего active upstream; WARP — только exact routes из строгого owned ledger.
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

# PostUp — shell-цепочка с `;`, поэтому unit может стать active даже если один
# из iptables шагов упал. Проверяем критические FORWARD/NAT/MSS правила точно,
# включая direct-NAT для WARP bypass.
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

# Перед commit проверяем не намерение в config, а точное live-состояние
# fail-closed маршрутизации и firewall fork-режимов.
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
        log_warn "Отложенный UFW main-route marker сохранён: новому режиму всё ещё нужен awg0→main."
        return 0
    fi
    [[ -f "$marker" && ! -L "$marker" ]] || {
        log_warn "Небезопасный UFW main-route marker сохранён: $marker"
        return 0
    }
    IFS= read -r iface < "$marker" || iface=""
    [[ "$iface" =~ ^[a-zA-Z][a-zA-Z0-9_.-]{0,14}$ ]] || {
        log_warn "Некорректный iface в UFW main-route marker; правило сохранено."
        return 0
    }
    command -v ufw >/dev/null 2>&1 || {
        log_warn "UFW недоступен; old awg0→main правило не удалено."
        return 0
    }
    _inspect_exact_ufw_route "$iface" "AmneziaWG Routing" || {
        log_warn "Не удалось проверить ownership UFW awg0→main; правило сохранено."
        return 0
    }
    if [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -eq 0 ]]; then
        _INSTALL_UFW_MAIN_MARKER_RESOLVED=1
        return 0
    fi
    if [[ "$_INSTALL_UFW_ROUTE_SHAPE_COUNT" -ne 1 || "$_INSTALL_UFW_ROUTE_OWNED_COUNT" -ne 1 ]]; then
        log_warn "UFW awg0→main не имеет ровно одного installer-owned совпадения; неоднозначное правило сохранено."
        return 0
    fi
    _INSTALL_ROLLBACK_UFW_MAIN_IFACE="$iface"
    _INSTALL_ROLLBACK_UFW_MAIN_RULE=1
    delete_exact_owned_ufw_route "$iface" "AmneziaWG Routing" || return 1
    log "UFW: прежний installer-owned route awg0→${iface} удалён перед commit нового режима."
    return 0
}

# ==============================================================================
# ШАГ 7: Запуск сервиса
# ==============================================================================

# При resume шага 7 process-local snapshot шага 6 потерян. До enable/start
# повторно фиксируем exact runtime/autostart reused upstream, чтобы поздний abort
# не оставил ранее inactive/manual unit изменённым.
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
    log "### ШАГ 7: Запуск сервиса и настройка безопасности ###"

    # При resume прямо с setup_state=7 общая библиотека ещё не была sourced в
    # этом процессе. Без неё awg_record_device_params ниже был command-not-found.
    if ! declare -F awg_record_device_params >/dev/null 2>&1; then
        [[ -f "$COMMON_SCRIPT_PATH" ]] || die "awg_common.sh не найден при возобновлении шага 7."
        # shellcheck source=/dev/null
        source "$COMMON_SCRIPT_PATH"
    fi
    declare -F awg_record_device_params >/dev/null 2>&1 \
        || die "awg_common.sh не содержит awg_record_device_params."

    # Существующий owned bypass меняем ДО namespace preflight/start. Иначе при
    # WARP→entry с той же table его specific routes блокируют entry preflight,
    # а при bypass→none временно переживают новый awg0. Snapshot делает раннюю
    # мутацию полностью обратимой через общий EXIT rollback.
    local _bypass_marker="$AWG_DIR/.warp_bypass_enabled_by_installer"
    local _bypass_tx_needed=0 _bypass_tx_prepared=0
    if [[ -e "$_bypass_marker" || -L "$_bypass_marker" ]]; then
        # Snapshot останавливает owned timer/service до того, как transaction
        # полностью armed. Не допускаем INT/TERM в этом окне и сохраняем блок
        # до общего installer commit/state99 ниже.
        trap '' INT TERM
        declare -F snapshot_warp_bypass_state >/dev/null 2>&1 \
            && declare -F setup_warp_bypass >/dev/null 2>&1 \
            || die "Текущий awg_common.sh не поддерживает транзакционный WARP bypass."
        snapshot_warp_bypass_state \
            || die "Не удалось создать полный снимок прежнего WARP bypass до policy preflight."
        setup_warp_bypass \
            || die "Прежний WARP bypass не приведён в новое состояние до policy preflight; выполняется rollback."
        _bypass_tx_prepared=1
    fi

    local _resume_owned_live=0 _resume_awg0_active=0 _resume_awg0_link=0
    if [[ "${_INSTALL_INITIAL_STEP:-1}" -eq 7 ]]; then
        systemctl is-active --quiet awg-quick@awg0 2>/dev/null && _resume_awg0_active=1
        command -v ip >/dev/null 2>&1 \
            && ip link show dev awg0 >/dev/null 2>&1 && _resume_awg0_link=1
        if [[ "$_resume_awg0_active" -ne "$_resume_awg0_link" ]]; then
            die "Resume шага 7: awg0 имеет неоднозначное unit/link состояние; live сеть не изменена."
        fi
        if [[ "$_resume_awg0_active" -eq 1 ]]; then
            [[ -f "$SERVER_CONF_FILE" && ! -L "$SERVER_CONF_FILE" ]] \
                || die "Resume шага 7: live awg0 не имеет штатного regular config; сеть не изменена."
            validate_awg_config "$SERVER_CONF_FILE" \
                || die "Resume шага 7: live awg0.conf не прошёл строгую валидацию; сеть не изменена."
            timeout 10 awg-quick strip "$SERVER_CONF_FILE" >/dev/null 2>&1 \
                || die "Resume шага 7: live awg0.conf не прошёл awg-quick strip; сеть не изменена."
            check_service_status >/dev/null 2>&1 \
                || die "Resume шага 7: live awg0 не прошёл service postcondition; сеть не изменена."
            verify_fork_egress_runtime 0 \
                || die "Resume шага 7: live fork egress не совпадает с exact owned state; сеть не изменена."
            _resume_owned_live=1
            log "Resume шага 7: exact live awg0 уже подтверждён; disruptive restart пропущен."
        fi
    fi
    if [[ "$_resume_owned_live" -eq 0 ]]; then
        preflight_fork_policy_namespace \
            || die "Выбранные policy table/priority заняты чужими или неоднозначными routes/rules."
        arm_step7_upstream_rollback \
            || die "Не удалось взвести rollback reused upstream перед resume шага 7."
    fi
    configure_awg0_dependency || die "Не удалось настроить загрузочную зависимость awg0."

    # Обязательный egress поднимается первым. Requires/After сохраняет этот
    # порядок после reboot; явный старт даёт понятную ошибку до запуска awg0.
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then
        local _up="${AWG_UPSTREAM_IFACE:-awg1}"
        log "Включение и запуск awg-quick@${_up} (upstream-каскад)..."
        systemctl enable --now "awg-quick@${_up}" \
            || die "awg-quick@${_up} не стартовал. Проверьте: systemctl status awg-quick@${_up}"
        systemctl is-active --quiet "awg-quick@${_up}" \
            || die "Upstream-туннель ${_up} не active; awg0 оставлен остановленным."
    elif [[ "${AWG_EGRESS:-direct}" == "warp" ]]; then
        local _warp_unit="wg-quick@${AWG_WARP_IFACE:-wgcf}"
        log "Запуск обязательного WARP egress (${_warp_unit})..."
        systemctl start "$_warp_unit" \
            || die "$_warp_unit не стартовал; awg0 оставлен остановленным."
        systemctl is-active --quiet "$_warp_unit" \
            || die "$_warp_unit не active; awg0 оставлен остановленным."
    fi

    log "Включение и запуск awg-quick@awg0..."

    # Переключение изоляции on->off: PostDown нового конфига DROP-правило не
    # снимет (его там больше нет), а down-фаза restart работает уже с новым
    # конфигом на диске. Убираем stale-правила явно, циклом - при повторных
    # прерванных запусках их могло накопиться несколько (issue #178, паттерн
    # отложенной уборки как у PREV_AWG_PORT в #175).
    if [[ "${CLIENT_ISOLATION:-1}" -eq 0 ]]; then
        while iptables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
        while ip6tables -D FORWARD -i awg0 -o awg0 -j DROP 2>/dev/null; do :; done
    fi

    if [[ "$_resume_owned_live" -eq 1 ]]; then
        systemctl enable awg-quick@awg0 \
            || die "Не удалось enable уже проверенный awg-quick@awg0."
    elif systemctl is-active --quiet awg-quick@awg0; then
        log "Сервис уже активен — перезапуск для применения конфигурации..."
        systemctl enable awg-quick@awg0 \
            || die "Не удалось enable awg-quick@awg0; установка не будет отмечена завершённой."
        systemctl restart awg-quick@awg0 || die "Ошибка restart awg-quick@awg0."
    else
        systemctl enable --now awg-quick@awg0 || die "Ошибка enable --now."
    fi
    log "Сервис включен и запущен."

    log "Проверка статуса сервиса..."
    local _attempt
    for _attempt in 1 2 3 4 5; do
        sleep 1
        check_service_status 2>/dev/null && break
        [[ $_attempt -lt 5 ]] && log_debug "Ожидание запуска сервиса... (попытка $_attempt/5)"
    done
    check_service_status || die "Проверка статуса сервиса не пройдена."

    # Multi-hop: upstream-интерфейс и его UFW route обязательны для выхода
    # клиентов. Не помечаем установку завершённой, если любой из них не поднят.
    if [[ "${AWG_ROLE:-single}" == "entry" ]]; then log "Upstream-туннель ${_up} запущен."; fi

    # Fail2Ban
    if [[ "$NO_TWEAKS" -eq 0 ]]; then
        setup_fail2ban
    else
        log "Пропуск Fail2Ban (--no-tweaks)."
    fi

    verify_fork_egress_runtime \
        || die "Fork egress не прошёл live-проверку: support/rule/blackhole/default route неполны."
    # Записываем snapshot только после service + exact egress postcondition.
    awg_record_device_params
    # Критическое окно UFW-delete → bypass/DNS transactions → commit не
    # должно быть разорвано сигналом. EXIT сможет откатить все snapshots, пока
    # installer commit явно не закроет их ниже.
    trap '' INT TERM
    if [[ "${AWG_ROLE:-single}" == "entry" ]] \
       && command -v ufw &>/dev/null && ! ufw status 2>/dev/null | grep -q inactive; then
        ensure_owned_cascade_ufw_route "${_up}" || {
            die "UFW: обязательный owned route awg0→${_up} неоднозначен или не добавился; выполняется rollback."
        }
    fi
    if ! cleanup_pending_ufw_main_route_for_entry; then
        die "Не удалось удалить подтверждённый прежний UFW awg0→main route; выполняется rollback."
    fi

    # Bypass входит в тот же install-level commit, что и awg0/WARP. Для нового
    # bypass и для удаления прежнего owned bundle сначала делается полный
    # snapshot файлов, unit-state и exact kernel routes.
    if [[ "${AWG_EGRESS:-direct}" == "warp" && "${AWG_WARP_BYPASS:-none}" != "none" ]] \
       || [[ -e "$_bypass_marker" || -L "$_bypass_marker" ]] \
       || [[ "$_bypass_tx_prepared" -eq 1 ]]; then
        _bypass_tx_needed=1
    fi
    if [[ "$_bypass_tx_needed" -eq 1 ]]; then
        if [[ "$_bypass_tx_prepared" -eq 0 ]]; then
            declare -F snapshot_warp_bypass_state >/dev/null 2>&1 \
                && declare -F setup_warp_bypass >/dev/null 2>&1 \
                || die "Текущий awg_common.sh не поддерживает транзакционный WARP bypass."
            snapshot_warp_bypass_state \
                || die "Не удалось создать полный снимок WARP bypass до изменения."
            if [[ "${AWG_EGRESS:-direct}" == "warp" && "${AWG_WARP_BYPASS:-none}" != "none" ]]; then
                log "Транзакционная настройка WARP bypass (${AWG_WARP_BYPASS})..."
            else
                log "Транзакционное удаление прежнего installer-owned WARP bypass..."
            fi
            setup_warp_bypass \
                || die "WARP bypass не приведён в запрошенное состояние; выполняется rollback."
        fi
        verify_fork_egress_runtime 1 \
            || die "Fork egress после WARP bypass не прошёл exact route/rule-проверку."
    fi

    # DNS — последняя обязательная fallible-настройка. Snapshot остаётся
    # активным до общего commit, поэтому поздняя ошибка сначала вернёт старый
    # awg0/gateway, а затем прежние resolver files, UFW и unit-state.
    if [[ "${AWG_AMNEZIA_DNS:-off}" == "on" ]]; then
        log "Настройка AmneziaDNS (dnsmasq на tunnel-gateway)..."
        declare -F snapshot_amnezia_dns_state >/dev/null 2>&1 \
            && declare -F setup_amnezia_dns >/dev/null 2>&1 \
            || die "Текущий awg_common.sh не поддерживает транзакционный AmneziaDNS."
        snapshot_amnezia_dns_state \
            || die "Не удалось взвести install-level snapshot AmneziaDNS."
        if ! setup_amnezia_dns; then
            die "Ошибка setup_amnezia_dns. См. лог."
        fi
    fi

    # Commit point: новый awg0 уже active и прошёл полную проверку. С этого
    # момента ошибка cleanup не должна возвращать старый конфиг поверх рабочего
    # нового интерфейса. Старые ресурсы удаляем best-effort, сохраняя marker'ы
    # для повторной попытки при любой ошибке.
    _INSTALL_ROLLBACK_AWG0=0
    _INSTALL_ROLLBACK_UPSTREAM=0
    _INSTALL_ROLLBACK_DEP_ACTIVE=0
    _INSTALL_ROLLBACK_OLD_SUPPORT=0
    _INSTALL_ROLLBACK_UFW_CASCADE_RULE=0
    if [[ "$_INSTALL_ROLLBACK_UFW_MAIN_RULE" -eq 1 || "$_INSTALL_UFW_MAIN_MARKER_RESOLVED" -eq 1 ]]; then
        _INSTALL_ROLLBACK_UFW_MAIN_RULE=0
        _INSTALL_UFW_MAIN_MARKER_RESOLVED=0
        rm -f -- "$AWG_DIR/.ufw_main_cleanup_pending" \
            || log_warn "Post-commit: не удалось удалить UFW main-route marker."
    elif ufw_main_route_required \
         && [[ -e "$AWG_DIR/.ufw_main_cleanup_pending" || -L "$AWG_DIR/.ufw_main_cleanup_pending" ]]; then
        if [[ -f "$AWG_DIR/.ufw_main_cleanup_pending" && ! -L "$AWG_DIR/.ufw_main_cleanup_pending" ]]; then
            rm -f -- "$AWG_DIR/.ufw_main_cleanup_pending" \
                || log_warn "Post-commit: не удалось снять больше не нужный UFW main-route marker."
        else
            log_warn "Post-commit: небезопасный UFW main-route marker сохранён."
        fi
    fi
    # Закрываем все common transactions, пока INT/TERM ещё заблокированы.
    # Эти commit-hooks лишь удаляют snapshots: рабочий новый awg0 уже disarmed
    # и не должен объявляться сломанным из-за best-effort удаления backup.
    if declare -F commit_warp_bypass_state >/dev/null 2>&1; then
        commit_warp_bypass_state \
            || log_warn "Post-commit: не удалось удалить временный WARP bypass snapshot."
    fi
    if declare -F commit_warp_egress_state >/dev/null 2>&1; then
        commit_warp_egress_state \
            || log_warn "Post-commit: не удалось удалить временный WARP egress snapshot."
    fi
    if declare -F commit_amnezia_dns_state >/dev/null 2>&1; then
        commit_amnezia_dns_state \
            || log_warn "Post-commit: не удалось удалить временный AmneziaDNS snapshot."
    fi
    # Parked proof остаётся на диске для best-effort/next-run cleanup, но после
    # commit его уже нельзя возвращать в live ownership по INT/TERM.
    _INSTALL_ROLLBACK_WARP_PARKED=0
    local _post_commit_cleanup_failed=0
    if [[ -n "${PREV_AWG_PORT:-}" && "$PREV_AWG_PORT" =~ ^[0-9]+$ \
          && "$PREV_AWG_PORT" != "$AWG_PORT" ]]; then
        if delete_owned_ufw_udp_allow_if_present "$PREV_AWG_PORT" "AmneziaWG VPN"; then
            log "Post-commit UFW: правило старого порта ${PREV_AWG_PORT}/udp удалено."
            sed -i '/^export PREV_AWG_PORT=/d' "$CONFIG_FILE" 2>/dev/null \
                || log_warn "Не удалось убрать PREV_AWG_PORT из $CONFIG_FILE."
            PREV_AWG_PORT=""
        else
            log_warn "Post-commit UFW: старый порт ${PREV_AWG_PORT}/udp не удалён; попытка повторится."
            _post_commit_cleanup_failed=1
        fi
    fi
    if [[ "${AWG_AMNEZIA_DNS:-off}" != "on" || "${AWG_ROLE:-single}" == "exit" ]]; then
        teardown_amnezia_dns || {
            log_warn "Post-commit cleanup: прежний AmneziaDNS очищен не полностью; новый awg0 оставлен рабочим."
            _post_commit_cleanup_failed=1
        }
    fi
    finalize_deferred_mode_cleanup || _post_commit_cleanup_failed=1
    if [[ "$_post_commit_cleanup_failed" -eq 1 ]]; then
        log_warn "Новый awg0 работает, но часть старых owned-ресурсов сохранена для безопасной повторной очистки."
    fi

    log "Шаг 7 успешно завершен."
    # До durable state=99 INT/TERM остаются заблокированы. SIGKILL/power-loss
    # оставят state=7, который безопасно распознаётся exact owned-live resume.
    update_state 99
    trap '_install_on_signal 130' INT
    trap '_install_on_signal 143' TERM
}

# ==============================================================================
# ШАГ 99: Завершение
# ==============================================================================

step99_finish() {
    log "### ЗАВЕРШЕНИЕ УСТАНОВКИ ###"
    log "=============================================================================="
    log "Установка и настройка AmneziaWG 2.0 УСПЕШНО ЗАВЕРШЕНА!"
    log " "
    log "КЛИЕНТСКИЕ ФАЙЛЫ:"
    log "  Конфиги (.conf) и QR-коды (.png) в: $AWG_DIR"
    log "  Скопируйте их безопасным способом."
    log "  Пример (на вашем ПК):"
    log "    scp root@<IP_СЕРВЕРА>:$AWG_DIR/*.conf ./"
    log " "
    log "ПОЛЕЗНЫЕ КОМАНДЫ:"
    log "  sudo bash $MANAGE_SCRIPT_PATH help   # Управление клиентами"
    log "  systemctl status awg-quick@awg0      # Статус VPN"
    log "  awg show                              # Статус AmneziaWG"
    log "  ufw status verbose                    # Статус Firewall"
    log " "
    log "ВАЖНО: Для подключения используйте клиент Amnezia VPN >= 4.8.12.7"
    log "       с поддержкой протокола AWG 2.0"
    log " "
    cleanup_apt
    log " "

    # Финальные проверки
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Файл настроек $CONFIG_FILE: OK"
    else
        log_error "Файл настроек $CONFIG_FILE ОТСУТСТВУЕТ!"
    fi

    # Удаление файла состояния
    log "Удаление файла состояния установки..."
    # Снимок защищаемых пакетов тоже уходит: он нужен между шагами, а пережив
    # установку, стал бы стареть. Устаревшее имя (пакет переименован сменой
    # выпуска) останавливало бы следующую установку без внятной причины.
    rm -f "$STATE_FILE" "${STATE_FILE}.lock" "$AWG_DIR/.boot_id_before_step2" \
          "$BOOT_CRITICAL_SNAPSHOT_FILE" || log_warn "Не удалось удалить $STATE_FILE"
    log "Установка полностью завершена. Лог: $LOG_FILE"
    log "=============================================================================="
}

# ==============================================================================
# Основной цикл выполнения
# ==============================================================================

if [[ "$HELP" -eq 1 ]]; then show_help; fi
if [[ "$UNINSTALL" -eq 1 ]]; then
    [[ "$(id -u)" -eq 0 ]] || die "Деинсталляция требует root (sudo bash $0 --uninstall)."
    mkdir -p "$AWG_DIR" || die "Не удалось открыть рабочий каталог $AWG_DIR."
    INSTALL_LOCK_FILE="$AWG_DIR/.install.lock"
    exec 9>"$INSTALL_LOCK_FILE" || die "Не могу открыть $INSTALL_LOCK_FILE"
    flock -n 9 || die "Другой install/uninstall уже выполняется. Дождитесь его завершения."
    touch "$LOG_FILE" && chmod 640 "$LOG_FILE" || die "Не удалось подготовить $LOG_FILE."
    step_uninstall
fi
if [[ "$DIAGNOSTIC" -eq 1 ]]; then create_diagnostic_report; exit 0; fi
if [[ "$VERBOSE" -eq 1 ]]; then set -x; fi

# v5.13.0: idempotency-страж — если AmneziaWG уже установлен и работает,
# повторный запуск даром тратит ~20 минут (Step 1 ещё раз настраивает sysctl/swap/BBR,
# `apt-get upgrade` может подтянуть новое ядро и заставить пользователя
# заново перезагружаться, Step 7 рестартит awg-quick@awg0 — handshake
# отваливаются на несколько секунд). Серверные ключи, пиры и параметры
# обфускации сохраняются при повторе, но без явного opt-in это поведение
# выглядит как «тихая переустановка». Защищаемся явным флагом.
# Поднимает ENV AWG_FORCE_REINSTALL=1 ровно так же, как CLI-флаг.
if [[ "${AWG_FORCE_REINSTALL:-0}" == "1" ]]; then
    FORCE_REINSTALL=1
fi
# Валидный unfinished setup_state имеет приоритет над idempotency guard: после
# reboot принудительной переустановки пользователь не обязан повторять --force.
_resume_install_in_progress=0
if [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]]; then
    IFS= read -r _resume_state < "$STATE_FILE" || _resume_state=""
    [[ "$_resume_state" =~ ^[1-7]$ ]] && _resume_install_in_progress=1
fi
if [[ "$FORCE_REINSTALL" -ne 1 && "$_resume_install_in_progress" -ne 1 ]] && [[ -f "$SERVER_CONF_FILE" ]] \
   && systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
    log_error "AmneziaWG уже установлен и запущен."
    log_error "Чтобы переустановить — добавьте --force (или AWG_FORCE_REINSTALL=1)."
    log_error "ВНИМАНИЕ: переустановка снова прогонит шаги 1 (sysctl/swap/BBR) и 7 (рестарт сервиса)."
    log_error "          Параметры обфускации (Jc/Jmin/Jmax/H1-H4/I1) сохранятся, ЕСЛИ не передавать"
    log_error "          --preset/--jc/--jmin/--jmax (эти флаги перегенерируют весь набор - все"
    log_error "          выданные клиентские конфиги придётся перевыпустить через regen)."
    log_error "Для управления клиентами:  sudo bash $MANAGE_SCRIPT_PATH help"
    log_error "Для полного удаления:      sudo bash $0 --uninstall"
    exit 0
fi

initialize_setup

while (( current_step < 99 )); do
    log "Выполнение шага $current_step..."
    case $current_step in
        1) step1_update_and_optimize ;;
        2) step2_install_amnezia ;;
        3) step3_check_module; current_step=4 ;;
        4) step4_setup_firewall; current_step=5 ;;
        5) step5_download_scripts; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service; current_step=99 ;;
        *) die "Ошибка: Неизвестный шаг $current_step." ;;
    esac
done

if (( current_step == 99 )); then step99_finish; fi
exit 0
