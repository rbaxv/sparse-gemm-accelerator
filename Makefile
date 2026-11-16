PYTHON ?= python3
.PHONY: doctor unit model compare uvm synth waveform
doctor unit model compare uvm synth waveform:
	$(PYTHON) scripts/run.py $@
