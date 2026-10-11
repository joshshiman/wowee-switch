---------------------------------------------------------------
-- UnitMenu.lua: Popup unit menu
---------------------------------------------------------------
local _, db = ...
local CPAPI = db.CPAPI
local Core, UnitMenu = ConsolePort, ConsolePortUnitMenu
---------------------------------------------------------------

---------------------------------------------------------------
-- Icon map
---------------------------------------------------------------
local ICON = {
    Default       = [[Interface\QuestFrame\UI-Quest-BulletPoint]];
    Back          = [[Interface\TimeManager\ResetButton]];
    RaidTarget    = [[Interface\TargetingFrame\UI-RaidTargetingIcons]];
    Focus         = [[Interface\Icons\Ability_Hunter_MasterMarksman]];
    ClearFocus    = [[Interface\Icons\Ability_Hunter_MasterMarksman]];
    AddFriend     = [[Interface\GossipFrame\PetitionGossipIcon]];
    Invite        = [[Interface\GossipFrame\PetitionGossipIcon]];
    Whisper       = [[Interface\GossipFrame\MailGossipIcon]];
    Inspect       = [[Interface\GossipFrame\InspectGossipIcon]];
    Trade         = [[Interface\GossipFrame\BankerGossipIcon]];
    Follow        = [[Interface\MiniMap\Tracking\Generic]];
    Duel          = [[Interface\PVPFrame\PVP-ArenaPoints-Icon]];
    Report        = [[Interface\GossipFrame\BinderGossipIcon]];
    Emote         = [[Interface\GossipFrame\HummerGossipIcon]];
    Roll          = [[Interface\Buttons\UI-GroupLoot-Dice-Up]];
    PvP           = [[Interface\TargetingFrame\UI-PVP-FFA]];
    Loot          = [[Interface\GossipFrame\BankerGossipIcon]];
    Dungeon       = [[Interface\LFGFrame\LFGIcon-Dungeon]];
    Raid          = [[Interface\LFGFrame\LFGIcon-Raid]];
    Reset         = [[Interface\TimeManager\ResetButton]];
    Normal        = [[Interface\PVPFrame\PVP-Currency-Alliance]];
    Heroic        = [[Interface\PVPFrame\PVP-Currency-Horde]];
}

local RAID_TARGET_COORDS = {
    [1] = {0,    0.25, 0,    0.25},
    [2] = {0.25, 0.5,  0,    0.25},
    [3] = {0.5,  0.75, 0,    0.25},
    [4] = {0.75, 1,    0,    0.25},
    [5] = {0,    0.25, 0.25, 0.5 },
    [6] = {0.25, 0.5,  0.25, 0.5 },
    [7] = {0.5,  0.75, 0.25, 0.5 },
    [8] = {0.75, 1,    0.25, 0.5 },
}
local RAID_TARGET_NAMES = {
    RAID_TARGET_1 or 'Star',    RAID_TARGET_2 or 'Circle',
    RAID_TARGET_3 or 'Diamond', RAID_TARGET_4 or 'Triangle',
    RAID_TARGET_5 or 'Moon',    RAID_TARGET_6 or 'Square',
    RAID_TARGET_7 or 'Cross',   RAID_TARGET_8 or 'Skull',
}

