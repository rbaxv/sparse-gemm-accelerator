"""Finite-bank WS top-injection schedule. Bank service serialized around compute."""

from model.buffered_os import Banks, request, word
from model.ws_schedule import events
from model.oracle import gemm, unpack_record


def schedule(a, w, records, sparse=True):
    M = len(a)
    K = len(w)
    N = len(w[0])
    assert 1 <= M <= 16 and 1 <= N <= 4 and 1 <= K <= 8192
    bank = Banks()
    trace = []
    cycle = 0

    def tick(phase, requests=(), **extra):
        nonlocal cycle
        cycle += 1
        responses = bank.edge(cycle, requests)
        trace.append(
            {
                "cycle": cycle,
                "phase": phase,
                "requests": list(requests),
                "responses": responses,
                **extra,
            }
        )
        return responses

    def read(req):
        tick("read_issue", req)
        return tick("read_response")

    for off in range(0, K, 16):
        L = min(16, K - off)
        G = (L + 3) // 4
        rec = records[off // 4 : (off + L + 3) // 4]
        for r in range(M):
            for g in range(G):
                tick(
                    "load",
                    [
                        request(
                            "A",
                            r % 4,
                            4 * (r // 4) + g,
                            word(a[r][off + 4 * g : min(off + 4 * g + 4, K)]),
                        )
                    ],
                )
        for c in range(N):
            for g in range(G):
                v = (
                    rec[g][c]
                    if sparse
                    else word(
                        [w[t][c] for t in range(off + 4 * g, min(off + 4 * g + 4, K))]
                    )
                )
                tick("load", [request("W", c, g, v)])
        for g in range(4):
            if g < G:
                response = read([request("W", c, g) for c in range(N)])
                if sparse:
                    for q in response:
                        unpack_record(q["value"])
            tick("preload", group=g, valid=g < G)
        seeds = (
            [[0] * N for _ in range(M)]
            if off == 0
            else [[bank.mem["P"][c][r] for c in range(N)] for r in range(M)]
        )
        assert all(v is not None for row in seeds for v in row)
        ticks = list(
            events([row[off : off + L] for row in a], rec, L, N, 4, sparse, seeds)
        )
        P = 2 if sparse else 4
        for slot in range(M + 4 + N - 2):
            req = []
            for g in range(G):
                row = slot - g
                if 0 <= row < M:
                    req.append(request("A", row % 4, 4 * (row // 4) + g))
            if off:
                for c in range(N):
                    row = slot - c
                    if 0 <= row < M:
                        req.append(request("P", c, row))
            if req:
                response = read(req)
                for q in response:
                    if q["space"] == "P":
                        assert q["value"] == seeds[q["addr"]][q["bank"]]
                    else:
                        row = 4 * (q["addr"] // 4) + q["bank"]
                        g = q["addr"] % 4
                        assert q["value"] == word(
                            a[row][off + 4 * g : min(off + 4 * g + 4, K)]
                        )
            for p in range(P):
                e = ticks[slot * P + p]
                tick(
                    "compute",
                    slot=slot,
                    subphase=p,
                    identity=e["identity"],
                    sums=e["sums"],
                )
            req = []
            for c in range(N):
                row = slot - 3 - c
                if 0 <= row < M:
                    value = e["sums"][3][c]
                    assert value == sum(a[row][t] * w[t][c] for t in range(off + L))
                    req.append(request("P", c, row, value))
            if req:
                tick("commit", req)
    actual = [[bank.mem["P"][c][r] for c in range(N)] for r in range(M)]
    assert actual == gemm(a, w)
    return {"cycles": cycle, "trace": trace, "result": actual}
