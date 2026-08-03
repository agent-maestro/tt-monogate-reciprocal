## How it works

A **Newton–Raphson fixed-point reciprocal** in Q8.8 (signed 16-bit, 8 fractional bits) computing
`1/x` — with a **machine-checked forward-error bound**.

The kernel is 17 pipeline stages, 1 sample/cycle throughput. Its error bound is proven in **Lean 4**
(`nr_reciprocal_2stage_at_format`, free of `sorry`) and holds over a **certified domain** of
`|x| ∈ [32, 4095]` raw — that is `|x| ∈ [0.125, 15.996]` in Q8.8. The seed margin and the usable
domain were **measured exhaustively**, not assumed.

Around the kernel sit a byte-serial I/O shell, a **CRC self-test (BIST)**, and a **provenance
register**. Only the kernel carries the certificate; the wrapper is I/O plumbing and is labelled as
such in the source.

### Protocol — a 2-cycle frame, phase counted from reset, no control pins spent

* **phase 0** — the 16-bit operand `{uio_in, ui_in}` is latched
* `uo_out` presents the 16-bit result **one byte per cycle**

**The wire byte order is calibrated, not asserted.** The coherent frame pairing is
**(phase 1 = high byte, then next phase 0 = low byte)**. Measured 2026-08-01: operand `386` reads
back `(0x00, 0xAA)`.

**`uio` is input-only, forever** (`uio_oe = 0`). On a die nobody can patch, dead pins beat live
conveniences.

### BIST — a self-sweep against a checksum fixed in advance

**Operand `0x8000` is a reserved trigger, not a reciprocal input.** Held for **two consecutive
frames** it arms a sweep over all 65,536 operand values, CRC-32ing the results whose `|operand|`
lands in the certified domain — **8,128 values, exactly half of them negative.**

The sweep then emits **8 bytes on `uo_out`, one per cycle, little-endian**:

| bytes | content |
|---|---|
| **0–3** | **CRC-32 = `0x4450E8E4`** — pre-registered *before any BIST RTL existed* |
| **4–7** | **`PROVENANCE_ID = 0xC03FF86C`** → evidence tag `additions-evidence-v2` |

**Exactly one BIST per hold**, however long the hold; re-arming requires the operand to leave
`0x8000` first.

> **The checksum certifies the design as built.** It was derived from the golden model, which is this
> RTL — so a die returning `0x4450E8E4` is a die whose certified-domain arithmetic is bit-for-bit
> what was proven and taped out.

## How to test

1. **Reset**, then count cycles — phase alternates from reset and there are no control pins.
2. **Drive the operand**: low byte on `ui[7:0]`, high byte on `uio[7:0]`. Hold it for a full frame.
3. **Read the result** on `uo[7:0]`, pairing **phase 1 (high) with the following phase 0 (low)**.
4. **Check against the reciprocal**: for `x` in the certified domain the result approximates
   `1/x` in Q8.8, with the residual `|1 − x·y|` inside the proven bound.
5. **Run the BIST**: hold `0x8000` for two frames, then read 8 bytes on consecutive cycles. The first
   four must be `0x4450E8E4`; the last four identify the evidence tag this die was built from.

Full reproduction instructions, the Lean proof, the exhaustive sweeps and the errata live at
<https://github.com/agent-maestro/tt-monogate-reciprocal>.

## External hardware

**None.** The design needs only the clock, reset and the standard TT pin header.
