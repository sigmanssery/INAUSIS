`timescale 1ns/1ps
//=============================================================================
// tb_rev_crc.v
//
// Unit test for lut_parser's CRC-gated apply. Drives the parser with the
// payload stream halfduplex_ctrl would deliver (LENGTH + entries; CRC bytes
// are NOT forwarded), then pulses rev_frame_done with rev_crc_ok asserted or
// deasserted, and checks:
//   - good frame (rev_crc_ok=1) -> all entries written to the flag engine
//   - bad  frame (rev_crc_ok=0) -> NO writes (whole frame discarded)
// No Manchester / .mem needed -- fast, EDA-Playground friendly.
//=============================================================================
module tb_rev_crc;
    reg clk=0, rst_n=0;
    reg [7:0] rev_byte; reg rev_valid, rev_frame_done, rev_crc_ok;
    wire lut_wr; wire [4:0] lut_dim; wire [31:0] lut_thr;
    always #5 clk=~clk;

    lut_parser dut(.clk(clk),.rst_n(rst_n),.rev_byte(rev_byte),.rev_valid(rev_valid),
        .rev_frame_done(rev_frame_done),.rev_crc_ok(rev_crc_ok),
        .lut_wr(lut_wr),.lut_dim(lut_dim),.lut_thr(lut_thr));

    integer nwr; reg [4:0] last_dim; reg [31:0] last_thr;
    always @(posedge clk) if(lut_wr) begin
        nwr=nwr+1; last_dim=lut_dim; last_thr=lut_thr;
        $display("    lut_wr dim=%0d thr=%08h", lut_dim, lut_thr);
    end

    task send_byte(input [7:0] b);
    begin @(posedge clk); rev_byte<=b; rev_valid<=1'b1; @(posedge clk); rev_valid<=1'b0; @(posedge clk); end
    endtask

    // LENGTH=10 + 2 five-byte entries (dim2=0x00001234, dim5=0x0000ABCD);
    // then frame_done w/ crc flag
    task send_frame(input crc_ok);
    begin
        send_byte(8'd10);
        send_byte(8'd2); send_byte(8'h00); send_byte(8'h00); send_byte(8'h12); send_byte(8'h34);
        send_byte(8'd5); send_byte(8'h00); send_byte(8'h00); send_byte(8'hAB); send_byte(8'hCD);
        @(posedge clk); rev_crc_ok<=crc_ok; rev_frame_done<=1'b1;
        @(posedge clk); rev_frame_done<=1'b0;
        repeat(12) @(posedge clk);
    end
    endtask

    initial begin
        rev_byte=0; rev_valid=0; rev_frame_done=0; rev_crc_ok=0; nwr=0;
        rst_n=0; #50; rst_n=1; #20;

        $display("=== reverse-CRC gating ===");
        $display("-- GOOD frame (rev_crc_ok=1) --");
        send_frame(1'b1);
        $display("  writes=%0d (expect 2); last dim=%0d thr=%08h (expect 5 / 0000ABCD)", nwr,last_dim,last_thr);
        if(nwr==2 && last_dim==5'd5 && last_thr==32'h0000_ABCD)
             $display("  PASS: valid frame applied both entries");
        else $display("  FAIL");

        nwr=0;
        $display("-- BAD frame (rev_crc_ok=0) --");
        send_frame(1'b0);
        $display("  writes=%0d (expect 0)", nwr);
        if(nwr==0) $display("  PASS: bad-CRC frame rejected, no thresholds written");
        else       $display("  FAIL: %0d writes leaked from a bad-CRC frame", nwr);

        $finish;
    end
    initial begin #200000; $display("TIMEOUT"); $finish; end
endmodule
