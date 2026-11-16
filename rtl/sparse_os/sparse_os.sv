module sparse_os #(
    parameter integer R = 2,
    C = 2
) (
    input wire clk,
    rst,
    clear,
    advance,
    sparse_mode,
    input wire [R*32-1:0] a_in,
    input wire [C*32-1:0] w_in,
    input wire [R*4-1:0] tail_in,
    input wire [C*3-1:0] code_in,
    input wire [R-1:0] a_valid,
    input wire [C-1:0] w_valid,
    output wire [R*C*32-1:0] sums,
    output reg [1:0] phase,
    output reg error
);
  reg mode;
  reg [31:0] ap[0:R-1][0:C-1], wp[0:R-1][0:C-1];
  reg [3:0] mask[0:R-1][0:C-1];
  reg [2:0] code[0:R-1][0:C-1];
  reg av[0:R-1][0:C-1], wv[0:R-1][0:C-1];
  reg signed [31:0] acc[0:R-1][0:C-1];
  wire [C-1:0] invalid_lane;
  for (genvar lane = 0; lane < C; lane = lane + 1) begin : validate
    assign invalid_lane[lane] = w_valid[lane] && code_in[lane*3+:3] > 5;
  end
  wire bad = mode && phase == 0 && (|invalid_lane);
  always @(posedge clk) begin
    if (rst) begin
      mode  <= 1;
      phase <= 0;
      error <= 0;
    end else if (clear) begin
      mode  <= sparse_mode;
      phase <= 0;
      error <= 0;
    end else if (advance && !error) begin
      if (bad) begin
        error <= 1;
        phase <= 0;
      end else if (phase == (mode ? 1 : 3)) phase <= 0;
      else phase <= phase + 1'b1;
    end
  end
  function [1:0] position(input [2:0] c, input second);
    case (c)
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
      wire [31:0] incoming_w = r == 0 ? w_in[c*32+:32] : wp[r-1][c];
      wire [3:0] incoming_mask = c == 0 ? tail_in[r*4+:4] : mask[r][c-1];
      wire [2:0] incoming_code = r == 0 ? code_in[c*3+:3] : code[r-1][c];
      wire incoming_av = c == 0 ? a_valid[r] : av[r][c-1];
      wire incoming_wv = r == 0 ? w_valid[c] : wv[r-1][c];
      wire [31:0] aa = phase == 0 ? incoming_a : ap[r][c];
      wire [31:0] ww = phase == 0 ? incoming_w : wp[r][c];
      wire [3:0] mm = phase == 0 ? incoming_mask : mask[r][c];
      wire [2:0] cc = phase == 0 ? incoming_code : code[r][c];
      wire va = phase == 0 ? incoming_av : av[r][c];
      wire vw = phase == 0 ? incoming_wv : wv[r][c];
      wire [1:0] index_a = mode ? position(cc, phase[0]) : phase;
      wire signed [7:0] operand_a = aa[index_a*8+:8];
      wire signed [7:0] operand_w = ww[phase*8+:8];
      wire signed [15:0] product = operand_a * operand_w;
      assign sums[(r*C+c)*32+:32] = acc[r][c];
      always @(posedge clk) begin
        if (rst || clear || (advance && !error && bad)) begin
          ap[r][c]   <= 0;
          wp[r][c]   <= 0;
          mask[r][c] <= 0;
          code[r][c] <= 0;
          av[r][c]   <= 0;
          wv[r][c]   <= 0;
          acc[r][c]  <= 0;
        end else if (advance && !error) begin
          if (phase == 0) begin
            ap[r][c]   <= incoming_a;
            wp[r][c]   <= incoming_w;
            mask[r][c] <= incoming_mask;
            code[r][c] <= incoming_code;
            av[r][c]   <= incoming_av;
            wv[r][c]   <= incoming_wv;
          end
          if (va && vw && mm[index_a]) acc[r][c] <= acc[r][c] + {{16{product[15]}}, product};
        end
      end
    end
  end
endmodule
