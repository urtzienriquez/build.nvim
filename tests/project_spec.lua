local helpers = require("tests.helpers")
local project = require("build.project")

local BUILD_SH = [[
#!/bin/sh
case "${1:-release}" in
release) build bin/app -O2 ;;
debug) build bin/app_debug -O0 -g ;;
asan | sanitize) build bin/app_asan -fsanitize=address ;;
clean) rm -rf bin ;;
*) echo usage ;;
esac]]

local MAKEFILE = [[
CC = gcc
SOURCES := $(wildcard src/*.c)
.PHONY: debug clean

bin/app: $(SOURCES)
	$(CC) -O2 $(SOURCES) -o $@

debug: bin/app_debug
bin/app_debug: $(SOURCES)
	$(CC) -g $(SOURCES) -o $@

main.o: main.c
clean:
	rm -rf bin]]

describe("finding the project", function()
  it("prefers build.sh, then a Makefile, then CMake", function()
    local root = helpers.tree({ ["build.sh"] = "", Makefile = "", ["CMakeLists.txt"] = "", ["src/a.c"] = "" })
    assert.same({ root, "buildsh", "build.sh" }, { project.find_root(root .. "/src/a.c") })
    os.remove(root .. "/build.sh")
    assert.same({ root, "make", "Makefile" }, { project.find_root(root .. "/src/a.c") })
    os.remove(root .. "/Makefile")
    assert.same({ root, "cmake", "CMakeLists.txt" }, { project.find_root(root .. "/src/a.c") })
  end)

  it("takes the nearest build file", function()
    local root = helpers.tree({ Makefile = "", ["lib/Makefile"] = "", ["lib/x.c"] = "" })
    assert.equals(root .. "/lib", (project.find_root(root .. "/lib/x.c")))
  end)

  it("takes the topmost CMakeLists.txt", function()
    local root = helpers.tree({ ["CMakeLists.txt"] = "", ["test/CMakeLists.txt"] = "", ["test/t.c"] = "" })
    assert.equals(root, (project.find_root(root .. "/test/t.c")))
  end)

  it("does not take a build file in the home folder", function()
    local home = helpers.tree({ Makefile = "", ["notes/a.c"] = "" })
    local saved = vim.env.HOME
    vim.env.HOME = home
    local found = project.find_root(home .. "/notes/a.c")
    vim.env.HOME = saved
    assert.is_nil(found)
  end)

  it("builds a C/C++ file by itself when there is no build file", function()
    local root = helpers.tree({ ["a.c"] = "int main(void) { return 0; }", ["notes.lua"] = "" })
    local p = project.get(helpers.open(root .. "/a.c"))
    assert.equals("single", p.kind)
    assert.equals(root, p.root)
    local _, err = project.get(helpers.open(root .. "/notes.lua"))
    assert.truthy(err:find("no build.sh"))
  end)
end)

describe("targets", function()
  it("are the labels of build.sh's case, with its default", function()
    local root = helpers.tree({ ["build.sh"] = BUILD_SH, ["src/a.c"] = "" })
    local p = project.get(helpers.open(root .. "/src/a.c"))
    local list, default = project.targets(p)
    assert.same({ "release", "debug", "asan", "sanitize", "clean" }, list)
    assert.equals("release", default)
    assert.equals("debug", project.known_debug_target(p))
  end)

  it("are a Makefile's targets, the first the default", function()
    local root = helpers.tree({ Makefile = MAKEFILE, ["src/a.c"] = "" })
    local p = project.get(helpers.open(root .. "/src/a.c"))
    local list, default = project.targets(p)
    assert.same({ "bin/app", "debug", "bin/app_debug", "clean" }, list)
    assert.equals("bin/app", default)
  end)

  it("are the profiles without a build system; debugging keeps one with -g", function()
    local root = helpers.tree({ ["a.c"] = "int main(void) { return 0; }" })
    local p = project.get(helpers.open(root .. "/a.c"))
    assert.same(project.PROFILES, (project.targets(p)))
    assert.equals("debug", project.known_debug_target(p))
    project.set(p, "target", "asan")
    assert.equals("asan", project.known_debug_target(p))
    project.set(p, "target", "release")
    assert.equals("debug", project.known_debug_target(p))
    project.set(p, "target", "-O1 -g -DTRACE") -- typed: remembered, and has -g
    assert.equals("-O1 -g -DTRACE", project.known_debug_target(p))
    assert.same({ "-O1 -g -DTRACE" }, p.state.custom)
  end)
end)

describe("programs", function()
  it("are read from build.sh's lines", function()
    local root = helpers.tree({ ["build.sh"] = BUILD_SH })
    local p = project.get(helpers.open(root .. "/build.sh"))
    assert.equals(root .. "/bin/app", project.guess_program(p, "release"))
    assert.equals(root .. "/bin/app_debug", project.guess_program(p, "debug"))
    assert.equals(root .. "/bin/app", project.guess_program(p, ""))
  end)

  it("are a Makefile's target, or its one prerequisite", function()
    local root = helpers.tree({ Makefile = MAKEFILE })
    local p = project.get(helpers.open(root .. "/Makefile"))
    assert.equals(root .. "/bin/app", project.guess_program(p, "bin/app"))
    assert.equals(root .. "/bin/app_debug", project.guess_program(p, "debug"))
    assert.is_nil(project.guess_program(p, "clean"))
  end)

  it("are the file with main(), built with the files without one", function()
    local root = helpers.tree({
      ["ex1.c"] = "int main(void) { return 0; }",
      ["ex2.c"] = "int main(void) { return 1; }",
      ["util.c"] = "int twice(int x) { return 2 * x; }",
      ["util.h"] = "int twice(int x);",
    })
    local p = project.get(helpers.open(root .. "/ex2.c"))
    local single = project.single_sources(p)
    assert.equals(root .. "/ex2", single.program)
    assert.same({ root .. "/ex2.c", root .. "/util.c" }, single.sources)
    -- from a file without main(), with two candidates: ambiguous
    local _, err = project.single_sources(project.get(helpers.open(root .. "/util.h")))
    assert.truthy(err:find("several"))
    os.remove(root .. "/ex1.c")
    assert.equals(root .. "/ex2", project.single_sources(project.get(helpers.open(root .. "/util.h"))).program)
  end)
end)

describe("a header", function()
  -- Nvim calls a .h file C or C++ depending on its version (0.12: C++), so the sources beside it
  -- decide its language, whatever its filetype
  it("is C among C files, C++ among C++ files", function()
    for _, case in ipairs({
      { files = { ["main.c"] = "int main(void) { return 0; }", ["util.h"] = "" }, lang = "c" },
      { files = { ["main.cpp"] = "int main() { return 0; }", ["util.h"] = "" }, lang = "cpp" },
    }) do
      local root = helpers.tree(case.files)
      local buf = helpers.open(root .. "/util.h")
      for _, ft in ipairs({ "c", "cpp" }) do
        vim.bo[buf].filetype = ft
        local p = project.get(buf)
        assert.equals(case.lang, p.lang, ft)
        assert.equals(root .. "/main", project.single_sources(p).program, ft)
      end
    end
  end)
end)

describe("arguments", function()
  it("are split like a shell's", function()
    assert.same({ "a", "b c", "d" }, project.split_args("a 'b c' d"))
    assert.same({ "x y", "z" }, project.split_args('"x y"  z'))
    assert.same({}, project.split_args(""))
  end)
end)
