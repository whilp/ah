# Self-improving development loop

Architecture for an unattended, autonomous development loop where `ah` works on
its own codebase through GitHub issues, executing a four-phase PDCA cycle
(Plan, Do, Check, Act) modeled as a GitHub Actions workflow.

## Overview

The system selects GitHub issues labeled `todo`, processes each through four
sequential phases, and produces concrete outputs: commits, PRs, comments. Each
phase runs `ah` with a phase-specific prompt and isolated database. The workflow
runs on a schedule or manual trigger, and all phase outputs are archived as
GitHub Actions artifacts.

Because the target repository is `ah` itself, the loop is self-improving: it can
fix bugs, add features, and refine its own implementation.

```
                        GitHub Actions workflow
                        ══════════════════════

  ┌──────────┐     ┌──────────┐     ┌──────────┐     ┌──────────┐
  │   Plan   │────→│    Do    │────→│  Check   │────→│   Act    │
  │          │     │          │     │          │     │          │
  │ research │     │ execute  │     │ review   │     │ publish  │
  │ + design │     │ + commit │     │ + verify │     │ + close  │
  └──────────┘     └──────────┘     └──────────┘     └──────────┘
       │                │                │                │
       ▼                ▼                ▼                ▼
   plan.md           do.md          check.md          act.md
   update.md         update.md      actions.json      results.json
                                    update.md
```

## Design principles

These follow from ah's existing scenarios (`scenarios/*.md`):

- **Composable**: ah is a loop; everything else lives outside it, in the shell
  and in GitHub Actions. The workflow doesn't need to know ah internals -- it
  just invokes `ah` with a prompt and a `--db` path.

- **Minimal**: each phase is a single `ah` invocation with a markdown prompt.
  State passes between phases as files, archived as artifacts. No custom
  orchestrator binary.

- **Improvable**: because the loop targets its own repo, it can modify its own
  prompts, workflow definition, and implementation.

## Workflow definition

The workflow is a single GitHub Actions workflow file at
`.github/workflows/work.yml`.

### Trigger

```yaml
on:
  schedule:
    - cron: '*/30 * * * *'    # every 30 minutes
  workflow_dispatch:
    inputs:
      issue:
        description: 'Issue number (skip selection)'
        type: number
        required: false
```

### Jobs

The workflow contains five jobs: `select`, `plan`, `do`, `check`, `act`. Each
job depends on the previous one.

```yaml
jobs:
  select:
    runs-on: ubuntu-latest
    outputs:
      issue_number: ${{ steps.select.outputs.issue_number }}
      issue_title: ${{ steps.select.outputs.issue_title }}
      issue_body: ${{ steps.select.outputs.issue_body }}
      issue_url: ${{ steps.select.outputs.issue_url }}
    steps:
      - uses: actions/checkout@v4
      - id: select
        run: |
          # Use workflow_dispatch input if provided
          if [ -n "${{ inputs.issue }}" ]; then
            gh issue view "${{ inputs.issue }}" \
              --json number,title,body,url > issue.json
          else
            # Select highest priority todo issue
            ah --db .ah/select.db \
              "$(cat sys/work/select.md)"
          fi
          # ... parse and set outputs

  plan:
    needs: select
    if: needs.select.outputs.issue_number != ''
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - run: |
          gh issue edit "${{ needs.select.outputs.issue_url }}" \
            --remove-label todo --add-label doing
      - run: |
          ah --db .ah/plan.db \
            "$(cat sys/work/plan.md)" \
            # ... with issue context interpolated
      - uses: actions/upload-artifact@v4
        with:
          name: plan
          path: |
            .ah/plan.db
            o/work/plan/

  do:
    needs: [select, plan]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { name: plan }
      - run: |
          ah --db .ah/do.db \
            "$(cat sys/work/do.md)"
      - uses: actions/upload-artifact@v4
        with:
          name: do
          path: |
            .ah/do.db
            o/work/do/

  check:
    needs: [select, plan, do]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { name: plan }
      - uses: actions/download-artifact@v4
        with: { name: do }
      - run: |
          ah --db .ah/check.db \
            "$(cat sys/work/check.md)"
      - uses: actions/upload-artifact@v4
        with:
          name: check
          path: |
            .ah/check.db
            o/work/check/

  act:
    needs: [select, plan, do, check]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/download-artifact@v4
        with: { name: check }
      - run: |
          # Deterministic: no ah invocation
          # Parse actions.json, execute approved actions
```

## Issue selection

### Priority algorithm

Issues are selected from the repo's issue tracker. The selection criteria:

1. State: open
2. Label: `todo`
3. Sort: priority label (p0 > p1 > p2 > unlabeled), then oldest first

