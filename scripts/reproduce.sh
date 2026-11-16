#!/usr/bin/env bash
# Reproduce the supported selected-candidate checks. Tools must already exist.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
: "${UVM_HOME:?Set UVM_HOME to the Accellera UVM directory containing src/uvm_pkg.sv}"
for tool in python3 iverilog vvp verilator yosys; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
python3 scripts/run.py unit
python3 scripts/run.py compare
python3 scripts/run.py uvm
python3 scripts/run.py synth
# Optional, independent studies: run.py model and run.py waveform.
# Physical implementation is intentionally separate because it is expensive.
