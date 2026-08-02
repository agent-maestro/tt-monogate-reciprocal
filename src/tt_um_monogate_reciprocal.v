/*
 * Monogate certified reciprocal — Tiny Tapeout wrapper.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Wraps `eml_reciprocal` (WIDTH=16, FRAC=8) for TT's 8-in / 8-out / 8-bidir pinout.
 *
 * THE WRAPPER IS NOT THE CERTIFIED PART. The Lean bound, the seed margin (7.57x) and the
 * exhaustive residual sweep all cover `eml_reciprocal` alone. This file is I/O plumbing and
 * carries no certificate; its only job is to present the kernel's ports across 8-bit pins
 * without changing a bit of the kernel.
 *
 * Protocol -- 2-cycle frame, phase counted from reset, no control pins spent:
 *   phase 0 : x_in = {uio_in, ui_in} latched, in_valid pulsed;  uo_out = shown[7:0]
 *   phase 1 :                                                   uo_out = shown[15:8]
 * uio is input-only (uio_oe = 0), so the 16-bit operand arrives in parallel and the 16-bit
 * result leaves serially. The host counts cycles from reset to recover the phase.
 *
 * THE WIRE BYTE ORDER IS CALIBRATED, NOT ASSERTED. The mux above says phase 0 carries
 * shown[7:0], but `shown` updates on the edge LEAVING phase 0, so the coherent frame pairing is
 * (phase 1 high, next phase 0 low). Measured 2026-08-01: operand 386 reads back (0x00, 0xAA) =
 * 170 = golden(386), i.e. HIGH BYTE FIRST at the alignment test/test.py uses. That test
 * calibrates the order at runtime against a known probe and refuses to grade if neither order
 * reproduces the golden. DO NOT hardcode a byte order from this comment. Probe it.
 *
 * -- ADDITIONS (2026-08-01) -------------------------------------------------------------------
 * uio_oe STAYS 0 FOREVER. On a die nobody can patch, dead pins beat live conveniences: holding
 * uio input-only forecloses the entire bidirectional-contention class, and a BIST done-flag is
 * not worth reopening it. Everything below is read by counting cycles, as the design already did.
 *
 * 1. CRC SELF-SWEEP (BIST), entered by a RESERVED OPERAND.
 *    0x8000 held for TWO consecutive frames enters BIST. 0x8000 is -32768, whose |b| = 32768
 *    lies far outside the certified domain |b| in [32, 4095], so the reservation costs no
 *    certified behaviour. This is a DOMAIN EXCLUSION, not a caveat: behaviour at 0x8000 is
 *    SPECIFIED as BIST entry, which is a smaller and cleaner claim than the uncertified
 *    saturate it replaces.
 *
 * 2. PROVENANCE REGISTER -- a read-only word identifying the frozen source, streamed after the
 *    CRC. Tie-cells; no sequential cost.
 *
 * Theorem-monitor is DEFERRED to chip 2 and is deliberately absent.
 */

