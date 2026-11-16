# Architecture and interface

## Development direction

The study preserved native dense output-stationary (D-OS), grouped sparse OS, WS and a project-specific row-serial RS control. G5 measurements motivated focusing on WS. G6 first tested overlap, packing, TK and bank mapping in a four-factor model; only the selected overlap+packing configuration was then integrated in RTL. These are distinct evidence levels: a model experiment is not an implemented hardware variant.

The public candidate keeps one multiplier per PE, `TK=16`, original banks and the original partial-sum organization. Overlap attacks serialized loading; packing reduces host traffic. Packing adds reservoir/control logic and can add an unpacking cycle, so fewer words need not mean fewer total cycles.

## Data and arithmetic

Compute `C[M,N] = A[M,K] × W[K,N]`. Inputs are signed INT8 and products signed INT16. INT32 partial sums persist between slabs. Legal host dimensions are M=1…16, N=1…4 and K=1…8192; each slab has L=min(16,K−offset). These bounds keep the signed accumulation range within INT32 for INT8 inputs.

Every four K positions of a weight column store two values and a code:

| Code | Positions |
|---|---|
| 0 | 0,1 |
| 1 | 0,2 |
| 2 | 0,3 |
| 3 | 1,2 |
| 4 | 1,3 |
| 5 | 2,3 |
| 6,7 | Invalid |

A record is `{code[2:0], value1[7:0], value0[7:0]}`. Zero is legal in either stored slot. Metadata determines scheduled positions; the design does not skip every multiplication whose value happens to be zero. Tail masks suppress K coordinates outside the slab. Dense-mode comparisons use the same pruned matrix expanded to four positions, not unrelated dense weights.

## Pin-level protocol

All handshakes are sampled on rising `clk`. Reset and abort are synchronous. Testbench driving occurs at falling edges, monitoring captures accepted inputs at rising edges, and state checks account for nonblocking updates.

| Pins | Contract |
|---|---|
| `cmd_valid`, `cmd_ready` | Accept a descriptor only when both are high |
| `cmd_first`, `cmd_final`, `cmd_sparse` | Start/end job and fixed job mode |
| `cmd_id`, `cmd_m`, `cmd_n`, `cmd_k` | Stable job identity and total shape |
| `cmd_offset`, `cmd_l` | Contiguous K slab offset and actual length |
| `data_valid`, `data_ready`, `data[31:0]`, `data_last` | Ordered payload words for the accepted load descriptor |
| `compute_enable` | Permit compute advancement; pause preserves computation state |
| `out_valid`, `out_ready` | Accept tagged row/column/data output; blocked output stays stable |
| `done`, `error` | Completion and invalid protocol/payload indication |
| `rst`, `abort` | Cancel outstanding descriptors and recover ownership/state |

A new first command requires no active job and offset zero. Continuations must retain ID, M, N, K and mode, use the next accepted offset, and mark final exactly when offset+L=K. Producers must hold valid payloads until accepted. Invalid commands or malformed data enter error handling; reset/abort is the recovery mechanism.

## Host stream order

Activation payload comes first: row-major, four signed bytes per word, with `ceil(L/4)` words per row. Weights follow in column-major group order. Dense weights use four bytes per group word. Sparse weights concatenate 19-bit records least-significant bits first into a continuous stream, transmitted in 32-bit words. Unused high bits in the final transport word are zero; `data_last` marks the final payload word. Activation bytes outside L are ignored by coordinate masks.

For sparse weights the transport needs `ceil(19*N*ceil(L/4)/32)` words, versus `N*ceil(L/4)` padded words in the baseline. Activations and other protocol costs are unchanged. Transport padding and arithmetic K-tail masking solve different problems.

`packed_slab_loader` uses a 64-bit reservoir. It can pop one 19-bit record and accept a new 32-bit word on the same edge. The new word is appended after subtracting the popped bits. The wrapper checks final-word padding and stream length; `slab_loader` checks metadata 6/7 and stores expanded records. The compute core does not replace load-boundary validation.

## Buffer ownership and compute

Two independent operand stores alternate producer (`enq`) and consumer (`deq`) ownership. A buffer progresses through free → loading → ready → compute → released. An accepted descriptor reserves its buffer; computation cannot consume an incomplete payload. With two outstanding descriptors the command interface backpressures the host. Reset/abort discards both descriptors; stale buffered data is not treated as a valid new job.

The array holds weights locally, streams activations and produces ordered partial sums. Sparse operation uses two phases per group; dense operation uses four on the same hardware. Local per-PE operand timing is checked using mathematical row/column/K coordinates, including inactive rows/columns and tails. Final partial sums are drained with output backpressure.

Read `ws_integrated.sv` for scheduling/ownership, `packed_slab_loader.sv` for transport, `slab_loader.sv` for bank storage and `sparse_ws.sv` for arithmetic. Physical wrappers deliberately omit debug ports from the external boundary. All physical wrappers declare `gemm_accel`; never compile them together.
