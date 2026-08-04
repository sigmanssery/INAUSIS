//=============================================================================
// ldc1101_bringup_trace.v
//
// PHASE 1 BRING-UP for the LDC1101 inductive front-end (INAUSIS project).
//
// Reads the LDC1101 device and streams human-readable diagnostics over UART
// at 460800 baud, 8N1, TEXT mode. Lets you debug WITHOUT a logic analyzer.
//
// You will see lines like:
//     LDC RST
//     LDC CFG
//     CHIP_ID=D4            <- reading register 0x3F (should be 0xD4 for LDC1101)
//     RP=1A2C L=03F8        <- RP_DATA and L_DATA 16-bit values
//     RP=1A30 L=03F5
//     ...
//
// DIAGNOSIS GUIDE:
//   "CHIP_ID=D4"     -> SPI link works AND it's really an LDC1101. BEST result;
//                       a correct device-ID readback is the strongest proof the
//                       SPI path is wired and timed correctly.
//   "CHIP_ID=00"     -> MISO reads all zeros. MISO (ldc_sdo, pin 40) not
//                       connected, or device not powered / wrong mode.
//   "CHIP_ID=FF"     -> MISO floating high. CS not selecting the chip, or
//                       device not responding.
//   "CHIP_ID=<other>"-> SPI runs but value wrong: check SPI mode (LDC=Mode 0,
//                       NOT Mode 1 like the ADS), bit order, or wiring.
//   RP/L all 0000 or FFFF -> conversion not running; check START_CONFIG and
//                       the LC tank / external inductor on the board.
//
// ====================== KEY DIFFERENCE FROM ADS114S08 ======================
// LDC1101 uses SPI MODE 0 (CPOL=0, CPHA=0), NOT Mode 1.
//   Mode 0: SCLK idles low. MASTER changes MOSI on the FALLING edge and
//           SAMPLES MISO on the RISING edge. The FIRST MOSI bit must be valid
//           BEFORE the first rising edge (i.e. set up while SCLK is still low,
//           right after CS goes low). This differs from the ADS Mode-1 timing.
//
// Transaction format (2 bytes):
//   Byte 1 = address byte: {R/W, addr[6:0]}   R/W=1 read, R/W=0 write
//   Byte 2 = data (write) or dummy (read; MISO returns the register value)
// ===========================================================================
//
// Target  : Tang Nano 9K (GW1NR-LV9), 27 MHz clock
// Pins (from inausis.cst, SPI Bus B):
//   ldc_cs_n = 33, ldc_sclk = 34, ldc_sdi(MOSI) = 35, ldc_sdo(MISO) = 40
//   uart_tx  = 17
//=============================================================================

