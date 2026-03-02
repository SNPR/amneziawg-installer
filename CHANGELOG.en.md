<p align="center">
  🇷🇺 <a href="CHANGELOG.md">Русский</a> | 🇬🇧 <b>English</b>
</p>

# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

---

## [5.2] — 2026-03-03

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
