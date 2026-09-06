--- In-process server factory. `M.new(opts)` returns a `cmd` function for `vim.lsp.config` /
--- `vim.lsp.start`; nvim calls it once per client instance with the resolved `vim.lsp.ClientConfig`.
---
--- Every request and notification handler runs as its own top-level `vim.async` task. A request
--- responds when its task completes: return value → result, `error()` → `InternalError`,
--- `$/cancelRequest` → `RequestCancelled`, `shutdown` → `ServerCancelled`. `initialize` never fails.
---
--- Error path, shared by handlers, `validate`, `on_*` callbacks and `capabilities` functions:
--- `window/logMessage` with a traceback (always), `window/showMessage` once per site per instance,
--- an `InternalError` response where a request exists. Never `dispatchers.on_error`.
local async = vim.async
local protocol = vim.lsp.protocol
local ErrorCodes = protocol.ErrorCodes
local MessageType = protocol.MessageType
local util = require('blink.lib.lsp.util')

local M = {}

--- Runs `fn` on the main loop: immediately when already there, via `vim.schedule` from a fast event
--- @param fn fun()
local function on_main(fn)
  if vim.in_fast_event() then
    vim.schedule(fn)
  else
    fn()
  end
end

--- @param code integer
--- @param message? string
--- @return lsp.ResponseError
local function rpc_error(code, message) return vim.lsp.rpc.rpc_response_error(code, message) end

--- @param opts blink.lib.lsp.server.Opts
local function validate_opts(opts)
  vim.validate('opts', opts, 'table')
  vim.validate('opts.name', opts.name, 'string')
  vim.validate('opts.capabilities', opts.capabilities, { 'table', 'function' }, true)
  vim.validate('opts.settings', opts.settings, 'table', true)
  vim.validate('opts.validate', opts.validate, 'function', true)
  vim.validate('opts.handlers', opts.handlers, 'table', true)
  vim.validate('opts.notifications', opts.notifications, 'table', true)
  for _, key in ipairs({ 'on_init', 'on_attach', 'on_detach', 'on_settings', 'on_exit' }) do
    vim.validate('opts.' .. key, opts[key], 'function', true)
  end
end

