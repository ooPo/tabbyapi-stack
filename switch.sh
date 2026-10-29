#!/usr/bin/env bash
# Switches the server to another config and waits until the model is loaded.
# The choice is saved to .env, so later `docker compose up` runs keep it.
# If the new config fails to load, the previous one is restored.
#
# Usage: ./switch.sh 3.0 | 3.5 | configs/<file>.yml
#        ./switch.sh            (show what's loaded)

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

DEFAULT_CONFIG="configs/qwen3.8-27b-3.5bpw.yml"
API_KEY="$(grep -oP '^api_key:\s*\K\S+' api_tokens.yml)"

# The config saved in .env, or the default if none is saved or it no longer exists.
current_config() {
  local config
  config="$(grep -oP '^TABBY_CONFIG=\K.*' .env 2>/dev/null || true)"
  if [ -f "$config" ]; then echo "$config"; else echo "$DEFAULT_CONFIG"; fi
}

loaded_model() {
  curl -sf localhost:5000/v1/model -H "Authorization: Bearer $API_KEY" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'
}

show_status() {
  local config=$1 model ctx
  model="$(grep -oP '^\s*model_name:\s*\K\S+' "$config")"
  ctx="$(grep -oP '^\s*max_seq_len:\s*\K[0-9]+' "$config")"
  echo "config:   $config"
  echo "loaded:   $(loaded_model 2>/dev/null || echo 'nothing (still loading, or failed)')"
  echo "opencode: use tabby/$model ($((ctx / 1024))k entry)"
}

# Recreates the container with a config and waits for the model; returns 1 on failure.
start_with() {
  TABBY_CONFIG="$1" docker compose up -d --force-recreate tabbyapi >/dev/null 2>&1
  for _ in $(seq 1 60); do
    sleep 3
    loaded_model >/dev/null 2>&1 && return 0
    if docker compose logs tabbyapi 2>&1 | grep -qE 'Insufficient VRAM|Traceback'; then
      # Docker restarts a failed load, so show the error itself rather than the log tail.
      docker compose logs tabbyapi 2>&1 | grep -E '^\S+\s+\|\s+\w*Error' | tail -1 | sed 's/^/  /'
      return 1
    fi
  done
  echo "  timed out waiting for the model to load"
  return 1
}

if [ $# -eq 0 ]; then
  show_status "$(current_config)"
  exit 0
fi

case "$1" in
  3.0|3.5) NEW="configs/qwen3.8-27b-$1bpw.yml" ;;
  *)       NEW="$1" ;;
esac
[ -f "$NEW" ] || { echo "no such config: $NEW" >&2; exit 1; }

OLD="$(current_config)"
echo "switching to $NEW ..."
if start_with "$NEW"; then
  echo "TABBY_CONFIG=$NEW" > .env
  show_status "$NEW"
else
  echo "failed to load $NEW; restoring $OLD ..."
  start_with "$OLD" || { echo "restore failed too; check docker compose logs tabbyapi" >&2; exit 1; }
  echo "TABBY_CONFIG=$OLD" > .env
  show_status "$OLD"
  exit 1
fi
