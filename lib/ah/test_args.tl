#!/usr/bin/env cosmic
-- test_args.tl: tests for CLI argument parsing
local args_mod = require("ah.args")

-- Also test backward-compatible access through init
local init = require("ah.init")

local function test_parse_args_help()
  local parsed, err = args_mod.parse_args({"-h"})
  assert(not parsed, "help should return nil")
  assert(err == "help", "err should be 'help', got: " .. tostring(err))
end
test_parse_args_help()

local function test_parse_args_long_help()
  local parsed, err = args_mod.parse_args({"--help"})
  assert(not parsed, "--help should return nil")
  assert(err == "help", "err should be 'help', got: " .. tostring(err))
end
test_parse_args_long_help()

local function test_parse_args_model()
  local parsed = args_mod.parse_args({"-m", "opus"})
  assert(parsed, "should parse successfully")
  assert(parsed.model == "opus", "model should be opus, got: " .. tostring(parsed.model))
end
test_parse_args_model()

local function test_parse_args_unknown_option()
  local parsed, err = args_mod.parse_args({"--bogus"})
  assert(not parsed, "unknown option should return nil")
  assert(err == "unknown", "err should be 'unknown', got: " .. tostring(err))
end
test_parse_args_unknown_option()

local function test_parse_args_work_subcommand_flags()
  local parsed, err = args_mod.parse_args({"work", "--repo", "owner/repo", "--prompt", "update-docs"})
  assert(parsed, "work subcommand args should not be rejected, got err: " .. tostring(err))
  assert(parsed.remaining[1] == "work", "first remaining should be 'work'")
  assert(parsed.remaining[2] == "--repo", "second remaining should be '--repo'")
  assert(parsed.remaining[3] == "owner/repo", "third remaining should be 'owner/repo'")
  assert(parsed.remaining[4] == "--prompt", "fourth remaining should be '--prompt'")
  assert(parsed.remaining[5] == "update-docs", "fifth remaining should be 'update-docs'")
end
test_parse_args_work_subcommand_flags()

local function test_parse_args_top_level_opts_before_work()
  local parsed, err = args_mod.parse_args({"-m", "opus", "work", "--repo", "owner/repo"})
  assert(parsed, "should parse successfully, got err: " .. tostring(err))
  assert(parsed.model == "opus", "model should be opus")
  assert(parsed.remaining[1] == "work", "first remaining should be 'work'")
end
test_parse_args_top_level_opts_before_work()

local function test_parse_args_work_with_issue()
  local parsed, err = args_mod.parse_args({"work", "--repo", "owner/repo", "--issue", "42"})
  assert(parsed, "should parse successfully, got err: " .. tostring(err))
  assert(parsed.remaining[1] == "work", "first remaining should be 'work'")
  assert(parsed.remaining[4] == "--issue", "--issue should be in remaining")
  assert(parsed.remaining[5] == "42", "issue number should be in remaining")
end
test_parse_args_work_with_issue()

local function test_parse_args_cd()
  local parsed = args_mod.parse_args({"--cd", "/path/to/project", "hello"})
  assert(parsed, "should parse successfully")
  assert(parsed.cd_path == "/path/to/project", "cd_path should be /path/to/project")
  assert(parsed.remaining[1] == "hello", "prompt should be in remaining")
end
test_parse_args_cd()

-- Sandbox protect-dirs parsing

