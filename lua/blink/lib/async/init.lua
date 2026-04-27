--- Structured concurrency where errors propagate up and cancellation propagates down.
--- Inspired by https://github.com/lewis6991/async.nvim
---
--- The primary difference comes from the scheduler, where blink.lib.async uses a synchronous step() closure which owns the coroutine. Every step() inspects the yield()-ed value, and arranges for step() to be called again, or it settles. The code doesn't include the defensive guards that async.nvim has around unexpected coroutine.resumes. It also doesn't (currently) include a trampoline to avoid stack overflows. The event loop comes entirely from the .wrap()-ed Futures, not from the scheduler. An entirely synchronous async.run() call will be run synchronously.
---
--- Other differences from async.nvim:
---
--- - not runtime agnostic
--- - `async.await()` only applies to `Future`s, `async.wrap()` still applies to any `cb` func
--- - `async.wrap()` always uses a closure and supports returning a cancellation func, rather than calling `:close()`
--- - ~-60% lower runtime and ~-50% lower mem usage, see PR for scripts (benchmarks need more verification, ideally some real I/O heavy workloads)
--- - tracebacks untested (planning to look into it)
--- - simpler (208 LoC ignoring blanks/comments)
---
--- Remaining work:
--- - semaphores
--- - improve stack traces
--- - add `Future:detach()`
--- - expand test suite (`pwait`, `async.all`, `async.any`, ...)
--- - expand helpers (`async.schedule`, `async.iter`, ...)

local function pack(...) return { n = select('#', ...), ... } end
local _unpack = unpack
local function unpack(t, i, j) return _unpack(t, i or 1, j or t.n) end

local PENDING = 1
local SETTLING = 2
local RESOLVED = 3
local REJECTED = 4
local CANCELLED = 5

-- Track the currently-running future (the "parent" context)
local current_future = nil

--- @class blink.lib.Future<T>
local Future = {}
--- @private
Future.__index = Future

--- @class blink.lib.async
local async = {}

--- Run a function in an async context, asynchronously.
---
--- Returns an [blink.lib.Future] object which can be used to wait or await the result
--- of the function.
---
--- ```lua
--- local sleep = function(ms)
---   return async.wrap(function(callback) vim.defer_fn(callback, ms) end)
--- end
---
--- async.run(function()
---   print('foo')
---   sleep(1000)
---   print('world')
--- end)
---
--- print('hello')
--- ```
---
--- prints: `foo` then `hello` then `world` after 1 second
---
--- @generic T
--- @param fn fun(): T...
--- @return blink.lib.Future<T...>
function async.run(fn)
  local future = setmetatable({ state = PENDING, parent = current_future }, Future)
  local co = coroutine.create(fn)

  -- register with parent
  if current_future ~= nil then
    if current_future.children == nil then
      current_future.children = { future }
    else
      table.insert(current_future.children, future)
    end
    future.parent_child_idx = #current_future.children
  end

  local function step(...)
    -- cancelled while suspended
    if future.state ~= PENDING then return end

    local prev = current_future
    current_future = future
    local yielded = pack(coroutine.resume(co, ...))
    current_future = prev

    -- synchronously failed
    if not yielded[1] then
      future:reject(unpack(yielded, 2))
    elseif #yielded == 2 and getmetatable(yielded[2]) == Future then
      -- synchronously returned a future, flatten
      -- async.run(function() return async.run(function() sleep(1) end) end)
      if coroutine.status(co) == 'dead' then
        future:resolve(yielded[2])
      -- async.await(future): inside of current future
      else
        yielded[2]:_finally(step)
      end

    -- coroutine completed, resolve
    elseif coroutine.status(co) == 'dead' then
      future:resolve(unpack(yielded, 2))

    -- async.wrap(fn): pass callback that resumes the coroutine
    elseif #yielded == 2 and type(yielded[2]) == 'function' then
      local settled = false
      local callback = function(err, ...)
        if settled then return end
        settled = true
        future.cleanup = nil
        if err ~= nil then
          step(false, err)
        else
          step(true, ...)
        end
      end

      local ok2, on_cancel_or_err = pcall(yielded[2], callback)
      -- synchronous error
      if not ok2 and not settled then
        callback(on_cancel_or_err)
      -- cancellation hook
      elseif type(on_cancel_or_err) == 'function' then
        future.cleanup = on_cancel_or_err
      end
    else
      future:reject('yielded unexpected value')
    end
  end
  step()

  return future
