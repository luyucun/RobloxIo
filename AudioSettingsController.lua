--[[
Script: AudioSettingsController
Type: ModuleScript
Studio path: StarterPlayer/StarterPlayerScripts/Controllers/AudioSettingsController
Purpose: Client-side music/SFX gates driven by the persisted option state.
]]

local SoundService = game:GetService("SoundService")

local AudioSettingsController = {}

AudioSettingsController._musicEnabled = true
AudioSettingsController._sfxEnabled = true
AudioSettingsController._initialBgmSounds = {}
AudioSettingsController._connections = {}
AudioSettingsController._watchedSounds = {}
AudioSettingsController._initialized = false

local BGM_FOLDER_NAME = "BGM"
local AUDIO_FOLDER_NAME = "Audio"
local UI_FOLDER_NAME = "UI"

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

function AudioSettingsController:Init()
    disconnectAll(self._connections)
    table.clear(self._watchedSounds)
    self:_captureInitialBgm()
    self:_watchFolder(BGM_FOLDER_NAME)
    self:_watchFolder(AUDIO_FOLDER_NAME)
    self:_watchFolder(UI_FOLDER_NAME)
    self._initialized = true
    self:ApplyMusic()
    self:SetSfxEnabled(self._sfxEnabled)
end

return AudioSettingsController
