local a = require('blink.lib.async')
local b = require('blink.lib.bench').group('event')

b.run('creation', function() a.event() end)

b.run('set and clear', function()
  local ev = a.event()
  ev:set()
  ev:clear()
end)

b.run('wait on already-set', function()
  local ev = a.event()
  ev:set()
  a.run(function() ev:wait() end):wait()
end)

b.run('waiter woken by set', function()
  local ev = a.event()
  local task = a.run(function() ev:wait() end)
  ev:set()
  task:wait()
end)

b.run('many waiters woken by set', function()
  local ev = a.event()
  local tasks = {}
  for _ = 1, 100 do
    tasks[#tasks + 1] = a.run(function() ev:wait() end)
  end
  ev:set()
  for _, t in ipairs(tasks) do t:wait() end
end)
