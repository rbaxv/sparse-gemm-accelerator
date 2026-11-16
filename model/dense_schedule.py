"""Coordinate/event model: no shift-register implementation."""

from model.oracle import gemm


def trace(a, w):
    final = gemm(a, w)
    r_count = len(a)
    c_count = len(w[0])
    k_count = len(w)
    accum = [[0] * c_count for _ in a]
    events = []
    for edge in range(k_count + r_count + c_count - 2):
        products = []
        for r in range(r_count):
            for c in range(c_count):
                k = edge - r - c
                if 0 <= k < k_count:
                    accum[r][c] += int(a[r][k]) * int(w[k][c])
                    products.append(
                        {"r": r, "c": c, "k": k, "a": a[r][k], "w": w[k][c]}
                    )
        events.append(
            {"edge": edge, "products": products, "c": [row[:] for row in accum]}
        )
    assert accum == final
    return events
