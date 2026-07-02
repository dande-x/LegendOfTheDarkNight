---@diagnostic disable: access-invisible
-- ============================================================================
-- Combat.lua — 传奇·山海 战斗系统 + 敌人 AI
-- 伤害计算 / 技能释放 / 弹道投射 / 敌人生成巡逻追击
-- ============================================================================

local CharacterClass = require("scripts.CharacterClass")
local MonsterSkeleton = require("scripts.MonsterSkeleton")
local DivineBeast = require("scripts.DivineBeast")

local Combat = {}

local C = CharacterClass.Colors
local SKILL_TYPE = CharacterClass.SKILL_TYPE

-- ============================================================================
-- 身位 / 近战触及 常量（可调参数 — 用于体验调试）
-- ============================================================================
-- 一个"身位"约等于一个角色占地。相邻=1身位、中间空一格=2身位。
local UNIT              = 1.2   -- 一个身位(米)
local MELEE_REACH       = 1.5   -- 基本剑术触及(挨着, 约1身位): 中心距≤此值才算近身命中
local ASSASSIN_REACH    = 3.0   -- 刺杀剑术(被动)延伸触及(跨一个身位, 约2身位)
local ASSASSIN_FACE_DOT = 0.3   -- 刺杀触发的正前方判定(cos阈值, 约±72°)
local ASSASSIN_ATK_BONUS = 1.15 -- 刺杀触发: 攻击力略微增强(+15%)
local ASSASSIN_ARMOR_PEN = 0.7  -- 刺杀触发: 大幅穿透防御(忽略70%防御)
local TARGET_FRONT_DOT  = 0.45  -- 玩家主动攻击优先目标的正前方判定(cos阈值, 约±63°)
Combat.UNIT = UNIT
Combat.MELEE_REACH = MELEE_REACH
Combat.ASSASSIN_REACH = ASSASSIN_REACH
Combat.TARGET_FRONT_DOT = TARGET_FRONT_DOT

-- ============================================================================
-- 野蛮冲撞 · 冲刺参数（非瞬移，逐帧推进 + 顶推怪物）
-- ============================================================================
-- 顶推检测示意（dir = 冲刺方向）：
--                    ┌─ 侧向容差 ±DASH_PUSH_WIDTH
--   玩家P ●━━━━━━━━━━▶  沿 dir 方向 [−0.3, DASH_PUSH_REACH] 内的怪 → 卷入顶推
--                    └─
--   卷入后每帧定位：E.pos = P.pos + dir*DASH_CONTACT + 侧向偏移（焊在玩家身前）
--   冲刺终点顶出：  E.pos = P.终点 + dir*DASH_EJECT_DIST + 侧向偏移，并施加 DASH_STUN 硬直
local DASH_SPEED       = 18.0           -- 冲刺速度(米/秒)，约 0.28s 冲完 5 米
local DASH_CONTACT     = 1.0            -- 顶推过程中怪物保持在玩家前方的距离(米)
local DASH_PUSH_REACH  = 1.4            -- 玩家正前方多远内的怪会被卷入顶推(米)
local DASH_PUSH_WIDTH  = 0.9            -- 顶推侧向容差(米)，超出则不卷入
local DASH_EJECT_DIST  = ASSASSIN_REACH - 0.3 -- 终点前向顶出距离(2.7m)；含侧向偏移后总距≤ASSASSIN_REACH，确保刺杀被动可触发
local DASH_STUN        = 1.0            -- 被顶出后的硬直时间(秒)

-- 冲刺运行时状态（单玩家，全局唯一）
local dashState = {
    active = false,
    dir = nil,        ---@type Vector3|nil 冲刺方向(水平,归一化)
    remaining = 0,    -- 剩余冲刺距离(米)
    pushed = {},      -- [enemy] = lateralVec(Vector3 侧向偏移)，被顶着的怪
}

-- ============================================================================
-- 敌人配置（普通怪+精英怪+Boss 覆盖 1~50级）
-- hp/atk/def 为基础值，实际生成时按等级缩放
-- tier: "normal"=普通, "elite"=精英(黄名), "boss"=Boss(红名)
-- ============================================================================
local ENEMY_DEFS = {
    -- === 低级区 1~10 ===
    {
        name = "幽灵鹿", monsterType = "deer",
        level = 1,  hp = 90,   atk = 8,  def = 3,
        speed = 3.0, chaseRange = 8, attackRange = 1.5, attackCD = 2.0,
        faceYawOffset = 0,
        exp = 30, scale = 0.9, tier = "normal",
    },
    {
        name = "机械人形", monsterType = "mech_humanoid",
        level = 3, hp = 180, atk = 16, def = 8,
        speed = 2.4, chaseRange = 10, attackRange = 1.65, attackCD = 1.9,
        exp = 62, scale = 1.0, tier = "normal",
    },
    {
        name = "稻草人", monsterType = "scarecrow",
        level = 2,  hp = 110,  atk = 10, def = 4,
        speed = 2.2, chaseRange = 7, attackRange = 1.5, attackCD = 1.8,
        exp = 40, scale = 1.0, tier = "normal",
    },
    {
        name = "骷髅",   monsterType = "skeleton",
        level = 4,  hp = 135,  atk = 14, def = 5,
        speed = 2.6, chaseRange = 10, attackRange = 1.5, attackCD = 1.5,
        exp = 55, scale = 0.95, tier = "normal",
    },
    {
        name = "蜘蛛",   monsterType = "spider",
        level = 6,  hp = 120,  atk = 16, def = 4,
        speed = 3.5, chaseRange = 12, attackRange = 1.5, attackCD = 1.2,
        exp = 65, scale = 0.85, tier = "normal",
    },
    {
        name = "半兽人", monsterType = "orc",
        level = 8,  hp = 210,  atk = 20, def = 8,
        speed = 2.0, chaseRange = 8, attackRange = 1.5, attackCD = 2.2,
        exp = 90, scale = 1.1, tier = "normal",
    },
    -- === 中级区 10~25 ===
    {
        name = "狼人",   monsterType = "orc",
        level = 10, hp = 260,  atk = 24, def = 10,
        speed = 3.2, chaseRange = 12, attackRange = 1.5, attackCD = 1.5,
        exp = 120, scale = 1.0, tier = "normal",
    },
    {
        name = "石魔",   monsterType = "golem",
        level = 14, hp = 400,  atk = 28, def = 16,
        speed = 1.6, chaseRange = 8, attackRange = 1.5, attackCD = 2.5,
        exp = 180, scale = 1.6, tier = "normal",
    },
    {
        name = "暗影蛛后", monsterType = "spider",
        level = 18, hp = 320,  atk = 32, def = 10,
        speed = 3.8, chaseRange = 14, attackRange = 1.5, attackCD = 1.0,
        exp = 220, scale = 1.3, tier = "elite",
    },
    {
        name = "骷髅将军", monsterType = "skeleton",
        level = 22, hp = 500,  atk = 38, def = 14,
        speed = 2.4, chaseRange = 12, attackRange = 1.5, attackCD = 1.8,
        exp = 300, scale = 1.3, tier = "elite",
    },
    -- === 高级区 25~40 ===
    {
        name = "赤焰魔", monsterType = "golem",
        level = 28, hp = 750,  atk = 45, def = 20,
        speed = 2.0, chaseRange = 10, attackRange = 1.5, attackCD = 2.0,
        exp = 450, scale = 1.8, tier = "elite",
    },
    {
        name = "巨蟒",   monsterType = "serpent",
        level = 32, hp = 950,  atk = 50, def = 18,
        speed = 2.8, chaseRange = 14, attackRange = 1.5, attackCD = 1.8,
        exp = 550, scale = 2.0, tier = "elite",
    },
    {
        name = "噬魂兽", monsterType = "orc",
        level = 36, hp = 1100, atk = 55, def = 22,
        speed = 2.5, chaseRange = 12, attackRange = 1.5, attackCD = 1.5,
        exp = 700, scale = 1.5, tier = "elite",
    },
    {
        name = "麒麟", monsterType = "qilin",
        level = 38, hp = 1350, atk = 62, def = 24,
        speed = 2.6, chaseRange = 14, attackRange = 1.8, attackCD = 1.8,
        exp = 850, scale = 1.4, tier = "elite",
    },
    -- === Boss 区 (大型压迫感怪物) ===
    {
        name = "山岳巨人", monsterType = "golem",
        level = 15, hp = 1600, atk = 35, def = 22,
        speed = 1.2, chaseRange = 10, attackRange = 1.5, attackCD = 3.0,
        exp = 600, scale = 2.5, tier = "boss",
    },
    {
        name = "九幽骨龙", monsterType = "serpent",
        level = 30, hp = 3200, atk = 60, def = 26,
        speed = 2.2, chaseRange = 16, attackRange = 1.5, attackCD = 2.0,
        exp = 1500, scale = 2.8, tier = "boss",
    },
    {
        name = "炎魔领主", monsterType = "golem",
        level = 45, hp = 5000, atk = 80, def = 32,
        speed = 1.8, chaseRange = 14, attackRange = 1.5, attackCD = 2.5,
        exp = 3000, scale = 3.0, tier = "boss",
    },
}
Combat.ENEMY_DEFS = ENEMY_DEFS

-- ============================================================================
-- 运行时状态
-- ============================================================================
local enemies = {}       -- 活着的敌人列表
local projectiles = {}   -- 弹道列表
local aoeZones = {}      -- 范围持续伤害区域 (火墙等)
local summons = {}        -- 召唤兽列表
local groundItems = {}   -- 地面掉落物 {node, type="gold"/"item", amount, item, timer, magnetPhase, vel}
---@type table|nil
local lastPlayerTarget = nil -- 玩家上次主动攻击命中的怪物，用于无正前方目标时保持目标连续性
local IsEnemyTargetable, HorizontalDir, NormalizeHorizontal, RememberPlayerTarget, IsLastPlayerTargetValid, FacePlayerToTarget
local killCount = 0
local spawnTimer = 0
local SPAWN_INTERVAL = 0.45
local MAX_ENEMIES = 70
local ENEMY_MOVE_SPEED = 2.8

Combat.enemies = enemies
Combat.projectiles = projectiles
Combat.killCount = 0

IsEnemyTargetable = function(enemy)
    return enemy and enemy.node and enemy.state ~= "dead" and enemy.state ~= "dying" and enemy.hp and enemy.hp > 0
end

HorizontalDir = function(fromPos, toPos)
    local dir = toPos - fromPos
    dir.y = 0
    local len = dir:Length()
    if len <= 0.001 then return nil, len end
    return dir:Normalized(), len
end

NormalizeHorizontal = function(dir)
    local flat = Vector3(dir.x, 0, dir.z)
    if flat:Length() <= 0.001 then return Vector3.FORWARD end
    return flat:Normalized()
end

RememberPlayerTarget = function(enemy)
    if IsEnemyTargetable(enemy) then
        lastPlayerTarget = enemy
    end
end

IsLastPlayerTargetValid = function(pos, maxRange)
    if not IsEnemyTargetable(lastPlayerTarget) then
        lastPlayerTarget = nil
        return false
    end
    if maxRange then
        local toTarget = lastPlayerTarget.node.position - pos
        toTarget.y = 0
        if toTarget:Length() > maxRange then
            return false
        end
    end
    return true
end

FacePlayerToTarget = function(playerNode, playerPos, target)
    if not playerNode or not target then return end
    local dir = target.node.position - playerPos
    dir.y = 0
    if dir:Length() <= 0.1 then return end
    dir = dir:Normalized()
    playerNode.rotation = Quaternion(math.deg(math.atan2(dir.x, dir.z)), Vector3.UP)
end

function Combat.FindPriorityEnemy(pos, forward, maxRange)
    local fwd = NormalizeHorizontal(forward)
    local nearest = nil
    local nearestDist = maxRange or 999
    local frontNearest = nil
    local frontNearestDist = maxRange or 999

    for _, e in ipairs(enemies) do
        if IsEnemyTargetable(e) then
            local dir, d = HorizontalDir(pos, e.node.position)
            if dir and d <= nearestDist then
                nearest = e
                nearestDist = d
            end
            if dir and d <= frontNearestDist and fwd:DotProduct(dir) >= TARGET_FRONT_DOT then
                frontNearest = e
                frontNearestDist = d
            end
        end
    end

    if frontNearest then return frontNearest, frontNearestDist, "front" end
    if IsLastPlayerTargetValid(pos, maxRange) then
        local toLast = lastPlayerTarget.node.position - pos
        toLast.y = 0
        return lastPlayerTarget, toLast:Length(), "last"
    end
    return nearest, nearestDist, nearest and "nearest" or "none"
end

-- 地面掉落常量
local GOLD_MAGNET_DELAY = 0.6    -- 金币落地后多久开始吸附(秒)
local GOLD_MAGNET_ACCEL = 25.0   -- 吸附加速度
local GOLD_MAGNET_MAX_SPEED = 18.0
local GOLD_PICKUP_DIST = 0.5     -- 拾取判定距离
local ITEM_PICKUP_DIST = 2.0     -- 装备拾取距离
local ITEM_LIFETIME = 60.0       -- 装备存在时间(秒)
local GOLD_LIFETIME = 30.0       -- 金币存在时间(秒)

-- ============================================================================
-- PBR 材质快捷创建
-- ============================================================================
local function CreatePBR(color, metallic, roughness)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("MatSpecColor", Variant(Color(0.3, 0.3, 0.3, 1.0)))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.6))
    return mat
end

-- ============================================================================
-- 中毒绿色效果辅助函数
-- ============================================================================
local function ApplyPoisonTint(enemy)
    if enemy.poisonTinted then return end
    enemy.poisonTinted = true
    enemy.poisonOrigMats = {}

    local poisonMat = CreatePBR(Color(0.08, 0.85, 0.18, 1.0), 0.0, 0.45)
    poisonMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.1, 1.2, 0.25, 1.0)))

    local function TintModels(node)
        local model = node:GetComponent("StaticModel")
        if model then
            table.insert(enemy.poisonOrigMats, { model = model, mat = model:GetMaterial(0) })
            model:SetMaterial(poisonMat)
        end
        local count = node:GetNumChildren(false)
        for i = 0, count - 1 do
            TintModels(node:GetChild(i))
        end
    end

    local skelRoot = enemy.node:GetChild("SkelRoot", false)
    if skelRoot then
        TintModels(skelRoot)
        enemy.poisonOrigScale = skelRoot.scale
        skelRoot.scale = skelRoot.scale * 1.08
    else
        TintModels(enemy.node)
    end

    if #enemy.poisonOrigMats == 0 then
        print("[Combat] Poison tint warning: no StaticModel found on " .. tostring(enemy.name))
    end
end

local function RemovePoisonTint(enemy)
    if not enemy.poisonTinted then return end
    enemy.poisonTinted = false
    if enemy.poisonOrigMats then
        for _, entry in ipairs(enemy.poisonOrigMats) do
            if entry.model then
                entry.model:SetMaterial(entry.mat)
            end
        end
        enemy.poisonOrigMats = nil
    end
    -- 恢复缩放
    if enemy.poisonOrigScale then
        local skelRoot = enemy.node:GetChild("SkelRoot", false)
        if skelRoot then
            skelRoot.scale = enemy.poisonOrigScale
        end
        enemy.poisonOrigScale = nil
    end
    enemy.poisonFlashAccum = nil
end

-- ============================================================================
-- 等级缩放系数：怪物属性随等级线性增长
-- 设计目标：玩家用普攻需要 4~6 下杀同级普通怪, 技能 2~3 下
-- ============================================================================
local LEVEL_SCALE = {
    hp_per_level  = 15,   -- 每级额外 HP
    atk_per_level = 3,    -- 每级额外 ATK
    def_per_level = 1,    -- 每级额外 DEF
    exp_per_level = 8,    -- 每级额外 EXP
}

-- Boss/精英 加成倍率
local TIER_MULT = {
    normal = { hp = 1.0, atk = 1.0, def = 1.0, exp = 1.0 },
    elite  = { hp = 2.0, atk = 1.5, def = 1.3, exp = 2.5 },
    boss   = { hp = 5.0, atk = 2.0, def = 2.0, exp = 5.0 },
}

