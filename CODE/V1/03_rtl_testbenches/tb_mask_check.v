`timescale 1ns/1ps
module tb_mask_check;
    reg clk=0, rst_n=0;
    reg [4:0] dim_id; reg signed [15:0] x_in; reg valid, mode_roc;
    wire [4:0] flag_dim; wire flag_out, flag_valid; wire [17:0] mask;
    always #5 clk=~clk;
    zscore_flag_multi dut(.clk(clk),.rst_n(rst_n),.dim_id(dim_id),.x_in(x_in),
        .valid(valid),.mode_roc(mode_roc),
        .lut_wr(1'b0),.lut_dim(5'd0),.lut_thr(16'd0),
        .flag_dim(flag_dim),.flag_out(flag_out),
        .flag_valid(flag_valid),.mask(mask));
    reg signed [15:0] g3 [0:2499];
    initial $readmemh("abs_input.mem", g3);
    integer n;
    task feed(input [4:0] d, input signed [15:0] v, input mr);
    begin @(posedge clk); dim_id<=d; x_in<=v; valid<=1; mode_roc<=mr;
          @(posedge clk); valid<=0; @(posedge clk); end
    endtask
    initial begin
        dim_id=0;x_in=0;valid=0;mode_roc=0; rst_n=0; #50; rst_n=1; #20;
        // 513 samples: new zscore_flag_multi finalizes calibration on the
        // (CAL_N+1)th valid sample (512 accumulate + 1 finalize), vs 512 before.
        for(n=0;n<513;n=n+1) begin feed(5'd2,g3[n],1'b0); feed(5'd5,g3[n],1'b0); end
        // feed dim2 with sustained grasp samples (n=700..720, all large) - debounce needs 3
        for(n=700;n<720;n=n+1) feed(5'd2, g3[n], 1'b0);
        $display("after sustained dim2 event: mask=%b", mask);
        $display("  mask[2]=%b (should be 1)  mask[5]=%b (should be 0, not fed event)", mask[2], mask[5]);
        // feed dim5 rest samples - should stay 0
        for(n=0;n<5;n=n+1) feed(5'd5, g3[n], 1'b0);
        $display("  after dim5 rest: mask[5]=%b (should be 0)", mask[5]);
        $finish;
    end
    initial begin #20_000_000; $finish; end
endmodule
