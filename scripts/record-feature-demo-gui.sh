#!/usr/bin/env bash
# Record a real macOS GUI screencast of the deterministic wtcp demo.
#
# This opens Terminal.app, attaches it to a tmux session, drives the same fake
# agent + mock judge flow as the renderer demo, and records the actual display
# with macOS screencapture. The first run may require Screen Recording and
# Automation permissions for the app that launches this script.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WTCP="$ROOT/wtcp"
OUT_DIR="${1:-$ROOT/demo-recordings}"
DURATION="${WTCP_GUI_DEMO_DURATION:-55}"
DISPLAY_ID="${WTCP_GUI_DEMO_DISPLAY:-1}"
# Match the Terminal bounds set in support/open-terminal-demo.applescript:
# {80, 60, 1540, 940} -> x,y,width,height.
CAPTURE_RECT="${WTCP_GUI_DEMO_RECT:-80,60,1460,880}"
SESSION="wtcp-gui-demo-$$"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wtcp-gui-demo.XXXXXX")"
DEMO_HOME="$TMP/home"
WTCP_CONFIG="$TMP/wtcp.config"
DEMO_REPO="$TMP/demo-repo"
MOCK_PORT_FILE="$TMP/mock-judge.port"
mkdir -p "$OUT_DIR" "$DEMO_HOME/.config/workmux" "$DEMO_HOME/.config/wtcp"

MOCK_PID=""
OUTPUT="$OUT_DIR/wtcp-feature-demo-gui-$(date +%Y%m%d-%H%M%S).mov"

cleanup(){
  set +e
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  tmux kill-session -t "$SESSION" 2>/dev/null
  for _ in 1 2 3; do
    rm -rf "$TMP" 2>/dev/null && break
    sleep 0.5
  done
}
trap cleanup EXIT

require(){
  command -v "$1" >/dev/null 2>&1 || {
    echo "missing required command: $1" >&2
    exit 1
  }
}

require tmux
require workmux
require git
require jq
require curl
require python3
require osascript
require screencapture
[ -x "$WTCP" ] || { echo "wtcp script not found or not executable: $WTCP" >&2; exit 1; }

permission_probe="$TMP/permission-probe.png"
set +e
screencapture -x -D "$DISPLAY_ID" "$permission_probe" >/dev/null 2>&1 &
PROBE_PID=$!
PROBE_DONE=0
for _ in $(seq 1 30); do
  if ! kill -0 "$PROBE_PID" 2>/dev/null; then
    PROBE_DONE=1
    break
  fi
  sleep 0.1
done
if [ "$PROBE_DONE" -eq 0 ]; then
  kill "$PROBE_PID" 2>/dev/null
  wait "$PROBE_PID" 2>/dev/null
  PROBE_RC=124
else
  wait "$PROBE_PID"
  PROBE_RC=$?
fi
set -e
if [ "$PROBE_RC" -ne 0 ] || [ ! -s "$permission_probe" ]; then
  cat >&2 <<EOF
macOS screen capture is not available to this process.

Grant Screen Recording permission to the app launching this script, then retry:
  System Settings -> Privacy & Security -> Screen & System Audio Recording

If you run this from Terminal.app, grant Terminal. If you run it from Codex or
another terminal host, grant that app. You may need to quit and reopen the app.
EOF
  exit 2
fi
rm -f "$permission_probe"

cat > "$TMP/fake-agent.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
kind="${1:-good}"
shift || true
prompt="$*"
git config user.name "wtcp demo"
git config user.email "wtcp-demo@example.invalid"
printf '[%s] received task: %s\n' "$kind" "$prompt"
sleep 1
if [ "$kind" = "good" ]; then
  cat > calculator.py <<'PY'
def add(a, b):
    return a + b
PY
  cat > test_calculator.py <<'PY'
from calculator import add

assert add(2, 3) == 5
assert add(-2, 5) == 3
PY
  python3 test_calculator.py
  git add -A
  git commit -qm "Implement correct add with tests"
  printf '[good] implemented add(a, b) and added smoke tests\n'
else
  cat > calculator.py <<'PY'
def add(a, b):
    return a - b
PY
  git add -A
  git commit -qm "Attempt add implementation"
  printf '[bad] changed add(a, b), but did not run tests\n'
fi
printf '[%s] waiting for follow-up instructions...\n' "$kind"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  printf '[%s] follow-up: %s\n' "$kind" "$line"
  if [ "$kind" = "good" ]; then
    python3 test_calculator.py && printf '[good] tests still pass\n'
  else
    printf '[bad] no test evidence available\n'
  fi
done
SH
chmod +x "$TMP/fake-agent.sh"

cat > "$DEMO_HOME/.config/workmux/config.yaml" <<EOF
nerdfont: false
agents:
  fgood: "$TMP/fake-agent.sh good"
  fbad: "$TMP/fake-agent.sh bad"
EOF

python3 - "$MOCK_PORT_FILE" <<'PY' &
import http.server
import json
import re
import socketserver
import sys

port_file = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", "0"))
        payload = self.rfile.read(length).decode("utf-8", "replace")
        try:
            body = json.loads(payload)
            content = "\n".join(m.get("content", "") for m in body.get("messages", []))
        except Exception:
            content = payload
        names = re.findall(r"=== AGENT: ([^\n=]+) ===", content) or ["demo-add-fgood", "demo-add-fbad"]
        def score_for(name):
            return 9 if "fgood" in name else 3
        rankings = []
        for name in sorted(names, key=score_for, reverse=True):
            reason = "correct implementation, committed tests, and passing follow-up evidence" if "fgood" in name else "incorrect subtraction behavior and no test evidence"
            rankings.append({"name": name, "score": score_for(name), "reason": reason})
        response = {
            "model": "mock-wtcp-demo-judge",
            "choices": [{"message": {"content": json.dumps({
                "rankings": rankings,
                "winner": rankings[0]["name"],
                "summary": "fgood wins because it fixes the behavior, adds tests, and reruns them after the follow-up",
            })}}],
        }
        data = json.dumps(response).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def log_message(self, fmt, *args):
        return

