# worktree-cockpit — developer notes

> **Canonical agent memory, shared across all coding agents.** Codex and agy load
> this file directly; Claude Code loads it via `@AGENTS.md` in `CLAUDE.md`. Edit
> these notes HERE — `CLAUDE.md` is just a thin importer, so do not duplicate
> content into it (drift between the two is what previously corrupted this file).

`wtcp` is a single Bash script (`./wtcp`, symlinked onto PATH by `install.sh`)
that runs several coding agents on one prompt in an isolated tmux grid, then
reviews, scores, and merges the best. It orchestrates **workmux + tmux + git**;
the optional "smart" dependency is an OpenAI-compatible LLM endpoint used for
scoring and, when configured, branch naming. See `README.md` for user-facing usage.

This file is the design/gotcha memory for working ON wtcp itself.

## Layout of the repo

- `wtcp` — the whole tool (one Bash file). Commands dispatched at the bottom `case`.
- `fm-helper/wtcp-fm-helper.swift` + `scripts/build-fm-helper.mjs` — optional
  on-device Apple Intelligence helper for branch naming (macOS). Built binary
  (`assets/fm-helper/wtcp-fm-helper`) is `.gitignore`d; `install.sh` builds it.
- `install.sh` — symlinks `wtcp` to PATH, builds the FM helper, warns on missing deps.
- `wtcp.config.example` → user copies to `~/.config/wtcp/config` (sourced shell vars).
- `.agents/skills/session-end/SKILL.md` — repo-shared Codex session closeout /
  handoff workflow, ported from Claude's `/session-end` command.

## Architecture (wtcp script)

- Config is sourced from `~/.config/wtcp/config` first, then `: "${VAR:=default}"` fills gaps.
- `_run_round` is the core: `workmux add -a <agent>...` branches one worktree per
  agent and launches it, then **join-pane** pulls each agent's pane into one grid
  window, a full-width command bar is added at the bottom, and the grid is laid out.
- In-grid actions are tmux keybindings installed by `cmd_setup` (run automatically
  by `cmd_broadcast`): prefix + Ctrl-P/K/X/R/S/F → pick/keep/drop/score/send/fork.
  They call back via `$INVOKE <verb>` (INVOKE resolves to `wtcp` on PATH).
- `cmd_score` does **comparative** judging (all agents in one LLM call → rank +
  winner), falling back to independent per-agent scoring (`_score_independent`).
- `wtcp merge` is the NON-interactive winner merge: `_scored_winner` reads the
  🏆-marked pane label (comparative scoring), else the top numeric ★ from
  `_scored_rows`, and hands the name to `cmd_pick` (so the diff/no-diff split
  applies). Refuses when nothing is scored. The menus stay for manual choice.
  `cmd_pick`/`cmd_merge` pass workmux merge STRATEGY flags through verbatim
  (`--squash`, `--rebase`, `--into <branch>`); winner = first non-flag arg.
- Live pane status: `_spawn_status_watch` (from `_run_round`/`_keep_session`)
  runs one detached `cmd_status_watch` per grid/kept window (pid in
  `@cockpit_watch`, single-instance, exits when the window dies). It reads
  workmux's per-pane state files (`~/.local/state/workmux/agents/*.json`, same
  source the sidebar/dashboard use) via `_workmux_pane_status` and stamps
  `@cockpit_status` 🤖 (working) / 💬 (waiting) / ✅ (done), rendered by
  `_style_window`'s border format. Required because join-pane destroys
  workmux's own window-name status icons; ASSUMES workmux's agent status hooks
  are installed (`workmux setup`; standard for claude/codex/opencode). Panes
  with no workmux state (shell/bar/empty pad) get no icon. The same watcher
  re-tiles on a pane-set change so sub-panes an agent spawns (Claude Code's
  tmux teammate mode) stay visible — see `_retile_with_teammates`.
