--- Creates an in-process LSP server usable as `cmd` in |vim.lsp.start|.
---
--- Handlers may respond in two ways:
---   Sync:  `return result, err`
---   Async: call `ctx.respond(result, err)`, optionally returning a cancellation function
---
--- @param opts blink.lib.lsp.server.Opts
--- @return fun(dispatchers: vim.lsp.rpc.Dispatchers): vim.lsp.rpc.Client
local function new(opts)
  local name = opts.name
  local handlers = opts.handlers or {}
  local notifications = opts.notifications or {}
  local settings = opts.default_settings or {}

  -----------------------
  --- Lifecycle

  handlers.initialize = function(params, ctx)
    local capabilities = opts.capabilities
    if type(capabilities) == 'function' then capabilities = capabilities(params) end
    ctx.respond(capabilities)

    local response, err = dispatchers.server_request(
      'workspace/configuration',
      { items = { { scopeUri = 'file:///proj', section = name } } }
    )
    if response and response[1] then
      -- `blink.lib.config` used for settings, merge with validation
      if settings.__blink_lib_config then
        local ok, err = pcall(settings, response[1])
        if not ok then
          dispatchers.on_error(vim.lsp.protocol.ErrorCodes.InternalError, 'Invalid setting for ' .. name .. ': ' .. err)
        end
      -- plain table
      else
        settings = vim.tbl_deep_extend('force', settings, response[1])
      end
    end
  end

  handlers.shutdown = function(params, ctx)
    -- respond to all pending requests with an error
    for id, pending_ctx in pairs(pending) do
      pending_ctx.cancel({ code = vim.lsp.protocol.ErrorCodes.ServerCancelled, message = 'Server is shutting down' })
    end
    ctx.respond()
  end

  notifications.exit = function() dispatchers.on_exit(0, 15) end

  -----------------------
  --- Cancellation

  notifications['$/cancelRequest'] = function(params, ctx)
    local ctx = pending[params.id]
    if not ctx then return end
    ctx.cancel({ code = vim.lsp.protocol.ErrorCodes.RequestCancelled, message = 'Request cancelled' })
  end

  ----------------------
  --- Server

  --- @param dispatchers vim.lsp.rpc.Dispatchers
  --- @return vim.lsp.rpc.Client
  return function(dispatchers)
    local closing = false
    local request_id = 0
    local pending = {} --- @type table<integer, blink.lib.lsp.server.Ctx>

    local srv = {}

    function srv.request(method, params, callback)
      request_id = request_id + 1
      local id = request_id

      if closing then
        callback({ code = vim.lsp.protocol.ErrorCodes.ServerCancelled, message = 'Server is shutting down' }, nil)
        return true, id
      end

      local handler = handlers[method]
      if not handler then
        callback({ code = vim.lsp.protocol.ErrorCodes.MethodNotFound, message = 'Method not found: ' .. method }, nil)
        return true, id
      end

      cancel_fn = function() end
      local ctx = {
        id = id,
        settings = settings,
        notify = function(m, p) dispatchers.notification(m, p) end,
        request = function(m, p, cb) return dispatchers.server_request(m, p, cb) end,
        cancel = function(err)
          if not pending[id] then return end
          ctx.respond(
            nil,
            err or { code = vim.lsp.protocol.ErrorCodes.RequestCancelled, message = 'Request cancelled' }
          )
          cancel_fn()
        end,
        is_cancelled = function() return closing or not pending[id] end,
        respond = function(result, err)
          if closing or not pending[id] then return end
          pending[id] = nil
          callback(err, result)
        end,
      }
      pending[id] = ctx

      local ok, ret1, ret2 = pcall(handler, params, ctx)
      -- failed
      if not ok then
        ctx.respond(nil, { code = vim.lsp.protocol.ErrorCodes.InternalError, message = tostring(ret1) })
      elseif type(ret1) == 'function' then
        -- asynchronous response: ret1=cancel_fn, ret2=nil
        cancel_fn = ret1
      elseif ret1 ~= nil then
        -- synchronous response: ret1=result, ret2=err
        ctx.respond(ret1, ret2)
      end

      return true, id
    end

    function srv.notify(method, params)
      local handler = notifications[method]
      if not handler then return end

      -- notifications: no id, cancelled, or respond
      local ok, err = pcall(handler, params, {
        notify = function(m, p) dispatchers.notification(m, p) end,
        request = function(m, p, cb) dispatchers.server_request(m, p, cb) end,
      })
      if not ok then dispatchers.on_error(vim.lsp.protocol.ErrorCodes.InternalError, err) end
    end

    function srv.is_closing() return closing end
    function srv.terminate() closing = true end

    return srv
  end
end

return new
