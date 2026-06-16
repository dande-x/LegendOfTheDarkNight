-- ============================================================================
-- DivineBeast.lua — 神兽系统
-- 使用 prefab 模型（AnimatedModel + AnimationController），与主角一致
-- 体型为角色的1.3倍高度（约2.3m），深色神兽材质，喷火攻击，可升级
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
-- Prefab 和动画配置
-- ============================================================================
local BEAST_PREFAB = "Prefabs/DivineBeast.prefab"
local BEAST_TARGET_HEIGHT = 2.3  -- 神兽目标高度（比主角高）

-- 动画资源（使用与 Tripo Rig 兼容的官方动画，运行时自动重定向）
local BEAST_ANIMS = {
    idle = "uuid://GikiEX04hbY9D5ALGNz051Zh",   -- 枪骑士战斗待机 1.33s loop（Tripo兼容）
    move = "uuid://F-afGUmbZwlJu4crZmqR_4kR",   -- 中速跑 1.0s loop（Tripo兼容）
    attack = "uuid://Ai-SCaONHGJAnRCLZmoO2QJ8",  -- 突刺 1.07s（喷火时播放）
}

-- 动画播放速度（神兽体型大，动作应更沉重缓慢）
local BEAST_ANIM_SPEEDS = {
    idle = 0.7,     -- 待机慢速，显得稳重沉着
    move = 0.55,    -- 跑步大幅降速，体现巨兽沉重步伐
    attack = 0.85,  -- 攻击略慢，力量感
}

-- 头部骨骼名候选列表（Tripo rig 可能使用不同命名）
local HEAD_BONE_CANDIDATES = {"Head", "head", "Bip001 Head", "mixamorig:Head"}

-- ============================================================================
-- 工具函数
-- ============================================================================
local function CreatePBRMat(color, roughness, metallic, emissive)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.6))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    if emissive then
        mat:SetShaderParameter("MatEmissiveColor", Variant(emissive))
    end
    return mat
end

-- ============================================================================
-- 神兽状态 (单例 — 只有一只)
-- ============================================================================
local beast = {
    alive = false,
    node = nil,
    modelNode = nil,      -- prefab 根节点
    animModel = nil,      -- AnimatedModel 组件
    animCtrl = nil,       -- AnimationController 组件
    headBoneNode = nil,   -- 头部骨骼节点
    mouthNode = nil,      -- 嘴巴位置标记（头部子节点）
    originalMats = {},    -- 原始材质列表（闪烁恢复用）
    level = 1,
    exp = 0,
    expToNext = LEVEL_EXP[1],
    maxHP = 300,
    hp = 300,
    atk = 18,
    baseAtk = 18,
    def = 8,
    speed = 3.2,
    attackCD = 2.0,
    attackTimer = 0,
    attackRange = 5.0,
    chaseRange = 9.0,
    state = "follow",  -- follow / chase / attack
    buffTimer = 0,
    buffMult = 1.0,
    fireTimer = 0,
    hitFlashTimer = 0,
    -- 动画状态
    currentAnim = "idle",
    isMoving = false,
    -- 模型缩放信息
    baseScale = 1.0,
    baseFootOffset = 0.0,
}

DivineBeast.beast = beast

-- 前向声明（Die/Clear 中需要访问）
local fireBreath = {
    active = false,
    timer = 0,
    duration = 0.4,
    dir = Vector3.ZERO,
    nodes = {},
    coneAngle = 35,
    range = 5.0,
    hitSet = {},
}

