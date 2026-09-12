`timescale 1ns/1ps
//=============================================================================
// zscore_flag_multi.v   (3-stage pipelined)
//
// Time-multiplexed significance-flag engine for all N_DIM=18 dimensions
// (6 channels x 3 scales). Per-dimension state in RAM (addressed by dim_id);
// one shared multiplier. The dim_id->result datapath is PIPELINED into three
// stages so it closes timing at 27 MHz on GW1NR-9 (the single-cycle version
// had a ~51 ns / 23-logic-level path: RAM read -> subtract -> multiply ->
// compare -> state update, limiting Fmax to ~19.5 MHz):
//
//   S1  latch inputs + read the per-dim state RAMs into registers
//   S2  compute cmp_val, select the squaring operand, do the (shared) multiply,
//       and register the product
//   S3  compare / variance, then write the per-dim state back and post outputs
//
// LATENCY: outputs (flag_out/flag_dim/flag_valid, mask, dead) and state writes
// land 3 cycles after `valid`, instead of 1. This is safe because mask/dead are
// sampled by frame_packer well after the chain goes idle, and flag_out is
// observability only. The computed VALUES are bit-identical to the single-cycle
// version.
//
// HAZARDS: consecutive `valid` cycles always carry DISTINCT dims (dsp_chain
// feeds ch*3+0,1,2), and any given dim reappears only one full sample period
// (~hundreds of cycles) later, so the (up to 3) in-flight pipeline entries are
// always different dims -- no read-after-write forwarding is needed.
//
// CALIBRATION / flag math unchanged (bit-exact):
//   flag <=> cmp_val^2 > N^2*variance ; var = (N*sumsq - sum^2)/N^2
//   cmp_val = x - mu (ABS) or x[n]-x[n-ROC_K] (ROC)
//=============================================================================

module zscore_flag_multi #(
    parameter N_DIM   = 18,
    parameter DIM_BITS= 5,
    parameter CAL_N   = 512,
    parameter CAL_SH  = 9,
    // Threshold is N_SQ * variance, i.e. sqrt(N_SQ) sigma.  9 put it at 3 sigma,
    // which for ch0's G_s3 lands right on the quiescent peaks: that dim's rest
    // excursions span 11-14 counts against a 3-sigma threshold of ~6.3, so the
    // rest false-trigger rate is a steep tail probability and swung from 0.00%
    // to 16.94% across five power-ups (correlation with the capture's
    // peak-to-peak range r = +0.89; with baseline drift only -0.27).
    // 25 moves it to 5 sigma.  The cost is negligible here because the measured
    // detection floor is 440-880 counts -- two orders of magnitude above the
    // 6-count noise peaks -- so the floor is set by the DoG dynamics, not by
    // this threshold.
    parameter N_SQ    = 25,
    parameter ROC_K   = 10,
    parameter DEB     = 3,
    // "dead" means the channel is frozen, i.e. EXACTLY zero variance.  A constant
    // sequence gives N*sumsq - sum^2 == 0 exactly in integer arithmetic, and the
    // frozen dims measure exactly 0.0000 on hardware, while the quietest live dim
    // (ch0's G_s3, low-passed to 1.8 Hz) sits at 3.3-4.2.  VAR_FLOOR was once 1 and
    // is now 0; read that history against the scale in force at the time, which the
    // next paragraph sets out -- the comparison is against cal_var16, not cal_var.
    // The deadness test runs on cal_var16 = floor(16*sigma^2), NOT on the integer
    // cal_var, so a dim is called frozen only below sigma^2 = 1/16.  That is a 16x
    // improvement introduced with the fractional variance in v5 (2026-08-29); the
    // paragraph that used to stand here described the pre-v5 behaviour, where the
    // test ran on floor(sigma^2) and anything quieter than 1 count^2 was
    // indistinguishable from frozen.  The synthetic white-noise case cited there --
    // G_s3's variance falling to 0.1 and the dim wrongly marked dead -- no longer
    // applies: 16*0.1 floors to 1, which is above VAR_FLOOR.
    //
    // VERIFIED 2026-09-03: L measured sd 13.0 counts over 42 distinct values with the
    // inductive board attached, and is NOT marked dead -- the fractional variance does
    // rescue it.  The paragraph below still holds for anything quieter.
    //
    // STILL A MITIGATION, NOT A CURE.  The floor has moved, not gone: a live dim
    // below sigma^2 = 1/16 is still indistinguishable from frozen.  Detecting
    // deadness from whether the raw input ever changes -- rather than from the
    // filtered variance -- remains the principled fix.
    //
    // WHERE THIS MATTERED: the inductive L channel was reported quantisation-limited
    // (variance rounding to integer zero, no z-score formable) on a build predating
    // v5.  That report is now historical -- see the verification note above.  It is
    // recorded here because it is the only case so far where this floor decided
    // whether a real channel was usable, and the next such case will look the same:
    // a dimension reported dead while its raw input is visibly moving.
    parameter VAR_FLOOR = 0,
    // VAR_MIN16 is the smallest variance the threshold may be built from, in
    // cal_var16 units (16*sigma^2).  16 is a sigma floor of one LSB, giving
    // THR_MIN = N_SQ*1 = 25 counts^2, i.e. the threshold can never fall below 5
    // counts however quiet the estimate goes.
    //
    // It is applied to the THRESHOLD, not to either variance, because the two
    // estimators do not share units: the one-shot path carries 16*sigma^2 and
    // the rolling path carries sigma^2 directly (new_var = w_sum_n >> CAL_SH).
    // Flooring one variance leaves the other free to overwrite the threshold on
    // the next accepted window -- measured: flooring only the one-shot path left
    // the false-trigger rate unchanged at 34%, because the rolling path rewrites
    // threshold[] every CAL_N samples.
    //
    // Needed because the front end became quantisation-limited on 2026-09-04,
    // when powering down an always-on internal reference in the ADS cut its
    // noise 13x: d0/d1 then took only five distinct values (-2..+2) and the
    // per-window variance ranged 0.16-0.72.  A window landing on the quiet end
    // gives cal_var16 = 2 and a threshold of 3.125, which the channel's own
    // +-2 quantisation steps clear -- measured 9514 false triggers in 19180
    // frames, against 0 before the noise dropped.  The failure is not that the
    // channel got worse; it is that 5 sigma of a sub-LSB sigma is smaller than
    // one LSB, so the threshold stops meaning anything.
    //
    // The floor is on the THRESHOLD path only.  cal_dead still tests the raw
    // cal_var16, so a genuinely dead channel is still marked dead rather than
    // being given a floored variance and treated as live.
    //
    // Chosen as one LSB because the quantisation-only sigma measured on this
    // data is 0.4-0.85 LSB, so a 5-count threshold keeps ~5.9 sigma of margin
    // against quantisation alone while costing far less sensitivity than the
    // noise reduction bought: the effective threshold on dim0 goes from 39.8
    // counts (noisy reference, cal_var 63.4) to 5.0, an 8x improvement.
    //
    // A per-band epsilon on sigma was validated in 2026-07 for the same class of
    // fault and is NOT what is used here: that analysis assumed the comparison
    // was |f| > N*sigma, where epsilon is one adder.  This engine compares in
    // the SQUARED domain (f^2 > N_SQ*sigma^2), where (sigma+eps)^2 needs a
    // square root and a variance floor is a compare and a mux.  The validated
    // value of 0.3 also does not transfer: it was fitted to an LDC channel whose
    // sigma collapsed to 0.01-0.05, one to two orders below this one.
    // VAR_CEIL applies to dims 12-17 (the inductive channels, unscaled).  Dims
    // 0-11 carry FB_CH0 extra fractional bits from dog_fir_multi, so their
    // variance arrives 2^(2*FB_CH0) = 256x larger and the same numeric ceiling
    // would reject any window whose sigma exceeded 8.8 counts instead of 141 --
    // tight enough to risk the endless-retry failure the inductive dims showed
    // on 2026-09-04, where every window was rejected and the dim never
    // calibrated.  VAR_CEIL_F carries the same REAL-WORLD ceiling at the finer
    // scale.  THR_MIN needs no such split: at the fine scale it floors sigma at
    // 1/16 count (threshold 0.31) and at the coarse scale at 1 count
    // (threshold 5.0), and both sit just below the measured sigma of the dims
    // they guard.
    parameter signed [39:0] VAR_CEIL_F = 40'sd5120000,   // 20000 * 16^2
    parameter VAR_MIN16 = 16,
    // Upper bound on a plausible quiescent variance.  Calibration runs ONCE over
    // the first CAL_N samples and never repeats, so anything touching the sensor
    // during that window sets thresholds that nothing can afterwards exceed --
    // the attention output then stays silent forever and does not self-recover.
    // Seen twice on 2026-08-28: mask == 0 across all 110355 frames of a synthetic
    // sweep whose first press landed inside the window, and (via the same
    // calibrate-once weakness) an all-dead map when the converter was still
    // asleep at cold start.
    // Measured basis: hands-off quiescent variance is d0 50 / d1 23 / d2 5;
    // a finger resting without force gives d0 1263; an actual press gives
    // d0 5.35e6.  20000 sits 400x above the first and 267x below the last.
    parameter VAR_CEIL  = 20000
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire [DIM_BITS-1:0]  dim_id,
    input  wire signed [15:0]   x_in,
    input  wire                 valid,
    input  wire                 mode_roc,

    input  wire                 lut_wr,
    input  wire [DIM_BITS-1:0]  lut_dim,
    input  wire [31:0]          lut_thr,     // 32-bit squared-domain threshold

    output reg  [DIM_BITS-1:0]  flag_dim,
    output reg                  flag_out,
    output reg                  flag_valid,
    output reg  [N_DIM-1:0]     mask,
    output wire [N_DIM-1:0]     mask_failsafe,
    output reg  [N_DIM-1:0]     dead,
    output wire [N_DIM-1:0]     uncal,       // 1 = still calibrating / retrying
    // Bring-up observability: window-calibration internals for one LIVE dim and
    // one DEAD dim, routed to spare frame dims by dsp_chain.  Reading the code
    // failed four times on this bug; the project's own rule is to route the
    // intermediate onto a spare dim and look at it.
    output wire [15:0]          dbg_wcnt_live,
    output wire [15:0]          dbg_acnt_live,
    output wire [15:0]          dbg_wcnt_dead,
    output wire [15:0]          dbg_acnt_dead
);
    //=========================================================================
    // Per-dim WIDE state in RAM (read in S1, written in S3; no async reset)
    //=========================================================================
    (* syn_ramstyle = "distributed_ram" *) reg signed [25:0] cal_sum   [0:N_DIM-1];
    (* syn_ramstyle = "distributed_ram" *) reg        [39:0] cal_sumsq [0:N_DIM-1];
    (* syn_ramstyle = "distributed_ram" *) reg signed [39:0] threshold [0:N_DIM-1];
    (* syn_ramstyle = "distributed_ram" *) reg signed [15:0] mu        [0:N_DIM-1];
    (* syn_ramstyle = "distributed_ram" *) reg signed [15:0] roc_mem   [0:N_DIM*ROC_K-1];

    // Narrow control state in registers
    reg [9:0]  cal_cnt    [0:N_DIM-1];
    reg        calibrated [0:N_DIM-1];
    reg [7:0]  deb_cnt    [0:N_DIM-1];
    reg [3:0]  wp         [0:N_DIM-1];

    integer i;

    //=========================================================================
    // Stage 1 registers : inputs + state RAM reads
    //=========================================================================
    reg                 s1_valid, s1_mode;
    reg [DIM_BITS-1:0]  s1_dim;
    reg signed [15:0]   s1_x, s1_mu, s1_xdly;
    reg signed [25:0]   s1_sum;
    reg        [39:0]   s1_sumsq;
    reg signed [39:0]   s1_thr;
    reg [43:0]          s1_racc, s1_wsum;
    reg [9:0]           s1_wcnt;
    reg [3:0]           s1_rej;
    reg [11:0]          s1_gst;
    reg                 s1_cal;
    reg [9:0]           s1_cnt;
    reg [7:0]           s1_deb;

    wire [8:0] roc_addr = dim_id*ROC_K + wp[dim_id];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s1_valid<=1'b0; s1_mode<=1'b0; s1_dim<=0;
            s1_x<=0; s1_mu<=0; s1_xdly<=0; s1_sum<=0; s1_sumsq<=0; s1_thr<=0;
            s1_cal<=1'b0; s1_cnt<=0; s1_deb<=0;
            for (i=0;i<N_DIM;i=i+1) wp[i] <= 4'd0;
        end else begin
            s1_valid <= valid;
            if (valid) begin
                s1_dim   <= dim_id;
                s1_x     <= x_in;
                s1_mode  <= mode_roc;
                s1_thr   <= threshold[dim_id];
                s1_racc  <= ref_acc[dim_id];
                s1_wsum  <= win_sum[dim_id];
                s1_wcnt  <= win_cnt[dim_id];
                s1_rej   <= rej_cnt[dim_id];
                s1_gst   <= gstall_cnt[dim_id];
                s1_sum   <= cal_sum[dim_id];
                s1_sumsq <= cal_sumsq[dim_id];
                s1_mu    <= mu[dim_id];
                s1_xdly  <= roc_mem[roc_addr];
                s1_cal   <= calibrated[dim_id];
                s1_cnt   <= cal_cnt[dim_id];
                s1_deb   <= deb_cnt[dim_id];
                // ROC circular buffer: read old (above) then overwrite, advance wp
                roc_mem[roc_addr] <= x_in;
                wp[dim_id] <= (wp[dim_id]==ROC_K-1) ? 4'd0 : wp[dim_id]+4'd1;
            end
        end
    end

    //=========================================================================
    // Stage 2 : cmp_val, operand select, shared multiply (registered product)
    //=========================================================================
    wire signed [16:0] s1_cmp = s1_mode
        ? ($signed({s1_x[15],s1_x}) - $signed({s1_xdly[15],s1_xdly}))
        : ($signed({s1_x[15],s1_x}) - $signed({s1_mu[15],s1_mu}));

    wire s1_do_accum = s1_valid && !s1_cal && (s1_cnt <  CAL_N);
    wire s1_do_final = s1_valid && !s1_cal && (s1_cnt == CAL_N);
    wire s1_do_run   = s1_valid &&  s1_cal;

    // shared multiplier operand: finalize->sum, accumulate->x, runtime->cmp
    reg signed [25:0] sq_op;
    always @(*) begin
        if      (s1_do_final) sq_op = s1_sum;
        else if (s1_do_accum) sq_op = $signed(s1_x);
        else                  sq_op = $signed(s1_cmp);
    end
    wire signed [51:0] sq_p = sq_op * sq_op;     // 26x26 -> 2 DSP

    reg                 s2_valid, s2_accum, s2_final, s2_run, s2_first;
    reg                 s2_mode;          // 1 = ROC, 0 = ABS (for the rolling mean)
    reg signed [15:0]   s2_mu_r;          // this dim's mean, carried for rolling
    reg [DIM_BITS-1:0]  s2_dim;
    reg signed [15:0]   s2_x;
    reg signed [25:0]   s2_sum;
    reg        [39:0]   s2_sumsq;
    reg signed [39:0]   s2_thr;
    reg [43:0]          s2_racc, s2_wsum;
    reg [9:0]           s2_wcnt;
    reg [3:0]           s2_rej;
    reg [11:0]          s2_gst;
    reg        [7:0]    s2_deb;
    reg [9:0]           s2_cnt;
    reg signed [51:0]   s2_sqp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid<=0; s2_accum<=0; s2_final<=0; s2_run<=0; s2_first<=0;
            s2_dim<=0; s2_x<=0; s2_sum<=0; s2_sumsq<=0; s2_thr<=0; s2_deb<=0;
            s2_cnt<=0; s2_sqp<=0;
        end else begin
            s2_valid <= s1_valid;
            s2_accum <= s1_do_accum;
            s2_final <= s1_do_final;
            s2_run   <= s1_do_run;
            s2_first <= (s1_cnt == 10'd0);
            s2_mode  <= s1_mode;
            s2_mu_r  <= s1_mu;
            s2_dim   <= s1_dim;
            s2_x     <= s1_x;
            s2_sum   <= s1_sum;
            s2_sumsq <= s1_sumsq;
            s2_thr   <= s1_thr;
            s2_racc  <= s1_racc;
            s2_wsum  <= s1_wsum;
            s2_wcnt  <= s1_wcnt;
            s2_rej   <= s1_rej;
            s2_gst   <= s1_gst;
            s2_deb   <= s1_deb;
            s2_cnt   <= s1_cnt;
            s2_sqp   <= sq_p;
        end
    end

    //=========================================================================
    // Stage 3 : compare / variance, write per-dim state back, post outputs
    //=========================================================================
    wire signed [34:0] cmp_sq   = $signed({1'b0, s2_sqp[33:0]});  // cmp_val^2 (runtime)
    wire [39:0]        x_sq_u   = s2_sqp[39:0];                   // x^2 (accumulate)
    wire over_thr = (cmp_sq > s2_thr);

    // variance (finalize): (N*sumsq - sum^2)/N^2 ; sum^2 = s2_sqp here
    wire signed [55:0] cal_num  = ($signed({16'd0, s2_sumsq}) <<< CAL_SH) - s2_sqp;
    // Keep 4 fractional bits.  cal_var used to be floor(sigma^2), and for a
    // heavily low-passed dim such as ch0's G_s3 -- quiescent sigma^2 of only
    // 3.4-6.2 -- that quantised the threshold (N_SQ * cal_var) to 27/36/45/54.
    // One count of boot-to-boot difference in the calibration window then moved
    // it by 20-30%, and the rest false-trigger rate on dim2 swung from 0.0% to
    // 15.8% across boots.  cal_var16 = 16*sigma^2 cuts that quantisation to
    // 1/16 count^2; the >>>4 puts the threshold back into counts^2 so the
    // SoC-written lut_thr keeps its existing units.
    wire signed [39:0] cal_var16 = cal_num >>> (2*CAL_SH - 4);
    wire signed [39:0] cal_var   = cal_var16 >>> 4;
    wire               cal_dead = (cal_var16 <= $signed(VAR_FLOOR));
    localparam signed [39:0] VAR_CEIL_C = VAR_CEIL;
    // Only the G_s3 dims of the piezoresistive channels (ch*3+2 for ch0-3) carry
    // the finer scale, so only they need the matching ceiling.  The DoG
    // difference dims were reverted to the original scale -- see dsp_chain's
    // F_FAST comment.
    // All three bands of the piezoresistive channels now carry the finer scale
    // (dims 0-11); dims 12-17 are the inductive pair and stay unscaled.
    // Two fine scales now: the difference bands run at 2^6 and G_s3 at 2^4,
    // because only G_s3 carries DC (see dog_fir_multi's G3_TRIM).  Variance
    // scales with the square of the scale, so the ceiling has to follow.
    wire s2_g3   = (s2_dim == 5'd2) || (s2_dim == 5'd5)
                || (s2_dim == 5'd8) || (s2_dim == 5'd11);
    wire s2_fine = (s2_dim < 5'd12) && !s2_g3;
    // One fine scale again (2^4) now that FB_CH0 is 4 and G3_TRIM is 0, so the
    // G_s3 split is gone; dims 0-11 share VAR_CEIL_F, 12-17 stay unscaled.
    wire signed [39:0] ceil_eff = (s2_fine || s2_g3) ? VAR_CEIL_F : VAR_CEIL_C;
    wire               cal_hot  = (cal_var   >  ceil_eff);

    // Strength-reduced constant multiply.  N_SQ is a compile-time constant, so
    // N_SQ * cal_var16 is a sum of shifts and needs no multiplier at all -- but
    // written as `*` the synthesiser inferred a 40x5 multiplier.  That cost ~3
    // of the device's 10 DSP macro units, on top of the 2 the squarer takes,
    // and DSP was the binding resource at 7.5/10.  Raising N_SQ from 9 to 25
    // (3 sigma -> 5 sigma) widened the constant from 4 bits to 5 and is what
    // pushed the inferred multiplier over a macro boundary.
    //
    // The loop is unrolled at elaboration: one shifted term per set bit of
    // N_SQ, so this stays correct if N_SQ is changed.  Arithmetic is 40-bit
    // throughout, exactly as the `*` form was after assignment to cal_thr, so
    // the result is bit-identical.
    localparam [7:0] N_SQ_V = N_SQ;
    reg signed [39:0] thr_mul;
    integer nb;
    always @(*) begin
        thr_mul = 40'sd0;
        for (nb = 0; nb < 8; nb = nb + 1)
            if (N_SQ_V[nb]) thr_mul = thr_mul + (cal_var16 <<< nb);
    end

    // A dead dim used to be given a threshold of ZERO.  That reads as "harmless"
    // and is the opposite: zero means the test is cmp_val^2 > 0, so the dim fires
    // on ANY departure from its mean at all.  It looked safe only because a dead
    // dim is usually constant, which makes cmp_val exactly 0 and the comparison
    // false -- the moment the channel moves by one count it asserts with no
    // threshold behind it.
    //
    // Measured 2026-09-04 on the real sensor: at true rest the sustained band
    // (dim2, G_s3, ~909 ms of smoothing on a raw sd of 1.97 counts) collapses to
    // a SINGLE value, so cal_var16 = 0 and it is marked dead.  It then "detected"
    // 10 of 10 presses with a 4.34 ms median -- but that was not a 5 sigma
    // decision, it was "something changed", debounced three samples.  A dim that
    // is quiet because it is heavily low-passed is indistinguishable here from
    // one that is quiet because nothing is connected, and neither should be given
    // a hair trigger.
    //
    // The floor now applies to every dim.  It costs nothing: re-running the same
    // ten presses offline against |f| > 5 still detects 10 of 10 with the median
    // latency unchanged at 4.34 ms (three presses shifted by one or two frames),
    // and rest stays at 0 of 8118 frames.  dead[] keeps its reporting role.
    wire signed [39:0] cal_thr  = (thr_mul >>> 4);
    wire signed [25:0] cal_mean = $signed(s2_sum) >>> CAL_SH;

    //=========================================================================
    // Repeated calibration with contamination rejection (window-based CFAR)
    //=========================================================================
    // WHY NOT A PER-SAMPLE EWMA.  The first attempt folded every unguarded
    // sample into the noise estimate.  That works at rest but fails near the
    // detection floor: a SUB-THRESHOLD stimulus never asserts, so it never arms
    // the guard, so its own energy raises the threshold and pushes itself
    // further below it.  Measured on the synthetic sweep: the 55-count step fell
    // from 100% detection (one-shot build) to 67%, and mid-range latency grew
    // ~1.5x.  That is the classic CA-CFAR target-masking failure.
    //
    // WHAT THIS DOES INSTEAD.  Keep re-running the CAL_N window and accept or
    // REJECT each completed window WHOLE.  A window holding a press is discarded
    // rather than diluted into a running average, so a sub-threshold stimulus
    // cannot walk the threshold up.
    //
    // ACCEPTANCE IS RELATIVE, NOT ABSOLUTE.  VAR_CEIL alone is far too loose: a
    // 55-count press contributes roughly 700-1400 counts^2 to a 512-sample
    // window -- well under the 20000 ceiling, yet ~300x the quiescent 4.7.  A
    // window is accepted only if it lies within 2^ACC_SH of the accumulated
    // reference.  Comparing "this window" against "what has been learned so far"
    // is the whole mechanism.
    //
    // WHY IT IS MORE ACCURATE.  CAL_N = 512 holds only ~6 INDEPENDENT samples of
    // a dim whose autocorrelation time is 84 frames, so one window puts the
    // nominal 5 sigma anywhere in 2.6-7.3 real sigma.  Averaging W accepted
    // windows improves that as sqrt(W): 8 windows -> about 4.3-5.8 sigma.
    //
    // COST.  The window sum accumulates cmp_sq, which the comparison already
    // computes -- no second multiply and no pipeline change.  mu is known after
    // the first calibration, so sum and sum^2 are not needed here either.
    localparam       ROLL_EN = 1'b1;
    localparam       ACC_SH  = 2;       // accept if new_var <= 4 * ref_var
    localparam       AVG_K   = 3;       // average about 8 accepted windows
    localparam [3:0] REJ_MAX = 4'd8;    // consecutive rejects before forced accept
    // Windows that must be ACCEPTED before this dim's estimate is trusted.  The
    // one-shot seed carries the full 0.52x-1.45x spread of a 6-effective-sample
    // variance, so a boot that seeds low fires a burst until the averaging
    // corrects it -- measured once in five boots as 42 assertions inside 80 ms,
    // followed by 59.4 s clean.  That behaviour is correct (it converges); what
    // was wrong is that the frame claimed calibrated=1 throughout.  uncal now
    // stays asserted until CONV_N windows have been folded in, so the host is
    // told the mask is not yet trustworthy instead of being told it is.
    localparam [3:0] CONV_N  = 4'd8;
    localparam [7:0] GUARD_N = 8'd128;  // > 84-frame correlation time
    // GUARD DUTY WATCHDOG.  The guard blocks window accumulation, and every
    // assertion re-arms it -- so a dim that asserts more often than once per
    // GUARD_N samples never accumulates again and its threshold FREEZES at
    // whatever value it had.  Frozen low, it keeps asserting: a self-sustaining
    // lock with no exit, because REJ_MAX only rescues windows that COMPLETE and
    // are rejected, not windows that never advance.
    //
    // Measured on a 10 h capture from a board left running for a week
    // (2026-09-01, midnight start): dim1 asserted 39,318 times in one hour,
    // median inter-arrival 40 frames against GUARD_N = 128, so the guard duty
    // cycle was 100% for five consecutive hours.  Its threshold sat at 3.1-3.6
    // sigma of the compared quantity instead of 5.  dim0, which never asserted
    // that night, converged correctly to 5.1 sigma -- so the mechanism is sound
    // and only a dim that FALLS IN gets stuck.  No controlled test found this:
    // ten-minute quiescence, five boots, 19/19 presses and the synthetic floor
    // sweep all pass, because none of them sustains a dense assertion burst.
    //
    // FIX: after GSTALL_MAX guarded sample periods, force one accumulation.  The
    // window then COMPLETES and re-enters the ordinary relative accept/reject
    // path, where REJ_MAX is the second-stage escape.  So the worst case becomes
    // "stuck for a bounded time", not "stuck forever".
    localparam [11:0] GSTALL_MAX = 12'd2048;   // 4 x CAL_N ~= 3 s at 689 Hz

    reg [7:0] guard_cnt [0:N_DIM-1];
    wire      s2_guarded = (guard_cnt[s2_dim] != 8'd0);
    wire      s2_force   = (s2_gst >= GSTALL_MAX);   // guard watchdog expired
    wire      s2_roll    = ROLL_EN && s2_run && (!s2_guarded || s2_force);

    // ref_acc carries AVG_K FRACTIONAL BITS.  Without that headroom the update
    // (new - ref) >>> AVG_K quantises to 0 for positive differences and to -1
    // for negative ones, and the estimate ratchets to zero -- the v7 failure
    // recorded in DATA/SESSION_2026-08-29_LEDGER.md.
    (* syn_ramstyle = "distributed_ram" *) reg [43:0] win_sum [0:N_DIM-1];
    (* syn_ramstyle = "distributed_ram" *) reg [43:0] ref_acc [0:N_DIM-1];
    reg [9:0] win_cnt [0:N_DIM-1];
    reg [3:0] rej_cnt [0:N_DIM-1];
    reg [3:0] acc_cnt [0:N_DIM-1];   // accepted windows, saturating at CONV_N
    reg [11:0] gstall_cnt [0:N_DIM-1];  // consecutive guarded periods (watchdog)

    wire [43:0] w_sum_n = s2_wsum + {9'd0, cmp_sq[34:0]};
    wire        w_full  = (s2_wcnt == CAL_N-1);
    wire [43:0] new_var = w_sum_n >> CAL_SH;          // mean square of cmp
    wire [43:0] ref_var = s2_racc >> AVG_K;
    wire        acc_ok  = (new_var <= (ref_var << ACC_SH)) || (s2_rej == REJ_MAX);
    wire [43:0] racc_n  = s2_racc + new_var - (s2_racc >> AVG_K);

    // threshold = N_SQ * ref_var, same strength-reduced form as the one-shot path
    reg [43:0] thr_win;
    integer wb;
    always @(*) begin
        thr_win = 44'd0;
        for (wb = 0; wb < 8; wb = wb + 1)
            if (N_SQ_V[wb]) thr_win = thr_win + ((racc_n >> AVG_K) << wb);
    end

    // THR_MIN: the floor both estimators land on.  VAR_MIN16 is in 16*sigma^2,
    // N_SQ multiplies a variance, so N_SQ*VAR_MIN16/16 is the threshold in the
    // counts^2 the comparison uses.  The SoC LUT write is deliberately NOT
    // floored: an explicit threshold from software means what it says.
    localparam signed [39:0] THR_MIN = (N_SQ * VAR_MIN16) >>> 4;
    wire signed [39:0] cal_thr_f = (cal_thr < THR_MIN) ? THR_MIN : cal_thr;
    wire signed [39:0] win_thr_f = ($signed(thr_win[39:0]) < THR_MIN)
                                   ? THR_MIN : $signed(thr_win[39:0]);

    // threshold RAM: SoC LUT write > one-shot finalize > accepted window
    always @(posedge clk) begin
        if (lut_wr)                           threshold[lut_dim] <= {8'd0, lut_thr};
        else if (s2_final && !cal_hot)        threshold[s2_dim]  <= cal_thr_f;
        else if (s2_roll && w_full && acc_ok) threshold[s2_dim]  <= win_thr_f;
    end

    // window sum / accepted reference
    always @(posedge clk) begin
        if (s2_final && !cal_hot) begin
            // Seed from the one-shot variance so the armed threshold is
            // unchanged at t = 0; the windows then refine it.
            // Seed at TWICE the one-shot variance, not at it.  The seed's error
            // is symmetric but its consequences are not: seeding low fires false
            // assertions, seeding high only costs brief insensitivity that the
            // window averaging then removes.  Bias to the fail-safe side.
            ref_acc[s2_dim] <= (({4'd0, cal_var16[39:0]}) >> 3) << AVG_K;
            win_sum[s2_dim] <= 44'd0;
        end else if (s2_roll) begin
            if (w_full) begin
                win_sum[s2_dim] <= 44'd0;
                if (acc_ok) ref_acc[s2_dim] <= racc_n;
            end else begin
                win_sum[s2_dim] <= w_sum_n;
            end
        end
    end

    // cal_sum / cal_sumsq / mu RAM writes (accumulate / finalize / roll).
    // The mean only rolls for ABS dims; the ROC dims difference two samples of
    // the same signal, so their comparison has no mean to track.
    always @(posedge clk) begin
        if (s2_accum) begin
            cal_sum[s2_dim]   <= s2_first ? $signed(s2_x) : s2_sum   + $signed(s2_x);
            cal_sumsq[s2_dim] <= s2_first ? x_sq_u        : s2_sumsq + x_sq_u;
        end
        if (s2_final) mu[s2_dim] <= cal_mean[15:0];
    end

    // control registers + outputs
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            flag_out<=0; flag_valid<=0; flag_dim<=0;
            mask<={N_DIM{1'b0}}; dead<={N_DIM{1'b0}};
            for (i=0;i<N_DIM;i=i+1) begin
                cal_cnt[i]<=10'd0; calibrated[i]<=1'b0; deb_cnt[i]<=8'd0;
                guard_cnt[i]<=8'd0; win_cnt[i]<=10'd0; rej_cnt[i]<=4'd0;
                acc_cnt[i]<=4'd0; gstall_cnt[i]<=12'd0;
            end
        end else begin
            flag_valid <= 1'b0;

            // CFAR guard band: an assertion freezes this dim's rolling update
            // for GUARD_N frames, so the contact's own energy never enters the
            // noise estimate.  Decays on every visit to the dim, so the hold-off
            // is counted in samples of that dim rather than in clocks.
            if (s2_run) begin
                if (over_thr)                     guard_cnt[s2_dim] <= GUARD_N;
                else if (guard_cnt[s2_dim] != 0)  guard_cnt[s2_dim] <= guard_cnt[s2_dim] - 8'd1;
                // Watchdog: count periods spent guarded; clear whenever the dim
                // actually accumulates (guard down, or this visit forced).
                // Once tripped, the watchdog must STAY tripped until the window
                // COMPLETES.  Clearing it on the forced sample only lets one
                // sample through per GSTALL_MAX, so a 512-sample window would
                // take 25 minutes to fill -- measured: win_cnt advanced by 19 in
                // 56 s of continuous assertion.  Holding the count latches the
                // force until w_full, which fills the window in 0.74 s.
                if (w_full)                       gstall_cnt[s2_dim] <= 12'd0;
                else if (s2_force)                gstall_cnt[s2_dim] <= s2_gst;
                else if (s2_guarded)              gstall_cnt[s2_dim] <= s2_gst + 12'd1;
                else                              gstall_cnt[s2_dim] <= 12'd0;
            end
            if (s2_final && !cal_hot) begin
                win_cnt[s2_dim] <= 10'd0; rej_cnt[s2_dim] <= 4'd0;
                acc_cnt[s2_dim] <= 4'd0;
            end else if (s2_roll) begin
                if (w_full) begin
                    win_cnt[s2_dim] <= 10'd0;
                    if (acc_ok && acc_cnt[s2_dim] != CONV_N)
                        acc_cnt[s2_dim] <= acc_cnt[s2_dim] + 4'd1;
                    // A rejected window still counts.  REJ_MAX consecutive
                    // rejections force acceptance, so a genuine shift in the
                    // ambient level is adopted instead of being frozen out.
                    rej_cnt[s2_dim] <= acc_ok ? 4'd0
                                              : ((s2_rej == REJ_MAX) ? REJ_MAX : s2_rej + 4'd1);
                end else begin
                    win_cnt[s2_dim] <= s2_wcnt + 10'd1;
                end
            end

            if (lut_wr) calibrated[lut_dim] <= 1'b1;

            if (s2_accum) begin
                cal_cnt[s2_dim] <= s2_cnt + 10'd1;
            end
            if (s2_final) begin
                if (cal_hot) begin
                    // window was contaminated: throw it away and start over.
                    // cal_cnt == 0 makes s2_first restart the accumulators, so
                    // no state from the bad window survives.  Retrying forever is
                    // the intended behaviour: while it retries the dim simply
                    // reports no events, which is the safe failure.
                    cal_cnt[s2_dim] <= 10'd0;
                end else begin
                    dead[s2_dim]       <= cal_dead;
                    calibrated[s2_dim] <= 1'b1;
                end
            end
            if (s2_run) begin
                if (over_thr) begin
                    if (s2_deb >= DEB-1) begin
                        flag_out      <= 1'b1;
                        mask[s2_dim]  <= 1'b1;
                    end else begin
                        deb_cnt[s2_dim] <= s2_deb + 8'd1;
                        flag_out        <= 1'b0;
                    end
                end else begin
                    deb_cnt[s2_dim] <= 8'd0;
                    flag_out        <= 1'b0;
                    mask[s2_dim]    <= 1'b0;
                end
                flag_dim   <= s2_dim;
                flag_valid <= 1'b1;
            end
        end
    end

    genvar ci;
    generate
        for (ci=0; ci<N_DIM; ci=ci+1) begin : g_uncal
            assign uncal[ci] = ~calibrated[ci] | (acc_cnt[ci] != CONV_N);
        end
    endgenerate

    assign mask_failsafe = ~mask;

    localparam DBG_LIVE = 2;    // ch0 DoG_slow -- the dim that locked up in the field
    localparam DBG_DEAD = 1;    // ch1 G_s3 -- no sensor, dead map bit set
    assign dbg_wcnt_live = {6'd0, win_cnt[DBG_LIVE]};
    assign dbg_acnt_live = {12'd0, acc_cnt[DBG_LIVE]};
    assign dbg_wcnt_dead = {6'd0, win_cnt[DBG_DEAD]};
    assign dbg_acnt_dead = {12'd0, acc_cnt[DBG_DEAD]};

endmodule
