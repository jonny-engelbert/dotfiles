#!/usr/bin/env bash
#
# PostToolUse tripwire: report when the pinned reference checkout's working tree
# changes, whatever caused it.
#
# WHY THIS SHAPE. The first attempt at this was a PreToolUse guard that read the
# Bash command and tried to predict whether it would write. Over four review
# rounds that produced seven bypasses and six false positives, and neither count
# was shrinking. The failure was structural, not sloppy: shell can write through
# an interpreter, a script it invokes, an editor, or any tool the parser has not
# been taught, so every widening of the pattern cost a false positive and every
# narrowing left a hole. The last false positive is the tell — merely QUOTING a
# `dd` command inside a string was blocked.
#
# So: stop predicting intent, observe the outcome. `git status` cannot be fooled
# by mechanism, because it looks at the tree rather than at the command. Prose
# about writing does not modify files, so there is nothing here to false-positive
# on.
#
# THE TRADE, stated plainly: this is DETECTION, not prevention. The write has
# already landed when you read the message. That is the right trade for the
# actual risk — an accident, not an attacker — because complete coverage after
# the fact beats leaky coverage before it, and the change is still revertible.
# Prevention for the precise case still exists: a Write|Edit guard receives a
# literal file_path and needs no parsing at all.
#
# Baseline: the checkout legitimately carries some untracked files. The first run
# records the current state and stays quiet; afterwards any DIFFERENCE is
# reported. Refresh deliberately with --accept once you have looked.
#
# stdin: the PostToolUse hook JSON (ignored).  Always exits 0 — a tripwire that
# fails a tool call would be a worse version of the guard it replaces.

set -uo pipefail

# --- CONFIGURATION -----------------------------------------------------------
# Shared with git-guard.sh; see claude/hooks/pinned-checkout.conf.example.
# With CLAUDE_PINNED_CHECKOUT unset this hook does nothing at all.
_conf="${CLAUDE_HOOKS_CONF:-$HOME/.claude/hooks/pinned-checkout.conf}"
# shellcheck source=/dev/null
[ -r "$_conf" ] && . "$_conf"

PINNED="${CLAUDE_PINNED_CHECKOUT:-}"
PINNED_BRANCH="${CLAUDE_PINNED_BRANCH:-main}"
STATE="${PINNED_TRIPWIRE_STATE:-$HOME/.cache/pinned-tripwire/baseline}"

[ -n "$PINNED" ] || exit 0

# Self-reference rather than a literal path. This script used to print its own
# location as a hardcoded string in the --accept instruction, which went stale
# the moment it moved out of the pinned checkout (it had to move: landing
# `!.claude/hooks/` in .gitignore un-ignored that directory, so living there
# made the pinned checkout permanently dirty — the exact condition this script
# reports on).
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/$(basename "${BASH_SOURCE[0]}")"

git -C "$PINNED" rev-parse --git-dir >/dev/null 2>&1 || exit 0

# `git status --porcelain` records a path's STATUS, not its content, so it is
# blind to two real changes: overwriting a file already listed (the `?? path`
# line is identical), and an edit followed by a commit (both snapshots clean
# while HEAD moved). The first version of this tripwire claimed it "cannot be
# fooled by mechanism" and was wrong on both counts — the claim was about the
# mechanism of WRITING, but the blindness is in what the state captures.
#
# So the state is: the porcelain lines, the HEAD commit, a hash of the tracked
# diff, and hashes of untracked file CONTENT.
#
# COST. This runs after every Bash call, so the git invocations are the budget.
# The first version called `git status` TWICE -- once for the display lines and
# again for the -z untracked walk -- at ~59ms each on this repo, which was 64% of
# the hook's 184ms. It now calls status once, reads the NUL-delimited output into
# an array, and derives both from it; HEAD and the branch come from a single
# rev-parse. Measure before changing this: `git status` dominates, so anything
# that adds a second tree scan roughly doubles the tax on every Bash call in
# every project.
snapshot() {
  local e f n=0
  # NUL-delimited, read once. Command substitution strips NUL bytes, so this has
  # to be a read loop into an array rather than a "$(...)" capture. No mapfile --
  # bash 3.2 is what ships on macOS.
  entries=()
  while IFS= read -r -d '' e; do
    entries+=("$e")
  done < <(git -C "$PINNED" status --porcelain -z --untracked-files=all 2>/dev/null)

  # Status lines. One per entry, so a path needing quotes in the DISPLAY form
  # cannot corrupt the record -- the display form is what broke the previous
  # content walk.
  for e in ${entries[@]+"${entries[@]}"}; do printf '%s\n' "$e"; done

  printf 'HEAD %s\n' "$head"
  printf 'TRACKED %s\n' "$(git -C "$PINNED" diff HEAD 2>/dev/null | shasum | cut -d' ' -f1)"
  # Untracked content, hashed per file, reusing the array above rather than
  # re-scanning. Bounded at 200 so a runaway directory cannot turn every Bash
  # call into a full-tree hash.
  #
  # -z, and NUL-delimited reads. The porcelain DISPLAY form quotes any path that
  # needs it — `?? ".agents/space name.txt"` — so treating that text as a
  # filesystem path silently skipped the file, and overwriting it then produced
  # an identical snapshot. Third time this class of bug appeared in this work:
  # it killed the regex guard, it hit a PR script, and here it is again. The
  # lesson is mechanical, not moral — never consume git's display output as
  # data; ask for -z.
  for e in ${entries[@]+"${entries[@]}"}; do
    [[ "${e:0:2}" == "??" ]] || continue
    f="${e:3}"
    [[ -f "$PINNED/$f" ]] || continue
    printf 'U %s %s\n' "$(shasum "$PINNED/$f" 2>/dev/null | cut -d' ' -f1)" "$f"
    n=$((n + 1))
    [[ "$n" -ge 200 ]] && break
  done
}

