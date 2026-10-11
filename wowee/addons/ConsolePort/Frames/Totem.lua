---------------------------------------------------------------
-- Totem.lua: Helper frames for Shaman totem selection
---------------------------------------------------------------
-- Creates custom UI frames to manage Shaman spells like 
-- Call of the Elements, Call of the Spirits, and Call of the Ancestors,
-- allowing players to customize which totems are summoned by these abilities
-- with the gamepad.

local _, db = ...
local Atlas = db.Atlas
local floor = math.floor
local LOCALE = db.TUTORIAL.TOTEM

ConsolePortTotemManager = {}

-------------------------------------------------
-- CONSTANTS
-------------------------------------------------

local TOTEM_EMPTY_TEXTURES = {
    [EARTH_TOTEM_SLOT] = "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\Totem-Earth",
    [FIRE_TOTEM_SLOT]  = "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\Totem-Fire",
    [WATER_TOTEM_SLOT] = "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\Totem-Water",
    [AIR_TOTEM_SLOT]   = "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\Totem-Air",
}
local NUM_SETS = 3
local NUM_SLOTS_PER_PAGE = 4
local UI_SLOT_ORDER = { EARTH_TOTEM_SLOT, FIRE_TOTEM_SLOT, WATER_TOTEM_SLOT, AIR_TOTEM_SLOT }

local TOTEM_ELEMENT_NAMES = {
    [EARTH_TOTEM_SLOT] = LOCALE.TOTEM_EARTH,
    [FIRE_TOTEM_SLOT]  = LOCALE.TOTEM_FIRE,
    [WATER_TOTEM_SLOT] = LOCALE.TOTEM_WATER,
    [AIR_TOTEM_SLOT]   = LOCALE.TOTEM_AIR
}

local TOTEM_PRIORITIES = { FIRE_TOTEM_SLOT, EARTH_TOTEM_SLOT, WATER_TOTEM_SLOT, AIR_TOTEM_SLOT }

local CPTM = ConsolePortTotemManager
CPTM.currentSet = 1
CPTM.editingSlot = nil

local function CreateTotemButton(name, parent, id, checked)
    local button = Atlas.GetRoundActionButton(name, true, parent, 42, nil, true)
    if id then button:SetID(id) end

    local buttonName = button:GetName()
    local icon = _G[buttonName .. "Icon"]

    if icon then
        function icon:SetTexture(...)
            SetPortraitToTexture(self, ...)
        end
        button.icon = icon
    end

    if checked then
        button:SetCheckedTexture("Interface\\AddOns\\ConsolePort\\Textures\\Button\\Hilite-Yellow")
    else
        button.CheckedTexture:SetAlpha(0)
    end

    return button
end

---
-- FIXME: Secure Button Creation, for now this will still cause UI taint in combat, so we don't allow opening/closing in combat
--

local totemToggler = CreateFrame("Button", "ConsolePortTotemToggle", UIParent, "SecureActionButtonTemplate")
totemToggler:SetScript("OnClick", function()
    local manager = ConsolePortTotemManagerFrame
    if(InCombatLockdown()) then
        UIErrorsFrame:AddMessage(db.TUTORIAL.SETUP.COMBAT, 1, 0, 0)
        return
    end
    if manager:IsShown() then
        manager:Hide()
        PlaySound("igMainMenuOptionCheckBoxOff")
    else
        CPTM:UpdateAll()
        PlaySound("igMainMenuOptionCheckBoxOn")
    end
end)
-------------------------------------------------
-- ConsolePortTotemManagerFrame Creation
-------------------------------------------------

local manager = Atlas.CreateFrame("ConsolePortTotemManagerFrame", UIParent, nil, nil, true, false)
manager:SetSize(420, 160)
manager:SetPoint("CENTER")
manager:EnableMouse(true)
manager:SetMovable(true)
manager:RegisterForDrag("LeftButton")
manager:SetScript("OnDragStart", manager.StartMoving)
manager:SetScript("OnDragStop", manager.StopMovingOrSizing)
manager:Hide()

manager.title = manager:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
manager.title:SetPoint("TOP", 0, -28) 
manager.title:SetText(LOCALE.TOTEM_MANAGER)

local setsGroup = CreateFrame("Frame", nil, manager)
setsGroup:SetSize(150, 60)
setsGroup:SetPoint("TOPLEFT", 34, -52)

local slotsGroup = CreateFrame("Frame", nil, manager)
slotsGroup:SetSize(200, 60)
slotsGroup:SetPoint("LEFT", setsGroup, "RIGHT", 10, 0)

for i = 1, NUM_SETS do
    local btn = CreateTotemButton("ConsolePortTotemManagerFrameSet" .. i, setsGroup, i, true)
    btn:SetPoint("LEFT", (i - 1) * 50, 0)
end

for i = 1, NUM_SLOTS_PER_PAGE do
    local btn = CreateTotemButton("ConsolePortTotemManagerFrameSlot" .. i, slotsGroup, i)
    btn:SetPoint("LEFT", (i - 1) * 50, 0)
