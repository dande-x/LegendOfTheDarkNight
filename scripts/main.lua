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

-- 俯视角相机参数
-- 斜45度视角（类传奇/暗黑风格，能看清人形角色）
local CAM_OFFSET = Vector3(0, 8, -10)
local CAM_PITCH = 40
local CAM_FOV = 40

-- 药瓶系统
local hpPotionCD = 0
local mpPotionCD = 0
local HP_POTION_CD = 1.0
local MP_POTION_CD = 1.0

-- 玩家死亡
local deathTimer = 0
local isDead = false

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

    GameUI.ShowClassSelect(function(classId)
        OnClassSelected(classId)
    end)

    SubscribeToEvent("Update", "HandleUpdate")
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
    -- 地面：水墨风黄土+青草融合贴图（一体化，无需额外草坪层）
    local floorNode = scene_:CreateChild("Floor")
    floorNode.position = Vector3(0, -0.25, 0)
    floorNode.scale = Vector3(120, 0.5, 120)
    local floorModel = floorNode:CreateComponent("StaticModel")
    floorModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))

    local floorMat = Material:new()
    floorMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRMetallicRoughDiffNormalSpec.xml"))
    local groundTex = cache:GetResource("Texture2D", "image/tex_ink_ground_grass_20260611104506.png")
    groundTex:SetAddressMode(COORD_U, ADDRESS_WRAP)
    groundTex:SetAddressMode(COORD_V, ADDRESS_WRAP)
    floorMat:SetTexture(TU_DIFFUSE, groundTex)
    floorMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 1.0, 1.0, 1.0)))
    floorMat:SetShaderParameter("Metallic", Variant(0.0))
    floorMat:SetShaderParameter("Roughness", Variant(0.88))
    floorMat:SetShaderParameter("UOffset", Variant(Vector4(12, 0, 0, 0)))
    floorMat:SetShaderParameter("VOffset", Variant(Vector4(0, 12, 0, 0)))
    floorModel:SetMaterial(floorMat)
    floorModel.castShadows = false
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
    cameraNode_.position = CAM_OFFSET

    local camera = cameraNode_:CreateComponent("Camera")
    camera.nearClip = 0.5
    camera.farClip = 200.0
    camera.fov = CAM_FOV

    cameraNode_.rotation = Quaternion(CAM_PITCH, Vector3.RIGHT)

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
    local targetPos = playerNode_.position + CAM_OFFSET
    -- 打击感屏幕震动
    local shakeOffset = PlayerAnim.GetCameraShakeOffset()
    targetPos = targetPos + shakeOffset
    local currentPos = cameraNode_.position
    local lerpSpeed = 5.0
    cameraNode_.position = currentPos + (targetPos - currentPos) * math.min(1.0, lerpSpeed * dt)
end

-- ============================================================================
-- 角色选择回调
-- ============================================================================
function OnClassSelected(classId)
    print("[main] Selected class: " .. classId)

    player_ = CharacterClass.CreatePlayer(classId, 1)
    CreatePlayerNode(classId)
    GameUI.SetPlayerNode(playerNode_)  -- 玩家节点创建后再设置引用
    GameUI.ShowGameHUD(player_)

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

        -- 播放对应攻击动画
        local animName = PlayerAnim.GetAnimForSkillType(skill.type)
        PlayerAnim.Play(animName)

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
    Inventory.Init()
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

    -- 初始刷怪
    for i = 1, 8 do
        Combat.SpawnEnemy(scene_, playerNode_.position, player_.level)
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

    -- 显示角色选择界面
    GameUI.ShowClassSelect(function(classId)
        OnClassSelected(classId)
    end)
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

    if not player_ then return end

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
