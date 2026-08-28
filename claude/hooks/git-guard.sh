#!/usr/bin/env bash
# PreToolUse(Bash) guard: destructive git operations + the pinned-branch checkout rule.
#
# Reads the hook JSON on stdin, prints a PreToolUse permissionDecision on stdout.
# Printing nothing (exit 0) means "no opinion" -- the normal permission flow continues,
# so this can only ever add friction, never remove it.
#
# Two rules:
#   1. The pinned reference checkout (see CONFIGURATION) is held on one branch.
#      Branch-changing checkout/switch there is DENIED (returning to the pinned
#      branch is allowed -- that's the fix). Git has no pre-checkout hook, so a
#      repo's post-checkout guard can only warn after the fact; this blocks
#      beforehand.
#   2. Destructive git commands ASK.
#
# Deliberately NOT covered, to avoid alarm fatigue on recoverable everyday operations:
# plain `git rebase`, `git commit --amend`, `git checkout -- <file>`. All are
# reflog-recoverable. Add them below if you want them.

set -uo pipefail

# --- CONFIGURATION -----------------------------------------------------------
# CLAUDE_PINNED_CHECKOUT  absolute path of the pinned reference checkout.
#                         UNSET (the default) makes Rule 1 inert -- Rule 2 still
#                         applies, so the guard is useful with no configuration.
# CLAUDE_PINNED_BRANCH    the branch that checkout is held on (default: main).
#
# Read from the environment, then from the conf file, which is sourced and so
# must use the `: "${VAR:=value}"` form if you want an environment value to win.
_conf="${CLAUDE_HOOKS_CONF:-$HOME/.claude/hooks/pinned-checkout.conf}"
# shellcheck source=/dev/null
[ -r "$_conf" ] && . "$_conf"

PINNED_DIR="${CLAUDE_PINNED_CHECKOUT:-}"
PINNED_BRANCH="${CLAUDE_PINNED_BRANCH:-main}"

# Escape a literal string for use inside an ERE. Without this, a checkout path
# containing `.` or `+` would match more than itself.
_re_escape() { printf '%s' "$1" | sed 's/[][^$.*+?(){}|\\]/\\&/g'; }

input=$(cat)
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // ""')
[ -n "$cmd" ] || exit 0

m() { printf '%s' "$cmd" | grep -Eq "$1"; }

# Cheap bail-out: nothing here applies to non-git commands.
m '(^|[^[:alnum:]_.-])git([[:space:]]|$)' || exit 0

