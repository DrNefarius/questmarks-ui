--[[
questmarks-ui -- your accepted quests, as a browsable list grouped by region.

    //qmui              open / close
    //qmui help         every command

Relationship to questmarks. This addon reads questmarks' data and drives its
core modules; it never writes to it and does not require it to be loaded, only
installed. Where the dependency is declared, what it costs and how it degrades
are all in model.lua's header.

Nothing here modifies questmarks.
]]

_addon.name     = 'questmarks-ui'
_addon.author   = 'DrNefarius'
_addon.version  = '1.0.0'
_addon.language = 'English'
_addon.commands = {'qmui', 'questlog'}

local config  = require('config')
local packets = require('packets')

local model = require('model')
local resnames = require('resnames')
local panel = require('ui/panel')
local launcher = require('ui/launcher')
local theme = require('ui/theme')
local draw  = require('ui/draw')

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

--[[ `questmarks_path` is a setting and not a constant. The default is built
     from Windower's own root, the same handle questmarks uses to reach res/,
     rather than a '../' hop out of this directory. That hop is the shape
     questmarks' own tools/test_standalone.lua scans its shipped files for, and
     it is worth not writing even where no test is watching. ]]
local defaults = {
    questmarks_path = '',      -- '' -> derive from windower_path at load
    --[[ Repeatables observed sitting completed, per character. An observation,
         meaning a bit read off a packet, which is why it is saved at all. See
         the header on model.observe_completions and questmarks' own split
         between an observation and an inference in core/steps.lua.

         Character name -> a comma-joined key list. A string, because config
         serialises table keys as XML element names and `quest/windurst/28` is
         not a legal one. See model.set_seen_done. ]]
    seen_done_by_char = {},
    x = 60,
    y = 90,
    scale = 1.0,
    open_on_load = false,
    show_when_map_open = false,
    --[[ The launcher, shown by default, because otherwise the addon loads with
         nothing on screen and `//qmui` as the only way in.

         `icon_x` and `icon_y`, not a nested `icon = {x, y}` table. Both forms
         round-trip through Windower's XML, since these are legal element names,
         but flat keys are what every other position in this file uses and the
         serialiser is the thing to check before choosing a key shape: see
         model.set_seen_done for what it does with one that is not legal. The
         position is clamped into the viewport when it is loaded, not trusted,
         because a resolution change can leave a perfectly good saved value off
         the screen. ]]
    icon = true,
    icon_x = 20,
    icon_y = 20,
    --[[ Which tint the papyrus sheet is multiplied by. A name and not a colour: the
         tints are derived from measurements of the sheet and contrast-checked by the
         suite, so a raw rgb in a settings file would be an unchecked value on the one
         axis that decides whether the panel is readable. An unknown name falls back
         to navy rather than blanking the panes. ]]
    bg = 'navy',
    --[[ How opaque the panel surfaces are. Only the two panes and the header
         band; text and glyphs keep their own alpha, so the contrast floors the
         suite asserts still describe what is drawn. See theme.set_opacity. ]]
    opacity = 1.0,
}

local settings = config.load(defaults)

--[[ Keyed by character name, because a completion belongs to a character and
     not to an install. Falls back to a shared bucket while logged out, which is
     the safe direction: it can only ever fail to know something. ]]
local function char_key()
    local ok, p = pcall(windower.ffxi.get_player)
    if ok and p and p.name and p.name ~= '' then return p.name end
    return '_'
end

local function load_seen()
    local all = settings.seen_done_by_char or {}
    model.set_seen_done(all[char_key()] or {})
end

--[[ Written the moment something new is learned rather than only on unload:
     config.save does nothing while logged out, and a crash or a Windower restart
     never fires unload at all. This is the reasoning questmarks' own `save_fame`
     gives for saving a fame reading immediately, and it applies unchanged. ]]
local function save_seen()
    settings.seen_done_by_char = settings.seen_done_by_char or {}
    settings.seen_done_by_char[char_key()] = model.seen_done_string()
    pcall(function() settings:save() end)
end

local function note_completions()
    if model.observe_completions() then save_seen() end
end

local function qm_path()
    local p = settings.questmarks_path
    if type(p) == 'string' and p ~= '' then return p end
    return (windower.windower_path or '') .. 'addons/questmarks/'
end

