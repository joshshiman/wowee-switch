---------------------------------------------------------------
-- Item.lua: Popup menu for managing container items
---------------------------------------------------------------
local _, db = ...
local CPAPI = db.CPAPI
local Core, ItemMenu, ItemMenuButtonMixin = ConsolePort, ConsolePortItemMenu, {}
---------------------------------------------------------------
local INDEX_BAGS_COUNT = 2
local INDEX_BAGS_NOVAL = 9
---------------------------------------------------------------
local INDEX_INFO_ILINK = 2
local INDEX_INFO_STACK = 8
local INDEX_INFO_EQLOC = 9
local INDEX_INFO_CLASS = 12
---------------------------------------------------------------
local COMMAND_OPT_ICON = {
	Default   = [[Interface\QuestFrame\UI-Quest-BulletPoint]];
	Sell      = [[Interface\GossipFrame\BankerGossipIcon]];
	Split     = [[Interface\AddOns\ConsolePort\Textures\Interface\UI-Cursor-SizeLeft]];
	Equip     = [[Interface\AddOns\ConsolePort\Textures\Interface\transmogrifyGossipIcon]];
	Pickup    = [[Interface\AddOns\ConsolePort\Textures\Interface\openhand]];
	Delete    = [[Interface\Buttons\UI-GroupLoot-Pass-Up]];
	QuickBind = [[Interface\AddOns\ConsolePort\Textures\Interface\UI-AttributeButton-Encourage-Up]];
}

local INV_EQ_LOCATIONS = {
	INVTYPE_WEAPON  = {INVSLOT_MAINHAND, INVSLOT_OFFHAND};
	INVTYPE_FINGER  = {INVSLOT_FINGER1,  INVSLOT_FINGER2};
	INVTYPE_TRINKET = {INVSLOT_TRINKET1, INVSLOT_TRINKET2};
	INVTYPE_WEAPONMAINHAND = {INVSLOT_MAINHAND};
	INVTYPE_WEAPONOFFHAND  = {INVSLOT_OFFHAND};
	INVTYPE_BAG = { 20, 21, 22, 23 };
}
local QUICK_BIND_TYPES = {
    ["Consumable"] = true,
    ["Quest"]      = true,
    ["Weapon"]     = true,
}
---------------------------------------------------------------

local function IsItemEmpty(Item)
    if not Item.bagID or not Item.slotID then
        return true
    end

    -- Check if the bag/slot actually has an item
    local itemID = GetContainerItemID(Item.bagID, Item.slotID)
    if not itemID then
        return true
    end

    -- Optional: check if the item is locked or inaccessible
    local _, _, locked = GetContainerItemInfo(Item.bagID, Item.slotID)
    if locked then
        return true
    end

    return false
end

local function GetItemIcon(Item)
    -- Make sure bag/slot are set
    if not Item.bagID or not Item.slotID then
        return nil
    end

    local texture = select(1, GetContainerItemInfo(Item.bagID, Item.slotID))
    return texture
end

local function GetItemName(Item)
    -- Make sure bag/slot are set
    if not Item.bagID or not Item.slotID then
        return nil
    end

    -- Get the item link from the bag slot
    local itemLink = GetContainerItemLink(Item.bagID, Item.slotID)
    if itemLink then
        local itemName = select(1, GetItemInfo(itemLink))
        return itemName
    end

    return nil
end

local function GetItemLink(Item) 
    return GetContainerItemLink(Item.bagID, Item.slotID)
end

local BAG_ITEM_QUALITY_COLORS = {
    [0] = {r=0.5, g=0.5, b=0.5},  -- Poor
    [1] = {r=1, g=1, b=1},        -- Common
    [2] = {r=0.12, g=1, b=0},     -- Uncommon
    [3] = {r=0, g=0.44, b=0.87},  -- Rare
    [4] = {r=0.64, g=0.21, b=0.93},-- Epic
    [5] = {r=1, g=0.5, b=0},      -- Legendary
}

local function GetItemQualityColor(Item)
	local bagID = Item.bagID
	local slotID = Item.slotID

    if not Item.bagID or not Item.slotID then
		return 1,1,1
	end

    local link = GetContainerItemLink(bagID, slotID)
    if not link then return 1, 1, 1 end

    local _, _, quality = GetItemInfo(link)
    if not quality then quality = 1 end  -- default to common (white)

    local color = BAG_ITEM_QUALITY_COLORS[quality] or {r=1, g=1, b=1}
    return color.r, color.g, color.b
end

local function GetItemInventoryType(Item)
    -- Make sure bag/slot are set
    if not Item.bagID or not Item.slotID then
        return nil
    end

    -- Get the item link from the bag slot
    local itemLink = GetContainerItemLink(Item.bagID, Item.slotID)
    if itemLink then
        -- The 9th return from GetItemInfo is inventoryType
        local inventoryType = select(9, GetItemInfo(itemLink))
        return inventoryType
    end

    return nil
end


-- build once, only where multiple slots are possible we return a table
local INVSLOTMAP = {
    INVTYPE_HEAD            = GetInventorySlotInfo("HeadSlot"),
    INVTYPE_NECK            = GetInventorySlotInfo("NeckSlot"),
    INVTYPE_SHOULDER        = GetInventorySlotInfo("ShoulderSlot"),
    INVTYPE_BODY            = GetInventorySlotInfo("ShirtSlot"),
    INVTYPE_CHEST           = GetInventorySlotInfo("ChestSlot"),
    INVTYPE_ROBE            = GetInventorySlotInfo("ChestSlot"),
    INVTYPE_WAIST           = GetInventorySlotInfo("WaistSlot"),
    INVTYPE_LEGS            = GetInventorySlotInfo("LegsSlot"),
    INVTYPE_FEET            = GetInventorySlotInfo("FeetSlot"),
    INVTYPE_WRIST           = GetInventorySlotInfo("WristSlot"),
    INVTYPE_HAND            = GetInventorySlotInfo("HandsSlot"),
    INVTYPE_WEAPONMAINHAND  = GetInventorySlotInfo("MainHandSlot"),
    INVTYPE_WEAPONOFFHAND   = GetInventorySlotInfo("SecondaryHandSlot"),
    INVTYPE_2HWEAPON        = GetInventorySlotInfo("MainHandSlot"),
    INVTYPE_SHIELD          = GetInventorySlotInfo("SecondaryHandSlot"),
    INVTYPE_HOLDABLE        = GetInventorySlotInfo("SecondaryHandSlot"),
    INVTYPE_RANGED          = GetInventorySlotInfo("RangedSlot"),
    INVTYPE_RANGEDRIGHT     = GetInventorySlotInfo("RangedSlot"),
    INVTYPE_AMMO            = GetInventorySlotInfo("AmmoSlot"),
    INVTYPE_QUIVER          = GetInventorySlotInfo("AmmoSlot"),
    INVTYPE_THROWN          = GetInventorySlotInfo("RangedSlot"),
    INVTYPE_CLOAK           = GetInventorySlotInfo("BackSlot"),
    INVTYPE_TABARD          = GetInventorySlotInfo("TabardSlot"),
    INVTYPE_RELIC           = GetInventorySlotInfo("SecondaryHandSlot"),
}

local function ResolveEquipSlotsFromInvType(invType)
    if not invType then return nil end

    return INVSLOTMAP[invType]
end


function ItemMenu:SetItem(bagID, slotID)
	--self:SetBagAndSlot(bagID, slotID)
	self.bagID = bagID;
	self.slotID = slotID;

	--self:SetItemLocation(self)
  	self.itemLocation = self;

	if IsItemEmpty(self) then
		return self:Hide()
	end

	local count = self:GetCount()
	self.Count:SetText(count > 1 and ('x'..count) or '')
	--self.Icon:SetTexture(self:GetItemIcon())
	SetPortraitToTexture(self.Icon, GetItemIcon(self));
	self.Name:SetText(GetItemName(self))
	self.Name:SetTextColor(GetItemQualityColor(self))

	self:SetTooltip()
	self:SetCommands()
	self:FixSize()
	self:Show()
	self:RedirectCursor()
