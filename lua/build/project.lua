--- The project of a file, and what is known or remembered about it.
---
--- Walking up from the file, the first folder with a build file is the project's root:
---   build.sh        its targets are the labels of its `case` (./build.sh debug, ...)
---   Makefile        its targets (also GNUmakefile, makefile)
---   CMakeLists.txt  Debug / Release / RelWithDebInfo (the root is the topmost CMakeLists.txt)
--- A folder with several build files uses the first in that order. With none (and a C/C++
--- file), the file is built by itself, with a profile: debug, asan, release, ...
--- What is chosen (build target, debug target, programs, arguments) is remembered per root.

local async = require("build.async")

local M = {}

-- the profiles of a file without a build system (a custom one is your own flags)
M.PROFILES = { "debug", "asan", "release", "release+symbols" }
M.PROFILE_FLAGS = {
  debug = { "-O0", "-g3" },
  asan = { "-O0", "-g3", "-fsanitize=address,undefined", "-fno-omit-frame-pointer" },
  release = { "-O2", "-DNDEBUG" },
  ["release+symbols"] = { "-O2", "-g3", "-fno-omit-frame-pointer" }, -- for perf, or debugging optimised code
}
local CMAKE_TYPES = { "Debug", "Release", "RelWithDebInfo" }

----------------------------------------
-- what is remembered, per project (its root folder)

local store
local function store_file()
  return vim.fn.stdpath("data") .. "/build-projects.json"
end

local function state(root)
  if not store then
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(store_file()), "\n"))
    end)
    store = ok and type(data) == "table" and data or {}
  end
  store[root] = store[root] or {}
  local s = store[root]
  s.programs = s.programs or {} -- per target
  s.args = s.args or {} -- per program in a folder of files, else one for the project ("*")
  s.custom = s.custom or {} -- targets typed by hand, the last first
  return s
end

function M.save()
  vim.fn.mkdir(vim.fs.dirname(store_file()), "p")
  vim.fn.writefile({ vim.json.encode(store) }, store_file())
end

function M.forget(root)
  state(root)
  store[root] = nil
  M.save()
end

----------------------------------------
-- finding it

