-- V6.13 hide/restore switches: real controller clones and detached formal UI, without Init or live remotes.
-- The only source substitution routes GameConfig to a fresh private clone so the
-- fallback and re-enable cases cannot mutate Studio's already-cached live config.
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")
local results = {}
local verified = true
local temporaryModules
local detached
local taskController
local chestController
local skinController

local function check(name, callback)
    local ok, failure = pcall(callback)
    table.insert(results, { name = name, passed = ok, detail = not ok and tostring(failure) or nil })
    if not ok then
        verified = false
    end
end

local function required(root, name)
    local node = root and root:FindFirstChild(name, true)
    assert(node, "Missing formal node: " .. name)
    return node
end

local ok, failure = pcall(function()
    assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit only")
    assert(game.PlaceId == 73988417166286, "Wrong PlaceId")
    local sources = game:GetService("StarterPlayer").StarterPlayerScripts.Controllers
    temporaryModules = Instance.new("Folder")
    temporaryModules.Name = "HiddenEntryVerification_" .. HttpService:GenerateGUID(false)
    temporaryModules.Parent = game:GetService("ServerStorage")

    local privateConfig = game:GetService("ReplicatedStorage").Shared.GameConfig:Clone()
    privateConfig.Name = "__PrivateGameConfig"
    privateConfig.Parent = temporaryModules
    local config = require(privateConfig)
    assert(type(config.UI_ENTRY_VISIBILITY) == "table"
        and type(config.UI_ENTRY_VISIBILITY.Tasks) == "boolean"
        and type(config.UI_ENTRY_VISIBILITY.Chests) == "boolean",
        "Deployed GameConfig must define boolean Tasks and Chests visibility switches")
    local deployedTasksVisible = config.UI_ENTRY_VISIBILITY.Tasks
    local deployedChestsVisible = config.UI_ENTRY_VISIBILITY.Chests

    for _, name in ipairs({ "CinematicUiGate", "TaskController", "ChestController", "SkinController", "ModalUiController", "TouchRegionGate" }) do
        local cloned = sources[name]:Clone()
        if name == "TaskController" or name == "ChestController" or name == "SkinController" then
            local changed
            cloned.Source, changed = cloned.Source:gsub(
                'local GameConfig = requireSharedModule%("GameConfig"%)',
                'local GameConfig = require(script.Parent:WaitForChild("__PrivateGameConfig"))')
            assert(changed == 1, "Expected exactly one isolated GameConfig binding in " .. name)
        end
        cloned.Parent = temporaryModules
    end
    taskController = require(temporaryModules.TaskController)
    chestController = require(temporaryModules.ChestController)
    skinController = require(temporaryModules.SkinController)

    detached = Instance.new("Folder")
    detached.Name = "HiddenEntryDetachedUi"
    local main = game:GetService("StarterGui").Main:Clone()
    main.Parent = detached
    local onlineEntry = required(required(main, "Right"), "Online")
    local onlineVisible = onlineEntry.Visible
    local onlinePosition = onlineEntry.Position
    local onlineSize = onlineEntry.Size
    local fakeGui = { FindFirstChild = function(_, name) return name == "Main" and main or nil end }
    local fakePlayer = { FindFirstChild = function(_, name) return name == "PlayerGui" and fakeGui or nil end }
    taskController._localPlayer = fakePlayer
    chestController._localPlayer = fakePlayer

    check("Task and chest controllers bind their UI with the deployed visibility switches", function()
        assert(taskController:_bindUi(true))
        assert(chestController:_bindUi(true))
        assert(taskController._entryRoot.Visible == deployedTasksVisible)
        assert(chestController._leftEntry.Visible == deployedChestsVisible)
    end)

    -- Exercise hiding on the private config even when the deployed entries are restored.
    config.UI_ENTRY_VISIBILITY = { Tasks = false, Chests = false }
    taskController:_renderEntryState()
    chestController:_updateUi()

    check("Incoming completed tasks remain stored while the entry and red dot stay hidden", function()
        taskController:_applyStatePayload({
            tasks = { daily = { { taskId = 101, title = "Test", target = 1, progress = 1,
                isClaimable = true, isClaimed = false, rewards = {} } }, weekly = {} },
            hasClaimableReward = true,
        })
        assert(taskController:_hasClaimableTask())
        assert(taskController._state.tasks.daily[1].progress == 1)
        assert(not taskController._entryRoot.Visible and not taskController._entryRedPoint.Visible)
        assert(not taskController._entryButton.Active and not taskController._entryButton.Selectable)
    end)

    check("Incoming chest inventory still updates without revealing the HUD or count bubble", function()
        chestController:_applyPayload({ chests = { ["101"] = 27 } })
        assert(chestController:_getChestCount(101) == 27)
        assert(chestController._countText.Text == "You have: 27")
        assert(not chestController._leftEntry.Visible and not chestController._leftInfo.Visible)
        assert(chestController._openOneBinding.enabled and chestController._openAllBinding.enabled)
    end)

    local trail = required(main, "TrailRowTemplate"):Clone()
    trail.Parent = main
    local trailData = { id = 90001, name = "Test box trail", isBoxOnly = true, owned = false }
    local boxOpen = required(trail, "BoxOpen")
    check("Unowned box-only trail keeps its item but hides and disables its alternative chest entry", function()
        skinController:_populateTrailItem(trail, trailData)
        assert(trail.Parent and not boxOpen.Visible)
        local button = boxOpen:IsA("GuiButton") and boxOpen or boxOpen:FindFirstChildWhichIsA("GuiButton", true)
        assert(button and not button.Active and not button.Selectable)
        for _, binding in ipairs(skinController._itemButtonBindings) do
            assert(binding.button ~= button, "Hidden chest entry was still bound")
        end
    end)

    check("Explicit re-enable restores task/chest entry and preserved reward indicators", function()
        config.UI_ENTRY_VISIBILITY = { Tasks = true, Chests = true }
        taskController:_renderEntryState()
        chestController:_updateUi()
        skinController:_disconnectItemButtonBindings()
        skinController:_populateTrailItem(trail, trailData)
        assert(taskController._entryRoot.Visible and taskController._entryRedPoint.Visible)
        assert(chestController._leftEntry.Visible and chestController._leftInfo.Visible)
        assert(boxOpen.Visible)
    end)

    check("Missing visibility settings preserve the original visible-entry behavior", function()
        config.UI_ENTRY_VISIBILITY = nil
        taskController:_renderEntryState()
        chestController:_updateUi()
        skinController:_disconnectItemButtonBindings()
        skinController:_populateTrailItem(trail, trailData)
        assert(taskController._entryRoot.Visible and chestController._leftEntry.Visible and boxOpen.Visible)
    end)

    check("Rebinding with entries disabled does not expose rewards again; online entry is untouched", function()
        config.UI_ENTRY_VISIBILITY = { Tasks = false, Chests = false }
        assert(taskController:_bindUi(true) and chestController:_bindUi(true))
        taskController:_renderEntryState()
        chestController:_updateUi()
        assert(not taskController._entryRoot.Visible and not taskController._entryRedPoint.Visible)
        assert(not chestController._leftEntry.Visible and not chestController._leftInfo.Visible)
        assert(onlineEntry.Visible == onlineVisible and onlineEntry.Position == onlinePosition and onlineEntry.Size == onlineSize)
        assert(onlineVisible, "The online-reward entry must remain visible in the formal template")
    end)
end)

if not ok then
    verified = false
    table.insert(results, { name = "Verification setup/execution", passed = false, detail = tostring(failure) })
end

check("Detached UI, module clones and bindings cleaned up", function()
    if taskController then
        taskController:_disconnectBindings(taskController._buttonBindings)
        taskController:_disconnectBindings(taskController._detailBindings)
        taskController:_clearRows()
        taskController:_clearRewardRows()
    end
    if chestController then
        chestController:_disconnectButtonBindings()
    end
    if skinController then
        skinController:_disconnectItemButtonBindings()
        skinController:_disconnectButtonBindings()
    end
end)
if temporaryModules then temporaryModules:Destroy() end
if detached then detached:Destroy() end
return HttpService:JSONEncode({ verified = verified, results = results,
    excluded = { "Does not start Playtest or call live remotes; viewport layout is not covered." } })
