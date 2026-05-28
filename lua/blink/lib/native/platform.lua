local platform = {
  triples = {
    mac = {
      arm64 = 'aarch64-apple-darwin',
      x64 = 'x86_64-apple-darwin',
    },
    windows = {
      arm64 = 'aarch64-pc-windows-msvc',
      x64 = 'x86_64-pc-windows-msvc',
    },
    linux = {
      arm64 = function(libc) return 'aarch64-unknown-linux-' .. libc end,
      x64 = function(libc) return 'x86_64-unknown-linux-' .. libc end,
      loongarch64 = function(libc) return 'loongarch64-unknown-linux-' .. libc end,
    },
    android = {
      arm64 = 'aarch64-linux-android',
      x64 = 'x86_64-linux-android',
    },
    freebsd = {
      x64 = 'x86_64-unknown-freebsd',
      arm64 = 'aarch64-unknown-freebsd',
    },
    openbsd = {
      x64 = 'x86_64-unknown-openbsd',
      arm64 = 'aarch64-unknown-openbsd',
    },
  },
}

--- @alias blink.lib.native.OS 'windows'|'linux'|'mac'|'freebsd'|'openbsd'|'netbsd'|'bsd'|'other'
--- @alias blink.lib.native.Arch 'x86'|'x64'|'arm'|'arm64'|'arm64be'|'ppc'|'ppc64'|'ppc64le'|'mips'|'mipsel'|'mips64'|'mips64el'|'loongarch64'|string
--- @alias blink.lib.native.Libc 'gnu'|'musl'
--- @alias blink.lib.native.Triple 'aarch64-apple-darwin'|'x86_64-apple-darwin'|'aarch64-pc-windows-msvc'|'x86_64-pc-windows-msvc'|'aarch64-unknown-linux-gnu'|'aarch64-unknown-linux-musl'|'aarch64-unknown-freebsd'|'x86_64-unknown-linux-gnu'|'x86_64-unknown-linux-musl'|'x86_64-unknown-freebsd'|'x86_64-unknown-openbsd'|'aarch64-unknown-openbsd'|'loongarch64-unknown-linux-gnu'|'loongarch64-unknown-linux-musl'
--- @alias blink.lib.native.LibExtension '.so'|'.dylib'|'.dll'

--- @class blink.lib.native.Platform
--- @field os blink.lib.native.OS
--- @field arch blink.lib.native.Arch
--- @field libc? blink.lib.native.Libc present when `os` is `'linux'`
--- @field triple? string present for known platforms, otherwise `nil`
--- @field lib_extension blink.lib.native.LibExtension

--- Gets the operating system and architecture of the current system
--- @return 'windows'|'linux'|'mac'|'freebsd'|'openbsd'|'netbsd'|'bsd'|'other'
function platform.os()
  local os = jit.os:lower()
  if os == 'osx' then os = 'mac' end
  if os == 'bsd' then
    local sysname = vim.loop.os_uname().sysname:lower()
    if sysname == 'freebsd' or sysname == 'openbsd' or sysname == 'netbsd' then os = sysname end
  end
  return os
end

--- @return 'x86'|'x64'|'arm'|'arm64'|'arm64be'|'ppc'|'ppc64'|'ppc64le'|'mips'|'mipsel'|'mips64'|'mips64el'|string
function platform.arch() return jit.arch end

--- @param os blink.lib.native.OS
--- @return blink.lib.native.Libc?
function platform.libc(os)
  if os ~= 'linux' then return end

  local fd = vim.uv.fs_open('/proc/self/exe', 'r', 438) -- 438 = 0666
  if not fd then return 'gnu' end

  -- Read the first 4KB which always contains the PT_INTERP string
  local head = vim.uv.fs_read(fd, 4096, 0)
  vim.uv.fs_close(fd)

  return head:match('musl') and 'musl' or 'gnu'
end

--- Gets the system triple for the current system
--- for example, `x86_64-unknown-linux-gnu` or `aarch64-apple-darwin`
--- @param os blink.lib.native.OS
--- @param arch blink.lib.native.Arch
--- @param libc? blink.lib.native.Libc
--- @return blink.lib.native.Triple?
function platform.triple(os, arch, libc)
  local triples = platform.triples[os]
  if triples == nil then return end

  local triple = triples[arch]
  if type(triple) ~= 'function' then return triple end
  return triple(libc)
end

return platform
