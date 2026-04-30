--- @class blink.lib.Filter
--- @field bufnr? number

--- @class blink.lib.Enable
--- @field enable fun(enable: boolean, filter?: blink.lib.Filter) Enables or disables the module, optionally scoped to a buffer
--- @field is_enabled fun(filter?: blink.lib.Filter): boolean Returns whether the module is enabled, optionally scoped to a buffer

--- @class blink.lib.EnableOpts
--- @field alternate_module_names? string[]
--- @field blocked_buftypes? string[]
--- @field blocked_filetypes? string[]
--- @field callback? fun(enable: boolean, filter?: blink.lib.Filter) Note that `filter.bufnr = 0` will be replaced with the current buffer

--- @class blink.lib.config
local M = { types = {}, utils = {} }

--- @param module_name string
--- @param opts blink.lib.EnableOpts?
function M.new_enable(module_name, opts)
  local blocked_buftypes = {}
  for _, buftype in ipairs(opts.blocked_buftypes or {}) do
    blocked_buftypes[buftype] = true
  end
  local blocked_filetypes = {}
  for _, filetype in ipairs(opts.blocked_filetypes or {}) do
    blocked_filetypes[filetype] = true
  end

  -- TODO: how to handle cmdline/term?

  return {
    enable = function(enable, filter)
      if enable == nil then enable = true end

      if filter ~= nil and filter.bufnr ~= nil then
        local bufnr = filter.bufnr == 0 and vim.api.nvim_get_current_buf() or filter.bufnr
        vim.b[bufnr][module_name] = enable
      else
        vim.g[module_name] = enable
      end

      if opts ~= nil and opts.callback ~= nil then opts.callback(enable, filter) end
    end,
    is_enabled = function(filter)
      -- per buffer
      if filter ~= nil and filter.bufnr ~= nil then
        local bufnr = filter.bufnr == 0 and vim.api.nvim_get_current_buf() or filter.bufnr
        if vim.b[bufnr][module_name] ~= nil then return vim.b[bufnr][module_name] == true end
        if opts.alternate_module_names ~= nil then
          for _, alt_module_name in ipairs(opts.alternate_module_names or {}) do
            if vim.b[bufnr][alt_module_name] ~= nil then return vim.b[bufnr][alt_module_name] == true end
          end
        end

        if blocked_buftypes[vim.bo[bufnr].buftype] then return false end
        if blocked_filetypes[vim.bo[bufnr].filetype] then return false end
      end

      -- global
      if vim.g[module_name] ~= nil then return vim.g[module_name] ~= false end
      for _, alt_module_name in ipairs(opts.alternate_module_names or {}) do
        if vim.g[alt_module_name] ~= nil then return vim.g[alt_module_name] ~= false end
      end
      return true
    end,
  }
end

--- @alias blink.lib.ConfigSchemaLiteralType 'string' | 'number' | 'boolean' | 'function' | 'table' | 'nil' | 'any'
--- @alias blink.lib.ConfigSchemaType blink.lib.ConfigSchemaLiteralType | blink.lib.ConfigSchemaValidator | (blink.lib.ConfigSchemaLiteralType | blink.lib.ConfigSchemaValidator)[]

--- @class blink.lib.ConfigSchemaField
--- @field [1] any Default value
--- @field [2] blink.lib.ConfigSchemaType Allowed types or validator

--- @alias blink.lib.ConfigSchema { [string]: blink.lib.ConfigSchema | blink.lib.ConfigSchemaField }

-- cache mode and bufnr for slightly faster access
local augroup = vim.api.nvim_create_augroup('blink.lib.config', {})
local mode = vim.api.nvim_get_mode().mode
local bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_create_autocmd('ModeChanged', {
  group = augroup,
  callback = function() mode = vim.api.nvim_get_mode().mode end,
})
vim.api.nvim_create_autocmd('BufEnter', {
  group = augroup,
  callback = function() bufnr = vim.api.nvim_get_current_buf() end,
})

local special_modes = {
  normal = { 'n', 'no', 'nov', 'noV', 'niI', 'niR', 'niV', 'nt', 'ntT' },
  visual = { 'v', 'V', '\x16', 'vs', 'Vs', '\x16s' },
  select = { 's', 'S', '\x13' },
  insert = { 'i', 'ic', 'ix' },
  replace = { 'R', 'Rc', 'Rx', 'Rv', 'Rvc', 'Rvx' },
  cmdline = { 'c', 'cv', 'ce', 'cr' },
  terminal = { 't' },
}

--- @class blink.lib.Config<T>: T
--- @param __blink_lib_config true
--- @overload fun(config: T, opts?: blink.lib.config.MergeOpts): blink.lib.Config<T>

