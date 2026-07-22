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

## Secrets

The API key (and anything else sensitive) is kept **outside this repo**, at:

```
~/.config/llama-server/secrets.env
```

`install.sh` stages this from `config/llama-server.env.example` with mode
`600` if it doesn't already exist. To do it by hand instead:

```sh
mkdir -p ~/.config/llama-server
chmod 700 ~/.config/llama-server
cp config/llama-server.env.example ~/.config/llama-server/secrets.env
chmod 600 ~/.config/llama-server/secrets.env
$EDITOR ~/.config/llama-server/secrets.env   # set LLAMA_API_KEY
```

`llm-server.sh` sources this file automatically (it's a plain shell script,
so it can set any `LLAMA_*` variable, not just the key) and warns if its
permissions are looser than `600`. The server binds to `0.0.0.0`, so the
script refuses to start without an API key unless you pass
`--allow-no-api-key` explicitly.

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
