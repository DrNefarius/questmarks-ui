--[[
ui/draw.lua -- the drawing floor: pooled, change-detected prims and text objects.

Why not libs/images.lua and libs/texts.lua. chronicle's widget layer is built on
both (chronicle/ui/widgets.lua:15-16) and that is a perfectly reasonable choice
for what chronicle does. This addon declines them, deliberately rather than by
default, for four measured reasons:

  * `saved_images` is a bare global, not a local (images.lua:11), and
    `windower.text.saved_texts` is a field on the shared windower table
    (texts.lua:11). Two addons that both load the library share neither, because
    each addon has its own Lua state, but within this addon it means any object
    it creates is reachable and mutable from anywhere.
  * `default_settings.draggable = true` (images.lua:70). Every image is
    draggable unless told otherwise. chronicle is disciplined about this and
    passes `draggable = false` at all 34 of its construction sites, but the
    default is the wrong way round for an interface made of a hundred
    non-draggable rectangles: one missed flag and the player drags a row out of
    its list.
  * requiring images.lua executes `math.randomseed(os.clock())` at load. That
    reseeds the RNG for the whole Lua state as a side effect of drawing a
    rectangle.
  * both libraries register their own global `mouse` handler (images.lua:381,
    texts.lua:618) which this addon would inherit whether it wants it or not,
    and which on a left click walks every registered object.

  This is the same reasoning render/markers.lua gives for the marker pool, and
  it is repeated here rather than cited because the conclusion is not
  automatically the same: a marker pool and a list widget have different costs.
  What decides it for a list is the fourth reason plus one the marker header
  does not have. texts.lua's `__newindex` calls `t:update()` on every single
  field assignment, so a row that sets text, colour and position issues three
  full updates. A list redraw touches a few hundred properties, and
  change-detection at this layer collapses that to the handful that differ.

What it costs: no `:hover()`, no drag, no layout help. Hit-testing is 15 lines in
panel.lua and measurement goes through ui/metrics.lua, which answers about a
string before it is drawn.

Named globals. Prims and text objects are named objects owned by the client, not
by this Lua state. An orphaned name stays on screen until Windower restarts, so
every object this module creates is recorded in `owned`, names are deterministic
(`qmui_<kind>_<n>`), and `draw.destroy_all()` deletes every one. It is called
from the 'unload' event and from `//qmui reload`.
]]

local draw = {}

-- name -> {kind = 'prim'|'text', props = {}}
local owned = {}
local counters = {}

local function next_name(kind)
    counters[kind] = (counters[kind] or 0) + 1
    return ('qmui_%s_%d'):format(kind, counters[kind])
end

-- ---------------------------------------------------------------------------
-- Rectangles (prims with no texture)
-- ---------------------------------------------------------------------------

--[[ A prim with a colour and no texture draws as a solid rectangle. That is not
     an assumption: it is what libs/images.lua does for every background in
     chronicle, `images.new{texture = {fit = false}}` with no `path`
     (chronicle/ui/widgets.lua:646 is the scroll track), and images.lua's own
     `default_settings.texture.path` is the empty string. The prim calls that
     path reduces to are create / set_position / set_size / set_color /
     set_visibility (images.lua:149, :226, :253, :317, :212). ]]
local Rect = {}
Rect.__index = Rect

function draw.rect()
    local self = setmetatable({}, Rect)
    self.name = next_name('rect')
    self.p = {}
    windower.prim.create(self.name)
    owned[self.name] = {kind = 'prim'}
    -- Prims default to visible; nothing has a position yet, so hide first.
    windower.prim.set_visibility(self.name, false)
    self.p.vis = false
    return self
end

--[[ Every setter is change-detected. The native call is the expensive part and
     a static panel should issue none of them between frames. ]]
function Rect:pos(x, y)
    x, y = math.floor(x), math.floor(y)
    if self.p.x == x and self.p.y == y then return end
    self.p.x, self.p.y = x, y
    windower.prim.set_position(self.name, x, y)
end

function Rect:size(w, h)
    w, h = math.floor(w), math.floor(h)
    if w < 0 then w = 0 end
    if h < 0 then h = 0 end
    if self.p.w == w and self.p.h == h then return end
    self.p.w, self.p.h = w, h
    windower.prim.set_size(self.name, w, h)
end

function Rect:color(a, r, g, b)
    if self.p.a == a and self.p.r == r and self.p.g == g and self.p.b == b then
        return
    end
    self.p.a, self.p.r, self.p.g, self.p.b = a, r, g, b
    windower.prim.set_color(self.name, a, r, g, b)
end

function Rect:visible(v)
    v = v and true or false
    if self.p.vis == v then return end
    self.p.vis = v
    windower.prim.set_visibility(self.name, v)
end

function Rect:destroy()
    if not owned[self.name] then return end
    windower.prim.delete(self.name)
    owned[self.name] = nil
end

-- ---------------------------------------------------------------------------
-- Images (prims WITH a texture)
-- ---------------------------------------------------------------------------

--[[ The same prim, with a PNG on it. Everything a Rect can do it can do, so it
     inherits rather than repeats; the only additions are the two calls that put a
     texture on a quad.

     The API is not guessed. `windower.prim.set_texture(name, path)` and
     `set_fit_to_texture(name, bool)` are what questmarks' own marker pool wraps as
     `api.texture` and `api.fit` in render/markers.lua, and libs/images.lua reaches
     the same two (images.lua:279, :288).

     `fit` is set false and the size is set explicitly. With fit true the quad takes
     the texture's own pixel size, which would make the icon 64px whatever the scale
     setting says. markers.lua does the same thing, `api.fit(n, false)` immediately
     followed by `api.size(n, icon_size, icon_size)`.

     A path that does not exist fails silently. The prim draws nothing at all, no
     error and no placeholder, so a missing asset is an invisible click target
     rather than a visible fault. That is why tools/smoke.lua asserts the files are
     on disk rather than trusting them, which is the check questmarks makes for the
     same reason in its own `assets are ours` block. ]]