This can be implemented as a simple `gh` query with shell sorting, or as an
`ah` invocation that uses bash tool calls to query and select.

```lua
-- Selection logic (conceptual)
-- gh issue list --label todo --state open --json number,title,body,url,labels,createdAt

local function priority(labels)
  for _, l in ipairs(labels) do
    if l.name == "p0" then return 0 end
    if l.name == "p1" then return 1 end
    if l.name == "p2" then return 2 end
  end
  return 3
end

-- sort by priority asc, then createdAt asc
table.sort(issues, function(a, b)
  local pa, pb = priority(a.labels), priority(b.labels)
  if pa ~= pb then return pa < pb end
  return a.createdAt < b.createdAt
end)
```

### Label lifecycle

```
[todo, p0/p1/p2]  →  select job picks issue
         ↓
[doing]            →  plan job replaces todo with doing
         ↓
[done]             →  act job on success
[failed]           →  any job on failure
```

## Phase details

### Plan

**Purpose**: Research the issue, explore the codebase, produce a detailed plan.

**Constraints**: Read-only intent. The plan phase should not modify the working
tree. It reads files, runs search commands, and produces a plan document.

**Inputs**:
- Issue title and body (interpolated into prompt)
- Full repository checkout

**Outputs** (written to `o/work/plan/`):
- `plan.md` -- research findings, approach, target branch, commit message,
  validation steps
- `update.md` -- brief status for GitHub comment (2-4 lines)

**Prompt** (`sys/work/plan.md`):

The plan prompt instructs ah to:

1. Research the codebase using read and bash tools
2. Validate the task is achievable (clear goal + entry point)
3. Write a structured plan with: context, approach, target (repo + branch),
   commit message, validation steps
4. Bail if the task isn't actionable (write only `update.md`, not `plan.md`)

```markdown
# Plan

You are planning a work item. Research the codebase and write a plan.

## Issue

**{title}**

{body}

## Instructions

1. Read relevant files to understand the current state
2. Identify what needs to change and where
3. Validate that you have a clear goal and entry point

## Bail conditions

If you cannot identify BOTH a clear goal AND an entry point, write ONLY
`o/work/plan/update.md` explaining why. Do NOT write `plan.md`.

## Output

Write `o/work/plan/plan.md`:

    # Plan: {title}

    ## Context
    <gathered context from files, inline>

    ## Approach
    <step by step>

    ## Target
    - Branch: work/{issue_number}-{slug}

    ## Commit
    <commit message>

    ## Validation
    <how to verify: commands to run, expected results>

Write `o/work/plan/update.md`: 2-4 line summary.

Do NOT modify any source files. Research only.
```

### Do

**Purpose**: Execute the plan. Make code changes, create commits.

**Constraints**: Full read-write access to working tree.

**Inputs**:
- `plan.md` from plan phase (via artifact)
- Full repository checkout

**Outputs** (written to `o/work/do/`):
- `do.md` -- summary of changes, commit SHA, status
- `update.md` -- brief status for GitHub comment

**Prompt** (`sys/work/do.md`):

```markdown
# Do

You are executing a work item. Follow the plan below.

## Plan

{plan.md contents}

## Instructions

1. Create the feature branch: `git checkout -b {branch} origin/main`
2. Make the changes described in the plan
3. Run validation steps from the plan
4. Stage specific files (not `git add -A`)
5. Commit with the message from the plan

## Output

Write `o/work/do/do.md`:

    # Do: {title}

    ## Changes
    <list of files changed>

    ## Commit
    <SHA or "none">

    ## Status
    <success|partial|failed>

    ## Notes
    <issues encountered>

Write `o/work/do/update.md`: 2-4 line summary.

Follow the plan. Do not add unrequested changes.
```

### Check

**Purpose**: Review execution against the plan. Determine if the work is ready
for action (PR creation, issue comment).

**Constraints**: Read-only intent. The check phase reviews what was done but
does not modify the working tree.

**Inputs**:
- `plan.md` from plan phase
- `do.md` from do phase
- Repository with changes on the feature branch

**Outputs** (written to `o/work/check/`):
- `check.md` -- human-readable assessment
- `actions.json` -- machine-readable action list for the act phase
- `update.md` -- brief status for GitHub comment

**Prompt** (`sys/work/check.md`):

