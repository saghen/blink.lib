local log = {}

--- @param module_name string
--- @param min_log_level number
function log.new(module_name, min_log_level)
  local path = vim.fn.stdpath('log') .. '/' .. module_name .. '.log'

  return setmetatable({
    module_name = module_name,
    min_log_level = min_log_level,
    path = path,
  }, { __index = log })
end

function log:set_min_level(level) self.min_log_level = level end

function log:open() vim.cmd('edit ' .. self.path) end

function log:log(level, msg)
  if level < self.min_log_level then return end
end

function log:trace(msg) end
function log:debug(msg) end
function log:info(msg) end
function log:warn(msg) end
function log:error(msg) end

return log
