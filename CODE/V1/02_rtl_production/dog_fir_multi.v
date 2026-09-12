`timescale 1ns/1ps
//=============================================================================
// dog_fir_multi.v
//
// Multi-channel DoG filter: ONE time-multiplexed MAC engine serves N_CH=6
// channels (4 piezoresistive P1-P4 + 2 inductive L, RP), each producing 3
// scales (sigma 2/8/85) -> 18 smoothed streams and the DoG features.
//
// This realizes the paper's "single DSP" claim: timing analysis shows the
// 6 x 3 x 256 = 4608 MACs per 1 ms sample period occupy only ~17% of the
// 27000-clock budget at 27 MHz, leaving ample headroom.
//
// ARCHITECTURE:
//   - N_CH independent 256-sample circular buffers (one per channel)
//   - ONE MAC engine, time-multiplexed: when a channel's new sample arrives
//     it is stored, then the engine sweeps that channel's 3 scales x 256 taps.
//   - Channels are serviced round-robin as samples arrive.
//
// MEMORY / BSRAM (synthesis):
//   The coefficient ROM (coef_rom, 768x16) and the per-channel sample buffer
//   (sbuf, 6x256x16) are read SYNCHRONOUSLY (registered output x_r/c_r) so the
//   tools infer them as block RAM (BSRAM). An earlier combinational read forced
//   them into distributed LUT ROM/RAM, which alone needed >14000 LUT4 and
//   overflowed the GW1NR-9 (8640 LUT4). The synchronous read adds one pipeline
//   stage to the MAC loop (the accumulate of tap k uses the read issued at
//   k-1); the loop runs N_TAPS+1 cycles and accumulates exactly taps 0..255, so
//   the DoG result is bit-identical to the combinational-read version.
//
// FIXED-POINT (from fixed_point_analysis.py):
//   input signed 16-bit, Q15 coeffs, 39-bit accumulator, output 16-bit.
//   Verified bit-exact (single channel) against the Python golden model.
//
// HANDSHAKE:
//   assert sample_valid with ch_id + sample_in for the channel that has a new
//   sample. When that channel's 3 scales are done, result_valid pulses with
//   ch_done = ch_id, and the G/DoG outputs for that channel are on the buses.
//=============================================================================

module dog_fir_multi #(
    parameter N_CH     = 6,     // channels: P1-4, L, RP
    parameter CH_BITS  = 3,     // ceil(log2(N_CH))
    parameter N_TAPS   = 256,
    parameter ADDR_BITS= 8,
    parameter FRAC     = 15,
    // Extra fractional bits kept on the FLAG-ENGINE copy of the outputs, per
    // channel.  The frame copy is unaffected: see the two output sets below.
    //
    // A 256-tap Gaussian at sigma=85 averages the input noise down by ~sqrt(85),
    // so on a quiet channel the result is a fraction of one count -- and
    // `acc >>> FRAC` then rounds the whole thing to zero.  Measured 2026-09-04 on
    // the real FSR (raw sd 5.00, 10 s with nothing touching it), recomputing the
    // same kernels in floating point:
    //
    //     dim  mode  true sigma  after integer truncation  threshold now / ideal
    //     d0   ROC     2.1721            2.2163              11.08 / 10.86  1.0x
    //     d1   ROC     0.2039            0.1801               5.00 /  1.02  4.9x
    //     d2   ABS     0.0726            0.0000               5.00 /  0.36 13.8x
    //
    // d0 loses nothing: its output is already well above one count.  d1 and d2
    // are both pinned to the THR_MIN floor because their variance estimate
    // rounds to zero, and d2 is additionally reported dead.  The information is
    // in the accumulator; only the output word is too coarse to carry it.
    //
    // The shift is PER CHANNEL because the two sensors differ by ~600x at rest
    // (piezoresistive sigma 0.5-0.8 counts, inductive 212-501), so one scaling
    // cannot serve both: 4 extra bits on the inductive channels would clip them
    // continuously.  ch0-3 are the piezoresistive corners, ch4-5 the inductive
    // pair.  A better long-term answer is to normalise per calibration epoch
    // (block floating point) so nothing is hand-set, but the exponent must then
    // be frozen for the epoch -- a scale change mid-epoch corrupts the ROC
    // difference x[n]-x[n-ROC_K] and silently invalidates the stored threshold.
    // 2^4, not 2^6.  The finer scale bought nothing: d1's true sigma is 0.11
    // counts, so its 5-sigma threshold is 0.53, already above the 0.31 floor
    // that 2^4 implies -- both scales leave it adaptive.  What 2^6 did cost is
    // headroom: d1 peaks near 22,000 counts on a press and saturates at 512
    // instead of 2048, so through the middle of a transient BOTH ROC operands
    // pin at 32767 and x[n]-x[n-10] reads zero.  Measured 2026-09-05: the mask
    // appeared only while the signal crossed the saturation band, and the
    // shorter assertion looked like an improvement when it was lost data.
    parameter [2:0] FB_CH0 = 3'd4,
    // Extra right-shift applied to G_s3's fine copy only; see the DONE state.
    // Zero now that FB_CH0 is 4: G_s3's resting DC (about 1613 counts) needs the
    // scale kept at or below 2^4, which the common scale already satisfies.
    parameter [2:0] G3_TRIM = 3'd0,
    parameter [2:0] FB_CH4 = 3'd0
)(
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire [CH_BITS-1:0]   ch_id,         // which channel this sample is
    input  wire signed [15:0]   sample_in,
    input  wire                 sample_valid,

    output reg  [CH_BITS-1:0]   ch_done,       // channel whose result is ready
    output reg  signed [15:0]   G_s1,
    output reg  signed [15:0]   G_s2,
    output reg  signed [15:0]   G_s3,
    output reg  signed [15:0]   DoG_fast,
    output reg  signed [15:0]   DoG_slow,
    // Same three features the flag engine consumes, but scaled up by FB_CH*
    // bits so a sub-count result survives.  They saturate far earlier (2047
    // counts at 4 bits) and that is deliberate: the thresholds they are compared
    // against are 0.36-11 counts, so saturation sits 160-5500x above any
    // decision.  Everything that reports a MAGNITUDE -- the UART frame and
    // slide_detect -- stays on the unscaled outputs above.
    output reg  signed [15:0]   G_s3_f,
    output reg  signed [15:0]   DoG_fast_f,
    output reg  signed [15:0]   DoG_slow_f,
    output reg                  result_valid,

    output reg                  busy           // high while MAC engine running
);

    //=========================================================================
    // Coefficient ROM (Q15), shared by all channels.
    // Layout: [sigma2 0..255][sigma8 256..511][sigma85 512..767]
    //=========================================================================
    (* syn_ramstyle = "block_ram" *)
    reg signed [15:0] coef_rom [0:3*N_TAPS-1];
    initial $readmemh("dog_coeffs.mem", coef_rom);

    //=========================================================================
    // Per-channel circular sample buffers: N_CH x 256 samples.
    // Flattened into one 2D reg array. head[ch] = newest index for channel ch.
    //=========================================================================
    // sbuf must infer as BSRAM: registered read (x_r) + NO async reset (BSRAM
    // has no per-cell reset). Power-up contents are zeroed via `initial` (also
    // gives the golden-model zero-padding during the first <256 startup
    // samples, which all precede the 512-sample calibration window).
    (* syn_ramstyle = "block_ram" *)
    reg signed [15:0]   sbuf [0:N_CH*N_TAPS-1];   // sbuf[ch*256 + idx]
    reg [ADDR_BITS-1:0] head [0:N_CH-1];
    integer jinit;
    initial for (jinit=0; jinit<N_CH*N_TAPS; jinit=jinit+1) sbuf[jinit] = 16'sd0;

    //=========================================================================
    // MAC engine state
    //=========================================================================
    localparam IDLE=2'd0, RUN=2'd1, SDONE=2'd2, DONE=2'd3;
    reg [1:0]            state;
    reg [CH_BITS-1:0]    cur_ch;        // channel being processed
    reg [1:0]            scale;         // 0=s2,1=s8,2=s85
    reg [ADDR_BITS:0]    tap;           // 0..N_TAPS (one extra to drain pipeline)
    // Saturate rather than truncate on the way down to 16 bits. Two places can
    // overflow. The accumulator shift: a kernel whose Q15 coefficients sum to
    // slightly over unity turns a full-scale input into a value just past
    // 32767, and truncation wraps it to negative full scale -- observed on
    // hardware 2026-08-27, where a sustained press pinned G(sigma3) at -32763
    // while the mask stayed asserted, i.e. the reported grip level inverted.
    // And the difference: G1 - G2 of two 16-bit values needs 17 bits, so a
    // steep enough edge overflows even with exactly-normalised coefficients.
    function signed [15:0] sat16;
        input signed [38:0] v;
        begin
            if      (v >  39'sd32767) sat16 = 16'sh7FFF;
            else if (v < -39'sd32768) sat16 = 16'sh8000;
            else                      sat16 = v[15:0];
        end
    endfunction

    reg signed [38:0]    acc;
    reg signed [15:0]    g_result [0:2];
    // The fine copies are kept UNSATURATED and full width.  Saturating each
    // Gaussian before the DoG subtraction is what broke v24: during a press both
    // operands pinned at 32767 and G1-G2 collapsed to zero, taking d0's latency
    // from 2.90 ms to 108.79 ms.  Subtracting first and saturating once keeps
    // the transient, because the DIFFERENCE is what has to survive, not the
    // terms.  30 bits covers the widest case (shift of 9 on a 39-bit acc).
    reg signed [29:0]    g_wide   [0:2];
    wire [2:0] fbits = (cur_ch <= 3) ? FB_CH0 : FB_CH4;

    // address helpers. tap is clamped to N_TAPS-1 for the single drain cycle
    // (tap==N_TAPS) so neither RAM is ever addressed out of range; that cycle's
    // read result is unused (we only accumulate the product already registered).
    wire [ADDR_BITS-1:0] tap_a    = (tap < N_TAPS) ? tap[ADDR_BITS-1:0]
                                                   : (N_TAPS-1);
    wire [ADDR_BITS-1:0] buf_local= head[cur_ch] - tap_a;       // within-channel idx
    wire [15:0]          buf_flat = cur_ch*N_TAPS + buf_local;  // flattened idx
    wire [9:0]           coef_idx = {scale, 8'd0} + tap_a;      // scale*256 + tap

    // SYNCHRONOUS reads -> BSRAM. x_r/c_r hold the data for the address issued
    // on the PREVIOUS cycle.
    reg signed [15:0] x_r, c_r;
    always @(posedge clk) begin
        x_r <= sbuf[buf_flat];
        c_r <= coef_rom[coef_idx];
    end
    wire signed [31:0] product = x_r * c_r;       // single 16x16 multiply -> 1 DSP

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state        <= IDLE;
            cur_ch       <= 0;
            scale        <= 2'd0;
            tap          <= 0;
            acc          <= 39'sd0;
            result_valid <= 1'b0;
            busy         <= 1'b0;
            ch_done      <= 0;
            G_s1<=0; G_s2<=0; G_s3<=0; DoG_fast<=0; DoG_slow<=0;
            G_s3_f<=0; DoG_fast_f<=0; DoG_slow_f<=0;
            for (i=0;i<3;i=i+1) g_wide[i] <= 30'sd0;
            for (i=0;i<N_CH;i=i+1) head[i] <= 0;
            // NOTE: sbuf is intentionally NOT reset here (see its declaration);
            // resetting it would prevent BSRAM inference.
        end else begin
            result_valid <= 1'b0;

            case (state)
            //-----------------------------------------------------------------
            IDLE: begin
                busy <= 1'b0;
                if (sample_valid) begin
                    // store new sample into this channel's buffer
                    head[ch_id] <= head[ch_id] + 1'b1;
                    sbuf[ch_id*N_TAPS + ((head[ch_id]+1'b1) & (N_TAPS-1))] <= sample_in;
                    cur_ch <= ch_id;
                    scale  <= 2'd0;
                    tap    <= 0;
                    acc    <= 39'sd0;
                    busy   <= 1'b1;
                    state  <= RUN;
                end
            end
            //-----------------------------------------------------------------
            // RUN: pipelined MAC. The synchronous read issued when the counter
            // was (tap-1) lands in x_r/c_r this cycle, so we accumulate that
            // product once tap >= 1. Addresses are issued for tap = 0..N_TAPS-1;
            // the tap == N_TAPS cycle accumulates the final (tap=255) product.
            RUN: begin
                if (tap != 0)
                    acc <= acc + {{7{product[31]}}, product};
                if (tap == N_TAPS) state <= SDONE;   // last product added this cycle
                else               tap   <= tap + 1'b1;
            end
            //-----------------------------------------------------------------
            // SDONE: acc now holds the full 256-tap sum for this scale.
            SDONE: begin
                g_result[scale] <= sat16(acc >>> FRAC);
                g_wide[scale]   <= acc >>> (FRAC - fbits);
                acc <= 39'sd0;
                tap <= 0;
                if (scale == 2'd2) state <= DONE;
                else begin
                    scale <= scale + 1'b1;
                    state <= RUN;
                end
            end
            //-----------------------------------------------------------------
            DONE: begin
                G_s1     <= g_result[0];
                G_s2     <= g_result[1];
                G_s3     <= g_result[2];
                DoG_fast <= sat16($signed({{23{g_result[0][15]}}, g_result[0]})
                                - $signed({{23{g_result[1][15]}}, g_result[1]}));
                DoG_slow <= sat16($signed({{23{g_result[1][15]}}, g_result[1]})
                                - $signed({{23{g_result[2][15]}}, g_result[2]}));
                // Subtract at full width, saturate once.  See g_wide above.
                //
                // G_s3 is the only band that carries DC -- it IS the baseline,
                // about 1613 counts on this sensor -- so its scale is bounded by
                // the resting level, not by the transient.  At the g_wide scale
                // of 2^6 that is 103,232 and sat16 pins it at 32767 both at rest
                // and under a press, leaving x - mu identically zero: measured
                // 2026-09-05, d2 fired on 0 of 71 presses while d0/d1 were
                // untouched at 71/71.  Shifting it back down by G3_TRIM gives
                // 2^4, where 1613*16 = 25,808 still fits.  The difference bands
                // are band-pass and carry no DC, so they keep the full scale.
                //
                // The subtractions below must use ONE scale, so the trim is
                // applied only to this output, not to g_wide itself.
                G_s3_f     <= sat16({{9{g_wide[2][29]}}, g_wide[2]} >>> G3_TRIM);
                DoG_fast_f <= sat16($signed({{9{g_wide[0][29]}}, g_wide[0]})
                                  - $signed({{9{g_wide[1][29]}}, g_wide[1]}));
                DoG_slow_f <= sat16($signed({{9{g_wide[1][29]}}, g_wide[1]})
                                  - $signed({{9{g_wide[2][29]}}, g_wide[2]}));
                ch_done  <= cur_ch;
                result_valid <= 1'b1;
                state    <= IDLE;
            end
            endcase
        end
    end

endmodule
