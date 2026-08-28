#!/usr/bin/env bash
#
# Regression matrix for git-guard.sh.
#
# WHY THIS EXISTS. The guard was changed three times in one session. Two of those
# changes were wrong in ways that nothing caught until an adversarial reviewer ran
# the cases by hand:
#   - a `git -C <dir>` census opened eight bypasses of the only rule the guard
#     PREVENTS, then was reverted;
#   - a `/`-anchored prefix cwd match denied branching inside a nested INDEPENDENT
#     repository, while telling the user it was protecting the pinned tree.
# Every case below is one that was actually observed wrong at some point, or is a
# case a later "improvement" would plausibly break. Run this before touching the guard.
#
#   bash claude/hooks/tests/git-guard.test.sh
#
# Rule 1 needs a real pinned checkout to test against: the guard asks git which
# repository a cwd belongs to, so a path that is not a git repository cannot
# exercise it. With CLAUDE_PINNED_CHECKOUT unset, or set to something that is not
# a repository, the Rule 1 sections SKIP and Rule 2 still runs.
#
# Exit 0 = all pass. Exit 1 = at least one failure.

set -uo pipefail

GUARD="${GUARD:-$HOME/.claude/hooks/git-guard.sh}"

_conf="${CLAUDE_HOOKS_CONF:-$HOME/.claude/hooks/pinned-checkout.conf}"
# shellcheck source=/dev/null
[ -r "$_conf" ] && . "$_conf"

PINNED="${CLAUDE_PINNED_CHECKOUT:-}"
BRANCH="${CLAUDE_PINNED_BRANCH:-main}"
WORKTREES="${PINNED}.worktrees"
PINNED_NAME="$(basename "${PINNED:-none}")"
# Optional: an independent repository nested inside the pinned checkout. The
# guard must NOT claim that one as pinned. Left unset, those cases skip.
NESTED="${CLAUDE_PINNED_NESTED_REPO:-}"

pinned_ok=0
if [ -n "$PINNED" ] && git -C "$PINNED" rev-parse --git-dir >/dev/null 2>&1; then
  pinned_ok=1
fi

pass=0; fail=0; skip=0

# Decision for (cwd, command). Prints deny|ask|none.
decide() {
  python3 - "$GUARD" "$1" "$2" <<'PY'
import json, subprocess, sys
guard, cwd, cmd = sys.argv[1], sys.argv[2], sys.argv[3]
payload = json.dumps({"cwd": cwd, "tool_input": {"command": cmd}})
out = subprocess.run(["bash", guard], input=payload,
                     capture_output=True, text=True).stdout.strip()
if not out:
    print("none"); sys.exit(0)
try:
    print(json.loads(out)["hookSpecificOutput"]["permissionDecision"])
except Exception:
    print("MALFORMED:" + out[:120])
PY
}

t() { # t <expected> <cwd> <command> <label>
  local got; got="$(decide "$2" "$3")"
  if [ "$got" = "$1" ]; then
    pass=$((pass + 1)); printf '  PASS  %-8s %s\n' "[$got]" "$4"
  else
    fail=$((fail + 1)); printf '  FAIL  exp=%-5s got=%-5s %s\n         cwd=%s\n         cmd=%s\n' \
      "$1" "$got" "$4" "$2" "$3"
  fi
}

skip_missing() { # skip_missing <path> <label>
  [ -n "$1" ] && [ -e "$1" ] && return 1
  skip=$((skip + 1)); printf '  SKIP  %s (missing: %s)\n' "$2" "${1:-unset}"; return 0
}

echo "git-guard regression matrix"
echo "guard:  $GUARD"
echo "pinned: ${PINNED:-<unset>} (branch $BRANCH)"
echo

if [ "$pinned_ok" = 0 ]; then
  skip=$((skip + 1))
  echo "-- Rule 1 sections SKIPPED: no pinned checkout configured, or not a git repository --"
  echo
else

echo "-- Rule 1: branch changes in the pinned checkout are denied --"
t deny "$PINNED"              'git checkout -b feature'        'bare checkout -b at root'
t deny "$PINNED"              'git switch -c feature'          'switch -c at root'
t deny "$PINNED/"             'git checkout -b x'              'trailing slash on cwd'
t deny /tmp                   "git -C $PINNED checkout -b x"   'explicit -C at pinned, from elsewhere'
t deny "$PINNED"              'git checkout HEAD~1'            'detached HEAD move'

# Subdirectory cases need a real subdirectory of the pinned checkout; find one
# rather than hardcoding a project's layout.
subdir="$(find "$PINNED" -maxdepth 1 -mindepth 1 -type d ! -name '.*' 2>/dev/null | head -1)"
if [ -n "$subdir" ]; then
  t deny "$subdir" 'git checkout -b x' 'subdirectory cwd'
  t deny "$subdir" 'git switch -c x'   'subdirectory cwd, switch'
