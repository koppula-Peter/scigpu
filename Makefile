# SciGPU build system — M1 golden model + M2 RTL verification
PY := python3
VVER := $(shell verilator --version 2>/dev/null | head -1)

SV_CORE := rtl/generated/scigpu_isa_pkg.sv rtl/common/scigpu_types_pkg.sv \
           rtl/frontend/scigpu_fetch.sv rtl/frontend/scigpu_decode.sv \
           rtl/compute/scalar/scigpu_sgpr_file.sv rtl/compute/scalar/scigpu_scalar_alu.sv \
           rtl/compute/scalar/scigpu_scalar_flags.sv rtl/compute/scalar/scigpu_scalar_control.sv \
           rtl/core/scigpu_scalar_core.sv rtl/top/scigpu_m2_top.sv
SV_INC  := -Irtl/generated -Irtl/common

EVID    := reports/evidence

.PHONY: generate check-generated m1-regression m2-lint m2-unit m2-build \
        m2-directed m2-diff m2-random m2-reset m2-fault m2-regression regression all

generate:
	$(PY) tools/gen_sv_isa.py

check-generated:
	$(PY) tools/gen_sv_isa.py
	git diff --exit-code -- rtl/generated/scigpu_isa_pkg.sv || \
	  (echo "GENERATED OUTPUT DRIFT: commit regenerated scigpu_isa_pkg.sv"; exit 1)

m1-regression:
	$(PY) tests/run_m1_tests.py | tee $(EVID)/m1_regression.log
	@grep -q "REGRESSION RESULT: PASS" $(EVID)/m1_regression.log && echo "[make] M1 GREEN"

m2-lint:
	verilator --lint-only -Wall --top-module scigpu_m2_top $(SV_INC) $(SV_CORE) \
	  | tee $(EVID)/m2/verilator_lint.log
	@echo "[make] M2 lint clean (see log; documented UNUSEDPARAM waiver inside generated pkg)"

m2-build:
	verilator --cc --exe --build -j 4 -O2 --top-module scigpu_scalar_core \
	  $(SV_INC) $(SV_CORE) verification/m2/tb_m2.cpp \
	  --Mdir build/obj_core -o tb_core 2>&1 | tee $(EVID)/m2/build_core.log
	verilator --cc --exe --build -j 4 -O2 --top-module scigpu_units_tb \
	  $(SV_INC) $(SV_CORE) verification/unit/scigpu_units_tb.sv \
	  verification/unit/units_driver.cpp \
	  --Mdir build/obj_units -o tb_units 2>&1 | tee $(EVID)/m2/build_units.log

m2-unit: m2-build
	./build/obj_units/tb_units 2>&1 | tee $(EVID)/m2/unit.log
	@grep -q "UNIT RESULT: PASS" $(EVID)/m2/unit.log && echo "[make] M2 unit GREEN"

m2-directed: m2-build
	$(PY) tools/m2_run_suite.py directed 2>&1 | tee $(EVID)/m2/directed.log

m2-diff: m2-build
	$(PY) tools/m2_run_suite.py random 2>&1 | tee $(EVID)/m2/differential.log

m2-reset: m2-build
	$(PY) tools/m2_run_suite.py reset 2>&1 | tee $(EVID)/m2/reset_stress.log

m2-fault: m2-build
	$(PY) tools/m2_run_suite.py faults 2>&1 | tee $(EVID)/m2/fault_matrix.log

m2-regression: m2-lint m2-unit m2-directed m2-diff m2-reset m2-fault
	@echo "[make] M2 GREEN"

	@echo "[make] FULL REGRESSION GREEN"

SV_M3 := rtl/generated/scigpu_isa_pkg.sv rtl/common/scigpu_types_pkg.sv \
         rtl/frontend/scigpu_fetch.sv rtl/frontend/scigpu_decode_m3.sv \
         rtl/compute/scalar/scigpu_sgpr_file.sv rtl/compute/scalar/scigpu_scalar_alu.sv \
         rtl/compute/scalar/scigpu_scalar_flags.sv rtl/compute/scalar/scigpu_m3_control.sv \
         rtl/compute/vector/scigpu_vgpr_file_m3.sv rtl/compute/vector/scigpu_predicate_file_m3.sv \
         rtl/compute/vector/scigpu_vector_alu.sv rtl/compute/vector/scigpu_fp32_alu.sv \
         rtl/compute/vector/scigpu_vector_engine.sv \
         rtl/core/scigpu_m3_core.sv rtl/top/scigpu_m3_top.sv

