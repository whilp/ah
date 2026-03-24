# work

the work loop is a bisect-style optimization system. it runs an agent to
make changes, benchmarks the result, and keeps or discards based on the
metric. inspired by `git bisect`.

## commands

```
ah work start BENCHMARK GOAL   # run benchmark, record baseline
ah work run                    # one iteration: agent → benchmark → keep/discard
ah work log                    # print iteration history
ah work status                 # current metric, baseline, iteration count
ah work reset                  # clear all work state
```

## lifecycle

```
start ──► run ──► run ──► run ──► reset
  │         │       │       │
  │       keep   discard  crash
  │
baseline
```

`start` runs the benchmark once to establish a baseline metric.
each `run` invocation is one iteration: the agent makes a change,
the benchmark measures it, and the loop keeps (commit) or discards
(revert) based on whether the metric improved.

state persists in the session database. you can stop and resume
across shell sessions — `run` reads the benchmark path and goal
from the db.

## writing benchmarks

the benchmark script is the most important part of a work session.
it determines what the agent optimizes for and whether kept changes
are actually good. the work loop trusts the benchmark completely —
like `git bisect run`, a bad script produces bad results.

### contract

a benchmark script must:

1. **print one number to stdout** — the metric. lower is better.
2. **exit 0 on success** — any non-zero exit is treated as a crash.
3. **send logs to stderr** — stdout is reserved for the metric.

### rules of thumb

**validate correctness, not just speed.** if you're optimizing test
time, verify that all tests actually pass. otherwise a change that
breaks tests could appear faster and be kept.

```bash
# bad: silent failures get kept as "improvements"
make test >/dev/null 2>&1

# good: verify success before reporting metric
output=$(make test 2>&1)
echo "$output" | tail -1 | grep -q "passed" || exit 1
```

**start from a clean state.** clear caches, stamp files, or build
artifacts that would make the benchmark a no-op on repeated runs.

```bash
# clear cached results to force a real measurement
rm -f o/lib/ah/test_*.test.ok o/lib/ah/test_*.lua
```

**be deterministic.** avoid benchmarks that depend on network, load,
or other external factors. if variance is unavoidable, consider
running multiple iterations and reporting the median.

**keep it fast.** each `work run` invocation calls the benchmark
twice (once for baseline on first run, once after the agent's
change). a 30-second benchmark means each iteration takes at least
30 seconds plus agent time.

**exit non-zero on any failure.** use `set -eo pipefail` in bash
scripts. the work loop treats non-zero exit as a crash, reverts the
change, and records it in the history.

### example

```bash
#!/bin/bash
set -eo pipefail

# clean slate
rm -f o/lib/ah/test_*.test.ok o/lib/ah/test_*.lua

# run and validate
start=$(date +%s%N)
output=$(make test 2>&1)
echo "$output" | tail -1 | grep -q "passed" || exit 1
end=$(date +%s%N)

# emit metric (milliseconds)
echo $(( (end - start) / 1000000 ))
```

### common mistakes

| mistake | consequence | fix |
|---------|-------------|-----|
| suppressing output (`>/dev/null`) | broken changes silently pass | capture output, check for success |
| not cleaning caches | benchmark returns cached result | clear stamps/build artifacts |
| multi-line stdout | metric parsing fails (returns nil) | ensure exactly one number line |
| missing `set -e` | script continues after failures | use `set -eo pipefail` |
| slow benchmark (>60s) | iterations take forever | measure something smaller or use a proxy metric |

## iteration history

each iteration records: status, metric value, baseline (what "best" was),
message, and timestamp. statuses:

- **baseline** — initial measurement from `start`
- **keep** — metric improved, change committed
- **discard** — metric did not improve, change reverted
- **crash** — benchmark failed (non-zero exit or no metric), change reverted
- **skip** — agent made no changes

`work log` shows all iterations. `work status` shows current state.
baseline rows are excluded from iteration count and history displayed
to the agent.

## how it works internally

1. `start` runs the benchmark, records the metric as a baseline row in
   `work_iterations`, and stores the benchmark path and goal in the
   `context` table.

2. `run` loads the autowork skill, formats a prompt with the goal and
   recent iteration history, runs the agent (with a 300s deadline),
   then benchmarks whatever changes the agent made.

3. if the metric is lower than the current best, the change is committed
   with a message containing the metric delta and `git diff --stat`.
   otherwise the working tree is reverted to HEAD.

4. the outcome is recorded as a row in `work_iterations`.

5. `reset` deletes all `work_iterations` rows and clears the benchmark/goal
   context keys.

## schema

the `work_iterations` table lives in the main session database:

```sql
create table if not exists work_iterations (
  id text primary key,        -- ULID
  status text not null,        -- baseline/keep/discard/crash/skip
  metric_value real,           -- measured metric (null for skip/crash)
  baseline_value real,         -- what "best" was at time of measurement
  message text,                -- human-readable description
  created_at integer not null  -- unix timestamp
);
```
