#!/usr/bin/env python3
"""Convict/acquit the golden against pairs captured from the SHIPPED RTL.
A golden that has never been checked against the artifact it grades has no credentials."""
import sys
from golden import reciprocal
rows = [tuple(map(int, l.split())) for l in open(sys.argv[1])]
bad = [(b, reciprocal(b), y) for b, y in rows if reciprocal(b) != y]
print(f"GOLDEN vs RTL over {len(rows)} certified-domain inputs: {len(bad)} mismatches")
for t in bad[:8]:
    print("   b=%-6d golden=%-7d rtl=%-7d" % t)
raise SystemExit(1 if bad else 0)
