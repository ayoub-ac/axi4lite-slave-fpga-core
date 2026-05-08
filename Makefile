# AXI4-Lite slave FPGA core - build / lint / sim / synth
#
# Targets:
#   make lint            verilator --lint-only on RTL (regfile + slave +
#                        top + testbench glue)
#   make sim             build the slave-top simulator
#   make test            build + run sim, check for "+PASS"
#   make test-all        alias for `test`
#   make synth           Yosys: ice40 + ecp5 + xilinx generic for the slave top
#   make synth_report    run all available toolchains and emit SYNTH_REPORT.md
#   make vhdl-test       GHDL+Verilator co-sim of the VHDL wrapper (if installed)
#   make regmap-example  run scripts/regmap_gen.py against the example YAML
#                        spec; emits /tmp/example_regmap.sv + /tmp/example_regmap.h
#   make regen_vectors   regenerate tb/random_vectors.h from gen_random_vectors.py
#   make clean           remove build artifacts

VERILATOR ?= verilator
YOSYS     ?= yosys
GHDL      ?= ghdl
VIVADO    ?= vivado
QUARTUS   ?= quartus_sh

RTL_CORE := \
    rtl/axi4lite_regfile.sv \
    rtl/axi4lite_slave.sv \
    rtl/axi4lite_top.sv

TB_TOP := tb/axi4lite_top_tb.sv
TB_AUX := tb/axi4lite_assertions.sv tb/axi4lite_cov.sv
TB_CPP := tb/sim_main.cpp

VFLAGS := -Wall -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL

.PHONY: lint sim test test-all synth synth_report vhdl-test \
        regmap-example regen_vectors clean

lint:
	$(VERILATOR) --lint-only $(VFLAGS) --top-module axi4lite_top_tb \
	    $(RTL_CORE) $(TB_TOP) $(TB_AUX)

sim: obj_dir/Vaxi4lite_top_tb

obj_dir/Vaxi4lite_top_tb: $(RTL_CORE) $(TB_TOP) $(TB_AUX) $(TB_CPP) \
                          tb/random_vectors.h
	$(VERILATOR) --cc --exe --build $(VFLAGS) --assert --public-flat-rw \
	    --top-module axi4lite_top_tb \
	    $(RTL_CORE) $(TB_TOP) $(TB_AUX) $(TB_CPP) \
	    -o Vaxi4lite_top_tb

test: sim
	./obj_dir/Vaxi4lite_top_tb | tee test.log
	@grep -q "+PASS" test.log && echo "TESTS PASSED" || (echo "TESTS FAILED" && exit 1)

test-all: test

# ---------- Open synthesis (Yosys) ------------------------------------------
synth:
	$(YOSYS) -p "read_verilog -sv $(RTL_CORE); hierarchy -top axi4lite_top; synth_ice40 -top axi4lite_top; stat" \
	    | tee synth_ice40.log
	$(YOSYS) -p "read_verilog -sv $(RTL_CORE); hierarchy -top axi4lite_top; synth_ecp5 -top axi4lite_top -abc9; stat" \
	    | tee synth_ecp5.log
	$(YOSYS) -p "read_verilog -sv $(RTL_CORE); hierarchy -top axi4lite_top; synth_xilinx -top axi4lite_top; stat" \
	    | tee synth_xilinx.log

# ---------- Cross-toolchain synthesis report --------------------------------
synth_report:
	@bash scripts/synth_report.sh

# ---------- VHDL co-sim (optional) ------------------------------------------
vhdl-test:
	@which $(GHDL) >/dev/null 2>&1 || { echo "ghdl not installed - skipping vhdl-test"; exit 0; }
	@which $(VERILATOR) >/dev/null 2>&1 || { echo "verilator not installed"; exit 1; }
	@bash scripts/vhdl_cosim.sh

# ---------- regmap_gen example ----------------------------------------------
regmap-example:
	python3 scripts/regmap_gen.py scripts/examples/example_regmap.yaml \
	    --sv /tmp/example_regmap.sv --header /tmp/example_regmap.h
	@echo "[regmap-example] generated /tmp/example_regmap.sv and /tmp/example_regmap.h"

clean:
	rm -rf obj_dir \
	    test.log \
	    synth_ice40.log synth_ecp5.log synth_xilinx.log \
	    synth_report/ SYNTH_REPORT.md

regen_vectors:
	python3 tb/gen_random_vectors.py > tb/random_vectors.h
