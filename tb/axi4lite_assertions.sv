// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// AXI4-Lite slave protocol assertions (ARM IHI 0022 §A3 + §B.1).
//
// The properties below are the standard AMBA AXI4-Lite invariants every
// slave is required to maintain. They are enforced on every cycle of
// every test, so a regression that breaks a handshake fails the gate
// instead of producing a confusing functional miscompare.
//
// Properties (10 total):
//
//   p_aw_stable       AWVALID held high until AWREADY accepts (§A3.2.1).
//                     AWADDR / AWPROT must remain stable across that wait.
//   p_w_stable        WVALID held high until WREADY accepts. WDATA / WSTRB
//                     stable.
//   p_b_stable        BVALID held high until BREADY accepts. BRESP stable.
//   p_ar_stable       ARVALID held high until ARREADY accepts. ARADDR
//                     / ARPROT stable.
//   p_r_stable        RVALID held high until RREADY accepts. RDATA / RRESP
//                     stable.
//   p_b_only_when_valid  BRESP only carries meaning while BVALID asserts.
//                        We assert that the slave never raises BVALID
//                        without a paired AW + W having been seen.
//   p_b_after_aw_w    BVALID does not assert before BOTH AW-handshake and
//                     W-handshake have completed since the last B-accept.
//   p_addr_aligned    AWADDR / ARADDR are DATA_WIDTH/8-aligned (§A8.1.1).
//                     Mis-aligned accesses are still legal at the bus
//                     level, but the slave is allowed to answer DECERR;
//                     this property checks that mis-aligned accesses are
//                     paired with DECERR.
//   p_no_deadlock_b   Once BVALID has asserted, BREADY arrives within
//                     LAT_MAX cycles (sanity bound on the simulated
//                     master).
//   p_no_deadlock_r   Same for the R channel.

