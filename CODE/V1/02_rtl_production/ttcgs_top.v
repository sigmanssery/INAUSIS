`timescale 1ns/1ps
//=============================================================================
// ttcgs_top.v
//
// Full TTCGS sensing datapath, top-level integration:
//
//   raw samples --> dsp_chain (DoG + flag) --> mask + 18-dim DoG
//               --> frame_packer (48-byte frame + CRC-16-CCITT)
//               --> manchester_tx (single-wire encode)
//               --> [single wire] --> manchester_rx (decode)
//               --> recovered 48-byte frame to the SoC.
//
// Frame trigger: the host streams one sample per channel per sample period.
// After the last channel (ch == N_CH-1) has been processed for a period, the
// top fires pack_start, snapshotting the current mask + dog_flat into a frame.
//
// For this self-test, the RX side is included so the testbench can verify the
// recovered frame end-to-end. On the real device, manchester_rx lives in the
// SoC.
//=============================================================================

module ttcgs_top #(
    parameter N_CH    = 6,
    parameter CH_BITS = 3,
    parameter N_DIM   = 18
)(
    input  wire                clk,
    input  wire                rst_n,
    // raw sample stream
    input  wire [CH_BITS-1:0]  ch_id,
    input  wire signed [15:0]  sample_in,
    input  wire                sample_valid,
    input  wire                period_end,   // pulse after last channel of a period
    input  wire [31:0]         timestamp,
    // recovered output (RX side, would be in SoC)
    output wire [7:0]          rx_byte,
    output wire                rx_valid,
    output wire                rx_locked,
    output wire                rx_sfd,
    // observability
    output wire [N_DIM-1:0]    mask,
    output wire                tx_line
);
    // ---- DSP chain ----
    wire [N_DIM-1:0]    chain_mask, chain_mask_fs, chain_dead;
    wire [N_DIM*16-1:0] chain_dog_flat;
    wire                chain_busy;

    dsp_chain #(.N_CH(N_CH), .CH_BITS(CH_BITS), .N_DIM(N_DIM)) u_chain (
        .clk(clk), .rst_n(rst_n),
        .ch_id(ch_id), .sample_in(sample_in), .sample_valid(sample_valid),
        .lut_wr(1'b0), .lut_dim(5'd0), .lut_thr(32'd0),   // forward-only top
        .mask(chain_mask), .mask_failsafe(chain_mask_fs), .dead(chain_dead),
        .dog_flat(chain_dog_flat), .chain_busy(chain_busy)
    );
    assign mask = chain_mask;

    // ---- frame packer ----
    wire        pk_wr_en;   wire [5:0] pk_wr_addr; wire [7:0] pk_wr_data;
    wire [6:0]  pk_len;     wire pk_fstart, pk_done;
    reg         pack_start;

    // fire pack_start one cycle after period_end, once the chain is idle
    reg period_pending;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pack_start <= 1'b0; period_pending <= 1'b0;
        end else begin
            pack_start <= 1'b0;
            if (period_end) period_pending <= 1'b1;
            else if (period_pending && !chain_busy) begin
                pack_start     <= 1'b1;     // snapshot mask+dog into a frame
                period_pending <= 1'b0;
            end
        end
    end

    frame_packer u_pk (
        .clk(clk), .rst_n(rst_n), .pack_start(pack_start),
        .dog_flat(chain_dog_flat), .mask(chain_mask), .dead(chain_dead),
        .timestamp(timestamp), .status({7'b0, 1'b1}),
        .wr_en(pk_wr_en), .wr_addr(pk_wr_addr), .wr_data(pk_wr_data),
        .payload_len(pk_len), .frame_start_out(pk_fstart), .done(pk_done)
    );

    // ---- Manchester TX ----
    wire tx_active, tx_frame_done;
    manchester_tx #(.HALF_CLKS(8), .PREAMBLE_LEN(4)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .wr_en(pk_wr_en), .wr_addr(pk_wr_addr), .wr_data(pk_wr_data),
        .payload_len(pk_len), .frame_start(pk_fstart),
        .data_line(tx_line), .tx_active(tx_active), .frame_done(tx_frame_done)
    );

    // ---- Manchester RX (SoC side; here for self-test) ----
    manchester_rx #(.HALF_CLKS(8)) u_rx (
        .clk(clk), .rst_n(rst_n), .data_line(tx_line), .rx_enable(1'b1),
        .rx_byte(rx_byte), .rx_valid(rx_valid),
        .locked(rx_locked), .sfd_seen(rx_sfd)
    );
endmodule
