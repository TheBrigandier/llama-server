# testing/ — measurement apparatus

Tools for deriving this repo's tunables from measurement rather than guesswork:
`--cache-ram`, `--ctx-checkpoints`, and the systemd `MemoryHigh`/`MemoryMax`/
`MemorySwapMax` caps.

**These numbers do not transfer between machines.** Everything in the main
[README](../README.md) was measured on one specific box — RTX 4070 (12GB VRAM),
31.25 GiB usable RAM, `Qwen3.6-35B-A3B-MTP-UD-Q4_K_XL`. Different VRAM, RAM, or
quant changes all of it. The *method* transfers; the values don't. If you're
adapting this repo to your own hardware, run these and use your own output.

## Prerequisites

- A running `llama-server` from this repo's systemd units (`systemctl --user`).
- `python3` (standard library only — no pip install).
- cgroup v2 (any current Linux). `mount | grep cgroup2` should show `/sys/fs/cgroup`.
- The memory scripts read `/sys/fs/cgroup/.../<unit>/memory.*`, so they need
  the server to be running **as a systemd unit**, not a bare foreground process.

Nothing here needs root. `measure-profile.sh` uses `systemctl --user
set-property --runtime`, which is unprivileged.

## Quick start on a new machine

```sh
cd testing

# 1. What does the model itself say? (no model load, reads GGUF header only)
./gguf_meta.py ../models/your-model.gguf

# 2. Is branch restore working at all? ~2 minutes.
./branch_switch.py "baseline"

# 3. Is --cache-ram big enough for your working set? ~5 minutes.
BRANCH_WORDS=7000 ./cacheram_test.py "cache-ram=8192"

# 4. Full memory sizing run. ~5-15 min depending on target.
MEAS_HIGH=30G MEAS_MAX=31G MEAS_SWAP=6G ./measure-profile.sh limited 118000
```

Step 4 is the one that produces the ceilings. Set `MEAS_*` near the top of what
your host has — see "Raise the caps before measuring" below.

If your server isn't on `127.0.0.1:8080`, or your key isn't at
`~/.config/llama-server/api-keys`:

```sh
export LLAMA_TEST_HOST=10.0.0.5 LLAMA_TEST_PORT=8080
export LLAMA_TEST_API_KEY_FILE=/path/to/api-keys   # or LLAMA_TEST_API_KEY=sk-...
```
A server started with `--allow-no-api-key` needs neither.

## The scripts

| file | purpose |
|---|---|
| `measure-profile.sh <profile> [target_tokens]` | end-to-end: raises caps (runtime only), restarts, samples, drives context, prints peak, reverts |
| `memsample.sh <profile>` | standalone sampler; writes `peaks-<profile>.txt`. Run alongside a real workload to profile actual use |
| `ctx_fill.py` | grows one conversation to `TARGET_TOKENS`, then layers a 2nd branch. The memory-sizing workload |
| `cacheram_test.py` | 3-branch cycle; reports restore hit rate. The `--cache-ram` sizing test |
| `branch_switch.py` | 2-branch A/B/A switch. The `--ctx-checkpoints` sizing test |
| `gguf_meta.py <model.gguf>` | dumps GGUF architecture metadata, no model load |
| `_common.py` | shared endpoint/auth plumbing for the Python scripts |

Outputs (`peaks-*.txt`, `*.log`, `run-*.out`) are gitignored.

## How to read the numbers

### Memory: measure `anon`+`shmem`, never `memory.current` alone

The model's host-side weights live in **shmem**, and `memory.current` is
dominated by page cache from reading a 22GB GGUF under `--no-mmap`. On the
reference box: `anon` alone reports ~0.5 GiB at rest against 16.24 GiB real;
`memory.current` overstates it by ~6 GiB. **`anon`+`shmem` is what a hard cap
must actually clear** — that's the column `memsample.sh` calls `UNRECL_GiB`.

### A climbing `high` counter is not, by itself, a problem

`memory.events`' `high` counter can reach the tens of thousands while
throughput is *measurably identical* to looser caps — that's free page-cache
reclaim at the ceiling. Judge by `anon`+`shmem` against the cap,
`memory.swap.current`, and `oom_kill`.

The reading that **is** alarming: unreclaimable memory approaching `MemoryMax`
with page cache already at zero. That's the deadlock precondition.

But the converse trap is real too: `MemoryHigh` actively *reclaims* to hold
usage at/below itself, so a cgroup sitting flat at exactly its own
`MemoryHigh` is **not** proof that's the resting footprint — it can equally
mean the ceiling is too tight and constantly fighting the process down.
Distinguish by raising the ceiling temporarily and seeing where it settles.

### Cache: `reproc` is the whole measurement

Every Python script prints `reproc` — `timings.prompt_n`, the tokens actually
reprocessed, from the **non-streamed** response (streaming responses don't
carry `timings`). Compare it to `prompt_tok`:

- `reproc` small (a handful of tokens) → the branch was restored from cache. Good.
- `reproc` ≈ `prompt_tok` → full reprocess; the cache had nothing usable.

