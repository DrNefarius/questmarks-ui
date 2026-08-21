--[[
resnames.lua -- turn a resource id into a name, for items and key items.

Why it is needed. A step's `ev` and `reqs` entries are `{rid=1698, n=1,
kind='item'}`: the thing you obtain, or the thing you hand over. Without a name
the panel can only describe a step by its target, which for an `obtain` step is
the wrong noun entirely. "Tuning In" step 2 comes out as "Obtain Fomor Warrior,
Fomor Monk, ..." when the Fomors are where the item drops and the item is an
Extra-Fine File. questmarks' own questgraph tool reads that shape as
"Obtain <grants> from <mobs>", which is the sentence this file exists to allow.

Where the names come from, and why loadfile.

  res/items.lua       23534 entries, 5.0 MB, about 90 ms to parse
  res/key_items.lua    3231 entries, 355 KB, about 5 ms

Both are Windower's own, and both are read with `loadfile` rather than through
`require('resources')`. That is questmarks' carve-out, argued in its `NOTICE` and
at the comment above its own `res_name()`: res/ is Windower's directory rather
than another addon's, and `require('resources')` monkeypatches the base string
and table metatables for the sake of a lookup table. Reading a plain data file
costs nothing but the parse.

Lazy, once, and then compacted. 90 ms is fine as a one-off the first time a
detail pane needs a name; it is not fine at load, and it is certainly not fine
per frame. 23534 full item records is also a lot of memory to hold for the sake
of a name, so the id to name map is copied out and the parsed table is dropped on
the floor for the collector. What survives is one string per id.

Degrades to nothing. A missing res file, a rid that does not resolve, or a kind
this does not know all produce nil, and every caller is written to fall back to
saying less rather than to saying something wrong.
]]

local resnames = {}

local names = nil          -- kind -> {[rid] = 'Name'}
local loaded = false
local stats = {items = 0, key_items = 0, ms = 0}

local FILES = {
    item = 'items.lua',
    --[[ The data writes key items as `ki`; Windower's file is key_items.lua.
         Both spellings are accepted so a future emitter change cannot silently
         stop resolving. ]]
    ki = 'key_items.lua',
    key_item = 'key_items.lua',
}

local function compact(path)
    local chunk = loadfile(path)
    if not chunk then return nil, 0 end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= 'table' then return nil, 0 end
    --[[ Copy out just the English name. The parsed table goes out of scope on
         return, so the 5 MB of item records is collectable and what is retained
         is one string per id. ]]
    local out, n = {}, 0
    for id, e in pairs(t) do
        if type(e) == 'table' and type(e.en) == 'string' then
            out[id] = e.en
            n = n + 1
        end
    end
    return out, n
end

local function ensure()
    if loaded then return end
    loaded = true
    names = {}
    local root = (windower and windower.windower_path or '') .. 'res/'
    local t0 = os.clock()

    local items, ni = compact(root .. 'items.lua')
    local kis, nk = compact(root .. 'key_items.lua')
    names.item = items
    names.ki = kis
    names.key_item = kis
    stats.items, stats.key_items = ni or 0, nk or 0
    stats.ms = (os.clock() - t0) * 1000
end

--[[ -> the name for `rid` of `kind`, or nil.

     nil is a legitimate answer and callers must handle it: an id can be absent
     from a res file that predates the content, and saying nothing is always
     better than saying an id. ]]
function resnames.name(rid, kind)
    if type(rid) ~= 'number' then return nil end
    local ok = pcall(ensure)
    if not ok or not names then return nil end
    local t = names[kind or 'item']
    return t and t[rid] or nil
end

--[[ -> a comma-joined list of the names in an `ev` or `reqs` array, with counts
     where more than one is wanted, or nil when nothing resolves.

     Counts matter here: "Obtain 4 Bronze Ingot" is a different instruction from
     "Obtain Bronze Ingot", and the data carries `n` precisely because several
     steps need several of a thing. ]]
function resnames.list(entries, max)
    if type(entries) ~= 'table' then return nil end
    local out = {}
    for _, e in ipairs(entries) do
        local nm = resnames.name(e.rid, e.kind)
        if nm then
            if (e.n or 1) > 1 then nm = e.n .. ' ' .. nm end
            out[#out + 1] = nm
            if max and #out >= max then break end
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, ', ')
end

--[[ One requirement entry as a phrase, or nil.

     `list` above is enough for `ev`, which the panel only ever states as "what
     this step gives you". A requirement is something the player has to go and
     satisfy, and two fields on it change what satisfying it means, so they are
     carried into the phrase rather than dropped:

     `kind == 'ki'` is a key item. It cannot be traded, sold or dropped and it
     lives in a different menu from everything else, so "have I got it?" is
     answered somewhere else entirely. 35 of the corpus' trade-step requirement
     entries are key items, and a bare name there sends the player to a trade
     window for a thing that cannot be put in one. questgraph's own ledger marks
     these the same way, in `entryChip` in tools/questgraph/web/quest.js.

     `eq` is equipped, not merely carried. `inventory.holds` in questmarks tests
     it separately for one reason: the "Unlocking a Myth" quests ask for a Vigil
     Weapon equipped, and a sword in a wardrobe satisfies a carried test. All 20
     entries carrying the flag in the corpus are those quests, and printing the
     name alone reproduces the bug the flag exists to prevent.

     `resnames.list` is deliberately not changed to do this. It is what states
     `ev`, and `ev` is what a step grants, which is a different claim. ]]
function resnames.entry(e)
    if type(e) ~= 'table' then return nil end
    local nm = resnames.name(e.rid, e.kind)
    if not nm then return nil end
    if (e.n or 1) > 1 then nm = e.n .. ' ' .. nm end
    if e.kind == 'ki' or e.kind == 'key_item' then nm = nm .. ' (key item)' end
    if e.eq then nm = nm .. ' (equipped)' end
    return nm
end

--[[ -> text, shown, unnamed  for a requirement array.

     `unnamed` is the point of this existing at all. A caller that only got the
     string back could not tell "these are the three things you need" from
     "these are the three of six things this install can name", and stating the
     first when the second is true is the completeness claim `reqs_partial`
     exists to refuse. Every caller has to use it.

     An id `res/` cannot resolve and an entry past `max` both land in `unnamed`,
     because for the reader they are the same fact: there is more here than this
     line names.

     `dedupe` drops an entry whose phrase has already been said, and does not
     count it as unnamed: nothing is missing from the line, the same words were
     simply about to appear twice. Pass it only for an or-list. Two entries of an
     or-list resolving to one name are exactly equivalent to one of them, so
     saying it once is both shorter and true; two entries of an and-list are two
     distinct things you need both of, and collapsing them would delete one.
     Key items 10 and 149 are both named `overdue book notification`, so without
     it a step asking for either reads "any one of overdue book notification,
     overdue book notification". 20 steps in the corpus have a duplicate inside
     `reqs_alt` and none inside `reqs`. ]]
function resnames.join(entries, max, dedupe)
    if type(entries) ~= 'table' then return nil, 0, 0 end
    local out, seen, unnamed = {}, {}, 0
    for _, e in ipairs(entries) do
        local nm = resnames.entry(e)
        if not nm then
            unnamed = unnamed + 1
        elseif dedupe and seen[nm] then
            -- said already; nothing is being withheld
        elseif max and #out >= max then
            unnamed = unnamed + 1
        else
            seen[nm] = true
            out[#out + 1] = nm
        end
    end
    if #out == 0 then return nil, 0, unnamed end
    return table.concat(out, ', '), #out, unnamed
end

function resnames.loaded() return loaded and names ~= nil end
function resnames.stats() return stats end

return resnames
