`timescale 1ns/1ps
//=============================================================================
// ldc1101_spi.v  — LDC1101 sampling SPI master (inductive L + RP)
//
// REWRITTEN 2026-06-17 after real-hardware bring-up. Two fixes vs the prior
// version (both proven on HW via gowin_syn/ldc_regcheck.v, which read
// CHIP_ID=0xD4 and round-tripped a WREG/RREG):
//
//   FIX 1 — SPI MODE 0 -> MODE 3 (CPOL=1, CPHA=1). The LDC1101 is Mode 3, NOT
//     Mode 0 (the old alignment-doc spec was wrong). Mode 0 read 0xFF on every
//     board; Mode 3 reads 0xD4. SCLK idles HIGH; MOSI changes on the FALLING
//     (leading) edge and the LDC updates SDO there; both sample on the RISING
//     (trailing) edge. (Confirmed against a working Mbed driver: format(8,3).)
//
//   FIX 2 — race-free FSM. The old per-byte FSM re-issued the SAME byte on the
//     spi_done cycle, so a WREG sent the ADDRESS byte twice and never the DATA
//     byte -> every config write was corrupted (CHIP_ID reads happened to be
//     immune). Now every 2-byte transaction is issued once
//     (ISSUE -> WAIT(spi_done) -> capture) via a 16-bit engine; the read data
//     byte lands in spi_rx[7:0].
//
// Sequence: POR -> WREG config list (RP+L active mode) -> read CHIP_ID (err_flag
// if != 0xD4) -> loop { read RP_DATA(L,H)+L_DATA(L,H) -> emit rp_data/l_data,
// pulse data_valid }. Config values are datasheet-typical and MUST be tuned for
// the actual LC tank on the bench. Ports unchanged (ttcgs_board instantiates
// this as-is). SCLK ~500 kHz.
//=============================================================================
module ldc1101_spi (
    input  wire        clk,          // 27 MHz
    input  wire        rst_n,

    // LDC1101 SPI bus (Mode 3)
    output reg         ldc_cs_n,
    output reg         ldc_sclk,     // idles HIGH (Mode 3)
    output reg         ldc_sdi,      // MOSI
    input  wire        ldc_sdo,      // MISO
    output wire        ldc_clkin,    // ~3.375 MHz reference clock for L (clk27/8)

    // to downstream DSP chain
    output reg         data_valid,
    output reg [15:0]  rp_data,
    output reg [15:0]  l_data,
    output reg         init_done,
    output reg         err_flag      // CHIP_ID mismatch
);
    localparam integer HALF       = 27;        // ~500 kHz SCLK (period = 2*HALF)
    localparam [22:0]  POR_DELAY  = 23'd135000; // ~5 ms power-on wait
    localparam [22:0]  LOOP_DELAY = 23'd27000;  // ~1 kHz RP/L sample loop

    localparam READ_BIT = 1'b1, WRITE_BIT = 1'b0;
    localparam [6:0] REG_RP_SET=7'h01, REG_TC1=7'h02, REG_TC2=7'h03,
                     REG_DIG_CONF=7'h04, REG_ALT_CONF=7'h05, REG_D_CONF=7'h0C,
                     REG_START_CONF=7'h0B,
                     REG_RP_DATA_L=7'h21, REG_RP_DATA_H=7'h22,
                     REG_L_DATA_L=7'h23,  REG_L_DATA_H=7'h24, REG_CHIP_ID=7'h3F;
    // Config validated on HW (ldc_regcheck): with CLKIN, L responds to metal.
    // DIG_CONF=0x06 (MIN_FREQ=0 + RESP_TIME=3072) for a readable L_DATA. RP_SET/
    // TC1/TC2 are still placeholders — RP stays noisy until tuned to the real
    // sensor's RP/Q (a bench-characterization task); L is the clean channel.
    localparam [7:0] VAL_RP_SET=8'h07, VAL_TC1=8'h90, VAL_TC2=8'hA0,
                     VAL_DIG_CONF=8'h06, VAL_ALT_CONF=8'h00, VAL_D_CONF=8'h00,
                     VAL_SLEEP=8'h01,    // START_CONFIG sleep/stop (configure in sleep)
                     VAL_ACTIVE=8'h00;   // START_CONFIG active (RP+L conversion)
    localparam [7:0] CHIP_ID_EXP = 8'hD4;

    //--------------------------------------------------- CLKIN generator
    // clk27/8 ≈ 3.375 MHz (within LDC 1-16 MHz). The L measurement REQUIRES this
    // reference clock (fSENSOR = fCLKIN*RESP_TIME/(3*L_DATA)); RP does not.
    // Lowered from 13.5MHz + DRIVE=4 (cst) to limit coupling into the LC tank.
    reg [2:0] clkin_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) clkin_cnt <= 3'd0;
        else        clkin_cnt <= clkin_cnt + 3'd1;
    end
    assign ldc_clkin = clkin_cnt[2];

    //--------------------------------------------------- SPI byte engine (MODE 3)
    reg        spi_start, spi_busy, spi_done;
    reg [23:0] load_data, shift_out, spi_rx;
    reg [5:0]  total_bits, bit_cnt;
    reg [4:0]  div;
    reg        phase;   // 0 = next edge FALLING (change), 1 = next edge RISING (sample)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ldc_cs_n<=1'b1; ldc_sclk<=1'b1; ldc_sdi<=1'b0;   // SCLK idle HIGH
            spi_busy<=1'b0; spi_done<=1'b0; spi_rx<=24'h0;
            shift_out<=24'h0; bit_cnt<=6'd0; div<=5'd0; phase<=1'b0;
        end else begin
            spi_done <= 1'b0;
            if (spi_start && !spi_busy) begin
                ldc_cs_n  <= 1'b0;
                ldc_sclk  <= 1'b1;
                shift_out <= load_data;
                bit_cnt   <= total_bits;
                div       <= 5'd0;
                phase     <= 1'b0;
                spi_busy  <= 1'b1;
            end else if (spi_busy) begin
                if (div==HALF-1) begin
                    div <= 5'd0;
                    if (phase==1'b0) begin
                        ldc_sclk  <= 1'b0;                 // FALLING: change MOSI
                        ldc_sdi   <= shift_out[23];
                        shift_out <= {shift_out[22:0], 1'b0};
                        phase     <= 1'b1;
                    end else begin
                        ldc_sclk <= 1'b1;                  // RISING: sample MISO
                        spi_rx   <= {spi_rx[22:0], ldc_sdo};
                        phase    <= 1'b0;
                        if (bit_cnt==6'd1) begin
                            spi_busy <= 1'b0;
                            ldc_cs_n <= 1'b1;
                            spi_done <= 1'b1;
                        end else bit_cnt <= bit_cnt - 6'd1;
                    end
                end else div <= div + 5'd1;
            end
        end
    end

    //--------------------------------------------------- config write list
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

    //--------------------------------------------------- data read addresses
    reg [1:0] data_idx;
    reg [6:0] data_addr;
    always @(*) begin
        case (data_idx)
            2'd0: data_addr=REG_RP_DATA_L;
            2'd1: data_addr=REG_RP_DATA_H;
            2'd2: data_addr=REG_L_DATA_L;
            default: data_addr=REG_L_DATA_H;
        endcase
    end
    reg [7:0] rp_lo, rp_hi, l_lo, l_hi;

    //--------------------------------------------------- control FSM (race-free)
    // 16-bit transactions: WREG {0,addr}+data ; RREG {1,addr}+dummy -> spi_rx[7:0]
    localparam [4:0]
        S_POR  =5'd0,  S_CFG  =5'd1,  S_CFG_I=5'd2,  S_CFG_N=5'd3,
        S_ID_I =5'd4,  S_ID_C =5'd5,  S_RD_I =5'd6,  S_RD_C =5'd7,
        S_EMIT =5'd8,  S_DLY  =5'd9,  S_WAIT =5'd10;

    reg [4:0]  state, ret_state;
    reg [22:0] delay_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_POR; ret_state<=S_POR; delay_cnt<=23'd0;
            spi_start<=1'b0; load_data<=24'h0; total_bits<=6'd16;
            cfg_idx<=4'd0; data_idx<=2'd0;
            init_done<=1'b0; err_flag<=1'b0; data_valid<=1'b0;
            rp_data<=16'd0; l_data<=16'd0;
            rp_lo<=8'd0; rp_hi<=8'd0; l_lo<=8'd0; l_hi<=8'd0;
        end else begin
            spi_start  <= 1'b0;
            data_valid <= 1'b0;

            case (state)
            S_POR: begin
                if (delay_cnt==POR_DELAY) begin delay_cnt<=23'd0; state<=S_CFG; end
                else delay_cnt<=delay_cnt+23'd1;
            end
            // ── walk config write list ───────────────────────────────────
            S_CFG: begin
                if (cfg_idx==CFG_COUNT) begin init_done<=1'b1; state<=S_ID_I; end
                else state<=S_CFG_I;
            end
            S_CFG_I: begin   // WREG {WRITE_BIT,cfg_addr}, cfg_data  (16 bits)
                load_data  <= {WRITE_BIT, cfg_addr, cfg_data, 8'h00};
                total_bits <= 6'd16;
                spi_start  <= 1'b1; ret_state <= S_CFG_N; state <= S_WAIT;
            end
            S_CFG_N: begin cfg_idx <= cfg_idx + 4'd1; state <= S_CFG; end
            // ── CHIP_ID sanity (read 0x3F, expect 0xD4) ──────────────────
            S_ID_I: begin
                load_data  <= {READ_BIT, REG_CHIP_ID, 8'hFF, 8'h00};
                total_bits <= 6'd16;
                spi_start  <= 1'b1; ret_state <= S_ID_C; state <= S_WAIT;
            end
            S_ID_C: begin
                err_flag <= (spi_rx[7:0] != CHIP_ID_EXP);
                state    <= S_RD_I;
            end
            // ── read RP_L, RP_H, L_L, L_H ────────────────────────────────
            S_RD_I: begin
                load_data  <= {READ_BIT, data_addr, 8'hFF, 8'h00};
                total_bits <= 6'd16;
                spi_start  <= 1'b1; ret_state <= S_RD_C; state <= S_WAIT;
            end
            S_RD_C: begin
                case (data_idx)
                    2'd0: rp_lo <= spi_rx[7:0];
                    2'd1: rp_hi <= spi_rx[7:0];
                    2'd2: l_lo  <= spi_rx[7:0];
                    default: l_hi <= spi_rx[7:0];
                endcase
                if (data_idx==2'd3) begin data_idx<=2'd0; state<=S_EMIT; end
                else begin data_idx<=data_idx+2'd1; state<=S_RD_I; end
            end
            S_EMIT: begin
                rp_data    <= {rp_hi, rp_lo};
                l_data     <= {l_hi, l_lo};
                data_valid <= 1'b1;
                delay_cnt  <= 23'd0;
                state      <= S_DLY;
            end
            S_DLY: begin     // ~1 kHz sample loop
                if (delay_cnt==LOOP_DELAY) begin delay_cnt<=23'd0; state<=S_RD_I; end
                else delay_cnt<=delay_cnt+23'd1;
            end
            // ── shared wait: hold until the SPI transaction completes ─────
            S_WAIT: begin
                if (spi_done) state <= ret_state;
            end
            default: state <= S_POR;
            endcase
        end
    end
endmodule
