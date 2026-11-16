"""Finite transaction timing from mathematical schedules and service availability."""

from collections import deque


def available(t, kind, service):
    return (
        not service
        or {"host": t % 5 < 3, "compute": t % 7 < 5, "output": t % 11 >= 4}[kind]
    )


def predict(m, n, k, arch, sparse, service=False):
    assert 1 <= m <= 16 and 1 <= n <= 4 and 1 <= k <= 8192
    t = 0
    states = {}
    counts = dict(
        a_reads=0,
        w_reads=0,
        p_reads=0,
        p_writes=0,
        advances=0,
        host_words=0,
        outputs=m * n,
    )

    def edge(state, gate=None):
        nonlocal t
        t += 1
        states[state] = states.get(state, 0) + 1
        if gate:
            while not available(t, gate, service):
                t += 1
                states[state] = states.get(state, 0) + 1

    # First accepted command, allowing the shared epoch's initial service delay.
    edge("command", "host")
    start = t
    for off in range(0, k, 16):
        L = min(16, k - off)
        G = (L + 3) // 4
        P = 2 if sparse else 4
        for _ in range((m + n) * G):
            edge("load", "host")
            counts["host_words"] += 1
        edge("ready")
        if arch == "ws":
            edge("clear")
            for g in range(4):
                edge("preload_issue")
                edge("preload_capture")
                edge("preload")
                if g < G:
                    counts["w_reads"] += n
            for slot in range(m + n + 2):
                edge("issue")
                edge("capture")
                counts["a_reads"] += sum(0 <= slot - g < m for g in range(G))
                if off:
                    counts["p_reads"] += sum(0 <= slot - c < m for c in range(n))
                for _ in range(P):
                    edge("compute", "compute")
                    counts["advances"] += 1
                edge("commit")
                counts["p_writes"] += sum(0 <= slot - 3 - c < m for c in range(n))
        else:
            native = arch == "native"
            rs = arch == "rs"
            P = 1 if native else ((1 if sparse else 2) if rs else P)
            height = 2 if rs else 4
            for tile in range(0, m, height):
                edge("clear")
                at = {}
                wt = {}
                for slot in range((L if native else G) + (0 if rs else 6)):
                    edge("issue")
                    reads = 0
                    for b in range(4):
                        index = slot if rs else slot - b
                        g = index // 4 if native else index
                        if 0 <= index < (L if native else G):
                            if (
                                b < height
                                and tile + b < m
                                and (not native or at.get(b) != g)
                            ):
                                counts["a_reads"] += 1
                                reads += 1
                                at[b] = g
                            if b < n and (not native or wt.get(b) != g):
                                counts["w_reads"] += 1
                                reads += 1
                                wt[b] = g
                    if reads:
                        edge("capture")
                    for _ in range(P):
                        edge("compute", "compute")
                        counts["advances"] += 1
                for rr in range(tile, min(tile + height, m)):
                    edge("merge_prep")
                    if off:
                        edge("prior_read")
                        edge("prior_wait")
                        counts["p_reads"] += n
                    edge("commit")
                    counts["p_writes"] += n
        edge("release")
        if off + L == k:
            # Read at t, queue-resident at t+1, first consumable at t+2.
            pending = deque()
            issued = 0
            accepted = 0
            while accepted < m * n:
                edge("drain")
                if pending and pending[0] <= t and available(t, "output", service):
                    pending.popleft()
                    accepted += 1
                if issued < m * n and len(pending) < 2:
                    pending.append(t + 2)
                    issued += 1
                    counts["p_reads"] += 1
        else:
            edge("driver_gap")
            edge("command", "host")
    return dict(wall_edges=t - start + 1, epoch_edges=t, counts=counts, states=states)