local function test_parse_protect_dirs_single()
  local dirs = args_mod.parse_protect_dirs("o/work/plan")
  assert(#dirs == 1, "should have 1 dir, got: " .. #dirs)
  assert(dirs[1] == "o/work/plan", "dir should match")
end
test_parse_protect_dirs_single()

local function test_parse_protect_dirs_multiple()
  local dirs = args_mod.parse_protect_dirs("o/work/plan:o/work/do")
  assert(#dirs == 2, "should have 2 dirs, got: " .. #dirs)
  assert(dirs[1] == "o/work/plan", "first dir")
  assert(dirs[2] == "o/work/do", "second dir")
end
test_parse_protect_dirs_multiple()

local function test_parse_protect_dirs_nil()
  local dirs = args_mod.parse_protect_dirs(nil)
  assert(#dirs == 0, "nil should return empty table")
end
test_parse_protect_dirs_nil()

local function test_parse_protect_dirs_empty()
  local dirs = args_mod.parse_protect_dirs("")
  assert(#dirs == 0, "empty string should return empty table")
end
test_parse_protect_dirs_empty()

-- Sandbox CLI flag parsing

local function test_parse_args_sandbox()
  local parsed = args_mod.parse_args({"--sandbox", "hello"})
  assert(parsed, "should parse successfully")
  assert(parsed.sandbox == true, "sandbox should be true")
end
test_parse_args_sandbox()

local function test_parse_args_timeout()
  local parsed = args_mod.parse_args({"--timeout", "300", "hello"})
  assert(parsed, "should parse successfully")
  assert(parsed.timeout == 300, "timeout should be 300")
end
test_parse_args_timeout()

local function test_parse_args_allow_host_single()
  local parsed = args_mod.parse_args({"--sandbox", "--allow-host", "api.example.com:443", "hello"})
  assert(parsed, "should parse successfully")
  assert(#parsed.allow_hosts == 1, "should have 1 host")
  assert(parsed.allow_hosts[1] == "api.example.com:443", "host mismatch")
end
test_parse_args_allow_host_single()

local function test_parse_args_allow_host_multiple()
  local parsed = args_mod.parse_args({"--sandbox", "--allow-host", "api.example.com:443", "--allow-host", "hooks.slack.com:443", "hello"})
  assert(parsed, "should parse successfully")
  assert(#parsed.allow_hosts == 2, "should have 2 hosts")
end
test_parse_args_allow_host_multiple()

local function test_parse_args_unveil_single()
  local parsed = args_mod.parse_args({"--sandbox", "--unveil", "o/work/plan:r", "hello"})
  assert(parsed, "should parse successfully")
  assert(#parsed.unveil_dirs == 1, "should have 1 unveil")
end
test_parse_args_unveil_single()

local function test_parse_args_unveil_multiple()
  local parsed = args_mod.parse_args({"--sandbox", "--unveil", "o/work/plan:r", "--unveil", "o/work/do:rw", "hello"})
  assert(parsed, "should parse successfully")
  assert(#parsed.unveil_dirs == 2, "should have 2 unveils")
end
test_parse_args_unveil_multiple()

local function test_parse_args_sandbox_combined()
  local parsed = args_mod.parse_args({
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
  assert(#parsed.unveil_dirs == 1, "should have 1 unveil")
  assert(parsed.model == "opus", "model should be opus")
  assert(parsed.db_path == "test.db", "db should be test.db")
end
test_parse_args_sandbox_combined()

local function test_parse_args_sandbox_with_work()
  local parsed = args_mod.parse_args({"--sandbox", "work", "--repo", "owner/repo"})
  assert(parsed, "should parse successfully")
  assert(parsed.sandbox == true, "sandbox should be true")
  assert(parsed.remaining[1] == "work", "work in remaining")
end
test_parse_args_sandbox_with_work()

local function test_parse_args_no_sandbox_defaults()
  local parsed = args_mod.parse_args({"hello"})
  assert(parsed, "should parse successfully")
  assert(not parsed.sandbox, "sandbox should be false by default")
end
test_parse_args_no_sandbox_defaults()

-- parse_unveil helper tests

local function test_parse_unveil_entry()
  local path, perms = args_mod.parse_unveil_entry("o/work/plan:r")
  assert(path == "o/work/plan", "path should be o/work/plan")
  assert(perms == "r", "perms should be r")
end
test_parse_unveil_entry()

local function test_parse_unveil_entry_rw()
  local path, perms = args_mod.parse_unveil_entry("src:rwc")
  assert(path == "src", "path should be src")
  assert(perms == "rwc", "perms should be rwc")
end
test_parse_unveil_entry_rw()

local function test_parse_unveil_entry_absolute()
  local path, perms = args_mod.parse_unveil_entry("/tmp:rwxc")
  assert(path == "/tmp", "path should be /tmp")
  assert(perms == "rwxc", "perms should be rwxc")
end
test_parse_unveil_entry_absolute()

local function test_parse_unveil_entry_no_perms()
  local path, perms = args_mod.parse_unveil_entry("o/work/plan")
  assert(path == "o/work/plan", "path should be o/work/plan")
  assert(perms == "r", "perms should default to r")
end
test_parse_unveil_entry_no_perms()

-- Help text completeness

local function get_help_text(): string
  local ah_bin = os.getenv("AH_BIN")
  assert(ah_bin, "AH_BIN not set — need built binary")
  local f = io.popen(ah_bin .. " --help 2>&1")
  assert(f, "failed to run ah --help")
  local help = f:read("*a") as string
  f:close()
  return help
end

local function test_usage_text_contains_all_options()
  local help = get_help_text()
  assert(#help > 0, "ah --help should produce output")
  local defined_options = {
    "help", "new", "session", "name", "db", "model", "output", "cd",
    "steer", "followup", "max-tokens", "sandbox", "timeout",
    "allow-host", "unveil", "skill", "must-produce",
  }
  for _, opt in ipairs(defined_options) do
    assert(help:find("--" .. opt, 1, true), "help text missing option: --" .. opt)
  end
end
test_usage_text_contains_all_options()

local function test_usage_text_contains_short_options()
  local help = get_help_text()
  local short_options = {"-h", "-n", "-S", "-m", "-o"}
  for _, opt in ipairs(short_options) do
    assert(help:find(opt, 1, true), "help text missing short option: " .. opt)
  end
end
test_usage_text_contains_short_options()

local function test_parse_args_tool()
  local parsed = args_mod.parse_args({"--tool", "foo=/usr/bin/foo", "-t", "bar=/tmp/bar", "hello"})
  assert(parsed, "should parse --tool args")
  assert(#parsed.tool_overrides == 2, "should have 2 tool overrides")
  assert(parsed.tool_overrides[1] == "foo=/usr/bin/foo", "first override")
  assert(parsed.tool_overrides[2] == "bar=/tmp/bar", "second override")
end
test_parse_args_tool()

-- Sandbox sub-option validation

local function test_parse_args_unveil_without_sandbox()
  local parsed, err = args_mod.parse_args({"--unveil", "/tmp:r", "hello"})
  assert(not parsed, "--unveil without --sandbox should fail")
  assert(err == "error: --unveil requires --sandbox", "err mismatch: " .. tostring(err))
end
test_parse_args_unveil_without_sandbox()

local function test_parse_args_allow_host_without_sandbox()
  local parsed, err = args_mod.parse_args({"--allow-host", "example.com:443", "hello"})
  assert(not parsed, "--allow-host without --sandbox should fail")
  assert(err == "error: --allow-host requires --sandbox", "err mismatch: " .. tostring(err))
end
test_parse_args_allow_host_without_sandbox()

local function test_parse_args_sandbox_with_unveil()
  local parsed = args_mod.parse_args({"--sandbox", "--unveil", "/tmp:r", "hello"})
  assert(parsed, "--sandbox --unveil should succeed")
  assert(parsed.sandbox == true, "sandbox should be true")
end
test_parse_args_sandbox_with_unveil()

local function test_parse_args_sandbox_with_allow_host()
  local parsed = args_mod.parse_args({"--sandbox", "--allow-host", "example.com:443", "hello"})
  assert(parsed, "--sandbox --allow-host should succeed")
  assert(parsed.sandbox == true, "sandbox should be true")
end
test_parse_args_sandbox_with_allow_host()

-- parse_subcommand_options tests

local function test_parse_subcommand_options_long_flag()
  local opts: {args_mod.OptionDef} = {{name = "output", short = "o", has_arg = "required"}}
  local result = args_mod.parse_subcommand_options({"--output", "o/bin/ah"}, opts)
  assert(result.output == "o/bin/ah", "expected 'o/bin/ah', got: " .. tostring(result.output))
end
test_parse_subcommand_options_long_flag()

local function test_parse_subcommand_options_short_flag()
  local opts: {args_mod.OptionDef} = {{name = "output", short = "o", has_arg = "required"}}
  local result = args_mod.parse_subcommand_options({"-o", "o/bin/ah"}, opts)
  assert(result.output == "o/bin/ah", "expected 'o/bin/ah'")
end
test_parse_subcommand_options_short_flag()

local function test_parse_subcommand_options_short_no_space()
  local opts: {args_mod.OptionDef} = {{name = "output", short = "o", has_arg = "required"}}
  local result = args_mod.parse_subcommand_options({"-oo/bin/ah"}, opts)
  assert(result.output == "o/bin/ah", "expected 'o/bin/ah'")
end
test_parse_subcommand_options_short_no_space()

local function test_parse_subcommand_options_none()
  local opts: {args_mod.OptionDef} = {{name = "output", short = "o", has_arg = "required"}}
  local result = args_mod.parse_subcommand_options({"somefile"}, opts)
  assert(result.output == nil, "expected nil")
end
test_parse_subcommand_options_none()

local function test_parse_subcommand_options_empty()
  local opts: {args_mod.OptionDef} = {{name = "output", short = "o", has_arg = "required"}}
  local result = args_mod.parse_subcommand_options({}, opts)
  assert(result.output == nil, "expected nil for empty args")
end
test_parse_subcommand_options_empty()

local function test_parse_subcommand_options_last_wins()
  local opts: {args_mod.OptionDef} = {{name = "output", short = "o", has_arg = "required"}}
  local result = args_mod.parse_subcommand_options({"--output", "first", "--output", "second"}, opts)
  assert(result.output == "second", "expected 'second'")
end
test_parse_subcommand_options_last_wins()

local function test_parse_subcommand_options_multiple()
  local opts: {args_mod.OptionDef} = {
    {name = "output", short = "o", has_arg = "required"},
    {name = "verbose", short = "v", has_arg = "none"}
  }
  local result = args_mod.parse_subcommand_options({"-v", "--output", "out.bin"}, opts)
  assert(result.verbose == "true", "expected verbose='true'")
  assert(result.output == "out.bin", "expected output='out.bin'")
end
test_parse_subcommand_options_multiple()

local function test_parse_subcommand_options_flag_no_arg()
  local opts: {args_mod.OptionDef} = {{name = "verbose", short = "v", has_arg = "none"}}
  local result = args_mod.parse_subcommand_options({"-v", "otherarg"}, opts)
  assert(result.verbose == "true", "expected verbose='true'")
end
test_parse_subcommand_options_flag_no_arg()

local function test_parse_args_embed_remaining_contains_output()
  local parsed = args_mod.parse_args({"embed", "mydir", "--output", "o/bin/ah"})
  assert(parsed.remaining[1] == "embed", "remaining[1] should be 'embed'")
  assert(parsed.remaining[2] == "mydir", "remaining[2] should be 'mydir'")
  assert(parsed.remaining[3] == "--output", "remaining[3] should be '--output'")
  assert(parsed.remaining[4] == "o/bin/ah", "remaining[4] should be 'o/bin/ah'")
  assert(parsed.output_path == nil, "top-level output_path should be nil")
end
test_parse_args_embed_remaining_contains_output()

-- Verify backward-compatible access through init module

local function test_backward_compat_init_parse_args()
  local parsed = init.parse_args({"-m", "opus"})
  assert(parsed, "init.parse_args should still work")
  assert(parsed.model == "opus", "should parse model through init")
end
test_backward_compat_init_parse_args()

print("all args tests passed")
