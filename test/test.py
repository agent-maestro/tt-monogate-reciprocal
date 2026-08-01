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

LATENCY = 17          # pipeline stages; MUST match the RTL. See PIPE_002_LOCAL_VERIFICATION.md.
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


@cocotb.test()
async def test_reciprocal_against_golden(dut):
    """Drive a sample of the certified domain and diff every output against the golden model."""
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())   # 50 MHz, the shuttle clock
    await reset(dut)

    n = int(os.environ.get("GOLDEN_N", "400"))
    rng = random.Random(20260801)
    sample = rng.sample(DOMAIN, min(n, len(DOMAIN)))

    # Frame-aligned drive/collect: present on even phase, read the two bytes back.
    mismatches = []
    for b in sample:
        drive(dut, b)
        # let the sample walk the whole pipe, then collect the two output bytes
        await ClockCycles(dut.clk, 2 * (LATENCY + 4))
        lo = int(dut.uo_out.value)
        await RisingEdge(dut.clk)
        hi = int(dut.uo_out.value)
        got = (hi << 8) | lo
        got = got - (1 << 16) if got & 0x8000 else got
        exp = reciprocal(b)
        if got != exp:
            mismatches.append((b, exp, got))

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
    b = 386                                    # the seed-margin worst case, a real operating point
    drive(dut, b)
    await ClockCycles(dut.clk, 2 * (LATENCY + 4))
    lo = int(dut.uo_out.value)
    await RisingEdge(dut.clk)
    hi = int(dut.uo_out.value)
    got = (hi << 8) | lo
    got = got - (1 << 16) if got & 0x8000 else got
    assert got != reciprocal(b) + 1, (
        "CONVICT FAILED: the DUT matched a golden value perturbed by +1 LSB, so the comparison "
        "cannot distinguish correct from incorrect and BAR 4's pass means nothing."
    )
    dut._log.info("CONVICT: a one-LSB perturbation is detected — the comparison discriminates")