end

local panel = Atlas.CreateFrame("ConsolePortTotemSelectionPanel", CPTotemManagerFrame, nil, nil, true, false)
panel:SetSize(320, 280)
panel:SetPoint("CENTER")
panel:SetFrameStrata("DIALOG")
panel:EnableMouse(true)
panel:SetMovable(true)
panel:RegisterForDrag("LeftButton")
panel:SetScript("OnDragStart", panel.StartMoving)
panel:SetScript("OnDragStop", panel.StopMovingOrSizing)
panel:Hide()

panel.title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
panel.title:SetPoint("TOP", 0, -28)
panel.title:SetText(LOCALE.TOTEM_SELECT)

panel:HookScript("OnShow", function() PlaySound("igMainMenuOptionCheckBoxOn") end)
panel:HookScript("OnHide", function()
    if panel.spellButtons then
        for _, b in ipairs(panel.spellButtons) do b:Hide() end
    end
end)

-------------------------------------------------
-- Core logic and some helper functions
-------------------------------------------------
CPTM._setterButton = CreateFrame("CheckButton", "CPTM_SetterButton", UIParent, "MultiCastActionButtonTemplate")
CPTM._setterButton:Hide()

function GetGlobalActionNumber(slotIndex, page, totemElement)
    if not slotIndex then return end
    local pageOffset = (page - 1) * NUM_SLOTS_PER_PAGE
    local actionIndex = pageOffset + slotIndex
    local actionId = pageOffset + (totemElement or slotIndex)
    CPTM._setterButton:SetID(actionId)
    CPTM._setterButton.buttonIndex = actionIndex
    return ActionButton_CalculateAction(CPTM._setterButton)
end

function CPTM:GetLiveSlotIndexForElement(element)
    local idx = 1
    for i = 1, NUM_SLOTS_PER_PAGE do
        local slot = TOTEM_PRIORITIES[i]
        if GetTotemInfo(slot) and GetMultiCastTotemSpells(slot) then
            if slot == element then
                return idx
            end
            idx = idx + 1
        end
    end
    return nil
end

function CPTM:GetSpellIDForAction(action)
    if not action then return 0 end
    local _, _, actionType, spellID = GetActionInfo(action)
    if actionType == "spell" then
        return spellID
    end
    return 0
end


function CPTM:UpdateSetButtons()
    for i = 1, NUM_SETS do
        local button = _G["ConsolePortTotemManagerFrameSet"..i]
        local spellID = TOTEM_MULTI_CAST_SUMMON_SPELLS[i]
        button.spellID = spellID

        if spellID and IsSpellKnown(spellID) then
            local _, _, icon = GetSpellInfo(spellID)
            if button.icon then button.icon:SetTexture(icon) end
            button:Enable()
            button:SetChecked(i == CPTM.currentSet)
        else
            if button.icon then button.icon:SetTexture(nil) end
            button:Disable()
            button.spellID = nil
        end
    end
end

function CPTM:UpdateSlotButtons()
    if not HasMultiCastActionBar() then
        manager:Hide()
        return
    end
    manager:Show()

    local page = CPTM.currentSet
    for i = 1, NUM_SLOTS_PER_PAGE do
        local totemElement = UI_SLOT_ORDER[i]
        local slotButton = _G["ConsolePortTotemManagerFrameSlot"..i]
        local slotIndex = CPTM:GetLiveSlotIndexForElement(totemElement)
        local action = GetGlobalActionNumber(slotIndex, page, totemElement)
        local spellID = CPTM:GetSpellIDForAction(action)
        slotButton.spellID = spellID

        if spellID and spellID > 0 then
            local _, _, icon = GetSpellInfo(spellID)
            if slotButton.icon then
                slotButton.icon:SetTexture(icon)
                slotButton.icon:SetTexCoord(0, 1, 0, 1)
            end
        else 
            if slotButton.icon then
                slotButton.icon:SetTexture(TOTEM_EMPTY_TEXTURES[totemElement]) 
            end
        end
    end
end

function CPTM:UpdateAll()
    CPTM:UpdateSetButtons()
    CPTM:UpdateSlotButtons()
end

