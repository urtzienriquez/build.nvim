--- Coroutines, so that prompts and builds read as straight-line code.

local M = {}

function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "build" })
end

local function resume(co, ...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    M.notify(debug.traceback(co, tostring(err)), vim.log.levels.ERROR)
  end
end

--- fn, made to run in a coroutine of its own
function M.wrap(fn)
  return function(...)
    resume(coroutine.create(fn), ...)
  end
end

--- Waits for `start(callback)` to call back (at once or later), and returns what it got.
function M.await(start)
  local co = assert(coroutine.running(), "await outside a coroutine")
  local result, waiting
  start(function(...)
    result = { n = select("#", ...), ... }
    if waiting then
      resume(co)
    end
  end)
  if not result then
    waiting = true
    coroutine.yield()
  end
  return unpack(result, 1, result.n)
end

--- Puts `:text` on the command line, to be edited (<C-f> opens the real command-line window)
--- and run. `text` goes in as it is: no key notation.
function M.cmdline(text)
  vim.api.nvim_feedkeys(vim.keycode("<C-\\><C-n>") .. ":" .. text, "n", false)
end

--- A window to edit `text` in, much like the command-line window (which input() cannot open):
--- <CR> (Normal or Insert mode) gives `cb` the line under the cursor; closing it gives nil.
local function edit_window(opts, text, cb)
  local lines = {}
  for i = 1, vim.fn.histnr("@") do
    local h = vim.fn.histget("@", i)
    if h ~= "" then
      table.insert(lines, h)
    end
  end
  table.insert(lines, text)

  vim.cmd(("botright %dnew"):format(math.max(vim.o.cmdwinheight, 1)))
  local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.wo[win].winbar = (opts.prompt or ""):gsub("%%", "%%%%")
  vim.wo[win].winfixheight = true
  vim.api.nvim_win_set_cursor(win, { #lines, 0 })

  local done = false
  local function finish(result)
    if done then
      return
    end
    done = true
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    cb(result)
  end
  vim.keymap.set({ "n", "i" }, "<CR>", function()
    local line = vim.api.nvim_get_current_line()
    vim.fn.histadd("@", line)
    vim.cmd("stopinsert")
    finish(line)
  end, { buffer = buf, desc = "build: use this line" })
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    vim.cmd("stopinsert")
    finish(nil)
  end, { buffer = buf, desc = "build: cancel" })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        finish(nil)
      end)
    end,
  })
end

--- vim.ui.input, where <C-f> (at input()'s prompt, which cannot open the command-line window)
--- opens an edit_window
function M.input(opts)
  local escaped -- what was typed, when <C-f> left the prompt for an edit_window
  local saved = vim.fn.maparg("<C-f>", "c", false, true)
  vim.keymap.set("c", "<C-f>", function()
    if vim.fn.getcmdtype() == "@" then
      escaped = vim.fn.getcmdline()
      return "<C-c>"
    end
    return "<C-f>"
  end, { expr = true, desc = "build: edit the prompt in a window" })
  local function restore()
    pcall(vim.keymap.del, "c", "<C-f>")
    if not vim.tbl_isempty(saved) then
      vim.fn.mapset("c", false, saved)
    end
  end

  return M.await(function(cb)
    local ok, err = pcall(vim.ui.input, opts, function(result)
      restore()
      if escaped then
        vim.schedule(function()
          edit_window(opts, escaped, cb)
        end)
      else
        cb(result)
      end
    end)
    if not ok then
      restore()
      error(err)
    end
  end)
end

function M.select(items, opts)
  return M.await(function(cb)
    vim.ui.select(items, opts, cb)
  end)
end

return M
