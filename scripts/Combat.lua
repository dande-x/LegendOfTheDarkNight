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
-- 敌人配置（普通怪+精英怪+Boss 覆盖 1~50级）
-- hp/atk/def 为基础值，实际生成时按等级缩放
-- tier: "normal"=普通, "elite"=精英(黄名), "boss"=Boss(红名)
-- ============================================================================
local ENEMY_DEFS = {
    -- === 低级区 1~10 ===
    {
        name = "鹿",     monsterType = "deer",
        level = 1,  hp = 90,   atk = 8,  def = 3,
        speed = 3.0, chaseRange = 8, attackRange = 1.5, attackCD = 2.0,
        exp = 30, scale = 0.9, tier = "normal",
    },
    {
        name = "稻草人", monsterType = "scarecrow",
        level = 2,  hp = 110,  atk = 10, def = 4,
        speed = 2.2, chaseRange = 7, attackRange = 1.8, attackCD = 1.8,
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
        speed = 3.5, chaseRange = 12, attackRange = 1.3, attackCD = 1.2,
        exp = 65, scale = 0.85, tier = "normal",
    },
    {
        name = "半兽人", monsterType = "orc",
        level = 8,  hp = 210,  atk = 20, def = 8,
        speed = 2.0, chaseRange = 8, attackRange = 1.8, attackCD = 2.2,
        exp = 90, scale = 1.1, tier = "normal",
    },
    -- === 中级区 10~25 ===
    {
        name = "狼人",   monsterType = "orc",
        level = 10, hp = 260,  atk = 24, def = 10,
        speed = 3.2, chaseRange = 12, attackRange = 1.6, attackCD = 1.5,
        exp = 120, scale = 1.0, tier = "normal",
    },
    {
        name = "石魔",   monsterType = "golem",
        level = 14, hp = 400,  atk = 28, def = 16,
        speed = 1.6, chaseRange = 8, attackRange = 2.2, attackCD = 2.5,
        exp = 180, scale = 1.6, tier = "normal",
    },
    {
        name = "暗影蛛后", monsterType = "spider",
        level = 18, hp = 320,  atk = 32, def = 10,
        speed = 3.8, chaseRange = 14, attackRange = 1.8, attackCD = 1.0,
        exp = 220, scale = 1.3, tier = "elite",
    },
    {
        name = "骷髅将军", monsterType = "skeleton",
        level = 22, hp = 500,  atk = 38, def = 14,
        speed = 2.4, chaseRange = 12, attackRange = 2.0, attackCD = 1.8,
        exp = 300, scale = 1.3, tier = "elite",
    },
    -- === 高级区 25~40 ===
    {
        name = "赤焰魔", monsterType = "golem",
        level = 28, hp = 750,  atk = 45, def = 20,
        speed = 2.0, chaseRange = 10, attackRange = 2.5, attackCD = 2.0,
        exp = 450, scale = 1.8, tier = "elite",
    },
    {
        name = "巨蟒",   monsterType = "serpent",
        level = 32, hp = 950,  atk = 50, def = 18,
        speed = 2.8, chaseRange = 14, attackRange = 2.8, attackCD = 1.8,
        exp = 550, scale = 2.0, tier = "elite",
    },
    {
        name = "噬魂兽", monsterType = "orc",
        level = 36, hp = 1100, atk = 55, def = 22,
        speed = 2.5, chaseRange = 12, attackRange = 2.0, attackCD = 1.5,
        exp = 700, scale = 1.5, tier = "elite",
    },
    -- === Boss 区 (大型压迫感怪物) ===
    {
        name = "山岳巨人", monsterType = "golem",
        level = 15, hp = 1600, atk = 35, def = 22,
        speed = 1.2, chaseRange = 10, attackRange = 3.0, attackCD = 3.0,
        exp = 600, scale = 2.5, tier = "boss",
    },
    {
        name = "九幽骨龙", monsterType = "serpent",
        level = 30, hp = 3200, atk = 60, def = 26,
        speed = 2.2, chaseRange = 16, attackRange = 3.5, attackCD = 2.0,
        exp = 1500, scale = 2.8, tier = "boss",
    },
    {
        name = "炎魔领主", monsterType = "golem",
        level = 45, hp = 5000, atk = 80, def = 32,
        speed = 1.8, chaseRange = 14, attackRange = 3.5, attackCD = 2.5,
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
local killCount = 0
local spawnTimer = 0
local SPAWN_INTERVAL = 1.8
local MAX_ENEMIES = 25

Combat.enemies = enemies
Combat.projectiles = projectiles
Combat.killCount = 0

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
    local bones, buildOrder = MonsterSkeleton.CreateSkeleton(skelRoot, def.monsterType)

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
        speed = def.speed,
        chaseRange = def.chaseRange,
        attackRange = def.attackRange,
        attackCD = def.attackCD,
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

        -- DOT 伤害 (施毒术)
        if e.dotTimer > 0 then
            e.dotTimer = e.dotTimer - dt
            e.hp = e.hp - e.dotDamage * dt
            if e.dotTimer <= 0 then
                e.dotDamage = 0
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

        -- 死亡检测（调用统一死亡函数）
        if e.hp <= 0 then
            Combat.TriggerDeath(e, player)
            goto continue
        end

        -- 状态机
        e.attackTimer = math.max(0, e.attackTimer - dt)

        local eBody = e.node:GetComponent("RigidBody")
        local isMoving = false

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
                    local angle = math.atan2(dir.x, dir.z)
                    e.node.rotation = Quaternion(math.deg(angle), Vector3.UP)
                    isMoving = true
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
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            else
                local dir = (chaseTargetPos - pos)
                dir.y = 0
                dir = dir:Normalized()
                if eBody then
                    eBody:SetLinearVelocity(dir * e.speed)
                end
                local angle = math.atan2(dir.x, dir.z)
                e.node.rotation = Quaternion(math.deg(angle), Vector3.UP)
                isMoving = true
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
                local dir = (targetPos - pos)
                dir.y = 0
                if dir:Length() > 0.1 then
                    dir = dir:Normalized()
                    local angle = math.atan2(dir.x, dir.z)
                    e.node.rotation = Quaternion(math.deg(angle), Vector3.UP)
                end

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

        -- 更新骨架动画
        if e.animData then
            MonsterSkeleton.UpdateAnimation(e.animData, dt, isMoving)
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

    -- 寻找最近的敌人(自动瞄准)
    local target, targetDist = Combat.FindNearestEnemy(playerPos, skill.range or 5)

    if skill.type == SKILL_TYPE.MELEE then
        -- 近战：ATK × 倍率百分比
        local dmg = player.atk * (skill.damage / 100)
        local hitCount = 0
        for _, e in ipairs(enemies) do
            if e.state ~= "dead" and e.state ~= "dying" then
                local d = (e.node.position - playerPos):Length()
                if d <= skill.range then
                    -- 半月弯刀：检查角度，仅命中前方半月范围
                    if skill.aoeAngle then
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
                    else
                        Combat.DealDamage(e, dmg, player)
                        hitCount = hitCount + 1
                        if hitCount >= 1 then break end
                    end
                end
            end
        end
        -- 技能专属视觉效果
        if skill.aoeAngle then
            -- 半月弯刀：前方弧形光斩
            Combat.SpawnCrescentVisual(scene, playerPos, playerDir, skill.range, player.classId)
        elseif skill.id == "w_fire" then
            -- 烈火剑法：焰刃纵斩 + 地面火浪
            Combat.SpawnFireSlashVisual(scene, playerPos, playerDir, skill.range)
        elseif skill.id == "w_basic" then
            -- 基本剑术：快速剑弧闪光
            Combat.SpawnSlashVisual(scene, playerPos, playerDir, player.classId)
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

        Combat.SpawnProjectile(scene, playerPos + Vector3(0, 0.8, 0), dir, dmg, skill, player)
        return true, "ranged"

    elseif skill.type == SKILL_TYPE.AOE then
        -- 范围：ATK × 倍率百分比
        local dmg = player.atk * (skill.damage / 100)
        local radius = skill.aoeRadius or skill.range

        -- 如果有目标，以目标为中心；否则以玩家前方为中心
        local center = playerPos
        if target then
            center = target.node.position
        else
            center = playerPos + playerDir * (radius * 0.5)
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

        if skill.id == "t_poison" and target then
            -- 施毒术：单体 DOT + 减防
            target.dotDamage = dps
            target.dotTimer = dur
            target.defReduction = skill.defReduce or 0
            target.defReductionTimer = dur
            -- 转向目标
            local dir = target.node.position - playerPos
            dir.y = 0
            dir = dir:Normalized()
            local angle = math.atan2(dir.x, dir.z)
            playerNode.rotation = Quaternion(math.deg(angle), Vector3.UP)
        else
            -- 火墙：范围 DOT
            local center = playerPos + playerDir * 4
            if target then center = target.node.position end
            local radius = skill.aoeRadius or 2.0
            table.insert(aoeZones, {
                center = center,
                radius = radius,
                dps = dps,
                timer = dur,
                ownerId = "player",
                visualNode = Combat.SpawnAOEVisual(scene, center, radius, player.classId, skill.id),
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
        -- 治疗
        local healPct = skill.healPercent
        local healAmount = player.maxHP * healPct / 100
        if skill.aoeRadius then
            -- 群体治疗 (目前单人游戏只治自己)
            player.hp = math.min(player.maxHP, player.hp + healAmount)
        else
            player.hp = math.min(player.maxHP, player.hp + healAmount)
        end
        if Combat.onPlayerHeal then
            Combat.onPlayerHeal(healAmount, playerPos)
        end
        return true, "heal"

    elseif skill.type == SKILL_TYPE.DASH then
        -- 冲撞：ATK × 倍率百分比
        local dmg = player.atk * (skill.damage / 100)

        local dir = playerDir
        if target then
            dir = target.node.position - playerPos
            dir.y = 0
            dir = dir:Normalized()
            local angle = math.atan2(dir.x, dir.z)
            playerNode.rotation = Quaternion(math.deg(angle), Vector3.UP)
        end

        -- 瞬移到前方
        local dashDist = math.min(skill.range, 5.0)
        local startPos = playerPos
        playerNode.position = playerPos + dir * dashDist

        -- 对冲撞路径上的敌人造成伤害
        for _, e in ipairs(enemies) do
            if e.state ~= "dead" and e.state ~= "dying" then
                local ePos = e.node.position
                -- 简化：在终点范围内都算命中
                local d = (ePos - playerNode.position):Length()
                if d <= 2.0 then
                    Combat.DealDamage(e, dmg, player)
                end
            end
        end

        -- 野蛮冲撞视觉效果：冲撞轨迹 + 落点震波
        Combat.SpawnDashTrailVisual(scene, startPos, playerNode.position, dir)
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
function Combat.DealDamage(enemy, baseDmg, player)
    if enemy.state == "dying" or enemy.state == "dead" then return end

    local effectiveDef = math.max(0, enemy.def - enemy.defReduction)
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

    -- ========== 武士 - 刺杀剑术：锋锐穿刺剑气（菱形剑尖+十字截面+能量尾流）==========
    if skillId == "w_thrust" then
        -- 朝向飞行方向
        local angle = math.atan2(dir.x, dir.z)
        projNode.rotation = Quaternion(math.deg(angle), Vector3.UP)

        -- 核心剑尖：窄长菱形（Z 极长，XY 扁平）模拟剑刃穿刺形态
        local bladeNode = projNode:CreateChild("blade")
        bladeNode.scale = Vector3(0.05, 0.12, 1.0)  -- 极扁极长
        local bladeModel = bladeNode:CreateComponent("StaticModel")
        bladeModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local bladeMat = Material:new()
        bladeMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        bladeMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.95, 0.8, 0.95)))
        bladeMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.85, 0.5)))
        bladeMat:SetShaderParameter("Metallic", Variant(0.9))
        bladeMat:SetShaderParameter("Roughness", Variant(0.0))
        bladeModel:SetMaterial(bladeMat)
        bladeModel.castShadows = false

        -- 十字截面第二片：旋转90度再来一片
        local crossNode = projNode:CreateChild("cross")
        crossNode.rotation = Quaternion(90, Vector3.FORWARD)
        crossNode.scale = Vector3(0.05, 0.12, 1.0)
        local crossModel = crossNode:CreateComponent("StaticModel")
        crossModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        crossModel:SetMaterial(bladeMat)
        crossModel.castShadows = false

        -- 外层能量护鞘：半透明金色菱形光芒，略大于剑身
        local sheathNode = projNode:CreateChild("sheath")
        sheathNode.scale = Vector3(0.15, 0.15, 1.2)
        local sheathModel = sheathNode:CreateComponent("StaticModel")
        sheathModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local sheathMat = Material:new()
        sheathMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        sheathMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.8, 0.3, 0.2)))
        sheathMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.9, 0.7, 0.2)))
        sheathMat:SetShaderParameter("Metallic", Variant(0.0))
        sheathMat:SetShaderParameter("Roughness", Variant(0.3))
        sheathModel:SetMaterial(sheathMat)
        sheathModel.castShadows = false

        -- 尾流拖痕：三个递次缩小的半透明方块（模拟残影）
        for ti = 1, 3 do
            local trailNode = projNode:CreateChild("trail" .. ti)
            trailNode.position = Vector3(0, 0, -0.4 * ti)  -- 依次向后
            local s = 0.08 / ti
            trailNode.scale = Vector3(s, s * 1.5, 0.2)
            local tModel = trailNode:CreateComponent("StaticModel")
            tModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            local tMat = Material:new()
            tMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            tMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.7, 0.2, 0.4 / ti)))
            tMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.5, 0.1)))
            tMat:SetShaderParameter("Metallic", Variant(0.0))
            tMat:SetShaderParameter("Roughness", Variant(0.5))
            tModel:SetMaterial(tMat)
            tModel.castShadows = false
        end

    -- ========== 法师 - 火球术：橙红火焰球 ==========
    elseif skillId == "m_fireball" then
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

    -- ========== 法师 - 雷电术：黄白闪电球 ==========
    elseif skillId == "m_thunder" then
        projNode.scale = Vector3(0.3, 0.3, 0.3)
        local model = projNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local thunderColor = Color(0.9, 0.9, 1.0, 1.0) -- 电弧白
        local mat = CreatePBR(thunderColor, 0.0, 0.1)
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.8, 1.0)))
        model:SetMaterial(mat)
        model.castShadows = false
        -- 电弧外层光晕
        local glowNode = projNode:CreateChild("glow")
        glowNode.scale = Vector3(1.6, 1.6, 1.6)
        local gModel = glowNode:CreateComponent("StaticModel")
        gModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local glowMat = Material:new()
        glowMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        glowMat:SetShaderParameter("MatDiffColor", Variant(Color(0.6, 0.5, 1.0, 0.25)))
        glowMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.5, 0.4, 1.0)))
        glowMat:SetShaderParameter("Metallic", Variant(0.0))
        glowMat:SetShaderParameter("Roughness", Variant(0.3))
        gModel:SetMaterial(glowMat)
        gModel.castShadows = false

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
                    hit = true
                    hitPos = e.node.position
                    break
                end
            end
        end

        if hit or p.traveled >= p.range then
            -- 命中时生成落点特效
            if hit and p.skillId == "m_thunder" then
                Combat.SpawnThunderStrikeVisual(scene, hitPos)
            end
            p.node:Remove()
            table.remove(projectiles, i)
        end
    end
