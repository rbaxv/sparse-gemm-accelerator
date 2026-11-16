`timescale 1ns / 1ps
interface wrapper_if (
    input logic clk
);
  logic [255:0] pins = 0;
  logic trace_enable = 0;
  wire cr, dr, ov, done, error;
  wire [31:0] od;
  wire [3:0] row;
  wire [1:0] col;
  wire [15:0] id;
  wire [4:0] state;
  wire adv;
  wire [511:0] sums;
  wire [127:0] a, w;
  wire [3:0] av, wv;
endinterface
package wrapper_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  class wrapper_test extends uvm_test;
    `uvm_component_utils(wrapper_test)
    virtual wrapper_if v;
    bit [255:0] intended;
    int checked = 0, fd;
    bit checking = 0;
    bit native_mode;
    int m, n, l, k, offset, group_count, load_index, compute_edge, tile, outputs;
    bit sparse;
    int signed A[16][16], W[16][4], local_sum[4][4];
    int codes[4][4];
    bit [31:0] raw_a[16][4], raw_w[4][4];
    bit [15:0] expected_id;
    bit [2047:0] golden;
    bit golden_valid = 0;
    bit held = 0;
    bit [53:0] held_output;
    int
        count_advance = 0,
        count_load = 0,
        count_stall = 0,
        count_output_stall = 0,
        count_reset = 0,
        count_error = 0,
        count_continue = 0;
    bit cov_rst, cov_abort, cov_ce, cov_ready;
    int epoch = 0;
    bit service;
    function bit host_open();
      return !service || ((checked + 1 - epoch) % 5 < 3);
    endfunction
    covergroup controls;
      reset_cp: coverpoint cov_rst {bins lo = {0}; bins hi = {1};}
      abort_cp: coverpoint cov_abort {bins lo = {0}; bins hi = {1};}
      enable_cp: coverpoint cov_ce {bins lo = {0}; bins hi = {1};}
      output_cp: coverpoint cov_ready {bins lo = {0}; bins hi = {1};}
    endgroup
    function new(string name = "wrapper_test", uvm_component parent = null);
      super.new(name, parent);
      controls = new;
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual wrapper_if)::get(this, "", "v", v))
        `uvm_fatal("VIF", "Missing interface")
      native_mode = $test$plusargs("NATIVE");
      service = $test$plusargs("SERVICE");
      fd = $fopen("observed.csv", "w");
      $fdisplay(
          fd,
          "cycle,pins,pre_state,pre_cr,pre_dr,pre_ov,pre_od,pre_row,pre_col,pre_id,pre_done,pre_error,advance,state,sums,a,w,av,wv,cr,dr,ov,od,row,col,id,done,error");
    endfunction
    function int byte_signed(bit [31:0] word, int i);
      return int'($signed(word[i*8+:8]));
    endfunction
    function int position(int code, int p);
      case (code)
        0: return p ? 1 : 0;
        1: return p ? 2 : 0;
        2: return p ? 3 : 0;
        3: return p ? 2 : 1;
        4: return p ? 3 : 1;
        5: return p ? 3 : 2;
        default: return 0;
      endcase
    endfunction
    task tick(bit [255:0] pins);
      @(negedge v.clk);
      pins[2] = !service || ((checked + 1 - epoch) % 7 < 5);
      pins[3] = !service || ((checked + 1 - epoch) % 11 >= 4);
      intended = pins;
      v.pins = pins;
      checking = 1;
      v.trace_enable = 1;
      @(posedge v.clk);
      #2;
      checking = 0;
      v.trace_enable = 0;
    endtask
    task monitor();
      bit [255:0] x;
      bit [  4:0] st;
      bit precr, predr, preov, predone, preerr, advance;
      bit [31:0] preod;
      bit [ 3:0] prer;
      bit [ 1:0] prec;
      bit [15:0] preid;
      int r, c, g, pos, ph, coord, p, word_index;
      bit [ 31:0] word;
      bit [511:0] expected;
      forever begin
        @(posedge v.clk);
        if (checking) begin
          x = v.pins;
          st = v.state;
          precr = v.cr;
          predr = v.dr;
          preov = v.ov;
          preod = v.od;
          prer = v.row;
          prec = v.col;
          preid = v.id;
          predone = v.done;
          preerr = v.error;
          advance = v.adv;
          if (x !== intended) `uvm_fatal("INTENT", "Observed inputs differ from intended pins")
          checked++;
          cov_rst = x[0];
          cov_abort = x[1];
          cov_ce = x[2];
          cov_ready = x[3];
          controls.sample();
          if (x[0] || x[1]) begin
            compute_edge = 0;
            tile = 0;
            outputs = 0;
            held = 0;
            count_reset++;
          end else begin
            if (held && (!preov || {preid, prer, prec, preod} !== held_output))
              `uvm_fatal("OUTPUT_STABLE", "Blocked output changed")
            held = preov && !x[3];
            held_output = {preid, prer, prec, preod};
            if (held) count_output_stall++;
            if (preov && x[3]) begin
              if(!golden_valid || preid!=expected_id || prer!=outputs/n || prec!=outputs%n || preod!==golden[outputs*32+:32])
                `uvm_fatal("OUTPUT", "Final matrix, ordering or unexpected output mismatch")
              outputs++;
            end
            if (precr && x[4]) begin
              expected_id = x[23:8];
              m = int'(x[28:24]);
              n = int'(x[31:29]);
              l = int'(x[36:32]);
              k = int'(x[50:37]);
              offset = int'(x[64:51]);
              sparse = x[7];
              group_count = (l + 3) / 4;
              load_index = 0;
              tile = 0;
              compute_edge = 0;
              if (x[5]) outputs = 0;
              else count_continue++;
              foreach (A[r, c]) A[r][c] = 0;
              foreach (W[r, c]) W[r][c] = 0;
            end
            if (predr && x[65]) begin
              word = x[97:66];
              word_index = load_index;
              load_index++;
              count_load++;
              if (word_index < m * group_count) begin
                r = word_index / group_count;
                g = word_index % group_count;
                raw_a[r][g] = word;
                for (p = 0; p < 4; p++) A[r][g*4+p] = byte_signed(word, p);
              end else begin
                word_index -= m * group_count;
                c = word_index / group_count;
                g = word_index % group_count;
                raw_w[g][c] = word;
                codes[g][c] = int'(word[18:16]);
                if (sparse) begin
                  for (p = 0; p < 2; p++) W[g*4+position(codes[g][c], p)][c] = byte_signed(word, p);
                end else for (p = 0; p < 4; p++) W[g*4+p][c] = byte_signed(word, p);
              end
            end
            if (st == 2) begin
              compute_edge = 0;
              foreach (local_sum[r, c]) local_sum[r][c] = 0;
            end
            if (advance) begin
              count_advance++;
              ph = sparse ? 1 : 2;
              for (r = 0; r < 4; r++) begin
                coord = compute_edge / ph;
                g = coord;
                if(v.av[r]!=(r<2 && tile+r<m && coord>=0 && coord<(native_mode?l:group_count)))
                  `uvm_fatal("ALIGN", "A valid misalignment")
                if (v.wv[r] != (r < n && coord >= 0 && coord < (native_mode ? l : group_count)))
                  `uvm_fatal("ALIGN", "W valid misalignment")
                if (v.av[r] && v.a[r*32+:32] !== raw_a[tile+r][g])
                  `uvm_fatal("ALIGN", "A packet misalignment")
                if (v.wv[r] && v.w[r*32+:32] !== raw_w[g][r])
                  `uvm_fatal("ALIGN", "W packet misalignment")
              end
              for (r = 0; r < 2; r++)
              for (c = 0; c < 4; c++) begin
                coord = compute_edge / ph;
                if (tile + r < m && c < n && coord < group_count) begin
                  for (p = 0; p < 2; p++) begin
                    pos = 4 * coord +
                        (sparse ? position(codes[coord][c], p) : 2 * (compute_edge % ph) + p);
                    if (pos < l) local_sum[r][c] += A[tile+r][pos] * W[pos][c];
                  end
                end
              end
              compute_edge++;
            end else if (st == 5) count_stall++;
            if (preerr) count_error++;
          end
          #1;
          if (!x[0] && !x[1] && (st == 2 || st == 5)) begin
            expected = 0;
            for (r = 0; r < 4; r++)
            for (c = 0; c < 4; c++) expected[(r*4+c)*32+:32] = local_sum[r][c];
            if (v.sums !== expected)
              `uvm_fatal("CORE_SUM", $sformatf(
                         "edge=%0d tile=%0d compute=%0d expected=%h actual=%h",
                         checked,
                         tile,
                         compute_edge,
                         expected,
                         v.sums
                         ))
          end
          if (st == 9 && v.state == 2) begin
            if (compute_edge != ((sparse ? 1 : 2) * group_count))
              `uvm_fatal("CYCLES", "Wrong enabled core edge count")
            tile += 2;
          end
          if (st == 9 && v.state == 10 && compute_edge != ((sparse ? 1 : 2) * group_count))
            `uvm_fatal("CYCLES", "Wrong final tile edge count")
          $fdisplay(
              fd,
              "%0d,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h",
              checked, x, st, precr, predr, preov, preod, prer, prec, preid, predone, preerr,
              advance, v.state, v.sums, v.a, v.w, v.av, v.wv, v.cr, v.dr, v.ov, v.od, v.row, v.col,
              v.id, v.done, v.error);
        end
      end
    endtask
    task run_phase(uvm_phase phase);
      string path;
      int f, kind, ret, waits, completed = 0;
      bit [2047:0] payload;
      bit [ 255:0] idle;
      phase.raise_objection(this);
      fork
        monitor();
      join_none
      if (!$value$plusargs("PROGRAM=%s", path)) `uvm_fatal("FILE", "Missing program")
      f = $fopen(path, "r");
      if (f == 0) `uvm_fatal("FILE", "Cannot open program")
      idle = (1 << 2) | (1 << 3);
      tick(1);
      tick(1);
      tick(idle);
      while (!$feof(
          f
      )) begin
        ret = $fscanf(f, "%d %h\n", kind, payload);
        if (ret != 2) `uvm_fatal("FILE", "Malformed program")
        case (kind)
          0: tick(payload[255:0]);
          1: begin
            waits = 0;
            while (!v.cr || !host_open()) begin
              tick(idle);
              if (waits++ > 20000) `uvm_fatal("WAIT", "Command timeout")
            end
            tick(payload[255:0]);
          end
          2: begin
            waits = 0;
            while (!v.dr || !host_open()) begin
              tick(idle);
              if (waits++ > 20000) `uvm_fatal("WAIT", "Data timeout")
            end
            tick(payload[255:0]);
          end
          3: begin
            waits = 0;
            while (!v.done) begin
              // Common deterministic availability, including held output stress.
              idle = 0;
              idle[2] = (waits % 5 != 1);
              idle[3] = (waits % 7 >= 3);
              tick(idle);
              if (v.error) `uvm_fatal("UNEXPECTED_ERROR", "Error in legal job")
              if (waits++ > 100000) `uvm_fatal("WAIT", "Completion timeout")
            end
            if (payload[0] && outputs != m * n) `uvm_fatal("COUNT", "Output count incomplete")
            completed++;
            idle = (1 << 2) | (1 << 3);
            tick(idle);
          end
          4: begin
            golden = payload;
            golden_valid = 1;
            epoch = checked;
          end
          5: begin
            waits = 0;
            while (!v.error) begin
              tick(idle);
              if (waits++ > 20) `uvm_fatal("EXPECTED_ERROR", "Missing expected rejection")
            end
            repeat (3) tick(idle);
          end
          6: begin
            waits = 0;
            idle  = 12;
            while (v.state != payload[4:0]) begin
              tick(idle);
              if (waits++ > 20000) `uvm_fatal("WAIT", "State target timeout")
            end
            tick(payload[5] ? 14 : 13);
            tick(12);
          end
          default: `uvm_fatal("FILE", "Unknown operation")
        endcase
      end
      if(completed<2 || count_advance==0 || count_load==0 || (service && (count_stall==0 || count_output_stall==0)))
        `uvm_fatal("COVERAGE", "Missing common-comparison work")
      if (v.state != 0 || v.ov) `uvm_fatal("PENDING", "Pending comparison work")
      `uvm_info(
          "WRAPPER_PASS",
          $sformatf(
              "checked=%0d completed=%0d advances=%0d loads=%0d stalls=%0d output_stalls=%0d resets=%0d expected_error_edges=%0d continues=%0d",
              checked, completed, count_advance, count_load, count_stall, count_output_stall,
              count_reset, count_error, count_continue), UVM_NONE)
      $fclose(f);
      $fclose(fd);
      phase.drop_objection(this);
    endtask
  endclass
endpackage
module tb;
  import uvm_pkg::*;
  import wrapper_pkg::*;
  bit clk = 0;
  always #5 clk = ~clk;
  wrapper_if bus (clk);
  wire [840:0] observed[3];
  for (genvar i = 0; i < 3; i++) begin : variants
    wire [255:0] x = bus.pins;
    if (i == 2) begin : fault
      rs_wrapper_fault dut (
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
          .cmd_ready(observed[i][0]),
          .data_ready(observed[i][1]),
          .out_valid(observed[i][2]),
          .done(observed[i][3]),
          .error(observed[i][4]),
          .out_data(observed[i][36:5]),
          .out_row(observed[i][40:37]),
          .out_col(observed[i][42:41]),
          .out_id(observed[i][58:43]),
          .debug_state(observed[i][63:59]),
          .debug_advance(observed[i][64]),
          .debug_sums(observed[i][576:65]),
          .debug_a(observed[i][704:577]),
          .debug_w(observed[i][832:705]),
          .debug_av(observed[i][836:833]),
          .debug_wv(observed[i][840:837])
      );
    end else begin : clean
      rs_wrapper dut (
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
          .cmd_ready(observed[i][0]),
          .data_ready(observed[i][1]),
          .out_valid(observed[i][2]),
          .done(observed[i][3]),
          .error(observed[i][4]),
          .out_data(observed[i][36:5]),
          .out_row(observed[i][40:37]),
          .out_col(observed[i][42:41]),
          .out_id(observed[i][58:43]),
          .debug_state(observed[i][63:59]),
          .debug_advance(observed[i][64]),
          .debug_sums(observed[i][576:65]),
          .debug_a(observed[i][704:577]),
          .debug_w(observed[i][832:705]),
          .debug_av(observed[i][836:833]),
          .debug_wv(observed[i][840:837])
      );
    end
  end
  wire [840:0] y = $test$plusargs(
      "MUTATE"
  ) ? observed[2] : ($test$plusargs(
      "NATIVE"
  ) ? observed[1] : observed[0]);
  assign {bus.wv,bus.av,bus.w,bus.a,bus.sums,bus.adv,bus.state,bus.id,bus.col,bus.row,bus.od,bus.error,bus.done,bus.ov,bus.dr,bus.cr}=y;
  initial begin
    uvm_config_db#(virtual wrapper_if)::set(null, "*", "v", bus);
    run_test("wrapper_test");
  end

  integer traffic_fd, traffic_cycle = 0;
  wire [3:0] traffic_ar, traffic_wr, traffic_pr, traffic_pw;
  initial begin
    traffic_fd = $fopen("traffic.csv", "w");
    $fdisplay(traffic_fd, "cycle,ar,wr,pr,pw");
  end
  always @(posedge clk)
    if (bus.trace_enable) begin
      traffic_cycle = traffic_cycle + 1;
      $fdisplay(traffic_fd, "%0d,%h,%h,%h,%h", traffic_cycle,
                bus.pins[1:0] != 0 ? 4'b0 : traffic_ar, bus.pins[1:0] != 0 ? 4'b0 : traffic_wr,
                bus.pins[1:0] != 0 ? 4'b0 : traffic_pr, bus.pins[1:0] != 0 ? 4'b0 : traffic_pw);
    end
  assign traffic_ar = $test$plusargs(
      "NATIVE"
  ) ? variants[1].clean.dut.ar : variants[0].clean.dut.ar;
  assign traffic_wr = $test$plusargs(
      "NATIVE"
  ) ? variants[1].clean.dut.wr : variants[0].clean.dut.wr;
  wire [3:0] pr0, pw0;
  assign pr0[0]=(variants[0].clean.dut.state==7 && 0<variants[0].clean.dut.n) || (variants[0].clean.dut.issue_drain && variants[0].clean.dut.drain_col==0);
  assign pw0[0] = variants[0].clean.dut.state == 9 && 0 < variants[0].clean.dut.n;
  assign pr0[1]=(variants[0].clean.dut.state==7 && 1<variants[0].clean.dut.n) || (variants[0].clean.dut.issue_drain && variants[0].clean.dut.drain_col==1);
  assign pw0[1] = variants[0].clean.dut.state == 9 && 1 < variants[0].clean.dut.n;
  assign pr0[2]=(variants[0].clean.dut.state==7 && 2<variants[0].clean.dut.n) || (variants[0].clean.dut.issue_drain && variants[0].clean.dut.drain_col==2);
  assign pw0[2] = variants[0].clean.dut.state == 9 && 2 < variants[0].clean.dut.n;
  assign pr0[3]=(variants[0].clean.dut.state==7 && 3<variants[0].clean.dut.n) || (variants[0].clean.dut.issue_drain && variants[0].clean.dut.drain_col==3);
  assign pw0[3] = variants[0].clean.dut.state == 9 && 3 < variants[0].clean.dut.n;
  wire [3:0] pr1, pw1;
  assign pr1[0]=(variants[1].clean.dut.state==7 && 0<variants[1].clean.dut.n) || (variants[1].clean.dut.issue_drain && variants[1].clean.dut.drain_col==0);
  assign pw1[0] = variants[1].clean.dut.state == 9 && 0 < variants[1].clean.dut.n;
  assign pr1[1]=(variants[1].clean.dut.state==7 && 1<variants[1].clean.dut.n) || (variants[1].clean.dut.issue_drain && variants[1].clean.dut.drain_col==1);
  assign pw1[1] = variants[1].clean.dut.state == 9 && 1 < variants[1].clean.dut.n;
  assign pr1[2]=(variants[1].clean.dut.state==7 && 2<variants[1].clean.dut.n) || (variants[1].clean.dut.issue_drain && variants[1].clean.dut.drain_col==2);
  assign pw1[2] = variants[1].clean.dut.state == 9 && 2 < variants[1].clean.dut.n;
  assign pr1[3]=(variants[1].clean.dut.state==7 && 3<variants[1].clean.dut.n) || (variants[1].clean.dut.issue_drain && variants[1].clean.dut.drain_col==3);
  assign pw1[3] = variants[1].clean.dut.state == 9 && 3 < variants[1].clean.dut.n;
  assign traffic_pr = $test$plusargs("NATIVE") ? pr1 : pr0;
  assign traffic_pw = $test$plusargs("NATIVE") ? pw1 : pw0;
  initial begin
    #100000000;
    $fatal(1, "TIMEOUT");
  end
endmodule
