local require = require('blink.lib.lazy_require')
return {
  async = require('blink.lib.async'),
  build = require('blink.lib.build'),
  config = require('blink.lib.config'),
  download = require('blink.lib.download'),
  fs = require('blink.lib.fs'),
  log = require('blink.lib.log'),
  lsp = require('blink.lib.lsp'),
  native = require('blink.lib.native'),
  nvim = require('blink.lib.nvim'),
  timer = require('blink.lib.timer'),

  -- utils
  require = require,
  list = require('blink.lib._.list'),
  tbl = require('blink.lib._.tbl'),
  is_not_nil = function(v) return v ~= nil and v ~= vim.NIL end,
  buffer_size = require('blink.lib._.buffer_size'),
}
