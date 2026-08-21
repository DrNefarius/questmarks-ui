--[[
model.lua -- reaching questmarks' data, and grouping it into regions.

How the data is reached, and why this way.

questmarks ships with no runtime dependency on any other addon, and its
tools/test_standalone.lua enforces it: no shipped file may hold a string literal
naming another addon's path, and the test scans the shipped set for `addons/`
and `../`. That rule does not bind this addon, but the smell it exists to catch
is real, so the dependency here is declared rather than hidden:

  * The path is a setting (`questmarks_path`), so a non-standard install is a
    config change and not a patch.
  * Its default is built from `windower.windower_path`, which is Windower's own
    root and the same handle questmarks uses to reach res/. It is not a `../`
    hop out of this addon's own directory.
  * Nothing is assumed. The path is probed with io.open before anything is
    required, every require is a pcall, and every entry point is feature-detected
    by type before it is called.

What is required, and what that costs. Three of questmarks' own modules,
core/quests, core/steps and render/markers, plus whatever they pull in. The full
graph is core/{quests,state,prereq,fame,inventory,steps,skills,keyitems},
data/fame_dialogue and LuaJIT's `bit`. Checked by reading every `require` in
core/ and render/: none of them requires a Windower library. That is what makes
this affordable, because the model layer is portable Lua over plain data.

  This does not read questmarks' live state. Addons do not share Lua globals:
  chronicle, questmarks and Balloon each assign a different value to
  `_addon.name` and all three coexist, which they could not do in one shared
  global table. There is no addon-to-addon API either. So what this does is run
  its own copy of the same state machine over the same packets.

  That is a real cost, because 0x056 is decoded twice when both addons are
  loaded, and it is the price of not modifying questmarks. It is small: the
  decode is a bitfield copy, on a packet that arrives on zone-in and on quest
  events, not per frame. The alternative would be an IPC channel, which is a
  change to questmarks and therefore out of bounds here.

Failure modes, all of which degrade rather than throw:

  questmarks absent          -> status 'no_addon'; the panel says so and offers
                                nothing. No require is attempted.
  index missing or malformed -> status 'no_index' with quests.load's own error.
  a core module errors       -> status 'load_failed' with the pcall message.
  a newer/older questmarks   -> status 'incompatible', naming the entry point
                                that is missing. Feature detection is by
                                `type(f) == 'function'` on each of the five
                                functions actually called, so a rename fails
                                loudly at load instead of silently at draw.
  index present, no packets  -> status 'ok' but `state.is_loaded()` false; the
                                panel says "waiting for the game" rather than
                                showing an empty list that looks like "you have
                                no quests".

Scope: accepted only, and that is a correctness boundary rather than a
preference. `prereq.marker_state` reaches `prereq.evaluate`, which is the fame,
level and job gate path, only for a completed repeatable and for the
linear-mission sanity check. Its `in_progress` branch goes straight to
`steps.current` and never consults fame. questmarks persists fame observations
per character in its own settings, which this addon cannot read. So on the
accepted set this addon's answers are identical to questmarks' own, and on the
available set they would silently differ. Accepted-only is the scope where the
missing state costs nothing.
]]

local model = {}

local theme = require('ui/theme')
local notes = require('notes')

-- ---------------------------------------------------------------------------
-- Region names
-- ---------------------------------------------------------------------------

--[[ The game's own quest-log sections, not names invented here.

     Packet 0x056 carries one `current` bitfield per area, 0x0050 San d'Oria,
     0x0058 Bastok, 0x0060 Windurst, 0x0068 Jeuno and so on, which questmarks'
     core/state.lua tabulates. The field labels for the multi-field sub-types are
     spelled out in the packet definition itself: 'Current TOAU Quests',
     "Completed San d'Oria Missions", 'Completed Zilart Missions', taken from
     Windower's own addons/libs/packets/fields.lua. The strings below are those
     section names in their natural reading order. This is the whole grouping
     argument in one table: the region structure is not a modelling choice, it is
     what the client already sends. ]]
