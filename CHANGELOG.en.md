<p align="center">
  🇷🇺 <a href="CHANGELOG.md">Русский</a> | 🇬🇧 <b>English</b>
</p>

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
- **modify:** Added an allowlist of permitted parameters (DNS, Endpoint, AllowedIPs, Address, PersistentKeepalive, MTU).
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

[5.6.0]: https://github.com/bivlked/amneziawg-installer/compare/v5.5.1...v5.6.0
[5.5.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.5...v5.5.1
[5.5]: https://github.com/bivlked/amneziawg-installer/compare/v5.4...v5.5
[5.4]: https://github.com/bivlked/amneziawg-installer/compare/v5.3...v5.4
[5.3]: https://github.com/bivlked/amneziawg-installer/compare/v5.2...v5.3
[5.2]: https://github.com/bivlked/amneziawg-installer/compare/v5.1...v5.2
[5.1]: https://github.com/bivlked/amneziawg-installer/compare/v5.0...v5.1
[5.0]: https://github.com/bivlked/amneziawg-installer/compare/v4.0...v5.0
[4.0]: https://github.com/bivlked/amneziawg-installer/releases/tag/v4.0
