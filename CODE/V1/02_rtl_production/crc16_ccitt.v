`timescale 1ns/1ps
//=============================================================================
// crc16_ccitt.v
//
// CRC-16-CCITT (polynomial 0x1021, init 0xFFFF, MSB-first, no final XOR,
// no reflection) -- the "false CCITT" / 0xFFFF-init variant whose standard
// check value over the ASCII string "123456789" is 0x29B1.
//
// Fed one byte at a time. Assert `clr` to reset CRC to 0xFFFF, then pulse
// `data_valid` with each `data_in` byte; `crc_out` holds the running CRC.
//
// Used by the frame packer to protect the 48-byte tactile frame: the SoC
// recomputes the CRC and discards any frame whose CRC does not match,
// guarding the Manchester link against noise / phase glitches.
//=============================================================================

module crc16_ccitt (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        clr,         // synchronous: reset CRC to 0xFFFF
    input  wire [7:0]  data_in,
    input  wire        data_valid,  // 1-clk: absorb data_in into CRC
    output reg  [15:0] crc_out
);
    integer i;
    reg [15:0] crc;          // CRC register (nonblocking only)
    reg [15:0] crc_nx;       // combinational next-value

    // combinational: compute next CRC from current crc + incoming byte
    always @(*) begin
        crc_nx = crc ^ {data_in, 8'h00};   // XOR byte into high bits
        for (i=0; i<8; i=i+1) begin
            if (crc_nx[15]) crc_nx = (crc_nx << 1) ^ 16'h1021;
            else            crc_nx = (crc_nx << 1);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            crc     <= 16'hFFFF;
            crc_out <= 16'hFFFF;
        end else begin
            if (clr) begin
                crc     <= 16'hFFFF;
                crc_out <= 16'hFFFF;
            end else if (data_valid) begin
                crc     <= crc_nx;   // nonblocking only -- no style hazard
                crc_out <= crc_nx;
            end
        end
    end
endmodule
