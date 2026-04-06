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
--- Per map-instance run (GetInstanceInfo instanceID): DungeonEncounterIDs killed with success this visit.
NMT._defeatedDungeonEncounterThisInstance = {}
--- "instanceType:instanceID" — when it changes we reset session defeated bosses (new instance / left instance).
NMT._instanceRunKey = nil
--- READY_CHECK (raid only) may show the talent warning at most once until cleared (zone / spec / kill / enter).
NMT._readyCheckTalentWarnShown = false
--- Raid: DungeonEncounterID we last wiped to this instance (nil after kill or new run).
NMT._lastWipeDungeonEncounterID = nil

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

--- Key: journalInstanceID .. ":" .. difficultyIDOr0 → encounter row list from EJ
local encounterListCache = {}

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

function NMT:ClearEncounterListCache()
	wipe(encounterListCache)
end

function NMT:ClearDefeatedEncountersThisInstance()
	wipe(self._defeatedDungeonEncounterThisInstance)
end

--- Build ordered list { { index, name, journalEncounterID, dungeonEncounterID }, ... }
--- Results are cached per (journalInstanceID, difficultyID); cleared on zone changes.
function NMT:GetEncounterListForJournalInstance(journalInstanceID, difficultyID)
	if not journalInstanceID or not EJ_SelectInstance then
		return {}
	end
	local cacheKey = tostring(journalInstanceID) .. ":" .. tostring(difficultyID or 0)
	local cached = encounterListCache[cacheKey]
	if cached then
		return cached
	end

	local prevDiff = EJ_GetDifficulty and EJ_GetDifficulty() or nil

	local ok = pcall(function()
		EJ_SelectInstance(journalInstanceID)
		if difficultyID and EJ_SetDifficulty and ejIsRaidDifficulty(difficultyID) then
			EJ_SetDifficulty(difficultyID)
		end
	end)
	if not ok then
		return {}
	end

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

	encounterListCache[cacheKey] = list
	return list
end