--- @class blink.lib.config.Opts
--- @field global_key? string Key used for getting configs from `vim.g` and `vim.b`
--- @field validate? boolean Validate default configuration, defaults to true

--- @class blink.lib.config.MergeOpts
--- @field validate? boolean Validate after merging configs, defaults to true
--- @field bufnr? number Apply config to a given buffer
--- @field mode? blink.lib.config.Mode Apply config to a given mode

--- @alias blink.lib.config.Mode 'normal' | 'visual' | 'select' | 'insert' | 'replace' | 'cmdline' | 'terminal' | string

--- @generic T
--- @param global_key string Key used for getting configs from `vim.g` and `vim.b`
--- @param schema blink.lib.ConfigSchema
--- @param opts? { global_key?: string, validate?: boolean } Validate default configuration, defaults to true
--- @return blink.lib.Config<T>
function M.new(schema, opts)
  local config = M.utils.extract_default(schema)
  local global_key = opts and opts.global_key
  local per_mode = {}
  local per_bufnr = {}
  if not opts or opts.validate ~= false then M.validate(schema, config) end

  --- @param path string[]
  local function get_metatable(inner_schema, path)
    local metatables = {}
    for key, field in pairs(inner_schema) do
      local nested_path = vim.list_extend({}, path)
      table.insert(nested_path, key)
      if field[2] == nil then metatables[key] = get_metatable(inner_schema[key], nested_path) end
    end

    return setmetatable({}, {
      __index = function(_, key)
        if key == '__blink_lib_config' then return true end
        if metatables[key] ~= nil then return metatables[key] end

        if mode:sub(1, 1) ~= 'c' then
          if global_key then
            local buffer_local_value = M.utils.tbl_get(vim.b[global_key], path, key)
            if buffer_local_value ~= nil then return buffer_local_value end
          end

          local buffer_value = M.utils.tbl_get(per_bufnr[bufnr], path, key)
          if buffer_value ~= nil then return buffer_value end
        end

        local mode_value = M.utils.tbl_get(per_mode[mode], path, key)
        if mode_value ~= nil then return mode_value end

        if global_key then
          local global_value = M.utils.tbl_get(vim.g[global_key], path, key)
          if global_value ~= nil then return global_value end
        end

        return M.utils.tbl_get(config, path, key)
      end,

      -- Merge with existing config
      __call = function(_, tbl, opts)
        if #path > 0 then error('Cannot call a nested config schema') end

        opts = opts or {}
        if opts.bufnr ~= nil and opts.mode ~= nil then error('Cannot specify both `bufnr` and `mode` options') end

        tbl = tbl or {}
        if opts.validate ~= false then M.validate(schema, vim.tbl_deep_extend('force', config, tbl)) end

        -- per mode
        if opts.mode ~= nil then
          local modes = special_modes[opts.mode] or { opts.mode }
          for _, mode in ipairs(modes) do
            per_mode[mode] = vim.tbl_deep_extend('force', per_mode[mode] or {}, tbl)
          end
        -- per buffer
        elseif opts.bufnr ~= nil then
          per_bufnr[opts.bufnr] = vim.tbl_deep_extend('force', per_bufnr[opts.bufnr] or {}, tbl)
        -- global
        else
          config = vim.tbl_deep_extend('force', config, tbl)
        end
      end,
    })
  end

  return get_metatable(schema, {})
end

--- @param schema blink.lib.ConfigSchema
--- @param tbl table
--- @param parent_path string? For internal use only
function M.validate(schema, tbl, parent_path)
  parent_path = parent_path or ''

  for key in next, tbl do
    if schema[key] == nil then error(parent_path .. tostring(key) .. ': unknown field') end
  end

  for key, field in pairs(schema) do
    -- nested schema
    if field[2] == nil then
      local nested_tbl = tbl[key]
      if type(nested_tbl) ~= 'table' then
        local path = parent_path .. key
        error(path .. ': expected nested table, got ' .. M.utils.describe_value(tbl[key]))
      end
      M.validate(field, tbl[key], parent_path .. key .. '.')

    -- field type
    else
      local t = field[2]
      local ok, inner_err = M.utils.validate_value(tbl[key], t)
      if not ok then
        local path = parent_path .. key
        if inner_err then
          error(path .. inner_err)
        else
          error(path .. ': expected ' .. M.utils.describe_type(t) .. ', got ' .. M.utils.describe_value(tbl[key]))
        end
      end
    end
  end
end

-------------------
--- TYPES
-------------------

--- @class blink.lib.ConfigSchemaValidator
local Validator = {}
Validator.__index = Validator

