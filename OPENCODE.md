# Using this stack with opencode

The server's defaults are tuned for chat: `medium` reasoning effort, no thinking
carried over from earlier turns, and a 16k thinking cap. For coding, opencode
asks for more on every request, so nothing on the server needs to change.

Tested with opencode 1.19.3.

## Provider config

In `~/.config/opencode/opencode.json`, under `provider`:

```json
"tabby": {
  "npm": "@ai-sdk/openai-compatible",
  "name": "TabbyAPI",
  "options": {
    "baseURL": "http://<host>:5000/v1",
    "apiKey": "{file:~/.config/opencode/tabby-key}"
  },
  "models": {
    "Qwen3.8-27B-exl3_3.00bpw": {
      "name": "Qwen3.8 27B 3.0bpw (128k)",
      "attachment": true,
      "modalities": { "input": ["text", "image"], "output": ["text"] },
      "limit": { "context": 131072, "output": 32000 },
      "options": {
        "chat_template_kwargs": { "reasoning_effort": "xhigh", "preserve_thinking": true },
        "reasoning_budget_tokens": 24576
      },
      "variants": {
        "medium": {
          "chat_template_kwargs": { "reasoning_effort": "medium", "preserve_thinking": true },
          "reasoning_budget_tokens": 12288
        },
        "low": {
          "chat_template_kwargs": { "reasoning_effort": "low", "preserve_thinking": true },
          "reasoning_budget_tokens": 4096
        }
      }
    },
    "Qwen3.8-27B-exl3_3.50bpw": {
      "name": "Qwen3.8 27B 3.5bpw (80k)",
      "attachment": true,
      "modalities": { "input": ["text", "image"], "output": ["text"] },
      "limit": { "context": 81920, "output": 32000 },
      "options": { "...": "same as the 3.0bpw entry" },
      "variants": { "...": "same as the 3.0bpw entry" }
    }
  }
}
```

Put the `api_key` from `api_tokens.yml` in `~/.config/opencode/tabby-key`, and
`chmod 600` it.

## Choosing a model entry

**Pick the entry that matches the config loaded on the server.** The server
answers with whatever model is loaded, whichever entry you choose. But opencode
uses the entry's context limit to decide when to compact the conversation. If
3.5bpw is loaded and you use the 3.0bpw entry, opencode lets the conversation grow
past 80k and requests start failing.

`./switch.sh` prints the entry to use after each switch, and `./switch.sh` on its
own shows it for whatever is currently loaded.

| Server config                    | opencode entry              | Good for                          |
|----------------------------------|-----------------------------|-----------------------------------|
| `configs/qwen3.8-27b-3.5bpw.yml` | `Qwen3.8 27B 3.5bpw (80k)`  | Default: better quant, same speed |
| `configs/qwen3.8-27b-3.0bpw.yml` | `Qwen3.8 27B 3.0bpw (128k)` | Long agent sessions               |

Both run at a similar speed (about 44–45 T/s). Code is less forgiving of
quantization than prose, so 3.5bpw should be the stronger coder, at the cost of
some context. Switch to 3.0bpw when a session needs more room before opencode
compacts it.

## Reasoning effort

- **Default (`xhigh`):** what the model card's coding benchmarks used. Slowest
  per agent step.
- **`medium` / `low` variants:** for quick edits, or long sessions where speed
  matters more. Use `--variant medium` on the command line, or switch variants in
  the TUI.

If `xhigh` feels sluggish for everyday work, make `medium` the default by swapping
the top-level `options` with the `medium` variant's.

Things to know about these settings:

- **Each variant must repeat `preserve_thinking`.** A variant replaces the whole
  `chat_template_kwargs` object rather than merging into it.
- **Thinking budgets stay below the output limit,** so the answer or tool call
  always has at least 8k tokens left.
- **`preserve_thinking` keeps the model's earlier reasoning in the conversation.**
  The model card says this helps agent work. opencode sends past thinking back,
  so it works here, but it fills context faster and opencode compacts more often.

## Sampling

opencode sends no sampler values, so the server's `qwen` preset fills them in
with the model card's thinking-mode values (temperature 1.0, top_p 0.95, top_k 20,
no presence penalty). Don't lower the temperature for code: with thinking models
that tends to cause repetition loops in the thinking, not better code.

## Context budget

opencode's system prompt and tool definitions take about 11k tokens before you
type anything, most of it opencode's own core tools. That's under a tenth of
3.0bpw's context and about a seventh of 3.5bpw's. Turning off MCP tools you don't use, in
opencode's `tools` section, saves a little on every request.

## Images

`attachment` and `modalities` tell opencode the model accepts images, so you can
paste screenshots of errors, UIs or charts. opencode first shrinks any image
larger than 2000×2000 to fit (its `media.image` settings), so a 1440p or 4K
screenshot arrives as about 2,200 tokens, and 1080p or smaller as about 900–2,000.
Images stay in the conversation until opencode compacts it. Crop to the part
that matters when you can: it's faster, too.

The height limit also shrinks tall full-page captures, which can make small text
unreadable. To let those through, raise it in `opencode.json`:

```json
"media": { "image": { "max_height": 5000 } }
```

See [Vision](README.md#vision) for timings.

## Performance notes

- **The first requests after a server restart are slow** while the server warms
  up and MTP calibrates. Expect normal speed from about the third request.
- **The server handles one request at a time** (`max_batch_size: 1`). Point
  opencode's `small_model` (titles) and lightweight agents such as `explore` at a
  different server if you have one, so they don't queue behind the main model.
- **The first request in a session processes the whole system prompt.** Later
  requests reuse the server's prompt cache and start much faster.
- **Edits are fast to write.** When the model quotes code from the conversation,
  as edit calls and file rewrites do, the server drafts it in large pieces
  (`hybrid_draft_tokens`): a verbatim file copy runs at about 200 T/s instead of 72.
- **Files with Windows (CRLF) line endings can break prompt caching** on the
  current image (exllamav3 1.6.4). If a long session reprocesses its whole
  history every turn, that's the likely cause. See the README's Upgrading section.
- **Switching between sessions is fast.** Conversations pushed out of VRAM are
  kept in system RAM and restored in about a second, rather than reprocessed at
  about 650 tokens/s (over a minute for a 45k-token session). After opencode compacts a
  session, the history has changed, so the next request processes it fresh.

## Checking what opencode sends

To see the exact request body and templated prompt, run a copy of the config with
request logging turned on:

```bash
sed 's/^  log_generation_params: false/  log_generation_params: false\n  log_chat_completion_requests: true/' \
  configs/qwen3.8-27b-3.5bpw.yml > configs/tmp-debug.yml
TABBY_CONFIG=configs/tmp-debug.yml docker compose up -d --force-recreate tabbyapi
# ...send a request from opencode, then:
docker exec tabbyapi sh -c 'ls -t /app/logs/debug/'
```

Each request is saved as a `.json` file (the body) and a `.txt` file (the exact
prompt). These files contain full prompts, so delete the temporary config and
restart with the normal one when you're done. Recreating the container clears
the logs.
