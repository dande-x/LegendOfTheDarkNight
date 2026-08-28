---@diagnostic disable: access-invisible
-- ============================================================================
-- Combat.lua — 暗夜传奇 战斗系统 + 敌人 AI
-- 伤害计算 / 技能释放 / 弹道投射 / 敌人生成巡逻追击
-- ============================================================================

local CharacterClass = require("scripts.CharacterClass")
local Balance = require("scripts.Balance")
local MonsterSkeleton = require("scripts.MonsterSkeleton")
local DivineBeast = require("scripts.DivineBeast")
local MonsterData = require("scripts.MonsterData")
-- `assets/` 与 `scripts/` 同时是资源根；根模块名确保命中 canonical
-- scripts/MapZone.lua，而不是旧的 assets/scripts 镜像。
local MapZone = require("MapZone")
local SoundManager = require("scripts.SoundManager")

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
-- 运行时 HP/ATK/DEF/EXP 由 Balance.GetMonsterStats 按实际等级派生；表内旧绝对
-- 数值仅保留为历史数据兼容，不再参与结算。个体微调使用 *Scale 字段。
-- tier: "normal"=普通, "elite"=精英(黄名), "boss"=Boss(红名)
-- ============================================================================
local ENEMY_DEFS = {
    -- === 低级区 1~10 ===
    {
        name = "鹿", monsterType = "deer",
        level = 1,  hp = 90,   atk = 8,  def = 3,
        speed = 3.0, chaseRange = 5.3, attackRange = 1.5, attackCD = 2.0,
        faceYawOffset = 0,
        exp = 30, scale = 0.9, tier = "normal",
    },
    {
        name = "幽灵", monsterType = "mech_humanoid",
        level = 3, hp = 180, atk = 16, def = 8,
        speed = 2.4, chaseRange = 6.7, attackRange = 1.65, attackCD = 1.9,
        exp = 62, scale = 1.0, tier = "normal",
    },
    {
        name = "稻草人", monsterType = "scarecrow",
        level = 2,  hp = 110,  atk = 10, def = 4,
        speed = 2.2, chaseRange = 4.7, attackRange = 1.5, attackCD = 1.8,
        exp = 40, scale = 1.0, tier = "normal",
    },
    {
        name = "骷髅",   monsterType = "skeleton",
        level = 4,  hp = 135,  atk = 14, def = 5,
        speed = 2.6, chaseRange = 6.7, attackRange = 1.5, attackCD = 1.5,
        exp = 55, scale = 1.08, tier = "normal",
    },
    {
        name = "毒蜘蛛", monsterType = "spider",
        level = 6,  hp = 120,  atk = 16, def = 4,
        speed = 3.5, chaseRange = 8.0, attackRange = 1.5, attackCD = 1.2,
        exp = 65, scale = 0.85, tier = "normal",
    },
    {
        name = "半兽人", monsterType = "orc",
        level = 8,  hp = 210,  atk = 20, def = 8,
        speed = 2.0, chaseRange = 5.3, attackRange = 1.5, attackCD = 2.2,
        exp = 90, scale = 1.1, tier = "normal",
    },
    -- === 中级区 10~25 ===
    {
        name = "狼",   monsterType = "wolf",
        level = 10, hp = 260,  atk = 24, def = 10,
        speed = 3.2, chaseRange = 8.0, attackRange = 1.5, attackCD = 1.5,
        exp = 120, scale = 1.15, tier = "normal",
    },
    {
        name = "石魔",   monsterType = "golem",
        level = 14, hp = 400,  atk = 28, def = 16,
        speed = 1.6, chaseRange = 5.3, attackRange = 1.5, attackCD = 2.5,
        exp = 180, scale = 1.6, tier = "normal",
    },
    {
        name = "蚁后", monsterType = "antqueen",
        -- 水上城市守关 Boss。最终属性由 Balance 的 Lv34 Boss 曲线派生，
        -- 衔接白野猪与终章沃玛教主。
        level = 34, hp = 900,  atk = 38, def = 16,
        speed = 3.4, chaseRange = 13.3, attackRange = 6.0, attackCD = 1.8,
        attackMode = "venom_spit", attackDamageScale = 0.95,
        encounterOffsetZ = 6.0, leashRange = 20.0, guardRadius = 2.4,
        exp = 480, scale = 1.8, tier = "boss",
    },
    {
        name = "骷髅将军", monsterType = "skeleton",
        -- 第三幕位于 Lv25~34 水上城市；旧值 Lv22 会被任务补池绕过地图
        -- 等级带，造成 UI 标注与实际怪物数据冲突。
        level = 26, hp = 500,  atk = 38, def = 14,
        speed = 2.4, chaseRange = 8.0, attackRange = 1.5, attackCD = 1.8,
        exp = 300, scale = 1.3, tier = "elite",
    },
    -- === 高级区 25~40 ===
    {
        name = "赤焰魔", monsterType = "golem",
        level = 28, hp = 750,  atk = 45, def = 20,
        speed = 2.0, chaseRange = 6.7, attackRange = 1.5, attackCD = 2.0,
        exp = 450, scale = 1.8, tier = "elite",
    },
    {
        name = "巨蟒",   monsterType = "serpent",
        level = 32, hp = 950,  atk = 50, def = 18,
        speed = 2.8, chaseRange = 9.3, attackRange = 1.5, attackCD = 1.8,
        exp = 550, scale = 2.0, tier = "elite",
    },
    {
        name = "噬魂兽", monsterType = "orc",
        level = 36, hp = 1100, atk = 55, def = 22,
        speed = 2.5, chaseRange = 8.0, attackRange = 1.5, attackCD = 1.5,
        exp = 700, scale = 1.5, tier = "elite",
    },
    {
        name = "麒麟", monsterType = "qilin",
        level = 38, hp = 1350, atk = 62, def = 24,
        speed = 2.6, chaseRange = 9.3, attackRange = 1.8, attackCD = 1.8,
        exp = 850, scale = 1.4, tier = "elite",
    },
    -- === Boss 区 (大型压迫感怪物) ===
    {
        name = "沃玛教主", monsterType = "golem",
        level = 44, hp = 1200, atk = 41, def = 18, hpScale = 0.80,
        speed = 2.4, chaseRange = 13.3, attackRange = 4.2, attackCD = 2.6,
        attackMode = "ground_slam", attackDamageScale = 1.08,
        leashRange = 21.3, guardRadius = 2.5,
        exp = 700, scale = 2.5, tier = "boss",
    },
    {
        name = "火龙王", monsterType = "fire_dragon",
        level = 48, hp = 1700, atk = 48, def = 20,
        speed = 2.9, chaseRange = 16.0, attackRange = 7.5, attackCD = 2.4,
        attackMode = "fire_breath", attackDamageScale = 1.0,
        leashRange = 24.0, guardRadius = 3.0,
        exp = 1000, scale = 2.7, tier = "boss",
    },
    {
        name = "牛魔王", monsterType = "golem",
        level = 50, hp = 2200, atk = 54, def = 23, atkScale = 1.12,
        speed = 2.6, chaseRange = 14.7, attackRange = 4.6, attackCD = 2.5,
        attackMode = "ground_slam", attackDamageScale = 1.18,
        encounterOffsetZ = -6.0, leashRange = 24.0, guardRadius = 3.0,
        exp = 1300, scale = 3.0, tier = "boss",
    },
}

-- 合并 MonsterData 中的经典怪与高级地图生态。
for _, def in ipairs(MonsterData.NEW_ENEMIES) do
    table.insert(ENEMY_DEFS, def)
end

Combat.ENEMY_DEFS = ENEMY_DEFS

-- ============================================================================
-- 运行时状态
-- ============================================================================
---@type table[]
local enemies = {}       -- 活着的敌人列表
---@type table[]
local projectiles = {}   -- 弹道列表
---@type table[]
local aoeZones = {}      -- 范围持续伤害区域 (火墙等)
---@type table[]
local summons = {}        -- 召唤兽列表
---@type table[]
local groundItems = {}   -- 地面掉落物 {node, type="gold"/"item", amount, item, timer, magnetPhase, vel}
---@type table[]
local questEffects = {}   -- 主线到点/波次的短时视觉效果
---@type table|nil
local questAreaEffect = nil -- 当前坚守任务的持续区域效果
---@type table|nil
local lastPlayerTarget = nil -- 玩家上次主动攻击命中的怪物，用于无正前方目标时保持目标连续性
---@type Scene|nil
local combatScene = nil -- 最近一次战斗所在场景，用于传送/重生时清掉根节点攻击视觉
local IsEnemyTargetable, HorizontalDir, NormalizeHorizontal, RememberPlayerTarget, IsLastPlayerTargetValid, FacePlayerToTarget
local killCount = 0
local spawnTimer = 0
local currentMapId = "map_bq"  -- 当前地图，供按图刷怪
local playerWasInSafeZone = false
Combat.currentMapId = currentMapId

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function SafeInteger(value, fallback, minValue, maxValue)
    local number = tonumber(value)
    if not IsFiniteNumber(number) then return fallback end
    if minValue then number = math.max(minValue, number) end
    if maxValue then number = math.min(maxValue, number) end
    return math.floor(number)
end

local MAX_COMBAT_VALUE = 1000000000

local function IsHostileSkill(skill)
    if type(skill) ~= "table" then return false end
    return skill.type == SKILL_TYPE.MELEE
        or skill.type == SKILL_TYPE.RANGED
        or skill.type == SKILL_TYPE.AOE
        or skill.type == SKILL_TYPE.DOT
        or skill.type == SKILL_TYPE.DASH
end

Combat.IsHostileSkill = IsHostileSkill

local function GetSafeZoneCenter(mapId)
    local mapDef = MapZone.GetDef(mapId or currentMapId)
    return (mapDef and mapDef.spawnPos) or Vector3.ZERO
end

local function IsInSafeZone(position, mapId)
    if not position then return false end
    local activeMapId = mapId or currentMapId
    local center = GetSafeZoneCenter(activeMapId)
    local halfExtent = tonumber(MapZone.GetSafeZoneRadius(activeMapId))
        or MapZone.DEFAULT_SAFE_ZONE_RADIUS
    if not IsFiniteNumber(halfExtent) then halfExtent = MapZone.DEFAULT_SAFE_ZONE_RADIUS end
    halfExtent = math.max(0, halfExtent)
    local dx = position.x - center.x
    local dz = position.z - center.z
    -- CreateFloor 绘制的是轴对齐方形边界，因此逻辑也必须覆盖四角；
    -- 否则玩家视觉上站在线内，实际却仍会被追击和攻击。
    return math.abs(dx) <= halfExtent and math.abs(dz) <= halfExtent
end

-- 将异常进入安全区的实体推到边界外。正常刷怪不会命中这里，主要防止
-- 物理碰撞、旧存档或跨地图切换把实体留在安全区内。
local function MoveOutsideSafeZone(position, mapId, margin)
    if not position then return nil end
    local activeMapId = mapId or currentMapId
    local center = GetSafeZoneCenter(activeMapId)
    local halfExtent = tonumber(MapZone.GetSafeZoneRadius(activeMapId))
        or MapZone.DEFAULT_SAFE_ZONE_RADIUS
    if not IsFiniteNumber(halfExtent) then halfExtent = MapZone.DEFAULT_SAFE_ZONE_RADIUS end
    halfExtent = math.max(0, halfExtent)
    local dx = position.x - center.x
    local dz = position.z - center.z
    local absX = math.abs(dx)
    local absZ = math.abs(dz)
    if absX > halfExtent or absZ > halfExtent then return position end

    -- 沿最近的一条边推出，避免圆形径向推出在方形角落仍留在线内。
    local edge = halfExtent + (tonumber(margin) or 0.75)
    local x = position.x
    local z = position.z
    local distanceToXEdge = halfExtent - absX
    local distanceToZEdge = halfExtent - absZ
    if distanceToXEdge < distanceToZEdge then
        local signX = dx < 0 and -1 or 1
        x = center.x + signX * edge
    else
        local signZ = dz < 0 and -1 or 1
        z = center.z + signZ * edge
    end
    return Vector3(x, position.y, z)
end

Combat.IsInSafeZone = IsInSafeZone

-- 怪物密度由各地图单独配置；后期单体更强，因此不再用同一个 42 只上限
-- 把所有地图都做成堆怪压力。
local ENEMY_MOVE_SPEED = 2.8
-- 怪物移动速度上限（米/秒）。任何怪物（含 Boss 冲锋/回位）最快不得超过此值。
local ENEMY_MAX_SPEED = 3.0

-- Boss 遭遇附近降低自然刷怪压力：只影响周期性生态刷怪，不影响 Boss
-- 遭遇本体或任务波次。按水平距离判断，Boss 离场/死亡后会自动恢复原频率。
local BOSS_NEARBY_SPAWN_RADIUS = 20.0
local BOSS_NEARBY_SPAWN_INTERVAL_MULTIPLIER = 2.5

-- 自然生态按“玩家附近密度”补充，而不是只看全地图总数。initialCount
-- 同时作为玩家周围的目标数量；全地图 maxEnemies 仍是硬上限。
local SPAWNER_LOCAL_DENSITY_RADIUS = 34.0
-- 只回收明显离开镜头和交战区的普通自然怪，避免玩家看到实体瞬移/消失。
local SPAWNER_FAR_RECYCLE_DISTANCE = 42.0
local SPAWNER_EMPTY_INTERVAL_MULTIPLIER = 0.55
local SPAWNER_REFILL_INTERVAL_MULTIPLIER = 0.82

-- 将技能倍率集中在一个入口，避免职业被动只停留在 CharacterClass 数据描述里。
local function GetSkillDamage(player, skill)
    local base = (player and player.atk or 0) * ((skill and skill.damage or 0) / 100)
    if CharacterClass.GetSkillDamageMultiplier then
        base = base * CharacterClass.GetSkillDamageMultiplier(player, skill)
    end
    return base
end

local function GetExperienceMultiplier(player)
    if CharacterClass.GetExperienceMultiplier then
        return CharacterClass.GetExperienceMultiplier(player)
    end
    return 1.0
end

local function GetBeastAttackMultiplier(player)
    if CharacterClass.GetDivineBeastAttackMultiplier then
        return CharacterClass.GetDivineBeastAttackMultiplier(player)
    end
    return 1.0
end

Combat.enemies = enemies
Combat.projectiles = projectiles
Combat.killCount = 0

IsEnemyTargetable = function(enemy)
    return enemy and enemy.node and enemy.state ~= "dead" and enemy.state ~= "dying"
        and IsFiniteNumber(enemy.hp) and enemy.hp > 0
        and not IsInSafeZone(enemy.node.position)
end

local function IsBossNearbyForSpawner(playerPosition)
    if not playerPosition then return false end
    local radiusSquared = BOSS_NEARBY_SPAWN_RADIUS * BOSS_NEARBY_SPAWN_RADIUS
    for _, enemy in ipairs(enemies) do
        if enemy and enemy.tier == "boss" and IsEnemyTargetable(enemy) then
            local bossPosition = enemy.node.position
            local dx = bossPosition.x - playerPosition.x
            local dz = bossPosition.z - playerPosition.z
            if dx * dx + dz * dz <= radiusSquared then
                return true
            end
        end
    end
    return false
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
local GOLD_MAGNET_DELAY = 2.0    -- 金币落地后多久开始吸附(秒)
local GOLD_MAGNET_ACCEL = 25.0   -- 吸附加速度
local GOLD_MAGNET_MAX_SPEED = 18.0
local GOLD_PICKUP_DIST = 0.5     -- 拾取判定距离
local ITEM_PICKUP_DIST = 0.65    -- 装备拾取距离：必须踩到装备上才拾取
local ITEM_PICKUP_DELAY = 1.0    -- 装备刚掉落后延迟拾取(秒)，由 2 秒缩短一半
local ITEM_BLINK_INTERVAL = 0.16 -- 装备可拾取前的闪烁半周期(秒)
local ITEM_LIFETIME = 60.0       -- 装备存在时间(秒)
local GOLD_LIFETIME = 30.0       -- 金币存在时间(秒)
-- 一件装备包含多段模型、透明光效与 Text3D。地面装备无上限时，高频刷怪
-- 会把单帧渲染 View 推过引擎上限；保留足够的拾取窗口，同时限制峰值。
local MAX_GROUND_EQUIPMENT = 16

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

-- 主线提示材质使用透明 PBR + 自发光：既能在暗色地图上读清轮廓，
-- 又不会把发光区域误当成实体碰撞或地面装饰。
local function CreateQuestEffectMaterial(color, alpha, emissive)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(color[1], color[2], color[3], alpha)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(
        color[1] * (emissive or 1.0),
        color[2] * (emissive or 1.0),
        color[3] * (emissive or 1.0), 1.0)))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    mat:SetShaderParameter("Roughness", Variant(0.18))
    return mat
end

local function SetQuestModelsMaterial(models, material)
    if type(models) ~= "table" then return end
    for _, model in ipairs(models) do
        if model then model:SetMaterial(material) end
    end
end

local function CreateQuestRingSegments(parent, radius, material, segmentCount, prefix)
    local models = {}
    local count = math.max(6, math.floor(segmentCount or 12))
    local circumference = math.pi * 2 * radius
    local segmentLength = math.max(0.38, circumference / count * 0.62)

    for index = 1, count do
        local angle = (index - 1) / count * math.pi * 2
        local segment = parent:CreateChild((prefix or "segment") .. "_" .. index)
        segment.position = Vector3(
            math.cos(angle) * radius,
            0.055,
            math.sin(angle) * radius)
        -- Box 的本体尺寸为 1m；长轴沿切线摆放，形成清晰的环形虚线。
        segment.scale = Vector3(segmentLength, 0.045, 0.09)
        segment.rotation = Quaternion(math.deg(angle) + 90, Vector3.UP)
        local model = segment:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        model:SetMaterial(material)
        model.castShadows = false
        table.insert(models, model)
    end
    return models
