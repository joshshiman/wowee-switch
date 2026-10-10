---------------------------------------------------------------
-- Utility.lua: Main radial action bar  
---------------------------------------------------------------
-- Creates an action bar that can be populated with
-- items, spells, mounts, macros, etc. The user may manually
-- assign items from container buttons inside bag frames.
-- Action buttons can grab info from cursor.

-- Now with the possibility to have multiple utility rings by creating new presets.

---------------------------------------------------------------
local addOn, db = ...
local CPAPI = db.CPAPI
---------------------------------------------------------------
local ConsolePort = ConsolePort
---------------------------------------------------------------
local FadeIn, FadeOut = db.GetFaders()
local GetItemCooldown = GetItemCooldown
local InCombatLockdown = InCombatLockdown
---------------------------------------------------------------
local 	Utility, Tooltip, Animation, AniCircle = 
		ConsolePortUtilityToggle,
		ConsolePortUtilityToggle.Tooltip,
		CreateFrame('Frame', 'ConsolePortUtilityAnimation', UIParent),
		CreateFrame('Frame', 'ConsolePortUtilityAnimationCircle', UIParent)
---------------------------------------------------------------
local red, green, blue = db.Atlas.GetCC()
local colMul = 1 + ( 1 - (( red + green + blue ) / 3) )
---------------------------------------------------------------
local DROP_TYPES = {
	item = true,
	spell = true,
	macro = true,
	mount = true,
	companion = true,
}

local TEXTURE_GETS = {
	----------------------------------
	item   = function(id) if id then return select(10, GetItemInfo(id)), select(12, GetItemInfo(id)) == 12 end end;
	spell  = function(id) if id then return select(3, GetSpellInfo(id)), nil end end;
	companion  = function(id) if id then return select(3, GetSpellInfo(id)), nil end end;
	macro  = function(id) if id then return select(2, GetMacroInfo(id)), nil end end;
	action = function(id) if id then return GetActionTexture(id) end end;
	custom = function(id)
        if id and ConsolePort.GetCustomBindingsForRings then
            for _, info in ipairs(ConsolePort:GetCustomBindingsForRings()) do
                if info.binding == id then return info.texture end
            end
        end
    end;
	----------------------------------
	none = function(id) return end;
} setmetatable(TEXTURE_GETS,{__index = function(t) return t.none end})

local TRANSLATE_CURSOR_INFO = {
	----------------------------------
	item = function(self, id)
		if tonumber(id) then
			self:SetAttribute('item', GetItemInfo(id))
			return true
		end
	end;
	--companion = function(self, id)
	--	local _, _, petSpellID = GetCompanionInfo(detail)
	--	local petName = GetSpellInfo(petSpellID)
	--	self:SetAttribute("mountID", petSpellID)
	--	self:SetAttribute("type", "spell")
	--	self:SetAttribute("spell", petName)
	--	return true
	--end;
	----------------------------------
	none = function(id) return end;
} setmetatable(TRANSLATE_CURSOR_INFO,{__index = function(t) return t.none end})
---------------------------------------------------------------

function Animation:ShowNewAction(actionButton, autoassigned, presetID)
	-- if an item was auto-assigned, postpone its animation until the current animation has finished
	if  autoassigned and self.Group:IsPlaying() then
		local progress = self.Group:GetDuration() * self.Group:GetProgress()
		local delay = self.Group:GetDuration() - progress
		CPAPI.TimerAfter(delay, function() self:ShowNewAction(actionButton, true) end)
		return
	end
	if actionButton.isQuest then
		self.Quest:Show()
	else
		self.Quest:Hide()
	end
	local scale = Utility.frameScale or 1

	if(presetID) then
		local actionData = ConsolePortUtility[presetID].Data[actionButton:GetID()]
		SetPortraitToTexture(self.Icon, TEXTURE_GETS[actionData.type](actionData.value))
	else 
		SetPortraitToTexture(self.Icon, actionButton.Icon.texture)
	end
	--self.Spell:SetSize(175, 175)
	self:ClearAllPoints()
	self:SetPoint('CENTER', actionButton)
	self:SetScale(scale)
	self:Show()
	self.Group:Stop()
	self.Group:Play()
	--FadeOut(self.Spell, 3, 0.15, 0)

	local activePreset = presetID and presetID or tonumber(Utility:GetAttribute("ActivePreset") or 1)

	if ConsolePortUtility[activePreset].Data and ConsolePortUtility[activePreset].Data[actionButton:GetID()] then
		local value = ConsolePortUtility[activePreset].Data[actionButton:GetID()].value
		local binding = ConsolePort:GetFormattedBindingOwner(Utility:GetBindingForSet(activePreset), nil, nil, true)
		if value then
			local string = binding and ' '..binding or '.'
			if value and not tonumber(value) then
				if(isNotDefault) then
					db.Hint:DisplayMessage(format(db.TUTORIAL.HINTS.UTILITY_RING_NEWBIND_P, value, ConsolePortUtility[activePreset].Name, string), 3, -190)
				else 
					db.Hint:DisplayMessage(format(db.TUTORIAL.HINTS.UTILITY_RING_NEWBIND, value, string), 3, -190)
				end
			elseif binding then
				db.Hint:DisplayMessage(format(db.TUTORIAL.HINTS.UTILITY_RING_BIND, binding), 3, -190)
			end
		end
	end

	local angle = actionButton:GetAttribute('rotation')
	AniCircle:Show()
	AniCircle:SetScale(scale)
	AniCircle.Ring:SetRotation(angle)
	AniCircle.Arrow:SetRotation(angle)
	AniCircle.Runes:SetRotation(angle)
	FadeOut(AniCircle, 3, 1, 0)
end

function Animation:ShowPresetAction(presetID, slotIndex, value)
    self:ShowNewAction(Utility.Buttons[slotIndex], false, presetID ~= 1 and presetID)
end


local function AnimateOnFinished(self)
	AniCircle:Hide()
	self:GetParent():Hide()
end

-- called from secure scope (e.g. extra action button 1 appears)
function Utility:AnimateNew(button) Animation:ShowNewAction(_G[button], true) end


---------------------------------------------------------------
-- Add action to free actionbutton
---------------------------------------------------------------
local function AddAction(actionType, ID, autoassigned)
	ID = tonumber(ID) or ID
	local alreadyBound
	for id, ActionButton in pairs(Utility.Buttons) do
		alreadyBound = 	( ActionButton:GetAttribute('type') == actionType and
						( ActionButton:GetAttribute('cursorID') == ID or ActionButton:GetAttribute(actionType) == ID) ) and id
		if alreadyBound then
			break
		end
	end
	if alreadyBound and not autoassigned then
		Animation:ShowNewAction(Utility.Buttons[alreadyBound])
	elseif not alreadyBound then
		for _, ActionButton in ipairs(Utility.Buttons) do
			if not ActionButton:GetAttribute('type') then
				if actionType == 'item' then
					ActionButton:SetAttribute('cursorID', ID)
				end
				ActionButton:SetAttribute('autoassigned', autoassigned)
				ActionButton:SetAttribute('type', actionType)
				ActionButton:SetAttribute(actionType, ID)
				Animation:ShowNewAction(ActionButton, autoassigned)
				break
			end 
		end
	end
