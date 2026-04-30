local MiniTest = require('mini.test')
local expect = MiniTest.expect
local eq = expect.equality

package.loaded['blink.lib.async'] = nil
package.loaded['blink.lib.async.mutex'] = nil
package.loaded['blink.lib.async.wait_queue'] = nil
local async = require('blink.lib.async')
local await = async.await

local T = MiniTest.new_set()

local function sleep(ms)
  async.await(function(callback) vim.defer_fn(callback, ms) end)
end

-- ==============================================================
-- Basic operations
-- ==============================================================

T['basic'] = MiniTest.new_set()

T['basic']['new mutex is unlocked'] = function()
  local m = async.mutex()
  eq(m:available(), true)
end

T['basic']['available returns false when locked'] = function()
  async
    .run(function()
      local m = async.mutex()
      m:lock()
      eq(m:available(), false)
    end)
    :wait(100)
end

T['basic']['available returns true after unlock'] = function()
  async
    .run(function()
      local m = async.mutex()
      m:lock()
      eq(m:available(), false)
      m:unlock()
      eq(m:available(), true)
    end)
    :wait(100)
end

T['basic']['is_held_by_current_task returns true when held by caller'] = function()
  async
    .run(function()
      local m = async.mutex()
      eq(m:is_held_by_current_task(), false)
      m:lock()
      eq(m:is_held_by_current_task(), true)
      m:unlock()
      eq(m:is_held_by_current_task(), false)
    end)
    :wait(100)
end

-- ==============================================================
-- with() helper
-- ==============================================================

T['with'] = MiniTest.new_set()

T['with']['executes function and releases lock'] = function()
  async
    .run(function()
      local m = async.mutex()
      local ran = false
      m:with(function() ran = true end)
      eq(ran, true)
      eq(m:available(), true)
    end)
    :wait(100)
end

T['with']['releases lock even when function errors'] = function()
  async
    .run(function()
      local m = async.mutex()
      local ok, err = pcall(function()
        m:with(function() error('INNER_ERROR') end)
      end)
      eq(ok, false)
      assert(tostring(err):match('INNER_ERROR'), 'Expected INNER_ERROR, got: ' .. tostring(err))
      -- lock must be released even after error
      eq(m:available(), true)
    end)
    :wait(100)
end

T['with']['returns values from function'] = function()
  async
    .run(function()
      local m = async.mutex()
      local a, b = m:with(function() return 1, 2 end)
      eq(a, 1)
      eq(b, 2)
    end)
    :wait(100)
end

T['with']['passes extra arguments to function'] = function()
  async
    .run(function()
      local m = async.mutex()
      local got_a, got_b
      m:with(function(a, b)
        got_a = a
        got_b = b
      end, 'hello', 42)
      eq(got_a, 'hello')
      eq(got_b, 42)
    end)
    :wait(100)
end

-- ==============================================================
-- try_lock
-- ==============================================================

T['try_lock'] = MiniTest.new_set()

T['try_lock']['succeeds when mutex is unlocked'] = function()
  async
    .run(function()
      local m = async.mutex()
      m:try_lock()
      eq(m:available(), false)
      eq(m:is_held_by_current_task(), true)
      m:unlock()
    end)
    :wait(100)
end

T['try_lock']['errors when mutex is already locked'] = function()
  async
    .run(function()
      local m = async.mutex()
      m:lock()
      local ok, err = pcall(function() m:try_lock() end)
      eq(ok, false)
      assert(tostring(err):match('try_lock'), 'Expected try_lock error, got: ' .. tostring(err))
      m:unlock()
    end)
    :wait(100)
end

-- ==============================================================
-- Mutual exclusion
-- ==============================================================

T['mutex'] = MiniTest.new_set()

T['mutex']['only one task runs critical section at a time'] = function()
  local m = async.mutex()
  local inside = 0
  local max_inside = 0
  local races = 0

  async
    .run(function()
      local tasks = {}
      for i = 1, 5 do
        tasks[i] = async.run(function()
          m:lock()
          inside = inside + 1
          if inside > max_inside then max_inside = inside end
          if inside > 1 then races = races + 1 end
          sleep(5)
          inside = inside - 1
          m:unlock()
        end)
      end
    end)
    :wait(500)

  eq(max_inside, 1)
  eq(races, 0)
end

T['mutex']['second lock blocks until first unlocks'] = function()
  local m = async.mutex()
  local order = {}

  async
    .run(function()
      local task_a = async.run(function()
        m:lock()
        table.insert(order, 'A:in')
        sleep(20)
        table.insert(order, 'A:out')
        m:unlock()
      end)

      local task_b = async.run(function()
        sleep(1) -- ensure A acquires first
        m:lock()
        table.insert(order, 'B:in')
        m:unlock()
      end)

      await(task_a)
      await(task_b)
    end)
    :wait(200)

  eq(order, { 'A:in', 'A:out', 'B:in' })
end

T['mutex']['waiters are woken in FIFO order'] = function()
  local m = async.mutex()
  local order = {}

  async
    .run(function()
      m:lock()

      local t1 = async.run(function()
        m:lock()
        table.insert(order, 1)
        m:unlock()
      end)
      local t2 = async.run(function()
        sleep(1)
        m:lock()
        table.insert(order, 2)
        m:unlock()
      end)
      local t3 = async.run(function()
        sleep(2)
        m:lock()
        table.insert(order, 3)
        m:unlock()
      end)

      sleep(10) -- let all three queue up
      m:unlock()

      await(t1)
      await(t2)
      await(t3)
    end)
    :wait(500)

  eq(order, { 1, 2, 3 })
end

T['mutex']['with() provides mutual exclusion'] = function()
  local m = async.mutex()
  local counter = 0
  local races = 0

  async
    .run(function()
      local tasks = {}
      for i = 1, 10 do
        tasks[i] = async.run(function()
          m:with(function()
            local snapshot = counter
            sleep(1)
            if counter ~= snapshot then races = races + 1 end
            counter = counter + 1
          end)
        end)
      end
      for _, t in ipairs(tasks) do
        await(t)
      end
    end)
    :wait(500)

  eq(counter, 10)
  eq(races, 0)
end

return T
