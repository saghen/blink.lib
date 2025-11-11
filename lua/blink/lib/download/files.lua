local fs = require('blink.lib.fs')

--- @class blink.lib.download.files
--- @field root_dir string
--- @field lib_folder string
--- @field lib_filename string
--- @field lib_path string
--- @field version_path string
local M = {}

--- @param root_dir string
--- @param output_dir string
--- @param binary_name string
--- @return blink.lib.download.files
function M.new(root_dir, output_dir, binary_name)
  -- Normalize trailing and leading slashes
  if root_dir:sub(#root_dir, #root_dir) ~= '/' then root_dir = root_dir .. '/' end
  if output_dir:sub(1, 1) == '/' then output_dir = output_dir:sub(2) end

  local lib_folder = root_dir .. output_dir
  local lib_filename = 'lib' .. binary_name .. M.get_lib_extension()
  local lib_path = lib_folder .. '/' .. lib_filename

  local self = setmetatable({}, { __index = M })

  self.root_dir = root_dir
  self.lib_folder = lib_folder
  self.lib_filename = lib_filename
  self.lib_path = lib_path
  self.version_path = lib_folder .. '/version'

  return self
end

--- @return blink.lib.Task<{ version?: string; missing?: boolean }>
function M:get_version()
  return fs.read(self.version_path, 1024)
    :map(function(version) return { version = version } end)
    :catch(function() return { missing = true } end)
end

--- @param version string
--- @return blink.lib.Task
function M:set_version(version)
  return fs.mkdir(self.root_dir .. '/target')
    :map(function() return fs.mkdir(self.lib_folder) end)
    :map(function() return fs.write(self.version_path, version) end)
end

--- Get the extension for the library based on the current platform, including the dot (i.e. '.so' or '.dll')
--- @return string
function M.get_lib_extension()
  if jit.os:lower() == 'mac' or jit.os:lower() == 'osx' then return '.dylib' end
  if jit.os:lower() == 'windows' then return '.dll' end
  return '.so'
end

return M