end


---------------------------------------------------------------
-- Manage auto-assigned items (quest items)
---------------------------------------------------------------
local function AddItemForQuestLogIndex(itemTbl, questLogIndex)
	if questLogIndex then
		local link = GetQuestLogSpecialItemInfo(questLogIndex)
		local name = link and GetItemInfo(link)
		if name then
			local _, itemID = strsplit(':', strmatch(link, 'item[%-?%d:]+'))
			if itemID then
				itemTbl[name] = itemID
			end
		end
	end
end

local function GetQuestWatchItems()
	local items = {}
	for i=1, CPAPI:GetNumQuestWatches() do
		AddItemForQuestLogIndex(items, GetQuestIndexForWatch(i))
	end
	return items
end

local function GetAutoAssignedItems()
	local items = {}
	for _, button in ipairs(Utility.Buttons) do
		local itemID = button:GetAutoAssigned()
		if itemID then
			items[itemID] = button
		end
	end
	return items
end

local function UpdateQuestItems(self)
    if not InCombatLockdown() then
        local newItems = GetQuestWatchItems()

        for _, preset in ipairs(ConsolePortUtility) do
            if preset.Autoassign then
                -- prune only auto-assigned items that are no longer in the quest watch
                for buttonID, buttonData in pairs(preset.Data) do
                    local currentItem = buttonData.cursorID
                    if buttonData.autoassigned and currentItem and not newItems[currentItem] then
                        preset.Data[buttonID] = nil
                    end
                end

                -- add new quest items that aren't already assigned
                for newItemName, newItemID in pairs(newItems) do
                    local alreadyAssigned = false
                    for _, buttonData in pairs(preset.Data) do
                        if buttonData.cursorID == newItemID then
                            alreadyAssigned = true
                            break
                        end
                    end

                    if not alreadyAssigned then
                        for _, actionButton in ipairs(Utility.Buttons) do
                            if not actionButton:GetAttribute('type') then
                                local buttonID = actionButton:GetID()
                                preset.Data[buttonID] = {
                                    action       = 'item',
                                    value        = newItemID,
                                    cursorID     = newItemID,
                                    autoassigned = true,
                                    mountID      = nil,
                                }
                                break
                            end
                        end
                    end
                end
            end
        end

        self:RemoveUpdateSnippet(UpdateQuestItems)
    end
end




---------------------------------------------------------------
-- Tooltip 
---------------------------------------------------------------
function Tooltip:Refresh()
	if self.castButton then
		self:AddLine(self.castInfo:format(db.TEXTURE[self.castButton]))
	end
	self:AddLine(self.removeInfo:format(db.TEXTURE.CP_T_R3))
end

function Tooltip:OnShow()	
	local activePreset = tonumber(Utility:GetAttribute("ActivePreset") or 1)
	self.castButton = ConsolePort:GetCurrentBindingOwner(Utility:GetBindingForSet(activePreset))
	-- set CC backdrop
	self:SetBackdropColor(red*0.15, green*0.15, blue*0.15,  0.75)
	self:Refresh()
	FadeIn(self, 0.2, 0, 1)
end





---------------------------------------------------------------
-- Radial action button handler
---------------------------------------------------------------
-- Manages radial action buttons. These action buttons behave
-- similarly to normal action buttons, but abstracts frontend
-- so that RABs don't need to handle state updates.
-- Callbacks:
--     OnContentChanged()
--     OnContentRemoved()
---------------------------------------------------------------
ConsolePortRingButtonMixin = {}
--------------------------------------------------------------- 

----------------------------------
-- Script handlers
----------------------------------
function ConsolePortRingButtonMixin:OnLoad()
	local border = self.Border
	self.Highlight = border.Highlight
	self.Quest = border.Quest
	self.Pushed:SetParent(border)
	self.Pushed:SetDrawLayer('OVERLAY', 5)
	self.NormalTexture:SetParent(border)
	self.NormalTexture:SetDrawLayer('OVERLAY', 4)

	self.Tooltip = self:GetParent().Tooltip
	self.FadeIn, self.FadeOut = ConsolePort:GetData().GetFaders()
end

function ConsolePortRingButtonMixin:OnEnter()
	self:SetFocus(true)
	--self.FadeIn(self.Pushed, 0.1, self.Pushed:GetAlpha(), 1)
	--self.FadeIn(self.Highlight, 0.1, self.Highlight:GetAlpha(), 1)
	--self.FadeOut(self.NormalTexture, 0.1, self.NormalTexture:GetAlpha(), 1)
	--self.FadeOut(self.Quest, 0.1, self.Quest:GetAlpha(), 0)
end

function ConsolePortRingButtonMixin:OnLeave()
	self:SetFocus(false)
	--self.FadeOut(self.Pushed, 0.2, self.Pushed:GetAlpha(), 0)
	--self.FadeOut(self.Highlight, 0.2, self.Highlight:GetAlpha(), 0)
	--self.FadeIn(self.NormalTexture, 0.2, self.NormalTexture:GetAlpha(), 0.75)
	--self.FadeIn(self.Quest, 0.2, self.Quest:GetAlpha(), 1)
end

function ConsolePortRingButtonMixin:PreClick(button)
	if not InCombatLockdown() then
		if button == 'RightButton' then
			self:SetAttribute('custombinding', nil)
            self:SetAttribute('macrotext', nil)
            self:SetAttribute('type', nil)
			self.Cooldown:SetCooldown(0, 0)
			self.Count:SetText()
			ClearCursor()
		elseif DROP_TYPES[GetCursorInfo()] then
			self:SetAttribute('custombinding', nil)
            self:SetAttribute('macrotext', nil)
			self:SetAttribute('type', nil)
		end
	end
end

function ConsolePortRingButtonMixin:PostClick(button) 
	if DROP_TYPES[GetCursorInfo()] then
		local cursorType, id, companionType, spellID = GetCursorInfo()
		local SpellBookFrame = CPAPI.IsCustomClient() and CPAPI.GetCustomFrame("SpellBookFrame") or SpellBookFrame
		
		ClearCursor()

		if InCombatLockdown() then return end

		local newValue
		-- Convert spellID to name
		if cursorType == "spell" then
			local spellName, subSpellName = GetSpellName(id, SpellBookFrame.bookType); 
			local link = GetSpellLink(spellName, subSpellName);  
			newValue = select(3, strfind(link, "spell:(%d+)")) 
		elseif cursorType == "companion" then 
			local _, _, petSpellID = GetCompanionInfo(companionType, id)  
			newValue = GetSpellInfo(petSpellID)
			self:SetAttribute("mountID", petSpellID)
			cursorType = "spell"
		end

		self:SetAttribute('type', cursorType)
		self:SetAttribute('cursorID', id)
		self:SetAttribute(cursorType, newValue or id)
	end
