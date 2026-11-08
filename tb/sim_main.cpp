// SPDX-License-Identifier: GPL-3.0-or-later OR LicenseRef-Commercial
//
// Verilator C++ harness for axi4lite_top.
//
// Tests:
//   1. Protocol-handshake correctness across all five channels (AW/W/B/AR/R)
//   2. WSTRB partial-byte coverage (0001, 0010, 0100, 1000, 0011, 1100, 1111)
//   3. Concurrent read+write to different registers
//   4. Back-to-back transactions with no idle gap
//   5. Hold scenarios: BREADY / RREADY low for many cycles
//   6. Out-of-range and misaligned addresses (DECERR)
//   7. RW / RO / RC / W1C semantics (per the example top's REG_ATTR)
//   8. 1024 random transactions cross-validated against a software shadow
//
// Output: prints "+PASS" or "+FAIL <reason>" with a coverage report.

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

#include "verilated.h"
#include "Vaxi4lite_top_tb.h"
#include "Vaxi4lite_top_tb___024root.h"
#include "Vaxi4lite_top_tb_axi4lite_top_tb.h"
#include "Vaxi4lite_top_tb_axi4lite_cov__D20.h"
#include "random_vectors.h"

// ---------------------------------------------------------------------------
// Sim primitives
// ---------------------------------------------------------------------------
static int g_failures = 0;
static vluint64_t g_time = 0;

static void tick(Vaxi4lite_top_tb* dut) {
    dut->clk_i = 0; dut->eval(); g_time++;
    dut->clk_i = 1; dut->eval(); g_time++;
}
static void reset(Vaxi4lite_top_tb* dut) {
    dut->rst_ni = 0;
    dut->awaddr = 0; dut->awprot = 0; dut->awvalid = 0;
    dut->wdata = 0;  dut->wstrb  = 0; dut->wvalid  = 0;
    dut->bready  = 0;
    dut->araddr = 0; dut->arprot = 0; dut->arvalid = 0;
    dut->rready  = 0;
    dut->user_busy_i = 0;
    dut->user_done_i = 0;
    dut->user_err_i  = 0;
    dut->slv_err_in  = 0;
    for (int i = 0; i < 4; i++) tick(dut);
    dut->rst_ni = 1;
    tick(dut);
}

// ---------------------------------------------------------------------------
// Bus operations. All return 0=OKAY, 2=SLVERR, 3=DECERR.
// ---------------------------------------------------------------------------
static const int LATENCY_BUDGET = 200;

// Write transaction. aw_first / w_first control ordering; b_hold delays
// BREADY by N cycles after BVALID. The pattern below uses the standard
// "drive on cycle N, check VALID+READY both high to confirm handshake,
// drop VALID after the consume tick" Verilator pattern.
static int axi_write(Vaxi4lite_top_tb* dut,
                     uint32_t addr, uint32_t data, uint8_t strb,
                     int aw_first = 0, int w_first = 0, int b_hold = 0) {
    dut->awaddr = addr; dut->awprot = 0;
    dut->wdata  = data; dut->wstrb  = strb;
    dut->bready = 0;
    dut->awvalid = 0; dut->wvalid = 0;

    bool aw_done = false, w_done = false;
    int  cycles  = 0;

    if (aw_first > 0) {
        // Raise AW first; W stays low until aw_first cycles elapsed OR
        // AW handshakes.
        dut->awvalid = 1; dut->wvalid = 0;
        for (int k = 0; k < aw_first && !aw_done; k++) {
            dut->eval();
            if (dut->awvalid && dut->awready) aw_done = true;
            tick(dut);
            if (aw_done) dut->awvalid = 0;
        }
        dut->wvalid = 1;
    } else if (w_first > 0) {
        dut->awvalid = 0; dut->wvalid = 1;
        for (int k = 0; k < w_first && !w_done; k++) {
            dut->eval();
            if (dut->wvalid && dut->wready) w_done = true;
            tick(dut);
            if (w_done) dut->wvalid = 0;
        }
        dut->awvalid = 1;
    } else {
        dut->awvalid = 1; dut->wvalid = 1;
    }

    // Joint wait: drive both VALIDs (whichever is still up) until both
    // handshake complete.
    while (!(aw_done && w_done) && cycles < LATENCY_BUDGET) {
        dut->eval();
        bool aw_h = !aw_done && dut->awvalid && dut->awready;
        bool w_h  = !w_done  && dut->wvalid  && dut->wready;
        tick(dut);
        if (aw_h) { aw_done = true; dut->awvalid = 0; }
        if (w_h)  { w_done  = true; dut->wvalid  = 0; }
        cycles++;
    }
    if (!aw_done || !w_done) {
        std::fprintf(stderr, "[axi] write handshake timeout addr=0x%02x\n", addr);
        g_failures++;
        return -1;
    }

    // Wait for BVALID; optionally hold BREADY low for b_hold cycles.
    int waited = 0;
    dut->eval();
    while (!dut->bvalid) {
        tick(dut);
        dut->eval();
        if (++waited > LATENCY_BUDGET) {
            std::fprintf(stderr, "[axi] no BVALID after write addr=0x%02x\n", addr);
            g_failures++;
            return -1;
        }
    }
    for (int k = 0; k < b_hold; k++) tick(dut);
    dut->bready = 1;
    dut->eval();
    int resp = dut->bresp;
    tick(dut);
    dut->bready = 0;
    dut->awvalid = 0; dut->wvalid = 0;
    return resp;
}