---------------------------------------------------------------
-- Emote data
---------------------------------------------------------------
local EMOTE_LIST = {
    'APPLAUD','BEG','BOW','CHICKEN','CRY','DANCE','EAT','FLEX',
    'KISS','KNEEL','LAUGH','POINT','ROAR','SALUTE','SIT',
    'SLEEP','THANK','WAVE','CHEER','CLAP','COWER','CURIOUS',
    'FROWN','GASP','GLOAT','GREET','GRIN','GROAN','GROVEL',
    'GROWL','HAPPY','HUG','INSULT','INTRODUCE','LOST','LOVE',
    'MOCK','MOAN','MOURN','NO','NOD','PANIC','PAT','PEER',
    'PLEAD','POUT','PUZZLED','RAISE','ROFL','RUDE','SHRUG',
    'SHY','SIGH','SLAP','SMILE','SMIRK','SNICKER','SOOTHE',
    'STARE','SURPRISED','TALK','TEASE','TIRED','VICTORY',
    'WELCOME','WHINE','WHISTLE','WINK','WORRY','YAWN','YES',
}
local VOICE_EMOTE_LIST = {
    'BONK','BURP','CACKLE','CHEER','CONFUSED','CRY','FLIRT',
    'GASP','GIGGLE','GLOAT','GREET','GROWL','HELLO','IMPATIENT',
    'LAUGH','NO','OOM','OPENFIRE','PITY','RASP','ROAR',
    'SHOUT','SHRUG','SIGH','SILLY','SORRY','SURPRISED',
}

local function GetEmoteSlashCmd(token)
    for i = 1, (MAXEMOTEINDEX or 200) do
        if _G['EMOTE'..i..'_TOKEN'] == token then
            return _G['EMOTE'..i..'_CMD1'] or ('/'..token:lower())
        end
    end
    return '/'..token:lower()
end

---------------------------------------------------------------
-- Unit helpers
---------------------------------------------------------------
local function GetUnitClassColor(unit)
    if UnitIsPlayer(unit) then
        local _, class = UnitClass(unit)
        if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
            local c = RAID_CLASS_COLORS[class]
            return c.r, c.g, c.b
        end
    else
        local reaction = UnitReaction(unit, 'player')
        if reaction and FACTION_BAR_COLORS then
            local c = FACTION_BAR_COLORS[reaction]
            if c then return c.r, c.g, c.b end
        end
    end
    return 1, 0.82, 0
end

local function GetUnitDescription(unit)
    local line1, line2 = '', ''
    local level = UnitLevel(unit)
    local levelStr = (level == -1) and 'Level ??' or (level and ('Level '..level) or '')

    if UnitIsPlayer(unit) then
        local race     = UnitRace(unit) or ''
        local _, class = UnitClass(unit)
        class = class or ''
        line1 = levelStr..' '..race..' ('..class..')'
        local guild = GetGuildInfo(unit)
        line2 = guild and ('<'..guild..'>') or (UnitFactionGroup(unit) or '')
    else
        local ctype = UnitCreatureType(unit) or ''
        line1 = levelStr..(ctype ~= '' and (' '..ctype) or '')
    end
    return line1, line2
end

---------------------------------------------------------------
-- Navigation stack
---------------------------------------------------------------
UnitMenu.pageStack = {}

---------------------------------------------------------------
-- Button height / spacing constants
---------------------------------------------------------------
local BUTTON_HEIGHT  = 20   -- height of each option button
local HEADER_HEIGHT  = 28   -- height of section headers
local TOP_PADDING    = 8    -- gap between tooltip bottom and first item
local ITEM_SPACING   = 2    -- vertical gap between items

