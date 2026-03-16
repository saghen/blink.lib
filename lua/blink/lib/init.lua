local function lazy_require(module_name)
  local module
  return setmetatable({}, {
    __index = function(_, key)
      if module == nil then module = require(module_name) end
      return module[key]
    end,
    __newindex = function(_, key, value)
      if module == nil then module = require(module_name) end
      module[key] = value
    end,
    __call = function(_, ...)
      if module == nil then module = require(module_name) end
      return module(...)
    end,
  })
end

return {
  --- @type blink.lib.build
  build = lazy_require('blink.lib.build'),
  --- @type blink.lib.config
  config = lazy_require('blink.lib.config'),
  --- @type blink.lib.download
  download = lazy_require('blink.lib.download'),
  --- @type blink.lib.fs
  fs = lazy_require('blink.lib.fs'),
  --- @type blink.lib.log
  log = lazy_require('blink.lib.log'),
  --- @type blink.lib.Task
  task = lazy_require('blink.lib.task'),
  --- @type blink.lib.nvim
  nvim = lazy_require('blink.lib.nvim'),
  --- @type blink.lib.timer
  timer = lazy_require('blink.lib.timer'),
}
