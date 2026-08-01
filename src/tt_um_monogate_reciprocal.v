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
 *   phase 0 : x_in = {uio_in, ui_in} latched, in_valid pulsed;  uo_out = result[7:0]
 *   phase 1 :                                                   uo_out = result[15:8]
 * uio is input-only (uio_oe = 0), so the 16-bit operand arrives in parallel and the 16-bit
 * result leaves serially. The host counts cycles from reset to recover the phase, which a
 * cycle-accurate golden-replay harness already does.
 */

`default_nettype none

module tt_um_monogate_reciprocal (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  wire rst = ~rst_n;

  reg phase;
  always @(posedge clk) begin
    if (rst) phase <= 1'b0;
    else     phase <= ~phase;
  end

  wire signed [15:0] x_in = {uio_in, ui_in};
  wire signed [15:0] result;
  wire               out_valid;

  eml_reciprocal #(.WIDTH(16), .FRAC(8), .PIPELINE_STAGES(2)) u_recip (
      .clk       (clk),
      .rst       (rst),
      .in_valid  (~phase),
      .x_in      (x_in),
      .out_valid (out_valid),
      .result    (result)
  );

  // ── FRAME-STABLE OUTPUT (defect fix 2026-08-01, found by BAR 4 before tapeout) ────────────
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

  assign uo_out  = phase ? shown[15:8] : shown[7:0];
  assign uio_out = 8'd0;
  assign uio_oe  = 8'd0;

  wire _unused = &{ena, 1'b0};

endmodule
