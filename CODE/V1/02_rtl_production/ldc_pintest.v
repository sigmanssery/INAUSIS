`timescale 1ns/1ps
//=============================================================================
// ldc_pintest.v — INAUSIS Phase-1 LDC bring-up PIN DRIVER test (no PulseView)
//
// WHY: the LDC CHIP_ID read returns 0xFF = MISO stuck HIGH the whole transfer
// = the LDC never drives SDO low. That is NOT a SPI timing/edge bug (0xD4 has
// zeros; a timing bug gives a shifted/garbled value, not pure FF). With wiring
// (CSB/SCLK/SDI/SDO all ~0 ohm) and power (VDD=3.36V) already confirmed good,
// 0xFF means either (a) the FPGA isn't actually driving CS/SCLK/SDI on pins
// 33/34/35, or (b) the LDC chip isn't responding.
//
// This test drives each SPI OUTPUT pin as a SLOW, DISTINCT square wave so you
// can confirm with a MULTIMETER (DC volts, pin-to-GND) that the FPGA really
// toggles them:
//     pin 33 (CSB)  ~1.24 s per half  (slowest)
//     pin 34 (SCLK) ~0.62 s per half  (medium)
//     pin 35 (SDI)  ~0.31 s per half  (fastest)
// A DRIVEN pin's DMM reading swings between ~0 V and ~3.3 V at that rate.
// A pin STUCK at 0 V or 3.3 V is NOT being driven => bitstream/pin-mapping
// problem on that pin (found it). If all three swing => FPGA output side is
// fine => the problem is the LDC chip (dead / wrong part / missing condition)
// => next step is a logic-analyzer capture or swapping the part.
//
//   led_init : heartbeat blink  = FPGA alive
//   led_acq  : mirrors live SDO (LED ON = SDO low ; OFF = SDO floating high)
//   uart_tx  : prints "SDO=x" ~1.6x/s (x = MISO level; stuck '1' = the FF case)
//
// Same ports/pins as ldc1101_bringup_trace, so ldc_bringup.cst is reused.
//=============================================================================
module ldc_pintest (
    input  wire clk27,
    input  wire rst_n,
    output reg  ldc_cs_n,    // pin 33
    output reg  ldc_sclk,    // pin 34
    output reg  ldc_sdi,     // pin 35
    input  wire ldc_sdo,     // pin 40
    output reg  led_init,    // pin 10
    output reg  led_acq,     // pin 11
    output reg  led_err,     // pin 13
    output wire uart_tx      // pin 17
);
    //--------------------------------------------------------------------
    // free-running tick @ 27 MHz
    //--------------------------------------------------------------------
    reg [26:0] tick;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) tick <= 27'd0;
        else        tick <= tick + 27'd1;
    end

    //--------------------------------------------------------------------
    // slow, distinct square waves on the 3 SPI outputs (DMM-observable)
    //--------------------------------------------------------------------
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            ldc_cs_n <= 1'b1; ldc_sclk <= 1'b0; ldc_sdi <= 1'b0;
            led_init <= 1'b1; led_acq <= 1'b1; led_err <= 1'b1;
        end else begin
            ldc_cs_n <= tick[25];   // ~1.24 s half-period (slowest)
            ldc_sclk <= tick[24];   // ~0.62 s
            ldc_sdi  <= tick[23];   // ~0.31 s (fastest)
            led_init <= tick[24];   // heartbeat blink = alive
            led_acq  <= ldc_sdo;    // mirror MISO (ON=SDO low ; OFF=floating high)
            led_err  <= 1'b1;       // off
        end
    end

    //--------------------------------------------------------------------
    // UART heartbeat: "SDO=x\r\n"
    //--------------------------------------------------------------------
    reg        uart_send;
    reg  [7:0] uart_data;
    wire       uart_ready;
    uart_tx_simple #(.CLK_HZ(27_000_000), .BAUD(921600)) u_uart (
        .clk(clk27), .rst_n(rst_n),
        .send(uart_send), .data(uart_data), .ready(uart_ready), .tx(uart_tx)
    );

    reg        tick22_d;
    wire       fire = tick[22] & ~tick22_d;   // ~ every 0.62 s
    reg [2:0]  sidx;
    reg        printing;
    reg [7:0]  msg [0:6];

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            tick22_d<=1'b0; uart_send<=1'b0; uart_data<=8'd0;
            sidx<=3'd0; printing<=1'b0;
        end else begin
            tick22_d  <= tick[22];
            uart_send <= 1'b0;
            if (fire && !printing) begin
                msg[0]<="S"; msg[1]<="D"; msg[2]<="O"; msg[3]<="=";
                msg[4]<= ldc_sdo ? "1" : "0";
                msg[5]<=8'h0D; msg[6]<=8'h0A;
                sidx<=3'd0; printing<=1'b1;
            end else if (printing) begin
                if (uart_ready && !uart_send) begin
                    uart_data <= msg[sidx];
                    uart_send <= 1'b1;
                    if (sidx==3'd6) printing<=1'b0;
                    else sidx<=sidx+3'd1;
                end
            end
        end
    end
endmodule

//=============================================================================
// uart_tx_simple : minimal 8N1 UART transmitter (same as the bring-up builds)
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
