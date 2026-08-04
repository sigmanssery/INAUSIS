`timescale 1ns/1ps
//=============================================================================
// manchester_enc.v
//
// Manchester encoder, IEEE 802.3 convention:
//   bit = 0  ->  HIGH then LOW   (falling edge mid-bit)
//   bit = 1  ->  LOW  then HIGH  (rising  edge mid-bit)
// Each bit = 2 half-bits; each half-bit = HALF_CLKS clock cycles.
//
// The mid-bit transition carries BOTH the data (its direction) and the clock
// (its presence), so no separate clock line is needed -- this is why Manchester
// was chosen for the single-wire joint-crossing link.
//
// INTERFACE:
//   - assert tx_start with tx_byte to send one byte (MSB first)
//   - tx_busy high while sending; data_line is the Manchester output
//   - tx_ready pulses when ready for the next byte
//=============================================================================

module manchester_enc #(
    parameter HALF_CLKS = 8     // clock cycles per half-bit
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] tx_byte,
    input  wire       tx_start,
    output reg        data_line,   // Manchester-encoded output
    output reg        tx_busy,
    output reg        tx_ready
);

    localparam IDLE=2'd0, FIRST=2'd1, SECOND=2'd2;
    reg [1:0]  state;
    reg [7:0]  shift;
    reg [2:0]  bit_idx;      // 0..7
    reg [15:0] half_cnt;     // counts clocks within a half-bit
    reg        cur_bit;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            data_line <= 1'b1;     // idle line high (will be pulled appropriately)
            tx_busy   <= 1'b0;
            tx_ready  <= 1'b1;
            shift     <= 8'd0;
            bit_idx   <= 3'd0;
            half_cnt  <= 16'd0;
            cur_bit   <= 1'b0;
        end else begin
            tx_ready <= 1'b0;
            case (state)
            //-----------------------------------------------------------------
            IDLE: begin
                tx_busy <= 1'b0;
                tx_ready<= 1'b1;
                if (tx_start) begin
                    shift   <= tx_byte;
                    bit_idx <= 3'd0;
                    cur_bit <= tx_byte[7];        // MSB first
                    half_cnt<= 16'd0;
                    tx_busy <= 1'b1;
                    tx_ready<= 1'b0;
                    // IEEE: first half of bit. 0 -> HIGH first, 1 -> LOW first
                    data_line <= (tx_byte[7]) ? 1'b0 : 1'b1;
                    state   <= FIRST;
                end
            end
            //-----------------------------------------------------------------
            // FIRST half-bit
            FIRST: begin
                if (half_cnt == HALF_CLKS-1) begin
                    half_cnt  <= 16'd0;
                    // mid-bit transition: flip to second half
                    data_line <= (cur_bit) ? 1'b1 : 1'b0;  // 1->HIGH, 0->LOW
                    state     <= SECOND;
                end else half_cnt <= half_cnt + 16'd1;
            end
            //-----------------------------------------------------------------
            // SECOND half-bit
            SECOND: begin
                if (half_cnt == HALF_CLKS-1) begin
                    half_cnt <= 16'd0;
                    if (bit_idx == 3'd7) begin
                        // byte done
                        state    <= IDLE;
                        tx_busy  <= 1'b0;
                        tx_ready <= 1'b1;
                    end else begin
                        bit_idx <= bit_idx + 3'd1;
                        shift   <= {shift[6:0], 1'b0};
                        cur_bit <= shift[6];
                        // set first half of next bit
                        data_line <= (shift[6]) ? 1'b0 : 1'b1;
                        state   <= FIRST;
                    end
                end else half_cnt <= half_cnt + 16'd1;
            end
            endcase
        end
    end

endmodule
