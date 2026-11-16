"""Finite single-port banks and conservative slab-major OS service schedule."""

from collections import deque
from model.oracle import integer, unpack_record, PAIRS


class ResetContext(Exception):
    pass


class RejectedContext(ValueError):
    pass


class Banks:
    def __init__(self):
        self.mem = {
            k: [[None] * depth for _ in range(4)]
            for k, depth in [("A", 16), ("W", 4), ("P", 16)]
        }
        self.pending = []

    def edge(self, cycle, requests):
        response = []
        for due, key, bank, addr, value in self.pending:
            assert due == cycle
            response.append({"space": key, "bank": bank, "addr": addr, "value": value})
        self.pending = []
        used = set()
        for q in requests:
            key, b, addr = q["space"], q["bank"], q["addr"]
            assert (key, b) not in used, "bank conflict"
            used.add((key, b))
            assert (
                key in self.mem and 0 <= b < 4 and 0 <= addr < len(self.mem[key][b])
            ), "bank capacity"
            if q["op"] == "write":
                self.mem[key][b][addr] = q["value"]
            else:
                assert q["op"] == "read"
                v = self.mem[key][b][addr]
                assert v is not None, "uninitialized bank read"
                self.pending.append((cycle + 1, key, b, addr, v))
        return response


def word(values):
    return sum((x & 255) << (8 * i) for i, x in enumerate(values))


def signed(x):
    return x - 256 if x >= 128 else x


def request(space, bank, addr, value=None):
    q = {
        "space": space,
        "bank": bank,
        "addr": addr,
        "op": "read" if value is None else "write",
    }
    if value is not None:
        q["value"] = value
    return q


