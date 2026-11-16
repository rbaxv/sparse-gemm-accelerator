import pytest, random
from model.ws_schedule import events
from model.oracle import pack_record, decode, gemm, encode


def test_literal_psum_identity():
    a = [list(range(1, 9)), list(range(11, 19))]
    w = [[0, 0] for _ in range(8)]
    for k, c in [(0, 0), (4, 0), (1, 1), (5, 1)]:
        w[k][c] = 1
    t = list(events(a, encode(w), 8, 2))
    assert len(t) == 8
    assert t[3]["sums"][1][0] == 6
    assert t[5]["sums"][1] == [26, 8]
    assert t[7]["sums"][1][1] == 28


@pytest.mark.parametrize("R", [2, 4])
@pytest.mark.parametrize("code", range(6))
@pytest.mark.parametrize("sparse", [False, True])
def test_coordinate_final(R, code, sparse):
    rng = random.Random(code)
    k = R * 4 - 1
    n = R
    m = 5
    a = [[rng.randrange(-128, 128) for _ in range(k)] for _ in range(m)]
    rec = [[pack_record(code, -128, 127) for _ in range(n)] for _ in range(R)]
    w = decode(rec, k, n)
    gold = gemm(a, w)
    seeds = [[r + c - 9 for c in range(n)] for r in range(m)]
    t = list(events(a, rec, k, n, R, sparse, seeds))
    p = 2 if sparse else 4
    for r in range(m):
        for c in range(n):
            assert (
                t[(r + R - 1 + c) * p + p - 1]["sums"][R - 1][c]
                == gold[r][c] + seeds[r][c]
            )


@pytest.mark.parametrize("shape", [(1, 1, 1), (3, 7, 2), (5, 17, 3), (16, 33, 4)])
@pytest.mark.parametrize("sparse", [False, True])
def test_finite_bank_schedule(shape, sparse):
    from model.ws_banks import schedule

    m, k, n = shape
    a = [[((r + t) * 17) % 256 - 128 for t in range(k)] for r in range(m)]
    rec = [
        [pack_record((g + c) % 6, -128, 0 if g % 2 else 127) for c in range(n)]
        for g in range((k + 3) // 4)
    ]
    w = decode(rec, k, n)
    result = schedule(a, w, rec, sparse)
    assert result["result"] == gemm(a, w)
    # One bank operation per edge and response exactly one edge after request.
    pending = []
    for e in result["trace"]:
        assert [(q["space"], q["bank"], q["addr"]) for q in e["responses"]] == pending
        keys = [(q["space"], q["bank"]) for q in e["requests"]]
        assert len(keys) == len(set(keys))
        pending = [
            (q["space"], q["bank"], q["addr"])
            for q in e["requests"]
            if q["op"] == "read"
        ]
    assert not pending
