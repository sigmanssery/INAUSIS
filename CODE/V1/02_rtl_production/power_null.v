`timescale 1ns/1ps
//=============================================================================
// power_null.v -- power baseline for the differential measurement.
//
// WHAT IT IS FOR.  The FPGA core figure the paper quotes (38.3 mW) is a
// post-route estimate and cannot be measured directly: the Tang Nano's
// regulators feed the FPGA, the FT2232, the oscillator and the LEDs from one
// USB rail.  The DIFFERENCE between two bitstreams can be measured, though,
// and that difference is the useful half: 26.4 mW of the 38.3 is static
// leakage, present in any bitstream, so what a differential isolates is the
// 11.9 mW of dynamic power -- the term the paper says is the one that scales
// with the design and the one relevant to ASIC integration.
//
// WHY NOT led_id.  Its six LEDs blink, and six LEDs at a few mA each is
// 20-25 mW at the USB -- the same size as the signal being looked for.  Here
// every LED is held OFF (they are active low, so driven high).
//
// WHY A COUNTER AT ALL.  With nothing clocked the tool removes the clock tree,
// and the baseline would then exclude a cost the real design pays for reasons
// that have nothing to do with its logic.  One 27-bit counter keeps the global
// clock distributed while adding almost no fabric activity.
//=============================================================================
module power_null (
    input  wire clk27,
    output wire [5:0] led        // {16,15,14,13,11,10}, active low -- all off
);
    // syn_keep, not a fake data dependency: anything of the form (1'b1 | x) is
    // a constant and the synthesiser folds it, taking the counter and the clock
    // tree with it -- which is exactly what this module exists to retain.
    (* syn_keep = "true" *) reg [26:0] cnt = 27'd0;
    always @(posedge clk27) cnt <= cnt + 27'd1;

    assign led = 6'b111111;      // active low: all six off
endmodule
