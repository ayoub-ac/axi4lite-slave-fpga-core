# Port description

Detailed handshake protocol and timing for the AXI4-Lite slave
(`axi4lite_top`, `axi4lite_slave`, `axi4lite_regfile`). The behaviour
and cycle counts below describe design intent; they are not verified.

## Reset

`s_axi_aresetn` is **synchronous active-low**. Hold it low for at
least 4 clock cycles before the first transaction. After de-assertion
the slave is idle with `AWREADY = WREADY = ARREADY = 1` and BVALID /
RVALID low.

```
s_axi_aclk     __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
s_axi_aresetn  ‾‾‾‾‾‾‾|_______________________|‾‾‾‾‾‾‾‾‾‾‾‾‾‾
AWREADY               X X X X X X X X X X X X X 1 1 1 1 1 1
WREADY                X X X X X X X X X X X X X 1 1 1 1 1 1
ARREADY               X X X X X X X X X X X X X 1 1 1 1 1 1
```

## Write transaction

Per ARM IHI 0022 §A3.2.1, AW and W are independent. The master may
issue them in any order. The slave issues B once both have been
captured.

```
s_axi_aclk     |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
AWVALID        |‾‾|________________________
AWREADY        ‾‾‾|________________________
AWADDR         |a |________________________
WVALID         |‾‾|________________________
WREADY         ‾‾‾|________________________
WDATA          |d |________________________
WSTRB          |s |________________________
BVALID         _____|‾‾|___________________
BRESP          _____|r |___________________
BREADY         _____|‾‾|___________________
```

* Best-case B latency: 1 cycle after both AW and W have been accepted.
* AWADDR / AWPROT must remain stable while `AWVALID` is high and
  `AWREADY` low (SVA `p_aw_stable`).
* Same rule for WDATA / WSTRB / WVALID (`p_w_stable`).
* Once asserted, BVALID stays high until BREADY accepts. BRESP is
  stable across that wait (`p_b_stable`).

### Write strobe (WSTRB)

`WSTRB[i]` set means byte `i` of WDATA is committed to storage; bytes
with strobe low are unchanged. The shipped regfile applies WSTRB
combinationally on the same cycle it accepts the write, so partial-
byte writes have the same latency as full-word writes.

| WSTRB (32-bit data) | Bytes written |
|---------------------|---------------|
| `4'b1111`           | All 4         |
| `4'b0001`           | Byte 0 only   |
| `4'b0010`           | Byte 1 only   |
| `4'b0100`           | Byte 2 only   |
| `4'b1000`           | Byte 3 only   |
| `4'b0011`           | Bytes 0..1    |
| `4'b1100`           | Bytes 2..3    |
| `4'b0000`           | None (no-op)  |

A WSTRB of `0` is legal (per §A8.1.4) and produces a successful B
response with no storage update — useful for software that wants to
"observe" a register without modifying it.

## Read transaction

```
s_axi_aclk     |‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
ARVALID        |‾‾|________________________
ARREADY        ‾‾‾|________________________
ARADDR         |a |________________________
RVALID         _____|‾‾‾‾‾‾‾‾‾|____________
RDATA          _____|d        |____________
RRESP          _____|r        |____________
RREADY         _____|________|‾|___________
```

* RVALID asserts the cycle AFTER AR is accepted; RDATA / RRESP are
  registered.
* RVALID stays high until RREADY accepts. RDATA and RRESP remain
  stable (`p_r_stable`).
* The next ARVALID can be presented on the cycle after RREADY drops
  RVALID. There is no idle cycle requirement.

## Response codes

| BRESP / RRESP | Encoding | When emitted |
|---------------|----------|--------------|
| `OKAY`        | 2'b00    | normal completion |
| `EXOKAY`      | 2'b01    | not used by AXI4-Lite (exclusive accesses are AXI-only) |
| `SLVERR`      | 2'b10    | integrator-driven via `slv_err_i` (e.g., a precondition violation) |
| `DECERR`      | 2'b11    | address out-of-range OR mis-aligned |

