-- V6.13 isolated regression checks. Studio Edit only; never starts Playtest or calls live remotes.
-- Clones the formal template/controller/modal. Blur is replaced on the private modal instance only.
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local results = {}
local verified = true
local temporaryModules, detached, controller, modal
local fakeRequests = {}
local fakeSyncCount = 0
local blurActive = false
local currentMain
local hitObjects = {}

local function record(name, passed, detail)
    table.insert(results, { name = name, passed = passed == true, detail = detail })
    if not passed then
        verified = false
    end
end

local function check(name, callback)
    local ok, failure = pcall(callback)
    record(name, ok, not ok and tostring(failure) or nil)
end

local function pointer(inputType, x, y)
    return { UserInputType = inputType, Position = Vector3.new(x or 100, y or 100, 0) }
end

local function payload(tier)
    return { eventType = "Show", tierIndex = tier, weaponName = "Verification T" .. tier,
        damage = 10 * tier, rewardDiamonds = 100, weaponIcon = "" }
end

local function arm()
    controller._inputArmedAt = os.clock() - 1
end

local function click(target, inputType)
    hitObjects = { target }
    local input = pointer(inputType or Enum.UserInputType.MouseButton1)
    controller:_handlePointerBegan(input)
    controller:_handlePointerEnded(input)
end

local function feedback(eventType, tier, message, clearPending)
    controller:_handleFeedback({ eventType = eventType, tierIndex = tier,
        message = message or (eventType == "Success" and "Claimed" or "DataLoading"),
        clearPending = clearPending == true })
end

local function waitForClose()
    task.wait(0.24)
end

local success, failure = pcall(function()
    assert(RunService:IsStudio() and not RunService:IsRunning(), "Studio Edit mode required")
    assert(game.PlaceId == 73988417166286, "Wrong PlaceId")
    local mainTemplate = game:GetService("StarterGui"):FindFirstChild("Main")
    local panelTemplate = mainTemplate and mainTemplate:FindFirstChild("NewWeaponUnlock")
    local backdropTemplate = mainTemplate and mainTemplate:FindFirstChild("NewWeaponUnlockBackdrop")
    assert(panelTemplate and backdropTemplate and backdropTemplate:IsA("TextButton"), "Formal V6.13 templates missing")
    local controllers = game:GetService("StarterPlayer").StarterPlayerScripts:FindFirstChild("Controllers")
    assert(controllers and controllers:FindFirstChild("NewWeaponUnlockController") and controllers:FindFirstChild("ModalUiController"))
    detached = Instance.new("Folder")
    detached.Name = "WeaponUnlockDetachedVerification"
    local function makeMain()
        local main = Instance.new("ScreenGui")
        main.Name = "Main"
        main.Parent = detached
        panelTemplate:Clone().Parent = main
        backdropTemplate:Clone().Parent = main
        local hud = Instance.new("Frame")
        hud.Name = "VerificationHud"
        hud.Visible = true
        hud.Parent = main
        return main
    end
    currentMain = makeMain()
    temporaryModules = Instance.new("Folder")
    temporaryModules.Name = "WeaponUnlockVerification_" .. HttpService:GenerateGUID(false)
    temporaryModules.Parent = game:GetService("ServerStorage")
    controllers.CinematicUiGate:Clone().Parent = temporaryModules
    local modalModule = controllers.ModalUiController:Clone()
    modalModule.Parent = temporaryModules
    modal = require(modalModule)
    modal._applyBlur = function()
        blurActive = true
    end
    modal._restoreBlur = function()
        blurActive = false
    end
    local sourceModule = controllers.NewWeaponUnlockController:Clone()
    sourceModule.Parent = temporaryModules
    controller = require(sourceModule)
    local fakePlayerGui = {}
    function fakePlayerGui:FindFirstChild(name)
        return name == "Main" and currentMain or nil
    end
    function fakePlayerGui:GetGuiObjectsAtPosition()
        return hitObjects
    end
    local fakePlayer = {}
    function fakePlayer:FindFirstChild(name)
        return name == "PlayerGui" and fakePlayerGui or nil
    end
    controller._localPlayer = fakePlayer
    local requestEvent = { FireServer = function(_, tier)
        table.insert(fakeRequests, tier)
    end }
    controller._requestClaimEvent = requestEvent
    controller._requestStateSyncEvent = { FireServer = function()
        fakeSyncCount += 1
    end }
    assert(controller:_bindUi(true), "Cannot bind cloned formal UI")

    check("Formal UI initially hidden; no modal owner or blur", function()
        assert(not controller._panel.Visible and not controller._backdrop.Visible)
        assert(not modal._owners.NewWeaponUnlock and not blurActive)
        assert(currentMain.VerificationHud.Visible)
    end)

    controller:_handlePrompt(payload(2))
    controller:_handlePrompt(payload(2))
    controller:_handlePrompt(payload(4))
    controller:_handlePrompt(payload(3))
    controller:_handlePrompt(payload(3))
    check("All content and Claim appear together; pending tiers are ordered and deduplicated", function()
        assert(controller._panel.Visible and controller._backdrop.Visible)
        assert(controller._claimButton.Visible and controller._claimButton.Active)
        assert(#controller._activeTweens == 2, "Only panel position and scale should animate")
        assert(controller._nameLabel.Text == "Verification T2")
        assert(#controller._pendingPayloads == 2 and controller._pendingPayloads[1].tierIndex == 3)
        assert(modal._owners.NewWeaponUnlock and blurActive)
        assert(not currentMain.VerificationHud.Visible)
    end)

    check("Keyboard, an old touch release and a press during the opening guard never claim", function()
        hitObjects = { controller._backdrop }
        local oldTouch = pointer(Enum.UserInputType.Touch)
        controller:_handlePointerEnded(oldTouch)
        local key = pointer(Enum.UserInputType.Keyboard)
        controller:_handlePointerBegan(key)
        controller:_handlePointerEnded(key)
        controller._inputArmedAt = os.clock() + 1
        local duringOpen = pointer(Enum.UserInputType.MouseButton1)
        controller:_handlePointerBegan(duringOpen)
        arm()
        controller:_handlePointerEnded(duringOpen)
        assert(#fakeRequests == 0)
    end)

    check("Hit testing allows this modal and blocks unrelated foreground controls", function()
        local input = pointer(Enum.UserInputType.MouseButton1)
        hitObjects = { controller._backdrop }
        assert(controller:_getPointerTarget(input) == "blank")
        hitObjects = { controller._claimButton }
        assert(controller:_getPointerTarget(input) == "claim")
        local foreign = Instance.new("TextButton")
        foreign.Parent = currentMain
        foreign.Visible = true
        hitObjects = { foreign, controller._backdrop }
        assert(controller:_getPointerTarget(input) == nil)
        click(foreign)
        assert(#fakeRequests == 0)
        foreign:Destroy()
    end)

    check("Mouse/touch dragging, holding and moving between Claim and backdrop never claim", function()
        for _, inputType in ipairs({ Enum.UserInputType.MouseButton1, Enum.UserInputType.Touch }) do
            hitObjects = { controller._backdrop }
            local input = pointer(inputType)
            controller:_handlePointerBegan(input)
            if inputType == Enum.UserInputType.MouseButton1 then
                controller:_handlePointerChanged(pointer(Enum.UserInputType.MouseMovement, 140, 100))
            else
                input.Position = Vector3.new(140, 100, 0)
                controller:_handlePointerChanged(input)
                input.Position = Vector3.new(100, 100, 0)
            end
            controller:_handlePointerEnded(input)
        end
        hitObjects = { controller._backdrop }
        local held = pointer(Enum.UserInputType.Touch)
        controller:_handlePointerBegan(held)
        controller._pointerCandidates[held].startedAt -= 1
        controller:_handlePointerEnded(held)
        local crossed = pointer(Enum.UserInputType.MouseButton1)
        controller:_handlePointerBegan(crossed)
        hitObjects = { controller._claimButton }
        controller:_handlePointerEnded(crossed)
        assert(#fakeRequests == 0)
    end)

    check("Two-finger input cancels dismissal candidates", function()
        hitObjects = { controller._backdrop }
        local first, second = pointer(Enum.UserInputType.Touch), pointer(Enum.UserInputType.Touch)
        controller:_handlePointerBegan(first)
        controller:_handlePointerBegan(second)
        controller:_handlePointerEnded(first)
        controller:_handlePointerEnded(second)
        assert(#fakeRequests == 0)
    end)

    check("A blank click closes immediately and sends one tier-only request without granting locally", function()
        click(controller._backdrop)
        controller:_requestClaim()
        assert(#fakeRequests == 1 and fakeRequests[1] == 2)
        assert(controller._isClosing and controller._isClaiming and not controller._isOpen)
        assert(not controller._acknowledgedTierIndexes["2"])
        assert(not controller._claimButton.Active)
    end)
    feedback("Success", 2)
    feedback("Failed", 2, "Busy")
    check("Fast success waits for close completion and late failure cannot undo it", function()
        assert(controller._activePayload.tierIndex == 2 and controller._isClosing)
        assert(controller._claimResolution == "complete")
    end)
    waitForClose()
    check("Success advances only one pending tier and preserves the remaining queue", function()
        assert(controller._isOpen and controller._activePayload.tierIndex == 3)
        assert(#controller._pendingPayloads == 1 and controller._pendingPayloads[1].tierIndex == 4)
        assert(#fakeRequests == 1)
        assert(controller._backdrop.Visible and modal._owners.NewWeaponUnlock and blurActive)
    end)

    check("Stale prompts and feedback cannot close a later tier", function()
        controller:_handlePrompt(payload(2))
        feedback("Success", 2)
        feedback("Failed", 2, "DataLoading")
        assert(controller._activePayload.tierIndex == 3 and controller._isOpen)
        assert(#controller._pendingPayloads == 1)
    end)
    arm()
    click(controller._claimButton, Enum.UserInputType.Touch)
    waitForClose()
    check("A touch on Claim also sends once; a slow response leaves gameplay unblocked", function()
        assert(#fakeRequests == 2 and fakeRequests[2] == 3)
        assert(controller._isClaiming and not controller._isOpen and not controller._isClosing)
        assert(not controller._panel.Visible and not controller._backdrop.Visible)
        assert(not modal._owners.NewWeaponUnlock and not blurActive)
        assert(currentMain.VerificationHud.Visible)
    end)
    feedback("Failed", 3, "DataLoading")
    check("A failed response restores the same reward for manual retry", function()
        assert(controller._isOpen and not controller._isClaiming)
        assert(controller._activePayload.tierIndex == 3 and controller._claimButton.Active)
        assert(not controller._acknowledgedTierIndexes["3"])
        assert(#fakeRequests == 2)
    end)
    arm()
    click(controller._backdrop)
    local pendingSerial = controller._claimSerial
    waitForClose()
    controller:_onClaimTimeout(pendingSerial - 1, 3)
    check("A stale timeout cannot alter the current request", function()
        assert(controller._isClaiming and not controller._isOpen)
    end)
    controller:_onClaimTimeout(pendingSerial, 3)
    check("A current timeout restores the reward without automatically resending", function()
        assert(controller._isOpen and not controller._isClaiming)
        assert(controller._activePayload.tierIndex == 3 and #fakeRequests == 3)
    end)
    feedback("Success", 3)
    waitForClose()
    check("A late success after timeout settles the same reward and advances safely", function()
        assert(controller._activePayload.tierIndex == 4 and controller._isOpen)
        assert(controller._acknowledgedTierIndexes["3"])
    end)

    arm()
    hitObjects = { controller._backdrop }
    local oldPress = pointer(Enum.UserInputType.Touch)
    controller:_handlePointerBegan(oldPress)
    local oldPanel, oldBackdrop = controller._panel, controller._backdrop
    currentMain = makeMain()
    assert(controller:_bindUi(true))
    arm()
    hitObjects = { controller._backdrop }
    controller:_handlePointerEnded(oldPress)
    check("Template rebinding hides the old modal and cannot carry a press into the new one", function()
        assert(not oldPanel.Visible and not oldBackdrop.Visible)
        assert(controller._activePayload.tierIndex == 4 and controller._isOpen)
        assert(modal._owners.NewWeaponUnlock.Panel == controller._panel)
        assert(#fakeRequests == 3 and #controller._buttonConnections == 4)
    end)

    click(controller._backdrop)
    local pendingPanel, pendingBackdrop = controller._panel, controller._backdrop
    currentMain = makeMain()
    assert(controller:_bindUi(true))
    feedback("Success", 4)
    check("Rebinding during a request cannot leave an old panel or blur behind", function()
        assert(not pendingPanel.Visible and not pendingBackdrop.Visible)
        assert(not controller._activePayload and not controller._isClaiming)
        assert(not controller._panel.Visible and not controller._backdrop.Visible)
        assert(not modal._owners.NewWeaponUnlock and not blurActive)
    end)

    controller:_handlePrompt(payload(5))
    arm()
    controller._requestClaimEvent = { FireServer = function()
        error("Intentional isolated transport failure")
    end }
    click(controller._backdrop)
    waitForClose()
    check("A transport failure restores the same reward without claiming it", function()
        assert(controller._isOpen and not controller._isClaiming)
        assert(controller._activePayload.tierIndex == 5)
        assert(not controller._acknowledgedTierIndexes["5"])
    end)
    controller._requestClaimEvent = requestEvent
    controller:_handlePrompt(payload(6))
    arm()
    click(controller._backdrop)
    feedback("Failed", 5, "NoPendingReward", true)
    waitForClose()
    check("Authoritative clearPending removes stale queue entries and releases the modal", function()
        assert(not controller._activePayload and #controller._pendingPayloads == 0)
        assert(next(controller._queuedTierIndexes) == nil)
        assert(not controller._acknowledgedTierIndexes["5"])
        assert(not modal._owners.NewWeaponUnlock and not blurActive)
        assert(not controller._panel.Visible and not controller._backdrop.Visible)
    end)
end)

if not success then
    record("Verification setup or execution", false, tostring(failure))
end
local cleanupSuccess, cleanupFailure = pcall(function()
    if controller then
        controller._lifecycleSerial += 1
        controller._claimSerial += 1
        controller._bindRetryQueued = false
        controller:_disconnectButtonBindings()
        controller:_disconnectPanelVisibleWatcher()
        controller:_releasePresentation()
    end
    if modal then
        modal:Release("NewWeaponUnlock")
        modal:_cancelDimOverlayTween()
    end
end)
if temporaryModules then
    temporaryModules:Destroy()
end
if detached then
    detached:Destroy()
end
record("Detached UI, cloned modules, input connections and modal ownership cleaned up", cleanupSuccess,
    not cleanupSuccess and tostring(cleanupFailure) or nil)
return HttpService:JSONEncode({ verified = verified, results = results,
    fakeClaimRequests = fakeRequests, fakeStateSyncRequests = fakeSyncCount,
    excluded = { "Uses detached UI and synthetic pointer samples; real desktop/touch hit testing, CoreGui menu behavior and rendered motion require manual verification." } })
