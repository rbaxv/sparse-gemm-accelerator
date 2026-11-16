"""Independent trace checks: mathematical products, bank service and protocol."""

from model.oracle import gemm


def audit(result, a, w):
    events = result["events"]
    M, K, N = result["shape"]
    expected = gemm(a, w)
    memory = {}
    pending = []
    held = None
    host_held = None
    validated = set()
    committed = {}
    partial = {}
    bins = set()
    last_slab = -1
    for i, e in enumerate(events, 1):
        assert e["cycle"] == i
        if e["phase"] == "reset":
            assert i == len(events) and result["status"] == "RESET"
            bins.add("reset")
            break
        assert e["responses"] == pending, "registered read response mismatch"
        pending = []
        used = set()
        slab = e["slab"]
        phase = e["phase"]
        if phase == "validated":
            validated.add(slab)
        if slab != last_slab:
            if slab > 0:
                assert all(
                    committed.get((r, c)) == slab - 1
                    for r in range(M)
                    for c in range(N)
                ), "slab overwritten before commit"
            last_slab = slab
        for q in e["requests"]:
            space, b, addr = q["space"], q["bank"], q["addr"]
            key = (space, b, addr)
            assert (space, b) not in used
            used.add((space, b))
            assert 0 <= b < 4 and 0 <= addr < ({"A": 16, "W": 4, "P": 16}[space])
            bins.add("bank/" + space + "/" + q["op"])
            if space in ("A", "W") and q["op"] == "write":
                assert phase == "load" and slab not in validated
            if q["op"] == "read":
                assert key in memory
                pending.append(
                    {"space": space, "bank": b, "addr": addr, "value": memory[key]}
                )
            else:
                if space == "P":
                    assert phase == "psum_commit"
                    want = sum(
                        a[addr][k] * w[k][b] for k in range(min((slab + 1) * 16, K))
                    )
                    assert q["value"] == want, "PSUM commit mismatch"
                    committed[addr, b] = slab
                memory[key] = q["value"]
        if e.get("host_valid"):
            if host_held is not None:
                assert e["host"] == host_held
            host_held = e["host"] if not e["host_ready"] else None
            if not e["host_ready"]:
                bins.add("host_stall")
        if phase == "compute":
            assert slab in validated
            if e["advance"]:
                for p in e["products"]:
                    r, c, k = p["r"], p["c"], p["k"]
                    assert p["a"] == a[r][k] and p["w"] == w[k][c], "operand alignment"
                    assert p["product"] == a[r][k] * w[k][c], "product mismatch"
                    key = (slab, r, c, k)
                    assert key not in partial, "duplicate product"
                    partial[key] = p["product"]
            else:
                bins.add("compute_stall")
        if phase == "drain":
            assert all(
                committed.get((r, c)) == (K - 1) // 16
                for r in range(M)
                for c in range(N)
            )
            if held is not None:
                assert (
                    e["out_valid"] and tuple(e["out_head"]) == held
                ), "blocked output changed"
            held = (
                tuple(e["out_head"]) if e["out_valid"] and not e["out_ready"] else None
            )
            if held is not None:
                bins.add("output_stall")
            assert e["queue_occupancy"] + e["reserved"] <= 2
            if e["accepted"] is not None:
                assert (
                    e["out_valid"] and e["out_ready"] and e["accepted"] == e["out_head"]
                )
                r, c, v = e["accepted"]
                assert v == expected[r][c]
    if result["status"] == "PASS":
        assert not pending and held is None and host_held is None
        assert result["output"] == [
            (r, c, expected[r][c]) for r in range(M) for c in range(N)
        ]
        for slab, k0 in enumerate(range(0, K, 16)):
            L = min(16, K - k0)
            mode = result["mode"]
            edges = (
                (L + 6)
                if mode == "native_dense"
                else (2 if mode == "sparse" else 4) * ((L + 3) // 4 + 6)
            )
            for tile in range(0, M, 4):
                assert (
                    sum(
                        e["phase"] == "compute"
                        and e.get("advance", False)
                        and e["slab"] == slab
                        and e["tile"] == tile
                        for e in events
                    )
                    == edges
                )
        bins.add("complete")
    if result["status"] == "REJECTED":
        assert not any(
            e["phase"] == "compute" and e["slab"] == events[-1]["slab"] for e in events
        )
        assert result["output"] == []
        bins.add("rejected")
    return sorted(bins)