- `prefix Ctrl-R` opens a `display-menu` (run judge / run fresh judge /
  merge-winner / pick-winner menu / keep / view-diff / show / copy).
  `wtcp score --fresh` omits previous pane scores/reasons so a corrected
  evidence pipeline can re-evaluate the CURRENT round without anchoring or
  restarting agents. After scoring — and via `wtcp winner` /
  the menu's "pick winner" —
  `_winner_menu` reads the ★scores stamped on each pane border (via `_scored_rows`:
  unjudged `★ ?` panes get sort key −1 so they land LAST — `?` is text and would
  otherwise sort above numbers under `sort -rn`), ranks best-first, and a selection
  runs `wtcp pick <worktree>`. `cmd_pick` therefore takes an OPTIONAL worktree arg
  (the menu passes it); with no arg it uses the focused pane. Losers are found by
  worktree name, not pane focus, so an explicit winner still drops the rest.
  Menus (`_agent_menu`) /`display-menu` no-op without an attached client (headless tests).
- `wtcp diff [wt]` shows an agent's FULL diff vs `@cockpit_base` in a popup
  (`_show_diff_popup`): the judge reads `_wt_evidence`, which puts status, the
  complete tracked/untracked file list + numstat, changed-test import signals,
  and explicit truncation accounting before file-balanced patch excerpts
  (new tests first); the viewer reads the uncapped `_wt_diff_raw`. Renders via
  `delta` when on PATH (force `DELTA_PAGER='less -R'` —
  delta's default pager includes `-F`, the popup flash-close gotcha) else
  `git diff --color=always` + `less -R`. Writes `~/.config/wtcp/diff.txt` even
  headless (the test observable).
- Judge terminal evidence uses `_terminal_evidence`, not a raw `tail -c`.
  Comparative scoring gives each candidate one combined pool; unused change
  evidence budget flows to terminal evidence. Long scrollback is trailing-blank
  trimmed and packaged as explicit head + tail with total/delivered counts.
  This matters most for read-only analysis rounds, where terminal output is the
  deliverable and a longer report must not lose its opening while shorter peers
  remain complete.
- The judge rubric has ONE source, `_judge_rubric`: Task 0–4 + Grounding 0–3 +
  Verification 0–2 + Actionability 0–1. The model does NOT own the redundant
  final-score arithmetic: `_rubric_response_normalize` validates dimensions,
  candidate names/winner, and cap IDs, ignores any model-emitted `score`,
  computes score from the breakdown, and deterministically lowers relevant
  dimensions to enforce declared caps. `_rubric_response_valid` is its
  no-output wrapper. Never reintroduce a required model-computed score: Qwen
  repeatedly returned valid breakdowns with an off-by-one score and copied the
  same mismatch in a repair turn. Every record must include `evidence_level`
  (`direct|mixed|narrative_only`) and four `dimension_reasons`. Normalization
  adds `mixed_primary_evidence` (Grounding ≤2, total ≤9) or
  `narrative_only_evidence` (Grounding ≤1, total ≤8), requires the named winner
  to have a top absolute score, and sorts rankings by computed score. The prompt
  keeps dimensions orthogonal: a comparative-only weakness is not an absolute
  deduction, unverified facts do not lower Task, optional next-step offers are
  not scope failures, the stored timeline alone defines requirements, and one
  issue must not be charged twice. Feedback is structured as
  `strength`/`deduction`/`improve_dimension`/`improve`; normalization rejects
  an improvement aimed at a full-credit dimension (and requires a real target
  below 10) or `Deduction: None` below 10. Every dimension has a snake-case
  `dimension_issue_id`. Normalization clears IDs on full-credit dimensions and
  namespaces a declared hard-cap ID when it affects several dimensions;
  remaining duplicate non-cap IDs across deducted dimensions are rejected so
  one issue cannot be charged twice. Evidence/verification/comparison-only
  Task deductions are removed deterministically, with the adjustment exposed
  in the report; evidence-level caps also synthesize a missing Grounding issue
  ID, and declared hard-cap ID variants are namespaced per dimension.
  That Task guard matches on ID WORDING and was trivially dodged by naming the
  rival's finding concretely (`missed_orphan_references` cost two candidates a
  Task point for a gap the instruction never requested), so
  `comparative_task_issue` also strips omission-relative IDs
  (`missed_`/`overlooked_`/`omitted_`/`not_identified_`/`failed_to_identify_`/
  `less_thorough_`…) UNLESS the ID names a requested item
  (`requirement`/`requested`/`instruction`/`asked`). Known trade-off: a judge
  that expresses a genuinely weak candidate's Task gap comparatively gets that
  deduction refunded, so a thin answer can gain a point — the rubric's own
  orthogonality rule (Task scores the answer against the timeline, never against
  rivals) makes that the correct reading, and the fix is a judge that names the
  absolute defect. Ranking order is unaffected.
  Comparative JSON also requires
  `winner_reason`, `tie_break`, and neutral `summary`. If normalization creates
  a top-score tie after the response, `none`/`not_needed` becomes an explicit
  judge-preference tie-break; an exact duplicate summary is omitted from the
  report.
  Judge response tokens scale per candidate.
  A schema failure gets exactly one format-only retry (`_judge_repair_request`,
  temperature 0, same evidence/substantive judgment); a second failure records
  both model responses in `~/.config/wtcp/judge-invalid.txt` before comparative
  scoring falls back to independent judging. Independent judging uses the same
  one-repair rule, so never replace strict validation with permissive parsing.
  **The retry MUST be told what failed.** `_rubric_response_normalize` explains
  every rejection on stderr (naming the offending field, the candidate for a
  comparative record, and the computed score); callers capture that text and
  `_judge_repair_request` puts it at the top of the repair turn, and
  `_record_invalid_judgment` stores it beside each response. A bare "schema
  validation failed" is what made Qwen resend byte-identical broken JSON three
  times in one round — never regress to an unlocated rejection.
  Reports and `@judge_reason` expose both the breakdown and applied `Caps`.
  Normalization runs BEFORE validation and `repair_feedback` heals the
  contradictions normalization itself creates: an evidence cap lowers a
  dimension after the model already wrote `improve_dimension`/`deduction` for
  the pre-cap score, and the model can never fix that on retry because it is
  never told the cap fired. Such records are re-targeted (and a `None`
  deduction filled in), mirroring the existing issue-ID re-targeting; a record
  whose breakdown wtcp did NOT touch still fails so genuine model errors keep
  their retry. Every downward adjustment is appended to `normalization_notes`
  so the report's `Adjustments` line stops reading `none` next to a number the
  model's own prose contradicts.
  `cmd_score` ROTATES `judge-invalid.txt` to `judge-invalid.prev.txt` instead of
  truncating it — a follow-up round used to erase the evidence for the round
  that motivated it.
  Measured against the real Qwen judge on one fixed 3-candidate round (see
  "Tuning the judge empirically" below), those changes took first-try validity
  from 1/5 to 5/6 and usable rounds from 3/5 to 6/6.
  `_wt_evidence` supplies a repository identity hard-gate profile
  (canonical common-git-dir repo name, package, worktree/HEAD, tracked/test
  counts, complete top-level tracked entries). Wrong-repository analysis gets
  Grounding 0 and total ≤2; never reward its detailed-looking paths or counts.
