local NMT = NoMoreWrongTalents
NMT.UI = NMT.UI or {}

local UI = NMT.UI

local WARNING_W, WARNING_H = 380, 340
local WARNING_RAID_BOSS_EXTRA_H = 52
-- Options: label left of UIDropDownMenuTemplate on one row
local OPTIONS_LABEL_COL_W = 68
local OPTIONS_DD_ROW_H = 30
local OPTIONS_DD_BLOCK_H = OPTIONS_DD_ROW_H
local OPTIONS_DD_GAP_H = 6
local OPTIONS_TITLE_TO_DD = 16
-- Stacked: instance/boss name + talents row + gap + gear row + pad
local OPTIONS_STACK_ROW_H = OPTIONS_TITLE_TO_DD + OPTIONS_DD_BLOCK_H + OPTIONS_DD_GAP_H + OPTIONS_DD_BLOCK_H + 8
local OPTIONS_W = 780
-- UIPanelScrollFrameTemplate: vertical bar sits inside SetWidth; reserve or columns overflow the viewport.
local OPTIONS_SCROLLBAR_ALLOWANCE = 24
-- UIDropDownMenuTemplate draws wider than UIDropDownMenu_SetWidth (arrow/borders).
local OPTIONS_DROPDOWN_WIDTH_PAD = 10
-- Keep M+ grid inside backdrop inner edge (widening OPTIONS_W only scales columns — does not fix chrome overflow).
local OPTIONS_DUNGEON_GRID_RIGHT_TRIM = 8
local OPTIONS_COLS = 3
local OPTIONS_SIDE_MARGIN = 16
local OPTIONS_COL_GAP = 15
local OPTIONS_INTER_ROW_GAP = 5
-- Bump when column/scroll/dropdown layout changes (invalidates cached options frame).
local OPTIONS_LAYOUT_REV = 3

-- Options panel: label colors (RGB 0–1) for quicker scanning
local OPT_CLR_SECTION = { 1, 0.85, 0.45 } -- warm gold — M+ / Raids / Raid instance
local OPT_CLR_PLACE = { 0.7, 0.82, 1 } -- light blue — dungeon or boss name
local OPT_CLR_FIELD = { 0.5, 0.92, 0.72 } -- mint — Talents / Gear row labels

local warningFrame
local optionsFrame
local settingsCategory
local dungeonDropdowns = {}
local raidBossDropdowns = {}

local MINIMAP_ICON = "Interface\\AddOns\\NoMoreWrongTalents\\logo"

local minimapButton

local function UpdateMinimapPosition(angle)
	if not minimapButton then
		return
	end
	local rad = math.rad(angle)
	local x = math.cos(rad) * 105
	local y = math.sin(rad) * 105
	minimapButton:ClearAllPoints()
	minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

function UI:RefreshMinimapVisibility()
	if not minimapButton or not NoMoreWrongTalentsDB then
		return
	end
	if NoMoreWrongTalentsDB.hideMinimapButton then
		minimapButton:Hide()
	else
		minimapButton:Show()
	end
end