---------------------------------------------------------------
-- Rendering
-- Entry types:
--   { type='button'|'radio', text, command, data, icon, iconCoords, isSelected, secure }
--   { type='header', text }
---------------------------------------------------------------
function UnitMenu:RenderPage(page, title)
    self.buttonPool:ReleaseAll()
    self.headerPool:ReleaseAll()

    self.currentPage  = page
    self.currentTitle = title

    local contentTop  = self.contentStartY  -- set in SetUnit based on portrait header height
    local offsetY     = contentTop

    for _, entry in ipairs(page) do
        if entry.type == 'header' then
            local h = self.headerPool:Acquire()
            h.Text:SetText(entry.text or '')
            h:ClearAllPoints()
            h:SetPoint('TOPLEFT', self, 'TOPLEFT', 16, offsetY)
            h:SetPoint('TOPRIGHT', self, 'TOPRIGHT', -16, offsetY)
            h:Show()
            offsetY = offsetY - HEADER_HEIGHT - ITEM_SPACING

        else
            local btn = self.buttonPool:Acquire()
            btn:ClearAllPoints()
            btn:SetPoint('TOPLEFT',  self, 'TOPLEFT',  16, offsetY)
            btn:SetPoint('TOPRIGHT', self, 'TOPRIGHT', -16, offsetY)

            -- CLEANUP SECURE ATTRIBUTES
            btn:SetAttribute('type1', nil)
            btn:SetAttribute('unit', nil)
            btn:SetAttribute('macrotext', nil)

            --  APPLY SECURE OR INSECURE LOGIC
            if entry.secure then
                for attr, val in pairs(entry.secure) do
                    btn:SetAttribute(attr, val)
                end
                btn.menuCommand = "Hide" 
                btn.menuData    = nil
            else
                -- Standard insecure lua callback
                btn.menuCommand = entry.command
                btn.menuData    = entry.data
            end

            local icon = entry.icon or ICON.Default
            btn.Icon:SetTexture(icon)
            if entry.iconCoords then
                btn.Icon:SetTexCoord(unpack(entry.iconCoords))
            else
                btn.Icon:SetTexCoord(0, 1, 0, 1)
            end

            if btn.Check then
                btn.Check:SetShown(entry.type == 'radio' and entry.isSelected == true)
            end

            btn:SetText(entry.text or '')
            btn:Show()
            
            offsetY = offsetY - BUTTON_HEIGHT - ITEM_SPACING
        end
    end

    local contentUsed = math.abs(contentTop - offsetY) + 24  -- 24 = bottom padding
    local titleArea   = math.abs(contentTop) + 16            -- portrait/header area
    self:SetHeight(titleArea + contentUsed)
end

---------------------------------------------------------------
-- SetUnit: main entry point
---------------------------------------------------------------
function UnitMenu:SetUnit(unit)
    -- Do not attempt to build or anchor secure frames while in combat
    if InCombatLockdown() then 
        UIErrorsFrame:AddMessage(ERR_NOT_IN_COMBAT, 1.0, 0.1, 0.1, 1.0)
        print("|cff00ffffConsolePort:|r Unit menu cannot be opened in combat.")
        return 
    end

    if not unit or not UnitExists(unit) then
        return self:Hide()
    end
    self.unit = unit
    wipe(self.pageStack)

    SetPortraitTexture(self.Icon, unit)
    local name        = UnitName(unit)
    local line1, line2 = GetUnitDescription(unit)

    self.Name:SetText(name or UNKNOWN)
    self.Name:SetTextColor(GetUnitClassColor(unit))
    self.Desc:SetText(line1)

    if self.Desc2 then
        self.Desc2:SetText(line2)
    end

    self.contentStartY = -96

    local page
    if UnitIsUnit(unit, 'player') then
        page = self:BuildPlayerPage()
    else
        page = self:BuildTargetPage()
    end

    self:RenderPage(page, name)
    self:Show()
    self.returnToNode = self.returnToNode or Core:GetCurrentNode()
    Core:SetCurrentNode(self.buttonPool:GetObjectByIndex(1))
end

---------------------------------------------------------------
-- Navigation
---------------------------------------------------------------
function UnitMenu:PushPage(page, title)
    tinsert(self.pageStack, {page=self.currentPage, title=self.currentTitle})
    self:RenderPage(page, title)
end

function UnitMenu:PopPage()
    local prev = tremove(self.pageStack)
    if prev then
        self:RenderPage(prev.page, prev.title)
    else
        self:Hide()
    end
end

function UnitMenu:GetBackEntry()
    return {type='button', text=BACK or 'Back', icon=ICON.Back, command='PopPage'}
end

