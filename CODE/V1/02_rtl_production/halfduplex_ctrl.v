`timescale 1ns/1ps
//=============================================================================
// halfduplex_ctrl.v
//
// Single-wire half-duplex ping-pong controller (FPGA side).
//
// PROTOCOL (your design): FPGA transmits a tactile frame, then immediately
// turns to receive; the SoC receives, then immediately turns to transmit a
// control frame (LUT update), then turns back to receive. Both ends alternate
// strictly. Frame boundaries are delimited by a LENGTH byte (first payload
// byte after SFD) so the receiver knows exactly when a frame ends and it is
// time to turn the line around.
//
// LINE: single wire, tri-stated. drive_en=1 -> FPGA drives (tx_bit); drive_en=0
// -> FPGA releases (high-Z), listening. A pull resistor on the board defines
// the idle level during turnaround.
//
// TURNAROUND: a short gap (TURN_CLKS) between releasing and the other end
// driving, so the two ends never drive simultaneously.
//
// This module wires together manchester_tx (forward) and manchester_rx
// (reverse) and sequences the direction. The tactile frame is supplied by the
// frame_packer (via the TX buffer); the received LUT-update frame is exposed
// for the flag engine to apply.
//=============================================================================

module halfduplex_ctrl #(
    parameter HALF_CLKS = 8,
    parameter TURN_CLKS = 16    // turnaround guard (~1 bit time)
)(
    input  wire        clk,
    input  wire        rst_n,

    // single wire (tri-state)
    inout  wire        line,

    // forward (tactile) frame: written into TX buffer by frame_packer
    input  wire        fwd_wr_en,
    input  wire [5:0]  fwd_wr_addr,
    input  wire [7:0]  fwd_wr_data,
    input  wire [6:0]  fwd_len,
    input  wire        fwd_start,      // pulse: begin a forward frame (+ping-pong)

    // reverse (LUT update) frame: bytes recovered from SoC
    output reg  [7:0]  rev_byte,
    output reg         rev_valid,      // pulses per received reverse PAYLOAD byte
                                       // (LENGTH + entries; the 2 CRC bytes are
                                       //  consumed here, NOT forwarded)
    output reg         rev_frame_done, // pulses when a full reverse frame received
    output reg         rev_crc_ok,     // valid with rev_frame_done: 1 = reverse
                                       // frame CRC matched. lut_parser MUST gate
                                       // its threshold writes on this.

    output reg  [1:0]  dir_state       // 0=TX,1=TURN1,2=RX,3=TURN2 (observability)
);
    //=========================================================================
    // Tri-state line
    //=========================================================================
    reg  drive_en;
    wire tx_line_w;          // from manchester_tx
    wire line_in = line;     // sampled input when listening
    assign line = drive_en ? tx_line_w : 1'bz;

    //=========================================================================
    // Forward TX (manchester_tx) - drives line when drive_en
    //=========================================================================
    wire tx_active, tx_frame_done;
    reg  tx_start_r;
    manchester_tx #(.HALF_CLKS(HALF_CLKS), .PREAMBLE_LEN(4)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .wr_en(fwd_wr_en), .wr_addr(fwd_wr_addr), .wr_data(fwd_wr_data),
        .payload_len(fwd_len), .frame_start(tx_start_r),
        .data_line(tx_line_w), .tx_active(tx_active), .frame_done(tx_frame_done)
    );

    //=========================================================================
    // Reverse RX (manchester_rx) - listens when !drive_en
    //=========================================================================
    wire [7:0] rx_byte_w; wire rx_valid_w, rx_locked_w, rx_sfd_w;
    reg        rx_en;
    manchester_rx #(.HALF_CLKS(HALF_CLKS)) u_rx (
        .clk(clk), .rst_n(rst_n), .data_line(line_in), .rx_enable(rx_en),
        .rx_byte(rx_byte_w), .rx_valid(rx_valid_w),
        .locked(rx_locked_w), .sfd_seen(rx_sfd_w)
    );

    //=========================================================================
    // Reverse-frame CRC-16-CCITT check (computed over LENGTH + entry bytes,
    // i.e. everything except the trailing 2 CRC bytes). Same engine/polynomial
    // as the forward path, so the SoC can compute it identically. A reverse
    // frame whose CRC does not match is flagged (rev_crc_ok=0) and the parser
    // discards it -- a bit-flip on the reverse link can no longer corrupt a
    // detection threshold.
    //=========================================================================
    reg         rcrc_clr;
    reg  [7:0]  rcrc_data;
    reg         rcrc_valid;
    wire [15:0] rcrc_out;
    reg  [15:0] rev_crc_rx;     // CRC bytes received from SoC (hi then lo)
    crc16_ccitt u_rcrc (
        .clk(clk), .rst_n(rst_n), .clr(rcrc_clr),
        .data_in(rcrc_data), .data_valid(rcrc_valid), .crc_out(rcrc_out)
    );

    //=========================================================================
    // Direction state machine: ping-pong
    //=========================================================================
    localparam D_TX=2'd0, D_TURN1=2'd1, D_RX=2'd2, D_TURN2=2'd3;
    reg [1:0]  dstate;
    reg [15:0] turn_cnt;

    // reverse frame length tracking (LENGTH byte delimits the frame)
    reg [7:0]  rev_len;        // payload length declared by SoC (LENGTH byte)
    reg [7:0]  rev_cnt;        // reverse bytes received so far
    reg        rev_got_len;    // captured the LENGTH byte yet?

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dstate    <= D_TX;
            drive_en  <= 1'b1;       // start by driving (forward)
            rx_en     <= 1'b0;
            tx_start_r<= 1'b0;
            turn_cnt  <= 16'd0;
            rev_byte  <= 8'd0; rev_valid <= 1'b0; rev_frame_done <= 1'b0;
            rev_len   <= 8'd0; rev_cnt <= 8'd0; rev_got_len <= 1'b0;
            rev_crc_ok<= 1'b0; rev_crc_rx <= 16'd0;
            rcrc_clr  <= 1'b0; rcrc_data <= 8'd0; rcrc_valid <= 1'b0;
            dir_state <= 2'd0;
        end else begin
            tx_start_r     <= 1'b0;
            rev_valid      <= 1'b0;
            rev_frame_done <= 1'b0;
            rcrc_clr       <= 1'b0;
            rcrc_valid     <= 1'b0;
            dir_state      <= dstate;

            case (dstate)
            //-----------------------------------------------------------------
            // TX: drive line, send the forward (tactile) frame
            D_TX: begin
                drive_en <= 1'b1;
                rx_en    <= 1'b0;
                if (fwd_start) tx_start_r <= 1'b1;    // kick off TX
                if (tx_frame_done) begin
                    // forward frame sent -> turn to receive
                    turn_cnt <= 16'd0;
                    dstate   <= D_TURN1;
                end
            end
            //-----------------------------------------------------------------
            // TURN1: release line, wait guard, then listen
            D_TURN1: begin
                drive_en <= 1'b0;     // release (high-Z)
                rx_en    <= 1'b0;
                if (turn_cnt >= TURN_CLKS) begin
                    rx_en       <= 1'b1;       // start listening
                    rev_cnt     <= 8'd0;
                    rev_got_len <= 1'b0;
                    rcrc_clr    <= 1'b1;       // reset reverse CRC for new frame
                    dstate      <= D_RX;
                end else turn_cnt <= turn_cnt + 16'd1;
            end
            //-----------------------------------------------------------------
            // RX: listen for the SoC's reverse frame, delimited by LENGTH byte
            D_RX: begin
                drive_en <= 1'b0;
                rx_en    <= 1'b1;
                if (rx_valid_w) begin
                    if (!rev_got_len) begin
                        // first byte after SFD = LENGTH (number of entry bytes).
                        // forward to parser AND start CRC over it.
                        rev_byte    <= rx_byte_w;
                        rev_valid   <= 1'b1;
                        rev_len     <= rx_byte_w;
                        rev_got_len <= 1'b1;
                        rev_cnt     <= 8'd0;
                        rcrc_data   <= rx_byte_w;
                        rcrc_valid  <= 1'b1;
                    end else if (rev_cnt < rev_len) begin
                        // entry (payload) byte: forward + include in CRC
                        rev_byte   <= rx_byte_w;
                        rev_valid  <= 1'b1;
                        rcrc_data  <= rx_byte_w;
                        rcrc_valid <= 1'b1;
                        rev_cnt    <= rev_cnt + 8'd1;
                    end else if (rev_cnt == rev_len) begin
                        // CRC high byte: capture only (not forwarded, not fed)
                        rev_crc_rx[15:8] <= rx_byte_w;
                        rev_cnt          <= rev_cnt + 8'd1;
                    end else begin
                        // CRC low byte: frame complete -> compare computed vs
                        // received CRC; rev_crc_ok valid with rev_frame_done.
                        rev_crc_ok     <= ({rev_crc_rx[15:8], rx_byte_w} == rcrc_out);
                        rev_frame_done <= 1'b1;
                        turn_cnt       <= 16'd0;
                        dstate         <= D_TURN2;
                    end
                end
            end
            //-----------------------------------------------------------------
            // TURN2: stop listening, wait guard, then back to TX
            D_TURN2: begin
                rx_en <= 1'b0;
                if (turn_cnt >= TURN_CLKS) begin
                    drive_en <= 1'b1;     // reclaim line
                    dstate   <= D_TX;
                end else turn_cnt <= turn_cnt + 16'd1;
            end
            endcase
        end
    end
endmodule
