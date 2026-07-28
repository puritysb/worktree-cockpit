#!/usr/bin/env bash
# tests/test_judge_mode.sh — the independent fallback must not pick a winner.
#
# Independent scores are produced one candidate at a time with no peer to
# calibrate against. Measured on a real round, that mode gave the WEAKEST agent
# 9/10 alone and 3/10 in comparison, so letting the top ★ stand in for "the
# judge's winner" turns a failed judgment into a confident wrong merge.
#
# Runs against a scratch tmux socket. Every client uses LC_ALL=C.utf8 because
# tmux mangles non-ASCII option values on read under a non-UTF-8 locale
# (gotcha 14), which would make ★/🏆 parsing silently fail here.
#
# Run: bash tests/test_judge_mode.sh

set -uo pipefail
WTCOP="$(cd "$(dirname "$0")/.." && pwd)/wtcp"
TEST_SOCKET="wtcp_mode_$$"
PASS=0; FAIL=0
fail(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
pass(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
is(){ [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"; }

TMP="$(mktemp -d)"
trap 'command tmux -L "$TEST_SOCKET" kill-server 2>/dev/null; rm -rf "$TMP"' EXIT
# tmux mangles non-ASCII option values on READ under a non-UTF-8 locale
# (gotcha 14), which would make the ★/🏆 parsing here fail silently. C.utf8 does
# not exist on macOS, so take whichever UTF-8 locale this machine actually has.
for loc in C.utf8 C.UTF-8 en_US.UTF-8; do
  if locale -a 2>/dev/null | grep -qxF "$loc"; then export LC_ALL="$loc"; break; fi
done
tmux(){ command tmux -L "$TEST_SOCKET" "$@"; }

extract_fn(){
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)" { print; in_fn=1; next }
    in_fn && /^}$/ { print; exit }
    in_fn { print }
  ' "$WTCOP"
}
{
  echo 'pane_wt(){ tmux show-options -pqv -t "$1" @worktree 2>/dev/null || true; }'
  for f in _scored_rows _scored_winner; do extract_fn "$f"; done
} > "$TMP/functions.sh"
# shellcheck disable=SC1090
. "$TMP/functions.sh" || { echo "could not extract functions from wtcp"; exit 2; }

tmux -f /dev/null new-session -d -s s -x 200 -y 50
grid=$(tmux new-window -d -P -F '#{window_id}' -n "wt:round")
p1=$(tmux list-panes -t "$grid" -F '#{pane_id}' | head -1)
p2=$(tmux split-window -d -t "$p1" -P -F '#{pane_id}')
p3=$(tmux split-window -d -t "$p1" -P -F '#{pane_id}')
tmux set-option -p -t "$p1" @worktree "round-weak"
tmux set-option -p -t "$p2" @worktree "round-strong"
tmux set-option -p -t "$p3" @worktree "round-middle"

echo "T1: comparative scoring still resolves a winner"
tmux set-option -w -t "$grid" @cockpit_judge_mode comparative
tmux set-option -p -t "$p1" @pane_label "round-weak   ★ 9"
tmux set-option -p -t "$p2" @pane_label "round-strong   ★ 8"
tmux set-option -p -t "$p3" @pane_label "round-middle   ★ 7"
is "the top numeric score wins a comparative round" "$(_scored_winner "$grid")" "round-weak"
tmux set-option -p -t "$p2" @pane_label "round-strong   ★ 8 🏆"
is "an explicit trophy outranks the numbers" "$(_scored_winner "$grid")" "round-strong"
tmux set-option -p -t "$p2" @pane_label "round-strong   ★ 8"

echo "T2: the independent fallback refuses to name a winner"
tmux set-option -w -t "$grid" @cockpit_judge_mode independent
is "no winner is invented from independent scores" "$(_scored_winner "$grid")" ""
is "the ranking is still readable as feedback" \
  "$(_scored_rows "$grid" | head -1 | cut -f2)" "round-weak"
# A trophy can only come from a comparative response, so it still counts.
tmux set-option -p -t "$p2" @pane_label "round-strong   ★ 8 🏆"
is "a trophy still resolves even in fallback mode" "$(_scored_winner "$grid")" "round-strong"
tmux set-option -p -t "$p2" @pane_label "round-strong   ★ 8"

echo "T3: an unscored round is still simply unscored"
tmux set-option -w -t "$grid" @cockpit_judge_mode ""
tmux set-option -p -t "$p1" @pane_label "round-weak   ★ ?"
tmux set-option -p -t "$p2" @pane_label "round-strong   ★ ?"
tmux set-option -p -t "$p3" @pane_label "round-middle   ★ ?"
is "nothing scored means no winner" "$(_scored_winner "$grid")" ""

echo "T4: the refusal is wired through the commands and the report"
SRC=$(<"$WTCOP")
case "$SRC" in
  *'@cockpit_judge_mode comparative'*) pass "a comparative round records its mode" ;;
  *) fail "a comparative round records its mode" ;;
esac
case "$SRC" in
  *'@cockpit_judge_mode independent'*) pass "the fallback records its mode" ;;
  *) fail "the fallback records its mode" ;;
esac
case "$SRC" in
  *'independent fallback scores are not comparable'*) pass "merge explains the refusal" ;;
  *) fail "merge explains the refusal" ;;
esac
case "$SRC" in
  *'MANUAL pick (independent scores are not comparable)'*) pass "the manual menu drops the judge's authority" ;;
  *) fail "the manual menu drops the judge's authority" ;;
esac
case "$SRC" in
  *'These scores are NOT comparable across candidates'*) pass "the report says so too" ;;
  *) fail "the report says so too" ;;
esac
# The fallback must not auto-open a ranked pick list.
if printf '%s' "$SRC" | grep -A4 '_score_independent "$cwin"' | grep -q '_winner_menu'; then
  fail "the fallback no longer offers an automatic ranked pick"
else
  pass "the fallback no longer offers an automatic ranked pick"
fi

echo
echo "results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