- `cmd_pick` branches on the diff: a winner WITH changes vs `@cockpit_base` merges
  as usual; a winner with NO changes (analysis/research round) is handed to
  `_keep_session` instead — `workmux merge` errors on an empty branch, and the
  valuable output there is the conversation in the pane, so keep it alive.
  `wtcp keep` (prefix Ctrl-K; the review menu calls `keep-menu` so it always
  offers the agent list) does the same explicitly for any agent, diff or not.
- `_keep_session` = break-pane the keeper into its own `wt:<worktree>` window,
  remove the losers' worktrees, kill the grid. It must COPY `@cockpit_root` /
  `@cockpit_prompt` / `@cockpit_base` onto the new window (window options do NOT
  survive break-pane) or goto_root/diff/fork stop working from the kept window;
  `@worktree`/`@pane_label` are PANE options and DO survive. A kept window has no
  shell pane, so `prefix Ctrl-F` (display-popup → `cmd_prompt_fork` → `cmd_fork`)
  is how it fans out a new multi-agent round (fork auto-commits WIP, so asking the
  kept agent to write findings to a file first carries them into the new round).
  Kept windows match the `wt:` prefix, so `cmd_clean` closes them and `cmd_grid`
  jumps to them; `wtcp drop` in a kept window removes worktree + window.
- `_show_judge_report` opens the report popup WITHOUT less's `-F`
  (which would auto-quit and flash the popup shut when the report fits one screen).
