--[[
脚本名字: BossHitFeedbackController
脚本文件: BossHitFeedbackController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/BossHitFeedbackController
说明: V3.7 Boss 受击反馈，本地播放 Highlight、爆点、弹动、伤害数字和血条反馈。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

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
        "[BossHitFeedbackController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local BossHitFeedbackController = {}

BossHitFeedbackController._localPlayer = nil
BossHitFeedbackController._audioSettings = nil
BossHitFeedbackController._connection = nil
BossHitFeedbackController._lastHighlightClockByBossId = {}
BossHitFeedbackController._lastImpactClockByBossId = {}
BossHitFeedbackController._lastOwnImpactClockByBossId = {}
BossHitFeedbackController._lastBounceClockByBossId = {}
BossHitFeedbackController._lastHealthRatioByBossId = {}
BossHitFeedbackController._damageBuckets = {}

local HIGHLIGHT_COOLDOWN_SECONDS = 0.1
local IMPACT_COOLDOWN_SECONDS = 0.08
local OWN_IMPACT_COOLDOWN_SECONDS = 0.06
local BOUNCE_COOLDOWN_SECONDS = 0.2
local DAMAGE_MERGE_SECONDS = 0.25

local function disconnectConnection(connection)
    if connection and connection.Connected then
        connection:Disconnect()
    end
end

local function getRuntimeMonstersFolder()
    local runtimeRoot = Workspace:FindFirstChild("Runtime")
    if not runtimeRoot then
        return nil
    end
    return runtimeRoot:FindFirstChild("Monsters")
end

local function getBossIdKey(bossId)
    return tostring(bossId or "")
end

local function findBossInstance(bossId)
    local resolvedBossId = tonumber(bossId)
    if not resolvedBossId then
        return nil
    end

    local monstersFolder = getRuntimeMonstersFolder()
    if not monstersFolder then
        return nil
    end

    for _, instance in ipairs(monstersFolder:GetChildren()) do
        if tonumber(instance:GetAttribute("MonsterId")) == resolvedBossId and instance:GetAttribute("IsBoss") == true then
            return instance
        end
    end
    return nil
end

local function getBossCenter(instance)
    if not instance then
        return nil
    end
    if instance:IsA("Model") then
        return instance:GetPivot().Position
    end
    if instance:IsA("BasePart") then
        return instance.Position
    end
    return nil
end

local function getBossHeight(instance)
    if not instance then
        return 8
    end
    if instance:IsA("Model") then
        local _, size = instance:GetBoundingBox()
        return math.max(1, size.Y)
    end
    if instance:IsA("BasePart") then
        return math.max(1, instance.Size.Y)
    end
    return 8
end

local function getBossAdornee(instance)
    if not instance then
        return nil
    end
    if instance:IsA("BasePart") then
        return instance
    end
    if instance:IsA("Model") then
        return instance.PrimaryPart or instance:FindFirstChild("Root", true) or instance:FindFirstChildWhichIsA("BasePart", true)
    end
    return nil
end

local function setWorldCFrame(instance, cframe)
    if instance:IsA("Model") then
        instance:PivotTo(cframe)
    elseif instance:IsA("BasePart") then
        instance.CFrame = cframe
    end
end

local function getWorldCFrame(instance)
    if instance:IsA("Model") then
        return instance:GetPivot()
    end
    if instance:IsA("BasePart") then
        return instance.CFrame
    end
    return nil
end

local function getEffectTemplate()
    local effectFolder = ReplicatedStorage:FindFirstChild("Effect")
    local template = effectFolder and effectFolder:FindFirstChild("BossHitImpact")
    if template and (template:IsA("BasePart") or template:IsA("Model") or template:IsA("Attachment")) then
        return template
    end
    return nil
end

local function setEffectCFrame(effect, cframe)
    if effect:IsA("Model") then
        effect:PivotTo(cframe)
    elseif effect:IsA("BasePart") then
        effect.CFrame = cframe
    elseif effect:IsA("Attachment") then
        effect.WorldCFrame = cframe
    end
end

local function createAttachmentEffectContainer(attachmentTemplate, cframe)
    local part = Instance.new("Part")
    part.Name = "BossHitImpact_Client"
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.Transparency = 1
    part.Size = Vector3.new(0.2, 0.2, 0.2)
    part.CFrame = cframe

    local attachment = attachmentTemplate:Clone()
    attachment.Name = "BossHitImpactAttachment"
    attachment.Parent = part
    return part
end

local function offsetUDim2(position, offsetX, offsetY)
    return UDim2.new(
        position.X.Scale,
        position.X.Offset + offsetX,
        position.Y.Scale,
        position.Y.Offset + offsetY
    )
end

local function configureEffectInstance(effect)
    if effect:IsA("BasePart") then
        effect.Anchored = true
        effect.CanCollide = false
        effect.CanTouch = false
        effect.CanQuery = false
    end
    for _, descendant in ipairs(effect:GetDescendants()) do
        if descendant:IsA("BasePart") then
            descendant.Anchored = true
            descendant.CanCollide = false
            descendant.CanTouch = false
            descendant.CanQuery = false
        end
    end
end

local function emitParticles(container, ownHit)
    for _, descendant in ipairs(container:GetDescendants()) do
        if descendant:IsA("ParticleEmitter") then
            local emitCount = tonumber(descendant:GetAttribute("EmitCount")) or (ownHit and 14 or 8)
            descendant:Emit(math.clamp(math.floor(emitCount), 1, 20))
        elseif descendant:IsA("PointLight") then
            descendant.Enabled = true
            TweenService:Create(descendant, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Brightness = 0,
                Range = math.max(0, descendant.Range * 0.65),
            }):Play()
        end
    end
end

local function createFallbackImpact(position, ownHit)
    local part = Instance.new("Part")
    part.Name = "BossHitImpact_Client"
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.Transparency = 1
    part.Size = Vector3.new(0.2, 0.2, 0.2)
    part.CFrame = CFrame.new(position)

    local attachment = Instance.new("Attachment")
    attachment.Name = "Impact"
    attachment.Parent = part

    local sparks = Instance.new("ParticleEmitter")
    sparks.Name = "HitSpark"
    sparks.Color = ColorSequence.new(Color3.fromRGB(255, 246, 205), Color3.fromRGB(255, 209, 82))
    sparks.LightEmission = 0.8
    sparks.Lifetime = NumberRange.new(0.12, 0.22)
    sparks.Speed = NumberRange.new(6, 11)
    sparks.SpreadAngle = Vector2.new(65, 65)
    sparks.Rate = 0
    sparks.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, ownHit and 0.34 or 0.24),
        NumberSequenceKeypoint.new(1, 0),
    })
    sparks.Parent = attachment

    local dots = Instance.new("ParticleEmitter")
    dots.Name = "EnergyDot"
    dots.Color = ColorSequence.new(Color3.fromRGB(178, 210, 255), Color3.fromRGB(209, 162, 255))
    dots.LightEmission = 0.9
    dots.Lifetime = NumberRange.new(0.15, 0.24)
    dots.Speed = NumberRange.new(2, 5)
    dots.SpreadAngle = Vector2.new(180, 180)
    dots.Rate = 0
    dots.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, ownHit and 0.22 or 0.16),
        NumberSequenceKeypoint.new(1, 0),
    })
    dots.Parent = attachment

    local light = Instance.new("PointLight")
    light.Name = "ImpactLight"
    light.Color = Color3.fromRGB(255, 231, 156)
    light.Brightness = ownHit and 1.5 or 0.9
    light.Range = ownHit and 7 or 5
    light.Parent = part

    part.Parent = Workspace.CurrentCamera or Workspace
    sparks:Emit(ownHit and 12 or 7)
    dots:Emit(ownHit and 7 or 4)
    TweenService:Create(light, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Brightness = 0,
        Range = 0,
    }):Play()
    task.delay(0.3, function()
        if part and part.Parent then
            part:Destroy()
        end
    end)
