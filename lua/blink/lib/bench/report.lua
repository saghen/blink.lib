local stats = require('blink.lib.bench.stats')

function fmt_time(ns)
  if ns < 1e3 then return string.format('%.2f ns', ns) end
  if ns < 1e6 then return string.format('%.2f µs', ns / 1e3) end
  if ns < 1e9 then return string.format('%.2f ms', ns / 1e6) end
  return string.format('%.2f s', ns / 1e9)
end

--- @class blink.lib.bench.Report
local Report = {}
Report.__index = Report

function Report.new(name, samples, opts)
  local sorted = stats.sorted_copy(samples)
  local m = stats.mean(samples)
  local lo, hi = stats.bootstrap_ci(samples, opts.confidence, opts.bootstrap_resamples)

  return setmetatable({
    name = name,
    samples = samples, -- per-op ns, one per batch
    iterations = opts._iters, -- total operations measured
    duration_ns = opts._dur, -- total wall time spent measuring

    mean = m,
    median = stats.percentile(sorted, 0.5),
    min = sorted[1],
    max = sorted[#sorted],
    std_dev = stats.std_dev(samples, m),
    p95 = stats.percentile(sorted, 0.95),
    p99 = stats.percentile(sorted, 0.99),

    ci_lower = lo,
    ci_upper = hi,
    confidence = opts.confidence,

    outliers = stats.classify_outliers(sorted),
  }, Report)
end

function Report:summary()
  local lines = {}
  local function add(s, ...) lines[#lines + 1] = s:format(...) end

  add('%s', self.name)
  add(
    '  time:   %s  [%s .. %s]  (%.0f%% CI)',
    fmt_time(self.mean),
    fmt_time(self.ci_lower),
    fmt_time(self.ci_upper),
    self.confidence * 100
  )
  add('  median: %s   std dev: %s', fmt_time(self.median), fmt_time(self.std_dev))
  add(
    '  range:  %s .. %s   p95: %s   p99: %s',
    fmt_time(self.min),
    fmt_time(self.max),
    fmt_time(self.p95),
    fmt_time(self.p99)
  )
  add('  samples: %d   iterations: %d', #self.samples, self.iterations)

  local o = self.outliers
  if o.total > 0 then
    local pct = 100 * o.total / #self.samples
    add(
      '  outliers: %d (%.1f%%)  [mild: %d lo / %d hi,  severe: %d lo / %d hi]',
      o.total,
      pct,
      o.mild_low,
      o.mild_high,
      o.severe_low,
      o.severe_high
    )
    if pct > 10 then add('  !!! high outlier ratio !!!') end
  end

  vim.print(table.concat(lines, '\n'))
end

Report.__tostring = Report.summary

return Report
