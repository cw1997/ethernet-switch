#!/usr/bin/env bash
# ============================================================================
#  File        : sim/run_questa.sh
#  Description : Compile and run one testbench with Questa/ModelSim
#                (`vlib` / `vlog` / `vsim` in batch mode).
#
#  Usage       : sim/run_questa.sh <top-module>
#  Example     : sim/run_questa.sh sw_switch_tb
#
#  Requirements: `vlib`, `vlog` and `vsim` on the PATH, e.g.
#                 export PATH=/tools/questa_fse/win64:$PATH
# ============================================================================
set -euo pipefail

TOP="${1:?usage: run_questa.sh <top-module>}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="build/questa/${TOP}"
LOG_DIR="build/logs"
mkdir -p "$WORK" "$LOG_DIR"

rm -rf "${WORK}/work"
echo "[questa] creating library ${WORK}/work"
vlib "${WORK}/work"

echo "[questa] compiling the design"
vlog -sv -work "${WORK}/work" +incdir+rtl,tb -f sim/sw_rtl.f -f sim/sw_tb.f \
     2>&1 | tee "$LOG_DIR/${TOP}.build.log"

echo "[questa] running ${TOP}"
set +e
vsim -c -quiet \
     -wlf "${WORK}/${TOP}.wlf" \
     -do "run -all; quit -f [expr [\$value - {0}] exit]" \
     "${WORK}/work.${TOP}" 2>&1 | tee "$LOG_DIR/${TOP}.run.log"
rc="${PIPESTATUS[0]}"
set -e

if [[ $rc -eq 0 ]]; then
  echo "[questa] ${TOP}: PASS"
else
  echo "[questa] ${TOP}: FAIL (exit ${rc})"
fi
exit $rc