module ldc1101_bringup_trace (
    input  wire clk27,        // 27 MHz oscillator (pin 52)
    input  wire rst_n,        // S2 button, active-low (pin 4)

    // ---- LDC1101 SPI bus (3.3V Bank 6) ----
    output reg  ldc_cs_n,     // chip select, active-low   (pin 33)
    output reg  ldc_sclk,     // SPI clock                 (pin 34)
    output reg  ldc_sdi,      // MOSI: FPGA -> LDC          (pin 35)
    input  wire ldc_sdo,      // MISO: LDC -> FPGA          (pin 40)

    // ---- status LEDs (active-low) ----
    output reg  led_init,     // pin 10
    output reg  led_acq,      // pin 11
    output reg  led_err,      // pin 13

    output wire uart_tx       // pin 17
);

    //=========================================================================
    // CONSTANTS
    //=========================================================================
    localparam integer SCLK_DIV  = 27;        // 500 kHz SCLK (slow & safe)
    localparam integer POR_DELAY = 135000;    // ~5 ms power-on wait

    // R/W bit in the address byte
    localparam READ_BIT  = 1'b1;   // MSB=1 => read
    localparam WRITE_BIT = 1'b0;   // MSB=0 => write

    // LDC1101 register addresses (from datasheet)
    localparam [6:0] REG_RP_SET     = 7'h01;
    localparam [6:0] REG_TC1        = 7'h02;
    localparam [6:0] REG_TC2        = 7'h03;
    localparam [6:0] REG_DIG_CONF   = 7'h04;
    localparam [6:0] REG_ALT_CONF   = 7'h05;
    localparam [6:0] REG_D_CONF     = 7'h0C;
    localparam [6:0] REG_START_CONF = 7'h0B;   // write 0x00 => active mode
    localparam [6:0] REG_RP_DATA_L  = 7'h21;
    localparam [6:0] REG_RP_DATA_H  = 7'h22;
    localparam [6:0] REG_L_DATA_L   = 7'h23;
    localparam [6:0] REG_L_DATA_H   = 7'h24;
    localparam [6:0] REG_CHIP_ID    = 7'h3F;   // device ID (expect 0xD4)

    // Configuration values (typical starting set; VERIFY for your LC tank!)
    // These are placeholders that get the device into RP+L mode. The exact
    // RP_SET / TC1 / TC2 depend on your coil + 4.7uH + 220pF tank (f~4.6MHz).
    localparam [7:0] VAL_RP_SET   = 8'h07;   // RP_MAX/MIN range  -- VERIFY
    localparam [7:0] VAL_TC1      = 8'h90;   // time constant 1   -- VERIFY
    localparam [7:0] VAL_TC2      = 8'hA0;   // time constant 2   -- VERIFY
    localparam [7:0] VAL_DIG_CONF = 8'h03;   // response time     -- VERIFY
    localparam [7:0] VAL_ALT_CONF = 8'h00;
    localparam [7:0] VAL_D_CONF   = 8'h00;
    localparam [7:0] VAL_ACTIVE   = 8'h00;   // START_CONFIG=0 => active

    //=========================================================================
    // SPI BYTE ENGINE (Mode 0: CPOL=0, CPHA=0)
    //=========================================================================
    // Mode 0 vs Mode 1 difference is WHEN the first MOSI bit appears and which
    // edge samples MISO:
    //   - SCLK idles low.
    //   - FIRST bit of MOSI is presented while SCLK is still low (right at the
    //     start), then the master SAMPLES MISO on each RISING edge and CHANGES
    //     MOSI on each FALLING edge.
    // Concretely: drive MOSI MSB before raising SCLK; on rising edge sample
    // MISO; on falling edge advance to next MOSI bit. (For an 8-bit byte we do
    // 8 rising-edge samples.)
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
            ldc_sclk   <= 1'b0;
            ldc_sdi    <= 1'b0;
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
                ldc_sclk <= 1'b0;
                spi_busy <= 1'b0;
                if (spi_start && !ldc_cs_n) begin
                    tx_shift   <= spi_tx_byte;
                    ldc_sdi    <= spi_tx_byte[7];   // MSB valid before 1st edge
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
                        // RISING edge: sample MISO (Mode 0 samples on rising)
                        ldc_sclk   <= 1'b1;
                        rx_shift   <= {rx_shift[6:0], ldc_sdo};
                        sclk_phase <= 1'b1;
                    end else begin
                        // FALLING edge: advance MOSI to next bit
                        ldc_sclk   <= 1'b0;
                        sclk_phase <= 1'b0;
                        bit_cnt    <= bit_cnt + 4'd1;
                        if (bit_cnt == 4'd7) begin
                            spi_rx_byte <= {rx_shift[6:0], ldc_sdo};
                            spi_state   <= SPI_END;
                        end else begin
                            tx_shift <= {tx_shift[6:0], 1'b0};
                            ldc_sdi  <= tx_shift[6];
                        end
                    end
                end else sclk_cnt <= sclk_cnt + 16'd1;
            end
            SPI_END: begin
                ldc_sclk <= 1'b0;
                spi_done <= 1'b1;
                spi_busy <= 1'b0;
                spi_state<= SPI_IDLE;
            end
            endcase
        end
    end

    //=========================================================================
    // UART TX (460800 baud) + print engine
    //=========================================================================
    reg        uart_send;
    reg  [7:0] uart_data;
    wire       uart_ready;

    uart_tx_simple #(.CLK_HZ(27_000_000), .BAUD(921600)) u_uart (
        .clk(clk27), .rst_n(rst_n),
        .send(uart_send), .data(uart_data),
        .ready(uart_ready), .tx(uart_tx)
    );

    function [7:0] hex_char;
        input [3:0] nib;
        begin
            hex_char = (nib < 10) ? (8'h30 + nib) : (8'h41 + nib - 10);
        end
    endfunction

    reg  [7:0] pbuf [0:23];
    reg  [4:0] plen;
    reg  [4:0] pidx;
    reg        print_start;
    reg        print_busy;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            pidx <= 5'd0; print_busy <= 1'b0; uart_send <= 1'b0; uart_data <= 8'd0;
        end else begin
            uart_send <= 1'b0;
            if (print_start && !print_busy) begin
                print_busy <= 1'b1; pidx <= 5'd0;
            end else if (print_busy) begin
                if (uart_ready && !uart_send) begin
                    uart_data <= pbuf[pidx];
                    uart_send <= 1'b1;
                    if (pidx == plen-1) print_busy <= 1'b0;
                    else pidx <= pidx + 5'd1;
                end
            end
        end
    end

    //=========================================================================
    // MAIN CONTROL FSM
    //=========================================================================
    // Sequence:
    //   POR -> (print "LDC RST") -> write config regs -> START_CONFIG=active
    //   -> print "LDC CFG" -> read CHIP_ID (sanity) -> print it
    //   -> loop: read RP_DATA(L,H) + L_DATA(L,H) -> print "RP=xxxx L=xxxx"
    //
    // Every SPI access is a 2-byte transaction (addr + data) with CS low for
    // the whole 16 SCLK, then CS high with a gap before the next access.
    localparam S_POR       = 6'd0;
    localparam S_PRINT_RST = 6'd1;
    localparam S_CFG_LIST  = 6'd2;   // walk through config register writes
    localparam S_CFG_ADDR  = 6'd3;
    localparam S_CFG_DATA  = 6'd4;
    localparam S_CFG_GAP   = 6'd5;
    localparam S_PRINT_CFG = 6'd6;
    localparam S_ID_ADDR   = 6'd7;
    localparam S_ID_DATA   = 6'd8;
    localparam S_ID_GAP    = 6'd9;
    localparam S_PRINT_ID  = 6'd10;
    localparam S_RPL_ADDR  = 6'd11;  // read one of the 4 data bytes
    localparam S_RPL_DATA  = 6'd12;
    localparam S_RPL_GAP   = 6'd13;
    localparam S_BUILD     = 6'd14;
    localparam S_PRINT_RPL = 6'd15;
    localparam S_WAIT_PR   = 6'd16;
    localparam S_LOOP_DLY  = 6'd17;

    reg [5:0]  state;
    reg [5:0]  ret_state;
    reg [17:0] delay_cnt;

    // config register write list
    reg [3:0] cfg_idx;
    reg [6:0] cfg_addr;
    reg [7:0] cfg_data;
    always @(*) begin
        case (cfg_idx)
            4'd0: begin cfg_addr = REG_RP_SET;     cfg_data = VAL_RP_SET;   end
            4'd1: begin cfg_addr = REG_TC1;        cfg_data = VAL_TC1;      end
            4'd2: begin cfg_addr = REG_TC2;        cfg_data = VAL_TC2;      end
            4'd3: begin cfg_addr = REG_DIG_CONF;   cfg_data = VAL_DIG_CONF; end
            4'd4: begin cfg_addr = REG_ALT_CONF;   cfg_data = VAL_ALT_CONF; end
            4'd5: begin cfg_addr = REG_D_CONF;     cfg_data = VAL_D_CONF;   end
            4'd6: begin cfg_addr = REG_START_CONF; cfg_data = VAL_ACTIVE;   end
            default: begin cfg_addr = REG_START_CONF; cfg_data = VAL_ACTIVE; end
        endcase
    end
    localparam CFG_COUNT = 4'd7;   // number of config writes

    // data read: 4 bytes (RP_L, RP_H, L_L, L_H)
    reg [1:0] data_idx;
    reg [6:0] data_addr;
    always @(*) begin
        case (data_idx)
            2'd0: data_addr = REG_RP_DATA_L;
            2'd1: data_addr = REG_RP_DATA_H;
            2'd2: data_addr = REG_L_DATA_L;
            2'd3: data_addr = REG_L_DATA_H;
        endcase
    end
    reg [7:0] rp_lo, rp_hi, l_lo, l_hi;
    reg [7:0] chip_id;

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_POR;
            delay_cnt   <= 18'd0;
            ldc_cs_n    <= 1'b1;
            spi_start   <= 1'b0;
            spi_tx_byte <= 8'd0;
            cfg_idx     <= 4'd0;
            data_idx    <= 2'd0;
            led_init    <= 1'b1;
            led_acq     <= 1'b1;
            led_err     <= 1'b1;
            print_start <= 1'b0;
            plen        <= 5'd0;
            chip_id     <= 8'd0;
            rp_lo<=0; rp_hi<=0; l_lo<=0; l_hi<=0;
        end else begin
            spi_start   <= 1'b0;
            print_start <= 1'b0;

            case (state)
            //----------------------------------------------------------------
            S_POR: begin
                led_init <= 1'b0;
                if (delay_cnt == POR_DELAY) begin
                    delay_cnt <= 18'd0;
                    pbuf[0]<="L";pbuf[1]<="D";pbuf[2]<="C";pbuf[3]<=" ";
                    pbuf[4]<="R";pbuf[5]<="S";pbuf[6]<="T";pbuf[7]<=8'h0A;
                    plen<=5'd8; ret_state<=S_CFG_LIST; state<=S_PRINT_RST;
                end else delay_cnt <= delay_cnt + 18'd1;
            end
            S_PRINT_RST: begin print_start<=1'b1; state<=S_WAIT_PR; end
            //----------------------------------------------------------------
            // Walk config-register write list
            S_CFG_LIST: begin
                if (cfg_idx == CFG_COUNT) begin
                    led_init <= 1'b1;
                    pbuf[0]<="L";pbuf[1]<="D";pbuf[2]<="C";pbuf[3]<=" ";
                    pbuf[4]<="C";pbuf[5]<="F";pbuf[6]<="G";pbuf[7]<=8'h0A;
                    plen<=5'd8; ret_state<=S_ID_ADDR; state<=S_PRINT_CFG;
                end else state <= S_CFG_ADDR;
            end
            S_CFG_ADDR: begin
                ldc_cs_n <= 1'b0;
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= {WRITE_BIT, cfg_addr};  // write addr byte
                    spi_start   <= 1'b1;
                end
                if (spi_done) state <= S_CFG_DATA;
            end
            S_CFG_DATA: begin
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= cfg_data;
                    spi_start   <= 1'b1;
                end
                if (spi_done) begin
                    ldc_cs_n  <= 1'b1;
                    delay_cnt <= 18'd0;
                    state     <= S_CFG_GAP;
                end
            end
            S_CFG_GAP: begin
                ldc_cs_n <= 1'b1;
                if (delay_cnt == 18'd8) begin
                    delay_cnt <= 18'd0;
                    cfg_idx   <= cfg_idx + 4'd1;
                    state     <= S_CFG_LIST;
                end else delay_cnt <= delay_cnt + 18'd1;
            end
            S_PRINT_CFG: begin print_start<=1'b1; state<=S_WAIT_PR; end
            //----------------------------------------------------------------
            // Read CHIP_ID (sanity check: expect 0xD4)
            S_ID_ADDR: begin
                ldc_cs_n <= 1'b0;
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= {READ_BIT, REG_CHIP_ID};
                    spi_start   <= 1'b1;
                end
                if (spi_done) state <= S_ID_DATA;
            end
            S_ID_DATA: begin
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= 8'h00;   // dummy; MISO returns ID
                    spi_start   <= 1'b1;
                end
                if (spi_done) begin
                    chip_id   <= spi_rx_byte;
                    ldc_cs_n  <= 1'b1;
                    delay_cnt <= 18'd0;
                    state     <= S_ID_GAP;
                end
            end
            S_ID_GAP: begin
                ldc_cs_n <= 1'b1;
                if (delay_cnt == 18'd8) begin
                    delay_cnt <= 18'd0;
                    // build "CHIP_ID=XX\n"
                    pbuf[0]<="C";pbuf[1]<="H";pbuf[2]<="I";pbuf[3]<="P";
                    pbuf[4]<="_";pbuf[5]<="I";pbuf[6]<="D";pbuf[7]<="=";
                    pbuf[8]<=hex_char(chip_id[7:4]);
                    pbuf[9]<=hex_char(chip_id[3:0]);
                    pbuf[10]<=8'h0A;
                    plen<=5'd11; ret_state<=S_RPL_ADDR; state<=S_PRINT_ID;
                end else delay_cnt <= delay_cnt + 18'd1;
            end
            S_PRINT_ID: begin print_start<=1'b1; state<=S_WAIT_PR; end
            //----------------------------------------------------------------
            // Read RP/L data: 4 single-register reads
            S_RPL_ADDR: begin
                ldc_cs_n <= 1'b0;
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= {READ_BIT, data_addr};
                    spi_start   <= 1'b1;
                end
                if (spi_done) state <= S_RPL_DATA;
            end
            S_RPL_DATA: begin
                if (!spi_busy && !spi_start) begin
                    spi_tx_byte <= 8'h00;   // dummy
                    spi_start   <= 1'b1;
                end
                if (spi_done) begin
                    case (data_idx)
                        2'd0: rp_lo <= spi_rx_byte;
                        2'd1: rp_hi <= spi_rx_byte;
                        2'd2: l_lo  <= spi_rx_byte;
                        2'd3: l_hi  <= spi_rx_byte;
                    endcase
                    ldc_cs_n  <= 1'b1;
                    delay_cnt <= 18'd0;
                    state     <= S_RPL_GAP;
                end
            end
            S_RPL_GAP: begin
                ldc_cs_n <= 1'b1;
                if (delay_cnt == 18'd8) begin
                    delay_cnt <= 18'd0;
                    if (data_idx == 2'd3) begin
                        data_idx <= 2'd0;
                        state    <= S_BUILD;
                    end else begin
                        data_idx <= data_idx + 2'd1;
                        state    <= S_RPL_ADDR;
                    end
                end else delay_cnt <= delay_cnt + 18'd1;
            end
            //----------------------------------------------------------------
            // Build "RP=xxxx L=xxxx\n"
            S_BUILD: begin
                led_acq <= ~led_acq;
                pbuf[0]<="R";pbuf[1]<="P";pbuf[2]<="=";
                pbuf[3]<=hex_char(rp_hi[7:4]); pbuf[4]<=hex_char(rp_hi[3:0]);
                pbuf[5]<=hex_char(rp_lo[7:4]); pbuf[6]<=hex_char(rp_lo[3:0]);
                pbuf[7]<=" ";
                pbuf[8]<="L";pbuf[9]<="=";
                pbuf[10]<=hex_char(l_hi[7:4]); pbuf[11]<=hex_char(l_hi[3:0]);
                pbuf[12]<=hex_char(l_lo[7:4]); pbuf[13]<=hex_char(l_lo[3:0]);
                pbuf[14]<=8'h0A;
                plen<=5'd15; state<=S_PRINT_RPL;
            end
            S_PRINT_RPL: begin
                print_start<=1'b1; ret_state<=S_LOOP_DLY; state<=S_WAIT_PR;
            end
            //----------------------------------------------------------------
            S_WAIT_PR: begin
                if (!print_busy && !print_start) state <= ret_state;
            end
            //----------------------------------------------------------------
            // small delay between sample loops (~1ms) so UART isn't flooded
            S_LOOP_DLY: begin
                if (delay_cnt == 18'd27000) begin
                    delay_cnt <= 18'd0;
                    state     <= S_RPL_ADDR;
                end else delay_cnt <= delay_cnt + 18'd1;
            end
            //----------------------------------------------------------------
            default: state <= S_POR;
            endcase
        end
    end

endmodule


//=============================================================================
// uart_tx_simple : minimal 8N1 UART transmitter (same as ADS build)
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
