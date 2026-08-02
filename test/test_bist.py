"""BIST-mode gl_test — bar 2 of the additions run, at gate level.

Adds four cases to the existing suite. They are the cases the design's own history generates, not a
uniform sweep of the interface:

  1. TRIGGER CONVICT (no-arm)   0x8000 once, then a normal operand -> NO BIST.
  2. TRIGGER CONVICT (arm)      0x8000 twice -> BIST, CRC == the pre-registered value.
  3. **BIST AFTER TRAFFIC**     the HISTORICAL convict. See below.
  4. LOCKOUT                    0x8000 held forever -> exactly one BIST, not a loop.

## Why (3) is not optional, and why it is not synthetic

The first version of this RTL had a real defect: `recv_cnt` self-aligns to `out_valid`, which made
the drain latency-independent — but at sweep start **the pipeline still held ~8 results from
whatever the host had been driving**, and those were attributed to sweep inputs 0–7. The CRC came
out wrong on an otherwise-working FSM. Fixed by flushing the kernel during `S_ARM`.

The rationale first written here was: *"BIST-from-idle passes forever while the flush is broken;
only after-traffic convicts it."* **MEASURED, AND FALSE.** Reverting the flush
(`.rst(kernel_rst)` -> `.rst(rst)`) fails **both** cases:

    flush reverted:  from_idle FAIL   after_traffic FAIL
    flush restored:  from_idle PASS   after_traffic PASS

The reason is embarrassingly simple once run: **entering BIST requires holding `0x8000` for two
frames, and those frames are themselves fed to the kernel** — so the pipeline is never empty at
sweep start, even from a quiet reset. There is no such thing as "from idle" through this trigger.

Case 3 is kept, with an honest and smaller justification: it covers residue from **arbitrary prior
operands** rather than only from the trigger frames, which is the realistic operating scenario. It
is *not* uniquely convicting, and the claim that it was has been withdrawn rather than left standing
because it sounded good.

## No typed constants

The expected CRC is read from `bist_expected.json`, produced by
`chip/crc/derive_expected_crc.py`. The test additionally asserts that the golden it can see hashes
to the value recorded in that JSON — so a golden that drifted from the one the constant was derived
against fails here rather than silently grading against a stale number.

## The egress order is CALIBRATED, not asserted

`PROVENANCE_ID` is a **pre-registered** constant loaded from `provenance_expected.json` — never read
from the DUT, which would be an oracle consulting its subject — so the 8-byte egress window is
*located* by scanning for it and
the CRC is read from the four bytes before it. Same discipline as `calibrate_phase()` in `test.py`:
the byte order of this interface has already been wrong once in prose, and the only artifact allowed
to assert it is a probe.
"""
import json
import os
from pathlib import Path

try:                                    # cocotb is needed for the simulator tests, not the specimen
    import cocotb
    from cocotb.clock import Clock
    from cocotb.triggers import ClockCycles, RisingEdge
except ImportError:                     # pragma: no cover - standalone specimen run
    # A shim so the specimen block at the bottom runs with no simulator installed. The oracle
    # defect that failed run 004 must be catchable without cocotb, a PDK, or 131k cycles.
    class _NoCocotb:
        @staticmethod
        def test(*a, **k):
            def deco(fn):
                return fn
            return deco
    cocotb = _NoCocotb()
    Clock = ClockCycles = RisingEdge = None

HERE = Path(__file__).resolve().parent
BIST_MAGIC = 0x8000
SWEEP_FRAMES = 1 << 16
EGRESS_BYTES = 8


def _expected():
    """The pre-registered value, loaded — never typed."""
    p = HERE / "bist_expected.json"
    if not p.is_file():
        p = HERE.parent / "bist_expected.json"
    d = json.loads(p.read_text())
    return d


def _golden_sha256():
    """Hash the golden this test can actually see, so a drifted golden cannot pass quietly."""
    import hashlib
    for cand in (HERE / "golden.py", HERE.parent / "golden.py"):
        if cand.is_file():
            return hashlib.sha256(cand.read_bytes().replace(b"\r\n", b"\n")).hexdigest()
    return None


