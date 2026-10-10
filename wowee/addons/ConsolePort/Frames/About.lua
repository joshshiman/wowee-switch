---------------------------------------------------------------
-- About.lua: About panel for ConsolePortLK.
-- Shows project info, links, donation options and a
-- suspiciously well-itemized Two-Hand Relic.
-- (Item tooltip idea from MunkDev).
---------------------------------------------------------------

local _, db = ...
local CPAPI = db.CPAPI

local FadeIn, FadeOut = db.GetFaders()
local red, green, blue = db.Atlas.GetCC()
local WindowMixin = {}

local currentHovered = nil
local enterTimer = nil

-- ============================================================
-- Content definitions
-- ============================================================
local DEFAULT_CONTENT = {
	isItem   = true,
	title    = "|cffff8000ConsolePortLK|r",
	titleSub = "|cffeda55fItem Level 335|r",
	logoPath = [[Interface\AddOns\ConsolePort\Textures\Logos\CP]],
	lines = {
		"Binds when picked up",
		"Unique",
		false,
		{ left = "Two-Hand",      right = "Relic"      },
		{ left = "20 - 26 Damage", right = "Speed 1.01" },
		"(5.5 damage per second)",
		false,
		"|cff1eff00+79 Intellect|r",
		"|cff1eff00+95 Stamina|r",
		"|cff1eff00+82 Spirit|r",
		"|cffcc0000-13 Agility|r",
		false,
		"Durability 50 / 60",
		"Requires Level 80",
		false,
		"|cff00ff00Equip:|r Increases your controller mastery by 172.",
		"|cff00ff00Use:|r They will speak of your exploits for generations.",
		false,
		"|cffffff00\"Are you comfortable with complicated machinery?\"|r",
		false,
		"|cff69ccf0<Port by leoaviana, version " .. GetAddOnMetadata("ConsolePort", "Version") ..">|r",
	},
}

local LINK_CONTENT = {
	CP = {
        isItem   = false,
        title    = "|cffff8000ConsolePortLK|r",
        titleSub = "|cff69ccf0GitHub Repository|r",
        logoPath = [[Interface\AddOns\ConsolePort\Textures\Logos\CP]],
        lines = {
            "The WotLK 3.3.5a port of ConsolePort.",
            "Original addon by Sebastian Lindfors (Munk).",
            false,
			"|cffeda55fCurrent Version " .. GetAddOnMetadata("ConsolePort", "Version") .. "|r",
			false,
            "|cff69ccf0github.com/leoaviana/ConsolePortLK|r",
            false,
            "Visit to download the latest version,",
            "report issues, and contribute.",
            false,
            "|cffffff00Click to open link.|r",
        },
    },
	WP = {
		isItem   = false,
		title    = "|cffff8000WoWpadX|r",
		titleSub = "|cff69ccf0Controller Driver|r",
		logoPath = [[Interface\AddOns\ConsolePort\Textures\Logos\WP]],
		lines = {
			"The recommended controller input driver",
			"for ConsolePortLK.",
			false,
			"|cff69ccf0github.com/leoaviana/WoWpadX|r",
			false,
			"Supports Xbox, Dualsense, and more.",
			false,
			"|cffffff00Click to open link.|r",
		},
	},
	PP = {
		isItem   = false,
		title    = "|cffff8000Support the Project|r",
		titleSub = "|cff69ccf0Buy me a coffee!|r",
		logoPath = [[Interface\AddOns\ConsolePort\Textures\Logos\DN]],
		lines = {
			"If you like this 3.3.5a port of ConsolePort,",
			"WoWpadX or any other project of mine",
			"consider supporting development.",
			false,
			false,
			"Every contribution helps keep me motivated",
			"and the project alive and updated.",
			false,
			"|cffffff00Click to show donation options.|r",
		},
	},
}

local LINKS = {
	CP = "https://github.com/leoaviana/ConsolePortLK/",
	WP = "https://github.com/leoaviana/WoWpadX/releases/latest",
	PP = "https://www.paypal.com/donate/?hosted_button_id=CSQHQU3DNCRYU",
	KF = "https://ko-fi.com/leoaviana",
	WS = "https://www.wise.com/pay/me/leandroa3066",
	BP = "https://app.binance.com/uni-qr/B987oivR",
}

