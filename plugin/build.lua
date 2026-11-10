-- Only one autocmd is defined here; everything else loads on use. In the buffers build.nvim
-- works in (vim.g.build_filetypes; sh only for files named build.sh) it defines the
-- buffer-local :Build command and fires `User BuildAttach` (data: { buf = ... }), where your
-- keymaps go. It defines no keymaps itself.

if vim.g.loaded_build then
  return
end
vim.g.loaded_build = 1

local DEFAULT_FILETYPES = { "c", "cpp", "make", "cmake", "sh" }

local opts = {
  nargs = "*",
  bang = true,
  complete = function(arglead, cmdline)
    return require("build").complete(arglead, cmdline)
  end,
  desc = "Build, run and debug: run, debug, debug-external, target, debug-target, args, program, info, cancel, forget",
}
local function command(o)
  require("build").command(o)
end

local function attach(buf)
  local ft = vim.bo[buf].filetype
  if not vim.tbl_contains(vim.g.build_filetypes or DEFAULT_FILETYPES, ft) then
    return
  end
  if ft == "sh" and vim.fs.basename(vim.api.nvim_buf_get_name(buf)) ~= "build.sh" then
    return
  end
  vim.api.nvim_buf_create_user_command(buf, "Build", command, opts)
  if not vim.b[buf].build_attached then
    vim.b[buf].build_attached = true
    vim.api.nvim_exec_autocmds("User", { pattern = "BuildAttach", data = { buf = buf }, modeline = false })
  end
end

vim.api.nvim_create_autocmd("FileType", {
  group = vim.api.nvim_create_augroup("build", {}),
  callback = function(ev)
    attach(ev.buf)
  end,
})

-- buffers that already have a filetype (when the plugin loads late)
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(buf) and vim.bo[buf].filetype ~= "" then
    attach(buf)
  end
end
