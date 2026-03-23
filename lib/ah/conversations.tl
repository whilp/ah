-- ah/conversations.tl: conversation lifecycle management on db.DB
local db = require("ah.db")
local ulid = require("ulid")
local ctime = require("cosmic.time")

local function create_conversation(self: db.DB, opts?: db.ConversationOpts): db.Conversation
  opts = opts or {}
  local id = ulid.generate()
  local now = math.floor((ctime.now())) as integer
  self._db:exec_list([[
    insert into conversations (id, name, created_at, state) values (?, ?, ?, 'idle')
  ]], {id, opts.name, now}, 3)
  db.set_context(self, "current_conversation", id)
  return {id = id, name = opts.name, created_at = now, state = "idle"}
end

local function get_conversation(self: db.DB, id: string): db.Conversation
  for row in self._db:query("select * from conversations where id = ?", id) do
    return row as db.Conversation
  end
  return nil
end

local function list_conversations(self: db.DB): {db.Conversation}
  local convs: {db.Conversation} = {}
  for row in self._db:query("select * from conversations order by id desc") do
    table.insert(convs, row as db.Conversation)
  end
  return convs
end

local function resolve_conversation(self: db.DB, prefix: string): string, string
  -- First: exact name match
  local name_matches: {string} = {}
  for row in self._db:query("select id from conversations where name = ?", prefix) do
    table.insert(name_matches, row.id as string)
  end
  if #name_matches == 1 then return name_matches[1], nil end
  if #name_matches > 1 then return nil, "ambiguous name: " .. prefix .. " matches " .. #name_matches .. " conversations" end

  -- Second: ULID prefix match
  local matches: {string} = {}
  for row in self._db:query("select id from conversations where id like ? || '%'", prefix) do
    table.insert(matches, row.id as string)
  end
  if #matches == 0 then return nil, "no conversation matches: " .. prefix end
  if #matches > 1 then return nil, "ambiguous prefix: " .. prefix .. " matches " .. #matches .. " conversations" end
  return matches[1], nil
end

local function get_current_conversation(self: db.DB): db.Conversation
  for row in self._db:query("select * from conversations where state != 'closed' order by id desc limit 1") do
    return row as db.Conversation
  end
  return nil
end

local function close_conversation(self: db.DB, id: string)
  local now = math.floor((ctime.now())) as integer
  self._db:exec("update conversations set state = 'closed', closed_at = ? where id = ?", now, id)
end

local function set_conversation_state(self: db.DB, id: string, state: string)
  self._db:exec("update conversations set state = ? where id = ?", state, id)
end

return {
  create_conversation = create_conversation,
  get_conversation = get_conversation,
  list_conversations = list_conversations,
  resolve_conversation = resolve_conversation,
  get_current_conversation = get_current_conversation,
  close_conversation = close_conversation,
  set_conversation_state = set_conversation_state,
}
