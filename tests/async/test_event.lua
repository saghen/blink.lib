local MiniTest = require('mini.test')
local expect = MiniTest.expect
local eq = expect.equality

package.loaded['blink.lib.async'] = nil
package.loaded['blink.lib.async.event'] = nil
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
-- Basic operations
-- ==============================================================

T['basic'] = MiniTest.new_set()

T['basic']['new event is not set'] = function()
  local e = async.event()
  eq(e:is_set(), false)
end

T['basic']['set() marks the event as set'] = function()
  local e = async.event()
  e:set()
  eq(e:is_set(), true)
end

T['basic']['set() is idempotent'] = function()
  local e = async.event()
  e:set()
  e:set()
  e:set()
  eq(e:is_set(), true)
end

T['basic']['wait() returns immediately when already set'] = function()
  local e = async.event()
  e:set()
  -- If wait() blocks forever this test times out; should resolve synchronously
  async.run(function() e:wait() end):wait(100)
end

T['basic']['wait() blocks until set'] = function()
  local e = async.event()
  local order = {}

  async
    .run(function()
      local waiter = async.run(function()
        e:wait()
        table.insert(order, 'after_wait')
      end)

      sleep(10)
      table.insert(order, 'before_set')
      e:set()

      await(waiter)
    end)
    :wait(200)

  eq(order, { 'before_set', 'after_wait' })
end

T['basic']['clear() on new event is a no-op'] = function()
  local e = async.event()
  e:clear()
  eq(e:is_set(), false)
end

T['basic']['clear() unsets the event'] = function()
  local e = async.event()
  e:set()
  eq(e:is_set(), true)
  e:clear()
  eq(e:is_set(), false)
end

T['basic']['clear() is idempotent'] = function()
  local e = async.event()
  e:set()
  e:clear()
  e:clear()
  e:clear()
  eq(e:is_set(), false)
end

T['basic']['wait() blocks after clear()'] = function()
  local e = async.event()
  e:set()
  e:clear()

  local order = {}

  async
    .run(function()
      local waiter = async.run(function()
        e:wait()
        table.insert(order, 'after_wait')
      end)

      sleep(10)
      table.insert(order, 'before_set')
      e:set()

      await(waiter)
    end)
    :wait(200)

  eq(order, { 'before_set', 'after_wait' })
end

T['basic']['set()/clear()/set() cycle works'] = function()
  local e = async.event()
  e:set()
  eq(e:is_set(), true)
  e:clear()
  eq(e:is_set(), false)
  e:set()
  eq(e:is_set(), true)
end

-- ==============================================================
-- Multiple waiters
-- ==============================================================

T['waiters'] = MiniTest.new_set()

T['waiters']['all waiters are woken when event is set'] = function()
  local e = async.event()
  local woken = {}

  async
    .run(function()
      local tasks = {}
      for i = 1, 5 do
        tasks[i] = async.run(function()
          e:wait()
          table.insert(woken, i)
        end)
      end

      sleep(10) -- let all tasks block on wait()
      e:set()

      for _, t in ipairs(tasks) do
        await(t)
      end
    end)
    :wait(200)

  table.sort(woken)
  eq(woken, { 1, 2, 3, 4, 5 })
end

T['waiters']['waiters are woken in registration order'] = function()
  local e = async.event()
  local order = {}

  async
    .run(function()
      -- stagger registration so order is deterministic
      local t1 = async.run(function()
        e:wait()
        table.insert(order, 1)
      end)
      local t2 = async.run(function()
        sleep(1)
        e:wait()
        table.insert(order, 2)
      end)
      local t3 = async.run(function()
        sleep(2)
        e:wait()
        table.insert(order, 3)
      end)

      sleep(10)
      e:set()

      await(t1)
      await(t2)
      await(t3)
    end)
    :wait(200)

  eq(order, { 1, 2, 3 })
end

T['waiters']['new waiter after set returns immediately'] = function()
  local e = async.event()
  e:set()

  local ran = false
  async
    .run(function()
      e:wait()
      ran = true
    end)
    :wait(100)

  eq(ran, true)
end

T['waiters']['clear() does not wake existing waiters'] = function()
  local e = async.event()
  local woken = false

  async
    .run(function()
      local waiter = async.run(function()
        e:wait()
        woken = true
      end)

      sleep(10)
      e:clear() -- should not wake the waiter
      sleep(10)
      eq(woken, false)

      e:set()
      await(waiter)
    end)
    :wait(200)

  eq(woken, true)
end

T['waiters']['waiters registered after clear() block until next set()'] = function()
  local e = async.event()
  e:set()
  e:clear()

  local order = {}

  async
    .run(function()
      local waiter = async.run(function()
        e:wait()
        table.insert(order, 'after_wait')
      end)

      sleep(10)
      table.insert(order, 'before_set')
      e:set()

      await(waiter)
    end)
    :wait(200)

  eq(order, { 'before_set', 'after_wait' })
end

-- ==============================================================
-- Interaction with future cancellation
-- ==============================================================

T['cancel'] = MiniTest.new_set()

T['cancel']['closing a waiting future does not block set()'] = function()
  local e = async.event()
  local other_woken = false

  async
    .run(function()
      local t1 = async.run(function() e:wait() end)
      async.run(function()
        e:wait()
        other_woken = true
      end)
      t1:close()
      e:set()
    end)
    :wait(200)

  eq(other_woken, true)
end

return T
