local a = require('blink.lib.async')
local b = require('blink.lib.bench').group('mutex')

b.run('creation', function() a.mutex() end)

b.run('uncontended lock/unlock', function()
  local m = a.mutex()
  a.run(function()
    for _ = 1, 100 do
      m:lock()
      m:unlock()
    end
  end):wait()
end)

b.run('contended: serial waiters', function()
  local m = a.mutex()
  local tasks = {}
  for _ = 1, 100 do
    tasks[#tasks + 1] = a.run(function()
      m:lock()
      m:unlock()
    end)
  end
  for _, t in ipairs(tasks) do t:wait() end
end)

b.run('with()', function()
  local m = a.mutex()
  a.run(function()
    for _ = 1, 100 do
      m:with(function() end)
    end
  end):wait()
end)
