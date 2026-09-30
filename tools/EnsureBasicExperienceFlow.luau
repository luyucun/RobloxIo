-- V6.13 formal template deployment. Run through this project's bridge after Assert-StudioProject.
-- Only entry visibility and an invisible unlock-click surface change; existing artwork stays intact.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit only")
local main = game:GetService("StarterGui"):FindFirstChild("Main")
assert(main and main:IsA("ScreenGui") and main.Parent == game.StarterGui, "Expected StarterGui.Main")

local taskEntry = main:FindFirstChild("Right") and main.Right:FindFirstChild("Daily")
local onlineEntry = main:FindFirstChild("Right") and main.Right:FindFirstChild("Online")
local chestEntry = main:FindFirstChild("Left") and main.Left:FindFirstChild("Box")
local taskPanel = main:FindFirstChild("TaskBgNew")
local chestPanel = main:FindFirstChild("ChestRewards")
local unlockPanel = main:FindFirstChild("NewWeaponUnlock")
local trailTemplate = main:FindFirstChild("Skin") and main.Skin:FindFirstChild("TrailRowTemplate", true)
local boxOpen = trailTemplate and trailTemplate:FindFirstChild("BoxOpen")
for name, node in pairs({ Task = taskEntry, Online = onlineEntry, Box = chestEntry,
    TaskPanel = taskPanel, ChestPanel = chestPanel, Unlock = unlockPanel, BoxOpen = boxOpen }) do
    assert(node and node:IsA("GuiObject"), "Missing or invalid formal GUI: " .. name)
end
assert(taskEntry and onlineEntry and chestEntry and taskPanel and chestPanel and unlockPanel and boxOpen,
    "Incomplete formal flow templates")
local backdrop = main:FindFirstChild("NewWeaponUnlockBackdrop")
assert(not backdrop or (backdrop:IsA("TextButton") and backdrop.Parent == main), "Unexpected unlock backdrop")

-- Use a fresh config instance so Edit-mode require caches cannot apply stale switches.
local configSource = game.ReplicatedStorage.Shared:FindFirstChild("GameConfig")
assert(configSource and configSource:IsA("ModuleScript"), "Missing GameConfig")
local configClone = configSource:Clone()
local configOk, config = pcall(require, configClone)
configClone:Destroy()
assert(configOk and type(config) == "table", "Could not load current GameConfig")
local visibility = config.UI_ENTRY_VISIBILITY or {}
local showTasks = visibility.Tasks ~= false
local showChests = visibility.Chests ~= false
local onlineWasVisible = onlineEntry.Visible

taskEntry.Visible = showTasks
chestEntry.Visible = showChests
taskPanel.Visible = false
chestPanel.Visible = false
if not showTasks then
    local redPoint = taskEntry:FindFirstChild("RedPoint", true)
    if redPoint and redPoint:IsA("GuiObject") then redPoint.Visible = false end
end
if not showChests then
    for _, name in ipairs({ "RedPoint", "Info" }) do
        local badge = chestEntry:FindFirstChild(name, true)
        if badge and badge:IsA("GuiObject") then badge.Visible = false end
    end
    boxOpen.Visible = false
end

if not backdrop then
    backdrop = Instance.new("TextButton")
    backdrop.Name = "NewWeaponUnlockBackdrop"
    backdrop.Parent = main
end
backdrop.AnchorPoint = Vector2.zero
backdrop.Position = UDim2.fromScale(0, 0)
backdrop.Size = UDim2.fromScale(1, 1)
backdrop.BackgroundTransparency = 1
backdrop.BorderSizePixel = 0
backdrop.Text = ""
backdrop.AutoButtonColor = false
backdrop.Selectable = false
backdrop.Active = true
backdrop.Visible = false
backdrop.ZIndex = 11
local scale = unlockPanel:FindFirstChildOfClass("UIScale")
if not scale then
    scale = Instance.new("UIScale")
    scale.Name = "UnlockScale"
    scale.Parent = unlockPanel
end
scale.Scale = 1
unlockPanel.Visible = false
main:SetAttribute("BasicExperienceFlowVersion", 1)
assert(onlineEntry.Visible == onlineWasVisible, "Online rewards visibility must not change")

return game:GetService("HttpService"):JSONEncode({
    verified = taskEntry.Visible == showTasks and chestEntry.Visible == showChests,
    tasksVisible = taskEntry.Visible,
    chestsVisible = chestEntry.Visible,
    boxOpenVisible = boxOpen.Visible,
    onlineVisible = onlineEntry.Visible,
    unlockBackdrop = backdrop:GetFullName(),
    unlockBackdropVisible = backdrop.Visible,
    activityDelaySeconds = config.ACTIVITY_RSVP_PROMPT.DelaySeconds,
    favoriteEnabled = config.FAVORITE_PROMPT.Enabled,
})