-- ---------------------------------------------------------------------------
-- Chat
-- ---------------------------------------------------------------------------

local function msg(fmt, ...)
    windower.add_to_chat(207, 'questmarks-ui: ' .. (select('#', ...) > 0
        and fmt:format(...) or fmt))
end

local function err(fmt, ...)
    windower.add_to_chat(167, 'questmarks-ui: ' .. (select('#', ...) > 0
        and fmt:format(...) or fmt))
end

local function line(fmt, ...)
    windower.add_to_chat(207, '   ' .. (select('#', ...) > 0
        and fmt:format(...) or fmt))
end

-- ---------------------------------------------------------------------------
-- Load
-- ---------------------------------------------------------------------------

theme.set_scale(settings.scale)
theme.set_opacity(settings.opacity)
panel.S.x, panel.S.y = settings.x, settings.y

--[[ Which tint the papyrus sheet is multiplied by. Refused rather than trusted: a
     settings file naming a preset this build has never heard of keeps navy and says
     so, instead of leaving the panes on nil. ]]
if settings.bg and not theme.set_bg(settings.bg) then
    err('unknown background "%s" -- using %s. try: //qmui bg',
        tostring(settings.bg), theme.bg_theme())
end

--[[ The launcher, restored where it was left. `set_pos` clamps, so a saved value
     from a bigger screen comes back reachable rather than off the edge. ]]
launcher.set_on(settings.icon ~= false)
launcher.set_pos(settings.icon_x, settings.icon_y)

--[[ Written the moment a drag ends, not only on unload: config:save does nothing
     while logged out and unload never fires on a crash. Same reasoning as
     save_seen above. ]]
launcher.set_saver(function(x, y)
    settings.icon_x, settings.icon_y = x, y
    pcall(function() settings:save() end)
end)

local function attach()
    local ok = model.attach(qm_path())
    if ok then
        local m = model.meta or {}
        msg('reading questmarks: %s entries (%s quests, %s missions)',
            tostring(m.indexed or '?'), tostring(m.quests or '?'),
            tostring(m.missions or '?'))
    else
        err('%s', model.detail or model.status)
        err('set the path with:  //qmui path <folder>')
    end
    panel.invalidate()
    return ok
end

attach()
load_seen()
if settings.open_on_load then panel.show(true) end

-- ---------------------------------------------------------------------------
-- Feeding the model
-- ---------------------------------------------------------------------------

--[[ Deliberately the same packet set questmarks itself listens to, minus the
     ones only its markers need. 0x028 (combat) and 0x02D (kill counts) are not
     taken: they exist to advance monster-step progress, which this list shows as
     a step row and not as a counter, and questmarks' own handler calls 0x028 a
     firehose because it arrives for every action of every fight in the zone.
     Paying that cost to change nothing on screen would be indefensible. ]]
local dirty_state = false
local dirty_inv = false

windower.register_event('incoming chunk', function(id, original)
    if model.status ~= 'ok' then return end

    if id == 0x056 then
        local ok, p = pcall(packets.parse, 'incoming', original)
        if ok and p then
            if model.handle_state_packet(p) then
                dirty_state = true
            end
        end

    elseif id == 0x055 then
        model.invalidate_key_items()
        dirty_state = true

    elseif id == 0x01F or id == 0x020 then
        --[[ Item assign and item update. Debounced through the tick rather than
             handled here: a gear swap or a treasure pool is a burst of these and
             each one would otherwise force a full bag sweep. questmarks' own
             0x01F/0x020 handler says the same. ]]
        model.invalidate_items()
        dirty_inv = true
    end
end)

windower.register_event('zone change', function()
    dirty_inv = true
    dirty_state = true
end)

windower.register_event('login', function()
    model.reset()
    model.refresh_player()
    load_seen()
    --[[ No harvest here. `model.reset()` two lines up wipes the 0x056 state, and
         the completed bitfield arrives in packets after login, so harvesting at
         this moment reads an empty state and learns nothing. It happens on the
         settle tick below instead, once the packets have landed. tools/smoke.lua
         is what catches it, by noticing the save path wrote nothing. ]]
    dirty_state, dirty_inv = true, true
    panel.invalidate()
end)

windower.register_event('logout', function()
    --[[ Every inference is dropped. This addon holds no observations to keep,
         because it never reads fame, so unlike questmarks there is nothing on
         the other side of that line. See model.reset. ]]
    model.reset()
    panel.invalidate()
    panel.show(false)
end)

