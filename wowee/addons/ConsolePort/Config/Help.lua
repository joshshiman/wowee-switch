--if select(5, GetAddOnInfo('ConsolePortHelp')) ~= 'DEMAND_LOADED' then return end
local  _, _, addenabled, addloadable,  _, _ = GetAddOnInfo('ConsolePortHelp')
if(addenabled ~= 1 and addloadable ~= 1) then
	return
end

local _, db = ...
local Atlas, mixin, spairs = db.Atlas, db.table.mixin, db.table.spairs
local red, green, blue = db.Atlas.GetCC()
local WindowMixin, IndexButton, HTMLHandler, selectedIndex = {}, {}, {}
local CPAPI = db.CPAPI

-- ============================================================
-- HTML handler methods
-- ============================================================
function HTMLHandler:website(address, linkType)
	StaticPopupDialogs['CONSOLEPORT_EXTERNALLINK'] = {
		text = db.TUTORIAL.SLASH.EXTERNALLINK:format(linkType),
		button1 = CLOSE,
		showAlert = true,
		timeout = 0,
		whileDead = true,
		hideOnEscape = true,
		preferredIndex = 3,
		hasEditBox = 1,
		enterClicksFirstButton = true,
		exclusive = true,
		OnAccept = ConsolePort.ClearPopup,
		OnCancel = ConsolePort.ClearPopup,
		OnShow = function(self, data)
			self.editBox:SetText(data)
		end,
	}
	ConsolePort:ShowPopup('CONSOLEPORT_EXTERNALLINK', nil, nil, address)
end

function HTMLHandler:slash(message)
	local handler = strmatch(message, '^(/[^%s]+)') or ''
	local subCmd = ''
	if ( handler ~= message ) then
		subCmd = message:sub(handler:len() + 2)
	end
	handler = handler:upper():sub(2)
	local cmd = SlashCmdList[handler]
	if cmd then
		cmd(subCmd)
	end
end

function HTMLHandler:run(message)
	local func, errMsg, pcallOK = loadstring(message)
	if func then
		pcallOK, errMsg = pcall(func)
		if pcallOK then return end
	end
	print('HTML function call failed:', errMsg)
end

function HTMLHandler:page(message)
	for i, button in pairs(self.Index.Buttons) do
		if button.pageID == message then
			ConsolePort:SetCurrentNode(button)
			return
		end
	end
end

function HTMLHandler:OnHyperlinkClick(linkData)
	local startPoint, endPoint = linkData:find('%a+:')
	local linkType = linkData:sub(startPoint, endPoint - 1)
	local address = linkData:sub(endPoint + 1)
	if self[linkType] then
		self[linkType](self, address, linkType)
	end
end

function HTMLHandler:GetCursorPoint()
	self.activeCursorPoints = self.activeCursorPoints + 1
	local point = self.cursorPoints[self.activeCursorPoints]
	if not point then
		point = CreateFrame('Button', nil, self)
		point.parent = self
		point:SetSize(4, 4)
		point:SetScript('OnClick', function(self)
			if self.script then
				self.parent:OnHyperlinkClick(self.script)
			end
		end)
		self.cursorPoints[self.activeCursorPoints] = point
	end
	point:Show()
	return point
end

function HTMLHandler:ResetCursorPoints()
	self.activeCursorPoints = 0
	for i, point in pairs(self.cursorPoints) do
		point.script = nil
		point:ClearAllPoints()
		point:Hide()
	end
end

function HTMLHandler:ShowPage(content, references)
	self:ResetCursorPoints()
	self:SetText(content)
	-- Reset scroll to top when switching pages
	if self.ScrollFrame then
		self.ScrollFrame:SetVerticalScroll(0)
		if self.ScrollBar then
			self.ScrollBar:SetValue(0)
		end
	end
	for _, region in pairs({self:GetRegions()}) do
		if region:IsObjectType('FontString') then
			local key = region:GetText()
			for refText, refScript in pairs(references) do
				if key and key:match(refText) then
					local pointButton = self:GetCursorPoint()
					pointButton:SetPoint('TOP', region, 'BOTTOM', 0, 0)
					pointButton.script = refScript
				end
			end
		end
	end
