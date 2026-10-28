#!/usr/bin/env bash
# Sends the same prompt N times, sequentially (no overlap/queuing), with a fixed
# max_tokens and temperature 0 so runs are directly comparable (identical output
# keeps MTP draft acceptance stable). Requests are streamed with include_usage so
# the server reports its own decode T/s, prefill time and draft acceptance.
#
# Usage: ./bench.sh [num_runs]
# IMPORTANT: only change ONE variable (e.g. draft_model on/off) between bench.sh
# runs, restarting the container in between. Keep max_seq_len identical across
# the runs you're comparing, or the comparison isn't clean.

set -euo pipefail

API_URL="http://localhost:5000/v1/chat/completions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_KEY="$(grep -oP '^api_key:\s*\K\S+' "$SCRIPT_DIR/api_tokens.yml")"
MODEL="$(curl -sf "${API_URL%/chat/completions}/model" -H "Authorization: Bearer $API_KEY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"  # whatever is loaded
RUNS="${1:-5}"
MAX_TOKENS=300

# A moderately long, fixed coding prompt — long enough that decode speed
# dominates over first-token latency noise, short enough to run quickly.
# Override with BENCH_PROMPT to test other kinds of text (draft acceptance varies).
PROMPT="${BENCH_PROMPT:-}"
[ -n "$PROMPT" ] || PROMPT='Write a Python function that implements a thread-safe LRU cache from scratch, without using functools.lru_cache or any external libraries. Include type hints, a docstring, and a brief explanation of the locking strategy.'

# Reads the SSE stream on stdin and prints one summary line from the final usage chunk.
SUMMARIZE='
import json, sys
usage = None
for line in sys.stdin:
    if line.startswith("data: {"):
        usage = json.loads(line[6:]).get("usage") or usage
if not usage:
    sys.exit("no usage stats in response")
d = usage.get("completion_tokens_details") or {}
acc, rej = d.get("accepted_prediction_tokens", 0), d.get("rejected_prediction_tokens", 0)
draft = f", draft {acc}/{acc + rej} accepted ({100 * acc / (acc + rej):.0f}%)" if acc + rej else ""
u = {k: usage[k] for k in ("completion_tokens", "completion_tokens_per_sec", "prompt_tokens", "prompt_time", "total_time")}
print("{completion_tokens} tokens at {completion_tokens_per_sec:.1f} T/s"
      ", prefill {prompt_tokens} tokens in {prompt_time:.2f}s"
      ", total {total_time:.2f}s".format(**u) + draft)
'

echo "Running $RUNS sequential requests against $MODEL (max_tokens=$MAX_TOKENS)"
echo

# Run 0 is a warm-up: the first request after a model load runs at roughly half
# speed, so it's printed for reference but shouldn't be compared.
for i in $(seq 0 "$RUNS"); do
  if [ "$i" -eq 0 ]; then printf 'warm-up (ignore): '; else printf 'run %d/%d: ' "$i" "$RUNS"; fi
  curl -sfN "$API_URL" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $API_KEY" \
    -d "{
      \"model\": \"$MODEL\",
      \"messages\": [{\"role\": \"user\", \"content\": $(printf '%s' "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}],
      \"max_tokens\": $MAX_TOKENS,
      \"stream\": true,
      \"stream_options\": {\"include_usage\": true},
      \"temperature\": 0
    }" | python3 -c "$SUMMARIZE"
done
