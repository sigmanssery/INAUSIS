//=============================================================================
// synth_press -- deterministic press train fed straight into the DSP chain,
// bypassing the ADS.
//
// WHY: the 2026-08-28 corpus measured the hand, not the front end.  Sweeps on
// the golden model put the rise-time resolution at about one sample period
// (1.45 ms) while the same operator's rise time varied with sd 43 ms -- a factor
// of 30.  A claim about what the FRONT END resolves therefore cannot be made
// from hand-executed gestures at all.  This generator removes both the hand and
// the sensor: between the stimulus and the frame sits only the shipping logic --
// the real integer MAC, the real >>FRAC and saturation, the real packer.
//
// SHAPE: trapezoid.  The rise is a fixed-step accumulate rather than a divide;
// the per-step increment for each (peak, rise) pair is precomputed below.
//
//   |<-rise->|<--hold-->|<-fall->|<----- gap ----->|
//            ____________
//           /            \
//   _______/              \_______________________   BASE  (+ inter, if any)
//
// PROGRAM: 32 presses, four 8-press phases, one parameter swept per phase.
// Every phase starts at the same reference press and steps away from it by
// 0,1,2,3,5,9,17,33 units, so the resolution limit shows up as the step where
// the measurement stops tracking.  `step` is exported to dim AUX_DIM so the
// host labels each press instead of inferring the order.
//
//   phase 0  sidx  0..7   rise      55..88 samples   (80 ms reference)
//   phase 1  sidx  8..15  hold     124..157 samples  (180 ms reference)
//   phase 2  sidx 16..23  inter      0..320 counts   (the C-vs-G difference)
//   phase 3  sidx 24..31  peak    55 down to 3 (brackets the detection floor)
//
// SUB-UNIT RISE.  `level` carries 4 FRACTIONAL BITS, so phase 3's increment can
// be less than one count per sample.  Without that the smallest reachable peak
// is r_len * 1 = 55 counts, which v10 detected 5/5 -- the floor was an artefact
// of the generator, not of the chain.  d2's synthetic noise sd is about 3, so
// 55 counts is ~18 sigma against a 5 sigma threshold and the real floor has to
// be lower.  The rise DURATION is held at 55 samples throughout; only the
// amplitude falls, so onset shape is not confounded with amplitude.
//
// NOISE: a 32-bit LFSR advanced EIGHT steps per sample, low byte taken as a
// signed value and halved, giving roughly uniform +-64 (sd ~37).
//
// THE EIGHT STEPS ARE LOAD-BEARING.  Advancing only one step per sample -- the
// obvious way to write it -- makes consecutive samples share 6 of the 7 bits
// used, so the sequence is strongly correlated (adjacent autocorrelation -0.247)
// and is NOT white.  It is specifically deficient at low frequency: after G_s3
// (0.2-1.8 Hz) the variance came out 60x too small, 0.15 against the 9.1 that a
// white source of the same amplitude gives.  The calibration window then measured
// a G_s3 variance near zero, thresholds came out far too low, and the first
// detection-floor sweep was invalidated by it.  (An earlier note here blamed a
// "dim2 free-run of 31-57%" on this; that figure was a misattribution -- most of
// it was dim2 correctly firing on phase 2's deliberate inter-press load.  After
// the fix dim2 reads 0% on all twelve zero-load cycles and 100% on the four
// loaded ones, with the measured rise 48/90/170/327 tracking the set 40/80/160/320.)
//
//   steps/sample    raw var    d2 var    d2/raw     adjacent autocorr
//        1           1365.2     0.151    0.00011      -0.247
//        2           1370.5     5.960    0.00435      -0.130
//        8           1366.1     9.092    0.00666      -0.002
//    real sensor     1085.0     4.650    0.00429
//
// The remaining gap to the sensor is not a defect: 30-40% of the real signal's
// power sits in mains harmonics above 60 Hz, which G_s3 rejects, so the real
// ratio is lower than a pure white source gives.  Synthesising mains is not
// wanted, so 0.0066 is the correct target.
//
// A day was lost on 2026-08-29 trying to ADD low-frequency content with a leaky
// integrator, on the assumption that real sensor noise is 1/f.  It is not: the
// measured quiescent spectrum is flat within +-0.4 dB from 0.1 Hz to 30 Hz
// (10 h soak, hour 2, 5 min window).  The synthetic side was the anomaly.
//
// NOISE_EN=0 gives the noiseless ceiling.
//
// SIGNEDNESS: a concatenation is ALWAYS unsigned in Verilog, so $signed() on
// the LFSR slice and on the level part-select are both load-bearing.  Without
// them >>> is a logical shift, the intended -64 becomes +32700 whenever the
// sign bit is set, and the sum past 32767 flips `sample` negative on alternate
// samples.  That bug shipped once and showed up as raw toggling 29800/-3000.
//=============================================================================
module synth_press #(
    parameter signed [15:0] BASE     = 16'sd1790,
    parameter        [15:0] PERIOD   = 16'd1034,   // 1.5 s at 689 Hz
    parameter        [15:0] FALL     = 16'd55,     // 80 ms
    parameter        [15:0] QUIET    = 16'd1400,  // silent lead-in, see below
    parameter               NOISE_EN = 1'b1
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,        // one pulse per sample period
    output reg signed [15:0]  sample,
    output reg        [15:0]  step         // 0..31, which program step this is
);

    reg  [4:0]        sidx;
    wire [1:0]        phase = sidx[4:3];
    wire [2:0]        sub   = sidx[2:0];

    // ---- per-phase parameter tables -------------------------------------
    // Only one parameter moves per phase; the other three sit at the reference.
    localparam [15:0] REF_RISE = 16'd55, REF_HOLD = 16'd124, REF_PEAK = 16'd28000;
    localparam [15:0] REF_INC  = 16'd8144;           // Q4: (REF_PEAK / REF_RISE) << 4

    function [15:0] f_rise(input [1:0] p, input [2:0] s);
        case (p)
        2'd0: case (s)
                3'd0: f_rise=16'd55; 3'd1: f_rise=16'd56; 3'd2: f_rise=16'd57;
                3'd3: f_rise=16'd58; 3'd4: f_rise=16'd60; 3'd5: f_rise=16'd64;
                3'd6: f_rise=16'd72; default: f_rise=16'd88;
              endcase
        default: f_rise = REF_RISE;
        endcase
    endfunction

    function [15:0] f_inc(input [1:0] p, input [2:0] s);
        case (p)
        2'd0: case (s)                                  // peak/rise, peak fixed
                3'd0: f_inc=16'd8144; 3'd1: f_inc=16'd8000; 3'd2: f_inc=16'd7856;
                3'd3: f_inc=16'd7712; 3'd4: f_inc=16'd7456; 3'd5: f_inc=16'd6992;
                3'd6: f_inc=16'd6208; default: f_inc=16'd5088;
              endcase
        // Sub-unit floor bracket, Q4: 16 = 1.0 count/sample, 1 = 0.0625.
        // peak = (REF_RISE * inc) >> 4  ->  55 41 27 20 13 10 6 3
        2'd3: case (s)
                3'd0: f_inc=16'd16;  3'd1: f_inc=16'd12;  3'd2: f_inc=16'd8;
                3'd3: f_inc=16'd6;   3'd4: f_inc=16'd4;   3'd5: f_inc=16'd3;
                3'd6: f_inc=16'd2;   default: f_inc=16'd1;
              endcase
        default: f_inc = REF_INC;
        endcase
    endfunction

    function [15:0] f_hold(input [1:0] p, input [2:0] s);
        case (p)
        2'd1: case (s)
                3'd0: f_hold=16'd124; 3'd1: f_hold=16'd125; 3'd2: f_hold=16'd126;
                3'd3: f_hold=16'd127; 3'd4: f_hold=16'd129; 3'd5: f_hold=16'd133;
                3'd6: f_hold=16'd141; default: f_hold=16'd157;
              endcase
        default: f_hold = REF_HOLD;
        endcase
    endfunction

    function [15:0] f_inter(input [1:0] p, input [2:0] s);
        case (p)
        2'd2: case (s)
                3'd0: f_inter=16'd0;   3'd1: f_inter=16'd5;   3'd2: f_inter=16'd10;
                3'd3: f_inter=16'd20;  3'd4: f_inter=16'd40;  3'd5: f_inter=16'd80;
                3'd6: f_inter=16'd160; default: f_inter=16'd320;
              endcase
        default: f_inter = 16'd0;
        endcase
    endfunction

    function [15:0] f_peak(input [1:0] p, input [2:0] s);
        case (p)
        2'd3: case (s)          // 55 down to 3, brackets the detection floor
                3'd0: f_peak=16'd55;   3'd1: f_peak=16'd41;   3'd2: f_peak=16'd27;
                3'd3: f_peak=16'd20;   3'd4: f_peak=16'd13;   3'd5: f_peak=16'd10;
                3'd6: f_peak=16'd6;    default: f_peak=16'd3;
              endcase
        default: f_peak = REF_PEAK;
        endcase
    endfunction

    wire [15:0] r_len    = f_rise (phase, sub);
    wire [15:0] r_inc    = f_inc  (phase, sub);
    wire [15:0] h_len    = f_hold (phase, sub);
    wire [15:0] inter    = f_inter(phase, sub);
    wire [15:0] peak     = f_peak (phase, sub);
    wire [15:0] hold_end = r_len + h_len;
    wire [15:0] fall_end = hold_end + FALL;

    // QUIET holds the output at BASE for the first 1400 samples (~2 s).
    // zscore_flag_multi calibrates over its first 512 samples ONCE and never
    // again; without this lead-in the first synthetic press (234 samples) lands
    // inside that window, the engine measures a full-scale variance, and every
    // threshold ends up so high that mask never fires again -- observed as
    // mask == 0 across all 110355 frames of the first detection sweep.
    // The same failure mode reaches real hardware: anything touching the sensor
    // within 0.74 s of power-up permanently disables the attention output.
    reg  [15:0]        qcnt;
    reg  [15:0]        pcnt;
    reg  signed [31:0] level;

    // Advance the LFSR eight steps per sample; see the NOISE note above.  Eight
    // steps of a linear recurrence is itself linear, so this is a fixed XOR
    // network, not eight clock cycles.
    reg  [31:0] lfsr;
    reg  [31:0] lnext;
    integer     li;
    always @(*) begin
        lnext = lfsr;
        for (li = 0; li < 8; li = li + 1)
            lnext = {lnext[30:0], lnext[31] ^ lnext[21] ^ lnext[1] ^ lnext[0]};
    end
    wire signed [15:0] noise_raw = $signed({{9{lfsr[7]}}, lfsr[6:0]});
    wire signed [15:0] noise     = NOISE_EN ? (noise_raw >>> 1) : 16'sd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pcnt <= 16'd0; sidx <= 5'd0; level <= 32'sd0; qcnt <= 16'd0;
            sample <= BASE; step <= 16'd0; lfsr <= 32'hACE1_2345;
        end else if (tick) begin
            lfsr <= lnext;
            if (qcnt != QUIET) begin
                qcnt   <= qcnt + 16'd1;
                sample <= BASE + noise;
            end else begin

            // `level` is Q4 throughout; peak / inter are plain counts, so they
            // are shifted up by 4 wherever they meet it.
            if (pcnt < r_len)
                level <= (level + $signed({16'd0, r_inc}) > $signed({12'd0, peak, 4'd0}))
                         ? $signed({12'd0, peak, 4'd0}) : level + $signed({16'd0, r_inc});
            else if (pcnt < hold_end)
                level <= $signed({12'd0, peak, 4'd0});
            else if (pcnt < fall_end)
                level <= (level - $signed({16'd0, REF_INC}) < $signed({12'd0, inter, 4'd0}))
                         ? $signed({12'd0, inter, 4'd0}) : level - $signed({16'd0, REF_INC});
            else
                level <= $signed({12'd0, inter, 4'd0});   // load held between presses

            if (pcnt == PERIOD-1) begin
                pcnt <= 16'd0;
                sidx <= sidx + 5'd1;
                step <= {11'd0, sidx + 5'd1};
            end else begin
                pcnt <= pcnt + 16'd1;
            end

            sample <= BASE + $signed(level[19:4]) + noise;   // Q4 -> counts
            end
        end
    end
endmodule
