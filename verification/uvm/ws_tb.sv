`timescale 1ns / 1ps
interface dense_if (
    input logic clk
);
  logic rst = 1, clear = 0, advance = 0, checking = 0;
  logic [511:0] ai = 0, wi = 0;
  logic [3:0] av = 0, wv = 0;
  wire [1023:0] sums;
  wire [127:0] ap, wp;
  wire [15:0] avp, wvp;
endinterface
package dense_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  class cycle_item extends uvm_sequence_item;
    bit rst, clear, advance;
    bit [511:0] ai, wi;
    bit [3:0] av, wv;
    bit [1023:0] sums;
    bit [127:0] ap, wp;
    bit [15:0] avp, wvp;
    `uvm_object_utils(cycle_item)
    function new(string n = "cycle_item");
      super.new(n);
    endfunction
    function bit inputs_equal(cycle_item b);
      return {rst,clear,advance,ai,wi,av,wv}=={b.rst,b.clear,b.advance,b.ai,b.wi,b.av,b.wv};
    endfunction
  endclass
  class vector_seq extends uvm_sequence #(cycle_item);
    `uvm_object_utils(vector_seq)
    function new(string n = "vector_seq");
      super.new(n);
    endfunction
    task body();
      string path;
      int fd, count, n;
      cycle_item t;
      if (!$value$plusargs("VECTORS=%s", path)) `uvm_fatal("FILE", "Missing vector path")
      fd = $fopen(path, "r");
      if (fd == 0) `uvm_fatal("FILE", "Cannot open vectors")
      count = 0;
      while (!$feof(
          fd
      )) begin
        t = cycle_item::type_id::create("t");
        n = $fscanf(
            fd,
            "%h %h %h %h %h %h %h %h %h %h %h %h\n",
            t.rst,
            t.clear,
            t.advance,
            t.ai,
            t.wi,
            t.av,
            t.wv,
            t.sums,
            t.ap,
            t.wp,
            t.avp,
            t.wvp
        );
        if (n != 12) `uvm_fatal("FILE", $sformatf("Malformed vector %0d fields=%0d", count, n))
        start_item(t);
        finish_item(t);
        count++;
      end
      $fclose(fd);
      if (count < 10) `uvm_fatal("EMPTY", "Insufficient vectors")
    endtask
  endclass
  class dense_driver extends uvm_driver #(cycle_item);
    `uvm_component_utils(dense_driver)
    virtual dense_if vif;
    uvm_analysis_port #(cycle_item) intent;
    function new(string n, uvm_component p);
      super.new(n, p);
      intent = new("intent", this);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual dense_if)::get(this, "", "vif", vif))
        `uvm_fatal("VIF", "Missing interface")
    endfunction
    task run_phase(uvm_phase phase);
      cycle_item t;
      forever begin
        seq_item_port.get_next_item(t);
        @(negedge vif.clk);
        vif.checking = 1;
        vif.rst = t.rst;
        vif.clear = t.clear;
        vif.advance = t.advance;
        vif.ai = t.ai;
        vif.wi = t.wi;
        vif.av = t.av;
        vif.wv = t.wv;
        intent.write(t);
        @(posedge vif.clk);
        #2;
        vif.checking = 0;
        seq_item_port.item_done();
      end
    endtask
  endclass
  class dense_monitor extends uvm_monitor;
    `uvm_component_utils(dense_monitor)
    virtual dense_if vif;
    uvm_analysis_port #(cycle_item) observed;
    function new(string n, uvm_component p);
      super.new(n, p);
      observed = new("observed", this);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual dense_if)::get(this, "", "vif", vif))
        `uvm_fatal("VIF", "Missing interface")
    endfunction
    task run_phase(uvm_phase phase);
      cycle_item s;
      forever begin
        @(posedge vif.clk);
        if (vif.checking) begin
          s = cycle_item::type_id::create("s");
          s.rst = vif.rst;
          s.clear = vif.clear;
          s.advance = vif.advance;
          s.ai = vif.ai;
          s.wi = vif.wi;
          s.av = vif.av;
          s.wv = vif.wv;
          #1;
          s.sums = vif.sums;
          s.ap   = vif.ap;
          s.wp   = vif.wp;
          s.avp  = vif.avp;
          s.wvp  = vif.wvp;
          observed.write(s);
        end
      end
    endtask
  endclass
  `uvm_analysis_imp_decl(_intent)
  `uvm_analysis_imp_decl(_observed)
  class dense_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(dense_scoreboard)
    uvm_analysis_imp_intent #(cycle_item, dense_scoreboard) intent;
    uvm_analysis_imp_observed #(cycle_item, dense_scoreboard) observed;
    cycle_item pending[$];
    int checked = 0, fd;
    bit cov_rst, cov_clear, cov_advance;
    covergroup modes;
      option.per_instance = 1;
      reset_cp: coverpoint cov_rst {bins asserted = {1}; bins released = {0};}
      clear_cp: coverpoint cov_clear {bins asserted = {1}; bins released = {0};}
      advance_cp: coverpoint cov_advance {bins stall = {0}; bins run = {1};}
    endgroup
    function new(string n, uvm_component p);
      super.new(n, p);
      intent = new("intent", this);
      observed = new("observed", this);
      modes = new;
      fd = $fopen("observed.csv", "w");
      $fdisplay(fd, "cycle,rst,clear,advance,ai,wi,av,wv,sums,ap,wp,avp,wvp");
    endfunction
    function void write_intent(cycle_item t);
      pending.push_back(t);
    endfunction
    function void write_observed(cycle_item s);
      cycle_item e;
      if (pending.size() == 0) `uvm_fatal("INPUT", "Unplanned clock")
      e = pending.pop_front();
      checked++;
      if (!e.inputs_equal(s)) `uvm_fatal("INPUT", "Intended and observed input differ")

      if (e.sums != s.sums || e.ap != s.ap || e.wp != s.wp || e.avp != s.avp || e.wvp != s.wvp)
        `uvm_fatal("WS_MISMATCH", $sformatf(
                   "cycle=%0d expected=%032h actual=%032h expected_ap=%h actual_ap=%h expected_wp=%h actual_wp=%h",
                   checked,
                   e.sums,
                   s.sums,
                   e.ap,
                   s.ap,
                   e.wp,
                   s.wp
                   ))
      cov_rst = s.ai[0];
      cov_clear = s.ai[1];
      cov_advance = s.ai[2];
      modes.sample();
      $fdisplay(fd, "%0d,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h", checked, s.rst, s.clear, s.advance,
                s.ai, s.wi, s.av, s.wv, s.sums, s.ap, s.wp, s.avp, s.wvp);
    endfunction
    function void check_phase(uvm_phase phase);
      int expected;
      if (!$value$plusargs("EXPECTED=%d", expected))
        `uvm_fatal("COUNT", "Missing expected cycle count")
      if (checked != expected || pending.size() != 0 || modes.get_inst_coverage() != 100.0)
        `uvm_fatal("CLOSURE", "Incomplete count, pending transaction or coverage")
      `uvm_info("WS_PASS", $sformatf(
                "checked=%0d coverage=%0.1f", checked, modes.get_inst_coverage()), UVM_NONE)
      $fclose(fd);
    endfunction
  endclass
  class dense_env extends uvm_env;
    `uvm_component_utils(dense_env)
    dense_driver d;
    dense_monitor m;
    dense_scoreboard sb;
    uvm_sequencer #(cycle_item) sq;
    function new(string n, uvm_component p);
      super.new(n, p);
    endfunction
    function void build_phase(uvm_phase phase);
      d  = dense_driver::type_id::create("d", this);
      m  = dense_monitor::type_id::create("m", this);
      sb = dense_scoreboard::type_id::create("sb", this);
      sq = new("sq", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      d.seq_item_port.connect(sq.seq_item_export);
      d.intent.connect(sb.intent);
      m.observed.connect(sb.observed);
    endfunction
  endclass
  class dense_test extends uvm_test;
    `uvm_component_utils(dense_test)
    dense_env e;
    function new(string n, uvm_component p);
      super.new(n, p);
    endfunction
    function void build_phase(uvm_phase phase);
      e = dense_env::type_id::create("e", this);
    endfunction
    task run_phase(uvm_phase phase);
      vector_seq s = vector_seq::type_id::create("s");
      phase.raise_objection(this);
      s.start(e.sq);
      #20;
      phase.drop_objection(this);
    endtask
  endclass
endpackage
module tb;
  import uvm_pkg::*;
  import dense_pkg::*;
  bit clk = 0;
  always #5 clk = ~clk;
  dense_if bus (clk);
  wire [1023:0] observed[4];
  assign bus.sums = $test$plusargs(
      "DIM4"
  ) ? ($test$plusargs(
      "MUTATE_DROP"
  ) ? observed[3] : observed[2]) : ($test$plusargs(
      "MUTATE_DROP"
  ) ? observed[1] : observed[0]);
  assign bus.ap = 0;
  assign bus.wp = 0;
  assign bus.avp = 0;
  assign bus.wvp = 0;
  for (genvar variant = 0; variant < 4; variant++) begin : instances
    localparam D = variant < 2 ? 2 : 4;
    localparam W=7,C=W+D*32,V=C+D*3,A=V+D,T=A+D*32,AV=T+D*4,P=AV+D,PV=P+D*32;
    wire [511:0] x = bus.ai;
    if (variant % 2 == 0) begin
      sparse_ws #(
          .R(D),
          .C(D)
      ) dut (
          .clk(clk),
          .rst(x[0]),
          .clear(x[1]),
          .advance(x[2]),
          .sparse_mode(x[3]),
          .load(x[4]),
          .load_row(x[6:5]),
          .weight_in(x[W+:D*32]),
          .code_in(x[C+:D*3]),
          .weight_valid(x[V+:D]),
          .a_in(x[A+:D*32]),
          .tail_in(x[T+:D*4]),
          .a_valid(x[AV+:D]),
          .psum_in(x[P+:D*32]),
          .psum_valid(x[PV+:D]),
          .sums(observed[variant][0+:D*D*32]),
          .valids(observed[variant][D*D*32+:D*D]),
          .phase(observed[variant][D*D*33+:2]),
          .error(observed[variant][D*D*33+2])
      );
    end else begin
      sparse_ws_fault #(
          .R(D),
          .C(D)
      ) dut (
          .clk(clk),
          .rst(x[0]),
          .clear(x[1]),
          .advance(x[2]),
          .sparse_mode(x[3]),
          .load(x[4]),
          .load_row(x[6:5]),
          .weight_in(x[W+:D*32]),
          .code_in(x[C+:D*3]),
          .weight_valid(x[V+:D]),
          .a_in(x[A+:D*32]),
          .tail_in(x[T+:D*4]),
          .a_valid(x[AV+:D]),
          .psum_in(x[P+:D*32]),
          .psum_valid(x[PV+:D]),
          .sums(observed[variant][0+:D*D*32]),
          .valids(observed[variant][D*D*32+:D*D]),
          .phase(observed[variant][D*D*33+:2]),
          .error(observed[variant][D*D*33+2])
      );
    end
    assign observed[variant][1023:D*D*33+3] = 0;
  end
  initial begin
    uvm_config_db#(virtual dense_if)::set(null, "*", "vif", bus);
    run_test("dense_test");
  end
  initial begin
    #10000000;
    $fatal(1, "WS_TIMEOUT");
  end
endmodule
