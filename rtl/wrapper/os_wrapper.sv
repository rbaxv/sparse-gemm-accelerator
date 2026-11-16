module os_wrapper #(
    parameter NATIVE = 0
) (
    input wire clk,
    rst,
    abort,
    input wire cmd_valid,
    cmd_first,
    cmd_final,
    cmd_sparse,
    input wire [15:0] cmd_id,
    input wire [4:0] cmd_m,
    cmd_l,
    input wire [2:0] cmd_n,
    input wire [13:0] cmd_k,
    cmd_offset,
    output wire cmd_ready,
    input wire data_valid,
    input wire [31:0] data,
    input wire data_last,
    output wire data_ready,
    input wire compute_enable,
    output wire out_valid,
    input wire out_ready,
    output wire [31:0] out_data,
    output wire [3:0] out_row,
    output wire [1:0] out_col,
    output wire [15:0] out_id,
    output reg done,
    output reg error,
    output wire [4:0] debug_state,
    output wire debug_advance,
    output wire [511:0] debug_sums,
    output wire [127:0] debug_a,
    debug_w,
    output wire [3:0] debug_av,
    debug_wv
);
  localparam IDLE=0,LOAD=1,CLEAR=2,ISSUE=3,CAPTURE=4,EXEC=5,
 PREP=6,PREAD=7,PWAIT=8,COMMIT=9,RELEASE=10,DRAIN=11,FAIL=12;
  reg [4:0] state, m, l, tile, merge_row;
  reg [2:0] n, groups;
  reg [13:0] total, committed;
  reg [15:0] job_id;
  reg active, mode, final_slab;
  reg [5:0] slot;
  reg [1:0] subphase;
  wire [1:0] last_phase = NATIVE ? 0 : (mode ? 1 : 3);
  wire [5:0] total_slots = NATIVE ? ({1'b0, l} + 6) : ({3'b0, groups} + 6);
  wire good_cmd=cmd_m>=1 && cmd_m<=16 && cmd_n>=1 && cmd_n<=4 &&
  cmd_k>=1 && cmd_k<=8192 && cmd_offset<cmd_k && cmd_l>=1 && cmd_l<=16 &&
  cmd_l==((cmd_k-cmd_offset>16)?16:cmd_k-cmd_offset) &&
  cmd_final==(cmd_offset+cmd_l==cmd_k) && (!NATIVE || !cmd_sparse) &&
  (cmd_first?(!active && cmd_offset==0):(active && cmd_offset==committed &&
   cmd_id==job_id && cmd_m==m && cmd_n==n && cmd_k==total && cmd_sparse==mode));
  wire loader_idle, loader_ready, loader_error;
  wire accept = cmd_valid && cmd_ready;
  wire loader_cmd = accept && good_cmd;
  wire [127:0] aq, wq;
  wire [3:0] aqv, wqv;
  reg [3:0] ar, wr;
  reg [15:0] aa;
  reg [ 7:0] wa;
  reg [127:0] a_stage, w_stage;
  reg [3:0] a_valid, w_valid;
  reg [15:0] tail_stage;
  reg [11:0] code_stage;
  reg [127:0] a_cache, w_cache;
  reg [3:0] a_cached, w_cached;
  reg [15:0] a_tag;
  reg [ 7:0] w_tag;
  reg [3:0] desired_av, desired_wv;
  reg [15:0] desired_tail;
  reg [31:0] p_mem[0:3][0:15];
  reg [127:0] prior;
  wire core_clear = state == CLEAR;
  wire core_advance = state == EXEC && compute_enable && !rst && !abort;
  wire [511:0] sums;
  wire core_error;
  wire [1:0] core_phase;
  wire [31:0] scalar_a, scalar_w;
  assign cmd_ready = state == IDLE && loader_idle && !error && !rst && !abort;
  wire loader_data_ready;
  assign data_ready = state == LOAD && loader_data_ready && !rst && !abort;
  assign debug_state = state;
  assign debug_advance = core_advance;
  assign debug_sums = sums;
  assign debug_a = a_stage;
  assign debug_w = w_stage;
  assign debug_av = a_valid;
  assign debug_wv = w_valid;
  slab_loader loader (
      .clk(clk),
      .rst(rst),
      .abort(abort || state == FAIL),
      .consume(state == RELEASE),
      .cmd_valid(loader_cmd),
      .cmd_m(cmd_m),
      .cmd_l(cmd_l),
      .cmd_n(cmd_n),
      .cmd_sparse(cmd_sparse),
      .cmd_ready(loader_idle),
      .data_valid(data_valid && state == LOAD),
      .data(data),
      .last(data_last),
      .data_ready(loader_data_ready),
      .ready(loader_ready),
      .error(loader_error),
      .ar(ar),
      .wr(wr),
      .aa(aa),
      .wa(wa),
      .aq(aq),
      .wq(wq),
      .av(aqv),
      .wv(wqv)
  );
  for (genvar lane = 0; lane < 4; lane = lane + 1) begin
    assign scalar_a[lane*8+:8] = a_stage[lane*32+((slot-lane)&3)*8+:8];
    assign scalar_w[lane*8+:8] = w_stage[lane*32+((slot-lane)&3)*8+:8];
  end
  generate
    if (NATIVE) begin
      dense_os #(
          .R(4),
          .C(4)
      ) core (
          .clk(clk),
          .rst(rst || abort),
          .clear(core_clear),
          .advance(core_advance),
          .a_in(scalar_a),
          .w_in(scalar_w),
          .a_valid(a_valid),
          .w_valid(w_valid),
          .sums(sums)
      );
      assign core_error = 0;
      assign core_phase = 0;
    end else begin
      sparse_os #(
          .R(4),
          .C(4)
      ) core (
          .clk(clk),
          .rst(rst || abort),
          .clear(core_clear),
          .advance(core_advance),
          .sparse_mode(mode),
          .a_in(a_stage),
          .w_in(w_stage),
          .tail_in(tail_stage),
          .code_in(code_stage),
          .a_valid(a_valid),
          .w_valid(w_valid),
          .sums(sums),
          .phase(core_phase),
          .error(core_error)
      );
    end
  endgenerate
  integer index, g, addr;
  always @* begin
    ar = 0;
    wr = 0;
    aa = 0;
    wa = 0;
    desired_av = 0;
    desired_wv = 0;
    desired_tail = 0;
    for (integer b = 0; b < 4; b = b + 1) begin
      index = $signed({1'b0, slot}) - b;
      g = NATIVE ? (index >> 2) : index;
      addr = (tile >> 2) * 4 + g;
      if (index >= 0 && index < (NATIVE ? l : groups)) begin
        if (tile + b < m) begin
          desired_av[b] = 1;
          aa[b*4+:4] = addr;
          for (integer z = 0; z < 4; z = z + 1) desired_tail[b*4+z] = (g * 4 + z < l);
          if (state == ISSUE && (!NATIVE || !a_cached[b] || a_tag[b*4+:4] != addr)) ar[b] = 1;
        end
        if (b < n) begin
          desired_wv[b] = 1;
          wa[b*2+:2] = g;
          if (state == ISSUE && (!NATIVE || !w_cached[b] || w_tag[b*2+:2] != g)) wr[b] = 1;
        end
      end
    end
  end
  reg [3:0] requested_a, requested_w;
  reg [31:0] q0, q1, drain_data;
  reg [5:0] qi0, qi1, drain_index;
  reg [1:0] qcount;
  reg pending;
  reg [6:0] cursor;
  reg [3:0] drain_row;
  reg [1:0] drain_col;
  wire [6:0] output_count=n==1?{2'b0,m}:n==2?{1'b0,m,1'b0}:n==3?({1'b0,m,1'b0}+{2'b0,m}):{m,2'b0};
  wire pop = state == DRAIN && qcount != 0 && out_ready && !rst && !abort;
  wire push = state == DRAIN && pending;
  wire issue_drain = state == DRAIN && cursor < output_count && (qcount - pop + pending) < 2;
  assign out_valid = state == DRAIN && qcount != 0 && !rst && !abort;
  assign out_data = q0;
  assign out_row = qi0[5:2];
  assign out_col = qi0[1:0];
  assign out_id = job_id;
  always @(posedge clk) begin
    if (rst || abort) begin
      state <= IDLE;
      active <= 0;
      error <= 0;
      done <= 0;
      m <= 0;
      n <= 1;
      l <= 0;
      groups <= 0;
      total <= 0;
      committed <= 0;
      job_id <= 0;
      mode <= 0;
      final_slab <= 0;
      tile <= 0;
      merge_row <= 0;
      slot <= 0;
      subphase <= 0;
      a_stage <= 0;
      w_stage <= 0;
      a_valid <= 0;
      w_valid <= 0;
      tail_stage <= 0;
      code_stage <= 0;
      a_cache <= 0;
      w_cache <= 0;
      a_cached <= 0;
      w_cached <= 0;
      a_tag <= 0;
      w_tag <= 0;
      requested_a <= 0;
      requested_w <= 0;
      prior <= 0;
      q0 <= 0;
      q1 <= 0;
      qi0 <= 0;
      qi1 <= 0;
      qcount <= 0;
      pending <= 0;
      cursor <= 0;
      drain_data <= 0;
      drain_index <= 0;
      drain_row <= 0;
      drain_col <= 0;
    end else begin
      done <= 0;
      case (state)
        IDLE:
        if (accept) begin
          if (!good_cmd) begin
            state  <= FAIL;
            error  <= 1;
            active <= 0;
          end else begin
            state <= LOAD;
            active <= 1;
            m <= cmd_m;
            n <= cmd_n;
            l <= cmd_l;
            total <= cmd_k;
            job_id <= cmd_id;
            mode <= cmd_sparse;
            final_slab <= cmd_final;
            groups <= (cmd_l + 3) >> 2;
            tile <= 0;
            if (cmd_first) committed <= 0;
          end
        end
        LOAD:
        if (loader_error) begin
          state  <= FAIL;
          error  <= 1;
          active <= 0;
        end else if (loader_ready) state <= CLEAR;
        CLEAR: begin
          slot <= 0;
          subphase <= 0;
          a_cached <= 0;
          w_cached <= 0;
          state <= ISSUE;
        end
        ISSUE: begin
          requested_a <= ar;
          requested_w <= wr;
          a_valid <= desired_av;
          w_valid <= desired_wv;
          tail_stage <= desired_tail;
          if ((|ar) || (|wr)) state <= CAPTURE;
          else begin
            for (integer b = 0; b < 4; b = b + 1) begin
              a_stage[b*32+:32]  <= desired_av[b] ? a_cache[b*32+:32] : 0;
              w_stage[b*32+:32]  <= desired_wv[b] ? w_cache[b*32+:32] : 0;
              code_stage[b*3+:3] <= desired_wv[b] ? w_cache[b*32+16+:3] : 0;
            end
            state <= EXEC;
          end
        end
        CAPTURE: begin
          for (integer b = 0; b < 4; b = b + 1) begin
            if (requested_a[b]) begin
              a_cache[b*32+:32] <= aq[b*32+:32];
              a_tag[b*4+:4] <= aa[b*4+:4];
              a_cached[b] <= 1;
            end
            if (requested_w[b]) begin
              w_cache[b*32+:32] <= wq[b*32+:32];
              w_tag[b*2+:2] <= wa[b*2+:2];
              w_cached[b] <= 1;
            end
            a_stage[b*32+:32]<=!a_valid[b]?0:(requested_a[b]?aq[b*32+:32]:a_cache[b*32+:32]);
            w_stage[b*32+:32]<=!w_valid[b]?0:(requested_w[b]?wq[b*32+:32]:w_cache[b*32+:32]);
            code_stage[b*3+:3]<=!w_valid[b]?0:(requested_w[b]?wq[b*32+16+:3]:w_cache[b*32+16+:3]);
          end
          state <= EXEC;
        end
        EXEC:
        if (core_error) begin
          error  <= 1;
          active <= 0;
          state  <= FAIL;
        end else if (compute_enable) begin
          if (subphase == last_phase) begin
            subphase <= 0;
            if (slot == total_slots - 1) begin
              merge_row <= 0;
              state <= PREP;
            end else begin
              slot  <= slot + 1'b1;
              state <= ISSUE;
            end
          end else subphase <= subphase + 1'b1;
        end
        PREP: begin
          if (committed == 0) begin
            prior <= 0;
            state <= COMMIT;
          end else state <= PREAD;
        end
        PREAD: begin
          for (integer c = 0; c < 4; c = c + 1)
          if (c < n) prior[c*32+:32] <= p_mem[c][tile+merge_row];
          state <= PWAIT;
        end
        PWAIT: state <= COMMIT;
        COMMIT: begin
          for (integer c = 0; c < 4; c = c + 1)
          if (c < n) p_mem[c][tile+merge_row] <= prior[c*32+:32] + sums[(merge_row*4+c)*32+:32];
          if (merge_row == 3 || tile + merge_row == m - 1) begin
            if (tile + 4 >= m) begin
              committed <= committed + l;
              state <= RELEASE;
            end else begin
              tile  <= tile + 4;
              state <= CLEAR;
            end
          end else begin
            merge_row <= merge_row + 1'b1;
            state <= PREP;
          end
        end
        RELEASE: begin
          if (final_slab) begin
            state <= DRAIN;
            cursor <= 0;
            qcount <= 0;
            pending <= 0;
            drain_row <= 0;
            drain_col <= 0;
          end else begin
            state <= IDLE;
            done  <= 1;
          end
        end
        DRAIN: begin
          pending <= issue_drain;
          if (issue_drain) begin
            drain_data <= p_mem[drain_col][drain_row];
            drain_index <= {drain_row, drain_col};
            cursor <= cursor + 1'b1;
            if (drain_col == n - 1) begin
              drain_col <= 0;
              drain_row <= drain_row + 1'b1;
            end else drain_col <= drain_col + 1'b1;
          end
          case ({
            push, pop
          })
            2'b01: begin
              q0 <= q1;
              qi0 <= qi1;
              qcount <= qcount - 1'b1;
            end
            2'b10: begin
              if (qcount == 0) begin
                q0  <= drain_data;
                qi0 <= drain_index;
              end else begin
                q1  <= drain_data;
                qi1 <= drain_index;
              end
              qcount <= qcount + 1'b1;
            end
            2'b11: begin
              if (qcount == 1) begin
                q0  <= drain_data;
                qi0 <= drain_index;
              end else begin
                q0  <= q1;
                qi0 <= qi1;
                q1  <= drain_data;
                qi1 <= drain_index;
              end
            end
          endcase
          if (pop && qi0[5:2] == m - 1 && qi0[1:0] == n - 1) begin
            active <= 0;
            state  <= IDLE;
            done   <= 1;
          end
        end
        FAIL: begin
          error  <= 1;
          active <= 0;
        end
        default: begin
          state  <= FAIL;
          error  <= 1;
          active <= 0;
        end
      endcase
    end
  end
endmodule
