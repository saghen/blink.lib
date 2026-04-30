local list = require('blink.lib._.list')
local utils = require('blink.lib.bench.utils')
local stats = require('blink.lib.bench.stats')
local Report = require('blink.lib.bench.report')
local color = require('blink.lib.bench.color')

--- @class blink.lib.bench
local M = {}

function M.setup()
  vim.api.nvim_create_user_command('BlinkBench', function(opts) M.run_files(opts.args) end, { nargs = '?' })
end

function M.run_files(filter)
  -- Collect lua/ dirs from current session's rtp as package.path entries
  -- (avoids adding to rtp which would trigger plugin/ftplugin auto-loading)
  local paths = {}
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    local lua_dir = rtp .. '/lua'
    if vim.uv.fs_stat(lua_dir) then
      paths[#paths + 1] = lua_dir .. '/?.lua'
      paths[#paths + 1] = lua_dir .. '/?/init.lua'
    end
  end

  -- Find bench files, optionally filtered by arg
  local files = vim.fn.glob('benches/**/*.lua', false, true)
  if filter and filter ~= '' then files = list.filter(function(f) return f:find(filter, 1, true) end, files) end
  if #files == 0 then return vim.notify('no bench files found', vim.log.levels.WARN, { title = 'blink.lib.bench' }) end

  -- Write a temp runner that sets package.path and dofiles each bench
  local runner = vim.fn.tempname() .. '.lua'
  local lines = {
    string.format('package.path = %q .. ";" .. package.path', table.concat(paths, ';')),
    -- set global `module` to cwd folder name
    string.format('require("blink.lib.bench").module = "%s"', vim.fs.basename(vim.fn.getcwd())),
  }
  for _, f in ipairs(files) do
    lines[#lines + 1] = string.format('dofile(%q)', vim.fn.fnamemodify(f, ':p'))
  end
  vim.fn.writefile(lines, runner)

  -- Open a scratch terminal buffer to the right
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_open_win(buf, true, { split = 'right' })
  vim.bo[buf].bufhidden = 'wipe'
  vim.fn.termopen({ 'nvim', '--clean', '--headless', '-l', runner })
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, silent = true })
end

function M.run_file()
  local file = vim.fs.relpath(vim.fn.getcwd(), vim.fn.expand('%:p'))
  M.run_files(file)
end

---------------------
--- Benchmarking API
---------------------

--- @param group string | string[]
--- @param default_opts? blink.lib.bench.RunOpts
--- @return blink.lib.bench.Group
function M.group(group, default_opts)
  if type(group) == 'string' then group = { group } end
  return {
    --- @param name string
    --- @param fn fun(): any
    --- @param opts? blink.lib.bench.RunOpts
    --- @return blink.lib.bench.Report
    run = function(name, fn, opts)
      opts = vim.tbl_extend('force', default_opts or {}, opts or {})
      opts.group = list.flatten({ group, opts.group or {} })
      return M.run(name, fn, opts)
    end,

    --- @param name string
    group = function(name) return M.group(vim.list_extend(vim.deepcopy(group), { name })) end,
  }
end

--- @class blink.lib.bench.RunOpts
--- @field group string[] Current group of benchmarks (default: {})
--- @field warmup string Time to spend warming up before starting measurements (default: 500ms)
--- @field measurement string Time to spend measuring (default: 5s)
--- @field min_samples integer Minimum number of samples to take (default: 10)
--- @field output boolean | 'verbose' Print output (default: true)
--- @field save boolean Save output to file (default: true)

--- @param name string
--- @param fn fun(): any
--- @param opts? blink.lib.bench.RunOpts
--- @return blink.lib.bench.Report
function M.run(name, fn, opts)
  opts = vim.tbl_extend(
    'force',
    { group = {}, warmup = '500ms', measurement = '5s', min_samples = 10, output = true, save = true },
    opts or {}
  )

  local warmup_ns = utils.parse_duration(opts.warmup)
  local measurement_ns = utils.parse_duration(opts.measurement)
  local hrtime = vim.uv.hrtime

  -- Phase 1: Warmup + find optimal batch size
  local warmup_end = hrtime() + warmup_ns
  local batch = 1
  local target_batch_ns = 1e6 -- ~10000x timer resolution (100µs)
  if jit then jit.flush() end -- clear JIT state

  while hrtime() < warmup_end do
    local t0 = hrtime()
    for _ = 1, batch do
      fn()
    end
    local elapsed = hrtime() - t0

    -- Scale batch toward target; cap growth so we don't overshoot
    if elapsed < target_batch_ns then
      local scale = math.max(2, math.min(10, target_batch_ns / math.max(elapsed, 1)))
      batch = math.ceil(batch * scale)
    else
      break
    end
  end

  -- Phase 2: Measurement
  local samples = {}
  local batch_sizes = {}
  local batch_times = {}
  local total_iters = 0
  local measure_start = hrtime()

  -- Cycle batch size through [batch, 2 * batch,  3 * batch] to measure overhead
  local sizes = { batch, math.ceil(batch * 2), batch * 3 }
  local idx = 1

  utils.with_manual_gc(function()
    while true do
      local now = hrtime()
      if now >= measure_start + measurement_ns and #samples >= opts.min_samples then break end

      local n = sizes[idx]
      idx = (idx % #sizes) + 1

      collectgarbage('collect')
      collectgarbage('collect') -- twice to handle finalizers
      local t0 = hrtime()
      for _ = 1, n do
        fn()
      end
      local elapsed = hrtime() - t0

      samples[#samples + 1] = elapsed / n
      batch_sizes[#batch_sizes + 1] = n
      batch_times[#batch_times + 1] = elapsed
      total_iters = total_iters + n
    end
  end)

  local report = Report.new(opts.module or M.module, opts.group, name, samples, total_iters, batch_sizes, batch_times)
  report.mean = stats.fit_slope(batch_sizes, batch_times)
  if opts.output then report:summary(opts.output == 'verbose') end
  if opts.save then report:save() end
  return report
end

return M