--- Keep only EJ rows whose journal encounter appears on the player's current uiMap (wing / floor).
--- If the API returns nothing or filtering removes every row, returns encounterRows unchanged.
function NMT:FilterEncounterRowsForPlayerMap(encounterRows)
	if not encounterRows or #encounterRows == 0 then
		return encounterRows or {}
	end
	if not C_Map or not C_Map.GetBestMapForUnit then
		return encounterRows
	end
	if not C_EncounterJournal or not C_EncounterJournal.GetEncountersOnMap then
		return encounterRows
	end
	local uiMapID = C_Map.GetBestMapForUnit("player")
	if not uiMapID or uiMapID == 0 then
		return encounterRows
	end
	local ok, onMap = pcall(C_EncounterJournal.GetEncountersOnMap, uiMapID)
	if not ok or type(onMap) ~= "table" or #onMap == 0 then
		return encounterRows
	end
	local allowed = {}
	for _, info in ipairs(onMap) do
		if type(info) == "table" then
			local eid = info.encounterID or info.journalEncounterID
			if eid then
				allowed[eid] = true
			end
		end
	end
	if not next(allowed) then
		return encounterRows
	end
	local out = {}
	for _, e in ipairs(encounterRows) do
		if e.journalEncounterID and allowed[e.journalEncounterID] then
			out[#out + 1] = e
		end
	end
	if #out == 0 then
		return encounterRows
	end
	return out
end

--- Drops rows whose dungeon encounter was killed this instance (ENCOUNTER_END success). DungeonEncounterID may be nil on some rows; those stay.
--- Result may be empty when every boss on this pass was defeated (valid).
function NMT:FilterEncounterRowsNotDefeatedThisInstance(encounterRows)
	if not encounterRows or #encounterRows == 0 then
		return encounterRows or {}
	end
	local def = self._defeatedDungeonEncounterThisInstance
	if not next(def) then
		return encounterRows
	end
	local out = {}
	for _, e in ipairs(encounterRows) do
		local dId = e.dungeonEncounterID
		if not dId or not def[dId] then
			out[#out + 1] = e
		end
	end
	return out
end

--- Boss rows from the EJ encounter list that have a saved expected loadout (current spec).
function NMT:FilterRaidBossesWithLoadout(journalInstanceID, encounterRows)
	if not journalInstanceID or not encounterRows then
		return {}
	end
	local out = {}
	for _, e in ipairs(encounterRows) do
		if self:GetExpectedRaidLoadout(journalInstanceID, e.index) then
			out[#out + 1] = e
		end
	end
	return out
end

--- Full raid encounter list for this journal, narrowed to bosses pinned on the current map, then loadout-only rows.
function NMT:GetRaidBossChoicesForContext(journalInstanceID, difficultyID)
	local encounters = self:GetEncounterListForJournalInstance(journalInstanceID, difficultyID)
	if #encounters == 0 then
		return {}
	end
	local onThisMap = self:FilterEncounterRowsForPlayerMap(encounters)
	local notKilled = self:FilterEncounterRowsNotDefeatedThisInstance(onThisMap)
	return self:FilterRaidBossesWithLoadout(journalInstanceID, notKilled)
end

function NMT:ClearRaidBossPick()
	local p = self._raidBossPick
	p.journalInstanceID = nil
	p.difficultyID = nil
	p.bossIndex = nil
end

function NMT:ClearReadyCheckTalentWarnGate()
	self._readyCheckTalentWarnShown = false
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

	local bossChoices = self:GetRaidBossChoicesForContext(journalInstanceID, difficultyID)
	if #bossChoices == 0 then
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

	local guessedIndex = bossChoices[1].index
	local guessedName = bossChoices[1].name
	local effectiveIndex = guessedIndex
	local effectiveName = guessedName
	local pick = self._raidBossPick
	if
		pick.journalInstanceID == journalInstanceID
		and pick.difficultyID == difficultyID
		and pick.bossIndex
	then
		for _, e in ipairs(bossChoices) do
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
		instanceName = instName,
		complete = false,
		undefeatedBosses = bossChoices,
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

--- Stable key for suppressing repeat raid prompts (nil if not in a journal-backed raid).
function NMT:GetRaidPromptKey(instanceType, difficultyID)
	if instanceType ~= "raid" then
		return nil
	end
	local jid = self:GetJournalInstanceForPlayerMap()
	if not jid then
		return nil
	end
	return tostring(jid) .. ":" .. tostring(difficultyID or 0)
end

function NMT:PresentRaidTalentWarning(raid, raidKey)
	if not self.UI or not self.UI.ShowWarning then
		return
	end
	local expectedID = self:GetExpectedRaidLoadout(raid.journalInstanceID, raid.bossIndex)
	local currentID = self:GetSelectedLoadoutConfigID()
	self.UI:ShowWarning(
		self:GetLoadoutDisplayName(currentID) or "?",
		expectedID and (self:GetLoadoutDisplayName(expectedID) or "?") or "Not set",
		"raid",
		raid,
		expectedID
	)
	if raidKey then
		self._raidPromptShownForKey = raidKey
	end
end

function NMT:PresentDungeonTalentWarning(expectedID, currentID, kind, ctx)
	if not self.UI or not self.UI.ShowWarning then
		return
	end
	self.UI:ShowWarning(
		self:GetLoadoutDisplayName(currentID) or "?",
		self:GetLoadoutDisplayName(expectedID) or "?",
		kind,
		ctx,
		expectedID
	)
end

--- Open the talent warning if context allows: raid with at least one configured boss choice, or M+ with loadout mismatch.
--- @return boolean whether the window was shown
function NMT:TryForceShowWarning()
	if not self._enabled or not self.UI or not self.UI.ShowWarning then
		return false
	end
	if self.UI.IsRaidWarningShown and self.UI:IsRaidWarningShown() then
		return false
	end
	local _, instanceType, difficultyID = GetInstanceInfo()
	if instanceType == "raid" then
		local raid = self:GetRaidContext()
		if not raid or raid.complete or not raid.undefeatedBosses or #raid.undefeatedBosses == 0 then
			return false
		end
		self:PresentRaidTalentWarning(raid, self:GetRaidPromptKey(instanceType, difficultyID))
		return true
	end
	local show, expectedID, currentID, kind, ctx = self:ShouldWarnForDungeon()
	if not show then
		return false
	end
	self:PresentDungeonTalentWarning(expectedID, currentID, kind, ctx)
	return true
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

--- True if at least one raid boss row with a saved loadout expects a different config than the current selection.
local function RaidConfiguredBossesMismatchCurrent(raid)
	local currentID = NMT:GetSelectedLoadoutConfigID()
	local jid = raid.journalInstanceID
	for _, e in ipairs(raid.undefeatedBosses) do
		local exp = NMT:GetExpectedRaidLoadout(jid, e.index)
		if exp and (not currentID or exp ~= currentID) then
			return true
		end
	end
	return false
end

--- @param ignoreRaidPromptKey boolean if true, show even when _raidPromptShownForKey would block (READY_CHECK once).
--- @return boolean whether the raid warning was shown
local function TryPresentRaidMismatchWarning(raid, raidKey, ignoreRaidPromptKey)
	if not NMT.UI or not NMT.UI.ShowWarning then
		return false
	end
	if not raid or raid.complete or not raid.undefeatedBosses or #raid.undefeatedBosses == 0 then
		return false
	end
	if not RaidConfiguredBossesMismatchCurrent(raid) then
		return false
	end
	if not ignoreRaidPromptKey then
		if not raidKey or raidKey == NMT._raidPromptShownForKey then
			return false
		end
	end
	NMT:PresentRaidTalentWarning(raid, raidKey)
	return true
end

local function DoInstanceCheck()
	if not NMT._enabled then
		return
	end
	if NMT.UI and NMT.UI.IsRaidWarningShown and NMT.UI:IsRaidWarningShown() then
		return
	end

	local _, instanceType, difficultyID, _, _, _, _, instanceRunId = GetInstanceInfo()
	instanceRunId = instanceRunId or 0
	local instanceRunKey = tostring(instanceType or "none") .. ":" .. tostring(instanceRunId)
	if instanceRunKey ~= NMT._instanceRunKey then
		NMT._instanceRunKey = instanceRunKey
		NMT:ClearDefeatedEncountersThisInstance()
		NMT:ClearRaidBossPick()
		NMT._raidPromptShownForKey = nil
		NMT._lastWipeDungeonEncounterID = nil
	end
	local raidKey = NMT:GetRaidPromptKey(instanceType, difficultyID)
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
			if not RaidConfiguredBossesMismatchCurrent(raid) then
				if raidKey then
					NMT._raidPromptShownForKey = nil
				end
			else
				TryPresentRaidMismatchWarning(raid, raidKey, false)
			end
		end
		return
	end

	local show, expectedID, currentID, kind, ctx = NMT:ShouldWarnForDungeon()
	if show and NMT.UI and NMT.UI.ShowWarning then
		NMT:PresentDungeonTalentWarning(expectedID, currentID, kind, ctx)
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
eventFrame:RegisterEvent("TRAIT_CONFIG_UPDATED")
eventFrame:RegisterEvent("READY_CHECK")

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
		NMT:ClearReadyCheckTalentWarnGate()
		NMT:ClearEncounterListCache()
		NMT:RefreshChallengeMapTable()
		ScheduleCheck()
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		NMT:ClearReadyCheckTalentWarnGate()
		NMT:ClearEncounterListCache()
		ScheduleCheck()
	elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
		NMT:ClearReadyCheckTalentWarnGate()
		ScheduleCheck()
	elseif event == "TRAIT_CONFIG_UPDATED" then
		ScheduleCheck()
	elseif event == "READY_CHECK" then
		if NMT._readyCheckTalentWarnShown or not NMT._enabled then
			return
		end
		if NMT.UI and NMT.UI.IsRaidWarningShown and NMT.UI:IsRaidWarningShown() then
			return
		end
		local _, instanceType, difficultyID = GetInstanceInfo()
		if instanceType ~= "raid" or not NMT.UI or not NMT.UI.ShowWarning then
			return
		end
		local raidKey = NMT:GetRaidPromptKey(instanceType, difficultyID)
		local raid = NMT:GetRaidContext()
		if TryPresentRaidMismatchWarning(raid, raidKey, true) then
			NMT._readyCheckTalentWarnShown = true
		end
	elseif event == "ENCOUNTER_END" then
		-- arg1 = DungeonEncounterID; ... = encounterName, difficultyID, groupSize, success (1 = kill)
		local dungeonEncounterID = arg1
		local success = select(4, ...)
		local _, instType = GetInstanceInfo()
		if instType == "raid" then
			local encId = (dungeonEncounterID and type(dungeonEncounterID) == "number" and dungeonEncounterID > 0)
				and dungeonEncounterID
				or nil

			if success == 1 or success == true then
				NMT._lastWipeDungeonEncounterID = nil
				NMT._raidPromptShownForKey = nil
				NMT:ClearReadyCheckTalentWarnGate()
				NMT:ClearRaidBossPick()
				if encId then
					NMT._defeatedDungeonEncounterThisInstance[encId] = true
				end
				ScheduleCheck()
			elseif encId then
				-- Wipe: remember boss; if we wiped a different encounter than last time, allow prompts again.
				if NMT._lastWipeDungeonEncounterID and NMT._lastWipeDungeonEncounterID ~= encId then
					NMT._raidPromptShownForKey = nil
					NMT:ClearReadyCheckTalentWarnGate()
					ScheduleCheck()
				end
				NMT._lastWipeDungeonEncounterID = encId
			end
		end
	end
end)

SLASH_NOMOREWRONGTALENTS1 = "/nmwt"
SlashCmdList["NOMOREWRONGTALENTS"] = function()
	if NMT.UI and NMT.UI.ShowOptions then
		NMT.UI:ShowOptions()
	end
end
