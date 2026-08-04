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
    parameter FRAC     = 15
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
    reg signed [38:0]    acc;
    reg signed [15:0]    g_result [0:2];

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
                g_result[scale] <= acc >>> FRAC;
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
                DoG_fast <= g_result[0] - g_result[1];
                DoG_slow <= g_result[1] - g_result[2];
                ch_done  <= cur_ch;
                result_valid <= 1'b1;
                state    <= IDLE;
            end
            endcase
        end
    end

endmodule
