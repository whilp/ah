#!/usr/bin/env cosmic
-- test_branch.tl: tests for branching UX (tree, branches, checkout, branch rm)
local fs = require("cosmic.fs")
local db = require("ah.db")

local TEST_TMPDIR = os.getenv("TEST_TMPDIR") or "/tmp"

-- Counter for unique db paths
local db_counter = 0

-- Helper: create a conversation tree for testing
-- Returns: d, msg1(U@0), msg2(A@1), msg3(U@2), msg4(A@3), fork5(U@2), fork6(A@3)
--
-- Tree structure:
--   msg1 (user @0)
--   └─ msg2 (assistant @1)
--      ├─ msg3 (user @2)
--      │  └─ msg4 (assistant @3)
--      └─ fork5 (user @2)
--         └─ fork6 (assistant @3)
--
local function make_tree(): db.DB, db.Message, db.Message, db.Message, db.Message, db.Message, db.Message
  db_counter = db_counter + 1
  local db_path = fs.join(TEST_TMPDIR, "branch_tree_" .. tostring(db_counter) .. ".db")
  local d = db.open(db_path)

  local msg1 = db.create_message(d, "user")
  db.add_content_block(d, msg1.id, "text", {content = "Hello"})

  local msg2 = db.create_message(d, "assistant", msg1.id)
  db.add_content_block(d, msg2.id, "text", {content = "Hi there"})

  local msg3 = db.create_message(d, "user", msg2.id)
  db.add_content_block(d, msg3.id, "text", {content = "Tell me about Lua"})

  local msg4 = db.create_message(d, "assistant", msg3.id)
  db.add_content_block(d, msg4.id, "text", {content = "Lua is a scripting language"})

  -- Fork from msg2: alternative branch
  local fork5 = db.create_message(d, "user", msg2.id)
  db.add_content_block(d, fork5.id, "text", {content = "Tell me about Python"})

  local fork6 = db.create_message(d, "assistant", fork5.id)
  db.add_content_block(d, fork6.id, "text", {content = "Python is a programming language"})

  return d, msg1, msg2, msg3, msg4, fork5, fork6
end