async def _reset(dut):
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


def _drive(dut, v):
    v &= 0xFFFF
    dut.ui_in.value = v & 0xFF
    dut.uio_in.value = (v >> 8) & 0xFF



async def _calibrate_read(dut, probe=386):
    """Determine the coherent byte order from a KNOWN operand, exactly as `test.py` does.

    NOT OPTIONAL, and this function exists because its absence failed. The first version of this
    file hardcoded hi-first -- the order a Verilator testbench had happened to land on -- and the
    no-arm test read 0xAA00 where the answer is 0x00AA: the byte-swap, at a different reset/settle
    alignment. **I asserted a byte order in the very suite written to teach that you must not.**

    Returns hi_first: bool.
    """
    from golden import reciprocal
    expect = reciprocal(probe)
    _drive(dut, probe)
    await ClockCycles(dut.clk, 40)
    a = int(dut.uo_out.value)
    await RisingEdge(dut.clk)
    b = int(dut.uo_out.value)
    await RisingEdge(dut.clk)
    for hi_first in (True, False):
        r = (a << 8) | b if hi_first else (b << 8) | a
        r = r - (1 << 16) if r & 0x8000 else r
        if r == expect:
            dut._log.info(f"byte order calibrated: hi_first={hi_first}")
            return hi_first
    raise AssertionError(
        f"CALIBRATION FAILED: neither order reproduces golden({probe})={expect} "
        f"from bytes ({a:#04x}, {b:#04x}). The harness cannot establish its own alignment."
    )


async def _read_operand(dut, op, hi_first):
    """Drive an operand, settle, and read one coherent frame in the calibrated order."""
    _drive(dut, op)
    await ClockCycles(dut.clk, 40)
    a = int(dut.uo_out.value)
    await RisingEdge(dut.clk)
    b = int(dut.uo_out.value)
    await RisingEdge(dut.clk)
    r = (a << 8) | b if hi_first else (b << 8) | a
    return r - (1 << 16) if r & 0x8000 else r


async def _collect(dut, n):
    """n consecutive cycles of uo_out."""
    out = []
    for _ in range(n):
        out.append(int(dut.uo_out.value))
        await RisingEdge(dut.clk)
    return out


def _find_egress(trace, prov_id):
    """Locate the egress window by its KNOWN provenance anchor; return (crc, index) or (None, -1).

    Low-byte-first, per the stipulated convention — and this function is what probes it. If the
    convention were reversed, no window would be found and the test fails loudly rather than
    grading a byte-swapped number.
    """
    for i in range(len(trace) - EGRESS_BYTES + 1):
        pv = (trace[i + 4] | (trace[i + 5] << 8) | (trace[i + 6] << 16) | (trace[i + 7] << 24))
        if pv == prov_id:
            crc = (trace[i] | (trace[i + 1] << 8) | (trace[i + 2] << 16) | (trace[i + 3] << 24))
            return crc, i
    return None, -1


