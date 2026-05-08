--[[
Script: MonetizationController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/MonetizationController
Purpose: Binds V1.5 paid feature buttons to Developer Product purchase prompts.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

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
        "[MonetizationController] Missing shared module %s (expected in ReplicatedStorage/Shared or ReplicatedStorage root)",
        tostring(moduleName or "")
    ))
end

local GameConfig = requireSharedModule("GameConfig")

local MonetizationController = {}

MonetizationController._localPlayer = nil
MonetizationController._connections = {}
MonetizationController._buttonBindings = {}
MonetizationController._mainGui = nil
MonetizationController._bindRetryQueued = false

local HOVER_SCALE = 1.04
local PRESS_SCALE = 0.92
local HOVER_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local PRESS_TWEEN_INFO = TweenInfo.new(0.06, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local RESET_TWEEN_INFO = TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function findMainGui(localPlayer)
    local playerGui = localPlayer and (localPlayer:FindFirstChild("PlayerGui") or localPlayer:WaitForChild("PlayerGui", 5))
    if not playerGui then
        return nil
    end

    return playerGui:FindFirstChild("Main") or playerGui:FindFirstChild("Main", true)
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

local function findButton(root, name)
    local candidate = root and root:FindFirstChild(name, true)
    if not candidate then
        return nil, nil
    end

    if candidate:IsA("GuiButton") then
        return candidate, candidate
    end

    if candidate:IsA("GuiObject") then
        local nestedButton = candidate:FindFirstChildWhichIsA("GuiButton", true)
        if nestedButton then
            return nestedButton, candidate
        end
    end

    return nil, nil
end

function MonetizationController:_cancelBindingTween(binding)
    if binding.tween then
        binding.tween:Cancel()
        binding.tween = nil
    end
end

function MonetizationController:_applyButtonState(binding)
    local scale = binding.baseScale
    local tweenInfo = RESET_TWEEN_INFO
    if binding.isPressed then
        scale = binding.baseScale * PRESS_SCALE
        tweenInfo = PRESS_TWEEN_INFO
    elseif binding.isHovered then
        scale = binding.baseScale * HOVER_SCALE
        tweenInfo = HOVER_TWEEN_INFO
    end

    self:_cancelBindingTween(binding)
    local tween = TweenService:Create(binding.uiScale, tweenInfo, {
        Scale = scale,
    })
    binding.tween = tween
    tween.Completed:Connect(function()
        if binding.tween == tween then
            binding.tween = nil
        end
    end)
    tween:Play()
end

function MonetizationController:_promptProduct(productId)
    local resolvedProductId = tonumber(productId) or 0
    if resolvedProductId <= 0 then
        warn("[MonetizationController] Invalid Developer Product id.")
        return
    end
    if not (self._localPlayer and self._localPlayer.Parent) then
        return
    end

    MarketplaceService:PromptProductPurchase(self._localPlayer, resolvedProductId)
end

function MonetizationController:_bindButton(button, scaleTarget, productId)
    if not (button and button:IsA("GuiButton") and scaleTarget and scaleTarget:IsA("GuiObject")) then
        return false
    end

    local uiScale = ensureUiScale(scaleTarget)
    if not uiScale then
        return false
    end

    local binding = {
        button = button,
        scaleTarget = scaleTarget,
        uiScale = uiScale,
        baseScale = uiScale.Scale,
        productId = productId,
        isHovered = false,
        isPressed = false,
        tween = nil,
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
        self:_promptProduct(binding.productId)
    end))

    table.insert(self._buttonBindings, binding)
    return true
end

function MonetizationController:_disconnectButtonBindings()
    for _, binding in ipairs(self._buttonBindings) do
        self:_cancelBindingTween(binding)
        disconnectAll(binding.connections)
        if binding.uiScale and binding.uiScale.Parent then
            binding.uiScale.Scale = binding.baseScale or 1
        end
    end
    table.clear(self._buttonBindings)
end

function MonetizationController:_queueBindRetry()
    if self._bindRetryQueued then
        return
    end

    self._bindRetryQueued = true
    task.spawn(function()
        local deadline = os.clock() + 12
        repeat
            if self:_bindUi(true) then
                self._bindRetryQueued = false
                return
            end
            task.wait(0.5)
        until os.clock() >= deadline
        self._bindRetryQueued = false
        warn("[MonetizationController] Could not find PlayerGui/Main/Bottom/Double and PlayerGui/Main/Bottom/Nuke.")
    end)
end

function MonetizationController:_bindUi(silent)
    local mainGui = findMainGui(self._localPlayer)
    self._mainGui = mainGui
    local bottomRoot = mainGui and mainGui:FindFirstChild("Bottom")
    local doubleButton, doubleScaleTarget = findButton(bottomRoot, "Double")
    local nukeButton, nukeScaleTarget = findButton(bottomRoot, "Nuke")

    if not (doubleButton and nukeButton) then
        if not silent then
            self:_queueBindRetry()
        end
        return false
    end

    self:_disconnectButtonBindings()
    self:_bindButton(doubleButton, doubleScaleTarget, GameConfig.MONETIZATION and GameConfig.MONETIZATION.DoubleLevelProductId)
    self:_bindButton(nukeButton, nukeScaleTarget, GameConfig.MONETIZATION and GameConfig.MONETIZATION.NukeProductId)
    return true
end

function MonetizationController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    disconnectAll(self._connections)
    self:_disconnectButtonBindings()

    if not self:_bindUi(true) then
        self:_queueBindRetry()
    end

    local playerGui = self._localPlayer and self._localPlayer:FindFirstChild("PlayerGui")
    if playerGui then
        table.insert(self._connections, playerGui.ChildAdded:Connect(function(child)
            if child.Name == "Main" then
                task.defer(function()
                    self:_bindUi()
                end)
            end
        end))
    end
end

return MonetizationController
