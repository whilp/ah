-- ah/proxy.tl: HTTP CONNECT proxy with destination allowlist
-- Used by `ah proxy` subcommand for sandboxed network access

local fs = require("cosmic.fs")
local child = require("cosmic.child")
local net = require("cosmic.net")
local ip = require("cosmic.ip")
local signal = require("cosmic.signal")

-- TODO: use net.Socket once cosmic exports it on NetModule
-- https://github.com/whilp/cosmic/issues/230
local record Socket
  fd: number
  close: function(self: Socket): boolean
  recv: function(self: Socket, bufsiz: number): string, string
  send: function(self: Socket, data: string): number, string
  bind_unix: function(self: Socket, path: string): boolean, string
  listen: function(self: Socket, backlog: number): boolean, string
  accept: function(self: Socket, flags: number): Socket, number, number, string
  connect: function(self: Socket, ip: number, port: number): boolean, string
  getsockopt: function(self: Socket, level: number, optname: number): number, string
end

local record M
  serve: function(string): integer
  -- exported for testing
  parse_connect: function(string): string, string
  resolvehost: function(string): ip.Addr, string
  is_allowed: function(string): boolean
  parse_allow_hosts: function(string): {string: boolean}
  parse_base_url: function(string): string
  nb_connect: function(Socket, number, integer): boolean, string
  send_all: function(Socket, string): boolean, string
end

local ALLOWLIST: {string: boolean} = {
  ["api.anthropic.com:443"] = true,
}

-- Parse AH_ALLOW_HOSTS env var: comma-separated host:port entries.
-- Returns a table of host:port -> true. Trims whitespace.
local function parse_allow_hosts(value: string): {string: boolean}
  local hosts: {string: boolean} = {}
  if not value or value == "" then return hosts end
  for entry in value:gmatch("[^,]+") do
    local trimmed = entry:match("^%s*(.-)%s*$")
    if trimmed and #trimmed > 0 then
      hosts[trimmed] = true
    end
  end
  return hosts
end

-- Merge AH_ALLOW_HOSTS into the allowlist at load time
local allow_hosts_env = os.getenv("AH_ALLOW_HOSTS")
if allow_hosts_env then
  local extra = parse_allow_hosts(allow_hosts_env)
  for host, _ in pairs(extra) do
    ALLOWLIST[host] = true
  end
end

-- Parse a URL into host:port. Returns nil for invalid/empty input.
-- Only handles http:// and https:// schemes.
local function parse_base_url(url: string): string
  if not url or url == "" then return nil end
  local scheme, rest = url:match("^(https?)://(.+)$")
  if not scheme or not rest then return nil end
  -- Strip path: take everything before the first /
  local hostport = rest:match("^([^/]+)")
  if not hostport or hostport == "" then return nil end
  -- Check if port is already specified
  local h, p = hostport:match("^(.+):(%d+)$")
  if h and p then
    return h .. ":" .. p
  end
  -- No port specified: default based on scheme
  local default_port = scheme == "https" and "443" or "80"
  return hostport .. ":" .. default_port
end

-- Add ANTHROPIC_BASE_URL host to allowlist at load time
local base_url_env = os.getenv("ANTHROPIC_BASE_URL")
if base_url_env then
  local hostport = parse_base_url(base_url_env)
  if hostport then
    ALLOWLIST[hostport] = true
  end
end

-- DNS: resolve via cosmic.ip.lookup, cache results for the process lifetime.
local DNS_CACHE: {string: ip.Addr} = {}

local function resolvehost(host: string): ip.Addr, string
  if DNS_CACHE[host] then
    return DNS_CACHE[host]
  end
  local addr, err = ip.lookup(host)
  if addr then
    DNS_CACHE[host] = addr
  end
  return addr, err
end

local _log_level = os.getenv("AH_LOG_LEVEL")
if not _log_level then
  _log_level = os.getenv("CI") and "info" or "debug"
end
local verbose = os.getenv("AH_PROXY_VERBOSE") == "1" or _log_level == "debug"

