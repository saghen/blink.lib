local task = require('blink.lib.task')

--- @class blink.lib.download.git
local git = {}

--- @param root_dir string
--- @return blink.lib.Task<{ tag?: string }>
function git.get_version(root_dir)
  return task.new(function(resolve, reject)
    vim.system({ 'git', 'describe', '--tags', '--exact-match' }, { cwd = root_dir }, function(out)
      if out.code == 128 then return resolve({}) end
      if out.code ~= 0 then
        return reject('While getting git tag, git exited with code ' .. out.code .. ': ' .. out.stderr)
      end

      local lines = out.stdout and vim.split(out.stdout, '\n') or {}
      if not lines[1] then return reject('Expected at least 1 line of output from git describe') end
      return resolve({ tag = lines[1] })
    end)
  end) --[[@as blink.lib.Task<{ tag?: string }>]]
end

return git
