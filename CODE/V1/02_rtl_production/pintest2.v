// 54/55/56 當「輸入」能不能用？
module pintest2 (input wire clk, input wire [2:0] i, output reg o);
  always @(posedge clk) o <= ^i;
endmodule
