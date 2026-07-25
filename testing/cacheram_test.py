#!/usr/bin/env python3
"""Three-branch prompt-cache probe - the --cache-ram sizing test.

Models orchestrator + subagent + title/summary: three independent prefixes
competing for one slot and one prompt cache. Phase 1 seeds all three (cold,
full prefill expected). Phase 2 cycles them twice - every step there is a
return to a branch the slot no longer holds, so it MUST come from the prompt
cache or be reprocessed whole.

The phase-2 restore hit rate is the number that tells you whether a given
--cache-ram is big enough. Measured history on this repo: 6/6 at 3072 MiB,
0/6 at 1024 MiB (every switch a ~40s full reprocess).

    BRANCH_WORDS=7000 ./cacheram_test.py "cache-ram=8192"

Raise BRANCH_WORDS to make each branch bigger; a cache that holds three small
branches may hold none at full context, so test at a realistic size.
"""
import os

from _common import label, post, report

WORDS = int(os.environ.get("BRANCH_WORDS", "7000"))

branches = {}
for tag in ("A", "B", "C"):
    filler = " ".join(f"{tag.lower()}{i}" for i in range(WORDS))
    branches[tag] = [{"role": "user",
                      "content": f"Branch {tag} corpus: {filler}\nReply: ok"}]

print(f"### {label('cacheram')}  (BRANCH_WORDS={WORDS})")
print(f"{'phase':>6} {'step':>4} {'br':>3} {'prompt_tok':>11} {'reproc':>8} "
      f"{'prefill_s':>10}")


def step(phase, i, tag):
    msgs = branches[tag]
    d = post(msgs)
    ptok, reproc, secs = report(d)
    msgs.append({"role": "assistant",
                 "content": d["choices"][0]["message"]["content"]})
    msgs.append({"role": "user", "content": f"Continue {tag}. Reply: ok"})
    print(f"{phase:>6} {i:>4} {tag:>3} {ptok:>11} {reproc:>8} {secs:>10.2f}",
          flush=True)
    return reproc, ptok


for i, tag in enumerate("ABC", 1):
    step("seed", i, tag)

restored = total = 0
for i, tag in enumerate("ABCABC", 1):
    reproc, ptok = step("cycle", i, tag)
    total += 1
    if reproc < ptok * 0.5:
        restored += 1

print(f"\nRESTORE HIT RATE {restored}/{total}")
if restored < total:
    print("  Below 3/6 means --cache-ram cannot hold the working set. The\n"
          "  failure is abrupt, not gradual: the cache doesn't degrade, it\n"
          "  stops storing an entry once that entry no longer fits.")
