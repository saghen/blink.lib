--- Checks if two tables are equal (shallow)
--- @param a table
--- @param b table
--- @return boolean
local function equal(a, b)
  -- reference equality short-circuit
  if a == b then return true end

  local a_count = 0
  for k, v in pairs(a) do
    if v ~= b[k] then return false end
    a_count = a_count + 1
  end

  -- Ensure b has no extra keys
  local b_count = 0
  for _ in pairs(b) do
    b_count = b_count + 1
  end
  return a_count == b_count
end

return equal
