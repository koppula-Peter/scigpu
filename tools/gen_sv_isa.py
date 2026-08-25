#!/usr/bin/env python3
"""Generate rtl/generated/scigpu_isa_pkg.sv from models/isa/scigpu_defs.py.

Single source of encoding truth (directive §12). Deterministic output.
"""
import os, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, 'models', 'isa'))
import scigpu_defs as D

def const_lines(pairs, indent='    localparam bit [31:0] '):
    return '\n'.join(f"{indent}{n} = 32'h{v:03X};" for n, v in pairs)

def main():
    opc = [(n, getattr(D.OP, n)) for n in dir(D.OP) if n.startswith(('S_', 'V', 'BRA',
           'CBRANCH', 'RECONV', 'RET_', 'ATOM', 'BAR', 'NOP', 'PUSHM', 'POPM',
           'SETM', 'ANDM', 'ORM', 'XORM', 'LOOP_', 'BREAK', 'CONTINUE')) and
           not n.startswith('_')]
    fmts = [('FMT_VRR', D.FMT_VRR), ('FMT_VRI', D.FMT_VRI), ('FMT_SRR', D.FMT_SRR),
            ('FMT_SRI', D.FMT_SRI), ('FMT_MEM', D.FMT_MEM), ('FMT_BR', D.FMT_BR),
            ('FMT_SYS', D.FMT_SYS), ('FMT_MMA', D.FMT_MMA), ('FMT_PCMP', D.FMT_PCMP)]
    conds = [(k, v) for k, v in sorted(D.__dict__.items())
             if k.startswith('COND_') and isinstance(v, int)]
    faults = [('FAULT_ILLEGAL_OPCODE', 0x01), ('FAULT_INVALID_REGISTER', 0x02),
              ('FAULT_INVALID_ADDRESS', 0x03), ('FAULT_ALIGNMENT', 0x04),
              ('FAULT_MASK_STACK_OVERFLOW', 0x05), ('FAULT_MASK_STACK_UNDERFLOW', 0x06),
              ('FAULT_ILLEGAL_BARRIER', 0x07), ('FAULT_WATCHDOG_TIMEOUT', 0x08),
              ('FAULT_INTERNAL', 0x0C),
              ('FAULT_RECONVERGENCE_MISMATCH', 0x0D),
              ('FAULT_ILLEGAL_CONTROL_FLOW', 0x0E)]
    arch = [('SC_Z', D.SC_Z), ('SC_N', D.SC_N), ('SC_C', D.SC_C), ('SC_V', D.SC_V),
            ('GETID_WG_X', D.GETID_WG_X), ('WAVEFRONT_SIZE', 32),
            ('VMOD_PRED_SHIFT', D.VMOD_PRED_SHIFT),
            ('VMOD_PRED_MASK', D.VMOD_PRED_MASK),
            ('PRED_NONE', D.PRED_NONE),
            ('CCOND_CTRL_EXEC', D.COND_CTRL_EXEC),
            ('FRAME_NONE', D.FRAME_NONE), ('FRAME_IF', D.FRAME_IF),
            ('FRAME_LOOP', D.FRAME_LOOP), ('FRAME_MANUAL', D.FRAME_MANUAL),
            ('IF_THEN', D.IF_THEN), ('IF_ELSE', D.IF_ELSE),
            ('MASK_STACK_DEPTH_DEFAULT', D.MASK_STACK_DEPTH_DEFAULT),
            ('LOOP_IDX_INVALID', D.LOOP_IDX_INVALID)]
    vmask = [(n, v) for n, v in sorted(D.__dict__.items())
             if n.startswith('VA_OP_')]
    arch += vmask

    out = []
    a = out.append
    a('// GENERATED — DO NOT EDIT')
    a('// Generator: tools/gen_sv_isa.py from models/isa/scigpu_defs.py')
    a('// Source of truth: ISA-001 Rev1.4 (docs are normative; this file prevents drift)')
    a('// Waiver (documented, directive §54): UNUSEDPARAM is intentionally waived for')
    a('// this package — it exposes the COMPLETE frozen ISA constant set so future')
    a('// milestones consume identical values; not-yet-used constants are by design.')
    a('/* verilator lint_off UNUSEDPARAM */')
    a('')
    a('package scigpu_isa_pkg;')
    a('')
    a('  // ---- formats ----')
    a(const_line := '\n'.join(f"    localparam bit [3:0] {n} = 4'h{v:X};" for n, v in fmts))
    a('')
    a('  // ---- opcodes (12-bit OPC field) ----')
    a('\n'.join(f"    localparam bit [11:0] OPC_{n} = 12'h{v:03X};" for n, v in opc))
    a('')
    a('  // ---- branch condition codes (FMT=5 COND[7:0], ISA-001 Rev1.2 §8) ----')
    a('\n'.join(f"    localparam bit [7:0] {n} = 8'h{v:02X};" for n, v in conds))
    a('')
    a('  // ---- fault codes (ARCH-001 §23) ----')
    a('\n'.join(f"    localparam bit [5:0] {n} = 6'h{v:02X};" for n, v in faults))
    a('')
    a('  // ---- architectural constants ----')
    a('\n'.join(f"    localparam int unsigned {n} = {v};" for n, v in arch))
    a('')
    a('endpackage')
    a('/* verilator lint_on UNUSEDPARAM */')
    dst = os.path.join(ROOT, 'rtl', 'generated', 'scigpu_isa_pkg.sv')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, 'w').write('\n'.join(out) + '\n')
    print(f'wrote {dst} ({len(out)} lines, {len(opc)} opcodes)')

if __name__ == '__main__':
    main()
