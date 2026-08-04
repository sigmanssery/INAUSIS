`timescale 1ns/1ps
module tb_chain_full;
    reg clk=0, rst_n=0; reg [2:0] ch_id; reg signed [15:0] sample_in; reg sample_valid;
    wire [17:0] mask, mask_failsafe; wire chain_busy;
    always #5 clk=~clk;
    dsp_chain dut(.clk(clk),.rst_n(rst_n),.ch_id(ch_id),.sample_in(sample_in),
        .sample_valid(sample_valid),.mask(mask),.mask_failsafe(mask_failsafe),.chain_busy(chain_busy));
    reg signed [15:0] sig [0:2499];
    initial $readmemh("chain_input.mem", sig);
    integer n, b0,b1,b2;
    task feed(input [2:0] ch, input signed [15:0] val);
    integer w;
    begin @(posedge clk); ch_id<=ch; sample_in<=val; sample_valid<=1;
          @(posedge clk); sample_valid<=0;
          for(w=0;w<900;w=w+1) @(posedge clk); end
    endtask
    initial begin
        b0=0;b1=0;b2=0;
        ch_id=0;sample_in=0;sample_valid=0; rst_n=0; #100; rst_n=1; #50;
        for(n=0;n<2500;n=n+1) begin
            feed(3'd0, sig[n]);
            if(n>520) begin
                if(mask[0]) b0=b0+1;
                if(mask[1]) b1=b1+1;
                if(mask[2]) b2=b2+1;
            end
        end
        $display("=== ch0 mask bit counts (after calibration) ===");
        $display("  bit0 (DoG_fast, ROC) = %0d", b0);
        $display("  bit1 (DoG_slow, ROC) = %0d", b1);
        $display("  bit2 (G_s3,     ABS) = %0d", b2);
        $display("  (golden single-dim ref: fast~113, g3~1308; slow somewhere between)");
        $display("  final mask=%b failsafe=%b", mask, mask_failsafe);
        $display("  ch1-5 bits (3-17): %b (should be 0)", mask[17:3]);
        $finish;
    end
    initial begin #400_000_000; $display("TIMEOUT"); $finish; end
endmodule
