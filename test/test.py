# SPDX-License-Identifier: Apache-2.0
"""BAR 4 — the gate-level netlist diffed against the golden model.

This replaces the template's stock adder assertions, which tested a design we do not ship and left
the netlist unverified through runs 001 and 002.

Protocol under test (see the wrapper header): 2-cycle frame, phase counted from reset.
    phase 0  x_in = {uio_in, ui_in} latched, in_valid pulsed;  uo_out = result[7:0]
    phase 1                                                    uo_out = result[15:8]
"""
import os
import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from golden import reciprocal, SAT_POS

SETTLE = 40           # cycles to hold an operand so the pipe fills with it. Any value >= ~2*17
                      # works; the READ PHASE depends on its parity, which is why the test
                      # CALIBRATES rather than assumes. See GOLDEN_VALIDATION.md — three different
                      # "latency" numbers have already convicted a correct model in this project.
DOMAIN = [v for a in range(32, 4096) for v in (a, -a)]   # certified |b| in [0.125, 16) at Q8.8


async def reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def drive(dut, b):
    v = b & 0xFFFF
    dut.ui_in.value = v & 0xFF
    dut.uio_in.value = (v >> 8) & 0xFF


async def read_frame(dut, hi_first):
    """Two consecutive cycles of uo_out, assembled per the calibrated byte order."""
    a = int(dut.uo_out.value)
    await RisingEdge(dut.clk)
    b = int(dut.uo_out.value)
    r = (a << 8) | b if hi_first else (b << 8) | a
    return r - (1 << 16) if r & 0x8000 else r


async def calibrate_phase(dut):
    """STEP ZERO for this test: establish the read byte order from a KNOWN operand.

    CRITICAL: this consumes EXACTLY the same number of clock cycles as one iteration of the grading
    loop (SETTLE + 2). An earlier version consumed a different count depending on which order it
    tried, so calibration and the loop ended on opposite phases and every graded sample came back
    off by a byte -- `got == exp * 256` across all 300 samples. Phase parity is state; a calibration
    that perturbs it differently than the thing it calibrates has calibrated nothing.
    """
    probe = 386                                   # the seed-margin worst case, a real operating point
    expect = reciprocal(probe)
    drive(dut, probe)
    await ClockCycles(dut.clk, SETTLE)
    a = int(dut.uo_out.value)
    await RisingEdge(dut.clk)
    b = int(dut.uo_out.value)
    await RisingEdge(dut.clk)                     # same trailing tick as the loop
    for hi_first in (True, False):
        r = (a << 8) | b if hi_first else (b << 8) | a
        r = r - (1 << 16) if r & 0x8000 else r
        if r == expect:
            dut._log.info(f"phase calibrated: hi_first={hi_first} (probe b={probe} -> {r})")
            return hi_first
    raise AssertionError(
        f"CALIBRATION FAILED: neither byte order reproduces golden({probe})={expect} "
        f"(read bytes {a:#04x}, {b:#04x}). The harness cannot establish its own alignment, "
        "so BAR 4 cannot be graded."
    )


@cocotb.test()
async def test_reciprocal_against_golden(dut):
    """Drive a sample of the certified domain and diff every output against the golden model."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())   # 50 MHz, the shuttle clock
    await reset(dut)

    hi_first = await calibrate_phase(dut)

    n = int(os.environ.get("GOLDEN_N", "300"))
    rng = random.Random(20260801)
    sample = rng.sample(DOMAIN, min(n, len(DOMAIN)))

    mismatches = []
    for b in sample:
        drive(dut, b)
        await ClockCycles(dut.clk, SETTLE)
        got = await read_frame(dut, hi_first)
        exp = reciprocal(b)
        if got != exp:
            mismatches.append((b, exp, got))
        await RisingEdge(dut.clk)

    if mismatches:
        head = ", ".join(f"b={b} exp={e} got={g}" for b, e, g in mismatches[:8])
        raise AssertionError(
            f"BAR 4 FAIL: {len(mismatches)} of {len(sample)} differ from golden. {head}"
        )
    dut._log.info(f"BAR 4: {len(sample)} certified-domain samples match the golden model exactly")


@cocotb.test()
async def test_golden_can_convict(dut):
    """CONVICT SPECIMEN — the comparison must be able to FAIL.

    A test that only ever passes is indistinguishable from a test that is not connected. This asserts
    the golden and the DUT disagree when the golden is deliberately perturbed by one LSB.
    """
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())
    await reset(dut)
    hi_first = await calibrate_phase(dut)
    b = 386
    drive(dut, b)
    await ClockCycles(dut.clk, SETTLE)
    got = await read_frame(dut, hi_first)
    assert got != reciprocal(b) + 1, (
        "CONVICT FAILED: the DUT matched a golden value perturbed by +1 LSB, so the comparison "
        "cannot distinguish correct from incorrect and BAR 4's pass means nothing."
    )
    dut._log.info("CONVICT: a one-LSB perturbation is detected — the comparison discriminates")
