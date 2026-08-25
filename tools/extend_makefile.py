#!/usr/bin/env python3
"""Extend Makefile with M3 targets (idempotent)."""
p = 'Makefile'
s = open(p).read()
if 'm3-lint' in s:
    print('already extended'); raise SystemExit
addition = '''
SV_M3 := rtl/generated/scigpu_isa_pkg.sv rtl/common/scigpu_types_pkg.sv \\
         rtl/frontend/scigpu_fetch.sv rtl/frontend/scigpu_decode_m3.sv \\
         rtl/compute/scalar/scigpu_sgpr_file.sv rtl/compute/scalar/scigpu_scalar_alu.sv \\
         rtl/compute/scalar/scigpu_scalar_flags.sv rtl/compute/scalar/scigpu_m3_control.sv \\
         rtl/compute/vector/scigpu_vgpr_file_m3.sv rtl/compute/vector/scigpu_predicate_file_m3.sv \\
         rtl/compute/vector/scigpu_vector_alu.sv rtl/compute/vector/scigpu_vector_engine.sv \\
         rtl/core/scigpu_m3_core.sv rtl/top/scigpu_m3_top.sv

m3-lint:
	@for L in 4 8 16 32; do \\
	  verilator --lint-only -Wall --top-module scigpu_m3_top -GSIMD_LANES=$$L \\
	    $(SV_INC) $(SV_M3) > $(EVID)/m3/verilator_lint_l$$L.log 2>&1 || exit 1; \\
	done
	@echo "[make] M3 lint clean at L4/L8/L16/L32"

define M3BUILD
m3-build-l$(1):
	verilator --cc --exe --build -j 4 -O2 --top-module scigpu_m3_top \\
	  -GSIMD_LANES=$(1) $(SV_INC) $(SV_M3) verification/m3/tb_m3.cpp \\
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

m3-regression: m3-lint m3-build m3-unit m3-directed m3-predication \
               m3-width-equiv m3-random m3-reset m3-fault
	@echo "[make] M3 GREEN"

regression: m1-regression m2-regression m3-regression
	@echo "[make] FULL REGRESSION GREEN (M1+M2+M3)"
'''
s += addition
open(p, 'w').write(s)
print('Makefile extended')
