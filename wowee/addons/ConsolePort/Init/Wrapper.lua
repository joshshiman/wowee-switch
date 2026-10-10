local addOn, db = ...

local CPAPI = {};
db.CPAPI = CPAPI

function CPAPI.Popup(id, settings, ...)
	if (settings and settings.whileDead == nil) then
		settings.whileDead = true; -- popup enabled while dead by default
	end
	StaticPopupDialogs[id:upper()] = settings;
	local dialog = StaticPopup_Show(id:upper(), ...)
	if dialog then
		local icon = dialog.AlertIcon or _G[dialog:GetName() .. 'AlertIcon'];
		if icon then
			local original = icon:GetTexture()
			local onHide = settings.OnHide;
			icon:SetTexture("Interface\\AddOns\\ConsolePort\\Textures\\Logos\\CP")
			settings.OnHide = function(...)
				if icon then icon:SetTexture(original) end;
				if onHide then
					return onHide(...)
				end
			end;
		end
		return dialog;
	end
end


local function GetClassInfo()	return UnitClass('player') end
local function GetClassFile()   return select(2, UnitClass('player')) end
local function GetClassID() 	return select(3, UnitClass('player')) end

function CPAPI:GetPlayerCastingInfo()
	-- use UnitCastingInfo on retail
	if UnitCastingInfo then
		return UnitCastingInfo('player')
	end
	-- use CastingInfo on classic
	return CastingInfo()
end

function CPAPI.GetSpecialization()
	local classes = {["WARRIOR"]=1, ["PALADIN"]=2, ["HUNTER"]=3, ["ROGUE"]=4, ["PRIEST"]=5, ["DEATHKNIGHT"]=6,["SHAMAN"]=7,["MAGE"]=8,["WARLOCK"]=9,["DRUID"]=10}
	local vln, vlfn = UnitClass("player");  
	return classes[vlfn] or 1;
end

local function CP_GetTalentSpecInfo(isInspect)
	-- Taken from ElvUI-WOTLK

	local talantGroup = GetActiveTalentGroup(isInspect)
	local maxPoints, specIdx, specName, specIcon = 0, 0

	for i = 1, MAX_TALENT_TABS do
		local name, icon, pointsSpent = GetTalentTabInfo(i, isInspect, nil, talantGroup)
		if maxPoints < pointsSpent then
			maxPoints = pointsSpent
			specIdx = i
			specName = name
			specIcon = icon
		end
	end

	if not specName then
		specName = NONE
	end
	if not specIcon then
		specIcon = "Interface\\Icons\\INV_Misc_QuestionMark"
	end

	return specIdx, specName, specIcon
end

function CPAPI.GetSpecializationInfo(specID)
	_, specName, _ = CP_GetTalentSpecInfo()
	return specID, specName;
end

function CPAPI:GetSpecTextureByID(ID)
	-- returns specTexture on retail
	if GetSpecializationInfoByID then
		return select(4, GetSpecializationInfoByID(ID))
	-- returns classTexture on classic
	elseif C_CreatureInfo and C_CreatureInfo.GetClassInfo then
		local classInfo = C_CreatureInfo.GetClassInfo(ID)
		if classInfo then
			return ([[Interface\ICONS\ClassIcon_%s.blp]]):format(classInfo.classFile)
		end
	end
end

function CPAPI:GetClassIcon(class)
	-- returns concatenated icons file with slicing coords
	return [[Interface\TargetingFrame\UI-Classes-Circles]], CLASS_ICON_TCOORDS[class or GetClassFile()]
end

function CPAPI:GetClassColor(class)
    local c = class and RAID_CLASS_COLORS[class]
    if c then return RAID_CLASS_COLORS[class] end
end

function CPAPI:GetCharacterMetadata()
	-- returns specID, specName on retail
	if GetSpecializationInfo and GetSpecialization then
		return GetSpecializationInfo(GetSpecializaton())
	end
	-- returns classID, localized class token on classic
	return GetClassID(), GetClassInfo()
end

function CPAPI:GetItemLevelColor(...)
	if GetItemLevelColor then
		return GetItemLevelColor(...)
	end
	return RAID_CLASS_COLORS[select(2, UnitClass("player"))]
end

function CPAPI:GetAverageItemLevel(...)
	if GetAverageItemLevel then
		return floor(select(2, GetAverageItemLevel(...)))
	end
	return MAX_PLAYER_LEVEL
