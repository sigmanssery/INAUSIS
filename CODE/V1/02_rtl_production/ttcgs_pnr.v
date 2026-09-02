`timescale 1ns/1ps
//=============================================================================
// ttcgs_pnr.v  (TIMING-CLOSURE HARNESS, not a board top)
//
// Thin pin-reduced wrapper around the full ttcgs_sys so place-and-route can
// complete on the GW1NR-9 (the real ttcgs_sys has ~85 test I/O, far more than
// the ~63 usable device pins). It instantiates the COMPLETE ttcgs_sys core, so
// static timing analysis sees the actual datapath (DoG BSRAM->DSP->39-bit acc,
// flag distributed-RAM->variance->compare, framer, half-duplex). The wide test
// I/O is replaced by a small synthetic sample generator (so input registers are
// real, not optimized to constants) and the outputs are reduced to a few pins.
//
// This is ONLY for timing closure. The real board top (SPI front-ends feeding
// samples, Manchester out, mask_failsafe GPIO) is separate bring-up work.
//=============================================================================
module ttcgs_pnr (
    input  wire        clk,        // 27 MHz crystal
    input  wire        rst_n,
    input  wire        samp_en,    // stream synthetic samples when high
    inout  wire        line,       // single-wire Manchester link
    output wire        flag_o,     // OR-reduction of the 18-bit mask
    output wire [1:0]  dir_o       // half-duplex direction state
);
    // synthetic, non-constant stimulus so the MAC/variance paths stay real
    reg [2:0]         ch;
    reg signed [15:0] samp;
    reg               sv;
    reg [31:0]        ts;
    reg               pe;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ch<=3'd0; samp<=16'sd0; sv<=1'b0; ts<=32'd0; pe<=1'b0;
        end else begin
            ch   <= (ch==3'd5) ? 3'd0 : ch+3'd1;
            samp <= samp + 16'sd17;        // varying input
            sv   <= samp_en;
            pe   <= samp_en && (ch==3'd5); // period end after last channel
            if (ch==3'd5) ts <= ts + 32'd1;
        end
    end

    wire [17:0] mask_w, mfs_w, dead_w;
    ttcgs_sys u_sys (
        .clk(clk), .rst_n(rst_n),
        .ch_id(ch), .sample_in(samp), .sample_valid(sv),
        .period_end(pe), .timestamp(ts),
        .line(line),
        .mask(mask_w), .mask_failsafe(mfs_w), .dead(dead_w),
        .dir_state(dir_o)
    );
    assign flag_o = |mask_w | (^mfs_w) | (^dead_w);  // keep outputs from being trimmed
endmodule