end

-- ============================================================================
-- AOE 视觉效果（根据技能 ID 分化）
-- ============================================================================
function Combat.SpawnAOEVisual(scene, center, radius, classId, skillId)
    skillId = skillId or ""

    -- ========== 法师 - 地狱火：暗红火柱群 ==========
    if skillId == "m_hellfire" then
        local node = scene:CreateChild("AOEVisual")
        node.position = Vector3(center.x, 0.0, center.z)
        -- 中心火焰柱
        local pillarCount = 5
        for pi = 1, pillarCount do
            local angle = (pi / pillarCount) * math.pi * 2
            local dist = radius * 0.5 * (0.3 + math.random() * 0.7)
            local pillar = node:CreateChild("pillar" .. pi)
            pillar.position = Vector3(math.cos(angle) * dist, 0, math.sin(angle) * dist)
            local h = 1.0 + math.random() * 1.5
            pillar.scale = Vector3(0.2, h, 0.2)
            local pModel = pillar:CreateComponent("StaticModel")
            pModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            local fireColor = Color(0.85, 0.15, 0.0, 0.8)
            local mat = Material:new()
            mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            mat:SetShaderParameter("MatDiffColor", Variant(fireColor))
            mat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.2, 0.0)))
            mat:SetShaderParameter("Metallic", Variant(0.0))
            mat:SetShaderParameter("Roughness", Variant(0.3))
            pModel:SetMaterial(mat)
            pModel.castShadows = false
        end
        -- 地面烧焦圈
        local baseRing = node:CreateChild("baseRing")
        baseRing.position = Vector3(0, 0.03, 0)
        baseRing.scale = Vector3(radius * 2, 0.03, radius * 2)
        local bModel = baseRing:CreateComponent("StaticModel")
        bModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local darkMat = CreatePBR(Color(0.3, 0.05, 0.0, 0.6), 0.0, 0.8)
        darkMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.5, 0.08, 0.0)))
        bModel:SetMaterial(darkMat)
        bModel.castShadows = false
        node:SetVar("removeTimer", Variant(2.0))
        return node

    -- ========== 法师 - 爆裂火焰：橙红扩散火环 ==========
    elseif skillId == "m_explosion" then
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

    -- ========== 法师 - 冰咆哮：冰蓝暴风雪 ==========
    elseif skillId == "m_blizzard" then
        local node = scene:CreateChild("AOEVisual")
        node.position = Vector3(center.x, 0.0, center.z)
        -- 冰霜地面
        local iceBase = node:CreateChild("iceBase")
        iceBase.position = Vector3(0, 0.04, 0)
        iceBase.scale = Vector3(radius * 2, 0.04, radius * 2)
        local iModel = iceBase:CreateComponent("StaticModel")
        iModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local iceMat = Material:new()
        iceMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        iceMat:SetShaderParameter("MatDiffColor", Variant(Color(0.7, 0.85, 1.0, 0.5)))
        iceMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 0.6, 1.0)))
        iceMat:SetShaderParameter("Metallic", Variant(0.8))
        iceMat:SetShaderParameter("Roughness", Variant(0.1))
        iModel:SetMaterial(iceMat)
        iModel.castShadows = false
        -- 冰柱碎片（随机散落）
        for ci = 1, 6 do
            local shard = node:CreateChild("shard" .. ci)
            local sa = (ci / 6) * math.pi * 2 + math.random() * 0.5
            local sd = radius * (0.3 + math.random() * 0.6)
            shard.position = Vector3(math.cos(sa) * sd, 0.2 + math.random() * 0.5, math.sin(sa) * sd)
            shard.scale = Vector3(0.1, 0.3 + math.random() * 0.4, 0.1)
            shard.rotation = Quaternion(math.random() * 20 - 10, math.random() * 360, math.random() * 20 - 10)
            local sModel = shard:CreateComponent("StaticModel")
            sModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            local shardMat = CreatePBR(Color(0.8, 0.92, 1.0, 0.8), 0.9, 0.05)
            shardMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.5, 0.7, 1.0)))
            sModel:SetMaterial(shardMat)
            sModel.castShadows = false
        end
        node:SetVar("removeTimer", Variant(2.5))
        return node

    -- ========== 法师 - 火墙：暗红持续燃烧 ==========
    elseif skillId == "m_firewall" then
        local node = scene:CreateChild("AOEVisual")
        node.position = Vector3(center.x, 0.0, center.z)
        -- 火焰墙柱群（低矮密集）
        local wallCount = 8
        for wi = 1, wallCount do
            local wa = (wi / wallCount) * math.pi * 2
            local wd = radius * 0.6 * (0.5 + math.random() * 0.5)
            local flame = node:CreateChild("flame" .. wi)
            flame.position = Vector3(math.cos(wa) * wd, 0, math.sin(wa) * wd)
            local fh = 0.5 + math.random() * 0.8
            flame.scale = Vector3(0.15, fh, 0.15)
            local fModel = flame:CreateComponent("StaticModel")
            fModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
            local fireMat = Material:new()
            fireMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
            fireMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.3, 0.0, 0.7)))
            fireMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.9, 0.2, 0.0)))
            fireMat:SetShaderParameter("Metallic", Variant(0.0))
            fireMat:SetShaderParameter("Roughness", Variant(0.3))
            fModel:SetMaterial(fireMat)
            fModel.castShadows = false
        end
        -- 地面灼烧痕
        local burnBase = node:CreateChild("burnBase")
        burnBase.position = Vector3(0, 0.02, 0)
        burnBase.scale = Vector3(radius * 2, 0.02, radius * 2)
        local bModel = burnBase:CreateComponent("StaticModel")
        bModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local burnMat = CreatePBR(Color(0.2, 0.02, 0.0, 0.5), 0.0, 0.9)
        burnMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 0.05, 0.0)))
        bModel:SetMaterial(burnMat)
        bModel.castShadows = false
        node:SetVar("removeTimer", Variant(2.5))
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
    local segments = 24
    local halfAngle = math.rad(75)  -- 前方 150 度弧

    -- === 第一层：刀刃主体（窄且锋利，朱红色）===
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

    -- 朱红色金属刀光，高金属感
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.3, 0.08, 0.85)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.25, 0.0)))
    mat:SetShaderParameter("Metallic", Variant(0.7))
    mat:SetShaderParameter("Roughness", Variant(0.1))
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

    -- 外层气浪：橙黄半透明
    local outerMat = Material:new()
    outerMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    outerMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.55, 0.1, 0.25)))
    outerMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.35, 0.0)))
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
        tipMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.9, 0.4, 0.9)))
        tipMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.8, 0.2)))
        tipMat:SetShaderParameter("Metallic", Variant(0.0))
        tipMat:SetShaderParameter("Roughness", Variant(0.1))
        tModel:SetMaterial(tipMat)
        tModel.castShadows = false
    end

    node:SetVar("removeTimer", Variant(0.7))
    return node
