-- ah/init.tl: CLI entry, session management, agent orchestration
local fs = require("cosmic.fs")
local cio = require("cosmic.io")
local tty = require("cosmic.tty")
local proc = require("cosmic.proc")
local signal = require("cosmic.signal")

local zip = require("cosmic.zip")
local embed = require("cosmic.embed")
local db = require("ah.db")
local api = require("ah.api")
local tools = require("ah.tools")
local commands = require("ah.commands")
local skills = require("ah.skills")
local loop = require("ah.loop")
local events = require("ah.events")
local ulid = require("ulid")
local queue = require("ah.queue")
local sandbox = require("cosmic.sandbox")
local util = require("ah.util")
local envd = require("cosmic.envd")
local compact = require("ah.compact")
local args_mod = require("ah.args")
local sessions_mod = require("ah.sessions")
local prompt_mod = require("ah.prompt")
local cli_mod = require("ah.cli")

-- Global for signal handling
global interrupted: boolean = false

-- Record types for sandbox supervisor mode (lazy-loaded modules)
local record SandboxCtx
  enabled: boolean
  socket_path: string
  proxy_pid: number
  tmpdir: string
end

local record SandboxMod
  start_sandbox: function(): SandboxCtx, string
  stop_sandbox: function(SandboxCtx)
  prepare_child_stdin: function(): string
  ah_exe: function(): string
  setup_git_env: function({string})
  env_set: function({string}, string, string)
end

local record FetchMod
  unix_proxy: function(string): string, string
end

local record ChildMod
  spawn: function({string}, {string: any}): ChildHandle, string
end

local record ChildHandle
  stderr: StderrHandle
  read: function(ChildHandle): boolean, string, string
end

local record StderrHandle
  read: function(StderrHandle): string
end

