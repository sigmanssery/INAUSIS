// top_bringup.v
// Phase 1 bring-up top module
// Purpose: verify ADS114S08 SPI communication + DRDY# behaviour
// Output: "CH0: XXXX\r\n" ... "CH3: XXXX\r\n" over UART at 921600 baud
//
// LED indicators (active-low, 1.8V):
//   led_init : OFF during init, ON after init_done
//   led_acq  : blinks on each data_valid pulse
//   led_err  : ON if error state

module top_bringup (
    input  wire clk27,      // pin 52, 27 MHz

    input  wire rst_n,      // pin 4, S2 button, active-low

    // LEDs (active-low)
    output wire led_init,   // pin 10
    output wire led_acq,    // pin 11
    output wire led_err,    // pin 13

    // ADS114S08 SPI Bus A
    output wire ads_cs_n,   // pin 25
    output wire ads_sclk,   // pin 26
    output wire ads_din,    // pin 27
    input  wire ads_dout,   // pin 28
    input  wire ads_drdy_n, // pin 29
    output wire ads_start,  // pin 30

    // LDC1101 SPI Bus B (hold CS high for now — not used in Phase 1)
    output wire ldc_cs_n,   // pin 33
    output wire ldc_sclk,   // pin 34
    output wire ldc_sdi,    // pin 35
    input  wire ldc_sdo,    // pin 40 (unused input)

    // UART TX
    output wire uart_tx     // pin 17
);

// ─── LDC idle (CS high, clock low, MOSI low) ────────────────────────────────
assign ldc_cs_n = 1'b1;
assign ldc_sclk = 1'b0;
assign ldc_sdi  = 1'b0;

// ─── ADS114S08 SPI master ───────────────────────────────────────────────────
wire        data_valid;
wire [15:0] data_out;
wire [1:0]  ch_out;
wire        init_done;
wire        err_flag_ads;

ads114s08_spi u_ads (
    .clk        (clk27),
    .rst_n      (rst_n),
    .ads_cs_n   (ads_cs_n),
    .ads_sclk   (ads_sclk),
    .ads_din    (ads_din),
    .ads_dout   (ads_dout),
    .ads_drdy_n (ads_drdy_n),
    .ads_start  (ads_start),
    .data_valid (data_valid),
    .data_out   (data_out),
    .ch_out     (ch_out),
    .init_done  (init_done),
    .err_flag   (err_flag_ads)
);

// ─── UART TX ─────────────────────────────────────────────────────────────────
uart_tx_simple u_uart (
    .clk        (clk27),
    .rst_n      (rst_n),
    .data_valid (data_valid),
    .data_in    (data_out),
    .ch_in      (ch_out),
    .uart_tx    (uart_tx)
);

// ─── LED indicators ──────────────────────────────────────────────────────────
// Active-low LEDs on 1.8V bank
assign led_init = ~init_done;      // ON after init complete

// led_acq blinks on data_valid
reg [19:0] acq_cnt;
reg        acq_led;
always @(posedge clk27 or negedge rst_n) begin
    if (!rst_n) begin
        acq_cnt <= 0;
        acq_led <= 0;
    end else if (data_valid) begin
        acq_cnt <= 20'd270000; // ~10 ms blink @ 27 MHz
        acq_led <= 1;
    end else if (acq_cnt > 0) begin
        acq_cnt <= acq_cnt - 1;
    end else begin
        acq_led <= 0;
    end
end
assign led_acq = ~acq_led;

assign led_err = ~err_flag_ads;

endmodule