static int axi_read(Vaxi4lite_top_tb* dut,
                    uint32_t addr, uint32_t* rdata,
                    int r_hold = 0) {
    dut->araddr = addr; dut->arprot = 0;
    dut->arvalid = 1;
    dut->rready  = 0;

    bool ar_done = false;
    int  cycles  = 0;
    while (!ar_done && cycles < LATENCY_BUDGET) {
        dut->eval();
        bool ar_h = dut->arvalid && dut->arready;
        tick(dut);
        if (ar_h) { ar_done = true; dut->arvalid = 0; }
        cycles++;
    }
    if (!ar_done) {
        std::fprintf(stderr, "[axi] AR handshake timeout addr=0x%02x\n", addr);
        g_failures++;
        return -1;
    }

    int waited = 0;
    dut->eval();
    while (!dut->rvalid) {
        tick(dut);
        dut->eval();
        if (++waited > LATENCY_BUDGET) {
            std::fprintf(stderr, "[axi] no RVALID after read addr=0x%02x\n", addr);
            g_failures++;
            return -1;
        }
    }
    for (int k = 0; k < r_hold; k++) tick(dut);
    if (rdata) *rdata = dut->rdata;
    int resp = dut->rresp;
    dut->rready = 1;
    dut->eval();
    tick(dut);
    dut->rready = 0;
    dut->arvalid = 0;
    return resp;
}

// ---------------------------------------------------------------------------
// Test 1: handshake correctness — single OKAY write + read on a RW reg.
// ---------------------------------------------------------------------------
static void test_handshake_okay(Vaxi4lite_top_tb* dut) {
    std::printf("---- Test 1: basic handshake (RW reg 0x10/SCRATCH0) ----\n");
    uint32_t rd = 0;
    int wr_resp = axi_write(dut, 0x10, 0xDEADBEEF, 0xF);
    int rd_resp = axi_read(dut,  0x10, &rd);
    bool ok = (wr_resp == 0) && (rd_resp == 0) && (rd == 0xDEADBEEF);
    if (ok) std::printf("  [PASS] handshake OKAY, RW round-trip 0xDEADBEEF\n");
    else { std::printf("  [FAIL] wr_resp=%d rd_resp=%d rd=0x%08x\n",
                       wr_resp, rd_resp, rd); g_failures++; }
}

// ---------------------------------------------------------------------------
// Test 2: WSTRB partial-byte coverage. Write 0xFFFFFFFF with each strb,
// expect read-back to show only the strobed bytes set.
// ---------------------------------------------------------------------------
static void test_wstrb(Vaxi4lite_top_tb* dut) {
    std::printf("---- Test 2: WSTRB partial-byte coverage ----\n");
    const uint8_t patterns[] = {0x1, 0x2, 0x4, 0x8,
                                0x3, 0xC, 0x7, 0xE, 0xF};
    int passes = 0;
    for (size_t i = 0; i < sizeof(patterns); i++) {
        // Reset reg by writing 0 with all bytes strobed.
        axi_write(dut, 0x10, 0x00000000, 0xF);
        int wr = axi_write(dut, 0x10, 0xFFFFFFFF, patterns[i]);
        uint32_t rd = 0;
        int rdr = axi_read(dut, 0x10, &rd);
        uint32_t expected = 0;
        for (int b = 0; b < 4; b++) if (patterns[i] & (1 << b))
            expected |= 0xFFu << (b * 8);
        bool ok = (wr == 0) && (rdr == 0) && (rd == expected);
        if (ok) { passes++;
                  std::printf("  [PASS] strb=0x%x rd=0x%08x\n", patterns[i], rd); }
        else    { std::printf("  [FAIL] strb=0x%x rd=0x%08x exp=0x%08x\n",
                              patterns[i], rd, expected); g_failures++; }
    }
    std::printf("  WSTRB: %d/%zu pass\n", passes, sizeof(patterns));
}