end


function ConsolePortRingButtonMixin:OnAttributeChanged(attribute, detail)
	if(InCombatLockdown()) then return end

    -- only react to attributes that actually represent button content
    if attribute ~= 'type' and attribute ~= 'item' and attribute ~= 'spell'
       and attribute ~= 'macro' and attribute ~= 'action' and attribute ~= 'custombinding' then
        return
    end

    if detail then
        if TRANSLATE_CURSOR_INFO[attribute](self, detail) then return end
        ClearCursor()
    end

    self:UpdateTexture()
	
    if Utility.clearing then return end 

	local actionType = self:GetAttribute('custombinding') and 'custom' or self:GetAttribute('type')

    if actionType then 
        self:OnContentChanged(actionType)
    else 
        self:SetAttribute('autoassigned', nil)
        self:OnContentRemoved()
    end
end


function ConsolePortRingButtonMixin:OnTooltipUpdate(elapsed)
    self.idle = self.idle + elapsed
    if self.idle > 0.5 then -- Snappier for Steam Deck
        -- 1. Get the current active ring index
        local activePresetID = tonumber(self:GetParent():GetAttribute("ActivePreset") or 1)
        
        -- 2. Reach directly into the DB for this button's ID
        local preset = ConsolePortUtility[activePresetID]
        local info = preset and preset.Data and preset.Data[self:GetID()]

        if info and info.action then
            self.Tooltip:SetOwner(self, 'ANCHOR_BOTTOM', 0, -16)
            
            if info.action == 'item' then
                local _, itemlink = GetItemInfo(info.value or info.cursorID)
                if itemlink then self.Tooltip:SetHyperlink(itemlink) end
                
            elseif info.action == 'spell' then
                if info.mountID then
                    -- Use the specific spell link for mounts
                    self.Tooltip:SetHyperlink(string.format("|cff71d5ff|Hspell:%d|h[%s]|h|r", info.mountID, info.value))
                else
                    local link = GetSpellLink(info.value)
                    if link then self.Tooltip:SetHyperlink(link) end
                end
            elseif info.action == 'macro' then
                local macroName = GetMacroInfo(info.value)
                if macroName then self.Tooltip:SetText(macroName, 1, 1, 1) end
            elseif info.action == 'custom' then
                local name = "Custom Binding"
                if ConsolePort.GetCustomBindingsForRings then
                    for _, bindInfo in ipairs(ConsolePort:GetCustomBindingsForRings()) do
                        if bindInfo.binding == info.value then
                            name = bindInfo.name or name
                            break
                        end
                    end
                end
                self.Tooltip:SetText(name, 1, 1, 1)
            end
        else
            -- If the slot is empty, hide the tooltip
            self.Tooltip:Hide()
        end
        self:SetScript('OnUpdate', nil)
    end
end

----------------------------------
-- Tooltip
----------------------------------

function ConsolePortRingButtonMixin:SetFocus(enabled)
	if self.Tooltip then
		if enabled then
			self.idle = 0
			self:SetScript('OnUpdate', self.OnTooltipUpdate)
		else
			if self.Tooltip:IsOwned(self) then
				self.Tooltip:Hide()
			end
			self:SetScript('OnUpdate', nil)
		end
	end
end

----------------------------------
-- Button data
----------------------------------

function ConsolePortRingButtonMixin:SetCooldown(time, cooldown, enable)
	if time and cooldown then
		self.onCooldown = true
		self.Cooldown:SetCooldown(time, cooldown, enable)
	else
		self.onCooldown = false
		self.Cooldown:SetCooldown(0, 0)
	end
end

function ConsolePortRingButtonMixin:SetCharges(charges) 
	self.Count:SetText(charges)
end

function ConsolePortRingButtonMixin:SetUsable(isUsable)
	local vxc = isUsable and 1 or 0.5
	self.Icon:SetVertexColor(vxc, vxc, vxc)
end

function ConsolePortRingButtonMixin:UpdateState()
	local action = self:GetAttribute('custombinding') and 'custom' or self:GetAttribute('type')
	self:UpdateTexture(action) 

	if action == 'item' then
		local item = self:GetAttribute('item')
		if item then
			local count = GetItemCount(item)
			local _, _, maxStack = select(6, GetItemInfo(item))
			self:SetCooldown(GetItemCooldown(self:GetAttribute('cursorID')))
			self:SetUsable(IsUsableItem(item))
			self:SetCharges(maxStack and maxStack > 1 and (count or 0))
		end
	elseif action == 'spell' then
		local spellID = self:GetAttribute('spell')
		if spellID then
			local spellName = GetSpellInfo(spellID)
			if(IsConsumableSpell and IsConsumableSpell(CPAPI.IsCustomClient() and spellID or spellName)) then
				self:SetCharges(GetSpellCount(CPAPI.IsCustomClient() and spellID or spellName))
			end
			self:SetUsable(IsUsableSpell(CPAPI.IsCustomClient() and spellID or spellName))
			self:SetCooldown(GetSpellCooldown(spellID))
		end
	elseif action == 'action' then
		local actionID = self:GetAttribute('action')
		if actionID then
			self:SetUsable(IsUsableAction(actionID))
			self:SetCooldown(GetActionCooldown(actionID))
		end 
	elseif action == 'custom' then
        self:SetUsable(true)
        self:SetCooldown(0, 0)
    end
end

function ConsolePortRingButtonMixin:GetAutoAssigned()
	return self:GetAttribute('item') and self:GetAttribute('autoassigned')
end

----------------------------------
-- Icon and quest icon
----------------------------------
function ConsolePortRingButtonMixin:SetTexture(actionType, actionValue)
	local mountID = self:GetAttribute("mountID")
	local texture, isQuest = TEXTURE_GETS[actionType](mountID or actionValue)
	if texture then
		self.Icon.texture = texture
		self.Icon:SetTexture(texture)		
		SetPortraitToTexture(self.Icon, texture)
		self:SetAlpha(1)
		self.Icon:SetVertexColor(1, 1, 1)
	else
		self.Icon.texture = nil
		self.Icon:SetTexture(nil)
		self:SetAlpha(0.5)
	end
	self.isQuest = isQuest
	if(self.Quest) then
		CPAPI.SetShown(self.Quest, isQuest)
	end
end

function ConsolePortRingButtonMixin:UpdateTexture(action, val)
    if self:GetAttribute('custombinding') then
        action = 'custom'
        val = self:GetAttribute('custombinding')
    else
        action = action or self:GetAttribute('type')
        val = val or (action and self:GetAttribute(action))
    end
    self:SetTexture(action, val)
end



---------------------------------------------------------------
-- Ring management 
---------------------------------------------------------------

