`timescale 1ns / 1ps
// ============================================================
// pixel_tick_gen.v
// Divides 100 MHz system clock by 4 to produce a 25 MHz
// pixel-enable tick (high for exactly 1 cycle out of every 4).
// ============================================================
module pixel_tick_gen (
    input  wire clk,
    output wire pixel_tick
);
    reg [1:0] cnt = 2'd0;
    always @(posedge clk) cnt <= cnt + 2'd1;
    assign pixel_tick = (cnt == 2'd0);
endmodule