function M.read(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  return ok and lines or {}
end

function M.exists(path)
  return vim.uv.fs_stat(path) ~= nil
end

--- root, kind ("buildsh" | "make" | "cmake") and build file of the project of `path`, or nil
function M.find_root(path)
  local home = vim.uv.os_homedir()
  local root = vim.fs.root(path, { "build.sh", "GNUmakefile", "makefile", "Makefile", "CMakeLists.txt" })
  if not root or root == home or root == "/" then -- a stray Makefile in ~ is no project
    return nil
  end
  if M.exists(root .. "/build.sh") then
    return root, "buildsh", "build.sh"
  end
  for _, file in ipairs({ "GNUmakefile", "makefile", "Makefile" }) do
    if M.exists(root .. "/" .. file) then
      return root, "make", file
    end
  end
  -- a CMake project's root is its topmost CMakeLists.txt
  while M.exists(vim.fs.dirname(root) .. "/CMakeLists.txt") do
    root = vim.fs.dirname(root)
  end
  return root, "cmake", "CMakeLists.txt"
end

local SOURCE_EXTS = { c = { c = true }, cpp = { cpp = true, cc = true, cxx = true } }

-- the language of a file built by itself: its filetype; but a header (.h) is C for some versions
-- of Nvim and C++ for others (see g:c_syntax_for_h), so for it the sources beside it decide
local function language(path, ft)
  if path:match("%.h$") then
    local c, cpp = false, false
    for name, type in vim.fs.dir(vim.fs.dirname(path)) do
      local ext = type == "file" and name:match("%.([^.]+)$")
      if ext and SOURCE_EXTS.c[ext] then
        c = true
      elseif ext and SOURCE_EXTS.cpp[ext] then
        cpp = true
      end
    end
    if c ~= cpp then
      return c and "c" or "cpp"
    end
  end
  return ft == "c" and "c" or "cpp"
end

---@class build.Project
---@field root string
---@field kind "buildsh"|"make"|"cmake"|"single"
---@field file? string the build file
---@field path string the file it was found from
---@field lang "c"|"cpp"
---@field state table what is remembered

---@return build.Project?, string?
function M.get(buf)
  buf = buf or 0
  local name = vim.api.nvim_buf_get_name(buf)
  local path = (vim.bo[buf].buftype == "" and name ~= "") and vim.fs.normalize(name) or vim.fn.getcwd()
  local root, kind, file = M.find_root(path)
  local ft = vim.bo[buf].filetype
  if not root then
    if ft ~= "c" and ft ~= "cpp" then
      return nil, "no build.sh, Makefile or CMakeLists.txt above " .. path
    end
    root, kind = vim.fs.dirname(path), "single"
  end
  local lang = kind == "single" and language(path, ft) or (ft == "c" and "c" or "cpp")
  return { root = root, kind = kind, file = file, path = path, lang = lang, state = state(root) }
end

----------------------------------------
-- targets

--- the targets to choose from, and the one used when none was chosen
function M.targets(p)
  if p.kind == "single" then
    return vim.deepcopy(M.PROFILES), "debug"
  elseif p.kind == "cmake" then
    return vim.deepcopy(CMAKE_TYPES), "Debug"
  end
  local list, seen, default = {}, {}, nil
  local function add(t)
    if not seen[t] then
      seen[t] = true
      table.insert(list, t)
    end
  end
  for _, line in ipairs(M.read(p.root .. "/" .. p.file)) do
    if p.kind == "buildsh" then
      default = default or line:match("%${1:%-([%w_%-]+)}")
      local labels = line:match("^%s*([%w_%-][%w_%-|%s]*)%)") -- `debug)`, `asan | sanitize)`
      for t in (labels or ""):gmatch("[%w_%-]+") do
        add(t)
      end
    else
      local t, after = line:match("^([%w_][%w_%-%./]*)%s*:(.?)")
      if t and after ~= "=" and not t:find("%.o$") then -- not `VAR := value`, nor object files
        add(t)
      end
    end
  end
  if p.kind == "make" then
    default = list[1] -- what a bare `make` builds
  end
  if #list == 0 then
    return { "" }, "" -- a build.sh without targets: just run it
  end
  return list, default or list[1]
end

function M.target(p)
  return p.state.target or select(2, M.targets(p))
end

function M.is_debug_flags(t)
  return t == "debug" or t == "asan" or (not M.PROFILE_FLAGS[t] and t:find("%-g") ~= nil)
end

local CUSTOM = "\0custom"
local CUSTOM_PROMPT = {
  single = "Compiler flags (e.g. -O1 -g -DTRACE): ",
  buildsh = "build.sh arguments: ",
  make = "make arguments (e.g. -B CXXFLAGS='-O0 -g'): ",
  cmake = "CMake build type: ",
}

--- Sets which ("target" | "debug_target") to `choice`, remembering a typed one.
function M.set(p, which, choice)
  if not vim.tbl_contains(M.targets(p), choice) then
    p.state.custom = vim.tbl_filter(function(t)
      return t ~= choice
    end, p.state.custom)
    table.insert(p.state.custom, 1, choice)
    p.state.custom[9] = nil
  end
  p.state[which] = choice
  M.save()
end

--- Asks which target `which` is (in a coroutine); "other…" types one: at a prompt, or with
--- `opts.cmdline` on the command line (`:Build target `), and then this returns nil.
function M.pick(p, which, current, opts)
  local list = M.targets(p)
  for _, t in ipairs(p.state.custom) do
    if not vim.tbl_contains(list, t) then
      table.insert(list, t)
    end
  end
  table.insert(list, CUSTOM)
  local choice = async.select(list, {
    prompt = (which == "target" and "Build target" or "Debug target (built with debug info)") .. " — " .. p.root,
    format_item = function(t)
      if t == CUSTOM then
        return "other…"
      end
      return (t == "" and "(default)" or t) .. (t == current and "  ●" or "")
    end,
  })
  if choice == CUSTOM and opts and opts.cmdline then
    async.notify((vim.trim(CUSTOM_PROMPT[p.kind]):gsub(":$", "")))
    async.cmdline(("Build %s "):format(which == "target" and "target" or "debug-target"))
    return nil
  elseif choice == CUSTOM then
    choice = async.input({ prompt = CUSTOM_PROMPT[p.kind] })
    choice = choice and vim.trim(choice)
  end
  if choice then
    M.set(p, which, choice)
  end
  return choice
end

--- the debug target, if it can be told without asking
function M.known_debug_target(p)
  if p.state.debug_target then
    return p.state.debug_target
  elseif p.kind == "single" then
    local t = M.target(p)
    return M.is_debug_flags(t) and t or "debug"
  elseif p.kind == "cmake" then
    return "Debug"
  elseif vim.tbl_contains(M.targets(p), "debug") then
    return "debug"
  end
end

--- the debug target, asked once if it cannot be told (in a coroutine)
function M.debug_target(p)
  local t = M.known_debug_target(p)
  if t then
    return t
  end
  async.notify("Which target builds this project with debug info (-g)? (asked once)")
  return M.pick(p, "debug_target")
end

----------------------------------------
-- programs

-- a folder of files: the file with main() (this one, or the folder's only one), with every
-- file of the folder that has no main()

local function has_main(file)
  for _, line in ipairs(M.read(file)) do
    if line:match("^%s*int%s+main%s*%(") or line:match("^%s*auto%s+main%s*%(") then
      return true
    end
  end
  return false
end

--- { sources, program } of a project without a build system, or nil and why
function M.single_sources(p)
  local files = {}
  for name, type in vim.fs.dir(p.root) do
    local ext = name:match("%.([^.]+)$")
    if type == "file" and ext and SOURCE_EXTS[p.lang][ext] then
      table.insert(files, p.root .. "/" .. name)
    end
  end
  table.sort(files)
  local mains, others = {}, {}
  for _, file in ipairs(files) do
    table.insert(has_main(file) and mains or others, file)
  end
  local main
  if vim.tbl_contains(mains, p.path) then
    main = p.path
  elseif #mains == 1 then
    main = mains[1]
  elseif #mains == 0 then
    return nil, "no main() in " .. p.root
  else
    return nil, "several files here have main(): open the one to build"
  end
  return { sources = vim.list_extend({ main }, others), program = (main:gsub("%.[^.]+$", "")) }
end

local function absolute(p, path)
  return path:sub(1, 1) == "/" and path or vim.fs.normalize(p.root .. "/" .. path)
end

--- the program `target` makes, if it was set or can be told from the build files
function M.guess_program(p, target)
  if p.state.programs[target] then
    return absolute(p, p.state.programs[target])
  end
  local name = target
  if name == "" then
    name = select(2, M.targets(p))
  end
  if p.kind == "buildsh" then
    for _, line in ipairs(M.read(p.root .. "/build.sh")) do
      local out = line:match("^%s*" .. vim.pesc(name) .. "%)%s*build%s+(%S+)")
      if out then
        return absolute(p, out)
      end
    end
  elseif p.kind == "make" then
    if name:find("/") then -- the target is the program: `bin/stats: ...`
      return absolute(p, name)
    end
    -- a name for one program: `debug: bin/stats_debug`
    for _, line in ipairs(M.read(p.root .. "/" .. p.file)) do
      local out = line:match("^" .. vim.pesc(name) .. "%s*:%s*(%S+/%S+)%s*$")
      if out then
        return absolute(p, out)
      end
    end
  end
end

--- asks for the program `target` makes, and remembers it (in a coroutine)
function M.ask_program(p, target)
  local path = async.input({
    prompt = ("Program that '%s' builds: "):format(target == "" and "(default)" or target),
    default = M.guess_program(p, target) or (p.root .. "/"),
    completion = "file",
  })
  if not path or vim.trim(path) == "" then
    return nil
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(vim.trim(path), ":p"))
  local rel = path:sub(1, #p.root + 1) == p.root .. "/" and path:sub(#p.root + 2) or path
  p.state.programs[target] = rel
  M.save()
  return path
end

--- the program `target` makes, asked once if it cannot be told (in a coroutine)
function M.program(p, target)
  if p.kind == "single" then
    local single, err = M.single_sources(p)
    if not single then
      async.notify(err, vim.log.levels.WARN)
    end
    return single and single.program
  end
  return M.guess_program(p, target) or M.ask_program(p, target)
end

----------------------------------------
-- arguments

local function args_key(p, program)
  return p.kind == "single" and program or "*"
end

function M.args(p, program)
  return p.state.args[args_key(p, program)] or ""
end

function M.set_args(p, program, args)
  p.state.args[args_key(p, program)] = vim.trim(args)
  M.save()
end

--- "a 'b c' d" -> { "a", "b c", "d" }
function M.split_args(s)
  local out, cur, quote = {}, nil, nil
  for ch in (s or ""):gmatch(".") do
    if quote then
      if ch == quote then
        quote = nil
      else
        cur = cur .. ch
      end
    elseif ch == "'" or ch == '"' then
      quote, cur = ch, cur or ""
    elseif ch:match("%s") then
      if cur then
        table.insert(out, cur)
        cur = nil
      end
    else
      cur = (cur or "") .. ch
    end
  end
  if cur then
    table.insert(out, cur)
  end
  return out
end

return M