with socketserver.TCPServer(("127.0.0.1", 0), Handler) as httpd:
    with open(port_file, "w", encoding="utf-8") as f:
        f.write(str(httpd.server_address[1]))
    httpd.serve_forever()
PY
MOCK_PID=$!
for _ in $(seq 1 50); do
  [ -s "$MOCK_PORT_FILE" ] && break
  sleep 0.1
done
[ -s "$MOCK_PORT_FILE" ] || { echo "mock judge did not start" >&2; exit 1; }
MOCK_PORT="$(cat "$MOCK_PORT_FILE")"

cat > "$WTCP_CONFIG" <<EOF
COCKPIT_AGENTS="fgood fbad"
COCKPIT_JUDGE_URL="http://127.0.0.1:$MOCK_PORT/v1/chat/completions"
COCKPIT_JUDGE_MODEL="mock-wtcp-demo-judge"
COCKPIT_NAMER="off"
COCKPIT_TRUST=0
COCKPIT_LAUNCH_TIMEOUT=30
COCKPIT_SEND_DELAY=0.2
COCKPIT_POPUP_WIDTH="92%"
COCKPIT_POPUP_HEIGHT="85%"
COCKPIT_NO_INTERACTIVE_MENUS=1
EOF

mkdir -p "$DEMO_REPO"
git -C "$DEMO_REPO" init -q -b main
git -C "$DEMO_REPO" config user.name "wtcp demo"
git -C "$DEMO_REPO" config user.email "wtcp-demo@example.invalid"
cat > "$DEMO_REPO/README.md" <<'EOF'
# Calculator Demo

The agents will implement `add(a, b)` and add evidence.
EOF
git -C "$DEMO_REPO" add README.md
git -C "$DEMO_REPO" commit -qm "Initial demo repo"

tmux new-session -d -s "$SESSION" -x 132 -y 40 -c "$DEMO_REPO" "env HOME='$DEMO_HOME' WTCP_CONFIG='$WTCP_CONFIG' GIT_PAGER=cat PATH='$ROOT':\$PATH /bin/zsh"
tmux set-environment -t "$SESSION" HOME "$DEMO_HOME"
tmux set-environment -t "$SESSION" WTCP_CONFIG "$WTCP_CONFIG"
tmux set-environment -t "$SESSION" GIT_PAGER cat
tmux set-environment -t "$SESSION" PATH "$ROOT:$PATH"

osascript "$ROOT/scripts/support/open-terminal-demo.applescript" "$DEMO_REPO" "$SESSION" >/dev/null
sleep 2

target(){ printf '%s:' "$SESSION"; }
command_target(){
  local bar
  bar=$(tmux list-panes -t "$(target)" -F '#{pane_id} #{@cockpit_bar}' 2>/dev/null | awk '$2 == "1" {print $1; exit}')
  [ -n "$bar" ] && printf '%s' "$bar" || target
}
send_line(){
  local line="$1" dest
  dest=$(command_target)
  tmux send-keys -t "$dest" -l -- "$line"
  tmux send-keys -t "$dest" Enter
}
close_popup(){
  local client
  client=$(tmux list-clients -t "$SESSION" -F '#{client_tty}' 2>/dev/null | head -1)
  [ -n "$client" ] && tmux display-popup -C -c "$client" 2>/dev/null || true
}
wait_for(){
  local needle="$1" timeout="${2:-30}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      tmux capture-pane -p -S - -t "$pane" 2>/dev/null | grep -Fq "$needle" && return 0
    done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | awk -F: -v s="$SESSION" '$1 == s')
    sleep 0.5
  done
  echo "timed out waiting for: $needle" >&2
  return 1
}
wait_for_label(){
  local needle="$1" timeout="${2:-30}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if tmux list-panes -t "$(target)" -F '#{@pane_label}' 2>/dev/null | grep -Fq "$needle"; then
      return 0
    fi
    sleep 0.5
  done
  echo "timed out waiting for pane label: $needle" >&2
  return 1
}

capture_args=(-v -V "$DURATION" -D "$DISPLAY_ID" -k)
[ -n "$CAPTURE_RECT" ] && capture_args+=("-R$CAPTURE_RECT")
screencapture "${capture_args[@]}" "$OUTPUT" &
REC_PID=$!

sleep 2
send_line "clear"
sleep 1
send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' doctor"
wait_for "deps" 20
sleep 2
send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' agents fgood fbad"
wait_for "compare set" 15
sleep 1
send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' start \"fix add function and add tests\" demo-add"
wait_for "grid ready" 40
sleep 3
send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' send \"run the tests and summarize risks\""
sleep 3
send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' score"
wait_for_label "★ 9" 30
sleep 5
close_popup
sleep 1
send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' pick demo-add-fgood"
sleep 5
tmux select-window -t "$SESSION:0" 2>/dev/null || true
send_line "git --no-pager log --oneline -3 && git status --short"
sleep 3

wait "$REC_PID" || {
  echo "screen recording failed; check Screen Recording permission" >&2
  exit 1
}

echo "$OUTPUT"
