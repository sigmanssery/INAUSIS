`timescale 1ns/1ps
//=============================================================================
// ads_regcheck.v — INAUSIS Phase-1 ADS114S08 SPI diagnostic (v3, alignment)
//
// HISTORY:
//   v1: race-free FSM + original bit engine -> STABLE readback (link OK!) but
//       byte came back 0x28 for a written 0x54 (stable-but-shifted).
//   v2: tried a "deterministic-phase" engine -> ADS stopped responding (all 0).
//       => the ORIGINAL engine timing is what the ADS likes; don't touch the
//          clocking. The misalignment is in WHERE we read the data out of the
//          received word, so fix the CAPTURE, not the SCLK.
//   v3 (this): ORIGINAL engine restored (it makes the ADS respond) + read a
//       register with a KNOWN reset value to pin the read alignment exactly:
//         - DATARATE (0x04) reset value = 0x14  (we do NOT write it)
//         - INPMUX  (0x02) we WRITE 0x54 then read back
//       Both printed as the FULL 24-bit received word so the bit position of
//       the known 0x14 / written 0x54 is directly visible.
//
// READ (read_uart.ps1 @921600):  "DR=hhhhhh MX=hhhhhh"
//   DR low byte == 14 AND MX low byte == 54 -> link+timing+write+read all good,
//                                              関1 fully PASS.
//   0x14 sits shifted inside DR  -> read path off by exactly that many bits
//                                   (I adjust the capture slice, no HW change).
//   DR=000000 / FFFFFF           -> not responding / floating (shouldn't happen
//                                   now — v1 already showed it responds).
//=============================================================================
module ads_regcheck (
    input  wire        clk27,
    input  wire        rst_n,
    output reg         ads_cs_n,
    output reg         ads_sclk,
    output reg         ads_din,
    input  wire        ads_dout,
    input  wire        ads_drdy_n,   // unused
    output reg         ads_start,
    output reg         led_init,
    output reg         led_acq,
    output reg         led_err,
    output wire        uart_tx
);
    //=========================================================================
    // ORIGINAL ads114s08_spi clock divider + byte engine (VERBATIM) + spi_done.
    // 27 MHz / 28 = ~964 kHz. Mode 1: sample MISO on rising, shift MOSI on fall.
    //=========================================================================
    localparam CLK_DIV = 14;
    reg [4:0] clk_cnt;
    reg       sclk_en, sclk_fall;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin clk_cnt<=5'd0; sclk_en<=1'b0; sclk_fall<=1'b0; end
        else begin
            sclk_en<=1'b0; sclk_fall<=1'b0;
            if (clk_cnt==CLK_DIV-1) begin clk_cnt<=5'd0; sclk_en<=1'b1; end
            else if (clk_cnt==(CLK_DIV/2)-1) begin sclk_fall<=1'b1; clk_cnt<=clk_cnt+5'd1; end
            else clk_cnt<=clk_cnt+5'd1;
        end
    end

    reg        spi_start, spi_busy, spi_done;
    reg [23:0] load_data, shift_out, spi_rx;
    reg [5:0]  total_bits, bit_cnt;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            ads_cs_n<=1'b1; ads_sclk<=1'b0; ads_din<=1'b0;
            spi_busy<=1'b0; spi_done<=1'b0; spi_rx<=24'h0;
            bit_cnt<=6'd0; shift_out<=24'h0;
        end else begin
            spi_done <= 1'b0;
            if (spi_start && !spi_busy) begin
                ads_cs_n  <= 1'b0;
                ads_sclk  <= 1'b0;
                bit_cnt   <= total_bits - 6'd1;
                spi_busy  <= 1'b1;
                shift_out <= load_data;
            end
            if (spi_busy) begin
                if (sclk_en) begin
                    ads_sclk <= 1'b1;
                    spi_rx   <= {spi_rx[22:0], ads_dout};
                end
                if (sclk_fall) begin
                    ads_sclk  <= 1'b0;
                    ads_din   <= shift_out[23];
                    shift_out <= {shift_out[22:0], 1'b0};
                    if (bit_cnt==6'd0) begin
                        spi_busy <= 1'b0;
                        ads_cs_n <= 1'b1;
                        spi_done <= 1'b1;
                    end else bit_cnt <= bit_cnt - 6'd1;
                end
            end
        end
    end

    //=========================================================================
    // UART TX (921600) + print engine
    //=========================================================================
    reg        uart_send;
    reg  [7:0] uart_data;
    wire       uart_ready;
    uart_tx_simple #(.CLK_HZ(27_000_000), .BAUD(921600)) u_uart (
        .clk(clk27), .rst_n(rst_n),
        .send(uart_send), .data(uart_data), .ready(uart_ready), .tx(uart_tx)
    );

    function [7:0] hex_char;
        input [3:0] nib;
        begin hex_char = (nib<10) ? (8'h30+nib) : (8'h41+nib-10); end
    endfunction

    reg  [7:0] pbuf [0:31];
    reg  [5:0] plen, pidx;
    reg        print_start, print_busy;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            pidx<=6'd0; print_busy<=1'b0; uart_send<=1'b0; uart_data<=8'd0;
        end else begin
            uart_send<=1'b0;
            if (print_start && !print_busy) begin
                print_busy<=1'b1; pidx<=6'd0;
            end else if (print_busy) begin
                if (uart_ready && !uart_send) begin
                    uart_data<=pbuf[pidx];
                    uart_send<=1'b1;
                    if (pidx==plen-1) print_busy<=1'b0;
                    else pidx<=pidx+6'd1;
                end
            end
        end
    end

    //=========================================================================
    // MAIN FSM — race-free ISSUE -> WAIT(spi_done) -> capture
    //   RESET -> WREG INPMUX=0x54 -> RREG DATARATE(0x04) -> RREG INPMUX(0x02)
    //=========================================================================
    localparam [4:0]
        S_POR   =5'd0,  S_RST_I =5'd1,  S_RST_GAP=5'd2,
        S_WR_I  =5'd3,  S_DR_I  =5'd4,  S_DR_C   =5'd5,
        S_MX_I  =5'd6,  S_MX_C  =5'd7,  S_BUILD  =5'd8,
        S_PRINT =5'd9,  S_PWAIT =5'd10, S_LOOP   =5'd11, S_WAIT=5'd12;

    reg [4:0]  state, ret_state;
    reg [22:0] delay_cnt;
    reg [23:0] drw, mxw;
    reg [7:0]  wval;       // walking-1 write test value

    localparam [22:0] POR_CYC  = 23'd1_350_000;
    localparam [22:0] GAP_CYC  = 23'd270_000;
    localparam [22:0] LOOP_CYC = 23'd5_400_000;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_POR; ret_state<=S_POR; delay_cnt<=23'd0;
            spi_start<=1'b0; load_data<=24'h0; total_bits<=6'd8;
            ads_start<=1'b0; drw<=24'h0; mxw<=24'h0; wval<=8'h01;
            led_init<=1'b1; led_acq<=1'b1; led_err<=1'b1;
            print_start<=1'b0; plen<=6'd0;
        end else begin
            spi_start   <= 1'b0;
            print_start <= 1'b0;
            ads_start   <= 1'b0;

            case (state)
            S_POR: begin
                led_init<=1'b1;
                if (delay_cnt==POR_CYC) begin delay_cnt<=23'd0; state<=S_RST_I; end
                else delay_cnt<=delay_cnt+23'd1;
            end
            S_RST_I: begin
                load_data<={8'h06,16'h0}; total_bits<=6'd8;
                spi_start<=1'b1; ret_state<=S_RST_GAP; state<=S_WAIT;
            end
            S_RST_GAP: begin
                if (delay_cnt==GAP_CYC) begin delay_cnt<=23'd0; state<=S_WR_I; end
                else delay_cnt<=delay_cnt+23'd1;
            end
            S_WR_I: begin     // WREG DATARATE(0x04)=0x1A  (reset is 0x14; trusted reg)
                load_data<={8'h44,8'h00,8'h1A}; total_bits<=6'd25;
                spi_start<=1'b1; ret_state<=S_DR_I; state<=S_WAIT;
            end
            S_DR_I: begin     // RREG DATARATE(0x04) — should now read 0x1A if write OK
                load_data<={8'h24,8'h00,8'h00}; total_bits<=6'd25;
                spi_start<=1'b1; ret_state<=S_DR_C; state<=S_WAIT;
            end
            S_DR_C: begin drw<=spi_rx; state<=S_MX_I; end
            S_MX_I: begin     // RREG ID(0x00) — reference
                load_data<={8'h20,8'h00,8'h00}; total_bits<=6'd25;
                spi_start<=1'b1; ret_state<=S_MX_C; state<=S_WAIT;
            end
            S_MX_C: begin mxw<=spi_rx; state<=S_BUILD; end
            S_BUILD: begin
                led_init<=1'b0;
                led_err <= (drw[7:0]==8'h1A) ? 1'b1:1'b0;   // ON if write!=0x1A
                pbuf[0]<="D";pbuf[1]<="R";pbuf[2]<="=";
                pbuf[3]<=hex_char(drw[23:20]);pbuf[4]<=hex_char(drw[19:16]);
                pbuf[5]<=hex_char(drw[15:12]);pbuf[6]<=hex_char(drw[11:8]);
                pbuf[7]<=hex_char(drw[7:4]);  pbuf[8]<=hex_char(drw[3:0]);
                pbuf[9]<=" ";
                pbuf[10]<="I";pbuf[11]<="D";pbuf[12]<="=";
                pbuf[13]<=hex_char(mxw[23:20]);pbuf[14]<=hex_char(mxw[19:16]);
                pbuf[15]<=hex_char(mxw[15:12]);pbuf[16]<=hex_char(mxw[11:8]);
                pbuf[17]<=hex_char(mxw[7:4]);  pbuf[18]<=hex_char(mxw[3:0]);
                pbuf[19]<=8'h0D; pbuf[20]<=8'h0A;
                plen<=6'd21; state<=S_PRINT;
            end
            S_PRINT: begin print_start<=1'b1; state<=S_PWAIT; end
            S_PWAIT: begin
                if (!print_busy && !print_start) begin
                    led_acq<=~led_acq; state<=S_LOOP;
                end
            end
            S_LOOP: begin
                if (delay_cnt==LOOP_CYC) begin delay_cnt<=23'd0; state<=S_WR_I; end
                else delay_cnt<=delay_cnt+23'd1;
            end
            S_WAIT: begin
                if (spi_done) state<=ret_state;
            end
            default: state<=S_POR;
            endcase
        end
    end
endmodule

//=============================================================================
// uart_tx_simple : minimal 8N1 UART transmitter
//=============================================================================
module uart_tx_simple #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BAUD   = 921600
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       send,
    input  wire [7:0] data,
    output reg        ready,
    output reg        tx
);
    localparam integer DIV = CLK_HZ / BAUD;
    reg [15:0] cnt;
    reg [3:0]  bit_idx;
    reg [9:0]  shifter;
    reg        busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx<=1'b1; ready<=1'b1; busy<=1'b0;
            cnt<=16'd0; bit_idx<=4'd0; shifter<=10'h3FF;
        end else begin
            if (!busy) begin
                tx<=1'b1; ready<=1'b1;
                if (send) begin
                    shifter<={1'b1,data,1'b0};
                    busy<=1'b1; ready<=1'b0; cnt<=16'd0; bit_idx<=4'd0;
                end
            end else begin
                if (cnt==DIV-1) begin
                    cnt<=16'd0; tx<=shifter[0];
                    shifter<={1'b1,shifter[9:1]};
                    bit_idx<=bit_idx+4'd1;
                    if (bit_idx==4'd9) begin busy<=1'b0; ready<=1'b1; end
                end else cnt<=cnt+16'd1;
            end
        end
    end
endmodule
