// ads114s08_spi.v
// ADS114S08 SPI master — Phase 1 bring-up version (v2, hardware-validated timing)
//
// REWRITTEN 2026-06-17 after real-hardware bring-up (関1) on the Tang Nano 9K.
// The previous version returned garbage (0000/8005). Root cause was NOT wiring/
// mode/chip (all verified good) but two bugs in THIS file, both now fixed:
//
//   BUG 1 — FSM handshake RACE: the old FSM pulsed spi_start and transitioned/
//     captured in the SAME cycle, but the engine only asserts spi_busy the NEXT
//     cycle. So the capture state ran one cycle too early and latched STALE
//     spi_rx (the 0000/8005), and the DR/channel-switch WREGs were eaten.
//     FIX: race-free ISSUE -> WAIT(spi_done) -> capture. Every transaction is
//     issued (1-cycle spi_start pulse) then we wait for the engine's spi_done
//     pulse before doing anything else.
//
//   BUG 2 — engine drops the LAST clocked bit (CS deasserts on the final
//     sclk_fall before a final rising). Empirically (proven via ads_regcheck on
//     real HW) BOTH read and write need total_bits = useful_bits + 1. E.g. a
//     3-byte (24-bit) WREG/RREG must clock 25; RDATA (8 cmd + 16 data) clocks
//     25 and the 16-bit result lands in spi_rx[15:0]. Single-byte commands
//     (RESET/START, 8 bits) clock 8 (validated: RESET at 8 reset the device).
//
// Validation (ads_regcheck.v, real HW): RREG DATARATE returned its reset 0x14
// exactly; WREG DATARATE=0x1A then RREG read back 0x1A; ID reg = 0x0C, stable.
// The bit ENGINE/divider/edges below are the ORIGINAL (the ADS responds to
// them) — only spi_done was added; the FSM and bit counts are the fix.
//
// SPI Mode 1-ish: SCLK idle LOW, DIN shifted on falling, DOUT sampled on rising.
// Clock: 27 MHz; SPI ~1.93 MHz (CLK_DIV=14). Ports unchanged (top_bringup /
// ttcgs_board instantiate this as-is).

module ads114s08_spi #(
    // ─── SINGLE_CH: convert one input instead of cycling all four ────────────
    // Four-channel round-robin costs a factor of four on the channel that has a
    // sensor on it, because it waits out three conversions of inputs sitting at
    // 0-2 counts. It also pays a 52 us INPMUX write per channel that is not
    // needed when the mux never changes.
    //
    //   SINGLE_CH = 0   1713 us x 4   ->  146 SPS per channel
    //   SINGLE_CH = 1   1660 us       ->  602 SPS on the selected input
    //
    // 86% of the remaining time is the conversion itself (1250 us at DR = 800
    // SPS plus 218 us of single-shot start-up), so DATARATE is the next lever
    // if more is wanted - 0x3A -> 0x3D gives about 1500 SPS, at the cost of
    // noise. Measure before spending that.
    //
    // SINGLE_IDX indexes mux_table: 0 = AIN5 (corner B), 1 = AIN4 (A),
    // 2 = AIN1 (D), 3 = AIN0 (C).
    parameter        SINGLE_CH  = 0,
    parameter [1:0]  SINGLE_IDX = 2'd0
) (
    input  wire        clk,          // 27 MHz
    input  wire        rst_n,        // active-low reset

    // ADS114S08 physical pins
    output reg         ads_cs_n,
    output reg         ads_sclk,
    output reg         ads_din,
    input  wire        ads_dout,
    input  wire        ads_drdy_n,
    output reg         ads_start,    // START pin (assert for continuous conv)

    // Output to downstream logic
    output reg         data_valid,
    output reg [15:0]  data_out,
    output reg [1:0]   ch_out,
    output reg         init_done,
    output reg         err_flag
);

