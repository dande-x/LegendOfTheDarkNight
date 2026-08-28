-- ============================================================================
-- DivineBeast.lua — 神兽系统
-- 使用 prefab 模型（AnimatedModel + AnimationController），与主角一致
-- 体型为角色的1.3倍高度（约2.3m），深色神兽材质，喷火攻击，可升级
-- ============================================================================

local CharacterClass = require("scripts.CharacterClass")
local Balance = require("scripts.Balance")

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
    hp_per_level = 65,
    atk_per_level = 8,
    def_per_level = 2.5,
}

-- 存档边界：成长属性由本模块决定，不能被可编辑的 JSON 无限放大。
-- 上限高于当前正常曲线，兼容未来调数值，同时避免溢出/一击秒杀。
local MAX_BEAST_LEVEL = 7
local MAX_BEAST_EXP = 1000000
local MAX_BEAST_HP = 100000
local MAX_BEAST_ATK = 100000
local MAX_BEAST_DEF = 10000

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
    idle = 0.75,    -- 待机慢速，显得稳重沉着
    move = 0.8,     -- 跑步适中降速，保证腿部动作可见
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
    -- summoned 表示这只神兽是否曾经被召唤过；它与 alive 分离，
    -- 这样神兽死亡后仍能保留成长状态；死亡惩罚会先扣级并清零经验，
    -- 重新召唤时沿用惩罚后的等级，不会直接回到初始状态。
    summoned = false,
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
    speed = 4.0,
    baseAttackCD = 2.0,
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
    buffFlashAccum = 0,
    isMoving = false,
    ownerStats = nil,     -- 当前主人面板快照，用于升级/换装后的实时同步
    summonDamagePercent = Balance.DIVINE_BEAST_ATK_PERCENT,
    ownerPassiveMultiplier = 1.0,
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

local function ResetFireBreath()
    for _, node in ipairs(fireBreath.nodes) do
        if node then node:Remove() end
    end
    fireBreath.nodes = {}
    fireBreath.active = false
    fireBreath.timer = 0
    fireBreath.dir = Vector3.ZERO
    fireBreath.hitSet = {}
end

-- 只清理场景实体和战斗瞬时状态，不触碰神兽长期成长。
-- 地图切换、异常节点修复、死亡都必须走这里；只有离开角色会话才调用 Clear。
local function ClearBeastEntity()
    if beast.node then
        beast.node:Remove()
        beast.node = nil
    end
    beast.alive = false
    beast.modelNode = nil
    beast.animModel = nil
    beast.animCtrl = nil
    beast.headBoneNode = nil
    beast.mouthNode = nil
    beast.originalMats = {}
    beast.attackTimer = 0
    beast.fireTimer = 0
    beast.buffTimer = 0
    beast.buffMult = 1.0
    beast.buffFlashAccum = 0
    beast.attackCD = beast.baseAttackCD or 2.0
    beast.state = "follow"
    beast.isMoving = false
    beast.hitFlashTimer = 0
    ResetFireBreath()
end

local function ResetBeastGrowth()
    beast.summoned = false
    beast.level = 1
    beast.exp = 0
    beast.expToNext = LEVEL_EXP[1]
    beast.maxHP = 300
    beast.hp = 0
    beast.baseAtk = 18
    beast.atk = 18
    beast.def = 8
    beast.ownerStats = nil
    beast.summonDamagePercent = Balance.DIVINE_BEAST_ATK_PERCENT
    beast.ownerPassiveMultiplier = 1.0
end

local function SafeNonNegativeInteger(value, fallback, maxValue)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return fallback or 0
    end
    number = math.max(0, number)
    if maxValue then number = math.min(maxValue, number) end
    return math.floor(number)
end

local function ReadOwnerSnapshot(player)
    if type(player) ~= "table" then return nil end

    local summonSkill = CharacterClass.GetSkillById
        and CharacterClass.GetSkillById(player.classId, "t_divineBeast") or nil
    return {
        maxHP = math.max(1, tonumber(player.maxHP) or 1),
        atk = math.max(0, tonumber(player.atk) or 0),
        def = math.max(0, tonumber(player.def) or 0),
        summonDamagePercent = summonSkill and summonSkill.damage
            or Balance.DIVINE_BEAST_ATK_PERCENT,
        passiveMultiplier = CharacterClass.GetDivineBeastAttackMultiplier
            and CharacterClass.GetDivineBeastAttackMultiplier(player) or 1.0,
    }