-- ============================================================================
-- 敌人创建（使用 MonsterSkeleton 骨架系统）
-- ============================================================================
function Combat.SpawnEnemy(scene, playerPos, playerLevel, forceDef)
    if #enemies >= MAX_ENEMIES then return end

    local def
    if forceDef then
        def = forceDef
    else
        -- 根据玩家等级选取合适的普通/精英怪（Boss 由专门机制刷新）
        local validDefs = {}
        for _, d in ipairs(ENEMY_DEFS) do
            if d.tier ~= "boss" and d.level <= playerLevel + 4 and d.level >= playerLevel - 5 then
                table.insert(validDefs, d)
            end
        end
        -- 如果没有合适的，取最接近玩家等级的非Boss怪
        if #validDefs == 0 then
            for _, d in ipairs(ENEMY_DEFS) do
                if d.tier ~= "boss" and d.level <= playerLevel + 8 then
                    table.insert(validDefs, d)
                end
            end
        end
        if #validDefs == 0 then validDefs = {ENEMY_DEFS[1]} end

        -- 加权随机：等级越接近玩家越容易出现
        local weights = {}
        local totalWeight = 0
        for i, d in ipairs(validDefs) do
            local diff = math.abs(d.level - playerLevel)
            local w = math.max(1, 10 - diff)  -- 等级差越小权重越高
            -- 精英怪权重降低（出现概率较低）
            if d.tier == "elite" then w = w * 0.3 end
            weights[i] = w
            totalWeight = totalWeight + w
        end
        local roll = math.random() * totalWeight
        local acc = 0
        def = validDefs[1]
        for i, d in ipairs(validDefs) do
            acc = acc + weights[i]
            if roll <= acc then
                def = d
                break
            end
        end
    end

    -- 等级缩放：怪物实际等级 = 定义等级 ± 浮动（普通怪浮动 ±2）
    local actualLevel = def.level
    if def.tier == "normal" then
        actualLevel = math.max(1, def.level + math.random(-2, 2))
        -- 让怪物等级接近玩家等级
        actualLevel = math.max(1, math.min(actualLevel, playerLevel + 3))
    end

    local tierMult = TIER_MULT[def.tier or "normal"] or TIER_MULT.normal
    local levelDiff = actualLevel - def.level
    local scaledHP  = math.floor((def.hp + levelDiff * LEVEL_SCALE.hp_per_level) * tierMult.hp)
    local scaledATK = math.floor((def.atk + levelDiff * LEVEL_SCALE.atk_per_level) * tierMult.atk)
    local scaledDEF = math.floor((def.def + levelDiff * LEVEL_SCALE.def_per_level) * tierMult.def)
    local scaledEXP = math.floor((def.exp + levelDiff * LEVEL_SCALE.exp_per_level) * tierMult.exp)

    -- 在玩家周围 15-25 米随机位置生成
    local angle = math.random() * math.pi * 2
    local dist = 15 + math.random() * 10
    local spawnPos = Vector3(
        playerPos.x + math.cos(angle) * dist,
        0,
        playerPos.z + math.sin(angle) * dist
    )

    -- 创建敌人节点
    local enemyNode = scene:CreateChild("Enemy_" .. def.monsterType)
    enemyNode.position = spawnPos

    -- 骨架容器节点（用于统一缩放）
    local skelRoot = enemyNode:CreateChild("SkelRoot")
    skelRoot.scale = Vector3(def.scale, def.scale, def.scale)

    -- 使用 MonsterSkeleton 创建程序化骨架
    local bones, buildOrder, visual = MonsterSkeleton.CreateSkeleton(skelRoot, def.monsterType)

    -- 敌人动态碰撞体
    local rbody = enemyNode:CreateComponent("RigidBody")
    rbody.mass = 1.0
    rbody.collisionLayer = 4          -- AI 层
    rbody.collisionMask = 1 | 2 | 4   -- 与地形(1)、玩家(2)、其他AI(4)碰撞
    rbody.angularFactor = Vector3(0, 0, 0)
    rbody.linearFactor = Vector3(1, 0, 1)   -- 锁定 Y 轴
    rbody.friction = 0.5
    rbody.linearDamping = 0.1
    local colShape = enemyNode:CreateComponent("CollisionShape")
    local capsuleH = 1.2 * def.scale
    local capsuleD = 0.6 * def.scale
    colShape:SetCapsule(capsuleD, capsuleH, Vector3(0, capsuleH * 0.5, 0))

    -- 名字标签已移至 GameUI 的 NanoVG 屏幕空间渲染（和血条统一）

    -- 动画数据
    local animData = {
        type = def.monsterType,
        state = "idle",
        elapsed = 0,
        bones = bones,
        buildOrder = buildOrder,
        visual = visual,
        onComplete = nil,
    }

    local enemy = {
        node = enemyNode,
        name = def.name,
        monsterType = def.monsterType,
        level = actualLevel,
        tier = def.tier or "normal",
        maxHP = scaledHP,
        hp = scaledHP,
        atk = scaledATK,
        def = scaledDEF,
        speed = def.speed or ENEMY_MOVE_SPEED,
        chaseRange = def.chaseRange,
        attackRange = def.attackRange,
        attackCD = def.attackCD,
        faceYawOffset = def.faceYawOffset or 0,
        attackTimer = 0,
        exp = scaledEXP,
        state = "patrol",  -- patrol / chase / attack / dead / dying
        patrolTarget = nil,
        patrolWait = 0,
        hitFlashTimer = 0,
        hitStunTimer = 0,   -- 受击硬直时间
        defReduction = 0,  -- 施毒术减防
        defReductionTimer = 0,
        dotDamage = 0,
        dotTimer = 0,
        dotTickInterval = 0.5,
        dotTickAccum = 0,
        animData = animData,
        dyingTimer = 0,
    }

    table.insert(enemies, enemy)
    return enemy
end

-- ============================================================================
-- 敌人死亡处理（统一入口，避免重复触发）
-- ============================================================================
function Combat.TriggerDeath(enemy, player)
    if enemy.state == "dying" or enemy.state == "dead" then return end

    if lastPlayerTarget == enemy then
        lastPlayerTarget = nil
    end

    enemy.state = "dying"
    enemy.hp = 0
    local deathDur = MonsterSkeleton.GetAnimDuration(enemy.monsterType, "death")
    enemy.dyingTimer = deathDur
    -- 停止物理移动
    local eBody = enemy.node:GetComponent("RigidBody")
    if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
    -- 播放死亡动画
    if enemy.animData then
        MonsterSkeleton.PlayAnim(enemy.animData, "death", nil)
    end
    -- 立即触发掉落和经验
    killCount = killCount + 1
    Combat.killCount = killCount
    if player then
        player.exp = player.exp + enemy.exp
        while player.exp >= player.expToNext do
            player.exp = player.exp - player.expToNext
            local newSkills = CharacterClass.LevelUp(player)
            if newSkills and Combat.onSkillUnlocked then
                for _, name in ipairs(newSkills) do
                    Combat.onSkillUnlocked(name)
                end
            end
        end
    end
    -- 神兽也获得经验
    DivineBeast.AddExp(enemy.exp)
    if Combat.onEnemyDeath then
        Combat.onEnemyDeath(enemy.name, enemy.node.position, enemy.exp)
    end
end

local function FaceEnemyDir(enemy, dir)
    if not enemy or not enemy.node or not dir then return end

    dir.y = 0
    if dir:Length() <= 0.001 then return end

    dir = dir:Normalized()
    local angle = math.atan2(dir.x, dir.z)
    local rotation = Quaternion(math.deg(angle) + (enemy.faceYawOffset or 0), Vector3.UP)
    local body = enemy.node:GetComponent("RigidBody")
    if body then
        body:SetRotation(rotation)
    end
    enemy.node.rotation = rotation
end

local function FaceEnemyTarget(enemy, targetPos)
    if not enemy or not targetPos then return end
    FaceEnemyDir(enemy, targetPos - enemy.node.position)
end

-- ============================================================================
-- 敌人 AI 更新
-- ============================================================================
function Combat.UpdateEnemies(dt, playerNode, player)
    if not playerNode then return end
    local playerPos = playerNode.position

    for i = #enemies, 1, -1 do
        local e = enemies[i]
        if e.state == "dead" then goto continue end

        -- 死亡动画播放中
        if e.state == "dying" then
            e.dyingTimer = e.dyingTimer - dt
            -- 更新死亡动画
            if e.animData then
                MonsterSkeleton.UpdateAnimation(e.animData, dt, false)
            end
            if e.dyingTimer <= 0 then
                e.state = "dead"
                e.node:Remove()
                table.remove(enemies, i)
            end
            goto continue
        end

        local pos = e.node.position
        local toPlayer = playerPos - pos
        toPlayer.y = 0
        local dist = toPlayer:Length()

        -- DOT 伤害 (施毒术)：每 0.5 秒结算一次
        if e.dotTimer > 0 then
            e.dotTimer = e.dotTimer - dt
            e.dotTickAccum = (e.dotTickAccum or 0) + dt
            local tickInterval = e.dotTickInterval or 0.5
            while e.dotTickAccum >= tickInterval and e.dotTimer > 0 do
                e.dotTickAccum = e.dotTickAccum - tickInterval
                e.hp = e.hp - e.dotDamage * tickInterval
                e.hitFlashTimer = 0.1
            end
            if e.dotTimer <= 0 then
                e.dotDamage = 0
                e.dotTickAccum = 0
                -- 中毒结束，移除绿色效果
                RemovePoisonTint(e)
            end
        end

        -- 减防衰减
        if e.defReductionTimer > 0 then
            e.defReductionTimer = e.defReductionTimer - dt
            if e.defReductionTimer <= 0 then
                e.defReduction = 0
            end
        end

        -- 受击闪烁
        if e.hitFlashTimer > 0 then
            e.hitFlashTimer = e.hitFlashTimer - dt
        end

        -- 困魔咒：计时器衰减
        if e.trapTimer and e.trapTimer > 0 then
            e.trapTimer = e.trapTimer - dt
            if e.trapTimer <= 0 then
                e.trapTimer = nil
                e.trapCenter = nil
                e.trapRadius = nil
                e.trapDefReduced = nil
            end
        end

        -- 死亡检测（调用统一死亡函数）
        if e.hp <= 0 then
            Combat.TriggerDeath(e, player)
            goto continue
        end

        -- 状态机
        e.attackTimer = math.max(0, e.attackTimer - dt)

        local eBody = e.node:GetComponent("RigidBody")
        local isMoving = false
        local moveAnimName = "run"

        -- 抗拒火环击退：被推开期间强制水平位移，跳过正常 AI（避免速度被状态机覆盖）
        if (e.knockbackTimer or 0) > 0 then
            e.knockbackTimer = e.knockbackTimer - dt
            if eBody and e.knockbackDir then
                local v = e.knockbackDir * (e.knockbackSpeed or 14)
                -- 保留竖直速度（重力/起跳），仅覆盖水平推开
                local cur = eBody:GetLinearVelocity()
                eBody:SetLinearVelocity(Vector3(v.x, cur.y, v.z))
            end
            if e.animData then
                MonsterSkeleton.UpdateAnimation(e.animData, dt, true, "run")
            end
            goto continue
        end

        -- 受击硬直：暂停移动，只播放动画
        if e.hitStunTimer > 0 then
            e.hitStunTimer = e.hitStunTimer - dt
            if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            if e.animData then
                MonsterSkeleton.UpdateAnimation(e.animData, dt, false)
            end
            goto continue
        end

        if e.state == "patrol" then
            -- 巡逻：发现玩家或神兽时追击
            local beastPos = DivineBeast.GetPosition()
            local beastDist = beastPos and (beastPos - pos):Length() or 9999
            if dist < e.chaseRange or beastDist < e.chaseRange then
                e.state = "chase"
            else
                if not e.patrolTarget or e.patrolWait <= 0 then
                    local rx = pos.x + (math.random() - 0.5) * 8
                    local rz = pos.z + (math.random() - 0.5) * 8
                    e.patrolTarget = Vector3(rx, 0, rz)
                    e.patrolWait = 3 + math.random() * 3
                end
                e.patrolWait = e.patrolWait - dt
                local dir = e.patrolTarget - pos
                dir.y = 0
                if dir:Length() > 0.5 then
                    dir = dir:Normalized()
                    if eBody then
                        eBody:SetLinearVelocity(dir * e.speed * 0.5)
                    end
                    FaceEnemyDir(e, dir)
                    isMoving = true
                    moveAnimName = "walk"
                else
                    if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
                end
            end

        elseif e.state == "chase" then
            -- 追击玩家或神兽（谁近追谁）
            local chaseBeastPos = DivineBeast.GetPosition()
            local chaseBeastDist = chaseBeastPos and (chaseBeastPos - pos):Length() or 9999
            local chaseTargetPos = playerPos
            local chaseTargetDist = dist
            if chaseBeastDist < chaseTargetDist then
                chaseTargetPos = chaseBeastPos
                chaseTargetDist = chaseBeastDist
            end

            if chaseTargetDist > e.chaseRange * 1.5 then
                e.state = "patrol"
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            elseif chaseTargetDist <= e.attackRange then
                e.state = "attack"
                FaceEnemyTarget(e, chaseTargetPos)
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            else
                local dir = (chaseTargetPos - pos)
                dir.y = 0
                dir = dir:Normalized()
                if eBody then
                    eBody:SetLinearVelocity(dir * e.speed)
                end
                FaceEnemyDir(e, dir)
                isMoving = true
                moveAnimName = "run"
            end

        elseif e.state == "attack" then
            -- 攻击玩家或神兽（站定攻击）
            if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end

            -- 判断攻击目标：优先攻击更近的（玩家或神兽）
            local attackTarget = "player"
            local attackDist = dist
            local beastPos = DivineBeast.GetPosition()
            if beastPos then
                local toBeast = (beastPos - pos):Length()
                if toBeast < attackDist then
                    attackTarget = "beast"
                    attackDist = toBeast
                end
            end

            if attackDist > e.attackRange * 1.5 then
                e.state = "chase"
            else
                -- 面向目标
                local targetPos = attackTarget == "beast" and beastPos or playerPos
                FaceEnemyTarget(e, targetPos)

                if e.attackTimer <= 0 then
                    -- 播放攻击动画
                    if e.animData then
                        MonsterSkeleton.PlayAnim(e.animData, "attack", nil)
                    end

                    if attackTarget == "beast" then
                        -- 攻击神兽
                        local dmg = math.max(1, e.atk)
                        local actualDmg = DivineBeast.TakeDamage(dmg)
                        e.attackTimer = e.attackCD
                    else
                        -- 攻击玩家
                        local dmg = math.max(1, e.atk - player.def * 0.5)
                        -- 护盾吸收
                        if player.shieldHP > 0 then
                            local absorbed = math.min(player.shieldHP, dmg)
                            player.shieldHP = player.shieldHP - absorbed
                            dmg = dmg - absorbed
                        end
                        player.hp = math.max(0, player.hp - dmg)
                        e.attackTimer = e.attackCD

                        if Combat.onEnemyAttack then
                            Combat.onEnemyAttack(e, dmg, playerPos)
                        end
                    end
                end
            end
        end

        -- 困魔咒：位置约束（被困住的怪物无法离开圆形区域）
        if e.trapCenter and e.trapRadius then
            local ePos = e.node.position
            local toCenter = ePos - e.trapCenter
            toCenter.y = 0
            local distFromCenter = toCenter:Length()
            if distFromCenter > e.trapRadius * 0.9 then
                -- 拉回到边界内
                local clampDir = toCenter:Normalized()
                local clampedPos = e.trapCenter + clampDir * (e.trapRadius * 0.85)
                clampedPos.y = ePos.y
                e.node.position = clampedPos
                -- 清除速度防止继续外移
                local eBody = e.node:GetComponent("RigidBody")
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            end
        end

        -- 更新骨架动画
        if e.animData then
            MonsterSkeleton.UpdateAnimation(e.animData, dt, isMoving, moveAnimName)
        end

        ::continue::
    end
end

-- ============================================================================
-- 技能释放
-- ============================================================================
function Combat.CastSkill(scene, player, playerNode, skillSlot)
    local skill = player.equippedSkills[skillSlot]
    if not skill then return false, "无技能" end

    local canCast, reason = CharacterClass.CanCastSkill(player, skill)
    if not canCast then return false, reason end

    -- 消耗 MP，触发 CD
    player.mp = player.mp - skill.manaCost
    player.cooldowns[skill.id] = skill.cooldown

    local playerPos = playerNode.position
    local playerDir = playerNode:GetDirection()  -- 前方方向

    -- 玩家主动攻击统一选目标：正前方最近 → 上次命中目标 → 最近目标
    local target = Combat.FindPriorityEnemy(playerPos, playerDir, skill.range or 5)
    if target and skill.type ~= SKILL_TYPE.BUFF and skill.type ~= SKILL_TYPE.HEAL and skill.type ~= SKILL_TYPE.SUMMON
        and not skill.isKnockback then
        FacePlayerToTarget(playerNode, playerPos, target)
        playerDir = playerNode:GetDirection()
    end

    if skill.type == SKILL_TYPE.MELEE then
        -- 近战：ATK × 倍率百分比
        local dmg = player.atk * (skill.damage / 100)
        local hitCount = 0
        if skill.aoeAngle then
            for _, e in ipairs(enemies) do
                if IsEnemyTargetable(e) then
                    local d = (e.node.position - playerPos):Length()
                    if d <= skill.range then
                        -- 半月弯刀：检查角度，仅命中前方半月范围
                        local toEnemy = e.node.position - playerPos
                        toEnemy.y = 0
                        toEnemy = toEnemy:Normalized()
                        local fwd = playerDir
                        fwd.y = 0
                        fwd = fwd:Normalized()
                        local dot = fwd:DotProduct(toEnemy)
                        local angleToEnemy = math.deg(math.acos(math.max(-1, math.min(1, dot))))
                        if angleToEnemy <= skill.aoeAngle * 0.5 then
                            Combat.DealDamage(e, dmg, player)
                            hitCount = hitCount + 1
                        end
                    end
                end
            end
        elseif target then
            Combat.DealDamage(target, dmg, player)
            RememberPlayerTarget(target)
            hitCount = 1
        end

        -- 【刺杀剑术·被动】基本剑术近身落空时，凌空斩出白色剑气，补击"隔一身位"之敌
        -- 触发条件: skill 为基本剑术 + 已解锁 w_thrust + 近身没打到人 + 敌人位于(MELEE_REACH, ASSASSIN_REACH]且身前
        if skill.id == "w_basic" and hitCount == 0 then
            local thrust = CharacterClass.GetUnlockedSkill(player, "w_thrust")
            if thrust then
                local fwd = Vector3(playerDir.x, 0, playerDir.z)
                if fwd:Length() > 0.001 then fwd = fwd:Normalized() end
                -- 在隔身位区间内、身前锥形内，挑最近的一个目标
                local bestE, bestD = nil, ASSASSIN_REACH + 0.001
                for _, e in ipairs(enemies) do
                    if e.state ~= "dead" and e.state ~= "dying" then
                        local toE = e.node.position - playerPos
                        toE.y = 0
                        local d = toE:Length()
                        if d > MELEE_REACH and d <= ASSASSIN_REACH and d < bestD then
                            local edir = toE:Normalized()
                            if fwd:DotProduct(edir) >= ASSASSIN_FACE_DOT then
                                bestE, bestD = e, d
                            end
                        end
                    end
                end
                if bestE then
                    -- 转向目标，沿武器挥砍方向斩出
                    local toE = bestE.node.position - playerPos
                    toE.y = 0
                    local sdir = toE:Normalized()
                    playerNode.rotation = Quaternion(math.deg(math.atan2(sdir.x, sdir.z)), Vector3.UP)
                    -- 攻击力略微增强 + 大幅穿透防御
                    local procDmg = player.atk * (thrust.damage / 100) * ASSASSIN_ATK_BONUS
                    Combat.DealDamage(bestE, procDmg, player, { armorPen = ASSASSIN_ARMOR_PEN })
                    RememberPlayerTarget(bestE)
                    -- 白色剑气特效（沿挥砍方向延伸到隔身位距离）
                    Combat.SpawnAssassinSlashVisual(scene, playerPos, sdir, ASSASSIN_REACH)
                end
            end
        end

        -- 技能专属视觉效果（基本剑术近身命中不再有剑弧特效）
        if hitCount > 0 and target then
            RememberPlayerTarget(target)
        end
        if skill.aoeAngle then
            -- 半月弯刀：前方弧形光斩
            Combat.SpawnCrescentVisual(scene, playerPos, playerDir, skill.range, player.classId)
        elseif skill.id == "w_fire" then
            -- 烈火剑法：焰刃纵斩 + 地面火浪
            Combat.SpawnFireSlashVisual(scene, playerPos, playerDir, skill.range)
        end
        return true, "melee"

    elseif skill.type == SKILL_TYPE.RANGED then
        -- 远程：ATK × 倍率百分比
        local dmg = player.atk * (skill.damage / 100)

        local dir = playerDir
        if target then
            dir = target.node.position - playerPos
            dir.y = 0
            dir = dir:Normalized()
            -- 让角色转向目标
            local angle = math.atan2(dir.x, dir.z)
            playerNode.rotation = Quaternion(math.deg(angle), Vector3.UP)
        end

        -- 雷电术：直接劈下闪电，不发射球体
        if skill.id == "m_thunder" then
            -- 确定落点：有目标则落在目标处，否则落在前方 range 处
            local strikePos
            if target then
                strikePos = target.node.position
                Combat.DealDamage(target, dmg, player)
                RememberPlayerTarget(target)
            else
                strikePos = playerPos + dir * (skill.range or 6)
                -- 对落点范围内的敌人造成伤害
                for _, e in ipairs(enemies) do
                    if e.state ~= "dead" and e.state ~= "dying" then
                        local d = (e.node.position - strikePos):Length()
                        if d <= 1.5 then
                            Combat.DealDamage(e, dmg, player)
                            RememberPlayerTarget(e)
                        end
                    end
                end
            end
            Combat.SpawnThunderStrikeVisual(scene, strikePos)
        else
            Combat.SpawnProjectile(scene, playerPos + Vector3(0, 0.8, 0), dir, dmg, skill, player)
        end
        return true, "ranged"

    elseif skill.type == SKILL_TYPE.AOE then
        -- 抗拒火环：以玩家自身为中心，无直接伤害，纯击退（在伤害计算前拦截）
        if skill.isKnockback then
            local kbRadius = skill.aoeRadius or skill.range or 3.0
            local kbSpeed = skill.knockbackSpeed or 14
            local kbDur = skill.knockbackDuration or 0.4
            for _, e in ipairs(enemies) do
                if e.state ~= "dead" and e.state ~= "dying" then
                    local toE = e.node.position - playerPos
                    toE.y = 0
                    local d = toE:Length()
                    if d <= kbRadius then
                        -- 推开方向：从玩家指向敌人(水平)；若与玩家重叠则随机方向避免归一化 NaN
                        local kbDir
                        if d > 0.01 then
                            kbDir = toE:Normalized()
                        else
                            kbDir = Vector3(math.random() - 0.5, 0, math.random() - 0.5):Normalized()
                        end
                        e.knockbackDir = kbDir
                        e.knockbackSpeed = kbSpeed
                        e.knockbackTimer = kbDur
                        e.hitStunTimer = 0  -- 打断硬直，立即被推开
                    end
                end
            end
            -- 火环视觉（以玩家为中心绽放）
            Combat.SpawnAOEVisual(scene, playerPos, kbRadius, player.classId, skill.id)
            return true, "aoe"
        end

        -- 范围：ATK × 倍率百分比
        local dmg = player.atk * (skill.damage / 100)
        local radius = skill.aoeRadius or skill.range

        -- 如果有目标，以目标为中心；否则以玩家前方为中心
        local center = playerPos
        if target then
            center = target.node.position
            RememberPlayerTarget(target)
        else
            center = playerPos + playerDir * (radius * 0.5)
        end

        -- 困魔咒：群控困敌 + 减防
        if skill.isTrap then
            local trapDur = skill.trapDuration or 6.0
            local defReducePct = skill.trapDefReducePercent or 0
            -- 创建困魔区域（持续存在，区域内敌人无法离开）
            table.insert(aoeZones, {
                center = center,
                radius = radius,
                isTrapZone = true,
                trapDefReducePercent = defReducePct,
                timer = trapDur,
                tickInterval = 0.1,
                tickAccum = 0,
                dps = 0,
                ownerId = "player",
                visualNode = Combat.SpawnAOEVisual(scene, center, radius, player.classId, skill.id),
            })
            -- 立即困住区域内的怪物并施加减防
            for _, e in ipairs(enemies) do
                if e.state ~= "dead" and e.state ~= "dying" then
                    local toE = e.node.position - center
                    toE.y = 0
                    local d = toE:Length()
                    if d <= radius then
                        e.trapCenter = center
                        e.trapRadius = radius
                        e.trapTimer = trapDur
                        -- 百分比减防
                        if defReducePct > 0 then
                            local reduceAmt = math.floor(e.def * defReducePct / 100)
                            e.defReduction = math.max(e.defReduction or 0, reduceAmt)
                            e.defReductionTimer = trapDur
                            e.trapDefReduced = true
                        end
                    end
                end
            end
            return true, "aoe"
        end

        for _, e in ipairs(enemies) do
            if e.state ~= "dead" and e.state ~= "dying" then
                local d = (e.node.position - center):Length()
                if d <= radius then
                    Combat.DealDamage(e, dmg, player)
                end
            end
        end

        -- AOE 视觉效果（按技能ID分化）
        Combat.SpawnAOEVisual(scene, center, radius, player.classId, skill.id)
        return true, "aoe"

    elseif skill.type == SKILL_TYPE.DOT then
        -- 持续伤害 (施毒术 / 火墙)：DPS = ATK × 倍率百分比
        local dps = player.atk * (skill.damage / 100)
        local dur = skill.duration

        if skill.id == "t_poison" then
            -- 施毒术：目标点圆形群体 DOT + 减防
            local radius = skill.aoeRadius or 3.0
            local center = playerPos + playerDir * math.min(skill.range or 6.0, 4.0)
            if target then
                center = target.node.position
                RememberPlayerTarget(target)
            end

            for _, e in ipairs(enemies) do
                if e.state ~= "dead" and e.state ~= "dying" then
                    local toE = e.node.position - center
                    toE.y = 0
                    local d = toE:Length()
                    if d <= radius then
                        e.dotDamage = dps
                        e.dotTimer = dur
                        e.dotTickInterval = 0.5
                        e.dotTickAccum = 0
                        e.defReduction = math.max(e.defReduction or 0, skill.defReduce or 0)
                        e.defReductionTimer = dur
                        e.hitFlashTimer = 0.1
                        if e.state == "patrol" then e.state = "chase" end
                        ApplyPoisonTint(e)
                    end
                end
            end

            Combat.SpawnAOEVisual(scene, center, radius, player.classId, skill.id)

            -- 转向施毒中心
            local dir = center - playerPos
            dir.y = 0
            if dir:Length() > 0.1 then
                dir = dir:Normalized()
                local angle = math.atan2(dir.x, dir.z)
                playerNode.rotation = Quaternion(math.deg(angle), Vector3.UP)
            end
        else
            -- 火墙：长方形范围 DOT，每0.5s出伤一次
            local center = playerPos + playerDir * 4
            if target then
                center = target.node.position
                RememberPlayerTarget(target)
            end
            local radius = skill.aoeRadius or 2.0
            -- 火墙使用长方形区域：宽度=radius*2, 长度=radius*3
            local halfW = radius       -- 半宽
            local halfL = radius * 1.5 -- 半长
            -- 计算火墙朝向（朝向施法方向）
            local wallAngle = math.atan2(playerDir.x, playerDir.z)
            table.insert(aoeZones, {
                center = center,
                radius = radius,
                halfW = halfW,
                halfL = halfL,
                wallAngle = wallAngle,
                isRect = true,
                dps = dps,
                timer = dur,
                tickInterval = 0.5,
                tickAccum = 0,
                ownerId = "player",
                visualNode = Combat.SpawnAOEVisual(scene, center, radius, player.classId, skill.id, wallAngle),
            })
        end
        return true, "dot"

    elseif skill.type == SKILL_TYPE.BUFF then
        local dur = skill.duration
        if skill.buffMultiplier then
            -- 神兽狂暴/万灵强化：提升神兽和召唤兽攻击力
            local mult = skill.buffMultiplier
            -- 增强神兽
            DivineBeast.ApplyBuff(mult, dur)
            -- 增强普通召唤兽
            for _, s in ipairs(summons) do
                s.atk = s.baseAtk * mult
                s.buffTimer = dur
            end
        elseif skill.shieldPercent then
            -- 护盾
            local shieldPct = skill.shieldPercent
            player.shieldHP = player.maxHP * shieldPct / 100
            player.shieldTimer = dur
            -- 护盾视觉效果
            Combat.SpawnShieldVisual(scene, playerNode, skill.id, dur)
        end
        return true, "buff"

    elseif skill.type == SKILL_TYPE.HEAL then
        -- 治疗（同时治疗自己和神兽）
        local healPct = skill.healPercent
        local healAmount = player.maxHP * healPct / 100
        player.hp = math.min(player.maxHP, player.hp + healAmount)
        -- 同时治疗神兽
        if DivineBeast.IsAlive() then
            local info = DivineBeast.GetDisplayInfo()
            if info then
                local beastHeal = info.maxHP * healPct / 100
                DivineBeast.Heal(beastHeal)
            end
        end
        if Combat.onPlayerHeal then
            Combat.onPlayerHeal(healAmount, playerPos)
        end
        return true, "heal"

    elseif skill.type == SKILL_TYPE.DASH then
        -- 野蛮冲撞：冲刺(非瞬移)。逐帧推进，途中顶着前方怪物前进，
        -- 终点将怪物顶出到刺杀剑术最远触及距离并施加硬直。本技能不造成直接伤害。
        local dir = Vector3(playerDir.x, 0, playerDir.z)
        if dir:Length() > 0.001 then
            dir = dir:Normalized()
        else
            dir = Vector3.FORWARD
        end
        -- 有最近敌人则朝敌人冲
        if target then
            local td = target.node.position - playerPos
            td.y = 0
            if td:Length() > 0.001 then
                dir = td:Normalized()
            end
        end
        playerNode.rotation = Quaternion(math.deg(math.atan2(dir.x, dir.z)), Vector3.UP)

        -- 初始化冲刺状态，实际推进由 Combat.UpdateDash 逐帧完成
        dashState.active = true
        dashState.dir = dir
        dashState.remaining = math.min(skill.range, 5.0)
        dashState.pushed = {}
        return true, "dash"

    elseif skill.type == SKILL_TYPE.SUMMON then
        local sType = skill.summonType or "normal"

        if sType == "divineBeast" then
            -- 召唤神兽（永久随从，只能一只）
            local ok = DivineBeast.Summon(scene, playerPos, player.atk)
            if not ok then
                -- 已存在，返还 MP 和 CD
                player.mp = player.mp + skill.manaCost
                player.cooldowns[skill.id] = 0
                return false, "神兽已存在"
            end
            return true, "summon"
        else
            -- 普通召唤兽
            local summonAtk = player.atk * (skill.damage / 100)
            local dur = skill.duration
            local count = skill.summonCount or 1

            for ci = 1, count do
                local offset = Vector3((ci - 1) * 2 - (count - 1), 0, 1.5)
                Combat.SpawnSummon(scene, playerPos + offset, summonAtk, dur, skill.isUltimate, sType)
            end
            return true, "summon"
        end
    end

    return false, "未知技能类型"
end

-- ============================================================================
-- 伤害计算
-- ============================================================================
--- @param opts table|nil 可选: { armorPen = 0~1 穿透比例 }
function Combat.DealDamage(enemy, baseDmg, player, opts)
    if enemy.state == "dying" or enemy.state == "dead" then return end

    local armorPen = (opts and opts.armorPen) or 0  -- 防御穿透比例 0~1
    local rawDef = math.max(0, enemy.def - enemy.defReduction)
    local effectiveDef = rawDef * (1 - armorPen)  -- 穿透后剩余防御
    -- 防御减伤公式: 伤害 = 基础伤害 × (100 / (100 + 防御))
    -- 这样防御永远不会让伤害降到0，且收益递减
    local dmg = baseDmg * (100 / (100 + effectiveDef))
    dmg = math.max(1, math.floor(dmg))

    -- 暴击 (10% 概率, 1.5 倍)
    local isCrit = math.random() < 0.10
    if isCrit then dmg = math.floor(dmg * 1.5) end

    enemy.hp = enemy.hp - dmg
    enemy.hitFlashTimer = 0.15

    -- 播放受击动画 + 短暂硬直（不打断攻击动画，hp>0 时才播放）
    if enemy.hp > 0 and enemy.animData and enemy.animData.state ~= "attack" then
        MonsterSkeleton.PlayAnim(enemy.animData, "hit", nil)
        enemy.hitStunTimer = 0.25  -- 受击硬直，停止移动
    end

    -- hp <= 0 立即标记死亡（不等下一帧检测）
    if enemy.hp <= 0 then
        enemy.hp = 0
        Combat.TriggerDeath(enemy, player)
    end

    -- 被击中后立刻进入追击状态
    if enemy.state ~= "dying" and enemy.state ~= "dead" and enemy.state == "patrol" then
        enemy.state = "chase"
    end

    -- 回调飘字
    if Combat.onDamageDealt then
        Combat.onDamageDealt(dmg, isCrit, enemy.node.position)
    end
end

-- ============================================================================
-- 弹道系统（根据技能 ID 分化视觉效果）
-- ============================================================================
function Combat.SpawnProjectile(scene, origin, dir, damage, skill, player)
    local projNode = scene:CreateChild("Projectile")
    projNode.position = origin

    local skillId = skill.id or ""

    -- ========== 法师 - 火球术：橙红火焰球 ==========
    if skillId == "m_fireball" then
        projNode.scale = Vector3(0.25, 0.25, 0.25)
        local model = projNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local fireColor = Color(1.0, 0.45, 0.05, 1.0) -- 火焰橙红
        local mat = CreatePBR(fireColor, 0.0, 0.2)
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.35, 0.0)))
        model:SetMaterial(mat)
        model.castShadows = false
        -- 火焰尾焰（小球拖尾）
        local trailNode = projNode:CreateChild("trail")
        trailNode.position = Vector3(0, 0, -0.4)
        trailNode.scale = Vector3(0.6, 0.6, 0.6)
        local tModel = trailNode:CreateComponent("StaticModel")
        tModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local trailMat = CreatePBR(Color(1.0, 0.2, 0.0, 0.5), 0.0, 0.4)
        trailMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.15, 0.0)))
        tModel:SetMaterial(trailMat)
        tModel.castShadows = false

    -- (m_thunder 已改为直接劈闪电，不再使用投射物)

    -- ========== 灵魂火符：长方形符咒 ==========
    elseif skillId == "t_talisman" then
        -- 横飞纸符：窄长型（宽0.25 × 厚0.008 × 长0.55）
        local angle = math.atan2(dir.x, dir.z)
        projNode.rotation = Quaternion(math.deg(angle), Vector3.UP)
        -- 底纸层
        local paperNode = projNode:CreateChild("paper")
        paperNode.scale = Vector3(0.25, 0.008, 0.55)
        local paperModel = paperNode:CreateComponent("StaticModel")
        paperModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local paperMat = CreatePBR(Color(0.96, 0.91, 0.74, 1.0), 0.9, 0.1)
        paperMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.25, 0.15, 0.04, 1.0)))
        paperModel:SetMaterial(paperMat)
        paperModel.castShadows = false
        -- 中央竖条纹（金黄符文）
        local centerLine = projNode:CreateChild("line_c")
        centerLine.scale = Vector3(0.03, 0.012, 0.42)
        local clModel = centerLine:CreateComponent("StaticModel")
        clModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local runeMatColor = Color(0.85, 0.65, 0.05, 1.0)
        local redMat = CreatePBR(runeMatColor, 0.0, 0.4)
        redMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.9, 0.7, 0.1, 1.0)))
        clModel:SetMaterial(redMat)
        clModel.castShadows = false
        -- 左侧短横（道教符纹）
        local leftBar = projNode:CreateChild("line_l")
        leftBar.position = Vector3(-0.06, 0.003, 0.12)
        leftBar.scale = Vector3(0.08, 0.012, 0.015)
        local lModel = leftBar:CreateComponent("StaticModel")
        lModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        lModel:SetMaterial(redMat)
        lModel.castShadows = false
        -- 右侧短横
        local rightBar = projNode:CreateChild("line_r")
        rightBar.position = Vector3(0.06, 0.003, -0.10)
        rightBar.scale = Vector3(0.08, 0.012, 0.015)
        local rModel = rightBar:CreateComponent("StaticModel")
        rModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        rModel:SetMaterial(redMat)
        rModel.castShadows = false
        -- 顶端横封（封印线）
        local topSeal = projNode:CreateChild("seal_top")
        topSeal.position = Vector3(0, 0.003, 0.24)
        topSeal.scale = Vector3(0.18, 0.012, 0.018)
        local tModel = topSeal:CreateComponent("StaticModel")
        tModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        tModel:SetMaterial(redMat)
        tModel.castShadows = false
        -- 底端横封
        local botSeal = projNode:CreateChild("seal_bot")
        botSeal.position = Vector3(0, 0.003, -0.24)
        botSeal.scale = Vector3(0.18, 0.012, 0.018)
        local bModel = botSeal:CreateComponent("StaticModel")
        bModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        bModel:SetMaterial(redMat)
        bModel.castShadows = false

    -- ========== 默认/通用投射物 ==========
    else
        projNode.scale = Vector3(0.2, 0.2, 0.2)
        local model = projNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local projColor = Color(1.0, 0.6, 0.2, 1.0)
        if player.classId == "mage" then
            projColor = Color(0.3, 0.6, 1.0, 1.0)
        elseif player.classId == "taoist" then
            projColor = Color(0.8, 0.8, 0.3, 1.0)
        end
        local mat = CreatePBR(projColor, 0.0, 0.3)
        mat:SetShaderParameter("MatEmissiveColor", Variant(projColor))
        model:SetMaterial(mat)
        model.castShadows = false
    end

    table.insert(projectiles, {
        node = projNode,
        dir = dir,
        speed = skill.projectileSpeed or 12,
        damage = damage,
        range = skill.range or 8,
        traveled = 0,
        skillId = skillId,
    })
end

function Combat.UpdateProjectiles(scene, dt, player)
    for i = #projectiles, 1, -1 do
        local p = projectiles[i]
        local move = p.dir * p.speed * dt
        p.node.position = p.node.position + move
        p.traveled = p.traveled + p.speed * dt

        -- 碰撞检测
        local hit = false
        local hitPos = p.node.position
        for _, e in ipairs(enemies) do
            if e.state ~= "dead" and e.state ~= "dying" then
                local d = (e.node.position - p.node.position):Length()
                if d < 1.0 then
                    Combat.DealDamage(e, p.damage, player)
                    RememberPlayerTarget(e)
                    hit = true
                    hitPos = e.node.position
                    break
                end
            end
        end

        if hit or p.traveled >= p.range then
            -- 灵魂火符命中时产生小爆炸
            if hit and p.skillId == "t_talisman" then
                Combat.SpawnTalismanBurst(scene, hitPos)
            end
            p.node:Remove()
            table.remove(projectiles, i)
        end
    end
end

-- 灵魂火符命中爆炸效果：火焰色小型爆散
function Combat.SpawnTalismanBurst(scene, pos)
    local node = scene:CreateChild("TalismanBurst")
    node.position = Vector3(pos.x, pos.y + 0.8, pos.z)
    -- 中心火焰闪光球
    local core = node:CreateChild("core")
    core.scale = Vector3(0.5, 0.5, 0.5)
    local cModel = core:CreateComponent("StaticModel")
    cModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    local coreMat = Material:new()
    coreMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    coreMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.45, 0.05, 0.85)))
    coreMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.35, 0.0)))
    coreMat:SetShaderParameter("Metallic", Variant(0.0))
    coreMat:SetShaderParameter("Roughness", Variant(0.2))
    cModel:SetMaterial(coreMat)
    cModel.castShadows = false
    -- 外扩火环
    local ring = node:CreateChild("ring")
    ring.scale = Vector3(0.8, 0.05, 0.8)
    local rModel = ring:CreateComponent("StaticModel")
    rModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local ringMat = Material:new()
    ringMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    ringMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.3, 0.0, 0.5)))
    ringMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.9, 0.2, 0.0)))
    ringMat:SetShaderParameter("Metallic", Variant(0.0))
    ringMat:SetShaderParameter("Roughness", Variant(0.3))
    rModel:SetMaterial(ringMat)
    rModel.castShadows = false
    -- 快速消失
    node:SetVar("removeTimer", Variant(0.3))
end

-- ============================================================================
-- AOE 视觉效果（根据技能 ID 分化）
-- ============================================================================
function Combat.SpawnAOEVisual(scene, center, radius, classId, skillId, wallAngle)
    skillId = skillId or ""

    -- ========== 法师 - 爆裂火焰：橙红扩散火环 ==========
    if skillId == "m_explosion" then
        local node = scene:CreateChild("AOEVisual")
        node.position = Vector3(center.x, 0.1, center.z)
        -- 内圈火焰爆心
        local coreNode = node:CreateChild("core")
        coreNode.scale = Vector3(radius * 0.8, 0.4, radius * 0.8)
        local cModel = coreNode:CreateComponent("StaticModel")
        cModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local coreColor = Color(1.0, 0.6, 0.0, 0.7)
        local coreMat = Material:new()
        coreMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        coreMat:SetShaderParameter("MatDiffColor", Variant(coreColor))
        coreMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.4, 0.0)))
        coreMat:SetShaderParameter("Metallic", Variant(0.0))
        coreMat:SetShaderParameter("Roughness", Variant(0.2))
        cModel:SetMaterial(coreMat)
        cModel.castShadows = false
        -- 外圈爆炸波
        local ringNode = node:CreateChild("ring")
        ringNode.position = Vector3(0, 0.05, 0)
        ringNode.scale = Vector3(radius * 2, 0.06, radius * 2)
        local rModel = ringNode:CreateComponent("StaticModel")
        rModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local ringMat = Material:new()
        ringMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        ringMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.35, 0.0, 0.4)))
        ringMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.9, 0.25, 0.0)))
        ringMat:SetShaderParameter("Metallic", Variant(0.0))
        ringMat:SetShaderParameter("Roughness", Variant(0.4))
        rModel:SetMaterial(ringMat)
        rModel.castShadows = false
        node:SetVar("removeTimer", Variant(1.8))
        return node

    -- ========== 法师 - 冰咆哮：暴风雪 + 冰雪粒子 ==========
    elseif skillId == "m_blizzard" then
        local node = scene:CreateChild("AOEVisual")
        node.position = Vector3(center.x, 0.0, center.z)
        node:SetVar("noShrink", Variant(true))
        node:SetVar("spinSpeed", Variant(120.0))  -- 每秒旋转120度

        -- 1) 冰冻地面（大范围半透明冰面）
        local iceBase = node:CreateChild("iceBase")
        iceBase.position = Vector3(0, 0.03, 0)
        iceBase.scale = Vector3(radius * 2.2, 0.03, radius * 2.2)
        local iModel = iceBase:CreateComponent("StaticModel")
        iModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local iceMat = Material:new()
        iceMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        iceMat:SetShaderParameter("MatDiffColor", Variant(Color(0.75, 0.9, 1.0, 0.45)))
        iceMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.3, 0.5, 0.9)))
        iceMat:SetShaderParameter("Metallic", Variant(0.95))
        iceMat:SetShaderParameter("Roughness", Variant(0.02))
        iModel:SetMaterial(iceMat)
        iModel.castShadows = false

        -- 2) 旋涡风柱（中心半透明圆柱模拟寒风旋转）
        local vortex = node:CreateChild("vortex")
        vortex.position = Vector3(0, 1.5, 0)
        vortex.scale = Vector3(radius * 1.4, 3.0, radius * 1.4)
        local vModel = vortex:CreateComponent("StaticModel")
        vModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local vortexMat = Material:new()
        vortexMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        vortexMat:SetShaderParameter("MatDiffColor", Variant(Color(0.8, 0.9, 1.0, 0.12)))
        vortexMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 0.6, 1.0)))
        vortexMat:SetShaderParameter("Metallic", Variant(0.0))
        vortexMat:SetShaderParameter("Roughness", Variant(0.1))
        vModel:SetMaterial(vortexMat)
        vModel.castShadows = false

        -- 3) 大冰柱（从地面刺出，环形排列）
        local pillarCount = 5
        for pi = 1, pillarCount do
            local angle = (pi / pillarCount) * math.pi * 2 + math.random() * 0.4
            local dist = radius * (0.5 + math.random() * 0.4)
            local pillar = node:CreateChild("icePillar" .. pi)
            local h = 1.2 + math.random() * 1.0
            pillar.position = Vector3(math.cos(angle) * dist, h * 0.5, math.sin(angle) * dist)
            pillar.scale = Vector3(0.15 + math.random() * 0.1, h, 0.15 + math.random() * 0.1)
            -- 冰柱略微倾斜
            pillar.rotation = Quaternion(math.random() * 12 - 6, math.random() * 360, math.random() * 12 - 6)
            local pModel = pillar:CreateComponent("StaticModel")
            pModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            local pillarMat = Material:new()
            pillarMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            pillarMat:SetShaderParameter("MatDiffColor", Variant(Color(0.85, 0.95, 1.0, 0.75)))
            pillarMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 0.65, 1.0)))
            pillarMat:SetShaderParameter("Metallic", Variant(0.9))
            pillarMat:SetShaderParameter("Roughness", Variant(0.03))
            pModel:SetMaterial(pillarMat)
            pModel.castShadows = false
        end

        -- 4) 冰雪粒子群（大量微小方块模拟飞舞的冰晶雪花）
        local particleCount = 25
        for pi = 1, particleCount do
            local particle = node:CreateChild("snowParticle" .. pi)
            -- 随机分布在圆柱空间内
            local pAngle = math.random() * math.pi * 2
            local pDist = math.random() * radius * 1.0
            local pHeight = 0.3 + math.random() * 3.5
            particle.position = Vector3(
                math.cos(pAngle) * pDist,
                pHeight,
                math.sin(pAngle) * pDist
            )
            -- 微小尺寸，随机形态
            local pSize = 0.03 + math.random() * 0.06
            particle.scale = Vector3(pSize, pSize * (0.5 + math.random()), pSize)
            -- 随机旋转模拟翻滚
            particle.rotation = Quaternion(math.random() * 360, math.random() * 360, math.random() * 360)
            local ptModel = particle:CreateComponent("StaticModel")
            ptModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            local ptMat = Material:new()
            ptMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            -- 白/淡蓝随机
            local blue = 0.85 + math.random() * 0.15
            ptMat:SetShaderParameter("MatDiffColor", Variant(Color(blue, blue, 1.0, 0.7 + math.random() * 0.3)))
            ptMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.5, 0.7, 1.0)))
            ptMat:SetShaderParameter("Metallic", Variant(0.6))
            ptMat:SetShaderParameter("Roughness", Variant(0.1))
            ptModel:SetMaterial(ptMat)
            ptModel.castShadows = false
        end

        -- 5) 外圈冰碎环（地面边缘碎冰块）
        for ci = 1, 8 do
            local shard = node:CreateChild("iceShard" .. ci)
            local sa = (ci / 8) * math.pi * 2 + math.random() * 0.3
            local sd = radius * (0.8 + math.random() * 0.3)
            shard.position = Vector3(math.cos(sa) * sd, 0.08 + math.random() * 0.15, math.sin(sa) * sd)
            local ss = 0.08 + math.random() * 0.12
            shard.scale = Vector3(ss, ss * 0.5, ss * 1.5)
            shard.rotation = Quaternion(math.random() * 30 - 15, math.random() * 360, math.random() * 30 - 15)
            local sModel = shard:CreateComponent("StaticModel")
            sModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            local shardMat = CreatePBR(Color(0.9, 0.95, 1.0, 0.85), 0.95, 0.02)
            shardMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.3, 0.5, 0.9)))
            sModel:SetMaterial(shardMat)
            sModel.castShadows = false
        end

        node:SetVar("removeTimer", Variant(3.0))
        return node

    -- ========== 法师 - 火墙：长方形燃烧区域（火墙形态） ==========
    elseif skillId == "m_firewall" then
        local node = scene:CreateChild("AOEVisual")
        node.position = Vector3(center.x, 0.0, center.z)
        node.rotation = Quaternion(math.deg(wallAngle or 0), Vector3.UP)
        node:SetVar("noShrink", Variant(true))

        local halfW = radius       -- 半宽
        local halfL = radius * 1.5 -- 半长

        -- 1) 地面焦灼长方形底盘（Box）
        local burnBase = node:CreateChild("burnBase")
        burnBase.position = Vector3(0, 0.02, 0)
        burnBase.scale = Vector3(halfW * 2, 0.02, halfL * 2)
        local bModel = burnBase:CreateComponent("StaticModel")
        bModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local burnMat = Material:new()
        burnMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        burnMat:SetShaderParameter("MatDiffColor", Variant(Color(0.08, 0.01, 0.0, 0.8)))
        burnMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.5, 0.06, 0.0)))
        burnMat:SetShaderParameter("Metallic", Variant(0.0))
        burnMat:SetShaderParameter("Roughness", Variant(0.95))
        bModel:SetMaterial(burnMat)
        bModel.castShadows = false

        -- 2) 边缘火焰（沿长方形边缘分布）
        local edgeFlames = 14
        for fi = 1, edgeFlames do
            -- 沿矩形边缘均匀分布
            local t = (fi - 1) / edgeFlames
            local fx, fz
            local perimeter = (halfW + halfL) * 4
            local p = t * perimeter
            if p < halfW * 2 then
                fx = -halfW + p
                fz = halfL
            elseif p < halfW * 2 + halfL * 2 then
                fx = halfW
                fz = halfL - (p - halfW * 2)
            elseif p < halfW * 4 + halfL * 2 then
                fx = halfW - (p - halfW * 2 - halfL * 2)
                fz = -halfL
            else
                fx = -halfW
                fz = -halfL + (p - halfW * 4 - halfL * 2)
            end
            -- 加点随机偏移让边缘不那么死板
            fx = fx + (math.random() - 0.5) * 0.2
            fz = fz + (math.random() - 0.5) * 0.2

            local flame = node:CreateChild("edgeFlame" .. fi)
            local fh = 1.0 + math.random() * 1.4
            flame.position = Vector3(fx, 0, fz)
            flame.scale = Vector3(0.22 + math.random() * 0.15, fh, 0.22 + math.random() * 0.15)
            -- 微微向外倾斜
            local outDir = Vector3(fx, 0, fz):Normalized()
            flame.rotation = Quaternion(5 + math.random() * 10, Vector3(outDir.z, 0, -outDir.x))
            local fModel = flame:CreateComponent("StaticModel")
            fModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            local flameMat = Material:new()
            flameMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            local bright = 0.7 + math.random() * 0.3
            flameMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.3 * bright, 0.0, 0.55)))
            flameMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.4 * bright, 0.35 * bright, 0.0)))
            flameMat:SetShaderParameter("Metallic", Variant(0.0))
            flameMat:SetShaderParameter("Roughness", Variant(0.25))
            fModel:SetMaterial(flameMat)
            fModel.castShadows = false
        end

        -- 3) 内部火焰（在长方形区域内随机分散）
        for fi = 1, 10 do
            local fx = (math.random() - 0.5) * halfW * 1.6
            local fz = (math.random() - 0.5) * halfL * 1.6
            local flame = node:CreateChild("innerFlame" .. fi)
            local fh = 0.5 + math.random() * 0.7
            flame.position = Vector3(fx, 0, fz)
            flame.scale = Vector3(0.12 + math.random() * 0.1, fh, 0.12 + math.random() * 0.1)
            flame.rotation = Quaternion(math.random() * 360, Vector3.UP)
            local fModel = flame:CreateComponent("StaticModel")
            fModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            local flameMat = Material:new()
            flameMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            flameMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.75, 0.25, 0.5)))
            flameMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.8, 0.9, 0.15)))
            flameMat:SetShaderParameter("Metallic", Variant(0.0))
            flameMat:SetShaderParameter("Roughness", Variant(0.15))
            fModel:SetMaterial(flameMat)
            fModel.castShadows = false
        end

        -- 4) 飘浮火星（在长方形范围内随机）
        for fi = 1, 8 do
            local ember = node:CreateChild("ember" .. fi)
            local fx = (math.random() - 0.5) * halfW * 1.8
            local fz = (math.random() - 0.5) * halfL * 1.8
            local ey = 0.6 + math.random() * 1.5
            ember.position = Vector3(fx, ey, fz)
            ember.scale = Vector3(0.05, 0.05, 0.05)
            local eModel = ember:CreateComponent("StaticModel")
            eModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
            local emberMat = Material:new()
            emberMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            emberMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.5, 0.1, 0.85)))
            emberMat:SetShaderParameter("MatEmissiveColor", Variant(Color(2.0, 0.7, 0.0)))
            emberMat:SetShaderParameter("Metallic", Variant(0.0))
            emberMat:SetShaderParameter("Roughness", Variant(0.1))
            eModel:SetMaterial(emberMat)
            eModel.castShadows = false
        end

        -- removeTimer 与 DOT duration 一致
        node:SetVar("removeTimer", Variant(5.0))
        return node

    -- ========== 道士 - 施毒术：圆形毒云 ==========
    elseif skillId == "t_poison" then
        local node = scene:CreateChild("AOEVisual")
        node.position = Vector3(center.x, 0.03, center.z)
        node:SetVar("spinSpeed", Variant(180.0))

        -- 地面毒圈底盘
        local baseNode = node:CreateChild("poisonBase")
        baseNode.scale = Vector3(radius * 2, 0.035, radius * 2)
        local bModel = baseNode:CreateComponent("StaticModel")
        bModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local baseMat = Material:new()
        baseMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        baseMat:SetShaderParameter("MatDiffColor", Variant(Color(0.05, 0.85, 0.12, 0.32)))
        baseMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.0, 0.9, 0.18)))
        baseMat:SetShaderParameter("Metallic", Variant(0.0))
        baseMat:SetShaderParameter("Roughness", Variant(0.25))
        bModel:SetMaterial(baseMat)
        bModel.castShadows = false

        -- 外圈毒雾边界
        local ringNode = node:CreateChild("poisonRing")
        ringNode.position = Vector3(0, 0.08, 0)
        ringNode.scale = Vector3(radius * 2.1, 0.08, radius * 2.1)
        local rModel = ringNode:CreateComponent("StaticModel")
        rModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local ringMat = Material:new()
        ringMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        ringMat:SetShaderParameter("MatDiffColor", Variant(Color(0.12, 1.0, 0.22, 0.45)))
        ringMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.05, 1.2, 0.25)))
        ringMat:SetShaderParameter("Metallic", Variant(0.0))
        ringMat:SetShaderParameter("Roughness", Variant(0.18))
        rModel:SetMaterial(ringMat)
        rModel.castShadows = false

        -- 内部十字毒纹，强调范围爆发感
        for ci = 1, 2 do
            local cross = node:CreateChild("poisonCross" .. ci)
            cross.position = Vector3(0, 0.075 + ci * 0.01, 0)
            cross.rotation = Quaternion((ci - 1) * 90 + 45, Vector3.UP)
            cross.scale = Vector3(radius * 1.8, 0.025, 0.12)
            local cModel = cross:CreateComponent("StaticModel")
            cModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            local crossMat = Material:new()
            crossMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            crossMat:SetShaderParameter("MatDiffColor", Variant(Color(0.18, 1.0, 0.28, 0.38)))
            crossMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.06, 1.4, 0.25)))
            crossMat:SetShaderParameter("Metallic", Variant(0.0))
            crossMat:SetShaderParameter("Roughness", Variant(0.18))
            cModel:SetMaterial(crossMat)
            cModel.castShadows = false
        end

        -- 边界毒雾喷柱
        for vi = 1, 10 do
            local vent = node:CreateChild("poisonVent" .. vi)
            local a = (vi / 10) * math.pi * 2
            local d = radius * (0.72 + math.random() * 0.22)
            vent.position = Vector3(math.cos(a) * d, 0.25, math.sin(a) * d)
            vent.scale = Vector3(0.12, 0.65 + math.random() * 0.45, 0.12)
            local vModel = vent:CreateComponent("StaticModel")
            vModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            local ventMat = Material:new()
            ventMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            ventMat:SetShaderParameter("MatDiffColor", Variant(Color(0.08, 0.95, 0.20, 0.42)))
            ventMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.0, 1.1, 0.25)))
            ventMat:SetShaderParameter("Metallic", Variant(0.0))
            ventMat:SetShaderParameter("Roughness", Variant(0.28))
            vModel:SetMaterial(ventMat)
            vModel.castShadows = false
        end

        -- 漂浮毒雾颗粒
        for pi = 1, 20 do
            local mist = node:CreateChild("poisonMist" .. pi)
            local a = math.random() * math.pi * 2
            local d = math.sqrt(math.random()) * radius * 0.9
            mist.position = Vector3(math.cos(a) * d, 0.35 + math.random() * 1.0, math.sin(a) * d)
            local s = 0.12 + math.random() * 0.22
            mist.scale = Vector3(s, s, s)
            local mModel = mist:CreateComponent("StaticModel")
            mModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
            local mistMat = Material:new()
            mistMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            mistMat:SetShaderParameter("MatDiffColor", Variant(Color(0.10, 0.9, 0.18, 0.55)))
            mistMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.0, 0.75, 0.18)))
            mistMat:SetShaderParameter("Metallic", Variant(0.0))
            mistMat:SetShaderParameter("Roughness", Variant(0.35))
            mModel:SetMaterial(mistMat)
            mModel.castShadows = false
        end

        node:SetVar("removeTimer", Variant(0.45))
        return node

    -- ========== 武士 - 烈火剑法：火焰爆发环 ==========
    elseif skillId == "w_fire" then
        local node = scene:CreateChild("AOEVisual")
        node.position = Vector3(center.x, 0.0, center.z)
        -- 中心火焰爆裂球
        local burstNode = node:CreateChild("burst")
        burstNode.position = Vector3(0, 0.8, 0)
        burstNode.scale = Vector3(radius * 0.6, radius * 0.6, radius * 0.6)
        local burstModel = burstNode:CreateComponent("StaticModel")
        burstModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local burstMat = Material:new()
        burstMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        burstMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.5, 0.0, 0.6)))
        burstMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.4, 0.0)))
        burstMat:SetShaderParameter("Metallic", Variant(0.0))
        burstMat:SetShaderParameter("Roughness", Variant(0.2))
        burstModel:SetMaterial(burstMat)
        burstModel.castShadows = false
        -- 地面火焰环
        local fireRing = node:CreateChild("fireRing")
        fireRing.position = Vector3(0, 0.05, 0)
        fireRing.scale = Vector3(radius * 2, 0.08, radius * 2)
        local frModel = fireRing:CreateComponent("StaticModel")
        frModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local frMat = CreatePBR(Color(1.0, 0.3, 0.0, 0.5), 0.0, 0.3)
        frMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.25, 0.0)))
        frModel:SetMaterial(frMat)
        frModel.castShadows = false
        node:SetVar("removeTimer", Variant(1.5))
        return node

    -- ========== 道士 - 困魔咒：翠绿法阵光环 ==========
    elseif skillId == "t_trapDemon" then
        local node = scene:CreateChild("AOEVisual")
        node.position = Vector3(center.x, 0.05, center.z)
        node:SetVar("noShrink", Variant(true))
        node:SetVar("spinSpeed", Variant(60.0))  -- 缓慢旋转法阵

        -- 地面法阵底盘（半透明翠绿）
        local baseNode = node:CreateChild("base")
        baseNode.scale = Vector3(radius * 2, 0.04, radius * 2)
        local bModel = baseNode:CreateComponent("StaticModel")
        bModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local baseMat = Material:new()
        baseMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        baseMat:SetShaderParameter("MatDiffColor", Variant(Color(0.1, 0.7, 0.3, 0.35)))
        baseMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.0, 0.5, 0.2)))
        baseMat:SetShaderParameter("Metallic", Variant(0.0))
        baseMat:SetShaderParameter("Roughness", Variant(0.3))
        bModel:SetMaterial(baseMat)
        bModel.castShadows = false

        -- 外圈光环（竖直薄圆环标识边界）
        local ringNode = node:CreateChild("ring")
        ringNode.position = Vector3(0, 1.0, 0)
        ringNode.scale = Vector3(radius * 2.1, 2.0, radius * 2.1)
        local rModel = ringNode:CreateComponent("StaticModel")
        rModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local ringMat = Material:new()
        ringMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        ringMat:SetShaderParameter("MatDiffColor", Variant(Color(0.2, 0.9, 0.4, 0.2)))
        ringMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.1, 0.8, 0.3)))
        ringMat:SetShaderParameter("Metallic", Variant(0.0))
        ringMat:SetShaderParameter("Roughness", Variant(0.2))
        rModel:SetMaterial(ringMat)
        rModel.castShadows = false

        -- 八方镇魔符柱
        for pi = 1, 8 do
            local pillar = node:CreateChild("trapPillar" .. pi)
            local a = (pi / 8) * math.pi * 2
            local d = radius * 0.95
            pillar.position = Vector3(math.cos(a) * d, 0.75, math.sin(a) * d)
            pillar.scale = Vector3(0.10, 1.35, 0.10)
            local pModel = pillar:CreateComponent("StaticModel")
            pModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            local pMat = Material:new()
            pMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            pMat:SetShaderParameter("MatDiffColor", Variant(Color(0.18, 1.0, 0.45, 0.55)))
            pMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.0, 1.4, 0.45)))
            pMat:SetShaderParameter("Metallic", Variant(0.0))
            pMat:SetShaderParameter("Roughness", Variant(0.15))
            pModel:SetMaterial(pMat)
            pModel.castShadows = false

            local orb = node:CreateChild("trapOrb" .. pi)
            orb.position = Vector3(math.cos(a) * d, 1.55, math.sin(a) * d)
            orb.scale = Vector3(0.18, 0.18, 0.18)
            local oModel = orb:CreateComponent("StaticModel")
            oModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
            local oMat = Material:new()
            oMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            oMat:SetShaderParameter("MatDiffColor", Variant(Color(0.35, 1.0, 0.55, 0.75)))
            oMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.05, 1.8, 0.55)))
            oMat:SetShaderParameter("Metallic", Variant(0.0))
            oMat:SetShaderParameter("Roughness", Variant(0.08))
            oModel:SetMaterial(oMat)
            oModel.castShadows = false
        end

        -- 内层旋转束缚符纹
        for li = 1, 4 do
            local line = node:CreateChild("trapRuneLine" .. li)
            line.position = Vector3(0, 0.11 + li * 0.01, 0)
            line.rotation = Quaternion(li * 45, Vector3.UP)
            line.scale = Vector3(radius * 1.45, 0.018, 0.055)
            local lModel = line:CreateComponent("StaticModel")
            lModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            local lMat = Material:new()
            lMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            lMat:SetShaderParameter("MatDiffColor", Variant(Color(0.35, 1.0, 0.55, 0.32)))
            lMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.08, 1.1, 0.35)))
            lMat:SetShaderParameter("Metallic", Variant(0.0))
            lMat:SetShaderParameter("Roughness", Variant(0.18))
            lModel:SetMaterial(lMat)
            lModel.castShadows = false
        end

        node:SetVar("removeTimer", Variant(6.0))
        return node

    -- ========== 默认通用 AOE ==========
    else
        local node = scene:CreateChild("AOEVisual")
        node.position = Vector3(center.x, 0.05, center.z)
        node.scale = Vector3(radius * 2, 0.05, radius * 2)
        local model = node:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local aoeColor
        if classId == "warrior" then
            aoeColor = Color(0.9, 0.3, 0.1, 0.4)
        elseif classId == "mage" then
            aoeColor = Color(0.3, 0.5, 1.0, 0.4)
        else
            aoeColor = Color(0.3, 0.8, 0.4, 0.4)
        end
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(aoeColor))
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(aoeColor.r, aoeColor.g, aoeColor.b)))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        mat:SetShaderParameter("Roughness", Variant(0.5))
        model:SetMaterial(mat)
        model.castShadows = false
        node:SetVar("removeTimer", Variant(2.0))
        return node
    end
