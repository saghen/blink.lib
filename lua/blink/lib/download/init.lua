local task = require('blink.lib.task')
local git = require('blink.lib.download.git')

--- @class blink.download.Options
--- @field download_url (fun(version: string, system_triple: string, extension: string): string) | nil
--- @field on_download fun()
--- @field root_dir string
--- @field output_dir string
--- @field binary_name string
--- @field force_version string | nil

--- @class blink.download.API
local download = {}

--- @param options blink.download.Options
--- @param callback fun(err: string | nil)
function download.ensure_downloaded(options, callback)
  callback = vim.schedule_wrap(callback)

  local files = require('blink.lib.download.files').new(options.root_dir, options.output_dir, options.binary_name)
  require('blink.lib.download.cpath')(files.lib_folder)

  task
    .all({ git.get_version(files.root_dir), files:get_version() })
    :map(function(results) return { git = results[1], current = results[2] } end)
    :map(function(version)
      -- no version file found, user manually placed the .so file or build the plugin manually
      if version.current.missing then
        local shared_library_found, _ = pcall(require, options.binary_name)
        if shared_library_found then return end
      end

      -- downloading disabled, not built locally
      if not options.download_url then error('No rust library found, but downloading is disabled.') end

      -- downloading enabled, not on a git tag
      local target_git_tag = options.force_version or version.git.tag
      if target_git_tag == nil then
        error("No rust library found, but can't download due to not being on a git tag.")
      end

      -- already downloaded and the correct version
      if version.current.tag == target_git_tag then return end

      -- download
      if options.on_download then vim.schedule(function() options.on_download() end) end
      local downloader = require('blink.lib.download.downloader')
      return downloader.download(files, options.download_url, target_git_tag)
    end)
    :map(function() callback() end)
    :catch(function(err) callback(err) end)
end

return download
