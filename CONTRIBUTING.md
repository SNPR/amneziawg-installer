# Contributing to amneziawg-installer

Thank you for your interest in contributing! This guide covers the process and conventions for submitting changes.

## How to Contribute

1. **Fork** the repository
2. **Create a branch** from `main` (e.g., `fix/ufw-rules` or `feat/multi-client-export`)
3. **Make your changes** following the code style below
4. **Test** locally and on a clean VPS
5. **Open a Pull Request** against `main`

## Code Style

### General

- All scripts use `set -o pipefail`
- Comments and user-facing text are in **Russian**
- Error handling: use `die()` for fatal errors, `log_error()` / `log_warn()` for non-fatal
- Logging: all output through `log_msg()` with appropriate level (INFO, WARN, ERROR, DEBUG)

### File Operations

- Atomic writes: use `awg_mktemp()` (auto-cleanup via trap) and `mv` to the final destination
- Create backups before modifying existing configs
- Set strict permissions: `chmod 600` for keys/configs, `chmod 700` for directories

### Shell Conventions

- Use `bash` (not `sh` or `zsh`)
- Quote all variable expansions: `"${var}"` instead of `$var`
- Use `[[ ]]` for conditionals (not `[ ]`)
- Prefer `$(command)` over backticks

## Testing Requirements

Before submitting a PR, ensure:

1. **Syntax check** passes:
   ```bash
   for f in install_amneziawg.sh install_amneziawg_en.sh manage_amneziawg.sh manage_amneziawg_en.sh awg_common.sh awg_common_en.sh; do
     bash -n "$f" && echo "OK: $f"
   done
   ```

2. **ShellCheck** passes:
   ```bash
   for f in install_amneziawg.sh install_amneziawg_en.sh manage_amneziawg.sh manage_amneziawg_en.sh awg_common.sh awg_common_en.sh; do
     shellcheck -s bash -S warning "$f"
   done
   ```

3. **VPS testing** (for script changes): test on a clean Ubuntu 24.04 LTS minimal server installation. The full test matrix includes:
   - Fresh install on clean Ubuntu 24.04 LTS
   - Fresh install on clean Ubuntu 25.10
   - All management commands: add, remove, list, regen, check, restart
   - Reboot-resume between critical installer steps
   - Client connectivity (handshake, ping, DNS resolution)
   - Fresh install on clean Debian 12 (bookworm)
   - Fresh install on clean Debian 13 (trixie)
   - Client expiry: add with --expires, verify cron auto-removal
   - Stats: verify `stats` and `stats --json` output

## Multilingual Scripts

When modifying Russian scripts (`*.sh`), update the corresponding English versions (`*_en.sh`):

- `awg_common.sh` → `awg_common_en.sh`
- `manage_amneziawg.sh` → `manage_amneziawg_en.sh`
- `install_amneziawg.sh` → `install_amneziawg_en.sh`

Run `diff install_amneziawg.sh install_amneziawg_en.sh` to verify only text differences remain.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

| Prefix     | Usage                        |
|------------|------------------------------|
| `fix:`     | Bug fix                      |
| `feat:`    | New feature                  |
| `docs:`    | Documentation only           |
| `ci:`      | CI/CD changes                |
| `refactor:`| Code restructuring, no behavior change |
| `test:`    | Adding or updating tests     |
| `chore:`   | Maintenance, dependency updates |

Examples:
```
fix: correct UFW rule ordering for dual-stack setups
feat: add --diagnostic flag for troubleshooting
docs: update CHANGELOG for v5.5
```

## Pull Request Workflow

1. Fill in the PR template completely
2. Ensure CI checks pass (ShellCheck + syntax)
3. Request a review from `@bivlked`
4. Address review feedback
5. Once approved, the maintainer will merge

## Questions?

Open a [discussion](https://github.com/bivlked/amneziawg-installer/discussions) or an issue if you have questions about contributing.
