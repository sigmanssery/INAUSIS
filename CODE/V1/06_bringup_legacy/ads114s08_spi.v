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
// SCLK period is CLK_DIV system clocks (counter wraps at CLK_DIV, falling
// strobe at CLK_DIV/2) -- NOT 2*CLK_DIV. This comment said 964 kHz by
// dividing by 28; corrected 2026-08-07 against a logic-analyser capture.
localparam CLK_DIV = 14;            // 27 MHz / 14 = ~1.93 MHz
reg [4:0]  clk_cnt;
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
wire drdy_fall = drdy_r0 & ~drdy_r1;
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
// Sequence: RESET -> WREG REF (internal 2.5V) -> WREG INPMUX(ch0) ->
//           WREG DATARATE(800 SPS) -> START -> { wait DRDY -> RDATA ->
//           capture -> WREG INPMUX(next ch) } loop.
//
// Bit counts (BUG 2): single-byte cmds=8; 3-byte WREG=25; RDATA(8+16)=25,
// data in spi_rx[15:0].
localparam [4:0]
    S_POR      = 5'd0,
    S_RST_I    = 5'd1,
    S_RST_GAP  = 5'd2,
    S_REF_I    = 5'd3,
    S_MUX_I    = 5'd4,
    S_DR_I     = 5'd5,
    S_START_I  = 5'd6,
    S_IDLE     = 5'd7,
    S_RDATA_I  = 5'd8,
    S_RDATA_C  = 5'd9,
    S_MUX2_I   = 5'd10,
    S_WAIT     = 5'd11,
    S_SKIP     = 5'd12;   // discard 1 conversion after a MUX change (FILTER=1 => 1-cycle settle)

reg [4:0]  state, ret_state;
reg [20:0] wait_cnt;          // up to ~78 ms
reg [1:0]  ch_idx;

localparam [20:0] POR_CYC = 21'd135000;   // ~5 ms power-on
localparam [20:0] GAP_CYC = 21'd270000;   // ~10 ms after RESET

// REF: REFSEL=10 (internal 2.5V), REFCON=10 (always on). VERIFY/TUNE for tank/sensor.
localparam [7:0] VAL_REF = 8'h0A;
localparam [7:0] VAL_DR  = 8'h1A;         // FILTER=1, DR=800 SPS (validated write value)

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
            spi_start <= 1'b1; ret_state <= S_MUX_I; state <= S_WAIT;
        end
        // ── WREG INPMUX (0x02) = channel 0. {0x42,0x00,mux}, 25 bits ───────
        S_MUX_I: begin
            load_data <= {8'h42, 8'h00, mux_table[ch_idx]}; total_bits <= 6'd25;
            spi_start <= 1'b1; ret_state <= S_DR_I; state <= S_WAIT;
        end
        // ── WREG DATARATE (0x04). {0x44,0x00,VAL_DR}, 25 bits ──────────────
        S_DR_I: begin
            load_data <= {8'h44, 8'h00, VAL_DR}; total_bits <= 6'd25;
            spi_start <= 1'b1; ret_state <= S_START_I; state <= S_WAIT;
        end
        // ── START (0x08, single byte) + assert START pin ───────────────────
        S_START_I: begin
            load_data <= {8'h08, 16'h0}; total_bits <= 6'd8;
            spi_start <= 1'b1; ads_start <= 1'b1; init_done <= 1'b1;
            ret_state <= S_SKIP; state <= S_WAIT;
        end
        // ── discard the in-flight/settling conversion after a MUX change ───
        S_SKIP: begin
            if (drdy_fall) state <= S_IDLE;
        end
        // ── wait for the next (settled, correct-channel) conversion ────────
        S_IDLE: begin
            if (drdy_fall) state <= S_RDATA_I;
        end
        // ── RDATA (0x12) + read 16-bit data. 8+16+1 = 25 bits ──────────────
        S_RDATA_I: begin
            load_data <= {8'h12, 16'h0}; total_bits <= 6'd25;
            spi_start <= 1'b1; ret_state <= S_RDATA_C; state <= S_WAIT;
        end
        // ── capture: 16-bit result in spi_rx[15:0]; advance channel ────────
        S_RDATA_C: begin
            data_out   <= spi_rx[15:0];
            ch_out     <= ch_idx;          // NOTE: continuous-mode MUX change has
            data_valid <= 1'b1;            // a 1-conversion lag; label may trail
            ch_idx     <= ch_idx + 2'd1;   // by one — fine for bring-up.
            state      <= S_MUX2_I;
        end
        // ── WREG INPMUX to the next channel, then wait for its conversion ──
        S_MUX2_I: begin
            load_data <= {8'h42, 8'h00, mux_table[ch_idx]}; total_bits <= 6'd25;
            spi_start <= 1'b1; ret_state <= S_SKIP; state <= S_WAIT;
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
