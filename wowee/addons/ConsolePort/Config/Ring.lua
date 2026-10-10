---------------------------------------------------------------------
-- RingManager.lua: Utility ring presets settings
---------------------------------------------------------------------
-- Provides a configuration panel to setup utility ring presets.

local addOn, db = ...
local FadeIn, FadeOut = db.GetFaders()
local Popup, TUTORIAL, Mixin = ConsolePortPopup, db.TUTORIAL, db.table.mixin
local LOCALE = db.TUTORIAL.RING

local r, g, b = db.Atlas.GetCC()
local colMul = (1 + ( 1 - (( r + g + b ) / 3) )) / 2
local CPAPI = db.CPAPI

local WindowMixin, Core, Catcher = {}, {}, {}

---------------------------------------------------------------
-- Core data management
---------------------------------------------------------------
function Core:Init()
    if next(ConsolePortUtility) == nil then
        ConsolePortUtility[1] = {
            Name       = "Utility Ring",
            Icon       = "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\Ring",
            Autoassign = false,
            Binding    = nil,
            Data       = {},
        }
    end
    self:NormalizeIds()
end

local function _sortedKeys(t)
    local keys = {}
    for k in pairs(t) do if type(k) == "number" then table.insert(keys, k) end end
    table.sort(keys)
    return keys
end

function Core:NextFreeId()
    local keys = _sortedKeys(ConsolePortUtility)
    local expect = 1
    for _, k in ipairs(keys) do
        if k ~= expect then return expect end
        expect = expect + 1
    end
    return expect
end

function Core:NormalizeIds()
    local keys = _sortedKeys(ConsolePortUtility)
    local new = {}
    for i, k in ipairs(keys) do new[i] = ConsolePortUtility[k] end
    ConsolePortUtility = new
    _G.ConsolePortUtility = new
end

function Core:CreateRing(name)
    local id = self:NextFreeId()
    ConsolePortUtility[id] = {
        Name       = name or (LOCALE.NEW_RING .. " " .. id),
        Icon       = "Interface\\Icons\\INV_Misc_QuestionMark",
        Autoassign = false,
        Binding    = nil,
        Data       = {},
    }
    return id
end

function Core:DuplicateRing(id)
    local src = ConsolePortUtility[id]
    if not src then return end
    local newID = self:NextFreeId()
    local copy = {
        Name       = src.Name .. " " .. (LOCALE.COPY or "Copy"),
        Icon       = src.Icon,
        Autoassign = src.Autoassign,
        Binding    = nil, -- bindings must be unique
        Data       = {},
    }
    if src.Data then
        for k, v in pairs(src.Data) do
            copy.Data[k] = {}
            for dk, dv in pairs(v) do copy.Data[k][dk] = dv end
        end
    end
    ConsolePortUtility[newID] = copy
    return newID
end

function Core:DeleteRing(id)
    if not ConsolePortUtility[id] then return end
    ConsolePortUtility[id] = nil
    self:NormalizeIds()
end

function Core:ClearRing(id)
    local r = ConsolePortUtility[id]
    if not r then return end
    r.Data = {}
end

function Core:GetRing(id)
    return ConsolePortUtility[id]
end

function Core:GetItemCount(id)
    local r = ConsolePortUtility[id]
    if not r or not r.Data then return 0 end
    local count = 0
    for _ in pairs(r.Data) do count = count + 1 end
    return count
end

function Core:UpdateRingMeta(id, name, iconTexture, autoAssign)
    local r = ConsolePortUtility[id]; if not r then return end
    if name and name ~= "" then r.Name = name end
    if iconTexture and iconTexture ~= "" then r.Icon = iconTexture end
    r.Autoassign = autoAssign
end

function Core:UpdateRingBinding(id, bindingTable)
    local r = ConsolePortUtility[id]; if not r then return end
    r.Binding = bindingTable
end

---------------------------------------------------------------
-- Helpers
---------------------------------------------------------------
local function DeepCopy(orig)
    local copy
    if type(orig) == "table" then
        copy = {}
        for k, v in pairs(orig) do copy[k] = DeepCopy(v) end
    else
        copy = orig
    end
    return copy
end

-- shared state
local selectedRingID = nil
local activeTab = "rings"

---------------------------------------------------------------
-- Confirmation popup helper
---------------------------------------------------------------
local function ShowConfirmPopup(title, text, onConfirm)
    local frame = CreateFrame("Frame", "ConsolePortConfirmDialog", UIParent)
    frame:SetSize(300, 80)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOP", 0, -10)
    label:SetText(text)

    local okBtn = db.Atlas.GetFutureButton("$parentOK", frame, nil, nil, 120, 36)
    okBtn:SetPoint("BOTTOMLEFT", 10, 10)
    okBtn:SetText(LOCALE.OK or "OK")
    okBtn:Hide()
    okBtn:SetScript("OnClick", function()
        onConfirm()
        Popup:Hide()
    end)

    local cancelBtn = db.Atlas.GetFutureButton("$parentCancel", frame, nil, nil, 120, 36)
    cancelBtn:SetPoint("BOTTOMRIGHT", -10, 10)
    cancelBtn:SetText(TUTORIAL.UICTRL.CANCEL)
    cancelBtn:Hide()
    cancelBtn:SetScript("OnClick", function() Popup:Hide() end)

    Popup:SetPopup(title, frame, okBtn, cancelBtn, 160, 320)
end

---------------------------------------------------------------
-- Bind Catcher mixin
---------------------------------------------------------------
function Catcher:Catch(key)
    FadeIn(ConsolePortCursor, 0.2, ConsolePortCursor:GetAlpha(), 1)
    ConsolePortOldConfig:ToggleShortcuts(true)
    self:SetScript('OnKeyUp', nil)
    self:EnableKeyboard(false)

    local action = key and GetBindingAction(key)
    if action and action:match('^CP_') then
        local mod = ''
        if IsShiftKeyDown() and IsControlKeyDown() then mod = 'CTRL-SHIFT-'
        elseif IsShiftKeyDown() then mod = 'SHIFT-'
        elseif IsControlKeyDown() then mod = 'CTRL-' end

        self.CurrentBinding = { Button = action, Modifier = mod }

        local ringManager = self:GetParent():GetParent():GetParent()
        if ringManager and ringManager.WorkingCopy then
            ringManager.WorkingCopy.Binding = self.CurrentBinding
        end

        local formatted = ConsolePort:GetFormattedButtonCombination(action, mod, 50, true)
        self:SetText(formatted or TUTORIAL.CONFIG.INTERACTCATCHER)
    else
        self:SetText(TUTORIAL.CONFIG.INTERACTCATCHER)
    end
end

function Catcher:OnClick()
    self:EnableKeyboard(true)
    self:SetScript('OnKeyUp', self.Catch)
    FadeOut(ConsolePortCursor, 0.2, ConsolePortCursor:GetAlpha(), 0)
    ConsolePortOldConfig:ToggleShortcuts(false)
    self:SetText(TUTORIAL.BIND.CATCHER)
end

function Catcher:OnHide()
    self:Catch()
    FadeOut(self, 0.2, self:GetAlpha(), 0)
end

function Catcher:OnShow()
    if selectedRingID then
        local r = Core:GetRing(selectedRingID)
        local binding = r and r.Binding
        if binding then
            local formatted = ConsolePort:GetFormattedButtonCombination(binding.Button, binding.Modifier, 50, true)
            self:SetText(formatted or TUTORIAL.CONFIG.INTERACTCATCHER)
        else
            binding = selectedRingID == 1 and 'CLICK ConsolePortUtilityToggle:LeftButton' or 'CLICK ConsolePortUtilityToggle:' .. selectedRingID
            local formatted

            if db.Bindings then
                for keyName, modSet in pairs(db.Bindings) do
                    for modifier, bind in pairs(modSet) do 
                        if bind == binding then
                            formatted  = ConsolePort:GetFormattedButtonCombination(
                                keyName, modifier, 50, true)
                        end
                    end
                end
            end

            self:SetText(formatted or TUTORIAL.CONFIG.INTERACTCATCHER)
        end
    else
        self:SetText(TUTORIAL.CONFIG.INTERACTCATCHER)
    end
    FadeIn(self, 0.2, self:GetAlpha(), 1)
end

---------------------------------------------------------------
-- Icon Picker
---------------------------------------------------------------
local CUSTOM_ICONS = {
    "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\Ring",
    "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\combat-ring",
    "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\emote-ring",
    "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\mount-ring",
    "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\pot-ring",
    "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\prof-ring",
    "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\quest-ring",
}

