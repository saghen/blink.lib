local os = jit.os:lower()
local lib_extension = (os == 'osx' or os == 'mac') and '.dylib' or os == 'windows' and '.dll' or '.so'

--- @class blink.lib.native
local native = {}

--- Get information about the current platform
--- @return blink.lib.native.Platform
function native.platform()
  local platform = require('blink.lib.native.platform')
  local os = platform.os()
  local arch = platform.arch()
  local libc = platform.libc(os)
  local triple = platform.triple(os, arch, libc)
  return { os = os, arch = arch, libc = libc, triple = triple, lib_extension = lib_extension }
end

--- @param name string Name of the artifact to be used when requiring it (e.g. 'blink_cmp_fuzzy')
--- @param commit_hash? string Commit hash of the repository. If omitted, resulting filename will be `lib$name.so` instead of `lib$name.so.hash`.
--- @param dir? string Override the default base path of `vim.fn.stdpath('data') .. '/site/lib/'`
--- @return string library_path
function native.library_path(name, commit_hash, dir)
  dir = dir and vim.fs.normalize(dir) or (vim.fn.stdpath('data') .. '/site/lib')
  local path = dir .. '/lib' .. name .. lib_extension
  if commit_hash ~= nil then return path .. '.' .. commit_hash:sub(1, 7) end
  return path
end

--- @param name string Name of the library to resolve (e.g. 'blink_cmp_fuzzy')
--- @param commit_hash? string Commit hash of the library to resolve (e.g. 'e5678fe566e86553403b3129a3684389c84fafb5'). If omitted, `lib$name.so.hash` will be skipped, and only `lib$name.so` will be attempted.
--- @return string library_path
function native.resolve(name, commit_hash)
  -- $runtimepath/lib/lib*.so.hash
  local lib_paths = commit_hash ~= nil
      and vim.api.nvim_get_runtime_file('lib/lib' .. name .. lib_extension .. '.' .. commit_hash:sub(1, 7), true)
    or {}
  if #lib_paths == 0 then
    -- fallback to $runtimepath/lib/lib*.so
    lib_paths = vim.api.nvim_get_runtime_file('lib/lib' .. name .. lib_extension, true)
  end

  if #lib_paths > 1 then
    error('Found multiple instances of the same library (' .. name .. '): ' .. table.concat(lib_paths, ', '))
  end
  return lib_paths[1]
end

--- @param name string Name of the library to load (e.g. 'blink_cmp_fuzzy')
--- @param commit_hash string? Commit hash of the library to load (e.g. 'e5678fe566e86553403b3129a3684389c84fafb5'). If omitted, `lib$name.so.hash` will be skipped, and only `lib$name.so` will be attempted.
--- @return any library
function native.load(name, commit_hash)
  local lib_path = native.resolve(name, commit_hash)
  if lib_path == nil then return error('Failed to resolve library in $runtimepath/lib/: ' .. name) end

  -- load the library
  local loader, err = package.loadlib(lib_path, 'luaopen_' .. name)
  if err or not loader then return error('Failed to load library: ' .. err or 'unknown error') end
  return loader()
end

--- @param url string
--- @param path string Where to save the library
--- @param callback fun(err: string)
function native.download(url, path, callback)
  vim.net.request(url, { outpath = path }, function(err) callback(err) end)
end

--- @param url string
--- @param path string Where to save the library
--- @return blink.lib.Task
function native.download_async(url, path)
  return require('blink.lib.task').wrap(function(callback) native.download(url, path, callback) end)
end

--- @param cwd string
--- @param cmd string[]
--- @param logger blink.lib.Logger
--- @param callback fun(err?: string, process: vim.SystemCompleted)
function native.exec(cwd, cmd, logger, callback)
  logger:write_to_file('---\n')
  logger:write_to_file('Working directory: ' .. cwd .. '\n')
  logger:write_to_file('Command: ' .. table.concat(cmd, ' ') .. '\n')
  logger:write_to_file('---\n')
  return vim.system(cmd, {
    cwd = cwd,
    stdout = function(_, data) logger:write_to_file(data) end,
    stderr = function(_, data) logger:write_to_file(data) end,
  }, function(res)
    logger:write_to_file('---\n')
    if res.code ~= 0 then
      callback('Failed with exit code ' .. res.code .. ': ' .. res.stderr)
    else
      callback(nil, res)
    end
  end)
