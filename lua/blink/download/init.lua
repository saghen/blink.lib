local task = require('blink.lib.task')

--- @class blink.lib.download.Opts
--- @field download_url? fun(version: string, system_triple: string, extension: string): string
--- @field on_download? fun()
--- @field root_dir string
--- @field output_dir string
--- @field binary_name string
--- @field force_version? string

--- @class blink.lib.download
local download = {}

--- @param opts blink.lib.download.Opts
--- @param callback fun(err?: any)
function download.ensure_downloaded(opts, callback)
  local git = require('blink.download.git')
  local files = require('blink.download.files').new(opts.root_dir, opts.output_dir, opts.binary_name)
  require('blink.download.cpath')(files.lib_folder)

  return task
    .all({ git.get_version(files.root_dir), files:get_version() })
    :map(function(results) return { git = results[1], current = results[2] } end)
    :map(function(version)
      -- no version file found, user manually placed the .so file or build the plugin manually
      if version.current.missing then
        local shared_library_found, _ = pcall(require, opts.binary_name)
        if shared_library_found then return end
      end

      -- downloading disabled, not built locally
      if not opts.download_url then error('No rust library found, but downloading is disabled.') end

      -- downloading enabled, not on a git tag
      local target_git_tag = opts.force_version or version.git.tag
      if target_git_tag == nil then
        error("No rust library found, but can't download due to not being on a git tag.")
      end

      -- already downloaded and the correct version
      if version.current.version == target_git_tag then return end

      -- download
      if opts.on_download then vim.schedule(function() opts.on_download() end) end
      local downloader = require('blink.download.downloader')
      return downloader.download(files, opts.download_url, target_git_tag)
    end)
    :map(function() vim.schedule(callback) end)
    :catch(function(err)
      vim.schedule(function() callback(err) end)
    end)
end

return download
