#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
BIN_PATH="${1:-$ROOT_DIR/zig-out/bin/vx}"
ARTIFACT_DIR="${2:-$ROOT_DIR/.tmp/tui-result-posix}"
EXPECTED_FILE="$ROOT_DIR/scripts/ci/tui/expected_final.txt"
WORK_DIR="$(mktemp -d)"
TARGET_FILE="$WORK_DIR/scenario.txt"
SESSION="vx-ci-$RANDOM"
PANE="$SESSION:0.0"

cleanup() {
  tmux kill-session -t "$SESSION" >/dev/null 2>&1 || true
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

if ! command -v tmux >/dev/null 2>&1; then
  echo "tmux is required for POSIX validation" >&2
  exit 1
fi

if [[ ! -x "$BIN_PATH" ]]; then
  echo "vx binary not found or not executable: $BIN_PATH" >&2
  exit 1
fi

cat >"$TARGET_FILE" <<'EOF'
alpha
beta
gamma
EOF

send() {
  tmux send-keys -t "$PANE" "$@"
  sleep 0.2
}

tmux new-session -d -s "$SESSION" "TERM=xterm-256color \"$BIN_PATH\" \"$TARGET_FILE\""
sleep 1

# Scenario coverage: movement, insert, yank/paste, undo/redo, search, delete, save+quit.
send g g
send i HEAD-
send C-\[
send j
send y
send p
send u
send U
send / gamma C-m
send x
send u
send : w q C-m

for _ in $(seq 1 120); do
  if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    break
  fi
  sleep 0.1
done

if tmux has-session -t "$SESSION" 2>/dev/null; then
  echo "Timed out waiting for vx to exit in tmux session $SESSION" >&2
  exit 1
fi

mkdir -p "$ARTIFACT_DIR"
cp "$TARGET_FILE" "$ARTIFACT_DIR/final.txt"

if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$ARTIFACT_DIR/final.txt" >"$ARTIFACT_DIR/final.sha256"
else
  shasum -a 256 "$ARTIFACT_DIR/final.txt" >"$ARTIFACT_DIR/final.sha256"
fi

python3 - "$EXPECTED_FILE" "$ARTIFACT_DIR/final.txt" <<'PY'
import pathlib, sys
expected = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").replace("\r\n", "\n")
actual = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").replace("\r\n", "\n")
if actual != expected:
    print("Scenario output mismatch", file=sys.stderr)
    print("=== expected ===", file=sys.stderr)
    print(expected, file=sys.stderr)
    print("=== actual ===", file=sys.stderr)
    print(actual, file=sys.stderr)
    raise SystemExit(1)
PY

echo "tmux validation passed: $ARTIFACT_DIR/final.txt"
