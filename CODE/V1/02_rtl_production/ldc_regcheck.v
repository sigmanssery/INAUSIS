`timescale 1ns/1ps
//=============================================================================
// ldc_regcheck.v — INAUSIS Phase-1 LDC1101 bring-up (v3: real RP+L sensing)
//
// Builds on the HW-validated Mode-3 SPI (v2 read CHIP_ID=0xD4 + RP_SET loopback).
// Now configures the LDC1101 into RP+L active mode and streams real sensor data:
//   POR -> WREG config list -> read CHIP_ID (led_err if != 0xD4)
//       -> loop: read RP_DATA(L,H)+L_DATA(L,H)+STATUS(0x20)  [STATUS LAST]
//                -> UART "ID=hh ST=hh RP=xxxx L=xxxx Bn"
// STATUS(0x20) bits: [7]NO_SENSOR_OSC [6]DRDYB [5]RP_HIN [4]RP_HI_LON
//                    [3]L_HIN [2]L_HI_LON [1]rsvd [0]POR_READ.
// GOTCHA (HW 2026-06-23): reading STATUS(0x20) *before* the RP/L data regs in
//   the same loop made RP/L read 0x0000 with DRDYB stuck — STATUS must be read
//   LAST (after 0x21-0x24). Keep it at the tail of the read list.
// Healthy active read: ST hops 0x28<->0x68 (only b6/DRDYB toggles; b5,b3 stay 1
//   as HI thresholds are unconfigured). RP printed = 1/16 EMA of glitch-gated
//   raw (see below); L printed = last valid raw. Bn = build tag.
//
// SPI MODE 0 (CPOL=0, CPHA=0): SCLK idles LOW; MOSI MSB presented before the
// first rising edge; master SAMPLES MISO on the RISING edge, ADVANCES MOSI on
// the FALLING edge. (Reverted from Mode 3 on 2026-07-02: on the integrated board
// Mode 3 read 0xFF, Mode 0 reads 0xD4 — LDC1101 is a Mode-0 part.)
// 2-byte (16-bit) transactions; read data byte lands in spi_rx[7:0].
//
// 関3 check (read_uart.ps1 @921600): bring a metal target near the planar coil
//   -> RP and L values should change, and recover when removed.
//   ID should stay D4 (led_err off). Config (RP_SET/TC1/TC2/...) is datasheet-
//   typical; if RP/L look stuck/railed, those need tuning for the real tank.
//
// Pins match ldc_bringup.cst (ldc_cs_n=33, ldc_sclk=34, ldc_sdi=35, ldc_sdo=40).
//=============================================================================
module ldc_regcheck (
    input  wire        clk27,
    input  wire        rst_n,
    output reg         ldc_cs_n,     // pin 33 (CSB)
    output reg         ldc_sclk,     // pin 34 (SCLK) — idles HIGH (Mode 3)
    output reg         ldc_sdi,      // pin 35 (MOSI -> LDC SDI)
    input  wire        ldc_sdo,      // pin 40 (LDC SDO/INTB -> MISO)
    output wire        ldc_clkin,    // pin 42 -> LDC CLKIN (reference clock for L)
    output reg         led_init,     // pin 10
    output reg         led_acq,      // pin 11
    output reg         led_err,      // pin 13 (ON if CHIP_ID != 0xD4)
    output wire        uart_tx       // pin 17
);
    localparam READ_BIT = 1'b1, WRITE_BIT = 1'b0;
    localparam [6:0] REG_RP_SET=7'h01, REG_TC1=7'h02, REG_TC2=7'h03,
                     REG_DIG_CONF=7'h04, REG_ALT_CONF=7'h05, REG_D_CONF=7'h0C,
                     REG_START_CONF=7'h0B, REG_STATUS=7'h20,
                     REG_RP_DATA_L=7'h21, REG_RP_DATA_H=7'h22,
                     REG_L_DATA_L=7'h23,  REG_L_DATA_H=7'h24, REG_CHIP_ID=7'h3F;
    // Reverted to the placeholder config that gave a non-zero RP (~0xA600) on HW.
    // The datasheet RP+L EXAMPLE values (0x36/0xDE/0xFE/0xE6) are for a 6k/Q45/
    // 4.2MHz sensor and made RP read 0 here -> this tank's RP/Q/freq differ, so
    // RP_SET/TC1/TC2/DIG_CONF must be tuned to the MEASURED sensor (bench task).
    // RP_SET=0x07 has a wide RPMAX range, which captured this (higher-RP) sensor.
    localparam [7:0] VAL_RP_SET =8'h07,
                     // TC1/TC2 tuned to THIS tank (220pF, fSENSOR~5.08MHz) via
                     // rp_regcalc.py (datasheet Eq.8/9). Was 0x90/0xA0 (the
                     // datasheet 4.2MHz example) -> RP loop didn't settle (jumpy).
                     VAL_TC1     =8'h59,  // C1=1.5pF R1~97.8k -> R1*C1~147.7ns
                     VAL_TC2     =8'h30,  // C2=3pF   R2~222k  -> R2*C2~660ns
                     VAL_DIG_CONF=8'h06,  // MIN_FREQ=0 + RESP_TIME=3072 (b110): ~8x bigger L_DATA
                     VAL_ALT_CONF=8'h00, VAL_D_CONF=8'h00,
                     VAL_SLEEP   =8'h01,  // START_CONFIG sleep/stop (configure in sleep)
                     VAL_ACTIVE  =8'h00;  // START_CONFIG active (RP+L conversion)

    // ── CLKIN generator: ~3.375 MHz (clk27/8), within the LDC 1-16 MHz spec.
    //    Lowered from 13.5 MHz + DRIVE=4 (in .cst) to reduce coupling of the
    //    CLKIN edges into the LC tank over the dupont wire (which made RP jumpy).
    //    L measurement REQUIRES this reference clock; RP does not.
    //    Route ldc_clkin (pin 42) to the LDC CLKIN header pin.
    reg [2:0] clkin_cnt;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) clkin_cnt <= 3'd0;
        else        clkin_cnt <= clkin_cnt + 3'd1;
    end
    assign ldc_clkin = clkin_cnt[2];

    //=========================================================================
    // SPI byte engine — MODE 0, deterministic phase, ~964 kHz (HALF=14).
    //=========================================================================
    localparam HALF = 14;
    reg        spi_start, spi_busy, spi_done;
    reg [23:0] load_data, shift_out, spi_rx;
    reg [5:0]  total_bits, bit_cnt;
    reg [4:0]  div;
    reg        phase;   // 0 = next edge RISING (sample), 1 = next edge FALLING (advance)

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            ldc_cs_n<=1'b1; ldc_sclk<=1'b0; ldc_sdi<=1'b0;   // SCLK idle LOW (Mode 0)
            spi_busy<=1'b0; spi_done<=1'b0; spi_rx<=24'h0;
            shift_out<=24'h0; bit_cnt<=6'd0; div<=5'd0; phase<=1'b0;
        end else begin
            spi_done <= 1'b0;
            if (spi_start && !spi_busy) begin
                ldc_cs_n  <= 1'b0;
                ldc_sclk  <= 1'b0;                 // idle LOW
                shift_out <= load_data;
                ldc_sdi   <= load_data[23];        // present MSB before 1st rising
                bit_cnt   <= total_bits;
                div       <= 5'd0;
                phase     <= 1'b0;
                spi_busy  <= 1'b1;
            end else if (spi_busy) begin
                if (div==HALF-1) begin
                    div <= 5'd0;
                    if (phase==1'b0) begin
                        ldc_sclk <= 1'b1;                  // RISING: sample MISO
                        spi_rx   <= {spi_rx[22:0], ldc_sdo};
                        phase    <= 1'b1;
                    end else begin
                        ldc_sclk <= 1'b0;                  // FALLING: advance MOSI
                        phase    <= 1'b0;
                        if (bit_cnt==6'd1) begin
                            spi_busy <= 1'b0;
                            ldc_cs_n <= 1'b1;
                            spi_done <= 1'b1;
                        end else begin
                            bit_cnt   <= bit_cnt - 6'd1;
                            shift_out <= {shift_out[22:0], 1'b0};
                            ldc_sdi   <= shift_out[22];
                        end
                    end
                end else div <= div + 5'd1;
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
    function [7:0] hex_char; input [3:0] nib;
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
    // config write list + data read addresses
    //=========================================================================
    reg [3:0] cfg_idx;
    reg [6:0] cfg_addr; reg [7:0] cfg_data;
    always @(*) begin
        case (cfg_idx)
            4'd0: begin cfg_addr=REG_START_CONF; cfg_data=VAL_SLEEP;    end // stop/sleep first
            4'd1: begin cfg_addr=REG_RP_SET;     cfg_data=VAL_RP_SET;   end
            4'd2: begin cfg_addr=REG_TC1;        cfg_data=VAL_TC1;      end
            4'd3: begin cfg_addr=REG_TC2;        cfg_data=VAL_TC2;      end
            4'd4: begin cfg_addr=REG_DIG_CONF;   cfg_data=VAL_DIG_CONF; end
            4'd5: begin cfg_addr=REG_ALT_CONF;   cfg_data=VAL_ALT_CONF; end
            4'd6: begin cfg_addr=REG_D_CONF;     cfg_data=VAL_D_CONF;   end
            default: begin cfg_addr=REG_START_CONF; cfg_data=VAL_ACTIVE; end // activate last
        endcase
    end
    localparam [3:0] CFG_COUNT = 4'd8;

    reg [2:0] data_idx;
    reg [6:0] data_addr;
    always @(*) begin
        case (data_idx)             // STATUS read LAST so RP/L timing == known-good
            3'd0: data_addr=REG_RP_DATA_L;
            3'd1: data_addr=REG_RP_DATA_H;
            3'd2: data_addr=REG_L_DATA_L;
            3'd3: data_addr=REG_L_DATA_H;
            default: data_addr=REG_STATUS;
        endcase
    end
    reg [7:0] st_byte, rp_lo, rp_hi, l_lo, l_hi, id_byte;

    //=========================================================================
    // RP smoothing: 1/16 EMA (leaky integrator) on a glitch-gated raw sample.
    //   valid sample = both RP and L nonzero (the occasional RP=0000/L=0000 line
    //   is a register-update transient — reject it, don't fold/show it).
    //   rp_acc += rawRP - rp_acc>>4   (steady-state rp_acc = 16*rawRP)
    //   rp_avg  = rp_acc>>4 ; seeded on first valid sample for instant lock.
    // L is left as last-valid raw (no averaging) to keep honest per-sample std
    //   for the paper; only the 0000 glitch is gated out.
    //=========================================================================
    reg  [23:0] rp_acc;     // EMA accumulator (16*avg)
    reg  [15:0] l_disp;     // last valid raw L
    reg         ema_init;   // 0 until first valid sample seeds rp_acc
    wire [15:0] rp_avg = rp_acc[19:4];

    //=========================================================================
    // MAIN FSM — race-free ISSUE -> WAIT(spi_done) -> capture. 16-bit txns.
    //=========================================================================
    localparam [4:0]
        S_POR  =5'd0,  S_CFG  =5'd1,  S_CFG_I=5'd2,  S_CFG_N=5'd3,
        S_ID_I =5'd4,  S_ID_C =5'd5,  S_RD_I =5'd6,  S_RD_C =5'd7,
        S_BUILD=5'd8,  S_PRINT=5'd9,  S_PWAIT=5'd10, S_LOOP =5'd11, S_WAIT=5'd12,
        S_AVG  =5'd13;

    reg [4:0]  state, ret_state;
    reg [22:0] delay_cnt;
    localparam [22:0] POR_CYC  = 23'd1_350_000;  // ~50 ms
    localparam [22:0] LOOP_CYC = 23'd1_350_000;  // ~50 ms between RP/L samples

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_POR; ret_state<=S_POR; delay_cnt<=23'd0;
            spi_start<=1'b0; load_data<=24'h0; total_bits<=6'd16;
            cfg_idx<=4'd0; data_idx<=3'd0;
            led_init<=1'b1; led_acq<=1'b1; led_err<=1'b1;
            print_start<=1'b0; plen<=6'd0;
            rp_lo<=8'd0; rp_hi<=8'd0; l_lo<=8'd0; l_hi<=8'd0; id_byte<=8'd0; st_byte<=8'd0;
            rp_acc<=24'd0; l_disp<=16'd0; ema_init<=1'b0;
        end else begin
            spi_start   <= 1'b0;
            print_start <= 1'b0;

            case (state)
            S_POR: begin
                led_init<=1'b1;
                if (delay_cnt==POR_CYC) begin delay_cnt<=23'd0; state<=S_CFG; end
                else delay_cnt<=delay_cnt+23'd1;
            end
            S_CFG: begin
                if (cfg_idx==CFG_COUNT) begin led_init<=1'b0; state<=S_ID_I; end
                else state<=S_CFG_I;
            end
            S_CFG_I: begin   // WREG {0,cfg_addr}, cfg_data
                load_data<={WRITE_BIT, cfg_addr, cfg_data, 8'h00}; total_bits<=6'd16;
                spi_start<=1'b1; ret_state<=S_CFG_N; state<=S_WAIT;
            end
            S_CFG_N: begin cfg_idx<=cfg_idx+4'd1; state<=S_CFG; end
            S_ID_I: begin    // read CHIP_ID(0x3F)
                load_data<={READ_BIT, REG_CHIP_ID, 8'hFF, 8'h00}; total_bits<=6'd16;
                spi_start<=1'b1; ret_state<=S_ID_C; state<=S_WAIT;
            end
            S_ID_C: begin
                id_byte <= spi_rx[7:0];
                led_err <= (spi_rx[7:0]!=8'hD4) ? 1'b0:1'b1;  // ON(low) if != D4
                data_idx<=3'd0; state <= S_RD_I;
            end
            S_RD_I: begin    // read RP/L data byte
                load_data<={READ_BIT, data_addr, 8'hFF, 8'h00}; total_bits<=6'd16;
                spi_start<=1'b1; ret_state<=S_RD_C; state<=S_WAIT;
            end
            S_RD_C: begin
                case (data_idx)
                    3'd0: rp_lo <= spi_rx[7:0];
                    3'd1: rp_hi <= spi_rx[7:0];
                    3'd2: l_lo  <= spi_rx[7:0];
                    3'd3: l_hi  <= spi_rx[7:0];
                    default: st_byte <= spi_rx[7:0];
                endcase
                if (data_idx==3'd4) begin data_idx<=3'd0; state<=S_AVG; end
                else begin data_idx<=data_idx+3'd1; state<=S_RD_I; end
            end
            S_AVG: begin     // glitch-gate (both nonzero) -> fold RP into EMA, latch L
                if ((rp_hi|rp_lo)!=8'd0 && (l_hi|l_lo)!=8'd0) begin
                    l_disp <= {l_hi, l_lo};
                    if (!ema_init) begin
                        rp_acc   <= {rp_hi, rp_lo, 4'd0};   // seed = 16*raw -> instant lock
                        ema_init <= 1'b1;
                    end else begin
                        rp_acc <= rp_acc - (rp_acc >> 4) + {8'd0, rp_hi, rp_lo};
                    end
                end
                state <= S_BUILD;       // invalid sample: hold last avg/L, just reprint
            end
            S_BUILD: begin
                // "ID=hh ST=hh RP=hhhh L=hhhh\r\n"  (RP = 1/16 EMA, L = last valid)
                pbuf[0]<="I";pbuf[1]<="D";pbuf[2]<="=";
                pbuf[3]<=hex_char(id_byte[7:4]); pbuf[4]<=hex_char(id_byte[3:0]);
                pbuf[5]<=" ";
                pbuf[6]<="S";pbuf[7]<="T";pbuf[8]<="=";
                pbuf[9] <=hex_char(st_byte[7:4]); pbuf[10]<=hex_char(st_byte[3:0]);
                pbuf[11]<=" ";
                pbuf[12]<="R";pbuf[13]<="P";pbuf[14]<="=";
                pbuf[15]<=hex_char(rp_avg[15:12]); pbuf[16]<=hex_char(rp_avg[11:8]);
                pbuf[17]<=hex_char(rp_avg[7:4]);   pbuf[18]<=hex_char(rp_avg[3:0]);
                pbuf[19]<=" ";
                pbuf[20]<="L";pbuf[21]<="=";
                pbuf[22]<=hex_char(l_disp[15:12]); pbuf[23]<=hex_char(l_disp[11:8]);
                pbuf[24]<=hex_char(l_disp[7:4]);   pbuf[25]<=hex_char(l_disp[3:0]);
                pbuf[26]<=" "; pbuf[27]<="M"; pbuf[28]<="0";  // build tag: Mode-0 SPI revert
                pbuf[29]<=8'h0D; pbuf[30]<=8'h0A;
                plen<=6'd31; state<=S_PRINT;
            end
            S_PRINT: begin print_start<=1'b1; state<=S_PWAIT; end
            S_PWAIT: begin
                if (!print_busy && !print_start) begin led_acq<=~led_acq; state<=S_LOOP; end
            end
            S_LOOP: begin    // re-read STATUS+RP/L (no re-config); ~50 ms
                if (delay_cnt==LOOP_CYC) begin delay_cnt<=23'd0; data_idx<=3'd0; state<=S_RD_I; end
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
