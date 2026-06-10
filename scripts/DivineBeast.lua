-- ============================================================================
-- DivineBeast.lua — 神兽系统
-- 永久随从，喷火攻击，可升级，名字颜色随等级变化
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
-- 神兽状态 (单例 — 只有一只)
-- ============================================================================
---@class DivineBeastState
---@field alive boolean
---@field node Node|nil
---@field level integer
---@field exp integer
---@field expToNext integer
---@field maxHP integer
---@field hp integer
---@field atk integer
---@field def integer
---@field baseAtk integer
---@field speed number
---@field attackCD number
---@field attackTimer number
---@field attackRange number
---@field chaseRange number
---@field state string
---@field buffTimer number
---@field buffMult number
---@field fireTimer number
---@field hitFlashTimer number
local beast = {
    alive = false,
    node = nil,
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
    attackRange = 4.0,
    chaseRange = 8.0,
    state = "follow",  -- follow / chase / attack
    buffTimer = 0,
    buffMult = 1.0,
    fireTimer = 0,
    hitFlashTimer = 0,
    facingDir = 1,  -- 1 = forward(back sprite), -1 = backward(front sprite)
}

DivineBeast.beast = beast

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
    beast.baseAtk = math.floor(playerAtk * 1.5)  -- 150% 玩家ATK
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
    beast.facingDir = 1

    -- 创建节点
    local beastNode = scene:CreateChild("DivineBeast")
    beastNode.position = playerPos + Vector3(2, 0, 2)

    -- 使用 BillboardSet 来渲染精灵图 (面朝相机)
    local bbSet = beastNode:CreateComponent("BillboardSet")
    bbSet:SetNumBillboards(1)
    bbSet:SetFaceCameraMode(FC_ROTATE_Y)  -- 只绕Y轴旋转面向相机
    bbSet.sorted = true

    -- 加载纹理
    local tex = cache:GetResource("Texture2D", "image/divine_beast.png")
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/DiffAlpha.xml"))
    mat:SetTexture(0, tex)  -- TU_DIFFUSE = 0
    mat:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1)))
    bbSet:SetMaterial(mat)

    -- 设置 billboard 尺寸和位置
    -- 图片是正面+背面并排，需要用 UV 来选择显示哪半
    -- 初始显示背面（左半部分 = 背面面朝玩家方向行走时看到的）
    local bb = bbSet:GetBillboard(0)
    bb.position = Vector3(0, 1.2, 0)  -- 提升到地面以上
    bb.size = Vector2(2.0, 2.4)       -- 宽高(米)
    bb.uv = Rect(0.0, 0.0, 0.5, 1.0) -- 左半=背面
    bb.enabled = true
    bb.color = Color(1, 1, 1, 1)
    bbSet:Commit()

    -- 物理碰撞体
    local rbody = beastNode:CreateComponent("RigidBody")
    rbody.mass = 1.0
    rbody.collisionLayer = 2          -- 玩家层（不被玩家攻击）
    rbody.collisionMask = 1 | 4       -- 与地形和AI碰撞
    rbody.angularFactor = Vector3(0, 0, 0)
    rbody.linearFactor = Vector3(1, 0, 1)
    rbody.friction = 0.5
    rbody.linearDamping = 0.1
    local shape = beastNode:CreateComponent("CollisionShape")
    shape:SetCapsule(1.2, 2.2, Vector3(0, 1.1, 0))

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

    -- 防御减伤
    local effectiveDmg = dmg * (100 / (100 + beast.def))
    effectiveDmg = math.max(1, math.floor(effectiveDmg))

    beast.hp = beast.hp - effectiveDmg
    beast.hitFlashTimer = 0.2

    if beast.hp <= 0 then
        beast.hp = 0
        DivineBeast.Die()
    end

    return effectiveDmg
end

