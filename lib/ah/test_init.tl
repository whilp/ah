#!/usr/bin/env cosmic
-- test_init.tl: tests for init module (system prompt loading)
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local init = require("ah.init")
local db = require("ah.db")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_load_system_prompt_default()
  -- No files exist, should still contain runtime context (datetime and cwd)
  -- but no git info (not a git repo)
  local empty_dir = fs.join(TEST_TMPDIR, "empty")
  fs.makedirs(empty_dir)

  local prompt = init.load_system_prompt(empty_dir)
  assert(prompt:match("Current date: %d%d%d%d%-%d%d%-%d%d"), "should contain current date")
  assert(prompt:match("Working directory: "), "should contain working directory")
  assert(not prompt:match("Git branch:"), "should not contain git branch in non-repo dir")
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

local function test_load_agents_md()
  local cwd = fs.join(TEST_TMPDIR, "cwd_agents")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "AGENTS.md"), "# Agents\nDo things this way")

  local content = init.load_claude_md(cwd)
  assert(content:match("Agent Context"), "should have AGENTS.md header")
  assert(content:match("Do things this way"), "should include AGENTS.md content")
end
test_load_agents_md()

local function test_load_both_claude_and_agents_md()
  -- CLAUDE.md supersedes AGENTS.md when both exist
  local cwd = fs.join(TEST_TMPDIR, "cwd_both")
  fs.makedirs(cwd)
  cio.barf(fs.join(cwd, "CLAUDE.md"), "claude context")
  cio.barf(fs.join(cwd, "AGENTS.md"), "agents context")

  local content = init.load_claude_md(cwd)
  assert(content:match("Project Context"), "should have CLAUDE.md header")
  assert(content:match("claude context"), "should include CLAUDE.md content")
  assert(not content:match("Agent Context"), "should NOT have AGENTS.md header")
  assert(not content:match("agents context"), "should NOT include AGENTS.md content")
end
test_load_both_claude_and_agents_md()

local function test_load_system_prompt_with_claude_md()
  local cwd = fs.join(TEST_TMPDIR, "cwd_with_claude")
  fs.makedirs(cwd)

  cio.barf(fs.join(cwd, "CLAUDE.md"), "This is my project context")

  local prompt = init.load_system_prompt(cwd)
  assert(prompt:match("Project Context"), "should have CLAUDE.md header")
  assert(prompt:match("This is my project context"), "should append CLAUDE.md content")
end
test_load_system_prompt_with_claude_md()

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

-- Arg parsing tests

local function test_parse_args_help()
  local parsed, err = init.parse_args({"-h"})
  assert(not parsed, "help should return nil")
  assert(err == "help", "err should be 'help', got: " .. tostring(err))
end
test_parse_args_help()

local function test_parse_args_long_help()
  local parsed, err = init.parse_args({"--help"})
  assert(not parsed, "--help should return nil")
  assert(err == "help", "err should be 'help', got: " .. tostring(err))
end
test_parse_args_long_help()

local function test_parse_args_model()
  local parsed = init.parse_args({"-m", "opus"})
  assert(parsed, "should parse successfully")
  assert(parsed.model == "opus", "model should be opus, got: " .. tostring(parsed.model))
end
test_parse_args_model()

local function test_parse_args_unknown_option()
  local parsed, err = init.parse_args({"--bogus"})
  assert(not parsed, "unknown option should return nil")
  assert(err == "unknown", "err should be 'unknown', got: " .. tostring(err))
end
test_parse_args_unknown_option()

