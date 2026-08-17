-- ============================================================================
-- Enhance.lua — 装备分解 / 锻造 / 精炼的纯数值规则
-- ============================================================================

local Enhance = {}

Enhance.ENHANCE_STONE_ID = "enhance_stone"

local RARITY = {
    COMMON = { mult = 1.0, tier = 0, next = "UNCOMMON" },
    UNCOMMON = { mult = 1.3, tier = 1, next = "RARE" },
    RARE = { mult = 1.6, tier = 2, next = "EPIC" },
    EPIC = { mult = 2.0, tier = 3, next = "LEGENDARY" },
    LEGENDARY = { mult = 2.5, tier = 4, next = nil },
}

local function Integer(value)
    value = tonumber(value) or 0
    return math.floor(value)
end

local function NonNegativeInteger(value)
    return math.max(0, Integer(value))
end

local function ItemScore(item)
    if type(item) ~= "table" then return 0 end
    return (tonumber(item.atk) or 0) * 2
        + (tonumber(item.def) or 0) * 1.5
        + (tonumber(item.hp) or 0) * 0.3
end

local function StonesSpentForLevel(level)
    local stones = 0
    for targetLevel = 1, level do
        if targetLevel <= 3 then
            stones = stones + 1
        elseif targetLevel <= 6 then
            stones = stones + 2
        elseif targetLevel <= 9 then
            stones = stones + 4
        else
            stones = stones + 8
        end
    end
    return stones
end

local function EnhancementBonus(baseStat, rate, level)
    baseStat = NonNegativeInteger(baseStat)
    if baseStat == 0 or level == 0 then return 0 end
    return math.max(1, math.floor(baseStat * rate * level))
end

--- Return the gold and enhance stones gained by recycling an equipment item.
---@param item table
---@return { gold: number, stones: number }
function Enhance.Recycle(item)
    local rarity = type(item) == "table" and RARITY[item.rarity] or nil
    if not rarity then
        return { gold = 0, stones = 0 }
    end

    local stoneByRarity = {
        RARE = 1,
        EPIC = 2,
        LEGENDARY = 4,
    }
    local enhanceLevel = math.min(12, NonNegativeInteger(item.enhance))
    local returnedStones = math.floor(StonesSpentForLevel(enhanceLevel) * 0.5)

    return {
        gold = math.floor(ItemScore(item) * rarity.mult * 3),
        stones = (stoneByRarity[item.rarity] or 0) + returnedStones,
    }
end

--- Return the gold needed to forge one item at targetRarityKey.
---@param targetRarityKey string
---@return number
function Enhance.ForgeCost(targetRarityKey)
    local rarity = RARITY[targetRarityKey]
    if not rarity or rarity.tier == 0 then return 0 end
    return rarity.tier * 100
end

--- Validate three forge materials and determine their next rarity.
---@param items3 table[]
---@return { ok: boolean, reason: string, targetRarity: string|nil }
function Enhance.ForgePick(items3)
    if type(items3) ~= "table" or #items3 ~= 3 then
        return { ok = false, reason = "需要3件装备", targetRarity = nil }
    end

    local first = items3[1]
    if type(first) ~= "table" or not RARITY[first.rarity] then
        return { ok = false, reason = "装备品质无效", targetRarity = nil }
    end

    local itemType = first.itemType or first.slot
    if not itemType then
        return { ok = false, reason = "装备部位无效", targetRarity = nil }
    end

    for index = 2, 3 do
        local item = items3[index]
        if type(item) ~= "table" or not RARITY[item.rarity] then
            return { ok = false, reason = "装备品质无效", targetRarity = nil }
        end
        if item.rarity ~= first.rarity then
            return { ok = false, reason = "装备品质必须相同", targetRarity = nil }
        end
        if (item.itemType or item.slot) ~= itemType then
            return { ok = false, reason = "装备部位必须相同", targetRarity = nil }
        end
    end

    local targetRarity = RARITY[first.rarity].next
    if not targetRarity then
        return { ok = false, reason = "品质已封顶", targetRarity = nil }
    end

    return { ok = true, reason = "", targetRarity = targetRarity }
end

--- Return the resource cost and failure behavior for reaching level 1 through 12.
---@param level number
---@return { stones: number, gold: number, successRate: number, dropOnFail: boolean }
function Enhance.EnhanceCost(level)
    level = Integer(level)
    if level < 1 or level > 12 then
        return { stones = 0, gold = 0, successRate = 0, dropOnFail = false }
    end

    if level <= 3 then
        return { stones = 1, gold = 200, successRate = 1.0, dropOnFail = false }
    end
    if level <= 6 then
        return { stones = 2, gold = 500, successRate = 0.9, dropOnFail = false }
    end
    if level <= 9 then
        return { stones = 4, gold = 1500, successRate = 0.7, dropOnFail = true }
    end
    return { stones = 8, gold = 4000, successRate = 0.5, dropOnFail = true }
end

--- Return the cumulative stat bonus for an item at the supplied enhance level.
---@param item table
---@param level number
---@return { atk: number, def: number, hp: number }
function Enhance.ApplyEnhanceStats(item, level)
    level = math.min(12, NonNegativeInteger(level))
    if type(item) ~= "table" then
        return { atk = 0, def = 0, hp = 0 }
    end

    return {
        atk = EnhancementBonus(item.atk, 0.04, level),
        def = EnhancementBonus(item.def, 0.04, level),
        hp = EnhancementBonus(item.hp, 0.02, level),
    }
end

return Enhance