function Utility:Initialize(ctype, ctemplate, cmixin)
	if self:GetAttribute('initialized') then return end
	----------------------------------
	self.cmixin = cmixin;
	self.ctype  = ctype or 'Button';
	self.ctemplate = ctemplate or 'ConsolePortRingButtonTemplate';
	----------------------------------
	self.HANDLE = ConsolePortRadialHandler
	self.HANDLE:RegisterFrame(self)
	----------------------------------
	self:WrapScript(self, 'PreClick', self:GetAttribute('_preclick'))
	self:WrapScript(self, 'OnDoubleClick', self:GetAttribute('_ondoubleclick'))
	----------------------------------
	self:SetAttribute('initialized', true)
end

function Utility:Disable()
	if not self:GetAttribute('initialized') then return end
	----------------------------------
	self:UnwrapScript(self, 'PreClick')
	self:UnwrapScript(self, 'OnDoubleClick')
	----------------------------------
	self:SetAttribute('initialized', false)
end

function Utility:Refresh() 
    if InCombatLockdown() then return end
	
	local size = self.HANDLE:GetIndexSize()
	self:SetAttribute('size', size)
	self:SetAttribute('fraction', rad(360 / size))

	self.Buttons = self.Buttons or {}
	self:Recall()
	self:Draw(size)

	self:OnRefresh(size)
end

function Utility:UpdateVisuals() 
    for _, button in ipairs(self.Buttons) do
        if button:IsShown() then 
            button:UpdateTexture() 
            button:UpdateState()
        end
    end
end

----------------------------------
-- Button loops
----------------------------------
function Utility:Recall()
	for i, button in ipairs(self.Buttons) do
		button:ClearAllPoints()
		button:Hide()
	end
end

function Utility:Draw(numButtons)
	for i=1, numButtons do
		self:SpawnButtonAtIndex(i)
	end
end

function Utility:ClearFocus()
	for i, button in ipairs(self.Buttons) do
		button:OnLeave()
	end
end

----------------------------------
-- Button spawns
----------------------------------
local CENTER_OFFSET = 180

function Utility:GetFraction()
	return self:GetAttribute('fraction')
end

function Utility:GetButtonFromAngle(angle)
	return self:GetAttribute(angle)
end

function Utility:SpawnButtonAtIndex(i)
	local angle  =  self.HANDLE:GetAngleForIndex(i)
	local rotate =  (i - 1) * self:GetFraction()
	local button =  self:GetButtonFromAngle(angle) or
					CreateFrame(self.ctype, '$parent'..self.ctype..i, self, self.ctemplate)

	
	if(not button.ismxin) then
		button:RegisterForClicks("AnyUp")
		CPAPI.Mixin(button, ConsolePortRingButtonMixin)
		button.ismxin = true
	end

	button:SetPoint('CENTER', -(CENTER_OFFSET * cos(angle)), CENTER_OFFSET * sin(angle))
	button:SetAttribute('rotation', -rotate)
	button:SetAttribute('angle', angle)
	button:SetID(i)
	button:Show()

	self.Buttons[i] = button
	self:SetAttribute(angle, button)
	self:SetFrameRef(tostring(i), button)
	self:SetFrameRef(tostring(angle), button)
	self:OnNewButton(button, i, angle, rotate)
		 
	button:SetScript("OnLoad", button.OnLoad)
	button:OnLoad()
	button:SetScript("OnEnter", button.OnEnter)
	button:SetScript("OnLeave", button.OnLeave)
	button:SetScript("PreClick", button.PreClick)
	button:SetScript("PostClick", button.PostClick)
	button:SetScript("OnAttributeChanged", button.OnAttributeChanged)
end

----------------------------------
-- State drivers
----------------------------------
function Utility:SetCursorDrop(enabled)
	local call = enabled and RegisterStateDriver or UnregisterStateDriver
	--call(self, 'cursor', self:GetAttribute('_driver-cursor'))
end

function Utility:SetExtraButtonDrop(enabled)
	local call = enabled and RegisterStateDriver or UnregisterStateDriver
	--call(self, 'extrabar', self:GetAttribute('_driver-extrabar'))
end

----------------------------------
-- Rotation handler
----------------------------------
local abs = math.abs

function Utility:SetRotation(value)
	if not value then return end
	self:OnNewRotation(value)
end

function Utility:SetNewRotationValue(anglenew)
	self.anglenew = anglenew
	if self.anglecur then
		local diff = abs(anglenew) - abs(self.anglecur)
		-- Case: lap reset, causing rotation in wrong direction in upperleft quadrant
		-- Solution: reverse delta and rotate in from a negative value
		if abs(diff) > 1 then
			self.anglecur = anglenew - ((diff > 0 and 1 or -1) * self:GetAttribute('fraction'))
		end
		return true -- if rotation is required
	end
	self.anglecur = anglenew
	self:SetRotation(anglenew)
end


function Utility:OnEvent(event, ...) 
	if (event == 'QUEST_ACCEPTED' or 
		event == 'QUEST_POI_UPDATE' or 
		event == 'QUEST_WATCH_LIST_CHANGED') then
		ConsolePort:RunOOC(UpdateQuestItems)
	end
	for _, ActionButton in ipairs(self.Buttons) do
		ActionButton:UpdateState()
	end
end


function Utility:OnButtonFocused(index)
	local button = self:GetAttribute(index)
	local focused = self.oldID and self:GetAttribute(self.oldID)
	if  focused then
		focused:OnLeave()
	end
	if 	button and button:IsVisible() then
		button:OnEnter()

		if self:SetNewRotationValue(button:GetAttribute('rotation')) then
			FadeOut(self.Spell, 1, self.Spell:GetAlpha(), 0)
		else
			FadeIn(self.Spell, 0.2, self.Spell:GetAlpha(), 0.15)
		end

		if button:GetAttribute('type') then
			FadeIn(self.Runes, 3, self.Runes:GetAlpha(), 1)
			FadeIn(self.Ring, 0.2, self.Ring:GetAlpha(), 1)
		else
			FadeOut(self.Ring, 0.5, self.Ring:GetAlpha(), 0)
			FadeOut(self.Runes, 0.5, self.Runes:GetAlpha(), 0)
		end

		self.Gradient:Show()
		self.Gradient:ClearAllPoints()
		self.Gradient:SetPoint('CENTER', button, 'CENTER', 0, 0)
		FadeIn(self.Gradient, 0.2, self.Gradient:GetAlpha(), 1)
		FadeIn(self.Arrow, 0.2, self.Arrow:GetAlpha(), 1)
        FadeIn(self.PieBand, 0.15, Utility.PieBand:GetAlpha(), 0.9)

		if Utility.PieSeparators then
			local totalSlots = self.HANDLE:GetIndexSize()
			local slotIndex = self.HANDLE:GetIndexForAngle(tonumber(index))
			if slotIndex then
				for i, sep in ipairs(Utility.PieSeparators) do
					local left  = slotIndex % totalSlots + 1
					local right = (slotIndex - 1) % totalSlots + 1

					local isActive = (i == left or i == right) 
					sep:SetTexture(isActive and
						[[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Active]] or
						[[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Inactive]])
				end
			end
		end

		self.Spell:Show()
		self.Spell:ClearAllPoints()
		self.Spell:SetPoint('CENTER', button, 0, 0)
	else
		FadeOut(self.Runes, 0.2, self.Runes:GetAlpha(), 0)
		FadeOut(self.Arrow, 0.2, self.Arrow:GetAlpha(), 0)
		FadeOut(self.Ring, 0.1, self.Ring:GetAlpha(), 0)
        FadeOut(self.PieBand, 0.2, Utility.PieBand:GetAlpha(), 0)

		if Utility.PieSeparators then
			for _, sep in ipairs(Utility.PieSeparators) do
				sep:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Inactive]])
			end
		end

		self.anglenew = nil
		self.anglecur = nil

		self.Gradient:SetAlpha(0)
		self.Gradient:ClearAllPoints()
		self.Gradient:Hide()

		self.Spell:ClearAllPoints()
		self.Spell:Hide()
	end

	self.oldID = index
