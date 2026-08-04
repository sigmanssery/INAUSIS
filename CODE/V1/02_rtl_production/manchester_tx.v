`timescale 1ns/1ps
//=============================================================================
// manchester_tx.v  (v2 - buffered payload, no handshake race)
//
// Frame-level Manchester transmitter: PREAMBLE + SFD + payload, each byte
// Manchester-encoded (IEEE 802.3).
//
// Payload is delivered via a small internal buffer (no dynamic req/valid
// handshake, which was race-prone). The caller writes payload bytes into the
// buffer before asserting frame_start; the TX then streams preamble, SFD, and
// the buffered payload bytes by itself.
//
// USAGE:
//   1. write payload: pulse wr_en with wr_data for each byte (wr_addr auto or
//      provided). Set payload_len = number of payload bytes.
//   2. pulse frame_start.
//   3. TX sends PREAMBLE_LEN x 0x55, SFD (0xD5), then payload_len bytes.
//   4. frame_done pulses when finished.
//=============================================================================

module manchester_tx #(
    parameter HALF_CLKS    = 8,
    parameter PREAMBLE_LEN = 4,
    parameter SFD          = 8'hD5,
    parameter MAX_PAYLOAD  = 64,
    parameter PAY_AW       = 6      // ceil(log2(MAX_PAYLOAD))
)(
    input  wire                clk,
    input  wire                rst_n,
    // payload buffer write port
    input  wire                wr_en,
    input  wire [PAY_AW-1:0]   wr_addr,
    input  wire [7:0]          wr_data,
    input  wire [PAY_AW:0]     payload_len,   // number of payload bytes
    // frame control
    input  wire                frame_start,
    output wire                data_line,
    output reg                 tx_active,
    output reg                 frame_done
);
    // payload buffer
    reg [7:0] pbuf [0:MAX_PAYLOAD-1];
    always @(posedge clk) if (wr_en) pbuf[wr_addr] <= wr_data;

    // byte encoder
    reg  [7:0] enc_byte; reg enc_start;
    wire enc_busy, enc_ready;
    manchester_enc #(.HALF_CLKS(HALF_CLKS)) u_enc (
        .clk(clk), .rst_n(rst_n),
        .tx_byte(enc_byte), .tx_start(enc_start),
        .data_line(data_line), .tx_busy(enc_busy), .tx_ready(enc_ready)
    );

    localparam S_IDLE=3'd0, S_PRE=3'd1, S_SFD=3'd2, S_PAY=3'd3,
               S_WAIT=3'd4, S_DONE=3'd5, S_WAIT2=3'd6;
    reg [2:0]      state, ret;
    reg [7:0]      pre_cnt;
    reg [PAY_AW:0] pay_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_IDLE; ret<=S_IDLE; pre_cnt<=0; pay_idx<=0;
            enc_byte<=0; enc_start<=0; tx_active<=0; frame_done<=0;
        end else begin
            enc_start  <= 1'b0;
            frame_done <= 1'b0;
            case (state)
            S_IDLE: begin
                tx_active <= 1'b0;
                if (frame_start) begin
                    tx_active <= 1'b1;
                    pre_cnt   <= 0;
                    pay_idx   <= 0;
                    state     <= S_PRE;
                end
            end
            // preamble: PREAMBLE_LEN x 0x55
            S_PRE: begin
                enc_byte  <= 8'h55;
                enc_start <= 1'b1;
                ret       <= (pre_cnt == PREAMBLE_LEN-1) ? S_SFD : S_PRE;
                pre_cnt   <= pre_cnt + 8'd1;
                state     <= S_WAIT;
            end
            // SFD
            S_SFD: begin
                enc_byte  <= SFD;
                enc_start <= 1'b1;
                ret       <= S_PAY;
                state     <= S_WAIT;
            end
            // payload from buffer
            S_PAY: begin
                if (pay_idx == payload_len) begin
                    state <= S_DONE;
                end else begin
                    enc_byte  <= pbuf[pay_idx[PAY_AW-1:0]];
                    enc_start <= 1'b1;
                    pay_idx   <= pay_idx + 1'b1;
                    ret       <= S_PAY;
                    state     <= S_WAIT;
                end
            end
            // wait for byte encoder
            S_WAIT: begin
                if (enc_busy) state <= S_WAIT2;
            end
            S_WAIT2: begin
                if (enc_ready) state <= ret;
            end
            S_DONE: begin
                frame_done <= 1'b1;
                tx_active  <= 1'b0;
                state      <= S_IDLE;
            end
            endcase
        end
    end
endmodule
