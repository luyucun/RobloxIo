--[[
脚本名字: NoobMachineController
脚本文件: NoobMachineController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/NoobMachineController
说明: 客户端本地让 Map2/Machines/Noob 始终循环播放动画，并关闭其本地碰撞。
]]

local Workspace = game:GetService("Workspace")

local NoobMachineController = {}

NoobMachineController._connections = {}
NoobMachineController._noobModel = nil
NoobMachineController._animationTrack = nil
NoobMachineController._animationObject = nil

local NOOB_ANIMATION_ID = "rbxassetid://77493219283554"

local function disconnectAll(connections)
	for _, connection in ipairs(connections) do
		if connection and connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(connections)
end

function NoobMachineController:_clearAnimation()
	if self._animationTrack then
		pcall(function()
			self._animationTrack:Stop(0)
		end)
		pcall(function()
			self._animationTrack:Destroy()
		end)
		self._animationTrack = nil
	end

	if self._animationObject then
		pcall(function()
			self._animationObject:Destroy()
		end)
		self._animationObject = nil
	end
end

function NoobMachineController:_applyCollision(model)
	for _, descendant in ipairs(model:GetDescendants()) do
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
		end
	end

	table.insert(self._connections, model.DescendantAdded:Connect(function(descendant)
		if descendant:IsA("BasePart") then
			descendant.CanCollide = false
		end
	end))
end

function NoobMachineController:_playLoopAnimation(model)
	local humanoid = model:FindFirstChildOfClass("Humanoid") or model:WaitForChild("Humanoid", 10)
	if not humanoid then
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 10)
	if not animator then
		return
	end

	self:_clearAnimation()

	local animation = Instance.new("Animation")
	animation.Name = "NoobLoopAnimation"
	animation.AnimationId = NOOB_ANIMATION_ID
	animation.Parent = animator

	local ok, track = pcall(function()
		return animator:LoadAnimation(animation)
	end)
	if not ok or not track then
		animation:Destroy()
		return
	end

	track.Priority = Enum.AnimationPriority.Action
	track.Looped = true
	track:Play(0.15)

	self._animationObject = animation
	self._animationTrack = track

	table.insert(self._connections, track.Stopped:Connect(function()
		if self._animationTrack == track and self._noobModel == model and model.Parent then
			track:Play(0.15)
		end
	end))
end

function NoobMachineController:_bindNoob(model)
	if self._noobModel == model then
		return
	end

	self._noobModel = model
	disconnectAll(self._connections)
	self:_clearAnimation()
	self:_applyCollision(model)
	self:_playLoopAnimation(model)
end

function NoobMachineController:_findNoob()
	local map2 = Workspace:WaitForChild("Map2", 30)
	if not map2 then
		return nil
	end

	local machines = map2:WaitForChild("Machines", 30)
	if not machines then
		return nil
	end

	return machines:WaitForChild("Noob", 30)
end

function NoobMachineController:Init()
	disconnectAll(self._connections)
	self._noobModel = nil
	self:_clearAnimation()

	task.spawn(function()
		local noob = self:_findNoob()
		if noob then
			self:_bindNoob(noob)
		end
	end)
end

return NoobMachineController