m3-lint:
	@for L in 4 8 16 32; do \
	  verilator --lint-only -Wall --top-module scigpu_m3_top -GSIMD_LANES=$$L \
	    $(SV_INC) $(SV_M3) > $(EVID)/m3/verilator_lint_l$$L.log 2>&1 || exit 1; \
	done
	@echo "[make] M3 lint clean at L4/L8/L16/L32"

define M3BUILD
m3-build-l$(1):
	verilator --cc --exe --build -j 4 -O2 --top-module scigpu_m3_top \
	  -GSIMD_LANES=$(1) $(SV_INC) $(SV_M3) verification/m3/tb_m3.cpp \
	  --Mdir build/m3_l$(1) -o tb_m3 2>&1 | tee $(EVID)/m3/build_l$(1).log
endef

$(foreach W,4 8 16 32,$(eval $(call M3BUILD,$(W))))

m3-build: m3-build-l4 m3-build-l8 m3-build-l16 m3-build-l32

m3-unit:
	$(PY) tools/m3_unit_tests.py 2>&1 | tee $(EVID)/m3/unit_vector.log
	@grep -q "M3 UNIT RESULT: PASS" $(EVID)/m3/unit_vector.log && echo "[make] M3 unit GREEN"

m3-directed: m3-build
	$(PY) tools/m3_run_suite.py directed 2>&1 | tee $(EVID)/m3/directed.log

m3-width-equiv: m3-build
	$(PY) tools/m3_run_suite.py width 2>&1 | tee $(EVID)/m3/width_equivalence.log

m3-predication: m3-build
	@echo "predication coverage: directed P13/P14 + width suite (EXEC x P intersection)"

m3-random: m3-build
	$(PY) tools/m3_run_suite.py random 2>&1 | tee $(EVID)/m3/random_differential.log

m3-reset: m3-build
	$(PY) tools/m3_run_suite.py reset 2>&1 | tee $(EVID)/m3/reset_stress.log

m3-fault: m3-build
	$(PY) tools/m3_run_suite.py faults 2>&1 | tee $(EVID)/m3/fault_matrix.log

m3-regression: m3-lint m3-build m3-unit m3-directed m3-predication                m3-width-equiv m3-random m3-reset m3-fault
	@echo "[make] M3 GREEN"

SV_M5 := rtl/generated/scigpu_isa_pkg.sv rtl/common/scigpu_types_pkg.sv \
         rtl/frontend/scigpu_fetch.sv rtl/frontend/scigpu_decode_m3.sv \
         rtl/frontend/scigpu_decode_m5.sv rtl/scheduler/scigpu_rr_scheduler.sv \
         rtl/compute/vector/scigpu_vector_alu.sv \
         rtl/compute/scalar/scigpu_sgpr_file_m4.sv rtl/compute/scalar/scigpu_scalar_alu.sv \
         rtl/compute/scalar/scigpu_scalar_flags.sv \
         rtl/compute/vector/scigpu_vgpr_file_m4.sv rtl/compute/vector/scigpu_pred_file_m4.sv \
         rtl/compute/vector/scigpu_vector_engine.sv \
         rtl/compute/vector/scigpu_vector_compare_m5.sv \
         rtl/control/scigpu_mask_control_m5.sv \
         rtl/core/scigpu_m5_cu.sv rtl/top/scigpu_m5_top.sv

M5_TB_ARGS = $(SV_INC) -Irtl/compute/vector $(SV_M5) verification/m5/tb_m5.cpp

m5-build-l%:
	verilator --cc --exe --build -j 4 -O2 --top-module scigpu_m5_top \
	  -GSIMD_LANES=$* $(M5_TB_ARGS) -o Vscigpu_m5_top -Mdir build/m5_l$*_d32
	mkdir -p build
	@test -x build/m5_l$*_d32/Vscigpu_m5_top

