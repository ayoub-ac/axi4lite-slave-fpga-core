// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
//
// Minimal AXI4-Lite master bus-functional model (BFM).
//
// The BFM exposes a small command interface that the C++ harness (or
// any SV testbench) drives one beat at a time. It is NOT a full master
// agent — there is no out-of-order issuing, no concurrent AW/W issuing
// across distinct transactions, no random latency injection. What it
// does:
//
//   * cmd_kind == CMD_WRITE: drive AWVALID + WVALID with the supplied
//     addr/data/strb on the next cycle, wait for the slave's AWREADY
//     and WREADY (independently), then wait for BVALID. Latches BRESP
//     into resp_o and pulses done_o on completion.
//   * cmd_kind == CMD_READ:  drive ARVALID with the supplied addr,
//     wait for ARREADY, then wait for RVALID. Latches RDATA into
//     rdata_o and RRESP into resp_o. Pulses done_o on completion.
//
// AW/W ordering can be controlled via aw_first_i / w_first_i. By default
// (both low) the BFM asserts both VALIDs on the same cycle. Setting
// aw_first_i delays the WVALID by 1..N cycles (parametric); setting
// w_first_i does the same for AWVALID. This is how the back-to-back /
// hold scenarios are exercised.
//
// READY-low scenarios are exercised on the master side by holding
// b_hold_i / r_hold_i: when high, the BFM keeps BREADY / RREADY low
// until cleared. This stresses the slave's "stable while not accepted"
// behaviour and gives the SVA p_*_stable properties something to do.

