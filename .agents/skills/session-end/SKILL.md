---
name: session-end
description: Close out a coding session cleanly before /clear, /new, handoff, or stopping work. Use when asked to run session-end, prepare a handoff, summarize completed work, verify the repository is clean, update durable project notes if needed, commit completed changes when appropriate, and produce a concise next-session summary.
---

# Session End

Run this workflow before ending a session, clearing context, handing work to another agent, or when the user asks for "session-end". It must be idempotent: if it runs more than once in the same session, skip steps that no longer apply and avoid duplicating notes or commits.

## Workflow

1. Inspect repository state.
   - Run `git status --short --branch`.
   - Identify this session's commits with `git log --oneline --decorate` from the likely session start point when known.
   - Inspect unstaged/staged work with `git diff --stat` and `git diff --cached --stat`.
   - Treat unexpected changes as user or parallel-agent work. Do not revert, stage, commit, or delete them unless clearly part of this session's task.

2. Verify completed work.
   - Derive the validation commands from `AGENTS.md`, `README.md`, package scripts, Makefiles, or local conventions.
   - Run focused checks that match the change risk. Prefer syntax/static checks for small documentation or shell-only changes; broaden tests for shared behavior or user-facing code.
   - If verification fails, stop before committing and report the failure plus the safest next step.

3. Update durable project notes only when useful.
   - Update `AGENTS.md`, `README.md`, `DEVELOPMENT_LOG.md`, `CHANGELOG.md`, ADRs, or equivalent docs only for durable decisions, new conventions, architecture changes, or handoff-critical context.
   - Do not duplicate facts already obvious from code or git history.
   - Keep repo-file documentation edits before any commit so the working tree can end clean.

4. Commit completed changes when appropriate.
   - Commit only coherent, completed work that belongs to this session and passed validation.
   - Keep unrelated or parallel-session changes out of the index.
   - Split independent changes into separate commits when that improves reviewability.
   - Do not push unless the user explicitly requested pushing or publishing.
   - After committing, re-run `git status --short --branch`.

5. Clean up session artifacts.
   - Remove or update temporary plan files only if they are clearly complete and safe to remove.
   - Leave partial plans with an explicit progress note and next action.
   - Do not remove generated outputs or ignored files unless the task created them and they are disposable.

6. Produce the final summary.
   Include:
   - Completed work, 1-3 lines.
   - Commits made in this session, or `none`.
   - Remaining uncommitted changes and ownership if any.
   - Verification run and result.
   - Durable docs or memory updated, if any.
   - Next-session TODO, or `none`.

## Handoff Prompt

If work remains, include a copy-pasteable next-session prompt with concrete anchors:

```text
Previous session ended at: <commit or branch>
Relevant files/docs: <paths>

Continue from the prior session:
1. <specific next action>
2. <specific validation or risk to check>
```

Omit the handoff prompt when there is no remaining work.
