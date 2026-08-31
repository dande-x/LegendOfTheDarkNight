-- ============================================================================
-- ShabakData.lua — 沙巴克城攻城战的纯数据契约
--
-- 这个模块只保存规则和可测试的数值，不创建 Node、UI 或战斗实体。
-- ShabakSiege/main.lua 可以直接读取它来创建一次性攻城实例；离线回归
-- 测试也可以在没有 UrhoX 运行时的情况下验证入口、波次、等级和补给。
-- ============================================================================

local ShabakData = {}

ShabakData.MAP_ID = "map_sb"
ShabakData.NAME = "沙巴克城"
ShabakData.MIN_LEVEL = 50

-- 进入后每次都是一场新的攻城实例，不保存中途进度。
ShabakData.INSTANCE = {
    totalDuration = 15 * 60,
    deploymentDuration = 10,
    throneHoldDuration = 60,
    retryStartsFresh = true,
    saveProgress = false,
}

-- 俯视角地图使用与其它地图相同的 120m 场地；出生点放在城外南侧，
-- 目标点按南门→街旗→内城旗→皇宫→王座的推进顺序排列。
ShabakData.SPAWN_POSITION = { x = 0, y = 0, z = -50 }
ShabakData.SAFE_ZONE_RADIUS = 6

-- 攻城目标的固定耐久。等级浮动已经由守军承担，目标本身不再随等级
-- 额外膨胀，确保高等级角色的成长能缩短攻城时间而不是抵消成长收益。
ShabakData.OBJECTIVE_HEALTH = {
    southGate = 4200,
    palaceSeal = 3200,
}

ShabakData.LANDMARKS = {
    { id = "south_gate", name = "南门", x = 0, z = -38, phase = "south_gate" },
    { id = "east_flag", name = "东街战旗", x = 25, z = -17, phase = "street_flags" },
    { id = "west_flag", name = "西街战旗", x = -25, z = -17, phase = "street_flags" },
    { id = "inner_flag", name = "内城战旗", x = 0, z = 4, phase = "inner_flag" },
    { id = "palace_seal", name = "皇宫封印", x = 0, z = 28, phase = "palace_seal" },
    { id = "throne", name = "城主王座", x = 0, z = 38, phase = "throne" },
}

-- 每个阶段的守军预算是本场最多生成的敌方角色数量（不是同时在线数）。
-- 合计 26 名，普通阶段活跃上限 7 名，王座阶段上限 8 名，避免小屏
-- 战斗变成纯粹的堆怪；同一阶段可按 activeCap 分批补入。
ShabakData.PHASES = {
    {
        id = "south_gate",
        name = "南门突破",
        order = 1,
        objective = "breach",
        landmarkId = "south_gate",
        guardBudget = 6,
        activeCap = 7,
        spawnInterval = 4.5,
        captureDuration = 8,
    },
    {
        id = "street_flags",
        name = "东西街夺旗",
        order = 2,
        objective = "capture_both_flags",
        landmarkId = "east_flag",
        alternateLandmarkId = "west_flag",
        guardBudget = 6,
        activeCap = 7,
        spawnInterval = 5.0,
        captureDuration = 10,
    },
    {
        id = "inner_flag",
        name = "内城夺旗",
        order = 3,
        objective = "capture",
        landmarkId = "inner_flag",
        guardBudget = 4,
        activeCap = 7,
        spawnInterval = 5.5,
        captureDuration = 10,
    },
    {
        id = "palace_seal",
        name = "皇宫封印",
        order = 4,
        objective = "break_seal",
        landmarkId = "palace_seal",
        guardBudget = 4,
        activeCap = 7,
        spawnInterval = 5.5,
        -- 封印是可破坏耐久目标，不使用站桩读条。
        captureDuration = 0,
    },
    {
        id = "throne",
        name = "王座坚守",
        order = 5,
        objective = "hold",
        landmarkId = "throne",
        guardBudget = 6,
        activeCap = 8,
        spawnInterval = 4.0,
        holdDuration = 60,
    },
}

ShabakData.TOTAL_GUARD_BUDGET = 26
ShabakData.NORMAL_ACTIVE_CAP = 7
ShabakData.THRONE_ACTIVE_CAP = 8

