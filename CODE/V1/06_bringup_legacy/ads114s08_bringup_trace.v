//=============================================================================
// ads114s08_bringup_trace.v
//
// PHASE 1 BRING-UP with UART DEBUG TRACE.
//
// Reads ADS114S08 channels AIN5/AIN4/AIN1/AIN0 (single-ended) and prints
// HUMAN-READABLE diagnostics over UART so you can debug WITHOUT a logic
// analyzer. Open a serial terminal at 460800 baud, 8N1, TEXT mode.
//
// You will see lines like:
//     RST
//     CFG
//     CH0 DRDY=L RD=7F23A1
//     CH1 DRDY=L RD=801244
//     CH2 DRDY=H TIMEOUT
//     ...
//
// DIAGNOSIS GUIDE:
//   "DRDY=H TIMEOUT"  -> DRDY# never went low. The chip isn't converting.
//                        Almost always a HARDWARE problem: cold solder on
//                        DRDY/CS/SCLK, wrong wiring, or chip not powered.
//                        NOT this RTL.
//   "RD=000000"       -> SPI clocks but reads all zeros. MISO not connected,
//                        or chip in wrong state. Check ads_dout (pin 28).
//   "RD=FFFFFF"       -> MISO floating high (pull-up but nothing driving).
//                        Chip not selected or not responding.
//   "RD=<changing sensible values>" -> SUCCESS. SPI link works.
//
// Target  : Tang Nano 9K (GW1NR-LV9), 27 MHz clock
// SPI mode : CPOL=0, CPHA=1 (Mode 1)
// UART     : 460800 baud, 8N1
//=============================================================================

