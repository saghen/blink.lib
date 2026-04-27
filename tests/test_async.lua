--- @diagnostic disable: global-in-non-module

local MiniTest = require('mini.test')
local expect = MiniTest.expect
local eq = expect.equality

package.loaded['blink.lib.async'] = nil
local async = require('blink.lib.async')
local await = async.await

local T = MiniTest.new_set()

--- Helper: expect a task to fail with a pattern
local function expect_err(task, pat, timeout)
  local ok, err = task:pwait(timeout or 100)
  if ok then error('Expected task to error, but it completed successfully', 2) end
  if not tostring(err):match(pat) then error('Unexpected error: ' .. tostring(err), 2) end
  return err
end

--- @async
local function eternity()
  async.wrap(function(_callback)
    -- Never call callback
  end)
end

local function sleep(ms)
  async.wrap(function(callback) vim.defer_fn(callback, ms) end)
end

-- ==============================================================
-- Basic operations
-- ==============================================================

T['basic'] = MiniTest.new_set()

T['basic']['error on sync wait'] = function()
  local task = async.run(function() error('SYNC ERR') end)
  expect_err(task, 'SYNC ERR')
end

T['basic']['can await a task'] = function()
  local a = async
    .run(function()
      return await(async.run(function()
        sleep(1)
        return 'JJ'
      end))
    end)
    :wait(100)

  eq(a, 'JJ')
end

T['basic']['can flatten a task'] = function()
  local a = async
    .run(function()
      return async.run(function()
        sleep(1)
        return 'JJ'
      end)
    end)
    :wait(100)

  eq(a, 'JJ')
end

T['basic']['can wait on an empty task'] = function()
  local did_cb = false
  local a = 1

  local task = async.run(function() a = a + 1 end)

  task:wait(function() did_cb = true end)
  task:wait(100)

  eq(a, 2)
  eq(did_cb, true)
end

T['basic']['handles tasks that complete with a value'] = function()
  local task = async.run(function()
    sleep(1)
    return 42
  end)

  eq(task:wait(100), 42)
end

T['basic']['handles tasks that complete with multiple values'] = function()
  local task = async.run(function()
    sleep(1)
    return nil, 1
  end)

  local r1, r2 = task:wait(100)
  vim.print(r1, r2)
  eq(r1, nil)
  eq(r2, 1)
end

-- TODO:
-- T['basic']['does not need new stack frame for non-deferred continuations'] = function()
--   --- @async
--   local function deep(n)
--     if n == 0 then return 'done' end
--     async.wrap(function(cb) cb() end)
--     return deep(n - 1)
--   end
--
--   local res = async.run(function() return deep(10000) end):wait(1000)
--   vim.print(res, 'res')
--   eq(res, 'done')
-- end

-- ==============================================================
-- async cancellation
-- ==============================================================

T['cancel'] = MiniTest.new_set()

T['cancel']['can cancel tasks'] = function()
  local task = async.run(eternity)
  task:cancel()
  expect_err(task, 'cancelled')
end

T['cancel']['can cancel task waiting on a wrapped callback'] = function()
  local task = async.run(function()
    async.wrap(function(_callback)
      -- never calls the callback
    end)
  end)

  task:cancel()
  expect_err(task, 'cancelled')
end

T['cancel']['wrap callback cancellation hook is invoked'] = function()
  local hook_called = false
  local task = async.run(function()
    async.wrap(function(_callback)
      return function() hook_called = true end
    end)
  end)

  task:cancel()
  expect_err(task, 'cancelled')
  eq(hook_called, true)
end

T['cancel']['can cancel nested task awaiting child'] = function()
  local child
  local task = async.run(function()
    child = async.run(eternity)
    await(child)
  end)

  task:cancel()

  expect_err(task, 'cancelled')
  expect_err(child, 'cancelled')
end

T['cancel']['can timeout tasks'] = function()
  local task = async.run(eternity)
  expect_err(task, 'timeout', 10)
  task:cancel()
  expect_err(task, 'cancelled')