-- ============================================================================
-- 神兽死亡
-- ============================================================================
function DivineBeast.Die()
    if not beast.alive then return end
    beast.alive = false
    if beast.node then
        beast.node:Remove()
        beast.node = nil
    end
    print("[DivineBeast] 神兽阵亡！可重新召唤")
end

-- ============================================================================
-- 神兽获得经验（杀怪时调用）
-- ============================================================================
function DivineBeast.AddExp(amount)
    if not beast.alive then return end
    if beast.level >= 7 then return end -- 满级

    -- 被动加成：经验 +20%
    amount = math.floor(amount * 1.2)
    beast.exp = beast.exp + amount

    -- 升级检查
    while beast.exp >= beast.expToNext and beast.level < 7 do
        beast.exp = beast.exp - beast.expToNext
        beast.level = beast.level + 1
        beast.expToNext = LEVEL_EXP[beast.level] or 999999

        -- 成长
        beast.maxHP = 300 + BEAST_GROWTH.hp_per_level * (beast.level - 1)
        beast.baseAtk = beast.baseAtk + BEAST_GROWTH.atk_per_level
        beast.atk = math.floor(beast.baseAtk * beast.buffMult)
        beast.def = 8 + BEAST_GROWTH.def_per_level * (beast.level - 1)

        -- 升级回满血
        beast.hp = beast.maxHP

        print("[DivineBeast] 神兽升级! Lv." .. beast.level ..
              " HP=" .. beast.maxHP .. " ATK=" .. beast.atk .. " DEF=" .. beast.def)
    end
end

-- ============================================================================
-- 神兽强化 Buff（神兽狂暴技能）
-- ============================================================================
function DivineBeast.ApplyBuff(multiplier, duration)
    if not beast.alive then return end
    beast.buffMult = multiplier
    beast.buffTimer = duration
    beast.atk = math.floor(beast.baseAtk * beast.buffMult)
    beast.attackCD = 1.2  -- 攻速提升
    print("[DivineBeast] 神兽狂暴! ATK=" .. beast.atk .. " 持续" .. duration .. "秒")
end

-- ============================================================================
-- 获取名字颜色
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
-- 更新 UV 面向（根据相对玩家位置切换正面/背面精灵）
-- ============================================================================
local function UpdateFacing(beastPos, targetPos)
    if not beast.node then return end

    local bbSet = beast.node:GetComponent("BillboardSet")
    if not bbSet then return end

    local bb = bbSet:GetBillboard(0)
    if not bb then return end

    -- 判断神兽相对运动方向：朝向目标时显示背面，远离时显示正面
    local dir = targetPos - beastPos
    dir.y = 0
    if dir:Length() < 0.1 then return end

    -- 这里简单处理：如果神兽在向前方移动（面对远方），显示背面
    -- 正面 = 右半 UV(0.5, 0, 1.0, 1.0)
    -- 背面 = 左半 UV(0.0, 0, 0.5, 1.0)
    -- 由于是俯视角相机且billboard面向相机，当神兽远离相机时显示背面
    -- 简化：始终显示背面（行走时看到的都是背面）
    bb.uv = Rect(0.0, 0.0, 0.5, 1.0)  -- 背面
    bbSet:Commit()
end

-- ============================================================================
-- 喷火攻击视觉
-- ============================================================================
local fireProjectiles = {}

