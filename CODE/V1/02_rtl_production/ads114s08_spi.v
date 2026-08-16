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

module ads114s08_spi (
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

// declared here (not with the engine below) so the divider can see the launch
reg        spi_start, spi_busy, spi_done;
wire       spi_launch = spi_start & ~spi_busy;

// ─── PHASE RESET on transaction start — fixes a random one-bit read shift ─────
// 2026-08-16. This divider used to free-run, so CS fell at an arbitrary point in
// the 56-clock period and the strobe that arrived FIRST was whichever came next:
//
//   clk_cnt 0..27 at CS  -> sclk_fall first:  F R F R ... F16 R16 F17(end)
//                           = 16 MISO samples -> spi_rx[15:0] is data>>1 = HALF
//   clk_cnt 28..55 at CS -> sclk_en   first:  R F R F ... R17 F17(end)
//                           = 17 MISO samples -> spi_rx[15:0] is the data
//
// The transaction always ends on the 17th sclk_fall (bit_cnt counts falls), so
// the number of RISING edges inside it — i.e. the number of MISO samples — was
// one more or one less depending on nothing but arrival phase. That is the
// factor-of-two population seen in every capture: 43.7% halved on a fixed
// 100 kohm, ~50/50 by nature because the phase is effectively random.
//
// Writes were never affected: MOSI shifts on falls and the fall count is fixed.
// Only the read path samples on rises, which is why the config WREGs always
// verified while the data reads did not.
//
// Loading CLK_DIV/2 forces the sclk_en-first ordering, so every read gets 17
// samples. RD_DELAY below cannot fix this and never could — it only nudged the
// phase, which is why one run landed at 0.04% and the next at 43.7%.
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        clk_cnt   <= 0;
        sclk_en   <= 0;
        sclk_fall <= 0;
    end else if (spi_launch) begin
        clk_cnt   <= CLK_DIV/2;     // next strobe is sclk_en -> rise-first
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
// spi_start / spi_busy / spi_done are declared up with the clock divider, which
// needs spi_launch to reset the phase.
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
    S_WAIT     = 5'd10,
    S_RDLY     = 5'd11;   // settling gap between DRDY and the data read

reg [4:0]  state, ret_state;
reg [20:0] wait_cnt;          // up to ~78 ms
reg [1:0]  ch_idx;
// SINGLE-SHOT per channel: set MUX, START one conversion, wait its DRDY, read.
// Each conversion is taken fully on the selected mux AFTER it settled, so there
// is no continuous-mode boundary race -> no more intermittent 0x7F8D (~+FS) rails.

localparam [20:0] POR_CYC = 21'd135000;   // ~5 ms power-on
localparam [20:0] GAP_CYC = 21'd270000;   // ~10 ms after RESET

// ─── RD_DELAY: settling gap between DRDY# falling and starting the data read ──
// 2026-08-16. Captures held two populations EXACTLY a factor of two apart, on
// 1.7-27.5% of samples depending on the run. An analog effect cannot produce an
// exact factor of two; a one-bit shift can, and it is the only thing that can.
//
// S_RDATA_I clocks 17 bits for a 16-bit result and takes spi_rx[15:0]. When the
// sampling instant sits near the bit boundary the alignment is marginal and the
// captured word loses a bit -> exactly HALF. The corrupted samples are the low
// ones. (The first reading of this went the other way, and the resulting
// calibration was wrong by 2x until the fix below settled which population was
// real -- see DATA/README.md.)
//
// Waiting ~1 us after the DRDY edge moves the sampling instant off the boundary.
// The conversion period is 1572 us (logic analyser, sd 0.4 us), so the cost is
// 0.06% of throughput.
//
// VERIFIED on hardware, 1 Mohm soldered from the excitation pad to AIN5, 30 s,
// discarding the first 91 rows (logger start-up transient):
//   before   1502 (72.5%) + 3004 (27.5%)
//   after    3002-3003, sd 1.09 counts, ONE shifted sample in 2741 (0.036%)
// 3002 counts -> 991.5 kohm through R = 100k*(32767/counts - 1). 0.85% error,
// and the run-to-run spread is 0.40 kohm (0.040%). The three unconnected
// channels stay at sd 0.6-0.8 counts, unchanged by this edit.
//
// Regression test: that same 1 Mohm must give a single population at ~3002 with
// nothing near 1502.
localparam [20:0] RD_DELAY = 21'd27;      // ~1 us @ 27 MHz

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
        ch_idx     <= 2'h0;
        init_done  <= 1'b0;
        err_flag   <= 1'b0;
        ads_start  <= 1'b0;
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
            if (drdy_assert) begin wait_cnt <= 21'd0; state <= S_RDLY; end
        end
        // ── let the ADS finish driving MISO before the first clock (see RD_DELAY)
        S_RDLY: begin
            if (wait_cnt == RD_DELAY) begin wait_cnt <= 21'd0; state <= S_RDATA_I; end
            else wait_cnt <= wait_cnt + 21'd1;
        end
        // ── DIRECT read: single-shot leaves DRDY# LOW, so the ADS already drives
        //    the conversion data onto MISO. Read it by clocking 16(+1) bits with NO
        //    RDATA command (0x12 would collide with that auto-output -> byte shift).
        S_RDATA_I: begin
            load_data <= 24'h0; total_bits <= 6'd17;       // 16 data + 1 (engine BUG2)
            spi_start <= 1'b1; ret_state <= S_RDATA_C; state <= S_WAIT;
        end
        // ── capture: 16-bit result in spi_rx[15:0]; advance channel, loop ──────
        S_RDATA_C: begin
            data_out   <= spi_rx[15:0];
            ch_out     <= ch_idx;
            data_valid <= 1'b1;
            ch_idx     <= ch_idx + 2'd1;
            state      <= S_MUX_I;
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
