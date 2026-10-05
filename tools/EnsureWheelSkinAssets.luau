-- Edit-only: sync the configured wheel skin to the formal wheel and claim templates.
-- Run after the project health/identity gate and source sync. Preserve manual layout.
assert(game.PlaceId == 73988417166286, "Wrong Place")
assert(game:GetService("RunService"):IsStudio() and not game:GetService("RunService"):IsRunning(), "Edit mode only")
local shared = game.ReplicatedStorage.Shared
local wheel = assert(loadstring(shared.WheelConfig.Source))()
local skins = assert(loadstring(shared.SkinConfig.Source))()
local targets = {}
for _, reward in ipairs(wheel.Rewards) do
    if reward.SkinId then
        local skin = assert(skins.GetSkin(reward.SkinId), "Wheel skin not configured")
        assert(not skin.IsRetired and skins.IsWheelSkin(skin), "Invalid wheel skin acquisition")
        local model = game.ReplicatedStorage.Model.Weapon:FindFirstChild(skin.TemplateName)
        assert(model and model:IsA("Model") and model:FindFirstChildWhichIsA("BasePart", true), "Missing weapon model")
        assert(type(skin.IconImage) == "string" and skin.IconImage:match("^rbxassetid://%d+$"), "Invalid skin icon")
        for _, root in ipairs({game.StarterGui.Main.WheelBg, game.ReplicatedStorage.UI.WheelBg}) do
            local colorBg = root:FindFirstChild("WheelColorBg")
            local gift = colorBg and colorBg:FindFirstChild(reward.GiftName)
            assert(gift and gift:IsA("ImageLabel") and gift.Parent == colorBg, "Unexpected wheel gift template")
            table.insert(targets, {node = gift, icon = skin.IconImage, skinId = skin.Id})
        end
    end
end
assert(#targets > 0, "No skin gift targets")
local result = {}
for _, target in ipairs(targets) do
    local before = target.node.Image
    target.node.Image = target.icon
    target.node:SetAttribute("RewardSkinId", target.skinId)
    table.insert(result, {path = target.node:GetFullName(), before = before, image = target.node.Image, skinId = target.skinId})
end
return game.HttpService:JSONEncode(result)
