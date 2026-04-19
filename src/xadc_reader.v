`timescale 1ns / 1ps
// ============================================================
// xadc_reader.v
// Wraps xadc_wiz_0 (continuous sequencer mode, VAUX3 only).
// INIT_49=0x0008 -> only VAUX3 in sequence.
// INIT_42=0x0400 -> ADCCLK = 100MHz/4 = 25MHz.
// Sequencer fires EOC for internal channels too (temp, vccint,
// vccaux, cal). We gate on channel_out==0x13 to accept VAUX3 only.
// FSM: IDLE --(EOC && ch==0x13)--> DEN_PULSE --> WAIT_DRDY --> IDLE
// ============================================================
module xadc_reader (
    input  wire        clk,
    input  wire        rst,
    input  wire        vauxp3,
    input  wire        vauxn3,
    output reg  [11:0] sample,        // 12-bit result (MSB-justified bits[15:4])
    output reg         sample_valid,  // 1-cycle pulse per new sample
    output reg         sample_ready   // sticky: first sample received
);
    wire [15:0] do_out;
    wire        drdy_out, eoc_out, eos_out, ot_out;
    wire        busy_out, alarm_out;
    wire        vccaux_alarm, vccint_alarm, user_temp_alarm;
    wire [4:0]  channel_out;

    reg [6:0] daddr;
    reg       den;

    localparam VAUX3_CH   = 5'h13;
    localparam VAUX3_ADDR = 7'h13;
    localparam S_IDLE = 2'd0, S_DEN = 2'd1, S_WAIT = 2'd2;
    reg [1:0] state;

    xadc_wiz_0 u_xadc (
        .daddr_in (daddr),   .dclk_in  (clk),
        .den_in   (den),     .di_in    (16'h0000),
        .dwe_in   (1'b0),    .reset_in (rst),
        .vauxp3   (vauxp3),  .vauxn3   (vauxn3),
        .vp_in    (1'b0),    .vn_in    (1'b0),
        .busy_out (busy_out),.channel_out(channel_out),
        .do_out   (do_out),  .drdy_out (drdy_out),
        .eoc_out  (eoc_out), .eos_out  (eos_out),
        .ot_out   (ot_out),
        .vccaux_alarm_out(vccaux_alarm),
        .vccint_alarm_out(vccint_alarm),
        .user_temp_alarm_out(user_temp_alarm),
        .alarm_out(alarm_out)
    );

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; daddr <= VAUX3_ADDR;
            den <= 0; sample <= 0; sample_valid <= 0; sample_ready <= 0;
        end else begin
            den          <= 1'b0;
            sample_valid <= 1'b0;
            case (state)
                S_IDLE: if (eoc_out && channel_out == VAUX3_CH) begin
                    daddr <= VAUX3_ADDR; den <= 1'b1; state <= S_WAIT;
                end
                S_WAIT: if (drdy_out) begin
                    sample       <= do_out[15:4];
                    sample_valid <= 1'b1;
                    sample_ready <= 1'b1;
                    state        <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule