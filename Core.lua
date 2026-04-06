--[[
  NoMoreWrongTalents — instance context, Mythic+ map table, raid lockout / EJ helpers, talent loadouts.
]]

local ADDON_NAME = "NoMoreWrongTalents"
NoMoreWrongTalents = NoMoreWrongTalents or {}

local NMT = NoMoreWrongTalents
local CM = C_ChallengeMode
local MP = C_MythicPlus

-- Session-only: user-selected boss in raid warning (cleared on new raid instance or boss kill).
NMT._raidBossPick = {
	journalInstanceID = nil,
	difficultyID = nil,
	bossIndex = nil,
}
NMT._lastRaidInstanceKey = nil
--- After raid warning is shown for this key, hide repeats until boss kill or new raid instance.
NMT._raidPromptShownForKey = nil

-- LoadConfig result (Enum.LoadConfigResult in client; use numeric fallbacks)
local RESULT_ERROR = 0
local RESULT_NO_CHANGES = 1
local RESULT_LOAD_IN_PROGRESS = 2
local RESULT_READY = 3
if Enum and Enum.LoadConfigResult then
	RESULT_ERROR = Enum.LoadConfigResult.Error
	RESULT_NO_CHANGES = Enum.LoadConfigResult.NoChangesNecessary
	RESULT_LOAD_IN_PROGRESS = Enum.LoadConfigResult.LoadInProgress
	RESULT_READY = Enum.LoadConfigResult.Ready
end

local mapTableCache = nil
local mapTableCacheAt = 0
local MAP_TABLE_CACHE_TTL = 8

local function GetCurrentSpecID()
	if PlayerUtil and PlayerUtil.GetCurrentSpecID then
		return PlayerUtil.GetCurrentSpecID()
	end
	local idx = GetSpecialization and GetSpecialization(false, false)
	if not idx then return nil end
	return GetSpecializationInfo(idx)
end

local function InitDB()
	if not NoMoreWrongTalentsDB then
		NoMoreWrongTalentsDB = {}
	end
	if not NoMoreWrongTalentsDB.specs then
		NoMoreWrongTalentsDB.specs = {}
	end
	if NoMoreWrongTalentsDB.hideMinimapButton == nil then
		NoMoreWrongTalentsDB.hideMinimapButton = false
	end
	if NoMoreWrongTalentsDB.minimapAngle == nil then
		NoMoreWrongTalentsDB.minimapAngle = 220
	end
end

local function GetSpecTable(specID)
	InitDB()
	if not NoMoreWrongTalentsDB.specs[specID] then
		NoMoreWrongTalentsDB.specs[specID] = {
			dungeons = {},
			raids = {},
		}
	end
	local t = NoMoreWrongTalentsDB.specs[specID]
	t.dungeons = t.dungeons or {}
	t.raids = t.raids or {}
	return t
end

function NMT:RefreshChallengeMapTable()
	if MP and MP.RequestMapInfo then
		MP.RequestMapInfo()
	end
	mapTableCache = CM.GetMapTable and CM.GetMapTable() or nil
	mapTableCacheAt = GetTime()
	if not mapTableCache or #mapTableCache == 0 then
		mapTableCache = nil
	end
	return mapTableCache
end

function NMT:GetChallengeMapIDs()
	if not mapTableCache or (GetTime() - mapTableCacheAt) > MAP_TABLE_CACHE_TTL then
		self:RefreshChallengeMapTable()
	end
	return mapTableCache
end

function NMT:GetCmDungeonName(cmID)
	if not cmID then return nil end
	local name = CM.GetMapUIInfo(cmID)
	return name
end

function NMT:GetCmUiMapID(cmID)
	if not cmID then return nil end
	local _, _, _, _, _, mapID = CM.GetMapUIInfo(cmID)
	return mapID
end

--- Resolve season M+ map id for current 5-player instance (nil if not in a tracked dungeon).
--- GetInstanceInfo instanceID matches C_ChallengeMode.GetMapUIInfo(cmID) mapID (6th return); then name.
function NMT:GetCurrentDungeonCmID()
	local name, instanceType, _, _, _, _, _, instanceID = GetInstanceInfo()
	if instanceType ~= "party" then
		return nil
	end
	if CM.IsChallengeModeActive and CM.IsChallengeModeActive() and CM.GetActiveChallengeMapID then
		local active = CM.GetActiveChallengeMapID()
		if active and active > 0 then
			return active
		end
	end
	local cmIDs = self:GetChallengeMapIDs()
	if not cmIDs then
		return nil
	end
	local function eachCmID(fn)
		if #cmIDs > 0 then
			for _, cmID in ipairs(cmIDs) do
				fn(cmID)
			end
		else
			for _, cmID in pairs(cmIDs) do
				if type(cmID) == "number" then
					fn(cmID)
				end
			end
		end
	end
	local matchById, matchByName
	eachCmID(function(cmID)
		local mapName, _, _, _, _, mapID = CM.GetMapUIInfo(cmID)
		if instanceID and mapID and instanceID == mapID then
			matchById = matchById or cmID
		end
		if mapName and name and mapName == name then
			matchByName = matchByName or cmID
		end
	end)
	return matchById or matchByName
