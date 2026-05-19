--[[
脚本名字: PotionController
脚本文件: PotionController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/PotionController
说明: 绑定 V2.1.1 药水界面、购买/使用按钮、倒计时和总经验倍率显示。
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")
local TweenService = game:GetService("TweenService")

local ModalUiController = require(script.Parent:WaitForChild("ModalUiController"))

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
        "[PotionController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local PotionConfig = requireSharedModule("PotionConfig")
local RemoteNames = requireSharedModule("RemoteNames")

local PotionController = {}

PotionController._localPlayer = nil
PotionController._connections = {}
PotionController._buttonBindings = {}
PotionController._mainGui = nil
PotionController._panel = nil
PotionController._entry = nil
PotionController._friendEntry = nil
PotionController._boundPanel = nil
PotionController._boundEntry = nil
PotionController._boundFriendEntry = nil
PotionController._requestPotionActionEvent = nil
PotionController._requestStateSyncEvent = nil
PotionController._latestState = {
    diamonds = 0,
    potions = {},
    activePotions = {},
    friendBonusPercent = 0,
    friendExperienceBonus = 0,
    totalExperienceMultiplier = 1,
}
PotionController._buffBindings = {}
PotionController._bindRetryQueued = false
PotionController._bindRetryToken = 0
PotionController._deferredBindQueued = false
PotionController._panelTweens = {}
PotionController._panelAnimationSerial = 0
PotionController._isPanelOpen = false

local BUFF_SLOTS = {
    { Name = "Buff1Bg", PotionId = 1001 },
    { Name = "Buff2Bg", PotionId = 1002 },
    { Name = "Buff3Bg", PotionId = 1003 },
}

local HOVER_SCALE = 1.05
local PRESS_SCALE = 0.93
local ENTRY_HOVER_SCALE = 1.1
local ENTRY_PRESS_SCALE = 0.9
local HOVER_ROTATION = 20
local FRIEND_BONUS_ZERO_COLOR = Color3.fromRGB(255, 255, 255)
local FRIEND_BONUS_ACTIVE_COLOR = Color3.fromRGB(80, 255, 120)
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local OPEN_FROM_SCALE = 0.82
local OPEN_OVERSHOOT_SCALE = 1.06
local OPEN_OVERSHOOT_DURATION = 0.18
local OPEN_SETTLE_DURATION = 0.12
local CLOSE_OVERSHOOT_SCALE = 1.04
local CLOSE_OVERSHOOT_DURATION = 0.1
local CLOSE_TO_SCALE = 0.78
local CLOSE_SHRINK_DURATION = 0.14
local BIND_RETRY_INTERVAL_SECONDS = 0.5
local BIND_RETRY_WARNING_SECONDS = 12

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function ensureUiScale(guiObject)
    if not (guiObject and guiObject:IsA("GuiObject")) then
        return nil
    end

    local uiScale = guiObject:FindFirstChildOfClass("UIScale")
    if uiScale then
        return uiScale
    end

    uiScale = Instance.new("UIScale")
    uiScale.Scale = 1
    uiScale.Parent = guiObject
    return uiScale
end

local function findMainGui(localPlayer)
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    if not playerGui then
        return nil
    end

    return playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)
end

local function setText(textObject, value)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.Text = tostring(value)
    end
end

local function formatRobuxPrice(value)
    local price = tonumber(value)
    if not price then
        return nil
    end
    return tostring(math.max(0, math.floor(price + 0.5)))
end

local function setMarketplaceRobuxPrice(textObject, productId)
    if not textObject then
        return
    end

    local resolvedProductId = math.floor(tonumber(productId) or 0)
    if resolvedProductId <= 0 then
        return
    end

    local fallbackText = tostring(textObject.Text or "")
    setText(textObject, "...")
    task.spawn(function()
        local success, productInfo = pcall(function()
            return MarketplaceService:GetProductInfoAsync(resolvedProductId, Enum.InfoType.Product)
        end)
        if not (success and type(productInfo) == "table") then
            if fallbackText ~= "" then
                setText(textObject, fallbackText)
            end
            return
        end

        local priceText = formatRobuxPrice(productInfo.PriceInRobux)
        if priceText then
            setText(textObject, priceText)
        elseif fallbackText ~= "" then
            setText(textObject, fallbackText)
        end
    end)
end

local function setImage(imageObject, value)
    if imageObject and (imageObject:IsA("ImageLabel") or imageObject:IsA("ImageButton")) then
        imageObject.Image = tostring(value or "")
    end
end

local function setTextColor(textObject, color)
    if textObject and (textObject:IsA("TextLabel") or textObject:IsA("TextButton") or textObject:IsA("TextBox")) then
        textObject.TextColor3 = color
    end
end

local function trimNumber(value)
    local rounded = math.floor(((tonumber(value) or 0) * 100) + 0.5) / 100
    if math.abs(rounded - math.floor(rounded)) < 0.001 then
        return tostring(math.floor(rounded))
    end

    local text = string.format("%.2f", rounded)
    text = string.gsub(text, "0+$", "")
    text = string.gsub(text, "%.$", "")
    return text
end

local function formatMultiplier(value)
    return "x" .. trimNumber(value)
end

local function formatCountdown(remainingSeconds)
    local totalSeconds = math.max(0, math.ceil(tonumber(remainingSeconds) or 0))
    local hours = math.floor(totalSeconds / 3600)
    local minutes = math.floor((totalSeconds % 3600) / 60)
    local seconds = totalSeconds % 60

    if hours >= 1 then
        return string.format("%02d:%02d:%02d", hours, minutes, seconds)
    end

    return string.format("%02dm %02ds", minutes, seconds)
end

local function getPotionKey(potionId)
    local resolvedPotionId = math.floor(tonumber(potionId) or 0)
    if resolvedPotionId <= 0 then
        return nil
    end
    return tostring(resolvedPotionId)
end

local function getActivePotionsFromPayload(payload)
    if type(payload) ~= "table" then
        return {}
    end

    if type(payload.activePotions) == "table" then
        return payload.activePotions
    end

    if type(payload.ActivePotions) == "table" then
        return payload.ActivePotions
    end

    local activePotion = type(payload.activePotion) == "table" and payload.activePotion or payload.ActivePotion
    if type(activePotion) == "table" then
        local potionId = activePotion.Id or activePotion.id or activePotion.PotionId or activePotion.potionId
        local potionKey = getPotionKey(potionId)
        if potionKey then
            return {
                [potionKey] = activePotion,
            }
        end
    end

    return {}
end

local function playTween(binding, tweenKey, target, tweenInfo, goal)
    if not (binding and target and tweenInfo and goal) then
        return
    end

    local existingTween = binding.tweens[tweenKey]
    if existingTween then
        existingTween:Cancel()
        binding.tweens[tweenKey] = nil
    end

    local tween = TweenService:Create(target, tweenInfo, goal)
    binding.tweens[tweenKey] = tween
    tween.Completed:Connect(function()
        if binding.tweens[tweenKey] == tween then
            binding.tweens[tweenKey] = nil
        end
    end)
    tween:Play()
end

function PotionController:_ensureMainGuiEnabled()
    if not self._mainGui then
        return
    end

    if self._mainGui:IsA("LayerCollector") then
        self._mainGui.Enabled = true
    end
end

function PotionController:_cancelPanelTweens()
    for _, tween in ipairs(self._panelTweens) do
        if tween then
            tween:Cancel()
        end
    end
    table.clear(self._panelTweens)
end

function PotionController:_nextPanelAnimationSerial()
    self._panelAnimationSerial += 1
    return self._panelAnimationSerial
end

function PotionController:_setPanelOpen(isOpen, immediate)
    if not (self._panel and self._panel:IsA("GuiObject")) then
        if isOpen ~= true then
            self._isPanelOpen = false
            ModalUiController:Release("Potion")
        end
        return
    end

    local uiScale = ensureUiScale(self._panel)
    self:_cancelPanelTweens()
    local animationSerial = self:_nextPanelAnimationSerial()
    self._isPanelOpen = isOpen == true

    if self._isPanelOpen then
        self:_ensureMainGuiEnabled()
        ModalUiController:Acquire("Potion", self._panel)
        self._panel.Visible = true
        if not uiScale or immediate == true then
            if uiScale then
                uiScale.Scale = 1
            end
            return
        end

        uiScale.Scale = OPEN_FROM_SCALE
        local overshootTween = TweenService:Create(uiScale, TweenInfo.new(OPEN_OVERSHOOT_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
            Scale = OPEN_OVERSHOOT_SCALE,
        })
        local settleTween = TweenService:Create(uiScale, TweenInfo.new(OPEN_SETTLE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Scale = 1,
        })
        self._panelTweens = { overshootTween, settleTween }

        task.spawn(function()
            overshootTween:Play()
            overshootTween.Completed:Wait()
            if self._panelAnimationSerial ~= animationSerial or not self._isPanelOpen then
                return
            end

            settleTween:Play()
            settleTween.Completed:Wait()
            if self._panelAnimationSerial ~= animationSerial or not self._isPanelOpen then
                return
            end

            uiScale.Scale = 1
            table.clear(self._panelTweens)
        end)
        return
    end

    if not uiScale or immediate == true or not self._panel.Visible then
        if uiScale then
            uiScale.Scale = 1
        end
        self._panel.Visible = false
        ModalUiController:Release("Potion")
        return
    end

    local overshootTween = TweenService:Create(uiScale, TweenInfo.new(CLOSE_OVERSHOOT_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Scale = CLOSE_OVERSHOOT_SCALE,
    })
    local shrinkTween = TweenService:Create(uiScale, TweenInfo.new(CLOSE_SHRINK_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
        Scale = CLOSE_TO_SCALE,
    })
    self._panelTweens = { overshootTween, shrinkTween }

    task.spawn(function()
        overshootTween:Play()
        overshootTween.Completed:Wait()
        if self._panelAnimationSerial ~= animationSerial or self._isPanelOpen then
            return
        end

        shrinkTween:Play()
        shrinkTween.Completed:Wait()
        if self._panelAnimationSerial ~= animationSerial or self._isPanelOpen then
            return
        end

        uiScale.Scale = 1
        self._panel.Visible = false
        table.clear(self._panelTweens)
        ModalUiController:Release("Potion")
    end)
end

function PotionController:_applyButtonState(binding)
    local scale = binding.baseScale
    local rotation = binding.baseRotation
    local tweenInfo = RESET_TWEEN_INFO
    if binding.isPressed then
        scale = binding.baseScale * binding.pressScale
        rotation = binding.baseRotation + binding.hoverRotation
        tweenInfo = PRESS_TWEEN_INFO
    elseif binding.isHovered then
        scale = binding.baseScale * binding.hoverScale
        rotation = binding.baseRotation + binding.hoverRotation
        tweenInfo = HOVER_TWEEN_INFO
    end

    playTween(binding, "scale", binding.uiScale, tweenInfo, {
        Scale = scale,
    })

    if binding.rotationTarget then
        playTween(binding, "rotation", binding.rotationTarget, tweenInfo, {
            Rotation = rotation,
        })
    end
end

function PotionController:_bindButton(button, onActivated, options)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    local scaleTarget = (type(options) == "table" and options.ScaleTarget) or button
    local rotationTarget = (type(options) == "table" and options.RotationTarget) or nil
    local uiScale = ensureUiScale(scaleTarget)
    if not uiScale then
        return
    end

    local binding = {
        button = button,
        uiScale = uiScale,
        scaleTarget = scaleTarget,
        rotationTarget = rotationTarget,
        baseScale = uiScale.Scale,
        baseRotation = rotationTarget and rotationTarget.Rotation or 0,
        hoverScale = (type(options) == "table" and tonumber(options.HoverScale)) or HOVER_SCALE,
        pressScale = (type(options) == "table" and tonumber(options.PressScale)) or PRESS_SCALE,
        hoverRotation = (type(options) == "table" and tonumber(options.HoverRotation)) or 0,
        isHovered = false,
        isPressed = false,
        tweens = {},
        connections = {},
    }

    table.insert(binding.connections, button.MouseEnter:Connect(function()
        binding.isHovered = true
        self:_applyButtonState(binding)
    end))

    table.insert(binding.connections, button.MouseLeave:Connect(function()
        binding.isHovered = false
        binding.isPressed = false
        self:_applyButtonState(binding)
    end))

    table.insert(binding.connections, button.InputBegan:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = true
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = true
            end
            self:_applyButtonState(binding)
        end
    end))

    table.insert(binding.connections, button.InputEnded:Connect(function(inputObject)
        local inputType = inputObject.UserInputType
        if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
            binding.isPressed = false
            if inputType == Enum.UserInputType.Touch then
                binding.isHovered = false
            end
            self:_applyButtonState(binding)
        end
    end))

    table.insert(binding.connections, button.Activated:Connect(function()
        onActivated()
    end))

    table.insert(self._buttonBindings, binding)
