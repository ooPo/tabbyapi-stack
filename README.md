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

This uses `configs/qwen3.8-27b-3.5bpw.yml` by default. To switch configs, use
`switch.sh`:

```bash
./switch.sh 3.0    # or 3.5, or a path such as configs/<file>.yml
./switch.sh        # show the current config, the loaded model and the opencode entry
```

It waits until the model has loaded, and prints which opencode entry to use. The
choice is saved to `.env`, so later `docker compose up` runs keep it. If the new
config fails to load, it restores the previous one. Setting `TABBY_CONFIG` in the
environment still overrides `.env` for a one-off run.

`docker ps` shows the container as `healthy` once a model is loaded and the
server reports no errors. A model that fails to load shows up differently:
TabbyAPI exits, and Docker keeps restarting it ("Up 3 seconds", with a rising
restart count).

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
- **Hybrid drafting:** when the model repeats text from its context, up to 32
  tokens of it are drafted at once (`hybrid_draft_tokens`). See
  [Hybrid drafting](#hybrid-drafting).
- **RAM prompt cache:** K/V pages evicted from VRAM are kept in system RAM
  (`sysmem_kv_cache: 8192`), so switching back to an earlier conversation is
  near-instant. See [Prompt caching](#prompt-caching).
- **Vision:** images are accepted, with the vision weights kept in system RAM
  and images capped at 4K. See [Vision](#vision).
- **No web UI:** the built-in chat page at `/ui` is turned off (`web_ui: false`).

| File                             | Context | Decode (code / prose) | VRAM after load |
|----------------------------------|---------|-----------------------|-----------------|
| `configs/qwen3.8-27b-3.0bpw.yml` | 128k    | 44.5 / 40.6 T/s       | 14.4 GB         |
| `configs/qwen3.8-27b-3.5bpw.yml` | 80k     | 44.7 / 43.2 T/s       | 14.6 GB         |

Measured with `bench.sh` (temperature 0, 300 tokens) on an RTX 4060 Ti 16GB. The
prose figure uses `BENCH_PROMPT` with a short plain-English explainer. Results
repeat closely within one load, but can shift by 1–3% between restarts (3.5bpw
has measured 43.5 and 44.7 T/s on code). Dynamic drafting calibrates as it goes,
so the first couple of requests after a restart are slower. VRAM peaks higher
during long prompts and image requests; see [Vision](#vision).

Each context is the largest step that loads with MTP and still leaves room for a
4K image: 3.5bpw fails to load at 96k, and 3.0bpw at 144k loads but a 4K image
then runs out of VRAM. 3.5bpw is the default: the better quant at the same
speed. Switch to 3.0bpw for long sessions that need more than 80k.

### Hybrid drafting

Measured on 3.0bpw, asking the model to reproduce a 1,834-token script with one
variable renamed (thinking off):

| `hybrid_draft_tokens` | Decode    |
|-----------------------|-----------|
| 0 (MTP only)          | 71.9 T/s  |
| 32 (default here)     | 199.5 T/s |
| 64                    | 190.0 T/s |

Every copy was exact. On the normal coding prompt the difference was within
noise. This is what opencode's edit calls and file rewrites do, since both quote
existing code.

### MTP draft length (3.0bpw, previous image)

Measured at 112k on the previous image (TabbyAPI `53da791`, exllamav3 1.5.0):

| Draft tokens  | Code     | Prose    |
|---------------|----------|----------|
| 2             | 41.5 T/s | 39.0 T/s |
| 3             | 44.2 T/s | 39.0 T/s |
| 4 (default)   | 44.8 T/s | 39.1 T/s |
| 5             | 42.5 T/s | 37.6 T/s |
| 4, dynamic    | 45.7 T/s | 40.1 T/s |

6 or more draft tokens (fixed or dynamic) failed to load at 112k: longer drafts
need more VRAM on this model. Compare speeds, not acceptance percentages:
acceptance drops as drafts get longer even when more tokens are accepted in total.

### Without MTP (previous image)

Measured on the previous image, before the reasoning defaults above, with the
coding prompt:

| Quant   | Max context | Decode   | Peak VRAM |
|---------|-------------|----------|-----------|
| 3.0bpw  | 112k        | 22.0 T/s | 13.4 GB   |
| 3.5bpw  | 104k        | 20.0 T/s | 14.7 GB   |

MTP roughly doubles decode speed and needs about 1.2 GB of VRAM. Without it, the
quant alone makes only about a 10% difference. On that image, 3.5bpw failed to
load at 108k without MTP and at 64k with it.

### Prompt caching

The server keeps each conversation's processed prompt in VRAM, so a follow-up
message only processes the new part. That cache is the size of the context (128k
or 80k tokens). When conversations you switch between add up to more than that,
the oldest is evicted, and returning to it means processing its whole history
again (prefill):

| Prompt      | 3.0bpw cold         | 3.5bpw cold         |
|-------------|---------------------|---------------------|
| 16k tokens  | 20.7 s (778 T/s)    | 20.8 s (775 T/s)    |
| 45k tokens  | 67.4 s (668 T/s)    | 67.5 s (667 T/s)    |

Measured with `./bench.sh --long`, best of two cold runs (the first cold run of
each size is about 10% slower). Prefill speed is the same for both quants, and it
slows a little as prompts get longer.

Follow-up turns in a cached conversation took 0.2–1.7 s in conversation tests (the
model's own reply plus a new question). `bench.sh --long`'s follow-up
consistently takes about 4.6 s instead, at both sizes (3.2–3.6 s on the previous
image). The cause wasn't found; it's still far from a cache miss, which would
take as long as the cold run.

**Known issue in this image (exllamav3 1.6.4):** long prompts containing Windows
(CRLF) line endings can tokenize differently as the conversation grows, so a
follow-up misses the cache and reprocesses everything. In testing, the second
turn of a 42k-token CRLF conversation took 62.5 s instead of under a second. Files
on Linux use LF, so this needs CRLF text in the context, such as files from
Windows or some web and tool output. Fixed in exllamav3 1.6.5
([issue #564](https://github.com/turboderp-org/exllamav3/issues/564)).

With `sysmem_kv_cache`, evicted pages go to system RAM instead and are copied
back on return. Measured on the previous image with 3.5bpw at 60k, switching
between two 35k-token conversations (70k total, more than the 60k cache):

| Request                 | RAM tier off | RAM tier on |
|-------------------------|--------------|-------------|
| First message (cold)    | 59.7 s       | 59.7 s      |
| Follow-up, still cached | 0.9 s        | 0.9 s       |
| Back to it after the other | 55.5 s    | 0.7 s       |

Rechecked on the current image with 3.5bpw at 80k: two conversations of 47.7k
and 46.1k tokens (94k total), and going back to the first took 0.8 s.

The cost is RAM, not VRAM. In this build the full 8 GB (about 9 GB with
overhead) is reserved as pinned memory right after load, even though the option
is described as a ceiling. At about 24 KB per token, that holds roughly 360k
tokens. Decode speed is unaffected.

### Vision

Both configs accept images (`vision: true`). The vision weights don't fit in VRAM
at full context, so `vision_offload: true` keeps them in system RAM (about 1.6 GB
more). VRAM after load and decode speed are unchanged, and offloading made image
requests no slower than in-VRAM vision did (tested at a reduced 64k context, where
both fit).

Measured on 3.0bpw at 128k, with each image asked about once:

| Image                         | Image tokens | First token | Peak VRAM |
|-------------------------------|--------------|-------------|-----------|
| 1280×720                      | ~900         | 2.5 s       | 15.3 GB   |
| 1440p                         | ~3,600       | 6.4 s       | 15.6 GB   |
| 1280×4800 (full-page capture) | ~6,000       | 12 s        | 15.6 GB   |
| 4K                            | ~8,200       | 17 s        | 15.7 GB   |

Most of that time is processing the image tokens as prompt. Asking again about the
same image takes 0.2–0.3 s, as both the image and the prompt are cached. The
first image after a restart is a few seconds slower. On 3.5bpw at 80k, timings
are the same and a 4K image peaks at 15.9 GB.

opencode shrinks images to fit 2000×2000 before sending them, so from opencode a
1440p or 4K screenshot arrives as about 2,200 tokens. See [OPENCODE.md](OPENCODE.md#images).

**Image size cap.** The model allows images up to 16.7M pixels (~16k tokens), but
from about 5K the vision encoder runs out of VRAM. That fails the request with a
500 error, and the server keeps running but holds about 1.5 GB more VRAM until it
restarts. `configs/vision-preprocessor.json` lowers the cap to 8.4M pixels (just
above 4K), so larger images are downscaled instead. It's a copy of the models'
`preprocessor_config.json` with only `size.longest_edge` changed, and
`docker-compose.yml` mounts it over each model's copy. A new model needs its own
mount line there. To trade 4K detail for more headroom, lower `longest_edge`
(each image token covers 32×32 pixels).

Accuracy was good on screenshots: build failures (file, line, exit code, commit),
charts, and finding one line in a dense log at every size, including small 18px
text.

The `qwen` sampler preset in `sampler_overrides/` uses the model card's
thinking-mode values. It only fills in values the client doesn't send, so clients
that turn thinking off should send the model card's non-thinking values themselves.

## Benchmarking

- `./bench.sh [runs]` sends a warm-up request, then sequential, deterministic
  requests against whichever model is loaded. It prints decode T/s, prefill time
  and MTP draft acceptance as reported by the server. Set `BENCH_PROMPT` to test
  a different kind of text, since draft acceptance varies with content.
- `./bench.sh --long [runs]` measures prefill instead: ~16k- and ~45k-token
  prompts, each made unique so nothing comes from the cache, then a follow-up
  turn on the last one to check that the cache is used. The text has CRLF line
  endings, to catch the 1.6.4 tokenizer issue above. Sizes larger than the
  loaded context are skipped.
- `./bench-concurrent.sh` sends 3 requests at once and records peak VRAM. With
  `max_batch_size: 1` they queue rather than batch.

Change one variable at a time between runs, and restart the container in between.

## Upgrading

The TabbyAPI image is pinned by digest in `docker-compose.yml`, so updates never
arrive silently. The current pin is the 2026-10-23 build (TabbyAPI `564f8fb`)
with exllamav3 1.6.4. The next one worth taking is a build with exllamav3 1.6.5
or later, which fixes the CRLF caching issue.

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
- **Prefill and prompt caching:** `./bench.sh --long 2`, compared with the
  prefill table above. The follow-up lines should show nearly the whole prompt
  cached and take a few seconds at most; if they take as long as the cold runs,
  prompt caching is broken in that build.
- **Context limits:** the server still loads at the configured context, and a 4K
  image still fits (see the Vision step). VRAM improvements may also let a config
  load with more, so it's worth retrying the next step up (e.g. 88k on 3.5bpw).
- **New options:** diff `/app/config_sample.yml` between the old and new images
  for options worth trying.
- **Vision:** send a screenshot larger than 4K. It should be downscaled to about
  8k image tokens (`prompt_tokens` in the usage stats), not fail with a 500. If it
  fails, the build may read the image size cap from somewhere else.

**5. Keep it or roll back.** If everything holds up, commit the new digest with
the numbers in the message, and update the tables in this README. If not, restore
the old pin and configs, and restart:

```bash
git checkout docker-compose.yml configs/
docker compose up -d --force-recreate tabbyapi
```
