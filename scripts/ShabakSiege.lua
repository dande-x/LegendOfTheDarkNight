---@diagnostic disable: undefined-field, undefined-global
-- ============================================================================
-- ShabakSiege.lua — 沙巴克城单人攻城战纯逻辑会话
--
-- 这个模块只维护攻城规则、阶段、队伍编制、守军计划和结算数据，不直接
-- 创建 Node/模型，也不把临时守军塞进 Combat.enemies。main.lua、Combat.lua
-- 和 GameUI.lua 可以把这里返回的 actor descriptor 交给各自的运行时适配层。
--
-- 设计边界：
--   * map_sb 是主线完成后的重复挑战地图，每次进入都是新的会话。
--   * 玩家 + 两名弱支援队友；玩家必须亲自完成所有攻城目标。
--   * 守军总预算 26 名，按阶段/波次激活，全部是三职业实际角色。
--   * 临时装备只允许 COMMON/RARE，且 enhance 永远为 0。
--   * 会话不提供中途存档；胜利后由宿主把 GetHonorPatch() 合并进角色槽位。
-- ============================================================================

local ShabakSiege = {}

-- ShabakData 是静态规则的单一数据源（由主线程接入时可能先于本模块落地）。
-- 这里采用可选加载：独立单元测试或旧版本资源树缺少该文件时，仍使用本
-- 模块内的安全回退值；一旦存在则优先读取其预算、时长和补给配置。
local StaticData = nil
do
    local ok, loaded = pcall(require, "ShabakData")
    if not ok then ok, loaded = pcall(require, "scripts.ShabakData") end
    if ok and type(loaded) == "table" then StaticData = loaded end
end

local Session = {}
Session.__index = Session

local MAX_SAFE_NUMBER = 1000000000

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function SafeNumber(value, fallback)
    local number = tonumber(value)
    if not IsFiniteNumber(number) then return fallback or 0 end
    return math.max(-MAX_SAFE_NUMBER, math.min(MAX_SAFE_NUMBER, number))
end

local function SafeInteger(value, fallback, minValue, maxValue)
    local number = tonumber(value)
    if not IsFiniteNumber(number) then return fallback end
    minValue = minValue or -MAX_SAFE_NUMBER
    maxValue = maxValue or MAX_SAFE_NUMBER
    number = math.max(minValue, math.min(maxValue, number))
    return math.floor(number)
end

local function Clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, SafeNumber(value, minValue)))
end

-- 配置文件历史上同时出现过 0.30（比例）和 30（百分数）两种写法；
-- 统一归一化后再交给战斗/UI，避免把补给误算成 0.3%。
local function NormalizeRatio(value, fallback)
    local number = SafeNumber(value, fallback or 0)
    if number > 1 then number = number / 100 end
    return Clamp(number, 0, 1)
end

