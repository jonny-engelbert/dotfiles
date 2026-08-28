#!/bin/bash
# PreCompact: record that this session is about to lose its detail to a summary.
#
# This hook exists for its SIDE EFFECT only. PreCompact stdout goes to the debug
# log -- Claude never sees it -- so printing a reminder here would be a hook that
# fires, prints, and changes nothing. The marker written here is read back by
# session-start-learnings-nudge.sh on the SessionStart that follows compaction,
# where stdout IS added to Claude's context.
#
# The pre-compaction transcript path is the thing worth preserving: after
# compaction Claude sees a summary, but the full detail is still on disk at that
# path, so a later /wrap can harvest from the real thing.
#
# MUST always exit 0. On PreCompact, exit 2 BLOCKS compaction -- a bug in here
# must never be able to wedge a session.

set -u

state_dir="${HOME}/.claude/state/precompact"
input="$(cat)"

emit_marker() {
  mkdir -p "$state_dir" || return 1

  local session_id transcript cwd stamp
  if command -v jq >/dev/null 2>&1; then
    session_id="$(printf '%s' "$input" | jq -r '.session_id // empty')"
    transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty')"
    cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"
  elif command -v python3 >/dev/null 2>&1; then
    read -r session_id transcript cwd <<<"$(printf '%s' "$input" | python3 -c '
import json,sys
try: d = json.load(sys.stdin)
except Exception: d = {}
print(d.get("session_id","-") or "-", d.get("transcript_path","-") or "-", d.get("cwd","-") or "-")
' 2>/dev/null)"
  else
    return 1
  fi

  [ -n "${session_id:-}" ] && [ "$session_id" != "-" ] || return 1
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Written as plain lines, not JSON: the reader is a shell script, and a
  # half-written JSON file would fail to parse where a half-written line file
  # just yields a short value.
  {
    printf 'stamp\t%s\n' "$stamp"
    printf 'transcript\t%s\n' "${transcript:--}"
    printf 'cwd\t%s\n' "${cwd:--}"
  } >"${state_dir}/${session_id}.marker" || return 1

  return 0
}

emit_marker || true
exit 0