module axi4lite_master_bfm #(
  parameter int unsigned ADDR_WIDTH = 8,
  parameter int unsigned DATA_WIDTH = 32
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // Command interface (driven from outside).
  input  logic                    cmd_valid_i,
  input  logic [1:0]              cmd_kind_i,        // 00 idle, 01 read, 10 write
  input  logic [ADDR_WIDTH-1:0]   cmd_addr_i,
  input  logic [DATA_WIDTH-1:0]   cmd_data_i,
  input  logic [DATA_WIDTH/8-1:0] cmd_strb_i,
  input  logic [3:0]              cmd_aw_first_i,    // # cycles to delay W after AW (0..15)
  input  logic [3:0]              cmd_w_first_i,     // # cycles to delay AW after W
  input  logic [3:0]              cmd_b_hold_i,      // # cycles BREADY held low after BVALID
  input  logic [3:0]              cmd_r_hold_i,      // # cycles RREADY held low after RVALID
  output logic                    cmd_ready_o,
  output logic                    cmd_done_o,
  output logic [1:0]              cmd_resp_o,
  output logic [DATA_WIDTH-1:0]   cmd_rdata_o,

  // AXI4-Lite master pins (drive the slave under test)
  output logic [ADDR_WIDTH-1:0]   m_axi_awaddr,
  output logic [2:0]              m_axi_awprot,
  output logic                    m_axi_awvalid,
  input  logic                    m_axi_awready,

  output logic [DATA_WIDTH-1:0]   m_axi_wdata,
  output logic [DATA_WIDTH/8-1:0] m_axi_wstrb,
  output logic                    m_axi_wvalid,
  input  logic                    m_axi_wready,

  input  logic [1:0]              m_axi_bresp,
  input  logic                    m_axi_bvalid,
  output logic                    m_axi_bready,

  output logic [ADDR_WIDTH-1:0]   m_axi_araddr,
  output logic [2:0]              m_axi_arprot,
  output logic                    m_axi_arvalid,
  input  logic                    m_axi_arready,

  input  logic [DATA_WIDTH-1:0]   m_axi_rdata,
  input  logic [1:0]              m_axi_rresp,
  input  logic                    m_axi_rvalid,
  output logic                    m_axi_rready
);

  localparam logic [1:0] K_IDLE  = 2'b00;
  localparam logic [1:0] K_READ  = 2'b01;
  localparam logic [1:0] K_WRITE = 2'b10;

  typedef enum logic [3:0] {
    S_IDLE,
    S_W_DRIVE_AW, S_W_DRIVE_W, S_W_WAIT_AW, S_W_WAIT_W, S_W_WAIT_B,
    S_R_DRIVE_AR, S_R_WAIT_AR, S_R_WAIT_R,
    S_DONE
  } st_e;

  st_e st_q, st_d;

  logic [3:0] delay_q;
  logic       aw_done_q;
  logic       w_done_q;
  logic [ADDR_WIDTH-1:0]   addr_q;
  logic [DATA_WIDTH-1:0]   data_q;
  logic [DATA_WIDTH/8-1:0] strb_q;
  logic [3:0]              aw_first_q;
  logic [3:0]              w_first_q;
  logic [3:0]              b_hold_q;
  logic [3:0]              r_hold_q;

  logic [1:0]              resp_q;
  logic [DATA_WIDTH-1:0]   rdata_q;
  logic                    done_q;

  // Drive logic.
  assign m_axi_awaddr  = addr_q;
  assign m_axi_awprot  = 3'b000;
  assign m_axi_wdata   = data_q;
  assign m_axi_wstrb   = strb_q;
  assign m_axi_araddr  = addr_q;
  assign m_axi_arprot  = 3'b000;

  // VALID assertions are gated on state.
  always_comb begin
    m_axi_awvalid = 1'b0;
    m_axi_wvalid  = 1'b0;
    m_axi_arvalid = 1'b0;
    m_axi_bready  = 1'b0;
    m_axi_rready  = 1'b0;

    case (st_q)
      S_W_DRIVE_AW: m_axi_awvalid = 1'b1;
      S_W_DRIVE_W:  m_axi_wvalid  = 1'b1;
      S_W_WAIT_AW:  m_axi_awvalid = !aw_done_q;
      S_W_WAIT_W:   m_axi_wvalid  = !w_done_q;
      S_W_WAIT_B:   m_axi_bready  = (b_hold_q == 0);
      S_R_DRIVE_AR: m_axi_arvalid = 1'b1;
      S_R_WAIT_AR:  m_axi_arvalid = 1'b1;
      S_R_WAIT_R:   m_axi_rready  = (r_hold_q == 0);
      default: ;
    endcase

    // While in the joint-drive states for write, also keep both VALIDs
    // up if neither side has handshaken yet.
    if (st_q == S_W_WAIT_AW || st_q == S_W_WAIT_W) begin
      if (!aw_done_q) m_axi_awvalid = 1'b1;
      if (!w_done_q)  m_axi_wvalid  = 1'b1;
    end
  end

  assign cmd_ready_o = (st_q == S_IDLE);
  assign cmd_done_o  = done_q;
  assign cmd_resp_o  = resp_q;
  assign cmd_rdata_o = rdata_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      st_q       <= S_IDLE;
      delay_q    <= 4'd0;
      aw_done_q  <= 1'b0;
      w_done_q   <= 1'b0;
      addr_q     <= '0;
      data_q     <= '0;
      strb_q     <= '0;
      aw_first_q <= '0;
      w_first_q  <= '0;
      b_hold_q   <= '0;
      r_hold_q   <= '0;
      resp_q     <= 2'b00;
      rdata_q    <= '0;
      done_q     <= 1'b0;
    end else begin
      done_q <= 1'b0;

      case (st_q)
        S_IDLE: begin
          if (cmd_valid_i) begin
            addr_q     <= cmd_addr_i;
            data_q     <= cmd_data_i;
            strb_q     <= cmd_strb_i;
            aw_first_q <= cmd_aw_first_i;
            w_first_q  <= cmd_w_first_i;
            b_hold_q   <= cmd_b_hold_i;
            r_hold_q   <= cmd_r_hold_i;
            aw_done_q  <= 1'b0;
            w_done_q   <= 1'b0;
            if (cmd_kind_i == K_WRITE) begin
              if (cmd_aw_first_i != 0) begin
                delay_q <= cmd_aw_first_i;
                st_q    <= S_W_DRIVE_AW;
              end else if (cmd_w_first_i != 0) begin
                delay_q <= cmd_w_first_i;
                st_q    <= S_W_DRIVE_W;
              end else begin
                st_q <= S_W_WAIT_AW;
              end
            end else if (cmd_kind_i == K_READ) begin
              st_q <= S_R_WAIT_AR;
            end
          end
        end

        // Drive AW first; W still gated.
        S_W_DRIVE_AW: begin
          if (m_axi_awvalid && m_axi_awready) aw_done_q <= 1'b1;
          if (delay_q == 1) begin
            st_q <= S_W_WAIT_AW;
          end else begin
            delay_q <= delay_q - 4'd1;
          end
        end

        // Drive W first; AW still gated.
        S_W_DRIVE_W: begin
          if (m_axi_wvalid && m_axi_wready) w_done_q <= 1'b1;
          if (delay_q == 1) begin
            st_q <= S_W_WAIT_W;
          end else begin
            delay_q <= delay_q - 4'd1;
          end
        end

        // Joint wait: drive both VALIDs until each side has handshaken.
        S_W_WAIT_AW, S_W_WAIT_W: begin
          if (m_axi_awvalid && m_axi_awready) aw_done_q <= 1'b1;
          if (m_axi_wvalid  && m_axi_wready)  w_done_q  <= 1'b1;
          if ((aw_done_q || (m_axi_awvalid && m_axi_awready)) &&
              (w_done_q  || (m_axi_wvalid  && m_axi_wready))) begin
            st_q <= S_W_WAIT_B;
          end
        end

        S_W_WAIT_B: begin
          if (b_hold_q != 0) begin
            b_hold_q <= b_hold_q - 4'd1;
          end else if (m_axi_bvalid && m_axi_bready) begin
            resp_q <= m_axi_bresp;
            done_q <= 1'b1;
            st_q   <= S_IDLE;
          end
        end

        S_R_WAIT_AR: begin
          if (m_axi_arvalid && m_axi_arready) begin
            st_q <= S_R_WAIT_R;
          end
        end

        S_R_WAIT_R: begin
          if (r_hold_q != 0) begin
            r_hold_q <= r_hold_q - 4'd1;
          end else if (m_axi_rvalid && m_axi_rready) begin
            resp_q  <= m_axi_rresp;
            rdata_q <= m_axi_rdata;
            done_q  <= 1'b1;
            st_q    <= S_IDLE;
          end
        end

        default: st_q <= S_IDLE;
      endcase
    end
  end

endmodule
