local task = require('blink.lib.task')

--- @class blink.download.Files
--- @field root_dir string
--- @field lib_folder string
--- @field lib_filename string
--- @field lib_path string
--- @field checksum_path string
--- @field checksum_filename string
--- @field version_path string
---
--- @field new fun(root_dir: string, output_dir: string, binary_name: string): blink.download.Files
---
--- @field get_version fun(self: blink.download.Files): blink.lib.Task
--- @field set_version fun(self: blink.download.Files, version: string): blink.lib.Task
---
--- @field get_lib_extension fun(): string Returns the extension for the library based on the current platform, including the dot (i.e. '.so' or '.dll')
---
--- @field read_file fun(path: string): blink.lib.Task
--- @field write_file fun(path: string, data: string): blink.lib.Task
--- @field exists fun(path: string): blink.lib.Task
--- @field stat fun(path: string): blink.lib.Task
--- @field create_dir fun(path: string): blink.lib.Task
--- @field rename fun(old_path: string, new_path: string): blink.lib.Task

--- @type blink.download.Files
--- @diagnostic disable-next-line: missing-fields
local files = {}

function files.new(root_dir, output_dir, binary_name)
  -- Normalize trailing and leading slashes
  if root_dir:sub(#root_dir, #root_dir) ~= '/' then root_dir = root_dir .. '/' end
  if output_dir:sub(1, 1) == '/' then output_dir = output_dir:sub(2) end

  local lib_folder = root_dir .. output_dir
  local lib_filename = 'lib' .. binary_name .. files.get_lib_extension()
  local lib_path = lib_folder .. '/' .. lib_filename

  local self = setmetatable({}, { __index = files })

  self.root_dir = root_dir
  self.lib_folder = lib_folder
  self.lib_filename = lib_filename
  self.lib_path = lib_path
  self.checksum_path = lib_path .. '.sha256'
  self.checksum_filename = lib_filename .. '.sha256'
  self.version_path = lib_folder .. '/version'

  return self
end

--- Version file ---

function files:get_version()
  return files
    .read_file(self.version_path)
    :map(function(version) return { tag = version } end)
    :catch(function() return { missing = true } end)
end

--- @param version string
--- @return blink.lib.Task
function files:set_version(version)
  return files
    .create_dir(self.root_dir .. '/target')
    :map(function() return files.create_dir(self.lib_folder) end)
    :map(function() return files.write_file(self.version_path, version) end)
end

--- Util ---

function files.get_lib_extension()
  if jit.os:lower() == 'mac' or jit.os:lower() == 'osx' then return '.dylib' end
  if jit.os:lower() == 'windows' then return '.dll' end
  return '.so'
end

--- Filesystem helpers ---

--- @param path string
--- @return blink.lib.Task
function files.read_file(path)
  return task.new(function(resolve, reject)
    vim.uv.fs_open(path, 'r', 438, function(open_err, fd)
      if open_err or fd == nil then return reject(open_err or 'Unknown error') end
      vim.uv.fs_read(fd, 1024, 0, function(read_err, data)
        vim.uv.fs_close(fd, function() end)
        if read_err or data == nil then return reject(read_err or 'Unknown error') end
        return resolve(data)
      end)
    end)
  end)
end

function files.write_file(path, data)
  return task.new(function(resolve, reject)
    vim.uv.fs_open(path, 'w', 438, function(open_err, fd)
      if open_err or fd == nil then return reject(open_err or 'Unknown error') end
      vim.uv.fs_write(fd, data, 0, function(write_err)
        vim.uv.fs_close(fd, function() end)
        if write_err then return reject(write_err) end
        return resolve()
      end)
    end)
  end)
end

function files.exists(path)
  return task.new(function(resolve)
    vim.uv.fs_stat(path, function(err) resolve(not err) end)
  end)
end

function files.stat(path)
  return task.new(function(resolve, reject)
    vim.uv.fs_stat(path, function(err, stat)
      if err then return reject(err) end
      resolve(stat)
    end)
  end)
end

function files.create_dir(path)
  return files
    .stat(path)
    :map(function(stat) return stat.type == 'directory' end)
    :catch(function() return false end)
    :map(function(exists)
      if exists then return end

      return task.new(function(resolve, reject)
        vim.uv.fs_mkdir(path, 511, function(err)
          if err then return reject(err) end
          resolve()
        end)
      end)
    end)
end

function files.rename(old_path, new_path)
  return task.new(function(resolve, reject)
    vim.uv.fs_rename(old_path, new_path, function(err)
      if err then return reject(err) end
      resolve()
    end)
  end)
end

return files
