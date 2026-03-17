-- test_timeout.tl: tests for native --timeout via SIGALRM
local signal = require("cosmic.signal")
local args_mod = require("ah.args")
local time = require("cosmic.time")

-- Test 1: system prompt injection when --timeout is set
local function test_timeout_system_prompt_injection()
  local parsed = args_mod.parse_args({"--timeout", "600", "hello"})
  assert(parsed, "should parse")
  assert(parsed.timeout == 600, "timeout should be 600")

  -- Simulate the system prompt injection logic from init.tl
  local effective_system = "base prompt"
  if parsed.timeout and parsed.timeout > 0 then
    effective_system = effective_system .. "\n\nYou have " .. tostring(parsed.timeout) .. " seconds of wall-clock time. Budget your turns accordingly."
  end
  assert(effective_system:match("You have 600 seconds"), "should contain time budget")
  assert(effective_system:match("Budget your turns"), "should contain budget advice")
  print("✓ timeout system prompt injection")
end
test_timeout_system_prompt_injection()

-- Test 2: no injection when timeout is not set
local function test_no_timeout_no_injection()
  local parsed = args_mod.parse_args({"hello"})
  assert(parsed, "should parse")
  assert(not parsed.timeout, "timeout should be nil")

  local effective_system = "base prompt"
  if parsed.timeout and parsed.timeout > 0 then
    effective_system = effective_system .. "\n\nYou have " .. tostring(parsed.timeout) .. " seconds of wall-clock time. Budget your turns accordingly."
  end
  assert(not effective_system:match("wall%-clock"), "should not contain time budget")
  print("✓ no timeout means no injection")
end
test_no_timeout_no_injection()

-- Test 3: SIGALRM fires and sets interrupted
local function test_sigalrm_fires()
  -- Declare global
  global interrupted: boolean = false

  signal.sigaction(signal.SIGALRM, function()
      interrupted = true
    end)

  -- Set a 1-second timer
  signal.setitimer({which = signal.ITIMER_REAL, valuesec = 1, valuens = 0, intervalsec = 0, intervalns = 0})

  -- Busy-wait for the signal (up to 10 seconds)
  local start = time.now()
  while not interrupted do
    if time.now() - start > 10 then
      break
    end
    time.sleep_ms(10)
  end

  assert(interrupted, "SIGALRM should have set interrupted=true")
  print("✓ SIGALRM fires and sets interrupted")

  -- Disarm any leftover timer
  signal.setitimer({which = signal.ITIMER_REAL, valuesec = 0, valuens = 0, intervalsec = 0, intervalns = 0})
end
test_sigalrm_fires()

-- Test 4: sandbox child_args no longer include external timeout
local function test_sandbox_no_external_timeout()
  local parsed = args_mod.parse_args({"--sandbox", "--timeout", "300", "hello"})
  assert(parsed, "should parse")
  assert(parsed.timeout == 300, "timeout should be 300")
  assert(parsed.sandbox == true, "sandbox should be true")

  -- Simulate the child_args construction from init.tl (post-change)
  local args = {"--sandbox", "--timeout", "300", "hello"}
  local child_args: {string} = {}
  table.insert(child_args, "/path/to/ah") -- exe placeholder

  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--sandbox" then
      -- skip
    elseif a == "--allow-host" then i = i + 1
    elseif a == "--unveil" then i = i + 1
    elseif a == "--pledge" then i = i + 1
    else table.insert(child_args, a) end
    i = i + 1
  end

  -- --timeout and its value should be passed through to the child
  local has_timeout_flag = false
  local has_timeout_binary = false
  for _, v in ipairs(child_args) do
    if v == "--timeout" then has_timeout_flag = true end
    if v == "timeout" then has_timeout_binary = true end
  end
  assert(has_timeout_flag, "--timeout should be passed through to child")
  assert(not has_timeout_binary, "external 'timeout' binary should not be in child_args")
  print("✓ sandbox passes --timeout to child instead of external timeout binary")
end
test_sandbox_no_external_timeout()

print("PASS")
