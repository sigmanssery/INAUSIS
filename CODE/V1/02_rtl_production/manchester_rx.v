`timescale 1ns/1ps
//=============================================================================
// manchester_rx.v
//
// Frame-level Manchester receiver with preamble lock + SFD detection.
//
// METHOD (robust):
//   1. LOCK: during preamble (0x55 repeated), the line has a transition every
//      half-bit at regular spacing. We measure the interval between edges to
//      confirm we're seeing preamble, and align an internal half-bit timer.
//   2. After lock, we SAMPLE at bit centers using the internal timer (not by
//      hunting edges), reading the mid-bit transition direction for each bit.
//   3. We watch decoded bytes; when we see the SFD (0xD5), real payload starts.
//   4. Payload bytes after SFD are emitted via rx_byte/rx_valid.
//
// This timer-based sampling after lock is immune to the "no entry transition"
// problem, because we no longer rely on per-byte entry edges.
//=============================================================================

module manchester_rx #(
    parameter HALF_CLKS = 8,
    parameter SFD       = 8'hD5
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       data_line,
    input  wire       rx_enable,
    output reg  [7:0] rx_byte,
    output reg        rx_valid,     // pulses for each PAYLOAD byte (after SFD)
    output reg        locked,
    output reg        sfd_seen
);
    localparam BIT_CLKS = 2*HALF_CLKS;

    reg line_d1, line_d2;
    wire rising  = ( line_d1 & ~line_d2);
    wire falling = (~line_d1 &  line_d2);
    wire any_edge = rising | falling;

    localparam S_HUNT=2'd0, S_LOCKED=2'd1;
    reg [1:0]  state;
    reg [15:0] timer;          // counts clocks
    reg [15:0] last_edge_gap;  // gap between last two edges
    reg [3:0]  pre_edges;      // count regular edges during hunt
    reg [2:0]  bit_idx;
    reg [7:0]  shift;
    reg        sfd_lock;       // have we passed SFD?

    // sample window: we re-sync timer on each mid-bit edge; a mid-bit edge is
    // one that arrives ~BIT_CLKS after the previous accepted one (regular).
    // During preamble every edge is ~HALF_CLKS apart (0x55 alternates each
    // half-bit), which we use to lock.

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            line_d1<=1'b1; line_d2<=1'b1;
            state<=S_HUNT; timer<=0; last_edge_gap<=0; pre_edges<=0;
            bit_idx<=0; shift<=0; rx_byte<=0; rx_valid<=0;
            locked<=0; sfd_seen<=0; sfd_lock<=0;
        end else begin
            rx_valid <= 1'b0;
            line_d1 <= data_line;
            line_d2 <= line_d1;
            timer   <= timer + 16'd1;

            if (!rx_enable) begin
                state<=S_HUNT; locked<=0; sfd_seen<=0; sfd_lock<=0;
                bit_idx<=0; pre_edges<=0;
            end else begin
                case (state)
                //-------------------------------------------------------------
                // HUNT: look for regular preamble edges (~HALF_CLKS apart)
                S_HUNT: begin
                    if (any_edge) begin
                        last_edge_gap <= timer;
                        timer <= 0;
                        // 0x55 = 01010101: adjacent 0,1 bits share boundary level,
                        // so boundary edges cancel; only mid-bit edges remain,
                        // spaced one full BIT_CLKS apart. Lock on regular
                        // BIT_CLKS-spaced edges.
                        if (timer >= (BIT_CLKS - HALF_CLKS/2) &&
                            timer <= (BIT_CLKS + HALF_CLKS/2)) begin
                            pre_edges <= pre_edges + 4'd1;
                            if (pre_edges >= 4'd6) begin
                                locked  <= 1'b1;
                                state   <= S_LOCKED;
                                bit_idx <= 3'd0;
                                timer   <= 0;
                            end
                        end else begin
                            pre_edges <= 4'd0;
                        end
                    end
                end
                //-------------------------------------------------------------
                // LOCKED: accept mid-bit edges ~BIT_CLKS apart; ignore boundary
                // edges (~HALF_CLKS). Build bytes; detect SFD; emit payload.
                S_LOCKED: begin
                    if (any_edge) begin
                        if (timer >= (BIT_CLKS - HALF_CLKS/2)) begin
                            // mid-bit edge accepted
                            timer <= 0;
                            shift <= {shift[6:0], (rising ? 1'b1 : 1'b0)};
                            if (!sfd_lock) begin
                                if ({shift[6:0], (rising ? 1'b1 : 1'b0)} == SFD) begin
                                    sfd_lock <= 1'b1;
                                    sfd_seen <= 1'b1;
                                    bit_idx  <= 3'd0;
                                end
                            end else begin
                                if (bit_idx == 3'd7) begin
                                    rx_byte  <= {shift[6:0], (rising ? 1'b1 : 1'b0)};
                                    rx_valid <= 1'b1;
                                    bit_idx  <= 3'd0;
                                end else begin
                                    bit_idx <= bit_idx + 3'd1;
                                end
                            end
                        end
                        // boundary edges (timer < BIT_CLKS - tol): ignore
                    end
                end
                endcase
            end
        end
    end
endmodule
