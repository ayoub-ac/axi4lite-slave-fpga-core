// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Example top wrapping axi4lite_slave with a representative register
// map. Use this as a starting point for wrapping any of the sibling IP
// cores (AES / SHA / ChaCha / Keccak) with a software-visible control
// interface.
//
// Register map (16 x 32-bit, byte address space 0x00..0x3C):
//   0x00  CTRL       RW    bit 0 = start, bit 1 = soft-reset, bits 31:2 reserved
//   0x04  STATUS     RO    bit 0 = busy, bit 1 = done, bit 2 = err
//   0x08  IRQ_STAT   W1C   bit 0 = done_irq, bit 1 = err_irq, bit 2 = ovf_irq
//   0x0C  IRQ_MASK   RW    1 = irq enabled, 0 = masked
//   0x10  SCRATCH0   RW    user scratch
//   0x14  SCRATCH1   RW    user scratch
//   0x18  ID         RO    32'hA1C4_017E (dummy ID, overwrite per project)
//   0x1C  VERSION    RO    32'h00010000  (major.minor)
//   0x20  EVENT_CNT  RC    read-clear counter
//   0x24..0x3C       RW    user registers (general purpose)
//
// REG_ATTR encoding (2 bits per register, register 0 in LSBs):
//   00 RW  / 01 RO / 10 RC / 11 W1C