end

function PotionController:_disconnectButtonBindings()
    for _, binding in ipairs(self._buttonBindings) do
        disconnectAll(binding.connections)
        for _, tween in pairs(binding.tweens) do
            tween:Cancel()
        end
        if binding.uiScale and binding.uiScale.Parent then
            binding.uiScale.Scale = binding.baseScale
        end
        if binding.rotationTarget and binding.rotationTarget.Parent then
            binding.rotationTarget.Rotation = binding.baseRotation
        end
    end
    table.clear(self._buttonBindings)
    self._boundPanel = nil
    self._boundEntry = nil
    self._boundFriendEntry = nil
end

function PotionController:_resolveEntryScaleTarget()
    if not self._entry then
        return nil
    end

    local icon = self._entry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    local label = self._entry:FindFirstChild("TextLabel", true)
    if label and label:IsA("GuiObject") then
        return label
    end

    return self._entry
end

function PotionController:_resolveEntryRotationTarget()
    if not self._entry then
        return nil
    end

    local icon = self._entry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    return self:_resolveEntryScaleTarget()
end

function PotionController:_resolveFriendScaleTarget()
    if not self._friendEntry then
        return nil
    end

    local icon = self._friendEntry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    local label = self._friendEntry:FindFirstChild("TextLabel", true)
    if label and label:IsA("GuiObject") then
        return label
    end

    return self._friendEntry
