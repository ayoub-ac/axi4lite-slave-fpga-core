# SPDX-License-Identifier: GPL-3.0-or-later OR Commercial
"""Generate random AXI4-Lite transaction vectors for the C++ harness.

Output: a C++ header (random_vectors.h) defining a static table of
{kind, addr, data, strb} tuples with a parallel "expected response /
expected read-back value" array. The harness in sim_main.cpp drives the
DUT with each vector and compares against the expected outcome.

Strategy:
  * 1024 vectors, mix of:
      - 60% writes (RW or W1C registers, in-range)
      - 30% reads (RW / RO / RC / W1C)
      - 5% out-of-range writes (must DECERR)
      - 5% out-of-range reads (must DECERR)
  * WSTRB is sampled from [0001, 0010, 0100, 1000, 0011, 1100, 0111,
    1110, 1111, 0000] for 32-bit data so partial-byte coverage hits
    every common pattern.
  * The script keeps a software shadow of the register file (with the
    same RW / RO / RC / W1C semantics as the RTL) so it can predict the
    expected value for every read.

Run: `python3 tb/gen_random_vectors.py > tb/random_vectors.h`
(invoked by `make regen_vectors`). Deterministic given the seed.
"""

import random
import sys

# Mirror the example top's REG_ATTR table.
# 0:RW 1:RO 2:W1C 3:RW 4:RW 5:RW 6:RO 7:RO 8:RC 9..15:RW
ATTR = ["RW", "RO", "W1C", "RW", "RW", "RW", "RO", "RO", "RC",
        "RW", "RW", "RW", "RW", "RW", "RW", "RW"]
ID_VAL      = 0xA1C4_017E  # reg 6
VERSION_VAL = 0x0001_0000  # reg 7

NUM_REGS   = 16
ADDR_WIDTH = 8
DATA_WIDTH = 32
BYTES      = DATA_WIDTH // 8

STRB_PATTERNS = [0b1111, 0b0001, 0b0010, 0b0100, 0b1000,
                 0b0011, 0b1100, 0b0111, 0b1110, 0b0000]


def apply_strb(old: int, new: int, strb: int) -> int:
    out = old
    for b in range(BYTES):
        if (strb >> b) & 1:
            mask = 0xFF << (b * 8)
            out = (out & ~mask) | (new & mask)
    return out & 0xFFFFFFFF


def main() -> int:
    random.seed(0xA1E50C42)
    out = sys.stdout

    # Software shadow of the register file. Reset matches RTL.
    shadow = [0] * NUM_REGS
    shadow[6] = ID_VAL
    shadow[7] = VERSION_VAL

    # Live RO payload model: STATUS at index 1 is driven externally —
    # we'll keep it 0 for the test (user_busy/done/err pinned low so
    # the harness can reproduce; if the harness wiggles them it must
    # update the expected_read value separately).
    def live_ro(idx: int) -> int:
        if idx == 1: return 0          # STATUS (0 with all signals 0)
        if idx == 6: return ID_VAL
        if idx == 7: return VERSION_VAL
        return 0

    KIND_WRITE      = 1
    KIND_READ       = 2
    KIND_WRITE_OOR  = 3   # out-of-range write
    KIND_READ_OOR   = 4   # out-of-range read

    n_total = 1024
    vectors = []  # (kind, addr, data, strb, exp_resp, exp_rdata)

    for i in range(n_total):
        roll = random.random()
        if roll < 0.05:
            kind = KIND_WRITE_OOR
        elif roll < 0.10:
            kind = KIND_READ_OOR
        elif roll < 0.40:
            kind = KIND_READ
        else:
            kind = KIND_WRITE

        if kind == KIND_WRITE:
            idx  = random.randrange(NUM_REGS)
            addr = idx * BYTES
            data = random.getrandbits(32)
            strb = random.choice(STRB_PATTERNS)
            attr = ATTR[idx]
            if attr == "RW":
                shadow[idx] = apply_strb(shadow[idx], data, strb)
            elif attr == "W1C":
                # Bits in data that are 1 clear corresponding stored bits,
                # gated by strb (per-byte).
                for b in range(BYTES):
                    if (strb >> b) & 1:
                        bm = 0xFF << (b * 8)
                        clear_bits = data & bm
                        shadow[idx] = shadow[idx] & ~clear_bits
            # RO/RC: write silently ignored on the storage side.
            vectors.append((kind, addr, data, strb, 0, 0))

        elif kind == KIND_READ:
            idx  = random.randrange(NUM_REGS)
            addr = idx * BYTES
            attr = ATTR[idx]
            if attr == "RO":
                exp = live_ro(idx)
            elif attr == "RC":
                exp = shadow[idx]
                shadow[idx] = 0  # read-clear
            else:
                exp = shadow[idx]
            vectors.append((kind, addr, 0, 0, 0, exp))

        elif kind == KIND_WRITE_OOR:
            # Address past NUM_REGS*BYTES, OR misaligned.
            if random.random() < 0.5:
                # Out-of-range
                addr = random.randint(NUM_REGS * BYTES,
                                      (1 << ADDR_WIDTH) - 1) & 0xFC
            else:
                # Mis-aligned (bytes 1..3)
                idx_b = random.randrange(NUM_REGS) * BYTES
                addr  = idx_b + random.randint(1, 3)
            data = random.getrandbits(32)
            strb = random.choice(STRB_PATTERNS)
            vectors.append((kind, addr, data, strb, 3, 0))  # DECERR=3

        else:  # KIND_READ_OOR
            if random.random() < 0.5:
                addr = random.randint(NUM_REGS * BYTES,
                                      (1 << ADDR_WIDTH) - 1) & 0xFC
            else:
                idx_b = random.randrange(NUM_REGS) * BYTES
                addr  = idx_b + random.randint(1, 3)
            vectors.append((kind, addr, 0, 0, 3, 0))  # DECERR=3, rdata don't-care

    out.write("// SPDX-License-Identifier: GPL-3.0-or-later OR Commercial\n")
    out.write("// AUTO-GENERATED by tb/gen_random_vectors.py.\n"
              "// Do not edit by hand; regenerate with `make regen_vectors`.\n")
    out.write("#pragma once\n")
    out.write("#include <cstdint>\n")
    out.write("#include <cstddef>\n\n")
    out.write("struct AxiVec {\n")
    out.write("    uint8_t  kind;       // 1=write, 2=read, 3=write_oor, 4=read_oor\n")
    out.write("    uint32_t addr;\n")
    out.write("    uint32_t data;       // wdata for writes\n")
    out.write("    uint8_t  strb;\n")
    out.write("    uint8_t  exp_resp;   // 0=OKAY, 2=SLVERR, 3=DECERR\n")
    out.write("    uint32_t exp_rdata;  // expected RDATA on reads\n")
    out.write("};\n\n")

    out.write(f"static const AxiVec kAxiVectors[] = {{\n")
    for k, a, d, s, er, ed in vectors:
        out.write(f"    {{ {k}u, 0x{a:02x}u, 0x{d:08x}u, 0x{s:01x}u, {er}u, 0x{ed:08x}u }},\n")
    out.write("};\n\n")
    out.write("static constexpr size_t kAxiVectorCount ="
              " sizeof(kAxiVectors) / sizeof(kAxiVectors[0]);\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