end

local function CreateQuestAreaVisual(scene, questId, mapId, area)
    local x = tonumber(area and area.x) or 0
    local z = tonumber(area and area.z) or 0
    local radius = math.max(0.5, tonumber(area and area.radius) or 9)
    local root = scene:CreateChild("QuestAreaEffect_" .. tostring(questId))
    root.position = Vector3(x, 0, z)

    local activeColor = { 1.0, 0.42, 0.08 }
    local idleColor = { 0.36, 0.18, 0.06 }
    local activeMat = CreateQuestEffectMaterial(activeColor, 0.62, 2.4)
    local idleMat = CreateQuestEffectMaterial(idleColor, 0.24, 0.7)
    local innerMat = CreateQuestEffectMaterial({ 1.0, 0.68, 0.20 }, 0.10, 1.6)

    local disk = root:CreateChild("AreaDisk")
    disk.position = Vector3(0, 0.025, 0)
    disk.scale = Vector3(radius * 2, 0.025, radius * 2)
    local diskModel = disk:CreateComponent("StaticModel")
    diskModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    diskModel:SetMaterial(innerMat)
    diskModel.castShadows = false

    -- 区域刚创建时处于“未生效”状态；先用低亮材质，等玩家真正站入
    -- 区域后再由 SetQuestAreaEffect 切到高亮，避免首帧就显示成已激活。
    local segments = CreateQuestRingSegments(root, radius, idleMat, 18, "AreaRing")
    local innerSegments = CreateQuestRingSegments(root, radius * 0.56, idleMat, 12, "AreaInnerRing")

    local beaconModels = {}
    for index, angle in ipairs({ 0, math.pi * 0.5, math.pi, math.pi * 1.5 }) do
        local beacon = root:CreateChild("AreaBeacon_" .. index)
        beacon.position = Vector3(
            math.cos(angle) * radius * 0.82,
            0.42,
            math.sin(angle) * radius * 0.82)
        beacon.scale = Vector3(0.13, 0.84, 0.13)
        local model = beacon:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        model:SetMaterial(idleMat)
        model.castShadows = false
        table.insert(beaconModels, { node = beacon, model = model, baseHeight = 0.84 })
    end

    return {
        questId = questId,
        mapId = mapId,
        node = root,
        radius = radius,
        phase = 0,
        active = false,
        activeMaterial = activeMat,
        idleMaterial = idleMat,
        segments = segments,
        innerSegments = innerSegments,
        beaconModels = beaconModels,
        diskModel = diskModel,
    }
end

-- 引擎节点被父节点清理后，Lua 包装对象有时仍然保持非 nil。用父节点
-- 关系确认它仍挂在场景树上，避免切图/装饰清理后下一帧访问失效位置。
local function IsQuestNodeAttached(node)
    if not node then return false end
    local ok, parent = pcall(function() return node:GetParent() end)
    return ok and parent ~= nil
end

--- 创建一次性的“到点/敌群来袭”主线提示。
---@param scene Scene
---@param position Vector3|table
---@param kind string|nil "patrol" or "survive"
---@return Node|nil
function Combat.SpawnQuestSignal(scene, position, kind)
    if not scene or not position then return nil end

    local palette = kind == "survive"
        and { 1.0, 0.34, 0.06 }
        or { 1.0, 0.78, 0.16 }
    local root = scene:CreateChild("QuestSignal")
    root.position = Vector3(
        tonumber(position.x) or 0,
        tonumber(position.y) or 0,
        tonumber(position.z) or 0)
    root.scale = Vector3(0.55, 1.0, 0.55)

    local ringMaterial = CreateQuestEffectMaterial(palette, 0.72, 3.2)
    local innerMaterial = CreateQuestEffectMaterial({ 1.0, 0.95, 0.56 }, 0.82, 3.8)
    local ringModels = CreateQuestRingSegments(root, 2.35, ringMaterial, 14, "SignalRing")
    local innerModels = CreateQuestRingSegments(root, 1.15, innerMaterial, 10, "SignalInner")

    local beacon = root:CreateChild("SignalBeacon")
    beacon.position = Vector3(0, 1.05, 0)
    beacon.scale = Vector3(0.18, 2.1, 0.18)
    local beaconModel = beacon:CreateComponent("StaticModel")
    beaconModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
    beaconModel:SetMaterial(innerMaterial)
    beaconModel.castShadows = false

    local core = root:CreateChild("SignalCore")
    core.position = Vector3(0, 0.24, 0)
    core.scale = Vector3(0.42, 0.42, 0.42)
    local coreModel = core:CreateComponent("StaticModel")
    coreModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    coreModel:SetMaterial(innerMaterial)
    coreModel.castShadows = false

    table.insert(questEffects, {
        node = root,
        elapsed = 0,
        duration = 1.35,
        ringModels = ringModels,
        innerModels = innerModels,
        ringMaterial = ringMaterial,
        innerMaterial = innerMaterial,
        color = palette,
    })
    return root
end

--- 设置当前坚守任务的区域效果。区域即使未站入也会保留低亮轮廓，站入后
--- 自动切为高亮脉冲，玩家能同时看到“目标在哪里”和“当前是否生效”。
---@param scene Scene
---@param questId string
---@param area table
---@param active boolean
---@return Node|nil
function Combat.SetQuestAreaEffect(scene, questId, area, active)
    if not scene or type(questId) ~= "string" or type(area) ~= "table" then
        Combat.ClearQuestAreaEffect()
        return nil
    end

    local x = tonumber(area.x) or 0
    local z = tonumber(area.z) or 0
    local radius = math.max(0.5, tonumber(area.radius) or 9)
    local mapId = currentMapId
    local areaNode = questAreaEffect and questAreaEffect.node or nil
    if questAreaEffect and not IsQuestNodeAttached(areaNode) then
        questAreaEffect = nil
    end
    if questAreaEffect and (
        questAreaEffect.questId ~= questId
        or questAreaEffect.mapId ~= mapId
        or math.abs(areaNode.position.x - x) > 0.01
        or math.abs(areaNode.position.z - z) > 0.01
        or math.abs(questAreaEffect.radius - radius) > 0.01) then
        areaNode:Remove()
        questAreaEffect = nil
    end

    if not questAreaEffect then
        questAreaEffect = CreateQuestAreaVisual(scene, questId, mapId, area)
    end

    local nextActive = active == true
    if questAreaEffect.active ~= nextActive then
        questAreaEffect.active = nextActive
        local outerMaterial = nextActive
            and questAreaEffect.activeMaterial or questAreaEffect.idleMaterial
        SetQuestModelsMaterial(questAreaEffect.segments, outerMaterial)
        SetQuestModelsMaterial(questAreaEffect.innerSegments, nextActive
            and questAreaEffect.activeMaterial or questAreaEffect.idleMaterial)
        local beaconModels = {}
        for _, item in ipairs(questAreaEffect.beaconModels) do
            table.insert(beaconModels, item.model)
        end
        SetQuestModelsMaterial(beaconModels, outerMaterial)
    end
    return questAreaEffect.node
end

function Combat.ClearQuestAreaEffect()
    if questAreaEffect and IsQuestNodeAttached(questAreaEffect.node) then
        questAreaEffect.node:Remove()
    end
    questAreaEffect = nil
end

-- 清理主线专用的瞬时/持续视觉节点。切图、读档和结束角色会话都必须
-- 清掉这些节点，否则它们会留在旧场景里，甚至继续被 UpdateVisuals 驱动。
local function ClearQuestEffects()
    for index = #questEffects, 1, -1 do
        local effect = questEffects[index]
        if effect and IsQuestNodeAttached(effect.node) then
            effect.node:Remove()
        end
        questEffects[index] = nil
    end
    Combat.ClearQuestAreaEffect()
end

local function UpdateQuestEffects(dt)
    local elapsed = math.max(0, tonumber(dt) or 0)

    for index = #questEffects, 1, -1 do
        local effect = questEffects[index]
        effect.elapsed = effect.elapsed + elapsed
        if not IsQuestNodeAttached(effect.node) or effect.elapsed >= effect.duration then
            if IsQuestNodeAttached(effect.node) then effect.node:Remove() end
            table.remove(questEffects, index)
        else
            local progress = math.max(0, math.min(1, effect.elapsed / effect.duration))
            local scale = 0.55 + progress * 1.65
            effect.node.scale = Vector3(scale, 1.0, scale)
            effect.node.rotation = effect.node.rotation * Quaternion(115 * elapsed, Vector3.UP)
            local alpha = 0.72 * (1.0 - progress) + 0.08
            if effect.ringMaterial then
                effect.ringMaterial:SetShaderParameter("MatDiffColor", Variant(Color(
                    effect.color[1], effect.color[2], effect.color[3], alpha)))
            end
            if effect.innerMaterial then
                effect.innerMaterial:SetShaderParameter("MatDiffColor", Variant(Color(
                    1.0, 0.95, 0.56, math.min(0.9, alpha + 0.10))))
            end
        end
    end

    if questAreaEffect and IsQuestNodeAttached(questAreaEffect.node) then
        questAreaEffect.phase = questAreaEffect.phase + elapsed
        local pulse = questAreaEffect.active
            and (1.0 + math.sin(questAreaEffect.phase * 4.2) * 0.075)
            or (0.94 + math.sin(questAreaEffect.phase * 2.0) * 0.025)
        questAreaEffect.node.scale = Vector3(pulse, 1.0, pulse)
        for _, item in ipairs(questAreaEffect.beaconModels or {}) do
            local heightPulse = questAreaEffect.active
                and (0.88 + math.sin(questAreaEffect.phase * 4.2 + item.baseHeight) * 0.18)
                or 0.72
            item.node.scale = Vector3(0.13, item.baseHeight * heightPulse, 0.13)
        end
    end
end

local fireBreathMaterials = nil

local function GetFireBreathMaterials()
    if fireBreathMaterials then return fireBreathMaterials end

    local function Make(color, emissive, roughness)
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(color))
        mat:SetShaderParameter("MatEmissiveColor", Variant(emissive))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        mat:SetShaderParameter("Roughness", Variant(roughness))
        return mat
    end

    fireBreathMaterials = {
        core = Make(Color(1.0, 0.72, 0.12, 0.92), Color(5.0, 1.45, 0.08, 1.0), 0.08),
        flame = Make(Color(1.0, 0.18, 0.015, 0.68), Color(3.6, 0.32, 0.02, 1.0), 0.15),
        ember = Make(Color(1.0, 0.88, 0.30, 0.90), Color(4.0, 1.1, 0.10, 1.0), 0.06),
    }
    return fireBreathMaterials
end

function Combat.SpawnFireBreathVisual(scene, origin, targetPos, maxRange)
    if not scene or not origin or not targetPos then return nil end
    combatScene = scene
    local dir = targetPos - origin
    dir.y = 0
    local targetDistance = dir:Length()
    if targetDistance <= 0.001 then return nil end
    dir = dir:Normalized()

    local length = math.min(maxRange or 7.5, targetDistance)
    local materials = GetFireBreathMaterials()
    local node = scene:CreateChild("BossAttackVisual")
    node.position = Vector3(origin.x, origin.y + 2.35, origin.z)
    node.rotation = Quaternion(math.deg(math.atan2(dir.x, dir.z)), Vector3.UP)

    -- 用逐渐扩张并下沉的火团形成锥形吐息，起点贴近龙首、末端覆盖目标身位。
    local segmentCount = 9
    for index = 1, segmentCount do
        local progress = index / segmentCount
        local radius = 0.12 + progress * 0.52
        local flame = node:CreateChild("fire_breath_flame_" .. index)
        flame.position = Vector3(
            math.sin(index * 2.3) * radius * 0.28,
            -1.32 * progress + math.sin(index * 1.7) * 0.08,
            length * progress)
        flame.scale = Vector3(radius * 1.20, radius * 0.92, radius * 1.65)
        local model = flame:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        model:SetMaterial(index % 3 == 0 and materials.core or materials.flame)
        model.castShadows = false
    end

    for index = 1, 4 do
        local progress = (index + 0.5) / 5.0
        local ember = node:CreateChild("fire_breath_ember_" .. index)
        ember.position = Vector3(
            (index % 2 == 0 and 1 or -1) * (0.18 + progress * 0.42),
            -1.18 * progress + 0.18,
            length * progress)
        local size = 0.07 + progress * 0.06
        ember.scale = Vector3(size, size, size)
        local model = ember:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        model:SetMaterial(materials.ember)
        model.castShadows = false
    end

    node:SetVar("removeTimer", Variant(0.72))
    return node
end

local bossAttackMaterials = nil

local function GetBossAttackMaterials()
    if bossAttackMaterials then return bossAttackMaterials end

    local function Make(color, emissive, roughness)
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(color))
        mat:SetShaderParameter("MatEmissiveColor", Variant(emissive))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        mat:SetShaderParameter("Roughness", Variant(roughness or 0.22))
        return mat
    end

    bossAttackMaterials = {
        venom = Make(Color(0.12, 0.88, 0.18, 0.76), Color(0.08, 2.2, 0.18, 1.0), 0.16),
        venomCore = Make(Color(0.62, 1.0, 0.16, 0.92), Color(1.4, 3.0, 0.12, 1.0), 0.10),
        slam = Make(Color(1.0, 0.30, 0.05, 0.52), Color(2.6, 0.42, 0.04, 1.0), 0.34),
        slamCore = Make(Color(1.0, 0.72, 0.12, 0.82), Color(3.2, 1.4, 0.08, 1.0), 0.18),
        charge = Make(Color(1.0, 0.86, 0.24, 0.72), Color(3.0, 1.6, 0.12, 1.0), 0.12),
    }
    return bossAttackMaterials
end

--- 生成轻量 Boss 攻击反馈。伤害仍由同帧战斗结算完成，视觉节点只负责表现，
--- 因而传送、重生或进入安全区时可以直接删除，不会留下等待中的攻击状态。
function Combat.SpawnBossAttackVisual(scene, mode, origin, targetPos, radius)
    if not scene or not origin then return nil end
    combatScene = scene
    local materials = GetBossAttackMaterials()
    local node = scene:CreateChild("BossAttackVisual")
    local effectRadius = math.max(0.8, tonumber(radius) or 2.0)

    if mode == "venom_spit" and targetPos then
        local dir = targetPos - origin
        dir.y = 0
        local distance = dir:Length()
        if distance <= 0.001 then node:Remove() return nil end
        dir = dir:Normalized()
        local length = math.min(effectRadius, distance)
        node.position = Vector3(origin.x, origin.y + 1.45, origin.z)
        node.rotation = Quaternion(math.deg(math.atan2(dir.x, dir.z)), Vector3.UP)
        for index = 1, 6 do
            local progress = index / 6
            local drop = node:CreateChild("venom_drop_" .. index)
            drop.position = Vector3(
                math.sin(index * 2.1) * 0.12,
                math.sin(progress * math.pi) * 0.55 - progress * 1.0,
                length * progress)
            local size = 0.12 + progress * 0.16
            drop.scale = Vector3(size, size, size)
            local model = drop:CreateComponent("StaticModel")
            model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
            model:SetMaterial(index == 6 and materials.venomCore or materials.venom)
            model.castShadows = false
        end
        node:SetVar("removeTimer", Variant(0.58))
    elseif mode == "ground_slam" then
        node.position = Vector3(origin.x, 0.06, origin.z)
        local disk = node:CreateChild("slam_disk")
        disk.scale = Vector3(effectRadius * 2, 0.045, effectRadius * 2)
        local diskModel = disk:CreateComponent("StaticModel")
        diskModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        diskModel:SetMaterial(materials.slam)
        diskModel.castShadows = false
        for index = 1, 4 do
            local crack = node:CreateChild("slam_crack_" .. index)
            crack.position = Vector3(0, 0.04, 0)
            crack.rotation = Quaternion((index - 1) * 45, Vector3.UP)
            crack.scale = Vector3(effectRadius * 1.65, 0.035, 0.10)
            local crackModel = crack:CreateComponent("StaticModel")
            crackModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
            crackModel:SetMaterial(index % 2 == 0 and materials.slamCore or materials.slam)
            crackModel.castShadows = false
        end
        node:SetVar("removeTimer", Variant(0.62))
    elseif mode == "charge" then
        local impact = targetPos or origin
        node.position = Vector3(impact.x, 0.12, impact.z)
        local burst = node:CreateChild("charge_impact")
        burst.scale = Vector3(effectRadius * 0.9, 0.12, effectRadius * 0.9)
        local model = burst:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        model:SetMaterial(materials.charge)
        model.castShadows = false
        node:SetVar("removeTimer", Variant(0.36))
    else
        node:Remove()
        return nil
    end

    return node
end

local function RemoveBossAttackVisuals(scene)
    if not scene then return end
    for index = scene:GetNumChildren(false) - 1, 0, -1 do
        local child = scene:GetChild(index)
        if child and child.name == "BossAttackVisual" then
            child:Remove()
        end
    end
end

local function ApplyEnemyDamageToPlayer(enemy, player, hitPos)
    local incomingMultiplier = enemy.attackDamageScale or 1.0
    if CharacterClass.RollIncomingDamageReduction
        and CharacterClass.RollIncomingDamageReduction(player) then
        incomingMultiplier = incomingMultiplier * CharacterClass.GetIncomingDamageMultiplier(player)
    end
    local dmg = Balance.CalculateDamage(enemy.atk, player.def, {
        damageMultiplier = incomingMultiplier,
    })
    if player.shieldHP > 0 then
        local absorbed = math.min(player.shieldHP, dmg)
        player.shieldHP = player.shieldHP - absorbed
        dmg = dmg - absorbed
    end
    player.hp = math.max(0, player.hp - dmg)
    if Combat.onEnemyAttack then
        Combat.onEnemyAttack(enemy, dmg, hitPos)
    end
    return dmg
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

    local function TintModelComponent(model)
        if not model then return end
        local index = 0
        while index < 16 do
            local original = model:GetMaterial(index)
            if not original and index > 0 then break end
            table.insert(enemy.poisonOrigMats, { model = model, index = index, mat = original })
            model:SetMaterial(index, poisonMat)
            index = index + 1
        end
    end

    local function TintModels(node)
        TintModelComponent(node:GetComponent("StaticModel"))
        TintModelComponent(node:GetComponent("AnimatedModel"))
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
                entry.model:SetMaterial(entry.index or 0, entry.mat)
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

