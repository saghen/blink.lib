--- @generic T
--- @generic U
--- @param a (T | U[])[]
--- @return (T | U)[]
local function flatten(a)
  local result = {}
  for _, v in ipairs(a) do
    if vim.islist(v) then
      for _, w in ipairs(v) do
        table.insert(result, w)
      end
    else
      table.insert(result, v)
    end
  end
  return result
end

return flatten
