// eml_reciprocal.v -- 1/x in Q<WIDTH-FRAC>.<FRAC> fixed-point.
//
// Status: SCAFFOLD. Replaces the giant LUT divider that yosys
// synthesises from Verilog `/` with a small Newton-Raphson
// iteration. The backend (`hardware/hdl_gen/verilog_backend.py`)
// lowers EML `a / b` to `a * eml_reciprocal(b)` so that no kernel
// emits a Verilog `/` operator.
//
// Math:
//
//   y_{n+1} = y_n · (2 − b · y_n)        (Newton-Raphson for 1/b)
//
// NR squares the scaled error each step (e_{n+1} = e_n², where
// e_n = 1 − b·y_n), so the accuracy of the *initial* estimate sets
// how many stages are needed. With the 2-term linear seed below
// (|e_0| ≤ 1/17), TWO stages already reach 16 bits (e_2 ≈ e_0^4 ≈
// 1/83521 ≪ 2^−16), so PIPELINE_STAGES = 2 — down from the 4 the old
// 1-bit edge seed needed. (machlib nr_reciprocal_2stage proves the
// 2-stage bound; the 4-stage result is kept there as the general form.)
//
// The initial estimate is a **2-term minimax linear seed** on the
// normalised mantissa. Let the leading set bit of |b| (Q-format
// integer rep) be at position `lb`, so |b| ∈ [2^k, 2^(k+1)) with
// k = lb − FRAC, and m := |b|·2^(−k) ∈ [1, 2) is the mantissa.
// The seed is
//
//   y_0 = 2^(−k) · (C1 − C2·m),   C1 = 24/17,  C2 = 8/17
//
// which minimises the worst-case *scaled* seed error over the octave:
//
//   e_0 = 1 − b·y_0 = 1 − m·(C1 − C2·m) = (8/17)m² − (24/17)m + 1,
//   |e_0| ≤ 1/17 ≈ 0.059   for all m ∈ [1, 2)
//
// (equioscillating at m = 1, 3/2, 2). This is the fix for the bench
// finding (2026-07-25, monogate-research .../nr_reciprocal/FINDINGS.md):
// the OLD seed y_0 = 2^(−k) (the octave *upper edge*, reciprocal of
// the octave bottom) gave b·y_0 ∈ [1, 2), i.e. e_0 running 0→~1 across
// the octave and CROSSING 1/2 above b = 1.5·2^k — so the machlib proof
// hypothesis |e_0| ≤ 1/2 (NewtonReciprocalDivision.lean) held only on
// the lower half of each octave, and the 4-stage NR stalled near octave
// tops (silicon-confirmed: b=1.992 → E=0.882). The minimax seed keeps
// |e_0| ≤ 1/17 everywhere, so the proof's hypothesis holds across the
// full octave — and makes 2 stages sufficient (bench re-anchor
// confirmed the fix on silicon; 4 stages were over-provisioned).
//
// Cost: the seed reuses the leading-bit normaliser for 2^(−k) and adds
// three Q-format multiplies (mantissa m, C2·m, and the final scale) —
// combinational, in stage 1. C1/C2 are `(24<<FRAC)/17` and `(8<<FRAC)/17`
// (elaboration-time integer division), so the seed tracks any FRAC.
//
// ── DEFECT FIX 2026-07-27 — SEED SIGN-BIT OVERFLOW AT 2-3 LSB DENOMINATORS ──
//
// FOUND BY: instantiating the EKF forward-error bound (machlib
// Ekf2MeasModelFwdError / Ekf2GainConditioning) against the range-bearing
// anchor. Not by any bit-exactness check — RTL, golden and silicon all
// agreed, on a wrong number.
//
// THE BUG. The seed was `y0e = $signed(1 <<< (2*FRAC - lb))` under the guard
// `(2*FRAC - lb) < WIDTH`. For Q16.16/32-bit, `lb = 1` gives `1 <<< 31`,
// WHICH IS THE SIGN BIT, so the seed was NEGATIVE. `lb = 1` means |b| is 2 or
// 3 LSB. Measured: recip(3) = -1310718717 against an exact 1431655765 —
// 191% error, SIGN INVERTED. The guard caught lb = 0 and was off by one.
//
// WHY IT MATTERED MORE THAN A RANGE LIMIT. The minimax seed exists precisely
// so |e_0| <= 1/17, which discharges nr_reciprocal_2stage's hypothesis
// `hinv0 : |1 - b*y0| <= 1/2`. At lb = 1, |e_0| = 1.18 — THE LEAN THEOREM'S
// PRECONDITION WAS VIOLATED BY THE HARDWARE AND NOTHING CHECKED IT. Every
// forward-error claim flowing through this kernel was void in that region.
//
// THE FIX, in two parts:
//   (1) HALVED SEED SCALE. `y0e = 2^(2F-lb-1)` (<= 2^30, never bit WIDTH-1)
//       with the two multiplies by it truncating by FRAC-1 instead of FRAC.
//       The product is algebraically identical; only the constant shrinks.
//   (2) SATURATION NOW BYPASSES THE NR. `norm`/`sat` run the full length of
//       the pipe and the mux is at the OUTPUT. Seeding the NR with a
//       saturated value and then iterating was the second half of the defect
//       (b = 1 LSB returned 1879121915, not the saturation constant, because
//       two Newton steps ran on a value that is not a Newton iterate).
//
// DOMAIN, now explicit and enforced rather than a comment:
//   |b| >= 3 LSB  -> COMPUTED. 1/|b| <= 2^31-1 is representable.
//   |b| <= 2 LSB  -> SATURATES. 1/|b| would need 2^31 or 2^32.
//   `FLOOR_AV = 1 <<< (2*FRAC - WIDTH + 1)` tracks FRAC/WIDTH.
//
// REGRESSION EVIDENCE (Verilator, old RTL vs new, 57155 inputs over
// [-200000, 200000] step 7 plus edge cases): exactly SIX inputs change —
// b = +/-1, +/-2, +/-3 — and ZERO inputs at |b| >= 4 change. The fix is
// confined to the broken region.
//
// EFFECT ON THE RANGE-BEARING EKF: det S ran 732, 9, 5, 4, 4, 4, 4, 3 LSB
// across the anchor's 8 steps and hit the defect at step 7, inverting the
// gain's sign. Its error rose 0.04094 -> 0.04869 on a CONSTANT measurement,
// visible in the shipped golden trajectory for three bench rounds. With the
// fix the trajectory is monotone over 20 steps.
//
// ── THE CERTIFICATE HAS TWO ENVELOPES, NOT ONE (2026-07-28) ─────────────────
//
// nr_reciprocal_2stage bounds THE ITERATION'S CONTRACTION: given hinv0, Newton
// squares the residual toward zero. That is a theorem about the ALGORITHM.
// It is NOT the only error source, and quoting one number over a domain merges
// a proof about the algorithm with a property of the format.
//
//   ALGORITHM ERROR   owner: the theorem. ~0 once |e_0| <= 1/2 holds.
//   REPRESENTABILITY  owner: Q16.16. |1/b| in LSB. Dominates at BOTH ends:
//                     below |b| <= 2 it is unrepresentable (saturation), and
//                     above ~2^22 the QUOTIENT quantises to a few LSB.
//
// Quote the MAX of the two, per domain. Measured worst |1 - b*y2| by octave:
//     2^2 .. 2^22   < 1e-3     <- usable
//     2^24          7.9e-03
//     2^26          3.2e-02
//     2^30          5.2e-01    <- 1/b is TWO LSB; no algorithm can do better
//
// A CONSUMER'S CAVEAT, from getting this wrong once: those are RELATIVE
// residuals. |recip - 1/b| = |1 - b*y|/|b|, so the same residual over a large b
// is a SMALL ABSOLUTE error. eml_atan_wide's range fold consumes the absolute
// value and is fine to the top of the format (worst atan output error
// 1.97e-05 rad at |x| = 32767). Pick the metric the consumer actually uses.
//
// SEED MARGIN LEDGER -- the seed constant is computed arithmetic and can drift:
//     hypothesis (nr_reciprocal_2stage hinv0)   |1 - b*y0| <= 1/2
//     measured worst on [2^16, 2^17)            5.885312e-02 -> 8.50x margin
//        ^ CORRECTED 2026-07-31. This line read 5.8840e-02, and the excess line
//          below read 0.028%. Both were wrong in the 3rd significant digit; the
//          true worst is 5.885312e-02 at b = 98321 (m = 1.500259), read out of
//          y0_b2t with Verilator --public-flat-rw. The 8.5x MARGIN CLAIM WAS
//          CORRECT and no conclusion moved. Found by following this ledger's own
//          instruction to re-measure rather than assume, while re-deriving the
//          seed at Q8.8. See monogate-research/chip/SEED_MARGIN_RESULT.md.
//     measured worst on the full usable domain  ~6.5e-02 at 2^24
//     design target quoted above                1/17 = 5.8824e-02
//     => the FIXED-POINT seed exceeds the real-arithmetic minimax target by
//        0.050% (was documented as 0.028%; corrected 2026-07-31 with the line
//        above), from truncation in computing the seed itself. Harmless against
//        the 1/2 hypothesis; recorded because the text above claims 1/17 and
//        anyone regenerating LIN_C1/LIN_C2 should re-measure rather than assume.
//
//
// SEED MARGIN AT OTHER FORMATS (measured from THIS RTL, 2026-07-31, --public-flat-rw):
//     FRAC=6   worst 7.666e-02  -> 6.52x margin      LIN_C1=90     LIN_C2=30
//     FRAC=8   worst 6.607e-02  -> 7.57x margin      LIN_C1=361    LIN_C2=120
//     FRAC=10  worst 6.124e-02  -> 8.16x margin      LIN_C1=1445   LIN_C2=481
//     FRAC=12  worst 5.925e-02  -> 8.44x margin      LIN_C1=5783   LIN_C2=1927
//     FRAC=16  worst 5.885e-02  -> 8.50x margin      LIN_C1=92521  LIN_C2=30840
// Every format clears the machlib hypothesis |e_0| <= 1/2. Degradation is monotone
// and gentle; the seed error converges to the 1/17 real minimax from above. The
// coefficients are elaboration-time derived, so NOTHING is hand-entered at a new
// FRAC -- the re-derivation is a non-event and only the MEASUREMENT was needed.
// WIDTH CEILING -- 32, AND IT IS SILENT (documented 2026-07-31, NOT fixed):
//     `reg [4:0] lb` and `lb = i[4:0]` cap the leading-bit index at five bits.
//     WIDTH <= 32 is fine (max lb = 31, exactly five bits). At WIDTH >= 33 a
//     leading bit at position 32 records as position 0 and the seed scale
//     `1 <<< (2*FRAC - lb - 1)` goes catastrophically wrong. IT DOES NOT ERROR,
//     IT COMPUTES. The explicit i[4:0] slice reads as considered, which is what
//     makes it dangerous to a reviewer.
//     Left unfixed on purpose: the repair (`reg [$clog2(WIDTH)-1:0] lb`) changes
//     a silicon-anchored module for a width nobody has asked for, and fixing
//     anchored RTL for a hypothetical is how anchors rot. Widening past 32 is a
//     deliberate act; make it one. Verified safe at WIDTH = 12/16/20/24/32.
//     See monogate-research/chip/RTL_PARAMETER_AUDIT.md.
//
// Sign handling: `eml_reciprocal(b)` returns sign(b) · (1/|b|).
//   For b = 0 the result is undefined (Verilog produces all-zeros
//   from the shift; treat as a caller error — the Forge backend
//   should never emit `a / 0` for a constant; for a variable, the
//   caller is responsible for an `assume (b != 0)`).
//
// Pipeline: 15 stages, 1 sample/cycle throughput, 15-cycle latency. Each of the 7
// Q-format multiplies is split into a MULTIPLY stage (64-bit product registered
// into the DSP48 PREG) and a TRUNCATE stage (`>>>FRAC`), so both are <10 ns and the
// datapath closes 100 MHz (one qmul is ~15 ns combinational on Arty: ~5.4 ns DSP +
// ~4.5 ns truncate CARRY chain, which stage-splitting alone floored at ~66 MHz).
// The seed's leading-bit normaliser is likewise split from its first multiply (stage
// A_n registers the encoder/select output ahead of A_m's |b|*2^-k product): standalone
// the normaliser cone met 100 MHz, but placed inside a fuller design (the recursive
// filter) its routing pushed the normaliser+multiply cone to 11.45 ns — the split
// makes both halves <10 ns. This 15th stage is what took 14 -> 15.
// The emitted result is BIT-IDENTICAL to the combinational-seed version (staging
// only — registering the product does not change `(a*b)>>>FRAC`).
//
// I/O:
//   clk, rst    standard synchronous clock + active-high reset
//   in_valid    high when x_in is valid this cycle
//   x_in        signed Q<WIDTH-FRAC>.<FRAC> argument (b in a/b)
//   out_valid   high when result is valid (15 cycles later)
//   result      signed Q<WIDTH-FRAC>.<FRAC> approximation of 1/x_in

