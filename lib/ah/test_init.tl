#!/usr/bin/env cosmic
-- test_init.tl: tests for init module (system prompt loading)
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local init = require("ah.init")
local db = require("ah.db")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_load_system_prompt_default()
  -- No files exist, should use default
  local empty_dir = fs.join(TEST_TMPDIR, "empty")
  fs.makedirs(empty_dir)

  local prompt = init.load_system_prompt(empty_dir)
  assert(prompt == init.DEFAULT_SYSTEM_PROMPT, "should use default prompt when no files exist")
end
test_load_system_prompt_default()

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
  fs.makedirs(cwd)

  cio.barf(fs.join(cwd, "CLAUDE.md"), "This is my project context")

  local prompt = init.load_system_prompt(cwd)
  assert(prompt:match("Project Context"), "should have CLAUDE.md header")
  assert(prompt:match("This is my project context"), "should append CLAUDE.md content")
end
test_load_system_prompt_with_claude_md()

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

-- Session management tests

local function test_list_sessions_empty()
  local cwd = fs.join(TEST_TMPDIR, "sessions_empty")
  fs.makedirs(fs.join(cwd, ".ah"))

  local sessions = init.list_sessions(cwd)
  assert(#sessions == 0, "empty .ah should have 0 sessions")
end
test_list_sessions_empty()

local function test_list_sessions()
  local cwd = fs.join(TEST_TMPDIR, "sessions_list")
  local ah_dir = fs.join(cwd, ".ah")
  fs.makedirs(ah_dir)

  -- Create two session dbs with different ULIDs (26 chars each)
  -- Use ULIDs that sort predictably (earlier timestamp = lexically smaller)
  local ulid1 = "01KGW111111111111111111111"  -- earlier (26 chars)
  local ulid2 = "01KGW222222222222222222222"  -- later (26 chars)

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

  local sessions = init.list_sessions(cwd)
  assert(#sessions == 2, "should have 2 sessions, got " .. #sessions)
  -- Sorted by ULID descending (most recent first)
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

  local ulid1 = "01KGWAAAAAAAAAAAAAAAAAAAAA"  -- 26 chars
  local d1 = db.open(fs.join(ah_dir, ulid1 .. ".db"))
  db.create_message(d1, "user")
  db.close(d1)

  -- Exact match
  local resolved, err = init.resolve_session(cwd, ulid1)
  assert(resolved == ulid1, "exact match should work: " .. tostring(err))
end
test_resolve_session_exact()

local function test_resolve_session_prefix()
  local cwd = fs.join(TEST_TMPDIR, "sessions_prefix")
  local ah_dir = fs.join(cwd, ".ah")
  fs.makedirs(ah_dir)

  local ulid1 = "01KGWBBBBBBBBBBBBBBBBBBBBB"  -- 26 chars
  local d1 = db.open(fs.join(ah_dir, ulid1 .. ".db"))
  db.create_message(d1, "user")
  db.close(d1)

  -- Prefix match
  local resolved, err = init.resolve_session(cwd, "01KGWB")
  assert(resolved == ulid1, "prefix match should work: " .. tostring(err))
end
test_resolve_session_prefix()

local function test_resolve_session_ambiguous()
  local cwd = fs.join(TEST_TMPDIR, "sessions_ambig")
  local ah_dir = fs.join(cwd, ".ah")
  fs.makedirs(ah_dir)

  local ulid1 = "01KGWCCCCC1111111111111111"  -- 26 chars
  local ulid2 = "01KGWCCCCC2222222222222222"  -- 26 chars
  local d1 = db.open(fs.join(ah_dir, ulid1 .. ".db"))
  db.create_message(d1, "user")
  db.close(d1)
  local d2 = db.open(fs.join(ah_dir, ulid2 .. ".db"))
  db.create_message(d2, "user")
  db.close(d2)

  -- Ambiguous prefix
  local resolved, err = init.resolve_session(cwd, "01KGWCCCCC")
  assert(not resolved, "ambiguous prefix should fail")
  assert(err:match("ambiguous"), "error should mention ambiguous: " .. tostring(err))
end
test_resolve_session_ambiguous()

local function test_resolve_session_not_found()
  local cwd = fs.join(TEST_TMPDIR, "sessions_notfound")
  local ah_dir = fs.join(cwd, ".ah")
  fs.makedirs(ah_dir)

  local resolved, err = init.resolve_session(cwd, "NOTEXIST")
  assert(not resolved, "non-existent should fail")
  assert(err:match("no session"), "error should mention no session: " .. tostring(err))
end
test_resolve_session_not_found()

-- Help system tests

local function test_list_help_topics_no_archive()
  -- When not running from archive, /zip/embed/scenarios won't exist
  -- Should return empty list gracefully
  local topics = init.list_help_topics()
  assert(type(topics) == "table", "should return table")
  -- May be empty (no archive) or populated (running from archive)
  -- Either way it should not error
end
test_list_help_topics_no_archive()

local function test_read_help_topic_missing()
  -- Reading a nonexistent topic should return nil
  local content = init.read_help_topic("nonexistent_topic_xyz")
  assert(content == nil, "should return nil for missing topic")
end
test_read_help_topic_missing()

local function test_main_help()
  -- ah help should return 0
  local code, err = init.main({"help"})
  assert(code == 0, "help should succeed: " .. tostring(err))
end
test_main_help()

local function test_main_help_unknown_topic()
  -- ah help <unknown> should still return 0 (prints error to stderr)
  local code, err = init.main({"help", "nonexistent_xyz"})
  assert(code == 0, "help unknown topic should return 0: " .. tostring(err))
end
test_main_help_unknown_topic()

local function test_main_tools()
  -- ah tools should return 0
  local code, err = init.main({"tools"})
  assert(code == 0, "tools should succeed: " .. tostring(err))
end
test_main_tools()

print("all init tests passed")
