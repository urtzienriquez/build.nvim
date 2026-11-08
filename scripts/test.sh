#!/usr/bin/env bash
# Runs the plenary.nvim test suite. Clones plenary into tests/deps/ on first run (gitignored,
# dev-only), unless $PLENARY_PATH points at one. Requires: nvim, git, gcc, make.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plenary_dir="${PLENARY_PATH:-$root/tests/deps/plenary.nvim}"

if [ ! -d "$plenary_dir" ]; then
  echo "Cloning plenary.nvim into $plenary_dir ..."
  mkdir -p "$(dirname "$plenary_dir")"
  git clone --depth 1 https://github.com/nvim-lua/plenary.nvim "$plenary_dir"
fi
export PLENARY_PATH="$plenary_dir"

# what the tests remember goes to a folder of their own
XDG_DATA_HOME="$(mktemp -d)"
export XDG_DATA_HOME
trap 'rm -rf "$XDG_DATA_HOME"' EXIT

target="${1:-$root/tests}"

nvim --headless --noplugin \
  -u "$root/tests/minimal_init.lua" \
  -c "PlenaryBustedDirectory $target { minimal_init = '$root/tests/minimal_init.lua', sequential = true }"
