---@diagnostic disable: undefined-field, access-invisible
-- ============================================================================
-- SoundManager.lua — 暗夜传奇 音效管理模块
-- 统一管理音效（一次性）与背景音乐（循环），并持久化"音效开关"设置。
-- ============================================================================
-- 设计要点：
--   * 所有音效资源集中在 assets/audio/sfx/ 与 assets/audio/music/。
--   * 通过 cache:GetResource("Sound", path) 加载；Sound 支持 .mp3。
--   * 音效开关关闭时，一次性音效直接跳过；背景音乐淡出停止。
--   * 设置持久化到 saves/audio_settings.json（与角色存档分离的全局设置）。
-- ============================================================================

local SoundManager = {}

---@class SoundManager
local Effects = require("urhox-libs.Effects.Effects")

-- 全局设置（不受单个角色存档影响）
local settings = {
    soundEnabled = true,  -- 音效总开关（含背景音乐）
    musicGain = 0.5,      -- 背景音乐音量
    sfxGain = 0.8,        -- 一次性音效音量
}

-- 运行期缓存
local bgmHandle = nil       -- 当前背景音乐句柄
local currentBgm = nil      -- 当前背景音乐路径
local currentBgmKey = nil   -- 当前背景音乐键（menu/battle），用于关闭后恢复
local settingsPath = "saves/audio_settings.json"
local settingsLoaded = false

-- 音效路径表（完整路径字面量，便于引用计算打包）
local SOUND_PATHS = {
    sword_hit   = "audio/sfx/sfx_sword_hit.mp3",
    sword_swing = "audio/sfx/sfx_sword_swing.mp3",
    fireball    = "audio/sfx/sfx_fireball.mp3",
    thunder     = "audio/sfx/sfx_thunder.mp3",
    explosion   = "audio/sfx/sfx_explosion.mp3",
    heal        = "audio/sfx/sfx_heal.mp3",
    buff        = "audio/sfx/sfx_buff.mp3",
    dash        = "audio/sfx/sfx_dash.mp3",
    hurt        = "audio/sfx/sfx_hurt.mp3",
    enemy_hit   = "audio/sfx/sfx_enemy_hit.mp3",
    enemy_death = "audio/sfx/sfx_enemy_death.mp3",
    death       = "audio/sfx/sfx_death.mp3",
    gold        = "audio/sfx/sfx_gold.mp3",
    pickup      = "audio/sfx/sfx_pickup.mp3",
    levelup     = "audio/sfx/sfx_levelup.mp3",
    potion      = "audio/sfx/sfx_potion.mp3",
    click       = "audio/sfx/sfx_click.mp3",
    open_panel  = "audio/sfx/sfx_open_panel.mp3",
    close_panel = "audio/sfx/sfx_close_panel.mp3",
    error       = "audio/sfx/sfx_error.mp3",
    quest_complete = "audio/sfx/sfx_quest_complete.mp3",
    safe_zone   = "audio/sfx/sfx_safe_zone.mp3",
    sell        = "audio/sfx/sfx_sell.mp3",
}

local MUSIC_PATHS = {
    menu   = "audio/music/bgm_menu.mp3",
    battle = "audio/music/bgm_battle.mp3",
}

SoundManager.SOUND_PATHS = SOUND_PATHS
SoundManager.MUSIC_PATHS = MUSIC_PATHS

-- ============================================================================
-- 设置持久化
-- ============================================================================

--- 归一化布尔值
local function ToBool(value, fallback)
    if value == nil then return fallback end
    return value == true
end

--- 归一化音量（0.0 - 1.0）
local function ToGain(value, fallback)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return fallback end
    return math.max(0.0, math.min(1.0, n))
end

--- 加载设置（幂等，多次调用只读一次）
function SoundManager.LoadSettings()
    if settingsLoaded then return end
    settingsLoaded = true

    if not fileSystem:FileExists(settingsPath) then return end
    local file = File(settingsPath, FILE_READ)
    if not file:IsOpen() then return end
    local jsonStr = file:ReadString()
    file:Close()
    if not jsonStr or #jsonStr == 0 then return end

    local ok, data = pcall(cjson.decode, jsonStr)
    if not ok or type(data) ~= "table" then return end

    settings.soundEnabled = ToBool(data.soundEnabled, true)
    settings.musicGain = ToGain(data.musicGain, 0.5)
    settings.sfxGain = ToGain(data.sfxGain, 0.8)
    print("[SoundManager] Loaded settings: soundEnabled=" .. tostring(settings.soundEnabled))
end