local REGION = {
    ['quest/sandoria']    = {name = "San d'Oria",              ord = 10},
    ['quest/bastok']      = {name = 'Bastok',                  ord = 11},
    ['quest/windurst']    = {name = 'Windurst',                ord = 12},
    ['quest/jeuno']       = {name = 'Jeuno',                   ord = 13},
    ['quest/outlands']    = {name = 'Outlands',                ord = 14},
    ['quest/other']       = {name = 'Other Areas',             ord = 15},
    ['quest/toau']        = {name = 'Aht Urhgan',              ord = 16},
    ['quest/crystal_war'] = {name = 'Crystal War',             ord = 17},
    ['quest/abyssea']     = {name = 'Abyssea',                 ord = 18},
    ['quest/adoulin']     = {name = 'Adoulin',                 ord = 19},
    ['quest/coalition']   = {name = 'Coalition',               ord = 20},
    ['quest/acp']         = {name = 'A Crystalline Prophecy',  ord = 21},
    ['quest/mkd']         = {name = "A Moogle Kupo d'Etat",    ord = 22},
    ['quest/asa']         = {name = 'A Shantotto Ascension',   ord = 23},

    ['mission/sandoria']  = {name = "San d'Oria Missions",     ord = 1},
    ['mission/bastok']    = {name = 'Bastok Missions',         ord = 2},
    ['mission/windurst']  = {name = 'Windurst Missions',       ord = 3},
    ['mission/nation']    = {name = 'Nation Missions',         ord = 4},
    ['mission/zilart']    = {name = 'Rise of the Zilart',      ord = 5},
    ['mission/cop']       = {name = 'Chains of Promathia',     ord = 6},
    ['mission/toau']      = {name = 'Treasures of Aht Urhgan', ord = 7},
    ['mission/wotg']      = {name = 'Wings of the Goddess',    ord = 8},
    ['mission/campaign']  = {name = 'Campaign',                ord = 8.1},
    ['mission/campaign_2']= {name = 'Campaign',                ord = 8.2},
    ['mission/assault']   = {name = 'Assault',                 ord = 8.3},
    ['mission/acp']       = {name = 'A Crystalline Prophecy',  ord = 8.4},
    ['mission/mkd']       = {name = "A Moogle Kupo d'Etat",    ord = 8.5},
    ['mission/asa']       = {name = 'A Shantotto Ascension',   ord = 8.6},
    ['mission/adoulin']   = {name = 'Seekers of Adoulin',      ord = 8.7},
    ['mission/rov']       = {name = "Rhapsodies of Vana'diel", ord = 8.8},
    ['mission/tvr']       = {name = 'The Voracious Resurgence', ord = 8.9},
}

-- ---------------------------------------------------------------------------
-- Display names
-- ---------------------------------------------------------------------------

--[[ The index stores folded lookup keys, not display names.

     Every NPC and monster name in the index is lowercased, because `quests.fold`
     is applied on the way in: the whole point of those strings is to match
     against `get_mob_list()` case-insensitively. Measured over the shipped
     index, 2309 distinct step npc and mob names, and not one contains an
     uppercase letter.

     Quest titles are unaffected. They come from data/dat_names.lua, which is the
     client's own text and properly cased. That asymmetry is what makes a panel
     read as a database dump: real titles above rows of "orn, windurst waters"
     and "furakku-norakku".

     There is no unfolded copy to recover, so display case has to be
     reconstructed. The rule is capitalise at a word start, where a word starts
     at the beginning or after a space, a hyphen or a colon:

       * Hyphen matters most. Tarutaru names are hyphenated compounds and the
         game capitalises both halves: Kohlo-Lakolo, Furakku-Norakku,
         Hariga-Origa. Splitting on space alone gets every one of them wrong.
       * Apostrophe must not capitalise. 70 index names carry one, and treating
         it as a separator turns "svenja's manor" into "Svenja'S Manor".
       * Colon is the `door:` prefix on the 20 synthetic door targets.

     This is a heuristic and it is allowed to be, because it only ever touches
     what is drawn. Nothing downstream matches on it: the marker path, the step
     lookup and the note index all keep using the folded key. A wrong
     capitalisation is a cosmetic blemish, never a missing marker. ]]
--[[ Names the rule gets wrong, and the place to add more.

     Title-casing every word is right for Tarutaru compounds and Mithra names,
     and wrong for the handful of names carrying an internal particle or an
     abbreviation. This table is the escape hatch, keyed by the FOLDED form, so
     a correction is one line and needs no change to the rule. ]]
