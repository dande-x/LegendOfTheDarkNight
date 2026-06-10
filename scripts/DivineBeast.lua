-- ============================================================================
-- DivineBeast.lua — 神兽系统
-- 永久随从，3D模型（胖哥斯拉造型：双足直立，圆胖身体，2角），喷火攻击，可升级
-- 体型为角色的1.5倍高度（约2.7m），火焰从嘴里喷出
-- ============================================================================

local CharacterClass = require("scripts.CharacterClass")

local DivineBeast = {}

-- ============================================================================
-- 神兽等级颜色 (Lv1~7: 白→绿→淡蓝→深蓝)
-- ============================================================================
local LEVEL_COLORS = {
    [1] = {255, 255, 255, 255},    -- 白色
    [2] = {180, 255, 180, 255},    -- 浅绿
    [3] = {80, 220, 80, 255},      -- 绿色
    [4] = {100, 230, 200, 255},    -- 青绿
    [5] = {130, 200, 255, 255},    -- 淡蓝
    [6] = {80, 160, 255, 255},     -- 蓝色
    [7] = {50, 100, 220, 255},     -- 深蓝
}

-- 神兽升级经验表
local LEVEL_EXP = {
    [1] = 100,
    [2] = 250,
    [3] = 500,
    [4] = 900,
    [5] = 1500,
    [6] = 2500,
    [7] = 999999,  -- 满级
}

-- 神兽每级成长
local BEAST_GROWTH = {
    hp_per_level = 80,
    atk_per_level = 8,
    def_per_level = 3,
}

-- ============================================================================
-- 工具函数
-- ============================================================================
local function CreatePBRMat(color, roughness, metallic)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.6))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    return mat
end

-- ============================================================================
-- 神兽状态 (单例 — 只有一只)
-- ============================================================================
local beast = {
    alive = false,
    node = nil,
    meshRoot = nil,     -- 模型根节点
    headNode = nil,     -- 头部节点（用于定位嘴巴喷火）
    mouthNode = nil,    -- 嘴巴位置标记
    bodyParts = {},     -- 所有部件引用（材质闪烁用）
    level = 1,
    exp = 0,
    expToNext = LEVEL_EXP[1],
    maxHP = 300,
    hp = 300,
    atk = 18,
    baseAtk = 18,
    def = 8,
    speed = 4.0,
    attackCD = 2.0,
    attackTimer = 0,
    attackRange = 5.0,
    chaseRange = 9.0,
    state = "follow",  -- follow / chase / attack
    buffTimer = 0,
    buffMult = 1.0,
    fireTimer = 0,
    hitFlashTimer = 0,
    -- 行走动画
    walkPhase = 0,        -- 步态周期相位 (0~2π)
    walkSpeed = 8.0,      -- 步态频率（越大摆腿越快）
    isMoving = false,
    -- 肢体节点引用（模型创建后赋值）
    limbs = nil,
}

DivineBeast.beast = beast

-- 前向声明（Die/Clear 中需要访问）
local fireBreath = {
    active = false,
    timer = 0,
    duration = 1.0,
    dir = Vector3.ZERO,
    nodes = {},
    coneAngle = 35,
    range = 5.0,
    hitSet = {},  -- 记录本次喷火已命中的敌人，每个敌人只受击一次
}