end

-- ============================================================================
-- 半月弯刀视觉效果：月牙形光斩（中间厚、两端尖，像弯刀刃）
-- ============================================================================
function Combat.SpawnCrescentVisual(scene, center, dir, radius, classId)
    local node = scene:CreateChild("CrescentVisual")
    -- 弧刃位于武器挥舞高度（腰部 0.9m），微前置
    local fwd = Vector3(dir.x, 0, dir.z):Normalized()
    node.position = Vector3(center.x + fwd.x * 0.3, 0.9, center.z + fwd.z * 0.3)

    local baseAngle = math.atan2(fwd.x, fwd.z)
    local segments = 36
    local halfAngle = math.rad(135)  -- 前方 270 度弧

    -- === 第一层：刀刃主体（窄且锋利，锋白亮刃）===
    local geom = node:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local maxThickness = radius * 0.18  -- 中间厚度

    for i = 0, segments - 1 do
        local t0 = -1.0 + (i / segments) * 2.0
        local t1 = -1.0 + ((i + 1) / segments) * 2.0

        local a0 = baseAngle + t0 * halfAngle
        local a1 = baseAngle + t1 * halfAngle

        local c0 = math.cos(t0 * math.pi / 2)
        local c1 = math.cos(t1 * math.pi / 2)
        local thick0 = maxThickness * c0 * c0
        local thick1 = maxThickness * c1 * c1

        local outerR = radius
        local innerR0 = radius - thick0
        local innerR1 = radius - thick1

        local ox0 = math.sin(a0) * outerR
        local oz0 = math.cos(a0) * outerR
        local ox1 = math.sin(a1) * outerR
        local oz1 = math.cos(a1) * outerR
        local ix0 = math.sin(a0) * innerR0
        local iz0 = math.cos(a0) * innerR0
        local ix1 = math.sin(a1) * innerR1
        local iz1 = math.cos(a1) * innerR1

        geom:DefineVertex(Vector3(ix0, 0, iz0))
        geom:DefineNormal(Vector3.UP)
        geom:DefineTexCoord(Vector2(0, 0))
        geom:DefineVertex(Vector3(ox0, 0, oz0))
        geom:DefineNormal(Vector3.UP)
        geom:DefineTexCoord(Vector2(1, 0))
        geom:DefineVertex(Vector3(ox1, 0, oz1))
        geom:DefineNormal(Vector3.UP)
        geom:DefineTexCoord(Vector2(1, 1))

        geom:DefineVertex(Vector3(ix0, 0, iz0))
        geom:DefineNormal(Vector3.UP)
        geom:DefineTexCoord(Vector2(0, 0))
        geom:DefineVertex(Vector3(ox1, 0, oz1))
        geom:DefineNormal(Vector3.UP)
        geom:DefineTexCoord(Vector2(1, 1))
        geom:DefineVertex(Vector3(ix1, 0, iz1))
        geom:DefineNormal(Vector3.UP)
        geom:DefineTexCoord(Vector2(0, 1))
    end
    geom:Commit()

    -- 锋锐白色亮刃（蓝白剑气主体的亮边）
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.95, 0.99, 1.0, 0.95)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 1.0, 1.0)))
    mat:SetShaderParameter("Metallic", Variant(0.5))
    mat:SetShaderParameter("Roughness", Variant(0.06))
    geom:SetMaterial(mat)
    geom.castShadows = false

    -- === 第二层：外圈气浪（更宽、更淡、橙黄色散射）===
    local outerChild = node:CreateChild("outerWave")
    outerChild.position = Vector3(0, -0.02, 0)
    local outerGeom = outerChild:CreateComponent("CustomGeometry")
    outerGeom:BeginGeometry(0, TRIANGLE_LIST)

    local outerRadius = radius * 1.15
    local outerThick = radius * 0.35

    for i = 0, segments - 1 do
        local t0 = -1.0 + (i / segments) * 2.0
        local t1 = -1.0 + ((i + 1) / segments) * 2.0

        local a0 = baseAngle + t0 * halfAngle
        local a1 = baseAngle + t1 * halfAngle

        local c0 = math.cos(t0 * math.pi / 2)
        local c1 = math.cos(t1 * math.pi / 2)
        local thick0 = outerThick * c0 * c0
        local thick1 = outerThick * c1 * c1

        local oR = outerRadius
        local iR0 = outerRadius - thick0
        local iR1 = outerRadius - thick1

        local ox0 = math.sin(a0) * oR
        local oz0 = math.cos(a0) * oR
        local ox1 = math.sin(a1) * oR
        local oz1 = math.cos(a1) * oR
        local ix0 = math.sin(a0) * iR0
        local iz0 = math.cos(a0) * iR0
        local ix1 = math.sin(a1) * iR1
        local iz1 = math.cos(a1) * iR1

        outerGeom:DefineVertex(Vector3(ix0, 0, iz0))
        outerGeom:DefineNormal(Vector3.UP)
        outerGeom:DefineTexCoord(Vector2(0, 0))
        outerGeom:DefineVertex(Vector3(ox0, 0, oz0))
        outerGeom:DefineNormal(Vector3.UP)
        outerGeom:DefineTexCoord(Vector2(1, 0))
        outerGeom:DefineVertex(Vector3(ox1, 0, oz1))
        outerGeom:DefineNormal(Vector3.UP)
        outerGeom:DefineTexCoord(Vector2(1, 1))

        outerGeom:DefineVertex(Vector3(ix0, 0, iz0))
        outerGeom:DefineNormal(Vector3.UP)
        outerGeom:DefineTexCoord(Vector2(0, 0))
        outerGeom:DefineVertex(Vector3(ox1, 0, oz1))
        outerGeom:DefineNormal(Vector3.UP)
        outerGeom:DefineTexCoord(Vector2(1, 1))
        outerGeom:DefineVertex(Vector3(ix1, 0, iz1))
        outerGeom:DefineNormal(Vector3.UP)
        outerGeom:DefineTexCoord(Vector2(0, 1))
    end
    outerGeom:Commit()

    -- 外层气浪：青蓝半透明发光
    local outerMat = Material:new()
    outerMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    outerMat:SetShaderParameter("MatDiffColor", Variant(Color(0.3, 0.65, 1.0, 0.3)))
    outerMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.25, 0.55, 1.0)))
    outerMat:SetShaderParameter("Metallic", Variant(0.0))
    outerMat:SetShaderParameter("Roughness", Variant(0.4))
    outerGeom:SetMaterial(outerMat)
    outerGeom.castShadows = false

    -- === 第三层：刃尖火星（两端小球闪烁）===
    for tip = 1, 2 do
        local tipAngle = baseAngle + (tip == 1 and -1 or 1) * halfAngle
        local tipNode = node:CreateChild("tip" .. tip)
        tipNode.position = Vector3(math.sin(tipAngle) * radius, 0, math.cos(tipAngle) * radius)
        tipNode.scale = Vector3(0.12, 0.06, 0.12)
        local tModel = tipNode:CreateComponent("StaticModel")
        tModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local tipMat = Material:new()
        tipMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        tipMat:SetShaderParameter("MatDiffColor", Variant(Color(0.85, 0.95, 1.0, 0.9)))
        tipMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.6, 0.85, 1.0)))
        tipMat:SetShaderParameter("Metallic", Variant(0.0))
        tipMat:SetShaderParameter("Roughness", Variant(0.1))
        tModel:SetMaterial(tipMat)
        tModel.castShadows = false
    end

    node:SetVar("removeTimer", Variant(0.7))
    return node
