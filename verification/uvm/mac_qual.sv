`timescale 1ns / 1ps
interface mac_if (
    input logic clk
);
  logic rst = 1, valid = 0, ready, out_valid, out_ready = 0;
  logic [7:0] a = 0, b = 0;
  logic [31:0] out_data;
endinterface

module mac_qual (
    mac_if p
);
  logic signed [31:0] acc;
  logic signed [15:0] product;
  assign product = $signed(p.a) * $signed(p.b);
  assign p.ready = !p.out_valid || p.out_ready;
  always_ff @(posedge p.clk) begin
    if (p.rst) begin
      acc <= 0;
      p.out_valid <= 0;
      p.out_data <= 0;
    end else begin
      if (p.ready) begin
        p.out_valid <= p.valid;
        if (p.valid) begin
          acc <= acc + 32'(product);
          p.out_data <= acc + 32'(product);
        end
      end
      if ($test$plusargs("MUTATE_ASSERT") && p.out_valid && !p.out_ready)
        p.out_data <= p.out_data + 1;
    end
  end
  assert property (@(posedge p.clk) disable iff(p.rst)
    p.out_valid && !p.out_ready |=> p.out_valid && $stable(
      p.out_data
  ))
  else $fatal(1, "QUAL_STABILITY_ASSERT");
endmodule

package qual_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  class item extends uvm_sequence_item;
    rand int signed   a,   b;
    rand int unsigned gap;
    constraint range_c {
      a inside {[-128 : 127]};
      b inside {[-128 : 127]};
      gap inside {[0 : 3]};
    }
    `uvm_object_utils(item)
    function new(string name = "item");
      super.new(name);
    endfunction
  endclass
  class sample extends uvm_sequence_item;
    bit rst, accept, consume, post_valid;
    int signed a, b, result;
    `uvm_object_utils(sample)
    function new(string name = "sample");
      super.new(name);
    endfunction
  endclass
  class seq extends uvm_sequence #(item);
    `uvm_object_utils(seq)
    function new(string name = "seq");
      super.new(name);
    endfunction
    task body();
      item t;
      t = item::type_id::create("unsat");
      if ((t.randomize() with {a == 128;}) != 0)
        `uvm_fatal("SOLVER", "Unsatisfiable constraint accepted")
      `uvm_info("SOLVER", "UNSAT_REJECTED", UVM_LOW)
      for (int i = 0; i < 72; i++) begin
        t = item::type_id::create("t");
        start_item(t);
        if (t.randomize() == 0) `uvm_fatal("SOLVER", "randomize failed")
        if (i < 8) begin
          case (i)
            0: begin
              t.a = -128;
              t.b = -128;
            end
            1: begin
              t.a = 127;
              t.b = 127;
            end
            2: begin
              t.a = 0;
              t.b = 0;
            end
            3: begin
              t.a = -1;
              t.b = 1;
            end
            4: begin
              t.a = 1;
              t.b = -1;
            end
            5: begin
              t.a = -128;
              t.b = 127;
            end
            6: begin
              t.a = 127;
              t.b = -128;
            end
            7: begin
              t.a = 1;
              t.b = 1;
            end
          endcase
        end
        if (t.a < -128 || t.a > 127 || t.b < -128 || t.b > 127 || t.gap > 3)
          `uvm_fatal("CONSTRAINT", "Out of range")
        finish_item(t);
      end
    endtask
  endclass
  class driver extends uvm_driver #(item);
    `uvm_component_utils(driver)
    virtual mac_if vif;
    uvm_analysis_port #(item) intended;
    function new(string n, uvm_component p);
      super.new(n, p);
      intended = new("intended", this);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual mac_if)::get(this, "", "vif", vif))
        `uvm_fatal("VIF", "Missing interface")
    endfunction
    task run_phase(uvm_phase phase);
      item t;
      repeat (3) @(negedge vif.clk);
      vif.rst = 0;
      vif.out_ready = 1;
      forever begin
        seq_item_port.get_next_item(t);
        repeat (t.gap) @(negedge vif.clk);
        @(negedge vif.clk);
        vif.a = 8'(t.a);
        vif.b = 8'(t.b);
        vif.valid = 1;
        vif.out_ready = 1;
        intended.write(t);
        @(posedge vif.clk);
        while (!vif.ready) @(posedge vif.clk);
        @(negedge vif.clk);
        vif.valid = 0;
        vif.out_ready = 0;
        repeat (3) @(negedge vif.clk);
        vif.out_ready = 1;
        @(negedge vif.clk);
        seq_item_port.item_done();
      end
    endtask
  endclass
  class monitor extends uvm_monitor;
    `uvm_component_utils(monitor)
    virtual mac_if vif;
    uvm_analysis_port #(sample) observed;
    function new(string n, uvm_component p);
      super.new(n, p);
      observed = new("observed", this);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual mac_if)::get(this, "", "vif", vif))
        `uvm_fatal("VIF", "Missing interface")
    endfunction
    task run_phase(uvm_phase phase);
      sample s;
      forever begin
        @(posedge vif.clk);
        s = sample::type_id::create("s");
        s.rst = vif.rst;
        s.accept = vif.valid && vif.ready;
        s.consume = vif.out_valid && vif.out_ready;
        s.a = int'($signed(vif.a));
        s.b = int'($signed(vif.b));
        #1;
        s.post_valid = vif.out_valid;
        s.result = int'($signed(vif.out_data));
        observed.write(s);
      end
    endtask
  endclass
  `uvm_analysis_imp_decl(_intent)
  `uvm_analysis_imp_decl(_actual)
  class scoreboard extends uvm_scoreboard;
    `uvm_component_utils(scoreboard)
    uvm_analysis_imp_intent #(item, scoreboard) intent;
    uvm_analysis_imp_actual #(sample, scoreboard) actual;
    item pending[$];
    longint signed acc = 0;
    bit expected_valid = 0;
    int checked = 0, resets = 0, fd;
    int signed cov_a;
    covergroup operands;
      option.per_instance = 1;
      a_cp: coverpoint cov_a {
        bins minimum = {-128};
        bins negative = {[-127 : -1]};
        bins zero = {0};
        bins positive = {[1 : 126]};
        bins maximum = {127};
      }
    endgroup
    function new(string n, uvm_component p);
      super.new(n, p);
      intent = new("intent", this);
      actual = new("actual", this);
      operands = new;
      fd = $fopen("accepted.csv", "w");
      $fdisplay(fd, "index,a,b,result");
    endfunction
    function void write_intent(item t);
      item copy_t = new;
      copy_t.a = t.a;
      copy_t.b = t.b;
      pending.push_back(copy_t);
    endfunction
    function void write_actual(sample s);
      item t;
      if (s.rst) begin
        acc = 0;
        expected_valid = 0;
        resets++;
      end else begin
        if (s.consume) expected_valid = 0;
        if (s.accept) begin
          if (pending.size() == 0) `uvm_fatal("INPUT", "Unexpected accepted input")
          t = pending.pop_front();
          if (t.a != s.a || t.b != s.b) `uvm_fatal("INPUT", "Intended/accepted mismatch")
          acc = acc + longint'(s.a) * longint'(s.b);
          expected_valid = 1;
          checked++;
          cov_a = s.a;
          operands.sample();
          $fdisplay(fd, "%0d,%0d,%0d,%0d", checked, s.a, s.b, acc);
        end
      end
      if (s.post_valid != expected_valid) `uvm_fatal("VALID", "Output validity mismatch")
      if (s.post_valid && s.result != int'(acc) + int'($test$plusargs("MUTATE_SCOREBOARD")))
        `uvm_fatal("MISMATCH", "QUAL_SCOREBOARD_MISMATCH")
    endfunction
    function void check_phase(uvm_phase phase);
      if (checked != 72 || pending.size() != 0 || expected_valid || resets == 0)
        `uvm_fatal("CLOSURE", "Counts, reset or pending transaction failure")
      if (operands.get_inst_coverage() != 100.0) `uvm_fatal("COVERAGE", "Missing operand bins")
      `uvm_info("QUAL", $sformatf(
                "QUAL_PASS checked=%0d coverage=%0.1f", checked, operands.get_inst_coverage()),
                UVM_NONE)
      $fclose(fd);
    endfunction
  endclass
  class agent extends uvm_agent;
    `uvm_component_utils(agent)
    driver d;
    monitor m;
    uvm_sequencer #(item) sq;
    function new(string n, uvm_component p);
      super.new(n, p);
    endfunction
    function void build_phase(uvm_phase phase);
      d  = driver::type_id::create("d", this);
      m  = monitor::type_id::create("m", this);
      sq = new("sq", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      d.seq_item_port.connect(sq.seq_item_export);
    endfunction
  endclass
  class env extends uvm_env;
    `uvm_component_utils(env)
    agent a;
    scoreboard sb;
    function new(string n, uvm_component p);
      super.new(n, p);
    endfunction
    function void build_phase(uvm_phase phase);
      a  = agent::type_id::create("a", this);
      sb = scoreboard::type_id::create("sb", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      a.d.intended.connect(sb.intent);
      a.m.observed.connect(sb.actual);
    endfunction
  endclass
  class qual_test extends uvm_test;
    `uvm_component_utils(qual_test)
    env e;
    function new(string n, uvm_component p);
      super.new(n, p);
    endfunction
    function void build_phase(uvm_phase phase);
      e = env::type_id::create("e", this);
    endfunction
    task run_phase(uvm_phase phase);
      seq s = seq::type_id::create("s");
      phase.raise_objection(this);
      s.start(e.a.sq);
      #30;
      phase.drop_objection(this);
    endtask
  endclass
endpackage
module tb;
  import uvm_pkg::*;
  import qual_pkg::*;
  bit clk = 0;
  always #5 clk = ~clk;
  mac_if bus (clk);
  mac_qual dut (bus);
  initial begin
    uvm_config_db#(virtual mac_if)::set(null, "*", "vif", bus);
    run_test("qual_test");
  end
  initial begin
    #100000;
    $fatal(1, "QUAL_TIMEOUT");
  end
endmodule
