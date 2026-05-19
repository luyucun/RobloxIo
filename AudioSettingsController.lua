--[[
Script: AudioSettingsController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/AudioSettingsController
Purpose: Client-side music/SFX gates driven by the persisted option state.
]]

local SoundService = game:GetService("SoundService")
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

    return nil
end

local GameConfig = requireSharedModule("GameConfig")

local AudioSettingsController = {}

AudioSettingsController._musicEnabled = true
AudioSettingsController._sfxEnabled = true
AudioSettingsController._initialBgmSounds = {}
AudioSettingsController._connections = {}
AudioSettingsController._watchedSounds = {}
AudioSettingsController._playerGuiButtonBoundButtons = setmetatable({}, { __mode = "k" })
AudioSettingsController._playerGuiButtonListenerConnection = nil
AudioSettingsController._playerGuiButtonListenerTarget = nil
AudioSettingsController._initialized = false
AudioSettingsController._buttonBindCount = 0
AudioSettingsController._buttonDescendantAddedCount = 0
AudioSettingsController._nextDiagClock = 0

local BGM_FOLDER_NAME = "BGM"
local AUDIO_FOLDER_NAME = "Audio"
local UI_FOLDER_NAME = "UI"
local RUNTIME_SFX_FOLDER_NAME = "__RuntimeSfx"

local function isPerformanceDebugEnabled()
    return GameConfig and GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.DebugEnabled == true
end

local function getPerformanceLogInterval()
    return math.max(1, tonumber(GameConfig and GameConfig.PERFORMANCE and GameConfig.PERFORMANCE.LogIntervalSeconds) or 15)
end

local function countMapEntries(map)
    local count = 0
    for _ in pairs(map or {}) do
        count += 1
    end
    return count
end

local function countDescendants(instance)
    if not instance then
        return 0
    end

    local ok, descendants = pcall(function()
        return instance:GetDescendants()
    end)
    return ok and #descendants or 0
end

local function disconnectAll(connections)
    for _, connection in ipairs(connections) do
        if connection and connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(connections)
end

local function getSoundFolder(folderName)
    local folder = SoundService:FindFirstChild(folderName)
    if folder then
        return folder
    end
    return SoundService:FindFirstChild(folderName, true)
end

local function getRuntimeSfxFolder(createIfMissing)
    local folder = SoundService:FindFirstChild(RUNTIME_SFX_FOLDER_NAME)
    if folder then
        return folder
    end

    if createIfMissing ~= true then
        return nil
    end

    folder = Instance.new("Folder")
    folder.Name = RUNTIME_SFX_FOLDER_NAME
    folder.Parent = SoundService
    return folder
end

local function normalizeSoundPath(soundPath)
    if type(soundPath) == "table" then
        local segments = {}
        for _, segment in ipairs(soundPath) do
            if type(segment) == "string" then
                local trimmed = segment:gsub("^%s+", ""):gsub("%s+$", "")
                if trimmed ~= "" then
                    table.insert(segments, trimmed)
                end
            end
        end
        return segments
    end

    if type(soundPath) == "string" then
        local segments = {}
        for segment in string.gmatch(soundPath, "[^/]+") do
            local trimmed = segment:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" then
                table.insert(segments, trimmed)
            end
        end
        if #segments == 0 and soundPath ~= "" then
            table.insert(segments, soundPath)
        end
        return segments
    end

    return nil
end

