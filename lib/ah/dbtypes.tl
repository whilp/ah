-- ah/dbtypes.tl: shared type definitions for the session database
--
-- Both db.tl and dbquery.tl import these types to avoid duplicate
-- record definitions that Teal treats as incompatible.

local record Statement
  bind: function(Statement, any ...)
  exec: function(Statement)
  close: function(Statement)
end

local record Database
  exec: function(Database, string, any ...): boolean, string
  exec_list: function(Database, string, {any}, integer): boolean, string
  prepare: function(Database, string): Statement, string
  query: function(Database, string, any ...): function(): {string: any}
  transaction: function < T > (Database, function(): T): T
  close: function(Database)
end

local record DB
  _db: Database
end

local record Conversation
  id: string
  name: string
  created_at: integer
  closed_at: integer
  state: string
end

local record ConversationOpts
  name: string
end

local record Message
  id: string
  parent_id: string
  role: string
  seq: integer
  created_at: integer
  input_tokens: integer
  output_tokens: integer
  stop_reason: string
  model: string
  api_latency_ms: integer
end

local record ContentBlock
  id: string
  message_id: string
  block_type: string
  seq: integer
  content: string
  tool_id: string
  tool_name: string
  tool_input: string
  tool_output: string
  is_error: integer
  duration_ms: integer
  details: string
end

local record ContentBlockOpts
  content: string
  tool_id: string
  tool_name: string
  tool_input: string
  tool_output: string
  is_error: boolean
  duration_ms: integer
  details: string
end

local record UpdateOpts
  content: string
  tool_output: string
  is_error: boolean
end

local record MessageOpts
  input_tokens: integer
  output_tokens: integer
  stop_reason: string
  model: string
  api_latency_ms: integer
end

local record Event
  id: string
  message_id: string
  event_type: string
  created_at: integer
  details: string
end

local record TokenTotals
  input_tokens: integer
  output_tokens: integer
  cache_read_tokens: integer
end

return {
  Statement = Statement, Database = Database, DB = DB,
  Conversation = Conversation, ConversationOpts = ConversationOpts,
  Message = Message, ContentBlock = ContentBlock, ContentBlockOpts = ContentBlockOpts,
  UpdateOpts = UpdateOpts, MessageOpts = MessageOpts,
  Event = Event, TokenTotals = TokenTotals,
}