-- 敌人不是 MonsterSkeleton 怪，而是与玩家相同的三职业角色。每次生成
-- 从这里选择职业；职业比例略偏武士，给玩家留下可读的前排/远程/治疗
-- 优先级。守军不会召唤神兽，也不会携带强化装备。
ShabakData.GUARD_CLASSES = { "warrior", "mage", "taoist" }
ShabakData.GUARD_ROLE_NAMES = {
    warrior = "守城武士",
    mage = "守城法师",
    taoist = "守城道士",
}
ShabakData.GUARD_PHASE_MIX = {
    south_gate = { warrior = 3, mage = 2, taoist = 1 },
    street_flags = { warrior = 3, mage = 2, taoist = 1 },
    inner_flag = { warrior = 2, mage = 1, taoist = 1 },
    palace_seal = { warrior = 1, mage = 2, taoist = 1 },
    throne = { warrior = 3, mage = 2, taoist = 1 },
}

-- 以玩家等级为中心的小范围浮动；Lv.50 是地板而不是上限，主角继续
-- 升级时守军也会同步变强。不同索引轮换偏移，确保同一波不是同级复制。
ShabakData.GUARD_LEVEL_OFFSETS = { -1, 0, 1 }
ShabakData.GUARD_LEVEL_MIN = 50
ShabakData.GUARD_LEVEL_MAX_OFFSET = 1

-- 敌方角色装备只使用普通/稀有模板，且永远未强化；守军装备不会掉落。
ShabakData.GUARD_EQUIPMENT_RARITIES = { "COMMON", "RARE" }
ShabakData.GUARD_EQUIPMENT_ENHANCE_LEVEL = 0
ShabakData.GUARD_DROPS_LOOT = false

-- 玩家 + 两名弱支援队友。队友补齐另外两个职业，不参与夺旗读条或王座
-- 占领；他们只在玩家附近提供有限的伤害、拉仇恨和治疗。
ShabakData.SUPPORT_COUNT = 2
ShabakData.SUPPORT_LEVEL_OFFSET = -2
ShabakData.SUPPORT_DAMAGE_SHARE = {
    warrior = 0.45,
    mage = 0.35,
    taoist = 0.30,
}
ShabakData.SUPPORT_BEHAVIOR = {
    warrior = {
        role = "tank",
        damageMultiplier = 0.45,
        leashRange = 8,
        cannotCapture = true,
    },
    mage = {
        role = "ranged_support",
        damageMultiplier = 0.35,
        attackInterval = 2.8,
        cannotCapture = true,
    },
    taoist = {
        role = "healer",
        damageMultiplier = 0.30,
        healThreshold = 0.45,
        healCooldown = 15,
        maxHealsPerSiege = 5,
        healPercent = 0.06,
        cannotCapture = true,
    },
}
ShabakData.SUPPORT_REVIVE = {
    enabledBetweenPhases = true,
    returnHealthPercent = 0.50,
    enabledDuringThrone = false,
}

-- 药瓶必须足够支撑 15 分钟战斗，但不把补给做成无限续航。
ShabakData.POTIONS = {
    hp = {
        maxCount = 10,
        recommendedMin = 8,
        warnBelow = 6,
        healPercent = 0.30,
        cooldown = 6.0,
    },
    mp = {
        maxCount = 8,
        recommendedMin = 4,
        recommendedMax = 6,
        healPercent = 0.40,
        cooldown = 4.5,
    },
}
ShabakData.CHECKPOINT_SUPPLY = {
    healPercent = 0.12,
    emergencyPotionCount = 1,
    temporary = true,
    persistsToSave = false,
    stages = { "south_gate", "inner_flag", "palace_seal" },
}
ShabakData.THRONE_HAS_SUPPLY = false

ShabakData.REWARD = {
    title = "沙巴克城主",
    titleKey = "shabak_lord",
    firstWinPermanent = true,
    persistPerCharacterSlot = true,
    bestTimeField = "shabakBestTime",
    winCountField = "shabakWinCount",
}

ShabakData.FAILURE_REASONS = {
    player_dead = "角色死亡",
    player_exit = "主动退出攻城",
    timeout = "攻城超时",
}