end

function PotionController:_resolveFriendRotationTarget()
    if not self._friendEntry then
        return nil
    end

    local icon = self._friendEntry:FindFirstChild("Icon", true)
    if icon and icon:IsA("GuiObject") then
        return icon
    end

    return self:_resolveFriendScaleTarget()
end

function PotionController:_findFriendEntry(mainGui)
    if not mainGui then
        return nil
    end

    local bottomLeft = mainGui:FindFirstChild("BottomLeft")
    local potionEntry = bottomLeft and bottomLeft:FindFirstChild("Potion")
    local nestedFriend = potionEntry and potionEntry:FindFirstChild("Friend")
    if nestedFriend and nestedFriend:IsA("GuiObject") then
        return nestedFriend
    end

    local siblingFriend = bottomLeft and bottomLeft:FindFirstChild("Friend")
    if siblingFriend and siblingFriend:IsA("GuiObject") then
        return siblingFriend
    end

    return nil
end

function PotionController:_findLuckLabel()
    if not self._mainGui then
        return nil
    end

    local left = self._mainGui:FindFirstChild("Left")
    local lucky = left and (left:FindFirstChild("Lucky") or left:FindFirstChild("Luck"))
    local luckLabel = lucky and lucky:FindFirstChild("LuckLabel", true)
    if luckLabel and (luckLabel:IsA("TextLabel") or luckLabel:IsA("TextButton") or luckLabel:IsA("TextBox")) then
        return luckLabel
    end

    local fallback = self._mainGui:FindFirstChild("LuckLabel", true)
    if fallback and (fallback:IsA("TextLabel") or fallback:IsA("TextButton") or fallback:IsA("TextBox")) then
        return fallback
    end

    return nil