- Visual chrome: `_style_window` (heavy dim borders, bright active border, bold
  border labels, the bar label highlighted via `#{?#{@cockpit_bar},...}`) is
  applied to grid/kept windows by `_run_round`/`_keep_session`/`cmd_score` — keep
  them in sync. The bar pane opens with `wtcp bar-banner` (colored cheatsheet)
  before its shell. stdout logs go through `say`/`ok`/`die` (cyan tag / green ✔ /
  red ✗; plain when piped or NO_COLOR). `wtcp help` is `cmd_help` (structured,
  colorized), no longer the raw header-comment dump.

## Hard-won gotchas (do not regress these)

1. **workmux blocks on a TTY stdin.** `workmux add`/`remove` go interactive when
   stdin is a terminal and hang even with `-f` (raw-string agents on add; a select
   UI on remove). ALL workmux calls go through `_wm(){ command workmux "$@" </dev/null; }`.
2. **join-pane stacks vertically → "create pane failed: pane too small".** The 5th/6th
   agent fails to join unless the grid is re-tiled after each join. `_run_round` runs
   `select-layout tiled` after every join-pane during assembly.
3. **workmux creates worktrees sequentially and project hooks can be slow.** A fixed
   `sleep` races past >4 agents and cold hooks (for example per-worktree `pnpm
   install`) can take much longer. `_run_round` ignores a non-zero `workmux add`
   exit and polls until all agent windows appear; `COCKPIT_LAUNCH_TIMEOUT=0`
   auto-scales generously by agent count, or can be set to seconds explicitly.
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
   - claude → `~/.claude.json` `projects[<worktree>].hasTrustDialogAccepted=true`
     + `hasTrustDialogBashAccepted=true` (jq, atomic)
   - codex → `~/.codex/config.toml` `[projects."<repo-root>"] trust_level="trusted"` (codex scopes to repo root)
   - agy → manual; its store is under `~/.gemini` (shared with the Google OAuth token — do NOT touch)
   Under `COCKPIT_TRUST=1`, claude launches `--permission-mode auto` (NOT bypass; per user preference);
   codex keeps its bypass flag. Both overridable via `COCKPIT_CLAUDE_CMD` / `COCKPIT_CODEX_CMD`.
7. **`cmd_setup` sets global tmux options** (`mouse on`, `mode-keys vi`,
   `history-limit 100000`). history-limit is raised so `wtcp score` can feed the
   judge each agent's whole pane scrollback. mouse-on is global (tmux has no
   per-window mouse) — to copy text users hold ⌥Option while dragging.
   **Mouse bindings must target the pane under the mouse (`-t=`) and respect
   `mouse_any_flag`.** The old `WheelUpPane` binding forced copy-mode with no
   `-t=`: mouse-aware agent TUIs (claude/codex enable mouse reporting) never got
   wheel events so their own viewport wouldn't scroll, and on older tmux the
   ACTIVE pane scrolled instead of the hovered one. Current bindings mirror the
   tmux 3.x defaults (`if -Ft= '#{||:#{pane_in_mode},#{mouse_any_flag}}' send -M`
   else `copy-mode -e -t=`) plus an explicit `MouseDown1Pane 'select-pane -t= ;
   send-keys -M'` so click-to-focus survives user config overrides.
8. **`wtcp clean` must remove worktrees BEFORE killing windows** — it is usually run
   from the grid's bottom bar pane, and killing that window would otherwise end the
   script before removal (the old "run clean twice" bug). Kills its own window last.
9. **workmux window names may have a `wm-` prefix.** `_find_task_windows` must match
   both `<task>-<agent>` and `wm-<task>-<agent>`; exact-only matching fails grid
   assembly even though the worktrees launched.
10. **Mouse/keys are tmux SERVER-GLOBAL and the terminal's mouse-reporting state can
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

11. **Unattached `tmux display -p '#{pane_id}'` can resolve to the WRONG pane.**
   With no attached client (headless tests, agents driving tmux, scripts), the
   bare "current pane/window" can resolve to a different window than the caller's
   — observed: a command typed INTO a kept pane resolved `#{pane_id}` to another
   window's pane, so `wtcp pick` there died and `wtcp abandon` would have killed
   an unrelated window. ALL "which pane/window am I in" lookups go through
   `_cur_pane`/`_cur_win`, which prefer `$TMUX_PANE` (set for every process
   inside a pane) and fall back to `display -p` (correct when a client is
   attached — keybindings' run-shell and popups don't set TMUX_PANE but always
   have a client). Window-scoped `@cockpit_*` reads must pass `-t "$cwin"` /
   `-t "$(_cur_win)"` for the same reason.
