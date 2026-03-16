local files = require('blink.lib.download.files')

--- @type table<string, boolean>
local cpath_set_by_module = {}

--- @param lib_dir string
local function init_cpath(lib_dir)
  if cpath_set_by_module[lib_dir] then return end
  if lib_dir:sub(#lib_dir, #lib_dir) ~= '/' then lib_dir = lib_dir .. '/' end

  -- search for the lib in the /target/release directory with and without the lib prefix
  -- since MSVC doesn't include the prefix
  package.cpath = package.cpath
    .. ';'
    .. lib_dir
    .. 'lib?'
    .. files.get_lib_extension()
    .. ';'
    .. lib_dir
    .. '?'
    .. files.get_lib_extension()

  cpath_set_by_module[lib_dir] = true
end

return init_cpath
