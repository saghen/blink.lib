local stats = require('blink.lib.bench.stats')
local Report = require('blink.lib.bench.report')

local M = {}

--- Opaque sink to defeat dead-code elimination.
--- Users call bench.black_box(v) to ensure `v` is considered used.
local _sink
function M.black_box(v)
  _sink = v
  return v
end

--- Parse "500ms", "2s", "1m", or a number (seconds) into nanoseconds.
local function parse_duration(d)
  if type(d) == 'number' then return d * 1e9 end
  local n, unit = d:match('^(%d+%.?%d*)(%a+)$')
  assert(n, 'invalid duration: ' .. tostring(d))
  n = tonumber(n)
  if unit == 'ns' then return n end
  if unit == 'us' then return n * 1e3 end
  if unit == 'ms' then return n * 1e6 end
  if unit == 's' then return n * 1e9 end
  if unit == 'm' then return n * 60e9 end
  error('unknown unit: ' .. unit)
end

local DEFAULTS = {
  warmup = '500ms',
  measurement = '5s',
  min_samples = 10,
  confidence = 0.95,
  bootstrap_resamples = 1000,
}

--- @class blink.lib.bench.RunOpts
--- @field warmup string Time to spend warming up before starting measurements (default: 500ms)
--- @field measurement string Time to spend measuring (default: 5s)
--- @field min_samples integer Minimum number of samples to take (default: 10)
--- @field confidence number Confidence level for statistical analysis (default: 0.95)
--- @field bootstrap_resamples integer

--- @param name string
--- @param fn fun(): any
--- @param opts? blink.lib.bench.RunOpts
--- @return blink.lib.bench.Report
function M.run(name, fn, opts)
  opts = vim.tbl_extend('force', DEFAULTS, opts or {})
  local warmup_ns = parse_duration(opts.warmup)
  local measurement_ns = parse_duration(opts.measurement)
  local hrtime, black_box = require('blink.lib.bench.timer'), M.black_box

  -- Clear JIT state for consistent warmup
  if jit then
    jit.flush()
    jit.on()
  end

  -- Phase 1: Warmup + find optimal batch size
  local warmup_end = hrtime() + warmup_ns
  local batch = 1
  local target_batch_ns = 1e6 -- ~10000x timer resolution (100µs)

  while hrtime() < warmup_end do
    local t0 = hrtime()
    for _ = 1, batch do
      black_box(fn())
    end
    local elapsed = hrtime() - t0

    -- Scale batch toward target; cap growth so we don't overshoot.
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
  local measure_end = measure_start + measurement_ns

  -- Cycle batch size through [batch, 1.5 * batch,  2 * batch] to measure overhead
  local sizes = { batch, math.ceil(batch * 1.5), batch * 2 }
  local idx = 1

  collectgarbage('stop')
  while true do
    local now = hrtime()
    if now >= measure_end and #samples >= opts.min_samples then break end

    local n = sizes[idx]
    idx = (idx % #sizes) + 1

    collectgarbage('collect')
    collectgarbage('collect') -- twice to handle finalizers
    local t0 = hrtime()
    for _ = 1, n do
      black_box(fn())
    end
    local elapsed = hrtime() - t0

    samples[#samples + 1] = elapsed / n
    batch_sizes[#batch_sizes + 1] = n
    batch_times[#batch_times + 1] = elapsed
    total_iters = total_iters + n
  end
  collectgarbage('restart')

  local total_duration = hrtime() - measure_start

  local report = Report.new(name, samples, {
    confidence = opts.confidence,
    bootstrap_resamples = opts.bootstrap_resamples,
    _iters = total_iters,
    _dur = total_duration,
  })

  -- Prefer the regression estimate for the headline mean (removes timer overhead)
  report.mean = stats.fit_slope(batch_sizes, batch_times)

  return report
end

return M