`default_nettype none

module eml_reciprocal #(
    parameter WIDTH = 32,
    parameter FRAC  = 16,
    parameter PIPELINE_STAGES = 2
) (
    input  wire                      clk,
    input  wire                      rst,
    input  wire                      in_valid,
    input  wire signed [WIDTH-1:0]   x_in,
    output wire                      out_valid,
    output wire signed [WIDTH-1:0]   result
);

    // Q-format constants
    // ── WIDTH CEILING, ENFORCED (2026-07-31) ──────────────────────────────────
    // `lb` is a 5-bit leading-bit index (`lb = i[4:0]` below), so WIDTH > 32 makes a
    // leading bit at position 32 record as position 0 and the seed scale go wrong --
    // SILENTLY, because it computes rather than errors. The header documents that;
    // this makes the toolchain confront it. A documented ceiling a reviewer must read
    // is a fence with a gap in it; an elaboration error is a wall.
    //
    // NOT a repair of the anchor: every in-play format (12/16/20/24/32) elaborates and
    // synthesises byte-unchanged. This only converts "does not error, computes" into
    // "does not elaborate", which is where an input's domain belongs -- checked where
    // inputs are checked. Honoured by both Yosys and Verilator (the latter downgrades
    // it to a warning under -Wno-fatal, so do not pass that flag when it matters).
    generate
      if (WIDTH > 32) begin : g_width_ceiling
        // Two guards, deliberately. $error carries the DIAGNOSIS; the missing-module
        // instantiation carries the STOP. Verilator downgrades $error to a warning under
        // -Wno-fatal -- which is the flag this module already needs for its pre-existing
        // WIDTHEXPAND warnings, so on its own $error would be suppressed exactly where it
        // is used. A reference to a module that does not exist is a structural error and
        // cannot be flagged away.
        $error("eml_reciprocal: WIDTH exceeds 32; the 5-bit leading-bit index `lb` cannot represent bit positions >= 32. Widen lb to $clog2(WIDTH) bits and RE-ANCHOR the module. See monogate-research/chip/RTL_PARAMETER_AUDIT.md");
        eml_reciprocal_WIDTH_must_not_exceed_32 u_ceiling_violation ();
      end
    endgenerate

    localparam signed [WIDTH-1:0] TWO = 2 <<< FRAC;
    // In Q16.16 this is 32'sd131072.

    // 2-term minimax linear seed coefficients, Q<>.FRAC (see header).
    // C1 = 24/17, C2 = 8/17; elaboration-time integer division tracks FRAC.
    // For FRAC=16: LIN_C1 = 92521 (0x16969), LIN_C2 = 30840 (0x7878).
    localparam signed [WIDTH-1:0] LIN_C1 = (24 <<< FRAC) / 17;
    localparam signed [WIDTH-1:0] LIN_C2 = ( 8 <<< FRAC) / 17;

    // ── DOMAIN FLOOR (2026-07-27 defect fix, see header) ──────────────────────
    // 1/|b| is representable iff  2^(2*FRAC)/|b| <= 2^(WIDTH-1)-1, i.e. |b| > 2^(2*FRAC-WIDTH+1).
    // For Q16.16/32-bit that is |b| > 2, so |b| >= 3 LSB computes and |b| <= 2 saturates.
    localparam [WIDTH-1:0]        FLOOR_AV = 1 <<< (2*FRAC - WIDTH + 1);   // = 2 for Q16.16
    localparam signed [WIDTH-1:0] SAT_POS  = ~((-1) <<< (WIDTH-1));        //  2^31-1
    localparam signed [WIDTH-1:0] SAT_NEG  =  ((-1) <<< (WIDTH-1));        // -2^31

    // Q-format multiply is `(a*b) >>> FRAC`; below it is split across two pipeline
    // stages — a 64-bit product register (DSP48 PREG) then the `>>>FRAC` truncate.

    // ── FULLY-PIPELINED reciprocal: qmul split multiply|truncate + normaliser split, 15 cycles ──
    // Silicon (run 5) showed one qmul is ~15 ns on Arty: ~5.4 ns DSP multiply +
    // ~4.5 ns `>>>FRAC` truncate/round CARRY chain. So 1-mul/stage floored at
    // ~15 ns (WNS -5 ns, ~66 MHz) — no more STAGE splitting helps. This splits
    // each qmul INTERNALLY: register the 64-bit PRODUCT (the DSP48 PREG the DPOP
    // advisories asked for since run 1) BEFORE the truncate, so multiply (~5.4 ns)
    // and truncate (~4.5 ns) are separate <10 ns stages. Each of the 7 qmuls
    // becomes `_m` (product) + `_t` (truncate); with the A_n normaliser split that is
    // 15 stages, latency 15, 1 sample/cycle throughput. Purely structural: BIT-IDENTICAL
    // result (registering the product/operands doesn't change `(a*b)>>>FRAC`), so
    // nr_reciprocal_2stage unchanged.
    //   A  : m   = |b| * 2^-k >> F        B1: c2m = C2 * m >> F
    //   B2 : y0  = 2^-k * (C1 - c2m) >> F  (signed)
    //   N1a: by1 = b * y0 >> F   N1b: y1 = y0 * (2 - by1) >> F
    //   N2a: by2 = b * y1 >> F   N2b: y2 = y1 * (2 - by2) >> F  -> result
    reg signed [WIDTH-1:0]   x_an, y0e_an, sat_an;  reg sign_an, norm_an, v_an;
    reg [WIDTH-1:0]          av_an;
    reg signed [WIDTH-1:0]   x_am, y0e_am, sat_am;  reg sign_am, norm_am, v_am;
    reg signed [2*WIDTH-1:0] p_am;
    reg signed [WIDTH-1:0]   x_at, y0e_at, m_at, sat_at; reg sign_at, norm_at, v_at;
    reg signed [WIDTH-1:0]   x_b1m, y0e_b1m, sat_b1m; reg sign_b1m, norm_b1m, v_b1m;
    reg signed [2*WIDTH-1:0] p_b1m;
    reg signed [WIDTH-1:0]   x_b1t, y0e_b1t, c2m_b1t, sat_b1t; reg sign_b1t, norm_b1t, v_b1t;
    reg signed [WIDTH-1:0]   x_b2m, sat_b2m; reg sign_b2m, norm_b2m, v_b2m;
    reg signed [2*WIDTH-1:0] p_b2m;
    // norm/sat now run the FULL length of the pipe: a saturated result must BYPASS the two NR
    // iterations, not seed them. Seeding the NR with a saturated value and then iterating was the
    // second half of the 2026-07-27 defect -- b = 1 LSB returned 1879121915 instead of the
    // saturation constant, because two Newton steps ran on a value that is not a Newton iterate.
    reg signed [WIDTH-1:0]   x_b2t, y0_b2t, sat_b2t; reg norm_b2t, v_b2t;
    reg signed [WIDTH-1:0]   x_1am, y0_1am, sat_1am; reg norm_1am, v_1am;
    reg signed [2*WIDTH-1:0] p_1am;
    reg signed [WIDTH-1:0]   x_1at, y0_1at, by1_1at, sat_1at; reg norm_1at, v_1at;
    reg signed [WIDTH-1:0]   x_1bm, sat_1bm; reg norm_1bm, v_1bm;
    reg signed [2*WIDTH-1:0] p_1bm;
    reg signed [WIDTH-1:0]   x_1bt, y1_1bt, sat_1bt; reg norm_1bt, v_1bt;
    reg signed [WIDTH-1:0]   y1_2am, sat_2am; reg norm_2am, v_2am;
    reg signed [2*WIDTH-1:0] p_2am;
    reg signed [WIDTH-1:0]   y1_2at, by2_2at, sat_2at; reg norm_2at, v_2at;
    reg signed [2*WIDTH-1:0] p_2bm; reg signed [WIDTH-1:0] sat_2bm; reg norm_2bm, v_2bm;
    reg signed [WIDTH-1:0]   y2_2bt, sat_2bt; reg norm_2bt, v_2bt;

    // combinational scratch for stage A_m (leading-bit normaliser; blocking)
    integer i;
    reg                    sgn;
    reg [WIDTH-1:0]        av;
    reg [4:0]              lb;
    reg signed [WIDTH-1:0] y0e_c, sat_c;
    reg                    norm_c;

    always @(posedge clk) begin
        if (rst) begin
            x_an <= '0; y0e_an <= '0; sat_an <= '0; sign_an <= 1'b0; norm_an <= 1'b0; v_an <= 1'b0; av_an <= '0;
            x_am <= '0; y0e_am <= '0; sat_am <= '0; sign_am <= 1'b0; norm_am <= 1'b0; v_am <= 1'b0; p_am <= '0;
            x_at <= '0; y0e_at <= '0; m_at <= '0; sat_at <= '0; sign_at <= 1'b0; norm_at <= 1'b0; v_at <= 1'b0;
            x_b1m <= '0; y0e_b1m <= '0; sat_b1m <= '0; sign_b1m <= 1'b0; norm_b1m <= 1'b0; v_b1m <= 1'b0; p_b1m <= '0;
            x_b1t <= '0; y0e_b1t <= '0; c2m_b1t <= '0; sat_b1t <= '0; sign_b1t <= 1'b0; norm_b1t <= 1'b0; v_b1t <= 1'b0;
            x_b2m <= '0; sat_b2m <= '0; sign_b2m <= 1'b0; norm_b2m <= 1'b0; v_b2m <= 1'b0; p_b2m <= '0;
            sat_b2t <= '0; norm_b2t <= 1'b0; sat_1am <= '0; norm_1am <= 1'b0;
            sat_1at <= '0; norm_1at <= 1'b0; sat_1bm <= '0; norm_1bm <= 1'b0;
            sat_1bt <= '0; norm_1bt <= 1'b0; sat_2am <= '0; norm_2am <= 1'b0;
            sat_2at <= '0; norm_2at <= 1'b0; sat_2bm <= '0; norm_2bm <= 1'b0;
            sat_2bt <= '0; norm_2bt <= 1'b0;
            x_b2t <= '0; y0_b2t <= '0; v_b2t <= 1'b0;
            x_1am <= '0; y0_1am <= '0; v_1am <= 1'b0; p_1am <= '0;
            x_1at <= '0; y0_1at <= '0; by1_1at <= '0; v_1at <= 1'b0;
            x_1bm <= '0; v_1bm <= 1'b0; p_1bm <= '0;
            x_1bt <= '0; y1_1bt <= '0; v_1bt <= 1'b0;
            y1_2am <= '0; v_2am <= 1'b0; p_2am <= '0;
            y1_2at <= '0; by2_2at <= '0; v_2at <= 1'b0;
            p_2bm <= '0; v_2bm <= 1'b0;
            y2_2bt <= '0; v_2bt <= 1'b0;
        end else begin
            // ── A_n: leading-bit normaliser (encoder + octave select + 2^-k), outputs
            //         REGISTERED. Split out of the old A_m so the normaliser cone
            //         (abs + CARRY leading-bit encoder + select, ~7 ns) and the first
            //         multiply |b|*2^-k (~4 ns) are separate <10 ns stages. Once the
            //         divisor is registered upstream, this normaliser->multiply cone was
            //         the recursive filter's WNS path (bench FINDINGS.md 2026-07-26:
            //         11.45 ns, WNS -2.937). Registering intermediates preserves values,
            //         so nr_reciprocal_2stage is unchanged; costs +1 latency (14 -> 15). ──
            sgn = x_in[WIDTH-1];
            av  = sgn ? ((~x_in) + 1) : x_in;
            lb  = 5'd0;
            for (i = 0; i < WIDTH; i = i + 1) if (av[i]) lb = i[4:0];
            // DEFECT FIX 2026-07-27 -- see header. The seed scale is now 2^(2F-lb-1), HALF the
            // old 2^(2F-lb), and the two multiplies by it truncate by FRAC-1 instead of FRAC. The
            // product is identical; what changes is that the CONSTANT can no longer reach bit
            // WIDTH-1. Old: lb=1 gave `1 <<< 31` = the sign bit, so the seed went NEGATIVE and the
            // reciprocal of a small positive number came out negative.
            if (av > FLOOR_AV) begin
                norm_c = 1'b1; y0e_c = $signed(1 <<< (2*FRAC - lb - 1)); sat_c = '0;
            end else begin
                // |b| <= 2 LSB: 1/|b| needs 2^31 or 2^32 and is NOT representable -- saturate.
                norm_c = 1'b0; y0e_c = '0; sat_c = sgn ? SAT_NEG : SAT_POS;
            end
            x_an <= x_in; sign_an <= sgn; av_an <= av; y0e_an <= y0e_c;
            sat_an <= sat_c; norm_an <= norm_c; v_an <= in_valid;
            // ── A_m: product |b| * 2^-k, from the registered normaliser operands ──
            x_am <= x_an; sign_am <= sign_an; y0e_am <= y0e_an; sat_am <= sat_an; norm_am <= norm_an;
            p_am <= $signed(av_an) * y0e_an; v_am <= v_an;
            // ── A_t: m = p_am >>> FRAC ──
            x_at <= x_am; sign_at <= sign_am; y0e_at <= y0e_am; sat_at <= sat_am; norm_at <= norm_am;
            m_at <= p_am >>> (FRAC-1); v_at <= v_am;   // halved seed -> one less bit
            // ── B1_m: product C2 * m ──
            x_b1m <= x_at; sign_b1m <= sign_at; y0e_b1m <= y0e_at; sat_b1m <= sat_at; norm_b1m <= norm_at;
            p_b1m <= LIN_C2 * m_at; v_b1m <= v_at;
            // ── B1_t: c2m = p_b1m >>> FRAC ──
            x_b1t <= x_b1m; sign_b1t <= sign_b1m; y0e_b1t <= y0e_b1m; sat_b1t <= sat_b1m; norm_b1t <= norm_b1m;
            c2m_b1t <= p_b1m >>> FRAC; v_b1t <= v_b1m;
            // ── B2_m: product 2^-k * (C1 - c2m) ──
            x_b2m <= x_b1t; sign_b2m <= sign_b1t; sat_b2m <= sat_b1t; norm_b2m <= norm_b1t;
            p_b2m <= y0e_b1t * (LIN_C1 - c2m_b1t); v_b2m <= v_b1t;
            // ── B2_t: y0 = seed (sign/sat applied to p_b2m >>> FRAC) ──
            x_b2t <= x_b2m;
            y0_b2t <= sign_b2m ? -(p_b2m >>> (FRAC-1)) : (p_b2m >>> (FRAC-1));
            norm_b2t <= norm_b2m; sat_b2t <= sat_b2m;
            v_b2t <= v_b2m;
            // ── N1a_m: product b * y0 ──
            x_1am <= x_b2t; y0_1am <= y0_b2t; p_1am <= x_b2t * y0_b2t; v_1am <= v_b2t;
            norm_1am <= norm_b2t; sat_1am <= sat_b2t;
            // ── N1a_t: by1 = p_1am >>> FRAC ──
            x_1at <= x_1am; y0_1at <= y0_1am; by1_1at <= p_1am >>> FRAC; v_1at <= v_1am;
            norm_1at <= norm_1am; sat_1at <= sat_1am;
            // ── N1b_m: product y0 * (2 - by1) ──
            x_1bm <= x_1at; p_1bm <= y0_1at * (TWO - by1_1at); v_1bm <= v_1at;
            norm_1bm <= norm_1at; sat_1bm <= sat_1at;
            // ── N1b_t: y1 = p_1bm >>> FRAC ──
            x_1bt <= x_1bm; y1_1bt <= p_1bm >>> FRAC; v_1bt <= v_1bm;
            norm_1bt <= norm_1bm; sat_1bt <= sat_1bm;
            // ── N2a_m: product b * y1 ──
            y1_2am <= y1_1bt; p_2am <= x_1bt * y1_1bt; v_2am <= v_1bt;
            norm_2am <= norm_1bt; sat_2am <= sat_1bt;
            // ── N2a_t: by2 = p_2am >>> FRAC ──
            y1_2at <= y1_2am; by2_2at <= p_2am >>> FRAC; v_2at <= v_2am;
            norm_2at <= norm_2am; sat_2at <= sat_2am;
            // ── N2b_m: product y1 * (2 - by2) ──
            p_2bm <= y1_2at * (TWO - by2_2at); v_2bm <= v_2at;
            norm_2bm <= norm_2at; sat_2bm <= sat_2at;
            // ── N2b_t: y2 = p_2bm >>> FRAC — output ──
            y2_2bt <= p_2bm >>> FRAC; v_2bt <= v_2bm;
            norm_2bt <= norm_2bm; sat_2bt <= sat_2bm;
        end
    end

    // SATURATION BYPASSES THE NR -- the mux is at the OUTPUT, not at the seed.
    assign result    = norm_2bt ? y2_2bt : sat_2bt;
    assign out_valid = v_2bt;

endmodule

`default_nettype wire
