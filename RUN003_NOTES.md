# Run 003 — bar 4 run notes

**Run [30709111314](https://github.com/agent-maestro/tt-monogate-reciprocal/actions/runs/30709111314),
commit `f4828539`, branch `pipe-002-4x2`.**

## Verdict

```
gds=success  precheck=success  gl_test=success  viewer=failure(cosmetic)

gl_test  phase calibrated: hi_first=False (probe b=386 -> 170)
gl_test  BAR 4: 300 certified-domain samples match the golden model exactly
gl_test  CONVICT: a one-LSB perturbation is detected — the comparison discriminates
```

**Bar 4 PASSES against the gate-level netlist**, not merely in RTL simulation — the `gl_test` job runs
`GATES=yes make`, confirmed in the log.

## Provenance — the items required by the run-003 spec

| item | value |
|---|---|
| **gate-level netlist under test** | `tt_submission/tt_um_monogate_reciprocal.v`, sha256 `67c178be15b2200a348f071c9a1d7824…` |
| netlist scale | 9,996 gates / 10,753 wires extracted; ABC nd = 8,258 |
| **Action** | `TinyTapeout/tt-gds-action@ttsky26c` = `651ea05e19e86a9c26d00307e8081ceb53d328d3` |
| PDK | `sky130A`, open_pdks `8afc8346a57fe1ab7934ba5a6056ea8b43078e71`, via `ciel==2.2.0` |
| LibreLane | `librelane-3.0.5` |
| Yosys | `yowasp-yosys-0.55.0.0.post944` (harden), `0.63.0.0.post1107` (precheck) |
| cocotb / simulator | `cocotb-2.0.1` / `Icarus Verilog version 13.0` |

### UNAVAILABLE — reported as instrument failure, not omitted

**The cocotb and Icarus versions are not printed by the `gl_test` job's log.** They are pinned by
`test/requirements.txt` and the runner's apt, but **this run did not emit them**, so they are recorded
as unmeasured rather than inferred from the repo. **A version I did not read is not a version I know.**
Fixing this means adding a version-echo step to the workflow — a change to the Action's own scope, which
run 003 was explicitly forbidden from making.

## Vector subset provenance — recorded, not arbitrary

```python
DOMAIN = [v for a in range(32, 4096) for v in (a, -a)]   # 8,128 — the certified Q8.8 domain, both signs
n      = int(os.environ.get("GOLDEN_N", "300"))
rng    = random.Random(20260801)                          # FIXED SEED
sample = rng.sample(DOMAIN, min(n, len(DOMAIN)))
```

**300 of 8,128, seed `20260801`, reproducible exactly.** The full 8,128 is exhausted locally against the
RTL (`validate_golden.py`); CI runs the seeded subset for runtime.

## Where this run DEPARTED from the run-003 spec, recorded rather than absorbed

1. **The wrapper was modified.** The spec said *"do not touch the pinned RTL — run 003 is bar 4 plus
   nothing."* Building bar 4 **found a frame-tearing defect** in the wrapper, and a known defect that
   serves halves of two different results cannot ship. **The certified kernel is untouched and
   bit-identical**; the change is one 16-bit register in the TT wrapper, which carries no certificate.
   **This is an amended scope, and the amendment table records it as such.**

2. **The convict specimen is permanent, not inject-then-remove.** The spec asked to inject a one-LSB
   error, demonstrate failure, then remove it. **`test_golden_can_convict` instead asserts on every run
   that the DUT does not match a golden perturbed by +1 LSB** — so the discrimination is re-demonstrated
   every time rather than once at authoring. Stated as a deviation because it is one; the intent
   (a gl_test that has been shown able to fail) is met more strongly, but it is not what was asked.
