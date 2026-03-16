local task = require('blink.lib.task')

--- @class blink.lib.download.git
local git = {}

--- @param root_dir string
--- @return blink.lib.Task
function git.get_version(root_dir)
  return task.new(function(resolve, reject)
    vim.system({ 'git', 'describe', '--tags', '--exact-match' }, { cwd = root_dir }, function(out)
      if out.code == 128 then return resolve({}) end
      if out.code ~= 0 then
        return reject('While getting git tag, git exited with code ' .. out.code .. ': ' .. out.stderr)
      end

      local lines = vim.split(out.stdout, '\n')
      if not lines[1] then return reject('Expected atleast 1 line of output from git describe') end
      return resolve({ tag = lines[1] })
    end)
  end)
end

return git
