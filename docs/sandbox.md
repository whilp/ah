# sandbox

source: `lib/ah/proxy.tl`, `lib/ah/work/sandbox.tl`

## overview

ah can run agents in a sandbox that restricts network and filesystem access.
this is used by the work loop to isolate agent phases from the broader system.

## `--sandbox` mode

when `--sandbox` is passed, ah:

1. starts an HTTP CONNECT proxy on a unix socket (`/tmp/ah-sandbox-XXXXXX/proxy.sock`).
2. sets `https_proxy=unix://<socket>` for the agent process.
3. applies `pledge` (restrict syscalls) and `unveil` (restrict filesystem visibility).

the agent can only reach hosts in the proxy allowlist.

## network proxy

`proxy.tl` implements an HTTP CONNECT proxy with a destination allowlist.

default allowlist: `api.anthropic.com:443`.

additional hosts are added via:
- `--allow-host HOST:PORT` CLI flag (repeatable).
- `AH_ALLOW_HOSTS` environment variable (comma-separated `host:port` entries).

the proxy resolves DNS, caches results, and relays TCP connections. all
non-allowed destinations are rejected.

## filesystem visibility

`--unveil PATH:PERM` restricts filesystem access. permissions are:
- `r` — read
- `w` — write
- `x` — execute
- `c` — create

the work loop adds unveils for plan and feedback directories as read-only
so the do/check phases can read plans but not modify them.

## work sandbox lifecycle

`work/sandbox.tl` manages sandbox setup and teardown for work phases:

1. `start_sandbox()`: forks a proxy child process, waits for socket readiness.
2. the work phase runs with `--sandbox` and proxy env vars.
3. `stop_sandbox()`: sends SIGTERM to proxy, cleans up socket and tmpdir.

## environment variables

| variable | purpose |
|----------|---------|
| `AH_ALLOW_HOSTS` | additional `host:port` entries for proxy allowlist |
| `AH_PROTECT_DIRS` | colon-separated paths protected from write/edit |
| `https_proxy` | set automatically in sandbox mode to unix socket |