local function CreateIconPickerFrame()
    local frame = CreateFrame("Frame", "ConsolePortIconPicker", UIParent)
    frame:SetSize(460, 420)
    frame.customIcons = CUSTOM_ICONS
    frame.iconsPerRow = 8
    frame.cellSize    = 36
    frame.cellSpacing = 6
    frame.rowSpacing  = 8
    local rowHeight   = frame.cellSize + frame.rowSpacing

    frame.Scroll = db.Atlas.GetScrollFrame("$parentIconScroll", frame, {
        childKey   = "List",
        childWidth = (frame.iconsPerRow * (frame.cellSize + frame.cellSpacing)),
        stepSize   = rowHeight,
        noMeta     = true,
    })
    frame.Scroll:SetPoint("TOPLEFT", 10, -40)
    frame.Scroll:SetPoint("BOTTOMRIGHT", -10, 10)
    local scroll, child = frame.Scroll, frame.Scroll.Child

    frame.pool = {}
    frame.poolSize = 0

    local function CreatePoolButton(i)
        local btn = CreateFrame("Button", frame:GetName() .. "IconBtn" .. i, child, "UIPanelButtonTemplate")
        btn:SetSize(frame.cellSize, frame.cellSize)
        btn:SetNormalTexture("")
        btn:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        btn.Icon = btn:CreateTexture(nil, "ARTWORK")
        btn.Icon:SetAllPoints(btn)
        btn:Hide()
        return btn
    end

    local function EnsurePoolSize(size)
        if size == frame.poolSize then return end
        for i = frame.poolSize + 1, size do frame.pool[i] = CreatePoolButton(i) end
        for i = size + 1, frame.poolSize do if frame.pool[i] then frame.pool[i]:Hide() end end
        frame.poolSize = size
    end

    local function GetTotalIcons() return #frame.customIcons + GetNumMacroIcons() end

    local function GetIconTexture(idx)
        if idx <= #frame.customIcons then return frame.customIcons[idx] end
        return GetMacroIconInfo(idx - #frame.customIcons)
    end

    local function UpdateVisible()
        frame.numIcons  = GetTotalIcons()
        frame.totalRows = math.ceil(frame.numIcons / frame.iconsPerRow)
        child:SetHeight(frame.totalRows * rowHeight)

        local offset      = scroll:GetVerticalScroll() or 0
        local firstRow    = math.floor(offset / rowHeight)
        local visibleRows = math.ceil((scroll:GetHeight() or 0) / rowHeight) + 1
        if visibleRows < 1 then visibleRows = 1 end

        EnsurePoolSize(visibleRows * frame.iconsPerRow)

        local startIdx = firstRow * frame.iconsPerRow + 1
        local endIdx   = math.min(frame.numIcons, startIdx + frame.poolSize - 1)
        local poolIdx  = 1

        for gIdx = startIdx, endIdx do
            local tex = GetIconTexture(gIdx)
            local btn = frame.pool[poolIdx]
            if btn then
                btn.Icon:SetTexture(tex)
                local row = math.floor((gIdx - 1) / frame.iconsPerRow)
                local col = (gIdx - 1) % frame.iconsPerRow
                btn:ClearAllPoints()
                btn:SetPoint("TOPLEFT", child, "TOPLEFT",
                    col * (frame.cellSize + frame.cellSpacing), -row * rowHeight)
                btn:Show()
                btn:SetScript("OnClick", function()
                    if frame.callback then frame.callback(tex, gIdx) end
                    Popup:Hide()
                end)
            end
            poolIdx = poolIdx + 1
        end
        for i = poolIdx, frame.poolSize do
            if frame.pool[i] then frame.pool[i]:Hide() end
        end
    end

    function frame:Refresh(callback)
        self.callback  = callback
        self.numIcons  = GetTotalIcons()
        self.totalRows = math.ceil(self.numIcons / self.iconsPerRow)
        child:SetHeight(self.totalRows * rowHeight)
        UpdateVisible()
    end

    scroll:SetScript("OnVerticalScroll", function() UpdateVisible() end)
    scroll:HookScript("OnSizeChanged", function() UpdateVisible() end)
    frame:HookScript("OnShow", function() UpdateVisible() end)
    return frame
end

---------------------------------------------------------------
-- Rename Frame
---------------------------------------------------------------
local function CreateRenameFrame(onRenamed)
    local frame = CreateFrame("Frame", "ConsolePortRenameDialog", UIParent)
    frame:SetSize(300, 80)

    frame.EditBox = CreateFrame("EditBox", "$parentEditBox", frame, "InputBoxTemplate")
    frame.EditBox:SetSize(240, 30)
    frame.EditBox:SetPoint("TOP", 0, -5)
    frame.EditBox:SetAutoFocus(false)
    frame.EditBox:SetMaxLetters(32)
    frame.EditBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    local function CommitRename()
        local newName = frame.EditBox:GetText()
        if newName and newName ~= "" and frame.ringID then
            if onRenamed then onRenamed(frame.ringID, newName) end
        end
        Popup:Hide()
    end

    frame.OK = db.Atlas.GetFutureButton("$parentOK", frame, nil, nil, 120, 36)
    frame.OK:SetPoint("BOTTOMLEFT", 10, 10)
    frame.OK:SetText(LOCALE.OK or "OK")
    frame.OK:SetScript("OnClick", CommitRename)
    frame.OK:Hide()

    frame.Cancel = db.Atlas.GetFutureButton("$parentCancel", frame, nil, nil, 120, 36)
    frame.Cancel:SetPoint("BOTTOMRIGHT", -10, 10)
    frame.Cancel:SetText(TUTORIAL.UICTRL.CANCEL)
    frame.Cancel:SetScript("OnClick", function() Popup:Hide() end)
    frame.Cancel:Hide()

    frame:Hide()

    function frame:Open(ringID, currentName)
        self.ringID = ringID
        self.EditBox:SetText(currentName or "")
        Popup:SetPopup(LOCALE.RENAMERING or "Rename Ring", self, self.OK, self.Cancel, 160, 400)
    end

    return frame
end

---------------------------------------------------------------
-- Loadout browser: builds categorized spell/item/macro list
---------------------------------------------------------------
local function BuildLoadoutCategories()
    local cats = {}

    -- Spellbook
    local spellCat = { name = LOCALE.SPELLS or "Spells", items = {} }
    local SpellBookFrame = CPAPI.IsCustomClient() and
        CPAPI.GetCustomFrame("SpellBookFrame") or SpellBookFrame
    if SpellBookFrame then
        local numTabs = GetNumSpellTabs()
        for t = 1, numTabs do
            local tabName, _, offset, numSpells = GetSpellTabInfo(t)
            local subcat = { name = tabName, items = {} }
            local highestRanks = {}

            for s = offset + 1, offset + numSpells do
                local spellName, rank = GetSpellName(s, BOOKTYPE_SPELL)
                if spellName and not IsPassiveSpell(s, BOOKTYPE_SPELL) then
                    local tex = GetSpellTexture(s, BOOKTYPE_SPELL)
                    local spellID = select(3, strfind(
                        (GetSpellLink(spellName, rank) or ""), "spell:(%d+)"))
                    if tex then
                        highestRanks[spellName] = {
                            name    = spellName,
                            texture = tex,
                            action  = "spell",
                            value   = spellID or spellName,
                        }
                    end
                end
            end
            
            for _, spellData in pairs(highestRanks) do
                table.insert(subcat.items, spellData)
            end
            if #subcat.items > 0 then
                table.insert(spellCat.items, subcat)
            end
        end
    end
    table.insert(cats, spellCat)

    -- Bag items (non-empty slots)
    local itemCat = { name = LOCALE.ITEMS or "Items", items = {} }
    local seen = {}
    for bag = 0, 4 do
        local slots = GetContainerNumSlots(bag)
        for slot = 1, slots do
            local link = GetContainerItemLink(bag, slot)
            if link and GetItemSpell(link) then
                local _, itemID = strsplit(":", strmatch(link, "item[%-?%d:]+"))
                itemID = tonumber(itemID)
                if itemID and not seen[itemID] then
                    seen[itemID] = true
                    local name, _, _, _, _, _, _, _, _, tex = GetItemInfo(itemID)
                    if name and tex then
                        table.insert(itemCat.items, {
                            name    = name,
                            texture = tex,
                            action  = "item",
                            value   = itemID,
                            cursorID = itemID,
                        })
                    end
                end
            end
        end
    end
    table.insert(cats, itemCat)

    -- Macros
    local macroCat = { name = LOCALE.MACROS or "Macros", items = {} }
    local numMacros = GetNumMacros()
    for i = 1, numMacros do
        local name, tex = GetMacroInfo(i)
        if name then
            table.insert(macroCat.items, {
                name    = name,
                texture = tex or "Interface\\Icons\\INV_Misc_QuestionMark",
                action  = "macro",
                value   = i,
            })
        end
    end
    table.insert(cats, macroCat)

    -- Mounts
    local mountCat = { name = LOCALE.MOUNTS or "Mounts", items = {} }
    local numMounts = GetNumCompanions("MOUNT")
    for i = 1, numMounts do
        local _, name, spellID, tex = GetCompanionInfo("MOUNT", i)
        if name and tex then
            table.insert(mountCat.items, {
                name    = name,
                texture = tex,
                action  = "spell",
                value   = spellID,
                mountID = spellID,
            })
        end
    end
    table.insert(cats, mountCat)

    -- Companions
    local petCat = { name = LOCALE.COMPANTION or "Companions", items = {} }
    local numPets = GetNumCompanions("CRITTER")
    for i = 1, numPets do
        local _, name, spellID, tex = GetCompanionInfo("CRITTER", i)
        if name and tex then
            table.insert(petCat.items, {
                name    = name,
                texture = tex,
                action  = "spell",
                value   = spellID,
                mountID = spellID,
            })
        end
    end
    table.insert(cats, petCat)

    local customBindingsList = ConsolePort:GetCustomBindingsForRings()  
    if customBindingsList then 
        local cpCat = { name = "ConsolePort", items = {} }
        for _, info in ipairs(customBindingsList) do
            if type(info) == "table" and info.texture and info.binding then
                table.insert(cpCat.items, {
                    name    = info.name or info.binding,
                    texture = info.texture,
                    action  = "custom",
                    value   = info.binding,
                })
            end
        end
        
        if #cpCat.items > 0 then
            table.insert(cats, cpCat)
        end
    end

    return cats
end

---------------------------------------------------------------
-- Ring list row factory
---------------------------------------------------------------
local function MakeRingCard(parent, i)
    local btn = parent.Buttons and parent.Buttons[i]
    if not btn then
        btn = db.Atlas.GetBindingMetaButton(("$parentCard%d"):format(i), parent, {
            width      = 240,
            height     = 64,
            useButton  = true,
            textWidth  = 160,
            iconPoint  = {"LEFT", "LEFT", 8, 0},
            textPoint  = {"LEFT", "LEFT", 46, 8},
            buttonPoint = {"CENTER", 0, 0},
        })
        db.Atlas.SetFutureButtonStyle(btn)
        btn.Label:SetJustifyH("LEFT")

        btn.SubLabel = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.SubLabel:SetPoint("TOPLEFT", btn.Label, "BOTTOMLEFT", 0, -2)
        btn.SubLabel:SetTextColor(0.6, 0.6, 0.6, 1)

        btn.BindBadge = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        btn.BindBadge:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -6, -8)
        btn.BindBadge:SetTextColor(0.4, 0.8, 1, 1)

        parent:AddButton(btn)
    end
    return btn
