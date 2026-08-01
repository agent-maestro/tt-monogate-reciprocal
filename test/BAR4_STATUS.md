# BAR 4 — the tapeout gate. **NOT PASSED. Work characterised, not shipped.**

**2026-08-01. Run 003 was to be bar 4 plus nothing. It is not done, and the reason is worth more than
a green tick would have been.**

## What was attempted

A Python golden model (`golden.py`) mirroring the RTL's localparams and truncating `qmul`, plus a real
cocotb test (`test.py`) replacing the template's adder assertions, plus a convict specimen asserting the
comparison can fail on a one-LSB perturbation.

## What stopped it — the golden disagrees with the artifact it would grade

Validated against the shipped RTL over the full certified domain (8,128 inputs, `tb_pairs.cpp`):

| alignment | mismatches |
|---|---|
| offset 0 | 8,128 / 8,128 |
| **offset +1** | **3,793 / 8,127** |
| offset +2 | 8,126 / 8,126 |

**Best case is 47% wrong.** Positive operands match under `+1`; **negative operands do not.**

## Root cause, identified

```verilog
assign result = norm_2bt ? y2_2bt : sat_2bt;   // NO sign re-application at the output
```

The sign registers terminate at `sign_b2m`. **The RTL applies the sign to the SEED and runs both Newton
stages on a signed value.** My model computes on `|b|` and negates at the end.

**Those are not the same computation.** Truncating `>>> FRAC` on a negative operand floors toward −∞, so
a signed NR and an unsigned-NR-then-negate diverge by an LSB on exactly the inputs that mismatched.

## Why this is not being pushed

**A golden that disagrees with the artifact on half the domain is not a second opinion; it is a second
defect.** Shipping it would make `gl_test` green or red for reasons unrelated to the netlist, which is
the precise failure bar 4 exists to prevent.

**Bar 4 therefore stands as FAIL — the same status it held after runs 001 and 002.** It is the tapeout
gate and it is not open.

## What the next session inherits

* `golden.py` — structurally wrong on the sign path, correct on magnitude for positives. **Fix: apply
  sign to the seed (`y0e`) and run both stages signed, mirroring the RTL rather than paraphrasing it.**
* `tb_pairs.cpp` — emits `(input, output)` pairs over the certified domain from the shipped RTL. **This
  is the validation instrument and it works**; it is what convicted the golden.
* `test.py` — the cocotb harness, including the convict specimen. Its `LATENCY = 17` constant is
  **unverified against the wrapper's 2-cycle framing** and must be established, not assumed.

**The alignment ambiguity is itself a finding:** the RTL-level pair harness needed `+1` where the
old-vs-new comparison used `17`, which means the absolute latency and the comparison offset are
different quantities and I had been conflating them.