def run(
    a,
    w,
    records,
    mode="sparse",
    seed=1,
    stalls=False,
    reset_at=None,
    fault=None,
    corrupt=None,
    reuse_words=False,
    service=None,
):
    """Inputs already pruned; caller/oracle independently verifies mathematical result.
    corrupt=(slab,group,column,word) mutates incoming sparse host data.
    """
    import random

    rng = random.Random(seed)
    M = len(a)
    K = len(w)
    N = len(w[0]) if w else 0
    integer(M, 1, 16)
    integer(N, 1, 4)
    integer(K, 1, 8192)
    assert mode in ("sparse", "grouped_dense", "native_dense")
    if reuse_words:
        assert mode == "native_dense"
    if service is not None:
        assert set(service) == {"host", "compute", "output"}
        assert all(
            v and all(type(b) is bool for b in v) and any(v) for v in service.values()
        )

    def allowed(channel):
        # Edge numbering starts at 1; availability is exogenous and periodic.
        return service[channel][cycle % len(service[channel])]

    assert all(len(r) == K for r in a) and all(len(r) == N for r in w)
    assert len(records) == (K + 3) // 4 and all(len(r) == N for r in records)
    for row in a + w:
        for v in row:
            integer(v, -128, 127)
    bank = Banks()
    events = []
    cycle = 0
    phase = "idle"
    slab = -1
    output = []
    counts = {}
    committed = set()

    def tick(req=(), **fields):
        nonlocal cycle
        cycle += 1
        if cycle == reset_at:
            bank.pending = []
            bank.mem = {
                k: [[None] * len(v[0]) for _ in range(4)] for k, v in bank.mem.items()
            }
            events.append(
                {
                    "cycle": cycle,
                    "phase": "reset",
                    "slab": slab,
                    "requests": [],
                    "responses": [],
                }
            )
            raise ResetContext()
        response = bank.edge(cycle, list(req))
        e = {
            "cycle": cycle,
            "phase": phase,
            "slab": slab,
            "requests": list(req),
            "responses": response,
            **fields,
        }
        events.append(e)
        counts[phase] = counts.get(phase, 0) + 1
        return response

    def read(req):
        tick(req)
        return tick()

    def transfer(q):
        # Valid data held unchanged until ready; deterministic stalls are replayable.
        while (
            not allowed("host")
            if service is not None
            else stalls and rng.randrange(4) == 0
        ):
            tick(host_valid=True, host_ready=False, host=q)
        tick([q], host_valid=True, host_ready=True, host=q)

    try:
        for slab, k0 in enumerate(range(0, K, 16)):
            L = min(16, K - k0)
            G = (L + 3) // 4
            phase = "load"
            loads = []
            for r in range(M):
                for g in range(G):
                    loads.append(
                        request(
                            "A",
                            r % 4,
                            4 * (r // 4) + g,
                            word(a[r][k0 + 4 * g : min(k0 + 4 * g + 4, K)]),
                        )
                    )
            invalid = None
            for c in range(N):
                for g in range(G):
                    v = (
                        records[k0 // 4 + g][c]
                        if mode == "sparse"
                        else word(
                            [w[k][c] for k in range(k0 + 4 * g, min(k0 + 4 * g + 4, K))]
                        )
                    )
                    if corrupt and (slab, g, c) == corrupt[:3]:
                        v = corrupt[3]
                    try:
                        integer(v, 0, 2**32 - 1)
                        if mode == "sparse":
                            unpack_record(v)
                    except ValueError as exc:
                        invalid = str(exc)
                    loads.append(request("W", c, g, v))
            # Detect on load completion; no computation can observe a partly validated slab.
            for q in loads:
                transfer(q)
            if invalid:
                raise RejectedContext(invalid)
            phase = "validated"
            tick()
            for base in range(0, M, 4):
                R = min(4, M - base)
                sums = [[0] * N for _ in range(R)]
                history_a = {}
                history_w = {}
                cache = {}
                sparse = mode == "sparse"
                grouped = mode != "native_dense"
                P = 2 if sparse else 4 if grouped else 1
                slots = (G if grouped else L) + 6
                for s in range(slots):
                    req = []
                    for r in range(R):
                        index = s - r
                        g = index if grouped else index // 4
                        if 0 <= index < (G if grouped else L):
                            req.append(
                                request("A", (base + r) % 4, 4 * ((base + r) // 4) + g)
                            )
                    for c in range(N):
                        index = s - c
                        g = index if grouped else index // 4
                        if 0 <= index < (G if grouped else L):
                            req.append(request("W", c, g))
                    hits = {}
                    if reuse_words:
                        missing = []
                        for q in req:
                            entry = cache.get((q["space"], q["bank"]))
                            if entry is not None and entry[0] == q["addr"]:
                                hits[q["space"], q["bank"], q["addr"]] = entry[1]
                            else:
                                missing.append(q)
                        req = missing
                    phase = "operand_read"
                    responses = read(req) if req else []
                    values = {
                        (q["space"], q["bank"], q["addr"]): q["value"]
                        for q in responses
                    }
                    if reuse_words:
                        for q in responses:
                            cache[q["space"], q["bank"]] = (q["addr"], q["value"])
                        assert len(cache) <= 8
                        values.update(hits)
                    for r in range(R):
                        index = s - r
                        g = index if grouped else index // 4
                        history_a[r, s] = (
                            values.get(
                                ("A", (base + r) % 4, 4 * ((base + r) // 4) + g), 0
                            )
                            if 0 <= index < (G if grouped else L)
                            else 0
                        )
                    for c in range(N):
                        index = s - c
                        g = index if grouped else index // 4
                        history_w[c, s] = (
                            values.get(("W", c, g), 0)
                            if 0 <= index < (G if grouped else L)
                            else 0
                        )
                    phase = "compute"
                    for p in range(P):
                        while (
                            not allowed("compute")
                            if service is not None
                            else stalls and rng.randrange(5) == 0
                        ):
                            tick(advance=False, tile=base, slot=s, subphase=p)
                        products = []
                        for r in range(R):
                            for c in range(N):
                                index = s - r - c
                                if not 0 <= index < (G if grouped else L):
                                    continue
                                aa = history_a[r, s - c]
                                ww = history_w[c, s - r]
                                if sparse:
                                    code, v0, v1 = unpack_record(ww)
                                    pos = PAIRS[code][p]
                                    v = (v0, v1)[p]
                                    kk = index * 4 + pos
                                else:
                                    pos = p if grouped else index % 4
                                    v = signed((ww >> (8 * pos)) & 255)
                                    kk = index * 4 + pos if grouped else index
                                av = signed((aa >> (8 * pos)) & 255)
                                if kk < L:
                                    product = av * v
                                    if (
                                        fault == "drop_last"
                                        and r == R - 1
                                        and c == N - 1
                                    ):
                                        product = 0
                                    sums[r][c] += product
                                    products.append(
                                        {
                                            "r": base + r,
                                            "c": c,
                                            "k": k0 + kk,
                                            "a": av,
                                            "w": v,
                                            "product": product,
                                        }
                                    )
                        tick(
                            advance=True,
                            tile=base,
                            slot=s,
                            subphase=p,
                            products=products,
                        )
                for r in range(R):
                    row = base + r
                    phase = "psum_read"
                    if slab:
                        assert all(
                            (row, c) in committed for c in range(N)
                        ), "uncommitted continuation"
                        response = read([request("P", c, row) for c in range(N)])
                        old = {q["bank"]: q["value"] for q in response}
                    else:
                        old = {c: 0 for c in range(N)}
                    phase = "psum_commit"
                    tick([request("P", c, row, old[c] + sums[r][c]) for c in range(N)])
                    committed.update((row, c) for c in range(N))
        phase = "drain"
        queue = deque()
        pending = None
        cursor = 0
        while cursor < M * N or queue or pending:
            ready = (
                allowed("output")
                if service is not None
                else not stalls or rng.randrange(3) != 0
            )
            head = queue[0] if queue else None
            accepted = head if head is not None and ready else None
            if accepted is not None:
                output.append(accepted)
                queue.popleft()
            # Pending read reserves an entry even before its response arrives.
            req = []
            new_pending = None
            if cursor < M * N and len(queue) + (pending is not None) < 2:
                row, c = divmod(cursor, N)
                req = [request("P", c, row)]
                new_pending = (row, c)
                cursor += 1
            response = tick(
                req,
                out_valid=head is not None,
                out_ready=ready,
                out_head=head,
                accepted=accepted,
                queue_occupancy=len(queue),
                reserved=pending is not None,
            )
            if pending:
                assert len(response) == 1
                queue.append((*pending, response[0]["value"]))
            else:
                assert not response
            pending = new_pending
            assert len(queue) + (pending is not None) <= 2
        status = "PASS"
    except ResetContext:
        status = "RESET"
    except RejectedContext as exc:
        phase = "reject"
        tick(reason=str(exc))
        status = "REJECTED"
    return {
        "status": status,
        "mode": mode,
        "seed": seed,
        "cycles": cycle,
        "counts": counts,
        "output": output,
        "events": events,
        "shape": [M, K, N],
    }
