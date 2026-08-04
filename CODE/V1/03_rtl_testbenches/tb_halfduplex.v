`timescale 1ns/1ps
module tb_halfduplex;
    reg clk=0, rst_n=0;
    wire line;   // shared single wire
    pullup(line);  // board pull resistor defines idle level

    // ---- FPGA side (DUT) ----
    reg fwd_wr_en; reg [5:0] fwd_wr_addr; reg [7:0] fwd_wr_data; reg [6:0] fwd_len;
    reg fwd_start;
    wire [7:0] rev_byte; wire rev_valid, rev_frame_done; wire [1:0] dir_state;

    halfduplex_ctrl #(.HALF_CLKS(8),.TURN_CLKS(16)) fpga(
        .clk(clk),.rst_n(rst_n),.line(line),
        .fwd_wr_en(fwd_wr_en),.fwd_wr_addr(fwd_wr_addr),.fwd_wr_data(fwd_wr_data),
        .fwd_len(fwd_len),.fwd_start(fwd_start),
        .rev_byte(rev_byte),.rev_valid(rev_valid),.rev_frame_done(rev_frame_done),
        .dir_state(dir_state));

    always #5 clk=~clk;

    // ---- SoC side (mirror model) ----
    // SoC: listen; when it has received FPGA's forward frame, turn and send a
    // reverse LUT-update frame back.
    reg soc_drive_en;
    wire soc_tx_line;
    assign line = soc_drive_en ? soc_tx_line : 1'bz;

    reg [7:0] soc_tx_byte; reg soc_tx_start;
    wire soc_enc_busy, soc_enc_ready;
    // SoC uses a frame-level TX (manchester_tx) with its own buffer
    reg soc_fwr_en; reg [5:0] soc_fwr_addr; reg [7:0] soc_fwr_data; reg [6:0] soc_flen;
    reg soc_fstart;
    wire soc_tx_active, soc_tx_done;
    manchester_tx #(.HALF_CLKS(8),.PREAMBLE_LEN(4)) soc_tx(
        .clk(clk),.rst_n(rst_n),.wr_en(soc_fwr_en),.wr_addr(soc_fwr_addr),
        .wr_data(soc_fwr_data),.payload_len(soc_flen),.frame_start(soc_fstart),
        .data_line(soc_tx_line),.tx_active(soc_tx_active),.frame_done(soc_tx_done));

    // SoC RX: listen to FPGA's forward frame
    wire [7:0] soc_rx_byte; wire soc_rx_valid, soc_rx_locked, soc_rx_sfd;
    reg soc_rx_en;
    manchester_rx #(.HALF_CLKS(8)) soc_rx(
        .clk(clk),.rst_n(rst_n),.data_line(line),.rx_enable(soc_rx_en),
        .rx_byte(soc_rx_byte),.rx_valid(soc_rx_valid),
        .locked(soc_rx_locked),.sfd_seen(soc_rx_sfd));

    // reverse LUT-update frame content: LENGTH=6, two LUT entries (3B each), then CRC
    // entry0: dim=2, thr=0x1234 ; entry1: dim=5, thr=0xABCD
    reg [7:0] lut_frame [0:8];   // 1 len + 6 data + 2 crc = 9
    integer i;
    task build_lut_frame;
        reg [15:0] crc; integer j,k;
        begin
            lut_frame[0]=8'd6;            // LENGTH = 6 payload bytes
            lut_frame[1]=8'd2;  lut_frame[2]=8'h12; lut_frame[3]=8'h34;  // dim2 thr=1234
            lut_frame[4]=8'd5;  lut_frame[5]=8'hAB; lut_frame[6]=8'hCD;  // dim5 thr=ABCD
            // CRC over the 7 bytes [0..6]
            crc=16'hFFFF;
            for(j=0;j<7;j=j+1) begin
                crc=crc^{lut_frame[j],8'h00};
                for(k=0;k<8;k=k+1) crc=crc[15]?((crc<<1)^16'h1021):(crc<<1);
            end
            lut_frame[7]=crc[15:8]; lut_frame[8]=crc[7:0];
        end
    endtask

    // capture what FPGA receives on reverse channel
    reg [7:0] fpga_got [0:8];
    integer gc;

    // forward tactile frame (simple 48-byte, content not the focus here)
    reg [7:0] fwd_frame [0:47];

    // SoC behavior: receive FPGA forward frame fully, then send reverse frame
    integer soc_rxcnt; reg soc_fwd_done;
    always @(posedge clk) begin
        if(soc_rx_valid) soc_rxcnt <= soc_rxcnt+1;
    end

    always @(posedge clk) if(rev_valid && gc<9) begin fpga_got[gc]<=rev_byte; gc<=gc+1; end

    initial begin
        // init forward frame
        for(i=0;i<48;i=i+1) fwd_frame[i]=i[7:0]^8'h5A;
        build_lut_frame;

        fwd_wr_en=0;fwd_wr_addr=0;fwd_wr_data=0;fwd_len=0;fwd_start=0;
        soc_drive_en=0; soc_fwr_en=0;soc_fwr_addr=0;soc_fwr_data=0;soc_flen=0;soc_fstart=0;
        soc_rx_en=0; soc_rxcnt=0; soc_fwd_done=0; gc=0;
        rst_n=0; #100; rst_n=1; #50;

        $display("=== Half-duplex ping-pong test ===");

        // 1. load FPGA forward frame into FPGA TX buffer
        for(i=0;i<48;i=i+1) begin
            @(posedge clk); fwd_wr_en<=1; fwd_wr_addr<=i[5:0]; fwd_wr_data<=fwd_frame[i];
        end
        @(posedge clk); fwd_wr_en<=0; fwd_len<=7'd48;

        // 2. SoC starts listening
        @(posedge clk); soc_rx_en<=1;

        // 3. FPGA sends forward frame
        @(posedge clk); fwd_start<=1; @(posedge clk); fwd_start<=0;

        // 4. wait for SoC to receive the forward frame (48 payload bytes)
        wait(soc_rxcnt >= 48);
        $display("SoC received %0d forward bytes from FPGA", soc_rxcnt);
        soc_rx_en<=0;

        // 5. FPGA should now be turning to RX. SoC turns to TX and sends LUT frame.
        // load SoC's reverse frame into SoC TX buffer
        for(i=0;i<9;i=i+1) begin
            @(posedge clk); soc_fwr_en<=1; soc_fwr_addr<=i[5:0]; soc_fwr_data<=lut_frame[i];
        end
        @(posedge clk); soc_fwr_en<=0; soc_flen<=7'd9;
        // SoC drives + sends
        @(posedge clk); soc_drive_en<=1; soc_fstart<=1; @(posedge clk); soc_fstart<=0;
        wait(soc_tx_done); 
        @(posedge clk); soc_drive_en<=0;   // SoC releases after sending

        // 6. FPGA should receive the reverse frame
        wait(rev_frame_done); #2000;
        $display("FPGA received reverse frame, %0d bytes", gc);
        $display("  expected LUT: len=6 [dim2 thr=1234][dim5 thr=ABCD]");
        $display("  FPGA got: len=%0d entry0=[dim%0d thr=%02h%02h] entry1=[dim%0d thr=%02h%02h]",
                 fpga_got[0], fpga_got[1],fpga_got[2],fpga_got[3],
                 fpga_got[4],fpga_got[5],fpga_got[6]);
        if(fpga_got[0]==6 && fpga_got[1]==2 && fpga_got[2]==8'h12 && fpga_got[3]==8'h34
           && fpga_got[4]==5 && fpga_got[5]==8'hAB && fpga_got[6]==8'hCD)
            $display("  PASS: ping-pong works, FPGA got correct LUT update");
        else
            $display("  FAIL: LUT mismatch");
        $finish;
    end
    initial begin #20_000_000; $display("TIMEOUT dir_state=%0d gc=%0d",dir_state,gc); $finish; end
endmodule
