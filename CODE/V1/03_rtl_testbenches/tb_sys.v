`timescale 1ns/1ps
//=============================================================================
// tb_sys.v
//
// End-to-end closed-loop test of the full bidirectional system ttcgs_sys.
// A SoC model on the other end of the single wire:
//   1. receives the real forward 51-byte tactile frame (built by frame_packer,
//      sent through halfduplex_ctrl over `line`), and
//   2. sends back a CRC'd reverse LUT-update frame that overwrites two
//      thresholds,
// then we check the thresholds actually changed inside the FPGA flag engine.
//
// Needs dog_coeffs.mem (DoG ROM). Inline sample stimulus, so no input .mem.
//=============================================================================
module tb_sys;
    reg clk=0, rst_n=0;
    reg [2:0] ch_id; reg signed [15:0] sample_in; reg sample_valid;
    reg period_end; reg [31:0] timestamp;
    wire [17:0] mask, mask_failsafe, dead; wire [1:0] dir_state;

    wire line; pullup(line);          // single-wire link, board pull resistor
    always #5 clk=~clk;

    ttcgs_sys dut(.clk(clk),.rst_n(rst_n),.ch_id(ch_id),.sample_in(sample_in),
        .sample_valid(sample_valid),.period_end(period_end),.timestamp(timestamp),
        .line(line),.mask(mask),.mask_failsafe(mask_failsafe),.dead(dead),
        .dir_state(dir_state));

    // ---- SoC side: RX (receive forward frame) + TX (send reverse LUT frame) ----
    wire [7:0] soc_rx_byte; wire soc_rx_valid, srl, srs; reg soc_rx_en;
    manchester_rx #(.HALF_CLKS(8)) soc_rx(.clk(clk),.rst_n(rst_n),.data_line(line),
        .rx_enable(soc_rx_en),.rx_byte(soc_rx_byte),.rx_valid(soc_rx_valid),
        .locked(srl),.sfd_seen(srs));

    reg soc_drive_en; wire soc_tx_line; assign line = soc_drive_en ? soc_tx_line : 1'bz;
    reg soc_fwr_en; reg [5:0] soc_fwr_addr; reg [7:0] soc_fwr_data; reg [6:0] soc_flen; reg soc_fstart;
    wire soc_tx_active, soc_tx_done;
    manchester_tx #(.HALF_CLKS(8),.PREAMBLE_LEN(4)) soc_tx(.clk(clk),.rst_n(rst_n),
        .wr_en(soc_fwr_en),.wr_addr(soc_fwr_addr),.wr_data(soc_fwr_data),.payload_len(soc_flen),
        .frame_start(soc_fstart),.data_line(soc_tx_line),.tx_active(soc_tx_active),.frame_done(soc_tx_done));

    // capture forward frame
    integer rc, i; reg [7:0] fwd [0:50];
    always @(posedge clk) if(soc_rx_valid && rc<51) begin fwd[rc]=soc_rx_byte; rc=rc+1; end

    // reverse LUT frame: LENGTH=10 + 2 five-byte entries (dim2=0x00ABCDEF, dim5=0x0000ABCD) + CRC
    reg [7:0] lut_frame [0:12];
    task build_lut; reg [15:0] c; integer j,k; begin
        lut_frame[0]=10;
        lut_frame[1]=2; lut_frame[2]=8'h00; lut_frame[3]=8'hAB; lut_frame[4]=8'hCD; lut_frame[5]=8'hEF;
        lut_frame[6]=5; lut_frame[7]=8'h00; lut_frame[8]=8'h00; lut_frame[9]=8'hAB; lut_frame[10]=8'hCD;
        c=16'hFFFF; for(j=0;j<11;j=j+1) begin c=c^{lut_frame[j],8'h00};
            for(k=0;k<8;k=k+1) c=c[15]?((c<<1)^16'h1021):(c<<1); end
        lut_frame[11]=c[15:8]; lut_frame[12]=c[7:0]; end
    endtask

    task feed(input [2:0] ch, input signed [15:0] val);
    integer w; begin
        @(posedge clk); ch_id<=ch; sample_in<=val; sample_valid<=1;
        @(posedge clk); sample_valid<=0;
        for(w=0;w<850;w=w+1) @(posedge clk);   // let DoG finish
    end endtask

    integer n;
    initial begin
        ch_id=0;sample_in=0;sample_valid=0;period_end=0;timestamp=32'hAABBCCDD;rc=0;
        soc_rx_en=0;soc_drive_en=0;soc_fwr_en=0;soc_fwr_addr=0;soc_fwr_data=0;soc_flen=0;soc_fstart=0;
        rst_n=0;#100;rst_n=1;#50;
        build_lut;
        $display("=== ttcgs_sys CLOSED LOOP: forward 51B frame + reverse LUT update ===");
        $display("threshold[2] before = %0d", dut.u_chain.u_flag.threshold[2]);

        // a few inline samples so the chain produces a frame
        for(n=0;n<6;n=n+1) feed(3'd0, 16'sd1000);

        // listen, then trigger a forward frame
        soc_rx_en<=1;
        @(posedge clk); period_end<=1; @(posedge clk); period_end<=0;

        // wait for the SoC to receive the full forward frame
        wait(rc>=51);
        $display("forward frame received: %0d bytes; [0,1]=%02h %02h (expect aa 55), [48]status=%02h",
                 rc, fwd[0], fwd[1], fwd[48]);
        repeat(40) @(posedge clk);             // FPGA turns to RX
        soc_rx_en<=0;

        // SoC sends the reverse LUT frame
        for(i=0;i<13;i=i+1) begin @(posedge clk);soc_fwr_en<=1;soc_fwr_addr<=i[5:0];soc_fwr_data<=lut_frame[i]; end
        @(posedge clk);soc_fwr_en<=0;soc_flen<=7'd13;
        @(posedge clk);soc_drive_en<=1;soc_fstart<=1;@(posedge clk);soc_fstart<=0;
        wait(soc_tx_done);@(posedge clk);soc_drive_en<=0;
        repeat(3000) @(posedge clk);           // RX decode + CRC + buffered apply

        $display("threshold[2] after  = %0d (0x%010h, expect 0x00ABCDEF=%0d)",
                 dut.u_chain.u_flag.threshold[2], dut.u_chain.u_flag.threshold[2], 32'h00ABCDEF);
        $display("threshold[5] after  = %0d (0x%010h, expect 0x0000ABCD=%0d)",
                 dut.u_chain.u_flag.threshold[5], dut.u_chain.u_flag.threshold[5], 32'h0000ABCD);
        if(rc>=51 && fwd[0]==8'hAA && fwd[1]==8'h55
           && dut.u_chain.u_flag.threshold[2]==32'h00ABCDEF
           && dut.u_chain.u_flag.threshold[5]==32'h0000ABCD)
            $display("PASS: full system closed loop works (real forward frame + reverse LUT update)");
        else $display("FAIL");
        $finish;
    end
    initial begin #50_000_000; $display("TIMEOUT rc=%0d dir=%0d",rc,dir_state); $finish; end
endmodule
