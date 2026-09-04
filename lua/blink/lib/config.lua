--- @class blink.lib.config
local M = { types = {}, utils = {} }

--- @alias blink.lib.ConfigSchemaLiteralType 'string' | 'number' | 'boolean' | 'function' | 'table' | 'nil' | 'any'
--- @alias blink.lib.ConfigSchemaType blink.lib.ConfigSchemaLiteralType | blink.lib.ConfigSchemaValidator | (blink.lib.ConfigSchemaLiteralType | blink.lib.ConfigSchemaValidator)[]

--- @class blink.lib.ConfigSchemaField
--- @field [1] any Default value
--- @field [2] blink.lib.ConfigSchemaType Allowed types or validator

--- @alias blink.lib.ConfigSchema { [string]: blink.lib.ConfigSchema | blink.lib.ConfigSchemaField }

--- @alias blink.lib.config.Mode 'normal' | 'visual' | 'select' | 'insert' | 'replace' | 'cmdline' | 'terminal' | string

-- stylua: ignore
local mode_prefixes = {
  n = 'normal', v = 'visual', V = 'visual', ['\x16'] = 'visual', s = 'select', S = 'select', ['\x13'] = 'select',
  i = 'insert', R = 'replace', r = 'replace', c = 'cmdline', t = 'terminal'
}

--- @param m string Raw mode from `nvim_get_mode()` or a category
--- @return blink.lib.config.Mode
local function mode_to_category(m) return mode_prefixes[m:sub(1, 1)] or m end

--- Weak references to config instances to drop per-buffer scopes when a buffer is deleted
--- @type table<blink.lib.Config, fun(bufnr: integer)>
local instances = setmetatable({}, { __mode = 'k' })

local augroup = vim.api.nvim_create_augroup('blink.lib.config', {})
vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
  group = augroup,
  callback = function(ev)
    for _, forget in pairs(instances) do
      forget(ev.buf)
    end
  end,
})

--- @class blink.lib.config.Filter
--- @field bufnr? integer Buffer to resolve the config for, `0` or `nil` for the current buffer. Ignored in cmdline mode
--- @field mode? blink.lib.config.Mode Mode to resolve the config for, defaults to the current mode

--- @class blink.lib.config.SetOpts
--- @field validate? boolean Validate after merging, defaults to true
--- @field bufnr? integer Apply config to a given buffer, `0` for the current buffer
--- @field mode? blink.lib.config.Mode Apply config to a given mode

--- @class blink.lib.config.Opts
--- @field validate? boolean Validate default configuration, defaults to true

--- Configuration object with validation and per-buffer, per-mode, and global values
---
--- Accessing a top-level key (`config.completion`) returns the field from the resolved config
--- for the current buffer and mode, which is a plain table. Re-read the field or call
--- `config.get()` at each use, to ensure the table is up-to-date.
---
--- Resolution order, highest priority first:
--- - per-buffer (`set(tbl, { bufnr })`), ignored in cmdline mode
--- - per-mode (`set(tbl, { mode })`)
--- - global (`set(tbl)`)
--- - defaults
---
--- @class blink.lib.Config
--- @field get fun(filter?: blink.lib.config.Filter): table Resolved configuration. Do not mutate.
--- @field set fun(tbl: table, opts?: blink.lib.config.SetOpts): blink.lib.Config Validates and deep-merges into the global, per-mode or per-buffer scope
--- @field validate fun(tbl: table) Validates a partial table against the schema, merged over the current global config
--- @field schema blink.lib.ConfigSchema
--- @field __blink_lib_config true
--- @overload fun(tbl: table, opts?: blink.lib.config.SetOpts): blink.lib.Config Alias for `set`

