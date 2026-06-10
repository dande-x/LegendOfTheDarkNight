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
}

DivineBeast.beast = beast

-- 前向声明（Die/Clear 中需要访问）
local fireBreath = {
    active = false,
    timer = 0,
    duration = 1.0,
    dir = Vector3.ZERO,
    nodes = {},
    damageTimer = 0,
    damageInterval = 0.25,
    coneAngle = 35,
    range = 5.0,
}

-- ============================================================================
-- 创建3D模型：胖哥斯拉（直立双足，圆胖身体，2角）
-- 角色高度约1.8m，神兽高度 1.5倍 → 约2.7m
-- ============================================================================
local function CreateBeastModel(parentNode)
    -- 整体高度比例：角色1.8m，神兽约2.7m
    local S = 1.5

    -- 材质 —— 参考图片：棕红色皮肤，浅色腹部
    local bodyMat = CreatePBRMat(Color(0.55, 0.25, 0.15, 1.0), 0.75, 0.05)    -- 棕红色身体
    local bellyMat = CreatePBRMat(Color(0.75, 0.55, 0.35, 1.0), 0.85, 0.0)    -- 浅棕色腹部
    local hornMat = CreatePBRMat(Color(0.4, 0.25, 0.1, 1.0), 0.5, 0.2)        -- 深棕色犄角
    local eyeMat = CreatePBRMat(Color(1.0, 0.8, 0.0, 1.0), 0.2, 0.0)          -- 黄色眼睛
    local clawMat = CreatePBRMat(Color(0.2, 0.12, 0.08, 1.0), 0.6, 0.1)       -- 深棕色爪子

    local parts = {}

    -- meshRoot
    local root = parentNode:CreateChild("BeastMesh")
    root.position = Vector3(0, 0, 0)

    -- === 躯干（大圆球，又胖又圆） ===
    local body = root:CreateChild("body")
    body.position = Vector3(0, 1.1 * S, 0)
    body.scale = Vector3(0.7 * S, 0.75 * S, 0.55 * S)  -- 宽胖，侧面略扁
    local bodyModel = body:CreateComponent("StaticModel")
    bodyModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    bodyModel:SetMaterial(bodyMat)
    bodyModel.castShadows = true
    table.insert(parts, {node = body, mat = bodyMat, model = bodyModel})

    -- === 大肚子（前面突出的浅色圆球） ===
    local belly = root:CreateChild("belly")
    belly.position = Vector3(0, 0.9 * S, 0.18 * S)
    belly.scale = Vector3(0.5 * S, 0.55 * S, 0.4 * S)
    local bellyModel = belly:CreateComponent("StaticModel")
    bellyModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    bellyModel:SetMaterial(bellyMat)
    bellyModel.castShadows = false
    table.insert(parts, {node = belly, mat = bellyMat, model = bellyModel})

    -- === 头部（比身体小的圆球，直接坐在身体上方） ===
    local head = root:CreateChild("head")
    head.position = Vector3(0, 1.7 * S, 0.1 * S)
    head.scale = Vector3(0.4 * S, 0.35 * S, 0.38 * S)
    local headModel = head:CreateComponent("StaticModel")
    headModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    headModel:SetMaterial(bodyMat)
    headModel.castShadows = true
    table.insert(parts, {node = head, mat = bodyMat, model = headModel})

    -- === 嘴巴/下颚（头部前下方的小椭球） ===
    local jaw = root:CreateChild("jaw")
    jaw.position = Vector3(0, 1.55 * S, 0.32 * S)
    jaw.scale = Vector3(0.25 * S, 0.12 * S, 0.2 * S)
    local jawModel = jaw:CreateComponent("StaticModel")
    jawModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    jawModel:SetMaterial(bellyMat)
    jawModel.castShadows = false
    table.insert(parts, {node = jaw, mat = bellyMat, model = jawModel})

    -- === 嘴巴位置标记（喷火出发点） ===
    local mouth = root:CreateChild("mouth")
    mouth.position = Vector3(0, 1.52 * S, 0.45 * S)

    -- === 犄角（头顶2个，向后上方弯曲） ===
    local hornL = root:CreateChild("hornL")
    hornL.position = Vector3(-0.1 * S, 1.95 * S, 0.0)
    hornL.rotation = Quaternion(-20, Vector3.FORWARD) * Quaternion(-15, Vector3.RIGHT)
    hornL.scale = Vector3(0.06 * S, 0.25 * S, 0.06 * S)
    local hornLModel = hornL:CreateComponent("StaticModel")
    hornLModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    hornLModel:SetMaterial(hornMat)
    hornLModel.castShadows = true
    table.insert(parts, {node = hornL, mat = hornMat, model = hornLModel})

    local hornR = root:CreateChild("hornR")
    hornR.position = Vector3(0.1 * S, 1.95 * S, 0.0)
    hornR.rotation = Quaternion(20, Vector3.FORWARD) * Quaternion(-15, Vector3.RIGHT)
    hornR.scale = Vector3(0.06 * S, 0.25 * S, 0.06 * S)
    local hornRModel = hornR:CreateComponent("StaticModel")
    hornRModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    hornRModel:SetMaterial(hornMat)
    hornRModel.castShadows = true
    table.insert(parts, {node = hornR, mat = hornMat, model = hornRModel})

    -- === 眼睛（左右，小黄球） ===
    local eyeL = root:CreateChild("eyeL")
    eyeL.position = Vector3(-0.12 * S, 1.75 * S, 0.28 * S)
    eyeL.scale = Vector3(0.06 * S, 0.06 * S, 0.06 * S)
    local eyeLModel = eyeL:CreateComponent("StaticModel")
    eyeLModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    eyeLModel:SetMaterial(eyeMat)
    table.insert(parts, {node = eyeL, mat = eyeMat, model = eyeLModel})

    local eyeR = root:CreateChild("eyeR")
    eyeR.position = Vector3(0.12 * S, 1.75 * S, 0.28 * S)
    eyeR.scale = Vector3(0.06 * S, 0.06 * S, 0.06 * S)
    local eyeRModel = eyeR:CreateComponent("StaticModel")
    eyeRModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    eyeRModel:SetMaterial(eyeMat)
    table.insert(parts, {node = eyeR, mat = eyeMat, model = eyeRModel})

    -- === 双腿（粗壮的圆柱，双足站立） ===
    local legL = root:CreateChild("legL")
    legL.position = Vector3(-0.2 * S, 0.35 * S, 0)
    legL.scale = Vector3(0.18 * S, 0.4 * S, 0.18 * S)
    local legLModel = legL:CreateComponent("StaticModel")
    legLModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    legLModel:SetMaterial(bodyMat)
    legLModel.castShadows = true
    table.insert(parts, {node = legL, mat = bodyMat, model = legLModel})

    local legR = root:CreateChild("legR")
    legR.position = Vector3(0.2 * S, 0.35 * S, 0)
    legR.scale = Vector3(0.18 * S, 0.4 * S, 0.18 * S)
    local legRModel = legR:CreateComponent("StaticModel")
    legRModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    legRModel:SetMaterial(bodyMat)
    legRModel.castShadows = true
    table.insert(parts, {node = legR, mat = bodyMat, model = legRModel})

    -- === 大脚掌（扁球） ===
    local footL = root:CreateChild("footL")
    footL.position = Vector3(-0.2 * S, 0.06 * S, 0.05 * S)
    footL.scale = Vector3(0.2 * S, 0.08 * S, 0.25 * S)
    local footLModel = footL:CreateComponent("StaticModel")
    footLModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    footLModel:SetMaterial(clawMat)
    table.insert(parts, {node = footL, mat = clawMat, model = footLModel})

    local footR = root:CreateChild("footR")
    footR.position = Vector3(0.2 * S, 0.06 * S, 0.05 * S)
    footR.scale = Vector3(0.2 * S, 0.08 * S, 0.25 * S)
    local footRModel = footR:CreateComponent("StaticModel")
    footRModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    footRModel:SetMaterial(clawMat)
    table.insert(parts, {node = footR, mat = clawMat, model = footRModel})

    -- === 短手臂（两侧下垂的小圆柱） ===
    local armL = root:CreateChild("armL")
    armL.position = Vector3(-0.45 * S, 1.05 * S, 0.05 * S)
    armL.rotation = Quaternion(10, Vector3.FORWARD)
    armL.scale = Vector3(0.1 * S, 0.3 * S, 0.1 * S)
    local armLModel = armL:CreateComponent("StaticModel")
    armLModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    armLModel:SetMaterial(bodyMat)
    armLModel.castShadows = true
    table.insert(parts, {node = armL, mat = bodyMat, model = armLModel})

    local armR = root:CreateChild("armR")
    armR.position = Vector3(0.45 * S, 1.05 * S, 0.05 * S)
    armR.rotation = Quaternion(-10, Vector3.FORWARD)
    armR.scale = Vector3(0.1 * S, 0.3 * S, 0.1 * S)
    local armRModel = armR:CreateComponent("StaticModel")
    armRModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    armRModel:SetMaterial(bodyMat)
    armRModel.castShadows = true
    table.insert(parts, {node = armR, mat = bodyMat, model = armRModel})

    -- === 小爪子（手臂末端小球） ===
    local handL = root:CreateChild("handL")
    handL.position = Vector3(-0.48 * S, 0.78 * S, 0.05 * S)
    handL.scale = Vector3(0.1 * S, 0.08 * S, 0.1 * S)
    local handLModel = handL:CreateComponent("StaticModel")
    handLModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    handLModel:SetMaterial(clawMat)
    table.insert(parts, {node = handL, mat = clawMat, model = handLModel})

    local handR = root:CreateChild("handR")
    handR.position = Vector3(0.48 * S, 0.78 * S, 0.05 * S)
    handR.scale = Vector3(0.1 * S, 0.08 * S, 0.1 * S)
    local handRModel = handR:CreateComponent("StaticModel")
    handRModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    handRModel:SetMaterial(clawMat)
    table.insert(parts, {node = handR, mat = clawMat, model = handRModel})

    -- === 尾巴（短粗，从后下方伸出） ===
    local tail = root:CreateChild("tail")
    tail.position = Vector3(0, 0.7 * S, -0.4 * S)
    tail.rotation = Quaternion(-35, Vector3.RIGHT)
    tail.scale = Vector3(0.14 * S, 0.14 * S, 0.4 * S)
    local tailModel = tail:CreateComponent("StaticModel")
    tailModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    tailModel:SetMaterial(bodyMat)
    tailModel.castShadows = true
    table.insert(parts, {node = tail, mat = bodyMat, model = tailModel})

    -- === 尾尖（小锥体） ===
    local tailTip = root:CreateChild("tailTip")
    tailTip.position = Vector3(0, 0.5 * S, -0.7 * S)
    tailTip.rotation = Quaternion(-40, Vector3.RIGHT)
    tailTip.scale = Vector3(0.1 * S, 0.1 * S, 0.2 * S)
    local tailTipModel = tailTip:CreateComponent("StaticModel")
    tailTipModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    tailTipModel:SetMaterial(bodyMat)
    table.insert(parts, {node = tailTip, mat = bodyMat, model = tailTipModel})

    return root, head, mouth, parts, bodyMat
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
    local meshRoot, headNode, mouthNode, parts, bodyMat = CreateBeastModel(beastNode)
    beast.meshRoot = meshRoot
    beast.headNode = headNode
    beast.mouthNode = mouthNode
    beast.bodyParts = parts

    -- 物理碰撞体（适配1.5倍胖体型：宽1.5m 高2.7m）
    local rbody = beastNode:CreateComponent("RigidBody")
    rbody.mass = 1.0
    rbody.collisionLayer = 2          -- 玩家层（不被玩家攻击）
    rbody.collisionMask = 1 | 4       -- 与地形和敌人碰撞
    rbody.angularFactor = Vector3(0, 0, 0)
    rbody.linearFactor = Vector3(1, 0, 1)
    rbody.friction = 0.5
    rbody.linearDamping = 0.1
    local shape = beastNode:CreateComponent("CollisionShape")
    shape:SetCapsule(1.5, 2.7, Vector3(0, 1.35, 0))

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
    fireBreath.damageTimer = 0

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

