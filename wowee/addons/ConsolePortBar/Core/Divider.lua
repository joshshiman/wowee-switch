local _, ab = ...
local db = ConsolePort:GetData()
local Divider = {}
ab.Divider = Divider

local GRADIENT_TEX = [[Interface\QuestFrame\UI-QuestLogTitleHighlight]]
local WHITE_TEX    = [[Interface\Buttons\WHITE8X8]]

local function SnapToCardinal(deg)
    local snapped = math.floor((deg + 45) / 90) * 90
    return snapped % 180
end

function Divider:Create(parent, name)
    local f = _G[name] or CreateFrame("Frame", name, parent)
    f:SetSize(1, 1)
    f:SetFrameLevel(parent:GetFrameLevel() + 1)

    if not f.Gradient then
        f.Gradient = f:CreateTexture(nil, "BACKGROUND")
        f.Gradient:SetTexture(GRADIENT_TEX)
        f.Gradient:SetBlendMode("ADD")
    end

    if not f.Gradient2 then
        f.Gradient2 = f:CreateTexture(nil, "BACKGROUND")
        f.Gradient2:SetTexture(GRADIENT_TEX)
        f.Gradient2:SetBlendMode("ADD")
    end

    if not f.LineTop then
        f.LineTop = f:CreateTexture(nil, "ARTWORK")
        f.LineTop:SetTexture(WHITE_TEX)
    end
    if not f.LineMid then
        f.LineMid = f:CreateTexture(nil, "ARTWORK")
        f.LineMid:SetTexture(WHITE_TEX)
    end
    if not f.LineBot then
        f.LineBot = f:CreateTexture(nil, "ARTWORK")
        f.LineBot:SetTexture(WHITE_TEX)
    end

    return f
end

function Divider:Update(f, props, currentMod, id)
    if not props then f:Hide() return end

    -- Resolve visual state
    local visualState
    local op = props.opacity
    if type(op) == 'table' then
        local isHidden = false
        if op.hidden then
            for hiddenMod in op.hidden:gmatch('[^,]+') do
                if currentMod == hiddenMod:match('^%s*(.-)%s*$') then
                    isHidden = true
                    break
                end
            end
        end

        if isHidden then
            visualState = 'hidden'
        elseif currentMod == op.focus then
            visualState = 'focus'
        elseif op.idle then
            visualState = 'idle'
        else
            visualState = 'hidden'
        end
    else
        visualState = (currentMod == op) and 'focus' or 'idle'
    end

    if visualState == 'hidden' then
        f:Hide()
        return
    end

    local rotationDeg = props.rotation or 90
    local rotationRad = math.rad(rotationDeg)
    local length      = props.breadth   or 130
    local spread      = props.depth     or 300
    local thickness   = props.thickness or 2
    local intensity   = (props.intensity or 18) / 100

    -- Alpha levels per state
    local lineAlpha, glowAlpha
    if visualState == 'focus' then
        lineAlpha = 1.0
        glowAlpha = 0.9
    else
        lineAlpha = 0.6
        glowAlpha = 0.3
    end

    f:ClearAllPoints()
    f:SetPoint(unpack(props.point))
    f:Show()

    local snapped = SnapToCardinal(rotationDeg)

    local r, g, b = db.Atlas.GetNormalizedCC()

    local goldR = math.min(1, 1.0  * 0.7 + r * 0.3)
    local goldG = math.min(1, 0.85 * 0.7 + g * 0.3)
    local goldB = math.min(1, 0.5  * 0.7 + b * 0.3)

    local fadeSize = length * 0.3
    local midSize  = length * 0.4

    if f.Line then f.Line:Hide() end

    if not f.LineTop then
        f.LineTop = f:CreateTexture(nil, "ARTWORK")
        f.LineTop:SetTexture(WHITE_TEX)
    end
    f.LineTop:Show()
    f.LineTop:ClearAllPoints()
    f.LineTop:SetPoint("BOTTOM", f, "CENTER", 0, midSize * 0.5)
    f.LineTop:SetSize(thickness, fadeSize)
    f.LineTop:SetGradientAlpha("VERTICAL",
        goldR, goldG, goldB, lineAlpha,
        goldR, goldG, goldB, 0
    )

    if not f.LineMid then
        f.LineMid = f:CreateTexture(nil, "ARTWORK")
        f.LineMid:SetTexture(WHITE_TEX)
    end
    f.LineMid:Show()
    f.LineMid:ClearAllPoints()
    f.LineMid:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.LineMid:SetSize(thickness, midSize)
    f.LineMid:SetVertexColor(goldR, goldG, goldB, lineAlpha)

    if not f.LineBot then
        f.LineBot = f:CreateTexture(nil, "ARTWORK")
        f.LineBot:SetTexture(WHITE_TEX)
    end
    f.LineBot:Show()
    f.LineBot:ClearAllPoints()
    f.LineBot:SetPoint("TOP", f, "CENTER", 0, -midSize * 0.5)
    f.LineBot:SetSize(thickness, fadeSize)
    f.LineBot:SetGradientAlpha("VERTICAL",
        goldR, goldG, goldB, 0,
        goldR, goldG, goldB, lineAlpha
    )

    local gradOrientation = (snapped == 90) and "HORIZONTAL" or "VERTICAL"
    local gradW = (snapped == 90) and spread or length
    local gradH = (snapped == 90) and length or spread

    local baseOffset     = 20
    local rotatedOffsetX = -baseOffset * math.sin(rotationRad)
    local rotatedOffsetY =  baseOffset * math.cos(rotationRad)

    if not f.Gradient then
        f.Gradient = f:CreateTexture(nil, "BACKGROUND")
        f.Gradient:SetTexture(GRADIENT_TEX)
        f.Gradient:SetBlendMode("ADD")
    end
    f.Gradient:ClearAllPoints()
    f.Gradient:SetSize(gradW, gradH)
    f.Gradient:SetPoint("CENTER", f, "CENTER", rotatedOffsetX, rotatedOffsetY)
    f.Gradient:SetGradientAlpha(
        gradOrientation,
        r, g, b, 0,
        r, g, b, glowAlpha * intensity
    )

    if not f.Gradient2 then
        f.Gradient2 = f:CreateTexture(nil, "BACKGROUND")
        f.Gradient2:SetTexture(GRADIENT_TEX)
        f.Gradient2:SetBlendMode("ADD")
    end
    f.Gradient2:ClearAllPoints()
    f.Gradient2:SetSize(gradW, gradH)
    f.Gradient2:SetPoint("CENTER", f, "CENTER", rotatedOffsetX, rotatedOffsetY)
    f.Gradient2:SetGradientAlpha(
        gradOrientation,
        r, g, b, glowAlpha * intensity,
        r, g, b, 0
    )
end