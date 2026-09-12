//=============================================================================
// digipot_sweep -- amplitude ladder for the end-to-end detection-floor test.
//
// Replaces the FSR with (bias resistor + eight AD5254 rheostats in series) and
// walks the wiper down and back up, so a known small resistance step travels
// through the REAL analogue path: the divider, the ADS114S08, its noise and its
// quantisation, then the shipping DSP chain.  synth_press could not do this --
// it injects after the converter and its smallest increment is one count per
// sample, which is what produced the 2026-08-30 floor (41 -> 100%, 27 -> 60%,
// 20 -> 0%).  That was the generator's floor, not the chain's.
//
// SUPER-POT.  Two AD5254 give 8 channels of 100 kOhm.  Wired in series they
// form one 800 kOhm / 2048-step rheostat.  Channel i takes
// clamp(code - 256*i, 0, 255), so incrementing the super code by one moves
// exactly one channel by one step: monotonic, and no glitch at the boundaries.
//
// OPERATING POINT (measured, 2026-09-10 rest recording, raw = 1612.1 counts):
//   R_fsr at rest = 100k * (32767/1612.1 - 1) = 1.933 MOhm
//   one wiper step = 100k/256 = 391 Ohm
//   with BIAS = 1.25 MOhm the rest point lands on code 1746 (1612.0 counts),
//   leaving 1746 steps of "press" travel below it and 301 of release above.
//   step size is 0.310 ADC counts at rest and 0.839 at full deflection -- the
//   divider is nonlinear, so counts per step is NOT constant across the range.
//   Calibrate per code by reading the ADC; do not assume a constant.
//
// LADDER (super-code steps -> ADC counts at BIAS = 1.25 MOhm):
//   idx :  0    1    2    3    4    5    6    7    8    9
//   stp :  1    2    3    4    6    9   13   19   27   39
//   cnt :0.31 0.62 0.93 1.24 1.86 2.79 4.04 5.91 8.41 12.2
//   idx : 10   11   12   13   14   15   16   17   18
//   stp : 57   82  119  173  250  363  526  763 1106
//   cnt :17.9 25.8 37.7 55.4 81.4  121  181  277  435
// The 2026-08-30 synthetic floor (about 19-27 counts) sits at idx 10-11, and
// the delay-amplitude points that were previously only synthetic (55 counts,
// 880 counts) are now reachable at idx 13 and above.
//
// ONSET SHAPE.  The rise duration is held at R_LEN frames for every amplitude,
// exactly as synth_press phase 3 does, so onset shape is not confounded with
// amplitude.  The ramp is a fixed-step accumulate (inc = round(amp*256/R_LEN))
// rather than a divide; at the end of the ramp the code is SNAPPED to the exact
// target so the held amplitude is exact regardless of rounding.
//   LIMITATION, state it when reporting: for amp < R_LEN (idx 0..9) the wiper
//   cannot move every frame, so the ramp degenerates into a staircase of `amp`
//   discrete jumps spread over R_LEN frames.  The onset DURATION is still
//   R_LEN, but the fine shape is quantised.  Inherent to stepping a 256-position
//   part; it cannot be designed away at this bias point.
//
// LABELLING.  aux carries {rung_index[4:0], wiper_code[10:0]}.  The live code is
// exported rather than only the index so the host can reconstruct the actual
// amplitude from the frame log instead of trusting this table -- the same rule
// as "tap the intermediate value into a spare dim, do not read it off the
// source" that the slide_detect debug cost a day to learn.
//
// MANUAL MODE.  man_en parks the wiper at man_code and halts the program, for
// bench calibration against the USB meter and for the per-code counts sweep.
//=============================================================================
`default_nettype none

module digipot_sweep #(
    parameter [10:0] REST_CODE = 11'd1746,  // wiper at rest = no press
    parameter [15:0] R_LEN     = 16'd55,    // rise, frames  (80 ms at 689 Hz)
    parameter [15:0] H_LEN     = 16'd124,   // hold, frames  (180 ms)
    parameter [15:0] F_LEN     = 16'd55,    // fall, frames
    parameter [15:0] GAP       = 16'd690,   // quiet gap, frames (~1 s)
    parameter [7:0]  N_REP     = 8'd10      // repeats per amplitude
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,        // one pulse per frame
    input  wire               man_en,      // 1 = park at man_code, halt program
    input  wire [10:0]        man_code,
    output reg  [10:0]        code,        // super-pot code -> digipot_rig
    output reg                code_wr,     // 1-cycle pulse when code changed
    output reg  signed [15:0] aux,         // {rung, code} -> dsp_chain AUX_DIM
    output reg                done
);
    localparam N_AMP = 19;

    function [10:0] amp_of; input [4:0] i; begin
        case (i)
            5'd0:  amp_of = 11'd1;    5'd1:  amp_of = 11'd2;    5'd2:  amp_of = 11'd3;
            5'd3:  amp_of = 11'd4;    5'd4:  amp_of = 11'd6;    5'd5:  amp_of = 11'd9;
            5'd6:  amp_of = 11'd13;   5'd7:  amp_of = 11'd19;   5'd8:  amp_of = 11'd27;
            5'd9:  amp_of = 11'd39;   5'd10: amp_of = 11'd57;   5'd11: amp_of = 11'd82;
            5'd12: amp_of = 11'd119;  5'd13: amp_of = 11'd173;  5'd14: amp_of = 11'd250;
            5'd15: amp_of = 11'd363;  5'd16: amp_of = 11'd526;  5'd17: amp_of = 11'd763;
            5'd18: amp_of = 11'd1106;
            default: amp_of = 11'd0;
        endcase
    end endfunction

    // inc = amp * 256 / R_LEN.  Both operands of the divide are constants at
    // elaboration (a literal and a parameter), so every arm folds to a literal
    // and no divider is inferred -- the reason this was a hand-computed table in
    // the first place.  It was computed for 55 and never re-derived, so R_LEN was
    // not an onset-duration control at all: at R_LEN=8 the ramp covered 14.5% of
    // the amplitude and the end-of-rise snap delivered the other 85.5% in one
    // frame (found 2026-09-12).
    // 19 bits because amp*256 = 283136 at the top rung; at R_LEN=4 the quotient
    // already exceeds 16 bits, and that would have overflowed silently.
    function [18:0] inc_of; input [4:0] i; begin
        case (i)
            5'd0 : inc_of = (32'd1    * 32'd256) / R_LEN;
            5'd1 : inc_of = (32'd2    * 32'd256) / R_LEN;
            5'd2 : inc_of = (32'd3    * 32'd256) / R_LEN;
            5'd3 : inc_of = (32'd4    * 32'd256) / R_LEN;
            5'd4 : inc_of = (32'd6    * 32'd256) / R_LEN;
            5'd5 : inc_of = (32'd9    * 32'd256) / R_LEN;
            5'd6 : inc_of = (32'd13   * 32'd256) / R_LEN;
            5'd7 : inc_of = (32'd19   * 32'd256) / R_LEN;
            5'd8 : inc_of = (32'd27   * 32'd256) / R_LEN;
            5'd9 : inc_of = (32'd39   * 32'd256) / R_LEN;
            5'd10: inc_of = (32'd57   * 32'd256) / R_LEN;
            5'd11: inc_of = (32'd82   * 32'd256) / R_LEN;
            5'd12: inc_of = (32'd119  * 32'd256) / R_LEN;
            5'd13: inc_of = (32'd173  * 32'd256) / R_LEN;
            5'd14: inc_of = (32'd250  * 32'd256) / R_LEN;
            5'd15: inc_of = (32'd363  * 32'd256) / R_LEN;
            5'd16: inc_of = (32'd526  * 32'd256) / R_LEN;
            5'd17: inc_of = (32'd763  * 32'd256) / R_LEN;
            5'd18: inc_of = (32'd1106 * 32'd256) / R_LEN;
            default: inc_of = 19'd0;
        endcase
    end endfunction

    localparam P_RISE = 3'd1, P_HOLD = 3'd2, P_FALL = 3'd3,
               P_GAP  = 3'd4, P_END  = 3'd5;

    reg [2:0]  ph;
    reg [15:0] t;
    reg [4:0]  a_i;
    reg [7:0]  rep;
    reg [23:0] acc;          // 16.8 fixed point; amp*256 needs 19 bits
    reg [10:0] next_code;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph <= P_GAP; t <= 16'd0; a_i <= 5'd0; rep <= 8'd0;
            acc <= 24'd0; code <= REST_CODE; next_code <= REST_CODE;
            code_wr <= 1'b1;               // push the rest code once after reset
            aux <= 16'sd0; done <= 1'b0;
        end else begin
            code_wr <= 1'b0;

            if (man_en) begin
                if (code != man_code) begin code <= man_code; code_wr <= 1'b1; end
                aux <= {5'd31, man_code};  // rung 31 marks manual mode
                ph  <= P_GAP; t <= 16'd0; acc <= 24'd0;
            end else if (tick) begin
                aux <= {a_i, code};
                t   <= t + 16'd1;
                next_code = code;

                case (ph)
                P_GAP: begin
                    next_code = REST_CODE;
                    if (t >= GAP) begin
                        t <= 16'd0; acc <= 24'd0;
                        ph <= (a_i >= N_AMP) ? P_END : P_RISE;
                    end
                end
                P_RISE: begin
                    if (t >= R_LEN) begin
                        next_code = REST_CODE - amp_of(a_i);   // snap: exact hold
                        t <= 16'd0; ph <= P_HOLD;
                    end else begin
                        acc = acc + {5'd0, inc_of(a_i)};
                        next_code = REST_CODE - acc[18:8];
                    end
                end
                P_HOLD: begin
                    next_code = REST_CODE - amp_of(a_i);
                    if (t >= H_LEN) begin t <= 16'd0; acc <= 24'd0; ph <= P_FALL; end
                end
                P_FALL: begin
                    if (t >= F_LEN) begin
                        next_code = REST_CODE;
                        t <= 16'd0; ph <= P_GAP;
                        if (rep + 8'd1 >= N_REP) begin
                            rep <= 8'd0; a_i <= a_i + 5'd1;
                        end else begin
                            rep <= rep + 8'd1;
                        end
                    end else begin
                        acc = acc + {5'd0, inc_of(a_i)};
                        next_code = (acc[18:8] >= amp_of(a_i))
                                  ? REST_CODE
                                  : (REST_CODE - amp_of(a_i) + acc[18:8]);
                    end
                end
                // LOOPING (2026-09-13).  The sweep used to park here forever:
                // N_AMP rungs x N_REP presentations is 12.75 minutes at
                // N_REP=10, so every rung's floor rested on ten repeats and
                // could not be placed any more tightly than ten repeats allow.
                // Restarting at rung 0 costs no new state -- a_i, rep, t, acc
                // and ph all already carry reset and in-flight assignments, so
                // this adds mux inputs to existing registers and no register.
                // `done` stays latched: it means "a full pass has completed",
                // which is still true, rather than "stopped", which no longer
                // is.  Rung N_AMP appears in aux for exactly one tick per pass,
                // which is the cycle boundary an offline drift check needs.
                P_END: begin
                    next_code = REST_CODE; done <= 1'b1;
                    a_i <= 5'd0; rep <= 8'd0; t <= 16'd0; acc <= 24'd0;
                    ph  <= P_GAP;
                end
                default: ph <= P_GAP;
                endcase

                if (next_code != code) begin
                    code    <= next_code;
                    code_wr <= 1'b1;
                end
            end
        end
    end
endmodule

`default_nettype wire
