local M = {}

-- stylua: ignore
local CODES = {
    reset = 0, bold = 1, dim = 2, italic = 3, underline = 4, reverse = 7,
    black = 30, red = 31, green = 32, yellow = 33,
    blue = 34, magenta = 35, cyan = 36, white = 37,
    ["bg:black"] = 40, ["bg:red"] = 41, ["bg:green"] = 42, ["bg:yellow"] = 43,
    ["bg:blue"] = 44, ["bg:magenta"] = 45, ["bg:cyan"] = 46, ["bg:white"] = 47,
    bright_red = 91, bright_green = 92, bright_yellow = 93, bright_blue = 94,
    bright_magenta = 95, bright_cyan = 96, bright_white = 97,
}

local function ansi(spec)
  local codes = {}
  for part in spec:gmatch('[^,%s]+') do
    if part:match('^%%[%-%+ #0]*%d*%.?%d*[diouxXeEfgGqscp]$') then return '{' .. spec .. '}' end
    local code = CODES[part] or error('unknown tag: ' .. part, 3)
    codes[#codes + 1] = tostring(code)
  end
  return '\27[' .. table.concat(codes, ';') .. 'm'
end

local function colorize(fmt)
  if not M.enabled then return fmt:gsub('{[^}]*}', '') end
  return (fmt:gsub('{/}', '\27[0m'):gsub('{([^}]+)}', ansi))
end

M.enabled = os.getenv('NO_COLOR') == nil and os.getenv('TERM') ~= nil and os.getenv('TERM') ~= 'dumb'

function M.format(fmt, ...) return colorize(string.format(colorize(fmt), ...)) end

function M.style(s, cond, text, ...)
  if cond == false or s == nil or not M.enabled then return text end
  if select('#', ...) > 0 then text = string.format(text, ...) end
  return '{' .. s .. '}' .. text .. '{/}'
end

function M.print(string) io.write(string, '\n') end

return M
