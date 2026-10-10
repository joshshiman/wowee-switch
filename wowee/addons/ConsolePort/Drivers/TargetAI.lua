local _, db = ...

local CPAPI = db.CPAPI 
---------------------------------------
local AI, SEL, HANDLE, CORE = ConsolePortTargetAI, ConsolePortTargetAISelector, ConsolePortMouseHandle, ConsolePort
---------------------------------------
local inRange, mapData, nameOnlyMode = AI.InRange, AI.MapData
---------------------------------------
local spairs, copy, strsplit = db.table.spairs, db.table.copy, strsplit
local getmetatable, setmetatable, rawset, next, select = getmetatable, setmetatable, rawset, next, select
---------------------------------------
-- Upvalued API:
local GetGUID, GetName, IsDead, Exists = UnitGUID, UnitName, UnitIsDead, UnitExists
local IsPlayer, IsEnemy, IsAttackable = UnitIsPlayer, UnitIsEnemy, UnitCanAttack

---------------------------------------
-- Shared guid->unit cache with Mouse.lua
-- Whichever file loads first creates it, the other picks it up.
-- Populated from NAME_PLATE_UNIT_ADDED and interaction events.
local guidToUnit = db.guidToUnit or {}
db.guidToUnit = guidToUnit

local function CacheUnit(unit)
	local guid = GetGUID(unit)
	if guid then guidToUnit[guid] = unit end
end

local function UncacheUnit(unit)
	local guid = GetGUID(unit)
	if guid then guidToUnit[guid] = nil end
end

---------------------------------------
-- Extended API:

local interactRangeItem = "item:37727"
local function _canInteract(unit)
    if unit then 
		local isInRange
		if GetItemInfo(interactRangeItem) then
			isInRange = IsItemInRange(interactRangeItem, unit)

			if(isInRange ~= nil) then
				return isInRange == 1
			end
		end
		return CheckInteractDistance(unit, 3) 
	end
end

local function CanInteract(guid)
	if not guid then return nil end
	local unit = guidToUnit[guid]
	if unit and UnitExists(unit) then
		return _canInteract(unit) or nil
	end
	-- fallback: scan nameplates
	if C_NamePlate and C_NamePlate.GetNamePlates then
		for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
			local u = plate.namePlateUnitToken
			if u and GetGUID(u) == guid then
				guidToUnit[guid] = u
				return _canInteract(u) or nil
			end
		end
	end
	return nil
end

local function IsNPC(unit) 
	local guid = UnitGUID(unit)
	if not guid then return false end
	local B = tonumber(guid:sub(5,5), 16)
	if not B then return false end
	local C = B % 8
	return (not UnitIsPlayer(unit)) and not UnitIsEnemy('player', unit) and (C == 3)
end

local function IsInteractive(unit)
	return not IsDead(unit) and CanInteract(GetGUID(unit))
end

---------------------------------------
local MAX_ZONES = 3
local MAX_NAMEPLATES = 30
local MAX_MARKER_GUIDS = 10

---------------------------------------
-- Metatables
---------------------------------------
setmetatable(AI, {
	__index = getmetatable(AI).__index;
	__newindex = function(t, k, v)
		if t:HasScript(k) then
			if t:GetScript(k) then
				t:HookScript(k, v)
			else
				t:SetScript(k, v)
			end
		else
			rawset(t, k, v)
		end
	end;
})
setmetatable(SEL, {
	__index = getmetatable(SEL).__index;
	__newindex = getmetatable(AI).__newindex;
})
---------------------------------------
-- inRange: Stack of NPCs in range
---------------------------------------
do 	local inRangeMT = {
		__index = {
			HasMultiple = function(t) return t.__mt.__active > 1 end;
			HasTarget = function(t) return t.__mt.__active > 0 end;
			Add = function(t, k, v)
				if k and v and not t[k] then
					rawset(t, k, v)
					t:Update(1)
					AI:UpdateSelection()
				end
			end;
			Remove = function(t, k)
				if k and t[k] then
					rawset(t, k, nil)
					t:Update(-1)
					AI:UpdateSelection()
				end
			end;
			Prune = function(t)
				local mt = t.__mt
				local guid, name = next(t, mt.__cleaner)
				mt.__cleaner = guid
				if guid and not CanInteract(guid) then
					t:Remove(guid)
				end
			end;
			Update = function(t, delta)
				local mt = t.__mt
				mt.__active = delta and mt.__active + delta or 0
				mt.__idx = nil
				mt.__cleaner = nil
			end;
			Wipe = function(t)
				if next(t) then
					t:Update()
					wipe(t)
					AI:UpdateSelection()
				end
			end;
		};
		__newindex = function() end;
		__active = 0;
	}
	inRangeMT.__index.__mt = inRangeMT
	setmetatable(inRange, inRangeMT)