12. **Commands that close the window they run in must do the `kill-window` LAST.**
   keep/pick/abandon usually execute inside the grid's bar pane; killing the
   grid HUPs that pane's process group — including the running wtcp and
   anything it just spawned. Everything after the kill is NOT guaranteed to
   run (`_keep_session` once spawned the kept-window status watcher after the
   kill: it never started). Corollary: background helpers are spawned with
   `nohup` + double fork (`_spawn_status_watch`) so they survive the HUP.
   (Same family as gotcha 8 / cmd_clean's remove-before-kill ordering.)
13. **`capture-pane -p` pads the viewport with trailing blank lines.** Sampling
   "the last N lines" therefore hashes constant blanks while the real content
   changes further up. The status watcher reads workmux state files directly;
   judge output goes through `_terminal_evidence`, which trims trailing blank
   rows and preserves head + tail when capped. Do not reintroduce raw tail/hash
   sampling.
14. **tmux mangles non-ASCII option values to `_` ON READ when the reading
   client's locale is not UTF-8** (storage keeps the raw bytes; verified by
   matrix test). All ★/🏆/🤖/💬/✅ parsing (`_scored_rows`, `_scored_winner`,
   status icons) assumes UTF-8 readers — true for normal shells, but headless
   tests MUST run every tmux client with `LC_ALL=C.utf8` or scored labels read
   back as `___` and winner resolution silently fails.
15. **`break-pane` on a single-pane window "succeeds" but only renames (tmux ≥ 3.4).**
   rc=0, EMPTY `-P` output, no new window. `_keep_session` must detect the
   1-pane case (keep/pick re-run inside an already-kept window) and rename in
   place instead — otherwise `nwin` is empty and the later `kill-window` on the
   old window would destroy the live session. Related guard: `cmd_pick` /
   `cmd_abandon` only `kill-window` windows whose name matches the `wt:` prefix,
   so running them from a plain shell window can't destroy that window.
16. **wtcp shares mutable state with plain `workmux` — never widen a blast radius.**
   The user drives workmux directly in the same repo, so wtcp's destructive and
   config-writing paths must be SCOPED to what wtcp itself created:
   - `cmd_clean` removes only worktrees stamped `@worktree` on panes of `wt:`
     windows (`_cockpit_worktrees`). The old `_wm remove --all -f` also deleted
     worktrees the user made by hand, uncommitted changes and all — that is now
     `wtcp clean --all`, behind a typed confirmation. Worktrees whose grid
     window is already gone are invisible to the scoped clean; `--all` is the
     escape hatch.
   - `_set_agent_cfg` writes the user's OWN `~/.config/workmux/config.yaml`.
     It backs the file up once per run (`.wtcp-bak`), tags entries it writes
     with `# wtcp-managed`, and REFUSES to touch anything without that tag —
     hand-written entries (especially multi-line `type:`/`command:`/`args:`/
     `env:` blocks, which the line-based rewrite would collapse into a scalar)
     survive. `_ensure_agent_configs` warns via `_warn_cfg_kept` that the
     agent's `COCKPIT_AGENT_*_CMD/_MODEL` is being ignored.
   `wtcp doctor`'s `_doctor_workmux_compat` surfaces the rest: `main_branch`,
   `base_branch`, an incompatible `window_prefix`/`worktree_prefix`, a custom
   `panes:`/`windows:` layout, and which agent entries are wtcp's vs the user's.
