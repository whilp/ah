#!/usr/bin/env lua
local cosmo = require("cosmo")
local unix = require("cosmo.unix")
local path = require("cosmo.path")

global TEST_TMPDIR: string
global TEST_DIR: string

local function run_test(test: string): boolean, string, string, string
  local tmpbase = os.getenv("TMPDIR") or "/tmp"
  TEST_TMPDIR = unix.mkdtemp(path.join(tmpbase, "test_XXXXXX"))
  unix.setenv("TEST_TMPDIR", TEST_TMPDIR)
  unix.setenv("TMPDIR", TEST_TMPDIR)
  TEST_DIR = os.getenv("TEST_DIR")

  local stdout_file = path.join(TEST_TMPDIR, "stdout")
  local stderr_file = path.join(TEST_TMPDIR, "stderr")

  local orig_stdout = unix.dup(1)
  local orig_stderr = unix.dup(2)

  local stdout_fd = unix.open(stdout_file, unix.O_WRONLY | unix.O_CREAT | unix.O_TRUNC, tonumber("644", 8))
  local stderr_fd = unix.open(stderr_file, unix.O_WRONLY | unix.O_CREAT | unix.O_TRUNC, tonumber("644", 8))

  unix.close(1)
  unix.dup(stdout_fd)
  unix.close(stdout_fd)

  unix.close(2)
  unix.dup(stderr_fd)
  unix.close(stderr_fd)

  local ok, err = pcall(dofile, test)

  io.stdout:flush()
  io.stderr:flush()

  unix.close(1)
  unix.dup(orig_stdout)
  unix.close(orig_stdout)

  unix.close(2)
  unix.dup(orig_stderr)
  unix.close(orig_stderr)

  local stdout = cosmo.Slurp(stdout_file) or ""
  local stderr = cosmo.Slurp(stderr_file) or ""

  unix.rmrf(TEST_TMPDIR)

  return ok, err as string, stdout, stderr
end

local function write_result(status: string, message: string, stdout: string, stderr: string): integer
  local lines: {string} = {}
  if message and message ~= "" then
    table.insert(lines, status .. ": " .. message)
  else
    table.insert(lines, status)
  end
  table.insert(lines, "")
  table.insert(lines, "## stdout")
  table.insert(lines, "")
  table.insert(lines, stdout)
  table.insert(lines, "## stderr")
  table.insert(lines, "")
  table.insert(lines, stderr)
  local output = table.concat(lines, "\n")
  io.write(output)
  return status == "fail" and 1 or 0
end

local function main(test: string): integer, string
  if not test then
    return 1, "usage: run-test.lua <test>"
  end

  local ok, err, stdout, stderr = run_test(test)

  local status: string
  local message: string
  if ok then
    status = "pass"
  else
    local err_str = tostring(err)
    local skip_reason = err_str:match("SKIP%s+(.+)")
    local ignore_reason = err_str:match("IGNORE%s+(.+)")
    if skip_reason then
      status = "skip"
      message = skip_reason
    elseif ignore_reason then
      status = "ignore"
      message = ignore_reason
    else
      status = "fail"
      message = err_str:gsub("^.-/([^/]+:%d+:)", "%1")
    end
  end

  return write_result(status, message, stdout, stderr)
end

if cosmo.is_main() then
  local code, err = main(arg[1])
  if err then
    io.stderr:write(err .. "\n")
  end
  os.exit(code)
end
