-- ah/db/query.tl: read-heavy query helpers for the session database
--
-- Extracted from db/init.tl to keep it under the line limit.
-- All functions are installed onto the db module table by db/init.tl at load time.
-- Types are shared via db/types.tl to maintain type identity across modules.
local json = require("cosmic.json")
local ulid = require("ulid")
local ctime = require("cosmic.time")
local t = require("ah.db.types")

local DB = t.DB
local Event = t.Event
local TokenTotals = t.TokenTotals

-- Callbacks injected by db.tl to avoid circular require.
local _get_context: function(DB, string): string
local _delete_message: function(DB, string)

local function set_callbacks(get_ctx: function(DB, string): string, del_msg: function(DB, string))
  _get_context = get_ctx
  _delete_message = del_msg
end

local function log_event(self: DB, event_type: string, message_id?: string, details?: string, conversation_id?: string): Event
  local id = ulid.generate()
  local now = math.floor((ctime.now())) as integer
  if not conversation_id then
    conversation_id = _get_context(self, "current_conversation")
  end
  self._db:exec_list("insert into events (id, conversation_id, message_id, event_type, created_at, details) values (?, ?, ?, ?, ?, ?)",
    {id, conversation_id, message_id, event_type, now, details}, 6)
  return {id = id, message_id = message_id, event_type = event_type, created_at = now, details = details}
end

local function get_events(self: DB, event_type?: string, conversation_id?: string): {Event}
  local ev: {Event} = {}
  local base = "select * from events"
  local iter: function(): {string: any}
  if event_type and conversation_id then
    iter = self._db:query(base .. " where event_type = ? and conversation_id = ? order by created_at asc", event_type, conversation_id)
  elseif event_type then
    iter = self._db:query(base .. " where event_type = ? order by created_at asc", event_type)
  elseif conversation_id then
    iter = self._db:query(base .. " where conversation_id = ? order by created_at asc", conversation_id)
  else
    iter = self._db:query(base .. " order by created_at asc")
  end
  for row in iter do table.insert(ev, row as Event) end
  return ev
end

local function get_message_count(self: DB, conversation_id?: string): integer
  if conversation_id then
    for row in self._db:query("select count(*) as cnt from messages where conversation_id = ?", conversation_id) do
      return (row.cnt or 0) as integer
    end
  else
    for row in self._db:query("select count(*) as cnt from messages") do
      return (row.cnt or 0) as integer
    end
  end
  return 0
end

local function cleanup_orphans(self: DB): integer
  -- Limit scan to 100 most recent leaf messages (orphans only arise from crashes)
  local orphans: {string} = {}
  for row in self._db:query([[
    select m.id from messages m
    left join content_blocks c on c.message_id = m.id
    where not exists (select 1 from messages child where child.parent_id = m.id)
    group by m.id having count(c.id) = 0
    order by m.created_at desc limit 100
  ]]) do
    table.insert(orphans, row.id as string)
  end
  for _, id in ipairs(orphans) do _delete_message(self, id) end
  return #orphans
end

local function get_session_token_totals(self: DB, conversation_id?: string): TokenTotals
  local totals: TokenTotals = {input_tokens = 0, output_tokens = 0, cache_read_tokens = 0}
  local q = "select details from events where event_type = 'api_call_end'"
  local iter: function(): {string: any}
  if conversation_id then
    iter = self._db:query(q .. " and conversation_id = ? order by rowid asc", conversation_id)
  else
    iter = self._db:query(q .. " order by rowid asc")
  end
  for row in iter do
    if not row.details then goto next end
    local detail = json.decode(row.details as string) as {string: any}
    if not detail then goto next end
    local inp = (detail.input_tokens or 0) as integer
    local out = (detail.output_tokens or 0) as integer
    local cc = (detail.cache_creation_input_tokens or 0) as integer
    local cr = (detail.cache_read_input_tokens or 0) as integer
    -- input/cache are per-call context window sizes (not incremental)
    totals.input_tokens = inp + cc + cr
    totals.cache_read_tokens = cr
    -- output is incremental
    totals.output_tokens = totals.output_tokens + out
    ::next::
  end
  return totals
end

local function get_session_state(self: DB): string
  local conv_id = _get_context(self, "current_conversation")
  if conv_id then
    for row in self._db:query("select state from conversations where id = ?", conv_id) do
      return row.state as string
    end
  end
  return "idle"
end

local function set_session_state(self: DB, state: string)
  local conv_id = _get_context(self, "current_conversation")
  if conv_id then
    self._db:exec("update conversations set state = ? where id = ?", state, conv_id)
  end
end

local function get_first_user_prompt(self: DB, conversation_id?: string): string
  if conversation_id then
    for row in self._db:query("select content from content_blocks where block_type = 'text' and message_id in (select id from messages where role = 'user' and conversation_id = ? order by seq asc limit 1) order by seq asc limit 1", conversation_id) do
      return (row.content or "") as string
    end
  else
    for row in self._db:query("select content from content_blocks where block_type = 'text' and message_id in (select id from messages where role = 'user' order by seq asc limit 1) order by seq asc limit 1") do
      return (row.content or "") as string
    end
  end
  return ""
end

return {
  set_callbacks = set_callbacks,
  log_event = log_event,
  get_events = get_events,
  get_message_count = get_message_count,
  cleanup_orphans = cleanup_orphans,
  get_session_token_totals = get_session_token_totals,
  get_session_state = get_session_state,
  set_session_state = set_session_state,
  get_first_user_prompt = get_first_user_prompt,
}