-- 喷火锥形范围伤害检测
local function UpdateFireBreathDamage(dt, enemies, player, dealDamageFn)
    if not fireBreath.active then return end
    if not beast.mouthNode then return end

    fireBreath.damageTimer = fireBreath.damageTimer - dt
    if fireBreath.damageTimer > 0 then return end
    fireBreath.damageTimer = fireBreath.damageInterval

    -- 对锥形范围内所有敌人造成伤害
    local mouthWorldPos = beast.mouthNode.worldPosition
    local coneAngleRad = math.rad(fireBreath.coneAngle)
    local cosThreshold = math.cos(coneAngleRad)

    if not enemies then return end
    for _, e in ipairs(enemies) do
        if e.state ~= "dead" and e.state ~= "dying" then
            local toEnemy = e.node.position - mouthWorldPos
            toEnemy.y = 0
            local dist = toEnemy:Length()

            -- 在射程内？
            if dist <= fireBreath.range + 1.0 then
                -- 在锥角内？
                if dist > 0.1 then
                    local dirToEnemy = toEnemy:Normalized()
                    local dot = fireBreath.dir.x * dirToEnemy.x + fireBreath.dir.z * dirToEnemy.z
                    if dot >= cosThreshold then
                        -- 命中！造成伤害
                        if dealDamageFn then
                            dealDamageFn(e, beast.atk, player)
                        end
                    end
                else
                    -- 距离太近，直接命中
                    if dealDamageFn then
                        dealDamageFn(e, beast.atk, player)
                    end
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
            if rbody then rbody:SetLinearVelocity(Vector3.ZERO) end

            if beast.attackTimer <= 0 then
                StartFireBreath(scene, nearestEnemy.node.position)
                beast.attackTimer = beast.attackCD
            end

            UpdateFacing(beastPos, nearestEnemy.node.position)
        else
            -- 追击
            beast.state = "chase"
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
            local dir = toPlayer:Normalized()
            local followSpeed = beast.speed * 1.2
            if rbody then rbody:SetLinearVelocity(dir * followSpeed) end
            UpdateFacing(beastPos, playerPos)
        else
            if rbody then rbody:SetLinearVelocity(Vector3.ZERO) end
        end

        -- 太远则传送
        if distToPlayer > 20 then
            beast.node.position = playerPos + Vector3(2, 0, 2)
        end
    end

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