-- ============================================================================
-- 创建3D模型：胖哥斯拉（直立双足，圆胖身体，2角，背脊板）
-- 角色高度约1.8m，神兽高度 1.2倍 → 约2.16m
-- ============================================================================
local function CreateBeastModel(parentNode)
    -- 整体比例：角色1.8m，神兽约2.16m（比之前矮一些）
    local S = 1.2

    -- 材质 —— 棕红色皮肤，浅色腹部，深色纹理过渡
    local bodyMat = CreatePBRMat(Color(0.52, 0.22, 0.12, 1.0), 0.72, 0.05)     -- 棕红色身体
    local bodyDarkMat = CreatePBRMat(Color(0.35, 0.15, 0.08, 1.0), 0.8, 0.05)  -- 深棕色（背部/肩部）
    local bellyMat = CreatePBRMat(Color(0.78, 0.58, 0.38, 1.0), 0.85, 0.0)     -- 浅棕色腹部
    local hornMat = CreatePBRMat(Color(0.35, 0.2, 0.08, 1.0), 0.45, 0.25)      -- 深棕犄角（略有光泽）
    local spineMat = CreatePBRMat(Color(0.45, 0.2, 0.05, 1.0), 0.5, 0.15)      -- 脊背板材质
    local eyeMat = CreatePBRMat(Color(1.0, 0.7, 0.0, 1.0), 0.15, 0.0)          -- 橙黄色眼睛（更亮）
    local pupilMat = CreatePBRMat(Color(0.05, 0.02, 0.0, 1.0), 0.9, 0.0)       -- 黑色瞳孔
    local clawMat = CreatePBRMat(Color(0.18, 0.1, 0.05, 1.0), 0.55, 0.1)       -- 深棕色爪子
    local noseMat = CreatePBRMat(Color(0.3, 0.12, 0.06, 1.0), 0.9, 0.0)        -- 鼻孔

    local parts = {}

    -- 辅助：添加部件
    local function AddPart(name, pos, rot, scl, modelPath, mat, castShadow)
        local n = parentNode:CreateChild(name)
        n.position = pos
        if rot then n.rotation = rot end
        n.scale = scl
        local m = n:CreateComponent("StaticModel")
        m:SetModel(cache:GetResource("Model", modelPath or "Models/Sphere.mdl"))
        m:SetMaterial(mat)
        m.castShadows = castShadow ~= false
        table.insert(parts, {node = n, mat = mat, model = m})
        return n
    end

    -- meshRoot
    local root = parentNode:CreateChild("BeastMesh")
    root.position = Vector3(0, 0, 0)

    -- 将 AddPart 改为相对于 root 创建
    local function Add(name, pos, rot, scl, modelPath, mat, castShadow)
        local n = root:CreateChild(name)
        n.position = pos
        if rot then n.rotation = rot end
        n.scale = scl
        local m = n:CreateComponent("StaticModel")
        m:SetModel(cache:GetResource("Model", modelPath or "Models/Sphere.mdl"))
        m:SetMaterial(mat)
        m.castShadows = castShadow ~= false
        table.insert(parts, {node = n, mat = mat, model = m})
        return n
    end

    -- === 躯干（大椭球，宽胖） ===
    Add("body", Vector3(0, 0.88*S, 0), nil,
        Vector3(0.62*S, 0.68*S, 0.48*S), "Models/Sphere.mdl", bodyMat)

    -- === 大肚子（前面突出的浅色椭球，嵌入身体） ===
    Add("belly", Vector3(0, 0.72*S, 0.16*S), nil,
        Vector3(0.46*S, 0.52*S, 0.36*S), "Models/Sphere.mdl", bellyMat)

    -- === 背部加深色过渡（让身体看起来不是单一颜色） ===
    Add("back", Vector3(0, 0.95*S, -0.12*S), nil,
        Vector3(0.5*S, 0.55*S, 0.35*S), "Models/Sphere.mdl", bodyDarkMat)

    -- === 脖子（短粗过渡，连接头和身体） ===
    Add("neck", Vector3(0, 1.25*S, 0.06*S), nil,
        Vector3(0.22*S, 0.18*S, 0.2*S), "Models/Sphere.mdl", bodyMat)

    -- === 头部（比身体小，略扁） ===
    local head = Add("head", Vector3(0, 1.4*S, 0.12*S), nil,
        Vector3(0.34*S, 0.28*S, 0.32*S), "Models/Sphere.mdl", bodyMat)

    -- === 吻部/鼻吻（头部前方突出的椭球，让头不是纯圆球） ===
    Add("snout", Vector3(0, 1.34*S, 0.3*S), nil,
        Vector3(0.2*S, 0.14*S, 0.18*S), "Models/Sphere.mdl", bodyMat)

    -- === 下颚（吻部下方） ===
    Add("jaw", Vector3(0, 1.28*S, 0.28*S), nil,
        Vector3(0.18*S, 0.08*S, 0.14*S), "Models/Sphere.mdl", bellyMat)

    -- === 鼻孔（吻部前端两个小点） ===
    Add("nostrilL", Vector3(-0.04*S, 1.36*S, 0.4*S), nil,
        Vector3(0.03*S, 0.025*S, 0.03*S), "Models/Sphere.mdl", noseMat, false)
    Add("nostrilR", Vector3(0.04*S, 1.36*S, 0.4*S), nil,
        Vector3(0.03*S, 0.025*S, 0.03*S), "Models/Sphere.mdl", noseMat, false)

    -- === 嘴巴位置标记（喷火出发点） ===
    local mouth = root:CreateChild("mouth")
    mouth.position = Vector3(0, 1.28*S, 0.42*S)

    -- === 犄角（头顶2个，向后上方弯，稍弯曲感） ===
    Add("hornL", Vector3(-0.09*S, 1.58*S, 0.02*S),
        Quaternion(-20, Vector3.FORWARD) * Quaternion(-20, Vector3.RIGHT),
        Vector3(0.04*S, 0.22*S, 0.04*S), "Models/Cone.mdl", hornMat)
    Add("hornR", Vector3(0.09*S, 1.58*S, 0.02*S),
        Quaternion(20, Vector3.FORWARD) * Quaternion(-20, Vector3.RIGHT),
        Vector3(0.04*S, 0.22*S, 0.04*S), "Models/Cone.mdl", hornMat)

    -- === 眼睛（黄色眼白 + 黑色瞳孔） ===
    Add("eyeL", Vector3(-0.11*S, 1.45*S, 0.26*S), nil,
        Vector3(0.06*S, 0.05*S, 0.04*S), "Models/Sphere.mdl", eyeMat, false)
    Add("eyeR", Vector3(0.11*S, 1.45*S, 0.26*S), nil,
        Vector3(0.06*S, 0.05*S, 0.04*S), "Models/Sphere.mdl", eyeMat, false)
    -- 瞳孔
    Add("pupilL", Vector3(-0.11*S, 1.45*S, 0.29*S), nil,
        Vector3(0.03*S, 0.03*S, 0.02*S), "Models/Sphere.mdl", pupilMat, false)
    Add("pupilR", Vector3(0.11*S, 1.45*S, 0.29*S), nil,
        Vector3(0.03*S, 0.03*S, 0.02*S), "Models/Sphere.mdl", pupilMat, false)

    -- === 眉脊（眼睛上方的骨质突起，增添凶狠感） ===
    Add("browL", Vector3(-0.1*S, 1.5*S, 0.25*S), Quaternion(5, Vector3.FORWARD),
        Vector3(0.08*S, 0.025*S, 0.04*S), "Models/Sphere.mdl", bodyDarkMat, false)
    Add("browR", Vector3(0.1*S, 1.5*S, 0.25*S), Quaternion(-5, Vector3.FORWARD),
        Vector3(0.08*S, 0.025*S, 0.04*S), "Models/Sphere.mdl", bodyDarkMat, false)

    -- === 背脊板（哥斯拉标志性，沿脊柱3片） ===
    for i = 1, 3 do
        local t = (i - 1) / 2  -- 0, 0.5, 1
        local y = 1.15*S - t * 0.3*S
        local z = -0.2*S - t * 0.12*S
        local spineSize = (0.06 - t * 0.015) * S
        Add("spine" .. i, Vector3(0, y, z),
            Quaternion(-10 - t*5, Vector3.RIGHT),
            Vector3(0.02*S, spineSize, spineSize * 0.6), "Models/Cone.mdl", spineMat)
    end

    -- === 肩部隆起（增加厚实感） ===
    Add("shoulderL", Vector3(-0.35*S, 1.05*S, 0), nil,
        Vector3(0.15*S, 0.12*S, 0.12*S), "Models/Sphere.mdl", bodyDarkMat)
    Add("shoulderR", Vector3(0.35*S, 1.05*S, 0), nil,
        Vector3(0.15*S, 0.12*S, 0.12*S), "Models/Sphere.mdl", bodyDarkMat)

    -- === 上臂（从肩部下垂） ===
    local armL = Add("armL", Vector3(-0.38*S, 0.85*S, 0.04*S),
        Quaternion(12, Vector3.FORWARD),
        Vector3(0.08*S, 0.22*S, 0.08*S), "Models/Cylinder.mdl", bodyMat)
    local armR = Add("armR", Vector3(0.38*S, 0.85*S, 0.04*S),
        Quaternion(-12, Vector3.FORWARD),
        Vector3(0.08*S, 0.22*S, 0.08*S), "Models/Cylinder.mdl", bodyMat)

    -- === 前臂（略细） ===
    local forearmL = Add("forearmL", Vector3(-0.4*S, 0.62*S, 0.06*S),
        Quaternion(5, Vector3.FORWARD),
        Vector3(0.065*S, 0.16*S, 0.065*S), "Models/Cylinder.mdl", bodyMat)
    local forearmR = Add("forearmR", Vector3(0.4*S, 0.62*S, 0.06*S),
        Quaternion(-5, Vector3.FORWARD),
        Vector3(0.065*S, 0.16*S, 0.065*S), "Models/Cylinder.mdl", bodyMat)

    -- === 爪子（前肢末端，3指造型） ===
    local handL = Add("handL", Vector3(-0.41*S, 0.48*S, 0.08*S), nil,
        Vector3(0.09*S, 0.05*S, 0.08*S), "Models/Sphere.mdl", clawMat, false)
    local handR = Add("handR", Vector3(0.41*S, 0.48*S, 0.08*S), nil,
        Vector3(0.09*S, 0.05*S, 0.08*S), "Models/Sphere.mdl", clawMat, false)

    -- === 大腿（粗壮，支撑整个身体） ===
    local thighL = Add("thighL", Vector3(-0.18*S, 0.45*S, -0.02*S), nil,
        Vector3(0.14*S, 0.28*S, 0.14*S), "Models/Cylinder.mdl", bodyMat)
    local thighR = Add("thighR", Vector3(0.18*S, 0.45*S, -0.02*S), nil,
        Vector3(0.14*S, 0.28*S, 0.14*S), "Models/Cylinder.mdl", bodyMat)

    -- === 小腿（略细，连接膝盖和脚） ===
    local shinL = Add("shinL", Vector3(-0.18*S, 0.2*S, 0.02*S), nil,
        Vector3(0.1*S, 0.2*S, 0.1*S), "Models/Cylinder.mdl", bodyMat)
    local shinR = Add("shinR", Vector3(0.18*S, 0.2*S, 0.02*S), nil,
        Vector3(0.1*S, 0.2*S, 0.1*S), "Models/Cylinder.mdl", bodyMat)

    -- === 大脚掌（扁宽，稳定支撑） ===
    local footL = Add("footL", Vector3(-0.18*S, 0.04*S, 0.06*S), nil,
        Vector3(0.15*S, 0.06*S, 0.22*S), "Models/Sphere.mdl", clawMat)
    local footR = Add("footR", Vector3(0.18*S, 0.04*S, 0.06*S), nil,
        Vector3(0.15*S, 0.06*S, 0.22*S), "Models/Sphere.mdl", clawMat)

    -- === 脚趾（每只脚3个小凸起，增加细节） ===
    for side = -1, 1, 2 do
        local prefix = side < 0 and "toeL" or "toeR"
        local bx = 0.18 * S * side
        for t = 1, 3 do
            local ox = (t - 2) * 0.04 * S * side
            Add(prefix..t, Vector3(bx + ox, 0.02*S, 0.16*S), nil,
                Vector3(0.03*S, 0.025*S, 0.04*S), "Models/Sphere.mdl", clawMat, false)
        end
    end

    -- === 尾巴根部（粗） ===
    local tailBase = Add("tailBase", Vector3(0, 0.6*S, -0.32*S),
        Quaternion(-30, Vector3.RIGHT),
        Vector3(0.12*S, 0.12*S, 0.28*S), "Models/Cylinder.mdl", bodyMat)

    -- === 尾巴中段 ===
    local tailMid = Add("tailMid", Vector3(0, 0.48*S, -0.55*S),
        Quaternion(-40, Vector3.RIGHT),
        Vector3(0.08*S, 0.08*S, 0.22*S), "Models/Cylinder.mdl", bodyDarkMat)

    -- === 尾尖（锥体） ===
    local tailTip = Add("tailTip", Vector3(0, 0.35*S, -0.72*S),
        Quaternion(-50, Vector3.RIGHT),
        Vector3(0.06*S, 0.06*S, 0.15*S), "Models/Cone.mdl", bodyDarkMat)

    -- === 保存肢体引用（用于程序化行走动画） ===
    local limbs = {
        -- 静止时的初始位置（用于计算偏移）
        S = S,
        -- 大腿
        thighL = thighL, thighR = thighR,
        thighLPos = Vector3(-0.18*S, 0.45*S, -0.02*S),
        thighRPos = Vector3(0.18*S, 0.45*S, -0.02*S),
        -- 小腿
        shinL = shinL, shinR = shinR,
        shinLPos = Vector3(-0.18*S, 0.2*S, 0.02*S),
        shinRPos = Vector3(0.18*S, 0.2*S, 0.02*S),
        -- 脚
        footL = footL, footR = footR,
        footLPos = Vector3(-0.18*S, 0.04*S, 0.06*S),
        footRPos = Vector3(0.18*S, 0.04*S, 0.06*S),
        -- 上臂
        armL = armL, armR = armR,
        armLPos = Vector3(-0.38*S, 0.85*S, 0.04*S),
        armRPos = Vector3(0.38*S, 0.85*S, 0.04*S),
        -- 前臂
        forearmL = forearmL, forearmR = forearmR,
        forearmLPos = Vector3(-0.4*S, 0.62*S, 0.06*S),
        forearmRPos = Vector3(0.4*S, 0.62*S, 0.06*S),
        -- 爪子
        handL = handL, handR = handR,
        handLPos = Vector3(-0.41*S, 0.48*S, 0.08*S),
        handRPos = Vector3(0.41*S, 0.48*S, 0.08*S),
        -- 尾巴
        tailBase = tailBase, tailMid = tailMid, tailTip = tailTip,
        -- 身体根节点（用于上下起伏）
        root = root,
    }

    return root, head, mouth, parts, bodyMat, limbs
