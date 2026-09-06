--- In-process LSP servers for `vim.lsp`. See `blink.lib.lsp.types` for the types.
---
--- ```lua
--- local lsp = require('blink.lib.lsp')
--- vim.lsp.config('my_server', {
---   cmd = lsp.server({
---     name = 'my_server',
---     capabilities = { completionProvider = {} },
---     handlers = {
---       ['textDocument/completion'] = function(params, ctx)
---         return { isIncomplete = false, items = {} }
---       end,
---     },
---   }),
--- })
--- vim.lsp.enable('my_server')
--- ```
--- @class blink.lib.lsp
--- @field util blink.lib.lsp.util
local M = {}

--- Creates an in-process server. Returns a `cmd` function for `vim.lsp.config` / `vim.lsp.start`,
--- invoked once per client instance (per `root_dir` when `root_markers` / `root_dir` are set).
--- @param opts blink.lib.lsp.server.Opts
--- @return fun(dispatchers: vim.lsp.rpc.Dispatchers, config: vim.lsp.ClientConfig): vim.lsp.rpc.Client
function M.server(opts) return require('blink.lib.lsp.server').new(opts) end

M.util = require('blink.lib.lazy_require')('blink.lib.lsp.util')

return M
