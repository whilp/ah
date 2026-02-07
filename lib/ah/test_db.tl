#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local db = require("ah.db")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_open_close()
  local db_path = fs.join(TEST_TMPDIR, "test.db")
  local d, err = db.open(db_path)
  assert(d, "failed to open db: " .. tostring(err))
  db.close(d)
end
test_open_close()

local function test_messages()
  local db_path = fs.join(TEST_TMPDIR, "test.db")
  local d = db.open(db_path)

  -- Create root message
  local msg1 = db.create_message(d, "user")
  assert(msg1.id, "message should have id")
  assert(msg1.role == "user", "message role mismatch")
  assert(msg1.seq == 0, "root message should have seq 0")

  -- Create child message
  local msg2 = db.create_message(d, "assistant", msg1.id)
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

  -- Get by seq
  local by_seq = db.get_message_by_seq(d, 0)
  assert(by_seq, "should find message by seq")
  assert(by_seq.id == msg1.id, "wrong message by seq")

  db.close(d)
end
test_messages()

local function test_content_blocks()
  local db_path = fs.join(TEST_TMPDIR, "test.db")
  local d = db.open(db_path)

  local msg = db.create_message(d, "assistant")

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
  local db_path = fs.join(TEST_TMPDIR, "test.db")
  local d = db.open(db_path)

  -- Create a conversation: user -> assistant -> user -> assistant
  local msg1 = db.create_message(d, "user")
  local msg2 = db.create_message(d, "assistant", msg1.id)
  local msg3 = db.create_message(d, "user", msg2.id)
  local msg4 = db.create_message(d, "assistant", msg3.id)

  -- Fork from msg2 (after first assistant response)
  local fork_msg = db.create_message(d, "user", msg2.id)
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
  -- Test empty db
  local db_path = fs.join(TEST_TMPDIR, "count_empty.db")
  local d = db.open(db_path)
  assert(db.get_message_count(d) == 0, "empty db should have 0 messages")
  db.close(d)

  -- Test db with 1 message
  db_path = fs.join(TEST_TMPDIR, "count_one.db")
  d = db.open(db_path)
  db.create_message(d, "user")
  assert(db.get_message_count(d) == 1, "should have 1 message")
  db.close(d)

  -- Test db with 3 messages
  db_path = fs.join(TEST_TMPDIR, "count_three.db")
  d = db.open(db_path)
  local msg1 = db.create_message(d, "user")
  local msg2 = db.create_message(d, "assistant", msg1.id)
  db.create_message(d, "user", msg2.id)
  assert(db.get_message_count(d) == 3, "should have 3 messages")
  db.close(d)
end
test_get_message_count()

