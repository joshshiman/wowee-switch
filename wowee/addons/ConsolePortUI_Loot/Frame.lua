do
local _, L = ...
local UI = ConsolePortUI

-- This client does not implement the secure show/hide handler
-- (SecureHandlerWrapScript is absent: the global answers with the missing-API
-- stand-in, so ask rawget). The probe below is a SecureHandlerShowHideTemplate
-- frame whose only job is to mirror Blizzard's LootFrame's show/hide onto our
-- own loot window - with no secure handler it never fires, so registering it
-- left our frame permanently hidden while UI:HideFrame(LootFrame) zeroed
-- Blizzard's frame's size, alpha and anchors. Because the renderer draws each
-- widget at its own alpha (a parent's alpha does not cascade to its children),
-- Blizzard's loot *children* - the item icons and the TargetDead portrait -
-- still drew over a panel that never appeared, and a frame with no size is not
-- a usable click target. Keep Blizzard's own loot window on a client without
-- secure show/hide: it draws, and its LootButton OnClick reaches LootSlot.
if not rawget(_G, 'SecureHandlerWrapScript') then return end

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