-- ============================================================
-- Sizes - tuned to match retail tooltip density
-- ============================================================
local TOOLTIP_W   = 340   -- box width; wide enough to avoid truncation
local LOGO_ITEM   = 64    -- logo size for isItem layout (outside-left)
local LOGO_HOVER  = 72    -- logo size for hover layout (above, centred)
local LINE_H      = 14    -- tight line height matching retail
local SPACER_H    = 8     -- height of a `false` section spacer
local PAD         = 8     -- inner padding inside the box
local TITLE_H     = 18    -- GameFontNormalLarge approx height
local SUB_H       = 14    -- GameFontHighlightSmall approx height
local MAX_LINES   = 30    -- pool size (must be >= any content line count)

-- ============================================================
-- Helper: measure total height of a lines array
-- ============================================================
local function MeasureLines(lines)
	local h = 0
	for _, v in ipairs(lines) do
		if v == false or v == nil then
			h = h + SPACER_H
		else
			h = h + LINE_H
		end
	end
	return h
end

-- ============================================================
-- Tooltip display frame
-- ============================================================
local function BuildTooltipDisplay(parent)
	local root = CreateFrame("Frame", nil, parent)
	root:SetPoint("CENTER", parent, "CENTER", 0, 60)

	-- Logo
	local logoFrame = CreateFrame("Frame", nil, root)
	local logoTex   = logoFrame:CreateTexture(nil, "ARTWORK")
	logoTex:SetAllPoints(logoFrame)

	-- Box
	local box = CreateFrame("Frame", nil, root)
	box:SetBackdrop({
		bgFile   = [[Interface\Tooltips\UI-Tooltip-Background]],
		edgeFile = [[Interface\Tooltips\UI-Tooltip-Border]],
		tile = true, tileSize = 16, edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	box:SetBackdropColor(0.06, 0.045, 0.025, 0.97)
	box:SetBackdropBorderColor(
		red * 0.6 + 0.15, green * 0.45 + 0.10, blue * 0.08 + 0.02, 1)

	-- Title & sub
	local title = box:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetJustifyH("LEFT")
	local titleSub = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	titleSub:SetJustifyH("LEFT")

	-- Line pool - each slot has a left and optional right fontstring
	local linePool = {}
	for i = 1, MAX_LINES do
		local left  = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		local right = box:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		left:SetJustifyH("LEFT")
		right:SetJustifyH("RIGHT")
		left:SetText("")
		right:SetText("")
		linePool[i] = { left = left, right = right }
	end

	-- Hide all pool entries
	local function HidePool()
		for i = 1, MAX_LINES do
			linePool[i].left:SetText("")
			linePool[i].right:SetText("")
		end
	end

	-- Place line pool starting at offsetY (negative = below top of box)
	-- Returns the next offsetY after all lines
	local function PlaceLines(lines, startY)
		local y   = startY
		local idx = 1
		for _, v in ipairs(lines) do
			if v == false then
				y = y - SPACER_H
			elseif type(v) == "table" then
				-- Two-column row
				local slot = linePool[idx]
				slot.left:ClearAllPoints()
				slot.right:ClearAllPoints()
				slot.left:SetPoint("TOPLEFT",  box, "TOPLEFT",  PAD,       y)
				slot.right:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PAD,      y)
				slot.left:SetText(v.left  or "")
				slot.right:SetText(v.right or "")
				y   = y - LINE_H
				idx = idx + 1
			elseif type(v) == "string" then
				local slot = linePool[idx]
				slot.left:ClearAllPoints()
				slot.right:ClearAllPoints()
				-- Full-width left line; right is hidden
				slot.left:SetPoint("TOPLEFT",  box, "TOPLEFT",  PAD,  y)
				slot.left:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PAD, y)
				slot.left:SetText(v)
				slot.right:SetText("")
				y   = y - LINE_H
				idx = idx + 1
			end
		end
		return y
	end

	-- --------------------------------------------------------
	-- isItem layout
	-- --------------------------------------------------------
	local function ApplyItemLayout(data)
		local ls = LOGO_ITEM

		-- Box height = header + body
		local bodyH = MeasureLines(data.lines or {})
		local boxH  = PAD + TITLE_H + 2 + SUB_H + SPACER_H + bodyH + PAD

		-- Logo to the left, top-aligned with box
		logoFrame:ClearAllPoints()
		logoFrame:SetSize(ls, ls)
		logoFrame:SetPoint("TOPLEFT", root, "TOPLEFT", -50, 0)

		-- Box inset so logo partially overlaps its left edge
		local inset = math.floor(ls * 0.55)
		box:ClearAllPoints()
		box:SetPoint("TOPLEFT",  root, "TOPLEFT",  inset, 0)
		box:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0,     0)
		box:SetHeight(boxH)

		root:SetSize(TOOLTIP_W + inset, math.max(boxH, ls))

		-- Title
		title:ClearAllPoints()
		title:SetPoint("TOPLEFT",  box, "TOPLEFT",  PAD, -PAD)
		title:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PAD, -PAD)
		title:SetText(data.title or "")

		-- Sub-title
		titleSub:ClearAllPoints()
		titleSub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
		titleSub:SetText(data.titleSub or "")

		HidePool()
		PlaceLines(data.lines or {}, -(PAD + TITLE_H + 2 + SUB_H + SPACER_H))
	end

	-- --------------------------------------------------------
	-- Hover layout (logo above, centred)
	-- --------------------------------------------------------
	local function ApplyHoverLayout(data)
		local ls = LOGO_HOVER

		local bodyH = MeasureLines(data.lines or {})
		local boxH  = PAD + TITLE_H + 2 + SUB_H + SPACER_H + bodyH + PAD

		-- Box fills root width, below logo
		box:ClearAllPoints()
		box:SetPoint("TOPLEFT",  root, "TOPLEFT",  0, -(ls + 8))
		box:SetPoint("TOPRIGHT", root, "TOPRIGHT", 0, -(ls + 8))
		box:SetHeight(boxH)

		-- Logo centred above box
		logoFrame:ClearAllPoints()
		logoFrame:SetSize(ls, ls)
		logoFrame:SetPoint("BOTTOM", box, "TOP", 0, 8)

		root:SetSize(TOOLTIP_W, ls + 8 + boxH)

		title:ClearAllPoints()
		title:SetPoint("TOPLEFT",  box, "TOPLEFT",  PAD, -PAD)
		title:SetPoint("TOPRIGHT", box, "TOPRIGHT", -PAD, -PAD)
		title:SetText(data.title or "")

		titleSub:ClearAllPoints()
		titleSub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
		titleSub:SetText(data.titleSub or "")

		HidePool()
		PlaceLines(data.lines or {}, -(PAD + TITLE_H + 2 + SUB_H + SPACER_H))
	end

	function root:SetContent(data)
		logoTex:SetTexture(data.logoPath or [[Interface\AddOns\ConsolePort\Textures\Icons\Logo]])
		if data.isItem then
			ApplyItemLayout(data)
		else
			ApplyHoverLayout(data)
		end
	end

	root:SetContent(DEFAULT_CONTENT)
	return root
