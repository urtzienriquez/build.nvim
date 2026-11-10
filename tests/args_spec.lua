local helpers = require("tests.helpers")
local async = require("build.async")
local build = require("build")
local project = require("build.project")

describe(":Build args", function()
  local root, p, program, fed
  local cmdline = async.cmdline

  before_each(function()
    root = helpers.tree({ ["hello.c"] = "int main(void) { return 0; }" })
    p = project.get(helpers.open(root .. "/hello.c"))
    program = project.program(p, project.target(p))
    fed = nil
    async.cmdline = function(text)
      fed = text
    end
  end)

  after_each(function()
    async.cmdline = cmdline
  end)

  it("sets them", function()
    build.command({ args = "args a 'b c'", bang = false })
    assert.equals("a 'b c'", project.args(p, program))
  end)

  it("puts them on the command line to be edited, when not given", function()
    project.set_args(p, program, "x < in.txt")
    build.command({ args = "args", bang = false })
    assert.equals("Build args x < in.txt", fed)
    assert.equals("x < in.txt", project.args(p, program))
  end)

  it("clears them with a bang", function()
    project.set_args(p, program, "x y")
    build.command({ args = "args", bang = true })
    assert.equals("", project.args(p, program))
    assert.is_nil(fed)
  end)
end)
