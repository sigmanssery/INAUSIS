`timescale 1ns/1ps
//=============================================================================
// ttcgs_sys.v
//
// Full BIDIRECTIONAL system top (production intent), wiring the complete
// closed loop on a single wire:
//
//   raw samples --> dsp_chain (DoG + z-score flag) --> mask / dead / 18-dim DoG
//               --> frame_packer (51-byte tactile frame + CRC-16)
//               --> halfduplex_ctrl --> [single wire `line`] --> SoC
//                                   <-- SoC reverse LUT-update frame (CRC'd)
//               --> lut_parser --> threshold writes back into the flag engine
//
// Difference from ttcgs_top (which is a forward-only self-test with the RX
// looped back internally): here the link is a real tri-stated single wire to an
// EXTERNAL SoC, the reverse channel is parsed and applied (closing the loop),
// and the fail-safe mask + dead-channel map are exposed for board I/O.
//
// Frame cadence: a tactile frame is launched once per sample period, but only
// while the half-duplex line is idle in its TX phase (dir_state == D_TX), so a
// frame is never started in the middle of a reverse exchange. The ping-pong
// (forward 51 B + reverse control frame + 2 turnarounds) fits within the 1 ms
// period (~66% worst case), so the line is back in TX before the next period.
//=============================================================================

module ttcgs_sys #(
    parameter N_CH    = 6,
    parameter CH_BITS = 3,
    parameter N_DIM   = 18,
    parameter DIM_BITS= 5
)(
    input  wire                clk,
    input  wire                rst_n,
    // raw sample stream (one channel at a time)
    input  wire [CH_BITS-1:0]  ch_id,
    input  wire signed [15:0]  sample_in,
    input  wire                sample_valid,
    input  wire                period_end,    // pulse after last channel of a period
    input  wire [31:0]         timestamp,

    // single-wire half-duplex link to the SoC (tri-stated, board pull resistor)
    inout  wire                line,

    // observability / board I/O
    output wire [N_DIM-1:0]    mask,          // active-high (1 = event)
    output wire [N_DIM-1:0]    mask_failsafe, // active-low  (0 = event); GPIO needs pull-down
    output wire [N_DIM-1:0]    dead,          // 1 = dim's calibration found var=0
    output wire [1:0]          dir_state      // 0=TX,1=TURN1,2=RX,3=TURN2
);
    localparam D_TX = 2'd0;

    //------------------------------------------------------------------ DSP chain
    wire [DIM_BITS-1:0] lut_dim;
    wire [31:0]         lut_thr;
    wire                lut_wr;
    wire [N_DIM-1:0]    chain_mask, chain_mask_fs, chain_dead;
    wire [N_DIM*16-1:0] chain_dog_flat;
    wire                chain_busy;

    dsp_chain #(.N_CH(N_CH), .CH_BITS(CH_BITS), .N_DIM(N_DIM), .DIM_BITS(DIM_BITS)) u_chain (
        .clk(clk), .rst_n(rst_n),
        .ch_id(ch_id), .sample_in(sample_in), .sample_valid(sample_valid),
        .lut_wr(lut_wr), .lut_dim(lut_dim), .lut_thr(lut_thr),   // reverse-channel writes
        .mask(chain_mask), .mask_failsafe(chain_mask_fs), .dead(chain_dead),
        .dog_flat(chain_dog_flat), .chain_busy(chain_busy)
    );
    assign mask          = chain_mask;
    assign mask_failsafe = chain_mask_fs;
    assign dead          = chain_dead;

    //------------------------------------------------------- frame launch trigger
    // Snapshot a frame one cycle after period_end, once the chain is idle AND the
    // line is free in its TX phase (so we never start mid-reverse-exchange).
    reg pack_start, period_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pack_start <= 1'b0; period_pending <= 1'b0;
        end else begin
            pack_start <= 1'b0;
            if (period_end) period_pending <= 1'b1;
            else if (period_pending && !chain_busy && (dir_state == D_TX)) begin
                pack_start     <= 1'b1;
                period_pending <= 1'b0;
            end
        end
    end

    //--------------------------------------------------------------- frame packer
    wire       pk_wr_en;  wire [5:0] pk_wr_addr; wire [7:0] pk_wr_data;
    wire [6:0] pk_len;    wire pk_fstart, pk_done;

    frame_packer u_pk (
        .clk(clk), .rst_n(rst_n), .pack_start(pack_start),
        .dog_flat(chain_dog_flat), .mask(chain_mask), .dead(chain_dead),
        .timestamp(timestamp), .status({7'b0, 1'b1}),
        .wr_en(pk_wr_en), .wr_addr(pk_wr_addr), .wr_data(pk_wr_data),
        .payload_len(pk_len), .frame_start_out(pk_fstart), .done(pk_done)
    );

    //------------------------------------------------- half-duplex single-wire link
    wire [7:0] rev_byte; wire rev_valid, rev_frame_done, rev_crc_ok;

    halfduplex_ctrl #(.HALF_CLKS(8), .TURN_CLKS(16)) u_hd (
        .clk(clk), .rst_n(rst_n), .line(line),
        .fwd_wr_en(pk_wr_en), .fwd_wr_addr(pk_wr_addr), .fwd_wr_data(pk_wr_data),
        .fwd_len(pk_len), .fwd_start(pk_fstart),
        .rev_byte(rev_byte), .rev_valid(rev_valid),
        .rev_frame_done(rev_frame_done), .rev_crc_ok(rev_crc_ok),
        .dir_state(dir_state)
    );

    //------------------------------------------------ reverse LUT-update parser
    lut_parser #(.DIM_BITS(DIM_BITS)) u_lp (
        .clk(clk), .rst_n(rst_n),
        .rev_byte(rev_byte), .rev_valid(rev_valid),
        .rev_frame_done(rev_frame_done), .rev_crc_ok(rev_crc_ok),
        .lut_wr(lut_wr), .lut_dim(lut_dim), .lut_thr(lut_thr)
    );

endmodule