end

function PotionController:_findCashFriendBonusLabel()
    if not self._mainGui then
        return nil
    end

    local cash = self._mainGui:FindFirstChild("Cash")
    local friendBonus = cash and cash:FindFirstChild("FriendBonus", true)
    if friendBonus and (friendBonus:IsA("TextLabel") or friendBonus:IsA("TextButton") or friendBonus:IsA("TextBox")) then
        return friendBonus
    end

    return nil
end

function PotionController:_sendPotionAction(action, potionId)
    if not self._requestPotionActionEvent then
        return
    end

    self._requestPotionActionEvent:FireServer({
        action = action,
        potionId = potionId,
    })
end

function PotionController:_promptGameInvite()
    if not self._localPlayer then
        return
    end

    task.spawn(function()
        local canInvite = true
        local canCheck = pcall(function()
            canInvite = SocialService:CanSendGameInviteAsync(self._localPlayer)
        end)
        if not canCheck then
            canInvite = true
        end
        if not canInvite then
            return
        end

        pcall(function()
            SocialService:PromptGameInvite(self._localPlayer)
        end)
    end)
end

function PotionController:_bindBuffSlot(slot)
    local frame = self._panel and self._panel:FindFirstChild(slot.Name)
    local potion = PotionConfig.GetPotion(slot.PotionId)
    if not (frame and frame:IsA("GuiObject") and potion) then
        return
    end

    local binding = {
        frame = frame,
        potion = potion,
        potionKey = getPotionKey(potion.Id),
        title = frame:FindFirstChild("Title", true),
        icon = frame:FindFirstChild("Icon", true),
        countdown = frame:FindFirstChild("CountDownTime", true),
        diamondButton = frame:FindFirstChild("DiamondButton", true),
        rbxButton = frame:FindFirstChild("RbxButton", true),
    }
    binding.useText = binding.diamondButton and binding.diamondButton:FindFirstChild("UseText", true) or nil
    binding.robuxPrice = binding.rbxButton and binding.rbxButton:FindFirstChild("Price", true) or nil

    setText(binding.title, potion.Name)
    setImage(binding.icon, potion.IconImage)
    setText(binding.robuxPrice, math.max(0, math.floor(tonumber(potion.RobuxPrice) or 0)))
    setMarketplaceRobuxPrice(binding.robuxPrice, potion.ProductId)

    if binding.diamondButton and binding.diamondButton:IsA("GuiButton") then
        self:_bindButton(binding.diamondButton, function()
            local inventoryCount = self:_getPotionInventoryCount(potion.Id)
            if inventoryCount > 0 then
                self:_sendPotionAction("Use", potion.Id)
            else
                self:_sendPotionAction("BuyDiamond", potion.Id)
            end
        end, {
            ScaleTarget = binding.diamondButton,
            HoverScale = HOVER_SCALE,
            PressScale = PRESS_SCALE,
        })
    end

    if binding.rbxButton and binding.rbxButton:IsA("GuiButton") then
        self:_bindButton(binding.rbxButton, function()
            if self._localPlayer and tonumber(potion.ProductId) then
                MarketplaceService:PromptProductPurchase(self._localPlayer, potion.ProductId)
            end
        end, {
            ScaleTarget = binding.rbxButton,
            HoverScale = HOVER_SCALE,
            PressScale = PRESS_SCALE,
        })
    end

    table.insert(self._buffBindings, binding)
