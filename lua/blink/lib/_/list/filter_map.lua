--- Maps a function over a list, returning the transformed list.
--- If the function returns `nil`, the item is skipped.
--- @generic T
--- @generic U
--- @param list T[]
--- @param fn fun(item: T, idx: integer): U?
--- @return U[]
local function filter_map(list, fn)
  local result = {}
  for idx, v in ipairs(list) do
    local mapped = fn(v, idx)
    if mapped ~= nil then result[#result + 1] = mapped end
  end
  return result
end

return filter_map
