---------------------------------------------------------------
local db = ConsolePort:GetData()
local CPAPI = db.CPAPI
---------------------------------------------------------------
local _, ab = ...
---------------------------------------------------------------
local cfg

local Bar = ConsolePortBar
local WrapperLib = ab.libs.wrapper
local state, now = ConsolePort:GetActionPageDriver()

local BAR_MIN_WIDTH = 1105
local BAR_MAX_SCALE = 1.6
local BAR_FIXED_HEIGHT = 140

-- Set up action bar
---------------------------------------------------------------
ab.bar = Bar
ab.data = db
---------------------------------------------------------------

Bar:SetAttribute('actionpage', now)
Bar:SetFrameRef('ActionBar', MainMenuBarArtFrame)
Bar:SetFrameRef('BonusActionBar', BonusActionBarFrame)  
--Bar:SetFrameRef('OverrideBar', OverrideActionBar)
Bar:SetFrameRef('Cursor', ConsolePortRaidCursor)
Bar:SetFrameRef('Mouse', ConsolePortMouseHandle)

Bar:Execute([[
	bindings = newtable()
	reticleSpellManifest = newtable()
	reticleMacroString = '/run if C_ConsoleXP then C_ConsoleXP:CastReticle() end' -- reticleMacroString = '/stopspelltarget\n/cast [@cursor] %s'
	bar = self
	cursor = self:GetFrameRef('Cursor')
	mouse = self:GetFrameRef('Mouse')
	self:SetAttribute('state', '')

	UpdateTripleScale = [=[
        local state = ...
        local myMod = self:GetAttribute("modifier") or ""
        -- Retrieve the custom base scale (default to 1.0 if not set)
        local base = self:GetAttribute("baseScale") or 1.0

        if (state == myMod or (state == 'CTRL-SHIFT-' and myMod == '')) and not self:GetAttribute("static") then 
            -- Active cluster: 105% of its base size
            self:SetScale(base * 1.05)
        else 
            -- Inactive cluster: its natural base size
            self:SetScale(base)
        end
    ]=]
]])

function Bar:ResetAllButtons()
    -- Kill dividers from previous cfg
    local prevCfg = ab.cfg
    if prevCfg and prevCfg.dividers then
        for id in pairs(prevCfg.dividers) do
            local div = self[id]
            if div then div:Hide() self[id] = nil end
        end
    end

    local swapIDs = {'CP_T3', 'CP_T4'}
    for _, id in ipairs(swapIDs) do
        local wrapper = ab.libs.registry[id]
        if wrapper and wrapper[''] then
            wrapper[''].isMainButton = nil
        end
    end

    -- Reset all wrapper buttons
    local snippet = ab.libs.acb.childUpdateSnippet and ab.libs.acb.childUpdateSnippet()
    for id, wrapper in pairs(ab.libs.registry) do
        for mod, button in pairs(wrapper.Buttons) do
            if ab.libs.slicemask then
                ab.libs.slicemask:Remove(button)
                button._sliceMaskHooked = nil
                button._sliceMaskContainer = nil
            end

            button.isMainButton = nil
            button.tripleShims = nil
            button:SetScale(1.0)
            -- Clear fake textures
            if button.FakePushed then
                button.FakePushed:SetAlpha(0)
                button.FakePushed = nil
            end
            if button.FakeChecked then
                button.FakeChecked:SetAlpha(0)
                button.FakeChecked = nil
            end
            -- Restore stripped attribute
            if snippet and not button:GetAttribute("_childupdate-state") then
                button:SetAttribute("_childupdate-state", snippet)
            end

		    if mod ~= '' then 
			    button.hotkey:Hide() 
            end
            
            for i = 1, 2 do
                local modIcon = button['hotkey'..i]
                if modIcon then 
                    modIcon:Show()
                    modIcon:SetAlpha(1) 
                end
            end

            button:SetAlpha(0)
            button:Hide()
        end
        -- Main nomod button is always promoted by default
        local main = wrapper['']
        if main then
            main.isMainButton = true
            main:SetAlpha(1)
            main:Show()
        end
    end
end

function Bar:FadeIn(alpha)
	db.UIFrameFadeIn(self, .25, alpha or 0, 1)
end

function Bar:FadeOut(alpha)
	db.UIFrameFadeOut(self, 1, alpha or 1, 0)
end

function Bar:StopCamera()
	ConsolePortCamera:Stop()
end

function Bar:ToggleMovable(enableMouseDrag, enableMouseWheel)
	self:RegisterForDrag(enableMouseDrag and 'LeftButton')
	self:EnableMouse(enableMouseDrag)
	self:EnableMouseWheel(enableMouseWheel)
end

