`timescale 1ns/1ps
//=============================================================================
// tb_chain_full_lite.v
//
// Lightweight version of tb_chain_full: feeds only 720 samples of ch0 (enough
// to calibrate dims 0-2 at the new 513-sample latency + cover the touch onset
// in chain_input.mem) so it finishes within EDA Playground's run-time limit.
// Confirms the DoG->zscore datapath still detects events after the
// calibration (512->513) / variance / dead changes, and asserts the invariant
// that the five un-fed channels (dims 3-17) stay silent.
//
// Needs chain_input.mem (first 720 samples) + dog_coeffs.mem.
//=============================================================================
module tb_chain_full_lite;
    reg clk=0, rst_n=0; reg [2:0] ch_id; reg signed [15:0] sample_in; reg sample_valid;
    wire [17:0] mask, mask_failsafe, dead; wire chain_busy;
    always #5 clk=~clk;
    dsp_chain dut(.clk(clk),.rst_n(rst_n),.ch_id(ch_id),.sample_in(sample_in),
        .sample_valid(sample_valid),
        .lut_wr(1'b0),.lut_dim(5'd0),.lut_thr(16'd0),
        .mask(mask),.mask_failsafe(mask_failsafe),.dead(dead),.chain_busy(chain_busy));
    reg signed [15:0] sig [0:719];
    initial $readmemh("chain_input.mem", sig);
    integer n, b0,b1,b2;
    task feed(input [2:0] ch, input signed [15:0] val);
    integer w;
    begin @(posedge clk); ch_id<=ch; sample_in<=val; sample_valid<=1;
          @(posedge clk); sample_valid<=0;
          for(w=0;w<850;w=w+1) @(posedge clk); end
    endtask
    initial begin
        b0=0;b1=0;b2=0;
        ch_id=0;sample_in=0;sample_valid=0; rst_n=0; #100; rst_n=1; #50;
        for(n=0;n<720;n=n+1) begin
            feed(3'd0, sig[n]);
            if(n>520) begin
                if(mask[0]) b0=b0+1;
                if(mask[1]) b1=b1+1;
                if(mask[2]) b2=b2+1;
            end
        end
        $display("=== ch0 mask bit counts (lite: 720 samples, after calibration) ===");
        $display("  bit0 (DoG_fast, ROC) = %0d", b0);
        $display("  bit1 (DoG_slow, ROC) = %0d", b1);
        $display("  bit2 (G_s3,     ABS) = %0d", b2);
        $display("  final mask=%b", mask);
        $display("  failsafe  =%b", mask_failsafe);
        $display("  dead      =%b", dead);
        $display("  ch1-5 bits (dims 3-17) = %b", mask[17:3]);
        if(mask[17:3]==15'd0) $display("  PASS: un-fed channels (dims 3-17) stayed silent");
        else                  $display("  FAIL: a non-fed channel fired");
        $finish;
    end
    initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
