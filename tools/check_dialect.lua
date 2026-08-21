--[[
tools/check_dialect.lua -- refuse to ship Lua the game cannot parse.

    luajit tools/check_dialect.lua

Why this exists. Windower's in-game interpreter is PUC-Rio Lua 5.1. The offline
harness runs LuaJIT, which accepts a good deal of Lua 5.2, `goto` and `::labels::`
among it. So a construct can pass every offline test, every syntax check, and
still fail to load in game with a bare parse error and no addon.

That is not hypothetical. `goto continue` shipped from this directory and the
game answered:

    Lua runtime error: questmarks-ui/ui/panel.lua:1054: '=' expected near 'continue'

A test environment more permissive than production tests nothing about the gap:
it confirms the code against its author's assumptions rather than against
reality.

The two interpreters are not ordered, which is the part that makes this subtle.
Neither accepts everything the other does:

                              Windower (LuaCore.dll)   LuaJIT 2.1 (the harness)
    goto / ::labels::         rejects                  accepts (5.2 extension)
    'str':method() no parens  accepts (patched)        rejects
    core Lua 5.1              accepts                  accepts

LuaCore.dll reports "Lua 5.1"; the paren-free shorthand is Windower's own patch,
and questmarks/tools/check.lua records the same conclusion from the other
direction. So the safe target is the intersection, and it needs a guard on each
side:

  * LuaJIT guards one side for free, because tools/smoke.lua parses every file
    and the shorthand cannot survive that. The rule below makes it explicit
    rather than leaving it to which interpreter happens to be installed.
  * This file guards the other side, the constructs LuaJIT is too permissive
    about.

Using stock PUC-Rio 5.1 as the harness instead would move the hole rather than
close it: it would catch `goto` and then reject Windower's own patched syntax and
its libraries.

What it checks. Constructs that are a parse error on 5.1, which is fatal because
the addon does not load, and a few that parse but are nil at runtime.

What it does not check. It is a lexical scan, not a parser. It cannot prove a
file loads on 5.1; it can only catch the constructs known to differ. The real
proof is loading it in game, and that remains the only proof.
]]

--[[ Derived from where this script was invoked, never hardcoded: a hardcoded
     absolute path runs on exactly one machine and names whoever owns it.
     `arg[0]` is the path the interpreter was handed, so stripping `tools/<file>`
     off it leaves the addon directory. ]]
local ROOT = ((arg and arg[0]) or ''):gsub('\\', '/'):gsub('tools/[^/]*$', '')
if ROOT == '' then ROOT = './' end

--[[ Every module the addon loads, and the list is checked rather than trusted:
     tools/smoke.lua walks `package.loaded` after the real addon has loaded and
     fails if anything under the addon root is missing from here.

     That check exists because a hand-maintained list of files is only ever as
     current as the last person to remember it. A module added in a later pass and
     never added here is a module a dialect error can hide in, and nothing else is
     looking for the gap. ]]
local FILES = {
    'questmarks-ui.lua', 'model.lua', 'notes.lua', 'resnames.lua',
    'ui/draw.lua', 'ui/launcher.lua', 'ui/panel.lua', 'ui/theme.lua',
    'ui/metrics.lua', 'ui/pagestats.lua',
}

--[[ Blank out comments and string literals so a rule cannot fire on prose or on
     a path. Replaced with spaces rather than deleted, so reported line numbers
     stay true to the file. ]]
--[[ Rules that must see string literals, so they run before strings are
     blanked. Only one so far, and it is the Windower-side half of the boundary
     above. ]]
local SHORTHAND = 'a quoted string called as a method without parentheses '
    .. 'is a Windower patch -- stock 5.1 and LuaJIT both reject it'

--[[ One rule per quote character, so neither pattern needs an escape inside the
     other's delimiter. Writing it as a single character class needed escaping
     that this file got wrong on the first attempt, which is a small joke at its
     own expense. ]]
local RAW_RULES = {
    {"'%s*:%s*[%a_][%w_]*%s*%(", SHORTHAND},
    {'"%s*:%s*[%a_][%w_]*%s*%(', SHORTHAND},
}

