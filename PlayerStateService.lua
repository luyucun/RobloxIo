--[[
脚本名字: PlayerStateService
脚本文件: PlayerStateService.lua
脚本类型: ModuleScript
Studio放置路径: ServerScriptService/Services/PlayerStateService
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ActorUtils = require(script.Parent:WaitForChild("ActorUtils"))

local function requireSharedModule(moduleName)
    local sharedFolder = ReplicatedStorage:FindFirstChild("Shared")
    if sharedFolder then
        local moduleInShared = sharedFolder:FindFirstChild(moduleName)
        if moduleInShared and moduleInShared:IsA("ModuleScript") then
            return require(moduleInShared)
        end
    end

    local moduleInRoot = ReplicatedStorage:FindFirstChild(moduleName)
    if moduleInRoot and moduleInRoot:IsA("ModuleScript") then
        return require(moduleInRoot)
    end

    error(string.format(
        "[PlayerStateService] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")
local WeaponTierConfig = requireSharedModule("WeaponTierConfig")
local PotionConfig = requireSharedModule("PotionConfig")

local PlayerStateService = {}

local OVERHEAD_HEALTH_BAR_NAME = "OverheadHealthBar"
local UI_FOLDER_NAME = "UI"
local LEADERSTATS_FOLDER_NAME = "leaderstats"
local LEADERSTAT_LEVEL_NAME = "Level"
local LEADERSTAT_REBIRTH_NAME = "Rebirth"
local LEGACY_LEADERSTAT_RESPAWN_COUNT_NAME = "RespawnCount"
local DEFAULT_CHARACTER_COLLISION_GROUP = "IOCharacters"
local DEFAULT_MONSTER_COLLISION_GROUP = "IOMonsters"
local FRIEND_EXPERIENCE_BONUS_PER_FRIEND = 0.2

PlayerStateService._statesByActorId = {}
PlayerStateService._playerStateSyncEvent = nil
PlayerStateService._requestStateSyncEvent = nil
PlayerStateService._levelUpFeedbackEvent = nil
PlayerStateService._requestStateConnection = nil
PlayerStateService._weaponService = nil
PlayerStateService._leaderboardService = nil
PlayerStateService._rebirthService = nil
PlayerStateService._arenaProgressService = nil
PlayerStateService._friendBonusRefreshToken = 0
PlayerStateService._friendBonusLoopToken = 0

local function getActorId(actor)
    local actorId = ActorUtils.GetActorId(actor)
    if actorId == "" then
        error("[PlayerStateService] 无法解析 ActorId。")
    end
    return actorId
end

local function buildWeaponLoadout(level)
    return WeaponTierConfig.ResolveLoadoutForLevel(level)
end

local function normalizeLevel(value)
    return math.clamp(math.floor(tonumber(value) or GameConfig.PLAYER.BaseLevel), 1, GameConfig.PLAYER.MaxSupportedLevel)
end

local function normalizePotionInventory(potions)
    local normalized = {}
    if type(potions) ~= "table" then
        return normalized
    end

    for potionId, count in pairs(potions) do
        local potion = PotionConfig.GetPotion(potionId)
        local resolvedCount = math.max(0, math.floor(tonumber(count) or 0))
        if potion and resolvedCount > 0 then
            normalized[tostring(potion.Id)] = resolvedCount
        end
    end
    return normalized
end

local function normalizeGroupRewards(groupRewards)
    local normalized = {}
    if type(groupRewards) ~= "table" then
        return normalized
    end

    for groupId, claimed in pairs(groupRewards) do
        local resolvedGroupId = math.floor(tonumber(groupId) or 0)
        if resolvedGroupId > 0 and claimed == true then
            normalized[tostring(resolvedGroupId)] = true
        end
    end
    return normalized
end

local function normalizeActivePotion(activePotion, fallbackPotionId)
    if type(activePotion) ~= "table" then
        return nil
    end

    local potion = PotionConfig.GetPotion(activePotion.Id or activePotion.id or activePotion.PotionId or activePotion.potionId or fallbackPotionId)
    if not potion then
        return nil
    end

    local expiresAt = tonumber(activePotion.ExpiresAt or activePotion.expiresAt) or 0
    if expiresAt <= os.time() then
        return nil
    end

    return {
        Id = potion.Id,
        StartedAt = tonumber(activePotion.StartedAt or activePotion.startedAt) or os.time(),
        ExpiresAt = expiresAt,
        ExperienceBonus = math.max(0, tonumber(activePotion.ExperienceBonus or activePotion.experienceBonus) or tonumber(potion.ExperienceBonus) or 0),
        MoveSpeedBonus = math.max(0, tonumber(activePotion.MoveSpeedBonus or activePotion.moveSpeedBonus) or tonumber(potion.MoveSpeedBonus) or 0),
        Source = tostring(activePotion.Source or activePotion.source or "Saved"),
    }
end

local function normalizeActivePotions(activePotions, legacyActivePotion)
    local normalized = {}

    if type(activePotions) == "table" then
        for potionId, activePotion in pairs(activePotions) do
            local normalizedPotion = normalizeActivePotion(activePotion, potionId)
            if normalizedPotion then
                normalized[tostring(normalizedPotion.Id)] = normalizedPotion
            end
        end
    end

    local normalizedLegacyPotion = normalizeActivePotion(legacyActivePotion)
    if normalizedLegacyPotion then
        local potionKey = tostring(normalizedLegacyPotion.Id)
        if not normalized[potionKey] then
            normalized[potionKey] = normalizedLegacyPotion
        end
    end

    return normalized
end

local function hasActivePotionEntries(activePotions)
    return type(activePotions) == "table" and next(activePotions) ~= nil
end

local function lerpColor(colorA, colorB, alpha)
    local t = math.clamp(tonumber(alpha) or 0, 0, 1)
    return Color3.new(
        colorA.R + ((colorB.R - colorA.R) * t),
        colorA.G + ((colorB.G - colorA.G) * t),
        colorA.B + ((colorB.B - colorA.B) * t)
    )
end

local function getHealthFillColor(healthRatio)
    local ratio = math.clamp(tonumber(healthRatio) or 0, 0, 1)
    local lowColor = Color3.fromRGB(255, 92, 92)
    local midColor = Color3.fromRGB(255, 204, 92)
    local highColor = Color3.fromRGB(90, 255, 138)

    if ratio >= 0.5 then
        return lerpColor(midColor, highColor, (ratio - 0.5) / 0.5)
    end

    return lerpColor(lowColor, midColor, ratio / 0.5)
end

local function ensureCollisionGroup(groupName)
    local didRegister = pcall(function()
        PhysicsService:RegisterCollisionGroup(groupName)
    end)
    if not didRegister then
        pcall(function()
            PhysicsService:CreateCollisionGroup(groupName)
        end)
    end
end

local function setCollisionRule(groupA, groupB, canCollide)
    pcall(function()
        PhysicsService:CollisionGroupSetCollidable(groupA, groupB, canCollide == true)
    end)
end

local function setPartCollisionGroup(basePart, groupName)
    local didSet = pcall(function()
        basePart.CollisionGroup = groupName
    end)
    if not didSet then
        pcall(function()
            PhysicsService:SetPartCollisionGroup(basePart, groupName)
        end)
    end
end

local function getCharacterCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.CharacterGroupName) or DEFAULT_CHARACTER_COLLISION_GROUP
end

local function getMonsterCollisionGroupName()
    return (GameConfig.COLLISION and GameConfig.COLLISION.MonsterGroupName) or DEFAULT_MONSTER_COLLISION_GROUP
end

local function configureCharacterCollision(character)
    if not character then
        return
    end

    local characterGroup = getCharacterCollisionGroupName()
    local monsterGroup = getMonsterCollisionGroupName()
    ensureCollisionGroup(characterGroup)
    ensureCollisionGroup(monsterGroup)
    setCollisionRule(characterGroup, monsterGroup, false)

    for _, descendant in ipairs(character:GetDescendants()) do
        if descendant:IsA("BasePart") then
            setPartCollisionGroup(descendant, characterGroup)
        end
    end

    character.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("BasePart") then
            setPartCollisionGroup(descendant, characterGroup)
        end
    end)
end

local function getOrCreateIntValue(parent, valueName)
    local valueObject = parent:FindFirstChild(valueName)
    if valueObject and not valueObject:IsA("IntValue") then
        valueObject:Destroy()
        valueObject = nil
    end

    if not valueObject then
        valueObject = Instance.new("IntValue")
        valueObject.Name = valueName
        valueObject.Value = 0
        valueObject.Parent = parent
    end

    return valueObject
end

function PlayerStateService:_ensureLeaderstats(player)
    if not ActorUtils.IsPlayer(player) then
        return nil
    end

    local leaderstats = player:FindFirstChild(LEADERSTATS_FOLDER_NAME)
    if leaderstats and not leaderstats:IsA("Folder") then
        leaderstats:Destroy()
        leaderstats = nil
    end

    if not leaderstats then
        leaderstats = Instance.new("Folder")
        leaderstats.Name = LEADERSTATS_FOLDER_NAME
        leaderstats.Parent = player
    end

    local legacyRespawnCount = leaderstats:FindFirstChild(LEGACY_LEADERSTAT_RESPAWN_COUNT_NAME)
    if legacyRespawnCount then
        legacyRespawnCount:Destroy()
    end

    getOrCreateIntValue(leaderstats, LEADERSTAT_LEVEL_NAME)
    getOrCreateIntValue(leaderstats, LEADERSTAT_REBIRTH_NAME)
    return leaderstats
end

function PlayerStateService:_syncLeaderstats(actor, state)
    if not ActorUtils.IsPlayer(actor) then
        return false
    end

    local leaderstats = self:_ensureLeaderstats(actor)
    if not leaderstats then
        return false
    end

    local levelValue = leaderstats:FindFirstChild(LEADERSTAT_LEVEL_NAME)
    if levelValue and levelValue:IsA("IntValue") then
        levelValue.Value = math.max(0, math.floor(tonumber(state.Level) or 0))
    end

    local rebirthValue = leaderstats:FindFirstChild(LEADERSTAT_REBIRTH_NAME)
    if rebirthValue and rebirthValue:IsA("IntValue") then
        rebirthValue.Value = math.max(0, math.floor(tonumber(state.Rebirth) or 0))
    end

    return true
end

function PlayerStateService:_applyLevelDerivedState(state)
    state.Level = normalizeLevel(state.Level)
    state.HighestLevelReached = math.max(normalizeLevel(state.HighestLevelReached or state.Level), state.Level)
    state.MaxHealth = GameConfig.GetMaxHealthForLevel(state.Level)
    state.NextLevelExperience = GameConfig.GetNextLevelExperience(state.Level)
    state.Rebirth = math.max(0, math.floor(tonumber(state.Rebirth or state.RespawnCount) or 0))
    state.RespawnCount = nil
    state.RebirthScore = math.max(0, math.floor(tonumber(state.RebirthScore) or 0))
    state.ExtraExperienceBonus = math.max(0, tonumber(state.ExtraExperienceBonus) or 0)
    state.FriendExperienceBonus = math.max(0, tonumber(state.FriendExperienceBonus) or 0)
    state.FriendCount = math.max(0, math.floor(tonumber(state.FriendCount) or 0))
    state.Diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0))
    state.Potions = normalizePotionInventory(state.Potions)
    state.GroupRewards = normalizeGroupRewards(state.GroupRewards)
    state.ActivePotions = normalizeActivePotions(state.ActivePotions, state.ActivePotion)
    state.ActivePotion = nil

    local loadout = buildWeaponLoadout(state.Level)
    state.DesiredWeaponTier = loadout.Tier
    state.DesiredWeaponTierIndex = loadout.TierIndex
    state.DesiredWeaponCount = loadout.Count
    state.DesiredWeaponIcon = loadout.IconImage or WeaponTierConfig.GetIconImageForTier(loadout.Tier)
    if state.IsInArena then
        state.WeaponTier = loadout.Tier
        state.WeaponTierIndex = loadout.TierIndex
        state.WeaponCount = loadout.Count
        state.WeaponIcon = state.DesiredWeaponIcon
    else
        state.WeaponTier = "None"
        state.WeaponTierIndex = 0
        state.WeaponCount = 0
        state.WeaponIcon = WeaponTierConfig.DefaultIconImage
    end

    state.CurrentHealth = math.clamp(tonumber(state.CurrentHealth) or state.MaxHealth, 0, state.MaxHealth)