// ---------------------------------------------------------------------------
// Test 3: out-of-range and misaligned -> DECERR.
// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Test 3b: integrator-driven SLVERR. Hold slv_err_i high during a
// transaction, expect BRESP/RRESP = 2'b10 (SLVERR).
// ---------------------------------------------------------------------------
static void test_slverr(Vaxi4lite_top_tb* dut) {
    std::printf("---- Test 3b: integrator-hint SLVERR ----\n");
    dut->slv_err_in = 1;
    int wresp = axi_write(dut, 0x10, 0xCAFEBABE, 0xF);
    uint32_t rd = 0;
    int rresp = axi_read(dut, 0x10, &rd);
    dut->slv_err_in = 0;
    int ok_n = 0;
    if (wresp == 2) { std::printf("  [PASS] write -> SLVERR\n"); ok_n++; }
    else            { std::printf("  [FAIL] write resp=%d\n", wresp); g_failures++; }
    if (rresp == 2) { std::printf("  [PASS] read  -> SLVERR\n"); ok_n++; }
    else            { std::printf("  [FAIL] read  resp=%d\n", rresp); g_failures++; }
    std::printf("  SLVERR: %d/2 pass\n", ok_n);
}

static void test_decerr(Vaxi4lite_top_tb* dut) {
    std::printf("---- Test 3: out-of-range + misaligned (DECERR) ----\n");
    uint32_t rd = 0;
    // Address 0x40 = 64 bytes, NUM_REGS*4 = 64, so first OOR.
    int oor_w = axi_write(dut, 0x40, 0x12345678, 0xF);
    int oor_r = axi_read (dut, 0x40, &rd);
    int mis_w = axi_write(dut, 0x05, 0x12345678, 0xF);  // 0x05 = misaligned
    int mis_r = axi_read (dut, 0x05, &rd);
    int ok_n  = 0;
    if (oor_w == 3) { std::printf("  [PASS] OOR write -> DECERR\n");        ok_n++; }
    else            { std::printf("  [FAIL] OOR write resp=%d\n", oor_w);   g_failures++; }
    if (oor_r == 3) { std::printf("  [PASS] OOR read  -> DECERR\n");        ok_n++; }
    else            { std::printf("  [FAIL] OOR read  resp=%d\n", oor_r);   g_failures++; }
    if (mis_w == 3) { std::printf("  [PASS] mis-aligned write -> DECERR\n"); ok_n++; }
    else            { std::printf("  [FAIL] mis-aligned write resp=%d\n", mis_w); g_failures++; }
    if (mis_r == 3) { std::printf("  [PASS] mis-aligned read  -> DECERR\n"); ok_n++; }
    else            { std::printf("  [FAIL] mis-aligned read  resp=%d\n", mis_r); g_failures++; }
    std::printf("  DECERR: %d/4 pass\n", ok_n);
}

