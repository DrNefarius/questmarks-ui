--[[
ui/launcher.lua -- the book the quest log opens from.

A closed book sits on screen whenever the log is shut. Click it and the log opens
and the book opens with it; click it again, or close the log any other way, and it
shuts. It can be dragged anywhere and it remembers where it was left.

Why a launcher at all. A command is a poor default for a thing you open twenty
times a session, and FFXI has no keybind an addon can claim without asking, so the
alternative to an icon is typing into the chat box every time. `//qmui` is unchanged
and is still the one a macro can bind; this is an additional door, not a replacement
for it.

The state is derived, never stored. Which texture to draw is read from
`panel.is_open()` on every frame rather than set when something is clicked. A
parallel boolean that has to stay in sync with the panel will come apart, because
the panel closes from six places, the X button, `//qmui`, `//qmui hide`, the
launcher itself, a draw failure and a `reload`, and every one of them would have to
remember to tell the icon. Looking cannot be wrong.

What it does not do, and why.

  * It does not claim a click the panel would claim. There is no z-order control on
    this platform: no prim call takes a depth, and draw order is the client's own
    business, so where the icon overlaps the open panel there is no way to know
    from Lua which one the player can see. Rather than guess, `panel.claims` is
    asked first and the icon stands down: clicks go to the thing that is certainly
    on top. The cost is that an icon parked under the open panel cannot be clicked
    to close it, which the X button and the command both still do.

  * It never swallows a mouse move, even mid-drag. Blocking movement breaks FFXI's
    own cursor tracking (chronicle/ui/widgets.lua:2531-2536), and that applies to a
    drag as much as to a hover.
]]

local launcher = {}

local draw  = require('ui/draw')
local theme = require('ui/theme')
local panel = require('ui/panel')

--[[ 32 px at scale 1.0, so 19 px at the 0.6 floor and 80 px at the 2.5 ceiling.
     It follows `//qmui scale` because a player who scaled the panel up did so
     because the default was too small to read, and an icon that stayed 32 px would
     be the one thing on screen still too small. ]]
local BASE = 32

--[[ A drag threshold, in pixels, and it is not optional. Without it every click
     is also a one-pixel drag: the icon creeps a little each time it is used, and
     the release has to decide between "moved" and "clicked" on a distinction the
     hand cannot control. 3 px is the smallest value that makes a deliberate click
     reliably a click. ]]
local SLOP = 3

local ASSET = {closed = 'book_closed.png', open = 'book_open.png'}

local S = {
    on = true,               -- is the launcher shown at all
    x = 20, y = 20,
    hover = false,
    press = nil,             -- {kind, ox, oy, sx, sy, moved}
}
launcher.S = S

local W = nil                -- {img}
local on_moved = nil         -- set by the entry point; persists the position

--[[ Called after a drag ends, not on every pixel of it. config:save writes a file;
     doing that per mouse-move event would write a hundred times across one drag. ]]
function launcher.set_saver(fn) on_moved = fn end

function launcher.asset(which)
    return (windower.addon_path or '') .. 'assets/' .. (ASSET[which] or '')
end

function launcher.geom()
    local n = math.floor(BASE * theme.scale + 0.5)
    return {x = math.floor(S.x), y = math.floor(S.y), w = n, h = n}
end

--[[ -> viewport width, height, or nil, nil.

     `ui_x_res` and not `x_res`. questmarks' projector states the same thing at
     render/project.lua:19, "screen space: ui_x_res / ui_y_res, NOT x_res / y_res",
     and prims are positioned in that space.

     Nil is a real answer and clamping must not invent one. A guessed resolution
     that is too large lets the icon sit off a small screen; one that is too small
     drags it inward from wherever the player put it, every load, forever. If the
     size is not knowable the position is left exactly as given. ]]
