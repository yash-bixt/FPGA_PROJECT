`timescale 1ns / 1ps
// ============================================================
// top_dso.v  -  Nexys 4 Generic Digital Storage Oscilloscope
//
// Signal chain:
//   JXADC (VAUXP3/N3) -> xadc_reader -> dso_core -> osd_renderer -> VGA
//
// Buttons (Nexys4):
//   BTNU  = Timebase faster
//   BTND  = Timebase slower
//   BTNL  = Trigger level down
//   BTNR  = Trigger level up
//   BTNC  = Toggle trigger edge (rising/falling)
//
// Switches:
//   SW[3:0]  = V_SCALE  (input full-scale voltage setting)
//   SW[7:4]  = V_OFFSET (DC offset correction)
//   SW[15:8] = Reserved (future use)
//
// V_SCALE table (see dso_core.v for full list):
//   SW=0101 (5) -> 0.45V full scale  (100k/10k divider, 5V input)
//   SW=0000 (0) -> 1.00V full scale  (direct XADC input)
//   SW=0100 (4) -> 0.50V full scale  (47k/10k divider, ~5V input)
// ============================================================
module top_dso (
    input  wire        CLK100MHZ,
    input  wire        CPU_RESETN,

    // XADC analog input (JXADC header)
    input  wire        VAUXP3,
    input  wire        VAUXN3,

    // Buttons
    input  wire        BTNU,
    input  wire        BTND,
    input  wire        BTNL,
    input  wire        BTNR,
    input  wire        BTNC,

    // Slide switches
    input  wire [15:0] SW,

    // VGA output
    output wire        VGA_HS,
    output wire        VGA_VS,
    output wire [3:0]  VGA_R,
    output wire [3:0]  VGA_G,
    output wire [3:0]  VGA_B
);
    wire rst = ~CPU_RESETN;

    // ----------------------------------------------------------------
    // 25 MHz pixel tick
    // ----------------------------------------------------------------
    wire pixel_tick;
    pixel_tick_gen u_ptick (
        .clk        (CLK100MHZ),
        .pixel_tick (pixel_tick)
    );

    // ----------------------------------------------------------------
    // VGA timing
    // ----------------------------------------------------------------
    wire [9:0] x, y;
    wire       video_on;

    vga_timing u_vga (
        .clk         (CLK100MHZ),
        .pixel_tick  (pixel_tick),
        .hsync       (VGA_HS),
        .vsync       (VGA_VS),
        .video_on    (video_on),
        .x           (x),
        .y           (y),
        .vsync_pulse ()
    );

    // ----------------------------------------------------------------
    // Button debouncers
    // ----------------------------------------------------------------
    wire btn_tb_up, btn_tb_dn, btn_trig_up, btn_trig_dn, btn_edge;

    btn_debounce u_dbn_u (.clk(CLK100MHZ), .btn_raw(BTNU), .btn_pulse(btn_tb_up));
    btn_debounce u_dbn_d (.clk(CLK100MHZ), .btn_raw(BTND), .btn_pulse(btn_tb_dn));
    btn_debounce u_dbn_r (.clk(CLK100MHZ), .btn_raw(BTNR), .btn_pulse(btn_trig_up));
    btn_debounce u_dbn_l (.clk(CLK100MHZ), .btn_raw(BTNL), .btn_pulse(btn_trig_dn));
    btn_debounce u_dbn_c (.clk(CLK100MHZ), .btn_raw(BTNC), .btn_pulse(btn_edge));

    // ----------------------------------------------------------------
    // XADC reader
    // ----------------------------------------------------------------
    wire [11:0] adc_sample;
    wire        adc_valid, sample_ready;

    xadc_reader u_xadc (
        .clk          (CLK100MHZ),
        .rst          (rst),
        .vauxp3       (VAUXP3),
        .vauxn3       (VAUXN3),
        .sample       (adc_sample),
        .sample_valid (adc_valid),
        .sample_ready (sample_ready)
    );

    // ----------------------------------------------------------------
    // DSO core
    // ----------------------------------------------------------------
    wire [8:0]  wave_y, wave_y_prev;
    wire [2:0]  timebase;
    wire [11:0] trig_level;
    wire        trig_edge;
    wire [1:0]  acq_state;
    wire        triggered;
    wire        core_sample_ready;
    wire [11:0] v_scale_code, v_offset_code;

    dso_core u_core (
        .clk            (CLK100MHZ),
        .rst            (rst),
        .adc_sample     (adc_sample),
        .adc_valid      (adc_valid),
        .sw_vscale      (SW[3:0]),
        .sw_voffset     (SW[7:4]),
        .btn_tb_up      (btn_tb_up),
        .btn_tb_dn      (btn_tb_dn),
        .btn_trig_up    (btn_trig_up),
        .btn_trig_dn    (btn_trig_dn),
        .btn_trig_edge  (btn_edge),
        .read_x         (x),
        .wave_y         (wave_y),
        .wave_y_prev    (wave_y_prev),
        .timebase       (timebase),
        .trig_level     (trig_level),
        .trig_edge      (trig_edge),
        .acq_state      (acq_state),
        .triggered      (triggered),
        .sample_ready   (core_sample_ready),
        .v_scale_code   (v_scale_code),
        .v_offset_code  (v_offset_code)
    );

    // ----------------------------------------------------------------
    // OSD renderer
    // ----------------------------------------------------------------
    wire [11:0] rgb;

    osd_renderer u_osd (
        .clk          (CLK100MHZ),
        .pixel_tick   (pixel_tick),
        .video_on     (video_on),
        .x            (x),
        .y            (y),
        .wave_y       (wave_y),
        .wave_y_prev  (wave_y_prev),
        .sample_ready (core_sample_ready),
        .timebase     (timebase),
        .trig_level   (trig_level),
        .trig_edge    (trig_edge),
        .acq_state    (acq_state),
        .triggered    (triggered),
        .v_scale_code (v_scale_code),
        .v_offset_code(v_offset_code),
        .sw_vscale    (SW[3:0]),
        .rgb          (rgb)
    );

    assign VGA_R = rgb[11:8];
    assign VGA_G = rgb[7:4];
    assign VGA_B = rgb[3:0];

endmodule