---------------------------------------------------------------
-- Submenu builders
---------------------------------------------------------------
function UnitMenu:BuildRaidTargetPage()
    local page = {self:GetBackEntry()}
    tinsert(page, {type='header', text=RAID_TARGET_ICON or 'Target Marker Icon'})
    tinsert(page, {type='button', text=NONE or 'None', icon=ICON.Default, command='DoRaidTarget', data=0})
    for i = 1, 8 do
        tinsert(page, {
            type='button', text=RAID_TARGET_NAMES[i],
            icon=ICON.RaidTarget, iconCoords=RAID_TARGET_COORDS[i],
            command='DoRaidTarget', data=i,
        })
    end
    return page
end

function UnitMenu:BuildPvPPage()
    local isPvP = UnitIsPVP('player')
    return {
        self:GetBackEntry(),
        {type='header', text=PVP or 'Player vs. Player'},
        {type='radio', text=ENABLE  or 'Enable',  command='DoPvPEnable',  isSelected=isPvP},
        {type='radio', text=DISABLE or 'Disable', command='DoPvPDisable', isSelected=not isPvP},
    }
end

function UnitMenu:BuildDungeonDifficultyPage()
    local cur = GetDungeonDifficulty and GetDungeonDifficulty() or 1
    return {
        self:GetBackEntry(),
        {type='header', text=DUNGEON_DIFFICULTY or 'Dungeon Difficulty'},
        {type='radio', text=PLAYER_DIFFICULTY1 or 'Normal', icon=ICON.Normal, command='DoDungeonDifficulty', data=1, isSelected=cur==1},
        {type='radio', text=PLAYER_DIFFICULTY2 or 'Heroic', icon=ICON.Heroic, command='DoDungeonDifficulty', data=2, isSelected=cur==2},
    }
end

function UnitMenu:BuildRaidDifficultyPage()
    local cur = GetRaidDifficulty and GetRaidDifficulty() or 1
    return {
        self:GetBackEntry(),
        {type='header', text=RAID_DIFFICULTY or 'Raid Difficulty'},
        {type='radio', text='10 '..(PLAYER_DIFFICULTY1 or 'Normal'), icon=ICON.Normal, command='DoRaidDifficulty', data=1, isSelected=cur==1},
        {type='radio', text='25 '..(PLAYER_DIFFICULTY1 or 'Normal'), icon=ICON.Normal, command='DoRaidDifficulty', data=3, isSelected=cur==3},
        {type='radio', text='10 '..(PLAYER_DIFFICULTY2 or 'Heroic'), icon=ICON.Heroic, command='DoRaidDifficulty', data=2, isSelected=cur==2},
        {type='radio', text='25 '..(PLAYER_DIFFICULTY2 or 'Heroic'), icon=ICON.Heroic, command='DoRaidDifficulty', data=4, isSelected=cur==4},
    }
end

function UnitMenu:BuildEmoteSubPage(list, title, start, stop)
    local page = {self:GetBackEntry(), {type='header', text=title}}
    for i = start, stop do
        local token = list[i]
        if token then
            tinsert(page, {type='button', text=GetEmoteSlashCmd(token), command='DoEmoteToken', data=token})
        end
    end
    return page
end