-- Test: get_children
local function test_get_children()
  local d, msg1, msg2, msg3, _, fork5 = make_tree()

  -- Root has one child
  local children1 = db.get_children(d, msg1.id)
  assert(#children1 == 1, "msg1 should have 1 child, got " .. #children1)
  assert(children1[1].id == msg2.id, "msg1's child should be msg2")

  -- msg2 has two children (fork point)
  local children2 = db.get_children(d, msg2.id)
  assert(#children2 == 2, "msg2 should have 2 children, got " .. #children2)

  -- msg3 has one child
  local children3 = db.get_children(d, msg3.id)
  assert(#children3 == 1, "msg3 should have 1 child, got " .. #children3)

  -- fork5 has one child
  local children5 = db.get_children(d, fork5.id)
  assert(#children5 == 1, "fork5 should have 1 child, got " .. #children5)

  db.close(d)
end
test_get_children()

-- Test: get_root_messages
local function test_get_root_messages()
  local d, msg1 = make_tree()

  local roots = db.get_root_messages(d)
  assert(#roots == 1, "should have 1 root, got " .. #roots)
  assert(roots[1].id == msg1.id, "root should be msg1")

  db.close(d)
end
test_get_root_messages()

-- Test: get_leaf_messages
local function test_get_leaf_messages()
  local d, _, _, _, msg4, _, fork6 = make_tree()

  local leaves = db.get_leaf_messages(d)
  assert(#leaves == 2, "should have 2 leaves, got " .. #leaves)

  -- Verify both leaves are present (msg4 and fork6)
  local leaf_ids: {string:boolean} = {}
  for _, l in ipairs(leaves) do
    leaf_ids[l.id] = true
  end
  assert(leaf_ids[msg4.id], "msg4 should be a leaf")
  assert(leaf_ids[fork6.id], "fork6 should be a leaf")

  db.close(d)
end
test_get_leaf_messages()

-- Test: get_message_by_seq_in_branch
local function test_get_message_by_seq_in_branch()
  local d, _, _, msg3, msg4, fork5, fork6 = make_tree()

  -- seq 2 is ambiguous: msg3 and fork5 both have seq 2
  -- When branch tip is msg4, should prefer msg3 (in that ancestry)
  local resolved = db.get_message_by_seq_in_branch(d, 2, msg4.id)
  assert(resolved, "should find message with seq 2 in msg4 branch")
  assert(resolved.id == msg3.id, "seq 2 in msg4 branch should resolve to msg3")

  -- When branch tip is fork6, should prefer fork5
  resolved = db.get_message_by_seq_in_branch(d, 2, fork6.id)
  assert(resolved, "should find message with seq 2 in fork6 branch")
  assert(resolved.id == fork5.id, "seq 2 in fork6 branch should resolve to fork5")

  -- seq 3 is also ambiguous: msg4 and fork6 both have seq 3
  resolved = db.get_message_by_seq_in_branch(d, 3, msg4.id)
  assert(resolved, "should find message with seq 3 in msg4 branch")
  assert(resolved.id == msg4.id, "seq 3 in msg4 branch should resolve to msg4")

  resolved = db.get_message_by_seq_in_branch(d, 3, fork6.id)
  assert(resolved, "should find message with seq 3 in fork6 branch")
  assert(resolved.id == fork6.id, "seq 3 in fork6 branch should resolve to fork6")

  -- seq 0 is unambiguous: only msg1 has seq 0
  resolved = db.get_message_by_seq_in_branch(d, 0, msg4.id)
  assert(resolved, "should find message with seq 0")
  assert(resolved.seq == 0, "seq 0 should be found")

  -- nil branch_tip_id falls back to global lookup
  resolved = db.get_message_by_seq_in_branch(d, 0, nil)
  assert(resolved, "should find message with seq 0 with nil branch_tip")
  assert(resolved.seq == 0, "seq 0 should be found with nil branch_tip")

  db.close(d)
end
test_get_message_by_seq_in_branch()

-- Test: get_depth
local function test_get_depth()
  local d, msg1, _, _, msg4, _, fork6 = make_tree()

  local depth0 = db.get_depth(d, msg1.id)
  assert(depth0 == 0, "root depth should be 0, got " .. depth0)

  local depth3 = db.get_depth(d, msg4.id)
  assert(depth3 == 3, "msg4 depth should be 3, got " .. depth3)

  local depth3b = db.get_depth(d, fork6.id)
  assert(depth3b == 3, "fork6 depth should be 3, got " .. depth3b)

  db.close(d)
end
test_get_depth()

-- Test: delete_branch
local function test_delete_branch()
  local d, _, _, msg3, _, _, fork6 = make_tree()

  -- Delete fork branch (fork5 + fork6)
  -- fork5 is a child of msg2, get its ID
  local fork6_ancestry = db.get_ancestry(d, fork6.id)
  local fork5_id = fork6_ancestry[3].id -- msg1, msg2, fork5, fork6

  local count = db.delete_branch(d, fork5_id)
  assert(count == 2, "should delete 2 messages (fork5 + fork6), got " .. count)

  -- Original branch should still be intact
  local leaves = db.get_leaf_messages(d)
  assert(#leaves == 1, "should have 1 leaf after branch deletion, got " .. #leaves)

  -- msg3 ancestry should be unchanged
  local ancestry = db.get_ancestry(d, msg3.id)
  assert(#ancestry == 3, "msg3 ancestry should have 3 messages, got " .. #ancestry)

  db.close(d)
end
test_delete_branch()

-- Test: delete_branch resets current_message when deleted
local function test_delete_branch_resets_current()
  local d, _, _, _, _, _, fork6 = make_tree()

  -- Set current to fork6
  db.set_current_message(d, fork6.id)
  assert(db.get_current_message(d).id == fork6.id, "current should be fork6")

  -- Delete fork branch
  local fork6_ancestry = db.get_ancestry(d, fork6.id)
  local fork5_id = fork6_ancestry[3].id

  db.delete_branch(d, fork5_id)

  -- Current message should be cleared
  local current = db.get_current_message(d)
  assert(current == nil, "current should be nil after deleting its branch")

  db.close(d)
end
test_delete_branch_resets_current()

-- Test: tree command output (smoke test - just verify it doesn't crash)
local function test_cmd_tree_smoke()
  local d = make_tree()

  -- Redirect stdout to capture output
  local old_write = io.write
  local output = ""
  io.write = function(...: any): FILE, string, integer
    for i = 1, select("#", ...) do
      output = output .. tostring(select(i, ...))
    end
    return io.stdout, nil, nil
  end

  local init = require("ah.init")
  init.cmd_tree(d)

  io.write = old_write

  -- Verify output contains key elements
  assert(output:match("Hello"), "tree should show 'Hello' message")
  assert(output:match("Hi there"), "tree should show 'Hi there' message")
  assert(output:match("Lua"), "tree should show Lua branch")
  assert(output:match("Python"), "tree should show Python branch")
  assert(output:match("├"), "tree should have branch connector")
  assert(output:match("└"), "tree should have last-child connector")

  db.close(d)
end
test_cmd_tree_smoke()

-- Test: branches command output
local function test_cmd_branches_smoke()
  local d = make_tree()

  local old_write = io.write
  local output = ""
  io.write = function(...: any): FILE, string, integer
    for i = 1, select("#", ...) do
      output = output .. tostring(select(i, ...))
    end
    return io.stdout, nil, nil
  end

  local init = require("ah.init")
  init.cmd_branches(d)

  io.write = old_write

  -- Should show 2 branch tips
  local line_count = 0
  for _ in output:gmatch("[^\n]+") do
    line_count = line_count + 1
  end
  assert(line_count == 2, "should show 2 branch tips, got " .. line_count)
  assert(output:match("depth:3"), "should show depth 3 for leaves")

  db.close(d)
end
test_cmd_branches_smoke()

-- Test: checkout command
local function test_cmd_checkout()
  local d, msg1, _, _, msg4, _, fork6 = make_tree()
  local init = require("ah.init")

  -- Current should be fork6 (last created)
  local current = db.get_current_message(d)
  assert(current.id == fork6.id, "current should be fork6 initially")

  -- Capture output
  local old_write = io.write
  local output = ""
  io.write = function(...: any): FILE, string, integer
    for i = 1, select("#", ...) do
      output = output .. tostring(select(i, ...))
    end
    return io.stdout, nil, nil
  end

  -- Checkout to msg1 (seq 0)
  init.cmd_checkout(d, 0)

  io.write = old_write

  -- Verify current message changed
  current = db.get_current_message(d)
  assert(current.id == msg1.id, "current should be msg1 after checkout @0")
  assert(output:match("switched to @0"), "output should confirm switch")

  db.close(d)
end
test_cmd_checkout()

-- Test: branch rm command
local function test_cmd_branch_rm()
  local d, _, _, _, msg4, fork5, fork6 = make_tree()
  local init = require("ah.init")

  -- Set current to fork6 so branch-aware resolution resolves @2 to fork5
  db.set_current_message(d, fork6.id)

  local old_write = io.write
  local output = ""
  io.write = function(...: any): FILE, string, integer
    for i = 1, select("#", ...) do
      output = output .. tostring(select(i, ...))
    end
    return io.stdout, nil, nil
  end

  -- fork5 has seq 2, same as msg3. Branch-aware resolution should pick fork5
  init.cmd_branch_rm(d, fork5.seq)

  io.write = old_write

  assert(output:match("deleted 2"), "should delete 2 messages, got: " .. output)

  -- Only one leaf should remain (msg4)
  local leaves = db.get_leaf_messages(d)
  assert(#leaves == 1, "should have 1 leaf after branch rm, got " .. #leaves)
  assert(leaves[1].id == msg4.id, "remaining leaf should be msg4")

  db.close(d)
end
test_cmd_branch_rm()

-- Test: tree shows current message marker
local function test_tree_current_marker()
  local d, _, _, _, msg4 = make_tree()
  local init = require("ah.init")

  -- Set current to msg4
  db.set_current_message(d, msg4.id)

  local old_write = io.write
  local output = ""
  io.write = function(...: any): FILE, string, integer
    for i = 1, select("#", ...) do
      output = output .. tostring(select(i, ...))
    end
    return io.stdout, nil, nil
  end

  init.cmd_tree(d)

  io.write = old_write

  -- Should have > marker for current message
  assert(output:match(">%s+3 A: Lua is a scripting"), "should mark current message with >")

  -- Should have * markers for ancestors
  assert(output:match("%*%s+0 U: Hello"), "should mark ancestor with *")

  db.close(d)
end
test_tree_current_marker()

-- Test: empty db handling
local function test_empty_db()
  db_counter = db_counter + 1
  local db_path = fs.join(TEST_TMPDIR, "branch_empty_" .. tostring(db_counter) .. ".db")
  local d = db.open(db_path)

  assert(#db.get_root_messages(d) == 0, "empty db should have no roots")
  assert(#db.get_leaf_messages(d) == 0, "empty db should have no leaves")
  assert(#db.get_children(d, "nonexistent") == 0, "nonexistent parent should have no children")

  db.close(d)
end
test_empty_db()

-- Test: linear conversation (no branches)
local function test_linear_tree()
  db_counter = db_counter + 1
  local db_path = fs.join(TEST_TMPDIR, "branch_linear_" .. tostring(db_counter) .. ".db")
  local d = db.open(db_path)
  local init = require("ah.init")

  local msg1 = db.create_message(d, "user")
  db.add_content_block(d, msg1.id, "text", {content = "Hello"})
  local msg2 = db.create_message(d, "assistant", msg1.id)
  db.add_content_block(d, msg2.id, "text", {content = "Hi"})
  local msg3 = db.create_message(d, "user", msg2.id)
  db.add_content_block(d, msg3.id, "text", {content = "Thanks"})

  -- Should have 1 root, 1 leaf
  assert(#db.get_root_messages(d) == 1, "linear tree should have 1 root")
  assert(#db.get_leaf_messages(d) == 1, "linear tree should have 1 leaf")

  -- Tree should not have branch connectors (├ or │)
  local old_write = io.write
  local output = ""
  io.write = function(...: any): FILE, string, integer
    for i = 1, select("#", ...) do
      output = output .. tostring(select(i, ...))
    end
    return io.stdout, nil, nil
  end

  init.cmd_tree(d)
  io.write = old_write

  -- Linear tree uses └─ but not ├─ (no sibling branches)
  assert(not output:match("├"), "linear tree should not have sibling connector")

  db.close(d)
end
test_linear_tree()

print("all branch tests passed")