--- @param desc string
--- @param validator fun(val): boolean, string?
--- @return blink.lib.ConfigSchemaValidator
function M.types.validator(desc, validator) return setmetatable({ desc = desc, validator = validator }, Validator) end

--- @return boolean
function M.types.is_validator(v) return getmetatable(v) == Validator end

--- Validates that the value is one of the given variants
--- @param variants (string | number | boolean)[]
--- @return blink.lib.ConfigSchemaValidator
function M.types.enum(variants)
  return M.types.validator(table.concat(vim.tbl_map(M.utils.describe_literal, variants), ' | '), function(val)
    for _, variant in ipairs(variants) do
      if val == variant then return true end
    end
    return false
  end)
end

--- Validates that the value is a list of the given type
--- @param inner_type blink.lib.ConfigSchemaType
--- @return blink.lib.ConfigSchemaValidator
function M.types.list(inner_type)
  return M.types.validator('list(' .. M.utils.describe_type(inner_type) .. ')', function(val)
    if not vim.islist(val) then return false end
    for i, inner_val in ipairs(val) do
      local ok = M.utils.validate_value(inner_val, inner_type)
      if ok == false then
        return false,
          '[' .. i .. ']: expected ' .. M.utils.describe_type(inner_type) .. ', got ' .. M.utils.describe_value(
            inner_val
          )
      end
    end
    return true
  end)
end

--- Ensure both keys and values are validated.
--- @param key_type blink.lib.ConfigSchemaType
--- @param value_type blink.lib.ConfigSchemaType
function M.types.map(key_type, value_type)
  return M.types.validator(
    'map(' .. M.utils.describe_type(key_type) .. ', ' .. M.utils.describe_type(value_type) .. ')',
    function(val)
      if type(val) ~= 'table' then return false, ': expected table, got ' .. M.utils.describe_value(val) end

      for k, v in pairs(val) do
        local ok, err = M.utils.validate_value(k, key_type)
        if not ok then
          if err then return false, err end

          local msg = ('[%s](key): expected %s, got %s'):format(
            M.utils.describe_literal(k),
            M.utils.describe_type(key_type),
            M.utils.describe_value(k)
          )
          return false, msg
        end

        local ok, err = M.utils.validate_value(v, value_type)
        if not ok then
          if err then return false, err end

          local msg = ('[%s](key): expected %s, got %s'):format(
            M.utils.describe_literal(k),
            M.utils.describe_type(value_type),
            M.utils.describe_value(k)
          )
          return false, msg
        end
      end
      return true
    end
  )
end

-------------------
--- UTILS
-------------------

function M.utils.describe_literal(val)
  if type(val) == 'string' then return '"' .. val .. '"' end
  return tostring(val)
end

function M.utils.describe_value(val) return vim.inspect(val, { depth = 1, newline = ' ', indent = '' }) end

--- Turn a type spec (list of strings/validators) into a description
--- e.g. { 'function', enum({...}) } -> 'function | "a" | "b" | "c"'
--- @param t blink.lib.ConfigSchemaType
function M.utils.describe_type(t)
  if M.types.is_validator(t) then return t.desc end

  if type(t) ~= 'table' then t = { t } end
  local parts = {}
  for _, t in ipairs(t) do
    if M.types.is_validator(t) then
      table.insert(parts, t.desc)
    else
      table.insert(parts, t) -- plain type string like 'function', 'number'
    end
  end
  return table.concat(parts, ' | ')
end

--- Check a value against a type spec (list of strings/validators)
--- @param val any
--- @param t blink.lib.ConfigSchemaType
--- @return boolean
function M.utils.validate_value(val, t)
  if M.types.is_validator(t) then
    local ok, err = t.validator(val)
    return ok
  end

  if type(t) ~= 'table' then t = { t } end
  for _, t in ipairs(t) do
    if M.types.is_validator(t) then
      local ok, err = t.validator(val)
      if ok then return true end
    elseif type(val) == t then
      return true
    end
  end
  return false
end

--- Extracts the default values from a schema
--- @param schema blink.lib.ConfigSchema
--- @return table
function M.utils.extract_default(schema)
  local default = {}
  for key, field in pairs(schema) do
    if field[2] ~= nil then
      default[key] = field[1]
    else
      default[key] = M.utils.extract_default(field)
    end
  end
  return default
end

function M.utils.tbl_get(tbl, path, key)
  for _, key in ipairs(path) do
    if type(tbl) ~= 'table' then return end
    tbl = tbl[key]
  end
  if type(tbl) ~= 'table' then return end
  return tbl[key]
end

return M
