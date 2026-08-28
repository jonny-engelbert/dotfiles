#!/bin/bash
# SessionStart (matcher: compact): tell Claude that detail was just summarised
# away, and that the full version is still on disk.
#
# SessionStart is one of only three events whose plain-text stdout is added to
# Claude's context, which is the whole reason this half exists rather than
# printing from PreCompact directly.
#
# Everything printed here becomes context, so print the nudge or print NOTHING.
# Diagnostics go to stderr. Always exit 0.

set -u

state_dir="${HOME}/.claude/state/precompact"
input="$(cat)"

session_id=""
if command -v jq >/dev/null 2>&1; then
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)"
elif command -v python3 >/dev/null 2>&1; then
  session_id="$(printf '%s' "$input" | python3 -c '
import json,sys
try: print(json.load(sys.stdin).get("session_id","") or "")
except Exception: pass
' 2>/dev/null)"
fi

[ -n "$session_id" ] || exit 0

marker="${state_dir}/${session_id}.marker"
[ -r "$marker" ] || exit 0

stamp="$(awk -F'\t' '$1=="stamp"{print $2; exit}' "$marker" 2>/dev/null)"
transcript="$(awk -F'\t' '$1=="transcript"{print $2; exit}' "$marker" 2>/dev/null)"

# Consume the marker: a second compaction writes a fresh one and earns a fresh
# nudge, but a resumed or forked session must not re-fire this one.
rm -f "$marker" 2>/dev/null || true

printf '[memory] This session was compacted at %s. What you can see above is a summary;\n' "${stamp:-an earlier point}"
if [ -n "${transcript:-}" ] && [ "$transcript" != "-" ] && [ -r "$transcript" ]; then
  printf 'the full pre-compaction detail is still on disk at %s.\n' "$transcript"
fi
cat <<'EOS'
Before this session ends, run /wrap to persist any durable learnings to the memory
directory named in your system prompt. Finish the task in front of you first --
this is a reminder, not an interrupt, and the transcript is not going away.
If the session produced nothing durable, /wrap will say so; do not invent an entry
to have an output.
EOS

exit 0
