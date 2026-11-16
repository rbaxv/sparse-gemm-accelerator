"""RS alternate: two output rows x four columns x two products = 16 multipliers.
Model-only finite-bank screen, not a synthesizable or routed implementation.
"""

from model.oracle import PAIRS, gemm


def evaluate(a, w, records, sparse=True):
    M, K, N = len(a), len(w), len(w[0])
    assert M <= 16 and N <= 4 and K <= 8192
    result = [[0] * N for _ in range(M)]
    trace = []
    cycle = 0

    def tick(kind, requests=(), **extra):
        nonlocal cycle
        cycle += 1
        keys = [(q[0], q[1]) for q in requests]
        assert len(keys) == len(set(keys)), ("bank conflict", cycle, requests)
        trace.append(dict(cycle=cycle, kind=kind, requests=requests, **extra))

    for off in range(0, K, 16):
        L = min(16, K - off)
        G = (L + 3) // 4
        for row in range(M):
            for g in range(G):
                tick("load", [("A", row % 4, 4 * (row // 4) + g, "write")])
        for c in range(N):
            for g in range(G):
                tick("load", [("W", c, g, "write")])
        for base in range(0, M, 2):
            active = list(range(base, min(base + 2, M)))
            if off:
                for row in active:
                    tick("seed_issue", [("P", c, row, "read") for c in range(N)])
                    tick("seed_capture")
            tick("accumulator_seed")
            for g in range(G):
                tick(
                    "operand_issue",
                    [("A", row % 4, 4 * (row // 4) + g, "read") for row in active]
                    + [("W", c, g, "read") for c in range(N)],
                )
                tick("operand_capture")
                for phase in range(1 if sparse else 2):
                    products = []
                    for row in active:
                        for c in range(N):
                            positions = (
                                PAIRS[records[off // 4 + g][c] >> 16 & 7]
                                if sparse
                                else (2 * phase, 2 * phase + 1)
                            )
                            pair = [
                                (
                                    a[row][off + 4 * g + p] * w[off + 4 * g + p][c]
                                    if 4 * g + p < L
                                    else 0
                                )
                                for p in positions
                            ]
                            assert all(-(1 << 15) <= v < (1 << 15) for v in pair)
                            pair_sum = sum(pair)
                            assert -(1 << 16) <= pair_sum < (1 << 16)
                            result[row][c] += pair_sum
                            products.append((row, c, pair, pair_sum))
                    tick("compute", products=products)
            for row in active:
                tick("commit", [("P", c, row, "write") for c in range(N)])
    for row in range(M):
        for c in range(N):
            tick("drain_issue", [("P", c, row, "read")])
            tick("drain_accept")
    assert result == gemm(a, w)
    counts = {}
    for e in trace:
        counts[e["kind"]] = counts.get(e["kind"], 0) + 1
    return dict(
        result=result,
        cycles=cycle,
        counts=counts,
        trace=trace,
        resources={
            "multipliers_int8": 16,
            "pair_adders_signed17": 8,
            "accumulators_int32": 8,
            "operand_staging_bits": 192,
            "local_accumulator_bits": 256,
            "bank_bits": 4608,
        },
    )
