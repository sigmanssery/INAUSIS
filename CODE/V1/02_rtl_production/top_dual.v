`timescale 1ns/1ps
//============================================================================
// top_dual.v — combined ADS114S08 (4-corner pressure) + LDC1101 (RP/L) readout.
//
// Every ~10 ms it bursts six UART lines @921600 8N1 (each "LBL: xxxx\r\n"):
//   CH0: xxxx  CH1: xxxx  CH2: xxxx  CH3: xxxx   (ADS corners; good-map single-
//                                                 shot direct-read driver)
//   RP : xxxx  L  : xxxx                          (LDC1101; TC1/TC2-calibrated)
// tactile_map.py reads CH0..3 for the touch map, and RP/L for the side curves.
//
// Reuses ads114s08_spi.v + ldc1101_spi.v as-is (separate SPI buses, no conflict).
// LDC needs CLKIN (pin 42) for the L measurement — free here (no Manchester).
//============================================================================
module top_dual (
    input  wire clk27,        // pin 52
    input  wire rst_n,        // pin 4
    output wire led_init,     // pin 10 (active-low: ON once both cores init)
    output wire led_acq,      // pin 11 (blinks as lines are sent)
    output wire led_err,      // pin 13 (ON if either core flags an ID error)
    // ADS114S08 SPI (Bus A)
    output wire ads_cs_n,     // 25
    output wire ads_sclk,     // 26
    output wire ads_din,      // 27
    input  wire ads_dout,     // 28
    input  wire ads_drdy_n,   // 29
    output wire ads_start,    // 30
    // LDC1101 SPI (Bus B)
    output wire ldc_cs_n,     // 33
    output wire ldc_sclk,     // 34
    output wire ldc_sdi,      // 35
    input  wire ldc_sdo,      // 40
    output wire ldc_clkin,    // 42
    output wire uart_tx,      // 17
    // Pseudo-ground pins (I/O driven LOW) — extra local ground return for each
    // peripheral to fight ground bounce when ADS+LDC switch together. NOT a
    // substitute for a real GND pin; keep the real board GND connected too.
    output wire gnd_ads,      // 39 (LEFT header, by ADS block; tie to ADS GND)
    output wire gnd_ldc,      // 41 (LEFT header, in LDC block; tie to LDC GND)

    // ── V4 board only: the three spare header positions ─────────────────────
    // Each is "safe by default, FPGA overrides": the board carries a pull so the
    // hardware behaves correctly during FPGA configuration, when every I/O here
    // is still high-Z.
    output wire ads_reset_n,  // board: 10k pull-up to IOVDD  (active LOW)
    output wire ldo_en,       // board: 100k pull-up to VIN   (HIGH = rail on)
    output wire ads_clk       // board: pull-down to DGND      (see EXT_CLK)
);
    // ─── time-multiplex: only ONE peripheral active at a time ────────────────
    // Running ADS+LDC together collapses the shared 3.3V (board whines, both
    // read garbage) even though each works perfectly ALONE. So give each a turn
    // and hold the OTHER in reset (kills its SPI *and* CLKIN) — at any instant
    // only one core switches, reproducing the proven solo condition. The
    // ch/rp/l latches below live in top_dual (global rst_n) so they persist
    // across slices; the UART keeps printing the last good values continuously.
    // TIME_MUX=1: alternate ~150ms turns (single-board mode — shared 3.3V can't
    // feed both at once). TIME_MUX=0: both cores run SIMULTANEOUSLY at full rate
    // (two-board split mode — each board has its own power wiring; worth it for
    // the full sample rate the TTCGS chain needs).
    localparam TIME_MUX = 1'b1;
    reg        slice;            // 0 = ADS turn, 1 = LDC turn
    reg [22:0] slice_cnt;
    localparam [22:0] SLICE_CYC = 23'd4_050_000;   // ~150 ms @27 MHz per turn
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n)                     begin slice<=1'b0; slice_cnt<=23'd0; end
        else if (slice_cnt==SLICE_CYC)  begin slice_cnt<=23'd0; slice<=~slice; end
        else                            slice_cnt <= slice_cnt + 23'd1;
    end
    wire rst_ads = rst_n & (TIME_MUX ? ~slice : 1'b1);
    wire rst_ldc = rst_n & (TIME_MUX ?  slice : 1'b1);

    // ─── ADS core ───────────────────────────────────────────────────────────
    wire        ads_dv, ads_init, ads_errf;
    wire [15:0] ads_data;
    wire [1:0]  ads_ch;
    ads114s08_spi u_ads (
        .clk(clk27), .rst_n(rst_ads),
        .ads_cs_n(ads_cs_n), .ads_sclk(ads_sclk), .ads_din(ads_din),
        .ads_dout(ads_dout), .ads_drdy_n(ads_drdy_n), .ads_start(ads_start),
        .data_valid(ads_dv), .data_out(ads_data), .ch_out(ads_ch),
        .init_done(ads_init), .err_flag(ads_errf)
    );

    // ─── LDC core ───────────────────────────────────────────────────────────
    wire        ldc_dv, ldc_init, ldc_errf;
    wire [15:0] rp_data, l_data;
    wire [7:0]  ldc_status;
    wire [7:0]  ldc_chip_id;   // 0xD4 = LDC answering on SPI; 0xFF = link dead
    ldc1101_spi u_ldc (
        .clk(clk27), .rst_n(rst_ldc),
        .ldc_cs_n(ldc_cs_n), .ldc_sclk(ldc_sclk), .ldc_sdi(ldc_sdi),
        .ldc_sdo(ldc_sdo), .ldc_clkin(ldc_clkin),
        .data_valid(ldc_dv), .rp_data(rp_data), .l_data(l_data),
        .init_done(ldc_init), .err_flag(ldc_errf), .status(ldc_status),
        .chip_id(ldc_chip_id)
    );
    // Sticky NO_SENSOR_OSC: the stall that corrupts an L sample can be shorter
    // than one UART slot, so a live snapshot of bit7 would usually read clean.
    // Latch any set seen since the previous ST line was sent, and clear on send —
    // the emitted byte then means "did the tank stall during this interval".
    reg [7:0] st_sticky;
    reg       st_clr;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n)      st_sticky <= 8'd0;
        else if (st_clr) st_sticky <= ldc_status;          // restart the window
        else             st_sticky <= st_sticky | ldc_status;
    end

    // ─── RP median-of-3 ─────────────────────────────────────────────────────
    // With DIG_CONF=0x07 the RP channel throws a ONE-SAMPLE dip (~41720 ->
    // ~35090) on an exact 0.300 s cadence; L is untouched. Measured 2026-07-03:
    // those 8 dips alone take RP's sd from 136 to 446. A 3-tap median is immune
    // to single-sample outliers and (unlike an average) does not lag real
    // changes -> sd 127, i.e. cleaner than DIG_CONF=0x06 (185) while keeping
    // 0x07's doubled L resolution.
    reg [15:0] rp_p1, rp_p2;                  // previous two valid RP samples
    wire [15:0] m_hi   = (rp_data > rp_p1) ? rp_data : rp_p1;
    wire [15:0] m_lo   = (rp_data > rp_p1) ? rp_p1   : rp_data;
    wire [15:0] m_b    = (m_hi > rp_p2)    ? rp_p2   : m_hi;
    wire [15:0] rp_med = (m_lo > m_b)      ? m_lo    : m_b;   // max(lo, min(hi,c))

    // ─── L median-of-3 ──────────────────────────────────────────────────────
    // L throws single-sample spikes too (2026-07-31: L=1411 for exactly one
    // sample with 1364/1365 either side). Feeding that to the TTCGS chain made
    // DoG_fast raise events on nothing — 4 events, of which 2 were this one
    // glitch. A 3-tap median removes it completely and costs a real multi-sample
    // poke only ~2 of its 15 counts, so the two genuine events survive.
    reg [15:0] l_p1, l_p2;
    wire [15:0] n_hi  = (l_data > l_p1) ? l_data : l_p1;
    wire [15:0] n_lo  = (l_data > l_p1) ? l_p1   : l_data;
    wire [15:0] n_b   = (n_hi > l_p2)   ? l_p2   : n_hi;
    wire [15:0] l_med = (n_lo > n_b)    ? n_lo   : n_b;

    // ─── latch latest values from each core ─────────────────────────────────
    reg [15:0] ch0, ch1, ch2, ch3, rpv, lv;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            ch0<=0; ch1<=0; ch2<=0; ch3<=0; rpv<=0; lv<=0;
            rp_p1<=0; rp_p2<=0; l_p1<=0; l_p2<=0;
        end else begin
            if (ads_dv) case (ads_ch)
                2'd0: ch0<=ads_data; 2'd1: ch1<=ads_data;
                2'd2: ch2<=ads_data; default: ch3<=ads_data;
            endcase
            if (ldc_dv) begin
                if (|rp_data) begin             // reject 0000 config/settle transient
                    rpv   <= FAST_LDC ? rp_data : rp_med;
                    rp_p1 <= rp_data;
                    rp_p2 <= rp_p1;
                end
                if (|l_data) begin
                    lv   <= FAST_LDC ? l_data : l_med;
                    l_p1 <= l_data;
                    l_p2 <= l_p1;
                end
            end
        end
    end

    // ─── byte UART + hex helper ─────────────────────────────────────────────
    reg        u_send; reg [7:0] u_data; wire u_ready;
    uart_byte_tx #(.CLK_HZ(27_000_000), .BAUD(921600)) u_uart (
        .clk(clk27), .rst_n(rst_n), .send(u_send), .data(u_data),
        .ready(u_ready), .tx(uart_tx));
    function [7:0] hexc; input [3:0] n;
        begin hexc = (n < 4'd10) ? (8'h30 + n) : (8'h41 + n - 4'd10); end
    endfunction

    // ─── line sender (pbuf -> UART, proven pattern) ─────────────────────────
    reg [7:0] pbuf [0:10];       // "LBL: xxxx\r\n" = 11 chars
    reg [3:0] pidx;
    reg       print_start, print_busy;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin pidx<=4'd0; print_busy<=1'b0; u_send<=1'b0; u_data<=8'd0; end
        else begin
            u_send <= 1'b0;
            if (print_start && !print_busy) begin print_busy<=1'b1; pidx<=4'd0; end
            else if (print_busy) begin
                if (u_ready && !u_send) begin
                    u_data <= pbuf[pidx]; u_send <= 1'b1;
                    if (pidx==4'd10) print_busy<=1'b0; else pidx<=pidx+4'd1;
                end
            end
        end
    end

    // ─── slot sequencer: build + fire one UART line per slot ────────────────
    // Rate is set by STREAM_MODE below. Why it matters: at the 10 ms burst the
    // channels are sampled at ~93 SPS — Nyquist 46 Hz — so an elastomer ringdown
    // in the 10-100 Hz band aliases into nonsense, and a 1-5 ms impact lands on
    // at most one sample, which the median-of-3 then deletes as a spike. 1 kHz is
    // also the rate TTCGS's sigmas are defined at, so it is what the paper's
    // touch/release figures and its 2 ms reflex band require.
    //
    // FAST_LDC now controls only the median filters, not the rate. Bypass them
    // for transient work — they exist to kill single-sample spikes, which is
    // exactly what a real impact looks like. Keep them for anything slow, where
    // a lone corrupt read is noise rather than signal.
    localparam FAST_LDC = 1'b0;

    // ── UART stream mode ────────────────────────────────────────────────────
    // The board only ever has one modality wired at a time, so streaming both
    // costs bandwidth for lines that carry nothing. It also caps the rate: all
    // eight lines are 88 bytes = 880 bits, which at 921600 baud is 0.955 ms —
    // 95% of a 1 ms period, and that saturation is what produced ~12% corrupt
    // reads the last time a 1 kHz period was tried. One modality is 4 lines =
    // 0.48 ms, so 1 kSPS fits with the line half idle.
    //
    //   0 = both, 10 ms  (~100 Hz)   slots 0-7  — bring-up / dual capture
    //   1 = ADS only, 1 ms (1 kHz)   slots 0-3  — the rate the DoG pipeline is
    //                                             specified at; needed for the
    //                                             touch/release figures
    //   2 = LDC only, 1 ms (1 kHz)   slots 4-7  — RP/L/ST/ID at the LDC's own
    //                                             loop rate, for transients
    localparam [1:0] STREAM_MODE = 2'd0;

    reg [2:0]  slot; reg [15:0] val; reg [22:0] dcnt; reg acq;
    localparam [22:0] PERIOD = (STREAM_MODE == 2'd0) ? 23'd270000   // ~10 ms
                                                     : 23'd27000;   // ~1 ms
    localparam [2:0]  SLOT_FIRST = (STREAM_MODE == 2'd2) ? 3'd4 : 3'd0;
    localparam [2:0]  SLOT_LAST  = (STREAM_MODE == 2'd1) ? 3'd3 : 3'd7;
    localparam [2:0] S_WAIT=3'd0, S_BUILD=3'd1, S_HEX=3'd2, S_FIRE=3'd3,
                     S_BUSY=3'd4, S_NEXT=3'd5;
    reg [2:0] sstate;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            sstate<=S_WAIT; slot<=SLOT_FIRST; dcnt<=23'd0; print_start<=1'b0; acq<=1'b0; val<=16'd0;
            st_clr<=1'b0;
        end else begin
            print_start <= 1'b0;
            st_clr      <= 1'b0;
            case (sstate)
            S_WAIT: if (dcnt==PERIOD) begin dcnt<=23'd0; slot<=SLOT_FIRST; sstate<=S_BUILD; end
                    else dcnt<=dcnt+23'd1;
            S_BUILD: begin
                case (slot)
                3'd0: begin pbuf[0]<="C";pbuf[1]<="H";pbuf[2]<="0";pbuf[3]<=":"; val<=ch0; end
                3'd1: begin pbuf[0]<="C";pbuf[1]<="H";pbuf[2]<="1";pbuf[3]<=":"; val<=ch1; end
                3'd2: begin pbuf[0]<="C";pbuf[1]<="H";pbuf[2]<="2";pbuf[3]<=":"; val<=ch2; end
                3'd3: begin pbuf[0]<="C";pbuf[1]<="H";pbuf[2]<="3";pbuf[3]<=":"; val<=ch3; end
                3'd4: begin pbuf[0]<="R";pbuf[1]<="P";pbuf[2]<=" ";pbuf[3]<=":"; val<=rpv; end
                3'd5: begin pbuf[0]<="L";pbuf[1]<=" ";pbuf[2]<=" ";pbuf[3]<=":"; val<=lv;  end
                // STATUS(0x20), sticky since the previous ST line. Printed as
                // "ST : 00xx" so the existing 4-hex-digit line format is unchanged.
                3'd6: begin pbuf[0]<="S";pbuf[1]<="T";pbuf[2]<=" ";pbuf[3]<=":";
                            val<={8'd0, st_sticky}; st_clr<=1'b1; end
                // CHIP_ID(0x3F), re-read every LDC loop. D4 = alive on SPI.
                default:begin pbuf[0]<="I";pbuf[1]<="D";pbuf[2]<=" ";pbuf[3]<=":";
                              val<={8'd0, ldc_chip_id}; end
                endcase
                pbuf[4]<=" "; pbuf[9]<=8'h0D; pbuf[10]<=8'h0A;
                sstate<=S_HEX;
            end
            S_HEX: begin
                pbuf[5]<=hexc(val[15:12]); pbuf[6]<=hexc(val[11:8]);
                pbuf[7]<=hexc(val[7:4]);   pbuf[8]<=hexc(val[3:0]);
                sstate<=S_FIRE;
            end
            S_FIRE: begin print_start<=1'b1; sstate<=S_BUSY; end
            S_BUSY: if (!print_busy && !print_start) sstate<=S_NEXT;
            S_NEXT: if (slot==SLOT_LAST) begin acq<=~acq; sstate<=S_WAIT; end
                    else begin slot<=slot+3'd1; sstate<=S_BUILD; end
            endcase
        end
    end

    assign led_init = ~(ads_init & ldc_init);
    assign led_acq  = ~acq;
    assign led_err  = ~(ads_errf | ldc_errf);

    assign gnd_ads  = 1'b0;   // driven-low pseudo-ground (see port comment)
    assign gnd_ldc  = 1'b0;

    //=========================================================================
    // V4 spare pins: peripheral power/reset/clock
    //=========================================================================
    // periph_en gates the analog rail. Deasserting it must ALSO stop driving the
    // peripheral pins: with the LDO off, any 3.3 V still coming out of the FPGA
    // flows through the ADS/LDC ESD diodes into their dead VDD rail
    // (back-powering — it part-powers the chip into an undefined state and can
    // damage it). Tying the two together in one place makes that impossible.
    // V4_PINS=0 while running on the X004 board, where these three pins go
    // nowhere: everything is held static so the bitstream behaves exactly as it
    // did before this port was added (in particular ads_clk does not toggle on an
    // unconnected pin). Set to 1 once the V4 board routes them.
    localparam V4_PINS   = 1'b0;
    localparam PERIPH_EN = 1'b1;      // hold the rail on; wire to control later
    assign ldo_en      = PERIPH_EN;
    assign ads_reset_n = PERIPH_EN;   // released with the rail; pull-up holds it
                                      // deasserted while the FPGA configures
    // ADS system clock = 27 MHz / 8 = 3.375 MHz. Spec: fCLK 2-4.5 MHz, duty
    // 40/50/60%. /8 toggles every 4 cycles for an exact 50% duty, dead centre of
    // the window; /7 would give 3.857 MHz (closer to the 4.096 MHz nominal) but
    // an odd divide can only make 42.9%/57.1%, right at the edges — not worth it
    // when the point of an external clock is precision. Data rates scale by
    // 3.375/4.096 = 0.824 (800 SPS -> 660 SPS), exactly known instead of the
    // internal oscillator's +-2%. 13.5 MHz (LDC CLKIN) is exactly 4x this, so the
    // two peripherals stay harmonically related and cannot beat against each other.
    // Only meaningful when ads114s08_spi's EXT_CLK is set AND the board routes
    // this pin; with EXT_CLK=0 the ADS ignores it and uses its internal oscillator.
    reg [1:0] aclk_cnt;
    reg       aclk_q;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            aclk_cnt <= 2'd0; aclk_q <= 1'b0;
        end else if (aclk_cnt == 2'd3) begin      // 4 cycles high, 4 low -> /8
            aclk_cnt <= 2'd0; aclk_q <= ~aclk_q;
        end else begin
            aclk_cnt <= aclk_cnt + 2'd1;
        end
    end
    assign ads_clk = V4_PINS ? aclk_q : 1'b0;
endmodule

//============================================================================
// uart_byte_tx : minimal 8N1 byte transmitter (unique name to avoid clashing
// with the ADS/LDC bring-up UARTs).
//============================================================================
module uart_byte_tx #(
    parameter integer CLK_HZ = 27_000_000,
    parameter integer BAUD   = 921600
)(
    input  wire clk, rst_n, send,
    input  wire [7:0] data,
    output reg  ready, tx
);
    localparam integer DIV = CLK_HZ / BAUD;
    reg [15:0] cnt; reg [3:0] bit_idx; reg [9:0] sh; reg busy;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin tx<=1'b1; ready<=1'b1; busy<=1'b0; cnt<=16'd0; bit_idx<=4'd0; sh<=10'h3FF; end
        else begin
            if (!busy) begin
                tx<=1'b1; ready<=1'b1;
                if (send) begin sh<={1'b1,data,1'b0}; busy<=1'b1; ready<=1'b0; cnt<=16'd0; bit_idx<=4'd0; end
            end else begin
                if (cnt==DIV-1) begin
                    cnt<=16'd0; tx<=sh[0]; sh<={1'b1,sh[9:1]}; bit_idx<=bit_idx+4'd1;
                    if (bit_idx==4'd9) begin busy<=1'b0; ready<=1'b1; end
                end else cnt<=cnt+16'd1;
            end
        end
    end
endmodule
