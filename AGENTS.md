# worktree-cockpit — developer notes

> **Canonical agent memory, shared across all coding agents.** Codex and agy load
> this file directly; Claude Code loads it via `@AGENTS.md` in `CLAUDE.md`. Edit
> these notes HERE — `CLAUDE.md` is just a thin importer, so do not duplicate
> content into it (drift between the two is what previously corrupted this file).

`wtcp` is a single Bash script (`./wtcp`, symlinked onto PATH by `install.sh`)
that runs several coding agents on one prompt in an isolated tmux grid, then
reviews, scores, and merges the best. It orchestrates **workmux + tmux + git**;
the only "smart" dependency is an OpenAI-compatible LLM endpoint used for branch
naming and scoring. See `README.md` for user-facing usage.

This file is the design/gotcha memory for working ON wtcp itself.

## Layout of the repo

- `wtcp` — the whole tool (one Bash file). Commands dispatched at the bottom `case`.
- `fm-helper/wtcp-fm-helper.swift` + `scripts/build-fm-helper.mjs` — optional
  on-device Apple Intelligence helper for branch naming (macOS). Built binary
  (`assets/fm-helper/wtcp-fm-helper`) is `.gitignore`d; `install.sh` builds it.
- `install.sh` — symlinks `wtcp` to PATH, builds the FM helper, warns on missing deps.
- `wtcp.config.example` → user copies to `~/.config/wtcp/config` (sourced shell vars).

## Architecture (wtcp script)

- Config is sourced from `~/.config/wtcp/config` first, then `: "${VAR:=default}"` fills gaps.
- `_run_round` is the core: `workmux add -a <agent>...` branches one worktree per
  agent and launches it, then **join-pane** pulls each agent's pane into one grid
  window, a full-width command bar is added at the bottom, and the grid is laid out.
- In-grid actions are tmux keybindings installed by `cmd_setup` (run automatically
  by `cmd_broadcast`): prefix + Ctrl-P/X/R/S → pick/drop/score/send. They call back
  via `$INVOKE <verb>` (INVOKE resolves to `wtcp` on PATH).
- `cmd_score` does **comparative** judging (all agents in one LLM call → rank +
  winner), falling back to independent per-agent scoring (`_score_independent`).

## Hard-won gotchas (do not regress these)

1. **workmux blocks on a TTY stdin.** `workmux add`/`remove` go interactive when
   stdin is a terminal and hang even with `-f` (raw-string agents on add; a select
   UI on remove). ALL workmux calls go through `_wm(){ command workmux "$@" </dev/null; }`.
2. **join-pane stacks vertically → "create pane failed: pane too small".** The 5th/6th
   agent fails to join unless the grid is re-tiled after each join. `_run_round` runs
   `select-layout tiled` after every join-pane during assembly.
3. **workmux creates worktrees sequentially (~1.5–2s each).** A fixed `sleep` races
   past >4 agents. `_run_round` polls until all agent windows appear (timeout scales
   with agent count).
4. **tmux assigns panes to layout cells by pane-INDEX order, NOT by the pane ids in
   the layout string** (verified). The grid is built rows-first so index order →
   row-major fill; the blank pad pane is created last so it lands in the final cell.
   The layout checksum is computed in pure Bash (`_layout_checksum`, ord via
   `printf '%d' "'c"`); algorithm: `c=(c>>1)+((c&1)<<15); c=(c+ord)&0xffff`.
5. **Grid shapes are fixed**: 2→1×2, 3→1×3, 4→2×2, 5→2×3 (one blank bottom-right),
   6→2×3. Rule: `rows = N<=3 ? 1 : 2`, `cols = ceil(N/rows)`. **Max 6 agents** —
   `wtcp agents` and `wtcp start` refuse more (7+ unsupported).
6. **Folder-trust ≠ permission bypass.** `--dangerously-skip-permissions` (claude) /
   `--dangerously-bypass-approvals-and-sandbox` (codex) auto-approve *tool use* but do
   NOT skip the "Do you trust this folder?" dialog. That dialog is skipped by
   pre-seeding each agent's own trust store (`_pretrust`, gated on `COCKPIT_TRUST=1`):
   - claude → `~/.claude.json` `projects[<worktree>].hasTrustDialogAccepted=true` (jq, atomic)
   - codex → `~/.codex/config.toml` `[projects."<repo-root>"] trust_level="trusted"` (codex scopes to repo root)
   - agy → manual; its store is under `~/.gemini` (shared with the Google OAuth token — do NOT touch)
   Under `COCKPIT_TRUST=1`, claude launches `--permission-mode auto` (NOT bypass; per user preference);
   codex keeps its bypass flag. Both overridable via `COCKPIT_CLAUDE_CMD` / `COCKPIT_CODEX_CMD`.
