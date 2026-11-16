`ifndef GEMM_DIM
`define GEMM_DIM 2
`endif
`timescale 1ns / 1ps
interface sparse_if (
    input logic clk
);
  logic rst = 1, clear = 0, advance = 0, checking = 0;
  logic [32*`GEMM_DIM-1:0] ai = 0, wi = 0;
  logic mode = 1;
  logic [4*`GEMM_DIM-1:0] tail = 0;
  logic [3*`GEMM_DIM-1:0] code = 0;
  wire [1:0] phase;
  wire error;
  logic [`GEMM_DIM-1:0] av = 0, wv = 0;
  wire [32*`GEMM_DIM*`GEMM_DIM-1:0] sums;
  wire [32*`GEMM_DIM*`GEMM_DIM-1:0] ap, wp;
  wire [4*`GEMM_DIM*`GEMM_DIM-1:0] mp;
  wire [3*`GEMM_DIM*`GEMM_DIM-1:0] cp;
  wire latched_mode;
  wire [`GEMM_DIM*`GEMM_DIM-1:0] avp, wvp;
endinterface
package sparse_pkg;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  class cycle_item extends uvm_sequence_item;
    bit rst, clear, advance;
    bit [32*`GEMM_DIM-1:0] ai, wi;
    bit mode;
    bit [4*`GEMM_DIM-1:0] tail;
    bit [3*`GEMM_DIM-1:0] code;
    bit [1:0] phase;
    bit error;
    bit [`GEMM_DIM-1:0] av, wv;
    bit [32*`GEMM_DIM*`GEMM_DIM-1:0] sums;
    bit [32*`GEMM_DIM*`GEMM_DIM-1:0] ap, wp;
    bit [4*`GEMM_DIM*`GEMM_DIM-1:0] mp;
    bit [3*`GEMM_DIM*`GEMM_DIM-1:0] cp;
    bit latched_mode;
    bit [1:0] pre_phase;
    bit pre_mode, pre_error;
    bit [`GEMM_DIM*`GEMM_DIM-1:0] avp, wvp;
    `uvm_object_utils(cycle_item)
    function new(string n = "cycle_item");
      super.new(n);
    endfunction
    function bit inputs_equal(cycle_item b);
      return {rst,clear,advance,ai,wi,av,wv,mode,tail,code}=={b.rst,b.clear,b.advance,b.ai,b.wi,b.av,b.wv,b.mode,b.tail,b.code};
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
            "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
            t.rst,
            t.clear,
            t.advance,
            t.mode,
            t.ai,
            t.wi,
            t.tail,
            t.code,
            t.av,
            t.wv,
            t.sums,
            t.phase,
            t.error,
            t.ap,
            t.wp,
            t.mp,
            t.cp,
            t.avp,
            t.wvp,
            t.latched_mode
        );
        if (n != 20) `uvm_fatal("FILE", "Malformed vector")
        start_item(t);
        finish_item(t);
        count++;
      end
      $fclose(fd);
      if (count < 10) `uvm_fatal("EMPTY", "Insufficient vectors")
    endtask
  endclass
  class sparse_driver extends uvm_driver #(cycle_item);
    `uvm_component_utils(sparse_driver)
    virtual sparse_if vif;
    uvm_analysis_port #(cycle_item) intent;
    function new(string n, uvm_component p);
      super.new(n, p);
      intent = new("intent", this);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual sparse_if)::get(this, "", "vif", vif))
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
        vif.mode = t.mode;
        vif.tail = t.tail;
        vif.code = t.code;
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
  class sparse_monitor extends uvm_monitor;
    `uvm_component_utils(sparse_monitor)
    virtual sparse_if vif;
    uvm_analysis_port #(cycle_item) observed;
    function new(string n, uvm_component p);
      super.new(n, p);
      observed = new("observed", this);
    endfunction
    function void build_phase(uvm_phase phase);
      if (!uvm_config_db#(virtual sparse_if)::get(this, "", "vif", vif))
        `uvm_fatal("VIF", "Missing interface")
    endfunction
    task run_phase(uvm_phase phase);
      cycle_item s;
      forever begin
        @(posedge vif.clk);
        if (vif.checking) begin
          s = cycle_item::type_id::create("s");
          s.mode = vif.mode;
          s.tail = vif.tail;
          s.code = vif.code;
          s.rst = vif.rst;
          s.clear = vif.clear;
          s.advance = vif.advance;
          s.ai = vif.ai;
          s.wi = vif.wi;
          s.av = vif.av;
          s.wv = vif.wv;
          s.pre_phase = vif.phase;
          s.pre_mode = vif.latched_mode;
          s.pre_error = vif.error;
          #1;
          s.sums = vif.sums;
          s.phase = vif.phase;
          s.error = vif.error;
          s.ap = vif.ap;
          s.wp = vif.wp;
          s.mp = vif.mp;
          s.cp = vif.cp;
          s.avp = vif.avp;
          s.wvp = vif.wvp;
          s.latched_mode = vif.latched_mode;
          observed.write(s);
        end
      end
    endtask
  endclass
  `uvm_analysis_imp_decl(_intent)
  `uvm_analysis_imp_decl(_observed)
  class sparse_scoreboard extends uvm_scoreboard;
    `uvm_component_utils(sparse_scoreboard)
    uvm_analysis_imp_intent #(cycle_item, sparse_scoreboard) intent;
    uvm_analysis_imp_observed #(cycle_item, sparse_scoreboard) observed;
    cycle_item pending[$];
    int checked = 0, fd;
    bit cov_rst, cov_clear, cov_advance;
    bit cov_compute;
    int cov_phase_mode, cov_code, cov_mask, cov_a, cov_w;
    covergroup phase_modes;
      option.per_instance = 1;
      phase_cp: coverpoint cov_phase_mode {
        bins dense0 = {0};
        bins dense1 = {1};
        bins dense2 = {2};
        bins dense3 = {3};
        bins sparse0 = {4};
        bins sparse1 = {5};
      }
    endgroup
    covergroup metadata;
      option.per_instance = 1;
      code_cp: coverpoint cov_code {bins codes[] = {[0 : 7]};}
    endgroup
    covergroup masks;
      option.per_instance = 1;
      mask_cp: coverpoint cov_mask {
        bins invalid_lane = {0}; bins one = {1}; bins two = {3}; bins three = {7}; bins full = {15};
      }
    endgroup
    covergroup operands;
      option.per_instance = 1;
      a_cp: coverpoint cov_a {
        bins minimum = {-128};
        bins negative = {[-127 : -1]};
        bins zero = {0};
        bins positive = {[1 : 126]};
        bins maximum = {127};
      }
      w_cp: coverpoint cov_w {
        bins minimum = {-128};
        bins negative = {[-127 : -1]};
        bins zero = {0};
        bins positive = {[1 : 126]};
        bins maximum = {127};
      }
    endgroup
    function int index_a(int code, int phase);
      case (code)
        0: return phase == 0 ? 0 : 1;
        1: return phase == 0 ? 0 : 2;
        2: return phase == 0 ? 0 : 3;
        3: return phase == 0 ? 1 : 2;
        4: return phase == 0 ? 1 : 3;
        5: return phase == 0 ? 2 : 3;
        default: return 0;
      endcase
    endfunction
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
      phase_modes = new;
      metadata = new;
      masks = new;
      operands = new;
      fd = $fopen("observed.csv", "w");
      $fdisplay(
          fd,
          "cycle,pre_phase,pre_mode,pre_error,rst,clear,advance,mode,ai,wi,tail,code,av,wv,sums,phase,error,ap,wp,mp,cp,avp,wvp,latched_mode");
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
      if ($test$plusargs("MUTATE_SCOREBOARD") && checked == 3) e.sums ^= 128'b1;
      if(e.sums!=s.sums || e.phase!=s.phase || e.error!=s.error || e.ap!=s.ap || e.wp!=s.wp || e.mp!=s.mp || e.cp!=s.cp || e.avp!=s.avp || e.wvp!=s.wvp || e.latched_mode!=s.latched_mode)
        `uvm_fatal("SPARSE_MISMATCH", $sformatf(
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
      if (!s.rst && !s.clear && s.advance && !s.pre_error) begin
        cov_phase_mode = 4 * int'(s.pre_mode) + int'(s.pre_phase);
        phase_modes.sample();
        if (s.pre_phase == 0) begin
          for (int lane = 0; lane < `GEMM_DIM; lane++) begin
            cov_mask = int'(s.tail[lane*4+:4]);
            masks.sample();
            if (s.pre_mode && s.wv[lane]) begin
              cov_code = int'(s.code[lane*3+:3]);
              metadata.sample();
            end
          end
        end
        if (!s.error) begin
          for (int pe = 0; pe < `GEMM_DIM * `GEMM_DIM; pe++) begin
            int pos;
            pos = s.pre_mode ? index_a(int'(s.cp[pe*3+:3]), int'(s.pre_phase)) : int'(s.pre_phase);
            if (s.avp[pe] && s.wvp[pe] && s.mp[pe*4+pos]) begin
              cov_a = int'($signed(s.ap[pe*32+pos*8+:8]));
              cov_w = int'($signed(s.wp[pe*32+int'(s.pre_phase)*8+:8]));
              operands.sample();
            end
          end
        end
      end
      $fdisplay(fd, "%0d,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h,%h",
                checked, s.pre_phase, s.pre_mode, s.pre_error, s.rst, s.clear, s.advance, s.mode,
                s.ai, s.wi, s.tail, s.code, s.av, s.wv, s.sums, s.phase, s.error, s.ap, s.wp, s.mp,
                s.cp, s.avp, s.wvp, s.latched_mode);
    endfunction
    function void check_phase(uvm_phase phase);
      int expected;
      if (!$value$plusargs("EXPECTED=%d", expected))
        `uvm_fatal("COUNT", "Missing expected cycle count")
      if(checked!=expected || pending.size()!=0 || modes.get_inst_coverage()!=100.0 || phase_modes.get_inst_coverage()!=100.0 || metadata.get_inst_coverage()!=100.0 || masks.get_inst_coverage()!=100.0 || operands.get_inst_coverage()!=100.0)
        `uvm_fatal("CLOSURE", "Incomplete count, pending transaction or coverage")
      `uvm_info("SPARSE_PASS", $sformatf(
                "checked=%0d control=%0.1f phase=%0.1f metadata=%0.1f masks=%0.1f operands=%0.1f",
                checked,
                modes.get_inst_coverage(),
                phase_modes.get_inst_coverage(),
                metadata.get_inst_coverage(),
                masks.get_inst_coverage(),
                operands.get_inst_coverage()
                ), UVM_NONE)
      $fclose(fd);
    endfunction
  endclass
  class sparse_env extends uvm_env;
    `uvm_component_utils(sparse_env)
    sparse_driver d;
    sparse_monitor m;
    sparse_scoreboard sb;
    uvm_sequencer #(cycle_item) sq;
    function new(string n, uvm_component p);
      super.new(n, p);
    endfunction
    function void build_phase(uvm_phase phase);
      d  = sparse_driver::type_id::create("d", this);
      m  = sparse_monitor::type_id::create("m", this);
      sb = sparse_scoreboard::type_id::create("sb", this);
      sq = new("sq", this);
    endfunction
    function void connect_phase(uvm_phase phase);
      d.seq_item_port.connect(sq.seq_item_export);
      d.intent.connect(sb.intent);
      m.observed.connect(sb.observed);
    endfunction
  endclass
  class sparse_test extends uvm_test;
    `uvm_component_utils(sparse_test)
    sparse_env e;
    function new(string n, uvm_component p);
      super.new(n, p);
    endfunction
    function void build_phase(uvm_phase phase);
      e = sparse_env::type_id::create("e", this);
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
  import sparse_pkg::*;
  bit clk = 0;
  always #5 clk = ~clk;
  sparse_if bus (clk);
  bit mutate;
  initial mutate = $test$plusargs("MUTATE_TAIL");
  wire [32*`GEMM_DIM*`GEMM_DIM-1:0] nominal_sums, fault_sums;
  wire [1:0] nominal_phase, fault_phase;
  wire nominal_error, fault_error;
  sparse_os #(
      .R(`GEMM_DIM),
      .C(`GEMM_DIM)
  ) dut (
      .clk(clk),
      .rst(bus.rst),
      .clear(bus.clear),
      .advance(bus.advance),
      .sparse_mode(bus.mode),
      .a_in(bus.ai),
      .w_in(bus.wi),
      .tail_in(bus.tail),
      .code_in(bus.code),
      .a_valid(bus.av),
      .w_valid(bus.wv),
      .sums(nominal_sums),
      .phase(nominal_phase),
      .error(nominal_error)
  );
  sparse_os_fault #(
      .R(`GEMM_DIM),
      .C(`GEMM_DIM)
  ) faulty (
      .clk(clk),
      .rst(bus.rst),
      .clear(bus.clear),
      .advance(bus.advance),
      .sparse_mode(bus.mode),
      .a_in(bus.ai),
      .w_in(bus.wi),
      .tail_in(bus.tail),
      .code_in(bus.code),
      .a_valid(bus.av),
      .w_valid(bus.wv),
      .sums(fault_sums),
      .phase(fault_phase),
      .error(fault_error)
  );
  assign bus.sums = mutate ? fault_sums : nominal_sums;
  assign bus.phase = mutate ? fault_phase : nominal_phase;
  assign bus.error = mutate ? fault_error : nominal_error;
  assign bus.latched_mode = mutate ? faulty.mode : dut.mode;
  for (genvar r = 0; r < `GEMM_DIM; r++) begin
    for (genvar c = 0; c < `GEMM_DIM; c++) begin
      assign bus.ap[(r*`GEMM_DIM+c)*32+:32] = mutate ? faulty.ap[r][c] : dut.ap[r][c];
      assign bus.wp[(r*`GEMM_DIM+c)*32+:32] = mutate ? faulty.wp[r][c] : dut.wp[r][c];
      assign bus.mp[(r*`GEMM_DIM+c)*4+:4] = mutate ? faulty.mask[r][c] : dut.mask[r][c];
      assign bus.cp[(r*`GEMM_DIM+c)*3+:3] = mutate ? faulty.code[r][c] : dut.code[r][c];
      assign bus.avp[r*`GEMM_DIM+c] = mutate ? faulty.av[r][c] : dut.av[r][c];
      assign bus.wvp[r*`GEMM_DIM+c] = mutate ? faulty.wv[r][c] : dut.wv[r][c];
    end
  end
  assert property (@(posedge clk) !bus.rst && !bus.clear && !bus.advance |=> $stable(
      {
        bus.sums,
        bus.phase,
        bus.error,
        bus.ap,
        bus.wp,
        bus.mp,
        bus.cp,
        bus.avp,
        bus.wvp,
        bus.latched_mode
      }
  ))
  else $fatal(1, "SPARSE_STALL_ASSERT");
  assert property(@(posedge clk) bus.rst || bus.clear |=> {bus.sums,bus.phase,bus.error,bus.ap,bus.wp,bus.mp,bus.cp,bus.avp,bus.wvp}=='0)
  else $fatal(1, "SPARSE_RESET_ASSERT");
  initial begin
    uvm_config_db#(virtual sparse_if)::set(null, "*", "vif", bus);
    run_test("sparse_test");
  end
  initial begin
    #10000000;
    $fatal(1, "SPARSE_TIMEOUT");
  end
endmodule
