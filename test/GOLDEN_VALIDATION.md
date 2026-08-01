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