local Image = setmetatable({}, {__index = Rect})
Image.__index = Image

function draw.image()
    local self = setmetatable({}, Image)
    self.name = next_name('img')
    self.p = {}
    windower.prim.create(self.name)
    owned[self.name] = {kind = 'prim'}
    windower.prim.set_visibility(self.name, false)
    self.p.vis = false
    -- Explicit sizing, always. See the note above.
    windower.prim.set_fit_to_texture(self.name, false)
    self.p.fit = false
    return self
end

function Image:texture(path)
    path = tostring(path or '')
    if self.p.tex == path then return end
    self.p.tex = path
    windower.prim.set_texture(self.name, path)
end

-- ---------------------------------------------------------------------------
-- Text
-- ---------------------------------------------------------------------------

local Text = {}
Text.__index = Text

--[[ The text API surface used here, all of it read off libs/texts.lua's own
     call sites so nothing is guessed:
       create/delete            texts.lua:197, :609
       set_text                 texts.lua:245
       set_location             texts.lua:381
       set_color                texts.lua:439   (alpha, r, g, b)
       set_font / set_font_size texts.lua:411, :421
       set_bold / set_italic    texts.lua:496, :487
       set_visibility           texts.lua:356
       set_bg_color             texts.lua:505   (alpha, r, g, b)
       set_bg_visibility        texts.lua:516
       set_stroke_width/_color  texts.lua:543, :552
       get_extents              texts.lua:403   -> width, height in pixels
     get_extents is the only measurement the platform itself offers. It answers
     only about a string an object has already been given, which is why layout
     goes through ui/metrics.lua instead. ]]
function draw.text(opts)
    local self = setmetatable({}, Text)
    opts = opts or {}
    self.name = next_name('text')
    self.p = {}
    windower.text.create(self.name)
    owned[self.name] = {kind = 'text'}
    windower.text.set_visibility(self.name, false)
    self.p.vis = false
    windower.text.set_bg_visibility(self.name, false)
    -- A stroke is what keeps light text readable over the game's own bright
    -- surfaces. questmarks bakes the equivalent into its glyph artwork instead,
    -- because a prim carries no outline of its own.
    windower.text.set_stroke_width(self.name, opts.stroke or 1)
    --[[ The stroke colour is deliberately not set here. A hardcoded near-black is
         right for light text over a dark panel and wrong the moment the panel is
         light: dark ink with a dark halo just gets muddier, and at 9pt that is the
         difference between a word and a smudge. `Text:stroke` reads
         `theme.col.stroke` per draw instead, change-detected like everything
         else. ]]
    self:font(opts.font or 'Consolas', opts.size or 10)
    self:bold(opts.bold and true or false)
    return self
end

function Text:font(name, size)
    if self.p.font ~= name then
        self.p.font = name
        windower.text.set_font(self.name, name)
    end
    if self.p.size ~= size then
        self.p.size = size
        windower.text.set_font_size(self.name, size)
    end
end

function Text:bold(v)
    v = v and true or false
    if self.p.bold == v then return end
    self.p.bold = v
    windower.text.set_bold(self.name, v)
end

function Text:italic(v)
    v = v and true or false
    if self.p.italic == v then return end
    self.p.italic = v
    windower.text.set_italic(self.name, v)
end

function Text:text(s)
    s = tostring(s or '')
    if self.p.text == s then return end
    self.p.text = s
    windower.text.set_text(self.name, s)
end

function Text:pos(x, y)
    x, y = math.floor(x), math.floor(y)
    if self.p.x == x and self.p.y == y then return end
    self.p.x, self.p.y = x, y
    windower.text.set_location(self.name, x, y)
end

--[[ The outline colour. Its own setter rather than a constructor argument because a
     background preset can change it at runtime, and every text object in the pool
     already exists by then. ]]
function Text:stroke(a, r, g, b)
    if self.p.sa == a and self.p.sr == r and self.p.sg == g and self.p.sb == b then
        return
    end
    self.p.sa, self.p.sr, self.p.sg, self.p.sb = a, r, g, b
    windower.text.set_stroke_color(self.name, a, r, g, b)
end

function Text:color(a, r, g, b)
    if self.p.a == a and self.p.r == r and self.p.g == g and self.p.b == b then
        return
    end
    self.p.a, self.p.r, self.p.g, self.p.b = a, r, g, b
    windower.text.set_color(self.name, a, r, g, b)
end

function Text:visible(v)
    v = v and true or false
    if self.p.vis == v then return end
    self.p.vis = v
    windower.text.set_visibility(self.name, v)
end

function Text:destroy()
    if not owned[self.name] then return end
    windower.text.delete(self.name)
    owned[self.name] = nil
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--[[ The whole reason `owned` exists. An addon that errors mid-layout, or is
     unloaded with objects on screen, leaves named objects the client still
     draws, and there is no way to enumerate them afterwards from Lua, so the
     names must be tracked as they are handed out. ]]
function draw.destroy_all()
    for name, rec in pairs(owned) do
        if rec.kind == 'prim' then
            pcall(windower.prim.delete, name)
        else
            pcall(windower.text.delete, name)
        end
    end
    owned = {}
end

function draw.count()
    local n = 0
    for _ in pairs(owned) do n = n + 1 end
    return n
end

return draw
