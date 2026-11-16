import random
import pytest
from model.sparse_schedule import events
from model.oracle import pack_record, decode, gemm


@pytest.mark.parametrize("code", range(6))
@pytest.mark.parametrize("k", [1, 2, 3, 4, 7, 16])
def test_coordinate_schedule(code, k):
    rng = random.Random(20261105 + code + k)
    records = [
        [pack_record((code + g + c) % 6, -128, 127) for c in range(2)]
        for g in range((k + 3) // 4)
    ]
    a = [[rng.randrange(-128, 128) for _ in range(k)] for _ in range(2)]
    sparse = events(a, records, k, 2, True)
    dense = events(a, records, k, 2, False)
    assert len(sparse) == 2 * ((k + 3) // 4 + 2)
    assert len(dense) == 4 * ((k + 3) // 4 + 2)
    assert sparse[-1]["sums"] == dense[-1]["sums"] == gemm(a, decode(records, k, 2))
    for e in sparse:
        for p in e["products"]:
            assert e["slot"] == p["group"] + p["r"] + p["c"]


def test_hand_identity():
    # K=2: code01 positions (0,1), including stored zeros.
    t = events([[1, 2], [3, 4]], [[pack_record(0, 1, 0), pack_record(0, 0, 1)]], 2, 2)
    assert [x["sums"] for x in t] == [
        [[1, 0], [0, 0]],
        [[1, 0], [0, 0]],
        [[1, 0], [3, 0]],
        [[1, 2], [3, 0]],
        [[1, 2], [3, 0]],
        [[1, 2], [3, 4]],
    ]


@pytest.mark.parametrize("code", [6, 7])
def test_invalid_code_rejected_by_model(code):
    with pytest.raises(ValueError):
        events([[1, 2, 3, 4]], [[code << 16]], 4, 1)
