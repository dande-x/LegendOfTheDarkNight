---@diagnostic disable: access-invisible
-- ============================================================================
-- Combat.lua — 传奇·山海 战斗系统 + 敌人 AI
-- 伤害计算 / 技能释放 / 弹道投射 / 敌人生成巡逻追击
-- ============================================================================

local CharacterClass = require("scripts.CharacterClass")
local MonsterSkeleton = require("scripts.MonsterSkeleton")

local Combat = {}

local C = CharacterClass.Colors
local SKILL_TYPE = CharacterClass.SKILL_TYPE

-- ============================================================================
-- 敌人配置（5种传奇怪物 + 骨架类型）
-- ============================================================================
local ENEMY_DEFS = {
    {
        name = "鹿",     monsterType = "deer",
        level = 1,  hp = 80,   atk = 8,  def = 3,
        speed = 3.0, chaseRange = 8, attackRange = 1.5, attackCD = 2.0,
        exp = 40, scale = 0.9,
    },
    {
        name = "稻草人", monsterType = "scarecrow",
        level = 2,  hp = 120,  atk = 12, def = 4,
        speed = 2.2, chaseRange = 7, attackRange = 1.8, attackCD = 1.8,
        exp = 60, scale = 1.0,
    },
    {
        name = "骷髅",   monsterType = "skeleton",
        level = 3,  hp = 160,  atk = 16, def = 6,
        speed = 2.6, chaseRange = 10, attackRange = 1.5, attackCD = 1.5,
        exp = 90, scale = 0.95,
    },
    {
        name = "蜘蛛",   monsterType = "spider",
        level = 4,  hp = 140,  atk = 18, def = 5,
        speed = 3.5, chaseRange = 12, attackRange = 1.3, attackCD = 1.2,
        exp = 100, scale = 0.85,
    },
    {
        name = "半兽人", monsterType = "orc",
        level = 5,  hp = 300,  atk = 24, def = 12,
        speed = 2.0, chaseRange = 8, attackRange = 1.8, attackCD = 2.2,
        exp = 150, scale = 1.1,
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
-- 敌人创建（使用 MonsterSkeleton 骨架系统）
-- ============================================================================
function Combat.SpawnEnemy(scene, playerPos, playerLevel)
    if #enemies >= MAX_ENEMIES then return end

    -- 根据玩家等级选取合适的敌人类型
    local validDefs = {}
    for _, def in ipairs(ENEMY_DEFS) do
        if def.level <= playerLevel + 3 then
            table.insert(validDefs, def)
        end
    end
    if #validDefs == 0 then validDefs = {ENEMY_DEFS[1]} end

    local def = validDefs[math.random(#validDefs)]

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

    -- 头顶名字标签（放在血条上方，3D世界空间缩放）
    local labelNode = enemyNode:CreateChild("NameLabel")
    labelNode.position = Vector3(0, 2.2 * def.scale, 0)
    labelNode.scale = Vector3(0.02, 0.02, 0.02)
    local text3D = labelNode:CreateComponent("Text3D")
    text3D:SetFont(cache:GetResource("Font", "Fonts/MiSans-Regular.ttf"), 32)
    text3D:SetText(def.name .. " Lv." .. def.level)
    text3D:SetColor(Color(1.0, 0.9, 0.5, 1.0))
    text3D:SetAlignment(HA_CENTER, VA_BOTTOM)
    text3D:SetFaceCameraMode(FC_ROTATE_XYZ)
    text3D:SetTextEffect(TE_SHADOW)
    text3D:SetEffectColor(Color(0, 0, 0, 0.7))

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
        level = def.level,
        maxHP = def.hp,
        hp = def.hp,
        atk = def.atk,
        def = def.def,
        speed = def.speed,
        chaseRange = def.chaseRange,
        attackRange = def.attackRange,
        attackCD = def.attackCD,
        attackTimer = 0,
        exp = def.exp,
        state = "patrol",  -- patrol / chase / attack / dead / dying
        patrolTarget = nil,
        patrolWait = 0,
        hitFlashTimer = 0,
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

        -- 死亡检测 → 立即掉落 + 触发死亡动画
        if e.hp <= 0 then
            e.state = "dying"
            local deathDur = MonsterSkeleton.GetAnimDuration(e.monsterType, "death")
            e.dyingTimer = deathDur
            -- 停止物理移动
            local eBody = e.node:GetComponent("RigidBody")
            if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            -- 播放死亡动画
            if e.animData then
                MonsterSkeleton.PlayAnim(e.animData, "death", nil)
            end
            -- 立即触发掉落和经验
            killCount = killCount + 1
            Combat.killCount = killCount
            if player then
                player.exp = player.exp + e.exp
                while player.exp >= player.expToNext do
                    player.exp = player.exp - player.expToNext
                    CharacterClass.LevelUp(player)
                end
            end
            if Combat.onEnemyDeath then
                Combat.onEnemyDeath(e.name, e.node.position, e.exp)
            end
            goto continue
        end

        -- 状态机
        e.attackTimer = math.max(0, e.attackTimer - dt)

        local eBody = e.node:GetComponent("RigidBody")
        local isMoving = false

        if e.state == "patrol" then
            -- 巡逻：随机走动
            if dist < e.chaseRange then
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
            -- 追击玩家
            if dist > e.chaseRange * 1.5 then
                e.state = "patrol"
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            elseif dist <= e.attackRange then
                e.state = "attack"
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            else
                local dir = toPlayer:Normalized()
                if eBody then
                    eBody:SetLinearVelocity(dir * e.speed)
                end
                local angle = math.atan2(dir.x, dir.z)
                e.node.rotation = Quaternion(math.deg(angle), Vector3.UP)
                isMoving = true
            end

        elseif e.state == "attack" then
            -- 攻击玩家（站定攻击）
            if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end

            if dist > e.attackRange * 1.5 then
                e.state = "chase"
            else
                -- 面向玩家
                local dir = toPlayer:Normalized()
                local angle = math.atan2(dir.x, dir.z)
                e.node.rotation = Quaternion(math.deg(angle), Vector3.UP)

                if e.attackTimer <= 0 then
                    -- 播放攻击动画
                    if e.animData then
                        MonsterSkeleton.PlayAnim(e.animData, "attack", nil)
                    end
                    -- 造成伤害
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
        -- 近战：直接对范围内敌人造成伤害
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local dmg = skill.damage[slvl] + player.atk * 1.5
        local hitCount = 0
        for _, e in ipairs(enemies) do
            if e.state ~= "dead" then
                local d = (e.node.position - playerPos):Length()
                if d <= skill.range then
                    Combat.DealDamage(e, dmg, player)
                    hitCount = hitCount + 1
                    if not skill.aoeAngle and hitCount >= 1 then break end
                end
            end
        end
        return true, "melee"

    elseif skill.type == SKILL_TYPE.RANGED then
        -- 远程：发射弹道
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local dmg = skill.damage[slvl] + player.atk * 1.2

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
        -- 范围：对周围所有敌人造成伤害
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local dmg = skill.damage[slvl] + player.atk * 1.3
        local radius = skill.aoeRadius or skill.range

        -- 如果有目标，以目标为中心；否则以玩家前方为中心
        local center = playerPos
        if target then
            center = target.node.position
        else
            center = playerPos + playerDir * (radius * 0.5)
        end

        for _, e in ipairs(enemies) do
            if e.state ~= "dead" then
                local d = (e.node.position - center):Length()
                if d <= radius then
                    Combat.DealDamage(e, dmg, player)
                end
            end
        end

        -- AOE 视觉效果 (地面光环)
        Combat.SpawnAOEVisual(scene, center, radius, player.classId)
        return true, "aoe"

    elseif skill.type == SKILL_TYPE.DOT then
        -- 持续伤害 (施毒术 / 火墙)
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local dps = skill.damage[slvl]
        local dur = skill.duration[slvl]

        if skill.id == "t_poison" and target then
            -- 施毒术：单体 DOT + 减防
            target.dotDamage = dps
            target.dotTimer = dur
            target.defReduction = skill.defReduce and skill.defReduce[slvl] or 0
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
                visualNode = Combat.SpawnAOEVisual(scene, center, radius, player.classId),
            })
        end
        return true, "dot"

    elseif skill.type == SKILL_TYPE.BUFF then
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local dur = skill.duration[slvl]
        if skill.buffMultiplier then
            -- 万灵强化：提升所有召唤兽攻击力
            local mult = skill.buffMultiplier[slvl]
            for _, s in ipairs(summons) do
                s.atk = s.baseAtk * mult
                s.buffTimer = dur
            end
        elseif skill.shieldPercent then
            -- 护盾
            local shieldPct = skill.shieldPercent[slvl]
            player.shieldHP = player.maxHP * shieldPct / 100
            player.shieldTimer = dur
        end
        return true, "buff"

    elseif skill.type == SKILL_TYPE.HEAL then
        -- 治疗
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local healPct = skill.healPercent[slvl]
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
        -- 冲撞
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local dmg = skill.damage[slvl] + player.atk

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
        playerNode.position = playerPos + dir * dashDist

        -- 对冲撞路径上的敌人造成伤害
        for _, e in ipairs(enemies) do
            if e.state ~= "dead" then
                local ePos = e.node.position
                -- 简化：在终点范围内都算命中
                local d = (ePos - playerNode.position):Length()
                if d <= 2.0 then
                    Combat.DealDamage(e, dmg, player)
                end
            end
        end
        return true, "dash"

    elseif skill.type == SKILL_TYPE.SUMMON then
        -- 召唤兽（支持多只同时存在）
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local summonAtk = skill.damage[slvl]
        local dur = skill.duration[slvl]
        local count = skill.summonCount or 1
        local sType = skill.summonType or "normal"

        for ci = 1, count do
            local offset = Vector3((ci - 1) * 2 - (count - 1), 0, 1.5)
            Combat.SpawnSummon(scene, playerPos + offset, summonAtk, dur, skill.isUltimate, sType)
        end
        return true, "summon"
    end

    return false, "未知技能类型"
end

-- ============================================================================
-- 伤害计算
-- ============================================================================
function Combat.DealDamage(enemy, baseDmg, player)
    if enemy.state == "dying" or enemy.state == "dead" then return end

    local effectiveDef = math.max(0, enemy.def - enemy.defReduction)
    local dmg = math.max(1, baseDmg - effectiveDef * 0.5)

    -- 暴击 (10% 概率, 1.5 倍)
    local isCrit = math.random() < 0.10
    if isCrit then dmg = dmg * 1.5 end

    enemy.hp = enemy.hp - dmg
    enemy.hitFlashTimer = 0.15

    -- 播放受击动画（不打断死亡动画）
    if enemy.hp > 0 and enemy.animData and enemy.animData.state ~= "attack" then
        MonsterSkeleton.PlayAnim(enemy.animData, "hit", nil)
    end

    -- 被击中后立刻进入追击状态
    if enemy.state == "patrol" then
        enemy.state = "chase"
    end

    -- 回调飘字
    if Combat.onDamageDealt then
        Combat.onDamageDealt(dmg, isCrit, enemy.node.position)
    end
end

-- ============================================================================
-- 弹道系统
-- ============================================================================
function Combat.SpawnProjectile(scene, origin, dir, damage, skill, player)
    local projNode = scene:CreateChild("Projectile")
    projNode.position = origin
    projNode.scale = Vector3(0.2, 0.2, 0.2)

    local model = projNode:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))

    -- 弹道颜色基于职业
    local projColor = Color(1.0, 0.6, 0.2, 1.0)
    if player.classId == "mage" then
        projColor = Color(0.3, 0.6, 1.0, 1.0)
    elseif player.classId == "taoist" then
        projColor = Color(0.8, 0.8, 0.3, 1.0)
    end

    local mat = CreatePBR(projColor, 0.0, 0.3)
    mat:SetShaderParameter("MatEmissiveColor", Variant(projColor))
    model:SetMaterial(mat)

    table.insert(projectiles, {
        node = projNode,
        dir = dir,
        speed = skill.projectileSpeed or 12,
        damage = damage,
        range = skill.range or 8,
        traveled = 0,
    })
