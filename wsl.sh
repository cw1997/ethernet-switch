#!/usr/bin/env bash
# Local helper: run a command inside the WSL toolchain that hosts
# verilator / iverilog.  Not used by CI.
set -euo pipefail
cd "$(dirname "$0")"
exec wsl -u root -e bash -lc "cd /mnt/d/fpga/switch && $*"