--- Minimap launcher (layout pattern from BlingtronApp).
function UI:EnsureMinimapButton()
	if minimapButton then
		UpdateMinimapPosition(NoMoreWrongTalentsDB.minimapAngle or 220)
		self:RefreshMinimapVisibility()
		return
	end

	minimapButton = CreateFrame("Button", "NoMoreWrongTalentsMinimapButton", Minimap)
	minimapButton:SetSize(32, 32)
	minimapButton:SetFrameStrata("MEDIUM")
	minimapButton:SetFrameLevel(8)
	minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
	minimapButton:SetMovable(true)
	minimapButton:RegisterForClicks("AnyUp")

	local overlay = minimapButton:CreateTexture(nil, "OVERLAY")
	overlay:SetSize(53, 53)
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetPoint("TOPLEFT")

	local icon = minimapButton:CreateTexture(nil, "BACKGROUND")
	icon:SetSize(20, 20)
	icon:SetTexture(MINIMAP_ICON)
	icon:SetPoint("CENTER", 1, 0)

	minimapButton:SetScript("OnDragStart", function(self)
		self:LockHighlight()
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local cx, cy = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			cx, cy = cx / scale, cy / scale
			local angle = math.deg(math.atan2(cy - my, cx - mx))
			NoMoreWrongTalentsDB.minimapAngle = angle
			UpdateMinimapPosition(angle)
		end)
	end)

	minimapButton:SetScript("OnDragStop", function(self)
		self:UnlockHighlight()
		self:SetScript("OnUpdate", nil)
	end)

	minimapButton:RegisterForDrag("LeftButton")

	minimapButton:SetScript("OnClick", function(_, button)
		if button == "LeftButton" then
			UI:ShowOptions()
		elseif button == "RightButton" then
			NMT:TryForceShowWarning()
		end
	end)

	minimapButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("NoMoreWrongTalents")
		GameTooltip:AddLine("|cffffffffLeft-click|r to open settings", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("|cffffffffRight-click|r to open check (raid / M+ when applicable)", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("|cffffffffDrag|r to move", 0.65, 0.65, 0.65)
		GameTooltip:Show()
	end)

	minimapButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	UpdateMinimapPosition(NoMoreWrongTalentsDB.minimapAngle or 220)
	self:RefreshMinimapVisibility()
end

local function ApplyWarningRaidLayout(f, useBossRow)
	if useBossRow then
		f:SetSize(WARNING_W, WARNING_H + WARNING_RAID_BOSS_EXTRA_H)
		f.bossSection:Show()
		f.curLab:SetPoint("TOPLEFT", 24, -(68 + WARNING_RAID_BOSS_EXTRA_H))
	else
		f:SetSize(WARNING_W, WARNING_H)
		f.bossSection:Hide()
		f.curLab:SetPoint("TOPLEFT", 24, -68)
	end
end

function UI:IsRaidWarningShown()
	return warningFrame and warningFrame:IsShown() and warningFrame.warningKind == "raid"
end

function UI:RefreshRaidWarningFromBossPick()
	local f = warningFrame
	if not f or not f:IsShown() or f.warningKind ~= "raid" then
		return
	end
	local raid = NMT:GetRaidContext()
	if not raid or raid.complete then
		return
	end
	local expectedID = NMT:GetExpectedRaidLoadout(raid.journalInstanceID, raid.bossIndex)
	local expectedGear = NMT:GetExpectedRaidGear(raid.journalInstanceID, raid.bossIndex)
	f.pendingExpectedConfigID = expectedID
	f.pendingExpectedGearSetID = expectedGear
	local currentID = NMT:GetSelectedLoadoutConfigID()
	local curGearID = NMT:GetEquippedEquipmentSetID()
	f.currentBuild:SetText(NMT:GetLoadoutDisplayName(currentID) or "—")
	f.expectedBuild:SetText(expectedID and (NMT:GetLoadoutDisplayName(expectedID) or "?") or "—")
	f.gearCurrent:SetText(NMT:GetEquipmentSetDisplayName(curGearID) or "—")
	f.gearExpected:SetText(expectedGear and (NMT:GetEquipmentSetDisplayName(expectedGear) or "?") or "—")
	local gname = raid.guessedBossName or "?"
	f.message:SetText(
		"Select the boss you intend to pull next (default: |cffffcc00"
			.. gname
			.. "|r). Compare talents and gear below; switch if something does not match."
	)
	local needTal = expectedID and (not currentID or currentID ~= expectedID)
	local needGear = expectedGear and not NMT:IsEquipmentSetEquipped(expectedGear)
	if needTal or needGear then
		if InCombatLockdown() then
			f.switchBtn:Disable()
			if f.status:GetText() == "" then
				f.status:SetText("|cffffcc00Leave combat to switch.|r")
			end
		else
			f.switchBtn:Enable()
		end
	else
		f.switchBtn:Disable()
	end
	UIDropDownMenu_SetText(f.bossDropdown, raid.bossName or "?")
end

local function CreateWarningFrame()
	local f = CreateFrame("Frame", "NoMoreWrongTalentsWarning", UIParent, "BackdropTemplate")
	f:SetSize(WARNING_W, WARNING_H)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true,
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 8, right = 8, top = 8, bottom = 8 },
	})

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText("|cffff9900Talents & gear|r")
	f.title = title

	local message = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	message:SetPoint("TOP", 0, -40)
	message:SetWidth(WARNING_W - 36)
	message:SetJustifyH("CENTER")
	f.message = message

	local bossSection = CreateFrame("Frame", nil, f)
	bossSection:SetSize(WARNING_W - 40, 46)
	bossSection:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -72)
	bossSection:Hide()
	f.bossSection = bossSection

	local bossLab = bossSection:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	bossLab:SetPoint("TOPLEFT", 0, 0)
	bossLab:SetText("Boss encounter:")
	bossLab:SetWidth(WARNING_W - 48)
	bossLab:SetJustifyH("LEFT")

	local bossDD = CreateFrame("Frame", nil, bossSection, "UIDropDownMenuTemplate")
	bossDD:SetPoint("TOPLEFT", bossSection, "TOPLEFT", -14, -18)
	UIDropDownMenu_SetWidth(bossDD, WARNING_W - 56)
	f.bossDropdown = bossDD

	local curLab = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	curLab:SetPoint("TOPLEFT", 24, -68)
	curLab:SetText("Talents (current):")
	f.curLab = curLab
	local cur = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	cur:SetPoint("TOPLEFT", curLab, "BOTTOMLEFT", 0, -2)
	cur:SetTextColor(1, 0.35, 0.35)
	cur:SetWidth(WARNING_W - 48)
	cur:SetJustifyH("LEFT")
	f.currentBuild = cur

	local expLab = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	expLab:SetPoint("TOPLEFT", cur, "BOTTOMLEFT", 0, -10)
	expLab:SetText("Talents (expected):")
	local exp = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	exp:SetPoint("TOPLEFT", expLab, "BOTTOMLEFT", 0, -2)
	exp:SetTextColor(0.35, 1, 0.45)
	exp:SetWidth(WARNING_W - 48)
	exp:SetJustifyH("LEFT")
	f.expectedBuild = exp

	local gearCurLab = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	gearCurLab:SetPoint("TOPLEFT", exp, "BOTTOMLEFT", 0, -12)
	gearCurLab:SetText("Gear (current):")
	f.gearCurLab = gearCurLab
	local gearCur = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	gearCur:SetPoint("TOPLEFT", gearCurLab, "BOTTOMLEFT", 0, -2)
	gearCur:SetTextColor(1, 0.35, 0.35)
	gearCur:SetWidth(WARNING_W - 48)
	gearCur:SetJustifyH("LEFT")
	f.gearCurrent = gearCur

	local gearExpLab = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	gearExpLab:SetPoint("TOPLEFT", gearCur, "BOTTOMLEFT", 0, -10)
	gearExpLab:SetText("Gear (expected):")
	local gearExp = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	gearExp:SetPoint("TOPLEFT", gearExpLab, "BOTTOMLEFT", 0, -2)
	gearExp:SetTextColor(0.35, 1, 0.45)
	gearExp:SetWidth(WARNING_W - 48)
	gearExp:SetJustifyH("LEFT")
	f.gearExpected = gearExp

	--- Equip expected gear set when needed; returns false on failure (talents are not applied).
	local function TryApplyExpectedGear()
		local gearID = f.pendingExpectedGearSetID
		if not gearID or NMT:IsEquipmentSetEquipped(gearID) then
			return true
		end
		local ok, gerr = NMT:ApplyGearSetByID(gearID)
		if not ok then
			local msg = gerr == "combat" and "Leave combat to change gear."
				or gerr == "failed" and "Could not equip that set."
				or "Gear sets unavailable."
			UI:SetSwitchStatus("|cffff3333" .. msg .. "|r")
			return false
		end
		return true
	end

	local switch = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	switch:SetSize(140, 28)
	switch:SetPoint("BOTTOMLEFT", 24, 16)
	switch:SetText("Switch")
	switch:SetScript("OnClick", function()
		if InCombatLockdown() then
			UI:SetSwitchStatus("|cffff3333Leave combat to switch.|r")
			return
		end
		local configID = f.pendingExpectedConfigID
		local needTal = configID and NMT:GetSelectedLoadoutConfigID() ~= configID
		local gearID = f.pendingExpectedGearSetID
		local needGear = gearID and not NMT:IsEquipmentSetEquipped(gearID)
		if not needTal and not needGear then
			return
		end
		TryApplyExpectedGear()
		if needTal then
			local result, err = NMT:ApplyLoadoutByConfigID(configID)
			local R = NMT._LoadConfigResult
			if result == R.Error then
				local msg = err == "not_found" and "Loadout not found." or "Could not switch talents."
				UI:SetSwitchStatus("|cffff3333" .. msg .. "|r")
				return
			elseif result == R.LoadInProgress then
				f.awaitingTraits = true
				UI:SetSwitchStatus("|cffffff00Applying talents…|r")
				return
			end
		end
		f:Hide()
	end)
	f.switchBtn = switch

	local dismiss = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	dismiss:SetSize(100, 28)
	dismiss:SetPoint("BOTTOMRIGHT", -24, 16)
	dismiss:SetText("Dismiss")
	dismiss:SetScript("OnClick", function()
		f:Hide()
	end)

	local status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	status:SetPoint("BOTTOM", 0, 48)
	status:SetWidth(WARNING_W - 40)
	status:SetJustifyH("CENTER")
	f.status = status

	f:SetScript("OnHide", function(self)
		self.awaitingTraits = false
		self.pendingExpectedConfigID = nil
		self.pendingExpectedGearSetID = nil
		self.warningKind = nil
		self._undefeatedBossList = nil
		if self.status then
			self.status:SetText("")
		end
	end)

	f:RegisterEvent("TRAIT_CONFIG_UPDATED")
	f:RegisterEvent("CONFIG_COMMIT_FAILED")
	f:RegisterEvent("PLAYER_REGEN_DISABLED")
	f:RegisterEvent("PLAYER_REGEN_ENABLED")
	f:SetScript("OnEvent", function(self, event)
		if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
			if self:IsShown() then
				if InCombatLockdown() then
					self.switchBtn:Disable()
					if self.status:GetText() == "" then
						self.status:SetText("|cffffcc00Leave combat to switch.|r")
					end
				else
					if self.warningKind == "raid" then
						UI:RefreshRaidWarningFromBossPick()
					else
						local needTal = self.pendingExpectedConfigID
							and NMT:GetSelectedLoadoutConfigID() ~= self.pendingExpectedConfigID
						local needGear = self.pendingExpectedGearSetID
							and not NMT:IsEquipmentSetEquipped(self.pendingExpectedGearSetID)
						if needTal or needGear then
							self.switchBtn:Enable()
						else
							self.switchBtn:Disable()
						end
					end
					if self.status:GetText() == "|cffffcc00Leave combat to switch.|r" then
						self.status:SetText("")
					end
				end
			end
			return
		end
		if not self:IsShown() or not self.awaitingTraits then return end
		if event == "TRAIT_CONFIG_UPDATED" then
			self.awaitingTraits = false
			self:Hide()
		elseif event == "CONFIG_COMMIT_FAILED" then
			self.awaitingTraits = false
			UI:SetSwitchStatus("|cffff3333Talent change failed.|r")
		end
	end)

	f:Hide()
	return f
