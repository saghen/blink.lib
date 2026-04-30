local await = require('blink.lib.async').await

--- Queue of tasks waiting to be resumed
--- Closed tasks are tombstoned; pop skips them.
--- @class blink.lib.async.WaitQueue
local WaitQueue = {}
WaitQueue.__index = WaitQueue

function WaitQueue.new() return setmetatable({ items = {}, head = 1, tail = 0 }, WaitQueue) end

function WaitQueue:len() return self.tail - self.head + 1 end

--- Wait for someone to wake us, automatically clearing from the queue when the task closes
--- @param cb? fun(): any
function WaitQueue:wait(cb)
  return await(function(await_cb)
    self.tail = self.tail + 1
    local idx = self.tail
    self.items[idx] = await_cb
    if cb then cb() end
    return function() self.items[idx] = nil end
  end)
end

--- Wakes the next non-tombstoned :await() callback
--- @return boolean task_woken Whether a task was woken
function WaitQueue:wake(...)
  while self.head <= self.tail do
    local cb = self.items[self.head]
    self.items[self.head] = nil
    self.head = self.head + 1
    if cb ~= nil then
      cb(...)
      return true
    end
  end
  return false
end

return WaitQueue
