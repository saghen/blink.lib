local utils = {}

function utils.tbl_get(tbl, path)
  for key in ipairs(path) do
    if tbl == nil then return end
    tbl = tbl[key]
  end
  return tbl
end

--- @param types blink.lib.ConfigSchemaType | blink.lib.ConfigSchemaType[]
--- @param value any
function utils.validate_type(types, value)
  if type(types) ~= 'table' then return type(value) == types end

  local value_type = type(value)
  for _, type in ipairs(types) do
    if value_type == type then return true end
  end
  return false
end

--- Formats a list of types into a string like "one of 'string', 'number'" or for a single type "'string'"
--- @param types blink.lib.ConfigSchemaType | blink.lib.ConfigSchemaType[]
function utils.format_types(types)
  if type(types) == 'table' then
    local str = 'one of '
    for _, type in ipairs(types) do
      str = str .. "'" .. type .. "', "
    end
    return str:sub(1, -3)
  end
  return "'" .. types .. "'"
end

return utils