// ─── SPI clock divider (VERBATIM original) ─────────────────────────────────────
// 2026-07-03: was 14 (~1.93 MHz). On the current wiring ~32% of reads came back
// bit-misaligned or railed (0x7Fxx) in EVERY bitstream — ADS-only, dual-simul
// and dual-timemux alike — i.e. a marginal SPI link, not core interference.
// 56 -> 27 MHz / 56 = ~482 kHz, 4x the setup/hold margin over long jumpers.
// SCLK period is CLK_DIV system clocks (counter wraps at CLK_DIV, falling
// strobe at CLK_DIV/2) -- NOT 2*CLK_DIV. Comments here said 241 kHz by
// dividing by 112; corrected 2026-08-07 after a logic analyser measured
// 2.074 us/clock = 482 kHz. See DATA/2026-08-07_ADS-SPI-DRDY_*.sr.
// Counter widened to 8 bits to hold the larger count. Raise back once the
// harness is short/properly grounded, if the extra sample rate is wanted.
localparam CLK_DIV = 56;            // 27 MHz / 56 = ~482 kHz
reg [7:0]  clk_cnt;
reg        sclk_en;                 // rising-edge strobe
reg        sclk_fall;               // falling-edge strobe
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        clk_cnt   <= 0;
        sclk_en   <= 0;
        sclk_fall <= 0;
    end else begin
        sclk_en   <= 0;
        sclk_fall <= 0;
        if (clk_cnt == CLK_DIV - 1) begin
            clk_cnt <= 0;
            sclk_en <= 1;
        end else if (clk_cnt == (CLK_DIV/2) - 1) begin
            sclk_fall <= 1;
            clk_cnt   <= clk_cnt + 1;
        end else begin
            clk_cnt <= clk_cnt + 1;
        end
    end
end

// ─── DRDY# falling-edge detect (VERBATIM original) ─────────────────────────────
reg drdy_r0, drdy_r1;
wire drdy_fall   = drdy_r0 & ~drdy_r1;   // ads_drdy_n 0->1 (deassert)  [unused in single-shot]
wire drdy_assert = drdy_r1 & ~drdy_r0;   // ads_drdy_n 1->0 = DATA READY (single-shot)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin drdy_r0 <= 1'b1; drdy_r1 <= 1'b1; end
    else begin drdy_r1 <= drdy_r0; drdy_r0 <= ads_drdy_n; end
end

// ─── Channel MUX table (VERBATIM): AINP=AIN5/4/1/0, AINN=AINCOM(0xC) ───────────
reg [7:0] mux_table [0:3];
initial begin
    mux_table[0] = 8'h5C; // AIN5
    mux_table[1] = 8'h4C; // AIN4
    mux_table[2] = 8'h1C; // AIN1
    mux_table[3] = 8'h0C; // AIN0
end

