# The golden model — validated, and able to convict

**`golden.py` grades the gate-level netlist for BAR 4. A grader with no credentials is not a second
opinion, so it is checked against the shipped RTL before it is allowed to check anything.**

## Acquit / convict, over the whole certified domain

```
python3 validate_golden.py pairs16.txt        # pairs captured from the RTL by tb_pairs.cpp
```

| | mismatches |
|---|---:|
| **acquit** — unperturbed | **0 / 8,128** |
| **convict** — golden +1 LSB | **8,128 / 8,128 (100%)** |
| **convict** — golden −1 LSB | **8,128 / 8,128 (100%)** |

**Exhaustive over `\|b\| ∈ [32, 4095]` — the certified Q8.8 domain — both signs.** Zero disagreement
unperturbed; total disagreement under a one-LSB shift. **The comparison discriminates.**

## What the first attempt got wrong, kept because it is the lesson

The first golden **computed on `|b|` and negated at the end**. The RTL does not:

```verilog
y0_b2t <= sign_b2m ? -(p_b2m >>> (FRAC-1)) : (p_b2m >>> (FRAC-1));
```

**The sign is applied to the SEED**, and both Newton stages then run on signed values. Truncating
`>>>` floors toward −∞, so *negate-at-the-end* and *sign-the-seed* differ by an LSB on negatives.
**47% of the domain disagreed.** The fix was to mirror the pipeline stage for stage rather than
paraphrase its intent.

## Three numbers that are not the same number

This cost a session and briefly convicted a correct golden:

| quantity | value |
|---|---:|
| register stages in the design | **17** |
| relative offset between old and new RTL (`tb_cmp`) | **17** |
| index of input `k`'s result in a post-tick capture (`tb_pairs`) | **k + 16** |

`out` is pushed **after** each tick, so a 17-stage design puts input `k`'s result at `out[k+16]`.
**Established empirically. Assuming any two of these are equal is what produced 8,127 phantom
mismatches against a model that was already exact.**

## BAR 4 found a real wrapper defect before tapeout — frame tearing

The wrapper originally read `held` directly:

```verilog
always @(posedge clk) if (out_valid) held <= result;
assign uo_out = phase ? held[15:8] : held[7:0];
```

`held` updates every time `out_valid` pulses — **every 2 cycles** — so a two-cycle byte read
**straddled an update** and the low and high bytes could come from **different results**.

**The signature is what identified it, and it is worth keeping:** at every *even* frame offset the
output agreed with the golden on **~77%** of the domain; at every *odd* offset, **0%**. **A partial
match that no alignment could repair is tearing, not misalignment** — misalignment is all-or-nothing at
some offset, tearing is never clean at any.

**Fix:** a frame-stable `shown` register republishes `held` only at a frame boundary, so both bytes of
any frame come from one result. One 16-bit register; **the certified kernel is untouched.**

**This is the gate paying for itself.** The wrapper had shipped through runs 001 and 002 with `gl_test`
failing on stock assertions, so nothing had ever read its output and compared it to anything.

## The test calibrates its own phase — step zero, inside the test

`uo_out` shows the low byte on one phase and the high byte on the other, and **which one a read lands
on depends on the parity of the settle count.** Measured: `order1` (high byte first) is exact at
`SETTLE ∈ {40, 42, 60}`; `SETTLE = 41` splits 50/50.

So the test does not assume. **It probes a known operand (`b = 386`, the seed-margin worst case),
tries both byte orders, and adopts the one that reproduces the golden. If NEITHER does, it refuses to
grade anything** — a harness that cannot establish its own alignment cannot judge a netlist.