end

local markerMT = {
	__index = {};
	__limit = MAX_MARKER_GUIDS;
	__newindex = function(t, k, v)
		rawset(t, k, v)
		local mt = getmetatable(t)
		mt.__idx = nil
		local fifo = mt.__index
		local limit = mt.__limit
		tinsert(fifo, 1, k)
		fifo[limit+1] = nil
		local num = 0
		for _,_ in pairs(t) do num=num+1 end
		if num > limit then
			for i=#fifo, 1, -1 do
				if t[fifo[i]] then
					rawset(t, fifo[i], nil)
					num = num - 1
				end
				if num == limit then
					break
				end
			end
		end
	end;
}
---------------------------------------
do	local mapDataMT = copy(markerMT)
	mapDataMT.__limit = MAX_ZONES
	setmetatable(mapData, mapDataMT)
end

local function f10(val)
	return math.floor((val or 0) * 10) / 10
end

local function __iterate(t)
	local mt = getmetatable(t)
	local idx, val = next(t, mt.__idx)
	mt.__idx = idx
	return idx, val
end

local function __loop(t)
	local mt = getmetatable(t)
	local idx, val = next(t, mt.__idx)
	if not idx and not val then
		idx, val = next(t, nil)
	end
	mt.__idx = idx
	return idx, val
end

---------------------------------------
AI:SetAttribute('_onattributechanged', [[
    if name == 'sel-active' then
        local sel = self:GetFrameRef('SEL')
         if value then
            sel:SetAttribute('state-active', 'show')
            sel:Show()
        else
            sel:SetAttribute('state-active', 'hide')
            sel:Hide()
        end
    end
]])

SecureHandlerSetFrameRef(AI, 'SEL', SEL)

function AI:OnEvent(event, ...)
	if self[event] then
		self[event](self, ...)
	end
end

function AI:OnHide()
	inRange:Wipe()
	wipe(mapData)
	wipe(guidToUnit)
	SEL:Hide()
	self:UnregisterAllEvents()
end

function AI:OnShow()
	nameOnlyMode = db('nameplateNameOnly')
	self:SetToCurrentMapMarker()
	self:ForceUpdatePlates()
	for event in pairs(self) do
		pcall(self.RegisterEvent, self, event)
	end
	if not nameOnlyMode then
		pcall(self.UnregisterEvent, self, 'UNIT_THREAT_LIST_UPDATE')
	end
end

---------------------------------------
local throttle, interval = 0, .5
function AI:OnUpdate(elapsed)
	throttle = throttle + elapsed
	if throttle > interval then
		local grid, dirty, plate = self:GetNPCs()
		if (grid or dirty or plate) then
			self:IterateTracker(dirty, true)
			self:IterateTracker(plate, false)
			self:IterateTracker(grid, false)
			interval = .05
		else
			interval = .5
		end
		inRange:Prune()
		throttle = 0
	end
	if self.plateUpdate then
		local unit = ('nameplate' .. self.plateIdx)
		if Exists(unit) then
			self:NAME_PLATE_UNIT_ADDED(unit)
		end
		self.plateIdx = self.plateIdx + 1
		if self.plateIdx > MAX_NAMEPLATES then
			self.plateUpdate = nil
		end
	end
end

function AI:IterateTracker(tracker, convertToGrid)
	if tracker then
		local guid, name = __iterate(tracker)
		if guid then
			if CanInteract(guid) then
				if convertToGrid then 
					self:ConvertToNPC(guid, name, self:GetPositionMarker())
				else
					inRange:Add(guid, name)
				end
			end
		end
	end
end

function AI:UpdateSelection()
	self:SetAttribute('sel-active', inRange:HasMultiple() or nil)
	self:SetFocus(__loop(inRange))
end

function AI:SetFocus(guid, name)
	self:SetAttribute('macrotext', (name and '/targetexact ' .. name) or ('') )
	HANDLE:SetArtificialUnit(guid, name)
end

---------------------------------------
local zone

function AI:GetMapMarker()
	return table.concat({GetCurrentMapZone()})
end

function AI:SetToCurrentMapMarker()
	local zoneID = self:GetMapMarker()
	self.MapData[zoneID] = self.MapData[zoneID] or {}
	local isNewZone, oldID = self:SetZoneID(zoneID)
	if isNewZone then
		self:ClearDirtyTrackers(oldID)
		self:ForceUpdatePlates()
	end
	return self.MapData[zoneID]
