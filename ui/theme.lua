--[[
ui/theme.lua -- type, colour and metrics for the quest log panel.

Design intent, which every choice below answers to: a page from the game's own
quest log that someone took the trouble to set properly. A flat dark Vana'diel
slab holding a column of quest names you can read straight down, and one facing
page of plain English that says what to do next and never cuts a sentence off.

The check: point at any pixel and say which of four questions it answers. Which
quest is this, can I act on it now, what do I do next, where. If it answers none
of them, delete it. If it answers one of them in field order rather than in
English, rewrite it.

One family, no monospace. Column alignment is the only argument for a fixed
pitch face, and it does not survive contact with the platform: every text object
is positioned at an absolute x, so a fixed x gives a perfect column in any face.
Consolas averages 0.5498 em against Segoe UI's 0.5136 (both measured,
tools/genmetrics.py), so it spends about 7% of the name column to look like a
terminal. FFXI contains no monospace anywhere.

No serif either, tempting as a book face is for the description prose. FFXI
renders its own quest text in the same face as its menus; a second voice the game
does not have reads as a different program's window.

Nothing stands in for WoW's level colouring. FFXI records no recommended level,
so a difficulty hue would be a confident lie.

The hue budget is three, and only three.
    amber  = now / act
    green  = past tense, and it appears on exactly one glyph
    brick  = stuck, and it appears on one 3px rectangle, never on text
Gold is the interaction colour, FFXI's own cursor convention, not a state.
Everything else is a tier of grey-blue.

  A chip on every row carrying questmarks' full six-state marker palette is the
  tempting alternative, and it does guarantee the list can never disagree with
  the world. Resist it: nineteen saturated chips in a column is confetti,
  colouring the eighteen rows you cannot act on as loudly as the one you can.
  The link is narrowed rather than abandoned. `Ready` still takes its amber from
  the marker table, so the one state that sends the player somewhere cannot
  drift. The rest say nothing, which is what they have to say.

Stroke on every text object. This panel floats over everything from a black cave
to bright desert sand. Opacity does most of the work (see the colour block) and
a dark stroke is the backstop; it is one property per object, not an extra
object, and it is the same trick FFXI's own outlined font uses.
]]

local theme = {}

local metrics = require('ui/metrics')
theme.metrics = metrics

theme.scale = 1.0
local function s(v) return math.floor(v * theme.scale + 0.5) end
theme.s = s

-- ---------------------------------------------------------------------------
-- Type
-- ---------------------------------------------------------------------------

theme.font      = 'Segoe UI'
theme.font_head = 'Segoe UI Semibold'

--[[ ASCII only. Windower's text rendering does not handle UTF-8 multibyte
     (chronicle records the same at chronicle/ui/theme.lua:324), so there are no
     box glyphs, no arrows, no bullets and no ellipsis character. Where a rule or
     an underline is wanted it is a rectangle, which is why none of these are
     drawing characters. ]]
theme.sym = {
    collapsed = '+',      -- region fold, closed
    expanded  = '-',      -- region fold, open
    close     = 'x',
    held      = '*',

    --[[ Three step glyphs, and each is a different character from every other
         glyph in the panel so no one has to reason about which pane they are
         looking at.

         `x` for done, not `+`: `+` is the region fold.
         `-` for not reached, not `.`: at 11pt with a stroke a full stop is a
             two-pixel smudge, while a hyphen is centred, quiet, and forms a
             legible unlit ladder.
         `>` for a candidate step. ]]
    done      = 'x',
    current   = '>',
    pending   = '-',
}