local function viewport()
    local ok, ws = pcall(windower.get_windower_settings)
    if not ok or type(ws) ~= 'table' then return nil, nil end
    local w, h = tonumber(ws.ui_x_res), tonumber(ws.ui_y_res)
    if not w or not h or w <= 0 or h <= 0 then return nil, nil end
    return w, h
end

--[[ Keep the icon reachable. A saved position can be off-screen for reasons that
     have nothing to do with a bug, a window resize, a resolution change or moving
     the settings file to another machine, and an icon at x = 3000 is gone with no
     way to get it back except a command the player would have to know exists. ]]
local function clamp(x, y)
    local vw, vh = viewport()
    if not vw then return x, y end
    local g = launcher.geom()
    --[[ A quarter of the icon may hang off, no more. Flush to the edge looks like
         a mistake; a sliver left visible is still grabbable. ]]
    local slack = math.floor(g.w / 4)
    x = math.max(-slack, math.min(vw - g.w + slack, x))
    y = math.max(-slack, math.min(vh - g.h + slack, y))
    return x, y
end

function launcher.set_pos(x, y)
    x, y = tonumber(x), tonumber(y)
    if not x or not y then return false end
    S.x, S.y = clamp(math.floor(x), math.floor(y))
    return true
end

function launcher.set_on(v)
    if v == nil then v = not S.on end
    S.on = v and true or false
    --[[ Hidden means hidden immediately, not on the next frame. render() would do
         it anyway, but only if it runs, and a prerender handler that is throwing is
         exactly when a player reaches for `//qmui icon off`. ]]
    if not S.on and W then
        W.img:visible(false)
    end
    return S.on
end

function launcher.is_on() return S.on end

local function build()
    if W then return end
    W = {img = draw.image()}
end

--[[ Is (x, y) on the icon? False whenever the launcher is hidden, so nothing has
     to remember to check that separately. ]]
function launcher.hit(x, y)
    if not S.on then return false end
    local g = launcher.geom()
    return x >= g.x and x < g.x + g.w and y >= g.y and y < g.y + g.h
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

function launcher.render()
    if not S.on then
        if W then W.img:visible(false) end
        return
    end
    build()

    local g = launcher.geom()

    --[[ No plate behind the icon.

         A dark plate is the tempting thing to add, for legibility: the artwork's page
         block is near-white and so is the FFXI dialogue box, which is the same
         reasoning the panel uses for its own alpha-236 fill. Do not. Both icons
         carry a near-black outline about 3 px thick around every shape, measured
         on the shipped PNGs, and that is what makes them survive an arbitrary
         background. A plate adds nothing over it except a blue rectangle around a
         book.

         The hover affordance is alpha, which the icon already spends: 216 at rest,
         255 under the pointer or mid-drag. One channel, no second object, and nothing
         behind the art. Whether 15% of brightness reads as "this is clickable" at
         32 px is reasoned rather than measured. ]]

    -- Derived, every frame. See the header.
    W.img:texture(launcher.asset(panel.is_open() and 'open' or 'closed'))
    W.img:pos(g.x, g.y)
    W.img:size(g.w, g.h)
    --[[ 255,255,255 is the identity for the multiply `set_color` performs, so the
         art appears exactly as authored, outline included. The alpha is the one
         channel this spends: full under the pointer or while dragging, and a
         little way back when idle, so a permanent fixture on screen is not
         permanently at full strength. ]]
    local a = (S.hover or S.press) and 255 or 216
    W.img:color(a, 255, 255, 255)
    W.img:visible(true)
end

function launcher.destroy()
    if not W then return end
    W.img:destroy()
    W = nil
end

--[[ The named client objects this module owns, by role. Exposed for tools/smoke.lua,
     which needs them for two different things: leaving them out of the panel's ASCII
     picture (the rasteriser frames each pane on the bounding box of everything visible
     in it, and an icon parked left of the panel widens that box by seven columns of
     padding), and reading back which book was drawn.

     Keyed, not an array, and that is deliberate. Find the icon by scanning for a
     `qmui_img_*` object in the pool and you find three of them, because the pane
     backgrounds are textures too, in whatever order `pairs` likes. An array here
     would replace that with a silent dependence on which slot came first. Not read
     in the addon. ]]
