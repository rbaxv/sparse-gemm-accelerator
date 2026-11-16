"""Audit a new operating period on an unchanged routed layout and extracted RC.
This does not rerun synthesis/placement or claim a clock-optimized implementation.
"""

import os, datetime, hashlib, json, math, pathlib, re, subprocess, sys, traceback

ROOT = pathlib.Path(__file__).resolve().parents[1]


def change_period(sdc, period):
    assert math.isfinite(period) and period > 0
    clocks = re.findall(r"^create_clock .*$", sdc, re.M)
    assert len(clocks) == 1 and re.search(r"-name clk(?:\s|$)", clocks[0])
    assert (
        "-waveform" not in clocks[0]
    ), "Explicit waveform needs separate qualification"
    changed, count = re.subn(
        r"(-period\s+)[0-9.eE+-]+", lambda m: m[1] + str(period), clocks[0]
    )
    assert count == 1
    return sdc.replace(clocks[0], changed, 1)


def main():
    auditdir = pathlib.Path(sys.argv[1]).resolve()
    period = float(sys.argv[2])
    (ROOT / "results").mkdir(exist_ok=True)
    r = (
        ROOT
        / "results"
        / (
            "g5-fixed-layout-clock-"
            + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        )
    )
    r.mkdir()
    print(r, flush=True)
    m = {
        "status": "RUNNING",
        "input_audit": str(auditdir),
        "operating_period_ns": period,
        "commands": [],
    }
    sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    try:
        parent = json.loads((auditdir / "audit.json").read_text())
        assert parent["pass"]
        physical = pathlib.Path(parent["physical_run"])
        pm = json.loads((physical / "manifest.json").read_text())
        assert (
            pm["status"] in ("FLOW_COMPLETED_AUDIT_PENDING", "AUDIT_PENDING")
            and pm.get("flow_rc", pm.get("returncode")) == 0
        )
        assert all(sha(physical / rel) == h for rel, h in parent["hashes"].items())
        assert all(
            sha(physical / "source" / rel) == h for rel, h in pm["sources"].items()
        )
        art = physical / "results/nangate45/gemm_accel/base"
        original = (art / "6_final.sdc").read_text()
        modified = change_period(original, period)
        (r / "constraint.sdc").write_text(modified)
        lib = (
            pathlib.Path(os.environ["ORFS_ROOT"])
            / "flow/platforms/nangate45/lib/NangateOpenCellLibrary_typical.lib"
        )
        (r / "audit.tcl").write_text(f"""read_liberty {lib}
read_db {art}/6_final.odb
read_sdc {r}/constraint.sdc
read_spef {art}/6_final.spef
check_setup -verbose
report_checks -path_delay max -digits 9
report_checks -path_delay min -digits 9
report_check_types -max_capacitance -max_slew -max_fanout -violators -digits 9
set f [open {r}/metrics.tsv w]
puts $f "clocks\\t[llength [all_clocks]]"
puts $f "period_ns\\t[get_property [get_clocks clk] period]"
puts $f "setup_slack_ns\\t[sta::time_sta_ui [sta::worst_slack_cmd max]]"
puts $f "hold_slack_ns\\t[sta::time_sta_ui [sta::worst_slack_cmd min]]"
puts $f "setup_violations\\t[sta::endpoint_violation_count max]"
puts $f "hold_violations\\t[sta::endpoint_violation_count min]"
puts $f "slew_violations\\t[sta::max_slew_violation_count]"
puts $f "cap_violations\\t[sta::max_capacitance_violation_count]"
puts $f "fanout_violations\\t[sta::max_fanout_violation_count]"
close $f
""")
        cmd = ["openroad", "-exit", str(r / "audit.tcl")]
        m["commands"].append(cmd)
        with (r / "sta.log").open("w") as f:
            rc = subprocess.call(cmd, stdout=f, stderr=subprocess.STDOUT)
        assert rc == 0, ("OpenROAD failure", rc)
        metrics = {
            k: float(v)
            for k, v in (
                line.split() for line in (r / "metrics.tsv").read_text().splitlines()
            )
        }
        checks = {
            "one_clock": metrics["clocks"] == 1,
            "requested_period": abs(metrics["period_ns"] - period) < 1e-6,
            "constraint_audit_clean": not re.search(
                r"warning|unconstrained|no clock|\[ERROR",
                (r / "sta.log").read_text(),
                re.I,
            ),
            "setup_nonnegative": metrics["setup_slack_ns"] >= 0,
            "hold_nonnegative": metrics["hold_slack_ns"] >= 0,
        }
        checks.update(
            {
                k: metrics[k] == 0
                for k in (
                    "setup_violations",
                    "hold_violations",
                    "slew_violations",
                    "cap_violations",
                    "fanout_violations",
                )
            }
        )
        m.update(
            status="PASS" if all(checks.values()) else "TIMING_CHECK_FAILED",
            checks=checks,
            metrics=metrics,
            physical=str(physical),
            implementation_period_ns=pm["period_ns"],
            input_hashes={
                str(p): sha(p)
                for p in [
                    auditdir / "audit.json",
                    art / "6_final.odb",
                    art / "6_final.spef",
                    art / "6_final.sdc",
                    lib,
                ]
            },
            version=next(
                line.strip()
                for line in (r / "sta.log").read_text().splitlines()
                if line.startswith("OpenROAD ")
            ),
        )
    except Exception:
        m.update(status="FAILED", failure=traceback.format_exc())
        print(m["failure"])
    m["limits"] = (
        "Unchanged routed implementation, different operating period only. Single-corner Nangate45 STA; not synthesis/P&R optimized at new period, SDF, exhaustive Fmax, power or sign-off."
    )
    (r / "runner.py").write_bytes(pathlib.Path(__file__).read_bytes())
    (r / "manifest.json").write_text(json.dumps(m, indent=2))
    print(m["status"])
    sys.exit(0 if m["status"] == "PASS" else 1)


if __name__ == "__main__":
    main()
