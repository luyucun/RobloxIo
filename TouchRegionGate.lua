--[[
Script: TouchRegionGate
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/TouchRegionGate
Purpose: Shared client-side touch-region gate that opens once per entry and re-arms only after the local character leaves.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local TouchRegionGate = {}
TouchRegionGate.__index = TouchRegionGate

local function disconnectAll(connections)
    for _, connection in ipairs(connections or {}) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function getCharacter(localPlayer)
    return localPlayer and localPlayer.Character or nil
end

local function getRaycastIncludeFilterType()
    local success, includeFilterType = pcall(function()
        return Enum.RaycastFilterType.Include
    end)
    if success and includeFilterType then
        return includeFilterType
    end
    return Enum.RaycastFilterType.Whitelist
end

local function isCharacterPart(localPlayer, part)
    local character = localPlayer and localPlayer.Character
    return part and character and part:IsDescendantOf(character) or false
end

local RAYCAST_FILTER_INCLUDE = getRaycastIncludeFilterType()
local DEFAULT_BOUNDS_PADDING = Vector3.new(1, 6, 1)

local function isRootPartInsideRegionPart(rootPart, regionPart)
    if not (rootPart and regionPart and regionPart:IsA("BasePart")) then
        return false
    end

    local localPosition = regionPart.CFrame:PointToObjectSpace(rootPart.Position)
    local halfSize = (regionPart.Size * 0.5) + DEFAULT_BOUNDS_PADDING
    return math.abs(localPosition.X) <= halfSize.X
        and math.abs(localPosition.Y) <= halfSize.Y
        and math.abs(localPosition.Z) <= halfSize.Z
end

local function isCharacterInsideRegion(regionParts, character)
    if #regionParts <= 0 or not character then
        return false
    end

    local rootPart = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
    if rootPart then
        for _, regionPart in ipairs(regionParts) do
            if regionPart and regionPart.Parent and isRootPartInsideRegionPart(rootPart, regionPart) then
                return true
            end
        end
    end

    local overlapParams = OverlapParams.new()
    overlapParams.FilterType = RAYCAST_FILTER_INCLUDE
    overlapParams.FilterDescendantsInstances = { character }

    for _, regionPart in ipairs(regionParts) do
        if regionPart and regionPart.Parent and regionPart:IsA("BasePart") then
            local success, touchingParts = pcall(function()
                return Workspace:GetPartsInPart(regionPart, overlapParams)
            end)
            if success and type(touchingParts) == "table" and #touchingParts > 0 then
                return true
            end
        end
    end

    return false
end

function TouchRegionGate.new(options)
    local self = setmetatable({}, TouchRegionGate)
    self._localPlayer = options and options.LocalPlayer or nil
    self._region = options and options.Region or nil
    self._onEnter = options and options.OnEnter or nil
    self._label = tostring(options and options.Label or "TouchRegion")
    self._checkInterval = math.max(0.05, tonumber(options and options.CheckInterval) or 0.2)
    self._connections = {}
    self._regionParts = {}
    self._regionPartSet = {}
    self._isInside = false
    self._accumulator = 0
    self._running = false
    return self
end

function TouchRegionGate:_bindRegionPart(part)
    if not (part and part:IsA("BasePart")) then
        return false
    end
    if self._regionPartSet[part] then
        return true
    end

    part.CanTouch = true
    part.CanQuery = true
    self._regionPartSet[part] = true
    table.insert(self._regionParts, part)
    table.insert(self._connections, part.Touched:Connect(function(hit)
        self:_handleTouched(hit)
    end))
    return true
end

function TouchRegionGate:_refreshRegionParts()
    local countBefore = #self._regionParts
    self:_bindRegionPart(self._region)

    if self._region then
        for _, descendant in ipairs(self._region:GetDescendants()) do
            self:_bindRegionPart(descendant)
        end
    end

    return #self._regionParts > countBefore
end

function TouchRegionGate:_handleTouched(hit)
    if self._isInside then
        return
    end

    if not isCharacterPart(self._localPlayer, hit) then
        return
    end

    self._isInside = true
    if type(self._onEnter) == "function" then
        self._onEnter(hit)
    end
end

function TouchRegionGate:_step(deltaTime)
    self:_refreshRegionParts()

    self._accumulator += deltaTime or 0
    if self._accumulator < self._checkInterval then
        return
    end
    self._accumulator = 0

    local character = getCharacter(self._localPlayer)
    local isInsideNow = isCharacterInsideRegion(self._regionParts, character)
    if self._isInside then
        if not isInsideNow then
            self._isInside = false
        end
        return
    end

    if isInsideNow then
        self._isInside = true
        if type(self._onEnter) == "function" then
            self._onEnter(nil)
        end
    end
end

function TouchRegionGate:_resetInsideOnCharacterChanged()
    if self._localPlayer then
        table.insert(self._connections, self._localPlayer.CharacterAdded:Connect(function()
            self._isInside = false
            self._accumulator = 0
        end))
        table.insert(self._connections, self._localPlayer.CharacterRemoving:Connect(function()
            self._isInside = false
            self._accumulator = 0
        end))
    end
end

function TouchRegionGate:_handleRegionPartRemoved()
    for index = #self._regionParts, 1, -1 do
        local part = self._regionParts[index]
        if not (part and part.Parent) then
            self._regionPartSet[part] = nil
            table.remove(self._regionParts, index)
        end
    end
    if #self._regionParts <= 0 then
        self._isInside = false
    end
end

function TouchRegionGate:Start()
    self:Stop()
    if not self._region then
        warn(string.format("[TouchRegionGate] %s has no region root.", self._label))
        return false
    end

    self._running = true
    self:_refreshRegionParts()
    self:_resetInsideOnCharacterChanged()

    table.insert(self._connections, self._region.DescendantAdded:Connect(function(descendant)
        if self._running ~= true then
            return
        end
        self:_bindRegionPart(descendant)
    end))

    table.insert(self._connections, RunService.Heartbeat:Connect(function(deltaTime)
        self:_step(deltaTime)
    end))

    return true
end

function TouchRegionGate:Stop()
    self._running = false
    disconnectAll(self._connections)
    self._regionParts = {}
    self._regionPartSet = {}
    self._isInside = false
    self._accumulator = 0
end

return TouchRegionGate
