#!/usr/bin/env cosmic
-- test_init.tl: tests for init module (system prompt loading)
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local init = require("ah.init")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_load_system_prompt_default()
  -- No files exist, should use default
  local empty_dir = fs.join(TEST_TMPDIR, "empty")
  fs.makedirs(empty_dir)

  local prompt = init.load_system_prompt(nil, empty_dir)
  assert(prompt == init.DEFAULT_SYSTEM_PROMPT, "should use default prompt when no files exist")
end
test_load_system_prompt_default()

local function test_load_system_prompt_cli_override()
  -- -s flag should take precedence over everything
  local prompt = init.load_system_prompt("Custom via -s", TEST_TMPDIR)
  assert(prompt:match("Custom via %-s"), "cli prompt should override")
end
test_load_system_prompt_cli_override()

local function test_load_system_prompt_project()
  local cwd = fs.join(TEST_TMPDIR, "cwd_proj")
  local project_ah = fs.join(cwd, ".ah")
  fs.makedirs(project_ah)

  cio.barf(fs.join(project_ah, "SYSTEM.md"), "Project system prompt")

  local prompt = init.load_system_prompt(nil, cwd)
  assert(prompt:match("Project system prompt"), "should load project SYSTEM.md")
end
test_load_system_prompt_project()

local function test_load_claude_md()
  local cwd = fs.join(TEST_TMPDIR, "cwd_claude")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "CLAUDE.md"), "# Project\nThis is context")

  local claude_content = init.load_claude_md(cwd)
  assert(claude_content:match("Project Context"), "should have header")
  assert(claude_content:match("This is context"), "should include CLAUDE.md content")
end
test_load_claude_md()

local function test_load_claude_md_missing()
  local cwd = fs.join(TEST_TMPDIR, "no_claude")
  fs.makedirs(cwd)

  local claude_content = init.load_claude_md(cwd)
  assert(claude_content == "", "should return empty string when no CLAUDE.md")
end
test_load_claude_md_missing()

local function test_load_system_prompt_with_claude_md()
  local cwd = fs.join(TEST_TMPDIR, "cwd_with_claude")
  local project_ah = fs.join(cwd, ".ah")
  fs.makedirs(project_ah)

  cio.barf(fs.join(project_ah, "SYSTEM.md"), "You are a coding assistant.")
  cio.barf(fs.join(cwd, "CLAUDE.md"), "This is my project context")

  local prompt = init.load_system_prompt(nil, cwd)
  assert(prompt:match("You are a coding assistant"), "should include system prompt")
  assert(prompt:match("Project Context"), "should have CLAUDE.md header")
  assert(prompt:match("This is my project context"), "should append CLAUDE.md content")
end
test_load_system_prompt_with_claude_md()

local function test_cli_prompt_with_claude_md()
  local cwd = fs.join(TEST_TMPDIR, "cwd_cli_claude")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "CLAUDE.md"), "Project notes here")

  local prompt = init.load_system_prompt("Custom prompt", cwd)
  assert(prompt:match("Custom prompt"), "should use cli prompt")
  assert(prompt:match("Project notes here"), "should append CLAUDE.md to cli prompt")
end
test_cli_prompt_with_claude_md()

-- Tests for tool_key_param
local function test_tool_key_param_bash()
  local key = init.tool_key_param("bash", '{"command":"ls -la"}')
  assert(key == "ls -la", "should extract bash command")
end
test_tool_key_param_bash()

local function test_tool_key_param_bash_truncate()
  local long_cmd = string.rep("x", 100)
  local key = init.tool_key_param("bash", '{"command":"' .. long_cmd .. '"}')
  assert(#key == 80, "should truncate to 80 chars: got " .. #key)
  assert(key:sub(-3) == "...", "should end with ellipsis")
end
test_tool_key_param_bash_truncate()

local function test_tool_key_param_read()
  local key = init.tool_key_param("read", '{"path":"/tmp/foo.txt"}')
  assert(key == "/tmp/foo.txt", "should extract read path")
end
test_tool_key_param_read()

local function test_tool_key_param_write()
  local key = init.tool_key_param("write", '{"path":"/tmp/bar.txt","content":"hello"}')
  assert(key == "/tmp/bar.txt", "should extract write path")
end
test_tool_key_param_write()

local function test_tool_key_param_edit()
  local key = init.tool_key_param("edit", '{"path":"/tmp/file.lua","old_string":"foo","new_string":"bar"}')
  assert(key:match("/tmp/file.lua"), "should include path")
  assert(key:match("foo"), "should include old_string preview")
  assert(key:match("bar"), "should include new_string preview")
end
test_tool_key_param_edit()

local function test_tool_key_param_nil_input()
  local key = init.tool_key_param("bash", nil)
  assert(key == "", "should return empty string for nil input")
end
test_tool_key_param_nil_input()

local function test_tool_key_param_invalid_json()
  local key = init.tool_key_param("bash", "not json")
  assert(key == "", "should return empty string for invalid json")
end
test_tool_key_param_invalid_json()

local function test_tool_key_param_unknown_tool()
  local key = init.tool_key_param("unknown_tool", '{"foo":"bar"}')
  assert(key == "", "should return empty string for unknown tool")
end
test_tool_key_param_unknown_tool()

print("all init tests passed")
