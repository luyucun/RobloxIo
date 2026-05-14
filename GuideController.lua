--[[
脚本名字: GuideController
脚本文件: GuideController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/GuideController
说明: 客户端本地显示新手引导 Beam，完成首次入场后自动清理。
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
		"[GuideController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
		tostring(moduleName or "")
	))
end

local RemoteNames = requireSharedModule("RemoteNames")

local GuideController = {}

GuideController._localPlayer = nil
GuideController._connections = {}
GuideController._guideInstances = {}
GuideController._playerStateSyncEvent = nil
GuideController._requestStateSyncEvent = nil
GuideController._guideCompleted = true
GuideController._bindToken = 0

local GUIDE_FOLDER_NAME = "Guide"
local GUIDE_PLAYER_NAME = "Guide01"
local GUIDE_PORTAL_NAME = "Guide02"
local GUIDE_RUNTIME_NAME = "__LocalNewPlayerGuide"

local function disconnectAll(connections)
	for _, connection in ipairs(connections) do
		if connection and connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(connections)
end

local function setLocalPartPhysics(instance, anchored)
	if instance:IsA("BasePart") then
		instance.Anchored = anchored == true
		instance.CanCollide = false
		instance.CanTouch = false
		instance.CanQuery = false
		instance.Massless = true
	end

	for _, descendant in ipairs(instance:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.Anchored = anchored == true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Massless = true
		end
	end
end

local function findGuideTemplate(name)
	local effectFolder = ReplicatedStorage:FindFirstChild("Effect")
	local guideFolder = effectFolder and effectFolder:FindFirstChild(GUIDE_FOLDER_NAME)
	return guideFolder and guideFolder:FindFirstChild(name) or nil
end

local function findPortalPart()
	local map2 = Workspace:FindFirstChild("Map2")
	local portals = map2 and map2:FindFirstChild("Portals")
	local portalModel = portals and portals:FindFirstChild("Portal")
	local portalPart = portalModel and portalModel:FindFirstChild("PORTAL")
	if portalPart and portalPart:IsA("BasePart") then
		return portalPart
	end
	return nil
end

local function findCharacterRoot(character)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

function GuideController:_destroyGuide()
	for _, instance in ipairs(self._guideInstances) do
		if instance and instance.Parent then
			instance:Destroy()
		end
	end
	table.clear(self._guideInstances)
end

function GuideController:_cloneGuidePair(character, portalPart)
	local characterRoot = findCharacterRoot(character)
	local guide01Template = findGuideTemplate(GUIDE_PLAYER_NAME)
	local guide02Template = findGuideTemplate(GUIDE_PORTAL_NAME)
	if not (characterRoot and portalPart and guide01Template and guide02Template) then
		return false
	end

	self:_destroyGuide()

	local guide01 = guide01Template:Clone()
	local guide02 = guide02Template:Clone()
	guide01.Name = GUIDE_RUNTIME_NAME .. "01"
	guide02.Name = GUIDE_RUNTIME_NAME .. "02"
	setLocalPartPhysics(guide01, false)
	setLocalPartPhysics(guide02, true)

	guide01.CFrame = characterRoot.CFrame
	guide02.CFrame = portalPart.CFrame
	guide01.Parent = character
	guide02.Parent = portalPart

	local weld = Instance.new("WeldConstraint")
	weld.Name = "GuideRootWeld"
	weld.Part0 = characterRoot
	weld.Part1 = guide01
	weld.Parent = guide01

	local beam = guide01:FindFirstChildOfClass("Beam")
	local playerAttachment = guide01:FindFirstChild("Attachment1")
	local portalAttachment = guide02:FindFirstChild("Attachment0")
	if beam and playerAttachment and playerAttachment:IsA("Attachment") and portalAttachment and portalAttachment:IsA("Attachment") then
		beam.Attachment0 = portalAttachment
		beam.Attachment1 = playerAttachment
		beam.Enabled = true
	end

	table.insert(self._guideInstances, guide01)
	table.insert(self._guideInstances, guide02)
	return true
end

function GuideController:_queueEnsureGuide()
	self._bindToken += 1
	local token = self._bindToken

	task.spawn(function()
		local deadline = os.clock() + 60
		repeat
			if token ~= self._bindToken or self._guideCompleted == true then
				return
			end

			local character = self._localPlayer and self._localPlayer.Character or nil
			local portalPart = findPortalPart()
			if character and portalPart and self:_cloneGuidePair(character, portalPart) then
				return
			end

			task.wait(0.5)
		until os.clock() >= deadline
	end)
end

function GuideController:_applyGuideCompleted(guideCompleted)
	self._guideCompleted = guideCompleted == true
	if self._guideCompleted then
		self._bindToken += 1
		self:_destroyGuide()
		return
	end

	self:_queueEnsureGuide()
end

function GuideController:Init(dependencies)
	self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
	disconnectAll(self._connections)
	self:_destroyGuide()
	self._guideCompleted = true
	self._bindToken += 1

	local eventsFolder = ReplicatedStorage:WaitForChild(RemoteNames.RootFolder)
	local systemEventsFolder = eventsFolder:WaitForChild(RemoteNames.SystemEventsFolder)
	self._playerStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.PlayerStateSync)
	self._requestStateSyncEvent = systemEventsFolder:WaitForChild(RemoteNames.System.RequestPlayerStateSync)

	table.insert(self._connections, self._playerStateSyncEvent.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" or type(payload.guideCompleted) ~= "boolean" then
			return
		end
		self:_applyGuideCompleted(payload.guideCompleted)
	end))

	if self._localPlayer then
		table.insert(self._connections, self._localPlayer.CharacterAdded:Connect(function()
			if self._guideCompleted ~= true then
				self:_destroyGuide()
				self:_queueEnsureGuide()
			end
		end))
	end

	if self._requestStateSyncEvent then
		self._requestStateSyncEvent:FireServer()
	end
end

return GuideController
