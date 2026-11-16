import importlib.util, pathlib

s = importlib.util.spec_from_file_location(
    "verdict",
    pathlib.Path(__file__).resolve().parents[1] / "scripts/check_simulation.py",
)
m = importlib.util.module_from_spec(s)
s.loader.exec_module(m)
SUMMARY = "QUAL_PASS\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n"


def test_clean():
    assert m.passed(SUMMARY, 0, "QUAL_PASS")


def test_uvm_fatal_with_zero_process_status():
    assert not m.passed(SUMMARY + "UVM_FATAL /source.sv(1) failed\n", 0, "QUAL_PASS")


def test_count_error():
    assert not m.passed(
        SUMMARY.replace("UVM_ERROR : 0", "UVM_ERROR : 1"), 0, "QUAL_PASS"
    )


def test_incomplete():
    assert not m.passed("QUAL_PASS", 0, "QUAL_PASS")


def test_nonzero():
    assert not m.passed(SUMMARY, 1, "QUAL_PASS")


def test_empty():
    assert not m.passed("", 0, "QUAL_PASS")
