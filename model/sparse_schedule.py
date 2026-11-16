"""Coordinate-derived grouped OS arithmetic events, independent of RTL registers.

All sums are Python integers. Event coordinates are (slot,phase,row,column,k).
This model describes legal jobs; protocol/error-state modeling is separate.
"""

from model.oracle import gemm, decode

POSITIONS = ((0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3))


def events(a, records, k, n, sparse=True):
    w = decode(records, k, n)
    final = gemm(a, w)
    m = len(a)
    groups = (k + 3) // 4
    phases = 2 if sparse else 4
    sums = [[0] * n for _ in range(m)]
    result = []
    for slot in range(groups + m + n - 2):
        for phase in range(phases):
            products = []
            for r in range(m):
                for c in range(n):
                    group = slot - r - c
                    if not 0 <= group < groups:
                        continue
                    word = records[group][c]
                    code = (word >> 16) & 7
                    if sparse:
                        position = POSITIONS[code][phase]
                        weight = (word >> (8 * phase)) & 255
                        weight = weight - 256 if weight >= 128 else weight
                    else:
                        position = phase
                        weight = (
                            w[4 * group + position][c]
                            if 4 * group + position < k
                            else 0
                        )
                    index = 4 * group + position
                    if index < k:
                        value = int(a[r][index]) * weight
                        sums[r][c] += value
                        products.append(
                            {
                                "r": r,
                                "c": c,
                                "group": group,
                                "k": index,
                                "product": value,
                            }
                        )
            result.append(
                {
                    "slot": slot,
                    "phase": phase,
                    "products": products,
                    "sums": [row[:] for row in sums],
                }
            )
    if sums != final:
        raise AssertionError("event arithmetic differs from mathematical oracle")
    return result
