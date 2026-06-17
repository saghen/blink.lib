-- we want to wait for UIEnter to send `notify` messages, otherwise the user might not see them
local ui_entered = vim.v.vim_did_enter == 1 -- technically VimEnter, but good enough
if not ui_entered then
  vim.api.nvim_create_autocmd('UIEnter', {
    callback = function() ui_entered = true end,
    once = true,
  })
end

local levels_to_str = {
  [vim.log.levels.TRACE] = 'TRACE',
  [vim.log.levels.DEBUG] = 'DEBUG',
  [vim.log.levels.INFO] = 'INFO',
  [vim.log.levels.WARN] = 'WARN',
  [vim.log.levels.ERROR] = 'ERROR',
}

--- @class blink.lib.LoggerOptions
--- @field module string
--- @field console? blink.lib.LoggerConsoleOptions
--- @field file? blink.lib.LoggerFileOptions

--- @class blink.lib.LoggerConsoleOptions
--- @field enabled? boolean
--- @field min_log_level? number
---
--- @class blink.lib.LoggerFileOptions : blink.lib.LoggerConsoleOptions
--- @field path? string

--- @class blink.lib.Logger
--- @field path string
--- @field opts blink.lib.LoggerOptions
--- @field fd integer File descriptor
--- @field failed boolean Failed to open or write to file, no future attempts will be made
--- @field logs_queue string[] Queued logs
--- @field notification_queue function[] Notifications to be queued for UIEnter
local logger = {}

--- Open the log file in the current buffer
function logger:open() vim.cmd('edit ' .. self.opts.file.path) end

--- Log message with the given level, where extra arguments will be formatted against `msg`
--- using `string.format`. Non-primitive types will be converted to strings via `vim.inspect`.
---
--- ```lua
--- logger:log(vim.log.levels.INFO, 'message %s', { foo = true })
--- ```
---
--- @param level number
--- @param msg string
--- @param ... any
function logger:log(level, msg, ...)
  if level < self.opts.console.min_log_level and level < self.opts.file.min_log_level then return end

  -- if there are args, use `vim.inspect` to format non-primitives
  -- and `string.format` with the `msg`
  if select('#', ...) > 0 then
    local args = {}
    for i = 1, select('#', ...) do
      local o = select(i, ...)
      local type = type(o)
      if type == 'table' or type == 'function' or type == 'userdata' then
        table.insert(args, vim.inspect(o, { newline = '\n', indent = '  ' }))
      else
        table.insert(args, o)
      end
    end
    msg = msg:format(args)
  end

  msg = levels_to_str[level] .. ': ' .. msg .. '\n'

  if level >= self.opts.console.min_log_level then print(msg) end
  if level >= self.opts.file.min_log_level then self:write_to_file(msg .. '\n') end
end

--- Log message with TRACE level, where extra arguments will be formatted against `msg`
--- using `string.format`. Non-primitive types will be converted to strings via `vim.inspect`.
---
--- ```lua
--- logger:trace('message %s', { foo = true })
--- ```
---
--- @param msg string
--- @param ... any
function logger:trace(msg, ...) self:log(vim.log.levels.TRACE, msg, ...) end

--- Log message with DEBUG level, where extra arguments will be formatted against `msg`
--- using `string.format`. Non-primitive types will be converted to strings via `vim.inspect`.
---
--- ```lua
--- logger:debug('message %s', { foo = true })
--- ```
---
--- @param msg string
--- @param ... any
function logger:debug(msg, ...) self:log(vim.log.levels.DEBUG, msg, ...) end

--- Log message with INFO level, where extra arguments will be formatted against `msg`
--- using `string.format`. Non-primitive types will be converted to strings via `vim.inspect`.
---
--- ```lua
--- logger:info('message %s', { foo = true })
--- ```
---
--- @param msg string
--- @param ... any
function logger:info(msg, ...) self:log(vim.log.levels.INFO, msg, ...) end

--- Log message with WARN level, where extra arguments will be formatted against `msg`
--- using `string.format`. Non-primitive types will be converted to strings via `vim.inspect`.
---
--- ```lua
--- logger:warn('message %s', { foo = true })
--- ```
---
--- @param msg string
--- @param ... any
function logger:warn(msg, ...) self:log(vim.log.levels.WARN, msg, ...) end

--- Log message with ERROR level, where extra arguments will be formatted against `msg`
--- using `string.format`. Non-primitive types will be converted to strings via `vim.inspect`.
---
--- ```lua
--- logger:error('message %s', { foo = true })
--- ```
---
--- @param msg string
--- @param ... any
function logger:error(msg, ...) self:log(vim.log.levels.ERROR, msg, ...) end

