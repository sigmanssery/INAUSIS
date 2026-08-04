`timescale 1ns/1ps
module tb_manch_48;
    reg clk=0, rst_n=0;
    reg wr_en; reg [5:0] wr_addr; reg [7:0] wr_data; reg [6:0] payload_len;
    reg frame_start;
    wire data_line, tx_active, frame_done;
    wire [7:0] rx_byte; wire rx_valid, locked, sfd_seen;
    always #5 clk=~clk;

    manchester_tx #(.HALF_CLKS(8),.PREAMBLE_LEN(4)) tx(
        .clk(clk),.rst_n(rst_n),.wr_en(wr_en),.wr_addr(wr_addr),.wr_data(wr_data),
        .payload_len(payload_len),.frame_start(frame_start),.data_line(data_line),
        .tx_active(tx_active),.frame_done(frame_done));
    manchester_rx #(.HALF_CLKS(8)) rx(
        .clk(clk),.rst_n(rst_n),.data_line(data_line),.rx_enable(1'b1),
        .rx_byte(rx_byte),.rx_valid(rx_valid),.locked(locked),.sfd_seen(sfd_seen));

    // 48-byte test frame: realistic structure with verifiable pattern
    reg [7:0] frame [0:47];
    reg [7:0] got [0:47];
    integer rc, i, errors;
    initial begin
        // byte 0-1: preamble marker (inside payload, distinct from manch preamble)
        frame[0]=8'hAA; frame[1]=8'h55;
        // byte 2-5: timestamp (incrementing)
        frame[2]=8'h12; frame[3]=8'h34; frame[4]=8'h56; frame[5]=8'h78;
        // byte 6-41: 18-dim data, 2 bytes each (use dim index pattern)
        for(i=0;i<18;i=i+1) begin
            frame[6+i*2]   = i[7:0];          // high byte = dim index
            frame[6+i*2+1] = 8'hF0 | i[3:0];  // low byte = marker+index
        end
        // byte 42-44: 18-bit mask (3 bytes)
        frame[42]=8'hFF; frame[43]=8'h03; frame[44]=8'h00;
        // byte 45: status
        frame[45]=8'h5A;
        // byte 46-47: CRC placeholder
        frame[46]=8'hDE; frame[47]=8'hAD;
    end

    always @(posedge clk) if(rx_valid && rc<48) begin
        got[rc]=rx_byte; rc=rc+1;
    end

    initial begin
        wr_en=0;wr_addr=0;wr_data=0;payload_len=0;frame_start=0;rc=0;errors=0;
        rst_n=0;#50;rst_n=1;#50;
        $display("=== Manchester 48-byte frame test ===");
        // load 48 bytes into TX buffer
        for(i=0;i<48;i=i+1) begin
            @(posedge clk); wr_en<=1; wr_addr<=i[5:0]; wr_data<=frame[i];
        end
        @(posedge clk); wr_en<=0; payload_len<=7'd48;
        @(posedge clk); frame_start<=1; @(posedge clk); frame_start<=0;
        wait(frame_done); #3000;
        // verify all 48
        $display("received %0d bytes", rc);
        for(i=0;i<48;i=i+1) begin
            if(frame[i] !== got[i]) begin
                errors=errors+1;
                if(errors<=10) $display("  MISMATCH byte %0d: sent=%02h recv=%02h", i, frame[i], got[i]);
            end
        end
        if(errors==0) $display("PASS: all 48 bytes correct, phase stable over full frame");
        else $display("FAIL: %0d/48 bytes wrong", errors);
        $finish;
    end
    initial begin #500000; $display("TIMEOUT (rc=%0d)", rc); $finish; end
endmodule