end

-- ============================================================================
-- 创建/召唤神兽
-- ============================================================================
function DivineBeast.Summon(scene, playerPos, playerAtk)
    if beast.alive then
        print("[DivineBeast] 神兽已存在，无法再次召唤")
        return false
    end

    -- 初始化属性
    beast.level = 1
    beast.exp = 0
    beast.expToNext = LEVEL_EXP[1]
    beast.baseAtk = math.floor(playerAtk * 1.5)
    beast.atk = beast.baseAtk
    beast.maxHP = 300
    beast.hp = 300
    beast.def = 8
    beast.speed = 4.0
    beast.attackCD = 2.0
    beast.attackTimer = 0
    beast.state = "follow"
    beast.buffTimer = 0
    beast.buffMult = 1.0
    beast.fireTimer = 0
    beast.hitFlashTimer = 0

    -- 创建根节点
    local beastNode = scene:CreateChild("DivineBeast")
    beastNode.position = playerPos + Vector3(2, 0, 2)

    -- 创建3D模型
    local meshRoot, headNode, mouthNode, parts, bodyMat, limbs = CreateBeastModel(beastNode)
    beast.meshRoot = meshRoot
    beast.headNode = headNode
    beast.mouthNode = mouthNode
    beast.bodyParts = parts
    beast.limbs = limbs
    beast.walkPhase = 0
    beast.isMoving = false

    -- 物理碰撞体（适配1.2倍体型：宽1.2m 高2.16m）
    local rbody = beastNode:CreateComponent("RigidBody")
    rbody.mass = 1.0
    rbody.collisionLayer = 2          -- 玩家层（不被玩家攻击）
    rbody.collisionMask = 1 | 4       -- 与地形和敌人碰撞
    rbody.angularFactor = Vector3(0, 0, 0)
    rbody.linearFactor = Vector3(1, 0, 1)
    rbody.friction = 0.5
    rbody.linearDamping = 0.1
    local shape = beastNode:CreateComponent("CollisionShape")
    shape:SetCapsule(1.2, 2.16, Vector3(0, 1.08, 0))

    beast.node = beastNode
    beast.alive = true

    print("[DivineBeast] 神兽已召唤! ATK=" .. beast.atk .. " HP=" .. beast.hp)
    return true
