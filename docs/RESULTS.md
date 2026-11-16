# Evidence and limits

## Historical results retained

| File | Origin / interpretation |
|---|---|
| `evidence/baseline_metrics.csv`, `candidate_metrics.csv` | `g6-directed-rtl-comparison-20261107T111759795232Z`; 12 jobs per design |
| `evidence/uvm_manifest.json` | `g6-integrated-uvm-gate-20261107T113814564307Z`; full selected-candidate gate |
| `evidence/stalled_coverage.csv`, `nostall_coverage.csv` | Counts and witness cycles from that full gate |
| `evidence/physical_closure.json` | `g6-integrated-closure-20261107T180928207164Z`; original route, audit and comparison IDs |
| `evidence/source_review.json` | Original/public SV hashes and formatting-token comparison |
| `evidence/public_validation.json` | Checks freshly run against this public copy |

Historical manifest paths were replaced with `original-run:` or `original-workspace` identifiers. They identify provenance; they are not executable local paths. Source hashes are retained. Formatting changes byte hashes; token-preservation records connect the public RTL/testbench to its original source.

The full historical UVM stalled run checked 195,235 edges; no-stall checked 153,788. Each checked 1,776 normal accepted commands, 75,430 normal accepted words, 857,088 products and 857,088 accumulator entries. These are monitor-scope counts, not total raw pin activity during deliberately invalid cases. The 242 goals define a finite functional scope.

The G5 architecture study measured 560 blocks across seven modes and two service policies; it motivated the WS focus. That broader study is historical context. This public release's supported execution path reproduces the selected candidate and matched WS control, not every historical route or gate.

## Why the optimization helps—and costs area

For directed sparse M=2/K=768/N=2, loading overlap plus packing reduces cycles 2982→2184 and words 768→624. The extra operand storage, unpacking and control increase routed cell area 132540→170487 µm². This tradeoff must be evaluated against workload and interface constraints. A single-slab job has no next slab to overlap and can regress by one cycle.

The model's M=16/K=768/N=4 sparse example predicted 10001 baseline cycles, 10049 packing-only, 6100 overlap-only and 6101 combined. Packed transfers reduced 3840→3552 words. These are model values, deliberately not presented as measured integrated RTL results.

## Physical interpretation

Original selected route: `g6-route-resume-20261107T124135206076Z`. Nangate45 typical, 35% initial utilization, 20 ns implementation target; no memory macros. At the separately audited 5 ns period the unchanged layout had setup +2.123975056 ns and hold +0.011928903 ns, with zero required setup/hold/slew/capacitance/fanout violations in that audit. This does not establish arbitrary-corner timing closure or maximum clock frequency.

Original physical work included timing repair and iterative detailed routing. Selected route violations fell through 19353→4488→3540→47→7→7→0 across recorded router iterations. These are router-stage counts, not independent failing chip versions. Hold/capacitance repair inserted cells and consumed area; the final layout is not simply an idealized placement of the RTL gates. The public flow retains the selected hold margin 0.03 ns, capacitance margin 20, slew margin 10 and repair buffer allowance 100%.

The original postroute functional run used 12 directed jobs, zero-delay cell models and Boolean initial-state setup followed by reset. It was not SDF timing simulation. No new physical build was required for source formatting, and this release does not claim one.

## Explicit exclusions

No foundry signoff, full LVS proof, multi-corner closure, measured power, silicon result, end-to-end CNN/LLM accuracy, universal architecture winner or published/accepted research-paper claim. GDS is a layout artifact, not proof of any of these. Future work should report both host traffic and cycles, and rerun affected verification for behavioral changes.

## Source review and warnings

The public preparation reformatted RTL/testbenches without changing non-comment tokens and formatted Python with AST-equivalence checks. Focused review covered ownership handshakes, reservoir pop/append ordering, signed PE arithmetic, tail enables and the strict UVM verdict. This is a source review plus regression, not a formal equivalence proof or an exhaustive lint cleanup.

Yosys reports conversion of PE arrays to registers: this matches the implemented standard-cell storage and the absence of SRAM macros. Descriptor/length arithmetic can create additional small generic multipliers; the structural assertion specifically counts **16 signed INT8 arithmetic PE multipliers**, not all `$mul` nodes in the controller. Verilator also emits compile-time width/unused-port and related diagnostics; these are retained in local validation logs. Zero runtime UVM warnings must not be presented as warning-free compilation.

## Fresh publication validation

The public copy passed 155 Python tests, 12 directed jobs per design with exact saved metrics, the full 242-goal UVM gate with replay and rejected mutation, the short waveform demo, all 3,840 model experiments and generic synthesis with 16 signed INT8 PE multipliers. Portable read-only physical and 5 ns audits also passed on the original layout. A separate clean-directory copy repeated the unit tests and directed comparison with the working-project root variable unset. Full build trees remain outside the source publication folder.