end

local function CaptureOwnerStats(player)
    local snapshot = ReadOwnerSnapshot(player)
    if not snapshot then return false end

    beast.ownerStats = {
        maxHP = snapshot.maxHP,
        atk = snapshot.atk,
        def = snapshot.def,
    }
    beast.summonDamagePercent = snapshot.summonDamagePercent
    beast.ownerPassiveMultiplier = snapshot.passiveMultiplier
    return true
end

local function RecalculateOwnerStats(player, fallbackAttack, refill)
    local oldMaxHP = math.max(1, tonumber(beast.maxHP) or 1)
    local oldHP = math.max(0, tonumber(beast.hp) or 0)
    local stats = nil

    if type(player) == "table" then
        CaptureOwnerStats(player)
    elseif fallbackAttack ~= nil then
        -- 旧调用只提供最终神兽攻击力，不能再套召唤技能或职业被动倍率。
        -- 生命与防御保留已恢复的安全值；下一次拿到 player 后会切回实时同步。
        beast.ownerStats = nil
        stats = {
            maxHP = math.max(300 + BEAST_GROWTH.hp_per_level * (beast.level - 1),
                SafeNonNegativeInteger(beast.maxHP, 300, MAX_BEAST_HP)),
            atk = math.max(1,
                SafeNonNegativeInteger(fallbackAttack, beast.baseAtk, MAX_BEAST_ATK)),
            def = math.max(math.floor(8 + BEAST_GROWTH.def_per_level * (beast.level - 1) + 0.5),
                SafeNonNegativeInteger(beast.def, 8, MAX_BEAST_DEF)),
        }
    end

    if not stats then
        if not beast.ownerStats then return false end
        stats = Balance.GetDivineBeastStats(
            beast.ownerStats,
            beast.level,
            beast.summonDamagePercent,
            beast.ownerPassiveMultiplier)
    end
    beast.maxHP = stats.maxHP
    beast.baseAtk = stats.atk
    beast.atk = math.max(1, math.floor(beast.baseAtk * (beast.buffMult or 1.0)))
    beast.def = stats.def

    if refill then
        beast.hp = beast.maxHP
    elseif oldHP > 0 then
        local hpRatio = math.max(0, math.min(1, oldHP / oldMaxHP))
        beast.hp = math.max(1, math.min(beast.maxHP,
            math.floor(beast.maxHP * hpRatio + 0.5)))
    end
    return true
end

--- 主人升级或换装后同步神兽面板；保持当前生命百分比，防止换装刷血。
---@param player table
---@return boolean
function DivineBeast.SyncOwnerStats(player)
    local snapshot = ReadOwnerSnapshot(player)
    if not snapshot then return false end

    local current = beast.ownerStats
    local unchanged = current
        and current.maxHP == snapshot.maxHP
        and current.atk == snapshot.atk
        and current.def == snapshot.def
        and beast.summonDamagePercent == snapshot.summonDamagePercent
        and beast.ownerPassiveMultiplier == snapshot.passiveMultiplier
    if unchanged then return false end

    return RecalculateOwnerStats(player, nil, false)
end

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

