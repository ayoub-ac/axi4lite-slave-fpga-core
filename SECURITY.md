# Security model

This document describes what the AXI4-Lite slave core is designed to
defend against, what it is NOT designed to defend against, and how to
evaluate the claims. None of the properties below have been
independently verified; treat them as design intent.

The slave is a control-and-status interface, not a cryptographic
primitive. The threat model is therefore very different from the AES /
SHA / GHASH sibling cores. Read this whole document before deploying
the slave in a security-sensitive system.

## What is intended to be protected (not verified)

### 1. Address-decode discipline

Every transaction whose address falls past `NUM_REGS * (DATA_WIDTH/8)`
or is mis-aligned with the data-bus width is intended to be answered
with `BRESP = DECERR` (writes) or `RRESP = DECERR` (reads), so that
software cannot probe beyond the published register map and get an
OKAY response. Not verified.

The decode predicate is checked by SVA assertions
(`a_aw_misaligned_decerr`, `a_ar_misaligned_decerr`) in the included
testbench; results not independently confirmed.

### 2. Per-register access policy

The register file is intended to enforce RW / RO / RC / W1C semantics
at the hardware level (not verified):

* RO registers ignore writes (BRESP = OKAY, but the storage is
  unchanged). Software cannot use a write to corrupt a status / ID
  register.
* RC registers clear on read. Software cannot keep an interrupt-status
  register set indefinitely once it has been observed.
* W1C registers clear bits on write-of-1; bits written as 0 are not
  modified. This is the canonical way to "acknowledge" an interrupt
  source without racing against a new event.

The semantics are exposed through the `REG_ATTR` parameter at
elaboration time and cannot be overridden by software.

### 3. Constant-time on the bus

Every transaction is intended to take the same number of cycles
regardless of which register is accessed (not verified). There is no early-exit, no data-dependent
latency, no per-register pipeline. Software cannot use timing to infer
the contents of a register it could not otherwise read.

(This is mostly a consequence of the slave being trivial; we point it
out because users coming from a software-bus IP may be used to
lazy-decoded slaves that take longer for invalid addresses.)

### 4. Reset hygiene

`s_axi_aresetn` is a synchronous active-low reset intended to clear
every register to its `REG_RESET` value. Held xVALIDs across the reset
boundary are intended to be masked, so the slave does not start a
transaction until the reset has de-asserted for at least one cycle.
Not verified.

## What is NOT covered (be honest)

This list is intended to help integrators evaluate fit; it may not be complete:

* **Side-channel attacks via bus timing.** Although per-register access
  is constant-time, a sophisticated attacker who can observe BRESP /
  RRESP latency at fine granularity could in principle distinguish
  OKAY from DECERR responses. Both responses take the same wall-clock
  number of cycles in the shipped slave, but the slave does not employ
  timing-balanced gates; in a power-leakage adversary model this
  distinction may still be observable. Not a typical threat against a
  control bus, but documented for completeness.
* **Differential power analysis on the register file.** The shipped
  storage is a flat array of flip-flops; a power attacker measuring
  leakage at the FF-update boundary can mount standard DPA against
  values written to RW registers. Mitigation requires masked storage
  and is not in scope.
* **Fault injection on the FSM** (xVALID glitch, BVALID skip, RVALID
  forge): a flipped flop can corrupt the response or skip a write.
  No duplicated-FSM / parity-protected variant is shipped.
