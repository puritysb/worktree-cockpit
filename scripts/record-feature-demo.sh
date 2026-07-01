#!/usr/bin/env bash
# Record a deterministic wtcp feature demo without real agent logins.
#
# The script uses real tmux + workmux + git operations, but replaces the agent
# commands with temporary fake agents and the judge with a local mock
# OpenAI-compatible endpoint. It renders captured tmux pane output into an mp4.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WTCP="$ROOT/wtcp"
OUT_DIR="${1:-$ROOT/demo-recordings}"
WIDTH="${WTCP_DEMO_WIDTH:-1600}"
HEIGHT="${WTCP_DEMO_HEIGHT:-900}"
POINTSIZE="${WTCP_DEMO_POINTSIZE:-19}"
FONT="${WTCP_DEMO_FONT:-/System/Library/Fonts/Menlo.ttc}"
SESSION="wtcp-demo-$$"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wtcp-feature-demo.XXXXXX")"
DEMO_HOME="$TMP/home"
WORKMUX_CONFIG="$DEMO_HOME/.config/workmux/config.yaml"
WORKMUX_BACKUP=""
WTCP_CONFIG="$TMP/wtcp.config"
DEMO_REPO="$TMP/demo-repo"
MOCK_PORT_FILE="$TMP/mock-judge.port"
FRAME_DIR="$TMP/frames"
TEXT_DIR="$TMP/text"
PANE_DIR="$TMP/panes"
mkdir -p "$OUT_DIR" "$FRAME_DIR" "$TEXT_DIR" "$PANE_DIR"

MOCK_PID=""
FRAME=0

