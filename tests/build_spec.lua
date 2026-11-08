local helpers = require("tests.helpers")
local job = require("build.job")
local project = require("build.project")

local function build(p, target)
  local result
  job.build(p, target, function(ok, spec)
    result = { ok = ok, spec = spec }
  end)
  vim.wait(20000, function()
    return result ~= nil
  end, 20)
  return result
end

describe("building", function()
  it("compiles a file by itself, with the profile's flags", function()
    local root = helpers.tree({ ["hello.c"] = "int main(void) { return 0; }" })
    local p = project.get(helpers.open(root .. "/hello.c"))
    local spec = job.command(p, "asan")
    assert.truthy(vim.tbl_contains(spec.cmd, "-fsanitize=address,undefined"))
    assert.truthy(vim.tbl_contains(spec.cmd, "-lm"))
    local result = build(p, "debug")
    assert.is_true(result.ok)
    assert.equals(1, vim.fn.executable(root .. "/hello"))
  end)

  it("puts the errors in the quickfix list", function()
    local root = helpers.tree({ ["bad.c"] = "int main(void) {\n  return undeclared;\n}" })
    local p = project.get(helpers.open(root .. "/bad.c"))
    assert.is_false(build(p, "debug").ok)
    local errors = vim.tbl_filter(function(item)
      return item.valid == 1 and item.type:lower() == "e"
    end, vim.fn.getqflist())
    assert.is_true(#errors > 0)
    assert.equals(root .. "/bad.c", vim.fs.normalize(vim.api.nvim_buf_get_name(errors[1].bufnr)))
    assert.equals(2, errors[1].lnum)
    vim.cmd("cclose")
  end)

  it("runs make in the project's root, its relative paths found", function()
    local root = helpers.tree({
      Makefile = "bin/app: src/main.c\n\tmkdir -p bin\n\tgcc src/main.c -o bin/app",
      ["src/main.c"] = "int main(void) { return y; }",
    })
    local p = project.get(helpers.open(root .. "/src/main.c"))
    vim.cmd("cd /") -- elsewhere: the paths in the errors are relative to the root
    assert.is_false(build(p, project.target(p)).ok)
    local errors = vim.tbl_filter(function(item)
      return item.valid == 1 and item.lnum > 0
    end, vim.fn.getqflist())
    assert.equals(root .. "/src/main.c", vim.fs.normalize(vim.api.nvim_buf_get_name(errors[1].bufnr)))
    vim.cmd("cclose")
    vim.fn.writefile({ "int main(void) { return 0; }" }, root .. "/src/main.c")
    assert.is_true(build(p, project.target(p)).ok)
    assert.equals(1, vim.fn.executable(root .. "/bin/app"))
  end)
end)
