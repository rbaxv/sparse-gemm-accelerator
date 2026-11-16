"""Finite two-bank-set WS scheduling experiment; mathematical slab arithmetic.
This models buffer/port ownership and host timing, not PE register updates.
"""

from collections import deque
from model.comparison import available
from model.oracle import decode, unpack_record


def simulate(
    a,
    records,
    n,
    *,
    sparse=True,
    service=False,
    overlap=True,
    host_period=1,
    output_period=1,
    cancel_at=None,
    trace=False,
    max_cycles=1000000
):
    m, k = len(a), len(a[0])
    assert 1 <= m <= 16 and 1 <= n <= 4 and 1 <= k <= 8192
    assert all(len(x) == k for x in a)
    decode(records, k, n)  # Full format validation precedes this model's experiment.
    slabs = (k + 15) // 16
    buffers = [None, None] if overlap else [None]
    p = [[0] * n for _ in range(m)]
    seeds = {}
    ready = deque()
    log = []
    out = []
    host = None
    active = None
    nxt = 0
    committed = 0
    first = None
    next_command = 1
    drain = None
    queue = deque()
    issued = 0
    t = 0
    counts = dict(
        host_words=0, a_reads=0, w_reads=0, p_reads=0, p_writes=0, advances=0, outputs=0
    )

    def program(s):
        off = s * 16
        L = min(16, k - off)
        G = (L + 3) // 4
        yield ("clear", 0)
        for g in range(4):
            for state in ("preload_issue", "preload_capture", "preload"):
                yield state, g
        for slot in range(m + n + 2):
            yield "issue", slot
            yield "capture", slot
            for phase in range(2 if sparse else 4):
                yield "compute", (slot, phase)
            yield "commit", slot
        yield "release", 0

    while len(out) < m * n:
        t += 1
        if t > max_cycles:
            raise TimeoutError("bounded service starvation or schedule noncompletion")
        actions = []
        ports = set()

        def access(kind, bank, addr, op, b=None):
            assert 0 <= bank < 4 and 0 <= addr < (4 if kind == "W" else 16)
            key = (kind, b, bank)
            assert key not in ports, ("port conflict", t, key)
            ports.add(key)
            actions.append([kind, bank, addr, op, b])

        if cancel_at == t:
            buffers[:] = [None] * len(buffers)
            ready.clear()
            queue.clear()
            return dict(
                cancelled=True,
                cycles=t,
                outputs=out,
                trace=log,
                counts=counts,
                owners=buffers,
                pending=0,
            )
        # Consume only work ready at the beginning of this edge.
        if active is None and ready and ready[0][2] < t:
            b, s, _ = ready.popleft()
            assert s == committed
            assert buffers[b]["owner"] == "ready"
            buffers[b]["owner"] = "compute"
            gen = program(s)
            active = [b, s, gen, next(gen)]
        if (
            host is None
            and nxt < slabs
            and t >= next_command
            and (overlap or active is None and not ready)
        ):
            free = next((i for i, b in enumerate(buffers) if b is None), None)
            if free is not None:
                host = [free, nxt, "command", 0]
        if host is not None:
            b, s, state, index = host
            off = s * 16
            L = min(16, k - off)
            G = (L + 3) // 4
            if (
                state == "command"
                and available(t, "host", service)
                and t % host_period == 0
            ):
                assert buffers[b] is None
                buffers[b] = dict(owner="loading", slab=s, A={}, W={}, L=L, G=G)
                host[2] = "load"
                nxt += 1
                first = t if first is None else first
                actions.append(["command", s, b])
            elif (
                state == "load"
                and available(t, "host", service)
                and t % host_period == 0
            ):
                buf = buffers[b]
                assert buf["owner"] == "loading"
                if index < m * G:
                    i, g = divmod(index, G)
                    buf["A"][i, g] = a[i][off + 4 * g : off + min(4 * g + 4, L)]
                    access("A", i % 4, 4 * (i // 4) + g, "write", b)
                else:
                    g, c = divmod(index - m * G, n)
                    buf["W"][g, c] = records[off // 4 + g][c]
                    access("W", c, g, "write", b)
                host[3] += 1
                counts["host_words"] += 1
                if host[3] == (m + n) * G:
                    host[2] = "ready"
            elif state == "ready":
                buffers[b]["owner"] = "ready"
                ready.append((b, s, t))
                host = None
                actions.append(["ready", s, b])
        if active is not None:
            b, s, gen, (state, arg) = active
            buf = buffers[b]
            assert buf["owner"] == "compute" and buf["slab"] == s
            assert len(buf["A"]) == m * buf["G"] and len(buf["W"]) == buf["G"] * n
            if state != "compute" or available(t, "compute", service):
                actions.append([state, s, arg, b])
                if state == "preload_issue" and arg < buf["G"]:
                    for c in range(n):
                        access("W", c, arg, "read", b)
                        counts["w_reads"] += 1
                if state == "issue":
                    for g in range(buf["G"]):
                        i = arg - g
                        if 0 <= i < m:
                            access("A", i % 4, 4 * (i // 4) + g, "read", b)
                            counts["a_reads"] += 1
                    for c in range(n):
                        i = arg - c
                        if 0 <= i < m:
                            seeds[i, c] = (p[i][c] if s else 0, t)
                            if s:
                                access("P", c, i, "read")
                                counts["p_reads"] += 1
                if state == "compute":
                    counts["advances"] += 1
                if state == "commit":
                    for c in range(n):
                        i = arg - 3 - c
                        if 0 <= i < m:
                            seed, read_t = seeds[i, c]
                            assert read_t < t
                            value = seed
                            for g in range(buf["G"]):
                                code, v0, v1 = unpack_record(buf["W"][g, c])
                                from model.oracle import PAIRS

                                weights = dict(zip(PAIRS[code], (v0, v1)))
                                for z, av in enumerate(buf["A"][i, g]):
                                    value += av * weights.get(z, 0)
                            assert -(1 << 31) <= value < (1 << 31)
                            p[i][c] = value
                            access("P", c, i, "write")
                            counts["p_writes"] += 1
                if state == "release":
                    buffers[b] = None
                    committed += 1
                    active = None
                    if not overlap:
                        next_command = t + 2
                    if committed == slabs:
                        drain = t + 1
                else:
                    active[3] = next(gen)
            else:
                actions.append(["compute_wait", s, arg, b])
        if drain is not None and t >= drain:
            if (
                queue
                and queue[0][0] <= t
                and available(t, "output", service)
                and t % output_period == 0
            ):
                _, i, c, value = queue.popleft()
                out.append([i, c, value])
                counts["outputs"] += 1
                actions.append(["output", i, c, value])
            if issued < m * n and len(queue) < 2:
                i, c = divmod(issued, n)
                access("P", c, i, "read")
                counts["p_reads"] += 1
                queue.append((t + 2, i, c, p[i][c]))
                issued += 1
            assert len(queue) <= 2
        if trace:
            log.append(
                dict(
                    edge=t,
                    actions=actions,
                    output_queue=len(queue),
                    owners=[
                        None if b is None else [b["slab"], b["owner"]] for b in buffers
                    ],
                )
            )
    assert (
        committed == slabs
        and not ready
        and active is None
        and host is None
        and not queue
        and all(b is None for b in buffers)
    )
    return dict(
        cancelled=False,
        cycles=t - first + 1,
        epoch=t,
        outputs=out,
        counts=counts,
        trace=log,
        pending=0,
    )
