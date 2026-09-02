// frame_uart_mirror.v
//
// Bring-up aid: mirrors the packed frame over a plain 8N1 UART so a host can
// capture what would go onto the Manchester line, without needing a Manchester
// receiver. The Manchester path is untouched; this only observes.
//
// The packer writes its bytes into a buffer by ADDRESS, so this keeps its own
// copy indexed the same way and streams bytes 0..payload_len-1 in order once
// `done` pulses. That makes the mirror independent of the packer's write order.
//
// Wire format per frame:  0xAA 0xA5 <len> <payload_len bytes>
// The two sync bytes let the host re-align after any dropped frame; <len> lets
// it know how many payload bytes follow, and the frame's own CRC-16 (the last
// two payload bytes) validates the capture.
//
// If a frame arrives while the previous one is still going out, this DROPS it
// and increments drop_cnt rather than corrupting the stream. At 921600 baud a
// 54-byte burst takes ~586 us, so frame periods shorter than that will drop.
//
module frame_uart_mirror #(
    parameter BAUD_DIV = 29,      // 27 MHz / 921600 ~= 29
    parameter SYNC0    = 8'hAA,
    parameter SYNC1    = 8'hA5
)(
    input  wire        clk,
    input  wire        rst_n,
    // tap from frame_packer
    input  wire        wr_en,
    input  wire [5:0]  wr_addr,
    input  wire [7:0]  wr_data,
    input  wire [6:0]  payload_len,
    input  wire        done,
    // UART pin
    output reg         uart_tx,
    output reg [7:0]   drop_cnt
);
    // ---- shadow copy, double-buffered --------------------------------------
    // The packer keeps writing while we stream. With one buffer the two
    // overlap and the frame goes out as a mix of old and new bytes, which is
    // what produced the 17.6% CRC failures on the first capture. Writes always
    // land in fbuf[wsel]; streaming always reads fbuf[~wsel]; the halves swap
    // only when a frame completes and we are idle.
    reg [7:0] fbuf [0:127];
    reg       wsel;
    always @(posedge clk) if (wr_en) fbuf[{wsel, wr_addr}] <= wr_data;

    // ---- byte-level 8N1 transmitter ---------------------------------------
    reg [12:0] baud_cnt;
    reg [3:0]  bit_idx;
    reg [9:0]  shifter;        // {stop, data[7:0], start}
    reg        tx_busy;

    // ---- frame streamer ----------------------------------------------------
    localparam S_IDLE=2'd0, S_LOAD=2'd1, S_SEND=2'd2;
    reg [1:0]  st;
    reg [6:0]  idx, len_l;
    reg [7:0]  nextb;
    reg        push;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            uart_tx<=1'b1; tx_busy<=0; baud_cnt<=0; bit_idx<=0; shifter<=10'h3FF;
            st<=S_IDLE; idx<=0; len_l<=0; push<=0; nextb<=0; drop_cnt<=0; wsel<=1'b0;
        end else begin
            push <= 1'b0;

            // ---- transmitter ----
            if (tx_busy) begin
                if (baud_cnt == BAUD_DIV-1) begin
                    baud_cnt <= 0;
                    uart_tx  <= shifter[0];
                    shifter  <= {1'b1, shifter[9:1]};
                    if (bit_idx == 4'd9) tx_busy <= 1'b0;
                    else                 bit_idx <= bit_idx + 4'd1;
                end else baud_cnt <= baud_cnt + 13'd1;
            end else if (push) begin
                shifter  <= {1'b1, nextb, 1'b0};   // stop, data, start
                bit_idx  <= 0; baud_cnt <= 0; tx_busy <= 1'b1;
            end

            // ---- streamer ----
            case (st)
            S_IDLE: if (done) begin
                        if (payload_len == 0) ;                  // nothing to send
                        else begin
                            len_l <= payload_len; idx <= 0; wsel <= ~wsel; st <= S_LOAD;
                        end
                    end
            S_LOAD: if (!tx_busy && !push) begin                 // sync0, sync1, len
                        nextb <= (idx==0) ? SYNC0 : (idx==1) ? SYNC1 : {1'b0,len_l};
                        push  <= 1'b1;
                        if (idx == 2) begin idx <= 0; st <= S_SEND; end
                        else idx <= idx + 7'd1;
                    end
            S_SEND: begin
                        if (!tx_busy && !push) begin
                            nextb <= fbuf[{~wsel, idx[5:0]}];
                            push  <= 1'b1;
                            if (idx == len_l-1) begin idx <= 0; st <= S_IDLE; end
                            else idx <= idx + 7'd1;
                        end
                        if (done) drop_cnt <= drop_cnt + 8'd1;   // frame arrived mid-send
                    end
            default: st <= S_IDLE;
            endcase
        end
    end
endmodule
