#!/usr/bin/env bash
# Local helper: run a command inside the WSL toolchain that hosts
# verilator / iverilog / yosys.  Not used by CI.
set -euo pipefail
# WSL mounts the Windows drives under /mnt, and the repository may well sit on a
# different drive than the one this was written against, so ask WSL where it is
# instead of hard-coding a path that goes stale the moment the checkout moves.
here="$(cd "$(dirname "$0")" && pwd)"
# `wslpath` only exists *inside* a WSL distribution, so when this script is
# started from a Windows shell - Git Bash or MSYS, which is how it is normally
# invoked - the conversion has to be done by asking WSL itself.  Both spellings
# accept a path with forward slashes; only the CR on WSL's reply has to go.
if command -v wslpath >/dev/null 2>&1; then
  dir="$(wslpath -a "$here")"
else
  dir="$(wsl.exe wslpath -a "$(cygpath -m "$here")" | tr -d '\r')"
fi
exec wsl -u root -e bash -lc "cd '$dir' && $*"