-- 恢复神兽模型自带的贴图材质。等级颜色只用于名字 UI，不能写入模型材质。
local function RestoreOriginalMaterials()
    if not beast.animModel then return end

    local numGeom = beast.animModel:GetNumGeometries()
    for i = 0, numGeom - 1 do
        if beast.originalMats[i] then
            beast.animModel:SetMaterial(i, beast.originalMats[i])
        end
    end
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
function DivineBeast.Summon(scene, playerPos, playerAtk, player)
    if not scene or not playerPos then
        print("[DivineBeast] ERROR: Cannot summon without scene and player position")
        return false
    end

    if DivineBeast.IsAlive() then
        print("[DivineBeast] 神兽已存在，无法再次召唤")
        return false
    end

    -- 正常路径里 alive 与 node 总是同步。若读档中断或节点被外部移除
    -- 留下半截状态，先清理再召唤，避免技能栏显示可召唤但 Summon 拒绝执行。
    if beast.alive or beast.node then
        print("[DivineBeast] WARNING: Cleaning orphaned beast state before summon")
        ClearBeastEntity()
    end

    -- 第一次召唤初始化成长；死亡后再次召唤必须保留死亡惩罚后的成长。
    if not beast.summoned then
        beast.summoned = true
        beast.level = 1
        beast.exp = 0
        beast.expToNext = LEVEL_EXP[1]
        beast.maxHP = 300
        beast.def = 8
    else
        beast.level = math.max(1, math.min(MAX_BEAST_LEVEL, SafeNonNegativeInteger(beast.level, 1, MAX_BEAST_LEVEL)))
        beast.expToNext = LEVEL_EXP[beast.level]
        beast.exp = beast.level >= MAX_BEAST_LEVEL and 0
            or math.min(SafeNonNegativeInteger(beast.exp, 0, MAX_BEAST_EXP), beast.expToNext - 1)
    end
    -- 攻击、生命和防御都按主人当前面板计算；没有 player 的旧调用中，
    -- playerAtk 视为已经结算完成的神兽攻击力，绝不再次乘技能倍率。
    RecalculateOwnerStats(player, playerAtk, true)
    beast.speed = 4.0
    beast.baseAttackCD = 2.0
    beast.attackCD = 2.0
    beast.attackTimer = 0
    beast.state = "follow"
    beast.buffTimer = 0
    beast.buffMult = 1.0
    beast.fireTimer = 0
    beast.hitFlashTimer = 0
    beast.buffFlashAccum = 0
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
    if not DivineBeast.IsAlive() then return 0 end

    dmg = tonumber(dmg)
    if not dmg or dmg ~= dmg or dmg == math.huge or dmg == -math.huge or dmg <= 0 then
        return 0
    end

    local effectiveDmg = Balance.CalculateDamage(dmg, beast.def)
    if effectiveDmg <= 0 then return 0 end

    beast.hp = beast.hp - effectiveDmg
    beast.hitFlashTimer = 0.2

    if beast.hp <= 0 then
        DivineBeast.Die()
    end
    return effectiveDmg
end

-- ============================================================================
-- 神兽死亡
-- ============================================================================
function DivineBeast.Die()
    if not beast.alive and not beast.node then return end
    print("[DivineBeast] 神兽阵亡!")
    -- 神兽死亡会受到成长惩罚：清空当前经验，且等级大于 1 时下降 1 级。
    -- 这里只处理真正的死亡；地图切换/异常节点清理仍只调用 ClearBeastEntity。
    local previousLevel = math.max(1, math.min(MAX_BEAST_LEVEL,
        SafeNonNegativeInteger(beast.level, 1, MAX_BEAST_LEVEL)))
    beast.level = math.max(1, previousLevel - 1)
    beast.exp = 0
    beast.expToNext = LEVEL_EXP[beast.level]
    ClearBeastEntity()
    beast.hp = 0
    print("[DivineBeast] 死亡惩罚：Lv." .. previousLevel .. " -> Lv." .. beast.level
        .. "，经验已清零")
end

-- ============================================================================
-- 增加经验
-- ============================================================================
function DivineBeast.AddExp(exp)
    if not DivineBeast.IsAlive() then return end
    if beast.level >= MAX_BEAST_LEVEL then
        beast.level = MAX_BEAST_LEVEL
        beast.exp = 0
        beast.expToNext = LEVEL_EXP[MAX_BEAST_LEVEL]
        return
    end
    exp = SafeNonNegativeInteger(exp, 0, MAX_BEAST_EXP)
    if exp <= 0 then return end

    beast.exp = math.min(MAX_BEAST_EXP, beast.exp + exp)
    while beast.exp >= beast.expToNext and beast.level < MAX_BEAST_LEVEL do
        beast.exp = beast.exp - beast.expToNext
        beast.level = beast.level + 1
        beast.expToNext = LEVEL_EXP[beast.level]

        -- 等级成长叠加在主人当前面板之上，升级回满生命。
        RecalculateOwnerStats(nil, nil, true)

        print("[DivineBeast] 升级! Lv." .. beast.level .. " HP=" .. beast.maxHP .. " ATK=" .. beast.atk)
    end
    if beast.level >= MAX_BEAST_LEVEL then
        beast.exp = 0
        beast.expToNext = LEVEL_EXP[MAX_BEAST_LEVEL]
    end
end

