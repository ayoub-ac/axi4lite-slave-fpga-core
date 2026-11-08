# Resource estimates

> **Unverified estimates.** The figures in this file have not been confirmed by a recorded, reproducible synthesis run or by hardware measurement. Treat every LUT, FF, BRAM, DSP, Fmax, throughput, latency and power figure here as an unverified estimate. Run `make synth_report` with your own toolchain to get real numbers.

Numbers below are unverified estimates, not output from a recorded Yosys run (`make synth_report`).
They are pre-place-and-route. See `SYNTH_REPORT.md` for the most recent
run; this document explains what dominates the area and how to shrink
it.

## Summary (post-Yosys, pre-PnR)

| Target                         | Comment |
|--------------------------------|---------|
| Lattice iCE40 UP5K             | The handshake FSM and the address comparator are tiny; the dominant LUT cost is the byte-strobe write logic (one mux per byte) and the read mux across NUM_REGS. Fits trivially on the UP5K (5280 logic tiles). |
| Lattice ECP5 LFE5UM-25         | Same shape; `synth_ecp5 -abc9` packs the W1C bit-clear logic into LUT4 networks efficiently. |
| Xilinx Artix-7 XC7A35T         | Yosys-generic synthesis here counts LUT6 + CARRY4. Vivado synth_design will fold the regfile mux into LUTRAM if the integrator opts in (see `(* ram_style = "distributed" *)` below). |
| Cyclone V 5CSEMA5F31C6         | ALMs for the regfile + handshake; tiny. |
| Gowin GW1NR-9 (Tang Nano 9K)   | Not characterised here. Comparable to ECP5 with vendor flow. |

For exact LUT/FF/BRAM numbers run `make synth_report` and read
`SYNTH_REPORT.md`. There is no CI build in this repository.

## What dominates the area

For the example top (`NUM_REGS = 16`, `DATA_WIDTH = 32`, mixed RW / RO
/ RC / W1C):

* **Register file storage**: 16 x 32 = 512 FFs for the RW / W1C / RC
  registers. RO registers consume 32 FFs each at reset (so they hold
  the reset value across `rst_ni` deassert) but no per-cycle update
  logic.
* **Read mux**: a 16-to-1 32-bit-wide mux. Yosys generic synth maps
  this to ~32 LUT6 cells on Artix-7, ~96 LUT4 on iCE40.
* **Byte-strobe write logic**: per byte, a 2-input mux selecting old vs
  new. 4 bytes x 32 bits = 128 LUT-equivalent cells, fully fused into
  the regfile update path.
* **Address-decode comparator**: a single magnitude compare against
  `NUM_REGS` (4-bit width here) plus an alignment-bits OR. ~2 LUTs.
* **Handshake FSM**: ~50 FFs (AW capture, W capture, AW/W "captured"
  flags, BVALID, BRESP, AR capture, RVALID, RDATA, RRESP) and ~20
  LUTs of next-state logic.

Total: roughly 200-500 LUT and 600-700 FF on iCE40 / ECP5 / Artix-7
generic synth. With vendor-flow LUTRAM packing the LUT count drops to
~150-300.

## What you can do to shrink it

* **Use BRAM-mapped storage** for very-wide register banks (NUM_REGS
  > 256). The shipped regfile is intentionally flat-FF for fast,
  visible storage, which is the right choice up to ~64 registers.
  Beyond that, a BRAM-backed variant would likely be cheaper; no such
  variant is shipped.
* **Drop unused attribute paths**. If your application has only RW
  registers (the common case), the synthesizer prunes the W1C and RC
  branches automatically. The shipped regfile compiles down to a
  classic flat regfile in that case.
* **Reduce DATA_WIDTH**. A 16-bit slave takes half the storage and
  half the read-mux width. Most ARM Cortex-M / RISC-V SoC peripherals
  use 32-bit; embedded controllers sometimes use 16.

## What you can do to push throughput

The slave's intended max bandwidth is one transaction per cycle on
each channel (AW + W collapse into one transaction; not verified). At
100 MHz with 32-bit data that would be 400 MB/s on the write side and
400 MB/s on the read side (unverified estimate) — far more than typical control-bus traffic. There is no
performance gain from pipelining a 1-cycle-latency slave; AXI4-Lite is
designed for exactly this.

For a high-bandwidth data path, do NOT use AXI4-Lite. Use full AXI4
(burst) or AXI-Stream. The slave shipped here is a control-and-status
interface, not a DMA target.

## Frequency

Unverified estimates; no timing analysis has been recorded.

* iCE40 UP5K, default toolchain (Yosys + nextpnr), no constraints:
  ~80-100 MHz typical (limited by the regfile read mux depth).
* ECP5: ~150-200 MHz on generic synth.
* Artix-7 -1 speed grade: ~250+ MHz typical with Yosys; easily 300+
  MHz with Vivado.
* Cyclone V: similar to Artix-7 with vendor flow.

The handshake FSM has no critical path; the regfile read-mux is the
limiter, and it scales as `O(log NUM_REGS)`. For NUM_REGS <= 64 the
mux fits in 2 LUT levels and frequency is essentially unlimited by
the slave (unverified).

## Power

Unverified estimate: 2-4 mW dynamic on iCE40 UP5K at 50 MHz, depending on bus
activity. The regfile only toggles during a write; reads are
combinational. Static power is dominated by the FPGA itself.

## How to reproduce

```bash
make synth_report
```

This runs Yosys with `synth_ice40`, `synth_ecp5` (with `-abc9`), and
`synth_xilinx`, then `stat`, and writes the result to
`SYNTH_REPORT.md`. Vendor flows (Vivado, Quartus) are detected
automatically when on PATH.

For end-to-end place-and-route numbers (post-PnR LUT counts and
timing), run the vendor flow:
- iCE40 / ECP5: `nextpnr-ice40` / `nextpnr-ecp5` with Yosys output.
- Xilinx: Vivado with a project pointing at the `rtl/` files.
- Lattice Diamond / Radiant: project with `rtl/` added.
- Quartus: project with `rtl/` added.