end

local function ensureDamageNumberGui(bossInstance)
    local adornee = getBossAdornee(bossInstance)
    if not adornee then
        return nil
    end

    local gui = adornee:FindFirstChild("BossDamageNumbers_Client")
    if gui and gui:IsA("BillboardGui") then
        return gui
    end

    gui = Instance.new("BillboardGui")
    gui.Name = "BossDamageNumbers_Client"
    gui.Adornee = adornee
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.Size = UDim2.fromOffset(220, 90)
    gui.StudsOffsetWorldSpace = Vector3.new(0, getBossHeight(bossInstance) * 0.55 + 2, 0)
    gui.Parent = adornee
    return gui
end

local function formatDamage(amount)
    local value = math.max(0, math.floor(tonumber(amount) or 0))
    if value >= 1000000 then
        return string.format("%.1fM", value / 1000000):gsub("%.0M", "M")
    end
    if value >= 1000 then
        return string.format("%.1fK", value / 1000):gsub("%.0K", "K")
    end
    return tostring(value)
end

local function getDamageColors(amount)
    local value = math.max(0, tonumber(amount) or 0)
    if value >= 10000 then
        return Color3.fromRGB(255, 139, 47), Color3.fromRGB(76, 40, 18)
    end
    if value >= 1000 then
        return Color3.fromRGB(255, 230, 92), Color3.fromRGB(196, 88, 24)
    end
    return Color3.fromRGB(255, 255, 255), Color3.fromRGB(38, 42, 56)