local function test_parse_args_work_subcommand_flags()
  -- This is the failing case from the workflow:
  -- ah work --repo owner/repo --prompt update-docs
  -- The top-level parser must NOT reject --repo and --prompt as unknown options.
  -- Instead, it should stop at "work" and pass everything after to the subcommand.
  local parsed, err = init.parse_args({"work", "--repo", "owner/repo", "--prompt", "update-docs"})
  assert(parsed, "work subcommand args should not be rejected, got err: " .. tostring(err))
  assert(parsed.remaining[1] == "work", "first remaining should be 'work', got: " .. tostring(parsed.remaining[1]))
  assert(parsed.remaining[2] == "--repo", "second remaining should be '--repo', got: " .. tostring(parsed.remaining[2]))
  assert(parsed.remaining[3] == "owner/repo", "third remaining should be 'owner/repo', got: " .. tostring(parsed.remaining[3]))
  assert(parsed.remaining[4] == "--prompt", "fourth remaining should be '--prompt', got: " .. tostring(parsed.remaining[4]))
  assert(parsed.remaining[5] == "update-docs", "fifth remaining should be 'update-docs', got: " .. tostring(parsed.remaining[5]))
end
test_parse_args_work_subcommand_flags()

local function test_parse_args_top_level_opts_before_work()
  -- ah -m opus work --repo owner/repo
  -- Top-level -m should be parsed, work and its args should be in remaining.
  local parsed, err = init.parse_args({"-m", "opus", "work", "--repo", "owner/repo"})
  assert(parsed, "should parse successfully, got err: " .. tostring(err))
  assert(parsed.model == "opus", "model should be opus, got: " .. tostring(parsed.model))
  assert(parsed.remaining[1] == "work", "first remaining should be 'work', got: " .. tostring(parsed.remaining[1]))
  assert(parsed.remaining[2] == "--repo", "second remaining should be '--repo', got: " .. tostring(parsed.remaining[2]))
  assert(parsed.remaining[3] == "owner/repo", "third remaining should be 'owner/repo', got: " .. tostring(parsed.remaining[3]))
end
test_parse_args_top_level_opts_before_work()

local function test_parse_args_work_with_issue()
  -- ah work --repo owner/repo --issue 42
  local parsed, err = init.parse_args({"work", "--repo", "owner/repo", "--issue", "42"})
  assert(parsed, "should parse successfully, got err: " .. tostring(err))
  assert(parsed.remaining[1] == "work", "first remaining should be 'work'")
  assert(parsed.remaining[2] == "--repo", "--repo should be in remaining")
  assert(parsed.remaining[3] == "owner/repo", "repo value should be in remaining")
  assert(parsed.remaining[4] == "--issue", "--issue should be in remaining")
  assert(parsed.remaining[5] == "42", "issue number should be in remaining")
end
test_parse_args_work_with_issue()

-- Sandbox protect-dirs parsing

local record InitSandbox
  parse_protect_dirs: function(string): {string}
end
local init_sandbox = require("ah.init") as InitSandbox

