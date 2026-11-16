# Public-source preparation review

The original working project and private learning notes were left separate. Public RTL and testbenches were formatted using Verible; copied Python was formatted with Black's AST-equivalence check. Explanatory comments were added around the selected controller, transport adapter, PE arithmetic and UVM checker roles. `evidence/source_review.json` connects all 31 public SV files to their original byte hashes and records equal non-comment tokens. No arithmetic, scheduling or ownership redesign was performed during publication preparation.

The supported public runner uses paths relative to itself and external tool environment variables. It snapshots inputs, records commands and versions, and rejects incomplete or unexpected UVM outcomes. A packaging issue was found and fixed: version probing must target known tool commands only, never execute a generated simulator with `--version`. Initial waveform evidence remains valid; the explicit simulation run and strict verdict passed independently. The correction prevents an unnecessary extra simulation during future runs.

## Focused review

- Descriptor acceptance is distinct from command intent, with ordered two-buffer ownership.
- Packed transport uses pop-before-append accounting on simultaneous operations.
- Metadata validation and final padding checks are at load boundaries; PE tail masking is separate.
- Signed operands/products and mathematical coordinate checks are retained.
- Output queue no-push/no-pop behavior intentionally holds state.
- UVM success requires report parsing and a completion marker; mutation rejection remains mandatory.
- Generic synthesis uses RTL-only sources; physical tops are mutually exclusive.

## Known compiler diagnostics

`evidence/compiler_warning_counts.json` records the selected public build warnings. Missing debug pins are unused exported debug ports; the test observes internal checker signals. RTL modules omit simulation timescales while the testbench provides them. Width expansion/truncation diagnostics remain in address/length and test arithmetic; declared dimension bounds and directed/extreme tests constrain these cases, but that is not an exhaustive proof of every width conversion. The output queue's incomplete sequential case intentionally holds state when neither push nor pop occurs. Yosys memory-to-register conversion matches the standard-cell implementation.

These diagnostics were preserved rather than globally relabelled as “clean.” The release has passing bounded verification and reviewed source formatting; it does not claim zero compiler diagnostics, full formal equivalence, exhaustive lint closure or full code/toggle coverage. Behavioral cleanup of width expressions would be a separate change with affected regression reruns.
