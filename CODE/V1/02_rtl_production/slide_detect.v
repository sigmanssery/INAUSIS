//=============================================================================
// slide_detect -- on-chip, force-invariant discrimination of sliding contact
// from pressing contact.  One decision per contact event, emitted in-band.
//
// THE MEASURE
//
//   H = RMS(raw - G_s1) / RMS(DoG_fast)      accumulated over one contact
//
// Numerator and denominator are two band-limited views of the SAME signal --
// the residual above G_s1's corner, and the 14-70 Hz DoG_fast band -- so contact
// amplitude cancels.  That part holds: correlation with contact amplitude is
// +0.01 over a 2x force range, and the measure survives 6x added noise and 4x
// amplitude reduction.
//
// !! THE CLASSIFICATION CLAIM DID NOT REPLICATE.  READ THIS BEFORE QUOTING IT. !!
//
//   session 1 (53 events)   press 16/16 100%   slide 34/37  92%   total 94%
//   session 2 (105 events)  press 16/16 100%   slide 35/89  39%   total 48.6%
//   (session 2 = cold power cycle + class order reversed + interleaved)
//
// The press side replicates exactly (H median 3.08 both times, never once
// misread as a slide).  The SLIDE side collapses: H median 5.84 -> 3.12, on top
// of the press distribution.  Not force (matched |g3| 11000-24000 still gives
// 97% vs 34%), not duration (r = -0.05 over 126 events), not firmware (dead map
// identical).  At matched force the second session's slides carry only 0.36-0.46x
// the 100-292 Hz power and 1.81x the 0-20 Hz power: they were slid more smoothly.
//
// So H measures whether the contact has STICK-SLIP, not whether it is a slide.
// One instruction ("slide") produces two physically different contacts, and a
// smooth one is a press as far as this band is concerned.  The measurement is
// sound -- board decision, board accumulators and offline recomputation agree
// per event to within 1% -- what fails is the class label.
//
// Kept in the design as a characterised measure, NOT as a gesture classifier.
// See DATA/SLIDE_DETECT_2026-08-28.md.
//
// WHY THE DENOMINATOR IS DoG_fast AND NOT G_s3
//
// The force-invariance above is the whole reason for this shape.  The obvious
// alternative, DoG_fast / G_s3, correlates -0.91 with force: it separates gesture classes only because the
// classes happened to be pressed at different forces, which is what invalidated
// the 2026-08-28 gesture corpus.  Dividing by G_s3 -- a near-DC quantity that
// grows with force while the high-band residual does not -- is the trap.
//
// WHY IT MUST BE GATED ON CONTACT
//
// At rest H is 5.02-6.30, ABOVE both classes, because numerator and denominator
// are then both noise and the ratio means nothing.  A free-running comparator
// would report "slide" continuously on an untouched sensor.  Contact gating is
// not an optimisation here, it is a correctness requirement.
//
// ARITHMETIC
//
// Squares are accumulated with a >>8 prescale so a 40-bit accumulator covers the
// longest plausible contact.  The threshold compare is
//
//   acc_hp * 256  >  acc_fast * thr_q8          thr_q8 = 3.77 * 256 = 965
//
// done once per event by a 16-step shift-add rather than a wide parallel
// multiplier: there are ~39187 clocks between samples, so a 16-cycle multiply is
// free, and it keeps this out of the 27 MHz critical path entirely.
//
// THRESHOLD PROVENANCE.  3.77 came from the 2026-08-28 17-file force sweep;
// 3.30 sits between that session and the next one's 2.65-3.26 / 3.20-7.55.
// Neither value survives session 2 -- see the replication note above -- so the
// default is a documented starting point for retuning, not a validated setting.
//
// thr_q8 is a register so the SoC can retune it over the existing reverse
// channel, the same way lut_parser retunes the flag thresholds.
//=============================================================================
module slide_detect #(
    parameter signed [15:0] CONTACT_THR = 16'sd6000,  // G_s3 above this = contact
    parameter        [15:0] THR_Q8_INIT = 16'd845,    // 3.30 in Q8
    parameter        [15:0] MIN_SAMPLES = 16'd64      // ignore blips (~93 ms)
)(
    input  wire               clk,
    input  wire               rst_n,

    input  wire signed [15:0] raw,        // ch0 converter sample
    input  wire signed [15:0] g1,         // G_s1
    input  wire signed [15:0] fast,       // DoG_fast
    input  wire signed [15:0] g3,         // G_s3
    input  wire               valid,      // one pulse per ch0 result

    input  wire               thr_wr,     // reverse-channel retune
    input  wire        [15:0] thr_data,

    output reg                is_slide,   // last decision
    output reg                decided,    // one-cycle pulse when it updates
    output reg                in_contact,
    // debug taps: accumulator tops latched at the decision
    output reg         [15:0] dbg_hp,
    output reg         [15:0] dbg_fast,
    output reg         [15:0] dbg_n,
    output reg  signed [15:0] dbg_hp_now
);

    reg [15:0] thr_q8;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)      thr_q8 <= THR_Q8_INIT;
        else if (thr_wr) thr_q8 <= thr_data;
    end

    wire contact_now = (g3 > CONTACT_THR);

    // hp = raw - G_s1.  Both are 16-bit signed, so the difference needs 17.
    wire signed [17:0] hp   = $signed({{2{raw[15]}},  raw}) -
                              $signed({{2{g1[15]}},   g1});
    // A signed value multiplied by itself is already non-negative, so no
    // sign-magnitude conversion is needed -- and attempting one is what broke
    // this the first time round.  `~hp + 1'b1` mixes an unsigned 1'b1 into the
    // expression, which demotes the WHOLE ternary to unsigned; negative hp then
    // got squared as an 18-bit unsigned (hp = -53 became 262091), inflating
    // acc_hp by ~20000x and pinning every decision to "slide".  Keep both
    // operands explicitly signed and let the product speak for itself.
    wire signed [35:0] hp2  = $signed(hp)   * $signed(hp);
    wire signed [31:0] fst2 = $signed(fast) * $signed(fast);

    reg [39:0] acc_hp, acc_fast;
    reg [15:0] n_samp;

    // 16-step shift-add: prod = acc_fast * thr_q8
    localparam S_RUN = 2'd0, S_MUL = 2'd1, S_CMP = 2'd2;
    reg [1:0]  st;
    reg [55:0] prod, mcand;
    reg [15:0] mplier;
    reg [4:0]  mcnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_hp <= 40'd0; acc_fast <= 40'd0; n_samp <= 16'd0;
            is_slide <= 1'b0; decided <= 1'b0; in_contact <= 1'b0;
            dbg_hp <= 16'd0; dbg_fast <= 16'd0; dbg_n <= 16'd0; dbg_hp_now <= 16'sd0;
            st <= S_RUN; prod <= 56'd0; mcand <= 56'd0; mplier <= 16'd0; mcnt <= 5'd0;
        end else begin
            decided <= 1'b0;
            if (valid) dbg_hp_now <= hp[15:0];

            case (st)
            S_RUN: begin
                if (valid) begin
                    if (contact_now) begin
                        if (!in_contact) begin          // rising edge: restart
                            acc_hp   <= {4'd0, hp2[35:8]};
                            acc_fast <= {16'd0, fst2[31:8]};
                            n_samp   <= 16'd1;
                        end else begin
                            acc_hp   <= acc_hp   + {4'd0, hp2[35:8]};
                            acc_fast <= acc_fast + {16'd0, fst2[31:8]};
                            n_samp   <= n_samp + 16'd1;
                        end
                        in_contact <= 1'b1;
                    end else if (in_contact) begin      // falling edge: decide
                        in_contact <= 1'b0;
                        if (n_samp >= MIN_SAMPLES) begin
                            prod   <= 56'd0;
                            mcand  <= {16'd0, acc_fast};
                            mplier <= thr_q8;
                            mcnt   <= 5'd0;
                            st     <= S_MUL;
                        end
                    end
                end
            end
            S_MUL: begin
                if (mplier[0]) prod <= prod + mcand;
                mcand  <= mcand << 1;
                mplier <= mplier >> 1;
                mcnt   <= mcnt + 5'd1;
                if (mcnt == 5'd15) st <= S_CMP;
            end
            S_CMP: begin
                // acc_hp * 256 > acc_fast * thr_q8  ->  slide
                is_slide <= ({8'd0, acc_hp, 8'd0} > prod);
                dbg_hp   <= acc_hp[31:16];
                dbg_fast <= acc_fast[31:16];
                dbg_n    <= n_samp;
                decided  <= 1'b1;
                st       <= S_RUN;
            end
            endcase
        end
    end
endmodule
