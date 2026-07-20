#!/usr/bin/env bash
# tests/test_workmux_coexist.sh — regression test for the parts of wtcp that
# share state with plain `workmux` use.
#
# Runs against a scratch tmux socket, a fake HOME (so the real
# ~/.config/workmux/config.yaml is never touched) and a throwaway git repo.
#
# Covers:
#   - _workmux_cfg_value / _workmux_main_branch: reading workmux's own policy
#   - _set_agent_cfg: never overwrites a HAND-WRITTEN agent entry, never
#     collapses a multi-line block definition, backs up before its first write,
#     and stays idempotent on entries it owns (marked "# wtcp-managed")
#   - _diff_base: falls back to workmux's main_branch before guessing main/master
#   - _in_linked_worktree: tells the main worktree from a linked one
#   - _cockpit_worktrees / cmd_clean: `wtcp clean` removes ONLY the round
#     worktrees, leaving worktrees the user created with plain `workmux add`
#
# Run: bash tests/test_workmux_coexist.sh

set -uo pipefail
WTCOP="$(cd "$(dirname "$0")/.." && pwd)/wtcp"
TEST_SOCKET="wtcp_coexist_$$"
PASS=0; FAIL=0
fail(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
pass(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
is(){ # $1 = label  $2 = got  $3 = want
  [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"
}

TMP="$(mktemp -d)"; trap 'command tmux -L "$TEST_SOCKET" kill-server 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP"
CFG="$TMP/.config/workmux/config.yaml"
mkdir -p "$TMP/.config/workmux" "$TMP/.config/wtcp"

tmux(){ command tmux -L "$TEST_SOCKET" "$@"; }

extract_fn(){ # $1 = function name -> print its definition (header line ... closing brace)
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)" { print; in_fn=1; next }
    in_fn && /^}$/ { print; exit }
    in_fn { print }
  ' "$WTCOP"
}

{
  echo 'WIN_PREFIX="wt"; WTCP_CFG_MARK="# wtcp-managed"; WTCP_CFG_BACKED_UP=0'
  echo 'say(){ printf "wtcp %s\n" "$*"; }; die(){ printf "wtcp x %s\n" "$*" >&2; exit 1; }'
  echo 'need_repo(){ :; }'
  for f in _workmux_cfg_global _workmux_cfg_value _workmux_main_branch \
           _backup_workmux_cfg _agent_cfg_exists _agent_cfg_is_wtcp_managed \
           _agent_cfg_command _agent_cfg_is_block _set_agent_cfg _diff_base \
           _in_linked_worktree _cockpit_worktrees cmd_clean; do
    extract_fn "$f"
  done
} > "$TMP/functions.sh"
# shellcheck disable=SC1090
. "$TMP/functions.sh" || { echo "could not extract functions from wtcp"; exit 2; }

# ── Fixtures: a workmux config with hand-written entries, and a git repo ─────
cat > "$CFG" <<'EOF'
nerdfont: true
main_branch: develop
window_prefix: "zz-"
agents:
  claude: "claude --model opus"
  claude-glm:
    type: claude
    command: claude
    env:
      X: y
EOF
cp "$CFG" "$TMP/before.yaml"

REPO="$TMP/repo"; mkdir -p "$REPO"
git init -q "$REPO"; git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" branch -M develop
cd "$REPO" || exit 2

# ── Test 1: reading workmux's config ────────────────────────────────────────
echo "T1: _workmux_cfg_value"
is "main_branch"          "$(_workmux_cfg_value main_branch)" "develop"
is "quoted value unquoted" "$(_workmux_cfg_value window_prefix)" "zz-"
is "absent key -> empty"  "$(_workmux_cfg_value no_such_key)" ""
is "_workmux_main_branch" "$(_workmux_main_branch)" "develop"
# A project .workmux.yaml wins over the global config.
printf 'main_branch: proj-main\n' > "$REPO/.workmux.yaml"
is "project config wins"  "$(_workmux_main_branch)" "proj-main"
rm -f "$REPO/.workmux.yaml"

# ── Test 2: the agents map is the USER's file ───────────────────────────────
echo "T2: _set_agent_cfg safety"
_agent_cfg_is_block claude-glm && pass "multi-line block detected" || fail "multi-line block detected"
_agent_cfg_is_block claude && fail "scalar entry is not a block" || pass "scalar entry is not a block"
_agent_cfg_is_wtcp_managed claude && fail "unmarked entry not claimed" || pass "unmarked entry not claimed"

_set_agent_cfg claude "claude --permission-mode auto" \
  && fail "refuses to overwrite a hand-written scalar" || pass "refuses to overwrite a hand-written scalar"
_set_agent_cfg claude-glm "claude --model glm" \
  && fail "refuses to overwrite a hand-written block" || pass "refuses to overwrite a hand-written block"
if diff -q "$TMP/before.yaml" "$CFG" >/dev/null; then pass "config byte-identical after refusals"
else fail "config byte-identical after refusals"; fi

# An unmarked entry that ALREADY says what wtcp would write is a no-op, not a
# conflict — that's the upgrade path from wtcp versions predating the marker.
is "reads a scalar entry's command" "$(_agent_cfg_command claude)" "claude --model opus"
is "block entry has no scalar"      "$(_agent_cfg_command claude-glm)" ""
_set_agent_cfg claude "claude --model opus" && pass "identical entry is a silent no-op" || fail "identical entry is a silent no-op"

_set_agent_cfg newagent "newagent --flag" && pass "writes a brand-new agent" || fail "writes a brand-new agent"
_agent_cfg_is_wtcp_managed newagent && pass "new entry carries the marker" || fail "new entry carries the marker"
[ -f "$CFG.wtcp-bak" ] && pass "backup written before first change" || fail "backup written before first change"
_set_agent_cfg newagent "newagent --other" && pass "rewrites an entry it owns" || fail "rewrites an entry it owns"
is "no duplicate entry" "$(grep -c 'newagent:' "$CFG")" "1"
grep -q 'X: y' "$CFG" && pass "hand-written block survived every write" || fail "hand-written block survived every write"
grep -q 'claude: "claude --model opus"' "$CFG" && pass "hand-written scalar survived" || fail "hand-written scalar survived"

# ── Test 3: judge base follows workmux's main_branch ────────────────────────
echo "T3: _diff_base"
is "falls back to main_branch"  "$(_diff_base "$REPO" "")" "develop"
is "keeps an explicit valid base" "$(_diff_base "$REPO" "develop")" "develop"
is "invalid base -> main_branch" "$(_diff_base "$REPO" "no-such-ref")" "develop"

# ── Test 4: linked-worktree detection ──────────────────────────────────────
echo "T4: _in_linked_worktree"
_in_linked_worktree && fail "main worktree not flagged" || pass "main worktree not flagged"
git -C "$REPO" worktree add -q -b feat "$TMP/wt-feat" >/dev/null 2>&1
( cd "$TMP/wt-feat" && _in_linked_worktree ) && pass "linked worktree flagged" || fail "linked worktree flagged"

# ── Test 5: `wtcp clean` scope — the reason this file exists ───────────────
# A wtcp grid window (panes stamped @worktree) sits next to a window for a
# worktree the user made with plain `workmux add`. clean must touch only the
# former. _wm is stubbed to record calls instead of removing anything.
echo "T5: cmd_clean scope"
tmux -f /dev/null new-session -d -s s -x 200 -y 50
grid=$(tmux new-window -d -P -F '#{window_id}' -n "wt:round1")
p1=$(tmux list-panes -t "$grid" -F '#{pane_id}' | head -1)
p2=$(tmux split-window -d -t "$p1" -P -F '#{pane_id}')
bar=$(tmux split-window -d -t "$p1" -P -F '#{pane_id}')
tmux set-option -p -t "$p1" @worktree "round1-claude"
tmux set-option -p -t "$p2" @worktree "round1-codex"
tmux set-option -p -t "$bar" @cockpit_bar 1          # bar pane: no @worktree
tmux new-window -d -n "wm-my-own-feature" >/dev/null # the user's own workmux window

export TMUX="dummy"   # _cockpit_worktrees only needs the tmux() stub above
found=$(_cockpit_worktrees | sort | tr '\n' ' ')
is "only stamped agent panes" "$found" "round1-claude round1-codex "

WM_CALLS="$TMP/wm_calls"; : > "$WM_CALLS"
_wm(){ printf '%s\n' "$*" >> "$WM_CALLS"; }
cmd_clean >/dev/null 2>&1
if grep -q -- '--all' "$WM_CALLS"; then fail "scoped clean must not use 'remove --all'"
else pass "scoped clean avoids 'remove --all'"; fi
is "removed exactly the round worktrees" \
   "$(sort "$WM_CALLS" | tr '\n' ' ')" "remove round1-claude -f remove round1-codex -f "
grep -q 'my-own-feature' "$WM_CALLS" && fail "user's own worktree untouched" || pass "user's own worktree untouched"

# --all still reaches the wide removal, but only after an explicit confirmation.
: > "$WM_CALLS"
# Subshell: an unconfirmed --all calls die(), which would exit this script.
(cmd_clean --all </dev/null) >/dev/null 2>&1
is "--all aborts without a confirmed yes" "$(cat "$WM_CALLS")" ""
: > "$WM_CALLS"
(cmd_clean --bogus) >/dev/null 2>&1 && fail "unknown flag rejected" || pass "unknown flag rejected"

echo
echo "results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
