local helpers = require("tests.helpers")

local function has_build(buf)
  return vim.api.nvim_buf_get_commands(buf, {}).Build ~= nil
end

describe("attaching", function()
  local attached
  before_each(function()
    attached = {}
    vim.api.nvim_create_autocmd("User", {
      pattern = "BuildAttach",
      callback = function(ev)
        table.insert(attached, ev.data.buf)
      end,
    })
  end)

  it("loads nothing until :Build runs", function()
    helpers.open(helpers.tree({ ["a.c"] = "" }) .. "/a.c")
    assert.is_nil(package.loaded["build"])
    assert.is_nil(package.loaded["build.project"])
  end)

  it("defines :Build and fires BuildAttach in C, C++, Makefiles and build.sh", function()
    local root = helpers.tree({ ["a.c"] = "", ["b.cpp"] = "", Makefile = "", ["build.sh"] = "#!/bin/sh" })
    for _, file in ipairs({ "a.c", "b.cpp", "Makefile", "build.sh" }) do
      local buf = helpers.open(root .. "/" .. file)
      assert.is_true(has_build(buf), file)
      assert.is_true(vim.tbl_contains(attached, buf), file)
    end
  end)

  it("leaves other buffers alone", function()
    local root = helpers.tree({ ["init.lua"] = "", ["install.sh"] = "#!/bin/sh" })
    for _, file in ipairs({ "init.lua", "install.sh" }) do
      local buf = helpers.open(root .. "/" .. file)
      assert.is_false(has_build(buf), file)
      assert.is_false(vim.tbl_contains(attached, buf), file)
    end
  end)

  it("defines no keymaps", function()
    local buf = helpers.open(helpers.tree({ ["a.c"] = "" }) .. "/a.c")
    assert.same({}, vim.api.nvim_buf_get_keymap(buf, "n"))
  end)

  it("follows vim.g.build_filetypes", function()
    vim.g.build_filetypes = { "fortran" }
    local root = helpers.tree({ ["a.f90"] = "", ["b.c"] = "" })
    assert.is_true(has_build(helpers.open(root .. "/a.f90")))
    assert.is_false(has_build(helpers.open(root .. "/b.c")))
    vim.g.build_filetypes = nil
  end)
end)