end

function PotionController:_getPotionInventoryCount(potionId)
    local potionKey = getPotionKey(potionId)
    local potions = self._latestState and self._latestState.potions or nil
    if not (potionKey and type(potions) == "table") then
        return 0
    end

    return math.max(0, math.floor(tonumber(potions[potionKey] or potions[tonumber(potionId)]) or 0))
end

function PotionController:_getActivePotion(potionId)
    local potionKey = getPotionKey(potionId)
    local activePotions = self._latestState and self._latestState.activePotions or nil
    if not (potionKey and type(activePotions) == "table") then
        return nil
    end

    local activePotion = activePotions[potionKey] or activePotions[tonumber(potionId)]
    if type(activePotion) ~= "table" then
        return nil
    end

    local expiresAt = tonumber(activePotion.ExpiresAt or activePotion.expiresAt) or 0
    if expiresAt <= os.time() then
        return nil
    end

    return activePotion
end

function PotionController:_getActivePotionExperienceBonusTotal()
    local activePotions = self._latestState and self._latestState.activePotions or nil
    if type(activePotions) ~= "table" then
        return 0
    end

    local totalBonus = 0
    local countedByPotionKey = {}
    for potionId, activePotion in pairs(activePotions) do
        if type(activePotion) == "table" then
            local resolvedPotionId = activePotion.Id or activePotion.id or activePotion.PotionId or activePotion.potionId or potionId
            local potionKey = getPotionKey(resolvedPotionId)
            local expiresAt = tonumber(activePotion.ExpiresAt or activePotion.expiresAt) or 0
            if potionKey and not countedByPotionKey[potionKey] and expiresAt > os.time() then
                local potion = PotionConfig.GetPotion(resolvedPotionId)
                local experienceBonus = tonumber(activePotion.ExperienceBonus or activePotion.experienceBonus)
                if experienceBonus == nil and potion then
                    experienceBonus = tonumber(potion.ExperienceBonus)
                end

                totalBonus += math.max(0, experienceBonus or 0)
                countedByPotionKey[potionKey] = true
            end
        end
    end

    return totalBonus