end

function PlayerStateService:_createDefaultState(actor)
    local state = {
        ActorId = getActorId(actor),
        ActorKind = ActorUtils.GetActorKind(actor),
        ActorRef = actor,
        UserId = ActorUtils.GetCombatUserId(actor),
        IsInArena = false,
        Alive = true,
        Level = GameConfig.PLAYER.BaseLevel,
        HighestLevelReached = GameConfig.PLAYER.BaseLevel,
        Experience = GameConfig.PLAYER.BaseExperience,
        NextLevelExperience = GameConfig.GetNextLevelExperience(GameConfig.PLAYER.BaseLevel),
        CurrentHealth = GameConfig.PLAYER.BaseMaxHealth,
        MaxHealth = GameConfig.PLAYER.BaseMaxHealth,
        MoveSpeed = GameConfig.PLAYER.BaseMoveSpeed,
        WeaponTier = GameConfig.PLAYER.BaseWeaponTier,
        WeaponTierIndex = 1,
        WeaponCount = GameConfig.PLAYER.BaseWeaponCount,
        WeaponIcon = WeaponTierConfig.GetIconImageForTier(GameConfig.PLAYER.BaseWeaponTier),
        DesiredWeaponTier = GameConfig.PLAYER.BaseWeaponTier,
        DesiredWeaponTierIndex = 1,
        DesiredWeaponCount = GameConfig.PLAYER.BaseWeaponCount,
        DesiredWeaponIcon = WeaponTierConfig.GetIconImageForTier(GameConfig.PLAYER.BaseWeaponTier),
        KillCount = 0,
        TotalPlayerKills = 0,
        Rebirth = 0,
        RebirthScore = 0,
        ExtraExperienceBonus = 0,
        FriendExperienceBonus = 0,
        FriendCount = 0,
        Diamonds = 0,
        Potions = {},
        GroupRewards = {},
        ActivePotions = {},
        ActivePotion = nil,
        SessionStartedAt = os.time(),
        Buffs = {},
    }
    self:_applyLevelDerivedState(state)
    state.CurrentHealth = state.MaxHealth
    return state
