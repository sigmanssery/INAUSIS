//=============================================================================
// digipot_rig -- super-pot mapper + I2C scheduler for the floor rig.
//
// Two AD5254 (8 channels x 100 kOhm) wired in series make one 800 kOhm,
// 2048-step rheostat.  Channel i holds clamp(code - 256*i, 0, 255), so:
//   - the mapping is monotonic in the super code,
//   - a one-step change of the super code moves exactly ONE channel by one,
//     so there is no boundary glitch and no need for an atomic multi-channel
//     update in the common case.
//
// SCHEDULER.  Rather than trying to push a whole 8-channel image on every
// change, a walker cycles channels 0..7 comparing the value last written with
// the value the current super code wants, and issues a write whenever they
// differ.  This is self-healing: after ANY jump (including the power-on load of
// all eight channels) it converges without special-casing, and for the ordinary
// one-step-per-frame ramp it finds the single changed channel within 8 clocks.
//
// A 3-byte write is ~28 SCL periods = 280 us at 100 kHz, against a 1.45 ms
// frame, so a single-channel update has ~5x headroom.  A full 8-channel reload
// takes 8 writes = 2.24 ms and therefore spans two frames -- that only happens
// at reset and during the GAP, never inside a ramp.
//
// lag_err latches if the super code changes while the walker has not finished
// converging, i.e. the wiper did not keep up with the program.  Wire it into a
// status bit and check it before trusting any run -- a silent lag would distort
// the onset shape, which is exactly the thing this rig is supposed to control.
//
// BUS TOPOLOGY -- DUAL_BUS picks how the two chips are reached:
//
//   DUAL_BUS = 1 (default, recommended).  One bus per chip: channels 0..3 on
//     bus A, channels 4..7 on bus B.  BOTH chips strap AD1 = AD0 = GND, so the
//     address is 0x2C on each.  This is fewer solder joints (no AD0 strap to
//     3V3), a bad joint only costs four channels instead of all eight, and each
//     chip can be brought up on its own.
//
//   DUAL_BUS = 0.  Both chips share bus A; then chip B MUST strap AD0 = 3V3 so
//     it answers on 0x2D.  Bus B's pins are left released.
//
// Only one transaction is in flight at a time in either mode.  The buses could
// run concurrently, but the worst case is two channel writes in one frame
// (560 us at 100 kHz against a 1.45 ms frame), so serialising costs nothing and
// keeps the walker simple.
//=============================================================================
`default_nettype none

module digipot_rig #(
    parameter integer CLK_HZ    = 27000000,
    parameter integer SCL_HZ    = 100000,
    parameter         DUAL_BUS  = 1'b1,    // 1 = one bus per chip (see above)
    parameter [10:0]  REST_CODE = 11'd1746,
    parameter [15:0]  R_LEN     = 16'd55,
    parameter [15:0]  H_LEN     = 16'd124,
    parameter [15:0]  F_LEN     = 16'd55,
    parameter [15:0]  GAP       = 16'd690,
    parameter [7:0]   N_REP     = 8'd10
)(
    input  wire               clk,
    input  wire               rst_n,
    input  wire               tick,      // one pulse per frame
    input  wire               man_en,    // park at man_code for calibration
    input  wire [10:0]        man_code,
    output wire signed [15:0] aux,       // {rung, code} -> AUX_DIM
    output wire               done,
    output reg                lag_err,   // wiper did not keep up
    output wire               ack_err,   // an AD5254 did not acknowledge
    output wire               ack_err_a, // per-bus, so a dead chip is localised
    output wire               ack_err_b,
    inout  wire               scl_a,
    inout  wire               sda_a,
    inout  wire               scl_b,
    inout  wire               sda_b
);
    wire [10:0] code;
    wire        code_wr;

    wire signed [15:0] sweep_aux;  // the sweep's own {rung, code}, before the tap

    digipot_sweep #(
        .REST_CODE(REST_CODE), .R_LEN(R_LEN), .H_LEN(H_LEN),
        .F_LEN(F_LEN), .GAP(GAP), .N_REP(N_REP)
    ) u_sweep (
        .clk(clk), .rst_n(rst_n), .tick(tick),
        .man_en(man_en), .man_code(man_code),
        .code(code), .code_wr(code_wr), .aux(sweep_aux), .done(done)
    );

    // In manual mode the sweep sets the rung field to the constant 31, so its
    // low two bits carry nothing.  Borrow them to report which of the four
    // addresses the search settled on; without this the only way to find out
    // would be another build, and the design has 0.2% of timing margin to spend.
    // rung still reads 111xx, so "manual" is still recognisable at a glance.
    assign aux = man_en ? {3'b111, dev_sel, sweep_aux[10:0]} : sweep_aux;

    // ---- super code -> per-channel wiper value -------------------------------
    // Channel i holds clamp(code - 255*i, 0, 255).  The stride is 255, NOT 256:
    // each channel spans 0..255, so consecutive channels must ABUT at 255, not
    // at 256.  With a stride of 256 the sum stalls at every channel boundary --
    // 7 dead codes where incrementing the super code changes no resistance at
    // all, which would put invisible flat spots in the amplitude ladder.
    // With stride 255, sum(want_i) == code exactly for code = 0..2040.
    function [7:0] want_of;
        input [10:0] c;
        input [2:0]  i;
        reg   [11:0] base, d;
        begin
            base = {1'b0, i, 8'd0} - {9'd0, i};     // 256*i - i = 255*i
            if ({1'b0, c} <= base) begin
                want_of = 8'd0;
            end else begin
                d = {1'b0, c} - base;
                want_of = (d >= 12'd255) ? 8'd255 : d[7:0];
            end
        end
    endfunction

    reg  [7:0] cur [0:7];        // value last written to each channel
    reg  [7:0] valid;            // bit k: cur[k] reflects a write we actually made
    reg        primed;           // the walker has converged at least once
    reg  [2:0] w;                // walker index
    reg        start_a, start_b;
    reg  [1:0] i2c_dev, i2c_chan;
    reg  [7:0] i2c_val;
    wire       busy_a, busy_b;
    wire       i2c_busy  = busy_a | busy_b;
    wire       i2c_start = start_a | start_b;
    wire [7:0] want_w    = want_of(code, w);

    // channel 0..3 -> chip A, 4..7 -> chip B
    wire       on_b = w[2];
    wire       use_b = DUAL_BUS ? on_b : 1'b0;              // which bus

    // ---- address search ------------------------------------------------------
    // The AD5254's slave address is 0101 1 AD1 AD0, so it is one of exactly four
    // values and dev is already two bits wide.  The breakout used here does not
    // bring AD0/AD1 out to a header (2026-09-12), so the strap is whatever the
    // module decided and cannot be read off the board -- but a four-value search
    // costs nothing, and it is the same mechanism as retrying a NACK, so both
    // are done by the one path below: a NACKed write leaves the channel invalid
    // AND steps the address.  Once an address answers, every later write ACKs
    // and the search stops on its own.
    reg  [1:0] dev_sel;
    wire [1:0] dev_w = DUAL_BUS ? dev_sel : (dev_sel | {1'b0, on_b});

    // the write in flight, held until the transaction's acknowledge is known
    reg        pend, pend_b, busy_d;
    reg  [2:0] pend_w;
    reg  [7:0] pend_val;
    wire       pend_nack = pend_b ? ack_err_b : ack_err_a;

    integer k;
    reg converged;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // cur[] used to be loaded with 8'hFF here to "force a full reload".
            // It does not: 0xFF is a LEGAL target, so every channel whose target
            // happens to be 255 compares equal and is never written.  At the
            // rest code 1746 that is six channels of eight -- they stayed at the
            // part's EEMEM midscale while the rig reported them as 255, i.e. the
            // ladder was wrong and nothing said so (found 2026-09-12).
            // No 8-bit sentinel can work, because all 256 values are legal, so
            // validity is tracked separately.
            valid <= 8'd0; primed <= 1'b0;
            dev_sel <= 2'd0; pend <= 1'b0; pend_b <= 1'b0; busy_d <= 1'b0;
            pend_w <= 3'd0; pend_val <= 8'd0;
            for (k = 0; k < 8; k = k + 1) cur[k] <= 8'd0;
            w <= 3'd0; start_a <= 1'b0; start_b <= 1'b0; lag_err <= 1'b0;
            i2c_dev <= 2'd0; i2c_chan <= 2'd0; i2c_val <= 8'd0;
        end else begin
            start_a <= 1'b0; start_b <= 1'b0;

            // Did the program move the code before the wiper caught up?
            //
            // `primed` exists because the startup reload is not a lag.  Every
            // reset begins un-converged by construction, so the first code_wr
            // latched lag_err unconditionally and led_err was lit permanently
            // after every reset -- including after a reset button press, which
            // is what made it look like a stuck hardware fault (2026-09-12).
            // Only a code change AFTER the first convergence is a real lag.
            if (code_wr) begin
                converged = 1'b1;
                for (k = 0; k < 8; k = k + 1)
                    if (!valid[k] || cur[k] != want_of(code, k[2:0])) converged = 1'b0;
                if (converged)      primed  <= 1'b1;
                else if (primed)    lag_err <= 1'b1;
            end

            // walker: one comparison per clock, issue a write on a mismatch
            // A write is only believed once the slave has acknowledged it.  The
            // old code marked the channel written the moment it was ISSUED, so a
            // single NACK -- at power-up, on a bad contact, at the wrong address
            // -- stuck permanently and silently, and the module's "self-healing"
            // claim did not hold on that path.
            busy_d <= i2c_busy;
            if (pend && busy_d && !i2c_busy) begin
                pend <= 1'b0;
                if (pend_nack) dev_sel <= dev_sel + 2'd1;   // try the next address
                else begin
                    cur[pend_w]   <= pend_val;
                    valid[pend_w] <= 1'b1;
                end
            end

            if (!i2c_busy && !i2c_start && !pend) begin
                if (!valid[w] || cur[w] != want_w) begin
                    i2c_dev  <= dev_w;
                    i2c_chan <= w[1:0];
                    i2c_val  <= want_w;
                    pend     <= 1'b1;
                    pend_w   <= w;
                    pend_val <= want_w;
                    pend_b   <= use_b;
                    if (use_b) start_b <= 1'b1;
                    else       start_a <= 1'b1;
                end
                w <= w + 3'd1;
            end
        end
    end

    ad5254_i2c #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) u_i2c_a (
        .clk(clk), .rst_n(rst_n),
        .start(start_a), .dev(i2c_dev), .chan(i2c_chan), .value(i2c_val),
        .busy(busy_a), .ack_err(ack_err_a),
        .scl(scl_a), .sda(sda_a)
    );

    ad5254_i2c #(.CLK_HZ(CLK_HZ), .SCL_HZ(SCL_HZ)) u_i2c_b (
        .clk(clk), .rst_n(rst_n),
        .start(start_b), .dev(i2c_dev), .chan(i2c_chan), .value(i2c_val),
        .busy(busy_b), .ack_err(ack_err_b),
        .scl(scl_b), .sda(sda_b)
    );

    assign ack_err = ack_err_a | ack_err_b;
endmodule

`default_nettype wire
