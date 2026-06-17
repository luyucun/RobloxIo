--[[
Script: SkinConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/SkinConfig
Purpose: V3.1 weapon skin catalog and purchase metadata.
]]

local SkinConfig = {}

SkinConfig.PurchaseChannel = {
    Diamonds = 1,
    GamePass = 2,
    Wheel = 3,
    SevenDayLoginReward = 4,
}

-- BEGIN GENERATED SKIN ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 皮肤表 + 武器数值. Update via tools/SyncCodeConfigFromWorkbook.py.
SkinConfig.Skins = {
    {
        Id = 10001,
        Name = 'Magma Hammer',
        TemplateName = 'Skin001',
        TemplatePath = 'ReplicatedStorage/Model/Weapon/Skin001',
        IconImage = 'rbxassetid://123177643935146',
        PurchaseChannel = SkinConfig.PurchaseChannel.Diamonds,
        DiamondPrice = 15999,
        GamePassId = 0,
    },
    {
        Id = 10002,
        Name = 'Phantom Reaper',
        TemplateName = 'Skin002',
        TemplatePath = 'ReplicatedStorage/Model/Weapon/Skin002',
        IconImage = 'rbxassetid://96062173104075',
        PurchaseChannel = SkinConfig.PurchaseChannel.GamePass,
        DiamondPrice = 0,
        GamePassId = 1830742687,
    },
    {
        Id = 10003,
        Name = 'Frozen Chainblade',
        TemplateName = 'Skin003',
        TemplatePath = 'ReplicatedStorage/Model/Weapon/Skin003',
        IconImage = 'rbxassetid://106240490422146',
        PurchaseChannel = SkinConfig.PurchaseChannel.Wheel,
        DiamondPrice = 0,
        GamePassId = 0,
    },
    {
        Id = 10006,
        Name = 'Abyss Sword',
        TemplateName = 'Skin006',
        TemplatePath = 'ReplicatedStorage/Model/Weapon/Skin006',
        IconImage = 'rbxassetid://107965659960902',
        PurchaseChannel = SkinConfig.PurchaseChannel.SevenDayLoginReward,
        DiamondPrice = 0,
        GamePassId = 0,
    },
    {
        Id = 10007,
        Name = 'Watermelon Pop',
        TemplateName = 'Skin007',
        TemplatePath = 'ReplicatedStorage/Model/Weapon/Skin007',
        IconImage = 'rbxassetid://97879805462753',
        PurchaseChannel = SkinConfig.PurchaseChannel.SevenDayLoginReward,
        DiamondPrice = 0,
        GamePassId = 0,
    },
}
-- END GENERATED SKIN ROWS

SkinConfig.ById = {}
SkinConfig.ByTemplateName = {}

for index, skin in ipairs(SkinConfig.Skins) do
    skin.Id = math.floor(tonumber(skin.Id) or 0)
    skin.SortOrder = index
    skin.DiamondPrice = math.max(0, math.floor(tonumber(skin.DiamondPrice) or 0))
    skin.GamePassId = math.max(0, math.floor(tonumber(skin.GamePassId) or 0))
    SkinConfig.ById[skin.Id] = skin
    SkinConfig.ByTemplateName[tostring(skin.TemplateName or "")] = skin
end

function SkinConfig.GetSkin(skinId)
    return SkinConfig.ById[math.floor(tonumber(skinId) or 0)]
end

function SkinConfig.GetSkinByTemplateName(templateName)
    return SkinConfig.ByTemplateName[tostring(templateName or "")]
end

function SkinConfig.GetAllSkins()
    return SkinConfig.Skins
end

function SkinConfig.IsDiamondSkin(skin)
    return skin and tonumber(skin.PurchaseChannel) == SkinConfig.PurchaseChannel.Diamonds
end

function SkinConfig.IsGamePassSkin(skin)
    return skin and tonumber(skin.PurchaseChannel) == SkinConfig.PurchaseChannel.GamePass
end

function SkinConfig.IsWheelSkin(skin)
    return skin and tonumber(skin.PurchaseChannel) == SkinConfig.PurchaseChannel.Wheel
end

function SkinConfig.IsSevenDayLoginRewardSkin(skin)
    return skin and tonumber(skin.PurchaseChannel) == SkinConfig.PurchaseChannel.SevenDayLoginReward
end

function SkinConfig.CopyForClient(skin)
    if type(skin) ~= "table" then
        return nil
    end

    return {
        id = skin.Id,
        name = skin.Name,
        templateName = skin.TemplateName,
        iconImage = skin.IconImage,
        purchaseChannel = skin.PurchaseChannel,
        diamondPrice = skin.DiamondPrice,
        gamePassId = skin.GamePassId,
    }
end

return SkinConfig
