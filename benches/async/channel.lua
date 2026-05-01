local a = require('blink.lib.async')
local b = require('blink.lib.bench').group('channel')

b.run('creation', function() a.channel() end)

local rendezvous = b.group('rendezvous')

rendezvous.run('sender waits on receiver', function()
  local ch = a.channel()
  local sender = a.run(function()
    for _ = 1, 100 do
      ch:send(1)
    end
    ch:close()
  end)
  local receiver = a.run(function()
    for _ in ch:iter() do
      -- do nothing
    end
  end)
  sender:wait()
  receiver:wait()
end)

rendezvous.run('receiver waits on sender', function()
  local ch = a.channel()
  local receiver = a.run(function()
    for _ in ch:iter() do
      -- do nothing
    end
  end)
  local sender = a.run(function()
    for _ = 1, 100 do
      ch:send(1)
    end
    ch:close()
  end)
  sender:wait()
  receiver:wait()
end)

local buffered = b.group('buffered')
buffered.run('no waiting', function()
  local ch = a.channel(100)
  for _ = 1, 100 do
    ch:send(1)
  end
  ch:close()
  for _ in ch:iter() do
    -- do nothing
  end
end)

buffered.run('receiver waits on sender', function()
  local ch = a.channel(100)
  local receiver = a.run(function()
    for _ in ch:iter() do
      -- do nothing
    end
  end)
  for _ = 1, 100 do
    ch:send(1)
  end
  ch:close()
  receiver:wait()
end)
