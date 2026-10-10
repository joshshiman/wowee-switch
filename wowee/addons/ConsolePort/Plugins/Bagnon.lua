-- Bagnon fixes

local _, db = ...
local CPAPI = db.CPAPI

ConsolePort:AddPlugin('Bagnon', function(self) 
    -- This is the custom check function for Bagnon items. its ugly but works.
    local function IsBagnonItem(node)  
        if (node:GetParent() and node:GetParent():GetParent() and node:GetParent():GetParent():GetParent()
                and node:GetParent():GetParent():GetParent():GetName()
                    and node:GetParent():GetParent():GetParent():GetName():match("BagnonFrameinventory")
					    and node:GetName():match("ContainerFrame")) then
            return true
        end 
        return false
    end
 
    -- Register custom check function with the main addon's plugin system.
    if db.PLUGINCHECKS and db.PLUGINCHECKS.IsBagNode then
        tinsert(db.PLUGINCHECKS.IsBagNode, IsBagnonItem)
    end
     
    -- Add bagnon frames to the frame stack. 
	self:AddFrame("BagnonFrameinventory")
	self:AddFrame("BagnonFramebank")
	self:AddFrame("BagnonFrameguildbank")
    self:UpdateFrames()


    -- Workaround refreshing ConsolePort framestack because unfortunately bagnon frames are generated on demand.
    local lateFrameTracker = CreateFrame("Frame", nil, UIParent)
 
    lateFrameTracker:RegisterEvent("BANKFRAME_OPENED")
    lateFrameTracker:RegisterEvent("GUILDBANKFRAME_OPENED")

    lateFrameTracker.timer = 2
    lateFrameTracker:SetScript("OnUpdate", function(self, elapsed) 
        if not ConsolePort:IsFrameTracked('BagnonFrameinventory') then
            self:SetScript("OnUpdate", nil) 
            return
        end

        self.timer = self.timer - elapsed 
        if self.timer <= 0 then 
            ConsolePort:UpdateFrames() 
            self.timer = 2
        end
    end)

    lateFrameTracker:SetScript("OnEvent", function(self, event, ...)
        if event == "BANKFRAME_OPENED" then
            CPAPI.TimerAfter(0.5, function() ConsolePort:UpdateFrames() end)
            self:UnregisterEvent("BANKFRAME_OPENED")
        elseif event == "GUILDBANKFRAME_OPENED" then
            CPAPI.TimerAfter(0.5, function() ConsolePort:UpdateFrames() end)
            self:UnregisterEvent("GUILDBANKFRAME_OPENED")
        end
    end)

end)