end

--- Instances listed in the Encounter Journal as raids (latest tiers) for the options UI.
function NMT:GetJournalRaidInstancesForOptions()
	local out = {}
	if not EJ_GetNumTiers or not EJ_SelectTier or not EJ_GetInstanceByIndex or not EJ_SelectInstance or not EJ_GetInstanceInfo then
		return out
	end
	local maxTier = EJ_GetNumTiers()
	local minTier = math.max(1, maxTier - 1)
	local seen = {}
	for tier = maxTier, minTier, -1 do
		pcall(EJ_SelectTier, tier)
		local idx = 1
		while true do
			local instanceID = EJ_GetInstanceByIndex(idx, true)
			if not instanceID then break end
			if not seen[instanceID] then
				pcall(EJ_SelectInstance, instanceID)
				local n = EJ_GetInstanceInfo()
				if n and instanceID then
					seen[instanceID] = true
					out[#out + 1] = { id = instanceID, name = n, tier = tier }
				end
			end
			idx = idx + 1
		end
	end
	table.sort(out, function(a, b)
		return a.name < b.name
	end)
	return out
end

--- @return journalInstanceID or nil
function NMT:GetJournalInstanceForPlayerMap()
	local uiMapID = C_Map.GetBestMapForUnit("player")
	if not uiMapID then return nil end
	if not EJ_GetInstanceForMap then return nil end
	return EJ_GetInstanceForMap(uiMapID)
end

local function ejIsRaidDifficulty(difficultyID)
	if not difficultyID or not EJ_IsValidInstanceDifficulty then return false end
	return EJ_IsValidInstanceDifficulty(difficultyID)
end

--- Build ordered list { { index, name, journalEncounterID, dungeonEncounterID }, ... }
function NMT:GetEncounterListForJournalInstance(journalInstanceID, difficultyID)
	if not journalInstanceID or not EJ_SelectInstance then return {} end
	local prevDiff = EJ_GetDifficulty and EJ_GetDifficulty() or nil

	local ok = pcall(function()
		EJ_SelectInstance(journalInstanceID)
		if difficultyID and EJ_SetDifficulty and ejIsRaidDifficulty(difficultyID) then
			EJ_SetDifficulty(difficultyID)
		end
	end)
	if not ok then return {} end

	local list = {}
	local i = 1
	local maxEncounters = 64
	while i <= maxEncounters do
		local encName, _, journalEncounterID, _, _, _, dungeonEncounterID =
			EJ_GetEncounterInfoByIndex(i, journalInstanceID)
		if not encName or not journalEncounterID then
			break
		end
		list[#list + 1] = {
			index = i,
			name = encName,
			journalEncounterID = journalEncounterID,
			dungeonEncounterID = dungeonEncounterID,
		}
		i = i + 1
	end

	if prevDiff and EJ_SetDifficulty and ejIsRaidDifficulty(prevDiff) then
		pcall(EJ_SetDifficulty, prevDiff)
	end

	return list
end

--- Find saved-instance index matching current raid (name + difficulty), or nil.
function NMT:FindSavedRaidLockoutIndex()
	local instName, instanceType, difficultyID = GetInstanceInfo()
	if instanceType ~= "raid" then return nil end
	local n = GetNumSavedInstances and GetNumSavedInstances() or 0
	for i = 1, n do
		local name, _, _, diff, locked, _, _, isRaid = GetSavedInstanceInfo(i)
		if isRaid and locked and name and instName then
			if diff == difficultyID then
				if name == instName then
					return i
				end
				-- loose match (suffixes / realm)
				if name:find(instName, 1, true) or instName:find(name, 1, true) then
					return i
				end
			end
		end
	end
	return nil
end

--- All bosses still alive in lockout order (EJ index + name). No lockout yet → full EJ list.
function NMT:GetUndefeatedRaidBosses(journalInstanceID, difficultyID)
	local encounters = self:GetEncounterListForJournalInstance(journalInstanceID, difficultyID)
	if #encounters == 0 then
		return {}
	end
	local savedIdx = self:FindSavedRaidLockoutIndex()
	local out = {}
	if not savedIdx then
		for _, enc in ipairs(encounters) do
			out[#out + 1] = { index = enc.index, name = enc.name }
		end
		return out
	end
	local _, _, _, _, _, _, _, _, _, _, numEncounters = GetSavedInstanceInfo(savedIdx)
	numEncounters = numEncounters or #encounters
	for _, enc in ipairs(encounters) do
		if enc.index > numEncounters then
			break
		end
		local encName, _, defeated = GetSavedInstanceEncounterInfo(savedIdx, enc.index)
		if encName and not defeated then
			out[#out + 1] = { index = enc.index, name = encName }
		end
	end
	return out
end

--- Undefeated bosses that have a non-nil expected loadout saved for this journal (current spec).
function NMT:FilterRaidBossesWithLoadout(journalInstanceID, undefeatedBosses)
	if not journalInstanceID or not undefeatedBosses then
		return {}
	end
	local out = {}
	for _, e in ipairs(undefeatedBosses) do
		if self:GetExpectedRaidLoadout(journalInstanceID, e.index) then
			out[#out + 1] = e
		end
	end
	return out
end

function NMT:ClearRaidBossPick()
	local p = self._raidBossPick
	p.journalInstanceID = nil
	p.difficultyID = nil
	p.bossIndex = nil
end

function NMT:SetRaidBossPickForCurrentRaid(bossIndex)
	local _, instanceType, difficultyID = GetInstanceInfo()
	if instanceType ~= "raid" or not bossIndex then
		return
	end
	local jid = self:GetJournalInstanceForPlayerMap()
	if not jid then
		return
	end
	local p = self._raidBossPick
	p.journalInstanceID = jid
	p.difficultyID = difficultyID
	p.bossIndex = bossIndex
end

function NMT:GetRaidContext()
	local instName, instanceType, difficultyID = GetInstanceInfo()
	if instanceType ~= "raid" then
		return nil
	end
	local journalInstanceID = self:GetJournalInstanceForPlayerMap()
	if not journalInstanceID then
		return nil
	end

	local encounters = self:GetEncounterListForJournalInstance(journalInstanceID, difficultyID)
	if #encounters == 0 then
		return nil
	end

	local undefeatedAll = self:GetUndefeatedRaidBosses(journalInstanceID, difficultyID)
	if #undefeatedAll == 0 then
		return {
			journalInstanceID = journalInstanceID,
			difficultyID = difficultyID,
			bossIndex = nil,
			bossName = nil,
			instanceName = instName,
			complete = true,
			undefeatedBosses = {},
		}
	end

	local undefeated = self:FilterRaidBossesWithLoadout(journalInstanceID, undefeatedAll)
	if #undefeated == 0 then
		return {
			journalInstanceID = journalInstanceID,
			difficultyID = difficultyID,
			bossIndex = nil,
			bossName = nil,
			instanceName = instName,
			complete = false,
			undefeatedBosses = {},
		}
	end

	local guessedIndex = undefeated[1].index
	local guessedName = undefeated[1].name
	local effectiveIndex = guessedIndex
	local effectiveName = guessedName
	local pick = self._raidBossPick
	if
		pick.journalInstanceID == journalInstanceID
		and pick.difficultyID == difficultyID
		and pick.bossIndex
	then
		for _, e in ipairs(undefeated) do
			if e.index == pick.bossIndex then
				effectiveIndex = e.index
				effectiveName = e.name
				break
			end
		end
	end

	return {
		journalInstanceID = journalInstanceID,
		difficultyID = difficultyID,
		bossIndex = effectiveIndex,
		bossName = effectiveName,
		guessedBossIndex = guessedIndex,
		guessedBossName = guessedName,
		instanceName = instName,
		complete = false,
		undefeatedBosses = undefeated,
	}
end

-- Talent loadouts -------------------------------------------------------------

function NMT:GetCurrentSpecName()
	local specID = GetCurrentSpecID()
	if not specID then return "Unknown" end
	local _, specName = GetSpecializationInfoByID(specID)
	return specName or "Unknown"
end

function NMT:GetLoadoutNamesForSpec(specID)
	specID = specID or GetCurrentSpecID()
	local builds = {}
	if not specID or not C_ClassTalents.GetConfigIDsBySpecID then return builds end
	local configIDs = C_ClassTalents.GetConfigIDsBySpecID(specID)
	if not configIDs then return builds end
	for _, configID in ipairs(configIDs) do
		local info = C_Traits.GetConfigInfo(configID)
		if info and info.name then
			builds[#builds + 1] = { id = configID, name = info.name }
		end
	end
	return builds
end

--- Saved loadout selection for this spec (loadout config id). Do not use C_ClassTalents.GetActiveConfigID():
--- that is the live trait tree config, not the selected loadout row.
function NMT:GetSelectedLoadoutConfigID()
	local specID = GetCurrentSpecID()
	if not specID or not C_ClassTalents.GetLastSelectedSavedConfigID then
		return nil
	end
	return C_ClassTalents.GetLastSelectedSavedConfigID(specID)
end

--- Display name for a loadout config ID (same enumeration as GetLoadoutNamesForSpec).
function NMT:GetLoadoutDisplayName(configID, specID)
	if not configID then return nil end
	specID = specID or GetCurrentSpecID()
	if specID and C_ClassTalents.GetConfigIDsBySpecID then
		local ids = C_ClassTalents.GetConfigIDsBySpecID(specID)
		if ids then
			for _, id in ipairs(ids) do
				if id == configID then
					local info = C_Traits.GetConfigInfo(id)
					return info and info.name or nil
				end
			end
		end
	end
	local info = C_Traits.GetConfigInfo(configID)
	return info and info.name or nil
end

function NMT:GetActiveLoadoutName()
	return self:GetLoadoutDisplayName(self:GetSelectedLoadoutConfigID())
end

function NMT:GetExpectedDungeonLoadout(cmID)
	local specID = GetCurrentSpecID()
	if not specID or not cmID then return nil end
	local v = GetSpecTable(specID).dungeons[cmID]
	return type(v) == "number" and v or nil
end

function NMT:SetExpectedDungeonLoadout(cmID, configID)
	local specID = GetCurrentSpecID()
	if not specID or not cmID then return end
	if configID == nil then
		GetSpecTable(specID).dungeons[cmID] = nil
	else
		GetSpecTable(specID).dungeons[cmID] = configID
	end
end

function NMT:GetExpectedRaidLoadout(journalInstanceID, bossIndex)
	local specID = GetCurrentSpecID()
	if not specID or not journalInstanceID or not bossIndex then return nil end
	local bosses = GetSpecTable(specID).raids[journalInstanceID]
	if not bosses then return nil end
	local v = bosses[bossIndex]
	return type(v) == "number" and v or nil
end

function NMT:SetExpectedRaidLoadout(journalInstanceID, bossIndex, configID)
	local specID = GetCurrentSpecID()
	if not specID or not journalInstanceID or not bossIndex then return end
	local spec = GetSpecTable(specID)
	spec.raids[journalInstanceID] = spec.raids[journalInstanceID] or {}
	if configID == nil then
		spec.raids[journalInstanceID][bossIndex] = nil
	else
		spec.raids[journalInstanceID][bossIndex] = configID
	end
end

--- @return expectedConfigID, contextKind, contextDetailTable
function NMT:GetExpectedForCurrentInstance()
	local cmID = self:GetCurrentDungeonCmID()
	if cmID then
		return self:GetExpectedDungeonLoadout(cmID), "dungeon", { cmID = cmID }
	end
	local raid = self:GetRaidContext()
	if raid and raid.bossIndex then
		local expected = self:GetExpectedRaidLoadout(raid.journalInstanceID, raid.bossIndex)
		return expected, "raid", raid
	end
	return nil, nil, nil
end

--- Mythic+ / dungeon: warn only when a saved expected loadout exists and differs from selection.
function NMT:ShouldWarnForDungeon()
	local cmID = self:GetCurrentDungeonCmID()
	if not cmID then
		return false
	end
	local expectedID = self:GetExpectedDungeonLoadout(cmID)
	if not expectedID then
		return false
	end
	local currentID = self:GetSelectedLoadoutConfigID()
	if not currentID or currentID == expectedID then
		return false
	end
	return true, expectedID, currentID, "dungeon", { cmID = cmID }
end

function NMT:ShouldWarnNow()
	return self:ShouldWarnForDungeon()
end

--- Same as: /run C_ClassTalents.LoadConfig(configID, true)
function NMT:ApplyLoadoutByConfigID(configID)
	if not configID then return RESULT_ERROR, "not_found" end
	if InCombatLockdown() then return RESULT_ERROR, "combat" end
	if not C_ClassTalents.LoadConfig then return RESULT_ERROR, "api" end
	local result, err = C_ClassTalents.LoadConfig(configID, true)
	return result, err
end

function NMT:IsLoadConfigBusy(result)
	return result == RESULT_LOAD_IN_PROGRESS
end

NMT._LoadConfigResult = {
	Error = RESULT_ERROR,
	NoChangesNecessary = RESULT_NO_CHANGES,
	LoadInProgress = RESULT_LOAD_IN_PROGRESS,
	Ready = RESULT_READY,
}

-- Events / bootstrap ----------------------------------------------------------

local eventFrame = CreateFrame("Frame")
local checkTimer

local function DoInstanceCheck()
	if not NMT._enabled then
		return
	end
	if NMT.UI and NMT.UI.IsRaidWarningShown and NMT.UI:IsRaidWarningShown() then
		return
	end

	local _, instanceType, difficultyID = GetInstanceInfo()
	local raidKey = nil
	if instanceType == "raid" then
		local jid = NMT:GetJournalInstanceForPlayerMap()
		if jid then
			raidKey = tostring(jid) .. ":" .. tostring(difficultyID or 0)
		end
	end
	if raidKey then
		if raidKey ~= NMT._lastRaidInstanceKey then
			NMT:ClearRaidBossPick()
			NMT._raidPromptShownForKey = nil
			NMT._lastRaidInstanceKey = raidKey
		end
	else
		NMT._lastRaidInstanceKey = nil
		NMT._raidPromptShownForKey = nil
	end

	if instanceType == "raid" and NMT.UI and NMT.UI.ShowWarning then
		local raid = NMT:GetRaidContext()
		if raid and not raid.complete and raid.undefeatedBosses and #raid.undefeatedBosses > 0 then
			if raidKey and raidKey ~= NMT._raidPromptShownForKey then
				local expectedID = NMT:GetExpectedRaidLoadout(raid.journalInstanceID, raid.bossIndex)
				local currentID = NMT:GetSelectedLoadoutConfigID()
				NMT.UI:ShowWarning(
					NMT:GetLoadoutDisplayName(currentID) or "?",
					expectedID and (NMT:GetLoadoutDisplayName(expectedID) or "?") or "Not set",
					"raid",
					raid,
					expectedID
				)
				NMT._raidPromptShownForKey = raidKey
			end
		end
		return
	end

	local show, expectedID, currentID, kind, ctx = NMT:ShouldWarnForDungeon()
	if show and NMT.UI and NMT.UI.ShowWarning then
		NMT.UI:ShowWarning(
			NMT:GetLoadoutDisplayName(currentID) or "?",
			NMT:GetLoadoutDisplayName(expectedID) or "?",
			kind,
			ctx,
			expectedID
		)
	end
end

local function ScheduleCheck()
	if checkTimer then
		checkTimer:Cancel()
		checkTimer = nil
	end
	checkTimer = C_Timer.NewTimer(0.5, function()
		checkTimer = nil
		DoInstanceCheck()
	end)
end

function NMT:SetEnabled(enabled)
	self._enabled = enabled ~= false
end

function NMT:IsEnabled()
	return self._enabled ~= false
end

eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
eventFrame:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
eventFrame:RegisterEvent("ENCOUNTER_END")

eventFrame:SetScript("OnEvent", function(_, event, arg1, ...)
	if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
		InitDB()
		NMT:SetEnabled(true)
		NMT:RefreshChallengeMapTable()
		if NMT.UI and NMT.UI.RegisterOptionsPanel then
			NMT.UI:RegisterOptionsPanel()
		end
		if NMT.UI and NMT.UI.EnsureMinimapButton then
			NMT.UI:EnsureMinimapButton()
		end
		print("|cff33ff99NoMoreWrongTalents|r loaded. |cffffcc00/nmwt|r — settings.")
	elseif event == "PLAYER_ENTERING_WORLD" then
		NMT:RefreshChallengeMapTable()
		ScheduleCheck()
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		ScheduleCheck()
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		ScheduleCheck()
	elseif event == "ENCOUNTER_END" then
		-- arg1 = encounterID; ... = name, difficultyID, raidSize, success
		local success = select(4, ...)
		local _, instType = GetInstanceInfo()
		if instType == "raid" and success then
			NMT:ClearRaidBossPick()
			NMT._raidPromptShownForKey = nil
		end
		ScheduleCheck()
	end
end)

SLASH_NOMOREWRONGTALENTS1 = "/nmwt"
SlashCmdList["NOMOREWRONGTALENTS"] = function()
	if NMT.UI and NMT.UI.ShowOptions then
		NMT.UI:ShowOptions()
	end
end