end

function BossHitFeedbackController:_playHighlight(bossId, bossInstance, now)
    if (self._lastHighlightClockByBossId[bossId] or 0) + HIGHLIGHT_COOLDOWN_SECONDS > now then
        return
    end
    self._lastHighlightClockByBossId[bossId] = now

    local highlight = bossInstance:FindFirstChild("BossHitHighlight")
    if not (highlight and highlight:IsA("Highlight")) then
        highlight = Instance.new("Highlight")
        highlight.Name = "BossHitHighlight"
        highlight.DepthMode = Enum.HighlightDepthMode.Occluded
        highlight.Parent = bossInstance
    end

    highlight.FillColor = Color3.fromRGB(255, 246, 214)
    highlight.OutlineColor = Color3.fromRGB(255, 211, 85)
    highlight.FillTransparency = 0.25
    highlight.OutlineTransparency = 0
    highlight.Enabled = true

    local tween = TweenService:Create(highlight, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        FillTransparency = 1,
        OutlineTransparency = 1,
    })
    tween:Play()
    tween.Completed:Connect(function()
        if highlight and highlight.Parent then
            highlight.Enabled = false
        end
    end)
end

function BossHitFeedbackController:_playImpact(bossId, bossInstance, hitPosition, ownHit, now)
    local lastMap = ownHit and self._lastOwnImpactClockByBossId or self._lastImpactClockByBossId
    local cooldown = ownHit and OWN_IMPACT_COOLDOWN_SECONDS or IMPACT_COOLDOWN_SECONDS
    if (lastMap[bossId] or 0) + cooldown > now then
        return
    end
    lastMap[bossId] = now

    local center = getBossCenter(bossInstance) or Vector3.zero
    local position = typeof(hitPosition) == "Vector3" and hitPosition or center
    if (position - center).Magnitude < 0.05 then
        local seed = now * 31 + (tonumber(bossId) or 1)
        position += Vector3.new(math.sin(seed), 0.35, math.cos(seed)) * math.max(0.8, getBossHeight(bossInstance) * 0.08)
    end

    local template = getEffectTemplate()
    if template then
        local effectCFrame = CFrame.new(position)
        local effect = template:IsA("Attachment") and createAttachmentEffectContainer(template, effectCFrame) or template:Clone()
        effect.Name = "BossHitImpact_Client"
        configureEffectInstance(effect)
        effect.Parent = Workspace.CurrentCamera or Workspace
        setEffectCFrame(effect, effectCFrame)
        emitParticles(effect, ownHit)
        task.delay(0.35, function()
            if effect and effect.Parent then
                effect:Destroy()
            end
        end)
        return
    end

    createFallbackImpact(position, ownHit)
end

