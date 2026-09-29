#!/usr/bin/env bash
# ============================================================================
#  File        : sim/run_verilator.sh
#  Description : Build and run one testbench with Verilator 5.x
#                (`--binary --timing`, i.e. a self-contained simulation).
#
#  Usage       : sim/run_verilator.sh <top-module> [extra verilator flags]
#  Example     : sim/run_verilator.sh sw_switch_tb
#
#  The script is simulator agnostic about the host: run it directly on a Linux
#  host, or through the WSL helper in the repository root on Windows.
# ============================================================================
set -euo pipefail

TOP="${1:?usage: run_verilator.sh <top-module> [flags]}"
shift || true

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

OBJ_DIR="build/verilator/${TOP}"
LOG_DIR="build/logs"
mkdir -p "$OBJ_DIR" "$LOG_DIR"

VERILATOR_FLAGS=(
  --binary --timing
  -Wall
  -Wno-DECLFILENAME
  -Wno-UNUSEDPARAM  # testbench constants that a given configuration does not use
  -Wno-WIDTHCONCAT   # expected: the testbench frame buffer is 16 kbit wide
  -Wno-fatal
  -Irtl -Itb
  -f sim/sw_rtl.f
  -f sim/sw_tb.f
  --top-module "$TOP"
  --Mdir "$OBJ_DIR"
)

echo "[verilator] building ${TOP} ..."
verilator "${VERILATOR_FLAGS[@]}" "$@" 2>&1 | tee "$LOG_DIR/${TOP}.build.log"

echo "[verilator] running ${TOP} ..."
set +e
"./${OBJ_DIR}/V${TOP}" 2>&1 | tee "$LOG_DIR/${TOP}.run.log"
rc="${PIPESTATUS[0]}"
set -e

if [[ $rc -eq 0 ]]; then
  echo "[verilator] ${TOP}: PASS"
else
  echo "[verilator] ${TOP}: FAIL (exit ${rc})"
fi
exit $rc
