# Worktree Cockpit Feature Video Use Cases

This is the working storyboard for a short feature introduction video. The goal is
to show `wtcp` as a terminal-native cockpit for comparing multiple coding agents
on the same task, judging their outputs, and merging the best result.

## Primary Audience

Developers who already use CLI coding agents, git worktrees, or tmux, and want a
practical way to compare multiple agents without manually creating branches,
copying prompts, or cleaning up losing attempts.

## Core Use Cases

1. Environment readiness
   - Run `wtcp doctor`.
   - Show tmux/workmux/git/jq/curl detection, configured agents, judge endpoint,
     and mouse/key troubleshooting hints.

2. Agent set selection
   - Run `wtcp agents codex claude` or model aliases such as
     `wtcp agents claude-sonnet codex-gpt5`.
   - Show that the compare set is persisted to config and capped at six agents.

3. Parallel implementation round
   - Run `wtcp start "fix add function and add tests"`.
   - Show one worktree per agent, tiled into a tmux grid, with a persistent
     command bar and pane labels.

4. Broadcast follow-up
   - Run `wtcp send "run the tests and summarize risks"`.
   - Show the same instruction delivered to every live agent pane.

5. Comparative judging
   - Run `wtcp score`.
   - Show the judge comparing every agent in one call, stamping pane borders with
     scores, writing a report, and ranking a winner.

6. Winner merge and cleanup
   - Run `wtcp pick <winner-worktree>`.
   - Show the winner auto-committed if needed, merged into the base branch, and
     loser worktrees removed.

7. No-change analysis round
   - Use an analysis or review prompt where a winner may produce no code diff.
   - Show that `wtcp pick` skips `workmux merge` when there are no changes and
     still cleans up the round.

8. Recovery and housekeeping
   - Show `wtcp abandon`, `wtcp clean`, and `wtcp list`.
   - Position these as the escape hatches for failed launches or unwanted rounds.

## Recommended Short Video Structure

Target length: 75 to 120 seconds.

1. Open on the problem
   - "One prompt, multiple agents, isolated worktrees."
   - Show the terminal in a git repo.

2. Check readiness
   - `wtcp doctor`
   - Keep this brief; it establishes that the tool is terminal-native and checks
     real dependencies.

3. Start a round
   - `wtcp agents fgood fbad` for deterministic demo agents, or real agent names
     for a live screencast.
   - `wtcp start "fix add function and add tests"`
   - Show the grid.

4. Drive all agents together
   - `wtcp send "run the tests and summarize risks"`
   - Show both panes receiving the follow-up.

5. Judge and pick
   - `wtcp score`
   - Show scores on pane labels and the winner.
   - `wtcp pick <winner>`

6. End on the result
   - Show `git log --oneline -1` and `git status --short`.
   - Message: "Winner merged. Losing worktrees cleaned."

## Deterministic Demo Script

Use `scripts/record-feature-demo-gui.sh` to generate a real macOS GUI recording
of Terminal.app running the demo. It opens a Terminal window, attaches it to the
demo tmux session, records that window area with `screencapture -v`, and writes a
`.mov` file under `demo-recordings/`.

The first GUI run may require macOS permissions:

- Screen Recording for the app launching the script.
- Automation for controlling Terminal.app.

Use `scripts/record-feature-demo.sh` only when a deterministic non-GUI render is
needed. It generates a repeatable video without real agent logins or a real LLM
endpoint. Both scripts create:

- a throwaway git repo,
- two fake workmux agents,
- a local OpenAI-compatible mock judge,
- a detached tmux session,
- an isolated temporary `HOME` so normal config is not touched.

The script runs with a temporary `HOME`, so the fake workmux agents and judge
report stay isolated from the user's normal config. It does not modify the source
repository except for writing the generated video under `demo-recordings/`.