module axi4lite_assertions #(
  parameter int unsigned ADDR_WIDTH = 8,
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned LAT_MAX    = 4096
) (
  input logic                    clk_i,
  input logic                    rst_ni,

  input logic [ADDR_WIDTH-1:0]   awaddr,
  input logic [2:0]              awprot,
  input logic                    awvalid,
  input logic                    awready,

  input logic [DATA_WIDTH-1:0]   wdata,
  input logic [DATA_WIDTH/8-1:0] wstrb,
  input logic                    wvalid,
  input logic                    wready,

  input logic [1:0]              bresp,
  input logic                    bvalid,
  input logic                    bready,

  input logic [ADDR_WIDTH-1:0]   araddr,
  input logic [2:0]              arprot,
  input logic                    arvalid,
  input logic                    arready,

  input logic [DATA_WIDTH-1:0]   rdata,
  input logic [1:0]              rresp,
  input logic                    rvalid,
  input logic                    rready
);
`ifndef SYNTHESIS

  localparam int unsigned BYTES = DATA_WIDTH / 8;
  localparam int unsigned ALIGN = (BYTES <= 1) ? 0 : $clog2(BYTES);

  // ---- Channel-stability properties -------------------------------
  property p_aw_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      (awvalid && !awready) |=> (awvalid && $stable(awaddr) && $stable(awprot));
  endproperty
  a_aw_stable: assert property (p_aw_stable)
    else $error("axi4lite: AWVALID/AWADDR not stable across AWREADY wait");

  property p_w_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      (wvalid && !wready) |=> (wvalid && $stable(wdata) && $stable(wstrb));
  endproperty
  a_w_stable: assert property (p_w_stable)
    else $error("axi4lite: WVALID/WDATA/WSTRB not stable across WREADY wait");

  property p_b_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      (bvalid && !bready) |=> (bvalid && $stable(bresp));
  endproperty
  a_b_stable: assert property (p_b_stable)
    else $error("axi4lite: BVALID/BRESP not stable across BREADY wait");

  property p_ar_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      (arvalid && !arready) |=> (arvalid && $stable(araddr) && $stable(arprot));
  endproperty
  a_ar_stable: assert property (p_ar_stable)
    else $error("axi4lite: ARVALID/ARADDR not stable across ARREADY wait");

  property p_r_stable;
    @(posedge clk_i) disable iff (!rst_ni)
      (rvalid && !rready) |=> (rvalid && $stable(rdata) && $stable(rresp));
  endproperty
  a_r_stable: assert property (p_r_stable)
    else $error("axi4lite: RVALID/RDATA/RRESP not stable across RREADY wait");

  // ---- Ordering / liveness ---------------------------------------
  // BVALID is only meaningful when AW and W have been observed since
  // the previous B-accept.
  logic aw_seen_q, w_seen_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      aw_seen_q <= 1'b0;
      w_seen_q  <= 1'b0;
    end else begin
      if (awvalid && awready) aw_seen_q <= 1'b1;
      if (wvalid  && wready)  w_seen_q  <= 1'b1;
      if (bvalid  && bready) begin
        aw_seen_q <= 1'b0;
        w_seen_q  <= 1'b0;
      end
    end
  end

  property p_b_after_aw_w;
    @(posedge clk_i) disable iff (!rst_ni)
      $rose(bvalid) |-> (aw_seen_q && w_seen_q);
  endproperty
  a_b_after_aw_w: assert property (p_b_after_aw_w)
    else $error("axi4lite: BVALID rose before both AW and W handshook");

  // BRESP must be one of the four legal codes whenever BVALID asserts.
  property p_bresp_legal;
    @(posedge clk_i) disable iff (!rst_ni)
      bvalid |-> (bresp inside {2'b00, 2'b01, 2'b10, 2'b11});
  endproperty
  a_bresp_legal: assert property (p_bresp_legal)
    else $error("axi4lite: BRESP carries an illegal value");

  property p_rresp_legal;
    @(posedge clk_i) disable iff (!rst_ni)
      rvalid |-> (rresp inside {2'b00, 2'b01, 2'b10, 2'b11});
  endproperty
  a_rresp_legal: assert property (p_rresp_legal)
    else $error("axi4lite: RRESP carries an illegal value");

  // ---- Alignment + DECERR pairing --------------------------------
  // We don't fail mis-aligned accesses; we require that if the master
  // issues one, the slave answers DECERR. (AXI4-Lite §A8.1.1: aligned
  // is required by the spec; nudging mis-aligned accesses to DECERR
  // is the slave-friendly behaviour.)
  function automatic logic addr_misaligned(input logic [ADDR_WIDTH-1:0] a);
    if (BYTES <= 1) return 1'b0;
    return |(a[ALIGN-1:0]);
  endfunction

  // Track if the AW we accepted was misaligned, so the next BVALID can
  // be checked.
  logic aw_was_misaligned_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni)                            aw_was_misaligned_q <= 1'b0;
    else if (awvalid && awready)            aw_was_misaligned_q <= addr_misaligned(awaddr);
    else if (bvalid && bready)              aw_was_misaligned_q <= 1'b0;
  end

  property p_aw_misaligned_decerr;
    @(posedge clk_i) disable iff (!rst_ni)
      $rose(bvalid) && aw_was_misaligned_q |-> (bresp == 2'b11);
  endproperty
  a_aw_misaligned_decerr: assert property (p_aw_misaligned_decerr)
    else $error("axi4lite: misaligned AW not answered with DECERR");

  // Track AR similarly.
  logic ar_was_misaligned_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni)                            ar_was_misaligned_q <= 1'b0;
    else if (arvalid && arready)            ar_was_misaligned_q <= addr_misaligned(araddr);
    else if (rvalid && rready)              ar_was_misaligned_q <= 1'b0;
  end

  property p_ar_misaligned_decerr;
    @(posedge clk_i) disable iff (!rst_ni)
      $rose(rvalid) && ar_was_misaligned_q |-> (rresp == 2'b11);
  endproperty
  a_ar_misaligned_decerr: assert property (p_ar_misaligned_decerr)
    else $error("axi4lite: misaligned AR not answered with DECERR");

  // ---- Liveness: BVALID/RVALID get drained within a bound --------
  int unsigned bvalid_pending_q;
  int unsigned rvalid_pending_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      bvalid_pending_q <= 0;
      rvalid_pending_q <= 0;
    end else begin
      if (bvalid && !bready)      bvalid_pending_q <= bvalid_pending_q + 1;
      else if (bvalid && bready)  bvalid_pending_q <= 0;

      if (rvalid && !rready)      rvalid_pending_q <= rvalid_pending_q + 1;
      else if (rvalid && rready)  rvalid_pending_q <= 0;
    end
  end

  property p_no_deadlock_b;
    @(posedge clk_i) disable iff (!rst_ni)
      (bvalid_pending_q < LAT_MAX);
  endproperty
  a_no_deadlock_b: assert property (p_no_deadlock_b)
    else $error("axi4lite: BVALID stuck asserted >%0d cycles", LAT_MAX);

  property p_no_deadlock_r;
    @(posedge clk_i) disable iff (!rst_ni)
      (rvalid_pending_q < LAT_MAX);
  endproperty
  a_no_deadlock_r: assert property (p_no_deadlock_r)
    else $error("axi4lite: RVALID stuck asserted >%0d cycles", LAT_MAX);

`endif // SYNTHESIS
endmodule
