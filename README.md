# llama-server

Local [llama.cpp](https://github.com/ggml-org/llama.cpp) `llama-server` setup for
[Qwen3.6-35B-A3B-MTP](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF)
(UD-Q4_K_XL quant), running on a single RTX 4070 (12GB VRAM) + 32GB system RAM.

## About the model

[Qwen3.6-35B-A3B-MTP](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF)
is a **mixture-of-experts (MoE)** model: 35B total parameters, but only
**~3B active per token** (256 experts, 8 routed + 1 shared per token, in a
hybrid linear-attention/gated-attention architecture across 40 layers).
That sparsity is what makes a 35B-class model workable on a single 12GB
consumer GPU at all - full dense 35B weights wouldn't fit, but with MoE
most of the parameter count only needs to be *resident* (in system RAM,
via `-ncmoe`), not compute-active on every token. This is also why
`-ncmoe` (how many MoE layers stay on CPU vs GPU) is the primary tuning
knob throughout this repo instead of just "how much VRAM do you have."

**MTP** (multi-token prediction) is the other half of the setup: the model
was trained to predict multiple tokens per step, which `--spec-type
draft-mtp` uses for speculative decoding - about **1.5-2x faster
inference with no accuracy loss**, per the model card, since the draft
tokens come from the model itself rather than a separate smaller model.
The tradeoff (see `--parallel` note below) is that MTP currently doesn't
support multiple parallel request slots or `--mmproj` (image/video input)
- this setup deliberately takes that tradeoff for single-user, text-only,
maximum-speed local inference.

Native context is 262,144 tokens (extensible further via YaRN, not used
here); the model card positions it for agentic coding, repo-level
reasoning, tool calling, and extended "thinking" - which is why context
size is treated as precious in this repo (see the min-context note below)
rather than trimmed for memory savings.

## Layout

```
.
├── install.sh                     # run this first - see Quick start
├── config/
│   ├── llama-server.env.example   # template for the secrets file
│   ├── full-128k.env.example      # tunables for the full-128k deployment
│   ├── full-256k.env.example      # tunables for the full-256k deployment
│   └── limited.env.example        # tunables for the limited deployment
├── models/
│   └── *.gguf                     # model weights (gitignored, see .gitignore)
├── scripts/
│   └── llm-server.sh              # launcher - has one built-in default config
└── systemd/
    ├── llama-server-full-128k.service
    ├── llama-server-full-256k.service
    └── llama-server-limited.service
```

## Quick start

```sh
./install.sh
```

This stages `~/.config/llama-server/secrets.env` plus one tunables file per
deployment (`full-128k.env`, `full-256k.env`, `limited.env`), symlinks the
three units in `systemd/` into `~/.config/systemd/user/`, and runs
`systemctl --user daemon-reload`. It's safe to re-run (e.g. after a
reclone) - existing config files are never overwritten, only created if
missing. Then:

```sh
$EDITOR ~/.config/llama-server/secrets.env   # set your API key
systemctl --user enable --now llama-server-full-128k.service
```

