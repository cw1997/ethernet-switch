#!/usr/bin/env bash
# ============================================================================
#  File        : sim/run_lint.sh
#  Description : Lint the RTL and the testbench with Verilator at -Wall.
#
#                The RTL is expected to be completely warning free - anything
#                reported for `sw_*` is a real finding.  For the testbench a few
#                classes are waived for good reasons, which are marked inline:
#
#                  UNUSEDSIGNAL  - stimulus signals that a given test does not
#                                  exercise
#                  WIDTHCONCAT   - the testbench frame buffer is 16 kbit wide,
#                                  so a plain `'0 exceeds Verilator's 8 kbit
#                                  "this replication is probably a typo" hint
#                  UNUSEDPARAM   - a testbench parameter (a port id, a protocol
#                                  constant) that the elaborated configuration
#                                  happens not to reference
#                  BLKSEQ        - a few blocks are only there to give a test
#                                  its name
#
#  Usage       : sim/run_lint.sh
# ============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

status=0

echo "======================================================================"
echo " Linting the RTL with Verilator -Wall (expect: no output at all)"
echo "======================================================================"
for top in es_common_crc32 es_mems_sync_fifo es_switch_gmii_rx es_switch_gmii_tx es_switch_mac_table \
           es_switch_rx_port es_switch_tx_port es_switch_arbiter es_switch_mii es_switch_rmii \
           es_switch_core es_switch_gmii es_switch_mii es_switch_rmii; do
  printf '%-14s : ' "$top"
  out="$(verilator --lint-only --timing -Wall -Wno-DECLFILENAME \
           -Irtl -f sim/sw_rtl.f --top-module "$top" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "ERROR"; echo "$out"; status=1
  elif [[ -n "$out" ]]; then
    echo "WARNINGS"; echo "$out"; status=1
  else
    echo "clean"
  fi
done

echo
echo "======================================================================"
echo " Linting the testbench with Verilator -Wall"
echo "======================================================================"
for top in sw_gmii_if sw_mii_if sw_rmii_if sw_if_array sw_crc32_tb \
           sw_sync_fifo_tb sw_mac_table_tb sw_mii_tb sw_rmii_tb sw_flood_tb \
           sw_switch_param_tb tb_sw_switch tb_sw_switch_mii tb_sw_switch_rmii; do
  printf '%-20s : ' "$top"
  out="$(verilator --lint-only --timing -Wall -Wno-DECLFILENAME \
           -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-WIDTHCONCAT -Wno-BLKSEQ \
           -Irtl -Itb -f sim/sw_rtl.f -f sim/sw_tb.f --top-module "$top" 2>&1)"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "ERROR"; echo "$out"; status=1
  elif [[ -n "$out" ]]; then
    echo "WARNINGS"; echo "$out"
  else
    echo "clean"
  fi
done

exit $status
