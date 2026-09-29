#!/usr/bin/env bash
# ============================================================================
#  File        : sim/run_all.sh
#  Description : Full regression: lint plus every testbench, with Verilator by
#                default.  Set SIM=questa to run the same suite with
#                Questa/ModelSim instead.
#
#  Usage       : sim/run_all.sh            (Verilator)
#                SIM=questa sim/run_all.sh (Questa)
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SIM="${SIM:-verilator}"
TESTS=(
  sw_crc32_tb
  sw_sync_fifo_tb
  sw_mac_table_tb
  sw_switch_param_tb
  sw_switch_tb
)

pass=0
fail=0
failed_list=()

run_one() {
  local top="$1"
  if [[ "$SIM" == "questa" ]]; then
    sim/run_questa.sh "$top"
  else
    sim/run_verilator.sh "$top"
  fi
}

echo "######################################################################"
echo "# Regression with ${SIM}"
echo "######################################################################"

if [[ "$SIM" != "questa" ]]; then
  if sim/run_lint.sh; then
    echo "[lint] clean"
  else
    echo "[lint] FAILED"
    fail=$((fail + 1))
    failed_list+=("lint")
  fi
  echo
fi

for t in "${TESTS[@]}"; do
  echo
  echo "--------------------------------------------------------------"
  echo ">>> ${t}"
  echo "--------------------------------------------------------------"
  if run_one "$t"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    failed_list+=("$t")
  fi
done

echo
echo "######################################################################"
echo "# ${pass} passed, ${fail} failed"
if [[ ${#failed_list[@]} -gt 0 ]]; then
  echo "# failed: ${failed_list[*]}"
fi
echo "######################################################################"
exit $(( fail > 0 ? 1 : 0 ))
