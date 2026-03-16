<p align="center">
  <h2 align="center">Blink Lib (blink.lib)</h2>
</p>

> [!WARNING]
> Not ready for use

**blink.lib** provides generic utilities for all other blink plugins, aka all the code I don't want to copy between my plugins :)

## Roadmap

- [ ] `blink.lib`: Utils (lazy_require, dedup, debounce, truncate, dedent, copy, slice, estimate buffer size, ...) with all other modules exported (lazily)
  - [x] `blink.lib.nvim`: Re-exported nvim APIs (`nvim.create_buf(...)`)
  - [x] `blink.lib.task`: Async
  - [x] `blink.lib.fs`: Filesystem APIs using `blink.lib.task`
  - [x] `blink.lib.timer`: Timers with automatically schedule callbacks with support for cancellation, without racing
  - [x] `blink.lib.log`: Logging to file and/or console
  - [x] `blink.lib.config`: Config module with validation (merge `vim.g/vim.b/setup()`, `enable()`, `is_enabled()`)
  - [x] `blink.lib.build`: Basic build system (e.g. building rust binaries)
    - [x] `blink.lib.build.download`: Binary downloader (e.g. downloading rust binaries)
  - [ ] `blink.lib.lsp`: In-process LSP client wrapper
  - [ ] `blink.lib.git`: Git APIs using [`gix`](https://github.com/Byron/gitoxide)
  - [ ] `blink.lib.http`: HTTP APIs using [`reqwest`](https://github.com/seanmonstar/reqwest)
  - [ ] `blink.lib.regex`: Regex using [`regex`](https://docs.rs/regex/latest/regex/)
  - [ ] `blink.lib.persist`: KV store with namespaces
