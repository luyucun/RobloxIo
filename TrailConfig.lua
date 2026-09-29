--[[
Script: TrailConfig
Type: ModuleScript
Studio path: ReplicatedStorage/Shared/TrailConfig
Purpose: V4.5 character trail catalog and purchase metadata.
]]

local TrailConfig = {}

-- BEGIN GENERATED TRAIL ROWS
-- Source: IO_BaseBalanceDraft.xlsx / 尾迹. Update via tools/SyncCodeConfigFromWorkbook.py.
TrailConfig.Trails = {
    {
        Id = 1001,
        Name = 'Starfall Trail',
        TemplateName = 'Trail001',
        TemplatePath = 'ReplicatedStorage/Model/Trail/Trail001',
        IconImage = 'rbxassetid://92179365798579',
        DiamondPrice = 199,
        RobuxPrice = 19,
        ProductId = 3601859594,
        IsDefaultUnlocked = true,
        SortOrder = 1,
        IsBoxOnly = false,
        ExperienceBonus = 0.0,
    },
    {
        Id = 1010,
        Name = 'Butter',
        TemplateName = 'Trail010',
        TemplatePath = 'ReplicatedStorage/Model/Trail/Trail010',
        IconImage = 'rbxassetid://90666239640859',
        DiamondPrice = 0,
        RobuxPrice = 0,
        ProductId = 3609210351,
        IsDefaultUnlocked = false,
        SortOrder = 2,
        IsBoxOnly = true,
        ExperienceBonus = 0.4,
    },
    {
        Id = 1002,
        Name = 'Rift Trail',
        TemplateName = 'Trail002',
        TemplatePath = 'ReplicatedStorage/Model/Trail/Trail002',
        IconImage = 'rbxassetid://111010624256087',
        DiamondPrice = 5900,
        RobuxPrice = 59,
        ProductId = 3601859651,
        IsDefaultUnlocked = false,
        SortOrder = 3,
        IsBoxOnly = false,
        ExperienceBonus = 0.1,
    },
    {
        Id = 1003,
        Name = 'Code Stream',
        TemplateName = 'Trail003',
        TemplatePath = 'ReplicatedStorage/Model/Trail/Trail003',
        IconImage = 'rbxassetid://85943083222947',
        DiamondPrice = 9900,
        RobuxPrice = 99,
        ProductId = 3602015249,
        IsDefaultUnlocked = false,
        SortOrder = 4,
        IsBoxOnly = false,
        ExperienceBonus = 0.15,
    },
    {
        Id = 1004,
        Name = 'Astral Runes',
        TemplateName = 'Trail004',
        TemplatePath = 'ReplicatedStorage/Model/Trail/Trail004',
        IconImage = 'rbxassetid://85069083901738',
        DiamondPrice = 16900,
        RobuxPrice = 169,
        ProductId = 3602015327,
        IsDefaultUnlocked = false,
        SortOrder = 5,
        IsBoxOnly = false,
        ExperienceBonus = 0.2,
    },
    {
        Id = 1005,
        Name = 'Heartbow Trail',
        TemplateName = 'Trail005',
        TemplatePath = 'ReplicatedStorage/Model/Trail/Trail005',
        IconImage = 'rbxassetid://79645045137496',
        DiamondPrice = 29900,
        RobuxPrice = 299,
        ProductId = 3602015404,
        IsDefaultUnlocked = false,
        SortOrder = 6,
        IsBoxOnly = false,
        ExperienceBonus = 0.25,
    },
    {
        Id = 1006,
        Name = 'Verdant Glow',
        TemplateName = 'Trail006',
        TemplatePath = 'ReplicatedStorage/Model/Trail/Trail006',
        IconImage = 'rbxassetid://137181153604931',
        DiamondPrice = 39900,
        RobuxPrice = 399,
        ProductId = 3602015478,
        IsDefaultUnlocked = false,
        SortOrder = 7,
        IsBoxOnly = false,
        ExperienceBonus = 0.3,
    },
    {
        Id = 1007,
        Name = 'Tidal Surge',
        TemplateName = 'Trail007',
        TemplatePath = 'ReplicatedStorage/Model/Trail/Trail007',
        IconImage = 'rbxassetid://90501972344316',
        DiamondPrice = 49900,
        RobuxPrice = 499,
        ProductId = 3602015534,
        IsDefaultUnlocked = false,
        SortOrder = 8,
        IsBoxOnly = false,
        ExperienceBonus = 0.35,
    },
    {
        Id = 1008,
        Name = 'Golden Stardust',
        TemplateName = 'Trail008',
        TemplatePath = 'ReplicatedStorage/Model/Trail/Trail008',
        IconImage = 'rbxassetid://82082312904863',
        DiamondPrice = 59900,
        RobuxPrice = 599,
        ProductId = 3602015590,
        IsDefaultUnlocked = false,
        SortOrder = 9,
        IsBoxOnly = false,
        ExperienceBonus = 0.4,
    },
    {
        Id = 1009,
        Name = 'Bubble Pop',
        TemplateName = 'Trail009',
        TemplatePath = 'ReplicatedStorage/Model/Trail/Trail009',
        IconImage = 'rbxassetid://130952449390741',
        DiamondPrice = 59900,
        RobuxPrice = 599,
        ProductId = 3608059690,
        IsDefaultUnlocked = false,
        SortOrder = 10,
        IsBoxOnly = false,
        ExperienceBonus = 0.4,
    },
}
-- END GENERATED TRAIL ROWS

