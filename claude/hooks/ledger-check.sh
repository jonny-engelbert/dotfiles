#!/usr/bin/env bash
# Stop hook: remind (once per session) that a repository's GENERATED artefacts
# are stale -- source files changed, and nothing was regenerated.
#
# The shape of the problem this came from, which is not specific to one project:
# a repository holds files that are DERIVED from source (a traceability ledger, a
# generated client, a schema snapshot, a lockfile) and a CI job that verifies they
# are current. That job is PATH-FILTERED, and the filter is narrower than the tree
# the generator indexes. So a change outside the filter can leave the generated
# files stale, land green because the job never ran, and fail the next PR that
# does touch a filtered path -- someone else's. This fires while you can still act
# on it.
#
# Self-disabling by construction: it does nothing at all unless the repository it
# is invoked in has a config file naming its source paths and its generated
# paths. That is what makes it safe to install once, in user settings, and forget:
# every other project is inert.
#
# CONFIG. First of these that exists wins:
#   $CLAUDE_LEDGER_CHECK_CONFIG                          (explicit, absolute)
#   <repo>/.claude/ledger-check.json                     (checked in with the repo)
#   ~/.claude/ledger-check/<main-worktree-name>.json     (per-machine)
#
# The third exists because a repository may gitignore its own `.claude/`
# directory, in which case a checked-in config is not an option. It is keyed on
# the MAIN worktree's directory name, not the current one, so linked worktrees of
# the same repository all resolve to the same config.
#
# See ledger-check.example.json for the schema.
#
# Never blocks. Advisory systemMessage only.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

input=$(cat)

cwd=$(printf '%s' "$input" | jq -r '.cwd // empty')
[ -n "$cwd" ] || cwd="$PWD"
cd "$cwd" 2>/dev/null || exit 0

root=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0
cd "$root" 2>/dev/null || exit 0

# The main worktree's name, so a linked worktree finds the same config. In a
# linked worktree --git-common-dir points at the MAIN checkout's .git.
common=$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || common="$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd)"
if [ -n "${common:-}" ]; then
  repo_name="$(basename "$(dirname "$common")")"
else
  repo_name="$(basename "$root")"
fi

config=""
for candidate in \
  "${CLAUDE_LEDGER_CHECK_CONFIG:-}" \
  "$root/.claude/ledger-check.json" \
  "${CLAUDE_HOME:-$HOME/.claude}/ledger-check/$repo_name.json"
do
  [ -n "$candidate" ] && [ -r "$candidate" ] && { config="$candidate"; break; }
done
[ -n "$config" ] || exit 0

# A malformed config must not turn every Stop into an error. Bail out quietly --
# the alternative is a hook that fails on every stop in one repository.
jq -e . "$config" >/dev/null 2>&1 || exit 0
# NOT `.enabled // true`: jq's `//` yields the right-hand side when the left is
# false OR null, so `"enabled": false` would read as true and the switch would do
# nothing. Ask whether the key is present instead.
[ "$(jq -r 'if has("enabled") then .enabled else true end' "$config")" = "true" ] || exit 0

# Read the two path lists. NUL-delimited: a path with a space in it is a path,
# not two paths.
sources=(); generated=()
while IFS= read -r -d '' p; do sources+=("$p"); done \
  < <(jq -j '(.sources // [])[] | . + "\u0000"' "$config" 2>/dev/null)
while IFS= read -r -d '' p; do generated+=("$p"); done \
  < <(jq -j '(.generated // [])[] | . + "\u0000"' "$config" 2>/dev/null)
[ "${#sources[@]}" -gt 0 ] || exit 0
[ "${#generated[@]}" -gt 0 ] || exit 0

# One reminder per session -- this event fires on every stop.
sid=$(printf '%s' "$input" | jq -r '.session_id // "nosession"')
marker="${TMPDIR:-/tmp}/claude-ledger-check-$(printf '%s' "$sid" | tr -c 'A-Za-z0-9_-' '_')"
[ -e "$marker" ] && exit 0

changed=$(git status --porcelain -- "${sources[@]}" 2>/dev/null)
[ -n "$changed" ] || exit 0

# If the generated files moved too, the pipeline has already been run.
regenerated=$(git status --porcelain -- "${generated[@]}" 2>/dev/null)
[ -n "$regenerated" ] && exit 0

: > "$marker"

n=$(printf '%s\n' "$changed" | grep -c . )
label=$(jq -r '.label // "Generated artefacts"' "$config")
note=$(jq -r '.note // "One reminder per session."' "$config")
gen_list=$(printf '%s' "$(IFS=', '; echo "${generated[*]}")")

# The commands to run, as written in the config.
cmds=$(jq -r '(.commands // [])[]' "$config" 2>/dev/null | sed 's/^/  /')
[ -n "$cmds" ] || cmds="  (no commands configured)"

# Derive a step count from a package.json script rather than letting the config
# hardcode one. A literal silently drifts every time a step is added -- it did,
# in the hook this was generalized from: it read "16 steps; CI runs only 7 of
# them" long after the count had reached 22 and CI had switched to running the
# full command. Optional; absent config means no suffix.
steps_file=$(jq -r '.stepCount.packageJson // empty' "$config")
steps_script=$(jq -r '.stepCount.script // empty' "$config")
steps_sep=$(jq -r '.stepCount.separator // " && "' "$config")
steps_note=""
if [ -n "$steps_file" ] && [ -n "$steps_script" ] && [ -r "$steps_file" ]; then
  steps=$(jq -r --arg s "$steps_script" '.scripts[$s] // empty' "$steps_file" 2>/dev/null \
    | awk -F"$steps_sep" 'NF{print NF}')
  case "$steps" in
    ''|*[!0-9]*) ;;
    *) steps_note=" ($steps steps)" ;;
  esac
fi

jq -n \
  --arg label "$label" --arg root "$(basename "$root")" --arg n "$n" \
  --arg gen "$gen_list" --arg cmds "$cmds" --arg note "$note" --arg sn "$steps_note" '{
  systemMessage: ($label + " — " + $root + ": " + $n + " uncommitted file(s) under source paths, and nothing regenerated under " + $gen + ".\n\nBefore pushing:\n" + $cmds + $sn + "\n\n(" + $note + ")")
}'