end

function AI:SetZoneID(newID)
	local isNewZone, oldID = (zone ~= newID), zone
	zone = newID
	return isNewZone, oldID, newID
end

function AI:GetCurrentMapData()
	return zone and self.MapData[zone]
end

function AI:GetMapDataForID(zoneID)
	return self.MapData[zoneID]
end

function AI:GetGridPosition() 
	local posX, posY = GetPlayerMapPosition('player')
	posX = f10(posX)
	posY = f10(posY) 
	return posX, posY
end

function AI:GetPositionMarker()
	local x, y = self:GetGridPosition()
	return (x ..':'.. y)
end

function AI:CreateTrackerFromMarker(marker, maxGUIDs)
	local mapData = self:GetCurrentMapData()
	if not mapData then
		mapData = self:SetToCurrentMapMarker()
	end
	if not mapData[marker] then
		local mt = copy(markerMT)
		mt.__limit = maxGUIDs or MAX_MARKER_GUIDS
		mapData[marker] = setmetatable({}, mt)
	end
	return mapData[marker]
end

function AI:ClearDirtyTrackers(mapID)
	local mapData = self:GetMapDataForID(mapID)
	if mapData then
		mapData.dirty = nil
		mapData.plate = nil
	end
end

function AI:ClearNPCDirty(guid, marker)
	local mapData = self:GetCurrentMapData()
	local tracker = mapData and mapData[marker]
	if tracker then
		tracker[guid] = nil
		if not next(tracker) then
			mapData[marker] = nil
		end
	end
end

function AI:ConvertToNPC(guid, name, marker)
	self:ClearNPCDirty(guid, 'dirty')
	self:CreateTrackerFromMarker(marker)[guid] = name
end

function AI:GetNPCs()
	local mapData = self:GetCurrentMapData()
	if mapData then
		return mapData[self:GetPositionMarker()], mapData.dirty, mapData.plate
	end
end

function AI:Track(unit, marker, maxGetGUIDs, forceMarker)
	local guid, name, interactive = GetGUID(unit), GetName(unit), IsInteractive(unit)
	if interactive and not forceMarker then
		marker = self:GetPositionMarker()
		self:ClearNPCDirty(guid, 'dirty')
	end
	if guid and name and marker then
		self:CreateTrackerFromMarker(marker, maxGetGUIDs)[guid] = name
	end
end

function AI:ForceUpdatePlates()
	self.plateUpdate = true
	self.plateIdx = 1
end

--------------------------------------------------------

function AI:WORLD_MAP_UPDATE() 
	self:SetToCurrentMapMarker()
end

function AI:GOSSIP_SHOW() 
	if Exists('npc') then CacheUnit('npc') end
	if Exists('npc') and IsNPC('npc') then
		self:Track('npc')
	end
end

function AI:MERCHANT_SHOW()
	if Exists('npc') then CacheUnit('npc') end
	if Exists('npc') and IsNPC('npc') then
		self:Track('npc')
	end
end

function AI:QUEST_DETAIL()
	if Exists('questnpc') then CacheUnit('questnpc') end
	if Exists('npc') then CacheUnit('npc') end
	if IsNPC('questnpc') then
		self:Track('questnpc')
	elseif IsNPC('npc') then
		self:Track('npc')
	end
end

function AI:QUEST_GREETING()
	if Exists('questnpc') then CacheUnit('questnpc') end
	if Exists('npc') then CacheUnit('npc') end
	if IsNPC('questnpc') then
		self:Track('questnpc')
	elseif IsNPC('npc') then
		self:Track('npc')
	end
end

function AI:PLAYER_TARGET_CHANGED()
	if Exists('target') then
		SEL:Hide()
		CORE:SetNameOnlyForUnit('target')
	else
		self:UpdateSelection(inRange)
	end
end

function AI:UPDATE_MOUSEOVER_UNIT()
	if Exists('mouseover') then
		SEL:Hide()
		if IsNPC('mouseover') then
			CacheUnit('mouseover')
			self:Track('mouseover', 'dirty')
		end
	else
		self:UpdateSelection(inRange)
	end
end

function AI:NAME_PLATE_UNIT_ADDED(unit)
	CacheUnit(unit)
	if IsNPC(unit) then
		self:Track(unit, 'plate', MAX_NAMEPLATES, true)
	end
	CORE:SetNameOnlyForUnit(unit)
end

function AI:NAME_PLATE_UNIT_REMOVED(unit)
	UncacheUnit(unit)
	self:ClearNPCDirty(GetGUID(unit), 'plate')