end

function PlayerStateService:_getOverheadHealthBarTemplate()
    local uiFolder = ReplicatedStorage:FindFirstChild(UI_FOLDER_NAME)
    local template = uiFolder and uiFolder:FindFirstChild(OVERHEAD_HEALTH_BAR_NAME)
    if template and template:IsA("BillboardGui") then
        return template
    end
    return nil
end

function PlayerStateService:_createDefaultOverheadHealthBarTemplate()
    local billboard = Instance.new("BillboardGui")
    billboard.Name = OVERHEAD_HEALTH_BAR_NAME
    billboard.AlwaysOnTop = true
    billboard.LightInfluence = 0
    billboard.MaxDistance = 140
    billboard.Size = UDim2.fromOffset(148, 42)
    billboard.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)

    local root = Instance.new("Frame")
    root.Name = "Root"
    root.BackgroundTransparency = 1
    root.Size = UDim2.fromScale(1, 1)
    root.Parent = billboard

    local valueLabel = Instance.new("TextLabel")
    valueLabel.Name = "ValueLabel"
    valueLabel.BackgroundTransparency = 1
    valueLabel.Size = UDim2.new(1, 0, 0, 18)
    valueLabel.Font = Enum.Font.GothamBold
    valueLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
    valueLabel.TextSize = 13
    valueLabel.TextStrokeTransparency = 0.6
    valueLabel.Parent = root

    local barBackground = Instance.new("Frame")
    barBackground.Name = "BarBackground"
    barBackground.AnchorPoint = Vector2.new(0.5, 1)
    barBackground.Position = UDim2.new(0.5, 0, 1, 0)
    barBackground.Size = UDim2.new(1, 0, 0, 18)
    barBackground.BackgroundColor3 = Color3.fromRGB(24, 28, 33)
    barBackground.BorderSizePixel = 0
    barBackground.Parent = root

    local backgroundCorner = Instance.new("UICorner")
    backgroundCorner.CornerRadius = UDim.new(0, 7)
    backgroundCorner.Parent = barBackground

    local backgroundStroke = Instance.new("UIStroke")
    backgroundStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    backgroundStroke.Color = Color3.fromRGB(255, 255, 255)
    backgroundStroke.Transparency = 0.7
    backgroundStroke.Thickness = 1
    backgroundStroke.Parent = barBackground

    local fill = Instance.new("Frame")
    fill.Name = "Fill"
    fill.Size = UDim2.fromScale(1, 1)
    fill.BackgroundColor3 = Color3.fromRGB(90, 255, 138)
    fill.BorderSizePixel = 0
    fill.Parent = barBackground

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0, 7)
    fillCorner.Parent = fill

    return billboard
end

function PlayerStateService:_cloneOverheadHealthBar()
    local template = self:_getOverheadHealthBarTemplate()
    if template then
        return template:Clone()
    end
    return self:_createDefaultOverheadHealthBarTemplate()
end

function PlayerStateService:_configureHumanoidNameplate(actor)
    local humanoid = ActorUtils.GetHumanoid(actor)
    if not humanoid then
        return nil
    end

    humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
    pcall(function()
        humanoid.NameDisplayDistance = 0
    end)
    pcall(function()
        humanoid.HealthDisplayDistance = 0
    end)
    pcall(function()
        humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
    end)
    return humanoid
end