```markdown
# Check

You are checking a work item. Review the execution against the plan.

## Plan

{plan.md contents}

## Execution summary

{do.md contents}

## Instructions

1. Review the diff: `git diff main...HEAD`
2. Run validation steps from the plan
3. Check for unintended changes
4. Write your assessment

## Output

Write `o/work/check/check.md`:

    # Check

    ## Plan compliance
    <did changes match plan?>

    ## Validation
    <results of running validation steps>

    ## Issues
    <problems found, or "none">

    ## Verdict
    <pass|needs-fixes|fail>

Write `o/work/check/actions.json`:

    {
      "verdict": "pass|needs-fixes|fail",
      "actions": [
        {"action": "comment_issue", "body": "..."},
        {"action": "create_pr", "branch": "...", "title": "...", "body": "..."}
      ]
    }

Action rules:
- Always include `comment_issue` with verdict and summary
- Include `create_pr` only when verdict is "pass" and changes were committed

Write `o/work/check/update.md`: 2-4 line summary.

Do NOT modify any source files.
```

### Act

**Purpose**: Execute the approved actions deterministically. No AI involvement.

**Constraints**: This phase does NOT invoke `ah`. It is a shell script that
reads `actions.json` and executes each action using `gh` CLI.

**Inputs**:
- `actions.json` from check phase
- Issue metadata from select job

**Outputs** (written to `o/work/act/`):
- `act.md` -- report of actions taken
- `results.json` -- machine-readable results

**Implementation**:

```bash
#!/bin/bash
set -euo pipefail

actions_file="o/work/check/actions.json"
verdict=$(jq -r .verdict "$actions_file")
issue_url="${ISSUE_URL}"

# Process each action
jq -c '.actions[]' "$actions_file" | while read -r action; do
  type=$(echo "$action" | jq -r .action)

  case "$type" in
    comment_issue)
      body=$(echo "$action" | jq -r .body)
      gh issue comment "$issue_url" --body "$body"
      ;;

    create_pr)
      branch=$(echo "$action" | jq -r .branch)
      title=$(echo "$action" | jq -r .title)
      body=$(echo "$action" | jq -r .body)
      git push -u origin "$branch"
      gh pr create --head "$branch" --title "$title" --body "$body"
      ;;
  esac
done

# Update labels
gh issue edit "$issue_url" --remove-label doing
if [ "$verdict" = "pass" ]; then
  gh issue edit "$issue_url" --add-label done
else
  gh issue edit "$issue_url" --add-label failed
fi
```

## State flow

State flows between phases as files, passed through GitHub Actions artifacts.

```
select job
  outputs: issue_number, issue_title, issue_body, issue_url
     │
     ▼
plan job
  reads:  issue metadata (from job outputs)
  writes: o/work/plan/plan.md
          o/work/plan/update.md
  artifact: plan (includes .ah/plan.db)
     │
     ▼
do job
  reads:  o/work/plan/plan.md (from plan artifact)
  writes: o/work/do/do.md
          o/work/do/update.md
  artifact: do (includes .ah/do.db)
     │
     ▼
check job
  reads:  o/work/plan/plan.md (from plan artifact)
          o/work/do/do.md (from do artifact)
  writes: o/work/check/check.md
          o/work/check/actions.json
          o/work/check/update.md
  artifact: check (includes .ah/check.db)
     │
     ▼
act job
  reads:  o/work/check/actions.json (from check artifact)
  writes: o/work/act/act.md
          o/work/act/results.json
  artifact: act
```

### Session databases

Each phase gets its own `--db` path. The database files are archived as
artifacts for debugging. They contain the full conversation tree, every tool
call, and all responses.

```
.ah/plan.db     # plan phase conversation
.ah/do.db       # do phase conversation
.ah/check.db    # check phase conversation
```

The act phase has no database -- it doesn't invoke `ah`.

## Prompt files

Prompts live in the repository at `sys/work/*.md`:

```
sys/work/
├── select.md     # issue selection instructions
├── plan.md       # plan phase prompt template
├── do.md         # do phase prompt template
└── check.md      # check phase prompt template
```

Because prompts are in-repo, the loop can modify its own prompts via the normal
issue-plan-do-check-act cycle. This is a key part of self-improvement.

### Prompt interpolation

The workflow interpolates variables into prompts before passing them to `ah`.
This is done in shell:

```bash
prompt=$(cat sys/work/plan.md)
prompt="${prompt//\{title\}/$ISSUE_TITLE}"
prompt="${prompt//\{body\}/$ISSUE_BODY}"
prompt="${prompt//\{issue_number\}/$ISSUE_NUMBER}"

ah --db .ah/plan.db "$prompt"
```

Alternatively, ah can read the prompt template and issue metadata from files,
doing the interpolation itself via its read tool.

## Failure handling

### Phase failure

If any phase fails (non-zero exit or missing required output), the workflow
stops and marks the issue as `failed`:

