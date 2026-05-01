local compare = require('benches.async.compare')

local group = compare('run()')
group('creation', function(a)
  a.run(function() end):wait()
end)
group('return value', function(a)
  a.run(function() return 1 end):wait()
end)
group('return multiple values', function(a)
  a.run(function() return 1, 2, 3, 4, 5 end):wait()
end)
group('rejection', function(a)
  a.run(function() error('nope', 0) end):pwait()
end)
group('close', function(a)
  a.run(function()
    a.await(function() end)
  end):close()
end)

local group = compare('await()')
group('sync', function(a)
  a.run(function()
    for _ = 1, 100 do
      a.await(function(cb) cb() end)
    end
  end):wait()
end)
group('async', function(a)
  a.run(function()
    for _ = 1, 100 do
      a.schedule()
    end
  end):wait()
end)
group('resolved future', function(a)
  local resolved = a.run(function() return 1 end)
  a.run(function()
    for _ = 1, 100 do
      a.await(resolved)
    end
  end):wait()
end)

local group = compare('parent/child')
group('implicit await children', function(a)
  a.run(function()
    local futures = {}
    for i = 1, 100 do
      futures[i] = a.run(function() return i end)
    end
  end):wait()
end)

group('explicit await children', function(a)
  a.run(function()
    local futures = {}
    for i = 1, 100 do
      futures[i] = a.run(function() return i end)
    end
    for _, t in ipairs(futures) do
      a.await(t)
    end
  end):wait()
end)

group('cancel children', function(a)
  a.run(function()
    local futures = {}
    for i = 1, 100 do
      futures[i] = a.run(function()
        a.await(function() end)
      end)
    end
  end):close()
end)

group('deeply nested', function(a)
  a.run(function()
    local function nest(depth)
      return a.run(function()
        if depth == 0 then return 0 end
        return a.await(nest(depth - 1)) + 1
      end)
    end
    return nest(50)
  end):wait()
end)
