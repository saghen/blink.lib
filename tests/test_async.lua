--- @diagnostic disable: global-in-non-module

local MiniTest = require('mini.test')
local expect = MiniTest.expect
local eq = expect.equality

package.loaded['blink.lib.async'] = nil
local async = require('blink.lib.async')

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
      return async
        .run(function()
          sleep(1)
          return 'JJ'
        end)
        :await()
    end)
    :wait(100)

  eq(a, 'JJ')
end

T['basic']['can flatten a task'] = function()
  vim.print('uh oh')
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

T['cancel']['cancels nested child tasks'] = function()
  local child
  local task = async.run(function()
    child = async.run(eternity)
    child:await()
  end)

  task:cancel()
  expect_err(task, 'cancelled')
  expect_err(child, 'cancelled')
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

-- ==============================================================
-- Child task management
-- ==============================================================

T['children'] = MiniTest.new_set()

T['children']['cancels unawaited child tasks when parent settles'] = function()
  -- This is explicitly noted as a difference from async.nvim:
  -- unawaited children are cancelled when parent settles.
  local child
  local parent = async.run(function()
    child = async.run(eternity)
    -- parent completes immediately without awaiting child
  end)

  parent:wait(100)
  expect_err(child, 'cancelled')
end

T['children']['awaited children complete before parent'] = function()
  local child
  local parent = async.run(function()
    child = async.run(function()
      sleep(1)
      return 'child done'
    end)
    return child:await()
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

return T
