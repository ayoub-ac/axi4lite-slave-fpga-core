// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Functional coverage for axi4lite_top. Sticky bins recorded across the
// regression so the harness prints a single coverage line at end-of-test.
//
// Bins (12 total):
//   c_read_seen        any read transaction completed
//   c_write_seen       any write transaction completed
//   c_resp_okay        BRESP/RRESP == OKAY observed
//   c_resp_slverr      BRESP/RRESP == SLVERR observed
//   c_resp_decerr      BRESP/RRESP == DECERR observed
//   c_strb_full        WSTRB == 4'b1111 observed
//   c_strb_partial     WSTRB partial (any of {0001, 0010, 0100, 1000,
//                                              0011, 1100}) observed
//   c_strb_zero        WSTRB == 0 observed (legal — write is a no-op)
//   c_back_to_back     two B handshakes <=2 cycles apart observed
//   c_aw_first         AW handshook before W on a write
//   c_w_first          W handshook before AW on a write
//   c_long_hold        BVALID or RVALID held >4 cycles waiting for
//                      master READY observed (the "wait scenario" bin)

module axi4lite_cov #(
  parameter int unsigned DATA_WIDTH = 32
) (
  input logic                    clk_i,
  input logic                    rst_ni,

  input logic                    awvalid,
  input logic                    awready,
  input logic                    wvalid,
  input logic                    wready,
  input logic [DATA_WIDTH/8-1:0] wstrb,
  input logic [1:0]              bresp,
  input logic                    bvalid,
  input logic                    bready,
  input logic                    arvalid,
  input logic                    arready,
  input logic [1:0]              rresp,
  input logic                    rvalid,
  input logic                    rready
);

  logic c_read_seen     /*verilator public*/;
  logic c_write_seen    /*verilator public*/;
  logic c_resp_okay     /*verilator public*/;
  logic c_resp_slverr   /*verilator public*/;
  logic c_resp_decerr   /*verilator public*/;
  logic c_strb_full     /*verilator public*/;
  logic c_strb_partial  /*verilator public*/;
  logic c_strb_zero     /*verilator public*/;
  logic c_back_to_back  /*verilator public*/;
  logic c_aw_first      /*verilator public*/;
  logic c_w_first       /*verilator public*/;
  logic c_long_hold     /*verilator public*/;

  logic        aw_seen_first_q;
  logic        w_seen_first_q;
  logic        prev_b_recent_q;
  int unsigned cycles_since_b;
  int unsigned bvalid_held;
  int unsigned rvalid_held;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      aw_seen_first_q  <= 1'b0;
      w_seen_first_q   <= 1'b0;
      prev_b_recent_q  <= 1'b0;
      cycles_since_b   <= 100;
      bvalid_held      <= 0;
      rvalid_held      <= 0;
    end else begin
      // Track ordering on the write side — set by whichever channel
      // handshakes first since the previous B.
      if (awvalid && awready && !aw_seen_first_q && !w_seen_first_q)
        aw_seen_first_q <= 1'b1;
      if (wvalid && wready && !aw_seen_first_q && !w_seen_first_q)
        w_seen_first_q <= 1'b1;

      if (bvalid && bready) begin
        c_write_seen <= 1'b1;
        if (bresp == 2'b00) c_resp_okay   <= 1'b1;
        if (bresp == 2'b10) c_resp_slverr <= 1'b1;
        if (bresp == 2'b11) c_resp_decerr <= 1'b1;
        if (aw_seen_first_q) c_aw_first <= 1'b1;
        if (w_seen_first_q)  c_w_first  <= 1'b1;
        aw_seen_first_q <= 1'b0;
        w_seen_first_q  <= 1'b0;

        // Back-to-back: a previous B happened within 2 cycles.
        if (prev_b_recent_q) c_back_to_back <= 1'b1;
        prev_b_recent_q <= 1'b1;
        cycles_since_b  <= 0;
      end else begin
        if (cycles_since_b < 100) cycles_since_b <= cycles_since_b + 1;
        if (cycles_since_b > 2)   prev_b_recent_q <= 1'b0;
      end

      // WSTRB observation on any W beat.
      if (wvalid && wready) begin
        if (DATA_WIDTH == 32) begin
          if (wstrb == 4'b1111) c_strb_full <= 1'b1;
          else if (wstrb == 4'b0000) c_strb_zero <= 1'b1;
          else c_strb_partial <= 1'b1;
        end else begin
          if (&wstrb)        c_strb_full    <= 1'b1;
          else if (|wstrb)   c_strb_partial <= 1'b1;
          else               c_strb_zero    <= 1'b1;
        end
      end

      if (rvalid && rready) begin
        c_read_seen <= 1'b1;
        if (rresp == 2'b00) c_resp_okay   <= 1'b1;
        if (rresp == 2'b10) c_resp_slverr <= 1'b1;
        if (rresp == 2'b11) c_resp_decerr <= 1'b1;
      end

      // Long-hold: BVALID or RVALID held >=4 cycles before READY.
      if (bvalid && !bready) begin
        bvalid_held <= bvalid_held + 1;
        if (bvalid_held >= 4) c_long_hold <= 1'b1;
      end else begin
        bvalid_held <= 0;
      end
      if (rvalid && !rready) begin
        rvalid_held <= rvalid_held + 1;
        if (rvalid_held >= 4) c_long_hold <= 1'b1;
      end else begin
        rvalid_held <= 0;
      end
    end
  end

  initial begin
    c_read_seen    = 1'b0;
    c_write_seen   = 1'b0;
    c_resp_okay    = 1'b0;
    c_resp_slverr  = 1'b0;
    c_resp_decerr  = 1'b0;
    c_strb_full    = 1'b0;
    c_strb_partial = 1'b0;
    c_strb_zero    = 1'b0;
    c_back_to_back = 1'b0;
    c_aw_first     = 1'b0;
    c_w_first      = 1'b0;
    c_long_hold    = 1'b0;
  end

endmodule
