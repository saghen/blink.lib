--- Returns the index of the first occurrence of the value in the array
--- @generic T
--- @param list T[]
--- @param val T
--- @return integer?
local function index_of(list, val)
  for idx, v in ipairs(list) do
    if v == val then return idx end
  end
  return nil
end

return index_of