-- 安全区代表完整脱战：玩家进入后，之前已经释放的敌对效果也必须立即失效，
-- 不能只禁止新技能。召唤兽与永久神兽实体继续保留，但各自的 Update 会暂停索敌。
function Combat.CancelPlayerHostileEffects()
    local hostileScene = nil
    for _, enemy in ipairs(enemies) do
        if enemy and enemy.node then
            hostileScene = enemy.node:GetScene()
            if hostileScene then break end
        end
    end

    for _, projectile in ipairs(projectiles) do
        if projectile.node then projectile.node:Remove() end
    end
    projectiles = {}
    Combat.projectiles = projectiles

    for _, zone in ipairs(aoeZones) do
        if zone.visualNode then zone.visualNode:Remove() end
    end
    aoeZones = {}
    RemoveBossAttackVisuals(hostileScene or combatScene)

    for _, enemy in ipairs(enemies) do
        if enemy then
            local hadPoison = (enemy.dotTimer or 0) > 0 or enemy.poisonTinted
            enemy.dotDamage = 0
            enemy.dotTimer = 0
            enemy.dotTickAccum = 0
            enemy.defReduction = 0
            enemy.defReductionTimer = 0
            enemy.trapCenter = nil
            enemy.trapRadius = nil
            enemy.trapTimer = nil
            enemy.trapDefReduced = nil
            if enemy.tier == "boss" and enemy.state ~= "dying" and enemy.state ~= "dead" then
                enemy.state = "return"
                enemy.patrolTarget = nil
                enemy.attackTimer = math.max(enemy.attackTimer or 0, 0.35)
                enemy.knockbackTimer = 0
                enemy.hitStunTimer = 0
            end
            if hadPoison then RemovePoisonTint(enemy) end
        end
    end

    lastPlayerTarget = nil
    dashState.active = false
    dashState.dir = nil
    dashState.remaining = 0
    dashState.pushed = {}
end

-- 怪物等级曲线、防御公式、品阶和物种定位统一由 Balance.lua 管理。