end

function Utility:DisplayHints(elapsed) 
	local activePreset = tonumber(Utility:GetAttribute("ActivePreset") or 1)
	self.hintTimer = self.hintTimer + elapsed
	if self.hintTimer > 5 then
		local binding = ConsolePort:GetFormattedBindingOwner(Utility:GetBindingForSet(activePreset), nil, nil, true)
		if binding then
			if self:GetAttribute('toggled') then
				db.Hint:DisplayMessage(format(db.TUTORIAL.HINTS.UTILITY_RING_DOUBLE, binding), 4, -190)
			else
				db.Hint:DisplayMessage(format(db.TUTORIAL.HINTS.UTILITY_RING_BIND, binding), 4, -190)
			end
		else
			db.Hint:DisplayMessage(db.CUSTOMBINDS.CP_UTILITYBELT)
		end
		self.hasHints = nil
	end
end

local ANI_SPEED, ANI_SMOOTH, ANI_INF = 1.5, 1.4, 0.005

function Utility:OnUpdateDisplay(elapsed)
	if self.PieBackground:GetAlpha() > 0 then
        local r = self.PieBackground._rotation + (ANI_SPEED * elapsed)
        self.PieBackground._rotation = r
        self.PieBackground:SetRotation(r)
    end

	-- flatten and update rotation angle
	local new, cur = self.anglenew, self.anglecur
	if cur ~= new then
		local dist = new - cur
		local flat = abs(dist / ANI_SPEED) ^ ANI_SMOOTH
		local diff = cur + (dist < 0 and -flat or flat)
		----------------------------------
		self.anglecur = abs(abs(diff)-abs(new)) < ANI_INF and new or diff
		----------------------------------
	end
	self:SetRotation(self.anglecur)

	if self.hasHints then
		self:DisplayHints(elapsed)
	end
end

function Utility:OnShow()
	self.PieBackground:SetAlpha(1)
    self.PieBackground._rotation = 0
	self.anglecur = nil
	self.anglenew = nil
	Animation:Hide()
	AniCircle:Hide()
	--self.Spell:SetSize(175, 175)
	FadeOut(self.Ring, 0, 0, 0)
	FadeOut(self.Arrow, 0, 0, 0)
	FadeOut(self.Runes, 0, 0, 0)
	self.hintTimer = 0
	self.hasHints = true 
	self:Refresh()
end

function Utility:OnHide()
	self:ClearFocus()
	self.anglecur = nil
	self.anglenew = nil
	self.PieBackground:SetAlpha(0)
	self.Gradient:SetAlpha(0)
	self.Gradient:ClearAllPoints()
	self.Gradient:Hide()
	--self.Spell:Hide()
end

Utility:SetAttribute('_onextrabar', [[
	local extraID = 169
	local size = control:RunAttribute('_getsize')
	if newstate then
		for i=1, size do
			local button = self:GetFrameRef(tostring(i))
			if 	button:GetAttribute('type') == 'action' and button:GetAttribute('action') == extraID then
				control:CallMethod('AnimateNew', button:GetName())
				return
			end
		end
		for i=1, size do
			local button = self:GetFrameRef(tostring(i))
			if 	not button:GetAttribute('type') then
				button:SetAlpha(1)
				button:SetAttribute('type', 'action')
				button:SetAttribute('action', extraID)
				control:CallMethod('AnimateNew', button:GetName())
				return
			end
		end
	else
		for i=1, size do
			local button = self:GetFrameRef(tostring(i))
			if 	button:GetAttribute('type') == 'action' and button:GetAttribute('action') == extraID then
				button:SetAlpha(0.5)
				button:SetAttribute('type', nil)
				button:SetAttribute('action', nil)
			end
		end
	end
]])

---------------------------------------------------------------
-- Callbacks
---------------------------------------------------------------
local function OnButtonContentChanged(self, actionType)
    local activePresetID = tonumber(Utility:GetAttribute("ActivePreset") or 1)
    local preset = ConsolePortUtility[activePresetID]
    if not preset.Data then
        preset.Data = {}
    end

    local val = (actionType == 'custom') and self:GetAttribute('custombinding') or self:GetAttribute(actionType)
    local cur = self:GetAttribute('cursorID')
    local mnt = self:GetAttribute('mountID')
    local aut = self:GetAttribute('autoassigned') 

    preset.Data[self:GetID()] = {
        action       = actionType,
        value        = val,
        cursorID     = cur,
        mountID      = mnt,
        autoassigned = aut,
    }

    if not InCombatLockdown() then
        local prefix = "ring"..activePresetID.."-"
        self:SetAttribute(prefix.."type", actionType)
        self:SetAttribute(prefix.."id", val)
        self:SetAttribute(prefix.."cursorID", cur)
        self:SetAttribute(prefix.."mountID", mnt)
    end

    self:UpdateState()
end

local function OnButtonContentRemoved(self) 
    local activePresetID = tonumber(Utility:GetAttribute("ActivePreset") or 1)
    local preset = ConsolePortUtility[activePresetID]
    if preset.Data then
        preset.Data[self:GetID()] = nil
    end

    if not InCombatLockdown() then
        local prefix = "ring"..activePresetID.."-"
        self:SetAttribute(prefix.."type", nil)
        self:SetAttribute(prefix.."id", nil)
        self:SetAttribute(prefix.."cursorID", nil)
        self:SetAttribute(prefix.."mountID", nil)
    end
end


function Utility:OnNewButton(button, index, angle, rotation)
	--button.Cooldown:SetSwipeColor(db.Atlas.GetNormalizedCC())
	button.Pushed:SetVertexColor(red, green, blue, 1)

	button.OnContentChanged = OnButtonContentChanged
	button.OnContentRemoved = OnButtonContentRemoved
	self:SetAttribute(tostring(angle), button)
end

function Utility:OnNewRotation(value)
	self.Ring:SetRotation(value)
	self.Arrow:SetRotation(value)
	self.Runes:SetRotation(value)
	self.PieBand:SetRotation(value)
end

