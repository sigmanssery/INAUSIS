`timescale 1ns/1ps
//=============================================================================
// tb_top_lite.v
//
// Lightweight connectivity / frame-layout check through the REAL ttcgs_top
// path (dsp_chain -> frame_packer -> Manchester -> rx). Uses a short inline
// stimulus (no chain_input.mem needed; only dog_coeffs.mem for the DoG ROM)
// so it finishes in well under a second -- suitable for EDA Playground's
// run-time limit, unlike the full tb_top.
//
// It does NOT calibrate (too few samples), so mask/dead are 0; the point is to
// confirm:
//   - a recovered frame is exactly 51 bytes
//   - status lands at byte 48 (proves the dead[45..47] insertion shifted the
//     layout correctly all the way through the real top)
//   - the dead bytes 45..47 are DRIVEN (no x) => dsp_chain.dead is actually
//     wired to frame_packer.dead in ttcgs_top
//   - recovered mask matches the DUT mask
// (Nonzero dead-byte *placement* is already proven by tb_pack_manch.)
//=============================================================================
module tb_top_lite;
    reg clk=0, rst_n=0;
    reg [2:0] ch_id; reg signed [15:0] sample_in; reg sample_valid;
    reg period_end; reg [31:0] timestamp;
    wire [7:0] rx_byte; wire rx_valid, rx_locked, rx_sfd;
    wire [17:0] mask; wire tx_line;
    always #5 clk=~clk;

    ttcgs_top dut(.clk(clk),.rst_n(rst_n),.ch_id(ch_id),.sample_in(sample_in),
        .sample_valid(sample_valid),.period_end(period_end),.timestamp(timestamp),
        .rx_byte(rx_byte),.rx_valid(rx_valid),.rx_locked(rx_locked),.rx_sfd(rx_sfd),
        .mask(mask),.tx_line(tx_line));

    integer rc; reg [7:0] rx_frame [0:50];
    always @(posedge clk) if(rx_valid && rc<51) begin rx_frame[rc]=rx_byte; rc=rc+1; end

    task feed(input [2:0] ch, input signed [15:0] val);
    integer w;
    begin
        @(posedge clk); ch_id<=ch; sample_in<=val; sample_valid<=1;
        @(posedge clk); sample_valid<=0;
        for(w=0;w<850;w=w+1) @(posedge clk);   // let DoG MAC engine finish
    end
    endtask

    integer n, ok;
    initial begin
        ch_id=0;sample_in=0;sample_valid=0;period_end=0;timestamp=32'hAABBCCDD;rc=0;
        rst_n=0;#100;rst_n=1;#50;
        $display("=== tb_top_lite: connectivity + 51B layout through real ttcgs_top ===");
        for(n=0;n<6;n=n+1) feed(3'd0, 16'sd1000);   // short inline stimulus
        @(posedge clk); period_end<=1; @(posedge clk); period_end<=0;
        wait(rx_sfd);
        repeat(20000) @(posedge clk);
        $display("recovered frame: %0d bytes (expect 51)", rc);
        $display("  [0,1]   preamble = %02h %02h (expect aa 55)", rx_frame[0],rx_frame[1]);
        $display("  [2-5]   timestamp= %02h%02h%02h%02h (expect aabbccdd)",
                 rx_frame[2],rx_frame[3],rx_frame[4],rx_frame[5]);
        $display("  [42-44] mask     = %02h %02h %02h", rx_frame[42],rx_frame[43],rx_frame[44]);
        $display("  [45-47] dead     = %02h %02h %02h", rx_frame[45],rx_frame[46],rx_frame[47]);
        $display("  [48]    status   = %02h (expect 01)", rx_frame[48]);
        ok = (rc==51)
           && (rx_frame[0]==8'haa && rx_frame[1]==8'h55)
           && (rx_frame[48]==8'h01)
           && ((^rx_frame[45])!==1'bx) && ((^rx_frame[46])!==1'bx) && ((^rx_frame[47])!==1'bx)
           && (rx_frame[42]==mask[7:0] && rx_frame[43]==mask[15:8]);
        if(ok) $display("PASS: 51B layout + status@48 + dead@45-47 driven + mask match (dead wiring OK)");
        else   $display("FAIL: check fields above");
        $finish;
    end
    initial begin #5_000_000; $display("TIMEOUT rc=%0d",rc); $finish; end
endmodule