7. **`cmd_setup` sets global tmux options** (`mouse on`, `mode-keys vi`,
   `history-limit 100000`). history-limit is raised so `wtcp score` can feed the
   judge each agent's whole pane scrollback. mouse-on is global (tmux has no
   per-window mouse) — to copy text users hold ⌥Option while dragging.
8. **`wtcp clean` must remove worktrees BEFORE killing windows** — it is usually run
   from the grid's bottom bar pane, and killing that window would otherwise end the
   script before removal (the old "run clean twice" bug). Kills its own window last.
9. **Mouse/keys are tmux SERVER-GLOBAL and the terminal's mouse-reporting state can
   go stale.** `cmd_setup` sets `mouse on` + keybindings globally, but they don't fix
   the layers above tmux. Symptom seen in the wild: identical config works on one
   machine, not another — click-to-select-pane + wheel scroll dead even with
   `mouse on`. Causes, in order of likelihood: (a) a long-lived tmux session whose
   terminal mouse mode drifted → **detach (`prefix d`) + re-run** re-initializes it;
   (b) **nested tmux** (outer tmux/ssh eats the mouse before the inner tmux sees it)
   → use a bare terminal; (c) terminal emulator not forwarding mouse (iTerm2 prefs
   aren't synced across Macs; avoid `tmux -CC` integration). `cmd_setup` also falls
   back to pre-2.1 `mode-mouse` for ancient tmux. `wtcp doctor` surfaces all of this
   (tmux version, live mouse/mode-keys, nesting heuristic via `#{client_termname}`,
   agent CLIs on PATH, deps).

## Config vars (all `COCKPIT_*`, set in `~/.config/wtcp/config`)

Agents/launch: `COCKPIT_AGENTS`, `COCKPIT_TRUST`, `COCKPIT_CLAUDE_CMD`,
`COCKPIT_CODEX_CMD`, `COCKPIT_SENDKEYS_AGENTS`, `COCKPIT_SEND_DELAY`, `COCKPIT_AGY_DELAY`.
Naming: `COCKPIT_NAMER` (fm|mlx|off), `COCKPIT_NAMER_URL`, `COCKPIT_FM_HELPER`, `COCKPIT_DAEMON_PORT`.
Judge: `COCKPIT_JUDGE_URL`, `COCKPIT_JUDGE_AUTH` (Authorization header for hosted
endpoints; namer reuses it via `COCKPIT_NAMER_AUTH`), `COCKPIT_JUDGE_OUTPUT_CHARS`,
`COCKPIT_JUDGE_DIFF_CHARS`, `COCKPIT_JUDGE_COMPARE_CHARS`, `COCKPIT_JUDGE_TIMEOUT`.
Misc: `COCKPIT_INVOKE` (keybinding callback command), `WTCP_CONFIG` (config path).

## Testing wtcp without real agents

Real agents are interactive TUIs; to exercise the machinery headlessly, register
**fake string agents** in the *global* workmux config (`~/.config/workmux/config.yaml`,
back it up first) that make a deterministic commit then keep the pane alive:

```yaml
  fgood: "sh -c 'printf \"def add(a,b): return a+b\\n\" > sol.py && git add -A && git commit -qm g; exec sleep 100000 </dev/null'"
  fbad:  "sh -c 'printf \"def add(a,b): return a-b\\n\" > sol.py && git add -A && git commit -qm b; exec sleep 100000 </dev/null'"
```

Then, in a throwaway git repo, drive a detached tmux session via `send-keys` with a
test config (`WTCP_CONFIG=...` pointing at fake agents + a real judge endpoint),
poll for completion, and inspect `tmux list-panes`/`~/.config/wtcp/judge.txt`.
Always restore the workmux config and remove the fake agents afterward. workmux
needs a running tmux **server**; a fully attached client is only needed for real
interactive agents, not for the join/layout/score machinery.

## Dependencies

Required: `tmux`, `workmux` (`brew install raine/workmux/workmux`), `git`, `jq`,
`curl`. Optional: the agent CLIs being compared, and a Node + Xcode toolchain to
build the FM helper. Judge/namer need an OpenAI-compatible `/chat/completions`
endpoint (local Ollama/MLX/LM Studio or hosted).