end

local CP_Atlases = { 	
	["groupfinder-button-cover"]={"Interface\\AddOns\\ConsolePort\\Textures\\Button\\Buttons.BLP", 300, 46, 0.000976562, 0.2939453125, 0.600, 0.6401953125, false, false},
	["adventureguide-microbutton-alert"]={"Interface\\AddOns\\BlizzCompat\\Compat\\BlizzardUI\\AdventureGuideMicrobuttonAlert.BLP", 28, 28, 0.03125, 0.90625, 0.03125, 0.90625, false, false},
};

function CPAPI:GetAtlasInfo(atlasName) -- this only returns texture file path.
	if(CP_Atlases[atlasName]) then
		local c_atlasInfo = CP_Atlases[atlasName];
		return c_atlasInfo[1];
	end
	return nil;
end

function CPAPI:GetAtlas(atlas)
	--stub
end

function CPAPI:SetAtlas(TextureObject, atlas)
	if(CP_Atlases[atlas]) then
		local c_atlas = CP_Atlases[atlas];
		TextureObject:SetTexture(c_atlas[1]);
		TextureObject:SetSize(c_atlas[2], c_atlas[3]);
		TextureObject:SetTexCoord(c_atlas[4],c_atlas[5],c_atlas[6], c_atlas[7]);
	end 
end

function CPAPI:GetAtlasTexture(atlas)
	local atlas = self:GetAtlasInfo(atlas)
	return atlas
end

function CPAPI:GetNumQuestWatches(...)
	return GetNumQuestWatches and GetNumQuestWatches(...) or 0
end

function CPAPI:GetNumWorldQuestWatches(...)
	return GetNumWorldQuestWatches and GetNumWorldQuestWatches(...) or 0
end

function CPAPI:GetQuestLogSpecialItemInfo(...)
	return GetQuestLogSpecialItemInfo and GetQuestLogSpecialItemInfo(...)
end

function CPAPI:UnitIsBattlePet(...)
	return UnitIsBattlePet and UnitIsBattlePet(...)
end

function CPAPI:UnitThreatSituation(...)
	return UnitThreatSituation and UnitThreatSituation(...)
end

function CPAPI:IsPlayerAtEffectiveMaxLevel() 
	return UnitLevel("player") >= MAX_PLAYER_LEVEL_TABLE[GetAccountExpansionLevel()];
end

function CPAPI:IsXPUserDisabled(...)
	return IsXPUserDisabled and IsXPUserDisabled(...)
end

function CPAPI:IsSpellOverlayed(...)
	return IsSpellOverlayed and IsSpellOverlayed(...)
end

function CPAPI:GetFriendshipReputation(...)
	return GetFriendshipReputation and GetFriendshipReputation(...)
end

function CPAPI:IsPartyLFG(...)
	return IsPartyLFG and IsPartyLFG(...)
end

function CPAPI:IsInLFGDungeon(...)
	return IsInLFGDungeon and IsInLFGDungeon(...)
end

function CPAPI:OpenStackSplitFrame(...)
	if OpenStackSplitFrame then
		return OpenStackSplitFrame(...)
	end
	return StackSplitFrame:OpenStackSplitFrame(...)
end

-- Project identifiers, should return true or nil (nil for dynamic table insertions)
function CPAPI:IsClassicVersion(...)
	if WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then return true end
end

function CPAPI:IsRetailVersion(...)
	if WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then return true end
end

-- Mixin Implementation

function CPAPI.Mixin(object, ...)
	for i = 1, select("#", ...) do
		local mixin = select(i, ...);
		for k, v in pairs(mixin) do
			object[k] = v;
		end
	end

	return object;
end

function CPAPI.CreateFromMixins(...)
	return CPAPI.Mixin({}, ...)
end 

-- Object and Frame Pool

local ObjectPoolMixin = {};

function ObjectPoolMixin:OnLoad(creationFunc, resetterFunc)
	self.creationFunc = creationFunc;
	self.resetterFunc = resetterFunc;

	self.activeObjects = {};
	self.inactiveObjects = {};

	self.numActiveObjects = 0;
end

