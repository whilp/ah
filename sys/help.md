usage: ah [options] [command] [args...]

commands:
  <prompt>            send prompt to agent
  (no args)           continue from last message
  sessions            list all sessions
  usage               show token usage and cache stats
  embed <dir>         embed files into /zip/embed/
  extract <dir>       extract /zip/embed/ to directory

options:
  -h, --help          show this help
  -V, --version       show version and exit
  -n, --new           start a new session
  -S, --session ULID  use specific session (prefix match)
  --name NAME         set or match session by name
  --db PATH           use custom database path (default: .ah/<ulid>.db)
  -m, --model MODEL   set model (default: opus, or AH_MODEL env)
  -o, --output FILE   output file (used with embed)
  --cd PATH           change working directory before other operations
  --steer MSG         send steering message to running session
  --followup MSG      queue followup message for after session completes
  --max-tokens N      stop when cumulative tokens exceed N
  --skill NAME        invoke a skill by name (prepends /skill:<name> to prompt)
  --must-produce FILE require the agent to write FILE before finishing
  -t, --tool NAME=CMD register a CLI tool (repeatable, overrides all tiers)
  --sandbox           run inside network sandbox (proxy + unveil + pledge)
  --timeout N         wall-clock timeout in seconds
  --allow-host H:P    allow egress to host:port (repeatable, default: api.anthropic.com:443)
  --unveil PATH:PERM  set filesystem visibility (repeatable, perms: r/w/x/c)

models:
