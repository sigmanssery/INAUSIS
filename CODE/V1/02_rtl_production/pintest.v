// pintest.v — every 3.3 V package pin driven, to see which the tool refuses
module pintest (input wire clk, output wire [46:0] o);
  reg [46:0] r;
  always @(posedge clk) r <= {r[45:0], ~r[46]};
  assign o = r;
endmodule