end

---------------------------------------------------------------
-- Register Panel
---------------------------------------------------------------
db.PANELS[#db.PANELS + 1] = {
    name   = "RingManager",
    header = LOCALE.RING,
    mixin  = WindowMixin,
    onLoad = function(RingManager, self)

        Core:Init()

        -- shared helpers
        local iconPicker = CreateIconPickerFrame()
        local renameFrame = CreateRenameFrame(function(ringID, newName)
            local r = Core:GetRing(ringID)
            if r then
                r.Name = newName
                if RingManager.WorkingCopy then
                    RingManager.WorkingCopy.Name = newName
                end
                RingManager:RefreshAll()
            end
        end)

        -----------------------------------------------------------
        -- Tab buttons (top of right panel)
        -----------------------------------------------------------
        local TAB_W, TAB_H = 130, 34
        local tabContainer = CreateFrame("Frame", "$parentTabContainer", RingManager)
        tabContainer:SetSize(TAB_W * 3, TAB_H)
        tabContainer:SetPoint("TOPLEFT", RingManager, "TOPLEFT", 310, -8)

        local tabs = {}
        local tabDefs = {
            { key = "rings",   label = LOCALE.RINGS   or "Rings"   },
            { key = "loadout", label = LOCALE.LOADOUT  or "Loadout"  },
            { key = "options", label = LOCALE.OPTIONS  or "Options"  },
        }

        local function SwitchTab(key)
            activeTab = key
            for _, t in ipairs(tabs) do
                if t.key == key then
                    t.btn:SetAlpha(1)
                    t.panel:Show()
                else
                    t.btn:SetAlpha(0.5)
                    t.panel:Hide()
                end
            end
        end

        -----------------------------------------------------------
        -- LEFT SIDE: Ring list + add/duplicate/remove buttons
        -----------------------------------------------------------
        RingManager.RingScroll = db.Atlas.GetScrollFrame("$parentRingScrollFrame", RingManager, {
            childKey   = "List",
            childWidth = 265,
            stepSize   = 64,
        })
        RingManager.RingScroll:SetPoint("TOPLEFT",    RingManager, "TOPLEFT",    24, -41)
        RingManager.RingScroll:SetPoint("BOTTOMLEFT", RingManager, "BOTTOMLEFT", 24, 91)
        RingManager.RingScroll:SetWidth(265)

        RingManager.RingList         = RingManager.RingScroll.Child
        RingManager.RingList.parent  = RingManager
        RingManager.RingList.Buttons = RingManager.RingScroll.Buttons

        -- three bottom buttons equal width
        local BTN_W = 83
        RingManager.AddRingButton = db.Atlas.GetFutureButton(
            "$parentAddRingButton", RingManager, nil, nil, BTN_W, 40)
        RingManager.AddRingButton:SetPoint("BOTTOMLEFT", 24, 24)
        RingManager.AddRingButton:SetText(LOCALE.ADD or "Add")

        RingManager.DuplicateRingButton = db.Atlas.GetFutureButton(
            "$parentDuplicateRingButton", RingManager, nil, nil, BTN_W, 40)
        RingManager.DuplicateRingButton:SetPoint("LEFT", RingManager.AddRingButton, "RIGHT", 5, 0)
        RingManager.DuplicateRingButton:SetText(LOCALE.DUPLICATE or "Duplicate")

        RingManager.RemoveRingButton = db.Atlas.GetFutureButton(
            "$parentRemoveRingButton", RingManager, nil, nil, BTN_W, 40)
        RingManager.RemoveRingButton:SetPoint("LEFT", RingManager.DuplicateRingButton, "RIGHT", 5, 0)
        RingManager.RemoveRingButton:SetText(LOCALE.REMOVE or "Remove")

        -----------------------------------------------------------
        -- Refresh ring list
        -----------------------------------------------------------
        local function RefreshRingList()
            local count = 0
            for id, ring in ipairs(ConsolePortUtility) do
                count = count + 1
                local btn = MakeRingCard(RingManager.RingList, count)

                -- icon
                if btn.Icon then
                    SetPortraitToTexture(btn.Icon, ring.Icon or "Interface\\Icons\\INV_Misc_QuestionMark")
                end

                btn:SetText(ring.Name or (LOCALE.RING .. " " .. id))
                btn.ringID = id

                local itemCount = Core:GetItemCount(id)
                btn.SubLabel:SetText(string.format("%d %s",
                    itemCount, itemCount == 1 and (LOCALE.ITEM or "Item")
                    or (LOCALE.ITEMS or "Items")))

                local binding = ring.Binding and
                    (ring.Binding.Modifier or "") .. (ring.Binding.Button or "")
                
                btn.BindBadge:SetText(binding
                    and ("|cFF88CCFF" .. binding .. "|r")
                    or ("|cFF666666" .. (LOCALE.NOTBOUND or "Not Bound") .. "|r"))

                if not binding then
                    binding = id == 1 and 'CLICK ConsolePortUtilityToggle:LeftButton' or 'CLICK ConsolePortUtilityToggle:' .. id
                    
                    if db.Bindings then
                        for keyName, modSet in pairs(db.Bindings) do
                            for modifier, bind in pairs(modSet) do 
                                if bind == binding then
                                    btn.BindBadge:SetText(ConsolePort:GetFormattedButtonCombination(
                                        keyName, modifier, 24, true))
                                end
                            end
                        end
                    end
                end

                btn:SetScript("OnClick", function(b)
                    -- deselect old
                    if RingManager.RingList.selected and
                        RingManager.RingList.selected ~= b and
                        RingManager.RingList.selected.SelectedTexture then
                        RingManager.RingList.selected.SelectedTexture:Hide()
                    end
                    RingManager.RingList.selected = b
                    if b.SelectedTexture then b.SelectedTexture:Show() end

                    selectedRingID = b.ringID
                    RingManager.WorkingCopy = DeepCopy(Core:GetRing(selectedRingID))

                    -- update all tab panels to reflect new selection
                    RingManager:OnRingSelected(selectedRingID)
                end)
                btn:Show()
            end
            RingManager.RingList:Refresh(count)
        end

        RingManager.RingList:SetScript("OnShow", RefreshRingList)

        RingManager.AddRingButton:SetScript("OnClick", function()
            Core:CreateRing()
            RefreshRingList()
        end)

        RingManager.DuplicateRingButton:SetScript("OnClick", function()
            if not selectedRingID then return end
            Core:DuplicateRing(selectedRingID)
            RefreshRingList()
        end)

        RingManager.RemoveRingButton:SetScript("OnClick", function()
            if not selectedRingID then return end
            if selectedRingID == 1 then return end
            local r = Core:GetRing(selectedRingID)
            local name = r and r.Name or ""
            ShowConfirmPopup(
                LOCALE.DELETERING or "Delete Ring",
                (LOCALE.CONFIRMDELETE or "Delete '%s'?"):format(name),
                function()
                    Core:DeleteRing(selectedRingID)
                    selectedRingID = nil
                    RefreshRingList()
                    RingManager:OnRingSelected(nil)
                end)
        end)

        -----------------------------------------------------------
        -- RIGHT PANEL container (shared by all 3 tabs)
        -----------------------------------------------------------
        local rightPanel = db.Atlas.GetGlassWindow(
            "$parentRightPanel", RingManager, nil, true)
        rightPanel:SetBackdrop(db.Atlas.Backdrops.Border)
        rightPanel:SetSize(600, 490)
        rightPanel:SetPoint("TOPLEFT", RingManager, "TOPLEFT", 310, -45)
        rightPanel.Close:Hide()
        rightPanel.BG:SetAlpha(0.08)

        -----------------------------------------------------------
        -- TAB: RINGS  (ring preview - uses actual Utility toggle)
        -----------------------------------------------------------
        local ringsPanel = CreateFrame("Frame", "$parentRingsPanel", rightPanel)
        ringsPanel:SetAllPoints()

        -- empty state message
        ringsPanel.EmptyLabel = ringsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        ringsPanel.EmptyLabel:SetPoint("CENTER", 0, 0)
        ringsPanel.EmptyLabel:SetText(LOCALE.RINGSEL or "Select a ring to view it.")
        ringsPanel.EmptyLabel:SetTextColor(0.6, 0.5, 0.2, 1)

        -- ring name + icon display at top
        ringsPanel.RingIcon = ringsPanel:CreateTexture(nil, "ARTWORK")
        ringsPanel.RingIcon:SetSize(36, 36)
        ringsPanel.RingIcon:SetPoint("TOPLEFT", 20, -16)

        ringsPanel.RingTitle = ringsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        ringsPanel.RingTitle:SetPoint("LEFT", ringsPanel.RingIcon, "RIGHT", 10, 2)

        ringsPanel.RingSubTitle = ringsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        ringsPanel.RingSubTitle:SetPoint("LEFT", ringsPanel.RingIcon, "RIGHT", 10, -14)
        ringsPanel.RingSubTitle:SetTextColor(0.6, 0.6, 0.6, 1)

        -- Pie ring background

        ringsPanel.PieBackground = ringsPanel:CreateTexture(nil, "BACKGROUND", nil, -1)
        ringsPanel.PieBackground:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Background]])
        ringsPanel.PieBackground:SetPoint("CENTER", ringsPanel, "CENTER", 0, -20)
        ringsPanel.PieBackground:SetSize(600, 600)
        ringsPanel.PieBackground:SetBlendMode('BLEND')
        ringsPanel.PieBackground:SetVertexColor(r * colMul, g * colMul, b * colMul)
        ringsPanel.PieBackground._rotation = 0

        -- Pie separators (one per slot, rotated between slots)
        ringsPanel.PieSeparators = {}
        local function RefreshPieSeparators(totalSlots)
            for _, sep in ipairs(ringsPanel.PieSeparators) do sep:Hide() end
            ringsPanel.PieSeparators = {}
            local angleStep = 360 / totalSlots
            for i = 1, totalSlots do
                local sep = ringsPanel:CreateTexture(nil, "ARTWORK", nil, 2)
                sep:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Inactive]])
                sep:SetPoint("CENTER", ringsPanel, "CENTER", 0, -20)
                sep:SetSize(600, 600)
                sep:SetRotation(math.rad(270 - (i - 1) * angleStep + (angleStep * 0.5)))
                sep:SetAlpha(0.6)
                sep:Show()
                ringsPanel.PieSeparators[i] = sep
            end
        end

        -- idle rotation OnUpdate
        local PIE_ROTATE_SPEED = 0.1
        ringsPanel:SetScript("OnUpdate", function(self, elapsed)
            if self.PieBackground:IsShown() then
                local rot = self.PieBackground._rotation + PIE_ROTATE_SPEED * elapsed
                self.PieBackground._rotation = rot
                self.PieBackground:SetRotation(rot)
            end
        end)

        -- Slot frames: look exactly like ConsolePortRingButtonTemplate
        -- icon masked round by Mask, Normal texture on top, Shadow below, Hilite on hover
        ringsPanel.SlotFrames = {}
        local totalSlots = ConsolePortRadialHandler:GetIndexSize()
        local SLOT_RADIUS = 130
        local SLOT_SIZE   = 48

        RefreshPieSeparators(totalSlots)

        for i = 1, totalSlots do
            -- counter-clockwise to match ingame ring direction
            local angle = math.rad(90 - (i - 1) * (360 / totalSlots))
            local x = math.cos(angle) * SLOT_RADIUS
            local y = math.sin(angle) * SLOT_RADIUS

            local slot = CreateFrame("Button", nil, ringsPanel)
            slot:SetSize(SLOT_SIZE, SLOT_SIZE)
            slot:SetPoint("CENTER", ringsPanel, "CENTER", x, y - 20)
            slot:SetAlpha(0.9)
            slot:RegisterForClicks("RightButtonUp")

            
            local icon = slot:CreateTexture(nil, "BACKGROUND")
            icon:SetSize(SLOT_SIZE, SLOT_SIZE)
            icon:SetPoint("CENTER", slot, "CENTER", 0, 0)
            slot.icon = icon

            -- empty icon (shown when no action assigned)
            local empty = slot:CreateTexture(nil, "BACKGROUND")
            empty:SetSize(SLOT_SIZE, SLOT_SIZE)
            empty:SetPoint("CENTER", slot, "CENTER", 0, 0)
            SetPortraitToTexture(empty, [[Interface\AddOns\ConsolePort\Textures\Button\EmptyIcon]])
            empty:SetDesaturated(true)
            empty:SetVertexColor(0.5, 0.5, 0.5, 1)
            slot.empty = empty

            -- Normal texture (the round button face, OVERLAY)
            local normal = slot:CreateTexture(nil, "OVERLAY")
            normal:SetTexture([[Interface\AddOns\ConsolePort\Textures\Button\Normal]])
            normal:SetAllPoints(slot)

            -- Hilite (ADD blendmode, shown on hover)
            local hilite = slot:CreateTexture(nil, "OVERLAY", nil, 6)
            hilite:SetTexture([[Interface\AddOns\ConsolePort\Textures\Button\Hilite]])
            hilite:SetAllPoints(slot)
            hilite:SetBlendMode("ADD")
            hilite:SetAlpha(0)
            

            local PieSepLeft, PieSepRight

            if ringsPanel.PieSeparators then
                local slotIndex = i
                if slotIndex then
                    for i, sep in ipairs(ringsPanel.PieSeparators) do
                        local left  = slotIndex % totalSlots + 1
                        local right = (slotIndex - 1) % totalSlots + 1

                        PieSepLeft = i == left and sep or PieSepLeft
                        PieSepRight = i == right and sep or PieSepRight
                    end
                end
            end

            slot:SetScript("OnEnter", function(s) 
                if(PieSepLeft and PieSepRight) then
                    PieSepLeft:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Active]])
                    PieSepRight:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Active]])
                end

                hilite:SetAlpha(1)
                local ring = Core:GetRing(selectedRingID)
                local info = ring and ring.Data and ring.Data[s.slotIndex]
                if info and info.action then  
                    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                    if info.action == 'item' then
                        local _, itemlink = GetItemInfo(info.value or info.cursorID)
                        if itemlink then GameTooltip:SetHyperlink(itemlink) end 
                    elseif info.action == 'spell' then
                        if info.mountID then
                            -- Use the specific spell link for mounts
                            GameTooltip:SetHyperlink(string.format("|cff71d5ff|Hspell:%d|h[%s]|h|r", info.mountID, info.value))
                        else
                            local link = GetSpellLink(info.value)
                            if link then GameTooltip:SetHyperlink(link) end
                        end
                    elseif info.action == 'macro' then
                        local name, _, body = GetMacroInfo(info.value)
                        -- Optional: Show macro name/contents
                        GameTooltip:ClearLines() 
                        GameTooltip:AddLine(name, 1, 0.82, 0) 
                        GameTooltip:AddLine(" ") 
                        if body and body ~= "" then
                            for line in string.gmatch(body, "[^\r\n]+") do
                                GameTooltip:AddLine(line, 1, 1, 1, true)
                            end
                        end

                        GameTooltip:Show()
                    end
                else 
                    GameTooltip:Hide()
                end
            end)
            slot:SetScript("OnLeave", function()
                if(PieSepLeft and PieSepRight) then
                    PieSepLeft:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Inactive]])
                    PieSepRight:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Inactive]])
                end

                hilite:SetAlpha(0)
                GameTooltip:Hide()
            end)

            -- right-click removes action from slot
            slot:SetScript("OnClick", function(s, btn)
                if btn == "RightButton" and selectedRingID then
                    local ring = Core:GetRing(selectedRingID)
                    if ring and ring.Data then
                        -- clear from data table
                        ring.Data[s.slotIndex] = nil

                        -- also clear the live button's attribute cache so it doesn't repopulate
                        if not InCombatLockdown() then
                            local liveButton = _G["ConsolePortUtilityToggleButton" .. s.slotIndex]
                            if liveButton then
                                -- this triggers OnAttributeChanged -> OnContentRemoved
                                -- which properly clears the prefixed attribute cache too
                                liveButton:SetAttribute("type", nil)

                                local prefix = "ring" .. selectedRingID .. "-"
                                liveButton:SetAttribute(prefix .. "type",     nil)
                                liveButton:SetAttribute(prefix .. "id",       nil)
                                liveButton:SetAttribute(prefix .. "cursorID", nil)
                                liveButton:SetAttribute(prefix .. "mountID",  nil)
                            end
                        end
                        
                        ringsPanel:UpdateSlots(selectedRingID)
                        RefreshRingList()
                    end
                end
            end)

            slot.slotIndex = i
            ringsPanel.SlotFrames[i] = slot
        end

        function ringsPanel:UpdateSlots(ringID)
            local r = ringID and Core:GetRing(ringID)
            for i, slot in ipairs(self.SlotFrames) do
                local info = r and r.Data and r.Data[i]
                if info and info.action then
                    local tex
                    if info.action == "item" then
                        tex = select(10, GetItemInfo(info.cursorID or info.value))
                    elseif info.action == "spell" then
                        tex = GetSpellTexture(info.value)
                            or select(3, GetSpellInfo(info.value))
                    elseif info.action == "macro" then
                        tex = select(2, GetMacroInfo(info.value))
                    end
                    if tex then
                        SetPortraitToTexture(slot.icon, tex)
                        slot.icon:Show()
                        slot.empty:Hide()
                    else
                        slot.icon:Hide()
                        slot.empty:Show()
                    end
                else
                    slot.icon:Hide()
                    slot.empty:Show()
                end
            end
        end

        function ringsPanel:Refresh(ringID)
            if not ringID then
                self.EmptyLabel:Show()
                self.RingIcon:Hide()
                self.RingTitle:Hide()
                self.RingSubTitle:Hide()
                for _, s in ipairs(self.SlotFrames) do s:Hide() end
                return
            end
            self.EmptyLabel:Hide()
            local r = Core:GetRing(ringID)
            if not r then return end

            SetPortraitToTexture(self.RingIcon, r.Icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            self.RingIcon:Show()
            self.RingTitle:SetText(r.Name or "")
            self.RingTitle:Show()

            local count = Core:GetItemCount(ringID)
            local binding = r.Binding and
                (r.Binding.Modifier or "") .. (r.Binding.Button or "")    

            if not binding then
                binding = ringID == 1 and 'CLICK ConsolePortUtilityToggle:LeftButton' or 'CLICK ConsolePortUtilityToggle:' .. ringID

                if db.Bindings then
                    for keyName, modSet in pairs(db.Bindings) do
                        for modifier, bind in pairs(modSet) do 
                            if bind == binding then
                                binding  = ConsolePort:GetFormattedButtonCombination(
                                    keyName, modifier, 16, true)
                            end
                        end
                    end
                end
            end

            self.RingSubTitle:SetText(string.format("%d %s  |  %s",
                count,
                count == 1 and (LOCALE.ITEM or "Item") or (LOCALE.ITEMS or "Items"),
                binding or (LOCALE.NOTBOUND or "Not Bound")))
            self.RingSubTitle:Show()

            for _, s in ipairs(self.SlotFrames) do s:Show() end
            self:UpdateSlots(ringID)
        end

        -----------------------------------------------------------
        -- TAB: LOADOUT
        -----------------------------------------------------------
        local loadoutPanel = CreateFrame("Frame", "$parentLoadoutPanel", rightPanel)
        loadoutPanel:SetAllPoints()
        loadoutPanel:Hide()

        -- empty state
        loadoutPanel.EmptyLabel = loadoutPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        loadoutPanel.EmptyLabel:SetPoint("CENTER", -100, 0)
        loadoutPanel.EmptyLabel:SetText(LOCALE.NOABILITIES or "You do not have any\nabilities in this ring yet.")
        loadoutPanel.EmptyLabel:SetTextColor(0.6, 0.5, 0.2, 1)
        loadoutPanel.EmptyLabel:SetJustifyH("CENTER")

        -- LEFT: mini ring preview with proper ring button look
        local miniRing = CreateFrame("Frame", nil, loadoutPanel)
        miniRing:SetSize(300, 400)
        miniRing:SetPoint("CENTER", loadoutPanel, "CENTER", -150, 0)

        -- mini pie background, same textures as ingame ring but smaller
        miniRing.PieBackground = miniRing:CreateTexture(nil, "BACKGROUND", nil, -1)
        miniRing.PieBackground:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Background]])
        miniRing.PieBackground:SetPoint("CENTER", miniRing, "CENTER", 0, 0)
        miniRing.PieBackground:SetSize(450, 450)
        miniRing.PieBackground:SetVertexColor(r * colMul, g * colMul, b * colMul)
        miniRing.PieBackground._rotation = 0

        miniRing.PieSeparators = {}
        local function RefreshMiniSeparators(totalSlots)
            for _, sep in ipairs(miniRing.PieSeparators) do sep:Hide() end
            miniRing.PieSeparators = {}
            local angleStep = 360 / totalSlots
            for i = 1, totalSlots do
                local sep = miniRing:CreateTexture(nil, "ARTWORK", nil, 2)
                sep:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Inactive]])
                sep:SetPoint("CENTER", miniRing, "CENTER", 0, 0)
                sep:SetSize(450, 450)
                sep:SetRotation(math.rad(270 - (i - 1) * angleStep + (angleStep * 0.5)))
                sep:SetAlpha(0.6)
                sep:Show()
                miniRing.PieSeparators[i] = sep
            end
        end

        miniRing:SetScript("OnUpdate", function(self, elapsed)
            if self.PieBackground:IsShown() then
                local rot = self.PieBackground._rotation + PIE_ROTATE_SPEED * elapsed
                self.PieBackground._rotation = rot
                self.PieBackground:SetRotation(rot)
            end
        end)

        miniRing.SlotFrames = {}
        local MINI_RADIUS = 100
        local MINI_SIZE   = 32  -- slightly smaller than main ring

        RefreshMiniSeparators(totalSlots)

        for i = 1, totalSlots do
            local angle = math.rad(90 - (i - 1) * (360 / totalSlots))
            local x = math.cos(angle) * MINI_RADIUS
            local y = math.sin(angle) * MINI_RADIUS

            local slot = CreateFrame("Button", nil, miniRing)
            slot:SetSize(MINI_SIZE, MINI_SIZE)
            slot:SetPoint("CENTER", miniRing, "CENTER", x, y)
            slot:SetAlpha(0.9)
            slot:RegisterForClicks("RightButtonUp")

            -- icon
            local icon = slot:CreateTexture(nil, "BACKGROUND")
            icon:SetSize(MINI_SIZE, MINI_SIZE)
            icon:SetPoint("CENTER", slot, "CENTER", 0, 0)
            slot.icon = icon

            -- empty icon
            local empty = slot:CreateTexture(nil, "BACKGROUND")
            empty:SetSize(MINI_SIZE, MINI_SIZE)
            empty:SetPoint("CENTER", slot, "CENTER", 0, 0)
            SetPortraitToTexture(empty, [[Interface\AddOns\ConsolePort\Textures\Button\EmptyIcon]])
            empty:SetDesaturated(true)
            empty:SetVertexColor(0.4, 0.4, 0.4, 1)
            slot.empty = empty

            -- Normal texture (round button face)
            local normal = slot:CreateTexture(nil, "OVERLAY")
            normal:SetTexture([[Interface\AddOns\ConsolePort\Textures\Button\Normal]])
            normal:SetAllPoints(slot)

            -- Hilite
            local hilite = slot:CreateTexture(nil, "OVERLAY", nil, 6)
            hilite:SetTexture([[Interface\AddOns\ConsolePort\Textures\Button\Hilite]])
            hilite:SetAllPoints(slot)
            hilite:SetBlendMode("ADD")
            hilite:SetAlpha(0)

            local PieSepLeft, PieSepRight

            if miniRing.PieSeparators then
                local slotIndex = i
                if slotIndex then
                    for i, sep in ipairs(miniRing.PieSeparators) do
                        local left  = slotIndex % totalSlots + 1
                        local right = (slotIndex - 1) % totalSlots + 1

                        PieSepLeft = i == left and sep or PieSepLeft
                        PieSepRight = i == right and sep or PieSepRight
                    end
                end
            end

            slot:SetScript("OnEnter", function(s)                
                if(PieSepLeft and PieSepRight) then
                    PieSepLeft:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Active]])
                    PieSepRight:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Active]])
                end

                hilite:SetAlpha(1)
                local ring = Core:GetRing(selectedRingID)
                local info = ring and ring.Data and ring.Data[s.slotIndex]
                if info and info.action then  
                    GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                    if info.action == 'item' then
                        local _, itemlink = GetItemInfo(info.value or info.cursorID)
                        if itemlink then GameTooltip:SetHyperlink(itemlink) end 
                    elseif info.action == 'spell' then
                        if info.mountID then
                            GameTooltip:SetHyperlink(string.format("|cff71d5ff|Hspell:%d|h[%s]|h|r", info.mountID, info.value))
                        else
                            local link = GetSpellLink(info.value)
                            if link then GameTooltip:SetHyperlink(link) end
                        end
                    elseif info.action == 'macro' then
                        local name, _, body = GetMacroInfo(info.value)
                        GameTooltip:ClearLines() 
                        GameTooltip:AddLine(name, 1, 0.82, 0) 
                        GameTooltip:AddLine(" ") 
                        if body and body ~= "" then
                            for line in string.gmatch(body, "[^\r\n]+") do
                                GameTooltip:AddLine(line, 1, 1, 1, true)
                            end
                        end

                        GameTooltip:Show()
                    end
                else 
                    GameTooltip:Hide()
                end
            end)
            slot:SetScript("OnLeave", function()
                if(PieSepLeft and PieSepRight) then
                    PieSepLeft:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Inactive]])
                    PieSepRight:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Inactive]])
                end
        
                hilite:SetAlpha(0)
                GameTooltip:Hide()
            end)

            slot:SetScript("OnClick", function(s, btn)
                if btn == "RightButton" and selectedRingID then
                    local ring = Core:GetRing(selectedRingID)
                    if ring and ring.Data then
                        -- clear from data table
                        ring.Data[s.slotIndex] = nil

                        -- also clear the live button's attribute cache so it doesn't repopulate
                        if not InCombatLockdown() then
                            local liveButton = _G["ConsolePortUtilityToggleButton" .. s.slotIndex]
                            if liveButton then
                                -- this triggers OnAttributeChanged -> OnContentRemoved
                                -- which properly clears the prefixed attribute cache too
                                liveButton:SetAttribute("type", nil)

                                local prefix = "ring" .. selectedRingID .. "-"
                                liveButton:SetAttribute(prefix .. "type",     nil)
                                liveButton:SetAttribute(prefix .. "id",       nil)
                                liveButton:SetAttribute(prefix .. "cursorID", nil)
                                liveButton:SetAttribute(prefix .. "mountID",  nil)
                            end
                        end

                        loadoutPanel:Refresh()
                        ringsPanel:UpdateSlots(selectedRingID)
                        RefreshRingList()
                    end
                end
            end)

            slot.slotIndex = i
            miniRing.SlotFrames[i] = slot
        end

        function miniRing:Update(ringID)
            local r = ringID and Core:GetRing(ringID)
            for i, slot in ipairs(self.SlotFrames) do
                local info = r and r.Data and r.Data[i]
                if info and info.action then
                    local tex
                    if info.action == "item" then
                        tex = select(10, GetItemInfo(info.cursorID or info.value))
                    elseif info.action == "spell" then
                        tex = GetSpellTexture(info.value)
                            or select(3, GetSpellInfo(info.value))
                    elseif info.action == "macro" then
                        tex = select(2, GetMacroInfo(info.value))
                    end
                    if tex then
                        SetPortraitToTexture(slot.icon, tex)
                        slot.icon:Show()
                        slot.empty:Hide()
                    else
                        slot.icon:Hide()
                        slot.empty:Show()
                    end
                else
                    slot.icon:Hide()
                    slot.empty:Show()
                end
            end
        end

        -- hint
        local miniHint = miniRing:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        miniHint:SetPoint("BOTTOM", miniRing, "BOTTOM", 0, 10)
        miniHint:SetText(LOCALE.RIGHTCLICKREMOVE or "|cFFAAAAAA Right-click slot to remove|r")

        -- RIGHT: category browser
        local browserFrame = CreateFrame("Frame", nil, loadoutPanel)
        browserFrame:SetPoint("TOPLEFT",    loadoutPanel, "TOPLEFT",    300, -15)
        browserFrame:SetPoint("BOTTOMRIGHT", loadoutPanel, "BOTTOMRIGHT", -35, 15)

        -- category scroll
        local catScroll = db.Atlas.GetScrollFrame("$parentCatScroll", browserFrame, {
            childKey   = "List",
            childWidth = 250,
            stepSize   = 28,
            noMeta     = true,
        })
        catScroll:SetAllPoints(browserFrame)       

        local catChild  = catScroll.Child
        local catButtons = {}
        local catExpanded = {}

        local function RebuildCategoryList()
            -- hide old
            for _, b in ipairs(catButtons) do b:Hide() end
            catButtons = {}

            if not selectedRingID then
                catChild:SetHeight(1)
                return
            end

            local cats = BuildLoadoutCategories()
            local y = 0
            local ROW_H = 28
            local INDENT = 16

            for _, cat in ipairs(cats) do
                -- category header
                local header = CreateFrame("Button", nil, catChild)
                header:SetSize(260, ROW_H)
                header:SetPoint("TOPLEFT", 0, -y)

                local hbg = header:CreateTexture(nil, "BACKGROUND")
                hbg:SetAllPoints()
                hbg:SetTexture([[Interface\Buttons\WHITE8X8]])
                hbg:SetVertexColor(0.15, 0.12, 0.06, 0.8)

                local hhl = header:CreateTexture(nil, "HIGHLIGHT")
                hhl:SetAllPoints()
                hhl:SetTexture([[Interface\Buttons\WHITE8X8]])
                hhl:SetVertexColor(1, 1, 1, 0.05)

                local harrow = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                harrow:SetPoint("LEFT", 6, 0)
                harrow:SetText(catExpanded[cat.name] and "|cFFFFFFFF-|r" or "|cFFFFFFFF+|r")

                local hlabel = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                hlabel:SetPoint("LEFT", 20, 0)
                hlabel:SetText(cat.name)
                hlabel:SetTextColor(1, 0.82, 0.2, 1)

                local hcount = header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                hcount:SetPoint("RIGHT", -6, 0)
                hcount:SetTextColor(0.5, 0.5, 0.5, 1)

                -- count flat items or subcats
                local total = 0
                if #cat.items > 0 and type(cat.items[1]) == "table" and cat.items[1].items then
                    for _, sub in ipairs(cat.items) do total = total + #sub.items end
                else
                    total = #cat.items
                end
                hcount:SetText(total)

                table.insert(catButtons, header)
                y = y + ROW_H

                header:SetScript("OnClick", function()
                    catExpanded[cat.name] = not catExpanded[cat.name]
                    RebuildCategoryList()
                end)

                if catExpanded[cat.name] then
                    harrow:SetText("|cFFFFFFFF-|r")

                    -- determine if subcategories or flat
                    local isSubcat = #cat.items > 0 and type(cat.items[1]) == "table"
                        and cat.items[1].items

                    local function AddItemRow(info)
                        if not info or not info.name then return end
                        local row = CreateFrame("Button", nil, catChild)
                        row:SetSize(260, ROW_H)
                        row:SetPoint("TOPLEFT", INDENT, -y)

                        local rbg = row:CreateTexture(nil, "BACKGROUND")
                        rbg:SetAllPoints()
                        rbg:SetTexture([[Interface\Buttons\WHITE8X8]])
                        rbg:SetVertexColor(0.08, 0.06, 0.03, 0.6)

                        local rhl = row:CreateTexture(nil, "HIGHLIGHT")
                        rhl:SetAllPoints()
                        rhl:SetTexture([[Interface\Buttons\WHITE8X8]])
                        rhl:SetVertexColor(1, 1, 1, 0.08)

                        local ric = row:CreateTexture(nil, "ARTWORK")
                        ric:SetSize(20, 20)
                        ric:SetPoint("LEFT", 4, 0)
                        ric:SetTexture(info.texture or "Interface\\Icons\\INV_Misc_QuestionMark")
                        ric:SetTexCoord(0.08, 0.92, 0.08, 0.92)

                        local rname = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                        rname:SetPoint("LEFT", 28, 0)
                        rname:SetPoint("RIGHT", -6, 0)
                        rname:SetText(info.name)
                        rname:SetTextColor(0.9, 0.9, 0.9, 1)
                        rname:SetJustifyH("LEFT")

                        row:SetScript("OnEnter", function(s)
                            GameTooltip:SetOwner(s, "ANCHOR_RIGHT")
                            if info.action == 'item' then
                                local _, itemlink = GetItemInfo(info.value or info.cursorID)
                                if itemlink then GameTooltip:SetHyperlink(itemlink) end 
                            elseif info.action == 'spell' then
                                if info.mountID then
                                    GameTooltip:SetHyperlink(string.format("|cff71d5ff|Hspell:%d|h[%s]|h|r", info.mountID, info.value))
                                else
                                    local link = GetSpellLink(info.value)
                                    if link then GameTooltip:SetHyperlink(link) end
                                end
                            elseif info.action == 'macro' then
                                local name, _, body = GetMacroInfo(info.value)
                                GameTooltip:ClearLines() 
                                GameTooltip:AddLine(name, 1, 0.82, 0) 
                                GameTooltip:AddLine(" ") 
                                if body and body ~= "" then
                                    for line in string.gmatch(body, "[^\r\n]+") do
                                        GameTooltip:AddLine(line, 1, 1, 1, true)
                                    end
                                end

                                GameTooltip:Show()
                            end
                        end)
                        row:SetScript("OnLeave", function()
                            GameTooltip:Hide()
                        end)

                        row:SetScript("OnClick", function()
                            if not selectedRingID then return end
                            ConsolePort:AddUtilityAction(info.action, info.value, selectedRingID)
                            loadoutPanel:Refresh()
                            ringsPanel:UpdateSlots(selectedRingID)
                            RefreshRingList()
                        end)

                        table.insert(catButtons, row)
                        y = y + ROW_H
                    end

                    if isSubcat then
                        for _, sub in ipairs(cat.items) do
                            -- subcat header
                            local subh = CreateFrame("Frame", nil, catChild)
                            subh:SetSize(260, ROW_H)
                            subh:SetPoint("TOPLEFT", INDENT / 2, -y)

                            local sbg = subh:CreateTexture(nil, "BACKGROUND")
                            sbg:SetAllPoints()
                            sbg:SetTexture([[Interface\Buttons\WHITE8X8]])
                            sbg:SetVertexColor(0.1, 0.08, 0.04, 0.5)

                            local slabel = subh:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                            slabel:SetPoint("LEFT", 8, 0)
                            slabel:SetText(sub.name)
                            slabel:SetTextColor(0.7, 0.7, 0.5, 1)

                            table.insert(catButtons, subh)
                            y = y + ROW_H

                            for _, info in ipairs(sub.items) do
                                AddItemRow(info)
                            end
                        end
                    else
                        for _, info in ipairs(cat.items) do
                            AddItemRow(info)
                        end
                    end
                end
            end

            catChild:SetHeight(math.max(y, 1))
        end

        function loadoutPanel:Refresh()
            if not selectedRingID then
                self.EmptyLabel:Show()
                miniRing:Hide()
                browserFrame:Hide()
                return
            end
            self.EmptyLabel:Hide()
            miniRing:Show()
            browserFrame:Show()
            miniRing:Update(selectedRingID)
            RebuildCategoryList()
        end

        -----------------------------------------------------------
        -- TAB: OPTIONS
        -----------------------------------------------------------
        local optionsPanel = CreateFrame("Frame", "$parentOptionsPanel", rightPanel)
        optionsPanel:SetAllPoints()
        optionsPanel:Hide()

        -- empty state
        optionsPanel.EmptyLabel = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        optionsPanel.EmptyLabel:SetPoint("CENTER", 0, 0)
        optionsPanel.EmptyLabel:SetText(LOCALE.RINGSEL or "Select a ring to edit options.")
        optionsPanel.EmptyLabel:SetTextColor(0.6, 0.5, 0.2, 1)

        local OPT_X, OPT_Y = 30, -30
        local OPT_ROW = 60

        -- Name row
        local nameRow = CreateFrame("Frame", nil, optionsPanel)
        nameRow:SetSize(560, OPT_ROW)
        nameRow:SetPoint("TOPLEFT", OPT_X, OPT_Y)

        local nameLabel = nameRow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        nameLabel:SetPoint("LEFT", 0, 0)
        nameLabel:SetText(LOCALE.NAME or "Name:")
        nameLabel:SetWidth(80)
        nameLabel:SetJustifyH("LEFT")

        optionsPanel.RingNameValue = nameRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        optionsPanel.RingNameValue:SetPoint("LEFT", nameLabel, "RIGHT", 10, 0)
        optionsPanel.RingNameValue:SetText("")

        optionsPanel.RenameButton = db.Atlas.GetFutureButton(
            "$parentRenameButton", nameRow, nil, nil, 100, 30)
        optionsPanel.RenameButton:SetPoint("RIGHT", nameRow, "RIGHT", -10, 0)
        optionsPanel.RenameButton:SetText(LOCALE.RENAME or "Rename")
        optionsPanel.RenameButton:SetScript("OnClick", function()
            if not selectedRingID then return end
            local r = Core:GetRing(selectedRingID)
            if r then renameFrame:Open(selectedRingID, r.Name) end
        end)

        -- Icon row
        local iconRow = CreateFrame("Frame", nil, optionsPanel)
        iconRow:SetSize(560, OPT_ROW)
        iconRow:SetPoint("TOPLEFT", OPT_X, OPT_Y - OPT_ROW)

        local iconLabel = iconRow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        iconLabel:SetPoint("LEFT", 0, 0)
        iconLabel:SetText(LOCALE.ICON or "Icon:")
        iconLabel:SetWidth(80)
        iconLabel:SetJustifyH("LEFT")

        optionsPanel.RingIcon = iconRow:CreateTexture(nil, "ARTWORK")
        optionsPanel.RingIcon:SetSize(30, 30)
        optionsPanel.RingIcon:SetPoint("LEFT", iconLabel, "RIGHT", 10, 0)

        optionsPanel.SetIconButton = db.Atlas.GetFutureButton(
            "$parentSetIconButton", iconRow, nil, nil, 100, 30)
        optionsPanel.SetIconButton:SetPoint("RIGHT", iconRow, "RIGHT", -10, 0)
        optionsPanel.SetIconButton:SetText(LOCALE.SETICON or "Set Icon")
        optionsPanel.SetIconButton:SetScript("OnClick", function()
            if not selectedRingID then return end
            iconPicker:Refresh(function(tex)
                SetPortraitToTexture(optionsPanel.RingIcon, tex)
                local r = Core:GetRing(selectedRingID)
                if r then r.Icon = tex end
                if RingManager.WorkingCopy then RingManager.WorkingCopy.Icon = tex end
                ringsPanel:Refresh(selectedRingID)
                RefreshRingList()
            end)
            Popup:SetPopup(LOCALE.CHOOSEICON or "Choose Icon", iconPicker, nil, nil, 500, 420)
        end)

        -- Auto assign row
        local autoRow = CreateFrame("Frame", nil, optionsPanel)
        autoRow:SetSize(560, OPT_ROW)
        autoRow:SetPoint("TOPLEFT", OPT_X, OPT_Y - OPT_ROW * 2)

        optionsPanel.AutoAssignSetting = CreateFrame(
            'CheckButton', '$parentAutoAssignSetting', autoRow, 'ChatConfigCheckButtonTemplate')
        local check = optionsPanel.AutoAssignSetting
        local checkText = check:CreateFontString(nil, 'OVERLAY', 'GameFontHighlight')
        checkText:SetText(TUTORIAL.CONFIG.AUTOEXTRA)
        checkText:SetPoint('LEFT', check, 30, 0)
        check.Description = checkText
        check:SetPoint("LEFT", 0, 0)
        check:SetScript('OnClick', function(self)
            if RingManager.WorkingCopy then
                RingManager.WorkingCopy.Autoassign = self:GetChecked()
            end
        end)

        -- Binding row
        local bindRow = CreateFrame("Frame", nil, optionsPanel)
        bindRow:SetSize(560, OPT_ROW + 20)
        bindRow:SetPoint("TOPLEFT", OPT_X, OPT_Y - OPT_ROW * 3)

        local bindLabel = bindRow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        bindLabel:SetPoint("TOPLEFT", 0, 0)
        bindLabel:SetText(LOCALE.BINDING or "Binding:")

        local bindWrapper = db.Atlas.GetGlassWindow(
            '$parentBindWrapper', bindRow, nil, true)
        bindWrapper:SetBackdrop(db.Atlas.Backdrops.Border)
        bindWrapper:SetPoint('TOPLEFT', 0, -24)
        bindWrapper:SetSize(300, 80)
        bindWrapper.Close:Hide()
        bindWrapper:Show()

        optionsPanel.BindCatcher = db.Atlas.GetFutureButton(
            '$parentBindCatcher', bindWrapper, nil, nil, 270)
        optionsPanel.BindCatcher.HighlightTexture:ClearAllPoints()
        optionsPanel.BindCatcher.HighlightTexture:SetAllPoints(optionsPanel.BindCatcher)
        optionsPanel.BindCatcher:SetHeight(44)
        optionsPanel.BindCatcher:SetPoint('CENTER', 0, 0)
        optionsPanel.BindCatcher.Cover:Hide()

        -- separator line before danger zone
        local sep = optionsPanel:CreateTexture(nil, "ARTWORK")
        sep:SetTexture([[Interface\Buttons\WHITE8X8]])
        sep:SetVertexColor(1, 1, 1, 0.06)
        sep:SetSize(540, 1)
        sep:SetPoint("TOPLEFT", OPT_X, OPT_Y - OPT_ROW * 5 + 10)

        -- Danger zone label
        local dangerLabel = optionsPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        dangerLabel:SetPoint("TOPLEFT", OPT_X, OPT_Y - OPT_ROW * 5)
        dangerLabel:SetText(LOCALE.DANGERZONE or "Ring Actions")
        dangerLabel:SetTextColor(0.8, 0.3, 0.3, 1)

        -- Clear All button
        optionsPanel.ClearAllButton = db.Atlas.GetFutureButton(
            "$parentClearAllButton", optionsPanel, nil, nil, 160, 40)
        optionsPanel.ClearAllButton:SetPoint("TOPLEFT", OPT_X, OPT_Y - OPT_ROW * 5 - 20)
        optionsPanel.ClearAllButton:SetText(LOCALE.CLEARALL or "Clear All")
        optionsPanel.ClearAllButton:SetScript("OnClick", function()
            if not selectedRingID then return end
            ShowConfirmPopup(
                LOCALE.CLEARALL or "Clear All",
                LOCALE.CONFIRMCLEAR or "Remove all items from this ring?",
                function()
                    Core:ClearRing(selectedRingID)
                    loadoutPanel:Refresh()
                    ringsPanel:UpdateSlots(selectedRingID)
                    RefreshRingList()
                end)
        end)

        -- Delete button
        optionsPanel.DeleteButton = db.Atlas.GetFutureButton(
            "$parentDeleteButton", optionsPanel, nil, nil, 160, 40)
        optionsPanel.DeleteButton:SetPoint("LEFT", optionsPanel.ClearAllButton, "RIGHT", 10, 0)
        optionsPanel.DeleteButton:SetText(LOCALE.DELETE or "Delete Ring")
        optionsPanel.DeleteButton:SetScript("OnClick", function()
            if not selectedRingID then return end
            if selectedRingID == 1 then return end
            local r = Core:GetRing(selectedRingID)
            ShowConfirmPopup(
                LOCALE.DELETERING or "Delete Ring",
                (LOCALE.CONFIRMDELETE or "Delete '%s'?"):format(r and r.Name or ""),
                function()
                    Core:DeleteRing(selectedRingID)
                    selectedRingID = nil
                    RefreshRingList()
                    RingManager:OnRingSelected(nil)
                end)
        end)

        -- Save button
        optionsPanel.SaveButton = db.Atlas.GetFutureButton(
            "$parentSaveButton", optionsPanel, nil, nil, 160, 46)
        optionsPanel.SaveButton:SetPoint("BOTTOMRIGHT", optionsPanel, "BOTTOMRIGHT", -20, 20)
        optionsPanel.SaveButton:SetText(LOCALE.SAVE or "Save")
        optionsPanel.SaveButton:SetScript("OnClick", function()
            if not selectedRingID or not RingManager.WorkingCopy then return end
            local copy = RingManager.WorkingCopy
            Core:UpdateRingMeta(selectedRingID, copy.Name, copy.Icon, copy.Autoassign)
            Core:UpdateRingBinding(selectedRingID, copy.Binding)
            RefreshRingList()
            ConsolePort:RunOOC(ConsolePort.SetupUtilityBindings)
        end)

        function optionsPanel:Refresh(ringID)
            if not ringID then
                self.EmptyLabel:Show()
                nameRow:Hide()
                iconRow:Hide()
                autoRow:Hide()
                bindRow:Hide()
                sep:Hide()
                dangerLabel:Hide()
                self.ClearAllButton:Hide()
                self.DeleteButton:Hide()
                self.SaveButton:Hide()
                return
            end

            self.EmptyLabel:Hide()
            nameRow:Show()
            iconRow:Show()
            autoRow:Show()
            bindRow:Show()
            sep:Show()
            dangerLabel:Show()
            self.ClearAllButton:Show()
            self.DeleteButton:Show()
            self.SaveButton:Show()

            local r = Core:GetRing(ringID)
            if not r then return end

            self.RingNameValue:SetText(r.Name or "")
            SetPortraitToTexture(self.RingIcon,
                r.Icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            self.AutoAssignSetting:SetChecked(r.Autoassign)

            -- disable delete for ring 1
            CPAPI.SetEnabled(self.DeleteButton, ringID ~= 1)

            -- refresh catcher
            self.BindCatcher:OnShow()
        end

        -- wire catcher mixin
        Mixin(optionsPanel.BindCatcher, Catcher)
        optionsPanel.BindCatcher:OnShow()

        -----------------------------------------------------------
        -- Build tabs after panels exist
        -----------------------------------------------------------
        for i, def in ipairs(tabDefs) do
            local panel = (def.key == "rings" and ringsPanel)
                       or (def.key == "loadout" and loadoutPanel)
                       or optionsPanel

            local btn = db.Atlas.GetFutureButton(
                ("$parentTab%d"):format(i), tabContainer, nil, nil, TAB_W, TAB_H)
            btn:SetPoint("LEFT", (i - 1) * TAB_W, 0)
            btn:SetText(def.label)
            btn:SetAlpha(i == 1 and 1 or 0.5)
            btn:SetScript("OnClick", function() SwitchTab(def.key) end)

            tabs[i] = { key = def.key, btn = btn, panel = panel }
        end

        -----------------------------------------------------------
        -- OnRingSelected: called whenever selected ring changes
        -----------------------------------------------------------
        function RingManager:OnRingSelected(ringID)
            ringsPanel:Refresh(ringID)
            loadoutPanel:Refresh()
            optionsPanel:Refresh(ringID)
        end

        -----------------------------------------------------------
        -- RefreshAll: full refresh after data changes
        -----------------------------------------------------------
        function RingManager:RefreshAll()
            RefreshRingList()
            self:OnRingSelected(selectedRingID)
        end

        -----------------------------------------------------------
        -- WindowMixin stubs
        -----------------------------------------------------------
        function WindowMixin:Default() end
        function WindowMixin:Save() end

        -----------------------------------------------------------
        -- Initial state
        -----------------------------------------------------------
        SwitchTab("rings")
        RefreshRingList()
        RingManager:OnRingSelected(nil)
    end
}