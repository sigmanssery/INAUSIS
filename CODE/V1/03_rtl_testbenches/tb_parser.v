`timescale 1ns/1ps
module tb_parser;
    reg clk=0, rst_n=0;
    reg [7:0] rev_byte; reg rev_valid, rev_frame_done;
    wire lut_wr; wire [4:0] lut_dim; wire [15:0] lut_thr;
    always #5 clk=~clk;
    lut_parser dut(.clk(clk),.rst_n(rst_n),.rev_byte(rev_byte),.rev_valid(rev_valid),
        .rev_frame_done(rev_frame_done),.lut_wr(lut_wr),.lut_dim(lut_dim),.lut_thr(lut_thr));
    // frame: len=6, [dim2 thr=1234][dim5 thr=ABCD], crc 2 bytes
    reg [7:0] frame [0:8];
    integer i;
    initial begin
        frame[0]=6; frame[1]=2;frame[2]=8'h12;frame[3]=8'h34;
        frame[4]=5;frame[5]=8'hAB;frame[6]=8'hCD; frame[7]=8'hDE;frame[8]=8'hAD;
    end
    always @(posedge clk) if(lut_wr)
        $display("  LUT WRITE: dim=%0d thr=0x%04h", lut_dim, lut_thr);
    initial begin
        rev_byte=0;rev_valid=0;rev_frame_done=0; rst_n=0;#20;rst_n=1;#20;
        $display("=== LUT parser test ===");
        $display("frame: len=6 [dim2=0x1234][dim5=0xABCD]");
        for(i=0;i<9;i=i+1) begin
            @(posedge clk); rev_byte<=frame[i]; rev_valid<=1;
            @(posedge clk); rev_valid<=0; @(posedge clk);
        end
        @(posedge clk); rev_frame_done<=1; @(posedge clk); rev_frame_done<=0;
        #50;
        $display("expected: dim2->1234, dim5->ABCD");
        $finish;
    end
    initial begin #5000; $finish; end
endmodule
