#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local time = require("cosmic.time")
local db = require("ah.db")
local conversations = require("ah.conversations")
local queue = require("ah.queue")
local cenv = require("cosmic.env")

local TEST_TMPDIR = cenv.get("TEST_TMPDIR") or "/tmp"

local function test_lock_acquire_release()
  local db_path = fs.join(TEST_TMPDIR, "test_lock.db")
  local d = db.open(db_path)

  -- Initially not locked
  local locked, pid = queue.is_locked(d)
  assert(not locked, "should not be locked initially")

  -- Acquire lock
  local acquired, err = queue.try_acquire_lock(d)
  assert(acquired, "should acquire lock: " .. tostring(err))

  -- Check lock info
  local info = queue.get_lock_info(d)
  assert(info, "should have lock info")
  assert(info.owner_pid == proc.getpid(), "owner_pid should be our pid")

  -- Should be able to re-acquire our own lock
  acquired, err = queue.try_acquire_lock(d)
  assert(acquired, "should re-acquire own lock: " .. tostring(err))

  -- Release lock
  local released = queue.release_lock(d)
  assert(released, "should release lock")

  -- Should not be locked anymore
  info = queue.get_lock_info(d)
  assert(info == nil, "should have no lock info after release")

  db.close(d)
end
test_lock_acquire_release()

local function test_heartbeat()
  local db_path = fs.join(TEST_TMPDIR, "test_heartbeat.db")
  local d = db.open(db_path)

  queue.try_acquire_lock(d)

  local info1 = queue.get_lock_info(d)
  local heartbeat1 = info1.heartbeat_at

  time.sleep(0, 10000000) -- 10ms
  queue.update_heartbeat(d)

  local info2 = queue.get_lock_info(d)
  assert(info2.heartbeat_at >= heartbeat1, "heartbeat should not decrease")

  queue.release_lock(d)
  db.close(d)
end
test_heartbeat()

local function test_add_steer()
  local db_path = fs.join(TEST_TMPDIR, "test_steer.db")
  local d = db.open(db_path)
  local conv = conversations.create_conversation(d)

  local msg = queue.add_steer(d, conv.id, "test steering message")
  assert(msg.id, "message should have id")
  assert(msg.message_type == "steer", "message_type should be steer")
  assert(msg.content == "test steering message", "content mismatch")

  assert(queue.pending_count(d, conv.id, "steer") == 1, "should have 1 pending steer")
  assert(queue.pending_count(d, conv.id, "followup") == 0, "should have 0 pending followup")

  db.close(d)
end
test_add_steer()

local function test_add_followup()
  local db_path = fs.join(TEST_TMPDIR, "test_followup.db")
  local d = db.open(db_path)
  local conv = conversations.create_conversation(d)

  local msg = queue.add_followup(d, conv.id, "test followup message")
  assert(msg.id, "message should have id")
  assert(msg.message_type == "followup", "message_type should be followup")
  assert(msg.content == "test followup message", "content mismatch")

  assert(queue.pending_count(d, conv.id, "followup") == 1, "should have 1 pending followup")
  assert(queue.pending_count(d, conv.id, "steer") == 0, "should have 0 pending steer")

  db.close(d)
end
test_add_followup()