end

-- ============================================================================
-- 刺杀剑术(被动)视觉效果：从刀上发出、朝目标飞出的"白色剑气"月牙
-- 起点贴着武器(角色前方)，随后整体朝挥砍方向飞行，到达隔身位距离后消失
-- ============================================================================
function Combat.SpawnAssassinSlashVisual(scene, center, dir, reach)
    reach = reach or 3.0
    local node = scene:CreateChild("AOEVisual")
    local fwd = Vector3(dir.x, 0, dir.z)
    if fwd:Length() > 0.001 then fwd = fwd:Normalized() else fwd = Vector3(0, 0, 1) end

    -- 起点：贴着武器(角色前方 0.6m，挥刀高度 1.0m)
    local startOffset = 0.6
    node.position = Vector3(center.x + fwd.x * startOffset, 1.0, center.z + fwd.z * startOffset)
    -- 朝向飞行方向：局部 +Z = 前方（飞行沿节点 forward）
    node.rotation = Quaternion(math.deg(math.atan2(fwd.x, fwd.z)), Vector3.UP)

    local segments = 24
    local halfAngle = math.rad(70)   -- 大弧度斩波(约140°)

    -- 在局部 XZ 平面绘制一弯"月牙剑气"(向 +Z 凸出)；两翼对齐到节点原点附近
    local function buildCrescent(comp, R, thick)
        comp:BeginGeometry(0, TRIANGLE_LIST)
        local zc = math.cos(halfAngle) * R
        for i = 0, segments - 1 do
            local t0 = -1.0 + (i / segments) * 2.0
            local t1 = -1.0 + ((i + 1) / segments) * 2.0
            local a0 = t0 * halfAngle
            local a1 = t1 * halfAngle
            local c0 = math.cos(t0 * math.pi / 2)
            local c1 = math.cos(t1 * math.pi / 2)
            local th0 = thick * c0 * c0
            local th1 = thick * c1 * c1
            local ox0 = math.sin(a0) * R
            local oz0 = math.cos(a0) * R - zc
            local ox1 = math.sin(a1) * R
            local oz1 = math.cos(a1) * R - zc
            local ix0 = math.sin(a0) * (R - th0)
            local iz0 = math.cos(a0) * (R - th0) - zc
            local ix1 = math.sin(a1) * (R - th1)
            local iz1 = math.cos(a1) * (R - th1) - zc
            comp:DefineVertex(Vector3(ix0, 0, iz0)); comp:DefineNormal(Vector3.UP); comp:DefineTexCoord(Vector2(0, 0))
            comp:DefineVertex(Vector3(ox0, 0, oz0)); comp:DefineNormal(Vector3.UP); comp:DefineTexCoord(Vector2(1, 0))
            comp:DefineVertex(Vector3(ox1, 0, oz1)); comp:DefineNormal(Vector3.UP); comp:DefineTexCoord(Vector2(1, 1))
            comp:DefineVertex(Vector3(ix0, 0, iz0)); comp:DefineNormal(Vector3.UP); comp:DefineTexCoord(Vector2(0, 0))
            comp:DefineVertex(Vector3(ox1, 0, oz1)); comp:DefineNormal(Vector3.UP); comp:DefineTexCoord(Vector2(1, 1))
            comp:DefineVertex(Vector3(ix1, 0, iz1)); comp:DefineNormal(Vector3.UP); comp:DefineTexCoord(Vector2(0, 1))
        end
        comp:Commit()
    end

    -- 按参考图分三层叠加：青蓝发光主体(铺开) + 青色中层 + 锋锐白色凸刃(最亮在上)
    -- 三层共享同一外凸刃(相同 R)，越往内越偏深蓝、越淡，形成渐变拖尾
    local function makeLayer(name, yOff, R, thick, diff, emis, rough)
        local n = node:CreateChild(name)
        n.position = Vector3(0, yOff, 0)
        local g = n:CreateComponent("CustomGeometry")
        buildCrescent(g, R, thick)
        local m = Material:new()
        m:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        m:SetShaderParameter("MatDiffColor", Variant(diff))
        m:SetShaderParameter("MatEmissiveColor", Variant(emis))
        m:SetShaderParameter("Metallic", Variant(0.0))
        m:SetShaderParameter("Roughness", Variant(rough))
        g:SetMaterial(m)
        g.castShadows = false
        return n
    end

    -- 主体：深青蓝、最宽、最透明（从凸刃向内大面积铺开）
    makeLayer("bodyDeep", -0.06, 1.78, 1.30, Color(0.15, 0.42, 1.0, 0.32), Color(0.12, 0.32, 0.9), 0.5)
    -- 中层：亮青蓝发光带
    makeLayer("bodyCyan", -0.03, 1.78, 0.70, Color(0.45, 0.82, 1.0, 0.58), Color(0.4, 0.78, 1.0), 0.3)
    -- 凸刃：锋锐白色亮边（最薄最亮，叠在最上层）
    makeLayer("edge", 0.0, 1.80, 0.20, Color(0.95, 0.99, 1.0, 0.98), Color(1.0, 1.0, 1.0), 0.05)

    -- 飞行：从武器位置朝节点前方短距甩出（由 UpdateVisuals 逐帧推进）
    local travelSpeed = 7.0      -- 慢一点
    local travelRemain = 1.2     -- 不必飞太远，短距甩出即可
    node:SetVar("noShrink", Variant(true))             -- 飞行途中不缩小
    node:SetVar("travelSpeed", Variant(travelSpeed))
    node:SetVar("travelRemain", Variant(travelRemain))
    node:SetVar("removeTimer", Variant(travelRemain / travelSpeed + 0.18))
    return node
end

-- ============================================================================
-- 烈火剑法视觉效果：巨型火焰纵斩弧 + 地面火浪扩散
-- 效果是一道从天劈下的烈焰剑弧，附带地面向前扩散的火浪
-- ============================================================================
function Combat.SpawnFireSlashVisual(scene, center, dir, radius)
    local node = scene:CreateChild("AOEVisual")
    local fwd = Vector3(dir.x, 0, dir.z):Normalized()
    -- 前置偏移，效果在角色前方
    node.position = Vector3(center.x + fwd.x * 0.8, 0, center.z + fwd.z * 0.8)

    local yaw = math.deg(math.atan2(fwd.x, fwd.z))
    node.rotation = Quaternion(yaw, Vector3.UP)

    -- === 主体：巨型火焰竖斩弧（从上方劈下）===
    local arcNode = node:CreateChild("fireArc")
    arcNode.position = Vector3(0, 1.2, 0.3)  -- 中心在胸前偏上
    local arcGeom = arcNode:CreateComponent("CustomGeometry")
    arcGeom:BeginGeometry(0, TRIANGLE_LIST)

    local segments = 20
    local arcRadius = radius * 0.9  -- 斩弧半径（与技能范围相关）
    local startAngle = math.rad(-30)  -- 从右上起
    local endAngle = math.rad(110)    -- 到左下止（140度大弧）
    local maxThick = 0.15             -- 火焰弧比普通剑弧厚

    for i = 0, segments - 1 do
        local t0 = i / segments
        local t1 = (i + 1) / segments
        local a0 = startAngle + (endAngle - startAngle) * t0
        local a1 = startAngle + (endAngle - startAngle) * t1

        -- 中间最宽，两端收尖
        local taper0 = math.sin(t0 * math.pi)
        local taper1 = math.sin(t1 * math.pi)
        local thick0 = maxThick * (0.3 + 0.7 * taper0)  -- 不完全收为零
        local thick1 = maxThick * (0.3 + 0.7 * taper1)

        local ox0 = math.cos(a0) * arcRadius
        local oy0 = math.sin(a0) * arcRadius
        local ox1 = math.cos(a1) * arcRadius
        local oy1 = math.sin(a1) * arcRadius
        local ix0 = math.cos(a0) * (arcRadius - thick0)
        local iy0 = math.sin(a0) * (arcRadius - thick0)
        local ix1 = math.cos(a1) * (arcRadius - thick1)
        local iy1 = math.sin(a1) * (arcRadius - thick1)

        local n = Vector3(0, 0, 1)
        arcGeom:DefineVertex(Vector3(ix0, iy0, 0))
        arcGeom:DefineNormal(n)
        arcGeom:DefineTexCoord(Vector2(t0, 0))
        arcGeom:DefineVertex(Vector3(ox0, oy0, 0))
        arcGeom:DefineNormal(n)
        arcGeom:DefineTexCoord(Vector2(t0, 1))
        arcGeom:DefineVertex(Vector3(ox1, oy1, 0))
        arcGeom:DefineNormal(n)
        arcGeom:DefineTexCoord(Vector2(t1, 1))

        arcGeom:DefineVertex(Vector3(ix0, iy0, 0))
        arcGeom:DefineNormal(n)
        arcGeom:DefineTexCoord(Vector2(t0, 0))
        arcGeom:DefineVertex(Vector3(ox1, oy1, 0))
        arcGeom:DefineNormal(n)
        arcGeom:DefineTexCoord(Vector2(t1, 1))
        arcGeom:DefineVertex(Vector3(ix1, iy1, 0))
        arcGeom:DefineNormal(n)
        arcGeom:DefineTexCoord(Vector2(t1, 0))
    end
    arcGeom:Commit()

    -- 火焰弧材质：炽烈橙红，强发光
    local fireMat = Material:new()
    fireMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    fireMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.4, 0.05, 0.85)))
    fireMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.5, 0.0)))
    fireMat:SetShaderParameter("Metallic", Variant(0.0))
    fireMat:SetShaderParameter("Roughness", Variant(0.15))
    arcGeom:SetMaterial(fireMat)
    arcGeom.castShadows = false

    -- === 火弧内层光芯：更亮更窄（白黄色高温核心）===
    local coreNode = node:CreateChild("fireCore")
    coreNode.position = Vector3(0, 1.2, 0.35)
    local coreGeom = coreNode:CreateComponent("CustomGeometry")
    coreGeom:BeginGeometry(0, TRIANGLE_LIST)

    local coreRadius = arcRadius * 0.85
    local coreThick = 0.04

    for i = 0, segments - 1 do
        local t0 = i / segments
        local t1 = (i + 1) / segments
        local a0 = startAngle + (endAngle - startAngle) * t0
        local a1 = startAngle + (endAngle - startAngle) * t1
        local taper0 = math.sin(t0 * math.pi)
        local taper1 = math.sin(t1 * math.pi)
        local thick0 = coreThick * taper0
        local thick1 = coreThick * taper1

        local ox0 = math.cos(a0) * coreRadius
        local oy0 = math.sin(a0) * coreRadius
        local ox1 = math.cos(a1) * coreRadius
        local oy1 = math.sin(a1) * coreRadius
        local ix0 = math.cos(a0) * (coreRadius - thick0)
        local iy0 = math.sin(a0) * (coreRadius - thick0)
        local ix1 = math.cos(a1) * (coreRadius - thick1)
        local iy1 = math.sin(a1) * (coreRadius - thick1)

        local n = Vector3(0, 0, 1)
        coreGeom:DefineVertex(Vector3(ix0, iy0, 0))
        coreGeom:DefineNormal(n)
        coreGeom:DefineTexCoord(Vector2(t0, 0))
        coreGeom:DefineVertex(Vector3(ox0, oy0, 0))
        coreGeom:DefineNormal(n)
        coreGeom:DefineTexCoord(Vector2(t0, 1))
        coreGeom:DefineVertex(Vector3(ox1, oy1, 0))
        coreGeom:DefineNormal(n)
        coreGeom:DefineTexCoord(Vector2(t1, 1))

        coreGeom:DefineVertex(Vector3(ix0, iy0, 0))
        coreGeom:DefineNormal(n)
        coreGeom:DefineTexCoord(Vector2(t0, 0))
        coreGeom:DefineVertex(Vector3(ox1, oy1, 0))
        coreGeom:DefineNormal(n)
        coreGeom:DefineTexCoord(Vector2(t1, 1))
        coreGeom:DefineVertex(Vector3(ix1, iy1, 0))
        coreGeom:DefineNormal(n)
        coreGeom:DefineTexCoord(Vector2(t1, 0))
    end
    coreGeom:Commit()

    local coreMat = Material:new()
    coreMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    coreMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.9, 0.5, 0.95)))
    coreMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.95, 0.7)))
    coreMat:SetShaderParameter("Metallic", Variant(0.0))
    coreMat:SetShaderParameter("Roughness", Variant(0.0))
    coreGeom:SetMaterial(coreMat)
    coreGeom.castShadows = false

    -- === 地面火浪：向前方扇形扩散的焦灼地面 ===
    local groundNode = node:CreateChild("groundFire")
    groundNode.position = Vector3(0, 0.04, radius * 0.4)
    groundNode.scale = Vector3(radius * 1.2, 0.04, radius * 0.8)
    local gModel = groundNode:CreateComponent("StaticModel")
    gModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local groundMat = Material:new()
    groundMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    groundMat:SetShaderParameter("MatDiffColor", Variant(Color(0.9, 0.25, 0.0, 0.4)))
    groundMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.7, 0.15, 0.0)))
    groundMat:SetShaderParameter("Metallic", Variant(0.0))
    groundMat:SetShaderParameter("Roughness", Variant(0.7))
    gModel:SetMaterial(groundMat)
    gModel.castShadows = false

    -- 地面火焰碎片（3个小火柱散落前方）
    for fi = 1, 3 do
        local flameNode = node:CreateChild("flame" .. fi)
        local fx = (fi - 2) * 0.6  -- -0.6, 0, 0.6 横向分布
        local fz = 0.5 + fi * 0.3  -- 纵向递增
        flameNode.position = Vector3(fx, 0, fz)
        local flameH = 0.5 + math.random() * 0.6
        flameNode.scale = Vector3(0.12, flameH, 0.12)
        local fModel = flameNode:CreateComponent("StaticModel")
        fModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local flameMat = Material:new()
        flameMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        flameMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.35, 0.0, 0.7)))
        flameMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.4, 0.0)))
        flameMat:SetShaderParameter("Metallic", Variant(0.0))
        flameMat:SetShaderParameter("Roughness", Variant(0.2))
        fModel:SetMaterial(flameMat)
        fModel.castShadows = false
    end

    node:SetVar("removeTimer", Variant(1.0))
    return node
end

-- ============================================================================
-- 护盾视觉效果：真气护盾(金色) / 魔法盾(蓝色)
-- ============================================================================
function Combat.SpawnShieldVisual(scene, playerNode, skillId, duration)
    local shieldNode = playerNode:CreateChild("AOEVisual")
    shieldNode.position = Vector3(0, 1.0, 0)
    shieldNode.scale = Vector3(1.2, 1.2, 1.2)

    local model = shieldNode:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))

    local shieldMat = Material:new()
    shieldMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))

    if skillId == "w_shield" then
        -- 真气护盾：金色气功壁
        shieldMat:SetShaderParameter("MatDiffColor", Variant(Color(0.9, 0.75, 0.2, 0.2)))
        shieldMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.6, 0.1)))
    else
        -- 魔法盾：蓝色魔力护盾
        shieldMat:SetShaderParameter("MatDiffColor", Variant(Color(0.3, 0.5, 1.0, 0.2)))
        shieldMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.2, 0.4, 0.9)))
    end
    shieldMat:SetShaderParameter("Metallic", Variant(0.0))
    shieldMat:SetShaderParameter("Roughness", Variant(0.1))
    model:SetMaterial(shieldMat)
    model.castShadows = false

    -- 视觉持续时间必须与护盾 BUFF 实际持续时间一致，
    -- 否则护盾球提前消失、玩家却仍免伤，会被误认为"结束后还在免伤"
    shieldNode:SetVar("removeTimer", Variant(duration))
end

