-- sys/tools/lua.tl: execute Lua code in a sandboxed environment
-- Only allowlisted safe functions are available; unsafe functions
-- (os, io, load, require, etc.) are blocked.

-- Build the restricted environment for sandboxed execution.
-- Uses Lua 5.4's load(chunk, chunkname, mode, env) to restrict globals.
local function make_sandbox_env(print_buf: {string}): {string: any}
  local env: {string: any} = {}

  -- Safe math functions
  env["math"] = {
    abs = math.abs,
    ceil = math.ceil,
    floor = math.floor,
    sqrt = math.sqrt,
    max = math.max,
    min = math.min,
    fmod = math.fmod,
    modf = math.modf,
    sin = math.sin,
    cos = math.cos,
    tan = math.tan,
    asin = math.asin,
    acos = math.acos,
    atan = math.atan,
    exp = math.exp,
    log = math.log,
    pow = (math as {string: any})["pow"],
    pi = math.pi,
    huge = math.huge,
    maxinteger = math.maxinteger,
    mininteger = math.mininteger,
    tointeger = math.tointeger,
    type = (math as {string: any})["type"],
    random = math.random,
    randomseed = math.randomseed,
  }

  -- Safe string functions (exclude string.dump which exposes bytecode)
  env["string"] = {
    byte = string.byte,
    char = string.char,
    find = string.find,
    format = string.format,
    gmatch = string.gmatch,
    gsub = string.gsub,
    len = string.len,
    lower = string.lower,
    match = string.match,
    rep = string.rep,
    reverse = string.reverse,
    sub = string.sub,
    upper = string.upper,
  }

  -- Safe table functions
  env["table"] = {
    concat = table.concat,
    insert = table.insert,
    move = table.move,
    remove = table.remove,
    sort = table.sort,
    unpack = table.unpack,
  }

  -- Safe coroutine functions (pure, no I/O)
  env["coroutine"] = {
    create = coroutine.create,
    isyieldable = coroutine.isyieldable,
    resume = coroutine.resume,
    running = coroutine.running,
    status = coroutine.status,
    wrap = coroutine.wrap,
    yield = coroutine.yield,
  }

  -- Safe global functions
  env["ipairs"] = ipairs
  env["pairs"] = pairs
  env["next"] = next
  env["select"] = select
  env["type"] = type
  env["tostring"] = tostring
  env["tonumber"] = tonumber
  env["pcall"] = pcall
  env["xpcall"] = xpcall
  env["error"] = error
  env["assert"] = assert
  env["rawget"] = rawget
  env["rawset"] = rawset
  env["rawequal"] = rawequal
  env["rawlen"] = rawlen
  env["unpack"] = table.unpack

  -- Capture print output into a buffer
  env["print"] = function(...: any)
    local parts: {string} = {}
    local n = select("#", ...)
    for i = 1, n do
      table.insert(parts, tostring(select(i, ...)))
    end
    table.insert(print_buf, table.concat(parts, "\t"))
  end

  -- Point _ENV at itself for code that references _ENV
  env["_ENV"] = env as any

  return env
end

-- Default instruction limit (guards against infinite loops)
local DEFAULT_INSTRUCTION_LIMIT = 1000000

return {
  name = "lua",
  description = "Execute a Lua expression or script in a sandboxed environment. Only safe standard functions are available; os, io, require, load, and other unsafe functions are blocked.",
  input_schema = {
    type = "object",
    properties = {
      code = {type = "string", description = "Lua code to execute"},
      instruction_limit = {type = "integer", description = "Max VM instructions before aborting (default: 1000000)"},
    },
    required = {"code"},
  },
  execute = function(input: {string: any}): string, boolean, any
    local code = input.code as string
    if not code or code == "" then
      return "error: code is required", true
    end

    local limit = (input.instruction_limit as integer) or DEFAULT_INSTRUCTION_LIMIT

    -- Buffer for captured print() output
    local print_buf: {string} = {}
    local env = make_sandbox_env(print_buf)

    -- Load in text mode with restricted environment.
    -- Cast through any to use Lua 5.4's 4-argument form of load().
    local load_fn = load as function(string, string, string, {string: any}): (function(), string)
    local chunk, load_err = load_fn(code, "lua", "t", env)
    if not chunk then
      return "error: " .. tostring(load_err), true
    end

    -- Set instruction count hook to abort infinite loops.
    -- Cast debug through any to call sethook with/without args.
    local debug_any = debug as {string: any}
    local sethook = debug_any["sethook"] as function(function(), string, integer)
    local sethook_clear = debug_any["sethook"] as function()
    local instruction_count = 0
    local limit_exceeded = false
    sethook(function()
        instruction_count = instruction_count + 1
        if instruction_count > limit then
          limit_exceeded = true
          error("instruction limit exceeded (" .. limit .. " instructions)", 2)
        end
      end, "", 1000)

    -- Execute the chunk, capturing return values and errors
    local results: {any} = {pcall(chunk)}
    sethook_clear()

    local ok = results[1] as boolean
    local output_parts: {string} = {}

    -- Include any printed output first
    for _, line in ipairs(print_buf) do
      table.insert(output_parts, line)
    end

    if not ok then
      local err_msg = tostring(results[2])
      if limit_exceeded then
        return "error: instruction limit exceeded (" .. limit .. " instructions)", true
      end
      return "error: " .. err_msg, true
    end

    -- Append return values (skip index 1 which is the ok bool)
    local ret_parts: {string} = {}
    for i = 2, #results do
      table.insert(ret_parts, tostring(results[i]))
    end
    if #ret_parts > 0 then
      table.insert(output_parts, table.concat(ret_parts, "\t"))
    end

    local output = table.concat(output_parts, "\n")
    if output == "" then
      output = "(no output)"
    end

    return output, false, {instruction_count = instruction_count}
  end,
}
