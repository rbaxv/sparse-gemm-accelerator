import importlib.util, json, pathlib
import pytest

spec = importlib.util.spec_from_file_location(
    "vectors",
    pathlib.Path(__file__).resolve().parents[1] / "scripts/generate_sparse_vectors.py",
)
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


@pytest.fixture(scope="module")
def vectors(tmp_path_factory):
    d = tmp_path_factory.mktemp("sparse") / "vectors"
    v.generate(d)
    return json.loads((d / "jobs.json").read_text()), [
        list(map(lambda x: int(x, 16), l.split()))
        for l in (d / "cycles.txt").read_text().splitlines()
    ]


def test_matched_workloads(vectors):
    jobs, rows = vectors
    groups = {}
    for j in jobs:
        if j["complete"]:
            groups.setdefault(
                (
                    j["k"],
                    j["m"],
                    j["n"],
                    j["code"],
                    j["kind"],
                    j["stalled"],
                    j["ignore_bad"],
                ),
                {},
            )[j["mode"]] = j
    for modes in groups.values():
        assert (
            modes[0]["a"] == modes[1]["a"]
            and modes[0]["records"] == modes[1]["records"]
        )
        assert modes[0]["expected"] == modes[1]["expected"]


def test_literal_sparse_identity_packet_trace(vectors):
    jobs, rows = vectors
    j = jobs[0]
    t = rows[j["start"] - 1 : j["end"]]
    assert j["kind"] == "identity" and j["mode"] == 1
    assert [r[10] for r in t] == [
        1,
        1,
        1 + (3 << 64),
        1 + (2 << 32) + (3 << 64),
        1 + (2 << 32) + (3 << 64),
        1 + (2 << 32) + (3 << 64) + (4 << 96),
    ]
    # A packet [1,2,99,99] captured at PE00 then forwarded right at next slot.
    assert t[0][13] & 0xFFFFFFFF == 0x63630201
    assert (t[2][13] >> 32) & 0xFFFFFFFF == 0x63630201
    assert t[0][17] == 1 and t[2][17] == 6 and t[4][17] == 8
    assert [r[11] for r in t] == [1, 0, 1, 0, 1, 0]


def test_stall_state_frozen_and_reset_clears(vectors):
    _, rows = vectors
    for prev, row in zip(rows, rows[1:]):
        if not row[0] and not row[1] and not row[2]:
            assert row[10:] == prev[10:]
        if row[0] or row[1]:
            assert row[10:19] == [0] * 9


def test_maximum_sparse_bound(vectors):
    jobs, _ = vectors
    for j in jobs:
        if j["k"] == 8192:
            assert j["expected"] == [[67108864] * 2] * 2
