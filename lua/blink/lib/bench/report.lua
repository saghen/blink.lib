local list = require('blink.lib._.list')
local fmt_time = require('blink.lib.bench.utils').fmt_time
local fmt_percent_delta = require('blink.lib.bench.utils').fmt_percent_delta
local color = require('blink.lib.bench.color')
local stats = require('blink.lib.bench.stats')

--- @class blink.lib.bench.Report
local Report = {}
Report.__index = Report

--- @param module string
--- @param group string[]
--- @param name string
--- @param samples number[]
--- @param iterations integer
--- @param batch_sizes integer[]
--- @param batch_times number[]
function Report.new(module, group, name, samples, iterations, batch_sizes, batch_times)
  local sorted = stats.sorted_copy(samples)
  local lo, hi = stats.bootstrap_ci_slope(batch_sizes, batch_times, 0.95, 1000)

  local file_name = table.concat(list.flatten({ group, name }), '.') .. '.json'
  local file_path = vim.fs.joinpath(vim.fn.stdpath('state'), 'blink', 'bench', module, file_name)

  return setmetatable({
    module = module,
    group = group,
    name = name,
    file_path = file_path,
    prev = Report.load(file_path),

    num_samples = #samples,
    iterations = iterations, -- total operations measured

    mean = stats.fit_slope(batch_sizes, batch_times),
    median = stats.percentile(sorted, 0.5),
    min = sorted[1],
    max = sorted[#sorted],
    std_dev = stats.std_dev(samples),
    p95 = stats.percentile(sorted, 0.95),
    p99 = stats.percentile(sorted, 0.99),

    ci_lower = lo,
    ci_upper = hi,
    confidence = 0.95,

    outliers = stats.classify_outliers(sorted),
  }, Report)
end

function Report:save()
  local report = vim.deepcopy(self)
  report.prev = nil
  vim.fn.mkdir(vim.fs.dirname(self.file_path), 'p')
  vim.fn.writefile({ vim.json.encode(report) }, self.file_path)
end
function Report.load(file_path)
  if vim.uv.fs_stat(file_path) == nil then return end
  return setmetatable(vim.json.decode(table.concat(vim.fn.readfile(file_path), '\n')), Report)
end

function Report:format_name()
  if #self.group == 0 then return string.format('{magenta}%s{/}', self.name) end
  return string.format('{bold}%s / {magenta}%s{/}', table.concat(self.group, ' / '), self.name)
end

function Report:compare(baseline)
  local lines = {}
  local function add(s, ...) lines[#lines + 1] = color.format(s, ...) end

  local delta = self.mean - baseline.mean
  local pct = delta / baseline.mean * 100

  local ci_overlap = self.ci_lower < baseline.ci_upper and baseline.ci_lower < self.ci_upper
  local significant = not ci_overlap and math.abs(pct) >= 2

  add('%s  vs  %s', self:format_name(), self:format_name())

  local self_mean = self.mean
  local baseline_mean = baseline.mean
  local delta = baseline_mean - self_mean
  local pct = delta / baseline_mean * 100
  add(
    '  {cyan}%-10s{/} %s  vs  %s   Δ {%s}%s  (%+.2f%%){/}',
    'time:',
    color.style('bold', self_mean < baseline_mean and significant, fmt_time(self_mean)),
    color.style('bold', baseline_mean < self_mean and significant, fmt_time(baseline_mean)),
    not significant and 'dim' or (delta > 0 and 'bright_green' or 'bright_red'),
    fmt_time(delta, true),
    pct
  )

  add(
    '  {cyan}%-10s{/} [%s .. %s]  vs  [%s .. %s]%s',
    'interval:',
    fmt_time(self.ci_lower),
    fmt_time(self.ci_upper),
    fmt_time(baseline.ci_lower),
    fmt_time(baseline.ci_upper),
    ci_overlap and '' or color.format('  {yellow}(no overlap){/}')
  )

  if not significant then
    add('{dim}no significant difference{/}')
  elseif delta < 0 then
    add('{bold,blue}%s{/}: {bright_red}slower{/} by {bright_red}%.2f%%{/}', baseline.name, math.abs(pct))
  else
    add('{bold,magenta}%s{/}: {bright_green}faster{/} by {bright_green}%.2f%%{/}', self.name, math.abs(pct))
  end

  color.print(table.concat(lines, '\n') .. '\n')
end

function Report:summary(verbose)
  local lines = {}
  local function add(s, ...) lines[#lines + 1] = color.format(s, ...) end

  add(self:format_name())
  add(
    '  {cyan}%-10s{/} [{dim}%s{/} {bold}%s{/} {dim}%s{/}]',
    'time:',
    fmt_time(self.ci_lower),
    fmt_time(self.mean),
    fmt_time(self.ci_upper)
  )
  if verbose then
    add('  {cyan}%-10s{/} %-12s {cyan}%s{/} %s', 'mean:', fmt_time(self.mean), 'std dev:', fmt_time(self.std_dev))
    add(
      '  {cyan}%-10s{/} %s .. %s   {cyan}%s{/} %s   {cyan}%s{/} %s',
      'range:',
      fmt_time(self.min),
      fmt_time(self.max),
      'p95:',
      fmt_time(self.p95),
      'p99:',
      fmt_time(self.p99)
    )
    add('  {cyan}%-10s{/} %-12d {cyan}%s{/} %d', 'samples:', self.num_samples, 'iterations:', self.iterations)
  end

  -- Compare to previous run
  if self.prev then
    local pct_delta = math.abs((self.prev.mean - self.mean) / self.prev.mean * 100)
    add(
      '  {cyan}%-10s{/} [{dim}%s{/} {bold,%s}%s{/} {dim}%s{/}]%s',
      'change:',
      fmt_percent_delta(self.prev.ci_lower, self.ci_lower),
      pct_delta < 2 and '' or self.mean > self.prev.mean and 'bright_red' or 'bright_green',
      fmt_percent_delta(self.prev.mean, self.mean),
      fmt_percent_delta(self.prev.ci_upper, self.ci_upper),
      pct_delta < 2 and '  {cyan}insignificant (<2%){/}' or ''
    )
  end

  -- Outliers
  local o = self.outliers
  if o.total > 0 then
    local pct = 100 * o.total / self.num_samples
    if pct > 5 or verbose then
      local outlier_color = pct > 10 and 'bright_red' or pct > 5 and 'yellow' or 'dim'
      local outlier_str = string.format('%d (%.1f%%)', o.total, pct)

      add(
        '  {cyan}%-10s{/} {%s}%-12s{/} {dim}[mild: %d lo / %d hi,  severe: %d lo / %d hi]{/}',
        'outliers:',
        outlier_color,
        outlier_str,
        o.mild_low,
        o.mild_high,
        o.severe_low,
        o.severe_high
      )
      if pct > 10 then add('  {bold,bright_red}!!! high outlier ratio !!!{/}') end
    end
  end

  color.print(table.concat(lines, '\n') .. '\n')
end

Report.__tostring = Report.summary

return Report
