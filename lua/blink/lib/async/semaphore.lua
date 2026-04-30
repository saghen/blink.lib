local WaitQueue = require('blink.lib.async.wait_queue')
local pack_len = function(...) return { n = select('#', ...), ... } end

--- @class blink.lib.async.Semaphore
--- @field available integer
--- @field max integer
--- @field private waiters table<integer, blink.lib.Future<nil>>
local Semaphore = {}
Semaphore.__index = Semaphore

function Semaphore.new(permits)
  permits = permits or 1
  return setmetatable({ available = permits, max = permits, waiters = WaitQueue.new() }, Semaphore)
end

function Semaphore:with(fn)
  self:acquire()
  local r = pack_len(pcall(fn))
  self:release()
  if not r[1] then error(r[2]) end
  return unpack(r, 2, r.n)
end

--- @async
function Semaphore:acquire()
  if self.available == 0 then self.waiters:await() end
  self.available = self.available - 1
  assert(self.available >= 0, 'Semaphore value is negative')
end

--- @async
function Semaphore:release()
  if self.available >= self.max then error('Semaphore value is greater than max permits', 2) end
  self.available = self.available + 1
  -- wake up acquire() while we have permits
  while self.available > 0 and self.waiters:wake() do
  end
end

return Semaphore