local function test_parse_protect_dirs_single()
  local dirs = init_sandbox.parse_protect_dirs("o/work/plan")
  assert(#dirs == 1, "should have 1 dir, got: " .. #dirs)
  assert(dirs[1] == "o/work/plan", "dir should match, got: " .. dirs[1])
  print("✓ parse_protect_dirs handles single dir")
end
test_parse_protect_dirs_single()

local function test_parse_protect_dirs_multiple()
  local dirs = init_sandbox.parse_protect_dirs("o/work/plan:o/work/do")
  assert(#dirs == 2, "should have 2 dirs, got: " .. #dirs)
  assert(dirs[1] == "o/work/plan", "first dir, got: " .. dirs[1])
  assert(dirs[2] == "o/work/do", "second dir, got: " .. dirs[2])
  print("✓ parse_protect_dirs handles multiple dirs")
end
test_parse_protect_dirs_multiple()

local function test_parse_protect_dirs_nil()
  local dirs = init_sandbox.parse_protect_dirs(nil)
  assert(#dirs == 0, "nil should return empty table, got: " .. #dirs)
  print("✓ parse_protect_dirs returns empty for nil")
end
test_parse_protect_dirs_nil()

local function test_parse_protect_dirs_empty()
  local dirs = init_sandbox.parse_protect_dirs("")
  assert(#dirs == 0, "empty string should return empty table, got: " .. #dirs)
  print("✓ parse_protect_dirs returns empty for empty string")
end
test_parse_protect_dirs_empty()

-- Sandbox CLI flag parsing tests

local function test_parse_args_sandbox()
  local parsed = init.parse_args({"--sandbox", "hello"})
  assert(parsed, "should parse successfully")
  assert(parsed.sandbox == true, "sandbox should be true")
  assert(parsed.remaining[1] == "hello", "prompt should be in remaining")
  print("✓ parse_args: --sandbox flag")
end
test_parse_args_sandbox()

local function test_parse_args_timeout()
  local parsed = init.parse_args({"--timeout", "300", "hello"})
  assert(parsed, "should parse successfully")
  assert(parsed.timeout == 300, "timeout should be 300, got: " .. tostring(parsed.timeout))
  assert(parsed.remaining[1] == "hello", "prompt should be in remaining")
  print("✓ parse_args: --timeout flag")
end
test_parse_args_timeout()

local function test_parse_args_allow_host_single()
  local parsed = init.parse_args({"--allow-host", "api.example.com:443", "hello"})
  assert(parsed, "should parse successfully")
  assert(parsed.allow_hosts, "allow_hosts should be set")
  assert(#parsed.allow_hosts == 1, "should have 1 host, got: " .. #parsed.allow_hosts)
  assert(parsed.allow_hosts[1] == "api.example.com:443", "host mismatch, got: " .. parsed.allow_hosts[1])
  print("✓ parse_args: --allow-host single")
end
test_parse_args_allow_host_single()

local function test_parse_args_allow_host_multiple()
  local parsed = init.parse_args({"--allow-host", "api.example.com:443", "--allow-host", "hooks.slack.com:443", "hello"})
  assert(parsed, "should parse successfully")
  assert(#parsed.allow_hosts == 2, "should have 2 hosts, got: " .. #parsed.allow_hosts)
  assert(parsed.allow_hosts[1] == "api.example.com:443", "first host")
  assert(parsed.allow_hosts[2] == "hooks.slack.com:443", "second host")
  print("✓ parse_args: --allow-host multiple")
end
test_parse_args_allow_host_multiple()

local function test_parse_args_unveil_single()
  local parsed = init.parse_args({"--unveil", "o/work/plan:r", "hello"})
  assert(parsed, "should parse successfully")
  assert(parsed.unveil_dirs, "unveil_dirs should be set")
  assert(#parsed.unveil_dirs == 1, "should have 1 unveil, got: " .. #parsed.unveil_dirs)
  assert(parsed.unveil_dirs[1] == "o/work/plan:r", "unveil mismatch, got: " .. parsed.unveil_dirs[1])
  print("✓ parse_args: --unveil single")
end
test_parse_args_unveil_single()

local function test_parse_args_unveil_multiple()
  local parsed = init.parse_args({"--unveil", "o/work/plan:r", "--unveil", "o/work/do:rw", "hello"})
  assert(parsed, "should parse successfully")
  assert(#parsed.unveil_dirs == 2, "should have 2 unveils, got: " .. #parsed.unveil_dirs)
  assert(parsed.unveil_dirs[1] == "o/work/plan:r", "first unveil")
  assert(parsed.unveil_dirs[2] == "o/work/do:rw", "second unveil")
  print("✓ parse_args: --unveil multiple")
end
test_parse_args_unveil_multiple()

local function test_parse_args_sandbox_combined()
  local parsed = init.parse_args({
    "--sandbox", "--timeout", "180",
    "--allow-host", "hooks.slack.com:443",
    "--unveil", "o/work/plan:r",
    "-m", "opus", "--db", "test.db",
    "do the thing"
  })
  assert(parsed, "should parse successfully")
  assert(parsed.sandbox == true, "sandbox should be true")
  assert(parsed.timeout == 180, "timeout should be 180")
  assert(#parsed.allow_hosts == 1, "should have 1 allow-host")
  assert(parsed.allow_hosts[1] == "hooks.slack.com:443", "allow-host value")
  assert(#parsed.unveil_dirs == 1, "should have 1 unveil")
  assert(parsed.unveil_dirs[1] == "o/work/plan:r", "unveil value")
  assert(parsed.model == "opus", "model should be opus")
  assert(parsed.db_path == "test.db", "db should be test.db")
  assert(parsed.remaining[1] == "do the thing", "prompt in remaining")
  print("✓ parse_args: --sandbox combined with all flags")
end
test_parse_args_sandbox_combined()

local function test_parse_args_sandbox_with_work()
  -- --sandbox before work subcommand shouldn't interfere
  local parsed = init.parse_args({"--sandbox", "work", "--repo", "owner/repo"})
  assert(parsed, "should parse successfully")
  assert(parsed.sandbox == true, "sandbox should be true")
  assert(parsed.remaining[1] == "work", "work in remaining")
  assert(parsed.remaining[2] == "--repo", "--repo in remaining")
  assert(parsed.remaining[3] == "owner/repo", "repo value in remaining")
  print("✓ parse_args: --sandbox with work subcommand")
end
test_parse_args_sandbox_with_work()

local function test_parse_args_no_sandbox_defaults()
  local parsed = init.parse_args({"hello"})
  assert(parsed, "should parse successfully")
  assert(not parsed.sandbox, "sandbox should be nil/false by default")
  assert(not parsed.timeout, "timeout should be nil by default")
  assert(not parsed.allow_hosts or #parsed.allow_hosts == 0, "allow_hosts should be empty by default")
  assert(not parsed.unveil_dirs or #parsed.unveil_dirs == 0, "unveil_dirs should be empty by default")
  print("✓ parse_args: sandbox flags absent by default")
end
test_parse_args_no_sandbox_defaults()

-- parse_unveil helper tests

local function test_parse_unveil_entry()
  local path, perms = init.parse_unveil_entry("o/work/plan:r")
  assert(path == "o/work/plan", "path should be o/work/plan, got: " .. tostring(path))
  assert(perms == "r", "perms should be r, got: " .. tostring(perms))
  print("✓ parse_unveil_entry: basic")
end
test_parse_unveil_entry()

local function test_parse_unveil_entry_rw()
  local path, perms = init.parse_unveil_entry("src:rwc")
  assert(path == "src", "path should be src")
  assert(perms == "rwc", "perms should be rwc, got: " .. tostring(perms))
  print("✓ parse_unveil_entry: rwc perms")
end
test_parse_unveil_entry_rw()

local function test_parse_unveil_entry_absolute()
  local path, perms = init.parse_unveil_entry("/tmp:rwxc")
  assert(path == "/tmp", "path should be /tmp")
  assert(perms == "rwxc", "perms should be rwxc")
  print("✓ parse_unveil_entry: absolute path")
end
test_parse_unveil_entry_absolute()

local function test_parse_unveil_entry_no_perms()
  local path, perms = init.parse_unveil_entry("o/work/plan")
  assert(path == "o/work/plan", "path should be o/work/plan")
  assert(perms == "r", "perms should default to r, got: " .. tostring(perms))
  print("✓ parse_unveil_entry: defaults to r when no perms")
end
test_parse_unveil_entry_no_perms()

-- Help text completeness: every defined option must appear in usage_text()

local function test_usage_text_contains_all_options()
  local help = init.usage_text()
  assert(type(help) == "string", "usage_text() should return a string")
  assert(#help > 0, "usage_text() should not be empty")

  -- every long option defined in the parser must appear as --name in help
  local defined_options = {
    "help", "new", "session", "name", "db", "model", "output",
    "steer", "followup", "max-tokens", "sandbox", "timeout",
    "allow-host", "unveil", "skill", "must-produce",
  }
  for _, opt in ipairs(defined_options) do
    assert(help:find("--" .. opt, 1, true),
      "help text missing option: --" .. opt)
  end
  print("✓ usage_text contains all defined options")
end
test_usage_text_contains_all_options()

local function test_usage_text_contains_short_options()
  local help = init.usage_text()
  -- short aliases must also appear
  local short_options = {"-h", "-n", "-S", "-m", "-o"}
  for _, opt in ipairs(short_options) do
    assert(help:find(opt, 1, true),
      "help text missing short option: " .. opt)
  end
  print("✓ usage_text contains all short options")
end
test_usage_text_contains_short_options()

print("all init tests passed")
