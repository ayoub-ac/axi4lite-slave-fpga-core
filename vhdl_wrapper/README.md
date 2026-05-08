# VHDL wrapper

`axi4lite_top_vhdl.vhd` is a thin VHDL-2008 entity that re-exposes the
SystemVerilog `axi4lite_top` module under a VHDL-friendly interface. Use
it from a VHDL design that does not want to touch SystemVerilog directly.

## Status

**Wrapper only.** The slave protocol engine and the parametrizable
register file both live in `rtl/*.sv` and are instantiated as a
SystemVerilog black-box. Mixed-language elaboration is supported by
every commercial simulator and synthesiser the core has been tested
against.

A pure VHDL re-implementation of the datapath is on the roadmap (Premium
tier, scope: parity with `rtl/axi4lite_top.sv` including the same
testbench checks). Until then, treat this directory as a binding layer,
not as a second implementation.

## Usage

### Vivado / Quartus / Diamond

Add both the SystemVerilog files and `axi4lite_top_vhdl.vhd` to the
same project library (`work` is fine). The toolchain resolves the SV
component automatically:

```tcl
# Vivado
read_verilog -sv {rtl/axi4lite_regfile.sv rtl/axi4lite_slave.sv \
                  rtl/axi4lite_top.sv}
read_vhdl -vhdl2008 vhdl_wrapper/axi4lite_top_vhdl.vhd
```

### ModelSim / Questa / Aldec

```
vlog -sv rtl/axi4lite_regfile.sv rtl/axi4lite_slave.sv rtl/axi4lite_top.sv
vcom -2008 vhdl_wrapper/axi4lite_top_vhdl.vhd
```

### GHDL + Verilator (open-source co-sim)

GHDL compiles the VHDL side, Verilator compiles the SV side, and the
two are linked through GHDL's VHPI bridge. The provided `make
vhdl-test` target wraps this; run it from the repository root:

```
make vhdl-test
```

The target is a no-op (with a notice) if `ghdl` is not on `$PATH`.

## Instantiation example

```vhdl
library ieee;
  use ieee.std_logic_1164.all;

entity my_design is end entity;
architecture rtl of my_design is
  signal clk, rstn                              : std_logic;
  signal awaddr, araddr                         : std_logic_vector(7 downto 0);
  signal awprot, arprot                         : std_logic_vector(2 downto 0);
  signal wdata, rdata                           : std_logic_vector(31 downto 0);
  signal wstrb                                  : std_logic_vector(3 downto 0);
  signal bresp, rresp                           : std_logic_vector(1 downto 0);
  signal awvalid, awready, wvalid, wready       : std_logic;
  signal bvalid, bready, arvalid, arready       : std_logic;
  signal rvalid, rready                         : std_logic;
  signal busy_in, done_in, err_in               : std_logic;
  signal start_p, srst_p, irq                   : std_logic;
begin
  u_axi : entity work.axi4lite_top_vhdl
    generic map (
      ADDR_WIDTH => 8,
      DATA_WIDTH => 32,
      NUM_REGS   => 16
    )
    port map (
      s_axi_aclk         => clk,
      s_axi_aresetn      => rstn,
      s_axi_awaddr       => awaddr,
      s_axi_awprot       => awprot,
      s_axi_awvalid      => awvalid,
      s_axi_awready      => awready,
      s_axi_wdata        => wdata,
      s_axi_wstrb        => wstrb,
      s_axi_wvalid       => wvalid,
      s_axi_wready       => wready,
      s_axi_bresp        => bresp,
      s_axi_bvalid       => bvalid,
      s_axi_bready       => bready,
      s_axi_araddr       => araddr,
      s_axi_arprot       => arprot,
      s_axi_arvalid      => arvalid,
      s_axi_arready      => arready,
      s_axi_rdata        => rdata,
      s_axi_rresp        => rresp,
      s_axi_rvalid       => rvalid,
      s_axi_rready       => rready,
      user_busy_i        => busy_in,
      user_done_i        => done_in,
      user_err_i         => err_in,
      start_pulse_o      => start_p,
      soft_reset_pulse_o => srst_p,
      irq_o              => irq
    );
end architecture;
```

## What this wrapper does NOT change

* Latency, throughput, area: identical to `axi4lite_top.sv`. There is
  no additional pipeline stage. Per transaction: 1 cycle B latency
  after AW + W; 1 cycle from AR-accept to R presented.
* Endianness: per AXI4-Lite §A8.1.1, byte 0 of the data lives at bits
  `[7:0]` (little-endian on the 32-bit data bus). WSTRB[0] gates byte 0.
* Reset polarity: still active-low synchronous (`s_axi_aresetn`).