end

function Combat.UpdateProjectiles(dt)
    for i = #projectiles, 1, -1 do
        local p = projectiles[i]
        local move = p.dir * p.speed * dt
        p.node.position = p.node.position + move
        p.traveled = p.traveled + p.speed * dt

        -- 碰撞检测
        local hit = false
        for _, e in ipairs(enemies) do
            if e.state ~= "dead" then
                local d = (e.node.position - p.node.position):Length()
                if d < 1.0 then
                    Combat.DealDamage(e, p.damage, nil)
                    hit = true
                    break
                end
            end
        end

        if hit or p.traveled >= p.range then
            p.node:Remove()
            table.remove(projectiles, i)
        end
    end
end

-- ============================================================================
-- AOE 视觉效果
-- ============================================================================
function Combat.SpawnAOEVisual(scene, center, radius, classId)
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

    -- 自动移除 (2秒后)
    node:SetVar("removeTimer", Variant(2.0))
    return node
end

-- ============================================================================
-- AOE 持续区域更新
-- ============================================================================
function Combat.UpdateAOEZones(dt)
    for i = #aoeZones, 1, -1 do
        local zone = aoeZones[i]
        zone.timer = zone.timer - dt
        if zone.timer <= 0 then
            if zone.visualNode then zone.visualNode:Remove() end
            table.remove(aoeZones, i)
        else
            -- 对区域内敌人造成持续伤害
            for _, e in ipairs(enemies) do
                if e.state ~= "dead" then
                    local d2 = (e.node.position - zone.center):Length()
                    if d2 <= zone.radius then
                        e.hp = e.hp - zone.dps * dt
                        if e.state == "patrol" then e.state = "chase" end
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

