-- V6.8 isolated regression checks. Run in Studio EDIT context after template deployment.
-- Fresh module source, fake player balances and detached UI clones only. No Init,
-- live player rewards, receipts, DataStores or Playtest changes.
local RunService = game:GetService("RunService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Run in Studio Edit mode only")
local HttpService = game:GetService("HttpService")
local sourceOverrides = nil -- Local-source runner may replace this declaration.
local passed = {}
local deferred = {}
local detached = Instance.new("Folder")
local created = { detached }
local fakeActors = { IsPlayer = function(player) return type(player) == "table" and player.UserId == 17 end }
local fakeModal = { Acquire = function() end, Release = function() end }
local function loadIsolated(instance, config)
    local source = sourceOverrides and sourceOverrides[instance.Name] or instance.Source
    local chunk, err = loadstring(source, "=" .. instance.Name)
    assert(chunk, err)
    local fakeGame = {}
    function fakeGame:GetService(name)
        if name == "TweenService" then
            return { Create = function()
                return { Play = function() end, Cancel = function() end, Completed = { Wait = function() end } }
            end }
        end
        return game:GetService(name)
    end
    setfenv(chunk, setmetatable({
        script = instance,
        game = fakeGame,
        require = function(module)
            if module.Name == "ActorUtils" then return fakeActors end
            if module.Name == "WheelConfig" and config then return config end
            if module.Name == "ModalUiController" then return fakeModal end
            if module.Name == "TouchRegionGate" then return {} end
            return require(module)
        end,
        Instance = { new = function(className)
            local item = Instance.new(className)
            table.insert(created, item)
            return item
        end },
        task = {
            delay = function(_, callback) table.insert(deferred, callback) end,
            spawn = function(callback) callback() end,
        },
    }, { __index = getfenv() }))
    return chunk()
end
local config = loadIsolated(game.ReplicatedStorage.Shared.WheelConfig)
local function check(name, callback)
    table.clear(deferred)
    callback()
    table.insert(passed, name)
end
local function fixture(options)
    options = options or {}
    local f = {
        player = { UserId = 17, Parent = true },
        loaded = options.loaded ~= false,
        state = { WheelSpins = options.spins or 1, Diamonds = 100, owned = options.owned == true },
        skinGrants = 0, diamondGrants = 0, spinRefunds = 0, dirty = 0, feedback = {},
    }
    f.reward = table.clone(config.GetRewardBySlot(3))
    f.config = table.clone(config)
    f.config.RollReward = function() return f.reward end
    f.wheel = loadIsolated(game.ServerScriptService.Services.WheelService, f.config)
    f.wheel._playerStateService = {
        GetState = function() return f.state end,
        OwnsSkin = function(_, _, skinId)
            assert(skinId == 10009)
            return f.state.owned
        end,
        TryConsumeWheelSpin = function()
            if f.state.WheelSpins <= 0 then return false, 0 end
            f.state.WheelSpins -= 1
            return true, f.state.WheelSpins
        end,
        AddDiamonds = function(_, _, amount, context)
            f.diamondGrants += 1
            f.state.Diamonds += amount
            f.lastDiamondContext = context
            if f.reenter then
                f.reenter = false
                f.wheel:_handleSpinRequest(f.player)
            end
            return f.state.Diamonds
        end,
        AddWheelSpins = function(_, _, amount, context)
            f.state.WheelSpins += amount
            if context.source == "wheel_refund" then f.spinRefunds += 1 end
        end,
    }
    f.wheel._skinService = { GrantSkin = function()
        f.skinGrants += 1
        if f.failSkin then return false, "SkinGrantFailed" end
        f.state.owned = true
        return true, f.racingOwnership and "AlreadyOwned" or "Granted"
    end }
    f.wheel._rebirthService = {
        IsPlayerLoaded = function() return f.loaded end,
        MarkDirty = function() f.dirty += 1 end,
    }
    f.wheel._wheelSpinResultEvent = { FireClient = function(_, _, payload)
        table.insert(f.feedback, payload)
    end }
    return f
