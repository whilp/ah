#!/usr/bin/env cosmic
-- test_looputil.tl: tests for ah.looputil module
local cfs = require("cosmic.fs")
local looputil = require("ah.looputil")

-- Tests for shorten_path
local function test_shorten_path_under_cwd()
  local cwd = cfs.getcwd() or "/tmp"
  local p = cwd .. "/foo/bar.txt"
  local short = looputil.shorten_path(p)
  assert(short == "foo/bar.txt", "should strip cwd prefix: " .. short)
  print("PASS: shorten_path strips cwd prefix")
end
test_shorten_path_under_cwd()

local function test_shorten_path_outside_cwd()
  local p = "/not/under/cwd/file.txt"
  local short = looputil.shorten_path(p)
  assert(short == p, "should leave paths outside cwd unchanged: " .. short)
  print("PASS: shorten_path leaves outside-cwd paths unchanged")
end
test_shorten_path_outside_cwd()

local function test_shorten_path_cwd_itself()
  local cwd = cfs.getcwd() or "/tmp"
  local short = looputil.shorten_path(cwd)
  assert(short == ".", "should return . for cwd itself: " .. short)
  print("PASS: shorten_path returns . for cwd itself")
end
test_shorten_path_cwd_itself()

local function test_shorten_path_empty()
  local short = looputil.shorten_path("")
  -- empty path does not start with cwd, so returned unchanged
  assert(short == "", "should return empty string unchanged: '" .. short .. "'")
  print("PASS: shorten_path handles empty string")
end
test_shorten_path_empty()

local function test_shorten_path_relative()
  local short = looputil.shorten_path("relative/path.txt")
  assert(short == "relative/path.txt", "should leave relative paths unchanged: " .. short)
  print("PASS: shorten_path leaves relative paths unchanged")
end
test_shorten_path_relative()

-- Tests for display_command
local function test_display_command_single_line()
  local cmd = "ls -la /tmp"
  local result = looputil.display_command(cmd)
  assert(result == cmd, "single-line command should be unchanged: " .. result)
  print("PASS: display_command single-line unchanged")
end
test_display_command_single_line()

local function test_display_command_multi_line()
  local cmd = "git log --oneline\ngit diff HEAD~1"
  local result = looputil.display_command(cmd)
  assert(result == "git log --oneline ...", "should collapse to first line + ' ...': " .. result)
  print("PASS: display_command multi-line collapses")
end
test_display_command_multi_line()

local function test_display_command_empty()
  local result = looputil.display_command("")
  assert(result == "", "empty string should return empty: '" .. result .. "'")
  print("PASS: display_command handles empty string")
end
test_display_command_empty()

-- Tests for display_command with && and \ continuations
local function test_display_command_ampersand()
  local cmd = "cd /tmp && ls -la && pwd"
  local result = looputil.display_command(cmd)
  assert(result == cmd, "single-line && command should be unchanged: " .. result)
  print("PASS: display_command preserves && commands")
end
test_display_command_ampersand()

local function test_display_command_backslash_continuation()
  local cmd = "gh pr create \\\n  --title 'fix' \\\n  --body 'desc'"
  local result = looputil.display_command(cmd)
  assert(result == "gh pr create ...", "should truncate at \\ continuation: " .. result)
  print("PASS: display_command truncates at \\ continuation")
end
test_display_command_backslash_continuation()

local function test_display_command_no_ampersand_match()
  local cmd = "ls --color=auto"
  local result = looputil.display_command(cmd)
  assert(result == cmd, "command without && should be unchanged: " .. result)
  print("PASS: display_command leaves command without && unchanged")
end
test_display_command_no_ampersand_match()

-- Tests for wrap_command
local function test_wrap_command_short()
  local cmd = "ls -la"
  local result = looputil.wrap_command(cmd, 80, "    ")
  assert(result == cmd, "short command should be unchanged: " .. result)
  print("PASS: wrap_command leaves short command unchanged")
end
test_wrap_command_short()

local function test_wrap_command_long_with_flags()
  local cmd = "gh issue list --repo whilp/ah --label todo --state open --json number,title --limit 100"
  local result = looputil.wrap_command(cmd, 60, "    ")
  assert(result:find("\\\n"), "long command should have continuation: " .. result)
  print("PASS: wrap_command wraps long command with flags")
end
test_wrap_command_long_with_flags()

