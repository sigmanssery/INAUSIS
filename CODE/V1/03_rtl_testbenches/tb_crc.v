`timescale 1ns/1ps
module tb_crc;
    reg clk=0, rst_n=0, clr=0, data_valid=0;
    reg [7:0] data_in;
    wire [15:0] crc_out;
    always #5 clk=~clk;
    crc16_ccitt dut(.clk(clk),.rst_n(rst_n),.clr(clr),.data_in(data_in),
        .data_valid(data_valid),.crc_out(crc_out));
    // standard check: "123456789" -> 0x29B1
    reg [7:0] msg [0:8];
    integer i;
    initial begin
        msg[0]="1";msg[1]="2";msg[2]="3";msg[3]="4";msg[4]="5";
        msg[5]="6";msg[6]="7";msg[7]="8";msg[8]="9";
        data_in=0; rst_n=0; #20; rst_n=1; #20;
        @(posedge clk); clr<=1; @(posedge clk); clr<=0;
        for(i=0;i<9;i=i+1) begin
            @(posedge clk); data_in<=msg[i]; data_valid<=1;
            @(posedge clk); data_valid<=0;
        end
        @(posedge clk); #1;
        $display("CRC-16-CCITT of \"123456789\" = 0x%04h (expect 0x29B1) %s",
                 crc_out, (crc_out==16'h29B1)?"PASS":"FAIL");
        $finish;
    end
    initial begin #2000; $finish; end
endmodule
