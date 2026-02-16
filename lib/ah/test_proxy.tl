#!/usr/bin/env cosmic
-- test_proxy.tl: tests for HTTP CONNECT proxy module

local ip = require("cosmic.ip")

local net = require("cosmic.net")

local record Socket
  fd: number
  close: function(self: Socket): boolean
  recv: function(self: Socket, bufsiz: number): string, string
  send: function(self: Socket, data: string): number, string
  connect: function(self: Socket, ip: number, port: number): boolean, string
  getsockopt: function(self: Socket, level: number, optname: number): number, string
end

local record Proxy
  serve: function(string): number
  parse_connect: function(string): string, string
  resolvehost: function(string): ip.Addr, string
  is_allowed: function(string): boolean
  parse_allow_hosts: function(string): {string:boolean}
  parse_base_url: function(string): string
  nb_connect: function(Socket, number, integer): boolean, string
end

local proxy = require("ah.proxy") as Proxy

-- parse_connect: valid CONNECT request
local function test_parse_connect_valid()
  local host, port = proxy.parse_connect("CONNECT api.anthropic.com:443 HTTP/1.1\r\nHost: api.anthropic.com\r\n\r\n")
  assert(host == "api.anthropic.com", "host should be api.anthropic.com, got: " .. tostring(host))
  assert(port == "443", "port should be 443, got: " .. tostring(port))
  print("✓ parse_connect: valid CONNECT")
end
test_parse_connect_valid()

-- parse_connect: different port
local function test_parse_connect_port()
  local host, port = proxy.parse_connect("CONNECT example.com:8080 HTTP/1.1\r\n\r\n")
  assert(host == "example.com", "host should be example.com, got: " .. tostring(host))
  assert(port == "8080", "port should be 8080, got: " .. tostring(port))
  print("✓ parse_connect: different port")
end
test_parse_connect_port()

-- parse_connect: rejects GET
local function test_parse_connect_rejects_get()
  local host, port = proxy.parse_connect("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n")
  assert(host == nil, "GET should not parse as CONNECT")
  assert(port == nil, "port should be nil for GET")
  print("✓ parse_connect: rejects GET")
end
test_parse_connect_rejects_get()

-- parse_connect: rejects POST
local function test_parse_connect_rejects_post()
  local host, port = proxy.parse_connect("POST /api HTTP/1.1\r\nHost: example.com\r\n\r\n")
  assert(host == nil, "POST should not parse as CONNECT")
  print("✓ parse_connect: rejects POST")
end
test_parse_connect_rejects_post()

-- parse_connect: rejects empty
local function test_parse_connect_rejects_empty()
  local host = proxy.parse_connect("")
  assert(host == nil, "empty request should not parse")
  print("✓ parse_connect: rejects empty")
end
test_parse_connect_rejects_empty()

-- parse_connect: rejects CONNECT without port
local function test_parse_connect_no_port()
  local host = proxy.parse_connect("CONNECT example.com HTTP/1.1\r\n\r\n")
  assert(host == nil, "CONNECT without port should not parse")
  print("✓ parse_connect: rejects CONNECT without port")
end
test_parse_connect_no_port()

-- parse_connect: rejects CONNECT with non-numeric port
local function test_parse_connect_bad_port()
  local host = proxy.parse_connect("CONNECT example.com:abc HTTP/1.1\r\n\r\n")
  assert(host == nil, "non-numeric port should not parse")
  print("✓ parse_connect: rejects non-numeric port")
end
test_parse_connect_bad_port()

-- is_allowed: allowed destination
local function test_is_allowed_pass()
  assert(proxy.is_allowed("api.anthropic.com:443") == true, "api.anthropic.com:443 should be allowed")
  print("✓ is_allowed: allows api.anthropic.com:443")
end
test_is_allowed_pass()

-- is_allowed: wrong port
local function test_is_allowed_wrong_port()
  assert(proxy.is_allowed("api.anthropic.com:80") == false, "port 80 should be blocked")
  print("✓ is_allowed: blocks wrong port")
end
test_is_allowed_wrong_port()

-- is_allowed: unknown host
local function test_is_allowed_unknown()
  assert(proxy.is_allowed("evil.com:443") == false, "unknown host should be blocked")
  print("✓ is_allowed: blocks unknown host")
end
test_is_allowed_unknown()

-- is_allowed: no port
local function test_is_allowed_no_port()
  assert(proxy.is_allowed("api.anthropic.com") == false, "host without port should be blocked")
  print("✓ is_allowed: blocks host without port")
