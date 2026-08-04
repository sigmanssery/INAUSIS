//=============================================================================
// tb_dog_multi.v - verify dog_fir_multi
//   Test 1: feed the step input to channel 0; outputs must match the
//           single-channel reference (n=50: G1=332 G2=95 G3=9 DoGf=237 DoGs=86)
//   Test 2: feed DIFFERENT constants to 6 channels; verify no cross-talk
//=============================================================================
`timescale 1ns/1ps

module tb_dog_multi;
    reg clk=0, rst_n=0;
    reg [2:0] ch_id;
    reg signed [15:0] sample_in;
    reg sample_valid;
    wire [2:0] ch_done;
    wire signed [15:0] G_s1,G_s2,G_s3,DoG_fast,DoG_slow;
    wire result_valid, busy;

    always #5 clk=~clk;

    dog_fir_multi dut(
        .clk(clk),.rst_n(rst_n),
        .ch_id(ch_id),.sample_in(sample_in),.sample_valid(sample_valid),
        .ch_done(ch_done),.G_s1(G_s1),.G_s2(G_s2),.G_s3(G_s3),
        .DoG_fast(DoG_fast),.DoG_slow(DoG_slow),
        .result_valid(result_valid),.busy(busy)
    );

    reg signed [15:0] step [0:399];
    initial $readmemh("test_input.mem", step);

    integer n;
    // capture ch0 results
    reg signed [15:0] c0_g1,c0_g2,c0_g3,c0_df,c0_ds;

    task feed_sample(input [2:0] ch, input signed [15:0] val);
    begin
        @(posedge clk); ch_id<=ch; sample_in<=val; sample_valid<=1;
        @(posedge clk); sample_valid<=0;
        wait(result_valid==1); @(posedge clk);
    end
    endtask

    initial begin
        ch_id=0; sample_in=0; sample_valid=0;
        rst_n=0; #100; rst_n=1; #50;

        // ---- Test 1: step input to channel 0 ----
        $display("=== Test 1: step to ch0 (expect n=50: G1=332 G2=95 G3=9 DoGf=237 DoGs=86) ===");
        for (n=0; n<400; n=n+1) begin
            feed_sample(3'd0, step[n]);
            if (n==50 || n==55 || n==100)
                $display("ch0 n=%0d: G1=%0d G2=%0d G3=%0d DoGf=%0d DoGs=%0d",
                         n, G_s1, G_s2, G_s3, DoG_fast, DoG_slow);
        end

        // ---- Test 2: different constants to 6 channels, check independence ----
        $display("\n=== Test 2: cross-talk check (6 channels, different constants) ===");
        $display("feed ch=value: ch0=100 ch1=200 ch2=300 ch3=400 ch4=500 ch5=600");
        // feed each channel its constant 300 times so G_s3 settles
        for (n=0; n<300; n=n+1) begin
            feed_sample(3'd0, 16'sd100);
            feed_sample(3'd1, 16'sd200);
            feed_sample(3'd2, 16'sd300);
            feed_sample(3'd3, 16'sd400);
            feed_sample(3'd4, 16'sd500);
            feed_sample(3'd5, 16'sd600);
        end
        // now read each channel's settled G_s3 (should equal its constant, DoG=0)
        $display("after settling, each channel G_s3 should = its constant, DoG~0:");
        feed_sample(3'd0, 16'sd100); $display("  ch0: G_s3=%0d DoGf=%0d DoGs=%0d (expect ~100, 0, 0)", G_s3, DoG_fast, DoG_slow);
        feed_sample(3'd1, 16'sd200); $display("  ch1: G_s3=%0d DoGf=%0d DoGs=%0d (expect ~200, 0, 0)", G_s3, DoG_fast, DoG_slow);
        feed_sample(3'd5, 16'sd600); $display("  ch5: G_s3=%0d DoGf=%0d DoGs=%0d (expect ~600, 0, 0)", G_s3, DoG_fast, DoG_slow);

        $display("\n=== done ===");
        $finish;
    end
    initial begin #50_000_000; $display("TIMEOUT"); $finish; end
endmodule