module ads114s08_bringup_trace (
    input  wire clk27,        // 27 MHz oscillator (pin 52)
    input  wire rst_n,        // S2 button, active-low (pin 4)

    // ADS114S08 SPI bus (3.3V Bank 6)
    output reg  ads_cs_n,     // pin 25
    output reg  ads_sclk,     // pin 26
    output reg  ads_din,      // pin 27  MOSI
    input  wire ads_dout,     // pin 28  MISO
    input  wire ads_drdy_n,   // pin 29  DRDY#
    output reg  ads_start,    // pin 30

    // status LEDs (active-low)
    output reg  led_init,     // pin 10
    output reg  led_acq,      // pin 11
    output reg  led_err,      // pin 13

    output wire uart_tx       // pin 17
);

    //=========================================================================
    // CONSTANTS
    //=========================================================================
    localparam integer SCLK_DIV  = 27;       // 500 kHz SCLK (slow & safe)
    localparam integer POR_DELAY = 135000;   // ~5 ms power-on wait

    // Command opcodes
    localparam [7:0] CMD_RESET    = 8'h06;
    localparam [7:0] CMD_START    = 8'h08;
    localparam [7:0] CMD_RDATA    = 8'h12;
    localparam [7:0] CMD_WREG     = 8'h40;
    localparam [7:0] REG_INPMUX   = 8'h02;
    localparam [7:0] REG_DATARATE = 8'h04;
    localparam [7:0] DATARATE_1KSPS = 8'h14; // VERIFY against datasheet!

    // Channel INPMUX values (AINx vs AINCOM=0xC). VERIFY against schematic!
    reg [7:0] inpmux_val;
    reg [1:0] ch_idx;
    always @(*) begin
        case (ch_idx)
            2'd0: inpmux_val = 8'h5C;  // AIN5
            2'd1: inpmux_val = 8'h4C;  // AIN4
            2'd2: inpmux_val = 8'h1C;  // AIN1
            2'd3: inpmux_val = 8'h0C;  // AIN0
            default: inpmux_val = 8'h0C;
        endcase
    end

    //=========================================================================
    // SPI BYTE ENGINE (Mode 1: CPOL=0, CPHA=1)
    //=========================================================================
    reg        spi_start;
    reg  [7:0] spi_tx_byte;
    reg  [7:0] spi_rx_byte;
    reg        spi_done;
    reg        spi_busy;

    reg [15:0] sclk_cnt;
    reg [3:0]  bit_cnt;
    reg [7:0]  tx_shift;
    reg [7:0]  rx_shift;
    reg        sclk_phase;

    localparam SPI_IDLE = 2'd0, SPI_RUN = 2'd1, SPI_END = 2'd2;
    reg [1:0] spi_state;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            spi_state  <= SPI_IDLE;
            ads_sclk   <= 1'b0;
            ads_din    <= 1'b0;
            sclk_cnt   <= 16'd0;
            bit_cnt    <= 4'd0;
            spi_done   <= 1'b0;
            spi_busy   <= 1'b0;
            spi_rx_byte<= 8'd0;
            tx_shift   <= 8'd0;
            rx_shift   <= 8'd0;
            sclk_phase <= 1'b0;
        end else begin
            spi_done <= 1'b0;
            case (spi_state)
            SPI_IDLE: begin
                ads_sclk <= 1'b0;
                spi_busy <= 1'b0;
                // Only begin a transfer when CS is actually asserted (low).
                // This prevents a late spi_start pulse from clocking SCLK
                // after the main FSM has already raised CS (which produced
                // stray SCLK edges while CS was high).
                if (spi_start && !ads_cs_n) begin
                    tx_shift   <= spi_tx_byte;
                    ads_din    <= spi_tx_byte[7];
                    rx_shift   <= 8'd0;
                    bit_cnt    <= 4'd0;
                    sclk_cnt   <= 16'd0;
                    sclk_phase <= 1'b0;
                    spi_busy   <= 1'b1;
                    spi_state  <= SPI_RUN;
                end
            end
            SPI_RUN: begin
                if (sclk_cnt == SCLK_DIV-1) begin
                    sclk_cnt <= 16'd0;
                    if (sclk_phase == 1'b0) begin
                        ads_sclk   <= 1'b1;                       // rising edge
                        rx_shift   <= {rx_shift[6:0], ads_dout};  // sample MISO
                        sclk_phase <= 1'b1;
                    end else begin
                        ads_sclk   <= 1'b0;                       // falling edge
                        sclk_phase <= 1'b0;
                        bit_cnt    <= bit_cnt + 4'd1;
                        if (bit_cnt == 4'd7) begin
                            spi_rx_byte <= {rx_shift[6:0], ads_dout};
                            spi_state   <= SPI_END;
                        end else begin
                            tx_shift <= {tx_shift[6:0], 1'b0};
                            ads_din  <= tx_shift[6];
                        end
                    end
                end else sclk_cnt <= sclk_cnt + 16'd1;
            end
            SPI_END: begin
                ads_sclk <= 1'b0;
                spi_done <= 1'b1;
                spi_busy <= 1'b0;
                spi_state<= SPI_IDLE;
            end
            endcase
        end
    end

    //=========================================================================
    // UART TX (460800 baud) + string-print helper
    //=========================================================================
    reg        uart_send;
    reg  [7:0] uart_data;
    wire       uart_ready;

    uart_tx_simple #(.CLK_HZ(27_000_000), .BAUD(460800)) u_uart (
        .clk(clk27), .rst_n(rst_n),
        .send(uart_send), .data(uart_data),
        .ready(uart_ready), .tx(uart_tx)
    );

    // hex nibble -> ASCII
    function [7:0] hex_char;
        input [3:0] nib;
        begin
            hex_char = (nib < 10) ? (8'h30 + nib) : (8'h41 + nib - 10);
        end
    endfunction

    //=========================================================================
    // PRINT ENGINE
    //=========================================================================
    // A tiny sub-FSM that emits a sequence of bytes. The main FSM loads a
    // "message selector" and the print engine walks through the chars.
    // This keeps the main FSM readable.
    //
    // Messages:
    //   MSG_RST   : "RST\n"
    //   MSG_CFG   : "CFG\n"
    //   MSG_CH    : "CHx DRDY=? RD=XXXXXX\n"  (x, ?, XXXXXX filled at runtime)
    //   MSG_TO    : "CHx DRDY=H TIMEOUT\n"
    //
    // The print engine reads from a small char buffer (pbuf) of length plen.
    reg  [7:0] pbuf [0:23];   // up to 24 chars per line
    reg  [4:0] plen;          // number of valid chars
    reg  [4:0] pidx;          // current char index
    reg        print_start;   // pulse to begin printing pbuf[0..plen-1]
    reg        print_busy;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            pidx       <= 5'd0;
            print_busy <= 1'b0;
            uart_send  <= 1'b0;
            uart_data  <= 8'd0;
        end else begin
            uart_send <= 1'b0;
            if (print_start && !print_busy) begin
                print_busy <= 1'b1;
                pidx       <= 5'd0;
            end else if (print_busy) begin
                if (uart_ready && !uart_send) begin
                    uart_data <= pbuf[pidx];
                    uart_send <= 1'b1;
                    if (pidx == plen-1) begin
                        print_busy <= 1'b0;
                    end else begin
                        pidx <= pidx + 5'd1;
                    end
                end
            end
        end
    end

    //=========================================================================
    // MAIN CONTROL FSM
    //=========================================================================
    localparam S_POR        = 5'd0;
    localparam S_RESET      = 5'd1;
    localparam S_RESET_WAIT = 5'd2;
    localparam S_PRINT_RST  = 5'd3;
    localparam S_CFG_A      = 5'd4;
    localparam S_CFG_B      = 5'd5;
    localparam S_CFG_C      = 5'd6;
    localparam S_PRINT_CFG  = 5'd7;
    localparam S_MUX_A      = 5'd8;
    localparam S_MUX_B      = 5'd9;
    localparam S_MUX_C      = 5'd10;
    localparam S_START      = 5'd11;
    localparam S_WAIT_DRDY  = 5'd12;
    localparam S_RD_CMD     = 5'd13;
    localparam S_RD_B0      = 5'd14;
    localparam S_RD_B1      = 5'd15;
    localparam S_RD_B2      = 5'd16;
    localparam S_BUILD_LINE = 5'd17;
    localparam S_PRINT_LINE = 5'd18;
    localparam S_WAIT_PRINT = 5'd19;
    localparam S_NEXT_CH    = 5'd20;
    localparam S_GAP_START  = 5'd21;   // CS-high gap before START
    localparam S_GAP_DRDY   = 5'd22;   // CS-high gap before read

    reg [4:0]  state;
    reg [4:0]  ret_state;     // where to return after a print
    reg [17:0] delay_cnt;
    reg [23:0] sample;
    reg        drdy_ok;       // 1 if DRDY went low, 0 if timed out

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_POR;
            delay_cnt   <= 18'd0;
            ads_cs_n    <= 1'b1;
            ads_start   <= 1'b0;
            spi_start   <= 1'b0;
            spi_tx_byte <= 8'd0;
            ch_idx      <= 2'd0;
            sample      <= 24'd0;
            led_init    <= 1'b1;
            led_acq     <= 1'b1;
            led_err     <= 1'b1;
            print_start <= 1'b0;
            plen        <= 5'd0;
            drdy_ok     <= 1'b0;
        end else begin
            spi_start   <= 1'b0;
            print_start <= 1'b0;

            case (state)
            //----------------------------------------------------------------
            S_POR: begin
                led_init <= 1'b0;       // initializing LED on
                if (delay_cnt == POR_DELAY) begin
                    delay_cnt <= 18'd0;
                    state     <= S_RESET;
                end else delay_cnt <= delay_cnt + 18'd1;
            end
            //----------------------------------------------------------------
            S_RESET: begin
                ads_cs_n <= 1'b0;
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= CMD_RESET;
                    spi_start   <= 1'b1;
                end
                if (spi_done) begin
                    ads_cs_n  <= 1'b1;
                    delay_cnt <= 18'd0;
                    state     <= S_RESET_WAIT;
                end
            end
            S_RESET_WAIT: begin
                if (delay_cnt == 18'd27000) begin   // ~1 ms
                    // build "RST\n"
                    pbuf[0] <= "R"; pbuf[1] <= "S"; pbuf[2] <= "T"; pbuf[3] <= 8'h0A;
                    plen    <= 5'd4;
                    ret_state <= S_CFG_A;
                    state   <= S_PRINT_RST;
                end else delay_cnt <= delay_cnt + 18'd1;
            end
            S_PRINT_RST: begin
                print_start <= 1'b1;
                state       <= S_WAIT_PRINT;
            end
            //----------------------------------------------------------------
            // Configure DATARATE register
            S_CFG_A: begin
                ads_cs_n <= 1'b0;
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= CMD_WREG | REG_DATARATE;
                    spi_start   <= 1'b1;
                end
                if (spi_done) state <= S_CFG_B;
            end
            S_CFG_B: begin
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= 8'h00;
                    spi_start   <= 1'b1;
                end
                if (spi_done) state <= S_CFG_C;
            end
            S_CFG_C: begin
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= DATARATE_1KSPS;
                    spi_start   <= 1'b1;
                end
                if (spi_done) begin
                    ads_cs_n <= 1'b1;
                    led_init <= 1'b1;        // init done
                    pbuf[0] <= "C"; pbuf[1] <= "F"; pbuf[2] <= "G"; pbuf[3] <= 8'h0A;
                    plen    <= 5'd4;
                    ret_state <= S_MUX_A;
                    state   <= S_PRINT_CFG;
                end
            end
            S_PRINT_CFG: begin
                print_start <= 1'b1;
                state       <= S_WAIT_PRINT;
            end
            //----------------------------------------------------------------
            // Per-channel: set INPMUX
            S_MUX_A: begin
                ads_cs_n <= 1'b0;
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= CMD_WREG | REG_INPMUX;
                    spi_start   <= 1'b1;
                end
                if (spi_done) state <= S_MUX_B;
            end
            S_MUX_B: begin
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= 8'h00;
                    spi_start   <= 1'b1;
                end
                if (spi_done) state <= S_MUX_C;
            end
            S_MUX_C: begin
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= inpmux_val;
                    spi_start   <= 1'b1;
                end
                if (spi_done) begin
                    ads_cs_n  <= 1'b1;
                    delay_cnt <= 18'd0;
                    state     <= S_GAP_START;   // hold CS high briefly first
                end
            end
            //----------------------------------------------------------------
            // CS-high gap: keep CS deasserted for a few clocks so the ADS sees
            // a clean end-of-transaction before the next one begins. Without
            // this, CS was raised and lowered on adjacent clocks (0 ns pulse),
            // which a real ADS114S08 may not register, risking data corruption.
            S_GAP_START: begin
                ads_cs_n <= 1'b1;               // stay high
                if (delay_cnt == 18'd8) begin   // ~300 ns at 27 MHz
                    delay_cnt <= 18'd0;
                    state     <= S_START;
                end else delay_cnt <= delay_cnt + 18'd1;
            end
            //----------------------------------------------------------------
            S_START: begin
                ads_cs_n <= 1'b0;
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= CMD_START;
                    spi_start   <= 1'b1;
                end
                if (spi_done) begin
                    ads_cs_n  <= 1'b1;
                    delay_cnt <= 18'd0;
                    state     <= S_GAP_DRDY;    // brief CS-high gap before read
                end
            end
            //----------------------------------------------------------------
            S_GAP_DRDY: begin
                ads_cs_n <= 1'b1;
                if (delay_cnt == 18'd8) begin
                    delay_cnt <= 18'd0;
                    state     <= S_WAIT_DRDY;
                end else delay_cnt <= delay_cnt + 18'd1;
            end
            //----------------------------------------------------------------
            S_WAIT_DRDY: begin
                led_acq <= ~led_acq;
                if (!ads_drdy_n) begin
                    drdy_ok <= 1'b1;
                    led_err <= 1'b1;        // clear error
                    state   <= S_RD_CMD;
                end else if (delay_cnt == 18'd200000) begin  // ~7.4ms timeout
                    drdy_ok <= 1'b0;
                    led_err <= 1'b0;        // error LED on
                    state   <= S_BUILD_LINE; // still print a line (TIMEOUT)
                end else delay_cnt <= delay_cnt + 18'd1;
            end
            //----------------------------------------------------------------
            S_RD_CMD: begin
                ads_cs_n <= 1'b0;
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= CMD_RDATA;
                    spi_start   <= 1'b1;
                end
                if (spi_done) state <= S_RD_B0;
            end
            S_RD_B0: begin
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= 8'h00; spi_start <= 1'b1;
                end
                if (spi_done) begin sample[23:16] <= spi_rx_byte; state <= S_RD_B1; end
            end
            S_RD_B1: begin
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= 8'h00; spi_start <= 1'b1;
                end
                if (spi_done) begin sample[15:8] <= spi_rx_byte; state <= S_RD_B2; end
            end
            S_RD_B2: begin
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= 8'h00; spi_start <= 1'b1;
                end
                if (spi_done) begin
                    sample[7:0] <= spi_rx_byte;
                    ads_cs_n    <= 1'b1;
                    state       <= S_BUILD_LINE;
                end
            end
            //----------------------------------------------------------------
            // Build the trace line:
            //   "CHx DRDY=L RD=XXXXXX\n"  or  "CHx DRDY=H TIMEOUT\n"
            S_BUILD_LINE: begin
                pbuf[0] <= "C";
                pbuf[1] <= "H";
                pbuf[2] <= "0" + {6'd0, ch_idx};   // channel digit 0..3
                pbuf[3] <= " ";
                pbuf[4] <= "D"; pbuf[5] <= "R"; pbuf[6] <= "D"; pbuf[7] <= "Y";
                pbuf[8] <= "=";
                if (drdy_ok) begin
                    pbuf[9]  <= "L";
                    pbuf[10] <= " ";
                    pbuf[11] <= "R"; pbuf[12] <= "D"; pbuf[13] <= "=";
                    pbuf[14] <= hex_char(sample[23:20]);
                    pbuf[15] <= hex_char(sample[19:16]);
                    pbuf[16] <= hex_char(sample[15:12]);
                    pbuf[17] <= hex_char(sample[11:8]);
                    pbuf[18] <= hex_char(sample[7:4]);
                    pbuf[19] <= hex_char(sample[3:0]);
                    pbuf[20] <= 8'h0A;     // newline
                    plen     <= 5'd21;
                end else begin
                    pbuf[9]  <= "H";
                    pbuf[10] <= " ";
                    pbuf[11] <= "T"; pbuf[12] <= "I"; pbuf[13] <= "M";
                    pbuf[14] <= "E"; pbuf[15] <= "O"; pbuf[16] <= "U";
                    pbuf[17] <= "T"; pbuf[18] <= 8'h0A;
                    plen     <= 5'd19;
                end
                state <= S_PRINT_LINE;
            end
            S_PRINT_LINE: begin
                print_start <= 1'b1;
                ret_state   <= S_NEXT_CH;
                state       <= S_WAIT_PRINT;
            end
            //----------------------------------------------------------------
            // Generic "wait until print engine is free, then go to ret_state"
            S_WAIT_PRINT: begin
                if (!print_busy && !print_start) state <= ret_state;
            end
            //----------------------------------------------------------------
            S_NEXT_CH: begin
                ch_idx <= ch_idx + 2'd1;
                state  <= S_MUX_A;
            end
            //----------------------------------------------------------------
            default: state <= S_POR;
            endcase
        end
    end

endmodule


//=============================================================================
// uart_tx_simple : minimal 8N1 UART transmitter
//=============================================================================
module uart_tx_simple #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BAUD   = 460800
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       send,
    input  wire [7:0] data,
    output reg        ready,
    output reg        tx
);
    localparam integer DIV = CLK_HZ / BAUD;   // 27e6/460800 = 58.6 -> 58

    reg [15:0] cnt;
    reg [3:0]  bit_idx;
    reg [9:0]  shifter;
    reg        busy;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx <= 1'b1; ready <= 1'b1; busy <= 1'b0;
            cnt <= 16'd0; bit_idx <= 4'd0; shifter <= 10'h3FF;
        end else begin
            if (!busy) begin
                tx <= 1'b1; ready <= 1'b1;
                if (send) begin
                    shifter <= {1'b1, data, 1'b0};
                    busy <= 1'b1; ready <= 1'b0;
                    cnt <= 16'd0; bit_idx <= 4'd0;
                end
            end else begin
                if (cnt == DIV-1) begin
                    cnt <= 16'd0;
                    tx  <= shifter[0];
                    shifter <= {1'b1, shifter[9:1]};
                    bit_idx <= bit_idx + 4'd1;
                    if (bit_idx == 4'd9) begin busy <= 1'b0; ready <= 1'b1; end
                end else cnt <= cnt + 16'd1;
            end
        end
    end
endmodule
