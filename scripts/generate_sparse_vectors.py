"""S-OS v2 vectors: direct coordinate arithmetic and packet provenance.

Packet expectations are functions of the last issued slot and (row,column),
not a model of RTL shifts. Control-only transitions have explicit expectations.
"""

import hashlib, json, pathlib, random, sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from model.sparse_schedule import events
from model.oracle import pack_record, decode, gemm, encode

FIELDS = [
    "rst",
    "clear",
    "advance",
    "mode",
    "ai",
    "wi",
    "tail",
    "code",
    "av",
    "wv",
    "sums",
    "phase",
    "error",
    "ap",
    "wp",
    "mp",
    "cp",
    "avp",
    "wvp",
    "latched_mode",
]


def pack(values, bits):
    return sum((v & ((1 << bits) - 1)) << (bits * i) for i, v in enumerate(values))


def generate(destination, dim=2):
    assert dim in (2, 4)
    S = dim
    d = pathlib.Path(destination)
    d.mkdir(parents=True, exist_ok=False)
    rows = []
    annotations = []
    jobs = []
    previous = [0] * 9 + [1]

    def emit(inputs, outputs, tags=(), job=-1, slot=-1, phase=-1):
        nonlocal previous
        assert len(inputs) == 10 and len(outputs) == 10
        rows.append(inputs + outputs)
        annotations.append(
            {
                "cycle": len(rows),
                "job": job,
                "slot": slot,
                "phase": phase,
                "tags": list(tags),
            }
        )
        previous = outputs[:]

    def empty(mode):
        return [0] * 9 + [mode]

    def clear(mode, rst=False, tags=()):
        emit(
            [int(rst), int(not rst), 0, mode, 0, 0, 0, 0, 0, 0],
            empty(1 if rst else mode),
            ["reset" if rst else "clear", *tags],
        )

    def job(
        mode,
        k,
        code,
        m=None,
        n=None,
        kind="random",
        stalled=False,
        cut=None,
        kill=None,
        ignore_bad=False,
    ):
        m = S if m is None else m
        n = S if n is None else n
        ident = len(jobs)
        rng = random.Random(20261105 + 100 * k + code)
        G = (k + 3) // 4
        P = 2 if mode else 4
        a = [[rng.randrange(-128, 128) for _ in range(k)] for _ in range(S)]
        rec = [
            [
                pack_record(
                    (code + g + c) % 6,
                    [-128, -7, 0, 19, 127][(code + g) % 5],
                    [-128, -7, 0, 19, 127][(code + g + 1) % 5],
                )
                for c in range(S)
            ]
            for g in range(G)
        ]
        if kind == "identity":
            a = [[r * S + i + 1 for i in range(S)] for r in range(S)]
            rec = encode([[int(r == c) for c in range(S)] for r in range(S)])
        if kind == "max":
            a = [[-128] * k for _ in range(S)]
            rec = [[pack_record(code, -128, -128)] * S for _ in range(G)]
        if kind == "positive":
            a = [[127] * k for _ in range(S)]
            rec = [[pack_record(code, 127, 127)] * S for _ in range(G)]
        if kind == "zero":
            a = [[0] * k for _ in range(S)]
            rec = [[pack_record(code, 0, 0)] * S for _ in range(G)]
        if kind == "cancel":
            a = [[1, -1, 1, -1][:k] for _ in range(S)]
            rec = [[pack_record(0, 127, 127)] * S]
        for r in range(m, S):
            a[r] = [0] * k
        for row in rec:
            for c in range(n, S):
                row[c] = pack_record(code, 0, 0)
        w = decode(rec, k, S)
        expected = gemm(a, w)
        clear(mode, tags=["job_start"])
        start = len(rows) + 1
        timeline = events(a, rec, k, S, bool(mode))

        # Boundary values at group g; zeros on invalid row/column lanes.
        def A(r, g):
            if r >= m or not 0 <= g < G:
                return (0, 0, 0)
            return (
                pack([a[r][4 * g + i] if 4 * g + i < k else 99 for i in range(4)], 8),
                sum(int(4 * g + i < k) << i for i in range(4)),
                1,
            )

        def W(c, g):
            if c >= n or not 0 <= g < G:
                return (0, 0, 0)
            record = rec[g][c]
            return (
                (
                    record & 65535
                    if mode
                    else pack(
                        [w[4 * g + i][c] if 4 * g + i < k else -77 for i in range(4)], 8
                    )
                ),
                record >> 16,
                1,
            )

        for tick, e in enumerate(timeline):
            if cut is not None and tick == cut:
                break
            s = e["slot"]
            p = e["phase"]
            ab = [A(r, s - r) for r in range(S)]
            wb = [W(c, s - c) for c in range(S)]
            inp = [
                0,
                0,
                1,
                1 - mode,
                pack([x[0] for x in ab], 32),
                pack([x[0] for x in wb], 32),
                pack([x[1] for x in ab], 4),
                pack([x[1] for x in wb], 3),
                pack([x[2] for x in ab], 1),
                pack([x[2] for x in wb], 1),
            ]
            # External mode deliberately changes after clear; latched mode must win.
            if ignore_bad:
                if not mode or p != 0:
                    inp[7] = pack([6 if c == 0 else 7 for c in range(S)], 3)
                else:
                    for c in range(1, S):
                        if not (inp[9] >> c) & 1:
                            inp[7] |= 7 << (3 * c)
            if p == 0:
                pa = [
                    A(r, s - r - c) if s >= c else (0, 0, 0)
                    for r in range(S)
                    for c in range(S)
                ]
                pw = [
                    W(c, s - r - c) if s >= r else (0, 0, 0)
                    for r in range(S)
                    for c in range(S)
                ]
                if ignore_bad and not mode:
                    # Metadata is ignored arithmetically in dense mode, but transported.
                    pw = [
                        (x[0], (6 if c == 0 else 7) if s >= r else 0, x[2])
                        for r in range(S)
                        for c in range(S)
                        for x in [pw[r * S + c]]
                    ]
                elif ignore_bad:
                    pw = [
                        (x[0], 7 if c > 0 and s >= r and not x[2] else x[1], x[2])
                        for r in range(S)
                        for c in range(S)
                        for x in [pw[r * S + c]]
                    ]
                packets = [
                    pack([x[0] for x in pa], 32),
                    pack([x[0] for x in pw], 32),
                    pack([x[1] for x in pa], 4),
                    pack([x[1] for x in pw], 3),
                    pack([x[2] for x in pa], 1),
                    pack([x[2] for x in pw], 1),
                ]
            else:
                packets = previous[3:9]
            out = [pack(sum(e["sums"], []), 32), (p + 1) % P, 0, *packets, mode]
            if stalled and (tick % 3 == 0 or p == P - 1):
                # Poison stalled pins, including illegal metadata; state must freeze.
                for _ in range(3 if tick % 3 == 0 else 1):
                    stalled_in = [
                        0,
                        0,
                        0,
                        1 - mode,
                        rng.getrandbits(S * 32),
                        rng.getrandbits(S * 32),
                        (1 << (S * 4)) - 1,
                        (1 << (S * 3)) - 1,
                        (1 << S) - 1,
                        (1 << S) - 1,
                    ]
                    emit(
                        stalled_in,
                        previous,
                        ["stall", f"stall_mode{mode}_phase{p}"],
                        ident,
                        s,
                        p,
                    )
            emit(inp, out, ["compute", "mode_change_ignored"], ident, s, p)
        end = len(rows)
        record = {
            "id": ident,
            "mode": mode,
            "k": k,
            "m": m,
            "n": n,
            "code": code,
            "kind": kind,
            "stalled": stalled,
            "ignore_bad": ignore_bad,
            "start": start,
            "end": end,
            "complete": cut is None,
            "enabled_edges": (
                min(cut, len(timeline)) if cut is not None else len(timeline)
            ),
            "predicted_edges": P * (G + 2 * S - 2),
            "expected": expected,
            "a": a,
            "records": rec,
        }
        jobs.append(record)
        if cut is None:
            assert previous[0] == pack(sum(expected, []), 32)
        if kill:
            had_packets = previous[7] != 0 or previous[8] != 0
            assert had_packets
            clear(
                mode,
                rst=kill == "reset",
                tags=[kill + "_inflight", f"{kill}_mode{mode}_phase{previous[1]}"],
            )
            actual_mode = previous[-1]
            p = 0
            for _ in range(8):
                p = (p + 1) % (2 if actual_mode else 4)
                emit(
                    [0, 0, 1, 1 - actual_mode, 0, 0, 0, 0, 0, 0],
                    [0, p, 0, 0, 0, 0, 0, 0, 0, actual_mode],
                    ["flush_after_" + kill],
                )

    clear(1, rst=True)
    for mode in (1, 0):
        job(mode, S, 0, kind="identity")
        for k in (1, 2, 3, 4, 7, 16, 67):
            for code in range(6):
                for stalled in (False, True):
                    job(mode, k, code, stalled=stalled)
        for m, n in [
            (m, n) for m in range(1, S + 1) for n in range(1, S + 1) if (m, n) != (S, S)
        ]:
            for code in range(6):
                job(mode, 7, code, m, n, stalled=True)
        for kind in ("max", "positive", "zero", "cancel"):
            job(mode, 4, 0, kind=kind, stalled=True)
        job(mode, 8192, 0, kind="max")
        job(mode, 7, 3, stalled=True, ignore_bad=True)
        for cut in range(1, (2 if mode else 4) + 1):
            for kill in ("reset", "clear"):
                job(mode, 16, 2, cut=cut, kill=kill)
    # Rejected context after partial work: both codes, both boundary columns.
    for code in (6, 7):
        for column in range(S):
            job(1, 16, 0, cut=2)
            inp = [
                0,
                0,
                1,
                0,
                0,
                0,
                (1 << (S * 4)) - 1,
                code << (3 * column),
                (1 << S) - 1,
                1 << column,
            ]
            emit(
                inp, [0, 0, 1, 0, 0, 0, 0, 0, 0, 1], [f"illegal_{code}_column{column}"]
            )
            for adv in (0, 1, 1):
                emit(
                    [
                        0,
                        0,
                        adv,
                        0,
                        2 ** (S * 32) - 1,
                        2 ** (S * 32) - 1,
                        (1 << (S * 4)) - 1,
                        0,
                        (1 << S) - 1,
                        (1 << S) - 1,
                    ],
                    previous,
                    ["sticky_error"],
                )
            clear(0, tags=["error_recovery_clear"])
            emit(
                [0, 0, 1, 1, 0, 0, 0, 0, 0, 0],
                [0, 1, 0, 0, 0, 0, 0, 0, 0, 0],
                ["recovered"],
            )
    # Separate error reset recovery.
    clear(1)
    emit(
        [0, 0, 1, 1, 0, 0, 0, 6, 0, 1],
        [0, 0, 1, 0, 0, 0, 0, 0, 0, 1],
        ["illegal_zero_activation"],
    )
    clear(0, rst=True, tags=["error_recovery_reset"])
    raw = "\n".join(" ".join(format(v, "x") for v in row) for row in rows) + "\n"
    (d / "cycles.txt").write_text(raw)
    (d / "annotations.json").write_text(json.dumps(annotations))
    (d / "jobs.json").write_text(json.dumps(jobs))
    (d / "manifest.json").write_text(
        json.dumps(
            {
                "schema": "sparse-core-v3",
                "dim": S,
                "fields": FIELDS,
                "seed": 20261105,
                "cycles": len(rows),
                "jobs": len(jobs),
                "sha256": hashlib.sha256(raw.encode()).hexdigest(),
            },
            indent=2,
        )
        + "\n"
    )
    return len(rows)


if __name__ == "__main__":
    print(generate(sys.argv[1]))
