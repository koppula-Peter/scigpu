"""SciGPU ISA v1.0 — M1 subset: opcode/format encode-decode core.

Implements the 64-bit little-endian encoding defined in ISA-001 §5 with the
concrete v1-subset opcode assignments. Shared by assembler, simulator (decoder)
and disassembler. GENERATED-BY-HAND — single source of truth for encodings.

Formats (ISA-001 §5.2 + recorded additive amendment Rev1.1):
  FMT0 VRR  : [47:40]VDST [39:32]VSRC0 [31:24]VSRC1 [23:16]VSRC2
  FMT1 VRI  : [47:40]VDST [39:32]VSRC0 [31:16]SIMM16
  FMT2 SRR  : [47:40]SDST [39:32]SS0 [31:24]SS1
  FMT3 SRI  : [47:40]SDST [39:32]SS0 [31:8]SIMM24
  FMT4 MEM  : [47:40]VDATA/SDATA [39:32]SADDR [31:12]SOFF20s
              [11:10]SCOPE [9:8]ORDER [7:4]SIZE [3:0]HINT
  FMT5 BR   : [47:24]DISP24s [23:16]COND [15:0]BMOD
  FMT6 SYS  : payload[47:0]
  FMT8 MMA  : (not in M1 subset)
  FMT9 PCMP : [47:44]PDST [43:36]VSRC0 [35:28]VSRC1   (ISA-001 Rev1.1 additive)

M1 subset notes (recorded honestly, not hidden):
  - .W (32-bit) memory granularity only; B/H/D arrive with later milestones.
  - ATOM.ADD.U32 return-old at device scope only.
  - MMA/SFU/collectives reserved, not decoded.
"""

MASK64 = (1 << 64) - 1
MASK32 = (1 << 32) - 1

# ---------------------------------------------------------------- opcodes ---
OPC_W = 12          # bits [63:52]
FMT_W = 4           # bits [51:48]

class OP:  # OPC values (v1 subset; ranges per ISA-001 §6)
    # scalar (000-0FF) — allocations frozen since M1; new ops in free slots (ISA-001 Rev1.2)
    S_MOV = 0x001; S_ADD = 0x002; S_MUL = 0x003; S_AND = 0x004; S_OR = 0x005
    S_SHL = 0x006
    S_SUB = 0x007; S_XOR = 0x008; S_NOT = 0x009          # Rev1.2 allocation
    S_SHR = 0x00A; S_SAR = 0x00B                          # Rev1.2 allocation
    S_ROL = 0x00C; S_ROR = 0x00D                          # reserved/optional later
    S_CMP_EQ = 0x010; S_CMP_LT = 0x011; S_CMP_GT = 0x012
    S_BRA = 0x020; S_BRA_COND = 0x021; BRA_V = 0x022
    S_GETID = 0x030                      # SMOD payload sel: 0=WG_X
    # vector integer (100-1FF)
    V_ADD = 0x100; V_SUB = 0x101; V_MUL = 0x102; V_AND = 0x103; V_OR = 0x104
    V_XOR = 0x105; V_SHL = 0x106; V_SHR = 0x107; V_SAR = 0x108
    V_MIN = 0x110; V_MAX = 0x111
    # compares writing predicates (300-33F, FMT9)
    VCMP_EQ = 0x300; VCMP_NEQ = 0x301; VCMP_LT = 0x302; VCMP_LE = 0x303
    VCMP_GT = 0x304; VCMP_GE = 0x305
    VFCMP_LT_O = 0x310; VFCMP_GT_O = 0x311; VFCMP_LE_O = 0x312
    # moves / broadcast (340-37F)
    V_MOV = 0x340; V_MOVI = 0x341; V_BCAST = 0x342; V_LLANE = 0x343
    # FP32 (400-45F) / CVT (460-49F)
    VF_ADD = 0x400; VF_SUB = 0x401; VF_MUL = 0x402; VF_FMA = 0x403
    VCVT_F32_I32 = 0x460; VCVT_I32_F32 = 0x461
    # memory (600-63F / atomics 680-69F)
    VLDW = 0x600; VSTW = 0x601           # global vector word
    SLDW = 0x610; SSTW = 0x611           # global scalar word (VDATA field = SGPR)
    VLDLW = 0x620; VSTLW = 0x621         # local/shared vector word
    ATOM_ADD_U32 = 0x681                 # return-old, device scope
    BAR_WG = 0x6A0
    # control / divergence (mask-stack family 7C0-7CF per ISA-001 Rev1.4 §16)
    PUSHM = 0x7C0                        # push FRAME_MANUAL{saved_exec=EXEC}
    CBRANCH_IF = 0x7C1                   # COND=p-index; DISP24=else; BMOD=reconv
    RECONV = 0x7C2
    POPM = 0x7C3                         # pop FRAME_MANUAL: EXEC=saved&LIVE
    SETM = 0x7C4                         # EXEC = P[N] & LIVE
    ANDM = 0x7C5                         # EXEC &= P[N] (& LIVE)
    ORM = 0x7C6                          # EXEC = (EXEC|P[N]) & LIVE
    XORM = 0x7C7                         # EXEC = (EXEC^P[N]) & LIVE
    LOOP_BEGIN = 0x7C8                   # DISP24 = loop_end - (PC+1)
    LOOP_END = 0x7C9                     # COND=p-index(15=all); DISP24 = head-(PC+1)
    BREAK = 0x7CA                        # COND=p-index or 15=current EXEC
    CONTINUE = 0x7CB                     # COND=p-index or 15=current EXEC
    RET_KERNEL_WF = 0x7CF
    # system (840-85F)
    NOP = 0x850

