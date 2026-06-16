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

local CATCHALL = {} -- sentinel for `types.catchall()`

--- @class blink.lib.config
local M = { types = {}, utils = {} }

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
  callback = function() mode = vim.fn.getcmdwintype() ~= '' and 'cmdwin' or vim.api.nvim_get_mode().mode end,
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
  cmdwin = { 'cmdwin' },
}

--- @class blink.lib.Config<T>: T
--- @param __blink_lib_config true
--- @param snapshot fun(): T
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
      if key ~= CATCHALL and field[2] == nil then metatables[key] = get_metatable(inner_schema[key], nested_path) end
    end

    return setmetatable({}, {
      __index = function(_, key)
        if key == 'snapshot' then
          if #path > 0 then error('Cannot call snapshot on a nested config schema') end
          return function()
            local result = config
            if global_key and vim.g[global_key] then result = vim.tbl_extend('force', result, vim.g[global_key]) end
            if per_mode[mode] then result = vim.tbl_extend('force', result, per_mode[mode]) end
            if mode:sub(1, 1) ~= 'c' then
              if per_bufnr[bufnr] then result = vim.tbl_extend('force', result, per_bufnr[bufnr]) end
              if global_key and vim.b[global_key] then result = vim.tbl_extend('force', result, vim.g[global_key]) end
            end
            return result
          end
        end

        if key == '__blink_lib_config' then return true end
        if metatables[key] ~= nil then return metatables[key] end

        if mode:sub(1, 1) ~= 'c' then
          if global_key and vim.b[global_key] then
            local buffer_local_value = M.utils.tbl_get(vim.b[global_key], path, key)
            if buffer_local_value ~= nil then return buffer_local_value end
          end

          if per_bufnr[bufnr] then
            local buffer_value = M.utils.tbl_get(per_bufnr[bufnr], path, key)
            if buffer_value ~= nil then return buffer_value end
          end
        end

        if per_mode[mode] then
          local mode_value = M.utils.tbl_get(per_mode[mode], path, key)
          if mode_value ~= nil then return mode_value end
        end

        if global_key and vim.g[global_key] then
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
  local catchall = schema[CATCHALL]

  for key in next, tbl do
    if schema[key] == nil then
      -- handle catchall
      if catchall then
        local path = parent_path .. tostring(key)
        local ok_k, err_k = M.utils.validate_value(key, catchall.key_type)
        if not ok_k then
          if err_k then
            error(path .. '(key)' .. err_k)
          else
            error(
              ('%s(key): expected %s, got %s'):format(
                path,
                M.utils.describe_type(catchall.key_type),
                M.utils.describe_value(key)
              )
            )
          end
        end
        local ok_v, err_v = M.utils.validate_value(tbl[key], catchall.value_type)
        if not ok_v then
          if err_v then
            error(path .. err_v)
          else
            error(
              ('%s: expected %s, got %s'):format(
                path,
                M.utils.describe_type(catchall.value_type),
                M.utils.describe_value(tbl[key])
              )
            )
          end
        end
      else
        error(parent_path .. tostring(key) .. ': unknown field')
      end
    end
  end

  for key, field in pairs(schema) do
    -- ignore catchall sentinel
    if key == CATCHALL then

    -- nested schema
    elseif field[2] == nil then
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
      local ok, err = M.utils.validate_value(inner_val, inner_type)
      if not ok then
        return false,
          err or ('[%s]: expected %s, got %s'):format(
            i,
            M.utils.describe_type(inner_type),
            M.utils.describe_value(inner_val)
          )
      end
    end
    return true
  end)
end

--- Accepts any value that matches at least one of the given types.
--- @vararg blink.lib.ConfigSchemaType
--- @return blink.lib.ConfigSchemaValidator
function M.types.union(...)
  local types_list = { ... }
  local desc = table.concat(vim.tbl_map(M.utils.describe_type, types_list), ' | ')
  return M.types.validator(desc, function(val)
    local deepest_err
    for _, t in ipairs(types_list) do
      local ok, err = M.utils.validate_value(val, t)
      if ok then return true end
      if err then deepest_err = err end
    end
    return false, deepest_err
  end)
end

--- Ensure both keys and values are validated.
--- @param key_type blink.lib.ConfigSchemaType
--- @param value_type blink.lib.ConfigSchemaType
function M.types.map(key_type, value_type)
  return M.types.validator(
    'map(' .. M.utils.describe_type(key_type) .. ', ' .. M.utils.describe_type(value_type) .. ')',
    function(val)
      if type(val) ~= 'table' then return false, 'expected table, got ' .. M.utils.describe_value(val) end

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

        local ok_val, err_val = M.utils.validate_value(v, value_type)
        if not ok_val then
          if err_val then return false, err_val end

          local msg = ('[%s](value): expected %s, got %s'):format(
            M.utils.describe_literal(k),
            M.utils.describe_type(value_type),
            M.utils.describe_value(v)
          )
          return false, msg
        end
      end
      return true
    end
  )
end

--- @class blink.lib.ConfigSchemaTable
--- @field [string | number] blink.lib.ConfigSchemaType | blink.lib.ConfigSchemaTable

--- Validates that the value is a table matching the given shape.
--- Unlike the main schema, values are type specs directly (no defaults).
--- @param shape blink.lib.ConfigSchemaTable
--- @return blink.lib.ConfigSchemaValidator
function M.types.table(shape)
  -- Normalize: wrap nested shapes as table validators
  local fields = {}
  for key, t in pairs(shape) do
    if type(t) == 'table' and not M.types.is_validator(t) and not vim.islist(t) then
      fields[key] = M.types.table(t)
    else
      fields[key] = t
    end
  end

  local desc_parts = {}
  for key, t in pairs(fields) do
    table.insert(desc_parts, key .. ': ' .. M.utils.describe_type(t))
  end
  local desc = '{ ' .. table.concat(desc_parts, ', ') .. ' }'

  return M.types.validator(desc, function(val)
    if type(val) ~= 'table' then return false, 'expected table, got ' .. M.utils.describe_value(val) end

    for key in pairs(val) do
      if fields[key] == nil then return false, tostring(key) .. ': unknown field' end
    end

    for key, t in pairs(fields) do
      local ok, err = M.utils.validate_value(val[key], t)
      if not ok then
        if err then return false, tostring(key) .. '.' .. err end
        return false,
          tostring(key) .. ': expected ' .. M.utils.describe_type(t) .. ', got ' .. M.utils.describe_value(val[key])
      end
    end

    return true
  end)
end

--- Mark a schema as accepting additional keys of a given type
--- @param struct blink.lib.ConfigSchema
--- @param key_type blink.lib.ConfigSchemaType
--- @param value_type blink.lib.ConfigSchemaType
--- @return blink.lib.ConfigSchemaValidator
function M.types.catchall(schema, key_type, value_type)
  schema[CATCHALL] = { key_type = key_type, value_type = value_type }
  return schema
end

M.types.keycode = M.types.validator('keycode', function(val)
  if type(val) ~= 'string' or val == '' then return false end
  local rest = val:gsub('<[^<>]+>', '')
  if rest:match('[<>]') then return false end
  return true
end)

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
--- @return boolean, string?
function M.utils.validate_value(val, t)
  if M.types.is_validator(t) then
    local ok, err = t.validator(val)
    return ok, err
  end

  if type(t) ~= 'table' then t = { t } end
  for _, t in ipairs(t) do
    if M.types.is_validator(t) then
      local ok, err = t.validator(val)
      if ok then return true, nil end
    elseif type(val) == t then
      return true, nil
    end
  end

  return false, nil
end

--- Extracts the default values from a schema
--- @param schema blink.lib.ConfigSchema
--- @return table
function M.utils.extract_default(schema)
  local default = {}
  for key, field in pairs(schema) do
    if key == CATCHALL then
      -- skip
    elseif field[2] ~= nil then
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
