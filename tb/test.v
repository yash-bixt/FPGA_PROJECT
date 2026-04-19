`timescale 1ns / 1ps
// ============================================================
// tb_dso_core.v  -  Testbench for dso_core.v
//
// HOW TO USE IN VIVADO:
//   1. Add this file + xadc_stub.v as Simulation Sources
//   2. Right-click tb_dso_core ? Set as Top
//   3. Run Behavioral Simulation
//   4. TCL: run 500ms
//
// KEY SIGNALS TO ADD TO WAVEFORM:
//   uut/adc_sample    - input ADC codes
//   uut/wave_y        - output pixel row
//   uut/triggered     - 1=edge triggered, 0=auto
//   uut/acq_state     - 0=ARM 1=CAP 2=SWAP
//   uut/trig_level    - current trigger threshold
//   uut/v_scale_code  - full-scale ADC code
//   uut/decim_cnt     - decimation counter
// ============================================================
module tb_dso_core;

    // ---- Clock & Reset ----
    reg clk = 0;
    reg rst = 1;
    always #5 clk = ~clk;   // 100 MHz

    // ---- DUT inputs ----
    reg [11:0] adc_sample   = 12'd0;
    reg        adc_valid    = 1'b0;
    reg [3:0]  sw_vscale    = 4'd5;    // 0.44V full scale
    reg [3:0]  sw_voffset   = 4'd0;
    reg        btn_tb_up    = 1'b0;
    reg        btn_tb_dn    = 1'b0;
    reg        btn_trig_up  = 1'b0;
    reg        btn_trig_dn  = 1'b0;
    reg        btn_trig_edge= 1'b0;
    reg [9:0]  read_x       = 10'd0;

    // ---- DUT outputs ----
    wire [8:0]  wave_y;
    wire [8:0]  wave_y_prev;
    wire [2:0]  timebase;
    wire [11:0] trig_level;
    wire        trig_edge;
    wire [1:0]  acq_state;
    wire        triggered;
    wire        sample_ready;
    wire [11:0] v_scale_code;
    wire [11:0] v_offset_code;

    // ---- Instantiate DUT ----
    dso_core uut (
        .clk            (clk),
        .rst            (rst),
        .adc_sample     (adc_sample),
        .adc_valid      (adc_valid),
        .sw_vscale      (sw_vscale),
        .sw_voffset     (sw_voffset),
        .btn_tb_up      (btn_tb_up),
        .btn_tb_dn      (btn_tb_dn),
        .btn_trig_up    (btn_trig_up),
        .btn_trig_dn    (btn_trig_dn),
        .btn_trig_edge  (btn_trig_edge),
        .read_x         (read_x),
        .wave_y         (wave_y),
        .wave_y_prev    (wave_y_prev),
        .timebase       (timebase),
        .trig_level     (trig_level),
        .trig_edge      (trig_edge),
        .acq_state      (acq_state),
        .triggered      (triggered),
        .sample_ready   (sample_ready),
        .v_scale_code   (v_scale_code),
        .v_offset_code  (v_offset_code)
    );

    // ============================================================
    // TASKS
    // ============================================================

    // Send one ADC sample (200kHz = 5us period)
    task send_sample;
        input [11:0] val;
        begin
            @(posedge clk); #1;
            adc_sample <= val;
            adc_valid  <= 1'b1;
            @(posedge clk); #1;
            adc_valid  <= 1'b0;
            #4980;
        end
    endtask

    // Triangle wave: n_cycles cycles, period_samp samples/cycle, peak ADC code
    task gen_triangle;
        input integer n_cycles;
        input integer period_samp;
        input [11:0]  peak;
        integer i, s;
        reg [11:0] v;
        begin
            for (i = 0; i < n_cycles; i = i + 1) begin
                for (s = 0; s <= period_samp/2; s = s + 1) begin
                    v = (peak * s) / (period_samp/2);
                    send_sample(v);
                end
                for (s = 0; s <= period_samp/2; s = s + 1) begin
                    v = peak - (peak * s) / (period_samp/2);
                    send_sample(v);
                end
            end
        end
    endtask

    // Sine wave: 16 points per cycle from lookup table
    task gen_sine;
        input integer n_cycles;
        input [11:0]  peak;
        integer i, p;
        reg [12:0] lut [0:15];
        reg [11:0] v;
        begin
            lut[0]  = 13'd2048; lut[1]  = 13'd2844;
            lut[2]  = 13'd3496; lut[3]  = 13'd3869;
            lut[4]  = 13'd4095; lut[5]  = 13'd3869;
            lut[6]  = 13'd3496; lut[7]  = 13'd2844;
            lut[8]  = 13'd2048; lut[9]  = 13'd1251;
            lut[10] = 13'd599;  lut[11] = 13'd226;
            lut[12] = 13'd0;    lut[13] = 13'd226;
            lut[14] = 13'd599;  lut[15] = 13'd1251;
            for (i = 0; i < n_cycles; i = i + 1) begin
                for (p = 0; p < 16; p = p + 1) begin
                    v = (lut[p] * peak) >> 12;
                    send_sample(v);
                end
            end
        end
    endtask

    // Square wave
    task gen_square;
        input integer n_cycles;
        input integer half_samp;
        input [11:0]  hi;
        input [11:0]  lo;
        integer i, s;
        begin
            for (i = 0; i < n_cycles; i = i + 1) begin
                for (s = 0; s < half_samp; s = s + 1) send_sample(hi);
                for (s = 0; s < half_samp; s = s + 1) send_sample(lo);
            end
        end
    endtask

    // Flat DC level
    task gen_dc;
        input integer n_samp;
        input [11:0]  level;
        integer i;
        begin
            for (i = 0; i < n_samp; i = i + 1) send_sample(level);
        end
    endtask

    // Wait for sample_ready (frame complete) with timeout
    task wait_frame;
        input integer timeout_us;
        integer t;
        begin
            t = 0;
            while (!sample_ready && t < timeout_us*200) begin
                @(posedge clk); t = t + 1;
            end
            if (t >= timeout_us*200)
                $display("  [%.3fms] TIMEOUT waiting for frame", $realtime/1e6);
            else
                $display("  [%.3fms] Frame ready: triggered=%b acq=%0d",
                         $realtime/1e6, triggered, acq_state);
        end
    endtask

    // One-cycle button pulse
    task pulse_btn;
        inout reg b;
        begin
            b = 1'b1; @(posedge clk); #1;
            b = 1'b0; @(posedge clk); #1;
        end
    endtask

    // Readback first N wave_y values
    task readback;
        input integer n;
        integer i;
        begin
            $display("  Waveform readback:");
            for (i = 0; i < n; i = i + 1) begin
                read_x = i; #20;
                $display("    x=%3d  wave_y=%3d", i, wave_y);
            end
        end
    endtask

    // ============================================================
    // MONITOR - prints state transitions automatically
    // ============================================================
    always @(acq_state)
        $display("  [%.3fms] acq_state=%0d (%s)",
                 $realtime/1e6, acq_state,
                 acq_state==2'd0 ? "ARMED" :
                 acq_state==2'd1 ? "CAPTURE" :
                 acq_state==2'd2 ? "SWAP" : "?");

    always @(posedge sample_ready)
        $display("  [%.3fms] *** FRAME COMPLETE: triggered=%b trig_level=%0d ***",
                 $realtime/1e6, triggered, trig_level);

    always @(trig_level)
        $display("  [%.3fms] trig_level changed -> %0d",
                 $realtime/1e6, trig_level);

    always @(timebase)
        $display("  [%.3fms] timebase changed -> %0d",
                 $realtime/1e6, timebase);

    // ============================================================
    // MAIN TEST SEQUENCE
    // ============================================================
    initial begin
        $display("================================================");
        $display(" TB: dso_core - DSO Acquisition Engine Test");
        $display("================================================");

        rst = 1; #200;
        rst = 0; #200;
        $display("Reset released. Starting tests...\n");

        // ----------------------------------------------------------
        // TEST 1: Triangle wave - rising edge trigger
        // ----------------------------------------------------------
        $display("--- TEST 1: Triangle wave (rising edge) ---");
        $display("  trig_level=%0d  trig_edge=%b", trig_level, trig_edge);
        gen_triangle(10, 80, 12'd1843);
        wait_frame(60000);
        readback(10);

        // ----------------------------------------------------------
        // TEST 2: Sine wave
        // ----------------------------------------------------------
        $display("\n--- TEST 2: Sine wave ---");
        gen_sine(10, 12'd1843);
        wait_frame(60000);

        // ----------------------------------------------------------
        // TEST 3: Square wave rising then falling trigger
        // ----------------------------------------------------------
        $display("\n--- TEST 3: Square wave RISE trigger ---");
        gen_square(10, 40, 12'd1843, 12'd0);
        wait_frame(60000);

        $display("\n--- TEST 3b: Square wave FALL trigger ---");
        pulse_btn(btn_trig_edge);
        $display("  trig_edge=%b", trig_edge);
        gen_square(10, 40, 12'd1843, 12'd0);
        wait_frame(60000);
        pulse_btn(btn_trig_edge);  // restore to RISE

        // ----------------------------------------------------------
        // TEST 4: Auto trigger (no edge - DC signal)
        // ----------------------------------------------------------
        $display("\n--- TEST 4: Auto trigger (flat DC below threshold) ---");
        gen_dc(500, 12'd300);
        wait_frame(2000000);
        if (!triggered)
            $display("  PASS: auto-triggered (no edge found as expected)");
        else
            $display("  NOTE: triggered (signal crossed threshold)");

        // ----------------------------------------------------------
        // TEST 5: Trigger level buttons
        // ----------------------------------------------------------
        $display("\n--- TEST 5: Trigger level adjustment ---");
        $display("  Initial trig_level=%0d", trig_level);
        repeat(4) begin pulse_btn(btn_trig_up); #50; end
        $display("  After 4x UP: trig_level=%0d", trig_level);
        repeat(2) begin pulse_btn(btn_trig_dn); #50; end
        $display("  After 2x DN: trig_level=%0d", trig_level);

        // Verify trigger still works
        gen_triangle(10, 80, 12'd1843);
        wait_frame(60000);
        $display("  triggered=%b with new level", triggered);

        // Reset level
        repeat(2) begin pulse_btn(btn_trig_dn); #50; end

        // ----------------------------------------------------------
        // TEST 6: Timebase steps
        // ----------------------------------------------------------
        $display("\n--- TEST 6: Timebase steps ---");
        $display("  Initial timebase=%0d", timebase);
        repeat(3) begin pulse_btn(btn_tb_up); #50; end
        $display("  After 3x BTNU: timebase=%0d", timebase);
        pulse_btn(btn_tb_dn); #50;
        $display("  After 1x BTND: timebase=%0d", timebase);
        repeat(2) begin pulse_btn(btn_tb_dn); #50; end
        $display("  Restored: timebase=%0d", timebase);

        // ----------------------------------------------------------
        // TEST 7: V_SCALE switch
        // ----------------------------------------------------------
        $display("\n--- TEST 7: V_SCALE switch (SW[3:0]) ---");
        sw_vscale = 4'd0; #100;
        $display("  SW=0: v_scale_code=%0d (expect 4095)", v_scale_code);
        sw_vscale = 4'd5; #100;
        $display("  SW=5: v_scale_code=%0d (expect 1843)", v_scale_code);
        sw_vscale = 4'd8; #100;
        $display("  SW=8: v_scale_code=%0d (expect 1024)", v_scale_code);
        sw_vscale = 4'hB; #100;
        $display("  SW=B: v_scale_code=%0d (expect 410)", v_scale_code);
        sw_vscale = 4'd5; #100;  // restore

        // ----------------------------------------------------------
        // TEST 8: V_OFFSET switch
        // ----------------------------------------------------------
        $display("\n--- TEST 8: V_OFFSET switch (SW[7:4]) ---");
        sw_voffset = 4'd0; #100;
        $display("  SW[7:4]=0: v_offset_code=%0d (expect 0)", v_offset_code);
        sw_voffset = 4'd2; #100;
        $display("  SW[7:4]=2: v_offset_code=%0d (expect 512)", v_offset_code);
        sw_voffset = 4'd4; #100;
        $display("  SW[7:4]=4: v_offset_code=%0d (expect 1024)", v_offset_code);
        sw_voffset = 4'd0; #100;

        // ----------------------------------------------------------
        // TEST 9: Pixel mapping - 0V, full-scale, midscale
        // ----------------------------------------------------------
        $display("\n--- TEST 9: Pixel row mapping ---");
        sw_vscale = 4'd0;  // 1V full scale for clean mapping
        #100;

        gen_dc(700, 12'd0);
        wait_frame(60000);
        read_x = 10'd200; #50;
        $display("  0V input:         wave_y=%0d (expect ~449)", wave_y);

        gen_dc(700, 12'd4095);
        wait_frame(60000);
        read_x = 10'd200; #50;
        $display("  Full-scale input: wave_y=%0d (expect ~30)", wave_y);

        gen_dc(700, 12'd2048);
        wait_frame(60000);
        read_x = 10'd200; #50;
        $display("  Mid-scale input:  wave_y=%0d (expect ~239)", wave_y);

        sw_vscale = 4'd5; #100;

        // ----------------------------------------------------------
        // TEST 10: Trigger boundary - max and min level
        // ----------------------------------------------------------
        $display("\n--- TEST 10: Trigger level boundaries ---");
        repeat(35) begin pulse_btn(btn_trig_up); #30; end
        $display("  Max trig_level=%0d (should clamp near 3967)", trig_level);
        repeat(35) begin pulse_btn(btn_trig_dn); #30; end
        $display("  Min trig_level=%0d (should clamp near 128)", trig_level);
        repeat(16) begin pulse_btn(btn_trig_up); #30; end
        $display("  Restored trig_level=%0d", trig_level);

        // ----------------------------------------------------------
        // TEST 11: Timebase boundary - min and max
        // ----------------------------------------------------------
        $display("\n--- TEST 11: Timebase boundaries ---");
        repeat(8) begin pulse_btn(btn_tb_up); #50; end
        $display("  Max timebase=%0d (expect 7)", timebase);
        repeat(8) begin pulse_btn(btn_tb_dn); #50; end
        $display("  Min timebase=%0d (expect 0)", timebase);
        repeat(2) begin pulse_btn(btn_tb_up); #50; end
        $display("  Restored timebase=%0d (expect 2)", timebase);

        $display("\n================================================");
        $display(" ALL TESTS COMPLETE");
        $display(" Review waveforms in Vivado Wave viewer");
        $display("================================================");
        $finish;
    end

endmodule