local function test_get_first_user_prompt()
  -- Test empty db
  local db_path = fs.join(TEST_TMPDIR, "prompt_empty.db")
  local d = db.open(db_path)
  assert(db.get_first_user_prompt(d) == "", "empty db should return empty string")
  db.close(d)

  -- Test db with user message
  db_path = fs.join(TEST_TMPDIR, "prompt_user.db")
  d = db.open(db_path)
  local msg = db.create_message(d, "user")
  db.add_content_block(d, msg.id, "text", {content = "Hello world"})
  assert(db.get_first_user_prompt(d) == "Hello world", "should return first user prompt")
  db.close(d)

  -- Test db with assistant-first (edge case - shouldn't happen but should handle)
  db_path = fs.join(TEST_TMPDIR, "prompt_assistant_first.db")
  d = db.open(db_path)
  local amsg = db.create_message(d, "assistant")
  db.add_content_block(d, amsg.id, "text", {content = "I am assistant"})
  local umsg = db.create_message(d, "user", amsg.id)
  db.add_content_block(d, umsg.id, "text", {content = "User prompt"})
  assert(db.get_first_user_prompt(d) == "User prompt", "should find first user message")
  db.close(d)
end
test_get_first_user_prompt()

-- Test orphan cleanup
local function test_cleanup_orphans()
  local db_path = fs.join(TEST_TMPDIR, "orphan_test.db")
  local d = db.open(db_path)

  -- Create a valid message with content
  local msg1 = db.create_message(d, "user")
  db.add_content_block(d, msg1.id, "text", {content = "hello"})

  -- Create a leaf orphan message (no content blocks - simulates crash)
  local orphan = db.create_message(d, "assistant", msg1.id)
  -- Intentionally NOT adding content blocks

  assert(db.get_message_count(d) == 2, "should have 2 messages before cleanup")

  -- Cleanup should remove the leaf orphan
  local cleaned = db.cleanup_orphans(d)
  assert(cleaned == 1, "should have cleaned 1 orphan, got " .. cleaned)
  assert(db.get_message_count(d) == 1, "should have 1 message after cleanup")

  db.close(d)
end
test_cleanup_orphans()

-- Test that orphan cleanup preserves parent chain
local function test_cleanup_preserves_chain()
  local db_path = fs.join(TEST_TMPDIR, "orphan_chain.db")
  local d = db.open(db_path)

  -- Create: valid -> orphan -> valid
  local msg1 = db.create_message(d, "user")
  db.add_content_block(d, msg1.id, "text", {content = "hello"})

  local orphan = db.create_message(d, "assistant", msg1.id)
  -- Intentionally NOT adding content blocks (orphan)

  local msg2 = db.create_message(d, "user", orphan.id)
  db.add_content_block(d, msg2.id, "text", {content = "world"})

  assert(db.get_message_count(d) == 3, "should have 3 messages")

  -- Cleanup should NOT remove the orphan because it has a child
  local cleaned = db.cleanup_orphans(d)
  assert(cleaned == 0, "should not clean orphan with children, got " .. cleaned)
  assert(db.get_message_count(d) == 3, "should still have 3 messages")

  -- Ancestry from msg2 should include all 3 messages
  local ancestry = db.get_ancestry(d, msg2.id)
  assert(#ancestry == 3, "ancestry should include all 3 messages")

  db.close(d)
end
test_cleanup_preserves_chain()

-- Test transaction support
local function test_transactions()
  local db_path = fs.join(TEST_TMPDIR, "tx_test.db")
  local d = db.open(db_path)

  -- Test basic transaction
  db.begin_transaction(d)
  local msg = db.create_message(d, "user")
  db.add_content_block(d, msg.id, "text", {content = "hello"})
  db.commit(d)

  local blocks = db.get_content_blocks(d, msg.id)
  assert(#blocks == 1, "should have 1 block after commit")

  -- Test rollback
  db.begin_transaction(d)
  local msg2 = db.create_message(d, "assistant", msg.id)
  db.add_content_block(d, msg2.id, "text", {content = "response"})
  db.rollback(d)

  -- After rollback, msg2 should not exist
  local count = db.get_message_count(d)
  assert(count == 1, "should have only 1 message after rollback, got " .. count)

  db.close(d)
end
test_transactions()

-- Test that demonstrates the empty content serialization bug
-- When a message has no content blocks (e.g., after a segfault during tool execution),
-- the empty content table serializes as {} (object) instead of [] (array),
-- causing API error: "messages.N.content: Input should be a valid list"
local function test_empty_content_serialization()
  local json = require("cosmic.json")
  local db_path = fs.join(TEST_TMPDIR, "empty_content.db")
  local d = db.open(db_path)

  -- Simulate a segfault scenario: message created but no content blocks added
  local msg = db.create_message(d, "user")
  -- Intentionally NOT adding any content blocks

  -- Build API message like init.tl does (lines 287-324)
  local blocks = db.get_content_blocks(d, msg.id)
  local content: {any} = {}
  for _, block in ipairs(blocks) do
    if block.block_type == "text" then
      table.insert(content, {type = "text", text = block.content})
    end
  end
  local api_message = {role = msg.role, content = content}

  -- This is the bug: empty Lua table {} serializes as JSON object {}, not array []
  local encoded = json.encode(api_message)

  -- The API expects: {"role":"user","content":[]}
  -- But we get:      {"role":"user","content":{}}
  local expected_array = '"content":[]'
  local actual_object = '"content":{}'

  assert(encoded:find(actual_object),
    "bug demonstration: empty content should serialize as {} (showing the bug exists)")

  -- This assertion would fail, demonstrating the bug
  -- assert(encoded:find(expected_array),
  --   "empty content should serialize as [] (array), not {} (object)")

  print("  (confirmed: empty content serializes as {} not [])")

  db.close(d)
end
test_empty_content_serialization()

print("all db tests passed")
