#!/usr/bin/env cosmic
local fs = require("cosmic.fs")
local proc = require("cosmic.proc")
local time = require("cosmic.time")
local queue = require("ah.queue")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

local function test_open_close()
  local db_path = fs.join(TEST_TMPDIR, "test_queue.db")
  local qdb, err = queue.open(db_path)
  assert(qdb, "failed to open queue db: " .. tostring(err))
  queue.close(qdb)
end
test_open_close()

local function test_lock_acquire_release()
  local db_path = fs.join(TEST_TMPDIR, "test_lock.db")
  local qdb = queue.open(db_path)

  -- Initially not locked
  local locked, pid = queue.is_locked(qdb)
  assert(not locked, "should not be locked initially")

  -- Acquire lock
  local acquired, err = queue.try_acquire_lock(qdb)
  assert(acquired, "should acquire lock: " .. tostring(err))

  -- Check lock info
  local info = queue.get_lock_info(qdb)
  assert(info, "should have lock info")
  assert(info.owner_pid == proc.getpid(), "owner_pid should be our pid")

  -- Should be able to re-acquire our own lock
  acquired, err = queue.try_acquire_lock(qdb)
  assert(acquired, "should re-acquire own lock: " .. tostring(err))

  -- Release lock
  local released = queue.release_lock(qdb)
  assert(released, "should release lock")

  -- Should not be locked anymore
  info = queue.get_lock_info(qdb)
  assert(info == nil, "should have no lock info after release")

  queue.close(qdb)
end
test_lock_acquire_release()

local function test_heartbeat()
  local db_path = fs.join(TEST_TMPDIR, "test_heartbeat.db")
  local qdb = queue.open(db_path)

  -- Acquire lock
  queue.try_acquire_lock(qdb)

  local info1 = queue.get_lock_info(qdb)
  local heartbeat1 = info1.heartbeat_at

  -- Wait a moment and update heartbeat
  time.sleep(0, 10000000)  -- 10ms
  queue.update_heartbeat(qdb)

  local info2 = queue.get_lock_info(qdb)
  -- Heartbeat should be same or newer (usually same since we only have second precision)
  assert(info2.heartbeat_at >= heartbeat1, "heartbeat should not decrease")

  queue.release_lock(qdb)
  queue.close(qdb)
end
test_heartbeat()

local function test_add_steer()
  local db_path = fs.join(TEST_TMPDIR, "test_steer.db")
  local qdb = queue.open(db_path)

  local msg = queue.add_steer(qdb, "test steering message")
  assert(msg.id, "message should have id")
  assert(msg.message_type == "steer", "message_type should be steer")
  assert(msg.content == "test steering message", "content mismatch")

  -- Should have 1 pending message
  assert(queue.pending_count(qdb, "steer") == 1, "should have 1 pending steer")
  assert(queue.pending_count(qdb, "followup") == 0, "should have 0 pending followup")

  queue.close(qdb)
end
test_add_steer()

local function test_add_followup()
  local db_path = fs.join(TEST_TMPDIR, "test_followup.db")
  local qdb = queue.open(db_path)

  local msg = queue.add_followup(qdb, "test followup message")
  assert(msg.id, "message should have id")
  assert(msg.message_type == "followup", "message_type should be followup")
  assert(msg.content == "test followup message", "content mismatch")

  -- Should have 1 pending message
  assert(queue.pending_count(qdb, "followup") == 1, "should have 1 pending followup")
  assert(queue.pending_count(qdb, "steer") == 0, "should have 0 pending steer")

  queue.close(qdb)
end
test_add_followup()

