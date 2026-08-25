// SciGPU M6 — operand collector (MICRO-001 Rev0.5 §5.2).
//
// Gathers both vector source operands (all B = 32/SIMD_LANES beats) from the
// banked VGPR into staging registers before the engine starts.
//   * disjoint register parity : one cycle per beat (both ports in parallel)
//   * equal register parity    : bank-set collision -> two cycles per beat,
//     `conflict` pulses once per serialized gather (PMC_BANK_CONFLICTS)
// Staged words are supplied to the engine datapath by beat index (`sup_beat`),
// replacing live per-beat VGPR reads for the vector datapath.
module scigpu_operand_collect_m6 #(
  parameter int unsigned SLOTS      = 4,
  parameter int unsigned SIMD_LANES = 8
) (
  input  logic clk, input logic rst,

  input  logic        start,               // one-cycle pulse when idle
  output logic        ready,
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [7:0]  vs0,
  input  logic [7:0]  vs1,
  /* verilator lint_on UNUSEDSIGNAL */
  input  logic [$clog2(SLOTS)-1:0] slot,
  output logic        busy,
  output logic        conflict,            // serialized-gather pulse

  // banked-VGPR read ports (driven here)
  output logic        rd0_en, output logic rd0_par, output logic [3:0] rd0_rh,
  output logic [4:0]  rd0_base,
  output logic [$clog2(SLOTS)-1:0] rd0_slot,
  input  logic [31:0] rd0_data [SIMD_LANES],
  output logic        rd1_en, output logic rd1_par, output logic [3:0] rd1_rh,
  output logic [4:0]  rd1_base,
  output logic [$clog2(SLOTS)-1:0] rd1_slot,
  input  logic [31:0] rd1_data [SIMD_LANES],

  // staged supply to engine datapath
  /* verilator lint_off UNUSEDSIGNAL */
  input  logic [2:0]  sup_beat,
  /* verilator lint_on UNUSEDSIGNAL */
  output logic [31:0] sup_a [SIMD_LANES],
  output logic [31:0] sup_b [SIMD_LANES],
  output logic        last_gather
);

  localparam int unsigned L = SIMD_LANES;
  localparam int unsigned B = 32/L;
  localparam int unsigned BCW = (B<=1)?1:$clog2(B);

  typedef enum logic [1:0] { C_IDLE=2'd0, C_DISJ=2'd1, C_SA=2'd2, C_SB=2'd3 } cstate_e;
  cstate_e st;

  logic [BCW-1:0] k;
  wire par0 = vs0[0], par1 = vs1[0];
  wire [3:0] rh0 = vs0[4:1], rh1 = vs1[4:1];
  wire same_set = (par0 == par1);

  assign ready = (st == C_IDLE);
  assign busy  = !ready;

  // port steering + captures
  logic cap_a, cap_b;
  always_comb begin
    rd0_en = 1'b0; rd1_en = 1'b0; cap_a = 1'b0; cap_b = 1'b0;
    rd0_par = par0; rd1_par = par1;
    rd0_rh  = rh0;  rd1_rh  = rh1;
    rd0_base = k * L[4:0];
    rd1_base = rd0_base;
    rd0_slot = slot; rd1_slot = slot;
    case (st)
      C_DISJ: begin
        rd0_en = 1'b1; rd1_en = 1'b1;   // different sets, parallel
        cap_a  = 1'b1; cap_b  = 1'b1;
      end
      C_SA: begin
        rd0_en = 1'b1;                  // same set: serialize on port 0
        cap_a  = 1'b1;
      end
      C_SB: begin
        rd1_en = 1'b1; rd1_par = par0; rd1_rh = rh1;   // second operand
        cap_b  = 1'b1;
      end
      default: ;
    endcase
  end

  logic [31:0] stage_a [B][L];
  logic [31:0] stage_b [B][L];

  integer jj;
  always_ff @(posedge clk) begin
    if (rst) begin
      st <= C_IDLE; k <= '0; conflict <= 1'b0; last_gather <= 1'b0;
    end else begin
      last_gather <= 1'b0;
      if (cap_a) for (jj = 0; jj < int'(L); jj++) stage_a[int'(k)][jj] <= rd0_data[jj];
      if (cap_b) for (jj = 0; jj < int'(L); jj++) stage_b[int'(k)][jj] <= rd1_data[jj];

      case (st)
        C_IDLE: if (start) begin
          k <= '0; conflict <= same_set;
          st <= same_set ? C_SA : C_DISJ;
        end
        C_DISJ: begin
          if (k == BCW'(B-1)) begin st <= C_IDLE; last_gather <= 1'b1; end
          else k <= k + 1'b1;
        end
        C_SA: st <= C_SB;
        C_SB: begin
          if (k == BCW'(B-1)) begin st <= C_IDLE; last_gather <= 1'b1; end
          else begin k <= k + 1'b1; st <= C_SA; end
        end
        default: st <= C_IDLE;
      endcase
    end
  end

  // staged supply
  always_comb begin
    for (int j = 0; j < int'(L); j++) begin
      sup_a[j] = stage_a[$clog2(B)'(sup_beat)][j];
      sup_b[j] = stage_b[$clog2(B)'(sup_beat)][j];
    end
  end

endmodule
