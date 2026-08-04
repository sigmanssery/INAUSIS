`timescale 1ns/1ps
//=============================================================================
// lut_parser.v
//
// Parses the reverse-channel LUT-update frame (from the SoC, via the
// half-duplex controller) into threshold writes for zscore_flag_multi.
//
// Reverse frame payload (as delivered by halfduplex_ctrl on rev_byte/rev_valid):
//   [LENGTH][entry0][entry1]...[entryN-1]
//   each entry = [dim_id][thr_b3][thr_b2][thr_b1][thr_b0]  (5 bytes, big-endian)
//   thr is a 32-bit value in the squared-comparison domain (cmp_val^2), so the
//   SoC can set thresholds across the full calibrated range (a 16-bit threshold
//   could not reach the calibrated scale, ~2^34, and left the reverse-channel
//   tuning effectively non-functional).
//   LENGTH = number of entry bytes (= 5 * num_entries).
// The trailing 2 CRC bytes are consumed/validated by halfduplex_ctrl and are
// NOT forwarded here; halfduplex_ctrl pulses rev_frame_done with rev_crc_ok.
//
// CRC-GATED APPLY (safety): entries are collected into an internal buffer as
// they stream in, but NO threshold write is emitted until the frame completes
// AND its CRC is validated (rev_crc_ok). On rev_frame_done:
//   - rev_crc_ok=1 and no overflow -> replay the buffered entries as lut_wr
//     pulses (one per cycle) to the flag engine.
//   - rev_crc_ok=0 (or too many entries) -> discard the whole frame, no writes.
//=============================================================================

module lut_parser #(
    parameter DIM_BITS    = 5,
    parameter MAX_ENTRIES = 18      // one per dimension; frames with more are rejected
)(
    input  wire        clk,
    input  wire        rst_n,
    // from half-duplex controller (reverse channel)
    input  wire [7:0]  rev_byte,
    input  wire        rev_valid,
    input  wire        rev_frame_done,
    input  wire        rev_crc_ok,     // valid with rev_frame_done (CRC matched)
    // to flag engine
    output reg                  lut_wr,
    output reg  [DIM_BITS-1:0]  lut_dim,
    output reg  [31:0]          lut_thr
);
    localparam P_LEN=3'd0, P_DIM=3'd1, P_B3=3'd2, P_B2=3'd3, P_B1=3'd4, P_B0=3'd5;
    reg [2:0]  pstate;
    reg [7:0]  length;
    reg [7:0]  rxcnt;        // entry bytes consumed
    reg [7:0]  e_dim;
    reg [7:0]  e_b3, e_b2, e_b1;

    // entry staging buffer (applied only after CRC validation)
    reg [DIM_BITS-1:0] buf_dim [0:MAX_ENTRIES-1];
    reg [31:0]         buf_thr [0:MAX_ENTRIES-1];
    reg [5:0]          n_ent;
    reg                overflow;
    reg                applying;
    reg [5:0]          apply_idx;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pstate<=P_LEN; length<=0; rxcnt<=0; e_dim<=0; e_b3<=0; e_b2<=0; e_b1<=0;
            n_ent<=0; overflow<=0; applying<=0; apply_idx<=0;
            lut_wr<=0; lut_dim<=0; lut_thr<=0;
        end else begin
            lut_wr <= 1'b0;

            if (applying) begin
                // replay validated entries: one lut_wr pulse per cycle
                if (apply_idx < n_ent) begin
                    lut_dim   <= buf_dim[apply_idx];
                    lut_thr   <= buf_thr[apply_idx];
                    lut_wr    <= 1'b1;
                    apply_idx <= apply_idx + 6'd1;
                end else begin
                    applying <= 1'b0;
                end
            end else if (rev_frame_done) begin
                // commit the whole frame's entries iff CRC valid and not overflowed.
                if (rev_crc_ok && !overflow && n_ent != 6'd0) begin
                    applying  <= 1'b1;
                    apply_idx <= 6'd0;
                end
                pstate <= P_LEN;
                rxcnt  <= 8'd0;
            end else if (rev_valid) begin
                case (pstate)
                P_LEN: begin
                    length   <= rev_byte;     // number of entry bytes
                    rxcnt    <= 8'd0;
                    n_ent    <= 6'd0;
                    overflow <= 1'b0;
                    pstate   <= P_DIM;
                end
                P_DIM: begin e_dim<=rev_byte; rxcnt<=rxcnt+8'd1; pstate<=P_B3; end
                P_B3:  begin e_b3 <=rev_byte; rxcnt<=rxcnt+8'd1; pstate<=P_B2; end
                P_B2:  begin e_b2 <=rev_byte; rxcnt<=rxcnt+8'd1; pstate<=P_B1; end
                P_B1:  begin e_b1 <=rev_byte; rxcnt<=rxcnt+8'd1; pstate<=P_B0; end
                P_B0:  begin
                    // complete entry -> stage in buffer (do NOT write yet)
                    if (n_ent < MAX_ENTRIES) begin
                        buf_dim[n_ent] <= e_dim[DIM_BITS-1:0];
                        buf_thr[n_ent] <= {e_b3, e_b2, e_b1, rev_byte};
                        n_ent          <= n_ent + 6'd1;
                    end else begin
                        overflow <= 1'b1;     // frame too large -> will be rejected
                    end
                    rxcnt <= rxcnt + 8'd1;
                    if (rxcnt + 8'd1 < length) pstate <= P_DIM;
                    else                       pstate <= P_LEN;  // entries done
                end
                endcase
            end
        end
    end
endmodule
