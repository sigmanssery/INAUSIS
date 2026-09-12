//=============================================================================
// ad5254_i2c -- minimal I2C master for the AD5254 quad 256-position digipot.
//
// WHY THIS EXISTS: the detection-floor numbers from 2026-08-30 (41 counts ->
// 100%, 27 -> 60%, 20 -> 0%) came from synth_press, whose smallest reachable
// increment is one count per sample.  That is a limit of the GENERATOR, not of
// the analogue chain, so the real floor was never measured.  Driving a digipot
// in place of the FSR puts a calibrated, sub-count step through the real ADS
// front end.  At the measured rest point (1612 counts = 1.933 MOhm) one AD5254
// LSB is 392 Ohm = 0.311 ADC counts, so the step is ~3x finer than one count.
//
// PROTOCOL -- read out of the AD5253/AD5254 data sheet (Rev. 0, 28 pp),
// Figure 27 "Single Write Mode" and Table 6.  Not from recall:
//
//   slave address byte : 0 1 0 1 1 AD1 AD0 R/W     (7-bit addr 0x2C..0x2F)
//   instruction byte   : CMD/REG EE/RDAC 0 A4 A3 A2 A1 A0
//                        CMD/REG=0 (register access), EE/RDAC=0 (RDAC), and
//                        Table 6 gives A4..A0 = 00000..00011 for RDAC0..RDAC3,
//                        so the instruction byte is just 8'h00 + channel.
//   data byte          : 8-bit wiper code (AD5254 = 256 positions)
//
//   S | addr+W | A | instr | A | data | A | P
//
// An RDAC write does not start an internal EEMEM cycle, so no acknowledge
// polling is needed (that is only for EEMEM writes and the Reset / Store
// quick commands).
//
// f_SCL max is 400 kHz per the data sheet; default here is 100 kHz because the
// part is reached over dupont wire.  SCL and SDA are both open-drain and the
// master honours clock stretching, so it stays protocol-correct even though
// this slave does not stretch.
//
// EXTERNAL PARTS REQUIRED: 4.7 kOhm pull-ups from SDA and SCL to 3V3.  The
// FPGA internal pull-up is ~50 kOhm, too weak for this wiring.
//=============================================================================
`default_nettype none

module ad5254_i2c #(
    parameter integer CLK_HZ = 27000000,
    parameter integer SCL_HZ = 100000        // <= 400000 per data sheet
)(
    input  wire       clk,
    input  wire       rst_n,
    input  wire       start,     // 1-cycle pulse, ignored while busy
    input  wire [1:0] dev,       // {AD1, AD0} strap of the target chip
    input  wire [1:0] chan,      // RDAC0..RDAC3
    input  wire [7:0] value,     // wiper code
    output reg        busy,
    output reg        ack_err,   // sticky per transaction: a byte was NACKed
    inout  wire       scl,
    inout  wire       sda
);
    // ---- open drain: pull low or release ------------------------------------
    reg  scl_oe, sda_oe;                     // 1 = pull the line low
    assign scl = scl_oe ? 1'b0 : 1'bz;
    assign sda = sda_oe ? 1'b0 : 1'bz;
    wire scl_in = scl;
    wire sda_in = sda;

    // ---- quarter-bit timebase -----------------------------------------------
    localparam integer DIVI = (CLK_HZ / (4 * SCL_HZ)) < 1 ? 1 : (CLK_HZ / (4 * SCL_HZ));
    reg  [15:0] div_cnt;
    wire        tick4 = (div_cnt == DIVI[15:0] - 16'd1);

    // ---- state ---------------------------------------------------------------
    localparam S_IDLE  = 3'd0, S_START = 3'd1, S_BIT = 3'd2,
               S_ACK   = 3'd3, S_STOP  = 3'd4, S_DONE = 3'd5;
    reg [2:0] st;
    reg [1:0] ph;          // quarter phase inside the current bit
    reg [2:0] bit_i;       // 7..0
    reg [1:0] byte_i;      // 0 = address, 1 = instruction, 2 = data
    reg [7:0] shreg, b_instr, b_data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_cnt <= 16'd0; st <= S_IDLE; ph <= 2'd0; bit_i <= 3'd7;
            byte_i  <= 2'd0;  shreg <= 8'd0; b_instr <= 8'd0; b_data <= 8'd0;
            scl_oe  <= 1'b0;  sda_oe <= 1'b0;
            busy    <= 1'b0;  ack_err <= 1'b0;
        end else begin
            div_cnt <= tick4 ? 16'd0 : div_cnt + 16'd1;

            if (st == S_IDLE) begin
                scl_oe <= 1'b0; sda_oe <= 1'b0; busy <= 1'b0;
                if (start) begin
                    shreg   <= {4'b0101, 1'b1, dev, 1'b0};       // addr + W
                    b_instr <= {6'b000000, chan};                // CMD/REG=0,EE/RDAC=0
                    b_data  <= value;
                    byte_i  <= 2'd0; bit_i <= 3'd7; ph <= 2'd0;
                    busy    <= 1'b1; ack_err <= 1'b0;
                    st      <= S_START; div_cnt <= 16'd0;
                end
            end else if (tick4) begin
                // clock-stretch guard: we released SCL but the line is still
                // low, so hold this phase until the slave lets go.
                if (ph == 2'd1 && !scl_oe && !scl_in) begin
                    ph <= ph;
                end else begin
                    ph <= ph + 2'd1;
                    case (st)
                    // START: SDA falls while SCL is high, then SCL goes low.
                    S_START: case (ph)
                        2'd0: begin sda_oe <= 1'b0; scl_oe <= 1'b0; end
                        2'd1: begin sda_oe <= 1'b1;                 end
                        2'd2: begin                                 end
                        2'd3: begin scl_oe <= 1'b1; st <= S_BIT;    end
                    endcase
                    // one data bit, MSB first
                    S_BIT: case (ph)
                        2'd0: begin sda_oe <= ~shreg[7]; scl_oe <= 1'b1; end
                        2'd1: begin scl_oe <= 1'b0;                      end
                        2'd2: begin                                      end
                        2'd3: begin
                                  scl_oe <= 1'b1;
                                  shreg  <= {shreg[6:0], 1'b0};
                                  if (bit_i == 3'd0) st    <= S_ACK;
                                  else               bit_i <= bit_i - 3'd1;
                              end
                    endcase
                    // ACK: release SDA, clock once, sample while SCL is high.
                    S_ACK: case (ph)
                        2'd0: begin sda_oe <= 1'b0; scl_oe <= 1'b1; end
                        2'd1: begin scl_oe <= 1'b0;                 end
                        2'd2: begin if (sda_in) ack_err <= 1'b1;    end  // 1 = NACK
                        2'd3: begin
                                  scl_oe <= 1'b1;
                                  bit_i  <= 3'd7;
                                  if (byte_i == 2'd2) begin
                                      st <= S_STOP;
                                  end else begin
                                      byte_i <= byte_i + 2'd1;
                                      shreg  <= (byte_i == 2'd0) ? b_instr : b_data;
                                      st     <= S_BIT;
                                  end
                              end
                    endcase
                    // STOP: SDA rises while SCL is high.
                    S_STOP: case (ph)
                        2'd0: begin sda_oe <= 1'b1; scl_oe <= 1'b1; end
                        2'd1: begin scl_oe <= 1'b0;                 end
                        2'd2: begin sda_oe <= 1'b0;                 end
                        2'd3: begin st <= S_DONE;                   end
                    endcase
                    S_DONE: begin busy <= 1'b0; st <= S_IDLE; end
                    default: st <= S_IDLE;
                    endcase
                end
            end
        end
    end
endmodule

`default_nettype wire