end

-- ============================================================================
-- 神兽受伤
-- ============================================================================
function DivineBeast.TakeDamage(dmg)
    if not beast.alive then return end

    local effectiveDmg = dmg * (100 / (100 + beast.def))
    effectiveDmg = math.max(1, math.floor(effectiveDmg))

    beast.hp = beast.hp - effectiveDmg
    beast.hitFlashTimer = 0.2

    if beast.hp <= 0 then
        DivineBeast.Die()
    end
end

-- ============================================================================
-- 神兽死亡
-- ============================================================================
function DivineBeast.Die()
    if not beast.alive then return end
    print("[DivineBeast] 神兽阵亡!")
    beast.alive = false
    if beast.node then
        beast.node:Remove()
        beast.node = nil
    end
    beast.meshRoot = nil
    beast.headNode = nil
    beast.mouthNode = nil
    beast.bodyParts = {}
    beast.hp = 0

    -- 清理喷火效果
    for _, node in ipairs(fireBreath.nodes) do
        if node then node:Remove() end
    end
    fireBreath.nodes = {}
    fireBreath.active = false
end

-- ============================================================================
-- 增加经验
-- ============================================================================
function DivineBeast.AddExp(exp)
    if not beast.alive then return end

    beast.exp = beast.exp + exp
    while beast.exp >= beast.expToNext and beast.level < 7 do
        beast.exp = beast.exp - beast.expToNext
        beast.level = beast.level + 1
        beast.expToNext = LEVEL_EXP[beast.level]

        -- 属性成长
        beast.maxHP = beast.maxHP + BEAST_GROWTH.hp_per_level
        beast.hp = beast.maxHP  -- 升级回满
        beast.baseAtk = beast.baseAtk + BEAST_GROWTH.atk_per_level
        beast.atk = math.floor(beast.baseAtk * beast.buffMult)
        beast.def = beast.def + BEAST_GROWTH.def_per_level

        print("[DivineBeast] 升级! Lv." .. beast.level .. " HP=" .. beast.maxHP .. " ATK=" .. beast.atk)
    end
