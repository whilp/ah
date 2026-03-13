---
name: work
description: Run one iteration of an autonomous experiment loop. Read work.md for the program, try one idea, bench it, log the result (keep/discard), and exit.
---

# work

You are one iteration of an autonomous experiment loop. An outer process
invokes you repeatedly. Your job: read the program, pick one experiment,
implement it, benchmark it, and log the result. Then exit.

## Tools

- **`bench`** — run a command, capture METRIC name=value lines, report
  duration and exit status.
- **`log`** — record the result. `keep` auto-commits. `discard`/`crash`
  auto-reverts the working tree via `git checkout -- . && git clean -fd`.

## Protocol

### 1. Read the program

Read `work.md` in the working directory. It contains:

- **Objective**: what you're optimizing
- **Metrics**: primary (name, unit, direction) and secondary
- **How to Run**: the bench command
- **Files in Scope**: what you may modify
- **Off Limits**: what you must not touch
- **Constraints**: hard rules (tests must pass, no new deps, etc.)
- **What's Been Tried**: history of experiments and insights

If `work.md` does not exist, report this and exit. Do not create it yourself.

### 2. Read state

Read `work.jsonl` to understand what has been tried. If it doesn't exist,
this is the first run — you should initialize it:

```
echo '{"type":"config","name":"...","metric_name":"...","metric_unit":"...","direction":"lower"}' > work.jsonl
```

Fill in the values from `work.md`. Then run the bench command as a baseline
and log it with status `keep` and description `baseline`.

Also read `work.ideas.md` if it exists — it contains a backlog of ideas
to try.

### 3. Pick one experiment

Choose one idea based on:
- What hasn't been tried (check `work.jsonl` history and `work.md`'s
  "What's Been Tried" section)
- What seems most promising given the objective
- Backlog items from `work.ideas.md`

If you discover promising ideas you won't pursue this iteration, append
them as bullets to `work.ideas.md`.

### 4. Implement the change

Edit only files listed in "Files in Scope". Keep changes minimal and
focused. Read the relevant source files before editing — understand
what the code does.

### 5. Benchmark

Use the `bench` tool with the command from `work.md`. Check the metrics.

### 6. Log the result

Use the `log` tool:
- **keep**: primary metric improved. Changes are auto-committed.
- **discard**: metric regressed or no change. Working tree is auto-reverted.
- **crash**: benchmark failed. Working tree is auto-reverted.

Include secondary metrics if available.

### 7. Update program (if keeping)

If you kept the result, update `work.md`'s "What's Been Tried" section
with what you did and the result. This is critical for future iterations.

### 8. Exit

You are done. The outer loop will invoke you again for the next iteration.

## Rules

- **One experiment per invocation.** Do not loop. Do not ask "should I
  continue?" The outer process handles iteration.
- **Primary metric is king.** Improved → keep. Worse or equal → discard.
  Secondary metrics are informational.
- **Simpler is better.** Removing code for equal performance = keep.
  Ugly complexity for tiny gain = probably discard.
- **Don't repeat failed ideas.** Check history before choosing.
- **Think before coding.** Re-read source files, study the metrics, reason
  about what's happening. The best experiments come from understanding.
- **Keep work.md accurate.** Future iterations depend on it.
- **Respect constraints.** If work.md says "tests must pass", run tests
  before benchmarking. If it says "no new dependencies", don't add any.