else
  skip=$((skip + 1)); printf '  SKIP  subdirectory cwd (no subdirectory found)\n'
fi

echo
echo "-- the eight bypasses opened by the reverted -C census (must all deny) --"
t deny "$PINNED" "git -C \$HOME/$PINNED_NAME checkout -b x"     'unexpanded $HOME'
t deny "$PINNED" "git -C \"\$HOME/$PINNED_NAME\" checkout -b x" 'quoted $HOME'
t deny "$PINNED" "git -C \${HOME}/$PINNED_NAME checkout -b x"   '${HOME} braces'
t deny "$PINNED" 'git -C . checkout -b x'                       'relative -C .'
t deny "$PINNED" 'git -C ./ checkout -b x'                      'relative -C ./'
t deny "$PINNED" 'git -C "$PWD" checkout -b x'                  'unexpanded $PWD'
t deny "$PINNED" 'git -C /tmp/other status && git checkout -b x' 'unrelated -C, then bare checkout'
t deny "$PINNED" 'git checkout -b x && git -C /tmp/other status' 'bare checkout, then unrelated -C'

echo
echo "-- worktrees are NOT the pinned checkout (a bare prefix match would break all work) --"
t none "$WORKTREES/feat"         'git checkout -b x' 'worktree cwd'
t none "$WORKTREES/feat/sub"     'git switch -c x'   'worktree subdirectory'
t none "$WORKTREES"              'git checkout -b x' 'worktrees parent dir'
t none "${PINNED}2"              'git checkout -b x' 'sibling with shared prefix'
if ! skip_missing "$WORKTREES/$PINNED_NAME" 'worktree with the repo name mid-path'; then
  t none "$WORKTREES/$PINNED_NAME" 'git checkout -b x' 'repo name mid-path'
fi

echo
echo "-- a nested INDEPENDENT repository is not the pinned checkout --"
if ! skip_missing "${NESTED:+$NESTED/.git}" 'nested independent repo'; then
  t none "$NESTED" 'git checkout -b feature' 'branch inside nested repo'
  t none "$NESTED" 'git switch -c feature'   'switch inside nested repo'
fi

echo
echo "-- file restore is not a branch change --"
t none "$PINNED"        'git checkout -- somefile.txt' 'explicit -- form'
t none "$PINNED"        'git checkout -- .'            'explicit -- dot'
t none "$PINNED"        'git checkout .'               'bare dot at root'
t none "$PINNED"        'git checkout -p'              'interactive patch restore'
t none "$PINNED"        'git checkout --patch'         'long patch flag'
t none "$PINNED"        'git checkout HEAD -- .'       'HEAD -- form'
if [ -n "$subdir" ]; then
  t none "$subdir"      'git checkout .'                          'bare dot in subdir'
  t none "$PINNED"      "git checkout $(basename "$subdir")"      'existing path as argument'
  t deny "$PINNED"      "git checkout -b $(basename "$subdir")"   'branch creation named after a real dir'
fi

echo
echo "-- returning to the pinned branch is always allowed --"
t none "$PINNED"        "git checkout $BRANCH"  'checkout pinned branch at root'
t none "$PINNED"        "git switch $BRANCH"    'switch pinned branch'

echo
echo "-- unrelated repositories and non-repositories --"
t none /tmp             'git checkout -b feature' 'not a repo'
t none "$PINNED"        'git status'              'read-only command'
t none "$PINNED"        'git log --oneline'       'read-only command'
t none "$PINNED"        'ls -la'                  'non-git command'

fi  # pinned_ok

echo
echo "-- Rule 2: destructive operations ask (must be unaffected by Rule 1 changes) --"
t ask  /tmp             'git reset --hard origin/main'      'reset --hard'
t ask  /tmp             'git clean -fd'                     'clean -fd'
t ask  /tmp             'git push --force origin main'      'force push'
t ask  /tmp             'git push --force-with-lease'       'force-with-lease'
t ask  /tmp             'git filter-branch --all'           'filter-branch'
t ask  /tmp             'git branch -D feature'             'branch -D'
t ask  /tmp             'git stash drop'                    'stash drop'
t ask  /tmp             'git reflog expire --all'           'reflog expire'
t ask  /tmp             'git update-ref -d refs/heads/x'    'update-ref -d'
t ask  /tmp             'git worktree remove --force w'     'worktree remove --force'
t none /tmp             'git log --oneline && echo --hard'  'no bleed across segments'
t none /tmp             'git rebase origin/main'            'plain rebase is deliberately not covered'

echo
printf '\n  %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
