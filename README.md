# tabbyapi-stack

TabbyAPI serving Qwen3.8-27B (exl3) on a single RTX 4060 Ti 16GB, exposed as an
OpenAI-compatible API on port 5000.

## Setup

```bash
sudo apt update
sudo apt install -y python3-venv python3-full

python3 -m venv ~/.venvs/hf-dl
source ~/.venvs/hf-dl/bin/activate
pip install -U huggingface_hub

./download-models.sh   # fetches the 3.00bpw and 3.50bpw quants into models/
```

Create `api_tokens.yml` before the first launch. It's git-ignored, so a fresh
clone doesn't have one:

```bash
printf 'api_key: %s\nadmin_key: %s\n' "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > api_tokens.yml
chmod 600 api_tokens.yml
```

## Running

```bash
docker compose up -d --force-recreate tabbyapi
docker compose logs -f tabbyapi
```

This uses `configs/qwen3.8-27b-3.0bpw.yml` by default. To run another config, set
`TABBY_CONFIG`:

```bash
TABBY_CONFIG=configs/qwen3.8-27b-3.5bpw.yml docker compose up -d --force-recreate tabbyapi
```

Clients connect to `http://<host>:5000/v1` using the `api_key` from
`api_tokens.yml`. Port 5000 listens on all interfaces, so firewall it to trusted
hosts. Browser (cross-origin) requests are blocked with `allowed_origins: []`, so
a client that calls the API from a browser page needs its origin added there.

For coding with opencode, see [OPENCODE.md](OPENCODE.md).

## Configs

Each file in `configs/` is named `<model>-<quant>.yml`. Apart from the differences
below, both use the same settings: `6,5` KV cache, the `qwen` sampler preset, and
these reasoning and MTP settings:

- **Reasoning defaults:** `medium` effort, and thinking from earlier turns is
  dropped (`preserve_thinking: false`). The model's own defaults are `xhigh` and
  preserved thinking, which are slower and fill context fast. Clients can override
  both per request through `chat_template_kwargs`.
- **Thinking cap:** thinking is forced to end after 16k tokens
  (`reasoning_budget_tokens`, also overridable per request).
