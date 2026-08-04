`timescale 1ns/1ps
module tb_hd2;
    reg clk=0, rst_n=0;
    wire line; pullup(line);
    reg fwd_wr_en; reg [5:0] fwd_wr_addr; reg [7:0] fwd_wr_data; reg [6:0] fwd_len; reg fwd_start;
    wire [7:0] rev_byte; wire rev_valid, rev_frame_done; wire [1:0] dir_state;
    halfduplex_ctrl #(.HALF_CLKS(8),.TURN_CLKS(16)) fpga(.clk(clk),.rst_n(rst_n),.line(line),
        .fwd_wr_en(fwd_wr_en),.fwd_wr_addr(fwd_wr_addr),.fwd_wr_data(fwd_wr_data),
        .fwd_len(fwd_len),.fwd_start(fwd_start),.rev_byte(rev_byte),.rev_valid(rev_valid),
        .rev_frame_done(rev_frame_done),.dir_state(dir_state));
    always #5 clk=~clk;
    reg soc_drive_en; wire soc_tx_line; assign line = soc_drive_en ? soc_tx_line : 1'bz;
    reg soc_fwr_en; reg [5:0] soc_fwr_addr; reg [7:0] soc_fwr_data; reg [6:0] soc_flen; reg soc_fstart;
    wire soc_tx_active, soc_tx_done;
    manchester_tx #(.HALF_CLKS(8),.PREAMBLE_LEN(4)) soc_tx(.clk(clk),.rst_n(rst_n),
        .wr_en(soc_fwr_en),.wr_addr(soc_fwr_addr),.wr_data(soc_fwr_data),.payload_len(soc_flen),
        .frame_start(soc_fstart),.data_line(soc_tx_line),.tx_active(soc_tx_active),.frame_done(soc_tx_done));
    wire [7:0] soc_rx_byte; wire soc_rx_valid, soc_rx_locked, soc_rx_sfd; reg soc_rx_en;
    manchester_rx #(.HALF_CLKS(8)) soc_rx(.clk(clk),.rst_n(rst_n),.data_line(line),.rx_enable(soc_rx_en),
        .rx_byte(soc_rx_byte),.rx_valid(soc_rx_valid),.locked(soc_rx_locked),.sfd_seen(soc_rx_sfd));
    reg [7:0] lut_frame [0:8]; integer i;
    initial begin
        lut_frame[0]=8'd6; lut_frame[1]=8'd2;lut_frame[2]=8'h12;lut_frame[3]=8'h34;
        lut_frame[4]=8'd5;lut_frame[5]=8'hAB;lut_frame[6]=8'hCD;
        lut_frame[7]=8'h00;lut_frame[8]=8'h00; // crc dummy for this trace
    end
    reg [7:0] fwd_frame [0:47];
    integer soc_rxcnt;
    always @(posedge clk) if(soc_rx_valid) soc_rxcnt<=soc_rxcnt+1;
    // log everything FPGA reverse-receives + state changes
    always @(posedge clk) if(rev_valid) $display("@%0t FPGA rev_byte=%02h dir=%0d rev_done=%b", $time, rev_byte, dir_state, rev_frame_done);
    reg [1:0] pd=0;
    always @(posedge clk) if(dir_state!=pd) begin $display("@%0t dir: %0d -> %0d", $time, pd, dir_state); pd<=dir_state; end
    initial begin
        for(i=0;i<48;i=i+1) fwd_frame[i]=i[7:0]^8'h5A;
        fwd_wr_en=0;fwd_wr_addr=0;fwd_wr_data=0;fwd_len=0;fwd_start=0;
        soc_drive_en=0;soc_fwr_en=0;soc_fwr_addr=0;soc_fwr_data=0;soc_flen=0;soc_fstart=0;
        soc_rx_en=0;soc_rxcnt=0;
        rst_n=0;#100;rst_n=1;#50;
        for(i=0;i<48;i=i+1) begin @(posedge clk); fwd_wr_en<=1;fwd_wr_addr<=i[5:0];fwd_wr_data<=fwd_frame[i]; end
        @(posedge clk); fwd_wr_en<=0; fwd_len<=7'd48;
        @(posedge clk); soc_rx_en<=1;
        @(posedge clk); fwd_start<=1; @(posedge clk); fwd_start<=0;
        wait(soc_rxcnt>=48); soc_rx_en<=0;
        for(i=0;i<9;i=i+1) begin @(posedge clk); soc_fwr_en<=1;soc_fwr_addr<=i[5:0];soc_fwr_data<=lut_frame[i]; end
        @(posedge clk); soc_fwr_en<=0; soc_flen<=7'd9;
        @(posedge clk); soc_drive_en<=1; soc_fstart<=1; @(posedge clk); soc_fstart<=0;
        wait(soc_tx_done); @(posedge clk); soc_drive_en<=0;
        #5000; $display("end, dir_state=%0d", dir_state); $finish;
    end
    initial begin #15000000; $display("TIMEOUT"); $finish; end
endmodule
