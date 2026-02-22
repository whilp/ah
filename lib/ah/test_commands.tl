#!/usr/bin/env cosmic
-- test_commands.tl: tests for command loading and expansion
local commands = require("ah.commands")

-- Tests for parse_args
local function test_parse_args_simple()
  local args = commands.parse_args("foo bar baz")
  assert(#args == 3, "expected 3 args, got " .. #args)
  assert(args[1] == "foo", "arg 1 should be foo")
  assert(args[2] == "bar", "arg 2 should be bar")
  assert(args[3] == "baz", "arg 3 should be baz")
end
test_parse_args_simple()

local function test_parse_args_quoted()
  local args = commands.parse_args('"hello world" \'single quoted\'')
  assert(#args == 2, "expected 2 args, got " .. #args)
  assert(args[1] == "hello world", "arg 1 should be 'hello world', got: " .. args[1])
  assert(args[2] == "single quoted", "arg 2 should be 'single quoted', got: " .. args[2])
end
test_parse_args_quoted()

local function test_parse_args_mixed()
  local args = commands.parse_args('foo "bar baz" qux')
  assert(#args == 3, "expected 3 args, got " .. #args)
  assert(args[1] == "foo", "arg 1 should be foo")
  assert(args[2] == "bar baz", "arg 2 should be 'bar baz'")
  assert(args[3] == "qux", "arg 3 should be qux")
end
test_parse_args_mixed()

local function test_parse_args_escaped()
  local args = commands.parse_args('foo\\ bar "hello\\"world"')
  assert(#args == 2, "expected 2 args, got " .. #args)
  assert(args[1] == "foo bar", "arg 1 should be 'foo bar', got: " .. args[1])
  assert(args[2] == 'hello"world', "arg 2 should be 'hello\"world', got: " .. args[2])
end
test_parse_args_escaped()

local function test_parse_args_empty()
  local args = commands.parse_args("")
  assert(#args == 0, "expected 0 args, got " .. #args)
end
test_parse_args_empty()

local function test_parse_args_whitespace()
  local args = commands.parse_args("   foo   bar   ")
  assert(#args == 2, "expected 2 args, got " .. #args)
  assert(args[1] == "foo", "arg 1 should be foo")
  assert(args[2] == "bar", "arg 2 should be bar")
end
test_parse_args_whitespace()

-- Tests for substitute_args
local function test_substitute_positional()
  local result = commands.substitute_args("Hello $1!", {"world"})
  assert(result == "Hello world!", "expected 'Hello world!', got: " .. result)
end
test_substitute_positional()

local function test_substitute_multiple_positional()
  local result = commands.substitute_args("$1 and $2", {"foo", "bar"})
  assert(result == "foo and bar", "expected 'foo and bar', got: " .. result)
end
test_substitute_multiple_positional()

local function test_substitute_all_args()
  local result = commands.substitute_args("Args: $@", {"a", "b", "c"})
  assert(result == "Args: a b c", "expected 'Args: a b c', got: " .. result)
end
test_substitute_all_args()

local function test_substitute_arguments()
  local result = commands.substitute_args("Args: $ARGUMENTS", {"x", "y"})
  assert(result == "Args: x y", "expected 'Args: x y', got: " .. result)
end
test_substitute_arguments()

local function test_substitute_slice_with_length()
  local result = commands.substitute_args("Slice: ${@:2:2}", {"a", "b", "c", "d"})
  assert(result == "Slice: b c", "expected 'Slice: b c', got: " .. result)
end
test_substitute_slice_with_length()

local function test_substitute_slice_to_end()
  local result = commands.substitute_args("Slice: ${@:2}", {"a", "b", "c", "d"})
  assert(result == "Slice: b c d", "expected 'Slice: b c d', got: " .. result)
end
test_substitute_slice_to_end()

local function test_substitute_no_recursion()
  -- $1 contains $2, should not be expanded further
  local result = commands.substitute_args("$1", {"$2"})
  assert(result == "$2", "should not recursively expand, got: " .. result)
end
test_substitute_no_recursion()

local function test_substitute_missing_args()
  local result = commands.substitute_args("$1 $2 $3", {"only"})
  assert(result == "only $2 $3", "missing args should be left as-is, got: " .. result)
end
test_substitute_missing_args()

-- Tests for expand_command
local function test_expand_known_command()
  local cmds = {
    test = {name = "test", content = "Hello $1!"}
  }
  local expanded, was_cmd = commands.expand_command("/test world", cmds)
  assert(was_cmd == true, "should be a command")
  assert(expanded == "Hello world!", "expected 'Hello world!', got: " .. expanded)
end
test_expand_known_command()

local function test_expand_unknown_command()
  local cmds = {}
  local expanded, was_cmd = commands.expand_command("/unknown arg", cmds)
  assert(was_cmd == false, "should not be recognized as command")
  assert(expanded == "/unknown arg", "should pass through unchanged, got: " .. expanded)
end
test_expand_unknown_command()

local function test_expand_not_command()
  local cmds = {test = {name = "test", content = "Hello!"}}
  local expanded, was_cmd = commands.expand_command("not a /command", cmds)
  assert(was_cmd == false, "should not be a command")
  assert(expanded == "not a /command", "should pass through unchanged")
end
test_expand_not_command()

local function test_expand_command_no_args()
  local cmds = {hello = {name = "hello", content = "Just hello!"}}
  local expanded, was_cmd = commands.expand_command("/hello", cmds)
  assert(was_cmd == true, "should be a command")
  assert(expanded == "Just hello!", "expected 'Just hello!', got: " .. expanded)
end
test_expand_command_no_args()

local function test_expand_command_with_all_args()
  local cmds = {echo = {name = "echo", content = "You said: $@"}}
  local expanded, was_cmd = commands.expand_command("/echo hello world", cmds)
  assert(was_cmd == true, "should be a command")
  assert(expanded == "You said: hello world", "expected 'You said: hello world', got: " .. expanded)
end
test_expand_command_with_all_args()

local function test_expand_command_hyphen_underscore()
  local cmds = {
    ["my-cmd"] = {name = "my-cmd", content = "hyphen: $1"},
    ["my_cmd"] = {name = "my_cmd", content = "underscore: $1"}
  }
  local e1, w1 = commands.expand_command("/my-cmd test", cmds)
  assert(w1 == true, "hyphen command should work")
  assert(e1 == "hyphen: test", "expected 'hyphen: test', got: " .. e1)

  local e2, w2 = commands.expand_command("/my_cmd test", cmds)
  assert(w2 == true, "underscore command should work")
  assert(e2 == "underscore: test", "expected 'underscore: test', got: " .. e2)
end
test_expand_command_hyphen_underscore()

print("all commands tests passed")
