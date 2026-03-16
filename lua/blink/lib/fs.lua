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

--- Scans a directory asynchronously
--- @param path string
--- @return blink.lib.Task
function fs.list(path)
  local chunks = {}
  return fs.list_chunked(path, function(entries) vim.list_extend(chunks, entries) end):map(function() return chunks end)
end

--- Scans a directory asynchronously in chunks, calling a provided callback for each directory entry.
--- The task resolves once all entries have been processed.
--- @param path string
--- @param callback fun(entries: table[]) Callback function called with an array (chunk) of directory entries
--- @return blink.lib.Task
function fs.list_chunked(path, callback)
  local chunk_size = 200

  return task.new(function(resolve, reject)
    uv.fs_scandir(path, function(err, req)
      if err or not req then return reject(err) end
      local entries = {}
      local function send_chunk()
        if #entries > 0 then
          callback(entries)
          entries = {}
        end
      end
      while true do
        local name, type = uv.fs_scandir_next(req)
        if not name then break end
        table.insert(entries, { name = name, type = type })
        if #entries >= chunk_size then send_chunk() end
      end
      send_chunk()
      resolve(true)
    end)
  end)
end

--- Equivalent to `preadv(2)`. Returns a string where an empty string indicates EOF
--- @param path string
--- @param size number
--- @param offset number?
--- @return blink.lib.Task<string>
function fs.read(path, size, offset)
  return task.new(function(resolve, reject)
    vim.uv.fs_open(path, 'r', 438, function(open_err, fd)
      if open_err or fd == nil then return reject(open_err or 'Unknown error while opening file') end
      vim.uv.fs_read(fd, size, offset or 0, function(read_err, data)
        vim.uv.fs_close(fd, function() end)
        if read_err or data == nil then return reject(read_err or 'Unknown error while closing file') end
        return resolve(data)
      end)
    end)
  end)
end

--- Equivalent to `pwritev(2)`. Returns the number of bytes written
--- @param path string
--- @param data string
--- @param offset number?
--- @return blink.lib.Task<number>
function fs.write(path, data, offset)
  return task.new(function(resolve, reject)
    vim.uv.fs_open(path, 'w', 438, function(open_err, fd)
      if open_err or fd == nil then return reject(open_err or 'Unknown error') end
      vim.uv.fs_write(fd, data, offset or 0, function(write_err, bytes_written)
        vim.uv.fs_close(fd, function() end)
        if write_err then return reject(write_err) end
        return resolve(bytes_written)
      end)
    end)
  end)
end

--- @param path string
--- @return blink.lib.Task<boolean>
function fs.exists(path)
  return task.new(function(resolve)
    vim.uv.fs_stat(path, function(err) resolve(not err) end)
  end)
end

--- Equivalent to `stat(2)`
--- @param path string
--- @return blink.lib.Task<uv.aliases.fs_stat_table>
function fs.stat(path)
  return task.wrap(function(cb) vim.uv.fs_stat(path, cb) end)
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
      return task.wrap(function(cb) vim.uv.fs_mkdir(path, mode or 511, cb) end)
    end)
end

--- Equivalent to `rename(2)`
--- @param old_path string
--- @param new_path string
--- @return blink.lib.Task<nil>
function fs.rename(old_path, new_path)
  return task.wrap(function(cb) vim.uv.fs_rename(old_path, new_path, cb) end)
end

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
