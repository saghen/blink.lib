--- @enum blink.lib.TaskStatus
local STATUS = {
  RUNNING = 1,
  COMPLETED = 2,
  FAILED = 3,
  CANCELLED = 4,
}

---Allows chaining of cancellable async operations without callback hell. You may want to use lewis's async.nvim instead which will likely be adopted into the core: https://github.com/lewis6991/async.nvim
---
---```lua
---local task = require('blink.lib.task')
---
---local some_task = task.new(function(resolve, reject)
---  vim.uv.fs_readdir(vim.loop.cwd(), function(err, entries)
---    if err ~= nil then return reject(err) end
---    resolve(entries)
---  end)
---end)
---
---some_task
---  :map(function(entries)
---    return vim.tbl_map(function(entry) return entry.name end, entries)
---  end)
---  :catch(function(err) vim.print('failed to read directory: ' .. err) end)
---```
---
---Note that lua language server cannot infer the type of the task from the `resolve` call.
---
---You may need to add the type annotation explicitly via an `@return` annotation on a function returning the task, or via the `@cast/@type` annotations on the task variable.
--- @class blink.lib.Task<T>: { status: blink.lib.TaskStatus, result: T, error: any | nil, _completion_cbs: fun(result: T)[], _failure_cbs: fun(err: any)[], _cancel_cbs: fun()[], _cancel: fun()?, __task: true }
local task = {
  __task = true,
  STATUS = STATUS,
}

--- @generic T
--- @param fn fun(resolve: fun(result?: T), reject: fun(err: any), cancel: fun()): fun()?
--- @return blink.lib.Task<T>
function task.new(fn)
  local self = setmetatable({}, { __index = task })
  self.status = STATUS.RUNNING
  self._completion_cbs = {}
  self._failure_cbs = {}
  self._cancel_cbs = {}
  self.result = nil
  self.error = nil

  local _clear = function()
    self._completion_cbs = {}
    self._failure_cbs = {}
    self._cancel_cbs = {}
  end

  local resolve = function(result)
    if self.status ~= STATUS.RUNNING then return end

    self.status = STATUS.COMPLETED
    self.result = result

    for _, cb in ipairs(self._completion_cbs) do
      cb(result)
    end
    _clear()
  end

  local reject = function(err)
    if self.status ~= STATUS.RUNNING then return end

    self.status = STATUS.FAILED
    self.error = err

    for _, cb in ipairs(self._failure_cbs) do
      cb(err)
    end
    _clear()
  end

  local cancel = function() self:cancel() end

  -- run task callback, if it returns a function, use it for cancellation

  local success, cancel_fn_or_err = pcall(function() return fn(resolve, reject, cancel) end)

  if not success then
    reject(cancel_fn_or_err)
  elseif type(cancel_fn_or_err) == 'function' then
    self._cancel = cancel_fn_or_err
  end

  return self
end

--- Similar to `new()` but for wrapping callback functions.
--- Instead of `resolve` and `reject`, a callback function will `reject` when
--- the first field (`err`) is not `nil`. Otherwise, it will resolve with
--- the second field (`result`).
--- @generic T
--- @param fn fun(callback: fun(err: any, result: T))
--- @return blink.lib.Task<T>
function task.wrap(fn)
  return task.new(function(resolve, reject)
    fn(function(err, result)
      if err ~= nil then return reject(err) end
      resolve(result)
    end)
  end)
end

--- @param self blink.lib.Task<any>
function task:cancel()
  if self.status ~= STATUS.RUNNING then return end
  self.status = STATUS.CANCELLED

  if self._cancel ~= nil then self._cancel() end
  for _, cb in ipairs(self._cancel_cbs) do
    cb()
  end
  self._completion_cbs = {}
  self._failure_cbs = {}
  self._cancel_cbs = {}
end

--- mappings

--- Creates a new task by applying a function to the result of the current task
--- This only applies if the input task completed successfully.
--- @generic T
--- @generic U
--- @param self blink.lib.Task<`T`>
--- @param fn fun(result: T): blink.lib.Task<`U`> | `U` | nil
--- @return blink.lib.Task<U>
function task:map(fn)
  return task.new(function(resolve, reject, cancel)
    self:on_resolve(function(result)
      vim.schedule(function()
        local success, mapped_result = pcall(fn, result)
        if not success then return reject(mapped_result) end

        -- received a task object, chain it
        if type(mapped_result) == 'table' and mapped_result.__task then
          --- @cast mapped_result blink.lib.Task<`U`>
          mapped_result:on_resolve(resolve)
          mapped_result:on_reject(reject)
          mapped_result:on_cancel(cancel)
        else
          resolve(mapped_result)
        end
      end)
    end)
    self:on_reject(reject)
    self:on_cancel(cancel)
    return function() self:cancel() end
  end)
end

--- Creates a new task by applying a function to the error of the current task.
--- This only applies if the input task errored.
--- @generic T
--- @generic U
--- @param fn fun(self: blink.lib.Task<T>, err: any): blink.lib.Task<U> | U | nil
--- @return blink.lib.Task<T | U>
function task:catch(fn)
  return task.new(function(resolve, reject, cancel)
    self:on_resolve(resolve)
    self:on_reject(function(err)
      local success, mapped_err = pcall(fn, err)
      if not success then return reject(mapped_err) end

      -- received a task object, chain it
      if type(mapped_err) == 'table' and mapped_err.__task then
        --- @cast mapped_err blink.lib.Task<`T` | `U`>
        mapped_err:on_resolve(resolve)
        mapped_err:on_reject(reject)
        mapped_err:on_cancel(cancel)
        return
      end
      resolve(mapped_err)
    end)
    self:on_cancel(cancel)
    return function() self:cancel() end
  end)
