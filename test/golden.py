"""Golden model for eml_reciprocal, WIDTH=16 FRAC=8 — a MIRROR of the RTL, not a paraphrase.

The first attempt computed on |b| and negated at the end. That is a DIFFERENT COMPUTATION: the RTL
applies the sign to the SEED (`y0_b2t <= sign ? -(p>>>(FRAC-1)) : ...`) and runs both Newton stages on
signed values, and truncating `>>>` floors toward -inf, so the two diverge by an LSB on negatives.
47% of the certified domain disagreed. This version follows the pipeline stage for stage.

Python's `>>` on negative ints floors, matching Verilog `>>>` on signed. Every intermediate is
sign-truncated to WIDTH via s() at the points the RTL registers it.

VALIDATED by `python3 validate_golden.py` against pairs captured from the shipped RTL.
"""
W, FRAC = 16, 8
TWO = 2 << FRAC
LIN_C1 = (24 << FRAC) // 17
LIN_C2 = (8 << FRAC) // 17
MASK = (1 << W) - 1
SAT_POS = (1 << (W - 1)) - 1
SAT_NEG = -(1 << (W - 1))
FLOOR_AV = 1 << (2 * FRAC - W + 1)


def s(x):
    """Truncate to WIDTH bits, two's complement — what a `reg signed [WIDTH-1:0]` does."""
    x &= MASK
    return x - (1 << W) if x & (1 << (W - 1)) else x


def reciprocal(x):
    x = s(x)
    sgn = 1 if (x & (1 << (W - 1))) or x < 0 else 0
    av = s(-x) & MASK if sgn else x & MASK          # av = sgn ? (~x)+1 : x, unsigned WIDTH bits

    lb = 0
    for i in range(W):
        if (av >> i) & 1:
            lb = i

    if av > FLOOR_AV:
        norm = 1
        y0e = s(1 << (2 * FRAC - lb - 1))
        sat = 0
    else:
        norm = 0
        y0e = 0
        sat = SAT_NEG if sgn else SAT_POS

    # A_m / A_t : m = (av * y0e) >>> (FRAC-1)
    p_am = s(av if av < (1 << (W - 1)) else av - (1 << W)) * y0e
    m = s(p_am >> (FRAC - 1))
    # B1_m / B1_t : c2m = (C2 * m) >>> FRAC
    c2m = s((LIN_C2 * m) >> FRAC)
    # B2_m / B2_t : y0 = sign applied to (y0e * (C1 - c2m)) >>> (FRAC-1)
    p_b2m = y0e * s(LIN_C1 - c2m)
    y0 = s(-(p_b2m >> (FRAC - 1))) if sgn else s(p_b2m >> (FRAC - 1))

    # N1a/N1b then N2a/N2b, on the SIGNED x and SIGNED y0
    by1 = s((x * y0) >> FRAC)
    y1 = s((y0 * s(TWO - by1)) >> FRAC)
    by2 = s((x * y1) >> FRAC)
    y2 = s((y1 * s(TWO - by2)) >> FRAC)

    return y2 if norm else sat
