"""Coordinate-level buffered WS expectations; no RTL FSM/register emulation."""


def slab_events(a, w, codes, prior, sparse):
    m, length, n = len(a), len(w), len(w[0])
    phases = 2 if sparse else 4
    positions = ((0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3))
    for slot in range(m + n + 2):
        reads = []
        for group in range((length + 3) // 4):
            row = slot - group
            if 0 <= row < m:
                reads.append((row % 4, 4 * (row // 4) + group, row, group))
        assert len({x[0] for x in reads}) == len(reads)
        for phase in range(phases):
            sums, valids = [], []
            for group in range(4):
                for col in range(4):
                    row = slot - group - col
                    valid = 0 <= row < m and col < n
                    value = 0
                    if valid:
                        value = prior[row][col] + sum(
                            a[row][k] * w[k][col] for k in range(min(4 * group, length))
                        )
                        selected = (
                            positions[codes[group][col]][: phase + 1]
                            if sparse and 4 * group < length
                            else range(phase + 1)
                        )
                        value += sum(
                            a[row][4 * group + p] * w[4 * group + p][col]
                            for p in selected
                            if 4 * group + p < length
                        )
                    sums.append(value)
                    valids.append(valid)
            yield dict(slot=slot, phase=phase, a_reads=reads, sums=sums, valids=valids)


def no_stall_after_load(m, n, sparse, final):
    """Edges from last accepted data through done; all outputs ready."""
    return 15 + (m + n + 2) * ((2 if sparse else 4) + 3) + (m * n + 2 if final else 0)
