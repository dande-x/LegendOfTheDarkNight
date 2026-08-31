---@diagnostic disable: access-invisible, param-type-mismatch, assign-type-mismatch
-- ============================================================================
-- main.lua — 暗夜传奇 主入口
-- 俯视角 ARPG: 场景搭建 + 相机跟随 + 角色移动 + 施法系统 + 系统集成
-- ============================================================================

local UI = require("urhox-libs/UI")
local CharacterClass = require("scripts.CharacterClass")
-- Both `assets/` and `scripts/` are asset roots. A `scripts.` prefix can
-- resolve the legacy `assets/scripts/` mirror first, so keep the UI module
-- rooted at the canonical scripts asset directory.
local GameUI = require("GameUI")
-- 刷怪与地图配置必须命中 canonical scripts/，避免加载 assets/scripts 旧镜像。
local Combat = require("Combat")
local Inventory = require("scripts.Inventory")
local PlayerAnim = require("scripts.PlayerAnim")
-- Apply the same canonical-root rule to cloud-save APIs; the legacy mirror can
-- omit newer methods such as SaveSystem.LoadFromCloud.
local SaveSystem = require("SaveSystem")
local Quest = require("scripts.Quest")
local MapZone = require("MapZone")
-- NPC has a newer canonical implementation under scripts/NPC.lua.  The
-- `scripts.` module name can resolve the legacy assets/scripts mirror first.
local NPC = require("NPC")
local DivineBeast = require("scripts.DivineBeast")
local SoundManager = require("scripts.SoundManager")
local PlatformLeaderboard = require("scripts.PlatformLeaderboard")
local ShabakSiege = require("ShabakSiege")
-- 沙巴克的角色模型/AI 运行时是可选适配层。主流程先按契约接入，避免在
-- 运行时模块尚未同步到资源树时把普通地图和存档入口一并阻断。
local ShabakRuntime = nil
do
    local ok, loaded = pcall(require, "ShabakRuntime")
    if ok and type(loaded) == "table" then
        ShabakRuntime = loaded
    else
        print("[main] ShabakRuntime unavailable; siege entry will remain locked")
    end
end
require "urhox-libs.UI.GameHUD"

-- ============================================================================
-- 全局状态
-- ============================================================================
---@type Scene
local scene_ = nil
---@type Node
local cameraNode_ = nil
---@type Node
local playerNode_ = nil
local player_ = nil

-- 沙巴克是一次性实例，不把中途状态混入普通地图/存档生命周期。
---@type table|nil
local shabakSession_ = nil
---@type table|nil
local shabakRuntime_ = nil
local shabakEntryMapId_ = nil
local shabakPendingDefeat_ = false
local shabakResultShown_ = false
local shabakPendingResult_ = nil
local shabakPendingReason_ = nil

local StartShabakSiege
local FinishShabakSiege
local AbortShabakSiege
local DestroyShabakRuntime

local function IsShabakMap(mapId)
    return mapId == ShabakSiege.MAP_ID
end

local function IsShabakActive()
    return shabakSession_ ~= nil and type(shabakSession_.IsActive) == "function"
        and shabakSession_:IsActive()
end

