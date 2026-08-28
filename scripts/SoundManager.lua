---@diagnostic disable: undefined-field, access-invisible
-- ============================================================================
-- SoundManager.lua — 暗夜传奇 音效管理模块
-- 统一管理音效（一次性）与背景音乐（循环），并持久化"音效开关"设置。
-- ============================================================================
-- 设计要点：
--   * 所有音效资源集中在 assets/audio/sfx/ 与 assets/audio/music/。
--   * 通过 cache:GetResource("Sound", path) 加载；Sound 支持 .mp3。
--   * 音效开关关闭时，一次性音效直接跳过；背景音乐开关关闭时背景音乐停止。
--   * 音效与背景音乐是两个相互独立的开关。
--   * 设置持久化到 saves/audio_settings.json（与角色存档分离的全局设置）。
-- ============================================================================

---@class SoundManager
local SoundManager = {}

local Effects = require("urhox-libs.Effects.Effects")

-- 默认音量与受伤反馈调优。
-- 音效总增益负责整体舒适度，受伤音效另设倍率，避免密集战斗里盖过
-- 技能、背景音乐和重要的死亡提示。
local SETTINGS_VERSION = 2
local DEFAULT_MUSIC_GAIN = 0.5
local DEFAULT_SFX_GAIN = 0.6
local LEGACY_DEFAULT_SFX_GAIN = 0.8
local HURT_SOUND_GAIN = 0.45
local HURT_SOUND_COOLDOWN = 0.45
local SETTINGS_SAVE_DELAY = 0.20
local MUSIC_APPLY_DEFER_FRAMES = 1

-- 全局设置（不受单个角色存档影响）
local settings = {
    soundEnabled = true,  -- 一次性音效开关（独立）
    musicEnabled = true,  -- 背景音乐开关（独立）
    musicGain = DEFAULT_MUSIC_GAIN, -- 背景音乐音量
    sfxGain = DEFAULT_SFX_GAIN,     -- 一次性音效音量
}

-- 运行期缓存
local bgmHandle = nil       -- 当前背景音乐句柄
local currentBgm = nil      -- 当前背景音乐路径
local currentBgmKey = nil   -- 当前背景音乐键（menu/battle），用于关闭后恢复
local settingsPath = "saves/audio_settings.json"
local settingsLoaded = false
local hurtSoundCooldown = 0
local settingsDirty = false
local settingsSaveTimer = 0
local pendingMusicEnabled = nil
local pendingMusicFrames = 0

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
    hurt_male   = "audio/sfx/sfx_hurt_male.mp3",
    hurt_female = "audio/sfx/sfx_hurt_female.mp3",
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
SoundManager.DEFAULT_SFX_GAIN = DEFAULT_SFX_GAIN
SoundManager.DEFAULT_MUSIC_GAIN = DEFAULT_MUSIC_GAIN
SoundManager.HURT_SOUND_GAIN = HURT_SOUND_GAIN
SoundManager.HURT_SOUND_COOLDOWN = HURT_SOUND_COOLDOWN

-- 各类音效的相对增益。options.gain 仍可用于单次微调，最终还会乘以
-- 系统菜单中的音效总音量。
local SOUND_GAIN_MULTIPLIERS = {
    hurt = HURT_SOUND_GAIN,
    hurt_male = HURT_SOUND_GAIN,
    hurt_female = HURT_SOUND_GAIN,
}

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

