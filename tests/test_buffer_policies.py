import pytest
from model.buffered_os import run
from model.audit_buffered import audit
from model.oracle import pack_record, decode

SERVICE = {
    "host": [False, True, True, False, True],
    "compute": [True, False, True],
    "output": [False, False, True, True],
}


@pytest.mark.parametrize("m,k,n", [(1, 1, 1), (4, 16, 4), (5, 17, 3), (16, 33, 4)])
@pytest.mark.parametrize("service", [None, SERVICE])
def test_reuse_and_common_service(m, k, n, service):
    a = [[(r + t) % 255 - 128 for t in range(k)] for r in range(m)]
    rec = [
        [pack_record((g + c) % 6, -128, 127) for c in range(n)]
        for g in range((k + 3) // 4)
    ]
    w = decode(rec, k, n)
    outputs = []
    reads = []
    for mode, reuse in [
        ("sparse", False),
        ("grouped_dense", False),
        ("native_dense", False),
        ("native_dense", True),
    ]:
        x = run(a, w, rec, mode, reuse_words=reuse, service=service)
        audit(x, a, w)
        outputs.append(x["output"])
        assert x == run(a, w, rec, mode, reuse_words=reuse, service=service)
        reads.append(
            sum(
                q["op"] == "read" and q["space"] in ("A", "W")
                for e in x["events"]
                for q in e["requests"]
            )
        )
        if service:
            for e in x["events"]:
                t = e["cycle"] - 1
                if e.get("host_valid"):
                    assert e["host_ready"] == service["host"][t % len(service["host"])]
                if e["phase"] == "compute":
                    assert (
                        e["advance"] == service["compute"][t % len(service["compute"])]
                    )
                if e["phase"] == "drain":
                    assert (
                        e["out_ready"] == service["output"][t % len(service["output"])]
                    )
    assert all(o == outputs[0] for o in outputs)
    assert reads[3] <= reads[2] and reads[3] == reads[0]
    if k > 4:
        assert reads[3] < reads[2]


def test_nonprogressing_service_rejected():
    with pytest.raises(AssertionError):
        run(
            [[1]],
            [[1]],
            [[1]],
            service={"host": [False], "compute": [True], "output": [True]},
        )
