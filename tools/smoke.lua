--[[
tools/smoke.lua -- load the real questmarks-ui against a stub client, drive every
command, and render the panel to ASCII from the recorded draw calls.

    luajit tools/smoke.lua

Modelled on questmarks/tools/smoke.lua, which exists for the reason its header
gives: the entry point is event handlers and formatters that no unit test ever
executes, and a crash there can otherwise only be found in game, in a chat
window you cannot copy out.

This one goes further in one respect. The stub `windower.prim` and
`windower.text` do not discard their calls, they record them, so the harness can
rasterise the result to a character grid. That turns "it did not throw" into
"here is what it drew", which is the only way to check layout without the game.

Three things it asserts that matter:
  * nothing throws, on any command, in any state;
  * the panel draws the right rows in the right groups;
  * unload leaves zero named objects behind. Orphaned prims stay on screen until
    Windower restarts, so this is the one failure the player cannot recover from
    and it is checked explicitly.

Build-time only. Reads questmarks; writes nothing anywhere.
]]

--[[ Both roots are derived from where this script was invoked, never hardcoded:
     a hardcoded absolute path runs on exactly one machine and names whoever owns
     it. `arg[0]` is the path the interpreter was handed, so stripping
     `tools/<file>` off it leaves the addon directory, and Windower's own root is
     two levels above that. Works from a clone, and from an absolute invocation
     out of another directory. ]]
local A = ((arg and arg[0]) or ''):gsub('\\', '/'):gsub('tools/[^/]*$', '')
if A == '' then A = './' end
local W = A .. '../../'
package.path = A .. '?.lua;' .. package.path

_addon = {name = 'questmarks-ui', version = 'smoke', language = 'English',
          command = 'qmui', commands = {}}

local events, chat = {}, {}
local function noop() end
local function nooptbl() return {} end

-- ---------------------------------------------------------------------------
-- Recording prim / text stubs
-- ---------------------------------------------------------------------------

local objs = {}      -- name -> {kind, x, y, w, h, a, r, g, b, text, vis, size}
local calls = 0

local function obj(name, kind)
    local o = objs[name]
    if not o then
        o = {kind = kind, name = name, vis = false}
        objs[name] = o
    end
    return o
end

local prim = {
    create = function(n) obj(n, 'prim') end,
    delete = function(n) objs[n] = nil end,
    set_position = function(n, x, y) local o = obj(n, 'prim') o.x, o.y = x, y calls = calls + 1 end,
    set_size = function(n, w, h) local o = obj(n, 'prim') o.w, o.h = w, h calls = calls + 1 end,
    set_color = function(n, a, r, g, b) local o = obj(n, 'prim') o.a, o.r, o.g, o.b = a, r, g, b calls = calls + 1 end,
    set_visibility = function(n, v) obj(n, 'prim').vis = v calls = calls + 1 end,
    --[[ The texture path is recorded, not discarded, and that is the fifth time a
         stub here has been more permissive than the thing it stands in for.

         `set_texture = noop` is enough while nothing draws an image. The launcher
         says which book it is showing entirely through this call, so a stub that
         throws the path away makes the open and closed state, which is the whole
         feature, invisible to the harness: every assertion about it would pass on
         a launcher that drew the wrong book, or no book at all.

         `set_fit_to_texture` is recorded for the same reason. With fit true the
         quad silently takes the texture's own 64 px size and ignores every
         set_size call, so "the icon respects the scale setting" is a claim that
         needs the flag to be observable. ]]
    set_texture = function(n, p) obj(n, 'prim').tex = p calls = calls + 1 end,
    set_fit_to_texture = function(n, v) obj(n, 'prim').fit = v and true or false end,
    set_repeat = noop,
}