17. **Base branch and merge target come from workmux, not from wtcp's guesses.**
   `_run_round` resolves `round_base` to a commit SHA at launch, ALWAYS passes
   that SHA via `--base`, and stamps the same immutable SHA as `@cockpit_base`.
   A moving `main`/`master` must never alter an active round's evidence. Without
   explicit `--base`, workmux branches from its configured `base_branch` while
   wtcp may record a different ref — corrupting judge diffs and `cmd_pick`'s
   merge-vs-keep decision.
   `_diff_base` falls back to workmux's `main_branch` before guessing
   `main`/`master`. Starting a round inside a LINKED worktree is ambiguous
   (`workmux merge` always targets `main_branch`, not the branch you're on), so
   `_run_round` warns and stamps `@cockpit_from_worktree`; `cmd_pick` then
   refuses to merge until `--into` says which branch. A FORK is deliberately
   exempt — its base is a throwaway round branch whose commits reach main
   through the winner anyway.
   `_in_linked_worktree` resolves both git dirs with `cd … && pwd -P`: on macOS
   git hands back `/var/...` for one and `/private/var/...` for the other, and
   the naive comparison warned on every round.
18. **A grid agent that spawns sub-panes (Claude Code's `teammateMode: tmux`,
   or any agent that fans out via tmux) breaks the fixed grid shape.** wtcp
   doesn't BLOCK the spawning — that would cripple the agent — instead
   `cmd_status_watch` detects the pane-set change and calls
   `_retile_with_teammates`: newcomers (no `@worktree`/`@pane_label`) get
   stamped `@pane_label "teammate"`, the command bar is briefly broken out,
   the agent area is re-tiled `select-layout tiled`, then the bar is rejoined
   at full width / `BAR_HEIGHT` (verified bottom strip — see
   `tests/test_status_retile.sh`). Side effect: once teammates appear the grid
   is in `tiled` for good; the original 2×2/2×3 shape is NOT restored when
   teammates later vanish (acceptable — tiled is stable, fixed shape only at
   fresh assembly). The judge (`_judge_one` / `_scored_rows`) iterates panes
   by `@worktree`, so teammate panes are naturally skipped — they're never fed
   to the LLM judge and never show ★ scores. Teammates DO get 🤖/💬/✅ from
   workmux's status hooks (they're real agent processes), which is desirable.
19. **Popup text input must use Readline, not terminal canonical editing.**
   Plain `read` makes arrow keys literal escape bytes and can corrupt multibyte
   Korean text when editing. `_read_editable_line` uses `read -e`; send/fork
   popup prompts advertise `Ctrl-C` cancel, and empty Enter cancels cleanly.

## Design decisions (evaluated & rejected — don't re-litigate)

- **iTerm2-native split-view backend — rejected (2026-07).** iTerm2 can split panes
  via its Python API, but: (a) workmux only supports tmux/kitty/WezTerm/Zellij, so
  going iTerm2-native means reimplementing workmux's fused worktree+window+launch
  pipeline, not swapping a backend; (b) ~half of `wtcp` is raw tmux plumbing with
  no abstraction seam (join-pane grid + layout checksum, prefix keybindings →
  `$INVOKE`, display-menu/popup, `@pane_label` stamping, capture-pane scrollback
  for the judge) with no iTerm2 analog; (c) iTerm2 is GUI-only — no headless
  testing (breaks the fake-agent strategy above), no detach/ssh/Linux. iTerm2
  remains supported as a *host terminal* for tmux. If tmux ever has to go, the
  cheap path is a workmux-supported backend (WezTerm/kitty), not iTerm2.
- Agent peer/cross-review — rejected; a stronger judge is config, not a feature.

## Config vars (all `COCKPIT_*`, set in `~/.config/wtcp/config`)

Agents/launch: `COCKPIT_AGENTS`, `COCKPIT_AGENT_<ALIAS>_CMD` (full command, wins),
`COCKPIT_AGENT_<ALIAS>_MODEL` (kind CLI + `--model`; see `_agent_launch_cmd`),
`COCKPIT_AGENT_<ALIAS>_KIND`, `COCKPIT_TRUST`, `COCKPIT_CLAUDE_CMD`,
`COCKPIT_CODEX_CMD`, `COCKPIT_SENDKEYS_AGENTS`, `COCKPIT_SEND_DELAY`,
`COCKPIT_AGY_DELAY`, `COCKPIT_LAUNCH_TIMEOUT`, `COCKPIT_STATUS`,
`COCKPIT_STATUS_INTERVAL`.
Naming: `COCKPIT_NAMER` (fm|mlx|off), `COCKPIT_NAMER_URL`, `COCKPIT_NAMER_MODEL`,
`COCKPIT_NAMER_AUTH`, `COCKPIT_FM_HELPER`, `COCKPIT_DAEMON_PORT`, `COCKPIT_DAEMON_URL`.
Judge: `COCKPIT_JUDGE_URL`, `COCKPIT_JUDGE_AUTH` (Authorization header for hosted
endpoints; namer reuses it by default via `COCKPIT_NAMER_AUTH`), `COCKPIT_JUDGE_MODEL`,
`COCKPIT_JUDGE_OUTPUT_CHARS`, `COCKPIT_JUDGE_DIFF_CHARS`, `COCKPIT_JUDGE_COMPARE_CHARS`,
`COCKPIT_JUDGE_TIMEOUT`, `COCKPIT_POPUP_WIDTH`, `COCKPIT_POPUP_HEIGHT`,
`COCKPIT_NO_INTERACTIVE_MENUS` (1 = never auto-open the winner menu after
scoring; headless/tests).
Misc: `COCKPIT_INVOKE` (keybinding callback command), `WTCP_CONFIG` (config path).

