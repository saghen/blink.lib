<p align="center">
  <h2 align="center">Blink Lib (blink.lib)</h2>
</p>

> [!WARNING]
> Not ready for use

**blink.lib** provides generic utilities for all other blink plugins, aka all the code I don't want to copy between my plugins :)

## Roadmap

- [x] `blink.lib.task`: Async
- [x] `blink.lib.fs`: Filesystem APIs
- [ ] `blink.lib.config`: Config module with validation (merge `vim.g/vim.b/setup()`, `enable()`, `is_enabled()`)
- [ ] `blink.lib`: Utils (lazy_require, dedup, debounce, truncate, dedent, copy, slice, ...) with all other modules exported (lazily)
- [ ] `blink.lib.log`: Logging to file and/or notifications
- [ ] `blink.lib.download`: Binary downloader (e.g. downloading rust binaries)
- [ ] `blink.lib.build`: Build system (e.g. building rust binaries)
- [ ] `blink.lib.regex`: Regex
- [ ] `blink.lib.git`: Git APIs using FFI
- [ ] `blink.lib.http`: HTTP APIs using [`reqwest`](https://github.com/seanmonstar/reqwest)
- [ ] `blink.lib.lsp`: In-process LSP client wrapper
