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

function M.input(opts)
  return M.await(function(cb)
    vim.ui.input(opts, cb)
  end)
end

function M.select(items, opts)
  return M.await(function(cb)
    vim.ui.select(items, opts, cb)
  end)
end

return M