end

function ItemMenu:FixSize()
	local lastItem = self.itemPool:GetObjectByIndex(self.itemPool:GetNumActive())
	if lastItem then
		local height = self:GetHeight() or 0
		local bottom = self:GetBottom() or 0
		local anchor = lastItem:GetBottom() or 0
		self:SetHeight(height + bottom - anchor + 16)
	end
end

function ItemMenu:RedirectCursor()
	self.returnToNode = self.returnToNode or Core:GetCurrentNode()
	Core:SetCurrentNode(self.itemPool:GetObjectByIndex(1))
end

function ItemMenu:SetCommands()
	self.itemPool:ReleaseAll()

	if self:IsEquippableItem() then
		self:AddEquipCommands()
	end

	if self:IsQuickBindItem() and (self:IsUsableItem() or self:IsEquippableItem()) then
		self:AddQuickBindCommands()
	end

	if self:IsSellableItem() then
		self:AddCommand('Sell', 'Sell')
	end

	if self:IsSplittableItem() then
		self:AddCommand(db('TOOLTIP/STACK_SPLIT'), 'Split')
	end

	self:AddCommand(db('TOOLTIP/PICKUP'), 'Pickup')
	self:AddCommand(DELETE, 'Delete')
end

function ItemMenu:GetEquipCommand(invSlot, i, numSlots)
	local item = GetInventoryItemID('player', invSlot)
	local link = item and select(INDEX_INFO_ILINK, GetItemInfo(item))

	local replaceText = REPLACE or "Replace"
	local equipText   = EQUIPSET_EQUIP or "Equip"
	local slotAbbrText = SLOT_ABBR or "Slots";

	return {
		text =  link and (replaceText .. ' ' .. link)
				or numSlots > 1 and equipText .. (' (%s/%s %s)'):format(i, numSlots, slotAbbrText)
				or equipText;
		data = invSlot;
		free = not link;
	}
end