--- Prints a message given by a list of `[text, hl_group]` "chunks".
--- The message will not be written to the log file.
--- Unlike the built-in `nvim_echo`, this API will wait for the UIEnter event to
--- ensure the user sees the message. The module name will be prepended to the
--- message.
---
--- Example:
--- ```lua
--- log:notify(vim.log.levels.INFO, { { 'chunk1-line1\nchunk1-line2\n' }, { 'chunk2-line1' } }, true, {})
--- ```
---
--- @param level number Level from `vim.log.levels.*`
--- @param chunks string | [string, integer|string?][] List of `[text, hl_group]` pairs, where each is a `text` string highlighted by
--- the (optional) name or ID `hl_group`.
--- @param history boolean? if false, do not add to `message-history`.
--- @param opts vim.api.keyset.echo_opts? Optional parameters.
--- - id: message id for updating existing message.
--- - err: Treat the message like `:echoerr`. Sets `hl_group` to `hl-ErrorMsg` by default.
--- - kind: Set the `ui-messages` kind with which this message will be emitted.
--- - verbose: Message is controlled by the 'verbose' option. Nvim invoked with `-V3log`
---   will write the message to the "log" file instead of standard output.
--- - title: The title for `progress-message`.
--- - status: Current status of the `progress-message`. Can be
---   one of the following values
---   - success: The progress item completed successfully
---   - running: The progress is ongoing
---   - failed: The progress item failed
---   - cancel: The progressing process should be canceled. NOTE: Cancel must be handled by
---     progress initiator by listening for the `Progress` event
--- - percent: How much progress is done on the progress message
--- - data: dictionary containing additional information
function logger:notify(level, chunks, history, opts)
  if self.opts.console.min_log_level > level then return end

  -- preprend module name to message
  local header_hl = 'DiagnosticVirtualTextWarn'
  if level == vim.log.levels.ERROR then
    header_hl = 'DiagnosticVirtualTextError'
  elseif level == vim.log.levels.INFO then
    header_hl = 'DiagnosticVirtualTextInfo'
  end
  if type(chunks) == 'string' then chunks = { { chunks } } end
  table.insert(chunks, 1, { ' ' .. self.opts.module .. ' ', header_hl })
  table.insert(chunks, 2, { ' ' })

  -- defaults
  history = history == nil or history
  opts = opts or {}
  opts.verbose = opts.verbose == true or false

  if level == vim.log.levels.ERROR and opts.err == nil then opts.err = true end
  if ui_entered then
    vim.schedule(function() vim.api.nvim_echo(chunks, history, opts) end)
  else
    -- Queue notification for the UIEnter event
    table.insert(self.notification_queue, function() vim.api.nvim_echo(chunks, history, opts) end)
  end
end

function logger:write_to_file(msg)
  if self.fd == nil or self.failed then
    -- havent yet opened file
    if not self.failed then table.insert(self.logs_queue, msg) end
    return
  end

  table.insert(self.logs_queue, msg)
  if self.writing then return end
  self:flush_write_queue()
end

function logger:flush_write_queue()
  if self.failed or self.fd == nil or #self.logs_queue == 0 then
    self.writing = false
    return
  end

  self.writing = true
  local batch = table.concat(self.logs_queue)
  self.logs_queue = {}

  vim.uv.fs_write(self.fd, batch, nil, function(write_err)
    if write_err ~= nil and not self.failed then
      self.failed = true
      vim.schedule(
        function()
          vim.notify(
            'Failed to write to log file at '
              .. self.opts.file.path
              .. ' for module '
              .. self.opts.module
              .. ': '
              .. write_err,
            vim.log.levels.ERROR
          )
        end
      )
      return
    end
    -- drain any messages that arrived while we were writing
    self:flush_write_queue()
  end)
end

--------------------

--- @class blink.lib.log
local M = {}

--- @param opts blink.lib.LoggerOptions
--- @return blink.lib.Logger
function M.new(opts)
  local log_dir = vim.fn.stdpath('log') --[[@as string]]

  opts.console = opts.console or {}
  opts.console.enabled = opts.console.enabled == nil or opts.console.enabled
  opts.console.min_log_level = opts.console.min_log_level or vim.log.levels.INFO

  opts.file = opts.file or {}
  opts.file.enabled = opts.file.enabled == nil or opts.file.enabled
  opts.file.min_log_level = opts.file.min_log_level or vim.log.levels.INFO
  opts.file.path = opts.file.path or log_dir .. '/' .. opts.module .. '.log'

  local self = setmetatable({
    opts = opts,
    notification_queue = {},
    logs_queue = {},
    fd = nil,
    -- we dont want to spam errors, so if we fail to open or write to the file, ignore future attempts
    failed = false,
  }, { __index = logger })

  -- the log dir may not exist (e.g. first install)
  if vim.fn.isdirectory(log_dir) == 0 then
    if vim.fn.mkdir(log_dir, 'p') == 0 then
      vim.notify('Failed to create log directory: ' .. log_dir, vim.log.levels.ERROR)
      return self
    end
  end

  -- open log file and write queued lines
  vim.uv.fs_open(opts.file.path or '', 'a', 438, function(open_err, _fd)
    if open_err or _fd == nil then
      self.failed = true
      vim.schedule(
        function()
          vim.notify(
            'Failed to open log file at '
              .. opts.file.path
              .. ' for module '
              .. opts.module
              .. ': '
              .. (open_err or 'unknown error'),
            vim.log.levels.ERROR
          )
        end
      )
      return
    end
    self.fd = _fd

    self:write_to_file(table.concat(self.logs_queue, '\n'))
    self.logs_queue = {}
  end)

  if not ui_entered then
    vim.api.nvim_create_autocmd('UIEnter', {
      callback = function()
        for _, fn in ipairs(self.notification_queue) do
          pcall(fn)
        end
      end,
      once = true,
    })
  end

  return self
end

return M