end

--- Wrap a callback-style function into an async function.
--- @generic T
--- @param fn fun(callback: fun(err?: any, ...: T...)): fun()?
--- @return T...
function async.wrap(fn)
  local yielded = pack(coroutine.yield(fn))
  if not yielded[1] then error(yielded[2], 0) end
  return unpack(yielded, 2)
end

--- Wait for this future to settle (blocking). Must be called from within a `async.run` closure.
--- @generic T
--- @param future blink.lib.Future<T>
--- @return T...
function async.await(future)
  local yielded = pack(coroutine.yield(future))
  -- child has been awaited by the parent, detach it so we ignore it on completion
  if current_future == future.parent then future:detach() end
  if not yielded[1] then error(yielded[2], 0) end
  return unpack(yielded, 2)
end

--- Return the results of all futures, or error if any future rejects.
--- All children will be implicitly cancelled on failure.
--- @generic T
--- @param futures blink.lib.Future<T>[]
--- @return T[]
function async.all(futures)
  local results = {}
  for i, future in ipairs(futures) do
    results[i] = async.await(future)
  end
  return results
end

--- Return the first future to settle, or error if all futures reject.
--- @generic T
--- @param futures blink.lib.Future<T>[]
--- @return T...
function async.any(futures)
  -- TODO: can this be simplified?
  return async.wrap(function(callback)
    local remaining = #futures
    local settled = false
    for _, future in ipairs(futures) do
      future:_finally(function(ok, ...)
        if settled then return end
        remaining = remaining - 1
        if ok then
          settled = true
          callback(nil, ...)
        elseif remaining == 0 then
          settled = true
          callback('all futures rejected')
        end
      end)
    end

    -- propagate cancellation
    return function()
      for _, future in ipairs(futures) do
        future:cancel()
      end
    end
  end)
end

------------------
--- Future
------------------

function Future:detach()
  if self.parent == nil then return end
  if #self.parent.children == 1 then
    -- fast path: only child, clear
    self.parent.children = nil
  else
    -- replace child with a placeholder
    self.parent.children[self.parent_child_idx] = true
  end
  self.parent = nil
end

--- Wait for this future to settle, optionally with a timeout (blocking) or callback (non-blocking)
--- @generic T
--- @param self blink.lib.Future<T>
--- @param timeout_or_cb? integer | fun(err?: any, ...?: T...)
--- @overload fun(timeout?: integer): T...
function Future:wait(timeout_or_cb)
  if type(timeout_or_cb) == 'function' then
    return self:_finally(function(ok, ...)
      if ok then
        timeout_or_cb(nil, ...)
      else
        timeout_or_cb(...)
      end
    end)
  end

  if self.state <= SETTLING then vim.wait(timeout_or_cb or vim._maxint, function() return self.state > SETTLING end) end
  if self.state <= SETTLING then error('timeout', 0) end
  if self.state == RESOLVED then return unpack(self.values) end
  error(self.values[1], 0)
end

--- Wait for this future to settle in _protected_ mode, optionally with a timeout (blocking) or callback (non-blocking).
--- This means that any error inside `f` is not propagated. Instead, `pwait` catches the error and returns whether the
--- future succeeded or not, along with the return values.
--- @generic T
--- @param self blink.lib.Future<T>
--- @param timeout_or_cb? integer | fun(ok: boolean, ...: T...)
--- @overload fun(timeout?: integer): boolean, T...
function Future:pwait(timeout_or_cb)
  if type(timeout_or_cb) == 'function' then return self:_finally(timeout_or_cb) end
  return pcall(self.wait, self, timeout_or_cb)