-- ============================================================================
-- Buff 增益
-- ============================================================================
function DivineBeast.ApplyBuff(multiplier, duration)
    if not DivineBeast.IsAlive() then return false end
    multiplier = tonumber(multiplier)
    duration = tonumber(duration)
    if not multiplier or multiplier ~= multiplier or multiplier == math.huge or multiplier <= 0 then
        return false
    end
    if not duration or duration ~= duration or duration == math.huge or duration <= 0 then
        return false
    end
    multiplier = math.max(1.0, math.min(5.0, multiplier))
    duration = math.min(600, duration)
    beast.buffMult = multiplier
    beast.buffTimer = duration
    beast.buffFlashAccum = 0  -- 初始化狂暴闪光计时器
    beast.atk = math.floor(beast.baseAtk * multiplier)
    -- 以基础 CD 计算，重复施放 Buff 不会把冷却时间无限除小。
    beast.attackCD = (beast.baseAttackCD or 2.0) / multiplier
    print("[DivineBeast] 获得增益! ATKx" .. multiplier .. " 持续" .. duration .. "s")
    return true
end

-- ============================================================================
-- 治疗神兽
-- ============================================================================
function DivineBeast.Heal(amount)
    if not DivineBeast.IsAlive() then return false end
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount == math.huge or amount <= 0 then return false end
    amount = math.max(1, math.floor(amount + 0.5))
    beast.hp = math.min(beast.maxHP, beast.hp + amount)
    return true
end

-- ============================================================================
-- 获取等级颜色
-- ============================================================================
function DivineBeast.IsAlive()
    local alive = beast.alive and beast.node ~= nil
    if beast.alive and not beast.node then
        -- 外部销毁节点时同步逻辑状态，但保留长期成长，等待重新召唤。
        beast.alive = false
        beast.hp = 0
        beast.attackTimer = 0
        ResetFireBreath()
    end
    return alive
end

function DivineBeast.GetNameColor()
    return LEVEL_COLORS[beast.level] or LEVEL_COLORS[1]
end

-- ============================================================================
-- 获取当前状态（供 UI 显示）
-- ============================================================================
function DivineBeast.GetDisplayInfo()
    return {
        alive = DivineBeast.IsAlive(),
        name = "神兽",
        level = beast.level,
        hp = beast.hp,
        maxHP = beast.maxHP,
        exp = beast.level >= MAX_BEAST_LEVEL and 0 or beast.exp,
        expToNext = beast.expToNext,
        nameColor = DivineBeast.GetNameColor(),
    }
end

--- 导出可持久化的神兽成长状态。
--- 只保存长期成长；狂暴、喷火和攻击冷却属于瞬时战斗状态，读档后重置。
---@return table|nil
function DivineBeast.GetSaveData()
    local alive = DivineBeast.IsAlive()
    if not beast.summoned then return nil end
    return {
        version = 2,
        summoned = true,
        alive = alive,
        level = beast.level,
        exp = beast.level >= MAX_BEAST_LEVEL and 0 or beast.exp,
        hp = alive and beast.hp or 0,
        maxHP = beast.maxHP,
        baseAtk = beast.baseAtk,
        def = beast.def,
    }
end

