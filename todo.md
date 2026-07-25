# todo.md — llama-server tuning handoff

Working notes for continued tuning. Written to be picked up by a fresh session
(likely Claude Code on the CLI, to allow `multi-user.target` testing).

**Everything below is uncommitted** unless you've since committed it. Delete
this file once `full-128k` and `full-256k` are validated.

---

## 1. Current state

| profile | ncmoe | ctx | cache-ram | ctx-checkpoints | MemoryHigh | MemoryMax | MemorySwapMax | validated? |
|---|---:|---:|---:|---:|---:|---:|---:|---|
| `limited` | 33 | 131072 | **5120** | 8 | **23G** | **25G** | **4G** | **yes** — full 131k context |
| `full-128k` | 27 | 131072 | 8192 | 32 | 28G | 30G | 4G | **no** — caps provisional |
| `full-256k` | 32 | 262144 | 8192 | 32 | 29G | 30G | 4G | **no** — caps provisional |

Repo `config/*.env.example` and live `~/.config/llama-server/*.env` are in sync
on every functional line (comments differ only where noted).

**Target constraint:** `full-128k`/`full-256k` require `multi-user.target` —
the GPU must be free. They will not load from a desktop session, and because
each unit `Conflicts=` the other two, a failed start also stops `limited`.
`limited` is the `graphical.target` profile and, despite the name, the most
host-RAM-hungry (higher `ncmoe` = more MoE layers on CPU).

---

## 2. What was measured, and what it overturned

### ctx-checkpoints — must be non-zero
Was `0` everywhere on the belief that checkpoints never restore on this hybrid
architecture. **False.** Checkpoints are what lets the prompt cache restore a
branch; recurrent state can't be rewound, so with `0` there is nothing to
resume from.

| `ctx-checkpoints` | branch restore | anon delta |
|---:|---|---:|
| 0 | fails — full 11–14k reprocess, 13–16s | 472 MiB |
| 4 / 8 / 32 | 25 tok, ~0.3s | 1190 MiB (identical) |

`N` is a **ceiling, not a reservation** (demand-allocated), which is why 4, 8
and 32 cost the same. The original wrong conclusion came from two bad tests:
an append-only chat reuses its prefix fine even at `0` (only turn 2 suffers),
and "no `checkpoint`/`restoring` log lines exist" proves nothing — this build
emits none at default verbosity even when restore provably works.

### cache-ram — a cap, not a reservation, and 3072 was silently broken
Same workload allocated 2515 MiB under an `8192` ceiling and 2550 MiB under
`3072`. Lowering it frees nothing until the working set crosses it, then fails
abruptly.

Cache entries are far larger than the ~11 KiB/token attention-KV figure
implies, because they also carry checkpoint and slot state:

| branch | entry size |
|---:|---:|
| 34k tok | ~838 MiB (only ~364 MiB attention KV) |
| ~88k tok | 2,896 MiB |
| ~125k tok | ~4 GiB |

At `3072` a single ~125k-token branch **exceeds the whole cache**, so it is
never stored: returning to it reprocessed **125,702 tokens / 190.25s**. At
`5120`: **5 tokens / 0.32s**. Hence `limited` → 5120.

### The 8-hour deadlock (root cause of the overnight hang)
`MemoryHigh=21G` + `MemorySwapMax=0` was sized from a 3×34k-token test peaking
at 18.74 GiB. A real job hit an **88,591-token** context. With no reclaimable
page cache left *and* no swap outlet, the cgroup could neither free memory nor
be cleanly OOM-killed — the kernel spun in direct reclaim for 8 hours:
process state `D`, 27M `memory.events` `high`, zero HTTP responses,
`oom_kill` still `0`.

Recovered **live, without restarting**, via
`systemctl --user set-property --runtime ... MemoryHigh=23G MemoryMax=25G MemorySwapMax=4G`.
OpenCode resumed as if nothing had happened.

**`MemorySwapMax` must be bounded — both extremes fail.** Unlimited (cgroup
default) lets the kernel push pages into zram (compressed RAM, not disk), out
of `memory.current`, so `MemoryMax` never trips while the RAM is still
consumed — that caused desktop-wide allocation failures (sound card vanishing,
1Password unable to open its DB) with `oom_kill 0`. `0` permits the deadlock
above. `4G` keeps total charge bounded at `MemoryMax + 4G` with an escape valve.

### `limited` measured numbers (2026-07-25)
```
resting unreclaimable (anon+shmem)          16.24 GiB
peak, 125,701-tok ctx + 2nd branch     20.39–21.16 GiB
headroom under the 25G cap                   ~4.6 GiB
desktop left                        ~6 GiB (never below 6.6 Gi observed)
validation      oom_kill 0, swap untouched, prefill 194s vs 193s
```

---

## 3. Measurement tooling

Lives in **`~/.config/llama-server/testing/`** (outside the repo deliberately,
same rationale as the tunables files; move into the repo if you want it
committed).

