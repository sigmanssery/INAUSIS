`timescale 1ns/1ps
module tb_dead2;
    reg clk=0, rst_n=0;
    reg [4:0] dim_id; reg signed [15:0] x_in; reg valid, mode_roc;
    reg lut_wr; reg [4:0] lut_dim; reg [31:0] lut_thr;
    wire [4:0] flag_dim; wire flag_out, flag_valid;
    wire [17:0] mask, mask_fs, dead;
    always #5 clk=~clk;
    zscore_flag_multi #(.CAL_N(512)) dut(.clk(clk),.rst_n(rst_n),.dim_id(dim_id),.x_in(x_in),
        .valid(valid),.mode_roc(mode_roc),.lut_wr(lut_wr),.lut_dim(lut_dim),.lut_thr(lut_thr),
        .flag_dim(flag_dim),.flag_out(flag_out),.flag_valid(flag_valid),
        .mask(mask),.mask_failsafe(mask_fs),.dead(dead));
    integer i;
    // This unit test hammers a SINGLE dim, which the real producer (dsp_chain,
    // which feeds distinct dims ch*3+0,1,2) never does. The flag engine is now
    // 3-stage pipelined, so back-to-back same-dim feeds would hit a read-modify-
    // write hazard on cal_sum/cal_cnt. Space each same-dim sample by a few idle
    // cycles so the pipeline drains (mirrors the real once-per-period cadence).
    task feed(input [4:0] d, input signed [15:0] v);
    begin @(posedge clk); dim_id<=d; x_in<=v; mode_roc<=0; valid<=1;
          @(posedge clk); valid<=0;
          @(posedge clk); @(posedge clk); @(posedge clk); end
    endtask
    initial begin
        dim_id=0;x_in=0;valid=0;mode_roc=0;lut_wr=0;lut_dim=0;lut_thr=0;
        rst_n=0; #50; rst_n=1; #20;
        // ONLY dim0, constant 100, 512 times
        for(i=0;i<513;i=i+1) feed(5'd0, 16'sd100);
        #50;
        $display("dim0 constant=100: cal_sum=%0d cal_sumsq=%0d", dut.cal_sum[0], dut.cal_sumsq[0]);
        $display("  threshold[0]=%0d dead[0]=%b", dut.threshold[0], dead[0]);
        $display("  expect: sum=51200 sumsq=5120000 var=0 -> dead=1 thr=9");
        $finish;
    end
    initial begin #2000000; $finish; end
endmodule
