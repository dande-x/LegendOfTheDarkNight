---@diagnostic disable: access-invisible, param-type-mismatch, assign-type-mismatch
-- ============================================================================
-- main.lua — 传奇·山海 主入口
-- 俯视角 ARPG: 场景搭建 + 相机跟随 + 角色移动 + 施法系统 + 系统集成
-- ============================================================================

local UI = require("urhox-libs/UI")
local CharacterClass = require("scripts.CharacterClass")
local GameUI = require("scripts.GameUI")
local Combat = require("scripts.Combat")
local Inventory = require("scripts.Inventory")
local PlayerAnim = require("scripts.PlayerAnim")
local SaveSystem = require("scripts.SaveSystem")
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

local C = CharacterClass.Colors

-- 俯视角相机参数（传奇/暗黑风格斜45度俯视）
local CAM_OFFSET = Vector3(0, 12, -14)  -- 相机在玩家上方12m、后方14m
local CAM_FOV = 35

-- 药瓶系统
local hpPotionCD = 0
local mpPotionCD = 0
local HP_POTION_CD = 1.0
local MP_POTION_CD = 1.0

-- 玩家死亡
local deathTimer = 0
local isDead = false

-- 存档系统
local currentSlotIndex = nil  -- 当前使用的存档槽位 (1 或 2)
local autoSaveTimer = 0
local AUTO_SAVE_INTERVAL = 30  -- 每30秒自动保存一次

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
-- 引擎入口
-- ============================================================================
function Start()
    graphics.windowTitle = "贪玩渣渣灰"

    GameUI.InitUI()
    GameUI.InitNanoVG()
    CreateScene()
    SetupCamera()

    -- 初始化存档系统
    SaveSystem.Init()

    -- 显示存档槽位选择界面
    ShowSaveSlotScreen()

    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")
    print("=== 贪玩渣渣灰 Started ===")
end

function Stop()
    UI.Shutdown()
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

    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Dusk.xml")
    local lightGroup = scene_:CreateChild("LightGroup")
    lightGroup:LoadXML(lightGroupFile:GetRoot())

    -- === 国风水墨氛围 ===
    -- 获取 LightGroup 中的 Zone，调整雾效（远处淡化，不是全白）
    local zone = lightGroup:GetComponent("Zone", true)
    if zone then
        zone.fogColor = Color(0.62, 0.64, 0.68, 1.0)  -- 淡青灰雾（远山朦胧感）
        zone.fogStart = 50.0                            -- 50m 开始起雾（近处清晰）
        zone.fogEnd = 120.0                             -- 120m 完全融入雾色
        zone.heightFog = false                          -- 关闭高度雾，避免地面泛白
    end

    -- 获取 LightGroup 中的方向光（水墨风：柔和自然光）
    local dirLight = lightGroup:GetComponent("Light", true)
    if dirLight then
        dirLight.color = Color(0.90, 0.88, 0.85, 1.0)  -- 微暖白光
        dirLight.brightness = 0.9                        -- 适中亮度，保留墨色层次
    end

    CreateFloor()
    CreateSceneDecorations()
    print("[main] Scene created (with PhysicsWorld + ink-wash atmosphere)")
end