-- ============================================================================
-- 创建模型：使用 Prefab + AnimatedModel（与主角相同方式）
-- ============================================================================
local function CreateBeastModel(parentNode, scene)
    -- 加载 prefab
    local prefabFile = cache:GetFile(BEAST_PREFAB)
    if not prefabFile then
        print("[DivineBeast] ERROR: Cannot find prefab: " .. BEAST_PREFAB)
        return false
    end

    local prefabNode = scene:InstantiateXML(prefabFile, Vector3.ZERO, Quaternion.IDENTITY, LOCAL)
    prefabFile:Close()

    if not prefabNode then
        print("[DivineBeast] ERROR: Failed to instantiate prefab")
        return false
    end

    -- 挂到父节点下
    prefabNode.parent = parentNode
    prefabNode.name = "BeastModel"
    beast.modelNode = prefabNode

    -- 获取 AnimatedModel 组件
    beast.animModel = prefabNode:GetComponent("AnimatedModel")
    if not beast.animModel then
        beast.animModel = prefabNode:GetComponent("AnimatedModel", true)
    end

    if not beast.animModel then
        print("[DivineBeast] ERROR: No AnimatedModel in prefab!")
        prefabNode:Remove()
        return false
    end

    -- 计算缩放，使神兽达到目标高度
    local bb = beast.animModel.boundingBox
    local h = bb.size.y
    local minY = bb.min.y

    if h > 0 then
        local s = BEAST_TARGET_HEIGHT / h
        beast.baseScale = s
        beast.baseFootOffset = -minY * s
        prefabNode.scale = Vector3(s, s, s)
        prefabNode.position = Vector3(0, beast.baseFootOffset, 0)
    end

    -- 获取 AnimationController
    beast.animCtrl = prefabNode:GetComponent("AnimationController")
        or prefabNode:GetComponent("AnimationController", true)
    if not beast.animCtrl then
        beast.animCtrl = prefabNode:CreateComponent("AnimationController")
    end

    -- 保留模型自带的贴图材质（不覆盖），记录原始材质用于受击闪烁恢复
    local numGeom = beast.animModel:GetNumGeometries()
    beast.originalMats = {}
    for i = 0, numGeom - 1 do
        beast.originalMats[i] = beast.animModel:GetMaterial(i)
    end

    -- 获取头部骨骼节点（用于定位嘴巴喷火）
    local skeleton = beast.animModel:GetSkeleton()
    if skeleton then
        for _, boneName in ipairs(HEAD_BONE_CANDIDATES) do
            local headBone = skeleton:GetBone(boneName)
            if headBone and headBone.node then
                beast.headBoneNode = headBone.node
                -- 在头部骨骼前方创建嘴巴标记节点
                beast.mouthNode = headBone.node:CreateChild("BeastMouth")
                beast.mouthNode.position = Vector3(0, 0.1, 0.4)  -- 头部前方偏上
                print("[DivineBeast] Head bone found: " .. boneName .. ", mouth node attached")
                break
            end
        end
        if not beast.headBoneNode then
            print("[DivineBeast] WARNING: No head bone found in candidates, using fallback")
        end
    end

    -- 如果没有找到头部骨骼，创建一个固定位置的嘴巴节点
    if not beast.mouthNode then
        beast.mouthNode = prefabNode:CreateChild("BeastMouthFallback")
        beast.mouthNode.position = Vector3(0, 1.8 / beast.baseScale, 0.5 / beast.baseScale)
    end

    -- 播放初始 idle 动画
    if beast.animCtrl and BEAST_ANIMS.idle then
        beast.animCtrl:PlayExclusive(BEAST_ANIMS.idle, 0, true, 0.0)
        beast.currentAnim = "idle"
    end

    print("[DivineBeast] Beast model created with prefab, height=" .. BEAST_TARGET_HEIGHT)
    return true
end