local function test_drain_steering()
  local db_path = fs.join(TEST_TMPDIR, "test_drain_steer.db")
  local qdb = queue.open(db_path)

  -- Add multiple steering messages
  queue.add_steer(qdb, "steer 1")
  queue.add_steer(qdb, "steer 2")
  queue.add_steer(qdb, "steer 3")

  assert(queue.pending_count(qdb, "steer") == 3, "should have 3 pending")

  -- Drain steering messages
  local messages = queue.drain_steering(qdb)
  assert(#messages == 3, "should drain 3 messages")
  assert(messages[1].content == "steer 1", "first message mismatch")
  assert(messages[2].content == "steer 2", "second message mismatch")
  assert(messages[3].content == "steer 3", "third message mismatch")

  -- Should have 0 pending after drain
  assert(queue.pending_count(qdb, "steer") == 0, "should have 0 pending after drain")

  -- Draining again should return empty
  local messages2 = queue.drain_steering(qdb)
  assert(#messages2 == 0, "second drain should be empty")

  queue.close(qdb)
end
test_drain_steering()

local function test_drain_followup()
  local db_path = fs.join(TEST_TMPDIR, "test_drain_followup.db")
  local qdb = queue.open(db_path)

  -- Add multiple followup messages
  queue.add_followup(qdb, "followup 1")
  queue.add_followup(qdb, "followup 2")

  assert(queue.pending_count(qdb, "followup") == 2, "should have 2 pending")

  -- Drain followup messages
  local messages = queue.drain_followup(qdb)
  assert(#messages == 2, "should drain 2 messages")
  assert(messages[1].content == "followup 1", "first message mismatch")
  assert(messages[2].content == "followup 2", "second message mismatch")

  -- Should have 0 pending after drain
  assert(queue.pending_count(qdb, "followup") == 0, "should have 0 pending after drain")

  queue.close(qdb)
end
test_drain_followup()

local function test_mixed_queues()
  local db_path = fs.join(TEST_TMPDIR, "test_mixed.db")
  local qdb = queue.open(db_path)

  -- Add both types
  queue.add_steer(qdb, "steer msg")
  queue.add_followup(qdb, "followup msg")
  queue.add_steer(qdb, "steer msg 2")

  assert(queue.pending_count(qdb) == 3, "should have 3 total pending")
  assert(queue.pending_count(qdb, "steer") == 2, "should have 2 pending steer")
  assert(queue.pending_count(qdb, "followup") == 1, "should have 1 pending followup")

  -- Drain steering only
  local steer_msgs = queue.drain_steering(qdb)
  assert(#steer_msgs == 2, "should drain 2 steer messages")

  -- Followup should still be pending
  assert(queue.pending_count(qdb, "followup") == 1, "followup should still be pending")

  -- Drain followup
  local followup_msgs = queue.drain_followup(qdb)
  assert(#followup_msgs == 1, "should drain 1 followup message")

  assert(queue.pending_count(qdb) == 0, "should have 0 total pending")

  queue.close(qdb)
end
test_mixed_queues()

local function test_stale_lock_detection()
  local db_path = fs.join(TEST_TMPDIR, "test_stale.db")
  local qdb = queue.open(db_path)

  -- Manually insert a stale lock (old heartbeat)
  local stale_time = os.time() - (queue.STALE_THRESHOLD + 10)
  qdb._db:exec([[
    insert or replace into session_lock (key, owner_pid, started_at, heartbeat_at)
    values ('lock', 99999, ?, ?)
  ]], stale_time, stale_time)

  -- Lock should be considered stale
  local locked, pid = queue.is_locked(qdb)
  assert(not locked, "stale lock should not be considered locked")
  assert(pid == 99999, "should return stale pid")

  -- Should be able to acquire (claim) the stale lock
  local acquired, err = queue.try_acquire_lock(qdb)
  assert(acquired, "should claim stale lock: " .. tostring(err))

  -- Now we own the lock
  local info = queue.get_lock_info(qdb)
  assert(info.owner_pid == proc.getpid(), "should now own the lock")

  queue.release_lock(qdb)
  queue.close(qdb)
end
test_stale_lock_detection()

local function test_dead_process_detection()
  local db_path = fs.join(TEST_TMPDIR, "test_dead.db")
  local qdb = queue.open(db_path)

  -- Insert a lock with a PID that doesn't exist (very high PID)
  local now = os.time()
  qdb._db:exec([[
    insert or replace into session_lock (key, owner_pid, started_at, heartbeat_at)
    values ('lock', 4000000000, ?, ?)
  ]], now, now)

  -- Lock should be considered stale because process is dead
  local locked, pid = queue.is_locked(qdb)
  assert(not locked, "dead process lock should not be considered locked")

  -- Should be able to acquire
  local acquired, err = queue.try_acquire_lock(qdb)
  assert(acquired, "should claim dead process lock: " .. tostring(err))

  queue.release_lock(qdb)
  queue.close(qdb)
end
test_dead_process_detection()

local function test_message_ordering()
  local db_path = fs.join(TEST_TMPDIR, "test_ordering.db")
  local qdb = queue.open(db_path)

  -- Add messages in specific order
  for i = 1, 5 do
    queue.add_steer(qdb, "msg " .. i)
  end

  -- Drain and verify order (ULID should preserve insertion order)
  local messages = queue.drain_steering(qdb)
  for i = 1, 5 do
    assert(messages[i].content == "msg " .. i,
      "message " .. i .. " out of order: got " .. messages[i].content)
  end

  queue.close(qdb)
end
test_message_ordering()

print("all queue tests passed")
