// Finite slab-load boundary. Compute controller and P storage are separate.
module slab_loader (
    input wire clk,
    rst,
    abort,
    consume,
    input wire cmd_valid,
    input wire [4:0] cmd_m,
    cmd_l,
    input wire [2:0] cmd_n,
    input wire cmd_sparse,
    output wire cmd_ready,
    input wire data_valid,
    input wire [31:0] data,
    input wire last,
    output wire data_ready,
    output wire ready,
    output wire error,
    input wire [3:0] ar,
    wr,
    input wire [15:0] aa,
    input wire [7:0] wa,
    output reg [127:0] aq,
    wq,
    output reg [3:0] av,
    wv
);
  localparam IDLE = 0, LOAD = 1, READY = 2, ERROR = 3;
  reg [1:0] state;
  reg [4:0] m, l, row;
  reg [2:0] n, groups, g, col;
  reg sparse, weights;
  reg [31:0] amem[0:3][0:15], wmem[0:3][0:3];
  wire terminal = weights && col == n - 1 && g == groups - 1;
  wire bad_word = weights && sparse && (|data[31:19] || data[18:16] > 5);
  assign cmd_ready = state == IDLE;
  assign data_ready = state == LOAD;
  assign ready = state == READY;
  assign error = state == ERROR;
  always @(posedge clk) begin
    if (rst || abort) begin
      state <= IDLE;
      m <= 0;
      l <= 0;
      n <= 0;
      groups <= 0;
      g <= 0;
      row <= 0;
      col <= 0;
      sparse <= 0;
      weights <= 0;
      aq <= 0;
      wq <= 0;
      av <= 0;
      wv <= 0;
    end else begin
      av <= 0;
      wv <= 0;
      if (state == IDLE && cmd_valid) begin
        if (cmd_m < 1 || cmd_m > 16 || cmd_n < 1 || cmd_n > 4 || cmd_l < 1 || cmd_l > 16)
          state <= ERROR;
        else begin
          state <= LOAD;
          m <= cmd_m;
          n <= cmd_n;
          l <= cmd_l;
          groups <= ({1'b0, cmd_l} + 3) >> 2;
          sparse <= cmd_sparse;
          g <= 0;
          row <= 0;
          col <= 0;
          weights <= 0;
        end
      end
      if (state == LOAD && data_valid) begin
        if (bad_word || last != terminal) state <= ERROR;
        else begin
          if (weights) wmem[col][g] <= data;
          else amem[row[1:0]][{row[3:2], 2'b00}+g] <= data;
          if (terminal) state <= READY;
          else if (g == groups - 1) begin
            g <= 0;
            if (weights) col <= col + 1'b1;
            else if (row == m - 1) begin
              weights <= 1;
              col <= 0;
            end else row <= row + 1'b1;
          end else g <= g + 1'b1;
        end
      end
      if (state == READY) begin
        if (consume) state <= IDLE;
        else
          for (integer b = 0; b < 4; b = b + 1) begin
            if (ar[b]) begin
              aq[b*32+:32] <= amem[b][aa[b*4+:4]];
              av[b] <= 1;
            end
            if (wr[b]) begin
              wq[b*32+:32] <= wmem[b][wa[b*2+:2]];
              wv[b] <= 1;
            end
          end
      end
    end
  end
endmodule