end

function PotionController:_updateBuffBinding(binding)
    local potion = binding.potion
    local inventoryCount = self:_getPotionInventoryCount(potion.Id)
    local activePotion = self:_getActivePotion(potion.Id)

    if binding.countdown and binding.countdown:IsA("GuiObject") then
        if activePotion then
            binding.countdown.Visible = true
            setText(binding.countdown, formatCountdown((tonumber(activePotion.ExpiresAt or activePotion.expiresAt) or 0) - os.time()))
        else
            binding.countdown.Visible = false
        end
    end

    if inventoryCount > 0 then
        setText(binding.useText, "Use（" .. tostring(inventoryCount) .. "）")
    else
        setText(binding.useText, math.max(0, math.floor(tonumber(potion.DiamondPrice) or 0)))
    end
end

function PotionController:_updateUi()
    for _, binding in ipairs(self._buffBindings) do
        self:_updateBuffBinding(binding)
    end

    local hasUsablePotion = false
    local potions = self._latestState.potions
    if type(potions) == "table" then
        for _, potion in ipairs(PotionConfig.GetAllPotions()) do
            if self:_getPotionInventoryCount(potion.Id) > 0 then
                hasUsablePotion = true
                break
            end
        end
    end

    local redPoint = self._entry and self._entry:FindFirstChild("RedPoint", true)
    if redPoint and redPoint:IsA("GuiObject") then
        redPoint.Visible = hasUsablePotion
    end

    local potionAdd = self._entry and self._entry:FindFirstChild("Add")
    if potionAdd and potionAdd:IsA("GuiObject") then
        local potionBonusTotal = self:_getActivePotionExperienceBonusTotal()
        potionAdd.Visible = potionBonusTotal > 0
        setTextColor(potionAdd, potionBonusTotal > 0 and FRIEND_BONUS_ACTIVE_COLOR or FRIEND_BONUS_ZERO_COLOR)
        if potionBonusTotal > 0 then
            setText(potionAdd, "+" .. trimNumber(potionBonusTotal * 100) .. "%")
        end
    end

    local friendBonusPercent = math.max(0, math.floor(tonumber(self._latestState.friendBonusPercent) or 0))
    local friendAdd = self._friendEntry and self._friendEntry:FindFirstChild("Add", true)
    setText(friendAdd, tostring(friendBonusPercent) .. "%")
    setTextColor(friendAdd, friendBonusPercent > 0 and FRIEND_BONUS_ACTIVE_COLOR or FRIEND_BONUS_ZERO_COLOR)

    local cashFriendBonus = self:_findCashFriendBonusLabel()
    setText(cashFriendBonus, "Friend Bonus: +" .. tostring(friendBonusPercent) .. "%")
    setTextColor(cashFriendBonus, friendBonusPercent > 0 and FRIEND_BONUS_ACTIVE_COLOR or FRIEND_BONUS_ZERO_COLOR)

    local luckLabel = self:_findLuckLabel()
    if luckLabel then
        setText(luckLabel, formatMultiplier(self._latestState.totalExperienceMultiplier or 1))
    end
