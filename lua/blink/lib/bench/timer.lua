if not vim.tbl_contains({ 'linux', 'osx', 'bsd' }, jit.os:lower()) then return vim.uv.hrtime end

local ffi_ok, ffi = pcall(require, 'ffi')
if not ffi_ok then return vim.uv.hrtime end

local ok = pcall(
  ffi.cdef,
  [[
    typedef long time_t;
    struct blink_timespec { time_t tv_sec; long tv_nsec; };
    int clock_gettime(int clk_id, struct blink_timespec *tp);
  ]]
)
if not ok then return nil end

-- CLOCK_MONOTONIC_RAW = 4 on Linux; CLOCK_MONOTONIC = 1 elsewhere.
local clock_id = (ffi.os == 'Linux') and 4 or 1
local ts = ffi.new('struct blink_timespec[1]')
local C = ffi.C

-- Probe that the symbol exists.
if not pcall(function() C.clock_gettime(clock_id, ts) end) then
  -- Try CLOCK_MONOTONIC as a fallback for clk_id.
  clock_id = 1
  -- fallback to uv.hrtime
  if not pcall(function() C.clock_gettime(clock_id, ts) end) then return vim.uv.hrtime end
end

local function now()
  C.clock_gettime(clock_id, ts)
  return tonumber(ts[0].tv_sec) * 1e9 + tonumber(ts[0].tv_nsec)
end
return now
