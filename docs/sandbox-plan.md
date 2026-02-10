# Sandbox plan for ah workflow

## Goal

Sandbox `ah` agent runs in the GitHub workflow (plan, do, check phases) to prevent:
1. Unauthorized network access (data exfiltration, SSRF)
2. Unauthorized filesystem access
3. Privilege escalation

The agent should only be able to:
- Make API calls to `api.anthropic.com` (authenticated)
- Read/write files within the repository workspace
- Execute allowed local commands (git, make, etc.)

## POC verification (completed)

1. **pledge works**: `pledge("stdio rpath wpath cpath unix")` allows unix sockets, blocks inet
2. **Unix socket proxy works**: ah-proxy accepts CONNECT, validates allowlist, relays TLS
3. **Blocking works**: Non-allowlisted destinations get `403 Forbidden`

```
$ curl --proxy http://127.0.0.1:18080 https://api.anthropic.com/
< HTTP/1.1 200 Connection Established   ✓ allowed

$ curl --proxy http://127.0.0.1:18080 https://evil.com/
< HTTP/1.1 403 Forbidden                ✓ blocked
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    work-do/work-plan                     │
│                                                          │
│  1. Start proxy process                                  │
│  2. Fork ah process                                      │
│  3. Monitor/cleanup                                      │
└─────────────────────────────────────────────────────────┘
         │                           │
         │ parent                    │ child
         ▼                           ▼
┌─────────────────────┐    ┌─────────────────────────────┐
│   Proxy (cosmic)    │    │      ah (sandboxed)         │
│                     │    │                             │
│ - Listen on Unix    │◄───│ - unveil: workspace only    │
│   domain socket     │    │ - pledge: stdio rpath wpath │
│ - Allowlist         │    │   cpath flock tty proc      │
│   api.anthropic.com │    │   exec unix (no inet)       │
│ - Forward HTTPS     │    │ - http_proxy → unix socket  │
│   via CONNECT       │    │                             │
└─────────────────────┘    └─────────────────────────────┘
         │
         │ HTTPS (CONNECT tunnel)
         ▼
┌─────────────────────┐
│ api.anthropic.com   │
└─────────────────────┘
```

## Implementation phases

### Phase 1: Unix socket proxy support in cosmopolitan

The current `lfetch.c` only supports TCP proxies. Need to add Unix domain socket support.

**File**: `tool/net/lfetch.c` in whilp/cosmopolitan

**Change 1**: Add unix scheme detection (around line 752)

```c
// Add variable at top of function
bool proxyunix = false;
char *proxysockpath = NULL;

// In proxy parsing section (line 752-777)
if (proxyarg && proxyarglen) {
  gc(ParseUrl(proxyarg, proxyarglen, &proxyurl, true));
  gc(proxyurl.params.p);

  // Check for unix:// scheme
  if (proxyurl.scheme.n == 4 && !memcasecmp(proxyurl.scheme.p, "unix", 4)) {
    proxyunix = true;
    // Path is in host + path, e.g. unix:///tmp/proxy.sock
    // or unix://localhost/tmp/proxy.sock
    if (proxyurl.path.n) {
      proxysockpath = gc(strndup(proxyurl.path.p, proxyurl.path.n));
    } else {
      return LuaNilError(L, "bad unix proxy; missing socket path");
    }
  } else if (!(proxyurl.scheme.n == 4 && !memcasecmp(proxyurl.scheme.p, "http", 4))) {
    return LuaNilError(L, "bad proxy scheme; only http:// and unix:// supported");
  }
  // ... rest of http proxy parsing
}
```

**Change 2**: Use AF_UNIX for connection (around line 835)

```c
// ---- Connect ----
if (proxyunix) {
  // Unix socket connection
  struct sockaddr_un addr_un = {.sun_family = AF_UNIX};
  strlcpy(addr_un.sun_path, proxysockpath, sizeof(addr_un.sun_path));
  if ((sock = socket(AF_UNIX, SOCK_STREAM, 0)) == -1)
    return LuaNilError(L, "socket(AF_UNIX) failed: %s", strerror(errno));
  if (connect(sock, (struct sockaddr *)&addr_un, sizeof(addr_un)) == -1) {
    close(sock);
    return LuaNilError(L, "connect(%s) failed: %s", proxysockpath, strerror(errno));
  }
} else {
  // Existing TCP connection code
  const char *connecthost = proxyhost ? proxyhost : host;
  // ...
}
```

**Testing**: After change, `http_proxy=unix:///tmp/ah-proxy.sock` should work

### Phase 2: Proxy server implementation

**Completed**: `bin/ah-proxy` - Smokescreen-style CONNECT proxy