-- ============================================================================
-- 敌人创建（使用 MonsterSkeleton 骨架系统）
-- ============================================================================
function Combat.SpawnEnemy(scene, playerPos, playerLevel, forceDef, mapId, options)
    if not scene or not playerPos then return nil end
    combatScene = scene

    -- 传入地图优先；未传入时使用战斗系统当前地图。不要让一个临时的
    -- mapId 参数影响另一套状态（例如读档/切图的安全区半径）。
    local spawnMapId = mapId or currentMapId
    local spawnSettings = MapZone.GetSpawnSettings(spawnMapId)
    if #enemies >= spawnSettings.maxEnemies then return nil end
    -- 玩家等级在 Lv.50 后仍可增长；这里只沿用 Balance 的异常数据安全边界。
    local safePlayerLevel = SafeInteger(playerLevel, 1, 1, Balance.LEVEL_SANITY_LIMIT)
    local mapDef = MapZone.GetDef(spawnMapId)
    local mapMinLevel = mapDef and tonumber(mapDef.minLevel) or nil
    local mapMaxLevel = mapDef and tonumber(mapDef.maxLevel) or nil
    local hasUsableMapPool = false

    local def
    if forceDef then
        def = forceDef
    else
        -- 按当前地图怪物池选取；未指定地图时回退到全表按等级选取。
        -- candidateDefs 一旦来自地图池，后续所有兜底都必须继续留在该池内，
        -- 否则低等级越级进入火龙魔窟时会刷出“鹿”等跨图怪物。
        -- 始终使用独立候选数组，地图池缺失或损坏时也不能污染全局定义。
        local candidateDefs = {}
        for _, enemyDef in ipairs(ENEMY_DEFS) do
            table.insert(candidateDefs, enemyDef)
        end
        local pool = MapZone.GetPool(spawnMapId)
        if pool and #pool > 0 then
            local poolSet = {}
            for _, n in ipairs(pool) do poolSet[n] = true end
            local mapped = {}
            for _, d in ipairs(ENEMY_DEFS) do
                if poolSet[d.name] then
                    table.insert(mapped, d)
                end
            end
            if #mapped > 0 then candidateDefs = mapped end
            hasUsableMapPool = #mapped > 0
        end

        local validDefs = {}

        local function IsWithinMapBand(definition)
            if not mapMinLevel or not mapMaxLevel then return true end
            return (tonumber(definition.level) or 0) >= mapMinLevel
                and (tonumber(definition.level) or 0) <= mapMaxLevel
        end

        for _, d in ipairs(candidateDefs) do
            -- 普通怪按等级带生成；显式写进地图池的精英允许低权重出现，
            -- 但全表兜底不会把其它精英误当作常规杂兵。
            if d.tier ~= "boss"
                and (d.tier == "normal" or (d.tier == "elite" and hasUsableMapPool))
                and IsWithinMapBand(d)
                and d.level <= safePlayerLevel + 4
                and d.level >= safePlayerLevel - 5 then
                table.insert(validDefs, d)
            end
        end
        -- 如果没有合适的，取最接近玩家等级的非Boss怪
        if #validDefs == 0 then
            for _, d in ipairs(candidateDefs) do
                if d.tier == "normal" and IsWithinMapBand(d)
                    and d.level <= safePlayerLevel + 8 then
                    table.insert(validDefs, d)
                end
            end
        end
        -- 软门槛允许玩家越级进入任意地图，因此极低等级时可能没有“接近
        -- 玩家等级”的候选；仍从该地图的普通池兜底，绝不能回退到全表第一只怪。
        if #validDefs == 0 then
            for _, d in ipairs(candidateDefs) do
                if d.tier == "normal" and IsWithinMapBand(d) then
                    table.insert(validDefs, d)
                end
            end
        end
        -- 仅当地图池不存在/配置损坏时才回退全表，避免静默跨地图刷怪。
        if #validDefs == 0 and not hasUsableMapPool then
            for _, d in ipairs(ENEMY_DEFS) do
                if d.tier == "normal" then
                    table.insert(validDefs, d)
                end
            end
        end
        if #validDefs == 0 then return end

        -- 加权随机：等级越接近玩家越容易出现
        local weights = {}
        local totalWeight = 0
        for i, d in ipairs(validDefs) do
            local diff = math.abs(d.level - safePlayerLevel)
            local w = math.max(1, 10 - diff)  -- 等级差越小权重越高
            if d.tier == "elite" then
                w = w * 0.25
            end
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
        if hasUsableMapPool and mapMinLevel and mapMaxLevel then
            -- 有效地图池代表固定等级生态。越级进入高危地图时必须面对该地图
            -- 的真实强度，不能把 Lv.46 怪物压成 Lv.4 后伪装成“软门槛”。
            actualLevel = math.max(mapMinLevel, math.min(actualLevel, mapMaxLevel))
        else
            -- 只有地图配置缺失/损坏而回退全表时，才按玩家等级做保守适配。
            actualLevel = math.max(1, math.min(actualLevel, safePlayerLevel + 3))
        end
    end

    local scaledStats = Balance.GetMonsterStats(def, actualLevel)
    local scaledHP = scaledStats.hp
    local scaledATK = scaledStats.atk
    local scaledDEF = scaledStats.def
    local scaledEXP = scaledStats.exp
    local isBoss = def.tier == "boss"

    -- 在玩家周围随机位置生成（避开安全区 + 保证最小距离）
    -- 安全区以地图出生点为中心、safeRadius 为方形半边长；怪物不得生成在线内。
    local safeRadius = MapZone.GetSafeZoneRadius(spawnMapId)
    local minSpawnDist = 12   -- 怪物距玩家最小距离
    local maxSpawnDist = 28   -- 怪物距玩家最大距离
    local spawnPos = nil
    local requestedPosition = type(options) == "table" and options.position or nil
    if requestedPosition then
        local candidate = Vector3(
            tonumber(requestedPosition.x) or 0,
            tonumber(requestedPosition.y) or 0,
            tonumber(requestedPosition.z) or 0)
        -- 显式遭遇点同时也是地图地标中心。部分旧场景把蚁穴/王座碰撞体
        -- 放在同一坐标，Boss 又锁定 Y 轴，因而永远无法自行脱困。只对
        -- Boss 遭遇应用配置偏移，让目标仍出现在地标附近但站到入口前方。
        if isBoss and type(options) == "table" and options.encounterId then
            candidate.x = candidate.x + (tonumber(def.encounterOffsetX) or 0)
            candidate.z = candidate.z + (tonumber(def.encounterOffsetZ) or 0)
        end
        candidate = MapZone.ClampToArena(candidate, 1.0) or candidate
        spawnPos = MoveOutsideSafeZone(candidate, spawnMapId, 1.0) or candidate
    else
        -- 自然刷新点距离安全区（地图出生点）越远，越容易被选中；越靠近
        -- 安全区越少刷。先采集一批合法候选，再按“偏离安全区的程度”加权，
        -- 保证玩家周围环形约束不变的同时，安全区附近明显稀疏。
        local safeCenter = GetSafeZoneCenter(spawnMapId)
        local candidates = {}
        for _ = 1, 16 do
            local angle = math.random() * math.pi * 2
            local dist = minSpawnDist + math.random() * (maxSpawnDist - minSpawnDist)
            local candidate = Vector3(
                playerPos.x + math.cos(angle) * dist,
                0,
                playerPos.z + math.sin(angle) * dist
            )
            if MapZone.IsInsideArena(candidate, 1.0) and not IsInSafeZone(candidate, spawnMapId) then
                local dx = candidate.x - safeCenter.x
                local dz = candidate.z - safeCenter.z
                local centerDist = math.sqrt(dx * dx + dz * dz)
                -- 权重与偏离安全区中心的距离成正比；等于安全区半径时权重为 0。
                local weight = math.max(0, centerDist - safeRadius)
                table.insert(candidates, { pos = candidate, weight = weight })
            end
        end
        if #candidates > 0 then
            local totalWeight = 0
            for _, c in ipairs(candidates) do totalWeight = totalWeight + c.weight end
            if totalWeight > 0 then
                local roll = math.random() * totalWeight
                local acc = 0
                spawnPos = candidates[1].pos
                for _, c in ipairs(candidates) do
                    acc = acc + c.weight
                    if roll <= acc then
                        spawnPos = c.pos
                        break
                    end
                end
            else
                -- 所有候选都贴边（玩家紧贴安全区边缘），此时均匀随机即可。
                spawnPos = candidates[math.random(#candidates)].pos
            end
        end
    end
    -- 兜底：若多次尝试都落在安全区内（玩家在安全区中心附近），直接放到安全区边缘外
    if not spawnPos then
        local angle = math.random() * math.pi * 2
        local safeCenter = GetSafeZoneCenter(spawnMapId)
        spawnPos = Vector3(
            safeCenter.x + math.cos(angle) * (safeRadius + 4),
            0,
            safeCenter.z + math.sin(angle) * (safeRadius + 4))
        spawnPos = MapZone.ClampToArena(spawnPos, 1.0) or spawnPos
    end

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
    -- Boss 不与普通 AI 互相阻挡，避免被小怪包围后看似“不能动”；仍与
    -- 地形和玩家碰撞。普通怪保持原来的 AI 间碰撞。
    rbody.collisionMask = isBoss and (1 | 2) or (1 | 2 | 4)
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
        speed = math.min(def.speed or ENEMY_MOVE_SPEED, ENEMY_MAX_SPEED),
        chaseRange = def.chaseRange,
        attackRange = def.attackRange,
        attackCD = def.attackCD,
        attackMode = def.attackMode or "melee",
        attackDamageScale = def.attackDamageScale or 1.0,
        faceYawOffset = def.faceYawOffset or 0,
        attackTimer = 0,
        exp = scaledEXP,
        state = isBoss and "guard" or "patrol",
        homePosition = Vector3(spawnPos.x, spawnPos.y, spawnPos.z),
        leashRange = tonumber(def.leashRange) or math.max(12, (def.chaseRange or 10) * 1.5),
        guardRadius = tonumber(def.guardRadius) or 2.0,
        returnSpeed = math.min((def.speed or ENEMY_MOVE_SPEED) * 1.15, ENEMY_MAX_SPEED),
        chargeRange = tonumber(def.chargeRange) or 8.0,
        patrolTarget = nil,
        patrolWait = 0,
        stuckCheckTimer = 0,
        stuckRecoveries = 0,
        lastMovePosition = Vector3(spawnPos.x, spawnPos.y, spawnPos.z),
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
        encounterId = type(options) == "table" and options.encounterId or nil,
        questGroupId = type(options) == "table" and options.questGroupId or nil,
        spawnSource = type(options) == "table" and options.spawnSource or "natural",
    }

    table.insert(enemies, enemy)
    return enemy
end

--- 立即移除一个尚存于 enemies 表中的实体，不触发击杀、掉落或任务进度。
--- 仅用于给更高优先级的任务生成腾出容量，以及回滚未完整生成的任务敌群。
---@param enemy table|nil
---@return boolean
local function RemoveEnemyImmediately(enemy)
    if not enemy then return false end
    for index = #enemies, 1, -1 do
        if enemies[index] == enemy then
            if enemy.node then enemy.node:Remove() end
            if lastPlayerTarget == enemy then lastPlayerTarget = nil end
            table.remove(enemies, index)
            return true
        end
    end
    return false
end

---@param groupId string|nil
---@return string|nil
local function GetQuestGroupOwner(groupId)
    if type(groupId) ~= "string" or groupId == "" then return nil end
    local separator = string.find(groupId, ":", 1, true)
    return separator and string.sub(groupId, 1, separator - 1) or groupId
end

--- 在地图总上限内为任务敌群预留完整容量。
--- 优先回收远离当前目标点的普通自然怪；仍不足时，只回收其它任务留下的
--- 非关键敌群。当前任务已生成的波次、Boss 与显式遭遇实体都不会被移除。
---@param mapId string
---@param requestedCount number
---@param center Vector3
---@param groupId string|nil
---@return boolean ready
---@return number reclaimed
local function MakeQuestGroupRoom(mapId, requestedCount, center, groupId)
    local maxEnemies = MapZone.GetSpawnSettings(mapId).maxEnemies
    local slotsNeeded = math.max(0, #enemies + requestedCount - maxEnemies)
    if slotsNeeded == 0 then return true, 0 end

    local activeQuestId = GetQuestGroupOwner(groupId)
    local candidates = {}
    for index, enemy in ipairs(enemies) do
        ---@type number|nil
        local priority = nil
        if not enemy.node then
            priority = 0
        elseif enemy.tier ~= "boss" and not enemy.encounterId then
            if enemy.state == "dead" or enemy.state == "dying" then
                priority = 0
            else
                local spawnSource = enemy.spawnSource
                    or (enemy.questGroupId and "quest_group" or "natural")
                if spawnSource == "natural" then
                    priority = 1
                elseif spawnSource == "quest_group"
                    and (not activeQuestId
                        or GetQuestGroupOwner(enemy.questGroupId) ~= activeQuestId) then
                    priority = 2
                end
            end
        end

        if priority ~= nil then
            local distanceSq = math.huge
            if enemy.node then
                local position = enemy.node.position
                local dx = (tonumber(position.x) or 0) - center.x
                local dz = (tonumber(position.z) or 0) - center.z
                distanceSq = dx * dx + dz * dz
            end
            table.insert(candidates, {
                enemy = enemy,
                priority = priority,
                distanceSq = distanceSq,
                index = index,
            })
        end
    end

    -- 容量不足时保持现状，让上层保留该波次并稍后重试；不做半组生成。
    if #candidates < slotsNeeded then return false, 0 end

    table.sort(candidates, function(a, b)
        if a.priority ~= b.priority then return a.priority < b.priority end
        if a.distanceSq ~= b.distanceSq then return a.distanceSq > b.distanceSq end
        return a.index > b.index
    end)

    local reclaimed = 0
    for index = 1, slotsNeeded do
        if RemoveEnemyImmediately(candidates[index].enemy) then
            reclaimed = reclaimed + 1
        end
    end
    return reclaimed == slotsNeeded, reclaimed
end

--- 在指定目标点附近生成一小组当前地图生态怪物。
--- 该 API 只重复调用统一 SpawnEnemy 入口，不改变地图池、等级曲线或自然刷怪器；
--- 因此任务事件只是一次性的压力注入，不会形成第二套怪物来源。
---@param scene Scene
---@param center Vector3|table
---@param playerLevel number
---@param mapId string|nil
---@param options table|nil {count, radius, groupId}
---@return number 实际生成数量（容量不足或创建异常时整组返回 0）
function Combat.SpawnEnemyGroup(scene, center, playerLevel, mapId, options)
    if not scene or not center then return 0 end

    local opts = type(options) == "table" and options or {}
    local count = SafeInteger(opts.count, 4, 1, 8)
    local radius = tonumber(opts.radius) or 5.5
    if not IsFiniteNumber(radius) then radius = 5.5 end
    radius = math.max(1.5, math.min(radius, 12.0))

    local spawnMapId = mapId or currentMapId
    local groupId = type(opts.groupId) == "string" and opts.groupId or nil
    local spawned = 0
    local startAngle = math.random() * math.pi * 2
    local centerPos = Vector3(
        tonumber(center.x) or 0,
        tonumber(center.y) or 0,
        tonumber(center.z) or 0)

    local roomReady, reclaimed = MakeQuestGroupRoom(
        spawnMapId, count, centerPos, groupId)
    if not roomReady then return 0 end

    local spawnedEnemies = {}

    for index = 1, count do
        local angle = startAngle + (index - 1) * (math.pi * 2 / count)
        local distance = radius * (0.62 + math.random() * 0.38)
        local spawnPos = Vector3(
            centerPos.x + math.cos(angle) * distance,
            centerPos.y,
            centerPos.z + math.sin(angle) * distance)
        local enemy = Combat.SpawnEnemy(scene, centerPos, playerLevel, nil, spawnMapId, {
            position = spawnPos,
            questGroupId = groupId,
            spawnSource = "quest_group",
        })
        if enemy then
            spawned = spawned + 1
            table.insert(spawnedEnemies, enemy)
        end
    end

    -- 任务波次必须是完整的一组。极端异常下回滚已创建实体，让 Quest
    -- 保留这一波并在后续帧重试，避免出现提示与实际数量不一致。
    if spawned ~= count then
        for _, enemy in ipairs(spawnedEnemies) do
            RemoveEnemyImmediately(enemy)
        end
        return 0
    end

    print(string.format(
        "[Combat] Quest enemy group spawned: requested=%d actual=%d reclaimed=%d (%s)",
        count, spawned, reclaimed, groupId or "anonymous"))
    return spawned
end

-- 兼容更短的调用名，所有别名仍指向同一个统一实现。
Combat.SpawnGroup = Combat.SpawnEnemyGroup
Combat.SpawnQuestGroup = Combat.SpawnEnemyGroup

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
    -- 立即触发掉落和经验。读取公开字段是为了兼容读档时直接写入
    -- Combat.killCount 的旧调用；之后始终保持私有/公开状态同步。
    if type(Combat.killCount) == "number" and Combat.killCount ~= killCount then
        killCount = Combat.killCount
    end
    killCount = killCount + 1
    Combat.killCount = killCount
    local awardedExp = enemy.exp
    if player then
        awardedExp = Balance.GetExperienceGain(
            enemy.exp, enemy.level, player.level, enemy.tier) * GetExperienceMultiplier(player)
        local newSkills = CharacterClass.AddExperience(player, awardedExp)
        if newSkills and Combat.onSkillUnlocked then
            for _, name in ipairs(newSkills) do
                Combat.onSkillUnlocked(name)
            end
        end
    end
    -- 神兽也获得经验
    DivineBeast.AddExp(awardedExp)
    if Combat.onEnemyDeath then
        Combat.onEnemyDeath(enemy.name, enemy.node.position, awardedExp, deathDur,
            enemy.tier, currentMapId, enemy.encounterId)
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

local function SetEnemyDisengaged(enemy, clearControl)
    if not enemy then return end
    enemy.state = enemy.tier == "boss" and "return" or "patrol"
    enemy.patrolTarget = nil
    enemy.patrolWait = 0
    enemy.attackTimer = math.max(enemy.attackTimer or 0, 0.25)
    if clearControl then
        enemy.knockbackTimer = 0
        enemy.knockbackDir = nil
        enemy.hitStunTimer = 0
    end
end

--- 玩家复活时重置所有仍存活的敌人。已经进入死亡/濒死状态的目标不会
--- 被重新拉起；存活目标会回满血并清除控制、攻击与仇恨残留。
---@return number restoredCount
function Combat.ResetLivingEnemiesForPlayerRevive()
    local restoredCount = 0

    for _, enemy in ipairs(enemies) do
        if enemy and enemy.node and enemy.state ~= "dead" and enemy.state ~= "dying" then
            enemy.hp = enemy.maxHP

            local hadPoison = (enemy.dotTimer or 0) > 0 or enemy.poisonTinted
            enemy.dotDamage = 0
            enemy.dotTimer = 0
            enemy.dotTickAccum = 0
            enemy.defReduction = 0
            enemy.defReductionTimer = 0
            enemy.trapCenter = nil
            enemy.trapRadius = nil
            enemy.trapTimer = nil
            enemy.trapDefReduced = nil
            enemy.knockbackTimer = 0
            enemy.knockbackDir = nil
            enemy.knockbackSpeed = nil
            enemy.hitStunTimer = 0
            enemy.hitFlashTimer = 0
            enemy.dyingTimer = 0

            SetEnemyDisengaged(enemy, true)
            enemy.attackTimer = math.max(0.35, enemy.attackTimer or 0)
            enemy.stuckCheckTimer = 0
            enemy.stuckRecoveries = 0
            enemy.lastMovePosition = enemy.node.position

            if hadPoison then RemovePoisonTint(enemy) end
            if enemy.animData then
                enemy.animData.onComplete = nil
                MonsterSkeleton.PlayAnim(enemy.animData, "idle", nil)
            end

            local body = enemy.node:GetComponent("RigidBody")
            if body then body:SetLinearVelocity(Vector3.ZERO) end
            restoredCount = restoredCount + 1
        end
    end

    lastPlayerTarget = nil
    return restoredCount
end

local function UpdateBossStuckRecovery(enemy, dt, isMoving, moveTargetPos)
    if not enemy or enemy.tier ~= "boss" or not enemy.node then return end
    if not isMoving or not moveTargetPos then
        enemy.stuckCheckTimer = 0
        enemy.lastMovePosition = enemy.node.position
        return
    end

    enemy.stuckCheckTimer = (enemy.stuckCheckTimer or 0) + math.max(0, dt or 0)
    if enemy.stuckCheckTimer < 0.75 then return end

    local currentPos = enemy.node.position
    local previousPos = enemy.lastMovePosition or currentPos
    local moved = currentPos - previousPos
    moved.y = 0
    if moved:Length() < 0.16 then
        local forward = moveTargetPos - currentPos
        forward.y = 0
        if forward:Length() > 0.001 then
            forward = forward:Normalized()
            enemy.stuckRecoveries = (enemy.stuckRecoveries or 0) + 1
            local sideSign = enemy.stuckRecoveries % 2 == 0 and -1 or 1
            local side = Vector3(-forward.z * sideSign, 0, forward.x * sideSign)
            local candidate = currentPos + forward * 0.45 + side * 1.15

            -- 连续三次仍无法移动时回到出生守点，避免被地标或地图边界永久夹住。
            if enemy.stuckRecoveries >= 3 and enemy.homePosition then
                candidate = Vector3(
                    enemy.homePosition.x,
                    enemy.homePosition.y,
                    enemy.homePosition.z)
                enemy.state = "guard"
                enemy.stuckRecoveries = 0
            end
            candidate = MapZone.ClampToArena(candidate, 0.85) or candidate
            candidate = MoveOutsideSafeZone(candidate, currentMapId, 0.85) or candidate
            enemy.node.position = candidate
            local body = enemy.node:GetComponent("RigidBody")
            if body then body:SetLinearVelocity(Vector3.ZERO) end
        end
    else
        enemy.stuckRecoveries = 0
    end

    enemy.lastMovePosition = enemy.node.position
    enemy.stuckCheckTimer = 0
end

-- ============================================================================
-- 敌人 AI 更新
-- ============================================================================
function Combat.UpdateEnemies(dt, playerNode, player)
    if not playerNode or type(player) ~= "table" then return end
    local playerPos = playerNode.position
    local playerInSafeZone = IsInSafeZone(playerPos)
    if playerInSafeZone and not playerWasInSafeZone then
        -- 必须早于 DOT tick 和其它战斗系统更新执行，确保进入安全区的同一帧
        -- 就清掉毒、火墙、困魔、弹道与冲刺，不留下“最后一跳”伤害。
        Combat.CancelPlayerHostileEffects()
    end
    playerWasInSafeZone = playerInSafeZone

    for i = #enemies, 1, -1 do
        -- 将单次迭代放进独立作用域。Lua 5.4 禁止 goto 跳入后续 local
        -- 的作用域；continue 标签留在作用域外，所有提前跳转都只会退出本轮。
        do
        local e = enemies[i]
        if not e or not e.node then
            table.remove(enemies, i)
            goto continue
        end
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
        local boundedPos, hitBoundary = MapZone.ClampToArena(pos, 0.75)
        if hitBoundary and boundedPos then
            e.node.position = boundedPos
            pos = boundedPos
            local boundaryBody = e.node:GetComponent("RigidBody")
            if boundaryBody then boundaryBody:SetLinearVelocity(Vector3.ZERO) end
            e.patrolTarget = nil
        end
        -- 物理挤压、击退或旧状态可能把怪物送进安全区。先把实体推出边界，
        -- 再执行 DOT 与 AI，确保安全区内不会发生任何一帧的伤害结算。
        if IsInSafeZone(pos) then
            local outside = MoveOutsideSafeZone(pos, currentMapId, 0.85)
            if outside then
                e.node.position = outside
                pos = outside
            end
            SetEnemyDisengaged(e, true)
            e.trapCenter = nil
            e.trapRadius = nil
            e.trapTimer = nil
            e.trapDefReduced = nil
        end
        local toPlayer = playerPos - pos
        toPlayer.y = 0
        local dist = toPlayer:Length()
        local eBody = e.node:GetComponent("RigidBody")

        -- DOT 伤害 (施毒术)：每 0.5 秒结算一次
        if (e.dotTimer or 0) > 0 then
            e.dotTimer = e.dotTimer - dt
            e.dotTickAccum = (e.dotTickAccum or 0) + dt
            local tickInterval = e.dotTickInterval or 0.5
            while e.dotTickAccum >= tickInterval and e.dotTimer > 0 do
                e.dotTickAccum = e.dotTickAccum - tickInterval
                local dealt = Combat.DealDamage(e, (e.dotDamage or 0) * tickInterval, player, {
                    ignoreDefense = true,
                    canCrit = false,
                    hitStun = false,
                })
                if dealt <= 0 or e.state == "dying" or e.state == "dead" then
                    break
                end
            end
            if e.dotTimer <= 0 then
                e.dotDamage = 0
                e.dotTickAccum = 0
                -- 中毒结束，移除绿色效果
                RemovePoisonTint(e)
            end
        end

        -- 减防衰减
        if (e.defReductionTimer or 0) > 0 then
            e.defReductionTimer = e.defReductionTimer - dt
            if e.defReductionTimer <= 0 then
                e.defReduction = 0
            end
        end

        -- 受击闪烁
        if (e.hitFlashTimer or 0) > 0 then
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

        -- 安全区是完整的战斗隔离区：怪物进入 attack 状态后，玩家再退回
        -- 安全区也必须立即停止伤害，不能只在 chase 分支拦截追击。
        -- 同时清掉速度和攻击状态，避免离开安全区后一帧继续沿用旧攻击窗口。
        if playerInSafeZone then
            SetEnemyDisengaged(e, true)
            if e.tier ~= "boss" then
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
                goto continue
            end
        end

        -- 状态机
        e.attackTimer = math.max(0, e.attackTimer - dt)

        local isMoving = false
        local moveAnimName = "run"
        local moveTargetPos = nil

        -- 抗拒火环击退：被推开期间强制水平位移，跳过正常 AI（避免速度被状态机覆盖）
        if (e.knockbackTimer or 0) > 0 then
            e.knockbackTimer = e.knockbackTimer - dt
            if eBody and e.knockbackDir then
                ---@cast e.knockbackDir Vector3
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

        if e.state == "guard" then
            -- Boss 守点：在出生点附近短距离巡弋；玩家或神兽进入警戒范围后追击。
            ---@type Vector3|nil
            local beastPos = DivineBeast.GetPosition()
            if beastPos and IsInSafeZone(beastPos) then beastPos = nil end
            local beastDist = beastPos and (beastPos - pos):Length() or 9999
            if dist < e.chaseRange or beastDist < e.chaseRange then
                e.state = "chase"
                e.patrolTarget = nil
            else
                local home = e.homePosition or pos
                local toHome = home - pos
                toHome.y = 0
                if toHome:Length() > (e.guardRadius or 2.0) * 1.8 then
                    e.state = "return"
                    e.patrolTarget = nil
                else
                    e.patrolWait = math.max(0, (e.patrolWait or 0) - dt)
                    if not e.patrolTarget and e.patrolWait <= 0 then
                        local angle = math.random() * math.pi * 2
                        local radius = (e.guardRadius or 2.0) * (0.45 + math.random() * 0.55)
                        local guardTarget = Vector3(
                            home.x + math.cos(angle) * radius,
                            home.y,
                            home.z + math.sin(angle) * radius)
                        guardTarget = MapZone.ClampToArena(guardTarget, 0.85) or guardTarget
                        e.patrolTarget = MoveOutsideSafeZone(guardTarget, currentMapId, 0.85) or guardTarget
                    end

                    if e.patrolTarget then
                        local dir = e.patrolTarget - pos
                        dir.y = 0
                        if dir:Length() > 0.45 then
                            dir = dir:Normalized()
                            if eBody then eBody:SetLinearVelocity(dir * e.speed * 0.38) end
                            FaceEnemyDir(e, dir)
                            isMoving = true
                            moveAnimName = "walk"
                            moveTargetPos = e.patrolTarget
                        else
                            if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
                            e.patrolTarget = nil
                            e.patrolWait = 1.2 + math.random() * 1.8
                        end
                    elseif eBody then
                        eBody:SetLinearVelocity(Vector3.ZERO)
                    end
                end
            end

        elseif e.state == "return" then
            -- 脱战回位不等待长前摇；安全区、重生与失去目标都能立即切入。
            local home = e.homePosition
            if not home then
                e.state = "patrol"
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            else
                local dir = home - pos
                dir.y = 0
                if dir:Length() <= 0.65 then
                    e.node.position = Vector3(home.x, home.y, home.z)
                    if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
                    e.state = "guard"
                    e.patrolTarget = nil
                    e.patrolWait = 0.8
                    e.attackTimer = math.max(e.attackTimer or 0, 0.35)
                else
                    dir = dir:Normalized()
                    if eBody then eBody:SetLinearVelocity(dir * (e.returnSpeed or e.speed)) end
                    FaceEnemyDir(e, dir)
                    isMoving = true
                    moveAnimName = "run"
                    moveTargetPos = home
                end
            end

        elseif e.state == "patrol" then
            -- 巡逻：发现玩家或神兽时追击
            ---@type Vector3|nil
            local beastPos = DivineBeast.GetPosition()
            if beastPos and IsInSafeZone(beastPos) then beastPos = nil end
            local beastDist = beastPos and (beastPos - pos):Length() or 9999
            if dist < e.chaseRange or beastDist < e.chaseRange then
                e.state = "chase"
            else
                if not e.patrolTarget or e.patrolWait <= 0 then
                    -- 围绕出生点巡逻，避免以当前位置连续随机游走，最终把
                    -- 全图怪物漂移并堆积到玩家已经离开的区域。
                    local patrolCenter = e.homePosition or pos
                    local rx = patrolCenter.x + (math.random() - 0.5) * 8
                    local rz = patrolCenter.z + (math.random() - 0.5) * 8
                    local patrolTarget = MoveOutsideSafeZone(Vector3(rx, 0, rz), currentMapId, 0.85)
                    e.patrolTarget = MapZone.ClampToArena(patrolTarget, 0.75) or patrolTarget
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
                    moveTargetPos = e.patrolTarget
                else
                    if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
                end
            end

        elseif e.state == "chase" then
            -- 安全区保护：玩家在安全区内时，怪物停止追击并返回巡逻
            if playerInSafeZone then
                SetEnemyDisengaged(e, true)
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
                goto continue
            end

            -- 追击玩家或神兽（谁近追谁）
            ---@type Vector3|nil
            local chaseBeastPos = DivineBeast.GetPosition()
            if chaseBeastPos and IsInSafeZone(chaseBeastPos) then chaseBeastPos = nil end
            local chaseBeastDist = chaseBeastPos and (chaseBeastPos - pos):Length() or 9999
            local chaseTargetPos = playerPos
            local chaseTargetDist = dist
            if chaseBeastDist < chaseTargetDist then
                chaseTargetPos = chaseBeastPos
                chaseTargetDist = chaseBeastDist
            end

            local homeDist = 0
            if e.tier == "boss" and e.homePosition then
                local toHome = pos - e.homePosition
                toHome.y = 0
                homeDist = toHome:Length()
            end

            if e.tier == "boss" and homeDist > (e.leashRange or e.chaseRange * 1.5) then
                SetEnemyDisengaged(e, true)
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            elseif chaseTargetDist > e.chaseRange * 1.5 then
                SetEnemyDisengaged(e, false)
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            elseif chaseTargetDist <= e.attackRange then
                e.state = "attack"
                FaceEnemyTarget(e, chaseTargetPos)
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            else
                local dir = (chaseTargetPos - pos)
                dir.y = 0
                dir = dir:Normalized()
                local chaseSpeed = e.speed
                if e.attackMode == "charge" and chaseTargetDist <= (e.chargeRange or 8.0)
                    and e.attackTimer <= 0 then
                    chaseSpeed = math.min(chaseSpeed * 1.45, ENEMY_MAX_SPEED)
                end
                if eBody then
                    eBody:SetLinearVelocity(dir * chaseSpeed)
                end
                FaceEnemyDir(e, dir)
                isMoving = true
                moveAnimName = "run"
                moveTargetPos = chaseTargetPos
            end

        elseif e.state == "attack" then
            -- 攻击玩家或神兽（站定攻击）
            if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end

            -- 判断攻击目标：优先攻击更近的（玩家或神兽）
            local attackTarget = "player"
            local attackDist = dist
            ---@type Vector3|nil
            local beastPos = DivineBeast.GetPosition()
            if beastPos and IsInSafeZone(beastPos) then beastPos = nil end
            if beastPos then
                local toBeast = (beastPos - pos):Length()
                if toBeast < attackDist then
                    attackTarget = "beast"
                    attackDist = toBeast
                end
            end

            if attackDist > e.attackRange * 1.35 then
                e.state = "chase"
            else
                -- 面向目标
                local targetPos = attackTarget == "beast" and beastPos or playerPos
                if not targetPos or IsInSafeZone(targetPos) then
                    SetEnemyDisengaged(e, true)
                    goto continue
                end
                FaceEnemyTarget(e, targetPos)

                if e.attackTimer <= 0 then
                    -- 播放攻击动画
                    if e.animData then
                        MonsterSkeleton.PlayAnim(e.animData, "attack", nil)
                    end

                    if e.attackMode == "fire_breath" then
                        local scene = e.node:GetScene()
                        if scene then
                            Combat.SpawnFireBreathVisual(scene, pos, targetPos, e.attackRange)
                        end
                    elseif e.attackMode == "venom_spit" then
                        local scene = e.node:GetScene()
                        if scene then
                            Combat.SpawnBossAttackVisual(scene, "venom_spit", pos, targetPos, e.attackRange)
                        end
                    elseif e.attackMode == "ground_slam" then
                        local scene = e.node:GetScene()
                        if scene then
                            Combat.SpawnBossAttackVisual(scene, "ground_slam", pos, targetPos, e.attackRange)
                        end
                    elseif e.attackMode == "charge" then
                        local scene = e.node:GetScene()
                        if scene then
                            Combat.SpawnBossAttackVisual(scene, "charge", pos, targetPos, e.attackRange)
                        end
                    end

                    if e.attackMode == "ground_slam" then
                        -- 震地是以 Boss 为中心的实际范围伤害；玩家与神兽都在
                        -- 范围内时会同时受击，不再表现为 1.5 米站桩拳。
                        if dist <= e.attackRange and not IsInSafeZone(playerPos) then
                            ApplyEnemyDamageToPlayer(e, player, playerPos)
                        end
                        local slamBeastPos = DivineBeast.GetPosition()
                        if slamBeastPos and not IsInSafeZone(slamBeastPos) then
                            local toBeast = slamBeastPos - pos
                            toBeast.y = 0
                            if toBeast:Length() <= e.attackRange then
                                DivineBeast.TakeDamage(e.atk * (e.attackDamageScale or 1.0))
                            end
                        end
                        e.attackTimer = e.attackCD
                    elseif attackTarget == "beast" then
                        -- 攻击神兽
                        DivineBeast.TakeDamage(e.atk * (e.attackDamageScale or 1.0))
                        e.attackTimer = e.attackCD
                    else
                        -- 攻击玩家
                        ApplyEnemyDamageToPlayer(e, player, playerPos)
                        e.attackTimer = e.attackCD
                    end
                end
            end
        end

        -- 困魔咒：普通怪会被限制在区域内；Boss 只承受减防，不会被永久
        -- 卡在法阵边缘而失去追击、回位和卡位自救能力。
        if e.tier ~= "boss" and e.trapCenter and e.trapRadius then
            local ePos = e.node.position
            local toCenter = ePos - e.trapCenter
            toCenter.y = 0
            local distFromCenter = toCenter:Length()
            if distFromCenter > e.trapRadius * 0.9 then
                -- 拉回到边界内
                local clampDir = toCenter:Normalized()
                local clampedPos = e.trapCenter + clampDir * (e.trapRadius * 0.85)
                clampedPos.y = ePos.y
                e.node.position = MoveOutsideSafeZone(clampedPos, currentMapId, 0.85) or clampedPos
                -- 清除速度防止继续外移
                local eBody = e.node:GetComponent("RigidBody")
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            end
        end

        -- 速度已经写入刚体后，用跨帧位移判断是否真的前进。Boss 若被地标、
        -- 地图边界或旧碰撞体夹住，会先侧移尝试，连续失败再回出生守点。
        UpdateBossStuckRecovery(e, dt, isMoving, moveTargetPos)

        -- 更新骨架动画
        if e.animData then
            MonsterSkeleton.UpdateAnimation(e.animData, dt, isMoving, moveAnimName)
        end

        end
        ::continue::
    end
end

-- ============================================================================
-- 技能释放
-- ============================================================================
---@param scene Scene
---@param player table
---@param playerNode Node
---@param skillSlot number
function Combat.CastSkill(scene, player, playerNode, skillSlot)
    if not scene or type(player) ~= "table" or not playerNode
        or type(player.equippedSkills) ~= "table" then
        return false, "角色状态异常"
    end
    local slot = SafeInteger(skillSlot, nil, 1, 20)
    if not slot then return false, "技能槽位无效" end
    local skill = player.equippedSkills[slot]
    if not skill then return false, "无技能" end

    -- 最终施法入口必须再次检查安全区。主界面按键检查只能覆盖按下按钮
    -- 的瞬间，带前摇技能仍可能在结算前进入安全区。
    if IsHostileSkill(skill) and IsInSafeZone(playerNode.position) then
        return false, "安全区内无法攻击"
    end

    local canCast, reason = CharacterClass.CanCastSkill(player, skill)
    if not canCast then return false, reason end

    -- 消耗 MP，触发 CD
    player.mp = player.mp - skill.manaCost
    player.cooldowns[skill.id] = skill.cooldown

    -- 播放技能施放音效（按技能类型映射，提高手感识别度）
    if skill.type == SKILL_TYPE.MELEE then
        SoundManager.Play("sword_swing")
    elseif skill.type == SKILL_TYPE.RANGED and skill.id == "m_thunder" then
        SoundManager.Play("thunder")
    elseif skill.type == SKILL_TYPE.RANGED then
        SoundManager.Play("fireball")
    elseif skill.type == SKILL_TYPE.AOE then
        SoundManager.Play("explosion")
    elseif skill.type == SKILL_TYPE.BUFF then
        SoundManager.Play("buff")
    elseif skill.type == SKILL_TYPE.HEAL then
        SoundManager.Play("heal")
    elseif skill.type == SKILL_TYPE.DASH then
        SoundManager.Play("dash")
    end

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
        local dmg = GetSkillDamage(player, skill)
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
                            local dealt = Combat.DealDamage(e, dmg, player)
                            if dealt > 0 then hitCount = hitCount + 1 end
                        end
                    end
                end
            end
        elseif target then
            local dealt = Combat.DealDamage(target, dmg, player)
            if dealt > 0 then
                RememberPlayerTarget(target)
                hitCount = 1
            end
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
                    if IsEnemyTargetable(e) then
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
                    local dealt = Combat.DealDamage(bestE, procDmg, player, { armorPen = ASSASSIN_ARMOR_PEN })
                    if dealt > 0 then RememberPlayerTarget(bestE) end
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
        local dmg = GetSkillDamage(player, skill)

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
            ---@type Vector3
            local strikePos = playerPos
            if target then
                strikePos = target.node.position
                local dealt = Combat.DealDamage(target, dmg, player)
                if dealt > 0 then RememberPlayerTarget(target) end
            else
                ---@cast dir Vector3
                strikePos = playerPos + dir * (skill.range or 6)
                -- 对落点范围内的敌人造成伤害
                for _, e in ipairs(enemies) do
                    if IsEnemyTargetable(e) then
                        ---@type Vector3
                        local enemyPos = e.node.position
                        local d = (enemyPos - strikePos):Length()
                        if d <= 1.5 then
                            local dealt = Combat.DealDamage(e, dmg, player)
                            if dealt > 0 then RememberPlayerTarget(e) end
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
        -- 地裂斩：以玩家朝向发出穿透式地面爆裂波。
        -- 伤害随波前进逐个结算，同一目标在单次施法中只命中一次。
        if skill.isGroundWave then
            local dmg = GetSkillDamage(player, skill)
            local dir = NormalizeHorizontal(playerDir)
            playerNode.rotation = Quaternion(math.deg(math.atan2(dir.x, dir.z)), Vector3.UP)
            Combat.SpawnEarthRiftWave(scene, playerPos, dir, dmg, skill)
            return true, "aoe"
        end

        -- 抗拒火环：以玩家自身为中心，无直接伤害，纯击退（在伤害计算前拦截）
        if skill.isKnockback then
            local kbRadius = skill.aoeRadius or skill.range or 3.0
            local kbSpeed = skill.knockbackSpeed or 14
            local kbDur = skill.knockbackDuration or 0.4
            for _, e in ipairs(enemies) do
                if IsEnemyTargetable(e) then
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
                        local controlScale = e.tier == "boss" and 0.25 or 1.0
                        e.knockbackDir = kbDir
                        e.knockbackSpeed = kbSpeed * controlScale
                        e.knockbackTimer = kbDur * controlScale
                        e.hitStunTimer = 0  -- 打断硬直，立即被推开
                        if e.state == "patrol" or e.state == "guard" or e.state == "return" then
                            e.state = "chase"
                            e.patrolTarget = nil
                        end
                    end
                end
            end
            -- 火环视觉（以玩家为中心绽放）
            Combat.SpawnAOEVisual(scene, playerPos, kbRadius, player.classId, skill.id)
            return true, "aoe"
        end

        -- 范围：ATK × 倍率百分比
        local dmg = GetSkillDamage(player, skill)
        local radius = skill.aoeRadius or skill.range

        -- 如果有目标，以目标为中心；否则以玩家前方为中心
        ---@type Vector3
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
                if IsEnemyTargetable(e) then
                    local toE = e.node.position - center
                    toE.y = 0
                    local d = toE:Length()
                    if d <= radius then
                        if e.tier == "boss" then
                            -- Boss 保留减防收益，但不接受位置囚禁。
                            e.trapCenter = nil
                            e.trapRadius = nil
                        else
                            e.trapCenter = center
                            e.trapRadius = radius
                        end
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
            if IsEnemyTargetable(e) then
                ---@type Vector3
                local enemyPos = e.node.position
                local d = (enemyPos - center):Length()
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
        local dps = GetSkillDamage(player, skill)
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
                if IsEnemyTargetable(e) then
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
            player.shieldHP = math.max(1,
                math.floor(player.maxHP * shieldPct / 100 + 0.5))
            player.shieldTimer = dur
            -- 护盾视觉效果
            Combat.SpawnShieldVisual(scene, playerNode, skill.id, dur)
        end
        return true, "buff"

    elseif skill.type == SKILL_TYPE.HEAL then
        -- 治疗（同时治疗自己和神兽）
        local healPct = skill.healPercent
            * (CharacterClass.GetHealingMultiplier
                and CharacterClass.GetHealingMultiplier(player) or 1.0)
        local requestedHeal = math.max(1,
            math.floor(player.maxHP * healPct / 100 + 0.5))
        local oldHP = player.hp
        player.hp = math.min(player.maxHP, player.hp + requestedHeal)
        local healAmount = player.hp - oldHP
        -- 同时治疗神兽
        if DivineBeast.IsAlive() then
            local info = DivineBeast.GetDisplayInfo()
            if info then
                local beastHeal = math.max(1,
                    math.floor(info.maxHP * healPct / 100 + 0.5))
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
            local summonAttack = GetSkillDamage(player, skill)
                * GetBeastAttackMultiplier(player)
            local ok = DivineBeast.Summon(scene, playerPos, summonAttack, player)
            if not ok then
                -- 已存在，返还 MP 和 CD
                player.mp = player.mp + skill.manaCost
                player.cooldowns[skill.id] = 0
                return false, "神兽已存在"
            end
            return true, "summon"
        else
            -- 普通召唤兽
            local summonAtk = GetSkillDamage(player, skill) * GetBeastAttackMultiplier(player)
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
--- @param opts table|nil 可选: { armorPen=0~1, ignoreDefense=false, canCrit=true, hitStun=true }
---@return number damage 实际结算伤害；0 表示目标无效或处于安全区
---@return boolean isCrit
function Combat.DealDamage(enemy, baseDmg, player, opts)
    if not IsEnemyTargetable(enemy) then return 0, false end

    baseDmg = tonumber(baseDmg)
    if not IsFiniteNumber(baseDmg) or baseDmg <= 0 then return 0, false end
    baseDmg = math.min(baseDmg, MAX_COMBAT_VALUE)

    local armorPen = opts and tonumber(opts.armorPen) or 0
    if not IsFiniteNumber(armorPen) then armorPen = 0 end
    armorPen = math.max(0, math.min(1, armorPen))

    local enemyDef = tonumber(enemy.def)
    if not IsFiniteNumber(enemyDef) then enemyDef = 0 end
    local defReduction = tonumber(enemy.defReduction)
    if not IsFiniteNumber(defReduction) then defReduction = 0 end
    local dmg = Balance.CalculateDamage(baseDmg, enemyDef, {
        armorPen = armorPen,
        defenseReduction = defReduction,
        ignoreDefense = opts and opts.ignoreDefense,
    })
    if dmg <= 0 then return 0, false end

    -- 暴击 (10% 概率, 1.5 倍)
    local canCrit = not opts or opts.canCrit ~= false
    local isCrit = canCrit and math.random() < 0.10
    if isCrit then dmg = math.min(MAX_COMBAT_VALUE, math.floor(dmg * 1.5)) end

    enemy.hp = math.max(0, enemy.hp - dmg)
    enemy.hitFlashTimer = 0.15

    -- 播放受击动画 + 短暂硬直（不打断攻击动画，hp>0 时才播放）
    local allowHitStun = not opts or opts.hitStun ~= false
    if allowHitStun and enemy.hp > 0 and enemy.animData and enemy.animData.state ~= "attack" then
        MonsterSkeleton.PlayAnim(enemy.animData, "hit", nil)
        enemy.hitStunTimer = enemy.tier == "boss" and 0.08 or 0.25
    end

    -- hp <= 0 立即标记死亡（不等下一帧检测）
    if enemy.hp <= 0 then
        enemy.hp = 0
        Combat.TriggerDeath(enemy, player)
    end

    -- 被击中后立刻进入追击状态
    if enemy.state ~= "dying" and enemy.state ~= "dead"
        and (enemy.state == "patrol" or enemy.state == "guard" or enemy.state == "return") then
        enemy.state = "chase"
        enemy.patrolTarget = nil
    end

    -- 回调飘字
    if Combat.onDamageDealt then
        Combat.onDamageDealt(dmg, isCrit, enemy.node.position)
    end
    return dmg, isCrit
end

-- ============================================================================
-- 弹道系统（根据技能 ID 分化视觉效果）
-- ============================================================================
function Combat.SpawnProjectile(scene, origin, dir, damage, skill, player)
    if not scene or not origin or not dir or type(skill) ~= "table"
        or IsInSafeZone(origin) then
        return nil
    end
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
    return projNode
end

-- ============================================================================
-- 地裂斩：沿地面前进的穿透 AOE 波
-- ============================================================================
---@param scene Scene
---@param origin Vector3
---@param dir Vector3
---@param damage number
---@param skill table
---@return Node|nil
function Combat.SpawnEarthRiftWave(scene, origin, dir, damage, skill)
    if not scene or not origin or not dir or type(skill) ~= "table"
        or IsInSafeZone(origin) then
        return nil
    end

    local fwd = NormalizeHorizontal(dir)
    local radius = tonumber(skill.aoeRadius) or 1.25
    local startOffset = math.min(1.0, math.max(0.35, radius * 0.75))
    local waveNode = scene:CreateChild("Projectile")
    waveNode.position = Vector3(
        origin.x + fwd.x * startOffset,
        0.04,
        origin.z + fwd.z * startOffset)
    waveNode.rotation = Quaternion(math.deg(math.atan2(fwd.x, fwd.z)), Vector3.UP)

    -- 地面爆心：深褐色尘浪托底，中心金橙色裂缝提供移动方向。
    local dustNode = waveNode:CreateChild("earthDust")
    dustNode.scale = Vector3(radius * 1.9, 0.06, radius * 1.45)
    local dustModel = dustNode:CreateComponent("StaticModel")
    dustModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    local dustMat = Material:new()
    dustMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    dustMat:SetShaderParameter("MatDiffColor", Variant(Color(0.24, 0.12, 0.045, 0.55)))
    dustMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.18, 0.055, 0.008)))
    dustMat:SetShaderParameter("Metallic", Variant(0.0))
    dustMat:SetShaderParameter("Roughness", Variant(0.92))
    dustModel:SetMaterial(dustMat)
    dustModel.castShadows = false

    local crackMat = Material:new()
    crackMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    crackMat:SetShaderParameter("MatDiffColor", Variant(Color(1.0, 0.48, 0.06, 0.82)))
    crackMat:SetShaderParameter("MatEmissiveColor", Variant(Color(1.35, 0.42, 0.025)))
    crackMat:SetShaderParameter("Metallic", Variant(0.0))
    crackMat:SetShaderParameter("Roughness", Variant(0.32))

    local crackOffsets = {-0.18, 0.12, -0.08, 0.20, -0.14}
    ---@type number[]
    local crackAngles = {-14, 11, -8, 16, -10}
    for i = 1, 5 do
        local crack = waveNode:CreateChild("earthCrack" .. i)
        crack.position = Vector3(crackOffsets[i] * radius, 0.035, (i - 3) * 0.34)
        crack.rotation = Quaternion(crackAngles[i] or 0, Vector3.UP)
        crack.scale = Vector3(0.10 + i * 0.008, 0.025, 0.52)
        local crackModel = crack:CreateComponent("StaticModel")
        crackModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        crackModel:SetMaterial(crackMat)
        crackModel.castShadows = false
    end

    -- 爆裂石片固定排列，既保持帧间稳定，又形成两侧向上掘起的冲击感。
    local rockMat = CreatePBR(Color(0.23, 0.15, 0.09, 1.0), 0.0, 0.94)
    rockMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.08, 0.025, 0.004)))
    local rockLayout = {
        {-0.78, 0.18, -0.30,  24, 0.24, 0.32},
        { 0.72, 0.24, -0.18, -28, 0.22, 0.38},
        {-0.55, 0.34,  0.22,  34, 0.18, 0.48},
        { 0.48, 0.30,  0.34, -36, 0.20, 0.44},
        {-0.28, 0.42,  0.02,  18, 0.15, 0.58},
        { 0.22, 0.46,  0.10, -16, 0.14, 0.62},
    }
    for i, data in ipairs(rockLayout) do
        local rock = waveNode:CreateChild("earthRock" .. i)
        rock.position = Vector3(data[1] * radius, data[2], data[3])
        rock.rotation = Quaternion(data[4], i * 37, data[4] * 0.45)
        rock.scale = Vector3(data[5], data[6], data[5] * 0.82)
        local rockModel = rock:CreateComponent("StaticModel")
        rockModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        rockModel:SetMaterial(rockMat)
        rockModel.castShadows = false
    end

    table.insert(projectiles, {
        node = waveNode,
        dir = fwd,
        speed = tonumber(skill.waveSpeed) or 11.0,
        damage = damage,
        range = math.max(0.1, (tonumber(skill.range) or 7.0) - startOffset),
        traveled = 0,
        skillId = skill.id or "w_earthsplit",
        groundWave = true,
        hitRadius = radius,
        hitEnemies = {},
    })
    return waveNode
