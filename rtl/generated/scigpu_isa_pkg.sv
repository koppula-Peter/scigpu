// GENERATED — DO NOT EDIT
// Generator: tools/gen_sv_isa.py from models/isa/scigpu_defs.py
// Source of truth: ISA-001 Rev1.4 (docs are normative; this file prevents drift)
// Waiver (documented, directive §54): UNUSEDPARAM is intentionally waived for
// this package — it exposes the COMPLETE frozen ISA constant set so future
// milestones consume identical values; not-yet-used constants are by design.
/* verilator lint_off UNUSEDPARAM */

package scigpu_isa_pkg;

  // ---- formats ----
    localparam bit [3:0] FMT_VRR = 4'h0;
    localparam bit [3:0] FMT_VRI = 4'h1;
    localparam bit [3:0] FMT_SRR = 4'h2;
    localparam bit [3:0] FMT_SRI = 4'h3;
    localparam bit [3:0] FMT_MEM = 4'h4;
    localparam bit [3:0] FMT_BR = 4'h5;
    localparam bit [3:0] FMT_SYS = 4'h6;
    localparam bit [3:0] FMT_MMA = 4'h8;
    localparam bit [3:0] FMT_PCMP = 4'h9;

  // ---- opcodes (12-bit OPC field) ----
    localparam bit [11:0] OPC_ANDM = 12'h7C5;
    localparam bit [11:0] OPC_ATOM_ADD_U32 = 12'h681;
    localparam bit [11:0] OPC_BAR_WG = 12'h6A0;
    localparam bit [11:0] OPC_BRA_V = 12'h022;
    localparam bit [11:0] OPC_BREAK = 12'h7CA;
    localparam bit [11:0] OPC_CBRANCH_IF = 12'h7C1;
    localparam bit [11:0] OPC_CONTINUE = 12'h7CB;
    localparam bit [11:0] OPC_LOOP_BEGIN = 12'h7C8;
    localparam bit [11:0] OPC_LOOP_END = 12'h7C9;
    localparam bit [11:0] OPC_NOP = 12'h850;
    localparam bit [11:0] OPC_ORM = 12'h7C6;
    localparam bit [11:0] OPC_POPM = 12'h7C3;
    localparam bit [11:0] OPC_PUSHM = 12'h7C0;
    localparam bit [11:0] OPC_RECONV = 12'h7C2;
    localparam bit [11:0] OPC_RET_KERNEL_WF = 12'h7CF;
    localparam bit [11:0] OPC_SETM = 12'h7C4;
    localparam bit [11:0] OPC_S_ADD = 12'h002;
    localparam bit [11:0] OPC_S_AND = 12'h004;
    localparam bit [11:0] OPC_S_BRA = 12'h020;
    localparam bit [11:0] OPC_S_BRA_COND = 12'h021;
    localparam bit [11:0] OPC_S_CMP_EQ = 12'h010;
    localparam bit [11:0] OPC_S_CMP_GT = 12'h012;
    localparam bit [11:0] OPC_S_CMP_LT = 12'h011;
    localparam bit [11:0] OPC_S_GETID = 12'h030;
    localparam bit [11:0] OPC_S_MOV = 12'h001;
    localparam bit [11:0] OPC_S_MUL = 12'h003;
    localparam bit [11:0] OPC_S_NOT = 12'h009;
    localparam bit [11:0] OPC_S_OR = 12'h005;
    localparam bit [11:0] OPC_S_ROL = 12'h00C;
    localparam bit [11:0] OPC_S_ROR = 12'h00D;
    localparam bit [11:0] OPC_S_SAR = 12'h00B;
    localparam bit [11:0] OPC_S_SHL = 12'h006;
    localparam bit [11:0] OPC_S_SHR = 12'h00A;
    localparam bit [11:0] OPC_S_SUB = 12'h007;
    localparam bit [11:0] OPC_S_XOR = 12'h008;
    localparam bit [11:0] OPC_VCMP_EQ = 12'h300;
    localparam bit [11:0] OPC_VCMP_GE = 12'h305;
    localparam bit [11:0] OPC_VCMP_GT = 12'h304;
    localparam bit [11:0] OPC_VCMP_LE = 12'h303;
    localparam bit [11:0] OPC_VCMP_LT = 12'h302;
    localparam bit [11:0] OPC_VCMP_NEQ = 12'h301;
    localparam bit [11:0] OPC_VCVT_F32_I32 = 12'h460;
    localparam bit [11:0] OPC_VCVT_I32_F32 = 12'h461;
    localparam bit [11:0] OPC_VFCMP_GT_O = 12'h311;
    localparam bit [11:0] OPC_VFCMP_LE_O = 12'h312;
    localparam bit [11:0] OPC_VFCMP_LT_O = 12'h310;
    localparam bit [11:0] OPC_VF_ADD = 12'h400;
    localparam bit [11:0] OPC_VF_FMA = 12'h403;
    localparam bit [11:0] OPC_VF_MUL = 12'h402;
    localparam bit [11:0] OPC_VF_SUB = 12'h401;
    localparam bit [11:0] OPC_VLDLW = 12'h620;
    localparam bit [11:0] OPC_VLDW = 12'h600;
    localparam bit [11:0] OPC_VSTLW = 12'h621;
    localparam bit [11:0] OPC_VSTW = 12'h601;
    localparam bit [11:0] OPC_V_ADD = 12'h100;
    localparam bit [11:0] OPC_V_AND = 12'h103;
    localparam bit [11:0] OPC_V_BCAST = 12'h342;
    localparam bit [11:0] OPC_V_LLANE = 12'h343;
    localparam bit [11:0] OPC_V_MAX = 12'h111;
    localparam bit [11:0] OPC_V_MIN = 12'h110;
    localparam bit [11:0] OPC_V_MOV = 12'h340;
    localparam bit [11:0] OPC_V_MOVI = 12'h341;
    localparam bit [11:0] OPC_V_MUL = 12'h102;
    localparam bit [11:0] OPC_V_OR = 12'h104;
    localparam bit [11:0] OPC_V_SAR = 12'h108;
    localparam bit [11:0] OPC_V_SHL = 12'h106;
    localparam bit [11:0] OPC_V_SHR = 12'h107;
    localparam bit [11:0] OPC_V_SUB = 12'h101;
    localparam bit [11:0] OPC_V_XOR = 12'h105;
    localparam bit [11:0] OPC_XORM = 12'h7C7;

  // ---- branch condition codes (FMT=5 COND[7:0], ISA-001 Rev1.2 §8) ----
    localparam bit [7:0] COND_ALWAYS = 8'h00;
    localparam bit [7:0] COND_C = 8'h07;
    localparam bit [7:0] COND_CTRL_EXEC = 8'h0F;
    localparam bit [7:0] COND_GE_S = 8'h0C;
    localparam bit [7:0] COND_GE_U = 8'h0E;
    localparam bit [7:0] COND_LT_S = 8'h0B;
    localparam bit [7:0] COND_LT_U = 8'h0D;
    localparam bit [7:0] COND_N = 8'h05;
    localparam bit [7:0] COND_NC = 8'h08;
    localparam bit [7:0] COND_NN = 8'h06;
    localparam bit [7:0] COND_NSCC = 8'h02;
    localparam bit [7:0] COND_NV = 8'h0A;
    localparam bit [7:0] COND_NZ = 8'h04;
    localparam bit [7:0] COND_RESERVED = 8'h0F;
    localparam bit [7:0] COND_SCC = 8'h01;
    localparam bit [7:0] COND_V = 8'h09;
    localparam bit [7:0] COND_Z = 8'h03;

  // ---- fault codes (ARCH-001 §23) ----
    localparam bit [5:0] FAULT_ILLEGAL_OPCODE = 6'h01;
    localparam bit [5:0] FAULT_INVALID_REGISTER = 6'h02;
    localparam bit [5:0] FAULT_INVALID_ADDRESS = 6'h03;
    localparam bit [5:0] FAULT_ALIGNMENT = 6'h04;
    localparam bit [5:0] FAULT_MASK_STACK_OVERFLOW = 6'h05;
    localparam bit [5:0] FAULT_MASK_STACK_UNDERFLOW = 6'h06;
    localparam bit [5:0] FAULT_ILLEGAL_BARRIER = 6'h07;
    localparam bit [5:0] FAULT_WATCHDOG_TIMEOUT = 6'h08;
    localparam bit [5:0] FAULT_INTERNAL = 6'h0C;
    localparam bit [5:0] FAULT_RECONVERGENCE_MISMATCH = 6'h0D;
    localparam bit [5:0] FAULT_ILLEGAL_CONTROL_FLOW = 6'h0E;

  // ---- architectural constants ----
    localparam int unsigned SC_Z = 0;
    localparam int unsigned SC_N = 1;
    localparam int unsigned SC_C = 2;
    localparam int unsigned SC_V = 3;
    localparam int unsigned GETID_WG_X = 0;
    localparam int unsigned WAVEFRONT_SIZE = 32;
    localparam int unsigned VMOD_PRED_SHIFT = 12;
    localparam int unsigned VMOD_PRED_MASK = 61440;
    localparam int unsigned PRED_NONE = 15;
    localparam int unsigned CCOND_CTRL_EXEC = 15;
    localparam int unsigned FRAME_NONE = 0;
    localparam int unsigned FRAME_IF = 1;
    localparam int unsigned FRAME_LOOP = 2;
    localparam int unsigned FRAME_MANUAL = 3;
    localparam int unsigned IF_THEN = 0;
    localparam int unsigned IF_ELSE = 1;
    localparam int unsigned MASK_STACK_DEPTH_DEFAULT = 32;
    localparam int unsigned LOOP_IDX_INVALID = 4294967295;

endpackage
/* verilator lint_on UNUSEDPARAM */
