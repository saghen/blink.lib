local await = require('blink.lib.async').await

--- Simple queue with O(1) push, pop, and remove-by-handle.
--- Removed entries are tombstoned; pop skips them.
--- @class blink.lib.async.WaitQueue
local WaitQueue = {}
WaitQueue.__index = WaitQueue

function WaitQueue.new() return setmetatable({ items = {}, head = 1, tail = 0 }, WaitQueue) end

function WaitQueue:len() return self.tail - self.head + 1 end

--- Wait for someone to wake us, automatically clearing from the queue when the task closes
function WaitQueue:await(cb)
  return await(function(await_cb)
    self.tail = self.tail + 1
    local idx = self.tail
    self.items[idx] = await_cb
    if cb then cb() end
    return function() self.items[idx] = nil end
  end)
end

--- Wakes the next non-tombstoned :await() callback
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
