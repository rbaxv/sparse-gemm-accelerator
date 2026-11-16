// Two output rows, four output columns, two INT8 multipliers per lane.
module rs_core (
    input wire clk,
    rst,
    clear,
    advance,
    sparse_mode,
    input wire [63:0] a_in,
    input wire [127:0] w_in,
    input wire [7:0] tail_in,
    input wire [11:0] code_in,
    input wire [1:0] a_valid,
    input wire [3:0] w_valid,
    output wire [255:0] sums,
    output reg [1:0] phase,
    output reg error
);
  reg mode;
  reg signed [31:0] acc[0:7];
  wire bad=(w_valid[0] && code_in[2:0]>5)||(w_valid[1] && code_in[5:3]>5)||
          (w_valid[2] && code_in[8:6]>5)||(w_valid[3] && code_in[11:9]>5);
  wire illegal = advance && phase == 0 && mode && bad;
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
      if (illegal) error <= 1;
      else if (advance) phase <= mode ? 0 : (phase == 0 ? 1 : 0);
    end
  end
  for (genvar r = 0; r < 2; r = r + 1) begin : rows
    for (genvar c = 0; c < 4; c = c + 1) begin : cols
      wire [1:0] p0 = mode ? position(code_in[c*3+:3], 0) : {phase[0], 1'b0};
      wire [1:0] p1 = mode ? position(code_in[c*3+:3], 1) : {phase[0], 1'b1};
      wire signed [7:0] a0 = a_in[r*32+p0*8+:8], a1 = a_in[r*32+p1*8+:8];
      wire signed [7:0] w0 = w_in[c*32+(mode ? 0 : p0)*8+:8], w1 = w_in[c*32+(mode ? 1 : p1)*8+:8];
      wire signed [15:0] product0 = a0 * w0, product1 = a1 * w1;
      wire signed [16:0] term0 = tail_in[r*4+p0] ? {product0[15], product0} : 17'sd0;
      wire signed [16:0] term1 = tail_in[r*4+p1] ? {product1[15], product1} : 17'sd0;
      wire signed [16:0] pair_sum = term0 + term1;
      assign sums[(r*4+c)*32+:32] = acc[r*4+c];
      always @(posedge clk) begin
        if (rst || clear) acc[r*4+c] <= 0;
        else if (advance && !error && !illegal && a_valid[r] && w_valid[c])
          acc[r*4+c] <= acc[r*4+c] + {{15{pair_sum[16]}}, pair_sum};
      end
    end
  end
endmodule
