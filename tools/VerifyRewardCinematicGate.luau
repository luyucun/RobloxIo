-- V6.19 / 2026-10-04. Studio Edit only; detached formal GUI and private controller modules.
-- The Shop Init below belongs to a private clone whose external bindings are all replaced.
-- No production Init, live RemoteEvent, Marketplace call, reward grant or Playtest is used.
-- A local runner may replace the next declaration with a map of local module source strings.
local sourceOverrides = nil -- Local-source runner may replace this declaration.
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit mode required")
assert(game.PlaceId == 73988417166286, "Wrong PlaceId")

local results, verified = {}, true
local modules, detached, runtime, gate, modal, shop, weapon
local chestClaims, weaponClaims, stateSyncs = {}, {}, 0
local popupStarts, chestCallbacks = {}, {}
local externalBindings = 0
local signals = {}

local function check(name, callback)
    local ok, failure = pcall(callback)
    table.insert(results, {name = name, passed = ok, detail = not ok and tostring(failure) or nil})
    if not ok then verified = false end
end

local function disconnectAll(connections)
    for _, connection in ipairs(connections or {}) do
        if connection.Connected then connection:Disconnect() end
    end
    table.clear(connections or {})
end

local function required(parent, name)
    local node = parent and parent:FindFirstChild(name, true)
    assert(node, "Missing formal node " .. name)
    return node
end

local function reward(label, source, extra)
    local payload = {
        source = source or "Task", closeDelay = 0.3,
        rewards = {{label = label, amount = 10, icon = "", aspectRatio = 1}},
    }
    for key, value in pairs(extra or {}) do payload[key] = value end
    return payload
end

local function tier(index)
    return {eventType = "Show", tierIndex = index, weaponName = "Fixture T" .. index,
        damage = index * 10, rewardDiamonds = 100, weaponIcon = ""}
end

