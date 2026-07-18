#!/usr/bin/env bash
# tests/test_status_retile.sh — regression test for the workmux-state-driven
# status watcher helpers and the teammate retile path.
#
# Runs entirely against a scratch tmux socket (no real tmux/workmux pollution)
# and a fake HOME (no real agent state files touched). Exits non-zero on any
# failure so it can be wired into CI or a pre-commit hook.
#
# Covers:
#   - _workmux_pane_status: reads workmux per-pane state JSON by pane id
#   - _retile_with_teammates: labels newcomer panes "teammate", preserves the
#     command bar as the full-width bottom strip, and works bar-less (kept window)
#
# Run: bash tests/test_status_retile.sh

set -uo pipefail
WTCOP="$(cd "$(dirname "$0")/.." && pwd)/wtcp"
TEST_SOCKET="wtcp_test_$$"
PASS=0; FAIL=0
fail(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
pass(){ echo "  PASS: $*"; PASS=$((PASS+1)); }

# ── Harness: scratch tmux socket, fake HOME, extract fresh functions from wtcp ─
TMP="$(mktemp -d)"; trap 'command tmux -L "$TEST_SOCKET" kill-server 2>/dev/null; rm -rf "$TMP"' EXIT
export HOME="$TMP"            # _workmux_pane_status reads $HOME/.local/...
mkdir -p "$TMP/.local/state/workmux/agents"

tmux(){ command tmux -L "$TEST_SOCKET" "$@"; }

extract_fn(){ # $1 = function name -> print its definition (header line ... closing brace)
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)" { print; in_fn=1; next }
    in_fn && /^}$/ { print; exit }
    in_fn { print }
  ' "$WTCOP"
}

{
  echo 'WIN_PREFIX="wt"; BAR_HEIGHT=6'
  extract_fn '_workmux_pane_status'
  extract_fn 'pane_wt'
  extract_fn '_style_window'
  extract_fn '_retile_with_teammates'
} > "$TMP/functions.sh"

# shellcheck disable=SC1090
. "$TMP/functions.sh" || { echo "could not extract functions from wtcp"; exit 2; }

command -v jq >/dev/null || { echo "jq required (wtcp dep anyway)"; exit 2; }

write_state(){ # $1 = pane id (e.g. %101)  $2 = status (working|waiting|done)
  local pane="$1" status="$2"
  local pane_enc; pane_enc=$(printf '%%%s' "${pane#%}" | sed 's/%/%25/g')
  cat > "$TMP/.local/state/workmux/agents/tmux__test__${pane_enc}.json" <<EOF
{"pane_key":{"backend":"tmux","pane_id":"$pane"},"status":"$status","agent_kind":"claude"}
EOF
}

# ── Test 1: _workmux_pane_status reads workmux state JSON ──────────────────
echo "T1: _workmux_pane_status"
write_state %101 working
write_state %102 done
write_state %103 waiting
[ "$(_workmux_pane_status %101)" = "working" ] && pass "reads 'working'" || fail "%101 → '$(_workmux_pane_status %101)' (want working)"
[ "$(_workmux_pane_status %102)" = "done" ]    && pass "reads 'done'"    || fail "%102 → '$(_workmux_pane_status %102)' (want done)"
[ "$(_workmux_pane_status %103)" = "waiting" ] && pass "reads 'waiting'" || fail "%103 → '$(_workmux_pane_status %103)' (want waiting)"
[ -z "$(_workmux_pane_status %99999)" ]        && pass "unknown pane → empty" || fail "%99999 → '$(_workmux_pane_status %99999)' (want empty)"

# ── Test 2: _retile_with_teammates (bar present) ───────────────────────────
echo "T2: _retile_with_teammates (with command bar)"
tmux -f /dev/null new-session -d -s g -x 200 -y 60
tmux split-window -d -t g:0 -h
tmux split-window -d -t g:0 -h
for i in 0 1 2; do
  tmux set-option -p -t "g:0.$i" @worktree "agent$i"
  tmux set-option -p -t "g:0.$i" @pane_label "agent$i"
done
bar=$(tmux split-window -d -f -v -l 6 -t g:0 -P -F '#{pane_id}')
tmux set-option -p -t "$bar" @cockpit_bar 1
tmux set-option -p -t "$bar" @pane_label "BAR_KEYS"
_style_window g:0
before=$(tmux list-panes -t g:0 -F x | grep -c .)
[ "$before" = 4 ] && pass "grid assembled: 4 panes (3 agents + bar)" || fail "expected 4 panes, got $before"

# Teammate mode spawn: two new panes off agent0
tmux split-window -d -t g:0.0
tmux split-window -d -t g:0.0
after=$(tmux list-panes -t g:0 -F x | grep -c .)
[ "$after" = 6 ] && pass "after spawn: 6 panes" || fail "expected 6, got $after"

_retile_with_teammates g:0
sleep 0.3

read -r bw bh < <(tmux list-panes -t g:0 -F '#{pane_width} #{pane_height}' -f '#{@cockpit_bar}')
[ "$bw" = 200 ] && [ "$bh" = 6 ] && pass "bar preserved 200x6 full-width" || fail "bar is ${bw}x${bh} (want 200x6)"

tn=$(tmux list-panes -t g:0 -F '#{@pane_label}' -f '#{==:#{@pane_label},teammate}' | grep -c .)
[ "$tn" = 2 ] && pass "2 teammates labeled" || fail "expected 2 teammates, got $tn"

an=$(tmux list-panes -t g:0 -F '#{@pane_label}' -f '#{m:agent*,#{@pane_label}}' | grep -c .)
[ "$an" = 3 ] && pass "3 original agents still labeled" || fail "expected 3 agents, got $an"

# No zero-size panes (everything visible, no overflow)
zn=$(tmux list-panes -t g:0 -F '#{pane_width} #{pane_height}' | awk '$1==0||$2==0{n++} END{print n+0}')
[ "$zn" = 0 ] && pass "no zero-size panes" || fail "$zn panes are zero-size (overflow)"

# ── Test 3: bar-less window (kept session) — no break/join path ────────────
echo "T3: _retile_with_teammates (no bar — kept session)"
tmux new-window -d -t g -n kept
tmux split-window -d -t g:kept -h
tmux set-option -p -t g:kept.0 @worktree keep1; tmux set-option -p -t g:kept.0 @pane_label keep1
tmux set-option -p -t g:kept.1 @worktree keep2; tmux set-option -p -t g:kept.1 @pane_label keep2
tmux split-window -d -t g:kept.0   # teammate spawns in a kept window
_retile_with_teammates g:kept
sleep 0.2
kt=$(tmux list-panes -t g:kept -F '#{@pane_label}' -f '#{==:#{@pane_label},teammate}' | grep -c .)
[ "$kt" = 1 ] && pass "no-bar window: teammate still labeled" || fail "expected 1 teammate, got $kt"
kn=$(tmux list-panes -t g:kept -F x | grep -c .)
[ "$kn" = 3 ] && pass "no-bar window: 3 panes visible" || fail "expected 3 panes, got $kn"

# ── Summary ────────────────────────────────────────────────────────────────
echo
echo "results: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