end

T['cancel']['cancels awaited detached task'] = function()
  local task1 = async.run(eternity)
  task1:cancel()

  local task2 = async.run(function() await(task1) end)

  expect_err(task2, 'cancelled')
end

T['cancel']['cancelling child does not cancel parent'] = function()
  async.run(function() async.run(eternity):cancel() end):wait(100)
end

-- ==============================================================
-- Error handling
-- ==============================================================

T['errors'] = MiniTest.new_set()

T['errors']['handles tasks that error after an await'] = function()
  local task = async.run(function()
    sleep(1)
    error('GOT HERE')
  end)

  expect_err(task, 'GOT HERE')
end

T['errors']['handles errors in wrapped callback functions'] = function()
  local task = async.run(function()
    async.wrap(function(_callback) error('ERROR') end)
  end)
  expect_err(task, 'ERROR')
end

T['errors']['can pcall errors from wrapped functions'] = function()
  local task = async.run(function()
    return pcall(function()
      async.wrap(function(_callback) error('ERROR') end)
    end)
  end)

  local ok, msg = task:wait(100)
  eq(ok, false)
  assert(msg:match('ERROR'), 'Expected ERROR, got: ' .. tostring(msg))
end

T['errors']['handles when a floating child errors'] = function()
  local parent = async.run(function()
    local _child = async.run(function()
      sleep(5)
      error('CHILD ERROR')
    end)
  end)

  expect_err(parent, 'CHILD ERROR')
end

T['errors']['parent error takes precedence over child error'] = function()
  local parent = async.run(function()
    local _child = async.run(function()
      sleep(5)
      error('CHILD ERROR')
    end)
    error('PARENT ERROR')
  end)

  expect_err(parent, 'PARENT ERROR')
end

T['errors']['child error during parent finalization is handled'] = function()
  local parent = async.run(function()
    local _child = async.run(function()
      sleep(5)
      error('CHILD_ERROR')
    end)
    -- Parent completes immediately, starting finalization
  end)

  expect_err(parent, 'CHILD_ERROR')
end

-- ==============================================================
-- Child task management
-- ==============================================================

T['children'] = MiniTest.new_set()

T['children']['waits for child tasks when parent settles'] = function()
  -- This is explicitly noted as a difference from async.nvim:
  -- unawaited children are cancelled when parent settles.
  local child
  local parent = async.run(function()
    child = async.run(function() sleep(1) end)
    -- parent completes immediately without awaiting child
  end)

  parent:wait(100)
  eq(child:status(), 'resolved')
end

T['children']['awaited children complete before parent'] = function()
  local child
  local parent = async.run(function()
    child = async.run(function()
      sleep(1)
      return 'child done'
    end)
    return await(child)
  end)

  eq(parent:wait(100), 'child done')
end

T['children']['cancelling parent cancels suspended child'] = function()
  local child
  local parent = async.run(function()
    child = async.run(function()
      while true do
        sleep(1)
      end
    end)
    sleep(10)
  end)

  parent:cancel()
  expect_err(parent, 'cancelled')
  expect_err(child, 'cancelled')
end

T['children']['automatically awaits child tasks'] = function()
  local child1, child2
  local main = async.run(function()
    child1 = async.run(function() sleep(10) end)
    child2 = async.run(function() sleep(10) end)
  end)

  main:wait(100)
  eq(child1:status(), 'resolved')
  eq(child2:status(), 'resolved')
end

T['children']['children finishing before parent does not fail parent'] = function()
  local child1, child2
  local main = async.run(function()
    child1 = async.run(function() sleep(5) end)
    child2 = async.run(function() sleep(5) end)
    sleep(20)
  end)

  main:wait(100)
  eq(child1:status(), 'resolved')
  eq(child2:status(), 'resolved')
end

-- ==============================================================
-- Resolution flattening
-- ==============================================================

T['resolve'] = MiniTest.new_set()

