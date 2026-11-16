// Weight-stationary compute array; each PE owns exactly one signed INT8
// multiplier. Sparse mode selects two stored positions; dense mode uses four.
// Products are signed INT16 and partial sums use signed INT32 arithmetic.
// The wrapper owns packet validation and loading; this module owns PE updates.
module sparse_ws #(
    parameter R = 2,
    C = 2
) (
    input wire clk,
    rst,
    clear,
    advance,
    sparse_mode,
    input wire load,
    input wire [1:0] load_row,
    input wire [C*32-1:0] weight_in,
    input wire [C*3-1:0] code_in,
    input wire [C-1:0] weight_valid,
    input wire [R*32-1:0] a_in,
    input wire [R*4-1:0] tail_in,
    input wire [R-1:0] a_valid,
    input wire [C*32-1:0] psum_in,
    input wire [C-1:0] psum_valid,
    output wire [R*C*32-1:0] sums,
    output wire [R*C-1:0] valids,
    output reg [1:0] phase,
    output reg error
);
  reg mode;
  reg [31:0] weights[0:R-1][0:C-1], ap[0:R-1][0:C-1];
  reg [2:0] codes[0:R-1][0:C-1];
  reg resident[0:R-1][0:C-1];
  reg [3:0] masks[0:R-1][0:C-1];
  reg av[0:R-1][0:C-1], pv[0:R-1][0:C-1];
  reg signed [31:0] ps[0:R-1][0:C-1];
  wire [C-1:0] bad_lane;
  for (genvar c = 0; c < C; c = c + 1) assign bad_lane[c] = weight_valid[c] && code_in[c*3+:3] > 5;
  wire bad_load = load && !advance && phase == 0 && (load_row >= R || (mode && |bad_lane));
  always @(posedge clk) begin
    if (rst) begin
      mode  <= 1;
      phase <= 0;
      error <= 0;
    end else if (clear) begin
      mode  <= sparse_mode;
      phase <= 0;
      error <= 0;
    end else if (!error) begin
      if (bad_load) error <= 1;
      else if (advance) begin
        if (phase == (mode ? 1 : 3)) phase <= 0;
        else phase <= phase + 1'b1;
      end
    end
  end
  function [1:0] position(input [2:0] code, input second);
    case (code)
      0: position = second ? 1 : 0;
      1: position = second ? 2 : 0;
      2: position = second ? 3 : 0;
      3: position = second ? 2 : 1;
      4: position = second ? 3 : 1;
      5: position = second ? 3 : 2;
      default: position = 0;
    endcase
  endfunction
  for (genvar r = 0; r < R; r = r + 1) begin : rows
    for (genvar c = 0; c < C; c = c + 1) begin : cols
      wire [31:0] incoming_a = c == 0 ? a_in[r*32+:32] : ap[r][c-1];
      wire [3:0] incoming_mask = c == 0 ? tail_in[r*4+:4] : masks[r][c-1];
      wire incoming_av = c == 0 ? a_valid[r] : av[r][c-1];
      wire [31:0] incoming_ps = r == 0 ? psum_in[c*32+:32] : ps[r-1][c];
      wire incoming_pv = r == 0 ? psum_valid[c] : pv[r-1][c];
      wire [31:0] packet = phase == 0 ? incoming_a : ap[r][c];
      wire [3:0] mask = phase == 0 ? incoming_mask : masks[r][c];
      wire va = phase == 0 ? incoming_av : av[r][c];
      wire vp = phase == 0 ? incoming_pv : pv[r][c];
      wire [1:0] index_a = mode ? position(codes[r][c], phase[0]) : phase;
      wire signed [7:0] operand_a = packet[index_a*8+:8];
      wire signed [7:0] operand_w = weights[r][c][phase*8+:8];
      wire signed [15:0] product = operand_a * operand_w;
      wire [31:0] base = phase == 0 ? incoming_ps : ps[r][c];
      wire enable_product = va && vp && resident[r][c] && mask[index_a];
      assign sums[(r*C+c)*32+:32] = ps[r][c];
      assign valids[r*C+c] = pv[r][c];
      always @(posedge clk) begin
        if (rst) begin
          weights[r][c] <= 0;
          codes[r][c] <= 0;
          resident[r][c] <= 0;
        end
    else if(!clear && !error && load && !advance && phase==0 && !bad_load && load_row==r)begin
          weights[r][c] <= weight_in[c*32+:32];
          codes[r][c] <= code_in[c*3+:3];
          resident[r][c] <= weight_valid[c];
        end
        if (rst || clear) begin
          ap[r][c] <= 0;
          masks[r][c] <= 0;
          av[r][c] <= 0;
          pv[r][c] <= 0;
          ps[r][c] <= 0;
        end else if (advance && !error) begin
          if (phase == 0) begin
            ap[r][c] <= incoming_a;
            masks[r][c] <= incoming_mask;
            av[r][c] <= incoming_av;
            pv[r][c] <= incoming_pv;
          end
          if (!vp) ps[r][c] <= 0;
          else ps[r][c] <= base + (enable_product ? {{16{product[15]}}, product} : 32'b0);
        end
      end
    end
  end
endmodule