// ---------------------------------------------------------------------------
// Test 4: register-attribute semantics (RW / RO / RC / W1C).
// ---------------------------------------------------------------------------
static void test_attrs(Vaxi4lite_top_tb* dut) {
    std::printf("---- Test 4: REG_ATTR semantics (RO/RC/W1C) ----\n");
    uint32_t rd = 0;

    // ID (reg 6, RO) — read returns ID_VAL, write is OKAY but no-op.
    int rdr = axi_read(dut, 0x18, &rd);
    if (rdr == 0 && rd == 0xA1C4017E)
        std::printf("  [PASS] RO read = 0x%08x\n", rd);
    else { std::printf("  [FAIL] RO read got 0x%08x rdr=%d\n", rd, rdr); g_failures++; }
    int wr = axi_write(dut, 0x18, 0xCAFEBABE, 0xF);
    rdr   = axi_read(dut, 0x18, &rd);
    if (wr == 0 && rd == 0xA1C4017E)
        std::printf("  [PASS] RO write OKAY but ignored\n");
    else { std::printf("  [FAIL] RO write resp=%d rd_after=0x%08x\n", wr, rd); g_failures++; }

    // VERSION (reg 7, RO).
    rdr = axi_read(dut, 0x1C, &rd);
    if (rdr == 0 && rd == 0x00010000)
        std::printf("  [PASS] VERSION RO = 0x%08x\n", rd);
    else { std::printf("  [FAIL] VERSION rd=0x%08x\n", rd); g_failures++; }

    // EVENT_CNT (reg 8, RC). Write a value (silently ignored — RC), then
    // read once to exercise the read path. Subsequent reads return 0
    // because the storage cleared on the first read.
    // Because writes are ignored on RC, we have no easy way to seed it
    // from the bus. Instead we verify the second read returns 0.
    axi_read(dut, 0x20, &rd);   // first read (whatever it was)
    rdr = axi_read(dut, 0x20, &rd);
    if (rdr == 0 && rd == 0x00000000)
        std::printf("  [PASS] RC read returns 0 after a previous read\n");
    else { std::printf("  [FAIL] RC second read 0x%08x rdr=%d\n", rd, rdr); g_failures++; }

    // IRQ_STAT (reg 2, W1C). Test W1C through a write-then-read-back of
    // the IRQ_MASK (RW) is irrelevant; for W1C, writes of '1' clear bits
    // and writes of '0' don't set. Software shadow stays at 0 in this
    // test (no hardware-driven set path is wired in the example top).
    wr  = axi_write(dut, 0x08, 0xFFFFFFFF, 0xF);
    rdr = axi_read(dut, 0x08, &rd);
    if (wr == 0 && rdr == 0 && rd == 0)
        std::printf("  [PASS] W1C reg cleared by writing 1s (was 0, stays 0)\n");
    else { std::printf("  [FAIL] W1C path wr=%d rd=0x%08x\n", wr, rd); g_failures++; }
}

// ---------------------------------------------------------------------------
// Test 5: hold scenarios — BREADY/RREADY held low for many cycles. The
// SVA p_b_stable / p_r_stable cover the data-stable check; here we
// just time the hold and confirm the response is intact afterwards.
// ---------------------------------------------------------------------------
static void test_hold(Vaxi4lite_top_tb* dut) {
    std::printf("---- Test 5: hold scenarios (BREADY/RREADY low for cycles) ----\n");
    int wr = axi_write(dut, 0x10, 0xA5A5A5A5, 0xF, 0, 0, 8);
    uint32_t rd = 0;
    int rr = axi_read(dut, 0x10, &rd, 8);
    if (wr == 0 && rr == 0 && rd == 0xA5A5A5A5)
        std::printf("  [PASS] hold: response stable across 8-cycle hold\n");
    else { std::printf("  [FAIL] hold wr=%d rr=%d rd=0x%08x\n", wr, rr, rd); g_failures++; }
}

// ---------------------------------------------------------------------------
// Test 6: AW-first then W (and W-first then AW) — exercises out-of-order
// channel handshake at the protocol level.
// ---------------------------------------------------------------------------
static void test_order(Vaxi4lite_top_tb* dut) {
    std::printf("---- Test 6: AW-first / W-first ordering ----\n");
    int a = axi_write(dut, 0x14, 0x11223344, 0xF, /*aw_first*/ 3, 0);
    uint32_t rd = 0;
    int ar = axi_read(dut, 0x14, &rd);
    if (a == 0 && ar == 0 && rd == 0x11223344)
        std::printf("  [PASS] AW-first ordering -> rd 0x%08x\n", rd);
    else { std::printf("  [FAIL] AW-first wr=%d rd=0x%08x\n", a, rd); g_failures++; }

    int b = axi_write(dut, 0x14, 0x55667788, 0xF, /*aw*/ 0, /*w_first*/ 3);
    int br = axi_read(dut, 0x14, &rd);
    if (b == 0 && br == 0 && rd == 0x55667788)
        std::printf("  [PASS] W-first ordering -> rd 0x%08x\n", rd);
    else { std::printf("  [FAIL] W-first wr=%d rd=0x%08x\n", b, rd); g_failures++; }
}

