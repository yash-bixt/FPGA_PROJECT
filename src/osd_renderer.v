`timescale 1ns / 1ps
// ============================================================
// osd_renderer.v  -  DSO On-Screen Display v6
//
// FIX v6: Voltage display corrected.
//   All voltages now stored as centivolts (integer 0-100):
//     1.00V = 100, 0.45V = 45, 0.25V = 25 etc.
//   Conversion: cv = adc_code / 41
//     (4096 codes / 100 cV = 40.96 per cV, 41 is integer approx)
//   Digit extraction:
//     units  = cv / 100       -> 0 or 1
//     tenths = (cv % 100) / 10
//     hundredths = cv % 10
//   This gives correct "X.XX" format on screen.
//
// SCREEN LAYOUT:
//
//  Y=0..19    Top status bar
//               x=0..99    "TB-X"
//               x=100..239  Trigger level bar + "TL"
//               x=240..319  "RISE"/"FALL"
//               x=320..399  "ARM"/"CAP"/"SWP"
//               x=400..479  "TRIG"/"AUTO"
//               x=480..639  "X:X.XXV"  (SW index : full-scale V)
//
//  Y=20..29   Voltage header row
//               x=0..49:   full-scale "X.XX" (yellow)
//               x=50..639: dark background
//
//  Y=30..449  Waveform area
//    x=0..49   Y-axis margin:
//               "X.XX" voltage labels at each H grid line  (yellow)
//               Orange trigger arrow at trigger voltage row
//    x=50..639  Waveform canvas:
//               Dotted grid (80px V / 60px H)
//               Dashed trigger level line (yellow-orange)
//               Pre-trigger dashed marker at x=130
//               Waveform trace (bright green, interpolated)
//
//  Y=450..459  X-axis time label row
//               "0" at x=50, "Xms"/"XXms"/"XXXms" at each 80px step
//
//  Y=460..479  Bottom status bar
//               x=0..200    "Xms/div" or "XXms/div" or "XXXms/div"
//               x=210..400  "X.XXV/div"
//               x=400..639  "TL:X.XXV"
// ============================================================
module osd_renderer (
    input  wire        clk,
    input  wire        pixel_tick,
    input  wire        video_on,
    input  wire [9:0]  x,
    input  wire [9:0]  y,

    input  wire [8:0]  wave_y,
    input  wire [8:0]  wave_y_prev,
    input  wire        sample_ready,
    input  wire [2:0]  timebase,
    input  wire [11:0] trig_level,
    input  wire        trig_edge,
    input  wire [1:0]  acq_state,
    input  wire        triggered,
    input  wire [11:0] v_scale_code,
    input  wire [11:0] v_offset_code,
    input  wire [3:0]  sw_vscale,

    output reg  [11:0] rgb
);
    // ================================================================
    // Layout
    // ================================================================
    localparam STAT_TOP_H  = 10'd20;
    localparam VHDR_Y0     = 10'd20;
    localparam VHDR_Y1     = 10'd29;
    localparam WAVE_Y0     = 10'd30;
    localparam WAVE_Y1     = 10'd449;
    localparam XLBL_Y0     = 10'd450;
    localparam XLBL_Y1     = 10'd459;
    localparam STAT_BOT_Y0 = 10'd460;
    localparam WAVE_X0     = 10'd50;
    localparam WAVE_H      = 10'd420;
    localparam Y_BOT       = 9'd449;
    localparam PRETRIG_X   = 10'd130;

    // ================================================================
    // Wave latch
    // ================================================================
    reg [8:0] wave_y_reg, wave_y_prev_reg;
    reg [9:0] last_x;
    always @(posedge clk) begin
        if (pixel_tick && x != last_x) begin
            wave_y_reg      <= wave_y;
            wave_y_prev_reg <= wave_y_prev;
            last_x          <= x;
        end
    end

    // ================================================================
    // Area flags
    // ================================================================
    wire in_wave    = (x >= WAVE_X0) && (y >= WAVE_Y0) && (y <= WAVE_Y1);
    wire in_ymargin = (x <  WAVE_X0) && (y >= WAVE_Y0) && (y <= WAVE_Y1);
    wire in_vhdr    = (y >= VHDR_Y0) && (y <= VHDR_Y1);
    wire in_xlbl    = (y >= XLBL_Y0) && (y <= XLBL_Y1);
    wire in_stat_bot= (y >= STAT_BOT_Y0);

    // ================================================================
    // Waveform hit (interpolated)
    // ================================================================
    wire [9:0] yc   = {1'b0, wave_y_reg};
    wire [9:0] yp   = {1'b0, wave_y_prev_reg};
    wire [9:0] y_lo = (yc <= yp) ? yc : yp;
    wire [9:0] y_hi = (yc >= yp) ? yc : yp;
    wire wave_hit   = sample_ready && in_wave &&
                      (y >= (y_lo > 10'd1   ? y_lo - 10'd1 : 10'd0)) &&
                      (y <= (y_hi < 10'd448 ? y_hi + 10'd1 : 10'd449));

    // ================================================================
    // Grid (relative offsets)
    // ================================================================
    wire [9:0] wx = (x >= WAVE_X0) ? (x - WAVE_X0) : 10'd0;
    wire [9:0] wy = (y >= WAVE_Y0) ? (y - WAVE_Y0) : 10'd0;

    wire on_vgrid    = in_wave && (wx % 10'd80 == 10'd0);
    wire on_hgrid    = in_wave && (wy % 10'd60 == 10'd0);
    wire grid_v_dot  = on_vgrid && (wy[3] == 1'b0);
    wire grid_h_dot  = on_hgrid && (wx[3] == 1'b0);
    wire grid_px     = grid_v_dot || grid_h_dot;

    // ================================================================
    // Border
    // ================================================================
    wire border = ((y == WAVE_Y0 || y == WAVE_Y1) && (x >= WAVE_X0)) ||
                  ((x == WAVE_X0 || x == 10'd639) && (y >= WAVE_Y0) && (y <= WAVE_Y1));

    // ================================================================
    // Trigger level row
    // ================================================================
    wire [22:0] trig_prod   = trig_level * WAVE_H;
    wire [9:0]  trig_offset = trig_prod[22:13];
    wire [9:0]  trig_y_row  = {1'b0, Y_BOT} - trig_offset;
    wire trig_line = in_wave && (y == trig_y_row) && (wx % 10'd10 < 10'd6);

    // Pre-trigger dashed marker
    wire pretrig_mark = (x == PRETRIG_X) && in_wave && (wy % 10'd16 < 10'd6);

    // ================================================================
    // Y-axis trigger arrow (right-pointing triangle in left margin)
    // ================================================================
    wire [9:0] arr_cy = trig_y_row;
    wire [9:0] arr_dy = (y >= arr_cy) ? (y - arr_cy) : (arr_cy - y);
    wire arr_valid    = in_ymargin && (arr_dy <= 10'd2);
    wire [9:0] arr_hw = 10'd2 - arr_dy;                // half-width: 2,1,0
    wire trig_arrow   = arr_valid &&
                        (x >= (10'd45 - arr_hw)) && (x <= 10'd47);

    // ================================================================
    // 5x7 Font ROM
    // Index:
    //  0-9  digits
    //  10=. 11=V 12=m 13=s 14=/
    //  15=T 16=R 17=I 18=G 19=A
    //  20=U 21=O 22=+ 23=- 24=k
    //  25=B 26=C 27=F 28=L 29=E
    //  30=S 31=W 32=H 33=N 34=d
    //  35=i 36=v 37=p 38=: 39=space
    // ================================================================
    function [34:0] font_char;
        input [5:0] idx;
        begin
            case (idx)
              6'd0:  font_char=35'b01110_10001_10011_10101_11001_10001_01110;
              6'd1:  font_char=35'b00100_01100_00100_00100_00100_00100_01110;
              6'd2:  font_char=35'b01110_10001_00001_00110_01000_10000_11111;
              6'd3:  font_char=35'b01110_10001_00001_00110_00001_10001_01110;
              6'd4:  font_char=35'b00010_00110_01010_10010_11111_00010_00010;
              6'd5:  font_char=35'b11111_10000_11110_00001_00001_10001_01110;
              6'd6:  font_char=35'b00110_01000_10000_11110_10001_10001_01110;
              6'd7:  font_char=35'b11111_00001_00010_00100_01000_01000_01000;
              6'd8:  font_char=35'b01110_10001_10001_01110_10001_10001_01110;
              6'd9:  font_char=35'b01110_10001_10001_01111_00001_00010_01100;
              6'd10: font_char=35'b00000_00000_00000_00000_00000_01100_01100;
              6'd11: font_char=35'b10001_10001_01010_00100_01010_10001_10001;
              6'd12: font_char=35'b00000_00000_11010_10101_10101_10101_10101;
              6'd13: font_char=35'b00000_01110_10000_01110_00001_00001_11110;
              6'd14: font_char=35'b00001_00001_00010_00100_01000_10000_10000;
              6'd15: font_char=35'b11111_00100_00100_00100_00100_00100_00100;
              6'd16: font_char=35'b11110_10001_10001_11110_10100_10010_10001;
              6'd17: font_char=35'b01110_00100_00100_00100_00100_00100_01110;
              6'd18: font_char=35'b01110_10001_10000_10111_10001_10001_01110;
              6'd19: font_char=35'b00100_01010_10001_10001_11111_10001_10001;
              6'd20: font_char=35'b10001_10001_10001_10001_10001_10001_01110;
              6'd21: font_char=35'b01110_10001_10001_10001_10001_10001_01110;
              6'd22: font_char=35'b00000_00100_00100_11111_00100_00100_00000;
              6'd23: font_char=35'b00000_00000_00000_11111_00000_00000_00000;
              6'd24: font_char=35'b10001_10010_10100_11000_10100_10010_10001;
              6'd25: font_char=35'b11110_10001_10001_11110_10001_10001_11110;
              6'd26: font_char=35'b01110_10001_10000_10000_10000_10001_01110;
              6'd27: font_char=35'b11111_10000_10000_11110_10000_10000_10000;
              6'd28: font_char=35'b10000_10000_10000_10000_10000_10000_11111;
              6'd29: font_char=35'b11111_10000_10000_11110_10000_10000_11111;
              6'd30: font_char=35'b01111_10000_10000_01110_00001_00001_11110;
              6'd31: font_char=35'b10001_10001_10001_10101_10101_11011_10001;
              6'd32: font_char=35'b10001_10001_10001_11111_10001_10001_10001;
              6'd33: font_char=35'b10001_11001_10101_10011_10001_10001_10001;
              6'd34: font_char=35'b00001_00001_01101_10011_10001_10011_01101;
              6'd35: font_char=35'b00100_00000_01100_00100_00100_00100_01110;
              6'd36: font_char=35'b00000_10001_10001_01010_01010_00100_00100;
              6'd37: font_char=35'b00000_01110_10001_10001_01111_00001_00001;
              6'd38: font_char=35'b00000_01100_01100_00000_01100_01100_00000;
              6'd39: font_char=35'b00000_00000_00000_00000_00000_00000_00000;
              default: font_char = 35'd0;
            endcase
        end
    endfunction

    function font_px;
        input [5:0] ch;
        input [2:0] col;
        input [2:0] row;
        reg [34:0] bits;
        reg [4:0]  rb;
        begin
            bits    = font_char(ch);
            rb      = bits[34 - row*5 -: 5];
            font_px = rb[4 - col];
        end
    endfunction

    // stat_px: returns 1 if pixel (px,py) is inside char ch at position (cx,cy)
    function stat_px;
        input [9:0] px, py;
        input [5:0] ch;
        input [9:0] cx, cy;
        reg [2:0] ccol, crow;
        begin
            if (px >= cx && px < cx + 10'd5 &&
                py >= cy && py < cy + 10'd7) begin
                ccol    = px - cx;
                crow    = py - cy;
                stat_px = font_px(ch, ccol, crow);
            end else
                stat_px = 1'b0;
        end
    endfunction

    // ================================================================
    // VOLTAGE ARITHMETIC  - centivolts (integer 0-100)
    //
    // XADC full scale = 4096 codes = 1.000V
    // 1 centivolt = 0.01V = 40.96 codes -> use 41 as integer divisor
    //
    // Examples:
    //   v_scale_code=4095 -> vfs_cv = 4095/41 = 99  -> displays "0.99V"
    //   v_scale_code=1843 -> vfs_cv = 1843/41 = 44  -> displays "0.44V"
    //   v_scale_code=1024 -> vfs_cv = 1024/41 = 24  -> displays "0.24V"
    //
    // Digit extraction from centivolt (0-100):
    //   units      = cv / 100        (0 or 1)
    //   tenths     = (cv % 100) / 10 (0-9)
    //   hundredths = cv % 10         (0-9)
    // ================================================================
    wire [6:0] vfs_cv   = v_scale_code / 12'd41;
    wire [6:0] voff_cv  = v_offset_code / 12'd41;
    wire [6:0] vtrig_cv = trig_level / 12'd41;
    wire [6:0] vdiv_cv  = vfs_cv / 7'd7;

    // Digit extraction functions (centivolt 0-100)
    function [3:0] dU; input [6:0] cv; begin dU = cv / 7'd100;           end endfunction // units (0,1)
    function [3:0] dT; input [6:0] cv; begin dT = (cv % 7'd100) / 7'd10; end endfunction // tenths
    function [3:0] dO; input [6:0] cv; begin dO = cv % 7'd10;            end endfunction // hundredths

    // Precompute digit sets for frequently used voltages
    // Full scale
    wire [3:0] vfs_dU = dU(vfs_cv);
    wire [3:0] vfs_dT = dT(vfs_cv);
    wire [3:0] vfs_dO = dO(vfs_cv);
    // Trigger
    wire [3:0] vtrig_dU = dU(vtrig_cv);
    wire [3:0] vtrig_dT = dT(vtrig_cv);
    wire [3:0] vtrig_dO = dO(vtrig_cv);
    // V/div
    wire [3:0] vdiv_dU = dU(vdiv_cv);
    wire [3:0] vdiv_dT = dT(vdiv_cv);
    wire [3:0] vdiv_dO = dO(vdiv_cv);

    // ================================================================
    // TIMEBASE ARITHMETIC
    // window_ms: total capture window in milliseconds
    // tdiv_ms:   time per division (window / 8 divs)
    // ================================================================
    function [9:0] window_ms;
        input [2:0] tb;
        begin
            case (tb)
                3'd0: window_ms = 10'd3;
                3'd1: window_ms = 10'd6;
                3'd2: window_ms = 10'd16;
                3'd3: window_ms = 10'd32;
                3'd4: window_ms = 10'd64;
                3'd5: window_ms = 10'd160;
                3'd6: window_ms = 10'd320;
                3'd7: window_ms = 10'd640;
                default: window_ms = 10'd3;
            endcase
        end
    endfunction

    wire [9:0] wms     = window_ms(timebase);
    wire [9:0] tdiv_ms = wms >> 3;   // /8 divisions

    // ================================================================
    // TOP STATUS BAR (y=0..19)
    // ================================================================
    wire in_stat_top  = (y < STAT_TOP_H);
    wire in_tb_zone   = in_stat_top && (x < 10'd100);
    wire in_tl_zone   = in_stat_top && (x >= 10'd100) && (x < 10'd240);
    wire in_edge_zone = in_stat_top && (x >= 10'd240) && (x < 10'd320);
    wire in_acq_zone  = in_stat_top && (x >= 10'd320) && (x < 10'd400);
    wire in_trg_zone  = in_stat_top && (x >= 10'd400) && (x < 10'd480);
    wire in_vin_zone  = in_stat_top && (x >= 10'd480);

    // "TB-X"
    wire tb_px = in_tb_zone && (
        stat_px(x, y, 6'd15,            10'd2,  10'd6) |  // T
        stat_px(x, y, 6'd25,            10'd8,  10'd6) |  // B
        stat_px(x, y, 6'd23,            10'd14, 10'd6) |  // -
        stat_px(x, y, {2'd0,timebase},  10'd20, 10'd6)    // 0-7
    );

    // Trigger bar + "TL"
    wire [9:0] tl_fill   = (x >= 10'd100) ? (x - 10'd100) : 10'd0;
    wire [9:0] tl_scaled = ({1'b0, trig_level[11:4]} * 10'd140) >> 8;
    wire tl_bar_active   = in_tl_zone && (tl_fill < tl_scaled);
    wire tl_px = in_tl_zone && (
        stat_px(x-10'd100, y, 6'd15, 10'd2, 10'd6) |  // T
        stat_px(x-10'd100, y, 6'd28, 10'd8, 10'd6)    // L
    );

    // "RISE"/"FALL"
    wire edge_px = in_edge_zone && (trig_edge ? (
        stat_px(x-10'd240, y, 6'd27, 10'd2,  10'd6) |
        stat_px(x-10'd240, y, 6'd19, 10'd8,  10'd6) |
        stat_px(x-10'd240, y, 6'd28, 10'd14, 10'd6) |
        stat_px(x-10'd240, y, 6'd28, 10'd20, 10'd6)
    ) : (
        stat_px(x-10'd240, y, 6'd16, 10'd2,  10'd6) |
        stat_px(x-10'd240, y, 6'd17, 10'd8,  10'd6) |
        stat_px(x-10'd240, y, 6'd30, 10'd14, 10'd6) |
        stat_px(x-10'd240, y, 6'd29, 10'd20, 10'd6)
    ));

    // "ARM"/"CAP"/"SWP"
    wire acq_px = in_acq_zone && (
        (acq_state == 2'd0) ? (
            stat_px(x-10'd320, y, 6'd19, 10'd2,  10'd6) |
            stat_px(x-10'd320, y, 6'd16, 10'd8,  10'd6) |
            stat_px(x-10'd320, y, 6'd12, 10'd14, 10'd6)
        ) : (acq_state == 2'd1) ? (
            stat_px(x-10'd320, y, 6'd26, 10'd2,  10'd6) |
            stat_px(x-10'd320, y, 6'd19, 10'd8,  10'd6) |
            stat_px(x-10'd320, y, 6'd37, 10'd14, 10'd6)
        ) : (
            stat_px(x-10'd320, y, 6'd30, 10'd2,  10'd6) |
            stat_px(x-10'd320, y, 6'd31, 10'd8,  10'd6) |
            stat_px(x-10'd320, y, 6'd37, 10'd14, 10'd6)
        )
    );

    // "TRIG"/"AUTO"
    wire trg_px = in_trg_zone && (triggered ? (
        stat_px(x-10'd400, y, 6'd15, 10'd2,  10'd6) |
        stat_px(x-10'd400, y, 6'd16, 10'd8,  10'd6) |
        stat_px(x-10'd400, y, 6'd17, 10'd14, 10'd6) |
        stat_px(x-10'd400, y, 6'd18, 10'd20, 10'd6)
    ) : (
        stat_px(x-10'd400, y, 6'd19, 10'd2,  10'd6) |
        stat_px(x-10'd400, y, 6'd20, 10'd8,  10'd6) |
        stat_px(x-10'd400, y, 6'd15, 10'd14, 10'd6) |
        stat_px(x-10'd400, y, 6'd21, 10'd20, 10'd6)
    ));

    // "X:X.XXV"  SW index + full-scale voltage
    wire vin_px = in_vin_zone && (
        stat_px(x-10'd480, y, {2'd0, sw_vscale}, 10'd2,  10'd6) |  // SW digit
        stat_px(x-10'd480, y, 6'd38,             10'd8,  10'd6) |  // :
        stat_px(x-10'd480, y, {2'd0, vfs_dU},   10'd14, 10'd6) |  // units
        stat_px(x-10'd480, y, 6'd10,             10'd20, 10'd6) |  // .
        stat_px(x-10'd480, y, {2'd0, vfs_dT},   10'd26, 10'd6) |  // tenths
        stat_px(x-10'd480, y, {2'd0, vfs_dO},   10'd32, 10'd6) |  // hundredths
        stat_px(x-10'd480, y, 6'd11,             10'd38, 10'd6)    // V
    );

    // ================================================================
    // VOLTAGE HEADER ROW (y=20..29)
    // Show full-scale voltage "X.XX" in top-left corner
    // ================================================================
    wire [9:0] vhdr_py = y - VHDR_Y0;
    wire vhdr_px = in_vhdr && (x < WAVE_X0) && (
        stat_px(x, vhdr_py, {2'd0, vfs_dU}, 10'd1,  10'd1) |
        stat_px(x, vhdr_py, 6'd10,          10'd7,  10'd1) |
        stat_px(x, vhdr_py, {2'd0, vfs_dT}, 10'd13, 10'd1) |
        stat_px(x, vhdr_py, {2'd0, vfs_dO}, 10'd19, 10'd1)
    );

    // ================================================================
    // Y-AXIS VOLTAGE LABELS (x=0..49, y=30..449)
    //
    // 8 horizontal grid lines at wy = 0,60,120,180,240,300,360,420
    // Voltage at grid row k (k=0=top, k=7=bottom):
    //   gv_cv = voff_cv + (7-k) * vfs_cv / 7
    //
    // Only rendered for 7 interior lines (k=0..6),
    // bottom line (k=7) shows as "0.00" + offset automatically
    // ================================================================
    wire [9:0] wy_rel   = (y >= WAVE_Y0) ? (y - WAVE_Y0) : 10'd0;
    wire [9:0] wy_div   = wy_rel / 10'd60;    // 0..6
    wire [9:0] wy_inrow = wy_rel % 10'd60;    // pixel offset within row (0..59)

    // Voltage at this grid row in centivolts
    wire [7:0] gv_cv    = voff_cv + ((7'd7 - wy_div[2:0]) * vfs_cv) / 7'd7;
    wire [3:0] gv_dU    = dU(gv_cv[6:0]);
    wire [3:0] gv_dT    = dT(gv_cv[6:0]);
    wire [3:0] gv_dO    = dO(gv_cv[6:0]);

    // Render only near a grid line (top 8 rows of each 60px band)
    wire ylabel_px = in_ymargin && (wy_inrow < 10'd8) && (
        stat_px(x, wy_inrow, {2'd0, gv_dU}, 10'd1,  10'd0) |  // units
        stat_px(x, wy_inrow, 6'd10,         10'd7,  10'd0) |  // .
        stat_px(x, wy_inrow, {2'd0, gv_dT}, 10'd13, 10'd0) |  // tenths
        stat_px(x, wy_inrow, {2'd0, gv_dO}, 10'd19, 10'd0)    // hundredths
    );

    // "0.00" label at very bottom of Y margin (y=442..449)
    wire [9:0] ybot_py = (y >= 10'd442) ? (y - 10'd442) : 10'd0;
    wire [3:0] bot0_dU = dU(voff_cv);
    wire [3:0] bot0_dT = dT(voff_cv);
    wire [3:0] bot0_dO = dO(voff_cv);
    wire ylabel_bot = in_ymargin && (y >= 10'd442) && (y <= WAVE_Y1) && (
        stat_px(x, ybot_py, {2'd0, bot0_dU}, 10'd1,  10'd0) |
        stat_px(x, ybot_py, 6'd10,           10'd7,  10'd0) |
        stat_px(x, ybot_py, {2'd0, bot0_dT}, 10'd13, 10'd0) |
        stat_px(x, ybot_py, {2'd0, bot0_dO}, 10'd19, 10'd0)
    );

    // ================================================================
    // X-AXIS TIME LABELS (y=450..459)
    // Grid columns at wx = 0,80,160,240,320,400,480,560
    // screen x    = 50,130,210,290,370,450,530,610
    // Time at col k: t_ms = k * tdiv_ms
    // ================================================================
    wire [9:0] xlbl_py  = y - XLBL_Y0;
    wire [9:0] wx_xlbl  = (x >= WAVE_X0) ? (x - WAVE_X0) : 10'd700;
    wire [9:0] wx_col   = wx_xlbl / 10'd80;
    wire [9:0] wx_incol = wx_xlbl % 10'd80;

    wire [9:0] col_tms  = wx_col * tdiv_ms;
    wire       t_big    = (col_tms >= 100);
    wire       t_med    = (col_tms >= 10) && ~t_big;
    wire [3:0] t_d0     = t_big ? (col_tms / 10'd100)              : 4'd0;
    wire [3:0] t_d1     = t_big ? ((col_tms % 10'd100) / 10'd10)   :
                          t_med ? (col_tms / 10'd10)               : 4'd0;
    wire [3:0] t_d2     = col_tms % 10'd10;

    wire xlbl_px = in_xlbl && (x >= WAVE_X0) && (wx_incol < 10'd28) && (
        (wx_col == 10'd0) ? (
            stat_px(wx_incol, xlbl_py, 6'd0, 10'd0, 10'd1)           // "0"
        ) : t_big ? (
            stat_px(wx_incol, xlbl_py, {2'd0,t_d0}, 10'd0,  10'd1) |
            stat_px(wx_incol, xlbl_py, {2'd0,t_d1}, 10'd6,  10'd1) |
            stat_px(wx_incol, xlbl_py, {2'd0,t_d2}, 10'd12, 10'd1) |
            stat_px(wx_incol, xlbl_py, 6'd12,       10'd18, 10'd1) |  // m
            stat_px(wx_incol, xlbl_py, 6'd13,       10'd24, 10'd1)    // s
        ) : t_med ? (
            stat_px(wx_incol, xlbl_py, {2'd0,t_d1}, 10'd0,  10'd1) |
            stat_px(wx_incol, xlbl_py, {2'd0,t_d2}, 10'd6,  10'd1) |
            stat_px(wx_incol, xlbl_py, 6'd12,       10'd12, 10'd1) |
            stat_px(wx_incol, xlbl_py, 6'd13,       10'd18, 10'd1)
        ) : (
            stat_px(wx_incol, xlbl_py, {2'd0,t_d2}, 10'd0,  10'd1) |
            stat_px(wx_incol, xlbl_py, 6'd12,       10'd6,  10'd1) |
            stat_px(wx_incol, xlbl_py, 6'd13,       10'd12, 10'd1)
        )
    );

    // ================================================================
    // BOTTOM STATUS BAR (y=460..479)
    // ================================================================
    wire [9:0] bot_py = y - STAT_BOT_Y0;

    // Time/div digits
    wire       td_big = (tdiv_ms >= 100);
    wire       td_med = (tdiv_ms >= 10) && ~td_big;
    wire [3:0] td_d0  = td_big ? (tdiv_ms / 10'd100)            : 4'd0;
    wire [3:0] td_d1  = td_big ? ((tdiv_ms%10'd100)/10'd10)     :
                        td_med ? (tdiv_ms / 10'd10)             : 4'd0;
    wire [3:0] td_d2  = tdiv_ms % 10'd10;

    wire bot_px = in_stat_bot && (
        // ---- Time/div [x=2..200] ----
        (x < 10'd200) && (
            td_big ? (
                stat_px(x, bot_py, {2'd0,td_d0}, 10'd2,  10'd6) |
                stat_px(x, bot_py, {2'd0,td_d1}, 10'd8,  10'd6) |
                stat_px(x, bot_py, {2'd0,td_d2}, 10'd14, 10'd6) |
                stat_px(x, bot_py, 6'd12,        10'd20, 10'd6) |
                stat_px(x, bot_py, 6'd13,        10'd26, 10'd6) |
                stat_px(x, bot_py, 6'd14,        10'd32, 10'd6) |
                stat_px(x, bot_py, 6'd34,        10'd38, 10'd6) |
                stat_px(x, bot_py, 6'd17,        10'd44, 10'd6)
            ) : td_med ? (
                stat_px(x, bot_py, {2'd0,td_d1}, 10'd2,  10'd6) |
                stat_px(x, bot_py, {2'd0,td_d2}, 10'd8,  10'd6) |
                stat_px(x, bot_py, 6'd12,        10'd14, 10'd6) |
                stat_px(x, bot_py, 6'd13,        10'd20, 10'd6) |
                stat_px(x, bot_py, 6'd14,        10'd26, 10'd6) |
                stat_px(x, bot_py, 6'd34,        10'd32, 10'd6) |
                stat_px(x, bot_py, 6'd17,        10'd38, 10'd6)
            ) : (
                stat_px(x, bot_py, {2'd0,td_d2}, 10'd2,  10'd6) |
                stat_px(x, bot_py, 6'd12,        10'd8,  10'd6) |
                stat_px(x, bot_py, 6'd13,        10'd14, 10'd6) |
                stat_px(x, bot_py, 6'd14,        10'd20, 10'd6) |
                stat_px(x, bot_py, 6'd34,        10'd26, 10'd6) |
                stat_px(x, bot_py, 6'd17,        10'd32, 10'd6)
            )
        ) ||
        // ---- V/div [x=210..400] "X.XXV/div" ----
        (x >= 10'd210 && x < 10'd400) && (
            stat_px(x-10'd210, bot_py, {2'd0,vdiv_dU}, 10'd2,  10'd6) |
            stat_px(x-10'd210, bot_py, 6'd10,          10'd8,  10'd6) |
            stat_px(x-10'd210, bot_py, {2'd0,vdiv_dT}, 10'd14, 10'd6) |
            stat_px(x-10'd210, bot_py, {2'd0,vdiv_dO}, 10'd20, 10'd6) |
            stat_px(x-10'd210, bot_py, 6'd11,          10'd26, 10'd6) |
            stat_px(x-10'd210, bot_py, 6'd14,          10'd32, 10'd6) |
            stat_px(x-10'd210, bot_py, 6'd34,          10'd38, 10'd6) |
            stat_px(x-10'd210, bot_py, 6'd17,          10'd44, 10'd6)
        ) ||
        // ---- TL:X.XXV [x=410..620] ----
        (x >= 10'd410 && x < 10'd620) && (
            stat_px(x-10'd410, bot_py, 6'd15,            10'd2,  10'd6) |  // T
            stat_px(x-10'd410, bot_py, 6'd28,            10'd8,  10'd6) |  // L
            stat_px(x-10'd410, bot_py, 6'd38,            10'd14, 10'd6) |  // :
            stat_px(x-10'd410, bot_py, {2'd0,vtrig_dU},  10'd20, 10'd6) |
            stat_px(x-10'd410, bot_py, 6'd10,            10'd26, 10'd6) |  // .
            stat_px(x-10'd410, bot_py, {2'd0,vtrig_dT},  10'd32, 10'd6) |
            stat_px(x-10'd410, bot_py, {2'd0,vtrig_dO},  10'd38, 10'd6) |
            stat_px(x-10'd410, bot_py, 6'd11,            10'd44, 10'd6)    // V
        )
    );

    // ================================================================
    // COLOUR PRIORITY MUX
    // ================================================================
    always @(*) begin
        if (!video_on)
            rgb = 12'h000;

        // Top status bar
        else if (y < STAT_TOP_H) begin
            if      (tb_px)         rgb = 12'hFF0;
            else if (tl_bar_active) rgb = 12'hF80;
            else if (tl_px)         rgb = 12'hFFF;
            else if (edge_px)       rgb = trig_edge ? 12'hF44 : 12'h4F4;
            else if (acq_px) begin
                case (acq_state)
                    2'd0:    rgb = 12'h0B0;
                    2'd1:    rgb = 12'h0FF;
                    2'd2:    rgb = 12'hFF0;
                    default: rgb = 12'h888;
                endcase
            end
            else if (trg_px)        rgb = triggered ? 12'h0FF : 12'hAAA;
            else if (vin_px)        rgb = 12'hF8F;
            else                    rgb = 12'h112;
        end

        // Voltage header row
        else if (in_vhdr) begin
            if      (vhdr_px)     rgb = 12'hFF8;
            else if (x < WAVE_X0) rgb = 12'h112;
            else                  rgb = 12'h001;
        end

        // Waveform area + Y margin
        else if ((y >= WAVE_Y0) && (y <= WAVE_Y1)) begin
            if      (border)       rgb = 12'h448;
            else if (wave_hit)     rgb = 12'h0F2;    // bright green trace
            else if (trig_arrow)   rgb = 12'hF80;    // orange trigger arrow
            else if (ylabel_bot)   rgb = 12'hFF8;    // bottom 0V label
            else if (ylabel_px)    rgb = 12'hFF8;    // Y-axis voltage labels
            else if (trig_line)    rgb = 12'hBB0;    // dashed trig line
            else if (pretrig_mark) rgb = 12'h226;    // dim blue pretrig
            else if (grid_px)      rgb = 12'h025;    // dotted grid
            else if (x < WAVE_X0)  rgb = 12'h112;    // Y margin background
            else                   rgb = 12'h000;    // waveform background
        end

        // X-axis label row
        else if (in_xlbl) begin
            if   (xlbl_px) rgb = 12'h8FF;
            else            rgb = 12'h112;
        end

        // Bottom status bar
        else if (in_stat_bot) begin
            if   (bot_px) rgb = 12'h8FF;
            else           rgb = 12'h112;
        end

        else rgb = 12'h000;
    end

endmodule