MNEMONIC = {}
def _m(op, name): MNEMONIC[op] = name
for _op, _n in [
    (OP.S_MOV,'S_MOV'),(OP.S_ADD,'S_ADD'),(OP.S_MUL,'S_MUL'),(OP.S_AND,'S_AND'),
    (OP.S_OR,'S_OR'),(OP.S_SHL,'S_SHL'),(OP.S_CMP_EQ,'S_CMP_EQ'),(OP.S_CMP_LT,'S_CMP_LT'),
    (OP.S_CMP_GT,'S_CMP_GT'),(OP.S_BRA,'S_BRA'),(OP.S_BRA_COND,'S_BRA_COND'),
    (OP.BRA_V,'BRA_V'),(OP.S_GETID,'S_GETID'),
    (OP.S_SUB,'S_SUB'),(OP.S_XOR,'S_XOR'),(OP.S_NOT,'S_NOT'),
    (OP.S_SHR,'S_SHR'),(OP.S_SAR,'S_SAR'),
    (OP.S_ROL,'S_ROL'),(OP.S_ROR,'S_ROR'),
    (OP.V_ADD,'V_ADD'),(OP.V_SUB,'V_SUB'),(OP.V_MUL,'V_MUL'),(OP.V_AND,'V_AND'),
    (OP.V_OR,'V_OR'),(OP.V_XOR,'V_XOR'),(OP.V_SHL,'V_SHL'),(OP.V_SHR,'V_SHR'),
    (OP.V_SAR,'V_SAR'),(OP.V_MIN,'V_MIN'),(OP.V_MAX,'V_MAX'),
    (OP.VCMP_EQ,'VCMP_EQ'),(OP.VCMP_NEQ,'VCMP_NEQ'),(OP.VCMP_LT,'VCMP_LT'),
    (OP.VCMP_LE,'VCMP_LE'),(OP.VCMP_GT,'VCMP_GT'),(OP.VCMP_GE,'VCMP_GE'),
    (OP.VFCMP_LT_O,'VFCMP.LT.O'),(OP.VFCMP_GT_O,'VFCMP.GT.O'),(OP.VFCMP_LE_O,'VFCMP.LE.O'),
    (OP.V_MOV,'V_MOV'),(OP.V_MOVI,'V_MOVI'),(OP.V_BCAST,'V_BCAST'),(OP.V_LLANE,'V_LLANE'),
    (OP.VF_ADD,'V_ADD.F32'),(OP.VF_SUB,'V_SUB.F32'),(OP.VF_MUL,'V_MUL.F32'),
    (OP.VF_FMA,'V_FMA.F32'),
    (OP.VCVT_F32_I32,'V_CVT.F32.I32'),(OP.VCVT_I32_F32,'V_CVT.I32.F32'),
    (OP.VLDW,'V_LOAD.W'),(OP.VSTW,'V_STORE.W'),(OP.SLDW,'S_LOAD.W'),(OP.SSTW,'S_STORE.W'),
    (OP.VLDLW,'V_LOAD.LOCAL.W'),(OP.VSTLW,'V_STORE.LOCAL.W'),
    (OP.ATOM_ADD_U32,'ATOM.ADD.U32'),(OP.BAR_WG,'BAR.WG'),
    (OP.CBRANCH_IF,'CBRANCH_IF'),(OP.RECONV,'RECONV'),(OP.RET_KERNEL_WF,'RET_KERNEL_WF'),
    (OP.PUSHM,'PUSHM'),(OP.POPM,'POPM'),(OP.SETM,'SETM'),(OP.ANDM,'ANDM'),
    (OP.ORM,'ORM'),(OP.XORM,'XORM'),(OP.LOOP_BEGIN,'LOOP_BEGIN'),
    (OP.LOOP_END,'LOOP_END'),(OP.BREAK,'BREAK'),(OP.CONTINUE,'CONTINUE'),
    (OP.NOP,'NOP')]:
    _m(_op, _n)