decide() { # $1 = allow|deny|ask   $2 = reason shown to the user
  jq -n --arg d "$1" --arg r "$2" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: $d,
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# --- Rule 1: pinned-branch checkout ------------------------------------------

if [ -n "$PINNED_DIR" ]; then

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cwd" ] || cwd="$PWD"

# The configured path, resolved through symlinks.
#
# `git rev-parse --show-toplevel` reports the PHYSICAL path, so a configured path
# that traverses a symlink never compares equal to it and Rule 1 silently stops
# denying anything -- no error, just a guard that has quietly stopped guarding.
# macOS makes this ordinary rather than exotic: /var, /tmp and /etc are all
# symlinks into /private, so a pinned checkout anywhere under them is affected,
# and so is a home directory behind a symlink. Found 2026-08-28 when the CI
# fixture was created under $RUNNER_TEMP (/var/folders/...) instead of $HOME:
# 15 of the matrix's Rule 1 cases flipped from deny to none.
pinned_phys="$(cd "$PINNED_DIR" 2>/dev/null && pwd -P)"

# The pinned path as an ERE: the configured spelling, its resolved spelling when
# those differ, and its `~`-spelling when it lives under $HOME.
pinned_re="$(_re_escape "$PINNED_DIR")"
pinned_alt="$pinned_re"
if [ -n "$pinned_phys" ] && [ "$pinned_phys" != "$PINNED_DIR" ]; then
  pinned_alt="$pinned_alt|$(_re_escape "$pinned_phys")"
fi
case "$PINNED_DIR" in
  "$HOME"/*) pinned_alt="~/$(_re_escape "${PINNED_DIR#"$HOME"/}")|$pinned_alt" ;;
esac
branch_re="$(_re_escape "$PINNED_BRANCH")"

in_pinned=0
# Ask git which repository the cwd belongs to, instead of matching the path as text.
#
# Two earlier versions got this wrong in opposite directions. Exact string equality
# missed every subdirectory, and sessions sit in subdirectories constantly, so
# `git checkout -b` there branched the pinned tree unchallenged. Replacing it with a
# `/`-anchored prefix match closed that but treated every top-level entry as pinned --
# including a nested INDEPENDENT repository with its own .git and its own remote.
# Branching there is legitimate, and the guard denied it while asserting the
# pinned-checkout reason, which was simply untrue. A guard that lies is a guard
# people switch off.
#
# --show-toplevel is the predicate the comment always meant: exact for subdirectories,
# structurally correct for the nested repo, for worktrees (which report their own
# root), for /System/Volumes/Data firmlink spellings, and for `..` segments -- none of
# which textual matching can see. Costs one subprocess (~8ms), and only on commands
# that already matched the git bail-out above.
top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
if [ -n "$top" ]; then
  [ "$top" = "$PINNED_DIR" ] && in_pinned=1
  [ -n "$pinned_phys" ] && [ "$top" = "$pinned_phys" ] && in_pinned=1
fi
# ...or the command reaches into the pinned checkout explicitly.
m "git[[:space:]]+-C[[:space:]]+[\"']?($pinned_alt)/?[\"']?([[:space:]]|$)" && in_pinned=1
m "cd[[:space:]]+[\"']?($pinned_alt)/?[\"']?([[:space:]]|;|&|$)" && in_pinned=1

# REVERTED, and the reason is worth keeping. A block used to live here that parsed
# `git -C <dir>` targets out of the command and cleared in_pinned when every target
# named somewhere else. It was added to fix one false positive -- `git -C /tmp/x
# checkout -b y` denied because the session cwd happened to be the pinned checkout.
#
# Adversarial review found it opened EIGHT bypasses of the only rule this guard
# actually prevents, all of them accidental-shape:
#   git -C $HOME/<pinned> checkout -b x   -> allowed (literal `$HOME` never matches
#       the shell-expanded pattern, so the census called it "elsewhere")
#   git -C . checkout -b x                -> allowed (relative target compared as a
#       string against absolute paths; from the pinned cwd, `.` IS pinned)
#   git -C /tmp/other status && git checkout -b x  -> allowed (the census is
#       line-global, but the bare checkout in the second segment has no -C at all)
#
# The invariant was wrong, not the regex: it reasoned about `-C` targets when the
# question is which invocation performs the checkout. Answering that needs per-segment
# shell parsing -- an approach that failed over five review rounds.
#
# It also did not fix the more common shape of the same false positive:
# `cd <pinned>.worktrees/feat && git checkout -b x` is still denied from the pinned
# cwd, and that is the workflow the deny message itself recommends.
#
# Net: one false positive fixed, eight holes opened. Reverted. If this is revisited,
# resolve targets with realpath against cwd and evaluate per command segment, or
# accept the false positive -- the escape hatch (run it in a terminal) already exists.

# `git checkout <path>` restores working-tree files; it does not move HEAD, so Rule 1
# does not apply to it. Only the `--`-separated spelling was exempt, and the spelling
# people actually type is `git checkout .` or `git checkout src/Foo.cs`. Those were
# denied -- with the branching message, which was the wrong reason -- and restoring a
# file is the most common legitimate write in a reference checkout.
#
# Disambiguated the way git itself does: if the first non-flag argument names an
# existing path, it is a restore. `-b`/`-B` means branch creation and short-circuits
# this, so `git checkout -b main` cannot slip through on a directory named `main`.
# `switch` never takes paths, so it is excluded from this test entirely.
file_restore=0
if m 'checkout' && ! m 'checkout([[:space:]]+-[^[:space:]]+)*[[:space:]]+-[bB]([[:space:]]|$)'; then
  m 'checkout[^&;|]*[[:space:]](-p|--patch)([[:space:]]|$)' && file_restore=1
  first=$(printf '%s' "$cmd" \
    | sed -nE 's/.*[[:space:]]checkout[[:space:]]+//p' \
    | tr ' ' '\n' | grep -v '^-' | grep -v '^$' | head -1 | tr -d "\"'")
  if [ -n "${first:-}" ]; then
    [ "$first" = "." ] && file_restore=1
    [ -e "$cwd/$first" ] && file_restore=1
  fi
fi

if [ "$in_pinned" = 1 ] \
   && [ "$file_restore" = 0 ] \
   && m 'git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+(checkout|switch)([[:space:]]|$)' \
   && ! m 'git[^&;|]*(checkout|switch)[^&;|]*[[:space:]]--[[:space:]]' \
   && ! m "(checkout|switch)([[:space:]]+-[^[:space:]]+)*[[:space:]]+$branch_re([[:space:]]|\$)"; then
  decide deny "$PINNED_DIR is the pinned '$PINNED_BRANCH' reference checkout. Concurrent sessions read it to answer \"what is actually on $PINNED_BRANCH?\", and branching here has already caused work to be based on a stale tree.

Do feature work in a worktree instead:
  git worktree add $PINNED_DIR.worktrees/<name> -b <branch> origin/$PINNED_BRANCH

(Returning to $PINNED_BRANCH is allowed. If you genuinely need to switch here, run it yourself in a terminal.)"
fi

fi  # end Rule 1

# --- Rule 2: destructive git -------------------------------------------------
# [^&;|]* keeps each pattern inside a single command segment, so `git log && echo --hard`
# does not trip the reset rule.

m 'git[^&;|]*[[:space:]]reset[^&;|]*--hard' \
  && decide ask "\`git reset --hard\` discards all uncommitted work in the working tree, with no reflog entry for the discarded changes."

m 'git[^&;|]*[[:space:]]clean[^&;|]*[[:space:]]-([a-zA-Z]*f|-force)' \
  && decide ask "\`git clean -f\` permanently deletes untracked files. They are not in the object store, so there is nothing to recover from."

m 'git[^&;|]*[[:space:]]push[^&;|]*[[:space:]](--force|--force-with-lease|-[a-zA-Z]*f)([[:space:]=]|$)' \
  && decide ask "Force-push rewrites published history. Anyone who has fetched this branch gets a divergent history."

m 'git[^&;|]*[[:space:]]filter-(branch|repo)([[:space:]]|$)' \
  && decide ask "History rewrite across the whole repository. Every commit SHA downstream changes."

m 'git[^&;|]*[[:space:]]branch[^&;|]*[[:space:]](-[a-zA-Z]*D([[:space:]]|$)|--delete[^&;|]*--force)' \
  && decide ask "\`git branch -D\` force-deletes a branch even when it is unmerged, dropping commits that exist nowhere else."

m 'git[^&;|]*[[:space:]]stash[^&;|]*[[:space:]](drop|clear)([[:space:]]|$)' \
  && decide ask "Dropping or clearing stashes discards stashed work."

m 'git[^&;|]*[[:space:]]reflog[^&;|]*[[:space:]]expire' \
  && decide ask "Expiring the reflog removes the safety net that makes most other destructive git operations recoverable."

m 'git[^&;|]*[[:space:]]update-ref[^&;|]*[[:space:]](-d|--delete)([[:space:]]|$)' \
  && decide ask "Deleting a ref directly can orphan commits."

m 'git[^&;|]*[[:space:]]worktree[^&;|]*[[:space:]]remove[^&;|]*[[:space:]](--force|-f)([[:space:]]|$)' \
  && decide ask "\`git worktree remove --force\` discards uncommitted changes in that worktree."

exit 0
