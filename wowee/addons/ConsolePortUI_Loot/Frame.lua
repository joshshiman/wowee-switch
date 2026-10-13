do
local _, L = ...
local UI = ConsolePortUI

-- This client has no working secure show/hide, so the addon stands down and
-- Blizzard's own LootFrame is the loot window.
--
-- The frame below mirrors Blizzard's LootFrame onto ConsolePort's loot UI
-- through a SecureHandlerShowHideTemplate probe. The probe's show/hide
-- snippets run through the restricted-execution layer (GetFrameHandle,
-- CallRestrictedClosure, the restricted environments in FrameXML's
-- RestrictedExecution.lua). This engine does not carry that layer far enough
-- to deliver: the probe never reaches its owner, so the mirrored frame stays
-- hidden - while UI:HideFrame(LootFrame) has already zeroed Blizzard's frame's
-- size, alpha and anchors. On hardware that is exactly the reported loot
-- window: no panel, only the item icons (LootFrame's children, drawn at their
-- own alpha because alpha does not cascade), and a cursor click that still
-- reaches LootSlot. A frame with no size is not a usable pad or mouse target.
--
-- The previous guard here asked rawget(_G, 'SecureHandlerWrapScript'), and it
-- was wrong: FrameXML's own SecureHandlers.lua defines that global, so the
-- guard never fired and the replacement ran anyway. Every global the probe
-- touches exists - what is missing is their *execution*, which presence cannot
-- answer - so the stand-down is explicit rather than a capability probe.
-- Keep Blizzard's loot window on a client without a working secure show/hide:
-- it draws, and its LootButton OnClick reaches LootSlot.

-- Proof at WARNING, because a Release log drops INFO: the loot panel's own
-- show state and size, read after FrameXML's LootFrame_OnEvent has run. One
-- line per open, and the run says whether the stand-down let the panel draw.
local proof = CreateFrame('Frame')
proof:RegisterEvent('LOOT_OPENED')
proof:SetScript('OnEvent', function()
	if LootFrame and __WoweeWarn then
		__WoweeWarn(('[WOWEE_LOOT] LootFrame shown=%d rect=%dx%d'):format(
			LootFrame:IsShown() and 1 or 0,
			math.floor(LootFrame:GetWidth() or -1),
			math.floor(LootFrame:GetHeight() or -1)))
	end
end)

do return end

-- Unreachable while the stand-down above holds. Kept so the ConsolePort loot
-- UI is not lost if the restricted-execution layer is ever completed.

local frame = UI:CreateFrame('Frame', _, UIParent, 'SecureHandlerBaseTemplate, SecureHandlerShowHideTemplate, SecureHandlerStateTemplate', {
	Size = {1, 1},
	Strata = 'HIGH',
	Point = {'CENTER', 100, 0},
	Mixin = L.LootFrameLogicMixin,
	{
		Container = {
			Type = 'Frame',
			Width = 200,
			Point = {'LEFT', '$parent', 'RIGHT', 0, 0},
			SetMovable = true,
			AdjustHeight = function(self, newHeight)
				self:SetScript('OnUpdate', function(self)
					local height = self:GetHeight()
					local diff = newHeight - height
					if abs(newHeight - height) < 0.5 then
						self:SetHeight(newHeight)
						self:SetScript('OnUpdate', nil)
					else
						self:SetHeight(height + ( diff / 5 ) )
					end
				end)
			end,
			{
				Header = {
					Type = 'Frame',
					Setup = {'CPUILootHeaderTemplate'},
					Point = {'BOTTOM', '$parent', 'TOP', 64, -4},
					OnLoad = function(self)
						self.Text:SetText(LOOT)
						self:SetDurationMultiplier(.5)
					end,
				},
			},
		},
	},
})

UI:RegisterFrame(frame, 'Loot', nil, true, true)
UI:CreateProbe(frame, LootFrame, 'showhide')
UI:HideFrame(LootFrame)
end