local function main(args: {string}): integer, string
  -- Load embedded env.d/ variables before anything else.
  envd.load()

  -- Enable core dumps for crash debugging
  proc.setrlimit(4, -1, -1)

  -- Sandbox mode: when AH_SANDBOX=1, restrict capabilities
  if os.getenv("AH_SANDBOX") then
    local cwd_for_unveil = fs.getcwd()
    sandbox.unveil(cwd_for_unveil, "rwxc")
    local protect = args_mod.parse_protect_dirs(os.getenv("AH_PROTECT_DIRS"))
    for _, dir in ipairs(protect) do
      sandbox.unveil(cwd_for_unveil .. "/" .. dir, "r")
    end
    local unveil_env = os.getenv("AH_UNVEIL")
    if unveil_env then
      for entry in unveil_env:gmatch("[^,]+") do
        local u_path, u_perms = args_mod.parse_unveil_entry(entry)
        if u_path:sub(1, 1) == "/" then
          sandbox.unveil(u_path, u_perms)
        else
          sandbox.unveil(cwd_for_unveil .. "/" .. u_path, u_perms)
        end
      end
    end
    sandbox.unveil("/tmp", "rwxc")
    sandbox.unveil("/usr", "rx")
    sandbox.unveil("/bin", "rx")
    sandbox.unveil("/lib", "rx")
    sandbox.unveil("/lib64", "rx")
    sandbox.unveil("/etc/ssl", "r")
    sandbox.unveil("/etc/resolv.conf", "r")
    sandbox.unveil("/dev/null", "rw")
    sandbox.unveil("/dev/tty", "rw")
    sandbox.unveil("/proc/self", "r")
    local home = os.getenv("HOME")
    if home then
      sandbox.unveil(home, "r")
    end
    sandbox.unveil(nil, nil)

    local PLEDGE_PENALTY_RETURN_EPERM = 2
    local promises = "stdio rpath wpath cpath flock tty proc exec execnative unix prot_exec"
    sandbox.pledge(promises, promises, PLEDGE_PENALTY_RETURN_EPERM)
  end

  local parsed, err = args_mod.parse_args(args)
  if not parsed then
    if err == "version" then
      local mod = "ah.version"
      local ok, version = pcall(require, mod)
      io.write("ah " .. (ok and version as string or "dev") .. "\n")
      return 0
    end
    if err and err:sub(1, 6) == "error:" then
      io.stderr:write(err .. "\n")
      return 1
    end
    args_mod.usage()
    if err == "help" then return 0 end
    return 1
  end

  if parsed.cd_path then
    local ok, chdir_err = pcall(fs.chdir, parsed.cd_path)
    if not ok then
      io.stderr:write("error: failed to change directory to " .. parsed.cd_path .. ": " .. tostring(chdir_err) .. "\n")
      return 1
    end
  end

  local cwd = fs.getcwd()
  local model = parsed.model
  local db_path = parsed.db_path
  local output_path = parsed.output_path
  local new_session = parsed.new_session
  local session_prefix = parsed.session_prefix
  local session_name = parsed.session_name
  local steer_msg = parsed.steer_msg
  local followup_msg = parsed.followup_msg
  local max_tokens = parsed.max_session_tokens
  local remaining = parsed.remaining

  -- Supervisor mode: --sandbox starts proxy, re-execs as sandboxed child
  if parsed.sandbox then
    local sbox = require("ah.sandbox") as SandboxMod
    local fetch = require("cosmic.fetch") as FetchMod

    local ctx, sbox_err = sbox.start_sandbox()
    if not ctx then
      io.stderr:write("error: sandbox failed to start: " .. (sbox_err or "unknown") .. "\n")
      return 1
    end
    util.debug("[sandbox] proxy started on " .. ctx.socket_path)

    local unix = require("cosmo.unix")
    local run_env: {string} = unix.environ() as {string}
    sbox.setup_git_env(run_env)
    sbox.env_set(run_env, "TMPDIR", ctx.tmpdir)

    local proxy_url, proxy_err = fetch.unix_proxy(ctx.socket_path)
    if not proxy_url then
      io.stderr:write("[sandbox] invalid proxy path: " .. (proxy_err or "unknown") .. "\n")
      sbox.stop_sandbox(ctx)
      return 1
    end
    sbox.env_set(run_env, "http_proxy", proxy_url)
    sbox.env_set(run_env, "HTTP_PROXY", proxy_url)
    sbox.env_set(run_env, "https_proxy", proxy_url)
    sbox.env_set(run_env, "HTTPS_PROXY", proxy_url)
    sbox.env_set(run_env, "AH_SANDBOX", "1")

    if #parsed.allow_hosts > 0 then
      sbox.env_set(run_env, "AH_ALLOW_HOSTS", table.concat(parsed.allow_hosts, ","))
    end
    if #parsed.unveil_dirs > 0 then
      sbox.env_set(run_env, "AH_UNVEIL", table.concat(parsed.unveil_dirs, ","))
    end

    local child_args: {string} = {}
    local exe = sbox.ah_exe()
    if parsed.timeout and parsed.timeout > 0 then
      table.insert(child_args, "timeout")
      table.insert(child_args, tostring(parsed.timeout))
    end
    table.insert(child_args, exe)

    local i = 1
    while i <= #args do
      local a = args[i]
      if a == "--sandbox" then
        -- skip
      elseif a == "--timeout" then i = i + 1
      elseif a == "--allow-host" then i = i + 1
      elseif a == "--unveil" then i = i + 1
      else table.insert(child_args, a) end
      i = i + 1
    end

    local parent_stdin = sbox.prepare_child_stdin()
    local child_mod = require("cosmic.child") as ChildMod
    util.debug("[sandbox] spawning child: " .. table.concat(child_args, " "))
    local handle, spawn_err = child_mod.spawn(child_args, {env = run_env, stdin = parent_stdin})
    if not handle then
      io.stderr:write("error: failed to spawn sandboxed child: " .. (spawn_err or "unknown") .. "\n")
      sbox.stop_sandbox(ctx)
      return 1
    end

    local stderr_out = handle.stderr:read()
    local ok, stdout, exit_str = handle:read()
    local exit_code = (tonumber(exit_str) or 0) as integer
    if stderr_out and stderr_out ~= "" then io.stderr:write(stderr_out) end
    if stdout and stdout ~= "" then io.write(stdout) end
    util.debug("[sandbox] child exited: " .. tostring(exit_code))
    sbox.stop_sandbox(ctx)
    if not ok or exit_code ~= 0 then return exit_code ~= 0 and exit_code or 1 end
    return 0
  end

  -- Handle commands that don't need db
  local cmd = remaining[1]
  if cmd == "sessions" then
    local sessions = sessions_mod.list_sessions(cwd)
    local current_ulid = sessions[1] and sessions[1].ulid or ""
    sessions_mod.cmd_sessions(cwd, current_ulid)
    return 0

  elseif cmd == "embed" then
    local src_dir = remaining[2]
    if not src_dir then
      io.stderr:write("usage: ah embed <dir> [-o <file>]\n")
      return 1
    end
    local sub_args: {string} = {}
    for si = 3, #remaining do sub_args[#sub_args + 1] = remaining[si] end
    local embed_opts: {args_mod.OptionDef} = {{name = "output", short = "o", has_arg = "required"}}
    local opts = args_mod.parse_subcommand_options(sub_args, embed_opts)
    local effective_output = opts.output or output_path
    local tmpdir = fs.mkdtemp("/tmp/ah-embed-XXXXXX")
    local embed_link = fs.join(tmpdir, "embed")
    fs.symlink(fs.realpath(src_dir), embed_link)
    local result = embed.run({tmpdir}, effective_output)
    fs.rmrf(tmpdir)
    if result.ok then io.write(result.message .. "\n"); return 0
    else io.stderr:write("embed: " .. result.message .. "\n"); return 1 end

  elseif cmd == "proxy" then
    local socket_path = remaining[2]
    if not socket_path then io.stderr:write("usage: ah proxy <socket-path>\n"); return 1 end
    local proxy = require("ah.proxy")
    return proxy.serve(socket_path)

  elseif cmd == "extract" then
    local output_dir = remaining[2]
    if not output_dir then io.stderr:write("usage: ah extract <dir>\n"); return 1 end
    local exe_path = arg[-1]
    local exe_data = cio.slurp(exe_path)
    if not exe_data then io.stderr:write("extract: cannot read executable\n"); return 1 end
    local reader, zerr = zip.from(exe_data)
    if not reader then io.stderr:write("extract: " .. (zerr or "no zip archive found") .. "\n"); return 1 end
    local prefix = "embed/"
    local entries = reader:list()
    local count = 0
    for _, name in ipairs(entries) do
      if name:sub(1, #prefix) == prefix and name:sub(-1) ~= "/" then
        local content = reader:read(name)
        if content then
          local rel_name = name:sub(#prefix + 1)
          local filepath = fs.join(output_dir, rel_name)
          local dir = fs.dirname(filepath)
          fs.makedirs(dir)
          cio.barf(filepath, content)
          count = count + 1
        end
      end
    end
    reader:close()
    io.write("extracted " .. count .. " file(s) to " .. output_dir .. "\n")
    return 0

  elseif cmd == "limits" then
    local limits_mod = require("ah.limits")
    return limits_mod.cmd_limits()
  end

  -- Session selection
  local session_ulid: string = nil
  if not db_path then
    local ah_dir = fs.join(cwd, ".ah")
    fs.makedirs(ah_dir)

    if new_session and session_name then
      return 1, "--new and --name cannot be used together"
    elseif session_name then
      local sessions = sessions_mod.list_sessions(cwd)
      local found: sessions_mod.Session = nil
      for _, s in ipairs(sessions) do
        if s.name == session_name then
          if found then return 1, "duplicate session name: " .. session_name end
          found = s
        end
      end
      if found then session_ulid = found.ulid else session_ulid = ulid.generate() end
    elseif new_session then
      session_ulid = ulid.generate()
    elseif session_prefix then
      local resolved, rerr = sessions_mod.resolve_session(cwd, session_prefix)
      if not resolved then return 1, rerr end
      session_ulid = resolved
    else
      local sessions = sessions_mod.list_sessions(cwd)
      if #sessions > 0 then session_ulid = sessions[1].ulid
      else session_ulid = ulid.generate() end
    end

    db_path = fs.join(ah_dir, session_ulid .. ".db")
  end

  local queue_path = db_path:gsub("%.db$", ".queue.db")

  if steer_msg or followup_msg then
    local qdb, qerr = queue.open(queue_path)
    if not qdb then return 1, qerr end
    if steer_msg then queue.add_steer(qdb, steer_msg); io.stderr:write("queued steering message\n") end
    if followup_msg then queue.add_followup(qdb, followup_msg); io.stderr:write("queued followup message\n") end
    queue.close(qdb)
    return 0
  end

  local d, derr = db.open(db_path)
  if not d then return 1, derr end

  if session_name then
    local existing_name = db.get_context(d, "session_name")
    if not existing_name then db.set_context(d, "session_name", session_name) end
  end

  local orphans_cleaned = db.cleanup_orphans(d)
  if orphans_cleaned > 0 then
    io.stderr:write(string.format("cleaned up %d orphan message(s) from previous crash\n", orphans_cleaned))
  end

  local qdb, qerr = queue.open(queue_path)
  if not qdb then db.close(d); return 1, qerr end

  if cmd == "usage" then
    sessions_mod.cmd_usage(d)
    queue.close(qdb); db.close(d)
    return 0
  end

  local parent_id: string = nil
  local prompt: string = nil
  prompt = table.concat(remaining, " ")

  if not parent_id then
    local last = db.get_last_message(d)
    if last then parent_id = (last as {string: any}).id as string end
  end

  if prompt == "" then
    if tty.isatty(0) then io.stderr:write(">>> "); io.stderr:flush() end
    local ok, input = pcall(io.read, "*a")
    if not ok or not input then
      io.stderr:write("\n"); queue.close(qdb); db.close(d); return 0
    end
    prompt = input:gsub("%s+$", "")
    if prompt == "" and not parsed.skill then
      args_mod.usage(); queue.close(qdb); db.close(d); return 0
    end
  end

  local loaded_skills = skills.load_skills(cwd)
  local active_skill_name: string = parsed.skill
  if parsed.skill then prompt = "/skill:" .. parsed.skill .. "\n" .. prompt end

  local skill_expanded, was_skill = skills.expand_skill(prompt, loaded_skills)
  if was_skill then
    prompt = skill_expanded
    if not active_skill_name then active_skill_name = prompt:match('^<skill name="([a-z0-9%-]+)"') end
  end

  if not was_skill then
    local loaded_commands = commands.load_commands()
    local expanded, was_command = commands.expand_command(prompt, loaded_commands)
    if was_command then prompt = expanded end
  end

  tools.init_custom_tools(cwd)
  if active_skill_name and loaded_skills[active_skill_name] then
    tools.load_skill_tools(loaded_skills[active_skill_name].base_dir)
  end

  for _, spec in ipairs(parsed.tool_overrides) do
    local name, tcmd = spec:match("^([^=]+)=(.*)")
    if name and tcmd ~= "" then tools.add_tool_override(name, tcmd)
    elseif name then tools.remove_tool(name)
    else io.stderr:write("warning: invalid --tool spec (expected name=cmd): " .. spec .. "\n") end
  end

  local effective_system = prompt_mod.load_system_prompt(cwd)
  local tools_prompt = tools.format_tools_for_prompt()
  if tools_prompt ~= "" then effective_system = effective_system .. "\n\n" .. tools_prompt end
  local skills_prompt = skills.format_skills_for_prompt(loaded_skills)
  if skills_prompt ~= "" then effective_system = effective_system .. "\n\n" .. skills_prompt end
  if parsed.must_produce then
    effective_system = effective_system .. "\n\nIMPORTANT: You must write the file `" .. parsed.must_produce .. "` before finishing."
  end

  local lock_acquired, lock_err = queue.try_acquire_lock(qdb)
  if not lock_acquired then
    queue.add_followup(qdb, prompt)
    io.stderr:write("session locked, queued as followup: " .. (lock_err or "") .. "\n")
    queue.close(qdb); db.close(d)
    return 0
  end

  signal.sigaction(signal.SIGINT, function()
      interrupted = true
      tools.abort_running_tools()
      queue.release_lock(qdb)
    end)

  local effective_model = api.resolve_model(model or os.getenv("AH_MODEL"))
  local on_event = cli_mod.make_cli_handler(parsed.skill, session_ulid)
  local agent_opts: loop.AgentOpts = {}
  if max_tokens then agent_opts.max_tokens = max_tokens end
  if parsed.max_turn_tokens then agent_opts.max_turn_tokens = parsed.max_turn_tokens end
  if parsed.must_produce then agent_opts.must_produce = parsed.must_produce end
  local stop_reason = loop.run_agent(d, qdb, effective_system, effective_model, prompt, parent_id, on_event, agent_opts)

  db.set_session_state(d, "closed")
  queue.release_lock(qdb)
  queue.close(qdb)
  db.close(d)

  if stop_reason == "error" then return 1 end
  return 0
end

return {
  main = main,
  -- Re-export from submodules for backward compatibility
  parse_args = args_mod.parse_args,
  parse_subcommand_options = args_mod.parse_subcommand_options,
  load_system_prompt = prompt_mod.load_system_prompt,
  load_claude_md = prompt_mod.load_claude_md,
  list_sessions = sessions_mod.list_sessions,
  resolve_session = sessions_mod.resolve_session,
  parse_protect_dirs = args_mod.parse_protect_dirs,
  parse_unveil_entry = args_mod.parse_unveil_entry,
  usage_text = args_mod.usage_text,
  colorize_diff_line = cli_mod.colorize_diff_line,
  colorize_tool_line = cli_mod.colorize_tool_line,
  format_tokens = cli_mod.format_tokens,
  make_cli_handler = cli_mod.make_cli_handler,
}