end

-- ============================================================
-- IndexButton behaviour
-- ============================================================
function IndexButton:OnClick()
	if not self.content then return end
	if selectedIndex then
		selectedIndex:SetSelected(false)
	end
	self:SetSelected(true)
	selectedIndex = self
	self.HTML:ShowPage(self.content, self.references)
end

function IndexButton:SetSelected(active)
	CPAPI.SetShown(self._selTex,  active)
	CPAPI.SetShown(self._accLine, active)
	self._label:SetTextColor(
		active and 1    or (self._isHeader and 0.92 or 0.78),
		active and 0.88 or (self._isHeader and 0.82 or 0.78),
		active and 0.45 or (self._isHeader and 0.45 or 0.78),
		1)
end

function IndexButton:ParseContent()
	if not self.content then return end
	for element in self.content:gmatch('<a href=%b""%b></a>') do
		local linkStart = select(2, element:find('href="'))
		local linkEnd = element:find('">')
		local textStart = linkEnd and linkEnd + 2
		local textEnd = element:find("</a>")
		if textStart and textEnd and linkStart and linkEnd then
			self.references[element:sub(textStart, textEnd - 1)] = element:sub(linkStart + 1, linkEnd - 1)
		end
	end
end

-- ============================================================
-- Button factory: clean sidebar-style, no atlas textures
-- ============================================================
local HEADER_H = 34   -- collapsible section header height
local ENTRY_H  = 28   -- child entry height
local BTN_W    = 234  -- full button width inside scroll child

