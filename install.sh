#!/usr/bin/env bash
#
# Install this repo's Claude Code commands/hooks and Codex skills.
#
# Files are SYMLINKED, not copied, so `git pull` here updates what Claude runs.
# The one exception is the pinned-checkout config, which is per-machine and is
# never written by this script.
#
#   ./install.sh              # symlink Claude commands/hooks and Codex skills
#   ./install.sh --dry-run    # print what would happen, touch nothing
#   ./install.sh --settings   # additionally merge settings.hooks.json into
#                             # ~/.claude/settings.json, if that is safe (see below)
#
# WHY --settings IS OPT-IN AND CONDITIONAL. Claude Code's settings.json keys each
# hook event to an ARRAY. Merging two settings files with `jq '.[0] * .[1]'`
# deep-merges objects but REPLACES arrays, so a machine that already has a
# PreToolUse hook would silently lose it. This script therefore merges only when
# ~/.claude/settings.json has no "hooks" key at all, and otherwise prints the
# block for you to paste. It backs the file up either way.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DEST="${CLAUDE_HOME:-$HOME/.claude}"
CODEX_DEST="${CODEX_HOME:-$HOME/.codex}"
DRY=0
DO_SETTINGS=0

for arg in "$@"; do
  case "$arg" in
    --dry-run)  DRY=1 ;;
    --settings) DO_SETTINGS=1 ;;
    -h|--help)  sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '%s\n' "$*"; }
run() { if [ "$DRY" = 1 ]; then say "  would: $*"; else "$@"; fi; }

# link <source> <target>
link() {
  local src="$1" dst="$2"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    say "  ok:    $dst (already linked)"
    return 0
  fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    # Never clobber a real file. Move it aside with a suffix that says why.
    local backup="$dst.pre-dotfiles"
    if [ -e "$backup" ] || [ -L "$backup" ]; then
      say "  REFUSED: $dst needs a backup, but $backup already exists"
      return 1
    fi
    say "  moved: $dst -> $(basename "$backup")"
    run mv "$dst" "$backup"
  fi
  say "  link:  $dst"
  run ln -s "$src" "$dst"
}

say "installing from $REPO"
say "  Claude: $CLAUDE_DEST"
say "  Codex:  $CODEX_DEST"
[ "$DRY" = 1 ] && say "(dry run)"

run mkdir -p "$CLAUDE_DEST/commands" "$CLAUDE_DEST/hooks/tests" "$CODEX_DEST/skills"

say
say "commands:"
for f in "$REPO"/claude/commands/*.md; do
  [ -e "$f" ] || continue
  link "$f" "$CLAUDE_DEST/commands/$(basename "$f")"
done

say
say "hooks:"
for f in "$REPO"/claude/hooks/*.sh; do
  [ -e "$f" ] || continue
  link "$f" "$CLAUDE_DEST/hooks/$(basename "$f")"
done
for f in "$REPO"/claude/hooks/tests/*.sh; do
  [ -e "$f" ] || continue
  link "$f" "$CLAUDE_DEST/hooks/tests/$(basename "$f")"
done

say
say "Codex skills:"
for skill in "$REPO"/codex/skills/*; do
  [ -d "$skill" ] || continue
  [ -f "$skill/SKILL.md" ] || {
    say "  REFUSED: $skill is not a skill package (SKILL.md is missing)"
    exit 1
  }
  link "$skill" "$CODEX_DEST/skills/$(basename "$skill")"
done

say
say "pinned-checkout config:"
if [ -e "$CLAUDE_DEST/hooks/pinned-checkout.conf" ]; then
  say "  ok:    $CLAUDE_DEST/hooks/pinned-checkout.conf exists (left alone)"
else
  say "  none:  git-guard's Rule 1 and the tripwire stay INERT until you write it."
  say "         cp $REPO/claude/hooks/pinned-checkout.conf.example $CLAUDE_DEST/hooks/pinned-checkout.conf"
  say "         (destructive-git prompts work with no config at all)"
fi

say
say "settings:"
SETTINGS="$CLAUDE_DEST/settings.json"
BLOCK="$REPO/claude/settings.hooks.json"
if ! command -v jq >/dev/null 2>&1; then
  say "  jq not installed; merge $BLOCK into $SETTINGS by hand."
elif [ "$DO_SETTINGS" != 1 ]; then
  say "  not touched. Re-run with --settings to merge, or paste $BLOCK yourself."
elif [ ! -f "$SETTINGS" ]; then
  say "  writing $SETTINGS (did not exist)"
  run cp "$BLOCK" "$SETTINGS"
elif jq -e 'has("hooks")' "$SETTINGS" >/dev/null 2>&1; then
  say "  REFUSED: $SETTINGS already defines hooks."
  say "  Merging would replace those arrays wholesale and silently drop them."
  say "  Merge the events you want from $BLOCK by hand."
else
  say "  backing up to $SETTINGS.pre-dotfiles and merging the hooks block"
  if [ "$DRY" = 1 ]; then
    say "  would: jq -s '.[0] * .[1]' $SETTINGS $BLOCK > $SETTINGS"
  else
    cp "$SETTINGS" "$SETTINGS.pre-dotfiles"
    merged="$(jq -s '.[0] * .[1]' "$SETTINGS" "$BLOCK")"
    printf '%s\n' "$merged" > "$SETTINGS"
    jq -e . "$SETTINGS" >/dev/null   # a settings.json that does not parse is ignored in silence
    say "  merged."
  fi
fi

say
say "verify the guard on this machine:"
say "  bash $CLAUDE_DEST/hooks/tests/git-guard.test.sh"
say "(Rule 1 cases SKIP until pinned-checkout.conf names a real repository.)"
