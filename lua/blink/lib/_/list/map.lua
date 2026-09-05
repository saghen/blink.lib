--- Maps a function over a list, returning the transformed list
--- @generic T
--- @generic U
--- @param list T[]
--- @param fn fun(item: T, idx: integer): U
--- @return U[]
local function map(list, fn)
  local result = {}
  for idx, v in ipairs(list) do
    result[idx] = fn(v, idx)
  end
  return result
end

return map
