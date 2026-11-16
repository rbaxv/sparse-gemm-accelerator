# Verification source map

`uvm/ws_integrated_tb.sv` is the supported full selected-candidate gate. Compile it with Accellera UVM and the four RTL files selected by `scripts/run_uvm.py`; never pass the entire verification tree to synthesis.

`demos/demo_tb.sv` is the shorter waveform version. It deliberately omits the long full-gate workload and full 242-goal closure. `directed/baseline/tb.sv` and `directed/candidate/tb.sv` are matched arithmetic/cycle/traffic checks, run separately through Icarus.

Other `uvm/*_tb.sv` files retain earlier dense-array, sparse-core, loader, OS/WS/RS-wrapper and architectural-comparison test sources. They use different DUT boundaries and are not interchangeable with the integrated test. Their historical qualification is not newly claimed by the public candidate gate. `mac_qual.sv` is the initial UVM/tool feature exercise.

The selected UVM file contains the pin interface, registered test class, driver/checker tasks and simulation top. See `docs/VERIFICATION.md` for the exact role decomposition, coverage IDs and acceptance logic.