function PlayerStateService:_ensureOverheadHealthBar(actor)
    local character = ActorUtils.GetCharacter(actor)
    if not character then
        return nil
    end

    local head = character:FindFirstChild("Head")
    if not (head and head:IsA("BasePart") and self:_configureHumanoidNameplate(actor)) then
        return nil
    end

    local billboard = head:FindFirstChild(OVERHEAD_HEALTH_BAR_NAME)
    if billboard and not billboard:IsA("BillboardGui") then
        billboard:Destroy()
        billboard = nil
    end

    if billboard then
        billboard.Adornee = head
        return billboard
    end

    billboard = self:_cloneOverheadHealthBar()
    billboard.Name = OVERHEAD_HEALTH_BAR_NAME
    billboard.Adornee = head
    billboard.Parent = head

    return billboard
end

function PlayerStateService:UpdateOverheadHealthBar(actor)
    local state = self:_getOrCreateState(actor)
    local billboard = self:_ensureOverheadHealthBar(actor)
    if not billboard then
        return false
    end

    local root = billboard:FindFirstChild("Root")
    local valueLabel = root and root:FindFirstChild("ValueLabel")
    local barBackground = root and root:FindFirstChild("BarBackground")
    local fill = barBackground and barBackground:FindFirstChild("Fill")
    if not (valueLabel and valueLabel:IsA("TextLabel") and fill and fill:IsA("Frame")) then
        return false
    end

    local maxHealth = math.max(1, math.floor(tonumber(state.MaxHealth) or 1))
    local currentHealth = math.clamp(math.floor(tonumber(state.CurrentHealth) or maxHealth), 0, maxHealth)
    local healthRatio = currentHealth / maxHealth

    fill.Size = UDim2.fromScale(healthRatio, 1)
    fill.BackgroundColor3 = getHealthFillColor(healthRatio)
    valueLabel.Text = string.format("%d / %d", currentHealth, maxHealth)
    billboard.Enabled = state.Alive == true and state.IsInArena == true
    return true
end

function PlayerStateService:_getOrCreateState(actor)
    local actorId = getActorId(actor)
    local state = self._statesByActorId[actorId]
    if state then
        state.ActorRef = actor
        if ActorUtils.IsBot(actor) then
            actor.State = state
        end
        return state
    end

    state = self:_createDefaultState(actor)
    self._statesByActorId[actorId] = state
    if ActorUtils.IsBot(actor) then
        actor.State = state
    end
    self:_syncLeaderstats(actor, state)
    return state
end

function PlayerStateService:Init(dependencies)
    self._statesByActorId = {}
    self._friendBonusRefreshToken = 0
    self._friendBonusLoopToken += 1
    local friendBonusLoopToken = self._friendBonusLoopToken
    self._weaponService = dependencies and dependencies.WeaponService or nil
    self._leaderboardService = dependencies and dependencies.LeaderboardService or nil
    self._rebirthService = dependencies and dependencies.RebirthService or nil
    self._arenaProgressService = dependencies and dependencies.ArenaProgressService or nil
    self._playerStateSyncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("PlayerStateSync") or nil
    self._requestStateSyncEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("RequestPlayerStateSync") or nil
    self._levelUpFeedbackEvent = dependencies and dependencies.RemoteEventService and dependencies.RemoteEventService:GetEvent("LevelUpFeedback") or nil

    if self._requestStateConnection then
        self._requestStateConnection:Disconnect()
        self._requestStateConnection = nil
    end

    if self._requestStateSyncEvent then
        self._requestStateConnection = self._requestStateSyncEvent.OnServerEvent:Connect(function(player)
            self:PushState(player)
        end)
    end

    task.spawn(function()
        while self._friendBonusLoopToken == friendBonusLoopToken do
            task.wait(15)
            if self._friendBonusLoopToken ~= friendBonusLoopToken then
                break
            end
            self:RefreshFriendExperienceBonuses()
        end
    end)
end

function PlayerStateService:BindSystems(dependencies)
    self._weaponService = dependencies and dependencies.WeaponService or self._weaponService
    self._leaderboardService = dependencies and dependencies.LeaderboardService or self._leaderboardService
    self._rebirthService = dependencies and dependencies.RebirthService or self._rebirthService
    self._arenaProgressService = dependencies and dependencies.ArenaProgressService or self._arenaProgressService
end

function PlayerStateService:_markArenaProgressDirty()
    if self._arenaProgressService and self._arenaProgressService.MarkDirty then
        self._arenaProgressService:MarkDirty()
    end
end

function PlayerStateService:RegisterBot(botActor)
    self:_getOrCreateState(botActor)
end

function PlayerStateService:UnregisterBot(botActor)
    local actorId = getActorId(botActor)
    self._statesByActorId[actorId] = nil
    if ActorUtils.IsBot(botActor) then
        botActor.State = nil
    end
end

function PlayerStateService:OnPlayerAdded(player)
    local state = self:_getOrCreateState(player)
    self:_syncLeaderstats(player, state)
    self:PushState(player)
    self:QueueFriendBonusRefresh()
end

