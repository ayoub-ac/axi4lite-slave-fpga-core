-- SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
--
-- VHDL-2008 wrapper for the SystemVerilog axi4lite_top module.
--
-- This entity exposes the slave's port list in VHDL syntax. The
-- architecture instantiates the SystemVerilog module by component name;
-- mixed-language elaboration is supported natively by Vivado, Quartus,
-- ModelSim/Questa, and Aldec, and via the GHDL VHPI bridge for open
-- simulation.
--
-- Status: WRAPPER ONLY. The slave datapath itself remains in SystemVerilog
-- (rtl/*.sv). A native VHDL port of the datapath is listed as future work.
--
-- I/O contract: identical to axi4lite_top.sv (see PORT_DESCRIPTION.md).
--   * Single clock, active-low synchronous reset.
--   * Standard AXI4-Lite handshake on AW/W/B/AR/R.
--   * 16 x 32-bit register file with mixed RW/RO/RC/W1C semantics.

library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;

entity axi4lite_top_vhdl is
  generic (
    ADDR_WIDTH : integer := 8;
    DATA_WIDTH : integer := 32;
    NUM_REGS   : integer := 16
  );
  port (
    s_axi_aclk         : in  std_logic;
    s_axi_aresetn      : in  std_logic;

    s_axi_awaddr       : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    s_axi_awprot       : in  std_logic_vector(2 downto 0);
    s_axi_awvalid      : in  std_logic;
    s_axi_awready      : out std_logic;

    s_axi_wdata        : in  std_logic_vector(DATA_WIDTH-1 downto 0);
    s_axi_wstrb        : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
    s_axi_wvalid       : in  std_logic;
    s_axi_wready       : out std_logic;

    s_axi_bresp        : out std_logic_vector(1 downto 0);
    s_axi_bvalid       : out std_logic;
    s_axi_bready       : in  std_logic;

    s_axi_araddr       : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
    s_axi_arprot       : in  std_logic_vector(2 downto 0);
    s_axi_arvalid      : in  std_logic;
    s_axi_arready      : out std_logic;

    s_axi_rdata        : out std_logic_vector(DATA_WIDTH-1 downto 0);
    s_axi_rresp        : out std_logic_vector(1 downto 0);
    s_axi_rvalid       : out std_logic;
    s_axi_rready       : in  std_logic;

    user_busy_i        : in  std_logic;
    user_done_i        : in  std_logic;
    user_err_i         : in  std_logic;
    start_pulse_o      : out std_logic;
    soft_reset_pulse_o : out std_logic;
    irq_o              : out std_logic
  );
end entity axi4lite_top_vhdl;

architecture rtl of axi4lite_top_vhdl is

  component axi4lite_top
    generic (
      ADDR_WIDTH : integer := 8;
      DATA_WIDTH : integer := 32;
      NUM_REGS   : integer := 16
    );
    port (
      s_axi_aclk         : in  std_logic;
      s_axi_aresetn      : in  std_logic;
      s_axi_awaddr       : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
      s_axi_awprot       : in  std_logic_vector(2 downto 0);
      s_axi_awvalid      : in  std_logic;
      s_axi_awready      : out std_logic;
      s_axi_wdata        : in  std_logic_vector(DATA_WIDTH-1 downto 0);
      s_axi_wstrb        : in  std_logic_vector(DATA_WIDTH/8-1 downto 0);
      s_axi_wvalid       : in  std_logic;
      s_axi_wready       : out std_logic;
      s_axi_bresp        : out std_logic_vector(1 downto 0);
      s_axi_bvalid       : out std_logic;
      s_axi_bready       : in  std_logic;
      s_axi_araddr       : in  std_logic_vector(ADDR_WIDTH-1 downto 0);
      s_axi_arprot       : in  std_logic_vector(2 downto 0);
      s_axi_arvalid      : in  std_logic;
      s_axi_arready      : out std_logic;
      s_axi_rdata        : out std_logic_vector(DATA_WIDTH-1 downto 0);
      s_axi_rresp        : out std_logic_vector(1 downto 0);
      s_axi_rvalid       : out std_logic;
      s_axi_rready       : in  std_logic;
      user_busy_i        : in  std_logic;
      user_done_i        : in  std_logic;
      user_err_i         : in  std_logic;
      start_pulse_o      : out std_logic;
      soft_reset_pulse_o : out std_logic;
      irq_o              : out std_logic
    );
  end component;

begin

  u_top : axi4lite_top
    generic map (
      ADDR_WIDTH => ADDR_WIDTH,
      DATA_WIDTH => DATA_WIDTH,
      NUM_REGS   => NUM_REGS
    )
    port map (
      s_axi_aclk         => s_axi_aclk,
      s_axi_aresetn      => s_axi_aresetn,
      s_axi_awaddr       => s_axi_awaddr,
      s_axi_awprot       => s_axi_awprot,
      s_axi_awvalid      => s_axi_awvalid,
      s_axi_awready      => s_axi_awready,
      s_axi_wdata        => s_axi_wdata,
      s_axi_wstrb        => s_axi_wstrb,
      s_axi_wvalid       => s_axi_wvalid,
      s_axi_wready       => s_axi_wready,
      s_axi_bresp        => s_axi_bresp,
      s_axi_bvalid       => s_axi_bvalid,
      s_axi_bready       => s_axi_bready,
      s_axi_araddr       => s_axi_araddr,
      s_axi_arprot       => s_axi_arprot,
      s_axi_arvalid      => s_axi_arvalid,
      s_axi_arready      => s_axi_arready,
      s_axi_rdata        => s_axi_rdata,
      s_axi_rresp        => s_axi_rresp,
      s_axi_rvalid       => s_axi_rvalid,
      s_axi_rready       => s_axi_rready,
      user_busy_i        => user_busy_i,
      user_done_i        => user_done_i,
      user_err_i         => user_err_i,
      start_pulse_o      => start_pulse_o,
      soft_reset_pulse_o => soft_reset_pulse_o,
      irq_o              => irq_o
    );

end architecture rtl;
