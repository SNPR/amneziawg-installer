<p align="center">
  <b>RU</b> <a href="CHANGELOG.md">Русский</a> | <b>EN</b> English
</p>

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [Unreleased]

---

## [5.7.7] — 2026-03-24

### Fixed

- **Peer loss on reinstall:** `render_server_config` overwrote `awg0.conf` from scratch. Existing `[Peer]` blocks are now automatically restored from backup when step 6 re-runs.
- **Race condition when adding clients (TOCTOU):** `get_next_client_ip` and `add_peer_to_server` now execute in a single critical section (`flock` in `generate_client`). Two parallel `add` operations can no longer pick the same IP.
- **Silent restore success on failure:** `restore_backup` now returns non-zero exit code when file copy errors occur, instead of silently reporting success.
- **Config parser double quote support:** `safe_load_config` now correctly handles double-quoted values (`"value"`) in addition to single quotes.

---

## [5.7.6] — 2026-03-24

### Fixed

- **UFW blocks VPN traffic (Discussion #28):** Added `ufw route allow in on awg0 out on <nic>` rule during firewall setup. Previously, the default `deny (routed)` policy blocked forwarded packets from awg0 to the main interface, despite PostUp iptables rules. The rule is automatically removed on uninstall.
- **PostUp FORWARD ordering:** Changed `iptables -A FORWARD` to `iptables -I FORWARD` to insert the rule at the top of the chain. Ensures correct routing when UFW is absent (`--no-tweaks`).

---

## [5.7.5] — 2026-03-20

### Fixed

- **Trailing newlines in awg0.conf (#27):** Multiple blank lines accumulated in the server config after peer removals. Added normalization via `cat -s` on each remove.
- **Timeout for awg syncconf (#27):** `awg-quick strip` and `awg syncconf` are now called with `timeout 10`. On hang (upstream deadlock [amneziawg-linux-kernel-module#146](https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/issues/146)), the script falls back to a full service restart instead of waiting indefinitely.

---

## [5.7.4] — 2026-03-20

### Fixed

- **MTU 1280 by default (Closes #26):** Server and client configs now include `MTU = 1280`. Fixes smartphone connectivity over cellular networks and on iPhone.
- **Jmax cap:** Maximum junk packet size capped at `Jmin+500` (was `Jmin+999`). Prevents fragmentation with MTU 1280.
- **validate_subnet:** Last subnet octet must be 1 (server address). Previously allowed arbitrary values, causing conflicts with `get_next_client_ip`.
- **awg show dump parsing:** Interface line skipped via `tail -n +2` instead of unreliable empty psk field check.
- **manage help without AWG:** `help` and empty command show usage before `check_dependencies`, allowing `--help` without AWG installed.
- **help text:** Installer help now lists all 4 supported OS (Ubuntu 24.04/25.10, Debian 12/13).
- **manage --expires help:** Added `4w` format to `--expires` help text (already supported by parser, but missing from help).

### Improved

- **IP caching:** `get_server_public_ip()` caches the result — repeated calls (add/regen) skip external service requests.
- **O(N) IP lookup:** `get_next_client_ip()` uses an associative array for free IP lookup instead of O(N²) nested loops.

### Documentation

- Fixed client compatibility table: `amneziawg-windows-client >= 2.0.0` supports AWG 2.0 (previously incorrectly listed as AWG 1.x only).
- Fixed APT format for Ubuntu 24.04: DEB822 `.sources` (was `.list`).
- Fixed `restore` example in migration FAQ: correct path `/root/awg/backups/`.
- Fixed uninstall reference in EN README FAQ: `install_amneziawg_en.sh`.
- Added Ubuntu 25.10 to the "Which hosting?" FAQ answer.
- Updated config examples: added `MTU = 1280`.
- Updated Jmax range in parameters table: `+500` instead of `+999`.
- Rewrote MTU section: automatic for v5.7.4+, manual workaround for older versions.
- Removed "MTU not set" from Known Limitations.
- Updated "How to change MTU?" FAQ for automatic MTU.

---

## [5.7.3] — 2026-03-18

### Fixed

- **Uninstall SSH lockout:** UFW is now disabled BEFORE fail2ban unban — prevents SSH lockout if the connection drops during uninstall.
- **CIDR validation (strict):** Invalid CIDR in `--route-custom` now calls `die()` in CLI mode. In interactive mode — retry prompt. Previously, installation continued with invalid AllowedIPs.
- **validate_subnet .0/.255:** Subnets with last octet 0 (network address) or 255 (broadcast) are now rejected.
- **ALLOWED_IPS resume:** Custom CIDR values (mode=3) are now validated when resuming installation from saved config.
- **modify sed mismatch:** Synchronized sed pattern with grep in `modify_client()` — handles .conf files with any whitespace formatting around `=`. Added post-replacement verification.
- **--no-color ANSI leak:** Fixed ESC code `\033[0m` leaking into `list --no-color` output.
- **Uninstall wildcard cleanup:** Removed meaningless wildcard patterns from uninstall — `*amneziawg*` files in `/etc/cron.d/` and `/usr/local/bin/` were never created.

### Documentation

- Added AmneziaWG for Windows 2.0.0 as a supported client.
- Removed misleading note about curl requirement on Debian.

---

## [5.7.2] — 2026-03-16

### Security

- **safe_load_config():** Replaced `source` with a whitelist config parser in `awg_common.sh` — only permitted keys (AWG_*, OS_*, DISABLE_IPV6, etc.) are loaded from the file. Eliminates potential code injection via `awgsetup_cfg.init`.
- **Supply chain pinning:** Script download URLs are pinned to the version tag (`AWG_BRANCH=v${SCRIPT_VERSION}`) instead of `main`. The `AWG_BRANCH` variable can be overridden for development.
- **HTTPS for IP detection:** `get_server_public_ip()` uses HTTPS instead of HTTP for external IP detection.

### Fixed

- **modify allowlist:** Removed Address and MTU from allowed `modify` parameters — these are managed by the installer and should not be changed manually.
- **flock for add/remove peer:** Peer addition and removal operations are protected with `flock -x` to prevent race conditions during parallel invocations.
- **cron expiry env:** Expiry cron job explicitly sets PATH and uses `--conf-dir` for correct operation in minimal cron environments.
- **log_warn for malformed expiry:** Malformed expiry files are handled via `log_warn` instead of being silently skipped.
- **Dead code:** Removed unused functions and variables from `awg_common.sh`.

### Changed

- **list_clients O(N):** Optimized `list_clients` — single-pass algorithm instead of O(N*M).
- **backup/restore:** Backups now include client expiry data (`expiry/`) and cron job.
- **Version:** 5.7.1 → 5.7.2 across all scripts.

---

## [5.7.1] — 2026-03-13

### Fixed

- **vpn:// URI AllowedIPs:** `generate_vpn_uri()` was hardcoding `0.0.0.0/0` instead of using actual AllowedIPs from client config — split-tunnel configurations are now correctly passed to the URI.
- **Fail2Ban jail.d:** Installation now writes to `/etc/fail2ban/jail.d/amneziawg.conf` instead of overwriting `jail.local` — user Fail2Ban customizations are preserved.
- **Fail2Ban uninstall:** Uninstall now removes only its own artifacts instead of `rm -rf /etc/fail2ban/`.
- **validate_client_name:** Client name validation added to `remove` and `modify` commands — previously only worked for `add` and `regen`.
- **exit code:** Management script now returns proper error codes instead of unconditional `exit 0`.
- **expiry cron path:** Expiry cron job uses `$AWG_DIR` instead of hardcoded `/root/awg/`.

### Removed

- **rand_range():** Removed unused function from `awg_common.sh` (installer defines its own copy).

---

## [5.7.0] — 2026-03-13

### Added

- **syncconf:** `add` and `remove` commands now auto-apply changes via `awg syncconf` — zero-downtime, no active connection drops (#19).
- **apply_config():** New function in `awg_common.sh` — applies config via `awg syncconf` with fallback to full restart.
- **--no-tweaks:** Installer flag — skips hardening (UFW, Fail2Ban, sysctl tweaks, cleanup) for advanced users with pre-configured servers (#21).
- **setup_minimal_sysctl():** Minimal sysctl configuration for `--no-tweaks` — only `ip_forward` and IPv6 settings.

### Fixed

- **trap conflict:** Fixed EXIT handler being overwritten when sourcing `awg_common.sh`. Each script now owns its trap and chains the library cleanup explicitly.

### Changed

- **Expiry cleanup:** Auto-removal of expired clients now uses `syncconf` instead of full restart.
- **Manage help:** Removed manual restart warning after `add`/`remove` (no longer required).
- **Version:** 5.6.0 → 5.7.0 across all scripts.

---

## [5.6.0] — 2026-03-13

### Added

- **stats:** `stats` command — per-client traffic statistics (format_bytes via awk).
- **stats --json:** Machine-readable JSON output for integration and monitoring.
- **--expires:** `--expires=DURATION` flag for `add` — time-limited clients (1h, 12h, 1d, 7d, 30d, 4w).
- **Expiry system:** Auto-removal of expired clients via cron (`/etc/cron.d/awg-expiry`, checks every 5 min).
- **vpn:// URI:** Generation of `.vpnuri` files for one-tap import into Amnezia Client (zlib compression via Perl).
- **Debian 12 (bookworm):** Full support — PPA via codename mapping to focal.
- **Debian 13 (trixie):** Full support — PPA via codename mapping to noble, DEB822 format.
- **linux-headers fallback:** Auto-fallback to `linux-headers-$(dpkg --print-architecture)` on Debian.

### Fixed

- **JSON sanitization:** Safe serialization in JSON output.
- **Numeric quoting:** AWG numeric parameters properly quoted.
- **O(n) stats:** Single-pass stats collection instead of multiple calls.
- **backup filename:** `%F_%T` → `%F_%H%M%S` (removed colons from filename).
- **cron auto-remove:** Cron cleanup when the last expiry client is removed.
- **backups perms:** `chmod 700` after `mkdir` for the backups directory.
- **apt sources location:** Apt sources backup moved to `$AWG_DIR` instead of `sources.list.d`.
- Multiple minor fixes from code review (19 fixes).

### Changed

- **Debian-aware installer:** OS_ID detection, adaptive behavior (cleanup, PPA, headers).
- **Version:** 5.5.1 → 5.6.0 across all scripts.

---

## [5.5.1] — 2026-03-05

### Fixed

- **read -r:** Added `-r` flag to all `read -p` calls (15 places) — prevents `\` from being interpreted as an escape character in user input.
- **curl timeout:** Added `--max-time 60 --retry 2` to script downloads during installation — prevents indefinite hanging on network issues.
- **subnet validation:** Subnet validation now checks each octet ≤ 255 — previously accepted addresses like `999.999.999.999/24`.
- **chmod checks:** Added error checking for `chmod 600` when setting permissions on key files.
- **pipe subshell:** Fixed variable loss in config regeneration loop due to pipe subshell — replaced with here-string.
- **port grep:** Improved port matching precision in `ss -lunp` — replaced `grep ":PORT "` with `grep -P ":PORT\s"` to avoid false matches.
- **sed → bash:** Replaced `sed 's/%/%%/g'` with `${msg//%/%%}` — removed 2 unnecessary subprocesses per log call.
- **cleanup trap:** Added `trap EXIT` for automatic cleanup of installer temp files.

---

## [5.5] — 2026-03-02

### Fixed

- **uninstall:** Uninstall proceeded without confirmation when `/dev/tty` was unavailable (pipe, cron, non-TTY SSH) due to default `confirm="yes"`.
- **uninstall:** Kernel module `amneziawg` remained loaded after uninstall — added `modprobe -r`.
- **uninstall:** Working directory `/root/awg/` was recreated by logging after deletion — moved cleanup to the end.
- **uninstall:** Empty `/etc/fail2ban/` and PPA backup `.bak-*` files remained after uninstall.
- **--no-color:** Reset escape code `\033[0m` was not suppressed with `--no-color` — fixed `color_end` initialization.
- **step99:** Duplicate "Cleaning apt…" message — removed extra `log` call before `cleanup_apt()`.
- **step99:** Lock file `setup_state.lock` was not removed after installation completed.
- **manage:** Inconsistent spelling "удален"/"удалён" — standardized (RU only).

---

## [5.4] — 2026-03-02

### Fixed

- **step5:** `manage_amneziawg.sh` download failure is now fatal (`die`), consistent with `awg_common.sh`.
- **update_state():** `die()` inside flock subshell did not terminate the main process — moved outside.
- **step6:** Server config backup now created *before* `render_server_config`, not after overwrite.
- **cloud-init:** Conservative detection — cloud-init markers checked first to avoid removing it on cloud hosts.
- **restore_backup():** Added non-interactive guard (explicit file path required in automation).
- **Subnet:** Validation now only allows `/24` mask (matches actual IP allocation logic).
- **Version:** Removed stale `v5.1` references in logs/diagnostics; introduced `SCRIPT_VERSION` constant.

---

## [5.3] — 2026-03-02

### Added

- **English scripts:** Full English versions of all three scripts (`install_amneziawg_en.sh`, `manage_amneziawg_en.sh`, `awg_common_en.sh`) with translated messages, help text, and comments.
- **CI:** ShellCheck and `bash -n` checks for English scripts.
- **PR template:** Checklist item for EN/RU version synchronization.
- **CONTRIBUTING.md:** Requirement to synchronize EN/RU when modifying scripts.

---

## [5.2] — 2026-03-02

### Fixed

- **check_server():** Fixed inverted exit code (return 1 on success → return 0).
- **Diagnostics restart/restore:** `systemctl status` output is now correctly captured in the log.
- **restore_backup():** Server config restoration path now uses `$SERVER_CONF_FILE`.

### Changed

- **awg_mktemp():** Activated automatic temp file cleanup via trap EXIT.
- **modify:** Added an allowlist of permitted parameters (DNS, Endpoint, AllowedIPs, Address, PersistentKeepalive, MTU). *(Address and MTU removed in v5.7.2)*
- **Documentation:** Removed incorrect mention of /16 subnet support.
- Removed dead trap code from install_amneziawg.sh.

---

## [5.1] — 2026-03-01

### Fixed

- **CRITICAL:** Command injection via special characters `#`, `&`, `/`, `\` in `modify_client()` — added `escape_sed()` function for escaping.
- **CRITICAL:** Race condition in `update_state()` — added locking via `flock -x`.
- **MEDIUM:** `curl` in `get_server_public_ip()` could receive HTML instead of IP — added `-f` flag (fail on error) and whitespace cleanup.
- **MEDIUM:** `$RANDOM` fallback in `rand_range()` gave max 32767 instead of uint32 — replaced with `(RANDOM<<15|RANDOM)` for 30-bit range.
- **MEDIUM:** Pipe subshell in `check_server()` — replaced with process substitution `< <(...)`.
- **MEDIUM:** Awk script in `remove_peer_from_server()` didn't handle non-standard sections — added handling for any `[...]` blocks.

### Added

- **CI:** GitHub Actions workflow — ShellCheck + `bash -n` on push/PR to main.
- **GitHub:** Issue templates (bug report, feature request) in YAML form format.
- **GitHub:** PR template with checklist (bash -n, shellcheck, VPS test, changelog).
- **SECURITY.md:** Security policy, responsible vulnerability disclosure.
- **CONTRIBUTING.md:** Contributor guide with code and testing requirements.
- **.editorconfig:** Unified formatting settings (UTF-8, LF, indentation).
- **Trap cleanup:** Automatic temp file cleanup via `trap EXIT` + `awg_mktemp()`.
- **Bash version check:** `Bash >= 4.0` check at the start of install and manage scripts.
- **Documentation:** Config examples, Mermaid architecture diagram, extended FAQ, troubleshooting.

### Changed

- **Version:** 5.0 → 5.1 across all scripts and documentation.
- **README.md:** Command table expanded to 10 (+ modify, backup, restore), FAQ expanded to 8 questions.
- **ADVANCED.md:** Added config examples, manage command examples, diagnostics description, update instructions.

---

## [5.0] — 2026-03-01

### ⚠️ Breaking Changes

- **AWG 2.0 protocol** is not compatible with AWG 1.x. All clients must update their configuration.
- Requires **Amnezia VPN >= 4.8.12.7** client with AWG 2.0 support.
- Previous version is available in the [`legacy/v4`](https://github.com/bivlked/amneziawg-installer/tree/legacy/v4) branch.

### Added

- **AWG 2.0:** Full protocol support — parameters H1-H4 (ranges), S1-S4, CPS (I1).
- **Native generation:** All keys and configs generated using Bash + `awg` with no external dependencies.
- **awg_common.sh:** Shared function library for install and manage scripts.
- **Server cleanup:** Automatic removal of unnecessary packages (snapd, modemmanager, networkd-dispatcher, unattended-upgrades, etc.).
- **Hardware-aware optimization:** Automatic swap, network buffer, and sysctl tuning based on server characteristics (RAM, CPU, NIC).
- **NIC optimization:** GRO/GSO/TSO offload disabling for stable VPN tunnel operation.
- **Extended sysctl hardening:** Adaptive network buffers, conntrack, additional protection.
- **Individual client regeneration:** `regen <name>` command for regenerating a single client's configs.
- **AWG 2.0 validation:** Verification of all protocol parameters in the server config.
- **AWG 2.0 diagnostics:** `check` command shows AWG 2.0 parameter status.

### Removed

- **Python/venv/awgcfg.py:** Python dependency and external config generator completely removed.
- **awgcfg.py bug workaround:** Moving `awgsetup_cfg.init` during generation is no longer necessary.
- **Parameters j1-j3, itime:** Legacy AWG 1.x parameters are no longer supported.

### Changed

- **Architecture:** 2 files → 3 files (install + manage + awg_common.sh).
- **Install step 1:** Added system cleanup and optimization.
- **Install step 2:** Installs `qrencode` instead of Python.
- **Install step 5:** Downloads `awg_common.sh` + `manage` (no Python/venv).
- **Install step 6:** Fully native config generation.
- **Key generation:** Native via `awg genkey` / `awg pubkey`.
- **QR codes:** Generated via `qrencode` directly (no Python).
- **Documentation:** README.md and ADVANCED.md updated for AWG 2.0.

---

## [4.0] — 2025-07-15

### Added

- AWG 1.x support (Jc, Jmin, Jmax, S1, S2, H1-H4 fixed values).
- DKMS installation.
- Config generation via Python + awgcfg.py.
- Client management: add, remove, list, regen, modify, backup, restore.
- UFW firewall, Fail2Ban, sysctl hardening.
- Resume-after-reboot support.
- Diagnostic report (`--diagnostic`).
- Full uninstall (`--uninstall`).

[Unreleased]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.3...HEAD
[5.7.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.2...v5.7.3
[5.7.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.1...v5.7.2
[5.7.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.7.0...v5.7.1
[5.7.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.6.0...v5.7.0
[5.6.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.5.1...v5.6.0
[5.5.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.5...v5.5.1
[5.5]: https://github.com/bivlked/amneziawg-installer/compare/v5.4...v5.5
[5.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.3...v5.4
[5.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.2...v5.3
[5.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.1...v5.2
[5.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.0...v5.1
[5.0]: https://github.com/bivlked/amneziawg-installer/compare/v4.0...v5.0
[4.0]: https://github.com/bivlked/amneziawg-installer/releases/tag/v4.0