end

function UI:SetSwitchStatus(text)
	if warningFrame and warningFrame.status then
		warningFrame.status:SetText(text or "")
	end
end

--- expectedConfigID / expectedGearSetID: what "Switch" applies (nil = none).
function UI:ShowWarning(
	currentBuildName,
	expectedBuildName,
	kind,
	ctx,
	expectedConfigID,
	currentGearName,
	expectedGearName,
	expectedGearSetID
)
	if not warningFrame then
		warningFrame = CreateWarningFrame()
	end
	local f = warningFrame
	f.warningKind = kind
	f.pendingExpectedConfigID = expectedConfigID
	f.pendingExpectedGearSetID = expectedGearSetID
	f.awaitingTraits = false
	f.status:SetText("")

	local isRaidBossPicker = kind == "raid" and ctx and ctx.undefeatedBosses and #ctx.undefeatedBosses > 0
	if isRaidBossPicker then
		f._undefeatedBossList = ctx.undefeatedBosses
		ApplyWarningRaidLayout(f, true)
		UIDropDownMenu_Initialize(f.bossDropdown, function(_, level)
			local list = f._undefeatedBossList or {}
			for _, e in ipairs(list) do
				local info = UIDropDownMenu_CreateInfo()
				info.text = e.name
				info.func = function()
					NMT:SetRaidBossPickForCurrentRaid(e.index)
					UIDropDownMenu_SetText(f.bossDropdown, e.name)
					CloseDropDownMenus()
					UI:RefreshRaidWarningFromBossPick()
				end
				local raidNow = NMT:GetRaidContext()
				info.checked = raidNow and raidNow.bossIndex == e.index
				UIDropDownMenu_AddButton(info, level)
			end
		end)
		UIDropDownMenu_SetText(f.bossDropdown, ctx.bossName or "?")
		UI:RefreshRaidWarningFromBossPick()
	else
		f._undefeatedBossList = nil
		ApplyWarningRaidLayout(f, false)
		local where
		if kind == "dungeon" and ctx and ctx.cmID then
			where = NMT:GetCmDungeonName(ctx.cmID) or "dungeon"
		elseif kind == "raid" and ctx then
			where = (ctx.instanceName or "raid") .. ": " .. (ctx.bossName or "?")
		else
			where = "instance"
		end
		f.message:SetText("Wrong talents or gear for |cffffcc00" .. where .. "|r.")

		f.currentBuild:SetText(currentBuildName or "—")
		f.expectedBuild:SetText(expectedBuildName or "—")
		f.gearCurrent:SetText(currentGearName or "—")
		f.gearExpected:SetText(expectedGearName or "—")

		local needTal = expectedConfigID and NMT:GetSelectedLoadoutConfigID() ~= expectedConfigID
		local needGear = expectedGearSetID and not NMT:IsEquipmentSetEquipped(expectedGearSetID)
		if needTal or needGear then
			if InCombatLockdown() then
				f.switchBtn:Disable()
				f.status:SetText("|cffffcc00Leave combat to switch.|r")
			else
				f.switchBtn:Enable()
			end
		else
			f.switchBtn:Disable()
		end
	end
	f:Show()