end
test_is_allowed_no_port()

-- is_allowed: prefix attack
local function test_is_allowed_prefix()
  assert(proxy.is_allowed("api.anthropic.com:443.evil.com") == false, "prefix attack should be blocked")
  print("✓ is_allowed: blocks prefix attack")
end
test_is_allowed_prefix()

-- is_allowed: suffix attack
local function test_is_allowed_suffix()
  assert(proxy.is_allowed("evil-api.anthropic.com:443") == false, "suffix attack should be blocked")
  print("✓ is_allowed: blocks suffix attack")
end
test_is_allowed_suffix()

-- resolvehost: known host
local function test_resolvehost_known()
  local addr, err = proxy.resolvehost("api.anthropic.com")
  assert(addr, "should resolve, got error: " .. tostring(err))
  local ip_str = addr:format()
  assert(ip_str:match("^%d+%.%d+%.%d+%.%d+$"), "should format as IPv4, got: " .. ip_str)
  print("✓ resolvehost: resolves known host")
end
test_resolvehost_known()

-- resolvehost: unknown host
local function test_resolvehost_unknown()
  local addr, err = proxy.resolvehost("nonexistent.invalid")
  assert(addr == nil, "unresolvable host should return nil, got: " .. tostring(addr))
  assert(err, "should return error message")
  print("✓ resolvehost: nil for unknown host")
end
test_resolvehost_unknown()

-- parse_connect: host is returned as-is (caller normalizes)
local function test_parse_connect_uppercase()
  local host, port = proxy.parse_connect("CONNECT API.ANTHROPIC.COM:443 HTTP/1.1\r\n\r\n")
  assert(host == "API.ANTHROPIC.COM", "host should preserve case from parse, got: " .. tostring(host))
  assert(port == "443", "port should be 443")
  print("✓ parse_connect: preserves uppercase (caller normalizes)")
end
test_parse_connect_uppercase()

-- parse_connect: IP literal
local function test_parse_connect_ip_literal()
  local host, port = proxy.parse_connect("CONNECT 160.79.104.11:443 HTTP/1.1\r\n\r\n")
  assert(host == "160.79.104.11", "should parse IP literal")
  assert(port == "443", "port should be 443")
  print("✓ parse_connect: IP literal")
end
test_parse_connect_ip_literal()

-- is_allowed: IP literal is not in allowlist (only hostname entries)
local function test_is_allowed_ip_literal()
  assert(proxy.is_allowed("160.79.104.11:443") == false, "IP literal should be blocked")
  print("✓ is_allowed: blocks IP literal")
end
test_is_allowed_ip_literal()

-- AH_ALLOW_HOSTS env var tests

-- Test: parse_allow_hosts parses comma-separated host:port entries
local function test_parse_allow_hosts_single()
  local hosts = proxy.parse_allow_hosts("example.com:443")
  assert(hosts["example.com:443"] == true, "should allow example.com:443")
  print("✓ parse_allow_hosts: single host")
end
test_parse_allow_hosts_single()

local function test_parse_allow_hosts_multiple()
  local hosts = proxy.parse_allow_hosts("example.com:443,hooks.slack.com:443")
  assert(hosts["example.com:443"] == true, "should allow example.com:443")
  assert(hosts["hooks.slack.com:443"] == true, "should allow hooks.slack.com:443")
  print("✓ parse_allow_hosts: multiple hosts")
end
test_parse_allow_hosts_multiple()

local function test_parse_allow_hosts_empty()
  local hosts = proxy.parse_allow_hosts("")
  -- Should be empty (or nil-safe)
  assert(not hosts["anything:443"], "empty string should produce no hosts")
  print("✓ parse_allow_hosts: empty string")
end
test_parse_allow_hosts_empty()

local function test_parse_allow_hosts_nil()
  local hosts = proxy.parse_allow_hosts(nil)
  assert(not hosts["anything:443"], "nil should produce no hosts")
  print("✓ parse_allow_hosts: nil")
end
test_parse_allow_hosts_nil()

local function test_parse_allow_hosts_whitespace()
  local hosts = proxy.parse_allow_hosts(" example.com:443 , hooks.slack.com:443 ")
  assert(hosts["example.com:443"] == true, "should trim whitespace")
  assert(hosts["hooks.slack.com:443"] == true, "should trim whitespace on second entry")
  print("✓ parse_allow_hosts: trims whitespace")
end
test_parse_allow_hosts_whitespace()

