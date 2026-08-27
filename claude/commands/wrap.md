---
description: Persist this session's durable learnings to memory before closing it
argument-hint: "[optional: a learning to make sure gets captured]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(ls:*), Bash(git log:*), Bash(git status:*), Bash(date:*)
---

Close out this session by persisting what it learned. `$ARGUMENTS`, if present, names
something the user wants captured — treat it as a required candidate, not the whole list.

The memory directory for this project is the one named in your system prompt under
**Memory** (`~/.claude/projects/<project-slug>/memory/`). It already exists. `MEMORY.md`
inside it is the index loaded into every future session.

## 1. Harvest candidates

Re-read this session and list every candidate learning. Look hardest at the places a
learning actually hides:

- A command, flag, or tool that did not do what its name implies — especially one that
  reported success while doing nothing.
- A wrong assumption you or the user held, and what corrected it.
- A cost paid: a failed gate, a wasted CI run, a re-done branch, a long detour — and the
  one fact that would have avoided it.
- A correction the user gave you about *how to work*, not about the code.
- A decision made for reasons not visible in the resulting diff.
- Environment/setup facts discovered the hard way (paths, device ids, credentials'
  locations — never their values, expiry behaviour, missing binaries).

## 2. Reject aggressively, and say what you rejected

Most sessions produce one durable learning, some produce none. Drop a candidate if:

- The repo already records it — code structure, `CLAUDE.md`, a requirements doc, git
  history, a test name. Memory duplicating a document is a second copy to keep true, and
  the two will disagree the first time either changes.
- It only matters inside this conversation.
- It is a fact about a bug that has since been fixed, with nothing transferable left.
- You cannot state *why* it is true. A learning you cannot justify is a guess that will
  be trusted later.

**Print the rejections with their reasons before you write anything.** The rejected rows
are where a wrap-up talks itself out of the one memory that mattered, and they are the
only place that can be caught.

If nothing survives, say so plainly and stop. Do not manufacture a memory to have an
output — a store padded with the obvious is one nobody reads.

## 3. Check for an existing home

For each survivor, read `MEMORY.md` and any file whose description is adjacent. Prefer
**updating** an existing memory over creating a neighbour to it: two files on one subject
both drift, and recall picks whichever it saw first. Create a new file only when the fact
is genuinely a separate subject.

If an existing memory is now **wrong**, fix or delete it in this pass. A stale memory is
worse than a missing one, because it is asserted with the same confidence as a true one.

## 4. Write

Match the house format exactly:

```markdown
---
name: <short-kebab-case-slug>
description: <one line; this is what future-you reads to decide relevance — make it say the finding, not the topic>
metadata:
  node_type: memory
  type: user | feedback | project | reference
  originSessionId: <this session's id, if known; omit otherwise>
  modified: <ISO-8601 UTC>
---

<The fact, stated so it is actionable without this conversation.>

**Why:** <the mechanism — for feedback and project entries this is required>

**How to apply:** <what a future session should do differently; include the exact command where there is one>

Related: [[other-memory-name]], [[another]].
```

Rules that are easy to get wrong:

- Convert every relative date to an absolute one. "Yesterday" is meaningless on recall.
- Include the measurement, not just the conclusion — the sha, the count, the exit code,
  the date it was observed. A future session has to decide whether the fact still holds,
  and it can only do that against evidence.
- Link liberally with `[[name]]`. A link to a memory that does not exist yet is fine; it
  marks something worth writing later.
- Never put secrets, tokens, or the contents of credentials in a memory. Record where a
  credential lives and how it behaves, not what it is.

Then add exactly one line to `MEMORY.md`: `- [Title](file.md) — hook`. Never put memory
content in the index.

## 5. Verify the effect, not the apparent success

Read back each file you wrote and confirm the index line resolves to a file that exists:

```bash
ls "$MEMORY_DIR"
```

Then report, in a few lines: what was written or updated, what was rejected and why, and
anything you noticed the store still lacks. If a write failed, say so with the error —
a wrap-up that reports success having saved nothing is the worst outcome available here,
because the session it was protecting is about to close.

## Related

- `/consolidate-memory` is the periodic *tidying* pass over the whole store — merge
  duplicates, prune the index. This command is the per-session *capture* pass. Run this
  one at close; run that one when the store starts feeling crowded.