// ---------------------------------------------------------------------------
// Test 7: back-to-back transactions (no idle cycle between B and the
// next AW). Slave must accept the next AW the cycle after we drop BREADY.
// ---------------------------------------------------------------------------
static void test_back_to_back(Vaxi4lite_top_tb* dut) {
    std::printf("---- Test 7: back-to-back writes (no idle gap) ----\n");
    int passes = 0;
    for (int i = 0; i < 8; i++) {
        uint32_t v = 0x10000 + i;
        int r = axi_write(dut, 0x10, v, 0xF);
        if (r == 0) passes++;
    }
    uint32_t rd = 0;
    axi_read(dut, 0x10, &rd);
    if (passes == 8 && rd == 0x10007)
        std::printf("  [PASS] 8 back-to-back writes, final rd=0x%08x\n", rd);
    else { std::printf("  [FAIL] back-to-back passes=%d rd=0x%08x\n", passes, rd); g_failures++; }
}

// ---------------------------------------------------------------------------
// Test 8: 1024 random vectors cross-validated against the software shadow
// generated by tb/gen_random_vectors.py.
// ---------------------------------------------------------------------------
static void test_random(Vaxi4lite_top_tb* dut) {
    std::printf("---- Test 8: %zu random transactions ----\n", kAxiVectorCount);
    // Align DUT state with the Python shadow: zero every RW / W1C / RC
    // register so the random replay starts from the same baseline.
    // (Indices 0, 3, 4, 5, 9..15 are RW; index 2 is W1C; index 8 is RC.)
    const int rw_idxs[] = {0, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13, 14, 15};
    for (int idx : rw_idxs) {
        // For RW write 0; for W1C write all-1s to clear; for RC just touch.
        axi_write(dut, idx * 4, 0xFFFFFFFF, 0xF);
    }
    for (int idx : rw_idxs) {
        axi_write(dut, idx * 4, 0x00000000, 0xF);
    }
    // RC clear via a read.
    uint32_t junk = 0;
    axi_read(dut, 0x20, &junk);
    int passes = 0, fails = 0;
    for (size_t i = 0; i < kAxiVectorCount; i++) {
        const AxiVec& v = kAxiVectors[i];
        if (v.kind == 1) {                                      // write
            int r = axi_write(dut, v.addr, v.data, v.strb);
            if (r == (int)v.exp_resp) passes++;
            else { if (fails < 3)
                     std::printf("  [FAIL] vec#%zu W addr=0x%02x got_resp=%d exp=%d\n",
                                 i, v.addr, r, v.exp_resp);
                   fails++; }
        } else if (v.kind == 2) {                               // read
            uint32_t rd = 0;
            int r = axi_read(dut, v.addr, &rd);
            bool resp_ok  = (r == (int)v.exp_resp);
            bool data_ok  = (rd == v.exp_rdata);
            if (resp_ok && data_ok) passes++;
            else { if (fails < 3)
                     std::printf("  [FAIL] vec#%zu R addr=0x%02x got rd=0x%08x exp=0x%08x resp=%d exp_resp=%d\n",
                                 i, v.addr, rd, v.exp_rdata, r, v.exp_resp);
                   fails++; }
        } else if (v.kind == 3) {                               // write OOR
            int r = axi_write(dut, v.addr, v.data, v.strb);
            if (r == (int)v.exp_resp) passes++;
            else { if (fails < 3)
                     std::printf("  [FAIL] vec#%zu Wo addr=0x%02x got_resp=%d exp=%d\n",
                                 i, v.addr, r, v.exp_resp);
                   fails++; }
        } else if (v.kind == 4) {                               // read OOR
            uint32_t rd = 0;
            int r = axi_read(dut, v.addr, &rd);
            if (r == (int)v.exp_resp) passes++;
            else { if (fails < 3)
                     std::printf("  [FAIL] vec#%zu Ro addr=0x%02x got_resp=%d exp=%d\n",
                                 i, v.addr, r, v.exp_resp);
                   fails++; }
        }
    }
    std::printf("  random: %d / %zu pass\n", passes, kAxiVectorCount);
    if (fails > 0) g_failures += fails;
}