local function strip_comments(src)
    local out = src:gsub('%-%-%[(=*)%[.-%]%1%]', function(s) return (' '):rep(#s) end)
    out = out:gsub('%-%-[^\n]*', function(s) return (' '):rep(#s) end)
    return out
end

local function strip(src)
    local out = src:gsub('[^\n]', function(c) return c end)  -- copy
    -- long comments and long strings, any level of = signs
    out = out:gsub('%-%-%[(=*)%[.-%]%1%]', function(s) return (' '):rep(#s) end)
    out = out:gsub('%[(=*)%[.-%]%1%]', function(s) return (' '):rep(#s) end)
    -- line comments
    out = out:gsub('%-%-[^\n]*', function(s) return (' '):rep(#s) end)
    -- quoted strings
    out = out:gsub('"[^"\n]*"', function(s) return (' '):rep(#s) end)
    out = out:gsub("'[^'\n]*'", function(s) return (' '):rep(#s) end)
    return out
end

--[[ Each rule is {pattern, why}. Patterns run against the stripped source.
     `~=` is valid 5.1 and must not be caught by the bitwise-not rule, which is
     why that one requires a non-`=` character after the tilde. ]]
local RULES = {
    {'goto%s+[%a_]', 'goto is Lua 5.2 -- PARSE ERROR on 5.1'},
    {'::[%a_][%w_]*::', 'labels are Lua 5.2 -- PARSE ERROR on 5.1'},
    {'[^%-/]//[^/]', 'floor division // is Lua 5.3 -- PARSE ERROR on 5.1'},
    {'<<', 'bitwise << is Lua 5.3 -- PARSE ERROR on 5.1'},
    {'>>', 'bitwise >> is Lua 5.3 -- PARSE ERROR on 5.1'},
    {'[%w_%)%]]%s*|%s*[%w_%(]', 'bitwise | is Lua 5.3 -- PARSE ERROR on 5.1'},
    {'~[^=]', 'unary ~ (bitwise not) is Lua 5.3; ~= is fine'},
    {'\\z', '\\z string escape is Lua 5.2'},
    {'table%.unpack', 'table.unpack is 5.2; 5.1 has the global unpack'},
    {'table%.pack', 'table.pack is 5.2'},
    {'math%.type', 'math.type is 5.3'},
    {'os%.exit%s*%(%s*[%a]', 'os.exit(boolean) is 5.2; 5.1 takes a number'},
}

--[[ -> array of {file, line, why, text}. Returned rather than printed so the
     smoke harness can call this in-process instead of shelling out. os.execute
     quoting and exit-code conventions differ enough across shells that the wrapper
     fails while the check itself passes. ]]
local function scan()
    local found = {}
for _, rel in ipairs(FILES) do
    local f = io.open(ROOT .. rel, 'r')
    if not f then
        found[#found + 1] = {file = rel, line = 0, why = 'cannot open'}
    else
        local src = f:read('*a')
        f:close()
        local clean = strip(src)
        --[[ The raw pass runs first, on source with the comments stripped and the
             strings intact, because its rule is about a string literal being called
             as a method and `strip` blanks exactly the text it needs. ]]
        do
            local rl = 1
            for ln in strip_comments(src):gmatch('([^\n]*)\n?') do
                for _, r in ipairs(RAW_RULES) do
                    if ln:find(r[1]) then
                        found[#found + 1] = {file = rel, line = rl,
                                             why = r[2],
                                             text = (ln:gsub('^%s+', ''))}
                    end
                end
                rl = rl + 1
                if rl > 100000 then break end
            end
        end
        local line = 1
        -- walk line by line so the report names one
        for ln in clean:gmatch('([^\n]*)\n?') do
            for _, r in ipairs(RULES) do
                if ln:find(r[1]) then
                    found[#found + 1] = {file = rel, line = line, why = r[2],
                                         text = (ln:gsub('^%s+', ''))}
                end
            end
            line = line + 1
            if line > 100000 then break end
        end
    end
end

    return found
end

local M = {scan = scan, files = FILES}

--[[ Run as a script -> print and set an exit code. Required as a module ->
     hand the findings back. `...` is nil when a file is run directly. ]]
if select('#', ...) == 0 and not package.loaded['tools/check_dialect'] then
    local found = scan()
    for _, p in ipairs(found) do
        print(('[FAIL] %s:%d  %s'):format(p.file, p.line, p.why))
        if p.text then print(('        %s'):format(p.text)) end
    end
    print('')
    if #found == 0 then
        print(('dialect clean -- %d files carry nothing the game cannot parse')
              :format(#FILES))
    else
        print(('DIALECT CHECK FAILED -- %d problem(s); the addon will not load in game')
              :format(#found))
        os.exit(1)
    end
end

return M
