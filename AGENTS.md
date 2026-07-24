# AGENTS.md

Local llama.cpp `llama-server` setup for Qwen3.6-35B-A3B-MTP on a single
RTX 4070 (12GB VRAM) + 32GB RAM. See [README.md](README.md) for the
user-facing docs (deployments, setup, systemd usage) - read that first for
context, this file is about how to safely make changes here.

## Architecture in one paragraph

`scripts/llm-server.sh` has exactly **one built-in default configuration**
(the fastest single-GPU-only setup) and no concept of named profiles
internally - it does not take a `--profile` flag. Different configurations
("deployments": `full-128k`, `full-256k`, `limited`) exist entirely as
tunables files (`config/<name>.env.example`, staged by `install.sh` to
`~/.config/llama-server/<name>.env`) that the matching
`systemd/llama-server-<name>.service` passes via `--tunables-file`. This
was a deliberate simplification - a user should never need to edit
`llm-server.sh` or a `.service` file to change ncmoe/ctx-size/sampling/etc,
only the relevant `.env` file.

## Hard constraints - do not violate

- **Never commit `models/*.gguf`** or any other file under `models/` - it's
  a 22GB+ weight file, already gitignored. `models/.keep` is the one
  intentional exception (an empty placeholder so the directory itself
  exists after a clone) - don't delete it or add it to `.gitignore`. Don't
  add code that assumes a model is present unless clearly needed at runtime
  (it's fine for `--dry-run` /
  `--help` / arg-parsing to work without it, and `llm-server.sh` is written
  that way on purpose).