end

function Combat.UpdateProjectiles(scene, dt, player)
    for i = #projectiles, 1, -1 do
        local p = projectiles[i]
        if not p or not p.node then
            table.remove(projectiles, i)
        else
            ---@type Vector3
            local projectilePos = p.node.position
            ---@cast p.dir Vector3
            ---@type Vector3
            local move = p.dir * p.speed * dt
            projectilePos = projectilePos + move
            p.node.position = projectilePos
            p.traveled = p.traveled + p.speed * dt

            local blockedBySafeZone = IsInSafeZone(projectilePos)
            if p.groundWave then
                -- 移动 AOE：波前缘扫过的多个目标均可受伤，但每个目标只结算一次。
                if not blockedBySafeZone then
                    local hitRadius = tonumber(p.hitRadius) or 1.25
                    p.hitEnemies = p.hitEnemies or {}
                    for _, e in ipairs(enemies) do
                        if IsEnemyTargetable(e) and not p.hitEnemies[e] then
                            local toEnemy = e.node.position - projectilePos
                            toEnemy.y = 0
                            if toEnemy:Length() <= hitRadius then
                                p.hitEnemies[e] = true
                                local dealt = Combat.DealDamage(e, p.damage, player)
                                if dealt > 0 then RememberPlayerTarget(e) end
                            end
                        end
                    end
                end
                if blockedBySafeZone or p.traveled >= p.range then
                    p.node:Remove()
                    table.remove(projectiles, i)
                end
            else
                -- 普通弹道：命中第一个目标后立即销毁。
                local hit = false
                ---@type Vector3
                local hitPos = projectilePos
                if not blockedBySafeZone then
                    for _, e in ipairs(enemies) do
                        if IsEnemyTargetable(e) then
                            ---@type Vector3
                            local enemyPos = e.node.position
                            local d = (enemyPos - projectilePos):Length()
                            if d < 1.0 then
                                local dealt = Combat.DealDamage(e, p.damage, player)
                                if dealt > 0 then
                                    RememberPlayerTarget(e)
                                    hit = true
                                    hitPos = enemyPos
                                    break
                                end
                            end
                        end
                    end
                end

                if blockedBySafeZone or hit or p.traveled >= p.range then
                    -- 灵魂火符命中时产生小爆炸
                    if hit and p.skillId == "t_talisman" then
                        Combat.SpawnTalismanBurst(scene, hitPos)
                    end
                    p.node:Remove()
                    table.remove(projectiles, i)
                end
            end
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

        node:SetVar("removeTimer", Variant(1.6))
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

    -- 起点：贴着武器(角色前方 0.6m，挥刀高度 1.35m)
    local startOffset = 0.6
    node.position = Vector3(center.x + fwd.x * startOffset, 1.35, center.z + fwd.z * startOffset)
    -- 朝向飞行方向：局部 +Z = 前方（飞行沿节点 forward）
    node.rotation = Quaternion(math.deg(math.atan2(fwd.x, fwd.z)), Vector3.UP)

    local segments = 24
    local halfAngle = math.rad(70)   -- 大弧度斩波(约140°)

    -- 在局部 YZ 纵向平面绘制一弯"月牙剑气"：弧形中心向局部 +Z 凸出并沿角色前方飞行
    local function buildCrescent(comp, R, thick)
        comp:BeginGeometry(0, TRIANGLE_LIST)
        local yc = math.cos(halfAngle) * R
        for i = 0, segments - 1 do
            local t0 = -1.0 + (i / segments) * 2.0
            local t1 = -1.0 + ((i + 1) / segments) * 2.0
            local a0 = t0 * halfAngle
            local a1 = t1 * halfAngle
            local c0 = math.cos(t0 * math.pi / 2)
            local c1 = math.cos(t1 * math.pi / 2)
            local th0 = thick * c0 * c0
            local th1 = thick * c1 * c1
            local oy0 = math.sin(a0) * R
            local oz0 = math.cos(a0) * R - yc
            local oy1 = math.sin(a1) * R
            local oz1 = math.cos(a1) * R - yc
            local iy0 = math.sin(a0) * (R - th0)
            local iz0 = math.cos(a0) * (R - th0) - yc
            local iy1 = math.sin(a1) * (R - th1)
            local iz1 = math.cos(a1) * (R - th1) - yc
            local nFront = Vector3(1, 0, 0)
            local nBack = Vector3(-1, 0, 0)
            comp:DefineVertex(Vector3(0, iy0, iz0)); comp:DefineNormal(nFront); comp:DefineTexCoord(Vector2(0, 0))
            comp:DefineVertex(Vector3(0, oy0, oz0)); comp:DefineNormal(nFront); comp:DefineTexCoord(Vector2(1, 0))
            comp:DefineVertex(Vector3(0, oy1, oz1)); comp:DefineNormal(nFront); comp:DefineTexCoord(Vector2(1, 1))
            comp:DefineVertex(Vector3(0, iy0, iz0)); comp:DefineNormal(nFront); comp:DefineTexCoord(Vector2(0, 0))
            comp:DefineVertex(Vector3(0, oy1, oz1)); comp:DefineNormal(nFront); comp:DefineTexCoord(Vector2(1, 1))
            comp:DefineVertex(Vector3(0, iy1, iz1)); comp:DefineNormal(nFront); comp:DefineTexCoord(Vector2(0, 1))
            comp:DefineVertex(Vector3(0, iy0, iz0)); comp:DefineNormal(nBack); comp:DefineTexCoord(Vector2(0, 0))
            comp:DefineVertex(Vector3(0, oy1, oz1)); comp:DefineNormal(nBack); comp:DefineTexCoord(Vector2(1, 1))
            comp:DefineVertex(Vector3(0, oy0, oz0)); comp:DefineNormal(nBack); comp:DefineTexCoord(Vector2(1, 0))
            comp:DefineVertex(Vector3(0, iy0, iz0)); comp:DefineNormal(nBack); comp:DefineTexCoord(Vector2(0, 0))
            comp:DefineVertex(Vector3(0, iy1, iz1)); comp:DefineNormal(nBack); comp:DefineTexCoord(Vector2(0, 1))
            comp:DefineVertex(Vector3(0, oy1, oz1)); comp:DefineNormal(nBack); comp:DefineTexCoord(Vector2(1, 1))
        end
        comp:Commit()
    end

    -- 按参考图分三层叠加：青蓝发光主体(铺开) + 青色中层 + 锋锐白色凸刃(最亮在上)
    -- 三层共享同一外凸刃(相同 R)，越往内越偏深蓝、越淡，形成渐变拖尾
    local function makeLayer(parent, name, xOff, R, thick, diff, emis, rough)
        local n = parent:CreateChild(name)
        n.position = Vector3(xOff, 0, 0)
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

    local function makeBladeGroup(name, yawOffset)
        local group = node:CreateChild(name)
        group.rotation = Quaternion(yawOffset, Vector3.UP)
        -- 主体：深青蓝、最宽、最透明（从凸刃向内大面积铺开）
        makeLayer(group, "bodyDeep", -0.06, 1.25, 0.90, Color(0.15, 0.42, 1.0, 0.16), Color(0.08, 0.22, 0.65), 0.5)
        -- 中层：亮青蓝发光带
        makeLayer(group, "bodyCyan", -0.03, 1.25, 0.48, Color(0.45, 0.82, 1.0, 0.30), Color(0.25, 0.55, 0.85), 0.3)
        -- 凸刃：锋锐白色亮边（最薄最亮，叠在最上层）
        makeLayer(group, "edge", 0.0, 1.28, 0.13, Color(0.95, 0.99, 1.0, 0.55), Color(0.65, 0.75, 0.85), 0.05)
    end

    -- 双片交叉剑气：两片围绕竖直轴各偏转 30°，交叉角约 60°，各角度都更清晰
    makeBladeGroup("bladeLeft", -30)
    makeBladeGroup("bladeRight", 30)

    -- 飞行：从武器位置朝节点前方短距甩出（由 UpdateVisuals 逐帧推进）
    local travelSpeed = 6.0      -- 短距飞行
    local travelRemain = 0.75    -- 缩短剑气飞行距离
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
            ---@type Vector3
            local zoneCenter = zone.center
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
                    if IsEnemyTargetable(e) then
                        local inZone = false
                        if zone.isRect then
                            -- 长方形判定：将敌人坐标转换到火墙本地坐标系
                            local dx = e.node.position.x - zoneCenter.x
                            local dz = e.node.position.z - zoneCenter.z
                            local cosA = math.cos(-zone.wallAngle)
                            local sinA = math.sin(-zone.wallAngle)
                            local localX = dx * cosA - dz * sinA
                            local localZ = dx * sinA + dz * cosA
                            inZone = math.abs(localX) <= zone.halfW and math.abs(localZ) <= zone.halfL
                        else
                            -- 圆形判定
                            local d2 = (e.node.position - zoneCenter):Length()
                            inZone = d2 <= zone.radius
                        end

                        if inZone then
                            -- tick式伤害：每次tick造成 dps * tickInterval 的伤害
                            local dmg = zone.tickInterval and (zone.dps * zone.tickInterval) or (zone.dps * dt)
                            Combat.DealDamage(e, dmg, player, {
                                ignoreDefense = true,
                                canCrit = false,
                                hitStun = false,
                            })
                        end
                    end
                end
            end

            -- 困魔区域：持续捕捉新进入的敌人
            if zone.isTrapZone then
                for _, e in ipairs(enemies) do
                    local needsTrap = e.tier == "boss"
                        and not e.trapTimer
                        or (e.tier ~= "boss" and not e.trapCenter)
                    if IsEnemyTargetable(e) and needsTrap then
                        local d = (e.node.position - zoneCenter):Length()
                        if d <= zone.radius then
                            if e.tier == "boss" then
                                e.trapCenter = nil
                                e.trapRadius = nil
                            else
                                e.trapCenter = zoneCenter
                                e.trapRadius = zone.radius
                            end
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
    if not playerNode or type(player) ~= "table" then return end
    local playerPos = playerNode.position
    local playerInSafeZone = IsInSafeZone(playerPos)

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
            -- 玩家已离开安全区而召唤物仍被碰撞留在里面时，将其送到边界外；
            -- 玩家位于安全区时则允许随从跟随，但保持完全停火。
            if not playerInSafeZone and IsInSafeZone(sPos) then
                local outside = MoveOutsideSafeZone(sPos, currentMapId, 0.5)
                if outside then
                    s.node.position = outside
                    sPos = outside
                end
            end
            local toPlayer = playerPos - sPos
            toPlayer.y = 0
            local distToPlayer = toPlayer:Length()
            local followSpeed = (s.summonType == "wolf") and 5.5 or 4.0

            local moved = false

            -- 攻击最近的敌人（优先级高于跟随）
            local chaseRange = (s.summonType == "wolf") and 6.0 or 4.5
            local canFight = not playerInSafeZone and not IsInSafeZone(sPos)
            if canFight and s.attackTimer <= 0 then
                local nearestEnemy, nearDist = Combat.FindNearestEnemy(s.node.position, chaseRange)
                if nearestEnemy then
                    local dir = nearestEnemy.node.position - s.node.position
                    dir.y = 0
                    local eDist = dir:Length()
                    if eDist > 0.001 then
                        dir = dir:Normalized()
                        local angle = math.atan2(dir.x, dir.z)
                        s.node.rotation = Quaternion(math.deg(angle), Vector3.UP)
                    end

                    if eDist <= 2.0 then
                        local dealt = Combat.DealDamage(nearestEnemy, s.atk, player)
                        if dealt > 0 then s.attackTimer = s.attackCD end
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
    if not scene then return end
    UpdateQuestEffects(dt)

    -- 清理 AOE / Crescent 视觉效果（场景根级别）
    local children = {}
    for i = 0, scene:GetNumChildren(false) - 1 do
        local child = scene:GetChild(i)
        if child.name == "AOEVisual" or child.name == "CrescentVisual"
            or child.name == "TalismanBurst" or child.name == "BossAttackVisual" then
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
-- 自动刷怪与显式遭遇
-- ============================================================================
local activeEncounterId = nil
local encounterRetryTimer = 0

