#!/usr/bin/env python3
"""Portable entry point. Every hardware attempt has isolated logs and hashes."""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
CANDIDATE = [
    "rtl/ws_integrated/ws_integrated.sv",
    "rtl/ws_integrated/packed_slab_loader.sv",
    "rtl/wrapper/slab_loader.sv",
    "rtl/sparse_ws/sparse_ws.sv",
]
BASELINE = [
    "rtl/wrapper/ws_wrapper.sv",
    "rtl/wrapper/slab_loader.sv",
    "rtl/sparse_ws/sparse_ws.sv",
]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "task",
        choices=["doctor", "unit", "model", "uvm", "compare", "synth", "waveform"],
    )
    task = parser.parse_args().task
    if task == "doctor":
        for tool in [
            "python3",
            "verilator",
            "yosys",
            "iverilog",
            "vvp",
            "gtkwave",
            "openroad",
            "klayout",
        ]:
            print(
                f'{tool}: {shutil.which(tool) or "not installed (see docs/REPRODUCING.md)"}'
            )
        print("UVM_HOME:", os.environ.get("UVM_HOME", "not set"))
        print("ORFS_ROOT:", os.environ.get("ORFS_ROOT", "not set"))
        return
    if task in ("unit", "model", "uvm"):
        cmd = (
            [sys.executable, "-m", "pytest", "-q"]
            if task == "unit"
            else [
                sys.executable,
                str(
                    ROOT
                    / "scripts"
                    / ("run_model_study.py" if task == "model" else "run_uvm.py")
                ),
            ]
        )
        raise SystemExit(subprocess.call(cmd, cwd=ROOT))
    run = (
        ROOT
        / "results"
        / (
            task
            + "-"
            + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
        )
    )
    run.mkdir(parents=True)
    print(run, flush=True)
    manifest = {
        "status": "RUNNING",
        "task": task,
        "commands": [],
        "sources": {},
        "versions": {},
    }

    def save():
        (run / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")

    def snapshot(rel):
        p = run / "source" / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, p)
        manifest["sources"][rel] = hashlib.sha256(p.read_bytes()).hexdigest()
        return str(p)

    def call(cmd, log, cwd=run):
        manifest["commands"].append(cmd)
        save()
        tool = cmd[0]
        if (
            tool in ("yosys", "iverilog", "vvp", "verilator")
            and tool not in manifest["versions"]
            and shutil.which(tool)
        ):
            v = subprocess.run(
                [tool, "-V" if tool in ("iverilog", "vvp") else "--version"],
                capture_output=True,
                text=True,
            )
            manifest["versions"][tool] = v.stdout + v.stderr
        with (run / log).open("w") as f:
            subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT, check=True)

    try:
        if task == "compare":
            import csv

            for name, rels in [("baseline", BASELINE), ("candidate", CANDIDATE)]:
                folder = run / name
                folder.mkdir()
                sources = [
                    snapshot(p) for p in rels + [f"verification/directed/{name}/tb.sv"]
                ]
                call(
                    [
                        "iverilog",
                        "-g2012",
                        "-s",
                        "tb",
                        "-o",
                        str(folder / "sim"),
                        *sources,
                    ],
                    name + "-build.log",
                )
                call(["vvp", str(folder / "sim")], name + "-simulation.log", folder)
                rows = list(csv.DictReader((folder / "metrics.csv").open()))
                reference = list(
                    csv.DictReader((ROOT / "evidence" / f"{name}_metrics.csv").open())
                )
                assert rows == reference, f"{name}: cycle/traffic regression changed"
            manifest["status"] = "PASS_DIRECTED_12_JOBS_PER_DESIGN"
        elif task == "synth":
            sources = [snapshot(p) for p in CANDIDATE]
            script = (
                "read_verilog -sv "
                + " ".join(sources)
                + "; hierarchy -check -top ws_integrated; proc; flatten; opt; wreduce; opt; check -assert; stat; write_json pre.json; synth -top ws_integrated; check -assert; stat; write_json generic.json; write_verilog generic.v\n"
            )
            (run / "synthesis.ys").write_text(script)
            call(["yosys", "-s", "synthesis.ys"], "synthesis.log")
            cells = json.loads((run / "pre.json").read_text())["modules"][
                "ws_integrated"
            ]["cells"]
            mul = [c for c in cells.values() if c["type"] == "$mul"]
            # Descriptor address/length arithmetic can contain constant multipliers;
            # count only PE signed 8x8 products, and record all other multipliers.
            pe = []
            other = []
            for c in mul:
                p = {k: int(v, 2) for k, v in c["parameters"].items()}
                (
                    pe
                    if p.get("A_SIGNED") == 1
                    and p.get("B_SIGNED") == 1
                    and p.get("A_WIDTH") == 8
                    and p.get("B_WIDTH") == 8
                    and p.get("Y_WIDTH") == 16
                    else other
                ).append(p)
            assert (
                len(pe) == 16
            ), f"expected 16 signed INT8 PE multipliers, got {len(pe)}"
            assert not any(
                "latch" in c["type"].lower() or c["type"] in ("$div", "$mod")
                for c in cells.values()
            )
            manifest.update(
                status="PASS_GENERIC_SYNTHESIS",
                pe_multipliers=len(pe),
                other_multiplier_parameters=other,
            )
        else:
            from check_simulation import passed

            lib = Path(os.environ["UVM_HOME"]).resolve() / "src"
            assert (lib / "uvm_pkg.sv").is_file()
            sources = [
                snapshot(p) for p in CANDIDATE + ["verification/demos/demo_tb.sv"]
            ]
            call(
                [
                    "verilator",
                    "--binary",
                    "--timing",
                    "--vpi",
                    "--assert",
                    "--trace",
                    "--trace-depth",
                    "6",
                    "--output-groups",
                    "0",
                    "-j",
                    "1",
                    "-Wno-fatal",
                    "--top-module",
                    "tb",
                    "--Mdir",
                    str(run / "build"),
                    "+incdir+" + str(lib),
                    str(lib / "uvm_pkg.sv"),
                    *sources,
                    str(lib / "dpi/uvm_dpi.cc"),
                    "-CFLAGS",
                    "-O0 -I" + str(lib / "dpi"),
                    "-MAKEFLAGS",
                    "OPT_FAST=-O0 OPT_SLOW=-O0",
                ],
                "build.log",
            )
            call([str(run / "build/Vtb")], "simulation.log")
            assert passed(
                (run / "simulation.log").read_text(), 0, "[WAVEFORM_DEMO_PASS]"
            )
            assert (run / "waveform.vcd").stat().st_size > 0
            for p in (ROOT / "verification/demos").glob("*.gtkw"):
                shutil.copy2(p, run / p.name)
            manifest["status"] = "PASS_SHORT_WAVEFORM_ONLY"
    except Exception as exc:
        manifest.update(status="FAILED", failure=str(exc))
        save()
        raise
    save()
    print(manifest["status"])


if __name__ == "__main__":
    main()
