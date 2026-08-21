--[[ A questmarks whose core/quests.lua loads but has been renamed underneath
     us: `todo` is gone. model.attach must notice by feature detection and
     report 'incompatible' naming the missing entry point, rather than
     discovering it inside a pcall at draw time. ]]
return {
    load = function() return {indexed = 0} end,
    where_of = function() return {} end,
    name_of = function() return nil end,
    -- todo = deliberately absent
}