end

function UI:HideWarning()
	if warningFrame then
		warningFrame:Hide()
	end
end

--- @return container (holds label + dropdown)
local function CreateLoadoutDropdown(parent, x, y, width, labelText, getValue, setValue)
	local labelCol = OPTIONS_LABEL_COL_W
	local gap = 8
	local container = CreateFrame("Frame", nil, parent)
	container:SetSize(width, OPTIONS_DD_ROW_H)
	container:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

	local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("LEFT", container, "LEFT", 0, 0)
	label:SetWidth(labelCol)
	label:SetJustifyH("LEFT")
	label:SetJustifyV("MIDDLE")
	label:SetText(labelText)
	label:SetTextColor(OPT_CLR_FIELD[1], OPT_CLR_FIELD[2], OPT_CLR_FIELD[3])

	local dd = CreateFrame("Frame", nil, container, "UIDropDownMenuTemplate")
	dd:SetPoint("TOPLEFT", container, "TOPLEFT", labelCol + gap - 14, -10)
	UIDropDownMenu_SetWidth(dd, math.max(72, width - labelCol - gap - 12 - OPTIONS_DROPDOWN_WIDTH_PAD))

	local function Init(_, level)
		local info = UIDropDownMenu_CreateInfo()
		info.text = "-- None --"
		info.func = function()
			setValue(nil)
			UIDropDownMenu_SetText(dd, "-- None --")
			CloseDropDownMenus()
		end
		info.checked = (getValue() == nil)
		UIDropDownMenu_AddButton(info, level)

		for _, entry in ipairs(NMT:GetLoadoutNamesForSpec()) do
			info = UIDropDownMenu_CreateInfo()
			info.text = entry.name
			info.func = function()
				setValue(entry.id)
				UIDropDownMenu_SetText(dd, entry.name)
				CloseDropDownMenus()
			end
			info.checked = (getValue() == entry.id)
			UIDropDownMenu_AddButton(info, level)
		end
	end

	local function refreshLabel()
		local id = getValue()
		UIDropDownMenu_SetText(dd, id and (NMT:GetLoadoutDisplayName(id) or ("#" .. tostring(id))) or "-- None --")
	end

	UIDropDownMenu_Initialize(dd, Init)
	refreshLabel()
	dd:HookScript("OnShow", refreshLabel)
	container.dropdown = dd
	return container
