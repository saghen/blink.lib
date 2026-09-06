local async = require('blink.lib.async')
local uv = vim.uv

--- @class blink.lib.fs.DirEntry
--- @field name string
--- @field type "file" | "directory" | "link" | "fifo" | "socket" | "char" | "block" | "unknown"

--- Asynchronous filesystem helpers. All functions are `@async` and resume in a fast event,
--- call `vim.async.await(vim.schedule)` before using editor APIs.
--- @class blink.lib.fs
local fs = {}

--- @async
--- @param path string
--- @param flags string
--- @param mode integer
--- @return integer fd
function fs.open(path, flags, mode) return async.await_err(4, uv.fs_open, path, flags, mode) end

--- Gets a list of all items in a directory
--- @async
--- @param path string
--- @param max_entries? integer Maximum number of entries to return, defaults to 200
--- @return blink.lib.fs.DirEntry[]
function fs.list_dir(path, max_entries)
  max_entries = max_entries or 200
  local dir = async.await_err(2, uv.fs_opendir, path, nil, math.min(max_entries, 200))

  local entries = {}
  local ok, err = async.pawait(async.run('blink.lib.fs.list_dir', function()
    while #entries < max_entries do
      local chunk = async.await_err(2, uv.fs_readdir, dir)
      if chunk == nil then break end
      for _, entry in ipairs(chunk) do
        if #entries >= max_entries then break end
        entries[#entries + 1] = entry
      end
    end
  end))

  uv.fs_closedir(dir, function() end)
  if not ok then error(err, 0) end
  return entries
end

--- Equivalent to `preadv(2)`. Returns a string where an empty string indicates EOF
--- @async
--- @param path string
--- @param size integer
--- @param offset integer?
--- @return string
function fs.read(path, size, offset)
  local fd = fs.open(path, 'r', 438)
  local ok, data = async.pawait(async.run('blink.lib.fs.read', async.await_err, 4, uv.fs_read, fd, size, offset or 0))
  uv.fs_close(fd, function() end)
  if not ok then error(data, 0) end
  return data or ''
end

--- Equivalent to `pwritev(2)`. Returns the number of bytes written
--- @async
--- @param path string
--- @param data string
--- @param offset integer?
--- @return integer
function fs.write(path, data, offset)
  local fd = fs.open(path, 'w', 438)
  local ok, bytes_written =
    async.pawait(async.run('blink.lib.fs.write', async.await_err, 4, uv.fs_write, fd, data, offset or 0))
  uv.fs_close(fd, function() end)
  if not ok then error(bytes_written, 0) end
  return bytes_written
end

--- Equivalent to `unlink(2)`
--- @async
--- @param path string
function fs.rm(path) async.await_err(2, uv.fs_unlink, path) end

--- @async
--- @param path string
--- @return boolean
function fs.exists(path)
  local err = async.await(2, uv.fs_stat, path)
  return err == nil
end

--- Equivalent to `stat(2)`
--- @async
--- @param path string
--- @return uv.aliases.fs_stat_table
function fs.stat(path) return async.await_err(2, uv.fs_stat, path) end

--- @async
--- @param path string
--- @return boolean
local function is_dir(path)
  local err, stat = async.await(2, uv.fs_stat, path)
  return err == nil and stat ~= nil and stat.type == 'directory'
end

--- Creates a directory (non-recursive), no-op if the directory already exists
--- @async
--- @param path string
--- @param mode integer? Defaults to `511`
function fs.mkdir(path, mode)
  if is_dir(path) then return end
  async.await_err(3, uv.fs_mkdir, path, mode or 511)
end

--- Recursively creates a directory, no-op if the directory already exists
--- @async
--- @param path string
--- @param mode integer? Defaults to `511`
function fs.mkdirp(path, mode)
  if is_dir(path) then return end
  local parent = fs.dirname(path)
  if parent ~= nil and parent ~= path then fs.mkdirp(parent, mode) end
  fs.mkdir(path, mode)
end

--- Equivalent to `rename(2)`
--- @async
--- @param old_path string
--- @param new_path string
function fs.rename(old_path, new_path) async.await_err(3, uv.fs_rename, old_path, new_path) end

------------------
--- Path utilities

fs.basename = vim.fs.basename
fs.dirname = vim.fs.dirname
fs.abspath = vim.fs.abspath
fs.ext = vim.fs.ext
fs.join_path = vim.fs.joinpath
fs.normalize = vim.fs.normalize
fs.parents = vim.fs.parents
fs.relpath = vim.fs.relpath
fs.root = vim.fs.root

--- Ensures a trailing slash is present
--- @param path string
--- @return string
function fs.ensure_trailing_slash(path)
  if path:sub(#path, #path) ~= '/' then return path .. '/' end
  return path
end

--- Ensures a leading slash is *not* present
--- @param path string
--- @return string
function fs.remove_leading_slash(path)
  if path:sub(1, 1) == '/' then return path:sub(2) end
  return path
end

return fs
