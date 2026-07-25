#!/usr/bin/env python3
"""Two-branch A/B/A switch - the --ctx-checkpoints sizing test.

Models the orchestrator<->subagent handoff: two independent conversations
(distinct prefixes, nothing shared to exploit), alternating. Each switch away
and back must be served from the prompt cache, since the slot itself has been
overwritten by the other branch.

This is the test that overturned this repo's `--ctx-checkpoints 0` setting.
Run it once with checkpoints at 0 and once non-zero: recurrent state cannot be
rewound, so with 0 there is nothing for the cache to resume from and steps 3-5
reprocess in full.

    ./branch_switch.py "checkpoints=0"
    ./branch_switch.py "checkpoints=8"

Why not just grow one chat: an append-only conversation reuses its prefix fine
even with checkpoints off (only turn 2 suffers), so a single-conversation test
hides this entire class of problem.
"""
import os

from _common import label, post, report

WORDS = int(os.environ.get("BRANCH_WORDS", "2500"))

branches = {
    name: [{"role": "user",
            "content": f"Branch {name} material: "
                       + " ".join(f"{name.lower() * 3}{i}" for i in range(WORDS))
                       + "\nReply: ok"}]
    for name in ("A", "B")
}

print(f"### {label('branch-switch')}  (BRANCH_WORDS={WORDS})")
print(f"{'step':>4} {'branch':>7} {'prompt_tok':>11} {'reprocessed':>12} "
      f"{'prefill_s':>10}")

switches = []
for step, name in enumerate(["A", "B", "A", "B", "A"], 1):
    msgs = branches[name]
    d = post(msgs)
    ptok, reproc, secs = report(d)
    print(f"{step:>4} {name:>7} {ptok:>11} {reproc:>12} {secs:>10.2f}",
          flush=True)
    if step >= 3:
        switches.append((reproc, ptok))
    msgs.append({"role": "assistant",
                 "content": d["choices"][0]["message"]["content"]})
    msgs.append({"role": "user", "content": f"Continue {name}. Reply: ok"})

restored = sum(1 for reproc, ptok in switches if reproc < ptok * 0.5)
print(f"\nSteps 3-5 are returns to a branch the slot no longer holds.")
print(f"RESTORED {restored}/{len(switches)}")
if restored < len(switches):
    print("  A full reprocess here means the cache had nothing to resume from.\n"
          "  Check --ctx-checkpoints is non-zero before suspecting --cache-ram.")
