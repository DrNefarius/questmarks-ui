--[[
notes.lua -- the per-step authoring notes, read from disk, never bundled.

What these are. questmarks' pipeline records a short human note on most steps,
"top floor, not down the stairs; spawns two Pudding NMs" or "any one of: La
Theine Cabbage x5, Millioncorn x3, Boyahda Moss x1", as the justification for
how a BG Wiki walkthrough was read. Measured over build/authored/: 6459 of 7142
steps carry one (90%), totalling 906 KB.

Why they matter here. 1002 of the shipped index's 6858 steps (14.6%) can carry
no marker at all, because they name neither an NPC nor a monster: a '???', a
zone line, a fight with nothing recorded. 133 entries have two or more of them
in a row, the longest run being six. For those steps questmarks has, correctly,
nothing to draw and nothing to say. The note is the only thing that answers "so
what do I actually do". That is the entire case for this module.

The licence reading, and why this file reads rather than ships.

questmarks' `NOTICE` records that its emitter drops both the per-step `note` and
the per-quest `notes`, deliberately, because the source is BG Wiki content under
CC BY-NC-SA 3.0 and "an emitter that started shipping wiki sentences would
change what the ADDON redistributes". It also says, of the wider repository's
obligations, "For personal use none of this is a concern."

Those two sentences are not in tension; they are about different acts.
Redistribution is what the licence's share-alike and attribution terms attach
to. Reading a file that is already on your own disk is not redistribution under
any reading of it.

So this module ships no note text whatsoever. It reads build/authored/ in place,
at runtime, from wherever questmarks is installed. The consequence is the
boundary that ought to exist:

  * questmarks commits build/authored/ and build/rendered/, so a clone of it has
    the notes and this feature works. Its `NOTICE` says why, and names this
    addon as the reason build/rendered/ is committed at all.
  * A copy of questmarks-ui alone has neither, and then this feature is simply
    absent. Nothing breaks and nothing is redistributed from here.

Bundling the notes would be the thing questmarks' emitter refused to do, so if
this addon is ever published, this file is the one to leave alone.

Why it cannot come from the shipped index. `emit_step` in
tools/pipeline/emit_lua.py builds each step from an explicit field whitelist and
`note` is not on it, so no amount of reading data/quest_index.lua will recover
one. build/authored/ is the only copy.

The alignment problem, and its answer. A note is worthless if it lands on the
wrong step. emit_lua.py emits every step of a quest in order with no filtering,
and only whole quests with an empty ladder are skipped, so authored step N
should be shipped step N. Verified rather than assumed, over the whole corpus:
of the 1546 authored quests, 1444 are present in the shipped index, and for all
1444 the step count and the ordered sequence of step kinds match exactly. Zero
mismatches. That is what makes indexing by position safe, and tools/smoke.lua
re-checks a sample of it so a future pipeline change that reorders steps cannot
land silently.
]]

local notes = {}

local dir = nil
local cache = nil          -- key -> {[step index] = note}
local scanned = false
local stats = {files = 0, quests = 0, notes = 0, ms = 0, redacted = 0}

local rdir = nil
local desc_cache = nil     -- key -> description string
local desc_scanned = false
local desc_stats = {files = 0, quests = 0, ms = 0}

