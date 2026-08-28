#!/usr/bin/env bash

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dotfiles-install-test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

pass=0
fail=0

ok() { pass=$((pass + 1)); printf '  PASS  %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; }
check() { if "$@"; then ok "$LABEL"; else bad "$LABEL"; fi; }

CLAUDE_TEST_HOME="$SCRATCH/claude"
CODEX_TEST_HOME="$SCRATCH/codex"
mkdir -p "$CLAUDE_TEST_HOME/commands" "$CODEX_TEST_HOME/skills/session-insights"
printf 'personal command\n' > "$CLAUDE_TEST_HOME/commands/wrap.md"
printf 'personal skill\n' > "$CODEX_TEST_HOME/skills/session-insights/SKILL.md"

out="$(CLAUDE_HOME="$CLAUDE_TEST_HOME" CODEX_HOME="$CODEX_TEST_HOME" "$ROOT/install.sh" 2>&1)"
rc=$?
printf '%s\n' "$out"
LABEL="first install succeeds"; check test "$rc" -eq 0
LABEL="Claude command is symlinked"; check test -L "$CLAUDE_TEST_HOME/commands/wrap.md"
LABEL="Codex skill package is symlinked"; check test -L "$CODEX_TEST_HOME/skills/session-insights"
LABEL="existing Claude command is backed up"; check grep -q 'personal command' "$CLAUDE_TEST_HOME/commands/wrap.md.pre-dotfiles"
LABEL="existing Codex skill is backed up"; check grep -q 'personal skill' "$CODEX_TEST_HOME/skills/session-insights.pre-dotfiles/SKILL.md"

first_target="$(readlink "$CODEX_TEST_HOME/skills/session-insights")"
out="$(CLAUDE_HOME="$CLAUDE_TEST_HOME" CODEX_HOME="$CODEX_TEST_HOME" "$ROOT/install.sh" 2>&1)"
rc=$?
LABEL="second install succeeds"; check test "$rc" -eq 0
LABEL="second install preserves the skill target"; check test "$(readlink "$CODEX_TEST_HOME/skills/session-insights")" = "$first_target"
LABEL="second install preserves the original backup"; check grep -q 'personal skill' "$CODEX_TEST_HOME/skills/session-insights.pre-dotfiles/SKILL.md"

DRY_CLAUDE="$SCRATCH/dry-claude"
DRY_CODEX="$SCRATCH/dry-codex"
out="$(CLAUDE_HOME="$DRY_CLAUDE" CODEX_HOME="$DRY_CODEX" "$ROOT/install.sh" --dry-run 2>&1)"
rc=$?
LABEL="dry run succeeds"; check test "$rc" -eq 0
LABEL="dry run does not create Claude home"; check test ! -e "$DRY_CLAUDE"
LABEL="dry run does not create Codex home"; check test ! -e "$DRY_CODEX"

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
test "$fail" -eq 0