NAME_TO_OP = {v: k for k, v in MNEMONIC.items()}
# assembler-friendly compare aliases
NAME_TO_OP.update({'V_CMP.EQ': OP.VCMP_EQ, 'V_CMP.NEQ': OP.VCMP_NEQ,
                   'V_CMP.LT': OP.VCMP_LT, 'V_CMP.LE': OP.VCMP_LE,
                   'V_CMP.GT': OP.VCMP_GT, 'V_CMP.GE': OP.VCMP_GE,
                   'V_CMP_EQ': OP.VCMP_EQ, 'V_CMP_NEQ': OP.VCMP_NEQ,
                   'V_CMP_LT': OP.VCMP_LT, 'V_CMP_LE': OP.VCMP_LE,
                   'V_CMP_GT': OP.VCMP_GT, 'V_CMP_GE': OP.VCMP_GE,
                   'BRA': OP.BRA_V})

FMT_VRR, FMT_VRI, FMT_SRR, FMT_SRI = 0, 1, 2, 3
FMT_MEM, FMT_BR, FMT_SYS, FMT_MMA, FMT_PCMP = 4, 5, 6, 8, 9

# ---- scalar condition state (ISA-001 Rev1.2 §7): dedicated architectural state,
# NOT SGPRs. The former temporary SGPR63 convention is removed.
SC_Z, SC_N, SC_C, SC_V = 0, 1, 2, 3          # flag bit positions in sc_flags nibble

# ---- FMT=5 COND[7:0] encoding for scalar conditional branches (Rev1.2 §8)
(COND_ALWAYS, COND_SCC, COND_NSCC, COND_Z, COND_NZ, COND_N, COND_NN,
 COND_C, COND_NC, COND_V, COND_NV, COND_LT_S, COND_GE_S, COND_LT_U,
 COND_GE_U, COND_RESERVED) = range(0x10)
COND_NAMES = {
    'ALWAYS': COND_ALWAYS, 'SCC': COND_SCC, 'NSCC': COND_NSCC, 'Z': COND_Z,
    'NZ': COND_NZ, 'N': COND_N, 'NN': COND_NN, 'C': COND_C, 'NC': COND_NC,
    'V': COND_V, 'NV': COND_NV, 'LT_S': COND_LT_S, 'GE_S': COND_GE_S,
    'LT_U': COND_LT_U, 'GE_U': COND_GE_U}
COND_REV = {v: k for k, v in COND_NAMES.items()}

# S_GETID selectors (SYS payload[7:0]); WG_X == 0 mandatory from M2
GETID_WG_X = 0