function CreateFloor()
    -- 地面：黄绿色草地底色（纯色，无贴图）
    local floorNode = scene_:CreateChild("Floor")
    floorNode.position = Vector3(0, -0.25, 0)
    floorNode.scale = Vector3(120, 0.5, 120)
    local floorModel = floorNode:CreateComponent("StaticModel")
    floorModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))

    local floorMat = Material:new()
    floorMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    floorMat:SetShaderParameter("MatDiffColor", Variant(Color(0.35, 0.42, 0.18, 1.0)))  -- 黄绿草地色
    floorMat:SetShaderParameter("Metallic", Variant(0.0))
    floorMat:SetShaderParameter("Roughness", Variant(0.92))
    floorModel:SetMaterial(floorMat)
    floorModel.castShadows = false

    -- 立体草丛建模：薄片 Box 模拟草叶，高度约 0.3m（膝盖以下）
    local grassColors = {
        Color(0.25, 0.38, 0.12, 1.0),  -- 深草绿
        Color(0.32, 0.45, 0.15, 1.0),  -- 中草绿
        Color(0.28, 0.40, 0.10, 1.0),  -- 橄榄绿
        Color(0.38, 0.48, 0.18, 1.0),  -- 黄草绿
    }
    local grassMats = {}
    for i, gc in ipairs(grassColors) do
        local m = Material:new()
        m:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        m:SetShaderParameter("MatDiffColor", Variant(gc))
        m:SetShaderParameter("Roughness", Variant(0.85))
        m:SetShaderParameter("Metallic", Variant(0.0))
        grassMats[i] = m
    end

    -- 在地图范围内散布草丛簇（每簇 3~5 根草叶）
    math.randomseed(42)  -- 固定种子保证每次一致
    local grassRoot = scene_:CreateChild("GrassRoot")
    local clusterCount = 120
    for c = 1, clusterCount do
        local cx = (math.random() - 0.5) * 80  -- -40 ~ 40 范围
        local cz = (math.random() - 0.5) * 80
        local bladeCount = 3 + math.random(0, 2)  -- 每簇 3~5 根

        for b = 1, bladeCount do
            local bNode = grassRoot:CreateChild("Grass")
            local h = 0.22 + math.random() * 0.14   -- 高度 0.22~0.36m
            local w = 0.03 + math.random() * 0.03   -- 宽度 0.03~0.06m
            local offsetX = (math.random() - 0.5) * 0.4
            local offsetZ = (math.random() - 0.5) * 0.4
            bNode.position = Vector3(cx + offsetX, h * 0.5, cz + offsetZ)
            bNode.scale = Vector3(w, h, w * 0.3)
            -- 随机倾斜 + 旋转
            local tilt = (math.random() - 0.5) * 20
            bNode.rotation = Quaternion(math.random() * 360, Vector3.UP)
                * Quaternion(tilt, Vector3.FORWARD)
            local bModel = bNode:CreateComponent("StaticModel")
            bModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            bModel:SetMaterial(grassMats[math.random(1, #grassMats)])
            bModel.castShadows = false
        end
    end
    math.randomseed(os.time())  -- 恢复随机种子
end

function CreateSceneDecorations()
    -- === 辅助：创建纯色 PBR 材质 ===
    local function MakeMat(color, roughness, metallic)
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(color))
        mat:SetShaderParameter("Roughness", Variant(roughness or 0.7))
        mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
        return mat
    end

    -- === 辅助：创建贴图 PBR 材质 ===
    local function MakeTexMat(texPath, roughness, metallic, tint)
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRMetallicRoughDiffNormalSpec.xml"))
        local tex = cache:GetResource("Texture2D", texPath)
        mat:SetTexture(TU_DIFFUSE, tex)
        mat:SetShaderParameter("MatDiffColor", Variant(tint or Color(1.0, 1.0, 1.0, 1.0)))
        mat:SetShaderParameter("Roughness", Variant(roughness or 0.7))
        mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
        return mat
    end

    -- 预加载贴图材质（国风水墨风）
    local stoneMat = MakeTexMat("image/tex_ink_stone_20260611072209.png", 0.85, 0.0)
    local pillarMat = MakeTexMat("image/tex_ink_pillar_20260611072144.png", 0.75, 0.0)
    local barkMat = MakeTexMat("image/tex_ink_bark_20260611072152.png", 0.8, 0.0)
    local houseWallMat = MakeTexMat("image/tex_ink_wall_20260611072143.png", 0.8, 0.0)

    -- === 石头 ===
    local stonePositions = {
        Vector3(8, 0, 12), Vector3(-15, 0, 8), Vector3(20, 0, -5),
        Vector3(-10, 0, -18), Vector3(5, 0, -25), Vector3(-22, 0, 15),
        Vector3(30, 0, 10), Vector3(-5, 0, 30), Vector3(18, 0, 22),
    }
    for i, pos in ipairs(stonePositions) do
        local s = 0.5 + math.random() * 1.5
        local stoneNode = scene_:CreateChild("Stone_" .. i)
        stoneNode.position = pos
        stoneNode.scale = Vector3(s, s * 0.5, s)
        stoneNode.rotation = Quaternion(math.random() * 360, Vector3.UP)
        local model = stoneNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        model:SetMaterial(stoneMat)
        model.castShadows = true
        local body = stoneNode:CreateComponent("RigidBody")
        body.mass = 0
        body.collisionLayer = 1
        body.collisionMask = 6
        local shape = stoneNode:CreateComponent("CollisionShape")
        shape:SetSphere(1.0)
    end

    -- === 石柱/遗迹 ===
    local pillarPositions = {
        Vector3(15, 0, 15), Vector3(-15, 0, 15),
        Vector3(15, 0, -15), Vector3(-15, 0, -15),
    }
    for i, pos in ipairs(pillarPositions) do
        local pillarNode = scene_:CreateChild("Pillar_" .. i)
        pillarNode.scale = Vector3(0.6, 3.0, 0.6)
        pillarNode.position = Vector3(pos.x, 1.5, pos.z)
        local model = pillarNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        model:SetMaterial(pillarMat)
        model.castShadows = true
        local body = pillarNode:CreateComponent("RigidBody")
        body.mass = 0
        body.collisionLayer = 1
        body.collisionMask = 6
        local shape = pillarNode:CreateComponent("CollisionShape")
        shape:SetCylinder(1.0, 1.0)
    end

    -- === 绿色树木（树干 + 球形树冠） ===
    local treePositions = {
        Vector3(-25, 0, 25), Vector3(-30, 0, 10), Vector3(-35, 0, -5),
        Vector3(25, 0, 28), Vector3(32, 0, 18), Vector3(28, 0, -12),
        Vector3(-18, 0, -30), Vector3(10, 0, -35), Vector3(38, 0, -25),
        Vector3(-40, 0, 0), Vector3(40, 0, 5), Vector3(-8, 0, 38),
        Vector3(12, 0, 40), Vector3(-32, 0, -20), Vector3(35, 0, 32),
    }
    -- 水墨风格：淡墨绿 + 青灰色树冠（国画中的远山近树感）
    local leafColors = {
        Color(0.25, 0.35, 0.22, 1.0),  -- 淡墨绿
        Color(0.30, 0.38, 0.28, 1.0),  -- 青苔绿
        Color(0.20, 0.30, 0.20, 1.0),  -- 深松绿
    }
    for i, pos in ipairs(treePositions) do
        local treeH = 2.5 + math.random() * 2.0  -- 树干高度 2.5~4.5m
        local crownR = 1.2 + math.random() * 1.0   -- 树冠半径 1.2~2.2m

        -- 树干（使用枯树皮贴图）
        local trunkNode = scene_:CreateChild("Tree_" .. i)
        trunkNode.position = Vector3(pos.x, treeH * 0.5, pos.z)
        trunkNode.scale = Vector3(0.3, treeH, 0.3)
        local trunkModel = trunkNode:CreateComponent("StaticModel")
        trunkModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        trunkModel:SetMaterial(barkMat)
        trunkModel.castShadows = true

        -- 树冠（暗色球形，稀疏感）
        local crownNode = scene_:CreateChild("TreeCrown_" .. i)
        crownNode.position = Vector3(pos.x, treeH + crownR * 0.6, pos.z)
        crownNode.scale = Vector3(crownR * 2, crownR * 1.6, crownR * 2)
        local crownModel = crownNode:CreateComponent("StaticModel")
        crownModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local lc = leafColors[math.random(1, #leafColors)]
        crownModel:SetMaterial(MakeMat(lc, 0.8, 0.0))
        crownModel.castShadows = true

        -- 树干碰撞
        local body = trunkNode:CreateComponent("RigidBody")
        body.mass = 0
        body.collisionLayer = 1
        body.collisionMask = 6
        local shape = trunkNode:CreateComponent("CollisionShape")
        shape:SetCylinder(1.0, 1.0)
    end

    -- === 枯木/死树（无树冠，分叉枝条） ===
    local deadTreePositions = {
        Vector3(-12, 0, 25), Vector3(22, 0, -30), Vector3(-38, 0, 15),
        Vector3(42, 0, -8), Vector3(-5, 0, -42), Vector3(15, 0, 38),
        Vector3(-28, 0, -35), Vector3(45, 0, 20),
    }
    for i, pos in ipairs(deadTreePositions) do
        local h = 2.0 + math.random() * 2.5
        local tilt = math.random() * 12 - 6  -- 微微倾斜

        -- 主干（使用枯树皮贴图）
        local deadNode = scene_:CreateChild("DeadTree_" .. i)
        deadNode.position = Vector3(pos.x, h * 0.5, pos.z)
        deadNode.scale = Vector3(0.2, h, 0.2)
        deadNode.rotation = Quaternion(tilt, Vector3.FORWARD) * Quaternion(math.random() * 360, Vector3.UP)
        local model = deadNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        model:SetMaterial(barkMat)
        model.castShadows = true

        -- 分叉枝条（2~3根）
        local branchCount = 2 + math.random(0, 1)
        for b = 1, branchCount do
            local branchNode = scene_:CreateChild("DeadBranch_" .. i .. "_" .. b)
            local bh = h * (0.4 + math.random() * 0.4)
            local angle = math.random() * 360
            local bLen = 0.8 + math.random() * 0.8
            local rad = math.rad(angle)
            branchNode.position = Vector3(
                pos.x + math.sin(rad) * 0.2,
                bh,
                pos.z + math.cos(rad) * 0.2
            )
            branchNode.scale = Vector3(0.08, bLen, 0.08)
            branchNode.rotation = Quaternion(30 + math.random() * 30, Vector3(math.cos(rad), 0, -math.sin(rad)))
            local bModel = branchNode:CreateComponent("StaticModel")
            bModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            bModel:SetMaterial(barkMat)
            bModel.castShadows = true
        end

        -- 碰撞
        local body = deadNode:CreateComponent("RigidBody")
        body.mass = 0
        body.collisionLayer = 1
        body.collisionMask = 6
        local shape = deadNode:CreateComponent("CollisionShape")
        shape:SetCylinder(1.0, 1.0)
    end

    -- === 房屋/小屋（Box 组合） ===
    local housePositions = {
        { pos = Vector3(-35, 0, -30), rot = 25 },
        { pos = Vector3(35, 0, -35), rot = -15 },
        { pos = Vector3(-40, 0, 30), rot = 45 },
        { pos = Vector3(42, 0, 35), rot = 10 },
    }
    local roofMat = MakeTexMat("image/tex_ink_bark_20260611072152.png", 0.75, 0.0,
        Color(0.35, 0.28, 0.22, 1.0))  -- 水墨褐色屋顶
    local doorMat = MakeMat(Color(0.18, 0.14, 0.10, 1.0), 0.85, 0.0)
    for i, hd in ipairs(housePositions) do
        local hw, hh, hd_depth = 3.0, 2.5, 3.5  -- 宽、高、深
        local houseRoot = scene_:CreateChild("House_" .. i)
        houseRoot.position = Vector3(hd.pos.x, 0, hd.pos.z)
        houseRoot.rotation = Quaternion(hd.rot, Vector3.UP)

        -- 墙体（烟熏木板+石砖贴图）
        local wallNode = houseRoot:CreateChild("Wall")
        wallNode.position = Vector3(0, hh * 0.5, 0)
        wallNode.scale = Vector3(hw, hh, hd_depth)
        local wallModel = wallNode:CreateComponent("StaticModel")
        wallModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        wallModel:SetMaterial(houseWallMat)
        wallModel.castShadows = true

        -- 屋顶（暗色树皮质感）
        local roofNode = houseRoot:CreateChild("Roof")
        roofNode.position = Vector3(0, hh + 0.4, 0)
        roofNode.scale = Vector3(hw + 0.6, 0.8, hd_depth + 0.6)
        roofNode.rotation = Quaternion(0, 0, 0)
        local roofModel = roofNode:CreateComponent("StaticModel")
        roofModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        roofModel:SetMaterial(roofMat)
        roofModel.castShadows = true

        -- 门（深黑色）
        local doorNode = houseRoot:CreateChild("Door")
        doorNode.position = Vector3(0, 0.7, hd_depth * 0.5 + 0.02)
        doorNode.scale = Vector3(0.7, 1.4, 0.05)
        local doorModel = doorNode:CreateComponent("StaticModel")
        doorModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        doorModel:SetMaterial(doorMat)
        doorModel.castShadows = false

        -- 整体碰撞
        local body = houseRoot:CreateComponent("RigidBody")
        body.mass = 0
        body.collisionLayer = 1
        body.collisionMask = 6
        local shape = houseRoot:CreateComponent("CollisionShape")
        shape:SetBox(Vector3(hw, hh, hd_depth), Vector3(0, hh * 0.5, 0))
    end

    -- === 灌木丛（小型球体聚簇）— 水墨风：淡青绿 ===
    local bushPositions = {
        Vector3(-6, 0, 15), Vector3(14, 0, 8), Vector3(-20, 0, -10),
        Vector3(25, 0, 15), Vector3(-30, 0, -8), Vector3(8, 0, -15),
        Vector3(-14, 0, 32), Vector3(20, 0, -28), Vector3(-25, 0, 22),
        Vector3(32, 0, -18), Vector3(-8, 0, -32), Vector3(15, 0, 32),
    }
    local bushColors = {
        Color(0.22, 0.32, 0.18, 1.0),  -- 淡墨绿
        Color(0.28, 0.36, 0.22, 1.0),  -- 青苔色
        Color(0.18, 0.28, 0.16, 1.0),  -- 松烟绿
    }
    for i, pos in ipairs(bushPositions) do
        local bushNode = scene_:CreateChild("Bush_" .. i)
        bushNode.position = pos
        bushNode.rotation = Quaternion(math.random() * 360, Vector3.UP)
        -- 2~3 个球组成灌木
        local count = 2 + math.random(0, 1)
        for b = 1, count do
            local bNode = bushNode:CreateChild("BushBall_" .. b)
            local offsetX = (math.random() - 0.5) * 0.6
            local offsetZ = (math.random() - 0.5) * 0.6
            local s = 0.4 + math.random() * 0.4
            bNode.position = Vector3(offsetX, s * 0.4, offsetZ)
            bNode.scale = Vector3(s, s * 0.7, s)
            local bModel = bNode:CreateComponent("StaticModel")
            bModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
            local bc = bushColors[math.random(1, #bushColors)]
            bModel:SetMaterial(MakeMat(bc, 0.9, 0.0))
            bModel.castShadows = true
        end
        -- 灌木不加碰撞体（可穿过）
    end

    -- === 篝火遗迹（圆石圈 + 中心炭火 + 余烬光）— 水墨风 ===
    local campfirePositions = {
        Vector3(0, 0, 20), Vector3(-20, 0, -25),
    }
    for i, pos in ipairs(campfirePositions) do
        local campNode = scene_:CreateChild("Campfire_" .. i)
        campNode.position = pos
        -- 圆石圈（6块小石头）— 使用石头贴图
        for s = 1, 6 do
            local angle = (s - 1) * 60
            local rad = math.rad(angle)
            local sNode = campNode:CreateChild("CampStone_" .. s)
            sNode.position = Vector3(math.sin(rad) * 0.8, 0.15, math.cos(rad) * 0.8)
            sNode.scale = Vector3(0.3, 0.2, 0.3)
            local sModel = sNode:CreateComponent("StaticModel")
            sModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
            sModel:SetMaterial(stoneMat)
            sModel.castShadows = true
        end
        -- 中心炭堆（暗红余烬色）
        local ashNode = campNode:CreateChild("Ash")
        ashNode.position = Vector3(0, 0.1, 0)
        ashNode.scale = Vector3(0.5, 0.15, 0.5)
        local ashModel = ashNode:CreateComponent("StaticModel")
        ashModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        ashModel:SetMaterial(MakeMat(Color(0.08, 0.04, 0.02, 1.0), 0.95, 0.0))
        ashModel.castShadows = false
        -- 篝火余烬点光（暖橙色微弱光芒）
        local fireLight = campNode:CreateChild("FireLight")
        fireLight.position = Vector3(0, 0.4, 0)
        local light = fireLight:CreateComponent("Light")
        light.lightType = LIGHT_POINT
        light.color = Color(0.9, 0.4, 0.1, 1.0)
        light.range = 4.0
        light.brightness = 0.6
        light.castShadows = false
    end

    -- === 木栅栏段（分散在地图边缘附近）— 水墨风：使用树皮贴图 ===
    local fenceSegments = {
        { pos = Vector3(-45, 0, 0), rot = 0 },
        { pos = Vector3(-45, 0, 4), rot = 0 },
        { pos = Vector3(-45, 0, 8), rot = 0 },
        { pos = Vector3(45, 0, -5), rot = 10 },
        { pos = Vector3(45, 0, -1), rot = 10 },
        { pos = Vector3(45, 0, 3), rot = 10 },
    }
    local fenceMat = MakeTexMat("image/tex_ink_bark_20260611072152.png", 0.85, 0.0, Color(0.55, 0.48, 0.40, 1.0))
    for i, fd in ipairs(fenceSegments) do
        local fNode = scene_:CreateChild("Fence_" .. i)
        fNode.position = Vector3(fd.pos.x, 0.6, fd.pos.z)
        fNode.rotation = Quaternion(fd.rot, Vector3.UP)
        fNode.scale = Vector3(0.1, 1.2, 2.5)
        local fModel = fNode:CreateComponent("StaticModel")
        fModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        fModel:SetMaterial(fenceMat)
        fModel.castShadows = true
        local body = fNode:CreateComponent("RigidBody")
        body.mass = 0
        body.collisionLayer = 1
        body.collisionMask = 6
        local shape = fNode:CreateComponent("CollisionShape")
        shape:SetBox(Vector3(1, 1, 1))
    end

    print("[main] Scene decorations created: stones, pillars, trees, dead trees, houses, bushes, campfires, fences")
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

-- 诊断计数器
local diagFrameCount_ = 0

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

    local playerPos = playerNode_.worldPosition
    local targetPos = playerPos + CAM_OFFSET

    -- 诊断日志：每 120 帧打印一次关键数据
    diagFrameCount_ = diagFrameCount_ + 1
    if diagFrameCount_ % 120 == 1 then
        print(string.format("[DIAG] playerPos=(%.2f,%.2f,%.2f) camTarget=(%.2f,%.2f,%.2f)",
            playerPos.x, playerPos.y, playerPos.z,
            targetPos.x, targetPos.y, targetPos.z))
    end

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

-- 预览用动画路径（与 PlayerAnim 相同）
local PREVIEW_ANIM_PATHS = {
    idle       = "uuid://GikiEX04hbY9D5ALGNz051Zh",
    melee_fast = "uuid://Ai-SCaONHGJAnRCLZmoO2QJ8",
    cast_quick = "uuid://E3rZmUDaM9pq2-V2gj3pCyW4",
    sweep_l    = "uuid://BzVkoQzPfkBeIJ_SyLQNwXpI",
}
local PREVIEW_ANIM_DURATIONS = {
    melee_fast = 1.07,
    cast_quick = 1.5,
    sweep_l    = 1.33,
}
-- 各职业预览攻击动画
local PREVIEW_CLASS_ATTACK = {
    warrior = "melee_fast",
    mage    = "cast_quick",
    taoist  = "sweep_l",
}

--- 创建预览角色（在远处，供存档界面展示）
---@param slotIndex number 1 或 2
---@param classId string "warrior"|"mage"|"taoist"
function CreatePreviewCharacter(slotIndex, classId)
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
    local prefabPath = classMod.prefab or "Prefabs/LegendWarrior.prefab"

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

        -- 应用职业材质（仅在 useTexture=true 时覆盖；否则保留 prefab 自带材质）
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
        -- 对所有职业：强制切换到无法线贴图的 Technique，彻底消除脸部坑洼
        local smoothTech = cache:GetResource("Technique", "Techniques/PBR/PBRDiff.xml")
        local numGeom = animModel:GetNumGeometries()
        for i = 0, numGeom - 1 do
            local mat = animModel:GetMaterial(i)
            if mat then
                mat = mat:Clone()
                -- 切换 Technique 为仅 Diffuse（不采样法线贴图）
                mat:SetTechnique(0, smoothTech)
                -- 清除法线和属性贴图
                mat:SetTexture(TU_NORMAL, nil)
                mat:SetTexture(TU_SPECULAR, nil)
                -- 统一设置光滑参数
                mat:SetShaderParameter("Roughness", Variant(0.8))
                mat:SetShaderParameter("Metallic", Variant(0.0))
                animModel:SetMaterial(i, mat)
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
    if animCtrl and PREVIEW_ANIM_PATHS.idle then
        animCtrl:PlayExclusive(PREVIEW_ANIM_PATHS.idle, 0, true, 0.0)
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
                local animPath = PREVIEW_ANIM_PATHS[attackAnim]
                if animPath then
                    ctrl:PlayExclusive(animPath, 0, false, 0.2)
                    previewAttackTimer_[i] = PREVIEW_ANIM_DURATIONS[attackAnim] or 1.0
                end
            else
                -- 未选中：播放 idle
                ctrl:PlayExclusive(PREVIEW_ANIM_PATHS.idle, 0, true, 0.2)
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
                local animPath = PREVIEW_ANIM_PATHS[attackAnim]
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

--- 显示存档槽位选择界面（传奇风格双槽位 + 3D 角色预览）
function ShowSaveSlotScreen()
    local slots = SaveSystem.GetAllSlots()

    -- 清除旧预览
    CleanupPreview()

    -- 为有数据的槽位创建预览角色
    local classIds = {}
    for i = 1, 2 do
        if slots[i] and slots[i].classId then
            classIds[i] = slots[i].classId
            CreatePreviewCharacter(i, slots[i].classId)
        end
    end

    -- 激活预览摄像机
    ActivatePreview()

    -- 默认选中第一个有数据的槽位（如果没有持久化值的话默认选1）
    local defaultSelected = 1
    for i = 1, 2 do
        if slots[i] then defaultSelected = i; break end
    end
    -- 设置持久化选中（ShowSaveSlots 会读取此值）
    GameUI.SetSelectedSlot(defaultSelected)
    SetPreviewSelected(defaultSelected, classIds)

    GameUI.ShowSaveSlots(slots, {
        onSelect = function(slotIndex)
            -- 槽位选中回调：切换预览动画
            SetPreviewSelected(slotIndex, classIds)
        end,
        onContinue = function(slotIndex)
            -- 继续游戏：清除预览，加载存档
            CleanupPreview()
            currentSlotIndex = slotIndex
            local saveData = SaveSystem.GetSlot(slotIndex)
            if saveData then
                LoadFromSave(saveData)
            end
        end,
        onCreate = function(slotIndex)
            -- 创建新角色：清除预览，进入职业选择
            CleanupPreview()
            currentSlotIndex = slotIndex
            GameUI.ShowClassSelect(function(classId)
                OnClassSelected(classId)
            end)
        end,
        onDelete = function(slotIndex, onDone)
            -- 删除角色
            SaveSystem.DeleteSlot(slotIndex)
            print("[main] Slot " .. slotIndex .. " deleted")
            if onDone then onDone() end
            -- 刷新界面（会重建预览）
            ShowSaveSlotScreen()
        end,
    })
end

--- 从存档加载游戏
function LoadFromSave(saveData)
    print("[main] Loading save: " .. saveData.className .. " Lv." .. saveData.level)

    -- 先初始化背包系统
    Inventory.Init()

    -- 恢复背包/装备/金币
    SaveSystem.RestoreInventory(saveData, Inventory.playerData)

    -- 创建角色运行时对象
    player_ = CharacterClass.CreatePlayer(saveData.classId, 1)

    -- 恢复角色属性（等级、经验等）
    SaveSystem.RestorePlayer(saveData, player_)

    -- 恢复击杀数
    Combat.killCount = saveData.killCount or 0

    -- 创建角色节点并进入游戏
    CreatePlayerNode(saveData.classId)
    GameUI.SetPlayerNode(playerNode_)
    GameUI.ShowGameHUD(player_)
    SetupGameCallbacks()

    -- 初始刷怪
    for i = 1, 8 do
        Combat.SpawnEnemy(scene_, playerNode_.position, player_.level)
    end

    GameUI.StartDoorOpen()
    print("[main] Game loaded from save: " .. saveData.className .. " Lv." .. saveData.level)
end

--- 手动保存当前游戏到当前槽位
function SaveCurrentGame()
    if not player_ or not currentSlotIndex then return false end
    local snapshot = SaveSystem.CreateSnapshot(player_, Inventory.playerData, Combat.killCount)
    local ok = SaveSystem.SaveToSlot(currentSlotIndex, snapshot)
    if ok then
        print("[main] Auto-saved to slot " .. currentSlotIndex)
    end
    return ok
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
        local canCast, reason = CharacterClass.CanCastSkill(player_, skill)
        if not canCast then
            print("[main] Skill blocked: " .. reason)
            return
        end

        -- 计算前摇/后摇时间
        local defaults = DEFAULT_CAST_TIMES[skill.type] or { windup = 0.2, recovery = 0.1 }
        local windup = skill.castTime or defaults.windup
        local recovery = defaults.recovery

        -- 法师职业额外增加蓄力时间
        if player_.classId == "mage" and windup < 0.3 and skill.manaCost > 0 then
            windup = 0.3
        end

        -- 自动瞄准：施法开始时转向最近敌人
        local target = Combat.FindNearestEnemy(playerNode_.position, skill.range or 5)
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
        PlayerAnim.PlaySkill(skill.type)

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
            GameUI.AddFloatingText("血药已空", playerNode_.position, {200, 200, 200, 200})
            return
        end
        local cfg = Inventory.POTION_CONFIG.hp
        local heal = player_.maxHP * cfg.healRatio
        player_.hp = math.min(player_.maxHP, player_.hp + heal)
        hpPotionCD = HP_POTION_CD
        GameUI.UpdatePotionCount("hp", Inventory.GetPotionCount("hp"))
        GameUI.AddFloatingText("+" .. math.floor(heal), playerNode_.position, {100, 255, 100, 255})
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
            GameUI.AddFloatingText("蓝药已空", playerNode_.position, {200, 200, 200, 200})
            return
        end
        local cfg = Inventory.POTION_CONFIG.mp
        local restore = player_.maxMP * cfg.healRatio
        player_.mp = math.min(player_.maxMP, player_.mp + restore)
        mpPotionCD = MP_POTION_CD
        GameUI.UpdatePotionCount("mp", Inventory.GetPotionCount("mp"))
        GameUI.AddFloatingText("+" .. math.floor(restore), playerNode_.position, {100, 180, 255, 255})
    end

    -- 返回主菜单回调
    GameUI.onMenuPressed = function()
        ReturnToMainMenu()
    end

    -- Debug 等级调整回调
    GameUI.onDebugLevelChange = function(delta)
        if not player_ then return end
        local newLevel = player_.level + delta
        if newLevel < 1 then newLevel = 1 end
        if newLevel > 50 then newLevel = 50 end
        if newLevel == player_.level then return end

        local classDef = CharacterClass.Classes[player_.classId]
        local g = classDef.growth
        player_.level = newLevel
        player_.maxHP = classDef.baseHP + g.hp * (newLevel - 1)
        player_.maxMP = classDef.baseMP + g.mp * (newLevel - 1)
        player_.atk   = classDef.baseATK + g.atk * (newLevel - 1)
        player_.def   = classDef.baseDEF + g.def * (newLevel - 1)
        player_.hp = player_.maxHP
        player_.mp = player_.maxMP
        player_.expToNext = 50 + newLevel * 60
        player_.exp = 0
        print("[Debug] Level set to " .. newLevel)
        -- 刷新技能栏（解锁状态可能变化）
        GameUI.ShowGameHUD(player_)
    end

    -- 一键满级：设为50级 + 填充全部技能栏
    GameUI.onDebugMaxLevel = function()
        if not player_ then return end
        local maxLv = 50
        local classDef = CharacterClass.Classes[player_.classId]
        local g = classDef.growth
        local Inventory = require("scripts.Inventory")
        local bonusHP = Inventory.playerData.bonusHP or 0
        player_.level = maxLv
        player_.maxHP = classDef.baseHP + g.hp * (maxLv - 1) + bonusHP
        player_.maxMP = classDef.baseMP + g.mp * (maxLv - 1)
        player_.atk   = classDef.baseATK + g.atk * (maxLv - 1)
        player_.def   = classDef.baseDEF + g.def * (maxLv - 1)
        player_.hp = player_.maxHP
        player_.mp = player_.maxMP
        player_.expToNext = 50 + maxLv * 60
        player_.exp = 0
        -- 装备全部技能到对应 slot
        player_.equippedSkills = {}
        for _, skill in ipairs(classDef.skills) do
            if skill.slot >= 1 and skill.slot <= 6 then
                player_.equippedSkills[skill.slot] = skill
            end
        end
        print("[Debug] MAX LEVEL! Lv." .. maxLv .. " all skills equipped")
        GameUI.ShowGameHUD(player_)
    end

    -- 角色面板切换回调
    GameUI.onCharacterPanelToggle = function()
        if GameUI.IsCharacterPanelOpen() then
            GameUI.HideCharacterPanel()
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

    GameUI.onCharacterPanelClosed = function()
        -- 角色面板关闭后刷新 HUD 技能栏
        GameUI.RefreshSkillButtons(player_)
    end

    -- 战斗回调
    Combat.onDamageDealt = function(dmg, isCrit, worldPos)
        local color = isCrit and {255, 220, 50, 255} or {255, 255, 255, 255}
        local text = isCrit and (math.floor(dmg) .. "!") or tostring(math.floor(dmg))
        GameUI.AddFloatingText(text, worldPos, color, isCrit)
    end

    Combat.onEnemyAttack = function(enemy, dmg, playerPos)
        GameUI.AddFloatingText("-" .. math.floor(dmg), playerPos, {255, 80, 60, 255})
    end

    Combat.onPlayerHeal = function(amount, pos)
        GameUI.AddFloatingText("+" .. math.floor(amount), pos, {100, 255, 130, 255})
    end

    -- 掉落系统（地面掉落模式）
    Combat.onEnemyDeath = function(enemyName, deathPos, exp)
        local droppedItem, gold = Inventory.RollDrop(enemyName)
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
    end

    -- 金币磁吸拾取回调
    Combat.onGoldPickup = function(amount, pos)
        Inventory.AddGold(amount)
        GameUI.AddFloatingText("+" .. amount .. "金", pos + Vector3(0, 0.3, 0), {255, 215, 0, 255})
    end

    -- 装备靠近拾取回调
    Combat.onItemPickup = function(item, pos)
        local ok, reason = Inventory.PickupItem(item, player_.classId)
        local rarity = Inventory.RARITY[item.rarity]
        local color = rarity and rarity.color or {255, 255, 255, 255}
        if ok then
            GameUI.AddFloatingText(item.name, pos + Vector3(0, 0.5, 0), color)
        else
            GameUI.AddFloatingText("背包已满", pos + Vector3(0, 0.5, 0), {255, 100, 100, 255})
        end
    end

    -- 技能解锁提示
    Combat.onSkillUnlocked = function(skillName)
        GameUI.ShowToast("习得新技能【" .. skillName .. "】")
        -- 刷新技能栏显示
        GameUI.RefreshSkillButtons(player_)
    end

    print("[main] Game callbacks bound")
end

-- ============================================================================
-- 角色选择回调（新建角色流程）
-- ============================================================================
function OnClassSelected(classId)
    print("[main] Selected class: " .. classId)

    -- 初始化背包
    Inventory.Init()

    -- 创建角色
    player_ = CharacterClass.CreatePlayer(classId, 1)
    CreatePlayerNode(classId)
    GameUI.SetPlayerNode(playerNode_)
    GameUI.ShowGameHUD(player_)
    SetupGameCallbacks()

    -- 初始刷怪
    for i = 1, 8 do
        Combat.SpawnEnemy(scene_, playerNode_.position, player_.level)
    end

    -- 首次保存到当前槽位
    if currentSlotIndex then
        local snapshot = SaveSystem.CreateSnapshot(player_, Inventory.playerData, Combat.killCount)
        SaveSystem.SaveToSlot(currentSlotIndex, snapshot)
        print("[main] Initial save to slot " .. currentSlotIndex)
    end

    -- 开门动画
    GameUI.StartDoorOpen()
    print("[main] Game started with " .. CharacterClass.Classes[classId].name)
end

-- ============================================================================
-- 返回主菜单
-- ============================================================================
function ReturnToMainMenu()
    print("[main] Returning to main menu...")

    -- 退出前自动保存
    SaveCurrentGame()

    -- 清理施法状态
    castState.active = false
    castState.phase = "none"
    GameUI.HideCastBar()
    ShowChargeGlow(false)

    -- 关闭角色面板和系统面板
    if GameUI.IsCharacterPanelOpen() then
        GameUI.HideCharacterPanel()
    end
    if GameUI.IsSystemPanelOpen() then
        GameUI.HideSystemPanel()
    end

    -- 清理战斗实体
    Combat.Clear()

    -- 移除玩家节点
    if playerNode_ then
        playerNode_:Remove()
        playerNode_ = nil
    end

    -- 重置状态
    player_ = nil
    isDead = false
    deathTimer = 0
    hpPotionCD = 0
    mpPotionCD = 0
    currentSlotIndex = nil
    autoSaveTimer = 0

    -- 返回存档槽位选择界面
    ShowSaveSlotScreen()
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
function CreatePlayerNode(classId)
    local classDef = CharacterClass.Classes[classId]
    local color = C[classDef.color]

    playerNode_ = scene_:CreateChild("Player")
    playerNode_.position = Vector3(0, 0, 0)

    -- 使用 PlayerAnim 创建人形骨架
    PlayerAnim.CreateSkeleton(playerNode_, classId, color, C)

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

    -- 预览模式：只更新预览动画，不运行游戏逻辑
    if previewActive_ then
        UpdatePreviewAnimations(dt, GameUI.GetPreviewClassIds())
        return
    end

    if not player_ then return end

    -- 自动保存计时
    if currentSlotIndex then
        autoSaveTimer = autoSaveTimer + dt
        if autoSaveTimer >= AUTO_SAVE_INTERVAL then
            autoSaveTimer = 0
            SaveCurrentGame()
        end
    end

    -- M 键切换全图 / ESC 键关闭全图
    if input:GetKeyPress(KEY_M) then
        GameUI.ToggleFullMap()
    elseif GameUI.IsFullMapOpen() and input:GetKeyPress(KEY_ESCAPE) then
        GameUI.ToggleFullMap()
    end

    -- 游戏暂停：打开背包/地图/系统面板时暂停游戏逻辑
    if GameUI.IsGamePaused() then
        UpdateCamera(dt)
        GameUI.UpdateHUD(player_, dt)
        return
    end

    -- 死亡状态
    if isDead then
        deathTimer = deathTimer - dt
        if deathTimer <= 0 then
            isDead = false
            player_.hp = player_.maxHP
            player_.mp = player_.maxMP
            playerNode_.position = Vector3(0, 0, 0)
            print("[main] Player revived")
        end
        UpdateCamera(dt)
        GameUI.UpdateHUD(player_, dt)
        return
    end

    -- 检查死亡
    if player_.hp <= 0 then
        isDead = true
        deathTimer = 3.0
        -- 打断施法
        castState.active = false
        castState.phase = "none"
        GameUI.HideCastBar()
        ShowChargeGlow(false)
        GameUI.AddFloatingText("阵亡!", playerNode_.position, {255, 50, 50, 255})
        print("[main] Player died, reviving in 3s")
    end

    -- 施法状态机更新
    UpdateCastState(dt)

    -- 玩家移动（施法前摇期间不能移动）
    if not castState.active or castState.phase == "recovery" then
        UpdatePlayerMovement(dt)
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

    -- 装备加成应用
    local inv = Inventory.playerData
    local classDef = CharacterClass.Classes[player_.classId]
    local g = classDef.growth
    player_.atk = classDef.baseATK + g.atk * (player_.level - 1) + inv.bonusAtk
    player_.def = classDef.baseDEF + g.def * (player_.level - 1) + inv.bonusDef
    player_.maxHP = classDef.baseHP + g.hp * (player_.level - 1) + inv.bonusHP
    if player_.hp > player_.maxHP then player_.hp = player_.maxHP end

    -- 战斗系统更新
    Combat.Update(scene_, dt, playerNode_, player_)

    -- 骨骼动画更新
    local joystick = GameUI.GetJoystick()
    local isMoving = false
    if joystick then
        local jx, jz = joystick:getMovement()
        isMoving = math.abs(jx) > 0.01 or math.abs(jz) > 0.01
    end
    PlayerAnim.Update(dt, isMoving)

    -- 相机跟随
    UpdateCamera(dt)

    -- UI 更新
    GameUI.UpdateHUD(player_, dt)
    GameUI.UpdateKillCount(Combat.killCount)
    GameUI.UpdateGold(inv.gold)
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