function PlayerStateService:BuildStatePayload(actor)
    local state = self:_getOrCreateState(actor)
    local activePotion = self:GetActivePotion(actor)
    local activePotions = self:GetActivePotions(actor)
    local potionExperienceBonus = self:GetPotionExperienceBonus(actor)
    local potionMoveSpeedBonus = self:GetPotionMoveSpeedBonus(actor)
    local friendExperienceBonus = math.max(0, tonumber(state.FriendExperienceBonus) or 0)
    local friendCount = math.max(0, math.floor(tonumber(state.FriendCount) or 0))
    return {
        level = state.Level,
        highestLevelReached = state.HighestLevelReached,
        experience = state.Experience,
        nextLevelExperience = state.NextLevelExperience,
        currentHealth = state.CurrentHealth,
        maxHealth = state.MaxHealth,
        moveSpeed = state.MoveSpeed * self:GetMoveSpeedMultiplier(actor),
        weaponTier = state.WeaponTier,
        weaponTierIndex = state.WeaponTierIndex,
        weaponCount = state.WeaponCount,
        weaponIcon = state.WeaponIcon,
        desiredWeaponTier = state.DesiredWeaponTier,
        desiredWeaponTierIndex = state.DesiredWeaponTierIndex,
        desiredWeaponCount = state.DesiredWeaponCount,
        desiredWeaponIcon = state.DesiredWeaponIcon,
        killCount = state.KillCount,
        totalPlayerKills = state.TotalPlayerKills,
        rebirth = state.Rebirth,
        rebirthScore = state.RebirthScore,
        nextRebirthScore = GameConfig.GetRequiredRebirthScore(state.Rebirth),
        rebirthExperienceBonus = GameConfig.GetRebirthExperienceBonus(state.Rebirth),
        diamonds = state.Diamonds,
        potions = state.Potions,
        groupRewards = state.GroupRewards,
        activePotions = activePotions,
        activePotion = activePotion,
        potionExperienceBonus = potionExperienceBonus,
        potionMoveSpeedBonus = potionMoveSpeedBonus,
        friendExperienceBonus = friendExperienceBonus,
        friendBonusPercent = math.floor((friendExperienceBonus * 100) + 0.5),
        friendCount = friendCount,
        totalExperienceMultiplier = self:GetExperienceMultiplier(actor),
        isInArena = state.IsInArena,
        alive = state.Alive,
        buffs = state.Buffs,
        timestamp = os.clock(),
    }
end

function PlayerStateService:PushState(actor)
    if not ActorUtils.IsPlayer(actor) then
        return
    end
    if not (actor and actor.Parent) then
        return
    end
    if not self._playerStateSyncEvent then
        return
    end

    self._playerStateSyncEvent:FireClient(actor, self:BuildStatePayload(actor))
end

function PlayerStateService:_fireLevelUpFeedback(actor, previousLevel, newLevel)
    if not (self._levelUpFeedbackEvent and ActorUtils.IsPlayer(actor) and actor.Parent) then
        return
    end

    local state = self:_getOrCreateState(actor)
    self._levelUpFeedbackEvent:FireClient(actor, {
        previousLevel = previousLevel,
        newLevel = newLevel,
        maxHealth = state.MaxHealth,
        weaponTier = state.WeaponTier,
        weaponTierIndex = state.WeaponTierIndex,
        weaponCount = state.WeaponCount,
        weaponIcon = state.WeaponIcon,
        desiredWeaponTier = state.DesiredWeaponTier,
        desiredWeaponTierIndex = state.DesiredWeaponTierIndex,
        desiredWeaponCount = state.DesiredWeaponCount,
        desiredWeaponIcon = state.DesiredWeaponIcon,
        timestamp = os.clock(),
    })
end

function PlayerStateService:GetHumanoid(actor)
    return ActorUtils.GetHumanoid(actor)
end

function PlayerStateService:SyncHumanoidHealth(actor)
    local state = self:_getOrCreateState(actor)
    local humanoid = ActorUtils.GetHumanoid(actor)
    if not humanoid then
        return false
    end

    state.CurrentHealth = math.clamp(state.CurrentHealth, 0, state.MaxHealth)
    humanoid.MaxHealth = state.MaxHealth
    humanoid.Health = math.min(state.CurrentHealth, humanoid.MaxHealth)
    self:UpdateOverheadHealthBar(actor)
    return true
end

function PlayerStateService:SyncHumanoidMovement(actor)
    local state = self:_getOrCreateState(actor)
    local humanoid = ActorUtils.GetHumanoid(actor)
    if not humanoid then
        return false
    end

    humanoid.WalkSpeed = state.MoveSpeed * self:GetMoveSpeedMultiplier(actor)
    return true
end

function PlayerStateService:SyncCharacterState(actor)
    local didSyncHealth = self:SyncHumanoidHealth(actor)
    local didSyncMovement = self:SyncHumanoidMovement(actor)
    return didSyncHealth or didSyncMovement
end

function PlayerStateService:SetWeaponState(actor, weaponTier, weaponCount)
    local state = self:_getOrCreateState(actor)
    state.WeaponTier = tostring(weaponTier or "None")
    state.WeaponTierIndex = WeaponTierConfig.GetTierIndex(state.WeaponTier)
    state.WeaponCount = math.max(0, math.floor(tonumber(weaponCount) or 0))
    state.WeaponIcon = WeaponTierConfig.GetIconImageForTier(state.WeaponTier)
end

function PlayerStateService:SetAlive(actor, isAlive)
    self:_getOrCreateState(actor).Alive = isAlive == true
end

function PlayerStateService:AddKillCount(actor, amount)
    local state = self:_getOrCreateState(actor)
    local delta = math.max(0, math.floor(tonumber(amount) or 0))
    if delta <= 0 then
        return state.KillCount, state.TotalPlayerKills
    end
    state.KillCount += delta
    state.TotalPlayerKills += delta
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state.KillCount, state.TotalPlayerKills
end

function PlayerStateService:SetTotalPlayerKills(actor, count)
    local state = self:_getOrCreateState(actor)
    state.TotalPlayerKills = math.max(0, math.floor(tonumber(count) or 0))
    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    return state.TotalPlayerKills
end

function PlayerStateService:AddDiamonds(actor, amount)
    local state = self:_getOrCreateState(actor)
    local delta = math.floor(tonumber(amount) or 0)
    if delta == 0 then
        return state.Diamonds
    end

    state.Diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0) + delta)
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state.Diamonds
end

function PlayerStateService:_addDiamondsWithoutPush(actor, amount)
    local state = self:_getOrCreateState(actor)
    local delta = math.floor(tonumber(amount) or 0)
    if delta == 0 then
        return state.Diamonds
    end

    state.Diamonds = math.max(0, math.floor(tonumber(state.Diamonds) or 0) + delta)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state.Diamonds
end