Features:
- Listens on Unix domain socket or TCP port
- Parses HTTP CONNECT requests
- Validates destination against hardcoded allowlist
- Returns 403 Forbidden for non-allowed destinations
- Establishes TCP connection to allowed destinations
- Relays data bidirectionally (TLS passes through tunnel)
- Forks per connection for isolation

```bash
# Unix socket mode (production)
ah-proxy --socket /tmp/ah-proxy.sock

# TCP mode (testing)
ah-proxy --port 18080
```

**TODO**:
- DNS resolution (currently hardcoded IP for api.anthropic.com)
- Configurable allowlist
- Connection timeout handling
- Graceful shutdown

### Phase 3: Sandbox wrapper

Modify work-do/work-plan to:
1. Start proxy before running ah
2. Set environment: `http_proxy=unix:///tmp/ah-proxy.sock`
3. Run ah with sandbox init

ah initialization (early in startup):
```lua
local sandbox = require("cosmic.sandbox")
local env = require("cosmic.env")

-- Unveil: restrict filesystem visibility
sandbox.unveil(env.get("GITHUB_WORKSPACE") or ".", "rwxc")
sandbox.unveil("/tmp", "rwc")  -- for proxy socket
sandbox.unveil(nil, nil)  -- commit

-- Pledge: drop network access
sandbox.pledge("stdio rpath wpath cpath flock tty proc exec unix", nil)
```

### Phase 4: GitHub workflow integration

Update `.github/workflows/work.yml`:
```yaml
- name: Run do phase
  env:
    CLAUDE_CODE_OAUTH_TOKEN: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
  run: |
    # Proxy started by work-do internally
    bin/work-do \
      --sandbox \
      --title "${{ fromJson(needs.plan.outputs.issue).title }}" \
      --number "${{ fromJson(needs.plan.outputs.issue).number }}"
```

## Constraints and limitations

1. **cosmopolitan changes required**: Need to add Unix socket proxy support to lfetch.c (in whilp/cosmopolitan fork)

2. **Proxy must handle TLS**: The proxy sees CONNECT requests but not the encrypted traffic. It just relays bytes after the tunnel is established.

3. **No https_proxy**: cosmopolitan uses http_proxy for all requests (including HTTPS via CONNECT). This is fine for our use case.

4. **pledge timing**: Must pledge after:
   - Opening the proxy socket connection
   - Any initialization that needs network (DNS, etc.)

5. **unveil paths**: Need to include:
   - Workspace directory (rw)
   - /tmp for proxy socket (rw)
   - /bin, /usr/bin for exec (x)
   - Potentially more paths for git, etc.

## Testing strategy

1. **Local testing** (gvisor doesn't support pledge/unveil - skip if not supported)
2. **Integration test on GitHub Actions** (native Linux runner supports pledge/unveil)

Test cases:
- Agent can call Anthropic API through proxy
- Agent cannot connect to arbitrary hosts
- Agent cannot read files outside workspace
- Agent cannot write files outside workspace
- Proxy rejects non-allowlisted destinations

## Alternative approaches considered

### A: Pre-connected socket (rejected)
Pass a pre-connected socket fd to child process. Rejected because:
- Would require significant changes to cosmic.fetch
- Complex fd passing across fork

### B: Localhost TCP proxy (rejected)
Run proxy on localhost:PORT. Rejected because:
- Race condition: agent could bypass before pledge
- Need to pledge away inet which blocks localhost too

### C: No proxy, just pledge/unveil (limited)
Just use pledge/unveil without proxy. Limited because:
- Can't selectively allow certain network destinations
- All-or-nothing inet pledge

## Open questions

1. Should proxy run in same process (thread) or separate process?
   - Same process: simpler, but if ah crashes, proxy dies too
   - Separate process: more isolation, but coordination needed

2. What's the allowlist format?
   - Hardcoded: api.anthropic.com:443
   - Config file: /etc/ah-proxy.conf
   - Environment variable: AH_PROXY_ALLOWLIST

3. How to handle proxy errors?
   - Return HTTP error codes
   - Log and continue
   - Terminate ah process

## Next steps

1. [x] POC: Verify pledge/unveil work with Unix sockets
2. [x] POC: Implement and test ah-proxy (Smokescreen-style)
3. [ ] cosmopolitan: Add `unix://` proxy scheme to lfetch.c
4. [ ] ah: Add sandbox initialization (unveil + pledge)
5. [ ] work-{plan,do,check}: Start proxy, set http_proxy, run ah sandboxed
6. [ ] Test on GitHub Actions
7. [ ] DNS resolution in proxy (or preload DNS before sandbox)
8. [ ] Document security properties
