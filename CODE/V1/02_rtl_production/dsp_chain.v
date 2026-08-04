`timescale 1ns/1ps
//=============================================================================
// dsp_chain.v
//
// Integration of the DoG multi-channel filter and the multi-dimension flag
// engine into one DSP chain. Handles the channel->dimension mapping:
//
//   dim = ch*3 + k,   k = 0:DoG_fast(ROC), 1:DoG_slow(ROC), 2:G_s3(ABS)
//
// FLOW per input sample (one channel at a time):
//   1. feed (ch_id, sample) into dog_fir_multi
//   2. when dog result_valid for that channel, push its 3 features into the
//      flag engine on 3 consecutive cycles, each with the right dim & mode
//   3. flag engine updates the 18-bit mask; mask_failsafe (~mask) goes out
//
// This is the core sensing datapath: raw sample in -> attention mask out.
//=============================================================================

module dsp_chain #(
    parameter N_CH    = 6,
    parameter CH_BITS = 3,
    parameter N_DIM   = 18,
    parameter DIM_BITS= 5
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // raw sample input (one channel at a time)
    input  wire [CH_BITS-1:0]   ch_id,
    input  wire signed [15:0]   sample_in,
    input  wire                 sample_valid,

    // LUT update (from SoC reverse channel via lut_parser) -> internal flag
    input  wire                 lut_wr,
    input  wire [DIM_BITS-1:0]  lut_dim,
    input  wire [31:0]          lut_thr,

    // outputs
    output wire [N_DIM-1:0]     mask,          // active-high (1=event)
    output wire [N_DIM-1:0]     mask_failsafe, // active-low  (0=event, fail-safe)
    output wire [N_DIM-1:0]     dead,          // 1 = dim's calibration found var=0
    output wire [N_DIM*16-1:0]  dog_flat,      // 18 dims x 16-bit DoG values
    output wire                 chain_busy
);

    //=========================================================================
    // DoG multi-channel filter
    //=========================================================================
    wire [CH_BITS-1:0]   dog_ch_done;
    wire signed [15:0]   dog_G1, dog_G2, dog_G3, dog_fast, dog_slow;
    wire                 dog_result_valid, dog_busy;

    dog_fir_multi #(.N_CH(N_CH), .CH_BITS(CH_BITS)) u_dog (
        .clk(clk), .rst_n(rst_n),
        .ch_id(ch_id), .sample_in(sample_in), .sample_valid(sample_valid),
        .ch_done(dog_ch_done),
        .G_s1(dog_G1), .G_s2(dog_G2), .G_s3(dog_G3),
        .DoG_fast(dog_fast), .DoG_slow(dog_slow),
        .result_valid(dog_result_valid), .busy(dog_busy)
    );

    //=========================================================================
    // Feeder FSM: when DoG produces a channel result, push its 3 features
    // into the flag engine on 3 consecutive cycles.
    //=========================================================================
    localparam F_IDLE=2'd0, F_FAST=2'd1, F_SLOW=2'd2, F_G3=2'd3;
    reg [1:0]            fstate;
    reg [CH_BITS-1:0]    feed_ch;
    reg signed [15:0]    lat_fast, lat_slow, lat_g3;

    reg [DIM_BITS-1:0]   flag_dim_id;
    reg signed [15:0]    flag_x;
    reg                  flag_valid_in;
    reg                  flag_mode_roc;

    // store each dim's DoG value (for the frame packer). dim = ch*3 + {0,1,2}
    reg signed [15:0]    dog_store [0:N_DIM-1];
    genvar gi;
    generate
        for (gi=0; gi<N_DIM; gi=gi+1) begin : g_dogflat
            assign dog_flat[gi*16 +: 16] = dog_store[gi];
        end
    endgenerate

    integer ri;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fstate        <= F_IDLE;
            feed_ch       <= 0;
            lat_fast<=0; lat_slow<=0; lat_g3<=0;
            flag_dim_id   <= 0;
            flag_x        <= 0;
            flag_valid_in <= 1'b0;
            flag_mode_roc <= 1'b0;
            for (ri=0; ri<N_DIM; ri=ri+1) dog_store[ri] <= 16'sd0;
        end else begin
            flag_valid_in <= 1'b0;   // default: no flag input this cycle

            case (fstate)
            F_IDLE: begin
                if (dog_result_valid) begin
                    // latch this channel's 3 features
                    feed_ch  <= dog_ch_done;
                    lat_fast <= dog_fast;
                    lat_slow <= dog_slow;
                    lat_g3   <= dog_G3;
                    fstate   <= F_FAST;
                end
            end
            // push DoG_fast -> dim = ch*3+0, ROC
            F_FAST: begin
                flag_dim_id   <= feed_ch*3 + 0;
                flag_x        <= lat_fast;
                flag_mode_roc <= 1'b1;        // ROC
                flag_valid_in <= 1'b1;
                dog_store[feed_ch*3 + 0] <= lat_fast;
                fstate        <= F_SLOW;
            end
            // push DoG_slow -> dim = ch*3+1, ROC
            F_SLOW: begin
                flag_dim_id   <= feed_ch*3 + 1;
                flag_x        <= lat_slow;
                flag_mode_roc <= 1'b1;        // ROC
                flag_valid_in <= 1'b1;
                dog_store[feed_ch*3 + 1] <= lat_slow;
                fstate        <= F_G3;
            end
            // push G_s3 -> dim = ch*3+2, ABS
            F_G3: begin
                flag_dim_id   <= feed_ch*3 + 2;
                flag_x        <= lat_g3;
                flag_mode_roc <= 1'b0;        // ABS
                flag_valid_in <= 1'b1;
                dog_store[feed_ch*3 + 2] <= lat_g3;
                fstate        <= F_IDLE;
            end
            endcase
        end
    end

    //=========================================================================
    // Flag engine (multi-dimension, time-multiplexed)
    //=========================================================================
    wire [DIM_BITS-1:0] fdim; wire fout, fvalid;

    zscore_flag_multi #(.N_DIM(N_DIM), .DIM_BITS(DIM_BITS)) u_flag (
        .clk(clk), .rst_n(rst_n),
        .dim_id(flag_dim_id), .x_in(flag_x), .valid(flag_valid_in),
        .mode_roc(flag_mode_roc),
        .lut_wr(lut_wr), .lut_dim(lut_dim), .lut_thr(lut_thr),
        .flag_dim(fdim), .flag_out(fout), .flag_valid(fvalid),
        .mask(mask), .mask_failsafe(mask_failsafe), .dead(dead)
    );

    // The flag engine is internally pipelined (3 stages): its mask/dead results
    // land a few cycles after the last feed. Hold chain_busy until that pipeline
    // has drained, so frame_packer never snapshots a stale mask.
    reg [2:0] flag_drain;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)               flag_drain <= 3'd0;
        else if (flag_valid_in)   flag_drain <= 3'd4;
        else if (flag_drain != 0) flag_drain <= flag_drain - 3'd1;
    end

    assign chain_busy = dog_busy || (fstate != F_IDLE) || (flag_drain != 3'd0);

endmodule