local function FiniteNumber(value, fallback)
    local number = tonumber(value)
    if type(number) ~= "number" or number ~= number
        or number == math.huge or number == -math.huge then
        return fallback
    end
    return number
end

--- 将等级规范化为可用于攻城缩放的正整数。
---@param level number|nil
---@return number
function ShabakData.NormalizeLevel(level)
    return math.max(1, math.floor(FiniteNumber(level, 1)))
end

--- 守军等级以玩家等级为中心上下浮动，但绝不会低于 Lv.50。
---@param playerLevel number|nil
---@param variantIndex number|nil 轮换偏移索引（1..3）
---@return number
function ShabakData.GetGuardLevel(playerLevel, variantIndex)
    local level = ShabakData.NormalizeLevel(playerLevel)
    local index = math.floor(FiniteNumber(variantIndex, 1))
    index = math.max(1, math.min(#ShabakData.GUARD_LEVEL_OFFSETS, index))
    return math.max(ShabakData.GUARD_LEVEL_MIN,
        level + ShabakData.GUARD_LEVEL_OFFSETS[index])
end

--- 队友等级保持略低于玩家，但在沙巴克不会低于 Lv.50。
---@param playerLevel number|nil
---@return number
function ShabakData.GetSupportLevel(playerLevel)
    local level = ShabakData.NormalizeLevel(playerLevel)
    return math.max(ShabakData.GUARD_LEVEL_MIN,
        level + ShabakData.SUPPORT_LEVEL_OFFSET)
end

--- 返回玩家职业之外的两个支援职业，顺序稳定，便于 UI 和行为测试。
---@param playerClassId string
---@return string[]
function ShabakData.GetSupportClasses(playerClassId)
    local result = {}
    for _, classId in ipairs(ShabakData.GUARD_CLASSES) do
        if classId ~= playerClassId then
            table.insert(result, classId)
        end
    end
    return result
end

---@param phaseId string
---@return table|nil
function ShabakData.GetPhase(phaseId)
    for _, phase in ipairs(ShabakData.PHASES) do
        if phase.id == phaseId then return phase end
    end
    return nil
end

---@param phaseId string
---@return table
function ShabakData.GetGuardMix(phaseId)
    local source = ShabakData.GUARD_PHASE_MIX[phaseId] or {}
    return {
        warrior = math.max(0, math.floor(FiniteNumber(source.warrior, 0))),
        mage = math.max(0, math.floor(FiniteNumber(source.mage, 0))),
        taoist = math.max(0, math.floor(FiniteNumber(source.taoist, 0))),
    }
end

---@return number
function ShabakData.GetTotalGuardBudget()
    local total = 0
    for _, phase in ipairs(ShabakData.PHASES) do
        total = total + math.max(0, math.floor(FiniteNumber(phase.guardBudget, 0)))
    end
    return total
end

---@param rarity string|nil
---@param enhanceLevel number|nil
---@return boolean
function ShabakData.IsAllowedGuardEquipment(rarity, enhanceLevel)
    local normalized = type(rarity) == "string" and string.upper(rarity) or ""
    local rarityAllowed = normalized == "COMMON" or normalized == "RARE"
    return rarityAllowed and math.floor(FiniteNumber(enhanceLevel, 0)) == 0
end

--- 根据当前药瓶数给出入场提示，不阻止玩家挑战。
---@param hpCount number|nil
---@param mpCount number|nil
---@return table {risk:string,hp:number,mp:number,message:string}
function ShabakData.GetSupplyAssessment(hpCount, mpCount)
    local hp = math.max(0, math.floor(FiniteNumber(hpCount, 0)))
    local mp = math.max(0, math.floor(FiniteNumber(mpCount, 0)))
    local risk = "recommended"
    local message = "补给充足，可进入攻城"
    if hp < ShabakData.POTIONS.hp.warnBelow then
        risk = "high"
        message = "血瓶少于 6 瓶，攻城风险较高"
    elseif hp < ShabakData.POTIONS.hp.recommendedMin
        or mp < ShabakData.POTIONS.mp.recommendedMin then
        risk = "caution"
        message = "建议在安全区补充药水"
    end
    return { risk = risk, hp = hp, mp = mp, message = message }
end

return ShabakData
