// Real Accellera UVM test using factory registration, config_db and phases.
// This compact environment implements driver/monitor/scoreboard roles as tasks
// inside one uvm_test; it does not claim a separate reusable agent hierarchy.
// watch(): accepted-pin reconstruction and coordinate-derived per-PE checking.
// tick(): output scoreboard. hit(): explicit bin counts with cycle witnesses.
// Full closure requires both the completion marker and the strict Python runner.
`timescale 1ns / 1ps
interface integrated_if (
    input logic clk
);
  logic [255:0] pins = 0;
  wire  [255:0] observed;
  wire cr, dr, ov, done, error;
  wire [31:0] od;
  wire [ 3:0] row;
  wire [ 1:0] col;
  wire [15:0] id;
  wire [ 4:0] state;
  wire adv, enq, deq;
  wire [  1:0] phase;
  wire [  5:0] slot;
  wire [511:0] sums;
  wire [15:0] valids, ena;
  wire [127:0] opa, opw;
  wire [255:0] prod;
endinterface
package integrated_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  class integrated_test extends uvm_test;
    `uvm_component_utils(integrated_test)
    virtual integrated_if v;
    bit [255:0] x;
    int checks = 0, outputs = 0, expected, job, code, pp0, pp1, w0, w1, tm = 4, tn = 4;
    bit sparse;
    bit matrix_mode = 0;
    int signed expected_matrix[16][4];
    int am[2][16][16], wm[2][16][4], cm[2][4][4], prior[16][4];
    int dm[2], dn[2], dl[2], dg[2], di[2], dwords[2], expected_words[2], owners[2];
    bit ds[2];
    bit [511:0] transport[2];
    int producer = 0, consumer = 0, loadbuf = 0, pending = 0;
    int
        monitored = 0,
        mac_checks = 0,
        sum_checks = 0,
        accepted_words = 0,
        accepted_cmds = 0,
        coverage[512],
        witness[512];
    int fd;
    bit monitor_on = 0, allow_error = 0;
    bit held = 0;
    bit [53:0] held_value;
    function int signed byteval(bit [31:0] word, int index);
      return int'($signed(word[index*8+:8]));
    endfunction
    function int position(int c, int q);
      case (c)
        0: return q ? 1 : 0;
        1: return q ? 2 : 0;
        2: return q ? 3 : 0;
        3: return q ? 2 : 1;
        4: return q ? 3 : 1;
        5: return q ? 3 : 2;
        default: return 0;
      endcase
    endfunction
    function void hit(int bin);
      coverage[bin]++;
      if (witness[bin] == 0) witness[bin] = monitored;
    endfunction
    task watch();
      bit [255:0] pins;
      bit advance;
      int st, sl, ph, b, g, i, c, j, k, index, code, rows, cols, len;
      int signed val, aa, ww;
      bit valid, enabled;
      bit [511:0] exp;
      bit [ 15:0] expvalid;
      forever begin
        @(posedge v.clk);
        if (monitor_on) begin
          monitored++;
          pins = v.observed;
          st = v.state;
          advance = v.adv;
          sl = v.slot;
          ph = v.phase;
          b = consumer;
          if (pins !== x) `uvm_fatal("INTENT_ALL", "intended/observed pins mismatch")
          if (pins[0] || pins[1]) begin
            if (v.cr || v.dr || v.ov)
              `uvm_fatal("CANCEL_PINS", "transfer exposed during cancellation")
            producer = 0;
            consumer = 0;
            pending = 0;
            owners[0] = 0;
            owners[1] = 0;
            held = 0;
            foreach (prior[r, col]) prior[r][col] = 0;
            hit(pins[0] ? 0 : 1);
          end else if (!allow_error) begin
            if (v.error) `uvm_fatal("UNEXPECTED_ERROR", "unexpected error")
            if (held && (!v.ov || {v.id, v.row, v.col, v.od} !== held_value))
              `uvm_fatal("BACKPRESSURE", "output changed while blocked")
            held = v.ov && !pins[3];
            held_value = {v.id, v.row, v.col, v.od};
            if (held) hit(2);
            if (v.cr && pins[4]) begin
              b = producer;
              if (owners[b] != 0 || v.enq !== 1'(b))
                `uvm_fatal("OWNERSHIP", "overwritten descriptor/bank")
              dm[b] = int'(pins[28:24]);
              dn[b] = int'(pins[31:29]);
              dl[b] = int'(pins[36:32]);
              ds[b] = pins[7];
              dg[b] = (dl[b] + 3) / 4;
              di[b] = 0;
              dwords[b] = 0;
              transport[b] = 0;
              expected_words[b]=dm[b]*dg[b]+(ds[b]?(19*dn[b]*dg[b]+31)/32:dn[b]*dg[b]);
              foreach (am[bb, r, t]) if (bb == b) am[bb][r][t] = 0;
              foreach (wm[bb, t, col]) if (bb == b) wm[bb][t][col] = 0;
              if (pins[5]) foreach (prior[r, col]) prior[r][col] = 0;
              owners[b] = 1;
              loadbuf   = b;
              producer  = 1 - producer;
              pending++;
              accepted_cmds++;
              if (pending == 2) hit(3);
              if (pending > 2) `uvm_fatal("PENDING", "too many descriptors")
            end
            if (v.dr && pins[65]) begin
              b = loadbuf;
              if (owners[b] != 1) `uvm_fatal("LOAD_OWNER", "wrong owner")
              index = di[b];
              accepted_words++;
              if (st >= 2 && st <= 9) hit(4);
              if (pins[98] != (index == expected_words[b] - 1))
                `uvm_fatal("LAST", "wrong payload last")
              if (index < dm[b] * dg[b]) begin
                i = index / dg[b];
                g = index % dg[b];
                for (int q = 0; q < 4; q++)
                if (4 * g + q < dl[b]) am[b][i][4*g+q] = byteval(pins[97:66], q);
              end else begin
                j = index - dm[b] * dg[b];
                if (ds[b]) transport[b][j*32+:32] = pins[97:66];
                else begin
                  c = j / dg[b];
                  g = j % dg[b];
                  for (int q = 0; q < 4; q++)
                  if (4 * g + q < dl[b]) wm[b][4*g+q][c] = byteval(pins[97:66], q);
                end
              end
              di[b]++;
              if (di[b] == expected_words[b]) begin
                if (ds[b]) begin
                  if ((transport[b] >> (19 * dg[b] * dn[b])) != 0)
                    `uvm_fatal("PADDING", "nonzero padding")
                  for (int col = 0; col < dn[b]; col++)
                  for (int gg = 0; gg < dg[b]; gg++) begin
                    automatic bit [18:0] rec = transport[b][(col*dg[b]+gg)*19+:19];
                    code = int'(rec[18:16]);
                    if (code > 5) `uvm_fatal("METADATA", "illegal code escaped negative suite")
                    cm[b][gg][col] = code;
                    hit(10 + code);
                    if (((col * dg[b] + gg) * 19) % 32 > 13) hit(5);
                    for (int q = 0; q < 2; q++) begin
                      k = 4 * gg + position(code, q);
                      if (k < dl[b]) wm[b][k][col] = byteval({13'b0, rec}, q);
                    end
                  end
                end
                owners[b] = 2;
              end
            end
            b = consumer;
            if (st == 2) begin
              if (owners[b] != 2 || v.deq !== 1'(b))
                `uvm_fatal("COMPUTE_OWNER", "compute before complete payload")
              owners[b] = 3;
            end
            if (advance) begin
              if (owners[b] != 3) `uvm_fatal("ADVANCE_OWNER", "advance without compute ownership")
              exp = 0;
              expvalid = 0;
              rows = dm[b];
              cols = dn[b];
              len = dl[b];
              hit(ds[b] ? 6 : 7);
              for (int r = 0; r < 4; r++)
              for (int col = 0; col < 4; col++) begin
                i = sl - r - col;
                valid = i >= 0 && i < rows && col < cols;
                k = 4 * r + (ds[b] ? position(cm[b][r][col], ph) : ph);
                expvalid[r*4+col] = valid;
                enabled = valid && r < dg[b] && k < len;
                if (valid && r < dg[b] && k >= len) hit(16);
                if (v.ena[r*4+col] !== enabled)
                  `uvm_fatal("PE_ENABLE", "tail/operand identity mismatch")
                aa = int'($signed(v.opa[(r*4+col)*8+:8]));
                ww = int'($signed(v.opw[(r*4+col)*8+:8]));
                if (v.prod[(r*4+col)*16+:16] !== 16'(aa * ww))
                  `uvm_fatal("PRODUCT", "multiplier result mismatch")
                mac_checks++;
                if (enabled) begin
                  if (aa != am[b][i][k] || ww != wm[b][k][col])
                    `uvm_fatal("OPERAND", "operand coordinate mismatch")
                  hit(32 + r * 4 + col);
                  if (ds[b]) hit(128 + (r * 4 + col) * 12 + cm[b][r][col] * 2 + ph);
                  if (ww == 0) hit(8);
                  if (aa == -128 && ww == -128) hit(9);
                end
                val = 0;
                if (valid) begin
                  val = prior[i][col];
                  for (int t = 0; t < 4 * r && t < len; t++) val += am[b][i][t] * wm[b][t][col];
                  for (int q = 0; q <= ph; q++) begin
                    j = 4 * r + (ds[b] ? position(cm[b][r][col], q) : q);
                    if (j < len) val += am[b][i][j] * wm[b][j][col];
                  end
                end
                exp[(r*4+col)*32+:32] = 32'(val);
              end
              #1;
              if (v.valids !== expvalid) `uvm_fatal("PE_VALID", "PE valid alignment mismatch")
              if (v.sums !== exp) `uvm_fatal("PE_ACCUMULATION", "coordinate sum mismatch")
              sum_checks += 16;
            end
            if (st == 5 && !advance) begin
              exp = v.sums;
              #1;
              if (v.sums !== exp) `uvm_fatal("STALL_STATE", "accumulator changed under stall")
              hit(17);
            end
            if (st == 10) begin
              for (int rr = 0; rr < dm[b]; rr++)
              for (int col = 0; col < dn[b]; col++)
              for (int t = 0; t < dl[b]; t++) prior[rr][col] += am[b][rr][t] * wm[b][t][col];
              owners[b] = 0;
              pending--;
              consumer = 1 - consumer;
            end
          end
        end
      end
    endtask
    function new(string name = "integrated_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual integrated_if)::get(this, "", "v", v))
        `uvm_fatal("VIF", "missing")
    endfunction
    task gates();
      int cy = 0;
      forever begin
        @(negedge v.clk);
        #1;
        cy++;
        if (monitor_on && !$test$plusargs("NOSTALL")) begin
          x[2] = cy % 7 < 5;
          x[3] = cy % 11 >= 4;
          v.pins[2] = x[2];
          v.pins[3] = x[3];
        end
      end
    endtask
    task recover(bit aborting);
      x = 0;
      x[aborting ? 1 : 0] = 1;
      tick();
      tick();
      x = 12;
      allow_error = 0;
      tick();
    endtask
    task tick();
      @(negedge v.clk);
      v.pins = x;
      @(posedge v.clk);
      if (v.pins !== x) `uvm_fatal("INTENT", "pin mismatch")
      if (v.error && !allow_error) `uvm_fatal("ERROR", "unexpected hardware error")
      if (v.ov && x[3]) begin
        if(v.od!==32'(matrix_mode?expected_matrix[outputs/tn][outputs%tn]:expected) || v.row!=outputs/tn || v.col!=outputs%tn || v.id!=job)
          `uvm_fatal("OUTPUT", "GEMM/order mismatch")
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
      x[28:24] = 5'(tm);
      x[31:29] = 3'(tn);
      x[36:32] = 5'(len);
      x[50:37] = 14'(k);
      x[64:51] = 14'(off);
      @(negedge v.clk);
      v.pins = x;
      do @(posedge v.clk); while (!v.cr);
      #2;
      x[4] = 0;
    endtask
    task word(bit [31:0] data, bit last);
      x[65] = 1;
      x[97:66] = data;
      x[98] = last;
      @(negedge v.clk);
      v.pins = x;
      do @(posedge v.clk); while (!v.dr && !v.error);
      #2;
      x[65] = 0;
    endtask
    task restart_job();
      bit [95:0] stream;
      job++;
      tm = 4;
      tn = 4;
      outputs = 0;
      expected = 16384;
      command(1, 0, 1, 1);
      repeat (4) word(32'h00000080, 0);
      stream = 0;
      for (int c = 0; c < 4; c++) stream[c*19+:19] = 19'h00080;
      for (int b = 0; b < 3; b++) word(stream[b*32+:32], b == 2);
      while (outputs < tm * tn) tick();
      tick();
      hit(80);
    endtask
    task varied_job(bit dense);
      int signed aa[4][33], ww[33][4];
      int codes[9][4];
      int idx, g, len;
      bit [511:0] stream;
      bit [ 31:0] value;
      bit [ 18:0] rec;
      job++;
      tm = 4;
      tn = 4;
      outputs = 0;
      matrix_mode = 1;
      foreach (ww[k, c]) ww[k][c] = 0;
      for (int i = 0; i < 4; i++) for (int k = 0; k < 33; k++) aa[i][k] = i * 7 - k;
      for (int gg = 0; gg < 9; gg++)
        for (int c = 0; c < 4; c++) begin
          codes[gg][c] = (gg + c) % 6;
          idx = 4 * gg + position(codes[gg][c], 0);
          if (idx < 33) ww[idx][c] = -(3 + c + gg);
          idx = 4 * gg + position(codes[gg][c], 1);
          if (idx < 33) ww[idx][c] = 5 + c - gg;
        end
      for (int i = 0; i < 4; i++)
        for (int c = 0; c < 4; c++) begin
          expected_matrix[i][c] = 0;
          for (int k = 0; k < 33; k++) expected_matrix[i][c] += aa[i][k] * ww[k][c];
        end
      for (int off = 0; off < 33; off += 16) begin
        len = 33 - off > 16 ? 16 : 33 - off;
        g   = (len + 3) / 4;
        command(33, off, len, !dense);
        for (int i = 0; i < 4; i++)
        for (int gg = 0; gg < g; gg++) begin
          value = 0;
          for (int q = 0; q < 4; q++)
          if (off + gg * 4 + q < 33) value[q*8+:8] = 8'(aa[i][off+gg*4+q]);
          word(value, 0);
        end
        stream = 0;
        for (int c = 0; c < 4; c++)
        for (int gg = 0; gg < g; gg++) begin
          rec = 19'(codes[off/4+gg][c] << 16);
          for (int q = 0; q < 2; q++) begin
            idx = off + 4 * gg + position(codes[off/4+gg][c], q);
            rec[q*8+:8] = idx < 33 ? 8'(ww[idx][c]) : 8'b0;
          end
          stream[(c*g+gg)*19+:19] = rec;
          if (dense) begin
            value = 0;
            for (int q = 0; q < 4; q++)
            if (off + gg * 4 + q < 33) value[q*8+:8] = 8'(ww[off+gg*4+q][c]);
            word(value, c == 3 && gg == g - 1);
          end
        end
        if (!dense)
          for (int b = 0; b < (76 * g + 31) / 32; b++)
          word(stream[b*32+:32], b == (76 * g + 31) / 32 - 1);
      end
      while (outputs < 16) tick();
      tick();
      matrix_mode = 0;
      hit(dense ? 84 : 83);
    endtask
    task run_phase(uvm_phase phase);
      int k, l, g;
      bit [511:0] stream;
      bit [ 31:0] w;
      phase.raise_objection(this);
      x = 1;
      v.pins = x;
      monitor_on = 1;
      fork
        watch();
        gates();
      join_none
      tick();
      tick();
      x = 12;
      for (job = 1; job <= 20; job++) begin
        code = (job - 1) % 6;
        sparse = job <= 6 || job > 12;
        tm = job <= 13 ? 4 : (job % 4 == 0 ? 16 : job % 4 == 1 ? 1 : job % 4 == 2 ? 2 : 7);
        tn = job <= 13 ? 4 : 1 + job % 4;
        w0 = job % 3 == 0 ? 0 : -128;
        w1 = 127;
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
        k = job >= 19 ? 8192 : job == 1 ? 1 : job == 2 ? 16 : job == 3 ? 33 : 768;
        expected = 0;
        for (int t = 0; t < k; t++) begin
          if (t % 4 == pp0) expected += (-128 * w0);
          if (t % 4 == pp1) expected += (-128 * w1);
        end
        outputs = 0;
        for (int off = 0; off < k; off += 16) begin
          l = k - off > 16 ? 16 : k - off;
          g = (l + 3) / 4;
          command(k, off, l, sparse);
          for (int a = 0; a < tm * g; a++) word(32'h80808080, 0);
          stream = 0;
          for (int r = 0; r < tn * g; r++)
          stream[r*19+:19] = 19'((code << 16) | ((w1 & 255) << 8) | (w0 & 255));
          if (sparse)
            for (int b = 0; b < (19 * tn * g + 31) / 32; b++)
            word(stream[b*32+:32], b == (19 * tn * g + 31) / 32 - 1);
          else
            for (int r = 0; r < tn * g; r++) begin
              w = 0;
              w[pp0*8+:8] = 8'(w0);
              w[pp1*8+:8] = 8'(w1);
              word(w, r == tn * g - 1);
            end
        end
        while (outputs < tm * tn) tick();
        tick();
      end
      varied_job(0);
      varied_job(1);
      // Expected-error cases; recovery reset/abort must restore readiness.
      for (int neg = 0; neg < 9; neg++) begin
        recover(neg % 2);
        tm = 4;
        tn = 4;
        allow_error = 1;
        job++;
        outputs = 0;
        if (neg == 0) begin
          x[4] = 1;
          x[5] = 1;
          x[6] = 1;
          x[7] = 1;
          x[28:24] = 0;
          x[31:29] = 4;
          x[36:32] = 16;
          x[50:37] = 16;
          x[64:51] = 0;
          @(negedge v.clk);
          v.pins = x;
          do @(posedge v.clk); while (!v.cr);
          #2;
          x[4] = 0;
        end else if (neg >= 6) begin
          command(32, 0, 16, 1);
          repeat (16) word(32'h80808080, 0);
          stream = 0;
          for (int rr = 0; rr < 16; rr++) stream[rr*19+:19] = 19'h07f80;
          for (int beat = 0; beat < 10; beat++) word(stream[beat*32+:32], beat == 9);
          x[4] = 1;
          x[5] = 0;
          x[6] = 1;
          x[7] = neg == 8 ? 0 : 1;
          x[64:51] = neg == 6 ? 0 : 16;
          x[23:8] = 16'(neg == 7 ? job + 1 : job);
          @(negedge v.clk);
          v.pins = x;
          do @(posedge v.clk); while (!v.cr);
          #2;
          x[4] = 0;
        end else begin
          command(16, 0, 16, 1);
          for (int a = 0; a < 16; a++) if (!v.error) word(32'h80808080, neg == 5 && a == 0);
          stream = 0;
          for (int rr = 0; rr < 16; rr++) stream[rr*19+:19] = 19'h07f80;
          if (neg == 1 || neg == 2) stream[18:16] = 3'(neg + 5);
          if (neg == 3) stream[319] = 1;
          for (int beat = 0; beat < 10; beat++)
          if (!v.error) word(stream[beat*32+:32], beat == 9 && neg != 4);
        end
        repeat (6) tick();
        if (!v.error) `uvm_fatal("NEGATIVE", "expected error missing")
        hit(64 + neg);
        recover(neg % 2);
        if (v.error || !v.cr || v.ov) `uvm_fatal("RECOVERY", "not idle after reset/abort")
        restart_job();
      end
      for (int cancel = 0; cancel < 4; cancel++) begin
        recover(cancel % 2);
        tm = 4;
        tn = 4;
        job++;
        outputs = 0;
        command(32, 0, 16, 1);
        repeat (16) word(32'h80808080, 0);
        stream = 0;
        for (int rr = 0; rr < 16; rr++) stream[rr*19+:19] = 19'h07f80;
        for (int beat = 0; beat < 10; beat++) word(stream[beat*32+:32], beat == 9);
        command(32, 16, 16, 1);
        if (cancel >= 2) begin
          repeat (16) word(32'h80808080, 0);
          word(32'h00007f80, 0);
        end else word(32'h80808080, 0);
        recover(cancel % 2);
        restart_job();
        hit(90 + cancel);
      end
      `uvm_info("INTEGRATED_PASS", $sformatf("tick_checks=%0d final_job_id=%0d", checks, job),
                UVM_LOW)
      if (pending != 0 || mac_checks == 0 || sum_checks == 0)
        `uvm_fatal("CLOSURE", "pending or empty work")
      for (int bin = 0; bin <= 17; bin++)
        if (coverage[bin] == 0 && !((bin == 2 || bin == 17) && $test$plusargs("NOSTALL")))
          `uvm_fatal("COVERAGE", "missing protocol bin")
      for (int bin = 32; bin < 48; bin++)
        if (coverage[bin] == 0) `uvm_fatal("COVERAGE", "missing PE operand witness")
      for (int bin = 128; bin < 320; bin++)
        if (coverage[bin] == 0) `uvm_fatal("COVERAGE", "missing PE metadata phase witness")
      for (int bin = 64; bin <= 72; bin++)
        if (coverage[bin] == 0) `uvm_fatal("COVERAGE", "missing negative/recovery witness")
      for (int bin = 80; bin <= 84; bin++)
        if (bin != 81 && bin != 82 && coverage[bin] == 0)
          `uvm_fatal("COVERAGE", "missing cancellation restart witness")
      for (int bin = 90; bin < 94; bin++)
        if (coverage[bin] == 0) `uvm_fatal("COVERAGE", "partial payload cancellation missing")
      fd = $fopen("coverage.csv", "w");
      $fdisplay(fd, "bin,count,witness_cycle");
      for (int b = 0; b < 512; b++)
        if (coverage[b]) $fdisplay(fd, "%0d,%0d,%0d", b, coverage[b], witness[b]);
      $fclose(fd);
      `uvm_info("MONITORS", $sformatf("edges=%0d cmds=%0d words=%0d products=%0d sums=%0d",
                                      monitored, accepted_cmds, accepted_words, mac_checks,
                                      sum_checks), UVM_LOW)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
module tb;
  import uvm_pkg::*;
  import integrated_pkg::*;
  bit clk = 0;
  always #5 clk = ~clk;
  integrated_if bus (clk);
  wire [255:0] x = bus.pins ^ (($test$plusargs(
      "MUTATE"
  ) && bus.pins[65]) ? (256'b1 << 82) : 256'b0);
  assign bus.observed = x;
  ws_integrated dut (
      .clk(clk),
      .rst(x[0]),
      .abort(x[1]),
      .compute_enable(x[2]),
      .out_ready(x[3]),
      .cmd_valid(x[4]),
      .cmd_first(x[5]),
      .cmd_final(x[6]),
      .cmd_sparse(x[7]),
      .cmd_id(x[23:8]),
      .cmd_m(x[28:24]),
      .cmd_n(x[31:29]),
      .cmd_l(x[36:32]),
      .cmd_k(x[50:37]),
      .cmd_offset(x[64:51]),
      .data_valid(x[65]),
      .data(x[97:66]),
      .data_last(x[98]),
      .cmd_ready(bus.cr),
      .data_ready(bus.dr),
      .out_valid(bus.ov),
      .done(bus.done),
      .error(bus.error),
      .out_data(bus.od),
      .out_row(bus.row),
      .out_col(bus.col),
      .out_id(bus.id)
  );
  assign bus.state = dut.state;
  assign bus.adv = dut.core_advance;
  assign bus.enq = dut.enq;
  assign bus.deq = dut.deq;
  assign bus.phase = dut.core_phase;
  assign bus.slot = dut.slot;
  assign bus.sums = dut.sums;
  assign bus.valids = dut.core_valids;
  for (genvar r = 0; r < 4; r++)
  for (genvar c = 0; c < 4; c++) begin
    assign bus.opa[(r*4+c)*8+:8] = dut.core.rows[r].cols[c].operand_a;
    assign bus.opw[(r*4+c)*8+:8] = dut.core.rows[r].cols[c].operand_w;
    assign bus.prod[(r*4+c)*16+:16] = dut.core.rows[r].cols[c].product;
    assign bus.ena[r*4+c] = dut.core.rows[r].cols[c].enable_product;
  end
  initial begin
    uvm_config_db#(virtual integrated_if)::set(null, "*", "v", bus);
    run_test("integrated_test");
  end
  initial begin
    #10000000;
    $fatal(1, "TIMEOUT");
  end
endmodule