windower.register_event('job change', function()
    model.refresh_player()
    dirty_state = true
end)

-- ---------------------------------------------------------------------------
-- Tick
-- ---------------------------------------------------------------------------

--[[ One coalescing tick rather than work in the packet handlers. The panel is
     redrawn from cached widgets every frame, which is cheap because every setter
     in ui/draw.lua is change-detected and a static list issues no native calls
     at all, but the model is rebuilt only when something actually moved, and
     never more than twice a second. ]]
local last_tick = 0
local TICK = 0.5

windower.register_event('prerender', function()
    --[[ The launcher draws whether the panel is open or not. That is the whole
         point of it, so it comes before the early-out below.

         Its own pcall, separate from the panel's. Two surfaces that fail
         independently must not take each other down: a bug in a 32 px icon
         closing the quest log would be a worse outcome than the bug. On failure
         the icon hides itself and says so once, which is the rule the panel
         follows too, because a recoverable state beats a stream of tracebacks at
         60 a second.

         Cheap by construction: every setter in ui/draw.lua is change-detected, so
         a launcher that has not moved issues no native calls at all. ]]
    local oki, ei = pcall(launcher.render)
    if not oki then
        err('launcher draw failed, hiding the icon: %s', tostring(ei))
        pcall(launcher.set_on, false)
    end

    if not panel.is_open() then return end

    local now = os.clock()
    if now - last_tick >= TICK then
        last_tick = now
        if dirty_inv then
            dirty_inv = false
            if model.refresh_inventory() then panel.invalidate() end
        end
        if dirty_state then
            dirty_state = false
            model.on_state_change()
            model.refresh_player()
            note_completions()
            panel.invalidate()
        end
    end

    --[[ pcall around the whole draw. A layout bug must not take the player's
         client down mid-fight, and an addon that throws inside prerender throws
         every frame. On the first failure the panel closes itself and says so,
         which is recoverable; a stream of tracebacks is not. ]]
    local ok, e = pcall(panel.render)
    if not ok then
        err('draw failed, closing panel: %s', tostring(e))
        pcall(panel.show, false)
    end
end)

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------

--[[ `blocked` means another handler has already claimed this event; the stock
     libraries both bail on it (libs/texts.lua:619-621, libs/images.lua:382-384)
     and so does this. Move events are never blocked, and chronicle's note at
     ui/widgets.lua:2534-2540 explains what breaks if they are.

     The launcher is offered the event first, and the panel is never skipped for
     being closed.

     Order does not decide who wins. launcher.on_mouse asks `panel.claims` itself
     and stands down over the open window, so the outcome is the same whichever
     is called first. That is deliberate, because "whichever handler was
     registered first" is not a rule anyone can read off the screen.

     Do not put an `is_open` guard here. panel.on_mouse opens by honouring a
     pending release even with the panel closed, and a guard here means that
     branch is never reached: press on a row, close the panel with `//qmui` or a
     macro before letting go, and the release reaches the client as an orphan and
     leaves mouse-look believing a button is still down. on_mouse's own guard is
     the only one needed, and it returns false in O(1) when nothing is
     pending. ]]
windower.register_event('mouse', function(mtype, x, y, delta, blocked)
    if blocked then return false end
    local okl, rl = pcall(launcher.on_mouse, mtype, x, y)
    if okl and rl then return true end
    local ok, r = pcall(panel.on_mouse, mtype, x, y, delta)
    if not ok then return false end
    return r and true or false
end)

-- ---------------------------------------------------------------------------
-- Unload
-- ---------------------------------------------------------------------------

--[[ The one thing this addon must not get wrong.

     Prims and text objects are named objects owned by the client. An orphan
     stays on screen until Windower is restarted and there is no way to
     enumerate it from Lua afterwards, which is why ui/draw.lua records every
     name as it hands it out, and why this is a pcall: a failure earlier in the
     handler must not skip the delete. ]]
