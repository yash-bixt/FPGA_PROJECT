`timescale 1ns / 1ps
// ============================================================
// btn_debounce.v
// Debounces a mechanical button and produces a single 1-cycle
// high pulse on the rising edge of the debounced output.
// Uses a 20-bit counter (~10ms at 100MHz) as settle timer.
// ============================================================
module btn_debounce (
    input  wire clk,
    input  wire btn_raw,
    output wire btn_pulse   // 1-cycle high on each confirmed press
);
    reg [19:0] cnt  = 0;
    reg        sync0 = 0, sync1 = 0;  // two-stage synchroniser
    reg        state = 0, prev = 0;

    // Synchronise async button input to clk domain
    always @(posedge clk) begin
        sync0 <= btn_raw;
        sync1 <= sync0;
    end

    // Debounce: only change state after input stable for ~10ms
    always @(posedge clk) begin
        if (sync1 != state) begin
            cnt <= cnt + 20'd1;
            if (cnt == 20'hFFFFF) begin   // ~10ms at 100MHz
                state <= sync1;
                cnt   <= 20'd0;
            end
        end else begin
            cnt <= 20'd0;
        end
        prev <= state;
    end

    // Pulse on rising edge of debounced state
    assign btn_pulse = state & ~prev;
endmodule