function BossHitFeedbackController:_playBounce(bossId, bossInstance, now)
    if (self._lastBounceClockByBossId[bossId] or 0) + BOUNCE_COOLDOWN_SECONDS > now then
        return
    end
    self._lastBounceClockByBossId[bossId] = now

    local originalCFrame = getWorldCFrame(bossInstance)
    if not originalCFrame then
        return
    end

    local offset = Vector3.new(0.1, 0.04, 0)
    setWorldCFrame(bossInstance, originalCFrame * CFrame.new(offset))
    task.delay(0.055, function()
        if bossInstance and bossInstance.Parent then
            setWorldCFrame(bossInstance, originalCFrame * CFrame.new(-offset))
        end
    end)
    task.delay(0.11, function()
        if bossInstance and bossInstance.Parent then
            setWorldCFrame(bossInstance, originalCFrame)
        end
    end)
end

function BossHitFeedbackController:_showDamageNumber(bossInstance, amount)
    local gui = ensureDamageNumberGui(bossInstance)
    if not gui then
        return
    end

    local textColor, strokeColor = getDamageColors(amount)
    local label = Instance.new("TextLabel")
    label.Name = "DamageNumber"
    label.AnchorPoint = Vector2.new(0.5, 0.5)
    label.BackgroundTransparency = 1
    label.Position = UDim2.fromScale(0.5 + ((math.random() - 0.5) * 0.18), 0.65)
    label.Size = UDim2.fromOffset(140, 42)
    label.Font = Enum.Font.GothamBold
    label.Text = formatDamage(amount)
    label.TextColor3 = textColor
    label.TextScaled = true
    label.TextTransparency = 0
    label.Parent = gui

    local stroke = Instance.new("UIStroke")
    stroke.Color = strokeColor
    stroke.Thickness = 3
    stroke.Transparency = 0
    stroke.Parent = label

    local tween = TweenService:Create(label, TweenInfo.new(0.62, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        Position = UDim2.fromScale(label.Position.X.Scale, 0.15),
        Size = UDim2.fromOffset(170, 52),
        TextTransparency = 1,
    })
    local strokeTween = TweenService:Create(stroke, TweenInfo.new(0.62, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Transparency = 1,
    })
    tween:Play()
    strokeTween:Play()
    task.delay(0.7, function()
        if label and label.Parent then
            label:Destroy()
        end
    end)
end

function BossHitFeedbackController:_queueDamageNumber(bossId, bossInstance, amount)
    local bucket = self._damageBuckets[bossId]
    if not bucket then
        bucket = {
            Amount = 0,
            BossInstance = bossInstance,
        }
        self._damageBuckets[bossId] = bucket

        task.delay(DAMAGE_MERGE_SECONDS, function()
            local currentBucket = self._damageBuckets[bossId]
            if not currentBucket then
                return
            end

            self._damageBuckets[bossId] = nil
            if currentBucket.BossInstance and currentBucket.BossInstance.Parent and currentBucket.Amount > 0 then
                self:_showDamageNumber(currentBucket.BossInstance, currentBucket.Amount)
            end
        end)
    end

    bucket.Amount += math.max(0, math.floor(tonumber(amount) or 0))
    bucket.BossInstance = bossInstance
end

local function ensureHealthBarFeedbackLayers(bossInstance)
    local adornee = getBossAdornee(bossInstance)
    if not adornee then
        return nil, nil, nil, nil
    end

    local billboard = adornee:FindFirstChild("BossOverheadHealthBar")
    local root = billboard and billboard:FindFirstChild("Root")
    local barBackground = root and root:FindFirstChild("BarBackground")
    local fill = barBackground and barBackground:FindFirstChild("Fill")
    if not (billboard and root and barBackground and fill and fill:IsA("Frame")) then
        return nil, nil, nil, nil
    end

    local lagFill = barBackground:FindFirstChild("DamageLagFill")
    if not (lagFill and lagFill:IsA("Frame")) then
        lagFill = fill:Clone()
        lagFill.Name = "DamageLagFill"
        lagFill.BackgroundColor3 = Color3.fromRGB(255, 210, 92)
        lagFill.BackgroundTransparency = 0.18
        lagFill.ZIndex = math.max(0, fill.ZIndex - 1)
        lagFill.Parent = barBackground
    end

    local flash = barBackground:FindFirstChild("HitFlash")
    if not (flash and flash:IsA("Frame")) then
        flash = Instance.new("Frame")
        flash.Name = "HitFlash"
        flash.BorderSizePixel = 0
        flash.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
        flash.BackgroundTransparency = 1
        flash.Size = UDim2.fromScale(1, 1)
        flash.ZIndex = fill.ZIndex + 2
        flash.Parent = barBackground
        local corner = barBackground:FindFirstChildWhichIsA("UICorner")
        if corner then
            corner:Clone().Parent = flash
        end
    end

    return root, fill, lagFill, flash
