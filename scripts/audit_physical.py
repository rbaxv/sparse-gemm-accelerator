#!/usr/bin/env python3
"""Audit full precision final metrics; never infer passing from rounded slack."""

import os, datetime, hashlib, json, pathlib, re, subprocess, sys

root = pathlib.Path(__file__).resolve().parents[1]
physical = pathlib.Path(sys.argv[1]).resolve()
(root / "results").mkdir(exist_ok=True)
run = (
    root
    / "results"
    / (
        "g5-route-audit-"
        + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    )
)
run.mkdir()
artifacts = physical / "results/nangate45/gemm_accel/base"
reports = physical / "reports/nangate45/gemm_accel/base"
logs = physical / "logs/nangate45/gemm_accel/base"
lib = (
    pathlib.Path(os.environ["ORFS_ROOT"])
    / "flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib"
)
script = f"""read_liberty {lib}
read_db {artifacts}/6_final.odb
read_sdc {artifacts}/6_final.sdc
read_spef {artifacts}/6_final.spef
check_setup -verbose
report_worst_slack -max
report_worst_slack -min
report_tns
report_checks -path_delay min -digits 9
"""
(run / "audit.tcl").write_text(script)
cmd = ["openroad", "-exit", str(run / "audit.tcl")]
with (run / "sta.log").open("w") as log:
    rc = subprocess.call(cmd, stdout=log, stderr=subprocess.STDOUT, cwd=root)
metrics = json.loads((logs / "6_report.json").read_text())
prefix = "finish__"
selected = {
    k: v
    for k, v in metrics.items()
    if any(
        x in k
        for x in [
            "__area",
            "__ws",
            "__tns",
            "violation_count",
            "__drv__max_slew",
            "__drv__max_cap",
            "__drv__max_fanout",
        ]
    )
}
required = [
    artifacts / f"6_final.{ext}" for ext in ["odb", "sdc", "spef", "gds", "def", "v"]
] + [
    reports / "5_route_drc.rpt",
    reports / "6_finish.rpt",
    logs / "6_report.json",
    physical
    / "source/rtl/physical"
    / (json.loads((physical / "manifest.json").read_text())["variant"] + "_top.sv"),
    physical / "config.mk",
    physical / "constraint.sdc",
]
missing = [
    str(p)
    for p in required
    if not p.exists() or (p.name != "5_route_drc.rpt" and p.stat().st_size == 0)
]
checks = {
    "flow_completed": json.loads((physical / "manifest.json").read_text()).get(
        "flow_rc",
        json.loads((physical / "manifest.json").read_text()).get("returncode"),
    )
    == 0,
    "artifacts_complete": not missing,
    "sta_executed": rc == 0,
    "constraint_audit_clean": not re.search(
        r"warning|unconstrained|no clock", (run / "sta.log").read_text(), re.I
    ),
    "setup_nonnegative": metrics[prefix + "timing__setup__ws"] >= 0,
    "hold_nonnegative": metrics[prefix + "timing__hold__ws"] >= 0,
    "setup_violations_zero": metrics[prefix + "timing__drv__setup_violation_count"]
    == 0,
    "hold_violations_zero": metrics[prefix + "timing__drv__hold_violation_count"] == 0,
    "router_drc_empty": (reports / "5_route_drc.rpt").stat().st_size == 0,
}
for kind in ["max_slew", "max_cap", "max_fanout"]:
    checks[kind + "_zero"] = metrics[prefix + "timing__drv__" + kind] == 0
result = {
    "physical_run": str(physical),
    "command": cmd,
    "checks": checks,
    "metrics": selected,
    "missing": missing,
    "hashes": {
        str(p.relative_to(physical)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in required
        if p.exists()
    },
    "pass": all(checks.values()),
    "limits": [
        "Nangate45 single-corner educational flow; no foundry sign-off LVS/DRC",
        "No SDF simulation or activity-qualified power",
        "Host-only 4x4 buffered wrapper; matched study requires all selected variants/settings",
        "STA clock-min-period output is not a searched/validated Fmax",
    ],
}
(run / "audit.json").write_text(json.dumps(result, indent=2) + "\n")
print(run)
print(json.dumps(checks, indent=2))
sys.exit(0 if result["pass"] else 1)