function PlayerStateService:AwardPlayerKillReward(killer, target)
    if not (ActorUtils.IsPlayer(killer) and ActorUtils.IsPlayer(target)) then
        return false
    end
    if ActorUtils.IsSameActor(killer, target) then
        return false
    end

    self:AddKillCount(killer, 1)
    self:_addDiamondsWithoutPush(killer, GameConfig.ECONOMY.PlayerKillDiamondReward)
    return true
end

function PlayerStateService:GetRequiredRebirthScore(actor)
    local state = self:_getOrCreateState(actor)
    return GameConfig.GetRequiredRebirthScore(state.Rebirth)
end

function PlayerStateService:GetExperienceMultiplier(actor)
    local state = self:_getOrCreateState(actor)
    local rebirthBonus = GameConfig.GetRebirthExperienceBonus(state.Rebirth)
    local extraBonus = math.max(0, tonumber(state.ExtraExperienceBonus) or 0)
    local potionBonus = self:GetPotionExperienceBonus(actor)
    local friendBonus = math.max(0, tonumber(state.FriendExperienceBonus) or 0)
    return math.max(1, 1 + rebirthBonus + extraBonus + potionBonus + friendBonus)
end

function PlayerStateService:GetActivePotions(actor)
    local state = self:_getOrCreateState(actor)
    local normalized = normalizeActivePotions(state.ActivePotions, state.ActivePotion)
    state.ActivePotions = normalized
    state.ActivePotion = nil
    return normalized
end

function PlayerStateService:GetActivePotion(actor)
    local activePotions = self:GetActivePotions(actor)
    local firstPotion = nil
    for _, activePotion in pairs(activePotions) do
        if not firstPotion or activePotion.ExpiresAt < firstPotion.ExpiresAt then
            firstPotion = activePotion
        end
    end
    return firstPotion
end

function PlayerStateService:GetPotionExperienceBonus(actor)
    local totalBonus = 0
    for _, activePotion in pairs(self:GetActivePotions(actor)) do
        totalBonus += math.max(0, tonumber(activePotion.ExperienceBonus) or 0)
    end
    return totalBonus
end

function PlayerStateService:GetPotionMoveSpeedBonus(actor)
    local totalBonus = 0
    for _, activePotion in pairs(self:GetActivePotions(actor)) do
        totalBonus += math.max(0, tonumber(activePotion.MoveSpeedBonus) or 0)
    end
    return totalBonus
end

function PlayerStateService:ClearExpiredPotions(actor)
    local state = self:_getOrCreateState(actor)
    if not (hasActivePotionEntries(state.ActivePotions) or state.ActivePotion ~= nil) then
        return false
    end

    local changed = state.ActivePotion ~= nil
    local normalized = {}

    if type(state.ActivePotions) == "table" then
        for potionId, activePotion in pairs(state.ActivePotions) do
            local normalizedPotion = normalizeActivePotion(activePotion, potionId)
            if normalizedPotion then
                normalized[tostring(normalizedPotion.Id)] = normalizedPotion
            else
                changed = true
            end
        end
    end

    local normalizedLegacyPotion = normalizeActivePotion(state.ActivePotion)
    if normalizedLegacyPotion then
        local potionKey = tostring(normalizedLegacyPotion.Id)
        if not normalized[potionKey] then
            normalized[potionKey] = normalizedLegacyPotion
        end
    end

    state.ActivePotions = normalized
    state.ActivePotion = nil
    return changed
end

function PlayerStateService:ClearExpiredPotion(actor)
    return self:ClearExpiredPotions(actor)
end

function PlayerStateService:GetMoveSpeedMultiplier(actor)
    local potionMoveSpeedBonus = self:GetPotionMoveSpeedBonus(actor)
    return math.max(0.1, 1 + potionMoveSpeedBonus)
end

function PlayerStateService:_countServerFriends(player)
    if not ActorUtils.IsPlayer(player) then
        return 0
    end

    local friendCount = 0
    for _, otherPlayer in ipairs(Players:GetPlayers()) do
        if otherPlayer ~= player and otherPlayer.Parent then
            local success, isFriend = pcall(function()
                return player:IsFriendsWith(otherPlayer.UserId)
            end)
            if success and isFriend == true then
                friendCount += 1
            end
        end
    end
    return friendCount
end

function PlayerStateService:RefreshFriendExperienceBonuses()
    for _, player in ipairs(Players:GetPlayers()) do
        if player and player.Parent then
            local state = self:_getOrCreateState(player)
            local friendCount = self:_countServerFriends(player)
            local friendBonus = friendCount * FRIEND_EXPERIENCE_BONUS_PER_FRIEND
            local previousCount = math.max(0, math.floor(tonumber(state.FriendCount) or 0))
            local previousBonus = math.max(0, tonumber(state.FriendExperienceBonus) or 0)

            if previousCount ~= friendCount or math.abs(previousBonus - friendBonus) > 0.0001 then
                state.FriendCount = friendCount
                state.FriendExperienceBonus = friendBonus
                self:PushState(player)
            end
        end
    end
end

function PlayerStateService:QueueFriendBonusRefresh(delaySeconds)
    self._friendBonusRefreshToken += 1
    local token = self._friendBonusRefreshToken
    local delayTime = math.max(0, tonumber(delaySeconds) or 1)

    task.delay(delayTime, function()
        if token ~= self._friendBonusRefreshToken then
            return
        end
        self:RefreshFriendExperienceBonuses()
    end)
end

function PlayerStateService:AddRebirthScore(actor, amount)
    local state = self:_getOrCreateState(actor)
    local delta = math.max(0, math.floor(tonumber(amount) or 0))
    if delta <= 0 then
        return state.RebirthScore or 0
    end

    state.RebirthScore = math.max(0, math.floor(tonumber(state.RebirthScore) or 0)) + delta
    self:PushState(actor)
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state.RebirthScore
end

function PlayerStateService:CanRebirth(actor)
    local state = self:_getOrCreateState(actor)
    return math.max(0, tonumber(state.RebirthScore) or 0) >= GameConfig.GetRequiredRebirthScore(state.Rebirth)
end

function PlayerStateService:SetRebirth(actor, count)
    local state = self:_getOrCreateState(actor)
    state.Rebirth = math.max(0, math.floor(tonumber(count) or 0))
    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state.Rebirth