--- 在角色节点创建后恢复永久神兽。
---@param scene Scene
---@param playerPos Vector3
---@param saved table|nil
---@param fallbackPlayerAtk number|nil
---@return boolean
function DivineBeast.Restore(scene, playerPos, saved, fallbackPlayerAtk)
    if not scene or not playerPos then
        return false
    end

    -- Restore 是角色/存档边界。即使传入 nil 或坏数据，也必须先清除上一
    -- 角色留下的成长状态；只 ClearBeastEntity 会让旧 summoned/level 泄漏。
    ClearBeastEntity()
    ResetBeastGrowth()

    if type(saved) ~= "table" then
        return false
    end

    -- 兼容旧版只有 alive=true 的存档；新版用 summoned 明确区分“曾召唤但已死亡”。
    local wasSummoned = saved.summoned == true or saved.alive == true
    if not wasSummoned then return false end

    beast.summoned = true

    local level = math.max(1, math.min(MAX_BEAST_LEVEL,
        SafeNonNegativeInteger(saved.level, 1, MAX_BEAST_LEVEL)))
    local minMaxHP = 300 + BEAST_GROWTH.hp_per_level * (level - 1)
    local minDef = math.floor(8 + BEAST_GROWTH.def_per_level * (level - 1) + 0.5)
    local fallbackAtk = math.max(1, math.floor(
        SafeNonNegativeInteger(fallbackPlayerAtk, 0, MAX_BEAST_ATK)
        * (Balance.DIVINE_BEAST_ATK_PERCENT / 100)))
    local savedBaseAtk = SafeNonNegativeInteger(saved.baseAtk, fallbackAtk, MAX_BEAST_ATK)

    beast.level = level
    beast.expToNext = LEVEL_EXP[level]
    beast.exp = level >= MAX_BEAST_LEVEL and 0 or math.max(0, math.min(
        SafeNonNegativeInteger(saved.exp, 0, MAX_BEAST_EXP), beast.expToNext - 1))
    beast.maxHP = math.max(minMaxHP,
        SafeNonNegativeInteger(saved.maxHP, minMaxHP, MAX_BEAST_HP))
    local savedHP = SafeNonNegativeInteger(saved.hp, beast.maxHP, MAX_BEAST_HP)
    beast.hp = math.max(1, math.min(beast.maxHP, savedHP))
    beast.baseAtk = math.max(fallbackAtk, savedBaseAtk, 1)
    beast.atk = beast.baseAtk
    beast.def = math.max(minDef, SafeNonNegativeInteger(saved.def, minDef, MAX_BEAST_DEF))
    beast.buffTimer = 0
    beast.buffMult = 1.0
    beast.baseAttackCD = 2.0
    beast.attackCD = beast.baseAttackCD
    beast.attackTimer = 0
    beast.state = "follow"

    -- 死亡存档只恢复成长数据，不立即创建实体；玩家下一次主动召唤时满血复生。
    if saved.alive ~= true then
        beast.alive = false
        beast.hp = 0
        return false
    end

    -- Summon 负责创建模型和物理组件；成长数据已先归一化，召唤时会保留它。
    if not DivineBeast.Summon(scene, playerPos, beast.baseAtk) then
        return false
    end
    beast.hp = math.max(1, math.min(beast.maxHP,
        SafeNonNegativeInteger(saved.hp, beast.maxHP, MAX_BEAST_HP)))

    print("[DivineBeast] Restored Lv." .. beast.level .. " HP=" .. beast.hp .. "/" .. beast.maxHP)
    return true
end

--- 地图切换时清除战斗瞬时状态，并把存活神兽放到新出生点附近。
---@param playerPos Vector3
---@return boolean
function DivineBeast.OnMapChanged(playerPos)
    if not playerPos then return false end
    local alive = DivineBeast.IsAlive()
    -- 先清理旧地图上的火焰、Buff、攻击计时和物理速度。
    beast.buffTimer = 0
    beast.buffMult = 1.0
    beast.atk = beast.baseAtk
    beast.baseAttackCD = beast.baseAttackCD or 2.0
    beast.attackCD = beast.baseAttackCD
    beast.attackTimer = 0
    beast.fireTimer = 0
    beast.hitFlashTimer = 0
    beast.buffFlashAccum = 0
    beast.state = "follow"
    beast.isMoving = false
    ResetFireBreath()
    RestoreOriginalMaterials()

    if not alive or not beast.node then return false end
    local body = beast.node:GetComponent("RigidBody")
    if body then body:SetLinearVelocity(Vector3.ZERO) end
    beast.node.position = playerPos + Vector3(2, 0, 2)
    PlayBeastAnim("idle")
    return true
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
        beast.hitFlashTimer = math.max(0, beast.hitFlashTimer - dt)
        local flash = beast.hitFlashTimer > 0 and math.floor(beast.hitFlashTimer * 10) % 2 == 0
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
            RestoreOriginalMaterials()
        end
    end
end

-- ============================================================================
-- 狂暴闪光效果（Buff 激活时金色闪烁）
-- ============================================================================
local function UpdateBuffFlash(dt)
    if not beast.animModel then return end

    if beast.buffTimer > 0 and beast.hitFlashTimer <= 0 then
        -- 狂暴状态：金色闪烁（频率较快，每0.15秒切换）
        beast.buffFlashAccum = (beast.buffFlashAccum or 0) + dt
        local flash = math.floor(beast.buffFlashAccum / 0.15) % 2 == 0
        local numGeom = beast.animModel:GetNumGeometries()

        if flash then
            local buffMat = CreatePBRMat(
                Color(1.0, 0.85, 0.2, 1.0), 0.3, 0.2,
                Color(1.0, 0.7, 0.0)
            )
            for i = 0, numGeom - 1 do
                beast.animModel:SetMaterial(i, buffMat)
            end
        else
            RestoreOriginalMaterials()
        end
    elseif beast.buffTimer <= 0 and beast.hitFlashTimer <= 0 then
        -- Buff 结束且无受击闪烁时恢复原材质
        if beast.buffFlashAccum and beast.buffFlashAccum > 0 then
            beast.buffFlashAccum = 0
            RestoreOriginalMaterials()
        end
    end
