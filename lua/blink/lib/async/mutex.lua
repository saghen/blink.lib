local WaitQueue = require('blink.lib.async.wait_queue')
local function pack_len(...) return { n = select('#', ...), ... } end

--- @class blink.lib.async.Mutex
--- @field private co? thread
--- @field private waiters blink.lib.async.WaitQueue
local Mutex = {}
Mutex.__index = Mutex

function Mutex.new() return setmetatable({ waiters = WaitQueue.new() }, Mutex) end
function Mutex:available() return self.co == nil end
function Mutex:is_held_by_current_task() return self.co == coroutine.running() end

function Mutex:with(fn)
  self:lock()
  local r = pack_len(pcall(fn))
  self:unlock()
  if not r[1] then error(r[2]) end
  return unpack(r, 2, r.n)
end

function Mutex:lock()
  if self.co ~= nil then self.waiters:await() end
  self.co = coroutine.running()
end

function Mutex:unlock()
  if self.co == nil then error('called unlock() on Mutex that was already unlocked', 2) end
  if self.co ~= coroutine.running() then error('unlock() called from coroutine that does not hold the lock', 2) end
  self.co = nil
  self.waiters:wake()
end

return Mutex
