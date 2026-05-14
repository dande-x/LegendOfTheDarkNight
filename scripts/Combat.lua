-- ============================================================================
-- Combat.lua — 传奇·山海 战斗系统 + 敌人 AI
-- 伤害计算 / 技能释放 / 弹道投射 / 敌人生成巡逻追击
-- ============================================================================

local CharacterClass = require("scripts.CharacterClass")

local Combat = {}

local C = CharacterClass.Colors
local SKILL_TYPE = CharacterClass.SKILL_TYPE

-- ============================================================================
-- 敌人配置
-- ============================================================================
local ENEMY_DEFS = {
    {
        name = "山贼",   level = 1,  hp = 120,  atk = 10, def = 4,
        speed = 2.2, chaseRange = 8, attackRange = 1.5, attackCD = 2.0,
        exp = 30, color = C.EnemyRed, scale = 0.9,
    },
    {
        name = "蛇妖",   level = 3,  hp = 200,  atk = 16, def = 6,
        speed = 2.5, chaseRange = 10, attackRange = 2.0, attackCD = 1.8,
        exp = 55, color = C.EnemyDark, scale = 1.0,
    },
    {
        name = "石魔",   level = 5,  hp = 350,  atk = 22, def = 12,
        speed = 1.8, chaseRange = 7, attackRange = 1.8, attackCD = 2.5,
        exp = 90, color = Color(0.35, 0.30, 0.28, 1.0), scale = 1.3,
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
local killCount = 0
local spawnTimer = 0
local SPAWN_INTERVAL = 4.0
local MAX_ENEMIES = 12

Combat.enemies = enemies
Combat.projectiles = projectiles
Combat.killCount = 0

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
-- 敌人创建
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
    local enemyNode = scene:CreateChild("Enemy_" .. tostring(#enemies + 1))
    enemyNode.position = spawnPos

    -- 身体 (圆柱体)
    local bodyNode = enemyNode:CreateChild("Body")
    bodyNode.scale = Vector3(0.6 * def.scale, 1.0 * def.scale, 0.6 * def.scale)
    bodyNode.position = Vector3(0, 0.5 * def.scale, 0)
    local bodyModel = bodyNode:CreateComponent("StaticModel")
    bodyModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    bodyModel:SetMaterial(CreatePBR(def.color, 0.05, 0.7))
    bodyModel.castShadows = true

    -- 头部 (球体)
    local headNode = enemyNode:CreateChild("Head")
    headNode.scale = Vector3(0.35 * def.scale, 0.35 * def.scale, 0.35 * def.scale)
    headNode.position = Vector3(0, 1.1 * def.scale, 0)
    local headModel = headNode:CreateComponent("StaticModel")
    headModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    headModel:SetMaterial(CreatePBR(def.color, 0.05, 0.6))
    headModel.castShadows = true

    local enemy = {
        node = enemyNode,
        name = def.name,
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
        state = "patrol",  -- patrol / chase / attack / dead
        patrolTarget = nil,
        patrolWait = 0,
        hitFlashTimer = 0,
        defReduction = 0,  -- 施毒术减防
        defReductionTimer = 0,
        dotDamage = 0,
        dotTimer = 0,
        bodyNode = bodyNode,
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
            if e.hitFlashTimer <= 0 and e.bodyNode then
                -- 恢复原色 (不做复杂处理)
            end
        end

        -- 死亡检测
        if e.hp <= 0 then
            e.state = "dead"
            e.node:Remove()
            table.remove(enemies, i)
            killCount = killCount + 1
            Combat.killCount = killCount
            -- 给玩家经验
            if player then
                player.exp = player.exp + e.exp
                if player.exp >= player.expToNext then
                    player.exp = player.exp - player.expToNext
                    CharacterClass.LevelUp(player)
                end
            end
            goto continue
        end

        -- 状态机
        e.attackTimer = math.max(0, e.attackTimer - dt)

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
                    dir:Normalize()
                    e.node.position = pos + dir * e.speed * 0.5 * dt
                    -- 朝向移动方向
                    local angle = math.atan2(dir.x, dir.z)
                    e.node.rotation = Quaternion(math.deg(angle), Vector3.UP)
                end
            end

        elseif e.state == "chase" then
            -- 追击玩家
            if dist > e.chaseRange * 1.5 then
                e.state = "patrol"
            elseif dist <= e.attackRange then
                e.state = "attack"
            else
                local dir = toPlayer
                dir:Normalize()
                e.node.position = pos + dir * e.speed * dt
                local angle = math.atan2(dir.x, dir.z)
                e.node.rotation = Quaternion(math.deg(angle), Vector3.UP)
            end

        elseif e.state == "attack" then
            -- 攻击玩家
            if dist > e.attackRange * 1.5 then
                e.state = "chase"
            else
                -- 面向玩家
                local dir = toPlayer
                dir:Normalize()
                local angle = math.atan2(dir.x, dir.z)
                e.node.rotation = Quaternion(math.deg(angle), Vector3.UP)

                if e.attackTimer <= 0 then
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

                    -- 返回伤害信息用于飘字
                    if Combat.onEnemyAttack then
                        Combat.onEnemyAttack(e, dmg, playerPos)
                    end
                end
            end
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
            dir:Normalize()
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
            dir:Normalize()
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
        -- 护盾
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local shieldPct = skill.shieldPercent[slvl]
        local dur = skill.duration[slvl]
        player.shieldHP = player.maxHP * shieldPct / 100
        player.shieldTimer = dur
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
            dir:Normalize()
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
        -- 召唤神兽
        local slvl = CharacterClass.GetSkillLevel(skill, player.level)
        local summonAtk = skill.damage[slvl]
        local dur = skill.duration[slvl]

        Combat.SpawnSummon(scene, playerPos, summonAtk, dur, skill.isUltimate)
        return true, "summon"
    end

    return false, "未知技能类型"
end

-- ============================================================================
-- 伤害计算
-- ============================================================================
function Combat.DealDamage(enemy, baseDmg, player)
    local effectiveDef = math.max(0, enemy.def - enemy.defReduction)
    local dmg = math.max(1, baseDmg - effectiveDef * 0.5)

    -- 暴击 (10% 概率, 1.5 倍)
    local isCrit = math.random() < 0.10
    if isCrit then dmg = dmg * 1.5 end

    enemy.hp = enemy.hp - dmg
    enemy.hitFlashTimer = 0.15

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
-- 召唤兽
-- ============================================================================
function Combat.SpawnSummon(scene, playerPos, atk, duration, isHoly)
    -- 移除旧的召唤兽
    for i = #summons, 1, -1 do
        if summons[i].node then summons[i].node:Remove() end
        table.remove(summons, i)
    end

    local summonNode = scene:CreateChild("Summon")
    summonNode.position = playerPos + Vector3(2, 0, 0)

    -- 身体
    local bodyNode = summonNode:CreateChild("Body")
    bodyNode.position = Vector3(0, 0.4, 0)
    bodyNode.scale = Vector3(0.5, 0.8, 0.5)
    local bodyModel = bodyNode:CreateComponent("StaticModel")
    bodyModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))

    local summonColor = isHoly and C.Gold or C.Jade
    local mat = CreatePBR(summonColor, 0.1, 0.5)
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(summonColor.r * 0.5, summonColor.g * 0.5, summonColor.b * 0.5)))
    bodyModel:SetMaterial(mat)
    bodyModel.castShadows = true

    -- 头部
    local headNode = summonNode:CreateChild("Head")
    headNode.position = Vector3(0, 1.0, 0)
    headNode.scale = Vector3(0.3, 0.3, 0.3)
    local headModel = headNode:CreateComponent("StaticModel")
    headModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    headModel:SetMaterial(mat)

    table.insert(summons, {
        node = summonNode,
        atk = atk,
        timer = duration,
        attackCD = 1.5,
        attackTimer = 0,
        isHoly = isHoly,
    })
    print("[Combat] Summoned " .. (isHoly and "圣兽" or "神兽") .. " ATK=" .. atk)
end

function Combat.UpdateSummons(dt, playerNode)
    if not playerNode then return end
    local playerPos = playerNode.position

    for i = #summons, 1, -1 do
        local s = summons[i]
        s.timer = s.timer - dt
        if s.timer <= 0 then
            s.node:Remove()
            table.remove(summons, i)
        else
            s.attackTimer = math.max(0, s.attackTimer - dt)

            -- 跟随玩家
            local sPos = s.node.position
            local toPlayer = playerPos - sPos
            toPlayer.y = 0
            local distToPlayer = toPlayer:Length()
            if distToPlayer > 3 then
                toPlayer:Normalize()
                s.node.position = sPos + toPlayer * 4.0 * dt
            end

            -- 攻击最近的敌人
            if s.attackTimer <= 0 then
                local nearestEnemy, nearDist = Combat.FindNearestEnemy(s.node.position, 4.0)
                if nearestEnemy then
                    Combat.DealDamage(nearestEnemy, s.atk, nil)
                    s.attackTimer = s.attackCD
                    -- 面向敌人
                    local dir = nearestEnemy.node.position - s.node.position
                    dir.y = 0
                    dir:Normalize()
                    local angle = math.atan2(dir.x, dir.z)
                    s.node.rotation = Quaternion(math.deg(angle), Vector3.UP)
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
    enemies = {}
    projectiles = {}
    summons = {}
    aoeZones = {}
    Combat.enemies = enemies
    Combat.projectiles = projectiles
    killCount = 0
    Combat.killCount = 0
    spawnTimer = 0
end

-- 回调（由 main.lua 设置）
Combat.onDamageDealt = nil  -- function(dmg, isCrit, worldPos)
Combat.onEnemyAttack = nil  -- function(enemy, dmg, playerPos)
Combat.onPlayerHeal = nil   -- function(amount, playerPos)

return Combat