function launcher.names()
    if not W then return {} end
    return {img = W.img.name}
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

--[[ -> true if this event was consumed.

     Mouse types, as the panel's own handler documents them: 0 move, 1 left down,
     2 left up, 3 right down, 4 right up, 5 middle up, 10 wheel.

     The panel is asked first, always. See the header on z-order. It is asked here
     rather than by the caller so the answer cannot depend on which handler happens
     to be registered first. ]]
function launcher.on_mouse(mtype, x, y)
    if not S.on then return false end

    if mtype == 0 then
        --[[ A drag in progress outranks everything, including the panel. Once the
             icon is in hand it has to keep following the pointer even as it passes
             over the open window, or a drag across the panel drops it. ]]
        if S.press and S.press.kind == 'drag' then
            if not S.press.moved
               and (math.abs(x - S.press.sx) > SLOP
                    or math.abs(y - S.press.sy) > SLOP) then
                S.press.moved = true
            end
            if S.press.moved then
                S.x, S.y = clamp(x - S.press.ox, y - S.press.oy)
            end
            -- Never swallowed. See the header.
            return false
        end
        --[[ No hover highlight for a click that would not land: where the panel
             claims the point, the icon is not the thing being pointed at. ]]
        S.hover = launcher.hit(x, y) and not panel.claims(x, y)
        return false
    end

    if mtype == 2 or mtype == 4 or mtype == 5 then          -- any release
        local was = S.press
        S.press = nil
        if not was then return false end                    -- not ours to eat
        if was.kind ~= 'drag' then return true end          -- right/middle: eat it
        if was.moved then
            --[[ Persisted the moment the drag ends rather than only on unload.
                 config:save does nothing while logged out and unload never fires
                 on a crash or a Windower restart. That is the reasoning
                 questmarks' own `save_fame` gives for saving a fame reading
                 immediately, and it applies unchanged to a position the player
                 just chose. ]]
            if on_moved then pcall(on_moved, S.x, S.y) end
        elseif launcher.hit(x, y) then
            --[[ The click fires on the release over the icon, not on the press.
                 That is what lets a press-then-drag-away cancel, and it is the
                 rule every other control in this addon follows. ]]
            panel.show(not panel.is_open())
        end
        return true
    end

    if not launcher.hit(x, y) then return false end
    if panel.claims(x, y) then return false end

    if mtype == 1 then                                      -- left down
        local g = launcher.geom()
        S.press = {kind = 'drag', ox = x - g.x, oy = y - g.y,
                   sx = x, sy = y, moved = false}
        return true
    end

    --[[ Right and middle press. Nothing is bound to them; they are swallowed over
         the icon only so a right-click on it cannot swing the camera, and recorded
         so their releases are swallowed to match. An orphaned release leaves the
         client's mouse-look believing a button is still down, and the camera spins
         until the next click. ]]
    if mtype == 3 then
        S.press = {kind = 'other'}
        return true
    end

    --[[ The wheel is not taken. Over a 32 px icon it has nothing to scroll, and
         eating it would stop the player zooming the camera through a corner of
         the screen they happened to park a book in. ]]
    return false
end

--[[ For //qmui diag, which is the whole diagnosis path for "where has it gone". ]]
function launcher.diag()
    local g = launcher.geom()
    local vw, vh = viewport()
    return {
        on = S.on, x = g.x, y = g.y, size = g.w,
        open = panel.is_open(),
        asset = launcher.asset(panel.is_open() and 'open' or 'closed'),
        vw = vw, vh = vh,
        dragging = (S.press ~= nil and S.press.kind == 'drag'
                    and S.press.moved) or false,
    }
end

return launcher
