---------------------------------------------------------------
-- PixelBridge.lua: Data-to-Pixel Encoder (Experimental)
---------------------------------------------------------------
-- Encodes player state into pixels for external reading with WoWpadX.

local _, db = ...
local Bridge = CreateFrame('Frame', 'ConsolePortPixelBridge', WorldFrame)

-- Pixel Bridge Configuration
local PIXEL_SIZE  = 4 -- We use 8x8 blocks as established for reliability
local FRAME_WIDTH = PIXEL_SIZE * 2
local FRAME_HEIGHT = 1

Bridge:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
Bridge:SetPoint('TOPLEFT', 0, 0)
Bridge:SetFrameStrata('TOOLTIP')
Bridge:SetScale(1)
Bridge:SetBackdrop({ bgFile = [[Interface\Buttons\WHITE8X8]] })

-- Beacon (Left Block)
Bridge.Beacon = Bridge:CreateTexture(nil, 'OVERLAY')
Bridge.Beacon:SetSize(PIXEL_SIZE, FRAME_HEIGHT)
Bridge.Beacon:SetPoint('LEFT')

-- Data (Right Block)
Bridge.Data = Bridge:CreateTexture(nil, 'OVERLAY')
Bridge.Data:SetSize(PIXEL_SIZE, FRAME_HEIGHT)
Bridge.Data:SetPoint('RIGHT')

-- State tracking
local flashTimer = 0
local isMagenta  = true

---------------------------------------------------------------
-- Core Update Logic
---------------------------------------------------------------
function Bridge:OnUpdate(elapsed)
    -- 1. Blinking Logic (0.5s Toggle)
    flashTimer = flashTimer + elapsed
    if flashTimer >= 0.5 then
        isMagenta = not isMagenta
        flashTimer = 0
    end
    
    if isMagenta then
        Bridge.Beacon:SetTexture(1, 0, 1, 1) -- Magenta
    else
        Bridge.Beacon:SetTexture(0, 0, 0, 1) -- Black
    end

    -- 2. Data Encoding
    -- HP: Red Channel
    local hp = (UnitHealth('player') / UnitHealthMax('player'))
    if hp < 0.01 then hp = 0.01 end
    
    -- State: Green Channel (Bitmask)
    local state = 0 
    local speed = GetUnitSpeed('player')
    local isWalking = (speed > 0 and speed < 4.5)

    if isWalking then state = state + 1 end
    if IsMouselooking() then state = state + 2 end
    if UnitAffectingCombat('player') then state = state + 4 end
    
    -- AOE: Blue Channel
    local isAOE = SpellIsTargeting() and 1 or 0
    
    Bridge.Data:SetTexture(hp, state / 255, isAOE, 1)
end

---------------------------------------------------------------
-- Toggle Management
---------------------------------------------------------------
function Bridge:Toggle(enabled)
    if enabled then
        self:Show()
        self:SetScript('OnUpdate', self.OnUpdate)
    else
        self:Hide()
        self:SetScript('OnUpdate', nil)
    end
end

function Bridge:OnVariableChanged(cvar, value)
    if (cvar == 'enablePixelBridge') then
        self:Toggle(value)
    end
end

-- Listen for the setting change via ConsolePort's callback system
ConsolePort:RegisterCallback('FireVarCallback', Bridge.OnVariableChanged, Bridge)

-- Initialize based on current setting
Bridge:Toggle(db('enablePixelBridge'))