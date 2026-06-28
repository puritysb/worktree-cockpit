# Worktree Cockpit (`wtcp`)

Run several coding agents on **one prompt** in an isolated tmux grid, then
review, score, and merge the best — all from a few keystrokes.

`wtcp` is a thin orchestrator over [workmux](https://github.com/raine/workmux) + tmux + git:
it branches a git worktree per agent, broadcasts your prompt to all of them,
tiles them into a grid with a command bar, and gives you in-grid keys to score
the results (via any LLM endpoint) and merge the winner to `main`.

```
┌──────────────┬──────────────┬──────────────┐
│ claude  ★ 8  │ codex   ★ 9  │ opencode ★ 6 │   ← one prompt, N agents, scored
│              │              │              │
├──────────────┴──────────────┴──────────────┤
│ wtcp (prefix, then) Ctrl-P pick · Ctrl-X drop · Ctrl-S send-all · Ctrl-R score
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

**An LLM endpoint** — used by `wtcp score` (and, off macOS, branch naming). Any
OpenAI-compatible `/chat/completions` works. Pick one and set `COCKPIT_JUDGE_URL`
(see [LLM endpoint](#llm-endpoint) below). On macOS, branch naming additionally
uses on-device Apple Intelligence with no setup.

## Install

```sh
git clone https://github.com/puritysb/worktree-cockpit
cd worktree-cockpit
./install.sh           # symlinks `wtcp` onto your PATH; builds the FM helper on macOS
```

Then configure the LLM endpoint (and anything else) by copying the example:

```sh
mkdir -p ~/.config/wtcp
cp wtcp.config.example ~/.config/wtcp/config
$EDITOR ~/.config/wtcp/config        # set COCKPIT_JUDGE_URL at minimum
```

### LLM endpoint

`wtcp score` needs one OpenAI-compatible `/chat/completions` URL. Set it once in
`~/.config/wtcp/config` as `COCKPIT_JUDGE_URL`. Common choices:

| Provider | `COCKPIT_JUDGE_URL` | Notes |
|----------|---------------------|-------|
| **Ollama** (local, free) | `http://localhost:11434/v1/chat/completions` | `ollama pull qwen2.5-coder` first |
| **LM Studio** (local) | `http://localhost:1234/v1/chat/completions` | start its local server |
| **MLX** (local, Apple Silicon) | `http://localhost:8800/v1/chat/completions` | `mlx_lm.server` |
| **OpenAI** | `https://api.openai.com/v1/chat/completions` | set `COCKPIT_JUDGE_AUTH="Bearer sk-..."` |

For hosted endpoints that need an API key, set `COCKPIT_JUDGE_AUTH` to the full
`Authorization` header value (e.g. `Bearer sk-...`); the namer reuses it. Local
servers (Ollama/LM Studio/MLX) need no key and are the easiest start — offline,
no keys.

If `wtcp score` shows *"no judgment — is the judge LLM running?"*, the endpoint
isn't reachable: check the URL and that the server is up.

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
| `Ctrl-P` | **pick** focused pane as winner → auto-commit + merge to `main`, drop the rest |
| `Ctrl-X` | **drop** just the focused pane (grid re-tiles) |
| `Ctrl-S` | **send** a follow-up instruction to *every* agent |
| `Ctrl-R` | **score** every agent with the judge LLM (★ on the border + a "why" popup) |
| `z` | fullscreen the focused agent (again to return) · arrows move between agents |
| `[` | scroll a pane (mouse wheel also works; `Ctrl-U`/`Ctrl-D` to page, `q` to exit) |

Use **Ctrl + the letter** — the Ctrl variants pass through the Korean IME.

Other commands: `wtcp send "..."`, `wtcp fork "..."` (new round from a pane's
WIP), `wtcp abandon` (discard a review-only round), `wtcp grid`, `wtcp list`,
`wtcp clean`. Run `wtcp help` for the full list.

## How scoring works

`wtcp score` asks an LLM (your `COCKPIT_JUDGE_URL`) to rate each agent 0–10 with
a one-line reason. It judges the **diff vs `main`** when the task produced code,
or the agent's **terminal output** when it didn't (conversational/analysis
tasks) — so non-code tasks are scored fairly too. It's a lightweight, on-demand
judge, independent of any external eval system.

## Configuration

All settings live in `~/.config/wtcp/config` (sourced shell vars). See
[`wtcp.config.example`](wtcp.config.example). Key ones:

| Var | Default | Meaning |
|-----|---------|---------|
| `COCKPIT_AGENTS` | `claude codex opencode` | agents compared by `wtcp start` |
| `COCKPIT_JUDGE_URL` | `localhost:11434/v1/chat/completions` | LLM endpoint for `wtcp score` |
| `COCKPIT_JUDGE_AUTH` | _(empty)_ | `Authorization` header value for hosted endpoints, e.g. `Bearer sk-...` (namer reuses it) |
| `COCKPIT_NAMER` | `fm` | branch naming: `fm` (Apple Intelligence) / `mlx` / `off` |
| `COCKPIT_TRUST` | `0` | **opt-in**: launch agents with trust/permission bypass so new projects auto-start (disarms approval/sandbox gates; edits the global workmux config) |

### `COCKPIT_TRUST` — auto-starting new projects

By default, agents show their "Do you trust this folder?" prompt on a new
project — confirm once and that repo auto-starts thereafter. Setting
`COCKPIT_TRUST=1` launches claude/codex/agy with their `--dangerously-*` flags so
even the first round starts unattended. **This auto-approves all tool use and
disables the sandbox**, and it edits your global workmux config, so it is off by
default. Enable it only for repositories you trust.
