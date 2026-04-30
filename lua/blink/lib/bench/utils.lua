local M = {}

local function fmt_num(num, width)
  width = width or 6
  -- Count digits before the decimal point
  local intPart = math.floor(math.abs(num))
  local intDigits = (intPart == 0) and 1 or (math.floor(math.log(intPart, 10)) + 1)

  -- Account for negative sign
  if num < 0 then intDigits = intDigits + 1 end

  -- Decimal places = width - intDigits - 1 (for the dot)
  local decimals = width - intDigits - 1

  if decimals < 0 then
    -- Number too big, just return integer part truncated
    return string.format('%d', num):sub(1, width)
  end

  return string.format('%.' .. decimals .. 'f', num)
end

--- Convert nanonseconds to a human-readable string (e.g. 1.23 µs)
function M.fmt_time(ns, include_sign)
  local sign = include_sign and ns >= 0 and '+' or ''
  local abs = math.abs(ns)
  if abs < 1e3 then return string.format('%s%s ns', sign, fmt_num(abs)) end
  if abs < 1e6 then return string.format('%s%s µs', sign, fmt_num(abs / 1e3)) end
  if abs < 1e9 then return string.format('%s%s ms', sign, fmt_num(abs / 1e6)) end
  return string.format('%s%s s', sign, fmt_num(abs / 1e9))
end

function M.fmt_percent_delta(prev, curr)
  local sign = curr > prev and '+' or '-'
  return string.format('%s%s%%', sign, fmt_num(math.abs((curr - prev) / prev * 100), 7))
end

--- Parse "500ms", "2s", "1m", or a number (seconds) into nanoseconds
function M.parse_duration(d)
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

function M.with_manual_gc(fn)
  collectgarbage('stop')
  local ok, err = pcall(fn)
  collectgarbage('restart')
  if not ok then error(err) end
end

return M