local function CreateIndexEntry(parent, labelText, isHeader, depth)
	local h = isHeader and HEADER_H or ENTRY_H
	local btn = CreateFrame('Button', nil, parent)
	btn:SetHeight(h)
	btn:SetWidth(BTN_W)

	local bgR, bgG, bgB = isHeader and 0.10 or 0.06, isHeader and 0.09 or 0.055, isHeader and 0.07 or 0.05
	local bg = btn:CreateTexture(nil, 'BACKGROUND')
	bg:SetAllPoints()
	bg:SetTexture([[Interface\Buttons\WHITE8X8]])
	bg:SetVertexColor(bgR, bgG, bgB, 1)

	local hl = btn:CreateTexture(nil, 'HIGHLIGHT')
	hl:SetAllPoints()
	hl:SetTexture([[Interface\Buttons\WHITE8X8]])
	hl:SetVertexColor(red, green, blue, 0.1)

	local selTex = btn:CreateTexture(nil, 'BACKGROUND', nil, 1)
	selTex:SetAllPoints()
	selTex:SetTexture([[Interface\Buttons\WHITE8X8]])
	selTex:SetVertexColor(red, green, blue, 0.18)
	selTex:Hide()

	local accLine = btn:CreateTexture(nil, 'ARTWORK')
	accLine:SetWidth(3)
	accLine:SetPoint('TOPLEFT',    btn, 'TOPLEFT',    0, 0)
	accLine:SetPoint('BOTTOMLEFT', btn, 'BOTTOMLEFT', 0, 0)
	accLine:SetTexture([[Interface\Buttons\WHITE8X8]])
	accLine:SetVertexColor(red, green, blue, 1)
	accLine:Hide()

	local sep = btn:CreateTexture(nil, 'ARTWORK')
	sep:SetPoint('BOTTOMLEFT',  btn, 'BOTTOMLEFT',  isHeader and 0 or 8, 0)
	sep:SetPoint('BOTTOMRIGHT', btn, 'BOTTOMRIGHT', -4, 0)
	sep:SetHeight(1)
	sep:SetTexture([[Interface\Buttons\WHITE8X8]])
	sep:SetVertexColor(1, 1, 1, isHeader and 0.08 or 0.04)

	local indent = isHeader and 12 or (14 + depth * 8)
	local label = btn:CreateFontString(nil, 'OVERLAY', isHeader and 'GameFontNormal' or 'GameFontHighlightSmall')
	label:SetPoint('LEFT',  btn, 'LEFT',  indent, 0)
	label:SetPoint('RIGHT', btn, 'RIGHT', isHeader and -30 or -8, 0)
	label:SetJustifyH('LEFT')
	label:SetText(labelText)
	if isHeader then
		label:SetTextColor(0.92, 0.82, 0.45, 1)
	else
		label:SetTextColor(0.78, 0.78, 0.78, 1)
	end

	btn:SetScript("OnMouseDown", function(self)
		label:ClearAllPoints()
		label:SetPoint("LEFT", self, "LEFT", indent + 1, -1)
		label:SetPoint('RIGHT', btn, 'RIGHT', (isHeader and -30 or -8) + 1, -1)
	end)

	btn:SetScript("OnMouseUp", function(self)
		label:ClearAllPoints()
		label:SetPoint('LEFT',  btn, 'LEFT',  indent, 0)
		label:SetPoint('RIGHT', btn, 'RIGHT', isHeader and -30 or -8, 0)
	end)

	local collapseBtn
	if isHeader then
		collapseBtn = CreateFrame('Button', nil, btn)
		collapseBtn:SetSize(28, HEADER_H)
		collapseBtn:SetPoint('TOPRIGHT',    btn, 'TOPRIGHT',    0, 0)
		collapseBtn:SetPoint('BOTTOMRIGHT', btn, 'BOTTOMRIGHT', 0, 0)

		local chl = collapseBtn:CreateTexture(nil, 'HIGHLIGHT')
		chl:SetAllPoints()
		chl:SetTexture([[Interface\Buttons\WHITE8X8]])
		chl:SetVertexColor(red, green, blue, 0.18)

		local arrow = collapseBtn:CreateFontString(nil, 'OVERLAY', 'GameFontNormal')
		arrow:SetPoint('CENTER', collapseBtn, 'CENTER', 0, 0)
		arrow:SetText('-')
		arrow:SetTextColor(red, green, blue, 0.9)
		collapseBtn._arrow = arrow

		btn:SetHitRectInsets(0, 28, 0, 0)
	end

	btn._selTex      = selTex
	btn._accLine     = accLine
	btn._label       = label
	btn._collapseBtn = collapseBtn
	btn._isHeader    = isHeader
	btn._bg          = bg

	return btn
end

-- ============================================================
-- WindowMixin:AddPage - rebuilds the index with collapsible groups
-- ============================================================
function WindowMixin:AddPage(pageID, pageTable, depth, welcome)
	self.pageCount = self.pageCount + 1
	depth = depth + 1

	local index    = self.Index
	local isHeader = (depth == 0)
	local button   = CreateIndexEntry(index.Child, pageID, isHeader, depth)

	mixin(button, IndexButton)

	if isHeader then
		button._children  = {}
		button._collapsed = false
		self._lastHeader  = button
	elseif self._lastHeader then
		table.insert(self._lastHeader._children, button)
	end

	index:AddButton(button, 0)

	button.pageID     = pageID
	button.content    = pageTable.content
	button.HTML       = self.HTML
	button.references = {}
	button:ParseContent()

	button:SetScript('OnClick', function(self)
		if self.content then
			IndexButton.OnClick(self)
		end
	end)

	if isHeader then
		button._collapseBtn:SetScript('OnClick', function(self)
			local hdr = self:GetParent()
			hdr._collapsed = not hdr._collapsed
			self._arrow:SetText(hdr._collapsed and '+' or '-')
			for _, child in ipairs(hdr._children) do
				CPAPI.SetShown(child, not hdr._collapsed)
			end
			index:Refresh()
		end)
	end

	if pageTable.children then
		for childID, childTable in spairs(pageTable.children) do
			self:AddPage(childID, childTable, depth)
		end
	elseif welcome then
		for childID, childTable in spairs(welcome.children) do
			self:AddPage(childID, childTable, depth)
		end
	end

	return button
