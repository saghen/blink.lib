--- An opinionated setup for building/downloading native libraries, used by all `blink.* plugins

local native = require('blink.lib.native')
local task = require('blink.lib.task')

--- @class blink.lib.native.managed
local managed = {}

--- @class blink.lib.native.managed.Opts
--- @field module_name string Name of the module for logging (`'blink.cmp'`)
--- @field library_name string Name of the library for logging and loading (`'blink_cmp_fuzzy'`)
--- @field current_file_path string Path to the current file (`debug.getinfo(1, 'S').source:sub(2)`)
--- @field logger blink.lib.Logger

--- @param opts blink.lib.native.managed.Opts
--- @return blink.lib.native.managed
function managed.new(opts) return setmetatable(opts, { __index = managed }) end

function managed:library_available()
  local git_commit = native.try_git_commit(self.current_file_path)
  return native.resolve(self.library_name, git_commit) ~= nil
end

--- Builds the precompiled library if it's not already available
--- @param command string[]
--- @param get_artifact_paths fun(repo_root: string, platform: blink.lib.native.Platform): string[] Returns a list of all possible artifact paths, ordered by preference
--- @param opts? { force?: boolean, dev?: boolean }
--- @return blink.lib.Task
function managed:build(command, get_artifact_paths, opts)
  local logger = self.logger
  return task
    .resolve()
    :map(function()
      opts = opts or {}
      if not opts.force and self:library_available() then return end

      logger:notify(vim.log.levels.INFO, 'Building ' .. self.module_name .. ' native library...')

      local repo_root = native.git_repo_root(self.current_file_path)
      if repo_root == nil then error('missing git repo root, did you install via a package manager?') end

      return native.exec_async(repo_root, command, logger):map(function(_system)
        -- move artifact to library path
        local platform = native.platform()
        local artifact_paths = get_artifact_paths(repo_root, platform)
        local git_commit = not opts.dev and native.git_commit(self.current_file_path) or nil
        local library_path = native.library_path(self.library_name, git_commit)

        for _, artifact_path in ipairs(artifact_paths) do
          if vim.uv.fs_stat(artifact_path) ~= nil then
            native.mv(artifact_path, library_path)
            break
          end
        end

        -- ensure the library loads
        if not native.resolve(self.library_name, native.git_commit(self.current_file_path)) then
          error('failed to load after building')
        end
        logger:notify(vim.log.levels.INFO, 'Successfully loaded built ' .. self.module_name .. ' native library')
      end)
    end)
    :catch(function(build_err)
      logger:notify(vim.log.levels.ERROR, 'Failed to build ' .. self.module_name .. ' native library: ' .. build_err)
      error(build_err)
    end)
end

--- Downloads the precompiled library if it's not already available
--- @param get_download_url fun(git_tag: string, platform: blink.lib.native.Platform): string
--- @param opts? { force?: boolean, match?: string }
--- @return blink.lib.Task
function managed:download(get_download_url, opts)
  local logger = self.logger
  return task
    .new(function(resolve, _reject)
      opts = opts or {}
      if not opts.force and self:library_available() then return resolve() end

      logger:notify(vim.log.levels.INFO, 'Downloading ' .. self.module_name .. ' precompiled library')

      local git_tag = native.git_tag(self.current_file_path, opts.match)
      if git_tag == nil then error('missing git tag, have you pinned the version?') end

      local platform = native.platform()
      if platform.triple == nil then error('unknown platform (' .. platform.triple .. ')') end

      local git_commit = native.git_commit(current_file_path)
      local library_path = native.library_path(self.library_name, git_commit)
      local download_url = get_download_url(git_tag, platform)
      logger:debug('Downloading native library from: ' .. download_url)

      return native.download_async(download_url, library_path):map(function()
        if not native.load(self.library_name, native.git_commit(current_file_path)) then
          error('failed to load after downloading')
        end
        logger:notify(vim.log.levels.INFO, 'Successfully downloaded ' .. self.module_name .. ' native library')
      end)
    end)
    :catch(function(download_err)
      logger:notify(
        vim.log.levels.ERROR,
        'Failed to download ' .. self.module_name .. ' native library: ' .. download_err
      )
      error(download_err)
    end)
end

return managed
