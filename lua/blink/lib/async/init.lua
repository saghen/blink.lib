--- Structured concurrency where errors propagate up and cancellation propagates down.
--- Inspired by https://github.com/lewis6991/async.nvim
---
--- `blink.lib.async` uses a synchronous step() closure which owns the coroutine. Every step() inspects the yield()-ed value, and arranges for step() to be called again, or it settles. The code doesn't include the defensive guards that async.nvim has around unexpected coroutine.resumes. The event loop comes entirely from the .wrap()-ed Futures, not from the scheduler. An entirely synchronous async.run() call will be run synchronously.
---
--- Other differences from async.nvim:
--- - not runtime agnostic
--- - ~-60% lower runtime and ~-50% lower mem usage, see PR for scripts (benchmarks need more verification, ideally some real I/O heavy workloads)
--- - simpler internal loop (247 LoC ignoring blanks/comments)
--- - no stack traces for non-awaited Futures

local function pack(...) return { n = select('#', ...), ... } end
local _unpack = unpack
local function unpack(t, i, j) return _unpack(t, i or 1, j or t.n) end

local PENDING = 1
local SETTLING = 2
local RESOLVED = 3
local REJECTED = 4
local CLOSED = 5

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
--- Returns a [blink.lib.Future] which can be used to wait or await the result
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

  -- main loop
  local cb_state, cb
  local function step(...)
    -- closed while suspended
    if future.state ~= PENDING then return end

    local prev = current_future
    current_future = future
    local yielded = pack(coroutine.resume(co, ...))
    current_future = prev

    -- errored, bubble up
    if not yielded[1] then return future:reject(yielded[2]) end

    -- async.run(fn): closure completed, return result
    if coroutine.status(co) == 'dead' then return future:resolve(unpack(yielded, 2)) end

    -- async.await(future): inside of current future
    if #yielded == 2 and getmetatable(yielded[2]) == Future then return yielded[2]:_finally(step) end

    -- async.await(fn): pass callback that resumes the coroutine
    if type(yielded[2]) == 'function' then
      -- create the closure once, but on-demand
      if cb_state == nil then
        -- this is a bit mind numbing, but we want to make use of tail-call optimization
        -- when the callback is synchronous. so we store the result of the callback externally
        -- and return the `step()` call directly, flattening the stack.
        cb_state = {}
        cb = function(err, ...)
          if cb_state.settled then return end
          cb_state.settled = true

          if cb_state.sync_phase then
            cb_state.sync_ok = err == nil
            cb_state.sync_value = err == nil and { n = select('#', ...), ... } or { err }
          else
            future._cleanup_cb = nil
            if err ~= nil then return step(false, err) end
            return step(true, ...)
          end
        end
      end

      cb_state.settled = false
      cb_state.sync_phase = true
      local ok, err_or_cleanup = pcall(yielded[2], cb)
      cb_state.sync_phase = false

      -- synchronous callback()
      if cb_state.settled then return step(cb_state.sync_ok, unpack(cb_state.sync_value)) end
      -- synchronous error()
      if not ok then
        cb_state.settled = true
        return step(false, err_or_cleanup)
      end
      -- store cleanup function
      if type(err_or_cleanup) == 'function' then future._cleanup_cb = err_or_cleanup end
      return
    end

    future:reject('yielded unexpected value')
  end
  step()

  return future
end

--- Wait for this future to settle (blocking). Must be called from within a `async.run` closure.
--- @generic T
--- @param future blink.lib.Future<T> | fun(callback: fun(err?: any, ...: T...)): fun()?
--- @return T...
function async.await(future)
  local yielded = pack(coroutine.yield(future))
  -- child has been awaited by the parent, detach it so we ignore it on completion
  -- TODO: shouldn't this be handled by step()?
  if getmetatable(future) == Future and current_future == future.parent then future:detach() end
  if not yielded[1] then
    local tb = debug
      .traceback(coroutine.running(), '', 2)
      :gsub('^\n[^\n]*\n', '') -- strip first line (empty) and 'stack traceback:' header
      :gsub('\t([^\n]*)$', '\tawaited at %1') -- prepend `awaited at` to last line (this frame)
    error(yielded[2] .. '\n' .. tb, 0)
  end
  return unpack(yielded, 2)
end

--- Return the results of all futures, or error if any future rejects.
--- @generic T
--- @param futures blink.lib.Future<T>[]
--- @return T[]
function async.all(futures)
  -- TODO: incorrect
  local results = {}
  for i, future in ipairs(futures) do
    results[i] = async.await(future)
  end
  return results
end

--- Return the first future to settle, or errors if all futures reject.
--- @generic T
--- @param futures blink.lib.Future<T>[]
--- @return T...
function async.any(futures)
  -- TODO: incorrect
  return async.await(function(callback)
    local remaining = #futures
    for _, future in ipairs(futures) do
      future:detach()
      future:_finally(function(ok, ...)
        if ok then
          callback(nil, ...)
        else
          remaining = remaining - 1
          if remaining == 0 then callback('all futures rejected') end
        end
      end)
    end

    -- propagate close
    return function()
      for _, future in ipairs(futures) do
        future:close()
      end
    end
  end)
end

--- @param capacity? integer 0 = rendezvous, N = bounded (default: 0)
--- @return blink.lib.async.Channel
function async.channel(capacity) return require('blink.lib.async.channel').new(capacity) end

--- @return blink.lib.async.Event
function async.event() return setmetatable({ _set = false, _waiters = {} }, require('blink.lib.async.event')) end

--- @return blink.lib.async.Mutex
function async.mutex() return require('blink.lib.async.mutex').new() end

--- @param permits? integer (default: 1)
--- @return blink.lib.async.Semaphore
function async.semaphore(permits) return require('blink.lib.async.semaphore').new(permits) end

------------------
--- Future
------------------

--- Detach a task from its parent, such that the parent will no longer wait for it or close it
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

--- @return 'pending' | 'settling' | 'resolved' | 'rejected' | 'closed'
function Future:status()
  if self.state == PENDING then return 'pending' end
  if self.state == SETTLING then return 'settling' end
  if self.state == RESOLVED then return 'resolved' end
  if self.state == REJECTED then return 'rejected' end
  if self.state == CLOSED then return 'closed' end
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

--- Close this future and all its children
function Future:close()
  if self.state ~= PENDING then return end
  self.state = SETTLING

  -- TODO: what to do with cleanup errors?
  if self.children ~= nil then
    for _, child in ipairs(self.children) do
      if child ~= true then child:close() end
    end
  end
  self:_finalize(CLOSED, 'closed')
  self:_cleanup()
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
      if child ~= true then child:close() end
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
      -- if a child rejects, since the parent was resolving, switch to reject
      if not ok and child.state == REJECTED then
        state = REJECTED
        args = pack(...)
      end
      remaining = remaining - 1
      if remaining == 0 then self:_finalize(state, unpack(args)) end
    end)
  end
end

--- Settling -> Resolved/Rejected/Closed
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
function Future:_cleanup()
  if self._cleanup_cb ~= nil then
    if type(self._cleanup_cb) == 'function' then
      self._cleanup_cb()
    else
      self._cleanup_cb:close()
    end
    self._cleanup_cb = nil
  end
end

--- @private
function Future:_finally(cb)
  if self.state > SETTLING then return cb(self.state == RESOLVED, unpack(self.values)) end

  if self.cbs == nil then
    self.cbs = { cb }
  else
    table.insert(self.cbs, cb)
  end
end

return async
