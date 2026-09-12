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
    parameter DIM_BITS= 5,
    // Build identifier, carried in the frame at BID_DIM so a capture always says
    // which bitstream produced it.  This board has three ways to end up running
    // something other than what was just built -- SRAM loses its image on power
    // loss, RESET reloads from internal flash, and Gowin's "Verify Failed at 0"
    // is a false alarm that cannot be trusted either way -- and each of those has
    // cost real time here.  Hex is chosen to read at a glance: 0x0934 is the
    // thirty-fourth build, September.  BUMP IT EVERY BUILD -- and note that for the
    // ttcgs_board target this default is NOT the one that ships: ttcgs_sys overrides
    // it, so bump ttcgs_sys.v too, or instead.  Kept equal to it on purpose.
    parameter [15:0] BUILD_ID = 16'h0946
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // raw sample input (one channel at a time)
    input  wire [CH_BITS-1:0]   ch_id,
    input  wire signed [15:0]   sample_in,
    input  wire                 sample_valid,

    // Passed straight through to dim AUX_DIM so a stimulus generator can label
    // its own output.  Tie to 0 when unused; that dim's channel has no sensor.
    input  wire signed [15:0]   aux_val,

    // LUT update (from SoC reverse channel via lut_parser) -> internal flag
    input  wire                 lut_wr,
    input  wire [DIM_BITS-1:0]  lut_dim,
    input  wire [31:0]          lut_thr,

    // outputs
    output wire [N_DIM-1:0]     mask,          // active-high (1=event)
    output wire [N_DIM-1:0]     mask_failsafe, // active-low  (0=event, fail-safe)
    output wire [N_DIM-1:0]     dead,          // 1 = dim's calibration found var=0
    output wire [N_DIM*16-1:0]  dog_flat,      // 18 dims x 16-bit DoG values
    output wire                 slide_flag,    // last contact was a slide
    output wire                 slide_valid,   // pulses when slide_flag updates
    output wire                 in_contact,
    output wire [N_DIM-1:0]     uncal,        // 1 = dim still calibrating
    output wire                 chain_busy
);

    //=========================================================================
    // DoG multi-channel filter
    //=========================================================================
    wire [CH_BITS-1:0]   dog_ch_done;
    wire signed [15:0]   dog_G1, dog_G2, dog_G3, dog_fast, dog_slow;
    // Flag-engine copies, scaled up per channel -- see dog_fir_multi's FB_CH*.
    // dog_flat and slide_detect stay on the unscaled set above so the frame
    // format and the slide thresholds are untouched.
    wire signed [15:0]   dog_G3f, dog_fastf, dog_slowf;
    wire                 dog_result_valid, dog_busy;

    dog_fir_multi #(.N_CH(N_CH), .CH_BITS(CH_BITS)) u_dog (
        .clk(clk), .rst_n(rst_n),
        .ch_id(ch_id), .sample_in(sample_in), .sample_valid(sample_valid),
        .ch_done(dog_ch_done),
        .G_s1(dog_G1), .G_s2(dog_G2), .G_s3(dog_G3),
        .DoG_fast(dog_fast), .DoG_slow(dog_slow),
        .G_s3_f(dog_G3f), .DoG_fast_f(dog_fastf), .DoG_slow_f(dog_slowf),
        .result_valid(dog_result_valid), .busy(dog_busy)
    );

    //=========================================================================
    // Feeder FSM: when DoG produces a channel result, push its 3 features
    // into the flag engine on 3 consecutive cycles.
    //=========================================================================
    localparam F_IDLE=3'd0, F_FAST=3'd1, F_SLOW=3'd2, F_G3=3'd3, F_RAW=3'd4;
    reg [2:0]            fstate;

    // CONTACT dimension.  The three bands answer three different questions and
    // none of them is "is the sensor loaded right now": d2 is a 371 ms moving
    // average, so a 111 ms tap keeps it asserted for 481 ms, and d0/d1 are rate
    // detectors that mark edges.  Measured 2026-09-05 against the raw signal:
    // d0 overshoots the true contact duration by +56 ms, d1 by -99, d2 by +370.
    //
    // The raw signal itself has no such lag -- 6.5 ms to rise, 4.4 ms to fall --
    // so running the SAME adaptive threshold on it gives contact directly.  It
    // costs nothing: SINGLE_CH=1 leaves ch1-3's nine dimensions permanently
    // dead, and dim 3 is one of them.
    //
    // Scaled by 16 to match dims 0-11, which is what VAR_CEIL_F and the fine
    // path assume.  The resting level (about 1613 counts) is 25,808 there and
    // still fits; a press saturates, which is harmless for an ABS comparison.
    wire signed [15:0] raw_x16 = (raw_lat >  16'sd2047) ? 16'sh7FFF
                               : (raw_lat < -16'sd2048) ? 16'sh8000
                                                        : (raw_lat <<< 4);
    reg [CH_BITS-1:0]    feed_ch;
    reg signed [15:0]    lat_fast, lat_slow, lat_g3;

    reg [DIM_BITS-1:0]   flag_dim_id;
    reg signed [15:0]    flag_x;
    reg signed [15:0]    lat_fastf, lat_slowf, lat_g3f;
    reg                  flag_valid_in;
    reg                  flag_mode_roc;

    // store each dim's DoG value (for the frame packer). dim = ch*3 + {0,1,2}
    reg signed [15:0]    dog_store [0:N_DIM-1];

    // Dim RAW_DIM carries the raw CH0 sample instead of ch4's DoG_fast.  All three
    // DoG outputs are low-passed -- G(s3) to 1.8 Hz, DoG_fast -3 dB by 70 Hz -- so
    // nothing above 70 Hz has ever reached the host, and the 2026-08-28 corpus
    // could not test whether contact types differ up there.  ch4/ch5 have no
    // sensor (dead map 0x3F000), so this slot was carrying zeros.
    // Only dog_flat is overridden: the flag engine is fed from lat_* in the
    // feeder FSM below, so its behaviour and the dead map are unchanged --
    // dim RAW_DIM still reports dead=1 while carrying live data.
    localparam RAW_DIM = 12;
    localparam AUX_DIM = 13;
    // ch1's slow band; ch1 is never sampled under SINGLE_CH so this dimension
    // carried a dead constant.  See BUILD_ID.
    localparam BID_DIM = 4;
    // Bring-up scaffolding: dims 14-17 carry slide_detect's internals so a host
    // capture can be compared against the offline model sample by sample.  That
    // is how the signedness bug in the squarer was located -- reading the code
    // had failed four times.  Off for anything whose resource figures are quoted.
    localparam DEBUG_TAPS = 1'b0;
    reg signed [15:0]    raw_lat;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          raw_lat <= 16'sd0;
        else if (sample_valid && ch_id == 0) raw_lat <= sample_in;
    end

    wire [15:0] dbg_hp_w, dbg_fast_w, dbg_n_w;
    wire signed [15:0] dbg_hpnow_w;
    // Force-invariant slide/press decision, made on chip once per contact.
    // Fed from ch0 only: that is the channel with the sensor on it.
    slide_detect u_slide (
        .clk(clk), .rst_n(rst_n),
        .raw(raw_lat), .g1(dog_G1), .fast(dog_fast), .g3(dog_G3),
        .valid(dog_result_valid && (dog_ch_done == 0)),
        .thr_wr(1'b0), .thr_data(16'd0),
        .is_slide(slide_flag), .decided(slide_valid), .in_contact(in_contact),
        .dbg_hp(dbg_hp_w), .dbg_fast(dbg_fast_w), .dbg_n(dbg_n_w), .dbg_hp_now(dbg_hpnow_w)
    );

    genvar gi;
    generate
        for (gi=0; gi<N_DIM; gi=gi+1) begin : g_dogflat
            assign dog_flat[gi*16 +: 16] =
                (gi == RAW_DIM) ? raw_lat :
                (gi == AUX_DIM) ? aux_val :
                (gi == BID_DIM) ? $signed(BUILD_ID) :
                (DEBUG_TAPS && gi == 14) ? $signed(zdbg_wl) :
                (DEBUG_TAPS && gi == 15) ? $signed(zdbg_al) :
                (DEBUG_TAPS && gi == 16) ? $signed(zdbg_wd) :
                (DEBUG_TAPS && gi == 17) ? $signed(zdbg_ad) : dog_store[gi];
        end
    endgenerate

    integer ri;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fstate        <= F_IDLE;
            feed_ch       <= 0;
            lat_fast<=0; lat_slow<=0; lat_g3<=0;
            lat_fastf<=0; lat_slowf<=0; lat_g3f<=0;
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
                    lat_fastf<= dog_fastf;
                    lat_slowf<= dog_slowf;
                    lat_g3f  <= dog_G3f;
                    fstate   <= F_FAST;
                end
            end
            // push DoG_fast -> dim = ch*3+0, ROC
            F_FAST: begin
                // ch1 is skipped: dim 3 belongs to the contact detector now (see
                // F_RAW), and ch1's own fast band is dead anyway because
                // SINGLE_CH=1 never samples that channel.  Feeding both would
                // alternate two unrelated signals into one dimension and destroy
                // its calibration.
                //
                // The fine copy is used again here.  The v25 revert existed
                // because the fine values were saturated BEFORE the DoG
                // subtraction, which zeroed d0/d1 during a press; dog_fir_multi
                // now subtracts at full width and saturates once.
                if (feed_ch != 3'd1) begin
                    flag_dim_id   <= feed_ch*3 + 0;
                    flag_x        <= lat_fastf;
                    flag_mode_roc <= 1'b1;        // ROC
                    flag_valid_in <= 1'b1;
                    dog_store[feed_ch*3 + 0] <= lat_fast;
                end
                fstate        <= F_SLOW;
            end
            // push DoG_slow -> dim = ch*3+1, ROC
            F_SLOW: begin
                flag_dim_id   <= feed_ch*3 + 1;
                flag_x        <= lat_slowf;
                flag_mode_roc <= 1'b1;        // ROC
                flag_valid_in <= 1'b1;
                dog_store[feed_ch*3 + 1] <= lat_slow;
                fstate        <= F_G3;
            end
            // push G_s3 -> dim = ch*3+2, ABS
            F_G3: begin
                flag_dim_id   <= feed_ch*3 + 2;
                flag_x        <= lat_g3f;
                flag_mode_roc <= 1'b0;        // ABS
                flag_valid_in <= 1'b1;
                dog_store[feed_ch*3 + 2] <= lat_g3;
                fstate        <= (feed_ch == 0) ? F_RAW : F_IDLE;
            end
            // Contact, from ch0's raw only.  See raw_x16 above.
            F_RAW: begin
                flag_dim_id   <= 5'd3;
                flag_x        <= raw_x16;
                flag_mode_roc <= 1'b0;        // ABS: level, not rate
                flag_valid_in <= 1'b1;
                dog_store[3]  <= raw_lat;     // frame shows what the mask judged
                fstate        <= F_IDLE;
            end
            endcase
        end
    end

    //=========================================================================
    // Flag engine (multi-dimension, time-multiplexed)
    //=========================================================================
    wire [DIM_BITS-1:0] fdim; wire fout, fvalid;
    wire [15:0] zdbg_wl, zdbg_al, zdbg_wd, zdbg_ad;

    zscore_flag_multi #(.N_DIM(N_DIM), .DIM_BITS(DIM_BITS)) u_flag (
        .clk(clk), .rst_n(rst_n),
        .dim_id(flag_dim_id), .x_in(flag_x), .valid(flag_valid_in),
        .mode_roc(flag_mode_roc),
        .lut_wr(lut_wr), .lut_dim(lut_dim), .lut_thr(lut_thr),
        .flag_dim(fdim), .flag_out(fout), .flag_valid(fvalid),
        .mask(mask), .mask_failsafe(mask_failsafe), .dead(dead), .uncal(uncal),
        .dbg_wcnt_live(zdbg_wl), .dbg_acnt_live(zdbg_al),
        .dbg_wcnt_dead(zdbg_wd), .dbg_acnt_dead(zdbg_ad)
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
