#!/usr/bin/env bats
# v5.11.3 docs parity tests for Phases 3, 4, 5.
#
# Phase 3: ICMP-in-tunnel FAQ entry (ADVANCED.md / .en.md)
# Phase 4: oper→I1 table extended with I1=absent rows
# Phase 5: --psk highlight in README + cheat sheet
#
# These tests guard against RU/EN drift and confirm cross-references resolve.

# ---------- Phase 3 ----------

@test "Phase 3: ADVANCED.md has ICMP-in-tunnel FAQ entry (sudo ufw allow in on awg0)" {
    run grep -F 'sudo ufw allow in on awg0' "$BATS_TEST_DIRNAME/../ADVANCED.md"
    [ "$status" -eq 0 ]
}

@test "Phase 3: ADVANCED.en.md has ICMP-in-tunnel FAQ entry" {
    run grep -F 'sudo ufw allow in on awg0' "$BATS_TEST_DIRNAME/../ADVANCED.en.md"
    [ "$status" -eq 0 ]
}

@test "Phase 3: ADVANCED docs warn against unsupported 'proto icmp'" {
    run grep -F 'proto icmp' "$BATS_TEST_DIRNAME/../ADVANCED.md"
    [ "$status" -eq 0 ]
    run grep -F 'proto icmp' "$BATS_TEST_DIRNAME/../ADVANCED.en.md"
    [ "$status" -eq 0 ]
}

@test "Phase 3: ICMP FAQ links to discussion #63 in both languages" {
    ru=$(grep -c '/discussions/63' "$BATS_TEST_DIRNAME/../ADVANCED.md")
    en=$(grep -c '/discussions/63' "$BATS_TEST_DIRNAME/../ADVANCED.en.md")
    [ "$ru" -ge 1 ]
    [ "$en" -ge 1 ]
    [ "$ru" = "$en" ]
}

@test "Phase 3: ICMP FAQ covers split-tunneling AllowedIPs gotcha (D#63 follow-up)" {
    # If user customized AllowedIPs on the client, the tunnel subnet must be
    # in the list — otherwise even server-direct ping fails.
    run grep -F 'split tunneling' "$BATS_TEST_DIRNAME/../ADVANCED.md"
    [ "$status" -eq 0 ]
    run grep -F 'split tunneling' "$BATS_TEST_DIRNAME/../ADVANCED.en.md"
    [ "$status" -eq 0 ]
}

# ---------- Phase 4 ----------

@test "Phase 4: oper-I1 table includes Megafon regions row in both languages" {
    run grep -F 'Megafon (регионы)' "$BATS_TEST_DIRNAME/../ADVANCED.md"
    [ "$status" -eq 0 ]
    run grep -F 'Megafon (regions)' "$BATS_TEST_DIRNAME/../ADVANCED.en.md"
    [ "$status" -eq 0 ]
}

@test "Phase 4: I1-absent marker appears 3+ times in both languages" {
    ru=$(grep -c 'I1=отсутствует' "$BATS_TEST_DIRNAME/../ADVANCED.md")
    en=$(grep -c 'I1=absent' "$BATS_TEST_DIRNAME/../ADVANCED.en.md")
    [ "$ru" -ge 3 ]
    [ "$en" -ge 3 ]
    [ "$ru" = "$en" ]
}

@test "Phase 4: oper table row count parity" {
    ru=$(grep -c '<tr><td>' "$BATS_TEST_DIRNAME/../ADVANCED.md")
    en=$(grep -c '<tr><td>' "$BATS_TEST_DIRNAME/../ADVANCED.en.md")
    [ "$ru" = "$en" ]
}

# ---------- Phase 5 ----------

# NB (fork): the fork ships a concise, fork-specific README (cascade/WARP focus),
# so upstream's Phase-5 README assertions (--psk cheat sheet with my_iphone,
# Shadowrocket FAQ, README --psk → ADVANCED#manage-cli-adv link, and the README
# <details> RU/EN parity) were removed here — they pinned upstream's marketing
# README structure that this fork intentionally dropped. The ADVANCED-doc checks
# below (anchor + <details> parity in ADVANCED) still apply unchanged.

@test "Phase 5: anchor target manage-cli-adv exists in both ADVANCED files" {
    run grep -F '<a id="manage-cli-adv">' "$BATS_TEST_DIRNAME/../ADVANCED.md"
    [ "$status" -eq 0 ]
    run grep -F '<a id="manage-cli-adv">' "$BATS_TEST_DIRNAME/../ADVANCED.en.md"
    [ "$status" -eq 0 ]
}

# ---------- Cross-cutting parity ----------

@test "Cross: <details> count identical in ADVANCED RU vs EN" {
    ru=$(grep -c '^<details>' "$BATS_TEST_DIRNAME/../ADVANCED.md")
    en=$(grep -c '^<details>' "$BATS_TEST_DIRNAME/../ADVANCED.en.md")
    [ "$ru" = "$en" ]
}