end

-- ============================================================================
-- 基本剑术视觉效果：竖斜劈弧（从右上到左下的对角斩击）
-- 效果从武器位置发出，贴合挥刀动作的竖直平面
-- ============================================================================
function Combat.SpawnSlashVisual(scene, center, dir, classId)
    local node = scene:CreateChild("AOEVisual")
    -- 剑弧位于角色前方 0.6m，胸口高度 1.0m
    local fwd = Vector3(dir.x, 0, dir.z):Normalized()
    node.position = Vector3(center.x + fwd.x * 0.6, 1.0, center.z + fwd.z * 0.6)

    -- 让节点朝向角色前方
    local yaw = math.deg(math.atan2(fwd.x, fwd.z))
    node.rotation = Quaternion(yaw, Vector3.UP)

    -- === 内层：锋利刃光（窄、亮、白色金属质感）===
    local bladeGeom = node:CreateComponent("CustomGeometry")
    bladeGeom:BeginGeometry(0, TRIANGLE_LIST)

    -- 在节点局部坐标中绘制：X=左右，Y=上下，Z=前方
    -- 对角弧从右上(+X,+Y)扫到左下(-X,-Y)，弧心在(0,0,0.3)前方
    local segments = 16
    local arcRadius = 1.2          -- 斩击弧半径
    local startAngle = math.rad(-50)  -- 从右上开始
    local endAngle = math.rad(70)     -- 到左下结束（120度弧）
    local maxThick = 0.06            -- 锋刃厚度（很薄=锋利感）
    local offsetZ = 0.3              -- 向前偏移，贴近武器轨迹

    for i = 0, segments - 1 do
        local t0 = i / segments
        local t1 = (i + 1) / segments
        local a0 = startAngle + (endAngle - startAngle) * t0
        local a1 = startAngle + (endAngle - startAngle) * t1

        -- 中间最厚，两端收尖
        local taper0 = math.sin(t0 * math.pi)
        local taper1 = math.sin(t1 * math.pi)
        local thick0 = maxThick * taper0
        local thick1 = maxThick * taper1

        -- 外弧
        local ox0 = math.cos(a0) * arcRadius
        local oy0 = math.sin(a0) * arcRadius
        local ox1 = math.cos(a1) * arcRadius
        local oy1 = math.sin(a1) * arcRadius
        -- 内弧
        local ix0 = math.cos(a0) * (arcRadius - thick0)
        local iy0 = math.sin(a0) * (arcRadius - thick0)
        local ix1 = math.cos(a1) * (arcRadius - thick1)
        local iy1 = math.sin(a1) * (arcRadius - thick1)

        local n = Vector3(0, 0, 1)
        -- 三角形1
        bladeGeom:DefineVertex(Vector3(ix0, iy0, offsetZ))
        bladeGeom:DefineNormal(n)
        bladeGeom:DefineTexCoord(Vector2(t0, 0))
        bladeGeom:DefineVertex(Vector3(ox0, oy0, offsetZ))
        bladeGeom:DefineNormal(n)
        bladeGeom:DefineTexCoord(Vector2(t0, 1))
        bladeGeom:DefineVertex(Vector3(ox1, oy1, offsetZ))
        bladeGeom:DefineNormal(n)
        bladeGeom:DefineTexCoord(Vector2(t1, 1))
        -- 三角形2
        bladeGeom:DefineVertex(Vector3(ix0, iy0, offsetZ))
        bladeGeom:DefineNormal(n)
        bladeGeom:DefineTexCoord(Vector2(t0, 0))
        bladeGeom:DefineVertex(Vector3(ox1, oy1, offsetZ))
        bladeGeom:DefineNormal(n)
        bladeGeom:DefineTexCoord(Vector2(t1, 1))
        bladeGeom:DefineVertex(Vector3(ix1, iy1, offsetZ))
        bladeGeom:DefineNormal(n)
        bladeGeom:DefineTexCoord(Vector2(t1, 0))
    end
    bladeGeom:Commit()

    -- 锋刃材质：冷白色金属光泽
    local bladeMat = Material:new()
    bladeMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    bladeMat:SetShaderParameter("MatDiffColor", Variant(Color(0.95, 0.97, 1.0, 0.9)))
    bladeMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.85, 0.9, 1.0)))
    bladeMat:SetShaderParameter("Metallic", Variant(0.9))
    bladeMat:SetShaderParameter("Roughness", Variant(0.05))
    bladeGeom:SetMaterial(bladeMat)
    bladeGeom.castShadows = false

    -- === 外层：拖尾气流（宽、淡、半透明淡蓝）===
    local trailChild = node:CreateChild("trail")
    local trailGeom = trailChild:CreateComponent("CustomGeometry")
    trailGeom:BeginGeometry(0, TRIANGLE_LIST)

    local trailRadius = 1.35
    local trailThick = 0.25  -- 气流比刃宽很多

    for i = 0, segments - 1 do
        local t0 = i / segments
        local t1 = (i + 1) / segments
        local a0 = startAngle + (endAngle - startAngle) * t0
        local a1 = startAngle + (endAngle - startAngle) * t1

        local taper0 = math.sin(t0 * math.pi)
        local taper1 = math.sin(t1 * math.pi)
        local thick0 = trailThick * taper0
        local thick1 = trailThick * taper1

        local ox0 = math.cos(a0) * trailRadius
        local oy0 = math.sin(a0) * trailRadius
        local ox1 = math.cos(a1) * trailRadius
        local oy1 = math.sin(a1) * trailRadius
        local ix0 = math.cos(a0) * (trailRadius - thick0)
        local iy0 = math.sin(a0) * (trailRadius - thick0)
        local ix1 = math.cos(a1) * (trailRadius - thick1)
        local iy1 = math.sin(a1) * (trailRadius - thick1)

        local n = Vector3(0, 0, 1)
        trailGeom:DefineVertex(Vector3(ix0, iy0, offsetZ - 0.05))
        trailGeom:DefineNormal(n)
        trailGeom:DefineTexCoord(Vector2(t0, 0))
        trailGeom:DefineVertex(Vector3(ox0, oy0, offsetZ - 0.05))
        trailGeom:DefineNormal(n)
        trailGeom:DefineTexCoord(Vector2(t0, 1))
        trailGeom:DefineVertex(Vector3(ox1, oy1, offsetZ - 0.05))
        trailGeom:DefineNormal(n)
        trailGeom:DefineTexCoord(Vector2(t1, 1))

        trailGeom:DefineVertex(Vector3(ix0, iy0, offsetZ - 0.05))
        trailGeom:DefineNormal(n)
        trailGeom:DefineTexCoord(Vector2(t0, 0))
        trailGeom:DefineVertex(Vector3(ox1, oy1, offsetZ - 0.05))
        trailGeom:DefineNormal(n)
        trailGeom:DefineTexCoord(Vector2(t1, 1))
        trailGeom:DefineVertex(Vector3(ix1, iy1, offsetZ - 0.05))
        trailGeom:DefineNormal(n)
        trailGeom:DefineTexCoord(Vector2(t1, 0))
    end
    trailGeom:Commit()

    -- 气流拖尾材质：淡蓝半透明
    local trailMat = Material:new()
    trailMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    trailMat:SetShaderParameter("MatDiffColor", Variant(Color(0.7, 0.8, 1.0, 0.3)))
    trailMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.4, 0.5, 0.7)))
    trailMat:SetShaderParameter("Metallic", Variant(0.0))
    trailMat:SetShaderParameter("Roughness", Variant(0.5))
    trailGeom:SetMaterial(trailMat)
    trailGeom.castShadows = false

    node:SetVar("removeTimer", Variant(0.35))
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
-- 野蛮冲撞视觉效果：冲撞轨迹残影 + 落点震波
-- ============================================================================
function Combat.SpawnDashTrailVisual(scene, startPos, endPos, dir)
    -- 冲撞轨迹：沿路线放置若干残影
    local dist = (endPos - startPos):Length()
    local trailCount = math.max(3, math.floor(dist / 1.0))
    for ti = 1, trailCount do
        local t = ti / (trailCount + 1)
        local pos = startPos + (endPos - startPos) * t
        local trailNode = scene:CreateChild("AOEVisual")
        trailNode.position = Vector3(pos.x, 0.5, pos.z)
        trailNode.scale = Vector3(0.3, 0.8, 0.3)
        local model = trailNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        -- 朱红色残影，越远越淡
        local alpha = 0.6 * (1.0 - t * 0.5)
        local trailMat = Material:new()
        trailMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        trailMat:SetShaderParameter("MatDiffColor", Variant(Color(0.85, 0.2, 0.1, alpha)))
        trailMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.7, 0.15, 0.05)))
        trailMat:SetShaderParameter("Metallic", Variant(0.0))
        trailMat:SetShaderParameter("Roughness", Variant(0.4))
        model:SetMaterial(trailMat)
        model.castShadows = false
        trailNode:SetVar("removeTimer", Variant(0.6 + t * 0.3))
    end

    -- 落点震波环
    local impactNode = scene:CreateChild("AOEVisual")
    impactNode.position = Vector3(endPos.x, 0.05, endPos.z)
    impactNode.scale = Vector3(2.5, 0.06, 2.5)
    local impModel = impactNode:CreateComponent("StaticModel")
    impModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local impMat = Material:new()
    impMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    impMat:SetShaderParameter("MatDiffColor", Variant(Color(0.9, 0.3, 0.05, 0.5)))
    impMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.2, 0.0)))
    impMat:SetShaderParameter("Metallic", Variant(0.0))
    impMat:SetShaderParameter("Roughness", Variant(0.3))
    impModel:SetMaterial(impMat)
    impModel.castShadows = false
    impactNode:SetVar("removeTimer", Variant(1.0))
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

    -- 设置移除时间为护盾持续时间
    shieldNode:SetVar("removeTimer", Variant(math.min(duration, 4.0)))
