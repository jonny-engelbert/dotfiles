#!/usr/bin/env bash
#
# Matrix for ledger-check.sh, run against a throwaway repository.
#
# The cases that matter are the SILENT ones. A Stop hook that speaks when it
# should not is worse than one that never speaks: it fires on every stop, in
# every project, and the first thing anyone does about it is switch it off.
#
#   bash claude/hooks/tests/ledger-check.test.sh
#
# Exit 0 = all pass. Exit 1 = at least one failure.

set -uo pipefail

HOOK="${HOOK:-$HOME/.claude/hooks/ledger-check.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export TMPDIR="$WORK/markers"
mkdir -p "$TMPDIR"

REPO="$WORK/demo"
mkdir -p "$REPO/src" "$REPO/generated" "$REPO/.claude"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name test
printf 'a\n' > "$REPO/src/a.txt"
printf 'g\n' > "$REPO/generated/g.txt"
printf 'x\n' > "$REPO/unwatched.txt"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m init

CONFIG="$REPO/.claude/ledger-check.json"
# `git clean -fd` in clean() removes the untracked .claude/ directory along with
# everything else, so recreate it here rather than once at setup.
write_config() { mkdir -p "$(dirname "$CONFIG")"; cat > "$CONFIG"; }

good_config() {
  write_config <<'JSON'
{
  "label": "Demo gate",
  "sources": ["src", "a path with spaces"],
  "generated": ["generated"],
  "commands": ["make regenerate"],
  "note": "one per session"
}
JSON
}

pass=0; fail=0
sid_n=0

# speaks <expected: yes|no> <label>   -- runs the hook with a FRESH session id
speaks() {
  sid_n=$((sid_n + 1))
  local out got
  out=$(printf '{"cwd":"%s","session_id":"s%d"}' "$REPO" "$sid_n" | bash "$HOOK" 2>/dev/null)
  if [ -n "$out" ]; then got=yes; else got=no; fi
  if [ "$got" = "$1" ]; then
    pass=$((pass + 1)); printf '  PASS  %-4s %s\n' "[$got]" "$2"
  else
    fail=$((fail + 1)); printf '  FAIL  exp=%-4s got=%-4s %s\n         out=%s\n' "$1" "$got" "$2" "${out:0:160}"
  fi
}

dirty()  { printf 'changed\n' >> "$REPO/$1"; }
clean()  { git -C "$REPO" checkout -- . 2>/dev/null; git -C "$REPO" clean -qfd 2>/dev/null; }

echo "ledger-check matrix"
echo "hook: $HOOK"
echo

echo "-- no config anywhere: inert, whatever the tree looks like --"
dirty src/a.txt
speaks no "dirty sources, no config"
clean

echo
echo "-- configured --"
good_config
speaks no "clean tree"
dirty src/a.txt
speaks yes "dirty sources, generated untouched"
dirty generated/g.txt
speaks no "dirty sources AND regenerated output"
clean
good_config
dirty unwatched.txt
speaks no "change outside the configured source paths"
clean
good_config

echo
echo "-- once per session --"
dirty src/a.txt
out1=$(printf '{"cwd":"%s","session_id":"repeat"}' "$REPO" | bash "$HOOK" 2>/dev/null)
out2=$(printf '{"cwd":"%s","session_id":"repeat"}' "$REPO" | bash "$HOOK" 2>/dev/null)
if [ -n "$out1" ] && [ -z "$out2" ]; then
  pass=$((pass + 1)); printf '  PASS  [yes/no] first stop speaks, second stop is silent\n'
else
  fail=$((fail + 1)); printf '  FAIL  first=%s second=%s (expected non-empty then empty)\n' "${out1:0:40}" "${out2:0:40}"
fi

echo
echo "-- a source path containing spaces is ONE path --"
mkdir -p "$REPO/a path with spaces"
printf 'q\n' > "$REPO/a path with spaces/f.txt"
speaks yes "space in a configured source path is detected"
clean
good_config

echo
echo "-- degrades quietly --"
dirty src/a.txt
write_config <<'JSON'
{ "sources": ["src"], "generated": ["generated"], "enabled": false }
JSON
speaks no "enabled:false"
write_config <<<'{ not json at all'
speaks no "malformed config"
good_config
speaks yes "…and recovers once the config parses again"
clean

echo
echo "-- message content --"
good_config
dirty src/a.txt
msg=$(printf '{"cwd":"%s","session_id":"content"}' "$REPO" | bash "$HOOK" | jq -r .systemMessage)
for want in "Demo gate" "make regenerate" "generated" "one per session"; do
  if printf '%s' "$msg" | grep -qF "$want"; then
    pass=$((pass + 1)); printf '  PASS  message contains %s\n' "\"$want\""
  else
    fail=$((fail + 1)); printf '  FAIL  message missing %s\n' "\"$want\""
  fi
done

echo
echo "-- not a git repository --"
out=$(printf '{"cwd":"%s","session_id":"nonrepo"}' "$WORK" | bash "$HOOK" 2>/dev/null)
if [ -z "$out" ]; then
  pass=$((pass + 1)); printf '  PASS  [no]  silent outside a repository\n'
else
  fail=$((fail + 1)); printf '  FAIL  spoke outside a repository: %s\n' "${out:0:80}"
fi

printf '\n  %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
