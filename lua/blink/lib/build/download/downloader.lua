local task = require('blink.lib.task')
local config = require('blink.lib.download.config')
local system = require('blink.lib.download.system')
local fs = require('blink.lib.fs')

local downloader = {}

--- @param files blink.lib.download.files
--- @param get_download_url fun(version: string, system_triple: string, extension: string): string
--- @param version string
--- @return blink.lib.Task
function downloader.download(files, get_download_url, version)
  -- set the version to 'v0.0.0' to avoid a failure causing the pre-built binary being marked as locally built
  return files
    :set_version('v0.0.0')
    -- get system triple
    :map(function() return system.get_triple() end)
    :map(function(system_triple)
      if not system_triple then return error('Your system is not supported by pre-built binaries') end
      return get_download_url(version, system_triple, files.get_lib_extension())
    end)
    -- Mac caches the library in the kernel, so updating in place causes a crash
    -- We instead write to a temporary file and rename it, as mentioned in:
    -- https://developer.apple.com/documentation/security/updating-mac-software
    :map(
      function(library_url) return downloader.download_file(files, library_url, files.lib_filename .. '.tmp') end
    )
    :map(
      function()
        return fs.rename(
          files.lib_folder .. '/' .. files.lib_filename .. '.tmp',
          files.lib_folder .. '/' .. files.lib_filename
        )
      end
    )
    :map(function() return files:set_version(version) end)
end

--- @param files blink.lib.download.files
--- @param url string
--- @param filename string
--- @return blink.lib.Task
function downloader.download_file(files, url, filename)
  return task.new(function(resolve, reject)
    local args = { 'curl' }

    -- Use https proxy if available
    if config.proxy.url ~= nil then
      vim.list_extend(args, { '--proxy', config.proxy.url })
    elseif config.proxy.from_env then
      local proxy_url = os.getenv('HTTPS_PROXY')
      if proxy_url ~= nil then vim.list_extend(args, { '--proxy', proxy_url }) end
    end

    vim.list_extend(args, config.extra_curl_args)
    vim.list_extend(args, {
      '--fail', -- Fail on 4xx/5xx
      '--location', -- Follow redirects
      '--silent', -- Don't show progress
      '--show-error', -- Show errors, even though we're using --silent
      '--create-dirs',
      '--output',
      files.lib_folder .. '/' .. filename,
      url,
    })

    vim.system(args, {}, function(out)
      if out.code ~= 0 then
        reject('Failed to download ' .. filename .. 'for pre-built binaries: ' .. out.stderr)
      else
        resolve()
      end
    end)
  end)
end

return downloader