local function CopyTable(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true
    local copy = {}
    for key, child in pairs(value) do
        local keyType = type(key)
        if keyType == "string" or keyType == "number" then
            copy[key] = CopyTable(child, seen)
        end
    end
    seen[value] = nil
    return copy
end

local function NormalizeClassId(classId)
    if classId == "warrior" or classId == "mage" or classId == "taoist" then
        return classId
    end
    return nil
end

local function ResolveLevel(source)
    if type(source) ~= "table" then return 1 end
    return SafeInteger(source.level or source.lv, 1, 1, MAX_SAFE_NUMBER)
end

local function ResolveClassId(source)
    if type(source) ~= "table" then return nil end
    return NormalizeClassId(source.classId or source.class or source.role)
end

local function ResolveQuestFinished(source)
    if source == true then return true end
    if type(source) ~= "table" then return false end
    if source.questFinished == true or source.mainlineFinished == true
        or source.isQuestFinished == true or source.finished == true then
        return true
    end
    local quest = source.quest or source.mainQuest
    return type(quest) == "table" and quest.finished == true
end

-- 支持函数型/对象型/简单数字型的可注入随机源，便于离线测试和回放。
local function RandomInt(rng, minValue, maxValue)
    if maxValue <= minValue then return minValue end

    local value = nil
    if type(rng) == "function" then
        local ok, result = pcall(rng, minValue, maxValue)
        if ok then value = result end
    elseif type(rng) == "table" and type(rng.random) == "function" then
        local ok, result = pcall(rng.random, rng, minValue, maxValue)
        if ok then value = result end
    end

    if type(value) == "number" and IsFiniteNumber(value) then
        -- 允许注入源返回 [0,1) 浮点，也允许直接返回整数。
        if value >= 0 and value < 1 then
            return minValue + math.floor(value * (maxValue - minValue + 1))
        end
        return math.max(minValue, math.min(maxValue, math.floor(value)))
    end

    return math.random(minValue, maxValue)
end

local function RandomChoice(rng, values)
    if type(values) ~= "table" or #values == 0 then return nil end
    return values[RandomInt(rng, 1, #values)]
end

local function NewEvent(eventType, payload)
    local event = { type = eventType }
    if type(payload) == "table" then
        for key, value in pairs(payload) do event[key] = value end
    end
    return event
end

-- ============================================================================
-- 对外常量与地图契约
-- ============================================================================

ShabakSiege.MAP_ID = "map_sb"
ShabakSiege.MAP_NAME = "沙巴克城"
ShabakSiege.TITLE = "沙巴克城主"

ShabakSiege.STATE = {
    READY = "ready",
    ACTIVE = "active",
    VICTORY = "victory",
    DEFEAT = "defeat",
    ABORTED = "aborted",
}

ShabakSiege.PHASE = {
    DEPLOYMENT = "deployment",
    SOUTH_GATE = "south_gate",
    -- 新数据契约使用 street_flags；旧接入方仍可通过 FLAGS 常量读取。
    FLAGS = StaticData and "street_flags" or "flags",
    STREET_FLAGS = StaticData and "street_flags" or "flags",
    INNER_FLAG = "inner_flag",
    PALACE_SEAL = "palace_seal",
    THRONE = "throne",
    THRONE_DEFENSE = "throne_defense",
    VICTORY = "victory",
    DEFEAT = "defeat",
}

ShabakSiege.OBJECTIVE = {
    SOUTH_GATE = "south_gate",
    EAST_FLAG = "east_flag",
    WEST_FLAG = "west_flag",
    INNER_FLAG = "inner_flag",
    PALACE_SEAL = "palace_seal",
    THRONE = "throne",
}

ShabakSiege.RESULT_REASON = {
    PLAYER_DEAD = "player_dead",
    TIMEOUT = "timeout",
    VOLUNTARY_EXIT = "voluntary_exit",
    MAP_CHANGED = "map_changed",
    INTERRUPTED = "interrupted",
}

ShabakSiege.CONFIG = {
    minLevel = 50,
    deploymentDuration = 10,
    timeLimit = 900,
    objectiveCaptureDuration = 8,
    gateMaxHP = 4200,
    palaceSealMaxHP = 3200,
    throneCaptureDuration = 12,
    throneDefenseDuration = 60,
    maxLives = 2,
    activeDefenderCap = 7,
    throneActiveDefenderCap = 8,
    companionLevelOffset = -2,
    companionDamageShare = { min = 0.25, max = 0.35 },
    fieldSupplyCount = 3,
    fieldSupplyHealRatio = 0.10,
    fieldMedkitHealRatio = 0.30,
    fieldMedkitCount = 1,
    throneWaveInterval = 20,
}

if StaticData then
    local instance = StaticData.INSTANCE or {}
    ShabakSiege.CONFIG.minLevel = SafeInteger(StaticData.MIN_LEVEL,
        ShabakSiege.CONFIG.minLevel, 1, MAX_SAFE_NUMBER)
    ShabakSiege.CONFIG.timeLimit = SafeNumber(instance.totalDuration,
        ShabakSiege.CONFIG.timeLimit)
    ShabakSiege.CONFIG.deploymentDuration = SafeNumber(instance.deploymentDuration,
        ShabakSiege.CONFIG.deploymentDuration)
    ShabakSiege.CONFIG.throneDefenseDuration = SafeNumber(instance.throneHoldDuration,
        ShabakSiege.CONFIG.throneDefenseDuration)
    ShabakSiege.CONFIG.activeDefenderCap = SafeInteger(StaticData.NORMAL_ACTIVE_CAP,
        ShabakSiege.CONFIG.activeDefenderCap, 1, 64)
    ShabakSiege.CONFIG.throneActiveDefenderCap = SafeInteger(StaticData.THRONE_ACTIVE_CAP,
        ShabakSiege.CONFIG.throneActiveDefenderCap, 1, 64)
    local objectiveHealth = StaticData.OBJECTIVE_HEALTH or {}
    ShabakSiege.CONFIG.gateMaxHP = SafeInteger(objectiveHealth.southGate,
        ShabakSiege.CONFIG.gateMaxHP, 1, MAX_SAFE_NUMBER)
    ShabakSiege.CONFIG.palaceSealMaxHP = SafeInteger(objectiveHealth.palaceSeal,
        ShabakSiege.CONFIG.palaceSealMaxHP, 1, MAX_SAFE_NUMBER)
    local supply = StaticData.CHECKPOINT_SUPPLY or {}
    ShabakSiege.CONFIG.fieldSupplyCount = #(supply.stages or {})
    ShabakSiege.CONFIG.fieldSupplyHealRatio = NormalizeRatio(
        supply.healPercent, ShabakSiege.CONFIG.fieldSupplyHealRatio)
    ShabakSiege.CONFIG.fieldMedkitCount = SafeInteger(supply.emergencyPotionCount,
        ShabakSiege.CONFIG.fieldMedkitCount, 0, 5)
end

ShabakSiege.POTION_POLICY = {
    recommendedHPMin = 8,
    recommendedHPMax = 10,
    warningHPBelow = 6,
    recommendedMPMin = 4,
    recommendedMPMax = 6,
    -- 入场检查只给风险提示，不因药水数量不足强制阻止挑战。
    blocksEntry = false,
}

if StaticData then
    local potions = StaticData.POTIONS or {}
    local hpPotion = potions.hp or {}
    local mpPotion = potions.mp or {}
    ShabakSiege.CONFIG.fieldMedkitHealRatio = NormalizeRatio(
        hpPotion.healPercent, ShabakSiege.CONFIG.fieldMedkitHealRatio)
    ShabakSiege.POTION_POLICY.recommendedHPMin = SafeInteger(hpPotion.recommendedMin,
        ShabakSiege.POTION_POLICY.recommendedHPMin, 0, 999)
    ShabakSiege.POTION_POLICY.warningHPBelow = SafeInteger(hpPotion.warnBelow,
        ShabakSiege.POTION_POLICY.warningHPBelow, 0, 999)
    ShabakSiege.POTION_POLICY.recommendedMPMin = SafeInteger(mpPotion.recommendedMin,
        ShabakSiege.POTION_POLICY.recommendedMPMin, 0, 999)
    ShabakSiege.POTION_POLICY.recommendedMPMax = SafeInteger(mpPotion.recommendedMax,
        ShabakSiege.POTION_POLICY.recommendedMPMax, 0, 999)
end

local MAP_CONTRACT = {
    id = ShabakSiege.MAP_ID,
    name = ShabakSiege.MAP_NAME,
    minLevel = ShabakSiege.CONFIG.minLevel,
    maxLevel = nil,
    repeatable = true,
    siegeOnly = true,
    naturalSpawns = false,
    normalNpcServices = false,
    spawnPool = {},
    -- 用有限哨兵值，避免宿主把地图契约编码成 JSON 时出现 Infinity。
    spawnSettings = { initialCount = 0, maxEnemies = 0, interval = 999999 },
    safeZoneRadius = 6,
    teleportCost = 0,
    landmarks = {
        { id = ShabakSiege.OBJECTIVE.SOUTH_GATE, name = "南门", x = 0, z = -42, kind = "gate" },
        { id = ShabakSiege.OBJECTIVE.EAST_FLAG, name = "东街战旗", x = 30, z = -4, kind = "flag" },
        { id = ShabakSiege.OBJECTIVE.WEST_FLAG, name = "西街战旗", x = -30, z = -4, kind = "flag" },
        { id = ShabakSiege.OBJECTIVE.INNER_FLAG, name = "内城战旗", x = 0, z = 14, kind = "flag" },
        { id = ShabakSiege.OBJECTIVE.PALACE_SEAL, name = "皇宫封印", x = 0, z = 28, kind = "seal" },
        { id = ShabakSiege.OBJECTIVE.THRONE, name = "城主王座", x = 0, z = 38, kind = "throne" },
    },
}

if StaticData and type(StaticData.LANDMARKS) == "table" then
    -- 保留统一的内部 ID/类型，同时让地图视觉/小地图读取 ShabakData 的
    -- 坐标，避免数据契约与会话目标点发生漂移。
    local kindById = {
        south_gate = "gate",
        east_flag = "flag",
        west_flag = "flag",
        inner_flag = "flag",
        palace_seal = "seal",
        throne = "throne",
    }
    MAP_CONTRACT.landmarks = {}
    for _, landmark in ipairs(StaticData.LANDMARKS) do
        MAP_CONTRACT.landmarks[#MAP_CONTRACT.landmarks + 1] = {
            id = landmark.id,
            name = landmark.name,
            x = SafeNumber(landmark.x, 0),
            z = SafeNumber(landmark.z, 0),
            kind = kindById[landmark.id] or "objective",
        }
    end
end

if StaticData and type(StaticData.SPAWN_POSITION) == "table" then
    MAP_CONTRACT.spawnPos = CopyTable(StaticData.SPAWN_POSITION)
end

function ShabakSiege.GetMapContract()
    return CopyTable(MAP_CONTRACT)
end

function ShabakSiege.GetStaticData()
    return CopyTable(StaticData)
end

function ShabakSiege.GetConfig()
    return CopyTable(ShabakSiege.CONFIG)
end

-- ============================================================================
-- 入口检查与等级/装备规则
-- ============================================================================

--- 判断主线完成且角色达到 Lv.50 后是否可进入。
---@param player table
---@param questState table|nil 可传 Quest.GetState()，也可把完成字段放在 player 上
---@return boolean
function ShabakSiege.IsUnlocked(player, questState)
    local level = ResolveLevel(player)
    local finished = ResolveQuestFinished(questState or player)
    return level >= ShabakSiege.CONFIG.minLevel and finished
end

--- 返回可直接用于入口 UI 的失败原因。
---@param player table
---@param questState table|nil
---@return boolean, string|nil
function ShabakSiege.CanEnter(player, questState)
    if type(player) ~= "table" then
        return false, "角色数据无效"
    end
    local classId = ResolveClassId(player)
    if not classId then return false, "职业数据无效" end
    if ResolveLevel(player) < ShabakSiege.CONFIG.minLevel then
        return false, "需要 Lv." .. tostring(ShabakSiege.CONFIG.minLevel)
    end
    if not ResolveQuestFinished(questState or player) then
        return false, "需要完成主线后才能挑战沙巴克城"
    end
    return true, nil
end

--- 返回入场药水建议。warning=true 仅提示风险，不改变 CanEnter 结果。
---@param potions table|nil {hp:number,mp:number}
---@return table
function ShabakSiege.ValidatePotionSupply(potions)
    potions = type(potions) == "table" and potions or {}
    local hp = SafeInteger(potions.hp, 0, 0, MAX_SAFE_NUMBER)
    local mp = SafeInteger(potions.mp, 0, 0, MAX_SAFE_NUMBER)
    return {
        hp = hp,
        mp = mp,
        warning = hp < ShabakSiege.POTION_POLICY.warningHPBelow,
        hpRecommended = hp >= ShabakSiege.POTION_POLICY.recommendedHPMin
            and hp <= ShabakSiege.POTION_POLICY.recommendedHPMax,
        mpRecommended = mp >= ShabakSiege.POTION_POLICY.recommendedMPMin
            and mp <= ShabakSiege.POTION_POLICY.recommendedMPMax,
        blocksEntry = ShabakSiege.POTION_POLICY.blocksEntry,
    }
end

function ShabakSiege.NormalizeLevel(level)
    return SafeInteger(level, 1, 1, MAX_SAFE_NUMBER)
end

function ShabakSiege.GetDefenderLevel(playerLevel, tier, rng)
    local level = math.max(ShabakSiege.CONFIG.minLevel, ShabakSiege.NormalizeLevel(playerLevel))
    -- 品阶只影响血量/伤害和波次身份，不再额外抬高等级；所有守军都围绕
    -- 当前玩家等级作小幅上下浮动，既满足 Lv.50 地板，也避免统领突然
    -- 高出玩家数级而破坏单人中偏难的预期。
    local minOffset, maxOffset = -1, 1
    if tier == "elite" then
        minOffset, maxOffset = -1, 1
    elseif tier == "commander" then
        minOffset, maxOffset = -1, 1
    end
    if StaticData and type(StaticData.GUARD_LEVEL_OFFSETS) == "table"
        and #StaticData.GUARD_LEVEL_OFFSETS > 0 then
        local offset = StaticData.GUARD_LEVEL_OFFSETS[
            RandomInt(rng, 1, #StaticData.GUARD_LEVEL_OFFSETS)]
        offset = SafeInteger(offset, 0, -10, 10)
        if tier == "elite" then offset = math.max(minOffset, math.min(maxOffset, offset)) end
        if tier == "commander" then offset = math.max(minOffset, math.min(maxOffset, offset)) end
        return math.max(ShabakSiege.CONFIG.minLevel, level + offset)
    end
    return math.max(ShabakSiege.CONFIG.minLevel,
        level + RandomInt(rng, minOffset, maxOffset))
end

-- ============================================================================
-- 临时装备与三职业 actor descriptor
-- ============================================================================

local SLOT_ORDER = {
    "helmet", "armor", "weapon", "necklace", "bracelet1", "bracelet2",
    "ring1", "ring2", "belt", "boots",
}

local COMMON_GEAR = {
    helmet = { "helm_iron" },
    armor = { "armor_cloth" },
    necklace = { "neck_bone", "neck_copper" },
    bracelet = { "brace_iron", "brace_small" },
    ring = { "ring_copper", "ring_horn" },
    belt = { "belt_cloth", "belt_hide" },
    boots = { "boots_cloth" },
    warrior = { "sword_iron" },
    mage = { "staff_wood", "staff_hs" },
    taoist = { "bell_wm", "bell_copper" },
}

local RARE_GEAR = {
    helmet = { "helm_golden" },
    armor = { "armor_chain" },
    necklace = { "neck_amber", "neck_white_tiger" },
    bracelet = { "brace_gold", "brace_exorcist" },
    ring = { "ring_gold", "ring_platinum" },
    belt = { "belt_chain", "belt_soul" },
    boots = { "boots_iron" },
    warrior = { "sword_flame", "sword_jzy" },
    mage = { "staff_thunder" },
    taoist = { "bell_soul" },
}

local CLASS_SKILLS = {
    warrior = { "w_basic", "w_crescent", "w_thrust", "w_charge", "w_fire" },
    mage = { "m_fireball", "m_firewall", "m_thunder", "m_explosion", "m_blizzard" },
    taoist = { "t_talisman", "t_poison", "t_heal", "t_trapDemon" },
}

local CLASS_ROLE = {
    warrior = {
        maxHPMultiplier = 1.15,
        damageMultiplier = 0.84,
        attackRange = 1.8,
        preferredDistance = 1.6,
        role = "frontline",
    },
    mage = {
        maxHPMultiplier = 0.84,
        damageMultiplier = 0.72,
        attackRange = 8.0,
        preferredDistance = 6.5,
        role = "backline",
    },
    taoist = {
        maxHPMultiplier = 0.92,
        damageMultiplier = 0.64,
        attackRange = 7.0,
        preferredDistance = 5.5,
        role = "support",
    },
}

local function GearPoolForSlot(classId, slot)
    if slot == "weapon" then
        return COMMON_GEAR[classId], RARE_GEAR[classId]
    end
    if slot == "bracelet1" or slot == "bracelet2" then
        return COMMON_GEAR.bracelet, RARE_GEAR.bracelet
    end
    if slot == "ring1" or slot == "ring2" then
        return COMMON_GEAR.ring, RARE_GEAR.ring
    end
    return COMMON_GEAR[slot], RARE_GEAR[slot]
end

--- 创建十个槽位的临时装备描述。若传入 itemFactory，会把实际
--- Inventory.CreateItem(itemId, 0) 结果挂在 descriptor.item 上；否则只返回
--- itemId，避免这个纯逻辑模块依赖引擎对象。
---@param classId string
---@param rng any
---@param itemFactory function|nil
---@return table[]
function ShabakSiege.BuildTemporaryLoadout(classId, rng, itemFactory)
    classId = NormalizeClassId(classId) or "warrior"
    local loadout = {}
    for _, slot in ipairs(SLOT_ORDER) do
        local commonPool, rarePool = GearPoolForSlot(classId, slot)
        local rarity = RandomInt(rng, 1, 100) <= 35 and "RARE" or "COMMON"
        local pool = rarity == "RARE" and rarePool or commonPool
        if type(pool) ~= "table" or #pool == 0 then
            rarity, pool = "COMMON", commonPool
        end
        local itemId = RandomChoice(rng, pool)
        local descriptor = {
            slot = slot,
            itemId = itemId,
            rarity = rarity,
            enhance = 0,
            temporary = true,
        }
        if type(itemFactory) == "function" and itemId then
            local ok, item = pcall(itemFactory, itemId, 0)
            if ok and type(item) == "table" then
                item.enhance = 0
                descriptor.item = item
            end
        end
        loadout[#loadout + 1] = descriptor
    end
    return loadout
end

local function BuildActorDescriptor(id, classId, tier, phase, wave, spawnZone,
    playerLevel, rng, itemFactory)
    local role = CLASS_ROLE[classId]
    local level = ShabakSiege.GetDefenderLevel(playerLevel, tier, rng)
    local loadout = ShabakSiege.BuildTemporaryLoadout(classId, rng, itemFactory)
    local canSummon = classId == "taoist" and tier == "commander"
    local skillPolicy = CopyTable(CLASS_SKILLS[classId])
    return {
        id = id,
        faction = "defender",
        classId = classId,
        className = classId == "warrior" and "武士"
            or classId == "mage" and "法师" or "道士",
        tier = tier,
        level = level,
        phase = phase,
        wave = wave,
        spawnZone = spawnZone or phase,
        actualCharacter = true,
        isMonster = false,
        temporary = true,
        role = role.role,
        attackRange = role.attackRange,
        preferredDistance = role.preferredDistance,
        maxHPMultiplier = role.maxHPMultiplier * (tier == "commander" and 1.12
            or tier == "elite" and 1.06 or 1.0),
        damageMultiplier = role.damageMultiplier * (tier == "commander" and 1.10
            or tier == "elite" and 1.05 or 1.0),
        skillPolicy = skillPolicy,
        canSummon = canSummon,
        summonLimit = canSummon and 1 or 0,
        equipment = loadout,
        state = "pending",
        spawned = false,
        defeated = false,
        healthResetCount = 0,
    }
end

local PHASE_COMPOSITION = {
    {
        phase = ShabakSiege.PHASE.SOUTH_GATE,
        entries = {
            { "warrior", "normal", "south_gate" }, { "warrior", "normal", "south_gate" },
            { "warrior", "normal", "south_gate" }, { "mage", "normal", "south_gate" },
            { "taoist", "normal", "south_gate" },
        },
    },
    {
        phase = ShabakSiege.PHASE.FLAGS,
        entries = {
            { "warrior", "normal", "east_flag" }, { "warrior", "normal", "east_flag" },
            { "mage", "normal", "east_flag" }, { "warrior", "normal", "west_flag" },
            { "warrior", "normal", "west_flag" }, { "taoist", "normal", "west_flag" },
        },
    },
    {
        phase = ShabakSiege.PHASE.INNER_FLAG,
        entries = {
            { "warrior", "normal", "inner_flag" }, { "warrior", "normal", "inner_flag" },
            { "mage", "normal", "inner_flag" }, { "taoist", "normal", "inner_flag" },
        },
    },
    {
        phase = ShabakSiege.PHASE.PALACE_SEAL,
        entries = {
            { "warrior", "normal", "palace_seal" }, { "warrior", "normal", "palace_seal" },
            { "mage", "normal", "palace_seal" }, { "warrior", "elite", "palace_seal" },
        },
    },
    {
        phase = ShabakSiege.PHASE.THRONE_DEFENSE,
        wave = 1,
        entries = { { "warrior", "normal", "throne" }, { "mage", "normal", "throne" } },
    },
    {
        phase = ShabakSiege.PHASE.THRONE_DEFENSE,
        wave = 2,
        entries = { { "warrior", "normal", "throne" }, { "taoist", "normal", "throne" } },
    },
    {
        phase = ShabakSiege.PHASE.THRONE_DEFENSE,
        wave = 3,
        entries = {
            { "warrior", "elite", "throne" }, { "mage", "normal", "throne" },
            { "warrior", "commander", "throne" },
        },
    },
}

-- 当 ShabakData 存在时，以它的阶段预算/职业配比为准；本地回退表仍保留，
-- 这样先合入会话模块也不会让旧资源树失效。每个静态阶段的职业数量会被
-- 展开成 actor entry，并在东西街/王座阶段补上明确的 spawnZone/wave。
local function BuildStaticPhaseComposition()
    if not StaticData or type(StaticData.PHASES) ~= "table" then return nil end
    local result = {}
    local classOrder = { "warrior", "mage", "taoist" }
    for _, staticPhase in ipairs(StaticData.PHASES) do
        local staticId = staticPhase.id
        local phase = staticId == "south_gate" and ShabakSiege.PHASE.SOUTH_GATE
            or staticId == "street_flags" and ShabakSiege.PHASE.FLAGS
            or staticId == "inner_flag" and ShabakSiege.PHASE.INNER_FLAG
            or staticId == "palace_seal" and ShabakSiege.PHASE.PALACE_SEAL
            or staticId == "throne" and ShabakSiege.PHASE.THRONE_DEFENSE
            or nil
        if phase then
            local mix = type(StaticData.GetGuardMix) == "function"
                and StaticData.GetGuardMix(staticId)
                or StaticData.GUARD_PHASE_MIX[staticId] or {}
            local entries = {}
            for _, classId in ipairs(classOrder) do
                local count = SafeInteger(mix[classId], 0, 0, 64)
                for _ = 1, count do
                    entries[#entries + 1] = { classId, "normal" }
                end
            end
            local budget = SafeInteger(staticPhase.guardBudget, #entries, 0, 64)
            while #entries < budget do
                entries[#entries + 1] = { "warrior", "normal" }
            end
            while #entries > budget do table.remove(entries) end

            if staticId == "street_flags" then
                local eastCount = math.ceil(#entries / 2)
                for index, entry in ipairs(entries) do
                    entry[3] = index <= eastCount and "east_flag" or "west_flag"
                end
            elseif staticId == "throne" then
                local waveSize = math.max(1, math.ceil(#entries / 3))
                for index, entry in ipairs(entries) do
                    entry[3] = "throne"
                    entry[4] = math.min(3, math.floor((index - 1) / waveSize) + 1)
                end
                -- 末波保留一名统领；若静态预算为空则不生成虚构角色。
                if #entries > 0 then
                    local finalIndex = #entries
                    entries[finalIndex][2] = "commander"
                    if finalIndex > 1 and entries[finalIndex - 1][2] == "normal" then
                        entries[finalIndex - 1][2] = "elite"
                    end
                end
            else
                local zone = staticId
                for _, entry in ipairs(entries) do entry[3] = zone end
            end
            result[#result + 1] = { phase = phase, entries = entries }
        end
    end
    return #result > 0 and result or nil
end

local function GetPhaseComposition()
    return BuildStaticPhaseComposition() or PHASE_COMPOSITION
end

local function BuildDefenderRoster(playerLevel, rng, itemFactory)
    local roster = {}
    local serial = 0
    for _, group in ipairs(GetPhaseComposition()) do
        for _, entry in ipairs(group.entries) do
            serial = serial + 1
            local id = string.format("sb_defender_%02d", serial)
            roster[#roster + 1] = BuildActorDescriptor(id, entry[1], entry[2],
                group.phase, entry[4] or group.wave, entry[3], playerLevel, rng, itemFactory)
        end
    end
    return roster
end

local function BuildCompanionDescriptor(classId, playerLevel, index, itemFactory, rng)
    local role = CLASS_ROLE[classId]
    local staticBehavior = StaticData and StaticData.SUPPORT_BEHAVIOR
        and StaticData.SUPPORT_BEHAVIOR[classId] or nil
    local level = math.max(ShabakSiege.CONFIG.minLevel,
        ShabakSiege.NormalizeLevel(playerLevel) + ShabakSiege.CONFIG.companionLevelOffset)
    local descriptor = {
        id = "sb_companion_" .. tostring(index),
        faction = "ally",
        classId = classId,
        className = classId == "warrior" and "武士"
            or classId == "mage" and "法师" or "道士",
        level = level,
        role = role.role,
        -- 两名队友合计只承担约 25%~35% 的队伍伤害；具体运行时可用
        -- damageShare 在区间内取值，避免固定值让每次挑战完全相同。
        damageShare = 0.125 + RandomInt(rng, 0, 50) / 1000,
        damageMultiplier = SafeNumber(staticBehavior and staticBehavior.damageMultiplier,
            role.damageMultiplier),
        leashRange = SafeNumber(staticBehavior and staticBehavior.leashRange, 8),
        maxHPMultiplier = classId == "warrior" and 0.75
            or classId == "mage" and 0.60 or 0.65,
        attackRange = role.attackRange,
        preferredDistance = role.preferredDistance,
        equipment = ShabakSiege.BuildTemporaryLoadout(classId, rng, itemFactory),
        state = "active",
        hpRatio = 1.0,
        canCaptureObjectives = false,
        canBreakGate = false,
        canUsePlayerPotions = false,
        canSummon = false,
        healPolicy = classId == "taoist" and {
            triggerPlayerHpBelow = SafeNumber(staticBehavior and staticBehavior.healThreshold,
                0.45),
            cooldown = SafeNumber(staticBehavior and staticBehavior.healCooldown, 15),
            maxUses = SafeInteger(staticBehavior and staticBehavior.maxHealsPerSiege,
                5, 0, 99),
            healRatio = NormalizeRatio(staticBehavior and staticBehavior.healPercent, 0.06),
        } or nil,
    }
    return descriptor
end

local function BuildCompanions(playerClassId, playerLevel, itemFactory, rng)
    local classes = { "warrior", "mage", "taoist" }
    local companions = {}
    local index = 0
    for _, classId in ipairs(classes) do
        if classId ~= playerClassId then
            index = index + 1
            companions[#companions + 1] = BuildCompanionDescriptor(classId,
                playerLevel, index, itemFactory, rng)
        end
    end
    return companions
end

function ShabakSiege.GetClassSkills(classId)
    return CopyTable(CLASS_SKILLS[NormalizeClassId(classId)] or {})
end

-- ============================================================================
-- Session 生命周期
-- ============================================================================

local function InitializeObjectives()
    return {
        [ShabakSiege.OBJECTIVE.SOUTH_GATE] = {
            id = ShabakSiege.OBJECTIVE.SOUTH_GATE,
            kind = "gate",
            label = "攻破南门",
            maxHP = ShabakSiege.CONFIG.gateMaxHP,
            hp = ShabakSiege.CONFIG.gateMaxHP,
            destroyed = false,
            captured = false,
            captureDuration = 0,
            progress = 0,
        },
        [ShabakSiege.OBJECTIVE.EAST_FLAG] = {
            id = ShabakSiege.OBJECTIVE.EAST_FLAG,
            kind = "flag",
            label = "夺取东街战旗",
            captureDuration = ShabakSiege.CONFIG.objectiveCaptureDuration,
            progress = 0,
            captured = false,
        },
        [ShabakSiege.OBJECTIVE.WEST_FLAG] = {
            id = ShabakSiege.OBJECTIVE.WEST_FLAG,
            kind = "flag",
            label = "夺取西街战旗",
            captureDuration = ShabakSiege.CONFIG.objectiveCaptureDuration,
            progress = 0,
            captured = false,
        },
        [ShabakSiege.OBJECTIVE.INNER_FLAG] = {
            id = ShabakSiege.OBJECTIVE.INNER_FLAG,
            kind = "flag",
            label = "夺取内城战旗",
            captureDuration = ShabakSiege.CONFIG.objectiveCaptureDuration,
            progress = 0,
            captured = false,
        },
        [ShabakSiege.OBJECTIVE.PALACE_SEAL] = {
            id = ShabakSiege.OBJECTIVE.PALACE_SEAL,
            kind = "seal",
            label = "击碎皇宫封印",
            maxHP = ShabakSiege.CONFIG.palaceSealMaxHP,
            hp = ShabakSiege.CONFIG.palaceSealMaxHP,
            destroyed = false,
            captureDuration = 0,
            progress = 0,
            captured = false,
        },
        [ShabakSiege.OBJECTIVE.THRONE] = {
            id = ShabakSiege.OBJECTIVE.THRONE,
            kind = "throne",
            label = "占领城主王座",
            captureDuration = ShabakSiege.CONFIG.throneCaptureDuration,
            progress = 0,
            captured = false,
        },
    }
end

function Session:init(player, opts)
    opts = type(opts) == "table" and opts or {}
    self.state = ShabakSiege.STATE.READY
    self.phase = ShabakSiege.PHASE.DEPLOYMENT
    self.result = nil
    self.resultReason = nil
    self.playerLevel = ResolveLevel(player)
    self.playerClassId = ResolveClassId(player)
    self.playerName = type(player) == "table" and player.name or nil
    self.elapsed = 0
    self.phaseElapsed = 0
    -- 王座坚守不是单纯等待波次结束：玩家本人必须留在王座区并保持
    -- 无守军干扰，才会推进这一段读条。阶段计时仍用于刷新守军波次。
    self.throneHoldProgress = 0
    self.throneHolding = false
    self.livesUsed = 0
    self.respawnPending = false
    self.latestRallyPoint = "entry"
    self.capturingObjective = nil
    self.objectives = InitializeObjectives()
    self.capturedFlags = {}
    local supplyHealRatio = ShabakSiege.CONFIG.fieldSupplyHealRatio
    local supplyMedkits = ShabakSiege.CONFIG.fieldMedkitCount
    self.supplies = {
        south_gate = { claimed = false, hpRatio = supplyHealRatio, mpRatio = supplyHealRatio,
            medkits = supplyMedkits },
        inner_flag = { claimed = false, hpRatio = supplyHealRatio, mpRatio = supplyHealRatio,
            medkits = supplyMedkits },
        palace_seal = { claimed = false, hpRatio = supplyHealRatio, mpRatio = supplyHealRatio,
            medkits = supplyMedkits },
    }
    self.fieldMedkits = 0
    self.companions = BuildCompanions(self.playerClassId, self.playerLevel,
        opts.itemFactory, opts.rng)
    self.defenders = BuildDefenderRoster(self.playerLevel, opts.rng, opts.itemFactory)
    self.activeDefenderCount = 0
    self.stats = {
        defendersDefeated = 0,
        objectivesCaptured = 0,
        gateDamage = 0,
        fieldSuppliesClaimed = 0,
        playerDeaths = 0,
        companionDeaths = 0,
    }
    self.eventQueue = {}
    self.onEvent = type(opts.onEvent) == "function" and opts.onEvent or nil
    self.rng = opts.rng
    self.itemFactory = opts.itemFactory
    self.createdAt = opts.createdAt
end

function ShabakSiege.CreateSession(player, opts)
    local allowed, reason = ShabakSiege.CanEnter(player, opts and opts.questState)
    if not allowed then return nil, reason end
    local session = setmetatable({}, Session)
    session:init(player, opts)
    return session
end

function ShabakSiege.Begin(player, opts)
    local session, reason = ShabakSiege.CreateSession(player, opts)
    if not session then return nil, reason end
    session:Start()
    return session
end

function Session:Emit(eventType, payload)
    local event = NewEvent(eventType, payload)
    self.eventQueue[#self.eventQueue + 1] = event
    if self.onEvent then pcall(self.onEvent, event) end
end

function Session:DrainEvents()
    local events = self.eventQueue
    self.eventQueue = {}
    return events
end

function Session:Start()
    if self.state ~= ShabakSiege.STATE.READY then return false, "会话已开始" end
    self.state = ShabakSiege.STATE.ACTIVE
    self.phase = ShabakSiege.PHASE.DEPLOYMENT
    self:Emit("siege_started", {
        mapId = ShabakSiege.MAP_ID,
        totalDuration = ShabakSiege.CONFIG.timeLimit,
        deploymentDuration = ShabakSiege.CONFIG.deploymentDuration,
    })
    return true
end

function Session:IsActive()
    return self.state == ShabakSiege.STATE.ACTIVE
end

function Session:IsFinished()
    return self.state == ShabakSiege.STATE.VICTORY
        or self.state == ShabakSiege.STATE.DEFEAT
        or self.state == ShabakSiege.STATE.ABORTED
end

function Session:GetRemainingTime()
    return math.max(0, ShabakSiege.CONFIG.timeLimit - self.elapsed)
end

local function IsPhaseObjectiveAvailable(session, objectiveId)
    local objectives = session.objectives
    local gate = objectives[ShabakSiege.OBJECTIVE.SOUTH_GATE]
    if objectiveId == ShabakSiege.OBJECTIVE.SOUTH_GATE then
        return session.phase == ShabakSiege.PHASE.SOUTH_GATE and not gate.destroyed
    end
    if objectiveId == ShabakSiege.OBJECTIVE.EAST_FLAG
        or objectiveId == ShabakSiege.OBJECTIVE.WEST_FLAG then
        return gate.destroyed and session.phase == ShabakSiege.PHASE.FLAGS
            and not objectives[objectiveId].captured
    end
    if objectiveId == ShabakSiege.OBJECTIVE.INNER_FLAG then
        return session.phase == ShabakSiege.PHASE.INNER_FLAG
            and objectives[objectiveId].captured ~= true
    end
    if objectiveId == ShabakSiege.OBJECTIVE.PALACE_SEAL then
        return session.phase == ShabakSiege.PHASE.PALACE_SEAL
            and objectives[objectiveId].destroyed ~= true
    end
    if objectiveId == ShabakSiege.OBJECTIVE.THRONE then
        return session.phase == ShabakSiege.PHASE.THRONE
            and objectives[objectiveId].captured ~= true
    end
    return false
end

function Session:IsObjectiveAvailable(objectiveId)
    return self:IsActive() and IsPhaseObjectiveAvailable(self, objectiveId)
end

function Session:GetObjective(objectiveId)
    local objective = self.objectives[objectiveId]
    return objective and CopyTable(objective) or nil
end

function Session:BeginObjective(objectiveId)
    if not self:IsObjectiveAvailable(objectiveId) then
        return false, "当前阶段无法进行该目标"
    end
    if objectiveId == ShabakSiege.OBJECTIVE.SOUTH_GATE
        or objectiveId == ShabakSiege.OBJECTIVE.PALACE_SEAL then
        return false, objectiveId == ShabakSiege.OBJECTIVE.SOUTH_GATE
            and "南门必须通过战斗破坏" or "皇宫封印必须通过战斗破坏"
    end
    self.capturingObjective = objectiveId
    local objective = self.objectives[objectiveId]
    objective.progress = math.max(0, SafeNumber(objective.progress, 0))
    self:Emit("objective_capture_started", {
        objectiveId = objectiveId,
        duration = objective.captureDuration,
    })
    return true
end

function Session:CancelObjective(objectiveId, reason)
    if self.capturingObjective ~= objectiveId then return false end
    self.capturingObjective = nil
    local objective = self.objectives[objectiveId]
    if objective then objective.progress = 0 end
    self:Emit("objective_capture_cancelled", {
        objectiveId = objectiveId,
        reason = reason or "contested",
    })
    return true
end

local function TransitionToPhase(session, phase)
    local retired = 0
    local previousPhase = session.phase
    local phaseRank = {
        [ShabakSiege.PHASE.DEPLOYMENT] = 0,
        [ShabakSiege.PHASE.SOUTH_GATE] = 1,
        [ShabakSiege.PHASE.FLAGS] = 2,
        [ShabakSiege.PHASE.STREET_FLAGS] = 2,
        [ShabakSiege.PHASE.INNER_FLAG] = 3,
        [ShabakSiege.PHASE.PALACE_SEAL] = 4,
        [ShabakSiege.PHASE.THRONE] = 5,
        [ShabakSiege.PHASE.THRONE_DEFENSE] = 6,
    }
    local targetRank = phaseRank[phase]
    -- 阶段推进后，上一片区域的残余守军（包括尚未生成的 pending
    -- 计划）都撤退并由宿主回收/跳过对应实体。pending 也必须退休，
    -- 否则它们会在新阶段继续占用总预算，且可能在后续波次被错误激活。
    -- 但不能把未来阶段的 pending 一并退休；它们仍要在进入对应阶段
    -- 时生成。正常顺序按 phaseRank 判断，旧/未知调用则只清理上一阶段。
    for _, defender in ipairs(session.defenders) do
        local defenderRank = phaseRank[defender.phase]
        local isPastPhase = false
        if defender.phase ~= phase then
            if defender.state == "active" then
                -- 已生成实体只能来自已经进入过的区域；即便旧接入方
                -- 没有设置 phaseRank，也要确保它不会跨阶段残留。
                isPastPhase = true
            elseif defender.state == "pending" then
                isPastPhase = defender.phase == previousPhase
                    or (targetRank ~= nil and defenderRank ~= nil
                        and defenderRank < targetRank)
            end
        end
        if isPastPhase then
            local wasActive = defender.state == "active"
            defender.state = "retired"
            if wasActive then
                session.activeDefenderCount = math.max(0,
                    session.activeDefenderCount - 1)
            end
            retired = retired + 1
        end
    end
    session.phase = phase
    session.phaseElapsed = 0
    if phase == ShabakSiege.PHASE.THRONE_DEFENSE then
        session.throneHoldProgress = 0
        session.throneHolding = false
    end
    session.capturingObjective = nil
    session:Emit("phase_changed", { phase = phase, retiredDefenders = retired })
    -- 新集结点提供有限队友复起；王座坚守阶段由 ReviveCompanionsAtRally
    -- 自身的策略开关阻止免费续航。
    session:ReviveCompanionsAtRally()
    if retired > 0 then
        session:Emit("defenders_retired", { count = retired, phase = phase })
    end
end

function Session:CompleteObjective(objectiveId)
    if not self:IsActive() then return false, "会话已结束" end
    if not IsPhaseObjectiveAvailable(self, objectiveId) then
        -- 已完成目标视为幂等成功，方便宿主在网络/触控重复回调时收敛。
        local existing = self.objectives[objectiveId]
        if existing and (existing.destroyed or existing.captured) then return true end
        return false, "当前阶段无法完成该目标"
    end

    local objective = self.objectives[objectiveId]
    objective.progress = objective.captureDuration or 0
    if objectiveId == ShabakSiege.OBJECTIVE.SOUTH_GATE then
        objective.destroyed = true
        objective.hp = 0
        self.latestRallyPoint = "south_gate"
        self.stats.objectivesCaptured = self.stats.objectivesCaptured + 1
        TransitionToPhase(self, ShabakSiege.PHASE.FLAGS)
    elseif objectiveId == ShabakSiege.OBJECTIVE.EAST_FLAG
        or objectiveId == ShabakSiege.OBJECTIVE.WEST_FLAG then
        objective.captured = true
        self.capturedFlags[objectiveId] = true
        self.latestRallyPoint = objectiveId
        self.stats.objectivesCaptured = self.stats.objectivesCaptured + 1
        if self.objectives[ShabakSiege.OBJECTIVE.EAST_FLAG].captured
            and self.objectives[ShabakSiege.OBJECTIVE.WEST_FLAG].captured then
            TransitionToPhase(self, ShabakSiege.PHASE.INNER_FLAG)
        end
    elseif objectiveId == ShabakSiege.OBJECTIVE.INNER_FLAG then
        objective.captured = true
        self.latestRallyPoint = "inner_flag"
        self.stats.objectivesCaptured = self.stats.objectivesCaptured + 1
        TransitionToPhase(self, ShabakSiege.PHASE.PALACE_SEAL)
    elseif objectiveId == ShabakSiege.OBJECTIVE.PALACE_SEAL then
        objective.destroyed = true
        objective.captured = true
        objective.hp = 0
        self.latestRallyPoint = "palace_gate"
        self.stats.objectivesCaptured = self.stats.objectivesCaptured + 1
        TransitionToPhase(self, ShabakSiege.PHASE.THRONE)
    elseif objectiveId == ShabakSiege.OBJECTIVE.THRONE then
        objective.captured = true
        self.stats.objectivesCaptured = self.stats.objectivesCaptured + 1
        TransitionToPhase(self, ShabakSiege.PHASE.THRONE_DEFENSE)
    else
        return false, "未知攻城目标"
    end

    self.capturingObjective = nil
    self:Emit("objective_completed", { objectiveId = objectiveId })
    return true
end

function Session:CaptureObjective(objectiveId)
    return self:CompleteObjective(objectiveId)
end

function Session:AdvanceObjective(objectiveId, dt, uncontested)
    if not self:IsActive() then return false, "会话已结束" end
    if uncontested == false then
        self:CancelObjective(objectiveId, "contested")
        return false, "目标争夺中"
    end
    if self.capturingObjective ~= objectiveId then
        local started, reason = self:BeginObjective(objectiveId)
        if not started then return false, reason end
    end
    local objective = self.objectives[objectiveId]
    local delta = Clamp(dt, 0, 5)
    objective.progress = math.min(objective.captureDuration,
        objective.progress + delta)
    if objective.progress >= objective.captureDuration then
        return self:CompleteObjective(objectiveId)
    end
    return true, objective.progress
end

function Session:DamageGate(amount)
    if not self:IsActive() or self.phase ~= ShabakSiege.PHASE.SOUTH_GATE then
        return false, "当前不是南门攻坚阶段"
    end
    local gate = self.objectives[ShabakSiege.OBJECTIVE.SOUTH_GATE]
    if gate.destroyed then return true, 0 end
    local damage = SafeNumber(amount, 0)
    if damage <= 0 then return false, "伤害无效" end
    damage = math.min(damage, gate.hp)
    gate.hp = math.max(0, gate.hp - damage)
    self.stats.gateDamage = self.stats.gateDamage + damage
    self:Emit("gate_damaged", {
        objectiveId = ShabakSiege.OBJECTIVE.SOUTH_GATE,
        damage = damage,
        hp = gate.hp,
        maxHP = gate.maxHP,
    })
    if gate.hp <= 0 then self:CompleteObjective(ShabakSiege.OBJECTIVE.SOUTH_GATE) end
    return true, damage
end

--- 皇宫封印与城门相同，必须由玩家主动施放的攻击技能造成伤害。
---@param amount number
---@return boolean, number|string
function Session:DamagePalaceSeal(amount)
    if not self:IsActive() or self.phase ~= ShabakSiege.PHASE.PALACE_SEAL then
        return false, "当前不是皇宫破封阶段"
    end
    local seal = self.objectives[ShabakSiege.OBJECTIVE.PALACE_SEAL]
    if seal.destroyed then return true, 0 end
    local damage = SafeNumber(amount, 0)
    if damage <= 0 then return false, "伤害无效" end
    damage = math.min(damage, seal.hp)
    seal.hp = math.max(0, seal.hp - damage)
    self:Emit("palace_seal_damaged", {
        objectiveId = ShabakSiege.OBJECTIVE.PALACE_SEAL,
        damage = damage,
        hp = seal.hp,
        maxHP = seal.maxHP,
    })
    if seal.hp <= 0 then self:CompleteObjective(ShabakSiege.OBJECTIVE.PALACE_SEAL) end
    return true, damage
end

-- ============================================================================
-- 补给、队友和死亡/复位
-- ============================================================================

function Session:ClaimSupply(checkpointId)
    local supply = self.supplies[checkpointId]
    if not supply then return false, "补给点不存在" end
    if supply.claimed then return false, "该补给已领取" end
    local allowed = (checkpointId == "south_gate" and self.objectives.south_gate.destroyed)
        or (checkpointId == "inner_flag" and self.objectives.inner_flag.captured)
        or (checkpointId == "palace_seal" and self.objectives.palace_seal.captured)
    if not allowed then return false, "尚未解锁该补给点" end
    supply.claimed = true
    self.fieldMedkits = self.fieldMedkits + supply.medkits
    self.stats.fieldSuppliesClaimed = self.stats.fieldSuppliesClaimed + 1
    self:Emit("field_supply_claimed", {
        checkpointId = checkpointId,
        hpRatio = supply.hpRatio,
        mpRatio = supply.mpRatio,
        medkits = supply.medkits,
    })
    return true, CopyTable(supply)
end

function Session:UseFieldMedkit(player)
    -- A field medkit is a recovery option, not a way to burn supplies while
    -- already full.  Keep the guard in the pure session API as well as the
    -- runtime/UI path so scripted callers cannot bypass the rule.
    if type(player) == "table" then
        local hp = tonumber(player.hp)
        local maxHP = tonumber(player.maxHP)
        if hp and maxHP and maxHP > 0 and hp >= maxHP then
            return false, "生命已满"
        end
    end
    if self.fieldMedkits <= 0 then return false, "没有临时急救药" end
    self.fieldMedkits = self.fieldMedkits - 1
    return true, {
        healRatio = ShabakSiege.CONFIG.fieldMedkitHealRatio,
        remaining = self.fieldMedkits,
        temporary = true,
    }
end

function Session:GetSupplyStatus()
    return {
        fieldMedkits = self.fieldMedkits,
        checkpoints = CopyTable(self.supplies),
    }
end

function Session:GetCompanions()
    return CopyTable(self.companions)
end

function Session:GetDefenderRoster()
    return CopyTable(self.defenders)
end

function Session:MarkCompanionDown(companionId)
    for _, companion in ipairs(self.companions) do
        -- Combat 回调发生在外部角色进入 dying/down 的边界，允许从任意
        -- 非 down 状态转入 down，避免丢失队友倒下事件。
        if companion.id == companionId and companion.state ~= "down" then
            companion.state = "down"
            companion.hpRatio = 0
            self.stats.companionDeaths = self.stats.companionDeaths + 1
            self:Emit("companion_down", { companionId = companionId })
            return true
        end
    end
    return false
end

function Session:ReviveCompanionsAtRally()
    local reviveDuringThrone = true
    if StaticData and StaticData.SUPPORT_REVIVE
        and StaticData.SUPPORT_REVIVE.enabledDuringThrone == false then
        reviveDuringThrone = false
    end
    local isThronePhase = self.phase == ShabakSiege.PHASE.THRONE
        or self.phase == ShabakSiege.PHASE.THRONE_DEFENSE
    if isThronePhase and not reviveDuringThrone then
        return 0
    end
    local reviveRatio = 0.50
    if StaticData and StaticData.SUPPORT_REVIVE then
        reviveRatio = NormalizeRatio(StaticData.SUPPORT_REVIVE.returnHealthPercent, reviveRatio)
    end
    local revived = 0
    for _, companion in ipairs(self.companions) do
        if companion.state == "down" then
            companion.state = "active"
            companion.hpRatio = reviveRatio
            revived = revived + 1
        end
    end
    if revived > 0 then
        self:Emit("companions_revived", {
            count = revived,
            rallyPoint = self.latestRallyPoint,
            hpRatio = reviveRatio,
        })
    end
    return revived
end

local function ResetLivingDefenderHealth(session)
    local reset = 0
    for _, defender in ipairs(session.defenders) do
        if defender.state == "active" then
            defender.healthResetCount = defender.healthResetCount + 1
            reset = reset + 1
        end
    end
    return reset
end

function Session:OnPlayerDeath()
    if not self:IsActive() then return false, "会话已结束" end
    self.stats.playerDeaths = self.stats.playerDeaths + 1
    self.livesUsed = self.livesUsed + 1
    if self.livesUsed >= ShabakSiege.CONFIG.maxLives then
        self:Defeat(ShabakSiege.RESULT_REASON.PLAYER_DEAD)
        return false, ShabakSiege.RESULT_REASON.PLAYER_DEAD
    end

    self.respawnPending = true
    local resetCount = ResetLivingDefenderHealth(self)
    self:Emit("player_down", {
        livesRemaining = ShabakSiege.CONFIG.maxLives - self.livesUsed,
        rallyPoint = self.latestRallyPoint,
        restoreLivingDefenders = true,
        resetDefenderCount = resetCount,
    })
    return true, self:GetRespawnPlan()
end

function Session:GetRespawnPlan()
    if not self.respawnPending then return nil end
    local reviveCompanions = true
    if self.phase == ShabakSiege.PHASE.THRONE_DEFENSE and StaticData
        and StaticData.SUPPORT_REVIVE
        and StaticData.SUPPORT_REVIVE.enabledDuringThrone == false then
        reviveCompanions = false
    end
    return {
        rallyPoint = self.latestRallyPoint,
        restoreHP = true,
        restoreMP = true,
        restoreLivingDefenders = true,
        reviveCompanions = reviveCompanions,
        livesRemaining = math.max(0, ShabakSiege.CONFIG.maxLives - self.livesUsed),
    }
end

function Session:CompleteRespawn()
    if not self.respawnPending then return false, "当前没有待复活状态" end
    self.respawnPending = false
    local revivedCompanions = self:ReviveCompanionsAtRally()
    self:Emit("player_revived", {
        rallyPoint = self.latestRallyPoint,
        revivedCompanions = revivedCompanions,
        restoreLivingDefenders = true,
    })
    return true, self.latestRallyPoint
end

-- ============================================================================
-- 守军激活与击杀回调
-- ============================================================================

local function IsDefenderEligibleForPhase(defender, phase, wave)
    if defender.state ~= "pending" then return false end
    if defender.phase ~= phase then return false end
    if phase == ShabakSiege.PHASE.THRONE_DEFENSE then
        return defender.wave == wave
    end
    return true
end

function Session:GetDefendersForPhase(phase, wave)
    local result = {}
    for _, defender in ipairs(self.defenders) do
        if defender.phase == phase and (phase ~= ShabakSiege.PHASE.THRONE_DEFENSE
            or defender.wave == wave) then
            result[#result + 1] = CopyTable(defender)
        end
    end
    return result
end

function Session:GetPendingSpawns()
    if not self:IsActive() then return {} end
    local phase = self.phase
    local wave = nil
    if phase == ShabakSiege.PHASE.THRONE_DEFENSE then
        wave = math.min(3, math.floor(self.phaseElapsed
            / ShabakSiege.CONFIG.throneWaveInterval) + 1)
    end
    local cap = phase == ShabakSiege.PHASE.THRONE_DEFENSE
        and ShabakSiege.CONFIG.throneActiveDefenderCap
        or ShabakSiege.CONFIG.activeDefenderCap
    local result = {}
    if self.activeDefenderCount >= cap then return result end
    for _, defender in ipairs(self.defenders) do
        if IsDefenderEligibleForPhase(defender, phase, wave)
            and self.activeDefenderCount + #result < cap then
            result[#result + 1] = CopyTable(defender)
        end
    end
    return result
end

function Session:GetDefender(defenderId)
    for _, defender in ipairs(self.defenders) do
        if defender.id == defenderId then return defender end
    end
    return nil
end

function Session:MarkDefenderSpawned(defenderId)
    local defender = self:GetDefender(defenderId)
    if not defender or defender.state ~= "pending" then return false end
    defender.state = "active"
    defender.spawned = true
    self.activeDefenderCount = self.activeDefenderCount + 1
    self:Emit("defender_spawned", {
        defenderId = defenderId,
        classId = defender.classId,
        tier = defender.tier,
        level = defender.level,
        activeCount = self.activeDefenderCount,
    })
    return true, CopyTable(defender)
end

function Session:MarkDefenderDefeated(defenderId)
    local defender = self:GetDefender(defenderId)
    if not defender or defender.defeated then return false end
    if defender.state == "active" then
        self.activeDefenderCount = math.max(0, self.activeDefenderCount - 1)
    end
    defender.state = "defeated"
    defender.defeated = true
    self.stats.defendersDefeated = self.stats.defendersDefeated + 1
    self:Emit("defender_defeated", {
        defenderId = defenderId,
        classId = defender.classId,
        tier = defender.tier,
        activeCount = self.activeDefenderCount,
    })
    return true
end

function Session:GetActiveDefenderCount()
    return self.activeDefenderCount
end

function Session:GetDefenderBudget()
    local pending = 0
    for _, defender in ipairs(self.defenders) do
        if defender.state == "pending" then pending = pending + 1 end
    end
    return {
        total = #self.defenders,
        defeated = self.stats.defendersDefeated,
        active = self.activeDefenderCount,
        pending = pending,
    }
end

-- ============================================================================
-- Update、胜负与荣誉结算
-- ============================================================================

--- 推进王座坚守。只有玩家本人留在王座区域、且区域内没有仍在作战的
--- 守军时才能累计；离开或被守军压制仅暂停，不清空已经完成的进度。
---@param dt number
---@param playerPresent boolean
---@param uncontested boolean
---@return boolean progressed
---@return number|string progressOrReason
function Session:AdvanceThroneHold(dt, playerPresent, uncontested)
    if not self:IsActive() then return false, "会话已结束" end
    if self.phase ~= ShabakSiege.PHASE.THRONE_DEFENSE then
        return false, "当前不是王座坚守阶段"
    end

    local canHold = playerPresent == true and uncontested == true
    if not canHold then
        if self.throneHolding then
            self:Emit("throne_hold_paused", {
                progress = self.throneHoldProgress,
                duration = ShabakSiege.CONFIG.throneDefenseDuration,
                reason = playerPresent == true and "contested" or "out_of_area",
            })
        end
        self.throneHolding = false
        return false, self.throneHoldProgress
    end

    self.throneHolding = true
    local delta = Clamp(dt, 0, 5)
    self.throneHoldProgress = math.min(ShabakSiege.CONFIG.throneDefenseDuration,
        self.throneHoldProgress + delta)
    if self.throneHoldProgress >= ShabakSiege.CONFIG.throneDefenseDuration then
        self.throneHoldProgress = ShabakSiege.CONFIG.throneDefenseDuration
        self:Victory()
        return true, self.throneHoldProgress
    end
    return true, self.throneHoldProgress
end

function Session:GetThroneHoldStatus()
    return {
        progress = self.throneHoldProgress,
        duration = ShabakSiege.CONFIG.throneDefenseDuration,
        holding = self.throneHolding == true,
    }
end

function Session:Update(dt)
    if not self:IsActive() then return self:DrainEvents() end
    local delta = Clamp(dt, 0, 5)
    self.elapsed = self.elapsed + delta
    self.phaseElapsed = self.phaseElapsed + delta

    if self.phase == ShabakSiege.PHASE.DEPLOYMENT
        and self.phaseElapsed >= ShabakSiege.CONFIG.deploymentDuration then
        TransitionToPhase(self, ShabakSiege.PHASE.SOUTH_GATE)
    end

    if self:IsActive() and self.elapsed >= ShabakSiege.CONFIG.timeLimit then
        self:Defeat(ShabakSiege.RESULT_REASON.TIMEOUT)
    end
    return self:DrainEvents()
end

function Session:Victory()
    if self.state ~= ShabakSiege.STATE.ACTIVE then return false end
    self.state = ShabakSiege.STATE.VICTORY
    self.phase = ShabakSiege.PHASE.VICTORY
    self.result = "victory"
    self.resultReason = nil
    self:Emit("siege_victory", {
        elapsed = self.elapsed,
        title = ShabakSiege.TITLE,
        honorPatch = self:GetHonorPatch(),
    })
    return true
end

function Session:Defeat(reason)
    if self:IsFinished() then return false end
    self.state = ShabakSiege.STATE.DEFEAT
    self.phase = ShabakSiege.PHASE.DEFEAT
    self.result = "defeat"
    self.resultReason = reason or ShabakSiege.RESULT_REASON.INTERRUPTED
    self.respawnPending = false
    self:Emit("siege_defeat", {
        reason = self.resultReason,
        elapsed = self.elapsed,
    })
    return true
end

function Session:Abort(reason)
    if self:IsFinished() then return false end
    self.state = ShabakSiege.STATE.ABORTED
    self.phase = ShabakSiege.PHASE.DEFEAT
    self.result = "aborted"
    self.resultReason = reason or ShabakSiege.RESULT_REASON.INTERRUPTED
    self.respawnPending = false
    self:Emit("siege_aborted", { reason = self.resultReason })
    return true
end

--- 首次胜利由宿主合并到当前角色槽位；这里不直接修改 SaveSystem，避免
--- 攻城中的临时状态被写入普通存档。
function Session:GetHonorPatch()
    if self.state ~= ShabakSiege.STATE.VICTORY then return nil end
    return {
        honors = {
            shabakLord = true,
            shabakWinsDelta = 1,
            shabakWinCountDelta = 1,
            shabakBestTime = self.elapsed,
        },
        title = ShabakSiege.TITLE,
        titlePermanent = true,
        combatBonus = false,
    }
end

function Session:GetSnapshot()
    local captured = {}
    for objectiveId, objective in pairs(self.objectives) do
        captured[objectiveId] = {
            destroyed = objective.destroyed == true,
            captured = objective.captured == true,
            hp = objective.hp,
            maxHP = objective.maxHP,
            progress = objective.progress,
            captureDuration = objective.captureDuration,
        }
    end
    return {
        mapId = ShabakSiege.MAP_ID,
        state = self.state,
        phase = self.phase,
        result = self.result,
        resultReason = self.resultReason,
        playerLevel = self.playerLevel,
        playerClassId = self.playerClassId,
        elapsed = self.elapsed,
        remainingTime = self:GetRemainingTime(),
        phaseElapsed = self.phaseElapsed,
        throneHoldProgress = self.throneHoldProgress,
        throneHoldDuration = ShabakSiege.CONFIG.throneDefenseDuration,
        throneHolding = self.throneHolding == true,
        livesUsed = self.livesUsed,
        livesRemaining = math.max(0, ShabakSiege.CONFIG.maxLives - self.livesUsed),
        respawnPending = self.respawnPending,
        latestRallyPoint = self.latestRallyPoint,
        capturingObjective = self.capturingObjective,
        objectives = captured,
        capturedFlags = CopyTable(self.capturedFlags),
        supplies = self:GetSupplyStatus(),
        companions = CopyTable(self.companions),
        defenderBudget = self:GetDefenderBudget(),
        stats = CopyTable(self.stats),
    }
end

return ShabakSiege
