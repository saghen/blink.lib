package.path = package.path .. ';../async.nvim/lua/?.lua'

local blink = require('blink.lib.async')
local nvim = require('async')

local blink_adapter = {
  run = blink.run,
  await = blink.await,
  schedule = function() return blink.await(vim.schedule) end,
  semaphore = blink.semaphore,
  await_never_cleanup = function()
    blink.await(function(_)
      return function() end
    end)
  end,
  all = blink.all,

  fs_open = function(path, flags, mode)
    return blink.await(function(cb) return vim.uv.fs_open(path, flags, mode, cb) end)
  end,
  fs_read = function(fd, size, offset)
    return blink.await(function(cb) return vim.uv.fs_read(fd, size, offset, cb) end)
  end,
  fs_write = function(fd, data, offset)
    return blink.await(function(cb) return vim.uv.fs_write(fd, data, offset, cb) end)
  end,
  fs_close = function(fd)
    return blink.await(function(cb) return vim.uv.fs_close(fd, cb) end)
  end,
  fs_stat = function(path)
    return blink.await(function(cb) return vim.uv.fs_stat(path, cb) end)
  end,
}

local nvim_adapter = {
  run = nvim.run,
  await = nvim.await,
  schedule = function() return nvim.await(vim.schedule) end,
  semaphore = nvim.semaphore,
  await_never_cleanup = function()
    nvim.await(function(_)
      return {
        close = function(_, cb)
          if cb then cb() end
        end,
      }
    end)
  end,
  all = nvim.await_all,

  fs_open = function(path, flags, mode)
    local err, fd = nvim.await(4, vim.uv.fs_open, path, flags, mode)
    if err then error(err) end
    return fd
  end,
  fs_read = function(fd, size, offset)
    local err, data = nvim.await(4, vim.uv.fs_read, fd, size, offset)
    if err then error(err) end
    return data
  end,
  fs_write = function(fd, data, offset)
    local err, bytes = nvim.await(4, vim.uv.fs_write, fd, data, offset)
    if err then error(err) end
    return bytes
  end,
  fs_close = function(fd)
    local err, success = nvim.await(2, vim.uv.fs_close, fd)
    if err then error(err) end
    return success
  end,
  fs_stat = function(path)
    local err, stat = nvim.await(2, vim.uv.fs_stat, path)
    if err then error(err) end
    return stat
  end,

  fs_read_file = function(path, size)
    local err, fd = nvim.await(4, vim.uv.fs_open, path, 'r', 420)
    if err then error(err) end

    local err, data = nvim.await(function(cb)
      vim.uv.fs_read(fd, size, 0, cb)
      return { close = function(_, close_cb) vim.uv.fs_close(fd, close_cb) end }
    end)
    if err then error(err) end
    return data
  end,

  lsp_request = function(bufnr, method, params)
    return nvim.await(function(cb)
      local _, cancel_all_requests = vim.lsp.buf_request(bufnr, method, params, cb)
      return {
        cancel = function(_, close_cb)
          cancel_all_requests()
          close_cb()
        end,
      }
    end)
  end,
}

local function compare(group)
  local flatten = require('blink.lib._.list.flatten')
  local b = require('blink.lib.bench')

  local opts = { warmup = '200ms', measurement = '1s', output = false }
  local nvim_group = b.group(flatten({ 'nvim', group }), opts)
  local blink_group = b.group(flatten({ 'blink', group }), opts)

  return function(name, fn)
    local r1 = blink_group.run(name, function() return fn(blink_adapter) end, { output = true })
    local r2 = nvim_group.run(name, function() return fn(nvim_adapter) end)
    r1:compare(r2)
  end
end
return compare