--- 标记设置需要保存。所有菜单改动都走短暂 debounce，避免点击或拖动回调
--- 被同步文件 IO 阻塞。
local function MarkSettingsDirty()
    settingsDirty = true
    settingsSaveTimer = SETTINGS_SAVE_DELAY
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
    -- 兼容仅保存过旧版 soundEnabled 的设置：旧开关同时代表两类音频，
    -- 因此在缺少 musicEnabled 时沿用旧值，避免升级后背景音乐意外恢复。
    settings.musicEnabled = ToBool(data.musicEnabled, settings.soundEnabled)
    settings.musicGain = ToGain(data.musicGain, DEFAULT_MUSIC_GAIN)

    -- v1 的默认音效音量是 0.8。只迁移“仍等于旧默认值”的存档，
    -- 其他用户已经主动调过的音量保留，避免覆盖玩家偏好。
    local savedVersion = tonumber(data.version) or 1
    local savedSfxGain = tonumber(data.sfxGain)
    local shouldMigrateLegacyDefault = savedVersion < SETTINGS_VERSION
        and (savedSfxGain == nil or math.abs(savedSfxGain - LEGACY_DEFAULT_SFX_GAIN) < 0.001)
    settings.sfxGain = ToGain(savedSfxGain, DEFAULT_SFX_GAIN)
    if shouldMigrateLegacyDefault then
        settings.sfxGain = DEFAULT_SFX_GAIN
        -- 立即写回新版本，后续启动不再重复走迁移分支。
        SoundManager.SaveSettings()
    end

    print("[SoundManager] Loaded settings: soundEnabled=" .. tostring(settings.soundEnabled)
        .. " musicEnabled=" .. tostring(settings.musicEnabled)
        .. " sfxGain=" .. string.format("%.2f", settings.sfxGain))
end

--- 保存设置
---@return boolean 是否成功写入
function SoundManager.SaveSettings()
    if not fileSystem:DirExists("saves") then
        fileSystem:CreateDir("saves")
    end
    local data = {
        version = SETTINGS_VERSION,
        soundEnabled = settings.soundEnabled,
        musicEnabled = settings.musicEnabled,
        musicGain = settings.musicGain,
        sfxGain = settings.sfxGain,
    }
    local ok, jsonStr = pcall(cjson.encode, data)
    if not ok or type(jsonStr) ~= "string" then
        print("[SoundManager] SaveSettings encode failed")
        return false
    end
    local file = File(settingsPath, FILE_WRITE)
    if not file:IsOpen() then return false end
    file:WriteString(jsonStr)
    file:Close()
    settingsDirty = false
    settingsSaveTimer = 0
    print("[SoundManager] Saved settings: soundEnabled=" .. tostring(settings.soundEnabled)
        .. " musicEnabled=" .. tostring(settings.musicEnabled))
    return true
end

--- 立即落盘尚未保存的设置；退出或进入后台时调用。
function SoundManager.FlushSettings()
    if settingsDirty then
        SoundManager.SaveSettings()
    end
end

-- ============================================================================
-- 对外 API
-- ============================================================================

--- 一次性音效是否开启（与背景音乐相互独立）
---@return boolean
function SoundManager.IsSoundEnabled()
    return settings.soundEnabled
end

--- 设置一次性音效开关（不影响背景音乐）。
---@param enabled boolean
function SoundManager.SetSoundEnabled(enabled)
    local newEnabled = enabled == true
    if settings.soundEnabled == newEnabled then return end
    settings.soundEnabled = newEnabled
    MarkSettingsDirty()
end

--- 背景音乐是否开启（与一次性音效相互独立）
---@return boolean
function SoundManager.IsMusicEnabled()
    return settings.musicEnabled
end

--- 设置背景音乐开关。关闭时停止背景音乐；重新开启时播放关闭前保留的音乐键。
---@param enabled boolean
function SoundManager.SetMusicEnabled(enabled)
    local newEnabled = enabled == true
    if settings.musicEnabled == newEnabled then return end
    settings.musicEnabled = newEnabled

    -- 音源停止/恢复可能触发资源加载。先让 UI Toggle 完成一帧视觉反馈，
    -- 再由 Update 统一应用最后一次状态，快速连点也不会反复重建音源。
    pendingMusicEnabled = newEnabled
    pendingMusicFrames = MUSIC_APPLY_DEFER_FRAMES
    MarkSettingsDirty()
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

--- 设置背景音乐音量（0.0 - 1.0）。
---
--- 立即应用到当前正在播放的背景音乐。
---@param gain number
---@param persist? boolean 保留兼容；设置统一延迟持久化
function SoundManager.SetMusicGain(gain, persist)
    settings.musicGain = ToGain(gain, settings.musicGain)
    -- 当前 BGM 不需要重启；直接修改音源即可让滑块即时生效。
    if bgmHandle and bgmHandle.source then
        bgmHandle.source.gain = settings.musicGain
    end
    MarkSettingsDirty()
