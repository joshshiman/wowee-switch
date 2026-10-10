---------------------------------------------------------------
-- Init.lua: Main frame creation, version checking, slash cmd
---------------------------------------------------------------
-- 1. Create the main frame and check all loaded settings.
-- 2. Validate compatibility with older versions.
-- 3. Create the slash handler function.

local addOn, db = ...
local CPAPI = db.CPAPI
---------------------------------------------------------------
local NEWCALIBRATION, BINDINGSLOADED
---------------------------------------------------------------
-- Initialize addon tables
---------------------------------------------------------------
db.ICONS 	= {}
db.TEXTURE 	= {}
db.SECURE 	= {}
db.PANELS 	= {}
db.PLUGINS 	= {}

db.PLUGINCHECKS = {}
db.PLUGINCHECKS.IsBagNode = {}
db.PLUGINCHECKS.IsSpellNode = {} 
db.PLUGINCHECKS.IsMerchantNode = {}

---------------------------------------------------------------
-- Popup functions 
---------------------------------------------------------------
local function LoadDefaultBindings()
	local defaultSet = ConsolePort:GetDefaultBindingSet()
	db.Bindings = defaultSet
	ConsolePortBindingSet = ConsolePortBindingSet or {}
	ConsolePortBindingSet[CPAPI.GetSpecialization()] = db.Bindings
	if ConsolePort.LoadBindingSet then
		ConsolePort:LoadBindingSet(db.Bindings, true)
	end
	if ConsolePort.OnNewBindings then
		ConsolePort:OnNewBindings(db.Bindings)
	end
	if ConsolePort.SetupUtilityBindings then
		ConsolePort:SetupUtilityBindings()
	end
	if ConsolePort.SetupUtilityRing then
		ConsolePort:SetupUtilityRing()
	end
	if ConsolePortOldConfig then
		ConsolePortOldConfig:Hide()
	end
end

local function LoadWoWmapper()
	db('calibration', db.table.copy(WoWmapper.Keys))
	for k, v in pairs(WoWmapper.Settings) do
		db(k, v)
	end
	db('type', db('forceController') or db('type'))
end

local function CancelPopup()
	ConsolePort:ClearPopup()
end

---------------------------------------------------------------

---------------------------------------------------------------
-- Custom client workarounds
---------------------------------------------------------------

local function FixSecureHandler(object)
    function object:SetFrameRef(label, ref)
        SecureHandlerSetFrameRef(object, label, ref)
    end

    function object:Execute(func)
        SecureHandlerExecute(object, func)
    end

    function object:WrapScript(frame, name, script)
        SecureHandlerWrapScript(frame, name, object, script)
    end
end

if CPAPI.IsCustomClient() then  
	-- for some weird reason, in some custom clients, the SecureHandler methods are not merged with these frames.
	FixSecureHandler(ConsolePortRaidCursor)
	FixSecureHandler(ConsolePortEasyMotionButton)
	FixSecureHandler(ConsolePortPager)
	FixSecureHandler(ConsolePortRadialHandler)
	FixSecureHandler(ConsolePortUIHandle)
	FixSecureHandler(ConsolePortUtilityToggle)
end
---------------------------------------------------------------