local NAME_FIX = {
    ['prof. schultz']  = 'Prof. Schultz',
    ['lamia no.27']    = 'Lamia No.27',
    ['mammet-800']     = 'Mammet-800',
}

local function nice_name(s)
    if type(s) ~= 'string' or s == '' then return s end
    local fixed = NAME_FIX[s]
    if fixed then return fixed end

    --[[ A string that already carries an uppercase letter is left alone. The
         index is folded, but a caller may hand this a display string that has
         been through here once, or a zone name straight out of res/zones.lua,
         and re-casing "Grauberg [S]" or "San d'Oria" can only damage it. ]]
    if s:match('%u') then return s end

    --[[ The apostrophe is inside the word class, not a separator. Listing it as
         a separator splits "svenja's" into "svenja" + "s" and capitalises both,
         giving "Svenja'S Manor". Only space, hyphen and colon break a word. ]]
    local out = s:gsub('([^%s%-:]+)', function(word)
        return word:sub(1, 1):upper() .. word:sub(2)
    end)
    return out
end
model.nice_name = nice_name

--[[ Missions before quests, matching the order `quests.todo` already sorts in
     and for the reason its own comment gives, that they are the storyline rather
     than a side errand. An unknown area sorts last under its own raw key rather
     than being dropped: new content has to appear somewhere. ]]
local function region_of(entry)
    local key = (entry.cat or '?') .. '/' .. (entry.area or '?')
    local r = REGION[key]
    if r then return key, r.name, r.ord end
    return key, key, 900
end
model.region_of = region_of

-- ---------------------------------------------------------------------------
-- Attaching to questmarks
-- ---------------------------------------------------------------------------

model.status = 'detached'
model.detail = nil
model.meta = nil

local quests, steps, markers, state, prereq, inventory
local zones = nil

local function readable(path)
    local f = io.open(path, 'r')
    if not f then return false end
    f:close()
    return true
end

--[[ res/zones.lua, read exactly the way questmarks reads it and for the same
     reason: it is Windower's own directory, and `loadfile` on a plain data file
     avoids `require('resources')`, which monkeypatches the base string and table
     metatables for the sake of a lookup table. The argument is questmarks' own,
     in its `NOTICE`. A missing file degrades to "zone 245", never to an
     error. ]]
local function load_zones()
    if zones ~= nil then return zones end
    zones = false
    local ok, chunk = pcall(loadfile,
        (windower.windower_path or '') .. 'res/zones.lua')
    if ok and chunk then
        local ok2, t = pcall(chunk)
        if ok2 and type(t) == 'table' then zones = t end
    end
    return zones
end

function model.zone_name(id)
    if type(id) ~= 'number' then return nil end
    local z = load_zones()
    local e = z and z[id]
    local n = e and (e.en or e.english or e.name)
    return n or ('zone ' .. id)
end

local function fail(status, detail)
    model.status, model.detail = status, detail
    return false
end