* **Privilege-aware decoding.** AXI4-Lite carries an `AxPROT[2:0]`
  signal (instruction/data, secure/non-secure, privileged/user) per
  the AXI4 spec. The slave forwards `AWPROT` / `ARPROT` to integration
  but does NOT enforce per-register ACL based on those bits. Adding
  ACLs (e.g., "only allow secure-mode masters to write the IRQ_MASK
  register") is integrator-side; no per-register PROT-mask filter is
  shipped.
* **Unauthorised access via clock-domain crossings.** All slave logic
  runs on `s_axi_aclk`; CDC handshakes between the AXI clock and a
  slower / faster user-side clock are out of scope. Wire user-side
  signals through your own CDC primitives.
* **Replay / aliasing attacks on the bus.** The slave does not
  authenticate the master. Any master that can reach the AXI ports
  can drive any read / write. Authenticated bus access is a system-
  level property.

## Compliance claims

* **ARM AMBA AXI4-Lite (IHI 0022)** conformance: the slave is intended
  to implement the protocol as specified; compliance is not verified.
  Intended behaviour includes:
  - Independent VALID/READY handshakes per channel (§A3.2.1).
  - VALID held high until the corresponding READY accepts (§A3.2.1).
  - Address-stable / data-stable while VALID (§A3.2.1).
  - 4-way response code on B and R (`{OKAY, EXOKAY, SLVERR, DECERR}`,
    §A3.4.4); EXOKAY is not used by AXI4-Lite slaves.
  - Aligned-address requirement (§A8.1.1).
  The included Verilator testbench has 12 SVA properties on these
  invariants and a 1024-vector random test checked against a software
  shadow of the register file. Tests are included; results not
  independently confirmed.
* **AMBA Arm Verification IP (Arm VIP)**: not run. Achieving an
  Arm-signed VIP-pass is a separate engagement that requires an Arm
  Authorized Design Partner.
* **Common Criteria, FIPS 140-3**: not evaluated. The slave is not a
  cryptographic boundary by itself; certifications attach to the
  primitive cores wrapped by the slave (AES-128, AES-128-GCM,
  ChaCha20-Poly1305, SHA-2, Keccak, etc.).

## Test methodology intended to check the security claims

Tests are included; results not independently confirmed. The Verilator
testbench is intended to run:

1. **Functional correctness on the published register map**: `make test`.
   Tests RW / RO / RC / W1C semantics, WSTRB partial-byte writes,
   out-of-range and misaligned access (DECERR), back-to-back transactions,
   and 1024 random transactions cross-checked against a Python software
   shadow of the regfile.
2. **SVA-checked protocol invariants on every cycle**: see
   `tb/axi4lite_assertions.sv`. Properties include:
   - AWVALID / AWADDR stable while AWREADY low.
   - WVALID / WDATA / WSTRB stable while WREADY low.
   - BVALID / BRESP stable while BREADY low.
   - ARVALID / ARADDR stable while ARREADY low.
   - RVALID / RDATA / RRESP stable while RREADY low.
   - BVALID does not assert before both AW and W have been seen.
   - BRESP / RRESP carry only legal codes when valid.
   - Mis-aligned AW / AR -> DECERR pairing.
   - Bounded-latency BREADY / RREADY drainage.
3. **Functional coverage**: 12 bins (read seen, write seen, OKAY,
   SLVERR, DECERR, four WSTRB classes, AW-first, W-first, back-to-back,
   long-hold). Coverage report intended to print at end of `make test`.

We do NOT run experimental fault injection or side-channel campaigns.
The constant-time-on-the-bus claim is design intent, derived from the
structure of the slave.

## How to use the core safely

1. **Lock down the AxPROT bits at the integration layer** if your
   system has both secure and non-secure masters reaching the slave.
   The shipped slave does not gate on AxPROT.
2. **Use RO for ID / version / status registers**, never RW. A
   compromised master that can write an RW ID register can confuse
   downstream software.
3. **Use W1C for interrupt-status registers**, never RW. RW
   interrupt-status registers race against the hardware-set path and
   can drop or duplicate IRQs.
4. **Use RC sparingly**. RC is convenient for "consumed once" status
   registers, but RC reads are destructive — a debug probe that
   re-reads the register sees zero, which can confuse the debugger.
5. **Hold `s_axi_aresetn` low for at least 4 cycles** after power-on
   and before the first transaction; this gives the FSM time to settle
   and avoids spurious xVALIDs being mistaken for transactions.
6. **Don't use AXI4-Lite for high-bandwidth data movement**. The slave
   answers one transaction at a time; for streaming or DMA, wrap it
   with a separate AXI4 burst master / slave (not in scope here).

## Reporting issues

Found a bug, a side channel we missed, or a discrepancy with ARM
IHI 0022? Open a GitHub issue (do not include confidential details).
No support or maintenance is provided. We do not offer a bug bounty.
