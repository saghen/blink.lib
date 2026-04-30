local M = {}

function M.sorted_copy(t)
  local s = {}
  for i = 1, #t do
    s[i] = t[i]
  end
  table.sort(s)
  return s
end

function M.percentile(sorted, p)
  local n = #sorted
  if n == 0 then return 0 end
  local i = p * (n - 1) + 1
  local lo, hi = math.floor(i), math.ceil(i)
  if lo == hi then return sorted[lo] end
  return sorted[lo] + (i - lo) * (sorted[hi] - sorted[lo])
end

function M.mean(t)
  local s = 0
  for i = 1, #t do
    s = s + t[i]
  end
  return s / #t
end

function M.std_dev(t, m)
  m = m or mean(t)
  local s = 0
  for i = 1, #t do
    local d = t[i] - m
    s = s + d * d
  end
  return math.sqrt(s / math.max(#t - 1, 1))
end

--- Tukey outlier classification on raw samples
--- Returns counts of mild/severe low/high outliers
function M.classify_outliers(sorted)
  local q1 = M.percentile(sorted, 0.25)
  local q3 = M.percentile(sorted, 0.75)
  local iqr = q3 - q1
  local mild_lo, severe_lo = q1 - 1.5 * iqr, q1 - 3.0 * iqr
  local mild_hi, severe_hi = q3 + 1.5 * iqr, q3 + 3.0 * iqr
  local o = { mild_low = 0, severe_low = 0, mild_high = 0, severe_high = 0 }
  for i = 1, #sorted do
    local v = sorted[i]
    if v < severe_lo then
      o.severe_low = o.severe_low + 1
    elseif v < mild_lo then
      o.mild_low = o.mild_low + 1
    elseif v > severe_hi then
      o.severe_high = o.severe_high + 1
    elseif v > mild_hi then
      o.mild_high = o.mild_high + 1
    end
  end
  o.total = o.mild_low + o.severe_low + o.mild_high + o.severe_high
  return o
end

--- Bootstrap confidence interval for the mean
--- Returns (lower, upper) at confidence level (e.g. 0.95)
function M.bootstrap_ci(samples, confidence, resamples)
  resamples = resamples or 1000
  local n = #samples
  if n < 2 then return samples[1] or 0, samples[1] or 0 end

  local means = {}
  for r = 1, resamples do
    local sum = 0
    for _ = 1, n do
      sum = sum + samples[math.random(n)]
    end
    means[r] = sum / n
  end
  table.sort(means)
  local alpha = (1 - confidence) / 2
  return M.percentile(means, alpha), M.percentile(means, 1 - alpha)
end

--- Simple linear regression through the origin: y = k*x
--- Given batch sizes xs and batch times ys, returns per-op cost k.
--- Using through-origin fit because a batch of 0 ops takes 0 time.
function M.fit_slope(xs, ys)
  local sxx, sxy = 0, 0
  for i = 1, #xs do
    sxx = sxx + xs[i] * xs[i]
    sxy = sxy + xs[i] * ys[i]
  end
  return sxy / sxx
end

return M