T['resolve']['resolving with a task flattens the result'] = function()
  local inner = async.run(function()
    sleep(1)
    return 'inner value'
  end)

  local outer = async.run(function() return inner end)

  eq(outer:wait(100), 'inner value')
end

-- ==============================================================
-- Wait variants
-- ==============================================================

T['wait'] = MiniTest.new_set()

T['wait']['non-blocking callback form receives ok/value'] = function()
  local got_err, got_val
  local task = async.run(function()
    sleep(1)
    return 'hello'
  end)

  task:wait(function(err, val)
    got_err = err
    got_val = val
  end)

  task:wait(100)

  eq(got_err, nil)
  eq(got_val, 'hello')
end

T['wait']['non-blocking callback form receives error'] = function()
  local got_err, got_val
  local task = async.run(function()
    sleep(1)
    error('boom')
  end)

  task:wait(function(err, val)
    got_err = err
    got_val = val
  end)

  task:pwait(100)

  eq(got_val, nil)
  assert(tostring(got_err):match('boom'), 'Expected "boom", got: ' .. tostring(got_val))
end

-- ==============================================================
-- async.all / async.any
-- ==============================================================

T['all'] = MiniTest.new_set()

T['all']['returns results of all tasks'] = function()
  local result = async
    .run(function()
      return async.all({
        async.run(function()
          sleep(1)
          return 1
        end),
        async.run(function()
          sleep(2)
          return 2
        end),
        async.run(function()
          sleep(3)
          return 3
        end),
      })
    end)
    :wait(100)

  eq(result, { 1, 2, 3 })
end

T['all']['errors if any task rejects'] = function()
  local task = async.run(function()
    return async.all({
      async.run(function()
        sleep(1)
        return 1
      end),
      async.run(function()
        sleep(2)
        error('BOOM')
      end),
      async.run(function()
        sleep(3)
        return 3
      end),
    })
  end)

  expect_err(task, 'BOOM')
end

T['any'] = MiniTest.new_set()

T['any']['returns the first task to resolve'] = function()
  local result = async
    .run(function()
      return async.any({
        async.run(function()
          sleep(50)
          return 'slow'
        end),
        async.run(function()
          sleep(1)
          return 'fast'
        end),
      })
    end)
    :wait(100)

  eq(result, 'fast')
end

T['any']['errors if all tasks reject'] = function()
  local task = async.run(function()
    return async.any({
      async.run(function()
        sleep(1)
        error('a')
      end),
      async.run(function()
        sleep(2)
        error('b')
      end),
    })
  end)

  expect_err(task, 'all tasks rejected')
end

-- ==============================================================
-- Edge cases
-- ==============================================================

T['edge'] = MiniTest.new_set()

T['edge']['callback called multiple times is handled gracefully'] = function()
  local call_count = 0
  local results = {}

  local task = async.run(function()
    local result = async.wrap(function(callback)
      call_count = call_count + 1
      callback(nil, 'FIRST_CALL')

      -- Try calling again (should be ignored)
      vim.schedule(function()
        call_count = call_count + 1
        callback(nil, 'SECOND_CALL')
      end)
    end)

    table.insert(results, result)
    return result
  end)

  local final_result = task:wait(100)

  eq(final_result, 'FIRST_CALL')
  eq(#results, 1)
  eq(results[1], 'FIRST_CALL')

  -- Wait for the second callback to potentially fire
  async.run(function() sleep(20) end):wait(100)

  -- Both callbacks should have been called
  eq(call_count, 2)

  -- But only the first should have been processed
  eq(#results, 1)
end

T['edge']['status reflects lifecycle'] = function()
  local task = async.run(eternity)
  eq(task:status(), 'pending')
  task:cancel()
  eq(task:status(), 'cancelled')
end

T['edge']['resolving task with itself rejects'] = function()
  local task
  task = async.run(function()
    sleep(1)
    return task
  end)

  expect_err(task, 'task resolved with itself')
end

return T