function Utility:ClearButtons()
    self.clearing = true  -- enable silent mode

    for _, actionButton in ipairs(self.Buttons) do
        actionButton:SetAttribute('autoassigned', nil)
        actionButton:SetAttribute('type', nil)
        actionButton:SetAttribute('cursorID', nil)
        actionButton:SetAttribute('mountID', nil)
        actionButton:SetAttribute('item', nil) 
        
        -- Clear custom handlers
        actionButton:SetAttribute('custombinding', nil)
        actionButton:SetAttribute('macrotext', nil)
        
        actionButton.Count:SetText()
    end

    self.clearing = false -- back to normal
end

function Utility:RefreshPieSeparators()
    if self.PieSeparators then
        for _, sep in ipairs(self.PieSeparators) do
            sep:Hide()
        end
    end
    self.PieSeparators = {}

    local totalSlots = self.HANDLE:GetIndexSize()
    local angleStep = 360 / totalSlots

    for i = 1, totalSlots do
        local sep = self:CreateTexture(nil, 'ARTWORK', nil, 2)
        sep:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Separator_Inactive]])
        sep:SetPoint('CENTER', Utility, 'CENTER', 0, 0)
        sep:SetSize(810, 810)  -- same as background
       	sep:SetRotation(math.rad(270 - (i - 1) * angleStep + (angleStep * 0.5)))
        sep:SetAlpha(0.8)
        sep:Show()
        self.PieSeparators[i] = sep
    end
end

function Utility:OnRefresh(size)   
	 -- Iterate through all buttons and reset them
    self:ClearButtons()

	for presetID, preset in ipairs(ConsolePortUtility) do
        if preset.Data then
            for index, info in pairs(preset.Data) do
                local actionButton = self.Buttons[index]
                if actionButton and info.action then
                    -- Store data with a ring-specific prefix
                    local prefix = "ring"..presetID.."-"
                    actionButton:SetAttribute(prefix.."type", info.action)
                    actionButton:SetAttribute(prefix.."id", info.value)
                    -- We also store cursor/mount IDs the same way
                    actionButton:SetAttribute(prefix.."cursorID", info.cursorID)
                    actionButton:SetAttribute(prefix.."mountID", info.mountID)
                end
            end
        end
    end

	local activePreset = ConsolePortUtility[tonumber(Utility:GetAttribute("ActivePreset") or 1)]
    if not activePreset or not activePreset.Data then return end

    for index, info in pairs(activePreset.Data) do
        local actionButton = self.Buttons[index]
        if actionButton and info.action then
            actionButton:SetAttribute('autoassigned', info.autoassigned)
            actionButton:SetAttribute('cursorID', info.cursorID)
            actionButton:SetAttribute('mountID', info.mountID)

			if info.action == 'custom' then
                local macrotext
				local clickFrame, clickBtn = string.match(info.value or "", "^CLICK ([^:]+):?(.*)")
				if clickFrame then
					clickBtn = (clickBtn == "") and "LeftButton" or clickBtn
					macrotext = '/click ' .. clickFrame .. ' ' .. clickBtn
				else 
					macrotext = info.value
				end
				
				actionButton:SetAttribute('custombinding', info.value)
				actionButton:SetAttribute('macrotext', macrotext)
				actionButton:SetAttribute('type', 'macro')
            else
                actionButton:SetAttribute('type', info.action)
                actionButton:SetAttribute(info.action, info.value)
                actionButton:SetAttribute('custombinding', nil)
            end
			
            actionButton:Show()
        end
    end


	local autoExtra = activePreset.Autoassign
	self.frameScale = db.Settings.utilityRingScale or 1
	self:SetScale(self.frameScale)

	self.Runes:SetSize(448 + (8 * size), 448 + (8 * size))
	self.Full:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\UtilityGlow]]..size)

	if autoExtra then
		ConsolePort:RunOOC(UpdateQuestItems)
	end

	self:SetCursorDrop(true)
	self:SetExtraButtonDrop(autoExtra)
	self:RefreshPieSeparators()
	
	for _, event in pairs({
		'ACTIONBAR_UPDATE_COOLDOWN',
		'ACTIONBAR_UPDATE_STATE',
		'ACTIONBAR_UPDATE_USABLE',
		'BAG_UPDATE',
		'BAG_UPDATE_COOLDOWN',
		'QUEST_ACCEPTED',
		'QUEST_POI_UPDATE',
		'QUEST_WATCH_LIST_CHANGED',
		'SPELL_UPDATE_COOLDOWN',
		'SPELL_UPDATE_CHARGES',
		'SPELL_UPDATE_USABLE',
	}) do pcall(self.RegisterEvent, self, event) end
end

function Utility:GetBindingForSet(setID)
	return ('CLICK ConsolePortUtilityToggle:%s'):format(self:GetBindingSuffixForSet(setID));
end

function Utility:GetBindingSuffixForSet(setID)
	return (tonumber(setID) == 1 and 'LeftButton' or tostring(setID));
end


---------------------------------------------------------------

