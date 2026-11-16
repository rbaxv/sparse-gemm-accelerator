module dense_os #(
    parameter integer R = 2,
    C = 2
) (
    input wire clk,
    rst,
    clear,
    advance,
    input wire [R*8-1:0] a_in,
    input wire [C*8-1:0] w_in,
    input wire [R-1:0] a_valid,
    input wire [C-1:0] w_valid,
    output wire [R*C*32-1:0] sums
);
  reg [7:0] a_pipe[0:R-1][0:C-1];
  reg [7:0] w_pipe[0:R-1][0:C-1];
  reg av_pipe[0:R-1][0:C-1];
  reg wv_pipe[0:R-1][0:C-1];
  reg signed [31:0] acc[0:R-1][0:C-1];
  for (genvar r = 0; r < R; r = r + 1) begin : rows
    for (genvar c = 0; c < C; c = c + 1) begin : cols
      wire [7:0] a = c == 0 ? a_in[r*8+:8] : a_pipe[r][c-1];
      wire [7:0] w = r == 0 ? w_in[c*8+:8] : w_pipe[r-1][c];
      wire av = c == 0 ? a_valid[r] : av_pipe[r][c-1];
      wire wv = r == 0 ? w_valid[c] : wv_pipe[r-1][c];
      wire signed [15:0] product = $signed(a) * $signed(w);
      assign sums[(r*C+c)*32+:32] = acc[r][c];
      always @(posedge clk) begin
        if (rst || clear) begin
          a_pipe[r][c] <= 0;
          w_pipe[r][c] <= 0;
          av_pipe[r][c] <= 0;
          wv_pipe[r][c] <= 0;
          acc[r][c] <= 0;
        end else if (advance) begin
          a_pipe[r][c]  <= a;
          w_pipe[r][c]  <= w;
          av_pipe[r][c] <= av;
          wv_pipe[r][c] <= wv;
          if (av && wv) acc[r][c] <= acc[r][c] + {{16{product[15]}}, product};
        end
      end
    end
  end
endmodule