--[[ -> true, or false with model.status / model.detail set. Never throws. ]]
function model.attach(path)
    quests, steps, markers, state, prereq, inventory = nil, nil, nil, nil, nil, nil
    model.meta = nil

    if type(path) ~= 'string' or path == '' then
        return fail('no_addon', 'no questmarks path configured')
    end
    if path:sub(-1) ~= '/' and path:sub(-1) ~= '\\' then path = path .. '/' end

    local index_path = path .. 'data/quest_index.lua'
    if not readable(path .. 'core/quests.lua') then
        return fail('no_addon', 'questmarks not found at ' .. path)
    end
    if not readable(index_path) then
        return fail('no_index', 'no data/quest_index.lua under ' .. path)
    end

    --[[ Re-attaching to a different path is the case this has to get right, and
         the naive version gets it silently wrong twice over.

         `require` memoises in package.loaded, so a second attach to a new path
         hands back the modules loaded from the old one and the addon reports
         success while running the previous install's code. package.path
         accumulates as well, so the stale directory stays on it and wins the
         search anyway, because require takes the first match.

         So: drop the previous entry from package.path, and evict every module
         this addon may have caused to load. The eviction list is questmarks'
         whole require graph, read off every `require` in its core/ and render/
         rather than guessed at, because a module left in the cache is a module
         still running.

         tools/smoke.lua re-attaches to four different paths in a row, which is
         the test that catches this. ]]
    local MODULES = {
        'core/quests', 'core/steps', 'core/state', 'core/prereq',
        'core/fame', 'core/inventory', 'core/keyitems', 'core/skills',
        'core/kills', 'core/notify', 'data/fame_dialogue',
        'render/markers', 'render/project',
    }
    local function evict()
        for _, n in ipairs(MODULES) do package.loaded[n] = nil end
    end

    if model._path_entry then
        package.path = package.path:gsub(
            model._path_entry:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1'), '')
    end
    evict()

    local entry = ';' .. path .. '?.lua'
    model._path_entry = entry
    package.path = package.path .. entry

    local function grab(name)
        local ok, m = pcall(require, name)
        if not ok or type(m) ~= 'table' then
            return nil, tostring(m)
        end
        return m
    end

    local err
    quests, err = grab('core/quests')
    if not quests then return fail('load_failed', 'core/quests: ' .. tostring(err)) end
    steps, err = grab('core/steps')
    if not steps then return fail('load_failed', 'core/steps: ' .. tostring(err)) end
    state, err = grab('core/state')
    if not state then return fail('load_failed', 'core/state: ' .. tostring(err)) end
    prereq, err = grab('core/prereq')
    if not prereq then return fail('load_failed', 'core/prereq: ' .. tostring(err)) end
    inventory, err = grab('core/inventory')
    if not inventory then return fail('load_failed', 'core/inventory: ' .. tostring(err)) end

    --[[ Feature detection by type, on exactly the functions this addon calls.
         A questmarks that renames one of these fails here, at load, naming it,
         rather than at draw time inside a pcall that would look like an empty
         quest log. ]]
    local need = {
        {quests, 'todo'}, {quests, 'load'}, {quests, 'where_of'},
        {quests, 'name_of'}, {steps, 'explain'}, {state, 'handle_packet'},
        {state, 'status_of'}, {state, 'is_loaded'}, {state, 'reset'},
        {prereq, 'set_player'}, {inventory, 'refresh'}, {inventory, 'invalidate'},
        {inventory, 'reset'},
    }
    for _, n in ipairs(need) do
        if type(n[1][n[2]]) ~= 'function' then
            return fail('incompatible', 'questmarks is missing ' .. n[2] .. '()')
        end
    end

    --[[ markers is optional and is the colour source only. Losing it costs the
         marker palette and nothing else: theme.state_style falls back to a
         deliberately plain grey rather than pretending. Requiring it is inert,
         because its only top-level work is `require('render/project')` and
         neither file touches `windower` outside a function body. ]]
    markers = grab('render/markers')
    if markers and type(markers.style_for) == 'function' then
        theme.style_for = markers.style_for
    else
        theme.style_for = nil
    end

    local ok, meta = pcall(quests.load, index_path)
    if not ok then
        return fail('no_index', 'quest_index.lua failed to load: ' .. tostring(meta))
    end
    if not meta then
        return fail('no_index', 'quest_index.lua is malformed')
    end

    --[[ Optional and independent of everything above: with no build/authored/
         under the questmarks path, notes are simply absent. Nothing else
         changes. ]]
    pcall(notes.attach, path)

    model.meta = meta
    model.status = 'ok'
    model.detail = nil
    return true
end

--[[ -> {[step index] = note} or nil. Optional enrichment; see notes.lua for the
     licence reading that keeps this a read of the player's own disk rather than
     something this addon redistributes. ]]
function model.notes_for(entry)
    if model.status ~= 'ok' or type(entry) ~= 'table' then return nil end
    local ok, t = pcall(notes.for_quest, entry.cat, entry.area, entry.id)
    if not ok then return nil end
    return t
end

function model.notes_available()
    local ok, v = pcall(notes.available)
    return ok and v and true or false
end

function model.notes_stats()
    local ok, s = pcall(notes.stats)
    return ok and s or {}
end

--[[ Which vocabulary list the note filter is using. Surfaced so //qmui diag
     can say whether it is questmarks' shared file or the bundled subset: a
     silently degraded filter is one nobody notices. ]]
function model.notes_voice_source()
    local ok, v = pcall(notes.voice_source)
    return (ok and v) or 'unknown'
end

--[[ -> the quest's own in-game description, or nil. Same read-in-place rule as
     the notes; see notes.lua for why that distinction carries the licence. ]]
function model.description_for(entry)
    if model.status ~= 'ok' or type(entry) ~= 'table' then return nil end
    local ok, s = pcall(notes.description_for, entry.cat, entry.area, entry.id)
    if not ok then return nil end
    return s
end

function model.desc_stats()
    local ok, s = pcall(notes.desc_stats)
    return ok and s or {}
end

--[[ Has the game told us anything yet? 'ok' means the index loaded; this means
     0x056 has arrived. The panel has to distinguish them, because an empty list
     from the second looks exactly like "you have no quests". ]]
function model.state_ready()
    if model.status ~= 'ok' then return false end
    local ok, v = pcall(state.is_loaded)
    return ok and v and true or false
end

-- ---------------------------------------------------------------------------
-- Feeding the model
-- ---------------------------------------------------------------------------

function model.handle_state_packet(p)
    if model.status ~= 'ok' then return false end
    local ok, changed = pcall(state.handle_packet, p)
    return ok and changed and true or false
end

function model.invalidate_items()
    if model.status ~= 'ok' then return end
    pcall(inventory.invalidate)
end

function model.invalidate_key_items()
    if model.status ~= 'ok' then return end
    pcall(inventory.invalidate_key_items)
end

function model.refresh_inventory(force)
    if model.status ~= 'ok' then return false end
    local ok, changed = pcall(inventory.refresh, force)
    return ok and changed and true or false
end

function model.refresh_player()
    if model.status ~= 'ok' then return end
    local ok, p = pcall(windower.ffxi.get_player)
    if not ok or not p then
        pcall(prereq.set_player, nil, nil)
        return
    end
    pcall(prereq.set_player, p.main_job, p.main_job_level)
end

--[[ Login, logout and character switch. Mirrors what questmarks does on the
     same events, in `steps.reset`: every inference is dropped, because it
     describes a character's session and means nothing for the next one. This
     addon holds no observations to keep, because it never reads fame, so there
     is nothing on the other side of that line. ]]
function model.reset()
    if model.status ~= 'ok' then return end
    pcall(state.reset)
    pcall(inventory.reset)
    if steps and type(steps.reset) == 'function' then pcall(steps.reset) end
end

function model.on_state_change()
    if model.status ~= 'ok' then return end
    if steps and type(steps.on_state_change) == 'function' then
        pcall(steps.on_state_change)
    end
end

-- ---------------------------------------------------------------------------
-- The list
-- ---------------------------------------------------------------------------

--[[ Accepted is turnin plus progress, which is exactly the set `//qm todo`
     defaults to and for the reason its own header gives: it is the size of your
     quest log, while `ready` alone is hundreds of entries nobody reads. ]]
model.SETS = {
    accepted = {turnin = true, progress = true},
    handin   = {turnin = true},
    here     = {turnin = true, progress = true},
}

--[[ The zone you are standing in, for the `Here` filter.

     This is the only extra data dependency the design takes, and it is the
     cheapest one available: `get_info().zone` is the same call questmarks makes,
     and it needs no packet handling. Guarded, because get_info returns nothing
     while zoning and the filter has to degrade to "unknown" rather than to
     "nothing matches". ]]
function model.current_zone()
    local ok, info = pcall(function() return windower.ffxi.get_info() end)
    if not ok or type(info) ~= 'table' then return nil end
    return info.zone
end

--[[ Is this quest asking you to be where you are?

     Answered against `where.zone`, which is the step the marker is on, and also
     against `where.at_zone`, which is set when the marker is held back and the
     real work is somewhere else. A quest whose work is here counts as here even
     when its marker is not, which is the whole point of at_zone existing. ]]
local function row_is_here(r, zone)
    if not zone then return false end
    local w = r.where
    if not w then return false end
    return w.zone == zone or w.at_zone == zone
end
model.row_is_here = row_is_here

--[[ -> array of groups, each {key, name, ord, rows = {...}, counts = {}}
     Row shape is quests.todo's own row, {key, entry, state, status, name,
     where}, with nothing added, so there is one description of it and it lives
     in core/quests.lua.

     Returns an empty array rather than nil on any failure. A quest log that
     cannot be built is an empty quest log with a status line above it, never a
     traceback. ]]
