"""WS products/PSUMs from output identity and mathematical K coordinates."""

from model.oracle import decode, unpack_record, PAIRS, gemm


def events(a, records, k, n, rows=2, sparse=True, seeds=None):
    assert 1 <= k <= 4 * rows and len(records) == (k + 3) // 4 and 1 <= n
    w = decode(records, k, n)
    M = len(a)
    seed = seeds or [[0] * n for _ in range(M)]
    P = 2 if sparse else 4
    for slot in range(M + rows + n - 2):
        for phase in range(P):
            sums = [[0] * n for _ in range(rows)]
            valid = [[0] * n for _ in range(rows)]
            ident = [[-1] * n for _ in range(rows)]
            for r in range(rows):
                for c in range(n):
                    i = slot - r - c
                    if 0 <= i < M:
                        valid[r][c] = 1
                        ident[r][c] = i
                        v = seed[i][c] + sum(
                            a[i][t] * w[t][c] for t in range(min(4 * r, k))
                        )
                        if r < len(records):
                            code, _, _ = unpack_record(records[r][c])
                            pos = (
                                PAIRS[code][: phase + 1] if sparse else range(phase + 1)
                            )
                            v += sum(
                                a[i][4 * r + p] * w[4 * r + p][c]
                                for p in pos
                                if 4 * r + p < k
                            )
                        sums[r][c] = v
            yield {
                "slot": slot,
                "phase": phase,
                "sums": sums,
                "valid": valid,
                "identity": ident,
            }
