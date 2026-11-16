"""Isolated matched host-boundary physical implementation; audit separately."""

import datetime, hashlib, json, os, pathlib, shutil, subprocess, sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
name = sys.argv[1]
period = float(sys.argv[2])
util = int(sys.argv[3])
assert name in ("integrated",) and period > 0 and 20 <= util <= 50
(ROOT / "results").mkdir(exist_ok=True)
r = (
    ROOT
    / "results"
    / (
        "g6-route-"
        + name
        + "-"
        + datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    )
)
r.mkdir()
print(r, flush=True)
rels = [
    "rtl/physical/integrated_top.sv",
    "rtl/ws_integrated/ws_integrated.sv",
    "rtl/ws_integrated/packed_slab_loader.sv",
    "rtl/wrapper/slab_loader.sv",
    "rtl/sparse_ws/sparse_ws.sv",
]
for rel in rels:
    p = r / "source" / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(ROOT / rel, p)
flow = pathlib.Path(os.environ["ORFS_ROOT"]).resolve() / "flow"
assert (flow / "Makefile").is_file()
(r / "repair_budget.tcl").write_text(
    "rename repair_timing_helper repair_timing_helper_default\nproc repair_timing_helper {args} { repair_timing_helper_default -max_buffer_percent 100 {*}$args }\n"
)
inputs = "rst abort cmd_valid cmd_first cmd_final cmd_sparse cmd_id[*] cmd_m[*] cmd_l[*] cmd_n[*] cmd_k[*] cmd_offset[*] data_valid data[*] data_last compute_enable out_ready"
outputs = "cmd_ready data_ready out_valid out_data[*] out_row[*] out_col[*] out_id[*] done error"
(r / "constraint.sdc").write_text(
    f"""create_clock -name clk -period {period} [get_ports clk]
set_clock_uncertainty 0.2 [get_clocks clk]
set_input_delay 1.0 -clock clk [get_ports {{{inputs}}}]
set_output_delay 1.0 -clock clk [get_ports {{{outputs}}}]
set_input_transition 0.1 [get_ports {{{inputs}}}]
set_load 0.01 [get_ports {{{outputs}}}]
"""
)
(r / "config.mk").write_text(f"""export DESIGN_NAME = gemm_accel
export PLATFORM = nangate45
export VERILOG_FILES = {' '.join(str(r/'source'/p) for p in rels)}
export SDC_FILE = {r}/constraint.sdc
export CORE_UTILIZATION = {util}
export PLACE_DENSITY_LB_ADDON = 0.20
export TNS_END_PERCENT = 100
export HOLD_SLACK_MARGIN = 0.03
export CAP_MARGIN = 20
export SLEW_MARGIN = 10
export PRE_CTS_TCL = {r}/repair_budget.tcl
export PRE_GLOBAL_ROUTE_TCL = {r}/repair_budget.tcl
export SYNTH_REPEATABLE_BUILD = 1
export PDN_TCL = {flow}/designs/nangate45/gcd/grid_strategy-M1-M4-M7.tcl
""")
env = os.environ.copy()
env.update(
    OPENROAD_EXE=shutil.which("openroad"),
    YOSYS_EXE=shutil.which("yosys"),
    KLAYOUT_CMD=shutil.which("klayout"),
)
cmd = [
    "make",
    "-C",
    str(flow),
    "DESIGN_CONFIG=" + str(r / "config.mk"),
    "WORK_HOME=" + str(r),
    "NUM_CORES=1",
]
m = {
    "repair_max_buffer_percent": 100,
    "status": "RUNNING",
    "variant": name,
    "period_ns": period,
    "utilization_percent": util,
    "command": cmd,
    "sources": {p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest() for p in rels},
    "orfs_commit": subprocess.check_output(
        ["git", "-C", str(flow), "rev-parse", "HEAD"], text=True
    ).strip(),
    "versions": {
        t: subprocess.getoutput(t + " --version")
        for t in ("yosys", "openroad", "klayout")
    },
}


def save():
    (r / "manifest.json").write_text(json.dumps(m, indent=2) + "\n")


save()
rc = subprocess.call(
    cmd, env=env, stdout=(r / "flow.log").open("w"), stderr=subprocess.STDOUT
)
m.update(status="AUDIT_PENDING" if rc == 0 else "FAILED", returncode=rc)
save()
sys.exit(rc)