end

--- @return 'pending' | 'settling' | 'resolved' | 'rejected' | 'cancelled'
function Future:status()
  if self.state == PENDING then return 'pending' end
  if self.state == SETTLING then return 'settling' end
  if self.state == RESOLVED then return 'resolved' end
  if self.state == REJECTED then return 'rejected' end
  if self.state == CANCELLED then return 'cancelled' end
  error('unknown state: ' .. tostring(self.state))
end

------------------
--- Settlement
------------------

--- Resolve this future with a value
--- @generic T
--- @param self blink.lib.Future<T>
--- @param ... T
function Future:resolve(...)
  local value = ...
  -- resolving with a value, settle
  if getmetatable(value) ~= Future or select('#', ...) ~= 1 then return self:_settle(RESOLVED, ...) end

  -- resolving another future, flatten
  if self.state ~= PENDING then return end
  if value == self then return self:reject('future resolved with itself') end
  value:_finally(function(ok, ...)
    if ok then
      self:resolve(...)
    else
      self:reject(...)
    end
  end)
end

--- Reject this future with an error
--- @generic T
--- @param self blink.lib.Future<T>
--- @param err any
function Future:reject(err) self:_settle(REJECTED, err) end

--- Cancel this future and all its children
function Future:cancel()
  if self.state ~= PENDING then return end
  self.state = SETTLING

  if self.cleanup ~= nil then self.cleanup() end
  if self.children ~= nil then
    for _, child in ipairs(self.children) do
      if child ~= true then child:cancel() end
    end
  end
  self:_finalize(CANCELLED, 'cancelled')
end

--- Pending -> Settling
--- Cancel all children on rejection/cancellation
--- Wait for all children on resolve
--- @private
function Future:_settle(state, ...)
  if self.state ~= PENDING then return end
  self.state = SETTLING

  -- no children to await, finalize immediately
  if self.children == nil then return self:_finalize(state, ...) end

  -- if we're not resolving successfully, cancel all children and finalize
  if state ~= RESOLVED then
    for _, child in ipairs(self.children) do
      if child ~= true then child:cancel() end
    end
    return self:_finalize(state, ...)
  end

  -- filter out detached children
  local filtered_children = {}
  for _, child in ipairs(self.children) do
    if child ~= true then table.insert(filtered_children, child) end
  end
  self.children = nil

  -- no children, finalize immediately
  if #filtered_children == 0 then return self:_finalize(state, ...) end

  -- wait for children to settle
  local args = pack(...)
  local remaining = #filtered_children
  for _, child in ipairs(filtered_children) do
    child:_finally(function(ok, ...)
      -- if a child rejects and parent was resolving, convert to reject
      if not ok and child.state == REJECTED then
        state = REJECTED
        args = pack(...)
      end
      remaining = remaining - 1
      if remaining == 0 then self:_finalize(state, unpack(args)) end
    end)
  end
end

--- Settling -> Resolved/Rejected/Cancelled
--- Runs all callbacks
--- @private
function Future:_finalize(state, ...)
  if self.state ~= SETTLING then return end
  self.state = state
  self.values = pack(...)

  -- fire callbacks
  if self.cbs ~= nil then
    for _, cb in ipairs(self.cbs) do
      cb(state == RESOLVED, ...)
    end
    self.cbs = nil
  end
end

--- @private
function Future:_finally(cb)
  if self.state ~= PENDING then
    cb(self.state == RESOLVED, unpack(self.values))
    return
  end

  if self.cbs == nil then
    self.cbs = { cb }
  else
    table.insert(self.cbs, cb)
  end
end

return async