end

-- ============================================================================
-- 主更新
-- ============================================================================
---@param dt number
---@param scene Scene
---@param playerNode Node
---@param player table
---@param enemies table[]|nil
---@param dealDamageFn function
---@param isSafeZoneFn function
function DivineBeast.Update(dt, scene, playerNode, player, enemies, dealDamageFn, isSafeZoneFn)
    if not DivineBeast.IsAlive() or not playerNode then return end
    dt = tonumber(dt)
    if not dt or dt <= 0 or dt ~= dt or dt == math.huge then return end
    DivineBeast.SyncOwnerStats(player)

    ---@type Vector3
    local beastPos = beast.node.position
    local playerPos = playerNode.position
    local playerInSafeZone = type(isSafeZoneFn) == "function" and isSafeZoneFn(playerPos) or false
    local beastInSafeZone = type(isSafeZoneFn) == "function" and isSafeZoneFn(beastPos) or false
    local combatAllowed = not playerInSafeZone and not beastInSafeZone

    -- 安全区允许神兽存在与跟随，但必须立即停止喷火、索敌和攻击。
    -- 玩家离开后，神兽先跟出安全区，下一帧才恢复战斗。
    if not combatAllowed and fireBreath.active then
        ResetFireBreath()
    end

    -- Buff 衰减
    if beast.buffTimer > 0 then
        beast.buffTimer = beast.buffTimer - dt
        if beast.buffTimer <= 0 then
            beast.buffMult = 1.0
            beast.atk = beast.baseAtk
            beast.attackCD = beast.baseAttackCD or 2.0
        end
    end

    -- 受击闪烁
    UpdateHitFlash(dt)

    -- 狂暴闪光
    UpdateBuffFlash(dt)

    -- 攻击计时
    beast.attackTimer = math.max(0, beast.attackTimer - dt)

    local rbody = beast.node:GetComponent("RigidBody")

    -- AI: 找最近敌人
    local nearestEnemy = nil
    local nearDist = beast.chaseRange
    if combatAllowed and enemies then
        for _, e in ipairs(enemies) do
            local enemyInSafeZone = type(isSafeZoneFn) == "function"
                and e.node and isSafeZoneFn(e.node.position)
            if e.node and e.state ~= "dead" and e.state ~= "dying" and not enemyInSafeZone then
                ---@type Vector3
                local enemyPos = e.node.position
                local d = (enemyPos - beastPos):Length()
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

        -- 跟随逻辑：使用滞回（hysteresis）避免频繁启停
        -- 开始跟随距离 2.5m，停下距离 1.5m（有0.5m死区防止抖动）
        local startFollowDist = 2.5
        local stopFollowDist = 1.5

        if distToPlayer > startFollowDist or (beast.isMoving and distToPlayer > stopFollowDist) then
            beast.isMoving = true
            local dir = toPlayer:Normalized()
            -- 跟随速度匹配主角：距离越远速度越快（确保能跟上）
            local followSpeed = beast.speed
            if distToPlayer > 6.0 then
                followSpeed = beast.speed * 1.8  -- 距离远时快速追赶
            elseif distToPlayer > 4.0 then
                followSpeed = beast.speed * 1.4
            end
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
    if combatAllowed then
        UpdateFireBreathVisual(dt)
        UpdateFireBreathDamage(dt, enemies, player, dealDamageFn)
    end
end

-- ============================================================================
-- 清理（重置状态）
-- ============================================================================
function DivineBeast.Clear()
    -- 这是角色会话级清理：实体和瞬时状态之外，长期成长也一并重置。
    ClearBeastEntity()
    ResetBeastGrowth()
end

-- ============================================================================
-- 获取节点位置（供 UI 使用）
-- ============================================================================
---@return Vector3|nil
function DivineBeast.GetPosition()
    if DivineBeast.IsAlive() then
        return beast.node.position
    end
    return nil
end

return DivineBeast
