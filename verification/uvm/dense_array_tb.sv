`timescale 1ns / 1ps
interface dense_if (
    input logic clk
);
  logic rst = 1, clear = 0, advance = 0, checking = 0;
  logic [31:0] ai = 0, wi = 0;
  logic [3:0] av = 0, wv = 0;
  wire [511:0] sums;
  wire [127:0] ap, wp;
  wire [15:0] avp, wvp;
endinterface
package dense_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  class cycle_item extends uvm_sequence_item;
    bit rst, clear, advance;
    bit [31:0] ai, wi;
    bit [3:0] av, wv;
    bit [511:0] sums;
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
      if (!fd) `uvm_fatal("FILE", "Cannot open vectors")
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
        `uvm_fatal("DENSE_MISMATCH", $sformatf(
                   "cycle=%0d expected=%032h actual=%032h expected_ap=%h actual_ap=%h expected_wp=%h actual_wp=%h",
                   checked,
                   e.sums,
                   s.sums,
                   e.ap,
                   s.ap,
                   e.wp,
                   s.wp
                   ))
      cov_rst = s.rst;
      cov_clear = s.clear;
      cov_advance = s.advance;
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
      `uvm_info("DENSE_PASS", $sformatf(
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
  wire [511:0] normal_sums;
  assign bus.sums = $test$plusargs("MUTATE_DROP") ? faulty_sums : normal_sums;
  dense_os #(
      .R(4),
      .C(4)
  ) dut (
      .clk(clk),
      .rst(bus.rst),
      .clear(bus.clear),
      .advance(bus.advance),
      .a_in(bus.ai),
      .w_in(bus.wi),
      .a_valid(bus.av),
      .w_valid(bus.wv),
      .sums(normal_sums)
  );
  wire [511:0] faulty_sums;
  dense_os_fault #(
      .R(4),
      .C(4)
  ) faulty (
      .clk(clk),
      .rst(bus.rst),
      .clear(bus.clear),
      .advance(bus.advance),
      .a_in(bus.ai),
      .w_in(bus.wi),
      .a_valid(bus.av),
      .w_valid(bus.wv),
      .sums(faulty_sums)
  );
  for (genvar r = 0; r < 4; r++) begin
    for (genvar c = 0; c < 4; c++) begin
      assign bus.ap[(r*4+c)*8+:8] = dut.a_pipe[r][c];
      assign bus.wp[(r*4+c)*8+:8] = dut.w_pipe[r][c];
      assign bus.avp[r*4+c] = dut.av_pipe[r][c];
      assign bus.wvp[r*4+c] = dut.wv_pipe[r][c];
    end
  end
  assert property (@(posedge clk) !bus.rst && !bus.clear && !bus.advance |=> $stable(
      {bus.sums, bus.ap, bus.wp, bus.avp, bus.wvp}
  ))
  else $fatal(1, "DENSE_STALL_ASSERT");
  assert property(@(posedge clk) bus.rst || bus.clear |=> {bus.sums,bus.ap,bus.wp,bus.avp,bus.wvp}==0)
  else $fatal(1, "DENSE_RESET_ASSERT");
  initial begin
    uvm_config_db#(virtual dense_if)::set(null, "*", "vif", bus);
    run_test("dense_test");
  end
  initial begin
    #10000000;
    $fatal(1, "DENSE_TIMEOUT");
  end
endmodule