function Bar:UnregisterOverrides()
	self:Execute([[
		bindings = wipe(bindings)
		self:ClearBindings()
	]])
end

function Bar:UpdateOverrides()
	self:Execute([[
		for key, button in pairs(bindings) do
			self:SetBindingClick(true, key, button, 'ControllerInput')
		end
	]])
end

-- WoWee handheld: the secure click path behind these overrides does not run
-- in this client (restricted GetAttribute arrives nil -> "Invalid function
-- body"), so every key stolen this way reads as dead while the handler's own
-- entry for the same key loses the pointer-ordered bucket merge. Neutralize
-- the writer; the pad F-keys then resolve to the handler's direct commands
-- (UseAction etc.). Revert if secure clicks ever land: bonus-bar paging and
-- form states ride these overrides on retail. (WoWeeNeutralizeClickTheft
-- below is the same note kept next to the call site in SetActionBinding.)
function Bar:WoWeeNeutralizeClickTheft()
	-- No-op: see comment above. Kept as a function so SetActionBinding's
	-- call site needs no change.
end

function Bar:RegisterOverride(key, button)
	-- WoWee handheld: neutralized. Recording the key here feeds
	-- UpdateOverrides -> SetBindingClick, which steals the pad F-key into a
	-- secure click path this client cannot drive (restricted GetAttribute
	-- arrives nil -> "Invalid function body"). With the writer off, F-keys
	-- resolve to the handler's direct commands (UseAction etc.). Revert if
	-- secure clicks ever land: bonus-bar paging and form states ride these
	-- overrides on retail.
end

function Bar:OnNewBindings(...)
	if not InCombatLockdown() then
		self:UnregisterOverrides()
		WrapperLib:UpdateAllBindings(...)
		self:UpdateOverrides()
        self:SetupShoulderButtons()
		self:WoWeeScrubPadOverrides()
	end
end

ConsolePort:RegisterCallback('OnNewBindings', Bar.OnNewBindings, Bar)
ConsolePort:RegisterSpellHeader(Bar, true)

function Bar:OnEvent(event, ...)
	if self[event] then
		self[event](self, ...)
	end
end

function Bar:PLAYER_REGEN_ENABLED()
	-- WoWee handheld: only fade when the hidebar option asks for it. The
	-- retail fade-out here drives bar alpha toward 0 after every fight, and
	-- at console frame rates the fade strands mid-value, which reads as a
	-- permanent dim film over the buttons. Default (no hidebar) = always lit.
	if ab.cfg and ab.cfg.hidebar then
		self:FadeOut(self:GetAlpha())
	end
end

function Bar:PLAYER_REGEN_DISABLED()
	if ab.cfg and ab.cfg.hidebar then
		self:FadeIn(self:GetAlpha())
	end
end

function Bar:UPDATE_BONUS_ACTIONBAR()
	WrapperLib:UpdateAllBindings()
end

function Bar:MODIFIER_STATE_CHANGED()
	local mod = ConsolePort:GetCurrentModifier() or ""
	self:SetAttribute("state", mod)
	for _, wrapper in ipairs(self.Buttons) do
		local main = wrapper['']
		if main then
			local kind = main.state_types and (main.state_types[mod] or main.state_types[""]) or "empty"
			local action = main.state_actions and (main.state_actions[mod] or main.state_actions[""])
			main._state_type = kind
			main._state_action = action
			main:SetAttribute("state", mod)
			if main.UpdateAction then
				main:UpdateAction(true)
			end
		end
	end
end

function Bar:ACTIONBAR_SLOT_CHANGED()
	for _, wrapper in ipairs(self.Buttons) do
		local main = wrapper['']
		if main and main.UpdateAction then
			main:UpdateAction(true)
		end
		for _, button in pairs(wrapper.Buttons) do
			if button and button.UpdateAction then
				button:UpdateAction(true)
			end
		end
	end
end

function Bar:LoadReticleSpells()
	Bar:Execute('wipe(reticleSpellManifest)')
	local reticleSpells = ab.manifest and ab.manifest.ReticleSpells
	if type(reticleSpells) == 'table' then
		local classSpecific = reticleSpells[select(2, UnitClass('player'))]
		if type(classSpecific) == 'table' then
			for spellID, name in pairs(classSpecific) do
				Bar:Execute(format('reticleSpellManifest[%d] = "%s"', spellID, name))
			end
		end
	end
	self.LoadReticleSpells = nil
end

function Bar:ADDON_LOADED(name)
	if name == _ then
		if not ConsolePortBarSetup then
			ConsolePortBarSetup = ab:GetDefaultSettings()
		-------------------------------
		-- WoWee Switch migration (rev 2): earlier Switch runs saved the
		-- desktop defaults (gold BG line, class-colour tints, centre-hugging
		-- layout) into the per-character SavedVariables, which then shadow
		-- every code default. Refresh those keys in place so existing
		-- characters pick up the handheld presentation without a /reset.
		else local layout = ConsolePortBarSetup.layout
			if layout then
				layout.CP_T3 = layout.CP_T3 or layout.CP_L_GRIP1 -- translate Lgrip1 to t3
				layout.CP_T4 = layout.CP_T4 or layout.CP_R_GRIP1 -- translate Rgrip1 to t4
				layout.CP_L_GRIP1 = nil layout.CP_R_GRIP1 = nil
				layout.CP_T5 = layout.CP_T5 or layout.CP_L_GRIP2 -- translate Lgrip2 to t5
				layout.CP_T6 = layout.CP_T6 or layout.CP_R_GRIP2 -- translate Rgrip2 to t6
				layout.CP_L_GRIP2 = nil layout.CP_R_GRIP2 = nil
			end
			if (ConsolePortBarSetup.woweeRev or 0) < 4 then
				ConsolePortBarSetup.showline = false
				ConsolePortBarSetup.showart = false
				ConsolePortBarSetup.flashart = false
				ConsolePortBarSetup.swipeRGB = nil
				ConsolePortBarSetup.tintRGB = nil
				ConsolePortBarSetup.borderRGB = nil
				ConsolePortBarSetup.artRGB = nil
				ConsolePortBarSetup.expRGB = nil
				ConsolePortBarSetup.layout = ab:GetDefaultButtonLayout()
				ConsolePortBarSetup.woweeRev = 4
			end
		-------------------------------
		end
		ab:CreateManifest()
		self:LoadReticleSpells()
		self:OnLoad(ConsolePortBarSetup)
		self:UnregisterEvent('ADDON_LOADED')
		self:RegisterEvent('UPDATE_BONUS_ACTIONBAR')
		self.ADDON_LOADED = nil
	end
end

function Bar:OnMouseWheel(delta)
	if not InCombatLockdown() then
		local cfg = ab.cfg
		if IsShiftKeyDown() then
			local newWidth = self:GetWidth() + ( delta * 10 )
			cfg.width = newWidth > BAR_MIN_WIDTH and newWidth or BAR_MIN_WIDTH
			self:SetWidth(cfg.width)
		else
			local newScale = self:GetScale() + ( delta * 0.1 )
			if newScale > BAR_MAX_SCALE then cfg.scale = BAR_MAX_SCALE
			elseif newScale <= 0 then cfg.scale = 0.1
			else cfg.scale = newScale end 
			self:SetScale(cfg.scale)
		end
	end
end

function Bar:SetupShoulderButtons()
    local registry = ab.libs.registry
    local layout = ab.cfg and ab.cfg.layout
    local shoulderMap = {
        ['CP_T3'] = 'CP_M1',
        ['CP_T4'] = 'CP_M2',
    }

    for shoulderID, modifierID in pairs(shoulderMap) do
        if layout and layout[shoulderID] then
            local wrapper = registry[shoulderID]
            local btn = wrapper and wrapper['']
            if btn then
                local hasKey = GetBindingKey(shoulderID) ~= nil
                if not hasKey then
                    btn:SetAttribute('disableDragNDrop', true)
                    local iconPath = "Interface\\AddOns\\ConsolePort\\Controllers\\"..db('type').."\\Icons64\\"
                    local tooltipText = modifierID == 'CP_M1'
                        and 'Modifier 1: Shift\nHold to swap binding set.'
                        or  'Modifier 2: Ctrl\nHold to swap binding set.'
                    ab.libs.acb.SetDummy(btn, iconPath .. db(modifierID), tooltipText)
                    wrapper:ToggleIcon(not (ab.cfg and ab.cfg.hideIcons))
                    if btn.hotkey then btn.hotkey.texture:SetTexture(db.ICONS[modifierID]) end
                    for i = 1, 2 do
                        local modIcon = btn['hotkey'..i]
                        if modIcon then
                            modIcon:Hide()
                            modIcon:SetAlpha(0)
                        end
                    end

                    for mod, subBtn in pairs(wrapper.Buttons) do
                        if mod ~= '' then
                            subBtn:SetAlpha(0)
                            subBtn:Hide()
                        end
                    end
                else
                    ab.libs.acb.RestoreButton(btn)
                    btn:SetAttribute('disableDragNDrop', nil)
                    wrapper:ToggleIcon(not (ab.cfg and ab.cfg.hideIcons))
                    if btn.hotkey then btn.hotkey.texture:SetTexture(db.ICONS[shoulderID]) end
                    for i = 1, 2 do
                        local modIcon = btn['hotkey'..i]
                        if modIcon then
                            modIcon:Show()
                            modIcon:SetAlpha(1)
                        end
                    end

                    for mod, subBtn in pairs(wrapper.Buttons) do
                        if mod ~= '' then
                            subBtn:SetAlpha(1)
                            subBtn:Show()
                        end
                    end
                    -- Restore proper metatable
                    WrapperLib:UpdateWrapperBindings(wrapper, ConsolePort:GetCurrentBindings()[shoulderID])
                end
            end
        end
    end
end

function Bar:OnLoad(cfg, benign)
	if not InCombatLockdown() then
        self:ResetAllButtons()
    end
	
    local r, g, b = db.Atlas.GetNormalizedCC()
    ab.cfg = cfg
    ConsolePortBarSetup = cfg
    self:SetScale(cfg.scale or 1)

    -- Bar Visibility Driver
    self:SetAttribute('hidesafe', cfg.hidebar)
    if cfg.hidebar then
        self:RegisterEvent('PLAYER_REGEN_ENABLED')
        self:RegisterEvent('PLAYER_REGEN_DISABLED')
        self:FadeOut(self:GetAlpha())
    else
        self:UnregisterEvent('PLAYER_REGEN_ENABLED')
        self:UnregisterEvent('PLAYER_REGEN_DISABLED')
        self:SetAlpha(1)
        self:Show()
        self:FadeIn(self:GetAlpha())
    end

    if CPAPI.CPCC then
        if cfg.enablecooldowntext then CPAPI.CPCC:Enable() else CPAPI.CPCC:Disable() end
    end

    local visDriver = cfg.combathide and '[nocombat] show; hide' or '[combat][nocombat] show; hide'
    RegisterStateDriver(Bar, 'visibility', visDriver)

    -- Pet Driver
    if cfg.hidepet then
        UnregisterStateDriver(Bar.Pet, 'visibility')
        Bar.Pet:Hide()
    elseif cfg.combatpethide then
        RegisterStateDriver(Bar.Pet, 'visibility', '[pet,nocombat] show; hide')
    else
        RegisterStateDriver(Bar.Pet, 'visibility', '[pet] show; hide')
    end

    -- Visual Stylings
    if cfg.showline then self.BG:Show() self.BottomLine:Show() else self.BG:Hide() self.BottomLine:Hide() end
    if not cfg.showline then
        self.BG:Hide()
        self.BottomLine:Hide()
    end
    ab:SetArtUnderlay(cfg.showart or cfg.flashart, cfg.flashart)
    ab:SetRainbowScript(cfg.rainbow)

    if cfg.tintRGB then
        self.BG:SetGradientAlpha(ab:GetColorGradient(unpack(cfg.tintRGB)))
        self.BottomLine:SetVertexColor(unpack(cfg.tintRGB))
    else
        self.BG:SetGradientAlpha(ab:GetColorGradient(1, 1, 1))
        self.BottomLine:SetVertexColor(1, 1, 1, 1)
    end

    CPAPI.SetShown(self.Menu, cfg.quickMenu)
    self.Pet:RegisterForDrag(not cfg.lockpet and 'LeftButton' or nil)
    self:ToggleMovable(not cfg.lock, cfg.mousewheel)

    -- Core Layout Processing
    cfg.layout = cfg.layout or ab:GetDefaultButtonLayout()
    local layout = cfg.layout
    local hideIcons = cfg.hideIcons
    local hideModifiers = cfg.hideModifiers
    local classicBorders = cfg.classicBorders

    -----------------------------------------------------------
    -- TRIPLE PRESET: Deterministic Initialization
    -----------------------------------------------------------
    wipe(self.Buttons)
    self:SetAttribute('isTriple', cfg.isTriple)

	if cfg.dividers then
        for id, dividerData in pairs(cfg.dividers) do
            local div = ab.Divider:Create(self, id)
            ab.Divider:Update(div, dividerData, "M0") -- Default state
            self:SetFrameRef(id, div)
			self[id] = div -- Direct reference for quick access in focus updates
        end
    end

	local buttonIndex = 0
    for id, layoutData in pairs(layout) do
        local baseID = id:match("^(CP_[^_]+_[^_]+)") or id
        
        -- Get or create the logic wrapper for the binding group
        local wrapper = WrapperLib:Get(baseID) or WrapperLib:Create(self, baseID, layoutData.dir or "down")

        local suffix = id:match("CP_[^_]+_[^_]+_(.+)$") or ""
        local modString = (suffix == "SHIFT" and "SHIFT-") or 
                          (suffix == "CTRL" and "CTRL-") or 
                          (suffix == "CTRL_SHIFT" and "CTRL-SHIFT-") or ""
        
        local button = wrapper.Buttons[modString]
        if button then 
			buttonIndex = buttonIndex + 1
            button.id = id -- Crucial: Set ID so WrapperMixin:SetSize finds layoutData
            button.isMainButton = true -- Bypass automatic hiding/ghosting
			button:SetAttribute("modifier", modString)
            button:SetAlpha(1)
            button:Show()
			button:SetAttribute("static", layoutData.static)

			self:SetFrameRef("child"..buttonIndex, button)
        end

        local exists = false
        for _, existing in ipairs(self.Buttons) do if existing == wrapper then exists = true end end
        if not exists then self.Buttons[#self.Buttons + 1] = wrapper end

        wrapper:SetSize(layoutData.size or 45)
        wrapper:UpdateOrientation(layoutData.dir or 'down')

        if id == baseID and layoutData.point then
            wrapper:SetPoint(unpack(layoutData.point))
        end

		if button then
			local baseScale = layoutData.scale or 1.0
    		button:SetAttribute("baseScale", baseScale)
    		button:SetScale(baseScale)
		end

        -- Visual Sync
        wrapper:ToggleIcon(not hideIcons)
        wrapper:ToggleModifiers(not hideModifiers)
        wrapper:SetClassicBorders(classicBorders)
        wrapper:SetSwipeColor(unpack(cfg.swipeRGB or {1, 1, 1, 1}))
        wrapper:SetBorderColor(unpack(cfg.borderRGB or {1, 1, 1, 1}))
    end

	-- Strip _childupdate-state from non-promoted buttons only
	for _, wrapper in ipairs(self.Buttons) do
		for mod, button in pairs(wrapper.Buttons) do
			if not button.isMainButton then
				button:SetAttribute('_childupdate-state', nil)
            end

            if mod ~= '' then
                if(button.isMainButton) then
				    button.hotkey:Show()
                    for i = 1, 2 do
                        local modIcon = button['hotkey'..i]
                        if modIcon then
                            modIcon:Hide()
                            modIcon:SetAlpha(0) 
                        end
                    end
                end
			end  
		end
	end

	self:SetAttribute("childCount", buttonIndex)

	if cfg.isTriple then
    	self:SetupTripleClickVisuals()
	end
    -----------------------------------------------------------

    self.WatchBarContainer:Hide()
    CPAPI.SetShown(self.WatchBarContainer, not cfg.hidewatchbars)

    if not benign then
        WrapperLib:UpdateAllBindings()
        self:Hide() 
        CPAPI.SetShown(self, not cfg.hidebar)
        self:SetAttribute('disableCastOnRelease', cfg.disablecastonrelease)
        self:SetAttribute('page', 1)
        self:Execute(format([[
            disableCastOnRelease = self:GetAttribute('disableCastOnRelease')
            control:ChildUpdate('state', '')
            control:RunAttribute('_onstate-page', '%s')
        ]], now or 1))
    end

    if cfg.showbuttons then
        self.Eye:SetAttribute('showbuttons', true)
        self:Execute("control:ChildUpdate('hover', true)")
    else
        self.Eye:SetAttribute('showbuttons', false)
        self:Execute("control:ChildUpdate('hover', false)")
    end

    local width = cfg.width or (#self.Buttons > 10 and (10 * 110) + 55 or (#self.Buttons * 110) + 55)
    self:SetSize(width, BAR_FIXED_HEIGHT)

    self:SetupShoulderButtons()
    self:SetAlpha(1)
    self:Show()

    -- WoWee diag (temporary): the secure click/drag snippets die with
    -- "Invalid function body", i.e. restricted self:GetAttribute arrives nil.
    -- Read the same attributes insecurely here plus a handle round-trip, so
    -- the next log says which side drops them. Remove once settled.
    do
        local warn = __WoweeWarn or print
        local w = self.Buttons[1] and self.Buttons[1]['']
        if w then
            warn('[WOWEE_ATTRDIAG] btn=' .. tostring(w:GetName())
                .. ' OnDragStart=' .. type(w:GetAttribute('OnDragStart'))
                .. ' OnReceiveDrag=' .. type(w:GetAttribute('OnReceiveDrag'))
                .. ' PickupButton=' .. type(w:GetAttribute('PickupButton'))
                .. ' UpdateState=' .. type(w:GetAttribute('UpdateState'))
                .. ' state=' .. tostring(w:GetAttribute('state')));
            if GetFrameHandle and GetFrameHandleFrame then
                local h = GetFrameHandle(w);
                local back = h and GetFrameHandleFrame(h);
                warn('[WOWEE_ATTRDIAG] handle-roundtrip=' .. tostring(back == w)
                    .. ' F3=' .. tostring(GetBindingAction('F3'))
                    .. ' F11=' .. tostring(GetBindingAction('F11'))
                    .. ' F12=' .. tostring(GetBindingAction('F12')));
                -- The fork: read THROUGH the handle, exactly as restricted
                -- code does. Table read fine + handle read nil = registry
                -- bridge broken; both fine = secure reads live again.
                -- Plus the fallback breadcrumb (see mt:GetAttribute): hits
                -- counts fallback runs on this frame, innerAt whether the
                -- inner table had attributes at all.
                local ok, hv = pcall(function() return h:GetAttribute('OnDragStart') end);
                warn('[WOWEE_ATTRDIAG] handle-read ok=' .. tostring(ok)
                    .. ' type=' .. type(hv)
                    .. ' fallbackHits=' .. tostring(w.__woweeFallbackHits)
                    .. ' fallbackInnerAt=' .. tostring(w.__woweeFallbackInnerAt));
                -- Local surrogate repro: same {[1]=frame} shape Blizzard
                -- builds, same metatable, read the same key. If this says
                -- string while handle-read says nil, the live handle points
                -- somewhere else (stale registry); if this also says nil,
                -- the mechanics themselves fail here.
                do
                    local surr = {[1] = w}
                    local okS = pcall(setmetatable, surr, getmetatable(w))
                    local rType = 'nometa'
                    if okS then
                        local okR, rv = pcall(function() return surr:GetAttribute('OnDragStart') end)
                        rType = (okR and type(rv)) or 'err'
                    end
                    warn('[WOWEE_ATTRDIAG] repro surrogate-read=' .. rType
                        .. ' hisW0=' .. tostring(h == w[0]));
                end
            end
            -- Is the CLICK override baked into the binding set itself?
            if ConsolePort and ConsolePort.GetBindingSet then
                local set = ConsolePort:GetBindingSet();
                if type(set) == 'table' then
                    for _, b in ipairs({'CP_R_LEFT', 'CP_R_DOWN', 'CP_X_LEFT', 'CP_X_RIGHT'}) do
                        local row = set[b];
                        if type(row) == 'table' then
                            local parts = {};
                            for _, m in ipairs({'', 'SHIFT-', 'CTRL-', 'CTRL-SHIFT-'}) do
                                parts[#parts + 1] = m .. '=' .. tostring(row[m]);
                            end
                            warn('[WOWEE_ATTRDIAG] set.' .. b .. ' ' .. table.concat(parts, ' '));
                        else
                            warn('[WOWEE_ATTRDIAG] set.' .. b .. ' MISSING');
                        end
                    end
                end
            end
        end
        if GameMenuFrame then
            warn('[WOWEE_ATTRDIAG] gamemenu size=' .. tostring(GameMenuFrame:GetWidth())
                .. 'x' .. tostring(GameMenuFrame:GetHeight())
                .. ' anchors=' .. tostring(GameMenuFrame:GetNumPoints())
                .. ' shown=' .. tostring(GameMenuFrame:IsShown()));
        end
        -- Glyph-set check: which controller the icon/hint formatting resolves.
        if db then
            warn('[WOWEE_GLYPH] type=' .. tostring(db('type'))
                .. ' iconX=' .. tostring(db.ICONS and db.ICONS.CP_X_LEFT));
        end
    end
end

function Bar:UpdateDividerFocus(newstate)
    local cfg = ab.cfg
    local dividers = cfg and cfg.dividers
    if not dividers then return end
    
    -- Syncing the state strings exactly
    local modMap = { 
        [""] = "M0", 
        ["SHIFT-"] = "M1", 
        ["CTRL-"] = "M2",
        ["CTRL-SHIFT-"] = "M0" -- Usually center is default for double mods in Triple
    }
    local currentMod = modMap[newstate] or "M0"

    for id, data in pairs(dividers) do	
        local div = self[id] 
        if div then
            ab.Divider:Update(div, data, currentMod)
        end
    end
end

function Bar:SetupTripleClickVisuals()
    -- Build lookup: baseButtonName -> { modString -> shimButton }
    local shimLookup = {}
	
    local TEX = [[Interface\AddOns\ConsolePortBar\Textures\Button\%s]]
    
    for _, wrapper in ipairs(self.Buttons) do
        for modString, button in pairs(wrapper.Buttons) do
            if button.isMainButton and modString ~= "" then
                -- Find the corresponding nomod button by name pattern
                -- e.g. CPB_L_LEFT_SHIFT- -> base is CPB_L_LEFT
                local baseName = button:GetName():match("^(CPB_[^_]+_[^_]+)") 
                if baseName then
                    if not shimLookup[baseName] then
                        shimLookup[baseName] = {}
                    end
                    shimLookup[baseName][modString] = button
                end
            end
        end
    end

    for _, wrapper in ipairs(self.Buttons) do
        local mainButton = wrapper['']
        if mainButton and mainButton.isMainButton then
			-- Create fake pushed on the main button too for nomod/CTRL-SHIFT- clicks
			local fakeMainPushed = mainButton:CreateTexture(nil, "OVERLAY")
			fakeMainPushed:ClearAllPoints()
			fakeMainPushed:SetPoint("CENTER", mainButton, "CENTER", 4, -2)
			fakeMainPushed:SetTexture(TEX:format("SquarePushed"))
			fakeMainPushed:SetSize(52, 51)
			fakeMainPushed:SetAlpha(0)
			mainButton.FakePushed = fakeMainPushed

			-- Create fake checked on the main button too for nomod/CTRL-SHIFT- clicks
			local fakeMainChecked = mainButton:CreateTexture(nil, "OVERLAY")
			fakeMainChecked:ClearAllPoints() 
			fakeMainChecked:SetSize(46, 45) 
			fakeMainChecked:SetPoint("CENTER", mainButton, "CENTER", 1, 0)
			fakeMainChecked:SetTexture(TEX:format("SquareHilite"))
			fakeMainChecked:SetBlendMode("ADD")
			fakeMainChecked:SetAlpha(0)
			
			mainButton.FakeChecked = fakeMainChecked

            local myMod = mainButton:GetAttribute("modifier") or ""
            if myMod == "" then
                local baseName = mainButton:GetName():match("^(CPB_[^_]+_[^_]+)")
                local shims = baseName and shimLookup[baseName]
				mainButton.tripleShims = shims
                if shims then

					for _, shim in pairs(shims) do
						local fake = shim:CreateTexture(nil, "OVERLAY")
						fake:ClearAllPoints()
						fake:SetPoint("CENTER", shim, "CENTER", 4, -2)
						fake:SetTexture(TEX:format("SquarePushed"))
						fake:SetSize(52, 51)
						fake:SetAlpha(0)
						shim.FakePushed = fake

						local fakeChecked = mainButton:CreateTexture(nil, "OVERLAY")
						fakeChecked:ClearAllPoints() 
						fakeChecked:SetSize(46, 45) 
						fakeChecked:SetPoint("CENTER", shim, "CENTER", 1, 0)
						fakeChecked:SetTexture(TEX:format("SquareHilite"))
						fakeChecked:SetBlendMode("ADD")
						fakeChecked:SetAlpha(0)
						
						shim.FakeChecked = fakeChecked
					end

                    mainButton:HookScript("PreClick", function(self, button, down)
                        if not self.header:GetAttribute("isTriple") then return end
                        local state = self:GetAttribute("state")
                         if state == "SHIFT-" or state == "CTRL-" then
							local shim = shims[state]
							if shim and shim.FakePushed then
								shim.FakePushed:SetAlpha(down and 1 or 0)
							end
						else
							if self.FakePushed then
								self.FakePushed:SetAlpha(down and 1 or 0)
							end
						end
                    end)
                end
            end
        end
    end
end

--------------------------
---- Secure functions ----
--------------------------
for name, script in pairs({
	['_onhide'] = [[
		self:ClearBindings()
	]],
	['_onshow'] = [[
		for key, button in pairs(bindings) do
			self:SetBindingClick(true, key, button, 'ControllerInput')
		end
		if mouse then
			control:RunFor(mouse, mouse:GetAttribute('UpdateTarget'), mouse:GetAttribute('current'))
		end
		if PlayerInCombat() or ( not self:GetAttribute('hidesafe') ) then
			control:CallMethod('FadeIn')
		end
	]],
	['_onstate-modifier'] = [[
		self:SetAttribute('state', newstate)
		control:ChildUpdate('state', newstate)

		if(self:GetAttribute('isTriple')) then 
			-- Modifier buttons visual scale update
			local count = self:GetAttribute("childCount") or 0
			for i = 1, count do
				local child = self:GetFrameRef("child" .. i)
				if child then
					control:RunFor(child, UpdateTripleScale, newstate)
				end
			end

			control:CallMethod("UpdateDividerFocus", newstate)
		end
	]],
	['_onstate-override'] = [[ 
		control:RunAttribute('UpdateActionBar')
	]],
	['_onstate-override_hidden'] = [[  
		control:RunAttribute('UpdateActionBar') 
	]],
	['_onstate-page'] = [[
		control:RunAttribute('UpdateActionBar')
	]],
	['UpdateActionBar'] = [[
		if GetBonusBarOffset() > 0 then
			newstate = GetBonusBarOffset()+6
		else
			newstate = GetActionBarPage()
		end
		self:SetAttribute('actionpage', newstate)
		control:ChildUpdate('actionpage', newstate)
	]],
	['GetReticleMacro'] = [[
		if disableCastOnRelease then return end
		local actionID, buttonID, down, macro = ...  

		if down then
			if not storedSpellID then
				storedSpellID = control:RunFor(self, self:GetAttribute('GetSpellID'), actionID) 
				storedButtonID = buttonID
				if reticleSpellManifest[storedSpellID] then
					control:CallMethod('StopCamera')
				end
			end
		else
			if storedSpellID and (storedButtonID == buttonID) then
				local spellName = reticleSpellManifest[storedSpellID]
				if spellName then
					macro = reticleMacroString:format(spellName)
				end
			end
			storedSpellID, storedButtonID = nil, nil
		end

		return macro
	]]
--------------------------
}) do Bar:SetAttribute(name, script) end
--------------------------

--

Bar.CallMethodFromFrame = CPAPI.CallMethodFromFrame

---

-- WoWee handheld: scrub the F9 base override. CP_T1 keeps ACTIONBUTTON1
-- in the set for honest bar display, but the local layer owns unmodified L
-- (target + act, ordered) - a live F9->ACTIONBUTTON1 override would resurrect
-- the double attack-toggle. Called after every binding rebuild (migration,
-- OnNewBindings); the PEW reassert below skips writing it in the first place.
function Bar:WoWeeScrubPadOverrides()
	if InCombatLockdown() then return end
	local handler = _G.ConsolePortButtonHandler
	if not handler then return end
	local k1, k2 = GetBindingKey('CP_T1')
	if k1 then SetOverrideBinding(handler, false, k1, nil) end
	if k2 then SetOverrideBinding(handler, false, k2, nil) end
end

function Bar:PLAYER_ENTERING_WORLD()
	if InCombatLockdown() then return end
	local handler = _G.ConsolePortButtonHandler
	local set = ConsolePort and ConsolePort.GetBindingSet and ConsolePort:GetBindingSet()
	if not handler or type(set) ~= 'table' then return end
	local n = 0
	for name, key in pairs(set) do
		if type(key) == 'table' and name:match('^CP_') then
			local base = key['']
			for modifier in ConsolePort:GetModifiers() do
				-- WoWee handheld: the local layer owns unmodified L (target +
				-- act, ordered). Writing F9->ACTIONBUTTON1 here would resurrect
				-- the double attack-toggle. Tiers still register; only the
				-- bare base is skipped. (Unmodified Y is CP-owned now, so F3
				-- writes normally again.)
				local override = nil
				if not (name == 'CP_T1' and modifier == '') then
					override = key[modifier] or base
				end
				if override then
					local k1, k2 = GetBindingKey(name)
					if k1 then SetOverrideBinding(handler, false, modifier .. k1, override) n = n + 1 end
					if k2 then SetOverrideBinding(handler, false, modifier .. k2, override) n = n + 1 end
				end
			end
		end
	end
	if __WoweeWarn then __WoweeWarn('[WOWEE_OVR] reasserted ' .. n .. ' pad overrides at world entry') end
end

Bar:SetScript('OnEvent', Bar.OnEvent)
Bar:SetScript('OnMouseWheel', Bar.OnMouseWheel)
for _, event in ipairs({
	'SPELLS_CHANGED',
	'PLAYER_LOGIN',
	'PLAYER_ENTERING_WORLD',
	'ADDON_LOADED',
	'PLAYER_TALENT_UPDATE',
	'MODIFIER_STATE_CHANGED',
	'ACTIONBAR_SLOT_CHANGED',
}) do pcall(Bar.RegisterEvent, Bar, event) end

Bar.ignoreNode = true
Bar.Buttons = {}
Bar.Elements = {}
Bar.isForbidden = true 

RegisterStateDriver(Bar, 'page', state)

local ov_driver = {}
table.insert(ov_driver, "[bonusbar:5]11") 
for i=1, 4 do
	table.insert(ov_driver, string.format("[bonusbar:%s]%s",i, i))
end

RegisterStateDriver(Bar, 'override_hidden', '[bonusbar:1][bonusbar:2][bonusbar:3][bonusbar:4][bonusbar:5] show; hide')
RegisterStateDriver(Bar, 'override', table.concat(ov_driver, ';'))
RegisterStateDriver(Bar, 'modifier', '[mod:ctrl,mod:shift] CTRL-SHIFT-; [mod:ctrl] CTRL-; [mod:shift] SHIFT-; ')