//=============================================================================
// zscore_flag.v
//
// Significance flag for ONE DoG dimension, using the squared-comparison trick
// so NO divider and NO square-root are needed on the FPGA.
//
// MATH (verified bit-identical to z-score in verify_square_method.py):
//   z-score flag:  |z| > N   where z = DoG / sigma_noise
//   equivalently:  DoG^2 > N^2 * variance          (square both sides)
//   variance = sigma_noise^2  (no sqrt needed!)
//
// So at power-on we estimate the variance of the stationary DoG, multiply by
// N^2, and store it as a threshold. At run time we just compute DoG^2 (one
// multiply) and compare. One multiplier + one comparator, no div, no sqrt.
//
// TWO MODES (matching the paper / golden model):
//   mode=0 ABS : flag on |DoG|^2 > thr            (for G_s3 slow trend)
//   mode=1 ROC : flag on (DoG[n]-DoG[n-k])^2 > thr (for DoG_fast/slow)
//                k = 10 samples
//
// DEBOUNCE: require DEB consecutive samples over threshold before asserting,
// to suppress the sqrt(2) noise amplification of the differential mode.
//
// POWER-ON CALIBRATION:
//   collect CAL_N (512) stationary DoG samples, compute mean and variance
//   online (Welford-style running sum), then thr = N^2 * variance.
//   IMPORTANT: the sensor MUST be at rest during calibration, else variance
//   is corrupted (verified in the golden model).
//=============================================================================

module zscore_flag #(
    parameter CAL_N   = 512,    // calibration samples
    parameter CAL_SH  = 9,      // log2(CAL_N): divide-by-N becomes >>CAL_SH
    parameter ROC_K   = 10,     // rate-of-change lag
    parameter N_SQ    = 9,      // N^2 (N=3 -> 9)
    parameter DEB     = 3,      // debounce: consecutive samples
    parameter MODE    = 1       // 0=ABS, 1=ROC
)(
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire signed [15:0]   dog_in,        // DoG value this sample
    input  wire                 valid,         // 1-clk pulse: new dog_in
    output reg                  flag,          // significance flag (debounced)
    output reg                  calibrated     // high once calibration done
);

    //=========================================================================
    // ROC delay line: store last ROC_K DoG samples to form DoG[n]-DoG[n-k]
    //=========================================================================
    reg signed [15:0] roc_buf [0:ROC_K-1];
    integer j;

    //=========================================================================
    // Calibration: accumulate sum and sum-of-squares of stationary DoG
    //   variance = (sum_sq - sum*sum/CAL_N) / CAL_N
    // We accumulate, then at the end compute variance and threshold.
    //=========================================================================
    reg [15:0]        cal_cnt;
    reg signed [47:0] cal_sum;     // sum of dog (signed, room for 512*32768)
    reg [63:0]        cal_sumsq;   // sum of dog^2 (unsigned, large)
    reg [63:0]        threshold;   // N^2 * variance (in (LSB)^2 units)
    reg signed [15:0] mu;          // calibration mean (for ABS mode offset removal)
    reg signed [63:0] mean_sq_term;// (sum^2)/N, signed intermediate
    reg               calc_thr;    // pulse: finalize threshold one cycle after cal

    //=========================================================================
    // Debounce counter
    //=========================================================================
    reg [7:0] deb_cnt;

    // value used for comparison this sample
    reg signed [16:0] cmp_val;     // either dog_in (ABS) or dog_in - dog_delayed (ROC)
    reg [63:0]        cmp_sq;      // cmp_val^2

    // signed-correct squaring: compute as signed product, result is always >=0,
    // then zero-extend into the unsigned accumulator. (dog_in*dog_in done as a
    // bare expression gets treated as unsigned, corrupting negative inputs.)
    wire signed [31:0] dog_sq_s = $signed(dog_in) * $signed(dog_in);
    wire [63:0]        dog_sq_u = {32'd0, dog_sq_s[31:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cal_cnt    <= 16'd0;
            cal_sum    <= 48'sd0;
            cal_sumsq  <= 64'd0;
            threshold  <= 64'd0;
            mu         <= 16'sd0;
            mean_sq_term <= 64'sd0;
            calc_thr   <= 1'b0;
            calibrated <= 1'b0;
            flag       <= 1'b0;
            deb_cnt    <= 8'd0;
            for (j=0;j<ROC_K;j=j+1) roc_buf[j] <= 16'sd0;
        end else begin
            if (valid) begin
                //--------------------------------------------------------------
                // shift ROC delay line (newest at index 0)
                //--------------------------------------------------------------
                for (j=ROC_K-1;j>0;j=j-1) roc_buf[j] <= roc_buf[j-1];
                roc_buf[0] <= dog_in;

                if (!calibrated) begin
                    //----------------------------------------------------------
                    // CALIBRATION PHASE: accumulate sum and sum of squares
                    //----------------------------------------------------------
                    cal_sum   <= cal_sum   + dog_in;
                    cal_sumsq <= cal_sumsq + dog_sq_u;
                    cal_cnt   <= cal_cnt + 1'b1;
                    if (cal_cnt == CAL_N-1) begin
                        // variance = (sumsq - sum^2/N) / N ; threshold = N_SQ*variance
                        // Use explicit signed intermediates: mixing the unsigned
                        // cal_sumsq with the signed cal_sum^2 term in one bare
                        // expression makes the whole thing unsigned, which blows
                        // up when cal_sum is negative. Compute signed, then scale.
                        mean_sq_term <= ($signed(cal_sum) * $signed(cal_sum))
                                        >>> CAL_SH;                  // sum^2 / N
                        calibrated   <= 1'b1;
                        calc_thr     <= 1'b1;   // trigger threshold finalize next cycle
                        mu           <= $signed(cal_sum) >>> CAL_SH; // mean
                    end
                end else begin
                    //----------------------------------------------------------
                    // RUN PHASE: compute comparison value and square it
                    //----------------------------------------------------------
                    if (MODE == 0)
                        cmp_val = dog_in - mu;                  // ABS: |x - mu|
                    else
                        cmp_val = dog_in - roc_buf[ROC_K-1];    // ROC: x[n]-x[n-k]

                    cmp_sq = $signed(cmp_val) * $signed(cmp_val);  // squared (>=0)

                    //----------------------------------------------------------
                    // compare to threshold, with debounce
                    //----------------------------------------------------------
                    if (cmp_sq > threshold) begin
                        if (deb_cnt >= DEB-1) flag <= 1'b1;
                        else begin deb_cnt <= deb_cnt + 1'b1; flag <= 1'b0; end
                    end else begin
                        deb_cnt <= 8'd0;
                        flag    <= 1'b0;
                    end
                end
            end

            // Finalize threshold one cycle after calibration completes, using
            // signed intermediates: variance = (sumsq - mean_sq_term)>>CAL_SH,
            // threshold = N_SQ * variance. cal_sumsq is unsigned but always >=
            // mean_sq_term for real data, so the signed result is non-negative.
            if (calc_thr) begin
                threshold <= $signed(N_SQ) *
                             (($signed(cal_sumsq) - mean_sq_term) >>> CAL_SH);
                calc_thr  <= 1'b0;
            end
        end
    end

endmodule
