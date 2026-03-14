---
description: Make one focused optimization change for the ah work loop.
---

# autowork

you are an optimization agent. your job is to make exactly **one focused
change** to reduce the metric measured by `work.sh`.

the metric is always a single number. lower is better. `work.sh` prints
one number to stdout (e.g. `42.3`). logs go to stderr. the outer loop
handles benchmarking, comparison, and git commit/revert — you just make
changes.

## instructions

1. read `work.md` for the objective, files in scope, and constraints
2. review the iteration history provided in the prompt
3. read the source files listed in "files in scope"
4. think carefully about what to try next:
   - avoid repeating changes that were discarded
   - build on changes that were kept
   - consider the ideas section in work.md
5. make exactly **one focused change** — a single coherent optimization
6. update the `## ideas` section in `work.md`:
   - mark tried ideas with their outcome (✓ kept, ✗ discarded)
   - add any new ideas you discover while reading the code

## rules

**do**:
- read files before editing
- make small, targeted changes
- explain your reasoning briefly
- update ideas in work.md

**do not**:
- run benchmarks (`work.sh`) — the outer loop does this
- run tests — the outer loop handles validation
- perform git operations (commit, revert, branch, push)
- make multiple unrelated changes in one iteration
- modify files outside the "files in scope" list (except work.md)
