local MiniTest = require('mini.test')
local expect = MiniTest.expect
local eq = expect.equality

package.loaded['blink.lib.async'] = nil
package.loaded['blink.lib.async.channel'] = nil
package.loaded['blink.lib.async.wait_queue'] = nil
local async = require('blink.lib.async')
local await = async.await

local T = MiniTest.new_set()

local function sleep(ms)
  async.await(function(callback) vim.defer_fn(callback, ms) end)
end

local function expect_err(future, pat, timeout)
  local ok, err = future:pwait(timeout or 100)
  if ok then error('Expected future to error, but it completed successfully', 2) end
  if not tostring(err):match(pat) then error('Unexpected error: ' .. tostring(err), 2) end
  return err
end

-- ==============================================================
-- Basic send/receive
-- ==============================================================

T['basic'] = MiniTest.new_set()

-- Receiver arrives first, then sender sends.
T['basic']['receiver waits for sender'] = function()
  local ch = async.channel(1)
  local received

  async
    .run(function()
      local recv = async.run(function()
        local ok, val = ch:receive()
        eq(ok, true)
        received = val
      end)
      ch:send('hello')
      await(recv)
    end)
    :wait(100)

  eq(received, 'hello')
end

-- Sender pushes into the buffer first, then receiver drains it.
T['basic']['sender fills buffer before receiver arrives'] = function()
  local ch = async.channel(1)
  local received

  async
    .run(function()
      ch:send('world')
      local ok, val = ch:receive()
      eq(ok, true)
      received = val
    end)
    :wait(100)

  eq(received, 'world')
end

-- Values are delivered FIFO.
T['basic']['values arrive in FIFO order'] = function()
  local ch = async.channel(3)
  local results = {}

  async
    .run(function()
      ch:send(1)
      ch:send(2)
      ch:send(3)
      for _ = 1, 3 do
        local ok, v = ch:receive()
        eq(ok, true)
        table.insert(results, v)
      end
    end)
    :wait(100)

  eq(results, { 1, 2, 3 })
end

-- ==============================================================
-- Bounded channel capacity
-- BUG: #self._buffer > self._capacity uses > instead of >=,
--      so a capacity=1 channel can hold 2 items before blocking.
-- ==============================================================

T['bounded'] = MiniTest.new_set()

-- A capacity-1 channel must block the second sender, not the third.
T['bounded']['sender blocks when buffer is at capacity'] = function()
  local ch = async.channel(1)
  local order = {}

  async
    .run(function()
      -- First send should not block (buffer empty → under capacity)
      ch:send('a')
      table.insert(order, 'sent-a')

      -- Second send must block because buffer is already at capacity (1 item)
      local sender = async.run(function()
        ch:send('b')
        table.insert(order, 'sent-b')
      end)

      table.insert(order, 'before-receive')
      local ok, v = ch:receive()
      eq(ok, true)
      eq(v, 'a')

      await(sender) -- sender should unblock now
    end)
    :wait(200)

  -- sent-b must come *after* the receive freed space
  eq(order, { 'sent-a', 'before-receive', 'sent-b' })
end

-- With capacity=2, exactly 2 items should fit before the third blocks.
T['bounded']['capacity=2 allows exactly 2 items'] = function()
  local ch = async.channel(2)
  local blocked = true

  async
    .run(function()
      ch:send(1)
      ch:send(2)

      -- Third send must block
      async.run(function()
        ch:send(3)
        blocked = false
      end)

      eq(blocked, true)
      ch:receive() -- free one slot
      eq(blocked, false)
    end)
    :wait(200)
end

-- Sender unblocks and its value is eventually received.
T['bounded']['sender unblocks after receiver consumes'] = function()
  local ch = async.channel(1)
  local sent_val = nil

  async
    .run(function()
      ch:send('first') -- fills buffer

      local sender = async.run(function()
        ch:send('second') -- blocks
        sent_val = 'second'
      end)

      local ok1, v1 = ch:receive() -- drains, wakes sender
      eq(ok1, true)
      eq(v1, 'first')

      await(sender)

      local ok2, v2 = ch:receive()
      eq(ok2, true)
      eq(v2, 'second')
    end)
    :wait(200)

  eq(sent_val, 'second')
end

-- ==============================================================
-- Rendezvous channel (capacity = 0)
-- ==============================================================

T['rendezvous'] = MiniTest.new_set()

-- Sender arrives first; it must block until a receiver shows up.
T['rendezvous']['sender blocks until receiver is ready'] = function()
  local ch = async.channel(0)
  local order = {}

  async
    .run(function()
      local sender = async.run(function()
        table.insert(order, 'send-start')
        ch:send('sync')
        table.insert(order, 'send-done')
      end)

      sleep(10) -- sender should be blocked

      table.insert(order, 'before-receive')
      local ok, v = ch:receive()
      eq(ok, true)
      eq(v, 'sync')
      table.insert(order, 'received')

      await(sender)
    end)
    :wait(200)

  -- send-done must come after before-receive (they rendezvous)
  eq(order, { 'send-start', 'before-receive', 'send-done', 'received' })
end

