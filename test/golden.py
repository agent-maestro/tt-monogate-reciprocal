"""Golden model for eml_reciprocal at WIDTH=16, FRAC=8 — pure integer, no RTL.

Mirrors the RTL's localparams and qmul semantics EXACTLY:
    LIN_C1 = (24 << FRAC) // 17     LIN_C2 = (8 << FRAC) // 17
    qmul(a,b) = (a*b) >> FRAC       (arithmetic shift, truncating)

VALIDATED, not asserted: `verify_against_rtl.py` in this directory checks this model against the
shipped RTL over the whole certified domain. A golden that has never been checked against the thing
it grades is a second opinion with no credentials.
"""
W, FRAC = 16, 8
ONE = 1 << FRAC
TWO = 2 << FRAC
LIN_C1 = (24 << FRAC) // 17
LIN_C2 = (8 << FRAC) // 17
MASK = (1 << W) - 1
SAT_POS = (1 << (W - 1)) - 1
SAT_NEG = -(1 << (W - 1))


def s(x):
    x &= MASK
    return x - (1 << W) if x & (1 << (W - 1)) else x


def qmul(a, b):
    return s((a * b) >> FRAC)


def reciprocal(x):
    """sign(x) * (1/|x|) in Q8.8, or the saturation constant outside the representable domain."""
    x = s(x)
    if x == 0:
        return SAT_POS
    neg = x < 0
    av = -x if neg else x
    # domain floor: 1/|b| representable iff |b| > 2^(2*FRAC-W+1)
    if av <= (1 << (2 * FRAC - W + 1)):
        return SAT_NEG if neg else SAT_POS
    lb = av.bit_length() - 1
    # seed: y0 = 2^-k * (C1 - C2*m), m = av * 2^-k
    m = s(av << (FRAC - lb)) if FRAC >= lb else s(av >> (lb - FRAC))
    y0e = 1 << (2 * FRAC - lb - 1)
    c2m = qmul(LIN_C2, m)
    y0 = qmul(y0e, s(LIN_C1 - c2m)) * 2
    y0 = s(y0)
    # two Newton stages, each a truncating qmul pair
    by1 = qmul(x if not neg else -x, y0)
    y1 = qmul(y0, s(TWO - by1))
    by2 = qmul(av, y1)
    y2 = qmul(y1, s(TWO - by2))
    return s(-y2) if neg else s(y2)