-- ============================================================================
-- 雷电术落点效果：闪电柱（命中时生成）
-- ============================================================================
function Combat.SpawnThunderStrikeVisual(scene, pos)
    local node = scene:CreateChild("AOEVisual")
    node.position = Vector3(pos.x, 0, pos.z)

    -- 闪电参数
    local boltHeight = 8.0       -- 闪电从多高劈下
    local segments = 12          -- 主雷折线段数
    local jitter = 0.4           -- 每段横向随机偏移
    local thickness = 0.08       -- 主雷粗度

    -- 辅助：生成一条锯齿折线闪电的顶点列表
    local function generateBoltPoints(startY, endY, segs, jitterAmt, offsetX, offsetZ)
        local points = {}
        for i = 0, segs do
            local t = i / segs
            local y = startY + (endY - startY) * t
            local jx, jz = 0, 0
            if i > 0 and i < segs then
                jx = (math.random() - 0.5) * 2 * jitterAmt
                jz = (math.random() - 0.5) * 2 * jitterAmt
            end
            points[#points + 1] = Vector3((offsetX or 0) + jx, y, (offsetZ or 0) + jz)
        end
        return points
    end

    -- 辅助：用 CustomGeometry 画一条折线闪电（三角带，双面厚度模拟）
    local function drawBolt(parentNode, name, points, thick, color, emissiveColor, alpha)
        local boltNode = parentNode:CreateChild(name)
        local geom = boltNode:CreateComponent("CustomGeometry")
        geom:BeginGeometry(0, TRIANGLE_LIST)

        -- 沿每段构建矩形面片（XY平面 + XZ平面交叉，产生体积感）
        for i = 1, #points - 1 do
            local p0 = points[i]
            local p1 = points[i + 1]
            local halfT = thick * 0.5

            -- XY 面片（左右展开）
            geom:DefineVertex(Vector3(p0.x - halfT, p0.y, p0.z))
            geom:DefineNormal(Vector3(0, 0, 1))
            geom:DefineTexCoord(Vector2(0, 0))
            geom:DefineVertex(Vector3(p0.x + halfT, p0.y, p0.z))
            geom:DefineNormal(Vector3(0, 0, 1))
            geom:DefineTexCoord(Vector2(1, 0))
            geom:DefineVertex(Vector3(p1.x + halfT, p1.y, p1.z))
            geom:DefineNormal(Vector3(0, 0, 1))
            geom:DefineTexCoord(Vector2(1, 1))

            geom:DefineVertex(Vector3(p0.x - halfT, p0.y, p0.z))
            geom:DefineNormal(Vector3(0, 0, 1))
            geom:DefineTexCoord(Vector2(0, 0))
            geom:DefineVertex(Vector3(p1.x + halfT, p1.y, p1.z))
            geom:DefineNormal(Vector3(0, 0, 1))
            geom:DefineTexCoord(Vector2(1, 1))
            geom:DefineVertex(Vector3(p1.x - halfT, p1.y, p1.z))
            geom:DefineNormal(Vector3(0, 0, 1))
            geom:DefineTexCoord(Vector2(0, 1))

            -- XZ 面片（前后展开，让侧面也可见）
            geom:DefineVertex(Vector3(p0.x, p0.y, p0.z - halfT))
            geom:DefineNormal(Vector3(1, 0, 0))
            geom:DefineTexCoord(Vector2(0, 0))
            geom:DefineVertex(Vector3(p0.x, p0.y, p0.z + halfT))
            geom:DefineNormal(Vector3(1, 0, 0))
            geom:DefineTexCoord(Vector2(1, 0))
            geom:DefineVertex(Vector3(p1.x, p1.y, p1.z + halfT))
            geom:DefineNormal(Vector3(1, 0, 0))
            geom:DefineTexCoord(Vector2(1, 1))

            geom:DefineVertex(Vector3(p0.x, p0.y, p0.z - halfT))
            geom:DefineNormal(Vector3(1, 0, 0))
            geom:DefineTexCoord(Vector2(0, 0))
            geom:DefineVertex(Vector3(p1.x, p1.y, p1.z + halfT))
            geom:DefineNormal(Vector3(1, 0, 0))
            geom:DefineTexCoord(Vector2(1, 1))
            geom:DefineVertex(Vector3(p1.x, p1.y, p1.z - halfT))
            geom:DefineNormal(Vector3(1, 0, 0))
            geom:DefineTexCoord(Vector2(0, 1))
        end

        geom:Commit()
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(Color(color.r, color.g, color.b, alpha)))
        mat:SetShaderParameter("MatEmissiveColor", Variant(emissiveColor))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        mat:SetShaderParameter("Roughness", Variant(0.05))
        geom:SetMaterial(mat)
        geom.castShadows = false
        return boltNode
    end

    -- 1) 主雷击（粗、亮白蓝）
    local mainPoints = generateBoltPoints(boltHeight, 0, segments, jitter, 0, 0)
    drawBolt(node, "mainBolt", mainPoints, thickness,
        Color(0.95, 0.95, 1.0), Color(0.9, 0.85, 1.0), 0.95)

    -- 2) 外层光晕（更粗更透明，包裹主雷）
    local glowPoints = generateBoltPoints(boltHeight, 0, segments, jitter * 0.6, 0, 0)
    drawBolt(node, "glowBolt", glowPoints, thickness * 3.5,
        Color(0.6, 0.5, 1.0), Color(0.5, 0.4, 1.0), 0.25)

    -- 3) 分叉支雷（2-3条，从主雷中段分出，较细较短）
    local branchCount = 2 + math.floor(math.random() * 2) -- 2~3 条
    for bi = 1, branchCount do
        -- 从主雷的某个中间段分叉
        local splitIdx = math.random(3, math.max(4, segments - 3))
        local splitPoint = mainPoints[splitIdx]
        -- 分支方向随机偏移
        local bOffX = (math.random() - 0.5) * 2.5
        local bOffZ = (math.random() - 0.5) * 2.5
        local bSegs = 4 + math.floor(math.random() * 3)
        local endY = splitPoint.y - (1.5 + math.random() * 2.0)
        if endY < 0 then endY = 0 end
        local branchPts = generateBoltPoints(splitPoint.y, endY, bSegs, jitter * 0.7,
            splitPoint.x + bOffX * 0.3, splitPoint.z + bOffZ * 0.3)
        -- 让分支从分叉点开始偏移
        for pi = 1, #branchPts do
            branchPts[pi] = Vector3(
                branchPts[pi].x + bOffX * (pi / #branchPts),
                branchPts[pi].y,
                branchPts[pi].z + bOffZ * (pi / #branchPts)
            )
        end
        drawBolt(node, "branch" .. bi, branchPts, thickness * 0.5,
            Color(0.8, 0.75, 1.0), Color(0.7, 0.6, 1.0), 0.7)
    end

    -- 4) 落点爆裂光环（地面冲击波）
    local impactNode = node:CreateChild("impact")
    impactNode.position = Vector3(0, 0.06, 0)
    impactNode.scale = Vector3(2.0, 0.06, 2.0)
    local impModel = impactNode:CreateComponent("StaticModel")
    impModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local impMat = Material:new()
    impMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    impMat:SetShaderParameter("MatDiffColor", Variant(Color(0.7, 0.6, 1.0, 0.5)))
    impMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.7, 1.0)))
    impMat:SetShaderParameter("Metallic", Variant(0.0))
    impMat:SetShaderParameter("Roughness", Variant(0.1))
    impModel:SetMaterial(impMat)
    impModel.castShadows = false

    -- 5) 落点电弧碎片（地面散布的小闪光碎块）
    for si = 1, 6 do
        local spark = node:CreateChild("spark" .. si)
        local sa = (si / 6) * math.pi * 2 + math.random() * 0.5
        local sd = 0.4 + math.random() * 0.8
        spark.position = Vector3(math.cos(sa) * sd, 0.1 + math.random() * 0.2, math.sin(sa) * sd)
        local ss = 0.04 + math.random() * 0.06
        spark.scale = Vector3(ss, ss * 2, ss)
        spark.rotation = Quaternion(math.random() * 360, math.random() * 30, math.random() * 360)
        local sModel = spark:CreateComponent("StaticModel")
        sModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local sparkMat = Material:new()
        sparkMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        sparkMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 1.0, 1.0, 0.9)))
        sparkMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.9, 0.85, 1.0)))
        sparkMat:SetShaderParameter("Metallic", Variant(0.0))
        sparkMat:SetShaderParameter("Roughness", Variant(0.05))
        sModel:SetMaterial(sparkMat)
        sModel.castShadows = false
    end

    node:SetVar("removeTimer", Variant(0.6))
end

-- ============================================================================
-- AOE 持续区域更新
-- ============================================================================
function Combat.UpdateAOEZones(dt, player)
    for i = #aoeZones, 1, -1 do
        local zone = aoeZones[i]
        zone.timer = zone.timer - dt
        if zone.timer <= 0 then
            if zone.visualNode then zone.visualNode:Remove() end
            table.remove(aoeZones, i)
        else
            -- 判断是否需要tick间隔出伤
            local shouldDamage = true
            if zone.tickInterval then
                zone.tickAccum = (zone.tickAccum or 0) + dt
                if zone.tickAccum >= zone.tickInterval then
                    zone.tickAccum = zone.tickAccum - zone.tickInterval
                    shouldDamage = true
                else
                    shouldDamage = false
                end
            end

            if shouldDamage and not zone.isTrapZone then
                -- 对区域内敌人造成伤害（困魔区域不造成伤害）
                for _, e in ipairs(enemies) do
                    if e.state ~= "dead" and e.state ~= "dying" then
                        local inZone = false
                        if zone.isRect then
                            -- 长方形判定：将敌人坐标转换到火墙本地坐标系
                            local dx = e.node.position.x - zone.center.x
                            local dz = e.node.position.z - zone.center.z
                            local cosA = math.cos(-zone.wallAngle)
                            local sinA = math.sin(-zone.wallAngle)
                            local localX = dx * cosA - dz * sinA
                            local localZ = dx * sinA + dz * cosA
                            inZone = math.abs(localX) <= zone.halfW and math.abs(localZ) <= zone.halfL
                        else
                            -- 圆形判定
                            local d2 = (e.node.position - zone.center):Length()
                            inZone = d2 <= zone.radius
                        end

                        if inZone then
                            -- tick式伤害：每次tick造成 dps * tickInterval 的伤害
                            local dmg = zone.tickInterval and (zone.dps * zone.tickInterval) or (zone.dps * dt)
                            e.hp = e.hp - dmg
                            e.hitFlashTimer = 0.1
                            if e.state == "patrol" then e.state = "chase" end
                            if e.hp <= 0 then
                                Combat.TriggerDeath(e, player)
                            end
                        end
                    end
                end
            end

            -- 困魔区域：持续捕捉新进入的敌人
            if zone.isTrapZone then
                for _, e in ipairs(enemies) do
                    if e.state ~= "dead" and e.state ~= "dying" and not e.trapCenter then
                        local d = (e.node.position - zone.center):Length()
                        if d <= zone.radius then
                            e.trapCenter = zone.center
                            e.trapRadius = zone.radius
                            e.trapTimer = zone.timer
                            -- 后续进入的敌人也施加减防
                            local pct = zone.trapDefReducePercent or 0
                            if pct > 0 and not e.trapDefReduced then
                                local reduceAmt = math.floor(e.def * pct / 100)
                                e.defReduction = math.max(e.defReduction or 0, reduceAmt)
                                e.defReductionTimer = zone.timer
                                e.trapDefReduced = true
                            end
                        end
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- 召唤兽（支持多只同时存在，最多6只）
-- ============================================================================
local MAX_SUMMONS = 6

local SUMMON_VISUALS = {
    skeleton = { color = Color(0.55, 0.50, 0.40, 1.0), bodyScale = 0.35, headScale = 0.22, emissive = 0.15, atkCD = 1.5 },
    wolf     = { color = Color(0.50, 0.45, 0.35, 1.0), bodyScale = 0.40, headScale = 0.25, emissive = 0.20, atkCD = 1.0 },
    golem    = { color = Color(0.40, 0.38, 0.32, 1.0), bodyScale = 0.65, headScale = 0.35, emissive = 0.10, atkCD = 2.0 },
    holy     = { color = C.Gold,                        bodyScale = 0.55, headScale = 0.32, emissive = 0.50, atkCD = 1.2 },
    normal   = { color = C.Jade,                        bodyScale = 0.50, headScale = 0.30, emissive = 0.20, atkCD = 1.5 },
}

