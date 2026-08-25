// SciGPU M2 — shared types (MICRO-001 Rev0.1 §1.8)
// Synthesizable, vendor-neutral. Clocking: single clk_gpu domain, sync active-high rst.

package scigpu_types_pkg;

  // Execution FSM states (MICRO-001 §1.3)
  typedef enum logic [3:0] {
    ST_IDLE       = 4'd0,
    ST_FETCH_REQ  = 4'd1,
    ST_FETCH_WAIT = 4'd2,
    ST_DECODE     = 4'd3,
    ST_EXECUTE    = 4'd4,
    ST_COMMIT     = 4'd5,
    ST_COMPLETE   = 4'd6,
    ST_FAULT      = 4'd7,
    ST_VECTOR_SETUP  = 4'd8,
    ST_VECTOR_RUN    = 4'd9,
    ST_VECTOR_RETIRE = 4'd10
  } state_e;

  // Instruction classes produced by the decoder (scalar bootstrap slice)
  typedef enum logic [3:0] {
    CLS_NONE   = 4'd0,
    CLS_MOV    = 4'd1,
    CLS_ALU    = 4'd2,
    CLS_MUL    = 4'd3,   // functional bootstrap multiplier (MICRO-001 §1.6)
    CLS_CMP    = 4'd4,
    CLS_BRA    = 4'd5,
    CLS_BRA_C  = 4'd6,
    CLS_GETID  = 4'd7,
    CLS_NOP    = 4'd8,
    CLS_RET    = 4'd9,
    CLS_VEC_PASS = 4'd10,
    CLS_VEC_ALU  = 4'd11,
    CLS_VEC_MUL  = 4'd12,
    CLS_VEC_LLANE= 4'd13,
    CLS_CTRL   = 4'd14,   // M5 divergence-control family (MICRO-001 Rev0.4 §4)
    CLS_VCMP   = 4'd15    // M5 vector compare -> predicate write (no VGPR dst)
  } iclass_e;

  // Retire-trace record (ISA-001 Rev1.2 / MICRO-001 §1.5)
  typedef struct packed {
    logic        valid;
    logic [63:0] pc;
    logic [63:0] insn;
    logic        sgpr_we;
    logic [7:0]  sgpr_addr;
    logic [31:0] sgpr_wdata;
    logic [3:0]  sc_flags;        // {V,C,N,Z}
    logic        scc;
    logic        branch_taken;
    logic [63:0] next_pc;
    logic        fault;
    logic [5:0]  fault_code;
  } trace_t;

endpackage
