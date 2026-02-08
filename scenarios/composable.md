# composable

- `ah` is a loop: it takes a prompt, calls tools, and repeats until it's done
- everything else lives outside `ah`, in the shell and in other tools
- there is no "clear" command — you just point `ah` at a new `--db` and start fresh
- commands are markdown prompts in sys/commands/*.md; invoke with /<name>
- state and context live in the conversation; `ah` doesn't need to invent its own mechanisms for things the shell already does
- the minimal CLI surface is the point: it gives other tools (scripts, pipelines, cron, other programs) the full power of `ah` without requiring them to know anything about `ah`
