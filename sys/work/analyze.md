# Friction analysis

Analyze the outputs of a completed work run. Identify up to 3 impactful
frictions and recommend issues to file.

## Repository

{repo}

## Instructions

1. Read friction files (skip missing):
   - `o/work/plan/friction.md`
   - `o/work/do/friction.md`
   - `o/work/check/friction.md`
   - `o/work/fix/friction.md`

2. Read phase outputs (skip missing):
   - `o/work/plan/plan.md`
   - `o/work/do/do.md`
   - `o/work/check/check.md`
   - `o/work/check/actions.json`
   - `o/work/act/act.md`
   - `o/work/act/results.json`

3. Query session databases for errors and slow operations:

        # for each existing phase db (plan, do, check, fix):
        sqlite3 o/work/<phase>/session.db \
          "select tool_name, substr(tool_input,1,200), substr(tool_output,1,200) from content_blocks where is_error = 1;"
        sqlite3 o/work/<phase>/session.db \
          "select tool_name, duration_ms, substr(tool_input,1,200) from content_blocks where duration_ms > 30000 order by duration_ms desc limit 5;"
        sqlite3 o/work/<phase>/session.db \
          "select stop_reason, count(*) from messages where role='assistant' group by stop_reason;"

4. Identify the top 1–3 most impactful frictions — things that:
   - Caused failures, retries, or workarounds
   - Wasted significant tokens or time
   - Indicate systemic issues worth fixing

## Output

Write `o/work/analyze/issues.json`:

    {
      "issues": [
        {
          "title": "friction: <concise problem>",
          "body": "## Problem\n<what happened>\n\n## Evidence\n<data from the run>\n\n## Suggested fix\n<what to change>",
          "labels": ["friction"]
        }
      ]
    }

Rules:
- 0 to 3 issues. Only real friction, not minor nits.
- If the run was smooth, write `{"issues": []}`.
- Title must start with `friction: `.
- Body must cite specific evidence from run data.
