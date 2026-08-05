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
    inout  wire line          // 42 (generic GPIO, board pull-up)
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

    ads114s08_spi u_ads (
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
    localparam PER_CLKS = 15'd27000;   // 27 MHz / 27000 = 1 kHz
    localparam CH_WAIT  = 11'd900;     // > DoG sweep (~770) per channel
    reg [14:0] per_cnt;
    reg        start_sweep;
    always @(posedge clk27 or negedge rst_n) begin
        if (!rst_n) begin per_cnt<=15'd0; start_sweep<=1'b0; end
        else begin
            start_sweep <= 1'b0;
            if (per_cnt == PER_CLKS-1) begin per_cnt<=15'd0; start_sweep<=1'b1; end
            else                           per_cnt<=per_cnt+15'd1;
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
            3'd0,3'd1,3'd2,3'd3: chan_val = ads_buf[c[1:0]];   // piezoresistive P1-P4
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
    ttcgs_sys u_sys (
        .clk(clk27), .rst_n(rst_n),
        .ch_id(s_ch), .sample_in(s_x), .sample_valid(s_sv),
        .period_end(s_pe), .timestamp(ts),
        .line(line),
        .mask(mask_w), .mask_failsafe(mfs_w), .dead(dead_w), .dir_state(dir_w)
    );

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
