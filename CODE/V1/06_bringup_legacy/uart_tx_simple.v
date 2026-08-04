// uart_tx_simple.v
// Minimal UART TX for bring-up
// Outputs: "CHx: XXXX\r\n" where x=channel, XXXX=hex ADC value
// Baud: 921600, Clock: 27 MHz
// Divider: 27,000,000 / 921,600 = ~29.3 → use 29

module uart_tx_simple (
    input  wire        clk,
    input  wire        rst_n,

    // from ADS SPI master
    input  wire        data_valid,
    input  wire [15:0] data_in,
    input  wire [1:0]  ch_in,

    // UART pin
    output reg         uart_tx
);

localparam BAUD_DIV = 29;  // 27 MHz / 921600 ≈ 29

// ─── Baud clock ─────────────────────────────────────────────────────────────
reg [5:0] baud_cnt;
reg       baud_tick;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        baud_cnt  <= 0;
        baud_tick <= 0;
    end else begin
        baud_tick <= 0;
        if (baud_cnt == BAUD_DIV - 1) begin
            baud_cnt  <= 0;
            baud_tick <= 1;
        end else begin
            baud_cnt <= baud_cnt + 1;
        end
    end
end

// ─── Hex nibble to ASCII ─────────────────────────────────────────────────────
function [7:0] nibble_to_ascii;
    input [3:0] n;
    nibble_to_ascii = (n < 10) ? (8'h30 + n) : (8'h41 + n - 10);
endfunction

// ─── Message buffer ──────────────────────────────────────────────────────────
// Format: "CH0: ABCD\r\n" = 11 bytes
reg [7:0] msg [0:10];
reg [3:0] msg_len;
reg [3:0] byte_idx;
reg [3:0] bit_idx;
reg       tx_busy;
reg [7:0] tx_byte;

// Build message when data_valid arrives
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tx_busy  <= 0;
        byte_idx <= 0;
        bit_idx  <= 0;
        uart_tx  <= 1;
        msg[0] <= "C";
        msg[1] <= "H";
        msg[2] <= "0";
        msg[3] <= ":";
        msg[4] <= " ";
        msg[5] <= "0";
        msg[6] <= "0";
        msg[7] <= "0";
        msg[8] <= "0";
        msg[9] <= 8'h0D; // CR
        msg[10]<= 8'h0A; // LF
        msg_len <= 11;
    end else begin

        // Latch new message when valid and not busy
        if (data_valid && !tx_busy) begin
            msg[0] <= "C";
            msg[1] <= "H";
            msg[2] <= 8'h30 + {6'b0, ch_in};  // '0'-'3'
            msg[3] <= ":";
            msg[4] <= " ";
            msg[5] <= nibble_to_ascii(data_in[15:12]);
            msg[6] <= nibble_to_ascii(data_in[11:8]);
            msg[7] <= nibble_to_ascii(data_in[7:4]);
            msg[8] <= nibble_to_ascii(data_in[3:0]);
            msg[9] <= 8'h0D;
            msg[10]<= 8'h0A;
            tx_busy  <= 1;
            byte_idx <= 0;
            bit_idx  <= 0;
        end

        // Transmit
        if (tx_busy && baud_tick) begin
            if (bit_idx == 0) begin
                // start bit
                tx_byte  <= msg[byte_idx];
                uart_tx  <= 1'b0;
                bit_idx  <= 1;
            end else if (bit_idx <= 8) begin
                // data bits LSB first
                uart_tx <= tx_byte[bit_idx - 1];
                bit_idx <= bit_idx + 1;
            end else begin
                // stop bit
                uart_tx <= 1'b1;
                bit_idx <= 0;
                if (byte_idx == msg_len - 1) begin
                    tx_busy  <= 0;
                    byte_idx <= 0;
                end else begin
                    byte_idx <= byte_idx + 1;
                end
            end
        end

    end
end

endmodule
