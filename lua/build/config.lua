--- The options: vim.g.build (a table, every field optional), read each time they are used.

local M = {}

M.defaults = {
  cc = "gcc", -- the compilers of files without a build system
  cxx = "g++",
  cstd = "c17",
  cxxstd = "c++20",
  warnings = { "-Wall", "-Wextra" },
  run_split = "botright 15split", -- the window :Build run opens its terminal in
  external_debugger = nil, -- for :Build debug-external, e.g. { "raddbg" } (the program and its
  -- arguments are added)
  dap = true, -- "Build & debug" in nvim-dap's list (read by plugin/build.lua)
}

function M.get()
  return vim.tbl_extend("force", M.defaults, vim.g.build or {})
end

return M
