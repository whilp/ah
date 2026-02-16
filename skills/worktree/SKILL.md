---
name: worktree
description: Perform work in a git worktree branched from main. Create the worktree, do the work, then offer to clean it up.
---

# worktree

do work in an isolated git worktree so the main working directory stays
clean. the worktree is always created from `origin/main`.

## usage

```
/skill:worktree <branch-name> [description of work]
```

if no branch name is given, derive one from the task description
(e.g. `fix/typo-in-readme`).

## steps

### 1. fetch and create the worktree

always branch from `origin/main`, regardless of what branch is currently
checked out:

```bash
git fetch origin main
git worktree add ../<branch-name> -b <branch-name> origin/main
```

confirm the worktree was created:

```bash
git worktree list
```

### 2. enter the worktree

all subsequent work happens inside the worktree directory:

```bash
cd ../<branch-name>
```

**important**: every bash invocation runs in a fresh shell. always `cd` into
the worktree at the start of each command. use paths relative to the worktree
root for read/write/edit operations (e.g. `../<branch-name>/path/to/file`),
or prefix commands:

```bash
cd ../<branch-name> && make ci
```

### 3. do the work

perform whatever task was requested. follow normal conventions:

- read files before editing
- run `make ci` (or the project's validation command) before committing
- stage specific files, not `git add -A`
- write clear commit messages

### 4. push

```bash
cd ../<branch-name> && git push -u origin <branch-name>
```

### 5. offer cleanup

once the work is complete (committed, pushed, PR opened if applicable),
**always offer to remove the worktree**:

> the worktree at `../<branch-name>` is no longer needed. want me to
> remove it?

if the user agrees (or if operating autonomously):

```bash
git worktree remove ../<branch-name>
```

if the branch is also no longer needed (e.g. merged):

```bash
git branch -d <branch-name>
```

## rules

- always branch from `origin/main` — never from the current branch or HEAD
- fetch before creating the worktree to ensure main is up to date
- never modify files in the original working directory while in worktree mode
- `cd` into the worktree at the start of every bash command
- offer worktree removal when work is done — don't leave worktrees behind
- if worktree creation fails (e.g. branch already exists), diagnose and
  suggest resolution (delete stale worktree, pick a different name, etc.)