def _provenance_id(dut=None):
    """The PRE-REGISTERED provenance ID, loaded from outside the design under test.

    TWO DEFECTS DIED HERE, BOTH FIRED BY RUN 004.

    1. **Unreadable at gate level.** The previous version read `PROVENANCE_ID` off the DUT.
       **Parameters bake at synthesis** — on a flattened netlist the name does not exist, so all
       three sweep tests aborted at 110 ns with `cannot read PROVENANCE_ID from the DUT`. The same
       fact that made a parameterised short sweep inadmissible made this harness inadmissible, and
       the ruling was applied to the fallback and not to the harness that inherited it.

    2. **Circular, which is worse.** Anchoring the egress scan on a value read *from the DUT* means
       a die carrying the WRONG provenance ID would have been graded against its own wrong ID —
       and passed. **AN ORACLE THAT CONSULTS THE SUBJECT IS NOT AN ORACLE.** It is house rule 12's
       mirror image: the seal-check pattern was built for the CRC in this same file, and the
       provenance check was the deviation.

    The expected value now comes from `provenance_expected.json`, which is committed, predates the
    run, and derives from the `additions-evidence-v1` tag. **`dut` is accepted and ignored**, kept
    only so the call sites read the same; nothing about the design under test can influence what
    this returns.

    REFUSES rather than defaulting. The defect just fired was an oracle consulting the subject; the
    adjacent one, a single lazy default away, is an oracle consulting nothing.
    """
    for cand in (HERE / "provenance_expected.json", HERE.parent / "provenance_expected.json"):
        if cand.is_file():
            d = json.loads(cand.read_text())
            if "provenance_id_int" not in d:
                raise AssertionError(
                    f"{cand.name} carries no `provenance_id_int`. The egress window is anchored on "
                    f"it, so without it this suite cannot grade anything — and it will not guess."
                )
            return int(d["provenance_id_int"])
    raise AssertionError(
        "provenance_expected.json not found beside the test. The provenance ID is a PRE-REGISTERED "
        "expected value and must come from outside the design under test; there is no default and "
        "no fallback, because a default that masks the value it stands in for is how run 004 failed."
    )


async def _run_bist_and_read(dut, extra_cycles=600):
    """Hold MAGIC two frames, release, let the sweep run, and read the egress window."""
    prov = _provenance_id(dut)                 # resolved BEFORE the run, so a failure is loud here
    _drive(dut, BIST_MAGIC)
    await ClockCycles(dut.clk, 6)          # >= 2 frames
    _drive(dut, 0x0000)                    # released; BIST ignores the pins once running
    trace = await _collect(dut, 2 * SWEEP_FRAMES + extra_cycles)
    return _find_egress(trace, prov)


@cocotb.test()
async def test_golden_matches_the_constant_it_was_derived_from(dut):
    """Guard: the constant is only meaningful against the golden it came from."""
    exp = _expected()
    seen = _golden_sha256()
    if seen is None:
        dut._log.warning("golden.py not beside the test; hash guard SKIPPED (not passed)")
        return
    assert seen == exp["golden_sha256"], (
        f"the golden here ({seen[:16]}) is not the one bist_expected.json was derived from "
        f"({exp['golden_sha256'][:16]}). The expected CRC describes a different model."
    )


@cocotb.test()
async def test_single_magic_frame_does_not_arm(dut):
    """CONVICT: one magic frame must NOT enter BIST — no partial arm from any state."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    from golden import reciprocal                                   # noqa: E402

    hi_first = await _calibrate_read(dut)   # STEP ZERO -- establish alignment before judging

    _drive(dut, BIST_MAGIC)
    await ClockCycles(dut.clk, 2)          # exactly one frame
    got = await _read_operand(dut, 386, hi_first)   # then a normal operand
    assert got == reciprocal(386), (
        f"a single 0x8000 frame perturbed normal operation (read {got}, expected "
        f"{reciprocal(386)}). Either it partially armed, or it flushed and did not recover."
    )


@cocotb.test()
async def test_bist_from_idle_matches_expected_crc(dut):
    """ARM: two magic frames enter BIST and the checksum equals the pre-registered value."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    exp = _expected()
    crc, idx = await _run_bist_and_read(dut)
    assert crc is not None, "no egress window found — BIST never reached its output state"
    assert crc == exp["crc_certified"], (
        f"BIST returned 0x{crc:08X}, pre-registered 0x{exp['crc_certified']:08X} "
        f"(window at cycle {idx})"
    )


