# build.nvim

Build, run and debug C/C++ programs from Neovim, whatever builds them: a `build.sh`, a
`Makefile`, CMake, or nothing at all (a file, or a folder of files). Builds run in the
background, and their errors go to the quickfix list. Debugging (with
[nvim-dap](https://github.com/mfussenegger/nvim-dap) and gdb) builds first, then starts the
right program with the right arguments.

It costs nothing at startup: `plugin/build.lua` only defines an autocmd, and the rest loads the
first time you use `:Build`. It defines no keymaps.

## How it finds the project

Walking up from the current file, the first folder with a build file is the project's root
(never your home folder):

| Build file | Targets | Debug target | Program |
|---|---|---|---|
| `build.sh` | the labels of its `case` (`release)`, `debug)`…) | `debug` | from its line: `debug) build bin/app_debug …` |
| `Makefile` | its targets; the first is the default | `debug` | the target (`bin/app:`), or its one prerequisite (`debug: bin/app_debug`) |
| `CMakeLists.txt` (the topmost) | Debug, Release, RelWithDebInfo, in `build/<type>/` | Debug | asked once |
| none (C/C++ only) | profiles: `debug`, `asan`, `release`, `release+symbols` | the profile, if it has `-g` | the file with `main()` |

A folder with several build files uses the first in that order. Without a build system, the
program is the file with `main()` (the current one, or the folder's only one), built with
every file of the folder that has no `main()`. What it cannot tell, it asks once. What you
choose (target, debug target, program, arguments) is remembered per project, in
`stdpath("data")/build-projects.json`.

## Commands

`:Build` exists only in the buffers it works in: C, C++, Makefiles, CMake, and files named
`build.sh` (see `vim.g.build_filetypes`).

| Command | |
|---|---|
| `:Build` | build the chosen target |
| `:Build target [name]` | choose the target to build (or set it); "other…" takes any arguments |
| `:Build run` | run the program as it was last built (it does not build), in a terminal |
| `:Build debug` | build the debug target, then debug it with nvim-dap |
| `:Build debug-external` | the same, in `vim.g.build.external_debugger` |
| `:Build debug-target [name]` | choose the debug target (or set it) |
| `:Build args [args]` | the program's arguments (set, or edited on a pre-filled command line, where `<C-f>` opens the command-line window) |
| `:Build args!` | clear the program's arguments |
| `:Build program` | set the program the targets make, where it cannot be told |
| `:Build info` | show what is known and chosen for this project |
| `:Build cancel` | stop the build running |
| `:Build forget` | forget what was chosen for this project |

## Keymaps

Define them in the `User BuildAttach` event, which fires in each buffer `:Build` attaches to:

```lua
vim.api.nvim_create_autocmd("User", {
  pattern = "BuildAttach",
  callback = function(ev)
    local function map(lhs, cmd, desc)
      vim.keymap.set("n", lhs, "<Cmd>Build " .. cmd .. "<CR>", { buffer = ev.data.buf, desc = desc })
    end
    map("<leader>cc", "", "Build")
    map("<leader>ct", "target", "Choose build target")
    map("<leader>cr", "run", "Run program")
    map("<leader>cd", "debug", "Debug")
  end,
})
```

## Options

```lua
vim.g.build = {
  cc = "gcc",                       -- the compilers of files without a build system
  cxx = "g++",
  cstd = "c17",
  cxxstd = "c++20",
  warnings = { "-Wall", "-Wextra" },
  run_split = "botright 15split",   -- where :Build run opens its terminal
  external_debugger = nil,          -- e.g. { "raddbg" }: the program and its arguments are added
  dap = true,                       -- "Build & debug" in nvim-dap's list
}
vim.g.build_filetypes = { "c", "cpp", "make", "cmake", "sh" } -- sh: only files named build.sh
```

Every field is optional. No `setup()` is needed.

## Debugging with nvim-dap

`:Build debug` needs a `gdb` adapter in nvim-dap (gdb ≥ 14 speaks DAP):

```lua
require("dap").adapters.gdb = { type = "executable", command = "gdb", args = { "--interpreter=dap" } }
```

With nvim-dap installed, its list (`require("dap").continue()`) has "Build & debug" first, in
the buffers `:Build` works in (a configuration provider: your `dap.configurations` are left
alone). `vim.g.build = { dap = false }` leaves it out; `require("build.dap").configuration()` is
the configuration itself, to put where you want.

It builds the debug target each time it starts, and debugs its program with its arguments
(`:Build args`), from the project's root. Under the debugger, the sanitizers stop the
program at the error instead of exiting (`require("build.dap").env`).

## Tests

`scripts/test.sh` (it clones [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) into
`tests/deps/` on the first run; needs gcc and make).