--- @param schema blink.lib.ConfigSchema
--- @param opts? blink.lib.config.Opts
--- @return blink.lib.Config
function M.new(schema, opts)
  opts = opts or {}

  local global = M.utils.extract_default(schema)
  if opts.validate ~= false then M.validate(schema, global) end

  local per_mode = {} --- @type table<string, table>
  local per_bufnr = {} --- @type table<integer, table>
  local cache = {} --- @type table<string, table> Resolved per mode
  local cache_by_bufnr = {} --- @type table<integer, table<string, table>> Resolved per (buffer, mode), only for buffers with a scope

  --- @type blink.lib.Config
  --- @diagnostic disable-next-line: missing-fields
  local self = { schema = schema, __blink_lib_config = true }

  --- @param b? integer
  --- @return integer
  local function to_bufnr(b) return (b == nil or b == 0) and vim.api.nvim_get_current_buf() or b end

  --- @param filter? blink.lib.config.Filter
  --- @return table
  local function get(filter)
    local m = mode_to_category(filter and filter.mode or vim.api.nvim_get_mode().mode)

    -- per mode resolution
    local resolved = cache[m]
    if resolved == nil then
      resolved = per_mode[m] and vim.tbl_deep_extend('force', global, per_mode[m]) or global
      cache[m] = resolved
    end
    if m == 'cmdline' then return resolved end

    -- per buffer resolution
    local b = to_bufnr(filter and filter.bufnr)
    local layer = per_bufnr[b]
    if layer == nil then return resolved end

    local by_mode = cache_by_bufnr[b]
    if by_mode == nil then
      by_mode = {}
      cache_by_bufnr[b] = by_mode
    end
    local resolved_for_bufnr = by_mode[m]
    if resolved_for_bufnr == nil then
      resolved_for_bufnr = vim.tbl_deep_extend('force', resolved, layer)
      by_mode[m] = resolved_for_bufnr
    end
    return resolved_for_bufnr
  end
  self.get = get

  instances[self] = function(b)
    if per_bufnr[b] == nil then return end
    per_bufnr[b], cache_by_bufnr[b] = nil, nil
  end

  function self.validate(tbl) M.validate(schema, vim.tbl_deep_extend('force', global, tbl)) end

  function self.set(tbl, set_opts)
    set_opts = set_opts or {}
    if set_opts.bufnr ~= nil and set_opts.mode ~= nil then error('Cannot specify both `bufnr` and `mode` options') end

    tbl = tbl or {}
    if set_opts.validate ~= false then self.validate(tbl) end

    -- per mode
    if set_opts.mode ~= nil then
      local m = mode_to_category(set_opts.mode)
      per_mode[m] = vim.tbl_deep_extend('force', per_mode[m] or {}, tbl)
    -- per buffer
    elseif set_opts.bufnr ~= nil then
      local b = to_bufnr(set_opts.bufnr)
      per_bufnr[b] = vim.tbl_deep_extend('force', per_bufnr[b] or {}, tbl)
    -- global
    else
      global = vim.tbl_deep_extend('force', global, tbl)
    end

    cache, cache_by_bufnr = {}, {}
    return self
  end

  for key in pairs(schema) do
    if rawget(self, key) ~= nil then
      error('"' .. tostring(key) .. '" is a reserved key and cannot be used in a schema')
    end
  end

  return setmetatable(self, {
    __index = function(_, key) return get()[key] end,
    __call = function(s, tbl, set_opts) return s.set(tbl, set_opts) end,
  })
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
--- @field desc string
--- @field validator fun(val): boolean, string?

--- @param desc string
--- @param validator fun(val): boolean, string?
--- @return blink.lib.ConfigSchemaValidator
function M.types.validator(desc, validator) return { desc = desc, validator = validator } end

--- @param v any
--- @return boolean
function M.types.is_validator(v) return type(v) == 'table' and type(v.validator) == 'function' end

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
--- Keys not in the shape are rejected, unless `extra_key_type` and `extra_value_type` are given,
--- in which case they're validated against those instead.
--- @param shape blink.lib.ConfigSchemaTable
--- @param extra_key_type? blink.lib.ConfigSchemaType
--- @param extra_value_type? blink.lib.ConfigSchemaType
--- @return blink.lib.ConfigSchemaValidator
function M.types.table(shape, extra_key_type, extra_value_type)
  if (extra_key_type == nil) ~= (extra_value_type == nil) then
    error('blink.lib.config: types.table requires both `extra_key_type` and `extra_value_type`, or neither')
  end

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
  if extra_key_type then
    table.insert(
      desc_parts,
      '[' .. M.utils.describe_type(extra_key_type) .. ']: ' .. M.utils.describe_type(extra_value_type)
    )
  end
  local desc = '{ ' .. table.concat(desc_parts, ', ') .. ' }'

  --- @param label string Prefix for the error message, e.g. the key
  --- @param t blink.lib.ConfigSchemaType
  --- @param val any
  --- @return boolean, string?
  local function check(label, t, val)
    local ok, err = M.utils.validate_value(val, t)
    if ok then return true end
    if err then return false, label .. '.' .. err end
    return false, label .. ': expected ' .. M.utils.describe_type(t) .. ', got ' .. M.utils.describe_value(val)
  end

  return M.types.validator(desc, function(val)
    if type(val) ~= 'table' then return false, 'expected table, got ' .. M.utils.describe_value(val) end

    for key, v in pairs(val) do
      if fields[key] == nil then
        if extra_key_type == nil then return false, tostring(key) .. ': unknown field' end
        local ok, err = check(tostring(key) .. '(key)', extra_key_type, key)
        if not ok then return false, err end
        ok, err = check(tostring(key), extra_value_type, v)
        if not ok then return false, err end
      end
    end

    for key, t in pairs(fields) do
      local ok, err = check(tostring(key), t, val[key])
      if not ok then return false, err end
    end

    return true
  end)
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
  -- single type
  if M.types.is_validator(t) then
    local ok, err = t.validator(val)
    return ok, err
  end

  -- union of multiple types
  local last_err
  if type(t) ~= 'table' then t = { t } end
  for _, t in ipairs(t) do
    if M.types.is_validator(t) then
      local ok, err = t.validator(val)
      if ok then return true, nil end
      last_err = err or last_err
    elseif type(val) == t then
      return true, nil
    end
  end

  return false, last_err
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

return M
