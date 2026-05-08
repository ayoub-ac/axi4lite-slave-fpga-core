// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Top-level testbench wrapper for axi4lite_top. Stimulus from
// tb/sim_main.cpp drives the AXI master pins directly.

module axi4lite_top_tb #(
  parameter int unsigned ADDR_WIDTH = 8,
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned NUM_REGS   = 16
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  input  logic [ADDR_WIDTH-1:0]   awaddr,
  input  logic [2:0]              awprot,
  input  logic                    awvalid,
  output logic                    awready,

  input  logic [DATA_WIDTH-1:0]   wdata,
  input  logic [DATA_WIDTH/8-1:0] wstrb,
  input  logic                    wvalid,
  output logic                    wready,

  output logic [1:0]              bresp,
  output logic                    bvalid,
  input  logic                    bready,

  input  logic [ADDR_WIDTH-1:0]   araddr,
  input  logic [2:0]              arprot,
  input  logic                    arvalid,
  output logic                    arready,

  output logic [DATA_WIDTH-1:0]   rdata,
  output logic [1:0]              rresp,
  output logic                    rvalid,
  input  logic                    rready,

  input  logic                    user_busy_i,
  input  logic                    user_done_i,
  input  logic                    user_err_i,
  input  logic                    slv_err_in,
  output logic                    start_pulse_o,
  output logic                    soft_reset_pulse_o,
  output logic                    irq_o
);

  axi4lite_top #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .NUM_REGS  (NUM_REGS)
  ) u_dut (
    .s_axi_aclk        (clk_i),
    .s_axi_aresetn     (rst_ni),
    .s_axi_awaddr      (awaddr),
    .s_axi_awprot      (awprot),
    .s_axi_awvalid     (awvalid),
    .s_axi_awready     (awready),
    .s_axi_wdata       (wdata),
    .s_axi_wstrb       (wstrb),
    .s_axi_wvalid      (wvalid),
    .s_axi_wready      (wready),
    .s_axi_bresp       (bresp),
    .s_axi_bvalid      (bvalid),
    .s_axi_bready      (bready),
    .s_axi_araddr      (araddr),
    .s_axi_arprot      (arprot),
    .s_axi_arvalid     (arvalid),
    .s_axi_arready     (arready),
    .s_axi_rdata       (rdata),
    .s_axi_rresp       (rresp),
    .s_axi_rvalid      (rvalid),
    .s_axi_rready      (rready),
    .user_busy_i       (user_busy_i),
    .user_done_i       (user_done_i),
    .user_err_i        (user_err_i),
    .slv_err_i         (slv_err_in),
    .start_pulse_o     (start_pulse_o),
    .soft_reset_pulse_o(soft_reset_pulse_o),
    .irq_o             (irq_o)
  );

  // ----------------------------------------------------------------
  // Bind the SVA + coverage modules.
  // ----------------------------------------------------------------
  axi4lite_assertions #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH)
  ) u_assert (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .awaddr (awaddr),  .awprot(awprot),  .awvalid(awvalid),  .awready(awready),
    .wdata  (wdata),   .wstrb (wstrb),   .wvalid (wvalid),   .wready (wready),
    .bresp  (bresp),                     .bvalid (bvalid),   .bready (bready),
    .araddr (araddr),  .arprot(arprot),  .arvalid(arvalid),  .arready(arready),
    .rdata  (rdata),   .rresp (rresp),   .rvalid (rvalid),   .rready (rready)
  );

  axi4lite_cov #(
    .DATA_WIDTH(DATA_WIDTH)
  ) u_cov (
    .clk_i  (clk_i),
    .rst_ni (rst_ni),
    .awvalid(awvalid), .awready(awready),
    .wvalid (wvalid),  .wready (wready),  .wstrb (wstrb),
    .bresp  (bresp),   .bvalid (bvalid),  .bready(bready),
    .arvalid(arvalid), .arready(arready),
    .rresp  (rresp),   .rvalid (rvalid),  .rready(rready)
  );

endmodule