local function apply_scale()
    -- Point sizes. set_font_size takes points, not pixels. Hand it pixels and
    -- every string overflows its column.
    theme.fs_title  = s(13)   -- panel title, detail quest title
    theme.fs_region = s(11)   -- region header, steps position phrase
    theme.fs_name   = s(11)   -- quest name, step title
    theme.fs_step   = s(11)
    theme.fs_prose  = s(10)   -- description, empty states, step note
    theme.fs_sub    = s(10)
    theme.fs_zone   = s(9)    -- zone/grid line, meta tokens, tags
    theme.fs_meta   = s(9)
    theme.fs_count  = s(9)
    theme.fs_action = s(10)   -- clickable words
    theme.fs_tag    = s(8)    -- the '(completed)' qualifier beside the bar

    theme.list_width   = s(430)
    theme.detail_width = s(380)
    theme.pane_gap     = s(2)

    theme.header_h     = s(26)
    theme.filter_h     = s(22)
    theme.row_h        = s(22)
    theme.row_gap      = 0
    theme.pad          = s(14)
    theme.scroll_w     = s(4)

    theme.bar_state    = s(3)
    theme.bar_sel      = s(2)

    --[[ A quest row is indented under its region, and these two columns are the
         indent.

         The list is a two-level tree and says so by position. At scale 1.0 the parent's
         fold glyph is at 10, its badge at 24 and its label at 44; a child's mark is at 54
         and its name at 66, which is one clear step in and reads as a tree without any
         rule or connector to draw. Those five are derived rather than picked, see the
         note below.

         `mark_x` is a named column and not a bare `theme.s()` at the one draw that uses
         it. A column spelled out at its use site is a column that moves in one place and
         not the other. It is also measured against `ui/pagestats.lua`'s glyph band
         (x 14..56), so a value that wanders out of that band silently changes which
         contrast floor the mark answers to. At 54 it is inside it, at the far edge,
         which is the conservative side for the reason the paragraph below gives.

         The indent costs 36 px of the name column: 280 px wide where an unindented row
         would give 316, which is 11.4%. Worth stating plainly, because the header rejects
         a monospace face partly for spending 7% of this same column and this spends more.
         It buys two things that argument did not get: the structure of the list stated in
         position rather than inferred, and room for the badge below. Chosen off three
         candidates rendered at true size; the two cheaper ones put a child's mark under
         its parent's first two characters, which reads as alignment rather than as
         nesting.

         `ui/pagestats.lua` measures two bands, x 14..56 for single glyphs and x 56..352
         for prose, and a quest name sits entirely inside the prose band. The mark sits at
         the far edge of the glyph band and is checked against it, which is the
         conservative side: on the left-hand sheet that band is the darker of the two,
         because it catches the page's outer edge. ]]

    --[[ The region badge, and the two columns either side of it.

         A group line is three things: the fold glyph in its own column, the region's
         badge, and the label. The badge is what makes a category line unmistakable at a
         glance beside a quest line.

         16 px inside a 22 px row, which is the whole budget there is: the wiki
         originals are 132 to 136 px square and the shipped copies are 64, so the client
         is always downscaling and never blowing one up (theme.scale tops out at 2.5,
         which asks for 40).

         `group_label_x` is a column and not an offset. A region with no badge leaves the
         space empty rather than sliding its label left, so the labels stay in one column
         whatever the artwork does. Three regions are in that state: quest/coalition,
         mission/assault and mission/nation. ]]
    theme.status_r     = s(346)
    theme.prog_x       = s(356)
    theme.prog_w       = s(48)
    theme.prog_h       = s(4)
    theme.region_x     = s(22)
    theme.fold_x       = s(10)
    --[[ The columns after the fold glyph are measured off it, not picked.

         Derive each column from the width of the widest fold glyph. `+` is far wider than
         `-` in a proportional face, 10.2 px against 6.0 at 11 pt, so a badge column
         hand-picked to clear the `-` has the `+` sitting on top of it, and only on the
         collapsed regions. A picked gap does not scale with a glyph either, so
         `//qmui scale` makes that overlap worse rather than better.

         The badge therefore starts past the widest fold glyph plus a gap, the label past
         the badge, and the child columns past the label. Every one is derived from the
         one before it, which is the same argument the vertical geometry makes: measure
         the font rather than estimate it, and the layout cannot come apart at a scale
         nobody tried. ]]
    local fold_w = math.max(metrics.width(theme.sym.collapsed, theme.fs_region, false),
                            metrics.width(theme.sym.expanded, theme.fs_region, false))
    theme.group_ico     = s(16)
    theme.group_ico_x   = theme.fold_x + math.ceil(fold_w) + s(3)
    theme.group_label_x = theme.group_ico_x + theme.group_ico + s(4)
    theme.mark_x        = theme.group_label_x + s(10)
    theme.name_x        = theme.mark_x + s(12)
    theme.count_r      = s(404)
    theme.row_text_y   = s(3)
    theme.row_name_y   = s(3)
    theme.fs_group     = theme.fs_region
    -- There is no state chip (see the hue budget); these stay at zero so any
    -- caller that still reads them lays out as if it were never there.
    theme.chip         = 0
    theme.chip_gap     = 0
    theme.group_indent = 0

    -- Detail pane, pane-local
    theme.d_rail       = s(18)
    theme.d_glyph      = s(26)
    theme.d_num_r      = s(48)
    theme.d_title      = s(56)
    theme.d_title_opt  = s(66)
    theme.d_tag_r      = s(352)
    theme.d_line       = s(16)
end
theme.apply_scale = apply_scale

function theme.set_scale(v)
    theme.scale = math.max(0.6, math.min(2.5, tonumber(v) or 1.0))
    apply_scale()
end
apply_scale()

--[[ How opaque the panel SURFACES are: the two pane backgrounds and the header
     band, and nothing else.

     Text, glyphs and the scroll thumb keep their own alpha deliberately. Every
     contrast floor this suite asserts is measured between an ink colour and a
     chrome colour, so dimming the ink would leave those numbers describing
     something that is no longer drawn. Dimming only the surface leaves the ink
     exactly as measured and lets the world show through behind it, which is
     what a transparency control is for.

     The floor is 0.15 and not 0. A pane at zero draws nothing at all while
     still swallowing every click over it, which set_pane_bg already calls the
     worst failure this panel can have, and it is silent. 0.15 is faint enough
     to see through and visible enough to find. ]]
theme.opacity = 1.0

function theme.set_opacity(v)
    theme.opacity = math.max(0.15, math.min(1.0, tonumber(v) or 1.0))
    return theme.opacity
end

-- A colour table with its alpha scaled by `theme.opacity`. Never mutates the
-- caller's table: these are the shared preset colours.
function theme.surface(c)
    if theme.opacity >= 1.0 then return c end
    return {a = math.floor((c.a or 255) * theme.opacity + 0.5),
            r = c.r, g = c.g, b = c.b}
end

--[[ Pixel width of a string at a point size. Goes through the shipped advance
     table rather than get_extents, because layout must know a string's width
     before drawing it, and for strings it decides not to draw at all. ]]
function theme.width(str, size, bold)
    return metrics.width(str, size, bold)
end

function theme.fit_count(str, size, px, bold)
    return metrics.fit_count(str, size, px, bold)
end

--[[ Vertical geometry, measured rather than estimated.

     `set_location` places text by the top of its line box, and the glyphs start
     well below that: for Segoe UI, 0.3475 em down, with the ink itself only
     0.9675 em of a 1.3325 em box. Those three numbers are measured from the
     installed TrueType file by tools/genmetrics.py, not guessed.

     Getting this wrong is invisible until something has to line up with what the
     eye sees rather than with the line box. Size a hover band from the line
     pitch and it draws about seven pixels above its own text. Centre a strip on
     a hand-picked constant, y + 3 here and y + 4 there, and the title, the close
     glyph and the filter words all ride high.

     Centring is on the cap box, not the ink box: most interface strings have no
     descender, so centring the full ink box makes them sit visibly high. ]]
theme.line_h      = function(size) return metrics.line_height(size) end
theme.ink_y       = function(size) return metrics.ink_y(size) end
theme.ink_h       = function(size) return metrics.ink_height(size) end
theme.center_y    = function(y, h, size) return metrics.center_y(y, h, size) end
theme.underline_y = function(y, size) return metrics.underline_y(y, size) end

-- ---------------------------------------------------------------------------
-- Colour
-- ---------------------------------------------------------------------------
local function c(a, r, g, b) return {a = a, r = r, g = g, b = b} end

--[[ Opacity first. At alpha 236 the scene contributes 7.5% of the composite, so
     the list background lands at relative luminance 0.006 over a black cave and
     0.014 over bright desert sand. That range is narrow enough for one set of
     text colours to clear 9:1 on both: primary text measures 17.1:1 over the
     cave and 14.8:1 over the desert. Tuning colours per environment is the trap;
     making the environment stop mattering is the fix. ]]
theme.col = {
    border      = c(180,   0,   0,   0),
    band_hair   = c(210, 150, 158, 205),
    band_mid    = c(215,  78,  84, 132),
    header_bg   = c(236,  42,  38,  90),
    panel_bg    = c(236,  16,  14,  44),
    detail_bg   = c(236,  24,  21,  58),
    divider     = c(120,  96, 104, 150),
    rule        = c(110, 120, 128, 176),

    --[[ No zebra striping. Striping helps the eye track across a row, and a row
         here is one line of one string, so there is nothing to track across.
         Alternating two near-identical darks on a 22px row buys nothing and adds
         a texture the design is trying to remove. Rows are flat; hover and
         selection are the only row fills. ]]
    row_even    = c(  0,   0,   0,   0),
    row_odd     = c(  0,   0,   0,   0),
    row_hover   = c( 90,  70,  78, 130),
    row_sel     = c(140,  96, 108, 172),
    group_bg    = c(  0,   0,   0,   0),

    bar_sel     = c(255, 190, 200, 240),
    bar_ready   = c(255, 255, 176,  48),
    bar_blocked = c(220, 198, 104,  92),

    prog_track  = c( 28, 255, 255, 255),
    prog_done   = c(225, 200, 210, 245),
    prog_maybe  = c( 80, 200, 210, 245),

    rail        = c( 26, 255, 255, 255),
    rail_maybe  = c(110, 255, 176,  48),

    --[[ The pane backgrounds, as a texture multiplied down.

         `theme.bg_source` is a papyrus sheet: light, warm, and 21x too bright to put
         white text on. Measured over the area the text occupies its luminance is
         0.5690, and the faintest text role needs a background under 0.0277 to clear
         4.5:1. Dropped in as authored it renders the zone and requirement lines at
         1.8:1, which is invisible.

         `windower.prim.set_color` multiplies. render/markers.lua says so in as many
         words and relies on it to tint a white glyph body to a state colour. So the
         sheet is multiplied by a dark tint, and these two tints
         are derived to land its mean on the flat fills the panel falls back to:
         rgb(16,14,44) for the list and rgb(24,21,58) for the detail pane. The grain,
         the edge wear and the corner staining survive as modulation around that mean.

         Nothing else in the design has to move for it. Measured on the real file, the
         faintest text sits at 6.2:1 over the list pane and 5.8:1 over the detail
         pane, and across the grain's 5th to 95th percentile spread the worst case is
         5.6:1, all of it better than the 5.8:1 a flat fill gives. The alpha stays 236
         for the reason the opacity note gives: the scene contributing 7.5% of the
         composite is what keeps contrast stable between a black cave and bright
         desert sand.

         The two panes keep their slightly different values rather than sharing one.
         The difference is what stops the pair reading as one shape with a seam.

         These two are the default and also the fallback. `theme.set_bg` overwrites
         them from `theme.bg_themes` below; they are spelled out here so a missing or
         unrecognised setting leaves the panel on navy rather than on nil. ]]
    panel_tint  = c(236,  17,  18,  93),
    detail_tint = c(236,  26,  28, 122),

    text        = c(255, 240, 244, 255),
    text_bright = c(255, 255, 255, 255),
    text_dim    = c(255, 180, 190, 218),
    text_faint  = c(255, 140, 148, 178),
    gold        = c(255, 232, 200, 128),
    accent      = c(255, 232, 200, 128),
    accent_dim  = c(255, 255, 176,  48),
    amber       = c(255, 255, 176,  48),
    amber_cap   = c(190, 255, 176,  48),

    --[[ The step ladder's two state hues, in roles of their own rather than in `amber`
         and a general-purpose green.

         They are the budget's amber and green on every preset that does not say
         otherwise, and on three of the four they are those values exactly. The split
         exists because one preset needs the ladder and the list to disagree: over
         parchment the ladder's strings are 11pt, carry a hue rather than a tier of grey,
         and are drawn inside `stroke_hue`, so they can be bright; the list's `n ready`
         tally is 9pt prose with no outline at all, so it cannot. A single role cannot be
         both. The contrast sweep also keys on the role name, so a role that is outlined
         in one place and bare in another cannot be checked honestly either.

         `step_now` is theme.col.amber itself and `step_todo` is theme.col.text_faint
         itself, both assigned below the table. One value each and not a copy of three
         numbers, so retuning the budget's amber or the grey ramp moves the ladder with
         it. ]]
    step_done   = c(255, 120, 196, 128),

    stroke      = c(235,   4,  10,  24),
    --[[ The outline on anything that carries a hue, as opposed to a tier of grey: the
         step ladder's title, glyph and number, and the list's `!` / `?` mark.

         Named for what it is rather than for the ladder it started on, because the mark
         needs it for the same reason: over parchment the mark is questmarks' own colour
         on a cream page, and the ring is what gives it edges. It is a role of its own
         and not `stroke`, because the preset that wants no outline on its prose wants
         one here. ]]
    stroke_hue  = c(235,   4,  10,  24),
    chip_bg     = c(  0,   0,   0,   0),

    scroll_bg   = c( 80,   0,   0,   0),
    scroll_th   = c(150, 150, 160, 205),
}

--[[ The ladder's "now" is the panel's amber and its "not yet" is the panel's faint grey:
     the same tables, not copies of three numbers each. Borrowing rather than copying for
     the same reason `mixed` borrows its parents' palettes: two values that must stay
     identical are two values that will not. A preset that needs them to differ overrides
     them separately, which is what parchment does for `amber` and `text_faint` while
     leaving the ladder on these. ]]
theme.col.step_now = theme.col.amber
theme.col.step_todo = theme.col.text_faint

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

--[[ The pane backgrounds, and the two panes are two pages of one open book.

     `bg_source` is the papyrus the owner photographed. It is never drawn: the two sheets
     that are drawn are derived from it by tools/make_pages.py, which mirrors the left
     one and bakes a gutter shadow into the inner edge of each so the pair leans into a
     fold instead of butting together. Cropped to each pane's own aspect rather than
     stretched, because the grain is the whole reason for using a photograph and 2.14x of
     horizontal stretch destroys it.

     The shadows are baked into the sheets and not drawn as prims because there is no
     gradient primitive on this platform; faking one would cost forty stacked rects to
     do badly what one multiply does exactly.

     -> the full path for a pane, or nil when that file is not on disk. Nil is
     load-bearing: a prim whose texture will not load draws nothing at all and reports
     nothing, so a missing sheet would leave the window invisible while still swallowing
     every click over it. The caller falls back to the flat fills instead.

     Probed once per name and remembered, because this is a file-system hit and the panel
     draws every frame. Keyed on the name, so pointing a pane at another sheet re-probes
     instead of returning the previous answer forever. ]]
theme.bg_source = 'papyrus.png'
theme.bg_pages = {list = 'page_left.png', detail = 'page_right.png'}

--[[ The region badges, keyed by the region's own `cat/area` key.

     Keyed by the key and not by the label. Two regions are called `Campaign` and three
     names appear on both a quest and a mission row (`A Shantotto Ascension` among them),
     so a table keyed by what is printed would collide; `cat/area` is what model.lua
     groups by and it is unique. It is also stable: a label is a display string somebody
     may reword.

     Several regions share a badge, and that is the wiki's own doing rather than a
     shortcut here. San d'Oria's crest serves its quests and its missions; Crystal War
     quests wear the Wings of the Goddess art; and Rise of the Zilart has no image of its
     own on Category:Missions, where the wiki uses Jeuno's crest for it, so this does too
     rather than inventing one.

     `quest/coalition`, `mission/assault` and `mission/nation` are deliberately absent:
     the table below is short of model.lua's REGION list by exactly those three. A region
     with no badge draws none and keeps its label column. Guessing one would be the panel
     asserting something the source does not say.

     Generated from these by tools/make_category_icons.py; `assets/category/SOURCES.json`
     records which wiki file each came from and `NOTICE` carries the attribution. ]]
theme.group_icons = {
    ['mission/sandoria']   = 'sandoria.png',
    ['mission/bastok']     = 'bastok.png',
    ['mission/windurst']   = 'windurst.png',
    ['mission/zilart']     = 'jeuno.png',
    ['mission/cop']        = 'promathia.png',
    ['mission/toau']       = 'ahturhgan.png',
    ['mission/wotg']       = 'wotg.png',
    ['mission/campaign']   = 'campaign.png',
    ['mission/campaign_2'] = 'campaign.png',
    ['mission/acp']        = 'acp.png',
    ['mission/mkd']        = 'mkd.png',
    ['mission/asa']        = 'asa.png',
    ['mission/adoulin']    = 'adoulin.png',
    ['mission/rov']        = 'rov.png',
    ['mission/tvr']        = 'tvr.png',
    ['quest/sandoria']     = 'sandoria.png',
    ['quest/bastok']       = 'bastok.png',
    ['quest/windurst']     = 'windurst.png',
    ['quest/jeuno']        = 'jeuno.png',
    ['quest/outlands']     = 'outlands.png',
    ['quest/other']        = 'other.png',
    ['quest/toau']         = 'ahturhgan.png',
    ['quest/crystal_war']  = 'wotg.png',
    ['quest/abyssea']      = 'abyssea.png',
    ['quest/adoulin']      = 'adoulin.png',
    ['quest/acp']          = 'acp.png',
    ['quest/mkd']          = 'mkd.png',
    ['quest/asa']          = 'asa.png',
}

--[[ The tints the sheet can be multiplied by, as named presets.

     One entry per look, two tints per entry, because the panes are not the same colour
     and the difference is part of what stops the pair reading as one shape with a
     seam. Every tint is derived the same way: measure the sheet's mean over the region
     the text occupies, then solve for the multiplier that lands it on a chosen fill.

       navy      the flat fills the panel falls back to, exactly: rgb(16,14,44) and
                 rgb(24,21,58). Nothing else in the design has to move for it, which
                 is why it is the default.
       leather   dark stained hide, rgb(28,19,16) and rgb(40,28,24), and it carries a
                 warmed chrome with it, see `chrome` below. A blue header band and a
                 blue row selection over brown parchment read as a mismatch.

     Every preset is contrast-checked by the suite, not just the active one. The
     multiply is per-channel and monotonic, so the brightest a tinted pixel can be is
     white through the tint, which is the tint itself, and tools/smoke.lua asserts each
     of these clears 4.5:1 against the faintest text. Adding a preset that is too
     bright fails the suite rather than shipping. ]]
--[[ And the chrome moves with the tint.

     A preset is not two numbers. The header band, the filter chip's fill, the row
     selection, the hover fill, the top-band moulding, the pane divider, the one rule
     and the scroll thumb are all blue-grey in the base palette, and blue chrome over
     brown parchment reads as a mismatch.

     `chrome` names only what a preset changes; anything it does not name falls back to
     the value authored in `theme.col`, which is navy's. So navy carries no chrome table
     at all: it is the base.

     The warm values are matched on luminance, not picked by eye. Each is at or below
     its navy counterpart, so every contrast reading on this palette is equal or better:
     the panel title over the header band reads 13.2:1 against navy's 12.5:1, and the
     faint where-text over a selected row 2.3:1 against navy's 1.7:1. Measured, and the
     suite checks the two that carry text. Keeping the luminance means the panel's whole
     legibility argument transfers without being re-run. ]]
theme.bg_themes = {
    navy    = {panel = c(236, 17, 18,  91), detail = c(236, 26, 28, 122)},

    --[[ The sheet as authored, with dark ink. The tint is 255,255,255, the identity for
         the multiply, so the papyrus appears exactly as photographed and every colour
         the panel draws inverts.

         This is the preset that moves everything, and it is the reason a preset can
         override any role rather than just the chrome. On a page at luminance 0.5 the
         panel's light greys measure 1.1:1 to 1.8:1, which is invisible, so the whole ink
         ramp, the accents, the two glyph hues and the outline colour all change.

         Every value here is solved, not picked. `ui/pagestats.lua` carries the real
         colour of the real sheets in the two columns the panel actually draws in, and
         each ink is scaled until it clears its floor against the darkest 5% of the
         column it appears in:

           main column   x 56..352, every string          4.5:1
           glyph column  x 14..56, step glyph and number  3.0:1

         Two floors because they are two different things. The main column carries prose
         at 9 and 10pt and gets the full bar. The glyph column carries single 11pt bold
         characters, `x`, `>`, `-` and the marker's `!` / `?`, which is what WCAG's
         large-text threshold of 3:1 is for, and their meaning is carried by position and
         by the step number beside them as well as by colour. Worst measured readings:
         text 8.1:1 main and 4.6:1 glyph, the faint ramp 5.5:1 and 3.1:1, the accents
         4.8:1 main.

         `stroke` goes to zero alpha. The outline is what keeps light text legible over a
         bright world; dark ink over a light page needs no halo, and a dark one at 9pt
         thickens the ink into a smudge. This is the role that makes `Text:stroke` worth
         having.

         One thing it fixes in passing: the faint where-text over a selected row measures
         1.7:1 in navy and 5.5:1 here, because a selected row on a page is a darker wash
         rather than a lighter one. ]]
    parchment = {
        panel = c(236, 255, 255, 255), detail = c(236, 255, 255, 255),
        --[[ No `marker_lum`. The mark wears questmarks' own hue here as it does
             everywhere, and what carries it on a cream page is `stroke_hue`. See the
             note above `lin`. ]]
        chrome = {
            band_hair = c(210, 120,  84,  40),
            band_mid  = c(215,  86,  56,  24),
            header_bg = c(236, 196, 152,  92),
            divider   = c(120, 150, 116,  70),
            rule      = c(110, 150, 116,  70),
            row_hover = c( 90, 224, 190, 140),
            row_sel   = c(140, 206, 168, 112),
            scroll_th = c(150, 120,  88,  46),
        },
        ink = {
            text        = c(255,  28,  19,   9),   -- L 0.0073, main 8.1:1  glyph 4.6:1
            text_bright = c(255,  10,   6,   2),   -- L 0.0020, main 9.0:1  glyph 5.1:1
            text_dim    = c(255,  54,  40,  24),   -- L 0.0237, main 6.3:1  glyph 3.6:1
            text_faint  = c(255,  66,  50,  30),   -- L 0.0353, main 5.5:1  glyph 3.1:1
            gold        = c(255, 104,  44,   6),   -- L 0.0476, main 4.8:1
            accent      = c(255, 104,  44,   6),
            accent_dim  = c(255, 104,  44,   6),
            amber       = c(255,  74,  44,   4),   -- L 0.0327, main 5.6:1  glyph 3.2:1
            amber_cap   = c(255,  88,  52,   6),   -- L 0.0454, main 4.9:1
            --[[ `step_done`, `step_now` and `step_todo` are deliberately absent, which
                 is a decision and not an oversight.

                 A dark forest green and a dark bronze solved against the page, the way
                 everything else here is solved, is the obvious thing to write and it is
                 wrong. The bright pair reads better on parchment than a darkened one
                 does, and a dark `step_todo` makes the steps ahead of you read as
                 crossed out rather than as pending. So all three fall through and the
                 ladder is one colour scheme on every preset. `text_faint` itself stays
                 dark, because the zone lines and requirement lines that use it are prose
                 and are read off the page.

                 The fall-through hands back the values authored in `theme.col`, navy's
                 and leather's exactly. No third copy of three colours to drift.

                 What carries them on this page is the outline below, and here it is the
                 only thing that does. rgb(120,196,128) over this page measures 1.07:1,
                 rgb(255,176,48) 1.23:1 and the grey 1.32:1, invisible by any floor,
                 while against their own halo they are 8.2:1, 9.4:1 and 5.7:1, and the
                 halo is 4.7:1 to 12.0:1 against the page. tools/smoke.lua checks both
                 links, and only for the roles that are always drawn inside a halo. ]]
            --[[ No halo on prose. See the note above. ]]
            stroke      = c(  0,   0,   0,   0),
            --[[ And a full-strength one on everything that carries a hue: the ladder,
                 and the list's `!` / `?` mark. This halo is what makes those strings
                 readable at all, so its alpha is not a matter of taste. 235 is the alpha
                 the panel's ordinary outline uses; at 150 the green measures 3.04:1
                 against its own halo, under the 4.5 its prose column asks for. ]]
            stroke_hue  = c(235,  16,  10,   4),
            -- Decorative: bars and rails carry no text, only position.
            bar_sel     = c(255,  28,  19,   9),
            bar_blocked = c(220, 120,  52,  44),
            prog_done   = c(225,  74,  52,  28),
            prog_maybe  = c( 80, 120,  88,  46),
            prog_track  = c( 34,  60,  40,  20),
            rail        = c( 30,  60,  40,  20),
            rail_maybe  = c(110, 104,  44,   6),
        },
    },

    --[[ One of each. Leather on the list, parchment on the detail: a dark index beside
         a bright page, which is what an open ledger actually looks like.

         It carries no colours of its own. `from` wears leather's chrome and ink on the
         window, `detail_from` wears parchment's on the right-hand pane, and the two
         tints are lifted from the presets they belong to. Nothing here can drift from
         either parent because nothing here is a copy.

         The row marker needs nothing said about it, on this preset or on any other: the
         mark wears questmarks' hue everywhere and the ring is what carries it. ]]
    mixed = {
        panel = c(236, 30, 25, 33), detail = c(236, 255, 255, 255),
        from = 'leather', detail_from = 'parchment',
    },

    leather = {
        panel = c(236, 30, 25, 33), detail = c(236, 44, 37, 51),
        chrome = {
            band_hair = c(210, 168, 146, 112),
            band_mid  = c(215,  96,  74,  52),
            header_bg = c(236,  54,  38,  28),
            divider   = c(120, 112,  90,  66),
            rule      = c(110, 140, 114,  82),
            row_hover = c( 90,  88,  68,  48),
            row_sel   = c(140, 110,  84,  58),
            scroll_th = c(150, 168, 146, 112),
        },
    },
}

--[[ The roles a preset is allowed to override, and the values as authored, captured
     before any preset has touched them.

     Two groups, because they answer to different things. Chrome is the window's
     furniture, the band, header, selection, divider, rule and thumb, and a preset
     changing it is a matter of the panel matching its own background. Ink is everything
     the eye reads, and a preset changing it has to clear a measured contrast floor; the
     suite holds it to one.

     Captured rather than re-derived so switching back restores exactly instead of
     approximating, and listed explicitly so a mistyped role in a preset is a failing
     assertion rather than a line that silently does nothing. ]]
theme.bg_chrome_keys = {'band_hair', 'band_mid', 'header_bg', 'divider', 'rule',
                        'row_hover', 'row_sel', 'scroll_th'}

theme.bg_ink_keys = {'text', 'text_bright', 'text_dim', 'text_faint', 'gold',
                     'accent', 'accent_dim', 'amber', 'amber_cap', 'step_done',
                     'step_now', 'step_todo', 'stroke', 'stroke_hue', 'bar_sel',
                     'bar_blocked', 'prog_done', 'prog_maybe', 'prog_track', 'rail',
                     'rail_maybe'}

local base_roles = {}
for _, k in ipairs(theme.bg_chrome_keys) do base_roles[k] = theme.col[k] end
for _, k in ipairs(theme.bg_ink_keys) do base_roles[k] = theme.col[k] end

local bg_theme = 'navy'

--[[ The detail pane's own colours, and for three of the four presets they are the list
     pane's colours exactly.

     `theme.dcol` reads through to `theme.col` for every key it does not own, so a
     preset that dresses the whole window sets nothing here and the two panes cannot
     drift apart: there is only one value. A preset that dresses the panes differently
     writes its detail-pane roles as own keys, and the fall-through stops applying to
     those alone.

     `mixed` is the reason it exists: dark leather on the list, bright parchment on the
     detail, which means light ink on the left and dark ink on the right. One
     `theme.col` cannot express that, and every alternative, a second theme module or a
     colour argument threaded through every draw call, is more machinery for the same
     answer.

     ui/panel.lua's two detail functions read `theme.dcol` and everything else reads
     `theme.col`. That split is the whole convention. ]]
theme.dcol = setmetatable({}, {__index = theme.col})

--[[ The marker hues are questmarks' own, on every background, and nothing touches them.

     A row's mark takes its colour from questmarks' `render/markers.lua` at runtime,
     deliberately, so the list can never disagree with the world about which quest is
     which. Over parchment those hues measure 1.11:1 to 2.23:1 against the page, and the
     tempting answer is to cap their luminance: keep the hue ratios and scale every
     channel down until quest yellow is rgb(55,46,8). Do not. It preserves the invariant
     on paper and costs the thing the colour is for. Yellow at a luminance a cream page
     can carry is a dark olive whatever you do to its saturation, because it is already
     near-saturated and there is no chroma left to spend.

     What works instead is the answer the ladder reaches: the mark is drawn inside
     `stroke_hue`, and a hue read against a near-black ring is questmarks' hue exactly.
     Measured on the real sheet, in the column the mark lands in: yellow 12.94:1 against
     its ring, green 10.30:1, blue 7.44:1, red 4.91:1, and the ring itself 6.02:1 against
     the page.

     So the panel draws the marker colour byte for byte as questmarks gives it, on all
     four presets. There is no `marker_lum` and no `cap_lum`; a mechanism no preset uses
     is a mechanism that drifts out of true unnoticed. ]]
local function lin(v)
    v = v / 255
    if v <= 0.04045 then return v / 12.92 end
    return ((v + 0.055) / 1.055) ^ 2.4
end

local function relative_lum(r, g, b)
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
end
theme.relative_lum = relative_lum

--[[ -> the name actually in force. Refuses an unknown name and keeps the current one,
     because a settings file from a newer build naming a preset this one has never
     heard of must not blank the panes. ]]
--[[ -> the chrome and ink tables a preset draws with, following `from` if it borrows
     them. Borrowing rather than copying, because two copies of twenty-six values that
     must stay identical are two copies that will not. One hop only: a preset that names
     a preset that names a preset is a mistake worth failing on rather than resolving. ]]
local function roles_of(t)
    if t.from then
        local src = theme.bg_themes[t.from]
        if src then return src.chrome, src.ink end
    end
    return t.chrome, t.ink
end

function theme.set_bg(name)
    local t = theme.bg_themes[tostring(name)]
    if not t then return nil end
    bg_theme = tostring(name)
    theme.col.panel_tint = t.panel
    theme.col.detail_tint = t.detail

    local chrome, ink = roles_of(t)
    --[[ Every role every time, from the preset or from the base. Overlaying only what
         the incoming preset names would leave the outgoing one's colours behind. ]]
    for _, k in ipairs(theme.bg_chrome_keys) do
        theme.col[k] = (chrome and chrome[k]) or base_roles[k]
    end
    for _, k in ipairs(theme.bg_ink_keys) do
        theme.col[k] = (ink and ink[k]) or base_roles[k]
    end

    --[[ The detail pane. Cleared to nothing first, so it falls back through to
         `theme.col`. That is the right answer for every preset that dresses the whole
         window, and it is the state the pane must return to when a preset that dresses
         the two sides differently is switched away from. Own keys are written only when
         `detail_from` names another preset to wear on that side. ]]
    for k in pairs(theme.dcol) do theme.dcol[k] = nil end
    if t.detail_from then
        local d = theme.bg_themes[t.detail_from]
        if d then
            local dchrome, dink = roles_of(d)
            for _, k in ipairs(theme.bg_chrome_keys) do
                theme.dcol[k] = (dchrome and dchrome[k]) or base_roles[k]
            end
            for _, k in ipairs(theme.bg_ink_keys) do
                theme.dcol[k] = (dink and dink[k]) or base_roles[k]
            end
        end
    end

    return bg_theme
end

function theme.bg_theme() return bg_theme end

--[[ The preset names, sorted, for `//qmui bg` and for the suite's sweep over all of
     them. Sorted so the command's output does not reorder itself between runs. ]]
function theme.bg_theme_names()
    local out = {}
    for k in pairs(theme.bg_themes) do out[#out + 1] = k end
    table.sort(out)
    return out
end

theme.set_bg(bg_theme)

--[[ One cache entry per pane, each keyed on the sheet name it was filled from. See the
     note above `theme.bg_pages` for why the key is the name and not a flag. ]]
local bg_path, bg_probed = {}, {}
function theme.bg_texture(which)
    which = which or 'detail'
    local name = theme.bg_pages[which]
    if bg_probed[which] ~= name then
        bg_probed[which] = name
        bg_path[which] = nil
        if name then
            local p = (windower and windower.addon_path or '') .. 'assets/'
                      .. tostring(name)
            local f = io.open(p, 'rb')
            if f then f:close() bg_path[which] = p end
        end
    end
    return bg_path[which]
end

--[[ -> the full path of a region's badge, or nil when it has none or the file is not on
     disk.

     Nil is load-bearing for the same reason it is for the pane sheets: a prim whose
     texture will not load draws nothing at all and reports nothing, so a renamed badge
     would be an invisible object the caller still positions. The caller hides it instead.

     Probed once per key and remembered, because this is a file-system hit and the list
     draws every frame. Keyed on the name the table currently holds, so repointing an
     entry re-probes instead of returning the previous answer forever. Key this cache on
     a flag rather than on the name and it returns the first answer forever. ]]
local ico_path, ico_probed = {}, {}
function theme.group_icon(key)
    local name = theme.group_icons[key]
    if not name then return nil end
    if ico_probed[key] ~= name then
        ico_probed[key] = name
        ico_path[key] = nil
        local p = (windower and windower.addon_path or '') .. 'assets/category/'
                  .. tostring(name)
        local f = io.open(p, 'rb')
        if f then f:close() ico_path[key] = p end
    end
    return ico_path[key]
end

--[[ For tools/smoke.lua and //qmui diag, which both need to distinguish "the sheets are
     drawn" from "a sheet is missing and the flat fill is standing in". Both panes must
     have theirs: one page of an open book is not an open book. ]]
function theme.bg_available()
    return theme.bg_texture('list') ~= nil and theme.bg_texture('detail') ~= nil
end

--[[ Set by model.lua from questmarks' render/markers.lua when reachable. Only
     `turnin` consults it, see the hue budget in the header. ]]
theme.style_for = nil

--[[ -> alpha, r, g, b for a quest's category, at full strength always.

     Deliberately asks questmarks for the `turnin` colour whatever the quest's
     actual state is, because `turnin` is the actionable value in each of its
     tables, yellow for a quest, green for a mission, red for Campaign. The muted
     variants exist to say "not actionable from here", which is a statement about
     a marker in the world and not about a row in your own quest log. See the
     note on state_style below for why this list does not dim.

     There is no blue here, and the reason is worth writing down because the
     obvious reading of the `repeatable` flag gets it wrong.

     In questmarks, blue does not mean "this quest repeats". It means "you have
     already done this one and it is available again", the `repeat` state, which
     `prereq.marker_state` returns only for a quest whose status is `done`. A
     repeatable you have never finished shows the ordinary yellow, and turns blue
     only after you hand it in.

     A quest in this list cannot be in that state. `state.status_of` tests the
     completed bit first and returns `done` before it ever looks at `current`, so
     anything carrying that bit, including a repeatable you completed and
     re-accepted, reads as done and never reaches an accepted-only list. Every
     repeatable that does reach it therefore has the completed bit clear: you
     have not finished it even once.

     Painting those blue would assert the opposite of the truth. The fact that a
     quest repeats is still worth knowing, so it is said in words on the detail
     pane's meta line, where it is a property of the quest rather than a claim
     about your history with it. ]]
function theme.category_colour(cat, area, done_before)
    --[[ Blue means what questmarks means by it: you have finished this one and
         it is available again. Never inferred from the `repeatable` flag, which
         only says the quest can repeat. It is granted solely when the addon has
         observed the completed bit set for this quest on this character. See
         model.observe_completions. ]]
    if done_before then
        return {a = 255, r = 90, g = 170, b = 255}
    end
    if theme.style_for then
        local ok, _, r, g, b = pcall(theme.style_for, 'turnin', cat, area)
        if ok and type(r) == 'number' then
            --[[ Questmarks' hue, untouched, on every background. What makes that
                 possible on a light page is the ring the mark is drawn inside, see the
                 note above `lin`, not anything done to the colour here. ]]
            return {a = 255, r = r, g = g, b = b}
        end
    end
    return theme.col.amber
end

--[[ -> alpha, r, g, b, glyph for a (state, category) pair.

     Straight through questmarks' own `markers.style_for`, which is the same
     function `//qm todo` names its colours from. Going through it rather than
     copying its tables is the whole point: the panel and the marker standing on
     the NPC cannot disagree, and it picks up mission green and Campaign red for
     free. Those live in `MISSION_COLOR` and `CAMPAIGN_COLOR`, which a copy of
     `COLOR` alone would miss.

     `hint` is deliberately not passed. In the world the glyph refines into a
     sack or a sword to say what the current step asks; in a list the step rows
     say that in words, so the list keeps the plain `!` / `?` and lets hue carry
     the rest.

     The fallback is a plain grey `?` rather than a guess at the palette: naming
     a colour the world might not be drawing is exactly the drift this routes
     around. ]]
--[[ The glyph is deliberately inverted relative to the world markers, and that
     is a considered decision rather than an oversight.

     questmarks reads `!` as "there is something here to take" and `?` as "you
     have accepted this" (its `GLYPH` table in render/markers.lua). That
     distinction does real work on an NPC, where both kinds of marker are on
     screen at once.

     It does no work here. Every row in this list is a quest you have already
     accepted, which is the list's whole scope, so a glyph that says "you have
     accepted this" is saying something every row already says by being present.
     The slot is free, so it carries the thing that varies:

         !   accepted, still working on it
         ?   objectives complete, go and hand it in

     The cost is real and worth stating: a quest ready to hand in shows `?` here
     and `?` in the world, which agrees; but a quest in progress shows `!` here
     and `?` in the world, which does not. That is accepted knowingly. The colour
     link is the one that matters for not sending the player somewhere wrong, and
     it is kept exactly.

     Colour is never dimmed. It is the category at full strength always: yellow
     quest, green mission, red Campaign, blue repeatable. On a list you have
     already committed to, "not actionable from here" is not a useful thing to
     whisper on eighteen rows. Completion is said in words instead, by the
     `(completed)` tag beside the progress bar. ]]
function theme.state_style(st, cat, area, done_before)
    local c = theme.category_colour(cat, area, done_before)
    return c.a, c.r, c.g, c.b, (st == 'turnin') and '?' or '!'
end

--[[ One word per row, mutually exclusive, and blank in the common case. On a
     nineteen-quest list about four rows carry one, and those four rows are the
     answer to "what should I do next". Sentence case, never capitals: the panel
     shouts nowhere. ]]
theme.state_label = {
    turnin     = '(completed)',
    blocked    = '(blocked)',
    progress   = '',
    ready      = '',
    unknown    = '',
    ['repeat'] = '',
}

return theme