end

-- ============================================================================
-- Buff 增益
-- ============================================================================
function DivineBeast.ApplyBuff(multiplier, duration)
    beast.buffMult = multiplier
    beast.buffTimer = duration
    beast.atk = math.floor(beast.baseAtk * multiplier)
    beast.attackCD = beast.attackCD / multiplier  -- 攻速也提升
    print("[DivineBeast] 获得增益! ATKx" .. multiplier .. " 持续" .. duration .. "s")
end

-- ============================================================================
-- 获取等级颜色
-- ============================================================================
function DivineBeast.GetNameColor()
    return LEVEL_COLORS[beast.level] or LEVEL_COLORS[1]
end

-- ============================================================================
-- 获取当前状态（供 UI 显示）
-- ============================================================================
function DivineBeast.GetDisplayInfo()
    return {
        alive = beast.alive,
        name = "神兽",
        level = beast.level,
        hp = beast.hp,
        maxHP = beast.maxHP,
        exp = beast.exp,
        expToNext = beast.expToNext,
        nameColor = DivineBeast.GetNameColor(),
    }
end

-- ============================================================================
-- 面向目标（旋转整个节点 Y 轴）
-- ============================================================================
local function UpdateFacing(beastPos, targetPos)
    if not beast.node then return end

    local dir = targetPos - beastPos
    dir.y = 0
    if dir:Length() < 0.1 then return end
    dir = dir:Normalized()

    -- 通过 atan 计算朝向角度，Z+ 为前方
    local angle = math.deg(math.atan(dir.x, dir.z))
    beast.node.rotation = Quaternion(angle, Vector3.UP)