local function FindEnemyDefByName(name)
    if not name then return nil end
    for _, def in ipairs(ENEMY_DEFS) do
        if def.name == name then return def end
    end
    return nil
end

local function RemoveStaleEncounterEnemies(keepEncounterId)
    for index = #enemies, 1, -1 do
        local enemy = enemies[index]
        if enemy and enemy.encounterId and enemy.encounterId ~= keepEncounterId then
            if enemy.node then enemy.node:Remove() end
            if lastPlayerTarget == enemy then lastPlayerTarget = nil end
            table.remove(enemies, index)
        end
    end
end

local function FindEncounterEnemy(encounterId)
    if type(encounterId) ~= "string" then return nil end
    for _, enemy in ipairs(enemies) do
        if enemy and enemy.encounterId == encounterId and enemy.node
            and enemy.state ~= "dead" then
            return enemy
        end
    end
    return nil
end

local function MakeEncounterRoom()
    local maxEnemies = MapZone.GetSpawnSettings(currentMapId).maxEnemies
    if #enemies < maxEnemies then return true end
    for index = #enemies, 1, -1 do
        local enemy = enemies[index]
        if enemy and not enemy.encounterId then
            if enemy.node then enemy.node:Remove() end
            if lastPlayerTarget == enemy then lastPlayerTarget = nil end
            table.remove(enemies, index)
            return true
        end
    end
    return #enemies < maxEnemies
end

--- 确保一个由外部系统描述的显式遭遇存在。
--- 该入口只接收纯数据，不读取 Quest；切图清场后传入同一 request 会恢复一只，
--- 每只实体上的 encounterId 则保证逐帧调用不会重复生成。
---@param scene Scene
---@param playerNode Node
---@param player table
---@param request table|nil {id,mapId,enemyName,x,z}
---@param dt number|nil
---@return table|nil
function Combat.EnsureEncounter(scene, playerNode, player, request, dt)
    if type(request) ~= "table" or type(request.id) ~= "string"
        or request.mapId ~= currentMapId then
        activeEncounterId = nil
        encounterRetryTimer = 0
        return nil
    end
    if not scene or not playerNode or type(player) ~= "table" then return nil end

    if activeEncounterId ~= request.id then
        activeEncounterId = request.id
        encounterRetryTimer = 0
        RemoveStaleEncounterEnemies(request.id)
    end

    local existing = FindEncounterEnemy(request.id)
    if existing then return existing end

    local elapsed = tonumber(dt) or 0
    encounterRetryTimer = math.max(0, encounterRetryTimer - math.max(0, elapsed))
    if encounterRetryTimer > 0 then return nil end

    local def = FindEnemyDefByName(request.enemyName)
    if not def then
        encounterRetryTimer = 3
        print("[Combat] Encounter enemy missing: " .. tostring(request.enemyName))
        return nil
    end
    if not MakeEncounterRoom() then
        encounterRetryTimer = 1
        return nil
    end

    local spawned = Combat.SpawnEnemy(scene, playerNode.position, player.level, def, currentMapId, {
        encounterId = request.id,
        position = { x = request.x, y = 0, z = request.z },
    })
    if spawned then
        encounterRetryTimer = 3
        print("[Combat] Encounter spawned: " .. def.name .. " (" .. request.id .. ")")
    else
        encounterRetryTimer = 1
    end
    return spawned
end

---@param playerPosition Vector3
---@return number
local function CountNearbyEnemiesForSpawner(playerPosition)
    local radiusSquared = SPAWNER_LOCAL_DENSITY_RADIUS * SPAWNER_LOCAL_DENSITY_RADIUS
    local count = 0
    for _, enemy in ipairs(enemies) do
        if IsEnemyTargetable(enemy) then
            local position = enemy.node.position
            local dx = position.x - playerPosition.x
            local dz = position.z - playerPosition.z
            if dx * dx + dz * dz <= radiusSquared then
                count = count + 1
            end
        end
    end
    return count
end

---@param enemy table|nil
---@return boolean
local function IsNaturalEnemyRecyclableForSpawner(enemy)
    if not enemy or not enemy.node or enemy == lastPlayerTarget then return false end
    local spawnSource = enemy.spawnSource or "natural"
    return spawnSource == "natural"
        and enemy.tier ~= "boss"
        and not enemy.encounterId
        and not enemy.questGroupId
        and enemy.state == "patrol"
        and IsEnemyTargetable(enemy)
        and (enemy.dotTimer or 0) <= 0
        and (enemy.defReductionTimer or 0) <= 0
        and (enemy.hitStunTimer or 0) <= 0
        and (enemy.knockbackTimer or 0) <= 0
        and not enemy.trapTimer
end

