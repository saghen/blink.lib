local MiniTest = require('mini.test')
local expect = MiniTest.expect
local eq = expect.equality

package.loaded['blink.lib.async'] = nil
local async = require('blink.lib.async')
local await = async.await

local T = MiniTest.new_set()

--- Helper: expect a future to fail with a pattern
local function expect_err(future, pat, timeout)
  local ok, err = future:pwait(timeout or 100)
  if ok then error('Expected future to error, but it completed successfully', 2) end
  if not tostring(err):match(pat) then error('Unexpected error: ' .. tostring(err), 2) end
  return err
end

--- @async
local function eternity()
  async.await(function(_callback)
    -- Never call callback
  end)
end

local function sleep(ms)
  async.await(function(callback) vim.defer_fn(callback, ms) end)
end

-- ==============================================================
-- Basic operations
-- ==============================================================

T['basic'] = MiniTest.new_set()

T['basic']['error on sync wait'] = function()
  local future = async.run(function() error('SYNC ERR') end)
  expect_err(future, 'SYNC ERR')
end

T['basic']['can await a future'] = function()
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

T['basic']['can flatten a future'] = function()
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

T['basic']['can wait on an empty future'] = function()
  local did_cb = false
  local a = 1

  local future = async.run(function() a = a + 1 end)

  future:wait(function() did_cb = true end)
  future:wait(100)

  eq(a, 2)
  eq(did_cb, true)
end

T['basic']['handles futures that complete with a value'] = function()
  local future = async.run(function()
    sleep(1)
    return 42
  end)

  eq(future:wait(100), 42)
end

T['basic']['handles futures that complete with multiple values'] = function()
  local future = async.run(function()
    sleep(1)
    return nil, 1
  end)

  local r1, r2 = future:wait(100)
  eq(r1, nil)
  eq(r2, 1)
end

T['basic']['does not need new stack frame for non-deferred continuations'] = function()
  --- @async
  local function deep(n)
    if n == 0 then return 'done' end
    async.await(function(cb) cb() end)
    return deep(n - 1)
  end

  local res = async.run(function() return deep(10000) end):wait(1000)
  eq(res, 'done')
end

-- ==============================================================
-- async cancellation
-- ==============================================================

T['cancel'] = MiniTest.new_set()

T['cancel']['can cancel futures'] = function()
  local future = async.run(eternity)
  future:close()
  expect_err(future, 'closed')
end

T['cancel']['can cancel future waiting on a wrapped callback'] = function()
  local future = async.run(function()
    async.await(function(_callback)
      -- never calls the callback
    end)
  end)

  future:close()
  expect_err(future, 'closed')
end

T['cancel']['cancellation hook is invoked'] = function()
  local hook_called = false
  local future = async.run(function()
    async.await(function(_callback)
      return function() hook_called = true end
    end)
  end)

  future:close()
  expect_err(future, 'closed')
  eq(hook_called, true)
end

T['cancel']['can cancel nested future awaiting child'] = function()
  local child
  local future = async.run(function()
    child = async.run(eternity)
    await(child)
  end)

  future:close()

  expect_err(future, 'closed')
  expect_err(child, 'closed')
end

T['cancel']['can timeout futures'] = function()
  local future = async.run(eternity)
  expect_err(future, 'timeout', 10)
  future:close()
  expect_err(future, 'closed')
end

T['cancel']['cancels awaited detached future'] = function()
  local future1 = async.run(eternity)
  future1:close()

  local future2 = async.run(function() await(future1) end)

  expect_err(future2, 'closed')
end

T['cancel']['cancelling child does not cancel parent'] = function()
  async.run(function() async.run(eternity):close() end):wait(100)
end

-- TODO: what should we do with the errors? this could silently leak resources
T['cancel']['cancellation hook errors are ignored'] = function()
  local future = async.run(function()
    async.await(function(_callback)
      return function() error('CLEANUP_ERROR') end
    end)
  end)

  future:close()
  expect_err(future, 'closed')
end

-- ==============================================================
-- Error handling
-- ==============================================================

T['errors'] = MiniTest.new_set()

T['errors']['handles futures that error after an await'] = function()
  local future = async.run(function()
    sleep(1)
    error('GOT HERE')
  end)

  expect_err(future, 'GOT HERE')
end

T['errors']['handles errors in wrapped callback functions'] = function()
  local future = async.run(function()
    async.await(function(_callback) error('ERROR') end)
  end)
  expect_err(future, 'ERROR')
end