end

function BossHitFeedbackController:_playHealthBarFeedback(bossId, bossInstance, remainingHealth, maxHealth)
    local root, fill, lagFill, flash = ensureHealthBarFeedbackLayers(bossInstance)
    if not root then
        return
    end

    local ratio = math.clamp((tonumber(remainingHealth) or 0) / math.max(1, tonumber(maxHealth) or 1), 0, 1)
    local previousRatio = self._lastHealthRatioByBossId[bossId]
    if previousRatio == nil then
        previousRatio = math.max(fill.Size.X.Scale, lagFill.Size.X.Scale, ratio)
    end
    self._lastHealthRatioByBossId[bossId] = ratio

    fill.Size = UDim2.fromScale(ratio, 1)
    lagFill.Size = UDim2.fromScale(math.max(previousRatio, ratio), 1)
    flash.BackgroundTransparency = 0.2

    TweenService:Create(flash, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        BackgroundTransparency = 1,
    }):Play()

    task.delay(0.25, function()
        if lagFill and lagFill.Parent then
            TweenService:Create(lagFill, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Size = UDim2.fromScale(ratio, 1),
            }):Play()
        end
    end)

    local originalPosition = root.Position
    TweenService:Create(root, TweenInfo.new(0.04, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Position = offsetUDim2(originalPosition, 5, 0),
    }):Play()
    task.delay(0.04, function()
        if root and root.Parent then
            TweenService:Create(root, TweenInfo.new(0.04, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Position = offsetUDim2(originalPosition, -4, 0),
            }):Play()
        end
    end)
    task.delay(0.08, function()
        if root and root.Parent then
            TweenService:Create(root, TweenInfo.new(0.04, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
                Position = originalPosition,
            }):Play()
        end
    end)
end

function BossHitFeedbackController:_handleBossHitFeedback(payload)
    if type(payload) ~= "table" then
        return
    end

    local bossId = getBossIdKey(payload.bossId)
    if bossId == "" then
        return
    end

    local bossInstance = findBossInstance(payload.bossId)
    if not bossInstance then
        return
    end

    local now = os.clock()
    local ownHit = tonumber(payload.attackerUserId) ~= nil and self._localPlayer and tonumber(payload.attackerUserId) == self._localPlayer.UserId
    self:_playHighlight(bossId, bossInstance, now)
    self:_playImpact(bossId, bossInstance, payload.hitPosition, ownHit == true, now)
    self:_playBounce(bossId, bossInstance, now)
    self:_playHealthBarFeedback(bossId, bossInstance, payload.remainingHealth, payload.maxHealth)

    if ownHit then
        if self._audioSettings and self._audioSettings.PlaySfxByPath then
            self._audioSettings:PlaySfxByPath("Audio", { "Sword", "SwordHitRelease" }, true)
        end
        self:_queueDamageNumber(bossId, bossInstance, payload.damage)
    end
end

function BossHitFeedbackController:Init(dependencies)
    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._audioSettings = dependencies and (dependencies.AudioSettingsController or dependencies.AudioSettings) or nil

    disconnectConnection(self._connection)
    self._connection = nil

    local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
    local battleEventsFolder = eventsFolder:WaitForChild(RemoteNames.BattleEventsFolder)
    local bossHitFeedbackEvent = battleEventsFolder:WaitForChild(RemoteNames.Battle.BossHitFeedback)
    self._connection = bossHitFeedbackEvent.OnClientEvent:Connect(function(payload)
        self:_handleBossHitFeedback(payload)
    end)
end

return BossHitFeedbackController
