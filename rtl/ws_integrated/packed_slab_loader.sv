// Converts a 32-bit host stream into 19-bit sparse records for slab_loader.
// A 64-bit reservoir allows a record to cross word boundaries. A simultaneous
// pop and host accept first removes 19 bits, then appends at after_bits.
// This transport packing is independent of arithmetic K-tail masking.
// Unused high bits in the final host word must be zero; last must match length.
module packed_slab_loader (
    input wire clk,
    rst,
    abort,
    consume,
    cmd_valid,
    input wire [4:0] cmd_m,
    cmd_l,
    input wire [2:0] cmd_n,
    input wire cmd_sparse,
    output wire cmd_ready,
    input wire data_valid,
    input wire [31:0] data,
    input wire last,
    output wire data_ready,
    ready,
    error,
    input wire [3:0] ar,
    wr,
    input wire [15:0] aa,
    input wire [7:0] wa,
    output wire [127:0] aq,
    wq,
    output wire [3:0] av,
    wv
);
  wire idle, dr, rd, err;
  reg bad, sparse;
  reg [6:0] aleft;
  reg [4:0] records_left;
  reg [3:0] beats_left;
  reg [5:0] last_bits, bits;
  reg [63:0] reservoir;
  wire weights = aleft == 0;
  wire pop = sparse && weights && records_left != 0 && bits >= 19 && dr && !bad;
  wire [5:0] after_bits = bits - (pop ? 6'd19 : 6'd0);
  wire accept = data_valid && data_ready;
  wire [8:0] record_bits = ({6'b0, cmd_n} * ((({4'b0, cmd_l} + 9'd3) >> 2))) * 9'd19;
  assign cmd_ready = idle && !bad;
  assign error = bad || err;
  assign ready = rd && !error;
  assign data_ready=dr && !bad && !rst && !abort &&
   ((!sparse || !weights) || (beats_left!=0 && after_bits<=32));
  wire direct = !sparse || !weights;
  wire dv = direct ? (data_valid && data_ready) : pop;
  wire [31:0] dw = direct ? data : {13'b0, reservoir[18:0]};
  wire dl = direct ? last : (records_left == 1);
  slab_loader storage (
      .clk(clk),
      .rst(rst),
      .abort(abort),
      .consume(consume),
      .cmd_valid(cmd_valid && cmd_ready),
      .cmd_m(cmd_m),
      .cmd_l(cmd_l),
      .cmd_n(cmd_n),
      .cmd_sparse(cmd_sparse),
      .cmd_ready(idle),
      .data_valid(dv),
      .data(dw),
      .last(dl),
      .data_ready(dr),
      .ready(rd),
      .error(err),
      .ar(ar),
      .wr(wr),
      .aa(aa),
      .wa(wa),
      .aq(aq),
      .wq(wq),
      .av(av),
      .wv(wv)
  );
  always @(posedge clk) begin
    if (rst || abort) begin
      bad <= 0;
      sparse <= 0;
      aleft <= 0;
      records_left <= 0;
      beats_left <= 0;
      last_bits <= 0;
      bits <= 0;
      reservoir <= 0;
    end else if (cmd_valid && cmd_ready) begin
      sparse <= cmd_sparse;
      aleft <= cmd_m * ((cmd_l + 7'd3) >> 2);
      records_left <= cmd_n * ((cmd_l + 7'd3) >> 2);
      beats_left <= (record_bits + 9'd31) >> 5;
      last_bits <= record_bits[4:0] == 0 ? 6'd32 : {1'b0, record_bits[4:0]};
      bits <= 0;
      reservoir <= 0;
    end else begin
      if (accept && aleft != 0) aleft <= aleft - 1'b1;
      if (sparse && weights) begin
        if (pop) begin
          reservoir <= reservoir >> 19;
          bits <= after_bits;
          records_left <= records_left - 1'b1;
        end
        if (accept) begin
          if (last != (beats_left == 1) || (beats_left == 1 && (data >> last_bits) != 0)) bad <= 1;
          reservoir <= (pop ? (reservoir >> 19) : reservoir) | ({32'b0, data} << after_bits);
          bits <= after_bits + 6'd32;
          beats_left <= beats_left - 1'b1;
        end
      end
    end
  end
endmodule
