# Worktree Cockpit (`wtcp`)

**A multi-agent comparison layer on top of [workmux](https://github.com/raine/workmux).**
Run several coding agents on **one prompt** in an isolated tmux grid, then
review, score, and merge the best — all from a few keystrokes.

```
┌──────────────┬──────────────┬──────────────┐
│ claude  ★ 8  │ codex   ★ 9  │ opencode ★ 6 │   ← one prompt, N agents, scored
│              │              │              │
├──────────────┴──────────────┴──────────────┤
│ wtcp (prefix, then) Ctrl-P pick · Ctrl-X drop · Ctrl-S send-all · Ctrl-R review
└─────────────────────────────────────────────┘
```

## wtcp is workmux, fanned out

workmux already does the hard part: one command gives you a git worktree, a
tmux window, and a coding agent running in it, plus a clean `merge` that folds
the branch back and tears the worktree down. wtcp does not reimplement any of
that — **every worktree, branch, agent launch, status icon, and merge below is
workmux doing its job.** `wtcp` is the layer that runs *N of them against the
same prompt* and helps you choose:

| Layer | Owns |
|-------|------|
| **workmux** | worktrees + branches, tmux windows, launching/prompting each agent, agent status tracking, `merge` / `remove` / base + main branch policy |
| **wtcp** | one prompt → N agents at once, joining their panes into a scored grid, an LLM judge that ranks them head-to-head, and one keystroke to merge the winner and drop the rest |

So everything you know about workmux keeps working, and anything workmux
configures (`main_branch`, `base_branch`, agent profiles, hooks) is policy wtcp
follows rather than overrides. If you also drive workmux by hand in the same
repo, read
[Using wtcp alongside plain workmux](#using-wtcp-alongside-plain-workmux) — wtcp
deliberately keeps to its own lane there.

**If you don't use workmux yet, start there.** wtcp only pays off once running
one agent in a worktree is already routine for you.

## Requirements

**[workmux](https://github.com/raine/workmux)** — the engine wtcp drives, not an
optional integration. Install and set it up first, alongside `tmux`, `git`,
`jq`, and `curl` (usually preinstalled or one `brew`/`apt` away):

```sh
brew install raine/workmux/workmux      # macOS / Linuxbrew
workmux setup                           # once: installs the agent status hooks
```

`workmux setup` is not optional decoration — the grid's live 🤖/💬/✅ pane
badges are read straight out of workmux's per-agent state files, so without the
hooks the borders stay blank. `wtcp doctor` tells you if they're missing.

**Agent CLIs** — install and **log in to** the ones you want to compare; neither
workmux nor wtcp authenticates them, they only launch them. An "agent" here is a
workmux agent name: the builtins workmux knows (`claude`, `codex`, `opencode`,
`gemini`) or any profile in your `~/.config/workmux/config.yaml`. Others (e.g.
`agy` / Antigravity) are auto-configured by wtcp.

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

At minimum, set `COCKPIT_AGENTS` to workmux agent names whose CLIs are installed
and logged in on your machine. Set the judge endpoint fields when you want
`wtcp score`.

## Quick start

Run wtcp from the repository you want agents to edit, inside tmux — the same
place you'd run `workmux add`:

```sh
cd /path/to/your/git-repo
tmux new -s wtcp

wtcp doctor                 # tmux, workmux config fit, deps, configured agents
wtcp agents codex claude    # use only agents installed + logged in on this machine
wtcp start "add a CONTRIBUTING.md"
```

`wtcp start` is `workmux add` repeated once per agent — same worktrees, same
branches, same prompt injection — with the resulting panes gathered into one
grid instead of scattered across windows.

Once the grid opens, review the panes. If a judge endpoint is configured, use
`prefix Ctrl-R` to open the review menu: run the LLM judge, **merge the scored
winner in one step** (`wtcp merge` — no menu, it reads the judge's 🏆/top score),
pick a winner from a menu, **view any agent's full diff**, show the detailed
report, or copy the last result. You can also focus any pane and use
`prefix Ctrl-P` to pick it yourself. If the round was analysis-only (the winner has no code diff), picking
**keeps that agent as a live session** instead of merging, so you can continue
the conversation — see
[Analysis rounds](#analysis-rounds--keep-a-session-instead-of-merging).

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
| `Ctrl-P` | **pick** focused pane as winner → auto-commit + merge into the workmux main branch, drop the rest. A winner with **no code changes** is **kept as a live session** instead (see [Analysis rounds](#analysis-rounds--keep-a-session-instead-of-merging)) |
| `Ctrl-K` | **keep** the focused agent's live session (own window, **no merge**), drop the other agents and the grid |
| `Ctrl-X` | **drop** just the focused pane (grid re-tiles) |
| `Ctrl-S` | **send** a follow-up instruction to *every* agent; arrows/backspace edit with Readline, `Ctrl-C` cancels |
| `Ctrl-F` | **fork**: type a prompt in a popup → new multi-agent round branched from the focused agent's work |
| `Ctrl-R` | **review menu**: run the judge (normal or fresh), merge/pick the winner, keep a session, view diff, show or copy the report |
| `z` | fullscreen the focused agent (again to return) · arrows move between agents |
| `[` | scroll/copy a pane (mouse wheel scrolls; drag to select copies to the clipboard; `Ctrl-U`/`Ctrl-D` page, `y`/`Enter` copy, `q` exits) |

Clicking any pane (focused or not) selects it; the mouse wheel scrolls the pane
**under the cursor** — agents that handle the mouse themselves get the wheel
events directly, other panes scroll tmux history.

Each agent pane's border also shows a **live status** straight from workmux:
`🤖` while the agent is working, `💬` when it's waiting for input, `✅` when
it's done. workmux's own window-name status icons can't survive the grid
(the agent windows are joined into it), so wtcp reads workmux's per-pane
state files (the same source the sidebar/dashboard use) and re-stamps the
icon on each border. This requires workmux's agent status hooks to be
installed — run `workmux setup` once (covers claude/codex/opencode/...).
Tune or disable the watcher with `COCKPIT_STATUS*` (see [Configuration](#configuration)).

`wtcp pick` and `wtcp merge` also pass workmux merge strategies through:
`wtcp pick <name> --squash`, `--rebase`, or `--into <branch>` (stacked
branches) work exactly like `workmux merge`'s flags.

Use **Ctrl + the letter** — the Ctrl variants pass through the Korean IME.

Other commands: `wtcp send "..."`, `wtcp merge` (merge the **judge's winner**
in one shot — reads the scored 🏆/top-★ pane, then runs the normal pick
machinery), `wtcp keep [name]` (keep one agent's live session, drop the rest —
no merge), `wtcp fork "..."` (new round from a pane's WIP), `wtcp winner`
(menu to pick the scored winner and merge it),
`wtcp diff [name]` (an agent's **full** diff vs the round base in a popup — the
focused pane's agent, or a menu; rendered with [delta](https://github.com/dandavison/delta)
when installed), `wtcp show` (last judge report), `wtcp copy` (copy last judge
report), `wtcp abandon` (discard the current grid without merging), `wtcp grid`,
`wtcp list`, `wtcp clean` (this round's worktrees; `--all` for every workmux
worktree in the repo), `wtcp doctor` (environment check). Run `wtcp help`
for the full list. See
[Using wtcp alongside plain workmux](#using-wtcp-alongside-plain-workmux) when
you also drive workmux by hand.

### What commands change

| Command | Effect |
|---------|--------|
| `wtcp start` | creates one worktree/branch per configured agent and opens the grid |
| `wtcp pick` | commits the focused winner if needed; **with code changes** merges it, removes the other round worktrees, and closes the grid; **without code changes** keeps the winner as a live session (like `wtcp keep`) |
| `wtcp keep` | moves one agent's pane into its own window (worktree + running agent survive, nothing merged), removes the other agents' worktrees, closes the grid |
| `wtcp drop` | removes only the focused agent's worktree/pane |
| `wtcp fork` | commits the focused pane's WIP as a base and starts another round from it |
| `wtcp abandon` | removes the current grid's worktrees without merging anything |
| `wtcp clean` | removes **this round's** worktrees and closes wtcp grid windows (kept sessions included); worktrees you created with plain `workmux add` are left alone |
| `wtcp clean --all` | removes **every** workmux worktree in the repo, uncommitted changes and all — asks for confirmation first |

## Using wtcp alongside plain workmux

wtcp drives workmux, so both read the same config and can share a repo and a
tmux session. wtcp keeps to its own lane:

- **Destructive commands are scoped.** `wtcp clean`, `pick`, `keep`, and
  `abandon` only touch worktrees wtcp created for the round. Use
  `wtcp clean --all` (which confirms first) for the repo-wide sweep — that one
  *does* remove worktrees you made yourself. `wtcp list` is a plain passthrough
  to `workmux list`, so it still shows everything.
- **Your workmux agent entries are never overwritten.** wtcp writes launch
  commands into `~/.config/workmux/config.yaml` for agents it manages, marking
  them `# wtcp-managed`, and backs the file up to `config.yaml.wtcp-bak` before
  its first change. An entry you wrote by hand — especially a multi-line
  `type:`/`command:`/`args:`/`env:` block — is left exactly as-is, and wtcp
  tells you that its `COCKPIT_AGENT_*_CMD`/`_MODEL` for that name is being
  ignored. To hand an entry over to wtcp, delete it or append `# wtcp-managed`.
- **Branch policy comes from workmux.** At round launch wtcp resolves the base
  ref to an immutable commit SHA, passes that SHA as workmux's explicit
  `--base`, and stores the same SHA for judging. A branch moving while agents
  work therefore cannot pollute their diffs, and a `base_branch:` in your
  workmux config can't make launch and scoring disagree.
  Where wtcp has to guess a base it uses your `main_branch` before falling back
  to `main`/`master`.
- **Starting a round inside another worktree.** This is allowed, but
  `workmux merge` always targets `main_branch` — so the winner would land on
  main rather than the branch you're on. wtcp warns when the round starts and
  then makes `wtcp pick` ask for an explicit `--into <branch>` instead of
  merging somewhere you didn't mean.
- **During a round, use wtcp's commands.** Agent panes are joined into the grid
  window, so workmux's `send`/`capture`/`run` can no longer find them by window
  name; `wtcp send` and the in-grid keys are the equivalents. `workmux
  dashboard`/`sidebar` keep working — they read the per-pane state files, which
  is also where the grid's 🤖/💬/✅ icons come from.
- **`wtcp doctor` reports the fit.** It prints your `main_branch`,
  `base_branch`, and flags settings wtcp can't follow — a custom
  `window_prefix`/`worktree_prefix` (the grid silently never assembles), a
  custom `panes:`/`windows:` layout (wtcp grids only the first pane of each
  agent window), and which agent entries are yours versus wtcp's.

One thing wtcp does **not** survive: a tmux server restart. Round state lives in
tmux window options, so `workmux resurrect` brings the worktrees' windows back
but not the grid — score/pick/diff won't work in it. Merge or `keep` what you
want before restarting tmux; otherwise re-run the round, or `wtcp clean --all`
to clear the leftovers.

## Analysis rounds — keep a session instead of merging

Not every round produces code. When you ask the agents to *analyze*, *review*,
or *answer a question*, the "result" is the conversation in the winning pane —
there is nothing to merge, but you usually want to **continue working with that
agent**.

That's what **keep** does (`prefix Ctrl-K` on the focused pane, the review
menu's *Keep a session*, or `wtcp keep [name]`):

- the kept agent's pane moves to its **own tmux window** — the worktree and the
  **running agent session (full conversation context) survive**;
- the other agents' worktrees are removed and the grid closes;
- nothing is merged.

`wtcp pick` chooses automatically based on the diff: a winner **with code
changes** is merged as usual; a winner **with no code changes vs the round
base** is kept as a live session instead. So you can always score with
`prefix Ctrl-R` and pick the winner — wtcp does the right thing for both kinds
of rounds.

**Continuing from a kept session.** Type follow-ups directly in the kept pane —
it's the same agent, same conversation. When a follow-up deserves another
multi-agent comparison, press **`prefix Ctrl-F`** (fork): type the new prompt in
the popup and a fresh grid launches, with every agent **branched from the kept
agent's work**. Rounds can alternate naturally: fan out → keep one → continue →
fan out again.

> Tip: before forking from an analysis-only session, ask the kept agent to
> write its findings to a file (e.g. `NOTES.md`). `wtcp fork` auto-commits the
> worktree's WIP, so the new round's agents all start with those findings —
> otherwise the analysis exists only in the kept pane's scrollback.

When you're done with a kept session, `prefix Ctrl-X` (drop) removes its
worktree and closes the window.

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
others and names a winner. The judge sees the full instruction timeline: the
initial prompt plus any `wtcp send` / `Ctrl-S` follow-ups. Later follow-ups refine
or supersede earlier instructions when they conflict, and every score reflects
the agent's **current final state** at the moment you run `wtcp score`.

It evaluates both evidence vs the round's immutable base SHA and terminal
output. Each candidate's evidence starts with `git status --short`, the complete
changed-file list and numstat, static imports from changed tests, and explicit
truncation counts. Patch excerpts then receive a file-balanced budget, with new
test files prioritized, so one large early diff cannot hide every later file.
For code tasks, visible implementation evidence is the source of truth while
output supports tests run, claims, and analysis. Explicitly omitted content is
uncertain rather than evidence that a matching terminal claim is false.

For test-heavy work, the judge treats a green pass count as a gate rather than a
quality score. It is instructed to prefer verified coverage deltas and to check
whether tests import and exercise real product modules instead of rewarding
synthetic/self-fulfilling fixtures or surface keywords. For analysis, review,
debugging, planning, or research tasks with empty diffs, terminal output remains
the primary evidence. The popup shows a short bullet report; each pane border
gets its score. It falls back to independent scoring if comparison can't parse.

Every score uses one canonical, additive rubric:

| Dimension | Points | What it measures |
|---|---:|---|
| Task | 0–4 | Explicit requirements fulfilled correctly at the right layer |
| Grounding | 0–3 | Primary evidence, factual accuracy, and correct repository identity |
| Verification | 0–2 | Tests/checks or systematic analysis and risk reasoning |
| Actionability | 0–1 | Clear priorities, maintainability, and requested scope |

The report prints this breakdown and an auditable `Caps:` line for every
candidate. The model supplies dimensions and cap IDs; wtcp computes the final
score itself, ignores any redundant model-provided score, and deterministically
lowers relevant dimensions when needed to enforce a declared cap. The displayed
breakdown therefore always sums to the displayed score. Judge JSON is rejected
when dimensions are missing/out of range, use an unknown cap ID, omit/rename a
candidate, omit the evidence classification or per-dimension reasons, or name a
winner that is not tied for the top absolute score. Absolute rubric scores are
computed before head-to-head ranking; wtcp then sorts the report by those
scores.

Every candidate must classify its central-claim evidence as `direct`, `mixed`,
or `narrative_only`. “Direct” requires visible raw command/test output or source
excerpts for every central claim—an agent-authored conclusion, exact-looking
number, path citation, pass count, or the word “verified” is not sufficient.
Mixed evidence limits Grounding to 2 and is capped at **9/10**; narrative-only
evidence limits Grounding to 1 and is capped at **8/10**. The resulting
`mixed_primary_evidence` /
`narrative_only_evidence` cap is printed in the report.

The four dimensions are intentionally orthogonal. Task measures absolute
fulfillment, Grounding visible support, Verification the checking method, and
Actionability prioritization/scope. The judge must provide one concise reason
for each dimension and may not use the same underlying weakness twice.
Comparative phrases such as “less detailed than the winner” do not lower an
absolute score by themselves. This prevents one minor breadth difference from
becoming both a Task and Grounding deduction merely to widen the ranking.
Unverified numbers belong under Grounding/Verification rather than Task, a
brief optional implementation offer after a complete analysis is ignored, and
only the stored Instruction timeline—not user-like text found in pane output—
defines the requested work.

Candidate feedback is also structural rather than a free-form paragraph. Each
record supplies `strength`, `deduction`, `improve_dimension`, and `improve`.
For every score below 10, `improve_dimension` must name a dimension that is
actually below its maximum after evidence limits and hard caps; a full-credit
dimension cannot be presented as the way to raise the score. The report renders
this explicitly as, for example, `Improve [grounding]`. A sub-10 record cannot
claim `Deduction: None`.

Each dimension also carries a lowercase snake-case issue ID. After evidence
limits and hard caps are applied, wtcp clears issue IDs on full-credit
dimensions and namespaces a declared hard-cap ID when that one cap necessarily
affects several dimensions. Any remaining reuse of one non-cap issue ID across
deducted dimensions is rejected as double-charging the same weakness. Reports
print the normalized IDs next to the dimension reasons so the point loss is
auditable. If a Task issue ID explicitly describes only an evidence,
verification, or comparative concern, wtcp restores Task credit, keeps the
concern under Grounding/Verification, and prints the deterministic adjustment
in the report. This avoids relying on a model repair turn that may simply copy
the same misplaced deduction.

Comparative output separately records `winner_reason`, `tie_break`, and a
neutral `summary`. A winner must have a top absolute score, and tied top scores
require a substantive non-score tie-break rather than an artificial deduction.
If evidence/cap normalization creates a tie only after the model responds,
wtcp turns `not_needed` into an explicit judge-preference tie-break instead of
rejecting an otherwise usable judgment. The summary is instructed not to
generalize one candidate's weakness to the whole field; an exact duplicate of
`winner_reason` is omitted from the rendered report.

Judge response space scales with the number of candidates. If the first answer
is invalid or truncated, wtcp sends the same evidence back once with a
format-only JSON repair instruction at temperature 0; score arithmetic alone
does not trigger a retry because it is owned by wtcp. The repair does not ask
the model to reconsider the substantive ranking. If the repaired comparative response is
still invalid, wtcp records both raw responses in
`~/.config/wtcp/judge-invalid.txt` and falls back to independently judging each
candidate. Independent responses receive the same one-repair treatment, so a
remaining `?/10` includes the diagnostic path instead of hiding the failed
model output.

Hard gates keep detailed hallucinations from scoring well: analyzing another
repository is capped at **2/10** with Grounding 0; fabricated or directly
contradicted central evidence and wrong-layer/nonfunctional core work are capped
at **4/10**; a missing major explicit requirement is capped at **6/10**; and a
material unresolved fact conflict that blocks verification is capped at
**8/10**. A 10 is exceptional and requires direct evidence for every central
claim, full credit in every independent dimension, and correct repository
identity.

To make those gates enforceable, every evidence manifest identifies the
canonical repository and package, worktree and HEAD, tracked/test-file counts,
and the complete top-level tracked structure. A response that describes another
product or relies on central path namespaces absent from that profile receives
no credit for its apparent detail, test counts, or pass rate.

After scoring, **`wtcp merge`** merges the winner's branch without any menu: it
reads the 🏆-marked pane (or the highest ★ score when there is no trophy) and
runs the same pick machinery — merge when the winner has code changes, keep the
session when it doesn't. The winner menu (`prefix Ctrl-R`) remains for choosing
a different agent than the judge's pick.

You can score repeatedly during a multi-turn round. Previous scores are shown to
the judge only as context for improvement/regression; the judge is instructed to
grade the current evidence, not to preserve an earlier ranking. The judge sees as
much context as fits its window — the instruction timeline, manifest plus
balanced patch excerpts, and each agent's pane scrollback, budgeted by the
`*_CHARS` vars below. Complete manifests and a minimum new-test excerpt may
slightly exceed the nominal evidence target rather than being silently omitted.
Change evidence and terminal output share one per-agent pool: unused diff space
automatically flows to the terminal, which prevents read-only analysis rounds
from wasting half their context. Terminal output that still exceeds the pool is
packaged as explicit head + tail excerpts with total/delivered counts instead of
silently keeping only the tail.

Use `wtcp score --fresh` (also available in the `Ctrl-R` menu) after correcting
an evaluation setup problem or whenever prior scores might anchor the next
decision. It reuses the current round and evidence but omits all previous judge
labels/reasons, so restarting the agents is unnecessary.

The report keeps structural labels in English, but writes each agent's
**reason/summary content in the same language as your prompt**. Judge bullets are
kept concise and include an `Improve:` bullet when points were deducted. The
prompt explicitly tells the judge not to reward or penalize language choice
unless your task requires a specific language.
It also shows a `Judge model:` line naming the model the endpoint actually used.

`wtcp copy` copies the last report from `~/.config/wtcp/judge.txt` to the system
clipboard (`pbcopy`, `wl-copy`, or `xclip`).

## Comparing models and backends

`COCKPIT_AGENTS` entries are workmux agent names and must be unique because they
become branch/worktree suffixes. To compare the **same CLI with different
models**, give each variant an alias and set its model — wtcp launches the
alias's base CLI with `--model`:

Aliases are not inferred from their names. For example, `codex-glm` does not
select GLM by itself; it must have a matching `COCKPIT_AGENT_CODEX_GLM_MODEL`,
`COCKPIT_AGENT_CODEX_GLM_CMD`, or named profile in
`~/.config/workmux/config.yaml`. If none is set, wtcp refuses the alias and tells
you which profile names or model settings are available. It will not silently run
`codex-glm` with the default Codex model.

```sh
# claude vs claude: which model handles this prompt better?
COCKPIT_AGENTS="claude-fable claude-opus claude-sonnet"
COCKPIT_AGENT_CLAUDE_FABLE_MODEL="fable"
COCKPIT_AGENT_CLAUDE_OPUS_MODEL="opus"
COCKPIT_AGENT_CLAUDE_SONNET_MODEL="sonnet"
```

`COCKPIT_AGENT_<ALIAS>_MODEL` accepts anything the CLI's `--model` flag accepts
(an alias like `opus`, or a full model id). It works for any alias whose kind is
a real CLI that takes `--model` — codex and opencode switch models the same way:

```sh
COCKPIT_AGENT_CODEX_GPT5_MODEL="gpt-5"                      # -> codex --model gpt-5
COCKPIT_AGENT_OPENCODE_GLM_MODEL="zai-coding-plan/glm-5.2"  # -> opencode --model <provider>/<model>
```

(opencode takes `provider/model` — use the provider id from your opencode
config.) `wtcp doctor` prints the exact command each alias will launch and the
installed CLIs / workmux profiles detected on the current machine.

When no model is set for a plain agent such as `claude` or `codex`, wtcp uses
`COCKPIT_AGENT_<KIND>_DEFAULT_MODEL` or `COCKPIT_AGENT_DEFAULT_MODEL`. The
built-in default for `claude` is `sonnet`. For `codex`, wtcp reads the model
from `~/.codex/config.toml` and otherwise lets the Codex CLI use its own
default. opencode has no built-in default because its `provider/model` names
are local to your opencode config. Aliases still require an explicit `_MODEL`,
`_CMD`, or workmux profile so unsupported model combinations fail with guidance
instead of launching the wrong model.

For anything `--model` can't express — a different **backend** behind the same
CLI, extra flags, env vars — set `COCKPIT_AGENT_<ALIAS>_CMD` with the full
command instead (it wins over `_MODEL`). That is how you attach **GLM (or any
Anthropic-compatible endpoint) to Claude Code** and race it against the stock
models:

```sh
COCKPIT_AGENTS="claude-fable claude-glm opencode-glm"
COCKPIT_AGENT_CLAUDE_FABLE_MODEL="fable"
# Claude Code CLI pointed at Zhipu's GLM endpoint (any Anthropic-compatible API works):
COCKPIT_AGENT_CLAUDE_GLM_CMD="env ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic ANTHROPIC_AUTH_TOKEN=sk-... ANTHROPIC_MODEL=glm-5.2 claude"
# ...and the same model through opencode, for a same-model different-CLI race:
COCKPIT_AGENT_OPENCODE_GLM_KIND="opencode"
COCKPIT_AGENT_OPENCODE_GLM_MODEL="zai-coding-plan/glm-5.2"
```

All variants run side by side in the grid, get scored by the judge like any
other agents, and the winner merges the same way.

Aliases starting with `claude-`, `codex-`, `opencode-`, or `agy-` inherit the
right trust-store handling and `COCKPIT_TRUST` launch flags. For other names,
set `COCKPIT_AGENT_<ALIAS>_KIND`, for example
`COCKPIT_AGENT_MY_ALIAS_KIND="codex"` (the kind is also the CLI that `_MODEL`
aliases launch).

`agy-*` names do **not** select Gemini models automatically. Plain `agy` uses
wtcp's prompt-loading wrapper for the default agy CLI. If you want
`agy-gemini` (or any other `agy-*`) to be a distinct backend, define it as a
real workmux profile or set `COCKPIT_AGENT_AGY_GEMINI_CMD`. Older wtcp versions
could leave aliases like `agy-gemini: ~/.config/wtcp/agy-wm`; `wtcp doctor`
reports those as stale generic wrappers, not usable backend profiles.

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
| `COCKPIT_JUDGE_OUTPUT_CHARS` | `16000` | target per-agent terminal evidence budget; unused diff space is added |
| `COCKPIT_JUDGE_DIFF_CHARS` | `16000` | target per-agent manifest + balanced patch evidence budget |
| `COCKPIT_JUDGE_COMPARE_CHARS` | `48000` | target total comparative evidence budget (split between agent evidence and terminal output) |
| `COCKPIT_PROMPT_LOG_CHARS` | `12000` | instruction timeline budget for initial prompt + follow-ups |
| `COCKPIT_JUDGE_TIMEOUT` | `120` | seconds per judge request |
| `COCKPIT_LAUNCH_TIMEOUT` | `0` | seconds to wait for agent windows; `0` auto-scales for slow cold worktree hooks |
| `COCKPIT_STATUS` | `1` | live 🤖/💬/✅ status on grid pane borders, read from workmux's per-pane state (`0` disables) |
| `COCKPIT_STATUS_INTERVAL` | `3` | status poll interval (seconds) |
| `COCKPIT_POPUP_WIDTH` / `COCKPIT_POPUP_HEIGHT` | `92%` / `85%` | tmux popup size for judge details |
| `COCKPIT_POPUP_DIM` / `COCKPIT_POPUP_DIM_STYLE` | `1` / `fg=colour244,bg=colour235` | dim pane styles behind popups; tmux has no true blur/backdrop |
| `COCKPIT_NAMER` | `fm` | branch naming: `fm` (Apple Intelligence) / `mlx` / `off` |
| `COCKPIT_NAMER_URL` / `COCKPIT_NAMER_MODEL` | judge settings | optional separate endpoint/model for branch naming |
| `COCKPIT_NO_INTERACTIVE_MENUS` | `0` | `1` = never auto-open the winner menu after scoring (headless runs) |
| `COCKPIT_TRUST` | `0` | **opt-in**: skip the per-agent folder-trust dialog + auto-approve tool use so new projects auto-start (edits the agents' trust stores + global workmux config) |
| `COCKPIT_CLAUDE_CMD` / `COCKPIT_CODEX_CMD` | _(see below)_ | override how claude/codex launch under `COCKPIT_TRUST` |
| `COCKPIT_AGENT_DEFAULT_MODEL` | _(empty)_ | fallback model for plain agents whose kind has no specific default |
| `COCKPIT_AGENT_CLAUDE_DEFAULT_MODEL` | `sonnet` | default model for plain `claude` |
| `COCKPIT_AGENT_CODEX_DEFAULT_MODEL` | `~/.codex/config.toml` model | default model for plain `codex`; empty falls back to Codex CLI's own default |
| `COCKPIT_AGENT_OPENCODE_DEFAULT_MODEL` | _(empty)_ | optional opencode default, usually `provider/model` from your opencode config |
| `COCKPIT_AGENT_<ALIAS>_CMD` | _(empty)_ | full command for a custom/variant agent alias (env vars, backends, extra flags; wins over `_MODEL`) |
| `COCKPIT_AGENT_<ALIAS>_MODEL` | _(empty)_ | model for an alias: launches the alias kind's CLI with `--model <value>` |
| `COCKPIT_AGENT_<ALIAS>_KIND` | inferred | base kind for alias trust handling and the CLI `_MODEL` launches (`claude`, `codex`, `opencode`, `agy`, etc.) |

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