T['errors']['can pcall errors from wrapped functions'] = function()
  local future = async.run(function()
    return pcall(function()
      async.await(function(_callback) error('ERROR') end)
    end)
  end)

  local ok, msg = future:wait(100)
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

T['errors']['multiple floating children - first error propagates'] = function()
  local parent = async.run(function()
    async.run(function()
      sleep(5)
      error('ERROR_1')
    end)

    async.run(function()
      sleep(10)
      error('ERROR_2')
    end)

    -- parent completes immediately and waits on both children
  end)

  -- First child to reject wins
  expect_err(parent, 'ERROR_1')
end

T['errors']['error in pcall inside async run'] = function()
  local result
  local future = async.run(function()
    local ok, err = pcall(function()
      sleep(1)
      error('INNER_ERROR')
    end)
    result = { ok = ok, err = err }
    return 'RECOVERED'
  end)

  eq(future:wait(100), 'RECOVERED')
  eq(result.ok, false)
  assert(result.err:match('INNER_ERROR'))
end

-- ==============================================================
-- Child future management
-- ==============================================================

T['children'] = MiniTest.new_set()

T['children']['waits for child futures when parent settles'] = function()
  -- This is explicitly noted as a difference from async.nvim:
  -- unawaited children are closed when parent settles.
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

  parent:close()
  expect_err(parent, 'closed')
  expect_err(child, 'closed')
end

T['children']['automatically awaits child futures'] = function()
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

T['children']['cancelling child does not cancel parent'] = function()
  async.run(function() async.run(eternity):close() end):wait(100)
end

T['children']['deeply nested children all close with root'] = function()
  local c1, c2, c3
  local root = async.run(function()
    c1 = async.run(function()
      c2 = async.run(function()
        c3 = async.run(eternity)
        await(c3)
      end)
      await(c2)
    end)
    await(c1)
  end)

  -- let the tree build up
  vim.wait(10, function() return c3 ~= nil end)

  root:close()
  expect_err(root, 'closed')
  expect_err(c1, 'closed')
  expect_err(c2, 'closed')
  expect_err(c3, 'closed')
end

-- ==============================================================
-- Detach from parent
-- ==============================================================

T['detach'] = MiniTest.new_set()

T['detach']['parent does not wait for detached child'] = function()
  local child
  local parent = async.run(function()
    child = async.run(function() sleep(50) end)
    child:detach()
  end)

  parent:wait(100)
  eq(parent:status(), 'resolved')
  eq(child:status(), 'pending')

  child:wait(100)
  eq(child:status(), 'resolved')
end

T['detach']['cancelling parent does not cancel detached child'] = function()
  local child
  local parent = async.run(function()
    child = async.run(function() sleep(20) end)
    child:detach()
    sleep(100)
  end)

  parent:close()
  expect_err(parent, 'closed')

  child:wait(100)
  eq(child:status(), 'resolved')
end

T['detach']['detached child error does not reject parent'] = function()
  local child
  local parent = async.run(function()
    child = async.run(function()
      sleep(1)
      error('DETACHED_ERROR')
    end)
    child:detach()
  end)

  parent:wait(100)
  eq(parent:status(), 'resolved')

  expect_err(child, 'DETACHED_ERROR')
end

-- ==============================================================
-- Resolution flattening
-- ==============================================================

T['resolve'] = MiniTest.new_set()

T['resolve']['resolving with a future flattens the result'] = function()
  local inner = async.run(function()
    sleep(1)
    return 'inner value'
  end)

  local outer = async.run(function() return inner end)

  eq(outer:wait(100), 'inner value')
end

T['resolve']['resolving with a rejecting future propagates error'] = function()
  local inner = async.run(function()
    sleep(1)
    error('INNER_ERR')
  end)

  local outer = async.run(function() return inner end)

  expect_err(outer, 'INNER_ERR')
end

-- ==============================================================
-- Wait variants
-- ==============================================================

T['wait'] = MiniTest.new_set()

T['wait']['non-blocking callback form receives ok/value'] = function()
  local got_err, got_val
  local future = async.run(function()
    sleep(1)
    return 'hello'
  end)

  future:wait(function(err, val)
    got_err = err
    got_val = val
  end)

  future:wait(100)

  eq(got_err, nil)
  eq(got_val, 'hello')
end

T['wait']['non-blocking callback form receives error'] = function()
  local got_err, got_val
  local future = async.run(function()
    sleep(1)
    error('boom')
  end)

  future:wait(function(err, val)
    got_err = err
    got_val = val
  end)

  future:pwait(100)

  eq(got_val, nil)
  assert(tostring(got_err):match('boom'), 'Expected "boom", got: ' .. tostring(got_val))
