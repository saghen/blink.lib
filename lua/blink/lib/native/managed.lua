--- An opinionated setup for building/downloading native libraries, used by all `blink.* plugins

local native = require('blink.lib.native')
local async = require('blink.lib.async')

--- @class blink.lib.native.managed
--- @field module_name string
--- @field library_name string
--- @field logger blink.lib.Logger
--- @field repo_root? string
--- @field git_commit? string
--- @field task? vim.async.Task Currently running build/download task
local managed = {}

--- @class blink.lib.native.managed.Opts
--- @field module_name string Name of the module for logging (`'blink.cmp'`)
--- @field library_name string Name of the library for logging and loading (`'blink_cmp_fuzzy'`)
--- @field current_file_path string Path to the current file (`debug.getinfo(1, 'S').source:sub(2)`)
--- @field logger blink.lib.Logger

--- @param opts blink.lib.native.managed.Opts
--- @return blink.lib.native.managed
function managed.new(opts)
  local repo_root = native.git_repo_root(opts.current_file_path)
  return setmetatable({
    module_name = opts.module_name,
    library_name = opts.library_name,
    logger = opts.logger,
    repo_root = repo_root,
    git_commit = repo_root and native.try_git_commit(repo_root),
    task = nil,
  }, { __index = managed })
end

function managed:library_available() return native.resolve(self.library_name, self.git_commit) ~= nil end

function managed:load() return native.load(self.library_name, self.git_commit) end

--- Builds the precompiled library if it's not already available
--- @param command string[]
--- @param get_artifact_paths fun(repo_root: string, platform: blink.lib.native.Platform): string[] Returns a list of all possible artifact paths, ordered by preference
--- @param opts? { force?: boolean, dev?: boolean }
--- @return vim.async.Task
function managed:build(command, get_artifact_paths, opts)
  local logger = self.logger
  return self:run_task(self.module_name .. ':build', function()
    -- ensure repository is available for native.resolve()
    assert(self.repo_root ~= nil, 'Could not find git repo root, did you install via a package manager?')
    vim.opt.runtimepath:append(self.repo_root)

    -- the commit may have changed since this module was loaded, so re-read it
    local current_commit = native.try_git_commit(self.repo_root)
    if current_commit ~= nil then self.git_commit = current_commit end

    opts = opts or {}
    if not opts.force and self:library_available() then return end

    logger:notify(vim.log.levels.INFO, 'Building ' .. self.module_name .. ' native library...')

    native.exec_async(self.repo_root, command, logger)

    local artifact_paths = get_artifact_paths(self.repo_root, native.platform())
    local git_commit = not opts.dev and self.git_commit or nil
    assert(opts.dev or git_commit ~= nil, 'Could not find git commit')
    local library_path = native.library_path(self.repo_root, self.library_name, git_commit)

    -- move artifact to library path
    local found_artifact = false
    for _, artifact_path in ipairs(artifact_paths) do
      if vim.uv.fs_stat(artifact_path) ~= nil then
        found_artifact = true
        native.mv(artifact_path, library_path)
        break
      end
    end
    assert(found_artifact, 'Failed to find any of the following artifact paths: ' .. table.concat(artifact_paths, ', '))

    -- ensure the library loads
    assert(native.resolve(self.library_name, git_commit) ~= nil, 'Failed to load built library')
    if opts.force and not opts.dev then
      -- remove the fallback so future updates trigger a rebuild
      local dev_path = native.library_path(self.repo_root, self.library_name)
      local ok, err, code = vim.uv.fs_unlink(dev_path)
      if not ok and code ~= 'ENOENT' then
        logger:notify(vim.log.levels.WARN, 'Failed to delete dev artifact: ' .. tostring(err))
      end
    end
    logger:notify(vim.log.levels.INFO, 'Successfully built ' .. self.module_name .. ' native library')
  end, function(err) return 'Failed to build ' .. self.module_name .. ' native library: ' .. tostring(err) end)
end

--- Downloads the precompiled library if it's not already available
--- @param get_download_url fun(git_tag: string, platform: blink.lib.native.Platform): string
--- @param opts? { force?: boolean, match?: string }
--- @return vim.async.Task
function managed:download(get_download_url, opts)
  local logger = self.logger
  return self:run_task(self.module_name .. ':download', function()
    -- ensure repository is available for native.resolve()
    assert(self.repo_root ~= nil, 'Could not find git repo root, did you install via a package manager?')
    vim.opt.runtimepath:append(self.repo_root)

    -- the commit may have changed since the module was loaded, so re-read it
    local current_commit = native.try_git_commit(self.repo_root)
    if current_commit ~= nil then self.git_commit = current_commit end

    opts = opts or {}
    if not opts.force and self:library_available() then return end

    logger:notify(vim.log.levels.INFO, 'Downloading ' .. self.module_name .. ' precompiled library')

    local git_tag = native.git_tag(self.repo_root, opts.match)
    assert(
      git_tag ~= nil,
      'Missing git tag, have you pinned the version? Set `version = "*"` for lazy.nvim or `version = vim.version.range("*")` for vim.pack'
    )

    local platform = native.platform()
    if platform.triple == nil then
      error(string.format('Unknown platform (os: %s, arch: %s)', platform.os, platform.arch))
    end

    assert(self.git_commit ~= nil, 'Could not find git commit')
    local library_path = native.library_path(self.repo_root, self.library_name, self.git_commit)
    local download_url = get_download_url(git_tag, platform)
    logger:debug('Downloading native library from: ' .. download_url)

    native.download_async(download_url, library_path)

    assert(native.resolve(self.library_name, self.git_commit) ~= nil, 'Failed to load downloaded library')
    logger:notify(vim.log.levels.INFO, 'Successfully downloaded ' .. self.module_name .. ' native library')
  end, function(err) return 'Failed to download ' .. self.module_name .. ' native library: ' .. tostring(err) end)
end

--- Returns the current running task, if any
--- @return vim.async.Task?
function managed:current_task() return self.task end

--- Runs `fn` as a top-level task, notifying on failure. Returns the running task if one is in flight.
--- @private
--- @param name string
--- @param fn async fun()
--- @param err_msg fun(err: any): string
--- @return vim.async.Task
function managed:run_task(name, fn, err_msg)
  if self.task ~= nil and not self.task:completed() then return self.task end

  local logger = self.logger
  self.task = async.run(name, function()
    local ok, err = async.pawait(async.run(name, fn))
    if not ok then
      logger:notify(vim.log.levels.ERROR, err_msg(err))
      error(err, 0)
    end
  end)
  return self.task
end

return managed