--- 全图达到硬上限、但玩家附近缺怪时，回收最远的一只闲置自然怪。
--- 不触发击杀、经验、掉落或任务进度；Boss、任务敌群和交战实体均受保护。
---@param playerPosition Vector3
---@return boolean
local function RecycleFarNaturalEnemyForSpawner(playerPosition)
    local minimumDistanceSquared = SPAWNER_FAR_RECYCLE_DISTANCE
        * SPAWNER_FAR_RECYCLE_DISTANCE
    local farthestDistanceSquared = minimumDistanceSquared
    local candidate = nil

    for _, enemy in ipairs(enemies) do
        if IsNaturalEnemyRecyclableForSpawner(enemy) then
            local position = enemy.node.position
            local dx = position.x - playerPosition.x
            local dz = position.z - playerPosition.z
            local distanceSquared = dx * dx + dz * dz
            if distanceSquared > farthestDistanceSquared then
                farthestDistanceSquared = distanceSquared
                candidate = enemy
            end
        end
    end

    return candidate ~= nil and RemoveEnemyImmediately(candidate)
end

function Combat.UpdateSpawner(scene, dt, playerNode, player)
    if not playerNode or not player then return end

    -- 地图自然生态始终使用同一套刷新逻辑，不读取或加权任何任务目标。
    -- initialCount 是玩家附近希望维持的基础密度；maxEnemies 只控制全图硬上限。
    local spawnSettings = MapZone.GetSpawnSettings(currentMapId)
    local maxEnemies = math.max(1, math.floor(tonumber(spawnSettings.maxEnemies) or 24))
    local localTarget = math.max(1, math.min(maxEnemies,
        math.floor(tonumber(spawnSettings.initialCount) or 8)))
    local nearbyCount = CountNearbyEnemiesForSpawner(playerNode.position)

    -- 附近已经达到地图基础密度时不继续向玩家身边堆怪。玩家移动、击杀或
    -- 怪物离开范围后，再从零开始计时补充，避免一进图迅速堆满全图上限。
    if nearbyCount >= localTarget then
        spawnTimer = 0
        return
    end

    spawnTimer = spawnTimer + dt
    local baseInterval = spawnSettings.interval
    local densityRatio = nearbyCount / localTarget
    local dynamicInterval = baseInterval * (densityRatio <= 0.5
        and SPAWNER_EMPTY_INTERVAL_MULTIPLIER
        or SPAWNER_REFILL_INTERVAL_MULTIPLIER)

    if IsBossNearbyForSpawner(playerNode.position) then
        dynamicInterval = dynamicInterval * BOSS_NEARBY_SPAWN_INTERVAL_MULTIPLIER
    end

    if spawnTimer >= dynamicInterval then
        -- 全图容量已满时，把远处、未交战的普通自然怪换到玩家附近；不扩大
        -- 总量，也不会删除任务敌群或 Boss。没有安全候选时等待下次再试。
        if #enemies >= maxEnemies
            and not RecycleFarNaturalEnemyForSpawner(playerNode.position) then
            spawnTimer = 0
            return
        end

        local spawned = Combat.SpawnEnemy(
            scene, playerNode.position, player.level, nil, currentMapId)
        if spawned then
            spawnTimer = 0
        else
            -- 配置或临时容量异常时保留半段进度，避免逐帧重试。
            spawnTimer = dynamicInterval * 0.5
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
            pickupDelayTimer = 0,
            magnetPhase = false,
            vel = 0,
        })
    end
end

local function CreateDropMaterial(color, metallic, roughness, emissiveScale)
    local mat = CreatePBR(color, metallic, roughness)
    local glow = emissiveScale or 0.0
    if glow > 0 then
        mat:SetShaderParameter("MatEmissiveColor", Variant(Color(color.r * glow, color.g * glow, color.b * glow)))
    end
    return mat
end

local function AddDropModelPart(parent, name, modelPath, position, scale, rotation, mat, castShadows)
    local part = parent:CreateChild(name)
    part.position = position
    part.scale = scale
    if rotation then part.rotation = rotation end

    local model = part:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", modelPath))
    model:SetMaterial(mat)
    model.castShadows = castShadows ~= false
    return part
end

local function BrightenColor(color, amount)
    amount = amount or 0.25
    return Color(
        math.min(1.0, color.r + amount),
        math.min(1.0, color.g + amount),
        math.min(1.0, color.b + amount),
        1.0
    )
end

local function DarkenColor(color, factor)
    factor = factor or 0.35
    return Color(color.r * factor, color.g * factor, color.b * factor, 1.0)
end

local function CreateDropCrystalMaterial(color, alpha, emissiveScale)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(color.r, color.g, color.b, alpha or 0.72)))
    mat:SetShaderParameter("MatSpecColor", Variant(Color(0.75, 0.8, 0.9, 1.0)))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    mat:SetShaderParameter("Roughness", Variant(0.05))
    local glow = emissiveScale or 0.8
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(color.r * glow, color.g * glow, color.b * glow)))
    return mat
end

local function AddSmallGem(parent, name, position, scale, mat)
    return AddDropModelPart(parent, name, "Models/Sphere.mdl", position, scale, nil, mat, true)
end

local function AddTrimBox(parent, name, position, scale, rotation, mat)
    return AddDropModelPart(parent, name, "Models/Box.mdl", position, scale, rotation, mat, true)
end

local function AddRing(parent, name, position, scale, rotation, mat)
    return AddDropModelPart(parent, name, "Models/Torus.mdl", position, scale, rotation, mat, true)
end

local function GetRarityVisualPower(rarity)
    if rarity == "LEGENDARY" then return 1.35 end
    if rarity == "EPIC" then return 1.05 end
    if rarity == "RARE" then return 0.78 end
    if rarity == "UNCOMMON" then return 0.52 end
    return 0.30
end

local function CreateDropGlowMaterial(color, alpha, emissiveScale)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(color.r, color.g, color.b, alpha or 0.28)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(color.r * (emissiveScale or 1.0), color.g * (emissiveScale or 1.0), color.b * (emissiveScale or 1.0))))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    mat:SetShaderParameter("Roughness", Variant(0.15))
    return mat
end

local function CreateGroundItemNameAndGlow(root, item, rarityInfo, rarityColor)
    local power = GetRarityVisualPower(item.rarity)
    local glowMat = CreateDropGlowMaterial(rarityColor, 0.18 + power * 0.16, 0.7 + power * 0.6)
    local halo = AddDropModelPart(root, "rarityGroundGlow", "Models/Cylinder.mdl", Vector3(0, -0.22, 0), Vector3(0.55 + power * 0.25, 0.012, 0.55 + power * 0.25), nil, glowMat, false)
    halo.rotation = Quaternion(0, 0, 0)

    local sparkMat = CreateDropCrystalMaterial(BrightenColor(rarityColor, 0.24), 0.52, 1.2 + power * 0.5)
    local sparkleCount = item.rarity == "LEGENDARY" and 6 or item.rarity == "EPIC" and 5 or item.rarity == "RARE" and 4 or 2
    for i = 1, sparkleCount do
        local a = (i - 1) / sparkleCount * math.pi * 2
        local d = 0.42 + power * 0.08
        AddSmallGem(root, "raritySpark" .. i, Vector3(math.cos(a) * d, 0.08 + (i % 2) * 0.08, math.sin(a) * d), Vector3(0.035, 0.035, 0.035), sparkMat)
    end

    -- 自发光光环和火花已经能清楚表达稀有度。不要为每件地面装备再创建
    -- 独立点光源：点光与透明掉落特效组合时会快速放大每帧 View 数量。

    local labelNode = root:CreateChild("itemNameLabel")
    labelNode.position = Vector3(0, 1.28, 0)
    local label = labelNode:CreateComponent("Text3D")
    label:SetFont("Fonts/MiSans-Regular.ttf", 18)
    label:SetText(item.name or "装备")
    label:SetColor(rarityColor)
    label:SetAlignment(HA_CENTER, VA_CENTER)
    label:SetTextAlignment(HA_CENTER)
    label:SetTextEffect(TE_SHADOW)
    label:SetEffectColor(Color(0, 0, 0, 0.9))
    label:SetEffectShadowOffset(IntVector2(2, 2))
    label:SetFaceCameraMode(FC_ROTATE_XYZ)
    label:SetFixedScreenSize(true)

    if rarityInfo and rarityInfo.name and item.rarity ~= "COMMON" then
        local rarityNode = root:CreateChild("itemRarityLabel")
        rarityNode.position = Vector3(0, 1.08, 0)
        local rarityLabel = rarityNode:CreateComponent("Text3D")
        rarityLabel:SetFont("Fonts/MiSans-Regular.ttf", 13)
        rarityLabel:SetText("[" .. rarityInfo.name .. "]")
        rarityLabel:SetColor(BrightenColor(rarityColor, 0.18))
        rarityLabel:SetAlignment(HA_CENTER, VA_CENTER)
        rarityLabel:SetTextAlignment(HA_CENTER)
        rarityLabel:SetTextEffect(TE_SHADOW)
        rarityLabel:SetEffectColor(Color(0, 0, 0, 0.85))
        rarityLabel:SetEffectShadowOffset(IntVector2(1, 1))
        rarityLabel:SetFaceCameraMode(FC_ROTATE_XYZ)
        rarityLabel:SetFixedScreenSize(true)
    end
end

local function CreateGroundEquipmentModel(root, item, rarityColor)
    local itemType = item.itemType or "weapon"
    local mainMat = CreateDropMaterial(rarityColor, 0.68, 0.20, 0.42)
    local brightMat = CreateDropMaterial(BrightenColor(rarityColor, 0.24), 0.82, 0.14, 0.58)
    local darkMat = CreateDropMaterial(DarkenColor(rarityColor, 0.26), 0.28, 0.62, 0.12)
    local gemMat = CreateDropCrystalMaterial(BrightenColor(rarityColor, 0.18), 0.78, 1.05)
    local steelMat = CreateDropMaterial(Color(0.74, 0.76, 0.80, 1.0), 0.92, 0.18, 0.10)
    local darkSteelMat = CreateDropMaterial(Color(0.36, 0.38, 0.42, 1.0), 0.9, 0.28, 0.02)
    local goldTrimMat = CreateDropMaterial(Color(1.0, 0.76, 0.22, 1.0), 0.95, 0.16, 0.18)
    local leatherMat = CreateDropMaterial(Color(0.24, 0.12, 0.045, 1.0), 0.0, 0.78, 0.0)

    if itemType == "weapon" then
        if item.id and string.find(item.id, "staff") then
            AddDropModelPart(root, "staffShaft", "Models/Cylinder.mdl", Vector3(0, 0.44, 0), Vector3(0.045, 0.84, 0.045), nil, leatherMat, true)
            AddRing(root, "staffLowerBand", Vector3(0, 0.18, 0), Vector3(0.10, 0.10, 0.10), Quaternion(90, 0, 0), goldTrimMat)
            AddRing(root, "staffUpperBand", Vector3(0, 0.64, 0), Vector3(0.11, 0.11, 0.11), Quaternion(90, 0, 0), goldTrimMat)
            AddDropModelPart(root, "staffOrb", "Models/Sphere.mdl", Vector3(0, 0.90, 0), Vector3(0.21, 0.21, 0.21), nil, gemMat, true)
            AddRing(root, "staffHalo", Vector3(0, 0.90, 0), Vector3(0.27, 0.27, 0.27), Quaternion(90, 0, 0), brightMat)
            AddTrimBox(root, "staffProngA", Vector3(-0.18, 0.91, 0), Vector3(0.04, 0.28, 0.04), Quaternion(0, 0, 18), brightMat)
            AddTrimBox(root, "staffProngB", Vector3(0.18, 0.91, 0), Vector3(0.04, 0.28, 0.04), Quaternion(0, 0, -18), brightMat)
            AddSmallGem(root, "staffTipGem", Vector3(0, 1.12, 0), Vector3(0.07, 0.07, 0.07), gemMat)
        elseif item.id and string.find(item.id, "bell") then
            AddDropModelPart(root, "bellBody", "Models/Cone.mdl", Vector3(0, 0.38, 0), Vector3(0.34, 0.44, 0.34), Quaternion(180, 0, 0), mainMat, true)
            AddRing(root, "bellRim", Vector3(0, 0.18, 0), Vector3(0.33, 0.33, 0.33), nil, goldTrimMat)
            AddRing(root, "bellMidBand", Vector3(0, 0.40, 0), Vector3(0.23, 0.23, 0.23), nil, brightMat)
            AddRing(root, "bellHandle", Vector3(0, 0.67, 0), Vector3(0.16, 0.16, 0.16), Quaternion(90, 0, 0), steelMat)
            AddSmallGem(root, "bellClapper", Vector3(0, 0.11, 0), Vector3(0.08, 0.08, 0.08), gemMat)
            AddSmallGem(root, "bellGemFront", Vector3(0, 0.42, -0.25), Vector3(0.07, 0.07, 0.05), gemMat)
        else
            AddTrimBox(root, "swordBlade", Vector3(0, 0.58, 0), Vector3(0.075, 0.68, 0.035), nil, steelMat)
            AddTrimBox(root, "swordEdgeL", Vector3(-0.052, 0.58, 0), Vector3(0.018, 0.66, 0.038), nil, brightMat)
            AddTrimBox(root, "swordEdgeR", Vector3(0.052, 0.58, 0), Vector3(0.018, 0.66, 0.038), nil, brightMat)
            AddDropModelPart(root, "swordTip", "Models/Cone.mdl", Vector3(0, 0.99, 0), Vector3(0.082, 0.18, 0.082), nil, steelMat, true)
            AddTrimBox(root, "swordFuller", Vector3(0, 0.58, -0.027), Vector3(0.020, 0.45, 0.012), nil, darkSteelMat)
            AddTrimBox(root, "swordGuard", Vector3(0, 0.20, 0), Vector3(0.50, 0.055, 0.085), nil, goldTrimMat)
            AddDropModelPart(root, "swordGuardCapL", "Models/Sphere.mdl", Vector3(-0.27, 0.20, 0), Vector3(0.07, 0.07, 0.07), nil, brightMat, true)
            AddDropModelPart(root, "swordGuardCapR", "Models/Sphere.mdl", Vector3(0.27, 0.20, 0), Vector3(0.07, 0.07, 0.07), nil, brightMat, true)
            AddSmallGem(root, "swordGuardGem", Vector3(0, 0.24, -0.05), Vector3(0.075, 0.075, 0.055), gemMat)
            AddDropModelPart(root, "swordGrip", "Models/Cylinder.mdl", Vector3(0, 0.03, 0), Vector3(0.052, 0.28, 0.052), nil, leatherMat, true)
            AddRing(root, "swordGripBandA", Vector3(0, 0.12, 0), Vector3(0.075, 0.075, 0.075), Quaternion(90, 0, 0), goldTrimMat)
            AddRing(root, "swordGripBandB", Vector3(0, -0.06, 0), Vector3(0.075, 0.075, 0.075), Quaternion(90, 0, 0), goldTrimMat)
            AddSmallGem(root, "swordPommel", Vector3(0, -0.16, 0), Vector3(0.085, 0.085, 0.085), brightMat)
        end
    elseif itemType == "helmet" then
        AddDropModelPart(root, "helmetShell", "Models/Sphere.mdl", Vector3(0, 0.43, 0), Vector3(0.42, 0.28, 0.40), nil, mainMat, true)
        AddTrimBox(root, "helmetOpenCut", Vector3(0, 0.28, -0.26), Vector3(0.42, 0.16, 0.07), nil, darkMat)
        AddRing(root, "helmetLowerRim", Vector3(0, 0.31, 0), Vector3(0.42, 0.28, 0.42), nil, goldTrimMat)
        AddTrimBox(root, "helmetBrowPlate", Vector3(0, 0.45, -0.29), Vector3(0.43, 0.08, 0.055), nil, goldTrimMat)
        AddTrimBox(root, "helmetNoseGuard", Vector3(0, 0.31, -0.33), Vector3(0.052, 0.25, 0.045), nil, darkSteelMat)
        AddTrimBox(root, "helmetCheekL", Vector3(-0.22, 0.27, -0.22), Vector3(0.10, 0.20, 0.065), Quaternion(0, 0, -8), mainMat)
        AddTrimBox(root, "helmetCheekR", Vector3(0.22, 0.27, -0.22), Vector3(0.10, 0.20, 0.065), Quaternion(0, 0, 8), mainMat)
        AddDropModelPart(root, "helmetTopSpike", "Models/Cone.mdl", Vector3(0, 0.74, 0), Vector3(0.12, 0.22, 0.12), nil, brightMat, true)
        AddTrimBox(root, "helmetCrestBase", Vector3(0, 0.66, 0.03), Vector3(0.10, 0.08, 0.44), nil, goldTrimMat)
        AddSmallGem(root, "helmetFrontGem", Vector3(0, 0.54, -0.31), Vector3(0.078, 0.078, 0.052), gemMat)
    elseif itemType == "armor" then
        AddTrimBox(root, "chestBackPlate", Vector3(0, 0.42, 0.04), Vector3(0.52, 0.62, 0.12), nil, darkMat)
        AddTrimBox(root, "chestFrontPlate", Vector3(0, 0.44, -0.05), Vector3(0.44, 0.56, 0.12), nil, mainMat)
        AddTrimBox(root, "chestCenterRidge", Vector3(0, 0.48, -0.13), Vector3(0.065, 0.52, 0.04), nil, brightMat)
        AddTrimBox(root, "chestTopTrim", Vector3(0, 0.74, -0.13), Vector3(0.50, 0.06, 0.045), nil, goldTrimMat)
        AddTrimBox(root, "chestBeltTrim", Vector3(0, 0.18, -0.13), Vector3(0.52, 0.07, 0.045), nil, goldTrimMat)
        AddDropModelPart(root, "leftShoulder", "Models/Sphere.mdl", Vector3(-0.36, 0.64, 0), Vector3(0.23, 0.14, 0.23), nil, brightMat, true)
        AddDropModelPart(root, "rightShoulder", "Models/Sphere.mdl", Vector3(0.36, 0.64, 0), Vector3(0.23, 0.14, 0.23), nil, brightMat, true)
        AddSmallGem(root, "armorHeartGem", Vector3(0, 0.53, -0.15), Vector3(0.09, 0.11, 0.055), gemMat)
        AddTrimBox(root, "leftLowerPlate", Vector3(-0.14, 0.04, -0.06), Vector3(0.18, 0.16, 0.10), Quaternion(0, 0, 6), darkMat)
        AddTrimBox(root, "rightLowerPlate", Vector3(0.14, 0.04, -0.06), Vector3(0.18, 0.16, 0.10), Quaternion(0, 0, -6), darkMat)
    elseif itemType == "necklace" then
        AddRing(root, "necklaceChain", Vector3(0, 0.50, 0), Vector3(0.44, 0.44, 0.44), Quaternion(90, 0, 0), steelMat)
        AddRing(root, "necklaceInnerGlow", Vector3(0, 0.50, 0), Vector3(0.28, 0.28, 0.28), Quaternion(90, 0, 0), brightMat)
        for i = 1, 5 do
            local a = math.pi * (0.18 + i * 0.13)
            AddSmallGem(root, "necklaceBead" .. i, Vector3(math.cos(a) * 0.26, 0.50 - math.sin(a) * 0.20, -0.03), Vector3(0.045, 0.045, 0.045), goldTrimMat)
        end
        AddSmallGem(root, "necklaceGem", Vector3(0, 0.17, -0.03), Vector3(0.18, 0.23, 0.12), gemMat)
        AddDropModelPart(root, "necklaceTip", "Models/Cone.mdl", Vector3(0, 0.01, -0.03), Vector3(0.11, 0.17, 0.11), Quaternion(180, 0, 0), brightMat, true)
    elseif itemType == "bracelet" then
        AddRing(root, "braceletOuter", Vector3(0, 0.31, 0), Vector3(0.42, 0.42, 0.42), nil, mainMat)
        AddRing(root, "braceletInner", Vector3(0, 0.31, 0), Vector3(0.30, 0.30, 0.30), nil, darkMat)
        for i = 1, 4 do
            local a = (i - 1) * math.pi * 0.5
            AddSmallGem(root, "braceletGem" .. i, Vector3(math.cos(a) * 0.34, 0.31, math.sin(a) * 0.34), Vector3(0.085, 0.085, 0.085), gemMat)
        end
        AddTrimBox(root, "braceletEngraveA", Vector3(0, 0.49, 0), Vector3(0.35, 0.025, 0.05), nil, goldTrimMat)
        AddTrimBox(root, "braceletEngraveB", Vector3(0, 0.13, 0), Vector3(0.35, 0.025, 0.05), nil, goldTrimMat)
    elseif itemType == "ring" then
        AddRing(root, "ringBand", Vector3(0, 0.30, 0), Vector3(0.30, 0.30, 0.30), Quaternion(90, 0, 0), mainMat)
        AddRing(root, "ringInnerTrim", Vector3(0, 0.30, 0), Vector3(0.22, 0.22, 0.22), Quaternion(90, 0, 0), goldTrimMat)
        AddSmallGem(root, "ringGem", Vector3(0, 0.53, -0.02), Vector3(0.15, 0.15, 0.15), gemMat)
        AddTrimBox(root, "ringGemProngL", Vector3(-0.09, 0.49, -0.02), Vector3(0.035, 0.10, 0.035), Quaternion(0, 0, -18), goldTrimMat)
        AddTrimBox(root, "ringGemProngR", Vector3(0.09, 0.49, -0.02), Vector3(0.035, 0.10, 0.035), Quaternion(0, 0, 18), goldTrimMat)
    elseif itemType == "belt" then
        AddRing(root, "beltBandOuter", Vector3(0, 0.30, 0), Vector3(0.52, 0.34, 0.52), nil, leatherMat)
        AddRing(root, "beltBandTrim", Vector3(0, 0.30, 0), Vector3(0.57, 0.38, 0.57), nil, goldTrimMat)
        AddTrimBox(root, "beltBuckleFrame", Vector3(0, 0.30, -0.36), Vector3(0.33, 0.22, 0.07), nil, goldTrimMat)
        AddTrimBox(root, "beltBuckleHole", Vector3(0, 0.30, -0.41), Vector3(0.20, 0.12, 0.045), nil, darkMat)
        AddSmallGem(root, "beltGem", Vector3(0, 0.30, -0.47), Vector3(0.075, 0.075, 0.06), gemMat)
        AddSmallGem(root, "beltStudL", Vector3(-0.32, 0.30, -0.18), Vector3(0.055, 0.055, 0.055), brightMat)
        AddSmallGem(root, "beltStudR", Vector3(0.32, 0.30, -0.18), Vector3(0.055, 0.055, 0.055), brightMat)
    elseif itemType == "boots" then
        AddTrimBox(root, "leftBootLeg", Vector3(-0.17, 0.36, 0), Vector3(0.18, 0.42, 0.16), Quaternion(0, 0, -3), mainMat)
        AddTrimBox(root, "rightBootLeg", Vector3(0.17, 0.36, 0), Vector3(0.18, 0.42, 0.16), Quaternion(0, 0, 3), mainMat)
        AddTrimBox(root, "leftBootFoot", Vector3(-0.17, 0.12, -0.13), Vector3(0.20, 0.13, 0.38), nil, darkMat)
        AddTrimBox(root, "rightBootFoot", Vector3(0.17, 0.12, -0.13), Vector3(0.20, 0.13, 0.38), nil, darkMat)
        AddTrimBox(root, "leftBootCuff", Vector3(-0.17, 0.59, 0), Vector3(0.23, 0.07, 0.20), nil, goldTrimMat)
        AddTrimBox(root, "rightBootCuff", Vector3(0.17, 0.59, 0), Vector3(0.23, 0.07, 0.20), nil, goldTrimMat)
        AddTrimBox(root, "leftToeCap", Vector3(-0.17, 0.13, -0.35), Vector3(0.18, 0.10, 0.08), nil, steelMat)
        AddTrimBox(root, "rightToeCap", Vector3(0.17, 0.13, -0.35), Vector3(0.18, 0.10, 0.08), nil, steelMat)
        AddSmallGem(root, "leftBootGem", Vector3(-0.17, 0.39, -0.11), Vector3(0.055, 0.055, 0.045), gemMat)
        AddSmallGem(root, "rightBootGem", Vector3(0.17, 0.39, -0.11), Vector3(0.055, 0.055, 0.045), gemMat)
    else
        AddDropModelPart(root, "unknownItem", "Models/Sphere.mdl", Vector3(0, 0.30, 0), Vector3(0.36, 0.36, 0.36), nil, mainMat, true)
        AddRing(root, "unknownHalo", Vector3(0, 0.30, 0), Vector3(0.46, 0.46, 0.46), Quaternion(90, 0, 0), brightMat)
    end
