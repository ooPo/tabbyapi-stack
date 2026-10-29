#!/usr/bin/env bash
# Sends the same prompt N times, sequentially (no overlap/queuing), with a fixed
# max_tokens and temperature 0 so runs are directly comparable (identical output
# keeps MTP draft acceptance stable). Requests are streamed with include_usage so
# the server reports its own decode T/s, prefill time and draft acceptance.
#
# Usage: ./bench.sh [num_runs]
#        ./bench.sh --long [num_runs]   (prefill speed and prompt caching instead)
#
# --long sends ~16k- and ~48k-token prompts built from the model's README. Each run
# starts with a unique line, so nothing is reused from the prompt cache and the
# whole prompt is processed (cold prefill). The last conversation of each size then
# gets a follow-up turn (the model's own reply plus a new question), whose earlier
# part should come from the cache in about a second. Sizes that don't fit the
# loaded context are skipped.
#
# The text uses CRLF line endings: exllamav3 1.6.4 can tokenize a growing CRLF
# prompt differently each turn, which breaks the cache for the follow-up.
#
# IMPORTANT: only change ONE variable (e.g. draft_model on/off) between bench.sh
# runs, restarting the container in between. Keep max_seq_len identical across
# the runs you're comparing, or the comparison isn't clean.

set -euo pipefail

API_URL="http://localhost:5000/v1/chat/completions"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_KEY="$(grep -oP '^api_key:\s*\K\S+' "$SCRIPT_DIR/api_tokens.yml")"
MODEL="$(curl -sf "${API_URL%/chat/completions}/model" -H "Authorization: Bearer $API_KEY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"  # whatever is loaded

if [ "${1:-}" = "--long" ]; then
  RUNS="${2:-3}"
  CTX="$(curl -sf "${API_URL%/chat/completions}/model" -H "Authorization: Bearer $API_KEY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["parameters"]["max_seq_len"])')"
  DOC="$(ls "$SCRIPT_DIR"/models/*/README.md | head -1)"

  # Prints a request body: the README repeated to roughly $1 tokens, prefixed by $2,
  # with CRLF line endings. With $3 (a file holding the model's reply), adds that
  # reply and a second question. Thinking is off, so the reply is short.
  # Bodies go to curl through stdin, as they're larger than a command-line argument may be.
  build_body() {
    python3 - "$DOC" "$1" "$2" "${3:-}" <<'PY'
import json, sys
doc, tokens, prefix, reply_file = open(sys.argv[1]).read(), int(sys.argv[2]), sys.argv[3], sys.argv[4]
chars = int(tokens * 2.6)  # this README averages ~2.6 characters per token
text = (doc * (chars // len(doc) + 1))[:chars].replace("\n", "\r\n")
messages = [{"role": "user", "content": f"{prefix}\r\n\r\n{text}\r\n\r\nSummarise the above in one sentence."}]
if reply_file:
    messages += [{"role": "assistant", "content": open(reply_file).read()},
                 {"role": "user", "content": "Which section is the longest?"}]
print(json.dumps({
    "messages": messages,
    "max_tokens": 40, "temperature": 0, "stream": True,
    "stream_options": {"include_usage": True},
    "chat_template_kwargs": {"enable_thinking": False},
}))
PY
  }

  # Prints the prefill summary, and saves the reply to the file named in argv[1].
  SUMMARIZE_PREFILL='
import json, sys
usage, reply = None, ""
for line in sys.stdin:
    if line.startswith("data: {"):
        d = json.loads(line[6:])
        usage = d.get("usage") or usage
        for c in d.get("choices") or []:
            reply += (c.get("delta") or {}).get("content") or ""
open(sys.argv[1], "w").write(reply)
if not usage:
    sys.exit("no usage stats in response")
cached = (usage.get("prompt_tokens_details") or {}).get("cached_tokens", 0)
total, secs = usage["prompt_tokens"], usage["prompt_time"]
rate = f" ({(total - cached) / secs:.0f} T/s)" if cached == 0 and secs else ""
print(f"{total} tokens, {cached} cached, prefill {secs:.2f}s{rate}")
'

  send() {
    curl -sfN "$API_URL" -H "Content-Type: application/json" -H "Authorization: Bearer $API_KEY" -d @- \
      | python3 -c "$SUMMARIZE_PREFILL" "$REPLY"
  }

  REPLY="$(mktemp)"
  trap 'rm -f "$REPLY"' EXIT

  echo "Prefill and prompt caching against $MODEL (context ${CTX}, $RUNS runs per size)"
  echo
  # The first follow-up after a restart is a few seconds slower, so warm that up too.
  printf '%-22s' 'warm-up (ignore):'; build_body 2048 "warm-up $$" | send
  printf '%-22s' 'warm-up (ignore):'; build_body 2048 "warm-up $$" "$REPLY" | send
  for size in 16384 49152; do
    label="$((size / 1024))k target"
    if [ "$size" -gt $((CTX - 1024)) ]; then echo "$label: skipped, larger than the loaded context"; continue; fi
    for i in $(seq 1 "$RUNS"); do
      printf '%-22s' "$label, cold $i/$RUNS:"
      prefix="Run $i of $$ at $(date +%s%N)."
      build_body "$size" "$prefix" | send
    done
    printf '%-22s' "$label, follow-up:"; build_body "$size" "$prefix" "$REPLY" | send
  done
  exit 0
fi

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
