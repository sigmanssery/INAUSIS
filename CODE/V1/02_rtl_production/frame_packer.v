`timescale 1ns/1ps
//=============================================================================
// frame_packer.v
//
// Assembles the 51-byte tactile frame and computes its CRC-16-CCITT, then
// writes the bytes into the Manchester TX payload buffer and triggers a frame.
//
// 51-byte layout:
//   byte  0-1   preamble marker 0xAA 0x55
//   byte  2-5   timestamp (32-bit incrementing counter, big-endian)
//   byte  6-41  18 dimensions x 2 bytes (DoG value, big-endian, signed)
//   byte 42-44  18-bit attention mask (mask[7:0], mask[15:8], {6'b0,mask[17:16]})
//   byte 45-47  18-bit dead-channel map (dead[7:0], dead[15:8], {6'b0,dead[17:16]})
//   byte 48     status (bit0 = calibrated)
//   byte 49-50  CRC-16-CCITT over bytes 0..48 (big-endian)
//
// `dead` is the per-dimension dead-channel map from zscore_flag_multi: bit d=1
// means dim d's power-on calibration measured zero variance, i.e. that sensor
// channel is disconnected / stuck / broken. It is carried in-band so the SoC
// can distrust those dimensions (a dead dim otherwise reads as a quiet, healthy
// "no-event" channel and would be silently trusted).
//
// INTERFACE:
//   - pulse pack_start with: dog_flat (18x16 = 288 bits), mask (18 bits),
//     dead (18 bits), timestamp (32 bits), status (8 bits)
//   - packer streams 49 bytes through CRC, appends CRC, writes all 51 into the
//     TX buffer via wr_en/wr_addr/wr_data, sets payload_len=51, pulses
//     frame_start_out, then asserts done.
//
// dog_flat layout: dim d occupies dog_flat[d*16 +: 16], d=0..17.
//=============================================================================

module frame_packer (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         pack_start,
    input  wire [287:0] dog_flat,     // 18 dims x 16-bit
    input  wire [17:0]  mask,
    input  wire [17:0]  dead,         // 18-bit dead-channel map
    input  wire [31:0]  timestamp,
    input  wire [7:0]   status,

    // write port to Manchester TX payload buffer
    output reg          wr_en,
    output reg  [5:0]   wr_addr,
    output reg  [7:0]   wr_data,
    output reg  [6:0]   payload_len,
    output reg          frame_start_out,
    output reg          done
);
    // CRC engine
    reg        crc_clr;
    reg  [7:0] crc_data;
    reg        crc_valid;
    wire [15:0] crc_out;
    crc16_ccitt u_crc (
        .clk(clk), .rst_n(rst_n), .clr(crc_clr),
        .data_in(crc_data), .data_valid(crc_valid), .crc_out(crc_out)
    );

    // assemble the 49 header+data bytes (0..48) combinationally by index
    function [7:0] frame_byte;
        input [5:0] idx;
        integer d;
        begin
            if (idx == 6'd0)       frame_byte = 8'hAA;
            else if (idx == 6'd1)  frame_byte = 8'h55;
            else if (idx == 6'd2)  frame_byte = timestamp[31:24];
            else if (idx == 6'd3)  frame_byte = timestamp[23:16];
            else if (idx == 6'd4)  frame_byte = timestamp[15:8];
            else if (idx == 6'd5)  frame_byte = timestamp[7:0];
            else if (idx >= 6'd6 && idx <= 6'd41) begin
                // data region: dim = (idx-6)/2, high byte if even offset
                d = (idx - 6) >> 1;
                if (((idx - 6) & 1) == 0)
                    frame_byte = dog_flat[d*16 + 8 +: 8];  // high byte
                else
                    frame_byte = dog_flat[d*16 +: 8];      // low byte
            end
            else if (idx == 6'd42) frame_byte = mask[7:0];
            else if (idx == 6'd43) frame_byte = mask[15:8];
            else if (idx == 6'd44) frame_byte = {6'b0, mask[17:16]};
            else if (idx == 6'd45) frame_byte = dead[7:0];
            else if (idx == 6'd46) frame_byte = dead[15:8];
            else if (idx == 6'd47) frame_byte = {6'b0, dead[17:16]};
            else if (idx == 6'd48) frame_byte = status;
            else                   frame_byte = 8'h00;
        end
    endfunction

    localparam S_IDLE=4'd0, S_FEED=4'd1, S_CRCWAIT=4'd2, S_CRCSETTLE=4'd3,
               S_CRChi=4'd4, S_CRClo=4'd5, S_LEN=4'd6, S_DONE=4'd7;
    reg [3:0] state;
    reg [15:0] crc_latch;
    reg [5:0] idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; idx<=0;
            wr_en<=0; wr_addr<=0; wr_data<=0; payload_len<=0;
            frame_start_out<=0; done<=0;
            crc_clr<=0; crc_data<=0; crc_valid<=0; crc_latch<=0;
        end else begin
            wr_en           <= 1'b0;
            crc_valid       <= 1'b0;
            frame_start_out <= 1'b0;
            done            <= 1'b0;

            case (state)
            S_IDLE: begin
                if (pack_start) begin
                    crc_clr <= 1'b1;       // reset CRC to 0xFFFF
                    idx     <= 6'd0;
                    state   <= S_FEED;
                end
            end
            // write bytes 0..48 to buffer AND feed them to CRC
            S_FEED: begin
                crc_clr  <= 1'b0;
                wr_en    <= 1'b1;
                wr_addr  <= idx;
                wr_data  <= frame_byte(idx);
                crc_data <= frame_byte(idx);
                crc_valid<= 1'b1;
                if (idx == 6'd48) state <= S_CRCWAIT;
                else idx <= idx + 6'd1;
            end
            // CRC absorbs byte 48 one cycle after its crc_valid; wait one
            // settle cycle, then LATCH the settled CRC so both output bytes
            // come from the same snapshot.
            S_CRCWAIT: begin
                state <= S_CRCSETTLE;
            end
            S_CRCSETTLE: begin
                crc_latch <= crc_out;     // now fully reflects byte 48
                state     <= S_CRChi;
            end
            S_CRChi: begin
                wr_en   <= 1'b1;
                wr_addr <= 6'd49;
                wr_data <= crc_latch[15:8];
                state   <= S_CRClo;
            end
            S_CRClo: begin
                wr_en   <= 1'b1;
                wr_addr <= 6'd50;
                wr_data <= crc_latch[7:0];
                state   <= S_LEN;
            end
            S_LEN: begin
                payload_len     <= 7'd51;
                frame_start_out <= 1'b1;   // trigger Manchester TX
                state           <= S_DONE;
            end
            S_DONE: begin
                done  <= 1'b1;
                state <= S_IDLE;
            end
            endcase
        end
    end
endmodule