local text = {
    saved_texts = {},
    create = function(n) obj(n, 'text') end,
    delete = function(n) objs[n] = nil end,
    set_text = function(n, s) obj(n, 'text').text = s calls = calls + 1 end,
    set_location = function(n, x, y) local o = obj(n, 'text') o.x, o.y = x, y calls = calls + 1 end,
    set_color = function(n, a, r, g, b) local o = obj(n, 'text') o.a, o.r, o.g, o.b = a, r, g, b calls = calls + 1 end,
    set_visibility = function(n, v) obj(n, 'text').vis = v calls = calls + 1 end,
    set_font = function(n, f) obj(n, 'text').font = f end,
    set_font_size = function(n, s) obj(n, 'text').size = s end,
    set_bold = noop, set_italic = noop,
    set_bg_color = noop, set_bg_visibility = noop, set_bg_border_size = noop,
    set_stroke_width = noop,
    --[[ RECORDED, not discarded, and this is the sixth time a stub here has been more
         permissive than the thing it stands in for. The outline colour was a hardcoded
         near-black in ui/draw.lua and nothing themed it; the parchment preset takes it
         to zero alpha, because a dark halo around dark ink at 9pt is a smudge. A no-op
         stub makes that change invisible to every assertion. ]]
    set_stroke_color = function(n, a, r, g, b)
        local o = obj(n, 'text')
        o.sa, o.sr, o.sg, o.sb = a, r, g, b
        calls = calls + 1
    end,
    set_right_justified = noop, set_bottom_justified = noop,
    get_location = function(n) local o = objs[n] return o and o.x or 0, o and o.y or 0 end,
    --[[ Models the real thing, which means modelling the unit conversion.
         set_font_size takes points, so a character of a monospace font is
         size * (96/72) * advance px wide: for Consolas that is size * 0.733, not
         size * 0.55. A stub that returns 0.55 while the addon assumes 0.55 agrees
         with the addon and disagrees with the game, so the offline picture looks
         correct while text overflows in play. A harness that shares the code's
         mistake cannot catch it. ]]
    get_extents = function(n)
        local o = objs[n]
        if not o or not o.text then return 0, 0 end
        local per = (o.size or 10) * (96 / 72) * 0.5498
        return math.floor(#o.text * per), math.floor((o.size or 10) * 1.4)
    end,
}

windower = {
    addon_path = A,
    windower_path = W,
    add_to_chat = function(_, s) chat[#chat + 1] = s end,
    register_event = function(...)
        local a = {...}
        local fn = a[#a]
        for i = 1, #a - 1 do
            events[a[i]] = events[a[i]] or {}
            table.insert(events[a[i]], fn)
        end
        return #events
    end,
    unregister_event = noop,
    send_command = noop,
    from_shift_jis = function(s) return s end,
    to_shift_jis = function(s) return s end,
    get_windower_settings = function()
        return {x_res = 1280, y_res = 720, ui_x_res = 1280, ui_y_res = 720}
    end,
    get_camera = function() return nil end,
    prim = prim,
    text = text,
    packets = {parse_action = function() return nil end},
    ffxi = {
        get_info = function()
            return {zone = 245, logged_in = true, mog_house = false,
                    day = 1, moon = 21, moon_phase = 1, time = 1191,
                    weather = 0, menu_open = false, chat_open = false,
                    server = 5, language = 'English'}
        end,
        get_player = function()
            return {name = 'Smoke', main_job = 'RDM', main_job_level = 99,
                    id = 1, index = 1}
        end,
        get_items = function() return {} end,
        get_key_items = nooptbl,
        get_bag_info = function() return {max = 80, count = 0, enabled = true} end,
        get_mob_by_target = nooptbl,
        get_mob_by_index = function() return nil end,
        get_mob_by_id = function() return nil end,
        get_mob_list = nooptbl,
        get_party = nooptbl,
    },
}

_libs = {}
package.loaded['logger'] = true
--[[ The config stub now models the XML serialiser's one hard constraint.

     Windower's config writes a settings table to XML with every table KEY as an
     Element name. The old stub was a no-op, so nothing here ever exercised that,
     and the addon shipped a set keyed by `cat/area/id`:

         <mission/windurst/4>true</mission/windurst/4>

     A slash is not legal in an XML name, so the file it wrote could not be read
     back and the addon failed to LOAD:

         Lua runtime error: libs/config.lua:99: XML error, line 9:
         Mismatched tag ending: </mission

     This is the fourth time in this project a stub was more permissive than the
     thing it stood in for. So `save` now walks the table and rejects any key
     that would not survive the round trip, which is the property that actually
     matters. ]]
local settings_ref = nil

local function xml_name_ok(k)
    if type(k) ~= 'string' then return false end          -- numeric keys index
    return k:match('^[%a_][%w_%.%-]*$') ~= nil
end

local function check_keys(t, path, bad)
    for k, v in pairs(t) do
        if k ~= 'save' and not xml_name_ok(k) then
            bad[#bad + 1] = (path or '') .. tostring(k)
        end
        if type(v) == 'table' then
            check_keys(v, (path or '') .. tostring(k) .. '/', bad)
        end
    end
    return bad
end

local settings_saves = 0

package.loaded['config'] = {
    load = function(defaults)
        local t = defaults or {}
        --[[ Counted, not ignored. "The position was saved" is otherwise not an
             observable fact, and a test that reads the value the addon set in
             memory passes whether or not the writer ever ran. ]]
        t.save = function(self) settings_saves = settings_saves + 1 end
        settings_ref = t
        return t
    end,
    save = noop,
    _get = function() return settings_ref end,
    _saves = function() return settings_saves end,
    _check = function()
        if not settings_ref then return {} end
        return check_keys(settings_ref, '', {})
    end,
    --[[ Did the addon actually put anything in the per-character store? Without
         this the key check passes on an empty table, which is how the first
         version of this test passed with the bug present. ]]
    _seen = function()
        local t = settings_ref and settings_ref.seen_done_by_char
        if type(t) ~= 'table' then return nil end
        for _, v in pairs(t) do return v end
        return nil
    end,
    _wrote = function()
        local t = settings_ref and settings_ref.seen_done_by_char
        if type(t) ~= 'table' then return nil end
        for _ in pairs(t) do return true end
        return nil
    end,
}

-- Queue a parsed packet for the next 'incoming chunk' with id 0x056.
local next_packet = nil
package.loaded['packets'] = {
    parse = function() return next_packet end,
    new = function() return {} end,
}

-- Never touch the player's real settings.xml.
local real_open = io.open
io.open = function(path, mode)
    if mode and mode:find('w') and tostring(path):find('settings') then
        return {write = noop, close = noop}
    end
    return real_open(path, mode)
end

-- ---------------------------------------------------------------------------
-- Load
-- ---------------------------------------------------------------------------

local failures = 0
--[[ check_dialect's own file list, kept so the coverage check further down can
     compare it against what the addon actually loaded. ]]
local dialect_files = nil
local function ok_(label, extra)
    print(('[ OK ] %-46s %s'):format(label, extra or ''))
end
local function fail_(label, e)
    failures = failures + 1
    print(('[FAIL] %-46s %s'):format(label, tostring(e)))
end

--[[ The dialect check runs first, because everything below it is worthless if
     the game cannot parse the file at all. This harness runs LuaJIT, which
     accepts Lua 5.2 constructs the in-game 5.1 interpreter rejects outright --
     so a green suite here is not evidence the addon loads. It shipped a
     `goto continue` once and the game answered with a parse error. ]]
do
    local okd, dialect = pcall(require, 'tools/check_dialect')
    if not okd then
        fail_('dialect check could not run', dialect)
    else
        local found = dialect.scan()
        if #found == 0 then
            ok_('dialect: nothing the in-game Lua 5.1 cannot parse',
                (#dialect.files) .. ' files')
        else
            for _, p in ipairs(found) do
                fail_(('dialect %s:%d'):format(p.file, p.line), p.why)
            end
        end
        dialect_files = dialect.files
    end
end

local loaded, lerr = pcall(dofile, A .. 'questmarks-ui.lua')
if not loaded then
    print('FAIL  questmarks-ui.lua did not load: ' .. tostring(lerr))
    os.exit(1)
end
ok_('questmarks-ui.lua loads against a stub client')

local model = require('model')
local panel = require('ui/panel')
local theme = require('ui/theme')
local function theme_s(v) return theme.s(v) end
local draw  = require('ui/draw')
local MET   = require('ui/metrics')

if model.status ~= 'ok' then
    fail_('model attached to questmarks', model.detail)
else
    local m = model.meta or {}
    ok_('model attached to questmarks',
        ('%s entries'):format(tostring(m.indexed)))
end

local cmd = events['addon command'] and events['addon command'][1]
if not cmd then print('FAIL  no addon command handler') os.exit(1) end

local function run(...)
    local before = #chat
    local okc, e = pcall(cmd, ...)
    local label = '//qmui ' .. table.concat({...}, ' ')
    if okc then ok_(label, ('%d line(s)'):format(#chat - before))
    else fail_(label, e) end
end

-- ---------------------------------------------------------------------------
-- Commands with an empty quest log
-- ---------------------------------------------------------------------------

print('\n=== commands, with nothing accepted ===')
for _, c in ipairs({
    {'help'}, {'diag'}, {'list'}, {'show'}, {'accepted'}, {'handin'},
    {'next'}, {'prev'}, {'pick', '1'}, {'scroll', '3'}, {'top'}, {'bottom'},
    {'search', 'wildcat'}, {'search'}, {'fold', 'Jeuno'}, {'foldall'},
    {'unfoldall'}, {'pos', '60', '90'}, {'scale', '1.0'},
    {'not-a-command'}, {'hide'},
}) do run(unpack(c)) end

-- ---------------------------------------------------------------------------
-- Feed a real quest log through the REAL handler path
-- ---------------------------------------------------------------------------

print('\n=== feeding packet 0x056 through the addon\'s own handler ===')

local chunk = events['incoming chunk'] and events['incoming chunk'][1]
if not chunk then print('FAIL  no incoming chunk handler') os.exit(1) end

local function blob(ids)
    local b = {}
    for i = 1, 32 do b[i] = 0 end
    for _, id in ipairs(ids) do
        local p = math.floor(id / 8) + 1
        b[p] = b[p] + 2 ^ (id % 8)
    end
    local s = {}
    for i = 1, 32 do s[i] = string.char(b[i]) end
    return table.concat(s)
end

local function feed(subtype, ids)
    next_packet = {Type = subtype, ['Quest Flags'] = blob(ids)}
    local okp, e = pcall(chunk, 0x056, 'raw')
    next_packet = nil
    if not okp then fail_(('0x056 subtype 0x%04X'):format(subtype), e) end
end

--[[ current / completed pairs across four of the game's own log sections.

     Four ids are here for the requirement shapes and nothing else, because a
     phrasing rule has to be asserted on the data it was derived from:

       jeuno/91      The Road to Aht Urhgan  step  2  reqs_partial, NO list at all
       jeuno/102     Unlocking a Myth (WAR)  step  1  a requirement to be EQUIPPED
       jeuno/132     Shattering Stars        step  3  reqs_alt of 15, past the cap
       outlands/165  Open Sesame             step  3  reqs AND reqs_alt AND partial

     And two for the title width check, which without them proves nothing: no title
     in the rest of this fixture comes within 21 px of the chevron column, so
     removing the reserve that keeps them apart left every assertion green. Both
     have an authoring note, which is what makes a step expandable and so gives it a
     chevron to collide with.

       jeuno/64      step 5  481 px  a trade title plus a three-mob spawn suffix
       outlands/145  step 3  315 px  a fight title listing three kill mobs

     And two more for the drop-source line, for the same reason: every drop-mob
     step in the rest of this fixture is an `obtain`, so the half of that rule
     which matters most, that `fight` and `trade` steps stop discarding the field
     entirely, would have no data behind it.

       jeuno/26      Deal with Tenshodo  step 2  a trade step, two drop mobs
       windurst/66   The Three Magi      step 4  a fight step, one drop mob
       jeuno/60      Wings of Gold       step 2  thirteen drop mobs, past the cap

     The rest carry the remaining shapes: windurst/90 step 5 is the plain `reqs`
     case, jeuno/27 step 2 is the four-items-or-a-Goblin-Stew case that
     `inventory.meets` exists for, jeuno/131 step 4 is four key items, and
     windurst/20 step 3 is two alternatives that resolve to one name.

     All four are in Jeuno or Outlands deliberately. The malformed-payload check
     below feeds `{Type = 0x0050, ['Quest Flags'] = 'x'}`, and a one-byte blob is
     a perfectly well-formed bitfield as far as state.lua is concerned, so it
     replaces the San d'Oria current set with 0x78, ids 3-6. Every San d'Oria row
     in this fixture is one of those four, not one of the five fed here, and an id
     added to this line would never reach the panel. ]]
feed(0x0050, {4, 7, 9, 11, 30})       -- current San d'Oria quests (see above)
feed(0x0090, {})                      -- completed San d'Oria quests
feed(0x0060, {0, 12, 20, 40, 66, 90}) -- Windurst: 0 Hat in Hand, 20 Early Bird, 90 Tuning In
feed(0x00A0, {})
feed(0x0068, {26, 27, 60, 64, 90, 91, 102, 131, 132})  -- current Jeuno quests
feed(0x00A8, {})
feed(0x0078, {3, 19, 145, 165})       -- current Outlands quests
feed(0x00B8, {})
ok_('0x056 accepted through the real handler', 'eight sub-types')

-- Malformed payloads must not throw.
for _, bad in ipairs({{}, {Type = 0x0050}, {Type = 0x0050, ['Quest Flags'] = 'x'},
                      {Type = 0x9999, ['Quest Flags'] = blob{1}}}) do
    next_packet = bad
    local okp, e = pcall(chunk, 0x056, 'raw')
    next_packet = nil
    if not okp then fail_('0x056 survives a malformed payload', e) end
end
ok_('0x056 survives malformed payloads', '4 shapes')

for _, id in ipairs({0x055, 0x01F, 0x020, 0x999}) do
    local okp, e = pcall(chunk, id, 'raw')
    if not okp then fail_(('packet 0x%03X survives'):format(id), e) end
end
ok_('other packet ids survive', '0x055 0x01F 0x020 0x999')

local inventory = require('core/inventory')
inventory.reset()
inventory.refresh(true)
model.refresh_player()
panel.invalidate()

-- ---------------------------------------------------------------------------
-- Commands with a populated quest log
-- ---------------------------------------------------------------------------

print('\n=== commands, with quests accepted ===')
for _, c in ipairs({
    {'show'}, {'list'}, {'diag'}, {'next'}, {'next'}, {'next'}, {'pick', '2'},
    {'handin'}, {'accepted'}, {'search', 'the'}, {'search'},
    {'fold', "San d'Oria"}, {'fold', "San d'Oria"}, {'scroll', '5'}, {'top'},
}) do run(unpack(c)) end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

print('\n=== render ===')

local prerender = events['prerender'] and events['prerender'][1]
if not prerender then print('FAIL  no prerender handler') os.exit(1) end

pcall(cmd, 'show')
pcall(cmd, 'unfoldall')
pcall(cmd, 'top')
local before_calls = calls
-- Raw render probe: call the panel directly so a layout error surfaces here
-- instead of being swallowed by the addon's own prerender pcall.
local okraw, eraw = pcall(panel.render)
if not okraw then fail_('panel.render (raw)', eraw) end
local okr, e = pcall(prerender)
if not okr then fail_('prerender draws the panel', e)
else ok_('prerender draws the panel', ('%d native calls'):format(calls - before_calls)) end

--[[ A second identical frame must issue NOTHING: every native call is
     change-detected, and the measured figure is zero rather than "few". It is
     asserted as zero because a threshold nobody can name is a test that
     cannot fail: this branch used to report a pass either way, so a frame
     that reissued all 1069 calls would still have printed OK. ]]
before_calls = calls
pcall(prerender)
local steady = calls - before_calls
if steady == 0 then
    ok_('a static frame issues ZERO native calls', 'change detection works')
else
    fail_('a static frame reissued native calls', ('%d'):format(steady))
end

--[[ Select the quest whose ladder has the most steps that cannot be marked,
     which is the case the authoring notes exist to rescue, so the picture below
     shows the detail pane doing the thing it is for rather than a tidy
     three-step quest where nothing is at stake. ]]
do
    --[[ Prefer "Early Bird Catches the Bookworm" (quest/windurst/20): 7 steps,
         an uncertain band of 3-5, TWO optional steps, and step numbers that a
         collapsed ladder has to fit whole. It is the case the user reported
         twice. Falls back to Hat in Hand, then to whatever has the most
         unmarkable steps. ]]
    --[[ "Tuning In" (quest/windurst/90) is the reported case for step phrasing:
         three consecutive `obtain` steps whose mobs are the SOURCE and whose
         object lives in `ev`. ]]
    local pref = nil
    for i, l in ipairs(panel.S.lines) do
        if l.kind == 'row' and l.row.key == 'quest/windurst/90' then pref = i break end
    end
    if pref then
        panel.S.sel, panel.S.sel_key = pref, panel.S.lines[pref].row.key
        panel.S.dkey = nil
        print(('  (detail pane shows %s)'):format(panel.S.lines[pref].row.name))
    end
    if not pref then
    --[[ Prefer "Hat in Hand" (quest/windurst/0): step 1 carries evidence and
         steps 2-10 carry none, so it is the exemplar of a ladder that cannot
         advance, which is the case the fog rule and the notes exist for. Falls
         back to whichever quest has the most unmarkable steps. ]]
    local best, bestn = nil, -1
    for i, l in ipairs(panel.S.lines) do
        if l.kind == 'row' then
            if l.row.key == 'quest/windurst/0' then best, bestn = i, -2 break end
            local lad = model.ladder(l.row.entry)
            local n = 0
            for _, rr in ipairs(lad and lad.rows or {}) do
                if not rr.markable then n = n + 1 end
            end
            if n > bestn then best, bestn = i, n end
        end
    end
    if best then
        panel.S.sel, panel.S.sel_key = best, panel.S.lines[best].row.key
        print(('  (detail pane shows %s)'):format(panel.S.lines[best].row.name or '?'))
    end
    end
end
pcall(prerender)

-- ---------------------------------------------------------------------------
-- Rasterise
-- ---------------------------------------------------------------------------

--[[ Each pane is rasterised on its own rows, then the two are put side by side.

     Two earlier attempts failed for opposite reasons and both are worth
     recording, because the harness misleading you is worse than no harness.

     A fixed cell height works only while everything shares one line pitch, and
     the list rows and the detail lines do not: the picture drifts a line every
     few rows and invents a layout bug that is not there, such as step 1 appearing
     to lose its zone line when the text dump shows it has not.

     Ordinal rows over all objects fixes the drift but not the problem: the two
     panes have unrelated y values, so every baseline in either pane becomes a row
     and the result is a very tall, mostly blank picture with the two panes
     interleaved.

     So: group by pane, give each pane ordinal rows of its own, then zip. Within a
     pane the reading order and grouping are exact; the horizontal axis stays
     absolute and font-size-scaled, which is what catches text overflowing its
     pane, and that is what this harness is for.

     `CW` is the horizontal cell, and it is the only cell: there is no vertical one,
     because rows are ordinal per pane and nothing here has to divide the panel's
     row pitch. ]]
local CW = 6

local function pane_rows(pick)
    local ys, seen = {}, {}
    local minx, maxx = 1e9, -1e9
    local mine = {}
    for _, o in pairs(objs) do
        if o.vis and o.x and pick(o) then
            mine[#mine + 1] = o
            if not seen[o.y] then seen[o.y] = true ys[#ys + 1] = o.y end
            minx = math.min(minx, o.x)
            maxx = math.max(maxx, o.x + (o.w or MET.width(o.text or '', o.size or 10)))
        end
    end
    if #ys == 0 then return {} end
    table.sort(ys)

    local gaps = {}
    for i = 2, #ys do gaps[#gaps + 1] = ys[i] - ys[i - 1] end
    table.sort(gaps)
    local med = gaps[math.max(1, math.floor(#gaps / 2))] or 1

    --[[ Baselines within a few pixels of each other are the SAME line. A row's
         state chip is centred in its height while its name sits on the text
         baseline, so the two differ by a pixel or two and would otherwise split
         every quest row across two grid lines. ]]
    local TOL = 5
    local rowof, rows = {}, 0
    local anchor = nil
    for i, y in ipairs(ys) do
        if anchor and (y - anchor) <= TOL then
            rowof[y] = rows
        else
            if anchor and (y - anchor) > med * 1.8 then rows = rows + 1 end
            rows = rows + 1
            rowof[y] = rows
            anchor = y
        end
    end

    local cols = math.ceil((maxx - minx) / CW) + 2
    local grid = {}
    for r = 1, rows do
        grid[r] = {}
        for c = 1, cols do grid[r][c] = ' ' end
    end

    for _, o in ipairs(mine) do
        if o.kind == 'prim' and o.w and o.h then
            local r0, r1
            for _, y in ipairs(ys) do
                if y >= o.y and y < o.y + o.h then
                    r0 = r0 or rowof[y]; r1 = rowof[y]
                end
            end
            if r0 then
                local c0 = math.floor((o.x - minx) / CW) + 1
                local c1 = math.floor((o.x + o.w - minx) / CW)
                local shade = ((o.a or 0) > 200) and '.' or ' '
                for r = r0, r1 do
                    for c = math.max(1, c0), math.min(cols, c1) do
                        if grid[r][c] == ' ' then grid[r][c] = shade end
                    end
                end
            end
        end
    end

    for _, o in ipairs(mine) do
        if o.kind == 'text' and o.text and o.text ~= '' then
            local r = rowof[o.y]
            local c0 = math.floor((o.x - minx) / CW) + 1
            local px = MET.width(o.text, o.size or 10, o.font ~= 'Segoe UI')
            local cells = math.max(1, math.floor(px / CW))
            local str = o.text
            if cells < #str then str = str:sub(1, cells) end
            if r then
                for i = 1, #str do
                    local c = c0 + i - 1
                    if c >= 1 and c <= cols then grid[r][c] = str:sub(i, i) end
                end
            end
        end
    end

    local out = {}
    for r = 1, rows do out[r] = table.concat(grid[r]) end
    return out
end

--[[ The launcher is left out of the picture, and it has to be said why.

     `pane_rows` frames each pane on the bounding box of everything visible in it,
     so a 32 px icon parked at 20,20, far to the left of a panel at x=60, widens the
     left pane by seven columns of empty padding and pushes the whole picture
     across. The picture exists to check the panel's layout, and the icon is not
     part of that layout; it is checked by its own assertions, which read the
     recorded draw calls directly and do not need a character grid.

     Excluded by the names the launcher owns, not by position: "anything left of
     the panel" would also drop a panel object that had escaped its own pane, which
     is precisely the class of bug this picture exists to show. ]]
local function launcher_names()
    local set = {}
    local okn, names = pcall(require('ui/launcher').names)
    if okn and type(names) == 'table' then
        for _, n in pairs(names) do set[n] = true end
    end
    return set
end

local function rasterise()
    local skip = launcher_names()
    local split = panel.geom().dx - 4
    local left  = pane_rows(function(o) return o.x < split and not skip[o.name] end)
    local right = pane_rows(function(o) return o.x >= split and not skip[o.name] end)
    local n = math.max(#left, #right)
    if n == 0 then print('  (nothing visible)') return end
    local lw = 0
    for _, l in ipairs(left) do lw = math.max(lw, #l) end
    for r = 1, n do
        local a = left[r] or ''
        a = a .. (' '):rep(math.max(0, lw - #a))
        local b = right[r] or ''
        print(('  |%s | %s'):format(a, (b:gsub('%s+$', ''))))
    end
end

rasterise()

--[[ The detail pane in full. The picture above is geometrically faithful and
     therefore drops characters from the smaller fonts; this is what the client
     actually renders, string for string, top to bottom. ]]
print('\n=== detail pane, text as drawn ===')
do
    local dx = panel.geom().dx - 4
    local list = {}
    for _, o in pairs(objs) do
        if o.vis and o.kind == 'text' and o.text and o.text ~= ''
           and o.x and o.x > dx then
            list[#list + 1] = o
        end
    end
    table.sort(list, function(a, b)
        if a.y ~= b.y then return a.y < b.y end
        return a.x < b.x
    end)
    for _, o in ipairs(list) do print('  ' .. o.text) end
end

-- ---------------------------------------------------------------------------
-- What the chat commands print
-- ---------------------------------------------------------------------------

print('\n=== //qmui list ===')
local mark = #chat
pcall(cmd, 'list')
for i = mark + 1, #chat do print('  ' .. chat[i]) end

print('\n=== //qmui diag ===')
mark = #chat
pcall(cmd, 'diag')
for i = mark + 1, #chat do print('  ' .. chat[i]) end

-- ---------------------------------------------------------------------------
-- Mouse
-- ---------------------------------------------------------------------------

print('\n=== mouse ===')
local mouse = events['mouse'] and events['mouse'][1]
if not mouse then fail_('mouse handler registered') else
    local g = panel.geom()
    local cases = {
        {0, g.x + 50, g.y + 100, 0, 'move over a row'},
        {1, g.x + 50, g.y + 100, 0, 'left click a row'},
        {2, g.x + 50, g.y + 100, 0, 'left release'},
        {10, g.x + 50, g.y + 100, 1, 'wheel up'},
        {10, g.x + 50, g.y + 100, -1, 'wheel down'},
        {3, g.x + 50, g.y + 100, 0, 'right click'},
        {1, g.x + 50, g.y + 40, 0, 'click a filter chip'},
        {1, 5, 5, 0, 'click outside the panel'},
        {1, g.x + 50, g.y + 100, 0, 'click with blocked=true'},
    }
    for _, c in ipairs(cases) do
        local okm, r = pcall(mouse, c[1], c[2], c[3], c[4], false)
        if okm then ok_('mouse: ' .. c[5], ('blocked=%s'):format(tostring(r)))
        else fail_('mouse: ' .. c[5], r) end
    end
    local okm = pcall(mouse, 1, g.x + 50, g.y + 100, 0, true)
    if okm then ok_('mouse: blocked events are ignored') end

    --[[ Regression: A press and its release must both be swallowed.

         Eat the press, close the panel, and the release falls through to the
         client as an orphan: its mouse-look state is left believing a button is
         still down, so the camera spins until the next click and that click opens
         a target menu.

         Three cases, and the second is the one that regresses. ]]
    pcall(cmd, 'show')
    local g2 = panel.geom()
    local closeX, closeY = g2.x + g2.w - theme_s(10), g2.y + theme_s(8)

    local _, d1 = pcall(mouse, 1, closeX, closeY, 0, false)
    local _, u1 = pcall(mouse, 2, closeX, closeY, 0, false)
    if d1 == true and u1 == true and not panel.is_open() then
        ok_('mouse: closing with X swallows BOTH press and release',
            'no orphan release reaches the game')
    else
        fail_('mouse: closing with X swallows both',
              ('down=%s up=%s open=%s'):format(tostring(d1), tostring(u1),
                                               tostring(panel.is_open())))
    end

    -- A release with no press of ours must not be eaten, or the game's own
    -- clicks get swallowed.
    local _, u2 = pcall(mouse, 2, 5, 5, 0, false)
    if u2 == false then
        ok_('mouse: a release we never pressed is passed through')
    else
        fail_('mouse: unmatched release', tostring(u2))
    end

    -- Press on the panel, release somewhere else: still ours to swallow, and
    -- the action must NOT fire because the pointer left the target.
    pcall(cmd, 'show')
    pcall(cmd, 'top')
    local before_open = panel.is_open()
    local _, d3 = pcall(mouse, 1, panel.geom().x + panel.geom().w - theme_s(10),
                        panel.geom().y + theme_s(8), 0, false)
    local _, u3 = pcall(mouse, 2, 5, 500, 0, false)
    if d3 == true and u3 == true and panel.is_open() == before_open then
        ok_('mouse: press-then-release-elsewhere swallows the pair',
            'and does not fire the action')
    else
        fail_('mouse: drag off target',
              ('down=%s up=%s open=%s'):format(tostring(d3), tostring(u3),
                                               tostring(panel.is_open())))
    end
end

-- ---------------------------------------------------------------------------
-- The launcher: a book you click to open the log
-- ---------------------------------------------------------------------------

--[[ A closed book sits wherever it was left; clicking it opens the log and the
     book opens with it.

     What is worth asserting here, in order:

       * that the two PNGs are on disk and are the size the code assumes. A prim
         whose texture will not load draws nothing and reports nothing, so a
         missing file is an invisible 32 px click target, indistinguishable in game
         from the icon being switched off. questmarks checks its own assets this
         way for the same reason, in its `assets are ours` block.

       * that the book drawn matches the panel's state through every path that can
         change it, not just through the click. The state is derived from
         panel.is_open() on each frame precisely so it cannot drift, and the way to
         test a derived value is to change the source from somewhere the icon has
         never heard of, a command or the X button, and look at what was drawn.

       * that a click is a click and a drag is a drag. Without a travel threshold
         every click is also a one-pixel drag, and the icon creeps across the
         screen as it is used.

     Read back from the recorded draw calls, never from launcher's own state: the
     question is what reached the client. ]]
print('')
print('=== the launcher ===')
do
    local launcher = require('ui/launcher')
    local cfg = package.loaded['config']

    --[[ The icon is asked for by role, not found by scanning.

         This used to take the only `qmui_img_*` object in the pool, which was true
         until the two pane backgrounds became textures as well. Then there were three,
         `pairs` handed them back in whatever order it felt like, and these assertions
         checked a pane background instead of the icon on roughly half of all runs --
         a flaky suite, which is worse than a failing one. It also asserts the thing
         worth asserting: the launcher's name for its image is an `img` object and so
         an image prim, not a coloured rect. ]]
    local function icon_obj()
        local n = launcher.names().img
        if not n then return nil end
        if not n:match('^qmui_img_') then
            fail_('launcher: its image is an image prim', n)
        end
        return objs[n], n
    end

    -- A PNG's width and height are big-endian 32-bit at offsets 16 and 20.
    local function png_size(path)
        local f = real_open(path, 'rb')
        if not f then return nil, 'missing' end
        local head = f:read(24)
        local n = f:seek('end')
        f:close()
        if not head or #head < 24 then return nil, 'truncated' end
        if head:sub(2, 4) ~= 'PNG' then return nil, 'not a PNG' end
        local function be32(s)
            local a, b, c, d = s:byte(1, 4)
            return ((a * 256 + b) * 256 + c) * 256 + d
        end
        return be32(head:sub(17, 20)), be32(head:sub(21, 24)), n
    end

    --[[ Nothing is drawn behind the book.

         A dark plate under it is arguable on legibility grounds and reads in game
         as a blue rectangle around the icon. The art carries its own near-black
         outline, about 3 px on every shape, so a plate is belt and braces and what
         it contributes is the blue. Asserted as a count, because "the plate is
         invisible" and "the plate is gone" are different things and only the second
         cannot come back as a colour someone tweaks. ]]
    do
        local owned = launcher.names()
        local n = 0
        for _ in pairs(owned) do n = n + 1 end
        if n == 1 and owned.img then
            ok_('launcher: the icon is the only thing it draws',
                'no plate, no backing rect -- the art carries its own outline')
        else
            local ks = {}
            for k in pairs(owned) do ks[#ks + 1] = k end
            table.sort(ks)
            fail_('launcher: it draws more than the book',
                  ('%d objects: %s'):format(n, table.concat(ks, ' ')))
        end
    end

    --[[ Image prims are not rare, and the launcher's must not be any of the panel's.

         Picking "the only `qmui_img_*`" out of the pool is how this went flaky: the
         two pane backgrounds are image prims too, and the region badges add one per
         row slot, so the pool holds twenty-odd. The assertion is written against the
         whole set rather than against the two it started with, because the next
         image prim added is exactly the one nobody remembers to list here. ]]
    do
        local o, n = icon_obj()
        local clash = nil
        local function check(obj, what)
            if obj and obj.name == n then clash = what end
        end
        check(panel.W and panel.W.bg, 'the list pane background')
        check(panel.W and panel.W.d_bg, 'the detail pane background')
        for i, w in ipairs((panel.W and panel.W.lines) or {}) do
            check(w.ico, 'the badge in row slot ' .. i)
        end
        if o and n and not clash then
            ok_('launcher: its image is its own object, no panel image shares its name',
                ('%s, against %d panel image prims')
                :format(n, 2 + #((panel.W and panel.W.lines) or {})))
        else
            fail_('launcher: image object identity',
                  ('icon=%s clashes with %s'):format(tostring(n), tostring(clash)))
        end
    end

    for _, which in ipairs({'closed', 'open'}) do
        local p = launcher.asset(which)
        local w, h, bytes = png_size(p)
        if w == 64 and h == 64 then
            ok_(('launcher: the %s book is on disk'):format(which),
                ('64x64 PNG, %d bytes'):format(bytes))
        else
            fail_(('launcher: %s book asset'):format(which),
                  ('%s -- %s'):format(p, tostring(h or w)))
        end
    end

    --[[ The default state the addon loads in: icon shown, log closed. That is the
         whole point of the feature and it is one assertion. ]]
    pcall(cmd, 'hide')
    local okr = pcall(prerender)
    if not okr then fail_('launcher: prerender with the panel closed') end
    local o = icon_obj()
    if launcher.is_on() and not panel.is_open() and o and o.vis then
        ok_('launcher: drawn with the panel closed', 'the default state on load')
    else
        fail_('launcher: default state',
              ('on=%s open=%s vis=%s'):format(tostring(launcher.is_on()),
               tostring(panel.is_open()), tostring(o and o.vis)))
    end

    --[[ The quad is sized EXPLICITLY. With fit_to_texture left true it would take
         the texture's own 64 px and ignore the scale setting entirely. ]]
    if o and o.fit == false and o.w == math.floor(32 * theme.scale + 0.5) then
        ok_('launcher: sized by the addon, not by the texture',
            ('fit=false, %dpx at scale %.2f'):format(o.w, theme.scale))
    else
        fail_('launcher: quad size',
              ('fit=%s w=%s'):format(tostring(o and o.fit), tostring(o and o.w)))
    end

    local function drawn_book()
        local ob = icon_obj()
        local t = ob and ob.tex or ''
        if t:find('book_open', 1, true) then return 'open' end
        if t:find('book_closed', 1, true) then return 'closed' end
        return tostring(t)
    end

    if drawn_book() == 'closed' then
        ok_('launcher: a CLOSED book while the log is closed')
    else
        fail_('launcher: closed-state texture', drawn_book())
    end

    -- Click it: press and release at its centre, through the real mouse handler.
    local lg = launcher.geom()
    local cx, cy = lg.x + math.floor(lg.w / 2), lg.y + math.floor(lg.h / 2)
    local _, d = pcall(mouse, 1, cx, cy, 0, false)
    local _, u = pcall(mouse, 2, cx, cy, 0, false)
    pcall(prerender)
    if d == true and u == true and panel.is_open() then
        ok_('launcher: clicking it opens the log', 'press and release both eaten')
    else
        fail_('launcher: click opens',
              ('down=%s up=%s open=%s'):format(tostring(d), tostring(u),
               tostring(panel.is_open())))
    end
    if drawn_book() == 'open' then
        ok_('launcher: and the book OPENS with it')
    else
        fail_('launcher: open-state texture', drawn_book())
    end

    -- Click it again: closes.
    pcall(mouse, 1, cx, cy, 0, false)
    pcall(mouse, 2, cx, cy, 0, false)
    pcall(prerender)
    if not panel.is_open() and drawn_book() == 'closed' then
        ok_('launcher: clicking the open book closes the log')
    else
        fail_('launcher: second click',
              ('open=%s book=%s'):format(tostring(panel.is_open()), drawn_book()))
    end

    --[[ The desync test, and the reason the texture is derived rather than stored.
         The log closes from six places and only one of them is the icon. Driven
         from the two the icon has never heard of. ]]
    do
        local bad = {}
        pcall(cmd, 'show')
        pcall(prerender)
        if drawn_book() ~= 'open' then bad[#bad + 1] = '//qmui show -> ' .. drawn_book() end
        pcall(cmd, 'hide')
        pcall(prerender)
        if drawn_book() ~= 'closed' then bad[#bad + 1] = '//qmui hide -> ' .. drawn_book() end

        -- And the X button, which is a different code path again.
        pcall(cmd, 'show')
        pcall(prerender)
        local g2 = panel.geom()
        local xx, xy = g2.x + g2.w - theme_s(10), g2.y + theme_s(8)
        pcall(mouse, 1, xx, xy, 0, false)
        pcall(mouse, 2, xx, xy, 0, false)
        pcall(prerender)
        if panel.is_open() then bad[#bad + 1] = 'X button did not close the panel' end
        if drawn_book() ~= 'closed' then bad[#bad + 1] = 'X button -> ' .. drawn_book() end

        if #bad == 0 then
            ok_('launcher: the book follows the log however it was closed',
                'command and X button, neither of which touches the icon')
        else
            fail_('launcher: state drifted', table.concat(bad, ' | '))
        end
    end

    --[[ DRAGGING. Press, travel past the threshold, release: the icon moves, the
         log does NOT toggle, and the position is written through the addon's own
         saver rather than by this test. ]]
    do
        local before_open = panel.is_open()
        local start = launcher.geom()
        local saves = cfg._saves()
        local sx, sy = start.x + 8, start.y + 8
        pcall(mouse, 1, sx, sy, 0, false)
        pcall(mouse, 0, sx + 40, sy + 25, 0, false)
        pcall(mouse, 0, sx + 60, sy + 30, 0, false)
        local _, ur = pcall(mouse, 2, sx + 60, sy + 30, 0, false)
        pcall(prerender)
        --[[ The grab offset is the point of this arithmetic. Pressed 8 px inside
             the icon and released 60,30 further on, so the icon must end 60,30 on
             from where it started, and not with its corner under the cursor. An
             icon that forgets where it was grabbed jumps by the grab offset the
             instant you touch it. ]]
        local after = launcher.geom()
        if after.x == start.x + 60 and after.y == start.y + 30 then
            ok_('launcher: dragging moves it, and keeps the grab offset',
                ('%d,%d -> %d,%d, cursor moved 60,30'):format(start.x, start.y,
                 after.x, after.y))
        else
            fail_('launcher: drag',
                  ('%d,%d -> %d,%d, wanted %d,%d'):format(start.x, start.y,
                   after.x, after.y, start.x + 60, start.y + 30))
        end
        if panel.is_open() == before_open then
            ok_('launcher: a drag does not toggle the log', 'release was a move')
        else
            fail_('launcher: drag toggled the log')
        end
        if ur == true then ok_('launcher: the drag release is swallowed') end

        --[[ The real save path ran. Reading the value the addon set in memory
             would pass with no writer at all. ]]
        local s = cfg._get()
        if cfg._saves() > saves and s.icon_x == after.x and s.icon_y == after.y then
            ok_('launcher: the dropped position is saved',
                ('icon_x=%d icon_y=%d, %d write(s)'):format(s.icon_x, s.icon_y,
                 cfg._saves() - saves))
        else
            fail_('launcher: position not persisted',
                  ('saves=%d icon_x=%s icon_y=%s'):format(cfg._saves() - saves,
                   tostring(s.icon_x), tostring(s.icon_y)))
        end

        --[[ The settings the launcher adds must survive the XML serialiser, which
             writes every key as an element name. Checked over the whole table, so
             this cannot pass by looking only where it expects trouble. ]]
        local bad = cfg._check()
        if #bad == 0 then
            ok_('launcher: its settings keys are legal XML element names',
                'icon, icon_x, icon_y')
        else
            fail_('launcher: illegal settings key', table.concat(bad, ' '))
        end
    end

    --[[ A click with a shaky hand is still a click. Below the threshold the icon
         must not move and the log must toggle. Without this the icon walks across
         the screen a pixel at a time as it is used. ]]
    do
        local start = launcher.geom()
        local was = panel.is_open()
        local cx2 = start.x + math.floor(start.w / 2)
        local cy2 = start.y + math.floor(start.h / 2)
        pcall(mouse, 1, cx2, cy2, 0, false)
        pcall(mouse, 0, cx2 + 2, cy2 + 1, 0, false)
        pcall(mouse, 2, cx2 + 2, cy2 + 1, 0, false)
        pcall(prerender)
        local after = launcher.geom()
        if after.x == start.x and after.y == start.y
           and panel.is_open() ~= was then
            ok_('launcher: 2px of jitter is a click, not a drag',
                ('threshold held at %d,%d'):format(after.x, after.y))
        else
            fail_('launcher: jitter',
                  ('%d,%d -> %d,%d open %s -> %s'):format(start.x, start.y,
                   after.x, after.y, tostring(was), tostring(panel.is_open())))
        end
    end

    --[[ It must not claim a click the panel would. There is no z-order control on
         this platform, so where the icon overlaps the open window there is no way
         to know which one the player can see, and the honest rule is that the big
         certain thing wins. Driven by parking the icon inside the panel. ]]
    do
        pcall(cmd, 'show')
        pcall(prerender)
        local g3 = panel.geom()
        pcall(cmd, 'icon', 'pos', tostring(g3.x + 100), tostring(g3.y + 200))
        pcall(prerender)
        local lg3 = launcher.geom()
        local px3 = lg3.x + math.floor(lg3.w / 2)
        local py3 = lg3.y + math.floor(lg3.h / 2)
        if not panel.claims(px3, py3) then
            fail_('launcher: the overlap test set itself up', 'panel does not claim')
        else
            local before = panel.is_open()
            pcall(mouse, 1, px3, py3, 0, false)
            pcall(mouse, 2, px3, py3, 0, false)
            local moved = launcher.geom()
            if panel.is_open() == before and moved.x == lg3.x and moved.y == lg3.y then
                ok_('launcher: stands down where the panel would claim the click',
                    'no z-order on this platform, so the window wins')
            else
                fail_('launcher: claimed a click over the panel',
                      ('open %s -> %s'):format(tostring(before),
                       tostring(panel.is_open())))
            end
        end
        pcall(cmd, 'hide')
    end

    --[[ Clamped into the viewport. A saved position can be off-screen for reasons
         that are nobody's bug, a resolution change or a settings file copied from
         another machine, and an icon at x=9000 is gone. ]]
    do
        local ws = windower.get_windower_settings()
        launcher.set_pos(9000, 9000)
        local g4 = launcher.geom()
        if g4.x < ws.ui_x_res and g4.y < ws.ui_y_res then
            ok_('launcher: an off-screen position is clamped back',
                ('9000,9000 -> %d,%d on a %dx%d screen'):format(g4.x, g4.y,
                 ws.ui_x_res, ws.ui_y_res))
        else
            fail_('launcher: not clamped', ('%d,%d'):format(g4.x, g4.y))
        end
        launcher.set_pos(-500, -500)
        local g5 = launcher.geom()
        if g5.x > -g5.w and g5.y > -g5.h then
            ok_('launcher: and a negative one too',
                ('-500,-500 -> %d,%d'):format(g5.x, g5.y))
        else
            fail_('launcher: negative clamp', ('%d,%d'):format(g5.x, g5.y))
        end
        launcher.set_pos(20, 20)
    end

    --[[ `//qmui` still opens the log. It is the form a macro binds, and it is the
         thing most likely to be broken by putting a second door in front of
         it. ]]
    do
        pcall(cmd, 'hide')
        local was = panel.is_open()
        pcall(cmd)
        local opened = panel.is_open()
        pcall(cmd)
        local closed = panel.is_open()
        if not was and opened and not closed then
            ok_('launcher: //qmui still toggles the log', 'unchanged by the icon')
        else
            fail_('launcher: //qmui toggle',
                  ('%s -> %s -> %s'):format(tostring(was), tostring(opened),
                   tostring(closed)))
        end
    end

    -- Turning it off hides it, and the command reports the state it settled on.
    do
        pcall(cmd, 'icon', 'off')
        pcall(prerender)
        local ob = icon_obj()
        if not launcher.is_on() and ob and ob.vis == false then
            ok_('launcher: //qmui icon off hides it', 'the prim goes invisible')
        else
            fail_('launcher: icon off',
                  ('on=%s vis=%s'):format(tostring(launcher.is_on()),
                   tostring(ob and ob.vis)))
        end
        --[[ And a hidden icon takes no clicks: an invisible 32 px hole that still
             swallowed presses would be worse than the icon itself. ]]
        local hg = launcher.geom()
        local _, dh = pcall(mouse, 1, hg.x + 4, hg.y + 4, 0, false)
        if dh ~= true then
            ok_('launcher: a hidden icon claims nothing')
        else
            fail_('launcher: hidden icon still eats clicks')
        end
        pcall(mouse, 2, hg.x + 4, hg.y + 4, 0, false)
        pcall(cmd, 'icon', 'on')
        pcall(prerender)
        if launcher.is_on() then ok_('launcher: //qmui icon on brings it back') end
    end
end

--[[ The orphaned release, asserted through the event handler rather than through
     the function it calls.

     panel.on_mouse honours a pending release even with the panel closed, and that
     branch has to come before its `S.open` test. Guard the event handler on
     `panel.is_open()` and the branch is never reached: press on a row, close the
     log with a command or a macro before letting go, and the release reaches the
     client as an orphan and leaves mouse-look believing a button is still down.

     Asserted through the real handler, because that is where such a guard would
     live, not in the function it guards. ]]
print('')
print('=== a press whose panel closes under it ===')
do
    pcall(cmd, 'show')
    pcall(prerender)
    local g = panel.geom()
    local _, d = pcall(mouse, 1, g.x + 50, g.y + 100, 0, false)
    pcall(cmd, 'hide')                       -- closed under the finger
    local _, u = pcall(mouse, 2, g.x + 50, g.y + 100, 0, false)
    if d == true and u == true then
        ok_('mouse: a press survives its panel closing', 'the release is still eaten')
    else
        fail_('mouse: orphan release after the panel closed',
              ('down=%s up=%s'):format(tostring(d), tostring(u)))
    end
    --[[ And the other half, which must NOT change: a release with no press of ours
         is still passed through. Swallowing those would eat the game's own clicks
         everywhere the panel is not. ]]
    local _, u2 = pcall(mouse, 2, 900, 600, 0, false)
    if u2 == false then
        ok_('mouse: and an unmatched release is still passed through')
    else
        fail_('mouse: swallowed a release it never pressed', tostring(u2))
    end
end

-- ---------------------------------------------------------------------------
-- Authoring notes
-- ---------------------------------------------------------------------------

--[[ The notes are an optional read of build/authored/, which is NOT shipped
     with questmarks. So this section asserts two different things depending on
     whether the directory happens to exist here, and both are pass conditions:
     present -> the scan works and lands notes on the right steps; absent -> the
     feature is silently off and nothing else changes. ]]
print('\n=== authoring notes ===')
if not model.notes_available() then
    ok_('build/authored is absent; notes feature is off', 'not an error')
else
    local t = model.notes_for({cat = 'quest', area = 'bastok', id = 65})
    local st = model.notes_stats()
    if type(t) == 'table' and next(t) then
        ok_('notes read for a known quest',
            ('%d files, %d quests, %d notes, %.0f ms'):format(
                st.files, st.quests, st.notes, st.ms))
    else
        fail_('notes read for a known quest', 'nothing came back')
    end

    local d = model.description_for({cat = 'quest', area = 'windurst', id = 0})
    local ds = model.desc_stats()
    if d and d:find('chatting with the local', 1, true) then
        ok_('the quest own description is read',
            ('%d quests, %.0f ms'):format(ds.quests or 0, ds.ms or 0))
    else
        fail_('the quest own description is read', tostring(d))
    end

    --[[ Alignment. The notes are indexed by position into the shipped ladder, so
         a pipeline change that reordered or dropped steps would silently put
         guidance on the wrong step. Re-checked here over every quest that has
         both, rather than trusted from a one-off measurement. ]]
    local quests = require('core/quests')
    local checked, bad = 0, 0
    quests.each_entry(function(key, e)
        local nt = model.notes_for(e)
        if nt and e.steps then
            checked = checked + 1
            for n in pairs(nt) do
                if n < 1 or n > #e.steps then bad = bad + 1 end
            end
        end
    end)
    if bad == 0 then
        ok_('every note indexes a real step of its quest',
            ('%d quests checked'):format(checked))
    else
        fail_('note step alignment', ('%d notes out of range'):format(bad))
    end
end

-- ---------------------------------------------------------------------------
-- The detail pane must be able to reach its last line
-- ---------------------------------------------------------------------------

--[[ The visible-row count has to be the smaller of the pane height and the
     widget pool. Take it from the pane height alone and the last few lines of a
     long ladder are neither drawn nor scrollable: `dscroll_by` clamps against the
     larger number, concludes nothing is below the fold, and refuses to move.

     Checked on the longest ladder in the log rather than a constructed one. ]]
print('')
print('=== detail pane scrolling ===')
do
    if panel.S.dirty then panel.rebuild() end
    local best, bestn = nil, -1
    for i, l in ipairs(panel.S.lines) do
        if l.kind == 'row' then
            local lad = model.ladder(l.row.entry)
            local n = lad and #lad.rows or 0
            if n > bestn then best, bestn = i, n end
        end
    end
    if not best then
        fail_('detail scroll: found a quest to test', 'no rows')
    else
        panel.S.sel, panel.S.sel_key = best, panel.S.lines[best].row.key
        panel.S.dkey, panel.S.dquest = nil, nil
        pcall(cmd, 'show')
        pcall(prerender)

        local total = #(panel.S.dlines or {})
        local vis = panel.S.dvisible or 0
        ok_('detail: longest ladder selected',
            ('%s, %d steps, %d lines, %d visible')
            :format(panel.S.lines[best].row.name or '?', bestn, total, vis))

        if total > vis then
            panel.S.dscroll = 0
            panel.dscroll_by(1000)
            local at = panel.S.dscroll
            if at == total - vis then
                ok_('detail: scrolls to the LAST line',
                    ('offset %d of %d'):format(at, total - vis))
            else
                fail_('detail: scrolls to the last line',
                      ('stopped at %d, expected %d'):format(at, total - vis))
            end
            panel.dscroll_by(-1000)
            if panel.S.dscroll == 0 then
                ok_('detail: scrolls back to the top')
            else
                fail_('detail: scroll back to top', panel.S.dscroll)
            end
        else
            ok_('detail: whole ladder fits, nothing to scroll',
                ('%d lines <= %d visible'):format(total, vis))
        end

        --[[ Every line the model produced must be reachable: with the scroll at
             its maximum, the last line has to land inside the drawn window. This
             is the property the bug violated. ]]
        panel.dscroll_by(1000)
        if panel.S.dscroll + vis >= total then
            ok_('detail: every line is reachable', ('%d lines'):format(total))
        else
            fail_('detail: unreachable lines',
                  ('%d of %d'):format(total - (panel.S.dscroll + vis), total))
        end
        panel.S.dscroll = 0
    end
end

-- ---------------------------------------------------------------------------
-- The ladder mark rule
-- ---------------------------------------------------------------------------

--[[ A mark rule, restated as a pure function so it can be tested against
     constructed ladders.

     It is NOT the rule the detail pane applies, and nothing here holds the two
     together. ui/panel.lua's draw_detail branches three ways on a `state` it
     computes as `i < idx` -> done, `i <= fog_end` -> candidate, else todo, and
     never consults `optional` at all. This returns five states and tests
     `optional` second. The cases below therefore check this function, not the
     panel; treat a change here as needing a deliberate look at draw_detail
     rather than as covered by a test.

     The ordering is the whole point. `optional` must not be tested before
     `n == idx`. questmarks' `idx = best + 1` never consults the flag even though
     `best` does, so the current step can be an optional one. Measured over the
     shipped index below; testing optional first leaves every such ladder with no
     current marker. ]]
print('\n=== ladder mark rule ===')
local function mark_for(row, idx, fog_end)
    if row.n == idx then return 'current' end
    if row.optional and row.verdict ~= true then return 'optional' end
    if row.n < idx or row.verdict == true then return 'done' end
    if row.n <= fog_end then return 'fog' end
    return 'pending'
end

local MARK_CASES = {
    {'a step before the current one is done',
     {n = 1, optional = false}, 3, 3, 'done'},
    {'even with no evidence of its own',
     {n = 2, optional = false, verdict = nil}, 3, 3, 'done'},
    {'an OPTIONAL step before the current one is NOT claimed done',
     {n = 2, optional = true, verdict = nil}, 3, 3, 'optional'},
    {'unless its own evidence is actually held',
     {n = 2, optional = true, verdict = true}, 3, 3, 'done'},
    {'the current step is current',
     {n = 3, optional = false}, 3, 3, 'current'},
    {'THE CURRENT STEP IS CURRENT EVEN WHEN OPTIONAL',
     {n = 3, optional = true, verdict = nil}, 3, 3, 'current'},
    {'a step inside the fog is active',
     {n = 4, optional = false}, 3, 6, 'fog'},
    {'an optional step inside the fog stays optional',
     {n = 5, optional = true, verdict = nil}, 3, 6, 'optional'},
    {'a step past the fog is pending',
     {n = 7, optional = false}, 3, 6, 'pending'},
}
for _, c in ipairs(MARK_CASES) do
    local got = mark_for(c[2], c[3], c[4])
    if got == c[5] then ok_('mark: ' .. c[1], got)
    else fail_('mark: ' .. c[1], ('expected %s, got %s'):format(c[5], got)) end
end

--[[ And the claim that motivates the ordering, re-measured against the shipped
     index rather than trusted from a comment. If a future questmarks excluded
     optional steps from being positions, this count would drop to zero and the
     ordering would stop mattering. That would not make it wrong, so this reports
     rather than asserts. ]]
do
    local quests = require('core/quests')
    local land, opt1 = 0, 0
    quests.each_entry(function(_, e)
        local st = e.steps
        if not st or #st == 0 then return end
        if st[1].optional then opt1 = opt1 + 1 end
        if #st > 1 then
            local idx = math.min(2, #st)      -- accepted-implies-step-1, no evidence
            if st[idx] and st[idx].optional then land = land + 1 end
        end
    end)
    ok_('ladders whose current step can be optional',
        ('%d land there, %d have an optional step 1'):format(land, opt1))
end

-- ---------------------------------------------------------------------------
-- Settings must survive the XML round trip
-- ---------------------------------------------------------------------------

--[[ REGRESSION. Windower's config serialises table keys as XML element names,
     so a key with a slash in it writes a file that cannot be read back and the
     addon does not load. Asserted against the settings table the addon actually
     built, after it has been given something to remember. ]]
print('')
print('=== settings survive the XML round trip ===')
local function settings_seen()
    local cfg = package.loaded['config']
    return cfg._seen and cfg._seen() or nil
end
do
    --[[ Drive the real save path. Marking a repeatable completed and firing
         `login` runs note_completions and then save_seen, which is what writes
         into the settings table, and writing into that table is the thing that can
         break. Set the value by hand instead and the test tests itself. ]]
    feed(0x00A0, {0})                     -- Hat in Hand completed (repeatable)

    --[[ The harvest runs on the coalescing tick, which is throttled to twice a
         second off os.clock. Spin until that window is open so the test is
         deterministic rather than dependent on how much CPU the suite happened
         to burn before reaching here. ]]
    local t0 = os.clock()
    while os.clock() - t0 < 0.6 do end
    pcall(cmd, 'show')
    pcall(prerender)

    local cfg = package.loaded['config']
    local bad = cfg._check()
    local wrote = cfg._wrote and cfg._wrote() or nil
    if not wrote then
        fail_('settings: the save path ran', 'nothing was written -- test is vacuous')
    elseif #bad == 0 then
        ok_('every settings key is a legal XML element name',
            ('checked a settings table that was actually written'))
    else
        for i = 1, math.min(4, #bad) do
            fail_('settings key not XML-safe', bad[i])
        end
    end

    --[[ The round trip, on the key the harvest actually produced. It is a key
         with two slashes in it, which is the whole reason this is a string and not
         a table. ]]
    local str = model.seen_done_string()
    local stored = settings_seen()
    if str ~= '' and str:find('/', 1, true) and stored == str then
        ok_('the set is stored as one string, slashes and all', stored)
    else
        fail_('stored value', ('set=%q stored=%q'):format(str, tostring(stored)))
    end

    --[[ Both directions, including the legacy table form an older install may
         carry: it has to migrate rather than start over. ]]
    model.set_seen_done({})
    model.set_seen_done(str)
    local n = 0
    for _ in pairs(model.seen_done_table()) do n = n + 1 end
    if n > 0 then ok_('and parses back to the same set', n .. ' key(s)')
    else fail_('round trip lost the set', str) end

    model.set_seen_done({['quest/windurst/0'] = true})
    if model.seen_done_string() == 'quest/windurst/0' then
        ok_('a legacy table-form setting still migrates')
    else
        fail_('legacy migration', model.seen_done_string())
    end
    model.set_seen_done({})
end

-- ---------------------------------------------------------------------------
-- Pooled-widget state must not leak between row KINDS
-- ---------------------------------------------------------------------------

--[[ Pool slots change kind, and the widgets of the previous kind have to go.

     The list draws from a fixed pool of row widgets rebound as you scroll, so a
     slot holds a quest row one frame and a region header the next. Region headers
     do not draw a progress bar, so a header scrolled into a slot that had held a
     row leaves the row's bar sitting under the region name.

     An assertion about whether the draw threw cannot see that, because it draws
     perfectly happily. The property that matters is "no widget belonging to a row
     is visible while the slot shows a header", checked directly against the
     recorded draw calls at several scroll offsets, because the fault only appears
     at the offsets where a slot changes kind. ]]
print('')
print('=== pooled widgets: no leak between row kinds ===')
do
    pcall(cmd, 'show')
    pcall(cmd, 'unfoldall')
    local bad, checked = 0, 0
    for _, off in ipairs({0, 1, 2, 3, 5, 8, 13}) do
        panel.S.scroll = off
        pcall(prerender)
        for i = 1, #panel.S.lines do
            local l = panel.S.lines[panel.S.scroll + i]
            local w = panel.W and panel.W.lines and panel.W.lines[i]
            if l and w then
                checked = checked + 1
                if l.kind == 'group' then
                    -- A header must have no progress bar and no state bar.
                    for _, key in ipairs({'prog_bg', 'prog_fill', 'prog_maybe',
                                          'chip', 'chip_tx', 'sub'}) do
                        local o = objs[w[key] and w[key].name]
                        if o and o.vis then
                            bad = bad + 1
                            if bad <= 3 then
                                print(('        leak: header row %d still shows %s')
                                      :format(i, key))
                            end
                        end
                    end
                else
                    --[[ And the other direction: a quest row must not show a header's
                         widgets either. The badge is an image prim, and an image prim
                         left visible over a quest name is the same class of fault as the
                         progress bar left under a region title, only more obvious. ]]
                    for _, key in ipairs({'ico', 'glabel'}) do
                        local o = objs[w[key] and w[key].name]
                        if o and o.vis then
                            bad = bad + 1
                            if bad <= 3 then
                                print(('        leak: quest row %d still shows %s')
                                      :format(i, key))
                            end
                        end
                    end
                end
            end
        end
    end
    if bad == 0 then
        ok_('no widget leaks across row kinds',
            ('%d slot-states checked over 7 scroll offsets'):format(checked))
    else
        fail_('widget leaks across row kinds', bad .. ' leaked widgets')
    end
    panel.S.scroll = 0
end

--[[ The list is a two-level tree and has to look like one.

     Asserted as the property rather than as the numbers: every quest row's mark
     begins at or after the first character of its region's label, not of the fold
     glyph, which is the parent's own bullet, and its name begins after its mark.
     Numbers would pass on a layout where the two happened to be equal; the property
     is what "indented" means.

     Read off the recorded draw positions of the objects the panel actually placed,
     and paired header to row in screen order, so a row is checked against the region
     it is under rather than against any region at all. ]]
print('')
print('=== the list reads as a tree ===')
do
    pcall(cmd, 'show')
    pcall(cmd, 'unfoldall')
    if panel.S.dirty then panel.rebuild() end
    panel.S.scroll = 0
    pcall(prerender)
    local seen, groups, bad = 0, 0, {}
    local label_x = nil
    for i, w in ipairs(panel.W.lines) do
        local l = panel.S.lines[panel.S.scroll + i]
        if l and l.kind == 'group' then
            --[[ The label has an object of its own. The fold glyph, the badge and the
                 label are three columns, so this is read rather than measured off a
                 combined string. ]]
            local o = objs[w.glabel.name]
            if o and o.vis then
                groups = groups + 1
                label_x = o.x
            end
        elseif l and l.kind == 'row' and label_x then
            local m, n = objs[w.chip_tx.name], objs[w.main.name]
            if m and m.vis and n and n.vis then
                seen = seen + 1
                if m.x < label_x and #bad < 4 then
                    bad[#bad + 1] = ('%s: mark at %d, its region label starts at %d')
                        :format(l.row.key, m.x, math.floor(label_x))
                elseif n.x <= m.x and #bad < 4 then
                    bad[#bad + 1] = ('%s: name at %d is not right of the mark at %d')
                        :format(l.row.key, n.x, m.x)
                end
            end
        end
    end
    if groups == 0 or seen < 5 then
        fail_('tree: headers and rows were drawn to compare',
              ('%d headers, %d rows -- this checked almost nothing')
              :format(groups, seen))
    elseif #bad > 0 then
        fail_(('tree: %d row(s) are not indented under their region'):format(#bad),
              bad[1])
    else
        ok_('tree: every quest row is indented under its region header',
            ('%d rows under %d headers'):format(seen, groups))
    end

    --[[ And the columns of a group line do not overlap, at any scale.

         Pick the badge column to clear the fold glyph and it is easy to clear the
         wrong one: `-` is 6.0 px at 11 pt and `+` is 10.2, so the badge sits on top
         of every collapsed region and none of the others. A hand-picked gap does not
         scale either, and the gap it has to absorb does: the two glyphs differ by
         4.3 px at scale 1.0 and by 10.9 px at the 2.5 ceiling.

         Swept over the scale range the command allows, because "it looks right at
         1.0" is how that ships. Measured through `theme.width`, which is the shipped
         advance table the layout itself uses: if that table is wrong the panel is
         wrong in the same direction, and this at least holds them together. ]]
    do
        local was_scale = theme.scale
        local bad3, n = {}, 0
        for _, sc in ipairs({0.6, 1.0, 1.25, 1.5, 2.0, 2.5}) do
            theme.set_scale(sc)
            local fold = math.max(theme.width(theme.sym.collapsed, theme.fs_region),
                                  theme.width(theme.sym.expanded, theme.fs_region))
            local cols = {
                {'fold glyph ends', theme.fold_x + fold, 'badge starts', theme.group_ico_x},
                {'badge ends', theme.group_ico_x + theme.group_ico,
                 'label starts', theme.group_label_x},
                {'label starts', theme.group_label_x, 'mark starts', theme.mark_x},
                {'mark starts', theme.mark_x, 'name starts', theme.name_x},
                {'name starts', theme.name_x, 'the status column', theme.status_r},
            }
            for _, c in ipairs(cols) do
                n = n + 1
                if c[2] > c[4] and #bad3 < 4 then
                    bad3[#bad3 + 1] = ('scale %.2f: %s at %.1f, %s at %d')
                        :format(sc, c[1], c[2], c[3], c[4])
                end
            end
        end
        theme.set_scale(was_scale)
        panel.S.dirty = true
        pcall(prerender)
        if n < 20 then
            fail_('columns: scales were checked', n)
        elseif #bad3 > 0 then
            fail_(('columns: %d overlap(s) across the scale range'):format(#bad3), bad3[1])
        else
            ok_('columns: a group line\'s columns clear each other at every scale',
                ('%d checks over 0.6 to 2.5'):format(n))
        end
    end

    --[[ And the region wears its badge.

         The badge is what makes a category line unmistakable rather than merely
         outdented, so what is asserted is the drawn object: visible, positioned in its
         own column, and carrying the texture THIS region maps to rather than any texture
         at all. Keyed by `cat/area` and checked against `theme.group_icons`, because two
         regions are called `Campaign` and a table keyed by the printed label would pair
         one of them with the wrong artwork and still look right. ]]
    do
        local drawn, bad2 = 0, {}
        for i, w in ipairs(panel.W.lines) do
            local l = panel.S.lines[panel.S.scroll + i]
            if l and l.kind == 'group' then
                local o = objs[w.ico.name]
                local want = theme.group_icons[l.group.key]
                if want then
                    if not (o and o.vis) then
                        bad2[#bad2 + 1] = l.group.key .. ': badge not drawn'
                    elseif not (o.tex and o.tex:find(want, 1, true)) then
                        bad2[#bad2 + 1] = ('%s: drew %s, wants %s')
                            :format(l.group.key, tostring(o.tex), want)
                    elseif o.x ~= math.floor(panel.W.bg.p.x + theme.group_ico_x) then
                        bad2[#bad2 + 1] = ('%s: badge at x %s, column is %d')
                            :format(l.group.key, tostring(o.x),
                                    math.floor(panel.W.bg.p.x + theme.group_ico_x))
                    else
                        drawn = drawn + 1
                    end
                elseif o and o.vis then
                    bad2[#bad2 + 1] = l.group.key .. ': has no badge but drew one'
                end
            end
        end
        --[[ The specific complaint before the count, so a wrong badge reports what was
             wrong rather than "nothing was checked". ]]
        if #bad2 > 0 then
            fail_(('badge: %d region(s) wrong'):format(#bad2), bad2[1])
        elseif drawn < 2 then
            fail_('badge: regions were drawn to check', drawn .. ' -- checked nothing')
        else
            ok_('badge: every region draws the artwork its own key maps to',
                ('%d regions on screen'):format(drawn))
        end
    end

    --[[ Every badge the table names is on disk, and this is not paperwork.

         A prim whose texture will not load draws nothing at all and reports nothing.
         A typo in the table, or a file left out of a copy, is therefore an invisible
         column rather than an error. `theme.group_icon` probes and returns nil, which
         the panel handles; what it cannot do is tell you the table is wrong. ]]
    do
        local missing, n = {}, 0
        for key, name in pairs(theme.group_icons) do
            n = n + 1
            if not theme.group_icon(key) then
                missing[#missing + 1] = key .. ' -> ' .. name
            end
        end
        if n < 10 then
            fail_('badge: the table names some regions', n)
        elseif #missing == 0 then
            ok_('badge: every file the badge table names is on disk',
                ('%d regions, from assets/category/'):format(n))
        else
            fail_(('badge: %d named file(s) missing'):format(#missing),
                  table.concat(missing, ' | ', 1, math.min(3, #missing)))
        end
    end

    --[[ And a missing one degrades to no badge, not to a hole in the layout.

         Driven by pointing a region at a file that is not there, which is also what
         proves the probe is keyed on the NAME: a cache that remembered the answer per key
         would hand back the old path forever and this would pass while the panel drew a
         stale texture. ]]
    do
        local key = 'quest/windurst'
        local was = theme.group_icons[key]
        theme.group_icons[key] = 'no_such_badge.png'
        local gone = theme.group_icon(key)
        pcall(prerender)
        local hid, label_x = true, nil
        for i, w in ipairs(panel.W.lines) do
            local l = panel.S.lines[panel.S.scroll + i]
            if l and l.kind == 'group' and l.group.key == key then
                local o, t = objs[w.ico.name], objs[w.glabel.name]
                if o and o.vis then hid = false end
                label_x = t and t.x
            end
        end
        theme.group_icons[key] = was
        local back = theme.group_icon(key)
        pcall(prerender)
        if gone == nil and hid and back and label_x
           and label_x == math.floor(panel.W.bg.p.x + theme.group_label_x) then
            ok_('badge: a missing file hides the badge and holds the label column',
                'and the probe comes back when the name does')
        else
            fail_('badge: missing file', ('probe=%s hidden=%s label x=%s back=%s')
                  :format(tostring(gone), tostring(hid), tostring(label_x),
                          tostring(back)))
        end
    end
end


print('')
print('=== detail cache survives deselect and reselect ===')
do
    --[[ REGRESSION. Deselecting cleared S.ladder but left S.dquest naming the
         quest, so reselecting the SAME quest took the "nothing to reload" branch
         with a nil ladder and rendered "No step ladder recorded for this quest."
         for a quest that had just shown one. ]]
    local idx = nil
    for i, l in ipairs(panel.S.lines) do
        if l.kind == 'row' then
            local lad = model.ladder(l.row.entry)
            if lad and lad.rows and #lad.rows > 0 then idx = i break end
        end
    end
    if not idx then
        fail_('detail cache: found a quest with a ladder', 'none')
    else
        panel.select_line(idx)          -- select
        pcall(prerender)
        local n1 = #(panel.S.dlines or {})
        panel.select_line(idx)          -- deselect (same row toggles off)
        pcall(prerender)
        panel.select_line(idx)          -- select again
        pcall(prerender)
        local n2 = #(panel.S.dlines or {})
        if n1 > 0 and n2 == n1 then
            ok_('detail: reselecting the same quest rebuilds its ladder',
                ('%d lines both times'):format(n1))
        else
            fail_('detail: reselect rebuilds the ladder',
                  ('%d lines then %d'):format(n1, n2))
        end
        local hasnl = false
        for _, d in ipairs(panel.S.dlines or {}) do
            if d.b and d.b:find('No step ladder') then hasnl = true end
        end
        if not hasnl then ok_('detail: no false "no step ladder" after reselect')
        else fail_('detail: false "no step ladder" after reselect') end
    end
end

-- ---------------------------------------------------------------------------
-- The two panes must not disagree about the same quest
-- ---------------------------------------------------------------------------

--[[ A rebuild runs on every 0x056 settle and rebuilds the list rows from fresh
     data, and the detail pane has to follow. Clear `S.dkey` only when the selection
     is lost and the pane keeps the ladder it was handed at selection time, so the
     row's progress bar advances while the ladder still shows the old step and
     nothing short of reselecting the quest unfreezes it.

     Tested by identity: steps.explain builds a fresh table per call, so if the
     ladder was re-derived the reference changes. That is the mechanism and it is the
     honest thing to assert here, because nothing in this offline harness makes a
     quest actually advance and a value comparison would pass either way. ]]
--[[ panel.select_line toggles, so calling it on an already-selected row deselects.
     Tests want "make this the selection" regardless of prior state. ]]
local function force_select(i)
    local l = panel.S.lines[i]
    --[[ Refuses a non-row instead of indexing nil. Trust the caller and a caller
         that captured an index before a rebuild hands over one that has become a
         region header: an intermittent crash that takes the whole suite down with no
         failure reported, which is worse than a red run. See select_key below. ]]
    if not l or l.kind ~= 'row' then
        fail_('force_select was given line ' .. tostring(i) .. ', which is not a row',
              l and l.kind or 'nil')
        return false
    end
    panel.S.sel, panel.S.sel_key = i, l.row.key
    panel.S.dkey, panel.S.dquest = nil, nil
    panel.S.ladder = nil
    return true
end

--[[ Select by quest key, not by line index, which is what stops the crash above.

     A prerender can rebuild the display list, and after a rebuild an index means a
     different line: a sweep that captures `idx` and then draws inside the loop
     selects whatever has moved into that slot. Intermittent, because whether a
     rebuild lands mid-loop depends on what ran before it.

     It is the same rule the panel keeps for its own selection, in rebuild(). The key
     survives a rebuild; the index does not.

     -> the row's entry, or nil if the quest is no longer in the list. ]]
local function select_key(key)
    for i, l in ipairs(panel.S.lines) do
        if l.kind == 'row' and l.row.key == key then
            if not force_select(i) then return nil end
            panel.S.dkey = nil
            local okp = pcall(prerender)
            if not okp then return nil end
            return l.row.entry
        end
    end
    return nil
end

--[[ Every row key in the list, taken BEFORE a sweep starts drawing. ]]
local function all_row_keys()
    local keys = {}
    for _, l in ipairs(panel.S.lines) do
        if l.kind == 'row' then keys[#keys + 1] = l.row.key end
    end
    return keys
end

print('')
print('=== the detail pane refreshes on rebuild ===')
do
    pcall(cmd, 'show')
    if panel.S.dirty then panel.rebuild() end
    local idx = nil
    for i, l in ipairs(panel.S.lines) do
        if l.kind == 'row' then
            local lad = model.ladder(l.row.entry)
            if lad and lad.rows and #lad.rows > 1 then idx = i break end
        end
    end
    if not idx then
        fail_('detail refresh: found a quest', 'none')
    else
        force_select(idx)
        pcall(prerender)
        local before = panel.S.ladder
        local key_before = panel.S.sel_key
        panel.invalidate()
        panel.rebuild()
        pcall(prerender)
        if panel.S.sel_key ~= key_before then
            fail_('detail refresh: selection survived the rebuild',
                  tostring(panel.S.sel_key))
        elseif panel.S.ladder ~= nil and panel.S.ladder ~= before then
            ok_('detail: a rebuild re-derives the selected ladder',
                'selection and scroll preserved')
        else
            fail_('detail: rebuild re-derives the ladder',
                  'ladder table is unchanged -- the pane is frozen')
        end
    end
end

--[[ REGRESSION. `d.y` is recorded only for lines actually drawn, and step_at
     scans the whole list for the first line whose y contains the cursor. Lines
     scrolled out of the window kept their old y, so after scrolling down an
     off-screen earlier line won the hit test and clicking toggled the wrong
     step. Asserted as the property: whatever step_at returns for a y must be the
     step actually DRAWN at that y. ]]
print('')
print('=== the step hit test matches what is on screen ===')
do
    --[[ Pick the quest with the most notes, not the most steps. Only a step with
         a note is expandable, and only an expandable step is a hit target, so a
         22-step quest carrying one note tests almost nothing and reports a vacuous
         pass. ]]
    local best, bestn = nil, -1
    for i, l in ipairs(panel.S.lines) do
        if l.kind == 'row' then
            local nt = model.notes_for(l.row.entry)
            local n = 0
            if nt then for _ in pairs(nt) do n = n + 1 end end
            if n > bestn then best, bestn = i, n end
        end
    end
    force_select(best)
    pcall(prerender)

    local wrong, checked = 0, 0
    for _, off in ipairs({0, 3, 7, 12}) do
        panel.S.dscroll = off
        pcall(prerender)
        for _, d in ipairs(panel.S.dlines or {}) do
            if d.step and d.expandable and d.y then
                checked = checked + 1
                --[[ Probe the visual centre of the glyphs, not the top of the
                     line box. They are not the same point: Segoe UI's ink starts
                     0.3475 em below the line-box top, which at 11 pt is 5 px. Probe
                     d.y + 2 and you are above the text, testing a band the panel
                     does not use. ]]
                local sz = d.size or theme.fs_step
                local mid = d.y + theme.ink_y(sz) + theme.ink_h(sz) / 2
                local got = panel.step_at(panel.geom().dx + 60, mid)
                if got ~= d.step then
                    wrong = wrong + 1
                    if wrong <= 3 then
                        print(('        y=%d is step %d on screen but step_at said %s')
                              :format(d.y, d.step, tostring(got)))
                    end
                end
            end
        end
    end
    --[[ The invariant, checked directly rather than hoping for a collision.

         "Has a recorded y" must mean "is on screen this frame". A test that waits
         for a stale off-screen line to land on the same y as an expandable
         on-screen one passes with the fault present, because on this data they do
         not collide. Asserting the invariant is deterministic: after drawing at
         any offset, exactly the lines in the window may carry a y. ]]
    local stray = 0
    for _, off in ipairs({0, 3, 7, 12, 2, 0}) do
        panel.S.dscroll = off
        pcall(prerender)
        local lo, hi = panel.S.dscroll + 1, panel.S.dscroll + (panel.S.dvisible or 0)
        for j, d in ipairs(panel.S.dlines or {}) do
            if d.y and (j < lo or j > hi) then stray = stray + 1 end
        end
    end
    if stray == 0 then
        ok_('only on-screen lines carry a position', 'checked over 6 offsets')
    else
        fail_('lines off-screen still carry a position',
              stray .. ' stale -- the hit test will return the wrong step')
    end
    panel.S.dscroll = 0

    if checked == 0 then
        fail_('step hit test', 'checked nothing -- no expandable step was drawn')
    elseif wrong == 0 then
        ok_('step hit test agrees with the screen',
            ('%d drawn steps over 4 scroll offsets'):format(checked))
    else
        fail_('step hit test', wrong .. ' mismatches')
    end
    panel.S.dscroll = 0
end

-- ---------------------------------------------------------------------------
-- One click, one toggle
-- ---------------------------------------------------------------------------

--[[ One click on a step flips what is drawn, and the assertion has to be the
     property rather than one example.

     Re-derive the default open state in `panel.toggle_step` as `not (i >= idx)`
     while build_detail derives it as `state == 'candidate'`, meaning `i >= idx` and
     `i <= fog_end`, and the two agree everywhere except on a step past the fog.
     There the step is drawn closed while `i >= idx` is true, so the toggle writes
     `dopen[i] = false` over a step that is already closed and nothing happens; the
     second click finds a non-nil `false` and opens it.

     A narrower assertion cannot see that. Anything which calls `panel.toggle_step`
     directly, or clicks a step inside the candidate band, is testing where the two
     formulas agree. So this sweeps every expandable step of every quest in the list,
     in every progress state. ]]
print('')
print('=== one click, one toggle ===')
do
    --[[ The y of a step's ink centre, which is what `step_at` matches against. Taken
         from the drawn line rather than computed from the step number, because the
         line's own y is the only thing that knows about wrapping and scrolling. ]]
    local function step_y(n)
        for _, d in ipairs(panel.S.dlines or {}) do
            if d.step == n and d.y then
                local sz = d.size or theme.fs_step
                return d.y + theme.ink_y(sz) + theme.ink_h(sz) / 2
            end
        end
        return nil
    end

    local function drawn_open(n)
        for _, d in ipairs(panel.S.dlines or {}) do
            if d.step == n then return d.open and true or false end
        end
        return nil
    end

    --[[ Press and release over the step through the real handler, so target matching
         and release pairing are exercised too. A toggle called directly is what lets
         this class of fault through. ]]
    local function click_step(n)
        local y = step_y(n)
        if not y then return false end
        local x = panel.geom().dx + 60
        pcall(mouse, 1, x, y, 0, false)
        pcall(mouse, 2, x, y, 0, false)
        pcall(prerender)
        return true
    end

    --[[ The named case. "Tuning In" carries evidence on step 2, so the fog ends there
         and steps 3-5 are `todo`: not yet active, with notes, past the fog. ]]
    do
        local idx
        for i, l in ipairs(panel.S.lines) do
            if l.kind == 'row' and l.row.key == 'quest/windurst/90' then idx = i break end
        end
        if not idx then
            fail_('toggle: Tuning In is in the list')
        else
            force_select(idx)
            panel.S.dkey = nil
            panel.S.showall = false
            pcall(prerender)
            local lad = panel.S.ladder
            --[[ Past the fog, not merely closed. A step before the current one is
                 also drawn closed, and `not (i >= idx)` is true there, so the wrong
                 formula opens those on the first click and an assertion aimed at one
                 of them passes on the fault. The candidate band is marked on the
                 drawn lines, so the last banded step is the fog end and anything
                 after it is `todo`. ]]
            local last_band = 0
            for _, d in ipairs(panel.S.dlines or {}) do
                if d.step and d.band and d.step > last_band then last_band = d.step end
            end
            local target
            for _, d in ipairs(panel.S.dlines or {}) do
                if d.step and d.expandable and not d.open and not d.band
                   and d.step > last_band then
                    target = d.step
                    break
                end
            end
            if not target then
                fail_('toggle: Tuning In has a closed not-yet-active step with a note',
                      'none -- this test would check nothing')
            elseif not click_step(target) then
                fail_('toggle: the step was drawn to click', tostring(target))
            elseif drawn_open(target) then
                ok_('toggle: ONE click opens a not-yet-active step',
                    ('step %d of Tuning In -- idx %d, fog ends %d')
                    :format(target, lad and lad.idx or 0, last_band))
            else
                fail_('toggle: the first click did nothing',
                      ('step %d is still closed'):format(target))
            end
            if target then
                click_step(target)
                if drawn_open(target) == false then
                    ok_('toggle: and the next click closes it again')
                else
                    fail_('toggle: second click', tostring(drawn_open(target)))
                end
            end
        end
    end

    --[[ The property, over every expandable step of every quest in the list. `done`,
         `candidate` and `todo` reach the toggle by different default rules and only
         one of the three was ever exercised. ]]
    do
        local bad, checked, states = {}, 0, {}
        for _, key in ipairs(all_row_keys()) do
            if select_key(key) then
                panel.S.showall = false
                panel.S.dkey = nil
                pcall(prerender)
                --[[ Snapshot first: a click rebuilds the line list, so the set of
                     steps to visit is taken before any of them is touched. ]]
                local last_band = 0
                for _, d in ipairs(panel.S.dlines or {}) do
                    if d.step and d.band and d.step > last_band then last_band = d.step end
                end
                local steps = {}
                for _, d in ipairs(panel.S.dlines or {}) do
                    if d.step and d.expandable then
                        steps[#steps + 1] = {n = d.step,
                                             band = d.band and true or false,
                                             todo = d.step > last_band}
                    end
                end
                for _, st in ipairs(steps) do
                    local before = drawn_open(st.n)
                    if before ~= nil and step_y(st.n) then
                        checked = checked + 1
                        local key = st.band and 'candidate'
                                    or (st.todo and 'todo' or 'done')
                        states[key] = (states[key] or 0) + 1
                        click_step(st.n)
                        if drawn_open(st.n) == before then
                            bad[#bad + 1] = ('%s step %d stayed %s')
                                :format(key, st.n, tostring(before))
                        end
                        -- Put it back, so later steps are judged from a clean state.
                        click_step(st.n)
                    end
                end
            end
        end
        local tally = {}
        for k, v in pairs(states) do tally[#tally + 1] = k .. '=' .. v end
        table.sort(tally)
        if checked < 10 then
            fail_('toggle: expandable steps were clicked',
                  checked .. ' -- this test checked almost nothing')
        elseif (states.todo or 0) == 0 then
            --[[ `todo` is the band the bug lived in. Without one in the list the
                 property holds vacuously over the two states that always worked. ]]
            fail_('toggle: a not-yet-active step was among them',
                  '0 todo steps -- this test checked the wrong band')
        elseif #bad == 0 then
            ok_('toggle: one click always flips what is drawn',
                ('%d expandable steps clicked (%s)')
                :format(checked, table.concat(tally, ' ')))
        else
            fail_(('toggle: %d step(s) ignored their first click'):format(#bad),
                  bad[1])
        end
    end

    --[[ And `Show all notes` no longer swallows the click. It used to win outright
         over `S.dopen`, so with it on, clicking a step to collapse it did nothing --
         the same fault one layer up, found looking for company for the first. An
         explicit per-step choice now beats both defaults, and pressing the global
         still clears them. ]]
    do
        local idx
        for i, l in ipairs(panel.S.lines) do
            if l.kind == 'row' then
                local nt = model.notes_for(l.row.entry)
                if nt and next(nt) then idx = i break end
            end
        end
        if not idx then
            fail_('toggle: a quest with notes was found')
        else
            force_select(idx)
            panel.S.showall = false
            panel.S.dopen = {}
            panel.S.dkey = nil
            pcall(prerender)

            --[[ `Show all notes` is pressed, not assigned. Setting `S.showall` by
                 hand and asserting on it tests the test: the press is what clears the
                 per-step overrides, so removing that clearing leaves this whole block
                 green while "Show all notes" has stopped meaning all. Same shape as
                 reading back a settings value the writer never wrote.

                 Its hit rect is recorded by the draw, so the control is clicked where
                 it actually is. ]]
            local function press_showall()
                local h = panel.S.action_hit
                if not h then return false end
                local ax = h.x + math.floor(h.w / 2)
                local ay = h.y + math.floor(h.h / 2)
                pcall(mouse, 1, ax, ay, 0, false)
                pcall(mouse, 2, ax, ay, 0, false)
                pcall(prerender)
                return true
            end

            if not press_showall() then
                fail_('toggle: Show all notes has a hit rect to press')
            elseif not panel.S.showall then
                fail_('toggle: pressing Show all notes turned it on',
                      tostring(panel.S.showall))
            end

            --[[ A candidate step, so its default is OPEN. That is what makes the
                 last assertion below meaningful: after the global is pressed again
                 the step must come back open by DEFAULT, which only happens if the
                 press cleared what the click wrote. ]]
            local target
            for _, d in ipairs(panel.S.dlines or {}) do
                if d.step and d.expandable and d.band and d.open then
                    target = d.step
                    break
                end
            end
            if not target then
                fail_('toggle: showall opened a step to close', 'none')
            else
                click_step(target)
                if drawn_open(target) == false then
                    ok_('toggle: a per-step click beats Show all notes',
                        ('step %d closed with showall on'):format(target))
                else
                    fail_('toggle: showall swallowed the click',
                          ('step %d is still open'):format(target))
                end
                --[[ And PRESSING the global reasserts it over what was just clicked
                     -- otherwise "Show all notes" stops meaning all. Pressed twice:
                     off, then on, both through the real control, so the clearing
                     that makes it work is the thing being exercised. ]]
                press_showall()
                press_showall()
                if panel.S.showall and drawn_open(target) then
                    ok_('toggle: pressing the global again reopens what was closed',
                        ('step %d, cleared by the press and not by hand')
                        :format(target))
                else
                    fail_('toggle: showall no longer means all',
                          ('step %d open=%s showall=%s'):format(target,
                           tostring(drawn_open(target)), tostring(panel.S.showall)))
                end
            end
            panel.S.showall = false
            panel.S.dopen = {}
            panel.S.dkey = nil
            pcall(prerender)
        end
    end
end

-- ---------------------------------------------------------------------------
-- The pane background sheet
-- ---------------------------------------------------------------------------

--[[ Both panes are drawn as a papyrus texture multiplied down by a dark tint, rather
     than as a flat fill. `set_color` multiplies, which is how render/markers.lua tints
     a white glyph body to a state colour, so the sheet can be used exactly as authored
     and darkened at draw time.

     The sheet is light: measured over the area the text occupies its luminance is
     0.5690, and the faintest text role needs a background under 0.0277 to clear 4.5:1.
     Untinted it renders the zone and requirement lines at 1.8:1. So what is worth
     asserting here is not "the texture is set". It is that the arrangement cannot make
     the text unreadable, and that a missing file cannot make the window invisible. ]]
print('')
print('=== the pane background ===')
do
    --[[ WCAG relative luminance and contrast, so the panel's legibility argument is
         executable rather than prose. ]]
    local function lin(c)
        c = c / 255
        if c <= 0.04045 then return c / 12.92 end
        return ((c + 0.055) / 1.055) ^ 2.4
    end
    local function lum(t)
        return 0.2126 * lin(t[1]) + 0.7152 * lin(t[2]) + 0.0722 * lin(t[3])
    end
    local function ratio(a, b)
        local la, lb = lum(a), lum(b)
        if la < lb then la, lb = lb, la end
        return (la + 0.05) / (lb + 0.05)
    end

    --[[ The bound on a tinted pixel, which holds for any sheet anyone drops in.

         The multiply is per-channel and monotonic, so the brightest a tinted pixel can
         be is white through the tint, which is the tint itself. Check the tint against
         the faintest text and you have checked every pixel of every possible texture,
         without decoding a PNG in Lua.

         Swap in a bright sheet and the panel still cannot drop below this, because the
         tint bounds it. Raise a tint and this fails. ]]
--[[ The contrast floor, measured, for every preset and every role that is read.

         The bound above is only valid for light ink on a dark ground. The parchment
         preset inverts that: its tint is the identity, its ink is near-black, and the
         case that matters is the darkest pixel rather than the brightest. A bound that
         only holds one way round is not a bound, so the sheets are measured instead.

         `ui/pagestats.lua` is generated by tools/make_pages.py and carries the real
         colour of the real pages at luminance percentiles, as RGB triples. RGB because
         the panel multiplies per channel and the luminance of the product is not any
         function of the luminances. Tint a triple and you have an exact pixel of an
         exact sheet under an exact preset.

         Checked at p05 and at p95, so it holds across the page rather than at its mean,
         and in two columns with two floors:

           main    x 56..352, every string the panel draws        4.5:1
           glyph   x 14..56, single 11pt bold characters          3.0:1

         The lower glyph floor is WCAG's large-text threshold and it is not a
         convenience: those are `x`, `>`, `-` and the marker's `!` / `?`, whose meaning
         is also carried by position and by the step number beside them. The prose gets
         the full bar.

         Adding a preset that cannot be read fails here. ]]
    local stats = require('ui/pagestats')

    local PAGE = {list = 'page_left.png', detail = 'page_right.png'}
    local FLOOR = {main = 4.5, glyph = 3.0}
    --[[ Which columns each role is actually drawn in. `text`, `text_dim` and
         `text_faint` reach the glyph column as the step number. `step_done`, `step_now`
         and `amber` reach it as a glyph: the first two as the ladder's `x` and `>`, and
         `amber` as the marker's `!` when questmarks cannot be reached and the fallback
         is taken. Everything else is prose or an accent and stays in the main
         column. ]]
    local ROLE_COLS = {
        text = {'main', 'glyph'}, text_dim = {'main', 'glyph'},
        text_faint = {'main', 'glyph'}, amber = {'main', 'glyph'},
        step_done = {'main', 'glyph'}, step_now = {'main', 'glyph'},
        step_todo = {'main', 'glyph'},
        text_bright = {'main'}, gold = {'main'},
        accent = {'main'}, accent_dim = {'main'}, amber_cap = {'main'},
    }

    --[[ And the two that are read through an outline rather than off the page.

         Over parchment the ladder is the panel's bright green and amber, which measure
         1.07:1 and 1.23:1 against the page. What makes them readable is `stroke_hue`, a
         near-black halo at alpha 235 drawn around every one of those strings and around
         nothing else on that page.

         So a role either clears its floor against the page, as everything else must, or,
         for these two alone, it clears it against its own halo while the halo clears it
         against the page. Two links, both measured, and the weaker of the two is what
         gets reported. That is weaker than measuring ink on page and it is not nothing:
         a halo too faint to separate from the page fails the second link, and a hue too
         close to the halo fails the first.

         It is narrow on purpose. These are the only roles ui/panel.lua always draws with
         a stroke of their own, the title, its wrapped continuations, the glyph and the
         number, all four from `d.stroke`, which is why they are roles of their own and
         not the panel's `amber` and grey ramp. The list's `n ready` tally is the same
         amber with no halo at all, and `text_faint` carries the zone and requirement
         lines; both are held to the page like everything else.

         The marker is held the same way, further down, by the same two links. It is not
         in this table because its colour is questmarks' at runtime rather than a
         role. ]]
    local OUTLINED = {step_done = true, step_now = true, step_todo = true}

    --[[ `src` at `a`/255 over `dst`, which is what a stroke does to the page under it. ]]
    local function over(src, a, dst)
        local f = a / 255
        return {math.floor(src[1] * f + dst[1] * (1 - f) + 0.5),
                math.floor(src[2] * f + dst[2] * (1 - f) + 0.5),
                math.floor(src[3] * f + dst[3] * (1 - f) + 0.5)}
    end

    --[[ Refuse a stale measurement. The stats carry each sheet's own dimensions and
         byte count; if they no longer describe the file on disk then every number below
         is about a sheet that no longer exists, which is worse than having none. ]]
    do
        local bad = {}
        for _, page in pairs(PAGE) do
            local st = stats[page]
            if not st then
                bad[#bad + 1] = page .. ': no stats'
            else
                local f = real_open(A .. 'assets/' .. page, 'rb')
                if not f then
                    bad[#bad + 1] = page .. ': not on disk'
                else
                    local n = f:seek('end')
                    f:close()
                    if n ~= st.bytes then
                        bad[#bad + 1] = ('%s: %d bytes on disk, stats say %d')
                            :format(page, n, st.bytes)
                    end
                end
            end
        end
        if #bad == 0 then
            ok_('background: the measured page stats still describe the sheets on disk',
                'regenerate with tools/make_pages.py')
        else
            fail_('background: ui/pagestats.lua is stale', table.concat(bad, ' | '))
        end
    end

    --[[ Every preset, every pane, both ends of the page, every role that is read. ]]
    do
        local was = theme.bg_theme()
        local bad, checked, worst, wlabel = {}, 0, 99, nil
        local haloed = 0
        for _, name in ipairs(theme.bg_theme_names()) do
            theme.set_bg(name)
            local tint = {list = theme.col.panel_tint, detail = theme.col.detail_tint}
            for _, pane in ipairs({'list', 'detail'}) do
                local st = stats[PAGE[pane]]
                local t = tint[pane]
                --[[ Each pane against the table it actually reads. ui/panel.lua's two
                     detail functions take their colours from `theme.dcol`, which reads
                     through to `theme.col` for every preset that dresses the window as
                     one thing and diverges for `mixed`. Check `theme.col` for both panes
                     and three presets pass by luck while the fourth reports failures
                     against colours that pane never draws. ]]
                local COL = (pane == 'detail') and theme.dcol or theme.col
                for col, floor in pairs(FLOOR) do
                    for _, pct in ipairs({'p05', 'p95'}) do
                        local px = st[col][pct]
                        --[[ The pixel as the client composites it: sheet x tint. ]]
                        local bg = {math.floor(px[1] * t.r / 255),
                                    math.floor(px[2] * t.g / 255),
                                    math.floor(px[3] * t.b / 255)}
                        for role, cols in pairs(ROLE_COLS) do
                            local wants = false
                            for _, c in ipairs(cols) do
                                if c == col then wants = true end
                            end
                            if wants then
                                local ink = COL[role]
                                local eff = ratio({ink.r, ink.g, ink.b}, bg)
                                local how = 'page'
                                --[[ Only when the page itself cannot carry it, and only
                                     for a role drawn inside a halo. See OUTLINED. ]]
                                if eff < floor and OUTLINED[role] then
                                    local k = COL.stroke_hue
                                    local halo = over({k.r, k.g, k.b}, k.a, bg)
                                    local ri = ratio({ink.r, ink.g, ink.b}, halo)
                                    local rh = ratio(halo, bg)
                                    eff = (ri < rh) and ri or rh
                                    how = 'halo'
                                    haloed = haloed + 1
                                end
                                checked = checked + 1
                                if eff < worst then
                                    worst = eff
                                    wlabel = ('%s %s/%s/%s %s via %s')
                                        :format(name, pane, col, pct, role, how)
                                end
                                if eff < floor then
                                    bad[#bad + 1] = ('%s %s %s %s %s %.2f:1 < %.1f (%s)')
                                        :format(name, pane, col, pct, role, eff, floor,
                                                how)
                                end
                            end
                        end
                    end
                end
            end
        end
        theme.set_bg(was)
        if checked < 100 then
            fail_('background: contrast readings were taken',
                  checked .. ' -- this test checked almost nothing')
        elseif #bad == 0 then
            ok_('background: every readable role clears its floor on every preset',
                ('%d readings, worst %.2f:1 at %s'):format(checked, worst, wlabel))
        else
            fail_(('background: %d contrast failure(s)'):format(#bad),
                  table.concat(bad, ' | ', 1, math.min(3, #bad)))
        end

        --[[ And the halo path must actually be taken, or it is an exemption that
             exempts nothing and quietly stops being examined. It exists because two
             roles on one preset cannot be read off the page. If that stops being true,
             because the ladder went dark again or the preset went away, the right answer
             is to delete the path, and a red assertion is how that gets noticed. Same
             rule as "a test that checks nothing must fail". ]]
        if haloed > 0 then
            ok_('background: the outlined roles are checked against their outline',
                ('%d of %d readings taken through the halo'):format(haloed, checked))
        else
            fail_('background: the halo path is exercised',
                  '0 readings needed it -- the exemption is checking nothing, delete it')
        end
    end

    --[[ And the marker hues, which are not ours to choose, held by the same two links.

         A row's mark takes its colour from questmarks' render/markers.lua at runtime so
         the list cannot disagree with the world. Over parchment those hues are 1.11:1 to
         2.23:1 against the page. Capping their luminance is the obvious answer and it
         does not work: a quest yellow dark enough for cream is an olive, and saturation
         cannot help because the hue is already near-saturated.

         So the mark is drawn inside `stroke_hue` and measured the way the ladder is. It
         either clears the glyph floor against the page, or it clears it against its own
         ring while the ring clears it against the page. The alternative to this check is
         no check, because there is nothing left to constrain the colour: it is
         questmarks' and the panel does not touch it.

         Driven through `theme.category_colour`, the funnel every marker colour passes,
         with the real four-way input. ]]
    do
        local was = theme.bg_theme()
        local CASES = {{'quest', 'sandoria', false}, {'mission', 'windurst', false},
                       {'quest', 'abyssea', false}, {'quest', 'sandoria', true}}
        local bad, checked, worst, wl, haloed = {}, 0, 99, nil, 0
        for _, name in ipairs(theme.bg_theme_names()) do
            theme.set_bg(name)
            local st = stats[PAGE.list]
            local t = theme.col.panel_tint
            for _, pct in ipairs({'p05', 'p95'}) do
                local px = st.glyph[pct]
                local bg = {math.floor(px[1] * t.r / 255),
                            math.floor(px[2] * t.g / 255),
                            math.floor(px[3] * t.b / 255)}
                --[[ The ring the mark is drawn inside, from the LIST pane's own role --
                     ui/panel.lua passes `theme.col.stroke_hue` at that draw. ]]
                local k = theme.col.stroke_hue
                local halo = over({k.r, k.g, k.b}, k.a, bg)
                for _, cs in ipairs(CASES) do
                    local col = theme.category_colour(cs[1], cs[2], cs[3])
                    local r = ratio({col.r, col.g, col.b}, bg)
                    local how = 'page'
                    if r < FLOOR.glyph then
                        local ri = ratio({col.r, col.g, col.b}, halo)
                        local rh = ratio(halo, bg)
                        r = (ri < rh) and ri or rh
                        how = 'halo'
                        haloed = haloed + 1
                    end
                    checked = checked + 1
                    if r < worst then
                        worst, wl = r, ('%s %s/%s %s via %s'):format(name, cs[1],
                                        tostring(cs[2]), pct, how)
                    end
                    if r < FLOOR.glyph then
                        bad[#bad + 1] = ('%s %s/%s %s %.2f:1 (%s)')
                            :format(name, cs[1], tostring(cs[2]), pct, r, how)
                    end
                end
            end
        end
        theme.set_bg(was)
        if checked == 0 then
            fail_('background: marker colours were checked', '0')
        elseif #bad == 0 then
            ok_('background: the marker hues clear the glyph floor on every preset',
                ('%d readings, %d through the ring, worst %.2f:1 at %s')
                :format(checked, haloed, worst, wl))
        else
            fail_(('background: %d marker colour(s) unreadable'):format(#bad),
                  table.concat(bad, ' | ', 1, math.min(3, #bad)))
        end
        --[[ The same guard the ladder's exemption carries: if no marker ever needs its
             ring, the ring is not what is holding the mark up and this path is checking
             nothing. Today it is the whole of parchment's list. ]]
        if haloed > 0 then
            ok_('background: the marker ring is what carries the hue on a light page',
                ('%d of %d readings taken through it'):format(haloed, checked))
        else
            fail_('background: the marker ring is exercised',
                  '0 readings needed it -- nothing is relying on the ring, drop it')
        end

        --[[ And the ring is actually drawn, which the sweep above assumes and cannot
             see.

             The sweep takes the ring from the role. Stop passing it at that draw in
             ui/panel.lua and the readings are unchanged while every one of them is about
             a ring that is not there, which is the same trap the ladder's outline has its
             own assertion for. Read off the recorded stroke of the marks the list drew
             under parchment, where the pane's ordinary stroke is zero alpha and so the
             two are told apart. ]]
        do
            local was2 = theme.bg_theme()
            pcall(cmd, 'bg', 'parchment')
            panel.S.dkey = nil
            pcall(prerender)
            local pink = theme.bg_themes.parchment.ink
            local want = ('%d,%d,%d,%d'):format(pink.stroke_hue.a, pink.stroke_hue.r,
                                                pink.stroke_hue.g, pink.stroke_hue.b)
            local n, bad2 = 0, {}
            for i, w in ipairs(panel.W.lines) do
                local l = panel.S.lines[panel.S.scroll + i]
                local o = objs[w.chip_tx.name]
                if l and l.kind == 'row' and o and o.vis and o.sa then
                    n = n + 1
                    local got = ('%s,%s,%s,%s'):format(tostring(o.sa), tostring(o.sr),
                                                       tostring(o.sg), tostring(o.sb))
                    if got ~= want and #bad2 < 4 then
                        bad2[#bad2 + 1] = l.row.key .. ' drew stroke ' .. got
                    end
                end
            end
            pcall(cmd, 'bg', was2)
            panel.S.dkey = nil
            pcall(prerender)
            if n < 5 then
                fail_('background: marks were drawn to check their ring',
                      n .. ' -- this checked almost nothing')
            elseif #bad2 > 0 then
                fail_(('background: %d mark(s) drawn outside the ring'):format(#bad2),
                      bad2[1] .. ' wanting ' .. want)
            else
                ok_('background: every mark is drawn inside that ring',
                    ('parchment: %d marks at stroke %s'):format(n, want))
            end
        end
    end


    --[[ `mixed` dresses the two panes differently, and every other preset does not.

         `theme.dcol` reads through to `theme.col` for a preset that dresses the window
         as one thing, so there is exactly one value and the panes cannot drift. Only
         `mixed` writes own keys. Both halves are asserted, divergence where it is meant
         to be and identity everywhere else, because a `dcol` that kept stale own keys
         after switching away would leave parchment ink on a leather pane. ]]
    do
        local was = theme.bg_theme()
        local bad = {}
        for _, name in ipairs(theme.bg_theme_names()) do
            theme.set_bg(name)
            local own = 0
            for _ in pairs(theme.dcol) do own = own + 1 end
            local same = (theme.dcol.text == theme.col.text)
            if name == 'mixed' then
                if own == 0 or same then
                    bad[#bad + 1] = 'mixed does not diverge (' .. own .. ' own keys)'
                end
                if theme.dcol.text ~= theme.bg_themes.parchment.ink.text then
                    bad[#bad + 1] = 'mixed detail ink is not parchment'
                end
            elseif own ~= 0 or not same then
                bad[#bad + 1] = ('%s leaked %d own key(s) into dcol')
                    :format(name, own)
            end
        end
        theme.set_bg(was)
        if #bad == 0 then
            ok_('background: only mixed dresses the panes differently',
                'dcol falls through for the other three, and is cleared on every switch')
        else
            fail_('background: per-pane colour', table.concat(bad, ' | '))
        end
    end

    --[[ And the detail pane actually draws with it.

         The check above compares theme tables and says nothing about which table
         ui/panel.lua reads. Point the detail half back at `theme.col` and it stays green,
         because `mixed` still has the right values in the right tables and only the
         drawing is wrong. So this reads the recorded colour of a detail-pane text object
         under `mixed` and requires parchment's ink. ]]
    do
        local was = theme.bg_theme()
        local sel
        for _, l in ipairs(panel.S.lines) do
            if l.kind == 'row' then sel = l.row.key break end
        end
        select_key(sel)
        pcall(cmd, 'bg', 'mixed')
        panel.S.dkey = nil
        pcall(prerender)
        --[[ The values are copied out before the preset is restored. `objs[...]` is the
             live recorded object and the restoring draw overwrites it in place, so
             reading afterwards compares the restored colour against parchment's and
             fails on a panel that drew correctly. ]]
        local o = objs[panel.W.d_title.name]
        local gr, gg, gb = o and o.r, o and o.g, o and o.b
        local want = theme.bg_themes.parchment.ink.text

        --[[ Both detail functions, because they hold their own alias. The quest title
             above is `draw_detail`'s; a step title is `build_detail`'s, and pointing only
             that one back at `theme.col` leaves this green.

             Checked on the step's outline and not on its hue. Comparing the title against
             parchment's three ladder colours does not discriminate, because parchment
             does not darken the ladder: `step_done` and `step_now` are the same values on
             both sides of `mixed`, so a done step drawn from the wrong table is
             byte-identical. `stroke_hue` is not. Parchment's is a warm near-black
             rgb(16,10,4) and the window's is the cool rgb(4,10,24), and it is set by
             build_detail itself on the same line that sets the colour, so mutating that
             alias back to `theme.col` reddens this. ]]
        local pink = theme.bg_themes.parchment.ink
        local step_ok = false
        for _, d in ipairs(panel.S.dlines or {}) do
            if d.step and d.stroke then
                local w = pink.stroke_hue
                step_ok = (d.stroke.a == w.a and d.stroke.r == w.r
                           and d.stroke.g == w.g and d.stroke.b == w.b)
                break
            end
        end

        pcall(cmd, 'bg', was)
        panel.S.dkey = nil
        pcall(prerender)
        if gr == want.r and gg == want.g and gb == want.b and step_ok then
            ok_('background: under mixed BOTH detail functions draw parchment ink',
                ('quest title rgb(%d,%d,%d), and the step outline is parchment\'s')
                :format(gr, gg, gb))
        else
            fail_('background: mixed detail pane ink',
                  ('title drew rgb(%s,%s,%s) wanting rgb(%d,%d,%d); step stroke ok=%s')
                  :format(tostring(gr), tostring(gg), tostring(gb),
                          want.r, want.g, want.b, tostring(step_ok)))
        end
    end

    --[[ And the list half of `mixed` is navy's, string for string.

         `mixed` borrows leather's palette on the window and leather names no ink at all,
         so the list wears navy's. That is "already true" rather than "enforced", and it
         stays true only until someone gives leather an ink table or repoints `from`, so
         it is asserted rather than assumed.

         Checked on the recorded colour and outline of every string the list pane draws,
         under navy and again under mixed, compared per widget. Not on the theme tables:
         comparing those is what let a mutation through once already. ]]
    do
        local was = theme.bg_theme()
        --[[ Every text widget the list half owns. The detail pane's are deliberately not
             here, because under mixed they are parchment's and must differ. ]]
        local function snap()
            local out, n = {}, 0
            local function look(t, what)
                local o = t and objs[t.name]
                if o and o.vis and o.a then
                    n = n + 1
                    out[what] = ('%s,%s,%s,%s / %s,%s,%s,%s')
                        :format(tostring(o.a), tostring(o.r), tostring(o.g),
                                tostring(o.b), tostring(o.sa), tostring(o.sr),
                                tostring(o.sg), tostring(o.sb))
                end
            end
            look(panel.W.title, 'panel title')
            look(panel.W.count, 'header count')
            look(panel.W.close, 'close glyph')
            look(panel.W.status, 'status')
            for i, c in ipairs(panel.W.chips or {}) do look(c.tx, 'chip ' .. i) end
            for i, l in ipairs(panel.W.lines or {}) do
                look(l.main, 'row ' .. i)
                look(l.sub, 'row sub ' .. i)
                look(l.right, 'row right ' .. i)
                look(l.chip_tx, 'row glyph ' .. i)
            end
            return out, n
        end
        pcall(cmd, 'bg', 'navy')
        panel.S.dkey = nil
        pcall(prerender)
        local navy, n_navy = snap()
        pcall(cmd, 'bg', 'mixed')
        panel.S.dkey = nil
        pcall(prerender)
        local mix, n_mix = snap()
        pcall(cmd, 'bg', was)
        panel.S.dkey = nil
        pcall(prerender)

        local bad = {}
        for what, v in pairs(navy) do
            if mix[what] ~= v then
                bad[#bad + 1] = ('%s: navy %s, mixed %s')
                    :format(what, v, tostring(mix[what]))
            end
        end
        if n_navy < 8 or n_mix < 8 then
            fail_('background: mixed list pane strings were drawn to compare',
                  ('navy %d, mixed %d -- this checked almost nothing')
                  :format(n_navy, n_mix))
        elseif #bad == 0 then
            ok_('background: mixed draws its LIST exactly as navy does',
                ('%d strings, same colour and same outline'):format(n_navy))
        else
            fail_(('background: mixed list ink, %d string(s) differ'):format(#bad),
                  bad[1])
        end
    end

    --[[ And the detail half of `mixed` is parchment's, string for string.

         The check below says the outline is the pane's own; this says the whole pane is
         the preset it borrows, colour and outline together, on every string it draws.
         The two are worth keeping apart, because one can pass while the other
         fails. ]]
    do
        local was = theme.bg_theme()
        local sel
        for _, l in ipairs(panel.S.lines) do
            if l.kind == 'row' then sel = l.row.key break end
        end
        local function snap(preset)
            select_key(sel)
            pcall(cmd, 'bg', preset)
            panel.S.dkey = nil
            pcall(prerender)
            local out, n = {}, 0
            local function look(t, what)
                local o = t and objs[t.name]
                if o and o.vis and o.a then
                    n = n + 1
                    out[what] = ('%s,%s,%s,%s / %s,%s,%s,%s')
                        :format(tostring(o.a), tostring(o.r), tostring(o.g),
                                tostring(o.b), tostring(o.sa), tostring(o.sr),
                                tostring(o.sg), tostring(o.sb))
                end
            end
            look(panel.W.d_title, 'quest title')
            look(panel.W.d_meta, 'meta line')
            for i, t in ipairs(panel.W.d_lines or {}) do
                look(t.b, 'line ' .. i)
                look(t.a, 'glyph ' .. i)
                look(t.n, 'number ' .. i)
                look(t.c, 'chevron ' .. i)
                look(t.g, 'tag ' .. i)
            end
            return out, n
        end
        local parch, n_parch = snap('parchment')
        local mix, n_mix = snap('mixed')
        pcall(cmd, 'bg', was)
        panel.S.dkey = nil
        pcall(prerender)

        local bad = {}
        for what, v in pairs(parch) do
            if mix[what] ~= v then
                bad[#bad + 1] = ('%s: parchment %s, mixed %s')
                    :format(what, v, tostring(mix[what]))
            end
        end
        if n_parch < 8 or n_mix < 8 then
            fail_('background: mixed detail strings were drawn to compare',
                  ('parchment %d, mixed %d -- this checked almost nothing')
                  :format(n_parch, n_mix))
        elseif #bad == 0 then
            ok_('background: mixed draws its DETAIL exactly as parchment does',
                ('%d strings, same colour and same outline'):format(n_parch))
        else
            fail_(('background: mixed detail ink, %d string(s) differ'):format(#bad),
                  bad[1])
        end
    end

    --[[ And the detail half wears its own outline, not the window's.

         `set_text` falls back to `theme.col.stroke`, which is the window's, and for the
         three presets that dress the window as one thing that is the very table `dcol`
         reads through to. It is right by coincidence there and wrong for `mixed`: dark
         parchment ink drawn inside leather's near-black halo at alpha 235.

         Every string the pane draws has to carry one of the pane's two outline roles,
         `stroke` for prose and `stroke_hue` for the ladder, and both are parchment's
         here. Read off the recorded draw calls and copied out before the preset is
         restored. ]]
    do
        local was = theme.bg_theme()
        local sel
        for _, l in ipairs(panel.S.lines) do
            if l.kind == 'row' then sel = l.row.key break end
        end
        select_key(sel)
        pcall(cmd, 'bg', 'mixed')
        panel.S.dkey = nil
        pcall(prerender)

        local function key(a, r, g, b)
            return ('%s,%s,%s,%s'):format(tostring(a), tostring(r), tostring(g),
                                          tostring(b))
        end
        local pink = theme.bg_themes.parchment.ink
        local bare = key(pink.stroke.a, pink.stroke.r, pink.stroke.g, pink.stroke.b)
        local step = key(pink.stroke_hue.a, pink.stroke_hue.r, pink.stroke_hue.g,
                         pink.stroke_hue.b)
        local win = theme.col.stroke
        local window = key(win.a, win.r, win.g, win.b)

        local n_bare, n_step, seen, bad = 0, 0, 0, {}
        local function look(t, what)
            local o = t and objs[t.name]
            if not o or not o.vis or not o.sa then return end
            seen = seen + 1
            local k = key(o.sa, o.sr, o.sg, o.sb)
            if k == bare then n_bare = n_bare + 1
            elseif k == step then n_step = n_step + 1
            elseif #bad < 4 then bad[#bad + 1] = what .. ' drew stroke ' .. k end
        end
        look(panel.W.d_title, 'quest title')
        look(panel.W.d_meta, 'meta line')
        for i, t in ipairs(panel.W.d_lines or {}) do
            look(t.b, 'line ' .. i)
            look(t.a, 'glyph ' .. i)
            look(t.n, 'number ' .. i)
            look(t.c, 'chevron ' .. i)
            look(t.g, 'tag ' .. i)
        end

        pcall(cmd, 'bg', was)
        panel.S.dkey = nil
        pcall(prerender)
        if seen < 8 then
            fail_('background: mixed detail strings were drawn to check',
                  seen .. ' -- this checked almost nothing')
        elseif #bad > 0 then
            fail_(('background: %d detail string(s) wear the window\'s outline')
                  :format(#bad), bad[1] .. ' (the window\'s is ' .. window .. ')')
        elseif n_bare == 0 or n_step == 0 then
            fail_('background: both detail outline roles are drawn',
                  ('%d bare, %d step -- one of them checked nothing')
                  :format(n_bare, n_step))
        else
            ok_('background: under mixed the detail pane wears parchment\'s outline',
                ('%d strings: %d bare, %d inside the step halo')
                :format(seen, n_bare, n_step))
        end
    end

    --[[ And its tints come from the two parents. `mixed` carries no colours of its own;
         if it did they would be a copy of leather and parchment that could drift from
         them. Asserted by identity against the parents, not by value. ]]
    do
        local was = theme.bg_theme()
        theme.set_bg('mixed')
        local l, p = theme.col.panel_tint, theme.col.detail_tint
        local okl = (l.r == theme.bg_themes.leather.panel.r
                     and l.b == theme.bg_themes.leather.panel.b)
        local okp = (p.r == theme.bg_themes.parchment.detail.r
                     and p.b == theme.bg_themes.parchment.detail.b)
        theme.set_bg(was)
        if okl and okp then
            ok_('background: mixed wears leather on the list and parchment on the detail',
                ('list rgb(%d,%d,%d), detail rgb(%d,%d,%d)')
                :format(l.r, l.g, l.b, p.r, p.g, p.b))
        else
            fail_('background: mixed tints', ('list=%s detail=%s')
                  :format(tostring(okl), tostring(okp)))
        end
    end

    --[[ The outline moves with the preset.

         `ui/draw.lua` hardcoded a near-black stroke on every text object and
         `theme.col.stroke` existed and was read by nothing. Right for light text over a
         dark panel; on a light page a dark halo around dark ink at 9pt is a smudge, so
         parchment takes it to zero alpha. Read back off the recorded draw calls, on a
         text object the panel actually drew. ]]
    do
        local was = theme.bg_theme()
        local title = panel.W and panel.W.d_title
        local seen = {}
        for _, name in ipairs(theme.bg_theme_names()) do
            theme.set_bg(name)
            panel.S.dkey = nil
            pcall(prerender)
            local o = objs[title.name]
            seen[name] = o and o.sa or nil
        end
        theme.set_bg(was)
        panel.S.dkey = nil
        pcall(prerender)
        if seen.parchment == 0 and (seen.navy or 0) > 0 then
            ok_('background: the text outline follows the preset',
                ('navy alpha %s, parchment alpha %s')
                :format(tostring(seen.navy), tostring(seen.parchment)))
        else
            fail_('background: stroke alpha per preset',
                  ('navy=%s leather=%s parchment=%s'):format(tostring(seen.navy),
                   tostring(seen.leather), tostring(seen.parchment)))
        end
    end

    --[[ And the mark on screen is questmarks' colour, byte for byte, on every preset.

         The panel does not touch the colour at all, so the invariant is asserted in its
         strongest form rather than approximated: what the client is told to draw is what
         render/markers.lua returned, on a page as well as on a slab.

         Read off the recorded draw of the row marks the list actually drew, not from the
         funnel that produced them, and compared against markers.style_for directly so a
         copied table cannot creep in. Any transform reintroduced anywhere between
         questmarks and the client reddens this on the light presets. ]]
    do
        local okm, markers = pcall(require, 'render/markers')
        if not okm then
            fail_('background: render/markers reachable for the marker check',
                  tostring(markers))
        else
            local was = theme.bg_theme()
            local bad, checked = {}, 0
            for _, name in ipairs(theme.bg_theme_names()) do
                pcall(cmd, 'bg', name)
                panel.S.dkey = nil
                pcall(prerender)
                for i, w in ipairs(panel.W.lines) do
                    local l = panel.S.lines[panel.S.scroll + i]
                    local o = objs[w.chip_tx.name]
                    if l and l.kind == 'row' and o and o.vis then
                        local e = l.row.entry
                        local _, wr, wg, wb = markers.style_for('turnin', e.cat, e.area)
                        checked = checked + 1
                        if o.r ~= wr or o.g ~= wg or o.b ~= wb then
                            if #bad < 4 then
                                bad[#bad + 1] = ('%s %s: drew rgb(%s,%s,%s), questmarks says rgb(%d,%d,%d)')
                                    :format(name, l.row.key, tostring(o.r),
                                            tostring(o.g), tostring(o.b), wr, wg, wb)
                            end
                        end
                    end
                end
            end
            pcall(cmd, 'bg', was)
            panel.S.dkey = nil
            pcall(prerender)
            if checked < 20 then
                fail_('background: marks were drawn to check',
                      checked .. ' -- this checked almost nothing')
            elseif #bad == 0 then
                ok_('background: the drawn mark is questmarks\' own colour on every preset',
                    ('%d marks across %d presets, byte for byte')
                    :format(checked, #theme.bg_theme_names()))
            else
                fail_(('background: %d mark(s) are not questmarks\' colour'):format(#bad),
                      bad[1])
            end
        end
    end


    --[[ The sheet is on disk and is shaped like the pane.

         Read out of the PNG header rather than decoded: width and height are big-endian
         32-bit at offsets 16 and 20. The aspect matters because the texture is stretched
         into the pane's quad, and a sheet of the wrong shape is not rejected by
         anything, it just distorts. 10% is generous and would still catch a landscape
         sheet or a square one. ]]
    do
        local function be32(str)
            local a, b, c, d = str:byte(1, 4)
            return ((a * 256 + b) * 256 + c) * 256 + d
        end
        local g = panel.geom()
        --[[ Each page against its own pane. Both are DERIVED by tools/make_pages.py,
             which crops rather than stretches, so the tolerance is tight: 2% catches a
             stale sheet left over from a pane-width change, which a generous one would
             wave through. ]]
        local report, bad = {}, {}
        for _, t in ipairs({{'list', g.w / g.h}, {'detail', g.dw / g.h}}) do
            local which = t[1]
            local p = theme.bg_texture(which)
            if not p then
                bad[#bad + 1] = which .. ': ' .. tostring(theme.bg_pages[which])
                                .. ' not on disk'
            else
                local f = real_open(p, 'rb')
                local head = f:read(24)
                local bytes = f:seek('end')
                f:close()
                local w, h = be32(head:sub(17, 20)), be32(head:sub(21, 24))
                local want, got = t[2], w / h
                local off = math.abs(got / want - 1) * 100
                if head:sub(2, 4) ~= 'PNG' then
                    bad[#bad + 1] = which .. ': not a PNG'
                elseif off > 2 then
                    bad[#bad + 1] = ('%s: %dx%d is aspect %.4f, its pane is %.4f (%.1f%%)')
                        :format(which, w, h, got, want, off)
                else
                    report[#report + 1] = ('%s %dx%d %.2f%%')
                        :format(which, w, h, off)
                end
            end
        end
        if #bad == 0 then
            ok_('background: each page fits its own pane',
                table.concat(report, ', ') .. ' of stretch')
        else
            fail_('background: page shape', table.concat(bad, ' | '))
        end

        --[[ There is no separate "the two pages are different files" check, and that is
             deliberate. It cannot fail: the panes' aspects are 0.857 and 0.757, 13%
             apart against a 2% tolerance, so no single sheet satisfies both and pointing
             them at one always trips the shape check above first. Verified by mutation.
             A check that cannot fail is not a check. ]]
    end

    --[[ And it is actually drawn, on BOTH panes, with the tint and not the flat fill.
         Read back off the recorded draw calls. ]]
    do
        pcall(cmd, 'show')
        local sel
        for i, l in ipairs(panel.S.lines) do
            if l.kind == 'row' then sel = i break end
        end
        force_select(sel)
        panel.S.dkey = nil
        pcall(prerender)
        local bad = {}
        for _, t in ipairs({{'list', panel.W.bg, theme.col.panel_tint},
                            {'detail', panel.W.d_bg, theme.col.detail_tint}}) do
            local o, tint = t[2], t[3]
            if not o.p.vis then bad[#bad + 1] = t[1] .. ' not visible' end
            --[[ Its OWN page and not the other's: swapped, both gutter shadows land on
                 the outside and the book opens backwards. ]]
            local want = theme.bg_pages[t[1]]
            if not (o.p.tex and o.p.tex:find(want, 1, true)) then
                bad[#bad + 1] = ('%s texture=%s, wanted %s')
                    :format(t[1], tostring(o.p.tex), want)
            end
            if o.p.r ~= tint.r or o.p.g ~= tint.g or o.p.b ~= tint.b
               or o.p.a ~= tint.a then
                bad[#bad + 1] = ('%s colour rgb(%s,%s,%s)a%s is not the tint')
                    :format(t[1], tostring(o.p.r), tostring(o.p.g), tostring(o.p.b),
                            tostring(o.p.a))
            end
        end
        if #bad == 0 then
            ok_('background: drawn on both panes, with the tint',
                ('alpha %d preserved, so the scene still shows through')
                :format(theme.col.panel_tint.a))
        else
            fail_('background: not drawn as expected', table.concat(bad, ' | '))
        end
    end

    --[[ The chrome moves with the preset, and moves back.

         A preset is not two numbers: the header band, row selection, moulding, divider,
         rule, hover fill and scroll thumb are all blue-grey, and blue chrome over brown
         parchment is what made leather unusable before. Three things worth asserting.

         Every chrome role a preset names must be a role that exists. A mistyped key
         writes a colour nobody reads and the mismatch survives, silently.

         Switching away and back has to restore, not approximate. The base values are
         captured once, so this is checking they were captured and not recomputed.

         And the two chrome colours that carry text must clear 4.5:1 for the title on
         them, in every preset. The warm values are matched on luminance precisely so
         this holds without re-running the panel's contrast argument. ]]
    do
        local known = {}
        for _, k in ipairs(theme.bg_chrome_keys) do known[k] = true end
        for _, k in ipairs(theme.bg_ink_keys) do known[k] = true end
        local bad = {}
        for _, name in ipairs(theme.bg_theme_names()) do
            for _, group in ipairs({'chrome', 'ink'}) do
                for k in pairs(theme.bg_themes[name][group] or {}) do
                    if not known[k] then
                        bad[#bad + 1] = ('%s names %s role "%s", which nothing reads')
                            :format(name, group, tostring(k))
                    end
                end
            end
        end
        if #bad == 0 then
            ok_('background: every role a preset names is a real one',
                ('%d chrome + %d ink'):format(#theme.bg_chrome_keys,
                 #theme.bg_ink_keys))
        else
            fail_('background: unknown chrome role', table.concat(bad, ' | '))
        end

        --[[ And the ladder's "now" is the panel's amber by identity, not by value.

             `theme.col.step_now = theme.col.amber` is one table shared, not a copy of
             three numbers, and the theme leans on that: retuning the budget's amber has
             to move the ladder with it. Written as a copy the two agree today and drift
             silently on the first retune, which is the failure the whole
             borrow-rather-than-copy convention exists to prevent.

             Checked as table identity on the presets that do not split them, and as
             non-identity on the one that does. Both counts must be non-zero: if no preset
             splits them the pair needs no two roles, and if none shares them the alias is
             gone. Replacing the alias with a literal copy of amber's numbers reddens
             it. ]]
        do
            local was2 = theme.bg_theme()
            --[[ Both borrowed pairs: the ladder's "now" is the panel's amber and its
                 "not yet" is the panel's faint grey. ]]
            local PAIRS = {{'amber', 'step_now'}, {'text_faint', 'step_todo'}}
            local bad2, shared, split = {}, 0, 0
            for _, name in ipairs(theme.bg_theme_names()) do
                theme.set_bg(name)
                --[[ The ink the WINDOW wears, following `from` the way theme.set_bg
                     does. ]]
                local t = theme.bg_themes[name]
                local src = (t.from and theme.bg_themes[t.from]) or t
                local ink = src.ink or {}
                for _, p in ipairs(PAIRS) do
                    local named = (ink[p[1]] and 1 or 0) + (ink[p[2]] and 1 or 0)
                    if named == 0 then
                        shared = shared + 1
                        if theme.col[p[2]] ~= theme.col[p[1]] then
                            bad2[#bad2 + 1] = ('%s copied %s instead of sharing it')
                                :format(name, p[1])
                        end
                    elseif named == 1 then
                        split = split + 1
                        if theme.col[p[2]] == theme.col[p[1]] then
                            bad2[#bad2 + 1] = ('%s names one of %s/%s and got both')
                                :format(name, p[1], p[2])
                        end
                    end
                end
            end
            theme.set_bg(was2)
            if shared == 0 or split == 0 then
                fail_('background: the ladder aliases are exercised both ways',
                      ('%d sharing, %d splitting'):format(shared, split))
            elseif #bad2 == 0 then
                ok_('background: the ladder wears the panel\'s own amber and grey, by identity',
                    ('%d shared, %d split, over 2 pairs'):format(shared, split))
            else
                fail_('background: a ladder role is a copy, not the role it borrows',
                      table.concat(bad2, ' | '))
            end
        end

        --[[ The title colour is read AFTER the switch, not before it. Captured once it
             was navy's near-white measured against parchment's near-cream chrome, which
             reported 2.4:1 for a pairing that never happens. A preset changes both
             sides. ]]
        local worst, wname = 99, nil
        for _, name in ipairs(theme.bg_theme_names()) do
            theme.set_bg(name)
            local title = {theme.col.text.r, theme.col.text.g, theme.col.text.b}
            for _, role in ipairs({'header_bg', 'row_sel'}) do
                local col = theme.col[role]
                local r = ratio(title, {col.r, col.g, col.b})
                if r < worst then worst, wname = r, name .. '/' .. role end
                if r < 4.5 then
                    fail_(('background: %s %s cannot carry the title'):format(name, role),
                          ('rgb(%d,%d,%d) gives %.1f:1'):format(col.r, col.g, col.b, r))
                end
            end
        end
        --[[ Guarded on `worst`, because this sat outside the loop and printed
             unconditionally: a run where a preset failed at 4.5:1 reported the
             failure AND the claim that every preset clears. ]]
        if worst >= 4.5 then
            ok_('background: the title clears 4.5:1 on every preset chrome',
                ('worst is %s at %.1f:1'):format(tostring(wname), worst))
        end

        --[[ Switch away and back, and the base must come back byte for byte. ]]
        --[[ Chrome and ink together: a preset that moves one and not the other is
             half a preset. ]]
        local ALL_ROLES = {}
        for _, k in ipairs(theme.bg_chrome_keys) do ALL_ROLES[#ALL_ROLES + 1] = k end
        for _, k in ipairs(theme.bg_ink_keys) do ALL_ROLES[#ALL_ROLES + 1] = k end

        theme.set_bg('navy')
        local before = {}
        for _, k in ipairs(ALL_ROLES) do
            local c = theme.col[k]
            before[k] = ('%d,%d,%d,%d'):format(c.a, c.r, c.g, c.b)
        end
        theme.set_bg('leather')
        local moved = 0
        for _, k in ipairs(ALL_ROLES) do
            local c = theme.col[k]
            if ('%d,%d,%d,%d'):format(c.a, c.r, c.g, c.b) ~= before[k] then
                moved = moved + 1
            end
        end
        theme.set_bg('navy')
        local restored = 0
        for _, k in ipairs(ALL_ROLES) do
            local c = theme.col[k]
            if ('%d,%d,%d,%d'):format(c.a, c.r, c.g, c.b) == before[k] then
                restored = restored + 1
            end
        end
        if moved > 0 and restored == #ALL_ROLES then
            ok_('background: a preset moves the roles it names, and navy restores all',
                ('%d moved, %d restored exactly'):format(moved, restored))
        else
            fail_('background: chrome switching',
                  ('%d of %d moved, %d restored'):format(moved,
                   #ALL_ROLES, restored))
        end
    end

    --[[ Switching the tint, through the real command, and the drawn colour following
         it. Which preset looks best is a taste call the rasteriser cannot settle, since
         it records colour but cannot judge it, so it is a command and the decision gets
         made in game. What is checkable is that the command switches what reaches the
         client, persists it, and refuses a name it does not know. ]]
    do
        local cfg = package.loaded['config']
        local was = theme.bg_theme()
        local bad = {}
        for _, name in ipairs(theme.bg_theme_names()) do
            local saves = cfg._saves()
            pcall(cmd, 'bg', name)
            panel.S.dkey = nil
            pcall(prerender)
            if theme.bg_theme() ~= name then
                bad[#bad + 1] = name .. ': not selected'
            end
            local want = theme.bg_themes[name]
            local o = panel.W.d_bg
            if o.p.r ~= want.detail.r or o.p.b ~= want.detail.b then
                bad[#bad + 1] = ('%s: drawn rgb(%s,%s,%s) is not the preset')
                    :format(name, tostring(o.p.r), tostring(o.p.g), tostring(o.p.b))
            end
            if cfg._get().bg ~= name or cfg._saves() <= saves then
                bad[#bad + 1] = ('%s: not persisted (bg=%s, %d writes)')
                    :format(name, tostring(cfg._get().bg), cfg._saves() - saves)
            end
        end
        if #bad == 0 then
            ok_('background: //qmui bg switches the tint and saves it',
                table.concat(theme.bg_theme_names(), ' | '))
        else
            fail_('background: switching', table.concat(bad, ' | '))
        end

        --[[ And an unknown name is REFUSED, keeping whatever was in force. A settings
             file from a newer build must not be able to blank the panes. ]]
        local before = theme.bg_theme()
        pcall(cmd, 'bg', 'chartreuse')
        if theme.bg_theme() == before and theme.set_bg('chartreuse') == nil then
            ok_('background: an unknown tint name is refused, not applied',
                ('still on %s'):format(before))
        else
            fail_('background: unknown name', theme.bg_theme())
        end

        pcall(cmd, 'bg', was)
        panel.S.dkey = nil
        pcall(prerender)
    end

    --[[ A missing sheet falls back to the flat fill, and this is the assertion that
         matters most.

         A prim whose texture will not load draws nothing at all and reports nothing.
         Without the fallback, a renamed or missing sheet leaves the whole window
         invisible while still swallowing every click over it, which is the worst failure
         this panel can have and it is completely silent. Driven by pointing
         `theme.bg_pages` at files that are not there. ]]
    do
        local was = theme.bg_pages
        theme.bg_pages = {list = 'no_such_page.png', detail = 'no_such_page.png'}
        panel.S.dkey = nil
        local okr = pcall(prerender)
        local bg, dbg = panel.W.bg, panel.W.d_bg
        local fell_back = okr
            and bg.p.vis and dbg.p.vis
            and bg.p.r == theme.col.panel_bg.r and bg.p.b == theme.col.panel_bg.b
            and dbg.p.r == theme.col.detail_bg.r and dbg.p.b == theme.col.detail_bg.b
        theme.bg_pages = was
        panel.S.dkey = nil
        pcall(prerender)
        if fell_back then
            ok_('background: a missing sheet falls back to the flat fill',
                'the window is never left invisible')
        else
            fail_('background: missing sheet',
                  ('render=%s list vis=%s rgb(%s,%s,%s) detail vis=%s rgb(%s,%s,%s)')
                  :format(tostring(okr), tostring(bg.p.vis), tostring(bg.p.r),
                          tostring(bg.p.g), tostring(bg.p.b), tostring(dbg.p.vis),
                          tostring(dbg.p.r), tostring(dbg.p.g), tostring(dbg.p.b)))
        end
        --[[ And it comes back when the sheet does. The probe is cached on the name, so
             a stale cache would leave the panel on the flat fill forever. ]]
        if panel.W.bg.p.tex
           and panel.W.bg.p.tex:find(theme.bg_pages.list, 1, true) then
            ok_('background: and the sheets return when the names do')
        else
            fail_('background: the probe cache went stale',
                  tostring(panel.W.bg.p.tex))
        end
    end
end


-- ---------------------------------------------------------------------------
-- A step's title wears its own state
-- ---------------------------------------------------------------------------

--[[ Asked for after seeing the ladder in game: green behind you, amber where you are,
     grey ahead, so position reads off the whole line rather than off a 5px character in
     a side column.

     It spends hue on a whole string, which the theme's budget does not do elsewhere.
     What is asserted here is that it is actually done, that the title and its glyph
     agree, and that the wrapped continuation lines agree with the title they belong
     to. A ladder where line one is amber and line two is grey would be worse than no
     colour at all. ]]
print('')
print('=== a step title wears its own state ===')
do
    do
        local function same(a, b)
            return a and b and a.r == b.r and a.g == b.g and a.b == b.b
        end
        --[[ Every quest in the list, not one. The continuation half of this needs a
             title long enough to wrap, and none of Tuning In's are, now that the drop
             mobs sit on a line of their own: checked on that quest alone it passes while
             a mutation blanks the continuation colour. `wrapped` counts them and the
             assertion fails at zero. ]]
        local bad, seen, checked, wrapped = {}, {}, 0, 0
        for _, key in ipairs(all_row_keys()) do
            if select_key(key) then
                panel.S.showall = false
                panel.S.dkey = nil
                pcall(prerender)
                local cur, curcol = nil, nil
                for _, d in ipairs(panel.S.dlines or {}) do
                    if d.step then
                        cur, curcol = d.step, d.col
                        checked = checked + 1
                        --[[ The title's colour IS the glyph's colour. Read off the drawn
                             record rather than recomputed, so the two cannot be right in
                             the test and wrong on screen. ]]
                        if not same(d.col, d.gcol) then
                            bad[#bad + 1] = ('%s step %d title and glyph disagree')
                                :format(key, d.step)
                        end
                        for _, t in ipairs({{'done', theme.dcol.step_done},
                                            {'candidate', theme.dcol.step_now},
                                            {'todo', theme.dcol.text_faint}}) do
                            if same(d.col, t[2]) then
                                seen[t[1]] = (seen[t[1]] or 0) + 1
                            end
                        end
                    elseif cur and d.size == theme.fs_step and d.col then
                        --[[ A wrapped continuation of that title. ]]
                        wrapped = wrapped + 1
                        if not same(d.col, curcol) then
                            bad[#bad + 1] = ('%s step %d wraps to a different colour')
                                :format(key, cur)
                        end
                    end
                end
            end
        end
        local tally = {}
        for k, v in pairs(seen) do tally[#tally + 1] = k .. '=' .. v end
        table.sort(tally)
        if checked < 20 then
            fail_('step colour: steps were drawn to check', checked)
        elseif wrapped == 0 then
            fail_('step colour: a wrapped title was among them',
                  '0 continuation lines -- that half checked nothing')
        elseif #bad > 0 then
            fail_(('step colour: %d problem(s)'):format(#bad), bad[1])
        elseif not (seen.done and seen.candidate and seen.todo) then
            --[[ All three states must occur, or two thirds of this passes vacuously. ]]
            fail_('step colour: all three states occur',
                  'saw ' .. table.concat(tally, ' '))
        else
            ok_('step colour: the title wears its glyph colour, and its wraps follow',
                ('%d steps, %d wrapped lines, %s')
                :format(checked, wrapped, table.concat(tally, ' ')))
        end

        --[[ And the title carries an outline the prose beneath it does not.
             `stroke_hue` is a role of its own because a preset can want no halo on prose,
             as parchment does by setting stroke to zero alpha, and one on a coloured
             string. Read off the recorded draw calls under that preset, where the two
             differ. ]]
        local was = theme.bg_theme()
        pcall(cmd, 'bg', 'parchment')
        panel.S.dkey = nil
        pcall(prerender)
        local title_a, prose_a
        for i, t in ipairs(panel.W.d_lines) do
            local d = panel.S.dlines[panel.S.dscroll + i]
            local o = objs[t.b.name]
            if d and o and o.sa then
                if d.step then title_a = title_a or o.sa
                elseif d.size == theme.fs_prose then prose_a = prose_a or o.sa end
            end
        end
        pcall(cmd, 'bg', was)
        panel.S.dkey = nil
        pcall(prerender)
        if title_a and prose_a and title_a > 0 and prose_a == 0 then
            ok_('step colour: the title is outlined where the prose is not',
                ('parchment: title stroke alpha %d, prose %d'):format(title_a, prose_a))
        else
            fail_('step colour: the step outline',
                  ('title=%s prose=%s'):format(tostring(title_a), tostring(prose_a)))
        end

        --[[ And the glyph and the number are inside the same halo as the title.

             They are the same state hue as the title beside them, and over parchment
             that hue is bright on a bright page. The title carries `stroke_hue`; let
             these two fall through to the pane's `stroke`, which parchment takes to
             zero alpha, and they are the two strings in the ladder with nothing holding
             them off the page, at 1.07:1 and 1.23:1.

             This is also what makes the contrast sweep's halo path honest: it measures
             those roles against an outline, and this is the assertion that the outline is
             actually drawn. Mutating the two `d.stroke` arguments out of ui/panel.lua
             reddens it. ]]
        local pink = theme.bg_themes.parchment.ink
        do
            local was2 = theme.bg_theme()
            pcall(cmd, 'bg', 'parchment')
            panel.S.dkey = nil
            pcall(prerender)
            local want = ('%d,%d,%d,%d'):format(pink.stroke_hue.a, pink.stroke_hue.r,
                                                pink.stroke_hue.g, pink.stroke_hue.b)
            local n, bad = 0, {}
            for i, t in ipairs(panel.W.d_lines) do
                local d = panel.S.dlines[panel.S.dscroll + i]
                if d and d.step then
                    for _, pair in ipairs({{t.a, 'glyph'}, {t.n, 'number'},
                                           {t.b, 'title'}}) do
                        local o = objs[pair[1].name]
                        if o and o.vis and o.sa then
                            n = n + 1
                            local got = ('%s,%s,%s,%s'):format(tostring(o.sa),
                                tostring(o.sr), tostring(o.sg), tostring(o.sb))
                            if got ~= want and #bad < 4 then
                                bad[#bad + 1] = ('step %d %s drew stroke %s')
                                    :format(d.step, pair[2], got)
                            end
                        end
                    end
                end
            end
            pcall(cmd, 'bg', was2)
            panel.S.dkey = nil
            pcall(prerender)
            if n < 6 then
                fail_('step colour: ladder strings were drawn to check their outline',
                      n .. ' -- this checked almost nothing')
            elseif #bad > 0 then
                fail_(('step colour: %d ladder string(s) outside the halo'):format(#bad),
                      bad[1] .. ' wanting ' .. want)
            else
                ok_('step colour: glyph, number and title all sit inside the step halo',
                    ('parchment: %d strings at stroke %s'):format(n, want))
            end
        end

        --[[ And parchment wears the same green and the same amber as navy. The ladder
             is one colour scheme on every preset, not a bright pair on the dark ones and
             a solved dark pair on the light one.

             Read off the recorded colour of the title, its glyph and its number, keyed by
             step number and not by line index, because a redraw rebuilds that list, and
             copied out before the preset is restored. Re-adding a `step_done` or
             `step_now` override to parchment's ink reddens it. ]]
        do
            local was2 = theme.bg_theme()
            --[[ Every quest in the list, for the reason the check above sweeps them all:
                 one quest's ladder is three steps of one or two states, and two thirds of
                 this would then pass vacuously. ]]
            --[[ All three ladder states. `step_todo` is the ladder's own grey and falls
                 back like the other two, so the whole ladder is one colour scheme on
                 every preset and all three belong in the comparison. Take the grey from
                 `text_faint` instead and parchment darkens it for its prose.
                 `text_faint` itself stays dark here and is checked against the page by
                 the sweep, as prose.

                 Recording the STATE alongside the colour means a step that changes state
                 between the two draws shows up as a difference rather than quietly
                 leaving the comparison. ]]
            local function ladder(preset)
                pcall(cmd, 'bg', preset)
                local out, n = {}, 0
                for _, key in ipairs(all_row_keys()) do
                    if select_key(key) then
                        panel.S.showall = false
                        panel.S.dkey = nil
                        pcall(prerender)
                        for i, t in ipairs(panel.W.d_lines) do
                            local d = panel.S.dlines[panel.S.dscroll + i]
                            local st
                            if d and d.step then
                                if same(d.col, theme.dcol.step_done) then st = 'done'
                                elseif same(d.col, theme.dcol.step_now) then st = 'now'
                                elseif same(d.col, theme.dcol.step_todo) then st = 'todo'
                                end
                            end
                            local b = st and objs[t.b.name]
                            local a, num = st and objs[t.a.name], st and objs[t.n.name]
                            if b and b.vis and a and a.vis and num and num.vis then
                                n = n + 1
                                out[key .. ' step ' .. d.step] =
                                    ('%s %s,%s,%s | %s,%s,%s | %s,%s,%s')
                                    :format(st, tostring(b.r), tostring(b.g),
                                            tostring(b.b), tostring(a.r),
                                            tostring(a.g), tostring(a.b),
                                            tostring(num.r), tostring(num.g),
                                            tostring(num.b))
                            end
                        end
                    end
                end
                return out, n
            end
            local navy, n_navy = ladder('navy')
            local parch, n_parch = ladder('parchment')
            pcall(cmd, 'bg', was2)
            panel.S.dkey = nil
            pcall(prerender)

            local bad, tally = {}, {done = 0, now = 0, todo = 0}
            for step, v in pairs(navy) do
                local st = v:match('^(%a+) ')
                if st and tally[st] then tally[st] = tally[st] + 1 end
                if parch[step] ~= v then
                    bad[#bad + 1] = ('%s: navy %s, parchment %s')
                        :format(step, v, tostring(parch[step]))
                end
            end
            if n_navy < 20 or n_parch < 20 then
                fail_('step colour: both presets drew ladders to compare',
                      ('navy %d steps, parchment %d'):format(n_navy, n_parch))
            elseif tally.done == 0 or tally.now == 0 or tally.todo == 0 then
                --[[ All three, or a third of this passes vacuously. ]]
                fail_('step colour: all three ladder states occur',
                      ('done=%d now=%d todo=%d')
                      :format(tally.done, tally.now, tally.todo))
            elseif #bad == 0 then
                ok_('step colour: parchment wears the same ladder colours as navy',
                    ('%d steps (%d done, %d now, %d todo), title glyph and number identical')
                    :format(n_navy, tally.done, tally.now, tally.todo))
            else
                fail_(('step colour: %d step(s) differ between navy and parchment')
                      :format(#bad), bad[1])
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The row glyph must agree with the world marker
-- ---------------------------------------------------------------------------

--[[ The GLYPH rule, which deliberately diverges from the world markers.

     questmarks reads `!` as "there is something here to take" and `?` as "you
     have accepted this". This list is accepted-only, so that distinction is
     already carried by the list existing, and the slot was re-used on purpose:

         !   accepted, still working on it
         ?   objectives complete, hand it in

     The divergence is intentional and ui/theme.lua sets out why. What is not
     allowed to drift is the colour: it has to come from questmarks' own tables,
     because colour is what sends a player somewhere. So this asserts the glyph
     follows the panel's rule and the hue is byte-identical to what
     markers.style_for gives for that category. ]]
print('')
print('=== the row glyph ===')
do
    local okm, markers = pcall(require, 'render/markers')
    if not okm then
        fail_('glyph: render/markers reachable', markers)
    else
        local bad = 0

        -- Shape: ? only for turnin, ! for everything else in the accepted set.
        for _, c in ipairs({
            {'turnin',   'quest',   nil,        '?'},
            {'progress', 'quest',   nil,        '!'},
            {'turnin',   'mission', 'toau',     '?'},
            {'progress', 'mission', 'campaign', '!'},
        }) do
            local _, _, _, _, glyph = theme.state_style(c[1], c[2], c[3])
            if glyph ~= c[4] then
                bad = bad + 1
                fail_(('glyph shape %s/%s'):format(c[1], c[2]),
                      ('got %s, expected %s'):format(glyph, c[4]))
            end
        end
        if bad == 0 then ok_('glyph: ? means ready to hand in, ! means in progress') end

        --[[ Colour: the category's ACTIONABLE hue from questmarks, whatever the
             state. Compared against markers.style_for directly so a copied
             table cannot creep in. ]]
        local cbad = 0
        for _, c in ipairs({{'quest', nil}, {'mission', 'toau'},
                            {'mission', 'campaign'}}) do
            local _, wr, wg, wb = markers.style_for('turnin', c[1], c[2])
            for _, st in ipairs({'turnin', 'progress'}) do
                local _, r, g, b = theme.state_style(st, c[1], c[2])
                if r ~= wr or g ~= wg or b ~= wb then
                    cbad = cbad + 1
                    fail_(('glyph colour %s/%s/%s'):format(st, c[1], tostring(c[2])),
                          ('panel rgb(%d,%d,%d) vs questmarks rgb(%d,%d,%d)')
                          :format(r, g, b, wr, wg, wb))
                end
            end
        end
        if cbad == 0 then
            ok_('glyph: hue is questmarks own, and never dimmed by state',
                '3 categories x 2 states')
        end

        --[[ No blue in this list. questmarks' blue means "already done,
             available again", and `state.status_of` returns `done` for anything
             carrying the completed bit before it looks at `current`, so such a
             quest never reaches the accepted set. Painting a never-finished
             repeatable blue would claim a history the player does not have.
             Asserted two ways: the colour function ignores the flag, and no row on
             screen carries the marker blue. ]]
        local _, br, bg, bb = markers.style_for('repeat', 'quest', nil)
        local _, rr, rg, rb = theme.state_style('progress', 'quest', nil)
        if not (rr == br and rg == bg and rb == bb) then
            ok_('glyph: a never-finished repeatable is NOT painted blue',
                ('rgb(%d,%d,%d), not the repeat blue'):format(rr, rg, rb))
        else
            fail_('glyph: repeatable must not be blue here',
                  'it claims the quest has been completed before')
        end

        if panel.S.dirty then panel.rebuild() end
        local blue, reps = 0, 0
        for _, l in ipairs(panel.S.lines) do
            if l.kind == 'row' then
                if l.row.entry.repeatable then reps = reps + 1 end
                local _, r, g, b = theme.state_style(l.row.state,
                                    l.row.entry.cat, l.row.entry.area)
                if r == br and g == bg and b == bb then blue = blue + 1 end
            end
        end
        if blue == 0 then
            ok_('no row shows the repeat blue',
                ('%d repeatable quests in the list, none claimed as done'):format(reps))
        else
            fail_('rows showing repeat blue', blue)
        end

        --[[ The blue, and what it is allowed to be granted on.

             questmarks' blue means "you have finished this one and it is
             available again". A re-accepted repeatable reports exactly what a
             first acceptance reports, current set and completed clear, so the
             packet cannot tell them apart at any instant. The addon earns the
             distinction by having watched the completed bit, which is an
             observation and is persisted per character.

             Two directions, and the second is the one that matters: the flag
             alone must never buy blue, or the panel claims a history the player
             may not have. ]]
        do
            local key = 'quest/windurst/0'          -- Hat in Hand, repeatable
            local ent = {cat = 'quest', area = 'windurst', id = 0,
                         repeatable = true}
            local nonrep = {cat = 'quest', area = 'windurst', id = 20}

            model.set_seen_done({})
            local _, r1, g1, b1 = theme.state_style('progress', 'quest', nil,
                                                    model.done_before(ent))
            if not (r1 == br and g1 == bg and b1 == bb) then
                ok_('blue: NOT granted by the repeatable flag alone',
                    ('rgb(%d,%d,%d)'):format(r1, g1, b1))
            else
                fail_('blue granted without an observation',
                      'claims a completion that was never seen')
            end

            model.set_seen_done({[key] = true})
            local _, r2, g2, b2 = theme.state_style('progress', 'quest', nil,
                                                    model.done_before(ent))
            if r2 == br and g2 == bg and b2 == bb then
                ok_('blue: granted once the completion has been observed',
                    ('rgb(%d,%d,%d)'):format(r2, g2, b2))
            else
                fail_('blue after an observation',
                      ('rgb(%d,%d,%d)'):format(r2, g2, b2))
            end

            -- A non-repeatable quest can never take it, whatever is recorded.
            model.set_seen_done({['quest/windurst/20'] = true})
            if not model.done_before(nonrep) then
                ok_('blue: a non-repeatable quest never takes it')
            else
                fail_('blue on a non-repeatable quest')
            end

            --[[ The observation itself, driven through the REAL packet path:
                 mark Hat in Hand (quest/windurst/0, repeatable) completed and
                 the harvest must record it. An earlier version of this fed a
                 bitfield with nothing completed in it and asserted "0
                 recorded", which is the vacuous pass this suite has been bitten
                 by twice already. ]]
            model.set_seen_done({})
            feed(0x00A0, {0})            -- completed Windurst quests: id 0
            local learned = model.observe_completions()
            local got = model.seen_done_table()[key]
            if learned and got then
                ok_('blue: a completion is harvested from live state', key)
            else
                fail_('blue: harvest from live state',
                      ('learned=%s recorded=%s'):format(tostring(learned),
                                                        tostring(got)))
            end

            -- ...and a second pass learns nothing new, so it will not re-save.
            if model.observe_completions() == false then
                ok_('blue: a repeat harvest reports nothing new')
            else
                fail_('blue: harvest is not idempotent')
            end

            feed(0x00A0, {})             -- put the fixture back
            model.set_seen_done({})
        end

        --[[ And the tag beside the bar, which is what carries completion now
             that colour does not. ]]
        if theme.state_label.turnin == '(completed)'
           and theme.state_label.progress == '' then
            ok_('a ready quest is tagged in words, not by dimming')
        else
            fail_('completion tag', tostring(theme.state_label.turnin))
        end
    end
end

-- ---------------------------------------------------------------------------
-- A step must name the right noun
-- ---------------------------------------------------------------------------

--[[ The worst kind of fault this panel can have: telling the player something
     false rather than merely looking wrong.

     Build the phrase as verb plus `steps.row_label` and "Tuning In" step 2 renders
     as "Obtain Fomor Warrior, Fomor Monk, ...", because row_label returns the npc
     or, failing that, the mobs. On an obtain step the mobs are where the thing
     drops and the thing is in `ev`. 738 steps in the index have mobs and no npc, so
     every one of them turns on this; the 446 fight and kill ones would be correct
     either way, because there the mob genuinely is the object.

     Asserted on the real quest, through the real render path. ]]
print('')
print('=== a step names the right noun ===')
do
    local resnames = require('resnames')

    -- The id in the reported case must resolve, or nothing below means anything.
    local nm = resnames.name(1698, 'item')
    if nm == 'Extra-Fine File' then
        ok_('resnames: an item id resolves', ('1698 -> %s'):format(nm))
    else
        fail_('resnames: item id 1698', tostring(nm))
    end
    if resnames.name(999999, 'item') == nil then
        ok_('resnames: an unknown id degrades to nil, never to an id')
    end

    -- Render Tuning In and read back what step 2 actually says.
    local idx
    for i, l in ipairs(panel.S.lines) do
        if l.kind == 'row' and l.row.key == 'quest/windurst/90' then idx = i break end
    end
    if not idx then
        fail_('step phrasing: Tuning In is in the list', 'not found')
    else
        force_select(idx)
        panel.S.showall = true
        panel.S.dkey = nil
        pcall(prerender)
        local line2
        for _, d in ipairs(panel.S.dlines or {}) do
            if d.step == 2 and d.b then line2 = d.b break end
        end
        panel.S.showall = false

        if line2 and line2:find('Extra%-Fine File') then
            ok_('step 2 names the ITEM, not the mobs it drops from', line2)
        else
            fail_('step 2 names the item', tostring(line2))
        end
        if line2 and not line2:match('^Obtain%s+Fomor') then
            ok_('step 2 does not render the mobs as the object')
        else
            fail_('step 2 renders mobs as the object', tostring(line2))
        end
        --[[ The mobs are the source, and the source has a line of its own.

             The claim is that the Fomors are where the file drops, not the thing to
             obtain. Put in the title the sentence runs to 96 characters and three
             wrapped lines, so it is asserted where it now lives: the mobs must
             appear on a `source` line and must not be in the title. ]]
        local src2
        for _, d in ipairs(panel.S.dlines or {}) do
            if d.step == 2 then src2 = nil end
            if d.source and d.b then src2 = (src2 or '') .. d.b end
        end
        if src2 and src2:find('^Drops from') and src2:find('Fomor Warrior', 1, true) then
            ok_('step 2 says the mobs are the SOURCE', src2)
        else
            fail_('step 2 names its drop mobs as the source', tostring(src2))
        end
        if line2 and not line2:find('Fomor', 1, true) then
            ok_('step 2 keeps the mobs OUT of the title', line2)
        else
            fail_('step 2 title still carries the mobs', tostring(line2))
        end
    end

    --[[ The opposite shape: on a fight step the mob IS the object and must not
         gain a "from".

         Scope, stated exactly because it is narrower than it reads: this
         counts fight steps that carry mobs across the whole list, and asserts
         nothing about their wording. The property itself is asserted on one
         quest above, against the rendered detail lines, because the sentence
         only exists once a quest is selected and its pane is drawn.
         model.ladder returns the DATA rows, not the rendered title. ]]
    local checked = 0
    for _, l in ipairs(panel.S.lines) do
        if l.kind == 'row' then
            local lad = model.ladder(l.row.entry)
            for _, rr in ipairs(lad and lad.rows or {}) do
                local raw = l.row.entry.steps and l.row.entry.steps[rr.n]
                if rr.kind == 'fight' and raw and raw.mobs and #raw.mobs > 0 then
                    checked = checked + 1
                end
            end
        end
    end
    ok_('fight steps with mobs are present to have been checked',
        ('%d in the list'):format(checked))

    --[[ No title names a mob the data calls a source or a spawn.

         The general form of the fault above, swept over every step of every quest in
         the list. `steps.row_label` is role-blind on purpose, because it is
         `//qm why`'s target column where any target will do, so used as a fallback
         inside the sentence it fires on every step with no npc and no kill mob: 289
         in the index, and on each of them the object slot would hold a mob the data
         says is where something drops or what appears.

         The `(spawns X)` clause is stripped before checking, because a spawn name
         belongs there deliberately. What must not survive is a drop name anywhere,
         or a spawn name in the sentence proper. ]]
    do
        --[[ Keys first, then draw. Drawing inside a loop over `panel.S.lines` can
             rebuild that list, after which the loop's index means a different row --
             which is how this sweep took the whole suite down intermittently. ]]
        local bad, checked = {}, 0
        for _, key in ipairs(all_row_keys()) do
            local ent = select_key(key)
            if ent then
                local lad = panel.S.ladder
                for _, rr in ipairs(lad and lad.rows or {}) do
                    local raw = ent.steps and ent.steps[rr.n]
                    local wrong = {}
                    for _, m in ipairs((raw and raw.mobs) or {}) do
                        local role = m.role or 'kill'
                        if role ~= 'kill' and m.name then
                            wrong[#wrong + 1] = {model.nice_name(m.name), role}
                        end
                    end
                    if #wrong > 0 then
                        local title
                        for _, d in ipairs(panel.S.dlines or {}) do
                            if d.step == rr.n and d.b then title = d.b break end
                        end
                        if title then
                            checked = checked + 1
                            -- the deliberate spawn clause is not the sentence
                            local sentence = title:gsub('%s*%(spawns.*$', '')
                            for _, w in ipairs(wrong) do
                                if sentence:find(w[1], 1, true) then
                                    bad[#bad + 1] = ('%s step %d %s:%s in "%s"')
                                        :format(key, rr.n, w[2], w[1], sentence)
                                end
                            end
                        end
                    end
                end
            end
        end
        if checked == 0 then
            fail_('noun: steps with a non-kill mob were found',
                  '0 -- this test checked nothing')
        elseif #bad == 0 then
            ok_('noun: no title names a mob the data calls a source or a spawn',
                ('%d such steps in the list'):format(checked))
        else
            fail_(('noun: %d title(s) name a non-kill mob as their object')
                  :format(#bad), bad[1])
        end
    end

    --[[ A travel or cutscene step must be able to name its destination.

         questgraph's own `KIND_SENTENCE` table, in
         questmarks/tools/questgraph/web/quest.js, gives each kind a target type:
         npc for talk, trade, turnin, cutscene and other; `object` for examine;
         zone for travel; and none for fight, obtain and wait.

         `travel` is the one that has to be read off that table: most of its
         steps carry no npc at all, so taking the npc as the object gives a bare
         "Travel to" with the destination stranded on the line below.

         Scope, stated exactly because it is narrower than it looks: this walks
         every step of every quest in the list, but the only thing it asserts is
         that a travel/cutscene step carrying a zone and no npc can resolve that
         zone to a name. The wider "every verb gets an object" sweep is not
         implemented. ]]
    local dangling, seenkind = 0, {}
    for _, l in ipairs(panel.S.lines) do
        if l.kind == 'row' then
            local e = l.row.entry
            local lad = model.ladder(e)
            for _, rr in ipairs(lad and lad.rows or {}) do
                local raw = e.steps and e.steps[rr.n]
                if raw then
                    seenkind[rr.kind or '?'] = true
                    -- travel/cutscene must consume the zone when they have one
                    if (rr.kind == 'travel' or rr.kind == 'cutscene')
                       and type(raw.z) == 'number'
                       and not (raw.npc and raw.npc ~= '') then
                        -- the sentence must be able to name the destination
                        if not model.zone_name(raw.z) then dangling = dangling + 1 end
                    end
                end
            end
        end
    end
    local kinds = {}
    for k in pairs(seenkind) do kinds[#kinds + 1] = k end
    table.sort(kinds)
    if dangling == 0 then
        ok_('every travel/cutscene step can name its destination',
            ('kinds seen: %s'):format(table.concat(kinds, ' ')))
    else
        fail_('dangling verbs', dangling)
    end
end

-- ---------------------------------------------------------------------------
-- A step says what it needs
-- ---------------------------------------------------------------------------

--[[ The same class as the one above: not wrong-looking, but silent about the half
     of the instruction that costs the most to work out.

     Without the needs line, "Tuning In" step 5 reads `Trade to  Leepe-Hoppe` and
     never says what to trade, though the three item ids sit in that step's `reqs`.
     1532 steps in the reachable index carry a requirement, 724 of the 779 trade
     steps alone.

     The three shapes are asserted separately, on named real quests, because
     collapsing any one of them into another makes the panel assert something
     false:

       reqs           an and-list. quest/windurst/90 step 5.
       reqs_alt       a second way to satisfy the same step, any one of which
                      does it, and never an extra requirement. quest/jeuno/27
                      step 2 (four items or one Goblin Stew) and
                      quest/jeuno/132 step 3 (any one of fifteen testimonies).
       reqs_partial   the recorded list is incomplete. quest/outlands/165 step 3
                      (a list plus the flag) and quest/jeuno/91 step 2 (the
                      flag with no list at all).

     Each case is checked twice and the two halves check different things: that the
     rule produces the exact sentence, and that the panel drew that sentence and not
     something else. The second is the half a hand-built value would silently
     skip. ]]
print('')
print('=== a step says what it needs ===')
do
    local nl = panel.needs_line
    if type(nl) ~= 'function' then
        fail_('panel.needs_line is exposed', type(nl))
    end

    local function row_for(key)
        for i, l in ipairs(panel.S.lines) do
            if l.kind == 'row' and l.row.key == key then return i, l.row.entry end
        end
        return nil
    end

    --[[ Select a quest and DRAW it, so what is read back below came out of
         build_detail rather than out of this test. ]]
    local function render(key)
        local i, e = row_for(key)
        if not i then return nil end
        force_select(i)
        panel.S.dkey = nil
        local okp, err = pcall(prerender)
        if not okp then fail_('render ' .. key, err) end
        return e
    end

    --[[ The requirement the panel DREW for step `n`, reassembled from the lines
         it wrapped it across. Whitespace is normalised on both sides of every
         comparison: the phrase's own separator is two spaces and `wrap` breaks at
         one, so a line break and a separator are indistinguishable once drawn --
         which is a property of the drawing, not of the sentence. ]]
    local function drawn_needs(n)
        local parts, on = {}, false
        for _, d in ipairs(panel.S.dlines or {}) do
            if d.step then on = (d.step == n) end
            if on and d.needs and d.b then parts[#parts + 1] = d.b end
        end
        if #parts == 0 then return nil end
        return table.concat(parts, ' ')
    end
    local function norm(s) return s and (s:gsub('%s+', ' ')) or nil end

    --[[ One named case: the rule's sentence must be exactly `want`, and the panel
         must have drawn exactly the rule's sentence. ]]
    local function case(label, key, n, want)
        local e = render(key)
        if not e then fail_('needs: ' .. label .. ' is in the list', key) return nil end
        local raw = e.steps and e.steps[n]
        if not raw then fail_('needs: ' .. label .. ' has step ' .. n, key) return nil end
        local got = nl(raw)
        if got == want then
            ok_('needs: ' .. label, got)
        else
            fail_('needs: ' .. label, ('%s\n         wanted  %s'):format(tostring(got), want))
        end
        local shown = drawn_needs(n)
        if shown and norm(shown) == norm(want) then
            ok_('needs: ' .. label .. ' -- drawn, not just computed')
        else
            fail_('needs: ' .. label .. ' is drawn', tostring(shown))
        end
        return got
    end

    -- reqs: the plain case. Three items, all of them wanted.
    local tuning = case('reqs, Tuning In step 5', 'quest/windurst/90', 5,
        'Needs  Extra-Fine File, Spruce Lumber, Magicked Steel')

    --[[ And the title still names the NPC. The requirement went on its own line
         precisely so the target would keep its fixed column; a fix that moved the
         items INTO the sentence would pass every assertion above and lose the
         only thing on the line that says where to go. ]]
    do
        local title
        for _, d in ipairs(panel.S.dlines or {}) do
            if d.step == 5 and d.b then title = d.b break end
        end
        if title == 'Trade to  Leepe-Hoppe' then
            ok_('needs: the title still names the target', title)
        else
            fail_('needs: step 5 title', tostring(title))
        end
    end

    --[[ `ev` is not a requirement. Steps 2-4 of the same quest carry `ev` and no
         `reqs`, because they are where the three items come from. A needs line on
         any of them would name what the step gives you as what it asks for. ]]
    do
        local bad = {}
        for _, n in ipairs({2, 3, 4}) do
            if drawn_needs(n) then bad[#bad + 1] = n .. ': ' .. drawn_needs(n) end
        end
        if #bad == 0 then
            ok_('needs: an `ev`-only step gets NO needs line', 'Tuning In steps 2-4')
        else
            fail_('needs: ev leaked into needs', table.concat(bad, ' | '))
        end
    end

    --[[ reqs_alt: the case `inventory.meets` exists for, four specific items or a
         single Goblin Stew instead. A conjunction here would demand all five. ]]
    local gobbie = case('reqs_alt, The Gobbiebag Part I step 2', 'quest/jeuno/27', 2,
        'Needs  all of  Dhalmel Leather, Steel Ingot, Linen Cloth, Peridot'
        .. '  or  Goblin Stew 880')
    if gobbie then
        local orat = gobbie:find('  or  ', 1, true)
        local stew = gobbie:find('Goblin Stew', 1, true)
        if orat and stew and stew > orat then
            ok_('needs: the alternative sits AFTER the or, not in the list')
        else
            fail_('needs: alt is on the far side of the or', gobbie)
        end
        if gobbie:find('Peridot, Goblin Stew', 1, true) then
            fail_('needs: alt was flattened into the AND-list', gobbie)
        else
            ok_('needs: the alternative is never comma-joined to the requirements')
        end
    end

    --[[ reqs_alt, fifteen of them, past the cap. `any one of` and an honest count
         of what was not named. ]]
    local stars = case('reqs_alt of 15, Shattering Stars step 3', 'quest/jeuno/132', 3,
        'Needs  any one of  War. Testimony, Mnk. Testimony, Whm. Testimony,'
        .. ' Blm. Testimony  and 11 more')
    if stars then
        if stars:find('all of', 1, true) then
            fail_('needs: an OR-list must never say "all of"', stars)
        else
            ok_('needs: a pure OR-list never claims a conjunction')
        end
    end

    --[[ reqs_partial WITH a list: naming the two that are recorded as though they
         were the whole requirement is the completeness claim the flag exists to
         refuse. This step is the one case in the corpus carrying all three fields
         at once. ]]
    local sesame = case('reqs_partial + reqs + reqs_alt, Open Sesame step 3',
        'quest/outlands/165', 3,
        'Needs  all of  Tremorstone, Meteorite  or any one of  Soil Gem,'
        .. ' 12 Soil Geode  and more (list incomplete)')
    if sesame then
        if sesame:find('(list incomplete)', 1, true) then
            ok_('needs: an incomplete list says so')
        else
            fail_('needs: reqs_partial is stated', sesame)
        end
    end

    --[[ reqs_partial with no list at all, which is 72 steps. Silence there is
         indistinguishable from "bring nothing", which is the one reading that is
         certainly wrong. ]]
    local wounds = case('reqs_partial with no list, The Road to Aht Urhgan step 2',
        'quest/jeuno/91', 2, 'Needs  items (list not recorded)')
    if wounds then
        if wounds:find('%d') then
            fail_('needs: nothing is named when nothing is recorded', wounds)
        else
            ok_('needs: an unrecorded list names nothing at all')
        end
    end

    -- The two qualifiers that change what satisfying the requirement MEANS.
    case('equipped, Unlocking a Myth step 1', 'quest/jeuno/102', 1,
         'Needs  Sturdy Axe (equipped)')
    case('key items, quest/jeuno/131 step 4', 'quest/jeuno/131', 4,
         'Needs  smiling stone (key item), scowling stone (key item),'
         .. ' somber stone (key item), spirited stone (key item)')

    --[[ Two alternatives, one name. Key items 10 and 149 are both called
         `overdue book notification` and either satisfies the step, so saying it
         twice is not more true, and "and 1 more" would claim something was withheld
         when nothing was. ]]
    local early = case('duplicate alternatives, Early Bird step 3',
        'quest/windurst/20', 3, 'Needs  overdue book notification (key item)')
    if early then
        if early:find('more', 1, true) then
            fail_('needs: a de-duplicated alternative is not "more"', early)
        else
            ok_('needs: dropping a repeated name claims nothing was withheld')
        end
    end

    --[[ The asymmetry between the two lists, asserted directly.

         Dropping a repeated name is right for an or-list and destroys an and-list:
         two alternatives with one name are one alternative, while two requirements
         with one name are two things you need both of. No `reqs` anywhere in the
         shipped corpus contains two entries that resolve to the same name, so no
         quest can hold this half up, and a rule with no test behind it is a rule
         that quietly stops being true. Verified by mutation: de-duplicating the
         and-list as well leaves every other assertion in this file green.

         The pair is the real one. Key items 10 and 149 are both named `overdue
         book notification`; the corpus asks for them as alternatives, and this
         asks for the same pair as a set. ]]
    do
        local resnames = require('resnames')
        local pair = {{kind = 'ki', rid = 10, n = 1}, {kind = 'ki', rid = 149, n = 1}}
        local atxt, ashown, aun = resnames.join(pair, 6)
        local xtxt, xshown, xun = resnames.join(pair, 6, true)
        if ashown == 2 and aun == 0 then
            ok_('needs: an AND-list keeps both of two same-named requirements', atxt)
        else
            fail_('needs: an AND-list deleted a requirement',
                  ('%s shown=%d'):format(tostring(atxt), ashown))
        end
        if xshown == 1 and xun == 0 then
            ok_('needs: an OR-list says a repeated name once and calls nothing missing',
                xtxt)
        else
            fail_('needs: OR-list de-duplication',
                  ('%s shown=%d unnamed=%d'):format(tostring(xtxt), xshown, xun))
        end

        --[[ And the same asymmetry at the call site, which the two checks above
             cannot see: they exercise `join` directly, so passing `dedupe` on the
             AND-list in panel.lua leaves them both green. Through needs_line the
             pair must come back named twice. ]]
        local phrase = nl({reqs = pair})
        local n = 0
        for _ in tostring(phrase):gmatch('overdue book notification') do n = n + 1 end
        if n == 2 then
            ok_('needs: two same-named requirements are both named', phrase)
        else
            fail_('needs: a required item was collapsed away',
                  ('%s -- named %d time(s), wanted 2'):format(tostring(phrase), n))
        end
    end

    --[[ An id that does not resolve must not reach the screen. res/ can be older
         than the data on any install, and one rid in the shipped corpus already
         fails here (ki 5268, mission/cop/638 step 1). ]]
    do
        local got = nl({reqs = {{kind = 'item', rid = 999999, n = 1}}})
        if got and not got:find('999999', 1, true) and not got:find('nil', 1, true)
           and got:find('1 item', 1, true) then
            ok_('needs: an unresolvable id degrades to a count', got)
        else
            fail_('needs: unresolvable id', tostring(got))
        end
        local none = nl({})
        if none == nil then
            ok_('needs: a step with no requirement gets no line')
        else
            fail_('needs: a bare step invents a requirement', tostring(none))
        end

        --[[ And a list that resolves to nothing is never dropped. This is the one
             arrangement in the rule that could say something outright false: with
             the and-list gone, the alternatives read as the whole requirement.
             Synthetic because it cannot happen against the res/ on this machine,
             where every requirement id in the corpus resolves, and entirely ordinary
             on an install whose res/ predates the data, which is the case the
             degradation rule exists for. Two requirements this install cannot name,
             one alternative it can. ]]
        local half = nl({
            reqs = {{kind = 'item', rid = 999998, n = 1},
                    {kind = 'item', rid = 999999, n = 1}},
            reqs_alt = {{kind = 'item', rid = 1698, n = 1}},
        })
        if half == 'Needs  2 items (not named here)  or  Extra-Fine File' then
            ok_('needs: an unnameable requirement list is counted, never dropped',
                half)
        else
            fail_('needs: an unnameable AND-list left the alternatives standing '
                  .. 'as the whole requirement', tostring(half))
        end

        -- And the mirror: an unnameable OR-list keeps its quantifier.
        local mirror = nl({
            reqs = {{kind = 'item', rid = 1698, n = 1}},
            reqs_alt = {{kind = 'item', rid = 999998, n = 1},
                        {kind = 'item', rid = 999999, n = 1}},
        })
        if mirror == 'Needs  Extra-Fine File  or  any one of 2 items (not named here)'
        then
            ok_('needs: an unnameable alternative list stays an alternative',
                mirror)
        else
            fail_('needs: unnameable OR-list', tostring(mirror))
        end
    end

    --[[ Every drawn requirement fits the pane. The phrase is the longest string the
         ladder produces, one runs to 217 characters, and the pane it wraps into is
         296px wide at this size. A line over that is a measurement error reaching a
         new string. ]]
    --[[ And not one of them is cut short. `wrap` marks a dropped tail with ' ..',
         and a requirement cut short reads as a complete one, which is the same
         completeness claim `reqs_partial` exists to refuse arrived at from the
         layout side. The needs call passes no line cap; this is what says so. ]]
    do
        local limit = theme.d_tag_r - theme.d_title
        local over, checked, widest, cut, worst = 0, 0, 0, 0, nil
        for _, l in ipairs(panel.S.lines) do
            if l.kind == 'row' then
                render(l.row.key)
                for _, d in ipairs(panel.S.dlines or {}) do
                    if d.needs and d.b then
                        checked = checked + 1
                        local w = theme.width(d.b, theme.fs_zone)
                        if w > widest then widest = w end
                        if w > limit then over = over + 1 end
                        if d.b:sub(-3) == ' ..' then
                            cut = cut + 1
                            worst = worst or d.b
                        end
                    end
                end
            end
        end
        if checked == 0 then
            fail_('needs: lines were drawn to measure', '0 -- this test checked nothing')
        elseif over == 0 then
            ok_('needs: every drawn requirement fits the pane',
                ('%d lines, widest %dpx of %dpx'):format(checked, widest, limit))
        else
            fail_('needs: lines overflow the pane', over)
        end
        if checked > 0 and cut == 0 then
            ok_('needs: no drawn requirement is truncated',
                ('%d lines carry no ".." tail'):format(checked))
        elseif checked > 0 then
            fail_(('needs: %d drawn requirements are cut short'):format(cut),
                  tostring(worst))
        end
    end

    --[[ A needs line appears exactly where the data has one, over every step of
         every quest in the list. Both directions matter: a missing line is the
         original bug, and a spurious one is the panel inventing a requirement. ]]
    do
        local miss, extra, with, without = 0, 0, 0, 0
        for _, l in ipairs(panel.S.lines) do
            if l.kind == 'row' then
                local e = render(l.row.key)
                local lad = panel.S.ladder
                for _, rr in ipairs(lad and lad.rows or {}) do
                    local raw = e.steps and e.steps[rr.n]
                    if raw then
                        local want = #(raw.reqs or {}) > 0
                            or #(raw.reqs_alt or {}) > 0
                            or (raw.reqs_partial and true or false)
                        local got = drawn_needs(rr.n) ~= nil
                        if want then with = with + 1 else without = without + 1 end
                        if want and not got then miss = miss + 1 end
                        if got and not want then extra = extra + 1 end
                    end
                end
            end
        end
        if with == 0 then
            fail_('needs: the list holds steps with requirements',
                  '0 -- this test checked nothing')
        elseif miss == 0 and extra == 0 then
            ok_('needs: a line appears on exactly the steps that carry one',
                ('%d with, %d without, across the whole list'):format(with, without))
        else
            fail_('needs: line placement', ('%d missing, %d spurious'):format(miss, extra))
        end
    end
end

--[[ The whole reachable index through the real rule, not just the accepted list.
     The phrasing rule answers for all 6858 steps, and the 1438 reachable entries
     are where the shapes the accepted list has never shown it live. ]]
print('')
print('=== the needs rule over the whole index ===')
do
    local nl = panel.needs_line
    local quests = require('core/quests')
    local seen, ents = {}, {}
    quests.each_entry(function(_, e)
        local k = tostring(e.cat) .. '/' .. tostring(e.area) .. '/' .. tostring(e.id)
        if not seen[k] then seen[k] = true ents[#ents + 1] = {key = k, e = e} end
    end)

    local steps_n, emitted, nonascii, shapes = 0, 0, 0, {}
    local worst_ascii = nil
    for _, r in ipairs(ents) do
        for i, s in ipairs(r.e.steps or {}) do
            steps_n = steps_n + 1
            local txt = nl(s)
            local want = #(s.reqs or {}) > 0 or #(s.reqs_alt or {}) > 0
                         or (s.reqs_partial and true or false)
            if want ~= (txt ~= nil) then
                fail_('index sweep: needs line presence', r.key .. ' step ' .. i)
            end
            if txt then
                emitted = emitted + 1
                --[[ Single-byte ASCII only. Windower's text rendering is not
                     UTF-8, and these strings come from res/, which this addon
                     does not control. ]]
                if txt:find('[^\32-\126]') then
                    nonascii = nonascii + 1
                    worst_ascii = worst_ascii or (r.key .. ' step ' .. i .. ': ' .. txt)
                end
                local k = txt:match('^Needs  all of') and 'and+or'
                    or txt:match('^Needs  any one of %d+ items') and 'or-unnamed'
                    or txt:match('^Needs  any one of') and 'or-only'
                    or txt:match('not recorded') and 'flag-only'
                    or txt:match('not named here') and 'unnamed'
                    or txt:match('or any one of') and 'and+or-any'
                    or txt:find('  or  ', 1, true) and 'and+or-one'
                    or txt:match('list incomplete') and 'and+partial'
                    or 'and-only'
                shapes[k] = (shapes[k] or 0) + 1
            end
        end
    end

    if steps_n < 5000 then
        fail_('index sweep: the whole index was walked', steps_n .. ' steps')
    else
        ok_('index sweep: every step of every reachable quest',
            ('%d entries, %d steps'):format(#ents, steps_n))
    end
    if emitted == 0 then
        fail_('index sweep: requirements were found', '0 -- this test checked nothing')
    else
        ok_('index sweep: steps carrying a requirement', tostring(emitted))
    end
    if nonascii == 0 then
        ok_('index sweep: every requirement is single-byte ASCII')
    else
        fail_(('index sweep: %d non-ASCII requirement lines'):format(nonascii),
              tostring(worst_ascii))
    end

    --[[ There is deliberately no corpus-wide width check here.

         Wrapping every requirement to a limit and then asserting the lines come
         back under that limit restates `wrap`'s own postcondition: it cannot fail,
         and a test which checks nothing must fail rather than pass. The width that
         can actually go wrong is the caller's, and the sweep over the fixture's
         drawn lines above is what catches it. Verified by mutation, where widening
         the wrap target is the only thing that reddens it.

         Measured once out of suite for the record: over the whole index the widest
         wrapped requirement is 295px of the 296px available and none exceeds it. ]]

    --[[ Every shape the rule can produce must actually occur. A branch no data
         reaches is a branch no test covers, and this is the cheapest way to
         notice one going cold. ]]
    local missing = {}
    for _, k in ipairs({'and-only', 'and+or-one', 'and+or-any', 'or-only',
                        'and+or', 'and+partial', 'flag-only', 'unnamed'}) do
        if not shapes[k] or shapes[k] == 0 then missing[#missing + 1] = k end
    end
    local tally = {}
    for k, v in pairs(shapes) do tally[#tally + 1] = k .. '=' .. v end
    table.sort(tally)
    if #missing == 0 then
        ok_('index sweep: all eight phrasings occur in the corpus',
            table.concat(tally, ' '))
    else
        fail_('index sweep: phrasings with no data behind them',
              table.concat(missing, ' ') .. '  |  saw ' .. table.concat(tally, ' '))
    end
end

-- ---------------------------------------------------------------------------
-- Where a step is, and how much room its title has
-- ---------------------------------------------------------------------------

--[[ Three ways a step line goes wrong, all of them checked here.

     A step shows `G-8` and nothing else, when the zone name is suppressed for
     matching the step above. A long title runs under the chevron, when the wrap
     reserves room for the `optional` tag and not for it. And an `obtain` sentence
     carries its drop mobs, which makes the longest titles in the panel. ]]
print('')
print('=== where a step is ===')
do
    local function select_key(key)
        for i, l in ipairs(panel.S.lines) do
            if l.kind == 'row' and l.row.key == key then
                force_select(i)
                panel.S.dkey = nil
                pcall(prerender)
                return l.row.entry
            end
        end
        return nil
    end

    --[[ The case that decides it. "Lure of the Wildcat (Jeuno)" crosses four zones
         and its grid letters repeat across all of them: `G-8` is Ru'Lude Gardens at
         step 3, Upper Jeuno at step 9 and Port Jeuno at step 17. Suppress the
         repeated zone name and sixteen of its 22 steps show a bare grid. ]]
    local e = select_key('quest/jeuno/90')
    if not e then
        fail_('location: Lure of the Wildcat (Jeuno) is in the list')
    else
        --[[ The location line is the one at the standard title column in the zone
             size that is neither a requirement nor a source. Collected per step. ]]
        local loc, cur = {}, nil
        for _, d in ipairs(panel.S.dlines or {}) do
            if d.step then cur = d.step end
            if cur and d.b and d.size == theme.fs_zone and not d.needs
               and not d.source and d.x == theme.d_title then
                loc[cur] = loc[cur] or d.b
            end
        end

        --[[ Compared against the step's own `g`, not matched against a pattern. A
             line that is exactly the map cell is the fault, a coordinate with nothing
             to attach it to, and the data says what that cell is, so there is nothing
             to guess about. ]]
        local bare, checked, sample = {}, 0, nil
        for n, s in ipairs(e.steps or {}) do
            if s.z then
                checked = checked + 1
                local txt = loc[n]
                if txt == nil or (s.g and txt == s.g) then
                    bare[#bare + 1] = n .. ':' .. tostring(txt)
                elseif not txt:find(model.zone_name(s.z), 1, true) then
                    bare[#bare + 1] = n .. ':' .. txt .. '(wrong zone)'
                end
                if n == 3 then sample = txt end
            end
        end
        if checked < 20 then
            fail_('location: the whole ladder was read', checked .. ' steps with a zone')
        elseif #bare == 0 then
            ok_('location: every step names its zone, not just a map cell',
                ('%d steps, step 3 reads "%s"'):format(checked, tostring(sample)))
        else
            fail_(('location: %d step(s) show a bare grid or the wrong zone')
                  :format(#bare), table.concat(bare, ' '))
        end
        if sample == "Ru'Lude Gardens  G-8" then
            ok_('location: zone and cell together, in that order', sample)
        else
            fail_('location: step 3 line', tostring(sample))
        end
    end

    --[[ And `travel` still drops to the grid alone.

         A different rule, and it must not be swept up with the one above: those
         steps consume the destination into the sentence, so naming it again
         immediately below would say it twice on one step.

         "The Requiem" step 4 is a travel step with no npc, a zone and a grid,
         checked on the render and not by counting how many exist in the index, which
         is what this assertion did at first and which passes whatever the code does.
         Removing the suppression leaves it green; that is how it was found. ]]
    do
        local ent = select_key('quest/jeuno/64')
        if not ent then
            fail_('location: The Requiem is in the list')
        else
            local loc, cur, title = {}, nil, nil
            for _, d in ipairs(panel.S.dlines or {}) do
                if d.step then cur = d.step end
                if d.step == 4 and d.b then title = title or d.b end
                if cur and d.b and d.size == theme.fs_zone and not d.needs
                   and not d.source and d.x == theme.d_title then
                    loc[cur] = loc[cur] or d.b
                end
            end
            local zone = model.zone_name(ent.steps[4].z)
            local ok_title = title and title:find(zone, 1, true) ~= nil
            local ok_loc = loc[4] == ent.steps[4].g
            if ok_title and ok_loc then
                ok_('location: travel names its destination once, in the sentence',
                    ('"%s" over "%s"'):format(title, tostring(loc[4])))
            else
                fail_('location: travel step says the zone twice, or not at all',
                      ('title="%s" below="%s" zone="%s"')
                      :format(tostring(title), tostring(loc[4]), zone))
            end
        end
    end

    --[[ A capped drop list says how many it left out.

         "Wings of Gold" step 2 lists thirteen gigas. Capped at five, and the
         shortfall stated, which is the rule the requirement ledger follows too:
         a list silently cut short claims a completeness it does not have. Without
         this quest in the fixture, removing the cap changes nothing any assertion
         can see. ]]
    do
        local ent = select_key('quest/jeuno/60')
        if not ent then
            fail_('source: Wings of Gold is in the list')
        else
            local src, cur = nil, nil
            for _, d in ipairs(panel.S.dlines or {}) do
                if d.step then cur = d.step end
                if cur == 2 and d.source and d.b then src = (src or '') .. ' ' .. d.b end
            end
            local n = 0
            for _ in tostring(src):gmatch(',') do n = n + 1 end
            if src and src:find('and 8 more', 1, true) and n == 4 then
                ok_('source: a capped drop list counts what it omitted',
                    (src:gsub('^%s+', '')))
            else
                fail_('source: cap on a 13-mob drop list', tostring(src))
            end
        end
    end

    --[[ The title clears the chevron column.

         Every drawn title line of every quest in the list, measured against the left
         edge of the chevron rather than against the pane edge. Continuation lines
         count: they are wrapped to the same width and the reported collision was on
         a first line, but a later one is the same fault.

         Only steps that have a chevron reserve the column. A step with no note
         draws none and its title is allowed the full width, so asserting the reserve
         on those would fail for a line that collides with nothing. ]]
    do
        local limit = theme.d_tag_r - panel.chev_width()
        local over, checked, widest, worst = 0, 0, 0, nil
        for _, l in ipairs(panel.S.lines) do
            if l.kind == 'row' then
                select_key(l.row.key)
                local expandable = false
                for _, d in ipairs(panel.S.dlines or {}) do
                    if d.step then expandable = d.expandable and true or false end
                    if d.b and d.size == theme.fs_step and expandable then
                        checked = checked + 1
                        local right = d.x + theme.width(d.b, theme.fs_step)
                        if right > widest then widest, worst = right, d.b end
                        if right > limit then over = over + 1 end
                    end
                end
            end
        end
        if checked == 0 then
            fail_('title: expandable steps were drawn to measure',
                  '0 -- this test checked nothing')
        elseif over == 0 then
            ok_('title: never runs into the chevron column',
                ('%d lines, widest edge %dpx of %dpx'):format(checked, widest, limit))
        else
            fail_(('title: %d line(s) run under the chevron'):format(over),
                  ('%s -- ends at %dpx, chevron starts at %dpx')
                  :format(tostring(worst), widest, limit))
        end
    end

    --[[ Drop mobs are never in a title, on any kind.

         Folded into the `obtain` sentence alone, `fight` and `trade` show them
         nowhere, which is 89 and 31 steps, so this also asserts they reach the
         screen. Swept over the accepted list through the real render path. ]]
    do
        local in_title, on_line, checked = 0, 0, 0
        for _, l in ipairs(panel.S.lines) do
            if l.kind == 'row' then
                local ent = select_key(l.row.key)
                local lad = panel.S.ladder
                for _, rr in ipairs(lad and lad.rows or {}) do
                    local raw = ent.steps and ent.steps[rr.n]
                    local drops = {}
                    for _, m in ipairs((raw and raw.mobs) or {}) do
                        if (m.role or 'kill') == 'drop' and m.name then
                            drops[#drops + 1] = model.nice_name(m.name)
                        end
                    end
                    if #drops > 0 then
                        checked = checked + 1
                        local title, src, cur = nil, nil, nil
                        for _, d in ipairs(panel.S.dlines or {}) do
                            if d.step then cur = d.step end
                            if cur == rr.n and d.b then
                                if d.step then title = d.b end
                                if d.source then src = (src or '') .. ' ' .. d.b end
                            end
                        end
                        if title and title:find(drops[1], 1, true) then
                            in_title = in_title + 1
                        end
                        if src and src:find(drops[1], 1, true) then
                            on_line = on_line + 1
                        end
                    end
                end
            end
        end
        if checked == 0 then
            fail_('source: steps with drop mobs were found',
                  '0 -- this test checked nothing')
        elseif in_title == 0 and on_line == checked then
            ok_('source: drop mobs are on their own line, never in the title',
                ('%d steps with drop mobs, all %d named on a source line')
                :format(checked, on_line))
        else
            fail_('source: drop mob placement',
                  ('%d in a title, %d of %d on a source line')
                  :format(in_title, on_line, checked))
        end
    end
end

-- ---------------------------------------------------------------------------
-- The spec's list and data layer
-- ---------------------------------------------------------------------------

print('')
print('=== spec: data layer ===')
do
    -- Select a quest with a ladder, so the note assertions below have one to
    -- read. This block asserts nothing itself.
    local lad = nil
    for _, l in ipairs(panel.S.lines) do
        if l.kind == 'row' and l.row.key == 'quest/windurst/20' then
            lad = model.ladder(l.row.entry) break
        end
    end
    if lad then
        panel.S.sel = nil
        pcall(cmd, 'pick', '1')
    end

    --[[ Note tidying. ` -- ` used as an em dash appears in 1338 of the 6459 notes
         and reads as a diff on screen; a preamble that restates the `optional` flag
         says nothing the same line has not already said. ]]
    local t = model.notes_for({cat = 'quest', area = 'windurst', id = 20})
    if t then
        local bad = 0
        for _, v in pairs(t) do if v:find(' %-%- ') then bad = bad + 1 end end
        if bad == 0 then ok_('notes: no " -- " survives tidying')
        else fail_('notes: em-dash stripped', bad .. ' remain') end

        local n4 = t[4]
        if n4 and not n4:lower():find('^the page marks this optional') then
            ok_('notes: the flag-restating preamble is stripped', n4)
        elseif n4 then
            fail_('notes: preamble stripped', n4)
        end
        local anylower = false
        for _, v in pairs(t) do if v:match('^%l') then anylower = true end end
        if not anylower then ok_('notes: each reads as a sentence') end
    end

    --[[ Title-casing must be idempotent: a string that already carries an
         uppercase letter is left alone, so a display string that goes through
         twice is not mangled. ]]
    local once = model.nice_name('kohlo-lakolo')
    if once == 'Kohlo-Lakolo' and model.nice_name(once) == once then
        ok_('names: title-casing is idempotent', once)
    else
        fail_('names: idempotent', once .. ' / ' .. model.nice_name(once))
    end
    if model.nice_name("svenja's manor") == "Svenja's Manor" then
        ok_('names: no capital after an apostrophe')
    else
        fail_('names: apostrophe', model.nice_name("svenja's manor"))
    end
    if model.zone_name(89) == 'Grauberg [S]' then
        ok_('zones: name is intact through the display layer', 'Grauberg [S]')
    else
        fail_('zones: Grauberg', tostring(model.zone_name(89)))
    end
end

print('')
print('=== spec: the Here filter ===')
do
    --[[ `Here` must HIDE, not reorder, and must degrade to an empty list with an
         explanation rather than to the full list when the zone is unknown. ]]
    local zone = model.current_zone()
    local all = select(2, model.groups(model.SETS.accepted))
    local here = select(2, model.groups(model.SETS.here))
    if here <= all then
        ok_('here: filters rather than reorders',
            ('zone %s, %d of %d'):format(tostring(zone), here, all))
    else
        fail_('here: filters', ('%d > %d'):format(here, all))
    end
    for _, c in ipairs({{'here'}, {'accepted'}}) do run(unpack(c)) end
end

-- ---------------------------------------------------------------------------
-- Degradation
-- ---------------------------------------------------------------------------

--[[ The requirement is that a missing or unexpected questmarks never throws. Each
     case re-attaches, checks the status code, and then renders, because "attach
     returned false" is only half of it: the panel still has to draw something honest
     instead of an empty list that reads as "you have no quests". ]]
print('\n=== degradation ===')

local DEGRADE = {
    {'',                              'no_addon',  'empty path'},
    {'C:/nope/not/here/',             'no_addon',  'questmarks not installed'},
    {W .. 'addons/chronicle/',        'no_addon',  'a path to the wrong addon'},
    {W .. 'addons/',                  'no_addon',  'the addons folder itself'},
}

for _, c in ipairs(DEGRADE) do
    local oka, e = pcall(model.attach, c[1])
    if not oka then
        fail_('attach: ' .. c[3], e)
    elseif model.status ~= c[2] then
        fail_('attach: ' .. c[3],
              ('expected %s, got %s'):format(c[2], model.status))
    else
        panel.invalidate()
        local okg, ge = pcall(cmd, 'list')
        local okr2, re = pcall(prerender)
        if okg and okr2 then
            ok_('degrades: ' .. c[3], model.status)
        else
            fail_('degrades: ' .. c[3], ge or re)
        end
    end
end

-- A path that exists and has core/quests.lua but no index.
local FIX = A .. 'tools/fixtures/'
pcall(model.attach, FIX .. 'no_index/')
if model.status == 'no_index' then
    ok_('degrades: core/ present but no quest index', model.detail)
else
    fail_('degrades: core/ present but no quest index', model.status)
end

--[[ Feature detection. The fixture's core/quests.lua loads cleanly and simply has
     no `todo`, which is what a renamed entry point in a future questmarks looks
     like. The failure has to name the missing function at attach time. ]]
pcall(model.attach, FIX .. 'incompatible/')
if model.status == 'incompatible' and (model.detail or ''):find('todo') then
    ok_('degrades: a questmarks missing an entry point', model.detail)
else
    fail_('degrades: a questmarks missing an entry point',
          model.status .. ' / ' .. tostring(model.detail))
end

--[[ Re-attach across paths. The fixture above was loaded through `require`, which
     memoises, so coming back to the real questmarks has to evict it. With the cache
     left alone this reports 'incompatible', or worse, reports ok while running the
     fixture's stub modules. ]]
pcall(model.attach, W .. 'addons/questmarks/')
if model.status == 'ok' and (model.meta or {}).indexed
   and model.meta.indexed > 1000 then
    ok_('re-attach evicts the previous install',
        ('back to %d entries'):format(model.meta.indexed))
else
    fail_('re-attach evicts the previous install',
          model.status .. ' / ' .. tostring((model.meta or {}).indexed))
end
-- ...and back off again, so the checks below run detached as intended.
pcall(model.attach, 'C:/nope/not/here/')

--[[ groups() and ladder() have to be safe to call while detached, because they are
     called on every frame between the failure and the player noticing. ]]
local g1, n1 = model.groups(model.SETS.accepted)
if type(g1) == 'table' and #g1 == 0 and n1 == 0 then
    ok_('groups() returns empty while detached')
else
    fail_('groups() while detached', tostring(#g1))
end
if model.ladder({cat = 'quest', area = 'x', id = 1}) == nil then
    ok_('ladder() returns nil while detached')
else
    fail_('ladder() while detached')
end
if model.ladder(nil) == nil then ok_('ladder(nil) is safe') end
if model.zone_name(238) == 'Windurst Waters' then
    ok_('zone_name reads res/zones.lua', 'Windurst Waters')
else
    fail_('zone_name', tostring(model.zone_name(238)))
end
if model.zone_name(99999):find('zone ') then
    ok_('zone_name degrades on an unknown id', model.zone_name(99999))
end

-- Re-attach for the lifecycle checks below.
pcall(model.attach, W .. 'addons/questmarks/')

-- ---------------------------------------------------------------------------
-- Login / logout / unload
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- The dialect check covers every module the addon loads
-- ---------------------------------------------------------------------------

--[[ tools/check_dialect.lua carries a hand-written list of files, and a hand-written
     list is only ever as current as the last person to remember it. A module missing
     from it is a module a Lua 5.2 construct can hide in, and the failure mode is the
     addon not loading at all, found in game, in a chat window you cannot copy out.

     Checked against `package.loaded` rather than against a second list, because the
     modules the addon really loads is the only definition of the set that matters.
     Anything under the addon root and not in the dialect list is a gap. ]]
print('')
print('=== every module the addon loads is dialect-checked ===')
do
    local listed = {}
    for _, f in ipairs(dialect_files or {}) do
        listed[(f:gsub('\\', '/'))] = true
    end
    local missing, checked = {}, 0
    for name, mod in pairs(package.loaded) do
        if type(name) == 'string' and mod ~= nil then
            --[[ Module names are require paths, 'ui/panel' or 'resnames', so the file
                 is the name plus .lua. Only ours: a leading 'tools/' is the harness's
                 own, and everything else is Windower's or the stubs'. ]]
            local rel = name:gsub('%.', '/') .. '.lua'
            local f = real_open(A .. rel, 'rb')
            if f then
                f:close()
                if not name:match('^tools/') then
                    checked = checked + 1
                    if not listed[rel] then missing[#missing + 1] = rel end
                end
            end
        end
    end
    table.sort(missing)
    if checked == 0 then
        fail_('dialect coverage: modules were found to check',
              '0 -- this test checked nothing')
    elseif #missing == 0 then
        ok_('dialect: every loaded module is on the check list',
            ('%d modules, %d files listed'):format(checked, #(dialect_files or {})))
    else
        fail_(('dialect: %d loaded module(s) are NOT checked'):format(#missing),
              table.concat(missing, ' '))
    end
end

print('\n=== lifecycle ===')
for _, ev in ipairs({'zone change', 'job change', 'login'}) do
    local h = events[ev] and events[ev][1]
    if h then
        local okh, e = pcall(h, 1)
        if okh then ok_(ev .. ' handler runs') else fail_(ev .. ' handler', e) end
    end
end

local logout = events['logout'] and events['logout'][1]
if logout then
    local okh, e = pcall(logout)
    if okh then ok_('logout handler runs') else fail_('logout handler', e) end
end

--[[ The check that matters most. A named prim left behind stays on screen until
     Windower is restarted, and Lua cannot enumerate it afterwards to clean up. ]]
local live_before = draw.count()
local unload = events['unload'] and events['unload'][1]
if not unload then fail_('unload handler registered') else
    local okh, e = pcall(unload)
    if not okh then fail_('unload handler', e) end
end

local leaked = 0
for name in pairs(objs) do leaked = leaked + 1 end
if leaked == 0 then
    ok_('unload leaves ZERO objects behind',
        ('%d were live'):format(live_before))
else
    fail_('unload leaked objects', ('%d still on screen'):format(leaked))
    for name in pairs(objs) do print('        orphan: ' .. name) end
end
if draw.count() ~= 0 then
    fail_('draw registry emptied', draw.count() .. ' still recorded')
else
    ok_('draw registry emptied')
end

print('')
if failures == 0 then
    print('smoke run clean -- 0 failure(s)')
else
    print(('SMOKE RUN FAILED -- %d failure(s)'):format(failures))
    os.exit(1)
end