**Don't grep logs for `checkpoint`/`restoring` to decide this.** This build
emits no such lines at default verbosity even when restore provably works.
Concluding "checkpoints never restore" from missing log lines is exactly how
this repo shipped `--ctx-checkpoints 0` for two days and lost real performance.
Measure `prompt_n`; don't infer from absent messages.

### Benchmark branch *switching*, not a growing chat

An append-only conversation reuses its prefix fine even with checkpoints off
(only turn 2 suffers), so a single-conversation test hides this entire class of
problem. The workload that exposes it is alternating between two distinct
prefixes — which is what an orchestrator↔subagent handoff actually does. That's
why `branch_switch.py` and `cacheram_test.py` exist and why `ctx_fill.py` layers
a second branch at the end.

## Sizing rules

Once you have a peak from `measure-profile.sh`:

- `MemoryMax` ≥ peak unreclaimable **+ ~4 GiB**.
- `MemoryHigh` ≈ `MemoryMax − 2G`.
- If a desktop shares the box, keep `total RAM − MemoryMax` ≥ ~6 GiB.
- `MemorySwapMax` **bounded and non-zero** (`4G`). Both extremes fail — see
  the main README's "Memory stability" section; unlimited defeats `MemoryMax`
  when swap is zram, and `0` permits a direct-reclaim deadlock.
- Size against a **near-full context**, not a synthetic multi-branch test. A
  3×34k-token test peaked at 18.74 GiB; the real single-context worst case on
  the same box was 20.39–21.16 GiB, and ceilings set from the former deadlocked
  the server for 8 hours.
- **Re-measure if `ncmoe` changes** — it moves weight between VRAM and host RAM.

For `--cache-ram`, size against a **stored entry**, which is ~3× bare attention
KV (measured ~36 KiB/token on the reference model, vs ~11 KiB/token of
attention KV) because entries also carry checkpoint and slot state. It is a
**cap, not a reservation** — lowering it frees nothing until the working set
crosses it, then the cache fails abruptly rather than degrading.

## Pitfalls (each of these cost real time)

- **Raise the caps before measuring.** `measure-profile.sh` defaults to
  `MEAS_HIGH=28G MEAS_MAX=30G`, which is at or *below* what this repo's
  `full-128k` (28G/30G) and `full-256k` (29G/30G) already ship — so the
  "raise" is a no-op and you measure a clipped peak. Always pass `MEAS_*`
  explicitly for a profile whose caps are already high.
- **`systemctl set-property --runtime` survives a service restart.** It writes
  a drop-in under `/run/user/<uid>/systemd/user.control/` that lasts until
  reboot. Clear it with `systemctl --user revert <unit>` — restarting is not
  enough, and you'll silently measure under the wrong caps. Verify with
  `ls -A /run/user/$(id -u)/systemd/user.control/`.
- **`pgrep -f` / `pkill -f` match your own shell** when the pattern appears in
  its command line — this killed a tuning session twice. Use the unit's
  `MainPID` (`systemctl --user show <unit> -p MainPID --value`) or
  `ps -eo pid,args | awk '/pattern/ && !/awk/'`.
- **`StartLimitBurst` counts manual restarts** (5 per 300s here). Clear a
  tripped limit with `systemctl --user reset-failed <unit>`.
- **`Conflicts=`** means starting any deployment stops the other two —
  including a deployment that then fails to load, which leaves you with
  nothing running.
- **Don't compare timings across sessions.** A "14% prefill regression"
  attributed to tighter caps disappeared under a controlled A/B via a
  temporary drop-in. Always A/B in the same sitting.
- **`systemctl get-default` is not the current target.** Check
  `systemctl is-active graphical.target display-manager.service` and
  `loginctl list-sessions` for a lingering greeter before starting a `full-*`
  deployment.

## If a test wedges the machine

A cgroup in direct-reclaim deadlock shows: process state `D` with
`WCHAN=mem_cgroup_handle_over_high`, `memory.events` `high` climbing into the
millions, `memory.swap.current` pinned at `MemorySwapMax`, `oom_kill` still
`0`, and system-available RAM near zero. HTTP stops answering.

```sh
systemctl --user stop llama-server-<profile>.service     # usually works, frees RAM
```

If you'd rather not lose the in-flight state, raise the caps live instead — no
restart needed, and client requests survive:

```sh
systemctl --user set-property --runtime llama-server-<profile>.service \
  MemoryHigh=23G MemoryMax=25G MemorySwapMax=4G
```

Then `systemctl --user revert` once you're done.

Diagnose with:
```sh
MP=$(systemctl --user show llama-server-<profile> -p MainPID --value)
ps -o pid,state,wchan:24 -p "$MP"
CG=/sys/fs/cgroup/user.slice/user-$(id -u).slice/user@$(id -u).service/app.slice/llama-server-<profile>.service
awk '/^(anon|shmem) /{s+=$2} END{printf "%.2f GiB\n", s/1073741824}' $CG/memory.stat
cat $CG/memory.events $CG/memory.swap.current
```
