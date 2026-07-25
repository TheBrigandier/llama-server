# todo.md — follow-ups for the 64GB RAM upgrade

This box currently runs on **31.25 GiB usable RAM only because a RAM stick
failed**. Nearly every memory compromise in this repo is a consequence of that,
not a considered design choice. When the full 64GB is back, the items below are
worth revisiting — in priority order.

Delete this file once the upgrade is done and these are worked through.

Everything here is measured; see [`testing/README.md`](testing/README.md) for
how to re-run any of it, and the main [README](README.md)'s "Memory stability"
and "If you add host RAM (32GB → 64GB)" sections for the reasoning.

---

## 0. First, re-measure — don't scale these numbers by hand

```sh
sudo systemctl isolate multi-user.target     # full-* need the GPU free; SSH in
cd testing
MEAS_HIGH=<near host max> MEAS_MAX=<host max> MEAS_SWAP=6G ./measure-profile.sh full-128k
MEAS_HIGH=<near host max> MEAS_MAX=<host max> MEAS_SWAP=6G ./measure-profile.sh full-256k 250000
```

The **resting** footprints won't move (13.52 / 16.05 / 16.24 GiB for
`full-128k` / `full-256k` / `limited`) — they're weights and fixed
allocations. Every ceiling *derived* from them should be redone.

Reference numbers to beat, all 2026-07-25, `multi-user.target`:

| profile | ncmoe | ctx | cache-ram | resting | peak unreclaimable | branch restore |
|---|---:|---:|---:|---:|---:|---|
| `full-128k` | 27 | 131072 | 8192 | 13.52 GiB | **19.38 GiB** | ✅ `reproc=5`, 0.24s |
| `full-256k` | 32 | 262144 | 8192 | 16.05 GiB | 22.22 GiB¹ | ❌ `reproc=250099`, 384.62s |
| `limited` | 33 | 131072 | 5120 | 16.24 GiB | 20.39–21.16 GiB | ✅ 5 tok, 0.32s |

¹ Understates the worst case — the cache was nearly empty *because* the 250k
entry was rejected. Real worst case with a full cache is ~26 GiB.

---

## 1. `full-256k` `--cache-ram` — the actual win

**The problem today:** a cache entry costs ~36 KiB/token, so a full 262144
branch is ~9.0 GiB but `cache-ram=8192` caps entries at 8 GiB. Branches above
**~228k tokens** are rejected outright and every switch back is a full
reprocess (measured: 250,099 tokens / **384.62s**).

Server says so directly:
```
W srv alloc: - prompt state size 8977.270 MiB exceeds cache size limit 8192.000 MiB, skipping
```

**Why it can't be fixed now:** tested at `cache-ram=10240` on 32GB and it
deadlocked the machine — peak 26.67 GiB unreclaimable, swap pinned at its 4G
bound, 166k `high` events, `oom_kill` 0, system-available RAM down to
**141 MiB**, process state `D` in `mem_cgroup_handle_over_high`. Recovered with
`systemctl --user stop`, no reboot.

**On 64GB:** raise to **~18432** (holds two full 262144 branches) and re-run
`measure-profile.sh full-256k 250000`. Pass criterion is the `ctx_fill` final
line showing a small `reproc` instead of a full reprocess. Then raise
`MemoryHigh`/`MemoryMax` to match — a bigger cache needs matching ceilings or
the cap becomes the thing that throttles.

Also drop the "ACCEPTED, not an oversight" paragraph in
`config/full-256k.env.example` and the corresponding block in
`systemd/llama-server-full-256k.service` once this is fixed.

## 2. Make `MemoryMax` a working safety net again

Today `full-256k` ships `MemoryMax=30G` on a 31.25 GiB box — **it can never
fire before global exhaustion.** We watched exactly that: the cgroup wedged at
26.67 GiB with 141 MiB left system-wide and `oom_kill` still `0`. It's left at
30G only because `cache-ram=8192` self-limits the worst case to ~26 GiB;
tightening it enough to fire would put `MemoryHigh` within ~1 GiB of that worst
case, which is the over-tightening that caused the 8-hour deadlock.

With real headroom, set all three to peak + ~4 GiB (`MemoryHigh` ≈
`MemoryMax − 2G`) so the cap is a genuine backstop rather than nominal.

Keep `MemorySwapMax=4G`. Bounded and non-zero is still correct at any RAM size —
unlimited defeats `MemoryMax` when swap is zram, `0` permits the deadlock.

## 3. `limited` — reconsider whether it still needs to be the hungriest

`limited` is the `graphical.target` profile and, despite the name, the most
host-RAM-hungry of the three (`ncmoe=33` keeps the most MoE layers on CPU
because the GPU is shared with a desktop). Its 23G/25G band is narrow in both
directions: 25G/27G starved the desktop into system-wide allocation failures;
21G/23G caused the 8-hour deadlock.

With more host RAM that band gets much less tight. Re-measure and widen. Note
`ncmoe` itself should **not** change — it's a VRAM decision (see below).

## 4. Possibly worth testing, unrelated to RAM

- **`ncmoe` A/B on `full-128k`.** It prefills 125,701 tokens in 151s at
  `ncmoe=27` vs `limited`'s ~193s at 33. Whether 24/25 fits in 12GB VRAM at
  131072 ctx and buys more is untested. This is **VRAM**-bound, so the RAM
  upgrade doesn't change it — it's just never been tried.
- **Re-validate the historical `1024`-vs-`8192` `--cache-ram` comparison.**
  Flagged in README: those reprocess rates were really observed, but they were
  measured while `--ctx-checkpoints` was `0`, i.e. while branch restore was
  broken, so *why* they moved was never established.

---

## Do NOT change on more RAM

These are not RAM-bound and re-tuning them is wasted effort:

- **`-ncmoe` (27 / 32 / 33)** — set by the 12GB VRAM budget. More host RAM does
  not let you move MoE layers back onto the GPU.
- **Prefill throughput** (~510–830 tok/s) — compute-bound. A 250k context still
  takes ~390s to fill the *first* time; more RAM only avoids *re*processing it.
- **`--ctx-checkpoints` (32 / 8)** — a demand-allocated ceiling, already
  non-binding. `4`, `8` and `32` all cost the same (1190 MiB). Must stay
  non-zero.
- **`--cache-reuse`** — permanently inert here; the server refuses it
  (`cache_reuse is not supported by this context`) because KV shifting isn't
  supported on recurrent layers. Don't retry.
- **`--parallel 1`** — required by `--spec-type draft-mtp`.
