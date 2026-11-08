--- Building in the background (the output goes to the quickfix list), and running programs.

local async = require("build.async")
local project = require("build.project")

local M = {}

local JOBS = vim.uv.available_parallelism()

-- gcc's (and clang's) error format, which also follows make's "Entering directory"
local efm
local function errorformat()
  if not efm then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_call(buf, function()
      vim.cmd("compiler gcc")
    end)
    efm = vim.bo[buf].errorformat
    vim.api.nvim_buf_delete(buf, { force = true })
  end
  return efm
end

local function sh(cmd, cwd, dir, label)
  return { cmd = { "sh", "-c", cmd }, cwd = cwd, dir = dir or cwd, title = cmd, label = label }
end

---@class build.Command
---@field cmd string[]
---@field cwd string
---@field dir string the folder relative paths in its errors are from
---@field title string the command, as shown
---@field label string what it builds, as shown
---@field program? string the program (of a project without a build system)

--- how to build `target`
---@return build.Command?, string?
function M.command(p, target)
  if p.kind == "buildsh" then
    local script = vim.fn.executable(p.root .. "/build.sh") == 1 and "./build.sh" or "sh build.sh"
    return sh(vim.trim(script .. " " .. target), p.root, nil, "build.sh " .. target)
  elseif p.kind == "make" then
    return sh(vim.trim(("make -j%d -Otarget %s"):format(JOBS, target)), p.root, nil, "make " .. target)
  elseif p.kind == "cmake" then
    local dir = "build/" .. target
    local configure = ("cmake -S . -B %s -DCMAKE_BUILD_TYPE=%s -DCMAKE_EXPORT_COMPILE_COMMANDS=ON"):format(dir, target)
    local cmd = ("[ -f %s/CMakeCache.txt ] || %s && cmake --build %s -j %d"):format(dir, configure, dir, JOBS)
    return sh(cmd, p.root, p.root .. "/" .. dir, "cmake " .. target)
  end
  local single, err = project.single_sources(p)
  if not single then
    return nil, err
  end
  local config = require("build.config").get()
  local c = p.lang == "c"
  local compiler = c and config.cc or config.cxx
  local flags = project.PROFILE_FLAGS[target] or vim.split(target, "%s+", { trimempty = true })
  local cmd = { compiler, "-std=" .. (c and config.cstd or config.cxxstd) }
  vim.list_extend(cmd, config.warnings)
  vim.list_extend(cmd, flags)
  if compiler:find("clang") and project.is_debug_flags(target) then
    table.insert(cmd, "-fstandalone-debug") -- full debug info of the standard library's types
  end
  vim.list_extend(cmd, { "-o", single.program })
  vim.list_extend(cmd, single.sources)
  if c then
    table.insert(cmd, "-lm")
  end
  local shown = vim.tbl_map(function(a)
    return a:sub(1, #p.root + 1) == p.root .. "/" and a:sub(#p.root + 2) or a
  end, cmd)
  return {
    cmd = cmd,
    cwd = p.root,
    dir = p.root,
    title = table.concat(shown, " "),
    label = vim.fs.basename(single.program) .. " (" .. target .. ")",
    program = single.program,
  }
end

local running -- the build running

--- Builds `target` in the background; calls back with (ok, command).
function M.build(p, target, cb)
  local spec, err = M.command(p, target)
  if not spec then
    async.notify(err, vim.log.levels.WARN)
    return cb(false)
  end
  M.cancel(true)
  local me, chunks, start = {}, {}, vim.uv.hrtime()
  local function collect(_, data)
    if data then
      table.insert(chunks, data)
    end
  end
  async.notify("Building " .. spec.label .. " …")
  local ok, handle = pcall(
    vim.system,
    spec.cmd,
    { cwd = spec.cwd, text = true, stdout = collect, stderr = collect },
    function(res)
      vim.schedule(function()
        if running == me then
          running = nil
        end
        if me.cancelled then
          async.notify("Build of " .. spec.label .. " cancelled", vim.log.levels.WARN)
          return cb(false)
        end
        local output = table.concat(chunks)
        local lines = vim.split(output, "\n", { trimempty = true })
        table.insert(lines, 1, ("build: Entering directory '%s'"):format(spec.dir))
        vim.fn.setqflist({}, " ", { title = spec.title, lines = lines, efm = errorformat() })
        local warnings = 0
        for _, item in ipairs(vim.fn.getqflist()) do
          if item.valid == 1 and item.type:lower() == "w" then
            warnings = warnings + 1
          end
        end
        local secs = (vim.uv.hrtime() - start) / 1e9
        if res.code == 0 then
          local note = (output == "" and not spec.program) and ", up to date" or "" -- compilers say nothing
          if warnings > 0 then
            note = note .. (", %d warning%s (:copen)"):format(warnings, warnings > 1 and "s" or "")
          end
          async.notify(("Built %s in %.1fs%s"):format(spec.label, secs, note))
          cb(true, spec)
        else
          vim.cmd("copen | wincmd p")
          async.notify(
            ("Build of %s failed (exit %d): see the quickfix list"):format(spec.label, res.code),
            vim.log.levels.ERROR
          )
          cb(false)
        end
      end)
    end
  )
  if not ok then
    async.notify("could not start the build: " .. tostring(handle), vim.log.levels.ERROR)
    return cb(false)
  end
  me.handle = handle
  running = me
end

--- Stops the build running (quietly: before starting another).
function M.cancel(quiet)
  if running then
    running.cancelled = true
    running.handle:kill("sigterm")
  elseif not quiet then
    async.notify("No build running")
  end
end

local run_buf

--- Runs `cmd` (a shell command) in a terminal, reusing the window of the last run.
function M.run(cmd, cwd)
  local win = run_buf and vim.api.nvim_buf_is_valid(run_buf) and vim.fn.bufwinid(run_buf) or -1
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd(require("build.config").get().run_split)
  end
  local old = run_buf
  run_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, run_buf)
  vim.fn.jobstart(cmd, { term = true, cwd = cwd })
  if old and old ~= run_buf and vim.api.nvim_buf_is_valid(old) then
    vim.api.nvim_buf_delete(old, { force = true })
  end
  vim.cmd.startinsert()
end

return M
