local M = {}

--- A new folder with `files` ({ ["path/in/it"] = "content" }) in it; returns its path.
function M.tree(files)
  local root = vim.fs.normalize(vim.fn.tempname())
  for path, content in pairs(files or {}) do
    local full = root .. "/" .. path
    vim.fn.mkdir(vim.fs.dirname(full), "p")
    vim.fn.writefile(vim.split(content, "\n"), full)
  end
  vim.fn.mkdir(root, "p")
  return root
end

--- Opens `path` (setting its filetype); returns the buffer.
function M.open(path)
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  return vim.api.nvim_get_current_buf()
end

return M