// ---------------------------------------------------------------------------
// Test 9: concurrent read+write on different registers. A read and a
// write are issued simultaneously to two different addresses; both must
// complete cleanly. (AXI4-Lite read and write channels are independent.)
// ---------------------------------------------------------------------------
static void test_concurrent_rw(Vaxi4lite_top_tb* dut) {
    std::printf("---- Test 9: concurrent R+W on different regs ----\n");
    // Seed reg 0x14 with a known value first.
    axi_write(dut, 0x14, 0xCAFEF00D, 0xF);
    // Start AR for 0x14 and AW+W for 0x10 in the same cycle.
    dut->araddr = 0x14; dut->arprot = 0; dut->arvalid = 1; dut->rready = 0;
    dut->awaddr = 0x10; dut->wdata = 0xBEEFCAFE; dut->wstrb = 0xF;
    dut->awprot = 0;    dut->awvalid = 1; dut->wvalid = 1; dut->bready = 0;

    bool aw_done = false, w_done = false, ar_done = false;
    bool b_done  = false, r_done = false;
    int  resp_w = -1, resp_r = -1;
    uint32_t rd = 0;
    for (int k = 0; k < 200 && !(b_done && r_done); k++) {
        dut->eval();
        bool aw_h = !aw_done && dut->awvalid && dut->awready;
        bool w_h  = !w_done  && dut->wvalid  && dut->wready;
        bool ar_h = !ar_done && dut->arvalid && dut->arready;
        bool b_h  = !b_done  && dut->bvalid  && dut->bready;
        bool r_h  = !r_done  && dut->rvalid  && dut->rready;
        if (b_h) { resp_w = dut->bresp; }
        if (r_h) { rd = dut->rdata; resp_r = dut->rresp; }
        tick(dut);
        if (aw_h) { aw_done = true; dut->awvalid = 0; }
        if (w_h)  { w_done  = true; dut->wvalid  = 0; }
        if (ar_h) { ar_done = true; dut->arvalid = 0; }
        if (b_h)  { b_done  = true; dut->bready  = 0; }
        if (r_h)  { r_done  = true; dut->rready  = 0; }
        if (!b_done && dut->bvalid) dut->bready = 1;
        if (!r_done && dut->rvalid) dut->rready = 1;
    }
    dut->awvalid = 0; dut->wvalid = 0;
    dut->arvalid = 0; dut->bready = 0; dut->rready = 0;

    bool ok = (resp_w == 0) && (resp_r == 0) && (rd == 0xCAFEF00D);
    if (ok) std::printf("  [PASS] concurrent R+W rd=0x%08x\n", rd);
    else    { std::printf("  [FAIL] concurrent rw resp_w=%d resp_r=%d rd=0x%08x\n",
                          resp_w, resp_r, rd); g_failures++; }
}

// ---------------------------------------------------------------------------
// Coverage report
// ---------------------------------------------------------------------------
static void report_coverage(const Vaxi4lite_top_tb* dut) {
    auto* cov = dut->rootp->axi4lite_top_tb->u_cov;
    struct Bin { const char* name; uint8_t hit; };
    Bin bins[] = {
        {"read_seen",     cov->c_read_seen},
        {"write_seen",    cov->c_write_seen},
        {"resp_okay",     cov->c_resp_okay},
        {"resp_slverr",   cov->c_resp_slverr},
        {"resp_decerr",   cov->c_resp_decerr},
        {"strb_full",     cov->c_strb_full},
        {"strb_partial",  cov->c_strb_partial},
        {"strb_zero",     cov->c_strb_zero},
        {"back_to_back",  cov->c_back_to_back},
        {"aw_first",      cov->c_aw_first},
        {"w_first",       cov->c_w_first},
        {"long_hold",     cov->c_long_hold},
    };
    int total = sizeof(bins) / sizeof(bins[0]);
    int hit = 0;
    std::printf("\n---- Functional coverage ----\n");
    for (int i = 0; i < total; i++) {
        std::printf("  [%s] %-15s\n", bins[i].hit ? "HIT " : "MISS",
                    bins[i].name);
        if (bins[i].hit) hit++;
    }
    std::printf("Coverage: %d/%d bins (%.1f%%)\n",
                hit, total, 100.0 * hit / total);
    if (hit < total) g_failures++;
}

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    setvbuf(stdout, nullptr, _IOLBF, 0);
    Vaxi4lite_top_tb* dut = new Vaxi4lite_top_tb();
    reset(dut);

    test_handshake_okay(dut);
    test_wstrb(dut);
    test_slverr(dut);
    test_decerr(dut);
    test_attrs(dut);
    test_hold(dut);
    test_order(dut);
    test_back_to_back(dut);
    test_concurrent_rw(dut);
    test_random(dut);

    report_coverage(dut);

    if (g_failures == 0) {
        std::printf("+PASS all tests passed\n");
        delete dut;
        return 0;
    } else {
        std::printf("+FAIL %d failures\n", g_failures);
        delete dut;
        return 1;
    }
}