local ok, failure = xpcall(function()
    local controllers = game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("Controllers")
    local formalMain = game:GetService("StarterGui"):FindFirstChild("Main")
    assert(controllers and formalMain, "Missing formal controllers/Main")
    modules = Instance.new("Folder")
    modules.Name = "RewardGateVerification_" .. HttpService:GenerateGUID(false)
    modules.Parent = game:GetService("ServerStorage")
    detached = Instance.new("Folder")
    detached.Name = "RewardGateDetachedGui"

    -- Only controller delays/clocks are virtualized. Actual formal nodes and tweens are retained.
    local runtimeModule = Instance.new("ModuleScript")
    runtimeModule.Name = "__RewardGateFixtureRuntime"
    runtimeModule.Source = [=[
local realTask, realOs = task, os
local runtime = {now = 100, queue = {}, serial = 0}
local function schedule(seconds, callback, ...)
    runtime.serial += 1
    local job = {at = runtime.now + math.max(0, seconds), callback = callback, args = {...}, serial = runtime.serial}
    table.insert(runtime.queue, job)
    return job
end
runtime.task = {
    delay = function(seconds, callback, ...) return schedule(seconds, callback, ...) end,
    defer = function(callback, ...) return schedule(0, callback, ...) end,
    spawn = realTask.spawn, wait = realTask.wait,
    cancel = function(job)
        if type(job) == "table" then job.cancelled = true else realTask.cancel(job) end
    end,
}
runtime.os = setmetatable({clock = function() return runtime.now end}, {__index = realOs})
function runtime:Advance(seconds)
    local target, iterations = self.now + seconds, 0
    while true do
        table.sort(self.queue, function(a, b) return a.at == b.at and a.serial < b.serial or a.at < b.at end)
        if #self.queue == 0 or self.queue[1].at > target then break end
        iterations += 1
        assert(iterations <= 2000, "Fixture delay queue did not settle")
        local job = table.remove(self.queue, 1)
        self.now = math.max(self.now, job.at)
        if not job.cancelled then job.callback(table.unpack(job.args)) end
    end
    self.now = target
end
return runtime
]=]
    runtimeModule.Parent = modules
    local prefix = 'local __fixture = require(script.Parent:WaitForChild("__RewardGateFixtureRuntime"))\nlocal task, os = __fixture.task, __fixture.os\n'
    for _, name in ipairs({"CinematicUiGate", "ModalUiController", "TouchRegionGate", "ShopController", "NewWeaponUnlockController"}) do
        local original = controllers:FindFirstChild(name)
        local source = sourceOverrides and sourceOverrides[name] or original and original.Source
        assert(type(source) == "string" and #source > 0, "Missing source for " .. name)
        assert(not original or original:IsA("ModuleScript"), "Unexpected controller class " .. name)
        local cloned = original and original:Clone() or Instance.new("ModuleScript")
        cloned.Name = name
        cloned.Source = prefix .. source
        cloned.Parent = modules
    end
    runtime = require(runtimeModule)
    gate = require(modules.CinematicUiGate)
    modal = require(modules.ModalUiController)
    -- Private modal ownership/suppression stays real; no Lighting or rendered dim overlay is touched.
    modal._applyBlur = function() end
    modal._restoreBlur = function() end
    modal._applyDimOverlay = function() end
    modal._restoreDimOverlay = function() end
    shop = require(modules.ShopController)
    weapon = require(modules.NewWeaponUnlockController)

    local shopMain = Instance.new("ScreenGui")
    shopMain.Name = "Main"
    shopMain.Enabled = true
    shopMain.Parent = detached
    required(formalMain, "ClaimSuccessful"):Clone().Parent = shopMain
    local chestPanel = Instance.new("Frame")
    chestPanel.Name = "ChestRewards"
    chestPanel.Visible = false
    chestPanel.Parent = shopMain
    local popup = shopMain.ClaimSuccessful
    local itemTemplate = required(required(popup, "ItemListFrame"), "ItemTemplate")
    local originalPosition = popup.Position
    local attributeSignal, childSignal = Instance.new("BindableEvent"), Instance.new("BindableEvent")
    table.insert(signals, attributeSignal)
    table.insert(signals, childSignal)
    local currentMain = shopMain
    local fakeGui = {ChildAdded = childSignal.Event}
    function fakeGui:FindFirstChild(name) return name == "Main" and currentMain or nil end
    function fakeGui:GetGuiObjectsAtPosition() return {} end
    local fakePlayer = {}
    function fakePlayer:FindFirstChild(name) return name == "PlayerGui" and fakeGui or nil end
    function fakePlayer:GetAttributeChangedSignal() return attributeSignal.Event end

    -- Replace external edges before running the private Shop Init; presentation methods are unmodified.
    shop._connectRemotes = function() externalBindings += 1 end
    shop._bindMarketStall = function() return true end
    shop._applyPassOwnershipUi = function() end
    shop._setOpen = function(self, open) self._isOpen = open == true end
    shop._bindUi = function(self)
        self._mainGui, self._claimPopup, self._claimPopupTemplate = shopMain, popup, itemTemplate
        self._rewardPopupOriginalPosition = originalPosition
        popup.Visible, itemTemplate.Visible = false, false
        return true
    end
    local originalPlayPopup = shop._playRewardPopup
    shop._playRewardPopup = function(self, payload)
        table.insert(popupStarts, payload.rewards[1].label)
        return originalPlayPopup(self, payload)
    end
    local chest = {PlayOpenAnimation = function(_, callback)
        table.insert(chestCallbacks, callback)
        return true
    end}
    local audio = {IsSfxEnabled = function() return false end}
    shop._requestChestRewardClaimEvent = {FireServer = function(_, payload)
        table.insert(chestClaims, payload.rewardClaimId)
    end}
    local function initShop()
        shop:Init({LocalPlayer = fakePlayer, ChestController = chest, AudioSettings = audio})
    end
    local function advance(seconds) runtime:Advance(seconds or 0) end
    local function closeShop()
        advance(0.31)
        shop:_closeRewardPopup()
        advance(0)
    end

    check("Blocked private Init subscribes safely; every reward applies state immediately and preserves a pure FIFO", function()
        local token = gate:Acquire("Shop FIFO")
        initShop()
        shop:_enqueueRewardFeedback(reward("A", "Task", {state = {starterPackClaimed = true}}))
        assert(shop._starterPackClaimed)
        shop:_enqueueRewardFeedback(reward("B", "Code", {state = {starterPackClaimed = false}}))
        assert(not shop._starterPackClaimed)
        shop:_enqueueRewardFeedback(reward("C", "OnlineReward"))
        assert(#shop._pendingRewardPayloads == 3 and not shop._activeRewardPayload and not popup.Visible)
        for _, payload in ipairs(shop._pendingRewardPayloads) do assert(payload.state == nil) end
        assert(shop:HasPendingRewardPresentation() and #popupStarts == 0)
        shop:_applyState({starterPackClaimed = true})
        gate:Release(token)
        advance(0)
        assert(shop._starterPackClaimed, "Replaying A must not overwrite a newer state")
        assert(popup.Visible and popupStarts[1] == "A" and #popupStarts == 1)
        assert(shop._activeRewardPayload.rewards[1].label == "A" and #shop._pendingRewardPayloads == 2)
    end)

    check("Only dismissal advances the formal Shop popup, retaining all queued animations", function()
        closeShop()
        assert(popupStarts[2] == "B" and #popupStarts == 2 and #shop._pendingRewardPayloads == 1)
        assert(shop._starterPackClaimed, "B must not replay its stale false state")
        closeShop()
        assert(popupStarts[3] == "C" and #popupStarts == 3 and #shop._pendingRewardPayloads == 0)
        closeShop()
        assert(not popup.Visible and not shop:HasPendingRewardPresentation())
        assert(#chestClaims == 0 and not shop._rewardPopupInputConnection)
    end)

    check("An active Chest popup suspends without claiming, keeps its claimId and invalidates input/delays", function()
        shop:_enqueueRewardFeedback(reward("Chest 1", "Chest", {requiresClaim = true, rewardClaimId = "fixture-chest-1"}))
        assert(shop:HasPendingRewardPresentation() and #chestCallbacks == 1)
        chestCallbacks[1]()
        advance(2.11)
        assert(popup.Visible and shop._lastRewardClaimId == "fixture-chest-1")
        local token = gate:Acquire("Interrupt active Chest")
        shop:_enqueueRewardFeedback(reward("D"))
        shop:_enqueueRewardFeedback(reward("E", "Code"))
        assert(not popup.Visible and not shop._rewardPopupInputConnection and #shop._rewardPopupTweens == 0)
        assert(shop._activeRewardPayload.rewards[1].label == "Chest 1" and #shop._pendingRewardPayloads == 2)
        assert(shop._lastRewardClaimId == "fixture-chest-1" and #chestClaims == 0)
        -- Even a stale caller carrying the old close-ready state cannot claim through the barrier.
        shop._rewardPopupCanClose, popup.Visible = true, true
        shop:_closeRewardPopup()
        shop._rewardPopupCanClose, popup.Visible = false, false
        advance(10)
        assert(#chestClaims == 0 and not shop._rewardPopupCanClose and not shop._rewardPopupInputConnection)
        assert(popup.Position == originalPosition)
        gate:Release(token)
        advance(0)
        assert(#chestCallbacks == 2 and not popup.Visible, "Chest animation must restart before its reward popup")
        chestCallbacks[2]()
        advance(2.11)
        assert(popup.Visible and shop._activeRewardPayload.rewards[1].label == "Chest 1")
        closeShop()
        assert(#chestClaims == 1 and chestClaims[1] == "fixture-chest-1" and popupStarts[#popupStarts] == "D")
        closeShop()
        assert(popupStarts[#popupStarts] == "E" and #chestClaims == 1)
        closeShop()
        assert(not shop:HasPendingRewardPresentation())
    end)

    check("Interrupted Chest pre-animation cannot later emit its stale completion or bypass the full restart", function()
        shop:_enqueueRewardFeedback(reward("Chest 2", "Chest", {requiresClaim = true, rewardClaimId = "fixture-chest-2"}))
        local oldCallback = chestCallbacks[3]
        local token = gate:Acquire("Interrupt Chest pre-animation")
        oldCallback()
        gate:Release(token)
        advance(0)
        assert(#chestCallbacks == 4)
        local before = #popupStarts
        oldCallback()
        advance(3)
        assert(#popupStarts == before and not popup.Visible and #chestClaims == 1)
        chestCallbacks[4]()
        advance(2.11)
        assert(popup.Visible and popupStarts[#popupStarts] == "Chest 2")
        closeShop()
        assert(#chestClaims == 2 and chestClaims[2] == "fixture-chest-2")
    end)

    check("Private Shop re-Init disconnects its old gate listener and invalidates old popup callbacks", function()
        shop:_enqueueRewardFeedback(reward("Before Init"))
        advance(0)
        local oldConnections = table.clone(shop._connections)
        local oldSerial, before = shop._rewardPopupSerial, #popupStarts
        initShop()
        for _, connection in ipairs(oldConnections) do assert(not connection.Connected) end
        assert(shop._rewardPopupSerial > oldSerial and not shop:HasPendingRewardPresentation())
        advance(10)
        assert(not popup.Visible and not shop._rewardPopupCanClose and not shop._rewardPopupInputConnection)
        assert(#popupStarts == before and #chestClaims == 2)
        local listeners = 0
        for connection in pairs(gate._listeners) do if connection.Connected then listeners += 1 end end
        assert(listeners == 1 and externalBindings == 2)
        local token = gate:Acquire("After Init")
        shop:_enqueueRewardFeedback(reward("After Init"))
        gate:Release(token)
        advance(0)
        assert(#popupStarts == before + 1)
        closeShop()
    end)

    local function makeWeaponMain()
        local main = Instance.new("ScreenGui")
        main.Name = "Main"
        main.Enabled = true
        main.Parent = detached
        required(formalMain, "NewWeaponUnlock"):Clone().Parent = main
        required(formalMain, "NewWeaponUnlockBackdrop"):Clone().Parent = main
        return main
    end
    currentMain = makeWeaponMain()
    weapon._localPlayer = fakePlayer
    weapon._requestClaimEvent = {FireServer = function(_, index) table.insert(weaponClaims, index) end}
    weapon._requestStateSyncEvent = {FireServer = function() stateSyncs += 1 end}
    assert(weapon:_bindUi(true), "Cannot bind detached formal weapon UI")
    table.insert(weapon._connections, gate:Subscribe(function(blocked)
        if blocked then weapon:_releasePresentation() else weapon:_resumeAfterCinematic() end
    end))
    local function feedback(eventType, index, message, clearPending)
        weapon:_handleFeedback({eventType = eventType, tierIndex = index,
            message = message or "", clearPending = clearPending == true})
    end
    local function request()
        advance(0.2)
        weapon:_requestClaim()
    end

    check("Active weapon reward suspends intact; multiple blocked tiers remain sorted and deduplicated", function()
        weapon:_handlePrompt(tier(2))
        local token = gate:Acquire("Weapon active")
        weapon:_handlePrompt(tier(4))
        weapon:_handlePrompt(tier(3))
        weapon:_handlePrompt(tier(3))
        assert(not weapon._panel.Visible and not weapon._backdrop.Visible and not weapon._isOpen)
        assert(weapon._activePayload.tierIndex == 2 and #weapon._pendingPayloads == 2)
        assert(weapon._pendingPayloads[1].tierIndex == 3 and weapon:HasPendingRewardPresentation())
        assert(not weapon:_playOpen(tier(2)) and not weapon:_canInteract())
        weapon:_requestClaim()
        assert(#weaponClaims == 0)
        gate:Release(token)
        advance(0)
        assert(weapon._isOpen and weapon._activePayload.tierIndex == 2 and #weapon._pendingPayloads == 2)
    end)

    check("In-flight success resolves during a cinematic without replaying the acknowledged weapon", function()
        request()
        assert(#weaponClaims == 1 and weaponClaims[1] == 2 and weapon._isClaiming)
        local token = gate:Acquire("Weapon in-flight success")
        assert(weapon._isClaiming and weapon._activePayload.tierIndex == 2 and not weapon._isClosing)
        feedback("Success", 2)
        assert(weapon._acknowledgedTierIndexes["2"] and not weapon._activePayload and not weapon._isClaiming)
        assert(not weapon._panel.Visible and #weapon._pendingPayloads == 2)
        gate:Release(token)
        advance(0)
        assert(weapon._isOpen and weapon._activePayload.tierIndex == 3 and #weapon._pendingPayloads == 1)
        assert(#weaponClaims == 1)
    end)

    check("In-flight failure keeps the same weapon for a manual retry after the cinematic", function()
        request()
        local token = gate:Acquire("Weapon retry")
        feedback("Failed", 3, "DataLoading")
        assert(not weapon._isOpen and not weapon._isClaiming and weapon._activePayload.tierIndex == 3)
        gate:Release(token)
        advance(0)
        assert(weapon._isOpen and weapon._activePayload.tierIndex == 3 and #weaponClaims == 2)
        assert(not weapon._acknowledgedTierIndexes["3"])
    end)

    check("A current timeout during the cinematic preserves retry; late success advances exactly one tier", function()
        request()
        local token = gate:Acquire("Weapon timeout")
        advance(6.1)
        assert(not weapon._isClaiming and not weapon._isOpen and weapon._activePayload.tierIndex == 3)
        gate:Release(token)
        advance(0)
        assert(weapon._isOpen and weapon._activePayload.tierIndex == 3 and #weaponClaims == 3)
        feedback("Success", 3)
        task.wait(0.22)
        advance(0)
        assert(weapon._acknowledgedTierIndexes["3"] and weapon._activePayload.tierIndex == 4)
        assert(#weapon._pendingPayloads == 0 and #weaponClaims == 3)
        feedback("Success", 4)
        task.wait(0.22)
        assert(not weapon:HasPendingRewardPresentation())
    end)

    check("Missing-panel recovery drains one weapon tier only; AlreadyClaimed never replays on resume", function()
        weapon:_releasePresentation()
        weapon._panel, weapon._backdrop = nil, nil
        currentMain = makeWeaponMain()
        local token = gate:Acquire("Weapon rebind")
        weapon:_handlePrompt(tier(6))
        weapon:_handlePrompt(tier(5))
        weapon:_handlePrompt(tier(6))
        gate:Release(token)
        advance(0)
        assert(weapon._activePayload.tierIndex == 5 and #weapon._pendingPayloads == 1)
        assert(weapon._pendingPayloads[1].tierIndex == 6 and weapon._nameLabel.Text == "Fixture T5")
        request()
        token = gate:Acquire("Already claimed response")
        feedback("Failed", 5, "AlreadyClaimed")
        assert(weapon._acknowledgedTierIndexes["5"] and not weapon._activePayload)
        gate:Release(token)
        advance(0)
        assert(weapon._activePayload.tierIndex == 6 and #weaponClaims == 4)
        feedback("Failed", 6, "NoPendingReward", true)
        task.wait(0.22)
        assert(not weapon:HasPendingRewardPresentation() and #weapon._pendingPayloads == 0)
    end)
end, debug.traceback)
if not ok then
    verified = false
    table.insert(results, {name = "Fixture setup/execution", passed = false, detail = tostring(failure)})
end

check("Private callbacks, input connections, GUI, modules and modal ownership are cleaned up", function()
    if shop then
        disconnectAll(shop._connections)
        shop:_suspendRewardPresentation()
        shop._pendingRewardPayloads, shop._activeRewardPayload = {}, nil
    end
    if weapon then
        weapon._claimSerial += 1
        weapon._lifecycleSerial += 1
        disconnectAll(weapon._connections)
        weapon:_disconnectButtonBindings()
        weapon:_disconnectPanelVisibleWatcher()
        weapon:_releasePresentation()
    end
    if modal then
        modal:Release("ClaimSuccessful")
        modal:Release("NewWeaponUnlock")
        modal:_clearHiddenVisibleWatchers()
        modal:_clearChildWatcher()
    end
    if runtime then table.clear(runtime.queue) end
    for _, signal in ipairs(signals) do signal:Destroy() end
    if detached then detached:Destroy() end
    if modules then modules:Destroy() end
end)
return HttpService:JSONEncode({verified = verified, results = results, fakeChestClaims = chestClaims,
    fakeWeaponClaims = weaponClaims, fakeStateSyncRequests = stateSyncs, popupStarts = popupStarts,
    sourceMode = sourceOverrides and "local overrides" or "deployed Studio modules",
    excluded = {"Detached GUI proves payload/state/queue/cancellation behavior; rendered motion and real mouse/touch hit testing remain manual QA.",
        "Chest opening is a completion-callback fixture; no production chest animation, marketplace UI or reward settlement is invoked."}})
