#!/usr/bin/env bash
# M5 mask-stack formal smoke: yosys + yosys-smtbmc(z3), BMC depth 10.
# The engine copy is mechanically preprocessed into the yosys-SV subset
# (package import inlined, cast syntax normalized, debug struct selects and
# inline frame declarations hoisted). Semantics are untouched.
set -e
cd "$(dirname "$0")"
R=../../../rtl
python3 - <<'PY'
import re
src=open('../../../rtl/control/scigpu_mask_control_m5.sv').read()
src=src.replace("  import scigpu_isa_pkg::*;",
"""  localparam bit [5:0] FAULT_ILLEGAL_OPCODE=6'h01, FAULT_INVALID_REGISTER=6'h02,
      FAULT_INVALID_ADDRESS=6'h03, FAULT_MASK_STACK_OVERFLOW=6'h05,
      FAULT_MASK_STACK_UNDERFLOW=6'h06, FAULT_INTERNAL=6'h0C,
      FAULT_RECONVERGENCE_MISMATCH=6'h0D,
      FAULT_ILLEGAL_CONTROL_FLOW=6'h0E;""")
src=re.sub(r"\bSPW'\(", "(", src)
src=re.sub(r"\bLIW'\(", "(", src)
src=re.sub(r"\bIW'\(", "(", src)
src=re.sub(r"\bPW'\(", "(", src)
for pat in [r"  assign dbg_top_ftype .*?\n", r"  assign dbg_top_parent.*?\n",
            r"  assign dbg_top_maska .*?\n", r"  assign dbg_top_maskb .*?\n"]:
    src=re.sub(pat,"",src)
src=src.replace("  integer si_, di_;","  frame_t fr_tmp;\n  integer si_, di_;",1)
a="            frame_t fr = frames[sl_q][wi_q[IW-1:0]];\n            if ((fr.ftype==FT_IF)||(fr.ftype==FT_MANUAL)) begin\n              wf_d<=fr;\n              wf_d.parent<=fr.parent & ~m_q;\n              wf_d.mask_a<=fr.mask_a  & ~m_q;\n              wf_en<=1'b1; wf_i<=wi_q[IW-1:0];\n            end"
b="            fr_tmp = frames[sl_q][wi_q[IW-1:0]];\n            if ((fr_tmp.ftype==FT_IF)||(fr_tmp.ftype==FT_MANUAL)) begin\n              wf_d<=fr_tmp;\n              wf_d.parent<=fr_tmp.parent & ~m_q;\n              wf_d.mask_a<=fr_tmp.mask_a  & ~m_q;\n              wf_en<=1'b1; wf_i<=wi_q[IW-1:0];\n            end"
assert a in src; src=src.replace(a,b)
a2="          end else begin\n            frame_t fr = frames[sl_q][wi_q[IW-1:0]];\n            wf_d<=fr;\n            wf_d.parent<=fr.parent & ~retm_q;"
b2="          end else begin\n            fr_tmp = frames[sl_q][wi_q[IW-1:0]];\n            wf_d<=fr_tmp;\n            wf_d.parent<=fr_tmp.parent & ~retm_q;"
assert a2 in src; src=src.replace(a2,b2)
a3="            frame_t fr = top_r;\n            if (fr.ftype==FT_IF) begin"
b3="            fr_tmp = top_r;\n            if (fr_tmp.ftype==FT_IF) begin"
assert a3 in src; src=src.replace(a3,b3)
src=re.sub(r"(?<!tmp)\bfr\.", "fr_tmp.", src)
open('mask_control_y.sv','w').write(src)
PY
yosys -q -p "
read_verilog -formal -sv $R/generated/scigpu_isa_pkg.sv
read_verilog -formal -sv $R/common/scigpu_types_pkg.sv
read_verilog -formal -sv mask_control_y.sv
read_verilog -formal -sv m5_mask_stack_formal.sv
prep -top m5_mask_stack_formal
write_smt2 m5_mask_stack.smt2"
yosys-smtbmc -s z3 -t 12 m5_mask_stack.smt2
