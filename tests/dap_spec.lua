local helpers = require("tests.helpers")

-- a stand-in for nvim-dap: only its table of configuration providers
local dap = { providers = { configs = {} } }
package.preload["dap"] = function()
  return dap
end

describe("nvim-dap's list", function()
  after_each(function()
    vim.g.build = nil
  end)

  it("has Build & debug in the buffers :Build works in", function()
    local root = helpers.tree({ ["a.c"] = "", ["notes.txt"] = "" })
    local buf = helpers.open(root .. "/a.c")
    local provider = assert(dap.providers.configs.build, "registered")
    local configs = provider(buf)
    assert.equals(1, #configs)
    assert.equals("Build & debug", configs[1].name)
    assert.same({}, provider(helpers.open(root .. "/notes.txt")))
  end)

  it("leaves it out with vim.g.build = { dap = false }", function()
    local buf = helpers.open(helpers.tree({ ["a.c"] = "" }) .. "/a.c")
    vim.g.build = { dap = false }
    assert.same({}, dap.providers.configs.build(buf))
  end)
end)