-- nb_connect: non-blocking connect to api.anthropic.com succeeds
local function test_nb_connect()
  local addr, err = proxy.resolvehost("api.anthropic.com")
  assert(addr, "DNS should resolve, got: " .. tostring(err))

  local sock = net.socket(net.AF_INET, net.SOCK_STREAM | net.SOCK_NONBLOCK, 0) as Socket
  assert(sock, "socket creation should succeed")

  local ok, conn_err = proxy.nb_connect(sock, addr:int() as number, 443 as integer)
  assert(ok, "nb_connect should succeed, got: " .. tostring(conn_err))
  sock:close()
  print("✓ nb_connect: non-blocking connect succeeds")
end
test_nb_connect()

-- nb_connect: non-blocking connect to unreachable port fails
local function test_nb_connect_refused()
  local addr, err = ip.lookup("127.0.0.1")
  assert(addr, "should resolve localhost, got: " .. tostring(err))

  local sock = net.socket(net.AF_INET, net.SOCK_STREAM | net.SOCK_NONBLOCK, 0) as Socket
  assert(sock, "socket creation should succeed")

  -- port 1 is almost certainly not listening
  local ok, conn_err = proxy.nb_connect(sock, addr:int() as number, 1 as integer)
  assert(not ok, "nb_connect to closed port should fail")
  assert(conn_err, "should have error message")
  sock:close()
  print("✓ nb_connect: connection refused returns error")
end
test_nb_connect_refused()

-- parse_base_url tests

local function test_parse_base_url_https_default_port()
  local result = proxy.parse_base_url("https://custom.example.com")
  assert(result == "custom.example.com:443", "should be custom.example.com:443, got: " .. tostring(result))
  print("✓ parse_base_url: https default port")
end
test_parse_base_url_https_default_port()

local function test_parse_base_url_https_explicit_port()
  local result = proxy.parse_base_url("https://custom.example.com:8443")
  assert(result == "custom.example.com:8443", "should be custom.example.com:8443, got: " .. tostring(result))
  print("✓ parse_base_url: https explicit port")
end
test_parse_base_url_https_explicit_port()

local function test_parse_base_url_http()
  local result = proxy.parse_base_url("http://custom.example.com")
  assert(result == "custom.example.com:80", "should be custom.example.com:80, got: " .. tostring(result))
  print("✓ parse_base_url: http default port")
end
test_parse_base_url_http()

local function test_parse_base_url_with_path()
  local result = proxy.parse_base_url("https://custom.example.com/v1")
  assert(result == "custom.example.com:443", "should strip path, got: " .. tostring(result))
  print("✓ parse_base_url: strips path")
end
test_parse_base_url_with_path()

local function test_parse_base_url_with_port_and_path()
  local result = proxy.parse_base_url("https://custom.example.com:8443/v1/messages")
  assert(result == "custom.example.com:8443", "should be custom.example.com:8443, got: " .. tostring(result))
  print("✓ parse_base_url: port and path")
end
test_parse_base_url_with_port_and_path()

local function test_parse_base_url_nil()
  local result = proxy.parse_base_url(nil)
  assert(result == nil, "nil should return nil, got: " .. tostring(result))
  print("✓ parse_base_url: nil input")
end
test_parse_base_url_nil()

local function test_parse_base_url_empty()
  local result = proxy.parse_base_url("")
  assert(result == nil, "empty string should return nil, got: " .. tostring(result))
  print("✓ parse_base_url: empty string")
end
test_parse_base_url_empty()

local function test_parse_base_url_default_anthropic()
  local result = proxy.parse_base_url("https://api.anthropic.com")
  assert(result == "api.anthropic.com:443", "should be api.anthropic.com:443, got: " .. tostring(result))
  print("✓ parse_base_url: default anthropic URL")
end
test_parse_base_url_default_anthropic()

local function test_parse_base_url_no_scheme()
  local result = proxy.parse_base_url("custom.example.com:443")
  assert(result == nil, "no scheme should return nil, got: " .. tostring(result))
  print("✓ parse_base_url: no scheme returns nil")
end
test_parse_base_url_no_scheme()

local function test_parse_base_url_ftp_scheme()
  local result = proxy.parse_base_url("ftp://custom.example.com")
  assert(result == nil, "ftp scheme should return nil, got: " .. tostring(result))
  print("✓ parse_base_url: unsupported scheme returns nil")
end
test_parse_base_url_ftp_scheme()

print("\nall proxy tests passed")
