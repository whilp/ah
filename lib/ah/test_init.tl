#!/usr/bin/env run-test.lua
-- test_init.tl: tests for init module (system prompt loading)
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local init = require("ah.init")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_get_global_dir()
  local dir = init.get_global_dir()
  assert(dir:match("%.ah$"), "should end with .ah")
  assert(dir:match("^/"), "should be absolute path")
end
test_get_global_dir()

local function test_load_system_prompt_default()
  -- No files exist, should use default
  local empty_dir = fs.join(TEST_TMPDIR, "empty")
  fs.makedirs(empty_dir)

  local prompt = init.load_system_prompt(nil, empty_dir, fs.join(TEST_TMPDIR, "no_global"))
  assert(prompt == init.DEFAULT_SYSTEM_PROMPT, "should use default prompt when no files exist")
end
test_load_system_prompt_default()

local function test_load_system_prompt_session_override()
  -- -s flag should take precedence over everything
  local prompt = init.load_system_prompt("Custom via -s", TEST_TMPDIR, TEST_TMPDIR)
  assert(prompt:match("Custom via %-s"), "session prompt should override")
end
test_load_system_prompt_session_override()

local function test_load_system_prompt_global()
  local global_ah = fs.join(TEST_TMPDIR, "global_ah_test")
  local cwd = fs.join(TEST_TMPDIR, "cwd_test")
  fs.makedirs(global_ah)
  fs.makedirs(cwd)

  cio.barf(fs.join(global_ah, "SYSTEM.md"), "Global system prompt")

  local prompt = init.load_system_prompt(nil, cwd, global_ah)
  assert(prompt:match("Global system prompt"), "should load global SYSTEM.md")
end
test_load_system_prompt_global()

local function test_load_system_prompt_project()
  local global_ah = fs.join(TEST_TMPDIR, "global_ah_proj")
  local cwd = fs.join(TEST_TMPDIR, "cwd_proj")
  local project_ah = fs.join(cwd, ".ah")
  fs.makedirs(global_ah)
  fs.makedirs(project_ah)

  cio.barf(fs.join(global_ah, "SYSTEM.md"), "Global")
  cio.barf(fs.join(project_ah, "SYSTEM.md"), "Project system prompt")

  local prompt = init.load_system_prompt(nil, cwd, global_ah)
  assert(prompt:match("Project system prompt"), "project should override global")
  assert(not prompt:match("Global"), "global should not be included")
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
  local global_ah = fs.join(TEST_TMPDIR, "global_ah_claude")
  local cwd = fs.join(TEST_TMPDIR, "cwd_with_claude")
  fs.makedirs(global_ah)
  fs.makedirs(cwd)

  cio.barf(fs.join(global_ah, "SYSTEM.md"), "You are a coding assistant.")
  cio.barf(fs.join(cwd, "CLAUDE.md"), "This is my project context")

  local prompt = init.load_system_prompt(nil, cwd, global_ah)
  assert(prompt:match("You are a coding assistant"), "should include system prompt")
  assert(prompt:match("Project Context"), "should have CLAUDE.md header")
  assert(prompt:match("This is my project context"), "should append CLAUDE.md content")
end
test_load_system_prompt_with_claude_md()

local function test_session_prompt_with_claude_md()
  local cwd = fs.join(TEST_TMPDIR, "cwd_session_claude")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "CLAUDE.md"), "Project notes here")

  local prompt = init.load_system_prompt("Custom prompt", cwd, TEST_TMPDIR)
  assert(prompt:match("Custom prompt"), "should use session prompt")
  assert(prompt:match("Project notes here"), "should append CLAUDE.md to session prompt")
end
test_session_prompt_with_claude_md()

print("all init tests passed")