local function test_drain_steering()
  local db_path = fs.join(TEST_TMPDIR, "test_drain_steer.db")
  local d = db.open(db_path)
  local conv = conversations.create_conversation(d)

  queue.add_steer(d, conv.id, "steer 1")
  queue.add_steer(d, conv.id, "steer 2")
  queue.add_steer(d, conv.id, "steer 3")

  assert(queue.pending_count(d, conv.id, "steer") == 3, "should have 3 pending")

  local messages = queue.drain_steering(d, conv.id)
  assert(#messages == 3, "should drain 3 messages")
  assert(messages[1].content == "steer 1", "first message mismatch")
  assert(messages[2].content == "steer 2", "second message mismatch")
  assert(messages[3].content == "steer 3", "third message mismatch")

  assert(queue.pending_count(d, conv.id, "steer") == 0, "should have 0 pending after drain")

  local messages2 = queue.drain_steering(d, conv.id)
  assert(#messages2 == 0, "second drain should be empty")

  db.close(d)
end
test_drain_steering()

local function test_drain_followup()
  local db_path = fs.join(TEST_TMPDIR, "test_drain_followup.db")
  local d = db.open(db_path)
  local conv = conversations.create_conversation(d)

  queue.add_followup(d, conv.id, "followup 1")
  queue.add_followup(d, conv.id, "followup 2")

  assert(queue.pending_count(d, conv.id, "followup") == 2, "should have 2 pending")

  local messages = queue.drain_followup(d, conv.id)
  assert(#messages == 2, "should drain 2 messages")
  assert(messages[1].content == "followup 1", "first message mismatch")
  assert(messages[2].content == "followup 2", "second message mismatch")

  assert(queue.pending_count(d, conv.id, "followup") == 0, "should have 0 pending after drain")

  db.close(d)
end
test_drain_followup()

local function test_mixed_queues()
  local db_path = fs.join(TEST_TMPDIR, "test_mixed.db")
  local d = db.open(db_path)
  local conv = conversations.create_conversation(d)

  queue.add_steer(d, conv.id, "steer msg")
  queue.add_followup(d, conv.id, "followup msg")
  queue.add_steer(d, conv.id, "steer msg 2")

  assert(queue.pending_count(d, conv.id) == 3, "should have 3 total pending")
  assert(queue.pending_count(d, conv.id, "steer") == 2, "should have 2 pending steer")
  assert(queue.pending_count(d, conv.id, "followup") == 1, "should have 1 pending followup")

  local steer_msgs = queue.drain_steering(d, conv.id)
  assert(#steer_msgs == 2, "should drain 2 steer messages")

  assert(queue.pending_count(d, conv.id, "followup") == 1, "followup should still be pending")

  local followup_msgs = queue.drain_followup(d, conv.id)
  assert(#followup_msgs == 1, "should drain 1 followup message")

  assert(queue.pending_count(d, conv.id) == 0, "should have 0 total pending")

  db.close(d)
end
test_mixed_queues()

local function test_stale_lock_detection()
  local db_path = fs.join(TEST_TMPDIR, "test_stale.db")
  local d = db.open(db_path)

  local stale_time = os.time() - (queue.STALE_THRESHOLD + 10)
  d._db:exec([[
    insert or replace into session_lock (key, owner_pid, started_at, heartbeat_at)
    values ('lock', 99999, ?, ?)
  ]], stale_time, stale_time)

  local locked, pid = queue.is_locked(d)
  assert(not locked, "stale lock should not be considered locked")
  assert(pid == 99999, "should return stale pid")

  local acquired, err = queue.try_acquire_lock(d)
  assert(acquired, "should claim stale lock: " .. tostring(err))

  local info = queue.get_lock_info(d)
  assert(info.owner_pid == proc.getpid(), "should now own the lock")

  queue.release_lock(d)
  db.close(d)
end
test_stale_lock_detection()

local function test_dead_process_detection()
  local db_path = fs.join(TEST_TMPDIR, "test_dead.db")
  local d = db.open(db_path)

  local now = time.now()
  d._db:exec([[
    insert or replace into session_lock (key, owner_pid, started_at, heartbeat_at)
    values ('lock', 4000000000, ?, ?)
  ]], now, now)

  local locked, pid = queue.is_locked(d)
  assert(not locked, "dead process lock should not be considered locked")

  local acquired, err = queue.try_acquire_lock(d)
  assert(acquired, "should claim dead process lock: " .. tostring(err))

  queue.release_lock(d)
  db.close(d)
end
test_dead_process_detection()

local function test_message_ordering()
  local db_path = fs.join(TEST_TMPDIR, "test_ordering.db")
  local d = db.open(db_path)
  local conv = conversations.create_conversation(d)

  for i = 1, 5 do
    queue.add_steer(d, conv.id, "msg " .. i)
  end

  local messages = queue.drain_steering(d, conv.id)
  for i = 1, 5 do
    assert(messages[i].content == "msg " .. i,
      "message " .. i .. " out of order: got " .. messages[i].content)
  end

  db.close(d)
end
test_message_ordering()

print("all queue tests passed")
