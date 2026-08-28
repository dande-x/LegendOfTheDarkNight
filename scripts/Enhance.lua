-- ============================================================================
-- Enhance.lua — 装备分解 / 锻造 / 强化的纯数值规则
-- ============================================================================

local Enhance = {}

-- 分解只保留少量回收价值，避免“掉落装备 → 分解 → 无限刷金”成为主收益线。
-- 商店出售与分解共用相近的低回收倍率，装备本身的战力价值仍高于现金价值。
Enhance.RECYCLE_GOLD_MULTIPLIER = 1.5
Enhance.ENHANCE_RECYCLE_REFUND_RATE = 0.20
Enhance.FORGE_MATERIAL_COUNT = 5

local RARITY = {
    COMMON = { mult = 1.0, tier = 0, next = "UNCOMMON" },
    UNCOMMON = { mult = 1.3, tier = 1, next = "RARE" },
    RARE = { mult = 1.6, tier = 2, next = "EPIC" },
    EPIC = { mult = 2.0, tier = 3, next = "LEGENDARY" },
    LEGENDARY = { mult = 2.5, tier = 4, next = nil },
}

-- 强化改为铁匠收取纯金币，不再要求强化石。成功才升级；失败不掉级，只损失
-- 本次铁匠服务费。失败不掉级，让强化回报更直观、风险不劝退。
-- 费用档位折算旧版金币与强化石商店价值，避免移除材料后成本骤降。
local ENHANCE_RULES = {
    { maxLevel = 3,  gold = 300,  successRate = 1.0 },
    { maxLevel = 6,  gold = 750,  successRate = 0.9 },
    { maxLevel = 9,  gold = 2000, successRate = 0.7 },
    { maxLevel = 12, gold = 5000, successRate = 0.5 },
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

local function GetEnhanceRule(level)
    level = Integer(level)
    if level < 1 or level > 12 then return nil end
    for _, rule in ipairs(ENHANCE_RULES) do
        if level <= rule.maxLevel then return rule end
    end
    return nil
end

local function GoldSpentForLevel(level)
    local gold = 0
    for targetLevel = 1, level do
        local rule = GetEnhanceRule(targetLevel)
        gold = gold + (rule and rule.gold or 0)
    end
    return gold
end

local function EnhancementBonus(baseStat, rate, level)
    baseStat = NonNegativeInteger(baseStat)
    if baseStat == 0 or level == 0 then return 0 end
    return math.max(1, math.floor(baseStat * rate * level))
end

--- Return the gold gained by recycling an equipment item.
---@param item table
---@return { gold: number, enhanceRefund: number }
function Enhance.Recycle(item)
    local rarity = type(item) == "table" and RARITY[item.rarity] or nil
    if not rarity then
        return { gold = 0, enhanceRefund = 0 }
    end

    local enhanceLevel = math.min(12, NonNegativeInteger(item.enhance))
    local enhanceRefund = math.floor(
        GoldSpentForLevel(enhanceLevel) * Enhance.ENHANCE_RECYCLE_REFUND_RATE)

    return {
        gold = math.floor(ItemScore(item) * rarity.mult * Enhance.RECYCLE_GOLD_MULTIPLIER)
            + enhanceRefund,
        enhanceRefund = enhanceRefund,
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

--- Return the next rarity in the forge chain, or nil when already capped.
---@param sourceRarityKey string
---@return string|nil
function Enhance.GetNextRarity(sourceRarityKey)
    local rarity = RARITY[sourceRarityKey]
    return rarity and rarity.next or nil
end

--- Validate forge materials and determine their next rarity.
---@param items table[]
---@return { ok: boolean, reason: string, targetRarity: string|nil }
function Enhance.ForgePick(items)
    if type(items) ~= "table" or #items ~= Enhance.FORGE_MATERIAL_COUNT then
        return {
            ok = false,
            reason = "需要" .. Enhance.FORGE_MATERIAL_COUNT .. "件装备",
            targetRarity = nil,
        }
    end

    local first = items[1]
    if type(first) ~= "table" or not RARITY[first.rarity] then
        return { ok = false, reason = "装备品质无效", targetRarity = nil }
    end

    local itemType = first.itemType or first.slot
    if not itemType then
        return { ok = false, reason = "装备部位无效", targetRarity = nil }
    end
    local classReq = first.classReq

    for index = 2, Enhance.FORGE_MATERIAL_COUNT do
        local item = items[index]
        if type(item) ~= "table" or not RARITY[item.rarity] then
            return { ok = false, reason = "装备品质无效", targetRarity = nil }
        end
        if item.rarity ~= first.rarity then
            return { ok = false, reason = "装备品质必须相同", targetRarity = nil }
        end
        if (item.itemType or item.slot) ~= itemType then
            return { ok = false, reason = "装备部位必须相同", targetRarity = nil }
        end
        if item.classReq ~= classReq then
            local reason = itemType == "weapon"
                and "不同职业武器不能混合锻造"
                or "装备职业要求必须相同"
            return { ok = false, reason = reason, targetRarity = nil }
        end
    end

    local targetRarity = Enhance.GetNextRarity(first.rarity)
    if not targetRarity then
        return { ok = false, reason = "品质已封顶", targetRarity = nil }
    end

    return { ok = true, reason = "", targetRarity = targetRarity }
end

--- Return the gold cost and success rate for reaching level 1 through 12.
--- 失败不掉级：只需要金币与成功率，用于 UI 点击前如实说明花费与风险。
---@param level number
---@return { gold: number, successRate: number }
function Enhance.EnhanceCost(level)
    level = Integer(level)
    local rule = GetEnhanceRule(level)
    if not rule then
        return { gold = 0, successRate = 0 }
    end

    return {
        gold = rule.gold,
        successRate = rule.successRate,
    }
end

--- Return cumulative gold spent to reach an enhancement level.
---@param level number
---@return number
function Enhance.GetEnhanceGoldSpent(level)
    return GoldSpentForLevel(math.min(12, NonNegativeInteger(level)))
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
        atk = EnhancementBonus(item.atk, 0.07, level),
        def = EnhancementBonus(item.def, 0.06, level),
        hp = EnhancementBonus(item.hp, 0.04, level),
    }
end

return Enhance
