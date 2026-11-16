import itertools, random
import numpy as np
import pytest
from model.oracle import (
    gemm,
    encode,
    decode,
    pack_record,
    unpack_record,
    pack_activation,
)


@pytest.mark.parametrize(
    "code,positions", list(enumerate(((0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3))))
)
def test_independent_code_fixture(code, positions):
    word = (code << 16) | 0x7F80
    actual = decode([[word]], 4, 1)
    expected = [[0] for _ in range(4)]
    expected[positions[0]][0] = -128
    expected[positions[1]][0] = 127
    assert actual == expected
    assert pack_record(code, -128, 127) == word


@pytest.mark.parametrize("word", [0x60000, 0x70000, 0x80000, 0xFFFFFFFF])
def test_bad_codes_reserved(word):
    with pytest.raises(ValueError):
        decode([[word]], 4, 1)


def test_known_input():
    assert pack_activation([1, -2, 3, -4]) == 0xFC03FE01
    assert pack_activation([5, -6, 7]) == 0x0007FA05
    w = decode([[0x0403FE], [0x01FF04]], 7, 1)
    assert w == [[0], [-2], [0], [3], [4], [0], [-1]]
    assert gemm([[1, -2, 3, -4, 5, -6, 7]], w) == [[5]]


def test_extremes_max_k():
    assert gemm([[-128] * 8192], [[-128] for _ in range(8192)]) == [[134217728]]
    assert gemm([[-128, -128]], [[-128], [127]]) == [[128]]
    assert gemm([[127, 127]], [[-128], [127]]) == [[-127]]


def test_tail_padding_ignored():
    for k in (1, 2, 3):
        for code in range(6):
            w = decode([[pack_record(code, 127, -128)]], k, 1)
            assert len(w) == k
            assert gemm([[1] * k], w) == [[sum(row[0] for row in w)]]


def test_seeded_shapes_roundtrip_and_independent_numpy():
    rng = random.Random(20261105)
    for m, k, n in [
        (1, 1, 1),
        (2, 4, 2),
        (3, 7, 5),
        (7, 67, 11),
        (4, 16, 4),
        (1, 8192, 1),
    ]:
        a = [[rng.randrange(-128, 128) for _ in range(k)] for _ in range(m)]
        w = [[0] * n for _ in range(k)]
        for g in range((k + 3) // 4):
            for j in range(n):
                for p in rng.sample(range(4), 2):
                    if 4 * g + p < k:
                        w[4 * g + p][j] = rng.randrange(-128, 128)
        assert decode(encode(w), k, n) == w
        assert (
            gemm(a, w)
            == (np.asarray(a, dtype=np.int64) @ np.asarray(w, dtype=np.int64)).tolist()
        )


@pytest.mark.parametrize(
    "a,w",
    [
        ([], [[1]]),
        ([[128]], [[1]]),
        ([[1.0]], [[1]]),
        ([[True]], [[1]]),
        ([[1, 2]], [[1]]),
        ([[1], [2, 3]], [[1]]),
        ([[1] * 8193], [[1]] * 8193),
    ],
)
def test_invalid_jobs(a, w):
    with pytest.raises(ValueError):
        gemm(a, w)


def test_no_implicit_pruning():
    with pytest.raises(ValueError):
        encode([[1], [2], [3], [0]])
