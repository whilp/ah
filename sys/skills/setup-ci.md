---
name: setup-ci
description: Bootstrap ah work loop in a new repository. Generate workflows, Makefile, and CLAUDE.md.
---

# Setup CI

Configure a repository for ah's automated work loop.

## What this skill does

Generates the files needed to run `ah work` in a repository:
- `.github/workflows/work.yml` — scheduled workflow that runs `ah work`
- `.github/workflows/test.yml` — CI workflow for tests and linting
- `Makefile` — downloads ah binary and provides work/test/lint targets
- `CLAUDE.md` — project context for the agent

## Instructions

### 1. Analyze the repository

Read files to detect:
- **Language**: look at file extensions, package files (package.json, go.mod, Cargo.toml, pyproject.toml, etc.)
- **Build system**: Makefile, npm scripts, cargo, gradle, etc.
- **Test framework**: what test runner is used, how tests are invoked
- **Linter**: eslint, golangci-lint, clippy, ruff, etc.
- **Existing CI**: check `.github/workflows/`, `.circleci/`, `.travis.yml`, etc.

If the repo already has CI, note what exists and only generate what's missing.

### 2. Read templates

Read the template files to use as starting points:

- `/zip/embed/sys/skills/setup-ci/work.yml.tmpl`
- `/zip/embed/sys/skills/setup-ci/test.yml.tmpl`
- `/zip/embed/sys/skills/setup-ci/Makefile.tmpl`
- `/zip/embed/sys/skills/setup-ci/CLAUDE.md.tmpl`

### 3. Generate files

Adapt each template to the repository:

**`.github/workflows/work.yml`**: Use the work.yml template. Replace VERSION
and SHA with the latest ah release (ask the user or check
https://github.com/whilp/ah/releases). The user must add a
`CLAUDE_CODE_OAUTH_TOKEN` secret to their repo.

**`.github/workflows/test.yml`**: Use the test.yml template. Replace
placeholder test/lint commands with the repo's actual commands. Add
language-specific setup steps (setup-node, setup-python, setup-go, etc.).

**`Makefile`**: Use the Makefile template if no Makefile exists. If a Makefile
exists, add the `ah` download target and `work` target to it. Replace
placeholder test/lint commands with real ones.

**`CLAUDE.md`**: Use the CLAUDE.md template. Fill in the project name,
description, build/test commands, and architecture from what you learned
in step 1. If a CLAUDE.md already exists, offer to enhance it rather than
overwrite it.

### 4. Customization (optional)

If the user wants to customize ah's behavior:

**Custom skills**: Create `sys/skills/*.md` files in the repo. When ah is
built with `ah embed`, these override the defaults. Explain this to the user.

**Custom system prompt**: Create `sys/system.md` in the repo to override the
default system prompt.

The `ah embed <dir>` and `ah extract <dir>` commands allow building a custom
ah binary with overridden prompts, skills, and entrypoints. For most repos,
the default ah binary works — customization is only needed for specialized
workflows.

### 5. Validate

After generating files:
- Verify YAML syntax: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/work.yml'))"`
  (or equivalent)
- Verify Makefile syntax: `make -n test` (dry run)
- Check that `.github/workflows/` directory exists

### 6. Tell the user what to do next

After generating files, tell the user:

1. Add the `CLAUDE_CODE_OAUTH_TOKEN` secret to the repository
   (Settings → Secrets → Actions → New repository secret)
2. Review and commit the generated files
3. Create issues labeled `work` for ah to pick up
4. The work workflow runs every 3 hours (or trigger manually via workflow_dispatch)

## Important notes

- `ah` is a self-contained binary. It does not need to be built from source.
- The work loop is language-agnostic. It works with any language or framework.
- Do NOT try to rewrite ah's internals in another language. Use the binary as-is
  and customize behavior through prompts and skills.
- If the repo already has a Makefile with complex build logic, add ah targets
  alongside existing ones rather than replacing the file.