-- ============================================================================
-- 动画控制
-- ============================================================================
local function PlayBeastAnim(animName, loop)
    if not beast.animCtrl then return end
    local animPath = BEAST_ANIMS[animName]
    if not animPath then return end
    if beast.currentAnim == animName then return end

    beast.currentAnim = animName
    local isLoop = loop ~= false and (animName == "idle" or animName == "move")
    beast.animCtrl:PlayExclusive(animPath, 0, isLoop, 0.3)

    -- 应用播放速度（让动作更沉重）
    local speed = BEAST_ANIM_SPEEDS[animName] or 1.0
    beast.animCtrl:SetSpeed(animPath, speed)
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
    beast.speed = 3.2
    beast.attackCD = 2.0
    beast.attackTimer = 0
    beast.state = "follow"
    beast.buffTimer = 0
    beast.buffMult = 1.0
    beast.fireTimer = 0
    beast.hitFlashTimer = 0
    beast.isMoving = false
    beast.currentAnim = "idle"

    -- 创建根节点
    local beastNode = scene:CreateChild("DivineBeast")
    beastNode.position = playerPos + Vector3(2, 0, 2)

    -- 创建 3D 模型（prefab 方式）
    local success = CreateBeastModel(beastNode, scene)
    if not success then
        print("[DivineBeast] ERROR: Failed to create beast model, using fallback")
        -- fallback: 简单圆柱体
        local fallbackNode = beastNode:CreateChild("BeastFallback")
        local sm = fallbackNode:CreateComponent("StaticModel")
        sm:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        sm:SetMaterial(CreatePBRMat(Color(0.15, 0.22, 0.12, 1.0), 0.5, 0.3))
        fallbackNode.scale = Vector3(0.8, 2.3, 0.8)
        fallbackNode.position = Vector3(0, 1.15, 0)
        beast.modelNode = fallbackNode

        -- fallback 嘴巴节点
        beast.mouthNode = beastNode:CreateChild("BeastMouthFallback")
        beast.mouthNode.position = Vector3(0, 2.0, 0.5)
    end

    -- 物理碰撞体（适配体型：宽1.3m 高2.3m）
    local rbody = beastNode:CreateComponent("RigidBody")
    rbody.mass = 1.0
    rbody.collisionLayer = 2          -- 玩家层（不被玩家攻击）
    rbody.collisionMask = 1 | 4       -- 与地形和敌人碰撞
    rbody.angularFactor = Vector3(0, 0, 0)
    rbody.linearFactor = Vector3(1, 0, 1)
    rbody.friction = 0.5
    rbody.linearDamping = 0.1
    local shape = beastNode:CreateComponent("CollisionShape")
    shape:SetCapsule(1.3, 2.3, Vector3(0, 1.15, 0))

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
    beast.modelNode = nil
    beast.animModel = nil
    beast.animCtrl = nil
    beast.headBoneNode = nil
    beast.mouthNode = nil
    beast.originalMats = {}
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

        -- 升级后更新材质颜色（等级越高越偏蓝绿）
        DivineBeast.UpdateLevelMaterial()

        print("[DivineBeast] 升级! Lv." .. beast.level .. " HP=" .. beast.maxHP .. " ATK=" .. beast.atk)
    end
end

-- ============================================================================
-- 等级材质更新（通过自发光叠加体现等级，保留原始贴图）
-- ============================================================================
function DivineBeast.UpdateLevelMaterial()
    if not beast.animModel then return end

    local lc = LEVEL_COLORS[beast.level] or LEVEL_COLORS[1]
    -- 等级越高，自发光越强（不改变漫反射贴图）
    local emissiveStrength = beast.level * 0.08
    local emissiveColor = Color(
        lc[1] / 255 * emissiveStrength,
        lc[2] / 255 * emissiveStrength,
        lc[3] / 255 * emissiveStrength
    )

    local numGeom = beast.animModel:GetNumGeometries()
    for i = 0, numGeom - 1 do
        local mat = beast.originalMats[i]
        if mat then
            -- Clone 材质以避免修改共享资源
            local levelMat = mat:Clone()
            levelMat:SetShaderParameter("MatEmissiveColor", Variant(emissiveColor))
            beast.originalMats[i] = levelMat
            beast.animModel:SetMaterial(i, levelMat)
        end
    end
end

-- ============================================================================
-- Buff 增益
-- ============================================================================
function DivineBeast.ApplyBuff(multiplier, duration)
    beast.buffMult = multiplier
    beast.buffTimer = duration
    beast.atk = math.floor(beast.baseAtk * multiplier)
    beast.attackCD = beast.attackCD / multiplier
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
    if fireBreath.active then return end

    local mouthWorldPos = beast.mouthNode.worldPosition
    local dir = targetPos - mouthWorldPos
    dir.y = 0
    if dir:Length() < 0.1 then return end
    dir = dir:Normalized()

    fireBreath.active = true
    fireBreath.timer = fireBreath.duration
    fireBreath.dir = dir
    fireBreath.hitSet = {}

    -- 播放攻击动画
    PlayBeastAnim("attack", false)

    -- 创建火焰锥形视觉
    local segCount = 6
    for i = 1, segCount do
        local t = i / segCount
        local dist = t * fireBreath.range
        local size = 0.3 + t * 1.2

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

