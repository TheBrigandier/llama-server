#!/usr/bin/env python3
"""Grow a single conversation toward a full context, then layer a 2nd branch.

This is the workload that memory ceilings should be sized against. An earlier
sizing test used 3 x 34k-token branches and under-measured badly: it peaked at
18.74 GiB, the ceilings were set from that, and a real job then hit an 88,591-
token single context and deadlocked the cgroup for 8 hours. This drives toward
a near-full context in ONE conversation - the shape that actually broke - then
seeds a second branch so the prompt cache is under pressure at the same time.

The final line is the one that matters for --cache-ram sizing: returning to
the big branch should show a small `reproc`. A `reproc` equal to the whole
prompt means the branch never fit in the cache and was reprocessed from
scratch.

    TARGET_TOKENS=118000 ./ctx_fill.py        # default, for a 131072 ctx
    TARGET_TOKENS=250000 ./ctx_fill.py        # near-full for a 262144 ctx

Prints prompt_tokens / reproc / prefill per turn so a stall or a truncation
is visible as it happens rather than at the end.
"""
import os
import time

from _common import post, report

TARGET = int(os.environ.get("TARGET_TOKENS", "118000"))
STEP_WORDS = int(os.environ.get("STEP_WORDS", "2400"))  # ~11-12k tok/turn
MAX_TURNS = int(os.environ.get("MAX_TURNS", "40"))

msgs = []
turn = 0
ptok = 0
print(f"{'turn':>4} {'prompt_tok':>11} {'reproc':>8} {'prefill_s':>10}  "
      f"(target {TARGET})", flush=True)
t0 = time.time()

while True:
    turn += 1
    filler = " ".join(f"t{turn}w{i}" for i in range(STEP_WORDS))
    msgs.append({"role": "user", "content": f"Block {turn}: {filler}\nReply: ok"})
    d = post(msgs)
    ptok, reproc, secs = report(d)
    print(f"{turn:>4} {ptok:>11} {reproc:>8} {secs:>10.2f}", flush=True)
    msgs.append({"role": "assistant",
                 "content": d["choices"][0]["message"]["content"]})
    if ptok >= TARGET:
        break
    if turn >= MAX_TURNS:
        print(f"  safety stop after {MAX_TURNS} turns "
              f"(raise MAX_TURNS, or STEP_WORDS, to reach {TARGET})")
        break

print(f"\nreached {ptok} tokens in {time.time() - t0:.0f}s", flush=True)

# A second, unrelated branch. The slot can only hold one conversation, so
# serving this one forces the big branch out to the prompt cache - and the
# return below then has to come back from that cache.
print("\n--- second branch (forces prompt cache to hold the big branch) ---",
      flush=True)
other = [{"role": "user",
          "content": "Other branch: " + " ".join(f"z{i}" for i in range(6000))
                     + "\nReply: ok"}]
ptok_b, reproc_b, _ = report(post(other))
print(f"branch B seeded: prompt_tok={ptok_b} reproc={reproc_b}", flush=True)

ptok_r, reproc_r, secs_r = report(post(msgs))
print(f"return to big branch: prompt_tok={ptok_r} reproc={reproc_r} "
      f"prefill={secs_r:.2f}s", flush=True)

if reproc_r > ptok_r * 0.5:
    print(f"\n  ^ FULL REPROCESS: the {ptok_r}-token branch did not fit in the\n"
          f"    prompt cache. Raise --cache-ram (and check the server log for\n"
          f"    'prompt state size ... exceeds cache size limit'), or accept\n"
          f"    this as the deployment's cache ceiling.")
else:
    print(f"\n  ^ restored from cache ({reproc_r} tok) - --cache-ram is "
          f"adequate for this context size.")