# ---- M5 divergence-control condition convention (ISA-001 Rev1.4 §16.2) ----
# For 0x7C4..0x7CB control instructions ONLY (distinct from S_BRA_COND table):
COND_CTRL_EXEC = 15            # COND 15 = unconditional: use current EXEC
FRAME_NONE, FRAME_IF, FRAME_LOOP, FRAME_MANUAL = 0, 1, 2, 3
IF_THEN, IF_ELSE = 0, 1        # frame phase values
MASK_STACK_DEPTH_DEFAULT = 32  # architecture minimum >= 32 (ADR-011)
LOOP_IDX_INVALID = 0xFFFFFFFF  # sentinel for "no active loop" in golden/RTL docs

def enc_getid(sdst, sel=GETID_WG_X):
    """S_GETID: FMT_SYS payload[15:8]=SDST, [7:0]=selector."""
    return enc_sys(OP.S_GETID, ((sdst & 0xFF) << 8) | (sel & 0xFF))

VECTOR_ALU = {OP.V_ADD,OP.V_SUB,OP.V_MUL,OP.V_AND,OP.V_OR,OP.V_XOR,OP.V_SHL,
              OP.V_SHR,OP.V_SAR,OP.V_MIN,OP.V_MAX,
              OP.VF_ADD,OP.VF_SUB,OP.VF_MUL,OP.VF_FMA}
VECTOR_2SRC = {OP.V_MOV} | VECTOR_ALU - {OP.VF_FMA}

def _f(word, hi, lo): return (word >> lo) & ((1 << (hi - lo + 1)) - 1)
def sext(val, bits):
    sign = 1 << (bits - 1)
    return (val & (sign - 1)) - (val & sign)

# ---------------------------------------------------------------- encoder ---
def enc(opc, fmt):
    return (opc << 52) | (fmt << 48)

# ---- VMOD field layout (ISA-001 §5.2; M3: only PRED is supported nonzero) ----
VMOD_PRED_SHIFT = 12
VMOD_PRED_BITS  = 4
VMOD_PRED_MASK  = 0xF << VMOD_PRED_SHIFT
PRED_NONE       = 15          # unpredicated bypass: effective_mask = EXEC

def build_vmod(pred=PRED_NONE, typesel=0, rnd=0, sat=0, abs0=0, neg0=0, neg1=0,
               flags=0):
    """Deliberate VMOD assembly. Nonzero unsupported modifiers are the caller's
    responsibility to reject (golden + RTL fault on them for M3 integer ops)."""
    return (((pred & 0xF) << 12) | ((typesel & 3) << 10) | ((rnd & 3) << 8) |
            ((sat & 1) << 7) | ((abs0 & 1) << 6) | ((neg0 & 1) << 5) |
            ((neg1 & 1) << 4) | (flags & 0xF))

def enc_vrr(opc, vdst, s0, s1=None, s2=None, pred=PRED_NONE):
    w = (enc(opc, FMT_VRR) | (vdst << 40) | (s0 << 32) | ((s1 or 0) << 24) |
         ((s2 or 0) << 16) | (build_vmod(pred) << 16 if False else
          (build_vmod(pred) << 0)))
    # VMOD occupies [15:0]
    w = (enc(opc, FMT_VRR) | (vdst << 40) | (s0 << 32) | ((s1 or 0) << 24) |
         ((s2 or 0) << 16)) | build_vmod(pred)
    return w & MASK64

def enc_vri(opc, vdst, s0, imm16, pred=PRED_NONE):
    # NOTE: FMT_VRI has no VSRC2/VSRC1 slots free for a separate VMOD field in
    # the M1 layout; VMOD lives in [15:0] and SIMM16 in [31:16].
    w = (enc(opc, FMT_VRI) | (vdst << 40) | (s0 << 32) |
         ((imm16 & 0xFFFF) << 16)) | build_vmod(pred)
    return w & MASK64

def enc_srr(opc, sdst, s0, s1=0):
    return (enc(opc, FMT_SRR) | (sdst << 40) | (s0 << 32) | (s1 << 24)) & MASK64

def enc_sri(opc, sdst, s0, imm24):
    return (enc(opc, FMT_SRI) | (sdst << 40) | (s0 << 32) | ((imm24 & 0xFFFFFF) << 8)) & MASK64

