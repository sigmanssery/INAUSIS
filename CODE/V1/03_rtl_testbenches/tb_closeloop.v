`timescale 1ns/1ps
module tb_closeloop;
    reg clk=0, rst_n=0;
    wire line; pullup(line);
    // FPGA half-duplex
    reg fwd_wr_en; reg [5:0] fwd_wr_addr; reg [7:0] fwd_wr_data; reg [6:0] fwd_len; reg fwd_start;
    wire [7:0] rev_byte; wire rev_valid, rev_frame_done, rev_crc_ok; wire [1:0] dir_state;
    halfduplex_ctrl #(.HALF_CLKS(8),.TURN_CLKS(16)) fpga(.clk(clk),.rst_n(rst_n),.line(line),
        .fwd_wr_en(fwd_wr_en),.fwd_wr_addr(fwd_wr_addr),.fwd_wr_data(fwd_wr_data),
        .fwd_len(fwd_len),.fwd_start(fwd_start),.rev_byte(rev_byte),.rev_valid(rev_valid),
        .rev_frame_done(rev_frame_done),.rev_crc_ok(rev_crc_ok),.dir_state(dir_state));
    always #5 clk=~clk;
    // LUT parser
    wire lut_wr; wire [4:0] lut_dim; wire [31:0] lut_thr;
    lut_parser parser(.clk(clk),.rst_n(rst_n),.rev_byte(rev_byte),.rev_valid(rev_valid),
        .rev_frame_done(rev_frame_done),.rev_crc_ok(rev_crc_ok),
        .lut_wr(lut_wr),.lut_dim(lut_dim),.lut_thr(lut_thr));
    // flag engine (receives LUT writes)
    reg [4:0] dim_id; reg signed [15:0] x_in; reg fvalid, mode_roc;
    wire [4:0] flag_dim; wire flag_out, flag_valid; wire [17:0] mask, mask_fs;
    zscore_flag_multi flag(.clk(clk),.rst_n(rst_n),.dim_id(dim_id),.x_in(x_in),
        .valid(fvalid),.mode_roc(mode_roc),
        .lut_wr(lut_wr),.lut_dim(lut_dim),.lut_thr(lut_thr),
        .flag_dim(flag_dim),.flag_out(flag_out),.flag_valid(flag_valid),
        .mask(mask),.mask_failsafe(mask_fs));
    // SoC mirror
    reg soc_drive_en; wire soc_tx_line; assign line = soc_drive_en ? soc_tx_line : 1'bz;
    reg soc_fwr_en; reg [5:0] soc_fwr_addr; reg [7:0] soc_fwr_data; reg [6:0] soc_flen; reg soc_fstart;
    wire soc_tx_active, soc_tx_done;
    manchester_tx #(.HALF_CLKS(8),.PREAMBLE_LEN(4)) soc_tx(.clk(clk),.rst_n(rst_n),
        .wr_en(soc_fwr_en),.wr_addr(soc_fwr_addr),.wr_data(soc_fwr_data),.payload_len(soc_flen),
        .frame_start(soc_fstart),.data_line(soc_tx_line),.tx_active(soc_tx_active),.frame_done(soc_tx_done));
    wire [7:0] soc_rx_byte; wire soc_rx_valid, srl, srs; reg soc_rx_en;
    manchester_rx #(.HALF_CLKS(8)) soc_rx(.clk(clk),.rst_n(rst_n),.data_line(line),.rx_enable(soc_rx_en),
        .rx_byte(soc_rx_byte),.rx_valid(soc_rx_valid),.locked(srl),.sfd_seen(srs));
    reg [7:0] lut_frame [0:12]; reg [7:0] fwd_frame [0:47]; integer i, soc_rxcnt;
    task build; reg [15:0] c; integer j,k; begin
        // LENGTH=10 + 2 five-byte entries: dim2=0x00ABCDEF (>16-bit, proves the
        // full 32-bit threshold path is intact), dim5=0x0000ABCD
        lut_frame[0]=10;
        lut_frame[1]=2; lut_frame[2]=8'h00; lut_frame[3]=8'hAB; lut_frame[4]=8'hCD; lut_frame[5]=8'hEF;
        lut_frame[6]=5; lut_frame[7]=8'h00; lut_frame[8]=8'h00; lut_frame[9]=8'hAB; lut_frame[10]=8'hCD;
        c=16'hFFFF; for(j=0;j<11;j=j+1) begin c=c^{lut_frame[j],8'h00};
            for(k=0;k<8;k=k+1) c=c[15]?((c<<1)^16'h1021):(c<<1); end
        lut_frame[11]=c[15:8];lut_frame[12]=c[7:0]; end
    endtask
    always @(posedge clk) if(soc_rx_valid) soc_rxcnt<=soc_rxcnt+1;
    always @(posedge clk) if(lut_wr) $display("@%0t flag got LUT: dim=%0d thr=%08h", $time, lut_dim, lut_thr);
    initial begin
        for(i=0;i<48;i=i+1) fwd_frame[i]=i[7:0];
        build;
        fwd_wr_en=0;fwd_wr_addr=0;fwd_wr_data=0;fwd_len=0;fwd_start=0;
        soc_drive_en=0;soc_fwr_en=0;soc_fwr_addr=0;soc_fwr_data=0;soc_flen=0;soc_fstart=0;
        soc_rx_en=0;soc_rxcnt=0; dim_id=0;x_in=0;fvalid=0;mode_roc=0;
        rst_n=0;#100;rst_n=1;#50;
        $display("=== CLOSED LOOP: SoC LUT update -> FPGA flag threshold ===");
        $display("threshold[2] before = %0d", flag.threshold[2]);
        // FPGA send forward
        for(i=0;i<48;i=i+1) begin @(posedge clk);fwd_wr_en<=1;fwd_wr_addr<=i[5:0];fwd_wr_data<=fwd_frame[i]; end
        @(posedge clk);fwd_wr_en<=0;fwd_len<=7'd48;
        @(posedge clk);soc_rx_en<=1;
        @(posedge clk);fwd_start<=1;@(posedge clk);fwd_start<=0;
        wait(soc_rxcnt>=48); soc_rx_en<=0;
        // SoC send reverse LUT frame
        for(i=0;i<13;i=i+1) begin @(posedge clk);soc_fwr_en<=1;soc_fwr_addr<=i[5:0];soc_fwr_data<=lut_frame[i]; end
        @(posedge clk);soc_fwr_en<=0;soc_flen<=7'd13;
        @(posedge clk);soc_drive_en<=1;soc_fstart<=1;@(posedge clk);soc_fstart<=0;
        wait(soc_tx_done);@(posedge clk);soc_drive_en<=0;
        // The CRC-gated lut_parser applies its buffered entries only AFTER the
        // whole reverse frame + CRC are received and validated, then replays
        // them as lut_wr pulses. Wait a fixed, generous span for last-byte RX
        // decode + CRC check + buffered replay (timing-independent; the old
        // wait(lut_wr)/wait(rev_frame_done) tail assumed the streaming parser).
        repeat(3000) @(posedge clk);
        $display("threshold[2] after  = %0d (0x%010h, expect 0x00ABCDEF=%0d)", flag.threshold[2], flag.threshold[2], 32'h00ABCDEF);
        $display("threshold[5] after  = %0d (0x%010h, expect 0x0000ABCD=%0d)", flag.threshold[5], flag.threshold[5], 32'h0000ABCD);
        if(flag.threshold[2]==32'h00ABCDEF && flag.threshold[5]==32'h0000ABCD)
            $display("PASS: closed loop works! SoC successfully updated FPGA flag thresholds");
        else $display("FAIL");
        $finish;
    end
    initial begin #20000000; $display("TIMEOUT"); $finish; end
endmodule
