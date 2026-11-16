"""Version 1 mathematical contract; no hardware scheduling dependencies."""

from numbers import Integral

PAIRS = ((0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3))
SCHEMA = "int8-2of4-v1"


def integer(x, lo, hi):
    if not isinstance(x, Integral) or isinstance(x, bool) or not lo <= x <= hi:
        raise ValueError(f"expected integer [{lo},{hi}], got {x!r}")
    return int(x)


def matrix(x):
    if not len(x) or not len(x[0]):
        raise ValueError("empty matrix")
    width = len(x[0])
    if any(len(row) != width for row in x):
        raise ValueError("ragged matrix")
    return [[integer(v, -128, 127) for v in row] for row in x]


def gemm(a, w):
    a, w = matrix(a), matrix(w)
    k = len(w)
    integer(k, 1, 8192)
    if len(a[0]) != k:
        raise ValueError("K mismatch")
    return [
        [sum(int(a[i][t]) * int(w[t][j]) for t in range(k)) for j in range(len(w[0]))]
        for i in range(len(a))
    ]


def pack_record(code, v0, v1):
    code = integer(code, 0, 5)
    return (
        (code << 16)
        | ((integer(v1, -128, 127) & 255) << 8)
        | (integer(v0, -128, 127) & 255)
    )


def unpack_record(word):
    word = integer(word, 0, (1 << 32) - 1)
    if word >> 19:
        raise ValueError("reserved bits nonzero")
    code = (word >> 16) & 7
    if code > 5:
        raise ValueError("illegal sparse metadata")

    def signed(v):
        return v - 256 if v & 128 else v

    return code, signed(word & 255), signed((word >> 8) & 255)


def encode(w):
    w = matrix(w)
    k = len(w)
    integer(k, 1, 8192)
    n = len(w[0])
    records = []
    for g in range((k + 3) // 4):
        row = []
        for j in range(n):
            vals = [w[4 * g + p][j] if 4 * g + p < k else 0 for p in range(4)]
            nonzero = [p for p, v in enumerate(vals) if v]
            if len(nonzero) > 2:
                raise ValueError("weight is not 2:4 representable; no implicit pruning")
            positions = sorted(
                nonzero + [p for p in range(4) if p not in nonzero][: 2 - len(nonzero)]
            )
            row.append(
                pack_record(
                    PAIRS.index(tuple(positions)), *(vals[p] for p in positions)
                )
            )
        records.append(row)
    return records


def decode(records, k, n):
    k = integer(k, 1, 8192)
    n = integer(n, 1, 2**31 - 1)
    if len(records) != (k + 3) // 4 or any(len(row) != n for row in records):
        raise ValueError("record shape mismatch")
    w = [[0] * n for _ in range(k)]
    for g, row in enumerate(records):
        for j, word in enumerate(row):
            code, v0, v1 = unpack_record(word)
            for p, value in zip(PAIRS[code], (v0, v1)):
                if 4 * g + p < k:
                    w[4 * g + p][j] = value
    return w


def pack_activation(values):
    if not 1 <= len(values) <= 4:
        raise ValueError("one to four bytes required")
    return sum((integer(v, -128, 127) & 255) << (8 * i) for i, v in enumerate(values))
