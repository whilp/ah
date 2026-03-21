# autowork UX design

the ideal CLI experience for autonomous optimization loops.

## principles

- one command does everything — run it once or run it in a loop
- each invocation is one iteration (or baseline if no prior state)
- state survives across invocations
- output is scannable — one line per phase

## inputs

`--work` takes two inputs:

1. **benchmark script** — measures the metric. prints one number to
   stdout (lower is better), logs to stderr, exits non-zero on failure.
   the user writes this. the work module runs it.

2. **prompt** — tells the agent what to optimize and any constraints.
   plain text, same as a normal ah prompt.

```bash
ah --work bench.sh "reduce make test wall clock time. do not remove tests."
```

that's it. no other files required. the agent may create a `work.md`
as its own scratchpad (ideas, scope, findings), but that's the agent's
choice — the user doesn't need to set it up.

## lifecycle

### first invocation — baseline

```bash
ah --work bench.sh "reduce make test wall clock time. do not remove tests."
```

```
work: baseline 23400 (bench.sh)
```

runs the benchmark, records the result, exits. no agent call. lets the
user verify the script works before spending tokens.

### second invocation — first iteration

```bash
ah --work bench.sh "reduce make test wall clock time. do not remove tests."
```

```
work: #1 best=23400
work: #1 implementing...
work: #1 benchmarking...
work: #1 keep 23400 → 20100 (-14.1%) — split test rules to avoid embed pipeline
```

### subsequent invocations

same command, every time:

```bash
ah --work bench.sh "reduce make test wall clock time. do not remove tests."
```

```
work: #2 best=20100 (baseline 23400, -14.1%)
work: #2 implementing...
work: #2 benchmarking...
work: #2 discard 20100 → 21300 (+6.0%)
```

```
work: #3 best=20100 (baseline 23400, -14.1%)
work: #3 implementing...
work: #3 benchmarking...
work: #3 crash — make test failed (retried 3x)
```

```
work: #4 best=20100 (baseline 23400, -14.1%)
work: #4 implementing...
work: #4 benchmarking...
work: #4 keep 20100 → 18500 (-8.0%) — narrow test deps to lib sources only
```

### looping

the user controls the loop:

```bash
# run 10 iterations
for i in $(seq 10); do ah --work bench.sh "reduce make test time"; done

# run until 5 consecutive failures
fails=0
while [ $fails -lt 5 ]; do
  if ah --work bench.sh "reduce make test time"; then fails=0; else fails=$((fails+1)); fi
done
```

exit 0 on keep, 1 on discard/crash.

## what the agent sees

each iteration, the agent gets a prompt assembled from:

1. **the user's prompt** — verbatim, as the goal
2. **current best metric** — the number to beat
3. **iteration history** — last N results: status, metric, message
4. **crash context** — if the previous iteration crashed, stderr snippet

the agent also has normal tool access (read, write, edit, bash) and reads
whatever files it needs from disk. if the autowork skill tells it to
maintain a `work.md`, that's between the agent and the skill — the work
module doesn't know or care about it.

## what the work module does

each invocation:

1. open session (normal resolution)
2. if no baseline: run benchmark, record, exit
3. build prompt (user prompt + metric + history + crash context)
4. run agent (one turn — make exactly one change)
5. if no git changes: record skip, exit 1
6. run benchmark (retry up to 3x on failure)
7. if improved: commit, record keep, exit 0
8. otherwise: revert, record discard/crash, exit 1

the work module owns git operations. the agent never commits.

## state

work iterations table in the session db (already exists). `--work` uses
normal session resolution.

## git behavior

- **keep**: `git add -A && git commit` with agent-generated message
- **discard/crash**: `git checkout -- .` (but preserve agent scratchpad
  files like work.md — exclude them from revert)
- **baseline**: no git operations

## benchmark resilience

retries are in the work module, not the user's script:

1. on failure, retry up to 3 times
2. if all retries fail: record crash, feed stderr to agent next iteration
3. exit 1 — the shell loop decides whether to continue

## signals

- **SIGINT during implementation**: revert, exit 1
- **SIGINT during benchmarking**: let benchmark finish, then evaluate
- **SIGTERM**: revert uncommitted changes, exit 1

## open questions

- should `--work` warn if on a detached HEAD?
- should there be a `--dry-run` that implements without benchmarking?
- should kept commits be auto-pushed?