end

-- ============================================================
-- Override Refresh so it re-stacks only visible buttons
-- ============================================================
local function RefreshHelpIndex(index)
	local y = 0
	for _, btn in ipairs(index.Buttons) do
		if btn:IsShown() then
			btn:ClearAllPoints()
			btn:SetPoint('TOPLEFT', index.Child, 'TOPLEFT', 0, -y)
			y = y + btn:GetHeight()
		end
	end
	index.Child:SetHeight(math.max(1, y))
end

-- ============================================================
-- Error page
-- ============================================================
local errorText =
[[<HTML><BODY>
<H1 align="center">Woops! Something went wrong!</H1>
<IMG src="Interface\Common\spacer" align="center" width="1" height="27"/>
<p align="center">The tutorial content failed to load.</p>
</BODY></HTML>]]

-- ============================================================
-- Panel registration
-- ============================================================
db.PANELS[#db.PANELS + 1] = {
	name      = HELP_LABEL,
	header    = HELP_LABEL,
	mixin     = WindowMixin,
	noDefault = true,
	onLoad = function(self, core)

		-------------------------------------------------------
		-- Index (left sidebar)
		-------------------------------------------------------
		self.Index = Atlas.GetScrollFrame('$parentIndexFrame', self, {
			childWidth = BTN_W,
			stepSize   = ENTRY_H,
			noBackdrop = true,
		})
		self.Index:SetPoint('TOPLEFT',     8,   -8)
		self.Index:SetPoint('BOTTOMRIGHT', self, 'BOTTOMLEFT', BTN_W + 16, 8)
		self.Index.Refresh = function(idx, n)
			RefreshHelpIndex(idx)
		end

		-------------------------------------------------------
		-- Divider
		-------------------------------------------------------
		local divider = self:CreateTexture(nil, 'ARTWORK')
		divider:SetWidth(1)
		divider:SetPoint('TOPLEFT',    self.Index, 'TOPRIGHT',    8, 0)
		divider:SetPoint('BOTTOMLEFT', self.Index, 'BOTTOMRIGHT', 8, 0)
		divider:SetTexture([[Interface\Buttons\WHITE8X8]])
		divider:SetVertexColor(red * 0.4, green * 0.4, blue * 0.4, 0.6)

		-------------------------------------------------------
		-- ScrollFrame
		-------------------------------------------------------

		local HTMLScroll = CreateFrame('ScrollFrame', '$parentHTMLScroll', self)
		HTMLScroll:SetPoint('TOPLEFT',     self.Index, 'TOPRIGHT',    20,  -4)
		HTMLScroll:SetPoint('BOTTOMRIGHT', self,       'BOTTOMRIGHT', -28,  8)
		HTMLScroll:EnableMouseWheel(true)

		local HTML = CreateFrame('SimpleHTML', '$parentHTML', HTMLScroll)
		self.HTML = HTML

		mixin(HTML, HTMLHandler)

		HTML:SetFontObject(SystemFont_Med2)
		HTML:SetFont('p',  [[Fonts\FRIZQT__.ttf]], 14, '')
		HTML:SetFont('h2', SystemFont_Med2:GetFont())
		HTML:SetFont('h1', [[Fonts\MORPHEUS.ttf]], 22)

		HTML:SetTextColor('p',  1, 1, 1)
		HTML:SetTextColor('h2', 1, 0.82, 0)
		HTML:SetTextColor('h1', 1, 0.82, 0)

		HTML:SetPoint('TOPLEFT', HTMLScroll, 'TOPLEFT', 0, 0)
		HTMLScroll:SetScrollChild(HTML)

		HTML:SetWidth(400)
		HTML:SetHeight(600)

		HTML:SetText(errorText)

		local HTML_FIXED_HEIGHT = 700
		
		local function UpdateHTMLSize()
			local w = HTMLScroll:GetWidth()
			if w and w > 10 then
				HTML:SetWidth(w)
			end
			HTML:SetHeight(HTML_FIXED_HEIGHT)
		end 
		UpdateHTMLSize()

		HTMLScroll:HookScript('OnSizeChanged', UpdateHTMLSize)

		-- Also update height when HTML content changes
		HTML:HookScript('OnUpdate', function(self)
			local contentH = HTML_FIXED_HEIGHT
			local scrollH  = HTMLScroll:GetHeight() or 0
			if contentH > 0 then
				self:SetHeight(math.max(contentH, scrollH))
			end
		end)

		-------------------------------------------------------
		-- Scrollbar
		-------------------------------------------------------
		local scrollbar = CreateFrame('Slider', '$parentHTMLScrollBar', HTMLScroll, 'UIPanelScrollBarTemplate')
		scrollbar:SetPoint('TOPLEFT',    HTMLScroll, 'TOPRIGHT',    4, -16)
		scrollbar:SetPoint('BOTTOMLEFT', HTMLScroll, 'BOTTOMRIGHT', 4,  16)
		scrollbar:SetMinMaxValues(0, 0)
		scrollbar:SetValueStep(20)
		scrollbar:SetValue(0)

		HTMLScroll:HookScript('OnScrollRangeChanged', function(self, _, yRange)
			local range = yRange or 0
			scrollbar:SetMinMaxValues(0, range)
			scrollbar:SetValue(self:GetVerticalScroll())
		end)

		scrollbar:HookScript('OnValueChanged', function(self, value)
			HTMLScroll:SetVerticalScroll(value)
		end)

		HTMLScroll:HookScript('OnMouseWheel', function(self, delta)
			local current = self:GetVerticalScroll()
			local _, max  = scrollbar:GetMinMaxValues()
			local new     = math.max(0, math.min(max, current - delta * 40))
			self:SetVerticalScroll(new)
			scrollbar:SetValue(new)
		end)

		-- Back-references for ShowPage to reset scroll on page change
		HTML.ScrollFrame = HTMLScroll
		HTML.ScrollBar   = scrollbar

		-------------------------------------------------------
		-- Dark backdrop behind the content area
		-------------------------------------------------------
		HTML.Backdrop = CPAPI.CreateFrame('Frame', '$parentBackdrop', self)
		do
			local hbg = HTML.Backdrop:CreateTexture(nil, 'BACKGROUND')
			hbg:SetAllPoints(HTML.Backdrop)
			hbg:SetTexture([[Interface\Buttons\WHITE8X8]])
			hbg:SetVertexColor(0.055, 0.05, 0.045, 0.6)
		end
		HTML.Backdrop:SetPoint('TOPLEFT',     HTMLScroll, 'TOPLEFT',     -8,  8)
		HTML.Backdrop:SetPoint('BOTTOMRIGHT', HTMLScroll, 'BOTTOMRIGHT',  8, -8)
		HTML.Backdrop:SetFrameLevel(self:GetFrameLevel() - 1)
		self:HookScript('OnShow', function() HTML.Backdrop:Show() end)
		self:HookScript('OnHide', function() HTML.Backdrop:Hide() end)

		-------------------------------------------------------
		-- Cursor points for hyperlink hit-testing
		-------------------------------------------------------
		HTML.cursorPoints        = {}
		HTML.activeCursorPoints  = 0

		-------------------------------------------------------
		-- Load addon content
		-------------------------------------------------------
		if not LoadAddOn('ConsolePortHelp') then
			return
		end

		self.pageCount = 0
		HTML.Index     = self.Index

		self.Pages, self.WelcomePage, self.WelcomeSubpages = ConsolePortHelp:GetPages()
		local welcomeIndex = self:AddPage('|cff69ccf0Introduction|r', {content = self.WelcomePage}, -1, self.WelcomeSubpages)
		welcomeIndex:Click()

		for pageID, pageTable in spairs(self.Pages) do
			self:AddPage(pageID, pageTable, -1)
		end

		self.Index:Refresh(self.pageCount)
	end,
}