local function log(...: string)
  if not verbose then return end
  local parts = {...} as {string}
  io.stderr:write("[proxy] " .. table.concat(parts, "\t") .. "\n")
end

local function parse_connect(request: string): string, string
  local host, port = request:match("CONNECT%s+([^:%s]+):(%d+)")
  return host, port
end

-- Non-blocking connect: initiate connect, poll for completion, check SO_ERROR.
-- Returns true on success, false + error string on failure.
local CONNECT_TIMEOUT_MS = 10000

local function nb_connect(sock: Socket, addr: number, port: integer): boolean, string
  local ok, conn_err = sock:connect(addr, port)
  if ok then
    return true
  end

  -- Non-blocking connect returns false with EINPROGRESS; poll for writability.
  local fds: {number: number} = {[sock.fd] = net.POLLOUT}
  local revents, poll_err = net.poll(fds, CONNECT_TIMEOUT_MS)
  if not revents then
    return false, "poll failed: " .. (poll_err or "unknown")
  end

  local ev = revents[sock.fd] or 0
  if ev == 0 then
    return false, "connect timed out"
  end

  if ev & net.POLLERR ~= 0 then
    local so_err = sock:getsockopt(net.SOL_SOCKET, net.SO_ERROR)
    return false, "connect error: " .. tostring(so_err or conn_err)
  end

  if ev & net.POLLOUT ~= 0 then
    local so_err = sock:getsockopt(net.SOL_SOCKET, net.SO_ERROR)
    if so_err and so_err ~= 0 then
      return false, "connect failed: SO_ERROR=" .. tostring(so_err)
    end
    return true
  end

  return false, "connect failed: unexpected poll events=" .. tostring(ev)
end

-- Send all data on a socket, handling short writes.
-- Loops with poll(POLLOUT) until all bytes are sent.
local SEND_TIMEOUT_MS = 30000

local function send_all(sock: Socket, data: string): boolean, string
  local sent = 0
  while sent < #data do
    local n, err = sock:send(data:sub(sent + 1))
    if not n or n == 0 then
      return false, err or "send failed"
    end
    sent = sent + (n as integer)
    if sent < #data then
      local fds: {number: number} = {[sock.fd] = net.POLLOUT}
      local revents, poll_err = net.poll(fds, SEND_TIMEOUT_MS)
      if not revents then
        return false, "poll failed: " .. (poll_err or "unknown")
      end
      local ev = revents[sock.fd] or 0
      if ev == 0 then
        return false, "send timed out"
      end
      if ev & net.POLLERR ~= 0 then
        return false, "send error"
      end
    end
  end
  return true
end

local function relay(client: Socket, upstream: Socket)
  local BUFSIZ = 65536
  local bytes_relayed: integer = 0

  while true do
    local fds: {number: number} = {
      [client.fd] = net.POLLIN,
      [upstream.fd] = net.POLLIN,
    }

    local revents, err = net.poll(fds, 30000)
    if not revents then
      log("relay poll error:", err, "after", tostring(bytes_relayed), "bytes")
      break
    end

    local client_ev = revents[client.fd] or 0
    local upstream_ev = revents[upstream.fd] or 0

    -- Timeout: no activity on either fd
    if client_ev == 0 and upstream_ev == 0 then
      log("relay timeout (30s idle) after", tostring(bytes_relayed), "bytes")
      break
    end

    -- Read available data before checking error flags.
    -- When POLLIN is set alongside POLLERR|POLLHUP, there may be an error
    -- response to forward (e.g. API error message before connection close).
    local client_err = false
    local upstream_err = false

    if client_ev & net.POLLIN ~= 0 then
      local data = client:recv(BUFSIZ)
      if not data or data == "" then
        log("relay client closed after", tostring(bytes_relayed), "bytes")
        break
      end
      bytes_relayed = bytes_relayed + #data
      local ok, send_err = send_all(upstream, data)
      if not ok then
        log("relay send to upstream failed:", send_err, "after", tostring(bytes_relayed), "bytes")
        break
      end
    end

    if upstream_ev & net.POLLIN ~= 0 then
      local data = upstream:recv(BUFSIZ)
      if not data or data == "" then
        log("relay upstream closed after", tostring(bytes_relayed), "bytes")
        break
      end
      bytes_relayed = bytes_relayed + #data
      local ok, send_err = send_all(client, data)
      if not ok then
        log("relay send to client failed:", send_err, "after", tostring(bytes_relayed), "bytes")
        break
      end
    end

    -- Check error/hangup flags after reading any available data.
    if client_ev & (net.POLLERR | net.POLLHUP | net.POLLNVAL) ~= 0 then
      client_err = true
    end
    if upstream_ev & (net.POLLERR | net.POLLHUP | net.POLLNVAL) ~= 0 then
      upstream_err = true
    end
    if client_err then
      log("relay client event:", tostring(client_ev), "after", tostring(bytes_relayed), "bytes")
      break
    end
    if upstream_err then
      log("relay upstream event:", tostring(upstream_ev), "after", tostring(bytes_relayed), "bytes")
      break
    end
  end