end

-- ============================================================
-- Link button
-- ============================================================
local BTN_SIZE    = 80
local BTN_LABEL_H = 20
local BTN_GAP     = 16

local function BuildLinkButton(parent, id, labelText, link, display, config)
	local data     = LINK_CONTENT[id]
	local logoPath = data and data.logoPath

	local btn = CreateFrame("Button", nil, parent)
	btn:SetSize(BTN_SIZE, BTN_SIZE + BTN_LABEL_H)

	local bg = btn:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(BTN_SIZE, BTN_SIZE)
	bg:SetPoint("TOP", btn, "TOP", 0, 0)
	bg:SetTexture([[Interface\Buttons\WHITE8X8]])
	bg:SetVertexColor(0.10, 0.08, 0.04, 1)
	btn.BG = bg

	local border = CreateFrame("Frame", nil, btn)
	border:SetPoint("TOPLEFT",     bg, "TOPLEFT",     -1,  1)
	border:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT",  1, -1)
	border:SetBackdrop({ edgeFile = [[Interface\Buttons\WHITE8X8]], edgeSize = 1 })
	border:SetBackdropBorderColor(
		red * 0.55 + 0.15, green * 0.42 + 0.10, blue * 0.08 + 0.02, 0.8)

	local hl = btn:CreateTexture(nil, "HIGHLIGHT")
	hl:SetSize(BTN_SIZE, BTN_SIZE)
	hl:SetPoint("TOP", btn, "TOP", 0, 0)
	hl:SetTexture([[Interface\Buttons\WHITE8X8]])
	hl:SetVertexColor(red, green, blue, 0.15)
	hl:SetBlendMode("ADD")

	local logo = btn:CreateTexture(nil, "ARTWORK")
	logo:SetSize(BTN_SIZE * 0.62, BTN_SIZE * 0.62)
	logo:SetPoint("CENTER", bg, "CENTER", 0, 0)
	if logoPath then logo:SetTexture(logoPath) end

	local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	label:SetPoint("TOP", bg, "BOTTOM", 0, -4)
	label:SetText(labelText)
	label:SetTextColor(0.75, 0.70, 0.55, 1)
	btn.Label = label

	local accent = btn:CreateTexture(nil, "ARTWORK")
	accent:SetHeight(2)
	accent:SetPoint("BOTTOMLEFT",  bg, "BOTTOMLEFT",  0, 0)
	accent:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", 0, 0)
	accent:SetTexture([[Interface\Buttons\WHITE8X8]])
	accent:SetVertexColor(red * 0.7 + 0.2, green * 0.55 + 0.15, blue * 0.1 + 0.04, 0)
	btn._accent = accent

	btn:SetScript("OnEnter", function(self)
		if leaveTimer then leaveTimer:Cancel() ; leaveTimer = nil end
		currentHovered = self
		FadeIn(self._accent, 0.15, self._accent:GetAlpha(), 1)
		bg:SetVertexColor(0.18, 0.14, 0.07, 1)
		label:SetTextColor(1, 1, 1, 1)
		if data then display:SetContent(data) end
	end)

	btn:SetScript("OnLeave", function(self)
		currentHovered = nil
		FadeOut(self._accent, 0.15, self._accent:GetAlpha(), 0)
		bg:SetVertexColor(0.10, 0.08, 0.04, 1)
		label:SetTextColor(0.75, 0.70, 0.55, 1)
		leaveTimer = CPAPI.NewTimer(0.2, function()
			leaveTimer = nil
			-- only reset if nothing else got hovered in the meantime
			if not currentHovered then
				display:SetContent(DEFAULT_CONTENT)
			end
		end)
	end)

	btn:SetScript("OnClick", function(self)
		if ActivePopup then
			ActivePopup:Hide()
			ActivePopup = nil
		end

		-- allow per-button custom popup logic
		if config and config.OnClick then
			config.OnClick()
			return
		end

		local QRCode     = db.QR(link, 150)
		local textStr    = db.TUTORIAL.SLASH.EXTERNALLINK:format(labelText)
		local paddedText = textStr .. string.rep("\n", 14)

		ActivePopup = CPAPI.Popup("ConsolePort_External_Link", {
			text         = paddedText,
			hasEditBox   = 1,
			maxLetters   = 0,
			button1      = CLOSE,
			timeout      = 0,
			whileDead    = true,
			showAlert = true,
			preferredIndex = 3,
			enterClicksFirstButton = true,
			exclusive = true,
			hideOnEscape = true,
			OnShow = function(popup)
				QRCode:SetParent(popup)
				QRCode:ClearAllPoints()
				QRCode:SetPoint("TOP", popup.text, "TOP", 0, -50)
				QRCode:Show()
				local editBox = popup.editBox or _G[popup:GetName() .. "EditBox"]
				if editBox then
					editBox:SetText(link)
					editBox:HighlightText()
					editBox:SetAutoFocus(false)
					editBox:ClearFocus()
				end
			end,
			OnHide = function(popup)
				QRCode:Release()
				ActivePopup = nil
			end,
		})
	end)

	return btn
