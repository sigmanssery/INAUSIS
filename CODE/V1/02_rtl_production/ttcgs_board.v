`timescale 1ns/1ps
//=============================================================================
// ttcgs_board.v  — real board-level top for Tang Nano 9K (GW1NR-9C)
//
//   ADS114S08 SPI (4 piezoresistive ch) ─┐
//                                         ├─ 1 kHz sample sequencer ─► ttcgs_sys
//   LDC1101 SPI (2 inductive ch: L, RP) ──┘        (DoG + flag + frame + halfduplex)
//                                                          └─► Manchester `line` ► SoC
//
// Pin map: see inausis.cst (schematic-verified Tang Nano 9K assignments).
//
// STATUS / what is verified:
//   - ADS114S08 SPI master (ads114s08_spi): 4 channels AIN5/4/1/0 -> ch 0..3.
//   - LDC1101 SPI master (ldc1101_spi): RP+L mode -> ch 4 (L), ch 5 (RP).
//   - The sample sequencer reads the latest ADS + LDC values once per 1 ms period
//     and streams the 6 channels into the core, spaced so each channel's DoG MAC
//     sweep (~770 cyc) finishes before the next.
//   This top PLACES, ROUTES, MEETS 27 MHz TIMING and GENERATES A BITSTREAM. The
//   SPI *functional* path (esp. the LDC register config for the actual LC tank)
//   must still be validated on hardware.
//=============================================================================
module ttcgs_board (
    input  wire clk27,        // pin 52, 27 MHz oscillator
    input  wire rst_n,        // pin 4, S2 button (active-low)

    // status LEDs (active-low, 1.8 V bank)
    // Physical order left-to-right: 16 15 14 13 11 10 (measured 2026-09-05).
    output wire led_init,     // pin 10  configured
    output wire led_uncal,    // pin 11  calibration not yet converged
    output wire led_err,      // pin 13  fault
    output wire led_d2,       // pin 14  sustained band
    output wire led_d1,       // pin 15  slow band
    output wire led_d0,       // pin 16  fast band

    // AD5254 floor rig: one I2C bus per chip, plus a write protect per chip.
    //
    // These take pin 32 from the demo servo, which is removed -- not only for
    // the pin.  The SG90's signal lead alone moved the resting baseline from
    // 1600 to 3400 counts through the FPGA's ESD diodes (measured 2026-09-05),
    // and this rig exists to measure a noise floor.  To restore the servo, put
    // `output wire servo_pwm` back, restore the block below the LEDs, and give
    // it a pin outside 31/32/48/49/74/75.
    //
    // WP is driven rather than strapped because the wires are already on 74/75.
    // It must be HIGH to allow writes: the AD5254 pulls WP low with an internal
    // current source, so a floating pin is write-protected, and in that state
    // every transaction still ACKs while the wiper never moves.
    inout  wire scl_a,        // 31
    inout  wire sda_a,        // 32
    inout  wire scl_b,        // 48
    inout  wire sda_b,        // 49
    output wire wp_a,         // 74
    output wire wp_b,         // 75

    // ADS114S08 SPI (piezoresistive P1-P4)
    output wire ads_cs_n,     // 25
    output wire ads_sclk,     // 26
    output wire ads_din,      // 27
    input  wire ads_dout,     // 28
    input  wire ads_drdy_n,   // 29
    output wire ads_start,    // 30

    // LDC1101 SPI (inductive L, RP) — held idle (stub) for now
    output wire ldc_cs_n,     // 33
    output wire ldc_sclk,     // 34
    output wire ldc_sdi,      // 35
    input  wire ldc_sdo,      // 40
    output wire ldc_clkin,    // 41 -> LDC CLKIN header (L reference clock; ≠ line@42)

    // single-wire half-duplex Manchester link to the SoC
    inout  wire line,         // 42 (generic GPIO, board pull-up)

    // bring-up only: 8N1 mirror of the packed frame (see frame_uart_mirror.v)
    output wire uart_tx       // 17
);
    //------------------------------------------------ LDC1101 SPI (inductive L, RP)
    wire        ldc_dv, ldc_init_done, ldc_err;
    wire [15:0] ldc_rp, ldc_l;
    wire [7:0]  ldc_chip_id;
    ldc1101_spi u_ldc (
        .clk(clk27), .rst_n(rst_n),
        .ldc_cs_n(ldc_cs_n), .ldc_sclk(ldc_sclk), .ldc_sdi(ldc_sdi), .ldc_sdo(ldc_sdo),
        .ldc_clkin(ldc_clkin),
        .data_valid(ldc_dv), .rp_data(ldc_rp), .l_data(ldc_l),
        .init_done(ldc_init_done), .err_flag(ldc_err),
        .chip_id(ldc_chip_id)
    );

    // ---- inductive-path liveness, reported in-band -------------------------
    // WHY THIS EXISTS.  Before this, the only report of inductive health was two
    // LEDs.  A frame whose inductive dimensions carry a dead converter is still a
    // well-formed frame: CRC correct, timestamp advancing, rate nominal.  Nothing
    // downstream could tell it from a live one, so a modality could die silently
    // and be believed.  That is worse than no signal, because a consumer acts on
    // it with confidence.  On a single board a human watches the LED; across a
    // cluster nobody does.
    //
    // TWO CONDITIONS, BOTH NEEDED.  The driver re-reads CHIP_ID(0x3F) on every
    // sample loop and 0xD4 is the LDC, so a wrong ID catches the 2026-07-31
    // latch-up signature (every register reading 0xFF while the SPI still
    // clocks).  But CHIP_ID is a REGISTER: if the driver stalls, it holds its
    // last value and a stale 0xD4 would read as alive.  The staleness timer
    // covers that case -- no data_valid within STALE_CLKS and the channel is
    // reported not-alive regardless of what the register says.  Neither test
    // alone is sufficient: one catches a lying chip, the other a stopped driver.
    localparam [23:0] STALE_CLKS = 24'd2_700_000;   // 100 ms at 27 MHz, ~69 frames
    reg [23:0] ldc_stale_cnt;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n)                          ldc_stale_cnt <= 24'd0;
        else if (ldc_dv)                     ldc_stale_cnt <= 24'd0;
        else if (ldc_stale_cnt != STALE_CLKS) ldc_stale_cnt <= ldc_stale_cnt + 24'd1;
    end
    wire ldc_fresh = (ldc_stale_cnt != STALE_CLKS);
    wire ldc_alive = ldc_fresh && (ldc_chip_id == 8'hD4);
    reg signed [15:0] ldc_l_buf, ldc_rp_buf;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin ldc_l_buf<=16'sd0; ldc_rp_buf<=16'sd0; end
        else if (ldc_dv) begin ldc_l_buf<=ldc_l; ldc_rp_buf<=ldc_rp; end
    end

    //------------------------------------------------------------- ADS114S08 SPI
    wire        ads_dv;
    wire [15:0] ads_data;
    wire [1:0]  ads_ch;
    wire        ads_init_done, ads_err;
    wire [15:0] ads_dbg;

    // SINGLE_CH=1 converts only AIN5 (SINGLE_IDX=0, the FSR on ch0) instead of
    // cycling all four: 159 SPS -> 584 SPS, so the information Nyquist moves from
    // 79.5 Hz to 292 Hz.  Under round-robin the core was fed each ch0 sample four
    // times over, and NOTHING above 79.5 Hz could reach the host no matter what
    // the filters did -- dim 12's raw stream held for 4-5 frames at a time.
    // Cost: ch1..ch3 (dims 3..11) stop updating.  They have no sensor.
    //
    // DIGIPOT BRING-UP (2026-09-11, BUILD_ID 0x0936): MUX_FORCE = 8'h1C selects
    // AIN1 (corner D), where the AD5254 floor rig is wired, instead of AIN5
    // (corner B, the FSR).  MUX_FORCE is used rather than SINGLE_IDX=2 on
    // purpose: SINGLE_IDX also drives ch_idx -> ch_out, so the sample would land
    // in ads_buf[2] and every dim would move.  Forcing only the INPMUX value
    // keeps ch_out = 0, so the whole downstream mapping (dims 0-2, raw on 3/12)
    // is unchanged and the host tools need no edit.
    //   REVERT TO 8'h00 to go back to the FSR on corner B.
    // Note the MUX_FORCE comment in ads114s08_spi.v warns that d12/d0-d2 are
    // meaningless -- that applies to the 8'hCC (AINCOM/AINCOM) diagnostic, not
    // to selecting a real input as here.
    ads114s08_spi #(.SINGLE_CH(1), .SINGLE_IDX(2'd0), .CONT_MODE(1),
                    .MUX_FORCE(8'h1C)) u_ads (
        .clk(clk27), .rst_n(rst_n),
        .ads_cs_n(ads_cs_n), .ads_sclk(ads_sclk), .ads_din(ads_din),
        .ads_dout(ads_dout), .ads_drdy_n(ads_drdy_n), .ads_start(ads_start),
        .data_valid(ads_dv), .data_out(ads_data), .ch_out(ads_ch),
        .init_done(ads_init_done), .err_flag(ads_err),
        .dbg_state(ads_dbg)
    );

    // Status bits 7:4, previously hard-zero. Bit 4 is the one to read first: it is
    // the only bit that goes low when a running inductive path stops being real.
    // Bits 7:5 report driver-level state that was also LED-only until now; the
    // resistive path's per-dimension health (dead, uncal) already had bits 3:0.
    //--------------------------------------------------------- AD5254 floor rig
    // Declared here rather than beside the instance because health_w below uses
    // these, and Verilog wants the net before its first use.
    //
    // DIGIPOT=1 drives the super-pot that replaces the FSR, so a calibrated
    // sub-count step goes through the real analog chain.  It is the measurement
    // `synth_press` could not make: that one bypasses the converter, so its floor
    // was set by the generator's 1 count/sample minimum rather than by the chain
    // (see the 2026-08-30 retraction).
    //
    // MAN parks the wiper at MAN_CODE instead of running the ramp, which is what
    // `digipot_trim.ps1` needs while the bias trimmer is turned by hand.  Set it
    // back to 0 before recording anything: with MAN=1 the rig never sweeps.
    localparam        DIGIPOT      = 1'b1;
    localparam        DIGIPOT_MAN  = 1'b0;     // 1 = trim mode, 0 = run the ramp
    localparam [10:0] DIGIPOT_CODE = 11'd1746; // rest point, = raw 1612

    wire signed [15:0] pot_aux;
    wire               pot_done, pot_lag, pot_ack, pot_ack_a, pot_ack_b;

    //   bit 7 ads_err        1 = ADS driver gave up: only zeros, re-init bounded out
    //   bit 6 ads_init_done  1 = ADS configured (asserts with NO ADS attached --
    //                            measured 2026-09-03 -- so it is NOT a liveness bit)
    //   bit 5 ldc_err        1 = LDC CHIP_ID read back something other than 0xD4
    //   bit 4 ldc_alive      1 = CHIP_ID reads 0xD4 AND data seen within 100 ms
    //
    // Bit 5 carried ldc_init_done until 2026-09-03. That signal never settles when
    // no inductive board is attached (the driver re-enters init on every failed ID
    // read), so it reported "configured" or nothing at all rather than anything
    // about the link. ldc_err is the useful half of the same information: with bit
    // 4 it separates a driver that has stopped (alive low, err low -- staleness
    // fired) from a chip answering wrongly (alive low, err high). That distinction
    // is what the 32% CHIP_ID corruption of 2026-09-03 needed and could not get.
    // TRIED AND REVERTED 2026-09-12: putting the rig's per-bus ack_err on bits
    // 5/4 (which carry nothing with HAS_LDC=0 and no inductive board) broke
    // timing -- Fmax 26.488 against the 27.000 constraint, 11 setup violations.
    // The failing paths were all inside u_flag's square-to-threshold chain, not
    // on the new one: at 92% CLS the design has ~0.2% margin (27.049 MHz) and
    // any added logic re-places that chain into a violation.  Those paths decide
    // the detection thresholds, so a build that misses there is not usable.
    // Re-try only after u_flag gets timing headroom.
    wire [3:0] health_w = {ads_err, ads_init_done, ldc_err, ldc_alive};

    // latch newest sample per piezoresistive channel
    reg signed [15:0] ads_buf [0:3];
    integer bi;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) for (bi=0;bi<4;bi=bi+1) ads_buf[bi] <= 16'sd0;
        else if (ads_dv) ads_buf[ads_ch] <= ads_data;
    end

    //------------------------------------------------- 1 kHz sample sequencer
    // 27 MHz / 39187 = 689.0 Hz. The kernels are defined in samples, so the
    // sample rate sets where their passbands land; 689 is the rate every band
    // figure in the paper is computed at (DoG_fast peaking at 33 Hz). Running
    // the board at 1 kHz instead would move that to 48 Hz. It also lets the
    // bring-up UART mirror keep up: a 54-byte burst takes 580 us against a
    // 1.45 ms period, so every frame is captured rather than one in three.
    localparam PER_CLKS = 16'd39187;
    localparam CH_WAIT  = 11'd900;     // > DoG sweep (~770) per channel
    reg [15:0] per_cnt;
    reg        start_sweep;
    // Sampling must not begin before the converters can answer. The ADS needs
    // its power-on wait, reset gap and register writes (~15 ms) before its first
    // conversion; sweeping from reset instead feeds the chain the buffers' reset
    // value, and since the flag engine calibrates over its first CAL_N samples it
    // then measures a near-constant sequence, computes ~zero variance and marks
    // every dimension dead. Observed on first bring-up: dead = 0x3FFFF with the
    // DoG outputs plainly alive (sd 1200-4900 counts).
    // Do NOT gate on ldc_init_done. The LDC driver re-enters its init sequence
    // whenever the chip ID read fails, so with no LDC board attached that signal
    // never settles; requiring it here held sampling off forever. A missing
    // inductive board is a legitimate configuration -- those six dimensions are
    // then correctly reported dead -- and must not stop the resistive path. What
    // replaced it is a liveness test on the data rather than on an init flag, and
    // as of 2026-09-03 it accepts either converter; see the block below.
    // init_done alone is NOT enough to start sampling.  On a cold power-up from
    // embedded flash the converter's supply is still ramping when the driver
    // runs its register writes; they are lost, init_done asserts anyway, and the
    // device streams exact zeros.  The flag engine calibrates over its first
    // CAL_N samples and only once, so it would measure zero variance on that
    // garbage and mark all 18 dims dead (0x3FFFF) -- and would STAY that way even
    // after the driver's own zero-run watchdog redoes the init and real data
    // starts flowing.  So wait for a converter sample that is actually non-zero:
    // calibration then happens on live data.  Latched, so later dropouts do not
    // restart it.  (Cold-start failure observed 2026-08-28; JTAG loads never hit
    // it because the converter has been powered for minutes by then.)
    // EITHER CONVERTER STARTS THE CHAIN (2026-09-03).  This gate used to test the
    // ADS alone, which made the resistive board mandatory for everything: with only
    // an inductive board attached, ads_data never went non-zero, sample_en never
    // asserted, per_cnt stayed at zero and the sequencer never ran -- no frames at
    // all, on a link that looks identical to a failed flash.  That contradicted the
    // stated design property that the two channel groups are independent, and the
    // comment above shows only the mirror-image case had been considered.
    //
    // ldc_alive is the right analogue of ads_init_done here because it already
    // carries both halves of the liveness test (CHIP_ID reads 0xD4, and a sample
    // arrived within 100 ms), and the non-zero test guards the same cold-start
    // hazard on that path: a converter whose register writes were lost to a ramping
    // supply streams exact zeros, and calibrating on those would mark every
    // dimension dead.  Latched, so a later dropout on either converter does not
    // restart the warm-up.  Only the loss of BOTH converters now holds sampling off.
    localparam [19:0] WARM_CLKS = 20'd540000;   // 20 ms past first live sample
    wire ads_live_evt = ads_init_done && ads_dv && ads_data != 16'd0;
    wire ldc_live_evt = ldc_alive     && ldc_dv && ldc_rp   != 16'd0;
    reg        cvt_live;
    reg [19:0] warm;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin cvt_live <= 1'b0; warm <= 20'd0; end
        else begin
            if (ads_live_evt || ldc_live_evt) cvt_live <= 1'b1;
            if (cvt_live && warm != WARM_CLKS) warm <= warm + 20'd1;
        end
    end
    wire sample_en = (warm == WARM_CLKS);

    //------------------------------------------------- synthetic stimulus mode
    // SYNTH=1 replaces ch0's converter samples with synth_press's trapezoid
    // train.  Everything downstream -- integer MAC, >>FRAC, saturation, flag
    // engine, packer, link -- is the shipping logic, so this measures what the
    // FRONT END resolves rather than what the operator can execute twice.  It
    // exists because the 2026-08-28 corpus turned out to have hand variance
    // ~30x the front end's own resolution, which makes hand-executed gestures
    // useless for a resolution claim.  Set SYNTH=0 to record real contact.
    localparam SYNTH = 1'b0;

    // ADS_DBG=1 routes the ADS driver's state word onto dim13 instead of
    // synth_step.  Bring-up only, and it must go back to 0 afterwards: that word
    // is {drdy_fall_cnt, state}, a free-running counter whose window variance is
    // ~3.5e8 against zscore_flag_multi's VAR_CEIL of 20000.  Every calibration
    // window on that dim is rejected, so it retries forever.  The retry is
    // per-dim and costs only dim13's own events, but status bit3 is |uncal over
    // all dims, so the frame reports "uncalibrated" for as long as the tap is
    // fitted and the bit stops meaning anything.  Measured 2026-09-04: uncal
    // 100.000% of 41454 frames with the tap in, while dims 0-2 were detecting
    // normally the whole time.  Never leave a free-running counter on a
    // calibrated dim.
    localparam ADS_DBG = 1'b0;
    wire signed [15:0] synth_x;
    wire        [15:0] synth_step;
    generate if (SYNTH) begin : g_synth
        synth_press u_synth (
            .clk(clk27), .rst_n(rst_n), .tick(start_sweep),
            .sample(synth_x), .step(synth_step)
        );
    end else begin : g_nosynth
        assign synth_x    = 16'sd0;
        assign synth_step = 16'd0;
    end endgenerate

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin per_cnt<=16'd0; start_sweep<=1'b0; end
        else begin
            start_sweep <= 1'b0;
            if (!sample_en) per_cnt <= 16'd0;
            else if (per_cnt == PER_CLKS-1) begin per_cnt<=16'd0; start_sweep<=1'b1; end
            else                            per_cnt<=per_cnt+16'd1;
        end
    end

    reg        sweeping;
    reg [2:0]  sch;            // channel being presented (0..5)
    reg [10:0] wcnt;
    reg [2:0]  s_ch;
    reg signed [15:0] s_x;
    reg        s_sv, s_pe;
    reg [31:0] ts;

    function signed [15:0] chan_val(input [2:0] c);
        case (c)
            3'd0:                chan_val = SYNTH ? synth_x : ads_buf[0];
            3'd1,3'd2,3'd3:      chan_val = ads_buf[c[1:0]];   // piezoresistive P1-P4
            3'd4:                chan_val = ldc_l_buf;          // inductance L
            default:             chan_val = ldc_rp_buf;         // ch5 = RP
        endcase
    endfunction

    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin
            sweeping<=1'b0; sch<=3'd0; wcnt<=11'd0;
            s_ch<=3'd0; s_x<=16'sd0; s_sv<=1'b0; s_pe<=1'b0; ts<=32'd0;
        end else begin
            s_sv <= 1'b0; s_pe <= 1'b0;
            if (start_sweep && !sweeping) begin
                sweeping <= 1'b1; sch <= 3'd0; wcnt <= 11'd0;
                s_ch <= 3'd0; s_x <= chan_val(3'd0); s_sv <= 1'b1;   // present ch0
            end else if (sweeping) begin
                if (wcnt == CH_WAIT-1) begin
                    wcnt <= 11'd0;
                    if (sch == 3'd5) begin
                        sweeping <= 1'b0;
                        s_pe     <= 1'b1;            // period end after last channel
                        ts       <= ts + 32'd1;
                    end else begin
                        sch  <= sch + 3'd1;
                        s_ch <= sch + 3'd1;
                        s_x  <= chan_val(sch + 3'd1);
                        s_sv <= 1'b1;
                    end
                end else wcnt <= wcnt + 11'd1;
            end
        end
    end

    //------------------------------------------------------------- TTCGS core
    wire [17:0] mask_w, mfs_w, dead_w; wire [1:0] dir_w;
    wire uncal_any;
    // frame-mirror nets (declared before use: implicit 1-bit nets would
    // silently truncate mir_wa/mir_wd and corrupt every frame)
    wire       mir_we, mir_dn;
    wire [5:0] mir_wa;
    wire [7:0] mir_wd;
    wire [6:0] mir_len;
    wire [7:0] mir_drops;

    ttcgs_sys u_sys (
        .clk(clk27), .rst_n(rst_n),
        .ch_id(s_ch), .sample_in(s_x), .sample_valid(s_sv),
        // dim13 carries whichever stimulus is driving: the rig's {rung, code}
        // when it is fitted, else synth_press's step index.  Only one of the
        // three can be enabled at a time, and ADS_DBG wins because it is a
        // bring-up tap.
        // The $signed() must wrap the WHOLE ternary, not one arm: a ternary with
        // any unsigned operand is unsigned, and ads_dbg/synth_step are unsigned,
        // so signing only pot_aux would still hand a 16-bit unsigned value to a
        // signed port and invert its sign bit.  All three arms are exactly 16
        // bits, so nothing is extended and this only reinterprets.
        .aux_val($signed(ADS_DBG ? ads_dbg : (DIGIPOT ? pot_aux : synth_step))),
        .uncal_any(uncal_any),
        .period_end(s_pe), .timestamp(ts), .health(health_w),
        .line(line),
        .mask(mask_w), .mask_failsafe(mfs_w), .dead(dead_w), .dir_state(dir_w),
        .mir_wr_en(mir_we), .mir_wr_addr(mir_wa), .mir_wr_data(mir_wd),
        .mir_len(mir_len), .mir_done(mir_dn)
    );

    // MIRROR=0 builds the production configuration: the bring-up UART tap is
    // omitted and uart_tx is parked high, so the reported resource figures are
    // those of the shipped datapath rather than of the observation aid.
    localparam MIRROR = 1'b1;
    generate if (MIRROR) begin : g_mir
    //--------------------------------------------- bring-up UART frame mirror
    frame_uart_mirror #(.BAUD_DIV(29)) u_mir (
        .clk(clk27), .rst_n(rst_n),
        .wr_en(mir_we), .wr_addr(mir_wa), .wr_data(mir_wd),
        .payload_len(mir_len), .done(mir_dn),
        .uart_tx(uart_tx), .drop_cnt(mir_drops)
    );
    end else begin : g_nomir
        assign uart_tx = 1'b1;
    end endgenerate

    //------------------------------------------------------------- status LEDs
    assign led_init = ~(ads_init_done & ldc_init_done);

    // CONTACT LED.  Was a 10 ms blink on every sample, which at 690 frames/s is
    // indistinguishable from solid on and therefore carried no information.  It
    // now follows the piezoresistive mask, stretched so the eye can see it: a
    // detection lasts 2 frames (2.90 ms) and a pulse that short is invisible.
    // 120 ms is above the ~60 ms at which a flash reads as a flash rather than
    // a flicker, and short enough that presses 300 ms apart stay distinct.
    // One lamp per band.  A contact excites all three timescales in sequence and
    // that sequence is the whole claim, so showing it needs no laptop: the fast
    // lamp blinks at the edge, the slow one follows as force builds, the
    // sustained one stays lit until release.
    //
    // d0/d1 are RATE detectors -- x[n]-x[n-10] returns to zero while a press is
    // held -- so they are transient by nature and are stretched to be seen.  d2
    // is the only band that reports STATE, which is why it is the one that stays
    // on; an earlier version lit a single lamp on the conjunction of all three
    // and went dark whenever the finger stopped moving.
    //
    // Confirmation counts come from bench data (2026-09-05, sensor fitted):
    // three real presses held d2 for 313/295/455 frames while the incidental
    // excursions around them held it for 270, 3, 1, 1, 1 and 1.  Sixteen frames
    // on d2 removes the blips; four on the transient bands keeps them responsive
    // while still rejecting a single-frame hit.
    //
    // These gate the LAMPS only -- mask_w reaches the frame untouched.
    localparam [21:0] LED_HOLD = 22'd3_240_000;   // 120 ms at 27 MHz, min visible
    // The sustained lamp follows the INTERSECTION of dim 2 and dim 3, not dim 2
    // alone.  dim 2 is a 371 ms moving average, so on its own the lamp stayed
    // lit for 371 ms after the finger left -- measured against the raw signal,
    // its reported contact duration is +370 ms long with 43 ms of scatter.
    // dim 3 is the raw put through the same adaptive threshold, and its edges
    // land within +0.0 ms of the true contact (sd 7.7).  Intersecting takes the
    // timing from dim 3 and keeps dim 2's confirmation: over 73 s of
    // non-contact, dim 3 alone let one frame through and the intersection let
    // none.  Verified offline on press_v30.csv before the change was made.
    wire [2:0] band_src = {mask_w[2] & mask_w[3], mask_w[1], mask_w[0]};

    wire [2:0] band_lit;
    genvar lb;
    generate
        for (lb = 0; lb < 3; lb = lb + 1) begin : g_bandled
            // dim 3's edges are already sharp, so the sustained lamp no longer
            // needs the long confirmation that suppressed d2's one-frame blips.
            localparam [4:0] CONF = (lb == 2) ? 5'd8 : 5'd4;
            reg [4:0]  cf;
            reg [21:0] hc;
            reg        lit;
            always @(posedge clk27 or negedge rst_n) begin
                if (!rst_n) begin cf<=5'd0; hc<=22'd0; lit<=1'b0; end
                else begin
                    if (s_pe) begin
                        if (band_src[lb]) begin
                            if (cf != CONF) cf <= cf + 5'd1;
                        end else cf <= 5'd0;
                    end
                    if (cf == CONF)       begin lit<=1'b1; hc<=LED_HOLD; end
                    else if (hc != 22'd0) hc <= hc - 22'd1;
                    else                  lit <= 1'b0;
                end
            end
            assign band_lit[lb] = lit;
        end
    endgenerate
    assign led_d0    = ~band_lit[0];
    assign led_d1    = ~band_lit[1];
    assign led_d2    = ~band_lit[2];
    assign led_uncal = ~uncal_any;

    //--------------------------------------------------------- AD5254 floor rig
    // The demo servo used to live here and drove pin 32; it is removed, see the
    // port list.  `tick` is start_sweep, one pulse per frame, the same tick
    // synth_press ran on, so a rung of the ramp is an integer number of frames.
    generate if (DIGIPOT) begin : g_pot
        // R_LEN/H_LEN are overridden because the defaults measured the wrong
        // thing (2026-09-12).  At R_LEN=55 the onset takes 80 ms, whose energy
        // is below DoG_fast's 14 Hz lower edge, so the fast band never fired at
        // any amplitude up to 397 counts -- the filter was correctly rejecting
        // a stimulus far slower than the contact it is built for (a real finger
        // onset peaks DoG_fast at 16 ms, and synth_press rose in 1.45 ms, 55x
        // faster than this rig did).  8 frames = 11.6 ms puts the onset in the
        // band being tested.
        // H_LEN=124 was 180 ms against G_sigma3's 256-tap, 371 ms window, so
        // the level band could never fill either; 260 frames clears it.
        digipot_rig #(
            .CLK_HZ(27_000_000), .DUAL_BUS(1'b1), .REST_CODE(DIGIPOT_CODE),
            .R_LEN(16'd8), .H_LEN(16'd260), .F_LEN(16'd8), .GAP(16'd2500)
        ) u_pot (
            .clk(clk27), .rst_n(rst_n), .tick(start_sweep),
            .man_en(DIGIPOT_MAN), .man_code(DIGIPOT_CODE),
            .aux(pot_aux), .done(pot_done), .lag_err(pot_lag),
            .ack_err(pot_ack), .ack_err_a(pot_ack_a), .ack_err_b(pot_ack_b),
            .scl_a(scl_a), .sda_a(sda_a), .scl_b(scl_b), .sda_b(sda_b)
        );
    end else begin : g_nopot
        assign pot_aux = 16'sd0;
        assign {pot_done, pot_lag, pot_ack, pot_ack_a, pot_ack_b} = 5'd0;
        // Released, not driven low: an unfitted rig must not hold the bus down
        // for anything else sharing those pins.
        assign scl_a = 1'bz;  assign sda_a = 1'bz;
        assign scl_b = 1'bz;  assign sda_b = 1'bz;
    end endgenerate

    // WP must be HIGH to permit writes.  Tied rather than registered so it is
    // valid the instant configuration completes; before that the pin floats and
    // the part is write-protected, which is the safe direction.
    assign wp_a = 1'b1;
    assign wp_b = 1'b1;

    // ERROR LED.  Restricted to the channels that are supposed to be alive.
    // SINGLE_CH=1 samples ch0 only, so dims 3-11 are dead BY DESIGN and the old
    // `|dead_w` lit this permanently -- an indicator that is always on reports
    // nothing.  HAS_LDC folds the inductive driver's error back in; with no
    // inductive board attached ldc_err is the expected state, not a fault.
    localparam HAS_LDC = 1'b0;
    // The rig's faults belong here too, and they are the whole point during
    // bring-up: ack_err means a chip never answered (dead bus, missing pull-up,
    // wrong address strap), lag_err means the wiper did not keep up with the
    // program, which silently distorts the onset shape the rig exists to
    // control.  Either one invalidates a run, so neither may be silent.
    assign led_err = ~(ads_err | (HAS_LDC && ldc_err) | (|dead_w[2:0])
                       | (DIGIPOT && (pot_ack | pot_lag)));

endmodule
