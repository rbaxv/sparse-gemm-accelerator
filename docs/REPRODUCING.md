# Reproducing the results

Run from the repository root, on Linux. Tool installations are external; no executable, UVM distribution or PDK is bundled. Paths should avoid spaces because Yosys/Make/Tcl scripts use conventional EDA path syntax. Start with `python3 scripts/run.py doctor`.

## Dependencies

| Target | Required tools | Qualified original version |
|---|---|---|
| Unit tests | Python, pytest, NumPy | Python 3.12; see `requirements.txt` |
| Directed RTL comparison | Icarus Verilog and vvp | See public validation tool records |
| UVM / waveform | Verilator, C++ compiler, make, Accellera UVM | Verilator 5.055 devel (`v5.054-55-gc0e51cadc`); UVM 1800.2-2020.3.2 |
| Generic synthesis | Yosys | 0.70+329, git b8d84f823 |
| Physical implementation | ORFS, OpenROAD, Yosys, KLayout, Nangate45 files and flow dependencies | ORFS commit `9d5f91a174e8d8f0d83fa4fa7391851a6f1625c0`; OpenROAD 26Q2-1164-g08f67ee5ec; KLayout 0.30.12 |
| Waveform viewing | GTKWave | Saved VCD views included |

Obtain tools from their maintainers: [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build/releases/tag/2026-11-04), [Accellera UVM](https://www.accellera.org/downloads/standards/uvm), and [OpenROAD-flow-scripts](https://github.com/The-OpenROAD-Project/OpenROAD-flow-scripts). The qualified OSS CAD archive was `oss-cad-suite-linux-x64-20261104.tgz`, SHA256 `8b4ee0a8071df1e20d3497c4fc11d66cc69991bd3e97903d56cc689c41fdea9a`. Newer versions may work but require requalification; do not silently substitute them for published comparisons.

Install a C++ compiler and make using your Linux distribution. Add the extracted CAD tools to PATH and point UVM_HOME at the directory containing `src/uvm_pkg.sv`:

```bash
export PATH=/absolute/path/to/oss-cad-suite/bin:$PATH
export UVM_HOME=/absolute/path/to/1800.2-2020.3.2
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements.txt
python scripts/run.py doctor
python scripts/run.py unit
python scripts/run.py compare
python scripts/run.py uvm
python scripts/run.py synth
```

`compare` runs the frozen baseline and candidate on 12 directed jobs each. It checks arithmetic inside the testbench, then requires exact cycle/word CSV equality to retained measurements. `uvm` builds once with one compiler job to bound RAM, then runs four scenarios. Compilation can take minutes. Build logs preserve compiler warnings; zero UVM warning summaries do not imply zero compiler warnings.

`synth` checks 16 signed 8×8→16 PE multipliers, no inferred latches/dividers, and Yosys structural consistency before and after generic mapping. It reports any other arithmetic multipliers separately. It is not a Nangate technology-mapped functional verdict.

## Model study

```bash
python scripts/run.py model
```

This evaluates 160 replayable workload/mode/service inputs × 24 combinations = 3,840 experiments: overlap on/off, packing on/off, TK 4/8/16 and two bank mappings. It checks mathematical outputs and reconciles the original configuration against 160 measured baseline blocks. Results are **model predictions**, not new RTL implementations. The serialized inputs are in `datasets/`.

## Short waveform

```bash
python scripts/run.py waveform
# Substitute the exact directory printed by the command:
cd results/waveform-<run-id>
gtkwave waveform.vcd 03_packing.gtkw
```

Other views: `01_protocol.gtkw` (valid/ready and outputs), `02_buffers.gtkw` (producer/consumer ownership), `04_pe.gtkw` (operands, products, accumulator). Signals `data_valid && data_ready` identify accepted host words; `bits`, `reservoir` and `pop` explain unpacking. `enq`, `deq` and state show ownership. PE operands are signed 8-bit values; interpret products as signed 16-bit and sums as signed 32-bit. Use the GTKWave signed-decimal display option rather than mistaking negative two's-complement values for large positive integers.

A waveform is illustrative evidence; the strict log and coverage verdict establish whether the demo passed. It is not the full regression.

## Optional physical flow

Build/install the pinned ORFS environment with its dependencies and platform files first. Only one physical top is used. This entry point generates the same selected constraints and repair policy:

```bash
export ORFS_ROOT=/absolute/path/to/OpenROAD-flow-scripts
python scripts/run_physical.py integrated 20 35
```

This is a potentially long build. It writes `config.mk`, SDC, repair hook, source snapshots, `flow.log` and a manifest in a new run. A successful Make exit is deliberately labelled **AUDIT_PENDING**. Inspect DRC, antenna, timing/electrical constraints and functional equivalence/checks before declaring physical closure. The portable flow entry point was inspected/compiled during packaging, not rerouted; published physical measurements come from the original recorded run.

To view a completed database (not a screenshot):

```bash
openroad -gui -db results/<physical-run>/results/nangate45/gemm_accel/base/6_final.odb
```

`2_floorplan.odb`, `3_place.odb`, `4_cts.odb` and `5_route.odb`, when present, show successive stages. ODB is OpenROAD's editable physical database; DEF describes placement/routing interchange; GDS contains final layout polygons. GDS existence alone does not prove DRC/LVS/timing signoff. Loading only ODB does not load a complete STA context: Liberty, SDC and SPEF must also be loaded for timing.

## Outputs and repeatability

Never reuse a run directory for a new attempt. New runs record commands, versions, hashes, logs and verdicts; failures stay available. Generated files under `results/` are ignored by Git. Retained `evidence/` is small, explicit and separate from generated outputs. Private study notes and absolute personal tool paths are not runtime dependencies.

After a physical flow completes, these read-only audits check the final database and extracted RC. Use the audit directory printed by the first command as the second command's input:

```bash
python scripts/audit_physical.py results/<physical-run>
python scripts/audit_clock.py results/<audit-run> 5
```

The first audit requires complete final artifacts, empty router DRC report and clean timing/electrical results. The second verifies preserved artifact/source-snapshot hashes and audits the unchanged layout at 5 ns. Neither replaces foundry signoff or mapped functional checking. The original mapped functional result is retained as historical evidence; no automated mapped replay is claimed by the public generic-synthesis command.
