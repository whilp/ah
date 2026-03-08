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

print("all looputil tests passed")
