-- ============================================================================
-- Balance.lua — 等级、伤害与怪物成长的单一数值源
--
-- 目标：
--   1. 玩家、怪物和神兽统一使用递减收益防御公式，杜绝高防御后长期只掉 1 点血。
--   2. 怪物属性由实际等级、攻击间隔、物种定位和品阶共同派生。
--   3. 主线五张地图在 Lv10 / 25 / 35 / 45 / 50 附近形成稳定检查点。
--
-- 本模块不依赖引擎对象，可由离线数值检查直接加载。
-- ============================================================================

local Balance = {}

Balance.MAX_LEVEL = 50
Balance.DEFENSE_CONSTANT = 100
Balance.REFERENCE_ATTACK_INTERVAL = 1.7

local MAX_VALUE = 1000000000

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function SafeNumber(value, fallback)
    local number = tonumber(value)
    if not IsFiniteNumber(number) then return fallback or 0 end
    return number
end

local function Clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, value))
end

function Balance.NormalizeLevel(level)
    return math.floor(Clamp(SafeNumber(level, 1), 1, Balance.MAX_LEVEL))
end

-- 玩家升级曲线。总经验约 11.5 万；配合主线奖励后，各章节结束等级约为
-- 10 / 25 / 35 / 45 / 50，避免中期任务把角色直接灌到满级。
function Balance.GetExpToNext(level)
    level = Balance.NormalizeLevel(level)
    return math.floor(75 + 38 * level + 1.6 * level * level)
end

--- 统一防御结算。
--- @param rawDamage number
--- @param defense number|nil
--- @param opts table|nil {armorPen=0~1, defenseReduction=number, ignoreDefense=boolean, damageMultiplier=number}
--- @return number
function Balance.CalculateDamage(rawDamage, defense, opts)
    local raw = SafeNumber(rawDamage, 0)
    if raw <= 0 then return 0 end
    raw = math.min(raw, MAX_VALUE)

    local effectiveDefense = math.max(0, SafeNumber(defense, 0))
    if opts and opts.defenseReduction then
        effectiveDefense = math.max(0,
            effectiveDefense - math.max(0, SafeNumber(opts.defenseReduction, 0)))
    end
    if opts and opts.ignoreDefense then
        effectiveDefense = 0
    else
        local armorPen = Clamp(SafeNumber(opts and opts.armorPen, 0), 0, 1)
        effectiveDefense = effectiveDefense * (1 - armorPen)
    end

    local multiplier = math.max(0, SafeNumber(opts and opts.damageMultiplier, 1))
    local damage = raw * (Balance.DEFENSE_CONSTANT
        / (Balance.DEFENSE_CONSTANT + effectiveDefense)) * multiplier
    if not IsFiniteNumber(damage) or damage <= 0 then return 0 end
    return math.max(1, math.min(MAX_VALUE, math.floor(damage + 0.5)))
end

-- 怪物基础曲线。ATK 表示在 1.7 秒标准攻击间隔下的单次伤害；生成时会按
-- 实际 attackCD 反算，因此快攻怪单次较轻、慢攻怪单次更重，持续威胁连续。
local MONSTER_CURVES = {
    hp = function(level)
        return 90 + 24 * level + 0.68 * level * level
    end,
    atk = function(level)
        return 12 + 2.8 * level + 0.04 * level * level
    end,
    def = function(level)
        return 2 + 1.35 * level + 0.015 * level * level
    end,
    exp = function(level)
        return 12 + 3 * level + 0.04 * level * level
    end,
}

Balance.TIER_MULTIPLIERS = {
    normal = { hp = 1.0,  atk = 1.0,  def = 1.0,  exp = 1.0 },
    elite  = { hp = 2.25, atk = 1.35, def = 1.15, exp = 1.6 },
    boss   = { hp = 7.5,  atk = 2.2,  def = 1.25, exp = 4.0 },
}

-- 物种只负责“手感轮廓”，等级曲线仍是强度主体。
Balance.MONSTER_PROFILES = {
    deer          = { hp = 0.90, atk = 0.90, def = 0.90, exp = 1.0 },
    toad          = { hp = 0.92, atk = 0.92, def = 0.95, exp = 1.0 },
    cat           = { hp = 0.88, atk = 1.06, def = 0.86, exp = 1.0 },
    wolf          = { hp = 0.88, atk = 1.08, def = 0.85, exp = 1.0 },
    spider        = { hp = 0.84, atk = 1.10, def = 0.82, exp = 1.0 },
    serpent       = { hp = 0.88, atk = 1.08, def = 0.85, exp = 1.0 },
    antqueen      = { hp = 0.95, atk = 1.10, def = 0.90, exp = 1.0 },
    boar          = { hp = 1.08, atk = 1.05, def = 1.00, exp = 1.0 },
    orc           = { hp = 1.08, atk = 1.05, def = 1.00, exp = 1.0 },
    golem         = { hp = 1.18, atk = 0.95, def = 1.25, exp = 1.0 },
    qilin         = { hp = 1.00, atk = 1.08, def = 1.05, exp = 1.0 },
}