local function findSoundByPath(root, soundPath)
    local segments = normalizeSoundPath(soundPath)
    if not (root and segments and #segments > 0) then
        return nil
    end

    local current = root
    for index = 1, #segments - 1 do
        current = current:FindFirstChild(segments[index])
        if not current then
            return nil
        end
    end

    local soundName = segments[#segments]
    if current then
        local direct = current:FindFirstChild(soundName)
        if direct and direct:IsA("Sound") then
            return direct
        end

        for _, descendant in ipairs(current:GetDescendants()) do
            if descendant:IsA("Sound") and descendant.Name == soundName then
                return descendant
            end
        end
    end

    if root:IsA("Sound") and root.Name == soundName then
        return root
    end

    for _, descendant in ipairs(root:GetDescendants()) do
        if descendant:IsA("Sound") and descendant.Name == soundName then
            return descendant
        end
    end

    return nil
end

local function collectSounds(root)
    local sounds = {}
    if root and root:IsA("Sound") then
        table.insert(sounds, root)
    end
    if root then
        for _, descendant in ipairs(root:GetDescendants()) do
            if descendant:IsA("Sound") then
                table.insert(sounds, descendant)
            end
        end
    end
    return sounds
end

local function stopSounds(root)
    for _, sound in ipairs(collectSounds(root)) do
        if sound.Playing then
            pcall(function()
                sound:Stop()
            end)
        end
    end
end

local function isSoundUnderFolder(sound, folderName)
    local folder = getSoundFolder(folderName)
    return folder and sound and sound:IsDescendantOf(folder)
end

function AudioSettingsController:_stopIfBlocked(sound)
    if not (sound and sound:IsA("Sound")) then
        return
    end

    local blocked = false
    if self._musicEnabled ~= true and isSoundUnderFolder(sound, BGM_FOLDER_NAME) then
        blocked = true
    elseif self._sfxEnabled ~= true and (isSoundUnderFolder(sound, AUDIO_FOLDER_NAME) or isSoundUnderFolder(sound, UI_FOLDER_NAME)) then
        blocked = true
    end

    if blocked and sound.Playing then
        pcall(function()
            sound:Stop()
        end)
    end
end

function AudioSettingsController:_watchSound(sound)
    if not (sound and sound:IsA("Sound")) or self._watchedSounds[sound] then
        return
    end

    self._watchedSounds[sound] = true
    table.insert(self._connections, sound:GetPropertyChangedSignal("Playing"):Connect(function()
        self:_stopIfBlocked(sound)
    end))
    self:_stopIfBlocked(sound)
end

function AudioSettingsController:_watchFolder(folderName)
    local folder = getSoundFolder(folderName)
    if not folder then
        return
    end

    for _, sound in ipairs(collectSounds(folder)) do
        self:_watchSound(sound)
    end

    table.insert(self._connections, folder.DescendantAdded:Connect(function(descendant)
        if descendant:IsA("Sound") then
            self:_watchSound(descendant)
        end
    end))
end

function AudioSettingsController:_captureInitialBgm()
    table.clear(self._initialBgmSounds)
    local bgmFolder = getSoundFolder(BGM_FOLDER_NAME)
    for _, sound in ipairs(collectSounds(bgmFolder)) do
        if sound.Playing then
            table.insert(self._initialBgmSounds, sound)
        end
    end
end

function AudioSettingsController:_findFallbackBgm()
    local bgmFolder = getSoundFolder(BGM_FOLDER_NAME)
    local firstSound = nil
    for _, sound in ipairs(collectSounds(bgmFolder)) do
        firstSound = firstSound or sound
        if sound.Looped then
            return sound
        end
    end
    return firstSound
end

function AudioSettingsController:_isAnyBgmPlaying()
    local bgmFolder = getSoundFolder(BGM_FOLDER_NAME)
    for _, sound in ipairs(collectSounds(bgmFolder)) do
        if sound.Playing then
            return true
        end
    end
    return false
end

function AudioSettingsController:ApplyMusic()
    local bgmFolder = getSoundFolder(BGM_FOLDER_NAME)
    if self._musicEnabled ~= true then
        stopSounds(bgmFolder)
        return
    end

    if self:_isAnyBgmPlaying() then
        return
    end

    local played = false
    for _, sound in ipairs(self._initialBgmSounds) do
        if sound and sound.Parent then
            pcall(function()
                sound:Play()
            end)
            played = true
        end
    end
    if played then
        return
    end

    local fallback = self:_findFallbackBgm()
    if fallback then
        pcall(function()
            fallback:Play()
        end)
    end
end

function AudioSettingsController:SetMusicEnabled(enabled)
    self._musicEnabled = enabled == true
    self:ApplyMusic()
end

function AudioSettingsController:SetSfxEnabled(enabled)
    self._sfxEnabled = enabled == true
    if self._sfxEnabled ~= true then
        stopSounds(getSoundFolder(AUDIO_FOLDER_NAME))
        stopSounds(getSoundFolder(UI_FOLDER_NAME))
        stopSounds(getRuntimeSfxFolder(false))
    end
end

function AudioSettingsController:ApplyOptions(options)
    if type(options) ~= "table" then
        return
    end

    if type(options.musicEnabled) == "boolean" then
        self:SetMusicEnabled(options.musicEnabled)
    elseif type(options.Music) == "boolean" then
        self:SetMusicEnabled(options.Music)
    end

    if type(options.sfxEnabled) == "boolean" then
        self:SetSfxEnabled(options.sfxEnabled)
    elseif type(options.Sfx) == "boolean" then
        self:SetSfxEnabled(options.Sfx)
    end
end

function AudioSettingsController:IsMusicEnabled()
    return self._musicEnabled == true
end

function AudioSettingsController:IsSfxEnabled()
    return self._sfxEnabled == true
end

function AudioSettingsController:PlaySfx(sound, restart)
    if not (sound and sound:IsA("Sound")) then
        return false
    end

    if self._sfxEnabled ~= true then
        if sound.Playing then
            pcall(function()
                sound:Stop()
            end)
        end
        return false
    end

    pcall(function()
        if restart == true then
            sound:Stop()
            sound.TimePosition = 0
        end
        sound:Play()
    end)
    return true
end

function AudioSettingsController:PlaySfxByPath(folderName, soundPath, restart)
    local folder = getSoundFolder(folderName)
    if not folder then
        return false
    end

    local sound = findSoundByPath(folder, soundPath)
    if not sound then
        return false
    end

    return self:PlaySfx(sound, restart)
end

function AudioSettingsController:PlaySfxOneShotByPath(folderName, soundPath)
    if self._sfxEnabled ~= true then
        return false
    end

    local folder = getSoundFolder(folderName)
    if not folder then
        return false
    end

    local sound = findSoundByPath(folder, soundPath)
    if not sound then
        return false
    end

    local runtimeFolder = getRuntimeSfxFolder(true)
    if not runtimeFolder then
        return false
    end

    local clone = sound:Clone()
    clone.Name = string.format("%s_OneShot_%d", sound.Name, math.floor(os.clock() * 1000))
    clone.Parent = runtimeFolder

    local cleanupConnections = {}
    local cleanedUp = false
    local function cleanup()
        if cleanedUp then
            return
        end
        cleanedUp = true

        for _, connection in ipairs(cleanupConnections) do
            if connection and connection.Connected then
                connection:Disconnect()
            end
        end

        if clone and clone.Parent then
            clone:Destroy()
        end
    end

    local okEnded, endedConnection = pcall(function()
        return clone.Ended:Connect(cleanup)
    end)
    if okEnded and endedConnection then
        table.insert(cleanupConnections, endedConnection)
    end

    local okStopped, stoppedConnection = pcall(function()
        return clone.Stopped:Connect(cleanup)
    end)
    if okStopped and stoppedConnection then
        table.insert(cleanupConnections, stoppedConnection)
    end

    task.delay(math.max(1, (tonumber(clone.TimeLength) or 0) + 1), cleanup)

    pcall(function()
        clone:Play()
    end)
    return true
end

function AudioSettingsController:PlayUiClickSound()
    return self:PlaySfxByPath(UI_FOLDER_NAME, { "Click Sound" }, true)
end

function AudioSettingsController:_bindPlayerGuiButton(button)
    if not (button and button:IsA("GuiButton")) then
        return
    end

    if self._playerGuiButtonBoundButtons[button] then
        return
    end

    self._playerGuiButtonBoundButtons[button] = true
    self._buttonBindCount = (self._buttonBindCount or 0) + 1
    table.insert(self._connections, button.Activated:Connect(function()
        self:PlayUiClickSound()
    end))
end

function AudioSettingsController:_logDiagnostics(force)
    if not isPerformanceDebugEnabled() then
        return
    end

    local now = os.clock()
    if force ~= true and now < (self._nextDiagClock or 0) then
        return
    end
    self._nextDiagClock = now + getPerformanceLogInterval()

    local runtimeFolder = getRuntimeSfxFolder(false)
    print(string.format(
        "[Diag][AudioSettingsController] boundButtons=%d buttonBinds=%d buttonDescAdded=%d totalConnections=%d watchedSounds=%d runtimeSfxChildren=%d runtimeSfxDesc=%d",
        countMapEntries(self._playerGuiButtonBoundButtons),
        self._buttonBindCount or 0,
        self._buttonDescendantAddedCount or 0,
        #self._connections,
        countMapEntries(self._watchedSounds),
        runtimeFolder and #runtimeFolder:GetChildren() or 0,
        countDescendants(runtimeFolder)
    ))
end

function AudioSettingsController:BindPlayerGuiButtonClicks(playerGui)
    if not (playerGui and playerGui:IsA("PlayerGui")) then
        return false
    end

    if self._playerGuiButtonListenerTarget == playerGui and self._playerGuiButtonListenerConnection and self._playerGuiButtonListenerConnection.Connected then
        return true
    end

    if self._playerGuiButtonListenerConnection and self._playerGuiButtonListenerConnection.Connected then
        self._playerGuiButtonListenerConnection:Disconnect()
    end

    self._playerGuiButtonListenerTarget = playerGui
    table.clear(self._playerGuiButtonBoundButtons)

    self._playerGuiButtonListenerConnection = playerGui.DescendantAdded:Connect(function(descendant)
        self._buttonDescendantAddedCount = (self._buttonDescendantAddedCount or 0) + 1
        self:_bindPlayerGuiButton(descendant)
        self:_logDiagnostics(false)
    end)
    table.insert(self._connections, self._playerGuiButtonListenerConnection)

    for _, descendant in ipairs(playerGui:GetDescendants()) do
        self:_bindPlayerGuiButton(descendant)
    end

    self:_logDiagnostics(true)
    return true
end

function AudioSettingsController:Init()
    disconnectAll(self._connections)
    table.clear(self._watchedSounds)
    table.clear(self._playerGuiButtonBoundButtons)
    self._playerGuiButtonListenerConnection = nil
    self._playerGuiButtonListenerTarget = nil
    self._buttonBindCount = 0
    self._buttonDescendantAddedCount = 0
    self._nextDiagClock = 0
    self:_captureInitialBgm()
    self:_watchFolder(BGM_FOLDER_NAME)
    self:_watchFolder(AUDIO_FOLDER_NAME)
    self:_watchFolder(UI_FOLDER_NAME)
    self._initialized = true
    self:ApplyMusic()
    self:SetSfxEnabled(self._sfxEnabled)
end

return AudioSettingsController
