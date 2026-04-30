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
  m = m or M.mean(t)
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

--- Bootstrap confidence interval for the regression slope (per-op cost)
--- Resamples (batch_sizes, batch_times) pairs and recomputes the slope each time,
--- so the CI is on the same estimator as the reported mean.
--- Returns (lower, upper) at confidence level (e.g. 0.95)
function M.bootstrap_ci_slope(batch_sizes, batch_times, confidence, resamples)
  resamples = resamples or 1000
  local n = #batch_sizes
  if n < 2 then return batch_times[1] / batch_sizes[1], batch_times[1] / batch_sizes[1] end

  local slopes = {}
  for r = 1, resamples do
    local sxx, sxy = 0, 0
    for _ = 1, n do
      local i = math.random(n)
      local x = batch_sizes[i]
      sxx = sxx + x * x
      sxy = sxy + x * batch_times[i]
    end
    slopes[r] = sxy / sxx
  end
  table.sort(slopes)
  local alpha = (1 - confidence) / 2
  return M.percentile(slopes, alpha), M.percentile(slopes, 1 - alpha)
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