end

-- ============================================================================
-- 喷火攻击（锥形火焰，持续喷射，范围AOE伤害）
-- ============================================================================

-- 创建火焰材质（从亮黄到暗红渐变）
local function CreateFireMat(progress)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    -- 近处亮黄，远处暗红
    local r = 1.0
    local g = 0.8 - progress * 0.6
    local b = 0.2 - progress * 0.2
    local a = 1.0 - progress * 0.5
    mat:SetShaderParameter("MatDiffColor", Variant(Color(r, g, math.max(0, b), a)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(2.0 - progress, 0.6 - progress * 0.4, 0.1)))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    mat:SetShaderParameter("Roughness", Variant(0.3))
    return mat
end

-- 开始喷火
local function StartFireBreath(scene, targetPos)
    if not beast.mouthNode then return end
    if fireBreath.active then return end  -- 已在喷火中

    local mouthWorldPos = beast.mouthNode.worldPosition
    local dir = targetPos - mouthWorldPos
    dir.y = 0
    if dir:Length() < 0.1 then return end
    dir = dir:Normalized()

    fireBreath.active = true
    fireBreath.timer = fireBreath.duration
    fireBreath.dir = dir
    fireBreath.hitSet = {}  -- 重置命中记录，新一轮喷火

    -- 创建火焰锥形视觉：沿喷火方向放置多个逐渐变大的火焰球
    local segCount = 6
    for i = 1, segCount do
        local t = i / segCount  -- 0~1 从嘴巴到末端
        local dist = t * fireBreath.range
        local size = 0.3 + t * 1.2  -- 近处小，远处大（锥形）

        local fireNode = scene:CreateChild("BreathFlame")
        fireNode.position = mouthWorldPos + dir * dist
        fireNode.scale = Vector3(size, size, size)

        local model = fireNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        model:SetMaterial(CreateFireMat(t))
        model.castShadows = false

        table.insert(fireBreath.nodes, fireNode)
    end
end

-- 更新火焰视觉（让火焰粒子抖动 + 随时间消散）
local function UpdateFireBreathVisual(dt)
    if not fireBreath.active then return end

    fireBreath.timer = fireBreath.timer - dt

    -- 更新每个火焰球的位置（轻微随机抖动模拟火焰）
    if beast.mouthNode then
        local mouthWorldPos = beast.mouthNode.worldPosition
        local segCount = #fireBreath.nodes
        for i, node in ipairs(fireBreath.nodes) do
            local t = i / segCount
            local dist = t * fireBreath.range
            local size = (0.3 + t * 1.2) * (0.7 + math.random() * 0.6)  -- 随机大小抖动

            -- 位置：基线 + 随机偏移
            local jitterX = (math.random() - 0.5) * 0.4 * t
            local jitterY = (math.random() - 0.5) * 0.3 * t + 0.1 * t  -- 火焰略微上飘
            local jitterZ = (math.random() - 0.5) * 0.4 * t

            node.position = mouthWorldPos + fireBreath.dir * dist + Vector3(jitterX, jitterY, jitterZ)
            node.scale = Vector3(size, size, size)
        end
    end

    -- 时间到，清除火焰
    if fireBreath.timer <= 0 then
        for _, node in ipairs(fireBreath.nodes) do
            node:Remove()
        end
        fireBreath.nodes = {}
        fireBreath.active = false
    end
end

-- 喷火锥形范围伤害检测（每个敌人每次喷火只命中一次，避免永久硬直）
local function UpdateFireBreathDamage(dt, enemies, player, dealDamageFn)
    if not fireBreath.active then return end
    if not beast.mouthNode then return end

    -- 对锥形范围内所有敌人造成伤害（只命中一次）
    local mouthWorldPos = beast.mouthNode.worldPosition
    local coneAngleRad = math.rad(fireBreath.coneAngle)
    local cosThreshold = math.cos(coneAngleRad)

    if not enemies then return end
    for _, e in ipairs(enemies) do
        -- 跳过已死亡、正在死亡、以及本次喷火已命中过的敌人
        if e.state ~= "dead" and e.state ~= "dying" and not fireBreath.hitSet[e] then
            local toEnemy = e.node.position - mouthWorldPos
            toEnemy.y = 0
            local dist = toEnemy:Length()

            -- 在射程内？
            if dist <= fireBreath.range + 1.0 then
                local hit = false
                -- 在锥角内？
                if dist > 0.1 then
                    local dirToEnemy = toEnemy:Normalized()
                    local dot = fireBreath.dir.x * dirToEnemy.x + fireBreath.dir.z * dirToEnemy.z
                    if dot >= cosThreshold then
                        hit = true
                    end
                else
                    -- 距离太近，直接命中
                    hit = true
                end

                if hit and dealDamageFn then
                    dealDamageFn(e, beast.atk, player)
                    fireBreath.hitSet[e] = true  -- 标记为已命中，本轮不再重复
                end
            end
        end
    end