end

--- 设置一次性音效音量（0.0 - 1.0）。
---
--- 新播放的音效会使用新音量；已播放的短音效无需追踪和修改。
---@param gain number
---@param persist? boolean 保留兼容；设置统一延迟持久化
function SoundManager.SetSfxGain(gain, persist)
    settings.sfxGain = ToGain(gain, settings.sfxGain)
    MarkSettingsDirty()
end

--- 每帧推进瞬态音频状态。
---
--- 受伤音效节流不依赖真实时间 API，暂停、死亡演出和移动端帧率变化时
--- 也能按游戏帧稳定恢复。
---@param dt number
function SoundManager.Update(dt)
    local timeStep = tonumber(dt) or 0
    if timeStep > 0 then
        hurtSoundCooldown = math.max(0, hurtSoundCooldown - timeStep)
    end

    if pendingMusicEnabled ~= nil then
        if pendingMusicFrames > 0 then
            pendingMusicFrames = pendingMusicFrames - 1
        else
            local shouldEnable = pendingMusicEnabled
            pendingMusicEnabled = nil
            if shouldEnable then
                if currentBgmKey then
                    SoundManager.PlayMusic(currentBgmKey)
                end
            else
                SoundManager.StopMusic(true)  -- 保留音乐键，重新开启时可恢复
            end
        end
    end

    if settingsDirty and timeStep > 0 then
        settingsSaveTimer = math.max(0, settingsSaveTimer - timeStep)
        if settingsSaveTimer <= 0 then
            SoundManager.SaveSettings()
        end
    end
end

--- 播放受伤音效（带全局节流）。
---
--- 同一时间被多只怪物命中时，视觉伤害数字仍完整显示，但声音在短窗口内
--- 只保留一次，避免连续尖叫/撞击声形成噪音墙。
---@param options? {position?: Vector3, scene?: Scene, gender?: string, gain?: number}
---@return table|nil 音效句柄；处于节流窗口或音效关闭时返回 nil
function SoundManager.PlayHurt(options)
    if hurtSoundCooldown > 0 then return nil end

    local handle = SoundManager.Play("hurt", options)
    if handle then
        hurtSoundCooldown = HURT_SOUND_COOLDOWN
    end
    return handle
end

--- 播放一次性音效
---@param name string 音效键名（SoundManager.SOUND_PATHS 的键）
---@param options? {gain?: number, position?: Vector3, scene?: Scene, gender?: string}
---@return table|nil 音效句柄
function SoundManager.Play(name, options)
    if not settings.soundEnabled then return nil end
    options = options or {}
    local path = SOUND_PATHS[name]
    -- 受击音效按角色性别区分：hurt + gender 时优先使用对应性别的音效
    if name == "hurt" then
        local gender = options.gender
        if gender == "female" then
            path = SOUND_PATHS.hurt_female
        elseif gender == "male" then
            path = SOUND_PATHS.hurt_male
        end
    end
    if not path then
        print("[SoundManager] Unknown sound: " .. tostring(name))
        return nil
    end
    local scene = options.scene or SoundManager.currentScene
    if not scene then return nil end

    local gainMultiplier = SOUND_GAIN_MULTIPLIERS[name] or 1.0
    local gain = (options.gain or 1.0) * gainMultiplier * settings.sfxGain
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
    if not settings.musicEnabled then
        -- 背景音乐关闭时仅记录音乐意图，重新开启后可据此恢复
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

    -- 说明：Effects 库的 options.soundType 注解为 number，与引擎实际的字符串
    -- 类型（SOUND_MUSIC 等）不符，这里改为拿到句柄后直接设置音源属性。
    local handle = Effects.PlaySoundLooped(scene, path, {
        gain = gain,
    })
    if not handle then return end
    -- 音量直接落在音源上，不用属性动画淡入，避免引擎报错。
    if handle.source then
        handle.source.gain = gain
        handle.source.soundType = SOUND_MUSIC
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