See [systemd (user service)](#systemd-user-service) below for the full
workflow, or run `scripts/llm-server.sh` directly without any of this - see
below.

## Deployments (tunables files)

`scripts/llm-server.sh` has exactly **one built-in default configuration**
(`ncmoe=27, ctx-size=131072, threads=12` - the fastest single-GPU-only
setup). You are not meant to edit the script to change it. Instead, each of
the three deployments below is just a tunables file
(`config/<name>.env.example`, staged by `install.sh` to
`~/.config/llama-server/<name>.env`) that a systemd unit passes via
`--tunables-file`; editing that file and restarting the unit is the normal
way to change what runs, and it lets you tweak *any* flag the script
supports (sampling, context, threads, cache type, ...), not just the three
that vary between these three:

| Deployment   | `-ncmoe` | `--ctx-size` | `-t` | When to use |
|--------------|---------:|-------------:|-----:|-------------|
| `full-128k`  | 27       | 131072       | 12   | Default daily driver - fastest, most layers on GPU |
| `full-256k`  | 32       | 262144       | 12   | Occasional, when a task genuinely needs more context |
| `limited`    | 33       | 131072       | 8    | A desktop session is also using the GPU's VRAM |

Context size always stays within `[131072, 262144]`, enforced by the
script: the [model card](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF)
says the model uses its context window for thinking and response quality
drops off below ~128k, and 262144 is its native max.

The `limited` numbers are tuned for a 12GB card sharing VRAM with a normal
desktop session. `-ncmoe 33` is confirmed in practice, not a guess: it was
lowered from 38 after real desktop use showed the VRAM headroom was there,
which both cuts host RAM and speeds up token generation. Note the memory
ceilings in `systemd/llama-server-limited.service` are sized against the
resting footprint at this value - raising `-ncmoe` moves weight from VRAM
into host RAM, so raise those caps to match if you do. If you see OOM errors
or heavy swapping, raise `-ncmoe` (more info below); if there's headroom to
spare, lower it towards `full-128k`'s value for more speed. Edit
`~/.config/llama-server/limited.env` and `systemctl --user restart
llama-server-limited.service` to apply a change.

You can also run the script directly without any tunables file (uses the
built-in default) or point `--tunables-file` at any of the example files
for a one-off run:

```sh
./scripts/llm-server.sh --dry-run
./scripts/llm-server.sh --tunables-file config/full-256k.env.example --dry-run
```

See the full flag/env-var reference:

```sh
./scripts/llm-server.sh --help
```

Config resolves in this order (later wins): built-in defaults → tunables
file → secrets file → environment variables → CLI flags. So e.g.
`LLAMA_NCMOE=40 ./scripts/llm-server.sh` overrides just that one value for
a single run, and `--dry-run` prints the resulting `llama-server` command
without starting it.

## Sampling & MTP notes

- **Sampling defaults** (`--temp 1.0 --top-p 0.95 --top-k 20 --presence-penalty 1.5`)
  come from the model card's "thinking mode" recommendation and are always
  applied unless overridden (`--temp`/`--top-p`/`--top-k`/`--presence-penalty`
  or the matching `LLAMA_*` env vars) - llama-server's generic built-in
  defaults aren't tuned for this model.
  - **They only apply to requests that don't specify their own.** Any
    OpenAI-compatible client that sends a sampler block in the request body
    overrides these per-request, and most send one on every call - OpenCode
    puts `"temperature":0.6,"top_p":0.95,"presence_penalty":0,"top_k":20,
    "min_p":0,"repeat_penalty":1` on the wire each time, so the CLI's
    `presence-penalty 1.5` never reaches it. Keep the flags (they're the
    fallback for raw `curl` and any client that stays silent), but tune
    sampling for an agent in *that agent's* config, not here. Confirm what
    actually applied via `/slots` rather than `/props` - `/props` only
    reports the server's own CLI-baked baseline.
- **`--spec-draft-n-max 4`**: tuned by testing on this model/hardware - good
  speedup at 4, draft accept rate falls off sharply at 5. The model card's
  own example uses 2, which is a safer generic starting point if you're
  running a different quant/hardware combo and want to re-tune.
- **`--parallel` must stay `1` while `--spec-type` is `draft-mtp`** - the
  model card states multi-token prediction doesn't yet support `-np > 1`
  (or `--mmproj`). The script enforces this and will refuse to start
  otherwise.

## Coding agent configs (example-configs/)

```
example-configs/
├── opencode/
│   └── opencode.json    # OpenCode provider config (OpenAI-compatible API)
└── claude-code/
    └── settings.json     # Claude Code config (Anthropic Messages API)
```

`example-configs/<agent-name>/` holds ready-to-use client configs for
coding agents that talk to this server. OpenCode uses the server's
OpenAI-compatible API (`http://localhost:8080/v1`); Claude Code uses
llama-server's newer built-in [Anthropic Messages
API](https://huggingface.co/blog/ggml-org/anthropic-messages-api-in-llamacpp)
(`http://localhost:8080`, no `/v1` suffix - Claude Code's `ANTHROPIC_BASE_URL`
appends its own path). The same pattern is meant to extend to other agents
(Continue, etc.) as they're set up against this server - each gets its own
subdirectory here rather than scattering config in unrelated places.

`opencode/opencode.json` defines **10 model profiles**: 5 sampling
"flavors" (`thinking-general`, `thinking-coding`, `thinking-coding-hard`,
`instruct-general`, `instruct-fast`) × 2 context sizes (`128k`/`256k`).
The sampling values for each flavor are pulled directly from the model
card's four published presets (see [About the model](#about-the-model) and
[Sampling & MTP notes](#sampling--mtp-notes) above) - not guessed. The
128k/256k split exists because OpenCode (like most OpenAI-compatible
clients) has no way to query a server for its actual loaded context size;
`limit.context` is a static, client-side-only value, so each flavor is
materialized twice rather than risking a mismatch against whichever
deployment (see [Deployments](#deployments-tunables-files)) happens to be
running.

Two top-level keys matter beyond the model list:

- **`small_model`** points OpenCode's background traffic - session title
  generation, and the auto-summarization that fires as a session nears its
  context limit - at `instruct-fast-128k` instead of the main thinking model.
  Those requests are not agents, but each is a distinct prefix on the same
  single slot, so this cuts their generation cost substantially. It does
  **not** remove the slot contention or the cache branch: title generation
  fires concurrently with the first message of a session and still queues
  behind it (observed on the wire waiting ~11s). Budget for those branches
  when sizing `--cache-ram` - see [Memory stability](#memory-stability).
- **`lsp: true`** enables OpenCode's language-server integration, which is
  client-side only and has no bearing on this server.

These configs were validated against a real request, not just written from
docs: with the server running, a differential test - temporarily launching
it with distinctive sampling defaults that don't match any profile, then
comparing `/slots`' actual applied params after a real request - confirmed
every field in `opencode.json`'s `options` (including non-standard ones
like `top_k`, `min_p`, and `repeat_penalty`) genuinely reaches llama-server
rather than being silently dropped by the client. That process caught a
real bug along the way: llama.cpp's field is `repeat_penalty`, not the
`repetition_penalty` the file originally used, which llama-server was
silently ignoring. Any future agent config added here should get the same
treatment before being trusted, since different clients pass through
non-standard OpenAI fields with varying (and sometimes broken) reliability.

`claude-code/settings.json` is deliberately much simpler than
`opencode.json`, for two reasons specific to how Claude Code works rather
than any limitation of this server:

- **No sampling profiles - because there is nowhere to put them.** Claude
  Code's `settings.json` schema has no field for
  `temperature`/`top_p`/`top_k`/etc, so unlike `opencode.json` there is no
  way to *configure* sampling on the client side at all.

  This is a gap, not a feature, and it does **not** mean the server's values
  always win. Measured against this server's Anthropic endpoint: a request
  with no sampling fields correctly picked up the CLI defaults
  (`temp=1.0 top_p=0.95 presence_penalty=1.5`), but a request carrying
  `temperature: 0.123, top_p: 0.404` applied exactly those instead. Whatever
  Claude Code puts in its own request bodies overrides the flags in
  [Sampling & MTP notes](#sampling--mtp-notes), for every field it sends -
  the same behaviour documented there for OpenCode. Fields it omits (e.g.
  `presence_penalty` in that test) do fall through to the server.

  So the practical position is: the tunables files set a sensible floor,
  Claude Code may silently override part of it, and there is no config knob
  to correct that. Check what actually applied with `/slots` during a real
  Claude Code request rather than assuming - `/props` only shows the
  server's own CLI-baked baseline.
- **No 128k/256k split.** Unlike OpenCode's `limit.context`, Claude Code's
  config has no client-side context-size field to keep in sync with
  whichever deployment (see
  [Deployments](#deployments-tunables-files)) is running - it just sends
  requests and the server enforces its own loaded context. One file
  covers every deployment.

`ANTHROPIC_MODEL`/`ANTHROPIC_DEFAULT_OPUS_MODEL`/`ANTHROPIC_DEFAULT_SONNET_MODEL`/
`ANTHROPIC_DEFAULT_HAIKU_MODEL`/`ANTHROPIC_SMALL_FAST_MODEL` are all pointed
at the same placeholder model name because llama-server only ever has one
model loaded at a time and doesn't validate the `model` field against
anything - Claude Code's opus/sonnet/haiku tiering doesn't map to
anything meaningful on a single local model, so every tier is just routed
at the one model that's actually running.
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`/`DISABLE_TELEMETRY`/`DISABLE_ERROR_REPORTING`/`DISABLE_AUTOUPDATER`
are set because this is a fully local, offline setup - there's no reason
for Claude Code to phone home to Anthropic's own infrastructure for
anything other than the actual (locally-redirected) inference requests.

**`apiKey`/`ANTHROPIC_AUTH_TOKEN` must stay a placeholder in every file here** (currently
`"CHANGE-ME"`) - these configs are meant to be safe to commit. Supply the
real key through whatever secret-injection mechanism the agent supports
(e.g. OpenCode's `{env:VAR_NAME}` config substitution) or a local,
untracked copy - never paste the real value into a tracked file. If a real
key is ever displayed anywhere outside `~/.config/llama-server/secrets.env`
itself (a terminal, a log, a chat transcript), treat it as burned and
rotate it - see [Secrets](#secrets) below.

## Secrets

Anything sensitive is kept **outside this repo**, under
`~/.config/llama-server/`. There are two separate files, because the API
key gets different treatment from everything else:

```
~/.config/llama-server/api-keys      # the API key(s) - see below
~/.config/llama-server/secrets.env   # anything else sensitive (uncommon)
```

`install.sh` stages both (from `config/api-keys.example` and
`config/llama-server.env.example`, mode `600`) if they don't already
exist. To do it by hand instead:

```sh
mkdir -p ~/.config/llama-server
chmod 700 ~/.config/llama-server
cp config/api-keys.example ~/.config/llama-server/api-keys
chmod 600 ~/.config/llama-server/api-keys
$EDITOR ~/.config/llama-server/api-keys   # replace "change-me" with a real key

cp config/llama-server.env.example ~/.config/llama-server/secrets.env
chmod 600 ~/.config/llama-server/secrets.env
```

The server binds to `0.0.0.0`, so `llm-server.sh` refuses to start without
a key configured unless you pass `--allow-no-api-key` explicitly.

### Why the API key gets its own file

`~/.config/llama-server/api-keys` is llama-server's own `--api-key-file`
format (one key per line, `#` comments, **not** a shell script like
`secrets.env`) - `llm-server.sh` passes the path straight through via
`--api-key-file`. This means key values are never read into the script at
all, and never become a CLI argument or a process environment variable -
they're only ever read from disk, by llama-server itself.

That matters because the alternative - putting the key in an environment
variable, which was this repo's first fix for the problem below - closes
one leak but opens a narrower one: an env var is readable via
`/proc/<pid>/environ` by any process running as the same user (or root),
for as long as the server runs. On a single-user desktop that's not a
useful boundary against a targeted attacker who already has code execution
as your user (they could just read `secrets.env` or `api-keys` directly
either way), but it *is* a real difference against generic,
opportunistic credential-stealing malware, which commonly scans
`/proc/*/environ` across all processes for anything that looks like a
secret - env vars are a common place tools put them, precisely because
so many tools use exactly the pattern this repo used to. A file at an
app-specific path doesn't get picked up by that kind of scan. Neither
approach protects against reading `secrets.env`/`api-keys` directly, or
against a core dump if the server ever crashes while the key is loaded in
memory - those risks are identical either way, since the key still has to
live in the process's own memory once loaded, however it got there.

Originally the key lived in `secrets.env` (as `LLAMA_API_KEY="..."`,
sourced into the environment) alongside everything else - it moved out
into its own file specifically to close the `/proc/*/environ` exposure.
`--api-key`/`LLAMA_API_KEY` still exist as a secondary override (e.g. for
one-off testing without touching the file) and still go via an exported
environment variable, not argv - so they're better than the old default
but not as good as the file, and are additive on top of `api-keys` rather
than replacing it.

**Practical rule regardless of mechanism:** if a key is ever displayed
anywhere outside `api-keys`/`secrets.env` themselves (a terminal, a log, a
chat transcript, `systemctl status` output before this fix existed), treat
it as burned and rotate it.

## systemd (user service)

Units are user-level (`systemctl --user`), so no root/sudo is needed and
they run as your own user automatically. One unit exists per deployment,
and all three `Conflicts=` each other so starting one stops whichever of
the other two was running - only one `llama-server` process runs at a
time. Each unit's `ExecStart=` passes `--tunables-file` pointing at its
matching `~/.config/llama-server/<name>.env` (see
[Deployments](#deployments-tunables-files) above) - the unit files
themselves never need editing to change ncmoe/ctx-size/sampling/etc.

`./install.sh` does the install step below for you (and stages the
tunables/secrets files); to do it by hand instead:

```sh
mkdir -p ~/.config/systemd/user
ln -s ~/llama-server/systemd/llama-server-full-128k.service ~/.config/systemd/user/
ln -s ~/llama-server/systemd/llama-server-full-256k.service ~/.config/systemd/user/
ln -s ~/llama-server/systemd/llama-server-limited.service   ~/.config/systemd/user/
systemctl --user daemon-reload
```

Symlinks (rather than copies) mean edits to the files in `systemd/` take
effect after just a `daemon-reload` - no reinstall step.

Start whichever deployment you want (enabling one does *not* disable the
others automatically - `Conflicts=` only stops a running unit, so run
`disable` on the ones you're not using if you don't want them starting on
next login too):

```sh
systemctl --user enable --now llama-server-full-128k.service
```

Switch deployments:

```sh
systemctl --user enable --now llama-server-limited.service   # stops full-128k via Conflicts=, starts limited
systemctl --user disable llama-server-full-128k.service       # so it doesn't race back on next login
```

Check status / logs:

```sh
systemctl --user status llama-server-full-128k.service
journalctl --user -u llama-server-full-128k.service -f
```

### Running without an active login session

User services normally stop when you log out. If you want the server to
keep running headless (e.g. you've set your machine to boot to
`multi-user.target` instead of `graphical.target` for a max-performance,
no-desktop session), enable lingering once:

```sh
loginctl enable-linger "$USER"
```

## Memory stability

On a desktop box also used for browsing, an unbounded `llama-server` is a
real problem, not just an inefficiency - it can eat enough RAM to force
swapping or trigger the system-wide OOM killer, which can take down
anything (browser tabs, the desktop session) rather than just the server.
This repo handles two related things under that heading - a resume mechanism
that has to stay on for the cache to work at all, and the cache itself, whose
size needs to match how this repo is actually used rather than just being
minimized. Both were previously mis-tuned in the direction of "use less RAM",
and both cost more time than they saved.

### Context checkpoints: ENABLED - they are what makes the prompt cache work

**`--ctx-checkpoints`** (llama-server default: `32` per slot) saves
snapshots of KV/recurrent state so a request can resume instead of
reprocessing from scratch. This repo set it to `0` on all three deployments
between 2026-07-23 and 2026-07-25, believing it was pure overhead on this
model's hybrid architecture. **That was wrong, and it was expensive.**

Checkpoints are the mechanism the prompt cache (`--cache-ram`, below) needs
to restore a branch. Recurrent state cannot be rewound the way attention KV
can, so without a checkpoint there is nothing to resume *from* - the server
recognises the cached prefix and then reprocesses all of it anyway.

Measured on `limited` at llama.cpp b10087, alternating between two
independent conversations (the orchestrator<->subagent handoff this repo
cares about), varying only `--ctx-checkpoints`:

| `--ctx-checkpoints` | returning to a cached branch | prefill |
|---:|---|---|
| `0` | 11431 of 11431 tokens reprocessed | **12.97 s** |
| `4` | 25 tokens | 0.31 s |
| `8` | 25 tokens | 0.26 s |
| `32` | 25 tokens | 0.29 s |

Only `0` behaves differently. Any non-zero value captures the whole benefit,
and **`N` is a ceiling, not a reservation** - checkpoints are allocated on
demand, and `4`, `8` and `32` measured an identical 1190 MiB of anonymous
growth on that workload. So the cost of a generous value is zero until a
session actually has that many divergence points to keep.

Two things made the old conclusion look plausible, both worth knowing:

- **An append-only conversation reuses its prefix fine without checkpoints.**
  In a ten-turn chat with `--ctx-checkpoints 0`, only turn 2 fully
  reprocesses; from turn 3 on, each turn reprocesses just the newly appended
  text (20.2% of all prompt tokens, versus 18.4% with checkpoints on). If you
  benchmark only a growing single conversation, checkpoints look nearly
  worthless. The cost shows up when a prompt *diverges* or when you switch
  branches - which is most real agent traffic.
- **The absence of log lines proved nothing.** The previous text cited "not a
  single 'checkpoint' or 'restoring' log line anywhere in this server's
  history" as confirmation. This build emits no such lines at default
  verbosity *even in runs where restore demonstrably works*, so that evidence
  never distinguished the two cases.

The upstream reports
([ggml-org/llama.cpp#24055](https://github.com/ggml-org/llama.cpp/issues/24055),
[#19794](https://github.com/ggml-org/llama.cpp/issues/19794)) may still be
accurate about context *shift* on this architecture - that is a different
operation and is not used here (`--context-shift` is off). They are not
evidence that prefix restore is broken; it isn't.

Current values: `32` on `full-128k`/`full-256k` (llama-server's own default),
`8` on `limited` - a tighter ceiling for the desktop-sharing profile, which
costs nothing measurable given its documented 2-branch working set.

### Prompt cache (`--cache-ram`): sized per-deployment for actual working set, not minimized

**`--cache-ram`** (llama-server default: `8192` MiB) caps the prompt
cache - the set of idle conversation branches kept ready to resume without
reprocessing (`--cache-idle-slots`, default enabled). This repo briefly
shipped `LLAMA_CACHE_RAM=1024` on all three deployments under the
assumption that shrinking it was a pure memory-stability win with no other
cost. It wasn't: with agentic coding workflows here running subagents
sequentially (single slot, `--parallel 1`, required by `--spec-type
draft-mtp`) and handing control back to an orchestrator, each
orchestrator<->subagent branch needs to stay cached across the handoff to
avoid a full reprocess. At 1024 MiB the cache couldn't hold both branches
at once, and every handoff evicted one to make room for the other -
turning a few-second cache hit into a 90+ second full reprocess of tens of
thousands of tokens. Confirmed in this server's own logs: the rate of full
(>10k token) reprocesses roughly doubled (6.65% of requests -> 12.5%)
after the cut, at matched request throughput.

> **Caveat on the numbers in this subsection.** The 1024-vs-8192 comparison
> above was measured while `--ctx-checkpoints` was `0`, i.e. while branch
> restore was mostly broken (see the section above). The reprocess rates were
> really observed, but *why* they moved is now unclear - with checkpoints
> disabled the cache could rarely restore a branch regardless of its size.
> The per-branch cost derivation below is from the GGUF's own metadata and is
> unaffected. Re-validate the sizing itself now that checkpoints are on;
> cached entries also carry checkpoint state, so a given `--cache-ram` holds
> somewhat fewer branches than the table implies.

The right number comes from what a single branch actually costs, computed
from this GGUF's own architecture metadata (`qwen35moe`, read directly from
the file - not guessed): `full_attention_interval=4` means only ~10-11 of
41 layers are full attention (the rest are fixed-size recurrent/SSM state
that doesn't grow with context at all); those full-attention layers have 2
KV heads x 256-dim K/V each; at `q8_0` (1.0625 bytes/element after
block-scale overhead), that's:

```
1024 elements/token/layer x 1.0625 bytes x ~10-11 layers  ~=  11 KiB/token
262,144 tokens (full-256k's max ctx) x 11 KiB/token       ~=  2.75 GiB/branch
131,072 tokens (full-128k/limited's max ctx) x 11 KiB/token ~= 1.4 GiB/branch
```

That per-branch cost is *why the value now differs by deployment* rather
than being one number for all three:

| Deployment | `--cache-ram` | Branches covered | Rationale |
|---|---:|---|---|
| `full-128k` | `8192` MiB | ~5-6 max-128k branches | llama-server's own default, restored rather than overridden - daily driver, generous cache |
| `full-256k` | `8192` MiB | ~3 max-256k branches | same default - orchestrator + active subagent + slack at the larger context size |
| `limited` | `3072` MiB | ~2 max-128k branches | deliberately smaller: this profile is *only* ever run at 128k context with strictly sequential (never parallel) agents, so exactly 2 branches (orchestrator + one active subagent) is the real ceiling of what it needs - see `limited.env`'s own comments |

`limited` is the profile explicitly meant to share RAM/VRAM with a desktop
session (see its description throughout this README), so giving back the
RAM a bigger cache would have reserved - rather than provisioning it for
branch counts or context sizes it never actually uses - is the point, not
a compromise.

### `--cache-reuse`: refused by this model, absent on purpose

**`--cache-reuse`** (llama.cpp default: `0`, off) is *not* passed by this
repo, and that's a deliberate result rather than an oversight - noting it
here because its absence otherwise looks like something nobody considered.

It's a different mechanism from `--cache-ram` above, which is why having one
says nothing about needing the other:

- `--cache-ram N` - stores whole evicted slot states in host RAM.
- `--cache-reuse N` - after a prompt diverges *mid-way*, reuses the cached
  chunk past the divergence point by KV-shifting the remainder into place.

KV shifting isn't supported on recurrent layers, and this is a hybrid model
(`full_attention_interval=4`, see the derivation above), so the flag has
nothing it can act on. Tested directly on the `limited` deployment at
llama.cpp b10087 by passing `LLAMA_EXTRA_ARGS="--cache-reuse 256"`; the
server accepts the argument and then disables it at load:

```
W srv    load_model: cache_reuse is not supported by this context, it will be disabled
```

So there is no setting to tune and no measurement to repeat - it is inert on
this architecture until upstream supports shifting recurrent state. Don't
re-add it expecting a prefill win.

### Baseline footprint (not fixed by either flag above)

Even with both of the above set well, the model's baseline footprint is
substantial on its own: the `limited` deployment rests at **18.2 GB**
`memory.current` after load, before any `--cache-ram` growth, on a 31GB-RAM
machine. That's inherent to running a 22GB+ GGUF with
several MoE layers CPU-resident (`-ncmoe`), not something `--cache-ram` or
`--ctx-checkpoints` can fix - if you need more desktop headroom than the
current profile leaves, the lever is raising `-ncmoe` further (more VRAM
used, more speed given up), and accept less multi-branch cache headroom by
lowering `--cache-ram` back down with the tradeoff above in mind, rather
than assuming there's a free reduction available.

**Measure this with `memory.current`, not `anon`.** The host-side weights
land in **shmem**, not anonymous memory - on `limited` at rest, `memory.stat`
reports ~16.9 GB `shmem` against only ~1.1 GB `anon` (`RssShmem` 16.5 GB,
`RssAnon` 1.1 GB, `VmRSS` 17.9 GB). Two consequences:

- Judging the footprint by `anon` makes it look like ~0.5 GB and hides
  essentially the entire model. `anon` is still the right lens for the part
  that *grows* with tuning (prompt cache + checkpoints), just not for the total.
- shmem is charged to the cgroup and can only be evicted to swap, so it is
  not the cheaply-reclaimable page cache it might look like. `MemoryHigh`/
  `MemoryMax` act on `memory.current`, which includes it - that is the number
  those ceilings must be sized against.

**A climbing `memory.events` `high` counter is not automatically a problem.**
Elsewhere this README treats it as evidence a ceiling is too tight, which is
right when the pressure is anonymous memory - but check *what* is being
reclaimed before acting. On `limited` at rest the split is roughly:

```
anon           1.5 GB   prompt cache + checkpoints  (the part tuning moves)
shmem         15.8 GB   model weights, swap-only
inactive_file  6.5 GB   leftover page cache from reading the GGUF
```

That `inactive_file` is a second copy of a file whose contents are already
resident in shmem - an artifact of `--no-mmap` reading 22GB through the page
cache. Reclaiming it is free, so the cgroup can sit against `MemoryHigh` with
tens of thousands of `high` events while `memory.swap.current` stays near
zero and nothing is actually hurting. Confirm with `memory.swap.current` and
the `oom_kill` counter (both should stay ~0) before concluding a ceiling
needs raising.

### `--cache-ram` is a cap, not a reservation

Worth stating plainly, because it inverts the intuition that lowering it
"saves memory". Measured on `limited` (ctx-checkpoints=8), same 3-branch
workload each time - three independent 34k-token conversations cycled twice,
so every step is a return to a branch the slot no longer holds:

| `--cache-ram` | restore hit rate | evictions | anon growth | behaviour |
|---:|---|---:|---:|---|
| `8192` | 6/6 | 0 | 2515 MiB | cap never reached |
| `3072` | 6/6 | 0 | 2550 MiB | fits, ~500 MiB spare |
| `1024` | **0/6** | 7 | 1796 MiB | thrashing - every switch reprocesses |
| `512` | **0/6** | 0 | 795 MiB | entry never fits; nothing is cacheable |

The workload allocated the same ~2.5 GiB under an 8192 ceiling as under a
3072 one. **Raising this number costs nothing until the workload actually
uses it**; lowering it reclaims nothing until you cross the threshold, and
then the cache fails abruptly rather than degrading. Dropping 3072 -> 1024
freed 754 MiB and turned all six branch switches into ~40s full reprocesses.

Two consequences for sizing:

- The limiting factor is the systemd `MemoryMax` below, not this value. Size
  `--cache-ram` to the working set and let the cgroup cap be the guard.
- `--cache-ram` does **not** bound total memory. At a 1024 MiB cap anon still
  reached 1796 MiB, because the active slot's own state and its checkpoints
  live outside the prompt cache.

Note also that a cache entry is much larger than the 11 KiB/token attention-KV
figure suggests, because it also carries checkpoint and slot state. Measured
entry sizes:

| branch size | cache entry |
|---:|---:|
| 34k tokens | ~838 MiB (only ~364 MiB of it attention KV) |
| ~88k tokens | 2,896 MiB |
| ~125k tokens | ~4 GiB |

**This is why `limited` runs `5120`, not `3072`.** At 3072 a single
125k-token branch exceeds the entire cache, so it is never stored and every
return to it reprocesses in full - measured at **125,702 tokens / 190.25s**.
At 5120 the identical switch cost **5 tokens / 0.32s**, with zero evictions
and no increase in peak memory. Budget by *entry size at your working context*,
not per-token: the failure is abrupt, not gradual.

### systemd memory caps: the actual safety net

As a layer of protection independent of getting the above tuning right,
every `systemd/*.service` unit sets `MemoryHigh=`/`MemoryMax=` (cgroup
memory caps, so a runaway gets killed and restarted by systemd instead of
triggering the system-wide OOM killer) and `OOMScoreAdjust=500` (makes the
kernel prefer killing this process over your desktop apps in a system-wide
OOM, as a last resort). Each unit's ceiling is sized for that deployment's
own baseline-footprint-plus-worst-case-cache (see the table above for what
each one's cache budget actually is), not one shared number:

| Deployment | `MemoryHigh` | `MemoryMax` | `MemorySwapMax` | Notes |
|---|---:|---:|---:|---|
| `full-128k` | `28G` | `30G` | `0` | runs only under `multi-user.target`, so nothing else is competing for RAM and a high ceiling is fine. **Not yet re-validated** - see the swap warning below |
| `full-256k` | `29G` | `30G` | `0` | same - `multi-user.target` only. Do not copy these numbers to a profile that runs alongside a desktop |
| `limited` | `23G` | `25G` | `4G` | **the graphical.target profile.** Sized from a measured near-full-context worst case - see below |

**`limited` is the profile that needs a real ceiling, and it is the
hungriest.** Despite the name, it keeps *more* MoE layers on the CPU
(`ncmoe=33`) than `full-128k` (27) or `full-256k` (32), because it runs on
`graphical.target` where the GPU is busy. So it uses the most host RAM, while
being the only one competing with a live desktop session. **The safe band is
narrow, and this repo overshot it in both directions before landing.**

```
resting                        15.74 shmem + 0.50 anon = 16.24 GiB
125,701-token ctx + 2nd branch                         = 20.39-21.16 GiB
```

| ceilings | outcome |
|---|---|
| `25G`/`27G` | only ~4GB left for the desktop - the kernel began failing allocations for *other* processes (sound card vanishing, password manager unable to open its DB). System-wide allocation failure, not a crash of this service. |
| `21G`/`23G` | too tight. Derived from a 3-branch x 34k-token test peaking at 18.74 GiB, which was **not representative** - a real overnight job reached an 88,591-token context, crossed `MemoryHigh` with no page cache left, and (with `MemorySwapMax=0`) deadlocked for 8 hours. |
| `23G`/`25G` | current. Clears the measured 21.16 GiB worst case with ~4.6GiB headroom, leaves ~6GiB for the desktop. Validated at a full 131072 context with `oom_kill 0` and no throughput cost. |

The lesson worth carrying: **size against a near-full 131072 context, not a
synthetic multi-branch workload.** The undersized value looked well-measured
and was not.

#### `MemorySwapMax` - bounded, because both extremes fail

Swap on this box is **zram** (`/dev/zram0`) - compressed RAM, not disk.

- **Unlimited** (`memory.swap.max=max`, the cgroup default) silently defeats
  the safety net: under pressure the kernel relocates anon/shmem into zram,
  removing it from `memory.current`, so `MemoryMax` never trips and no restart
  happens - while those pages still occupy physical RAM, merely charged
  outside the cgroup. The service escapes its own cap and the shortfall lands
  on the desktop.
- **`0`** is worse. With no swap outlet *and* no reclaimable page cache left,
  a cgroup that reaches `MemoryHigh` can neither free memory nor be cleanly
  OOM-killed, so the kernel spins in direct reclaim indefinitely. On
  2026-07-25 that wedged the server for 8 hours: process in state `D`, 27
  million `memory.events` `high`, zero HTTP responses, and `oom_kill` still
  `0`. A silent deadlock is worse than either finishing slowly or dying and
  restarting.
- **`4G`** (current, `limited`) gives the kernel an escape valve while keeping
  total charge bounded at `MemoryMax + 4G`. In validation the valve was barely
  touched (0.00-0.37 GiB) - it exists to prevent deadlock, not as working
  space.

Check `memory.swap.current` and `oom_kill` after real use; both should stay
near zero. If `oom_kill` fires, the cap is genuinely too low - that is the
*correct* failure, and `StartLimitBurst` bounds the restart loop.

That "throttle at cache-ram=8192" finding came from
`cat /sys/fs/cgroup/.../llama-server-<profile>.service/memory.events` -
its `high` counter (times the cgroup hit `MemoryHigh` and was throttled/
forced to reclaim, distinct from `oom`/`max`, which never fired) had
climbed into the thousands within a couple of hours of normal use, with
the cgroup pushed into a few GB of (fast, zram-backed) swap as a result.
Not a crash - `MemoryMax` never triggered - but real, frequent throttling
purely from `cache-ram=8192` needing more headroom than the original
ceiling gave it, not from a leak. Watch `systemctl --user status
llama-server-<profile>`'s peak memory column (and `memory.events` for the
`high` count) after real use and adjust if a profile is consistently
throttling or, conversely, sitting far below its ceiling. Raising
`--cache-ram` on any deployment without raising its caps to match will
make the cap the thing that throttles/kills the server, not a leak.

**A methodological trap worth knowing about, hit while tuning `limited`'s
first pass at these numbers:** `MemoryHigh` doesn't just cap growth, it
actively *reclaims* to hold usage at/below the threshold - so a cgroup
sitting exactly at its `MemoryHigh` value, flat, even under a test
generation, is not proof that's the real resting footprint. It can equally
mean the ceiling is too tight and constantly fighting the process back
down to it. The only way to tell the difference: check `memory.events`'
`high` counter (climbing fast = being throttled, not settling) or, more
directly, temporarily raise the ceiling and see where it actually comes to
rest on its own. `limited` briefly shipped `MemoryHigh=22G` that looked
"confirmed flat" at exactly 22.0GiB - `high` events were climbing into the
tens of thousands within 2 minutes at idle. Raised, it settled on its own
at ~17-18GiB with zero throttling.

**The converse trap is just as real, and this repo fell into it next:** a
climbing `high` counter is *not* by itself proof the ceiling is too tight.
Most of `memory.current` here is page cache from reading a 22GB GGUF under
`--no-mmap`, and reclaiming that is free. `limited` now runs at 21G/23G
with the `high` counter in the tens of thousands and *measurably identical*
prefill throughput to the looser 25G/27G it replaced (46.1/45.7/45.2s vs
46.0/45.5/44.9s, controlled A/B). Distinguish the two cases by what is
actually being reclaimed: check `anon`+`shmem` against the cap, plus
`memory.swap.current` and `oom_kill`, not the `high` count alone.

## Tuning for different hardware

If you're adapting this for a different GPU/RAM combination, the two knobs
that matter most:

- `-ngl` (`--ngl`): GPU layers to offload. `99` means "all of them" for
  this model.
- `-ncmoe` (`--ncmoe`): how many MoE layers stay on CPU RAM instead of GPU
  VRAM. Higher = less VRAM used, more system RAM used, slower. This is the
  primary lever for fitting a MoE model into limited VRAM.

Watch `nvidia-smi` while the server loads and while under load to see
actual VRAM usage, and adjust `LLAMA_NCMOE` in the relevant tunables file
(or pass `--ncmoe` for a one-off run) accordingly.