end

-- ============================================================================
-- 雷电术落点效果：闪电柱（命中时生成）
-- ============================================================================
function Combat.SpawnThunderStrikeVisual(scene, pos)
    local node = scene:CreateChild("AOEVisual")
    node.position = Vector3(pos.x, 0, pos.z)

    -- 闪电柱（垂直光柱从天而降）
    local boltNode = node:CreateChild("bolt")
    boltNode.position = Vector3(0, 3.0, 0)
    boltNode.scale = Vector3(0.12, 6.0, 0.12)
    local bModel = boltNode:CreateComponent("StaticModel")
    bModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local boltMat = Material:new()
    boltMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    boltMat:SetShaderParameter("MatDiffColor", Variant(Color(0.9, 0.85, 1.0, 0.8)))
    boltMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.7, 1.0)))
    boltMat:SetShaderParameter("Metallic", Variant(0.0))
    boltMat:SetShaderParameter("Roughness", Variant(0.1))
    bModel:SetMaterial(boltMat)
    bModel.castShadows = false

    -- 落点光环
    local glowNode = node:CreateChild("glow")
    glowNode.position = Vector3(0, 0.05, 0)
    glowNode.scale = Vector3(1.5, 0.05, 1.5)
    local gModel = glowNode:CreateComponent("StaticModel")
    gModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local glowMat = Material:new()
    glowMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    glowMat:SetShaderParameter("MatDiffColor", Variant(Color(0.7, 0.6, 1.0, 0.4)))
    glowMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.6, 0.5, 1.0)))
    glowMat:SetShaderParameter("Metallic", Variant(0.0))
    glowMat:SetShaderParameter("Roughness", Variant(0.2))
    gModel:SetMaterial(glowMat)
    gModel.castShadows = false

    node:SetVar("removeTimer", Variant(0.8))
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
            -- 对区域内敌人造成持续伤害
            for _, e in ipairs(enemies) do
                if e.state ~= "dead" and e.state ~= "dying" then
                    local d2 = (e.node.position - zone.center):Length()
                    if d2 <= zone.radius then
                        e.hp = e.hp - zone.dps * dt
                        e.hitFlashTimer = 0.1
                        if e.state == "patrol" then e.state = "chase" end
                        -- AOE 也触发死亡
                        if e.hp <= 0 then
                            Combat.TriggerDeath(e, player)
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
        if child.name == "AOEVisual" or child.name == "CrescentVisual" then
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
            -- 渐隐效果：缩小 + 透明（护盾不缩小，只计时）
            if child:GetParent() == scene then
                local s = child.scale
                child.scale = s * (1.0 - dt * 0.8)
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
    if #enemies > 15 then
        dynamicInterval = SPAWN_INTERVAL * 2  -- 场上怪多时放慢
    elseif #enemies < 5 then
        dynamicInterval = SPAWN_INTERVAL * 0.5  -- 场上怪少时加快
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

--- 总更新入口
function Combat.Update(scene, dt, playerNode, player)
    Combat.UpdateEnemies(dt, playerNode, player)
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