def enc_mem(opc, data, saddr, soff, scope=0, order=0, size=2, hint=0):
    return (enc(opc, FMT_MEM) | ((data & 0xFF) << 40) | ((saddr & 0xFF) << 32)
            | ((soff & 0xFFFFF) << 12) | ((scope & 3) << 10) | ((order & 3) << 8)
            | ((size & 0xF) << 4) | (hint & 0xF)) & MASK64

def enc_br(opc, disp24, cond=0, bmod=0):
    return (enc(opc, FMT_BR) | ((disp24 & 0xFFFFFF) << 24)
            | ((cond & 0xFF) << 16) | (bmod & 0xFFFF)) & MASK64

def enc_ctrl(opc, disp24=0, cond=0, bmod=0):
    """M5 divergence-control FMT5: COND nibble at [23:20], [19:16]=0
    (ISA-001 Rev1.4 §16.2 control-condition convention)."""
    return (enc(opc, FMT_BR) | ((disp24 & 0xFFFFFF) << 24)
            | ((cond & 0xF) << 20) | (bmod & 0xFFFF)) & MASK64

def enc_sys(opc, payload=0):
    return (enc(opc, FMT_SYS) | (payload & ((1 << 48) - 1))) & MASK64

def enc_pcmp(opc, pdst, s0, s1):
    return (enc(opc, FMT_PCMP) | ((pdst & 0xF) << 44) | ((s0 & 0xFF) << 36)
            | ((s1 & 0xFF) << 28)) & MASK64

# ---------------------------------------------------------------- decoder ---
class Decoded:
    __slots__ = ('op','fmt','vd','vs0','vs1','vs2','imm','pd','saddr','soff',
                 'scope','order','size','hint','disp','cond','payload',
                 'pred','typesel','rnd','sat','abs0','neg0','neg1','vflags')
    def __repr__(self):
        return f'<{MNEMONIC.get(self.op,hex(self.op))} fmt{self.fmt}>'

def _vmod(d, word):
    v = _f(word,15,0)
    d.pred     = (v >> VMOD_PRED_SHIFT) & 0xF
    d.typesel  = (v >> 10) & 3
    d.rnd      = (v >> 8) & 3
    d.sat      = (v >> 7) & 1
    d.abs0     = (v >> 6) & 1
    d.neg0     = (v >> 5) & 1
    d.neg1     = (v >> 4) & 1
    d.vflags   = v & 0xF

def decode(word):
    d = Decoded(); d.op = _f(word,63,52); d.fmt = _f(word,51,48)
    d.vd=d.vs0=d.vs1=d.vs2=d.imm=d.pd=d.saddr=d.soff=0
    d.scope=d.order=d.size=d.hint=d.disp=d.cond=d.payload=0
    d.pred=PRED_NONE; d.typesel=0; d.rnd=0; d.sat=0; d.abs0=0; d.neg0=0
    d.neg1=0; d.vflags=0
    if d.fmt == FMT_VRR:
        d.vd=_f(word,47,40); d.vs0=_f(word,39,32); d.vs1=_f(word,31,24); d.vs2=_f(word,23,16)
        _vmod(d, word)
    elif d.fmt == FMT_VRI:
        d.vd=_f(word,47,40); d.vs0=_f(word,39,32); d.imm=sext(_f(word,31,16),16)
        _vmod(d, word)
    elif d.fmt == FMT_SRR:
        d.vd=_f(word,47,40); d.vs0=_f(word,39,32); d.vs1=_f(word,31,24)
    elif d.fmt == FMT_SRI:
        d.vd=_f(word,47,40); d.vs0=_f(word,39,32); d.imm=sext(_f(word,31,8),24)
    elif d.fmt == FMT_MEM:
        d.vd=_f(word,47,40); d.saddr=_f(word,39,32); d.soff=sext(_f(word,31,12),20)
        d.scope=_f(word,11,10); d.order=_f(word,9,8); d.size=_f(word,7,4); d.hint=_f(word,3,0)
    elif d.fmt == FMT_BR:
        d.disp=sext(_f(word,47,24),24); d.cond=_f(word,23,16); d.payload=_f(word,15,0)
    elif d.fmt == FMT_SYS:
        d.payload=_f(word,47,0)
    elif d.fmt == FMT_PCMP:
        d.pd=_f(word,47,44); d.vs0=_f(word,43,36); d.vs1=_f(word,35,28)
    else:
        raise ValueError(f'unsupported FMT {d.fmt}')
    return d