end

--- events

--- @generic T
--- @param self blink.lib.Task<T>
--- @param cb fun(result: T)
--- @return blink.lib.Task<T>
function task:on_resolve(cb)
  if self.status == STATUS.COMPLETED then
    cb(self.result)
  elseif self.status == STATUS.RUNNING then
    table.insert(self._completion_cbs, cb)
  end
  return self
end

--- @generic T
--- @param self blink.lib.Task<T>
--- @param cb fun(err: any)
--- @return blink.lib.Task<T>
function task:on_reject(cb)
  if self.status == STATUS.FAILED then
    cb(self.error)
  elseif self.status == STATUS.RUNNING then
    table.insert(self._failure_cbs, cb)
  end
  return self
end

--- @generic T
--- @param self blink.lib.Task<T>
--- @param cb fun()
--- @return blink.lib.Task<T>
function task:on_cancel(cb)
  if self.status == STATUS.CANCELLED then
    cb()
  elseif self.status == STATUS.RUNNING then
    table.insert(self._cancel_cbs, cb)
  end
  return self
end

--- utils

--- Awaits all tasks in the given array of tasks.
--- If any child task fails, the parent task will fail, and all other children will be cancelled.
--- If any child task cancels, the parent task will be cancelled, and all other children will be cancelled.
--- If all tasks resolve, the parent task will resolve with an array of results.
--- @generic T
--- @param tasks blink.lib.Task<T>[]
--- @return blink.lib.Task<T[]>
function task.all(tasks)
  if #tasks == 0 then
    return task.new(function(resolve) resolve({}) end)
  end

  local all_task
  all_task = task.new(function(resolve, reject)
    local results = {}
    local has_resolved = {}

    local function resolve_if_completed()
      -- we can't check #results directly because a table like
      -- { [2] = { ... } } has a length of 2
      for i = 1, #tasks do
        if has_resolved[i] == nil then return end
      end
      resolve(results)
    end

    local function cancel()
      for _, task in ipairs(tasks) do
        task:cancel()
      end
    end

    for idx, task in ipairs(tasks) do
      -- task completed, add result to results table, and resolve if all tasks are done
      task
        :on_resolve(function(result)
          results[idx] = result
          has_resolved[idx] = true
          resolve_if_completed()
        end)
        -- one task failed, cancel all other tasks
        :on_reject(function(err)
          reject(err)
          cancel()
        end)
        -- one task was cancelled, cancel all other tasks
        :on_cancel(function()
          cancel()
          if all_task == nil then
            vim.schedule(function() all_task:cancel() end)
          else
            all_task:cancel()
          end
        end)
    end

    -- root task cancelled, cancel all inner tasks
    return cancel
  end)
  return all_task
end

--- Creates a task that resolves with the given value.
--- @generic T
--- @param val? T
--- @return blink.lib.Task<T>
function task.resolve(val)
  return task.new(function(resolve) resolve(val) end)
end

--- Creates a task that rejects with the given error.
--- @param err any
--- @return blink.lib.Task<nil>
function task.reject(err)
  return task.new(function(_, reject) reject(err) end)
end

--- Makes the task infallible, returning true if the task resolved successfully and false if the task rejected.
--- @generic T
--- @param self blink.lib.Task<T>
--- @return blink.lib.Task<boolean>
function task:ok(fn)
  return self:map(function() return true end):catch(function() return false end)
end

--- @generic T
--- @param self blink.lib.Task<T>
--- @return blink.lib.Task<T>
function task:schedule()
  return self:map(function(value)
    return task.new(function(resolve)
      vim.schedule(function() resolve(value) end)
    end)
  end)
end

--- @generic T
--- @param self blink.lib.Task<T>
--- @return blink.lib.Task<nil>
function task:void()
  return self:map(function() end)
end

--- Fails if the task doesn't complete within the given number of milliseconds.
--- @generic T
--- @param self blink.lib.Task<T>
--- @param ms number
--- @return blink.lib.Task<T>
function task:timeout(ms)
  return task.new(function(resolve, reject)
    vim.defer_fn(function()
      self:cancel()
      reject('Task timed out after ' .. ms .. ' milliseconds.')
    end, ms)
    self:map(resolve):catch(reject)
  end)
end

--- Blocks until the task completes, fails, or is cancelled.
--- Must be called from the main thread (not from a fast callback).
--- @generic T
--- @param self blink.lib.Task<T>
--- @param timeout number Timeout in milliseconds
--- @param interval? number Polling interval in milliseconds (default: 20)
--- @return T? result
function task:wait(timeout)
  vim.wait(timeout, function() return self.status ~= STATUS.RUNNING end, 20)

  if self.status == STATUS.COMPLETED then
    return self.result
  elseif self.status == STATUS.FAILED then
    error(self.error)
  elseif self.status == STATUS.CANCELLED then
    error('Task was cancelled')
  else
    self:cancel()
    error('Task timed out after ' .. timeout .. ' milliseconds')
  end
end

return task
