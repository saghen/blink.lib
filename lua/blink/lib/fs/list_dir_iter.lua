local task = require('blink.lib.task')
local uv = vim.uv

--- @class blink.lib.fs.DirEntry
--- @field name string
--- @field type "file" | "directory" | "link" | "fifo" | "socket" | "char" | "block" | "unknown"

--- Scans a directory asynchronously in chunks, returning an iterator function that yields
--- each chunk of entries.
--- @param path string
--- @param chunk_size? integer Entries to return per chunk
--- @return blink.lib.Task<fun(): blink.lib.Task<blink.lib.fs.DirEntry[]?>>
local function list_dir_iter(path, chunk_size)
  return task.new(function(resolve, reject)
    uv.fs_opendir(path, function(err, dir)
      if err then return reject(err) end
      if dir == nil then return reject('Failed to open directory: ' .. path) end

      resolve(function()
        return task.new(function(resolve, reject)
          uv.fs_readdir(dir, function(err, entries)
            if err then return reject(err) end
            resolve(entries)
          end)
        end)
      end)
    end, chunk_size or 200)
  end)
end

return list_dir_iter