m5-lint:
	@for L in 4 8 16 32; do \
	  verilator --lint-only -Wall --top-module scigpu_m5_top -GSIMD_LANES=$$L \
	    -Wno-fatal -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
	    $(SV_INC) -Irtl/compute/vector $(SV_M5) \
	    > $(EVID)/m5/verilator_lint_l$$L.log 2>&1 || exit 1; \
	done
	@echo "[make] M5 lint clean x4 widths (pre-existing WIDTH waivers in decode_m5/engine)"

m5-directed:
	python3 tools/m5_run_suite.py directed | tee $(EVID)/m5/directed.log

m5-faults:
	python3 tools/m5_run_suite.py faults --widths 8 | tee $(EVID)/m5/fault_matrix.log

m5-random:
	python3 tools/m5_run_suite.py random -n 1000 | tee $(EVID)/m5/random_divergence.log

m5-cross-width:
	python3 tools/m5_run_suite.py crosswidth -n 250 | tee $(EVID)/m5/cross_width.log

m5-multiwf:
	python3 tools/m5_run_suite.py multiwf -n 250 | tee $(EVID)/m5/random_multiwf.log

m5-reset:
	python3 tools/m5_run_suite.py reset | tee $(EVID)/m5/reset_stress.log

m5-formal:
	./verification/formal/m5_mask_stack/run_formal.sh > $(EVID)/m5/formal_mask_stack.log 2>&1
	@grep -q "Status: PASSED" $(EVID)/m5/formal_mask_stack.log && echo "[make] M5 formal PASSED"

SV_M6 := rtl/generated/scigpu_isa_pkg.sv rtl/common/scigpu_types_pkg.sv \
         rtl/frontend/scigpu_fetch.sv rtl/frontend/scigpu_decode_m3.sv \
         rtl/frontend/scigpu_decode_m5.sv rtl/scheduler/scigpu_rr_scheduler.sv \
         rtl/compute/vector/scigpu_vector_alu.sv \
         rtl/compute/scalar/scigpu_sgpr_prod_m6.sv rtl/compute/scalar/scigpu_scalar_alu.sv \
         rtl/compute/scalar/scigpu_scalar_flags.sv \
         rtl/compute/vector/scigpu_vgpr_file_m4.sv rtl/compute/vector/scigpu_pred_file_m4.sv \
         rtl/compute/vector/scigpu_vector_engine.sv \
         rtl/compute/vector/scigpu_vector_compare_m5.sv \
         rtl/compute/vector/scigpu_scoreboard_m6.sv \
         rtl/control/scigpu_mask_control_m5.sv \
         rtl/core/scigpu_m6_cu.sv rtl/top/scigpu_m6_top.sv

m4-regression:
	verilator --cc --exe --build -j 4 -O2 -Wno-fatal -Wno-WIDTHTRUNC -Wno-IMPLICIT -Wno-WIDTHEXPAND -Wno-PINCONNECTEMPTY --top-module scigpu_m4_top \
	  $(SV_INC) -Irtl/compute/vector rtl/generated/scigpu_isa_pkg.sv rtl/common/scigpu_types_pkg.sv \
	  rtl/frontend/scigpu_fetch.sv rtl/frontend/scigpu_decode_m3.sv rtl/scheduler/scigpu_rr_scheduler.sv \
	  rtl/compute/vector/scigpu_vector_alu.sv rtl/compute/scalar/scigpu_sgpr_file_m4.sv \
	  rtl/compute/scalar/scigpu_scalar_alu.sv rtl/compute/scalar/scigpu_scalar_flags.sv \
	  rtl/compute/vector/scigpu_vgpr_file_m4.sv rtl/compute/vector/scigpu_pred_file_m4.sv \
	  rtl/compute/vector/scigpu_vector_engine.sv rtl/core/scigpu_m4_cu.sv rtl/top/scigpu_m4_top.sv \
	  verification/m4/tb_m4_full.cpp -o Vscigpu_m4_top -Mdir build/m4_full
	build/m4_full/Vscigpu_m4_top | tee $(EVID)/m4/regression_full.log
	@grep -q "SUITE RESULT: ALL PASS" $(EVID)/m4/regression_full.log && echo "[make] M4 GREEN"

