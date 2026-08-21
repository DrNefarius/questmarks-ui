--[[
ui/panel.lua -- the quest log window.

Layout, and the argument with WoW's quest log.

WoW puts a collapsible region tree in a left pane and quest detail in a right
pane that is always there, because a WoW quest carries several paragraphs of
description and objective text that need the room. FFXI hands an addon no quest
description at all, so a permanently open right pane here would be a
permanently open empty pane, and it would cost the width at the moment the
player is scanning a list, which is the one moment they do not want it.

So: one column by default, and the detail pane opens beside it only when a
quest is selected. Nothing selected costs nothing. That is worth doing because
the list is the common case and the detail is the rare one, which is the
opposite of the WoW assumption.

Region headers are kept, and they are collapsible, but they are not the point
they are in WoW. A WoW log holds 25 quests over a dozen zones; an FFXI log is
smaller, so headers here earn their place by orientation, meaning which of the
game's own log sections a quest is filed under, rather than by hiding bulk.

Not a clickable tree only. The mouse works, and the event is real with its shape
pinned below, but almost every action also has a command, because the mouse
cursor in FFXI is frequently captured by the game and a player mid-fight would
rather type. Two are mouse-only and known to be: expanding one step's note, and
the "show all notes" toggle. Everything else -- moving the selection, folding,
scrolling either pane, the state filters, search and hide -- has one.

The mouse event, established rather than assumed. The signature is
`(type, x, y, delta, blocked)`, confirmed in three independent addons that all
agree: Windower's own libs/texts.lua:618 and libs/images.lua:381, and
chronicle/ui/widgets.lua:2490. Type codes are read off the branches those three
take: 0 = move, 1 = left down, 2 = left up. Returning true blocks the event from
reaching the game (texts.lua:610-628 returns true only while dragging, so the
click that started a drag does not also click the world).

  Move events are not blocked, and that is load-bearing rather than lazy.
  chronicle wrote this down at widgets.lua:2534-2540: swallowing type 0 freezes
  FFXI's own cursor tracking, so once the in-game cursor is hidden it cannot
  reappear while the pointer is over the panel. Camera rotation needs the right
  button held, so passing moves through is safe. Clicks over the panel are
  blocked, to stop click-through into the world.

Lua dialect: the game runs PUC-Rio Lua 5.1.

Windower's in-game interpreter is Lua 5.1. `goto` and `::labels::` are 5.2, the
integer-division operator `//` is 5.3, and the bitwise operators are 5.3. None
of them parse in game, and a parse error means the addon does not load at all.

The offline suite will not catch it for you. tools/smoke.lua runs LuaJIT, which
accepts 5.2 `goto`, so `goto continue` passes every test here and then fails in
game with "'=' expected near 'continue'". tools/check_dialect.lua scans for the
whole family, which is the check that speaks for the target rather than for the
harness. Run it before believing a green suite.

Prim discipline. The object pool is fixed and allocated once. Nothing is created
or deleted while the panel is open; a row that is not needed is hidden, not
destroyed. This is render/markers.lua's rule (markers.lua:12-14) and it applies
here for the same reason: named objects are owned by the client, and churning
them is both the expensive path and the one that leaks.
]]

local panel = {}

local draw  = require('ui/draw')
local theme = require('ui/theme')
local model = require('model')
local resnames = require('resnames')

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local S = {
    open = false,
    x = 60, y = 90,
    scroll = 0,
    sel = nil,             -- flattened index of the selected quest line
    sel_key = nil,         -- its quest key, so selection survives a rebuild
    hover = nil,
    set = 'accepted',
    filter = '',
    collapsed = {},        -- region key -> true
    lines = {},            -- flattened display list
    total = 0,
    handin = 0,
    dirty = true,
    ladder = nil,
    notes = nil,
    desc = nil,
    dlines = nil,          -- flattened detail pane
    dkey = nil,
    dscroll = 0,
    dvisible = 1,
    dopen = {},            -- step index -> explicit open/closed override
    dquest = nil,          -- which quest dopen/dscroll belong to
    showall = false,       -- global 'Show all notes' override
    action_hit = nil,
    action_hover = false,
    hover_step = nil,
}
panel.S = S
panel.W = nil   -- set after the pool is built; see the note below

local W = {}               -- widget pool
-- Exposed for tools/smoke.lua, which asserts that no widget leaks between the
-- row kinds a pool slot can hold. Not read anywhere in the addon itself.


local LINES = 20           -- rows in the pool; scrolling moves data through them
local DETAIL_LINES = 40    -- text-line pool for the detail pane
local DPITCH_BASE = 13     -- px between detail lines, before scaling
--[[ NOT scaled, and that is a known defect rather than a decision. `//qmui
     scale` reaches theme.apply_scale, which rewrites every `fs_*` and
     `theme.d_line`, then rebuilds this pool. Nothing recomputes DPITCH, so at
     any scale but 1.0 the detail pane keeps a 13 px pitch under fonts that
     grew. The fix is to derive it from theme.s(DPITCH_BASE) wherever the pool
     is rebuilt; it is left alone here because it changes in-game layout. ]]
local DPITCH = DPITCH_BASE

--[[ The verb map. The step kinds as the data records them are lowercase machine
     tokens, talk, trade, turnin, examine, fight, obtain, travel, wait, cutscene
     and other, and printing those raw is what makes a panel read as a database
     dump.

     The wording is the game's and the wiki's, not generic interface English:
     "Speak with" and "Report to" rather than "Talk to" and "Hand in". The
     tie-breaker throughout this design is to keep the conventions FFXI itself
     uses and drop the ones only a database uses.

     Not padded. Padding to a common width is monospace thinking; the verb and
     the name are two fixed columns, so alignment is a matter of where they are
     drawn rather than how many spaces are in the string. ]]
local KIND_VERB = {
    talk     = 'Speak with',
    trade    = 'Trade to',
    turnin   = 'Report to',
    examine  = 'Examine',
    fight    = 'Defeat',
    obtain   = 'Obtain',
    travel   = 'Travel to',
    wait     = 'Wait',
    cutscene = 'Watch a cutscene',
    other    = nil,
}

--[[ Verbs that read as complete sentences on their own. Appending a target to
     "Wait" produces "Wait Windurst Waters", so these take no object and the note
     carries the condition.

     `cutscene` is deliberately not here: questgraph gives it the target type
     `npc`, and a cutscene is always somewhere. See the object table in
     build_detail. ]]
local KIND_INTRANSITIVE = {wait = true}

--[[ What the step needs you to be carrying: the `reqs` ledger.

     Without it, "Tuning In" step 5 reads `Trade to  Leepe-Hoppe` and never says
     what to trade, though the three item ids sit in that step's `reqs`. Measured
     over the reachable index (1438 entries, 6858 steps), 1532 steps carry a
     requirement.

         kind         n    reqs  reqs_alt  reqs_partial
         talk      2602     130        13             5
         examine   1391     213        30            26
         trade      779     724        86            56
         turnin     707     232        27            10
         fight      650      30         0             7
         travel     396      25         3             5
         obtain     241      43         5            16
         other       43       9         0             1
         cutscene    36       3         1             0
         wait        13       1         0             0

     Stated for every kind, on its own line, and never folded into the verb
     phrase. Three reasons, in order of weight.

     It cannot be got grammatically wrong. On a `trade` step the items are the
     direct object ("Trade the file to Leepe-Hoppe"); on `examine` they are
     something you must be holding for the '???' to answer; on `travel` they are
     a gate key. One line labelled with the predicate the addon actually tests is
     true for all three, where one sentence per kind is ten chances to say
     something false.

     It follows questgraph, which shows this as its own ledger row, `needs`,
     beside `grants` and `mobs` (`tools/questgraph/web/quest.js:456-518`). Its
     reading of the field is the one being adopted, so its separation of the
     field from the verb comes with it.

     And the target stays where the eye already looks for it. The verb and the
     name are two fixed columns; pushing a six-item list between them would move
     "where do I go" to wherever the list happened to end.

     `Needs` is the word because it is what `inventory.meets` asks, do you hold
     these, and that is the one claim true of every kind. It is not decoration:
     it is what tells this line apart from the location line below it.

     Travel and fight steps get it too, and deliberately. 26 travel steps and 30
     fight steps carry a requirement, and they are among the most useful in the
     corpus: "Travel to Ranguemont Pass / Needs Delkfutt Key" is exactly what you
     want before setting out. `reqs` is tested by `inventory.meets` identically
     whatever the step's kind, so suppressing it by kind would be deciding the
     data is wrong somewhere, with nothing to base that on. ]]

--[[ The longest real `reqs` list is 6, on six steps including quest/bastok/90
     step 8, so the cap on the and-list never fires today and exists so a data
     update cannot make a line unbounded. `reqs_alt` genuinely needs one:
     quest/other/26 step 2 takes any one of fifty-nine fish. ]]
local REQ_MAX     = 6
local REQ_ALT_MAX = 4

--[[ -> the needs line for a raw step, or nil.

     The three shapes, and why none of them may be flattened into another.

     `reqs` is an and-list: `inventory.satisfies` demands every one of them.
     Comma-joined, so it reads as the set it is.

     `reqs_alt` is a second way to satisfy the same step, and any one of its
     entries does it. `inventory.satisfies_any` tests it, and `inventory.meets`
     ors the two lists. It is never an extra requirement. "The Gobbiebag Part I"
     is the case the field exists for: four specific items or a single Goblin
     Stew instead, so a conjunction would be wrong in exactly the case the field
     is there to record. It gets the word `or`, and `any one of` when there is
     more than one of them. 115 steps carry both lists, and there a bare comma
     list plus `or` can be misread as binding to the last item alone, so those
     say `all of` in front of the and-list to close it off.

     `reqs_partial` means the recorded list is incomplete: the builder dropped BG
     Wiki prose it could not parse, which `core/inventory.lua` records above
     `satisfies`. Naming what survived as though it were the whole requirement is
     a completeness claim the data does not support, so it is said out loud. 72
     of the 126 partial steps carry no list at all, and for those the only honest
     sentence is that a requirement exists and is not recorded. That is still
     worth saying, because silence there is indistinguishable from "bring
     nothing".

     An id `res/` cannot name counts the same way. It is not dropped silently:
     the shortfall is stated as `and N more`, because a caller that says less
     must not thereby say something complete. No requirement id in the corpus
     fails to resolve against this install's res/, but a res file older than the
     data is the ordinary case elsewhere.

     `ev` is not consulted here. It is what the step grants. 272 steps carry both
     fields and they name different things. ]]
