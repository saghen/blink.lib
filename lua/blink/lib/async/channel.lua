local await = require('blink.lib.async').await
local WaitQueue = require('blink.lib.async.wait_queue')

--- @class blink.lib.async.Channel
local Channel = {}
Channel.__index = Channel

function Channel.new(capacity)
  return setmetatable(
    { _capacity = capacity or 0, _buffer = {}, _senders = WaitQueue.new(), _receivers = WaitQueue.new() },
    Channel
  )
end

function Channel:send(value)
  if self._closed then error('send on closed channel') end
  -- waiting receiver, pass value to it
  if self._receivers:wake(nil, value) then return end
  -- space in buffer, insert
  if #self._buffer < self._capacity then return table.insert(self._buffer, value) end

  -- wait until receiver tells us to try again
  self._senders:await()
  return self:send(value)
end

function Channel:receive()
  if #self._buffer > 0 then
    local value = table.remove(self._buffer, 1)
    -- sender might be waiting for space, wake it
    self._senders:wake()
    return true, value
  end
  if self._closed then return false end

  -- sender will pass the value to the receiver via the callback directly
  local value = self._receivers:await(function() self._senders:wake() end)
  return not self._closed, value
end

function Channel:iter()
  return function()
    local ok, val = self:receive()
    if ok then return val end
  end
end

function Channel:close()
  if self._closed then return end
  self._closed = true
  while self._senders:wake('send on closed channel') do
  end
  while self._receivers:wake() do
  end
end

function Channel:is_closed() return self._closed end

return Channel