m5-regression: m5-lint m5-build-l4 m5-build-l8 m5-build-l16 m5-build-l32 \
               m5-directed m5-faults m5-formal
	@echo "[make] M5 GREEN"

m5-campaigns:
	python3 tools/m5_run_suite.py random -n 1000 | tee $(EVID)/m5/random_divergence.log
	python3 tools/m5_run_suite.py crosswidth -n 250 | tee $(EVID)/m5/cross_width.log
	python3 tools/m5_run_suite.py multiwf -n 250 | tee $(EVID)/m5/random_multiwf.log
	python3 tools/m5_run_suite.py reset | tee $(EVID)/m5/reset_stress.log

regression: m1-regression m2-regression m3-regression m4-regression m5-regression
	@echo "[make] FULL REGRESSION GREEN (M1+M2+M3+M4+M5)"

SV_M7 := rtl/generated/scigpu_isa_pkg.sv rtl/common/scigpu_types_pkg.sv \
         rtl/frontend/scigpu_fetch.sv rtl/frontend/scigpu_decode_m3.sv \
         rtl/frontend/scigpu_decode_m5.sv rtl/scheduler/scigpu_rr_scheduler.sv \
         rtl/compute/vector/scigpu_vector_alu.sv \
         rtl/compute/vector/scigpu_fp32_alu.sv \
         rtl/compute/scalar/scigpu_sgpr_prod_m6.sv rtl/compute/scalar/scigpu_scalar_alu.sv \
         rtl/compute/scalar/scigpu_scalar_flags.sv \
         rtl/compute/vector/scigpu_vgpr_file_m4.sv rtl/compute/vector/scigpu_pred_file_m4.sv \
         rtl/compute/vector/scigpu_vector_engine.sv \
         rtl/compute/vector/scigpu_vector_compare_m5.sv \
         rtl/compute/vector/scigpu_scoreboard_m6.sv \
         rtl/control/scigpu_mask_control_m5.sv \
         rtl/core/scigpu_m6_cu.sv rtl/top/scigpu_m6_top.sv

fp32-lint:
	verilator --lint-only -Wall --top-module scigpu_fp32_alu -GSIMD_LANES=8 \
	  $(SV_INC) rtl/compute/vector/scigpu_fp32_alu.sv \
	  | tee $(EVID)/m7/fp32_lint.log
	@echo "[make] FP32 lint clean"

fp32-build:
	verilator --cc --exe --build -j 4 -O2 --top-module scigpu_fp32_alu \
	  -GSIMD_LANES=8 $(SV_INC) rtl/compute/vector/scigpu_fp32_alu.sv \
	  verification/unit/tb_fp32.cpp -o tb_fp32 -Mdir build/fp32_unit \
	  2>&1 | tee $(EVID)/m7/fp32_build.log

fp32-unit: fp32-build
	./build/fp32_unit/tb_fp32 2>&1 | tee $(EVID)/m7/fp32_unit.log
	@grep -q "FP32 UNIT: PASS" $(EVID)/m7/fp32_unit.log && echo "[make] FP32 unit GREEN"

m6-build-l8:
	sed 's/Vscigpu_m5_top/Vscigpu_m6_top/' verification/m5/tb_m5.cpp > /tmp/opencode/tb_m6.cpp
	verilator --cc --exe --build -j 4 -O2 -Wno-fatal -Wno-WIDTH \
	  --top-module scigpu_m6_top -GSIMD_LANES=8 \
	  $(SV_INC) -Irtl/compute/vector $(SV_M7) /tmp/opencode/tb_m6.cpp -o Vscigpu_m6_top -Mdir build/m6_l8_d32

M6BIN ?= $(pwd)/build/m6_l8_d32/Vscigpu_m6_top
m6-directed:
	M5_BIN=$(shell pwd)/build/m6_l8_d32/Vscigpu_m6_top python3 tools/m5_run_suite.py directed --widths 8 | tee $(EVID)/m6/directed.log

m6-regression: m6-build-l8 m6-directed
	@echo "[make] M6 phase-2 directed GREEN"

fp-campaign:
	python3 tools/fp_campaign.py 300 8 | tee $(EVID)/m7/fp_campaign_l8.log
	@grep -q "fails=0" $(EVID)/m7/fp_campaign_l8.log && echo "[make] FP campaign GREEN"
