# dotfiles

Claude Code commands and hooks, shared so colleagues can install the same setup.

Everything here is user-level (`~/.claude`), works in any repository, and is
configured by one optional file. Nothing here is specific to a particular project.

```bash
git clone https://github.com/jonny-engelbert/dotfiles.git ~/src/dotfiles
~/src/dotfiles/install.sh --dry-run     # see what it would do
~/src/dotfiles/install.sh               # symlink commands + hooks into ~/.claude
```

Files are symlinked, so `git pull` updates what Claude runs. `install.sh` never
overwrites anything: an existing file is moved to `<name>.pre-dotfiles` first.

## What's in here

| Path | Event | What it does |
|---|---|---|
| `claude/commands/wrap.md` | `/wrap` | Harvests a session's durable learnings into the project's memory directory, rejecting aggressively and saying what it rejected. |
| `claude/hooks/precompact-mark-learnings.sh` | PreCompact | Writes a marker recording the pre-compaction transcript path. Side effect only — PreCompact stdout goes to the debug log, where Claude never sees it. |
| `claude/hooks/session-start-learnings-nudge.sh` | SessionStart (`compact`) | Reads that marker back and tells Claude the detail was summarised away and where the full version still is. SessionStart is one of only three events whose stdout reaches Claude's context, which is why this is two hooks and not one. |
| `claude/hooks/git-guard.sh` | PreToolUse (Bash) | Rule 1: denies branch changes in a pinned reference checkout. Rule 2: asks before destructive git (`reset --hard`, `clean -f`, force-push, `filter-branch`, `branch -D`, `stash drop`, `reflog expire`, `update-ref -d`, `worktree remove --force`). |
| `claude/hooks/pinned-checkout-tripwire.sh` | PostToolUse (Bash) | Reports when the pinned checkout's tree or branch changed, whatever caused it. |
| `claude/hooks/ledger-check.sh` | Stop | Reminds you once per session that a repository's GENERATED files are stale — sources changed, nothing regenerated. Inert in every repository that has no config for it. |
| `claude/hooks/tests/git-guard.test.sh` | — | Regression matrix for the guard. Every case is one that was observed wrong at some point. Run it before changing the guard. |
| `claude/hooks/tests/ledger-check.test.sh` | — | Matrix for the Stop hook. Most of its cases assert SILENCE. |
| `claude/settings.hooks.json` | — | The `hooks` block that wires the four hooks up. |

The three memory-related pieces are one mechanism: `/wrap` is the command, and the
two compaction hooks are what make it fire when a session is about to lose the
detail `/wrap` harvests. Installing the command alone gets you a command nobody
remembers to run.

## Configuration

The two pinned-checkout hooks need to know which checkout to protect. Without it
they stay inert — the guard still prompts on destructive git, the tripwire does
nothing:

```bash
cp claude/hooks/pinned-checkout.conf.example ~/.claude/hooks/pinned-checkout.conf
$EDITOR ~/.claude/hooks/pinned-checkout.conf
```

- `CLAUDE_PINNED_CHECKOUT` — absolute path of the checkout other sessions read to
  answer "what is actually on the main branch?"
- `CLAUDE_PINNED_BRANCH` — the branch it is held on (default `main`)

Environment variables of the same names override the file.

### `ledger-check.sh`

This one is configured per REPOSITORY, not per machine, because the paths it
watches are a property of the project. It does nothing until it finds a config,
so installing it costs nothing in projects that don't want it. First hit wins:

1. `$CLAUDE_LEDGER_CHECK_CONFIG`
2. `<repo>/.claude/ledger-check.json` — checked in, shared with the team
3. `~/.claude/ledger-check/<main-worktree-name>.json` — for a repository that
   gitignores its own `.claude/`, and keyed on the MAIN worktree's name so linked
   worktrees resolve to the same config

Schema, in `claude/hooks/ledger-check.example.json`:

| Key | Meaning |
|---|---|
| `sources` | Paths whose change means the generated files may be stale. |
| `generated` | Paths the generator writes. If these changed too, the hook stays quiet — the pipeline has already been run. |
| `commands` | Printed verbatim as what to run before pushing. |
| `label`, `note` | Message wording. |
| `enabled` | `false` switches it off without deleting the config. |
| `stepCount` | Optional `{packageJson, script, separator}`. Counts the steps in an npm script and appends `(N steps)`, rather than letting the message hardcode a number that drifts — which is exactly what happened to the hook this was generalized from. |

## Settings

`install.sh` does not touch `~/.claude/settings.json` unless you pass `--settings`,
and even then it refuses if you already have a `hooks` key. Claude Code keys each
hook event to an array, and a jq merge replaces arrays wholesale — so an automatic
merge would silently drop hooks you already had. Paste from
`claude/settings.hooks.json` in that case.

## Requirements

- bash (3.2, as shipped on macOS, is enough)
- `jq` — required by `git-guard.sh`; without it the guard cannot read its input
- `python3` — required by the test matrix only
- `shasum` — used by the tripwire

## Verifying

```bash
bash ~/.claude/hooks/tests/git-guard.test.sh
```

Rule 1 cases need a real pinned checkout, so they SKIP until the config names one.
Rule 2 cases always run.

## A note on the comments

The hooks carry long comments explaining why they are shaped the way they are —
a reverted `git -C` census that opened eight bypasses, a prefix match that denied
work in a nested repository while claiming to protect something else, a tripwire
that detected writes correctly and reported them to stderr, where nothing surfaced
them. Those paragraphs are the expensive part. Read them before "simplifying" a
hook, and run the test matrix after.