# One rev-parse for both facts instead of two separate calls.
head=""; branch=""
{ read -r head; read -r branch; } < <(git -C "$PINNED" rev-parse HEAD --abbrev-ref HEAD 2>/dev/null)

current="$(snapshot)"

if [[ "${1:-}" == "--accept" ]]; then
  mkdir -p "$(dirname "$STATE")"
  printf '%s' "$current" > "$STATE"
  echo "pinned-checkout tripwire: baseline updated ($(printf '%s' "$current" | grep -c . ) entr(y|ies))."
  exit 0
fi

# Emit through the hook's JSON channel. Written without jq on purpose: the
# opt-in setup does not declare jq as a prerequisite, and the jq-absent fallback
# in the first version wrote to stderr — reintroducing the silent-PostToolUse
# failure this whole script exists to avoid, in the branch meant to handle its
# own dependency being missing.
json_escape() { printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' | awk '{printf "%s\\n", $0}'; }
emit() {
  local msg="$1" esc
  esc="$(json_escape "$msg")"
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"%s"}}\n' "$esc" "$esc"
}

if [[ ! -f "$STATE" ]]; then
  mkdir -p "$(dirname "$STATE")"
  printf '%s' "$current" > "$STATE"
  exit 0
fi

baseline="$(cat "$STATE" 2>/dev/null)"

# Branch drift matters as much as file drift: the whole point of the pinned
# checkout is that other sessions can read it to answer "what is on the pinned
# branch?".
drift=""
if [[ -n "$branch" && "$branch" != "$PINNED_BRANCH" ]]; then
  drift="⚠️  PINNED CHECKOUT IS ON '$branch', NOT $PINNED_BRANCH — other sessions read it as $PINNED_BRANCH."
fi

if [[ "$current" == "$baseline" ]]; then
  # Branch drift alone still has to be reported, and through JSON: the first
  # version wrote it to stderr and exited 0, i.e. silently, which is the very
  # failure this file documents two paragraphs above.
  [[ -n "$drift" ]] && emit "$drift"
  exit 0
fi

# Report only what MOVED, so a long-standing untracked file is not re-reported
# every call. Deletions matter as much as additions.
added="$(comm -13 <(printf '%s\n' "$baseline" | sort) <(printf '%s\n' "$current" | sort) | grep -c . || true)"
gone="$(comm -23 <(printf '%s\n' "$baseline" | sort) <(printf '%s\n' "$current" | sort) | grep -c . || true)"

detail="$(
  comm -13 <(printf '%s\n' "$baseline" | sort) <(printf '%s\n' "$current" | sort) | sed 's/^/  + /' | head -20
  comm -23 <(printf '%s\n' "$baseline" | sort) <(printf '%s\n' "$current" | sort) | sed 's/^/  - /' | head -10
)"

report="PINNED CHECKOUT CHANGED — $PINNED
$added new / $gone cleared, versus the recorded baseline.

$detail

This checkout is pinned to $PINNED_BRANCH and other sessions read it to answer \"what is
actually on $PINNED_BRANCH?\". If that was accidental, revert it:
  git -C \"$PINNED\" checkout -- <path>
If it was deliberate, record the new baseline:
  bash \"$SELF\" --accept"

# JSON, not stderr. A PostToolUse hook that writes to stderr and exits 0 is
# SILENT — the harness surfaces a hook only when it errors — so the first
# version of this tripwire detected the write correctly and told nobody, which
# is the one failure mode a tripwire cannot have. systemMessage reaches the
# human; additionalContext reaches the model, so it can offer to revert.
emit "${drift:+$drift

}⚠️  $report"

# Exit 0 on purpose. This observes; it does not veto.
exit 0