`default_nettype none

module tt_um_monogate_reciprocal #(
    // The frozen-source pointer this die reports.
    //
    // PINNED 2026-08-01 to monogate-research tag `additions-evidence-v1` = commit 9fb80077, the
    // frozen pre-submission evidence state: the armed pre-registration, the CRC derivation script
    // and its expected values, this RTL, and bar 2's test suite.
    //
    // THE TAG IS CUT BEFORE THE ID IS DERIVED, and that ordering is the whole point. The ID lives
    // INSIDE the submitted files, so a pointer to the submission's own tag could never exist --
    // the hash would have to contain itself. Pointing at a tag that already exists and never moves
    // is the only non-circular option, and it was fixed as a sequence before push day rather than
    // discovered during the shuttle window.
    parameter [31:0] PROVENANCE_ID = 32'h9FB80077
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  localparam [15:0] BIST_MAGIC = 16'h8000;

  // Certified Q8.8 domain, |b| in [32, 4095] -- the window the CRC accumulates over. Outside it
  // the kernel saturates and nothing is certified, so folding those results into the checksum
  // would grade the die on a claim nobody made.
  localparam [15:0] CERT_LO = 16'd32;
  localparam [15:0] CERT_HI = 16'd4095;

  wire rst = ~rst_n;

  reg phase;
  always @(posedge clk) begin
    if (rst) phase <= 1'b0;
    else     phase <= ~phase;
  end

  wire [15:0] pin_operand = {uio_in, ui_in};

  // -- TRIGGER FSM -- total by construction ----------------------------------------------------
  //
  // Every question the pre-registration asks has one answer here, from any state:
  //   0x8000 once, then a normal operand   -> S_NORMAL. NO partial arm.
  //   0x8000 held two frames               -> exactly one BIST.
  //   0x8000 held three frames, or forever -> exactly one BIST. `lockout` blocks re-arming
  //                                           until the operand LEAVES 0x8000.
  //   anything on the pins during BIST     -> ignored. Exit is COMPLETION-ONLY; no abort.
  localparam [1:0] S_NORMAL = 2'd0,
                   S_ARM    = 2'd1,
                   S_RUN    = 2'd2,
                   S_OUT    = 2'd3;

  reg [1:0]  state;
  reg        lockout;          // set on BIST completion, cleared when the operand leaves MAGIC
  reg [15:0] sweep_idx;        // which input to ISSUE next
  reg        issue_done;       // all 65,536 issued
  reg [16:0] recv_cnt;         // results RECEIVED -- 17 bits so 65,536 is representable
  reg [31:0] crc;
  reg [2:0]  out_byte;         // which egress byte is being presented (0..7)

  wire frame_tick = ~phase;    // one pulse per 2-cycle frame, aligned with in_valid
  wire is_magic   = (pin_operand == BIST_MAGIC);

  // -- kernel feed -----------------------------------------------------------------------------
  // In BIST the operand comes from the sweep counter; otherwise from the pins. in_valid keeps its
  // original cadence in both cases, so the kernel sees an unchanged interface.
  wire signed [15:0] x_in = (state == S_RUN) ? $signed(sweep_idx) : $signed(pin_operand);
  wire signed [15:0] result;
  wire               out_valid;

  // PIPELINE FLUSH ON ARM. Removing the latency dependence at the TAIL (recv_cnt self-aligns)
  // left it at the HEAD: when the sweep starts, the pipeline still holds ~8 results from whatever
  // the host was driving before, and recv_cnt would attribute those to sweep inputs 0..7. The
  // simulation caught it as a wrong CRC on an otherwise working FSM.
  //
  // Asserting the kernel's reset for the single S_ARM frame empties it. The kernel's reset is
  // synchronous and clears EVERY valid bit in one clock, so one frame is more than sufficient --
  // verified by reading its reset block, not assumed from its latency.
  //
  // Consequence, documented rather than discovered: driving 0x8000 discards any results still in
  // flight. That is reserved-word semantics -- 0x8000 is not a reciprocal operand, it is the BIST
  // trigger -- and it costs nothing certified.
  wire kernel_rst = rst || (state == S_ARM);

  eml_reciprocal #(.WIDTH(16), .FRAC(8), .PIPELINE_STAGES(2)) u_recip (
      .clk       (clk),
      .rst       (kernel_rst),
      .in_valid  (~phase),
      .x_in      (x_in),
      .out_valid (out_valid),
      .result    (result)
  );

  // -- CRC-32, reflected (poly 0x04C11DB7 -> 0xEDB88320), init/xorout 0xFFFFFFFF ---------------
  // Byte-at-a-time, unrolled 8 bits combinationally. Mirrors `crc32_bitserial` in
  // chip/crc/derive_expected_crc.py line for line -- that routine is deliberately not
  // table-driven so this can be diffed against it.
  function [31:0] crc32_byte;
    input [31:0] c_in;
    input [7:0]  b;
    reg   [31:0] c;
    integer      i;
    begin
      c = c_in ^ {24'd0, b};
      for (i = 0; i < 8; i = i + 1)
        c = c[0] ? ((c >> 1) ^ 32'hEDB88320) : (c >> 1);
      crc32_byte = c;
    end
  endfunction

  // Which input does the CURRENT result belong to? `recv_cnt`, because out_valid pulses once per
  // issued input, in order. THE DRAIN IS THEREFORE LATENCY-INDEPENDENT: nothing here encodes the
  // measured 17-cycle issue-to-valid figure, so an error in that constant cannot shift which
  // 65,536 results the checksum covers. (Latency measured 2026-08-01 at 17 cycles issue-to-valid
  // against a golden-matched ramp; the header comment's 15 is pre-split and stale.)
  wire [15:0] recv_idx  = recv_cnt[15:0];
  wire [15:0] recv_abs  = recv_idx[15] ? (~recv_idx + 16'd1) : recv_idx;
  wire        recv_cert = (recv_abs >= CERT_LO) && (recv_abs <= CERT_HI);
  wire [15:0] res_u     = result;

  // -- the sequencer ---------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst) begin
      state      <= S_NORMAL;
      lockout    <= 1'b0;
      sweep_idx  <= 16'd0;
      issue_done <= 1'b0;
      recv_cnt   <= 17'd0;
      crc        <= 32'hFFFFFFFF;
      out_byte   <= 3'd0;
    end else begin
      if (!is_magic) lockout <= 1'b0;      // re-arming needs the operand to leave MAGIC first

      case (state)
        S_NORMAL: if (frame_tick && is_magic && !lockout) state <= S_ARM;

        S_ARM: if (frame_tick) begin
          if (is_magic) begin
            state      <= S_RUN;
            sweep_idx  <= 16'd0;
            issue_done <= 1'b0;
            recv_cnt   <= 17'd0;
            crc        <= 32'hFFFFFFFF;
          end else begin
            state <= S_NORMAL;             // one magic frame alone does NOT arm
          end
        end

        S_RUN: begin
          if (frame_tick && !issue_done) begin
            if (sweep_idx == 16'hFFFF) issue_done <= 1'b1;
            sweep_idx <= sweep_idx + 16'd1;
          end
          if (out_valid) begin
            if (recv_cert) crc <= crc32_byte(crc32_byte(crc, res_u[7:0]), res_u[15:8]);
            recv_cnt <= recv_cnt + 17'd1;
            if (recv_cnt == 17'd65535) begin
              state    <= S_OUT;
              out_byte <= 3'd0;
            end
          end
        end

        // ONE BYTE PER PHASE, i.e. per CYCLE -- eight phases, four frames. Advancing on
        // `frame_tick` here would hold each byte for two cycles and take eight frames, which is
        // what an earlier revision did while this file's egress comment claimed otherwise. The
        // simulation caught the disagreement; the code was wrong and the convention stands.
        S_OUT: begin
          if (out_byte == 3'd7) begin
            state   <= S_NORMAL;
            lockout <= 1'b1;               // exactly one BIST per hold, however long the hold
          end
          out_byte <= out_byte + 3'd1;
        end

        default: state <= S_NORMAL;
      endcase
    end
  end

  // -- FRAME-STABLE OUTPUT (defect fix 2026-08-01, found by BAR 4 before tapeout) ---------------
  // `held` updates whenever out_valid pulses -- every 2 cycles. Reading its low byte on phase 0
  // and its high byte on phase 1 therefore STRADDLED an update: the two bytes could come from
  // DIFFERENT RESULTS. Signature was ~77% agreement with the golden at every even frame offset
  // and 0% at every odd one -- a partial match that no alignment could fix, which is what
  // distinguishes tearing from misalignment.
  //
  // `shown` republishes `held` only at a frame boundary, so both bytes of any frame come from one
  // result. Costs one 16-bit register; the kernel is untouched.
  reg [15:0] held;
  reg [15:0] shown;
  always @(posedge clk) begin
    if (rst) begin
      held  <= 16'd0;
      shown <= 16'd0;
    end else begin
      if (out_valid) held <= result;
      if (!phase)    shown <= held;
    end
  end

  // -- egress ----------------------------------------------------------------------------------
  // STIPULATED CONVENTION, probed in simulation, not inferred from this comment: the BIST result
  // streams LOW BYTE FIRST -- CRC[7:0], [15:8], [23:16], [31:24], then PROVENANCE_ID[7:0] ..
  // [31:24] -- one byte per PHASE, eight phases, four frames. Same low-first rule as the CRC's
  // internal datum order, so there is one convention to remember rather than two.
  wire [31:0] crc_final = crc ^ 32'hFFFFFFFF;
  reg  [7:0]  egress;
  always @(*) begin
    case (out_byte)
      3'd0: egress = crc_final[7:0];
      3'd1: egress = crc_final[15:8];
      3'd2: egress = crc_final[23:16];
      3'd3: egress = crc_final[31:24];
      3'd4: egress = PROVENANCE_ID[7:0];
      3'd5: egress = PROVENANCE_ID[15:8];
      3'd6: egress = PROVENANCE_ID[23:16];
      default: egress = PROVENANCE_ID[31:24];
    endcase
  end

  assign uo_out  = (state == S_OUT) ? egress
                                    : (phase ? shown[15:8] : shown[7:0]);
  assign uio_out = 8'd0;
  assign uio_oe  = 8'd0;   // input-only, forever -- forecloses contention on a die nobody can patch

  wire _unused = &{ena, 1'b0};

endmodule