local function dir_present(p)
    --[[ windower.dir_exists is a real export; libs/files.lua:113 uses it the
         same way. Guarded so the offline harness, which has no such function,
         falls through to the caller's io.open probe. ]]
    local ok, present = pcall(function()
        return windower.dir_exists and windower.dir_exists(p)
    end)
    return ok and present and true or false
end

--[[ The player's vocabulary, loaded from questmarks with a bundled fallback.

     These notes are written as build-log justifications for a maintainer, and
     that register leaks: sentences that tell the player about res/key_items.lua,
     the resolver, a numbered rule or what the record carries. questmarks'
     `emit_lua.py` still names 531 such build terms in its own baseline file, so
     the shape is real and the corpus has held them.

     It redacts nothing on the corpus shipped today, because questmarks'
     `rewrite_notes.py` has since cleaned it, and `//qmui diag` says so. Keep it
     anyway: it is the guard that stops a re-authored note reaching a player in
     the maintainer's voice, and a filter is worth nothing the first time it is
     needed if it was deleted for being quiet.

     Two stages, and the order is the whole design.

     Translate first. `rung` and `evidence` are the two commonest offenders by a
     wide margin, and both have a real word this panel already uses: step, and
     signal (see the candidate-band line in ui/panel.lua). Substituting them
     rescues the sentence instead of costing it, so "nothing reports the count,
     so this rung cannot advance" becomes ordinary, useful English. Doing this
     second would be pointless, because the sentence would already be gone.

     Drop second, and by sentence rather than by word. A sentence still naming a
     build thing after translation cannot be repaired by substitution, because
     there is no player word for "res/key_items.lua", and half-deleting it leaves
     a stump that reads as a truncation. If nothing survives, the note is empty,
     which `scan_file` treats as "no note" and the panel treats as a
     non-expandable step. That is the correct outcome, and the preamble stripper
     below can empty a note the same way.

     Why a shared file. tools/pipeline/check_voice.py fails the questmarks build
     on a new build term in a note, and this redacts any that are already there.
     Two copies of one word list is drift waiting to happen, so both read
     tools/pipeline/lib/player_voice.json. Lua patterns have no alternation and
     no \b, so each rule carries `lua_find` (plain substrings) and `lua_match`
     (Lua patterns) beside the Python regex; the gate refuses to run if a rule is
     missing them, which is what keeps the two honest.

     Bundled fallback, because this addon must not need questmarks' tools/ to be
     present. If the file is missing or unreadable the constants below are used.
     They are a subset, the shapes that cost the most, and the file is the
     authority whenever it is there. ]]
local FALLBACK_TRANSLATE = {
    {'%f[%w]rungs%f[%W]', 'steps'},
    {'%f[%w]rung%f[%W]', 'step'},
    {'%f[%w]ladder%f[%W]', 'step list'},
    {'%f[%w]evidence%f[%W]', 'signal'},
}
local FALLBACK_FIND = {
    'res/', 'res\\', '.lua', '.py', 'resolv', 'chronicl', 'quarantin',
    'baselin', 'prepass', 'schema', 'emitter', 'pipeline', 'overrid',
    'normalis', 'normaliz',
}
local FALLBACK_MATCH = {
    'rules?%s+%d', '%f[%w]%l+_%l+', '%f[%w]record%f[%W]',
    '%f[%w]records%f[%W]', 'stage%s+%a%f[%W]',
}

local voice_translate, voice_find, voice_match = nil, nil, nil
local voice_src = 'not loaded'

--[[ Read the list without a JSON parser, exactly as scan_file reads the corpus
     and for the same reason. The three arrays wanted here are flat lists of
     quoted strings under known keys, so the values can be lifted directly. The
     `translate` pairs need `from` and `to` together, so that one is walked as
     objects. If anything about the shape changes, the scrape finds nothing and
     the fallback stands; it cannot half-load a list. ]]
local function load_voice(path)
    local f = io.open(path, 'r')
    if not f then return false end
    local raw = f:read('*a')
    f:close()
    if not raw or raw == '' then return false end

    local tr, find, match = {}, {}, {}

    local tblock = raw:match('"translate"%s*:%s*%[(.-)%]%s*,%s*"banned"')
    if tblock then
        for obj in tblock:gmatch('%b{}') do
            local from = obj:match('"from"%s*:%s*"(.-)"')
            local to = obj:match('"to"%s*:%s*"(.-)"')
            local lp = obj:match('"lua"%s*:%s*"(.-)"')
            if from and to then
                --[[ `lua` is written with %% so it survives JSON; undo that.
                     Without it, fall back to a word-bounded literal. ]]
                local pat = lp and lp:gsub('%%%%', '%%')
                    or ('%f[%w]' .. from .. '%f[%W]')
                tr[#tr + 1] = {pat, to}
            end
        end
    end

    for body in raw:gmatch('"lua_find"%s*:%s*%[(.-)%]') do
        for s in body:gmatch('"(.-)"') do
            find[#find + 1] = s:gsub('\\\\', '\\'):lower()
        end
    end
    for body in raw:gmatch('"lua_match"%s*:%s*%[(.-)%]') do
        for s in body:gmatch('"(.-)"') do
            match[#match + 1] = (s:gsub('\\\\', '\\'))
        end
    end

    if #tr == 0 or (#find == 0 and #match == 0) then return false end
    voice_translate, voice_find, voice_match = tr, find, match
    return true
end

local function voice()
    if voice_translate then return end
    voice_translate = FALLBACK_TRANSLATE
    voice_find, voice_match = FALLBACK_FIND, FALLBACK_MATCH
    voice_src = 'bundled fallback'
end

function notes.voice_source() return voice_src end

function notes.attach(questmarks_path)
    cache, scanned = nil, false
    stats = {files = 0, quests = 0, notes = 0, ms = 0, redacted = 0}
    desc_cache, desc_scanned = nil, false
    desc_stats = {files = 0, quests = 0, ms = 0}
    dir, rdir = nil, nil
    if type(questmarks_path) ~= 'string' or questmarks_path == '' then return end
    local p = questmarks_path
    if p:sub(-1) ~= '/' and p:sub(-1) ~= '\\' then p = p .. '/' end

    --[[ The shared vocabulary, before any note is read. Not finding it is not an
         error, because the bundled fallback above covers the shapes that cost the
         most, but which one is in use is reported by //qmui diag: a silently
         degraded filter is one nobody notices. ]]
    voice_translate, voice_find, voice_match = nil, nil, nil
    if load_voice(p .. 'tools/pipeline/lib/player_voice.json') then
        voice_src = 'questmarks/tools/pipeline/lib/player_voice.json'
    else
        voice_src = 'bundled fallback (player_voice.json not readable)'
    end

    local a = p .. 'build/authored/'
    if dir_present(a) then dir = a
    else
        -- Fallback probe: if we can open one known batch, the directory is there.
        local f = io.open(a .. '_batch1.json', 'r')
        if f then f:close() dir = a end
    end

    local r = p .. 'build/rendered/'
    if dir_present(r) then rdir = r
    else
        --[[ No single filename is predictable here. The leading number is a
             page sequence, not the quest id (0000005_a_crisis_in_the_making is
             quest/windurst/2), so absence of get_dir means absence of the
             feature, and the listing helper below decides. ]]
        rdir = r
    end
end

function notes.available() return dir ~= nil end
function notes.stats() return stats end
function notes.desc_stats() return desc_stats end

-- ---------------------------------------------------------------------------
-- Directory listing
-- ---------------------------------------------------------------------------

--[[ windower.get_dir(path) -> array of names. Real, and Windower's own
     resources library is built on it: libs/resources.lua:130 enumerates
     res/*.lua with exactly this call. Offline there is no such function, so the
     harness falls back to a shell listing, which is fine for a build-time test
     and is never reached in game. ]]
local function shell_list(cmd)
    local out = {}
    local okp, pipe = pcall(io.popen, cmd)
    if not okp or not pipe then return nil end
    local okr = pcall(function()
        for name in pipe:lines() do
            name = name:gsub('[\r\n]', '')
            if name ~= '' then out[#out + 1] = name end
        end
    end)
    pcall(function() pipe:close() end)
    if okr and #out > 0 then return out end
    return nil
end

local function list_dir(path)
    local ok, l = pcall(function()
        return windower.get_dir and windower.get_dir(path)
    end)
    if ok and type(l) == 'table' and #l > 0 then return l end

    --[[ In game this is never reached, because windower.get_dir is real. The
         fallbacks exist for the offline harness, and there are two of them
         because io.popen on Windows spawns cmd.exe, which has no `ls`. `dir /b`
         is the cmd equivalent and wants backslashes. The POSIX form is kept
         second for a shell that has it. ]]
    local win = path:gsub('/', '\\'):gsub('\\+$', '')
    return shell_list('dir /b "' .. win .. '" 2>nul')
        or shell_list('ls -1 "' .. path .. '" 2>/dev/null')
end

-- ---------------------------------------------------------------------------
-- Scanning
-- ---------------------------------------------------------------------------

--[[ JSON string unescaping, restricted to what this corpus contains. \u is
     turned into '?' rather than decoded: Windower's text rendering is
     single-byte (chronicle/ui/theme.lua:324), so a decoded codepoint could not
     be drawn anyway, and a '?' is honest about that. ]]
local ESC = {n = '\n', t = ' ', r = '', b = '', f = '', ['"'] = '"',
             ['\\'] = '\\', ['/'] = '/'}


--[[ Tidying a note into a sentence.

     These are written as build-log justifications, not as player-facing text,
     and two habits of that register read as machine output on screen.

     ` -- ` used as an em dash, in 1338 of the 6459 notes (21%). It is a
     plain-text-file convention; on screen it reads as a diff. Promoted to a
     full stop when what follows starts a new clause, and to a comma otherwise.

     Preambles that restate a flag the panel already draws. "the page marks this
     Optional -- at Orn's request, extra dialogue only" tells the reader
     something the word `optional` on the same line already told them. Stripped
     to "At Orn's request, extra dialogue only." If stripping leaves nothing,
     the note is empty and its step becomes non-expandable, which is correct: it
     never had anything to say.

     Deliberately conservative. Everything here is a rewrite of text the player
     will act on, so each rule keys on a fixed phrase rather than trying to
     understand the sentence. ]]
local PREAMBLE = {
    '^the page marks this [Oo]ptional%s*%-%-%s*',
    '^the walkthrough marks this [Oo]ptional%s*%-%-%s*',
    '^marked [Oo]ptional%s*%-%-%s*',
    '^this step is optional%s*%-%-%s*',
    '^optional%s*%-%-%s*',
}

--[[ Sentences, and the ` -- ` promotion has to happen before the split.

     The corpus uses ` -- ` as an em dash, and it is a clause boundary as often
     as a comma is. Split first and rejoin with a space and the boundary is lost:
     "not that the mission is over -- The Imperial Silver Pieces stay out" comes
     back as "...is over The Imperial Silver Pieces stay out", two sentences run
     together. So the dash is promoted to real punctuation first, and only then
     is the text cut. ]]
local function promote_dashes(s)
    --[[ A capital or an "It/He/She/They" after the dash starts a new sentence;
         anything else is an aside. ]]
    s = s:gsub('%s+%-%-%s+(%a)', function(c)
        if c:match('%u') then return '. ' .. c end
        return ', ' .. c
    end)
    return (s:gsub('%s*%-%-%s*', ', '))
end

--[[ Split on terminal punctuation only. `;` is deliberately not a boundary: the
     corpus uses it to join two halves of one thought, and cutting there leaves
     "You must have the Vigil Weapon equipped for the cutscene;." on screen, a
     semicolon with nothing after it and a full stop bolted on. A semicolon
     inside a dropped sentence takes the whole sentence with it, which is the
     conservative answer. ]]
local function split_sentences(s)
    --[[ `???` is not a question. It is what the game calls an unnamed clickable
         object, it appears in 321 notes, and treating its last `?` as terminal
         punctuation cuts sentences in half: "puts the ??? at their base" comes
         back as "puts the ???" plus "At their base", capitalised mid-sentence,
         with the tail later dropped as a stump. Hidden behind a byte no note
         contains, restored after the split. ]]
    local out, rest = {}, (s:gsub('%?%?%?', ''))
    while true do
        local a, b = rest:find('[%.!%?]%s+')
        if not a then break end
        local head = rest:sub(1, a)
        if head:match('%S') then out[#out + 1] = head end
        rest = rest:sub(b + 1)
    end
    if rest:match('%S') then out[#out + 1] = rest end
    for i, v in ipairs(out) do out[i] = (v:gsub('', '???')) end
    return out
end

local function is_build_talk(sent)
    local low = sent:lower()
    for _, lit in ipairs(voice_find) do
        if low:find(lit, 1, true) then return true end
    end
    for _, pat in ipairs(voice_match) do
        if sent:find(pat) then return true end
    end
    return false
end

--[[ Words, for the stump test below. A survivor of three words or fewer that
     follows a cut is almost never a sentence. "A ???" is what is left of "a ???
     can never carry a marker, but it keeps the rung", and a fragment on screen
     reads as a bug rather than as brevity. ]]
local function word_count(s)
    local n = 0
    for _ in s:gmatch("%a[%a'-]*") do n = n + 1 end
    return n
end

local function tidy_note(s)
    if type(s) ~= 'string' then return '' end
    s = s:gsub('^%s+', ''):gsub('%s+$', '')

    for _, p in ipairs(PREAMBLE) do
        local stripped = s:gsub(p, '')
        if stripped ~= s then s = stripped break end
    end
    if s == '' then return '' end

    --[[ Stage 1, translate, before anything is judged or dropped. A sentence
         whose only build word is `rung` or `evidence` is not a problem at all
         once it says `step` and `signal`, and translating first is what keeps
         those sentences out of stage 2 rather than dropping them whole. Case is
         preserved on the first letter so a sentence-initial "Evidence" does not
         become lower-case mid-paragraph. ]]
    voice()
    for _, t in ipairs(voice_translate) do
        s = s:gsub(t[1], function(m)
            local to = t[2]
            if m:sub(1, 1):match('%u') then to = to:gsub('^%l', string.upper) end
            return to
        end)
    end

    s = promote_dashes(s)

    --[[ Stage 2, drop, by sentence. There is no player word for
         "res/key_items.lua", so a sentence still naming one after translation
         cannot be rescued, and excising the clause alone would leave a stump
         that reads as a truncation rather than as a sentence. Dropped whole.

         Two things go with it, both found by reading the output rather than by
         reasoning about it:

           a back-reference that lost its referent. Drop "That is what rule 7
           asks for" and a following "It is why the Reward listing does not bar
           it here" is left pointing at nothing;

           a stump, three words or fewer surviving after a cut, which is what
           "A ???" is left as.

         Neither applies before the first cut: a leading sentence is the useful
         one and is never dropped for context it cannot have lost. ]]
    local kept, dropped = {}, false
    for _, sent in ipairs(split_sentences(s)) do
        local bad = is_build_talk(sent)
        if not bad and dropped then
            if sent:match('^%s*[Tt]hat%s') or sent:match('^%s*[Ww]hich%s')
               or sent:match('^%s*[Ss]o%s') or word_count(sent) <= 3 then
                bad = true
            end
        end
        if bad then
            dropped = true
            stats.redacted = (stats.redacted or 0) + 1
        else
            kept[#kept + 1] = (sent:gsub('^%s+', ''):gsub('%s+$', ''))
        end
    end
    if #kept == 0 then return '' end

    --[[ Each survivor has to stand on its own now: it may have been mid-note
         before, so it starts lower-case and may end on a comma or semicolon
         that pointed at something now gone. ]]
    for i, sent in ipairs(kept) do
        sent = sent:gsub('[,;:]$', '')
        if not sent:match('[%.!%?]$') then sent = sent .. '.' end
        kept[i] = (sent:gsub('^%l', string.upper))
    end
    s = table.concat(kept, ' ')

    s = s:gsub('%s+', ' '):gsub('%s+$', '')
    if not s:match('[%.%!%?]$') then s = s .. '.' end
    return s
end

local function unescape(s)
    if not s:find('\\', 1, true) then return s end
    return (s:gsub('\\u%x%x%x%x', '?'):gsub('\\(.)', function(c)
        return ESC[c] or c
    end))
end

--[[ A targeted scanner, not a JSON parser, and that is a decision worth
     defending. A general parser would build 8.3 MB of Lua tables to throw nearly
     all of it away; this reads the three fields it wants.

     It is safe because the corpus is machine-generated to one schema and the key
     `note` occurs at exactly one path in it, /steps[]/note, 7142 times over all
     179 files. There is no nested `note` to confuse, and the quest-level field
     is spelled `notes`, which the anchored pattern below does not match. If a
     future schema moves the key, the scan finds nothing and the feature
     disappears; it cannot attach a note to the wrong thing. ]]
local function scan_file(path)
    local f = io.open(path, 'r')
    if not f then return end
    local raw = f:read('*a')
    f:close()
    if not raw then return end
    stats.files = stats.files + 1

    --[[ Each quest object opens with the schema tag, so those positions cut the
         file into one chunk per quest without parsing structure. ]]
    local bounds = {}
    for pos in raw:gmatch('()"schema"%s*:%s*"questmarks%-authoring/1"') do
        bounds[#bounds + 1] = pos
    end
    bounds[#bounds + 1] = #raw + 1

    for i = 1, #bounds - 1 do
        local chunk = raw:sub(bounds[i], bounds[i + 1] - 1)
        local cat = chunk:match('"cat"%s*:%s*"([^"]*)"')
        local area = chunk:match('"area"%s*:%s*"([^"]*)"')
        local id = tonumber(chunk:match('"id"%s*:%s*(%-?%d+)'))
        if cat and area and id then
            local key = cat .. '/' .. area .. '/' .. id
            local steps = chunk:match('"steps"%s*:%s*(%[.*)')
            if steps then
                local t, last = {}, nil
                --[[ Walk step numbers and notes together in document order and
                     attach each note to the most recent step number before it.
                     Positional, so a step whose note is null simply gets none. ]]
                local marks = {}
                for pos, n in steps:gmatch('()"n"%s*:%s*(%d+)') do
                    marks[#marks + 1] = {pos = pos, n = tonumber(n)}
                end
                for pos, txt in steps:gmatch('()"note"%s*:%s*"(.-)"%s*[,}]') do
                    last = nil
                    for _, m in ipairs(marks) do
                        if m.pos < pos then last = m.n else break end
                    end
                    if last and txt ~= '' then
                        local clean = tidy_note(unescape(txt))
                        if clean ~= '' then
                            t[last] = clean
                            stats.notes = stats.notes + 1
                        end
                    end
                end
                if next(t) then
                    cache[key] = t
                    stats.quests = stats.quests + 1
                end
            end
        end
    end
end

--[[ One pass, lazily, on first use. Never at load: an addon that spends half a
     second reading 8.3 MB before the player has opened anything is an addon that
     appears to hang on //lua load. Triggered by the first detail pane that asks,
     behind a pcall, and if it fails the feature is off for the session rather
     than fatal. ]]
local function ensure()
    if scanned then return end
    scanned = true
    if not dir then return end
    cache = {}
    local t0 = os.clock()

    local files = list_dir(dir)
    if files then
        for _, name in ipairs(files) do
            if type(name) == 'string' and name:sub(-5) == '.json' then
                pcall(scan_file, dir .. name)
            end
        end
    else
        --[[ No directory listing at all. Probe the two naming families the
             corpus uses, _batchN and _runNNN, and stop after a run of
             misses. ]]
        for n = 1, 40 do
            pcall(scan_file, dir .. ('_batch%d.json'):format(n))
        end
        local misses = 0
        for n = 0, 400 do
            local p = dir .. ('_run%03d.json'):format(n)
            local f = io.open(p, 'r')
            if f then f:close() pcall(scan_file, p) misses = 0
            else misses = misses + 1 if misses > 20 then break end end
        end
    end

    stats.ms = (os.clock() - t0) * 1000
end

--[[ -> table of {[step index] = note}, or nil.
     Callers have to treat a missing table and an empty one alike: this is an
     optional enrichment, never something the layout depends on. ]]
function notes.for_quest(cat, area, id)
    if not dir then return nil end
    local ok = pcall(ensure)
    if not ok or not cache then return nil end
    return cache[tostring(cat) .. '/' .. tostring(area) .. '/' .. tostring(id)]
end

-- ---------------------------------------------------------------------------
-- The game's own quest description
-- ---------------------------------------------------------------------------

--[[ The description is the game's text, not the wiki's prose, and that is the
     whole reason it is treated differently from a walkthrough.

     build/rendered/*.md carries a `Description:` block per quest, wrapped at the
     client's own fixed width:

         Description:
                     Advertise Baren-Moren's latest
                     creation by chatting with the local
                     inhabitants of Windurst Waters.

     That is what the player's in-game quest log says, transcribed. It is
     SQUARE ENIX game content, covered by questmarks' NOTICE under game content
     rather than by CC BY-NC-SA authorship, which reached this machine by way of
     a wiki that transcribed it. The evidence that it is a transcription rather
     than a paraphrase is the in-game line wrapping, which survives verbatim,
     hyphenation and all: chronicle's copy of the same field still contains the
     client's fixed-width breaks ("extra- luxurious",
     chronicle/wiki/quests/windurst.lua:52). questmarks' rendered copies are
     clean of that artefact, checked across all 1829 files with zero hits, so the
     lines can be rejoined into a paragraph and re-wrapped to the pane.

     It cannot be read from the client, and that is established with negative
     evidence: there is no quest resource in res/, LuaCore exports 45 get_*
     functions and none is quest-related, and no DAT dump exists in the tree.
     0x056 carries ids and completion bits, not text. So the choice is between
     "no description at all" and "read the transcription that is already on this
     disk".

     Same rule as the step notes: read in place, ship nothing. This file contains
     no description text. A copy of this addon on a machine without questmarks'
     build/rendered/ simply has no descriptions, which is the correct outcome and
     requires no decision from anybody. ]]

local function scan_desc(path)
    --[[ Only the first 1600 bytes. Measured across all 1829 files, the furthest
         `Description:` starts 1480 bytes in, so a prefix read reaches every one
         of them and turns 4.2 MB of scanning into 2.8 MB.

         That margin is 120 bytes and it is the whole safety of this. Re-measure
         it whenever build/rendered/ gains front-matter keys, because a block
         pushed past the window is a description that silently disappears. ]]
    local f = io.open(path, 'r')
    if not f then return end
    local raw = f:read(1600)
    f:close()
    if not raw then return end
    desc_stats.files = desc_stats.files + 1

    local cat = raw:match('"cat"%s*:%s*"([^"]*)"')
    local area = raw:match('"area"%s*:%s*"([^"]*)"')
    local id = tonumber(raw:match('"id"%s*:%s*(%-?%d+)'))
    if not (cat and area and id) then return end

    local i = raw:find('Description:', 1, true)
    if not i then return end

    --[[ The block is the indented continuation lines that follow. It ends at
         the next label in column zero (`Fame:`, `FLevel:`, `Repeatable:`), so
         the terminator is "a line that does not begin with whitespace". ]]
    local body = {}
    local first = true
    for line in raw:sub(i + 12):gmatch('([^\n]*)\n') do
        if first then
            first = false
            local rest = line:match('^%s*(.-)%s*$')
            if rest ~= '' then body[#body + 1] = rest end
        elseif line:match('^%s+%S') then
            body[#body + 1] = line:match('^%s*(.-)%s*$')
        elseif line:match('^%s*$') then
            -- blank line inside the block: keep going, it is padding
        else
            break
        end
    end
    if #body == 0 then return end

    --[[ Rejoined into one paragraph. The line breaks in the file are the
         client's fixed-width wrapping at the client's panel width, which has
         nothing to do with this one; keeping them would produce a ragged column
         a third the width of the pane. ]]
    local text = table.concat(body, ' '):gsub('%s+', ' ')
    desc_cache[cat .. '/' .. area .. '/' .. id] = text
    desc_stats.quests = desc_stats.quests + 1
end

local function ensure_desc()
    if desc_scanned then return end
    desc_scanned = true
    if not rdir then return end
    local files = list_dir(rdir)
    if not files then return end
    desc_cache = {}
    local t0 = os.clock()
    for _, name in ipairs(files) do
        if type(name) == 'string' and name:sub(-3) == '.md' then
            pcall(scan_desc, rdir .. name)
        end
    end
    desc_stats.ms = (os.clock() - t0) * 1000
end

--[[ -> the quest's in-game description as one paragraph, or nil. ]]
function notes.description_for(cat, area, id)
    if not rdir then return nil end
    local ok = pcall(ensure_desc)
    if not ok or not desc_cache then return nil end
    return desc_cache[tostring(cat) .. '/' .. tostring(area) .. '/' .. tostring(id)]
end

return notes