# ------------------------------------------------------------------ SGP1 ----
SGP1_MAGIC = b'SGP1'
SEC_CODE, SEC_RODATA, SEC_META, SEC_SYM, SEC_STR, SEC_RELOC, SEC_DEBUG = 1,2,3,4,5,6,7

def crc64_ecma(data):
    poly = 0xC96C5795D7870F42
    crc = 0xFFFFFFFFFFFFFFFF
    for b in data:
        crc ^= b << 56
        for _ in range(8):
            crc = ((crc << 1) ^ poly) & MASK64 if crc & (1 << 63) else (crc << 1) & MASK64
    return crc

import struct as _s
def write_sgp1(path, isa_major=1, isa_minor=0, features=0, code=b'', meta=b'',
               entry_name_idx=0, vgpr_req=0, sgpr_req=0, smem_req=0, arg_count=0):
    nsec = 2
    entry_off = 64                       # entry-point table right after header
    entry_sz = 40
    sec_tab_off = entry_off + entry_sz
    sec_entry_sz = 32
    code_off = sec_tab_off + nsec * sec_entry_sz
    meta_off = code_off + len(code)
    buf = bytearray(meta_off + len(meta))
    buf[0:4] = SGP1_MAGIC
    _s.pack_into('<HHHHI', buf, 4, 1, 0, isa_major, isa_minor, features)
    _s.pack_into('<Q', buf, 0x18, sec_tab_off)
    _s.pack_into('<I', buf, 0x20, nsec)
    _s.pack_into('<I', buf, 0x24, entry_off)
    o = sec_tab_off
    _s.pack_into('<IIQQQ', buf, o, SEC_CODE, 0, code_off, len(code), 0);   o += 32
    _s.pack_into('<IIQQQ', buf, o, SEC_META, 0, meta_off, len(meta), 0)
    _s.pack_into('<IIQIIIII', buf, entry_off, entry_name_idx, 0, 0,
                 vgpr_req, sgpr_req, smem_req, 0, arg_count)
    buf[code_off:code_off+len(code)] = code
    buf[meta_off:meta_off+len(meta)] = meta
    crc = crc64_ecma(bytes(buf))
    _s.pack_into('<Q', buf, 0x10, crc)
    with open(path, 'wb') as f:
        f.write(buf)
    return bytes(buf)

def read_sgp1(path_or_bytes):
    raw = path_or_bytes if isinstance(path_or_bytes,(bytes,bytearray)) else open(path_or_bytes,'rb').read()
    assert raw[0:4] == SGP1_MAGIC, 'bad magic'
    stored = _s.unpack_from('<Q', raw, 0x10)[0]
    chk = bytearray(raw); _s.pack_into('<Q', chk, 0x10, 0)
    assert crc64_ecma(bytes(chk)) == stored, 'SGP1 checksum mismatch (INV-022)'
    fmt_major, fmt_minor = _s.unpack_from('<HH', raw, 4)
    isa = _s.unpack_from('<HH', raw, 8)
    features = _s.unpack_from('<I', raw, 12)[0]
    sec_off, nsec = _s.unpack_from('<QI', raw, 0x18)
    sections = {}
    for i in range(nsec):
        styp, flags, off, ln, nm = _s.unpack_from('<IIQQQ', raw, sec_off + 32*i)
        sections[styp] = (off, ln)
    eo = _s.unpack_from('<I', raw, 0x24)[0]
    name_idx, eflags, pc_off = _s.unpack_from('<IIQ', raw, eo)
    vgpr_req, sgpr_req, smem_req, rsv = _s.unpack_from('<IIII', raw, eo+16)
    _, arg_count = _s.unpack_from('<II', raw, eo+32)
    c_off, c_len = sections[SEC_CODE]
    return dict(fmt=(fmt_major,fmt_minor), isa=isa, features=features,
                entry=dict(pc=pc_off, vgpr=vgpr_req, sgpr=sgpr_req, smem=smem_req,
                           args=arg_count),
                code=raw[c_off:c_off+c_len])