end

function PlayerStateService:AddRebirth(actor, amount)
    local state = self:_getOrCreateState(actor)
    local delta = math.max(0, math.floor(tonumber(amount) or 0))
    state.Rebirth = math.max(0, math.floor(tonumber(state.Rebirth) or 0))
    state.Rebirth += delta
    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state.Rebirth
end

function PlayerStateService:SetRebirthData(actor, rebirth, rebirthScore, highestLevelReached, savedProgress)
    local state = self:_getOrCreateState(actor)
    state.Rebirth = math.max(0, math.floor(tonumber(rebirth) or 0))
    state.RebirthScore = math.max(0, math.floor(tonumber(rebirthScore) or 0))
    state.HighestLevelReached = math.max(
        normalizeLevel(highestLevelReached),
        normalizeLevel(state.HighestLevelReached or state.Level),
        state.Level
    )
    if type(savedProgress) == "table" then
        state.Diamonds = math.max(0, math.floor(tonumber(savedProgress.diamonds or savedProgress.Diamonds) or 0))
        state.Potions = normalizePotionInventory(savedProgress.potions or savedProgress.Potions)
        state.GroupRewards = normalizeGroupRewards(savedProgress.groupRewards or savedProgress.GroupRewards)
        state.ActivePotions = normalizeActivePotions(savedProgress.activePotions or savedProgress.ActivePotions, savedProgress.activePotion or savedProgress.ActivePotion)
        state.ActivePotion = nil
    end
    self:_syncLeaderstats(actor, state)
    self:SyncHumanoidMovement(actor)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state
end

function PlayerStateService:ApplyRebirth(actor, shouldClearScore)
    local state = self:_getOrCreateState(actor)
    state.Rebirth = math.max(0, math.floor(tonumber(state.Rebirth) or 0)) + 1
    if shouldClearScore == true then
        state.RebirthScore = 0
    else
        state.RebirthScore = math.max(0, math.floor(tonumber(state.RebirthScore) or 0))
    end
    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    return state
end

function PlayerStateService:GetGroupRewards(actor)
    local state = self:_getOrCreateState(actor)
    state.GroupRewards = normalizeGroupRewards(state.GroupRewards)
    return state.GroupRewards
end

function PlayerStateService:HasGroupReward(actor, groupId)
    local rewards = self:GetGroupRewards(actor)
    return rewards[tostring(math.floor(tonumber(groupId) or 0))] == true
end

function PlayerStateService:MarkGroupReward(actor, groupId)
    local state = self:_getOrCreateState(actor)
    state.GroupRewards = normalizeGroupRewards(state.GroupRewards)
    local resolvedGroupId = math.floor(tonumber(groupId) or 0)
    if resolvedGroupId <= 0 then
        return false
    end
    local key = tostring(resolvedGroupId)
    if state.GroupRewards[key] == true then
        return false
    end
    state.GroupRewards[key] = true
    return true
end

function PlayerStateService:SetRespawnCount(actor, count)
    return self:SetRebirth(actor, count)
end

function PlayerStateService:AddRespawnCount(actor, amount)
    return self:AddRebirth(actor, amount)
end

function PlayerStateService:_addExperience(actor, amount, requireActiveInArena)
    local state = self:_getOrCreateState(actor)
    if requireActiveInArena and not (state.Alive and state.IsInArena) then
        return false, state.Level, state.Experience
    end

    local gained = math.max(0, math.floor(tonumber(amount) or 0))
    if gained <= 0 then
        return false, state.Level, state.Experience
    end

    local previousLevel = state.Level
    state.Experience += gained

    while state.Level < GameConfig.PLAYER.MaxSupportedLevel and state.Experience >= GameConfig.GetNextLevelExperience(state.Level) do
        local needed = GameConfig.GetNextLevelExperience(state.Level)
        state.Experience -= needed
        state.Level += 1
    end

    if state.Level >= GameConfig.PLAYER.MaxSupportedLevel then
        state.Level = GameConfig.PLAYER.MaxSupportedLevel
        state.Experience = math.min(state.Experience, GameConfig.GetNextLevelExperience(state.Level))
    end

    local didLevelUp = state.Level > previousLevel
    local previousMaxHealth = state.MaxHealth
    if didLevelUp then
        self:_applyLevelDerivedState(state)
        local healthGain = math.max(0, state.MaxHealth - previousMaxHealth)
        state.CurrentHealth = math.min(state.MaxHealth, state.CurrentHealth + healthGain)
        self:SyncCharacterState(actor)
        if self._weaponService then
            self._weaponService:RebuildWeaponsForActor(actor)
        end
        if self._rebirthService then
            self._rebirthService:MarkDirty(actor)
        end
        self:_fireLevelUpFeedback(actor, previousLevel, state.Level)
    else
        state.NextLevelExperience = GameConfig.GetNextLevelExperience(state.Level)
    end

    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
        if didLevelUp and self._leaderboardService.BroadcastNow then
            self._leaderboardService:BroadcastNow()
        end
    end
    if didLevelUp then
        self:_markArenaProgressDirty()
    end
    return didLevelUp, state.Level, state.Experience
end

function PlayerStateService:AddExperience(actor, amount)
    return self:_addExperience(actor, amount, true)
end

function PlayerStateService:AddAuthorizedExperience(actor, amount)
    return self:_addExperience(actor, amount, false)
end

function PlayerStateService:AddExperienceWithMultiplier(actor, amount)
    local totalAmount = math.max(0, math.floor((tonumber(amount) or 0) * self:GetExperienceMultiplier(actor)))
    local didLevelUp, level, experience = self:AddExperience(actor, totalAmount)
    return didLevelUp, level, experience, totalAmount
end

