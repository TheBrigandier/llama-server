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
| `limited`    | 38       | 131072       | 8    | A desktop session is also using the GPU's VRAM |

Context size always stays within `[131072, 262144]`, enforced by the
script: the [model card](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF)
says the model uses its context window for thinking and response quality
drops off below ~128k, and 262144 is its native max.

The `limited` numbers are a starting point tuned for a 12GB card sharing
VRAM with a normal desktop session - if you see OOM errors or heavy
swapping, raise `-ncmoe` further (more info below); if there's headroom to
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
└── opencode/
    └── opencode.json   # OpenCode provider config for this server
```

`example-configs/<agent-name>/` holds ready-to-use client configs for
coding agents that talk to this server over its OpenAI-compatible API
(`http://localhost:8080/v1`). Currently just [OpenCode](https://opencode.ai/),
but the same pattern is meant to extend to other agents (Claude Code,
Continue, etc.) as they're set up against this server - each gets its own
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

**`apiKey` must stay a placeholder in every file here** (currently
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
Two llama-server mechanisms drive that growth here, and both are overridden
away from llama-server's own defaults in every `config/*.env.example`:

- **`--ctx-checkpoints`** (llama-server default: `32` per slot) saves
  snapshots of KV/recurrent state so a request can rewind instead of
  reprocessing from scratch. On this model's hybrid linear-attention/
  gated-attention (Gated DeltaNet-style) architecture, checkpoints are
  currently **known-broken upstream**: they get created (consuming RAM) but
  are constantly invalidated and never successfully restored - see
  [ggml-org/llama.cpp#24055](https://github.com/ggml-org/llama.cpp/issues/24055)
  and [#19794](https://github.com/ggml-org/llama.cpp/issues/19794), both
  filed against this exact model family. Until that's fixed upstream, this
  repo sets `LLAMA_CTX_CHECKPOINTS=0` - pure memory overhead with no
  restore benefit for this model as things stand. If a future llama.cpp
  release fixes hybrid/recurrent checkpoint restore, it's worth
  re-enabling (checkpoints are the mechanism behind fast multi-turn
  prompt reuse) and re-testing.
- **`--cache-ram`** (llama-server default: `8192` MiB) caps the prompt
  cache, and normal multi-turn usage genuinely fills it - `journalctl
  --user -u llama-server-<profile>` will show repeated `making room for
  prompt cache entry, removing oldest entry` lines as it evicts to stay
  under the cap. An 8GB cache on top of this model's baseline footprint
  (which alone runs ~24GB+ on a 32GB box, see below) leaves no headroom for
  the desktop session, so this repo sets `LLAMA_CACHE_RAM=1024`.

Even with both fixed, the model's baseline footprint alone is substantial:
the `limited` deployment was observed at ~24GB RSS at idle right after
model load on a 31GB-RAM machine, before any conversation activity. That's
inherent to running a 22GB+ GGUF with several MoE layers CPU-resident
(`-ncmoe`), not something these two flags can fix - if you need more
desktop headroom than that leaves, the lever is raising `-ncmoe` further
(more VRAM used, more speed given up) or, if you're on a bigger card,
lowering `-ncmoe` isn't the direction that helps here since it *reduces*
CPU RAM in favor of VRAM.

As a second layer of protection independent of getting the above tuning
right, every `systemd/*.service` unit sets `MemoryHigh=`/`MemoryMax=`
(cgroup memory caps, so a runaway gets killed and restarted by systemd
instead of triggering the system-wide OOM killer) and `OOMScoreAdjust=500`
(makes the kernel prefer killing this process over your desktop apps in a
system-wide OOM, as a last resort). The specific numbers in each unit are
starting points, not measured for every profile - watch `systemctl --user
status llama-server-<profile>`'s peak memory column after real use and
adjust if it's consistently far from (or dangerously close to) the ceiling.

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
