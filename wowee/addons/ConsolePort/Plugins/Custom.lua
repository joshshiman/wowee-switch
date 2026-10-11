-- Custom client workarounds goes here...
local _, db = ...
local CPAPI = db.CPAPI


ConsolePort:AddPlugin('CustomFrames', function(self) 
    for _, frame in pairs({
        'AddonPanel',
        'AscensionCharacterFrame',
        'AscensionSpellbookFrame',
        'AscensionLFGFrame',
        'Collections',
        'EscapeMenu',
        'PathToAscensionFrame', 
        'SkillCardsFrame',
        'LFDParentFrame',
        'PVPUIFrame',
        'ChallengesFrame',
        'LadderFrame',
        'CollectionsJournal',
        'LookingForGuildFrame',
        'EncounterJournal',
        'GuildFrame',
    }) do self:AddFrame(frame) end
    
    self:UpdateFrames() 
end, true)

ConsolePort:AddPlugin('CustomFunctions', function(self)  

    local function IsAscensionSpellNode(node) 
        if ((node and node:GetParent()):GetName() and (node and node:GetParent()):GetName():match("AscensionSpellbookFrame")
					and node:GetName():match("SpellButton")) then
            return true
        end
        return false
    end

    -- Register custom check function with the main addon's plugin system.
    if db.PLUGINCHECKS and db.PLUGINCHECKS.IsSpellNode then
        tinsert(db.PLUGINCHECKS.IsSpellNode, IsAscensionSpellNode)
    end

end, CPAPI.IsCustomClient())