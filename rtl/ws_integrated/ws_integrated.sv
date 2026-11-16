// Integrated 4x4 weight-stationary host boundary (TK=16).
// Commands reserve alternating loader buffers; computation consumes them in order.
// enq/deq are ownership selectors, not arbitrary bank-selection inputs.
// PSUM storage persists between K slabs. Reset/abort cancel both descriptors.
// See docs/ARCHITECTURE.md for handshake, packing and error semantics.
module ws_integrated (
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
 WISSUE=6,WCAPTURE=7,WLOAD=8,COMMIT=9,RELEASE=10,DRAIN=11,FAIL=12;
  reg [4:0] state, m, l;
  reg [2:0] n, groups;
  reg [13:0] total, committed;
  reg [15:0] job_id;
  reg active, mode, final_slab;
  reg [5:0] slot;
  reg [1:0] subphase, preload_row;
  wire [1:0] last_phase = mode ? 1 : 3;
  wire [5:0] total_slots = {1'b0, m} + {3'b0, n} + 6'd2;
  reg [13:0] accepted_k;
  wire good_cmd=cmd_m>=1 && cmd_m<=16 && cmd_n>=1 && cmd_n<=4 &&
  cmd_k>=1 && cmd_k<=8192 && cmd_offset<cmd_k && cmd_l>=1 && cmd_l<=16 &&
  cmd_l==((cmd_k-cmd_offset>16)?16:cmd_k-cmd_offset) &&
  cmd_final==(cmd_offset+cmd_l==cmd_k) &&
  (cmd_first?(!active && cmd_offset==0):(active && cmd_offset==accepted_k &&
   cmd_id==job_id && cmd_m==m && cmd_n==n && cmd_k==total && cmd_sparse==mode));

  reg enq, deq, loading;
  reg [4:0] desc_l[0:1];
  reg desc_final[0:1];
  wire [1:0] li, lr, le;
  wire [127:0] aqs[0:1], wqs[0:1];
  wire [3:0] avs[0:1], wvs[0:1];
  wire loader_idle = li[enq], loader_ready = lr[deq], loader_error = |le;

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
  reg [31:0] p_mem[0:3][0:15];
  reg [127:0] seed_response, seed_stage;
  reg [3:0] seed_valid;
  wire core_clear = state == CLEAR;
  wire core_advance = state == EXEC && compute_enable && !rst && !abort;
  wire [511:0] sums;
  wire [15:0] core_valids;
  wire core_error;
  wire [1:0] core_phase;
  assign cmd_ready=!loading && loader_idle && !error && !rst && !abort && (!active || accepted_k<total);
  wire loader_data_ready;
  assign data_ready = loading && loader_data_ready && !rst && !abort;
  assign debug_state = state;
  assign debug_advance = core_advance;
  assign debug_sums = sums;
  assign debug_a = a_stage;
  assign debug_w = w_stage;
  assign debug_av = a_valid;
  assign debug_wv = w_valid;
  wire [1:0] dready;
  assign loader_data_ready = dready[enq];
  assign aq = aqs[deq];
  assign wq = wqs[deq];
  assign aqv = avs[deq];
  assign wqv = wvs[deq];
  for (genvar b = 0; b < 2; b = b + 1) begin : buffers
    packed_slab_loader loader (
        .clk(clk),
        .rst(rst),
        .abort(abort || error || state == FAIL),
        .consume(state == RELEASE && deq == b),
        .cmd_valid(loader_cmd && enq == b),
        .cmd_m(cmd_m),
        .cmd_l(cmd_l),
        .cmd_n(cmd_n),
        .cmd_sparse(cmd_sparse),
        .cmd_ready(li[b]),
        .data_valid(data_valid && loading && enq == b),
        .data(data),
        .last(data_last),
        .data_ready(dready[b]),
        .ready(lr[b]),
        .error(le[b]),
        .ar(deq == b ? ar : 4'b0),
        .wr(deq == b ? wr : 4'b0),
        .aa(aa),
        .wa(wa),
        .aq(aqs[b]),
        .wq(wqs[b]),
        .av(avs[b]),
        .wv(wvs[b])
    );
  end
  sparse_ws #(
      .R(4),
      .C(4)
  ) core (
      .clk(clk),
      .rst(rst || abort),
      .clear(core_clear),
      .advance(core_advance),
      .sparse_mode(mode),
      .load(state == WLOAD),
      .load_row(preload_row),
      .weight_in(w_stage),
      .code_in(code_stage),
      .weight_valid(w_valid),
      .a_in(a_stage),
      .tail_in(tail_stage),
      .a_valid(a_valid),
      .psum_in(seed_stage),
      .psum_valid(seed_valid),
      .sums(sums),
      .valids(core_valids),
      .phase(core_phase),
      .error(core_error)
  );
  integer input_row, bank_index;
  always @* begin
    ar = 0;
    wr = 0;
    aa = 0;
    wa = 0;
    input_row = 0;
    bank_index = 0;
    for (integer g = 0; g < 4; g = g + 1) begin
      input_row  = $signed({1'b0, slot}) - g;
      bank_index = input_row & 3;
      if (state == ISSUE && g < groups && input_row >= 0 && input_row < m) begin
        ar[bank_index] = 1;
        aa[bank_index*4+:4] = ((input_row >> 2) << 2) + g;
      end
      if (state == WISSUE && preload_row < groups && g < n) begin
        wr[g] = 1;
        wa[g*2+:2] = preload_row;
      end
    end
  end
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
  assign out_valid = state == DRAIN && qcount != 0 && !rst && !abort && !error;
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
      enq <= 0;
      deq <= 0;
      loading <= 0;
      accepted_k <= 0;
      desc_l[0] <= 0;
      desc_l[1] <= 0;
      desc_final[0] <= 0;
      desc_final[1] <= 0;
      m <= 0;
      n <= 1;
      l <= 0;
      groups <= 0;
      total <= 0;
      committed <= 0;
      job_id <= 0;
      mode <= 0;
      final_slab <= 0;
      slot <= 0;
      subphase <= 0;
      preload_row <= 0;
      a_stage <= 0;
      w_stage <= 0;
      a_valid <= 0;
      w_valid <= 0;
      tail_stage <= 0;
      code_stage <= 0;
      seed_response <= 0;
      seed_stage <= 0;
      seed_valid <= 0;
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
      if (loading && lr[enq]) begin
        loading <= 0;
        enq <= !enq;
      end
      if (accept && good_cmd) begin
        loading <= 1;
        desc_l[enq] <= cmd_l;
        desc_final[enq] <= cmd_final;
        accepted_k <= cmd_offset + cmd_l;
        if (cmd_first) begin
          active <= 1;
          m <= cmd_m;
          n <= cmd_n;
          total <= cmd_k;
          job_id <= cmd_id;
          mode <= cmd_sparse;
          committed <= 0;
        end
      end
      if (loader_error || (accept && !good_cmd)) begin
        error  <= 1;
        state  <= FAIL;
        active <= 0;
      end else
        case (state)
          IDLE:
          if (loader_ready) begin
            l <= desc_l[deq];
            final_slab <= desc_final[deq];
            groups <= (desc_l[deq] + 3) >> 2;
            state <= CLEAR;
          end
          CLEAR: begin
            slot <= 0;
            subphase <= 0;
            preload_row <= 0;
            state <= WISSUE;
          end
          WISSUE: state <= WCAPTURE;
          WCAPTURE: begin
            for (integer c = 0; c < 4; c = c + 1) begin
              w_valid[c] <= preload_row < groups && c < n;
              w_stage[c*32+:32] <= preload_row < groups && c < n ? wq[c*32+:32] : 0;
              code_stage[c*3+:3] <= preload_row < groups && c < n ? wq[c*32+16+:3] : 0;
            end
            state <= WLOAD;
          end
          WLOAD: begin
            if (preload_row == 3) state <= ISSUE;
            else begin
              preload_row <= preload_row + 1'b1;
              state <= WISSUE;
            end
          end
          ISSUE: begin
            for (integer c = 0; c < 4; c = c + 1) begin
              seed_valid[c] <= c < n && slot >= c && slot < c + m;
              if (committed != 0 && c < n && slot >= c && slot < c + m)
                seed_response[c*32+:32] <= p_mem[c][slot-c];
              else seed_response[c*32+:32] <= 0;
            end
            state <= CAPTURE;
          end
          CAPTURE: begin
            seed_stage <= seed_response;
            for (integer g = 0; g < 4; g = g + 1) begin
              a_valid[g] <= g < groups && slot >= g && slot < g + m;
              a_stage[g*32+:32]<=g<groups && slot>=g && slot<g+m?aq[((slot-g)&3)*32+:32]:0;
              for (integer z = 0; z < 4; z = z + 1) tail_stage[g*4+z] <= g * 4 + z < l;
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
              state <= COMMIT;
            end else subphase <= subphase + 1'b1;
          end
          COMMIT: begin
            for (integer c = 0; c < 4; c = c + 1) begin
              if (c < n && slot >= 3 + c && slot < 3 + c + m)
                p_mem[c][slot-3-c] <= sums[(12+c)*32+:32];
            end
            if (slot == total_slots - 1) begin
              committed <= committed + l;
              state <= RELEASE;
            end else begin
              slot  <= slot + 1'b1;
              state <= ISSUE;
            end
          end
          RELEASE: begin
            deq <= !deq;
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
            // No push/pop intentionally holds queue data and occupancy.
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
