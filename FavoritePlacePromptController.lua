--[[
脚本名字: FavoritePlacePromptController
脚本文件: FavoritePlacePromptController.lua
脚本类型: ModuleScript
Studio放置路径: StarterPlayer/StarterPlayerScripts/Controllers/FavoritePlacePromptController
]]

local AvatarEditorService = game:GetService("AvatarEditorService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
        "[FavoritePlacePromptController] 缺少共享模块 %s（应放在 ReplicatedStorage/Shared 或 ReplicatedStorage 根目录）",
        tostring(moduleName or "")
    ))
end

local RemoteNames = requireSharedModule("RemoteNames")

local FavoritePlacePromptController = {}

FavoritePlacePromptController._localPlayer = nil
FavoritePlacePromptController._promptFavoritePlaceEvent = nil
FavoritePlacePromptController._favoritePlacePromptStartedEvent = nil
FavoritePlacePromptController._favoritePlacePromptResultEvent = nil
FavoritePlacePromptController._activeRequestId = ""
FavoritePlacePromptController._activePlaceId = 0
FavoritePlacePromptController._didPromptThisSession = false
FavoritePlacePromptController._isPrompting = false
FavoritePlacePromptController._initialized = false

local function asNonNegativeInteger(value)
    return math.max(0, math.floor(tonumber(value) or 0))
end

function FavoritePlacePromptController:_bindRemoteEvents()
    local eventsRoot = ReplicatedStorage:FindFirstChild(RemoteNames.RootFolder)
        or ReplicatedStorage:WaitForChild(RemoteNames.RootFolder, 10)
    if not eventsRoot then
        warn("[FavoritePlacePromptController] 找不到 ReplicatedStorage/Events，收藏提示功能暂不可用。")
        return false
    end

    local systemEvents = eventsRoot:FindFirstChild(RemoteNames.SystemEventsFolder)
        or eventsRoot:WaitForChild(RemoteNames.SystemEventsFolder, 10)
    if not systemEvents then
        warn("[FavoritePlacePromptController] 找不到 ReplicatedStorage/Events/SystemEvents，收藏提示功能暂不可用。")
        return false
    end

    self._promptFavoritePlaceEvent = systemEvents:FindFirstChild(RemoteNames.System.PromptFavoritePlace)
        or systemEvents:WaitForChild(RemoteNames.System.PromptFavoritePlace, 10)
    self._favoritePlacePromptStartedEvent = systemEvents:FindFirstChild(RemoteNames.System.FavoritePlacePromptStarted)
        or systemEvents:WaitForChild(RemoteNames.System.FavoritePlacePromptStarted, 10)
    self._favoritePlacePromptResultEvent = systemEvents:FindFirstChild(RemoteNames.System.FavoritePlacePromptResult)
        or systemEvents:WaitForChild(RemoteNames.System.FavoritePlacePromptResult, 10)

    if not (self._promptFavoritePlaceEvent and self._favoritePlacePromptStartedEvent and self._favoritePlacePromptResultEvent) then
        warn("[FavoritePlacePromptController] 收藏提示远端事件不完整，收藏提示功能暂不可用。")
        return false
    end

    return true
end

function FavoritePlacePromptController:_reportPromptResult(result)
    local requestId = tostring(self._activeRequestId or "")
    if requestId == "" then
        return
    end

    local resultName = typeof(result) == "EnumItem" and result.Name or tostring(result or "")
    if self._favoritePlacePromptResultEvent then
        self._favoritePlacePromptResultEvent:FireServer({
            requestId = requestId,
            placeId = asNonNegativeInteger(self._activePlaceId),
            result = resultName,
            timestamp = os.clock(),
        })
    end

    self._activeRequestId = ""
    self._activePlaceId = 0
    self._isPrompting = false
end

function FavoritePlacePromptController:_promptFavoritePlace(requestId, placeId)
    if self._didPromptThisSession or self._isPrompting then
        return
    end

    local resolvedRequestId = tostring(requestId or "")
    local resolvedPlaceId = asNonNegativeInteger(placeId)
    if resolvedRequestId == "" or resolvedPlaceId <= 0 then
        return
    end

    self._isPrompting = true
    self._didPromptThisSession = true
    self._activeRequestId = resolvedRequestId
    self._activePlaceId = resolvedPlaceId
    local okPrompt, promptError = pcall(function()
        AvatarEditorService:PromptSetFavorite(resolvedPlaceId, Enum.AvatarItemType.Asset, true)
    end)
    if not okPrompt then
        warn(string.format(
            "[FavoritePlacePromptController] 打开 Place 收藏提示失败 placeId=%d err=%s",
            resolvedPlaceId,
            tostring(promptError)
        ))
        self:_reportPromptResult("Failed")
        return
    end

    if self._favoritePlacePromptStartedEvent then
        self._favoritePlacePromptStartedEvent:FireServer({
            requestId = resolvedRequestId,
            placeId = resolvedPlaceId,
            timestamp = os.clock(),
        })
    end
end

function FavoritePlacePromptController:_handlePromptRequest(payload)
    if type(payload) ~= "table" or self._didPromptThisSession then
        return
    end

    local requestId = tostring(payload.requestId or "")
    local placeId = asNonNegativeInteger(payload.placeId or game.PlaceId)
    if requestId == "" or placeId <= 0 then
        return
    end
    self:_promptFavoritePlace(requestId, placeId)
end

function FavoritePlacePromptController:Init(dependencies)
    if self._initialized then
        return
    end
    self._initialized = true

    self._localPlayer = dependencies and dependencies.LocalPlayer or Players.LocalPlayer
    self._activeRequestId = ""
    self._activePlaceId = 0
    self._didPromptThisSession = false
    self._isPrompting = false

    if not self:_bindRemoteEvents() then
        return
    end

    self._promptFavoritePlaceEvent.OnClientEvent:Connect(function(payload)
        self:_handlePromptRequest(payload)
    end)

    AvatarEditorService.PromptSetFavoriteCompleted:Connect(function(result)
        self:_reportPromptResult(result)
    end)
end

return FavoritePlacePromptController
