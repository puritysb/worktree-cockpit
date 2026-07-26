#!/usr/bin/env bash
# Regression tests for editable popup prompts used by send-all and fork.
#
# Run: bash tests/test_prompt_input.sh

set -uo pipefail
WTCOP="$(cd "$(dirname "$0")/.." && pwd)/wtcp"
PASS=0; FAIL=0
fail(){ echo "  FAIL: $*"; FAIL=$((FAIL+1)); }
pass(){ echo "  PASS: $*"; PASS=$((PASS+1)); }
is(){ # $1=label $2=got $3=want
  [ "$2" = "$3" ] && pass "$1" || fail "$1 (got '$2', want '$3')"
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
extract_fn(){
  awk -v fn="$1" '
    $0 ~ "^"fn"\\(\\)" { print; in_fn=1; next }
    in_fn && /^}$/ { print; exit }
    in_fn { print }
  ' "$WTCOP"
}

{
  for f in _read_editable_line cmd_prompt_send; do extract_fn "$f"; done
} > "$TMP/functions.sh"
# shellcheck disable=SC1090
. "$TMP/functions.sh" || exit 2

need_tmux(){ :; }
tmux(){ :; }
_cur_win(){ printf '@1'; }
PROMPT_LOG=""; SENT=""
_prompt_log_append(){ PROMPT_LOG="$1|$2|$3"; }
_send_to_window(){ SENT="$1|$2"; }

echo "T1: headless input preserves text"
printf '한글 cursor edit text\n' > "$TMP/input"
got=$(_read_editable_line ignored < "$TMP/input")
is "UTF-8 text preserved byte-for-byte" "$got" "한글 cursor edit text"

echo "T2: send prompt behavior"
PROMPT_LOG=""; SENT=""
cmd_prompt_send @7 < "$TMP/input"
is "follow-up log receives exact text" "$PROMPT_LOG" "@7|follow-up|한글 cursor edit text"
is "send receives exact text" "$SENT" "@7|한글 cursor edit text"

PROMPT_LOG=""; SENT=""
: > "$TMP/input"
cmd_prompt_send @7 < "$TMP/input"
is "EOF cancels without logging" "$PROMPT_LOG" ""
is "EOF cancels without sending" "$SENT" ""

PROMPT_LOG=""; SENT=""
printf '\n' > "$TMP/input"
cmd_prompt_send @7 < "$TMP/input"
is "empty Enter cancels without logging" "$PROMPT_LOG" ""
is "empty Enter cancels without sending" "$SENT" ""

echo "T3: interactive editor and exit affordance"
if grep -Fq 'read -e -r -p "$prompt"' "$WTCOP"; then
  pass "TTY input uses Readline editing"
else
  fail "TTY input uses Readline editing"
fi
if grep -Fq 'Ctrl-C: cancel' "$WTCOP"; then
  pass "popup tells the user how to exit"
else
  fail "popup tells the user how to exit"
fi
if grep -Fq "cmd_prompt_fork" "$WTCOP" \
  && grep -Fq "_read_editable_line 'fork prompt" "$WTCOP"; then
  pass "fork popup uses the same safe editor"
else
  fail "fork popup uses the same safe editor"
fi

echo
echo "results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
