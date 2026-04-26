-- run with: nvim --headless -l tests/benchmark_async.lua

-- TODO: adjust path to point to your async.nvim installation
package.path = package.path .. ';./lua/?.lua;../async.nvim/lua/?.lua'

local blink = require('blink.lib.async')
local nvim = require('async')

------------------
--- Benchmark utilities
------------------

local results = { blink = {}, nvim = {} }
local ordered_names = {}

local function bench(store, name, iters, fn, is_async)
  local run = is_async and function() fn():wait(5000) end or fn

  for _ = 1, math.min(is_async and 10 or 100, iters) do
    run()
  end
  collectgarbage('collect')

  local start = vim.uv.hrtime()
  for _ = 1, iters do
    run()
  end
  local elapsed = vim.uv.hrtime() - start

  if not store[name] then ordered_names[#ordered_names + 1] = name end
  store[name] = elapsed / iters
  print(string.format('  %-50s %10d iter  %10.3f µs/op', name, iters, elapsed / iters / 1e3))
end

------------------
--- Adapters
------------------

local blink_adapter = {
  run = blink.run,
  await_task = function(t) return t:await() end,
  await_cb = blink.wrap,
  await_cb_deferred = function() return blink.wrap(vim.schedule) end,
  cancel = function(t) t:cancel() end,
  wait_cb = function(t, cb) t:wait(cb) end,
  wait_sync = function(t) t:wait() end,
  pwait_sync = function(t) t:pwait() end,
  await_never = function()
    blink.wrap(function(_) end)
  end,
  await_never_cleanup = function()
    blink.wrap(function(_)
      return function() end
    end)
  end,
  drain_rejected = function(_) end,
}

local nvim_adapter = {
  run = nvim.run,
  await_task = nvim.await,
  await_cb = nvim.await,
  await_cb_deferred = function() return nvim.await(vim.schedule) end,
  cancel = function(t) t:close() end,
  wait_cb = function(t, cb) t:wait(cb) end,
  wait_sync = function(t) t:wait(0) end,
  pwait_sync = function(t) t:pwait(0) end,
  await_never = function()
    nvim.await(function(_) end)
  end,
  await_never_cleanup = function()
    nvim.await(function(_)
      return {
        close = function(_, cb)
          if cb then cb() end
        end,
      }
    end)
  end,
  drain_rejected = function(t) t:pwait(0) end,
}

------------------
--- Suite
------------------

local function make_suite(a)
  local sync_cb = function(cb) cb() end
  return {
    { section = 'Task creation & synchronous completion' },
    {
      'run with empty fn (sync resolve)',
      100000,
      function()
        a.run(function() end)
      end,
    },
    {
      'run returning value (sync resolve)',
      100000,
      function()
        a.run(function() return 42 end)
      end,
    },
    {
      'run returning multiple values',
      100000,
      function()
        a.run(function() return 1, 2, 3, 4, 5 end)
      end,
    },
    {
      'run with rejection (error)',
      100000,
      function()
        a.drain_rejected(a.run(function() error('nope', 0) end))
      end,
    },

    { section = 'wrap / await (sync callback)' },
    {
      'await immediate sync callback',
      50000,
      async = true,
      function()
        return a.run(function() a.await_cb(sync_cb) end)
      end,
    },
    {
      'await immediate 10x in sequence',
      10000,
      async = true,
      function()
        return a.run(function()
          for _ = 1, 10 do
            a.await_cb(sync_cb)
          end
        end)
      end,
    },
    {
      'await immediate 100x in sequence',
      1000,
      async = true,
      function()
        return a.run(function()
          for _ = 1, 100 do
            a.await_cb(sync_cb)
          end
        end)
      end,
    },

    { section = 'await (deferred callback via vim.schedule)' },
    {
      'await vim.schedule callback',
      5000,
      async = true,
      function()
        return a.run(function() a.await_cb_deferred() end)
      end,
    },
    {
      '10x vim.schedule in sequence',
      1000,
      async = true,
      function()
        return a.run(function()
          for _ = 1, 10 do
            a.await_cb_deferred()
          end
        end)
      end,
    },

    { section = 'Task:await' },
    {
      'await already-resolved task',
      50000,
      async = true,
      function()
        local resolved = a.run(function() return 1 end)
        return a.run(function() a.await_task(resolved) end)
      end,
    },
    {
      'await chain of 10 tasks',
      5000,
      async = true,
      function()
        return a.run(function()
          for _ = 1, 10 do
            a.await_task(a.run(function() return 1 end))
          end
        end)
      end,
    },

    { section = 'Parent/child relationships' },
    {
      'spawn 10 child tasks (awaited)',
      5000,
      async = true,
      function()
        return a.run(function()
          local tasks = {}
          for i = 1, 10 do
            tasks[i] = a.run(function() return i end)
          end
          for _, t in ipairs(tasks) do
            a.await_task(t)
          end
        end)
      end,
    },
    {
      'spawn 100 child tasks (awaited)',
      500,
      async = true,
      function()
        return a.run(function()
          local tasks = {}
          for i = 1, 100 do
            tasks[i] = a.run(function() return i end)
          end
          for _, t in ipairs(tasks) do
            a.await_task(t)
          end
        end)
      end,
    },
    {
      'deeply nested run (depth 50)',
      1000,
      async = true,
      function()
        local function nest(depth)
          return a.run(function()
            if depth == 0 then return 0 end
            return a.await_task(nest(depth - 1)) + 1
          end)
        end
        return nest(50)
      end,
    },

    { section = 'Cancellation' },
    {
      'cancel pending task (no cleanup)',
      50000,
      function()
        a.cancel(a.run(function() a.await_never() end))
      end,
    },
    {
      'cancel pending task (with cleanup hook)',
      50000,
      function()
        a.cancel(a.run(function() a.await_never_cleanup() end))
      end,
    },
    {
      'cancel parent with 10 pending children',
      10000,
      function()
        a.cancel(a.run(function()
          for _ = 1, 10 do
            a.run(function() a.await_never() end)
          end
          a.await_never()
        end))
      end,
    },
    {
      'cancel parent with 100 pending children',
      1000,
      function()
        a.cancel(a.run(function()
          for _ = 1, 100 do
            a.run(function() a.await_never() end)
          end
          a.await_never()
        end))
      end,
    },

    { section = 'Settlement callbacks' },
    {
      'resolve with 0 callbacks',
      100000,
      function()
        a.run(function() end)
      end,
    },
    {
      'resolve with 10 callbacks attached',
      20000,
      function()
        local t = a.run(function() a.await_cb(sync_cb) end)
        for _ = 1, 10 do
          a.wait_cb(t, function() end)
        end
      end,
    },

    { section = 'pwait / wait variants' },
    {
      'Task:wait on resolved task',
      100000,
      function()
        a.wait_sync(a.run(function() return 1 end))
      end,
    },
    {
      'Task:pwait on resolved task',
      100000,
      function()
        a.pwait_sync(a.run(function() return 1 end))
      end,
    },
    {
      'Task:pwait on rejected task',
      100000,
      function()
        a.pwait_sync(a.run(function() error('x', 0) end))
      end,
    },
    {
      'Task:wait with callback (resolved)',
      100000,
      function()
        a.wait_cb(a.run(function() return 1 end), function() end)
      end,
    },

    { section = 'Real-world-ish patterns' },
    {
      'producer/consumer via 10 awaits',
      2000,
      async = true,
      function()
        return a.run(function()
          local sum = 0
          for i = 1, 10 do
            sum = sum + a.await_task(a.run(function() return i * 2 end))
          end
          return sum
        end)
      end,
    },
    {
      'fan-out 20 then join',
      1000,
      async = true,
      function()
        return a.run(function()
          local tasks = {}
          for i = 1, 20 do
            tasks[i] = a.run(function()
              a.await_cb(sync_cb)
              return i
            end)
          end
          local sum = 0
          for _, t in ipairs(tasks) do
            sum = sum + a.await_task(t)
          end
          return sum
        end)
      end,
    },
  }
end

------------------
--- Run suites
------------------

local function run_suite(label, adapter, store)
  print('\n' .. string.rep('=', 80) .. '\n' .. label .. '\n' .. string.rep('=', 80))
  for _, e in ipairs(make_suite(adapter)) do
    if e.section then
      print('\n── ' .. e.section .. ' ' .. string.rep('─', 60 - #e.section))
    else
      bench(store, e[1], e[2], e[3], e.async)
    end
  end
end

run_suite('blink.lib.async', blink_adapter, results.blink)
run_suite('async.nvim', nvim_adapter, results.nvim)

------------------
--- Comparison table
------------------

print('\n' .. string.rep('=', 90))
print('Comparison (blink.lib.async vs async.nvim)')
print(string.rep('=', 90))
print(string.format('  %-50s %14s %14s %10s', 'benchmark', 'nvim µs/op', 'blink µs/op', 'Δ%'))
print('  ' .. string.rep('-', 89))

local sum_b, sum_n, best_b, best_n = 0, 0, 0, 0
for _, name in ipairs(ordered_names) do
  local b, nv = results.blink[name], results.nvim[name]
  if b and nv then
    local diff = (b - nv) / nv * 100
    if diff > 0 then
      best_b = best_b + 1
    else
      best_n = best_n + 1
    end
    print(string.format('  %-49s %14.3f%14.3f %+9.1f%%', name, nv / 1e3, b / 1e3, diff))
    sum_b, sum_n = sum_b + b, sum_n + nv
  end
end

print('  ' .. string.rep('-', 89))
print(string.rep('=', 90))
