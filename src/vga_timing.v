`timescale 1ns / 1ps
// ============================================================
// vga_timing.v
// Standard 640x480 @ 60 Hz VGA timing.
// Outputs pixel coordinates (x,y), blanking (video_on),
// and sync pulses. Also provides vsync_pulse (1-cycle high
// at the very start of each vertical sync) for frame timing.
// ============================================================
module vga_timing (
    input  wire       clk,
    input  wire       pixel_tick,
    output wire       hsync,
    output wire       vsync,
    output wire       video_on,
    output wire [9:0] x,
    output wire [9:0] y,
    output wire       vsync_pulse    // 1-cycle high at start of vsync
);
    localparam H_VIS = 640, H_FP = 16,  H_SYN = 96,  H_BP = 48;
    localparam V_VIS = 480, V_FP = 10,  V_SYN = 2,   V_BP = 33;
    localparam H_TOT = H_VIS + H_FP + H_SYN + H_BP;  // 800
    localparam V_TOT = V_VIS + V_FP + V_SYN + V_BP;  // 525

    reg [9:0] hc = 0, vc = 0;

    always @(posedge clk) begin
        if (pixel_tick) begin
            if (hc == H_TOT-1) begin
                hc <= 0;
                vc <= (vc == V_TOT-1) ? 0 : vc + 1;
            end else hc <= hc + 1;
        end
    end

    assign hsync     = ~((hc >= H_VIS+H_FP) && (hc < H_VIS+H_FP+H_SYN));
    assign vsync     = ~((vc >= V_VIS+V_FP) && (vc < V_VIS+V_FP+V_SYN));
    assign video_on  = (hc < H_VIS) && (vc < V_VIS);
    assign x         = hc;
    assign y         = vc;

    // One-cycle pulse at the very first pixel of vsync
    reg vsync_d;
    always @(posedge clk) vsync_d <= vsync;
    assign vsync_pulse = vsync_d & ~vsync;  // falling edge of active-low vsync
endmodule