`timescale 1ns/1ps
module tb_pack_manch;
    reg clk=0, rst_n=0, pack_start=0;
    reg [287:0] dog_flat; reg [17:0] mask; reg [17:0] dead;
    reg [31:0] timestamp; reg [7:0] status;
    // packer -> TX buffer wires
    wire pk_wr_en; wire [5:0] pk_wr_addr; wire [7:0] pk_wr_data;
    wire [6:0] pk_len; wire pk_fstart, pk_done;
    // manchester
    wire data_line, tx_active, frame_done;
    wire [7:0] rx_byte; wire rx_valid, locked, sfd_seen;
    always #5 clk=~clk;

    frame_packer u_pk(.clk(clk),.rst_n(rst_n),.pack_start(pack_start),
        .dog_flat(dog_flat),.mask(mask),.dead(dead),.timestamp(timestamp),.status(status),
        .wr_en(pk_wr_en),.wr_addr(pk_wr_addr),.wr_data(pk_wr_data),
        .payload_len(pk_len),.frame_start_out(pk_fstart),.done(pk_done));

    manchester_tx #(.HALF_CLKS(8),.PREAMBLE_LEN(4)) u_tx(.clk(clk),.rst_n(rst_n),
        .wr_en(pk_wr_en),.wr_addr(pk_wr_addr),.wr_data(pk_wr_data),.payload_len(pk_len),
        .frame_start(pk_fstart),.data_line(data_line),.tx_active(tx_active),.frame_done(frame_done));

    manchester_rx #(.HALF_CLKS(8)) u_rx(.clk(clk),.rst_n(rst_n),.data_line(data_line),
        .rx_enable(1'b1),.rx_byte(rx_byte),.rx_valid(rx_valid),.locked(locked),.sfd_seen(sfd_seen));

    // reference frame (recompute in tb) + capture rx
    reg [7:0] expected [0:50];
    reg [7:0] got [0:50];
    integer rc, i, errors;

    // build expected frame the same way + CRC
    task build_expected;
        integer d, j; reg [15:0] crc; reg [7:0] v;
        begin
            expected[0]=8'hAA; expected[1]=8'h55;
            expected[2]=timestamp[31:24]; expected[3]=timestamp[23:16];
            expected[4]=timestamp[15:8]; expected[5]=timestamp[7:0];
            for(d=0;d<18;d=d+1) begin
                expected[6+d*2]   = dog_flat[d*16+8 +: 8];
                expected[6+d*2+1] = dog_flat[d*16 +: 8];
            end
            expected[42]=mask[7:0]; expected[43]=mask[15:8]; expected[44]={6'b0,mask[17:16]};
            expected[45]=dead[7:0]; expected[46]=dead[15:8]; expected[47]={6'b0,dead[17:16]};
            expected[48]=status;
            crc=16'hFFFF;
            for(j=0;j<49;j=j+1) begin
                crc=crc^{expected[j],8'h00};
                for(d=0;d<8;d=d+1) crc=crc[15]?((crc<<1)^16'h1021):(crc<<1);
            end
            expected[49]=crc[15:8]; expected[50]=crc[7:0];
        end
    endtask

    always @(posedge clk) if(rx_valid && rc<51) begin got[rc]=rx_byte; rc=rc+1; end

    initial begin
        for(i=0;i<18;i=i+1) dog_flat[i*16 +: 16] = {i[7:0], 8'hF0|i[3:0]};
        mask=18'h2_03FF; dead=18'h0_0005; timestamp=32'h1234_5678; status=8'h01;
        pack_start=0; rst_n=0; rc=0; errors=0; #20; rst_n=1; #20;
        build_expected;
        $display("=== END-TO-END: packer -> Manchester -> decode ===");
        @(posedge clk); pack_start<=1; @(posedge clk); pack_start<=0;
        wait(frame_done); #3000;
        $display("received %0d bytes", rc);
        for(i=0;i<51;i=i+1) if(expected[i]!==got[i]) begin
            errors=errors+1;
            if(errors<=8) $display("  MISMATCH [%0d]: exp=%02h got=%02h", i, expected[i], got[i]);
        end
        $display("CRC: exp=[%02h %02h] got=[%02h %02h]", expected[49],expected[50],got[49],got[50]);
        if(errors==0) $display("PASS: full 51-byte frame survived packer+CRC+Manchester end-to-end");
        else $display("FAIL: %0d errors", errors);
        $finish;
    end
    initial begin #500000; $display("TIMEOUT rc=%0d",rc); $finish; end
endmodule
