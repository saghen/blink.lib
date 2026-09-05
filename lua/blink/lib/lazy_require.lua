local function lazy_require(module_name)
  ---@type any
  local module
  return setmetatable({}, {
    __index = function(_, key)
      if module == nil then module = require(module_name) end
      return module[key]
    end,
    __call = function(_, ...)
      if module == nil then module = require(module_name) end
      return module(...)
    end,
  })
end

return lazy_require
