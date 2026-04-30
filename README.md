<p align="center">
  <h2 align="center">Blink Lib (blink.lib)</h2>
</p>

**blink.lib** provides generic utilities for all other blink plugins and looks to fill the gaps in the neovim standard library, particularly around async, config, native libraries, git, regex and so on.

## Installation

```lua
-- lazy.nvim
{ 'saghen/blink.lib' }

-- vim.pack
vim.pack.add({ 'https://github.com/saghen/blink.lib' })
```

## Modules

All APIs are unstable until v1!

- [`blink.lib`](#blinklib): Utilities and lazy export of top level modules
- [`blink.lib.config`](#blinklibconfig): Schema based config validation with dynamic per-mode/buffer lookup (merge `vim.g/vim.b/config({}, { mode = 'cmdline' })/setup()`)
- [`blink.lib.native`](#blinklibnative): Build and download APIs for native libraries
- [`blink.lib.task`](#blinklibtask): Async task API with support for cancellation
- [`blink.lib.fs`](#blinklibfs): Filesystem APIs using `blink.lib.task`
- [`blink.lib.log`](#blinkliblog): Notifications and logging to file and/or console
- [`blink.lib.nvim`](#blinklibnvim): Re-exported nvim APIs (`nvim.create_buf(...)`)
- [`blink.lib.timer`](#blinklibtimer): Timers with automatically schedule callbacks with support for cancellation, without racing
- [`blink.lib.bench`](#blinklibbench): Benchmarking API (see `benches/**/*.lua`)

### Roadmap

Modules that are planned but not yet implemented:

- [ ] `blink.lib.lsp`: In-process LSP client wrapper
- [ ] `blink.lib.git`: Git APIs using [`gix`](https://github.com/Byron/gitoxide)
- [ ] `blink.lib.regex`: Regex using [`regex`](https://docs.rs/regex/latest/regex/)
- [ ] `blink.lib.persist`: KV store with namespaces

### `blink.lib`

Utilities and lazy export of top level modules

```lua
-- all modules re-exported
lib.config
lib.fs
lib.log
lib.nvim
lib.task
lib.timer

-- lazy require
local require = lib.require -- rename to `require` to trick the LSP into thinking it's the real `require`
-- or
local require = require('blink.lib.lazy_require')
local some_module = require('some_module') -- lazily required on first use

-- table/list utils
lib.list.dedup({ 1, 2, 3, 2 }) -- { 1, 2, 3 }
lib.list.reverse({ 1, 2, 3 }) -- { 3, 2, 1 }
lib.list.equal({ 1, 2, 3 }, { 1, 2, 3 }) -- true
lib.list.filter_map({ 1, 2, 3 }, function(v) return v > 1 and v + 10 end) -- { 12, 13 }
-- ...

lib.tbl.equal({ a = 1, b = 2 }, { a = 1, b = 2 }) -- true
lib.tbl.pick({ a = 1, b = 2, c = 3 }, { 'a', 'c' }) -- { a = 1, c = 3 }
lib.tbl.omit({ a = 1, b = 2, c = 3 }, { 'a', 'c' }) -- { b = 2 }
-- ...
```

### `blink.lib.config`

Schema based config validation with dynamic per-mode/buffer lookup. Merges `vim.g[module]`, `vim.b[module]`, per-mode/bufnr configs and top level config.

```lua
local types = require('blink.lib.config').types
local config = require('blink.lib.config').new('my_plugin', {
  enabled = { true, 'boolean' },
  some_setting = { 'foo', types.enum({ 'foo', 'bar' }) },
  other_setting = { { 1, 2, 'bar' }, types.list({ 'number', types.enum({ 'foo', 'bar' }) })}
  nested = {
    setting = { nil, { 'function', 'nil' } },
  }
})

-- per buffer config, `vim.g` also works
vim.b.my_plugin = { some_setting = 'bar' }
config({ nested = { setting = function() end } }, { bufnr = 0 })

-- per mode config
config({ enabled = false }, { mode = 'cmdline' })

-- global config
config({ other_setting = { 3, 'foo' }})

-- access values in the config
print(config.enabled) -- true (would be `false` if `mode` was `c`)
print(config.some_setting) -- 'bar' (from vim.b.my_plugin)
print(config.other_setting) -- { 3, 'foo' } (from config(...))
print(config.nested.setting) -- function (from config(..., { bufnr = 0 }))
```

### `blink.lib.native`

Most blink plugins use native libraries which are fetched from github releases when on a git tag (versioned release) or built on the user's device. This module provides utilities for resolving/downloading/building/loading libraries, fetching platform information and reading git commit/tags.

For a production example, see [`blink.cmp's implementation`](https://github.com/saghen/blink.cmp/blob/main/lua/blink/cmp/init.lua).

```lua
local native = require('blink.lib.native')
local logger = require('blink.lib.log').new({ module = 'my_module' })

local current_file = debug.getinfo(1, 'S').source:sub(2)
local lib_name = 'some_library'
local your_repo = 'foobar/some_repo'

function load()
  return native.load(lib_name, native.try_git_commit(current_file))
end

function library_available()
  return native.resolve(lib_name, native.try_git_commit(current_file)) ~= nil
end

function build(opts)
  local platform = native.platform()
  local repo_root = native.git_repo_root(current_file)
  if repo_root == nil then error('Missing git repo root, did you install via a package manager?') end

  local system = native.exec_async(repo_root, { 'cargo', 'build', '--release' }, logger, callback):wait(60000)
  native.mv(repo_root .. '/target/release/lib' .. lib_name .. platform.lib_extension, native.library_path(lib_name))

  if not lib.native.load('blink_cmp_fuzzy', lib.native.git_commit(current_file)) then
    error('Failed to load built blink.cmp native library')
  end
end

--- Downloads the precompiled library if it's not already available
--- @param opts? { force?: boolean }
--- @return blink.lib.Task
function cmp.download(opts)
  local git_tag = native.git_tag(current_file)
  if git_tag == nil then error('Missing git tag, have you pinned the version?') end

  local platform = native.platform()
  if platform.triple == nil then error('Unknown platform: ' .. platform.triple) end

  local url = 'https://github.com/ ' .. your_repo .. '/releases/download/'
    .. git_tag
    .. '/'
    .. platform.triple
    .. platform.lib_extension
  local library_path = native.library_path('blink_cmp_fuzzy', native.git_commit(current_file))
  native.download_async(url, library_path):wait(30000)

  if not native.load(lib_name, native.git_commit(current_file)) then
    error('Failed to load downloaded blink.cmp precompiled library')
  end
end
```

### `blink.lib.task`

Allows chaining of cancellable async operations without callback hell. You may want to use [lewis's async.nvim](https://github.com/lewis6991/async.nvim) instead which will likely be adopted into the core.

```lua
local lib = require('blink.lib')

lib.task.wrap(function(callback) vim.uv.fs_readdir(vim.uv.cwd(), callback) end)
  :map(function(entries) return lib.tbl.map(function(entry) return entry.name end, entries) end)
  :catch(function(err) vim.print('failed to read directory: ' .. err) end)

local tag = lib.task.new(function(resolve, reject)
  vim.system({ 'git', 'describe', '--tags', '--exact-match' }, { cwd = root_dir }, function(out)
    if out.code == 128 then return resolve({}) end
    if out.code ~= 0 then
      return reject('While getting git tag, git exited with code ' .. out.code .. ': ' .. out.stderr)
    end

    local lines = vim.split(out.stdout, '\n')
    if not lines[1] then return reject('Expected atleast 1 line of output from git describe') end
    return resolve({ tag = lines[1] })
  end)
end):wait(1000)
```

Note that lua language server cannot infer the type of the task from the `resolve` call. You may need to add the type annotation explicitly via an `@return` annotation on a function returning the task, or via the `@cast/@type` annotations on the task variable.

### `blink.lib.fs`

Filesystem APIs using `blink.lib.task`

```lua
fs.list_dir(path, max_entries)
fs.read(path, size, offset)
fs.write(path, data, offset)
fs.rm(path)
fs.exists(path)
fs.stat(path)
fs.mkdir(path, mode)
fs.mkdirp(path, mode)
fs.rename(old_path, new_path)

-- path utilities
fs.basename(path)
fs.dirname(path)
fs.abspath(path)
fs.ext(path)
fs.join_path(path1, path2)
fs.normalize(path)
fs.parents(path)
fs.relpath(path1, path2)
fs.root(path)
fs.ensure_trailing_slash(path)
fs.remove_leading_slash(path)
```

### `blink.lib.log`

Notifications and logging to file and/or console. Waits for UIEnter event to ensure the user sees messages.

```lua
local logger = require('blink.lib.log').new({
  module = 'my_module',
  -- defaults
  console = { enabled = true, min_log_level = vim.log.levels.INFO },
  file = { enabled = true, min_log_level = vim.log.levels.INFO, path = vim.fn.stdpath('log') .. '/my_module.log' },
})

logger:notify(vim.log.levels.INFO, { { 'message' } }) -- same api as `vim.api.nvim_echo`
logger:info('message %s', { foo = true }) -- "message { foo = true }"
logger:write_to_file('message\n')
```

### `blink.lib.nvim`

Re-exported nvim APIs (`%s/vim.api.nvim_/nvim./g`)

```lua
nvim.create_buf(name, options)
nvim.open_win(bufnr, enter, config)
nvim.get_current_buf()
nvim.get_current_line()
-- ...
```

### `blink.lib.timer`

Timers with automatically schedule callbacks with support for cancellation, without racing. Same API as `vim.uv.new_timer()`.

```lua
local old_timer = vim.uv.new_timer()
old_timer:start(0, 0, vim.schedule_wrap(function() print('hello') end))
old_timer:stop()
-- timer stopped but callback already scheduled, races

local new_timer = require('blink.lib.timer').new()
new_timer:start(0, 0, function() print('hello') end)
new_timer:stop()
-- timer stopped and scheduled callback cancelled
```

### `blink.lib.bench`

Statistics-driven micro-benchmarking API inspired by [criterion](https://criterion-rs.github.io/book/criterion_rs.html). Bench files live in `benches/**/*.lua` and are run in a clean headless Neovim instance with manual GC and JIT.

- `:BlinkBench [filter]`: run all `benches/**/*.lua` files (optionally filtered by substring) in a terminal split to the right
- `require('blink.lib.bench').setup()`: register the `:BlinkBench` command
- `require('blink.lib.bench').run_file()`: run benches for the current file only
- `require('blink.lib.bench').run_files(filter)`: run all `benches/**/*.lua` files programmatically

```lua
local b = require('blink.lib.bench')

b.run('my bench', function()
  -- code to measure
end)
b.run('customized bench', function()
  -- code to measure
end, { warmup = '100ms', measurement = '1s', output = 'verbose', save = false })

-- receive a report and comapre two runs
local fast_report = b.run('fast bench', function() end)
local slow_report = b.run('slow bench', function() end)
fast_report:compare(slow_report)

-- groups (can set options for all nested benches)
local group = b.group('table insertion')
-- local group = b.group('table insertion', { warmup = '500ms', measurement = '5s', output = 'verbose', save = false })
group.run('tbl[#tbl + 1] = val', function()
  local tbl = {}
  for i = 1, 100 do tbl[#tbl + 1] = i end
end)
group.run('table.insert', function()
  local tbl = {}
  for i = 1, 100 do table.insert(tbl, i) end
end)
```

Results are saved to `{stdpath('state')}/blink/bench/{module}/{group}.{name}.json` and compared against the previous run automatically. Set `save = false` to disable this behavior.