--- @param opts blink.lib.lsp.server.Opts
--- @return fun(dispatchers: vim.lsp.rpc.Dispatchers, config: vim.lsp.ClientConfig): vim.lsp.rpc.Client
function M.new(opts)
  validate_opts(opts)
  local handlers = opts.handlers or {}
  local notifications = opts.notifications or {}

  -- `settings` is either plain defaults or a `blink.lib.ConfigSchemaObject` (duck-typed, so that
  -- `blink.lib.config` is not loaded for servers that don't use it)
  local settings = opts.settings or {}
  local is_schema = settings.__blink_lib_schema == true
  local default_settings = is_schema and settings.default or settings --- @type table
  --- @param merged table
  local function validate_settings(merged)
    if is_schema then settings.validate(merged) end
    if opts.validate ~= nil then opts.validate(merged) end
  end

  return function(dispatchers, config)
    local name = opts.name
    local closing = false
    local next_id = 0
    local pending = {} --- @type table<integer, vim.async.Task> Request tasks by id
    local tasks = {} --- @type table<vim.async.Task, true> Every live handler task
    local cancel_codes = {} --- @type table<integer, integer> Error code to respond with once a closed request completes
    local reported = {} --- @type table<string, true> Sites already surfaced via `window/showMessage`
    local registrations = {} --- @type table<string, string> Registration id → method
    local counters = { registration = 0, progress = 0 }
    local client --- @type vim.lsp.Client?
    local init_params --- @type lsp.InitializeParams?
    local last_settings = config.settings --- @type table? Last `settings` received, to skip no-op changes

    --- @type vim.lsp.rpc.Client
    --- @diagnostic disable-next-line: missing-fields
    local rpc = {}

    --- @type blink.lib.lsp.Server
    --- @diagnostic disable-next-line: missing-fields
    local srv = { name = name, config = config, settings = {}, capabilities = {}, state = {}, rpc = rpc }

    --- Notifications are delivered from the event loop, like an out-of-process server would: a
    --- synchronous `window/showMessage` would raise inside the autocmd or request that caused it
    --- @param method string
    --- @param params table
    local function notification(method, params)
      vim.schedule(function() dispatchers.notification(method, params) end)
    end

    --- @param site string
    --- @param err any Message, usually with a traceback
    local function report(site, err)
      local message = ('%s: %s'):format(site, tostring(err))
      notification('window/logMessage', { type = MessageType.Error, message = message })

      if reported[site] then return end
      reported[site] = true
      -- first line only, the log has the rest
      notification('window/showMessage', { type = MessageType.Error, message = message:match('^[^\n]*') })
    end

    --- Calls an `on_*` callback through the error path
    --- @param site string
    --- @param fn? function
    local function callback(site, fn, ...)
      if fn == nil then return end
      local ok, err = xpcall(fn, debug.traceback, ...)
      if not ok then report(site, err) end
    end

    --- Merges `incoming` over the defaults and validates. Returns nil when validation fails.
    --- @param incoming? table
    --- @return table?
    local function resolve_settings(incoming)
      local merged = vim.tbl_deep_extend('force', vim.deepcopy(default_settings), incoming or {})
      local ok, err = pcall(validate_settings, merged)
      if not ok then
        report('settings', 'invalid settings: ' .. tostring(err))
        return nil
      end
      return merged
    end
    srv.settings = resolve_settings(config.settings) or vim.deepcopy(default_settings)

    ---------- Server API ----------

    function srv.client()
      if client ~= nil then return client end
      for _, c in ipairs(vim.lsp.get_clients()) do
        if c.rpc == rpc then
          client = c
          return c
        end
      end
      error(('blink.lib.lsp: no vim.lsp.Client found for server "%s"'):format(name))
    end

    function srv.notify(method, params) notification(method, params) end

    function srv.request(method, params)
      assert(not vim.in_fast_event(), 'blink.lib.lsp: srv.request() must run on the main loop')
      return dispatchers.server_request(method, params)
    end

    function srv.register(method, register_options)
      counters.registration = counters.registration + 1
      local id = ('%s/%d'):format(name, counters.registration)
      registrations[id] = method
      local _, err = srv.request('client/registerCapability', {
        registrations = { { id = id, method = method, registerOptions = register_options } },
      })
      if err ~= nil then error(vim.lsp.rpc.format_rpc_error(err)) end
      return id
    end

    function srv.unregister(id)
      local method = registrations[id]
      if method == nil then return end
      registrations[id] = nil
      srv.request('client/unregisterCapability', { unregisterations = { { id = id, method = method } } })
    end

    function srv.progress(title)
      counters.progress = counters.progress + 1
      local token = ('%s/progress/%d'):format(name, counters.progress)
      srv.request('window/workDoneProgress/create', { token = token })
      srv.notify('$/progress', { token = token, value = { kind = 'begin', title = title } })
      return {
        report = function(message, percentage)
          srv.notify(
            '$/progress',
            { token = token, value = { kind = 'report', message = message, percentage = percentage } }
          )
        end,
        done = function(message)
          srv.notify('$/progress', { token = token, value = { kind = 'end', message = message } })
        end,
      }
    end

    function srv.log(level, message) srv.notify('window/logMessage', { type = level, message = message }) end

    ---------- Tasks ----------

    --- Runs a handler as a top-level task
    --- @param method string
    --- @param id? integer
    --- @param handler function
    --- @param params table
    --- @param on_done fun(err: any, result: any, task: vim.async.Task)
    local function run(method, id, handler, params, on_done)
      local ctx = { id = id, method = method, srv = srv }
      local task_name = id and ('lsp:%s:%s:%d'):format(name, method, id) or ('lsp:%s:%s'):format(name, method)
      -- detach: the request may come from inside another task, and must not become its child
      local task = async.run(task_name, handler, params, ctx):detach()
      ctx.task = task
      tasks[task] = true
      if id ~= nil then pending[id] = task end
      task:on_complete(function(err, result)
        tasks[task] = nil
        if id ~= nil then pending[id] = nil end
        on_done(err, result, task)
      end)
    end

    --- @param task vim.async.Task
    --- @param err any
    --- @return string
    local function traceback(task, err)
      local ok, tb = pcall(task.traceback, task, tostring(err))
      return ok and tb or tostring(err)
    end

    --- Closes every live task; pending requests respond with `code`
    --- @param code integer
    local function cancel_all(code)
      for id, task in pairs(pending) do
        cancel_codes[id] = code
        task:close()
      end
      for task in pairs(tasks) do
        task:close()
      end
    end

    local function exit()
      if closing then return end
      closing = true
      cancel_all(ErrorCodes.ServerCancelled)
      callback('on_exit', opts.on_exit, srv)
      on_main(function() dispatchers.on_exit(0, 15) end)
    end

    ---------- RPC ----------

    function rpc.request(method, params, respond_callback, notify_reply_callback)
      if closing then return false end
      next_id = next_id + 1
      local id = next_id

      --- @param err? lsp.ResponseError
      --- @param result any
      local function respond(err, result)
        on_main(function()
          if notify_reply_callback then notify_reply_callback(id) end
          respond_callback(err, result, id)
        end)
      end

      if method == 'initialize' then
        init_params = params
        local capabilities = opts.capabilities
        if type(capabilities) == 'function' then
          local ok, result = xpcall(capabilities, debug.traceback, params, srv)
          if ok then
            capabilities = result
          else
            report('capabilities', result)
            capabilities = {}
          end
        end
        srv.capabilities = vim.tbl_deep_extend('keep', capabilities or {}, {
          positionEncoding = 'utf-8',
          textDocumentSync = protocol.TextDocumentSyncKind.None,
        })
        respond(nil, { capabilities = srv.capabilities })
      elseif method == 'shutdown' then
        cancel_all(ErrorCodes.ServerCancelled)
        respond(nil, vim.NIL)
      elseif handlers[method] == nil then
        respond(rpc_error(ErrorCodes.MethodNotFound, ('method not found: %s'):format(method)))
      else
        run(method, id, handlers[method], params, function(err, result, task)
          if err == nil then
            respond(nil, result == nil and vim.NIL or result)
          elseif err == 'closed' then
            respond(rpc_error(cancel_codes[id] or ErrorCodes.RequestCancelled))
            cancel_codes[id] = nil
          else
            report(method, traceback(task, err))
            respond(rpc_error(ErrorCodes.InternalError, tostring(err)))
          end
        end)
      end

      return true, id
    end

    function rpc.notify(method, params)
      if closing then return false end

      if method == 'initialized' then
        callback('on_init', opts.on_init, srv, init_params)
      elseif method == 'exit' then
        exit()
        return true
      elseif method == '$/cancelRequest' then
        local task = pending[params.id]
        if task ~= nil then
          cancel_codes[params.id] = ErrorCodes.RequestCancelled
          task:close()
        end
      elseif method == 'workspace/didChangeConfiguration' then
        -- nvim sends the initial settings again right after `initialized`
        if not vim.deep_equal(params.settings, last_settings) then
          last_settings = params.settings
          reported['settings'] = nil
          local settings = resolve_settings(params.settings)
          if settings ~= nil then
            srv.settings = settings
            callback('on_settings', opts.on_settings, srv, settings)
          end
        end
      elseif method == 'textDocument/didOpen' then
        local bufnr = util.bufnr(params.textDocument)
        if bufnr ~= nil then callback('on_attach', opts.on_attach, srv, bufnr) end
      elseif method == 'textDocument/didClose' then
        local bufnr = util.bufnr(params.textDocument)
        if bufnr ~= nil then callback('on_detach', opts.on_detach, srv, bufnr) end
      end

      local handler = notifications[method]
      if handler ~= nil then
        run(method, nil, handler, params, function(err, _, task)
          if err ~= nil and err ~= 'closed' then report(method, traceback(task, err)) end
        end)
      end

      return true
    end

    function rpc.is_closing() return closing end

    function rpc.terminate() exit() end

    return rpc
  end
end

return M