-- 更新火焰视觉
local function UpdateFireBreathVisual(dt)
    if not fireBreath.active then return end

    fireBreath.timer = fireBreath.timer - dt

    if beast.mouthNode then
        local mouthWorldPos = beast.mouthNode.worldPosition
        local segCount = #fireBreath.nodes
        for i, node in ipairs(fireBreath.nodes) do
            local t = i / segCount
            local dist = t * fireBreath.range
            local size = (0.3 + t * 1.2) * (0.7 + math.random() * 0.6)

            local jitterX = (math.random() - 0.5) * 0.4 * t
            local jitterY = (math.random() - 0.5) * 0.3 * t + 0.1 * t
            local jitterZ = (math.random() - 0.5) * 0.4 * t

            node.position = mouthWorldPos + fireBreath.dir * dist + Vector3(jitterX, jitterY, jitterZ)
            node.scale = Vector3(size, size, size)
        end
    end

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

    local mouthWorldPos = beast.mouthNode.worldPosition
    local coneAngleRad = math.rad(fireBreath.coneAngle)
    local cosThreshold = math.cos(coneAngleRad)

    if not enemies then return end
    for _, e in ipairs(enemies) do
        if e.state ~= "dead" and e.state ~= "dying" and not fireBreath.hitSet[e] then
            local toEnemy = e.node.position - mouthWorldPos
            toEnemy.y = 0
            local dist = toEnemy:Length()

            if dist <= fireBreath.range + 1.0 then
                local hit = false
                if dist > 0.1 then
                    local dirToEnemy = toEnemy:Normalized()
                    local dot = fireBreath.dir.x * dirToEnemy.x + fireBreath.dir.z * dirToEnemy.z
                    if dot >= cosThreshold then
                        hit = true
                    end
                else
                    hit = true
                end

                if hit and dealDamageFn then
                    dealDamageFn(e, beast.atk, player)
                    fireBreath.hitSet[e] = true
                end
            end
        end
    end
end

-- ============================================================================
-- 受击闪烁效果（AnimatedModel 材质闪红）
-- ============================================================================
local function UpdateHitFlash(dt)
    if not beast.animModel then return end

    if beast.hitFlashTimer > 0 then
        beast.hitFlashTimer = beast.hitFlashTimer - dt
        local flash = math.floor(beast.hitFlashTimer * 10) % 2 == 0
        local numGeom = beast.animModel:GetNumGeometries()

        if flash then
            local flashMat = CreatePBRMat(
                Color(1.0, 0.2, 0.2, 1.0), 0.5, 0.0,
                Color(1.0, 0.0, 0.0)
            )
            for i = 0, numGeom - 1 do
                beast.animModel:SetMaterial(i, flashMat)
            end
        else
            for i = 0, numGeom - 1 do
                if beast.originalMats[i] then
                    beast.animModel:SetMaterial(i, beast.originalMats[i])
                end
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
            beast.isMoving = false
            if rbody then rbody:SetLinearVelocity(Vector3.ZERO) end

            if beast.attackTimer <= 0 then
                StartFireBreath(scene, nearestEnemy.node.position)
                beast.attackTimer = beast.attackCD
            end

            -- 非攻击动画时回到 idle
            if not fireBreath.active and beast.currentAnim ~= "idle" then
                PlayBeastAnim("idle")
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

            PlayBeastAnim("move")
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

            PlayBeastAnim("move")
        else
            beast.isMoving = false
            if rbody then rbody:SetLinearVelocity(Vector3.ZERO) end

            PlayBeastAnim("idle")
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
    beast.modelNode = nil
    beast.animModel = nil
    beast.animCtrl = nil
    beast.headBoneNode = nil
    beast.mouthNode = nil
    beast.originalMats = {}
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