-- 兼容 runtime 以对象方法或模块函数导出的两种写法。对象方法优先，
-- 模块函数作为旧资源树/热更新期间的回退；异常只记录，不让主循环崩溃。
local function CallShabakRuntime(methodNames, ...)
    if type(methodNames) == "string" then methodNames = { methodNames } end
    local targets = {}
    if shabakRuntime_ then targets[#targets + 1] = shabakRuntime_ end
    if ShabakRuntime and ShabakRuntime ~= shabakRuntime_ then
        targets[#targets + 1] = ShabakRuntime
    end
    for _, target in ipairs(targets) do
        for _, methodName in ipairs(methodNames or {}) do
            local okLookup, fn = pcall(function() return target[methodName] end)
            if okLookup and type(fn) == "function" then
                local ok, a, b, c, d = pcall(fn, target, ...)
                if ok then return a, b, c, d end
                print("[main] ShabakRuntime." .. tostring(methodName)
                    .. " failed: " .. tostring(a))
            end
        end
    end
    return nil
end

local function CallShabakModule(methodNames, ...)
    if not ShabakRuntime then return nil end
    if type(methodNames) == "string" then methodNames = { methodNames } end
    for _, methodName in ipairs(methodNames or {}) do
        local okLookup, fn = pcall(function() return ShabakRuntime[methodName] end)
        if okLookup and type(fn) == "function" then
            local ok, a, b, c, d = pcall(fn, ...)
            if ok then return a, b, c, d end
            print("[main] ShabakRuntime module " .. tostring(methodName)
                .. " failed: " .. tostring(a))
        end
    end
    return nil
end

local C = CharacterClass.Colors

-- 俯视角相机参数（传奇/暗黑风格斜45度俯视）
local CAM_OFFSET = Vector3(0, 12, -14)  -- 相机在玩家上方12m、后方14m
local CAM_FOV = 35

-- 药瓶系统
local hpPotionCD = 0
local mpPotionCD = 0
local HP_POTION_CD = 6.0
local MP_POTION_CD = 4.5

-- 玩家死亡
local DEATH_MARK_DURATION = 1.2
local deathTimer = 0
local deathPhase = "none" -- none | mark | result
local deathLossInfo = nil
local isDead = false

-- 存档系统
local currentSlotIndex = nil  -- 当前使用的存档槽位 (1 或 2)
local autoSaveTimer = 0
local AUTO_SAVE_INTERVAL = 30  -- 每30秒自动保存一次
local startupLogoReady = false
local cloudSaveReady = false
local cloudSyncResult = nil

-- 激励广告请求状态。SDK 可能同步回调、异步回调，也可能在请求未受理时
-- 完全不回调；序列号和 watchdog 共同保证迟到回调不会重复发奖或卡住入口。
local rewardAdInFlight = false
local rewardAdElapsed = 0
local rewardAdFinish = nil
local rewardAdRequestSerial = 0
local REWARD_AD_WATCHDOG_SECONDS = 60.0

-- 商人货架：同一地图/角色会话内保持稳定，避免每次打开面板都随机换货；
-- 五分钟后自动刷新，也可由玩家付费手动刷新。
local merchantShopState = {
    mapId = nil,
    classId = nil,
    expiresAt = 0,
    items = {},
}
local MERCHANT_STOCK_SIZE = 6
local MERCHANT_STOCK_TTL = 300
local MERCHANT_REFRESH_COST = 100

-- 跨地图任务完成后不再由任务系统主动切图。玩家通过安全区管家手动
-- 传送到目标地图，切图完成后把任务激活动作排到下一帧，避免在传送
-- 面板的点击回调里直接替换对话根节点。
local pendingQuestActivation = false
local ProcessPendingQuestActivation = nil
local HandleQuestMapEntered = nil
local pendingQuestPresentation = nil
local questPresentationDelayHint = 0
local ProcessPendingQuestPresentation = nil

-- 角色预览系统（存档选择界面用）
local previewNodes_ = {}         -- [1],[2] 预览角色节点
local previewAnimCtrls_ = {}     -- [1],[2] 预览 AnimationController
local previewSelectedSlot_ = 0   -- 当前选中的预览槽位
local previewActive_ = false     -- 是否处于预览模式
local previewAttackTimer_ = {}   -- [1],[2] 攻击动画循环计时器
local PREVIEW_POSITIONS = {      -- 两个预览角色的位置（远离游戏区域）
    Vector3(-0.75, 0, 200),      -- 槽位1角色（居中于左半屏视口）
    Vector3(0.75, 0, 200),       -- 槽位2角色（居中于右半屏视口）
}
local PREVIEW_CAM_POS = Vector3(0, 1.0, 196.5)  -- 预览摄像机位置（稍远，留出头顶空间）
local PREVIEW_CAM_LOOKAT = Vector3(0, 0.8, 200)  -- 看向角色腰部偏上
local PREVIEW_FOV = 28                           -- 预览模式 FOV（稍宽视角，确保头部完整）

-- ============================================================================
-- 施法状态机
-- ============================================================================
local castState = {
    active = false,
    phase = "none",      -- "none" | "windup" | "recovery"
    skill = nil,
    slot = 0,
    elapsed = 0,
    windupDuration = 0,   -- 前摇时间
    recoveryDuration = 0, -- 后摇时间
}

-- 默认施法时间表（按技能类型），技能自身的 castTime 优先
local DEFAULT_CAST_TIMES = {
    [CharacterClass.SKILL_TYPE.MELEE]  = { windup = 0.20, recovery = 0.20 },
    [CharacterClass.SKILL_TYPE.RANGED] = { windup = 0.15, recovery = 0.18 },
    [CharacterClass.SKILL_TYPE.AOE]    = { windup = 0.35, recovery = 0.20 },
    [CharacterClass.SKILL_TYPE.DOT]    = { windup = 0.30, recovery = 0.18 },
    [CharacterClass.SKILL_TYPE.BUFF]   = { windup = 0.25, recovery = 0.15 },
    [CharacterClass.SKILL_TYPE.HEAL]   = { windup = 0.30, recovery = 0.15 },
    [CharacterClass.SKILL_TYPE.DASH]   = { windup = 0.08, recovery = 0.15 },
    [CharacterClass.SKILL_TYPE.SUMMON] = { windup = 0.40, recovery = 0.20 },
}

-- 法师蓄力视觉节点
local chargeGlowNode = nil

-- ============================================================================
-- 平台排行榜：同一 TapTap 账号的两个角色槽位各项取最高值
-- ============================================================================
local function NormalizeLeaderboardValue(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return 0
    end
    return math.max(0, math.min(1000000000, math.floor(number)))
end

local function MergeLeaderboardScores(scores, source)
    scores.level = math.max(scores.level, NormalizeLeaderboardValue(source and source.level))
    scores.monster_kills = math.max(scores.monster_kills,
        NormalizeLeaderboardValue(source and source.killCount))
    scores.gold = math.max(scores.gold, NormalizeLeaderboardValue(source and source.gold))
end

local function CollectAccountLeaderboardScores()
    local scores = { level = 0, monster_kills = 0, gold = 0 }
    local slotCount = tonumber(SaveSystem.MAX_SLOTS) or 2
    for slotIndex = 1, slotCount do
        local source = SaveSystem.GetSlot(slotIndex)
        local useRuntime = slotIndex == currentSlotIndex and player_ ~= nil
        if useRuntime then
            source = {
                level = player_.level,
                killCount = type(Combat.GetKillCount) == "function"
                    and Combat.GetKillCount() or Combat.killCount,
                gold = Inventory.playerData and Inventory.playerData.gold or 0,
            }
        end
        if useRuntime or SaveSystem.IsLoadable(source) then
            MergeLeaderboardScores(scores, source)
        end
    end
    return scores
end

local function SyncAccountLeaderboard(callbacks)
    return PlatformLeaderboard.Sync(CollectAccountLeaderboardScores(), callbacks)
end

local function LoadPlatformLeaderboardBoard(boardId, callback)
    local fetchStarted = false
    local function fetchBoard()
        if fetchStarted then return end
        fetchStarted = true
        PlatformLeaderboard.Fetch(boardId, PlatformLeaderboard.TOP_COUNT, callback)
    end
    local syncStarted = SyncAccountLeaderboard({
        ok = fetchBoard,
        error = function() fetchBoard() end,
    })
    if not syncStarted and not fetchStarted then fetchBoard() end
    return true
end

-- ============================================================================
-- 引擎入口
-- ============================================================================
function Start()
    graphics.windowTitle = "暗夜传奇"

    startupLogoReady = false
    cloudSaveReady = false
    cloudSyncResult = nil

    GameUI.InitUI()
    GameUI.InitNanoVG()
    CreateScene()
    SetupCamera()

    -- 初始化本地存档后异步读取平台云存档。存档选择页要等云端合并完成，
    -- 避免玩家在云数据返回前点击并把旧本地状态再次写回云端。
    SaveSystem.Init()
    local function EnterSaveSlotsWhenReady()
        if not startupLogoReady or not cloudSaveReady then return end
        SyncAccountLeaderboard()
        ShowSaveSlotScreen()
        if cloudSyncResult then
            if cloudSyncResult.ok and cloudSyncResult.source == "local_uploaded" then
                GameUI.ShowToast("本地存档已同步到云端")
            elseif cloudSyncResult.ok
                and (cloudSyncResult.source == "cloud" or cloudSyncResult.source == "merged") then
                GameUI.ShowToast("云存档已同步")
            elseif not cloudSyncResult.ok and cloudSyncResult.code ~= "unavailable" then
                GameUI.ShowToast("云存档暂不可用，已使用本地存档")
            end
        end
    end
    local function HandleCloudSaveStartup(result)
        -- A stale runtime/module cache must not prevent the local save-slot
        -- screen from opening.  The canonical module normally supplies a
        -- result; this guard also covers older runtimes without cloud saves.
        if cloudSaveReady then return end
        result = type(result) == "table" and result or {
            ok = false,
            code = "unavailable",
            source = "local_only",
            reason = "平台云存档接口不可用",
        }
        cloudSyncResult = result
        cloudSaveReady = true
        print("[main] Cloud save startup sync: source=" .. tostring(result.source)
            .. " ok=" .. tostring(result.ok)
            .. (result.reason and (" reason=" .. tostring(result.reason)) or ""))
        EnterSaveSlotsWhenReady()
    end

    if type(SaveSystem.LoadFromCloud) == "function" then
        local cloudCallOk, cloudCallError = pcall(function()
            SaveSystem.LoadFromCloud(HandleCloudSaveStartup)
        end)
        if not cloudCallOk then
            print("[main] Cloud save startup sync failed: " .. tostring(cloudCallError))
            HandleCloudSaveStartup({
                ok = false,
                code = "exception",
                source = "local_only",
                reason = tostring(cloudCallError),
            })
        end
    else
        print("[main] Cloud save API unavailable; continuing with local saves")
        HandleCloudSaveStartup()
    end
    -- 初始化音效管理：绑定场景、加载设置、播放主界面背景音乐
    SoundManager.SetScene(scene_)
    SoundManager.LoadSettings()
    SoundManager.PlayMusic("menu")

    -- 先展示启动 Logo，再进入存档槽位选择界面
    GameUI.ShowStartupLogo(function()
        startupLogoReady = true
        EnterSaveSlotsWhenReady()
    end)

    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")
    SubscribeToEvent("AppWillEnterBackground", "HandleAppWillEnterBackground")
    SubscribeToEvent("AppTerminating", "HandleAppTerminating")
    print("=== 暗夜传奇 Started ===")
end

function Stop()
    GameUI.ClearHeldSkill()
    if IsShabakActive() or IsShabakMap(Combat.currentMapId) then
        AbortShabakSiege(ShabakSiege.RESULT_REASON.INTERRUPTED)
    end
    -- 退出前先把当前运行时状态落到本地，并发起一次 best-effort 云同步。
    -- 云端请求未必能在进程结束前完成，但本地存档会保留，下一次启动时
    -- 仍会继续上传，因此不会因退出时网络抖动丢失最近进度。
    if type(SaveCurrentGame) == "function" then
        SaveCurrentGame(true)
    end
    -- 当前角色会话结束即清空神兽召唤与成长状态。
    DivineBeast.Clear()
    -- 音频设置平时延迟写入，退出前强制落盘，避免最后一次操作丢失。
    SoundManager.FlushSettings()
    -- 停止背景音乐，避免退出时残留循环节点
    SoundManager.StopMusic()
    UI.Shutdown()
end

--- 应用进入后台前保存一次当前角色；移动端可能没有机会等到 Stop。
---@param eventType string|nil
---@param eventData table|nil
function HandleAppWillEnterBackground(eventType, eventData)
    GameUI.ClearHeldSkill()
    if IsShabakActive() or IsShabakMap(Combat.currentMapId) then
        -- 不保存攻城中途状态；让会话在后台边界中止并回到可保存地图。
        AbortShabakSiege(ShabakSiege.RESULT_REASON.INTERRUPTED)
    else
        SaveCurrentGame(true)
    end
    SoundManager.FlushSettings()
end

--- 应用收到终止通知时保存一次当前角色。
---@param eventType string|nil
---@param eventData table|nil
function HandleAppTerminating(eventType, eventData)
    GameUI.ClearHeldSkill()
    if IsShabakActive() or IsShabakMap(Combat.currentMapId) then
        AbortShabakSiege(ShabakSiege.RESULT_REASON.INTERRUPTED)
    else
        SaveCurrentGame(true)
    end
    SoundManager.FlushSettings()
end

-- ============================================================================
-- 场景
-- ============================================================================
function CreateScene()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    -- 添加物理世界（俯视角不需要重力）
    local physicsWorld = scene_:CreateComponent("PhysicsWorld")
    physicsWorld.gravity = Vector3(0, 0, 0)

    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Midnight.xml")
    local lightGroup = scene_:CreateChild("LightGroup")
    lightGroup:LoadXML(lightGroupFile:GetRoot())

    -- === 传奇 / 暗黑风格氛围 ===
    -- 使用 LightGroup 自带 Zone，只覆盖雾色和距离，避免创建新 Zone 抢占预设。
    local zone = lightGroup:GetComponent("Zone", true)
    if zone then
        zone.fogColor = Color(0.26, 0.29, 0.34, 1.0)
        zone.fogStart = 115.0
        zone.fogEnd = 280.0
        zone.fogDensity = 0.14
        zone.heightFog = false
    end

    -- 冷色主光保证无火把区域可读，火把负责局部暖色对比。
    local dirLight = lightGroup:GetComponent("Light", true)
    if dirLight then
        dirLight.color = Color(0.88, 0.92, 1.0, 1.0)
        dirLight.brightness = 2.25
        dirLight.castShadows = true
    end

    CreateFloor()
    CreateSceneDecorations("map_bq")
    print("[main] Scene created (with PhysicsWorld + dark fantasy atmosphere)")
end

function CreateFloor(groundColor)
    --[[
        暗黑地表设计：
        1. 大面积暗色泥土作为可行走底面（颜色可按地图传入，默认暗褐）。
        2. 一条弯曲破碎石板路贯穿出生点，提供视觉引导。
        3. 路边加入湿泥、苔藓、碎石色块，避免单调平面。
        4. 不生成抬高土台，避免角色和怪物在装饰地块上穿模。
    ]]
    local floorMapId = MapZone.GetCurrentMapId()
    local floorSeeds = {
        map_bq = 7301,
        map_mz = 7319,
        map_sc = 7331,
        map_wm = 7349,
        map_zm = 7367,
        map_sb = 7393,
    }
    math.randomseed(floorSeeds[floorMapId] or 7301)

    local function MakeMat(color, roughness, metallic, emissive)
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(color))
        mat:SetShaderParameter("Roughness", Variant(roughness or 0.85))
        mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
        if emissive then
            mat:SetShaderParameter("MatEmissiveColor", Variant(emissive))
        end
        return mat
    end

    local function GetMaterial(uri, fallback)
        local mat = cache:GetResource("Material", uri)
        if mat then return mat end
        return fallback
    end

    local soilColor = groundColor or Color(0.20, 0.16, 0.12, 1.0)
    -- 缓存材质必须克隆后再染色：直接返回共享 UUID 材质会让传入的
    -- groundColor 完全失效，五张地图最终仍显示同一块地表。
    local sharedSoilMat = cache:GetResource("Material", "uuid://B2-Y8QtOc5NdOQVWAmvW1aQ_")
    local darkSoilMat = sharedSoilMat and sharedSoilMat:Clone() or MakeMat(soilColor, 0.94, 0.0)
    darkSoilMat:SetShaderParameter("MatDiffColor", Variant(soilColor))
    local roadMat = GetMaterial("uuid://GSN7IaGGBlvP2Xk_zX9UQyuq", MakeMat(Color(0.32, 0.31, 0.29, 1.0), 0.86, 0.0))
    local wetMudMat = MakeMat(Color(0.10, 0.085, 0.075, 1.0), 0.72, 0.0)
    local mossMat = MakeMat(Color(0.13, 0.18, 0.10, 1.0), 0.90, 0.0)
    local ashMat = MakeMat(Color(0.075, 0.070, 0.072, 1.0), 0.96, 0.0)

    -- 主地面：Box 尺寸 1m，缩放后 120m × 120m，顶面位于 y=0。 
    local floorNode = scene_:CreateChild("DarkSoilFloor")
    floorNode.position = Vector3(0, -0.25, 0)
    floorNode.scale = Vector3(MapZone.ARENA_SIZE, 0.5, MapZone.ARENA_SIZE)
    local floorModel = floorNode:CreateComponent("StaticModel")
    floorModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    floorModel:SetMaterial(darkSoilMat)
    floorModel.castShadows = false

    -- 安全区视觉：只保留沿边界分布的竖直锥形光芒。
    -- 光芒底部贴地、锥尖朝上；中心必须与 Combat 的 spawnPos 判定一致，
    -- 避免以后地图出生点移动后视觉错位。
    local currentMapDef = MapZone.GetDef(MapZone.GetCurrentMapId())
    local safeCenter = (currentMapDef and currentMapDef.spawnPos) or Vector3.ZERO
    local safeRadius = MapZone.GetSafeZoneRadius(MapZone.GetCurrentMapId())
    local half = safeRadius

    local function IsOutsideSafeZone(x, z, padding)
        local margin = padding or 0
        return math.abs(x - safeCenter.x) > safeRadius + margin
            or math.abs(z - safeCenter.z) > safeRadius + margin
    end

    local function RandomFloorPoint(range, padding)
        for _ = 1, 32 do
            local x = (math.random() - 0.5) * range * 2
            local z = (math.random() - 0.5) * range * 2
            if IsOutsideSafeZone(x, z, padding) then return x, z end
        end
        return safeCenter.x + safeRadius + (padding or 0) + 2.0, safeCenter.z
    end

    -- 透明外锥 + 高亮窄芯组成“光芒”轮廓。Cone 的默认轴向为 Y，
    -- 因而只需把节点中心抬到高度的一半即可保证底部落地、顶部尖锐。
    local rayOuterMat = Material:new()
    rayOuterMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    rayOuterMat:SetShaderParameter("MatDiffColor", Variant(Color(0.18, 0.55, 1.0, 0.10)))
    rayOuterMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.25, 0.85, 2.6, 1.0)))
    rayOuterMat:SetShaderParameter("Metallic", Variant(0.0))
    rayOuterMat:SetShaderParameter("Roughness", Variant(0.16))
    rayOuterMat:SetCullMode(CULL_NONE)

    local rayCoreMat = Material:new()
    rayCoreMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    rayCoreMat:SetShaderParameter("MatDiffColor", Variant(Color(0.68, 0.9, 1.0, 0.32)))
    rayCoreMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.6, 2.6, 4.2, 1.0)))
    rayCoreMat:SetShaderParameter("Metallic", Variant(0.0))
    rayCoreMat:SetShaderParameter("Roughness", Variant(0.12))

    local gapInterval = safeRadius * 2 / 8   -- 每条边分 8 个锥形光芒位置
    local segLen = gapInterval * 0.5          -- 光芒沿边界居中分布
    local rayHeight = 0.77
    local rayDiameter = 0.22
    local rayCoreHeight = 0.68
    local rayCoreDiameter = 0.07
    for side = 0, 3 do
        -- side 0=上边(z=-half), 1=右边(x=+half), 2=下边(z=+half), 3=左边(x=-half)
        for seg = 0, 7 do
            local t0 = -half + seg * gapInterval
            local t1 = t0 + segLen
            local cx = (t0 + t1) / 2
            local pos = Vector3(safeCenter.x, 0.045, safeCenter.z)
            if side == 0 then
                pos = Vector3(safeCenter.x + cx, 0.045, safeCenter.z - half)
            elseif side == 1 then
                pos = Vector3(safeCenter.x + half, 0.045, safeCenter.z + cx)
            elseif side == 2 then
                pos = Vector3(safeCenter.x + cx, 0.045, safeCenter.z + half)
            else
                pos = Vector3(safeCenter.x - half, 0.045, safeCenter.z + cx)
            end

            -- 每个分段只放置一组更小、更矮、更通透的竖直锥形光芒，提升边界密度；
            -- 锥体的底面位于边界线上，顶部保持清晰的尖角轮廓。
            local rayIndex = seg
            local ray = scene_:CreateChild("SafeZoneRay_" .. side .. "_" .. rayIndex)
            ray.position = Vector3(pos.x, pos.y + rayHeight * 0.5, pos.z)
            ray.scale = Vector3(rayDiameter, rayHeight, rayDiameter)
            local rayModel = ray:CreateComponent("StaticModel")
            rayModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
            rayModel:SetMaterial(rayOuterMat)
            rayModel.castShadows = false

            local core = scene_:CreateChild("SafeZoneRayCore_" .. side .. "_" .. rayIndex)
            core.position = Vector3(pos.x, pos.y + rayCoreHeight * 0.5, pos.z)
            core.scale = Vector3(rayCoreDiameter, rayCoreHeight, rayCoreDiameter)
            local coreModel = core:CreateComponent("StaticModel")
            coreModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
            coreModel:SetMaterial(rayCoreMat)
            coreModel.castShadows = false
        end
    end

    -- 破碎主路：按路径点生成石板段。
    local paths = {
        map_bq = {
            Vector3(-43, 0, -31), Vector3(-34, 0, -23), Vector3(-24, 0, -16),
            Vector3(-13, 0, -8), Vector3(-3, 0, -2), Vector3(7, 0, 5),
            Vector3(16, 0, 13), Vector3(27, 0, 21), Vector3(40, 0, 29),
        },
        map_mz = {
            Vector3(-48, 0, -18), Vector3(-34, 0, -9), Vector3(-18, 0, -4),
            Vector3(0, 0, 0), Vector3(19, 0, 5), Vector3(35, 0, 13), Vector3(48, 0, 22),
        },
        map_sc = {
            Vector3(-38, 0, 34), Vector3(-24, 0, 20), Vector3(-12, 0, 11),
            Vector3(0, 0, 0), Vector3(10, 0, -13), Vector3(23, 0, -25), Vector3(38, 0, -36),
        },
        map_wm = {
            Vector3(-4, 0, -50), Vector3(-2, 0, -34), Vector3(0, 0, -18),
            Vector3(0, 0, 0), Vector3(1, 0, 18), Vector3(3, 0, 34), Vector3(5, 0, 50),
        },
        map_zm = {
            Vector3(-46, 0, 30), Vector3(-31, 0, 17), Vector3(-18, 0, 23),
            Vector3(-7, 0, 8), Vector3(0, 0, 0), Vector3(14, 0, -9),
            Vector3(27, 0, -4), Vector3(39, 0, -20), Vector3(48, 0, -34),
        },
        map_sb = {
            Vector3(0, 0, -50), Vector3(0, 0, -38), Vector3(0, 0, -24),
            Vector3(0, 0, -8), Vector3(0, 0, 10), Vector3(0, 0, 27),
            Vector3(0, 0, 38),
        },
    }
    local path = paths[floorMapId] or paths.map_bq
    for i = 1, #path - 1 do
        local a, b = path[i], path[i + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local len = math.sqrt(dx * dx + dz * dz)
        local yaw = math.deg(math.atan(dx, dz))
        local segments = math.max(2, math.floor(len / 2.4))
        for s = 1, segments do
            local t = (s - 0.5) / segments
            local x = a.x + dx * t + (math.random() - 0.5) * 0.55
            local z = a.z + dz * t + (math.random() - 0.5) * 0.55
            local slab = scene_:CreateChild("BrokenStoneRoad_" .. i .. "_" .. s)
            slab.position = Vector3(x, 0.035 + math.random() * 0.012, z)
            slab.scale = Vector3(3.3 + math.random() * 1.2, 0.055, 1.55 + math.random() * 0.65)
            slab.rotation = Quaternion(yaw + (math.random() - 0.5) * 9.0, Vector3.UP)
            local model = slab:CreateComponent("StaticModel")
            model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            model:SetMaterial(roadMat)
            model.castShadows = false
        end
    end

    -- 焦土 / 泥坑：按地图移到安全区之外，用多块重叠椭圆替代单个矩形。
    -- 旧实现固定盖在出生点附近，既让五张图同构，也把安全区视觉弄得很脏。
    local scorchCenters = {
        map_bq = Vector3(19, 0, -15),
        map_mz = Vector3(-20, 0, 16),
        map_sc = Vector3(19, 0, -16),
        map_wm = Vector3(-20, 0, -3),
        map_zm = Vector3(18, 0, 18),
        map_sb = Vector3(0, 0, 18),
    }
    local scorchCenter = scorchCenters[floorMapId] or scorchCenters.map_bq
    for i = 1, 7 do
        local t = (i - 4) / 3.0
        local pit = scene_:CreateChild("CentralScorchedPatch_" .. i)
        pit.position = Vector3(
            scorchCenter.x + t * 4.1 + (math.random() - 0.5) * 0.45,
            0.018 + i * 0.001,
            scorchCenter.z - t * 1.9 + (math.random() - 0.5) * 0.35
        )
        pit.scale = Vector3(4.0 + math.random() * 2.1, 0.035, 1.35 + math.random() * 0.85)
        pit.rotation = Quaternion(-26 + (math.random() - 0.5) * 24.0, Vector3.UP)
        local pitModel = pit:CreateComponent("StaticModel")
        pitModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        pitModel:SetMaterial(ashMat)
        pitModel.castShadows = false
    end
    for i = 1, 12 do
        local edge = scene_:CreateChild("ScorchedEdge_" .. i)
        local side = (i % 2 == 0) and 1 or -1
        local along = (math.random() - 0.5) * 13.5
        edge.position = Vector3(
            scorchCenter.x + along * 0.9,
            0.021 + i * 0.0005,
            scorchCenter.z + side * (1.4 + math.random() * 1.2) - along * 0.22
        )
        edge.scale = Vector3(1.1 + math.random() * 1.7, 0.026, 0.45 + math.random() * 0.8)
        edge.rotation = Quaternion(-26 + (math.random() - 0.5) * 55.0, Vector3.UP)
        local edgeModel = edge:CreateComponent("StaticModel")
        edgeModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        edgeModel:SetMaterial((i % 3 == 0) and wetMudMat or mossMat)
        edgeModel.castShadows = false
    end

    -- 地面斑驳层：湿泥 / 苔藓 / 灰烬，略高于地面。
    local patchMats = { wetMudMat, mossMat, ashMat }
    for i = 1, 34 do
        local p = scene_:CreateChild("GroundPatch_" .. i)
        local x, z = RandomFloorPoint(46, 0.8)
        p.position = Vector3(x, 0.018 + math.random() * 0.01, z)
        p.scale = Vector3(3.5 + math.random() * 5.5, 0.025, 1.8 + math.random() * 4.2)
        p.rotation = Quaternion(math.random() * 360, Vector3.UP)
        local model = p:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        model:SetMaterial(patchMats[math.random(1, #patchMats)])
        model.castShadows = false
    end

    math.randomseed(os.time())
    print("[main] Dark fantasy floor created: soil, broken stone road, ravine, patches")
end

function CreateSceneDecorations(mapId)
    --[[
        碰撞设计：
        - 主地面和石板路不加碰撞体，玩家保持 y=0 的俯视角移动规则。
        - 石堆、树干、墓碑、桥边柱等作为静态障碍，使用 layer=1。
        - 桥面本身不阻挡，方便玩家通过中央道路。
    ]]
    local decorSeeds = {
        map_bq = 9107,
        map_mz = 9127,
        map_sc = 9151,
        map_wm = 9173,
        map_zm = 9199,
        map_sb = 9221,
    }
    math.randomseed(decorSeeds[mapId] or 9107)
    local isBiqi = mapId == nil or mapId == "map_bq"
    local decorMapDef = MapZone.GetDef(mapId or "map_bq")
    local decorSafeCenter = (decorMapDef and decorMapDef.spawnPos) or Vector3.ZERO
    local decorSafeHalf = MapZone.GetSafeZoneRadius(mapId or "map_bq")

    local function RandomDecorPoint(range, padding)
        local margin = padding or 0
        for _ = 1, 32 do
            local x = (math.random() - 0.5) * range * 2
            local z = (math.random() - 0.5) * range * 2
            if math.abs(x - decorSafeCenter.x) > decorSafeHalf + margin
                or math.abs(z - decorSafeCenter.z) > decorSafeHalf + margin then
                return x, z
            end
        end
        return decorSafeCenter.x + decorSafeHalf + margin + 2.0, decorSafeCenter.z
    end

    local function MakeMat(color, roughness, metallic, emissive)
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(color))
        mat:SetShaderParameter("Roughness", Variant(roughness or 0.8))
        mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
        if emissive then
            mat:SetShaderParameter("MatEmissiveColor", Variant(emissive))
        end
        return mat
    end

    local function GetMaterial(uri, fallback)
        local mat = cache:GetResource("Material", uri)
        if mat then return mat end
        return fallback
    end

    local rockMat = GetMaterial("uuid://Hg04wSbDi8KsIwqNpUJ0OiwN", MakeMat(Color(0.24, 0.23, 0.22, 1.0), 0.9, 0.0))
    local rockDarkMat = MakeMat(Color(0.12, 0.115, 0.11, 1.0), 0.96, 0.0)
    local barkMat = GetMaterial("uuid://DdH4-Su6Cppk8qaKI2AiCLs-", MakeMat(Color(0.18, 0.12, 0.075, 1.0), 0.9, 0.0))
    local deadBarkMat = MakeMat(Color(0.105, 0.082, 0.065, 1.0), 0.96, 0.0)
    local leafMat = MakeMat(Color(0.075, 0.115, 0.065, 1.0), 0.92, 0.0)
    local bridgeWoodMat = GetMaterial("uuid://DdH4-Su6Cppk8qaKI2AiCLs-", MakeMat(Color(0.20, 0.13, 0.075, 1.0), 0.88, 0.0))
    local tombMat = MakeMat(Color(0.18, 0.18, 0.17, 1.0), 0.93, 0.0)
    local ironMat = MakeMat(Color(0.035, 0.033, 0.032, 1.0), 0.55, 0.55)
    local emberMat = MakeMat(Color(0.95, 0.28, 0.055, 1.0), 0.35, 0.0, Color(2.6, 0.7, 0.16, 1.0))
    local flameMat = MakeMat(Color(1.0, 0.58, 0.12, 1.0), 0.22, 0.0, Color(3.2, 1.2, 0.22, 1.0))

    local function AddStaticCollision(node, shapeKind, sizeOrRadius, center)
        local body = node:CreateComponent("RigidBody")
        body.mass = 0
        body.collisionLayer = 1
        body.collisionMask = 2 | 4
        local shape = node:CreateComponent("CollisionShape")
        if shapeKind == "box" then
            shape:SetBox(sizeOrRadius or Vector3(1, 1, 1), center or Vector3.ZERO)
        elseif shapeKind == "sphere" then
            shape:SetSphere(sizeOrRadius or 1.0)
        elseif shapeKind == "cylinder" then
            shape:SetCylinder(1.0, 1.0)
        end
    end

    local function CreateBox(name, pos, scale, rot, mat, castShadow, collisionSize, collisionCenter)
        local node = scene_:CreateChild(name)
        node.position = pos
        node.scale = scale
        node.rotation = Quaternion(rot or 0, Vector3.UP)
        local model = node:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        model:SetMaterial(mat)
        model.castShadows = castShadow ~= false
        if collisionSize then
            AddStaticCollision(node, "box", collisionSize, collisionCenter)
        end
        return node
    end

    local function CreateCylinder(name, pos, scale, rot, mat, castShadow, withCollision)
        local node = scene_:CreateChild(name)
        node.position = pos
        node.scale = scale
        node.rotation = Quaternion(rot or 0, Vector3.UP)
        local model = node:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        model:SetMaterial(mat)
        model.castShadows = castShadow ~= false
        if withCollision then AddStaticCollision(node, "cylinder") end
        return node
    end

    local function CreateSphere(name, pos, scale, mat, castShadow, withCollision)
        local node = scene_:CreateChild(name)
        node.position = pos
        node.scale = scale
        node.rotation = Quaternion(math.random() * 360, Vector3.UP)
        local model = node:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        model:SetMaterial(mat)
        model.castShadows = castShadow ~= false
        if withCollision then AddStaticCollision(node, "sphere", 1.0) end
        return node
    end

    if isBiqi then
    -- 比奇省专属破桥：桥面不阻挡角色，并避开出生安全区。
    local bridgeRoot = scene_:CreateChild("RuinedBridge")
    bridgeRoot.position = Vector3(15.0, 0.08, 12.0)
    bridgeRoot.rotation = Quaternion(64, Vector3.UP)
    for i = -4, 4 do
        local plank = bridgeRoot:CreateChild("BridgePlank_" .. i)
        plank.position = Vector3(i * 0.64, 0.10 + math.abs(i) * 0.006, 0)
        plank.scale = Vector3(0.52 + math.random() * 0.12, 0.16, 4.35 + math.random() * 0.35)
        plank.rotation = Quaternion((math.random() - 0.5) * 4.5, Vector3.UP)
        local model = plank:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        model:SetMaterial(bridgeWoodMat)
        model.castShadows = true
    end
    for side = -1, 1, 2 do
        for i = -1, 1 do
            local post = bridgeRoot:CreateChild("BridgePost_" .. side .. "_" .. i)
            post.position = Vector3(i * 2.4, 0.58, side * 2.15)
            post.scale = Vector3(0.18, 1.0, 0.18)
            local model = post:CreateComponent("StaticModel")
            model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            model:SetMaterial(deadBarkMat)
            model.castShadows = true
            AddStaticCollision(post, "cylinder")
        end
    end
    end

    -- 岩石群：沿道路边缘和高地脚下成组摆放。
    local rockClustersByMap = {
        map_bq = {
            Vector3(-31, 0, -18), Vector3(-19, 0, -7), Vector3(-12, 0, 9), Vector3(13, 0, -4),
            Vector3(23, 0, 15), Vector3(34, 0, 22), Vector3(-36, 0, 24), Vector3(31, 0, -26),
            Vector3(-27, 0, -31), Vector3(38, 0, 32), Vector3(-47, 0, 2), Vector3(45, 0, -9),
        },
        map_mz = {
            Vector3(-42, 0, -28), Vector3(-34, 0, 18), Vector3(-20, 0, 34), Vector3(18, 0, -35),
            Vector3(32, 0, -20), Vector3(44, 0, 12), Vector3(-45, 0, 8), Vector3(30, 0, 34),
        },
        map_sc = {
            Vector3(-46, 0, -34), Vector3(-42, 0, 25), Vector3(-24, 0, -42), Vector3(24, 0, 40),
            Vector3(43, 0, 18), Vector3(36, 0, -32), Vector3(-35, 0, 38), Vector3(44, 0, -6),
        },
        map_wm = {
            Vector3(-28, 0, -40), Vector3(28, 0, -40), Vector3(-33, 0, -15), Vector3(33, 0, -15),
            Vector3(-30, 0, 16), Vector3(30, 0, 16), Vector3(-26, 0, 39), Vector3(26, 0, 39),
        },
        map_zm = {
            Vector3(-42, 0, -30), Vector3(-32, 0, 16), Vector3(-20, 0, -38), Vector3(18, 0, 36),
            Vector3(34, 0, 18), Vector3(42, 0, -22), Vector3(-40, 0, 35), Vector3(28, 0, -42),
        },
        -- 沙巴克是按固定路线进行的攻城实例。这里明确使用空表，
        -- 不能回退到比奇省的随机岩石群，否则岩石碰撞会堵住
        -- 南门、战旗和皇宫封印之间的必经通道。
        map_sb = {},
    }
    local rockClusters = rockClustersByMap[mapId or "map_bq"] or rockClustersByMap.map_bq
    for i, pos in ipairs(rockClusters) do
        local count = 3 + math.random(0, 3)
        for j = 1, count do
            local x = pos.x + (math.random() - 0.5) * 2.2
            local z = pos.z + (math.random() - 0.5) * 2.2
            local sx = 0.7 + math.random() * 1.25
            local sy = 0.35 + math.random() * 0.75
            local sz = 0.65 + math.random() * 1.25
            CreateSphere("DarkRock_" .. i .. "_" .. j, Vector3(x, sy * 0.46, z), Vector3(sx, sy, sz),
                (j % 2 == 0) and rockDarkMat or rockMat, true, true)
        end
    end

    if isBiqi then
    -- 枯树、墓园和路边火把构成比奇省独有的边城荒野轮廓。
    local deadTreePositions = {
        Vector3(-41, 0, 18), Vector3(-30, 0, 34), Vector3(-18, 0, -32), Vector3(-7, 0, 30),
        Vector3(18, 0, -33), Vector3(30, 0, -16), Vector3(39, 0, 12), Vector3(45, 0, 33),
        Vector3(-44, 0, -11), Vector3(8, 0, 39), Vector3(27, 0, 31), Vector3(-24, 0, 13),
    }
    for i, pos in ipairs(deadTreePositions) do
        local h = 2.7 + math.random() * 2.2
        local trunk = CreateCylinder("DeadTree_" .. i, Vector3(pos.x, h * 0.5, pos.z), Vector3(0.32, h, 0.32),
            math.random() * 360, deadBarkMat, true, true)
        trunk.rotation = trunk.rotation * Quaternion((math.random() - 0.5) * 8.0, Vector3.FORWARD)

        local branchCount = 3 + math.random(0, 2)
        for b = 1, branchCount do
            local angle = math.rad(math.random() * 360)
            local y = h * (0.45 + math.random() * 0.38)
            local branch = scene_:CreateChild("DeadBranch_" .. i .. "_" .. b)
            branch.position = Vector3(pos.x + math.sin(angle) * 0.18, y, pos.z + math.cos(angle) * 0.18)
            branch.scale = Vector3(0.08, 0.85 + math.random() * 0.8, 0.08)
            branch.rotation = Quaternion(math.deg(angle), Vector3.UP) * Quaternion(58 + math.random() * 20, Vector3.RIGHT)
            local model = branch:CreateComponent("StaticModel")
            model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            model:SetMaterial(deadBarkMat)
            model.castShadows = true
        end

        if i % 4 == 0 then
            local crown = CreateSphere("SickCrown_" .. i, Vector3(pos.x, h + 0.7, pos.z), Vector3(2.0, 1.2, 2.0), leafMat, true, false)
            crown.rotation = Quaternion(math.random() * 360, Vector3.UP)
        end
    end

    -- 墓园：倾斜墓碑 + 石堆，提供暗黑/传奇据点感。
    local graves = {
        { pos = Vector3(-18, 0, 20), rot = -18 }, { pos = Vector3(-15, 0, 24), rot = 9 },
        { pos = Vector3(-21, 0, 26), rot = 22 }, { pos = Vector3(20, 0, -20), rot = -8 },
        { pos = Vector3(24, 0, -23), rot = 16 }, { pos = Vector3(28, 0, -19), rot = -30 },
    }
    for i, data in ipairs(graves) do
        local root = scene_:CreateChild("Grave_" .. i)
        root.position = data.pos
        root.rotation = Quaternion(data.rot, Vector3.UP)
        local slab = root:CreateChild("StoneSlab")
        slab.position = Vector3(0, 0.78, 0)
        slab.scale = Vector3(0.72, 1.55, 0.22)
        slab.rotation = Quaternion((math.random() - 0.5) * 10, Vector3.FORWARD)
        local slabModel = slab:CreateComponent("StaticModel")
        slabModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        slabModel:SetMaterial(tombMat)
        slabModel.castShadows = true
        local base = root:CreateChild("Base")
        base.position = Vector3(0, 0.12, 0.02)
        base.scale = Vector3(1.05, 0.24, 0.55)
        local baseModel = base:CreateComponent("StaticModel")
        baseModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        baseModel:SetMaterial(rockDarkMat)
        baseModel.castShadows = true
        AddStaticCollision(root, "box", Vector3(0.95, 1.5, 0.55), Vector3(0, 0.75, 0))
    end

    -- 火把：暖色局部光，形成暗黑场景中最重要的视觉焦点。
    local torchPositions = {
        Vector3(-9, 0, -5), Vector3(4, 0, 11), Vector3(11, 0, 8), Vector3(21, 0, 16),
        Vector3(-17, 0, 22), Vector3(22, 0, -22), Vector3(-35, 0, -23), Vector3(35, 0, 27),
    }
    for i, pos in ipairs(torchPositions) do
        local root = scene_:CreateChild("Torch_" .. i)
        root.position = pos
        local torchPole = CreateCylinder("TorchPole_" .. i, Vector3(pos.x, 0.72, pos.z), Vector3(0.08, 1.44, 0.08), 0, ironMat, true, true)
        local torchShape = torchPole:GetComponent("CollisionShape")
        if torchShape then
            torchShape:SetCylinder(1.6, 1.0)
        end
        CreateSphere("TorchEmber_" .. i, Vector3(pos.x, 1.48, pos.z), Vector3(0.28, 0.36, 0.28), emberMat, false, false)
        local flame = scene_:CreateChild("TorchFlame_" .. i)
        flame.position = Vector3(pos.x, 1.78, pos.z)
        flame.scale = Vector3(0.32, 0.62, 0.32)
        local flameModel = flame:CreateComponent("StaticModel")
        flameModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        flameModel:SetMaterial(flameMat)
        flameModel.castShadows = false
        local lightNode = scene_:CreateChild("TorchLight_" .. i)
        lightNode.position = Vector3(pos.x, 1.55, pos.z)
        local light = lightNode:CreateComponent("Light")
        light.lightType = LIGHT_POINT
        light.color = Color(1.0, 0.48, 0.14, 1.0)
        light.range = 8.5
        light.brightness = 5.5
        light.castShadows = false
    end
    end

    -- 破败木桩 / 栅栏边界，暗示可探索区域边缘。
    if isBiqi or mapId == "map_mz" then
    local fences = {
        { pos = Vector3(-46, 0, -3), rot = 8 }, { pos = Vector3(-45, 0, 2), rot = -7 },
        { pos = Vector3(-43, 0, 7), rot = 16 }, { pos = Vector3(44, 0, -14), rot = -15 },
        { pos = Vector3(46, 0, -9), rot = 3 }, { pos = Vector3(45, 0, -4), rot = 14 },
        { pos = Vector3(-10, 0, 44), rot = 86 }, { pos = Vector3(-5, 0, 45), rot = 93 },
        { pos = Vector3(0, 0, 44), rot = 82 },
    }
    for i, data in ipairs(fences) do
        CreateBox("BrokenFence_" .. i, Vector3(data.pos.x, 0.55, data.pos.z), Vector3(0.14, 1.1, 2.7),
            data.rot, deadBarkMat, true, Vector3(1, 1, 1), Vector3.ZERO)
    end
    end

    -- 暗色灌木/枯草：低矮、无碰撞，增加地面丰富度。
    if isBiqi or mapId == "map_mz" then
    local scrubMats = {
        MakeMat(Color(0.10, 0.13, 0.065, 1.0), 0.94, 0.0),
        MakeMat(Color(0.14, 0.115, 0.065, 1.0), 0.96, 0.0),
        MakeMat(Color(0.065, 0.09, 0.055, 1.0), 0.92, 0.0),
    }
    for i = 1, 80 do
        local x, z = RandomDecorPoint(48, 0.8)
        local h = 0.18 + math.random() * 0.26
        local blade = CreateBox("DarkScrub_" .. i, Vector3(x, h * 0.5, z), Vector3(0.045, h, 0.22 + math.random() * 0.20),
            math.random() * 360, scrubMats[math.random(1, #scrubMats)], false, nil, nil)
        blade.rotation = blade.rotation * Quaternion((math.random() - 0.5) * 18, Vector3.FORWARD)
    end
    end

    math.randomseed(os.time())

    -- 地图差异化装饰（按 mapId 分派标志性场景元素）
    if mapId then
        local mapDef = MapZone.GetDef(mapId)
        if mapDef then
            CreateMapDecorations(mapId, mapDef)
        end
    end

    print("[main] Map-specific dark fantasy decorations created for " .. tostring(mapId))
end

--- 为特定地图构建标志性装饰（差异化场景元素）
function CreateMapDecorations(mapId, mapDef)
    local function solid(color, roughness, emissive, metallic)
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(color))
        mat:SetShaderParameter("Roughness", Variant(roughness or 0.85))
        mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
        if emissive then
            mat:SetShaderParameter("MatEmissiveColor", Variant(emissive))
        end
        return mat
    end

    local function transparent(color, roughness, emissive)
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(color))
        mat:SetShaderParameter("Roughness", Variant(roughness or 0.2))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        if emissive then
            mat:SetShaderParameter("MatEmissiveColor", Variant(emissive))
        end
        return mat
    end

    local safeCenter = mapDef.spawnPos or Vector3.ZERO
    local safeHalf = MapZone.GetSafeZoneRadius(mapId)

    local function IsOutsideSafeZone(x, z, padding)
        local margin = padding or 2.0
        return math.abs(x - safeCenter.x) > safeHalf + margin
            or math.abs(z - safeCenter.z) > safeHalf + margin
    end

    local function RandomOutsideSafeZone(range, padding)
        for _ = 1, 32 do
            local x = safeCenter.x + (math.random() - 0.5) * range * 2
            local z = safeCenter.z + (math.random() - 0.5) * range * 2
            if IsOutsideSafeZone(x, z, padding) then return x, z end
        end
        return safeCenter.x + safeHalf + (padding or 2.0) + 3.0, safeCenter.z
    end

    local function AddMapCollision(node, shapeKind)
        local body = node:CreateComponent("RigidBody")
        body.mass = 0
        body.collisionLayer = 1
        body.collisionMask = 2 | 4
        local shape = node:CreateComponent("CollisionShape")
        if shapeKind == "cylinder" then
            shape:SetCylinder(1.0, 1.0)
        elseif shapeKind == "sphere" then
            shape:SetSphere(1.0)
        else
            shape:SetBox(Vector3(1, 1, 1))
        end
    end

    local function CreateMapModel(name, modelPath, pos, scale, mat, collisionKind)
        local node = scene_:CreateChild(name)
        node.position = pos
        node.scale = scale
        local model = node:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", modelPath))
        model:SetMaterial(mat)
        model.castShadows = true
        if collisionKind then AddMapCollision(node, collisionKind) end
        return node
    end

    if mapId == "map_bq" then
        -- 比奇省：把任务文本中的荒村与毒蛛巢真正落到场景里。
        local ruinMat = solid(Color(0.25, 0.22, 0.18, 1.0), 0.94)
        local charMat = solid(Color(0.07, 0.055, 0.045, 1.0), 0.98)
        local webMat = transparent(Color(0.50, 0.68, 0.54, 0.42), 0.34,
            Color(0.10, 0.30, 0.12, 1.0))

        local villageWalls = {
            { -31.4, -22.0, 0.45, 1.8, 5.2, 10 },
            { -28.7, -24.0, 4.6, 1.25, 0.42, -8 },
            { -27.4, -20.6, 0.42, 1.05, 3.2, -18 },
        }
        for i, data in ipairs(villageWalls) do
            local wall = CreateMapModel("VillageRuinWall_" .. i, "Models/Box.mdl",
                Vector3(data[1], data[4] * 0.5, data[2]), Vector3(data[3], data[4], data[5]),
                ruinMat, "box")
            wall.rotation = Quaternion(data[6], Vector3.UP)
        end
        local ash = CreateMapModel("VillageAsh", "Models/Sphere.mdl", Vector3(-30, 0.045, -22),
            Vector3(4.3, 0.08, 3.5), charMat, nil)
        local ashModel = ash:GetComponent("StaticModel")
        if ashModel then ashModel.castShadows = false end

        CreateMapModel("SpiderNest", "Models/Sphere.mdl", Vector3(28, 0.55, 22),
            Vector3(3.3, 1.1, 2.7), charMat, "sphere")
        local maw = CreateMapModel("SpiderNestMaw", "Models/Sphere.mdl", Vector3(27.05, 0.52, 21.15),
            Vector3(1.45, 0.62, 0.28), webMat, nil)
        maw.rotation = Quaternion(48, Vector3.UP)
        for i = 1, 7 do
            local angle = (i - 1) / 7 * math.pi * 2
            local egg = CreateMapModel("SpiderNestEgg_" .. i, "Models/Sphere.mdl",
                Vector3(28 + math.cos(angle) * 2.1, 0.22 + (i % 2) * 0.08, 22 + math.sin(angle) * 1.7),
                Vector3(0.34, 0.48, 0.34), webMat, nil)
            local eggModel = egg:GetComponent("StaticModel")
            if eggModel then eggModel.castShadows = false end
        end
    elseif mapId == "map_mz" then
        -- 盟重土城：开阔沙丘、带枝仙人掌和围城残墙。
        local sandMat = solid(Color(0.52, 0.42, 0.26, 1.0), 0.9)
        local cactusMat = solid(Color(0.18, 0.35, 0.16, 1.0), 0.8)
        local wallMat = solid(Color(0.44, 0.38, 0.28, 1.0), 0.9)
        for i = 1, 18 do
            local x, z = RandomOutsideSafeZone(44, 3.0)
            local s = 1.6 + math.random() * 2.4
            local dune = CreateMapModel("Dune_" .. i, "Models/Sphere.mdl",
                Vector3(x, 0.12, z), Vector3(s * 1.5, 0.45, s), sandMat, nil)
            dune.rotation = Quaternion(math.random() * 360, Vector3.UP)
            local model = dune:GetComponent("StaticModel")
            if model then model.castShadows = false end
        end
        for i = 1, 10 do
            local x, z = RandomOutsideSafeZone(40, 3.0)
            local h = 1.4 + math.random() * 1.2
            CreateMapModel("Cactus_" .. i, "Models/Cylinder.mdl",
                Vector3(x, h * 0.5, z), Vector3(0.24, h, 0.24), cactusMat, "cylinder")
            for armIndex = 1, 2 do
                local side = armIndex == 1 and -1 or 1
                local arm = CreateMapModel("Cactus_" .. i .. "_Arm_" .. armIndex,
                    "Models/Cylinder.mdl",
                    Vector3(x + side * 0.30, h * (0.48 + armIndex * 0.10), z),
                    Vector3(0.11, 0.55, 0.11), cactusMat, nil)
                -- 下端贴近主干、上端向外抬起，避免旧实现变成向下垂的“枯枝”。
                arm.rotation = Quaternion(-side * 62, Vector3.FORWARD)
            end
        end
        local wallSegments = {
            { -34, -40, 8, 1.7, 0.7, 8 }, { -17, -40, 6, 1.3, 0.7, -4 },
            { 20, -40, 7, 1.6, 0.7, 6 }, { 38, -30, 0.7, 1.5, 8, 0 },
            { 40, 15, 0.7, 1.8, 7, -3 }, { -40, 25, 0.7, 1.4, 8, 4 },
            { -27, 40, 8, 1.5, 0.7, -5 }, { 25, 40, 9, 1.7, 0.7, 5 },
        }
        for i, data in ipairs(wallSegments) do
            local wall = CreateMapModel("RuinedWall_" .. i, "Models/Box.mdl",
                Vector3(data[1], data[4] * 0.5, data[2]), Vector3(data[3], data[4], data[5]),
                wallMat, "box")
            wall.rotation = Quaternion(data[6], Vector3.UP)
        end
        -- 石墓入口：让第二幕“猪洞”不再只存在于对话文本。
        for _, data in ipairs({
            { "L", 27.7, 1.6, 20, 1.1, 3.2, 1.1 },
            { "R", 32.3, 1.6, 20, 1.1, 3.2, 1.1 },
            { "Top", 30, 3.45, 20, 5.6, 0.75, 1.2 },
        }) do
            CreateMapModel("StoneTombGate_" .. data[1], "Models/Box.mdl",
                Vector3(data[2], data[3], data[4]), Vector3(data[5], data[6], data[7]),
                wallMat, "box")
        end
        CreateMapModel("StoneTombDarkness", "Models/Box.mdl", Vector3(30, 1.35, 20.42),
            Vector3(2.8, 2.7, 0.08), solid(Color(0.025, 0.02, 0.018, 1.0), 1.0), nil)
    elseif mapId == "map_sc" then
        -- 水上城市：可见水道、木栈桥、珊瑚和带灯光的灯塔。
        local waterMat = transparent(Color(0.04, 0.30, 0.43, 0.72), 0.12, Color(0.02, 0.16, 0.24, 1.0))
        local coralMat = solid(Color(0.65, 0.22, 0.30, 1.0), 0.7)
        local pierMat = solid(Color(0.32, 0.24, 0.16, 1.0), 0.85)
        local towerMat = solid(Color(0.62, 0.64, 0.62, 1.0), 0.58)
        local beaconMat = solid(Color(1.0, 0.88, 0.48, 1.0), 0.18, Color(3.0, 2.2, 0.7, 1.0))
        local waterChannels = {
            { 0, -28, 50, 0.035, 13 }, { 0, 28, 50, 0.035, 13 },
            { -30, 0, 12, 0.035, 30 }, { 30, 0, 12, 0.035, 30 },
        }
        for i, data in ipairs(waterChannels) do
            local water = CreateMapModel("WaterChannel_" .. i, "Models/Box.mdl",
                Vector3(data[1], 0.018, data[2]), Vector3(data[3], data[4], data[5]), waterMat, nil)
            local model = water:GetComponent("StaticModel")
            if model then model.castShadows = false end
        end
        for i = 1, 8 do
            local z = 10 + i * 3.3
            CreateMapModel("DockWalkway_" .. i, "Models/Box.mdl", Vector3(0, 0.055, z),
                Vector3(4.8, 0.10, 2.8), pierMat, nil)
        end
        for i = 1, 16 do
            local x, z = RandomOutsideSafeZone(43, 3.0)
            local coral = CreateMapModel("Coral_" .. i, "Models/Sphere.mdl", Vector3(x, 0.26, z),
                Vector3(0.45 + math.random() * 0.8, 0.45 + math.random() * 0.9, 0.45 + math.random() * 0.8),
                coralMat, nil)
            coral.rotation = Quaternion(math.random() * 360, Vector3.UP)
            local model = coral:GetComponent("StaticModel")
            if model then model.castShadows = false end
        end
        for i = 1, 7 do
            local z = 10 + i * 4.0
            CreateMapModel("PierPost_L_" .. i, "Models/Cylinder.mdl",
                Vector3(-2.4, 0.72, z), Vector3(0.22, 1.44, 0.22), pierMat, "cylinder")
            CreateMapModel("PierPost_R_" .. i, "Models/Cylinder.mdl",
                Vector3(2.4, 0.72, z), Vector3(0.22, 1.44, 0.22), pierMat, "cylinder")
        end
        CreateMapModel("Lighthouse", "Models/Cylinder.mdl", Vector3(0, 2.8, 38),
            Vector3(1.6, 5.6, 1.6), towerMat, "cylinder")
        local lamp = CreateMapModel("LighthouseLamp", "Models/Sphere.mdl", Vector3(0, 6.05, 38),
            Vector3(0.65, 0.65, 0.65), beaconMat, nil)
        local lampModel = lamp:GetComponent("StaticModel")
        if lampModel then lampModel.castShadows = false end
        local lightNode = scene_:CreateChild("LighthouseLight")
        lightNode.position = Vector3(0, 6.05, 38)
        local light = lightNode:CreateComponent("Light")
        light.lightType = LIGHT_POINT
        light.color = Color(1.0, 0.82, 0.42, 1.0)
        light.range = 18.0
        light.brightness = 6.0
        light.castShadows = false
        -- 蚁穴入口：与第三幕 Boss 路由和全图地标对应。
        local nestMat = solid(Color(0.16, 0.11, 0.08, 1.0), 0.96)
        local nestGlow = solid(Color(0.11, 0.20, 0.09, 1.0), 0.7,
            Color(0.18, 0.55, 0.12, 1.0))
        CreateMapModel("AntNest", "Models/Sphere.mdl", Vector3(30, 0.58, -26),
            Vector3(3.6, 1.16, 3.0), nestMat, "sphere")
        local antMaw = CreateMapModel("AntNestOpening", "Models/Sphere.mdl", Vector3(29.2, 0.48, -25.25),
            Vector3(1.35, 0.58, 0.25), nestGlow, nil)
        antMaw.rotation = Quaternion(46, Vector3.UP)
    elseif mapId == "map_wm" then
        -- 沃玛寺庙：对称石柱长廊、出生区外祭坛、发光火盆。
        local pillarMat = solid(Color(0.42, 0.44, 0.48, 1.0), 0.6)
        local altarMat = solid(Color(0.24, 0.26, 0.30, 1.0), 0.7)
        local runeMat = solid(Color(0.30, 0.10, 0.08, 1.0), 0.35, Color(1.2, 0.18, 0.08, 1.0))
        local brazierMat = solid(Color(0.18, 0.12, 0.08, 1.0), 0.62, nil, 0.45)
        local flameMat = solid(Color(1.0, 0.32, 0.06, 1.0), 0.18, Color(3.0, 0.7, 0.12, 1.0))
        local pillarZ = { -34, -22, 22, 34 }
        local pillarIndex = 0
        for _, z in ipairs(pillarZ) do
            for _, x in ipairs({ -12, 12 }) do
                pillarIndex = pillarIndex + 1
                CreateMapModel("Pillar_" .. pillarIndex, "Models/Cylinder.mdl",
                    Vector3(x, 2.2, z), Vector3(0.8, 4.4, 0.8), pillarMat, "cylinder")
            end
        end
        local altarPos = safeCenter + Vector3(0, 0.6, 18)
        CreateMapModel("Altar", "Models/Box.mdl", altarPos,
            Vector3(4.6, 1.2, 4.6), altarMat, "box")
        for i = 1, 6 do
            local angle = (i - 1) * math.pi / 3
            local rune = CreateMapModel("TempleRune_" .. i, "Models/Box.mdl",
                Vector3(altarPos.x + math.sin(angle) * 4.2, 0.04, altarPos.z + math.cos(angle) * 4.2),
                Vector3(0.28, 0.035, 1.5), runeMat, nil)
            rune.rotation = Quaternion(math.deg(angle), Vector3.UP)
            local model = rune:GetComponent("StaticModel")
            if model then model.castShadows = false end
        end
        local brazierPositions = {
            Vector3(-7, 0, 13), Vector3(7, 0, 13), Vector3(-7, 0, 25), Vector3(7, 0, 25),
        }
        for i, pos in ipairs(brazierPositions) do
            CreateMapModel("Brazier_" .. i, "Models/Cylinder.mdl", Vector3(pos.x, 0.45, pos.z),
                Vector3(0.62, 0.9, 0.62), brazierMat, "cylinder")
            local flame = CreateMapModel("BrazierFlame_" .. i, "Models/Sphere.mdl", Vector3(pos.x, 1.12, pos.z),
                Vector3(0.34, 0.46, 0.34), flameMat, nil)
            local flameModel = flame:GetComponent("StaticModel")
            if flameModel then flameModel.castShadows = false end
            local lightNode = scene_:CreateChild("BrazierLight_" .. i)
            lightNode.position = Vector3(pos.x, 1.1, pos.z)
            local light = lightNode:CreateComponent("Light")
            light.lightType = LIGHT_POINT
            light.color = Color(1.0, 0.34, 0.08, 1.0)
            light.range = 8.0
            light.brightness = 4.0
            light.castShadows = false
        end
        -- 教主殿门：对应全图地标和终章 Boss 战方向。
        for _, data in ipairs({
            { "L", 27.4, 2.2, -28, 1.2, 4.4, 1.2 },
            { "R", 32.6, 2.2, -28, 1.2, 4.4, 1.2 },
            { "Top", 30, 4.55, -28, 6.4, 0.85, 1.3 },
        }) do
            CreateMapModel("WomarGate_" .. data[1], "Models/Box.mdl",
                Vector3(data[2], data[3], data[4]), Vector3(data[5], data[6], data[7]),
                altarMat, "box")
        end
        CreateMapModel("WomarGateDarkness", "Models/Box.mdl", Vector3(30, 1.65, -27.55),
            Vector3(3.2, 3.3, 0.08), solid(Color(0.025, 0.02, 0.035, 1.0), 1.0), nil)
    elseif mapId == "map_sb" then
        -- 沙巴克城：由南门、东西街、内城和皇宫组成一条清晰的攻城路线。
        -- 这里仅创建静态场景几何；城门/战旗/封印的可交互状态由
        -- ShabakRuntime + ShabakSiege 会话维护，避免装饰节点承载存档状态。
        local wallMat = solid(Color(0.20, 0.18, 0.19, 1.0), 0.88, nil, 0.15)
        local wallTopMat = solid(Color(0.31, 0.27, 0.25, 1.0), 0.78, nil, 0.20)
        local gateMat = solid(Color(0.18, 0.105, 0.055, 1.0), 0.82, nil, 0.08)
        local ironMat = solid(Color(0.08, 0.085, 0.10, 1.0), 0.48, nil, 0.68)
        local redFlagMat = solid(Color(0.60, 0.055, 0.045, 1.0), 0.72,
            Color(0.34, 0.015, 0.008, 1.0))
        local blueFlagMat = solid(Color(0.05, 0.20, 0.62, 1.0), 0.72,
            Color(0.02, 0.08, 0.32, 1.0))
        local sealMat = transparent(Color(0.52, 0.16, 0.72, 0.55), 0.22,
            Color(1.05, 0.22, 1.35, 1.0))
        local goldMat = solid(Color(0.66, 0.40, 0.10, 1.0), 0.40,
            Color(0.34, 0.16, 0.02, 1.0), 0.55)
        local fireMat = solid(Color(1.0, 0.34, 0.06, 1.0), 0.18,
            Color(3.0, 0.60, 0.08, 1.0))

        -- 外城墙：两侧纵墙 + 北侧皇宫墙，南门中央保留可见缺口。
        local outerWalls = {
            { "L", -46, 0.0, 6.0, 3.8, 92, 0 },
            { "R",  46, 0.0, 6.0, 3.8, 92, 0 },
            { "N",   0, 44.0, 92, 3.8, 6.0, 0 },
            { "SW", -25, -44.0, 34, 3.2, 5.0, 0 },
            { "SE",  25, -44.0, 34, 3.2, 5.0, 0 },
        }
        for _, data in ipairs(outerWalls) do
            local wall = CreateMapModel("ShabakWall_" .. data[1], "Models/Box.mdl",
                Vector3(data[2], data[4] * 0.5, data[3]),
                Vector3(data[5], data[4], data[6]), wallMat, "box")
            wall.rotation = Quaternion(data[7], Vector3.UP)
            local crenel = CreateMapModel("ShabakWall_" .. data[1] .. "_Crown",
                "Models/Box.mdl", Vector3(data[2], data[4] + 0.25, data[3]),
                Vector3(data[5] * 0.92, 0.42, data[6] * 0.88), wallTopMat, nil)
            crenel.rotation = Quaternion(data[7], Vector3.UP)
        end

        -- 南门门楼与可破坏门板。门板保持独立节点，运行时可在 0 HP 时隐藏。
        for side = -1, 1, 2 do
            CreateMapModel("ShabakGateTower_" .. tostring(side), "Models/Box.mdl",
                Vector3(side * 8.0, 3.0, -38), Vector3(5.0, 6.0, 7.0),
                wallMat, "box")
            CreateMapModel("ShabakGateTowerTop_" .. tostring(side), "Models/Box.mdl",
                Vector3(side * 8.0, 6.3, -38), Vector3(5.5, 0.55, 7.5),
                wallTopMat, nil)
        end
        local gate = CreateMapModel("ShabakGate", "Models/Box.mdl",
            Vector3(0, 2.05, -38), Vector3(10.0, 4.1, 0.72), gateMat, "box")
        gate:SetVar("siegeObjective", Variant("south_gate"))
        for i = -4, 4 do
            local bar = CreateMapModel("ShabakGateBar_" .. tostring(i), "Models/Box.mdl",
                Vector3(i * 1.05, 2.05, -37.55), Vector3(0.13, 4.0, 0.18),
                ironMat, nil)
            bar.rotation = Quaternion(2.0, Vector3.UP)
        end

        -- 东西街战旗与内城战旗：旗杆 + 旗面使用不同颜色，便于玩家在俯视角下识别。
        local function CreateSiegeFlag(id, position, material)
            local pole = CreateMapModel("ShabakFlagPole_" .. id, "Models/Cylinder.mdl",
                Vector3(position.x, 1.45, position.z), Vector3(0.14, 2.9, 0.14),
                ironMat, "cylinder")
            pole:SetVar("siegeObjective", Variant(id))
            local cloth = CreateMapModel("ShabakFlag_" .. id, "Models/Box.mdl",
                Vector3(position.x + 1.05, 2.25, position.z), Vector3(2.1, 0.92, 0.08),
                material, nil)
            cloth:SetVar("siegeObjective", Variant(id))
            return pole, cloth
        end
        CreateSiegeFlag("east_flag", Vector3(25, 0, -17), redFlagMat)
        CreateSiegeFlag("west_flag", Vector3(-25, 0, -17), blueFlagMat)
        CreateSiegeFlag("inner_flag", Vector3(0, 0, 4), goldMat)

        -- 皇宫封印：双柱、封印盘与门墙，给“破封”目标一个明确的可视焦点。
        local palaceLeft = CreateMapModel("ShabakPalace_Left", "Models/Box.mdl",
            Vector3(-13, 2.4, 24), Vector3(3.0, 4.8, 13.0), wallMat, "box")
        palaceLeft.rotation = Quaternion(-4, Vector3.UP)
        local palaceRight = CreateMapModel("ShabakPalace_Right", "Models/Box.mdl",
            Vector3(13, 2.4, 24), Vector3(3.0, 4.8, 13.0), wallMat, "box")
        palaceRight.rotation = Quaternion(4, Vector3.UP)
        CreateMapModel("ShabakPalace_Back", "Models/Box.mdl",
            Vector3(0, 2.4, 32), Vector3(26.0, 4.8, 2.2), wallMat, "box")
        local seal = CreateMapModel("ShabakSeal_palace_seal", "Models/Torus.mdl",
            Vector3(0, 0.16, 28), Vector3(4.2, 0.12, 4.2), sealMat, nil)
        seal:SetVar("siegeObjective", Variant("palace_seal"))
        local sealCore = CreateMapModel("ShabakSeal_Core", "Models/Sphere.mdl",
            Vector3(0, 0.22, 28), Vector3(1.0, 0.14, 1.0), sealMat, nil)
        sealCore:SetVar("siegeObjective", Variant("palace_seal"))

        -- 王座和四角火盆构成最终坚守区；不在王座模型上放刚体，避免玩家读条时卡位。
        CreateMapModel("ShabakThrone_Base", "Models/Box.mdl",
            Vector3(0, 0.38, 38), Vector3(8.0, 0.76, 6.0), goldMat, nil)
        CreateMapModel("ShabakThrone_Back", "Models/Box.mdl",
            Vector3(0, 2.2, 40.4), Vector3(5.8, 4.4, 0.75), wallTopMat, nil)
        for side = -1, 1, 2 do
            CreateMapModel("ShabakThrone_Arm_" .. tostring(side), "Models/Box.mdl",
                Vector3(side * 2.75, 1.3, 38), Vector3(0.72, 2.2, 4.6), goldMat, nil)
        end
        local brazierPositions = {
            Vector3(-9, 0, 27), Vector3(9, 0, 27), Vector3(-9, 0, 39), Vector3(9, 0, 39),
        }
        for index, pos in ipairs(brazierPositions) do
            CreateMapModel("ShabakBrazier_" .. index, "Models/Cylinder.mdl",
                Vector3(pos.x, 0.55, pos.z), Vector3(0.62, 1.1, 0.62), ironMat, "cylinder")
            CreateMapModel("ShabakBrazier_Flame_" .. index, "Models/Cone.mdl",
                Vector3(pos.x, 1.35, pos.z), Vector3(0.34, 0.68, 0.34), fireMat, nil)
            local lightNode = scene_:CreateChild("ShabakBrazierLight_" .. index)
            lightNode.position = Vector3(pos.x, 1.2, pos.z)
            local light = lightNode:CreateComponent("Light")
            light.lightType = LIGHT_POINT
            light.color = Color(1.0, 0.28, 0.08, 1.0)
            light.range = 8.0
            light.brightness = 3.6
            light.castShadows = false
        end
    elseif mapId == "map_zm" then
        -- 火龙魔窟：真正自发光的岩浆池、裂隙和带碰撞的熔岩石。
        -- 火龙王遭遇中心必须保持净空，避免动态刚体出生后被场景碰撞夹住。
        local lavaMat = solid(Color(0.82, 0.16, 0.025, 1.0), 0.26, Color(2.8, 0.46, 0.06, 1.0))
        local lavaGlowMat = solid(Color(1.0, 0.36, 0.04, 1.0), 0.16, Color(4.0, 0.85, 0.10, 1.0))
        local rockMat = solid(Color(0.16, 0.10, 0.08, 1.0), 0.95)
        local lairCenterX, lairCenterZ = 0, -32
        local lairClearRadius = 8.0
        local function RandomOutsideDragonLair(range, padding)
            for _ = 1, 32 do
                local x, z = RandomOutsideSafeZone(range, padding)
                local dx, dz = x - lairCenterX, z - lairCenterZ
                if dx * dx + dz * dz >= lairClearRadius * lairClearRadius then
                    return x, z
                end
            end
            return lairCenterX + lairClearRadius + 3.0, lairCenterZ
        end
        for i = 1, 7 do
            local x, z
            if i == 1 then
                x, z = -26, 22
            else
                x, z = RandomOutsideDragonLair(38, 4.0)
            end
            local pool = CreateMapModel("LavaPool_" .. i, "Models/Sphere.mdl", Vector3(x, 0.055, z),
                Vector3(2.8 + math.random() * 2.4, 0.10, 2.0 + math.random() * 2.2),
                (i == 1 or i % 2 == 0) and lavaGlowMat or lavaMat, nil)
            pool.rotation = Quaternion(math.random() * 360, Vector3.UP)
            local model = pool:GetComponent("StaticModel")
            if model then model.castShadows = false end
        end
        for i = 1, 18 do
            local x, z = RandomOutsideDragonLair(42, 3.0)
            local crack = CreateMapModel("LavaCrack_" .. i, "Models/Box.mdl", Vector3(x, 0.04, z),
                Vector3(0.10, 0.035, 1.2 + math.random() * 2.2), lavaGlowMat, nil)
            crack.rotation = Quaternion(math.random() * 360, Vector3.UP)
            local model = crack:GetComponent("StaticModel")
            if model then model.castShadows = false end
        end
        for i = 1, 12 do
            local x, z = RandomOutsideDragonLair(44, 3.0)
            local rock = CreateMapModel("LavaRock_" .. i, "Models/Sphere.mdl", Vector3(x, 0.4, z),
                Vector3(0.8 + math.random() * 1.2, 0.55 + math.random() * 0.8, 0.8 + math.random() * 1.2),
                rockMat, "sphere")
            rock.rotation = Quaternion(math.random() * 360, Vector3.UP)
        end

        -- 熔火龙巢只有地表与外围装饰，不创建任何碰撞体；Boss 可从中心直接追击玩家。
        local lairGround = CreateMapModel("DragonLair_Ground", "Models/Sphere.mdl",
            Vector3(lairCenterX, 0.025, lairCenterZ), Vector3(7.6, 0.045, 7.6), rockMat, nil)
        local lairGroundModel = lairGround:GetComponent("StaticModel")
        if lairGroundModel then lairGroundModel.castShadows = false end
        local lairRing = CreateMapModel("DragonLair_Ring", "Models/Torus.mdl",
            Vector3(lairCenterX, 0.09, lairCenterZ), Vector3(13.2, 0.28, 13.2), lavaGlowMat, nil)
        local lairRingModel = lairRing:GetComponent("StaticModel")
        if lairRingModel then lairRingModel.castShadows = false end
        for index = 1, 4 do
            local angle = (index - 1) / 4 * math.pi * 2 + math.pi * 0.25
            local x = lairCenterX + math.cos(angle) * 9.2
            local z = lairCenterZ + math.sin(angle) * 9.2
            CreateMapModel("DragonLair_Spire_" .. index, "Models/Cone.mdl",
                Vector3(x, 1.2, z), Vector3(0.72, 2.4, 0.72), rockMat, nil)
            local flame = CreateMapModel("DragonLair_Flame_" .. index, "Models/Sphere.mdl",
                Vector3(x, 2.58, z), Vector3(0.30, 0.52, 0.30), lavaGlowMat, nil)
            local flameModel = flame:GetComponent("StaticModel")
            if flameModel then flameModel.castShadows = false end
        end
        local lairLightNode = scene_:CreateChild("DragonLair_Light")
        lairLightNode.position = Vector3(lairCenterX, 1.6, lairCenterZ)
        local lairLight = lairLightNode:CreateComponent("Light")
        lairLight.lightType = LIGHT_POINT
        lairLight.color = Color(1.0, 0.22, 0.04, 1.0)
        lairLight.range = 15.0
        lairLight.brightness = 2.2
        lairLight.castShadows = false

        CreateMapModel("AbyssThroneBase", "Models/Box.mdl", Vector3(30, 0.45, 26),
            Vector3(5.2, 0.9, 4.2), rockMat, "box")
        CreateMapModel("AbyssThroneBack", "Models/Box.mdl", Vector3(30, 2.25, 27.4),
            Vector3(3.4, 3.6, 0.8), rockMat, "box")
        for side = -1, 1, 2 do
            CreateMapModel("AbyssThroneArm_" .. tostring(side), "Models/Box.mdl",
                Vector3(30 + side * 2.05, 1.25, 26), Vector3(0.65, 1.6, 3.6),
                rockMat, "box")
        end
    end
end

-- ============================================================================
-- 相机
-- ============================================================================
function SetupCamera()
    cameraNode_ = scene_:CreateChild("Camera")
    cameraNode_.worldPosition = CAM_OFFSET

    local camera = cameraNode_:CreateComponent("Camera")
    camera.nearClip = 0.5
    camera.farClip = 200.0
    camera.fov = CAM_FOV

    -- 初始朝向原点（玩家初始位置）
    cameraNode_:LookAt(Vector3(0, 0.8, 0))

    local viewport = Viewport:new(scene_, camera)
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true

    -- 把相机/场景引用传给 GameUI（用于世界坐标转换 + 暂停控制）
    GameUI.SetCamera(camera)
    GameUI.SetPlayerNode(playerNode_)
    GameUI.SetScene(scene_)
end

function UpdateCamera(dt)
    if not playerNode_ then return end

    -- 【修复】强制锁定玩家 Y=0（物理引擎碰撞穿透修正可能绕过 linearFactor）
    local pos = playerNode_.position
    if math.abs(pos.y) > 0.01 then
        playerNode_.position = Vector3(pos.x, 0, pos.z)
        -- 同时重置物理速度的 Y 分量
        local body = playerNode_:GetComponent("RigidBody")
        if body then
            local v = body:GetLinearVelocity()
            if math.abs(v.y) > 0.01 then
                body:SetLinearVelocity(Vector3(v.x, 0, v.z))
            end
        end
    end

    -- 地面视觉是 120m × 120m；角色胶囊中心需留出少量边距，避免走出
    -- 地面后小地图标记消失、怪物继续追到场景外。
    local boundedPos, hitBoundary = MapZone.ClampToArena(playerNode_.position, 0.75)
    if hitBoundary and boundedPos then
        playerNode_.position = boundedPos
        local body = playerNode_:GetComponent("RigidBody")
        if body then body:SetLinearVelocity(Vector3.ZERO) end
    end

    local playerPos = playerNode_.worldPosition
    local targetPos = playerPos + CAM_OFFSET

    -- 打击感屏幕震动
    local shakeOffset = PlayerAnim.GetCameraShakeOffset()
    targetPos = targetPos + shakeOffset
    -- 即时跟随（不用 lerp，消除延迟）
    cameraNode_.worldPosition = targetPos
    -- 始终朝向玩家位置（看角色腰部）
    cameraNode_:LookAt(playerPos + Vector3(0, 0.8, 0))
end

-- ============================================================================
-- 角色预览系统（存档选择界面展示3D角色）
-- ============================================================================

-- 预览用男角色动画路径
local PREVIEW_MALE_ANIM_PATHS = {
    idle       = "uuid://GikiEX04hbY9D5ALGNz051Zh",
    melee_fast = "uuid://Ai-SCaONHGJAnRCLZmoO2QJ8",
    cast_quick = "uuid://E3rZmUDaM9pq2-V2gj3pCyW4",
    staff_slam  = "uuid://AG7o2TcvrluLScFMCJltgkkF",
    sweep_l    = "uuid://BzVkoQzPfkBeIJ_SyLQNwXpI",
}

local PREVIEW_ANIM_SETS = {
    male = PREVIEW_MALE_ANIM_PATHS,
}

local function GetPreviewAnimPaths(classId)
    local ClassModules = {
        warrior = require("classes.Warrior"),
        mage    = require("classes.Mage"),
        taoist  = require("classes.Taoist"),
    }
    local classMod = ClassModules[classId] or ClassModules.warrior
    return PREVIEW_ANIM_SETS[classMod.animSet or "male"] or PREVIEW_MALE_ANIM_PATHS
end
local PREVIEW_ANIM_DURATIONS = {
    melee_fast = 1.07,
    cast_quick = 1.5,
    staff_slam = 1.37,
    sweep_l    = 1.33,
}
-- 各职业预览攻击动画，保持与实战职业动作一致。
local PREVIEW_CLASS_ATTACK = {
    warrior = "sweep_l",
    mage    = "staff_slam",
    taoist  = "cast_quick",
}

--- 创建预览角色（在远处，供存档界面展示）
---@param slotIndex number 1 或 2
---@param classId string "warrior"|"mage"|"taoist"
function CreatePreviewCharacter(slotIndex, classId, modelStyle, gender)
    -- 清除该槽位已有的预览
    DestroyPreviewCharacter(slotIndex)

    local node = scene_:CreateChild("Preview_" .. slotIndex)
    node.position = PREVIEW_POSITIONS[slotIndex]
    -- 角色面朝摄像机（朝 -Z 方向）
    node.rotation = Quaternion(180, Vector3.UP)

    -- 实例化 prefab
    local ClassModules = {
        warrior = require("classes.Warrior"),
        mage    = require("classes.Mage"),
        taoist  = require("classes.Taoist"),
    }
    local classMod = ClassModules[classId] or ClassModules.warrior
    local prefabPath = PlayerAnim.GetPrefabPath(classId, modelStyle, gender)

    local prefabFile = cache:GetFile(prefabPath)
    if not prefabFile then
        print("[Preview] ERROR: Cannot find prefab: " .. prefabPath)
        return
    end

    local parentScene = node:GetScene()
    local modelNode = parentScene:InstantiateXML(prefabFile, Vector3.ZERO, Quaternion.IDENTITY, LOCAL)
    prefabFile:Close()

    if not modelNode then
        print("[Preview] ERROR: Failed to instantiate prefab")
        return
    end

    modelNode.parent = node
    modelNode.name = "PreviewModel"
    -- reparent 保留 world transform，需要归零 local transform 以继承 parent 的 180°Y 旋转
    modelNode.rotation = Quaternion.IDENTITY
    modelNode.position = Vector3.ZERO

    local animModel = modelNode:GetComponent("AnimatedModel")
        or modelNode:GetComponent("AnimatedModel", true)

    if animModel then
        -- 缩放到标准高度
        local bb = animModel.boundingBox
        local h = bb.size.y
        local minY = bb.min.y
        if h > 0 then
            local s = 1.6 / h
            modelNode.scale = Vector3(s, s, s)
            modelNode.position = Vector3(0, -minY * s, 0)
        end

        -- 新模型预览保留职业 prefab 自带的完整模型与材质；旧模型沿用原有平滑处理。
        if modelStyle ~= "new" then
            local config = classMod.material
            if config.useTexture then
                local mat = Material:new()
                mat:SetTechnique(0, cache:GetResource("Technique", config.technique))
                mat:SetTexture(TU_DIFFUSE, cache:GetResource("Texture2D", "uuid://ARGvkYnzrbbOxkjh2N68upmG"))
                mat:SetShaderParameter("MatDiffColor", Variant(config.diffColor))
                mat:SetShaderParameter("Roughness", Variant(0.6))
                mat:SetShaderParameter("Metallic", Variant(0.2))
                mat:SetShaderParameter("MatEmissiveColor", Variant(config.emissive))
                local numGeom = animModel:GetNumGeometries()
                for i = 0, numGeom - 1 do
                    animModel:SetMaterial(i, mat)
                end
            end

            local smoothTech = cache:GetResource("Technique", "Techniques/PBR/PBRDiff.xml")
            local numGeom = animModel:GetNumGeometries()
            for i = 0, numGeom - 1 do
                local mat = animModel:GetMaterial(i)
                if mat then
                    mat = mat:Clone()
                    mat:SetTechnique(0, smoothTech)
                    mat:SetTexture(TU_NORMAL, nil)
                    mat:SetTexture(TU_SPECULAR, nil)
                    mat:SetShaderParameter("Roughness", Variant(0.8))
                    mat:SetShaderParameter("Metallic", Variant(0.0))
                    animModel:SetMaterial(i, mat)
                end
            end
        end
    end

    -- 获取动画控制器
    local animCtrl = modelNode:GetComponent("AnimationController")
        or modelNode:GetComponent("AnimationController", true)
    if not animCtrl then
        animCtrl = modelNode:CreateComponent("AnimationController")
    end

    previewNodes_[slotIndex] = node
    previewAnimCtrls_[slotIndex] = animCtrl
    previewAttackTimer_[slotIndex] = 0

    -- 默认播放 idle
    local previewAnimPaths = GetPreviewAnimPaths(classId)
    if animCtrl and previewAnimPaths.idle then
        animCtrl:PlayExclusive(previewAnimPaths.idle, 0, true, 0.0)
    end

    print("[Preview] Created character slot " .. slotIndex .. ": " .. classId)
end

--- 销毁预览角色
function DestroyPreviewCharacter(slotIndex)
    if previewNodes_[slotIndex] then
        previewNodes_[slotIndex]:Remove()
        previewNodes_[slotIndex] = nil
        previewAnimCtrls_[slotIndex] = nil
        previewAttackTimer_[slotIndex] = nil
    end
end

--- 销毁所有预览角色，恢复正常摄像机
function CleanupPreview()
    for i = 1, 2 do
        DestroyPreviewCharacter(i)
    end
    -- 移除背板、地面和预览灯光
    local backdrop = scene_:GetChild("PreviewBackdrop")
    if backdrop then backdrop:Remove() end
    local floor = scene_:GetChild("PreviewFloor")
    if floor then floor:Remove() end
    local keyLight = scene_:GetChild("PreviewKeyLight")
    if keyLight then keyLight:Remove() end
    local fillLight = scene_:GetChild("PreviewFillLight")
    if fillLight then fillLight:Remove() end
    -- 恢复游戏 FOV
    if cameraNode_ then
        local cam = cameraNode_:GetComponent("Camera")
        if cam then cam.fov = CAM_FOV end
    end
    previewActive_ = false
    previewSelectedSlot_ = 0
    GameUI.ClearSelectedSlot()
    print("[Preview] Cleanup done")
end

--- 设置预览选中状态（切换动画）
---@param slotIndex number 选中的槽位（0 表示无选中）
---@param classIds table {[1]=classId,[2]=classId} 各槽位的职业
function SetPreviewSelected(slotIndex, classIds)
    previewSelectedSlot_ = slotIndex
    for i = 1, 2 do
        local ctrl = previewAnimCtrls_[i]
        if ctrl then
            if i == slotIndex and classIds[i] then
                -- 选中：播放攻击动画（通过 timer 循环）
                local attackAnim = PREVIEW_CLASS_ATTACK[classIds[i]] or "melee_fast"
                local previewAnimPaths = GetPreviewAnimPaths(classIds[i])
                local animPath = previewAnimPaths[attackAnim]
                if animPath then
                    ctrl:PlayExclusive(animPath, 0, false, 0.2)
                    previewAttackTimer_[i] = PREVIEW_ANIM_DURATIONS[attackAnim] or 1.0
                end
            else
                -- 未选中：播放 idle
                local previewAnimPaths = GetPreviewAnimPaths(classIds[i])
                ctrl:PlayExclusive(previewAnimPaths.idle, 0, true, 0.2)
                previewAttackTimer_[i] = 0
            end
        end
    end
end

--- 每帧更新预览动画（循环攻击动画）
function UpdatePreviewAnimations(dt, classIds)
    if not previewActive_ then return end
    for i = 1, 2 do
        if i == previewSelectedSlot_ and previewAttackTimer_[i] and previewAttackTimer_[i] > 0 then
            previewAttackTimer_[i] = previewAttackTimer_[i] - dt
            if previewAttackTimer_[i] <= 0 then
                -- 重播攻击动画（循环）
                local classId = classIds[i]
                local attackAnim = PREVIEW_CLASS_ATTACK[classId] or "melee_fast"
                local previewAnimPaths = GetPreviewAnimPaths(classId)
                local animPath = previewAnimPaths[attackAnim]
                local ctrl = previewAnimCtrls_[i]
                if ctrl and animPath then
                    ctrl:PlayExclusive(animPath, 0, false, 0.1)
                    previewAttackTimer_[i] = PREVIEW_ANIM_DURATIONS[attackAnim] or 1.0
                end
            end
        end
    end
end

--- 激活预览模式（移动摄像机到预览位置，设置窄FOV + 深色背板）
function ActivatePreview()
    previewActive_ = true
    if cameraNode_ then
        cameraNode_.worldPosition = PREVIEW_CAM_POS
        cameraNode_:LookAt(PREVIEW_CAM_LOOKAT)
        local cam = cameraNode_:GetComponent("Camera")
        if cam then cam.fov = PREVIEW_FOV end
    end
    -- 创建预览专用正面补光（棚拍灯光，消除脸部阴影坑洼感）
    if not scene_:GetChild("PreviewKeyLight") then
        -- 主光：正面偏上，照亮面部
        local keyNode = scene_:CreateChild("PreviewKeyLight")
        keyNode.position = Vector3(0, 2.5, 197)  -- 在相机前方偏上
        keyNode:LookAt(Vector3(0, 1.0, 200))     -- 朝向角色面部
        local keyLight = keyNode:CreateComponent("Light")
        keyLight.lightType = LIGHT_SPOT
        keyLight.range = 12
        keyLight.fov = 60
        keyLight.color = Color(1.0, 0.95, 0.9)
        keyLight.brightness = 1.8
        keyLight.castShadows = false

        -- 补光：从下方柔和填充下巴/嘴部暗区
        local fillNode = scene_:CreateChild("PreviewFillLight")
        fillNode.position = Vector3(0, 0.3, 197.5)
        fillNode:LookAt(Vector3(0, 1.2, 200))
        local fillLight = fillNode:CreateComponent("Light")
        fillLight.lightType = LIGHT_SPOT
        fillLight.range = 10
        fillLight.fov = 50
        fillLight.color = Color(0.85, 0.88, 1.0)
        fillLight.brightness = 1.0
        fillLight.castShadows = false
    end
    -- 创建深色背板（大黑色平面在角色后方，让预览背景纯黑）
    if not scene_:GetChild("PreviewBackdrop") then
        local backdrop = scene_:CreateChild("PreviewBackdrop")
        backdrop.position = Vector3(0, 1.0, 202)  -- 在角色身后2m
        backdrop.scale = Vector3(12, 8, 0.05)     -- 足够大覆盖整个视野
        local mdl = backdrop:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(Color(0.02, 0.02, 0.02, 1.0)))
        mat:SetShaderParameter("Roughness", Variant(1.0))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        mdl:SetMaterial(mat)
        mdl.castShadows = false
    end
    -- 地面板（角色脚下深色地面）
    if not scene_:GetChild("PreviewFloor") then
        local floor = scene_:CreateChild("PreviewFloor")
        floor.position = Vector3(0, -0.02, 200)
        floor.scale = Vector3(8, 0.04, 4)
        local mdl = floor:CreateComponent("StaticModel")
        mdl:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(Color(0.04, 0.03, 0.03, 1.0)))
        mat:SetShaderParameter("Roughness", Variant(0.9))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        mdl:SetMaterial(mat)
        mdl.castShadows = false
    end
end

-- ============================================================================
-- 存档系统：槽位选择界面 & 自动保存
-- ============================================================================

--- 显示存档槽位选择界面（二维职业立绘，不实例化三维角色）
function ShowSaveSlotScreen()
    local slots = SaveSystem.GetAllSlots()

    -- 清理可能残留的旧三维预览；立绘动画由 GameUI 控件负责。
    CleanupPreview()

    -- 默认选中第一个有数据的槽位（如果没有持久化值的话默认选1）
    local defaultSelected = 1
    for i = 1, 2 do
        if slots[i] then defaultSelected = i; break end
    end
    -- 设置持久化选中（ShowSaveSlots 会读取此值）
    GameUI.SetSelectedSlot(defaultSelected)

    GameUI.ShowSaveSlots(slots, {
        onSelect = function(slotIndex)
            print("[main] Selected portrait slot " .. slotIndex)
        end,
        onContinue = function(slotIndex)
            -- 继续游戏：清除预览，加载存档
            CleanupPreview()
            currentSlotIndex = slotIndex
            local saveData = SaveSystem.GetSlot(slotIndex)
            if saveData and SaveSystem.IsLoadable(saveData) then
                LoadFromSave(saveData)
            elseif saveData then
                currentSlotIndex = nil
                GameUI.ShowToast("该存档已损坏，无法载入")
                print("[main] Refused to load invalid save in slot " .. tostring(slotIndex))
            end
        end,
        onCreate = function(slotIndex)
            -- 创建新角色：在当前选中槽位的模型展示区覆盖职业选择，不离开存档页
            currentSlotIndex = slotIndex
            GameUI.ShowClassSelect(function(classId, modelStyle, gender)
                OnClassSelected(classId, modelStyle, gender)
            end, true, slotIndex, function()
                currentSlotIndex = nil
            end)
        end,
        onDelete = function(slotIndex, onDone)
            -- 删除角色
            local deleted = SaveSystem.DeleteSlot(slotIndex)
            if deleted then
                SyncAccountLeaderboard()
                print("[main] Slot " .. slotIndex .. " deleted")
            else
                GameUI.ShowToast("删除角色失败，请重试")
            end
            if onDone then onDone(deleted) end
            -- 刷新界面（会重建预览）
            ShowSaveSlotScreen()
        end,
    })
end

--- 从存档加载游戏
function LoadFromSave(saveData)
    if not SaveSystem.IsLoadable(saveData) then
        print("[main] Refused to load invalid save")
        return false
    end
    local classId = SaveSystem.NormalizeClassId(saveData.classId)
    local gender = (saveData.gender == "female") and "female" or "male"
    local modelStyle = (saveData.modelStyle == "new" or saveData.modelStyle == "old")
        and saveData.modelStyle or (gender == "female" and "new" or "old")
    print("[main] Loading save: " .. tostring(saveData.className or classId)
        .. " Lv." .. tostring(saveData.level or 1))

    -- 载入另一个角色时先结束旧会话，避免单例神兽、旧敌人和旧玩家节点
    -- 泄漏到新角色；随后只恢复击杀数，神兽从未召唤的 Lv.1 状态开始。
    if shabakRuntime_ then DestroyShabakRuntime("load_save") end
    shabakRuntime_ = nil
    shabakSession_ = nil
    shabakEntryMapId_ = nil
    shabakPendingDefeat_ = false
    shabakResultShown_ = false
    shabakPendingResult_ = nil
    shabakPendingReason_ = nil
    Combat.SetExternalCombatMode(false)
    Combat.Clear(true, true)
    pendingQuestActivation = false
    pendingQuestPresentation = nil
    questPresentationDelayHint = 0
    if playerNode_ then
        playerNode_:Remove()
        playerNode_ = nil
    end
    player_ = nil

    -- 先初始化背包系统
    Inventory.Init()

    -- 恢复背包/装备/金币；失败时不要继续创建一个“半恢复”角色。
    -- 第二个返回值用于把旧强化石一次性折算成金币并立刻写回新存档。
    local inventoryRestored, legacyEnhanceRefund =
        SaveSystem.RestoreInventory(saveData, Inventory.playerData)
    if not inventoryRestored then
        currentSlotIndex = nil
        print("[main] ERROR: Failed to restore inventory from save")
        return false
    end

    -- 创建角色运行时对象
    player_ = CharacterClass.CreatePlayer(classId, 1, modelStyle, gender)
    if not player_ then
        currentSlotIndex = nil
        print("[main] ERROR: Failed to create player from save")
        return false
    end

    -- 恢复角色属性（等级、经验等）
    if not SaveSystem.RestorePlayer(saveData, player_) then
        player_ = nil
        currentSlotIndex = nil
        print("[main] ERROR: Failed to restore player from save")
        return false
    end

    -- 恢复击杀数。通过 Combat 的统一入口同步模块内部计数，避免只写
    -- 公开字段而导致下一次击杀覆盖读档值。
    Combat.SetKillCount(saveData.killCount or 0)

    -- 恢复主线任务进度
    Quest.Restore(saveData.quest)

    -- 恢复所在地图（默认比奇省）
    local mapId = type(saveData.mapId) == "string" and saveData.mapId or "map_bq"
    if not MapZone.GetDef(mapId) then
        print("[main] Unknown saved map " .. tostring(mapId) .. ", fallback to map_bq")
        mapId = "map_bq"
    end
    -- 旧版本可能在攻城中途写入了 map_sb；该实例不支持断点续战，
    -- 读档一律回到可保存的普通地图，荣誉字段仍按槽位正常恢复。
    if IsShabakMap(mapId) then
        print("[main] Saved Shabak instance has no resume state; fallback to map_bq")
        mapId = "map_bq"
    end
    Combat.SetMap(mapId)
    -- Combat.SetMap 当前也会同步 MapZone；这里保留显式调用作为读档边界
    -- 的自校验，防止未来替换战斗实现后地图视觉与刷怪状态再次分叉。
    MapZone.SetCurrentMap(mapId)

    -- 按存档地图重铺地面、装饰与雾色
    local mapDef = MapZone.GetDef(mapId)
    if mapDef then
        ClearDecorations()
        local oldFloor = scene_:GetChild("DarkSoilFloor")
        if oldFloor then oldFloor:Remove() end
        CreateFloor(mapDef.groundColor)
        CreateSceneDecorations(mapId)
        local zone = scene_:GetComponent("Zone", true)
        if zone then zone.fogColor = mapDef.fogColor end
        -- 生成安全区 NPC
        NPC.SpawnForMap(scene_, mapId, mapDef.spawnPos)
    end

    -- 创建角色节点并进入游戏
    CreatePlayerNode(classId, player_.modelStyle, player_.gender)
    GameUI.SetPlayerNode(playerNode_)
    -- 神兽不读取旧存档：道士每次进入角色都需重新召唤，并从 Lv.1
    -- 开始培养。LoadFromSave 开头的 Combat.Clear(true, true) 已清空
    -- 上一角色会话可能残留的神兽单例。
    GameUI.ShowGameHUD(player_)
    SetupGameCallbacks()
    -- 进入游戏：切换到战斗背景音乐
    SoundManager.PlayMusic("battle")

    -- 如果存档是在目标地图切换完成后、任务开场演出尚未消费前写下的，
    -- 读档边界也必须完成一次“进入目标地图”激活；不能把旅行状态卡住。
    local activatedOnLoad = HandleQuestMapEntered(mapId)

    -- 刷新任务追踪条
    local cur = Quest.GetCurrent()
    local p, c = Quest.GetProgress()
    GameUI.UpdateQuestTracker(cur, p, c)

    -- 触发当前任务剧情对话（读档后首次进入播放）
    if not activatedOnLoad then
        Quest.TriggerCurrentStart()
    else
        SaveCurrentGame()
    end

    -- 最终击杀已落盘、但尾声尚未看完时（例如真机被系统中断），读档后
    -- 补播一次；播完会写入 endingSeen，之后不再重复。
    if Quest.IsFinished() and not Quest.IsEndingSeen() then
        local finalQuest = Quest.CHAIN[#Quest.CHAIN]
        if finalQuest and finalQuest.completionDialogues then
            pendingQuestPresentation = {
                kind = "completion",
                quest = finalQuest,
                delay = 0.8,
            }
        end
    end

    -- 保留存档中的实际地图。任务栏会持续显示目标地图，玩家返回后从
    -- 已保存进度继续；读档不能把一次主动传送悄悄撤销。
    if #Combat.enemies == 0 then
        local initialCount = MapZone.GetSpawnSettings(Combat.currentMapId).initialCount
        for i = 1, initialCount do
            Combat.SpawnEnemy(scene_, playerNode_.position, player_.level, nil, Combat.currentMapId)
        end
    end

    GameUI.StartDoorOpen()
    if (legacyEnhanceRefund or 0) > 0 then
        GameUI.ShowToast("旧强化石已折算为 " .. legacyEnhanceRefund .. " 金币")
        SaveCurrentGame()
    end
    SyncAccountLeaderboard()
    print("[main] Game loaded from save: " .. tostring(player_.className)
        .. " Lv." .. tostring(player_.level))
    return true
end

--- 手动保存当前游戏到当前槽位
---@param skipLeaderboard boolean|nil 退出/后台保存时跳过额外的排行榜写入
function SaveCurrentGame(skipLeaderboard)
    if not player_ or not currentSlotIndex then return false end
    -- 沙巴克会话是临时实例；任何死亡/后台/退出边界都不得把 map_sb 或
    -- 未完成的守军/占领进度写进普通角色存档。
    if IsShabakActive() or IsShabakMap(Combat.currentMapId) then
        print("[main] Skip saving during Shabak siege")
        return false
    end
    if isDead or (tonumber(player_.hp) or 0) <= 0 then
        print("[main] Skip saving while player is dead")
        return false
    end
    local snapshot = SaveSystem.CreateSnapshot(player_, Inventory.playerData, Combat.killCount)
    if not snapshot then
        print("[main] ERROR: Cannot save invalid current player state")
        return false
    end
    local ok = SaveSystem.SaveToSlot(currentSlotIndex, snapshot)
    if ok then
        if not skipLeaderboard then
            SyncAccountLeaderboard()
        end
        print("[main] Auto-saved to slot " .. currentSlotIndex)
    end
    return ok
end

-- ============================================================================
-- 沙巴克攻城宿主适配
-- ============================================================================

local function GetShabakQuestState()
    if type(Quest.GetState) == "function" then return Quest.GetState() end
    return { finished = type(Quest.IsFinished) == "function" and Quest.IsFinished() }
end

local function GetShabakObjectivePosition(objectiveId)
    local contract = type(ShabakSiege.GetMapContract) == "function"
        and ShabakSiege.GetMapContract() or nil
    for _, landmark in ipairs(contract and contract.landmarks or {}) do
        if landmark.id == objectiveId then
            return Vector3(tonumber(landmark.x) or 0, tonumber(landmark.y) or 0,
                tonumber(landmark.z) or 0)
        end
    end
    return nil
end

local function GetShabakRallyPosition(rallyPoint)
    local runtimePosition = CallShabakRuntime(
        { "GetRallyPosition", "GetRallyPointPosition", "ResolveRallyPosition" },
        rallyPoint, playerNode_, player_, shabakSession_)
    if runtimePosition and runtimePosition.x and runtimePosition.z then
        return runtimePosition
    end
    local aliases = {
        entry = "south_gate",
        palace_gate = "palace_seal",
    }
    local objectiveId = aliases[rallyPoint] or rallyPoint
    return GetShabakObjectivePosition(objectiveId)
        or (MapZone.GetDef(ShabakSiege.MAP_ID)
            and MapZone.GetDef(ShabakSiege.MAP_ID).spawnPos)
        or Vector3.ZERO
end

local function UpdateShabakHUD()
    if not shabakSession_ then return end
    local snapshot = type(shabakSession_.GetSnapshot) == "function"
        and shabakSession_:GetSnapshot() or nil
    if type(GameUI.UpdateSiegeHUD) == "function" then
        pcall(GameUI.UpdateSiegeHUD, snapshot, shabakRuntime_, player_)
    elseif type(GameUI.SetSiegeHUDState) == "function" then
        pcall(GameUI.SetSiegeHUDState, snapshot, shabakRuntime_, player_)
    end
end

local function HideShabakHUD()
    if type(GameUI.HideSiegeHUD) == "function" then
        pcall(GameUI.HideSiegeHUD)
    elseif type(GameUI.SetSiegeHUDState) == "function" then
        pcall(GameUI.SetSiegeHUDState, nil)
    end
end

local function ApplyShabakSupplyEvent(event)
    if not player_ or type(event) ~= "table" then return end
    local hpRatio = math.max(0, math.min(1, tonumber(event.hpRatio) or 0))
    local mpRatio = math.max(0, math.min(1, tonumber(event.mpRatio) or hpRatio))
    local hpAmount = math.max(0, math.floor((tonumber(player_.maxHP) or 0) * hpRatio + 0.5))
    local mpAmount = math.max(0, math.floor((tonumber(player_.maxMP) or 0) * mpRatio + 0.5))
    local oldHP, oldMP = player_.hp, player_.mp
    player_.hp = math.min(player_.maxHP or player_.hp, (player_.hp or 0) + hpAmount)
    player_.mp = math.min(player_.maxMP or player_.mp, (player_.mp or 0) + mpAmount)
    local healed = (player_.hp or 0) - (oldHP or 0)
    local restored = (player_.mp or 0) - (oldMP or 0)
    if healed > 0 or restored > 0 then
        GameUI.AddFloatingText("补给 +" .. tostring(math.floor(healed)) .. " HP",
            playerNode_ and playerNode_.position or Vector3.ZERO,
            {120, 230, 150, 255})
    end
end

local function HandleShabakEvent(event)
    if type(event) ~= "table" then return end
    -- Session 既可通过 onEvent 直接派发，也会在 Update 后由宿主 Drain；
    -- 标记已处理事件，避免相同 table 被提示两次并重复结算补给。
    if event._shabakHandled then return end
    event._shabakHandled = true
    local eventType = event.type or event.event
    if eventType == "phase_changed" then
        local phaseNames = {
            south_gate = "南门突破",
            flags = "东西街夺旗",
            street_flags = "东西街夺旗",
            inner_flag = "内城夺旗",
            palace_seal = "击碎皇宫封印",
            throne = "占领城主王座",
            throne_defense = "王座坚守",
        }
        if phaseNames[event.phase] then
            GameUI.ShowToast("攻城阶段：" .. phaseNames[event.phase], 2.2)
        end
    elseif eventType == "field_supply_claimed" then
        ApplyShabakSupplyEvent(event)
        GameUI.ShowToast("前线补给已领取", 1.8)
    elseif eventType == "field_medkit_used" then
        GameUI.ShowToast("临时急救药已使用，剩余 " .. tostring(event.remaining or 0), 1.6)
    elseif eventType == "companion_down" then
        GameUI.ShowToast("支援队友倒下，推进到下一集结点后可复起", 2.2)
    elseif eventType == "companions_revived" then
        GameUI.ShowToast("队友已在集结点复起", 1.8)
    elseif eventType == "player_down" then
        shabakPendingDefeat_ = false
        GameUI.ShowToast("你倒下了，剩余命数：" .. tostring(event.livesRemaining or 0), 2.0)
    elseif eventType == "siege_victory" then
        shabakPendingResult_ = "victory"
        shabakPendingReason_ = nil
        GameUI.ShowToast("攻城成功：你成为沙巴克城主！", 3.5)
    elseif eventType == "siege_defeat" or eventType == "siege_aborted" then
        shabakPendingResult_ = "defeat"
        shabakPendingReason_ = event.reason or "战斗结束"
        GameUI.ShowToast("攻城失败：" .. tostring(shabakPendingReason_), 2.8)
    end
    UpdateShabakHUD()
end

local function DrainShabakEvents(events)
    if type(events) ~= "table" then return end
    if events.type then
        HandleShabakEvent(events)
        return
    end
    for _, event in ipairs(events) do HandleShabakEvent(event) end
end

DestroyShabakRuntime = function(reason)
    if shabakRuntime_ then
        CallShabakRuntime({ "Destroy", "Shutdown", "Dispose", "Stop" }, reason,
            shabakSession_, scene_)
    end
    if ShabakRuntime and shabakRuntime_ ~= ShabakRuntime then
        CallShabakModule({ "Destroy", "Shutdown", "Dispose" }, shabakRuntime_, reason,
            shabakSession_, scene_)
    end
    shabakRuntime_ = nil
end

local function BuildShabakRuntime(session)
    if not ShabakRuntime then return nil, "攻城运行时未加载" end
    local options = {
        session = session,
        mapId = ShabakSiege.MAP_ID,
        player = player_,
        playerNode = playerNode_,
        scene = scene_,
        combat = Combat,
        onEvent = HandleShabakEvent,
        itemFactory = Inventory.CreateItem,
    }
    local runtime = CallShabakModule({ "Create", "CreateRuntime", "New", "Start" },
        scene_, playerNode_, player_, session, options)
    if type(runtime) ~= "table" and runtime == true then runtime = ShabakRuntime end
    if type(runtime) ~= "table" then return nil, "攻城运行时创建失败" end
    shabakRuntime_ = runtime
    local initialized, initReason = CallShabakRuntime({ "Init", "Start", "Activate" }, scene_, playerNode_, player_,
        session, options)
    if initialized ~= true then
        DestroyShabakRuntime("init_failed")
        return nil, initReason or "攻城运行时初始化失败"
    end
    return runtime
end

-- ============================================================================
-- 地图切换（分支：地图系统）
-- ============================================================================
local MAP_ORDER = { "map_bq", "map_mz", "map_sc", "map_wm", "map_zm" }

-- 装饰节点前缀（切图时按前缀清理）
local DECOR_PREFIXES = {
    "BrokenStoneRoad_", "CentralScorchedPatch_", "ScorchedEdge_", "GroundPatch_",
    "RuinedBridge", "BridgePlank_", "BridgePost_",
    "DarkRock_", "DeadTree_", "DeadBranch_", "SickCrown_",
    "Grave_", "Torch_", "TorchPole_", "TorchEmber_", "TorchFlame_", "TorchLight_",
    "BrokenFence_", "DarkScrub_",
    "VillageRuin", "VillageAsh", "SpiderNest",
    "Dune_", "Cactus_", "RuinedWall_",
    "StoneTomb",
    "WaterChannel_", "DockWalkway_", "Coral_", "PierPost_", "Lighthouse",
    "AntNest",
    "Pillar_", "Altar", "TempleRune_", "Brazier_", "BrazierFlame_", "BrazierLight_",
    "WomarGate",
    "LavaPool_", "LavaCrack_", "LavaRock_",
    "DragonSlayer", "DragonLair_", "AbyssThrone",
    "ShabakWall_", "ShabakGate", "ShabakGateBar_", "ShabakFlag_", "ShabakFlagPole_",
    "ShabakPalace_", "ShabakSeal_", "ShabakThrone_", "ShabakBrazier_", "ShabakBrazierLight_",
    "SafeZone", "SafeZoneDash_", "SafeZoneNeedle_", "SafeZoneRay_", "SafeZoneRayCore_", "SafeZoneRing_",
    "QuestSignal", "QuestAreaEffect",
}

--- 清理所有装饰节点（切图时调用）
function ClearDecorations()
    local children = scene_:GetChildren()
    for i = #children, 1, -1 do
        local child = children[i]
        local name = child.name or ""
        local matched = false
        for _, prefix in ipairs(DECOR_PREFIXES) do
            if name:sub(1, #prefix) == prefix or name == prefix then
                matched = true
                break
            end
        end
        if matched then
            child:Remove()
        end
    end
end

local function RebuildMapVisuals(mapId)
    local mapDef = MapZone.GetDef(mapId)
    if not mapDef then return false end
    ClearDecorations()
    local oldFloor = scene_:GetChild("DarkSoilFloor")
    if oldFloor then oldFloor:Remove() end
    CreateFloor(mapDef.groundColor)
    CreateSceneDecorations(mapId)
    local zone = scene_:GetComponent("Zone", true)
    if zone then zone.fogColor = mapDef.fogColor end
    return true
end

local function SpawnNormalMapEntities(mapId)
    local mapDef = MapZone.GetDef(mapId)
    if not mapDef then return false end
    NPC.SpawnForMap(scene_, mapId, mapDef.spawnPos)
    local initialCount = MapZone.GetSpawnSettings(mapId).initialCount
    for _ = 1, initialCount do
        Combat.SpawnEnemy(scene_, playerNode_.position, player_.level, nil, mapId)
    end
    return true
end

local function ApplyShabakHonorPatch(session)
    if not player_ or not session or type(session.GetHonorPatch) ~= "function" then
        return false
    end
    local patch = session:GetHonorPatch()
    if type(patch) ~= "table" then return false end
    local honors = patch.honors or {}
    if honors.shabakLord == true or patch.titlePermanent == true then
        player_.shabakLord = true
    end
    local delta = tonumber(honors.shabakWinCountDelta or honors.shabakWinsDelta) or 0
    if delta > 0 then
        player_.shabakWinCount = math.max(0, math.floor(
            tonumber(player_.shabakWinCount) or 0) + math.floor(delta))
    end
    local best = tonumber(honors.shabakBestTime)
    if best and best > 0 then
        local previous = tonumber(player_.shabakBestTime) or 0
        if previous <= 0 or best < previous then player_.shabakBestTime = best end
    end
    return true
end

FinishShabakSiege = function(result, reason)
    local session = shabakSession_
    if not session and not IsShabakMap(Combat.currentMapId) then return false end
    local returnMapId = shabakEntryMapId_

    local victory = result == "victory"
        or (session and session.state == ShabakSiege.STATE.VICTORY)
    if session and not victory and not session:IsFinished() then
        session:Defeat(reason or ShabakSiege.RESULT_REASON.INTERRUPTED)
    end
    if victory then ApplyShabakHonorPatch(session) end

    DestroyShabakRuntime(reason or (victory and "victory" or "defeat"))
    Combat.Clear()
    Combat.SetExternalCombatMode(false)
    HideShabakHUD()
    GameUI.onUseSiegeMedkit = nil

    shabakSession_ = nil
    shabakEntryMapId_ = nil
    shabakPendingDefeat_ = false
    shabakResultShown_ = false
    shabakPendingResult_ = nil
    shabakPendingReason_ = nil
    isDead = false
    deathTimer = 0
    deathPhase = "none"
    deathLossInfo = nil
    GameUI.HideDeathPresentation()
    castState.active = false
    castState.phase = "none"
    castState.skill = nil
    castState.slot = 0
    castState.elapsed = 0
    GameUI.HideCastBar()
    ShowChargeGlow(false)

    if player_ then
        player_.hp = player_.maxHP
        player_.mp = player_.maxMP
    end

    if not returnMapId or IsShabakMap(returnMapId) or not MapZone.GetDef(returnMapId) then
        returnMapId = "map_bq"
    end
    -- Combat.Clear() deliberately preserves currentMapId, so explicitly move
    -- the combat map out of the temporary siege instance before routing through
    -- the normal SwitchMap path.  Otherwise SwitchMap sees map_sb as an active
    -- siege and rejects the return, forcing a degraded fallback (and showing an
    -- incorrect "攻城进行中" toast) after every victory/defeat.
    Combat.SetMap(returnMapId)
    -- SwitchMap 负责重建普通地图、NPC、自然刷怪和安全区；此时 session
    -- 已清空，故不会再次进入沙巴克分支。
    local switched = player_ and playerNode_ and SwitchMap(returnMapId)
    if not switched then
        Combat.SetMap(returnMapId)
        MapZone.SetCurrentMap(returnMapId)
        if playerNode_ then
            local def = MapZone.GetDef(returnMapId)
            playerNode_.position = def and def.spawnPos or Vector3.ZERO
        end
        RebuildMapVisuals(returnMapId)
        SpawnNormalMapEntities(returnMapId)
    end
    if victory then
        GameUI.ShowToast("沙巴克攻城成功：你已成为城主", 4.0)
        if playerNode_ then
            GameUI.AddFloatingText("沙巴克城主", playerNode_.position + Vector3(0, 1.35, 0),
                {255, 215, 70, 255})
        end
    else
        GameUI.ShowToast("攻城失败，已返回安全区", 3.0)
    end
    SaveCurrentGame()
    return true
end

AbortShabakSiege = function(reason)
    if not shabakSession_ and not IsShabakMap(Combat.currentMapId) then return false end
    if shabakSession_ and shabakSession_:IsActive() then
        shabakSession_:Abort(reason or ShabakSiege.RESULT_REASON.VOLUNTARY_EXIT)
    end
    return FinishShabakSiege("defeat", reason or ShabakSiege.RESULT_REASON.VOLUNTARY_EXIT)
end

StartShabakSiege = function()
    if not player_ or not playerNode_ then return false end
    if IsShabakActive() or IsShabakMap(Combat.currentMapId) then
        GameUI.ShowToast("攻城已在进行中", 1.8)
        return false
    end
    if not ShabakRuntime then
        GameUI.ShowToast("攻城运行时未就绪，请稍后重试", 2.4)
        return false
    end

    local questState = GetShabakQuestState()
    local allowed, reason = ShabakSiege.CanEnter(player_, questState)
    if not allowed then
        GameUI.ShowToast(reason or "暂时无法进入沙巴克城", 2.6)
        return false
    end

    local potionStatus = ShabakSiege.ValidatePotionSupply({
        hp = Inventory.GetPotionCount("hp"),
        mp = Inventory.GetPotionCount("mp"),
    })
    if potionStatus.warning then
        GameUI.ShowToast("提示：建议携带至少 8 瓶血瓶与 4 瓶蓝瓶", 3.0)
    end

    shabakEntryMapId_ = Combat.currentMapId
    if not MapZone.GetDef(shabakEntryMapId_) or IsShabakMap(shabakEntryMapId_) then
        shabakEntryMapId_ = "map_bq"
    end
    -- 先保存进入前的安全地图，确保攻城失败/中断后可以稳定回到该地图。
    SaveCurrentGame()

    local session, sessionReason = ShabakSiege.Begin(player_, {
        questState = questState,
        itemFactory = Inventory.CreateItem,
        onEvent = HandleShabakEvent,
    })
    if not session then
        GameUI.ShowToast(sessionReason or "攻城会话创建失败", 2.4)
        return false
    end
    shabakSession_ = session
    shabakPendingDefeat_ = false
    shabakResultShown_ = false
    shabakPendingResult_ = nil
    shabakPendingReason_ = nil

    GameUI.ClearHeldSkill()
    Combat.Clear()
    Combat.SetMap(ShabakSiege.MAP_ID)
    Combat.SetExternalCombatMode(true)
    MapZone.SetCurrentMap(ShabakSiege.MAP_ID)
    GameUI.RefreshMap(ShabakSiege.MAP_ID)
    RebuildMapVisuals(ShabakSiege.MAP_ID)
    NPC.Clear()
    local siegeDef = MapZone.GetDef(ShabakSiege.MAP_ID)
    if siegeDef then playerNode_.position = siegeDef.spawnPos end
    local body = playerNode_:GetComponent("RigidBody")
    if body then body:SetLinearVelocity(Vector3.ZERO) end
    DivineBeast.OnMapChanged(playerNode_.position)

    local runtime, runtimeReason = BuildShabakRuntime(session)
    if not runtime then
        shabakSession_ = nil
        Combat.Clear()
        Combat.SetMap(shabakEntryMapId_)
        Combat.SetExternalCombatMode(false)
        MapZone.SetCurrentMap(shabakEntryMapId_)
        RebuildMapVisuals(shabakEntryMapId_)
        SpawnNormalMapEntities(shabakEntryMapId_)
        GameUI.ShowToast(runtimeReason or "攻城运行时创建失败", 2.4)
        return false
    end
    GameUI.onUseSiegeMedkit = function()
        if not IsShabakActive() then return false end
        local used, result = CallShabakRuntime({ "UseFieldMedkit", "UseMedkit" }, player_)
        if used then
            -- Medkits share the regular HP-potion cooldown.  This keeps the
            -- siege fallback from bypassing the six-second recovery rhythm.
            hpPotionCD = HP_POTION_CD
            GameUI.ShowToast("已使用临时急救药", 1.5)
        else
            GameUI.ShowToast(type(result) == "string" and result or "没有临时急救药", 1.6)
        end
        UpdateShabakHUD()
        return used == true
    end
    if type(GameUI.ShowSiegeHUD) == "function" then
        GameUI.ShowSiegeHUD(session:GetSnapshot(), runtime, player_)
    end
    GameUI.ShowToast("进入沙巴克城：10 秒后开始攻城", 3.0)
    GameUI.AddFloatingText("沙巴克攻城战", playerNode_.position + Vector3(0, 1.25, 0),
        {255, 192, 86, 255})
    UpdateShabakHUD()
    return true
end

--- 切换到指定地图（清怪 + 改雾色 + 传送玩家 + 按图刷怪）
function SwitchMap(mapId)
    local mapDef = MapZone.GetDef(mapId)
    if not mapDef then
        print("[main] SwitchMap: unknown map " .. tostring(mapId))
        return false
    end
    if not scene_ or not player_ or not playerNode_ then
        print("[main] SwitchMap: game scene/player is not ready")
        return false
    end

    -- 沙巴克不是普通传送地图：进入时创建全新会话，离开时由会话结算并
    -- 返回进入前地图。任何普通地图切换请求都不能中途绕过攻城结算。
    if IsShabakMap(mapId) then
        return StartShabakSiege()
    end
    if IsShabakActive() or IsShabakMap(Combat.currentMapId) then
        GameUI.ShowToast("攻城进行中，完成或主动退出后才能离开", 2.2)
        return false
    end

    GameUI.ClearHeldSkill()

    -- 清空当前地图战斗实体与地面掉落；默认保留累计击杀数和本次
    -- 角色会话内培养的道士神兽。
    Combat.Clear()

    -- 设置战斗系统当前地图（决定按图刷怪池）
    Combat.SetMap(mapId)
    MapZone.SetCurrentMap(mapId)
    -- 先失效 HUD 的地图缓存，再重建场景；这样传送面板关闭前后
    -- 小地图/全图都不会继续复用上一张地图的地标与目标点。
    if type(GameUI.RefreshMap) == "function" then
        GameUI.RefreshMap(mapId)
    end

    -- 重铺地面与装饰（按地图主色，移除旧地面/装饰节点）
    ClearDecorations()
    local oldFloor = scene_:GetChild("DarkSoilFloor")
    if oldFloor then oldFloor:Remove() end
    CreateFloor(mapDef.groundColor)
    CreateSceneDecorations(mapId)

    -- 更新 Zone 雾色（主光色保持，仅切雾色体现地域差异）
    local zone = scene_:GetComponent("Zone", true)
    if zone then
        zone.fogColor = mapDef.fogColor
    end

    -- 玩家传送到该图出生点
    if playerNode_ then
        playerNode_.position = mapDef.spawnPos
        -- 神兽是跨地图持久实体：切图时只保留成长，不把旧地图的
        -- 喷火、狂暴、攻击计时或物理速度带进新地图。
        if player_.classId == "taoist" then
            DivineBeast.OnMapChanged(playerNode_.position)
        end
    end

    -- 生成安全区 NPC（管家 + 商人 + 铁匠）
    NPC.SpawnForMap(scene_, mapId, mapDef.spawnPos)

    -- 初始刷怪（按新地图怪物池）
    local initialCount = MapZone.GetSpawnSettings(mapId).initialCount
    for i = 1, initialCount do
        Combat.SpawnEnemy(scene_, playerNode_.position, player_.level, nil, mapId)
    end

    GameUI.ShowToast("进入：" .. mapDef.name)
    GameUI.AddFloatingText(mapDef.name, playerNode_.position + Vector3(0, 1.2, 0), {255, 215, 0, 255})

    -- 地图进入可能刚好完成一次等待中的跨地图任务激活；先消费状态，
    -- 再保存，确保崩溃恢复后不会回到“已到图但仍待传送”的假状态。
    HandleQuestMapEntered(mapId)

    -- 立即存档（地图落盘）
    SaveCurrentGame()

    print("[main] Switched to map: " .. mapId .. " (" .. mapDef.name .. ")")
    return true
end

--- 处理地图进入后的跨地图任务激活。
--- 只由 SwitchMap / LoadFromSave 调用 OnMapEntered；真正的开场演出排到
--- 下一帧，确保管家传送面板已经关闭，不会被 HUD 根节点覆盖。
HandleQuestMapEntered = function(mapId)
    local activated = Quest.OnMapEntered(mapId)
    if not activated then return false end

    pendingQuestActivation = true
    local quest = Quest.GetCurrent()
    local progress, count = Quest.GetProgress()
    GameUI.UpdateQuestTracker(quest, progress, count)
    return true
end

ProcessPendingQuestActivation = function()
    if not pendingQuestActivation then return false end
    -- 传送面板、其它对话或系统浮层仍在顶层时，继续等待；否则会把
    -- 新任务对话立即替换掉玩家当前正在看的界面。
    if GameUI.IsGamePaused() then return false end

    pendingQuestActivation = false
    local started = Quest.TriggerCurrentStart()
    if started then
        SaveCurrentGame()
    end
    return started
end

-- 任务世界坐标统一从目标数据生成。Quest 只保存纯坐标，主流程负责补齐
-- 渲染/刷怪需要的 Y 值，避免把引擎 Node 或材质状态塞回任务存档。
local function GetQuestWorldPosition(anchor, y)
    if type(anchor) ~= "table" then return nil end
    local x = tonumber(anchor.x)
    local z = tonumber(anchor.z)
    if not x or not z then return nil end
    return Vector3(x, tonumber(anchor.y) or (y or 0), z)
end

-- 坚守区域是当前任务的世界提示，不属于地图装饰。只在目标地图展示，
-- 站入区域且角色存活时切换到高亮；离开、死亡、切图或任务推进后自动熄灭/清理。
local function UpdateQuestAreaEffect()
    local quest = Quest.GetCurrent()
    if not scene_ or not playerNode_ or not player_
        or not quest or quest.mode ~= "survive"
        or quest.mapId ~= Combat.currentMapId
        or type(quest.area) ~= "table" then
        Combat.ClearQuestAreaEffect()
        return
    end

    local active = false
    if not isDead and (tonumber(player_.hp) or 0) > 0 then
        active = Quest.IsInsideObjective(playerNode_.position, quest.area)
    end
    Combat.SetQuestAreaEffect(scene_, quest.id, quest.area, active)
end

local function GetMerchantRequiredLevel(item)
    local rarityLevels = {
        COMMON = 1,
        UNCOMMON = 5,
        RARE = 12,
        EPIC = 25,
        LEGENDARY = 40,
    }
    return rarityLevels[item and item.rarity] or 1
end

local function GenerateMerchantStock(mapId, player)
    local candidates = {}
    local compatibleTemplates = Inventory.GetCompatibleItemTemplates(player.classId)
    for _, item in ipairs(compatibleTemplates) do
        local requiredLevel = GetMerchantRequiredLevel(item)
        -- 货架只展示当前等级可购买或略高一档的装备；终极传说装备留给
        -- 终章/Boss，避免商人直接跳过掉落与主线成长。
        if item.rarity ~= "LEGENDARY"
            and requiredLevel <= (player.level or 1) then
            table.insert(candidates, item)
        end
    end
    if #candidates == 0 then
        for _, item in ipairs(compatibleTemplates) do
            table.insert(candidates, item)
        end
    end

    local stock = {}
    while #stock < MERCHANT_STOCK_SIZE and #candidates > 0 do
        local index = math.random(1, #candidates)
        table.insert(stock, candidates[index])
        table.remove(candidates, index)
    end
    merchantShopState.mapId = mapId
    merchantShopState.classId = player.classId
    merchantShopState.expiresAt = os.time() + MERCHANT_STOCK_TTL
    merchantShopState.items = stock
end

local function EnsureMerchantStock(mapId, player)
    if merchantShopState.mapId ~= mapId
        or merchantShopState.classId ~= player.classId
        or os.time() >= (merchantShopState.expiresAt or 0)
        or #merchantShopState.items == 0 then
        GenerateMerchantStock(mapId, player)
    end
    return merchantShopState.items
end

local function RefreshMerchantStock(mapId, player)
    GenerateMerchantStock(mapId, player)
end

-- ============================================================================
-- 通用回调绑定（新建角色 & 加载存档共用）
-- ============================================================================
function SetupGameCallbacks()
    if not player_ or not playerNode_ then
        print("[main] ERROR: SetupGameCallbacks called without player/node")
        return
    end

    -- 绑定技能按钮回调（现在走施法状态机）
    GameUI.onSkillPressed = function(slot, skill)
        if isDead then return end
        if castState.active then return end  -- 施法中不可再按
        if GameUI.IsCharacterPanelOpen() then return end -- 角色面板打开时不放技能
        if GameUI.IsSystemPanelOpen() then return end -- 系统面板打开时不放技能
        if not skill then return end

        -- 安全区只禁止敌对技能；治疗、增益和召唤不属于“攻击”，应允许使用。
        -- 复用 Combat 的统一判断，避免未来地图出生点不在原点时出现 UI 与
        -- 最终伤害结算使用两套安全区中心。
        if playerNode_ and Combat.IsHostileSkill(skill)
            and Combat.IsInSafeZone(playerNode_.position) then
            GameUI.AddFloatingText("安全区内无法攻击", playerNode_.position + Vector3(0, 1.0, 0), {160, 200, 255, 255})
            return
        end
        local canCast, reason = CharacterClass.CanCastSkill(player_, skill)
        if not canCast then
            print("[main] Skill blocked: " .. reason)
            return
        end

        -- 计算前摇/后摇时间
        local defaults = DEFAULT_CAST_TIMES[skill.type] or { windup = 0.2, recovery = 0.1 }
        local windup = skill.castTime or defaults.windup
        local recovery = defaults.recovery

        -- 法师职业允许更短前摇，避免技能手感拖沓
        if player_.classId == "mage" and windup < 0.18 and skill.manaCost > 0 then
            windup = 0.18
        end

        -- 瞬发技能：不进入施法状态机，立即结算效果
        if skill.instant or windup <= 0 then
            local ok, result = Combat.CastSkill(scene_, player_, playerNode_, slot)
            if ok then
                PlayerAnim.PlaySkill(skill.animationType or skill.type)
                PlayerAnim.TriggerHitFeedback(0.8)
            else
                print("[main] Instant cast failed: " .. result)
                if result == "安全区内无法攻击" then
                    GameUI.AddFloatingText(result, playerNode_.position + Vector3(0, 1.0, 0), {160, 200, 255, 255})
                end
            end
            return
        end

        -- 自动瞄准：正前方最近 → 上次命中目标 → 最近目标
        local target = nil
        if Combat.IsHostileSkill(skill) then
            target = Combat.FindPriorityEnemy(playerNode_.position, playerNode_:GetDirection(), skill.range or 5)
        end
        if target then
            local dir = target.node.position - playerNode_.position
            dir.y = 0
            if dir:Length() > 0.1 then
                dir = dir:Normalized()
                local angle = math.atan2(dir.x, dir.z)
                playerNode_.rotation = Quaternion(math.deg(angle), Vector3.UP)
            end
        end

        -- 进入前摇
        castState.active = true
        castState.phase = "windup"
        castState.skill = skill
        castState.slot = slot
        castState.elapsed = 0
        castState.windupDuration = windup
        castState.recoveryDuration = recovery

        -- 立即停止移动（清零物理速度，防止惯性滑行）
        if playerNode_ then
            local body = playerNode_:GetComponent("RigidBody")
            if body then
                body:SetLinearVelocity(Vector3.ZERO)
            end
        end

        -- 播放对应攻击动画（根据职业+技能类型自动选择动画和速度）
        PlayerAnim.PlaySkill(skill.animationType or skill.type)

        -- 法师蓄力判定
        local isCharging = (player_.classId == "mage" and windup >= 0.3)

        -- 显示施法条（武士动作明显，不需要进度条）
        if player_.classId ~= "warrior" then
            GameUI.ShowCastBar(skill.name, isCharging)
        end

        -- 法师蓄力视觉效果
        if isCharging and playerNode_ then
            ShowChargeGlow(true)
        end

        print("[main] Cast start: " .. skill.name .. " windup=" .. string.format("%.2f", windup))
    end

    -- 药瓶回调（消耗制）
    GameUI.onUseHpPotion = function()
        if isDead or hpPotionCD > 0 then return end
        if castState.active then return end
        -- 满血时不能使用
        if player_.hp >= player_.maxHP then
            GameUI.AddFloatingText("生命已满", playerNode_.position, {200, 200, 200, 180})
            return
        end
        if not Inventory.UsePotion("hp") then
            -- 沙巴克补给箱提供的急救药只在真实血瓶耗尽后接管本次按钮；
            -- 不写入背包或普通存档，也不改变常规地图的药瓶规则。
            if IsShabakActive() and type(GameUI.onUseSiegeMedkit) == "function"
                and GameUI.onUseSiegeMedkit() then
                return
            end
            GameUI.AddFloatingText("强效金创药已空", playerNode_.position, {200, 200, 200, 200})
            return
        end
        local cfg = Inventory.POTION_CONFIG.hp
        local requestedHeal = math.max(1,
            math.floor(player_.maxHP * cfg.healRatio + 0.5))
        local oldHP = player_.hp
        player_.hp = math.min(player_.maxHP, player_.hp + requestedHeal)
        local heal = player_.hp - oldHP
        hpPotionCD = HP_POTION_CD
        GameUI.UpdatePotionCount("hp", Inventory.GetPotionCount("hp"))
        GameUI.AddFloatingText("+" .. math.floor(heal), playerNode_.position, {100, 255, 100, 255})
        SoundManager.Play("potion", { position = playerNode_.position })
    end

    GameUI.onUseMpPotion = function()
        if isDead or mpPotionCD > 0 then return end
        if castState.active then return end
        -- 满蓝时不能使用
        if player_.mp >= player_.maxMP then
            GameUI.AddFloatingText("法力已满", playerNode_.position, {150, 180, 255, 180})
            return
        end
        if not Inventory.UsePotion("mp") then
            GameUI.AddFloatingText("法力药水已空", playerNode_.position, {200, 200, 200, 200})
            return
        end
        local cfg = Inventory.POTION_CONFIG.mp
        local requestedRestore = math.max(1,
            math.floor(player_.maxMP * cfg.healRatio + 0.5))
        local oldMP = player_.mp
        player_.mp = math.min(player_.maxMP, player_.mp + requestedRestore)
        local restore = player_.mp - oldMP
        mpPotionCD = MP_POTION_CD
        GameUI.UpdatePotionCount("mp", Inventory.GetPotionCount("mp"))
        GameUI.AddFloatingText("+" .. math.floor(restore), playerNode_.position, {100, 180, 255, 255})
        SoundManager.Play("potion", { position = playerNode_.position })
    end

    -- 返回主菜单回调
    GameUI.onMenuPressed = function()
        ReturnToMainMenu()
    end

    -- 激励视频广告：只有 SDK 回调明确返回 result.success == true 时才解锁。
    GameUI.onRewardAdRequested = function()
        if rewardAdInFlight then
            GameUI.ShowToast("广告正在播放，请稍候", 2.0)
            return
        end
        if not player_ or not playerNode_ or isDead then
            GameUI.ShowRewardAdResult(false, "当前无法观看广告，请稍后再试。")
            return
        end

        rewardAdRequestSerial = rewardAdRequestSerial + 1
        local requestSerial = rewardAdRequestSerial
        local watchedPlayer = player_
        local watchedSlotIndex = currentSlotIndex
        local completed = false
        local callbackFired = false
        rewardAdInFlight = true
        rewardAdElapsed = 0

        local function finish(result)
            -- 页面已销毁或本次请求已被新请求取代时，忽略迟到回调。
            if completed or requestSerial ~= rewardAdRequestSerial then return end
            completed = true
            rewardAdInFlight = false
            rewardAdElapsed = 0
            rewardAdFinish = nil

            if result and result.success == true then
                -- 广告期间若角色会话已结束，不把奖励发给新角色或空会话。
                if player_ ~= watchedPlayer or currentSlotIndex ~= watchedSlotIndex
                    or not player_ or not playerNode_ or isDead then
                    print("[main] Reward ad completed after player session ended; reward ignored")
                    return
                end

                local wasUnlocked = player_.returnScrollUnlocked == true
                local rewardMessage
                if wasUnlocked then
                    -- 首次广告已解锁功能后，后续每次完整观看都奖励 1 枚金币。
                    -- AddGold 统一处理金币上限；成功回调仍只发放一次奖励。
                    local added = Inventory.AddGold(1)
                    if added then
                        GameUI.UpdateGold(Inventory.playerData.gold)
                        rewardMessage = "获取了 1 枚金币和作者的感恩。"
                    else
                        rewardMessage = "金币已达上限，仍感谢你的支持。"
                    end
                    SaveCurrentGame()
                else
                    -- 以广告回调时的完整运行时状态生成快照，再只改变当前槽位的
                    -- 解锁字段。这样不会因槽位级更新把刚获得的装备/金币回退到
                    -- 上一次自动保存的旧快照。
                    local snapshot = SaveSystem.CreateSnapshot(
                        watchedPlayer, Inventory.playerData, Combat.killCount)
                    local persisted = false
                    if snapshot and type(SaveSystem.SetReturnScrollUnlocked) == "function" then
                        persisted = SaveSystem.SetReturnScrollUnlocked(
                            watchedSlotIndex, true, snapshot)
                    elseif snapshot then
                        -- 兼容仍加载旧模块的预览入口；正式运行时应走上面的
                        -- 槽位级 API，以便 SaveToSlot 继续排队云同步。
                        snapshot.returnScrollUnlocked = true
                        persisted = SaveSystem.SaveToSlot(watchedSlotIndex, snapshot)
                    end
                    if not persisted then
                        GameUI.ShowRewardAdResult(false, "解锁保存失败，请稍后重试。")
                        print("[main] Reward ad completed but return-scroll unlock was not persisted")
                        return
                    end
                    player_.returnScrollUnlocked = true
                    if type(GameUI.RefreshReturnScrollAccess) == "function" then
                        pcall(GameUI.RefreshReturnScrollAccess)
                    end
                    rewardMessage = "获得“使用回城卷轴”功能！"
                end
                GameUI.ShowRewardAdResult(true, rewardMessage)
                return
            end

            local message = result and result.msg == "embed manual close"
                and "需完整观看广告才能获得奖励。"
                or "广告暂不可用，请稍后再试。"
            GameUI.ShowRewardAdResult(false, message)
        end

        rewardAdFinish = finish
        local sdkObject = rawget(_G, "sdk")
        if not sdkObject then
            finish({ success = false, msg = "unsupported platform" })
            return
        end

        local accepted = nil
        local ok, err = pcall(function()
            accepted = sdkObject:ShowRewardVideoAd(function(result)
                callbackFired = true
                finish(result)
            end)
        end)

        if not ok then
            print("[main] ShowRewardVideoAd failed: " .. tostring(err))
            finish({ success = false, msg = "广告暂不可用" })
        elseif accepted == false and not callbackFired then
            -- API 明确返回 false 且没有同步回调时，立即结束本次请求，
            -- 避免按钮状态永久占用；其它异常返回值交给 watchdog。
            finish({ success = false, msg = "广告暂不可用" })
        end
    end

    -- 使用回城卷轴：只移动到当前地图安全区，不切图、不重刷怪物或掉落。
    GameUI.onUseReturnScroll = function()
        if not player_ or not playerNode_ or isDead
            or (tonumber(player_.hp) or 0) <= 0 then
            return
        end
        if player_.returnScrollUnlocked ~= true then
            GameUI.ShowSupportAuthorDialog()
            return
        end

        local mapId = Combat.currentMapId
        if not MapZone.GetDef(mapId) and type(MapZone.GetCurrentMapId) == "function" then
            mapId = MapZone.GetCurrentMapId()
        end
        local mapDef = MapZone.GetDef(mapId)
        if not mapDef then
            GameUI.ShowToast("当前地图状态异常，请稍后再试", 2.0)
            return
        end

        Combat.CancelPlayerHostileEffects()
        Combat.CancelDash()

        castState.active = false
        castState.phase = "none"
        castState.skill = nil
        castState.slot = 0
        castState.elapsed = 0
        GameUI.HideCastBar()
        ShowChargeGlow(false)
        if GameUI.SetNPCInteract then GameUI.SetNPCInteract(false) end
        if GameUI._ResetJoystickState then GameUI._ResetJoystickState() end

        local target = mapDef.spawnPos or Vector3.ZERO
        playerNode_.position = Vector3(target.x, target.y, target.z)
        local body = playerNode_:GetComponent("RigidBody")
        if body then body:SetLinearVelocity(Vector3.ZERO) end
        if player_.classId == "taoist" then
            DivineBeast.OnMapChanged(playerNode_.position)
        end
        PlayerAnim.Play("idle")
        autoSaveTimer = 0
        GameUI.ShowToast("已使用回城卷轴，返回安全区", 2.0)
        GameUI.AddFloatingText(
            "使用回城卷轴",
            playerNode_.position + Vector3(0, 1.2, 0),
            {160, 210, 255, 255})
        SaveCurrentGame()
    end

    -- Debug 等级调整回调
    GameUI.onDebugLevelChange = function(delta)
        if not player_ then return end
        local currentLevel = CharacterClass.NormalizeLevel(player_.level)
        local newLevel = CharacterClass.NormalizeLevel(
            currentLevel + (tonumber(delta) or 0))
        if newLevel == currentLevel then return end

        player_.level = newLevel
        CharacterClass.ApplyDerivedStats(player_, Inventory.playerData, true)
        player_.expToNext = CharacterClass.GetExpToNext(newLevel)
        player_.exp = 0
        if newLevel > currentLevel and Combat.onLevelUp then
            Combat.onLevelUp(newLevel, newLevel - currentLevel)
        end
        print("[Debug] Level set to " .. newLevel)
        -- 刷新技能栏（解锁状态可能变化）
        GameUI.RefreshSkillButtons(player_)
    end

    -- 一键满级（兼容旧按钮）：至少设为 Lv.50 + 填充全部技能栏。
    GameUI.onDebugMaxLevel = function()
        if not player_ then return end
        local previousLevel = CharacterClass.NormalizeLevel(player_.level)
        local maxLv = math.max(previousLevel, 50)
        player_.level = maxLv
        CharacterClass.ApplyDerivedStats(player_, Inventory.playerData, true)
        player_.expToNext = CharacterClass.GetExpToNext(maxLv)
        player_.exp = 0
        if maxLv > previousLevel and Combat.onLevelUp then
            Combat.onLevelUp(maxLv, maxLv - previousLevel)
        end
        -- 按解锁等级从低到高装备全部主动技能到低位槽
        CharacterClass.RebuildEquippedSkills(player_, true)
        print("[Debug] MAX LEVEL! Lv." .. maxLv .. " all skills equipped")
        GameUI.RefreshSkillButtons(player_)
    end

    -- 隐藏调试入口：连续点击角色装备栏“鞋子”槽正好十二次，至少升到 Lv.50。
    GameUI.onDebugBootsSlotActivated = function()
        if not player_ then return false end

        local previousLevel = CharacterClass.NormalizeLevel(player_.level)
        local targetLevel = math.max(previousLevel, 50)
        player_.level = targetLevel
        CharacterClass.ApplyDerivedStats(player_, Inventory.playerData, true)
        player_.expToNext = CharacterClass.GetExpToNext(targetLevel)
        player_.exp = 0
        if targetLevel > previousLevel and Combat.onLevelUp then
            Combat.onLevelUp(targetLevel, targetLevel - previousLevel)
        end
        CharacterClass.RebuildEquippedSkills(player_, true)

        -- 鞋子槽点击发生在角色面板内；重建面板后立即让等级和技能显示同步。
        local reopenCharacterPanel = GameUI.IsCharacterPanelOpen()
        if reopenCharacterPanel then GameUI.HideCharacterPanel() end
        GameUI.RefreshSkillButtons(player_)
        if reopenCharacterPanel then GameUI.ShowCharacterPanel(player_, "equip") end

        print("[Debug] Boots slot sequence activated; level set to Lv." .. targetLevel)
        return true
    end

    -- 角色面板切换回调
    GameUI.onCharacterPanelToggle = function()
        if GameUI.IsCharacterPanelOpen() then
            GameUI.CloseCharacterPanel()
        else
            GameUI.ShowCharacterPanel(player_, "equip")
        end
    end

    -- 系统面板切换回调
    GameUI.onSystemPanelToggle = function()
        if GameUI.IsSystemPanelOpen() then
            GameUI.HideSystemPanel()
        else
            GameUI.ShowSystemPanel()
        end
    end

    GameUI.onLeaderboardPressed = function()
        GameUI.ShowLeaderboardPanel({
            boards = PlatformLeaderboard.GetBoards(),
            loadBoard = LoadPlatformLeaderboardBoard,
        })
    end

    -- 传送面板回调（已改为 NPC 管家对话传送，此回调保留用于兼容但不再由按钮触发）
    GameUI.onTeleportToggle = nil

    --- 读取角色实际所在地图。NPC 节点携带的 mapId 只作为最后回退，
    --- 避免切图边界上旧节点数据让传送列表排除错地图或计算错费用。
    ---@param npcMapId string|nil
    ---@return string|nil
    local function resolveCurrentMapId(npcMapId)
        local combatMapId = Combat.currentMapId
        local zoneMapId = MapZone.GetCurrentMapId()

        if MapZone.GetDef(combatMapId) then
            if MapZone.GetDef(zoneMapId) and zoneMapId ~= combatMapId then
                print("[main] Teleport map state mismatch: combat=" .. tostring(combatMapId)
                    .. ", zone=" .. tostring(zoneMapId))
            end
            return combatMapId
        end
        if MapZone.GetDef(zoneMapId) then return zoneMapId end
        if MapZone.GetDef(npcMapId) then return npcMapId end
        return nil
    end

    GameUI.onTeleportSelected = function(mapId)
        local targetDef = MapZone.GetDef(mapId)
        if not targetDef then
            GameUI.ShowToast("传送目标不存在，请重新打开传送面板", 2.0)
            print("[main] Teleport rejected unknown target: " .. tostring(mapId))
            return false
        end

        local currentMapId = resolveCurrentMapId(nil)
        if not currentMapId then
            GameUI.ShowToast("当前地图状态异常，请返回游戏后重试", 2.0)
            print("[main] Teleport rejected: current map is unavailable")
            return false
        end
        if mapId == currentMapId then
            GameUI.ShowToast("你已经在" .. targetDef.name)
            return false
        end

        -- 沙巴克是主线结束后的重复挑战入口，不属于普通地图路线：
        -- 必须同时满足主线完成和 Lv.50，且每次点击都创建新攻城实例。
        if IsShabakMap(mapId) then
            local allowed, reason = ShabakSiege.CanEnter(player_, GetShabakQuestState())
            if not allowed then
                GameUI.ShowToast(reason or "暂时无法挑战沙巴克城", 2.6)
                return false
            end
        end

        local currentQuest = Quest.GetCurrent()
        local questTargetMapId = Quest.GetTravelTargetMapId()
            or Quest.GetTargetMapId(currentQuest)
        local isQuestDestination = questTargetMapId == mapId

        -- 当前主线目标地图仍可按任务流程提前解锁，但传送一律按目的地收取金币。
        if not isQuestDestination and not MapZone.IsLevelAllowed(mapId, player_.level) then
            GameUI.ShowToast("等级不足，" .. MapZone.GetLevelRequirement(mapId), 2.0)
            return false
        end

        local cost = MapZone.GetTeleportCost(mapId)
        if cost > 0 and not Inventory.SpendGold(cost) then
            GameUI.ShowToast("金币不足，需要 " .. cost .. " 金币", 2.0)
            return false
        end

        local switched = SwitchMap(mapId)
        if not switched then
            if cost > 0 then Inventory.AddGold(cost) end
            GameUI.ShowToast(cost > 0 and "传送失败，金币已退回" or "传送失败，请重试", 2.0)
            return false
        end

        -- 传送到目标地图安全区；若这是等待中的下一张主线地图，
        -- SwitchMap 已记录激活动作，下一帧会播放新任务开场。
        SoundManager.Play("safe_zone")
        GameUI.SetNPCInteract(false)
        return true
    end

    -- 与管家交互：根据实时所在地图打开专用传送面板。
    local function openStewardPanel(npcMapId)
        local currentMapId = resolveCurrentMapId(npcMapId)
        local options = {}
        if currentMapId then
            options = NPC.GetTeleportOptions(currentMapId, player_.level)
            local currentQuest = Quest.GetCurrent()
            local questTargetMapId = Quest.GetTravelTargetMapId()
                or Quest.GetTargetMapId(currentQuest)
            for _, option in ipairs(options) do
                if option.id == questTargetMapId then
                    option.locked = false
                    option.lockReason = nil
                end
                -- 沙巴克不是主线中的普通目的地；只有完整主线结束后才
                -- 应在管家面板中显示为可点击的免费攻城入口。
                if IsShabakMap(option.id) and not GetShabakQuestState().finished then
                    option.locked = true
                    option.lockReason = "需完成全部主线"
                end
            end
        end

        print("[main] Open teleport panel: currentMap=" .. tostring(currentMapId)
            .. ", npcMap=" .. tostring(npcMapId)
            .. ", level=" .. tostring(player_.level)
            .. ", options=" .. tostring(#options))

        if #options == 0 then
            GameUI.ShowToast("未读取到传送路线，请关闭面板后重试", 2.0)
        end
        GameUI.ShowTeleportPanel(options)
    end

    -- 与商人交互：打开商店（「购买」标签：药水 + 装备；「出售」标签：卖背包装备）
    local function openMerchantPanel(selectedTab)
        -- ============ 购买 tab ============
        local function buildBuyRows()
            local hpCfg = Inventory.POTION_CONFIG.hp
            local mpCfg = Inventory.POTION_CONFIG.mp
            local rows = {
                {
                    text = "强效金创药（恢复 " .. math.floor(hpCfg.healRatio * 100 + 0.5) .. "% 生命）",
                    hint = "💰" .. hpCfg.price .. "  拥有 "
                        .. Inventory.GetPotionCount("hp") .. "/" .. hpCfg.max,
                    onTap = function()
                        local ok, msg = Inventory.BuyPotionFromMerchant("hp")
                        if ok then
                            GameUI.UpdatePotionCount("hp", Inventory.GetPotionCount("hp"))
                            GameUI.ShowToast("购买成功：强效金创药 +1")
                        else
                            GameUI.ShowToast(msg or "购买失败")
                        end
                        GameUI.HideNPCPanel()
                        openMerchantPanel(1)
                    end,
                },
                {
                    text = "法力药水（恢复 " .. math.floor(mpCfg.healRatio * 100 + 0.5) .. "% 法力）",
                    hint = "💰" .. mpCfg.price .. "  拥有 "
                        .. Inventory.GetPotionCount("mp") .. "/" .. mpCfg.max,
                    onTap = function()
                        local ok, msg = Inventory.BuyPotionFromMerchant("mp")
                        if ok then
                            GameUI.UpdatePotionCount("mp", Inventory.GetPotionCount("mp"))
                            GameUI.ShowToast("购买成功：法力药水 +1")
                        else
                            GameUI.ShowToast(msg or "购买失败")
                        end
                        GameUI.HideNPCPanel()
                        openMerchantPanel(1)
                    end,
                },
            }

            -- 装备货架：按职业/等级筛选，并在五分钟内保持不变。
            local shopItems = EnsureMerchantStock(Combat.currentMapId, player_)
            for _, tmpl in ipairs(shopItems) do
                local price = Inventory.GetItemPrice(tmpl)
                local rarityName = Inventory.GetRarityName(tmpl.rarity)
                local rarityColor = Inventory.GetRarityColor(tmpl.rarity)
                local itemCopy = tmpl
                table.insert(rows, {
                    text = "[" .. rarityName .. "] " .. tmpl.name,
                    fontColor = rarityColor,
                    hint = "💰" .. price .. "  点击购买",
                    onTap = function()
                        local ok, msg, item = Inventory.BuyItem(itemCopy.id, player_.classId)
                        if not ok then
                            GameUI.ShowToast(msg or "购买失败")
                            return
                        end
                        GameUI.ShowToast("购买成功：" .. item.name)
                        GameUI.HideNPCPanel()
                        openMerchantPanel(1)
                    end,
                })
            end
            table.insert(rows, {
                text = "刷新货架",
                hint = "💰" .. MERCHANT_REFRESH_COST .. " · 当前货架五分钟内保持不变",
                onTap = function()
                    if not Inventory.SpendGold(MERCHANT_REFRESH_COST) then
                        GameUI.ShowToast("金币不足，需要 " .. MERCHANT_REFRESH_COST .. " 金币")
                        return
                    end
                    RefreshMerchantStock(Combat.currentMapId, player_)
                    GameUI.ShowToast("货架已刷新")
                    GameUI.HideNPCPanel()
                    openMerchantPanel(1)
                end,
            })
            return rows
        end

        -- ============ 出售 tab ============
        local function buildSellRows()
            local rows = {}
            local bag = Inventory.playerData.bag
            if #bag == 0 then
                table.insert(rows, {
                    text = "背包是空的",
                    hint = "击杀怪物或购买装备后再来出售",
                    onTap = function() GameUI.ShowToast("背包没有可出售的装备") end,
                })
            else
                for i, item in ipairs(bag) do
                    local sellPrice = Inventory.GetItemSellPrice(item)
                    local rarityName = Inventory.GetRarityName(item.rarity)
                    local rarityColor = Inventory.GetRarityColor(item.rarity)
                    local enhanceTag = (item.enhance and item.enhance > 0) and (" +" .. item.enhance) or ""
                    local capturedItem = item  -- 捕获实例，避免售出后索引漂移
                    table.insert(rows, {
                        text = "[" .. rarityName .. "] " .. item.name .. enhanceTag,
                        fontColor = rarityColor,
                        hint = "卖出得 💰" .. sellPrice .. "  点击出售",
                        onTap = function()
                            local function sellCapturedItem()
                                local ok, got = Inventory.SellItem(capturedItem)
                                if ok then
                                    GameUI.ShowToast("出售成功：+" .. got .. " 金币")
                                else
                                    GameUI.ShowToast(tostring(got))
                                end
                                GameUI.HideNPCPanel()
                                openMerchantPanel(2)
                            end
                            if capturedItem.rarity == "LEGENDARY" then
                                UI.Modal.Confirm {
                                    title = "确认出售传说装备",
                                    message = "【" .. capturedItem.name .. "】将离开背包，确定出售吗？",
                                    confirmText = "确认出售",
                                    cancelText = "保留装备",
                                    onConfirm = sellCapturedItem,
                                }
                            else
                                sellCapturedItem()
                            end
                        end,
                    })
                end
            end
            return rows
        end

        GameUI.ShowNPCPanel("商人 · 商店", {
            { label = "购买", build = buildBuyRows },
            { label = "出售", build = buildSellRows },
        }, selectedTab or 1)
    end

    -- 与铁匠交互：锻造与强化都只通过安全区 NPC 开放。
    local function openBlacksmithPanel()
        GameUI.ShowBlacksmithPanel(player_)
    end

    -- NPC 交互回调（由 HandleUpdate 每帧检测后触发）
    GameUI.onNPCInteract = function(kind, mapId)
        if kind == "steward" then
            openStewardPanel(mapId)
        elseif kind == "merchant" then
            openMerchantPanel()
        elseif kind == "blacksmith" then
            openBlacksmithPanel()
        end
    end

    GameUI.onCharacterPanelClosed = function()
        -- 角色面板关闭后刷新 HUD 技能栏
        GameUI.RefreshSkillButtons(player_)
    end

    local function PresentQuestStart(quest)
        if not quest then return end

        if quest.dialogues and #quest.dialogues > 0 then
            GameUI.PlayDialogue(quest.dialogues, function()
                if Quest.MarkDialogueRead(quest.id) then
                    -- 对话真正播完后立即落盘。此前只依赖定时自动保存，真机在
                    -- 最后一句后被系统杀掉时会把整段剧情再次播放。
                    SaveCurrentGame()
                end
                local cur = Quest.GetCurrent()
                local p, c = Quest.GetProgress()
                GameUI.UpdateQuestTracker(cur, p, c)
            end)
        else
            if Quest.MarkDialogueRead(quest.id) then
                SaveCurrentGame()
            end
        end
    end

    local function PresentQuestCompletion(quest)
        if not quest or not quest.completionDialogues or #quest.completionDialogues == 0
            or Quest.IsEndingSeen() then
            return
        end
        GameUI.PlayDialogue(quest.completionDialogues, function()
            Quest.MarkEndingSeen()
            SaveCurrentGame()
            GameUI.ShowToast("主线通关：【" .. quest.name .. "】")
        end)
    end

    -- Boss 击杀后的下一章对话/切图应等死亡动画结束再出现。否则模态对话
    -- 会暂停 Combat.Update，而切图还会直接删除正在倒下的 Boss。
    ProcessPendingQuestPresentation = function(dt)
        local pending = pendingQuestPresentation
        if not pending then return false end
        if not player_ then
            pendingQuestPresentation = nil
            return false
        end

        pending.delay = math.max(0, (pending.delay or 0) - math.max(0, dt or 0))
        if pending.delay > 0 then return false end

        pendingQuestPresentation = nil
        if pending.kind == "start" then
            PresentQuestStart(pending.quest)
        elseif pending.kind == "completion" then
            PresentQuestCompletion(pending.quest)
        end
        return true
    end

    -- 战斗回调
    Combat.onDamageDealt = function(dmg, isCrit, worldPos)
        local color = isCrit and {255, 220, 50, 255} or {255, 255, 255, 255}
        local text = isCrit and (math.floor(dmg) .. "!") or tostring(math.floor(dmg))
        GameUI.AddFloatingText(text, worldPos, color, isCrit)
        -- 命中怪物音效（在命中位置播放，增强打击感）
        SoundManager.Play("sword_hit", { position = worldPos })
    end

    Combat.onEnemyAttack = function(enemy, dmg, playerPos)
        if dmg <= 0 then
            GameUI.AddFloatingText("护盾吸收", playerPos, {120, 190, 255, 255})
        else
            GameUI.AddFloatingText("-" .. math.floor(dmg), playerPos, {255, 80, 60, 255})
            -- 致死一击下一帧会播放专用死亡音效，不再叠加受伤声；其余
            -- 连续命中由 SoundManager.PlayHurt 做 0.65 秒全局节流。
            if not player_ or (tonumber(player_.hp) or 0) > 0 then
                SoundManager.PlayHurt({ position = playerPos, gender = player_ and player_.gender })
            end
        end
    end

    Combat.onPlayerHeal = function(amount, pos)
        GameUI.AddFloatingText("+" .. math.floor(amount), pos, {100, 255, 130, 255})
        SoundManager.Play("heal", { position = pos })
    end

    -- 掉落系统（地面掉落模式）
    Combat.onEnemyDeath = function(enemyName, deathPos, exp, deathDuration, tier, mapId, encounterId)
        -- 怪物死亡音效
        SoundManager.Play("enemy_death", { position = deathPos })
        local droppedItem, gold = Inventory.RollDrop(enemyName, player_.classId)
        -- 金币散落到地面
        if gold > 0 then
            Combat.SpawnGroundGold(scene_, deathPos, gold)
        end
        -- 装备掉落到地面
        if droppedItem then
            Combat.SpawnGroundItem(scene_, deathPos, droppedItem)
        end
        -- 药水掉落判定
        local potionDrops = Inventory.RollPotionDrop()
        for _, name in ipairs(potionDrops) do
            GameUI.AddFloatingText("+" .. name, deathPos + Vector3(0, 0.8, 0), {180, 255, 180, 255})
        end
        if #potionDrops > 0 then
            GameUI.UpdatePotionCount("hp", Inventory.GetPotionCount("hp"))
            GameUI.UpdatePotionCount("mp", Inventory.GetPotionCount("mp"))
        end
        -- 只有完成显式遭遇时延后下一段演出；普通清理任务继续即时刷新进度。
        local activeQuest = Quest.GetCurrent()
        local progress, count = Quest.GetProgress()
        local completesEncounter = activeQuest and activeQuest.mode == "encounter"
            and activeQuest.target == enemyName
            and (encounterId == nil or encounterId == activeQuest.id)
            and progress + 1 >= count
        questPresentationDelayHint = completesEncounter
            and math.max(0, tonumber(deathDuration) or 0) + 0.12 or 0

        -- 主线任务击杀计数。Quest 回调在本函数内同步执行，因此上面的
        -- delay hint 能被 onQuestStart/onQuestComplete 精确消费。
        Quest.OnKill(enemyName, tier, mapId, encounterId)
        questPresentationDelayHint = 0
    end

    -- 金币磁吸拾取回调
    Combat.onGoldPickup = function(amount, pos)
        Inventory.AddGold(amount)
        GameUI.AddFloatingText("+" .. amount .. "金", pos + Vector3(0, 0.3, 0), {255, 215, 0, 255})
        SoundManager.Play("gold", { position = pos })
    end

    -- 装备靠近拾取回调
    Combat.onItemPickup = function(item, pos)
        local ok, reason = Inventory.PickupItem(item, player_.classId)
        local rarity = Inventory.RARITY[item.rarity]
        local color = rarity and rarity.color or {255, 255, 255, 255}
        if ok then
            GameUI.AddFloatingText(item.name, pos + Vector3(0, 0.5, 0), color)
            SoundManager.Play("pickup", { position = pos })
        else
            GameUI.AddFloatingText("背包已满", pos + Vector3(0, 0.5, 0), {255, 100, 100, 255})
            SoundManager.Play("error", { position = pos })
        end
        -- Combat 依据返回值决定是否移除地面掉落；背包满时保留物品以便
        -- 玩家整理背包后再拾取。
        return ok
    end

    -- 技能解锁提示
    Combat.onLevelUp = function(newLevel, _levelsGained)
        -- 升级光芒由 Combat 统一管理，和任务区域/AOE 视觉共用更新与清理。
        if scene_ and playerNode_ and Combat.SpawnLevelUpVisual then
            Combat.SpawnLevelUpVisual(scene_, playerNode_, newLevel)
        end
    end

    Combat.onSkillUnlocked = function(skillName)
        GameUI.ShowToast("习得新技能【" .. skillName .. "】")
        SoundManager.Play("levelup")
        -- 刷新技能栏显示
        GameUI.RefreshSkillButtons(player_)
    end

    -- 主线任务回调
    Quest.onQuestComplete = function(quest)
        -- 发放奖励
        if player_ then
            local previousLevel = CharacterClass.NormalizeLevel(player_.level)
            local newSkills = CharacterClass.AddExperience(player_, quest.rewardExp or 0)
            local currentLevel = CharacterClass.NormalizeLevel(player_.level)
            if currentLevel > previousLevel and Combat.onLevelUp then
                Combat.onLevelUp(currentLevel, currentLevel - previousLevel)
            end
            if newSkills and Combat.onSkillUnlocked then
                for _, name in ipairs(newSkills) do
                    Combat.onSkillUnlocked(name)
                end
            end
            GameUI.RefreshSkillButtons(player_)
        end
        local questGoldReward = Inventory.GetQuestGoldReward(quest.rewardGold or 0)
        Inventory.AddGold(questGoldReward)

        GameUI.ShowToast("任务完成：【" .. quest.name .. "】")
        GameUI.AddFloatingText("任务完成 +" .. (quest.rewardExp or 0) .. "经验", playerNode_.position, {255, 215, 0, 255})
        SoundManager.Play("quest_complete")

        -- 跨地图完成后不再自动切图；把下一张地图和入口直接告诉玩家，
        -- 避免任务完成只剩下一个泛化 toast，玩家不知道下一步去哪。
        if Quest.IsTravelPending() then
            local travelMap = MapZone.GetDef(Quest.GetTravelTargetMapId())
            if travelMap then
                GameUI.ShowToast("下一步：前往" .. travelMap.name .. "，找管家传送", 3.0)
            end
        end

        -- 刷新任务追踪条
        local cur = Quest.GetCurrent()
        local p, c = Quest.GetProgress()
        GameUI.UpdateQuestTracker(cur, p, c)

        -- 立即存档（任务进度落盘）
        SaveCurrentGame()

        if Quest.IsFinished() and quest.completionDialogues
            and #quest.completionDialogues > 0 and not Quest.IsEndingSeen() then
            pendingQuestPresentation = {
                kind = "completion",
                quest = quest,
                delay = questPresentationDelayHint,
            }
        end
    end

    Quest.onProgressUpdate = function(quest, progress, count)
        GameUI.UpdateQuestTracker(quest, progress, count)
        -- 巡逻点必须立即落盘；坚守每 5 秒、清理每 3 只保存一次，兼顾
        -- 中断恢复与移动端写盘频率。任务完成仍由 onQuestComplete 强制保存。
        local shouldSave = quest.mode == "patrol"
            or (quest.mode == "survive" and progress > 0 and progress % 5 == 0)
            or (quest.mode == "clear" and progress > 0 and progress % 3 == 0)
        if shouldSave then SaveCurrentGame() end
    end

    -- 巡查点首次到达：在目标地点打出一次明确的世界特效，并从当前地图
    -- 自然生态中注入一小组敌人。Quest 只报告事件，刷怪和演出仍由主流程
    -- 统一编排，避免 Combat 反向依赖任务模块。
    Quest.onObjectiveReached = function(quest, point, progress)
        if not quest or quest.mode ~= "patrol" or not scene_ or not player_
            or Combat.currentMapId ~= quest.mapId then
            return
        end

        local position = GetQuestWorldPosition(point, 0)
        if not position then return end

        local pointName = (point and point.name) or "目标地点"
        Combat.SpawnQuestSignal(scene_, position, "patrol")
        GameUI.ShowToast("探索成功：" .. pointName, 2.2)
        if playerNode_ then
            GameUI.AddFloatingText("已发现 · " .. pointName,
                position + Vector3(0, 1.25, 0), {255, 220, 110, 255})
        end

        Combat.SpawnEnemyGroup(scene_, position, player_.level, quest.mapId, {
            count = 3,
            radius = 4.8,
            groupId = quest.id .. ":point:" .. tostring(progress or 0),
        })
    end

    -- 坚守区域状态变化：首次进入时亮起区域、播报“区域生效”，并
    -- 生成首波敌群；之后的离开/回归只切换亮度，不重复首波。
    Quest.onAreaStateChanged = function(quest, active, area, firstActivation)
        if not quest or quest.mode ~= "survive" or not scene_ or not player_
            or Combat.currentMapId ~= quest.mapId then
            return
        end

        local position = GetQuestWorldPosition(area, 0)
        if not position then return end

        Combat.SetQuestAreaEffect(scene_, quest.id, area, active == true)
        if not active then return end

        local areaName = (area and area.name) or "目标区域"
        if firstActivation then
            Combat.SpawnQuestSignal(scene_, position, "survive")
            local surviveDuration = Quest.SURVIVE_DURATION or 30
            GameUI.ShowToast("区域生效：" .. areaName .. " · 坚守 "
                .. tostring(surviveDuration) .. " 秒", 2.6)
            if playerNode_ then
                GameUI.AddFloatingText("区域生效",
                    position + Vector3(0, 1.25, 0), {255, 180, 70, 255})
            end
            Combat.SpawnEnemyGroup(scene_, position, player_.level, quest.mapId, {
                count = 4,
                radius = 5.5,
                groupId = quest.id .. ":start",
            })
        else
            GameUI.ShowToast("回到" .. areaName .. "，坚守继续", 1.8)
        end
    end

    -- 坚守每累计 10 秒触发一波敌群（10/20 秒），最后 30 秒由
    -- 任务完成处理，不再额外生成“完成后的”波次。
    Quest.onSurviveWave = function(quest, waveIndex, area)
        if not quest or quest.mode ~= "survive" or not scene_ or not player_
            or Combat.currentMapId ~= quest.mapId then
            return false
        end

        local position = GetQuestWorldPosition(area, 0)
        if not position then return false end

        local requestedCount = 4
        local spawned = Combat.SpawnEnemyGroup(scene_, position, player_.level, quest.mapId, {
            count = requestedCount,
            radius = 6.0,
            groupId = quest.id .. ":wave:" .. tostring(waveIndex or 0),
        })
        if spawned ~= requestedCount then return false end

        -- 只有完整敌群已经创建后才播报，避免“敌群来袭”与实际场景脱节。
        Combat.SpawnQuestSignal(scene_, position, "survive")
        local waveLabel = "敌群来袭 · 第" .. tostring(waveIndex or 1) .. "波"
        GameUI.ShowToast(waveLabel, 1.8)
        if playerNode_ then
            GameUI.AddFloatingText(waveLabel,
                position + Vector3(0, 1.25, 0), {255, 120, 70, 255})
        end
        return true
    end

    Quest.onQuestStart = function(quest)
        if questPresentationDelayHint > 0 then
            pendingQuestPresentation = {
                kind = "start",
                quest = quest,
                delay = questPresentationDelayHint,
            }
        else
            PresentQuestStart(quest)
        end
    end

    print("[main] Game callbacks bound")
end

-- ============================================================================
-- 角色选择回调（新建角色流程）
-- ============================================================================
function OnClassSelected(classId, modelStyle, gender)
    modelStyle = modelStyle or "old"
    gender = gender or "male"
    print("[main] Selected class: " .. classId .. " style=" .. modelStyle .. " gender=" .. gender)

    -- 只创建角色存档，不立即进入游戏；用户需要回到槽位页点击“开始游戏”。
    Inventory.Init()
    Quest.Reset()
    Combat.SetMap("map_bq")  -- 新角色从比奇省开始
    Combat.SetKillCount(0)
    MapZone.SetCurrentMap("map_bq")
    pendingQuestActivation = false
    pendingQuestPresentation = nil
    questPresentationDelayHint = 0
    local newPlayer = CharacterClass.CreatePlayer(classId, 1, modelStyle, gender)

    if currentSlotIndex then
        local snapshot = SaveSystem.CreateSnapshot(newPlayer, Inventory.playerData, 0)
        local saved = snapshot and SaveSystem.SaveToSlot(currentSlotIndex, snapshot)
        if saved then
            SyncAccountLeaderboard()
            GameUI.SetSelectedSlot(currentSlotIndex)
            print("[main] Created character in slot " .. currentSlotIndex)
        else
            GameUI.ShowToast("创建角色失败，请重试")
        end
    end

    GameUI.HideClassSelect()
    ShowSaveSlotScreen()
end

-- ============================================================================
-- 返回主菜单
-- ============================================================================
function ReturnToMainMenu()
    print("[main] Returning to main menu...")

    -- 不能把临时攻城地图留在菜单会话中；先回到进入前的普通地图，
    -- 再执行既有的角色保存与节点销毁流程。
    if IsShabakActive() or IsShabakMap(Combat.currentMapId) then
        AbortShabakSiege(ShabakSiege.RESULT_REASON.VOLUNTARY_EXIT)
    end

    -- 角色会话销毁后，广告回调即使迟到也不得给新角色发奖。
    rewardAdRequestSerial = rewardAdRequestSerial + 1
    rewardAdInFlight = false
    rewardAdElapsed = 0
    rewardAdFinish = nil

    -- 死亡结算尚未完成时不能把 0 血快照写回存档；正常退出仍自动保存。
    if not isDead and player_ and (tonumber(player_.hp) or 0) > 0 then
        SaveCurrentGame()
    end

    -- 清理施法状态
    castState.active = false
    castState.phase = "none"
    GameUI.HideCastBar()
    ShowChargeGlow(false)
    GameUI.HideDeathPresentation()

    -- 关闭角色面板和系统面板
    if GameUI.IsCharacterPanelOpen() then
        GameUI.HideCharacterPanel()
    end
    if GameUI.IsSystemPanelOpen() then
        GameUI.HideSystemPanel()
    end

    -- 离开角色会话时清除道士神兽成长，并重置本次会话的击杀统计。
    Combat.Clear(true, true)

    -- 移除玩家节点
    if playerNode_ then
        playerNode_:Remove()
        playerNode_ = nil
    end

    -- 重置状态
    player_ = nil
    isDead = false
    deathTimer = 0
    deathPhase = "none"
    deathLossInfo = nil
    hpPotionCD = 0
    mpPotionCD = 0
    currentSlotIndex = nil
    autoSaveTimer = 0
    pendingQuestActivation = false
    pendingQuestPresentation = nil
    questPresentationDelayHint = 0

    -- 返回存档槽位选择界面
    -- 回到主界面：切换为菜单背景音乐
    SoundManager.PlayMusic("menu")
    ShowSaveSlotScreen()
end

--- 完成死亡结算并在当前地图安全区复活。
---@param currentMap table|nil
local function RevivePlayer(currentMap)
    if not isDead or not player_ or not playerNode_ then return end

    -- 沙巴克使用独立的两命/集结点规则：不扣普通死亡金币，也不把玩家
    -- 送回地图出生安全区。最后一命耗尽时，死亡结算按钮只负责返回原地图。
    if IsShabakActive() or IsShabakMap(Combat.currentMapId) then
        local session = shabakSession_
        if shabakPendingDefeat_ or not session or session:IsFinished() then
            local reason = session and session.resultReason or ShabakSiege.RESULT_REASON.PLAYER_DEAD
            FinishShabakSiege("defeat", reason)
            return
        end
        local plan = session:GetRespawnPlan()
        if not plan then
            FinishShabakSiege("defeat", ShabakSiege.RESULT_REASON.PLAYER_DEAD)
            return
        end

        Combat.CancelPlayerHostileEffects()
        player_.hp = player_.maxHP
        player_.mp = player_.maxMP
        playerNode_.position = GetShabakRallyPosition(plan.rallyPoint)
        local siegeBody = playerNode_:GetComponent("RigidBody")
        if siegeBody then siegeBody:SetLinearVelocity(Vector3.ZERO) end
        PlayerAnim.Play("idle")

        local completed = session:CompleteRespawn()
        if not completed then
            FinishShabakSiege("defeat", ShabakSiege.RESULT_REASON.PLAYER_DEAD)
            return
        end
        CallShabakRuntime({ "ResetForRespawn", "HandlePlayerRespawn" }, plan, playerNode_, player_)
        DrainShabakEvents(session:DrainEvents())

        isDead = false
        deathTimer = 0
        deathPhase = "none"
        deathLossInfo = nil
        shabakPendingDefeat_ = false
        GameUI.HideDeathPresentation()
        GameUI.UpdateGold(Inventory.playerData.gold)
        UpdateShabakHUD()
        return
    end

    -- 清掉玩家死亡前已经生成的弹道、范围伤害和 Boss 攻击视觉，再重置
    -- 存活敌人的血量、控制状态与仇恨，确保复活后不会承接旧攻击窗口。
    Combat.CancelPlayerHostileEffects()
    local restoredEnemies = Combat.ResetLivingEnemiesForPlayerRevive()

    player_.hp = player_.maxHP
    player_.mp = player_.maxMP
    playerNode_.position = currentMap and currentMap.spawnPos or Vector3.ZERO
    local body = playerNode_:GetComponent("RigidBody")
    if body then body:SetLinearVelocity(Vector3.ZERO) end
    PlayerAnim.Play("idle")

    isDead = false
    deathTimer = 0
    deathPhase = "none"
    deathLossInfo = nil
    GameUI.HideDeathPresentation()
    GameUI.UpdateGold(Inventory.playerData.gold)
    autoSaveTimer = 0
    SaveCurrentGame()

    print("[main] Player revived; restored living enemies: " .. restoredEnemies)
end

-- ============================================================================
-- 法师蓄力发光效果
-- ============================================================================
function ShowChargeGlow(show)
    if show then
        if not chargeGlowNode and playerNode_ then
            chargeGlowNode = playerNode_:CreateChild("ChargeGlow")
            chargeGlowNode.position = Vector3(0, 0.8, 0)
            chargeGlowNode.scale = Vector3(0.8, 0.8, 0.8)
            local model = chargeGlowNode:CreateComponent("StaticModel")
            model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
            local mat = Material:new()
            mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
            mat:SetShaderParameter("MatDiffColor", Variant(Color(0.2, 0.4, 0.8, 0.3)))
            mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.3, 0.5, 1.0)))
            mat:SetShaderParameter("Metallic", Variant(0.0))
            mat:SetShaderParameter("Roughness", Variant(0.2))
            model:SetMaterial(mat)
            model.castShadows = false
        end
    else
        if chargeGlowNode then
            chargeGlowNode:Remove()
            chargeGlowNode = nil
        end
    end
end

local function CanMoveDuringCast()
    if not castState.active then return true end
    if not player_ then return false end
    return player_.classId == "warrior" and castState.phase == "recovery"
end

-- 触屏按住技能时，沿用原有施法入口续放。这里先检查所有运行时门槛，
-- 避免冷却中、灵力不足或身处安全区时每帧重复刷提示/日志。
local function UpdateHeldSkillInput()
    if not player_ or not playerNode_ then return end

    -- 即使当前仍在施法，也先读取一次以消费首次按下标记，并验证触摸
    -- 是否仍真实存在；施法结束后的下一帧即可无缝续放。
    local slot, skill = GameUI.GetHeldSkill()
    if not slot or not skill then return end
    if isDead or castState.active or GameUI.IsGamePaused() then return end
    if Combat.IsHostileSkill(skill) and Combat.IsInSafeZone(playerNode_.position) then return end

    local canCast = CharacterClass.CanCastSkill(player_, skill)
    if not canCast then return end

    if GameUI.onSkillPressed then
        GameUI.onSkillPressed(slot, skill)
    end
end

-- ============================================================================
-- 施法状态机更新
-- ============================================================================
function UpdateCastState(dt)
    if not castState.active then return end

    castState.elapsed = castState.elapsed + dt

    if castState.phase == "windup" then
        local progress = castState.elapsed / castState.windupDuration
        GameUI.UpdateCastBar(math.min(1, progress))

        -- 法师蓄力脉冲效果
        if chargeGlowNode then
            local pulse = 0.7 + 0.3 * math.sin(castState.elapsed * 12)
            chargeGlowNode.scale = Vector3(pulse, pulse, pulse)
        end

        if castState.elapsed >= castState.windupDuration then
            -- 前摇结束 → 释放技能
            GameUI.HideCastBar()
            ShowChargeGlow(false)

            local ok, result = Combat.CastSkill(scene_, player_, playerNode_, castState.slot)
            if ok then
                -- 技能命中，触发打击感
                local intensity = 1.0
                if castState.skill.type == "melee" or castState.skill.type == "aoe" then
                    intensity = 1.5  -- 近战/AOE 打击感更强
                elseif castState.skill.type == "summon" then
                    intensity = 0.8
                end
                PlayerAnim.TriggerHitFeedback(intensity)
            else
                print("[main] Cast failed after windup: " .. result)
                if result == "安全区内无法攻击" then
                    GameUI.AddFloatingText(result, playerNode_.position + Vector3(0, 1.0, 0), {160, 200, 255, 255})
                end
            end

            -- 进入后摇
            castState.phase = "recovery"
            castState.elapsed = 0
        end

    elseif castState.phase == "recovery" then
        if castState.elapsed >= castState.recoveryDuration then
            -- 后摇结束
            castState.active = false
            castState.phase = "none"
        end
    end
end

-- ============================================================================
-- 玩家角色节点（人形骨架）
-- ============================================================================
function CreatePlayerNode(classId, modelStyle, gender)
    local classDef = CharacterClass.Classes[classId]
    local color = C[classDef.color]

    modelStyle = modelStyle or (player_ and player_.modelStyle) or "old"
    gender = gender or (player_ and player_.gender) or "male"

    playerNode_ = scene_:CreateChild("Player")
    playerNode_.position = Vector3(0, 0, 0)

    -- 使用 PlayerAnim 创建人形骨架
    PlayerAnim.CreateSkeleton(playerNode_, classId, color, C, modelStyle, gender)

    -- 玩家动态碰撞体（胶囊体，无重力，不旋转，锁 Y）
    local body = playerNode_:CreateComponent("RigidBody")
    body.mass = 1.0
    body.collisionLayer = 2          -- 玩家层
    body.collisionMask = 1 | 4       -- 与地形(1)和AI(4)碰撞
    body.angularFactor = Vector3(0, 0, 0)  -- 禁止物理旋转
    body.linearFactor = Vector3(1, 0, 1)   -- 锁定 Y 轴
    body.friction = 0.5
    body.linearDamping = 0.1
    local shape = playerNode_:CreateComponent("CollisionShape")
    shape:SetCapsule(0.5, 1.4, Vector3(0, 0.7, 0))

    -- 初始化动画为 idle
    PlayerAnim.Play("idle")
end

-- ============================================================================
-- 主循环
-- ============================================================================
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 无回调 watchdog：只结束为失败，绝不根据等待时长发放奖励。
    if rewardAdInFlight then
        rewardAdElapsed = rewardAdElapsed + math.max(0, dt)
        if rewardAdElapsed >= REWARD_AD_WATCHDOG_SECONDS and rewardAdFinish then
            rewardAdFinish({ success = false, msg = "广告响应超时" })
        end
    end

    -- 推进受伤音效节流，即使当前处于启动 Logo、暂停或死亡演出也不冻结。
    SoundManager.Update(dt)

    -- 安全区 NPC 的待机动画独立于玩家状态更新，暂停/死亡演出期间也
    -- 保持微光环、金币和火花的轻量活动感；动画只作用于视觉子节点。
    NPC.Update(dt)

    -- 推进云读取的本地超时兜底，即使启动 Logo 仍在播放也不能停止计时。
    if type(SaveSystem.Update) == "function" then
        SaveSystem.Update(dt)
    end

    -- 启动 Logo：只更新开场 UI，结束后回调进入存档界面
    if GameUI.UpdateStartupLogo(dt) then
        return
    end

    -- 返回键必须在预览模式、空角色和全局暂停的提前 return 之前处理。
    -- 这样删除确认、职业选择、传送、商店、角色、系统和全图都不会出现
    -- “能打开但无法退出”的状态。
    if input:GetKeyPress(KEY_ESCAPE) and GameUI.HandleBackAction() then
        return
    end

    -- 预览模式：只更新预览动画，不运行游戏逻辑
    if previewActive_ then
        UpdatePreviewAnimations(dt, GameUI.GetPreviewClassIds())
        return
    end

    if not player_ then return end

    -- 死亡期间不消费待处理的任务演出或切图；重生后继续，避免重生位置、
    -- 对话和地图切换在同一帧互相覆盖。
    local canAdvanceQuestEvents = not isDead and (tonumber(player_.hp) or 0) > 0
    if canAdvanceQuestEvents and ProcessPendingQuestPresentation then
        ProcessPendingQuestPresentation(dt)
    end

    -- 地图切换完成后再激活下一段主线。放在暂停判断前，但自身会在
    -- 传送面板仍打开时等待，避免 UI 根节点互相覆盖。
    if canAdvanceQuestEvents and ProcessPendingQuestActivation then
        ProcessPendingQuestActivation()
    end

    -- 死亡当帧和死亡结算期间都不写入 0 血快照；复活完成后立即存档。
    if currentSlotIndex and not isDead and (tonumber(player_.hp) or 0) > 0 then
        autoSaveTimer = autoSaveTimer + dt
        if autoSaveTimer >= AUTO_SAVE_INTERVAL then
            autoSaveTimer = 0
            SaveCurrentGame()
        end
    end

    -- 死亡状态
    if isDead then
        GameUI.ClearHeldSkill()
        if deathPhase == "mark" then
            deathTimer = deathTimer - dt
            if deathTimer <= 0 then
                deathTimer = 0
                deathPhase = "result"
                GameUI.ShowDeathLossDialog(deathLossInfo, function()
                    RevivePlayer(MapZone.GetDef(Combat.currentMapId))
                end)
            end
        end
        UpdateQuestAreaEffect()
        UpdateCamera(dt)
        GameUI.UpdateHUD(player_, dt)
        return
    end

    -- 检查死亡
    if player_.hp <= 0 then
        isDead = true
        GameUI.ClearHeldSkill()
        deathTimer = DEATH_MARK_DURATION
        deathPhase = "mark"
        if IsShabakActive() then
            local canRespawn, respawnPlanOrReason = shabakSession_:OnPlayerDeath()
            shabakPendingDefeat_ = canRespawn ~= true
            local lives = shabakSession_:GetSnapshot().livesRemaining or 0
            deathLossInfo = {
                goldLost = 0,
                goldRemaining = Inventory.playerData.gold,
                lossRatio = 0,
                title = canRespawn and "攻城倒下" or "攻城失守",
                message = canRespawn
                    and ("已撤回集结点，剩余命数：" .. tostring(lives))
                    or "两条命数均已耗尽，攻城失败。",
                actionLabel = canRespawn and "重返战场" or "返回安全区",
            }
            if not canRespawn and type(respawnPlanOrReason) == "string" then
                shabakPendingReason_ = respawnPlanOrReason
            end
            UpdateShabakHUD()
        else
            deathLossInfo = Inventory.ApplyDeathPenalty()
        end
        -- 打断施法
        castState.active = false
        castState.phase = "none"
        -- 阵亡当帧就清掉 Boss 攻击、弹道、持续伤害和控制状态；重生时再
        -- 幂等清理一次，避免死亡演出期间冻结的攻击窗口在复活后继续结算。
        Combat.CancelPlayerHostileEffects()
        GameUI.HideCastBar()
        ShowChargeGlow(false)
        GameUI.UpdateGold(Inventory.playerData.gold)
        GameUI.ShowDeathMark(DEATH_MARK_DURATION)
        -- 玩家死亡音效
        SoundManager.Play("death")
        print("[main] Player died; waiting for death settlement")
        UpdateQuestAreaEffect()
        UpdateCamera(dt)
        GameUI.UpdateHUD(player_, dt)
        return
    end

    -- 游戏暂停：打开背包/地图/系统面板时暂停游戏逻辑。死亡演出也属于
    -- 暂停界面，但它已在上方单独推进状态机，不能被这个提前 return 冻结。
    if GameUI.IsGamePaused() then
        GameUI.ClearHeldSkill()
        UpdateQuestAreaEffect()
        UpdateCamera(dt)
        GameUI.UpdateHUD(player_, dt)
        return
    end

    -- 沙巴克会话独立于普通任务/自然刷怪循环。只在未暂停时推进，避免
    -- 打开背包、全图或系统菜单后攻城计时和守军继续攻击。
    if IsShabakActive() then
        local runtimeEvents = CallShabakRuntime(
            { "Update", "Tick", "Step" }, dt, playerNode_, player_, shabakSession_, scene_)
        DrainShabakEvents(runtimeEvents)
        local sessionEvents = shabakSession_:Update(dt)
        DrainShabakEvents(sessionEvents)
        if shabakSession_:IsFinished() and not shabakResultShown_ then
            shabakResultShown_ = true
            shabakPendingResult_ = shabakSession_.state == ShabakSiege.STATE.VICTORY
                and "victory" or "defeat"
            shabakPendingReason_ = shabakSession_.resultReason
        end
    end

    -- 会话进入 victory/defeat 后 IsShabakActive() 会立即变为 false；
    -- 结果仍必须在当前 map_sb 实例收口，不能让待结算状态永远悬挂。
    if shabakPendingResult_
        and (shabakSession_ ~= nil or IsShabakMap(Combat.currentMapId)) then
        local result, reason = shabakPendingResult_, shabakPendingReason_
        shabakPendingResult_, shabakPendingReason_ = nil, nil
        FinishShabakSiege(result, reason)
        return
    end

    -- 只有在没有模态界面时才消费全局快捷键。否则打开对话、商店或角色
    -- 面板时仍可切图，既会打断演出，也会让当前 UI 持有过期的地图/NPC 引用。
    -- M 键切换全图
    if input:GetKeyPress(KEY_M) then
        GameUI.ToggleFullMap()
    end

    -- F3 键：切换"显示距离"调试开关（敌人头顶显示与玩家的距离/身位区间）
    if GameUI.debugMode and input:GetKeyPress(KEY_F3) then
        GameUI.debugShowDistance = not GameUI.debugShowDistance
        GameUI.ShowToast(GameUI.debugShowDistance and "距离显示：开" or "距离显示：关", 1.5)
    end

    -- F5 键：循环切换地图（调试用，正式版由传送阵接管）
    if GameUI.debugMode and input:GetKeyPress(KEY_F5) then
        local curIdx = 1
        for i, id in ipairs(MAP_ORDER) do
            if id == (Combat.currentMapId or "map_bq") then curIdx = i; break end
        end
        local nextId = MAP_ORDER[(curIdx % #MAP_ORDER) + 1]
        SwitchMap(nextId)
    end

    -- 施法状态机更新
    UpdateCastState(dt)

    -- 触屏长按续放：必须在本帧施法状态更新后、移动处理前尝试。
    UpdateHeldSkillInput()

    -- 玩家移动：武士后摇可移动；法师/道士施法全程锁定移动；冲刺期间由 Combat 接管位移
    if CanMoveDuringCast() and not Combat.IsDashing() then
        UpdatePlayerMovement(dt)
    elseif playerNode_ then
        local body = playerNode_:GetComponent("RigidBody")
        if body then
            body:SetLinearVelocity(Vector3.ZERO)
        end
    end

    -- 更新冷却 & 药瓶CD
    CharacterClass.UpdateCooldowns(player_, dt)
    if hpPotionCD > 0 then hpPotionCD = math.max(0, hpPotionCD - dt) end
    if mpPotionCD > 0 then mpPotionCD = math.max(0, mpPotionCD - dt) end
    -- 暴露 CD 进度给 UI 绘制
    GameUI.potionCD = {
        hp = hpPotionCD / HP_POTION_CD,
        mp = mpPotionCD / MP_POTION_CD,
    }

    -- 统一通过职业模块重算派生属性，保留职业被动与装备加成。
    -- refill=false 只在属性上限变化时钳制当前 HP/MP，不会每帧回满。
    CharacterClass.ApplyDerivedStats(player_, Inventory.playerData, false)

    -- NPC 交互检测：玩家靠近安全区 NPC 时显示交互按钮
    local npcKind, npcMapId = NPC.FindNearby(playerNode_.position, 3.0)
    if npcKind and not GameUI.IsNPCPanelOpen() then
        local label = NPC.GetInteractionLabel(npcKind)
        GameUI.SetNPCInteract(true, label, function()
            GameUI.SetNPCInteract(false)
            if GameUI.onNPCInteract then
                GameUI.onNPCInteract(npcKind, npcMapId)
            end
        end)
    else
        if not GameUI.IsNPCPanelOpen() then
            GameUI.SetNPCInteract(false)
        end
    end

    -- 区域/巡逻进度只在角色存活且位于目标地图时推进；离图、死亡和读档
    -- 都保留已完成部分。显式遭遇逐帧确保存在，但 encounterId 防止重复刷出。
    if not IsShabakActive() then
        Quest.Update(dt, Combat.currentMapId, playerNode_.position, not isDead)
    end
    UpdateQuestAreaEffect()
    if GameUI.IsGamePaused() then
        UpdateCamera(dt)
        GameUI.UpdateHUD(player_, dt)
        return
    end
    if not IsShabakActive() then
        local encounterRequest = pendingQuestPresentation and nil or Quest.GetEncounterRequest()
        Combat.EnsureEncounter(scene_, playerNode_, player_, encounterRequest, dt)
    end

    -- 战斗系统更新
    Combat.Update(scene_, dt, playerNode_, player_)

    -- 骨骼动画更新
    local joystick = GameUI.GetJoystick()
    local isMoving = false
    if joystick and CanMoveDuringCast() and not Combat.IsDashing() then
        local jx, jz = joystick:getMovement()
        isMoving = math.abs(jx) > 0.01 or math.abs(jz) > 0.01
    end
    PlayerAnim.Update(dt, isMoving)

    -- 相机跟随
    UpdateCamera(dt)

    -- UI 更新
    GameUI.UpdateHUD(player_, dt)
    GameUI.UpdateKillCount(Combat.killCount)
    GameUI.UpdateGold(Inventory.playerData.gold)
    if IsShabakActive() then UpdateShabakHUD() end
end

-- ============================================================================
-- PostUpdate: 动画骨骼更新后、蒙皮前的 scale 补偿
-- ============================================================================
function HandlePostUpdate(eventType, eventData)
    PlayerAnim.PostUpdate()
end

-- ============================================================================
-- 玩家移动 (摇杆)
-- ============================================================================
function UpdatePlayerMovement(dt)
    if not playerNode_ or isDead then return end
    -- 暂停时不移动
    if GameUI.IsGamePaused() then return end

    local joystick = GameUI.GetJoystick()
    if not joystick then return end

    local x, z = joystick:getMovement()

    local body = playerNode_:GetComponent("RigidBody")

    if math.abs(x) < 0.01 and math.abs(z) < 0.01 then
        -- 停止移动时清零速度
        if body then
            body:SetLinearVelocity(Vector3.ZERO)
        end
        return
    end

    local moveDir = Vector3(x, 0, z)
    moveDir = moveDir:Normalized()

    local speed = player_.moveSpeed

    -- 使用 SetLinearVelocity 让物理引擎处理碰撞
    if body then
        body:SetLinearVelocity(moveDir * speed)
    end

    local angle = math.atan2(moveDir.x, moveDir.z)
    playerNode_.rotation = Quaternion(math.deg(angle), Vector3.UP)
end
