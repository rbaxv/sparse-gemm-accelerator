from model.comparison import predict
from model.row_serial import evaluate
from model.oracle import pack_record, decode


def test_ws_literal_wall_formula():
    p = predict(2, 2, 8, "ws", True)
    # command1 + eight host words + post-load51
    assert p["wall_edges"] == 60
    assert p["counts"] == dict(
        a_reads=4,
        w_reads=4,
        p_reads=4,
        p_writes=4,
        advances=12,
        host_words=8,
        outputs=4,
    )


def test_rs_pair_width_and_tail():
    a = [[-128] * 5 for _ in range(3)]
    rec = [[pack_record(0, -128, -128) for _ in range(4)] for _ in range(2)]
    w = decode(rec, 5, 4)
    s = evaluate(a, w, rec, True)
    d = evaluate(a, w, rec, False)
    assert s["result"] == d["result"] == [[49152] * 4 for _ in range(3)]
    assert any(p[3] == 32768 for e in s["trace"] for p in e.get("products", []))
    assert s["resources"]["multipliers_int8"] == 16


def test_model_service_never_improves_latency():
    for arch in ("native", "grouped", "ws"):
        assert (
            predict(7, 3, 17, arch, False, True)["wall_edges"]
            >= predict(7, 3, 17, arch, False, False)["wall_edges"]
        )
