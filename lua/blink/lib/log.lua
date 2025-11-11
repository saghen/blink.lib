--- @class blink.lib.Logger
--- @field set_min_level fun(level: number)
--- @field open fun()
--- @field log fun(level: number, msg: string, ...: any)
--- @field trace fun(msg: string, ...: any)
--- @field debug fun(msg: string, ...: any)
--- @field info fun(msg: string, ...: any)
--- @field warn fun(msg: string, ...: any)
--- @field error fun(msg: string, ...: any)

local levels_to_str = {
  [vim.log.levels.TRACE] = 'TRACE',
  [vim.log.levels.DEBUG] = 'DEBUG',
  [vim.log.levels.INFO] = 'INFO',
  [vim.log.levels.WARN] = 'WARN',
  [vim.log.levels.ERROR] = 'ERROR',
}

--- @class blink.lib.log
local M = {}

--- @param module_name string
--- @param min_log_level? number
--- @return blink.lib.Logger
function M.new(module_name, min_log_level)
  min_log_level = min_log_level or vim.log.levels.INFO

  local queued_lines = {}
  local path = vim.fn.stdpath('log') .. '/' .. module_name .. '.log'
  local fd

  vim.uv.fs_open(path, 'a', 438, function(err, _fd)
    if err or _fd == nil then
      fd = nil
      vim.notify(
        'Failed to open log file at ' .. path .. ' for module ' .. module_name .. ': ' .. (err or 'Unknown error'),
        vim.log.levels.ERROR
      )
      return
    end

    fd = _fd

    for _, line in ipairs(queued_lines) do
      local _, _, write_err_msg = vim.uv.fs_write(fd, line, 0)
      if write_err_msg ~= nil then error('Failed to write to log file: ' .. (write_err_msg or 'Unknown error')) end
    end
    queued_lines = {}
  end)

  --- @param level number
  --- @param msg string
  --- @param ... any
  local function log(level, msg, ...)
    -- failed to initialize, ignore
    if fd == false then return end

    if level < min_log_level then return end
    if #... > 0 then msg = msg:format(...) end

    local line = levels_to_str[level] .. ': ' .. msg .. '\n'

    if fd == nil then
      table.insert(queued_lines, line)
    else
      local _, _, write_err_msg = vim.uv.fs_write(fd, line, 0)
      if write_err_msg ~= nil then error('Failed to write to log file: ' .. (write_err_msg or 'Unknown error')) end
    end
  end

  return {
    set_min_level = function(level) min_log_level = level end,
    open = function() vim.cmd('edit ' .. path) end,
    log = log,
    trace = function(msg, ...) log(vim.log.levels.TRACE, msg, ...) end,
    debug = function(msg, ...) log(vim.log.levels.DEBUG, msg, ...) end,
    info = function(msg, ...) log(vim.log.levels.INFO, msg, ...) end,
    warn = function(msg, ...) log(vim.log.levels.WARN, msg, ...) end,
    error = function(msg, ...) log(vim.log.levels.ERROR, msg, ...) end,
  }
end

return M