end

-- ============================================================================
-- 受击闪烁效果（材质颜色闪红）
-- ============================================================================
local function UpdateHitFlash(dt)
    if beast.hitFlashTimer > 0 then
        beast.hitFlashTimer = beast.hitFlashTimer - dt
        -- 闪烁: 偶数时段变红
        local flash = math.floor(beast.hitFlashTimer * 10) % 2 == 0
        for _, part in ipairs(beast.bodyParts) do
            if part.model then
                if flash then
                    local flashMat = Material:new()
                    flashMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
                    flashMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.2, 0.2, 1.0)))
                    flashMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.0, 0.0)))
                    flashMat:SetShaderParameter("Roughness", Variant(0.5))
                    flashMat:SetShaderParameter("Metallic", Variant(0.0))
                    part.model:SetMaterial(flashMat)
                else
                    part.model:SetMaterial(part.mat)
                end
            end
        end
    else
        -- 确保恢复原始材质
        for _, part in ipairs(beast.bodyParts) do
            if part.model and part.needsRestore then
                part.model:SetMaterial(part.mat)
                part.needsRestore = false
            end
        end
    end
end

-- ============================================================================
-- 程序化行走动画（腿部前后摆动、身体上下起伏、手臂摆动、尾巴晃动）
-- ============================================================================
local function UpdateWalkAnimation(dt)
    local limbs = beast.limbs
    if not limbs then return end

    local S = limbs.S

    if beast.isMoving then
        -- 步态相位推进
        beast.walkPhase = beast.walkPhase + dt * beast.walkSpeed
        if beast.walkPhase > math.pi * 2 then
            beast.walkPhase = beast.walkPhase - math.pi * 2
        end
    else
        -- 停止时缓慢回到站立姿势
        if beast.walkPhase ~= 0 then
            beast.walkPhase = beast.walkPhase * 0.85  -- 快速衰减
            if math.abs(beast.walkPhase) < 0.05 then
                beast.walkPhase = 0
            end
        end
    end

    local phase = beast.walkPhase
    local sinP = math.sin(phase)
    local cosP = math.cos(phase)

    -- === 腿部动画 ===
    -- 左右腿相位相反：左腿 sin(phase)，右腿 sin(phase + π) = -sin(phase)
    local legSwing = 0.12 * S   -- 前后摆幅
    local legLift = 0.04 * S    -- 抬腿高度

    -- 大腿：前后平移 + 轻微抬起
    local liftL = math.max(0, sinP) * legLift     -- 左腿前迈时抬起
    local liftR = math.max(0, -sinP) * legLift    -- 右腿前迈时抬起

    limbs.thighL.position = limbs.thighLPos + Vector3(0, liftL, sinP * legSwing)
    limbs.thighR.position = limbs.thighRPos + Vector3(0, liftR, -sinP * legSwing)

    -- 小腿跟随大腿（摆幅稍小，有一点延迟感）
    local shinSwing = 0.08 * S
    limbs.shinL.position = limbs.shinLPos + Vector3(0, liftL * 0.5, sinP * shinSwing)
    limbs.shinR.position = limbs.shinRPos + Vector3(0, liftR * 0.5, -sinP * shinSwing)

    -- 脚掌跟随（贴地感）
    local footSwing = 0.06 * S
    limbs.footL.position = limbs.footLPos + Vector3(0, liftL * 0.3, sinP * footSwing)
    limbs.footR.position = limbs.footRPos + Vector3(0, liftR * 0.3, -sinP * footSwing)

    -- === 手臂动画（与同侧腿相反摆动） ===
    local armSwing = 0.06 * S
    limbs.armL.position = limbs.armLPos + Vector3(0, 0, -sinP * armSwing)
    limbs.armR.position = limbs.armRPos + Vector3(0, 0, sinP * armSwing)

    local forearmSwing = 0.05 * S
    limbs.forearmL.position = limbs.forearmLPos + Vector3(0, 0, -sinP * forearmSwing)
    limbs.forearmR.position = limbs.forearmRPos + Vector3(0, 0, sinP * forearmSwing)

    limbs.handL.position = limbs.handLPos + Vector3(0, 0, -sinP * forearmSwing * 0.8)
    limbs.handR.position = limbs.handRPos + Vector3(0, 0, sinP * forearmSwing * 0.8)

    -- === 身体上下起伏（两步一个周期，频率是腿的2倍） ===
    local bodyBob = math.abs(sinP) * 0.03 * S  -- 轻微起伏
    limbs.root.position = Vector3(0, bodyBob, 0)

    -- === 尾巴左右晃动（频率略低于步态，像自然摆动） ===
    local tailSway = math.sin(phase * 0.7) * 0.06 * S
    if limbs.tailBase then
        limbs.tailBase.position = Vector3(tailSway * 0.5, 0.6*S, -0.32*S)
    end
    if limbs.tailMid then
        limbs.tailMid.position = Vector3(tailSway, 0.48*S, -0.55*S)
    end
    if limbs.tailTip then
        limbs.tailTip.position = Vector3(tailSway * 1.5, 0.35*S, -0.72*S)
    end
