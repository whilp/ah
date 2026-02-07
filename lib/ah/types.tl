-- ah/types.tl: type definitions for ah

local record Session
  id: string
  name: string
  created_at: integer
  updated_at: integer
  cwd: string
  system_prompt: string
end

local record Message
  id: string
  session_id: string
  parent_id: string
  role: string          -- 'user' | 'assistant'
  seq: integer          -- depth in tree
  created_at: integer
end

local record ContentBlock
  id: string
  message_id: string
  block_type: string    -- 'text' | 'tool_use' | 'tool_result'
  seq: integer
  content: string       -- json for text blocks
  tool_id: string
  tool_name: string
  tool_input: string    -- json
  tool_output: string   -- json
  is_error: boolean
end

local record ToolCall
  id: string
  name: string
  input: {string:any}
end

local record ToolResult
  tool_use_id: string
  content: string
  is_error: boolean
end

local record Credentials
  access_token: string
  refresh_token: string
  expires_at: string
  is_api_key: boolean
end

local record ApiMessage
  role: string
  content: any  -- string or {ContentBlock}
end

local record ApiRequest
  model: string
  max_tokens: integer
  system: string
  messages: {ApiMessage}
  tools: {{string:any}}
  stream: boolean
end

local record ApiResponse
  id: string
  type: string
  role: string
  content: {any}
  model: string
  stop_reason: string
  usage: {string:integer}
end

local record StreamEvent
  type: string
  index: integer
  delta: {string:any}
  content_block: {string:any}
  message: ApiResponse
end

local record Tool
  name: string
  description: string
  input_schema: {string:any}
  execute: function(input: {string:any}): string, boolean
end

return {
  Session = Session,
  Message = Message,
  ContentBlock = ContentBlock,
  ToolCall = ToolCall,
  ToolResult = ToolResult,
  Credentials = Credentials,
  ApiMessage = ApiMessage,
  ApiRequest = ApiRequest,
  ApiResponse = ApiResponse,
  StreamEvent = StreamEvent,
  Tool = Tool,
}
