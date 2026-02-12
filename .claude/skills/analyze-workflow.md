# analyze-workflow

Analyze a GitHub Actions workflow run artifact for friction.

## Usage

```
/skill:analyze-workflow <artifact-url>
```

Example:
```
/skill:analyze-workflow https://github.com/whilp/ah/actions/runs/21908654534/artifacts/5466593394
```

## Steps

1. **Download and extract artifact**
   ```bash
   cd /tmp
   gh api repos/{owner}/{repo}/actions/artifacts/{artifact_id}/zip > artifact.zip
   unzip -o artifact.zip -d artifact_contents
   ```

2. **Query session databases for errors**
   ```bash
   for db in /tmp/artifact_contents/work/*/session.db; do
     phase=$(basename $(dirname $db))
     echo "=== $phase ==="
     sqlite3 $db "SELECT tool_name, substr(tool_input,1,200), substr(tool_output,1,200) FROM content_blocks WHERE is_error = 1;"
   done
   ```

3. **Query for slow operations (>30s)**
   ```bash
   for db in /tmp/artifact_contents/work/*/session.db; do
     phase=$(basename $(dirname $db))
     sqlite3 $db "SELECT tool_name, duration_ms, substr(tool_input,1,100) FROM content_blocks WHERE duration_ms > 30000 ORDER BY duration_ms DESC LIMIT 5;" | while read line; do
       echo "$phase: $line"
     done
   done
   ```

4. **Summarize token usage and stop reasons**
   ```bash
   for db in /tmp/artifact_contents/work/*/session.db; do
     phase=$(basename $(dirname $db))
     echo "=== $phase ==="
     sqlite3 $db "SELECT SUM(input_tokens), SUM(output_tokens) FROM messages;"
     sqlite3 $db "SELECT stop_reason, COUNT(*) FROM messages WHERE role='assistant' GROUP BY stop_reason;"
   done
   ```

5. **Check for incomplete phases** (missing stop_reason on final assistant message)
   ```bash
   for db in /tmp/artifact_contents/work/*/session.db; do
     phase=$(basename $(dirname $db))
     last=$(sqlite3 $db "SELECT seq, stop_reason FROM messages WHERE role='assistant' ORDER BY seq DESC LIMIT 1;")
     echo "$phase: $last"
   done
   ```

6. **Read friction files for comparison**
   ```bash
   for f in /tmp/artifact_contents/work/*/friction.md; do
     echo "=== $f ==="
     cat $f
   done
   ```

7. **Check for expected outputs**
   ```bash
   ls -la /tmp/artifact_contents/work/*/
   # expect: plan.md, do.md, check.md, actions.json, act.md, results.json, issues.json
   ```

## Output

Summarize:
- Total errors per phase (from session.db, not friction.md)
- Slow operations
- Incomplete phases
- Missing output files
- Token usage

Recommend issues to file for significant friction (>2 errors, incomplete phases, missing outputs).

## Filing issues

If friction is found, offer to file issues:
```bash
gh issue create --repo {owner}/{repo} \
  --title "friction: <concise problem>" \
  --body "## Problem\n...\n\n## Evidence\n...\n\n## Suggested fix\n..." \
  --label "friction"
```