end

-- ============================================================================
-- 主更新
-- ============================================================================
function DivineBeast.Update(dt, scene, playerNode, player, enemies, dealDamageFn)
    if not beast.alive or not beast.node or not playerNode then return end

    local beastPos = beast.node.position
    local playerPos = playerNode.position

    -- Buff 衰减
    if beast.buffTimer > 0 then
        beast.buffTimer = beast.buffTimer - dt
        if beast.buffTimer <= 0 then
            beast.buffMult = 1.0
            beast.atk = beast.baseAtk
            beast.attackCD = 2.0
        end
    end

    -- 受击闪烁
    UpdateHitFlash(dt)

    -- 攻击计时
    beast.attackTimer = math.max(0, beast.attackTimer - dt)

    local rbody = beast.node:GetComponent("RigidBody")

    -- AI: 找最近敌人
    local nearestEnemy = nil
    local nearDist = beast.chaseRange
    if enemies then
        for _, e in ipairs(enemies) do
            if e.state ~= "dead" and e.state ~= "dying" then
                local d = (e.node.position - beastPos):Length()
                if d < nearDist then
                    nearDist = d
                    nearestEnemy = e
                end
            end
        end
    end

    if nearestEnemy and nearDist <= beast.chaseRange then
        if nearDist <= beast.attackRange then
            -- 攻击
            beast.state = "attack"
            beast.isMoving = false
            if rbody then rbody:SetLinearVelocity(Vector3.ZERO) end

            if beast.attackTimer <= 0 then
                StartFireBreath(scene, nearestEnemy.node.position)
                beast.attackTimer = beast.attackCD
            end

            UpdateFacing(beastPos, nearestEnemy.node.position)
        else
            -- 追击
            beast.state = "chase"
            beast.isMoving = true
            local dir = nearestEnemy.node.position - beastPos
            dir.y = 0
            dir = dir:Normalized()
            if rbody then rbody:SetLinearVelocity(dir * beast.speed) end
            UpdateFacing(beastPos, nearestEnemy.node.position)
        end
    else
        -- 跟随玩家
        beast.state = "follow"
        local toPlayer = playerPos - beastPos
        toPlayer.y = 0
        local distToPlayer = toPlayer:Length()

        if distToPlayer > 3.0 then
            beast.isMoving = true
            local dir = toPlayer:Normalized()
            local followSpeed = beast.speed * 1.2
            if rbody then rbody:SetLinearVelocity(dir * followSpeed) end
            UpdateFacing(beastPos, playerPos)
        else
            beast.isMoving = false
            if rbody then rbody:SetLinearVelocity(Vector3.ZERO) end
        end

        -- 太远则传送
        if distToPlayer > 20 then
            beast.node.position = playerPos + Vector3(2, 0, 2)
        end
    end

    -- 更新行走动画
    UpdateWalkAnimation(dt)

    -- 更新喷火效果（视觉 + 伤害）
    UpdateFireBreathVisual(dt)
    UpdateFireBreathDamage(dt, enemies, player, dealDamageFn)
end

-- ============================================================================
-- 清理（重置状态）
-- ============================================================================
function DivineBeast.Clear()
    if beast.node then
        beast.node:Remove()
        beast.node = nil
    end
    beast.alive = false
    beast.level = 1
    beast.exp = 0
    beast.meshRoot = nil
    beast.headNode = nil
    beast.mouthNode = nil
    beast.bodyParts = {}
    beast.hp = 0

    -- 清理喷火效果
    for _, node in ipairs(fireBreath.nodes) do
        if node then node:Remove() end
    end
    fireBreath.nodes = {}
    fireBreath.active = false
end

-- ============================================================================
-- 是否存活
-- ============================================================================
function DivineBeast.IsAlive()
    return beast.alive
end

-- ============================================================================
-- 获取节点位置（供 UI 使用）
-- ============================================================================
function DivineBeast.GetPosition()
    if beast.alive and beast.node then
        return beast.node.position
    end
    return nil
end

return DivineBeast
