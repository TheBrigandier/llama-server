# Changelog

## 2026-07-25 (later) - `limited` re-tuned against a real workload

The memory caps set earlier the same day were sized from an unrepresentative
test and **wedged the server for 8 hours overnight**. Re-measured properly.

- **The failure.** An overnight agent job reached an 88,591-token context.
  With `MemoryHigh=21G` and `MemorySwapMax=0`, the cgroup crossed the
  threshold with zero reclaimable page cache and no swap outlet, so the kernel
  could neither free memory nor OOM-kill cleanly - it spun in direct reclaim.
  Process stuck in state `D`, 27M `memory.events` `high`, no HTTP responses,
  `oom_kill` still `0`. Recovered live with `systemctl set-property --runtime`
  (raising the cap unstuck it without a restart; the client resumed as if
  nothing had happened).
- **Root cause of the bad number.** `21G`/`23G` came from a 3-branch x
  34k-token workload peaking at 18.74 GiB. A near-full 131072 context peaks at
  **20.39-21.16 GiB**. Sizing now uses the latter.
- **`MemoryHigh`/`MemoryMax` -> `23G`/`25G`** on `limited`: clears the real
  worst case with ~4.6GiB headroom, ~6GiB left for the desktop.
- **`MemorySwapMax` -> `4G`** (was `0`). Both extremes fail: unlimited lets
  the cgroup escape `MemoryMax` via zram, `0` allows the deadlock above. A
  bounded valve keeps the cap meaningful without permitting a hang.
- **`--cache-ram` -> `5120`** on `limited` (was `3072`). A ~125k-token branch
  is a ~4 GiB cache entry, so at 3072 it could not be cached at all and every
  branch switch reprocessed everything: **125,702 tokens / 190.25s**. At 5120
  the same switch cost **5 tokens / 0.32s**. Entry sizes measured at 2,896 MiB
  for ~88k tokens - far above what the ~11 KiB/token attention-KV figure
  implies, because entries also carry checkpoint and slot state.
- Validated end to end at a full 131072 context under the final caps:
  `oom_kill 0`, swap untouched, no deadlock, prefill unchanged (194s vs 193s).

`full-128k`/`full-256k` are **not** re-validated - they require
`multi-user.target` and could not be tested from a desktop session. They still
carry `MemorySwapMax=0`, which is now known to permit this deadlock.

## 2026-07-25

**Context checkpoints re-enabled - the 2026-07-23 change below was wrong.**

- `--ctx-checkpoints 0` was not "pure overhead with no tradeoff". Checkpoints
  are what lets the prompt cache restore a branch on this architecture:
  recurrent state can't be rewound, so with `0` the server recognises a
  cached prefix and reprocesses all of it anyway. Measured on `limited`
  (llama.cpp b10087), returning to a cached branch cost 11431 tokens /
  12.97s at `0` versus 25 tokens / 0.3s at any non-zero value. This is the
  slowdown that showed up after 2026-07-23.
- Set to `32` (llama-server's default) on `full-128k`/`full-256k` and `8` on
  `limited`. `4`, `8` and `32` measured identical in both benefit and memory
  - allocation is on demand, so the value is a ceiling, not a reservation.
- The original evidence was invalid: it inferred "never restored" from the
  absence of `checkpoint`/`restoring` log lines, but this build emits none at
  default verbosity even when restore demonstrably works. It also only
  benchmarked a growing single conversation, which reuses its prefix fine
  without checkpoints - the cost only appears on branch switches.
- `--cache-ram` sizing notes in README are flagged as needing re-validation:
  they were measured while branch restore was broken.
- `--cache-reuse` tested and documented as permanently inert here - the
  server refuses it (`cache_reuse is not supported by this context, it will
  be disabled`), since KV shifting isn't supported on recurrent layers.

**Memory safety - the caps were not actually capping anything.**

- `MemorySwapMax=0` added to all three units. Swap on this box is zram
  (compressed RAM, not disk) and cgroups default to `memory.swap.max=max`, so
  under pressure the kernel moved anon/shmem into zram, out of
  `memory.current` - `MemoryMax` never tripped, nothing restarted, and the RAM
  was still gone, charged outside the cgroup. This is the mechanism behind
  desktop-wide allocation failures (sound card disappearing, password manager
  unable to open its database) with `oom_kill` sitting at 0.
- `limited` ceilings lowered `25G`/`27G` -> `21G`/`23G`. It is the
  `graphical.target` profile *and* the most host-RAM-hungry (`ncmoe=33` keeps
  more MoE layers on CPU than the full profiles), so it was the one squeezing
  the desktop. Measured resting 16.24 GB, worst case 18.74 GB; the new caps
  clear that and leave ~8GB for the desktop. Verified free: prefill is
  identical to the old caps (46.1/45.7/45.2s vs 46.0/45.5/44.9s) with the
  cache still at a 6/6 restore rate.
- `full-128k`/`full-256k` ceilings left alone - they only run under
  `multi-user.target` with no desktop competing.
- `--cache-ram` characterised: it is a **cap, not a reservation**. Same
  workload allocated 2515 MiB under `8192` and 2550 MiB under `3072`; lowering
  it saves nothing until the working set crosses it, then fails abruptly
  (`1024` -> 0/6 branch restores). The README's older sizing narrative is
  corrected accordingly.

**systemd units** - `StartLimitIntervalSec`/`StartLimitBurst` added (a
persistent failure previously restarted forever, because `RestartSec=5` could
never fill systemd's default 10s/5 window), `RestartSec` raised to 30s, and
the inert `TimeoutStartSec=300` removed (it never covered model load under
`Type=simple`).

## 2026-07-23

**Memory stability** - `llama-server` was slowly eating RAM until it crashed
(and dragging desktop responsiveness down along the way):

- ~~Context checkpoints (`--ctx-checkpoints`) are known-broken upstream for
  this model's hybrid/recurrent architecture - created but never
  successfully restored, pure overhead. Disabled (`LLAMA_CTX_CHECKPOINTS=0`)
  in all three deployments.~~ **Superseded 2026-07-25: this was wrong and was
  reverted - see the entry above.** Checkpoints do restore, and disabling
  them broke prompt-cache branch restore.
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
- ~~Context checkpoints stay disabled - confirmed unrelated to the slowdown
  (the same full-reprocess pattern existed even before they were disabled,
  and zero checkpoint-restore log lines exist anywhere in this server's
  history, before or after).~~ **Superseded 2026-07-25.** They were very
  much related to the slowdown. The "zero log lines" check proved nothing -
  this build emits none even when restore works - and the surviving
  full-reprocess pattern was the branch-switch case that disabling
  checkpoints had itself broken.

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