end

function PotionController:_applyPayload(payload)
    if type(payload) ~= "table" then
        return
    end

    self._latestState.diamonds = payload.diamonds or payload.Diamonds or self._latestState.diamonds or 0
    self._latestState.potions = type(payload.potions) == "table" and payload.potions or type(payload.Potions) == "table" and payload.Potions or self._latestState.potions or {}
    self._latestState.activePotions = getActivePotionsFromPayload(payload)
    self._latestState.friendExperienceBonus = tonumber(payload.friendExperienceBonus or payload.FriendExperienceBonus) or self._latestState.friendExperienceBonus or 0
    self._latestState.friendBonusPercent = math.max(0, math.floor(tonumber(payload.friendBonusPercent or payload.FriendBonusPercent) or ((self._latestState.friendExperienceBonus or 0) * 100) or 0))
    self._latestState.totalExperienceMultiplier = tonumber(payload.totalExperienceMultiplier or payload.TotalExperienceMultiplier) or self._latestState.totalExperienceMultiplier or 1
    self:_updateUi()
end

function PotionController:_queueDeferredBind()
    if self._deferredBindQueued then
        return
    end

    self._deferredBindQueued = true
    task.defer(function()
        self._deferredBindQueued = false
        if not self:_bindUi(true) then
            self:_queueBindRetry()
        end
    end)
end

function PotionController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end

    self._bindRetryQueued = true
    self._bindRetryToken += 1
    local retryToken = self._bindRetryToken
    task.spawn(function()
        local warningClock = os.clock() + BIND_RETRY_WARNING_SECONDS
        local warned = false
        while self._bindRetryQueued and self._bindRetryToken == retryToken do
            if self:_bindUi(true) then
                if self._bindRetryToken == retryToken then
                    self._bindRetryQueued = false
                end
                return
            end

            if not warned and os.clock() >= warningClock then
                warned = true
                warn("[PotionController] 暂未找到 PlayerGui/Main/Potion 或 Friend，继续等待界面复制完成。")
            end

            task.wait(BIND_RETRY_INTERVAL_SECONDS)
        end
    end)
end