function PlayerStateService:ApplyLevelMultiplier(actor, multiplier)
    local state = self:_getOrCreateState(actor)
    local resolvedMultiplier = math.max(1, tonumber(multiplier) or 1)
    local previousLevel = math.max(1, math.floor(tonumber(state.Level) or GameConfig.PLAYER.BaseLevel))
    local targetLevel = math.clamp(
        math.floor((previousLevel * resolvedMultiplier) + 0.5),
        1,
        GameConfig.PLAYER.MaxSupportedLevel
    )

    if targetLevel <= previousLevel then
        state.Level = targetLevel
        self:_applyLevelDerivedState(state)
        self:_syncLeaderstats(actor, state)
        self:SyncCharacterState(actor)
        self:PushState(actor)
        return false, state.Level, state.Experience
    end

    local previousMaxHealth = state.MaxHealth
    state.Level = targetLevel
    state.HighestLevelReached = math.max(normalizeLevel(state.HighestLevelReached or previousLevel), targetLevel)
    state.Experience = math.min(math.max(0, math.floor(tonumber(state.Experience) or 0)), GameConfig.GetNextLevelExperience(targetLevel))
    self:_applyLevelDerivedState(state)
    local healthGain = math.max(0, state.MaxHealth - previousMaxHealth)
    state.CurrentHealth = math.min(state.MaxHealth, state.CurrentHealth + healthGain)
    self:SyncCharacterState(actor)
    if self._weaponService then
        self._weaponService:RebuildWeaponsForActor(actor)
    end
    if self._rebirthService then
        self._rebirthService:MarkDirty(actor)
    end
    self:_fireLevelUpFeedback(actor, previousLevel, state.Level)
    self:_syncLeaderstats(actor, state)
    self:PushState(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
        if self._leaderboardService.BroadcastNow then
            self._leaderboardService:BroadcastNow()
        end
    end
    self:_markArenaProgressDirty()
    return true, state.Level, state.Experience
end

function PlayerStateService:ResetCombatState(actor)
    local wasInArena = self:_getOrCreateState(actor).IsInArena == true
    local state = self:_getOrCreateState(actor)
    state.IsInArena = false
    state.Alive = false
    state.Level = GameConfig.PLAYER.BaseLevel
    state.Experience = GameConfig.PLAYER.BaseExperience
    state.MoveSpeed = GameConfig.PLAYER.BaseMoveSpeed
    state.KillCount = 0
    state.Buffs = {}
    self:_applyLevelDerivedState(state)
    state.CurrentHealth = state.MaxHealth
    self:_syncLeaderstats(actor, state)
    self:UpdateOverheadHealthBar(actor)
    if self._leaderboardService then
        self._leaderboardService:MarkDirty()
        if self._leaderboardService.BroadcastNow then
            self._leaderboardService:BroadcastNow()
        end
    end
    if wasInArena then
        self:_markArenaProgressDirty()
    end
end

function PlayerStateService:CaptureHumanoidHealth(actor)
    local state = self:_getOrCreateState(actor)
    local humanoid = ActorUtils.GetHumanoid(actor)
    if not humanoid then
        return false
    end

    state.MaxHealth = humanoid.MaxHealth
    state.CurrentHealth = math.clamp(humanoid.Health, 0, humanoid.MaxHealth)
    return true
end

function PlayerStateService:OnCharacterAdded(actor)
    local wasInArena = self:_getOrCreateState(actor).IsInArena == true
    local state = self:_getOrCreateState(actor)
    state.IsInArena = false
    state.Alive = true
    self:_applyLevelDerivedState(state)
    state.CurrentHealth = state.MaxHealth
    configureCharacterCollision(ActorUtils.GetCharacter(actor))
    self:SyncCharacterState(actor)
    self:_syncLeaderstats(actor, state)
    self:UpdateOverheadHealthBar(actor)
    self:PushState(actor)
    if wasInArena then
        self:_markArenaProgressDirty()
    end
end

function PlayerStateService:OnPlayerRemoving(player)
    local state = self._statesByActorId[getActorId(player)]
    local wasInArena = state and state.IsInArena == true
    self._statesByActorId[getActorId(player)] = nil
    self:QueueFriendBonusRefresh()
    if wasInArena then
        self:_markArenaProgressDirty()
    end
end

function PlayerStateService:GetState(actor)
    return self:_getOrCreateState(actor)
end

function PlayerStateService:IsInArena(actor)
    return self:_getOrCreateState(actor).IsInArena == true
end

function PlayerStateService:SetInArena(actor, isInArena)
    local state = self:_getOrCreateState(actor)
    local wasActiveInArena = state.IsInArena == true and state.Alive == true
    state.IsInArena = isInArena == true
    if state.IsInArena then
        state.Alive = true
        self:_applyLevelDerivedState(state)
        if state.CurrentHealth <= 0 then
            state.CurrentHealth = state.MaxHealth
        end
        self:SyncCharacterState(actor)
    end
    self:_syncLeaderstats(actor, state)
    local isActiveInArena = state.IsInArena == true and state.Alive == true
    if wasActiveInArena ~= isActiveInArena then
        self:_markArenaProgressDirty()
    end
end

function PlayerStateService:GetArenaActors()
    local result = {}
    for _, state in pairs(self._statesByActorId) do
        local actor = state.ActorRef
        if actor and state.IsInArena and state.Alive then
            if ActorUtils.IsPlayer(actor) then
                if actor.Parent then
                    table.insert(result, actor)
                end
            elseif ActorUtils.IsBot(actor) then
                table.insert(result, actor)
            end
        end
    end
    return result
end

function PlayerStateService:GetArenaPlayers()
    local result = {}
    for _, actor in ipairs(self:GetArenaActors()) do
        if ActorUtils.IsPlayer(actor) then
            table.insert(result, actor)
        end
    end
    return result
end

function PlayerStateService:GetAllActors()
    local result = {}
    for _, state in pairs(self._statesByActorId) do
        if state.ActorRef then
            table.insert(result, state.ActorRef)
        end
    end
    return result
end

function PlayerStateService:GetAllPlayerStates()
    local result = {}
    for _, state in pairs(self._statesByActorId) do
        if state.ActorKind == "Player" then
            table.insert(result, state)
        end
    end
    return result
end

return PlayerStateService
