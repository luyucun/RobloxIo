--[[
Script: ChestConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/ChestConfig
Purpose: V5.9 chest item catalog and drop pool metadata.
]]

local ChestConfig = {}

-- BEGIN GENERATED CHEST ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 宝箱. Update via tools/SyncCodeConfigFromWorkbook.py.
ChestConfig.Chests = {
    {
        Id = 101,
        Icon = 'rbxassetid://100403311120383',
        DropPoolId = 1,
    },
    {
        Id = 102,
        Icon = 'rbxassetid://91047283783298',
        DropPoolId = 2,
    },
}

ChestConfig.DropPools = {
    [1] = {
        { RewardType = 'WheelSpins', Amount = 2, Weight = 200.0, IsLimited = false },
        { RewardType = 'Diamonds', Amount = 300, Weight = 400.0, IsLimited = false },
        { RewardType = 'Potion', Amount = 2, Weight = 250.0, IsLimited = false, PotionId = 1001 },
        { RewardType = 'Potion', Amount = 2, Weight = 100.0, IsLimited = false, PotionId = 1002 },
        { RewardType = 'Potion', Amount = 2, Weight = 40.0, IsLimited = false, PotionId = 1003 },
        { RewardType = 'Trail', Amount = 1, Weight = 7.0, IsLimited = true, TrailId = 1008 },
        { RewardType = 'Diamonds', Amount = 20000, Weight = 3.0, IsLimited = false },
    },
    [2] = {
        { RewardType = 'WheelSpins', Amount = 5, Weight = 200.0, IsLimited = false },
        { RewardType = 'Diamonds', Amount = 500, Weight = 400.0, IsLimited = false },
        { RewardType = 'Potion', Amount = 2, Weight = 100.0, IsLimited = false, PotionId = 1003 },
        { RewardType = 'Trail', Amount = 1, Weight = 50.0, IsLimited = true, TrailId = 1008 },
        { RewardType = 'Diamonds', Amount = 10000, Weight = 30.0, IsLimited = false },
    },
}
-- END GENERATED CHEST ROWS

ChestConfig.ById = {}
ChestConfig.DropPoolsById = {}

local function normalizeRewardType(rewardType)
	local text = tostring(rewardType or "")
	if text == "Diamonds" or text == "钻石" then
		return "Diamonds"
	elseif text == "WheelSpins" or text == "转盘次数" or text == "钻盘次数" then
		return "WheelSpins"
	elseif text == "Potion" or text == "药水" then
		return "Potion"
	elseif text == "Trail" or text == "尾迹" then
		return "Trail"
	end
	return text
end

for _, chest in ipairs(ChestConfig.Chests) do
	chest.Id = math.floor(tonumber(chest.Id) or 0)
	chest.Icon = tostring(chest.Icon or "")
	chest.DropPoolId = math.floor(tonumber(chest.DropPoolId) or 0)
	if chest.Id > 0 then
		ChestConfig.ById[chest.Id] = chest
	end
end

for poolId, rows in pairs(ChestConfig.DropPools) do
	local normalizedPoolId = math.floor(tonumber(poolId) or 0)
	local normalizedRows = {}
	for index, reward in ipairs(type(rows) == "table" and rows or {}) do
		local normalizedReward = {
			PoolId = normalizedPoolId,
			RewardType = normalizeRewardType(reward.RewardType),
			Amount = math.max(1, math.floor(tonumber(reward.Amount) or 1)),
			Weight = math.max(0, tonumber(reward.Weight) or 0),
			IsLimited = reward.IsLimited == true or tonumber(reward.IsLimited) == 1,
			SortOrder = index,
		}
		if reward.PotionId then
			normalizedReward.PotionId = math.floor(tonumber(reward.PotionId) or 0)
		end
		if reward.TrailId then
			normalizedReward.TrailId = math.floor(tonumber(reward.TrailId) or 0)
		end
		table.insert(normalizedRows, normalizedReward)
	end
	ChestConfig.DropPoolsById[normalizedPoolId] = normalizedRows
end

function ChestConfig.GetChest(chestId)
	return ChestConfig.ById[math.floor(tonumber(chestId) or 0)]
end

function ChestConfig.GetDropPool(poolId)
	return ChestConfig.DropPoolsById[math.floor(tonumber(poolId) or 0)] or {}
end

function ChestConfig.GetDropPoolForChest(chestId)
	local chest = ChestConfig.GetChest(chestId)
	return chest and ChestConfig.GetDropPool(chest.DropPoolId) or {}
end

function ChestConfig.GetAllChests()
	return ChestConfig.Chests
end

function ChestConfig.CopyRewardForClient(reward)
	if type(reward) ~= "table" then
		return nil
	end

	return {
		rewardType = reward.RewardType,
		potionId = reward.PotionId,
		trailId = reward.TrailId,
		amount = reward.Amount,
		weight = reward.Weight,
		isLimited = reward.IsLimited == true,
	}
end

function ChestConfig.CopyChestForClient(chest)
	if type(chest) ~= "table" then
		return nil
	end

	local rewards = {}
	for _, reward in ipairs(ChestConfig.GetDropPool(chest.DropPoolId)) do
		local copied = ChestConfig.CopyRewardForClient(reward)
		if copied then
			table.insert(rewards, copied)
		end
	end

	return {
		id = chest.Id,
		icon = chest.Icon,
		dropPoolId = chest.DropPoolId,
		rewards = rewards,
	}
end

function ChestConfig.CopyAllForClient()
	local result = {}
	for _, chest in ipairs(ChestConfig.Chests) do
		local copied = ChestConfig.CopyChestForClient(chest)
		if copied then
			table.insert(result, copied)
		end
	end
	return result
end

return ChestConfig
