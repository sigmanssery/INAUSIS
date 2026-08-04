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
// CALIBRATION / flag math:
//   flag <=> cmp_val^2 > N^2*variance ; var = (N*sumsq - sum^2)/N^2
//   cmp_val = x - mu (ABS) or x[n]-x[n-ROC_K] (ROC)
//   2026-06: each dim calibrates `variance` on the SAME quantity it later
//   compares -> ABS accumulates x, ROC accumulates the difference x[n]-x[n-K].
//   Previously both accumulated x, so the ROC threshold was ~sqrt(2) too low
//   (diff variance ~2x feature variance) -> ROC bands fired at ~2.1 sigma, not
//   N. Now a true per-band N-sigma. (golden: estimate_noise_sigma_roc)
//=============================================================================

module zscore_flag_multi #(
    parameter N_DIM   = 18,
    parameter DIM_BITS= 5,
    parameter CAL_N   = 512,
    parameter CAL_SH  = 9,
    parameter N_SQ    = 9,
    parameter ROC_K   = 10,
    parameter DEB     = 3,
    parameter VAR_FLOOR = 1
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
    output reg  [N_DIM-1:0]     dead
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

    // value accumulated during CALIBRATION: ROC dims calibrate on the DIFFERENCE
    // they actually compare (x[n]-x[n-k], = s1_cmp in ROC mode) so threshold =
    // N^2*var is a TRUE N-sigma; ABS dims calibrate on the feature x. Fixes the
    // ~sqrt(2) ROC under-threshold (diff variance is ~2x the feature variance).
    // First ROC_K cal samples use x[n-k]=0 (zero-init roc_mem) — negligible vs 512.
    wire signed [16:0] s1_accval = s1_mode ? s1_cmp : $signed({s1_x[15],s1_x});

    wire s1_do_accum = s1_valid && !s1_cal && (s1_cnt <  CAL_N);
    wire s1_do_final = s1_valid && !s1_cal && (s1_cnt == CAL_N);
    wire s1_do_run   = s1_valid &&  s1_cal;

    // shared multiplier operand: finalize->sum, accumulate->x, runtime->cmp
    reg signed [25:0] sq_op;
    always @(*) begin
        if      (s1_do_final) sq_op = s1_sum;
        else if (s1_do_accum) sq_op = $signed(s1_accval);   // ROC: var of the difference
        else                  sq_op = $signed(s1_cmp);
    end
    wire signed [51:0] sq_p = sq_op * sq_op;     // 26x26 -> 2 DSP

    reg                 s2_valid, s2_accum, s2_final, s2_run, s2_first;
    reg [DIM_BITS-1:0]  s2_dim;
    reg signed [16:0]   s2_accval;   // calibration accumuland (diff for ROC, x for ABS)
    reg signed [25:0]   s2_sum;
    reg        [39:0]   s2_sumsq;
    reg signed [39:0]   s2_thr;
    reg        [7:0]    s2_deb;
    reg [9:0]           s2_cnt;
    reg signed [51:0]   s2_sqp;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            s2_valid<=0; s2_accum<=0; s2_final<=0; s2_run<=0; s2_first<=0;
            s2_dim<=0; s2_accval<=0; s2_sum<=0; s2_sumsq<=0; s2_thr<=0; s2_deb<=0;
            s2_cnt<=0; s2_sqp<=0;
        end else begin
            s2_valid <= s1_valid;
            s2_accum <= s1_do_accum;
            s2_final <= s1_do_final;
            s2_run   <= s1_do_run;
            s2_first <= (s1_cnt == 10'd0);
            s2_dim   <= s1_dim;
            s2_accval <= s1_accval;
            s2_sum   <= s1_sum;
            s2_sumsq <= s1_sumsq;
            s2_thr   <= s1_thr;
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
    wire signed [39:0] cal_var  = cal_num >>> (2*CAL_SH);
    wire               cal_dead = (cal_var <= $signed(VAR_FLOOR));
    wire signed [39:0] cal_thr  = cal_dead ? ($signed(N_SQ) * $signed(VAR_FLOOR))
                                           : ($signed(N_SQ) * cal_var);
    wire signed [25:0] cal_mean = $signed(s2_sum) >>> CAL_SH;

    // threshold RAM: single write port (SoC LUT write has priority over finalize)
    always @(posedge clk) begin
        if (lut_wr)        threshold[lut_dim] <= {8'd0, lut_thr};
        else if (s2_final) threshold[s2_dim]  <= cal_thr;
    end

    // cal_sum / cal_sumsq / mu RAM writes (accumulate / finalize)
    always @(posedge clk) begin
        if (s2_accum) begin
            cal_sum[s2_dim]   <= s2_first ? $signed(s2_accval) : s2_sum   + $signed(s2_accval);
            cal_sumsq[s2_dim] <= s2_first ? x_sq_u             : s2_sumsq + x_sq_u;
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
            end
        end else begin
            flag_valid <= 1'b0;

            if (lut_wr) calibrated[lut_dim] <= 1'b1;

            if (s2_accum) begin
                cal_cnt[s2_dim] <= s2_cnt + 10'd1;
            end
            if (s2_final) begin
                dead[s2_dim]       <= cal_dead;
                calibrated[s2_dim] <= 1'b1;
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

    assign mask_failsafe = ~mask;

endmodule
