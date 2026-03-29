#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local db = require("ah.db")
local conversations = require("ah.conversations")
local cenv = require("cosmic.env")

local TEST_TMPDIR = cenv.get("TEST_TMPDIR") or "/tmp"

-- Helper: open db and create a conversation so FK constraints are satisfied
local function open_with_conv(name: string): db.DB, string
  local d = db.open(fs.join(TEST_TMPDIR, name))
  local conv = conversations.create_conversation(d)
  return d, conv.id
end

local function test_open_close()
  local db_path = fs.join(TEST_TMPDIR, "test_oc.db")
  local d, err = db.open(db_path)
  assert(d, "failed to open db: " .. tostring(err))
  db.close(d)
end
test_open_close()

local function test_messages()
  local d, cid = open_with_conv("test_msg.db")

  -- Create root message
  local msg1 = db.create_message(d, "user", nil, nil, cid)
  assert(msg1.id, "message should have id")
  assert(msg1.role == "user", "message role mismatch")
  assert(msg1.seq == 0, "root message should have seq 0")

  -- Create child message
  local msg2 = db.create_message(d, "assistant", msg1.id, nil, cid)
  assert(msg2.seq == 1, "child message should have seq 1")
  assert(msg2.parent_id == msg1.id, "parent_id mismatch")

  -- Get ancestry
  local ancestry = db.get_ancestry(d, msg2.id)
  assert(#ancestry == 2, "expected 2 messages in ancestry")
  assert(ancestry[1].id == msg1.id, "first in ancestry should be root")
  assert(ancestry[2].id == msg2.id, "second in ancestry should be child")

  -- Get last message
  local last = db.get_last_message(d)
  assert(last, "should have last message")
  assert(last.id == msg2.id, "last message should be msg2")

  db.close(d)
end
test_messages()

local function test_content_blocks()
  local d, cid = open_with_conv("test_cb.db")

  local msg = db.create_message(d, "assistant", nil, nil, cid)

  -- Add text block
  local block1 = db.add_content_block(d, msg.id, "text", {content = "Hello world"})
  assert(block1.id, "block should have id")
  assert(block1.seq == 0, "first block should have seq 0")
  assert(block1.content == "Hello world", "block content mismatch")

  -- Add tool_use block
  local block2 = db.add_content_block(d, msg.id, "tool_use", {
      tool_id = "tool_123",
      tool_name = "read",
      tool_input = '{"path": "/tmp/test"}',
    })
  assert(block2.seq == 1, "second block should have seq 1")
  assert(block2.tool_name == "read", "tool_name mismatch")

  -- Get blocks
  local blocks = db.get_content_blocks(d, msg.id)
  assert(#blocks == 2, "expected 2 blocks")
  assert(blocks[1].block_type == "text", "first block type mismatch")
  assert(blocks[2].block_type == "tool_use", "second block type mismatch")

  -- Update block
  db.update_content_block(d, block2.id, {tool_output = "file contents"})
  local updated_blocks = db.get_content_blocks(d, msg.id)
  assert(updated_blocks[2].tool_output == "file contents", "tool_output not updated")

  db.close(d)
end
test_content_blocks()

local function test_forking()
  local d, cid = open_with_conv("test_fork.db")

  -- Create a conversation: user -> assistant -> user -> assistant
  local msg1 = db.create_message(d, "user", nil, nil, cid)
  local msg2 = db.create_message(d, "assistant", msg1.id, nil, cid)
  local msg3 = db.create_message(d, "user", msg2.id, nil, cid)
  local msg4 = db.create_message(d, "assistant", msg3.id, nil, cid)

  -- Fork from msg2 (after first assistant response)
  local fork_msg = db.create_message(d, "user", msg2.id, nil, cid)
  assert(fork_msg.seq == 2, "forked message should have seq 2")
  assert(fork_msg.parent_id == msg2.id, "forked parent should be msg2")

  -- Ancestry of forked message should be: msg1 -> msg2 -> fork_msg
  local fork_ancestry = db.get_ancestry(d, fork_msg.id)
  assert(#fork_ancestry == 3, "expected 3 messages in fork ancestry")
  assert(fork_ancestry[1].id == msg1.id, "first should be msg1")
  assert(fork_ancestry[2].id == msg2.id, "second should be msg2")
  assert(fork_ancestry[3].id == fork_msg.id, "third should be fork_msg")

  -- Original ancestry should still be: msg1 -> msg2 -> msg3 -> msg4
  local orig_ancestry = db.get_ancestry(d, msg4.id)
  assert(#orig_ancestry == 4, "expected 4 messages in original ancestry")

  db.close(d)
end
test_forking()

local function test_get_message_count()
  local d0, _ = open_with_conv("count_e.db")
  assert(db.get_message_count(d0) == 0, "empty db should have 0 messages")
  db.close(d0)

  local d1, c1 = open_with_conv("count_1.db")
  db.create_message(d1, "user", nil, nil, c1)
  assert(db.get_message_count(d1) == 1, "should have 1 message")
  db.close(d1)

  local d3, c3 = open_with_conv("count_3.db")
  local m1 = db.create_message(d3, "user", nil, nil, c3)
  local m2 = db.create_message(d3, "assistant", m1.id, nil, c3)
  db.create_message(d3, "user", m2.id, nil, c3)
  assert(db.get_message_count(d3) == 3, "should have 3 messages")
  db.close(d3)
end
test_get_message_count()

local function test_get_first_user_prompt()
  local d0, _ = open_with_conv("pr_e.db")
  assert(db.get_first_user_prompt(d0) == "", "empty db should return empty string")
  db.close(d0)

  local d1, c1 = open_with_conv("pr_u.db")
  local msg = db.create_message(d1, "user", nil, nil, c1)
  db.add_content_block(d1, msg.id, "text", {content = "Hello world"})
  assert(db.get_first_user_prompt(d1) == "Hello world", "should return first user prompt")
  db.close(d1)

  -- assistant-first edge case
  local d2, c2 = open_with_conv("pr_af.db")
  local amsg = db.create_message(d2, "assistant", nil, nil, c2)
  db.add_content_block(d2, amsg.id, "text", {content = "I am assistant"})
  local umsg = db.create_message(d2, "user", amsg.id, nil, c2)
  db.add_content_block(d2, umsg.id, "text", {content = "User prompt"})
  assert(db.get_first_user_prompt(d2) == "User prompt", "should find first user message")
  db.close(d2)
end
test_get_first_user_prompt()

-- Test orphan cleanup
local function test_cleanup_orphans()
  local d, cid = open_with_conv("orph.db")

  local msg1 = db.create_message(d, "user", nil, nil, cid)
  db.add_content_block(d, msg1.id, "text", {content = "hello"})

  -- Create a leaf orphan message (no content blocks - simulates crash)
  db.create_message(d, "assistant", msg1.id, nil, cid)

  assert(db.get_message_count(d) == 2, "should have 2 messages before cleanup")
  local cleaned = db.cleanup_orphans(d)
  assert(cleaned == 1, "should have cleaned 1 orphan, got " .. cleaned)
  assert(db.get_message_count(d) == 1, "should have 1 message after cleanup")

  db.close(d)
end
test_cleanup_orphans()

-- Test that orphan cleanup preserves parent chain
local function test_cleanup_preserves_chain()
  local d, cid = open_with_conv("orph_ch.db")

  local m1 = db.create_message(d, "user", nil, nil, cid)
  db.add_content_block(d, m1.id, "text", {content = "hello"})

  local orphan = db.create_message(d, "assistant", m1.id, nil, cid)

  local m2 = db.create_message(d, "user", orphan.id, nil, cid)
  db.add_content_block(d, m2.id, "text", {content = "world"})

  local cleaned = db.cleanup_orphans(d)
  assert(cleaned == 0, "should not clean orphan with children, got " .. cleaned)
  assert(db.get_message_count(d) == 3, "should still have 3 messages")
  assert(#db.get_ancestry(d, m2.id) == 3, "ancestry should include all 3 messages")

  db.close(d)
end
test_cleanup_preserves_chain()

-- Test transaction support
local function test_transactions()
  local d, cid = open_with_conv("tx.db")

  db.begin_transaction(d)
  local msg = db.create_message(d, "user", nil, nil, cid)
  db.add_content_block(d, msg.id, "text", {content = "hello"})
  db.commit(d)

  assert(#db.get_content_blocks(d, msg.id) == 1, "should have 1 block after commit")

  -- Test rollback
  db.begin_transaction(d)
  db.create_message(d, "assistant", msg.id, nil, cid)
  db.rollback(d)

  assert(db.get_message_count(d) == 1, "should have only 1 message after rollback")

  db.close(d)
end
test_transactions()

-- Test empty content serialization bug (documentation test)
local function test_empty_content_serialization()
  local d, cid = open_with_conv("empty_content.db")

  -- Simulate a segfault scenario: message created but no content blocks added
  local msg = db.create_message(d, "user", nil, nil, cid)

  local blocks = db.get_content_blocks(d, msg.id)
  local content: {any} = {}
  for _, block in ipairs(blocks) do
    if block.block_type == "text" then
      table.insert(content, {type = "text", text = block.content})
    end
  end
  local api_message = {role = msg.role, content = content}

  -- Empty Lua table {} serializes as JSON object {}, not array []
  local encoded = json.encode(api_message)
  assert(encoded:find('"content":{}'),
    "bug demonstration: empty content should serialize as {} (showing the bug exists)")
  print("  (confirmed: empty content serializes as {} not [])")

  db.close(d)
end
test_empty_content_serialization()

-- Test message metadata (tokens, model, latency)
local function test_message_metadata()
  local d, cid = open_with_conv("meta.db")

  local msg1 = db.create_message(d, "user", nil, nil, cid)
  assert(msg1.input_tokens == nil, "user message should have nil input_tokens")
  assert(msg1.model == nil, "user message should have nil model")

  local msg2 = db.create_message(d, "assistant", msg1.id, {
      input_tokens = 100, output_tokens = 50, stop_reason = "end_turn",
      model = "claude-sonnet", api_latency_ms = 1500,
    }, cid)
  assert(msg2.input_tokens == 100, "input_tokens mismatch")
  assert(msg2.output_tokens == 50, "output_tokens mismatch")
  assert(msg2.stop_reason == "end_turn", "stop_reason mismatch")
  assert(msg2.model == "claude-sonnet", "model mismatch")
  assert(msg2.api_latency_ms == 1500, "api_latency_ms mismatch")

  db.close(d)
end
test_message_metadata()

-- Test content block duration
local function test_content_block_duration()
  local d, cid = open_with_conv("dur.db")

  local msg = db.create_message(d, "user", nil, nil, cid)

  local block1 = db.add_content_block(d, msg.id, "text", {content = "hello"})
  assert(block1.duration_ms == nil, "text block should have nil duration")

  local block2 = db.add_content_block(d, msg.id, "tool_result", {
      tool_id = "t1", tool_output = "output", duration_ms = 250,
    })
  assert(block2.duration_ms == 250, "duration_ms mismatch")

  local blocks = db.get_content_blocks(d, msg.id)
  assert(blocks[1].duration_ms == nil, "first block duration should be nil")
  assert(blocks[2].duration_ms == 250, "second block duration should be 250")

  db.close(d)
end
test_content_block_duration()

-- Test content block details
local function test_content_block_details()
  local d, cid = open_with_conv("det.db")

  local msg = db.create_message(d, "user", nil, nil, cid)

  local block1 = db.add_content_block(d, msg.id, "tool_result", {
      tool_id = "t1", tool_output = "output",
    })
  assert(block1.details == nil, "block without details should be nil")

  local details_json = '{"path":"/tmp/test.txt","line_count":42}'
  local block2 = db.add_content_block(d, msg.id, "tool_result", {
      tool_id = "t2", tool_output = "file contents", details = details_json,
    })
  assert(block2.details == details_json, "details mismatch on insert")

  local blocks = db.get_content_blocks(d, msg.id)
  assert(blocks[1].details == nil, "first block details should be nil")
  assert(blocks[2].details == details_json, "second block details should match")

  db.close(d)
end
test_content_block_details()

-- Test event logging
local function test_events()
  local d, cid = open_with_conv("ev.db")

  local evt1 = db.log_event(d, "startup", nil, nil, cid)
  assert(evt1.id, "event should have id")
  assert(evt1.event_type == "startup", "event_type mismatch")
  assert(evt1.message_id == nil, "message_id should be nil")
  assert(evt1.created_at, "should have created_at")

  local msg = db.create_message(d, "user", nil, nil, cid)
  local evt2 = db.log_event(d, "retry", msg.id, '{"attempt":1,"delay_ms":1000}', cid)
  assert(evt2.message_id == msg.id, "message_id mismatch")
  assert(evt2.details == '{"attempt":1,"delay_ms":1000}', "details mismatch")

  local all_events = db.get_events(d)
  assert(#all_events == 2, "should have 2 events")

  local retry_events = db.get_events(d, "retry")
  assert(#retry_events == 1, "should have 1 retry event")
  assert(retry_events[1].event_type == "retry", "filtered event type mismatch")

  db.close(d)
end
test_events()

-- Test session state management (delegates to conversations.state)
local function test_session_state()
  local d, _ = open_with_conv("st.db")

  local state = db.get_session_state(d)
  assert(state == "idle", "default state should be idle, got: " .. state)

  db.set_session_state(d, "processing")
  state = db.get_session_state(d)
  assert(state == "processing", "state should be processing, got: " .. state)

  db.set_session_state(d, "idle")
  state = db.get_session_state(d)
  assert(state == "idle", "state should be idle, got: " .. state)

  db.set_session_state(d, "closed")
  state = db.get_session_state(d)
  assert(state == "closed", "state should be closed, got: " .. state)

  db.close(d)
end
test_session_state()

-- Test session state persists across reopen
local function test_session_state_persistence()
  local db_path = fs.join(TEST_TMPDIR, "st_persist.db")
  local d = db.open(db_path)
  conversations.create_conversation(d)
  db.set_session_state(d, "processing")
  db.close(d)

  d = db.open(db_path)
  local state = db.get_session_state(d)
  assert(state == "processing", "state should persist across reopen, got: " .. state)
  db.close(d)
end
test_session_state_persistence()

-- Test get_session_token_totals (events-based)
local function test_session_token_totals()
  -- empty db
  local d0, _ = open_with_conv("tok_e.db")
  local t0 = db.get_session_token_totals(d0)
  assert(t0.input_tokens == 0, "empty input_tokens: " .. t0.input_tokens)
  assert(t0.output_tokens == 0, "empty output_tokens: " .. t0.output_tokens)
  assert(t0.cache_read_tokens == 0, "empty cache_read: " .. t0.cache_read_tokens)
  db.close(d0)

  -- input_tokens = context window size (not incremental) → use last; output → sum
  local d, cid = open_with_conv("tok_s.db")
  local m1 = db.create_message(d, "user", nil, nil, cid)
  local m2 = db.create_message(d, "assistant", m1.id, {input_tokens = 100, output_tokens = 50}, cid)
  db.log_event(d, "api_call_end", m2.id, json.encode({input_tokens = 100, output_tokens = 50}), cid)
  local m3 = db.create_message(d, "user", nil, nil, cid)
  local m4 = db.create_message(d, "assistant", m3.id, {input_tokens = 200, output_tokens = 75}, cid)
  db.log_event(d, "api_call_end", m4.id, json.encode({input_tokens = 200, output_tokens = 75}), cid)
  local totals = db.get_session_token_totals(d)
  assert(totals.input_tokens == 200, "input_tokens should be 200 (last): " .. totals.input_tokens)
  assert(totals.output_tokens == 125, "output_tokens should be 125: " .. totals.output_tokens)
  db.close(d)

  -- nil tokens on user messages should not break results
  local d2, c2 = open_with_conv("tok_n.db")
  local u1 = db.create_message(d2, "user", nil, nil, c2)
  local a1 = db.create_message(d2, "assistant", u1.id, {input_tokens = 500, output_tokens = 100}, c2)
  db.log_event(d2, "api_call_end", a1.id, json.encode({input_tokens = 500, output_tokens = 100}), c2)
  local t2 = db.get_session_token_totals(d2)
  assert(t2.input_tokens == 500, "nil tokens input: " .. t2.input_tokens)
  assert(t2.output_tokens == 100, "nil tokens output: " .. t2.output_tokens)
  db.close(d2)
end
test_session_token_totals()

local function test_session_token_totals_cache_read()
  local d, cid = open_with_conv("tok_c.db")
  local m1 = db.create_message(d, "user", nil, nil, cid)
  local m2 = db.create_message(d, "assistant", m1.id, {
      input_tokens = 5000, output_tokens = 100,
    }, cid)
  db.log_event(d, "api_call_end", m2.id, json.encode({input_tokens = 5000, output_tokens = 100, cache_read_input_tokens = 0}), cid)
  local m3 = db.create_message(d, "user", m2.id, nil, cid)
  local m4 = db.create_message(d, "assistant", m3.id, {
      input_tokens = 10000, output_tokens = 200,
    }, cid)
  db.log_event(d, "api_call_end", m4.id, json.encode({input_tokens = 5100, output_tokens = 200, cache_read_input_tokens = 4900}), cid)
  local totals = db.get_session_token_totals(d)
  -- should use last event's cache_read, not sum
  assert(totals.cache_read_tokens == 4900, "cache_read should be 4900 (last): " .. totals.cache_read_tokens)
  -- input is from last event: 5100 + 4900 = 10000
  assert(totals.input_tokens == 10000, "input should be 10000: " .. totals.input_tokens)
  assert(totals.output_tokens == 300, "output should be 300 (sum): " .. totals.output_tokens)
  db.close(d)
end
test_session_token_totals_cache_read()

-- Test set_context with nil value (should delete, not violate NOT NULL)
local function test_set_context_nil()
  local d, _ = open_with_conv("ctx_nil.db")
  db.set_context(d, "test_key", "test_value")
  assert(db.get_context(d, "test_key") == "test_value", "should set value")
  db.set_context(d, "test_key", nil)
  assert(db.get_context(d, "test_key") == nil, "should delete on nil")
  db.close(d)
end
test_set_context_nil()

-- Test delete_message cascades to events
local function test_delete_message_cascades_events()
  local d, cid = open_with_conv("del_cas.db")
  local msg = db.create_message(d, "user", nil, nil, cid)
  db.add_content_block(d, msg.id, "text", {content = "hello"})
  db.log_event(d, "test_event", msg.id, nil, cid)

  local events_before = db.get_events(d, "test_event")
  assert(#events_before == 1, "should have 1 event before delete")

  db.delete_message(d, msg.id)

  local events_after = db.get_events(d, "test_event")
  assert(#events_after == 0, "events should be deleted when message is deleted")
  db.close(d)
end
test_delete_message_cascades_events()

-- Test with_transaction helper
local function test_with_transaction()
  local d, cid = open_with_conv("with_tx.db")

  -- Successful transaction
  local msg_id: string = nil
  db.with_transaction(d, function()
      local msg = db.create_message(d, "user", nil, nil, cid)
      db.add_content_block(d, msg.id, "text", {content = "hello"})
      msg_id = msg.id
    end)
  assert(msg_id, "msg_id should be set")
  assert(db.get_message_count(d) == 1, "should have 1 message after successful tx")

  -- Failed transaction (error in fn → rollback)
  local ok = pcall(function()
      db.with_transaction(d, function()
          db.create_message(d, "user", nil, nil, cid)
          error("deliberate failure")
        end)
    end)
  assert(db.get_message_count(d) == 1, "should still have 1 message after failed tx")

  db.close(d)
end
test_with_transaction()

print("all db tests passed")
