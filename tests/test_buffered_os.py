import random, pytest
from model.oracle import encode, decode, pack_record
from model.buffered_os import run, Banks, request
from model.audit_buffered import audit


def fixture(m, k, n, seed=7):
    rng = random.Random(seed)
    a = [[rng.randrange(-128, 128) for _ in range(k)] for _ in range(m)]
    rec = [
        [
            pack_record((g + c) % 6, rng.randrange(-128, 128), rng.randrange(-128, 128))
            for c in range(n)
        ]
        for g in range((k + 3) // 4)
    ]
    return a, decode(rec, k, n), rec


@pytest.mark.parametrize("mode", ["sparse", "grouped_dense", "native_dense"])
@pytest.mark.parametrize(
    "shape", [(1, 1, 1), (3, 3, 2), (4, 4, 4), (5, 17, 3), (16, 33, 4), (16, 16, 4)]
)
def test_shapes(mode, shape):
    a, w, rec = fixture(*shape)
    r = run(a, w, rec, mode, stalls=True)
    assert r["status"] == "PASS"
    audit(r, a, w)
    assert r == run(a, w, rec, mode, stalls=True)


@pytest.mark.parametrize("bad", [6 << 16, 7 << 16, 1 << 19])
@pytest.mark.parametrize("slab", [0, 1])
def test_rejected_load(bad, slab):
    a, w, rec = fixture(5, 17, 4)
    r = run(a, w, rec, corrupt=(slab, 0, 3, bad))
    assert r["status"] == "REJECTED"
    audit(r, a, w)


def test_reset_every_phase_and_restart():
    a, w, rec = fixture(5, 17, 4)
    normal = run(a, w, rec, stalls=True)
    phases = {}
    for e in normal["events"]:
        phases.setdefault(e["phase"], e["cycle"])
    for cycle in phases.values():
        r = run(a, w, rec, stalls=True, reset_at=cycle)
        assert r["status"] == "RESET"
        audit(r, a, w)
    assert run(a, w, rec, stalls=True) == normal


def test_banks_latency_conflict_uninitialized_capacity():
    b = Banks()
    assert b.edge(1, [request("A", 0, 0, 123)]) == []
    assert b.edge(2, [request("A", 0, 0)]) == []
    assert b.edge(3, []) == [{"space": "A", "bank": 0, "addr": 0, "value": 123}]
    with pytest.raises(AssertionError, match="bank conflict"):
        Banks().edge(1, [request("A", 0, 0, 1), request("A", 0, 1, 2)])
    with pytest.raises(AssertionError, match="uninitialized"):
        Banks().edge(1, [request("P", 0, 0)])
    with pytest.raises(AssertionError, match="capacity"):
        Banks().edge(1, [request("W", 0, 4, 1)])


def test_literal_identity_cycles():
    a = [[1, 2], [3, 4]]
    w = [[1, 0], [0, 1]]
    rec = encode(w)
    r = run(a, w, rec)
    audit(r, a, w)
    # Four host words, validation, 2 nonempty slots*2 read edges,
    # seven sparse slots*2 compute phases, two commits, drain pipeline.
    assert r["counts"]["load"] == 4 and r["counts"]["validated"] == 1
    assert r["counts"]["operand_read"] == 4 and r["counts"]["compute"] == 14
    assert r["counts"]["psum_commit"] == 2 and r["counts"]["drain"] == 6
    assert r["cycles"] == 31


def test_mutation_rejected():
    a, w, rec = fixture(4, 7, 4)
    r = run(a, w, rec, fault="drop_last")
    with pytest.raises(AssertionError, match="product mismatch"):
        audit(r, a, w)


@pytest.mark.parametrize("mode", ["sparse", "grouped_dense", "native_dense"])
def test_max_k_and_signed_extreme(mode):
    k = 8192
    rec = [[pack_record(0, -128, -128)] for _ in range(k // 4)]
    w = decode(rec, k, 1)
    a = [[-128] * k]
    r = run(a, w, rec, mode)
    assert r["output"] == [(0, 0, 67108864)]
    audit(r, a, w)


@pytest.mark.parametrize("mode", ["sparse", "grouped_dense", "native_dense"])
def test_zero_and_cancellation(mode):
    for a in [[[0] * 17], [[1, -1, 1, -1] * 4 + [0]]]:
        rec = [[pack_record(0, 127, 127)] for _ in range(5)]
        w = decode(rec, 17, 1)
        r = run(a, w, rec, mode, stalls=True)
        audit(r, a, w)
        assert r["output"] == [(0, 0, 0)]


def test_reset_pending_response_and_blocked_output():
    a, w, rec = fixture(5, 17, 4)
    normal = run(a, w, rec, stalls=True)
    cycles = [
        next(
            e["cycle"] + 1
            for e in normal["events"]
            if any(q["op"] == "read" for q in e["requests"])
        ),
        next(
            e["cycle"] + 1
            for e in normal["events"]
            if e.get("out_valid") and not e["out_ready"]
        ),
    ]
    for cy in cycles:
        r = run(a, w, rec, stalls=True, reset_at=cy)
        assert r["status"] == "RESET"
        audit(r, a, w)


def test_trace_faults_rejected():
    import copy

    a, w, rec = fixture(5, 17, 4)
    r = run(a, w, rec, stalls=True)
    bad = copy.deepcopy(r)
    e = next(e for e in bad["events"] if e["responses"])
    e["responses"][0]["value"] ^= 1
    with pytest.raises(AssertionError, match="registered read"):
        audit(bad, a, w)
    bad = copy.deepcopy(r)
    i = next(
        i
        for i, e in enumerate(bad["events"])
        if e.get("out_valid") and not e["out_ready"]
    )
    bad["events"][i + 1]["out_head"] = (0, 0, 999)
    with pytest.raises(AssertionError, match="blocked output"):
        audit(bad, a, w)
