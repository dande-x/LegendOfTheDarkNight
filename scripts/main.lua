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

    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Night.xml")
    local lightGroup = scene_:CreateChild("LightGroup")
    lightGroup:LoadXML(lightGroupFile:GetRoot())

    -- === 传奇 / 暗黑风格氛围 ===
    -- 使用 LightGroup 自带 Zone，只覆盖雾色和距离，避免创建新 Zone 抢占预设。
    local zone = lightGroup:GetComponent("Zone", true)
    if zone then
        zone.fogColor = Color(0.18, 0.20, 0.24, 1.0)
        zone.fogStart = 85.0
        zone.fogEnd = 220.0
        zone.fogDensity = 0.24
        zone.heightFog = false
    end

    -- 冷色主光保证无火把区域可读，火把负责局部暖色对比。
    local dirLight = lightGroup:GetComponent("Light", true)
    if dirLight then
        dirLight.color = Color(0.76, 0.80, 0.92, 1.0)
        dirLight.brightness = 1.25
        dirLight.castShadows = true
    end

    CreateFloor()
    CreateSceneDecorations()
    print("[main] Scene created (with PhysicsWorld + dark fantasy atmosphere)")
end

function CreateFloor()
    --[[
        暗黑地表设计：
        1. 大面积暗色泥土作为可行走底面。
        2. 一条弯曲破碎石板路贯穿出生点，提供视觉引导。
        3. 路边加入湿泥、苔藓、碎石色块，避免单调平面。
        4. 高地和坡面只放在道路外侧作为视觉层次，不改变玩家 Y=0 的移动规则。
    ]]
    math.randomseed(7301)

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

    local darkSoilMat = GetMaterial("uuid://B2-Y8QtOc5NdOQVWAmvW1aQ_", MakeMat(Color(0.13, 0.10, 0.075, 1.0), 0.96, 0.0))
    local roadMat = GetMaterial("uuid://GSN7IaGGBlvP2Xk_zX9UQyuq", MakeMat(Color(0.24, 0.23, 0.21, 1.0), 0.88, 0.0))
    local wetMudMat = MakeMat(Color(0.055, 0.045, 0.040, 1.0), 0.74, 0.0)
    local mossMat = MakeMat(Color(0.09, 0.13, 0.075, 1.0), 0.93, 0.0)
    local ashMat = MakeMat(Color(0.035, 0.032, 0.034, 1.0), 0.98, 0.0)
    local plateauMat = MakeMat(Color(0.095, 0.078, 0.060, 1.0), 0.94, 0.0)

    -- 主地面：Box 尺寸 1m，缩放后 120m × 120m，顶面位于 y=0。 
    local floorNode = scene_:CreateChild("DarkSoilFloor")
    floorNode.position = Vector3(0, -0.25, 0)
    floorNode.scale = Vector3(120, 0.5, 120)
    local floorModel = floorNode:CreateComponent("StaticModel")
    floorModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    floorModel:SetMaterial(darkSoilMat)
    floorModel.castShadows = false

    -- 周边抬高地块：制造坡度/高差感，但不放在主路上，避免影响俯视角移动。
    local plateaus = {
        { pos = Vector3(-34, 0.12, 22), scale = Vector3(18, 0.32, 12), rot = -12 },
        { pos = Vector3(32, 0.16, -24), scale = Vector3(22, 0.42, 15), rot = 18 },
        { pos = Vector3(-30, 0.10, -28), scale = Vector3(16, 0.28, 14), rot = 30 },
        { pos = Vector3(35, 0.11, 28), scale = Vector3(19, 0.30, 12), rot = -25 },
    }
    for i, data in ipairs(plateaus) do
        local node = scene_:CreateChild("DarkPlateau_" .. i)
        node.position = data.pos
        node.scale = data.scale
        node.rotation = Quaternion(data.rot, Vector3.UP)
        local model = node:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        model:SetMaterial(plateauMat)
        model.castShadows = true
    end

    -- 破碎主路：按路径点生成石板段。
    local path = {
        Vector3(-43, 0, -31), Vector3(-34, 0, -23), Vector3(-24, 0, -16),
        Vector3(-13, 0, -8), Vector3(-3, 0, -2), Vector3(7, 0, 5),
        Vector3(16, 0, 13), Vector3(27, 0, 21), Vector3(40, 0, 29),
    }
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

    -- 中央焦土 / 泥坑：用多块重叠椭圆替代单个矩形，避免出现突兀方块边缘。
    for i = 1, 7 do
        local t = (i - 4) / 3.0
        local pit = scene_:CreateChild("CentralScorchedPatch_" .. i)
        pit.position = Vector3(3.0 + t * 4.1 + (math.random() - 0.5) * 0.45, 0.018 + i * 0.001, 3.5 - t * 1.9 + (math.random() - 0.5) * 0.35)
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
        edge.position = Vector3(3.0 + along * 0.9, 0.021 + i * 0.0005, 3.5 + side * (1.4 + math.random() * 1.2) - along * 0.22)
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
        local x = (math.random() - 0.5) * 92
        local z = (math.random() - 0.5) * 92
        p.position = Vector3(x, 0.018 + math.random() * 0.01, z)
        p.scale = Vector3(3.5 + math.random() * 5.5, 0.025, 1.8 + math.random() * 4.2)
        p.rotation = Quaternion(math.random() * 360, Vector3.UP)
        local model = p:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        model:SetMaterial(patchMats[math.random(1, #patchMats)])
        model.castShadows = false
    end

    math.randomseed(os.time())
    print("[main] Dark fantasy floor created: soil, broken stone road, ravine, patches, plateaus")
end

function CreateSceneDecorations()
    --[[
        碰撞设计：
        - 主地面和石板路不加碰撞体，玩家保持 y=0 的俯视角移动规则。
        - 石堆、树干、墓碑、桥边柱等作为静态障碍，使用 layer=1。
        - 桥面本身不阻挡，方便玩家通过中央道路。
    ]]
    math.randomseed(9107)

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

    -- 桥：跨过中央黑色沟壑，桥面不阻挡角色。
    local bridgeRoot = scene_:CreateChild("RuinedBridge")
    bridgeRoot.position = Vector3(3.0, 0.08, 3.5)
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
        end
    end

    -- 岩石群：沿道路边缘和高地脚下成组摆放。
    local rockClusters = {
        Vector3(-31, 0, -18), Vector3(-19, 0, -7), Vector3(-8, 0, 7), Vector3(13, 0, -4),
        Vector3(23, 0, 15), Vector3(34, 0, 22), Vector3(-36, 0, 24), Vector3(31, 0, -26),
        Vector3(-27, 0, -31), Vector3(38, 0, 32), Vector3(-47, 0, 2), Vector3(45, 0, -9),
    }
    for i, pos in ipairs(rockClusters) do
        local count = 3 + math.random(0, 3)
        for j = 1, count do
            local x = pos.x + (math.random() - 0.5) * 2.2
            local z = pos.z + (math.random() - 0.5) * 2.2
            local sx = 0.7 + math.random() * 1.25
            local sy = 0.35 + math.random() * 0.75
            local sz = 0.65 + math.random() * 1.25
            CreateSphere("DarkRock_" .. i .. "_" .. j, Vector3(x, sy * 0.46, z), Vector3(sx, sy, sz),
                (j % 2 == 0) and rockDarkMat or rockMat, true, j == 1)
        end
    end

    -- 枯树和暗色古树：主干有碰撞，枝条仅视觉。
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
        Vector3(-9, 0, -5), Vector3(1, 0, 0), Vector3(11, 0, 8), Vector3(21, 0, 16),
        Vector3(-17, 0, 22), Vector3(22, 0, -22), Vector3(-35, 0, -23), Vector3(35, 0, 27),
    }
    for i, pos in ipairs(torchPositions) do
        local root = scene_:CreateChild("Torch_" .. i)
        root.position = pos
        CreateCylinder("TorchPole_" .. i, Vector3(pos.x, 0.72, pos.z), Vector3(0.08, 1.44, 0.08), 0, ironMat, true, false)
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
        light.range = 6.5
        light.brightness = 3.0
        light.castShadows = false
    end

    -- 破败木桩 / 栅栏边界，暗示可探索区域边缘。
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

    -- 暗色灌木/枯草：低矮、无碰撞，增加地面丰富度。
    local scrubMats = {
        MakeMat(Color(0.10, 0.13, 0.065, 1.0), 0.94, 0.0),
        MakeMat(Color(0.14, 0.115, 0.065, 1.0), 0.96, 0.0),
        MakeMat(Color(0.065, 0.09, 0.055, 1.0), 0.92, 0.0),
    }
    for i = 1, 80 do
        local x = (math.random() - 0.5) * 96
        local z = (math.random() - 0.5) * 96
        local h = 0.18 + math.random() * 0.26
        local blade = CreateBox("DarkScrub_" .. i, Vector3(x, h * 0.5, z), Vector3(0.045, h, 0.22 + math.random() * 0.20),
            math.random() * 360, scrubMats[math.random(1, #scrubMats)], false, nil, nil)
        blade.rotation = blade.rotation * Quaternion((math.random() - 0.5) * 18, Vector3.FORWARD)
    end

    math.randomseed(os.time())
    print("[main] Dark fantasy decorations created: bridge, rocks, dead trees, graves, torches, fences, scrub")
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
    for i = 1, 28 do
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

        -- 法师职业允许更短前摇，避免技能手感拖沓
        if player_.classId == "mage" and windup < 0.18 and skill.manaCost > 0 then
            windup = 0.18
        end

        -- 瞬发技能：不进入施法状态机，立即结算效果
        if skill.instant or windup <= 0 then
            local ok, result = Combat.CastSkill(scene_, player_, playerNode_, slot)
            if ok then
                PlayerAnim.PlaySkill(skill.type)
                PlayerAnim.TriggerHitFeedback(0.8)
            else
                print("[main] Instant cast failed: " .. result)
            end
            return
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
    for i = 1, 28 do
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

local function CanMoveDuringCast()
    if not castState.active then return true end
    if not player_ then return false end
    return player_.classId == "warrior" and castState.phase == "recovery"
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

    -- F3 键：切换"显示距离"调试开关（敌人头顶显示与玩家的距离/身位区间）
    if input:GetKeyPress(KEY_F3) then
        GameUI.debugShowDistance = not GameUI.debugShowDistance
        GameUI.ShowToast(GameUI.debugShowDistance and "距离显示：开" or "距离显示：关", 1.5)
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
        Combat.CancelDash()   -- 中断冲刺，避免死亡后仍被推进
        GameUI.HideCastBar()
        ShowChargeGlow(false)
        GameUI.AddFloatingText("阵亡!", playerNode_.position, {255, 50, 50, 255})
        print("[main] Player died, reviving in 3s")
    end

    -- 施法状态机更新
    UpdateCastState(dt)

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
