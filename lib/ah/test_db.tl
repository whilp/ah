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

local function test_session_crud()
  local db_path = fs.join(TEST_TMPDIR, "test.db")
  local d = db.open(db_path)

  -- Create session
  local session = db.create_session(d, "test-session", "/tmp", "You are helpful")
  assert(session.id, "session should have id")
  assert(session.name == "test-session", "session name mismatch")
  assert(session.cwd == "/tmp", "session cwd mismatch")
  assert(session.system_prompt == "You are helpful", "session prompt mismatch")

  -- Get session
  local fetched = db.get_session(d, session.id)
  assert(fetched, "failed to fetch session")
  assert(fetched.id == session.id, "fetched session id mismatch")

  -- Get by name
  local by_name = db.get_session_by_name(d, "test-session")
  assert(by_name, "failed to fetch session by name")
  assert(by_name.id == session.id, "fetched by name id mismatch")

  -- List sessions
  local sessions = db.list_sessions(d)
  assert(#sessions == 1, "expected 1 session")

  -- Current session
  local current = db.get_current_session(d)
  assert(current, "no current session")
  assert(current.id == session.id, "current session id mismatch")

  -- Delete session
  db.delete_session(d, session.id)
  local deleted = db.get_session(d, session.id)
  assert(not deleted, "session should be deleted")

  db.close(d)
end
test_session_crud()

local function test_messages()
  local db_path = fs.join(TEST_TMPDIR, "test.db")
  local d = db.open(db_path)

  local session = db.create_session(d)

  -- Create root message
  local msg1 = db.create_message(d, session.id, "user")
  assert(msg1.id, "message should have id")
  assert(msg1.role == "user", "message role mismatch")
  assert(msg1.seq == 0, "root message should have seq 0")

  -- Create child message
  local msg2 = db.create_message(d, session.id, "assistant", msg1.id)
  assert(msg2.seq == 1, "child message should have seq 1")
  assert(msg2.parent_id == msg1.id, "parent_id mismatch")

  -- Get ancestry
  local ancestry = db.get_ancestry(d, msg2.id)
  assert(#ancestry == 2, "expected 2 messages in ancestry")
  assert(ancestry[1].id == msg1.id, "first in ancestry should be root")
  assert(ancestry[2].id == msg2.id, "second in ancestry should be child")

  -- Get last message
  local last = db.get_last_message(d, session.id)
  assert(last, "should have last message")
  assert(last.id == msg2.id, "last message should be msg2")

  -- Get by seq
  local by_seq = db.get_message_by_seq(d, session.id, 0)
  assert(by_seq, "should find message by seq")
  assert(by_seq.id == msg1.id, "wrong message by seq")

  db.close(d)
end
test_messages()

local function test_content_blocks()
  local db_path = fs.join(TEST_TMPDIR, "test.db")
  local d = db.open(db_path)

  local session = db.create_session(d)
  local msg = db.create_message(d, session.id, "assistant")

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

  local session = db.create_session(d)

  -- Create a conversation: user -> assistant -> user -> assistant
  local msg1 = db.create_message(d, session.id, "user")
  local msg2 = db.create_message(d, session.id, "assistant", msg1.id)
  local msg3 = db.create_message(d, session.id, "user", msg2.id)
  local msg4 = db.create_message(d, session.id, "assistant", msg3.id)

  -- Fork from msg2 (after first assistant response)
  local fork_msg = db.create_message(d, session.id, "user", msg2.id)
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

print("all db tests passed")
