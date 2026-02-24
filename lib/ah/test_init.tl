#!/usr/bin/env cosmic
-- test_init.tl: tests for prompt loading and session management
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local init = require("ah.init")
local db = require("ah.db")
local prompt_mod = require("ah.prompt")
local sessions_mod = require("ah.sessions")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

-- Prompt loading tests

local function test_load_system_prompt_default()
  local empty_dir = fs.join(TEST_TMPDIR, "empty")
  fs.makedirs(empty_dir)

  local prompt = prompt_mod.load_system_prompt(empty_dir)
  assert(prompt:match("Current date: %d%d%d%d%-%d%d%-%d%d"), "should contain current date")
  assert(prompt:match("Working directory: "), "should contain working directory")
  assert(not prompt:match("Git branch:"), "should not contain git branch in non-repo dir")
end
test_load_system_prompt_default()

local function test_load_claude_md()
  local cwd = fs.join(TEST_TMPDIR, "cwd_claude")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "CLAUDE.md"), "# Project\nThis is context")

  local claude_content = prompt_mod.load_claude_md(cwd)
  assert(claude_content:match("Project Context"), "should have header")
  assert(claude_content:match("This is context"), "should include CLAUDE.md content")
end
test_load_claude_md()

local function test_load_claude_md_missing()
  local cwd = fs.join(TEST_TMPDIR, "no_claude")
  fs.makedirs(cwd)

  local claude_content = prompt_mod.load_claude_md(cwd)
  assert(claude_content == "", "should return empty string when no CLAUDE.md")
end
test_load_claude_md_missing()

local function test_load_agents_md()
  local cwd = fs.join(TEST_TMPDIR, "cwd_agents")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "AGENTS.md"), "# Agents\nDo things this way")

  local content = prompt_mod.load_claude_md(cwd)
  assert(content:match("Agent Context"), "should have AGENTS.md header")
  assert(content:match("Do things this way"), "should include AGENTS.md content")
end
test_load_agents_md()

local function test_load_both_claude_and_agents_md()
  local cwd = fs.join(TEST_TMPDIR, "cwd_both")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "CLAUDE.md"), "claude context")
  cio.barf(fs.join(cwd, "AGENTS.md"), "agents context")

  local content = prompt_mod.load_claude_md(cwd)
  assert(content:match("Project Context"), "should have CLAUDE.md header")
  assert(content:match("claude context"), "should include CLAUDE.md content")
  assert(not content:match("Agent Context"), "should NOT have AGENTS.md header")
end
test_load_both_claude_and_agents_md()

local function test_load_claude_md_ancestor()
  -- Parent has CLAUDE.md, cwd has none → content found from ancestor.
  local base = fs.join(TEST_TMPDIR, "ancestor_test")
  local parent_dir = fs.join(base, "parent")
  local cwd = fs.join(parent_dir, "child")
  fs.makedirs(cwd)
  cio.barf(fs.join(parent_dir, "CLAUDE.md"), "parent context")

  local content = prompt_mod.load_claude_md(cwd)
  assert(content:match("Project Context"), "should have Project Context header from ancestor")
  assert(content:match("parent context"), "should include ancestor CLAUDE.md content")
end
test_load_claude_md_ancestor()

local function test_load_claude_md_both_levels()
  -- Parent has AGENTS.md, cwd has CLAUDE.md → both appear, cwd content last.
  local base = fs.join(TEST_TMPDIR, "both_levels_test")
  local parent_dir = fs.join(base, "root")
  local cwd = fs.join(parent_dir, "sub")
  fs.makedirs(cwd)
  cio.barf(fs.join(parent_dir, "AGENTS.md"), "root agents context")
  cio.barf(fs.join(cwd, "CLAUDE.md"), "cwd claude context")

  local content = prompt_mod.load_claude_md(cwd)
  assert(content:match("Agent Context"), "should have Agent Context header from parent")
  assert(content:match("root agents context"), "should include parent AGENTS.md content")
  assert(content:match("Project Context"), "should have Project Context header from cwd")
  assert(content:match("cwd claude context"), "should include cwd CLAUDE.md content")

  -- cwd content should appear after parent content.
  local parent_pos = content:find("root agents context")
  local cwd_pos = content:find("cwd claude context")
  assert(parent_pos and cwd_pos and parent_pos < cwd_pos, "parent content should come before cwd content")
end
test_load_claude_md_both_levels()

local function test_load_claude_md_cwd_supersedes_same_dir()
  -- Same dir: CLAUDE.md and AGENTS.md — CLAUDE.md wins, AGENTS.md is skipped.
  local cwd = fs.join(TEST_TMPDIR, "same_dir_both2")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "CLAUDE.md"), "claude wins")
  cio.barf(fs.join(cwd, "AGENTS.md"), "agents loses")

  local content = prompt_mod.load_claude_md(cwd)
  assert(content:match("claude wins"), "CLAUDE.md content should be present")
  assert(not content:match("agents loses"), "AGENTS.md content should NOT appear when CLAUDE.md exists")
end
test_load_claude_md_cwd_supersedes_same_dir()

local function test_load_system_prompt_with_claude_md()
  local cwd = fs.join(TEST_TMPDIR, "cwd_with_claude")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "CLAUDE.md"), "This is my project context")

  local prompt = prompt_mod.load_system_prompt(cwd)
  assert(prompt:match("Project Context"), "should have CLAUDE.md header")
  assert(prompt:match("This is my project context"), "should append CLAUDE.md content")