TrailConfig.ById = {}
TrailConfig.ByTemplateName = {}
TrailConfig.ByProductId = {}

for index, trail in ipairs(TrailConfig.Trails) do
    trail.Id = math.floor(tonumber(trail.Id) or 0)
    trail.TemplateName = tostring(trail.TemplateName or "")
    trail.TemplatePath = tostring(trail.TemplatePath or "")
    trail.IconImage = tostring(trail.IconImage or "")
    trail.DiamondPrice = math.max(0, math.floor(tonumber(trail.DiamondPrice) or 0))
    trail.RobuxPrice = math.max(0, math.floor(tonumber(trail.RobuxPrice) or 0))
    trail.ProductId = math.max(0, math.floor(tonumber(trail.ProductId) or 0))
    trail.IsDefaultUnlocked = trail.IsDefaultUnlocked == true or tonumber(trail.IsDefaultUnlocked) == 1
    trail.SortOrder = math.max(0, math.floor(tonumber(trail.SortOrder) or index))
    trail.IsBoxOnly = trail.IsBoxOnly == true or tonumber(trail.IsBoxOnly) == 1
    trail.ExperienceBonus = math.max(0, tonumber(trail.ExperienceBonus) or 0)
    TrailConfig.ById[trail.Id] = trail
    TrailConfig.ByTemplateName[trail.TemplateName] = trail
    if trail.ProductId > 0 then
        TrailConfig.ByProductId[trail.ProductId] = trail
    end
end

function TrailConfig.GetTrail(trailId)
    return TrailConfig.ById[math.floor(tonumber(trailId) or 0)]
end

function TrailConfig.GetTrailByTemplateName(templateName)
    return TrailConfig.ByTemplateName[tostring(templateName or "")]
end

function TrailConfig.GetTrailByProductId(productId)
    return TrailConfig.ByProductId[math.floor(tonumber(productId) or 0)]
end

function TrailConfig.GetAllTrails()
    return TrailConfig.Trails
end

function TrailConfig.CopyForClient(trail)
    if type(trail) ~= "table" then
        return nil
    end

    return {
        id = trail.Id,
        name = trail.Name,
        templateName = trail.TemplateName,
        iconImage = trail.IconImage,
        diamondPrice = trail.DiamondPrice,
        robuxPrice = trail.RobuxPrice,
        productId = trail.ProductId,
        isDefaultUnlocked = trail.IsDefaultUnlocked == true,
        sortOrder = trail.SortOrder,
        isBoxOnly = trail.IsBoxOnly == true,
        experienceBonus = trail.ExperienceBonus,
    }
end

return TrailConfig
