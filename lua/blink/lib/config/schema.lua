-- TODO: support nested schemas

local utils = require('blink.lib.config.utils')

--- @class blink.lib.ConfigSchemaField
--- @field [1] any Default value
--- @field [2] blink.lib.ConfigSchemaType | blink.lib.ConfigSchemaType[] Allowed type or types
--- @field [3]? fun(val): boolean | string | nil Validation function returning a string error message or false to use the default error message. Any other return value will be treated as passing validation
--- @field [4]? string Error message to use if the validation function returns false

--- @alias blink.lib.ConfigSchemaType 'string' | 'number' | 'boolean' | 'function' | 'table' | 'nil' | 'any'
--- @alias blink.lib.ConfigSchema { [string]: blink.lib.ConfigSchema | blink.lib.ConfigSchemaField }

local M = {}

--- @param global_key string Key used for getting configs from `vim.g` and `vim.b`
--- @param schema blink.lib.ConfigSchema
--- @param validate_defaults boolean? Validate the default values, defaults to true
function M.new(global_key, schema, validate_defaults)
  local config = M.extract_default(schema)
  if validate_defaults ~= false then M.validate(schema, config) end

  --- @param path string[]
  local function get_metatable(inner_schema, path)
    local metatables = {}
    for key, field in pairs(inner_schema) do
      local nested_path = vim.list_extend({}, path)
      table.insert(nested_path, key)
      if field[2] ~= nil then metatables[key] = get_metatable(inner_schema[key], nested_path) end
    end

    return setmetatable({}, {
      __index = function(_, key)
        if metatables[key] ~= nil then return metatables[key] end

        local buffer_value = utils.tbl_get(vim.b[global_key], path)
        if buffer_value ~= nil then return buffer_value end

        local global_value = utils.tbl_get(vim.g[global_key], path)
        if global_value ~= nil then return global_value end

        return utils.tbl_get(config, path)
      end,

      __newindex = function(_, key, value)
        if inner_schema[key] ~= nil then
          M.validate({ [key] = inner_schema[key] }, { [key] = value }, table.concat(path, '.') .. '.')
        end
        config[key] = value
      end,

      __call = function(_, tbl)
        if #path > 0 then error('Cannot call a nested config schema') end

        local new_config = vim.tbl_deep_extend('force', config, tbl or {})
        M.validate(schema, new_config)
        config = new_config
      end,
    })
  end

  return get_metatable(schema, {})
end

--- Extracts the default values from a schema
--- @param schema blink.lib.ConfigSchema
--- @return table
function M.extract_default(schema)
  local default = {}
  for key, field in pairs(schema) do
    if field[1] ~= nil then
      default[key] = field[1]
    else
      default[key] = M.extract_default(field)
    end
  end
  return default
end

--- @param schema blink.lib.ConfigSchema
--- @param tbl table
--- @param prev_keys string? For internal use only
function M.validate(schema, tbl, prev_keys)
  prev_keys = prev_keys or ''

  for key, field in pairs(schema) do
    -- nested schema
    if field[2] == nil then
      local nested_tbl = tbl[key]
      if nested_tbl == nil then
        error(string.format('Missing field %s: expected %s, got nil', prev_keys .. key, utils.format_types(field[2])))
      end
      M.validate(field, tbl[key], prev_keys .. key .. '.')

    -- field schema
    else
      if not utils.validate_type(field[2], tbl[key]) then
        error(
          string.format(
            "Invalid type for %s: expected %s, got '%s'",
            prev_keys .. key,
            utils.format_types(field[2]),
            type(tbl[key])
          )
        )
      end
      if field[3] then
        local err = field[3](tbl[key])
        if err == false then
          error(
            string.format(
              'Invalid value for %s: %s',
              prev_keys .. key,
              field[4] or '[[developer forgot to set a default error message!]]'
            )
          )
        elseif type(err) == 'string' then
          error(string.format('Invalid value for %s: %s', prev_keys .. key, err))
        end
      end
    end
  end
end
