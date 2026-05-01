local a = require('blink.lib.async')
local b = require('blink.lib.bench').group('semaphore')

b.run('creation', function() a.semaphore(10) end)

b.run('uncontended acquire/release', function()
  local s = a.semaphore(1)
  a.run(function()
    for _ = 1, 100 do
      s:acquire()
      s:release()
    end
  end):wait()
end)

b.run('contended: single permit', function()
  local s = a.semaphore(1)
  local tasks = {}
  for _ = 1, 100 do
    tasks[#tasks + 1] = a.run(function()
      s:acquire()
      s:release()
    end)
  end
  for _, t in ipairs(tasks) do t:wait() end
end)

b.run('multiple permits: bounded concurrency', function()
  local s = a.semaphore(10)
  local tasks = {}
  for _ = 1, 100 do
    tasks[#tasks + 1] = a.run(function()
      s:acquire()
      s:release()
    end)
  end
  for _, t in ipairs(tasks) do t:wait() end
end)
