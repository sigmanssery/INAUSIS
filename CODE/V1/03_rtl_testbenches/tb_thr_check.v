`timescale 1ns/1ps
module tb_thr_check;
    reg clk=0, rst_n=0;
    reg [4:0] dim_id; reg signed [15:0] x_in; reg fvalid, mode_roc;
    reg lut_wr; reg [4:0] lut_dim; reg [31:0] lut_thr;
    wire [4:0] flag_dim; wire flag_out, flag_valid; wire [17:0] mask, mask_fs;
    always #5 clk=~clk;
    zscore_flag_multi flag(.clk(clk),.rst_n(rst_n),.dim_id(dim_id),.x_in(x_in),
        .valid(fvalid),.mode_roc(mode_roc),.lut_wr(lut_wr),.lut_dim(lut_dim),.lut_thr(lut_thr),
        .flag_dim(flag_dim),.flag_out(flag_out),.flag_valid(flag_valid),.mask(mask),.mask_failsafe(mask_fs));
    initial begin
        dim_id=0;x_in=0;fvalid=0;mode_roc=0;lut_wr=0;lut_dim=0;lut_thr=0;
        rst_n=0;#20;rst_n=1;#20;
        $display("threshold[2] before = 0x%04h", flag.threshold[2]);
        // direct LUT write
        @(posedge clk); lut_wr<=1; lut_dim<=2; lut_thr<=32'h0000_1234;
        @(posedge clk); lut_wr<=0;
        @(posedge clk); @(posedge clk);
        $display("threshold[2] after LUT write = 0x%04h (expect 0x1234)", flag.threshold[2]);
        $display("calibrated[2] = %b (expect 1, SoC override marks it calibrated)", flag.calibrated[2]);
        if(flag.threshold[2]==16'h1234 && flag.calibrated[2])
            $display("PASS: LUT write applies to flag engine, threshold updated + dim calibrated");
        else $display("FAIL");
        $finish;
    end
    initial begin #2000; $finish; end
endmodule