function Combat.SpawnSummon(scene, playerPos, atk, duration, isHoly, summonType)
    -- 超过上限时移除最老的
    while #summons >= MAX_SUMMONS do
        local oldest = summons[1]
        if oldest.node then oldest.node:Remove() end
        table.remove(summons, 1)
    end

    summonType = summonType or "normal"
    local vis = SUMMON_VISUALS[summonType] or SUMMON_VISUALS.normal

    local summonNode = scene:CreateChild("Summon_" .. summonType)
    summonNode.position = playerPos + Vector3(2, 0, 0)

    -- 身体
    local bodyNode = summonNode:CreateChild("Body")
    bodyNode.position = Vector3(0, vis.bodyScale, 0)
    bodyNode.scale = Vector3(vis.bodyScale, vis.bodyScale * 1.6, vis.bodyScale)
    local bodyModel = bodyNode:CreateComponent("StaticModel")
    bodyModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))

    local mat = CreatePBR(vis.color, 0.1, 0.5)
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(vis.color.r * vis.emissive, vis.color.g * vis.emissive, vis.color.b * vis.emissive)))
    bodyModel:SetMaterial(mat)
    bodyModel.castShadows = true

    -- 头部
    local headNode = summonNode:CreateChild("Head")
    headNode.position = Vector3(0, vis.bodyScale * 2 + vis.headScale, 0)
    headNode.scale = Vector3(vis.headScale, vis.headScale, vis.headScale)
    local headModel = headNode:CreateComponent("StaticModel")
    headModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    headModel:SetMaterial(mat)

    -- 召唤物动态碰撞体
    local sBody = summonNode:CreateComponent("RigidBody")
    sBody.mass = 1.0
    sBody.collisionLayer = 4          -- AI 层（与敌人同层，互相碰撞）
    sBody.collisionMask = 1 | 2 | 4   -- 与地形(1)、玩家(2)、其他AI(4)碰撞
    sBody.angularFactor = Vector3(0, 0, 0)
    sBody.linearFactor = Vector3(1, 0, 1)   -- 锁定 Y 轴
    sBody.friction = 0.5
    sBody.linearDamping = 0.1
    local sShape = summonNode:CreateComponent("CollisionShape")
    local sCapsuleH = vis.bodyScale * 2.5
    local sCapsuleD = vis.bodyScale * 1.2
    sShape:SetCapsule(sCapsuleD, sCapsuleH, Vector3(0, sCapsuleH * 0.5, 0))

    table.insert(summons, {
        node = summonNode,
        atk = atk,
        baseAtk = atk,
        timer = duration,
        attackCD = vis.atkCD,
        attackTimer = 0,
        isHoly = isHoly or false,
        summonType = summonType,
        buffTimer = 0,
    })
    print("[Combat] Summoned " .. summonType .. " ATK=" .. atk .. " (total:" .. #summons .. ")")
end

function Combat.UpdateSummons(dt, playerNode, player)
    if not playerNode then return end
    local playerPos = playerNode.position

    for i = #summons, 1, -1 do
        local s = summons[i]
        s.timer = s.timer - dt

        -- buff 衰减
        if s.buffTimer > 0 then
            s.buffTimer = s.buffTimer - dt
            if s.buffTimer <= 0 then
                s.atk = s.baseAtk
            end
        end

        if s.timer <= 0 then
            s.node:Remove()
            table.remove(summons, i)
        else
            s.attackTimer = math.max(0, s.attackTimer - dt)

            local sBody = s.node:GetComponent("RigidBody")
            local sPos = s.node.position
            local toPlayer = playerPos - sPos
            toPlayer.y = 0
            local distToPlayer = toPlayer:Length()
            local followSpeed = (s.summonType == "wolf") and 5.5 or 4.0

            local moved = false

            -- 攻击最近的敌人（优先级高于跟随）
            local chaseRange = (s.summonType == "wolf") and 6.0 or 4.5
            if s.attackTimer <= 0 then
                local nearestEnemy, nearDist = Combat.FindNearestEnemy(s.node.position, chaseRange)
                if nearestEnemy then
                    local dir = nearestEnemy.node.position - s.node.position
                    dir.y = 0
                    local eDist = dir:Length()
                    dir = dir:Normalized()
                    local angle = math.atan2(dir.x, dir.z)
                    s.node.rotation = Quaternion(math.deg(angle), Vector3.UP)

                    if eDist <= 2.0 then
                        Combat.DealDamage(nearestEnemy, s.atk, player)
                        s.attackTimer = s.attackCD
                        if sBody then sBody:SetLinearVelocity(Vector3.ZERO) end
                    else
                        if sBody then sBody:SetLinearVelocity(dir * followSpeed) end
                    end
                    moved = true
                end
            end

            -- 跟随玩家（松散跟随）
            if not moved then
                if distToPlayer > 3.5 then
                    local dir = toPlayer:Normalized()
                    if sBody then sBody:SetLinearVelocity(dir * followSpeed) end
                else
                    if sBody then sBody:SetLinearVelocity(Vector3.ZERO) end
                end
            end
        end
    end
end

-- ============================================================================
-- AOE 视觉清理 (场景中的临时节点)
-- ============================================================================
function Combat.UpdateVisuals(scene, dt, playerNode)
    -- 清理 AOE / Crescent 视觉效果（场景根级别）
    local children = {}
    for i = 0, scene:GetNumChildren(false) - 1 do
        local child = scene:GetChild(i)
        if child.name == "AOEVisual" or child.name == "CrescentVisual" or child.name == "TalismanBurst" then
            table.insert(children, child)
        end
    end
    -- 同时清理挂在玩家身上的护盾等视觉效果
    if playerNode then
        for i = 0, playerNode:GetNumChildren(false) - 1 do
            local child = playerNode:GetChild(i)
            if child.name == "AOEVisual" then
                table.insert(children, child)
            end
        end
    end
    for _, child in ipairs(children) do
        local t = child:GetVar("removeTimer"):GetFloat()
        t = t - dt
        if t <= 0 then
            child:Remove()
        else
            child:SetVar("removeTimer", Variant(t))
            -- 渐隐效果：持续型效果(火墙等)不缩小，仅短暂效果缩小
            if child:GetParent() == scene then
                local noShrink = child:GetVar("noShrink")
                local shouldShrink = true
                if noShrink and not noShrink:IsEmpty() and noShrink:GetBool() then
                    shouldShrink = false
                end
                if shouldShrink then
                    local s = child.scale
                    child.scale = s * (1.0 - dt * 0.8)
                end
                -- 旋转效果（冰咆哮等）
                local spinVar = child:GetVar("spinSpeed")
                if spinVar and not spinVar:IsEmpty() then
                    local speed = spinVar:GetFloat()
                    local rot = child.rotation
                    child.rotation = rot * Quaternion(speed * dt, Vector3.UP)
                end
                -- 飞行效果（刺杀白色剑气：从武器朝目标飞出）
                local travelVar = child:GetVar("travelSpeed")
                if travelVar and not travelVar:IsEmpty() then
                    local spd = travelVar:GetFloat()
                    local remVar = child:GetVar("travelRemain")
                    local rem = (remVar and not remVar:IsEmpty()) and remVar:GetFloat() or 0
                    if spd > 0 and rem > 0 then
                        local step = math.min(rem, spd * dt)
                        child.position = child.position + child:GetDirection() * step
                        child:SetVar("travelRemain", Variant(rem - step))
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- 自动刷怪（等级匹配 + Boss 定时刷新）
-- ============================================================================
local bossTimer = 0
local BOSS_INTERVAL = 45  -- 每45秒尝试刷一只Boss

function Combat.UpdateSpawner(scene, dt, playerNode, player)
    if not playerNode or not player then return end

    -- 普通怪刷新（频率随场上怪物数量动态调节）
    spawnTimer = spawnTimer + dt
    local dynamicInterval = SPAWN_INTERVAL
    if #enemies > 55 then
        dynamicInterval = SPAWN_INTERVAL * 1.6  -- 场上怪多时放慢
    elseif #enemies < 30 then
        dynamicInterval = SPAWN_INTERVAL * 0.35  -- 场上怪少时加快
    end

    if spawnTimer >= dynamicInterval then
        spawnTimer = 0
        Combat.SpawnEnemy(scene, playerNode.position, player.level)
    end

    -- Boss 定时刷新（必须玩家等级达到 Boss 等级-5 才会出现）
    bossTimer = bossTimer + dt
    if bossTimer >= BOSS_INTERVAL then
        bossTimer = 0
        -- 寻找合适的 Boss
        local validBoss = {}
        for _, d in ipairs(ENEMY_DEFS) do
            if d.tier == "boss" and d.level <= player.level + 5 and d.level >= player.level - 10 then
                table.insert(validBoss, d)
            end
        end
        if #validBoss > 0 then
            local bossDef = validBoss[math.random(#validBoss)]
            Combat.SpawnEnemy(scene, playerNode.position, player.level, bossDef)
            print("[Combat] Boss spawned: " .. bossDef.name .. " Lv." .. bossDef.level)
        end
    end
end

-- ============================================================================
-- 地面掉落物系统
-- ============================================================================

--- 创建堆叠金币造型（多个扁平圆柱叠加）
local function CreateCoinPile(parentNode, pileSize)
    -- pileSize: 1=小堆(2-3枚), 2=中堆(3-4枚), 3=大堆(4-5枚)
    local coinCount = pileSize + math.random(1, 2)
    local goldMat = CreatePBR(Color(0.95, 0.75, 0.15, 1.0), 0.9, 0.35)
    goldMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.35, 0.25, 0.02)))

    for ci = 1, coinCount do
        local coinNode = parentNode:CreateChild("coin" .. ci)
        -- 每枚硬币稍有偏移和旋转，模拟自然堆叠
        local offX = (math.random() - 0.5) * 0.15
        local offZ = (math.random() - 0.5) * 0.15
        local stackY = (ci - 1) * 0.06  -- 每枚硬币高度叠加
        coinNode.position = Vector3(offX, stackY, offZ)
        -- 随机倾斜，越上面越歪
        local tiltX = (math.random() - 0.5) * 8 * ci
        local tiltZ = (math.random() - 0.5) * 8 * ci
        local rotY = math.random() * 360
        coinNode.rotation = Quaternion(tiltX, rotY, tiltZ)
        -- 扁平圆柱 = 硬币形状
        coinNode.scale = Vector3(0.3, 0.06, 0.3)

        local model = coinNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        model:SetMaterial(goldMat)
        model.castShadows = false
    end
end

--- 生成金币散落到地面
function Combat.SpawnGroundGold(scene, pos, amount)
    -- 分成 2~3 堆散开
    local count = math.random(2, 3)
    local perCoin = math.floor(amount / count)
    local remainder = amount - perCoin * count

    for ci = 1, count do
        local coinAmount = perCoin + (ci == 1 and remainder or 0)
        if coinAmount <= 0 then break end

        -- 散开偏移
        local angle = (ci - 1) / count * math.pi * 2 + math.random() * 0.5
        local dist = 0.4 + math.random() * 0.6
        local offX = math.cos(angle) * dist
        local offZ = math.sin(angle) * dist
        local targetPos = Vector3(pos.x + offX, 0.10, pos.z + offZ)

        local goldNode = scene:CreateChild("GroundGold")
        -- 先从死亡位置上方开始
        goldNode.position = Vector3(targetPos.x, 1.2, targetPos.z)

        -- 根据金额决定堆大小
        local pileSize = 1
        if coinAmount >= 20 then pileSize = 3
        elseif coinAmount >= 10 then pileSize = 2
        end
        CreateCoinPile(goldNode, pileSize)

        table.insert(groundItems, {
            node = goldNode,
            type = "gold",
            amount = coinAmount,
            timer = 0,
            lifetime = GOLD_LIFETIME,
            targetY = 0.10,
            fallSpeed = 3.0 + math.random() * 2.0,
            falling = true,
            magnetPhase = false,
            vel = 0,
        })
    end
end

--- 生成装备掉落到地面
function Combat.SpawnGroundItem(scene, pos, item)
    local Inventory = require("scripts.Inventory")
    local rarity = Inventory.RARITY[item.rarity]
    local rColor = rarity and rarity.color or {200, 200, 200, 255}
    local c = Color(rColor[1] / 255, rColor[2] / 255, rColor[3] / 255, 1.0)

    -- 稍微偏移
    local offAngle = math.random() * math.pi * 2
    local offDist = 0.3 + math.random() * 0.5
    local targetPos = Vector3(pos.x + math.cos(offAngle) * offDist, 0.25, pos.z + math.sin(offAngle) * offDist)

    local itemNode = scene:CreateChild("GroundItem")
    itemNode.position = Vector3(targetPos.x, 1.5, targetPos.z)
    itemNode.scale = Vector3(0.25, 0.25, 0.25)

    local model = itemNode:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
    local mat = CreatePBR(c, 0.3, 0.4)
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(c.r * 0.5, c.g * 0.5, c.b * 0.5)))
    model:SetMaterial(mat)
    model.castShadows = true

    table.insert(groundItems, {
        node = itemNode,
        type = "item",
        item = item,
        timer = 0,
        lifetime = ITEM_LIFETIME,
        targetY = 0.25,
        fallSpeed = 2.5 + math.random() * 1.5,
        falling = true,
        rotSpeed = 60 + math.random() * 40,
    })
end

--- 更新地面物品（金币磁吸 + 装备靠近拾取）
function Combat.UpdateGroundItems(dt, playerNode)
    if not playerNode then return end
    local playerPos = playerNode.position

    for i = #groundItems, 1, -1 do
        local g = groundItems[i]
        g.timer = g.timer + dt

        -- 超时移除
        if g.timer > g.lifetime then
            g.node:Remove()
            table.remove(groundItems, i)
            goto continue_ground
        end

        local pos = g.node.position

        -- 掉落动画
        if g.falling then
            local newY = pos.y - g.fallSpeed * dt
            if newY <= g.targetY then
                newY = g.targetY
                g.falling = false
            end
            g.node.position = Vector3(pos.x, newY, pos.z)
            pos = g.node.position
        end

        if g.type == "gold" then
            -- 金币：延迟后磁吸向玩家
            if not g.falling and g.timer >= GOLD_MAGNET_DELAY then
                g.magnetPhase = true
            end

            if g.magnetPhase then
                local toPlayer = playerPos - pos
                toPlayer.y = 0
                local dist = toPlayer:Length()

                if dist < GOLD_PICKUP_DIST then
                    -- 拾取金币
                    if Combat.onGoldPickup then
                        Combat.onGoldPickup(g.amount, pos)
                    end
                    g.node:Remove()
                    table.remove(groundItems, i)
                    goto continue_ground
                end

                -- 加速朝玩家飞去
                g.vel = math.min(GOLD_MAGNET_MAX_SPEED, g.vel + GOLD_MAGNET_ACCEL * dt)
                local dir = toPlayer:Normalized()
                local newPos = pos + dir * g.vel * dt
                newPos.y = math.max(0.15, newPos.y)
                g.node.position = newPos
            end

        elseif g.type == "item" then
            -- 装备：旋转 + 上下浮动
            if not g.falling then
                local rot = g.node.rotation
                g.node.rotation = rot * Quaternion(g.rotSpeed * dt, Vector3.UP)
                -- 轻微上下浮动
                local bob = g.targetY + math.sin(g.timer * 2.5) * 0.1
                g.node.position = Vector3(pos.x, bob, pos.z)
            end

            -- 靠近拾取
            local toPlayer = playerPos - pos
            toPlayer.y = 0
            local dist = toPlayer:Length()

            if dist < ITEM_PICKUP_DIST then
                if Combat.onItemPickup then
                    Combat.onItemPickup(g.item, pos)
                end
                g.node:Remove()
                table.remove(groundItems, i)
                goto continue_ground
            end
        end

        ::continue_ground::
    end
end

-- ============================================================================
-- 工具函数
-- ============================================================================
function Combat.FindNearestEnemy(pos, maxRange)
    local nearest = nil
    local nearDist = maxRange or 999
    for _, e in ipairs(enemies) do
        if e.state ~= "dead" and e.state ~= "dying" then
            local d = (e.node.position - pos):Length()
            if d < nearDist then
                nearDist = d
                nearest = e
            end
        end
    end
    return nearest, nearDist
end

-- ============================================================================
-- 野蛮冲撞 · 冲刺逐帧推进
-- ============================================================================
--- 是否正在冲刺（main.lua 据此暂停玩家摇杆移动，避免覆盖冲刺位移）
function Combat.IsDashing()
    return dashState.active
end

--- 重置冲刺状态（玩家死亡/场景清理时调用，不结算顶出）
function Combat.CancelDash()
    dashState.active = false
    dashState.dir = nil
    dashState.remaining = 0
    dashState.pushed = {}
end

--- 冲刺结束：把被顶着的怪物顶出到刺杀剑术最远距离，并施加硬直
---@param playerNode Node
function Combat.EndDash(playerNode)
    local dir = dashState.dir
    if dir and playerNode then
        local pPos = playerNode.position
        for e, lateral in pairs(dashState.pushed) do
            if e.state ~= "dead" and e.state ~= "dying" then
                local ey = e.node.position.y
                e.node.position = Vector3(
                    pPos.x + dir.x * DASH_EJECT_DIST + lateral.x,
                    ey,
                    pPos.z + dir.z * DASH_EJECT_DIST + lateral.z)
                local eBody = e.node:GetComponent("RigidBody")
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
                e.knockbackTimer = 0          -- 清除残留击退，确保硬直立即生效
                e.hitStunTimer = DASH_STUN    -- 顶出后进入硬直
                -- 被顶出后回头面向玩家
                FaceEnemyDir(e, -dir)
                if e.state == "patrol" then e.state = "chase" end
                if e.animData then
                    MonsterSkeleton.PlayAnim(e.animData, "hit", nil)
                end
            end
        end
    end
    Combat.CancelDash()
end

--- 冲刺逐帧推进：移动玩家、卷入并顶推前方怪物
---@param dt number
---@param playerNode Node
function Combat.UpdateDash(dt, playerNode)
    if not dashState.active or not playerNode then return end
    local dir = dashState.dir
    if not dir then dashState.active = false return end

    -- 本帧推进步长（不超过剩余距离）
    local step = DASH_SPEED * dt
    local ending = false
    if step >= dashState.remaining then
        step = dashState.remaining
        ending = true
    end
    dashState.remaining = dashState.remaining - step

    local pPos = playerNode.position
    local newPos = Vector3(pPos.x + dir.x * step, 0, pPos.z + dir.z * step)

    -- 卷入"将要到达位置"前方的怪物（每帧检测，途中遇到的新怪也会被顶）
    for _, e in ipairs(enemies) do
        if e.state ~= "dead" and e.state ~= "dying" and not dashState.pushed[e] then
            local toE = e.node.position - newPos
            toE.y = 0
            local along = toE:DotProduct(dir)             -- 沿冲刺方向的投影
            if along >= -0.3 and along <= DASH_PUSH_REACH then
                local lateral = Vector3(toE.x - dir.x * along, 0, toE.z - dir.z * along)
                if lateral:Length() <= DASH_PUSH_WIDTH then
                    dashState.pushed[e] = lateral         -- 记录侧向偏移，全程保持
                end
            end
        end
    end

    -- 推进玩家
    playerNode.position = newPos
    local pBody = playerNode:GetComponent("RigidBody")
    if pBody then pBody:SetLinearVelocity(Vector3.ZERO) end

    -- 顶着被卷入的怪物前进（焊在玩家前方 DASH_CONTACT 处）
    for e, lateral in pairs(dashState.pushed) do
        if e.state ~= "dead" and e.state ~= "dying" then
            local ey = e.node.position.y
            e.node.position = Vector3(
                newPos.x + dir.x * DASH_CONTACT + lateral.x,
                ey,
                newPos.z + dir.z * DASH_CONTACT + lateral.z)
            local eBody = e.node:GetComponent("RigidBody")
            if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            -- 顶推期间保持轻硬直，压制怪物自身 AI 移动（次帧 UpdateEnemies 生效）
            if e.hitStunTimer < 0.15 then e.hitStunTimer = 0.15 end
            FaceEnemyDir(e, -dir)
        else
            dashState.pushed[e] = nil
        end
    end

    if ending then
        Combat.EndDash(playerNode)
    end
end

function Combat.Update(scene, dt, playerNode, player)
    Combat.UpdateEnemies(dt, playerNode, player)
    Combat.UpdateDash(dt, playerNode)   -- 在敌人 AI 之后，覆盖被顶怪物的位置
    Combat.UpdateProjectiles(scene, dt, player)
    Combat.UpdateAOEZones(dt, player)
    Combat.UpdateSummons(dt, playerNode, player)
    Combat.UpdateVisuals(scene, dt, playerNode)
    Combat.UpdateSpawner(scene, dt, playerNode, player)
    Combat.UpdateGroundItems(dt, playerNode)
    DivineBeast.Update(dt, scene, playerNode, player, enemies, Combat.DealDamage)
end

--- 清空所有战斗实体
function Combat.Clear()
    for _, e in ipairs(enemies) do
        if e.node then e.node:Remove() end
    end
    for _, p in ipairs(projectiles) do
        if p.node then p.node:Remove() end
    end
    for _, s in ipairs(summons) do
        if s.node then s.node:Remove() end
    end
    for _, z in ipairs(aoeZones) do
        if z.visualNode then z.visualNode:Remove() end
    end
    for _, g in ipairs(groundItems) do
        if g.node then g.node:Remove() end
    end
    enemies = {}
    projectiles = {}
    summons = {}
    aoeZones = {}
    groundItems = {}
    Combat.enemies = enemies
    Combat.projectiles = projectiles
    killCount = 0
    Combat.killCount = 0
    spawnTimer = 0
    lastPlayerTarget = nil
    Combat.CancelDash()
    DivineBeast.Clear()
end

-- 回调（由 main.lua 设置）
Combat.onDamageDealt = nil   -- function(dmg, isCrit, worldPos)
Combat.onEnemyAttack = nil   -- function(enemy, dmg, playerPos)
Combat.onPlayerHeal = nil    -- function(amount, playerPos)
Combat.onEnemyDeath = nil    -- function(enemyName, deathPos, exp)
Combat.onGoldPickup = nil    -- function(amount, worldPos)
Combat.onItemPickup = nil    -- function(item, worldPos)

return Combat