windower.register_event('unload', function()
    pcall(function()
        settings.x, settings.y = panel.S.x, panel.S.y
        settings.scale = theme.scale
        --[[ A backstop, not the primary save: a drag persists itself the moment it
             ends. This catches `//qmui icon pos`, and where the position was
             already saved and nothing has changed it costs one identical write. ]]
        local lg = launcher.geom()
        settings.icon = launcher.is_on()
        settings.icon_x, settings.icon_y = lg.x, lg.y
        settings:save()
    end)
    pcall(panel.destroy)
    pcall(launcher.destroy)
    pcall(draw.destroy_all)
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

--[[ Every action has a command, not just the awkward ones. The mouse is real
     and it works, but FFXI captures the cursor often enough that a list you can
     only reach by clicking is a list you sometimes cannot reach. See
     ui/panel.lua's header. ]]
local HELP = {
    '//qmui                 open or close the quest log',
    '//qmui show | hide',
    '//qmui accepted        show everything you have accepted (default)',
    '//qmui handin          show only what is ready to hand in',
    '//qmui here            show only what is in this zone',
    '//qmui search <text>   filter by quest or region name',
    '//qmui search          clear the filter',
    '//qmui next | prev     move the selection',
    '//qmui pick <n>        select the nth quest in the list',
    '//qmui scroll <n>      scroll the quest list (negative scrolls up)',
    '//qmui steps <n>       scroll the step detail on the right',
    '//qmui top | bottom',
    '//qmui fold <region>   collapse or expand a region by name',
    '//qmui foldall | unfoldall',
    '//qmui list            print the list to chat instead of drawing it',
    '//qmui pos <x> <y>     move the window',
    '//qmui icon            show or hide the book icon',
    '//qmui icon pos <x> <y>  move the book icon (or just drag it)',
    '//qmui bg [<name>]    pane background: navy, leather, parchment or mixed',
    '//qmui scale <n>       0.6 to 2.5',
    '//qmui opacity [<n>]   panel transparency, 0.15 to 1',
    '//qmui path <folder>   where questmarks is installed',
    '//qmui reload          re-read the index',
    '//qmui diag            what is loaded, and how many objects are drawn',
}

--[[ Selection moves over quest rows only, skipping region headers. Landing the
     cursor on a header would mean `next` sometimes selects nothing and the
     detail pane blanks for no reason the player can see. ]]
local function move_sel(dir)
    local S = panel.S
    if S.dirty then panel.rebuild() end
    local n = #S.lines
    if n == 0 then return end
    local i = S.sel or (dir > 0 and 0 or n + 1)
    for _ = 1, n do
        i = i + dir
        if i < 1 or i > n then return end
        if S.lines[i].kind == 'row' then
            S.sel, S.sel_key = i, S.lines[i].row.key
            -- Keep the selection inside the viewport.
            if i <= S.scroll then S.scroll = i - 1 end
            if i > S.scroll + 14 then S.scroll = i - 14 end
            return
        end
    end
end

local function cmd_list()
    local S = panel.S
    if S.dirty then panel.rebuild() end
    if model.status ~= 'ok' then
        err('%s', model.detail or model.status)
        return
    end
    if not model.state_ready() then
        err('the game has not sent your quest log yet (packet 0x056)')
        return
    end
    if #S.lines == 0 then
        msg('nothing accepted')
        return
    end
    msg('%d accepted%s', S.total,
        S.handin > 0 and (', %d ready to hand in'):format(S.handin) or '')
    local n = 0
    for _, l in ipairs(S.lines) do
        if l.kind == 'group' then
            line('%s (%d)', l.group.name, l.n)
        else
            n = n + 1
            local w = l.row.where or {}
            local where = w.label and model.nice_name(w.label) or ''
            if w.zone then
                where = where .. (where ~= '' and ', ' or '')
                        .. model.zone_name(w.zone)
            end
            if w.grid then where = where .. ' (' .. w.grid .. ')' end
            local step = w.step and (' step %d/%d%s'):format(w.step, w.of,
                                    w.held and ' (held)' or '') or ''
            line('%2d. %-34s %s%s', n, l.row.name or l.row.key, where, step)
        end
    end
end

local function cmd_pick(n)
    local S = panel.S
    if S.dirty then panel.rebuild() end
    n = tonumber(n)
    if not n then err('usage: //qmui pick <n>') return end
    local c = 0
    for i, l in ipairs(S.lines) do
        if l.kind == 'row' then
            c = c + 1
            if c == n then
                S.sel, S.sel_key = i, l.row.key
                if i <= S.scroll then S.scroll = math.max(0, i - 1) end
                if i > S.scroll + 14 then S.scroll = i - 14 end
                panel.show(true)
                return
            end
        end
    end
    err('no quest %d in the list', n)
end

local function cmd_fold(name)
    local S = panel.S
    if S.dirty then panel.rebuild() end
    if not name or name == '' then err('usage: //qmui fold <region>') return end
    local pat = name:lower()
    for _, l in ipairs(S.lines) do
        if l.kind == 'group' and l.group.name:lower():find(pat, 1, true) then
            S.collapsed[l.group.key] = (not S.collapsed[l.group.key]) or nil
            S.dirty = true
            msg('%s %s', S.collapsed[l.group.key] and 'collapsed' or 'expanded',
                l.group.name)
            return
        end
    end
    err('no region matching "%s" in the list', name)
end

local function cmd_diag()
    msg('status: %s%s', model.status,
        model.detail and (' -- ' .. model.detail) or '')
    line('questmarks path: %s', qm_path())
    local m = model.meta or {}
    line('index: %s entries (%s quests, %s missions)',
         tostring(m.indexed or '?'), tostring(m.quests or '?'),
         tostring(m.missions or '?'))
    line('marker colours: %s', theme.style_for and 'from questmarks render/markers'
         or 'FALLBACK (render/markers unavailable)')
    if model.notes_available() then
        local s = model.notes_stats()
        line('step notes: reading build/authored (%d notes over %d quests, %.0f ms)',
             s.notes or 0, s.quests or 0, s.ms or 0)
        --[[ What the voice filter did, and where its word list came from.
             These notes are written as build-log justifications, so some can
             carry vocabulary a player cannot act on: a res/ file, a numbered
             house rule, the resolver. tidy_note translates the two that have
             player words (rung -> step, evidence -> signal) and drops any
             sentence still carrying one. A filter nobody can see working is a
             filter nobody notices has stopped, so both the count and the source
             of the list are printed. A count of zero is the ordinary reading on
             a clean corpus; "bundled fallback" means questmarks'
             tools/pipeline/lib/player_voice.json was not readable. ]]
        line('  voice filter: %d sentence(s) redacted, list from %s',
             s.redacted or 0, model.notes_voice_source())
    else
        line('step notes: unavailable -- questmarks/build/authored is not present')
    end
    local ds = model.desc_stats()
    if (ds.quests or 0) > 0 then
        line('descriptions: reading build/rendered (%d quests, %.0f ms)',
             ds.quests, ds.ms or 0)
    else
        line('descriptions: not loaded yet, or build/rendered is not present')
    end
    --[[ The character width and where it came from. This is the number that,
         when wrong, makes every string in the addon overflow its panel, so it is
         the first thing to ask for when the layout looks broken. ]]
    if resnames.loaded() then
        local rs = resnames.stats()
        line('item names: %d items + %d key items from res/ (%.0f ms)',
             rs.items or 0, rs.key_items or 0, rs.ms or 0)
    else
        line('item names: not loaded yet (read lazily from res/ on first need)')
    end
    local cw, src, sz = panel.metrics()
    line('text metrics: %.2f px/char at size %d (%s)', cw, sz, src)
    line('0x056 received: %s', tostring(model.state_ready()))
    line('drawn objects: %d prims/texts', draw.count())
    line('panel: %s at %d,%d scale %.2f', panel.is_open() and 'open' or 'closed',
         panel.S.x, panel.S.y, theme.scale)
    line('lines: %d  selected: %s', #panel.S.lines,
         panel.S.sel_key or 'none')

    --[[ The whole diagnosis path for "the icon has gone". It can be off, it can
         be off the edge of the viewport, or its texture can be missing, and the
         third of those looks exactly like the first because a prim whose texture
         will not load draws nothing at all and says nothing about it. So the file
         is opened here rather than assumed, and the viewport is printed so an
         icon at x=3000 on a 1920 screen is visible as the arithmetic it is. ]]
    local li = launcher.diag()
    line('icon: %s at %d,%d  %dpx  showing the %s book', li.on and 'on' or 'off',
         li.x, li.y, li.size, li.open and 'open' or 'closed')
    local f = io.open(li.asset, 'rb')
    if f then
        local n = f:seek('end')
        f:close()
        line('icon art: %s (%d bytes)', li.asset, n)
    else
        err('icon art MISSING: %s -- the icon will draw as nothing at all',
            li.asset)
    end
    line('viewport: %s', li.vw and ('%dx%d'):format(li.vw, li.vh)
         or 'unknown -- the icon position is not being clamped')

    --[[ Whether the panes are on the texture or on the flat fill. Worth a line for
         the same reason the icon art is: a sheet that will not load draws nothing
         and says nothing, and the fallback is deliberately invisible as a
         fallback. If someone reports "the background went flat", this is the
         answer. ]]
    if theme.bg_available() then
        line('pane pages: %s + %s   tint %s', theme.bg_pages.list,
             theme.bg_pages.detail, theme.bg_theme())
        line('derived from %s by tools/make_pages.py', theme.bg_source)
    else
        line('pane pages: %s / %s NOT BOTH FOUND -- panes are on their flat fills, '
             .. 'so the %s tint has nothing to act on',
             tostring(theme.bg_pages.list), tostring(theme.bg_pages.detail),
             theme.bg_theme())
    end
end

windower.register_event('addon command', function(cmd, a1, a2, ...)
    cmd = (cmd or ''):lower()

    if cmd == '' or cmd == 'toggle' then
        panel.show()
    elseif cmd == 'show' or cmd == 'open' then
        panel.show(true)
    elseif cmd == 'hide' or cmd == 'close' then
        panel.show(false)

    elseif cmd == 'accepted' or cmd == 'all' then
        panel.set_filter_set('accepted'); panel.show(true)
    elseif cmd == 'handin' or cmd == 'turnin' then
        panel.set_filter_set('handin'); panel.show(true)
    elseif cmd == 'here' then
        panel.set_filter_set('here'); panel.show(true)

    elseif cmd == 'search' or cmd == 'find' then
        local terms = {a1, a2, ...}
        local s = table.concat(terms, ' '):gsub('^%s+', ''):gsub('%s+$', '')
        panel.set_search(s)
        if s == '' then msg('filter cleared') else msg('filter: %s', s) end
        panel.show(true)

    elseif cmd == 'next' then move_sel(1);  panel.show(true)
    elseif cmd == 'prev' then move_sel(-1); panel.show(true)
    elseif cmd == 'pick' then cmd_pick(a1)

    elseif cmd == 'scroll' then
        panel.scroll_by(tonumber(a1) or 3)
    elseif cmd == 'steps' or cmd == 'dscroll' then
        --[[ Scrolls the detail pane. It has its own command because notes wrap in
             full and a long ladder genuinely does not fit, and because the mouse
             is not always available. ]]
        panel.dscroll_by(tonumber(a1) or 3)
    elseif cmd == 'top' then
        panel.S.scroll = 0
    elseif cmd == 'bottom' then
        panel.scroll_by(#panel.S.lines)

    elseif cmd == 'fold' then
        cmd_fold(table.concat({a1, a2, ...}, ' '))
    elseif cmd == 'foldall' then
        if panel.S.dirty then panel.rebuild() end
        for _, l in ipairs(panel.S.lines) do
            if l.kind == 'group' then panel.S.collapsed[l.group.key] = true end
        end
        panel.S.dirty = true
    elseif cmd == 'unfoldall' then
        panel.S.collapsed = {}
        panel.S.dirty = true

    elseif cmd == 'list' then
        cmd_list()

    elseif cmd == 'pos' then
        local x, y = tonumber(a1), tonumber(a2)
        if not x or not y then err('usage: //qmui pos <x> <y>') return end
        panel.S.x, panel.S.y = x, y
        settings.x, settings.y = x, y
        pcall(function() settings:save() end)

    --[[ The icon has commands too, and not as an afterthought. It is dragged with
         the mouse, and FFXI captures the cursor often enough that a control you
         can only reach by clicking is one you sometimes cannot reach, which is the
         argument in ui/panel.lua's header for why everything here has a command.
         It applies with more force to the launcher than to anything else: an icon
         dragged somewhere unreachable can only be recovered by typing. ]]
    elseif cmd == 'icon' then
        if a1 == 'pos' then
            local x, y = tonumber(a2), tonumber((select(1, ...)))
            if not x or not y then err('usage: //qmui icon pos <x> <y>') return end
            if not launcher.set_pos(x, y) then
                err('usage: //qmui icon pos <x> <y>') return
            end
            local g = launcher.geom()
            settings.icon_x, settings.icon_y = g.x, g.y
            pcall(function() settings:save() end)
            --[[ The clamped value is reported, not the one asked for. Silently
                 moving it and then printing the request is how a player concludes
                 the command is broken. ]]
            msg('icon at %d,%d%s', g.x, g.y,
                (g.x ~= math.floor(x) or g.y ~= math.floor(y))
                and ' (clamped to the screen)' or '')
        else
            local v
            if a1 == 'on' or a1 == 'show' then v = true
            elseif a1 == 'off' or a1 == 'hide' then v = false
            elseif a1 == nil or a1 == '' then v = nil
            else err('usage: //qmui icon [on | off | pos <x> <y>]') return end
            local on = launcher.set_on(v)
            settings.icon = on
            pcall(function() settings:save() end)
            msg('icon %s', on and 'shown' or 'hidden')
            if not on then
                line('open the log with //qmui, and bring the icon back with '
                     .. '//qmui icon on')
            end
        end

    --[[ Switching the background tint. A taste call no offline harness can settle,
         because the rasteriser cannot show colour, so it is a command and the
         choice is made in game. ]]
    elseif cmd == 'bg' then
        local names = table.concat(theme.bg_theme_names(), ' | ')
        if a1 == nil or a1 == '' then
            msg('background tint: %s   (available: %s)', theme.bg_theme(), names)
            if not theme.bg_available() then
                line('note: the page sheets are not both on disk, so the panes are on '
                     .. 'their flat fills and the tint changes nothing')
            end
            return
        end
        if not theme.set_bg(a1) then
            err('unknown background "%s". available: %s', tostring(a1), names)
            return
        end
        settings.bg = theme.bg_theme()
        pcall(function() settings:save() end)
        msg('background tint: %s', theme.bg_theme())
        --[[ Said out loud, because switching a tint with no sheet on disk looks like a
             command that did nothing at all. ]]
        if not theme.bg_available() then
            line('note: the page sheets are not both on disk, so the panes stay on '
                 .. 'their flat fills')
        end

    elseif cmd == 'scale' then
        local v = tonumber(a1)
        if not v then err('usage: //qmui scale <0.6-2.5>') return end
        --[[ Every cached size changes, so the pool is rebuilt from scratch. This
             is the one place objects are destroyed outside unload, and it is safe
             because it happens on a command and not during a frame, which is the
             discipline render/markers.lua states at markers.lua:12-14. ]]
        theme.set_scale(v)
        pcall(panel.destroy)
        panel.invalidate()
        --[[ The icon scales with the panel, so scaling up can push an icon that
             was flush against an edge off it. Re-clamped through its own setter
             rather than left for the next load to fix. ]]
        local lg = launcher.geom()
        launcher.set_pos(lg.x, lg.y)
        lg = launcher.geom()
        settings.icon_x, settings.icon_y = lg.x, lg.y
        settings.scale = theme.scale
        pcall(function() settings:save() end)
        msg('scale %.2f', theme.scale)

    elseif cmd == 'opacity' then
        if a1 == nil or a1 == '' then
            msg('panel opacity %.2f   (0.15 to 1.00)', theme.opacity)
            return
        end
        local v = tonumber(a1)
        if not v then err('usage: //qmui opacity <0.15-1>') return end
        --[[ Colours only, so the pool is not rebuilt: `scale` destroys it
             because every cached SIZE changes, and nothing here does.
             invalidate() is enough to redraw the surfaces. ]]
        theme.set_opacity(v)
        panel.invalidate()
        settings.opacity = theme.opacity
        pcall(function() settings:save() end)
        msg('panel opacity %.2f', theme.opacity)

    elseif cmd == 'path' then
        local p = table.concat({a1, a2, ...}, ' ')
        if p == '' then
            msg('questmarks path: %s', qm_path())
            return
        end
        settings.questmarks_path = p
        pcall(function() settings:save() end)
        pcall(panel.destroy)
        attach()

    elseif cmd == 'reload' then
        pcall(panel.destroy)
        attach()

    elseif cmd == 'diag' then
        cmd_diag()

    elseif cmd == 'help' then
        msg('commands:')
        for _, h in ipairs(HELP) do line('%s', h) end

    else
        err('unknown command "%s"', cmd)
        for _, h in ipairs(HELP) do line('%s', h) end
    end
end)
