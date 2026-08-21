--[[
ui/pagestats.lua -- GENERATED FILE, DO NOT EDIT BY HAND.
    python tools/make_pages.py

What the page sheets look like where the panel puts text, as RGB triples. It
exists because the presets in ui/theme.lua multiply a tint through these sheets
and the result has to clear a contrast floor, and Lua cannot decode a PNG, so the
measurement has to be taken here and carried across.

RGB and not luminance: the panel multiplies per channel, and the luminance of
the product is not any function of the luminances. Each triple is a real pixel
of the sheet at that luminance percentile, so tinting it gives an exact answer
rather than an estimate.

Measured as two columns of a 380x502 pane at scale 1.0, y 11..481:

  glyph   x 14..56   the step glyph, the step number, the row state bar
  main    x 56..352  every string the panel draws

Two and not one because the gutter shadow spans the first 13% of a page: on the
right-hand page that is x 0..49 of 380, the glyph column and no further. One
figure for the whole box would hold the prose to a floor set by a shadow it
never touches.

`w`, `h` and `bytes` are the sheet's own, so a consumer can tell whether these
numbers still describe the file on disk.
]]

return {
    ['page_left.png'] = {
        w = 1091, h = 1274, bytes = 2469166,
        glyph = {
            darkest   = {106,  55,  18},   -- luminance 0.0584
            p05       = {195, 137,  66},   -- luminance 0.2989
            mean      = {222, 174,  98},   -- luminance 0.4668
            p50       = {225, 177,  93},   -- luminance 0.4824
            p95       = {239, 200, 132},   -- luminance 0.6133
            lightest  = {253, 225, 155},   -- luminance 0.7710
        },
        main = {
            darkest   = {112,  62,  20},   -- luminance 0.0694
            p05       = {225, 179, 102},   -- luminance 0.4921
            mean      = {237, 198, 127},   -- luminance 0.5992
            p50       = {238, 200, 128},   -- luminance 0.6104
            p95       = {243, 213, 150},   -- luminance 0.6885
            lightest  = {253, 228, 167},   -- luminance 0.7916
        },
    },
    ['page_right.png'] = {
        w = 1091, h = 1441, bytes = 2840624,
        glyph = {
            darkest   = { 58,  24,   4},   -- luminance 0.0156
            p05       = {172, 116,  48},   -- luminance 0.2147
            mean      = {209, 165,  93},   -- luminance 0.4126
            p50       = {211, 169,  96},   -- luminance 0.4307
            p95       = {240, 201, 130},   -- luminance 0.6191
            lightest  = {250, 225, 163},   -- luminance 0.7682
        },
        main = {
            darkest   = { 89,  40,   9},   -- luminance 0.0366
            p05       = {217, 163,  85},   -- luminance 0.4160
            mean      = {234, 194, 122},   -- luminance 0.5748
            p50       = {238, 197, 125},   -- luminance 0.5959
            p95       = {245, 212, 142},   -- luminance 0.6845
            lightest  = {253, 228, 167},   -- luminance 0.7916
        },
    },
}
