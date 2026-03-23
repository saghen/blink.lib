--- @class blink.lib.Logger
--- @field path string
--- @field set_min_level fun(level: number)
--- @field open fun()
--- @field log fun(level: number, msg: string, ...: any)
--- @field trace fun(msg: string, ...: any)
--- @field debug fun(msg: string, ...: any)
--- @field info fun(msg: string, ...: any)
--- @field warn fun(msg: string, ...: any)
--- @field error fun(msg: string, ...: any)

--- @class blink.lib.LoggerTransportOptions
--- @field enabled? boolean
--- @field min_log_level? number

--- @class blink.lib.LoggerOptions
--- @field module_name string
--- @field console? blink.lib.LoggerTransportOptions
--- @field file? blink.lib.LoggerTransportOptions

local levels_to_str = {
  [vim.log.levels.TRACE] = 'TRACE',
  [vim.log.levels.DEBUG] = 'DEBUG',
  [vim.log.levels.INFO] = 'INFO',
  [vim.log.levels.WARN] = 'WARN',
  [vim.log.levels.ERROR] = 'ERROR',
}

--- @class blink.lib.log
local M = {}

--- @param opts blink.lib.LoggerOptions
--- @return blink.lib.Logger
function M.new(opts)
  opts.console = opts.console or {}
  opts.console.enabled = opts.console.enabled == nil or opts.console.enabled
  opts.console.min_log_level = opts.console.min_log_level or vim.log.levels.INFO

  opts.file = opts.file or {}
  opts.file.enabled = opts.file.enabled == nil or opts.file.enabled
  opts.file.min_log_level = opts.file.min_log_level or vim.log.levels.INFO

  local queued_lines = {}
  local path = vim.fn.stdpath('log') .. '/' .. opts.module_name .. '.log'
  local fd

  -- we dont want to spam errors, so if we fail to open or write to the file, ignore future attempts
  local failed = false
  local function write(msg)
    if fd == nil or failed then
      -- havent yet opened file
      if not failed then table.insert(queued_lines, msg) end
      return
    end

    vim.uv.fs_write(fd, msg .. '\n', nil, function(write_err)
      if write_err ~= nil and not failed then
        failed = true
        vim.notify(
          'Failed to write to log file at ' .. path .. ' for module ' .. opts.module_name .. ': ' .. write_err,
          vim.log.levels.ERROR
        )
      end
    end)
  end

  -- open log file and write queued lines
  vim.uv.fs_open(path, 'a', 438, function(open_err, _fd)
    if open_err or _fd == nil then
      failed = true
      vim.notify(
        'Failed to open log file at ' .. path .. ' for module ' .. opts.module_name .. ': ' .. open_err,
        vim.log.levels.ERROR
      )
      return
    end

    fd = _fd

    write(table.concat(queued_lines, '\n'))
    queued_lines = {}
  end)

  --- @param level number
  --- @param msg string
  --- @param ... any
  local function log(level, msg, ...)
    if level < opts.console.min_log_level and level < opts.file.min_log_level then return end

    -- if there are args, use `vim.inspect` to format non-primitives
    -- and `string.format` with the `msg`
    if select('#', ...) > 0 then
      local args = {}
      for i = 1, select('#', ...) do
        local o = select(i, ...)
        local type = type(o)
        if type == 'table' or type == 'function' or type == 'userdata' then
          table.insert(args, vim.inspect(o, { newline = '\n', indent = '  ' }))
        else
          table.insert(args, o)
        end
      end
      msg = msg:format(args)
    end

    msg = levels_to_str[level] .. ': ' .. msg .. '\n'

    if level >= opts.console.min_log_level then print(msg) end
    if level >= opts.file.min_log_level then write(msg) end
  end

  return {
    path = path,
    set_file_min_level = function(level) opts.file.min_log_level = level end,
    set_console_min_level = function(level) opts.console.min_log_level = level end,
    open = function() vim.cmd('edit ' .. path) end,
    log = log,
    trace = function(...) log(vim.log.levels.TRACE, ...) end,
    debug = function(...) log(vim.log.levels.DEBUG, ...) end,
    info = function(...) log(vim.log.levels.INFO, ...) end,
    warn = function(...) log(vim.log.levels.WARN, ...) end,
    error = function(...) log(vim.log.levels.ERROR, ...) end,
  }
end

return M