function Combat.UpdateSummons(dt, playerNode)
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
                        Combat.DealDamage(nearestEnemy, s.atk, nil)
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
function Combat.UpdateVisuals(scene, dt)
    -- 清理 AOE 视觉效果
    local children = {}
    for i = 0, scene:GetNumChildren(false) - 1 do
        local child = scene:GetChild(i)
        if child.name == "AOEVisual" then
            table.insert(children, child)
        end
    end
    for _, child in ipairs(children) do
        local t = child:GetVar("removeTimer"):GetFloat()
        t = t - dt
        if t <= 0 then
            child:Remove()
        else
            child:SetVar("removeTimer", Variant(t))
            -- 渐隐效果：缩小
            local s = child.scale
            child.scale = s * (1.0 - dt * 0.5)
        end
    end
end

-- ============================================================================
-- 自动刷怪
-- ============================================================================
function Combat.UpdateSpawner(scene, dt, playerNode, player)
    if not playerNode or not player then return end
    spawnTimer = spawnTimer + dt
    if spawnTimer >= SPAWN_INTERVAL then
        spawnTimer = 0
        Combat.SpawnEnemy(scene, playerNode.position, player.level)
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
        if e.state ~= "dead" then
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
    Combat.UpdateProjectiles(dt)
    Combat.UpdateAOEZones(dt)
    Combat.UpdateSummons(dt, playerNode)
    Combat.UpdateVisuals(scene, dt)
    Combat.UpdateSpawner(scene, dt, playerNode, player)
    Combat.UpdateGroundItems(dt, playerNode)
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
end

-- 回调（由 main.lua 设置）
Combat.onDamageDealt = nil   -- function(dmg, isCrit, worldPos)
Combat.onEnemyAttack = nil   -- function(enemy, dmg, playerPos)
Combat.onPlayerHeal = nil    -- function(amount, playerPos)
Combat.onEnemyDeath = nil    -- function(enemyName, deathPos, exp)
Combat.onGoldPickup = nil    -- function(amount, worldPos)
Combat.onItemPickup = nil    -- function(item, worldPos)

return Combat
