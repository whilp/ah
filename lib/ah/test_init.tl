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

-- Ancestor walking tests (non-git dirs, so walk stops at "/").
-- We use TEST_TMPDIR as the ancestor with a context file.

local function test_ancestor_claude_md_included()
  -- ancestor has CLAUDE.md, cwd does not
  local ancestor = fs.join(TEST_TMPDIR, "anc_test1")
  local cwd = fs.join(ancestor, "sub")
  fs.makedirs(cwd)
  cio.barf(fs.join(ancestor, "CLAUDE.md"), "ancestor context")

  local content = prompt_mod.load_claude_md(cwd)
  assert(content:match("ancestor context"), "ancestor CLAUDE.md should be included: " .. content)
end
test_ancestor_claude_md_included()

local function test_ancestor_and_cwd_both_included()
  -- ancestor has CLAUDE.md, cwd also has CLAUDE.md
  local ancestor = fs.join(TEST_TMPDIR, "anc_test2")
  local cwd = fs.join(ancestor, "sub")
  fs.makedirs(cwd)
  cio.barf(fs.join(ancestor, "CLAUDE.md"), "parent context")
  cio.barf(fs.join(cwd, "CLAUDE.md"), "child context")

  local content = prompt_mod.load_claude_md(cwd)
  assert(content:match("parent context"), "ancestor content should be included: " .. content)
  assert(content:match("child context"), "cwd content should be included: " .. content)
  -- ancestor (more general) should appear before cwd (more specific)
  local parent_pos = content:find("parent context")
  local child_pos = content:find("child context")
  assert(parent_pos < child_pos, "ancestor should precede cwd in output")
end
test_ancestor_and_cwd_both_included()

local function test_cwd_only_backward_compat()
  -- cwd alone has CLAUDE.md, ancestor does not — legacy header format
  local ancestor = fs.join(TEST_TMPDIR, "anc_test3")
  local cwd = fs.join(ancestor, "sub")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "CLAUDE.md"), "only child context")

  local content = prompt_mod.load_claude_md(cwd)
  assert(content:match("Project Context"), "single-source should use legacy 'Project Context' header")
  assert(content:match("only child context"), "cwd content should be present")
end
test_cwd_only_backward_compat()

local function test_ancestor_agents_md_included()
  -- ancestor has AGENTS.md, cwd has nothing
  local ancestor = fs.join(TEST_TMPDIR, "anc_test4")
  local cwd = fs.join(ancestor, "sub")
  fs.makedirs(cwd)
  cio.barf(fs.join(ancestor, "AGENTS.md"), "ancestor agent context")

  local content = prompt_mod.load_claude_md(cwd)
  assert(content:match("ancestor agent context"), "ancestor AGENTS.md should be included: " .. content)
end
test_ancestor_agents_md_included()

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

-- Sandbox context tests

local function test_sandbox_context_absent()
  -- When AH_SANDBOX is not set, sandbox_context returns ""
  -- This test assumes AH_SANDBOX is NOT set in the test environment
  if not os.getenv("AH_SANDBOX") then
    local result = prompt_mod.sandbox_context("/tmp/test_sandbox")
    assert(result == "", "sandbox_context should return empty when AH_SANDBOX not set, got: " .. result)
  end
end
test_sandbox_context_absent()

local function test_sandbox_context_present()
  -- When AH_SANDBOX=1, sandbox_context should return a non-empty string with expected sections.
  -- Run as a subprocess with AH_SANDBOX=1 to avoid polluting our env.
  local script = [[
local prompt_mod = require("ah.prompt")
local result = prompt_mod.sandbox_context("/fake/cwd")
assert(result ~= "", "sandbox_context should return non-empty when AH_SANDBOX=1")
assert(result:match("## Sandbox"), "should have Sandbox heading")
assert(result:match("### Filesystem %(unveil%)"), "should have Filesystem section")
assert(result:match("### Network %(proxy allowlist%)"), "should have Network section")
assert(result:match("### Syscalls %(pledge%)"), "should have Syscalls section")
assert(result:match("/fake/cwd"), "should include cwd path")
assert(result:match("api.anthropic.com:443"), "should include default host")
assert(result:match("stdio"), "should include pledge promises")
print("ok")
]]
  local tmpf = "/tmp/test_sandbox_context.tl"
  local f = io.open(tmpf, "w")
  if f then
    f:write(script)
    f:close()
  end

  local cosmic_exe = "o/bin/cosmic"
  local cmd = "AH_SANDBOX=1 " .. cosmic_exe .. " " .. tmpf .. " 2>&1"
  local handle = io.popen(cmd)
  if handle then
    local out = handle:read("*a")
    handle:close()
    assert(out:match("ok"), "sandbox_context subprocess test failed: " .. out)
  end
end
test_sandbox_context_present()

local function test_sandbox_context_extra_hosts()
  -- Verify AH_ALLOW_HOSTS are included in output
  local script = [[
local prompt_mod = require("ah.prompt")
local result = prompt_mod.sandbox_context("/fake/cwd")
assert(result:match("github.com:443"), "should include extra host from AH_ALLOW_HOSTS")
print("ok")
]]
  local tmpf = "/tmp/test_sandbox_extra_hosts.tl"
  local f = io.open(tmpf, "w")
  if f then
    f:write(script)
    f:close()
  end

  local cosmic_exe = "o/bin/cosmic"
  local cmd = "AH_SANDBOX=1 AH_ALLOW_HOSTS=github.com:443 " .. cosmic_exe .. " " .. tmpf .. " 2>&1"
  local handle = io.popen(cmd)
  if handle then
    local out = handle:read("*a")
    handle:close()
    assert(out:match("ok"), "extra hosts test failed: " .. out)
  end
end
test_sandbox_context_extra_hosts()

local function test_load_system_prompt_sandbox_section()
  -- Verify load_system_prompt includes sandbox section when AH_SANDBOX=1
  local script = [[
local fs = require("cosmic.fs")
local prompt_mod = require("ah.prompt")
local cwd = "/tmp/sandbox_prompt_test"
fs.makedirs(cwd)
local prompt = prompt_mod.load_system_prompt(cwd)
assert(prompt:match("## Sandbox"), "system prompt should include Sandbox section when AH_SANDBOX=1: " .. prompt:sub(1, 200))
print("ok")
]]
  local tmpf = "/tmp/test_sandbox_prompt.tl"
  local f = io.open(tmpf, "w")
  if f then
    f:write(script)
    f:close()
  end

  local cosmic_exe = "o/bin/cosmic"
  local cmd = "AH_SANDBOX=1 " .. cosmic_exe .. " " .. tmpf .. " 2>&1"
  local handle = io.popen(cmd)
  if handle then
    local out = handle:read("*a")
    handle:close()
    assert(out:match("ok"), "system prompt sandbox test failed: " .. out)
  end
end
test_load_system_prompt_sandbox_section()

print("all init tests passed")
