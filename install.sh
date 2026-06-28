#!/usr/bin/env bash
# Install wtcp: symlink the script onto your PATH and (on macOS) build the
# optional Apple Intelligence helper used for branch naming.
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"

# Pick a PATH dir to symlink into (first existing one on PATH, else ~/.local/bin).
BIN=""
for d in "$HOME/.local/bin" "$HOME/bin" /usr/local/bin; do
  case ":$PATH:" in *":$d:"*) BIN="$d"; break;; esac
done
BIN="${BIN:-$HOME/.local/bin}"; mkdir -p "$BIN"
ln -sf "$DIR/wtcp" "$BIN/wtcp"
echo "wtcp -> $BIN/wtcp"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "  note: $BIN is not on PATH — add it to your shell rc";; esac

# Optional: build the on-device naming helper (macOS + Xcode toolchain).
if [ "$(uname)" = Darwin ] && command -v node >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1; then
  node "$DIR/scripts/build-fm-helper.mjs" || echo "wtcp: FM helper build skipped (naming falls back to MLX/ASCII)"
fi

# Warn about missing required external tools.
miss=""
for t in tmux workmux git jq curl; do command -v "$t" >/dev/null 2>&1 || miss="$miss $t"; done
[ -n "$miss" ] && echo "wtcp: missing required tools:$miss — install them before use" || true

echo "Done.  Try:  wtcp agents   ·   wtcp start \"add a README\"  (inside a git repo, inside tmux)"
