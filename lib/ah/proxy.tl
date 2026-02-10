-- ah/proxy.tl: HTTP CONNECT proxy with destination allowlist
-- Inspired by Stripe's Smokescreen
local net = require("cosmic.net")
local poll = require("cosmic.poll")
local fs = require("cosmic.fs")
local re = require("cosmic.re")

local M = {}

-- Default allowlist: only Anthropic API
local DEFAULT_ALLOWLIST: {string} = {
  "api.anthropic.com:443",
}

-- Parse HTTP request line: "CONNECT host:port HTTP/1.1"
function M.parse_connect(line: string): string, string, string
  local pattern = "^CONNECT%s+([^%s:]+):(%d+)%s+HTTP/(%d%.%d)"
  local host, port, version = line:match(pattern)
  return host, port, version
end

-- Check if destination is in allowlist
function M.is_allowed(host: string, port: string, allowlist: {string}): boolean
  local dest = host .. ":" .. port
  for _, allowed in ipairs(allowlist) do
    if dest == allowed then
      return true
    end
    -- Support wildcards: *.example.com:443
    if allowed:sub(1, 2) == "*." then
      local suffix = allowed:sub(2)  -- .example.com:443
      local dest_suffix = dest:match("^[^.]+(.*)$")  -- .example.com:443
      if dest_suffix == suffix then
        return true
      end
    end
  end
  return false
end

-- Read HTTP headers until empty line
function M.read_headers(sock: net.Socket): string, {string:string}
  local buf = ""
  local headers: {string:string} = {}
  local request_line: string = nil

  while true do
    local chunk, err = sock:recv(4096)
    if not chunk or chunk == "" then
      return nil, nil
    end
    buf = buf .. chunk

    -- Look for end of headers
    local header_end = buf:find("\r\n\r\n")
    if header_end then
      local header_section = buf:sub(1, header_end - 1)
      local lines = {}
      for line in header_section:gmatch("[^\r\n]+") do
        table.insert(lines, line)
      end

      if #lines > 0 then
        request_line = lines[1]
        for i = 2, #lines do
          local name, value = lines[i]:match("^([^:]+):%s*(.*)$")
          if name then
            headers[name:lower()] = value
          end
        end
      end
      return request_line, headers
    end

    -- Prevent buffer overflow
    if #buf > 65536 then
      return nil, nil
    end
  end
end

-- Relay data between two sockets
function M.relay(client: net.Socket, upstream: net.Socket): boolean, string
  local BUFSIZ = 65536

  while true do
    -- Poll both sockets
    local fds = {
      [client.fd] = net.POLLIN,
      [upstream.fd] = net.POLLIN,
    }

    local revents, err = poll.poll(fds, 30000)  -- 30s timeout
    if not revents then
      return false, "poll error: " .. (err or "unknown")
    end

    -- Check for errors or hangup
    for fd, events in pairs(revents) do
      if events & (net.POLLERR | net.POLLHUP | net.POLLNVAL) ~= 0 then
        return true, nil  -- connection closed normally
      end
    end

    -- Client -> upstream
    if revents[client.fd] and revents[client.fd] & net.POLLIN ~= 0 then
      local data, rerr = client:recv(BUFSIZ)
      if not data or data == "" then
        return true, nil
      end
      local sent, serr = upstream:send(data)
      if not sent then
        return false, "upstream send error: " .. (serr or "unknown")
      end
    end

    -- Upstream -> client
    if revents[upstream.fd] and revents[upstream.fd] & net.POLLIN ~= 0 then
      local data, rerr = upstream:recv(BUFSIZ)
      if not data or data == "" then
        return true, nil
      end
      local sent, serr = client:send(data)
      if not sent then
        return false, "client send error: " .. (serr or "unknown")
      end
    end
  end
end