end

function AI:UNIT_THREAT_LIST_UPDATE(unit)
	if unit and unit:match('nameplate') then
		CORE:SetNameOnlyForUnit(unit)
	end
end

---------------------------------------
-- SEL: Secure binding setup
---------------------------------------
-- SEL is now a Button with SecureHandlerShowHideTemplate +
-- SecureActionButtonTemplate in XML. This means:
--   _onshow: runs restricted, can SetBindingClick -> works in combat
--   _onhide: runs restricted, can ClearBindings -> works in combat
--   type=macro, macrotext=/targetexact <n> -> fires in combat
--   PostClick (Lua) advances iterator -> only out of combat, acceptable
--
-- Key attributes are pre-computed out of combat and stored on SEL
-- so the restricted _onshow snippet can read them without needing
-- GetBindingKey (which is not available in the restricted env).
---------------------------------------


SEL:SetAttribute('_onattributechanged', [[
    if name == 'state-active' then
        if value == 'show' then
            local k1 = self:GetAttribute('sel-key-1')
			local k2 = self:GetAttribute('sel-key-2')
			local k3 = self:GetAttribute('sel-key-3')
			local k4 = self:GetAttribute('sel-key-4')
			if k1 and k1 ~= '' then self:SetBindingClick(true, k1, self, '1') end
			if k2 and k2 ~= '' then self:SetBindingClick(true, k2, self, '1') end
			if k3 and k3 ~= '' then self:SetBindingClick(true, k3, self, '2') end
			if k4 and k4 ~= '' then self:SetBindingClick(true, k4, self, '2') end  
        else
            self:ClearBindings()
        end
    end
]])


-- Restricted: fires when SEL hides, even in combat
SEL:SetAttribute('_onhide', [[
	self:ClearBindings()
]])

-- SEL is a SecureActionButtonTemplate - clicking fires its macro
SEL:SetAttribute('type', 'macro')
SEL:SetAttribute('macrotext', '')

---------------------------------------
-- UpdateSELKeyAttributes
-- Must run out of combat. Finds the physical keys bound to the
-- two D-pad actions SEL wants to intercept and stores them as
-- attributes so _onshow can read them in the restricted env.
---------------------------------------
local function UpdateSELKeyAttributes()
	if InCombatLockdown() then return end
	local interactWith = db('interactWith')
	-- intercept the axis NOT used for interact
	local a1, a2
	if interactWith == 'CP_L_UP' or interactWith == 'CP_L_DOWN' then
		a1, a2 = 'CP_L_LEFT', 'CP_L_RIGHT'
	else
		a1, a2 = 'CP_L_UP', 'CP_L_DOWN'
	end
	local k1a, k1b = GetBindingKey(a1)
	local k2a, k2b = GetBindingKey(a2)
	SEL:SetAttribute('sel-key-1', k1a or '')
	SEL:SetAttribute('sel-key-2', k1b or '')
	SEL:SetAttribute('sel-key-3', k2a or '')
	SEL:SetAttribute('sel-key-4', k2b or '')
end

---------------------------------------
-- UpdateSELMacro
-- Sets the macrotext to /targetexact the next NPC in inRange.
-- Called before SEL shows and after each click.
---------------------------------------
local function UpdateSELMacro()
	local _, name = __loop(inRange)
	SEL:SetAttribute('macrotext', name and ('/targetexact ' .. name) or '')
end

-- PostClick is not restricted - advances iterator out of combat only.
-- In combat the macro still fires targeting the last set NPC.
SEL:HookScript('PostClick', function(self, btn) 
	if btn == '1' or btn == '2' then
        local guid, name = __loop(inRange)
        AI:SetFocus(guid, name)
    end
end)

---------------------------------------

function SEL:OnShow()
	self.Group:Play()
	-- Pre-compute keys before restricted _onshow reads them.
	-- SEL only shows when NPCs detected = always out of combat.
	UpdateSELKeyAttributes()
	UpdateSELMacro()
	-- Note: _onshow fires automatically from SecureHandlerShowHideTemplate
	-- after this Lua OnShow returns, so attributes are ready in time.
end

SEL:SetScript('OnShow', SEL.OnShow)
-- OnHide: _onhide handles ClearBindings in restricted env automatically.
-- No Lua OnHide needed.

---------------------------------------
-- Re-sync key attributes when bindings reload or interactWith changes
---------------------------------------
ConsolePort:RegisterCallback('OnNewBindings', function()
	UpdateSELKeyAttributes()
end)

ConsolePort:RegisterVarCallback('interactWith', function()
	UpdateSELKeyAttributes()
end)