end

-- ============================================================
-- Panel
-- ============================================================
db.PANELS[#db.PANELS + 1] = {
	name      = "About",
	header    = "About",
	mixin     = WindowMixin,
	noDefault = true,
	onCreate  = function(self)
		local ctrlType = db("type")
		local model = self:CreateTexture(nil, "BACKGROUND")
		model:SetPoint("CENTER", 0, 20)
		model:SetSize(500, 500)
		model:SetTexture("Interface\\AddOns\\ConsolePort\\Controllers\\" .. ctrlType .. "\\Front")
		model:SetAlpha(0.08)

		local display = BuildTooltipDisplay(self)
		self.Display  = display

		local totalW = BTN_SIZE * 3 + BTN_GAP * 2
		local btnRow = CreateFrame("Frame", nil, self)
		btnRow:SetSize(totalW, BTN_SIZE + BTN_LABEL_H)
		btnRow:SetPoint("BOTTOM", self, "BOTTOM", 0, 40)

		local cpBtn = BuildLinkButton(btnRow, "CP", "ConsolePortLK", LINKS.CP, display)
		local wpBtn = BuildLinkButton(btnRow, "WP", "WoWpadX",       LINKS.WP, display)
		local ppBtn = BuildLinkButton(btnRow, "PP", "Contribute", LINKS.PP, display, {
			OnClick = function()
				local options = {
					{ label = "PayPal", link = LINKS.PP },
					{ label = "Ko-fi",  link = LINKS.KF },
					{ label = "Wise",  link = LINKS.WS },
					{ label = "BinancePay",  link = LINKS.BP },
				}
				local currentIndex = 1
				local QRCode = db.QR(options[1].link, 150)

				local textStr    = db.TUTORIAL.SLASH.EXTERNALLINK:format("Donate")
				local paddedText = textStr .. string.rep("\n", 18)

				local function SwitchOption(index, popup)
					currentIndex = index
					local opt = options[index]
					QRCode:Release()
					QRCode = db.QR(opt.link, 150)
					QRCode:SetParent(popup)
					QRCode:ClearAllPoints()
					QRCode:SetPoint("TOP", popup.text, "TOP", 0, -80)
					QRCode:Show()
					local editBox = popup.editBox or _G[popup:GetName() .. "EditBox"]
					if editBox then
						editBox:SetText(opt.link)
						editBox:HighlightText()
						editBox:SetAutoFocus(false)
						editBox:ClearFocus()
					end
					for i, rb in ipairs(popup._radioButtons) do
						rb:SetChecked(i == index)
					end
				end

				ActivePopup = CPAPI.Popup("ConsolePort_External_Link", {
					text         = paddedText,
					hasEditBox   = 1,
					maxLetters   = 0,
					button1      = CLOSE,
					timeout      = 0,
					whileDead    = true,
					hideOnEscape = true,
					showAlert = true,
					preferredIndex = 3,
					enterClicksFirstButton = true,
					exclusive = true,
					OnShow = function(popup)
						if not popup._radioButtons then
							popup._radioButtons = {}
							local prevBtn = nil
							for i, opt in ipairs(options) do
								local rb = CreateFrame("CheckButton", nil, popup, "UIRadioButtonTemplate")
								rb:SetPoint(
									prevBtn and "LEFT" or "TOP",
									prevBtn or popup.text,
									prevBtn and "RIGHT"or "BOTTOM",
									prevBtn and 40 or -115, prevBtn and 0 or 10)
								rb.index = i
								rb:SetScript("OnClick", function(self)
									SwitchOption(self.index, popup)
								end)
								local lbl = rb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
								lbl:SetPoint("LEFT", rb, "RIGHT", 2, 0)
								lbl:SetText(opt.label)
								popup._radioButtons[i] = rb
								prevBtn = rb
							end
						end

						for _, rb in ipairs(popup._radioButtons) do
							rb:Show()
						end

						SwitchOption(1, popup)
					end,
					OnHide = function(popup)
						if popup._radioButtons then
							for _, rb in ipairs(popup._radioButtons) do
								rb:Hide()
							end
						end
						QRCode:Release()
						ActivePopup = nil
					end,
				})
			end
		})

		cpBtn:SetPoint("LEFT",   btnRow, "LEFT",   0, 0)
		wpBtn:SetPoint("CENTER", btnRow, "CENTER", 0, 0)
		ppBtn:SetPoint("RIGHT",  btnRow, "RIGHT",  0, 0)

		local hline = self:CreateTexture(nil, "ARTWORK")
		hline:SetHeight(1)
		hline:SetPoint("TOPLEFT",  btnRow, "TOPLEFT",  -4, 8)
		hline:SetPoint("TOPRIGHT", btnRow, "TOPRIGHT",  4, 8)
		hline:SetTexture([[Interface\Buttons\WHITE8X8]])
		hline:SetVertexColor(red * 0.4, green * 0.35, blue * 0.08, 0.55)
	end,
}