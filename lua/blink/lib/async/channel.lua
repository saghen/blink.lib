local await = require('blink.lib.async').await
local WaitQueue = require('blink.lib.async.wait_queue')

--- @class blink.lib.async.Channel<T>
--- @field capacity integer
--- @field private _buffer table<integer, any>
--- @field private _head integer
--- @field private _tail integer
--- @field private _closed boolean
--- @field private _senders blink.lib.async.WaitQueue
--- @field private _receivers blink.lib.async.WaitQueue
local Channel = {}
Channel.__index = Channel

function Channel.new(capacity)
  return setmetatable({
    capacity = capacity or 0,
    _buffer = {},
    _head = 1,
    _tail = 0,
    _closed = false,
    _senders = WaitQueue.new(),
    _receivers = WaitQueue.new(),
  }, Channel)
end

function Channel:send(value)
  if self._closed then error('send on closed channel', 2) end

  -- waiting receiver, pass value to it direclty
  if self._receivers:wake(nil, value) then return end

  -- space in buffer, insert
  if self._tail - self._head + 1 < self.capacity then
    self._tail = self._tail + 1
    self._buffer[self._tail] = value
  end

  -- buffer full, wait until receiver tells us to try again
  self._senders:wait()
  return self:send(value)
end

function Channel:try_send(value)
  if self._closed then error('send on closed channel', 2) end

  -- waiting receiver, pass value to it direclty
  if self._receivers:wake(nil, value) then return end

  -- space in buffer, insert
  if self._tail - self._head + 1 < self.capacity then
    self._tail = self._tail + 1
    self._buffer[self._tail] = value
    return
  end

  error('channel is full', 2)
end

function Channel:recv()
  -- buffer not empty, return value
  if self._head <= self._tail then
    local value = self._buffer[self._head]
    self._head = self._head + 1
    -- sender might be waiting for space, wake it
    self._senders:wake()
    return true, value
  end
  if self._closed then return false end

  -- sender will pass the value to the receiver via the callback directly
  local value = self._receivers:wait(function() self._senders:wake() end)
  return not self._closed, value
end

function Channel:try_recv()
  if self._head > self._tail then
    if self._closed then return false end
    error('channel is empty', 2)
  end

  local value = self._buffer[self._head]
  self._head = self._head + 1
  self._senders:wake() -- sender might be waiting for space, wake it
  return true, value
end

function Channel:iter()
  return function()
    local ok, val = self:recv()
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

function Channel:is_closing() return self._closed end

return Channel