-- Handle a single client connection
function M.handle_client(client: net.Socket, allowlist: {string}): boolean, string
  -- Read CONNECT request
  local request_line, headers = M.read_headers(client)
  if not request_line then
    client:send("HTTP/1.1 400 Bad Request\r\n\r\n")
    return false, "failed to read request"
  end

  -- Parse CONNECT
  local host, port, version = M.parse_connect(request_line)
  if not host then
    client:send("HTTP/1.1 400 Bad Request\r\n\r\nOnly CONNECT method supported\r\n")
    return false, "not a CONNECT request: " .. request_line
  end

  -- Check allowlist
  if not M.is_allowed(host, port, allowlist) then
    client:send("HTTP/1.1 403 Forbidden\r\n\r\nDestination not allowed: " .. host .. ":" .. port .. "\r\n")
    return false, "destination not allowed: " .. host .. ":" .. port
  end

  -- Resolve and connect to upstream
  -- Note: This is simplified; production should use async DNS
  local ip, dns_err = net.parseip(host)
  if not ip then
    -- Need DNS resolution - for now, only support IP addresses or rely on system resolver
    -- In production, we'd do async DNS here
    client:send("HTTP/1.1 502 Bad Gateway\r\n\r\nDNS resolution not implemented\r\n")
    return false, "DNS resolution needed for: " .. host
  end

  local upstream, conn_err = net.socket(net.AF_INET, net.SOCK_STREAM)
  if not upstream then
    client:send("HTTP/1.1 502 Bad Gateway\r\n\r\n")
    return false, "failed to create upstream socket: " .. (conn_err or "unknown")
  end

  local port_num = tonumber(port)
  local ok, cerr = upstream:connect(ip, port_num)
  if not ok then
    upstream:close()
    client:send("HTTP/1.1 502 Bad Gateway\r\n\r\n")
    return false, "failed to connect to upstream: " .. (cerr or "unknown")
  end

  -- Send 200 Connection Established
  client:send("HTTP/1.1 200 Connection Established\r\n\r\n")

  -- Relay data
  local relay_ok, relay_err = M.relay(client, upstream)
  upstream:close()

  return relay_ok, relay_err
end

-- Run proxy server on Unix socket
function M.serve_unix(socket_path: string, allowlist: {string}): boolean, string
  allowlist = allowlist or DEFAULT_ALLOWLIST

  -- Remove existing socket
  fs.remove(socket_path)

  -- Create and bind socket
  local server, err = net.socket(net.AF_UNIX, net.SOCK_STREAM)
  if not server then
    return false, "failed to create socket: " .. (err or "unknown")
  end

  -- TODO: net module needs bind_unix support
  -- For now, this is a stub
  return false, "Unix socket binding not yet implemented in cosmic.net"
end

-- Run proxy server on TCP port (for testing)
function M.serve_tcp(port: number, allowlist: {string}): boolean, string
  allowlist = allowlist or DEFAULT_ALLOWLIST

  local server, err = net.socket(net.AF_INET, net.SOCK_STREAM)
  if not server then
    return false, "failed to create socket: " .. (err or "unknown")
  end

  server:setsockopt(net.SOL_SOCKET, net.SO_REUSEADDR, true)

  local ok, berr = server:bind(0, port)  -- 0 = all interfaces
  if not ok then
    server:close()
    return false, "failed to bind: " .. (berr or "unknown")
  end

  local lok, lerr = server:listen(128)
  if not lok then
    server:close()
    return false, "failed to listen: " .. (lerr or "unknown")
  end

  io.stderr:write("proxy listening on port " .. port .. "\n")

  while true do
    local client, cip, cport, aerr = server:accept()
    if client then
      io.stderr:write("connection from " .. net.formatip(cip) .. ":" .. cport .. "\n")
      local hok, herr = M.handle_client(client, allowlist)
      if not hok then
        io.stderr:write("client error: " .. (herr or "unknown") .. "\n")
      end
      client:close()
    end
  end
end

return M
