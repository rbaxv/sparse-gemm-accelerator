module tb;
  reg clk = 0;
  always #5 clk = ~clk;
  reg [255:0] pins = 1, x;
  wire cr, dr, ov, done, error;
  wire [31:0] od;
  wire [ 3:0] row;
  wire [ 1:0] col;
  wire [15:0] id;
  integer checks = 0, outputs = 0, expected, job, code, pp0, pp1;
  bit sparse;
  ws_integrated dut (
      .clk(clk),
      .rst(pins[0]),
      .abort(pins[1]),
      .compute_enable(pins[2]),
      .out_ready(pins[3]),
      .cmd_valid(pins[4]),
      .cmd_first(pins[5]),
      .cmd_final(pins[6]),
      .cmd_sparse(pins[7]),
      .cmd_id(pins[23:8]),
      .cmd_m(pins[28:24]),
      .cmd_n(pins[31:29]),
      .cmd_l(pins[36:32]),
      .cmd_k(pins[50:37]),
      .cmd_offset(pins[64:51]),
      .data_valid(pins[65]),
      .data(pins[97:66]),
      .data_last(pins[98]),
      .cmd_ready(cr),
      .data_ready(dr),
      .out_valid(ov),
      .done(done),
      .error(error),
      .out_data(od),
      .out_row(row),
      .out_col(col),
      .out_id(id)
  );
  task tick();
    @(negedge clk);
    pins = x;
    @(posedge clk);
    if (pins !== x) $fatal(1, "check failed");
    if (error) $fatal(1, "check failed");
    if (ov && x[3]) begin
      if (od !== 32'(expected) || row != outputs / 2 || col != outputs % 2 || id != job)
        $fatal(1, "check failed");
      outputs++;
    end
    checks++;
    #2;
  endtask
  task command(int k, int off, int len, bit sparse);
    x[4] = 1;
    x[5] = off == 0;
    x[6] = off + len == k;
    x[7] = sparse;
    x[23:8] = 16'(job);
    x[28:24] = 2;
    x[31:29] = 2;
    x[36:32] = 5'(len);
    x[50:37] = 14'(k);
    x[64:51] = 14'(off);
    @(negedge clk);
    pins = x;
    do @(posedge clk); while (!cr);
    #2;
    x[4] = 0;
  endtask
  task word(bit [31:0] data, bit last);
    x[65] = 1;
    x[97:66] = data;
    x[98] = last;
    @(negedge clk);
    pins = x;
    do @(posedge clk); while (!dr);
    #2;
    x[65] = 0;
  endtask
  initial begin
    int k, l, g;
    bit [511:0] stream;
    bit [ 31:0] w;
    x = 1;
    tick();
    tick();
    x = 12;
    for (job = 1; job <= 12; job++) begin
      code   = (job - 1) % 6;
      sparse = job <= 6;
      case (code)
        0: begin
          pp0 = 0;
          pp1 = 1;
        end
        1: begin
          pp0 = 0;
          pp1 = 2;
        end
        2: begin
          pp0 = 0;
          pp1 = 3;
        end
        3: begin
          pp0 = 1;
          pp1 = 2;
        end
        4: begin
          pp0 = 1;
          pp1 = 3;
        end
        5: begin
          pp0 = 2;
          pp1 = 3;
        end
      endcase
      k = job == 1 ? 1 : job == 2 ? 16 : job == 3 ? 33 : 768;
      expected = 0;
      for (int t = 0; t < k; t++) begin
        if (t % 4 == pp0) expected += 16384;
        if (t % 4 == pp1) expected -= 16256;
      end
      outputs = 0;
      for (int off = 0; off < k; off += 16) begin
        l = k - off > 16 ? 16 : k - off;
        g = (l + 3) / 4;
        command(k, off, l, sparse);
        for (int a = 0; a < 2 * g; a++) word(32'h80808080, 0);
        stream = 0;
        for (int r = 0; r < 2 * g; r++) stream[r*19+:19] = 19'((code << 16) | 16'h7f80);
        if (sparse)
          for (int b = 0; b < (38 * g + 31) / 32; b++)
          word(stream[b*32+:32], b == (38 * g + 31) / 32 - 1);
        else
          for (int r = 0; r < 2 * g; r++) begin
            w = 0;
            w[pp0*8+:8] = 8'h80;
            w[pp1*8+:8] = 8'h7f;
            word(w, r == 2 * g - 1);
          end
      end
      while (outputs < 4) tick();
      tick();
    end
    $display("DIRECTED_PASS");
    $finish;

  end
  integer cyc = 0, start_c = 0, hw = 0, overlap_words = 0, fd;
  initial begin
    fd = $fopen("metrics.csv", "w");
    $fdisplay(fd, "job,cycles,host_words,overlap_words");
  end
  always @(posedge clk) begin
    cyc = cyc + 1;
    if (!pins[0] && !pins[1]) begin
      if (cr && pins[4] && pins[5]) begin
        start_c = cyc;
        hw = 0;
        overlap_words = 0;
      end
      if (dr && pins[65]) begin
        hw = hw + 1;
        if (dut.state == 5) overlap_words = overlap_words + 1;
      end
      if (ov && pins[3] && row == 1 && col == 1)
        $fdisplay(fd, "%0d,%0d,%0d,%0d", job, cyc - start_c + 1, hw, overlap_words);
      if (error) $fatal(1, "hardware error");
    end
  end
  initial begin
    #10000000;
    $fatal(1, "timeout");
  end
endmodule
