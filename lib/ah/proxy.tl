-- ah/proxy.tl: HTTP CONNECT proxy with destination allowlist
-- Used by `ah proxy` subcommand for sandboxed network access

local unix = require("cosmo.unix")
local net = require("cosmic.net")

local M = {}

local ALLOWLIST: {string:boolean} = {
  ["api.anthropic.com:443"] = true,
}

-- DNS cache (hardcoded for now, could use getaddrinfo before pledge)
local DNS_CACHE: {string:string} = {
  ["api.anthropic.com"] = "160.79.104.11",
}

local function log(...: string)
  local parts: {string} = {...}
  io.stderr:write("[proxy] " .. table.concat(parts, "\t") .. "\n")
end

local function parse_connect(request: string): string, string
  local host, port = request:match("CONNECT%s+([^:%s]+):(%d+)")
  return host, port
end

local function relay(client_fd: number, upstream_fd: number)
  local BUFSIZ = 65536

  -- Set non-blocking
  unix.fcntl(client_fd, unix.F_SETFL, unix.O_NONBLOCK)
  unix.fcntl(upstream_fd, unix.F_SETFL, unix.O_NONBLOCK)

  while true do
    local fds: {number:number} = {
      [client_fd] = net.POLLIN,
      [upstream_fd] = net.POLLIN,
    }

    local revents, err = net.poll(fds, 30000)
    if not revents then
      log("poll error:", err)
      break
    end

    local client_ev = revents[client_fd] or 0
    local upstream_ev = revents[upstream_fd] or 0

    if client_ev & (net.POLLERR | net.POLLHUP | net.POLLNVAL) ~= 0 then
      break
    end
    if upstream_ev & (net.POLLERR | net.POLLHUP | net.POLLNVAL) ~= 0 then
      break
    end

    if client_ev & net.POLLIN ~= 0 then
      local data = unix.read(client_fd, BUFSIZ)
      if not data or data == "" then break end
      unix.write(upstream_fd, data)
    end

    if upstream_ev & net.POLLIN ~= 0 then
      local data = unix.read(upstream_fd, BUFSIZ)
      if not data or data == "" then break end
      unix.write(client_fd, data)
    end
  end
end

local function handle_client(client_fd: number)
  local request = unix.read(client_fd, 4096)
  if not request then
    log("failed to read request")
    return
  end

  local host, port = parse_connect(request)
  if not host then
    log("bad request:", (request as string):sub(1, 50))
    unix.write(client_fd, "HTTP/1.1 400 Bad Request\r\n\r\nOnly CONNECT supported\r\n")
    return
  end

  local dest = host .. ":" .. port
  log("CONNECT", dest)

  if not ALLOWLIST[dest] then
    log("BLOCKED", dest)
    unix.write(client_fd, "HTTP/1.1 403 Forbidden\r\n\r\nDestination not allowed: " .. dest .. "\r\n")
    return
  end

  local ip_str = DNS_CACHE[host]
  if not ip_str then
    log("DNS failed:", host)
    unix.write(client_fd, "HTTP/1.1 502 Bad Gateway\r\n\r\nDNS resolution failed\r\n")
    return
  end

  local ip = net.parseip(ip_str)
  if not ip then
    log("invalid IP:", ip_str)
    unix.write(client_fd, "HTTP/1.1 502 Bad Gateway\r\n\r\nInvalid IP\r\n")
    return
  end

  local upstream_fd = unix.socket(unix.AF_INET, unix.SOCK_STREAM, 0)
  if not upstream_fd or upstream_fd < 0 then
    log("socket failed")
    unix.write(client_fd, "HTTP/1.1 502 Bad Gateway\r\n\r\nSocket creation failed\r\n")
    return
  end

  local ok = unix.connect(upstream_fd, ip, tonumber(port) as integer)
  if not ok then
    log("connect failed:", host, port)
    unix.close(upstream_fd)
    unix.write(client_fd, "HTTP/1.1 502 Bad Gateway\r\n\r\nConnection failed\r\n")
    return
  end

  log("ALLOWED", dest)
  unix.write(client_fd, "HTTP/1.1 200 Connection Established\r\n\r\n")

  relay(client_fd, upstream_fd)
  unix.close(upstream_fd)
end

-- Run proxy server on Unix socket
-- Returns only on error
function M.serve(socket_path: string): number
  unix.unlink(socket_path)

  local server_fd = unix.socket(unix.AF_UNIX, unix.SOCK_STREAM, 0)
  if not server_fd or server_fd < 0 then
    io.stderr:write("error: failed to create socket\n")
    return 1
  end

  local ok = unix.bind(server_fd, socket_path)
  if not ok then
    io.stderr:write("error: failed to bind to " .. socket_path .. "\n")
    unix.close(server_fd)
    return 1
  end

  unix.chmod(socket_path, tonumber("600", 8))
  unix.listen(server_fd, 128)

  log("listening on", socket_path)

  while true do
    local client_fd = unix.accept(server_fd, 0)
    if client_fd and client_fd >= 0 then
      local pid = unix.fork()
      if pid == 0 then
        unix.close(server_fd)
        handle_client(client_fd)
        unix.close(client_fd)
        os.exit(0)
      else
        unix.close(client_fd)
      end
    end
  end
end

return M
