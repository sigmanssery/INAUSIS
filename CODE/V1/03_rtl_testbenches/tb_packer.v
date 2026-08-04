`timescale 1ns/1ps
module tb_packer;
    reg clk=0, rst_n=0, pack_start=0;
    reg [287:0] dog_flat; reg [17:0] mask; reg [17:0] dead;
    reg [31:0] timestamp; reg [7:0] status;
    wire wr_en; wire [5:0] wr_addr; wire [7:0] wr_data; wire [6:0] payload_len;
    wire frame_start_out, done;
    always #5 clk=~clk;
    frame_packer dut(.clk(clk),.rst_n(rst_n),.pack_start(pack_start),
        .dog_flat(dog_flat),.mask(mask),.dead(dead),.timestamp(timestamp),.status(status),
        .wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),.payload_len(payload_len),
        .frame_start_out(frame_start_out),.done(done));
    // capture what packer writes to buffer
    reg [7:0] buf_cap [0:50];
    always @(posedge clk) if(wr_en) buf_cap[wr_addr] <= wr_data;
    integer i;
    initial begin
        // set up test data: dim d -> value (d<<8 | 0xF0|d)
        for(i=0;i<18;i=i+1) dog_flat[i*16 +: 16] = {i[7:0], 8'hF0|i[3:0]};
        mask = 18'h2_03FF;   // some pattern: bits set
        dead = 18'h0_0005;   // dims 0 and 2 flagged dead
        timestamp = 32'h1234_5678;
        status = 8'h01;
        pack_start=0; rst_n=0; #20; rst_n=1; #20;
        @(posedge clk); pack_start<=1; @(posedge clk); pack_start<=0;
        wait(done); #20;
        $display("=== packed 51-byte frame ===");
        for(i=0;i<48;i=i+4)
            $display("  [%2d] %02h %02h %02h %02h", i, buf_cap[i],buf_cap[i+1],buf_cap[i+2],buf_cap[i+3]);
        $display("  [48] %02h %02h %02h", buf_cap[48],buf_cap[49],buf_cap[50]);
        $display("payload_len=%0d", payload_len);
        $display("mask bytes: [42]=%02h [43]=%02h [44]=%02h", buf_cap[42],buf_cap[43],buf_cap[44]);
        $display("dead bytes: [45]=%02h [46]=%02h [47]=%02h", buf_cap[45],buf_cap[46],buf_cap[47]);
        $display("status:     [48]=%02h", buf_cap[48]);
        $display("CRC bytes:  [49]=%02h [50]=%02h", buf_cap[49], buf_cap[50]);
        // dump bytes 0-48 for external CRC check
        $write("FRAME49:");
        for(i=0;i<49;i=i+1) $write("%02h", buf_cap[i]);
        $display("");
        $finish;
    end
    initial begin #5000; $finish; end
endmodule
