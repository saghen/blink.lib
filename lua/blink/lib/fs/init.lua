local require = require('blink.lib.lazy_require')
local task = require('blink.lib.task')
local uv = vim.uv

--- @class blink.lib.fs
local fs = {}

--- @param path string
--- @param flags string
--- @param mode integer
--- @return blink.lib.Task<integer>
function fs.open(path, flags, mode)
  return task.new(function(resolve, reject)
    uv.fs_open(path, flags, mode, function(err, fd)
      if err or fd == nil then return reject(err or 'Unknown error while opening file') end
      resolve(fd)
    end)
  end)
end

--- Gets a list of all items in a directory asynchronously
--- @param path string
--- @param max_entries? integer Maximum of entries to return
--- @return blink.lib.Task<blink.lib.fs.DirEntry[]>
function fs.list_dir(path, max_entries)
  -- TODO: create a helper for working with iters in `blink.lib.task`?
  return fs.list_dir_iter(path, math.min(max_entries or 200, 200)):map(function(iter)
    local function next(all_entries)
      return iter():map(function(entries)
        -- end of directory
        if entries == nil then return all_entries end

        -- reached max entries
        if #all_entries + #entries >= max_entries then
          vim.list_extend(all_entries, vim.list_slice(entries, 1, max_entries - #all_entries))
          return all_entries
        end

        -- continue iter
        vim.list_extend(all_entries, entries)
        return next(all_entries)
      end)
    end
    return next({})
  end)
end

fs.list_dir_iter = require('blink.lib.fs.list_dir_iter')

--- Equivalent to `preadv(2)`. Returns a string where an empty string indicates EOF
--- @param path string
--- @param size integer
--- @param offset integer?
--- @return blink.lib.Task<string?>
function fs.read(path, size, offset)
  return task.new(function(resolve, reject)
    uv.fs_open(path, 'r', 438, function(open_err, fd)
      if open_err or fd == nil then return reject(open_err or 'Unknown error while opening file') end
      uv.fs_read(fd, size, offset or 0, function(read_err, data)
        uv.fs_close(fd, function() end)
        if read_err or data == nil then return reject(read_err or 'Unknown error while closing file') end
        return resolve(data)
      end)
    end)
  end)
end

--- Equivalent to `pwritev(2)`. Returns the number of bytes written
--- @param path string
--- @param data string
--- @param offset integer?
--- @return blink.lib.Task<integer?>
function fs.write(path, data, offset)
  return task.new(function(resolve, reject)
    uv.fs_open(path, 'w', 438, function(open_err, fd)
      if open_err or fd == nil then return reject(open_err or 'Unknown error') end
      uv.fs_write(fd, data, offset or 0, function(write_err, bytes_written)
        uv.fs_close(fd, function() end)
        if write_err then return reject(write_err) end
        return resolve(bytes_written)
      end)
    end)
  end)
end

--- Equivalent to `unlink(2)`
function fs.rm(path)
  return task.wrap(function(cb) uv.fs_unlink(path, cb) end)
end

--- @param path string
--- @return blink.lib.Task<boolean>
function fs.exists(path)
  return task.new(function(resolve)
    uv.fs_stat(path, function(err) resolve(not err) end)
  end)
end

--- Equivalent to `stat(2)`
--- @param path string
--- @return blink.lib.Task<uv.aliases.fs_stat_table>
function fs.stat(path)
  return task.wrap(function(cb) uv.fs_stat(path, cb) end)
end

--- Creates a directory (non-recursive), no-op if the directory already exists
--- @param path string
--- @param mode integer? Defaults to `511`
--- @return blink.lib.Task<nil>
function fs.mkdir(path, mode)
  return fs.stat(path)
    :map(function(stat) return stat.type == 'directory' end)
    :catch(function() return false end)
    :map(function(exists)
      if exists then return end
      return task.wrap(function(cb) uv.fs_mkdir(path, mode or 511, cb) end)
    end)
end

--- Recursively creates a directory, no-op if the directory already exists
--- @param path string
--- @param mode integer? Defaults to `511`
--- @return blink.lib.Task<nil>
function fs.mkdirp(path, mode)
  return fs.stat(path)
    :map(function(stat) return stat.type == 'directory' end)
    :catch(function() return false end)
    :map(function(exists)
      if exists then return end
      return fs.mkdirp(fs.dirname(path), mode):map(function() return fs.mkdir(path, mode) end)
    end)
end

--- Equivalent to `rename(2)`
--- @param old_path string
--- @param new_path string
--- @return blink.lib.Task<nil>
function fs.rename(old_path, new_path)
  return task.wrap(function(cb) uv.fs_rename(old_path, new_path, cb) end)
end

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