local DEFAULT_PROFILE = { hp = 1.0, atk = 1.0, def = 1.0, exp = 1.0 }

--- 返回指定等级怪物的基础曲线，供离线验收与 UI 说明使用。
function Balance.GetMonsterCurve(level)
    level = Balance.NormalizeLevel(level)
    return {
        hp = MONSTER_CURVES.hp(level),
        atk = MONSTER_CURVES.atk(level),
        def = MONSTER_CURVES.def(level),
        exp = MONSTER_CURVES.exp(level),
    }
end

--- 根据怪物定义生成最终战斗属性。旧定义中的绝对 hp/atk/def/exp 不再参与
--- 结算；如需个体微调，使用 hpScale/atkScale/defScale/expScale。
---@param definition table
---@param actualLevel number
---@return table {hp:number,atk:number,def:number,exp:number}
function Balance.GetMonsterStats(definition, actualLevel)
    definition = type(definition) == "table" and definition or {}
    local level = Balance.NormalizeLevel(actualLevel or definition.level)
    local tier = Balance.TIER_MULTIPLIERS[definition.tier] or Balance.TIER_MULTIPLIERS.normal
    local profile = Balance.MONSTER_PROFILES[definition.monsterType] or DEFAULT_PROFILE

    local attackInterval = Clamp(
        SafeNumber(definition.attackCD, Balance.REFERENCE_ATTACK_INTERVAL), 0.65, 3.2)
    local timingScale = Clamp(
        attackInterval / Balance.REFERENCE_ATTACK_INTERVAL, 0.60, 1.80)

    local hpScale = math.max(0.1, SafeNumber(definition.hpScale, 1))
    local atkScale = math.max(0.1, SafeNumber(definition.atkScale, 1))
    local defScale = math.max(0.1, SafeNumber(definition.defScale, 1))
    local expScale = math.max(0.1, SafeNumber(definition.expScale, 1))

    return {
        hp = math.max(1, math.floor(MONSTER_CURVES.hp(level)
            * (profile.hp or 1) * tier.hp * hpScale + 0.5)),
        atk = math.max(1, math.floor(MONSTER_CURVES.atk(level)
            * timingScale * (profile.atk or 1) * tier.atk * atkScale + 0.5)),
        def = math.max(0, math.floor(MONSTER_CURVES.def(level)
            * (profile.def or 1) * tier.def * defScale + 0.5)),
        exp = math.max(1, math.floor(MONSTER_CURVES.exp(level)
            * (profile.exp or 1) * tier.exp * expScale + 0.5)),
    }
end

--- 低等级普通怪的经验随等级差衰减，避免回旧地图刷满级；精英/Boss 和
--- 同级目标保持完整奖励，越级挑战则有轻微加成。
function Balance.GetExperienceGain(baseExp, monsterLevel, playerLevel, tier)
    local amount = math.max(0, SafeNumber(baseExp, 0))
    if amount <= 0 then return 0 end

    local monster = Balance.NormalizeLevel(monsterLevel)
    local player = Balance.NormalizeLevel(playerLevel)
    local difference = player - monster
    local multiplier = 1.0

    if tier == "normal" then
        if difference >= 13 then
            multiplier = 0.10
        elseif difference >= 8 then
            multiplier = 0.30
        elseif difference >= 5 then
            multiplier = 0.60
        elseif monster - player >= 5 then
            multiplier = 1.10
        end
    end

    return math.max(1, math.floor(amount * multiplier + 0.5))
end

-- 神兽随主人当前面板同步，等级只提供额外成长；因此升级、换装后不会继续
-- 使用召唤瞬间的旧攻击力，也不会靠一次高攻装备“快照”永久获利。
function Balance.GetDivineBeastStats(player, beastLevel, summonDamagePercent, passiveMultiplier)
    player = type(player) == "table" and player or {}
    local level = math.floor(Clamp(SafeNumber(beastLevel, 1), 1, 7))
    local ownerHP = math.max(1, SafeNumber(player.maxHP, 1))
    local ownerATK = math.max(0, SafeNumber(player.atk, 0))
    local ownerDEF = math.max(0, SafeNumber(player.def, 0))
    local skillMultiplier = math.max(0, SafeNumber(summonDamagePercent, 150) / 100)
    local passive = math.max(0, SafeNumber(passiveMultiplier, 1))

    return {
        maxHP = math.max(1, math.floor(240 + ownerHP * 0.40 + (level - 1) * 65 + 0.5)),
        atk = math.max(1, math.floor(ownerATK * skillMultiplier * passive
            + (level - 1) * 8 + 0.5)),
        def = math.max(0, math.floor(8 + ownerDEF * 0.55 + (level - 1) * 2.5 + 0.5)),
    }
end

Balance.PROGRESSION_CHECKPOINTS = {
    { questId = "q_006", expectedLevel = 10 },
    { questId = "q_009", expectedLevel = 25 },
    { questId = "q_012b", expectedLevel = 35 },
    { questId = "q_014b", expectedLevel = 45 },
    { questId = "q_016", expectedLevel = 50 },
}

return Balance
