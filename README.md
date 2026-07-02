# Worktree Cockpit (`wtcp`)

Run several coding agents on **one prompt** in an isolated tmux grid, then
review, score, and merge the best — all from a few keystrokes.

`wtcp` is a thin orchestrator over [workmux](https://github.com/raine/workmux) + tmux + git:
it branches a git worktree per agent, broadcasts your prompt to all of them,
tiles them into a grid with a command bar, and gives you in-grid keys to score
the results with your judge LLM and merge the winner into your configured
workmux main branch.

```
┌──────────────┬──────────────┬──────────────┐
│ claude  ★ 8  │ codex   ★ 9  │ opencode ★ 6 │   ← one prompt, N agents, scored
│              │              │              │
├──────────────┴──────────────┴──────────────┤
│ wtcp (prefix, then) Ctrl-P pick · Ctrl-X drop · Ctrl-S send-all · Ctrl-R review
└─────────────────────────────────────────────┘
```

## Requirements

**Core tools** — `tmux`, `git`, `jq`, `curl` (usually preinstalled or one `brew`/
`apt` away), plus [**workmux**](https://github.com/raine/workmux), the worktree
manager wtcp drives:

```sh
brew install raine/workmux/workmux      # macOS / Linuxbrew
```

**Agent CLIs** — install and **log in to** the ones you want to compare; wtcp only
launches them. Builtins workmux knows: `claude`, `codex`, `opencode`, `gemini`.
Others (e.g. `agy` / Antigravity) are auto-configured by wtcp. Each agent must
already be authenticated on your machine.

**A judge LLM endpoint** — required only for `wtcp score`. Use any
OpenAI-compatible `/chat/completions` endpoint you already run, local or hosted.
Set `COCKPIT_JUDGE_URL` and usually `COCKPIT_JUDGE_MODEL` (see
[LLM endpoint](#llm-endpoint)). On macOS, branch naming can use on-device Apple
Intelligence without a judge endpoint.

## Install

```sh
git clone https://github.com/puritysb/worktree-cockpit
cd worktree-cockpit
./install.sh           # symlinks `wtcp` onto your PATH; builds the FM helper on macOS
```

Then create a config file:

```sh
mkdir -p ~/.config/wtcp
cp wtcp.config.example ~/.config/wtcp/config
$EDITOR ~/.config/wtcp/config
```

At minimum, set `COCKPIT_AGENTS` to agent CLIs that are installed and logged in
on your machine. Set the judge endpoint fields when you want `wtcp score`.

## Quick start

Run wtcp from the repository you want agents to edit, inside tmux:

```sh
cd /path/to/your/git-repo
tmux new -s wtcp

wtcp doctor                 # check tmux, workmux, deps, and configured agents
wtcp agents codex claude    # use only agents installed + logged in on this machine
wtcp start "add a CONTRIBUTING.md"
```

Once the grid opens, review the panes. If a judge endpoint is configured, use
`prefix Ctrl-R` to open the review menu: run the LLM judge, **view any agent's
full diff**, show the detailed report, copy the last result, or **pick the
winner to merge** (a menu of the scored agents, best first — choosing one merges
it directly). You can also focus any pane and use `prefix Ctrl-P` to pick it
yourself.

## LLM endpoint

`wtcp score` calls an OpenAI-compatible `/chat/completions` endpoint. wtcp does
not ship a model or assume a provider. Configure the endpoint you actually use:

```sh
COCKPIT_JUDGE_URL="http://localhost:<port>/v1/chat/completions"
COCKPIT_JUDGE_MODEL="<model-name>"
COCKPIT_JUDGE_AUTH=""
```

For hosted APIs, set `COCKPIT_JUDGE_AUTH` to the full `Authorization` header
value, for example `Bearer ...`. For local servers that do not require auth,
leave it empty. Leave `COCKPIT_JUDGE_MODEL` empty only if your endpoint supplies
a default model server-side; most OpenAI-compatible servers require a model.

Branch naming can reuse the same endpoint/model/auth. On macOS the default
`COCKPIT_NAMER=fm` tries Apple Intelligence first; without that, or with
`COCKPIT_NAMER=off`, wtcp falls back to an ASCII slug of the prompt.

If `wtcp score` shows *"no judgment — is the judge LLM running?"*, check the URL,
model name, auth header, and that the server is running.

## Usage

Inside a **git repo**, inside a **tmux** session:

```sh
wtcp agents                      # show the compare set (default: claude codex opencode)
wtcp agents claude codex opencode agy   # set it (persists to ~/.config/wtcp/config)

wtcp start "add a CONTRIBUTING.md"      # branch each agent + broadcast + build the grid
```

The grid installs its keybindings automatically. In the grid, with your tmux
**prefix** then:

| Key | Action |
|-----|--------|
| `Ctrl-P` | **pick** focused pane as winner → auto-commit + merge into the workmux main branch, drop the rest |
| `Ctrl-X` | **drop** just the focused pane (grid re-tiles) |
| `Ctrl-S` | **send** a follow-up instruction to *every* agent |
| `Ctrl-R` | **review menu**: run the judge LLM, pick the winner to merge, view an agent's full diff, show the detailed report, or copy the last result |
| `z` | fullscreen the focused agent (again to return) · arrows move between agents |
| `[` | scroll/copy a pane (mouse wheel scrolls; drag to select copies to the clipboard; `Ctrl-U`/`Ctrl-D` page, `y`/`Enter` copy, `q` exits) |

Use **Ctrl + the letter** — the Ctrl variants pass through the Korean IME.

Other commands: `wtcp send "..."`, `wtcp fork "..."` (new round from a pane's
WIP), `wtcp winner` (menu to pick the scored winner and merge it),
`wtcp diff [name]` (an agent's **full** diff vs the round base in a popup — the
focused pane's agent, or a menu; rendered with [delta](https://github.com/dandavison/delta)
when installed), `wtcp show` (last judge report), `wtcp copy` (copy last judge
report), `wtcp abandon` (discard the current grid without merging), `wtcp grid`,
`wtcp list`, `wtcp clean`, `wtcp doctor` (environment check). Run `wtcp help`
for the full list.

### What commands change

| Command | Effect |
|---------|--------|
| `wtcp start` | creates one worktree/branch per configured agent and opens the grid |
| `wtcp pick` | commits the focused winner if needed, merges it when it has code changes, removes the other round worktrees, and closes the grid |
| `wtcp drop` | removes only the focused agent's worktree/pane |
| `wtcp fork` | commits the focused pane's WIP as a base and starts another round from it |
| `wtcp abandon` | removes the current grid's worktrees without merging anything |
| `wtcp clean` | removes all compare worktrees and closes wtcp grid windows |

## Troubleshooting

Run **`wtcp doctor`** first — it reports tmux version, the live `mouse`/`mode-keys`
state, whether you're in a nested tmux, the configured agents (and whether their
CLIs are on `PATH`), and missing dependencies.

**Mouse, per-pane scroll, or the in-grid keys don't work** (works on one machine
but not another): the quickest fix is to **detach tmux (`prefix d`) and re-run
`wtcp start`** (or just `wtcp setup`). `wtcp` sets `mouse on` and the keybindings
as *server-global* options, but a long-lived tmux session can leave the terminal's
mouse-reporting state stale — detaching re-initializes it. Also check:

- **Nested tmux** (local tmux → ssh → remote tmux, or tmux-in-tmux): the outer
  tmux eats mouse clicks/wheel so they never reach the inner one. Connect from a
  bare terminal (no outer tmux) instead. `wtcp doctor` flags likely nesting.
- **Terminal mouse reporting**: the emulator must forward mouse events. In iTerm2,
  settings aren't synced across machines — compare **Settings → Pointer** and the
  iTerm2 version on both. Don't use iTerm2's `tmux -CC` integration (different
  mouse model); launch plain `tmux`.
- **Old tmux** (< 2.1) uses `mode-mouse` instead of `mouse on`; `wtcp setup` falls
  back to it automatically, but upgrading tmux is better.

**The grid doesn't build / panes are missing** — usually an agent failed to
launch. On timeout `wtcp start` prints a per-agent launched/MISSING table and
asks whether to **keep** what did launch (default — slow worktree hooks may just
need more time; raise `COCKPIT_LAUNCH_TIMEOUT`) or **clean** the round's
worktrees. Make sure every name in `COCKPIT_AGENTS` is an installed,
**authenticated** CLI (and, for custom agents, defined in
`~/.config/workmux/config.yaml`). A too-small terminal window can also fail
joins ("pane too small") — make the window bigger.

**A merge conflict during `wtcp pick`** keeps the whole round intact — nothing
is removed. wtcp detects where the conflict landed (mid-merge in the main
worktree, mid-rebase in the winner's worktree, or — with current workmux —
nowhere, with a prompt to rebase the winner's worktree onto the base) and prints
the matching resolve/retry steps.

## How scoring works

`wtcp score` sends **all agents to the configured judge LLM in one call** so
it compares them head-to-head: it scores each 0–10 with a reason relative to the
others and names a winner. It evaluates both the diff vs the round base and the
terminal output: the diff is the source of truth for implementation quality,
while output is evidence for tests run, claims made, and analysis quality. Empty
diffs are valid for analysis/review tasks and are not penalized by themselves.
The popup shows a short bullet report; each pane border gets its score. It falls
back to independent per-agent scoring if the comparison can't be parsed.

The judge sees as much context as fits its window — the full diff plus each
agent's whole pane scrollback, budgeted by the `*_CHARS` vars below.

The report writes each agent's **reason/summary in the same language as your
prompt** (the judge mirrors the task's language; scores, names and the structural
labels stay as-is), but the prompt explicitly tells the judge not to reward or
penalize Korean vs English language choice unless your task requires a language.
It also shows a `Judge model:` line naming the model the endpoint actually used.

`wtcp copy` copies the last report from `~/.config/wtcp/judge.txt` to the system
clipboard (`pbcopy`, `wl-copy`, or `xclip`).

## Comparing Model Variants

`COCKPIT_AGENTS` entries are workmux agent names and must be unique because they
become branch/worktree suffixes. To compare the same CLI with different models or
backends, use aliases and map each alias to a command:

```sh
COCKPIT_AGENTS="claude-sonnet claude-mlx codex-gpt5 codex-mlx"
COCKPIT_AGENT_CLAUDE_SONNET_CMD="claude --model sonnet"
COCKPIT_AGENT_CLAUDE_MLX_CMD="claude --model mlx"
COCKPIT_AGENT_CODEX_GPT5_CMD="codex --model gpt-5"
COCKPIT_AGENT_CODEX_MLX_CMD="codex --model mlx"
```

Aliases starting with `claude-`, `codex-`, or `agy-` inherit the right trust-store
handling. For other names, set `COCKPIT_AGENT_<ALIAS>_KIND`, for example
`COCKPIT_AGENT_MY_ALIAS_KIND="codex"`.

## Grid layout

The compare set is capped at **6 agents**. Panes are arranged: 2→`1×2`, 3→`1×3`,
4→`2×2`, 5→`2×3` (one blank bottom-right), 6→`2×3`.

## Configuration

All settings live in `~/.config/wtcp/config` (sourced shell vars). See
[`wtcp.config.example`](wtcp.config.example). Key ones:

| Var | Default | Meaning |
|-----|---------|---------|
| `COCKPIT_AGENTS` | `claude codex opencode` | agents compared by `wtcp start` (max 6) |
| `COCKPIT_JUDGE_URL` | _(empty)_ | OpenAI-compatible `/chat/completions` endpoint for `wtcp score` |
| `COCKPIT_JUDGE_MODEL` | _(empty)_ | model name sent to the judge endpoint, if required |
| `COCKPIT_JUDGE_AUTH` | _(empty)_ | `Authorization` header for hosted endpoints, e.g. `Bearer sk-...` (namer reuses it) |
| `COCKPIT_JUDGE_OUTPUT_CHARS` | `16000` | per-agent terminal-output budget sent to the judge |
| `COCKPIT_JUDGE_DIFF_CHARS` | `16000` | per-agent diff budget |
| `COCKPIT_JUDGE_COMPARE_CHARS` | `48000` | total evidence budget for comparative scoring (split across agents) |
| `COCKPIT_JUDGE_TIMEOUT` | `120` | seconds per judge request |
| `COCKPIT_LAUNCH_TIMEOUT` | `0` | seconds to wait for agent windows; `0` auto-scales for slow cold worktree hooks |
| `COCKPIT_POPUP_WIDTH` / `COCKPIT_POPUP_HEIGHT` | `92%` / `85%` | tmux popup size for judge details |
| `COCKPIT_NAMER` | `fm` | branch naming: `fm` (Apple Intelligence) / `mlx` / `off` |
| `COCKPIT_NAMER_URL` / `COCKPIT_NAMER_MODEL` | judge settings | optional separate endpoint/model for branch naming |
| `COCKPIT_NO_INTERACTIVE_MENUS` | `0` | `1` = never auto-open the winner menu after scoring (headless runs) |
| `COCKPIT_TRUST` | `0` | **opt-in**: skip the per-agent folder-trust dialog + auto-approve tool use so new projects auto-start (edits the agents' trust stores + global workmux config) |
| `COCKPIT_CLAUDE_CMD` / `COCKPIT_CODEX_CMD` | _(see below)_ | override how claude/codex launch under `COCKPIT_TRUST` |
| `COCKPIT_AGENT_<ALIAS>_CMD` | _(empty)_ | command used for a custom/variant agent alias |
| `COCKPIT_AGENT_<ALIAS>_KIND` | inferred | base kind for alias trust handling (`claude`, `codex`, `agy`, etc.) |

Raise the `*_CHARS` budgets for a bigger-context judge model; lower them for a
small local one (char ≈ ⅓–¼ token, so keep the total under the model's window).

### `COCKPIT_TRUST` — auto-starting new projects

By default, agents show their "Do you trust this folder?" prompt on a new
project — confirm once and that repo auto-starts thereafter. `COCKPIT_TRUST=1`
makes even the first round start unattended by doing two things before the round:

- **Pre-seeding each agent's folder-trust store** so the trust dialog is skipped
  (claude → `~/.claude.json`, codex → `~/.codex/config.toml`). agy is left to a
  one-time manual accept — its store lives under `~/.gemini`.
- **Launching agents in an unattended permission mode** so they don't pause on
  every tool prompt: claude in `--permission-mode auto` (not full bypass), codex
  with `--dangerously-bypass-approvals-and-sandbox`. Override either with
  `COCKPIT_CLAUDE_CMD` / `COCKPIT_CODEX_CMD`.

This edits the agents' trust stores and the global workmux config, so it is off
by default. Enable it only for repositories you trust.