// ─── SPI byte engine (VERBATIM original) + spi_done pulse ──────────────────────
reg        spi_start, spi_busy, spi_done;
reg [23:0] load_data, shift_out, spi_rx;
reg [5:0]  total_bits, bit_cnt;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ads_cs_n  <= 1'b1;
        ads_sclk  <= 1'b0;
        ads_din   <= 1'b0;
        spi_busy  <= 1'b0;
        spi_done  <= 1'b0;
        spi_rx    <= 24'h0;
        bit_cnt   <= 0;
        shift_out <= 24'h0;
    end else begin
        spi_done <= 1'b0;
        if (spi_start && !spi_busy) begin
            ads_cs_n  <= 1'b0;
            ads_sclk  <= 1'b0;
            bit_cnt   <= total_bits - 1;
            spi_busy  <= 1'b1;
            shift_out <= load_data;
        end
        if (spi_busy) begin
            if (sclk_en) begin
                ads_sclk <= 1'b1;
                spi_rx   <= {spi_rx[22:0], ads_dout};   // sample MISO on rising
            end
            if (sclk_fall) begin
                ads_sclk  <= 1'b0;
                ads_din   <= shift_out[23];             // shift MOSI on falling
                shift_out <= {shift_out[22:0], 1'b0};
                if (bit_cnt == 0) begin
                    spi_busy <= 1'b0;
                    ads_cs_n <= 1'b1;
                    spi_done <= 1'b1;                   // completion pulse (new)
                end else bit_cnt <= bit_cnt - 1;
            end
        end
    end
end

// ─── Main FSM — race-free ISSUE -> WAIT(spi_done) -> capture ───────────────────
// Sequence: RESET -> WREG REF -> WREG DATARATE (single-shot) -> then per channel:
//           { WREG INPMUX(ch) -> START(one conv) -> wait DRDY -> RDATA ->
//             capture -> next ch }. SINGLE-SHOT: one START = one clean conversion
//           on the selected mux, so there is NO continuous-mode boundary race.
//
// Bit counts (BUG 2): single-byte cmds=8; 3-byte WREG=25; RDATA(8+16)=25,
// data in spi_rx[15:0].
localparam [4:0]
    S_POR      = 5'd0,
    S_RST_I    = 5'd1,
    S_RST_GAP  = 5'd2,
    S_REF_I    = 5'd3,
    S_DR_I     = 5'd4,
    S_MUX_I    = 5'd5,
    S_START_I  = 5'd6,
    S_WAITDR   = 5'd7,
    S_RDATA_I  = 5'd8,
    S_RDATA_C  = 5'd9,
    S_WAIT     = 5'd10;

reg [4:0]  state, ret_state;
reg [20:0] wait_cnt;          // up to ~78 ms
reg [1:0]  ch_idx;

// ─── RD_REPEAT: read each conversion several times, keep the largest ──────────
// The divider below free-runs, so CS falls at an arbitrary point in its 56-clock
// period and the transaction contains either 16 or 17 SCLK rising edges. Reads
// sample MISO on rises, so one edge fewer means one bit fewer and the captured
// word is exactly HALF. Measured on a fixed 100 kohm: 38-52% of reads halved,
// and the proportion is not reproducible across power cycles (one session ran at
// 100%).
//
// Only reads are affected. Writes shift MOSI on falls and the fall count is
// fixed, which is why the config WREGs always verified. And only THIS read is
// exposed, because it is a direct read carrying no command byte (see S_RDATA_I)
// -- there is nothing for the device to frame against, so the bit alignment is
// set purely by CS phase.
//
// Rather than chase that phase (four attempts on 2026-08-16 each made it worse
// or stopped conversion entirely -- see git history), this is immune by
// construction: corruption only ever HALVES, so the largest of N reads is
// correct unless all N were corrupted. In single-shot the data register holds
// its value until the next START, so re-reading returns the same conversion.
//
//   1 read   ~44% wrong        4 reads  2.6%
//   2 reads   19%              5 reads  1.0%
//   3 reads  7.7%              6 reads  0.4%
//
// Cost: 4 extra 35 us transactions per channel on a 1572 us conversion, so
// 159 -> ~138 SPS per channel.
//
// Compare on MAGNITUDE, not value: halving moves a negative reading UP, so a
// plain unsigned max would pick the corrupted one on channels sitting near zero.
localparam [2:0] RD_REPEAT = 3'd5;
reg [15:0] rd_max;
reg [2:0]  rd_cnt;

function [15:0] absv;
    input [15:0] x;
    begin absv = x[15] ? (~x + 16'd1) : x; end
endfunction
// SINGLE-SHOT per channel: set MUX, START one conversion, wait its DRDY, read.
// Each conversion is taken fully on the selected mux AFTER it settled, so there
// is no continuous-mode boundary race -> no more intermittent 0x7F8D (~+FS) rails.

localparam [20:0] POR_CYC = 21'd135000;   // ~5 ms power-on
localparam [20:0] GAP_CYC = 21'd270000;   // ~10 ms after RESET

// REF: REFSEL=10 (internal 2.5V), REFCON=10 (always on). VERIFY/TUNE for tank/sensor.
localparam [7:0] VAL_REF = 8'h0A;
// DATARATE(04h): [7]=0 [6]=CLK src [5]=MODE [4]=FILTER [3:0]=DR.
// 0x3A = MODE 1 (single-shot) + FILTER 1, DR = 800 SPS, CLK = internal.
//
// EXT_CLK=1 additionally sets bit6 -> take the system clock from the CLK pin.
// The internal oscillator is 4.096 MHz with only 2% accuracy AND "the data rate
// scales with internal oscillator variation" — so the sample rate drifts with
// temperature. TTCGS defines its DoG sigmas in SAMPLES, so a drifting rate drags
// the claimed passbands with it. Driving CLK from the FPGA makes the rate
// crystal-accurate (+-20 ppm) and coherent with the LDC's CLKIN.
//   Allowed fCLK is 2-4.5 MHz (need NOT be 4.096): 27 MHz/7 = 3.857 MHz is the
//   closest with margin, and scales every data rate by 0.942 (800 -> 753 SPS).
// Only enable once the board actually routes FPGA -> ADS CLK; with the pin left
// at DGND the device must stay on the internal oscillator.
// NOTE: a RESET (pin or command) reverts the device to the internal oscillator,
// so this bit has to be re-applied on every init — it is, since DATARATE is
// written after the reset in the sequence below.
localparam EXT_CLK = 1'b0;
localparam [7:0] VAL_DR  = EXT_CLK ? 8'h7A : 8'h3A;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= S_POR;
        ret_state  <= S_POR;
        wait_cnt   <= 21'd0;
        spi_start  <= 1'b0;
        load_data  <= 24'h0;
        total_bits <= 6'd8;
        data_valid <= 1'b0;
        data_out   <= 16'h0;
        ch_out     <= 2'h0;
        ch_idx     <= SINGLE_CH ? SINGLE_IDX : 2'h0;
        init_done  <= 1'b0;
        err_flag   <= 1'b0;
        ads_start  <= 1'b0;
        rd_max     <= 16'h0;
        rd_cnt     <= 3'd0;
    end else begin
        spi_start  <= 1'b0;
        data_valid <= 1'b0;

        case (state)
        // ── power-on wait ─────────────────────────────────────────────────
        S_POR: begin
            if (wait_cnt == POR_CYC) begin wait_cnt <= 21'd0; state <= S_RST_I; end
            else wait_cnt <= wait_cnt + 21'd1;
        end
        // ── RESET (0x06, single byte = 8 bits) ────────────────────────────
        S_RST_I: begin
            load_data <= {8'h06, 16'h0}; total_bits <= 6'd8;
            spi_start <= 1'b1; ret_state <= S_RST_GAP; state <= S_WAIT;
        end
        S_RST_GAP: begin
            if (wait_cnt == GAP_CYC) begin wait_cnt <= 21'd0; state <= S_REF_I; end
            else wait_cnt <= wait_cnt + 21'd1;
        end
        // ── WREG REF (0x05) = internal 2.5V ref. {0x45,0x00,VAL_REF}, 25 bits
        S_REF_I: begin
            load_data <= {8'h45, 8'h00, VAL_REF}; total_bits <= 6'd25;
            spi_start <= 1'b1; ret_state <= S_DR_I; state <= S_WAIT;
        end
        // ── WREG DATARATE = single-shot mode (config ONCE). {0x44,0x00,VAL_DR},25b
        S_DR_I: begin
            load_data <= {8'h44, 8'h00, VAL_DR}; total_bits <= 6'd25;
            spi_start <= 1'b1; init_done <= 1'b1; ret_state <= S_MUX_I; state <= S_WAIT;
        end
        // ── per-channel SINGLE-SHOT: WREG INPMUX(ch). {0x42,0x00,mux}, 25 bits ──
        S_MUX_I: begin
            load_data <= {8'h42, 8'h00, mux_table[ch_idx]}; total_bits <= 6'd25;
            spi_start <= 1'b1; ret_state <= S_START_I; state <= S_WAIT;
        end
        // ── START (0x08): trigger exactly ONE conversion on the settled mux ────
        S_START_I: begin
            load_data <= {8'h08, 16'h0}; total_bits <= 6'd8;
            spi_start <= 1'b1; ret_state <= S_WAITDR; state <= S_WAIT;
        end
        // ── wait THIS conversion's DRDY# ASSERTION (1->0 = data ready) ─────────
        S_WAITDR: begin
            if (drdy_assert) begin
                rd_max <= 16'h0; rd_cnt <= 3'd0; state <= S_RDATA_I;
            end
        end
        // ── DIRECT read: single-shot leaves DRDY# LOW, so the ADS already drives
        //    the conversion data onto MISO. Read it by clocking 16(+1) bits with NO
        //    RDATA command (0x12 would collide with that auto-output -> byte shift).
        S_RDATA_I: begin
            load_data <= 24'h0; total_bits <= 6'd17;       // 16 data + 1 (engine BUG2)
            spi_start <= 1'b1; ret_state <= S_RDATA_C; state <= S_WAIT;
        end
        // ── capture: keep the largest-magnitude of RD_REPEAT reads (see above) ─
        S_RDATA_C: begin
            if (rd_cnt == RD_REPEAT - 3'd1) begin
                data_out   <= (absv(spi_rx[15:0]) > absv(rd_max)) ? spi_rx[15:0]
                                                                  : rd_max;
                ch_out     <= ch_idx;
                data_valid <= 1'b1;
                if (SINGLE_CH) begin
                    // mux is already on SINGLE_IDX and never moves, so skip the
                    // INPMUX write and go straight to the next conversion
                    state  <= S_START_I;
                end else begin
                    ch_idx <= ch_idx + 2'd1;
                    state  <= S_MUX_I;
                end
            end else begin
                if (absv(spi_rx[15:0]) > absv(rd_max)) rd_max <= spi_rx[15:0];
                rd_cnt <= rd_cnt + 3'd1;
                state  <= S_RDATA_I;
            end
        end
        // ── shared wait: hold until the SPI transaction actually completes ─
        S_WAIT: begin
            if (spi_done) state <= ret_state;
        end
        default: begin err_flag <= 1'b1; state <= S_POR; end
        endcase
    end
end

endmodule