The shipped `axi4lite_top` ties `slv_err_i` to `1'b0`, so SLVERR is
never emitted by the example; integrators that wrap their own
preconditions (e.g., "writing CTRL.START while user_busy is high is a
violation") should drive `slv_err_i` from their own logic.

## Per-register attribute (`REG_ATTR`)

`axi4lite_regfile` accepts a parameter that selects per-register
semantics:

| Encoding | Class | Read returns                  | Write semantics                          |
|----------|-------|-------------------------------|------------------------------------------|
| `2'b00`  | RW    | stored value                  | replaces masked bytes                    |
| `2'b01`  | RO    | live `rd_payload_i` slot      | ignored (BRESP = OKAY)                   |
| `2'b10`  | RC    | stored value, then clears storage | ignored                              |
| `2'b11`  | W1C   | stored value                  | bits in `WDATA` set to 1 clear stored bits, bits set to 0 are no-op |

`REG_ATTR` is a packed bit-vector with two bits per register, register
0 in the LSBs. The default (all-zero) makes every register RW, which
is what most users want. The example top in `rtl/axi4lite_top.sv`
shows a representative mix:

| Offset | Reg name   | Attr | Notes                                           |
|--------|------------|------|-------------------------------------------------|
| 0x00   | CTRL       | RW   | bit 0 = start pulse, bit 1 = soft-reset pulse   |
| 0x04   | STATUS     | RO   | bits 0..2 = busy / done / err (live)            |
| 0x08   | IRQ_STAT   | W1C  | software acks an IRQ by writing 1 to its bit    |
| 0x0C   | IRQ_MASK   | RW   | per-IRQ enable                                  |
| 0x10   | SCRATCH0   | RW   | general-purpose                                 |
| 0x14   | SCRATCH1   | RW   |                                                 |
| 0x18   | ID         | RO   | reset = 0xA1C4_017E                             |
| 0x1C   | VERSION    | RO   | reset = 0x0001_0000 (major.minor)               |
| 0x20   | EVENT_CNT  | RC   | read once -> latest count, then clears          |
| 0x24…  | …          | RW   | open for the integrator                         |

## Live-read payload (`rd_payload_i`)

For RO registers the slave returns the contents of `rd_payload_i` at
the matching slot rather than the regfile's storage. This lets the
integrator surface real status (FIFO levels, hardware counters,
interrupt vector) without making the regfile stateful for those
words. Unused slots (RW / RC / W1C registers) can be tied to '0;
the regfile will not consult them.

The `rd_payload_i` mux is combinational, so the master sees a
consistent snapshot for the cycle it AR-accepts.

## User-side hooks

| Signal               | Dir | Description                                                               |
|----------------------|-----|---------------------------------------------------------------------------|
| `slv_err_i`          | in  | Hint to the slave to answer SLVERR on the next BVALID / RVALID            |
| `reg_storage_o`      | out | Packed array of all register values; user logic can read what software wrote without re-issuing through the bus |
| `wr_event_o`         | out | One-cycle pulse on a successful write (in-range, non-DECERR) — handy to start a state machine when software pokes a control register |
| `wr_event_addr_o`    | out | Address of the registered write-event (valid alongside `wr_event_o`)      |
| `rd_event_o`         | out | One-cycle pulse on a successful read accept                              |
| `rd_event_addr_o`    | out | Address of the registered read-event (valid alongside `rd_event_o`)       |

## Latency summary

Intended latencies; not verified.

| Phase                                    | Cycles                |
|------------------------------------------|-----------------------|
| AW + W -> B                              | 1                     |
| AR -> R                                  | 1                     |
| Reset assert -> ready to accept          | 1 (after rst_ni high) |
| Back-to-back B / next AW                 | 0 (no idle cycle)     |
| Back-to-back R / next AR                 | 0                     |

The slave is purely combinational on the channel side (no skid except
the one-deep capture buffer per AW / W), so adding clock cycles to the
bus is rare. The shipped configuration trades two cycles of total
write latency for cleaner read-clear / write-1-clear handling.
