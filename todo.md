# todo.md — llama-server

All four `cattle-app` handoff items are done, plus the `ctx-checkpoints`
regression they turned up. Everything is uncommitted by request.

1. **Restart loop** — fixed. All three units now carry `StartLimitIntervalSec`
   / `StartLimitBurst` and `RestartSec=30`.
2. **`TimeoutStartSec=300`** — dropped from all three; comment now records why
   it was inert and warns the inherited 15s default becomes live if `Type=`
   changes.
3. **`--cache-reuse`** — measured, refused by the server
   (`cache_reuse is not supported by this context, it will be disabled`).
   Documented in README as permanently inert here.
4. **Doc corrections** — branch budget now names title/summary traffic;
   sampling flags documented as per-request defaults clients override.
5. **`ctx-checkpoints` regression** — found and fixed, see below.

---

## What the `ctx-checkpoints` measurement actually showed

`LLAMA_CTX_CHECKPOINTS=0` was set on 2026-07-23 as "pure overhead, no
tradeoff". It was the cause of the post-2026-07-23 slowdown.

Checkpoints are the mechanism the prompt cache needs to *resume* a branch.
Recurrent state can't be rewound, so with `0` the server recognises a cached
prefix and then reprocesses all of it anyway. Measured on `limited`, b10087,
alternating two conversations (the orchestrator↔subagent case):

| `--ctx-checkpoints` | return to cached branch | prefill | anon growth |
|---:|---|---|---|
| `0` | 11431 / 11431 tokens | 12.97 s | 472 MiB |
| `4` | 25 tokens | 0.31 s | 1190 MiB |
| `8` | 25 tokens | 0.26 s | 1190 MiB |
| `32` | 25 tokens | 0.29 s | 1190 MiB |

Only `0` differs. `N` is a **ceiling, not a reservation** — allocation is on
demand, which is why 4/8/32 cost the same.

**Applied:** `32` on `full-128k`/`full-256k` (llama-server's default), `8` on
`limited` (tighter bound for the desktop-sharing profile; its documented
working set is exactly the 2 branches this test covers). Set in both
`config/*.env.example` and the live `~/.config/llama-server/*.env`.

**Two traps that made the original wrong conclusion look solid** — both now
written into `AGENTS.md` so they don't recur:

- An append-only conversation reuses its prefix fine *without* checkpoints
  (only turn 2 suffers: 20.2% of tokens reprocessed vs 18.4% with them on).
  Benchmarking a single growing chat hides the entire problem.
- "No `checkpoint`/`restoring` log lines exist" proved nothing — this build
  emits none at default verbosity even when restore provably works.

## Verified on the live config

`limited` restarted on `ctx-checkpoints=8`: branch restore confirmed
(25 / 25 / 18 tokens, ~0.3 s). Footprint against its 25G/27G ceilings:

```
anon           1.5 GB   prompt cache + checkpoints
shmem         15.8 GB   model weights (swap-only, NOT page cache)
inactive_file  6.5 GB   redundant page cache from --no-mmap reading the GGUF
memory.current 23.9 GB  peak 25.0 GB
swap.current   0.16 GB  oom_kill 0
```

The `memory.events` `high` counter climbs into the tens of thousands, but
that is the kernel dropping the redundant `inactive_file` copy — free, and
not a sign the ceiling is too tight. Swap and OOM counters stay ~0. No
ceiling change needed.

---

## `--cache-ram` validated (and the desktop-crash cause found)

Re-measured with checkpoints on. **`--cache-ram` is a cap, not a reservation**
— the same 3-branch workload allocated 2515 MiB under an `8192` ceiling and
2550 MiB under `3072`. Lowering it saves nothing until the working set crosses
it, then fails abruptly:

| `cache-ram` | restore | evictions | anon | behaviour |
|---:|---|---:|---:|---|
| 8192 | 6/6 | 0 | 2515 MiB | cap never reached |
| 3072 | 6/6 | 0 | 2550 MiB | fits, ~500 MiB spare |
| 1024 | 0/6 | 7 | 1796 MiB | thrashing |
| 512 | 0/6 | 0 | 795 MiB | nothing cacheable |

So there was no memory to save here. Left at `3072`/`8192`.

**The actual cause of the desktop instability** (sound card vanishing,
1Password unable to open its DB — kernel-level allocation failures):

1. `limited` is the `graphical.target` profile *and* the most host-RAM-hungry
   (`ncmoe=33` > full-128k's 27), yet ran with `25G`/`27G` ceilings on a 31Gi
   box — ~4GB left for the whole desktop.
2. **`MemoryMax` could not bind.** Swap is zram (compressed RAM) with
   `memory.swap.max=max`, so under pressure the cgroup pushed pages into zram,
   out of `memory.current`. `MemoryMax` never tripped, nothing restarted, and
   the RAM was still consumed — charged outside the cgroup.

**Fixed:** `MemorySwapMax=0` on all three units (makes `MemoryMax` real);
`limited` lowered to `21G`/`23G`. Measured resting 16.24 GB, worst case
18.74 GB, so the cap clears it with ~4GB spare and leaves ~8GB for the
desktop. `full-*` ceilings untouched — they only run under
`multi-user.target` with nothing competing.

**Verified free:** prefill under the new caps is 46.1/45.7/45.2s vs
46.0/45.5/44.9s under the old ones (controlled A/B via a temporary drop-in),
with the cache still at 6/6 restores, `oom_kill 0`, `swap.current 0`.

## Still open / worth knowing
- **`StartLimit` was loosened to `300s`/`5`** after the initial `600s`/`3`
  blocked a legitimate tuning session on the fourth restart (manual restarts
  count toward the limit). Revert to `600`/`3` if you prefer strictness over
  iteration comfort.
- ~~**Config drift:** `config/limited.env.example` ships `LLAMA_NCMOE=38`~~
  **Resolved:** the example now ships `33`, matching the live file. `33` is
  correct — there is VRAM headroom for it during normal desktop use, and it
  means less host RAM and faster generation. This mattered for safety too: the
  16.24 GB resting footprint the new memory ceilings are sized against was
  measured at `ncmoe=33`, so a reclone installing `38` would have pushed more
  weight into host RAM than those caps assume.
- Repro scripts are in the session scratchpad (`branch_switch.py`,
  `ckpt_sweep.py`, `gguf_meta.py`) — copy them somewhere durable if you want
  to re-run any of this.
