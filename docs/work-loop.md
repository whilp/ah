# work loop

source: `lib/ah/work/init.tl`, `work.mk`, `lib/work/work.tl`

## overview

the work loop implements a PDCA (plan-do-check-act) cycle for autonomous
issue resolution. it is driven by make targets in `work.mk`.

## pipeline

```
preflight → issues.json → issue.json → plan → do → push → check → act
```

### preflight (`lib/work/work.tl`)

make-driven subcommands that produce JSON:

- `labels`: ensures required labels exist (`todo`, `doing`, `done`, `failed`, `friction`).
- `pr-limit`: checks open PR count against `MAX_PRS` (default 4).
- `issues`: fetches open issues labeled `todo` via `gh issue list`.
- `issue`: selects highest-priority issue (p0 > p1 > p2, then oldest).
- `doing`: transitions issue to `doing` label.

### plan phase

runs `ah` with `--skill plan` and `--must-produce o/work/plan/plan.md`.
the agent reads the issue and produces a structured plan. sandboxed.
timeout: 180s, budget: 100k tokens.

### do phase

runs `ah` with `--skill do`. the agent executes the plan, making changes
to the codebase. resets branch to `DEFAULT_BRANCH` before retry attempts.
sandboxed. timeout: 300s, budget: 200k tokens.

### push

`git push --force-with-lease` to the work branch.

### check phase

runs `ah` with `--skill check` and `--must-produce o/work/check/actions.json`.
the agent reviews the changes against the plan and writes a verdict JSON:

```json
{"verdict": "pass", "actions": [{"action": "create_pr", ...}]}
{"verdict": "needs-fixes", "actions": [...]}
```

if verdict is `needs-fixes`, the check agent writes `o/work/do/feedback.md`,
which makes `do_done` stale and triggers re-execution on the next make run.

### act

executes actions from the check verdict: `create_pr`, `comment_issue`,
`close_issue`, `label_issue`.

## convergence

`make work` runs the full pipeline up to 3 times:

```make
work:
    -@LOOP=1 $(converge)
    -@LOOP=2 $(converge)
    @LOOP=3 $(converge)
```

each attempt gets its own session database (`session-$(LOOP).db`). the
first two attempts tolerate failure; only the last must succeed.

## GitHub Actions

the work workflow (`.github/workflows/work.yml`) runs on a schedule
(every 3 hours) and on manual dispatch. it builds ah, runs `make work`,
and uploads the `o/` directory as an artifact.

## environment variables

| variable | purpose |
|----------|---------|
| `WORK_REPO` | GitHub repository (`owner/repo`) |
| `WORK_MAX_PRS` | max concurrent open PRs |
| `WORK_DEFAULT_BRANCH` | base branch for work branches |
| `WORK_INPUT` | path to issues.json |
| `WORK_ISSUE` | path to issue.json |
| `WORK_ACTIONS` | path to actions.json |

## issue selection

issues are sorted by priority label (p0 < p1 < p2 < unlabeled), then
by creation date (oldest first). only issues labeled `todo` are considered.