end
test_load_system_prompt_with_claude_md()

-- Backward compatibility: test through init module

local function test_backward_compat_load_claude_md()
  local cwd = fs.join(TEST_TMPDIR, "compat_claude")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "CLAUDE.md"), "compat test")

  local content = init.load_claude_md(cwd)
  assert(content:match("compat test"), "init.load_claude_md should still work")
end
test_backward_compat_load_claude_md()

-- Session management tests

local function test_list_sessions_empty()
  local cwd = fs.join(TEST_TMPDIR, "sessions_empty")
  fs.makedirs(fs.join(cwd, ".ah"))

  local sessions = sessions_mod.list_sessions(cwd)
  assert(#sessions == 0, "empty .ah should have 0 sessions")
end
test_list_sessions_empty()

local function test_list_sessions()
  local cwd = fs.join(TEST_TMPDIR, "sessions_list")
  local ah_dir = fs.join(cwd, ".ah")
  fs.makedirs(ah_dir)

  local ulid1 = "01KGW111111111111111111111"
  local ulid2 = "01KGW222222222222222222222"

  local d1 = db.open(fs.join(ah_dir, ulid1 .. ".db"))
  local msg1 = db.create_message(d1, "user")
  db.add_content_block(d1, msg1.id, "text", {content = "Hello world"})
  db.close(d1)

  local d2 = db.open(fs.join(ah_dir, ulid2 .. ".db"))
  local msg2a = db.create_message(d2, "user")
  db.add_content_block(d2, msg2a.id, "text", {content = "Fix the login bug"})
  local msg2b = db.create_message(d2, "assistant", msg2a.id)
  db.add_content_block(d2, msg2b.id, "text", {content = "I'll help"})
  local msg2c = db.create_message(d2, "user", msg2b.id)
  db.add_content_block(d2, msg2c.id, "text", {content = "Thanks"})
  db.close(d2)

  local sessions = sessions_mod.list_sessions(cwd)
  assert(#sessions == 2, "should have 2 sessions, got " .. #sessions)
  assert(sessions[1].ulid == ulid2, "first should be ulid2 (most recent)")
  assert(sessions[2].ulid == ulid1, "second should be ulid1")
  assert(sessions[1].msg_count == 3, "session 2 should have 3 messages")
  assert(sessions[1].first_prompt == "Fix the login bug", "session 2 first prompt mismatch")
  assert(sessions[2].msg_count == 1, "session 1 should have 1 message")
  assert(sessions[2].first_prompt == "Hello world", "session 1 first prompt mismatch")
end
test_list_sessions()

local function test_resolve_session_exact()
  local cwd = fs.join(TEST_TMPDIR, "sessions_resolve")
  local ah_dir = fs.join(cwd, ".ah")
  fs.makedirs(ah_dir)

  local ulid1 = "01KGWAAAAAAAAAAAAAAAAAAAAA"
  local d1 = db.open(fs.join(ah_dir, ulid1 .. ".db"))
  db.create_message(d1, "user")
  db.close(d1)

  local resolved, err = sessions_mod.resolve_session(cwd, ulid1)
  assert(resolved == ulid1, "exact match should work: " .. tostring(err))
end
test_resolve_session_exact()

local function test_resolve_session_prefix()
  local cwd = fs.join(TEST_TMPDIR, "sessions_prefix")
  local ah_dir = fs.join(cwd, ".ah")
  fs.makedirs(ah_dir)

  local ulid1 = "01KGWBBBBBBBBBBBBBBBBBBBBB"
  local d1 = db.open(fs.join(ah_dir, ulid1 .. ".db"))
  db.create_message(d1, "user")
  db.close(d1)

  local resolved, err = sessions_mod.resolve_session(cwd, "01KGWB")
  assert(resolved == ulid1, "prefix match should work: " .. tostring(err))
end
test_resolve_session_prefix()

local function test_resolve_session_ambiguous()
  local cwd = fs.join(TEST_TMPDIR, "sessions_ambig")
  local ah_dir = fs.join(cwd, ".ah")
  fs.makedirs(ah_dir)

  local ulid1 = "01KGWCCCCC1111111111111111"
  local ulid2 = "01KGWCCCCC2222222222222222"
  local d1 = db.open(fs.join(ah_dir, ulid1 .. ".db"))
  db.create_message(d1, "user")
  db.close(d1)
  local d2 = db.open(fs.join(ah_dir, ulid2 .. ".db"))
  db.create_message(d2, "user")
  db.close(d2)

  local resolved, err = sessions_mod.resolve_session(cwd, "01KGWCCCCC")
  assert(not resolved, "ambiguous prefix should fail")
  assert(err:match("ambiguous"), "error should mention ambiguous")
end
test_resolve_session_ambiguous()

local function test_resolve_session_not_found()
  local cwd = fs.join(TEST_TMPDIR, "sessions_notfound")
  local ah_dir = fs.join(cwd, ".ah")
  fs.makedirs(ah_dir)

  local resolved, err = sessions_mod.resolve_session(cwd, "NOTEXIST")
  assert(not resolved, "non-existent should fail")
  assert(err:match("no session"), "error should mention no session")
end
test_resolve_session_not_found()

print("all init tests passed")
