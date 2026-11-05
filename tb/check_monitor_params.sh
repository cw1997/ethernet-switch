#!/usr/bin/env bash
# Invalid static configurations must fail elaboration rather than run silently.
set -euo pipefail
simulator="$1"
build_dir="$2"
rtl_dir="$3"
checks=0
for config in \
  sw_uart:DATA_BITS:4 sw_uart:DATA_BITS:9 \
  sw_uart:PARITY:3 sw_uart:STOP_BITS:0 sw_uart:STOP_BITS:3 \
  sw_uart:FLOW_CONTROL:2 sw_uart:BAUD_RATE:0 sw_uart:BAUD_RATE:7800000 sw_uart:BAUD_RATE:12250000 \
  sw_console:UART_DATA_BITS:5 sw_console:UART_DATA_BITS:6 \
  sw_monitor:REFRESH_INTERVAL_MS:0 sw_monitor:CLK_FREQ_HZ:0 sw_monitor:NUM_PORTS:0
do
  IFS=: read -r top parameter value <<< "$config"
  if "$simulator" -g2012 -I "$rtl_dir" -s "$top" "-P$top.$parameter=$value" \
    -o "$build_dir/invalid-monitor.vvp" \
    "$rtl_dir/sw_defs.sv" "$rtl_dir/sw_uart.sv" "$rtl_dir/sw_console.sv" \
    "$rtl_dir/sw_ratio.sv" "$rtl_dir/sw_monitor.sv" \
    > "$build_dir/invalid-monitor.log" 2>&1; then
    echo "FAIL invalid configuration accepted: $config"
    exit 1
  fi
  if ! grep -q 'Unknown module type: SW_' "$build_dir/invalid-monitor.log"; then
    cat "$build_dir/invalid-monitor.log"
    echo "FAIL configuration rejected for an unexpected reason: $config"
    exit 1
  fi
  echo "PASS invalid configuration rejected: $config"
  checks=$((checks+1))
done
echo "monitor parameter checks: $checks passed, 0 errors"
