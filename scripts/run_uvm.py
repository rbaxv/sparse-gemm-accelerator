"""Build one selected integrated candidate, then strict bounded UVM closure."""

import pathlib, datetime, json, hashlib, subprocess, sys, csv, traceback, os

ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from check_simulation import passed

(ROOT / "results").mkdir(exist_ok=True)
r = (
    ROOT
    / "results"
    / (
        "g6-integrated-uvm-gate-"
        + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    )
)
r.mkdir()
print(r, flush=True)
files = [
    "rtl/ws_integrated/ws_integrated.sv",
    "rtl/ws_integrated/packed_slab_loader.sv",
    "rtl/wrapper/slab_loader.sv",
    "rtl/sparse_ws/sparse_ws.sv",
    "verification/uvm/ws_integrated_tb.sv",
    "scripts/run_uvm.py",
    "scripts/check_simulation.py",
]
m = dict(
    status="RUNNING",
    sources={},
    commands=[],
    tests=[],
    versions={
        t: subprocess.getoutput(t + " --version") for t in ["verilator", "yosys"]
    },
)


def save():
    (r / "manifest.json").write_text(json.dumps(m, indent=2))


def call(cmd, log, cwd=ROOT):
    m["commands"].append(cmd)
    save()
    with log.open("w") as f:
        return subprocess.call(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT)


for f in files:
    p = r / "source" / f
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes((ROOT / f).read_bytes())
    m["sources"][f] = hashlib.sha256(p.read_bytes()).hexdigest()
lib = pathlib.Path(os.environ["UVM_HOME"]).resolve() / "src"
assert (lib / "uvm_pkg.sv").is_file(), "UVM_HOME must contain src/uvm_pkg.sv"
cmd = [
    "verilator",
    "--binary",
    "--timing",
    "--vpi",
    "--assert",
    "--output-groups",
    "0",
    "-j",
    "1",
    "-Wno-fatal",
    "--top-module",
    "tb",
    "--Mdir",
    str(r / "build"),
    "+incdir+" + str(lib),
    str(lib / "uvm_pkg.sv"),
    *[str(r / "source" / f) for f in files[:5]],
    str(lib / "dpi/uvm_dpi.cc"),
    "-CFLAGS",
    "-O0 -I" + str(lib / "dpi"),
    "-MAKEFLAGS",
    "OPT_FAST=-O0 OPT_SLOW=-O0",
]
try:
    assert call(cmd, r / "build.log") == 0, "build failed"
    required = (
        list(range(18))
        + list(range(32, 48))
        + list(range(128, 320))
        + list(range(64, 73))
        + [80, 83, 84]
        + list(range(90, 94))
    )
    for name, args in [
        ("stalled", []),
        ("nostall", ["+NOSTALL"]),
        ("replay", []),
        ("mutation", ["+MUTATE"]),
    ]:
        d = r / name
        d.mkdir()
        rc = call([str(r / "build/Vtb"), *args], d / "simulation.log", d)
        log = (d / "simulation.log").read_text()
        good = passed(log, rc, "[INTEGRATED_PASS]")
        if name == "mutation":
            assert not good and "[INTENT_ALL]" in log, "wrong mutation failure reason"
        else:
            assert good, name + " strict verdict failed"
            cov = {
                int(x["bin"]): x for x in csv.DictReader((d / "coverage.csv").open())
            }
            # Nostall legitimately cannot hit output-backpressure bin 2.
            goals = [b for b in required if name != "nostall" or b not in (2, 17)]
            assert all(
                int(cov[b]["count"]) > 0 and int(cov[b]["witness_cycle"]) > 0
                for b in goals
            )
        m["tests"].append(
            dict(
                name=name,
                returncode=rc,
                accepted=good,
                expected_rejection=name == "mutation",
            )
        )
        save()
    assert (r / "stalled/coverage.csv").read_bytes() == (
        r / "replay/coverage.csv"
    ).read_bytes()
    m.update(
        status="PASS_UVM_DECLARED_SCOPE", required_bins=len(required), replay_equal=True
    )
except Exception:
    m.update(status="FAILED", failure=traceback.format_exc())
    print(m["failure"], flush=True)
save()
print(m["status"], flush=True)
sys.exit(0 if m["status"] == "PASS_UVM_DECLARED_SCOPE" else 1)