end
local function lastResult(f)
    return f.feedback[#f.feedback]
end
local function clientFixture()
    local controller = loadIsolated(game.StarterPlayer.StarterPlayerScripts.Controllers.WheelController, config)
    local claim = game.StarterGui.Main.WheelClaim:Clone()
    claim.Parent = detached
    controller._wheelClaim = claim
    controller._wheelClaimTemplate = claim:FindFirstChild("GiftTemplate")
    controller._wheelClaimResultNotice = claim:FindFirstChild("ResultNotice")
    assert(controller._wheelClaimResultNotice, "Deploy EnsureWheelDuplicateNotice first")
    controller._wheelClaimGiftSourceRoot = game.ReplicatedStorage.UI.WheelBg.WheelColorBg
    return controller
end

local success, failure = xpcall(function()
    check("Workbook reward keeps 0.5% skin chance, original slot/rotation and 5,000 compensation", function()
        local skin = config.GetRewardBySlot(3)
        assert(skin.SkinId == 10009 and skin.Weight == 0.5 and config.TotalWeight == 100)
        assert(skin.TargetRotation == 30 and skin.GiftName == "Gift3" and skin.DuplicateDiamonds == 5000)
        assert(config.GetRewardBySlot(5).Amount == 200)
    end)
    check("First skin consumes one spin, grants skin once and grants no diamonds", function()
        local f = fixture()
        f.wheel:_handleSpinRequest(f.player)
        local result = lastResult(f)
        assert(result.ok and f.state.owned and f.skinGrants == 1 and f.diamondGrants == 0)
        assert(f.state.WheelSpins == 0 and f.state.Diamonds == 100)
        assert(not result.pending and not result.reward.pending and not result.reward.duplicateCompensation)
        assert(result.reward.awardedRewardType == "Skin" and result.reward.awardedGiftName == "Gift3")
        assert(f.reward.Pending == true, "Client payload must not mutate shared reward config")
    end)
    check("Owned skin grants exactly 5,000 diamonds without repeating skin unlocked feedback", function()
        local f = fixture({ owned = true })
        f.wheel:_handleSpinRequest(f.player)
        local result = lastResult(f)
        assert(result.ok and f.skinGrants == 0 and f.diamondGrants == 1 and f.state.Diamonds == 5100)
        assert(f.state.WheelSpins == 0 and result.reward.duplicateCompensation)
        assert(result.reward.awardedRewardType == "Diamonds" and result.reward.awardedAmount == 5000)
        assert(result.reward.awardedGiftName == "Gift5" and result.reward.duplicateDiamonds == 5000)
        assert(result.reward.slot == 3 and result.reward.giftName == "Gift3" and result.targetRotation == 30)
        assert(result.reason == "DuplicateConverted" and not result.pending)
        assert(f.lastDiamondContext.source == "wheel_duplicate_skin" and f.dirty > 0)
    end)
    check("Two consecutive skin rolls produce one skin followed by one compensation", function()
        local f = fixture({ spins = 2 })
        f.wheel:_handleSpinRequest(f.player)
        f.wheel:_handleSpinRequest(f.player)
        assert(f.skinGrants == 1 and f.diamondGrants == 1 and f.state.WheelSpins == 0)
        assert(not f.feedback[1].reward.duplicateCompensation and f.feedback[2].reward.duplicateCompensation)
    end)
    check("Concurrent spin while compensation is granted cannot consume or award twice", function()
        local f = fixture({ owned = true, spins = 2 })
        f.reenter = true
        f.wheel:_handleSpinRequest(f.player)
        assert(f.diamondGrants == 1 and f.state.Diamonds == 5100 and f.state.WheelSpins == 1)
        assert(#f.feedback == 2 and f.feedback[1].reason == "SpinInProgress" and lastResult(f).ok)
        assert(f.wheel._spinInProgressByUserId[17] == nil)
    end)
    check("AlreadyOwned race after first ownership check is compensated once", function()
        local f = fixture()
        f.racingOwnership = true
        f.wheel:_handleSpinRequest(f.player)
        assert(lastResult(f).ok and lastResult(f).reward.duplicateCompensation)
        assert(f.skinGrants == 1 and f.diamondGrants == 1 and f.state.Diamonds == 5100)
    end)
    check("No spins and repeated requests cannot manufacture compensation", function()
        local f = fixture({ owned = true, spins = 0 })
        f.wheel:_handleSpinRequest(f.player)
        f.wheel:_handleSpinRequest(f.player)
        assert(lastResult(f).reason == "NotEnoughSpins" and f.skinGrants == 0 and f.diamondGrants == 0)
        assert(f.state.WheelSpins == 0 and f.state.Diamonds == 100)
    end)
    check("Unloaded persistent data blocks spin consumption and compensation", function()
        local f = fixture({ owned = true, loaded = false })
        f.wheel:_handleSpinRequest(f.player)
        assert(lastResult(f).reason == "DataLoading" and f.state.WheelSpins == 1)
        assert(f.diamondGrants == 0 and f.skinGrants == 0)
    end)
    check("Failed skin grant restores the consumed spin and awards nothing", function()
        local f = fixture()
        f.failSkin = true
        f.wheel:_handleSpinRequest(f.player)
        assert(not lastResult(f).ok and lastResult(f).reason == "SkinGrantFailed")
        assert(f.spinRefunds == 1 and f.state.WheelSpins == 1 and not f.state.owned and f.diamondGrants == 0)
    end)
    check("Missing duplicate balance configuration fails explicitly and refunds the spin", function()
        local f = fixture({ owned = true })
        f.reward.DuplicateDiamonds = nil
        f.wheel:_handleSpinRequest(f.player)
        assert(lastResult(f).reason == "InvalidDuplicateCompensation")
        assert(f.spinRefunds == 1 and f.state.WheelSpins == 1 and f.diamondGrants == 0)
    end)
    check("Free timer spin and purchased spin use the same duplicate payout", function()
        for _, source in ipairs({ "timer", "purchased" }) do
            local f = fixture({ owned = true, spins = 0 })
            if source == "timer" then
                f.wheel._nextFreeAtByUserId[17] = 100
                f.wheel:_grantFreeSpin(f.player, 100)
            else
                assert(f.wheel:GrantPurchasedSpins(f.player, config.Purchases[1].ProductId))
            end
            f.wheel:_handleSpinRequest(f.player)
            assert(lastResult(f).ok and f.diamondGrants == 1 and f.state.Diamonds == 5100)
        end
    end)
    check("Ordinary diamond sector still grants 200 and keeps its original result", function()
        local f = fixture()
        f.reward = config.GetRewardBySlot(5)
        f.wheel:_handleSpinRequest(f.player)
        local result = lastResult(f)
        assert(result.ok and f.state.Diamonds == 300 and result.targetRotation == 210)
        assert(result.reward.giftName == "Gift5" and result.reward.amount == 200 and not result.reward.duplicateCompensation)
    end)
    check("Claim shows diamond icon, +5,000 and conversion notice while pointer stays on skin", function()
        local f = fixture({ owned = true })
        f.wheel:_handleSpinRequest(f.player)
        local c = clientFixture()
        c._playSpinTo = function(_, rotation, callback)
            assert(rotation == 30)
            callback()
        end
        c:_handleSpinResult(lastResult(f))
        local item = c._wheelClaimGeneratedItem
        assert(item and item.Name == "Gift5" and item.Image == "rbxassetid://89590364394067")
        assert(item:FindFirstChild("Num", true).Text == "+5,000")
        assert(c._wheelClaimResultNotice.Visible and c._wheelClaimResultNotice.Text == "Butter already owned\nConverted to 5,000 Diamonds")
        assert(f.state.Diamonds == 5100 and f.diamondGrants == 1, "Client display may not grant a second reward")
        c:_hideWheelClaim()
        assert(not c._wheelClaim.Visible and not c._wheelClaimResultNotice.Visible)
    end)
    check("Later ordinary claim clears duplicate notice and uses its own amount", function()
        local c = clientFixture()
        c:_showWheelClaim({ giftName = "Gift3", duplicateCompensation = true, awardedRewardType = "Diamonds", awardedAmount = 5000, awardedGiftName = "Gift5" })
        c:_showWheelClaim({ giftName = "Gift5", amount = 200 })
        assert(not c._wheelClaimResultNotice.Visible and c._wheelClaimGeneratedItem.Num.Text == "+200")
        c:_showWheelClaim({ giftName = "Gift3", awardedRewardType = "Skin", awardedGiftName = "Gift3" })
        assert(c._wheelClaimGeneratedItem.Name == "Gift3" and not c._wheelClaimResultNotice.Visible)
    end)
    check("Fixed rule notice preserves the original skin probability and stays readable during spin", function()
        local gift = game.StarterGui.Main.WheelBg.WheelColorBg.Gift3
        local notice = game.StarterGui.Main.WheelBg.DuplicateNotice
        assert(gift.Probality.Text == "0.5%")
        assert(notice:IsA("TextLabel") and notice.Text == "Butter duplicate: +5,000 Diamonds")
        assert(notice.Visible and notice.Rotation == 0 and notice.Parent == game.StarterGui.Main.WheelBg)
        assert(not game.StarterGui.Main.WheelClaim.ClipsDescendants)
    end)
end, debug.traceback)

for _, item in ipairs(created) do item:Destroy() end
if not success then error(failure) end
return HttpService:JSONEncode({ passed = #passed, cases = passed, scope = "isolated source and detached UI; no live rewards or Playtest" })