function ObjectPoolMixin:Acquire()
	local numInactiveObjects = #self.inactiveObjects;
	if numInactiveObjects > 0 then
		local obj = self.inactiveObjects[numInactiveObjects];
		self.activeObjects[obj] = true;
		self.numActiveObjects = self.numActiveObjects + 1;
		self.inactiveObjects[numInactiveObjects] = nil;
		return obj, false;
	end

	local newObj = self.creationFunc(self);
	if self.resetterFunc then
		self.resetterFunc(self, newObj);
	end
	self.activeObjects[newObj] = true;
	self.numActiveObjects = self.numActiveObjects + 1;
	return newObj, true;
end

function ObjectPoolMixin:Release(obj)
	if self:IsActive(obj) then
		self.inactiveObjects[#self.inactiveObjects + 1] = obj;
		self.activeObjects[obj] = nil;
		self.numActiveObjects = self.numActiveObjects - 1;
		if self.resetterFunc then
			self.resetterFunc(self, obj);
		end

		return true;
	end

	return false;
end

function ObjectPoolMixin:ReleaseAll()
	for obj in pairs(self.activeObjects) do
		self:Release(obj);
	end
end

function ObjectPoolMixin:EnumerateActive()
	return pairs(self.activeObjects);
end

function ObjectPoolMixin:GetNextActive(current)
	return (next(self.activeObjects, current));
end

function ObjectPoolMixin:IsActive(object)
	return (self.activeObjects[object] ~= nil);
end

function ObjectPoolMixin:GetNumActive()
	return self.numActiveObjects;
end

function ObjectPoolMixin:EnumerateInactive()
	return ipairs(self.inactiveObjects);
end

function CPAPI.CreateObjectPool(creationFunc, resetterFunc)
	local objectPool = CPAPI.CreateFromMixins(ObjectPoolMixin);
	objectPool:OnLoad(creationFunc, resetterFunc);
	return objectPool;
end

local FramePoolMixin = CPAPI.CreateFromMixins(ObjectPoolMixin);

local function FramePoolFactory(framePool)
	return CreateFrame(framePool.frameType, nil, framePool.parent, framePool.frameTemplate);
end

function FramePoolMixin:OnLoad(frameType, parent, frameTemplate, resetterFunc)
	ObjectPoolMixin.OnLoad(self, FramePoolFactory, resetterFunc);
	self.frameType = frameType;
	self.parent = parent;
	self.frameTemplate = frameTemplate;
end

function FramePoolMixin:GetTemplate()
	return self.frameTemplate;
end

function CPAPI.FramePool_Hide(framePool, frame)
	frame:Hide();
end

function CPAPI.FramePool_HideAndClearAnchors(framePool, frame)
	frame:Hide();
	frame:ClearAllPoints();
end

function CPAPI.CreateFramePool(frameType, parent, frameTemplate, resetterFunc)
	local framePool = CPAPI.CreateFromMixins(FramePoolMixin);
	framePool:OnLoad(frameType, parent, frameTemplate, resetterFunc or CPAPI.FramePool_HideAndClearAnchors);
	return framePool;
end

-- CTime After function replacement
local CP_TimerAfterFrame = nil
local CP_TimerAfterTable = {};

function CPAPI.TimerAfter(delay, func, ...)
	if(type(delay)~="number" or type(func)~="function") then
	  return false;
	end
	if (CP_TimerAfterFrame == nil) then
	  CP_TimerAfterFrame = CreateFrame("Frame","CP_TimerAfterFrame", UIParent);
	  CP_TimerAfterFrame:SetScript("onUpdate",function (self,elapse)
		local count = #CP_TimerAfterTable;
		local i = 1;
		while(i<=count) do
		  local waitRecord = tremove(CP_TimerAfterTable,i);
		  local d = tremove(waitRecord,1);
		  local f = tremove(waitRecord,1);
		  local p = tremove(waitRecord,1);
		  if(d>elapse) then
			tinsert(CP_TimerAfterTable,i,{d-elapse,f,p});
			i = i + 1;
		  else
			count = count - 1;
			f(unpack(p));
		  end
		end
	  end);
	end
	tinsert(CP_TimerAfterTable,{delay,func,{...}});
	return true;
end 

function CPAPI.NewTimer(delay, func)
    local cancelled = false
    CPAPI.TimerAfter(delay, function()
        if not cancelled then
            func()
        end
    end)
    return {
        Cancel = function() cancelled = true end
    }
end

-- Convenience functions
function CPAPI.SetShown(frame, boolean)
	if(boolean) then
	frame:Show()
	else
	frame:Hide()
	end -- lol
end

local cpBagsOpen = false;
function CPAPI.ToggleAllBags()
	CloseAllBags(); -- try to close bags if open.
	if not cpBagsOpen then
		cpBagsOpen = OpenAllBags()
	else
		CloseAllBags()
		cpBagsOpen = false;
	end 
end

function CPAPI.SetEnabled(button, boolean)
	if (boolean) then
	button:Enable()
	else
	button:Disable()
	end
end

function CPAPI.GetScaledCursorPosition()
	local uiScale = UIParent:GetEffectiveScale();
	local x, y = GetCursorPosition();
	return x / uiScale, y / uiScale;
end

-- callmethod workaround


local function CPAPICallMethodInner(frame, methodName, ...)
    local method = frame[methodName];
    -- Ensure code isn't run securely
    forceinsecure();
    if (type(method) ~= "function") then
        error("Invalid method '" .. methodName .. "'");
        return;
    end
    method(frame, ...); 
end

function CPAPI:CallMethodFromFrame(srcframe, methodName, ...)
	local frame = _G[srcframe]   
	if (not frame) then
		error("Invalid control handle");
		return;
	end
	if (type(methodName) ~= "string") then
		error("Method name must be a string");
		return;
	end
	-- Use a pcall wrapper here to ensure that execution continues
	-- regardless
	local ok, err =
		securecall(pcall, CPAPICallMethodInner, frame, methodName, scrub(...));
	if (err) then
		--SoftError(err);
	end
end

-- SoundKit

local CP_SOUNDKIT = {
    ["GS_CHARACTER_SELECTION_ENTER_WORLD"] = 809,
    ["IG_SPELLBOOK_OPEN"] = 829,
    ["IG_SPELLBOOK_CLOSE"] = 830,
    ["IG_MAINMENU_OPTION_CHECKBOX_ON"] = 856,
    ["IG_MAINMENU_OPTION_CHECKBOX_OFF"] = 857,
    ["ACHIEVEMENT_MENU_OPEN"] = 13832,
    ["ACHIEVEMENT_MENU_CLOSE"] = 13833
};

function CPAPI.GetSound(sound)
	return CP_SOUNDKIT[sound]
end


-- Frame wrapper, provide backwards compat in widgets
CPAPI.FrameMixin = {
	SetBackdrop = function(self, ...)
		if BackdropTemplateMixin then
			if not self.OnBackdropLoaded then 
				CPAPI.Mixin(self, BackdropTemplateMixin)
				self:HookScript('OnSizeChanged', self.OnBackdropSizeChanged)
			end
			BackdropTemplateMixin.SetBackdrop(self, ...)
		else
			getmetatable(self).__index.SetBackdrop(self, ...)
		end
	end;
};

function CPAPI.CreateFrame(...)
	return CPAPI.Mixin(CreateFrame(...), CPAPI.FrameMixin)
end






-- OmniCC style cooldown text for ConsolePortBar, adapted from OmniCC by Shestak and Nevcairiel (https://www.wowinterface.com/downloads/info25099-OmniCC.html)

CPAPI.CPCC = CPAPI.CPCC or {}

local CPCC = CPAPI.CPCC

CPCC.db = {
    enabled = true,
    font = "Fonts\\FRIZQT__.TTF",
    fontSize = 24,
    fontFlags = "OUTLINE",
    minDuration = 1.5,      -- ignore shorter cooldowns (GCD etc)
    decimalThreshold = 10,  -- show decimals when < this many seconds
    colorThresholds = {     -- (seconds) : color
        red = 2,
        yellow = 5,
    },
    popOnFinish = true,     -- scale pop when cooldown finishes
    popScale = 1.6,
    popDuration = 0.25,     -- seconds for pop animation
}

-- Internal tables
CPCC.texts = CPCC.texts or {}   
CPCC.meta = CPCC.meta or {} 


local function formatTime(s)
    if s <= 0 then return "" end
    if s >= 3600 then
        local hours = math.floor(s / 3600 + 0.5)
        return string.format("%dh", hours)
    elseif s >= 60 then
        local mins = math.floor(s / 60 + 0.5)
        return string.format("%dm", mins)
    else
        if s < CPCC.db.decimalThreshold then
            -- one decimal place
            return string.format("%.1f", s)
        else
            return string.format("%d", math.floor(s + 0.5))
        end
    end
end

local function chooseColor(remaining)
    if remaining <= CPCC.db.colorThresholds.red then
        return 1, 0.12, 0.12 -- red-ish
    elseif remaining <= CPCC.db.colorThresholds.yellow then
        return 1, 0.95, 0.12 -- yellow-ish
    else
        return 1, 1, 1 -- white
    end
end

function CPCC:CreateTextFor(parentRCooldown)
    if not parentRCooldown then return nil end
    local name = parentRCooldown:GetName()
    if not name then return nil end
    if self.texts[name] then return self.texts[name] end

    local holder = CreateFrame("Frame", name .. "OmniTextHolder", parentRCooldown)
    holder:SetAllPoints(parentRCooldown)
    holder:SetFrameLevel(parentRCooldown:GetFrameLevel() + 10) 

    local fs = holder:CreateFontString(nil, "OVERLAY")
    fs:SetFont(self.db.font, self.db.fontSize, self.db.fontFlags)
    fs:SetPoint("CENTER", holder, "CENTER", 0, 0)
    fs:SetJustifyH("CENTER")
    fs:SetJustifyV("MIDDLE")
    fs:SetAlpha(1)
    fs:Show()

    self.texts[name] = holder
    self.texts[name].fontstring = fs

    self.meta[name] = self.meta[name] or { start = 0, duration = 0, visible = false, pop = 0, popTimer = 0, baseScale = 1 }
    return holder
end

function CPCC:StartCooldown(parentname, start, duration)
    if not self.db.enabled then return end
    if not parentname or not start or not duration then return end
    if duration <= self.db.minDuration then
        -- ignore
        return
    end

    local rcool = _G[parentname]
    if not rcool then return end

    local fs = self:CreateTextFor(rcool)
    local meta = self.meta[parentname]
    meta.start = start
    meta.duration = duration
    meta.visible = true
    meta.pop = 0
    meta.popTimer = 0
    fs:SetScale(meta.baseScale or 1)
    fs:Show()
end

function CPCC:StopCooldown(parentname)
    if not parentname then return end
    local fs = self.texts[parentname]
    local meta = self.meta[parentname]
    if fs and meta then
        fs:Hide()
        meta.visible = false
        meta.start = 0
        meta.duration = 0
        meta.pop = 0
        meta.popTimer = 0
    end
end

function CPCC:OnUpdate(parentname, elapsed)
    if not self.db.enabled then return end
    if not parentname then return end
    local holder = self.texts[parentname]
	local fs = holder.fontstring
    local meta = self.meta[parentname]
    if not fs or not meta then return end
    if not meta.visible or meta.duration <= 0 then
        if holder:IsShown() then holder:Hide() end
        return
    end

    local now = GetTime()
    local remaining = (meta.start + meta.duration) - now

    if remaining <= 0 then
        -- finished: trigger pop + hide after tiny delay
        if self.db.popOnFinish then
            meta.pop = self.db.popScale
            meta.popTimer = self.db.popDuration
        end

        fs:SetText("")
        holder:Hide()
        meta.visible = false
        meta.start = 0
        meta.duration = 0
        return
    end

    local text = formatTime(remaining)
    fs:SetText(text)
    local r,g,b = chooseColor(remaining)
    fs:SetTextColor(r,g,b)

    if meta.popTimer and meta.popTimer > 0 then
        meta.popTimer = meta.popTimer - elapsed
        local t = 1 - (meta.popTimer / self.db.popDuration)
        local s = t * t * (3 - 2 * t)
        local scale = (meta.baseScale or 1) + ( (self.db.popScale - (meta.baseScale or 1)) * (1 - s) )
        holder:SetScale(scale)
        if meta.popTimer <= 0 then
            holder:SetScale(meta.baseScale or 1)
            meta.pop = 0
            meta.popTimer = 0
        end
    else
        holder:SetScale(meta.baseScale or 1)
    end
end

-- Enable / Disable API
function CPCC:Enable()
    self.db.enabled = true
end

function CPCC:Disable()
    self.db.enabled = false
    -- hide everything
    for name, fs in pairs(self.texts) do
        if fs then fs:Hide() end
    end
end

--[==[

    The RoundCooldown functions here is copy/paste from the post  https://www.wowinterface.com/forums/showthread.php?t=45918 
	(Huge thanks to semlar, zork and Infus for the code.) and from the shine animation of the OmniCC AddOn!! thanks to https://www.curseforge.com/members/tullamods

	Cooldown animations on 3.3.5a are squared and there is no way to make it round (no SetMask function available) like
    in newer wow builds, so I had to find a way on how to make custom round cooldown and this is the result of my research.
--]==]

function CPAPI.RoundCooldown_OnLoad(self)
	if(not self:GetParent().roundcd) then
		self:GetParent().roundcd = self
	end

    local cos, sin, pi2, halfpi = math.cos, math.sin, math.rad(360), math.rad(90)
    
    local function Transform(tx, x, y, angle, aspect)
        local c, s = cos(angle), sin(angle)
        local y, oy = y / aspect, 0.5 / aspect
        local ULx, ULy = 0.5 + (x - 0.5) * c - (y - oy) * s, (oy + (y - oy) * c + (x - 0.5) * s) * aspect
        local LLx, LLy = 0.5 + (x - 0.5) * c - (y + oy) * s, (oy + (y + oy) * c + (x - 0.5) * s) * aspect
        local URx, URy = 0.5 + (x + 0.5) * c - (y - oy) * s, (oy + (y - oy) * c + (x + 0.5) * s) * aspect
        local LRx, LRy = 0.5 + (x + 0.5) * c - (y + oy) * s, (oy + (y + oy) * c + (x + 0.5) * s) * aspect
        tx:SetTexCoord(ULx, ULy, LLx, LLy, URx, URy, LRx, LRy)
    end

    local function OnPlayUpdate(self)
        self:SetScript('OnUpdate', nil)
        self:Pause()
    end

    local function OnPlay(self)
        self:SetScript('OnUpdate', OnPlayUpdate)
    end

    local function SetValue(self, value)
        if value > 1 then value = 1
        elseif value < 0 then value = 0 end

        if self._reverse then
            value = 1 - value
        end

        -- Early exit: don't recalculate if value hasn't meaningfully changed
        -- Threshold of ~0.002 means ~0.7 degrees, imperceptible visually
        local lastValue = self._lastValue
        if lastValue and math.abs(value - lastValue) < 0.002 then return end
        self._lastValue = value

        local q = self._clockwise and (1 - value) or value
        local quadrant
        if q >= 0.75 then quadrant = 1
        elseif q >= 0.5 then quadrant = 2
        elseif q >= 0.25 then quadrant = 3
        else quadrant = 4 end

        if self._quadrant ~= quadrant then
            self._quadrant = quadrant
            local textures = self._textures
            if self._clockwise then
                for i = 1, 4 do CPAPI.SetShown(textures[i], i < quadrant) end
            else
                for i = 1, 4 do CPAPI.SetShown(textures[i], i > quadrant) end
            end
            self._scrollframe:SetAllPoints(textures[quadrant])
        end

        local rads = value * pi2
        if not self._clockwise then rads = -rads + halfpi end
        Transform(self._wedge, -0.5, -0.5, rads, self._aspect)
        self._rotation:SetRadians(-rads)
    end

    local function SetClockwise(self, clockwise)
        self._clockwise = clockwise
    end

    local function SetReverse(self, reverse)
        self._reverse = reverse
    end

    local function OnSizeChanged(self, width, height)
        self._wedge:SetSize(width, height)
        self._aspect = width / height
    end

    local function CreateTextureFunction(func)
        return function(self, ...)
            local textures = self._textures
            for i = 1, 4 do
                local tx = textures[i]
                tx[func](tx, ...)
            end
            self._wedge[func](self._wedge, ...)
        end
    end

    local TextureFunctions = {
        SetTexture   = CreateTextureFunction('SetTexture'),
        SetBlendMode = CreateTextureFunction('SetBlendMode'),
        SetVertexColor = CreateTextureFunction('SetVertexColor'),
    }

    local function CreateSpinner(parent)
        local spinner = CreateFrame('Frame', nil, parent)

        local scrollframe = CreateFrame('ScrollFrame', nil, spinner)
        scrollframe:SetPoint('BOTTOMLEFT', spinner, 'CENTER')
        scrollframe:SetPoint('TOPRIGHT')
        spinner._scrollframe = scrollframe

        local scrollchild = CreateFrame('frame', nil, scrollframe)
        scrollframe:SetScrollChild(scrollchild)
        scrollchild:SetAllPoints(scrollframe)

        local wedge = scrollchild:CreateTexture()
        wedge:SetPoint('BOTTOMRIGHT', spinner, 'CENTER')
        spinner._wedge = wedge

        local trTexture = spinner:CreateTexture()
        trTexture:SetPoint('BOTTOMLEFT', spinner, 'CENTER')
        trTexture:SetPoint('TOPRIGHT')
        trTexture:SetTexCoord(0.5, 1, 0, 0.5)

        local brTexture = spinner:CreateTexture()
        brTexture:SetPoint('TOPLEFT', spinner, 'CENTER')
        brTexture:SetPoint('BOTTOMRIGHT')
        brTexture:SetTexCoord(0.5, 1, 0.5, 1)

        local blTexture = spinner:CreateTexture()
        blTexture:SetPoint('TOPRIGHT', spinner, 'CENTER')
        blTexture:SetPoint('BOTTOMLEFT')
        blTexture:SetTexCoord(0, 0.5, 0.5, 1)

        local tlTexture = spinner:CreateTexture()
        tlTexture:SetPoint('BOTTOMRIGHT', spinner, 'CENTER')
        tlTexture:SetPoint('TOPLEFT')
        tlTexture:SetTexCoord(0, 0.5, 0, 0.5)

        spinner._textures  = {trTexture, brTexture, blTexture, tlTexture}
        spinner._quadrant  = nil
        spinner._clockwise = true
        spinner._reverse   = false
        spinner._aspect    = 1
        spinner._lastValue = nil  -- cache for delta check
        spinner:HookScript('OnSizeChanged', OnSizeChanged)

        for method, func in pairs(TextureFunctions) do
            spinner[method] = func
        end

        spinner.SetClockwise = SetClockwise
        spinner.SetReverse   = SetReverse
        spinner.SetValue     = SetValue

        local group    = wedge:CreateAnimationGroup()
        local rotation = group:CreateAnimation('Rotation')
        spinner._rotation = rotation
        spinner._group    = group
        rotation:SetDuration(0)
        rotation:SetEndDelay(1)
        rotation:SetOrigin('BOTTOMRIGHT', 0, 0)
        group:SetScript('OnPlay', OnPlay)
        group:Play()
        return spinner
    end

    self.spinner = CreateSpinner(self:GetParent())
    self.spinner:SetAllPoints()
    self.spinner:SetTexture("Interface\\AddOns\\ConsolePortBar\\Textures\\cooldown")
    self.spinner:SetClockwise(false)
    self.spinner:SetReverse(true)
    self.spinner:SetAlpha(0)

    local spinner   = self.spinner
    local updateFrame = CreateFrame('Frame')
    spinner.f = updateFrame

    local function OnUpdate(f, elapsed)
		local button = self:GetParent()
		if (button and button.isSquareMode) or (button and (not button.isSquareMode and button._sliceMaskContainer)) then 
			-- Stop the spinner and exit
			if f.timespent then f.timespent = nil end
			return  
		end
		
        local ts = f.timespent
        if ts == nil then return end

        ts = ts + elapsed
        if ts >= f.duration then
            f.timespent = nil
            if f.cooldownFrame:IsShown() then
                f.endanimation.Start()
            end

           	CPCC:StopCooldown(f)
            return
        end
        f.timespent = ts
        spinner:SetValue(ts / f.duration)
		CPCC:OnUpdate(self, elapsed)
    end

    updateFrame:SetScript('OnUpdate', OnUpdate)

    local function endanimation_OnFinished(self)
        local parent = self:GetParent()
        if parent:IsShown() then parent:Hide() end
    end

    local function CreateShineAnimation(endanimationFrame)
        local g = endanimationFrame:CreateAnimationGroup()
        g:SetLooping('NONE')
        g:SetScript('OnFinished', endanimation_OnFinished)

        local startTrans = g:CreateAnimation('Alpha')
        startTrans:SetChange(-1)
        startTrans:SetDuration(0)
        startTrans:SetOrder(0)

        local grow = g:CreateAnimation('Scale')
        grow:SetOrigin('CENTER', 0, 0)
        grow:SetDuration(0.8/2)
        grow:SetOrder(1)

        local brighten = g:CreateAnimation('Alpha')
        brighten:SetChange(1)
        brighten:SetDuration(0.8/2)
        brighten:SetOrder(1)

        local shrink = g:CreateAnimation('Scale')
        shrink:SetDuration(0.8/2)
        shrink:SetOrder(2)

        local fade = g:CreateAnimation('Alpha')
        fade:SetChange(-1)
        fade:SetDuration(0.8/2)
        fade:SetOrder(2)

        return g
    end

    local function endAnimOnHide(self)
        self.animation:Finish()
        self:Hide()
    end

    local function CooldownEndAnimStart(self)
        if not self.animation:IsPlaying() then
            self:Show()
            self.animation:Play()
        end
    end

    self.endanimation = CreateFrame('Frame', nil, self:GetParent())
    self.endanimation:Hide()
    self.endanimation:SetScript('OnHide', endAnimOnHide)
    self.endanimation:SetAllPoints()
    self.endanimation.animation = CreateShineAnimation(self.endanimation)
    self.endanimation.Start = function() CooldownEndAnimStart(self.endanimation) end

    updateFrame.endanimation  = self.endanimation
    updateFrame.cooldownFrame = _G[self:GetParent():GetName() .. "Cooldown"]

    local icon = self.endanimation:CreateTexture(nil, 'OVERLAY')
    icon:SetPoint('CENTER')
    icon:SetBlendMode('ADD')
    icon:SetAllPoints(self.endanimation)
    icon:SetTexture("Interface\\Cooldown\\star4")
end

function CPAPI.RoundCooldown_OnSetCooldown(self, start, duration)
    local roundcd = self:GetParent().roundcd

	local button = self:GetParent()
    if (button and button.isSquareMode) then 
        self:SetAlpha(1)
        if roundcd and roundcd.spinner then roundcd.spinner:SetAlpha(0) end
        return
	elseif button and (not button.isSquareMode and button._sliceMaskContainer)  then 
        if roundcd and roundcd.spinner then roundcd.spinner:SetAlpha(0) end
		ConsolePortBar.SliceMask:StartCooldown(button, start, duration)

		if CPCC.db.enabled then 
			local holder = CPCC:CreateTextFor(button)
			if holder and holder.fontstring then
				local scaledSize = math.floor(CPCC.db.fontSize * 0.6)
        		holder.fontstring:SetFont(CPCC.db.font, scaledSize, CPCC.db.fontFlags)
			end
			CPCC:StartCooldown(button, start, duration) 
		end	
		return
    end
    
    local f = roundcd.spinner.f
    f.start = start
    f.duration = duration
    roundcd.spinner._lastValue = nil
    roundcd.spinner:SetAlpha(1)
    f.timespent = GetTime() - start

    if CPCC.db.enabled then
        if roundcd then
            CPCC:CreateTextFor(roundcd)
            CPCC:StartCooldown(roundcd, start, duration)
        end
    end
end

function CPAPI.RoundCooldown_OnShowCooldown(self)
	local button = self:GetParent()
    if (button and button.isSquareMode) then  
        self:SetAlpha(1)
		return
	elseif button and (not button.isSquareMode and button._sliceMaskContainer)  then
		return
	end

    self:GetParent().roundcd.spinner:SetAlpha(1)
    CPCC:CreateTextFor(self:GetParent().roundcd)
end

function CPAPI.RoundCooldown_OnHideCooldown(self)
	local button = self:GetParent()
    if (button and button.isSquareMode) then 
		return
	elseif button and (not button.isSquareMode and button._sliceMaskContainer)  then
		ConsolePortBar.SliceMask:StopCooldown(button)
    	CPCC:StopCooldown(button:GetName())
		return
	end

    self:GetParent().roundcd.spinner:SetAlpha(0)
    CPCC:StopCooldown(self:GetParent().roundcd)
end

------------------------------------------------------------------------------------
-- Custom client workarounds
------------------------------------------------------------------------------------
CPAPI.CustomFrames = CPAPI.CustomFrames or {}

CPAPI.CustomFrames.Ascension = {
    ["SpellButton1"]   = "AscensionSpellbookFrameContentSpellsSpellButton1",
    ["SpellBookFrame"] = "AscensionSpellbookFrame",
    ["SpellBookOwner"] = "AscensionSpellbookFrameContentSpells",
}

-- Check if the client running is a customized client
function CPAPI.IsCustomClient()
    if AscensionTimer and GetAscensionDonationPoints then
        return "Ascension"
    end
    return nil
end

-- Get the custom frame by name, returns nil if not found or not a custom client.
function CPAPI.GetCustomFrame(name)
    local client = CPAPI.IsCustomClient()
    if not client then return nil end

    local frames = CPAPI.CustomFrames[client]
    return frames and _G[frames[name]] or nil
end
