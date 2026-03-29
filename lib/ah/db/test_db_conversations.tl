#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local json = require("cosmic.json")
local db = require("ah.db")
local conversations = require("ah.conversations")
local queue = require("ah.queue")
local cenv = require("cosmic.env")

local TEST_TMPDIR = cenv.get("TEST_TMPDIR") or "/tmp"

-- Test: create and get a conversation
local function test_create_conversation()
  local db_path = fs.join(TEST_TMPDIR, "conv_create.db")
  local d = db.open(db_path)

  local conv = conversations.create_conversation(d)
  assert(conv, "should return conversation")
  assert(conv.id, "conversation should have id")
  assert(conv.state == "idle", "default state should be idle, got: " .. tostring(conv.state))
  assert(conv.created_at, "should have created_at")
  assert(conv.name == nil, "name should be nil by default")

  -- get it back
  local got = conversations.get_conversation(d, conv.id)
  assert(got, "should find conversation by id")
  assert(got.id == conv.id, "id mismatch")
  assert(got.state == "idle", "state mismatch")

  db.close(d)
end
test_create_conversation()

-- Test: create conversation with name
local function test_create_conversation_with_name()
  local db_path = fs.join(TEST_TMPDIR, "conv_name.db")
  local d = db.open(db_path)

  local conv = conversations.create_conversation(d, {name = "my-session"})
  assert(conv.name == "my-session", "name mismatch: " .. tostring(conv.name))

  local got = conversations.get_conversation(d, conv.id)
  assert(got.name == "my-session", "name should persist")

  db.close(d)
end
test_create_conversation_with_name()