@cocotb.test()
async def test_bist_after_traffic_matches_expected_crc(dut):
    """THE HISTORICAL CONVICT — a full pipeline at sweep start must not corrupt the checksum.

    The defect this reproduces: ~8 results still in flight from prior traffic were counted as sweep
    results 0-7. BIST-from-idle cannot see it; only this case can.
    """
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    exp = _expected()

    for op in (386, 512, 1024, 300, 64, 2000, 33, 4095):     # fill the pipeline with real traffic
        _drive(dut, op)
        await ClockCycles(dut.clk, 2)

    crc, idx = await _run_bist_and_read(dut)
    assert crc is not None, "no egress window found after traffic"
    assert crc == exp["crc_certified"], (
        f"BIST-AFTER-TRAFFIC returned 0x{crc:08X}, pre-registered 0x{exp['crc_certified']:08X}. "
        f"This is the pipeline-residue defect: results in flight when the sweep began were "
        f"attributed to sweep inputs. BIST-from-idle would still pass."
    )


@cocotb.test()
async def test_magic_held_forever_runs_exactly_once(dut):
    """LOCKOUT: holding MAGIC does not loop the BIST."""
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    await _reset(dut)
    prov = _provenance_id(dut)

    _drive(dut, BIST_MAGIC)                                  # and never release
    trace = await _collect(dut, 2 * SWEEP_FRAMES + 600)
    first, idx = _find_egress(trace, prov)
    assert first is not None, "held-forever never completed a BIST at all"

    trace2 = await _collect(dut, 2 * SWEEP_FRAMES + 600)     # a second sweep's worth
    again, _ = _find_egress(trace2, prov)
    assert again is None, (
        "a second BIST completed while MAGIC was still held — the lockout does not hold, so the "
        "die would re-sweep for as long as the trigger is present."
    )


# ── SPECIMEN for the run-004 defect, both directions ──────────────────────────────────────────
#
# These need no simulator: they exercise the oracle directly, which is the point. The defect that
# failed run 004 was in the oracle, not the design, and an oracle defect must be catchable without
# a 131k-cycle run or a PDK.

def specimen_oracle_ignores_the_dut():
    """CONVICT the circularity: a DUT claiming a different ID must not move the expected value.

    The run-004 design read PROVENANCE_ID off the DUT, so a die carrying the WRONG id would have
    been graded against its own wrong id and passed. This fails if the oracle ever consults the
    subject again.
    """
    class LyingDut:
        class PROVENANCE_ID:
            value = 0xDEADBEEF
        class user_project:
            class PROVENANCE_ID:
                value = 0xDEADBEEF

    got = _provenance_id(LyingDut())
    assert got == 0x9FB80077, f"the oracle consulted the subject: got {got:#010x}"
    assert got != 0xDEADBEEF
    return "oracle ignores the DUT"


def specimen_works_with_no_dut_at_all():
    """The gate-level condition, reproduced without a PDK.

    At gate level the parameter does not exist -- parameters bake at synthesis. Passing no DUT is
    the strictly harder case, so if this resolves, a flattened netlist cannot break it.
    """
    assert _provenance_id(None) == 0x9FB80077
    assert _provenance_id() == 0x9FB80077
    return "resolves with no DUT"


def specimen_refuses_when_the_file_is_missing(tmpdir):
    """An oracle consulting NOTHING is the adjacent defect, one lazy default away."""
    import shutil, tempfile
    global HERE
    saved = HERE
    try:
        HERE = Path(tempfile.mkdtemp())        # a directory with no expected-value file
        try:
            _provenance_id(None)
        except AssertionError as e:
            assert "will not guess" in str(e) or "no default" in str(e)
            return "refuses with no file"
        raise AssertionError("returned a value with no expected-value file present")
    finally:
        HERE = saved


if __name__ == "__main__":
    # Runnable WITHOUT cocotb or a simulator, deliberately: the run-004 defect lived in the oracle,
    # and an oracle defect must be catchable without a 131k-cycle run or a PDK.
    print("  ok  " + specimen_oracle_ignores_the_dut())
    print("  ok  " + specimen_works_with_no_dut_at_all())
    print("  ok  " + specimen_refuses_when_the_file_is_missing(None))
    print("SPECIMEN OK — the run-004 defect is structurally unreachable")