local function SpawnFireBreath(scene, beastPos, targetPos)
    local dir = targetPos - beastPos
    dir.y = 0
    if dir:Length() < 0.1 then return end
    dir = dir:Normalized()

    local fireNode = scene:CreateChild("BeastFire")
    fireNode.position = beastPos + Vector3(0, 1.0, 0) + dir * 0.8
    fireNode.scale = Vector3(0.35, 0.35, 0.35)

    local model = fireNode:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))

    -- 橙红色火球
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.4, 0.1, 1.0)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.0, 0.5, 0.1)))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    mat:SetShaderParameter("Roughness", Variant(0.2))
    model:SetMaterial(mat)
    model.castShadows = false

    table.insert(fireProjectiles, {
        node = fireNode,
        dir = dir,
        speed = 10,
        damage = beast.atk,
        traveled = 0,
        maxRange = beast.attackRange + 2,
    })
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
    if beast.hitFlashTimer > 0 then
        beast.hitFlashTimer = beast.hitFlashTimer - dt
        -- 闪烁效果：让 billboard 颜色周期变化
        local bbSet = beast.node:GetComponent("BillboardSet")
        if bbSet then
            local bb = bbSet:GetBillboard(0)
            if bb then
                if math.floor(beast.hitFlashTimer * 10) % 2 == 0 then
                    bb.color = Color(1, 0.4, 0.4, 1)  -- 红闪
                else
                    bb.color = Color(1, 1, 1, 1)
                end
                bbSet:Commit()
            end
        end
    else
        -- 确保颜色正常
        local bbSet = beast.node:GetComponent("BillboardSet")
        if bbSet then
            local bb = bbSet:GetBillboard(0)
            if bb and (bb.color.r < 0.99 or bb.color.g < 0.99) then
                bb.color = Color(1, 1, 1, 1)
                bbSet:Commit()
            end
        end
    end

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

    local moved = false

    if nearestEnemy and nearDist <= beast.chaseRange then
        -- 有敌人在追击范围内
        if nearDist <= beast.attackRange then
            -- 可以攻击
            beast.state = "attack"
            if rbody then rbody:SetLinearVelocity(Vector3.ZERO) end

            if beast.attackTimer <= 0 then
                -- 喷火攻击
                SpawnFireBreath(scene, beastPos, nearestEnemy.node.position)
                beast.attackTimer = beast.attackCD
            end

            UpdateFacing(beastPos, nearestEnemy.node.position)
        else
            -- 追击敌人
            beast.state = "chase"
            local dir = nearestEnemy.node.position - beastPos
            dir.y = 0
            dir = dir:Normalized()
            if rbody then rbody:SetLinearVelocity(dir * beast.speed) end
            UpdateFacing(beastPos, nearestEnemy.node.position)
            moved = true
        end
    else
        -- 没有敌人，跟随玩家
        beast.state = "follow"
        local toPlayer = playerPos - beastPos
        toPlayer.y = 0
        local distToPlayer = toPlayer:Length()

        if distToPlayer > 3.5 then
            local dir = toPlayer:Normalized()
            local followSpeed = beast.speed * 1.2  -- 跟随时稍快
            if rbody then rbody:SetLinearVelocity(dir * followSpeed) end
            UpdateFacing(beastPos, playerPos)
            moved = true
        else
            if rbody then rbody:SetLinearVelocity(Vector3.ZERO) end
        end

        -- 如果离玩家太远，传送过去
        if distToPlayer > 20 then
            beast.node.position = playerPos + Vector3(2, 0, 2)
        end
    end

    -- 更新火球弹道
    for i = #fireProjectiles, 1, -1 do
        local f = fireProjectiles[i]
        local move = f.dir * f.speed * dt
        f.node.position = f.node.position + move
        f.traveled = f.traveled + f.speed * dt

        -- 碰撞检测
        local hit = false
        if enemies then
            for _, e in ipairs(enemies) do
                if e.state ~= "dead" and e.state ~= "dying" then
                    local d = (e.node.position - f.node.position):Length()
                    if d < 1.2 then
                        -- 造成伤害
                        if dealDamageFn then
                            dealDamageFn(e, f.damage, player)
                        end
                        hit = true
                        break
                    end
                end
            end
        end

        if hit or f.traveled >= f.maxRange then
            f.node:Remove()
            table.remove(fireProjectiles, i)
        end
    end
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
    beast.hp = 0

    -- 清理火球
    for _, f in ipairs(fireProjectiles) do
        if f.node then f.node:Remove() end
    end
    fireProjectiles = {}
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