cleanup(){
  set +e
  if [ "${WTCP_DEMO_KEEP:-0}" = "1" ]; then
    echo "keeping demo session $SESSION and temp dir $TMP" >&2
    return
  fi
  [ -n "$MOCK_PID" ] && kill "$MOCK_PID" 2>/dev/null
  tmux kill-session -t "$SESSION" 2>/dev/null
  if [ -n "$WORKMUX_BACKUP" ] && [ -f "$WORKMUX_BACKUP" ]; then
    mkdir -p "$(dirname "$WORKMUX_CONFIG")"
    cp "$WORKMUX_BACKUP" "$WORKMUX_CONFIG"
  fi
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
require ffmpeg
if ! command -v magick >/dev/null 2>&1 && ! command -v convert >/dev/null 2>&1; then
  echo "missing required command: magick or convert" >&2
  exit 1
fi
[ -x "$WTCP" ] || { echo "wtcp script not found or not executable: $WTCP" >&2; exit 1; }
[ -f "$FONT" ] || { echo "font not found: $FONT" >&2; exit 1; }

mkdir -p "$(dirname "$WORKMUX_CONFIG")" "$DEMO_HOME/.config/wtcp"

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

cat > "$WORKMUX_CONFIG" <<EOF
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
        names = re.findall(r"=== AGENT: ([^\n=]+) ===", content)
        if not names:
            names = ["demo-add-fgood", "demo-add-fbad"]
        def score_for(name):
            return 9 if "fgood" in name else 3
        rankings = []
        for name in sorted(names, key=score_for, reverse=True):
            if "fgood" in name:
                reason = "correct implementation, committed tests, and passing follow-up evidence"
            else:
                reason = "incorrect subtraction behavior and no test evidence"
            rankings.append({"name": name, "score": score_for(name), "reason": reason})
        winner = rankings[0]["name"]
        result = {
            "rankings": rankings,
            "winner": winner,
            "summary": "fgood wins because it fixes the behavior, adds tests, and reruns them after the follow-up",
        }
        response = {
            "model": "mock-wtcp-demo-judge",
            "choices": [{"message": {"content": json.dumps(result)}}],
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

tmux new-session -d -s "$SESSION" -x 132 -y 40 -c "$DEMO_REPO" "env HOME='$DEMO_HOME' WTCP_CONFIG='$WTCP_CONFIG' PATH='$ROOT':\$PATH /bin/zsh"
tmux set-environment -t "$SESSION" HOME "$DEMO_HOME"
tmux set-environment -t "$SESSION" WTCP_CONFIG "$WTCP_CONFIG"
tmux set-environment -t "$SESSION" PATH "$ROOT:$PATH"
tmux set-environment -t "$SESSION" GIT_PAGER cat

target(){
  printf '%s:' "$SESSION"
}

command_target(){
  local bar
  bar=$(tmux list-panes -t "$(target)" -F '#{pane_id} #{@cockpit_bar}' 2>/dev/null | awk '$2 == "1" {print $1; exit}')
  if [ -n "$bar" ]; then
    printf '%s' "$bar"
  else
    target
  fi
}

send_line(){
  local line="$1" dest
  dest=$(command_target)
  tmux send-keys -t "$dest" -l -- "$line"
  tmux send-keys -t "$dest" Enter
}

wait_for(){
  local needle="$1" timeout="${2:-30}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    while IFS= read -r pane; do
      [ -n "$pane" ] || continue
      if tmux capture-pane -p -S - -t "$pane" 2>/dev/null | grep -Fq "$needle"; then
        return 0
      fi
    done < <(tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null | awk -F: -v s="$SESSION" '$1 == s')
    sleep 0.5
  done
  echo "timed out waiting for: $needle" >&2
  return 1
}

wait_for_file(){
  local file="$1" needle="$2" timeout="${3:-30}" deadline
  deadline=$(( $(date +%s) + timeout ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    if [ -s "$file" ] && grep -Fq "$needle" "$file"; then
      return 0
    fi
    sleep 0.5
  done
  echo "timed out waiting for $needle in $file" >&2
  return 1
}

active_panes_meta(){
  tmux list-panes -t "$(target)" -F '#{pane_id}	#{@worktree}	#{@pane_label}	#{@cockpit_bar}'
}

compose_text(){
  local outfile="$1" title="$2"
  local meta="$TMP/panes.meta"
  active_panes_meta > "$meta"
  while IFS=$'\t' read -r pane _wt _label _bar; do
    [ -n "$pane" ] || continue
    tmux capture-pane -p -J -S -80 -t "$pane" > "$PANE_DIR/${pane#%}.txt" 2>/dev/null || true
  done < "$meta"
  python3 - "$meta" "$PANE_DIR" "$outfile" "$title" <<'PY'
import os
import sys

meta_path, pane_dir, out_path, title = sys.argv[1:5]
cols = 96
left_width = 47
right_width = 47
body_lines = 24

def clean(s):
    return "".join(ch if ch == "\t" or ch >= " " else "" for ch in s).replace("\t", "    ")

def fit(s, width):
    s = clean(s)
    return s[:width].ljust(width)

panes = []
with open(meta_path, encoding="utf-8", errors="replace") as f:
    for raw in f:
        raw = raw.rstrip("\n")
        if not raw:
            continue
        parts = raw.split("\t")
        while len(parts) < 4:
            parts.append("")
        pane, wt, label, bar = parts[:4]
        path = os.path.join(pane_dir, pane.lstrip("%") + ".txt")
        try:
            with open(path, encoding="utf-8", errors="replace") as pf:
                lines = [clean(line.rstrip("\n")) for line in pf.readlines()]
        except FileNotFoundError:
            lines = []
        panes.append({"pane": pane, "wt": wt, "label": label, "bar": bar, "lines": lines})

agents = [p for p in panes if p["wt"]]
bars = [p for p in panes if p["bar"] == "1"]
out = []
out.append(title)
out.append("=" * min(len(title), cols))
out.append("")

if len(agents) >= 2:
    a, b = agents[:2]
    out.append("+" + "-" * left_width + "+" + "-" * right_width + "+")
    out.append("|" + fit(a["label"] or a["wt"], left_width) + "|" + fit(b["label"] or b["wt"], right_width) + "|")
    out.append("+" + "-" * left_width + "+" + "-" * right_width + "+")
    alines = a["lines"][-body_lines:]
    blines = b["lines"][-body_lines:]
    for i in range(body_lines):
        out.append("|" + fit(alines[i] if i < len(alines) else "", left_width) + "|" + fit(blines[i] if i < len(blines) else "", right_width) + "|")
    out.append("+" + "-" * left_width + "+" + "-" * right_width + "+")
    if bars:
        bar = bars[0]
        out.append("")
        out.append("COMMAND BAR")
        out.append("-" * 96)
        for line in bar["lines"][-6:]:
            out.append(fit(line, 96))
else:
    pane = panes[0] if panes else {"label": "terminal", "lines": []}
    out.append("+" + "-" * 96 + "+")
    out.append("|" + fit(pane.get("label") or "terminal", 96) + "|")
    out.append("+" + "-" * 96 + "+")
    for line in pane.get("lines", [])[-31:]:
        out.append("|" + fit(line, 96) + "|")
    out.append("+" + "-" * 96 + "+")

with open(out_path, "w", encoding="utf-8") as f:
    f.write("\n".join(out) + "\n")
PY
}

render_frame(){
  local title="$1" hold="${2:-1}" text_file png_file
  FRAME=$((FRAME + 1))
  text_file="$TEXT_DIR/frame_$(printf '%04d' "$FRAME").txt"
  png_file="$FRAME_DIR/frame_$(printf '%04d' "$FRAME").png"
  compose_text "$text_file" "$title"
  if command -v magick >/dev/null 2>&1; then
    magick -background '#101418' -fill '#dce3ea' -font "$FONT" -pointsize "$POINTSIZE" -size "${WIDTH}x${HEIGHT}" "caption:@$text_file" "$png_file"
  else
    convert -background '#101418' -fill '#dce3ea' -font "$FONT" -pointsize "$POINTSIZE" -size "${WIDTH}x${HEIGHT}" "caption:@$text_file" "$png_file"
  fi
  local i
  for i in $(seq 2 "$hold"); do
    FRAME=$((FRAME + 1))
    cp "$png_file" "$FRAME_DIR/frame_$(printf '%04d' "$FRAME").png"
  done
}

send_line "clear"
render_frame "Worktree Cockpit: one prompt, multiple agents" 2

send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' doctor"
wait_for "deps" 20
render_frame "1. Doctor checks the terminal environment" 3

send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' agents fgood fbad"
wait_for "compare set" 15
render_frame "2. Pick the agents to compare" 2

send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' start \"fix add function and add tests\" demo-add"
wait_for "grid ready" 40
sleep 1
render_frame "3. wtcp starts isolated worktrees and builds the grid" 4

send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' send \"run the tests and summarize risks\""
sleep 2
render_frame "4. Send one follow-up to every agent" 4

send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' score"
wait_for_file "$DEMO_HOME/.config/wtcp/judge.txt" "Winner:" 30
sleep 1
render_frame "5. Judge ranks the agents and stamps pane scores" 4

send_line "WTCP_CONFIG='$WTCP_CONFIG' '$WTCP' pick demo-add-fgood"
sleep 5
render_frame "6. Pick the winner, merge, and clean up losers" 3

tmux select-window -t "$SESSION:0" 2>/dev/null || true
send_line "git --no-pager log --oneline -3 && git status --short"
sleep 2
render_frame "7. Winner is merged back into the base repo" 3

OUTPUT="$OUT_DIR/wtcp-feature-demo-$(date +%Y%m%d-%H%M%S).mp4"
ffmpeg -y -framerate 1 -i "$FRAME_DIR/frame_%04d.png" -r 30 -pix_fmt yuv420p "$OUTPUT" >/dev/null 2>&1

echo "$OUTPUT"
