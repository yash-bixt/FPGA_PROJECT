`timescale 1ns / 1ps
// ============================================================
// dso_core.v  -  Generic DSO acquisition engine v3
//
// Voltage scaling fully runtime-configurable via slide switches:
//   SW[3:0]  = V_SCALE  (input full-scale selection)
//   SW[7:4]  = V_OFFSET (DC offset in 256-code steps)
//
// SW[3:0] -> ADC full-scale code -> Input voltage (XADC 1V ref):
//   0000 -> 4095 -> 1.000V
//   0001 -> 3686 -> 0.900V
//   0010 -> 3072 -> 0.750V
//   0011 -> 2458 -> 0.600V
//   0100 -> 2048 -> 0.500V
//   0101 -> 1843 -> 0.450V  (100k/10k divider + 5V source)
//   0110 -> 1434 -> 0.350V
//   0111 -> 1229 -> 0.300V
//   1000 -> 1024 -> 0.250V
//   1001 ->  819 -> 0.200V
//   1010 ->  614 -> 0.150V
//   1011 ->  410 -> 0.100V
//   others -> 4095 (safe default)
//
// SW[7:4] -> Offset = sw_voffset * 256 codes
//   0000 = 0V offset, 1111 = 3840 codes (~0.937V) offset
//
// Bugs fixed vs v1:
//   1. Pre-trigger copy gated by decim_tick
//   2. map_y uses runtime v_scale_code / v_offset_code
//   3. Pixel area leaves room for voltage labels (Y 30..449)
// ============================================================
module dso_core (
    input  wire        clk,
    input  wire        rst,

    input  wire [11:0] adc_sample,
    input  wire        adc_valid,

    // Switch-based voltage config
    input  wire [3:0]  sw_vscale,
    input  wire [3:0]  sw_voffset,

    // Buttons (1-cycle pulses from debouncer)
    input  wire        btn_tb_up,
    input  wire        btn_tb_dn,
    input  wire        btn_trig_up,
    input  wire        btn_trig_dn,
    input  wire        btn_trig_edge,

    // Display read port
    input  wire [9:0]  read_x,
    output reg  [8:0]  wave_y,
    output reg  [8:0]  wave_y_prev,

    // OSD status
    output reg  [2:0]  timebase,
    output reg  [11:0] trig_level,
    output reg         trig_edge,
    output reg  [1:0]  acq_state,
    output reg         triggered,
    output reg         sample_ready,

    // Voltage config for OSD labels
    output reg  [11:0] v_scale_code,
    output reg  [11:0] v_offset_code
);
    // Waveform pixel rows (leaves top 20px for status, bottom 20px for labels)
    localparam Y_BOT  = 9'd449;
    localparam Y_TOP  = 9'd30;
    localparam Y_MID  = 9'd239;
    localparam Y_RNG  = 9'd419;

    localparam PRE_TRIG     = 10'd80;
    localparam BUF_SIZE     = 10'd640;
    localparam AUTO_TIMEOUT = 20'd200000;

    localparam S_ARMED   = 2'd0;
    localparam S_CAPTURE = 2'd1;
    localparam S_SWAP    = 2'd2;

    // ----------------------------------------------------------------
    // V_SCALE / V_OFFSET decode (registered, updates every cycle)
    // ----------------------------------------------------------------
    always @(posedge clk) begin
        case (sw_vscale)
            4'h0: v_scale_code <= 12'd4095;
            4'h1: v_scale_code <= 12'd3686;
            4'h2: v_scale_code <= 12'd3072;
            4'h3: v_scale_code <= 12'd2458;
            4'h4: v_scale_code <= 12'd2048;
            4'h5: v_scale_code <= 12'd1843;
            4'h6: v_scale_code <= 12'd1434;
            4'h7: v_scale_code <= 12'd1229;
            4'h8: v_scale_code <= 12'd1024;
            4'h9: v_scale_code <= 12'd819;
            4'hA: v_scale_code <= 12'd614;
            4'hB: v_scale_code <= 12'd410;
            default: v_scale_code <= 12'd4095;
        endcase
        v_offset_code <= {sw_voffset, 8'h00}; // * 256
    end

    // ----------------------------------------------------------------
    // Decimation
    // ----------------------------------------------------------------
    reg [7:0] decim_cnt;
    reg [7:0] decim_max;
    always @(*) begin
        case (timebase)
            3'd0: decim_max = 8'd1;
            3'd1: decim_max = 8'd2;
            3'd2: decim_max = 8'd5;
            3'd3: decim_max = 8'd10;
            3'd4: decim_max = 8'd20;
            3'd5: decim_max = 8'd50;
            3'd6: decim_max = 8'd100;
            3'd7: decim_max = 8'd200;
            default: decim_max = 8'd1;
        endcase
    end
    wire decim_tick = (decim_cnt == 8'd0);

    // ----------------------------------------------------------------
    // Buffers
    // ----------------------------------------------------------------
    reg [8:0] pretrig_buf [0:79];
    reg [6:0] pt_wr;
    reg [8:0] buf0 [0:639];
    reg [8:0] buf1 [0:639];
    reg       front_sel;

    reg [1:0]  state;
    reg [9:0]  cap_cnt;
    reg [19:0] auto_cnt;
    reg [11:0] prev_sample;

    // ----------------------------------------------------------------
    // map_y: generic, uses runtime v_scale_code / v_offset_code
    // ----------------------------------------------------------------
    function [8:0] map_y;
        input [11:0] s;
        reg   [12:0] s_off;
        reg   [11:0] s_clamp;
        reg   [22:0] prod;
        reg   [8:0]  res;
        begin
            // Subtract DC offset (clamp to 0)
            if (s > v_offset_code)
                s_off = {1'b0, s} - {1'b0, v_offset_code};
            else
                s_off = 13'd0;

            // Clamp to full-scale range
            s_clamp = (s_off[11:0] >= v_scale_code) ? v_scale_code : s_off[11:0];

            // Scale to pixel row
            prod = s_clamp * Y_RNG;
            res  = Y_BOT - (prod / {11'd0, v_scale_code});

            // Pixel clamp
            if      (res < Y_TOP) map_y = Y_TOP;
            else if (res > Y_BOT) map_y = Y_BOT;
            else                  map_y = res;
        end
    endfunction

    // ----------------------------------------------------------------
    // Trigger
    // ----------------------------------------------------------------
    wire trig_rising  = (prev_sample <  trig_level) && (adc_sample >= trig_level);
    wire trig_falling = (prev_sample >  trig_level) && (adc_sample <= trig_level);
    wire trig_hit     = trig_edge ? trig_falling : trig_rising;

    // ----------------------------------------------------------------
    // Main FSM
    // ----------------------------------------------------------------
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state        <= S_ARMED;
            cap_cnt      <= 10'd0;
            auto_cnt     <= 20'd0;
            decim_cnt    <= 8'd0;
            prev_sample  <= 12'd0;
            pt_wr        <= 7'd0;
            front_sel    <= 1'b0;
            timebase     <= 3'd2;
            trig_level   <= 12'd2048;
            trig_edge    <= 1'b0;
            triggered    <= 1'b0;
            sample_ready <= 1'b0;
            acq_state    <= S_ARMED;
            for (i = 0; i < 640; i = i+1) begin buf0[i] <= Y_MID; buf1[i] <= Y_MID; end
            for (i = 0; i < 80;  i = i+1) pretrig_buf[i] <= Y_MID;
        end else begin
            if (btn_tb_up   && timebase   < 3'd7)    timebase   <= timebase   + 3'd1;
            if (btn_tb_dn   && timebase   > 3'd0)    timebase   <= timebase   - 3'd1;
            if (btn_trig_up && trig_level <= 12'd3967) trig_level <= trig_level + 12'd128;
            if (btn_trig_dn && trig_level >= 12'd128)  trig_level <= trig_level - 12'd128;
            if (btn_trig_edge) trig_edge <= ~trig_edge;

            acq_state <= state;

            if (adc_valid) begin
                prev_sample <= adc_sample;
                decim_cnt   <= (decim_cnt >= decim_max - 8'd1) ? 8'd0 : decim_cnt + 8'd1;

                case (state)
                    S_ARMED: begin
                        auto_cnt <= auto_cnt + 20'd1;
                        if (decim_tick) begin
                            pretrig_buf[pt_wr] <= map_y(adc_sample);
                            pt_wr <= (pt_wr == 7'd79) ? 7'd0 : pt_wr + 7'd1;
                        end
                        if (trig_hit && decim_tick) begin
                            cap_cnt <= 10'd0; auto_cnt <= 20'd0;
                            triggered <= 1'b1; state <= S_CAPTURE;
                        end else if (auto_cnt >= AUTO_TIMEOUT) begin
                            cap_cnt <= 10'd0; auto_cnt <= 20'd0;
                            triggered <= 1'b0; state <= S_CAPTURE;
                        end
                    end

                    S_CAPTURE: begin
                        if (decim_tick) begin
                            if (cap_cnt < PRE_TRIG) begin
                                begin : pt_rd
                                    reg [6:0] idx;
                                    idx = pt_wr + cap_cnt[6:0];
                                    if (idx >= 7'd80) idx = idx - 7'd80;
                                    if (!front_sel) buf1[cap_cnt] <= pretrig_buf[idx];
                                    else            buf0[cap_cnt] <= pretrig_buf[idx];
                                end
                                cap_cnt <= cap_cnt + 10'd1;
                            end else begin
                                if (!front_sel) buf1[cap_cnt] <= map_y(adc_sample);
                                else            buf0[cap_cnt] <= map_y(adc_sample);
                                if (cap_cnt == BUF_SIZE - 10'd1) state <= S_SWAP;
                                else cap_cnt <= cap_cnt + 10'd1;
                            end
                        end
                    end

                    S_SWAP: begin
                        front_sel    <= ~front_sel;
                        sample_ready <= 1'b1;
                        state        <= S_ARMED;
                    end

                    default: state <= S_ARMED;
                endcase
            end
        end
    end

    // ----------------------------------------------------------------
    // Read port
    // ----------------------------------------------------------------
    always @(*) begin
        if (read_x >= 10'd640) begin
            wave_y = Y_MID; wave_y_prev = Y_MID;
        end else if (!front_sel) begin
            wave_y      = buf0[read_x];
            wave_y_prev = (read_x > 0) ? buf0[read_x-1] : Y_MID;
        end else begin
            wave_y      = buf1[read_x];
            wave_y_prev = (read_x > 0) ? buf1[read_x-1] : Y_MID;
        end
    end

endmodule