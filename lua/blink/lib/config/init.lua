--- @class blink.lib.Filter
--- @field bufnr? number

--- @class blink.lib.Enable
--- @field enable fun(enable: boolean, filter?: blink.lib.Filter) Enables or disables the module, optionally scoped to a buffer
--- @field is_enabled fun(filter?: blink.lib.Filter): boolean Returns whether the module is enabled, optionally scoped to a buffer

--- @class blink.lib.EnableOpts
--- @field callback? fun(enable: boolean, filter?: blink.lib.Filter) Note that `filter.bufnr = 0` will be replaced with the current buffer

local M = {}

--- @param module_name string
function M.new_enable(module_name, opts)
  return {
    enable = function(enable, filter)
      if enable == nil then enable = true end

      if filter ~= nil and filter.bufnr ~= nil then
        if filter.bufnr == 0 then filter = { bufnr = vim.api.nvim_get_current_buf() } end
        vim.b[filter.bufnr][module_name] = enable
      else
        vim.g[module_name] = enable
      end

      if opts ~= nil and opts.callback ~= nil then opts.callback(enable, filter) end
    end,
    is_enabled = function(filter)
      if filter ~= nil and filter.bufnr ~= nil then
        local bufnr = filter.bufnr == 0 and vim.api.nvim_get_current_buf() or filter.bufnr
        if vim.b[bufnr][module_name] ~= nil then return vim.b[bufnr][module_name] == true end

        -- TODO:
        -- local blocked = config.blocked
        -- if
        --   (blocked.buftypes.include_defaults and vim.tbl_contains(default_blocked_buftypes, vim.bo[bufnr].buftype))
        --   or (#blocked.buftypes > 0 and vim.tbl_contains(blocked.buftypes, vim.bo[bufnr].buftype))
        --   or (blocked.filetypes.include_defaults and vim.tbl_contains(default_blocked_filetypes, vim.bo[bufnr].filetype))
        --   or (#blocked.filetypes > 0 and vim.tbl_contains(blocked.filetypes, vim.bo[bufnr].filetype))
        -- then
        --   return false
        -- end
      end
      return vim.g[module_name] ~= false
    end,
  }
end

--- @param schema blink.lib.ConfigSchema
--- @param validate_defaults boolean? Validate the default values, defaults to true
function M.new_config(schema, validate_defaults)
  return require('blink.lib.config.schema').new(schema, validate_defaults)
end

return M