function PotionController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    self._panel = mainGui and mainGui:FindFirstChild("Potion") or nil
    local bottomLeft = mainGui and mainGui:FindFirstChild("BottomLeft") or nil
    self._entry = bottomLeft and bottomLeft:FindFirstChild("Potion") or nil
    self._friendEntry = self:_findFriendEntry(mainGui)

    local hasPotionPanel = self._panel and self._panel:IsA("GuiObject")
    local hasPotionEntry = self._entry and self._entry:IsA("GuiObject")
    local hasFriendEntry = self._friendEntry and self._friendEntry:IsA("GuiObject")
    local isSameBinding = self._boundPanel == self._panel
        and self._boundEntry == self._entry
        and self._boundFriendEntry == self._friendEntry
    if not ((hasPotionPanel and hasPotionEntry) or hasFriendEntry) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    if isSameBinding then
        self:_updateUi()
        return hasPotionPanel and hasPotionEntry and hasFriendEntry
    end

    self:_disconnectButtonBindings()
    table.clear(self._buffBindings)
    if self._isPanelOpen and hasPotionPanel then
        ModalUiController:Acquire("Potion", self._panel)
        self._panel.Visible = true
    else
        self:_setPanelOpen(false, true)
    end

    local openButton = hasPotionEntry and self._entry:FindFirstChild("TextButton", true) or nil
    local closeButton = hasPotionPanel and self._panel:FindFirstChild("CloseButton", true) or nil
    local entryScaleTarget = self:_resolveEntryScaleTarget()
    local entryRotationTarget = self:_resolveEntryRotationTarget()
    local friendButton = hasFriendEntry and self._friendEntry:FindFirstChild("TextButton", true) or nil
    local friendScaleTarget = self:_resolveFriendScaleTarget()
    local friendRotationTarget = self:_resolveFriendRotationTarget()

    if hasPotionPanel and hasPotionEntry then
        self:_bindButton(openButton, function()
            self:_setPanelOpen(true)
            self:_updateUi()
        end, {
            ScaleTarget = entryScaleTarget or openButton,
            RotationTarget = entryRotationTarget,
            HoverScale = ENTRY_HOVER_SCALE,
            PressScale = ENTRY_PRESS_SCALE,
            HoverRotation = HOVER_ROTATION,
        })

        self:_bindButton(closeButton, function()
            self:_setPanelOpen(false)
        end, {
            ScaleTarget = closeButton,
            RotationTarget = closeButton,
            HoverScale = 1.12,
            PressScale = 0.92,
            HoverRotation = HOVER_ROTATION,
        })

        for _, slot in ipairs(BUFF_SLOTS) do
            self:_bindBuffSlot(slot)
        end
    end

    self:_bindButton(friendButton, function()
        self:_promptGameInvite()
    end, {
        ScaleTarget = friendScaleTarget or friendButton,
        RotationTarget = friendRotationTarget,
        HoverScale = ENTRY_HOVER_SCALE,
        PressScale = ENTRY_PRESS_SCALE,
        HoverRotation = HOVER_ROTATION,
    })

    self:_updateUi()
    self._boundPanel = self._panel
    self._boundEntry = self._entry
    self._boundFriendEntry = self._friendEntry
    return hasPotionPanel and hasPotionEntry and hasFriendEntry
end

function PotionController:RefreshNow()
    self:_updateUi()
end

function PotionController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._bindRetryToken += 1
    self._bindRetryQueued = false
    self._deferredBindQueued = false
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()
    table.clear(self._buffBindings)

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
    self._requestPotionActionEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestPotionAction)
    self._requestStateSyncEvent = systemEventsFolder:FindFirstChild(RemoteNames.System.RequestPlayerStateSync)
    local playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
    local potionFeedbackEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PotionFeedback)

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    table.insert(self._connections, playerStateSyncEvent.OnClientEvent:Connect(function(payload)
        self:_applyPayload(payload)
    end))

    table.insert(self._connections, potionFeedbackEvent.OnClientEvent:Connect(function(payload)
        self:_applyPayload(payload)
    end))

    table.insert(self._connections, RunService.Heartbeat:Connect(function()
        self:_updateUi()
    end))

    if self._requestStateSyncEvent and self._requestStateSyncEvent:IsA("RemoteEvent") then
        self._requestStateSyncEvent:FireServer()
    end

    local playerGui = self._localPlayer and (self._localPlayer:FindFirstChild("PlayerGui") or self._localPlayer:WaitForChild("PlayerGui", 10))
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                self:_queueDeferredBind()
            end
        end))

        table.insert(self._connections, playerGui.DescendantAdded:Connect(function(descendant)
            local name = descendant.Name
            if name == "Main" or name == "Potion" or name == "BottomLeft" or name == "Friend" then
                self:_queueDeferredBind()
            end
        end))
    end
end

return PotionController