local function test_wrap_command_ampersand_wraps()
  local cmd = "cd /tmp && ls -la && pwd"
  local result = looputil.wrap_command(cmd, 80, "    ")
  -- Should always break at && boundaries
  assert(result:find("&& \\\n"), "should break at &&: " .. result)
  assert(result:match("^cd /tmp"), "first segment preserved")
  assert(result:find("    ls %-la"), "second segment indented")
  assert(result:find("    pwd$"), "third segment indented")
  print("PASS: wrap_command always breaks at && boundaries")
end
test_wrap_command_ampersand_wraps()

local function test_wrap_command_ampersand_short()
  -- Even short && commands get broken
  local cmd = "a && b"
  local result = looputil.wrap_command(cmd, 80, "    ")
  assert(result == "a && \\\n    b", "short && should still break: " .. result)
  print("PASS: wrap_command breaks short && commands")
end
test_wrap_command_ampersand_short()

local function test_wrap_command_first_line_width()
  -- First line should respect width, not accumulate unlimited tokens
  local cmd = "echo aaa bbb ccc ddd eee fff --ggg --hhh"
  local result = looputil.wrap_command(cmd, 25, "    ")
  assert(result:find("\\\n"), "should wrap: " .. result)
  -- Every line (stripped of trailing " \") should fit within width
  for line in result:gmatch("[^\n]+") do
    local clean = line:gsub(" \\$", "")
    assert(#clean <= 25, "line exceeds width: [" .. #clean .. " chars] " .. line)
  end
  print("PASS: wrap_command respects width on first line")
end
test_wrap_command_first_line_width()

local function test_wrap_command_first_line_flag_break()
  -- Flag-aware breaking should work on the first line, not just continuations
  local cmd = "gh issue list --repo whilp/ah --label todo --state open"
  local result = looputil.wrap_command(cmd, 30, "    ")
  assert(result:find("\\\n"), "should wrap: " .. result)
  -- The flag pass should produce breaks at flag boundaries
  -- (not fall through to the space-boundary fallback)
  local first_line = result:match("^([^\n]+)")
  local clean = first_line:gsub(" \\$", "")
  assert(#clean <= 30, "first line exceeds width: [" .. #clean .. " chars] " .. first_line)
  print("PASS: wrap_command flag-aware breaking works on first line")
end
test_wrap_command_first_line_flag_break()

-- Tests for check_loop
local function test_check_loop_empty()
  local count = looputil.check_loop({})
  assert(count == 0, "empty history should return 0: " .. count)
  print("PASS: check_loop empty history returns 0")
end
test_check_loop_empty()

local function test_check_loop_single()
  local count = looputil.check_loop({"bash:ls"})
  assert(count == 1, "single entry should return 1: " .. count)
  print("PASS: check_loop single entry returns 1")
end
test_check_loop_single()

local function test_check_loop_no_repeat()
  local count = looputil.check_loop({"bash:ls", "read:/tmp/foo", "bash:pwd"})
  assert(count == 1, "no repeat should return 1: " .. count)
  print("PASS: check_loop no repeat returns 1")
end
test_check_loop_no_repeat()

local function test_check_loop_consecutive_repeats()
  local count = looputil.check_loop({"read:/tmp/a", "bash:ls", "bash:ls", "bash:ls"})
  assert(count == 3, "three consecutive identical should return 3: " .. count)
  print("PASS: check_loop consecutive repeats returns correct count")
end
test_check_loop_consecutive_repeats()

local function test_check_loop_broken_sequence()
  local count = looputil.check_loop({"bash:ls", "bash:ls", "read:/tmp/a", "bash:ls"})
  assert(count == 1, "broken sequence should return 1: " .. count)
  print("PASS: check_loop broken sequence returns 1")
end
test_check_loop_broken_sequence()

-- Tests for tool_key_param: read with offset/limit
local function test_tool_key_param_read_no_offset_limit()
  local key = looputil.tool_key_param("read", '{"path":"/tmp/foo.txt"}', nil)
  assert(key:find("foo%.txt$") ~= nil,
    "read without offset/limit should return path only: " .. key)
  -- should not contain : or +
  assert(not key:find("[:%+]"), "read without offset/limit should not have suffix: " .. key)
  print("PASS: tool_key_param read without offset/limit returns path only")
end
test_tool_key_param_read_no_offset_limit()

local function test_tool_key_param_read_offset_only()
  local key = looputil.tool_key_param("read", '{"path":"/tmp/foo.txt","offset":100}', nil)
  assert(key:find(":100$"), "read with offset only should append :offset: " .. key)
  print("PASS: tool_key_param read with offset only appends :N")
end
test_tool_key_param_read_offset_only()

local function test_tool_key_param_read_limit_only()
  local key = looputil.tool_key_param("read", '{"path":"/tmp/foo.txt","limit":50}', nil)
  assert(key:find(" %+50$"), "read with limit only should append +limit: " .. key)
  print("PASS: tool_key_param read with limit only appends +N")
end
test_tool_key_param_read_limit_only()

local function test_tool_key_param_read_offset_and_limit()
  local key = looputil.tool_key_param("read", '{"path":"/tmp/foo.txt","offset":100,"limit":50}', nil)
  assert(key:find(":100%+50$"), "read with both should append :offset+limit: " .. key)
  print("PASS: tool_key_param read with offset and limit appends :N+M")
end
test_tool_key_param_read_offset_and_limit()

-- Tests for tool_key_param type safety: numeric values from JSON decode
-- Reproduces: looputil.lua:46: attempt to compare number with string
-- When offset/limit come from JSON as strings instead of numbers,
-- the > 0 comparison crashes in Lua 5.4.

local function test_tool_key_param_read_string_offset()
  -- API might send offset as a string
  local key = looputil.tool_key_param("read", '{"path":"/tmp/foo.txt","offset":"100"}', nil)
  assert(key:find("foo%.txt"), "should still return path: " .. key)
  assert(key:find(":100"), "should handle string offset: " .. key)
  print("PASS: tool_key_param handles string offset without crash")
end
test_tool_key_param_read_string_offset()

local function test_tool_key_param_read_string_limit()
  -- API might send limit as a string
  local key = looputil.tool_key_param("read", '{"path":"/tmp/foo.txt","limit":"50"}', nil)
  assert(key:find("foo%.txt"), "should still return path: " .. key)
  assert(key:find("%+50"), "should handle string limit: " .. key)
  print("PASS: tool_key_param handles string limit without crash")
end
test_tool_key_param_read_string_limit()

local function test_tool_key_param_read_string_offset_and_limit()
  local key = looputil.tool_key_param("read", '{"path":"/tmp/foo.txt","offset":"100","limit":"50"}', nil)
  assert(key:find("foo%.txt"), "should still return path: " .. key)
  assert(key:find(":100%+50"), "should handle string offset+limit: " .. key)
  print("PASS: tool_key_param handles string offset and limit without crash")
end
test_tool_key_param_read_string_offset_and_limit()

local function test_tool_key_param_bash_numeric_command()
  -- edge case: command is a number
  local key = looputil.tool_key_param("bash", '{"command":42}', nil)
  assert(type(key) == "string", "should return string, got: " .. type(key))
  assert(key == "42", "should convert numeric command to string: " .. key)
  print("PASS: tool_key_param converts numeric command to string")
end
test_tool_key_param_bash_numeric_command()

local function test_tool_key_param_read_numeric_path()
  -- edge case: path is a number
  local key = looputil.tool_key_param("read", '{"path":123}', nil)
  assert(type(key) == "string", "should return string, got: " .. type(key))
  assert(key == "123", "should convert numeric path to string: " .. key)
  print("PASS: tool_key_param converts numeric path to string")
end
test_tool_key_param_read_numeric_path()

local function test_tool_key_param_details_numeric_command()
  -- details.command might be a number
  local key = looputil.tool_key_param("bash", '{"command":"ls"}', '{"command":42}')
  assert(type(key) == "string", "should return string from details, got: " .. type(key))
  assert(key == "42", "should convert numeric details.command: " .. key)
  print("PASS: tool_key_param converts numeric details.command to string")
end
test_tool_key_param_details_numeric_command()

local function test_tool_key_param_details_numeric_path()
  -- details.path might be a number
  local key = looputil.tool_key_param("read", '{}', '{"path":123}')
  assert(type(key) == "string", "should return string from details, got: " .. type(key))
  assert(key == "123", "should convert numeric details.path: " .. key)
  print("PASS: tool_key_param converts numeric details.path to string")
end
test_tool_key_param_details_numeric_path()

print("all looputil tests passed")