module axi4lite_top #(
  parameter int unsigned ADDR_WIDTH = 8,
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned NUM_REGS   = 16
) (
  input  logic                    s_axi_aclk,
  input  logic                    s_axi_aresetn,

  input  logic [ADDR_WIDTH-1:0]   s_axi_awaddr,
  input  logic [2:0]              s_axi_awprot,
  input  logic                    s_axi_awvalid,
  output logic                    s_axi_awready,

  input  logic [DATA_WIDTH-1:0]   s_axi_wdata,
  input  logic [DATA_WIDTH/8-1:0] s_axi_wstrb,
  input  logic                    s_axi_wvalid,
  output logic                    s_axi_wready,

  output logic [1:0]              s_axi_bresp,
  output logic                    s_axi_bvalid,
  input  logic                    s_axi_bready,

  input  logic [ADDR_WIDTH-1:0]   s_axi_araddr,
  input  logic [2:0]              s_axi_arprot,
  input  logic                    s_axi_arvalid,
  output logic                    s_axi_arready,

  output logic [DATA_WIDTH-1:0]   s_axi_rdata,
  output logic [1:0]              s_axi_rresp,
  output logic                    s_axi_rvalid,
  input  logic                    s_axi_rready,

  // User-side: live status into RO registers, write-event observability.
  input  logic                    user_busy_i,
  input  logic                    user_done_i,
  input  logic                    user_err_i,
  // Optional integrator hint: hold high to make the slave respond
  // SLVERR on the in-flight transaction (e.g. an upstream check
  // rejected the write). Tie low when unused.
  input  logic                    slv_err_i,
  output logic                    start_pulse_o,
  output logic                    soft_reset_pulse_o,
  output logic                    irq_o
);

  // REG_ATTR per the table above. 16 registers; LSB pair = reg 0.
  // We pack: 0:RW 1:RO 2:W1C 3:RW 4:RW 5:RW 6:RO 7:RO 8:RC 9..15:RW
  // (9..15 default to RW = 2'b00).
  localparam logic [2*NUM_REGS-1:0] EX_REG_ATTR = {
      2'b00, 2'b00, 2'b00, 2'b00, 2'b00, 2'b00, 2'b00,  // 15..9
      2'b10,                                            // 8  RC
      2'b01, 2'b01,                                     // 7,6 RO
      2'b00, 2'b00,                                     // 5,4 RW
      2'b00, 2'b11,                                     // 3 RW, 2 W1C
      2'b01, 2'b00                                      // 1 RO, 0 RW
  };

  // Reset values: ID at 0x18 = reg6, VERSION at 0x1C = reg7.
  localparam logic [DATA_WIDTH-1:0] ID_VAL      = 32'hA1C4_017E;
  localparam logic [DATA_WIDTH-1:0] VERSION_VAL = 32'h0001_0000;

  // Build the per-index reset vector. Reg 6 = ID, reg 7 = VERSION; the
  // remaining registers default to zero. We construct the value as a
  // shift-OR of the two non-zero entries so Yosys parses the result as
  // a constant expression (it does not accept SystemVerilog `return`
  // inside a localparam-feeding function).
  localparam logic [NUM_REGS*DATA_WIDTH-1:0] EX_REG_RESET =
        ({{(NUM_REGS*DATA_WIDTH-DATA_WIDTH){1'b0}}, ID_VAL}      << (6*DATA_WIDTH))
      | ({{(NUM_REGS*DATA_WIDTH-DATA_WIDTH){1'b0}}, VERSION_VAL} << (7*DATA_WIDTH));

  // Build live read payload (RO register values).
  logic [NUM_REGS*DATA_WIDTH-1:0] rd_payload;
  logic [DATA_WIDTH-1:0]          status_word;
  assign status_word = {{(DATA_WIDTH-3){1'b0}},
                        user_err_i, user_done_i, user_busy_i};

  always_comb begin
    rd_payload = '0;
    rd_payload[1*DATA_WIDTH +: DATA_WIDTH] = status_word;     // STATUS
    rd_payload[6*DATA_WIDTH +: DATA_WIDTH] = ID_VAL;          // ID
    rd_payload[7*DATA_WIDTH +: DATA_WIDTH] = VERSION_VAL;     // VERSION
  end

  // Hook outputs from the slave.
  logic [NUM_REGS*DATA_WIDTH-1:0] reg_storage;
  logic                           wr_event;
  logic [ADDR_WIDTH-1:0]          wr_event_addr;
  logic                           rd_event_unused;
  logic [ADDR_WIDTH-1:0]          rd_event_addr_unused;

  axi4lite_slave #(
    .ADDR_WIDTH(ADDR_WIDTH),
    .DATA_WIDTH(DATA_WIDTH),
    .NUM_REGS  (NUM_REGS),
    .REG_ATTR  (EX_REG_ATTR),
    .REG_RESET (EX_REG_RESET)
  ) u_slave (
    .s_axi_aclk     (s_axi_aclk),
    .s_axi_aresetn  (s_axi_aresetn),
    .s_axi_awaddr   (s_axi_awaddr),
    .s_axi_awprot   (s_axi_awprot),
    .s_axi_awvalid  (s_axi_awvalid),
    .s_axi_awready  (s_axi_awready),
    .s_axi_wdata    (s_axi_wdata),
    .s_axi_wstrb    (s_axi_wstrb),
    .s_axi_wvalid   (s_axi_wvalid),
    .s_axi_wready   (s_axi_wready),
    .s_axi_bresp    (s_axi_bresp),
    .s_axi_bvalid   (s_axi_bvalid),
    .s_axi_bready   (s_axi_bready),
    .s_axi_araddr   (s_axi_araddr),
    .s_axi_arprot   (s_axi_arprot),
    .s_axi_arvalid  (s_axi_arvalid),
    .s_axi_arready  (s_axi_arready),
    .s_axi_rdata    (s_axi_rdata),
    .s_axi_rresp    (s_axi_rresp),
    .s_axi_rvalid   (s_axi_rvalid),
    .s_axi_rready   (s_axi_rready),
    .rd_payload_i   (rd_payload),
    .slv_err_i      (slv_err_i),
    .reg_storage_o  (reg_storage),
    .wr_event_o     (wr_event),
    .wr_event_addr_o(wr_event_addr),
    .rd_event_o     (rd_event_unused),
    .rd_event_addr_o(rd_event_addr_unused)
  );

  // CTRL register: bit0 = start, bit1 = soft_reset. Generate one-cycle
  // pulses on a successful write to address 0 (CTRL).
  logic ctrl_write_now;
  assign ctrl_write_now = wr_event && (wr_event_addr[ADDR_WIDTH-1:2] == '0);

  logic [DATA_WIDTH-1:0] ctrl_word;
  assign ctrl_word = reg_storage[0 +: DATA_WIDTH];

  always_ff @(posedge s_axi_aclk) begin
    if (!s_axi_aresetn) begin
      start_pulse_o      <= 1'b0;
      soft_reset_pulse_o <= 1'b0;
    end else begin
      start_pulse_o      <= ctrl_write_now && ctrl_word[0];
      soft_reset_pulse_o <= ctrl_write_now && ctrl_word[1];
    end
  end

  // IRQ: OR of (IRQ_STAT[i] & IRQ_MASK[i]).
  logic [DATA_WIDTH-1:0] irq_stat_word;
  logic [DATA_WIDTH-1:0] irq_mask_word;
  assign irq_stat_word = reg_storage[2*DATA_WIDTH +: DATA_WIDTH];
  assign irq_mask_word = reg_storage[3*DATA_WIDTH +: DATA_WIDTH];
  assign irq_o = |(irq_stat_word & irq_mask_word);

endmodule
