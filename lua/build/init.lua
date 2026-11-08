--- build.nvim: build, run and debug C/C++ programs, whatever builds them (build.sh, a
--- Makefile, CMake, or nothing). The :Build command; see :help build.

local async = require("build.async")
local job = require("build.job")
local project = require("build.project")

local M = {}

local function name(t)
  return t == "" and "(default)" or t
end

-- start of every subcommand: save the files, find the project
local function begin()
  vim.cmd("silent! wall")
  local p, err = project.get()
  if not p then
    async.notify(err, vim.log.levels.WARN)
  end
  return p
end

----------------------------------------
-- the subcommands

M.build = async.wrap(function()
  local p = begin()
  if p then
    job.build(p, project.target(p), function() end)
  end
end)

M.run = async.wrap(function()
  local p = begin()
  local program = p and project.program(p, project.target(p))
  if not program then
    return
  end
  -- runs what was built last: building is :Build's job
  if not project.exists(program) then
    async.notify(vim.fs.basename(program) .. " is not built yet (:Build)", vim.log.levels.WARN)
    return
  elseif vim.fn.executable(program) ~= 1 then
    async.notify(program .. " is not an executable (set the right one with :Build program)", vim.log.levels.WARN)
    return
  end
  job.run(vim.trim(vim.fn.shellescape(program) .. " " .. project.args(p, program)), p.root)
end)

--- :Build target [name] / :Build debug-target [name]: set it, or choose it
local function target_command(which, label)
  return async.wrap(function(args)
    local p = begin()
    if not p then
      return
    end
    local t
    if args ~= "" then
      t = args
      project.set(p, which, t)
    else
      local current = which == "target" and project.target(p) or project.known_debug_target(p)
      t = project.pick(p, which, current)
    end
    if t then
      async.notify(label .. ": " .. name(t))
    end
  end)
end
M.target = target_command("target", "Build target")
M.debug_target = target_command("debug_target", "Debug target")

--- :Build args [args]: set them, or edit them
M.args = async.wrap(function(args)
  local p = begin()
  local program = p and project.program(p, project.target(p))
  if not program then
    return
  end
  if args == "" then
    args = async.input({
      prompt = ("Arguments of %s: "):format(vim.fs.basename(program)),
      default = project.args(p, program),
    })
  end
  if args then
    project.set_args(p, program, args)
  end
end)

M.program = async.wrap(function()
  local p = begin()
  if not p then
    return
  end
  if p.kind == "single" then
    async.notify("Here the program is the file with main() (" .. (project.program(p) or "none") .. ")")
    return
  end
  local target = project.target(p)
  project.ask_program(p, target)
  local dt = project.known_debug_target(p)
  if dt and dt ~= target then
    project.ask_program(p, dt)
  end
end)

M.info = async.wrap(function()
  local p = begin()
  if not p then
    return
  end
  local target = project.target(p)
  local dt = project.known_debug_target(p)
  local program = p.kind == "single" and project.program(p) or project.guess_program(p, target)
  local lines = {
    "Project:  "
      .. p.root
      .. "  ["
      .. ({ single = "single file", buildsh = "build.sh", make = "Makefile", cmake = "CMake" })[p.kind]
      .. "]",
    "Build:    " .. name(target),
    "Debug:    " .. (dt and name(dt) or "(asked on the first debug)"),
    "Program:  " .. (program or "(asked on the first run)"),
    "Args:     " .. project.args(p, program),
  }
  if p.kind == "single" then
    local spec = job.command(p, target)
    if spec then
      table.insert(lines, "Command:  " .. spec.title)
    end
  end
  async.notify(table.concat(lines, "\n"))
end)

function M.cancel()
  job.cancel()
end

function M.forget()
  local p = begin()
  if p then
    project.forget(p.root)
    async.notify("Forgot the settings of " .. p.root)
  end
end

function M.debug()
  require("build.dap").debug()
end

function M.debug_external()
  require("build.dap").debug_external()
end

----------------------------------------
-- :Build

local SUBCOMMANDS = {
  run = M.run,
  debug = M.debug,
  ["debug-external"] = M.debug_external,
  target = M.target,
  ["debug-target"] = M.debug_target,
  args = M.args,
  program = M.program,
  info = M.info,
  cancel = M.cancel,
  forget = M.forget,
}

function M.command(o)
  local sub, rest = o.args:match("^%s*(%S*)%s*(.-)%s*$")
  if sub == "" then
    return M.build()
  end
  local fn = SUBCOMMANDS[sub]
  if not fn then
    async.notify("Unknown :Build subcommand: " .. sub, vim.log.levels.ERROR)
    return
  end
  fn(rest)
end

function M.complete(arglead, cmdline)
  local words = vim.split(cmdline:sub(1, #cmdline - #arglead), "%s+", { trimempty = true })
  local list
  if #words == 1 then
    list = vim.tbl_keys(SUBCOMMANDS)
    table.sort(list)
  elseif #words == 2 and (words[2] == "target" or words[2] == "debug-target") then
    local p = project.get()
    list = p and vim.list_extend(project.targets(p), p.state.custom) or {}
  else
    return {}
  end
  return vim.tbl_filter(function(item)
    return item ~= "" and vim.startswith(item, arglead)
  end, list)
end

return M
