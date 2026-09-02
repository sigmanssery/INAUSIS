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
    output wire led_init,     // pin 10
    output wire led_acq,      // pin 11
    output wire led_err,      // pin 13

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
    ldc1101_spi u_ldc (
        .clk(clk27), .rst_n(rst_n),
        .ldc_cs_n(ldc_cs_n), .ldc_sclk(ldc_sclk), .ldc_sdi(ldc_sdi), .ldc_sdo(ldc_sdo),
        .ldc_clkin(ldc_clkin),
        .data_valid(ldc_dv), .rp_data(ldc_rp), .l_data(ldc_l),
        .init_done(ldc_init_done), .err_flag(ldc_err)
    );
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

    // SINGLE_CH=1 converts only AIN5 (SINGLE_IDX=0, the FSR on ch0) instead of
    // cycling all four: 159 SPS -> 584 SPS, so the information Nyquist moves from
    // 79.5 Hz to 292 Hz.  Under round-robin the core was fed each ch0 sample four
    // times over, and NOTHING above 79.5 Hz could reach the host no matter what
    // the filters did -- dim 12's raw stream held for 4-5 frames at a time.
    // Cost: ch1..ch3 (dims 3..11) stop updating.  They have no sensor.
    ads114s08_spi #(.SINGLE_CH(1), .SINGLE_IDX(2'd0)) u_ads (
        .clk(clk27), .rst_n(rst_n),
        .ads_cs_n(ads_cs_n), .ads_sclk(ads_sclk), .ads_din(ads_din),
        .ads_dout(ads_dout), .ads_drdy_n(ads_drdy_n), .ads_start(ads_start),
        .data_valid(ads_dv), .data_out(ads_data), .ch_out(ads_ch),
        .init_done(ads_init_done), .err_flag(ads_err)
    );

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
    // Gate on the ADS only, and latch it. The LDC driver re-enters its init
    // sequence whenever the chip ID read fails, so with no LDC board attached
    // ldc_init_done never settles; requiring it here held sampling off forever.
    // A missing inductive board is a legitimate configuration -- those six
    // dimensions are then correctly reported dead -- and must not stop the
    // resistive path. The latch also survives any later ADS recovery.
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
    localparam [19:0] WARM_CLKS = 20'd540000;   // 20 ms past first live sample
    reg        ads_live;
    reg [19:0] warm;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin ads_live <= 1'b0; warm <= 20'd0; end
        else begin
            if (ads_init_done && ads_dv && ads_data != 16'd0) ads_live <= 1'b1;
            if (ads_live && warm != WARM_CLKS) warm <= warm + 20'd1;
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
        .aux_val(synth_step),
        .period_end(s_pe), .timestamp(ts),
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

    reg [19:0] acq_cnt; reg acq_led;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin acq_cnt<=20'd0; acq_led<=1'b0; end
        else if (s_pe) begin acq_cnt<=20'd270000; acq_led<=1'b1; end   // ~10ms blink
        else if (acq_cnt!=20'd0) acq_cnt<=acq_cnt-20'd1;
        else acq_led<=1'b0;
    end
    assign led_acq = ~acq_led;

    // error LED: ADS/LDC error OR any dead channel flagged after calibration
    assign led_err = ~(ads_err | ldc_err | (|dead_w));

endmodule
