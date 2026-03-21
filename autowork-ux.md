# autowork UX design

the ideal CLI experience for autonomous optimization loops.

## principles

- one command does everything — run it once or run it in a loop
- each invocation is one iteration (or baseline if no prior state)
- state survives across invocations
- output is scannable — one line per phase

## realistic session

### the benchmark script

the user writes a script that prints a single number to stdout (lower is
better). logs go to stderr. exit non-zero means failure.

```bash
cat > bench.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
rm -rf o/
start=$(date +%s%N)
make test >&2
end=$(date +%s%N)
echo $(( (end - start) / 1000000 ))
EOF
chmod +x bench.sh
```

### the command

```bash
ah --work bench.sh "reduce make test wall clock time. do not remove tests."
```

that's it. one command. run it again to do another iteration.

### first invocation — baseline

if no prior state exists for this script, ah baselines:

```
work: baseline 23400 (bench.sh)
```

baseline runs the benchmark, records the result, exits. no agent call.
this is fast and lets the user verify the script works before spending
tokens.

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

the agent makes one change, the benchmark runs, the result is kept or
discarded. one commit on keep, full revert on discard/crash.

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

the user decides how to loop. a simple shell loop, or just mashing
up-enter:

```bash
# run 10 iterations
for i in $(seq 10); do ah --work bench.sh "reduce make test time"; done

# run until 5 consecutive failures
fails=0
while [ $fails -lt 5 ]; do
  if ah --work bench.sh "reduce make test time"; then fails=0; else fails=$((fails+1)); fi
done
```

ah exits 0 on keep, 1 on discard/crash. this makes shell loops natural.

### checking status

```bash
ah --work-status bench.sh
```

```
work: bench.sh
  baseline: 23400
  best:     18500 (-20.9%)
  iterations: 7 (3 kept, 2 discarded, 2 crashed)
  last:     #7 discard 18500 → 19200 (+3.8%)
```

### resetting

```bash
ah --work-reset bench.sh
```

removes stored state (baseline, history). leaves work.md and commits
intact. next invocation will re-baseline.

## state management

work state is keyed by the **absolute path of the benchmark script**.
stored in `.ah/work/` as sqlite:

```
.ah/work/<sha256-of-script-path>.db
```

this means:
- state survives across invocations — no session flags needed
- multiple optimization targets can coexist
- `ah work --status` can list all active targets

## benchmark resilience

the work module handles retries, not the user's script:

1. on benchmark failure, retry up to 3 times
2. if all retries fail, record as crash
3. feed crash stderr to the agent as context on the next iteration:
   `"previous iteration crashed: <stderr snippet>"`
4. exit 1 — the shell loop decides whether to continue

## work.md lifecycle

- never committed by the work loop
- the agent reads and updates it each iteration as a working file
- updates survive reverts (work.md is excluded from `git checkout -- .`)
- the user commits it when they want to (or never)

## agent context per iteration

the prompt includes:

1. the user's original prompt (goal + constraints)
2. current best metric
3. last N iterations with status, metric, message
4. if previous iteration crashed: stderr snippet

the agent reads work.md from disk. it's not injected into the prompt.

## git behavior

- **keep**: `git add -A && git commit` with agent-generated message
- **discard/crash**: `git checkout -- .` (excluding work.md and .ah/)
- baseline invocation: no git operations

## signals

- **SIGINT during implementation**: revert, exit 1
- **SIGINT during benchmarking**: let benchmark finish, then evaluate
- **SIGTERM**: revert any uncommitted changes, exit 1

## open questions

- should `ah work` warn if not on a branch (detached HEAD)?
- should there be a `--dry-run` that implements without benchmarking?
- should kept commits be auto-pushed?