end

local function CreateGearDropdown(parent, x, y, width, labelText, getValue, setValue)
	local labelCol = OPTIONS_LABEL_COL_W
	local gap = 8
	local container = CreateFrame("Frame", nil, parent)
	container:SetSize(width, OPTIONS_DD_ROW_H)
	container:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)

	local label = container:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	label:SetPoint("LEFT", container, "LEFT", 0, 0)
	label:SetWidth(labelCol)
	label:SetJustifyH("LEFT")
	label:SetJustifyV("MIDDLE")
	label:SetText(labelText)
	label:SetTextColor(OPT_CLR_FIELD[1], OPT_CLR_FIELD[2], OPT_CLR_FIELD[3])

	local dd = CreateFrame("Frame", nil, container, "UIDropDownMenuTemplate")
	dd:SetPoint("TOPLEFT", container, "TOPLEFT", labelCol + gap - 14, -10)
	UIDropDownMenu_SetWidth(dd, math.max(72, width - labelCol - gap - 12 - OPTIONS_DROPDOWN_WIDTH_PAD))

	local function Init(_, level)
		local info = UIDropDownMenu_CreateInfo()
		info.text = "-- None --"
		info.func = function()
			setValue(nil)
			UIDropDownMenu_SetText(dd, "-- None --")
			CloseDropDownMenus()
		end
		info.checked = (getValue() == nil)
		UIDropDownMenu_AddButton(info, level)

		if not NMT:CanUseEquipmentSets() then
			info = UIDropDownMenu_CreateInfo()
			info.text = "(Equipment sets unavailable)"
			info.disabled = true
			UIDropDownMenu_AddButton(info, level)
			return
		end

		for _, entry in ipairs(NMT:GetEquipmentSetList()) do
			info = UIDropDownMenu_CreateInfo()
			info.text = entry.name
			info.func = function()
				setValue(entry.id)
				UIDropDownMenu_SetText(dd, entry.name)
				CloseDropDownMenus()
			end
			info.checked = (getValue() == entry.id)
			UIDropDownMenu_AddButton(info, level)
		end
	end

	local function refreshLabel()
		local id = getValue()
		local txt = "-- None --"
		if id then
			txt = NMT:GetEquipmentSetDisplayName(id) or ("#" .. tostring(id))
		end
		UIDropDownMenu_SetText(dd, txt)
	end

	UIDropDownMenu_Initialize(dd, Init)
	refreshLabel()
	dd:HookScript("OnShow", refreshLabel)
	container.dropdown = dd
	return container
end

local function WipeRaidBossRows()
	for _, row in pairs(raidBossDropdowns) do
		if row.container then
			row.container:Hide()
			row.container:SetParent(nil)
		end
	end
	wipe(raidBossDropdowns)
end

local raidSectionAnchor
local optsRaidInstanceID