-- Test: list conversations (most recent first)
local function test_list_conversations()
  local db_path = fs.join(TEST_TMPDIR, "conv_list.db")
  local d = db.open(db_path)

  local c1 = conversations.create_conversation(d)
  local c2 = conversations.create_conversation(d)
  local c3 = conversations.create_conversation(d)

  local all = conversations.list_conversations(d)
  assert(#all == 3, "expected 3 conversations, got " .. #all)
  -- ordered by id desc; ULIDs are monotonic so last created has highest id
  assert(all[1].id >= all[2].id, "should be sorted descending")
  assert(all[2].id >= all[3].id, "should be sorted descending")

  db.close(d)
end
test_list_conversations()

-- Test: resolve conversation by name
local function test_resolve_by_name()
  local db_path = fs.join(TEST_TMPDIR, "conv_resolve_name.db")
  local d = db.open(db_path)

  conversations.create_conversation(d, {name = "alpha"})
  local c2 = conversations.create_conversation(d, {name = "beta"})

  local resolved = conversations.resolve_conversation(d, "beta")
  assert(resolved, "should resolve by name")
  assert(resolved == c2.id, "resolved id mismatch")

  db.close(d)
end
test_resolve_by_name()

-- Test: resolve conversation by ULID prefix
local function test_resolve_by_prefix()
  local db_path = fs.join(TEST_TMPDIR, "conv_resolve_prefix.db")
  local d = db.open(db_path)

  local c1 = conversations.create_conversation(d)
  local prefix = c1.id:sub(1, 10)

  local resolved = conversations.resolve_conversation(d, prefix)
  assert(resolved, "should resolve by prefix")
  assert(resolved == c1.id, "resolved id mismatch")

  db.close(d)
end
test_resolve_by_prefix()

-- Test: resolve returns nil for no match
local function test_resolve_no_match()
  local db_path = fs.join(TEST_TMPDIR, "conv_resolve_none.db")
  local d = db.open(db_path)

  local resolved, err = conversations.resolve_conversation(d, "ZZZZZZZZZ")
  assert(not resolved, "should not resolve")
  assert(err, "should return error message")

  db.close(d)
end
test_resolve_no_match()

-- Test: resolve returns nil for ambiguous prefix
local function test_resolve_ambiguous()
  local db_path = fs.join(TEST_TMPDIR, "conv_resolve_ambig.db")
  local d = db.open(db_path)

  conversations.create_conversation(d)
  conversations.create_conversation(d)

  -- prefix "0" matches all ULIDs (they all start with 0)
  local resolved, err = conversations.resolve_conversation(d, "0")
  assert(not resolved, "should not resolve ambiguous")
  assert(err and err:find("ambiguous"), "should mention ambiguous: " .. tostring(err))

  db.close(d)
end
test_resolve_ambiguous()

-- Test: get latest non-closed conversation
local function test_get_current_conversation()
  local db_path = fs.join(TEST_TMPDIR, "conv_current.db")
  local d = db.open(db_path)

  local c1 = conversations.create_conversation(d)
  conversations.close_conversation(d, c1.id)

  local c2 = conversations.create_conversation(d)

  local current = conversations.get_current_conversation(d)
  assert(current, "should have current conversation")
  assert(current.id == c2.id, "current should be the non-closed one")

  db.close(d)
end
test_get_current_conversation()

-- Test: get_current_conversation returns nil when all closed
local function test_get_current_conversation_all_closed()
  local db_path = fs.join(TEST_TMPDIR, "conv_current_none.db")
  local d = db.open(db_path)

  local c1 = conversations.create_conversation(d)
  conversations.close_conversation(d, c1.id)

  local current = conversations.get_current_conversation(d)
  assert(not current, "should return nil when all closed")

  db.close(d)
end
test_get_current_conversation_all_closed()

-- Test: close_conversation sets state and closed_at
local function test_close_conversation()
  local db_path = fs.join(TEST_TMPDIR, "conv_close.db")
  local d = db.open(db_path)

  local c = conversations.create_conversation(d)
  assert(c.closed_at == nil, "closed_at should be nil initially")

  conversations.close_conversation(d, c.id)
  local got = conversations.get_conversation(d, c.id)
  assert(got.state == "closed", "state should be closed: " .. tostring(got.state))
  assert(got.closed_at, "closed_at should be set")

  db.close(d)
end
test_close_conversation()

-- Test: messages scoped to conversation
local function test_messages_in_conversation()
  local db_path = fs.join(TEST_TMPDIR, "conv_messages.db")
  local d = db.open(db_path)

  local c1 = conversations.create_conversation(d)
  local c2 = conversations.create_conversation(d)

  local m1 = db.create_message(d, "user", nil, nil, c1.id)
  local m2 = db.create_message(d, "assistant", m1.id, nil, c1.id)
  local m3 = db.create_message(d, "user", nil, nil, c2.id)

  -- ancestry in c1 should only include c1 messages
  local ancestry = db.get_ancestry(d, m2.id)
  assert(#ancestry == 2, "c1 ancestry should have 2, got " .. #ancestry)

  -- message count per conversation
  local count1 = db.get_message_count(d, c1.id)
  assert(count1 == 2, "c1 should have 2 messages, got " .. count1)

  local count2 = db.get_message_count(d, c2.id)
  assert(count2 == 1, "c2 should have 1 message, got " .. count2)

  db.close(d)
end
test_messages_in_conversation()

-- Test: events scoped to conversation
local function test_events_in_conversation()
  local db_path = fs.join(TEST_TMPDIR, "conv_events.db")
  local d = db.open(db_path)

  local c1 = conversations.create_conversation(d)
  local c2 = conversations.create_conversation(d)

  db.log_event(d, "startup", nil, nil, c1.id)
  db.log_event(d, "api_call_end", nil, '{"tokens":100}', c1.id)
  db.log_event(d, "startup", nil, nil, c2.id)

  local c1_events = db.get_events(d, nil, c1.id)
  assert(#c1_events == 2, "c1 should have 2 events, got " .. #c1_events)

  local c2_events = db.get_events(d, nil, c2.id)
  assert(#c2_events == 1, "c2 should have 1 event, got " .. #c2_events)

  db.close(d)
end
test_events_in_conversation()

-- Test: token totals scoped to conversation
local function test_token_totals_per_conversation()
  local db_path = fs.join(TEST_TMPDIR, "conv_tokens.db")
  local d = db.open(db_path)

  local c1 = conversations.create_conversation(d)
  local c2 = conversations.create_conversation(d)

  local m1 = db.create_message(d, "user", nil, nil, c1.id)
  local m2 = db.create_message(d, "assistant", m1.id, {input_tokens = 500, output_tokens = 100}, c1.id)
  db.log_event(d, "api_call_end", m2.id, json.encode({input_tokens = 500, output_tokens = 100}), c1.id)

  local m3 = db.create_message(d, "user", nil, nil, c2.id)
  local m4 = db.create_message(d, "assistant", m3.id, {input_tokens = 1000, output_tokens = 200}, c2.id)
  db.log_event(d, "api_call_end", m4.id, json.encode({input_tokens = 1000, output_tokens = 200}), c2.id)

  local t1 = db.get_session_token_totals(d, c1.id)
  assert(t1.input_tokens == 500, "c1 input should be 500, got " .. t1.input_tokens)
  assert(t1.output_tokens == 100, "c1 output should be 100, got " .. t1.output_tokens)

  local t2 = db.get_session_token_totals(d, c2.id)
  assert(t2.input_tokens == 1000, "c2 input should be 1000, got " .. t2.input_tokens)
  assert(t2.output_tokens == 200, "c2 output should be 200, got " .. t2.output_tokens)

  db.close(d)
end
test_token_totals_per_conversation()

-- Test: first user prompt scoped to conversation
local function test_first_prompt_per_conversation()
  local db_path = fs.join(TEST_TMPDIR, "conv_prompt.db")
  local d = db.open(db_path)

  local c1 = conversations.create_conversation(d)
  local c2 = conversations.create_conversation(d)

  local m1 = db.create_message(d, "user", nil, nil, c1.id)
  db.add_content_block(d, m1.id, "text", {content = "fix the bug"})

  local m2 = db.create_message(d, "user", nil, nil, c2.id)
  db.add_content_block(d, m2.id, "text", {content = "add a feature"})

  local p1 = db.get_first_user_prompt(d, c1.id)
  assert(p1 == "fix the bug", "c1 prompt mismatch: " .. p1)

  local p2 = db.get_first_user_prompt(d, c2.id)
  assert(p2 == "add a feature", "c2 prompt mismatch: " .. p2)

  db.close(d)
end
test_first_prompt_per_conversation()

-- Test: queue messages scoped to conversation
local function test_queue_in_conversation()
  local db_path = fs.join(TEST_TMPDIR, "conv_queue.db")
  local d = db.open(db_path)

  local c1 = conversations.create_conversation(d)
  local c2 = conversations.create_conversation(d)

  queue.add_queue_message(d, c1.id, "steer", "go left")
  queue.add_queue_message(d, c1.id, "followup", "then go right")
  queue.add_queue_message(d, c2.id, "steer", "go up")

  local steers = queue.drain_queue(d, c1.id, "steer")
  assert(#steers == 1, "c1 should have 1 steer, got " .. #steers)
  assert(steers[1].content == "go left", "steer content mismatch")

  local followups = queue.drain_queue(d, c1.id, "followup")
  assert(#followups == 1, "c1 should have 1 followup, got " .. #followups)

  -- c2 steers unaffected
  local c2_steers = queue.drain_queue(d, c2.id, "steer")
  assert(#c2_steers == 1, "c2 should have 1 steer, got " .. #c2_steers)

  -- draining again returns empty
  local empty = queue.drain_queue(d, c1.id, "steer")
  assert(#empty == 0, "drained queue should be empty")

  db.close(d)
end
test_queue_in_conversation()

-- Test: session lock (global, not per-conversation)
local function test_session_lock()
  local db_path = fs.join(TEST_TMPDIR, "conv_lock.db")
  local d = db.open(db_path)

  local locked = queue.is_locked(d)
  assert(not locked, "should not be locked initially")

  local acquired, err = queue.try_acquire_lock(d)
  assert(acquired, "should acquire lock: " .. tostring(err))

  local info = queue.get_lock_info(d)
  assert(info, "should have lock info")
  assert(info.owner_pid > 0, "owner_pid should be positive")

  local released = queue.release_lock(d)
  assert(released, "should release lock")

  db.close(d)
end
test_session_lock()

-- Test: conversation state management
local function test_conversation_state()
  local db_path = fs.join(TEST_TMPDIR, "conv_state.db")
  local d = db.open(db_path)

  local c = conversations.create_conversation(d)

  conversations.set_conversation_state(d, c.id, "processing")
  local got = conversations.get_conversation(d, c.id)
  assert(got.state == "processing", "state should be processing: " .. tostring(got.state))

  conversations.set_conversation_state(d, c.id, "idle")
  got = conversations.get_conversation(d, c.id)
  assert(got.state == "idle", "state should be idle: " .. tostring(got.state))

  db.close(d)
end
test_conversation_state()

-- Test: cleanup orphans scoped to conversation
local function test_cleanup_orphans_per_conversation()
  local db_path = fs.join(TEST_TMPDIR, "conv_orphans.db")
  local d = db.open(db_path)

  local c1 = conversations.create_conversation(d)
  local c2 = conversations.create_conversation(d)

  -- c1: valid message + orphan
  local m1 = db.create_message(d, "user", nil, nil, c1.id)
  db.add_content_block(d, m1.id, "text", {content = "hello"})
  db.create_message(d, "assistant", m1.id, nil, c1.id) -- orphan (no content)

  -- c2: valid message only
  local m3 = db.create_message(d, "user", nil, nil, c2.id)
  db.add_content_block(d, m3.id, "text", {content = "world"})

  local cleaned = db.cleanup_orphans(d)
  assert(cleaned == 1, "should clean 1 orphan, got " .. cleaned)

  assert(db.get_message_count(d, c1.id) == 1, "c1 should have 1 message after cleanup")
  assert(db.get_message_count(d, c2.id) == 1, "c2 should have 1 message")

  db.close(d)
end
test_cleanup_orphans_per_conversation()

-- Test: heartbeat update
local function test_heartbeat()
  local db_path = fs.join(TEST_TMPDIR, "conv_heartbeat.db")
  local d = db.open(db_path)

  queue.try_acquire_lock(d)
  local ok = queue.update_heartbeat(d)
  assert(ok, "heartbeat should succeed")
  queue.release_lock(d)

  db.close(d)
end
test_heartbeat()

-- Test: pending queue count
local function test_pending_count()
  local db_path = fs.join(TEST_TMPDIR, "conv_pending.db")
  local d = db.open(db_path)

  local c = conversations.create_conversation(d)

  assert(queue.pending_count(d, c.id) == 0, "should start at 0")

  queue.add_queue_message(d, c.id, "steer", "msg1")
  queue.add_queue_message(d, c.id, "steer", "msg2")
  queue.add_queue_message(d, c.id, "followup", "msg3")

  assert(queue.pending_count(d, c.id) == 3, "should have 3 pending")
  assert(queue.pending_count(d, c.id, "steer") == 2, "should have 2 steers")
  assert(queue.pending_count(d, c.id, "followup") == 1, "should have 1 followup")

  queue.drain_queue(d, c.id, "steer")
  assert(queue.pending_count(d, c.id, "steer") == 0, "steers should be drained")
  assert(queue.pending_count(d, c.id) == 1, "should have 1 remaining")

  db.close(d)
end
test_pending_count()

print("all db conversation tests passed")
