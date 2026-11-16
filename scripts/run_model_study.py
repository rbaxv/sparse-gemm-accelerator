"""Bounded full-factorial WS model study; no physical estimates."""

import sys, pathlib, json, datetime, hashlib, itertools, traceback

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from model.ws_optimization import simulate

(ROOT / "results").mkdir(exist_ok=True)
r = (
    ROOT
    / "results"
    / (
        "g6-ws-study-"
        + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    )
)
r.mkdir()
print(r, flush=True)
paths = [
    "model/ws_optimization.py",
    "scripts/run_model_study.py",
    "model/oracle.py",
    "model/comparison.py",
    "datasets/study_vectors.json",
    "datasets/baseline_measurements.json",
]
m = dict(
    status="RUNNING",
    command="python scripts/run_model_study.py",
    python=sys.version,
    hashes={p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in paths},
)
(r / "manifest.json").write_text(json.dumps(m, indent=2))
out = []
try:
    vectors = json.loads((ROOT / paths[-2]).read_text())
    base = json.loads((ROOT / paths[-1]).read_text())
    base = {(v["mode"], v["service"], v["block"]): v for v in base}
    for index, v in enumerate(vectors):
        b = base[v["mode"], v["service"], v["block"]]
        n = b["shape"][2]
        for ov, pack, tk, bank in itertools.product(
            [False, True], [False, True], [4, 8, 16], ["row", "group"]
        ):
            x = simulate(
                v["a"],
                v["records"],
                n,
                sparse=v["mode"] == "ws_sparse",
                service=v["service"],
                overlap=ov,
                packed=pack,
                tk=tk,
                mapping=bank,
            )
            assert x["outputs"] == v["expected"]
            if not ov and not pack and tk == 16 and bank == "row":
                assert x["cycles"] == b["wall_edges"] and x["counts"] == b["counts"]
            out.append(
                dict(
                    block=v["block"],
                    mode=v["mode"],
                    service=v["service"],
                    shape=b["shape"],
                    overlap=ov,
                    packed=pack,
                    tk=tk,
                    bank=bank,
                    cycles=x["cycles"],
                    baseline=b["wall_edges"],
                    counts=x["counts"],
                )
            )
        if index % 20 == 0:
            print("Completed workload", index, flush=True)
    (r / "comparisons.json").write_text(json.dumps(out))
    m.update(
        status="PASS_MODEL_ONLY",
        executions=len(out),
        baseline_reconciliations=len(vectors),
    )
except Exception:
    m.update(status="FAILED", failure=traceback.format_exc())
    print(m["failure"])
for p in paths[:4]:
    dest = r / "source" / p
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes((ROOT / p).read_bytes())
(r / "manifest.json").write_text(json.dumps(m, indent=2))
print(m["status"], flush=True)
if m["status"] == "FAILED":
    sys.exit(1)
