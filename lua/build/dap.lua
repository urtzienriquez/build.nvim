--- Debugging what is built. nvim-dap is needed only by configuration() and debug().
---
--- configuration() is an nvim-dap configuration that builds the project's debug target each
--- time it starts, and then debugs it with gdb. plugin/build.lua puts it in nvim-dap's list
--- (dap.continue()), in the buffers :Build works in.

-- (required at startup by configs that add configuration() to nvim-dap: the rest loads on use)
local function async_module()
  return require("build.async")
end

local M = {}

local NAME = "Build & debug"

-- under the debugger the sanitizers stop the program at the error (so the debugger shows where
-- it is) instead of exiting; the leak check is off, as it does not work under a debugger
M.env = {
  ASAN_OPTIONS = "abort_on_error=1:detect_leaks=0",
  UBSAN_OPTIONS = "print_stacktrace=1:halt_on_error=1:abort_on_error=1",
}

--- Builds the debug target (in a coroutine). Returns the nvim-dap configuration that debugs it,
--- or nil.
function M.prepare()
  local async, job, project = async_module(), require("build.job"), require("build.project")
  vim.cmd("silent! wall")
  local p, err = project.get()
  if not p then
    async.notify(err, vim.log.levels.WARN)
    return nil
  end
  local target = project.debug_target(p)
  local program = target and project.program(p, target)
  if not program then
    return nil
  end
  local ok = async.await(function(cb)
    job.build(p, target, cb)
  end)
  if not ok then
    return nil
  end
  if vim.fn.executable(program) ~= 1 then
    async.notify(program .. " is not an executable (fix it with :Build program)", vim.log.levels.WARN)
    return nil
  end
  return {
    name = NAME,
    type = "gdb",
    request = "launch",
    program = program,
    args = project.split_args(project.args(p, program)),
    cwd = p.root,
    env = M.env,
    stopAtBeginningOfMainSubprogram = false,
  }
end

--- An nvim-dap configuration that builds before each start (nvim-dap calls it in a coroutine).
function M.configuration()
  return setmetatable({ name = NAME, type = "gdb", request = "launch" }, {
    __call = function()
      return M.prepare() or { name = NAME, type = "gdb", program = require("dap").ABORT }
    end,
  })
end

--- :Build debug
function M.debug()
  local ok, dap = pcall(require, "dap")
  if not ok then
    async_module().notify(":Build debug needs nvim-dap", vim.log.levels.ERROR)
    return
  end
  dap.run(M.configuration())
end

--- :Build debug-external: the program in g:build.external_debugger, outside nvim
function M.debug_external()
  async_module().wrap(M._debug_external)()
end

function M._debug_external()
  local debugger = require("build.config").get().external_debugger
  if not debugger then
    async_module().notify(
      "Set the debugger to use in vim.g.build.external_debugger, e.g. { 'raddbg' }",
      vim.log.levels.WARN
    )
    return
  end
  local config = M.prepare()
  if not config then
    return
  end
  local cmd = vim.list_extend(vim.list_extend({}, debugger), { config.program })
  vim.fn.jobstart(vim.list_extend(cmd, config.args), { detach = true, cwd = config.cwd })
end

return M
