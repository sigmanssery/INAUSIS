`timescale 1ns/1ps
module tb_top;
    reg clk=0, rst_n=0;
    reg [2:0] ch_id; reg signed [15:0] sample_in; reg sample_valid;
    reg period_end; reg [31:0] timestamp;
    wire [7:0] rx_byte; wire rx_valid, rx_locked, rx_sfd;
    wire [17:0] mask; wire tx_line;
    always #5 clk=~clk;

    ttcgs_top dut(.clk(clk),.rst_n(rst_n),.ch_id(ch_id),.sample_in(sample_in),
        .sample_valid(sample_valid),.period_end(period_end),.timestamp(timestamp),
        .rx_byte(rx_byte),.rx_valid(rx_valid),.rx_locked(rx_locked),.rx_sfd(rx_sfd),
        .mask(mask),.tx_line(tx_line));

    reg signed [15:0] sig [0:2499];
    initial $readmemh("chain_input.mem", sig);

    integer n;
    reg [7:0] rx_frame [0:50];
    integer rc;

    // feed one sample to channel ch, wait chain idle
    task feed(input [2:0] ch, input signed [15:0] val);
    integer w;
    begin
        @(posedge clk); ch_id<=ch; sample_in<=val; sample_valid<=1;
        @(posedge clk); sample_valid<=0;
        for(w=0;w<850;w=w+1) @(posedge clk);
    end
    endtask

    always @(posedge clk) if(rx_valid && rc<51) begin rx_frame[rc]=rx_byte; rc=rc+1; end

    integer i;
    initial begin
        ch_id=0;sample_in=0;sample_valid=0;period_end=0;timestamp=32'hAABBCCDD;rc=0;
        rst_n=0;#100;rst_n=1;#50;
        $display("=== FULL SYSTEM: raw -> DSP -> pack -> Manchester -> decode ===");
        // feed ch0 enough samples to calibrate + trigger events (reuse golden sig)
        // feed only ch0 for simplicity; other channels stay 0 (will calibrate to ~0)
        for(n=0;n<720;n=n+1) begin
            feed(3'd0, sig[n]);
        end
        $display("after 720 samples, DSP mask = %b", mask);
        $display("  ch0 bits: g3=%b slow=%b fast=%b", mask[2], mask[1], mask[0]);
        // now trigger a frame: pulse period_end
        @(posedge clk); period_end<=1; @(posedge clk); period_end<=0;
        // wait for the frame to traverse Manchester
        wait(rx_sfd);
        // wait for all 51 payload bytes
        repeat(20000) @(posedge clk);
        $display("recovered frame: %0d bytes", rc);
        if(rc>=49) begin
            $display("  frame[0,1] = %02h %02h (preamble, expect AA 55)", rx_frame[0], rx_frame[1]);
            $display("  frame[2-5] timestamp = %02h%02h%02h%02h (expect AABBCCDD)",
                     rx_frame[2],rx_frame[3],rx_frame[4],rx_frame[5]);
            $display("  frame[42-44] mask = %02h %02h %02h", rx_frame[42],rx_frame[43],rx_frame[44]);
            $display("  frame[45-47] dead = %02h %02h %02h", rx_frame[45],rx_frame[46],rx_frame[47]);
            $display("  frame[48] status  = %02h", rx_frame[48]);
            $display("  DSP mask was      = %b", mask);
            // mask[7:0] should == frame[42]
            if(rx_frame[42]==mask[7:0] && rx_frame[43]==mask[15:8])
                $display("  PASS: recovered mask matches DSP mask");
            else
                $display("  mask check: frame[42]=%02h vs mask[7:0]=%02h", rx_frame[42], mask[7:0]);
        end
        $finish;
    end
    initial begin #50_000_000; $display("TIMEOUT rc=%0d locked=%b sfd=%b",rc,rx_locked,rx_sfd); $finish; end
endmodule
