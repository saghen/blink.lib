--- Drop in replacement for `vim.async` with helpers

assert(vim.async, 'blink.lib.async requires `vim.async` (nvim 0.13+)')
local async = vim.async

--- @class blink.lib.async: vim.async
local M = setmetatable({}, { __index = async })

--- Holds at most one task, see `latest()`
--- @class blink.lib.async.Slot
--- @field task? vim.async.Task

--- Awaits a libuv style callback function (`fn(..., callback(err, result))`), raising `err`
--- @async
--- @generic T
--- @param argc integer Position of the callback argument
--- @param fn fun(...: any): any
--- @param ... any
--- @return T
function M.await_err(argc, fn, ...)
  local err, result = async.await(argc, fn, ...)
  if err ~= nil then error(err, 0) end
  return result
end

--- Starts the given tasks (if pending) and waits for all of them, never raising for a failed task.
--- Returns the `pawait` results (`{ ok, ... }`) in input order.
--- @async
--- @param tasks vim.async.Task[]
--- @return { [1]: boolean, [integer]: any, n: integer }[]
function M.all(tasks)
  async.checkpoint()
  local results = {}
  for i, t in ipairs(tasks) do
    results[i] = vim.F.pack_len(async.pawait(t))
  end
  return results
end

--- Waits for the task up to `ms` milliseconds, without closing it on timeout (unlike `vim.async.timeout`).
--- The returned task completes with the task's results, or fails with `'timeout'`.
--- Use for tasks shared with other callers or that should keep running for a later consumer.
--- @generic R
--- @param ms integer
--- @param task vim.async.Task<R>
--- @return vim.async.Task<R>
function M.deadline(ms, task)
  return async.run('blink.lib.async:deadline', function()
    local timer = async.run('blink.lib.async:deadline:timer', async.sleep, ms)
    local first = async.iter({ task, timer })()
    timer:close()
    if first ~= task then error('timeout', 0) end
    return async.await(task)
  end)
end

--- Closes the task held by the slot, if any
--- @param slot blink.lib.async.Slot
function M.close(slot)
  local t = slot.task
  slot.task = nil
  if t ~= nil then t:close() end
end

--- Closes the previous task held by the slot and runs a new one. Use when only the latest
--- request matters (debounces, documentation, signature help, prefetching).
--- @generic T
--- @param slot blink.lib.async.Slot
--- @param name string
--- @param fn async fun(...: T): any
--- @param ... T
--- @return vim.async.Task
function M.latest(slot, name, fn, ...)
  M.close(slot)
  local t = async.run(name, fn, ...)
  slot.task = t
  return t
end

--- Calls `fn(err)` when the task fails with anything other than being closed
--- @generic T: vim.async.Task
--- @param task T
--- @param fn fun(err: any)
--- @return T
function M.on_error(task, fn)
  task:on_complete(function(err)
    if err ~= nil and err ~= 'closed' then fn(err) end
  end)
  return task
end

--- Wraps a cancel function as a `vim.async.Closable`, for returning from `await` callbacks
--- @param cancel? fun()
--- @return vim.async.Closable?
function M.closable(cancel)
  if cancel == nil then return end
  return {
    close = function(_, callback)
      cancel()
      if callback then callback() end
    end,
  }
end

return M
