#!/usr/bin/env bash
# Local helper: run a command inside the WSL toolchain that hosts
# verilator / iverilog.  Not used by CI.
set -euo pipefail
# WSL mounts the Windows drives under /mnt, and the repository may well sit on a
# different drive than the one this was written against, so ask WSL where it is
# instead of hard-coding a path that goes stale the moment the checkout moves.
cd "$(wslpath "$(cd "$(dirname "$0")" && pwd)")"
exec wsl -u root -e bash -lc "cd '$PWD' && $*"