function ConsolePort:AddUtilityAction(actionType, value, presetID, noanimation)
    if not (actionType and value) then return end 

    presetID = presetID or tonumber(Utility:GetAttribute("ActivePreset") or 1)

    local preset = ConsolePortUtility[presetID]
    if not preset then return end

    preset.Data = preset.Data or {}

    local count = 0
    for _ in pairs(preset.Data) do count = count + 1 end
    if count >= 8 then 
        return
    end

    for slot, info in pairs(preset.Data) do
        if info.action == actionType then
            if (actionType == "item"  and info.cursorID == tonumber(value)) or
               (actionType == "mount" and info.mountID == tonumber(value)) or
               (info.value == value) then
				
				if(not noanimation) then
					if presetID == tonumber(Utility:GetAttribute("ActivePreset") or 1) then
						Animation:ShowNewAction(Utility.Buttons[slot])
					else
						Animation:ShowPresetAction(presetID, slot)
					end
				end
                return
            end
        end
    end

    local freeSlot
    for i = 1, 8 do
        if not preset.Data[i] then
            freeSlot = i
            break
        end
    end
    if not freeSlot then return end

    preset.Data[freeSlot] = {
        action       = actionType,
        value        = value,
        autoassigned = false,
        cursorID     = (actionType == "item") and tonumber(value) or nil,
        mountID      = (actionType == "mount") and tonumber(value) or nil,
    }

    local activePreset = tonumber(Utility:GetAttribute("ActivePreset") or 1)
    if presetID == activePreset then
        Utility:OnRefresh(#Utility.Buttons)
        if Utility.Buttons[freeSlot] then
			if(not noanimation) then 
            	Animation:ShowNewAction(Utility.Buttons[freeSlot])
			end
        end
    else
		if(not noanimation) then
        	Animation:ShowPresetAction(presetID, freeSlot)
		end
    end
end


function ConsolePort:SetupUtilityRing()
	if not InCombatLockdown() and Utility:GetAttribute("initialized") ~= true then 
		Utility:UnregisterAllEvents()
		Utility:Initialize()
		self:RemoveUpdateSnippet(self.SetupUtilityRing) 
	end
end

----------------------------------------------------------------

function ConsolePort:SetupUtilityBindings()
	ConsolePortUtility = ConsolePortUtility or {}

	if(not db) then
		return
	end
	if( not db.Bindings) then
		return
	end 

	if next(ConsolePortUtility) == nil then
    	ConsolePortUtility[1] = { Name = "Utility Ring", Icon = [[Interface\AddOns\ConsolePort\Textures\Icons\Ring]] }
	end

    for profileID, preset in pairs(ConsolePortUtility) do
        if preset.Binding and preset.Binding.Button then
            local buttonName = preset.Binding.Button
            local modifier   = preset.Binding.Modifier or ""
            local action = Utility:GetBindingForSet(profileID)
			 
            -- ensure entry exists in db.Bindings (copied from default if missing)
            db.Bindings[buttonName] = db.Bindings[buttonName] or {}

            -- overwrite just this one modifier
            if action and action ~= "" then
                db.Bindings[buttonName][modifier] = action
            end
        end
    end

    self:LoadBindingSet(db.Bindings, true)
end

function ConsolePort:GetUtilityRingIcon(binding)
    if binding == 'CLICK ConsolePortUtilityToggle:LeftButton' then
        return (ConsolePortUtility[1] and ConsolePortUtility[1].Icon) or "Interface\\AddOns\\ConsolePort\\Textures\\Icons\\Ring"
    end

    local bindingID = strmatch(binding, 'CLICK ConsolePortUtilityToggle:(%d+)')
    if bindingID then
        for presetID, preset in ipairs(ConsolePortUtility) do
            if presetID == tonumber(bindingID) and preset.Icon then
                return preset.Icon
            end
        end
    end
end

function ConsolePort:GetUtilityRingName(binding)
    if binding == 'CLICK ConsolePortUtilityToggle:LeftButton' then
        return (ConsolePortUtility[1] and ConsolePortUtility[1].Name) or db.CUSTOMBINDS.CP_UTILITYBELT
    end

    local bindingID = strmatch(binding, 'CLICK ConsolePortUtilityToggle:(%d+)')
    if bindingID then
        for presetID, preset in ipairs(ConsolePortUtility) do
            if presetID == tonumber(bindingID) and preset.Name then
                return preset.Name
            end
        end
    end
end

----------------------------------------------------------------
-- Simple Animation System
-- Supports Alpha + Scale animations with OnPlay, OnStop, OnFinished
-- Implements Play, Stop, Finish, IsPlaying
----------------------------------------------------------------
local function CreateSimpleAnimationGroup(parent)
    local group = {
        parent = parent,
        anims = {},
        _scripts = {},   -- event -> handler
        _playing = false,
        _elapsed = 0,
        _maxTime = 0,
    }

    -- Event API ------------------------------------------------
    function group:SetScript(evt, fn) self._scripts[evt] = fn end
    function group:HookScript(evt, fn)
        local prev = self._scripts[evt]
        if prev then
            self._scripts[evt] = function(self, ...) prev(self, ...); fn(self, ...) end
        else
            self._scripts[evt] = fn
        end
    end
    function group:IsPlaying() return self._playing end

    -- Anim factory ---------------------------------------------
    function group:CreateAnimation(animType)
        local anim = {
            type = animType,
            parent = self.parent,
            from = {},
            to   = {},
            duration = 0.5,
            smoothing = nil,
            startDelay = 0,
        }

        -- Common setters
        function anim:SetDuration(d) self.duration = d end
        function anim:SetSmoothing(s) self.smoothing = s end -- "IN" | "OUT"
        function anim:SetStartDelay(d) self.startDelay = d end

        -- Alpha
        function anim:SetFromAlpha(a) self.from.alpha = a end
        function anim:SetToAlpha(a)   self.to.alpha   = a end

        -- Scale
        function anim:SetFromScale(x, y) self.from.sx, self.from.sy = x, y end
        function anim:SetToScale(x, y)   self.to.sx,   self.to.sy   = x, y end

        table.insert(self.anims, anim)
        return anim
    end

    -- Helpers --------------------------------------------------
    local function ease(progress, mode)
        if mode == "IN"  then return progress * progress
        elseif mode == "OUT" then return 1 - (1 - progress) * (1 - progress)
        else return progress end
    end

    local driver

    -- Internal reset to from-values
    local function resetFromValues(self)
        for _, a in ipairs(self.anims) do
            if a.type == "Alpha" and a.from.alpha ~= nil then
                self.parent:SetAlpha(a.from.alpha)
            elseif a.type == "Scale" and a.from.sx ~= nil then
                self.parent:SetScale(a.from.sx) -- uniform only
            end
        end
    end

    -- Control --------------------------------------------------
    function group:Play()
        if self._playing then self:Stop() end
        self._playing = true
        self._elapsed = 0

        -- compute max span
        local maxT = 0
        for _, a in ipairs(self.anims) do
            local span = (a.startDelay or 0) + (a.duration or 0)
            if span > maxT then maxT = span end
        end
        self._maxTime = maxT

        resetFromValues(self)

        if self._scripts.OnPlay then pcall(self._scripts.OnPlay, self) end

        if not driver then driver = CreateFrame("Frame", nil, self.parent) end

        driver:SetScript("OnUpdate", function(_, delta)
            if not self._playing then return end
            self._elapsed = self._elapsed + delta
            local parent = self.parent

            for _, a in ipairs(self.anims) do
                local t = self._elapsed - (a.startDelay or 0)
                if t >= 0 and t <= (a.duration or 0) then
                    local p = ease(t / a.duration, a.smoothing)

                    if a.type == "Alpha" then
                        local from = a.from.alpha or parent:GetAlpha() or 1
                        local to   = a.to.alpha   or from
                        parent:SetAlpha(from + (to - from) * p)

                    elseif a.type == "Scale" then
                        local from = a.from.sx or parent:GetScale() or 1
                        local to   = a.to.sx   or from
                        parent:SetScale(from + (to - from) * p)
                    end
                end
            end

            if self._elapsed >= self._maxTime then
                self:Finish()
            end
        end)
    end

    function group:Stop()
        if not self._playing then return end
        self._playing = false
        if driver then driver:SetScript("OnUpdate", nil) end
        if self._scripts.OnStop then pcall(self._scripts.OnStop, self) end
    end

    function group:Finish()
        for _, a in ipairs(self.anims) do
            if a.type == "Alpha" and a.to.alpha ~= nil then
                self.parent:SetAlpha(a.to.alpha)
            elseif a.type == "Scale" and a.to.sx ~= nil then
                self.parent:SetScale(a.to.sx)
            end
        end
        self._playing = false
        if driver then driver:SetScript("OnUpdate", nil) end
        if self._scripts.OnFinished then pcall(self._scripts.OnFinished, self) end
    end

    return group
end


---------------------------------------------------------------

Utility.Gradient:SetVertexColor(red * colMul, green * colMul, blue * colMul)
Utility.Full:SetVertexColor(red * 1.5, green * 1.5, blue * 1.5)
Utility.Ring:SetVertexColor(red * colMul, green * colMul, blue * colMul)
Utility.Arrow:SetVertexColor(red * 1.25, green * 1.25, blue * 1.25)
---------------------------------------------------------------
Utility:HookScript('OnHide', Utility.OnHide)
Utility:HookScript('OnShow', Utility.OnShow)
Utility:HookScript('OnEvent', Utility.OnEvent)
Utility:HookScript('OnUpdate', Utility.OnUpdateDisplay)
---------------------------------------------------------------

Utility.PieBackground = Utility:CreateTexture(nil, 'BACKGROUND', nil, -1)
Utility.PieBackground:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Background]])
Utility.PieBackground:SetPoint('CENTER', 0, 0)
Utility.PieBackground:SetSize(820, 820)
Utility.PieBackground:SetBlendMode('BLEND')
Utility.PieBackground:SetVertexColor(red * 0.6, green * 0.6, blue * 0.6)
Utility.PieBackground:SetAlpha(0)  -- hidden until ring opens
Utility.PieBackground._rotation = 0

