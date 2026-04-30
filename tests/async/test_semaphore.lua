local MiniTest = require('mini.test')
local expect = MiniTest.expect
local eq = expect.equality

package.loaded['blink.lib.async'] = nil
package.loaded['blink.lib.async.semaphore'] = nil
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
-- Construction
-- ==============================================================

T['new'] = MiniTest.new_set()

T['new']['defaults to 1 permit'] = function()
  local sem = async.semaphore()
  eq(sem.available, 1)
  eq(sem.max, 1)
end

T['new']['creates with specified permits'] = function()
  local sem = async.semaphore(5)
  eq(sem.available, 5)
  eq(sem.max, 5)
end

-- ==============================================================
-- acquire / release
-- ==============================================================

T['acquire'] = MiniTest.new_set()

T['acquire']['decrements available count'] = function()
  local sem = async.semaphore(3)
  async
    .run(function()
      sem:acquire()
      eq(sem.available, 2)
      sem:acquire()
      eq(sem.available, 1)
      sem:acquire()
      eq(sem.available, 0)
    end)
    :wait(100)
end

T['acquire']['available is 0 when fully acquired'] = function()
  local sem = async.semaphore(2)
  async
    .run(function()
      sem:acquire()
      sem:acquire()
      eq(sem.available, 0)
    end)
    :wait(100)
end

T['release'] = MiniTest.new_set()

T['release']['increments available count'] = function()
  local sem = async.semaphore(2)
  async
    .run(function()
      sem:acquire()
      sem:acquire()
      eq(sem.available, 0)
      sem:release()
      eq(sem.available, 1)
      sem:release()
      eq(sem.available, 2)
    end)
    :wait(100)
end

T['release']['errors when exceeding max permits'] = function()
  local sem = async.semaphore(1)
  local ok, err = pcall(function() sem:release() end)
  eq(ok, false)
  assert(tostring(err):match('greater than max'), 'Expected "greater than max", got: ' .. tostring(err))
end

-- ==============================================================
-- Blocking behaviour
-- ==============================================================

T['blocking'] = MiniTest.new_set()

T['blocking']['second acquire blocks when no permits available'] = function()
  local sem = async.semaphore(1)
  local order = {}

  async
    .run(function()
      local task_a = async.run(function()
        sem:acquire()
        table.insert(order, 'A:in')
        sleep(20)
        table.insert(order, 'A:out')
        sem:release()
      end)

      local task_b = async.run(function()
        sleep(1) -- ensure A acquires first
        sem:acquire()
        table.insert(order, 'B:in')
        sem:release()
      end)

      await(task_a)
      await(task_b)
    end)
    :wait(200)

  eq(order, { 'A:in', 'A:out', 'B:in' })
end

T['blocking']['n permits allow n concurrent acquires'] = function()
  local sem = async.semaphore(3)
  local inside = 0
  local max_inside = 0

  async
    .run(function()
      local tasks = {}
      for i = 1, 5 do
        tasks[i] = async.run(function()
          sem:acquire()
          inside = inside + 1
          if inside > max_inside then max_inside = inside end
          sleep(10)
          inside = inside - 1
          sem:release()
        end)
      end
      for _, t in ipairs(tasks) do
        await(t)
      end
    end)
    :wait(500)

  assert(max_inside <= 3, 'Expected max_inside <= 3, got: ' .. tostring(max_inside))
  assert(max_inside >= 2, 'Expected max_inside >= 2, got: ' .. tostring(max_inside))
end

T['blocking']['waiters are woken in FIFO order'] = function()
  local sem = async.semaphore(1)
  local order = {}

  async
    .run(function()
      sem:acquire()

      local t1 = async.run(function()
        sem:acquire()
        table.insert(order, 1)
        sem:release()
      end)
      local t2 = async.run(function()
        sleep(1)
        sem:acquire()
        table.insert(order, 2)
        sem:release()
      end)
      local t3 = async.run(function()
        sleep(2)
        sem:acquire()
        table.insert(order, 3)
        sem:release()
      end)

      sleep(10) -- let all three queue up
      sem:release()

      await(t1)
      await(t2)
      await(t3)
    end)
    :wait(500)

  eq(order, { 1, 2, 3 })
end

T['blocking']['mutual exclusion: critical section runs serially'] = function()
  local sem = async.semaphore(1)
  local counter = 0
  local races = 0

  async
    .run(function()
      local tasks = {}
      for i = 1, 10 do
        tasks[i] = async.run(function()
          sem:acquire()
          local snapshot = counter
          sleep(1)
          if counter ~= snapshot then races = races + 1 end
          counter = counter + 1
          sem:release()
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

-- ==============================================================
-- with() helper
-- ==============================================================

T['with'] = MiniTest.new_set()

T['with']['executes function and releases permit'] = function()
  local sem = async.semaphore(1)
  local ran = false
  async
    .run(function()
      sem:with(function() ran = true end)
    end)
    :wait(100)
  eq(ran, true)
  eq(sem.available, 1)
end

T['with']['releases permit even when function errors'] = function()
  local sem = async.semaphore(1)
  async
    .run(function()
      local ok, err = pcall(function()
        sem:with(function() error('INNER_ERROR') end)
      end)
      eq(ok, false)
      assert(tostring(err):match('INNER_ERROR'), 'Expected INNER_ERROR, got: ' .. tostring(err))
      eq(sem.available, 1)
    end)
    :wait(100)
end

T['with']['provides mutual exclusion'] = function()
  local sem = async.semaphore(1)
  local counter = 0
  local races = 0

  async
    .run(function()
      local tasks = {}
      for i = 1, 10 do
        tasks[i] = async.run(function()
          sem:with(function()
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

T['with']['runs multiple concurrent tasks up to permit count'] = function()
  local ret = {}
  async
    .run(function()
      local sem = async.semaphore(3)
      local tasks = {}
      for i = 1, 5 do
        tasks[i] = async.run(function()
          sem:with(function()
            ret[#ret + 1] = 'start' .. i
            await(vim.schedule)
            ret[#ret + 1] = 'end' .. i
          end)
        end)
      end
    end)
    :wait()

  expect.equality({
    'start1',
    'start2',
    'start3',
    'end1',
    'start4',
    'end2',
    'start5',
    'end3',
    'end4',
    'end5',
  }, ret)
end

return T