| file | purpose |
|---|---|
| `measure-profile.sh <profile> [target_tokens]` | end-to-end: raises caps (runtime only), restarts, samples, drives context, prints peak, reverts |
| `memsample.sh <profile>` | standalone sampler; writes `peaks-<profile>.txt` |
| `ctx_fill.py` | grows one conversation to `TARGET_TOKENS`, then layers a 2nd branch |
| `cacheram_test.py` | 3-branch cycle; reports restore hit rate (for cache-ram sizing) |
| `branch_switch.py` | 2-branch A/B/A switch (for ctx-checkpoints sizing) |
| `gguf_meta.py <model.gguf>` | dumps GGUF architecture metadata, no model load |

**Measure `anon`+`shmem`, never `memory.current` alone.** The model's host-side
weights are in **shmem**, and `memory.current` is dominated by page cache from
reading a 22GB GGUF under `--no-mmap`. `anon` alone hides the model (~0.5 GiB
at rest vs 16.24 GiB real); `memory.current` overstates it.

A climbing `memory.events` `high` — even `max` — counter is **not** by itself a
problem: that's free page-cache reclaim, and throughput was measurably
identical with the counter in the tens of thousands. The reading that *is*
alarming: unreclaimable approaching `MemoryMax` with page cache at zero. That's
the deadlock precondition. Judge by `anon+shmem`, `memory.swap.current`,
`oom_kill`.

---

## 4. Next: validate `full-128k`, then `full-256k`

Both need a session that survives leaving `graphical.target` — a TTY, or SSH
from another machine.

```sh
sudo systemctl isolate multi-user.target      # desktop goes away

cd ~/.config/llama-server/testing
./measure-profile.sh full-128k                # ~118k target, 131072 ctx
./measure-profile.sh full-256k 250000         # near-full for 262144 ctx
```

Each run takes roughly 5–8 minutes (model load ~70–90s, context fill ~200s at
~600 tok/s prefill, plus the branch phase).

**Then size from the output:**
- `MemoryMax` ≥ peak unreclaimable **+ ~4 GiB** headroom.
- `MemoryHigh` ≈ `MemoryMax − 2G`.
- Under `multi-user.target` there's no desktop to protect, so ceilings can stay
  high — but `full-256k` at `30G` on a 31Gi box leaves ~1 GiB, which is thin
  even with nothing else running. Expect its 262144 ctx to need more than
  `full-128k`: the KV cache is allocated for the full `n_ctx` up front.
- Keep `MemorySwapMax=4G`.

**Pass criteria:** `oom_kill 0`, no process in state `D`, `/health` answers
promptly throughout, and the `ctx_fill` branch-switch line shows a small
`reproc` (cache restoring) rather than a full reprocess.

**`cache-ram` for `full-256k` is the open question.** Both full profiles ship
`8192`. If a ~250k-token branch produces an entry near ~8 GiB — plausible, given
~4 GiB at 125k — then `8192` has exactly the `limited`-at-3072 problem: one
branch won't fit and every switch is a full reprocess (which at 250k would be
~6 minutes). Watch the branch-switch line specifically; raise `cache-ram` if
`reproc` comes back large, and re-check the ceiling afterwards.

Afterwards: `sudo systemctl isolate graphical.target` and confirm `limited`
comes back (`systemctl --user status llama-server-limited`).

---

## 5. Pitfalls hit during this work

- **`pgrep -f` / `pkill -f` match your own shell** when the pattern appears in
  the command line — killed the session twice. Use a PID file, or
  `ps -eo pid,args | awk '/pattern/ && !/awk/'`.
- **`systemctl set-property --runtime` survives a service restart.** It writes a
  drop-in under `/run/user/<uid>/systemd/user.control/` that lasts until reboot.
  Clear it with `systemctl --user revert <unit>` — restarting is not enough,
  and you'll silently measure under the wrong caps.
- **`StartLimitBurst` counts manual restarts.** Currently 5 per 300s (was 3 per
  600s, which blocked a tuning session on the 4th restart). Clear a tripped
  limit with `systemctl --user reset-failed <unit>`.
- **`Conflicts=`** means starting any profile stops the other two — including a
  profile that then fails to load.
- **Don't compare timings across sessions.** A "14% prefill regression" I
  attributed to tighter caps disappeared under a controlled A/B via a temporary
  drop-in. Always A/B in the same sitting.

---

## 6. Still open

- `full-128k` / `full-256k` ceilings unvalidated (section 4). Marked provisional
  inline in both unit files.
- **`--cache-ram` sizing narrative in README** is corrected for `limited` but
  the original 1024-vs-8192 comparison it grew from was measured while
  checkpoints were `0`, i.e. while branch restore was broken. The reprocess
  rates were real; *why* they moved is not established. Flagged inline.
- `--cache-reuse` is permanently inert here — server refuses it
  (`cache_reuse is not supported by this context, it will be disabled`), since
  KV shifting isn't supported on recurrent layers. Documented; don't retry.
- `limited` is under extended real-use testing by the user as of 2026-07-25.
  If it wedges again: check `oom_kill` (should be 0), process state (`D` = the
  reclaim deadlock), and whether `anon+shmem` reached `MemoryMax`. The live
  rescue is `set-property --runtime` with higher caps — no restart needed, and
  in-flight client requests survive.