end

--- 更新装备掉落期间的闪烁状态。
---
--- 地面装备由多个子节点（模型、光环、Text3D）组成，不能只切换根节点的
--- enabled 属性，否则子节点仍可能继续渲染；SetDeepEnabled 会递归覆盖整棵
--- 掉落物树。装备一旦落地且延迟结束，立即恢复完整可见状态并停止闪烁。
local function UpdateGroundItemBlink(groundItem, dt, canPickup)
    if not groundItem or not groundItem.node then return end

    if canPickup then
        -- 延迟结束后不再闪烁，即使玩家暂时不在拾取距离内也保持常亮。
        if groundItem.blinkActive ~= false or groundItem.blinkVisible ~= true then
            groundItem.blinkActive = false
            groundItem.blinkTimer = 0
            groundItem.blinkVisible = true
            groundItem.node:SetDeepEnabled(true)
        end
        return
    end

    groundItem.blinkActive = true
    groundItem.blinkTimer = (groundItem.blinkTimer or 0) + math.max(0, tonumber(dt) or 0)

    -- 用步数处理大帧间隔，避免低帧时闪烁状态失真；只有奇数次翻转才需要
    -- 调用引擎 API，减少每帧跨 Lua/C++ 的开销。
    local toggleCount = math.floor(groundItem.blinkTimer / ITEM_BLINK_INTERVAL)
    if toggleCount <= 0 then return end
    groundItem.blinkTimer = groundItem.blinkTimer - toggleCount * ITEM_BLINK_INTERVAL
    if toggleCount % 2 == 1 then
        groundItem.blinkVisible = not groundItem.blinkVisible
        groundItem.node:SetDeepEnabled(groundItem.blinkVisible)
    end
end

local function ReserveGroundEquipmentSlot()
    while true do
        local equipmentCount = 0
        local oldestEquipmentIndex = nil
        for i, groundItem in ipairs(groundItems) do
            if groundItem.type == "item" then
                equipmentCount = equipmentCount + 1
                if not oldestEquipmentIndex then
                    oldestEquipmentIndex = i
                end
            end
        end

        if equipmentCount < MAX_GROUND_EQUIPMENT or not oldestEquipmentIndex then
            return
        end

        local oldest = groundItems[oldestEquipmentIndex]
        if not oldest then return end
        ---@type Node|nil
        local oldestNode = oldest.node
        if oldestNode then oldestNode:Remove() end
        table.remove(groundItems, oldestEquipmentIndex)
    end
end

--- 生成装备掉落到地面
function Combat.SpawnGroundItem(scene, pos, item)
    ReserveGroundEquipmentSlot()

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
    itemNode.rotation = Quaternion(0, math.random() * 360, 0)
    CreateGroundEquipmentModel(itemNode, item, c)
    CreateGroundItemNameAndGlow(itemNode, item, rarity, c)

    table.insert(groundItems, {
        node = itemNode,
        type = "item",
        item = item,
        timer = 0,
        lifetime = ITEM_LIFETIME,
        targetY = 0.25,
        fallSpeed = 2.5 + math.random() * 1.5,
        falling = true,
        pickupDelayTimer = 0,
        pickupRetryTimer = 0,
        -- 掉落动画和不可拾取延迟阶段均闪烁；初始帧保持可见，避免装备
        -- 生成时恰好处于隐藏相位而让玩家错过落点。
        blinkTimer = 0,
        blinkVisible = true,
        blinkActive = true,
        rotSpeed = 60 + math.random() * 40,
    })
end

--- 更新地面物品（金币磁吸 + 装备靠近拾取）
function Combat.UpdateGroundItems(dt, playerNode)
    if not playerNode then return end
    local playerPos = playerNode.position

    for i = #groundItems, 1, -1 do
        -- 与敌人更新循环相同：让 continue 标签位于本轮局部变量作用域外，
        -- 避免 Lua 5.4 将前向 goto 判定为跳入 local 作用域。
        do
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
            -- 金币：落地后等待 2 秒，再自动磁吸向玩家
            if not g.falling and not g.magnetPhase then
                g.pickupDelayTimer = (g.pickupDelayTimer or 0) + dt
                if g.pickupDelayTimer >= GOLD_MAGNET_DELAY then
                    g.magnetPhase = true
                end
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

            -- 装备刚掉落的前 1 秒不可拾取，之后必须踩到装备上才触发
            g.pickupDelayTimer = math.min(ITEM_PICKUP_DELAY, (g.pickupDelayTimer or 0) + dt)
            g.pickupRetryTimer = math.max(0, (g.pickupRetryTimer or 0) - dt)
            local canPickup = not g.falling and g.pickupDelayTimer >= ITEM_PICKUP_DELAY
            UpdateGroundItemBlink(g, dt, canPickup)
            if canPickup
                and g.pickupRetryTimer <= 0 and dist < ITEM_PICKUP_DIST then
                -- 回调返回 false 时（例如背包已满）必须保留地面物品；此前
                -- 无论回调结果都 Remove，导致玩家看到“背包已满”却永久丢装。
                local pickedUp = true
                if Combat.onItemPickup then
                    pickedUp = Combat.onItemPickup(g.item, pos) ~= false
                end
                if pickedUp then
                    g.node:Remove()
                    table.remove(groundItems, i)
                    goto continue_ground
                end
                -- 仍站在物品上时不要每帧重复 Toast/飘字；清出背包后会自动再试。
                g.pickupRetryTimer = 0.6
            end
        end

        end
        ::continue_ground::
    end
end

-- ============================================================================
-- 工具函数
-- ============================================================================
---@param pos Vector3
---@param maxRange number|nil
---@return table|nil, number
function Combat.FindNearestEnemy(pos, maxRange)
    local nearest = nil
    local nearDist = maxRange or 999
    for _, e in ipairs(enemies) do
        if IsEnemyTargetable(e) then
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
            if e and e.node and e.state ~= "dead" and e.state ~= "dying" then
                local ey = e.node.position.y
                if e.tier ~= "boss" then
                    local ejectPos = Vector3(
                        pPos.x + dir.x * DASH_EJECT_DIST + lateral.x,
                        ey,
                        pPos.z + dir.z * DASH_EJECT_DIST + lateral.z)
                    e.node.position = MoveOutsideSafeZone(ejectPos, currentMapId, 0.85) or ejectPos
                end
                local eBody = e.node:GetComponent("RigidBody")
                if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
                e.knockbackTimer = 0          -- 清除残留击退，确保硬直立即生效
                e.hitStunTimer = e.tier == "boss" and 0.08 or DASH_STUN
                -- 被顶出后回头面向玩家
                FaceEnemyDir(e, -dir)
                if e.state == "patrol" or e.state == "guard" or e.state == "return" then
                    e.state = "chase"
                    e.patrolTarget = nil
                end
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

    -- 位移技能不能作为安全区攻击绕过路径。即将踏入安全区时在边界外
    -- 结束冲刺，并结算已卷入目标；普通行走仍可自由进入安全区。
    if IsInSafeZone(newPos) then
        Combat.EndDash(playerNode)
        return
    end

    -- 卷入"将要到达位置"前方的怪物（每帧检测，途中遇到的新怪也会被顶）
    for _, e in ipairs(enemies) do
        if IsEnemyTargetable(e) and not dashState.pushed[e] then
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
        if e and e.node and e.state ~= "dead" and e.state ~= "dying" then
            if e.tier ~= "boss" then
                local ey = e.node.position.y
                local pushedPos = Vector3(
                    newPos.x + dir.x * DASH_CONTACT + lateral.x,
                    ey,
                    newPos.z + dir.z * DASH_CONTACT + lateral.z)
                e.node.position = MoveOutsideSafeZone(pushedPos, currentMapId, 0.85) or pushedPos
            end
            local eBody = e.node:GetComponent("RigidBody")
            if eBody then eBody:SetLinearVelocity(Vector3.ZERO) end
            -- 顶推期间保持轻硬直，压制怪物自身 AI 移动（次帧 UpdateEnemies 生效）
            local dashStun = e.tier == "boss" and 0.08 or 0.15
            if e.hitStunTimer < dashStun then e.hitStunTimer = dashStun end
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
    DivineBeast.Update(dt, scene, playerNode, player, enemies, Combat.DealDamage, IsInSafeZone)
end

--- 清空所有战斗实体
-- 设置当前地图（供按图刷怪）
function Combat.SetMap(mapId)
    if not MapZone.GetDef(mapId) then return false end
    local changed = currentMapId ~= mapId
    currentMapId = mapId
    Combat.currentMapId = currentMapId
    MapZone.SetCurrentMap(mapId)
    if changed then
        -- 切图会清空旧地图实体；遭遇请求回到目标地图后再由统一入口恢复。
        encounterRetryTimer = 0
        activeEncounterId = nil
        playerWasInSafeZone = false
        -- SetMap 也可能被独立调用（不一定总是先经过 Combat.Clear），
        -- 因此在地图边界再次清理主线特效，避免旧区域轮廓跨图残留。
        ClearQuestEffects()
    end
    return true
end

--- 设置累计击杀数（读档/创建新角色时使用）。
---@param value number
function Combat.SetKillCount(value)
    killCount = SafeInteger(value, 0, 0, MAX_COMBAT_VALUE)
    Combat.killCount = killCount
end

---@return number
function Combat.GetKillCount()
    return killCount
end

--- 清空战斗实体。
--- 默认保留跨地图累计击杀数和道士的永久神兽；返回主菜单等真正结束
--- 当前角色会话时，再显式传 clearPersistentSummon=true。
---@param resetKillCount boolean|nil
---@param clearPersistentSummon boolean|nil
function Combat.Clear(resetKillCount, clearPersistentSummon)
    RemoveBossAttackVisuals(combatScene)
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
    ClearQuestEffects()
    enemies = {}
    projectiles = {}
    summons = {}
    aoeZones = {}
    groundItems = {}
    Combat.enemies = enemies
    Combat.projectiles = projectiles
    if resetKillCount then
        Combat.SetKillCount(0)
    else
        -- 兼容旧代码直接写 Combat.killCount 的情况。
        killCount = SafeInteger(Combat.killCount, killCount or 0, 0, MAX_COMBAT_VALUE)
        Combat.killCount = killCount
    end
    spawnTimer = 0
    encounterRetryTimer = 0
    activeEncounterId = nil
    lastPlayerTarget = nil
    playerWasInSafeZone = false
    combatScene = nil
    Combat.CancelDash()
    if clearPersistentSummon then
        DivineBeast.Clear()
    end
end

-- 回调（由 main.lua 设置）
Combat.onDamageDealt = nil   -- function(dmg, isCrit, worldPos)
Combat.onEnemyAttack = nil   -- function(enemy, dmg, playerPos)
Combat.onPlayerHeal = nil    -- function(amount, playerPos)
Combat.onEnemyDeath = nil    -- function(enemyName, deathPos, exp, deathDuration, tier, mapId, encounterId)
Combat.onSkillUnlocked = nil -- function(skillName)
Combat.onGoldPickup = nil    -- function(amount, worldPos)
Combat.onItemPickup = nil    -- function(item, worldPos) -> boolean|nil（false 时保留地面物品）

return Combat
