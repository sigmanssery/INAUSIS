//=============================================================================
// tb_flag_multi.v - verify zscore_flag_multi
//   dim 0 (ROC): feed flag_input.mem (DoG_fast)  -> expect 113 flags, first 604
//   dim 2 (ABS): feed abs_input.mem  (G_s3)       -> expect 1308 flags, first 607
//   both fed interleaved to prove per-dimension state independence
//=============================================================================
`timescale 1ns/1ps

module tb_flag_multi;
    reg clk=0, rst_n=0;
    reg [4:0] dim_id;
    reg signed [15:0] x_in;
    reg valid, mode_roc;
    wire [4:0] flag_dim;
    wire flag_out, flag_valid;
    wire [17:0] mask;

    always #5 clk=~clk;

    zscore_flag_multi dut(
        .clk(clk),.rst_n(rst_n),
        .dim_id(dim_id),.x_in(x_in),.valid(valid),.mode_roc(mode_roc),
        .flag_dim(flag_dim),.flag_out(flag_out),.flag_valid(flag_valid),.mask(mask)
    );

    reg signed [15:0] roc_vec [0:2499];   // DoG_fast (ROC)
    reg signed [15:0] abs_vec [0:2499];   // G_s3 (ABS)
    initial $readmemh("flag_input.mem", roc_vec);
    initial $readmemh("abs_input.mem",  abs_vec);

    integer n;
    integer roc_flags, roc_first, abs_flags, abs_first;

    // feed one sample to a dimension, return after flag_valid
    task feed(input [4:0] d, input signed [15:0] val, input mr);
    begin
        @(posedge clk); dim_id<=d; x_in<=val; valid<=1; mode_roc<=mr;
        @(posedge clk); valid<=0;
        @(posedge clk);  // let flag register settle
    end
    endtask

    initial begin
        roc_flags=0; roc_first=-1; abs_flags=0; abs_first=-1;
        dim_id=0; x_in=0; valid=0; mode_roc=0;
        rst_n=0; #100; rst_n=1; #50;

        // interleave: dim0 gets ROC vec, dim2 gets ABS vec, same index n
        for (n=0; n<2500; n=n+1) begin
            // dim 0, ROC mode
            feed(5'd0, roc_vec[n], 1'b1);
            if (flag_valid && flag_out && flag_dim==0) begin
                roc_flags=roc_flags+1;
                if (roc_first<0) roc_first=n;
            end
            // dim 2, ABS mode
            feed(5'd2, abs_vec[n], 1'b0);
            if (flag_valid && flag_out && flag_dim==2) begin
                abs_flags=abs_flags+1;
                if (abs_first<0) abs_first=n;
            end
        end

        $display("=== multi-flag results ===");
        $display("dim0 ROC: flags=%0d first=%0d  (expect 113, 604)", roc_flags, roc_first);
        $display("dim2 ABS: flags=%0d first=%0d  (expect 1308, 607)", abs_flags, abs_first);
        $display("final mask = %b", mask);
        $finish;
    end
    initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