--- 保存设置
function SoundManager.SaveSettings()
    if not fileSystem:DirExists("saves") then
        fileSystem:CreateDir("saves")
    end
    local data = {
        version = 1,
        soundEnabled = settings.soundEnabled,
        musicGain = settings.musicGain,
        sfxGain = settings.sfxGain,
    }
    local ok, jsonStr = pcall(cjson.encode, data)
    if not ok or type(jsonStr) ~= "string" then
        print("[SoundManager] SaveSettings encode failed")
        return
    end
    local file = File(settingsPath, FILE_WRITE)
    if not file:IsOpen() then return end
    file:WriteString(jsonStr)
    file:Close()
    print("[SoundManager] Saved settings: soundEnabled=" .. tostring(settings.soundEnabled))
end

-- ============================================================================
-- 对外 API
-- ============================================================================

--- 音效是否开启
---@return boolean
function SoundManager.IsSoundEnabled()
    return settings.soundEnabled
end

--- 设置音效总开关。关闭时同时停止背景音乐。
---@param enabled boolean
function SoundManager.SetSoundEnabled(enabled)
    settings.soundEnabled = enabled == true
    if not settings.soundEnabled then
        SoundManager.StopMusic(true)  -- 保留音乐键，重新开启时可恢复
    else
        -- 重新打开时按关闭前保留的音乐键恢复背景音乐
        if currentBgmKey then
            SoundManager.PlayMusic(currentBgmKey)
        end
    end
    SoundManager.SaveSettings()
end

--- 获取背景音乐音量
---@return number
function SoundManager.GetMusicGain()
    return settings.musicGain
end

--- 获取音效音量
---@return number
function SoundManager.GetSfxGain()
    return settings.sfxGain
end

--- 播放一次性音效
---@param name string 音效键名（SoundManager.SOUND_PATHS 的键）
---@param options? {gain?: number, position?: Vector3, scene?: Scene}
---@return table|nil 音效句柄
function SoundManager.Play(name, options)
    if not settings.soundEnabled then return nil end
    local path = SOUND_PATHS[name]
    if not path then
        print("[SoundManager] Unknown sound: " .. tostring(name))
        return nil
    end
    options = options or {}
    local scene = options.scene or SoundManager.currentScene
    if not scene then return nil end

    local gain = (options.gain or 1.0) * settings.sfxGain
    if gain <= 0.01 then return nil end

    return Effects.PlaySound(scene, path, {
        gain = gain,
        position = options.position,
    })
end

--- 播放背景音乐（自动切换：同名不重启，不同名淡出旧、淡入新）
---@param name string 背景音乐键名（SoundManager.MUSIC_PATHS 的键）
---@param options? {gain?: number, scene?: Scene}
function SoundManager.PlayMusic(name, options)
    local path = MUSIC_PATHS[name]
    if not path then
        print("[SoundManager] Unknown music: " .. tostring(name))
        return
    end
    if not settings.soundEnabled then
        -- 音效关闭时仅记录音乐意图，重新开启后可据此恢复
        currentBgmKey = name
        return
    end
    if currentBgm == path and bgmHandle and bgmHandle.source then
        return -- 已在播放
    end
    options = options or {}
    local scene = options.scene or SoundManager.currentScene
    if not scene then return end

    local gain = (options.gain or settings.musicGain)

    -- 停止旧 BGM。
    -- 说明：Effects.FadeOutSound 依赖 ValueAnimation + SetAttributeAnimation("Gain")，
    -- 在宿主引擎上会触发 "Invalid value type" 报错，因此这里走直接 Stop/Remove，避开该路径。
    if bgmHandle and bgmHandle.Stop then
        bgmHandle:Stop()
    end
    bgmHandle = nil
    currentBgm = nil

    local handle = Effects.PlaySoundLooped(scene, path, {
        gain = gain,
        soundType = SOUND_MUSIC,
    })
    if not handle then return end
    -- 音量直接落在音源上，不用属性动画淡入，避免引擎报错。
    if handle.source then
        handle.source.gain = gain
    end
    bgmHandle = handle
    currentBgm = path
    currentBgmKey = name
    print("[SoundManager] PlayMusic: " .. path)
end

--- 停止背景音乐
---@param keepKey? boolean 停止后是否保留音乐键（用于关闭音效后可恢复）
function SoundManager.StopMusic(keepKey)
    if bgmHandle then
        -- 同上：优先直接 Stop/Remove，避免 SetAttributeAnimation 触发 "Invalid value type"。
        if bgmHandle.Stop then
            bgmHandle:Stop()
        end
        bgmHandle = nil
    end
    currentBgm = nil
    if not keepKey then
        currentBgmKey = nil
    end
end

--- 设置当前场景引用（供场景切换时绑定）
---@param scene Scene
function SoundManager.SetScene(scene)
    SoundManager.currentScene = scene
end

SoundManager.currentScene = nil

return SoundManager