- **MTP:** drafts up to 4 tokens, cut short dynamically when the drafter is unsure.
- **RAM prompt cache:** K/V pages evicted from VRAM are kept in system RAM
  (`sysmem_kv_cache: 8192`), so switching back to an earlier conversation is
  near-instant. See [Prompt caching](#prompt-caching).

| File                             | Context | Decode (code / prose) | Peak VRAM |
|----------------------------------|---------|-----------------------|-----------|
| `configs/qwen3.8-27b-3.0bpw.yml` | 112k    | 45.7 / 40.1 T/s       | 14.7 GB   |
| `configs/qwen3.8-27b-3.5bpw.yml` | 60k     | 42.2 T/s (code)       | 14.8 GB   |

Measured with `bench.sh` (temperature 0, 300 tokens) on an RTX 4060 Ti 16GB. The
prose figure uses `BENCH_PROMPT` with a short plain-English explainer. Results
repeat exactly within one load, but can shift by about 1% between restarts.
Dynamic drafting calibrates as it goes, so the first couple of requests after a
restart are slower.

Pick 3.0bpw for long context, or 3.5bpw for the better quant at nearly the same
speed when 60k is enough.

### MTP draft length (3.0bpw)

| Draft tokens  | Code     | Prose    |
|---------------|----------|----------|
| 2             | 41.5 T/s | 39.0 T/s |
| 3             | 44.2 T/s | 39.0 T/s |
| 4 (default)   | 44.8 T/s | 39.1 T/s |
| 5             | 42.5 T/s | 37.6 T/s |
| 4, dynamic    | 45.7 T/s | 40.1 T/s |

6 or more draft tokens (fixed or dynamic) fail to load at 112k: longer drafts need
more VRAM on this model. Compare speeds, not acceptance percentages: acceptance
drops as drafts get longer even when more tokens are accepted in total.

### Without MTP

Measured before the reasoning defaults above, with the coding prompt:

| Quant   | Max context | Decode   | Peak VRAM |
|---------|-------------|----------|-----------|
| 3.0bpw  | 112k        | 22.0 T/s | 13.4 GB   |
| 3.5bpw  | 104k        | 20.0 T/s | 14.7 GB   |

MTP roughly doubles decode speed and needs about 1.2 GB of VRAM. Without it, the
quant alone makes only about a 10% difference. On 16GB, 3.5bpw fails to load at
108k without MTP and at 64k with it.

### Prompt caching

The server keeps each conversation's processed prompt in VRAM, so a follow-up
message only processes the new part. That cache is the size of the context (112k
or 60k tokens). When conversations you switch between add up to more than that,
the oldest is evicted, and returning to it means processing its whole history
again at about 590 tokens/s.

With `sysmem_kv_cache`, evicted pages go to system RAM instead and are copied
back on return. Measured on 3.5bpw, switching between two 35k-token conversations
(70k total, more than the 60k cache):

| Request                 | RAM tier off | RAM tier on |
|-------------------------|--------------|-------------|
| First message (cold)    | 59.7 s       | 59.7 s      |
| Follow-up, still cached | 0.9 s        | 0.9 s       |
| Back to it after the other | 55.5 s    | 0.7 s       |

The cost is RAM, not VRAM. In this build the full 8 GB (about 9 GB with
overhead) is reserved as pinned memory right after load, even though the option
is described as a ceiling. At about 24 KB per token, that holds roughly 360k
tokens. Decode speed is unaffected.

The `qwen` sampler preset in `sampler_overrides/` uses the model card's
thinking-mode values. It only fills in values the client doesn't send, so clients
that turn thinking off should send the model card's non-thinking values themselves.

## Benchmarking

- `./bench.sh [runs]` sends a warm-up request, then sequential, deterministic
  requests against whichever model is loaded. It prints decode T/s, prefill time
  and MTP draft acceptance as reported by the server. Set `BENCH_PROMPT` to test
  a different kind of text, since draft acceptance varies with content.
- `./bench-concurrent.sh` sends 3 requests at once and records peak VRAM. With
  `max_batch_size: 1` they queue rather than batch.

Change one variable at a time between runs, and restart the container in between.

## Upgrading

The TabbyAPI image is pinned by digest in `docker-compose.yml`, so updates never
arrive silently. The current pin is TabbyAPI `53da791` (2026-09-13) with
exllamav3 1.5.0.

**1. Check what changed.** Read the
[TabbyAPI commits](https://github.com/theroyallab/tabbyAPI/commits/main) and
[exllamav3 releases](https://github.com/turboderp-org/exllamav3/releases) since
the current pin. Look for fixes or known regressions affecting prompt caching,
drafting (MTP), sampling, or GDN / linear-attention layers, which make up most of
this model. Skip an image whose exllamav3 version has an open regression in
something this stack relies on.

**2. Pull the new image and note its digest and exllamav3 version:**

```bash
docker pull ghcr.io/theroyallab/tabbyapi:latest
docker image inspect --format '{{index .RepoDigests 0}}' ghcr.io/theroyallab/tabbyapi:latest
docker run --rm --entrypoint sh ghcr.io/theroyallab/tabbyapi:latest -c 'pip show exllamav3 | grep -i ^version'
```

**3. Swap the digest** into `docker-compose.yml`, update the comment above it, and
restart with the default config.

**4. Re-measure each config,** restarting between them:

- **Decode:** `./bench.sh 3`, compared with the configs table above.
- **Prompt caching:** run `bench.sh` with a long prompt. The warm-up processes
  the full prompt, and the next run should be served from cache, with prefill
  dropping from tens of seconds to under a second:

  ```bash
  BENCH_PROMPT="$(head -c 40000 models/Qwen3.8-27B-exl3_3.00bpw/README.md) Summarise the above in one sentence." ./bench.sh 1
  ```

  On the current pin, 15k tokens take 26 s cold and 0.65 s cached.
- **Context limits:** the server still loads at the configured context. VRAM
  improvements may also let a config load with more, so it's worth retrying the
  next step up (e.g. 64k on 3.5bpw with MTP).

**5. Keep it or roll back.** If everything holds up, commit the new digest with
the numbers in the message, and update the tables in this README. If not, restore
the old pin and restart:

```bash
git checkout docker-compose.yml
docker compose up -d --force-recreate tabbyapi
```