Utility.PieBand = Utility:CreateTexture(nil, 'ARTWORK', nil, 3)
Utility.PieBand:SetTexture([[Interface\AddOns\ConsolePort\Textures\Utility\Pie_Band]])
Utility.PieBand:SetPoint('CENTER', 0, 0)
Utility.PieBand:SetSize(410, 410)
Utility.PieBand:SetVertexColor(red * colMul, green * colMul, blue * colMul)
Utility.PieBand:SetAlpha(0)  -- hidden until a slot is focused


---------------------------------------------------------------
Animation:SetSize(64, 64)
Animation:SetFrameStrata('TOOLTIP')
Animation.Group = CreateSimpleAnimationGroup(Animation) --Animation:CreateAnimationGroup()
---------------------------------------------------------------
Animation.Icon = Animation:CreateTexture(nil, 'ARTWORK')
Animation.Quest = Animation:CreateTexture(nil, 'OVERLAY')
Animation.Border = Animation:CreateTexture(nil, 'OVERLAY')
Animation.Scale = Animation.Group:CreateAnimation('Scale')
Animation.Fade = Animation.Group:CreateAnimation('Alpha')
---------------------------------------------------------------
Animation.Scale:SetToScale(1, 1)
Animation.Scale:SetFromScale(2, 2)
Animation.Scale:SetDuration(0.5)
Animation.Scale:SetSmoothing('IN')
Animation.Fade:SetFromAlpha(1)
Animation.Fade:SetToAlpha(0)
Animation.Fade:SetSmoothing('OUT')
Animation.Fade:SetStartDelay(3)
Animation.Fade:SetDuration(0.2)
---------------------------------------------------------------
Animation.Border:SetTexture('Interface\\AddOns\\ConsolePort\\Textures\\Button\\Normal')
Animation.Border:SetAlpha(1)
Animation.Border:SetAllPoints(Animation)
---------------------------------------------------------------
Animation.Icon:SetSize(64, 64)
Animation.Icon:SetPoint('CENTER', 0, 0)
---------------------------------------------------------------
Animation.Quest:SetTexture('Interface\\AddOns\\ConsolePort\\Textures\\QuestButton')
Animation.Quest:SetPoint('CENTER', 0, 0)
Animation.Quest:SetSize(64, 64)
---------------------------------------------------------------
Animation.Gradient = Animation:CreateTexture(nil, 'BACKGROUND')
Animation.Gradient:SetTexture('Interface\\AddOns\\ConsolePort\\Textures\\Window\\Circle')
Animation.Gradient:SetBlendMode('ADD')
Animation.Gradient:SetVertexColor(red, green, blue, 1)
Animation.Gradient:SetPoint('CENTER', 0, 0)
Animation.Gradient:SetSize(512, 512)	
---------------------------------------------------------------
Animation.Shadow = Animation:CreateTexture(nil, 'BACKGROUND')
Animation.Shadow:SetTexture('Interface\\AddOns\\ConsolePort\\Textures\\Button\\NormalShadow')
Animation.Shadow:SetSize(82, 82)
Animation.Shadow:SetPoint('CENTER', 0, -6)
Animation.Shadow:SetAlpha(0.75)
---------------------------------------------------------------
Animation.Spell = CreateFrame('PlayerModel', nil, Animation)
Animation.Spell:SetFrameStrata('TOOLTIP')
Animation.Spell:SetPoint('CENTER', Animation.Icon, 'CENTER', -4, 0)
Animation.Spell:SetSize(176, 176)
Animation.Spell:SetAlpha(0)
Animation.Spell:SetFrameLevel(1)
---------------------------------------------------------------
Animation.Group:SetScript('OnFinished', AnimateOnFinished)
---------------------------------------------------------------
AniCircle:SetPoint('CENTER', 0, 0)
AniCircle:SetSize(512, 512)
AniCircle:Hide()
---------------------------------------------------------------

---------------------------------------------------------------
AniCircle.Ring = AniCircle:CreateTexture(nil, 'OVERLAY', nil, 2)
AniCircle.Ring:SetTexture('Interface\\AddOns\\ConsolePort\\Textures\\Utility\\UtilityCircle')
AniCircle.Ring:SetVertexColor(red * colMul, green * colMul, blue * colMul)
AniCircle.Ring:SetPoint('CENTER', 0, 0)
AniCircle.Ring:SetSize(512, 512)
--AniCircle.Ring:SetAlpha(0)
AniCircle.Ring:SetRotation(0)
AniCircle.Ring:SetBlendMode('ADD')
---------------------------------------------------------------
AniCircle.Arrow = AniCircle:CreateTexture(nil, 'OVERLAY')
AniCircle.Arrow:SetTexture('Interface\\AddOns\\ConsolePort\\Textures\\Utility\\UtilityArrow')
AniCircle.Arrow:SetVertexColor(red * 1.25, green * 1.25, blue * 1.25)
AniCircle.Arrow:SetPoint('CENTER', 0, 0)
AniCircle.Arrow:SetSize(512, 512)
--AniCircle.Arrow:SetAlpha(0)
AniCircle.Arrow:SetRotation(0)
---------------------------------------------------------------
AniCircle.Runes = AniCircle:CreateTexture(nil, 'OVERLAY')
AniCircle.Runes:SetTexture('Interface\\AddOns\\ConsolePort\\Textures\\Utility\\UtilityRunes')
AniCircle.Runes:SetPoint('CENTER', 0, 0)
AniCircle.Runes:SetSize(512, 512)
--AniCircle.Runes:SetAlpha(0)
AniCircle.Runes:SetRotation(0)
---------------------------------------------------------------

---------------------------------------------------------------
Tooltip:SetScript('OnShow', Tooltip.OnShow)
Tooltip.castInfo = db.TOOLTIP.UTILITY_RELEASE
Tooltip.removeInfo = db.TOOLTIP.UTILITY_REMOVE
---------------------------------------------------------------