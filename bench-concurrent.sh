#!/usr/bin/env bash
# Fires 3 requests SIMULTANEOUSLY (not sequentially like bench.sh) to test whether
# max_batch_size actually holds up under real concurrent load, VRAM-wise.
# Watch `nvidia-smi` in another terminal WHILE this runs — that's the number that matters.

set -euo pipefail

API_URL="http://localhost:5000/v1/chat/completions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_KEY="$(grep -oP '^api_key:\s*\K\S+' "$SCRIPT_DIR/api_tokens.yml")"
MODEL="$(curl -sf "${API_URL%/chat/completions}/model" -H "Authorization: Bearer $API_KEY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"  # whatever is loaded
MAX_TOKENS=300

PROMPT='Write a Python function that implements a thread-safe LRU cache from scratch, without using functools.lru_cache or any external libraries. Include type hints, a docstring, and a brief explanation of the locking strategy.'

# Reads the SSE stream on stdin and prints one summary line from the final usage chunk.
SUMMARIZE='
import json, sys
usage = None
for line in sys.stdin:
    if line.startswith("data: {"):
        usage = json.loads(line[6:]).get("usage") or usage
if not usage:
    sys.exit("no usage stats in response")
print("{completion_tokens} tokens at {completion_tokens_per_sec:.1f} T/s, total {total_time:.2f}s".format(**usage))
'

send_request() {
  local id=$1
  local summary
  summary=$(curl -sfN "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "{
      \"model\": \"$MODEL\",
      \"messages\": [{\"role\": \"user\", \"content\": $(printf '%s' "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}],
      \"max_tokens\": $MAX_TOKENS,
      \"stream\": true,
      \"stream_options\": {\"include_usage\": true},
      \"temperature\": 0
    }" | python3 -c "$SUMMARIZE")
  echo "request $id: $summary"
}

echo "Firing 3 requests concurrently, polling nvidia-smi in the background..."

# Poll VRAM usage every 0.3s in the background while requests run, log to a temp file
VRAM_LOG=$(mktemp)
(
  while true; do
    nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits >> "$VRAM_LOG"
    sleep 0.3
  done
) &
POLL_PID=$!

send_request 1 &
PID1=$!
send_request 2 &
PID2=$!
send_request 3 &
PID3=$!

# Wait ONLY on the three request PIDs — a bare `wait` here would also wait on
# the poller loop above, which never exits on its own, causing a permanent hang.
wait "$PID1" "$PID2" "$PID3"

# Stop the poller
kill "$POLL_PID" 2>/dev/null
wait "$POLL_PID" 2>/dev/null || true

PEAK_MB=$(sort -n "$VRAM_LOG" | tail -1)
echo
echo "Peak VRAM usage during the concurrent burst: ${PEAK_MB} MiB"
echo "(compare against your card's total — 16380 MiB on the 4060 Ti/4080 16GB)"
rm -f "$VRAM_LOG"

echo "Done. Check docker compose logs for per-request T/s and any OOM/error output."