-- Receiver arrives first; it must block until a sender arrives.
T['rendezvous']['receiver blocks until sender sends'] = function()
  local ch = async.channel(0)
  local order = {}

  async
    .run(function()
      local receiver = async.run(function()
        table.insert(order, 'recv-start')
        local ok, v = ch:receive()
        eq(ok, true)
        eq(v, 'ping')
        table.insert(order, 'recv-done')
      end)

      sleep(10) -- receiver should be blocked

      table.insert(order, 'before-send')
      ch:send('ping')

      await(receiver)
    end)
    :wait(200)

  eq(order, { 'recv-start', 'before-send', 'recv-done' })
end

-- ==============================================================
-- Channel close
-- ==============================================================

T['close'] = MiniTest.new_set()

-- Calling close() must not crash (syntax-error bug).
T['close']['close does not crash'] = function()
  local ch = async.channel(1)
  ch:close()
end

-- After closing an empty channel, receive must return false immediately.
T['close']['receive on closed empty channel returns false'] = function()
  local ch = async.channel(1)
  ch:close()

  async
    .run(function()
      local ok = ch:receive()
      eq(ok, false)
    end)
    :wait(100)
end

-- Items already in the buffer must still be readable after close.
T['close']['buffered items are still readable after close'] = function()
  local ch = async.channel(2)
  local results = {}

  async
    .run(function()
      ch:send('x')
      ch:send('y')
      ch:close()

      local ok1, v1 = ch:receive()
      local ok2, v2 = ch:receive()
      local ok3 = ch:receive()

      table.insert(results, { ok1, v1 })
      table.insert(results, { ok2, v2 })
      table.insert(results, { ok3 })
    end)
    :wait(100)

  eq(results[1], { true, 'x' })
  eq(results[2], { true, 'y' })
  eq(results[3], { false })
end

-- A receiver blocked on an empty channel must wake up when the channel closes.
-- BUG: close() does not call waiting receiver callbacks.
T['close']['close wakes blocked receiver'] = function()
  local ch = async.channel(1)
  local ok_result

  async
    .run(function()
      local receiver = async.run(function()
        local ok = ch:receive() -- blocks; channel is empty
        ok_result = ok
      end)

      sleep(5) -- let receiver block

      ch:close() -- must wake the receiver

      await(receiver)
    end)
    :wait(200)

  eq(ok_result, false)
end

-- A sender blocked waiting for buffer space must error when the channel closes.
-- (This also exercises the for-loop syntax in close().)
T['close']['close wakes blocked sender with error'] = function()
  local ch = async.channel(0)

  -- Fill the conceptual slot so sender blocks, then close.
  local future = async.run(function()
    -- For rendezvous: no receiver, sender must block.
    ch:send('value')
  end)
  ch:close()

  expect_err(future, 'send on closed channel', 200)
end

-- Sending on a closed channel must raise an error synchronously.
T['close']['send on closed channel errors'] = function()
  local ch = async.channel(1)
  ch:close()

  local ok, err = pcall(function() ch:send('late') end)
  eq(ok, false)
  assert(tostring(err):match('send on closed channel'), tostring(err))
end

-- close() is idempotent (calling it twice must not crash).
T['close']['close is idempotent'] = function()
  local ch = async.channel(1)
  ch:close()
  ch:close() -- should not raise
end

-- ==============================================================
-- iter()
-- ==============================================================

T['iter'] = MiniTest.new_set()

-- iter() must yield every sent value and stop when channel is closed.
T['iter']['iterates values until closed'] = function()
  local ch = async.channel(3)
  local results = {}

  async
    .run(function()
      async.run(function()
        ch:send(10)
        ch:send(20)
        ch:send(30)
        ch:close()
      end)

      for v in ch:iter() do
        table.insert(results, v)
      end
    end)
    :wait(200)

  eq(results, { 10, 20, 30 })
end

-- iter() interleaved with a slow producer.
T['iter']['iter works with async producer'] = function()
  local ch = async.channel(1)
  local results = {}

  async
    .run(function()
      local producer = async.run(function()
        for i = 1, 3 do
          sleep(5)
          ch:send(i)
        end
        ch:close()
      end)
      producer:detach()

      for v in ch:iter() do
        table.insert(results, v)
      end
    end)
    :wait(500)

  eq(results, { 1, 2, 3 })
end

-- ==============================================================
-- Task close
-- ==============================================================

T['task close'] = MiniTest.new_set()

T['task close']['closing a task cancels receiver'] = function()
  local ch = async.channel(0)

  local ok, val = async
    .run(function()
      async.run(function() ch:receive() end):close()
      async.run(function() ch:send('hello') end)
      return ch:receive()
    end)
    :wait(100)
  vim.print(ok, val)
  eq(ok, true)
  eq(val, 'hello')
end

T['task close']['closing a task cancels sender'] = function()
  local ch = async.channel(0)

  local ok, val = async
    .run(function()
      async.run(function() ch:send('hello') end):close()
      async.run(function() ch:send('world') end)
      return ch:receive()
    end)
    :wait(100)
  eq(ok, true)
  eq(val, 'world')
end

return T
