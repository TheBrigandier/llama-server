# Changelog

## 2026-07-23

**Memory stability** - `llama-server` was slowly eating RAM until it crashed
(and dragging desktop responsiveness down along the way):

- Context checkpoints (`--ctx-checkpoints`) are known-broken upstream for
  this model's hybrid/recurrent architecture - created but never
  successfully restored, pure overhead. Disabled (`LLAMA_CTX_CHECKPOINTS=0`)
  in all three deployments.
- Prompt-cache RAM (`--cache-ram`) defaulted to 8GB, leaving no headroom on
  a 32GB desktop box. Capped to 1GB (`LLAMA_CACHE_RAM=1024`).
- Added `MemoryHigh=`/`MemoryMax=`/`OOMScoreAdjust=` to all three systemd
  units as a safety net, so any future runaway gets killed and restarted
  by systemd instead of taking the whole desktop session down.
- Documented all of it in README's new "Memory stability" section.

**API key exposure** - the key was leaking in plaintext via `ps`,
`systemctl status`, and `--dry-run` output (all read process argv):

- Moved off `--api-key KEY` on the command line entirely.
- Landed on `--api-key-file`, llama-server's own file-based auth mechanism:
  the key now lives in a dedicated, 600-permissioned file
  (`~/.config/llama-server/api-keys`) and is only ever read from disk by
  llama-server itself - never argv, never a process environment variable
  (which would still be readable via `/proc/<pid>/environ` by anything
  else running as the same user).
- `install.sh` auto-migrates existing installs: detects a real key still
  sitting in the old `secrets.env`, moves it into `api-keys`, and backs up
  the original line before removing it.
- `--api-key`/`LLAMA_API_KEY` remain as a secondary, additive override for
  one-off testing.

**Also:** if you're upgrading from before this change and a key was ever
displayed in a terminal, log, or transcript, treat it as burned and
rotate it - see README's Secrets section.

**Follow-up, same day: `--cache-ram` correction** - the `1GB` cap above
turned out to be wrong, not just conservative:

- This repo's sequential-subagent agentic workflow (single slot,
  `--parallel 1`) needs the orchestrator's branch and the active subagent's
  branch both resident in the prompt cache across each handoff. At 1GB the
  cache couldn't hold both, so every handoff evicted one to make room for
  the other - turning a few-second cache hit into a 90+ second full
  reprocess. Measured directly in this server's own logs: full-reprocess
  rate roughly doubled (6.65% -> 12.5% of requests) after the cut, at
  matched request throughput.
- Root-caused with an exact per-branch memory cost, computed from this
  GGUF's own architecture metadata rather than guessed: only ~10-11 of 41
  layers are full attention (`full_attention_interval=4`, the rest are
  fixed-size recurrent/SSM state), giving ~11 KiB/token and ~2.75GiB per
  max-256k-context branch.
- `LLAMA_CACHE_RAM` restored to `8192` (llama-server's own default, not a
  new override) - comfortably covers ~3 resident max-context branches.
  Turns out the upstream default was already sized about right for this
  kind of workload.
- `MemoryHigh=`/`MemoryMax=` raised on all three systemd units to match the
  new worst-case ceiling (baseline + up to ~8GB cache).
- Context checkpoints stay disabled - confirmed unrelated to the slowdown
  (the same full-reprocess pattern existed even before they were disabled,
  and zero checkpoint-restore log lines exist anywhere in this server's
  history, before or after).

## 2026-07-24

**`--cache-ram`/memory caps split per-deployment** - raising `cache-ram` to
8192 on all three deployments (yesterday's fix) worked for handoff speed,
but real usage showed a new problem: `full-128k`'s (and presumably
`full-256k`'s) `MemoryHigh` ceiling was too tight for that cache size -
`memory.events`' `high` counter had climbed into the thousands within
~2 hours of normal use, repeatedly throttling the cgroup into (fast,
zram-backed) swap. Not a crash (`MemoryMax`/`oom` never fired), but
frequent, avoidable pressure from the ceiling being sized too close to
what `cache-ram=8192` actually needs.

- `full-128k`: `MemoryHigh`/`MemoryMax` raised `26G/28G` -> `28G/30G`.
- `full-256k`: raised only `28G/30G` -> `29G/30G` (smaller bump on
  purpose - total system RAM is 31Gi, and going further would leave so
  little floor that the cap would stop being a meaningful safety net for
  this profile).
- `limited`, by contrast, got its cache *shrunk* rather than its ceiling
  raised: this profile is only ever run at 128k context with strictly
  sequential (never parallel) agents, so it only ever needs ~2 resident
  branches, not the ~3+ the other two are provisioned for.
  `LLAMA_CACHE_RAM` set to `3072` (down from `8192`) and
  `MemoryHigh`/`MemoryMax` first lowered to `22G/24G` to match - giving
  that RAM back to the desktop session `limited` is specifically meant to
  share with, rather than reserving headroom it doesn't need.
- **That `22G/24G` was wrong, caught within the same session**: it sat
  the cgroup flush against `MemoryHigh` with zero cushion, so `memory.
  events`' `high` counter climbed into the tens of thousands within ~2
  minutes at idle - and a flat reading at exactly the ceiling turned out to
  be `memory.high` itself forcibly capping growth via reclaim, not the real
  resting size (a methodological trap - see README's "Memory stability"
  section). Raised to `25G/27G` and it settled on its own at ~17-18GiB with
  zero throttling, matching this repo's original baseline estimate from
  before the tight cap muddied the measurement.
- Per-branch cost math (from README's "Memory stability" section) now
  shown per-deployment rather than a single number, since `full-256k`'s
  max-256k branches (~2.75GiB each) cost roughly double `limited`'s
  max-128k branches (~1.4GiB each).
