-- ah/proxy.tl: HTTP CONNECT proxy with destination allowlist
-- Used by `ah proxy` subcommand for sandboxed network access

local net = require("cosmic.net")
local fs = require("cosmic.fs")
local child = require("cosmic.child")

local record Socket
  fd: number
  close: function(self: Socket): boolean
  closed: function(self: Socket): boolean
  send: function(self: Socket, data: string, flags?: number): number, string
  recv: function(self: Socket, bufsiz?: number, flags?: number): string, string
  bind_unix: function(self: Socket, path: string): boolean, string
  listen: function(self: Socket, backlog?: number): boolean, string
  accept: function(self: Socket, flags?: number): Socket, number, number, string
  connect: function(self: Socket, ip: number, port: number): boolean, string
end

local record M
  serve: function(string): integer
  -- exported for testing
  parse_connect: function(string): string, string
  resolvehost: function(string): string
  is_allowed: function(string): boolean
  parse_allow_hosts: function(string): {string:boolean}
end

local ALLOWLIST: {string:boolean} = {
  ["api.anthropic.com:443"] = true,
}

-- Parse AH_ALLOW_HOSTS env var: comma-separated host:port entries.
-- Returns a table of host:port -> true. Trims whitespace.
local function parse_allow_hosts(value: string): {string:boolean}
  local hosts: {string:boolean} = {}
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

-- DNS: hardcoded for known allowlist entries.
-- TODO: resolve dynamically via net.getaddrinfo once cosmic exposes it,
-- or resolve in work.tl before pledge and pass IPs via env/args.
local DNS_CACHE: {string:string} = {
  ["api.anthropic.com"] = "160.79.104.11",
}

local function resolvehost(host: string): string
  return DNS_CACHE[host]
end

local function log(...: string)
  local parts = {...} as {string}
  io.stderr:write("[proxy] " .. table.concat(parts, "\t") .. "\n")
end

local function parse_connect(request: string): string, string
  local host, port = request:match("CONNECT%s+([^:%s]+):(%d+)")
  return host, port
end

local function relay(client: Socket, upstream: Socket)
  local BUFSIZ = 65536

  while true do
    local fds: {number:number} = {
      [client.fd] = net.POLLIN,
      [upstream.fd] = net.POLLIN,
    }

    local revents, err = net.poll(fds, 30000)
    if not revents then
      log("poll error:", err)
      break
    end

    local client_ev = revents[client.fd] or 0
    local upstream_ev = revents[upstream.fd] or 0

    -- Timeout: no activity on either fd
    if client_ev == 0 and upstream_ev == 0 then
      break
    end

    if client_ev & (net.POLLERR | net.POLLHUP | net.POLLNVAL) ~= 0 then
      break
    end
    if upstream_ev & (net.POLLERR | net.POLLHUP | net.POLLNVAL) ~= 0 then
      break
    end

    if client_ev & net.POLLIN ~= 0 then
      local data = client:recv(BUFSIZ)
      if not data or data == "" then break end
      upstream:send(data)
    end

    if upstream_ev & net.POLLIN ~= 0 then
      local data = upstream:recv(BUFSIZ)
      if not data or data == "" then break end
      client:send(data)
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

  local ip_str = resolvehost(host)
  if not ip_str then
    log("DNS failed:", host)
    client:send("HTTP/1.1 502 Bad Gateway\r\n\r\nDNS resolution failed\r\n")
    return
  end

  local ip = net.parseip(ip_str)
  if not ip then
    log("invalid IP:", ip_str)
    client:send("HTTP/1.1 502 Bad Gateway\r\n\r\nInvalid IP\r\n")
    return
  end

  local upstream, sock_err = net.socket(net.AF_INET, net.SOCK_STREAM) as (Socket, string)
  if not upstream then
    log("socket failed:", sock_err)
    client:send("HTTP/1.1 502 Bad Gateway\r\n\r\nSocket creation failed\r\n")
    return
  end

  local ok, conn_err = upstream:connect(ip, tonumber(port) as integer)
  if not ok then
    log("connect failed:", host, port, conn_err)
    upstream:close()
    client:send("HTTP/1.1 502 Bad Gateway\r\n\r\nConnection failed\r\n")
    return
  end

  log("ALLOWED", dest)
  client:send("HTTP/1.1 200 Connection Established\r\n\r\n")

  relay(client, upstream)
  upstream:close()
end

-- Run proxy server on Unix socket
-- Returns only on error
function M.serve(socket_path: string): integer
  fs.unlink(socket_path)

  local server, sock_err = net.listen_unix(socket_path) as (Socket, string)
  if not server then
    io.stderr:write("error: failed to listen on " .. socket_path .. ": " .. (sock_err or "") .. "\n")
    return 1
  end

  fs.chmod(socket_path, tonumber("600", 8))

  log("listening on", socket_path)

  -- Note: forked children become zombies until the proxy is killed.
  -- Acceptable since proxy lifetime is bounded by the work session.
  while true do
    local client = server:accept(0) as Socket
    if client then
      local pid = child.fork()
      if pid == 0 then
        server:close()
        handle_client(client)
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

return M