function model.groups(set, filter_text)
    if model.status ~= 'ok' then return {}, 0 end

    local ok, rows = pcall(quests.todo, set or model.SETS.accepted)
    if not ok or type(rows) ~= 'table' then return {}, 0 end

    --[[ `Here` hides, it does not reorder. A filter that merely floats things
         leaves you reading the same nineteen rows wondering which are which;
         one that hides answers the question outright. ]]
    if set == model.SETS.here then
        local zone = model.current_zone()
        local keep = {}
        for _, r in ipairs(rows) do
            if row_is_here(r, zone) then keep[#keep + 1] = r end
        end
        rows = keep
    end

    if filter_text and filter_text ~= '' then
        local pat = filter_text:lower()
        local keep = {}
        for _, r in ipairs(rows) do
            local n = (r.name or r.key or ''):lower()
            local _, rn = region_of(r.entry)
            if n:find(pat, 1, true) or rn:lower():find(pat, 1, true) then
                keep[#keep + 1] = r
            end
        end
        rows = keep
    end

    --[[ The candidate band, per row, for the list's progress bar.

         `where_of` gives the current step and the total; it does not say how far
         ahead the tracker stops being able to tell. That band is what the bar's
         ghost segment draws, and it is the honest half of the quest's progress.

         Computed here rather than by calling steps.explain per row: explain
         walks every step's evidence through the inventory, and this needs only
         "where is the next step carrying any evidence at all", which is a scan
         of the steps array and no inventory work. On a 19-quest log that is the
         difference between a rebuild you can do on every 0x056 and one you
         cannot. ]]
    local function fog_end_of(e, from)
        local st = e and e.steps
        if not st or not from then return from end
        for n = from, #st do
            local s = st[n]
            local a, b = s.ev, s.ev_alt
            if (type(a) == 'table' and #a > 0) or (type(b) == 'table' and #b > 0) then
                return n
            end
        end
        return #st
    end

    local by, order = {}, {}
    for _, r in ipairs(rows) do
        local w = r.where
        if w and w.step then w.fog_end = fog_end_of(r.entry, w.step) end
        local key, name, ord = region_of(r.entry)
        local g = by[key]
        if not g then
            g = {key = key, name = name, ord = ord, rows = {}, counts = {}}
            by[key] = g
            order[#order + 1] = g
        end
        g.rows[#g.rows + 1] = r
        g.counts[r.state] = (g.counts[r.state] or 0) + 1
    end

    --[[ Regions in the client's own log order, not by how many quests each
         holds. A list whose headers move as you accept and finish things cannot
         be learned, and being learnable is most of what a grouped list is for. ]]
    table.sort(order, function(a, b)
        if a.ord ~= b.ord then return a.ord < b.ord end
        return a.name < b.name
    end)

    --[[ Sort within each region: ready to hand in, then in progress, then
         unverifiable, then blocked; alphabetical inside each band.

         Position does the work a colour code would otherwise do. quests.todo
         already sorts globally by the same priority, but grouping re-interleaves
         it: a region's rows arrive in whatever order the global sort left them,
         so the one you can finish can sit below three you cannot. Sorting per
         region puts it back on top of its own group, which is where the eye
         goes. ]]
    local BAND = {turnin = 1, progress = 2, unknown = 3, ['repeat'] = 3,
                  ready = 3, blocked = 4}
    for _, g in ipairs(order) do
        table.sort(g.rows, function(a, b)
            local ba = BAND[a.state] or 5
            local bb = BAND[b.state] or 5
            if ba ~= bb then return ba < bb end
            return (a.name or a.key) < (b.name or b.key)
        end)
    end

    return order, #rows
end

--[[ The step ladder for the detail pane, straight from steps.explain, which
     already returns every row with a verdict on its evidence. `active` is true
     here by construction: this pane is only ever opened on an accepted
     quest. ]]
function model.ladder(entry)
    if model.status ~= 'ok' or type(entry) ~= 'table' then return nil end
    local ok, l = pcall(steps.explain, entry, true)
    if not ok then return nil end
    return l
end

-- ---------------------------------------------------------------------------
-- Which repeatables you have finished before
-- ---------------------------------------------------------------------------

--[[ The packet cannot tell you, but the addon can remember.

     A repeatable you have completed and then re-accepted reports exactly what a
     first-time acceptance reports: current set, completed clear. questmarks
     relies on that, and core/steps.lua says so: "Repeatable quests DO step, but
     only while re-accepted, which is guaranteed by the only caller that matters:
     prereq consults a position solely when 0x056 reports the quest in progress".
     There is no times-completed counter anywhere in 0x056, so at any single
     instant the two are indistinguishable.

     What is available is history. The completed bitfield arrives in full on
     every login and on every 0x056 update, so any time the addon is running
     while the quest sits completed, it can write that down. Later, when the same
     quest reads in_progress, the record proves you have finished it before,
     which is precisely what questmarks' blue means.

     This is an observation, not an inference, and that distinction is
     questmarks' own. Its core/steps.lua refuses to persist the step latch
     because "a step mark is a floor, not a reading" and writing an inference to
     disk makes a wrong one permanent and undiagnosable, while its `save_fame`
     writes fame readings per character. A completed bit read straight off a
     packet is a reading. It belongs on the saved side of that line.

     What it cannot know, stated plainly: a quest you completed and re-accepted
     entirely between two runs of this addon. The window is narrow, because the
     full completed bitfield arrives on every login and the addon has to have
     been absent for both events, but it is real. The failure is silent and
     benign: the quest shows the ordinary yellow. ]]
local seen_done = {}

--[[ Stored as one delimited string, not as a table, and that is a hard
     requirement rather than a preference.

     Windower's config library serialises a table's keys as XML element names.
     These keys are `cat/area/id`, such as `quest/windurst/28`, and a slash is
     not legal in an XML name, so saving the set as a table writes

         <mission/windurst/4>true</mission/windurst/4>

     which the parser reads as a self-closing `<mission/>` followed by rubbish.
     The addon then fails to load at all:

         Lua runtime error: libs/config.lua:99: XML error, line 9:
         Mismatched tag ending: </mission

     A single string is element text rather than an element name, so no key of
     ours ever reaches the XML grammar. The character name is still a key, but
     FFXI names are alphanumeric and legal as element names. ]]
local function split_keys(str)
    local t = {}
    if type(str) ~= 'string' then return t end
    for k in str:gmatch('[^,]+') do
        k = k:match('^%s*(.-)%s*$')
        if k ~= '' then t[k] = true end
    end
    return t
end

--[[ Accepts either form. An install carrying the table form should keep its
     observations rather than silently start over, and migration is free here
     because the set is a set either way. ]]
function model.set_seen_done(v)
    if type(v) == 'string' then seen_done = split_keys(v)
    elseif type(v) == 'table' then
        seen_done = {}
        for k, on in pairs(v) do
            if on and type(k) == 'string' then seen_done[k] = true end
        end
    else seen_done = {} end
end

function model.seen_done_table() return seen_done end

--[[ -> the set as one comma-joined string, sorted so the settings file does not
     churn on every save just because pairs() came out in a different order. ]]
function model.seen_done_string()
    local t = {}
    for k in pairs(seen_done) do t[#t + 1] = k end
    table.sort(t)
    return table.concat(t, ',')
end

--[[ Record every repeatable currently sitting completed. Walks the index and
     asks state directly rather than going through quests.todo, which would run
     a full prereq evaluation per entry for an answer neither needs.

     -> true when something new was learned, so the caller can decide to save. ]]
function model.observe_completions()
    if model.status ~= 'ok' then return false end
    local added = false
    local ok = pcall(function()
        quests.each_entry(function(key, e)
            if e.repeatable and state.status_of(e.cat, e.area, e.id) == 'done'
               and not seen_done[key] then
                seen_done[key] = true
                added = true
            end
        end)
    end)
    return ok and added
end

--[[ Has this quest been observed completed at some point? Only meaningful for a
     repeatable; anything else is either done now or has never been done. ]]
function model.done_before(entry)
    if type(entry) ~= 'table' or not entry.repeatable then return false end
    local key = (entry.cat or '?') .. '/' .. (entry.area or '?') .. '/'
                .. tostring(entry.id)
    return seen_done[key] == true
end

return model
