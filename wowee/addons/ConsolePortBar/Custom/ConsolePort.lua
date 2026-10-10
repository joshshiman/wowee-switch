-- This file modifies default ConsolePort behaviour to accommodate the action bars.
local bar = select(2, ...).bar
---------------------------------------------------------------
-- Raid cursor fix to add the hidden action bars to the interface scan process

if ConsolePortRaidCursor and bar and bar.UIHider then
	if ConsolePortRaidCursor.SetFrameRef then
		ConsolePortRaidCursor:SetFrameRef("hiddenBars", bar.UIHider)
	end
	if ConsolePortRaidCursor.Execute then
		ConsolePortRaidCursor:Execute([[
	UpdateFrameStack = [=[
		local frames = newtable(self:GetParent():GetChildren())
		frames[#frames + 1] = self:GetFrameRef("hiddenBars")
		for _, frame in ipairs(frames) do
			if frame:IsProtected() and not Cache[frame] then
				CurrentNode = frame
				control:Run(GetNodes)
			end
		end
		control:Run(RefreshActions)
		if IsEnabled then
			control:Run(SelectNode, 0)
		end
	]=]
]])
	end
end


---------------------------------------------------------------
-- Stop action button lookup from adding hotkeys to the bars,
-- since this is handled internally by the wrapper.

ConsolePort:SetIgnoreFrameForActionLookup(bar, true)