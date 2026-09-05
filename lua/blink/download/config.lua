return {
  ---@type string?
  force_system_triple = nil,
  proxy = {
    ---@type string?
    url = nil,
    from_env = true,
  },
  ---@type string[]
  extra_curl_args = {},
}