--- @param contentWidth total width available for columns (full window or scroll inner)
--- @param sideMargin optional horizontal inset (default OPTIONS_SIDE_MARGIN)
--- @param innerTrim extra px subtracted from usable width (right-side breathing room inside panel)
local function OptionsColumnLayout(contentWidth, sideMargin, innerTrim)
	sideMargin = sideMargin or OPTIONS_SIDE_MARGIN
	innerTrim = innerTrim or 0
	local usable = contentWidth - 2 * sideMargin - innerTrim
	local w = (usable - OPTIONS_COL_GAP * (OPTIONS_COLS - 1)) / OPTIONS_COLS
	return w, function(colIndexZeroBased)
		return sideMargin + colIndexZeroBased * (w + OPTIONS_COL_GAP)
	end
end

local function RefreshRaidBossArea()
	if not optionsFrame or not raidSectionAnchor then return end
	local inst = optsRaidInstanceID
	WipeRaidBossRows()
	if not inst then
		raidSectionAnchor:SetHeight(40)
		return
	end
	local scrollViewportW = OPTIONS_W - 48
	local raidContentW = scrollViewportW - OPTIONS_SCROLLBAR_ALLOWANCE
	local colW, colX = OptionsColumnLayout(raidContentW, 8, 0)
	local encounters = NMT:GetEncounterListForJournalInstance(inst, nil)
	local rowStride = OPTIONS_STACK_ROW_H + OPTIONS_INTER_ROW_GAP
	for idx, enc in ipairs(encounters) do
		local col = (idx - 1) % OPTIONS_COLS
		local row = math.floor((idx - 1) / OPTIONS_COLS)
		local x = colX(col)
		local y = -4 - row * rowStride
		local rowFrame = CreateFrame("Frame", nil, raidSectionAnchor)
		rowFrame:SetSize(colW, OPTIONS_STACK_ROW_H)
		rowFrame:SetPoint("TOPLEFT", raidSectionAnchor, "TOPLEFT", x, y)
		local encTitle = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		encTitle:SetPoint("TOPLEFT", 0, 0)
		encTitle:SetWidth(colW - 4)
		encTitle:SetJustifyH("LEFT")
		encTitle:SetText(enc.name)
		encTitle:SetTextColor(OPT_CLR_PLACE[1], OPT_CLR_PLACE[2], OPT_CLR_PLACE[3])
		local talentY = -OPTIONS_TITLE_TO_DD
		local gearY = talentY - OPTIONS_DD_BLOCK_H - OPTIONS_DD_GAP_H
		CreateLoadoutDropdown(rowFrame, 0, talentY, colW, "Talents", function()
			return NMT:GetExpectedRaidLoadout(inst, enc.index)
		end, function(configID)
			NMT:SetExpectedRaidLoadout(inst, enc.index, configID)
		end)
		CreateGearDropdown(rowFrame, 0, gearY, colW, "Gear", function()
			return NMT:GetExpectedRaidGear(inst, enc.index)
		end, function(setID)
			NMT:SetExpectedRaidGear(inst, enc.index, setID)
		end)
		raidBossDropdowns[#raidBossDropdowns + 1] = { container = rowFrame }
	end
	local nRows = math.max(1, math.ceil(#encounters / OPTIONS_COLS))
	raidSectionAnchor:SetWidth(raidContentW)
	raidSectionAnchor:SetHeight(math.max(60, 8 + nRows * rowStride))
end

function UI:CreateOrUpdateOptionsFrame()
	NMT:RefreshChallengeMapTable()
	local cmIDs = NMT:GetChallengeMapIDs() or {}
	local sorted = {}
	for _, id in ipairs(cmIDs) do
		sorted[#sorted + 1] = id
	end
	if #sorted == 0 then
		for _, id in pairs(cmIDs) do
			if type(id) == "number" then
				sorted[#sorted + 1] = id
			end
		end
	end
	if #sorted > 0 then
		table.sort(sorted)
	end

	local sig = ((#sorted > 0) and table.concat(sorted, ",") or "EMPTY")
		.. ":"
		.. tostring(OPTIONS_W)
		.. ":"
		.. tostring(OPTIONS_LAYOUT_REV)
	if optionsFrame and optionsFrame._cmSig == sig then
		return
	end

	if optionsFrame then
		optionsFrame:Hide()
		optionsFrame:SetParent(nil)
		optionsFrame = nil
		raidSectionAnchor = nil
	end
	wipe(dungeonDropdowns)

	local rows = math.max(1, math.ceil(math.max(#sorted, 1) / OPTIONS_COLS))
	local dunRowStride = OPTIONS_STACK_ROW_H + OPTIONS_INTER_ROW_GAP
	local raidHeaderH = 72
	local raidScrollMinH = 220
	-- Extra space between raid instance dropdown and boss scroll area
	local raidInstToScrollGap = 32
	local frameH = 100 + rows * dunRowStride + raidHeaderH + raidScrollMinH + 40 + raidInstToScrollGap

	local f = CreateFrame("Frame", "NoMoreWrongTalentsOptions", UIParent, "BackdropTemplate")
	f:SetSize(OPTIONS_W, frameH)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tileSize = 32,
		edgeSize = 32,
		insets = { left = 8, right = 8, top = 8, bottom = 8 },
	})
	f._cmSig = sig

	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -16)
	title:SetText("|cff33ff99NoMoreWrongTalents|r")
	f.title = title

	local specLine = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	specLine:SetPoint("TOP", 0, -42)
	specLine:SetText(NMT:GetCurrentSpecName())
	f.specLine = specLine

	local dunHeader = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	dunHeader:SetPoint("TOPLEFT", 20, -64)
	dunHeader:SetText("Mythic+ season dungeons (character-specific)")
	dunHeader:SetTextColor(OPT_CLR_SECTION[1], OPT_CLR_SECTION[2], OPT_CLR_SECTION[3])

	local colW, colX = OptionsColumnLayout(OPTIONS_W, nil, OPTIONS_DUNGEON_GRID_RIGHT_TRIM)
	local y0 = -88
	for i, cmID in ipairs(sorted) do
		local c = (i - 1) % OPTIONS_COLS
		local row = math.floor((i - 1) / OPTIONS_COLS)
		local x = colX(c)
		local y = y0 - row * dunRowStride
		local dname = NMT:GetCmDungeonName(cmID) or ("Map " .. tostring(cmID))
		local rowFrame = CreateFrame("Frame", nil, f)
		rowFrame:SetSize(colW, OPTIONS_STACK_ROW_H)
		rowFrame:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
		local rowTitle = rowFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		rowTitle:SetPoint("TOPLEFT", 0, 0)
		rowTitle:SetWidth(colW - 4)
		rowTitle:SetJustifyH("LEFT")
		rowTitle:SetText(dname)
		rowTitle:SetTextColor(OPT_CLR_PLACE[1], OPT_CLR_PLACE[2], OPT_CLR_PLACE[3])
		local talentY = -OPTIONS_TITLE_TO_DD
		local gearY = talentY - OPTIONS_DD_BLOCK_H - OPTIONS_DD_GAP_H
		local tcont = CreateLoadoutDropdown(rowFrame, 0, talentY, colW, "Talents", function()
			return NMT:GetExpectedDungeonLoadout(cmID)
		end, function(configID)
			NMT:SetExpectedDungeonLoadout(cmID, configID)
		end)
		local gcont = CreateGearDropdown(rowFrame, 0, gearY, colW, "Gear", function()
			return NMT:GetExpectedDungeonGear(cmID)
		end, function(setID)
			NMT:SetExpectedDungeonGear(cmID, setID)
		end)
		dungeonDropdowns[cmID] = { talent = tcont.dropdown, gear = gcont.dropdown }
	end

	if #sorted == 0 then
		local empty = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
		empty:SetPoint("TOPLEFT", 24, y0)
		empty:SetWidth(OPTIONS_W - 40)
		empty:SetJustifyH("LEFT")
		empty:SetText("No season dungeon list yet. Enter the world or open Mythic+ UI, then reopen settings.")
	end

	local raidY = y0 - rows * dunRowStride - 24
	local raidHdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	raidHdr:SetPoint("TOPLEFT", 20, raidY)
	raidHdr:SetText("Raids (per boss, all difficulties)")
	raidHdr:SetTextColor(OPT_CLR_SECTION[1], OPT_CLR_SECTION[2], OPT_CLR_SECTION[3])

	local raidInstLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	raidInstLabel:SetPoint("TOPLEFT", 24, raidY - 22)
	raidInstLabel:SetText("Raid instance")
	raidInstLabel:SetTextColor(OPT_CLR_SECTION[1], OPT_CLR_SECTION[2], OPT_CLR_SECTION[3])

	local raidInstDD = CreateFrame("Frame", nil, f, "UIDropDownMenuTemplate")
	raidInstDD:SetPoint("TOPLEFT", raidInstLabel, "BOTTOMLEFT", -16, -10)
	UIDropDownMenu_SetWidth(raidInstDD, 320)
	local raidList = NMT:GetJournalRaidInstancesForOptions()
	optsRaidInstanceID = raidList[1] and raidList[1].id or nil

	local function RaidInstInit()
		for _, r in ipairs(raidList) do
			local info = UIDropDownMenu_CreateInfo()
			info.text = r.name
			info.func = function()
				optsRaidInstanceID = r.id
				UIDropDownMenu_SetText(raidInstDD, r.name)
				CloseDropDownMenus()
				RefreshRaidBossArea()
			end
			info.checked = (optsRaidInstanceID == r.id)
			UIDropDownMenu_AddButton(info)
		end
	end
	UIDropDownMenu_Initialize(raidInstDD, RaidInstInit)
	if raidList[1] then
		UIDropDownMenu_SetText(raidInstDD, raidList[1].name)
	else
		UIDropDownMenu_SetText(raidInstDD, "-- None --")
	end

	local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, raidY - 58 - raidInstToScrollGap)
	scroll:SetSize(OPTIONS_W - 48, raidScrollMinH)
	raidSectionAnchor = CreateFrame("Frame", nil, scroll)
	raidSectionAnchor:SetSize(OPTIONS_W - 52, 100)
	scroll:SetScrollChild(raidSectionAnchor)

	f.raidInstDD = raidInstDD
	f.raidScroll = scroll

	local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
	closeBtn:SetSize(120, 28)
	closeBtn:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
	closeBtn:SetText("Close")
	closeBtn:SetScript("OnClick", function()
		f:Hide()
	end)

	local minimapRow = CreateFrame("Frame", nil, f)
	minimapRow:SetSize(260, 28)
	minimapRow:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)

	local minimapCheckbox = CreateFrame("CheckButton", nil, minimapRow, "UICheckButtonTemplate")
	minimapCheckbox:SetChecked(not NoMoreWrongTalentsDB.hideMinimapButton)
	minimapCheckbox:SetPoint("CENTER", minimapRow, "RIGHT", -14, 0)
	local minimapCbLabel = minimapCheckbox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	minimapCbLabel:SetText("Show minimap button")
	minimapCbLabel:SetJustifyH("RIGHT")
	minimapCbLabel:SetJustifyV("MIDDLE")
	minimapCbLabel:SetPoint("TOPRIGHT", minimapCheckbox, "TOPLEFT", -6, 0)
	minimapCbLabel:SetPoint("BOTTOMRIGHT", minimapCheckbox, "BOTTOMLEFT", -6, 0)
	minimapCheckbox:SetScript("OnClick", function(self)
		NoMoreWrongTalentsDB.hideMinimapButton = not self:GetChecked()
		UI:RefreshMinimapVisibility()
	end)
	f.minimapCheckbox = minimapCheckbox

	optionsFrame = f
	RefreshRaidBossArea()
	f:Hide()
end

function UI:ShowOptions()
	self:CreateOrUpdateOptionsFrame()
	if not optionsFrame then return end
	NMT:RefreshChallengeMapTable()
	optionsFrame.title:SetText("|cff33ff99NoMoreWrongTalents|r")
	optionsFrame.specLine:SetText(NMT:GetCurrentSpecName())
	if optionsFrame.minimapCheckbox then
		optionsFrame.minimapCheckbox:SetChecked(not NoMoreWrongTalentsDB.hideMinimapButton)
	end
	for cmID, pair in pairs(dungeonDropdowns) do
		if pair and pair.talent then
			local id = NMT:GetExpectedDungeonLoadout(cmID)
			UIDropDownMenu_SetText(
				pair.talent,
				id and (NMT:GetLoadoutDisplayName(id) or ("#" .. tostring(id))) or "-- None --"
			)
		end
		if pair and pair.gear then
			local gid = NMT:GetExpectedDungeonGear(cmID)
			UIDropDownMenu_SetText(
				pair.gear,
				gid and (NMT:GetEquipmentSetDisplayName(gid) or ("#" .. tostring(gid))) or "-- None --"
			)
		end
	end
	RefreshRaidBossArea()
	optionsFrame:Show()
end

function UI:RegisterOptionsPanel()
	if Settings and Settings.RegisterCanvasLayoutCategory then
		local panel = CreateFrame("Frame", "NoMoreWrongTalentsSettingsPanel", UIParent)
		panel.name = "NoMoreWrongTalents"

		local t = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		t:SetPoint("TOPLEFT", 16, -16)
		t:SetText("|cff33ff99NoMoreWrongTalents|r")

		local d = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		d:SetPoint("TOPLEFT", t, "BOTTOMLEFT", 0, -12)
		d:SetWidth(math.min(720, OPTIONS_W - 40))
		d:SetJustifyH("LEFT")
		d:SetText(
			"On entering a season Mythic+ dungeon or a raid, warns if your selected talent loadout or equipped gear set "
				.. "does not match what you configured for that place. "
				.. "In raids, a warning appears only when something differs from at least one boss you configured for your current map wing (bosses you have killed this instance visit are omitted); the default pick is the first of those in journal order. "
				.. "Open settings with |cffffcc00/nmwt|r or the minimap button."
		)

		local b = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		b:SetSize(160, 30)
		b:SetPoint("TOPLEFT", d, "BOTTOMLEFT", 0, -20)
		b:SetText("Open settings")
		b:SetScript("OnClick", function()
			UI:ShowOptions()
		end)

		local cat = Settings.RegisterCanvasLayoutCategory(panel, "NoMoreWrongTalents")
		Settings.RegisterAddOnCategory(cat)
		settingsCategory = cat
	end
end

function UI:OpenSettingsPanel()
	if settingsCategory and Settings.OpenToCategory then
		Settings.OpenToCategory(settingsCategory:GetID())
	end
end
