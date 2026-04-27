--- Structured concurrency where errors propagate up and cancellation propagates down.
--- Inspired by https://github.com/lewis6991/async.nvim
---
--- Differences from async.nvim:
--- - .wrap() uses a closure and supports returning a cancellation func
--- - uv hooks are not automatically closed
--- - ~2-4x faster and significantly simpler (208 LoC ignoring blanks/comments)
--- - other?
---
--- Remaining work:
--- - semaphores
--- - improve stack traces
--- - add `Task:detach()`
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

-- Track the currently-running task (the "parent" context)
local current_task = nil

--- @class blink.lib.Task<T>
local Task = {}
--- @private
Task.__index = Task

--- @class blink.lib.async
local async = {}

--- Run a function in an async context, asynchronously.
---
--- Returns an [blink.lib.Task] object which can be used to wait or await the result
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
--- @return blink.lib.Task<T...>
function async.run(fn)
  local task = setmetatable({ state = PENDING, parent = current_task }, Task)
  local co = coroutine.create(fn)

  -- register with parent
  if current_task ~= nil then
    if current_task.children == nil then
      current_task.children = { task }
    else
      table.insert(current_task.children, task)
    end
  end

  local function step(ok, ...)
    -- cancelled while suspended
    if task.state ~= PENDING then return end

    local prev = current_task
    current_task = task
    local yielded = pack(coroutine.resume(co, ok, ...))
    current_task = prev

    -- synchronously failed
    if not yielded[1] then
      task:reject(unpack(yielded, 2))
    elseif #yielded == 2 and getmetatable(yielded[2]) == Task then
      -- synchronously returned a task, flatten
      -- async.run(function() return async.run(function() sleep(1) end) end)
      if coroutine.status(co) == 'dead' then
        task:resolve(yielded[2])
      -- async.await(task): inside of current task
      else
        yielded[2]:_finally(step)
      end

    -- coroutine completed, resolve
    elseif coroutine.status(co) == 'dead' then
      task:resolve(unpack(yielded, 2))

    -- async.wrap(fn): pass callback that resumes the coroutine
    elseif #yielded == 2 and type(yielded[2]) == 'function' then
      local settled = false
      local callback = function(err, ...)
        if settled then return end
        settled = true
        task.cleanup = nil
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
        task.cleanup = on_cancel_or_err
      end
    else
      task:reject('yielded unexpected value')
    end
  end
  step()

  return task
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

--- Return the results of all tasks, or error if any task rejects.
--- All children will be implicitly cancelled on failure.
--- @generic T
--- @param tasks blink.lib.Task<T>[]
--- @return T[]
function async.all(tasks)
  local results = {}
  for i, task in ipairs(tasks) do
    results[i] = async.await(task)
  end
  return results
end

--- Return the first task to settle, or error if all tasks reject.
--- @generic T
--- @param tasks blink.lib.Task<T>[]
--- @return T...
function async.any(tasks)
  -- TODO: can this be simplified?
  return async.wrap(function(callback)
    local remaining = #tasks
    local settled = false
    for _, task in ipairs(tasks) do
      task:_finally(function(ok, ...)
        if settled then return end
        remaining = remaining - 1
        if ok then
          settled = true
          callback(nil, ...)
        elseif remaining == 0 then
          settled = true
          callback('all tasks rejected')
        end
      end)
    end

    -- propagate cancellation
    return function()
      for _, task in ipairs(tasks) do
        task:cancel()
      end
    end
  end)
end

--- Wait for this task to settle (blocking). Must be called from within a `async.run` closure.
--- @generic T
--- @param task blink.lib.Task<T>
--- @return T...
function async.await(task)
  local yielded = pack(coroutine.yield(task))
  if not yielded[1] then error(yielded[2], 0) end
  return unpack(yielded, 2)
end

------------------
--- Task
------------------

--- Wait for this task to settle, optionally with a timeout (blocking) or callback (non-blocking)
--- @generic T
--- @param self blink.lib.Task<T>
--- @param timeout_or_cb? integer | fun(err?: any, ...?: T...)
--- @overload fun(timeout?: integer): T...
function Task:wait(timeout_or_cb)
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

--- Wait for this task to settle in _protected_ mode, optionally with a timeout (blocking) or callback (non-blocking).
--- This means that any error inside `f` is not propagated. Instead, `pwait` catches the error and returns whether the
--- task succeeded or not, along with the return values.
--- @generic T
--- @param self blink.lib.Task<T>
--- @param timeout_or_cb? integer | fun(ok: boolean, ...: T...)
--- @overload fun(timeout?: integer): boolean, T...
function Task:pwait(timeout_or_cb)
  if type(timeout_or_cb) == 'function' then return self:_finally(timeout_or_cb) end
  return pcall(self.wait, self, timeout_or_cb)
end

--- @return 'pending' | 'settling' | 'resolved' | 'rejected' | 'cancelled'
function Task:status()
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

--- Resolve this task with a value
--- @generic T
--- @param self blink.lib.Task<T>
--- @param ... T
function Task:resolve(...)
  local value = ...
  -- resolving with a value, settle
  if getmetatable(value) ~= Task or select('#', ...) ~= 1 then return self:_settle(RESOLVED, ...) end

  -- resolving another task, flatten
  if self.state ~= PENDING then return end
  if value == self then return self:reject('task resolved with itself') end
  value:_finally(function(ok, ...)
    if ok then
      self:resolve(...)
    else
      self:reject(...)
    end
  end)
end

--- Reject this task with an error
--- @generic T
--- @param self blink.lib.Task<T>
--- @param err any
function Task:reject(err) self:_settle(REJECTED, err) end

--- Cancel this task and all its children
function Task:cancel()
  if self.state ~= PENDING then return end
  self.state = SETTLING

  if self.cleanup ~= nil then self.cleanup() end
  if self.children ~= nil then
    for _, child in ipairs(self.children) do
      child:cancel()
    end
  end
  self:_finalize(CANCELLED, 'cancelled')
end

--- @private
function Task:_settle(state, ...)
  if self.state ~= PENDING then return end
  self.state = SETTLING

  -- no children to await, finalize immediately
  if self.children == nil then return self:_finalize(state, ...) end

  -- gather pending children, or cancel them if this task rejected/cancelled
  local pending_children = {}
  for _, child in ipairs(self.children) do
    if child.state <= SETTLING then
      -- on error/cancel, cancel children
      if state ~= RESOLVED then
        child:cancel()
        -- otherwise, wait for child to settle
      else
        table.insert(pending_children, child)
      end
    end
  end
  self.children = nil

  -- no children left, finalize immediately
  if #pending_children == 0 then return self:_finalize(state, ...) end

  -- wait for children to settle
  local args = pack(...)
  local remaining = #pending_children
  for _, child in ipairs(pending_children) do
    child:_finally(function(ok, ...)
      -- if a child rejects and parent was resolving, convert to reject
      if not ok and state == RESOLVED and child.state == REJECTED then
        state = REJECTED
        args = pack(...)
      end
      remaining = remaining - 1
      if remaining == 0 then self:_finalize(state, unpack(args)) end
    end)
  end
end

--- @private
function Task:_finalize(state, ...)
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
function Task:_finally(cb)
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
