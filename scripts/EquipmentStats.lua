-- ============================================================================
-- EquipmentStats.lua — 装备实际属性与评分
-- ============================================================================

local Enhance = require("scripts.Enhance")

local EquipmentStats = {}
local MAX_SCORE = 1000000000

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function ClampEnhance(value)
    local number = tonumber(value)
    if not IsFiniteNumber(number) then return 0 end
    return math.max(0, math.min(12, math.floor(number)))
end

---@param item table|nil
---@return table|nil
function EquipmentStats.Get(item)
    if type(item) ~= "table" then return nil end
    local atk, def, hp = tonumber(item.atk), tonumber(item.def), tonumber(item.hp)
    if not IsFiniteNumber(atk) or not IsFiniteNumber(def) or not IsFiniteNumber(hp)
        or atk < 0 or def < 0 or hp < 0 then
        return nil
    end

    local enhanceLevel = ClampEnhance(item.enhance)
    local bonus = Enhance.ApplyEnhanceStats(item, enhanceLevel)
    return {
        atk = atk + bonus.atk,
        def = def + bonus.def,
        hp = hp + bonus.hp,
        baseAtk = atk,
        baseDef = def,
        baseHP = hp,
        bonusAtk = bonus.atk,
        bonusDef = bonus.def,
        bonusHP = bonus.hp,
        enhance = enhanceLevel,
    }
end

---@param item table|nil
---@return number
function EquipmentStats.Score(item)
    local stats = EquipmentStats.Get(item)
    if not stats then return -1 end
    local score = stats.atk * 2 + stats.def * 1.5 + stats.hp * 0.3
    if not IsFiniteNumber(score) then return -1 end
    return math.min(MAX_SCORE, score)
end

return EquipmentStats