end

--- @param cwd string
--- @param cmd string[]
--- @param logger blink.lib.Logger
--- @return blink.lib.Task<vim.SystemCompleted>
function native.exec_async(cwd, cmd, logger)
  return require('blink.lib.task').wrap(function(callback) native.exec(cwd, cmd, logger, callback) end)
end

--- Recursively creates a directory, no-op if the directory already exists
--- @param path string
function native.mkdirp(path)
  -- Synchronous so callers (like `native.mv`) can safely write into `path`
  -- immediately afterwards without racing the directory creation.
  vim.fn.mkdir(path, 'p')
end

--- Move a file from one location to another, creating all intermediate directories at dst
--- @param src string
--- @param dst string
function native.mv(src, dst)
  native.mkdirp(vim.fs.dirname(dst))
  local ok, err = vim.uv.fs_rename(src, dst)
  if not ok then error(err) end
end

--------------------
--- Git
--------------------

--- @param path string Path to the repository root or some path inside the repository
--- @return string? git_repo_root Path to the repository root
function native.git_repo_root(path)
  local git_dir = vim.fs.find('.git', { upward = true, path = vim.fs.normalize(path), type = 'directory' })[1]
  if not git_dir then return end
  return vim.fn.fnamemodify(git_dir, ':h')
end

--- @param path string Path to the repository root or some path inside the repository
--- @return string commit_hash For example 'e5678fe566e86553403b3129a3684389c84fafb5'
function native.git_commit(path)
  --- @param p string
  --- @return string?
  function read_file(p)
    local fd, err = vim.uv.fs_open(p, 'r', 438) -- 438 = 0666
    if not fd then error(err) end
    local content = vim.uv.fs_read(fd, 1024, 0)
    vim.uv.fs_close(fd)
    return content
  end

  -- Walk up from the module file to find the .git directory
  local git_dir = vim.fs.find('.git', { upward = true, path = vim.fs.normalize(path), type = 'directory' })[1]
  if not git_dir then error('Failed to find .git directory for path: ' .. path) end

  -- Read HEAD
  local head_path = git_dir .. '/HEAD'
  local head_content = read_file(head_path)
  if not head_content then error('Failed to read ' .. head_path) end
  head_content = vim.trim(head_content)

  -- If HEAD is a direct commit hash (detached HEAD)
  if head_content:match('^%x+$') then return head_content end

  -- HEAD contains a ref, e.g. "ref: refs/heads/main"
  local ref = head_content:match('^ref: (.+)$')
  if not ref then error('Failed to parse HEAD: ' .. head_content) end

  -- Try to read the loose ref file (e.g. .git/refs/heads/main)
  local ref_path = git_dir .. '/' .. ref
  local ref_content = read_file(ref_path)
  if ref_content then return vim.trim(ref_content) end

  -- Fallback to git CLI
  local result = vim.system({ 'git', 'rev-parse', 'HEAD' }, { cwd = path }):wait(1000)
  if result.code ~= 0 or result.stdout == nil then error('Failed to get git commit: ' .. (result.stderr or '')) end
  return result.stdout
end

--- Unlike `git_commit(path)`, this function will simply return `nil` if the git commit cannot be determined
--- @param path string Path to the repository root or some path inside the repository
--- @return string? commit_hash For example 'e5678fe566e86553403b3129a3684389c84fafb5'
function native.try_git_commit(path)
  local success, commit_hash = pcall(native.git_commit, path)
  if success then return commit_hash end
end

--- @param path string Path to the repository root or some path inside the repository
--- @return string? tag For example 'v0.0.1'
function native.git_tag(path)
  local process = vim.system({ 'git', 'describe', '--tags', '--exact-match' }, { cwd = path }):wait(1000)
  if process.code == 0 then return process.stdout:match('(%w+)\n') end
end

return native
