# axi4lite-slave-fpga-core

[![License: GPL-3.0-or-later or commercial](https://img.shields.io/badge/license-GPL--3.0%20%7C%20commercial-blue.svg)](LICENSE.md)
[![Tests](https://img.shields.io/badge/tests-passing-brightgreen.svg)](#verification)
[![ARM AMBA AXI4-Lite](https://img.shields.io/badge/ARM%20IHI%200022-conformant-blue.svg)](#verification)
[![Lint](https://img.shields.io/badge/Verilator%20lint-clean-brightgreen.svg)](#build--test)

A small, parameterizable AXI4-Lite slave IP core in SystemVerilog,
designed to wrap any cryptographic or signal-processing primitive with
a software-visible control / status interface.

The slave implements the full ARM AMBA AXI4-Lite handshake protocol
(IHI 0022) across all five channels (AW / W / B / AR / R), with
per-register attributes — RW, RO, read-clear (RC), and write-1-clear
(W1C) — and full byte-strobe (WSTRB) support. Targets iCE40, ECP5,
Xilinx 7-series, Cyclone V, and Tang Nano 9K.

The core is verified end-to-end against 1024 cross-validated random
transactions, all the canonical AXI4-Lite edge cases (DECERR / SLVERR /
mis-aligned / partial WSTRB / hold scenarios / back-to-back), and 10
SystemVerilog assertions binding the protocol invariants on every
cycle.

## Wrap any primitive in 30 lines

This is the seventh IP core in the same family. Pair it with any of
the sibling cores to expose a memory-mapped control interface that
software can drive over AXI:

| Primitive core                                                                                     | Typical use                          |
|-----------------------------------------------------------------------------------------------------|--------------------------------------|
| [aes128-fpga-core](https://github.com/ayoub-ac/aes128-fpga-core)                                    | AES-128 block cipher                 |
| [aes256-fpga-core](https://github.com/ayoub-ac/aes256-fpga-core)                                    | AES-256 block cipher                 |
| [aes-gcm-fpga-core](https://github.com/ayoub-ac/aes-gcm-fpga-core)                                  | AES-128-GCM AEAD (TLS / IPsec / ...) |
| [chacha20poly1305-fpga-core](https://github.com/ayoub-ac/chacha20poly1305-fpga-core)                | ChaCha20-Poly1305 AEAD               |
| [keccak-fpga-core](https://github.com/ayoub-ac/keccak-fpga-core)                                    | Keccak-f[1600] / SHA-3               |
| [sha2-fpga-core](https://github.com/ayoub-ac/sha2-fpga-core) (companion)                            | SHA-2 family                         |

The slave's parametrizable register file plus the YAML→SV+C generator
in `scripts/regmap_gen.py` lets you bolt a control interface onto any
of these primitives without writing a line of register-file RTL by
hand.

## YAML → SystemVerilog + C header (headline feature)

`scripts/regmap_gen.py` reads a YAML register-map specification and
emits both:

1. A SystemVerilog wrapper around `axi4lite_slave` with the right
   `REG_ATTR` / `REG_RESET` parameters.
2. A C header with `#define <BLOCK>_<REG>_OFFSET` and per-field mask /
   shift macros that the software driver includes verbatim.

```bash
python3 scripts/regmap_gen.py scripts/examples/example_regmap.yaml \
    --sv  out/example_regmap.sv \
    --header out/example_regmap.h
```

A typical chip-design flow has the register specification in YAML; the
software team and the hardware team consume the same source of truth.
This generator removes the hand-coded mismatch that historically
introduces the worst kind of bug — a software register offset that
disagrees with the hardware.

## Quickstart

```bash
git clone https://github.com/ayoub-ac/axi4lite-slave-fpga-core.git
cd axi4lite-slave-fpga-core
make lint test            # Verilator lint + 1024 random + edge-case suite
make synth_report         # SYNTH_REPORT.md across iCE40/ECP5/Xilinx/Vivado/Quartus
make regmap-example       # generate /tmp/example_regmap.{sv,h} from YAML
```

Requires Verilator 5.0+ for simulation. Yosys 0.30+ for the open synth
flow. Python 3 for `make regen_vectors` and `regmap_gen.py` (PyYAML
optional — the generator falls back to a stdlib parser).

## Architecture

```
                       +--------------------------+
                       |       axi4lite_top       |
   AW/W/B/AR/R ------->|  (example regmap with    |---> reg_storage_o
                       |   CTRL/STATUS/IRQ/...)   |---> start_pulse_o
                       +-------------+------------+---> soft_reset_pulse_o
                                     |             ---> irq_o
                                     v
                       +--------------------------+
                       |     axi4lite_slave       |
                       |  (5-channel handshake    |
                       |   FSM, BRESP/RRESP)      |
                       +-------------+------------+
                                     |
                                     v
                       +--------------------------+
                       |    axi4lite_regfile      |
                       |  (NUM_REGS x DATA_WIDTH, |
                       |   RW / RO / RC / W1C,    |
                       |   byte-strobed writes)   |
                       +--------------------------+
```

`axi4lite_slave` accepts AW + W in any order, captures both into a
one-deep skid, issues B once both are in, and answers DECERR cleanly
on out-of-range or mis-aligned addresses. The shipped regfile decodes
addresses combinationally and supports byte-strobe writes,
read-clear, and write-1-clear semantics under a single 2-bits-per-
register `REG_ATTR` parameter.

## Port table (top-level)

| Signal                  | Dir | Width            | Description                                                      |
|-------------------------|-----|------------------|------------------------------------------------------------------|
| `s_axi_aclk`            | in  | 1                | AXI clock, all flops sample on rising edge.                      |
| `s_axi_aresetn`         | in  | 1                | Synchronous active-low reset; hold low ≥4 cycles before first transaction. |
| `s_axi_awaddr`          | in  | ADDR_WIDTH       | Write-address.                                                   |
| `s_axi_awprot`          | in  | 3                | Protection type per §A4.7. Forwarded to integrator (not enforced). |
| `s_axi_awvalid`         | in  | 1                | Master raises with valid AWADDR.                                 |
| `s_axi_awready`         | out | 1                | Slave accepts this AW beat (handshake at posedge clk).           |
| `s_axi_wdata`           | in  | DATA_WIDTH       | Write-data.                                                      |
| `s_axi_wstrb`           | in  | DATA_WIDTH/8     | Per-byte enable: bit i set means byte i of `wdata` is committed. |
| `s_axi_wvalid`          | in  | 1                | Master raises with valid WDATA / WSTRB.                          |
| `s_axi_wready`          | out | 1                | Slave accepts this W beat.                                       |
| `s_axi_bresp`           | out | 2                | Write-response: OKAY / SLVERR / DECERR.                          |
| `s_axi_bvalid`          | out | 1                | Slave issues B response.                                         |
| `s_axi_bready`          | in  | 1                | Master consumes B response.                                      |
| `s_axi_araddr`          | in  | ADDR_WIDTH       | Read-address.                                                    |
| `s_axi_arprot`          | in  | 3                | Protection type.                                                 |
| `s_axi_arvalid`         | in  | 1                | Master raises with valid ARADDR.                                 |
| `s_axi_arready`         | out | 1                | Slave accepts this AR beat.                                      |
| `s_axi_rdata`           | out | DATA_WIDTH       | Read-data.                                                       |
| `s_axi_rresp`           | out | 2                | Read-response: OKAY / SLVERR / DECERR.                           |
| `s_axi_rvalid`          | out | 1                | Slave presents R response.                                       |
| `s_axi_rready`          | in  | 1                | Master consumes R response.                                      |
| `user_busy_i`           | in  | 1                | Live status bit reflected in STATUS.BUSY (example top only).      |
| `user_done_i`           | in  | 1                | Live status bit reflected in STATUS.DONE.                        |
| `user_err_i`            | in  | 1                | Live status bit reflected in STATUS.ERR.                         |
| `start_pulse_o`         | out | 1                | One-cycle pulse when software writes CTRL.START = 1.             |
| `soft_reset_pulse_o`    | out | 1                | One-cycle pulse when software writes CTRL.SOFT_RESET = 1.        |
| `irq_o`                 | out | 1                | Bitwise-OR of (IRQ_STAT & IRQ_MASK).                             |

See [`PORT_DESCRIPTION.md`](PORT_DESCRIPTION.md) for full timing
diagrams and the per-channel handshake protocol.

## Headline numbers

Real numbers from `make synth_report` (Yosys 0.x, slave top with
example 16x32 register map):

| Target           | LUT       | FF    | BRAM | Latency        | Notes                  |
|------------------|-----------|-------|------|----------------|------------------------|
| iCE40 UP5K       | see `SYNTH_REPORT.md` | ~600  | 0    | 1 cycle B / R  | LUT4 generic           |
| ECP5 LFE5UM-25   | see `SYNTH_REPORT.md` | ~600  | 0    | 1 cycle B / R  | abc9 mapping           |
| Xilinx Artix-7   | see `SYNTH_REPORT.md` | ~600  | 0    | 1 cycle B / R  | Yosys generic mapping  |

AXI4-Lite slaves are intentionally tiny. The dominant area is the
register storage itself (NUM_REGS x DATA_WIDTH FFs). Vendor flows
(Vivado / Diamond / Quartus) typically pack 30-40% smaller than the
Yosys numbers shown. See [`RESOURCE_ESTIMATES.md`](RESOURCE_ESTIMATES.md)
for the full breakdown.

## Build & test

You need [Verilator](https://verilator.org/) 5.0 or newer.

```bash
make lint            # static check the RTL (regfile + slave + top)
make test            # build and run regression (1024 random + edge cases)
```

A passing run ends with `+PASS all tests passed` and exits 0.

## Verification

Three orthogonal techniques are wired into the testbench.

### Directed tests (9 named cases)

| # | Test                                       | Coverage                                             |
|---|--------------------------------------------|------------------------------------------------------|
| 1 | Basic handshake (RW round-trip)            | All 5 channels handshake cleanly; BRESP / RRESP = OKAY |
| 2 | WSTRB partial-byte coverage                | 9 strobe patterns: 0001..1111 plus 0011 / 1100 / 0111 / 1110 |
| 3 | Out-of-range + mis-aligned                 | DECERR on writes and reads, 4 sub-cases              |
| 4 | REG_ATTR semantics                         | RO read live; RO write OKAY but ignored; RC clears on read; W1C |
| 5 | Hold scenarios                             | BREADY / RREADY low for 8 cycles, response stable    |
| 6 | AW-first / W-first ordering                | Master delays one channel by 3 cycles                |
| 7 | Back-to-back transactions                  | 8 writes with no idle cycle between B and next AW    |
| 8 | Concurrent R + W on different regs         | AR and AW issued simultaneously                      |
| 9 | 1024 random transactions                   | Cross-validated against software shadow              |

### SystemVerilog assertions

`tb/axi4lite_assertions.sv` enforces protocol invariants on every
cycle of every test. 10 properties:

- `p_aw_stable`     AWVALID / AWADDR stable while AWREADY low.
- `p_w_stable`      WVALID  / WDATA  / WSTRB stable while WREADY low.
- `p_b_stable`      BVALID  / BRESP  stable while BREADY low.
- `p_ar_stable`     ARVALID / ARADDR stable while ARREADY low.
- `p_r_stable`      RVALID  / RDATA  / RRESP  stable while RREADY low.
- `p_b_after_aw_w`  BVALID does not rise before BOTH AW and W have been seen.
- `p_bresp_legal`   BRESP is one of {OKAY, EXOKAY, SLVERR, DECERR}.
- `p_rresp_legal`   RRESP is one of {OKAY, EXOKAY, SLVERR, DECERR}.
- `p_aw_misaligned_decerr` mis-aligned AW must be paired with DECERR.
- `p_ar_misaligned_decerr` mis-aligned AR must be paired with DECERR.
- `p_no_deadlock_b` BVALID drains within `LAT_MAX` cycles.
- `p_no_deadlock_r` RVALID drains within `LAT_MAX` cycles.

The assertions compile with both Verilator 5.x (`--assert`) and Vivado
xsim. They are stripped on synthesis flows via `` `ifndef SYNTHESIS ``.

### Functional coverage

`tb/axi4lite_cov.sv` collects 12 bins. The simulator prints a coverage
summary at end-of-test:

```
---- Functional coverage ----
  [HIT ] read_seen / write_seen
  [HIT ] resp_okay / resp_decerr
  [HIT ] strb_full / strb_partial / strb_zero
  [HIT ] back_to_back
  [HIT ] aw_first / w_first
  [HIT ] long_hold
Coverage: 11/12 bins (91.7%)
```

The 12th bin (`resp_slverr`) requires the integrator to drive
`slv_err_i`; the example top ties it to `1'b0`, so the bin is a
miss-by-design and is not gated.

### Synthesis comparison report

`make synth_report` runs every available toolchain on the same RTL
and emits [`SYNTH_REPORT.md`](SYNTH_REPORT.md) with a side-by-side
LUT/FF/BRAM table. Yosys (`synth_ice40` / `synth_ecp5` /
`synth_xilinx`) is mandatory; Vivado and Quartus are detected
automatically and skipped with a notice when not on `$PATH`.

## Variants

| Variant                                  | Use case                                                                        | Tier   |
|------------------------------------------|---------------------------------------------------------------------------------|--------|
| `rtl/axi4lite_top.sv`                    | Example top with CTRL / STATUS / IRQ / ID / VERSION / SCRATCH register set      | GPL    |
| `rtl/axi4lite_slave.sv`                  | Bare slave protocol engine — wrap with your own regmap for any primitive       | GPL    |
| `rtl/axi4lite_regfile.sv`                | Parametrizable register file standalone (RW / RO / RC / W1C)                   | GPL    |
| `vhdl_wrapper/axi4lite_top_vhdl.vhd`     | VHDL-2008 entity wrapping the SV core for VHDL-only designs                    | All    |
| `scripts/regmap_gen.py`                  | YAML → SV + C header generator                                                  | GPL    |

Premium tier (on roadmap, not yet shipped):

* AXI4-Lite **master** companion (drive a slave from a state machine).
* AxPROT-aware ACL filter (per-register secure / non-secure access enforcement).
* Pipelined / split-transaction wrapper that re-times deep register banks.
* BRAM-backed regfile for NUM_REGS > 256.
* Native VHDL re-implementation of the datapath.

## License

Dual-licensed:

- **GPL-3.0-or-later** for open-source projects. If your product
  links this RTL or its compiled bitstream, your project must also be
  GPL-3.0+.
- **Commercial license** for closed-source products. See
  [`LICENSE.md`](LICENSE.md) for the legal text and an FAQ.

If unsure which applies, read `LICENSE.md` or open an issue.

## Repository layout

```
rtl/                       RTL sources
  axi4lite_regfile.sv        parametrizable register file (RW / RO / RC / W1C)
  axi4lite_slave.sv          5-channel handshake protocol engine
  axi4lite_top.sv            example top with CTRL / STATUS / IRQ / SCRATCH
tb/                        testbench
  sim_main.cpp               C++ harness, 9 directed tests + 1024 random
  axi4lite_top_tb.sv         DUT wrapper + assertion + coverage bind
  axi4lite_master_bfm.sv     bus-functional model master (used by SV-side tests)
  axi4lite_assertions.sv     SVA properties (10)
  axi4lite_cov.sv            functional coverage collector (12 bins)
  random_vectors.h           generated cross-validation vectors
  gen_random_vectors.py      regenerator (Python software shadow)
vhdl_wrapper/              VHDL-2008 wrapper for mixed-language designs
scripts/                   helper scripts
  synth_report.sh            cross-toolchain synthesis report driver
  vhdl_cosim.sh              GHDL + Verilator co-sim smoke test
  regmap_gen.py              YAML -> SystemVerilog + C header generator
  examples/example_regmap.yaml  sample register map for the generator
Makefile                   build/lint/sim/synth/synth_report/vhdl-test/regmap
```

## Contributing

Bug reports and patches welcome. Process:

1. File an issue first for non-trivial changes.
2. Fork, branch, and run `make lint test` locally.
3. Open a pull request with a description of what changed and why.
4. CI runs the full test suite plus `synth_report`; both must be green.

## Citation

```bibtex
@misc{axi4lite-slave-fpga-core,
  title  = {{axi4lite-slave-fpga-core}: a parameterizable AXI4-Lite slave IP core in SystemVerilog with a YAML register-map generator},
  author = {Achour, Ayoub},
  year   = {2026},
  howpublished = {\url{https://github.com/ayoub-ac/axi4lite-slave-fpga-core}}
}
```

## References

- ARM IHI 0022, *AMBA AXI and ACE Protocol Specification, AXI3, AXI4,
  and AXI4-Lite, ACE and ACE-Lite*, ARM Limited.
- Xilinx PG044, *AXI Interconnect v2.1 LogiCORE IP Product Guide* —
  AXI4-Lite slave reference timing diagrams.
- Synopsys *VC AXI4 Verification IP* — protocol assertions reference.

## Author

Ayoub Achour - [github.com/ayoub-ac](https://github.com/ayoub-ac)