function ItemMenu:AddEquipCommands()
	local slots = INV_EQ_LOCATIONS[GetItemInventoryType(self)] or {ResolveEquipSlotsFromInvType(GetItemInventoryType(self))}
	local commands = {}
	local foundFree = false

	for i, slot in ipairs(slots) do
		local command = self:GetEquipCommand(slot, i, #slots)
		if ( command.free and not foundFree ) then
			foundFree = true
			tinsert(commands, 1, command)
		else
			tinsert(commands, command)
		end
	end
	-- add in order (make sure 'Equip' comes first)
	for i, command in ipairs(commands) do
		self:AddCommand(command.text, 'Equip', command.data)
	end
end

function ItemMenu:AddQuickBindCommands() 
	for i, preset in ipairs(ConsolePortUtility) do 
		self:AddCommand(format(db(i == 1 and 'TOOLTIP/ADD_TO_EXTRA' or 'TOOLTIP/ADD_TO_EXTRA_P'), preset.Name), 'QuickBind', i)
	end
end

function ItemMenu:AddCommand(text, command, data)
	local option = self.itemPool:Acquire()
	local anchor = self.itemPool:GetObjectByIndex(self.itemPool:GetNumActive()-1)
	
	option:SetCommand(text, command, data)
	option:SetPoint('TOPLEFT', anchor or self.Tooltip, 'BOTTOMLEFT', anchor and 0 or 8, anchor and 0 or -16)
	option:Show()
end

---------------------------------------------------------------
-- Tooltip hacks
---------------------------------------------------------------
function ItemMenu.Tooltip:GetTooltipStrings(index)
	local name = self:GetName()
	return _G[name .. 'TextLeft' .. index], _G[name .. 'TextRight' .. index]
end

function ItemMenu.Tooltip:Readjust()
	self:SetBackdrop(nil)
	self:SetWidth(340)
	self:GetTooltipStrings(1):Hide()
	local i, left, right = 2, self:GetTooltipStrings(2)
	while left and right do
		right:ClearAllPoints()
		right:SetPoint('LEFT', left, 'RIGHT', 0, 0)
		right:SetPoint('RIGHT', -32, 0)
		right:SetJustifyH('RIGHT')
		i = i + 1
		left, right = self:GetTooltipStrings(i)
	end
	self:GetParent():FixSize()
end

function ItemMenu.Tooltip:OnUpdate(elapsed)
	self.tooltipUpdate = self.tooltipUpdate + elapsed
	if self.tooltipUpdate > 0.25 then
		self:Readjust()
		self.tooltipUpdate = 0
	end
end

function ItemMenu:SetTooltip()
	local tooltip = self.Tooltip
	tooltip:SetOwner(self, 'ANCHOR_NONE')
	tooltip:SetBagItem(self.bagID, self.slotID)
	tooltip:Show()
	tooltip:ClearAllPoints()
	tooltip:SetPoint('TOPLEFT', 80, -16)
end

function ItemMenu:ClearTooltip()
	self.Tooltip:Hide()
end

ItemMenu.Tooltip.tooltipUpdate = 0
ItemMenu.Tooltip:HookScript('OnUpdate', ItemMenu.Tooltip.OnUpdate)
ItemMenu.Tooltip:HookScript('OnTooltipSetItem', ItemMenu.Tooltip.Readjust)

---------------------------------------------------------------
-- API
---------------------------------------------------------------
function ItemMenu:GetSpellID()
	return GetItemSpell(GetItemLink(self))
end

function ItemMenu:GetCount() 
	return select(INDEX_BAGS_COUNT, GetContainerItemInfo(self.bagID, self.slotID))
end

function ItemMenu:GetStackCount()
	return select(INDEX_INFO_STACK, GetItemInfo(GetItemLink(self)))
end

function ItemMenu:GetInventoryLocation()
	return select(INDEX_INFO_EQLOC, GetItemInfo(GetItemLink(self)))
end

function ItemMenu:HasNoValue()
	return select(INDEX_BAGS_NOVAL, GetContainerItemInfo(self.bagID, self.slotID))
end

local INVALID_QUICKBIND_INV_TYPES = {
    INVTYPE_HEAD, INVTYPE_NECK, INVTYPE_SHOULDER, INVTYPE_BODY,
    INVTYPE_CHEST, INVTYPE_ROBE, INVTYPE_WAIST, INVTYPE_LEGS,
    INVTYPE_FEET, INVTYPE_WRIST, INVTYPE_HAND, INVTYPE_AMMO,
    INVTYPE_QUIVER, INVTYPE_CLOAK, INVTYPE_TABARD, INVTYPE_BAG, INVTYPE_FINGER, INVTYPE_TRINKET
}

function ItemMenu:IsQuickBindItem()
    local link = GetItemLink(self)
    if not link then return false end

    local _, _, _, _, _, itemType, itemSubType, _, itemEquipLoc = GetItemInfo(link)

    for _, t in ipairs(INVALID_QUICKBIND_INV_TYPES) do
        if itemEquipLoc == t then
            return false
        end
    end

    if GetItemSpell(link) then
        return true
    end

    return false
end


function ItemMenu:IsSplittableItem()
	return self:GetStackCount() > 1 and self:GetCount() > 1
end

function ItemMenu:IsEquippableItem()
	return IsEquippableItem(GetItemLink(self))
end

function ItemMenu:IsUsableItem()
	return self:GetSpellID() and true
end

function ItemMenu:IsSellableItem()
	return self.merchantAvailable and not self:HasNoValue()
end

StaticPopupDialogs["CP_CONFIRM_DELETE_ITEM"] = {
    text = "Are you sure you want to delete this item?",
    button1 = "Yes",
    button2 = "No",
    OnAccept = function(self)
        if self.itemMenuRef then
            PickupContainerItem(self.itemMenuRef.bagID, self.itemMenuRef.slotID)
            DeleteCursorItem()
			self.itemMenuRef:Hide()
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

---------------------------------------------------------------
-- Commands
---------------------------------------------------------------
function ItemMenu:Pickup()
	PickupContainerItem(self.bagID, self.slotID)
	self:Hide()
end

function ItemMenu:Delete() 
    local popup = StaticPopup_Show("CP_CONFIRM_DELETE_ITEM")
	if(popup) then
		popup.itemMenuRef = self
	end
end

function ItemMenu:Equip(slot)
	if self:IsEquippableItem() then
		PickupContainerItem(self.bagID, self.slotID)
		EquipCursorItem(slot or ResolveEquipSlotsFromInvType(GetItemInventoryType(self)))
	end
	self:Hide()
end

function ItemMenu:Sell()
	-- confirm to ensure item isn't used
	if self:IsSellableItem() then
		UseContainerItem(self.bagID, self.slotID)
	end
	self:Hide()
end

function ItemMenu:Split()
	CPAPI:OpenStackSplitFrame(self:GetCount(), self, 'TOP', 'BOTTOM')
end

function ItemMenu:SplitStack(count)
	local bagID, slotID = self.bagID, self.slotID
	SplitContainerItem(bagID, slotID, count)
	self:Hide()
end

function ItemMenu:QuickBind(presetID)
	local link = GetItemLink(self)
	local _, itemID = strsplit(":", (strmatch(link or "", "item[%-?%d:]+")) or "")
	if GetItemSpell(link) then
		Core:AddUtilityAction("item", itemID, presetID) 
	end

	self:Hide()
end

---------------------------------------------------------------
-- Button mixin
---------------------------------------------------------------
function ItemMenuButtonMixin:OnClick()
	if self.command then
		self:GetParent()[self.command](self:GetParent(), self.data)
	end
end

function ItemMenuButtonMixin:SpecialClick()
	self:OnClick()
end

function ItemMenuButtonMixin:SetCommand(text, command, data)
	self.data = data
	self.command = command
	self.Icon:SetTexture(COMMAND_OPT_ICON[command] or COMMAND_OPT_ICON.Default)
	self:SetText(text)
end

---------------------------------------------------------------
-- Handlers and init
---------------------------------------------------------------
function ItemMenu:OnEvent(event, ...)
	if self[event] then
		self[event](self, ...)
	end
end

function ItemMenu:OnHide()
	if self.returnToNode then
		Core:SetCurrentNode(self.returnToNode)
		self.returnToNode = nil
	end
end

function ItemMenu:MERCHANT_SHOW()
	self.merchantAvailable = true
end

function ItemMenu:MERCHANT_CLOSED()
	self.merchantAvailable = false
end

function ItemMenu:PLAYER_REGEN_DISABLED()
	self:Hide()
end

function ItemMenu:BAG_UPDATE()
	if self:IsShown() then
		self:SetItem(self.bagID, self.slotID)
	end
end

---------------------------------------------------------------
for _, event in ipairs({
	'MERCHANT_SHOW',
	'MERCHANT_CLOSED',
	'BAG_UPDATE',
	'PLAYER_REGEN_DISABLED',
}) do ItemMenu:RegisterEvent(event) end

ItemMenu:SetScript('OnEvent', ItemMenu.OnEvent)
ItemMenu:SetScript('OnHide', ItemMenu.OnHide)
ItemMenu.itemPool = ConsolePortUI:CreateFramePool(
	'Button', ItemMenu,
	'ConsolePortPopupButtonTemplate',
	ItemMenuButtonMixin
);
Core:AddFrame(ItemMenu)