function ConsolePort:LoadSettings()
	local selectController --, newUser

	-----------------------------------------------------------
	-- Set/load addon settings
	-----------------------------------------------------------
	if not ConsolePortSettings then
		ConsolePortSettings = self:GetDefaultAddonSettings()
	end

	db.Settings = ConsolePortSettings
	db('calibration', db('calibration') or (ConsolePortSettings and ConsolePortSettings.calibration) or {})

	self:LoadLookup()

	if not ConsolePortBindingSet or not next(ConsolePortBindingSet) then
		LoadDefaultBindings()
	else
		-- WoWee handheld remap (rev 1): A = interact, X = jump, B = bags.
		-- Saved per-character binding sets shadow the profile defaults, so
		-- patch the three main slots in place and re-apply once.
		local spec = CPAPI.GetSpecialization and CPAPI.GetSpecialization()
		local set = spec and ConsolePortBindingSet[spec]
		if set and (ConsolePortBindingSet.woweeBindRev or 0) < 1 then
			local remap = {CP_R_RIGHT = 'INTERACTTARGET', CP_R_UP = 'JUMP', CP_R_DOWN = 'OPENALLBAGS'}
			for button, action in pairs(remap) do
				if type(set[button]) == 'table' then
					set[button][''] = action
				end
			end
			ConsolePortBindingSet.woweeBindRev = 1
			db.Bindings = set
			if ConsolePort.LoadBindingSet then
				ConsolePort:LoadBindingSet(set, true)
			end
			if ConsolePort.SetupUtilityBindings then
				ConsolePort:SetupUtilityBindings()
			end
			if ConsolePort.OnNewBindings then
				ConsolePort:OnNewBindings(set)
			end
		end
		-- WoWee handheld remap (rev 2): Plus tiers become the panel doors
		-- (map / character / quests); autorun leaves the pad entirely (L3
		-- keeps it physically). Saved sets still hold the old tiers.
		if set and (ConsolePortBindingSet.woweeBindRev or 0) < 2 then
			if type(set.CP_X_RIGHT) == 'table' then
				set.CP_X_RIGHT['SHIFT-'] = 'TOGGLEWORLDMAP'
				set.CP_X_RIGHT['CTRL-'] = 'TOGGLECHARACTER0'
				set.CP_X_RIGHT['CTRL-SHIFT-'] = 'TOGGLEQUESTLOG'
			end
			ConsolePortBindingSet.woweeBindRev = 2
			db.Bindings = set
			if ConsolePort.LoadBindingSet then
				ConsolePort:LoadBindingSet(set, true)
			end
			if ConsolePort.OnNewBindings then
				ConsolePort:OnNewBindings(set)
			end
		end
	end

	-- The utility ring is built by SetupUtilityRing, which nothing on the
	-- migration path above ever called (LoadDefaultBindings calls it, but
	-- that only runs for fresh binding sets). Without it the toggle button
	-- exists but owns no ring, so Minus clicks into the void, silently. The
	-- call is idempotent (guarded on Utility "initialized"), so run it every
	-- login rather than stamping another rev.
	if ConsolePort.SetupUtilityRing then
		ConsolePort:SetupUtilityRing()
	end

	-- GameMenuFrame arrives anchorless and zero-size in this client (its XML
	-- asks for 195x240 centered, the emitter drops both), so Plus opened a
	-- menu that played its sound and drew nothing. Pin it every login.
	if GameMenuFrame then
		if GameMenuFrame:GetWidth() == 0 or GameMenuFrame:GetHeight() == 0 then
			GameMenuFrame:SetSize(195, 240)
		end
		GameMenuFrame:ClearAllPoints()
		GameMenuFrame:SetPoint('CENTER', UIParent, 'CENTER', 0, 0)
	end

	-- ConsolePortMouseHandle is the smart-mouse interact prompt (300x50 Line
	-- + text + button art, CENTER -300). Its frame is alpha=0, which hides it
	-- on retail - but this client does not propagate parent alpha to children
	-- (renderer uses each widget's own alpha), and the smart-mouse driver is
	-- off anyway (no interactWith binding in the Switch profile). Result: a
	-- permanent empty dark band with an empty circle floating over the
	-- character. Hide the frame outright until the driver is wanted.
	if ConsolePortMouseHandle then
		ConsolePortMouseHandle:Hide()
	end

	-- Minus drives the utility ring through a scripted click, but this
	-- client's Click only runs insecure scripts while the ring's visibility
	-- lives in its secure show/hide template - so the click lands and nothing
	-- appears. Mirror the toggle insecurely (HookScript chains, never
	-- clobbers): release flips the ring, guarded to hook once per session.
	if ConsolePortUtilityToggle and not ConsolePortUtilityToggle.woweeRingHook then
		ConsolePortUtilityToggle.woweeRingHook = true
		ConsolePortUtilityToggle:HookScript('PreClick', function(self, button, down)
			if down then return end
			if InCombatLockdown() then return end
			if self:IsShown() then
				self:Hide()
			else
				if self.Refresh then self:Refresh() end
				self:Show()
			end
		end)
	end

	-----------------------------------------------------------
	-- Load controller splash if no preference exists
	-----------------------------------------------------------
	if selectController then
		self:SelectController()
	end

	-----------------------------------------------------------
	-- Set/load mouse settings
	-----------------------------------------------------------
	ConsolePortMouse = ConsolePortMouse or {
		Events = self:GetDefaultMouseEvents();
		Cursor = self:GetDefaultMouseCursor();
	}
	
	-----------------------------------------------------------
	-- Add empty bindings popup for later use
	-----------------------------------------------------------

	StaticPopupDialogs['CONSOLEPORT_IMPORTBINDINGS'] = {
		button1 = db.TUTORIAL.SLASH.ACCEPT,
		button2 = db.TUTORIAL.SLASH.CANCEL,
		showAlert = true,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
		enterClicksFirstButton = true,
		exclusive = true,
		OnAccept = LoadDefaultBindings,
		OnCancel = CancelPopup,
		OnShow = function(self)
			-- don't show the popup when selecting controller layout or calibrating.
			if 	( ConsolePortSplashFrame and ConsolePortSplashFrame:IsVisible() ) or
				( ConsolePortCalibrationFrame and ConsolePortCalibrationFrame:IsVisible() ) then
				self:Hide()
			end
		end,
	}

	-----------------------------------------------------------
	-- Extra features
	-----------------------------------------------------------

	-- Use these frames in the virtual cursor stack
	ConsolePortUIFrames = ConsolePortUIFrames or self:GetDefaultUIFrames()
	-- Use this table to populate main radial action bar
	ConsolePortUtility = ConsolePortUtility or {}
	-- Use this table to store UI module settings
	ConsolePortUIConfig = ConsolePortUIConfig or {}

	----------------------------------------------------------

	db.UIStack 	= ConsolePortUIFrames
	db.UIConfig = ConsolePortUIConfig
	db.Mouse 	= ConsolePortMouse

	----------------------------------------------------------
	-- Load the calibration wizard if a button does not have a registered mock binding
	----------------------------------------------------------
	if 	self:CheckCalibration() then
		self:CalibrateController()
	end

	----------------------------------------------------------
	-- Load UI handle fade frames
	----------------------------------------------------------
	if ConsolePortUIHandle and ConsolePortUIHandle.LoadFadeFrames then
		ConsolePortUIHandle:LoadFadeFrames()
	end

	----------------------------------------------------------
	-- Create slash handler
	----------------------------------------------------------
	self:CreateSlashHandler()

	----------------------------------------------------------
	-- Dispatch a cvar refresh for reguistered callbacks
	----------------------------------------------------------
	self:RefreshCVars()

	----------------------------------------------------------
	self.LoadSettings = nil
end

function ConsolePort:WMupdate()
	StaticPopupDialogs['CONSOLEPORT_WMUPDATE'] = {
		text = db.TUTORIAL.SLASH.WMUPDATE,
		button1 = db.TUTORIAL.SLASH.ACCEPT,
		button2 = db.TUTORIAL.SLASH.CANCEL,
		showAlert = true,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
		enterClicksFirstButton = true,
		exclusive = true,
		OnAccept = function()
			db('wmupdate', true)
			ReloadUI()
		end,
		OnCancel = CancelPopup,
	}
	self:ShowPopup('CONSOLEPORT_WMUPDATE')
end

function ConsolePort:GetBindingSet(specID)
	-----------------------------------------------------------
	-- Set/load binding table
	-----------------------------------------------------------
	local specID = specID or CPAPI.GetSpecialization() 

	-- Flag bindings loaded so the settings checkup doesn't run this part.
	BINDINGSLOADED = true

	-- Assert the SV binding set container exists before proceeding
	ConsolePortBindingSet = ConsolePortBindingSet or {}

	-- BC: Convert old binding set paradigm to spec-specific
	-- Check if set contains a string key, in which case it's using the
	-- outdated binding format. 
	if type(next(ConsolePortBindingSet)) == 'string' then
		ConsolePortBindingSet = {[specID] = ConsolePortBindingSet}
	end

	-- Assert the current specID is included in the set and that bindings exist,
	-- else create the subset (and flag no bindings for the popup).
	local set = ConsolePortBindingSet
	set[specID] = set[specID] or db.table.copy(db.Bindings) or {}

	-- return the current binding set and the specID
	return set[specID], specID
end

function ConsolePort:CheckLoadedSettings()
	local settings = ConsolePortSettings
	if settings then
		if settings.newController then
			LoadDefaultBindings()
			settings.newController = nil
		elseif NEWCALIBRATION and ( not settings.id or (WoWmapper and WoWmapper.Settings and (settings.id ~= WoWmapper.Settings.id)) ) then
			NEWCALIBRATION = nil
			settings.id = WoWmapper.Settings.id
			StaticPopupDialogs['CONSOLEPORT_CALIBRATIONUPDATE'] = {
				text = db.TUTORIAL.SLASH.CALIBRATIONUPDATE,
				button1 = db.TUTORIAL.SLASH.ACCEPT,
				button2 = db.TUTORIAL.SLASH.CANCEL,
				showAlert = true,
				timeout = 0,
				whileDead = true,
				hideOnEscape = true,
				preferredIndex = 3,
				enterClicksFirstButton = true,
				exclusive = true,
				OnAccept = function()
					LoadWoWmapper()
					ReloadUI()
				end,
				OnCancel = CancelPopup,
			}
			self:ShowPopup('CONSOLEPORT_CALIBRATIONUPDATE')
		elseif BINDINGSLOADED and ( not db.Bindings or not next(db.Bindings) ) then
			LoadDefaultBindings()
		end
	end
end

function ConsolePort:CheckLoadedAddons()
	local loaded = {}
	for name, frames in pairs(db.UIStack) do
		if IsAddOnLoaded(name) then
			for i, frame in pairs(frames) do
				self:AddFrame(frame)
			end
		end
	end
	for name, pluginData in pairs(db.PLUGINS) do
		if pluginData.condition then
			pluginData.loader(self)
			loaded[name] = true
		elseif IsAddOnLoaded(name) then
			pluginData.loader(self)
			loaded[name] = true
		end
	end
	for name in pairs(loaded) do
		db.PLUGINS[name] = nil
	end
end

function ConsolePort:RunPluginNodeChecks(checkType, node)
    if db.PLUGINCHECKS[checkType] then
        for i, checkFunc in ipairs(db.PLUGINCHECKS[checkType]) do 
            local success, result = pcall(checkFunc, node)
            if success and result then
                return true
            end
        end
    end
    return false
end

function ConsolePort:CreateSecureButtons()
	for name in self:GetBindings() do
		for modifier in self:GetModifiers() do
			self:SetSecureButton(name, modifier, self:GetUIControlKey(name))
		end
	end
	self.CreateSecureButtons = nil
end