function UnitMenu:BuildEmotePage()
    local page = {
        self:GetBackEntry(),
        {type='header', text=EMOTE_MESSAGE or 'Emote'},
        {type='button', text=ROLL or 'Roll', icon=ICON.Roll, command='DoRoll'},
    }
    local eChunk, vChunk = 11, 13
    for start = 1, #EMOTE_LIST, eChunk do
        local stop  = math.min(start + eChunk - 1, #EMOTE_LIST)
        local label = ('Emote [%d-%d]'):format(start, stop)
        tinsert(page, {type='button', text=label, command='PushEmoteSub',
            data={list=EMOTE_LIST, title=label, start=start, stop=stop}})
    end
    for start = 1, #VOICE_EMOTE_LIST, vChunk do
        local stop  = math.min(start + vChunk - 1, #VOICE_EMOTE_LIST)
        local label = ('Voice Emote [%d-%d]'):format(start, stop)
        tinsert(page, {type='button', text=label, command='PushEmoteSub',
            data={list=VOICE_EMOTE_LIST, title=label, start=start, stop=stop}})
    end
    return page
end

---------------------------------------------------------------
-- Root page builders
---------------------------------------------------------------
function UnitMenu:BuildPlayerPage()
    local page    = {}
    local unit    = self.unit
    local iLeader = IsPartyLeader()
    local inGroup = (GetNumPartyMembers() > 0) or (GetNumRaidMembers() > 0)

    tinsert(page, {type='button', text=RAID_TARGET_ICON or 'Target Marker Icon', icon=ICON.RaidTarget, command='PushRaidTarget'})

    if UnitExists('focus') and UnitIsUnit(unit, 'focus') then
        tinsert(page, {
            type='button', text=CLEAR_FOCUS or 'Clear Focus', icon=ICON.ClearFocus, 
            secure = { type1 = "macro", macrotext = "/clearfocus" } 
        })
    else
        tinsert(page, {
            type='button', text=SET_FOCUS or 'Set Focus', icon=ICON.Focus, 
            secure = { type1 = "focus", unit = unit } 
        })
    end

    tinsert(page, {type='button', text=PVP or 'Player vs. Player', icon=ICON.PvP, command='PushPvP'})

    if iLeader and inGroup then
        tinsert(page, {type='header', text=LOOT_OPTIONS or 'Loot Options'})
        tinsert(page, {type='button', text=LOOT_METHOD or 'Loot Method', icon=ICON.Loot, command='DoLootMethod'})
    end

    tinsert(page, {type='header', text=INSTANCE_OPTIONS or 'Instance Options'})
    tinsert(page, {type='button', text=DUNGEON_DIFFICULTY or 'Dungeon Difficulty', icon=ICON.Dungeon, command='PushDungeonDifficulty'})
    tinsert(page, {type='button', text=RAID_DIFFICULTY    or 'Raid Difficulty',    icon=ICON.Raid,    command='PushRaidDifficulty'})
    tinsert(page, {type='button', text=RESET_INSTANCES    or 'Reset all instances',icon=ICON.Reset,   command='DoResetInstances'})

    tinsert(page, {type='header', text=OTHER_OPTIONS or 'Other Options'})
    tinsert(page, {type='button', text=EMOTE_MESSAGE or 'Emote', icon=ICON.Emote, command='PushEmote'})

    return page
end

function UnitMenu:BuildTargetPage()
    local page    = {}
    local unit    = self.unit
    local iLeader = IsPartyLeader()

    tinsert(page, {type='button', text=RAID_TARGET_ICON or 'Target Marker Icon', icon=ICON.RaidTarget, command='PushRaidTarget'})

    if UnitExists('focus') and UnitIsUnit(unit, 'focus') then
        tinsert(page, {
            type='button', text=CLEAR_FOCUS or 'Clear Focus', icon=ICON.ClearFocus, 
            secure = { type1 = "macro", macrotext = "/clearfocus" } 
        })
    else
        tinsert(page, {
            type='button', text=SET_FOCUS or 'Set Focus', icon=ICON.Focus, 
            secure = { type1 = "focus", unit = unit } 
        })
    end

    tinsert(page, {type='button', text=ADD_FRIEND or 'Add Friend', icon=ICON.AddFriend, command='DoAddFriend'})

    tinsert(page, {type='header', text=INTERACT or 'Interact'})

    if iLeader and (UnitInParty(unit) or UnitInRaid(unit)) then
        tinsert(page, {type='button', text=VOTE_KICK or 'Kick', icon=ICON.Invite, command='DoKick'})
    else
        tinsert(page, {type='button', text=INVITE or 'Invite', icon=ICON.Invite, command='DoInvite'})
    end

    tinsert(page, {type='button', text=WHISPER or 'Whisper', icon=ICON.Whisper, command='DoWhisper'})

    if CheckInteractDistance(unit, 1) then
        tinsert(page, {type='button', text=INSPECT or 'Inspect', icon=ICON.Inspect, command='DoInspect'})
    end
    if CheckInteractDistance(unit, 2) then
        tinsert(page, {type='button', text=TRADE or 'Trade', icon=ICON.Trade, command='DoTrade'})
    end
    if CheckInteractDistance(unit, 4) then
        tinsert(page, {type='button', text=FOLLOW or 'Follow', icon=ICON.Follow, command='DoFollow'})
    end
    if CheckInteractDistance(unit, 3) then
        tinsert(page, {type='button', text=DUEL or 'Duel', icon=ICON.Duel, command='DoDuel'})
    end

    tinsert(page, {type='header', text=OTHER_OPTIONS or 'Other Options'})
    tinsert(page, {type='button', text=REPORT_PLAYER or 'Report Player', icon=ICON.Report, command='DoReport'})
    tinsert(page, {type='button', text=EMOTE_MESSAGE  or 'Emote',        icon=ICON.Emote,  command='PushEmote'})

    return page
end

---------------------------------------------------------------
-- Navigation push helpers
---------------------------------------------------------------
function UnitMenu:PushRaidTarget()        self:PushPage(self:BuildRaidTargetPage(),       RAID_TARGET_ICON   or 'Target Marker Icon') end
function UnitMenu:PushPvP()               self:PushPage(self:BuildPvPPage(),               PVP                or 'Player vs. Player')  end
function UnitMenu:PushDungeonDifficulty() self:PushPage(self:BuildDungeonDifficultyPage(), DUNGEON_DIFFICULTY or 'Dungeon Difficulty')  end
function UnitMenu:PushRaidDifficulty()    self:PushPage(self:BuildRaidDifficultyPage(),    RAID_DIFFICULTY    or 'Raid Difficulty')     end
function UnitMenu:PushEmote()             self:PushPage(self:BuildEmotePage(),             EMOTE_MESSAGE      or 'Emote')               end
function UnitMenu:PushEmoteSub(data)
    self:PushPage(self:BuildEmoteSubPage(data.list, data.title, data.start, data.stop), data.title)
end

---------------------------------------------------------------
-- Action commands
---------------------------------------------------------------
function UnitMenu:DoRaidTarget(index)
    if InCombatLockdown() then return end
    SetRaidTarget(self.unit, index or 0) ; self:Hide()
end
function UnitMenu:DoPvPEnable()
    if not UnitIsPVP('player') then TogglePVP() end ; self:PopPage()
end
function UnitMenu:DoPvPDisable()
    if UnitIsPVP('player') then TogglePVP() end ; self:PopPage()
end
function UnitMenu:DoDungeonDifficulty(id)
    if SetDungeonDifficulty then SetDungeonDifficulty(id) end ; self:PopPage()
end
function UnitMenu:DoRaidDifficulty(id)
    if SetRaidDifficulty then SetRaidDifficulty(id) end ; self:PopPage()
end
function UnitMenu:DoResetInstances()
    if ResetInstances then ResetInstances() end ; self:Hide()
end
function UnitMenu:DoLootMethod()
    if GetLootMethod and SetLootMethod then
        local methods = {'freeforall','roundrobin','master','group','needbeforegreed'}
        local cur = GetLootMethod()
        local idx = 1
        for i, m in ipairs(methods) do if m == cur then idx = i; break end end
        SetLootMethod(methods[(idx % #methods) + 1])
    end
    self:Hide()
end
function UnitMenu:DoAddFriend()
    local name = UnitName(self.unit) ; if name then AddFriend(name) end ; self:Hide()
end
function UnitMenu:DoInvite()
    local name = UnitName(self.unit) ; if name then InviteUnit(name) end ; self:Hide()
end
function UnitMenu:DoKick()
    local name = UnitName(self.unit) ; if name then UninviteUnit(name) end ; self:Hide()
end
function UnitMenu:DoWhisper()
    local name = UnitName(self.unit)
    if name then ChatFrame_OpenChat('/w '..name..' ', DEFAULT_CHAT_FRAME) end
    self:Hide()
end
function UnitMenu:DoInspect()
    InspectUnit(self.unit) ; self:Hide()
end
function UnitMenu:DoTrade()
    InitiateTrade(self.unit) ; self:Hide()
end
function UnitMenu:DoFollow()
    FollowUnit(self.unit) ; self:Hide()
end
function UnitMenu:DoDuel()
    StartDuel(self.unit) ; self:Hide()
end
function UnitMenu:DoReport()
    if ReportPlayer then ReportPlayer('spam', self.unit) end ; self:Hide()
end
function UnitMenu:DoRoll()
    RandomRoll(1, 100) ; self:Hide()
end
function UnitMenu:DoEmoteToken(token)
    DoEmote(token, UnitIsPlayer(self.unit) and self.unit or nil) ; self:Hide()
end

---------------------------------------------------------------
-- Button mixin
---------------------------------------------------------------
local UnitMenuButtonMixin = {}

function UnitMenuButtonMixin:OnClick()
    local parent = self:GetParent()
    local cmd    = self.menuCommand
    
    -- If it's a secure button, the client handled the action.
    -- We just need to hide the menu.
    if cmd == "Hide" then
        parent:Hide()
        return
    end

    -- Otherwise, execute the insecure function
    if cmd and parent[cmd] then
        parent[cmd](parent, self.menuData)
    end
end

function UnitMenuButtonMixin:SpecialClick()
    self:OnClick()
end

---------------------------------------------------------------
-- Header mixin
---------------------------------------------------------------
local UnitMenuHeaderMixin = {}

function UnitMenuHeaderMixin:OnLoad()
    -- Text child created in XML
end

---------------------------------------------------------------
-- Events
---------------------------------------------------------------
function UnitMenu:OnEvent(event, ...)
    if self[event] then self[event](self, ...) end
end

function UnitMenu:OnHide()
    self.buttonPool:ReleaseAll()
    self.headerPool:ReleaseAll()
    wipe(self.pageStack)
    if self.returnToNode then
        Core:SetCurrentNode(self.returnToNode)
        self.returnToNode = nil
    end
    self.unit        = nil
    self.currentPage = nil
end

function UnitMenu:PLAYER_TARGET_CHANGED()
    if self:IsShown() and self.unit and UnitIsUnit(self.unit, 'target') then
        if not UnitExists('target') then self:Hide() end
    end
end

function UnitMenu:PLAYER_REGEN_DISABLED()
    self:Hide()
end

---------------------------------------------------------------
-- Init
---------------------------------------------------------------
UnitMenu.pageStack = {}

for _, event in ipairs({'PLAYER_TARGET_CHANGED','PLAYER_REGEN_DISABLED'}) do
    UnitMenu:RegisterEvent(event)
end
UnitMenu:SetScript('OnEvent', UnitMenu.OnEvent)
UnitMenu:SetScript('OnHide',  UnitMenu.OnHide)

UnitMenu.buttonPool = ConsolePortUI:CreateFramePool(
    'Button', UnitMenu,
    'ConsolePortSecurePopupButtonTemplate',
    UnitMenuButtonMixin
)

UnitMenu.headerPool = ConsolePortUI:CreateFramePool(
    'Frame', UnitMenu,
    'ConsolePortUnitMenuHeaderTemplate',
    UnitMenuHeaderMixin
)

Core:AddFrame(UnitMenu)

---------------------------------------------------------------
-- Public API
---------------------------------------------------------------
function UnitMenu:Open(unit)
    unit = unit or 'target'
    if UnitExists(unit) then
        self:SetUnit(unit)
    end
end