end

local function handle_client(client: Socket)
  local request = client:recv(4096)
  if not request then
    log("failed to read request")
    return
  end

  local host, port = parse_connect(request)
  if not host then
    log("bad request:", (request as string):sub(1, 50))
    client:send("HTTP/1.1 400 Bad Request\r\n\r\nOnly CONNECT supported\r\n")
    return
  end

  host = host:lower()
  local dest = host .. ":" .. port
  log("CONNECT", dest)

  if not ALLOWLIST[dest] then
    log("BLOCKED", dest)
    client:send("HTTP/1.1 403 Forbidden\r\n\r\n")
    return
  end

  local addr, dns_err = resolvehost(host)
  if not addr then
    log("DNS failed:", host, dns_err or "unknown")
    client:send("HTTP/1.1 502 Bad Gateway\r\n\r\nDNS resolution failed\r\n")
    return
  end

  local upstream, sock_err = net.socket(net.AF_INET, net.SOCK_STREAM | net.SOCK_NONBLOCK, 0)
  if not upstream then
    log("socket failed:", sock_err)
    client:send("HTTP/1.1 502 Bad Gateway\r\n\r\nSocket creation failed\r\n")
    return
  end

  local ok, conn_err = nb_connect(upstream as Socket, addr:int() as number, tonumber(port) as integer)
  if not ok then
    log("connect failed:", host, port, conn_err)
    upstream:close()
    client:send("HTTP/1.1 502 Bad Gateway\r\n\r\nConnection failed\r\n")
    return
  end

  log("ALLOWED", dest)
  client:send("HTTP/1.1 200 Connection Established\r\n\r\n")

  relay(client, upstream as Socket)
  log("relay done:", dest)
  upstream:close()
end

-- Run proxy server on Unix socket
-- Returns only on error
function M.serve(socket_path: string): integer
  fs.unlink(socket_path)

  local server, srv_err = net.listen_unix(socket_path, 128)
  if not server then
    io.stderr:write("error: failed to listen on " .. socket_path .. ": " .. (srv_err or "") .. "\n")
    return 1
  end

  fs.chmod(socket_path, tonumber("600", 8))

  log("listening on", socket_path)

  signal.sigaction(signal.SIGCHLD, function()
      while true do
        local pid, _ = child.wait(-1, child.WNOHANG)
        if not pid or pid <= 0 then break end
      end
    end)

  while true do
    local client = server:accept(net.SOCK_NONBLOCK)
    if client then
      local pid = child.fork()
      if pid == 0 then
        server:close()
        handle_client(client as Socket)
        client:close()
        os.exit(0)
      else
        client:close()
      end
    end
  end
end

-- exported for testing
M.parse_connect = parse_connect
M.resolvehost = resolvehost
M.is_allowed = function(dest: string): boolean
  return ALLOWLIST[dest] or false
end
M.parse_allow_hosts = parse_allow_hosts
M.parse_base_url = parse_base_url
M.nb_connect = nb_connect
M.send_all = send_all

return M