-------------------------------------------------
-- Selection Panel and Spell Assignment
-------------------------------------------------
function CPTM:OpenSelectionPanel(uiSlotID)
    CPTM.editingSlot = uiSlotID
    local totemElement = UI_SLOT_ORDER[uiSlotID]
    panel.title:SetText(format(LOCALE.TOTEM_X_SELECT, TOTEM_ELEMENT_NAMES[totemElement]))

    local availableSpells = { GetMultiCastTotemSpells(totemElement) }

    if not panel.NoneButton then
        panel.NoneButton = CreateTotemButton("ConsolePortTotemSelectionPanelNoneButton", panel, 0)
        panel.NoneButton:SetScript("OnClick", function() CPTM:SelectTotem(0) end)
        panel.NoneButton:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetText(LOCALE.NO_TOTEM)
        end)
        panel.NoneButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    
    if panel.NoneButton.icon then 
        panel.NoneButton.icon:SetTexture(TOTEM_EMPTY_TEXTURES[totemElement]) 
    end
    panel.NoneButton:SetPoint("TOPLEFT", 40, -70)
    panel.NoneButton:Show()

    panel.spellButtons = panel.spellButtons or {}
    local buttons_per_row = 5
    for i, spellID in ipairs(availableSpells) do
        local button = panel.spellButtons[i]
        if not button then
            button = CreateTotemButton("ConsolePortTotemSelectionSpellButton" .. i, panel, i)
            panel.spellButtons[i] = button
            button:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetSpellByID(self.spellID)
            end)
            button:SetScript("OnLeave", function() GameTooltip:Hide() end)
            button:SetScript("OnClick", function(self) CPTM:SelectTotem(self.spellID) end)
        end

        local col = i % buttons_per_row
        local row = floor(i / buttons_per_row)
        
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", 40 + (col * 50), -70 - (row * 50))
        button.spellID = spellID
        local _, _, icon = GetSpellInfo(spellID)
        if button.icon then button.icon:SetTexture(icon) end
        button:Show()
    end

    for i = #availableSpells + 1, #panel.spellButtons do
        panel.spellButtons[i]:Hide()
    end

    panel:Show()
end

function CPTM:SelectTotem(spellID)
    if not CPTM.editingSlot or not CPTM.currentSet then return end
    local totemElement = UI_SLOT_ORDER[CPTM.editingSlot]
    local slotIndex = CPTM:GetLiveSlotIndexForElement(totemElement)
    if not slotIndex then
        UIErrorsFrame:AddMessage(LOCALE.INVALID_TOTEM, 1, 0.1, 0.1)
        PlaySound("igQuestFailed")
        return
    end

    local action = GetGlobalActionNumber(slotIndex, CPTM.currentSet, totemElement)
    SetMultiCastSpell(action, spellID)
    
    CPTM:UpdateAll()

    PlaySound("igMainMenuOptionCheckBoxOff")
    panel:Hide()
    CPTM.editingSlot = nil
end

-------------------------------------------------
-- Initialization
-------------------------------------------------
function CPTM:Initialize()
    for i = 1, NUM_SETS do
        local button = _G["ConsolePortTotemManagerFrameSet"..i]
        button:SetScript("OnClick", function(self)
            CPTM.currentSet = self:GetID()
            PlaySound("igMainMenuOptionCheckBoxOn")
            CPTM:UpdateAll()
        end)
        button:SetScript("OnEnter", function(self)
            if self.spellID then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT"); GameTooltip:SetSpellByID(self.spellID)
            end
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end

    for i = 1, NUM_SLOTS_PER_PAGE do
        local button = _G["ConsolePortTotemManagerFrameSlot"..i]
        button:SetScript("OnClick", function(self) CPTM:OpenSelectionPanel(self:GetID()) end)
        button:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.spellID and self.spellID > 0 then
                GameTooltip:SetSpellByID(self.spellID)
            else
                local totemElement = UI_SLOT_ORDER[self:GetID()]
                local elementName = TOTEM_ELEMENT_NAMES[totemElement] or LOCALE.TOTEM_UNKNOWN
                GameTooltip:SetText(elementName .. " ".. LOCALE.EMPTY_TOTEM)
            end
        end)
        button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
end

local function PlayerHasTotemSystem()
    for _, spellID in ipairs(TOTEM_MULTI_CAST_SUMMON_SPELLS) do
        if IsSpellKnown(spellID) then
            return true
        end
    end
    return false
end

local function OnEvent(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        if not PlayerHasTotemSystem() then
            self:UnregisterAllEvents()
            return
        end
        CPTM:Initialize()
    elseif event == "UPDATE_MULTI_CAST_ACTIONBAR" or event == "SPELLS_CHANGED" then
        if manager and manager:IsShown() then
            CPTM:UpdateAll()
        end
    end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("UPDATE_MULTI_CAST_ACTIONBAR")
eventFrame:RegisterEvent("SPELLS_CHANGED")
eventFrame:SetScript("OnEvent", OnEvent)

RegisterStateDriver(ConsolePortTotemManagerFrame, "visibility", "[combat] hide; nil")
RegisterStateDriver(ConsolePortTotemSelectionPanel, "visibility", "[combat] hide; nil")

local combatGuard = CreateFrame("Frame")
combatGuard:RegisterEvent("PLAYER_REGEN_DISABLED")
combatGuard:SetScript("OnEvent", function()
    if CPTM.editingSlot then
        CPTM.editingSlot = nil
    end
end)

ConsolePort:AddFrame(ConsolePortTotemManagerFrame)
ConsolePort:AddFrame(ConsolePortTotemSelectionPanel)
ConsolePort:UpdateFrames()