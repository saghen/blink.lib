local async = require('blink.lib.async')
--- @class blink.lib.async.Event
local Event = {}
Event.__index = Event

function Event.new() return setmetatable({ _set = false, _waiters = {} }, Event) end
function Event:is_set() return self._set end

function Event:set()
  if self._set then return end
  self._set = true
  local waiters = self._waiters
  for _, waiter in ipairs(waiters) do
    if waiter then waiter() end
  end
  self._waiters = nil
end

function Event:wait()
  if self._set then return end
  async.await(function(cb)
    local idx = #self._waiters + 1
    self._waiters[idx] = cb
    return function() self._waiters[idx] = false end -- cleanup on close
  end)
end

return Event