end

T['wait']['pwait returns ok=true for successful future'] = function()
  local future = async.run(function()
    sleep(1)
    return 'ok', 2
  end)

  local ok, v1, v2 = future:pwait(100)
  eq(ok, true)
  eq(v1, 'ok')
  eq(v2, 2)
end

T['wait']['pwait returns ok=false with error'] = function()
  local future = async.run(function()
    sleep(1)
    error('BOOM')
  end)

  local ok, err = future:pwait(100)
  eq(ok, false)
  assert(tostring(err):match('BOOM'))
end

T['wait']['wait on already-settled future returns value immediately'] = function()
  local future = async.run(function() return 42 end)
  -- no await, should resolve synchronously
  eq(future:status(), 'resolved')
  eq(future:wait(100), 42)
end

T['wait']['callback registered after settle is fired immediately'] = function()
  local future = async.run(function() return 'done' end)

  local got_val
  future:wait(function(_err, val) got_val = val end)
  eq(got_val, 'done')
end

-- ==============================================================
-- async.all / async.any
-- ==============================================================

T['all'] = MiniTest.new_set()

T['all']['returns results of all futures'] = function()
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

T['all']['errors if any future rejects'] = function()
  local future = async.run(function()
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

  expect_err(future, 'BOOM')
end

T['all']['empty list resolves with empty table'] = function()
  local result = async.run(function() return async.all({}) end):wait(100)
  eq(result, {})
end

T['any'] = MiniTest.new_set()

T['any']['returns the first future to resolve'] = function()
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

T['any']['errors if all futures reject'] = function()
  local future = async.run(function()
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

  expect_err(future, 'all futures rejected')
end

T['any']['first resolving wins even if later ones would reject'] = function()
  local result = async
    .run(function()
      return async.any({
        async.run(function()
          sleep(1)
          return 'winner'
        end),
        async.run(function()
          sleep(5)
          error('too late')
        end),
      })
    end)
    :wait(100)

  eq(result, 'winner')
end

-- ==============================================================
-- Edge cases
-- ==============================================================

T['edge'] = MiniTest.new_set()

T['edge']['callback called multiple times is handled gracefully'] = function()
  local call_count = 0
  local results = {}

  local future = async.run(function()
    local result = async.await(function(callback)
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

  local final_result = future:wait(100)

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

T['edge']['async callback called multiple times is ignored'] = function()
  -- Similar to above but where the first call is asynchronous
  local result
  local future = async.run(function()
    return async.await(function(callback)
      vim.schedule(function() callback(nil, 'FIRST') end)
      vim.defer_fn(function() callback(nil, 'SECOND') end, 5)
    end)
  end)

  result = future:wait(100)
  eq(result, 'FIRST')
end

T['edge']['status reflects lifecycle'] = function()
  local future = async.run(eternity)
  eq(future:status(), 'pending')
  future:close()
  eq(future:status(), 'closed')
end

T['edge']['resolving future with itself rejects'] = function()
  local future
  future = async.run(function()
    sleep(1)
    return future
  end)

  expect_err(future, 'future resolved with itself')
end

T['edge']['cancel on already-resolved future is no-op'] = function()
  local future = async.run(function() return 42 end)
  eq(future:wait(100), 42)
  future:close()
  eq(future:status(), 'resolved')
  eq(future:wait(100), 42)
end

T['edge']['cancel on already-rejected future is no-op'] = function()
  local future = async.run(function() error('ERR') end)
  expect_err(future, 'ERR')
  future:close()
  eq(future:status(), 'rejected')
  expect_err(future, 'ERR')
end

T['edge']['multiple cancel calls are safe'] = function()
  local future = async.run(eternity)
  future:close()
  future:close()
  future:close()
  expect_err(future, 'closed')
end

T['edge']['synchronous future resolves synchronously'] = function()
  -- Per the docs: an entirely synchronous async.run() call will be run synchronously.
  local future = async.run(function() return 'sync' end)
  eq(future:status(), 'resolved')
  eq(future:wait(0), 'sync')
end

T['edge']['wrap with synchronous callback'] = function()
  local future = async.run(function()
    return async.await(function(cb) cb(nil, 'sync-wrap') end)
  end)
  eq(future:status(), 'resolved')
  eq(future:wait(0), 'sync-wrap')
end

T['edge']['wrap callback with error as first arg rejects'] = function()
  local future = async.run(function()
    async.await(function(cb) cb('OOPS') end)
  end)

  expect_err(future, 'OOPS')
end

return T