## Tuning the judge empirically

Rubric changes must be MEASURED, not reasoned about — every plausible-sounding
change in this area has been wrong at least once. Capture one real round's
evidence blocks (`_wt_diff` + `_terminal_evidence` per pane, exactly as
`cmd_score` builds them), then replay that fixed payload against the judge N
times per variant and count: first-try validity, rounds that produce any usable
report, per-candidate score spread, and whether the ranking order inverts. One
sample proves nothing; the same input has scored one candidate 3 and 9.

Findings that cost real round-trips to learn, on
`mlx-community/Qwen3.6-35B-A3B-4bit`:

- **Clerical rejections are not repairable; judgment is sound.** Breakdown and
  ranking order were sane in essentially every sample. The failures were
  bookkeeping — duplicate issue IDs, a stray brace, feedback fields that
  contradict a cap. Prefer deterministic normalization over rejection for
  anything clerical; reserve rejection for what changes the verdict.
- **A rejection needs the offending BYTES, not a coordinate.** "line 30,
  column 1" produced a byte-identical resend more than once; quoting the
  surrounding lines back (`_judge_error_excerpt`) recovers it.
- **Never offer an escape hatch in an error message.** A strict pre-check that
  bounced `evidence_level: mixed` alongside `grounding: 3` suggested "or
  classify the evidence as direct" — the judge took that option and handed two
  candidates 10/10. The check was reverted; wtcp caps leniently instead.
- **Never synthesize report prose.** The report language is inferred by the
  model from the instruction timeline and is unknown to wtcp, so an invented
  English sentence lands inside a Korean report. `repair_feedback` reuses the
  judge's own `dimension_reasons[target]`.
- **Evidence level must be judged on the claims that ANSWER the instruction.**
  A narrative candidate that happened to run `pnpm test` oscillated between
  `mixed` and `narrative_only` (a 1-2 point swing that inverted the ranking
  once). Saying explicitly that incidental command output does not ground an
  assessment pinned it to `narrative_only` in 5/5 and removed the inversion.

## Testing wtcp without real agents

Fast unit-style regression tests (no real agents/tmux/workmux pollution) live
under `tests/`. Run them after touching `_workmux_pane_status`,
`_retile_with_teammates`, `cmd_status_watch`, or `_apply_grid_layout` (first
file), or `cmd_clean`, `_set_agent_cfg`, `_diff_base`, `_workmux_cfg_value`, or
`_in_linked_worktree` (second), or `_round_base_commit`, `_wt_evidence`,
`_wt_file_patch`, `_terminal_evidence`, `_judge_rubric`,
`_rubric_response_valid`, `_rubric_error_summary`,
`_judge_error_excerpt`, `_rotate_invalid_judgments`, judge budgets/prompts
(third), or popup
send/fork input editing (fourth):

```bash
bash tests/test_status_retile.sh     # 12 assertions; scratch tmux socket + fake HOME
bash tests/test_workmux_coexist.sh   # 32 assertions; also a throwaway git repo
bash tests/test_judge_evidence.sh    # 141 assertions; immutable base + rubric/evidence/repair
bash tests/test_prompt_input.sh      # 10 assertions; UTF-8 editing + clean cancel
```

These tests extract functions straight out of `wtcp` with `extract_fn` (an awk range
from `name()` to the closing `}` in column 1) rather than sourcing the script,
so a helper they cover must keep its brace on its own line.

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
`curl`. Also required for live grid status: workmux's per-agent status hooks
(run `workmux setup` once — installs hooks for claude/codex/opencode/gemini/...).
Optional: the agent CLIs being compared, and a Node + Xcode toolchain to build
the FM helper. Scoring needs a configured OpenAI-compatible `/chat/completions`
endpoint and, for most servers, a model name.
