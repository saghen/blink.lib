package.path = package.path .. ';../async.nvim/lua/?.lua'

local blink = require('blink.lib.async')
local nvim = require('async')

local blink_adapter = {
  run = blink.run,
  await = blink.await,
  schedule = function() return blink.await(vim.schedule) end,
  await_never_cleanup = function()
    blink.await(function(_)
      return function() end
    end)
  end,
}

local nvim_adapter = {
  run = nvim.run,
  await = nvim.await,
  schedule = function() return nvim.await(vim.schedule) end,
  await_never_cleanup = function()
    nvim.await(function(_)
      return {
        close = function(_, cb)
          if cb then cb() end
        end,
      }
    end)
  end,
}

local function compare(group)
  local flatten = require('blink.lib._.list.flatten')
  local b = require('blink.lib.bench')

  local opts = { warmup = '200ms', measurement = '1s', output = false }
  local nvim_group = b.group(flatten({ 'nvim', group }), opts)
  local blink_group = b.group(flatten({ 'blink', group }), opts)

  return function(name, fn)
    local r1 = blink_group.run(name, function() return fn(blink_adapter) end)
    local r2 = nvim_group.run(name, function() return fn(nvim_adapter) end)
    r1:compare(r2)
    -- io.write('-------------------\n')
  end
end
return compare