- **`--ctx-size` must stay within `[131072, 262144]`** (`MIN_CTX_SIZE` /
  `MAX_CTX_SIZE` in `scripts/llm-server.sh`, both enforced). Per the
  [model card](https://huggingface.co/unsloth/Qwen3.6-35B-A3B-MTP-GGUF),
  the model uses its context window for thinking and quality drops off
  below ~128k; 262144 is its native max. Don't add a deployment or example
  outside that range.
- **`--parallel` must be `1` whenever `--spec-type` is `draft-mtp`**
  (enforced in the script's validation step). The model card states `-np >
  1` and `--mmproj` aren't supported with MTP yet - don't add a deployment
  or example that combines them.
- **`--spec-draft-n-max` defaults to `4`**, not the model card's example
  value of `2` - this was tuned by testing on this model/hardware (good
  speedup at 4, accept rate falls off sharply at 5). Don't "fix" it back to
  match the card without new evidence.
- **`LLAMA_CTX_CHECKPOINTS=0` is set in every `config/*.env.example`**,
  overriding llama-server's own default (`32`) - context checkpoints are
  known-broken upstream on this model's hybrid/recurrent architecture
  (created but never successfully restored - see README's "Memory
  stability" section and the linked llama.cpp issues), confirmed against
  this repo's own logs (zero "checkpoint"/"restoring" lines ever, same
  full-reprocess pattern before and after disabling), so this is pure RAM
  overhead with no tradeoff. If an upstream fix lands, re-enabling and
  re-testing is reasonable - don't just revert silently.
- **`LLAMA_CACHE_RAM=8192` is set explicitly in every `config/*.env.example`**
  (matching llama-server's own default, not overriding it down). This repo
  briefly shipped `1024` under the assumption that shrinking it was a free
  memory-stability win - it wasn't: this repo's sequential-subagent
  workflow (single slot, `--parallel 1`) needs the orchestrator's branch
  and the active subagent's branch both resident in the prompt cache
  across each handoff, and 1024 MiB couldn't hold both, turning fast
  handoffs into 90+ second full reprocesses (measured: full-reprocess rate
  roughly doubled at matched request throughput). See README's "Memory
  stability" section for the per-branch cost calculation (derived from this
  GGUF's own architecture metadata: ~11 KiB/token, ~2.75GiB per max-256k
  branch) before changing this value - it's sized for ~3 resident branches,
  not picked arbitrarily. If you do need to trade cache size for desktop
  RAM, that's a real tradeoff to make deliberately (and adjust the systemd
  `MemoryHigh`/`MemoryMax` caps accordingly), not a default to "clean up."
- **Sampling defaults** (`temp=1.0, top_p=0.95, top_k=20,
  presence_penalty=1.5`) are always applied unless overridden - they come
  from the model card's "thinking mode" recommendation, not llama.cpp's
  generic built-in defaults. Keep them wired through the same
  defaults→tunables→secrets→env→CLI precedence as everything else if you
  touch them.
- **Never write real secrets into the repo.** The API key lives at
  `~/.config/llama-server/api-keys` (outside this directory, chmod 600,
  llama-server's own `--api-key-file` format - one key per line, not
  shell), passed to llama-server as a path via `--api-key-file` so key
  values are never read into `scripts/llm-server.sh` itself, never argv,
  never a process environment variable - see README's Secrets section for
  why (closes a `/proc/*/environ` exposure that an earlier, since-reverted
  version of this design had). `~/.config/llama-server/secrets.env` still
  exists for anything else sensitive (uncommon). `config/*.example` (both
  `config/*.env.example` and `config/api-keys.example`) are the only
  example/template files that should ever be committed - `.gitignore`
  guards the real ones, keep it that way if you touch it.
- **systemd units are user-level (`systemctl --user`) on purpose**, not
  system units in `/etc/systemd/system`. No `User=`/`Group=` directives,
  paths use `%h` instead of a hardcoded home dir, `[Install]` targets
  `default.target` (user managers don't have `multi-user.target`/
  `graphical.target`). This was an explicit user preference - don't
  "fix" it back to system units.
- **No `--profile` flag / `set_profile_defaults()` in the script, and no
  helper/wrapper script for switching deployments.** Both were built and
  explicitly rejected in favor of the tunables-file design above and the
  three unit files' `Conflicts=` directives (each conflicts with the other
  two, so starting one stops whichever else is running). The user wants to
  drive `systemctl --user` directly. Don't reintroduce either unless asked.
- **Tunables files are passed via `--tunables-file` (a CLI arg the script
  sources), not `EnvironmentFile=` in the unit.** This was also explicitly
  chosen: `EnvironmentFile=` doesn't expand `$HOME` and, without the
  optional `-` prefix, breaks the unit if the file doesn't exist yet (e.g.
  before `install.sh` has run) - `--tunables-file` degrades gracefully
  (prints a `note:` and falls back to built-in defaults) and correctly
  expands `$HOME` since the script `source`s it as real bash.

## Layout

```
install.sh                 stages api-keys + secrets.env + per-deployment .env files,
                            symlinks systemd units into ~/.config/systemd/user/,
                            daemon-reload. Safe to re-run - never overwrites existing
                            config files.
scripts/llm-server.sh       launcher: one built-in default + tunables file + secrets file
                            + api-keys file + env vars + CLI flags (that precedence
                            order, later wins - api-keys file is the exception, see
                            README's Secrets section)
systemd/*.service           user-level units, one per deployment, mutually Conflicts=,
                            each ExecStart passes --tunables-file for its deployment
config/api-keys.example     committed template for the API key file (llama-server's
                            own --api-key-file format, not shell)
config/*.env.example        committed templates: secrets file + one per deployment
models/                     gitignored weights, not otherwise touched by tooling here
example-configs/<agent>/    committed client configs for coding agents that talk to this
                            server (e.g. example-configs/opencode/opencode.json) - apiKey
                            fields must stay placeholders, see conventions below
```

## Conventions when editing `scripts/llm-server.sh`

- Precedence is built-in defaults → tunables file → secrets file → env vars
  → CLI flags (later wins). If you add a new tunable, thread it through
  all the layers the same way the existing ones are (see `NCMOE`/
  `CTX_SIZE`/`THREADS` for the pattern: declared with `"${LLAMA_X:-default}"`
  in the "Defaults" section *after* the tunables/secrets files are
  sourced, then a case arm in the CLI-parsing loop overwrites it last).
- Every new flag needs: a case arm in the parsing loop, a line in
  `usage()`, and an entry in the `LLAMA_*` env var list in both `usage()`
  and `README.md`. If it's something a deployment would plausibly want to
  override, add a commented example line to each `config/*.env.example`
  too.
- Validate with `--dry-run` before assuming a change works - it prints the
  resolved `llama-server` command without executing it, and doesn't
  require the model file to exist. Useful sanity checks after a change:

  ```sh
  ./scripts/llm-server.sh --dry-run --allow-no-api-key   # built-in default
  ./scripts/llm-server.sh --tunables-file config/full-256k.env.example --dry-run --allow-no-api-key
  ./scripts/llm-server.sh --tunables-file config/limited.env.example   --dry-run --allow-no-api-key
  ./scripts/llm-server.sh --tunables-file /tmp/does-not-exist.env --dry-run --allow-no-api-key  # must warn + fall back, not error
  ./scripts/llm-server.sh --ctx-size 100000 --dry-run --allow-no-api-key   # must fail (below min)
  ./scripts/llm-server.sh --ctx-size 300000 --dry-run --allow-no-api-key   # must fail (above max)
  ./scripts/llm-server.sh --parallel 2 --dry-run --allow-no-api-key       # must fail (draft-mtp default)
  ```

## Conventions when editing `systemd/*.service`

- Validate syntax with `systemd-analyze verify --user systemd/*.service`
  before calling a change done.
- Keep the three-way `Conflicts=` complete (each unit lists the other two)
  if you add, rename, or remove a deployment unit.
- These are symlinked (not copied) into `~/.config/systemd/user/` by
  `install.sh` / per README.md, so edits here take effect after
  `systemctl --user daemon-reload` without a reinstall step - don't add
  anything that requires copying instead.
- `ExecStart=` should pass `--tunables-file %h/.config/llama-server/<name>.env`
  - don't switch this to `EnvironmentFile=` (see hard constraints above).

## Conventions when editing `install.sh`

- Must stay idempotent: never overwrite an existing `api-keys`,
  `secrets.env`, or `<name>.env` (only `cp` if the destination doesn't
  exist yet) - a user's edits to their tunables (and their real API key)
  need to survive a reclone. The systemd symlinks and `daemon-reload` are
  fine to always re-run, since they're just pointers back into the
  checkout, not user-editable state.
- Test by actually running it (it's cheap and reversible - it only creates
  config scaffolding, never starts `llama-server`), then run it a second
  time to confirm the second run only prints "skip ... (already exists)"
  for the config files while still relinking + reloading the units.

## Conventions when adding a coding-agent config (`example-configs/`)

`example-configs/<agent-name>/` holds committed, ready-to-use client
configs for coding agents that talk to this server. `opencode/opencode.json`
is the reference example - follow its pattern for any new agent:

- **Sampling values come from the model card's published presets, not
  guesswork.** The card documents four: Thinking-general, Thinking-precise-coding,
  Instruct-general, Instruct-reasoning (see `README.md`'s "About the
  model" / "Sampling & MTP notes" for the exact numbers). If an agent's
  config needs different profiles than OpenCode's, still derive the
  sampling values from these same presets rather than inventing new ones.
- **Never put a real API key in a tracked file.** `apiKey` (or equivalent)
  must stay a placeholder like `"CHANGE-ME"` - real keys go through
  whatever secret-injection mechanism the agent supports (env var
  substitution, a local untracked override file, etc.), same principle as
  `config/*.env.example` vs `~/.config/llama-server/secrets.env`.
  `.gitignore` does *not* currently exclude `example-configs/**`, so
  nothing stops a real key from being committed here except discipline -
  check the diff before committing any file under this directory.
- **Don't trust field names or client passthrough behavior from docs
  alone - verify against a live server.** llama.cpp's field is
  `repeat_penalty`, not the `repetition_penalty` this file originally
  shipped with (silently ignored by the server, found only by testing).
  Separately, whether a client actually forwards non-standard OpenAI
  fields (`top_k`, `min_p`, `chat_template_kwargs`, `repeat_penalty`) to
  the request body is client-specific and has had real bugs in the wild
  (OpenCode has closed issues about custom-provider option passthrough).
  The validation method used for `opencode.json`: temporarily set
  distinctive sampling defaults in the active deployment's tunables file
  (values that don't match any profile in the config being tested),
  restart the service, fire one real request through the client, then
  compare `/slots`' actual applied params against both the distinctive
  server defaults and the profile's intended values - a match against the
  profile that differs from the server default is unambiguous proof the
  field reached the server. A match that's merely *consistent* with the
  server's own default proves nothing (this tripped us up once - `/props`
  alone isn't sufficient, it only shows the server's own CLI-baked
  baseline). Revert the tunables file back afterward.
- **Context size is a static, per-profile value, not auto-detected.** No
  OpenAI-compatible client we've checked queries the server for its actual
  loaded context (llama-server exposes it via `/props`, but that's a
  llama.cpp-specific endpoint, not part of the OpenAI API surface clients
  implement against). Mirror this repo's own `128k`/`256k` deployment split
  rather than picking one static number, unless a specific agent is proven
  to auto-detect it.

## Adding a new deployment

If asked to add a deployment (e.g. a different quant, a different model
entirely): add `config/<name>.env.example` (copy an existing one and
adjust the values that differ), add a matching
`systemd/llama-server-<name>.service` that `Conflicts=` with *all*
existing deployment units (update their `Conflicts=` lines too, not just
the new one's) and passes `--tunables-file %h/.config/llama-server/<name>.env`,
add `<name>` to the `DEPLOYMENTS` array in `install.sh`, and document it in
the deployments table in `README.md`. Nothing in `llm-server.sh` itself
needs to change unless the new deployment needs a flag the script doesn't
support yet.
