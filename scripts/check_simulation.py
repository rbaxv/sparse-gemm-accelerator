#!/usr/bin/env python3
"""Strict verdict: UVM $finish may return OS status 0 after UVM_FATAL."""

import pathlib, re, sys


def passed(text, returncode, marker):
    if returncode != 0 or marker not in text:
        return False
    # Require all UVM severity summary fields, each zero; missing is incomplete.
    for severity in ("WARNING", "ERROR", "FATAL"):
        counts = re.findall(r"^UVM_" + severity + r"\s*:\s*(\d+)\s*$", text, re.M)
        if not counts or any(int(x) != 0 for x in counts):
            return False
    if re.search(r"^UVM_(?:ERROR|FATAL)[ \t]+[^ \t:\r\n]", text, re.M):
        return False
    return True


if __name__ == "__main__":
    sys.exit(
        0
        if passed(pathlib.Path(sys.argv[1]).read_text(), int(sys.argv[2]), sys.argv[3])
        else 1
    )