```yaml
  plan:
    steps:
      - run: ah --db .ah/plan.db "$prompt"
      - run: test -f o/work/plan/plan.md  # bail check

  do:
    needs: plan
    # implicitly skipped if plan fails

  # final cleanup job runs always
  cleanup:
    needs: [select, plan, do, check, act]
    if: always() && needs.select.outputs.issue_number != ''
    runs-on: ubuntu-latest
    steps:
      - run: |
          gh issue edit "$ISSUE_URL" --remove-label doing
          if [ "${{ needs.act.result }}" = "success" ]; then
            gh issue edit "$ISSUE_URL" --add-label done
          else
            gh issue edit "$ISSUE_URL" --add-label failed
          fi
```

### Bail mechanism

During the plan phase, if ah determines the task isn't actionable, it writes
only `update.md` (not `plan.md`). The workflow detects the missing file and
fails the job, triggering cleanup.

### Timeout

Each `ah` invocation should have a timeout. Use `--max-tokens` to cap token
usage, and the Actions job-level `timeout-minutes` for wall-clock limits:

```yaml
  plan:
    timeout-minutes: 15
    steps:
      - run: ah --max-tokens 100000 --db .ah/plan.db "$prompt"
```

## Actions

The act phase executes a fixed set of action types. New action types are added
by modifying the act script, not by changing prompts.

| Action | Description | Inputs |
|--------|-------------|--------|
| `comment_issue` | Post a comment on the issue | `body` |
| `create_pr` | Push branch and create a PR | `branch`, `title`, `body` |

### Safety constraints

- **No force push**: The act script uses `git push`, never `git push --force`.
- **PR scope**: PRs are created against the same repo. Cross-repo PRs are not
  supported.
- **Label management**: Only `todo`, `doing`, `done`, `failed` labels are
  modified.
- **No issue closure**: Issues are labeled, not closed. Humans close issues
  after reviewing PRs.

## File layout

New files added to the repository:

```
sys/work/
├── select.md           # issue selection prompt
├── plan.md             # plan phase prompt
├── do.md               # do phase prompt
└── check.md            # check phase prompt

.github/workflows/
└── work.yml            # the workflow definition

docs/
└── self-improving-dev-loop.md   # this document
```

Output directory (gitignored, created at runtime):

```
o/work/
├── plan/
│   ├── plan.md
│   └── update.md
├── do/
│   ├── do.md
│   └── update.md
├── check/
│   ├── check.md
│   ├── actions.json
│   └── update.md
└── act/
    ├── act.md
    └── results.json
```

## Implementation plan

Work is split into small PRs, each independently shippable:

1. **Prompts**: Add `sys/work/{select,plan,do,check}.md` with the phase prompt
   templates. These can be tested manually: `ah --db /tmp/test.db "$(cat sys/work/plan.md)"`.

2. **Workflow skeleton**: Add `.github/workflows/work.yml` with the job
   structure, artifact passing, and label management. Start with the act phase
   as a no-op that just logs the actions.

3. **Act script**: Implement the deterministic action executor as a shell script
   or Teal module that reads `actions.json` and calls `gh`.

4. **Integration**: Wire up secrets (API key), test on a real issue, iterate on
   prompts based on results.

5. **Self-improvement**: Once the loop can process simple issues (typo fixes,
   doc updates), create issues for enhancing the loop itself.

## Differences from the reference implementation

The reference system ("Working") uses Python, Claude Code, and Linux namespace
isolation. This design differs:

| Aspect | Working (reference) | ah dev loop |
|--------|-------------------|-------------|
| AI engine | Claude Code CLI | `ah` |
| Language | Python | Cosmic Lua (Teal) |
| Orchestrator | `work.py` script | GitHub Actions workflow |
| Isolation | Linux namespaces (unshare) | Actions runner isolation |
| State passing | Filesystem paths | Actions artifacts |
| Output archive | `~/working/o/<N>/` | Actions artifacts |
| Action execution | Python handlers | Shell script with `gh` |
| Scheduling | External (cron calling work.py) | Actions cron schedule |
| Read-only enforcement | remount bind ro | Prompt instructions (soft) |

### Isolation tradeoffs

The reference system uses Linux namespaces for hard isolation (read-only
mounts, network restriction). GitHub Actions runners provide process-level
isolation between jobs but not filesystem read-only enforcement within a job.

Options for harder isolation if needed:
- **Container jobs**: Run plan/check phases in a container with read-only
  mounts
- **Prompt discipline**: Instruct ah not to modify files (soft, current
  approach)
- **Post-hoc validation**: Check `git status` after plan/check phases and fail
  if the tree is dirty

The prompt-discipline approach is the starting point. Hard isolation can be
added later if needed.

### Why GitHub Actions

- Already configured for the repo (test.yml, prerelease.yml)
- Built-in artifact storage, secrets management, cron scheduling
- Job dependency graph maps naturally to PDCA phases
- Logs and artifacts provide audit trail
- No custom infrastructure to maintain