local function needs_line(raw)
    if type(raw) ~= 'table' then return nil end
    local all = type(raw.reqs) == 'table' and raw.reqs or nil
    local alt = type(raw.reqs_alt) == 'table' and raw.reqs_alt or nil
    local partial = raw.reqs_partial and true or false
    local nall = all and #all or 0
    local nalt = alt and #alt or 0
    if nall == 0 and nalt == 0 and not partial then return nil end

    --[[ The flag with nothing behind it. Reaching here with both lists empty
         means `reqs_partial` is set on its own, which is 72 steps, 27 of them
         trade. A requirement exists and none of it is recorded, and that is
         worth a line: silence is indistinguishable from "bring nothing". ]]
    if nall == 0 and nalt == 0 then return 'Needs  items (list not recorded)' end

    --[[ `dedupe` on the or-list only. See resnames.join: two alternatives with
         one name are equivalent to one of them, while two requirements with one
         name are two things you need both of. ]]
    local atext, ashown, aun = resnames.join(all, REQ_MAX)
    local xtext, xshown, xun = resnames.join(alt, REQ_ALT_MAX, true)

    --[[ How many distinct alternatives are on offer, named or not. `any one of`
         is a claim about the list, so it must not turn on how many of them this
         install can name, and a duplicate that `join` dropped is not one of
         them. ]]
    local nopts = xshown + xun

    --[[ A list that resolves to nothing is replaced by its count, never dropped.

         Dropping it is the one arrangement here that says something outright
         false: with the and-list gone the alternatives read as the whole
         requirement, and with the or-list gone a second way to satisfy the step
         reads as the only way. Folding its shortfall into the shared `and N more`
         at the end would be the same error more quietly, with items you need all
         of counted into the alternatives clause.

         Unreachable with the res/ on this machine, where every requirement id
         in the corpus resolves. Entirely reachable on an install whose res/
         predates the data, which is the ordinary case for anyone running older
         files. ]]
    local function counted(n)
        return ('%d item%s (not named here)'):format(n, n == 1 and '' or 's')
    end
    local x_counted = false
    if ashown == 0 and nall > 0 then
        atext, aun = counted(nall), 0
    end
    if xshown == 0 and nalt > 0 then
        xtext = (nopts > 1) and ('any one of ' .. counted(nalt)) or counted(nalt)
        xun, x_counted = 0, true
    end

    --[[ What this line does not name, pooled. When both lists fall short the sum
         sits at the end of the whole phrase and is a count of what the line
         omits, not of alternatives. Also unreachable today, and stated here
         because the clause's position invites the narrower reading. ]]
    local unnamed = aun + xun

    local parts = {}
    if nall > 0 then
        --[[ `all of` closes the comma list off before an `or`. 115 steps carry both
             lists, and there a bare comma list followed by `or` can be read as
             binding to the last item alone. Not said when the and-list is one
             thing, and not said in front of a bare count. ]]
        if nalt > 0 and ashown > 1 then parts[#parts + 1] = 'all of' end
        parts[#parts + 1] = atext
    end
    if nalt > 0 then
        --[[ A counted or-list carries its own quantifier, so it takes none here. ]]
        if nall > 0 then
            parts[#parts + 1] = (nopts > 1 and not x_counted) and 'or any one of'
                                or 'or'
        elseif nopts > 1 and not x_counted then
            parts[#parts + 1] = 'any one of'
        end
        parts[#parts + 1] = xtext
    end

    if partial and unnamed > 0 then
        parts[#parts + 1] = ('and %d more (list incomplete)'):format(unnamed)
    elseif partial then
        parts[#parts + 1] = 'and more (list incomplete)'
    elseif unnamed > 0 then
        parts[#parts + 1] = ('and %d more'):format(unnamed)
    end

    return 'Needs  ' .. table.concat(parts, '  ')
end
panel.needs_line = needs_line
-- Exposed for tools/smoke.lua, which sweeps it over every step of every quest in
-- the index. Not read anywhere in the addon itself.

-- ---------------------------------------------------------------------------
-- Text metrics
-- ---------------------------------------------------------------------------

--[[ Measurement.

     The face is proportional, so there is no single advance number to get right.
     Widths come from ui/metrics.lua, the real advances of the installed Segoe
     UI, measured from the TrueType file and shipped as fractions of the em.
     Layout has to know a string's width before drawing it, and for strings it
     decides not to draw at all, which is exactly what get_extents cannot answer.

     get_extents is not used anywhere here. It is not wrong, it answers a
     different question.

     If you ever reach for one number per point size again: `size * 0.55` is an
     advance in ems while set_font_size takes points, so that pairing measures
     every string 1.333x too narrow and runs it off both panes. ]]
local function width_of(str, size, bold)
    return theme.width(str, size, bold)
end

function panel.metrics()
    return width_of(('x'):rep(100), theme.fs_name) / 100, 'metrics table',
           theme.fs_name
end

--[[ The width the chevron column reserves, gap included.

     One function because two places need the same answer: the step title is
     wrapped to what is left of it, and the drawing right-aligns both the chevron
     and the `optional` tag against it. Keep them separate and the wrap stops
     accounting for the chevron, so a full-width title runs under it.

     Measured on `v` rather than on the chevron actually being drawn, so the
     column does not change width when a step is opened and `^` takes over. A
     title that re-wrapped on expand would reflow the whole ladder under the
     cursor. ]]
local function chev_width()
    return theme.width('v', theme.fs_meta, true) + theme.s(8)
end
--[[ Exposed for tools/smoke.lua, which measures every drawn title against the
     chevron's left edge. It asks for the number rather than keeping a copy,
     because a copy is how the wrap and the drawing come apart. ]]
panel.chev_width = chev_width

--[[ Truncate to a pixel width. '..' rather than a single-byte ellipsis because
     Windower's text rendering is single-byte only. ]]
local function fit(str, size, px, bold)
    str = tostring(str or '')
    if width_of(str, size, bold) <= px then return str end
    local n = theme.fit_count(str, size, px - width_of('..', size, bold), bold)
    if n < 1 then return '' end
    return str:sub(1, n) .. '..'
end

--[[ Word wrap to a pixel width -> array of lines, at most `maxlines`.

     Breaks at spaces; a single word longer than the line is hard-split so one
     unbreakable token cannot undo the whole thing. The last line takes '..' only
     if something was actually dropped, because a truncated note must never look
     complete. Notes are called with a high line cap and a pane that scrolls, so
     in practice nothing is dropped. ]]
local function wrap(str, size, px, maxlines, bold)
    str = tostring(str or '')
    maxlines = maxlines or 99
    if str == '' then return {} end
    if width_of(str, size, bold) <= px then return {str} end

    local lines, pos = {}, 1
    while pos <= #str and #lines < maxlines do
        local rest = str:sub(pos)
        if width_of(rest, size, bold) <= px then
            lines[#lines + 1] = rest
            pos = #str + 1
            break
        end
        local n = theme.fit_count(rest, size, px, bold)
        if n < 1 then n = 1 end
        local seg = rest:sub(1, n)
        local brk = seg:match('^.*()%s')
        if brk and brk > n * 0.4 then n = brk - 1 end
        lines[#lines + 1] = (rest:sub(1, n):gsub('%s+$', ''))
        pos = pos + n
        while str:sub(pos, pos) == ' ' do pos = pos + 1 end
    end

    if pos <= #str and #lines > 0 then
        lines[#lines] = fit(lines[#lines] .. ' ..', size, px, bold)
    end
    return lines
end

-- ---------------------------------------------------------------------------
-- Pool
-- ---------------------------------------------------------------------------

local function build_pool()
    if W.built then return end

    --[[ An image, not a rect: the pane fills carry a texture. A prim with a
         texture and one without differ only in whether set_texture was called,
         so this costs nothing when the sheet is missing. See set_pane_bg. ]]
    W.bg      = draw.image()
    W.head_bg = draw.rect()
    -- Window chrome: a 1px outer border and a three-rect top band.
    W.frame = {}
    for i = 1, 2 do
        W.frame[i] = {
            t = draw.rect(), b = draw.rect(), l = draw.rect(), r = draw.rect(),
            hair = draw.rect(), mid = draw.rect(),
        }
    end
    W.divider   = draw.rect()
    -- Detail pane ladder rails.
    W.d_rail  = draw.rect()
    W.d_rail_maybe = draw.rect()
    W.d_action = draw.text({size = theme.fs_action, bold = true})
    W.d_action_ul = draw.rect()
    W.rule    = draw.rect()
    W.scr_bg  = draw.rect()
    W.scr_th  = draw.rect()

    W.title  = draw.text({font = theme.font_head, size = theme.fs_title, bold = true})
    W.count  = draw.text({size = theme.fs_count})
    W.close  = draw.text({size = theme.fs_title, bold = true})
    W.status = draw.text({size = theme.fs_prose})
    W.status2 = draw.text({size = theme.fs_prose})

    --[[ One per entry in draw_chips' `defs`. Add a filter without widening this
         pool and the panel stops drawing silently: the new chip is nil,
         draw_chips throws, and the addon's own prerender pcall swallows it into
         a closed panel. tools/smoke.lua calls panel.render directly as well, so
         a layout error fails the suite instead of hiding. ]]
    W.chips = {}
    for i = 1, 3 do
        W.chips[i] = {
            bg = draw.rect(),
            tx = draw.text({size = theme.fs_sub, bold = true}),
        }
    end

    W.lines = {}
    for i = 1, LINES do
        W.lines[i] = {
            bg      = draw.rect(),
            chip    = draw.rect(),
            --[[ The region badge. One per slot rather than one per region, because a
                 slot holds whatever line scrolls into it; it is hidden on every row
                 that is not a region header, which is most of them. ]]
            ico     = draw.image(),
            --[[ The region label is its own object rather than the row's `sub`. Sharing
                 one would put a header's text and a row's second line in the same
                 widget, and "no widget belonging to one kind is visible while the slot
                 shows the other" is the invariant the pool's sweep and its assertion are
                 built on. One widget, one role, and the leak check keeps meaning
                 something. ]]
            glabel  = draw.text({size = theme.fs_region}),
            chip_tx = draw.text({size = theme.fs_step, bold = true}),
            main    = draw.text({size = theme.fs_name}),
            sub     = draw.text({size = theme.fs_sub}),
            right   = draw.text({size = theme.fs_sub, bold = true}),
            prog_bg    = draw.rect(),
            prog_fill  = draw.rect(),
            prog_maybe = draw.rect(),
        }
    end

    -- Detail pane
    W.d_bg    = draw.image()
    W.d_rule  = draw.rect()
    W.d_title = draw.text({font = theme.font_head, size = theme.fs_name, bold = true})
    W.d_where = draw.text({size = theme.fs_sub})
    W.d_meta  = draw.text({size = theme.fs_sub})
    W.d_head  = draw.text({size = theme.fs_sub, bold = true})
    W.d_scr_bg = draw.rect()
    W.d_scr_th = draw.rect()
    W.d_lines = {}
    for i = 1, DETAIL_LINES do
        W.d_lines[i] = {
            a = draw.text({size = theme.fs_step, bold = true}),   -- mark glyph
            n = draw.text({size = theme.fs_meta}),                -- step number
            b = draw.text({size = theme.fs_sub}),                 -- body
            g = draw.text({size = theme.fs_meta}),                -- right tag
            c = draw.text({size = theme.fs_meta, bold = true}),   -- chevron
            h = draw.rect(),                                      -- hover / rule
        }
    end
    W.built = true
    panel.W = W
end

local function hide_all()
    if not W.built then return end
    local function h(o) if o then o:visible(false) end end
    h(W.bg) h(W.head_bg) h(W.rule) h(W.scr_bg) h(W.scr_th)
    for _, f in ipairs(W.frame) do
        h(f.t) h(f.b) h(f.l) h(f.r) h(f.hair) h(f.mid)
    end
    h(W.divider)
    h(W.d_rail) h(W.d_rail_maybe) h(W.d_action) h(W.d_action_ul)
    h(W.title) h(W.count) h(W.close) h(W.status) h(W.status2)
    for _, c in ipairs(W.chips) do h(c.bg) h(c.tx) end
    for _, l in ipairs(W.lines) do
        h(l.bg) h(l.chip) h(l.ico) h(l.glabel) h(l.chip_tx) h(l.main) h(l.sub) h(l.right)
        h(l.prog_bg) h(l.prog_fill) h(l.prog_maybe)
    end
    h(W.d_bg) h(W.d_rule) h(W.d_title) h(W.d_where) h(W.d_meta) h(W.d_head)
    h(W.d_scr_bg) h(W.d_scr_th)
    for _, t in ipairs(W.d_lines) do
        h(t.a) h(t.n) h(t.b) h(t.g) h(t.c) h(t.h)
    end
end

function panel.destroy()
    hide_all()
    draw.destroy_all()
    W = {}
end

-- ---------------------------------------------------------------------------
-- Flattening
-- ---------------------------------------------------------------------------

--[[ Groups and rows are flattened into one list before drawing.

     Scrolling a tree whose nodes have different heights means every scroll step
     has to re-walk the tree to find out what is on screen. Flattening makes
     scroll a plain array offset and hit-testing a division, and collapse becomes
     "do not emit these entries", which is the whole feature. ]]
local function rebuild()
    local groups, total = model.groups(model.SETS[S.set] or model.SETS.accepted,
                                       S.filter)
    local lines = {}
    local handin = 0

    for _, g in ipairs(groups) do
        local n = #g.rows
        local hi = g.counts.turnin or 0
        handin = handin + hi
        lines[#lines + 1] = {kind = 'group', group = g, n = n, handin = hi}
        if not S.collapsed[g.key] then
            for j, r in ipairs(g.rows) do
                -- `zebra` is the ordinal within the region; see draw_row_line.
                lines[#lines + 1] = {kind = 'row', row = r, group = g,
                                     zebra = j}
            end
        end
    end

    S.lines, S.total, S.handin = lines, total, handin

    --[[ Selection follows the quest, not the line index. A rebuild happens on
         every 0x056 settle, and an index-based selection would silently jump to
         a different quest the moment one is handed in. ]]
    S.sel = nil
    if S.sel_key then
        for i, l in ipairs(lines) do
            if l.kind == 'row' and l.row.key == S.sel_key then S.sel = i break end
        end
        if not S.sel then
            S.sel_key, S.ladder = nil, nil
            S.notes, S.desc, S.dlines = nil, nil, nil
            S.dkey, S.dquest = nil, nil
        else
            --[[ The selected quest's ladder is re-derived here, and leaving it
                 out is a correctness bug rather than a staleness nicety.

                 A rebuild runs on every 0x056 settle, and the list row is
                 rebuilt from fresh data every time: `model.groups` allocates new
                 rows, so the progress bar and the step counter move as you play.
                 The detail pane needs the same. Clear `S.dkey` only when the
                 selection is lost and a selection that survives the rebuild
                 keeps the ladder it was given at selection time, forever, so the
                 two panes disagree about the same quest with the bar advancing
                 while the ladder still says "Step 2 of 7". Toggling a step does
                 not unfreeze it: that clears `S.dkey`, but the guard in
                 draw_detail then finds a populated ladder and skips the reload,
                 which is exactly what that guard is for.

                 Re-derived here rather than by clearing the guard, because this
                 is the only place that knows a rebuild happened. `S.dopen` and
                 `S.dscroll` are deliberately untouched: the ladder is new, but
                 which notes you had opened and where you were reading are still
                 yours. `S.dkey = nil` then forces the line list to be rebuilt
                 from the fresh ladder on the next draw. ]]
            local e = lines[S.sel].row.entry
            S.ladder = model.ladder(e)
            S.dkey = nil
        end
    end

    local max = math.max(0, #lines - LINES)
    if S.scroll > max then S.scroll = max end
    if S.scroll < 0 then S.scroll = 0 end
    S.dirty = false
end
panel.rebuild = rebuild

function panel.invalidate() S.dirty = true end

-- ---------------------------------------------------------------------------
-- Geometry
-- ---------------------------------------------------------------------------

local function geom()
    local g = {}
    g.x, g.y = S.x, S.y
    g.w = theme.list_width
    g.head_h = theme.header_h
    g.filter_y = g.y + g.head_h
    g.body_y = g.filter_y + theme.filter_h
    g.body_h = LINES * (theme.row_h + theme.row_gap)
    g.h = g.head_h + theme.filter_h + g.body_h + theme.pad
    g.dx = g.x + g.w + theme.pane_gap
    g.dw = theme.detail_width
    return g
end
panel.geom = geom

local function line_y(g, i)  -- i is 1..LINES within the viewport
    return g.body_y + (i - 1) * (theme.row_h + theme.row_gap)
end

-- ---------------------------------------------------------------------------
-- Drawing
-- ---------------------------------------------------------------------------

--[[ What was drawn this frame.

     A pool slot holds different kinds of content on different frames, and any
     widget the previous kind showed and the new kind never mentions stays on
     screen with stale data. Hiding every widget in the slot before drawing it is
     correct and costs a visibility toggle per widget per frame in both
     directions, which takes a static panel from issuing zero native calls to
     128.

     So the sweep is deferred instead of eager: drawing marks an object as used,
     and at the end of the slot anything unmarked is hidden. Untouched widgets
     that were already hidden stay hidden with no call at all, change detection
     survives, and a renderer still only has to know about what it draws. ]]
local touched = {}

local function set_rect(r, x, y, w, h, c)
    touched[r] = true
    r:pos(x, y); r:size(w, h); r:color(c.a, c.r, c.g, c.b); r:visible(true)
end

--[[ A pane background: the papyrus sheet multiplied down by `tint`, or the flat
     `fill` when the sheet is not on disk.

     The fallback is the whole point of this being a function. A prim whose texture
     will not load draws nothing at all and says nothing about it, so a missing or
     renamed sheet would leave the window invisible while still swallowing every
     click over it, which is the worst failure this panel can have and it is silent.
     `theme.bg_texture` returns nil in that case and the pane goes back to the flat
     colour.

     Both are handled here rather than at the two call sites so the two panes cannot
     end up disagreeing about which mode they are in. ]]
local function set_pane_bg(r, which, x, y, w, h, tint, fill)
    local tex = theme.bg_texture(which)
    if tex then
        r:texture(tex)
        set_rect(r, x, y, w, h, theme.surface(tint))
    else
        set_rect(r, x, y, w, h, theme.surface(fill))
    end
end

local function set_text(t, x, y, s, c, size, bold, stroke)
    touched[t] = true
    t:font(bold and theme.font_head or theme.font, size or theme.fs_name)
    t:bold(bold and true or false)
    --[[ The stroke comes from the theme rather than from the drawing floor, because a
         light background wants a different one. See ui/draw.lua's note. Set on every
         draw and change-detected, so a static frame still issues nothing.

         `stroke` overrides it for one string. Only the step titles use that, and only
         because they are the one string carrying a state hue rather than a tier of
         grey: a preset can want no halo on its prose and one on those. ]]
    local k = stroke or theme.col.stroke
    t:stroke(k.a, k.r, k.g, k.b)
    t:text(s); t:pos(x, y); t:color(c.a, c.r, c.g, c.b); t:visible(true)
end

--[[ The same, for the detail pane, whose outline is its own.

     `set_text` falls back to `theme.col.stroke`, which is the window's. For the three
     presets that dress the window as one thing that is the very table `theme.dcol` reads
     through to, so it is right by coincidence. Under `mixed` it is not: the pane is
     parchment, whose stroke is zero alpha because dark ink on a light page needs no
     halo, while the window is leather, whose stroke is a near-black at 235. Take the
     window's outline there and every string in the pane draws dark ink inside a dark
     halo.

     The pane reads `dcol` for its ink (see the note in draw_detail), so it has to read
     `dcol` for its outline too. ]]
local function set_dtext(t, x, y, s, c, size, bold, stroke)
    set_text(t, x, y, s, c, size, bold, stroke or theme.dcol.stroke)
end

local function draw_chips(g)
    --[[ Words with a hairline under the active one, not two shouting boxes.
         Bracketed capitals such as `[ACCEPTED]` are the panel at its most
         machine-like: brackets are how a program writes things, and capitals are
         the only place it raises its voice. The underline is a 1px rectangle,
         which is the only underline primitive available. ]]
    local defs = {
        {id = 'accepted', label = 'All'},
        {id = 'handin',   label = 'Ready'},
        {id = 'here',     label = 'Here'},
    }
    local x = g.x + theme.pad
    for i, d in ipairs(defs) do
        local c = W.chips[i]
        local on = (S.set == d.id)
        local tw = math.floor(width_of(d.label, theme.fs_action, true))
        local ty = theme.center_y(g.filter_y, theme.filter_h, theme.fs_action)
        set_text(c.tx, x, ty, d.label,
                 on and theme.col.gold or theme.col.text_faint,
                 theme.fs_action, true)
        if on then
            -- Below the descenders, not through them.
            set_rect(c.bg, x, theme.underline_y(ty, theme.fs_action), tw,
                     math.max(1, theme.s(1)), theme.col.gold)
        else
            c.bg:visible(false)
        end
        c.x, c.y, c.w, c.h = x, g.filter_y, tw, theme.filter_h
        c.id = d.id
        x = x + tw + theme.s(18)
    end
end

--[[ Hide everything in `w` that this frame did not draw into.

     A pool slot holds a quest row one frame and a region header the next. Any
     widget the previous kind made visible and the new kind never mentions stays
     on screen showing the old row's data. Rows draw a progress bar and headers
     do not, so scrolling a header into a slot that had held a row leaves the bar
     under the region name.

     Do not hide per widget inside each renderer. That needs every renderer to
     know about every widget every other renderer might touch, and it breaks
     silently the moment one gains a widget. Sweeping the slot makes the
     invariant structural: a renderer is responsible only for what it draws, and
     this asks the widget table what it holds. ]]
local function sweep(w)
    for _, o in pairs(w) do
        if type(o) == 'table' and type(o.visible) == 'function'
           and not touched[o] then
            o:visible(false)
        end
    end
end

local function draw_group_line(w, g, l, y, hovered)
    if hovered then
        set_rect(w.bg, g.x + theme.s(6), y, g.w - theme.s(16), theme.row_h,
                 theme.col.row_hover)
    end

    --[[ Three things in three columns, not one string.

         The fold glyph keeps `fold_x`; the region's badge sits in the next column; the
         label starts at `group_label_x` and quest rows are indented past it. See the
         note on the indent in ui/theme.lua.

         The badge is drawn, or the column is left empty. `theme.group_icon` returns nil
         both for a region with no artwork (Coalition) and for one whose file is missing,
         and the two want the same handling: hide the object. A prim with an unloadable
         texture draws nothing at all and says nothing about it, so the alternative is an
         invisible object sitting in a column nobody can see is occupied. ]]
    local sym = S.collapsed[l.group.key] and theme.sym.collapsed or theme.sym.expanded
    local cy = theme.center_y(y, theme.row_h, theme.fs_group)
    local ink = hovered and theme.col.text or theme.col.text_dim
    set_text(w.main, g.x + theme.fold_x, cy, sym, ink, theme.fs_group)

    local ico = theme.group_icon(l.group.key)
    if ico then
        w.ico:texture(ico)
        --[[ Full strength and untinted: `set_color` multiplies, so white is the
             identity and the artwork arrives as authored. ]]
        set_rect(w.ico, g.x + theme.group_ico_x,
                 y + math.floor((theme.row_h - theme.group_ico) / 2),
                 theme.group_ico, theme.group_ico,
                 {a = 255, r = 255, g = 255, b = 255})
    else
        w.ico:visible(false)
    end

    set_text(w.glabel, g.x + theme.group_label_x, cy,
             fit(l.group.name, theme.fs_group, g.w - theme.group_label_x - theme.s(60)),
             ink, theme.fs_group)

    --[[ The counter WoW puts in its title bar, put per region instead. "3" is
         how many are filed here; the accent half says how many of those you can
         hand in right now, which is the only number that changes what you do
         next.

         Only when the region is collapsed. Expanded, the rows are right there to
         be counted, and a number beside every header is a column of noise
         answering a question nobody asked. Collapsed, it is the only thing
         standing in for the hidden rows, so it earns its place. ]]
    if S.collapsed[l.group.key] then
        local right = tostring(l.n)
        local rw = math.floor(width_of(right, theme.fs_meta))
        set_text(w.right, g.x + theme.count_r - rw,
                 theme.center_y(y, theme.row_h, theme.fs_meta), right,
                 l.handin > 0 and theme.col.amber or theme.col.text_faint,
                 theme.fs_meta)
    else
        w.right:visible(false)
    end
end

local function draw_row_line(w, g, l, y, hovered, selected)
    local r = l.row
    local e = r.entry

    --[[ Zebra parity is the row's ordinal within its region, not its index in
         the flattened list and not the screen slot.

         Parity off the screen slot inverts the stripe pattern on every scroll
         notch, which actively fights the eye you are trying to help; chronicle
         does it that way at ui/widgets.lua:1054. The flattened index avoids that
         but has its own tell, because region headers occupy indices too, so a
         region with an odd number of rows flips the parity of every region below
         it. Numbering within the region is stable under both scrolling and
         folding. ]]
    local bg
    if selected then bg = theme.col.row_sel
    elseif hovered then bg = theme.col.row_hover
    else bg = ((l.zebra or 0) % 2 == 0) and theme.col.row_even
                                        or theme.col.row_odd end
    set_rect(w.bg, g.x, y, g.w, theme.row_h, bg)

    --[[ The marker glyph, on the category axis rather than the state axis.

         A coloured chip on every row carrying the marker state is confetti: on an
         accepted-only list 18 of 19 rows say "in progress" in the same grey, so it
         colours the rows you cannot act on exactly as loudly as the one you can.

         The same vocabulary read the other way round is worth the column, because
         it varies. The glyph's hue is the quest's category, which differs down the
         list. Brightness carries nothing: theme.category_colour returns alpha 255
         on every path, which the note below `state_style` states as a rule.

             yellow     quest
             green      mission
             red        Campaign

             blue       a repeatable this character has been seen to finish
                        before and has now taken again

         The blue is never inferred from the `repeatable` flag, which only says a
         quest can repeat. It is granted only where the addon has watched the
         completed bit set for that quest. See model.observe_completions for why
         the packet alone cannot say.

         The glyph is inverted relative to the world markers, deliberately, and
         ui/theme.lua sets the whole argument out above `state_style`. In short:
         questmarks reads `!` as "there is something here to take" and `?` as
         "you have accepted this", which does real work on an NPC where both are
         on screen at once. It does none here, because every row in this list is
         already accepted. So the slot carries what varies instead: `!` still
         working on it, `?` objectives complete. Readiness is the glyph, not the
         colour.

         Every value comes from `markers.style_for` through theme.state_style, so
         this cannot drift from what is drawn in the world. That was the whole
         argument for the chip and it is the part worth keeping.

         No light chip behind it. A chip is only wanted because `unknown` is
         near-black by design and vanishes on a dark panel; `unknown` is not in the
         accepted set, where only turnin and progress appear, and all six colours
         those produce are legible unbacked.

         It is drawn inside `stroke_hue`, which is what lets it keep questmarks'
         colour on a page as well as on a slab. This is the one string the list pane
         draws that carries a hue rather than a tier of grey, and the ring is the
         same answer the ladder reaches: over parchment the mark measures 1.11:1 to
         2.23:1 against the page and 4.91:1 to 12.94:1 against its own ring. Capping
         the hue's luminance instead does not work, because a quest yellow dark
         enough for cream is an olive. ]]
    local a, cr, cg, cb, glyph = theme.state_style(r.state, e.cat, e.area,
                                                   model.done_before(e))
    set_text(w.chip_tx, g.x + theme.mark_x,
             theme.center_y(y, theme.row_h, theme.fs_name), glyph,
             {a = a, r = cr, g = cg, b = cb}, theme.fs_name, true,
             theme.col.stroke_hue)

    local tx = g.x + theme.name_x
    local avail = theme.status_r - theme.name_x

    --[[ The right-hand tag is WoW's `(Daily)` slot, and it is used with the
         same restraint: only when there is something to say. `turnin` is the
         one state that changes what you do next, so it is the one that speaks.

         Completion is said in words, not by dimming the glyph. The glyph carries
         the category at full strength on every row, so it cannot also carry
         "done". A small tag immediately left of the progress bar does that
         instead, smaller than the row's own type because it qualifies the bar
         rather than competing with the quest name.

         It is also the redundant coding the design requires: colour is never the
         sole carrier of a state, and a `?` plus the word is legible to someone
         who cannot separate the hues at all. ]]
    local word = theme.state_label[r.state] or ''
    if word ~= '' then
        local ww = width_of(word, theme.fs_tag)
        set_text(w.right, g.x + theme.status_r - ww,
                 theme.center_y(y, theme.row_h, theme.fs_tag), word,
                 theme.col.text_dim, theme.fs_tag)
    else
        w.right:visible(false)
    end

    local dim = (r.state == 'blocked' or r.state == 'unknown')
    set_text(w.main, tx, theme.center_y(y, theme.row_h, theme.fs_name),
             fit(r.name or r.key, theme.fs_name, avail),
             dim and theme.col.text_faint or theme.col.text, theme.fs_name)

    --[[ The progress bar, which stands in for `[3/7]`.

         A bar rather than a fraction, for two reasons. FFXI's own HUD is made of
         bars, HP, MP, TP and experience, so a bar is native to the game in a way
         a right-aligned column of nineteen ratios is not; and reading nineteen
         ratios is exactly the labour this pane is trying to remove.

         More importantly, a bar can say something the fraction literally cannot:
         how much of the progress is certain. The solid part is steps whose
         evidence the client actually confirmed; the ghost part runs on to the
         highest step you might be on. `[3/7]` has no way to express that band,
         and this addon's whole honesty problem is that the band exists.

         A one-step quest gets no bar. A full bar on a single-step quest is a lie
         of precision. An unverifiable quest gets confirmed = 0 and ghost = full,
         which is visually distinct from both empty and complete and is the
         honest statement. ]]
    local wh = r.where or {}
    local total = wh.of
    if total and total > 1 then
        local px = g.x + theme.prog_x
        local py = y + math.floor((theme.row_h - theme.prog_h) / 2)
        set_rect(w.prog_bg, px, py, theme.prog_w, theme.prog_h,
                 theme.col.prog_track)
        local certain = math.max(0, (wh.step or 1) - 1)
        local cw = math.floor(certain / total * theme.prog_w)
        local mw = math.floor((wh.fog_end or wh.step or 1) / total * theme.prog_w)
        if r.state == 'unknown' then cw, mw = 0, theme.prog_w end
        if mw > cw then
            set_rect(w.prog_maybe, px + cw, py, mw - cw, theme.prog_h,
                     theme.col.prog_maybe)
        else
            w.prog_maybe:visible(false)
        end
        if cw > 0 then
            set_rect(w.prog_fill, px, py, cw, theme.prog_h, theme.col.prog_done)
        else
            w.prog_fill:visible(false)
        end
    else
        w.prog_bg:visible(false)
        w.prog_fill:visible(false)
        w.prog_maybe:visible(false)
    end

    w.sub:visible(false)
end

local function build_detail(r, e, g)
    --[[ The detail pane reads `theme.dcol`, not `theme.col`, and this alias is the
         whole convention. For every preset that dresses the window as one thing, `dcol`
         reads through to `col` and there is exactly one value; `mixed` puts parchment on
         this side and leather on the other, and only then do the two differ. ]]
    local D = theme.dcol
    local L = {}
    local inner = g.dw - theme.pad * 2

    local function add(t) L[#L + 1] = t end
    local function gap() add({gap = true}) end

    --[[ The game's own description, first, because it is the why. Wrapped to
         the pane with no line cap: the client's own copy is broken at the
         client's panel width, which has nothing to do with this one. ]]
    if S.desc then
        for _, ln in ipairs(wrap(S.desc, theme.fs_prose, inner, 99)) do
            add({b = ln, size = theme.fs_prose, col = D.text_dim,
                 x = pad})
        end
        gap()
    end

    --[[ The one rule in the panel, and it belongs after the description.

         It sits between the description and the ladder because that is the seam
         it marks: the game's words above, the addon's reading of them below. In
         the flow, so it lands wherever the description ends however long that
         is. Draw it at a fixed y instead and it cuts through the quest's
         category line and through "Show all notes". ]]
    add({rule = true})
    gap()

    local ladder = S.ladder
    if not ladder or not ladder.rows or #ladder.rows == 0 then
        add({b = 'No step ladder recorded for this quest.',
             size = theme.fs_sub, col = D.text_dim})
        return L
    end

    local idx = ladder.idx or 1

    --[[ The fog: how far ahead the ladder genuinely cannot see.

         A step only proves it is finished if it carries evidence, meaning an item
         or key item the client will report. 5623 of the index's 6858 steps
         (82.0%) carry none, and 4907 of those are still markable: "talk to
         someone" steps that point at a real NPC and leave no trace whatsoever.

         So every step from `idx` up to and including the next evidence-bearing
         one is equally consistent with where the player actually is. "Hat in
         Hand" is the pure case: step 1 has evidence, steps 2-10 have none, so
         after accepting it the ladder pins to step 2 and can never move again.
         696 entries, 48% of the corpus, have no evidence on any step. ]]
    local function has_evidence(row)
        local a, b = row.evidence, row.evidence_alt
        return (type(a) == 'table' and next(a) ~= nil)
            or (type(b) == 'table' and next(b) ~= nil)
    end
    local fog_end = idx
    for n = idx, #ladder.rows do
        fog_end = n
        if has_evidence(ladder.rows[n]) then break end
    end

    --[[ The position phrase is the header, and `Show all notes` sits on the same
         row, right-aligned.

         There is no separate "Steps" label: a numbered vertical list under a rule
         is self-evidently the steps, and a word that never changes carries no
         information. Both of these are in the flow rather than placed by hand at
         fixed coordinates near the top of the pane, which is what stops them
         colliding with the rule and with each other. ]]
    local head = (fog_end > idx)
        and ('Steps %d-%d of %d'):format(idx, fog_end, ladder.n or 0)
        or  ('Step %d of %d'):format(idx, ladder.n or 0)
    add({b = head, size = theme.fs_region, col = D.gold, bold = true,
         x = pad, action = true})

    --[[ Uncertainty stated once, in a sentence, about the range, and never
         smeared across the glyph column. Italic is reserved for this and nothing
         else in the panel, so the one italic line is unmistakably an aside. ]]
    if fog_end > idx then
        local cap = ('The game gives no signal between steps %d and %d. Any of them may be the one you are on.')
                    :format(idx, fog_end)
        for _, ln in ipairs(wrap(cap, theme.fs_zone, inner)) do
            add({b = ln, size = theme.fs_zone, col = D.amber_cap})
        end
    end
    gap()

    for i, row in ipairs(ladder.rows) do
        --[[ The mark scheme: three channels, one variable each.

             Ask the glyph column to state three things at once, how far along you
             are, whether a step is skippable, and whether the tracker is sure, and
             an optional step inside an uncertain run renders a fourth character
             between two `>` and reads as a mistake. That is the whole content of
             "why is step 4 not marked but 3 and 5 are".

             Axis A, progress, owns the glyph and its hue, and nothing else touches
             them. Its whole value is that it forms an unbroken run down the ladder,
             so it must be strictly ordinal:
                 done      x   green
                 candidate >   amber
                 not yet   -   grey

             Axis B, optionality, owns a 10px title indent and the trailing word
             `optional`. Never a glyph, never a hue. It is a fact about the step, not
             about your position.

             Axis C, uncertainty, is a property of a range, so it is stated once
             about the range, in the position phrase and the caption above the band,
             and never per step. Every step in the band gets a full-brightness `>`:
             the tracker is not more confident about the first of them than the last,
             so a dim variant inside the band would be dishonest.

             Any step below the lowest candidate renders `done` regardless of its
             optional flag. There is deliberately no fourth "passed but unverifiable"
             state: a strictly monotonic column is worth more than per-step truth
             about a step the player was free to skip. ]]
        local state
        if i < idx then state = 'done'
        elseif i <= fog_end then state = 'candidate'
        else state = 'todo' end

        --[[ The title takes the glyph's own colour. Green behind you, amber where you
             are, grey ahead, so the ladder's position reads at a glance instead of off
             a 5px character in a side column.

             This spends hue on a whole string, which the theme's budget does not do
             elsewhere, and the argument against spending it is confetti: saturated
             colour on the rows you cannot act on as loudly as the one you can. It is a
             weaker argument here than in the list. A ladder is one quest's steps in
             order, the three states form a run rather than a scatter, and there are
             three hues down a column rather than six across a list.

             Axis B gives up its brightness channel for it: an optional step does not
             sit one tier down, because that tier is the state. It keeps its 10px indent
             and its trailing `optional`, which are the two that scan.

             Every one of these three is held to the contrast floor by the suite on all
             four presets, in both columns. Two of them are the ladder's own roles
             rather than the panel's amber and green: over parchment these strings are
             bright and the list's `n ready` tally in the same amber cannot be, because
             these are drawn inside `stroke_hue` and it is bare. See ui/theme.lua. ]]
        local glyph, gc, tc
        if state == 'done' then
            glyph, gc = theme.sym.done, D.step_done
            tc = D.step_done
        elseif state == 'candidate' then
            glyph, gc = theme.sym.current, D.step_now
            tc = D.step_now
        else
            --[[ `step_todo` and not `text_faint`. They are the same grey on every
                 preset that does not split them; parchment does, because its zone and
                 requirement lines are prose read off the page and want a dark faint
                 ink, while a step ahead of you in that same dark ink reads as crossed
                 out rather than as pending. ]]
            glyph, gc = theme.sym.pending, D.step_todo
            tc = D.step_todo
        end

        --[[ Collapsible, with a default open set and no clicks required.

             A 7-step quest with every note expanded runs past the bottom of the
             pane, and the ladder then looks like it ends where the pane does. The
             scroll thumb is not enough of a signal, and the answer is less to
             scroll past rather than a louder thumb.

             Open by default: every step in the candidate band, and nothing else.
             That is aimed at the tracker's weakest moment. When it cannot tell
             which of several steps you are on, those notes are exactly the
             evidence you need to work it out. Steps behind you and steps far
             ahead collapse to one line each.

             A step with no note is not expandable: no hover, no cursor change,
             clicking does nothing. A click that opens nothing is worse than a
             control that is visibly absent. ]]
        local note = S.notes and S.notes[row.n]

        --[[ Only the note collapses. The location does not.

             Fold the location in with the note and a step whose zone matches the
             one above it and which has no note shows nothing at all, not even its
             map cell. On "Lure of the Wildcat", twelve consecutive talk-steps
             around Windurst, that erases the map reference on eight of them and
             leaves a column of bare names. Where a step is, is the step's primary
             payload; the note is the elaboration.

             So `expandable` is about the note alone, and the location line is
             emitted unconditionally below. Nothing about where a step is is
             conditional on anything, which is the same rule the location line
             itself argues.

             An explicit choice beats both defaults. `S.dopen[i]` is what the
             player said about this step; `showall` and the candidate band are only
             what to do when they have not said anything. Let `showall` come first
             and win outright and clicking a step to collapse it does nothing while
             `Show all notes` is on. Pressing `Show all notes` clears `S.dopen`, so
             the global still takes effect everywhere when it is pressed; it just
             does not overrule what you do afterwards. ]]
        local expandable = (note ~= nil)
        local open = expandable and (
            (S.dopen[i] ~= nil and S.dopen[i])
            or (S.dopen[i] == nil and (S.showall or state == 'candidate')))

        --[[ A verb phrase, and the object is not always the step's target.

             Build the phrase as verb plus `steps.row_label` and a step's meaning
             comes out backwards, because row_label returns the step's npc or,
             failing that, its mobs. "Tuning In" step 2 then reads

                 Obtain  Fomor Warrior, Fomor Monk, Fomor Dark Knight, ...

             On an `obtain` step the mobs are where the thing drops; the thing
             itself is in `ev`. The sentence wanted is questmarks' own questgraph
             reading:

                 Obtain  Extra-Fine File  from Fomor Warrior, Fomor Monk, ...

             The field that decides is the mob `role`, not the step kind. The index
             carries kill (684), drop (297) and spawn (242), and
             render/markers.lua switches its glyph on exactly this: a sword to kill
             it, a sack because it drops what the step needs.

                 kill   the mob is the object      -> "Defeat X"
                 drop   the mob is the source      -> "... from X"
                 spawn  the mob is what appears    -> "... spawns X"

             738 steps have mobs and no npc, so every one of them turns on this.
             The 446 `fight` and kill ones would be right either way, because for
             those the mob genuinely is the object. ]]
        local verb = KIND_VERB[row.kind]

        --[[ The object slot takes the npc and never a mob name.

             `steps.row_label` is the npc or, failing that, every mob name joined.
             It is role-blind by design, because it exists for `//qm why`'s target
             column where any target will do, so it must not reach a sentence here
             even as a fallback. Leave it in and it fires wherever the
             role-specific join comes up empty: a step with no npc, no kill mobs,
             and a drop or spawn mob.

             289 steps in the index are that shape, 96 obtain, 85 fight, 84 examine,
             23 trade and 1 other, and on every one of them a role-blind label names
             a mob the data says is a source or a spawn as the thing to act on. "The
             Three Magi" step 4 is the plain case: mobs = [drop: chaos elemental],
             no npc, so it reads `Defeat  Chaos Elemental` about a mob the step
             says drops something. `examine` is the visibly broken one, `Examine
             Chaos Elemental (spawns Chaos Elemental)`, the same name in both
             halves.

             Mobs reach the sentence only through the role-specific joins, and
             everything else through the source line. A step with neither an npc
             nor a kill mob gets the bare verb plus its own lines, which is less,
             and less is what this addon says when it does not know. The drop-source
             assertion in tools/smoke.lua sweeps the titles for drop-mob names, so
             a regression here fails the suite. ]]
        local label = (row.npc and row.npc ~= '')
                      and model.nice_name(row.npc) or nil

        --[[ Mobs by role, so each group can be phrased as what it is. ]]
        local by_role = {}
        --[[ steps.explain does not carry `mobs`, so they come from the entry's
             own step array, indexed by the row's own step number rather than by
             the loop counter. They are equal today and `row.n` is the one that is
             guaranteed to mean it. ]]
        local raw = e.steps and e.steps[row.n]
        for _, m in ipairs((raw and raw.mobs) or {}) do
            local rl = m.role or 'kill'
            by_role[rl] = by_role[rl] or {}
            if m.name then
                by_role[rl][#by_role[rl] + 1] = model.nice_name(m.name)
            end
        end
        local function joined(rl, cap)
            local t = by_role[rl]
            if not t or #t == 0 then return nil end
            if cap and #t > cap then
                return table.concat(t, ', ', 1, cap)
                       .. (' and %d more'):format(#t - cap)
            end
            return table.concat(t, ', ')
        end

        --[[ What the step gives you, named. Falls back to saying nothing rather
             than to printing a resource id. ]]
        local granted = resnames.list(row.evidence, 4)

        --[[ The object of each verb, per questgraph's own `KIND_SENTENCE` table
             (questmarks/tools/questgraph/web/quest.js), whose second element is
             the target type:

                 talk / trade / turnin / cutscene / other -> npc
                 examine                                  -> object (in `npc`)
                 travel                                   -> zone
                 fight / obtain / wait                    -> none

             `travel` is the one that has to be read off the table rather than
             guessed: 332 of its 396 steps carry no npc at all, so taking the npc
             as the object gives a bare "Travel to" with the destination on the
             line below. The destination is the object. ]]
        local zone_name = row.zone and model.zone_name(row.zone) or nil
        local used_zone = false

        local body
        if row.kind == 'travel' then
            local dest = label or zone_name
            body = verb .. (dest and ('  ' .. dest) or '')
            used_zone = (dest ~= nil and dest == zone_name)
        elseif row.kind == 'cutscene' then
            --[[ "Watch a cutscene" alone is true but useless; it is always
                 somewhere, and the somewhere is the only actionable half. ]]
            local at = label or zone_name
            body = verb .. (at and ('  at ' .. at) or '')
            used_zone = (at ~= nil and at == zone_name)
        elseif KIND_INTRANSITIVE[row.kind] then
            body = verb
        elseif row.kind == 'obtain' then
            --[[ The object is the item, and the item alone. Fold the mobs it
                 drops from into this sentence and it reads "Obtain Extra-Fine
                 File from Fomor Warrior, Fomor Monk, Fomor Dark Knight, Fomor
                 Paladin, Fomor Samurai", which is 96 characters and three
                 wrapped lines for one step, and the five Fomors are the least
                 useful part of it. They get a line of their own, the same move
                 the requirement ledger makes: see the source line below. With
                 neither item nor label the verb alone plus the location is still
                 true, which is the point of not inventing a target. ]]
            body = verb .. '  ' .. (granted or label or '')
        elseif row.kind == 'fight' then
            body = verb .. '  ' .. (joined('kill', 5) or label or '')
        elseif label then
            body = verb and (verb .. '  ' .. label) or label
        elseif granted then
            body = (verb or 'Obtain') .. '  ' .. granted
        else
            body = verb or 'Step'
        end
        body = body:gsub('%s+$', '')

        --[[ A spawn mob is neither the object nor the source. It is what your
             action produces, so it is appended rather than folded in.

             Deliberately in the title, unlike the drop mobs below. 146 of the 181
             steps carrying one are `examine`, where the whole step is "touch this
             and something appears" and splitting the appearing thing off the
             sentence would leave two half-instructions. It is also short: one mob
             name, capped at three. If that stops being true it should move to a
             line of its own the same way. ]]
        local spawns = joined('spawn', 3)
        if spawns then body = body .. '  (spawns ' .. spawns .. ')' end

        --[[ `optional` is its own right-aligned element at the tag column, not
             three spaces appended to the title. Appended, the tags land wherever
             the name happens to end, so "which steps can I skip" stops being a
             single vertical scan, which is the only reason to have a tag column
             at all. ]]
        local tag = row.optional and 'optional' or nil

        --[[ The affordance: a chevron in its own right-hand column.

             Appending '...' to the title reads as "this text was truncated"
             rather than "this opens", and says nothing at all once the step is
             open. A chevron is the convention every accordion uses, it is
             unambiguous in both states, and it sits in a fixed column so "which
             steps have more" is one vertical scan.

             `v` and `^` because the panel is single-byte ASCII, with no drawing
             characters and no arrows. They cannot be confused with the step
             glyphs (`x` / `>` / `-`), which live at the far left in their own
             column. ]]
        local tx = row.optional and theme.d_title_opt or theme.d_title
        local chev = expandable and (open and '^' or 'v') or nil

        --[[ A long step title wraps; it does not get cut.

             The target name is the instruction. Truncate it and "Cavernous
             Maws" step 1 reads "Speak with Cavernous Maw In Batallia Dow..",
             which removes the half that says which maw and where. The pane
             scrolls, so there is no reason to clip.

             Continuation lines carry no glyph and no number, and sit at the
             title's own x so the block reads as one item. Only the first line is
             the click target, which is what `step` marks.

             It wraps to what is left after the right-hand columns, both of them.
             Reserve room for the `optional` tag and not for the chevron and a
             title long enough to reach the content edge runs straight under the
             `v`. The drawing layer right-aligns the tag to the left of the
             chevron, so both sides go through `chev_width` and cannot drift
             apart. That is the whole reason it is a function rather than a number
             written out twice. ]]
        local avail = theme.d_tag_r - tx - (chev and chev_width() or 0)
                      - (tag and theme.s(60) or 0)
        local blines = wrap(body, theme.fs_step, avail)
        --[[ `stroke` on the title and its continuations only. See set_text: a coloured
             string at 11pt over a light page wants an outline that the prose beneath it
             does not. ]]
        add({glyph = glyph, gcol = gc, num = tostring(row.n),
             b = blines[1] or body,
             col = tc, tag = tag, chev = chev, stroke = D.stroke_hue,
             size = theme.fs_step, x = tx, step = i, band = (state == 'candidate'),
             expandable = expandable, open = open})
        for k = 2, #blines do
            add({b = blines[k], col = tc, size = theme.fs_step, x = tx,
                 stroke = D.stroke_hue})
        end

        --[[ The needs line, above the location and below the title.

             Above the location because it decides whether going is worth it at
             all: a trade step you cannot satisfy is not a place to walk to yet,
             and the map cell is the addressing rather than the instruction.

             At `theme.d_title`, the standard title column, and not under the
             optional indent. That is the rule the location and note lines follow
             too, because carrying Axis B's indent into the lines beneath makes
             optional steps look nested.

             Its own weight: the location line's size, one step brighter in ink.
             That places it between the title and the map cell without spending a
             hue, which the colour budget does not have to give.

             `needs = true` marks the kind of line, the way `step`, `gap`, `rule`
             and `action` do. tools/smoke.lua reassembles a wrapped requirement
             from it and checks the drawing against the rule's own output; nothing
             in the addon reads it. ]]
        local needs = needs_line(raw)
        if needs then
            for _, ln in ipairs(wrap(needs, theme.fs_zone,
                                     theme.d_tag_r - theme.d_title)) do
                add({b = ln, size = theme.fs_zone, col = D.text_dim,
                     x = theme.d_title, needs = true})
            end
        end

        --[[ Where it drops from, on its own line, for every kind that has one.

             Folded into the `obtain` sentence, it makes the longest titles in the
             panel: "Obtain Extra-Fine File from Fomor Warrior, Fomor Monk, Fomor
             Dark Knight, Fomor Paladin, Fomor Samurai" wraps to three lines and one
             of them runs under the chevron.

             Folded in there and nowhere else, 120 steps throw the field away.
             `fight` renders only its kill mobs and `trade` only its npc, so the
             drop mobs on 89 fight and 31 trade steps reach nothing at all.
             `quest/sandoria/79` step 2 is the case that makes it plain: trade 2
             Shaman Garlic to Maloquedil, and the garlic drops from Orcish
             Cursemakers.

             `Drops from` is questgraph's own verb for the role (`ROLE_VERB.drop`
             in tools/questgraph/web/quest.js), so the wording needs no defending.
             Capped at 5, because one step lists thirteen gigas, and the shortfall
             counted rather than dropped silently.

             After `Needs`, not before. On a trade or fight step the drop mobs are
             where the requirement comes from, so the two read as one thought in
             that order; on an obtain step they relate to the title instead and the
             requirement sits between, which costs those 9 steps a little and
             gains the 120 a lot. ]]
        local source = joined('drop', 5)
        if source then
            for _, ln in ipairs(wrap('Drops from  ' .. source, theme.fs_zone,
                                     theme.d_tag_r - theme.d_title)) do
                add({b = ln, size = theme.fs_zone, col = D.text_dim,
                     x = theme.d_title, source = true})
            end
        end

        --[[ Where the step is, in full, on every step that has a zone.

             Suppressing the zone name when it matches the step above stops
             "Windurst Waters" appearing eight times, and it is still the wrong
             trade. The corpus says so rather than taste: "Lure of the Wildcat
             (Jeuno)" crosses four zones, Upper Jeuno, Ru'Lude Gardens, Lower Jeuno
             and Port Jeuno, and grid letters repeat across all of them. `G-8` is
             step 3 in Ru'Lude Gardens, step 9 in Upper Jeuno and step 17 in Port
             Jeuno. Sixteen of its 22 steps would show a bare grid reference.

             The chain is technically sound, since each suppressed line does follow
             a named one, but it only reads if the whole chain is on screen and that
             ladder is 75 lines in a 33-line pane. Scroll to step 8 and the screen
             says `G-8` with nothing above it to attach that to. A coordinate with no
             place attached is not a shorter answer, it is a different and useless
             one.

             `travel` and `cutscene` still drop to the grid alone, and that is not
             the same rule. Those two consume the destination into the sentence
             itself, "Travel to Ranguemont Pass", so naming it again immediately
             below would be saying it twice on one step. ]]
        local loc
        if used_zone then
            loc = row.grid or nil
        elseif row.zone then
            loc = model.zone_name(row.zone)
                  .. (row.grid and ('  ' .. row.grid) or '')
        elseif row.grid then
            loc = row.grid
        end
        --[[ At the standard title column, not under the optional indent. The
             indent is Axis B and it applies to the step's title only; carry it
             into the zone and note lines and an optional step gets a second,
             deeper indent that makes the ladder look like it has nested itself.
             Both of these sit at the same x as a non-optional title. ]]
        if loc then
            add({b = loc, size = theme.fs_zone,
                 col = D.text_faint, x = theme.d_title})
        end

        --[[ The note, in full. Shown for the fog, meaning the steps you might be
             on, and for anything unmarkable, where the world shows nothing at
             all. Never capped, see the header. ]]
        if open and note then
            local nx = theme.d_title + theme.s(10)
            for _, ln in ipairs(wrap(note, theme.fs_prose,
                                     theme.d_tag_r - nx)) do
                add({b = ln, size = theme.fs_prose, x = nx,
                     col = D.text_dim})
            end
        end
        if i < #ladder.rows then gap() end
    end

    return L
end

local function draw_detail(g)
    local D = theme.dcol          -- see build_detail
    local l = S.sel and S.lines[S.sel]
    if not l or l.kind ~= 'row' then
        --[[ Nothing is drawn when no quest is selected: no frame, no rule, no
             empty ladder. An empty pane with furniture in it looks broken; an
             absent pane looks deliberate, and the list is wider for it. ]]
        W.d_bg:visible(false); W.d_rule:visible(false)
        W.d_title:visible(false); W.d_where:visible(false)
        W.d_meta:visible(false); W.d_head:visible(false)
        W.d_scr_bg:visible(false); W.d_scr_th:visible(false)
        W.d_rail:visible(false); W.d_rail_maybe:visible(false)
        W.d_action:visible(false); W.d_action_ul:visible(false)
        S.action_hit = nil
        for _, t in ipairs(W.d_lines) do
            t.a:visible(false); t.n:visible(false); t.b:visible(false)
            t.g:visible(false); t.c:visible(false); t.h:visible(false)
        end
        return
    end

    local r, e = l.row, l.row.entry
    local x, y = g.dx, g.y
    local pad = theme.pad
    local inner = g.dw - pad * 2
    set_pane_bg(W.d_bg, 'detail', x, y, g.dw, g.h, D.detail_tint,
                D.detail_bg)
    -- Title clears the pane's own 7px top band.

    --[[ Title and category are pinned, outside the scroll region. Scrolling a
         list until you cannot see what you are looking at is the one thing a
         detail pane must not do. ]]
    set_dtext(W.d_title, x + pad, y + theme.s(11),
              fit(r.name or r.key, theme.fs_title, inner),
              D.text, theme.fs_title, true)

    local _, region = model.region_of(e)
    local meta = region
    if e.lvl and e.lvl > 0 then meta = meta .. '   Lv' .. e.lvl .. '+' end
    if e.repeatable then meta = meta .. '   repeatable' end
    set_dtext(W.d_meta, x + pad, y + theme.s(31),
              fit(meta, theme.fs_meta, inner),
              D.text_faint, theme.fs_meta)

    W.d_rule:visible(false)      -- the rule is drawn as a line in the flow

    --[[ Rebuilt only when the selection changes. It wraps every note and walks
         the whole ladder, so it must not run per frame; the wheel moves an
         integer and nothing else.

         A rebuild is triggered by two different things and they want different
         scroll behaviour: selecting another quest starts at the top, while
         opening or closing a step must leave you where you were reading. ]]
    if S.dkey ~= r.key then
        --[[ `not S.ladder` is the load-bearing half of this condition.

             `S.dquest` exists so that toggling a step rebuilds the lines without
             re-walking the ladder. Test it alone and deselecting a quest clears
             S.ladder while leaving S.dquest naming it, so reselecting the same
             quest takes the "nothing to reload" branch with a nil ladder and
             renders "No step ladder recorded for this quest." for a quest that
             just showed one.

             Keying on the cache being populated rather than on a parallel
             variable staying in sync removes the whole class: it cannot be wrong
             about whether the data is there, because it looks. ]]
        local same_quest = (S.dquest == r.key) and S.ladder ~= nil
        if not same_quest then
            S.ladder = model.ladder(e)
            S.notes = model.notes_for(e)
            S.desc = model.description_for(e)
            S.dopen = {}
            S.dscroll = 0
        end
        S.dlines = build_detail(r, e, g)
        S.dkey, S.dquest = r.key, r.key
    end

    --[[ How many lines are actually drawn, which is the smaller of what fits in
         the pane and what the widget pool holds.

         Take it from the pane height alone and it silently eats the end of every
         long ladder: the draw loop runs to DETAIL_LINES, so any line past the
         pool is never drawn, and `S.dvisible` then tells `dscroll_by` to clamp
         its maximum at `total` minus a count the pane cannot show, which decides
         a full-pane quest has nothing below the fold and refuses to scroll at
         all.

         The pool is the real limit, so the pool is what the scroll maths must
         use. ]]
    local top = y + theme.s(52)
    local avail = (y + g.h - theme.pad) - top
    local rows = math.max(1, math.min(math.floor(avail / DPITCH), DETAIL_LINES))
    S.dvisible = rows

    --[[ Every line's recorded y is cleared before the window is drawn.

         `d.y` is written only for lines actually drawn, and `panel.step_at` walks
         the whole list looking for the first line whose recorded y contains the
         cursor. Leave the old values in place and a line scrolled out of the
         window keeps the y it had when it was last on screen, still claims the
         cursor's y, and `ipairs` reaches it first: clicking a step then toggles a
         different step, and the hover band lights the wrong row or none at all.

         Clearing first makes "has a y" mean "is on screen this frame", which is
         the property step_at needs. ]]
    for _, d in ipairs(S.dlines or {}) do d.y = nil end

    local n = #(S.dlines or {})
    local maxs = math.max(0, n - rows)
    if S.dscroll > maxs then S.dscroll = maxs end
    if S.dscroll < 0 then S.dscroll = 0 end

    W.d_head:visible(false)
    W.d_where:visible(false)

    for i = 1, DETAIL_LINES do
        local t = W.d_lines[i]
        local d = (i <= rows) and S.dlines[S.dscroll + i] or nil
        if not d or d.gap then
            t.a:visible(false); t.n:visible(false); t.b:visible(false)
            t.g:visible(false); t.c:visible(false); t.h:visible(false)
        else
            local ly = top + (i - 1) * DPITCH
            d.y = ly

            --[[ A rule is a rectangle. There is no rule primitive and no
                 box-drawing character available, and a row of hyphens is the
                 loudest terminal cue there is.

                 Written as an if/else rather than an early `goto continue`:
                 the game runs PUC-Rio Lua 5.1, which has no goto and no labels.
                 See the note on the Lua dialect at the top of this file. ]]
            if d.rule then
                t.a:visible(false); t.n:visible(false); t.b:visible(false)
                t.g:visible(false); t.c:visible(false)
                set_rect(t.h, x + pad, ly + math.floor(DPITCH / 2), inner,
                         math.max(1, theme.s(1)), D.rule)
            else

            --[[ The hover band, which is what announces that a step collapses.
                 A row that lights up under the pointer is how every list in every
                 game says "this is a control", and it costs one rectangle that is
                 already pooled. ]]
            if d.step and d.expandable and S.hover_step == d.step then
                --[[ Sized to the measured ink box of the step title, not to the
                     line pitch. The pitch is 13 px while an 11 pt line box is
                     19.5 px and its glyphs sit 5 px down inside that, so a band
                     drawn at the pitch lands above its own text. ]]
                local iy = theme.ink_y(d.size or theme.fs_step)
                local ih = theme.ink_h(d.size or theme.fs_step)
                set_rect(t.h, x + pad, ly + iy - theme.s(3), inner,
                         ih + theme.s(6), D.row_hover)
            else
                t.h:visible(false)
            end

            --[[ Three fixed columns, not one concatenated string.

                 Draw the mark and the number as one left-aligned string, "> 10",
                 and a two-digit number in a proportional face is wider than a
                 one-digit one, so from step 10 onward it pushes into the title and
                 renders "> 10Talk to Chomomo". Lure of the Wildcat reaches step 22.

                 Fixed columns instead: glyph at a fixed x, number right-aligned to
                 a fixed x, title at a fixed x. This is the whole reason a
                 proportional face is workable here. Windower places every object at
                 an absolute x, so a column is a decision, not a property of the
                 font.

                 The glyph and the number take the title's outline, not the pane's.
                 They are the same state hue as the title beside them, over
                 parchment a bright one on a bright page, and `stroke` there is zero
                 alpha, so without this they would be the two strings in the ladder
                 the halo does not reach. The contrast sweep's outline path assumes
                 they have one. ]]
            if d.glyph then
                set_dtext(t.a, x + theme.d_glyph, ly, d.glyph,
                          d.gcol or D.text, theme.fs_step, true, d.stroke)
                local nw = width_of(d.num, theme.fs_meta)
                set_dtext(t.n, x + theme.d_num_r - nw,
                          ly + theme.s(2), d.num,
                          d.gcol or D.text_faint, theme.fs_meta, false, d.stroke)
            else
                t.a:visible(false); t.n:visible(false)
            end

            if d.b and d.b ~= '' then
                set_dtext(t.b, x + (d.x or theme.pad), ly, d.b,
                          d.col or D.text, d.size or theme.fs_sub,
                          d.bold, d.stroke)
            else
                t.b:visible(false)
            end

            --[[ Right-aligned extras: the `optional` tag on a step, and
                 `Show all notes` on the position-phrase row. Both land in one
                 column at the content edge, which is what makes them scannable
                 and what stops them colliding with the pane divider. The chevron
                 owns the far-right column and the `optional` tag is right-aligned
                 to the left of it, so the two never collide. ]]
            local chev_w = 0
            if d.chev then
                -- The same column the title was wrapped against. See chev_width.
                chev_w = chev_width()
                local cy = theme.center_y(ly + theme.ink_y(d.size or theme.fs_step),
                                          theme.ink_h(d.size or theme.fs_step),
                                          theme.fs_meta)
                set_dtext(t.c, x + theme.d_tag_r - width_of(d.chev, theme.fs_meta, true),
                          cy, d.chev,
                          (S.hover_step == d.step) and D.gold
                                                    or D.text_faint,
                          theme.fs_meta, true)
            else
                t.c:visible(false)
            end

            if d.tag then
                local gw = width_of(d.tag, theme.fs_meta)
                set_dtext(t.g, x + theme.d_tag_r - chev_w - gw,
                          ly + theme.s(2), d.tag,
                          D.text_faint, theme.fs_meta)
            elseif d.action then
                local label = S.showall and 'Hide all notes' or 'Show all notes'
                local lw = width_of(label, theme.fs_action, true)
                local ax = x + theme.d_tag_r - lw
                set_dtext(t.g, ax, ly, label, D.gold,
                          theme.fs_action, true)
                S.action_hit = {x = ax, y = ly, w = lw,
                                h = theme.line_h(theme.fs_action)}
                if S.action_hover then
                    set_rect(t.h, ax, theme.underline_y(ly, theme.fs_action),
                             lw, math.max(1, theme.s(1)), D.gold)
                end
            else
                t.g:visible(false)
            end
            end   -- `if d.rule then ... else`
        end
    end

    --[[ The uncertainty rail.

         Uncertainty is a property of a range of steps, so it is drawn as a range:
         a 3px amber rect running beside the candidate band, over a 1px dim rail
         that runs the whole ladder. That is the third axis of the mark scheme, and
         keeping it off the glyph column is what stops "why is step 4 not marked
         but 3 and 5 are". A per-step glyph cannot state a range-level fact without
         lying about the steps inside it.

         The rail colour is the active amber at low alpha. There is no fourth
         colour to learn, and "less certain" simply looks fainter. ]]
    local first_y, last_y, band_top, band_bot
    for i = 1, rows do
        local d = S.dlines[S.dscroll + i]
        if d and d.y and not d.gap then
            if d.step then
                first_y = first_y or d.y
                last_y = d.y + DPITCH
            end
            if d.band and d.step then
                band_top = band_top or d.y
                band_bot = d.y + DPITCH
            end
        end
    end
    if first_y then
        set_rect(W.d_rail, x + theme.d_rail, first_y, 1,
                 (last_y or first_y) - first_y, D.rail)
    else
        W.d_rail:visible(false)
    end
    if band_top then
        set_rect(W.d_rail_maybe, x + theme.d_rail - 1, band_top, theme.s(3),
                 band_bot - band_top, D.rail_maybe)
    else
        W.d_rail_maybe:visible(false)
    end

    -- Scroll indicator, only when there is something off the bottom.
    if n > rows then
        local tx = x + g.dw - theme.scroll_w
        set_rect(W.d_scr_bg, tx, top, theme.scroll_w, rows * DPITCH,
                 D.scroll_bg)
        local th = math.max(theme.s(12),
                            math.floor(rows * DPITCH * rows / n))
        local off = maxs > 0 and (S.dscroll / maxs) or 0
        set_rect(W.d_scr_th, tx, top + math.floor((rows * DPITCH - th) * off),
                 theme.scroll_w, th, D.scroll_th)
    else
        W.d_scr_bg:visible(false); W.d_scr_th:visible(false)
    end
end

function panel.render()
    if not S.open then return end
    build_pool()
    for k in pairs(touched) do touched[k] = nil end
    if S.dirty then rebuild() end

    local g = geom()

    --[[ Window chrome, and each pane is its own framed window.

         A flat rectangle floating over a 3D world reads as a div, not as a
         window. Everything that fixes that is a rectangle, because rectangles
         are all there is: no rounded corners, no gradient, no drop shadow. The
         primitives do not exist and square corners are FFXI-native anyway.

           * a 1px black outer border, which is the substitute for the shadow
             the platform cannot draw and is what stops the panel bleeding into
             a bright zone;
           * a top band of three stacked flat rects, a light hairline, a
             mid-tone strip, then the header fill. Not twenty rects faking a
             ramp; three tones read as moulding and cost three objects.

         Six rectangles per pane, and each pane gets its own set. Span the border
         and the top band from the list's left edge to the detail pane's right
         edge and the two read as one shape with a seam rather than as two pages.
         Framing each separately is what leaves the gap visible, and it is what
         lets the detail pane be simply absent when nothing is selected rather
         than a frame with a hole in it. ]]
    local function frame(f, fx, fy, fw, fh)
        set_rect(f.t, fx - 1, fy - 1, fw + 2, 1, theme.col.border)
        set_rect(f.b, fx - 1, fy + fh, fw + 2, 1, theme.col.border)
        set_rect(f.l, fx - 1, fy - 1, 1, fh + 2, theme.col.border)
        set_rect(f.r, fx + fw, fy - 1, 1, fh + 2, theme.col.border)
        set_rect(f.hair, fx, fy, fw, 1, theme.col.band_hair)
        set_rect(f.mid, fx, fy + 1, fw, theme.s(6), theme.col.band_mid)
    end
    local function unframe(f)
        f.t:visible(false); f.b:visible(false); f.l:visible(false)
        f.r:visible(false); f.hair:visible(false); f.mid:visible(false)
    end

    frame(W.frame[1], g.x, g.y, g.w, g.h)
    if S.sel then frame(W.frame[2], g.dx, g.y, g.dw, g.h)
    else unframe(W.frame[2]) end
    W.divider:visible(false)

    set_pane_bg(W.bg, 'list', g.x, g.y, g.w, g.h, theme.col.panel_tint,
                theme.col.panel_bg)
    set_rect(W.head_bg, g.x, g.y + theme.s(7), g.w, g.head_h - theme.s(7),
             theme.surface(theme.col.header_bg))

    local hs_y, hs_h = g.y + theme.s(7), g.head_h - theme.s(7)
    set_text(W.title, g.x + theme.pad,
             theme.center_y(hs_y, hs_h, theme.fs_title), 'Quest Log',
             theme.col.text, theme.fs_title, true)

    --[[ The counter. WoW's is "17/20", accepted over a hard cap, and FFXI
         publishes no such cap to an addon, so inventing a denominator would be
         a guess printed as a fact. What stands in for it is the number that
         changes behaviour: how many of these you can hand in right now. ]]
    local cnt
    if model.status == 'ok' and not model.state_ready() then
        cnt = 'loading'
    else
        cnt = ('%d accepted'):format(S.total)
        if S.handin > 0 then cnt = cnt .. ('   %d ready'):format(S.handin) end
    end
    --[[ The close button is its own click target (on_mouse reserves the last
         24 px of the header), so the counter must clear it by more than its
         glyph width or the 'x' lands on the final character and the rasteriser
         renders "10 acceptex".

         Both are right-aligned by measurement against the same edge, with the
         close glyph's own measured width reserving its column. Hand-picked
         offsets are what put the 'x' on top of the counter's last character. ]]
    local xw = width_of(theme.sym.close, theme.fs_title, true)
    local close_x = g.x + g.w - theme.pad - xw
    set_text(W.close, close_x, theme.center_y(hs_y, hs_h, theme.fs_title),
             theme.sym.close, theme.col.text_faint, theme.fs_title, true)
    local cw = width_of(cnt, theme.fs_count)
    set_text(W.count, close_x - theme.s(12) - cw,
             theme.center_y(hs_y, hs_h, theme.fs_count), cnt,
             S.handin > 0 and theme.col.amber or theme.col.text_dim,
             theme.fs_count)

    draw_chips(g)

    -- Status line replaces the list when there is nothing honest to show.
    --[[ Empty and loading states are sentences, not labels. Each one says what
         is true and, where there is one, what to do about it. An empty list with
         no explanation is indistinguishable from a broken addon. ]]
    local note = nil
    if model.status ~= 'ok' then
        note = model.detail or ('questmarks unavailable (' .. model.status .. ')')
    elseif not model.state_ready() then
        note = 'Reading your quest log...'
    elseif #S.lines == 0 then
        if S.filter ~= '' then
            note = ('Nothing on your list matches "%s".'):format(S.filter)
        elseif S.set == 'handin' then
            note = 'Nothing is ready to hand in right now.'
        else
            note = 'You have no accepted quests. Take one from an NPC and it '
                   .. 'will show up here.'
        end
    end

    if note then
        local lines = wrap(note, theme.fs_prose, theme.s(340))
        set_text(W.status, g.x + theme.name_x, g.body_y + theme.s(6),
                 lines[1] or note, theme.col.text_dim, theme.fs_prose)
        if lines[2] then
            set_text(W.status2, g.x + theme.name_x,
                     g.body_y + theme.s(6) + theme.s(17), lines[2],
                     theme.col.text_dim, theme.fs_prose)
        else
            W.status2:visible(false)
        end
        for _, l in ipairs(W.lines) do sweep(l) end
        W.scr_bg:visible(false); W.scr_th:visible(false)
        draw_detail(g)
        return
    end
    W.status:visible(false); W.status2:visible(false)

    for i = 1, LINES do
        local w = W.lines[i]
        local idx = S.scroll + i
        local l = S.lines[idx]
        if not l then
            sweep(w)
        else
            l.idx = idx
            local y = line_y(g, i)
            local hovered = (S.hover == idx)
            if l.kind == 'group' then
                draw_group_line(w, g, l, y, hovered)
            else
                draw_row_line(w, g, l, y, hovered, S.sel == idx)
            end
            sweep(w)
        end
    end

    -- Scroll indicator: shown only when there is something off-screen.
    if #S.lines > LINES then
        local tx = g.x + g.w - theme.scroll_w
        set_rect(W.scr_bg, tx, g.body_y, theme.scroll_w, g.body_h,
                 theme.col.scroll_bg)
        local frac = LINES / #S.lines
        local th = math.max(theme.s(12), math.floor(g.body_h * frac))
        local maxs = #S.lines - LINES
        local off = maxs > 0 and (S.scroll / maxs) or 0
        set_rect(W.scr_th, tx, g.body_y + math.floor((g.body_h - th) * off),
                 theme.scroll_w, th, theme.col.scroll_th)
    else
        W.scr_bg:visible(false); W.scr_th:visible(false)
    end

    draw_detail(g)
end

-- ---------------------------------------------------------------------------
-- Interaction
-- ---------------------------------------------------------------------------

function panel.show(v)
    if v == nil then v = not S.open end
    S.open = v and true or false
    if not S.open then
        hide_all()
    else
        S.dirty = true
    end
    return S.open
end

function panel.is_open() return S.open end

--[[ Is this point over the window? False whenever the panel is closed.

     Exists for ui/launcher.lua, which must not claim a click the panel would.
     There is no z-order control on this platform, so where the two overlap the
     only safe rule is that the big certain thing wins. The detail pane counts
     only when something is selected, because that is exactly when it is drawn:
     draw_detail hides every one of its objects otherwise, and a claim over a
     pane that is not on screen would make a strip of empty screen swallow
     clicks. ]]
function panel.claims(x, y)
    if not S.open then return false end
    local g = geom()
    if x >= g.x and x <= g.x + g.w and y >= g.y and y <= g.y + g.h then
        return true
    end
    if S.sel and x >= g.dx and x <= g.dx + g.dw
       and y >= g.y and y <= g.y + g.h then
        return true
    end
    return false
end

function panel.scroll_by(n)
    local max = math.max(0, #S.lines - LINES)
    S.scroll = math.max(0, math.min(max, S.scroll + n))
end

--[[ Scroll the detail pane's flattened line list. Clamped against what was
     actually laid out last frame (`S.dvisible`), because how many lines fit
     depends on the pane height and the scale. ]]
function panel.dscroll_by(n)
    local total = #(S.dlines or {})
    local max = math.max(0, total - (S.dvisible or 1))
    S.dscroll = math.max(0, math.min(max, (S.dscroll or 0) + n))
end

--[[ Toggle one step open or closed. `nil` in `dopen` means "use the default", so an
     explicit false is meaningfully different from absent: closing a step that
     defaults to open must stick.

     It flips what is on screen, and the default is never recomputed here.
     Re-deriving it as `not (i >= idx)` looks equivalent to build_detail's
     `state == 'candidate'`, which is `i >= idx` and `i <= fog_end`, and the two
     agree everywhere except on a step past the fog. There the step is drawn closed
     while `i >= idx` is true, so the toggle writes `dopen[i] = false` on a step that
     is already closed and the click does nothing; the second click finds a non-nil
     `false` and opens it. Every step before the current one behaves, which is why
     that takes a long ladder to see.

     So `build_detail` records the `open` it actually drew on the step's own line,
     and this reads that back and inverts it. One formula, in one place, and the
     thing being flipped is the thing the player is looking at. A second derivation
     of a value that already exists will drift; looking cannot be wrong.

     A step that is not drawn returns without doing anything. `step_at` only offers
     lines it drew this frame, so this is unreachable from a click, and a toggle of
     a step the player cannot see is not a thing to guess at. ]]
function panel.toggle_step(i)
    if not i then return end
    local l = S.sel and S.lines[S.sel]
    if not l or l.kind ~= 'row' then return end
    local shown = nil
    for _, d in ipairs(S.dlines or {}) do
        if d.step == i then shown = d.open and true or false break end
    end
    if shown == nil then return end
    S.dopen[i] = not shown
    S.dkey = nil          -- force a rebuild on the next draw
end

--[[ Which step, if any, is at this y in the detail pane. Only the step's own
     title line is a target; its zone and note lines are not.

     The band is the measured ink box, not `d.y` to `d.y + DPITCH`. DPITCH is
     smaller than the rendered line height at 11pt, so a band taken from the pitch
     sits above the glyphs and you have to aim just over the title to hit it. ]]
function panel.step_at(x, y)
    local g = geom()
    if not (x >= g.dx and x <= g.dx + g.dw) then return nil end
    --[[ The same measured ink box the hover band uses, so what lights up and
         what responds to a click are the same rectangle. Derive them separately
         and they drift apart. ]]
    for _, d in ipairs(S.dlines or {}) do
        if d.step and d.expandable and d.y then
            local sz = d.size or theme.fs_step
            local top = d.y + theme.ink_y(sz) - theme.s(3)
            local bot = top + theme.ink_h(sz) + theme.s(6)
            if y >= top and y < bot then return d.step end
        end
    end
    return nil
end

local function line_at(x, y)
    local g = geom()
    if x < g.x or x > g.x + g.w then return nil end
    if y < g.body_y or y > g.body_y + g.body_h then return nil end
    local i = math.floor((y - g.body_y) / (theme.row_h + theme.row_gap)) + 1
    if i < 1 or i > LINES then return nil end
    local idx = S.scroll + i
    if not S.lines[idx] then return nil end
    return idx
end

--[[ Selecting by quest key and not by line index, see rebuild(). Clicking the
     selected row again clears it, which is how the detail pane is closed
     without a second control. ]]
local function select_line(idx)
    local l = S.lines[idx]
    if not l or l.kind ~= 'row' then return end
    if S.sel_key == l.row.key then
        S.sel, S.sel_key, S.ladder = nil, nil, nil
        S.notes, S.desc, S.dlines = nil, nil, nil
        S.dkey, S.dquest = nil, nil
    else
        S.sel, S.sel_key = idx, l.row.key
    end
end
panel.select_line = select_line

function panel.toggle_group(idx)
    local l = S.lines[idx]
    if not l or l.kind ~= 'group' then return end
    local k = l.group.key
    S.collapsed[k] = (not S.collapsed[k]) or nil
    S.dirty = true
end

function panel.set_filter_set(id)
    if model.SETS[id] then S.set = id; S.scroll = 0; S.dirty = true end
end

function panel.set_search(s)
    S.filter = s or ''
    S.scroll = 0
    S.dirty = true
end

--[[ Returns true to block the event. Move events never block, see the file
     header for why that is deliberate rather than an oversight.

     A button press and its release are one event, and splitting them spins the
     camera.

     Act on the button-down and swallow it, and closing the panel with the X
     means the matching button-up arrives with the panel shut, hits the
     `if not S.open then return false` line and passes straight through to the
     client. FFXI receives a release for a press it never saw and its own
     mouse-look state is left believing a button is still held: the camera
     rotates until the next click, which then opens a target menu.

     Two rules, and both are needed:

       * a swallowed press is remembered, and its release is swallowed too,
         whatever has happened in between: panel closed, cursor moved off the
         panel, selection changed. Nothing else can consume it, because nothing
         else knows the press was eaten.
       * the action fires on the release rather than the press, over the same
         target, which is what every other interface does and what stops a
         press-drag-release from activating something the pointer left.

     The same applies to the right and middle buttons (types 3-5): they are
     swallowed over the panel so a right-click on a row cannot swing the camera,
     which means their releases must be swallowed as well. ]]
-- {kind = 'close'|'chip'|'line'|'header'|'body'|'step'|'showall', id, idx}
local press = nil

--[[ What is under the cursor, as a target description rather than an action, so
     press and release can be compared. ]]
local function target_at(g, x, y)
    if not (x >= g.x and x <= g.x + g.w and y >= g.y and y <= g.y + g.h) then
        --[[ The detail pane is a target too: clicking a step's title row opens
             or closes it. Reached only once the list-pane bounds test has
             failed, which is why it sits inside that branch rather than
             returning nil straight away. ]]
        local h = S.action_hit
        if h and x >= h.x and x <= h.x + h.w and y >= h.y and y <= h.y + h.h then
            return {kind = 'showall'}
        end
        local st = panel.step_at(x, y)
        if st then return {kind = 'step', idx = st} end
        return nil
    end
    if y <= g.y + g.head_h then
        if x >= g.x + g.w - theme.s(24) then return {kind = 'close'} end
        return {kind = 'header'}
    end
    if y >= g.filter_y and y < g.body_y then
        for _, c in ipairs(W.chips or {}) do
            if c.x and x >= c.x and x <= c.x + c.w then
                return {kind = 'chip', id = c.id}
            end
        end
        return {kind = 'header'}
    end
    local idx = line_at(x, y)
    if idx then return {kind = 'line', idx = idx} end
    return {kind = 'body'}
end

local function same_target(a, b)
    if not a or not b then return false end
    if a.kind ~= b.kind then return false end
    if a.kind == 'chip' then return a.id == b.id end
    if a.kind == 'line' or a.kind == 'step' then return a.idx == b.idx end
    return true
end

function panel.on_mouse(mtype, x, y, delta)
    --[[ A pending release is honoured even with the panel closed. This is the
         whole fix and it must come before the `S.open` test. ]]
    if not S.open then
        if press and (mtype == 2 or mtype == 4 or mtype == 5) then
            press = nil
            return true
        end
        return false
    end

    local g = geom()

    local inside_list = x >= g.x and x <= g.x + g.w and y >= g.y and y <= g.y + g.h
    local inside_detail = S.sel and x >= g.dx and x <= g.dx + g.dw
                          and y >= g.y and y <= g.y + g.h

    if mtype == 0 then
        S.hover = line_at(x, y)
        local h = S.action_hit
        S.action_hover = h and x >= h.x and x <= h.x + h.w
                           and y >= h.y and y <= h.y + h.h or false
        -- Drives the hover band that tells the player a step is expandable.
        S.hover_step = panel.step_at(x, y)
        return false
    end

    if mtype == 2 or mtype == 4 or mtype == 5 then     -- any release
        local was = press
        press = nil
        if not was then
            -- A release whose press we never saw is not ours to eat.
            return false
        end
        if was.kind ~= 'close' and was.kind ~= 'chip' and was.kind ~= 'line'
           and was.kind ~= 'step' and was.kind ~= 'showall' then
            return true
        end
        local now = target_at(g, x, y)
        if same_target(was, now) then
            if was.kind == 'close' then
                panel.show(false)
            elseif was.kind == 'chip' then
                panel.set_filter_set(was.id)
            elseif was.kind == 'showall' then
                S.showall = not S.showall
                S.dopen = {}
                S.dkey = nil
            elseif was.kind == 'step' then
                panel.toggle_step(was.idx)
            elseif was.kind == 'line' then
                local l = S.lines[was.idx]
                if l and l.kind == 'group' then panel.toggle_group(was.idx)
                elseif l then select_line(was.idx) end
            end
        end
        return true
    end

    if not (inside_list or inside_detail) then return false end

    if mtype == 1 then                       -- left down
        press = target_at(g, x, y) or {kind = 'body'}
        return true
    end

    --[[ Right and middle press. Nothing is bound to them; they are swallowed
         over the panel only so a right-click on a row cannot swing the camera
         (chronicle/ui/widgets.lua:2648). Recorded like a left press so their
         releases, types 4 and 5 handled above, are swallowed to match. ]]
    if mtype == 3 then
        press = {kind = 'body'}
        return true
    end

    --[[ The wheel is type 10, and the direction is in `delta` rather than in a
         second type code. chronicle/ui/widgets.lua:2654-2656 states it, "type 10,
         delta > 0 = scroll up, delta < 0 = scroll down", and its handler branches
         on the sign of delta exactly that way. Worth stating because the obvious
         guess, two codes one per direction, is wrong and gives a wheel that
         silently does nothing. ]]
    if mtype == 10 then
        local n = (tonumber(delta) or 0) > 0 and -3 or 3
        --[[ The wheel belongs to whichever pane the pointer is over. Route it
             always to the list and the detail pane, which is the one place with
             more text than room because notes wrap in full, cannot be scrolled
             at all. ]]
        if inside_detail then panel.dscroll_by(n) else panel.scroll_by(n) end
        return true
    end

    return inside_list or inside_detail
end

return panel
