-- ============================================================================
-- Inventory.lua — 掉落 / 装备 / 背包 / 金币系统
-- 支持地面拾取: RollDrop 只生成掉落物，不自动添加
-- ============================================================================

local Inventory = {}
local MAX_RESOURCE = 1000000000

-- 经济平衡参数：集中管理商店买卖价，避免掉落装备成为稳定套利来源。
-- 买入价上调、卖出价下调后，装备的主要价值回到“提升战力”，而不是刷怪卖钱。
Inventory.ECONOMY = {
    itemBuyMultiplier = 12,
    itemSellMultiplier = 1.5,
    enhanceSellRefundPerLevel = 25,
    -- 怪物表中的金币是章节基准值，统一折算后再落地，避免
    -- 高密度刷怪把后期金币产出拉得过快。装备价格不受此倍率影响。
    goldDropMultiplier = 0.80,
    -- 主线奖励仍是阶段性补给，但不再一次性覆盖多次强化/购买成本。
    questGoldMultiplier = 0.75,
    -- 死亡只损失当前持有金币的一小部分；经验、装备与任务进度不受影响。
    deathGoldLossRatio = 0.10,
}

-- 旧存档中的强化石按原商店价折算为金币，并在成功载入后立即写回新存档。
-- 新系统不再创建、购买或消耗强化石。
Inventory.LEGACY_ENHANCE_STONE_REFUND = 120

-- 分支模块（武器链 / 怪物数据 / 强化规则）
local WeaponData = require("WeaponData")
local MonsterData = require("MonsterData")
local Enhance = require("Enhance")
local EquipmentStats = require("EquipmentStats")

Inventory.Enhance = Enhance  -- 暴露强化/分解/锻造纯逻辑，供 UI 调用
Inventory.MonsterData = MonsterData

-- ============================================================================
-- 装备槽位（传奇风格: 头盔/盔甲/武器/项链/手镯×2/戒指×2/腰带/鞋子）
-- ============================================================================
local SLOT = {
    HELMET    = "helmet",
    ARMOR     = "armor",
    WEAPON    = "weapon",
    NECKLACE  = "necklace",
    BRACELET1 = "bracelet1",  -- 左手镯
    BRACELET2 = "bracelet2",  -- 右手镯
    RING1     = "ring1",      -- 左戒指
    RING2     = "ring2",      -- 右戒指
    BELT      = "belt",
    BOOTS     = "boots",
}
-- 槽位显示名称
local SLOT_NAMES = {
    helmet    = "头盔",
    armor     = "盔甲",
    weapon    = "武器",
    necklace  = "项链",
    bracelet1 = "左手镯",
    bracelet2 = "右手镯",
    ring1     = "左戒指",
    ring2     = "右戒指",
    belt      = "腰带",
    boots     = "鞋子",
}
-- 物品类型到可装备的槽位映射（手镯和戒指各有2个槽位）
local TYPE_TO_SLOTS = {
    helmet   = { "helmet" },
    armor    = { "armor" },
    weapon   = { "weapon" },
    necklace = { "necklace" },
    bracelet = { "bracelet1", "bracelet2" },
    ring     = { "ring1", "ring2" },
    belt     = { "belt" },
    boots    = { "boots" },
}
Inventory.SLOT = SLOT
Inventory.SLOT_NAMES = SLOT_NAMES
Inventory.TYPE_TO_SLOTS = TYPE_TO_SLOTS

-- ============================================================================
-- 品质定义 (颜色 RGBA)
-- ============================================================================
local RARITY = {
    COMMON    = { name = "普通", color = {200, 200, 200, 255}, mult = 1.0 },
    UNCOMMON  = { name = "优秀", color = {100, 220, 100, 255}, mult = 1.3 },
    RARE      = { name = "稀有", color = {80, 150, 255, 255},  mult = 1.6 },
    EPIC      = { name = "史诗", color = {180, 80, 255, 255},  mult = 2.0 },
    LEGENDARY = { name = "传说", color = {255, 165, 0, 255},   mult = 2.5 },
}
Inventory.RARITY = RARITY

local ITEM_TYPE_NAMES = {
    helmet = "头盔",
    armor = "盔甲",
    weapon = "武器",
    necklace = "项链",
    bracelet = "手镯",
    ring = "戒指",
    belt = "腰带",
    boots = "鞋子",
}
local ITEM_TYPE_SORT_ORDER = {
    weapon = 1,
    armor = 2,
    helmet = 3,
    necklace = 4,
    bracelet = 5,
    ring = 6,
    belt = 7,
    boots = 8,
}
local RARITY_SORT_ORDER = {
    COMMON = 1,
    UNCOMMON = 2,
    RARE = 3,
    EPIC = 4,
    LEGENDARY = 5,
}
Inventory.ITEM_TYPE_NAMES = ITEM_TYPE_NAMES

-- ============================================================================
-- 物品模板表
-- ============================================================================
local ITEM_TEMPLATES = {
    -- 武器由 WeaponData.WEAPONS 在下方循环插入（单一数据源，避免重复维护）
    -- 头盔
    { id = "helm_iron",     name = "铁盔",     slot = SLOT.HELMET,   itemType = "helmet", rarity = "COMMON",    atk = 0,  def = 3,  hp = 15  },
    { id = "helm_bronze",   name = "青铜盔",   slot = SLOT.HELMET,   itemType = "helmet", rarity = "UNCOMMON",  atk = 0,  def = 6,  hp = 30  },
    { id = "helm_golden",   name = "黄金头盔", slot = SLOT.HELMET,   itemType = "helmet", rarity = "RARE",      atk = 2,  def = 12, hp = 50  },
    { id = "helm_dragon",   name = "龙角盔",   slot = SLOT.HELMET,   itemType = "helmet", rarity = "EPIC",      atk = 5,  def = 20, hp = 100 },
    { id = "helm_heaven",   name = "天冠",     slot = SLOT.HELMET,   itemType = "helmet", rarity = "LEGENDARY", atk = 8,  def = 28, hp = 150 },
    -- 盔甲
    { id = "armor_cloth",   name = "布甲",     slot = SLOT.ARMOR,    itemType = "armor", rarity = "COMMON",    atk = 0,  def = 5,  hp = 20  },
    { id = "armor_leather", name = "皮甲",     slot = SLOT.ARMOR,    itemType = "armor", rarity = "UNCOMMON",  atk = 0,  def = 10, hp = 40  },
    { id = "armor_chain",   name = "锁子甲",   slot = SLOT.ARMOR,    itemType = "armor", rarity = "RARE",      atk = 0,  def = 18, hp = 80  },
    { id = "armor_dragon",  name = "龙鳞甲",   slot = SLOT.ARMOR,    itemType = "armor", rarity = "EPIC",      atk = 5,  def = 30, hp = 150 },
    { id = "armor_heaven",  name = "天衣",     slot = SLOT.ARMOR,    itemType = "armor", rarity = "LEGENDARY", atk = 10, def = 40, hp = 250 },
    -- 项链
    { id = "neck_bone",     name = "骨链",     slot = SLOT.NECKLACE, itemType = "necklace", rarity = "COMMON",    atk = 2,  def = 2, hp = 15  },
    { id = "neck_jade",     name = "玉佩",     slot = SLOT.NECKLACE, itemType = "necklace", rarity = "UNCOMMON",  atk = 4,  def = 4, hp = 30  },
    { id = "neck_amber",    name = "琥珀坠",   slot = SLOT.NECKLACE, itemType = "necklace", rarity = "RARE",      atk = 8,  def = 6, hp = 50  },
    { id = "neck_dragon",   name = "龙牙链",   slot = SLOT.NECKLACE, itemType = "necklace", rarity = "EPIC",      atk = 15, def = 10, hp = 80 },
    -- 手镯（可装2个）
    { id = "brace_iron",    name = "铁手镯",   slot = SLOT.BRACELET1, itemType = "bracelet", rarity = "COMMON",    atk = 2,  def = 2, hp = 10  },
    { id = "brace_silver",  name = "银手镯",   slot = SLOT.BRACELET1, itemType = "bracelet", rarity = "UNCOMMON",  atk = 5,  def = 3, hp = 20  },
    { id = "brace_gold",    name = "金手镯",   slot = SLOT.BRACELET1, itemType = "bracelet", rarity = "RARE",      atk = 9,  def = 5, hp = 35  },
    { id = "brace_dragon",  name = "降龙手镯", slot = SLOT.BRACELET1, itemType = "bracelet", rarity = "EPIC",      atk = 16, def = 8, hp = 60  },
    -- 戒指（可装2个）
    { id = "ring_copper",   name = "铜戒",     slot = SLOT.RING1,    itemType = "ring", rarity = "COMMON",    atk = 3,  def = 1, hp = 0  },
    { id = "ring_silver",   name = "银戒",     slot = SLOT.RING1,    itemType = "ring", rarity = "UNCOMMON",  atk = 6,  def = 2, hp = 10 },
    { id = "ring_gold",     name = "金戒",     slot = SLOT.RING1,    itemType = "ring", rarity = "RARE",      atk = 10, def = 4, hp = 25 },
    { id = "ring_dragon",   name = "龙纹戒",   slot = SLOT.RING1,    itemType = "ring", rarity = "EPIC",      atk = 18, def = 6, hp = 50 },
    -- 腰带
    { id = "belt_cloth",    name = "布带",     slot = SLOT.BELT,     itemType = "belt", rarity = "COMMON",    atk = 0,  def = 2,  hp = 20  },
    { id = "belt_leather",  name = "皮带",     slot = SLOT.BELT,     itemType = "belt", rarity = "UNCOMMON",  atk = 0,  def = 4,  hp = 35  },
    { id = "belt_chain",    name = "锁链腰带", slot = SLOT.BELT,     itemType = "belt", rarity = "RARE",      atk = 2,  def = 8,  hp = 55  },
    { id = "belt_dragon",   name = "蟠龙腰带", slot = SLOT.BELT,     itemType = "belt", rarity = "EPIC",      atk = 5,  def = 14, hp = 90  },
    -- 鞋子
    { id = "boots_cloth",   name = "布鞋",     slot = SLOT.BOOTS,    itemType = "boots", rarity = "COMMON",    atk = 0,  def = 2,  hp = 10  },
    { id = "boots_leather", name = "皮靴",     slot = SLOT.BOOTS,    itemType = "boots", rarity = "UNCOMMON",  atk = 0,  def = 5,  hp = 25  },
    { id = "boots_iron",    name = "铁靴",     slot = SLOT.BOOTS,    itemType = "boots", rarity = "RARE",      atk = 0,  def = 10, hp = 40  },
    { id = "boots_dragon",  name = "龙鳞靴",   slot = SLOT.BOOTS,    itemType = "boots", rarity = "EPIC",      atk = 3,  def = 16, hp = 70  },
    { id = "boots_wind",    name = "疾风靴",   slot = SLOT.BOOTS,    itemType = "boots", rarity = "LEGENDARY", atk = 5,  def = 20, hp = 100 },
}

-- 插入三职业传奇武器链（单一数据源 WeaponData.WEAPONS）
for _, weapon in ipairs(WeaponData.WEAPONS) do
    table.insert(ITEM_TEMPLATES, weapon)
end

local ITEM_BY_ID = {}
for _, tmpl in ipairs(ITEM_TEMPLATES) do
    ITEM_BY_ID[tmpl.id] = tmpl
end

-- ============================================================================
-- 物品模板/存档边界
-- ============================================================================
-- 存档中的装备属性不是可信数据：旧版本允许直接把 JSON table 放入背包，
-- 这会让改过的 atk/def/hp、slot 或 classReq 穿透到运行时。所有从存档恢复
-- 的实例都必须以本地模板为唯一数据源，只保留可控的强化等级。
local function CloneItemTemplate(template)
    if not template then return nil end
    local item = {}
    for key, value in pairs(template) do
        item[key] = value
    end
    item.enhance = 0
    return item
end

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

local function ClampInteger(value, minValue, maxValue, fallback)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return fallback
    end
    -- 先限制到可接受区间再 floor，避免极大浮点数在 Lua 5.4 中触发
    -- "number has no integer representation"。
    number = math.max(minValue, math.min(maxValue, number))
    return math.floor(number)
end

-- 经济倍率只允许在 0~1 之间，且对异常配置回退到 1，避免 NaN/Inf
-- 进入 math.floor 后让掉落回调中断。
local function NormalizeGoldMultiplier(value)
    local multiplier = tonumber(value)
    if not IsFiniteNumber(multiplier) then return 1.0 end
    return math.max(0, math.min(1.0, multiplier))
end

local function ScaleGoldAmount(amount, multiplier, minimum)
    local raw = tonumber(amount)
    if not IsFiniteNumber(raw) or raw <= 0 then return 0 end
    raw = math.min(MAX_RESOURCE, raw)

    local scaled = raw * NormalizeGoldMultiplier(multiplier)
    if not IsFiniteNumber(scaled) then return MAX_RESOURCE end
    scaled = math.floor(scaled + 0.5)
    if minimum and scaled < minimum then scaled = minimum end
    return math.min(MAX_RESOURCE, math.max(0, scaled))
end

local function IsCanonicalItem(item, playerClassId)
    if type(item) ~= "table" or type(item.id) ~= "string" then return false end
    local template = ITEM_BY_ID[item.id]
    if not template then return false end
    if template.classReq and playerClassId and template.classReq ~= playerClassId then
        return false
    end
    local fields = { "name", "slot", "itemType", "rarity", "atk", "def", "hp", "classReq" }
    for _, key in ipairs(fields) do
        if item[key] ~= template[key] then return false end
    end
    return type(item.enhance) == "number"
        and IsFiniteNumber(item.enhance)
        and item.enhance % 1 == 0
        and item.enhance >= 0
        and item.enhance <= 12
end

local CLASS_IDS = {
    warrior = true,
    mage = true,
    taoist = true,
}

local function IsKnownClassId(playerClassId)
    return type(playerClassId) == "string" and CLASS_IDS[playerClassId] == true
end

Inventory.IsKnownClassId = IsKnownClassId

--- 判断装备是否适用于当前职业。
---
--- classReq=nil 表示职业通用装备（例如屠龙）；带职业要求的装备只有
--- 在要求与当前职业一致时才允许进入该职业的掉落池。playerClassId=nil
--- 时保留旧接口语义，不做职业过滤，供编辑器/离线工具查看完整模板。
---@param item table|nil
---@param playerClassId string|nil
---@return boolean
local function IsItemCompatibleWithClass(item, playerClassId)
    if type(item) ~= "table" then return false end
    if playerClassId == nil then return true end
    -- 运行时职业上下文异常时必须 fail closed，不能因为 classReq=nil
    -- 而把未知职业误当成“全职业”放行。
    if not IsKnownClassId(playerClassId) then return false end
    return item.classReq == nil or item.classReq == playerClassId
end

Inventory.IsItemCompatibleWithClass = IsItemCompatibleWithClass

local function GetItemType(item)
    if type(item) ~= "table" then return nil end
    return item.itemType or item.slot
end

-- 查找合法的锻造产物模板。职业专属装备优先保持同职业；只有没有同职业
-- 目标时才允许落到无职业限制的通用模板，绝不随机到其它职业。
local function FindForgeTargetTemplates(itemType, targetRarity, classReq)
    local exactClass = {}
    local universal = {}
    for _, template in ipairs(ITEM_TEMPLATES) do
        if GetItemType(template) == itemType and template.rarity == targetRarity then
            if classReq ~= nil then
                if template.classReq == classReq then
                    table.insert(exactClass, template)
                elseif template.classReq == nil then
                    table.insert(universal, template)
                end
            elseif template.classReq == nil then
                table.insert(universal, template)
            end
        end
    end
    if #exactClass > 0 then return exactClass end
    return universal
end

local function ForgeMaterialScore(item)
    return (tonumber(item.atk) or 0) * 2
        + (tonumber(item.def) or 0) * 1.5
        + (tonumber(item.hp) or 0) * 0.3
end

local function SortForgeEntries(a, b)
    local enhanceA = ClampInteger(a.item.enhance, 0, 12, 0)
    local enhanceB = ClampInteger(b.item.enhance, 0, 12, 0)
    if enhanceA ~= enhanceB then return enhanceA < enhanceB end

    local scoreA = ForgeMaterialScore(a.item)
    local scoreB = ForgeMaterialScore(b.item)
    if scoreA ~= scoreB then return scoreA < scoreB end

    local idA = tostring(a.item.id or "")
    local idB = tostring(b.item.id or "")
    if idA ~= idB then return idA < idB end
    return a.bagIndex < b.bagIndex
end

--- 获取装备类型显示名。
---@param itemType string
---@return string
function Inventory.GetItemTypeName(itemType)
    return ITEM_TYPE_NAMES[itemType] or "装备"
end

--- 获取只读物品模板（供存档校验/商人等边界使用）。
---@param itemId string
---@return table|nil
function Inventory.GetItemTemplate(itemId)
    if type(itemId) ~= "string" then return nil end
    return ITEM_BY_ID[itemId]
end

--- 获取当前职业可见的装备模板。
---
--- 掉落、商店和其它按职业生成货架的入口统一复用这条规则，避免某个
--- 新入口只筛掉落表、却把其它职业武器重新展示或售出。
---@param playerClassId string|nil nil 仅用于编辑器/离线查看全部模板
---@return table[]
function Inventory.GetCompatibleItemTemplates(playerClassId)
    if playerClassId ~= nil and not IsKnownClassId(playerClassId) then
        return {}
    end

    local result = {}
    for _, template in ipairs(ITEM_TEMPLATES) do
        if IsItemCompatibleWithClass(template, playerClassId) then
            result[#result + 1] = CloneItemTemplate(template)
        end
    end
    return result
end

--- 根据模板创建一个新的运行时物品实例。
---@param itemId string
---@param enhance number|nil
---@return table|nil
function Inventory.CreateItem(itemId, enhance)
    local template = Inventory.GetItemTemplate(itemId)
    if not template then return nil end
    local item = CloneItemTemplate(template)
    item.enhance = ClampInteger(enhance, 0, 12, 0)
    return item
end

--- 将外部/存档物品重建为合法实例。
--- 只接受已知模板 ID；名称、属性、部位、职业要求均以模板覆盖。
---@param savedItem table
---@param expectedSlot string|nil 装备栏恢复时的目标槽位
---@param playerClassId string|nil 当前角色职业
---@return table|nil, string|nil
function Inventory.CreateItemFromSave(savedItem, expectedSlot, playerClassId)
    if type(savedItem) ~= "table" or type(savedItem.id) ~= "string" then
        return nil, "物品数据无效"
    end

    if playerClassId ~= nil and not IsKnownClassId(playerClassId) then
        return nil, "职业无效"
    end

    local template = Inventory.GetItemTemplate(savedItem.id)
    if not template then
        return nil, "未知物品"
    end

    if expectedSlot ~= nil then
        if type(expectedSlot) ~= "string" or not SLOT_NAMES[expectedSlot] then
            return nil, "装备槽位无效"
        end
        local templateType = template.itemType or template.slot
        local validSlots = TYPE_TO_SLOTS[templateType]
        local slotAllowed = false
        if validSlots then
            for _, slotKey in ipairs(validSlots) do
                if slotKey == expectedSlot then
                    slotAllowed = true
                    break
                end
            end
        elseif template.slot == expectedSlot then
            slotAllowed = true
        end
        if not slotAllowed then
            return nil, "物品与装备槽位不匹配"
        end
    end

    if not IsItemCompatibleWithClass(template, playerClassId) then
        return nil, "职业不匹配"
    end

    local item = CloneItemTemplate(template)
    item.enhance = ClampInteger(savedItem.enhance, 0, 12, 0)
    return item
end

--- 判断值是否为有限数（供需要严格拒绝 NaN/Inf 的调用方）。
---@param value any
---@return boolean
function Inventory.IsFiniteNumber(value)
    return IsFiniteNumber(value)
end

-- ============================================================================
-- 敌人掉落表
-- ============================================================================
local DROP_TABLES = {
    ["鹿"] = {
        goldMin = 3, goldMax = 9, dropChance = 0.18,
        items = {
            { id = "sword_iron",    weight = 25 },
            { id = "armor_cloth",   weight = 20 },
            { id = "ring_copper",   weight = 15 },
            { id = "neck_bone",     weight = 15 },
            { id = "bell_copper",   weight = 12 },
            { id = "staff_wood",    weight = 12 },
            { id = "helm_iron",     weight = 15 },
            { id = "brace_iron",    weight = 15 },
            { id = "belt_cloth",    weight = 15 },
            { id = "boots_cloth",   weight = 15 },
        },
    },
    ["稻草人"] = {
        goldMin = 5, goldMax = 13, dropChance = 0.20,
        items = {
            { id = "armor_cloth",   weight = 15 },
            { id = "armor_leather", weight = 8  },
            { id = "ring_copper",   weight = 15 },
            { id = "neck_bone",     weight = 12 },
            { id = "ring_silver",   weight = 5  },
            { id = "helm_iron",     weight = 12 },
            { id = "helm_bronze",   weight = 5  },
            { id = "brace_iron",    weight = 12 },
            { id = "belt_cloth",    weight = 12 },
            { id = "belt_leather",  weight = 5  },
            { id = "boots_cloth",   weight = 12 },
            { id = "boots_leather", weight = 5  },
        },
    },
    ["幽灵"] = {
        goldMin = 6, goldMax = 16, dropChance = 0.20,
        items = {
            { id = "sword_iron",    weight = 18 },
            { id = "armor_leather", weight = 12 },
            { id = "ring_copper",   weight = 12 },
            { id = "neck_bone",     weight = 16 },
            { id = "staff_wood",    weight = 10 },
            { id = "bell_copper",   weight = 10 },
            { id = "helm_iron",     weight = 10 },
            { id = "brace_iron",    weight = 10 },
            { id = "belt_leather",  weight = 6  },
            { id = "boots_leather", weight = 6  },
        },
    },
    ["骷髅"] = {
        goldMin = 10, goldMax = 23, dropChance = 0.22,
        items = {
            { id = "sword_steel",   weight = 12 },
            { id = "staff_crystal", weight = 12 },
            { id = "bell_jade",     weight = 12 },
            { id = "armor_leather", weight = 14 },
            { id = "ring_silver",   weight = 10 },
            { id = "neck_jade",     weight = 10 },
            { id = "sword_flame",   weight = 3  },
            { id = "helm_bronze",   weight = 10 },
            { id = "brace_silver",  weight = 10 },
            { id = "belt_leather",  weight = 10 },
            { id = "boots_leather", weight = 10 },
        },
    },
    ["毒蜘蛛"] = {
        goldMin = 13, goldMax = 29, dropChance = 0.25,
        items = {
            { id = "armor_leather", weight = 12 },
            { id = "armor_chain",   weight = 6  },
            { id = "ring_silver",   weight = 12 },
            { id = "neck_jade",     weight = 10 },
            { id = "ring_gold",     weight = 4  },
            { id = "neck_amber",    weight = 4  },
            { id = "helm_bronze",   weight = 8  },
            { id = "helm_golden",   weight = 3  },
            { id = "brace_silver",  weight = 8  },
            { id = "brace_gold",    weight = 3  },
            { id = "belt_leather",  weight = 8  },
            { id = "belt_chain",    weight = 3  },
            { id = "boots_leather", weight = 8  },
            { id = "boots_iron",    weight = 3  },
        },
    },
    ["半兽人"] = {
        goldMin = 20, goldMax = 45, dropChance = 0.28,
        items = {
            { id = "sword_flame",   weight = 10 },
            { id = "staff_thunder", weight = 10 },
            { id = "bell_soul",     weight = 10 },
            { id = "armor_chain",   weight = 12 },
            { id = "ring_gold",     weight = 8  },
            { id = "neck_amber",    weight = 8  },
            { id = "helm_golden",   weight = 8  },
            { id = "brace_gold",    weight = 8  },
            { id = "belt_chain",    weight = 8  },
            { id = "boots_iron",    weight = 8  },
            { id = "sword_dragon",  weight = 2  },
            { id = "staff_arcane",  weight = 2  },
            { id = "bell_holy",     weight = 2  },
            { id = "armor_dragon",  weight = 2  },
            { id = "ring_dragon",   weight = 2  },
            { id = "neck_dragon",   weight = 2  },
            { id = "helm_dragon",   weight = 2  },
            { id = "brace_dragon",  weight = 2  },
            { id = "belt_dragon",   weight = 2  },
            { id = "boots_dragon",  weight = 2  },
            { id = "armor_heaven",  weight = 1  },
            { id = "helm_heaven",   weight = 1  },
            { id = "boots_wind",    weight = 1  },
        },
    },
}

-- 合并分支怪物掉落表（经典名 key）
for k, v in pairs(MonsterData.DROP_TABLES) do
    DROP_TABLES[k] = v
end

-- ============================================================================
-- 玩家背包状态
-- ============================================================================
local MAX_BAG_SLOTS = 50

local playerData = {
    gold = 0,
    equipped = {
        [SLOT.HELMET]    = nil,
        [SLOT.ARMOR]     = nil,
        [SLOT.WEAPON]    = nil,
        [SLOT.NECKLACE]  = nil,
        [SLOT.BRACELET1] = nil,
        [SLOT.BRACELET2] = nil,
        [SLOT.RING1]     = nil,
        [SLOT.RING2]     = nil,
        [SLOT.BELT]      = nil,
        [SLOT.BOOTS]     = nil,
    },
    bag = {},
    bonusAtk = 0,
    bonusDef = 0,
    bonusHP  = 0,
    protectStones = 0,  -- 保护石数量（强化失败不掉级）
}

Inventory.playerData = playerData

-- ============================================================================
-- 药水配置
-- ============================================================================
Inventory.POTION_BUY_PRICE = 100
Inventory.POTION_CONFIG = {
    hp = { max = 10, price = Inventory.POTION_BUY_PRICE, healRatio = 0.30, dropChance = 0.12, label = "血药" },
    mp = { max = 8,  price = Inventory.POTION_BUY_PRICE, healRatio = 0.40, dropChance = 0.08, label = "蓝药" },
}

local function EnsurePotions()
    if type(playerData.potions) ~= "table" then
        playerData.potions = { hp = 5, mp = 3 }
    end
    playerData.potions.hp = ClampInteger(
        playerData.potions.hp, 0, Inventory.POTION_CONFIG.hp.max, 0)
    playerData.potions.mp = ClampInteger(
        playerData.potions.mp, 0, Inventory.POTION_CONFIG.mp.max, 0)
    return playerData.potions
end

-- ============================================================================
-- 初始化
-- ============================================================================
function Inventory.Init()
    playerData.gold = 0
    playerData.equipped = {
        [SLOT.HELMET]    = nil,
        [SLOT.ARMOR]     = nil,
        [SLOT.WEAPON]    = nil,
        [SLOT.NECKLACE]  = nil,
        [SLOT.BRACELET1] = nil,
        [SLOT.BRACELET2] = nil,
        [SLOT.RING1]     = nil,
        [SLOT.RING2]     = nil,
        [SLOT.BELT]      = nil,
        [SLOT.BOOTS]     = nil,
    }
    playerData.bag = {}
    playerData.bonusAtk = 0
    playerData.bonusDef = 0
    playerData.bonusHP  = 0
    playerData.protectStones = 0
    ---@type table<string, number>
    playerData.potions = { hp = 5, mp = 3 }
    print("[Inventory] Initialized")
end

-- ============================================================================
-- 药水系统
-- ============================================================================

--- 使用药水，返回 true 表示成功
---@param kind "hp"|"mp"
---@return boolean
function Inventory.UsePotion(kind)
    local potions = EnsurePotions()
    if not Inventory.POTION_CONFIG[kind] or potions[kind] <= 0 then return false end
    potions[kind] = potions[kind] - 1
    return true
end

--- 获取药水数量
---@param kind "hp"|"mp"
---@return number
function Inventory.GetPotionCount(kind)
    local potions = EnsurePotions()
    return potions[kind] or 0
end

--- 商人出售药水：扣除金币并增加一瓶。只允许商人交互流程调用，
--- 背包和 HUD 不提供购买入口。
---@param kind "hp"|"mp"
---@return boolean, string
function Inventory.BuyPotionFromMerchant(kind)
    local cfg = Inventory.POTION_CONFIG[kind]
    if not cfg then return false, "无效类型" end
    local potions = EnsurePotions()
    if potions[kind] >= cfg.max then return false, "已满" end
    if not Inventory.SpendGold(cfg.price) then return false, "金币不足" end
    potions[kind] = potions[kind] + 1
    return true, ""
end

--- 击杀掉落药水判定（在 RollDrop 之后额外调用）
function Inventory.RollPotionDrop()
    local potions = EnsurePotions()
    local dropped = {}
    for kind, cfg in pairs(Inventory.POTION_CONFIG) do
        if math.random() < cfg.dropChance and potions[kind] < cfg.max then
            potions[kind] = potions[kind] + 1
            table.insert(dropped, cfg.label)
        end
    end
    return dropped
end

--- 获取装备当前实际属性（基础属性 + 强化加成）。
---@param item table|nil
---@return table|nil
function Inventory.GetItemStats(item)
    return EquipmentStats.Get(item)
end

local function ItemScore(item)
    return EquipmentStats.Score(item)
end

-- 前向声明：装备、分解、强化都需要验证实例仍归属于当前角色。
local FindOwnedItem

-- ============================================================================
-- 重新计算装备加成
-- ============================================================================
function Inventory.RecalcBonus()
    local atk, def, hp = 0, 0, 0
    for _, item in pairs(playerData.equipped) do
        if item and IsCanonicalItem(item, nil) then
            local stats = EquipmentStats.Get(item)
            if stats then
                atk = atk + stats.atk
                def = def + stats.def
                hp = hp + stats.hp
            end
        end
    end
    playerData.bonusAtk = atk
    playerData.bonusDef = def
    playerData.bonusHP  = hp
end

-- ============================================================================
-- 为物品找到最佳装备槽位（处理双槽位逻辑）
-- ============================================================================
local function FindBestSlot(item)
    local itemType = item.itemType
    if not itemType then return item.slot end  -- 兼容旧数据

    local slots = TYPE_TO_SLOTS[itemType]
    if not slots then return item.slot end

    -- 单槽位类型，直接返回
    if #slots == 1 then return slots[1] end

    -- 双槽位类型（手镯/戒指）：优先空槽，否则替换评分低的
    local emptySlot = nil
    local worstSlot = nil
    local worstScore = math.huge
    for _, s in ipairs(slots) do
        local current = playerData.equipped[s]
        if not current then
            emptySlot = s
            break
        else
            local score = ItemScore(current)
            if score < worstScore then
                worstScore = score
                worstSlot = s
            end
        end
    end
    return emptySlot or worstSlot
end

--- 获取背包装备默认要穿戴/替换的槽位。双手镯、双戒指优先空槽，
--- 都已占用时选择强化后实际属性较低的一件。
---@param item table|nil
---@return string|nil
function Inventory.GetSuggestedEquipSlot(item)
    if not IsCanonicalItem(item, nil) then return nil end
    return FindBestSlot(item)
end

-- ============================================================================
-- 装备物品到指定槽位（可指定 targetSlot，不指定则自动选择）
-- ============================================================================
function Inventory.EquipItem(item, playerClassId, targetSlot)
    if type(item) ~= "table" then return false, "装备无效", nil end
    if not IsKnownClassId(playerClassId) then
        return false, "装备需要有效职业", nil
    end
    local ownedType, ownedKey = FindOwnedItem(item)
    if ownedType then
        -- 当前角色已经持有的实例必须仍与本地模板一致；异常运行时数据
        -- 不得借装备动作把伪造属性带入加成计算。
        if not IsCanonicalItem(item, nil) then
            return false, "装备数据异常", nil
        end
    else
        -- 地面掉落等尚未入包的实例先按模板重建，只保留合法强化等级。
        local normalized, reason = Inventory.CreateItemFromSave(item, nil, nil)
        if not normalized then return false, reason or "装备数据异常", nil end
        item = normalized
    end

    if item.classReq and playerClassId and item.classReq ~= playerClassId then
        return false, "职业不匹配", nil
    end

    local slot = targetSlot or FindBestSlot(item)
    if not slot then return false, "没有可用装备槽位", nil end
    if item.itemType and not Inventory.CanEquipToSlot(item, slot) then
        return false, "装备与目标槽位不匹配", slot
    end

    if ownedType == "equipped" and ownedKey ~= slot then
        return false, "装备已穿戴，请先卸下", ownedKey
    end
    -- 同一实例已经在目标槽位时是幂等操作。不能继续走交换分支，
    -- 否则 old == item 会把同一个引用再次塞进背包，形成复制装备。
    if ownedType == "equipped" and ownedKey == slot then
        return true, "", slot
    end
    local old = playerData.equipped[slot]

    -- 先定位待装备实例，替换装备时执行原子交换：背包已满也不会
    -- 无声丢弃旧装备；若物品本来就在背包中，则用旧装备占据原槽位。
    local bagIndex = nil
    for i, bagItem in ipairs(playerData.bag) do
        if bagItem == item then
            bagIndex = i
            break
        end
    end
    if old and not bagIndex and #playerData.bag >= MAX_BAG_SLOTS then
        print("[Inventory] Bag full, cannot replace equipped item")
        return false, "背包已满，无法替换装备", slot
    end

    playerData.equipped[slot] = item
    if old then
        if bagIndex then
            playerData.bag[bagIndex] = old
        else
            table.insert(playerData.bag, old)
        end
    elseif bagIndex then
        table.remove(playerData.bag, bagIndex)
    end

    Inventory.RecalcBonus()
    print("[Inventory] Equipped: " .. item.name .. " → " .. (SLOT_NAMES[slot] or slot))
    return true, "", slot
end

-- ============================================================================
-- 尝试自动装备（双槽位：有空槽直接装，否则与最弱的比较）
-- ============================================================================
function Inventory.TryAutoEquip(item, playerClassId)
    if type(item) ~= "table" then return false end
    local ownedType = FindOwnedItem(item)
    if ownedType then
        if not IsCanonicalItem(item, playerClassId) then return false end
    else
        local normalized = Inventory.CreateItemFromSave(item, nil, playerClassId)
        if not normalized then return false end
        item = normalized
    end

    local itemType = item.itemType or "weapon"
    local slots = TYPE_TO_SLOTS[itemType]
    if not slots then return false end

    -- 检查所有可用槽位
    local emptySlot = nil
    local worstSlot = nil
    local worstScore = math.huge
    for _, s in ipairs(slots) do
        local current = playerData.equipped[s]
        if not current then
            emptySlot = s
            break
        else
            local score = ItemScore(current)
            if score < worstScore then
                worstScore = score
                worstSlot = s
            end
        end
    end

    -- 有空槽直接装
    if emptySlot then
        return Inventory.EquipItem(item, playerClassId, emptySlot)
    end

    -- 比最弱的强则替换
    if ItemScore(item) > worstScore then
        return Inventory.EquipItem(item, playerClassId, worstSlot)
    end

    return false
end

-- ============================================================================
-- 添加物品到背包
-- ============================================================================
function Inventory.AddToBag(item)
    if type(item) ~= "table" then return false end
    if FindOwnedItem(item) then return false end
    if #playerData.bag >= MAX_BAG_SLOTS then
        print("[Inventory] Bag full, discarding " .. tostring(item.name or "unknown"))
        return false
    end
    local normalized = Inventory.CreateItemFromSave(item, nil, nil)
    if not normalized then return false end
    table.insert(playerData.bag, normalized)
    return true, normalized
end

-- ============================================================================
-- 添加金币
-- ============================================================================
function Inventory.AddGold(amount)
    if type(amount) ~= "number" or not IsFiniteNumber(amount)
        or amount <= 0 or amount > MAX_RESOURCE or amount % 1 ~= 0 then
        return false
    end
    local current = ClampInteger(playerData.gold, 0, MAX_RESOURCE, 0)
    if current >= MAX_RESOURCE then return false end
    playerData.gold = math.min(MAX_RESOURCE, current + amount)
    return true
end

--- 应用于击杀掉落的金币倍率（普通掉落至少保留 1 金）。
---@param rawGold number
---@return number
function Inventory.GetGoldDropAmount(rawGold)
    return ScaleGoldAmount(rawGold, Inventory.ECONOMY.goldDropMultiplier, 1)
end

--- 应用于主线任务奖励的金币倍率。
---@param rawReward number
---@return number
function Inventory.GetQuestGoldReward(rawReward)
    return ScaleGoldAmount(rawReward, Inventory.ECONOMY.questGoldMultiplier, 0)
end

--- 扣金币，不足返回 false
---@param amount number
---@return boolean
function Inventory.SpendGold(amount)
    if type(amount) ~= "number" or not IsFiniteNumber(amount)
        or amount < 0 or amount > MAX_RESOURCE or amount % 1 ~= 0 then
        return false
    end
    local current = ClampInteger(playerData.gold, 0, MAX_RESOURCE, 0)
    playerData.gold = current
    if current < amount then return false end
    playerData.gold = current - amount
    return true
end

--- 结算角色死亡金币损失。所有数值都在经济模块内归一化，避免宿主直接
--- 修改金币后遗漏异常值边界或与后续经济调参脱节。
---@return table {goldLost:number,goldRemaining:number,lossRatio:number}
function Inventory.ApplyDeathPenalty()
    local current = ClampInteger(playerData.gold, 0, MAX_RESOURCE, 0)
    local ratio = NormalizeGoldMultiplier(Inventory.ECONOMY.deathGoldLossRatio)
    local lost = math.floor(current * ratio)
    playerData.gold = current - lost
    return {
        goldLost = lost,
        goldRemaining = playerData.gold,
        lossRatio = ratio,
    }
end

--- 从商人原子购买一件模板装备。所有校验通过后才同时扣款与入包，
--- 避免“金币已扣但背包写入失败”。价格始终由本地模板计算；职业参数
--- 是必需的，防止未来调用绕过商店货架筛选购买异职业武器。
---@param itemId string
---@param playerClassId string
---@return boolean, string, table|nil, number
function Inventory.BuyItem(itemId, playerClassId)
    local item = Inventory.CreateItem(itemId, 0)
    if not item then return false, "商品不存在", nil, 0 end
    if not IsKnownClassId(playerClassId) then
        return false, "购买装备需要有效职业", nil, 0
    end
    if not IsItemCompatibleWithClass(item, playerClassId) then
        return false, "该装备不适用于当前职业", nil, 0
    end
    if #playerData.bag >= MAX_BAG_SLOTS then
        return false, "背包已满", nil, 0
    end
    local price = Inventory.GetItemPrice(item)
    if price <= 0 then return false, "商品价格异常", nil, 0 end

    local currentGold = ClampInteger(playerData.gold, 0, MAX_RESOURCE, 0)
    playerData.gold = currentGold
    if currentGold < price then
        return false, "金币不足，需要 " .. price .. " 金币", nil, price
    end

    -- 单线程状态下在同一函数内完成两次写入；前面不再有可失败步骤。
    playerData.gold = currentGold - price
    table.insert(playerData.bag, item)
    return true, "", item, price
end

-- ============================================================================
-- 拾取物品（自动装备或放入背包）
-- ============================================================================
function Inventory.PickupItem(item, playerClassId)
    if type(item) ~= "table" then return false, "无物品" end
    -- 地面掉落允许收入其它职业装备，之后可出售、分解或参与锻造；
    -- 只有自动装备阶段才校验当前职业。此前在重建实例时就传入
    -- playerClassId，会让高阶共享掉落池中的异职业武器永远无法拾取。
    local normalized, reason = Inventory.CreateItemFromSave(item, nil, nil)
    if not normalized then return false, reason or "物品数据无效" end
    local canAutoEquip = not normalized.classReq or normalized.classReq == playerClassId
    local equipped = canAutoEquip and Inventory.TryAutoEquip(normalized, playerClassId) or false
    if not equipped then
        local added = Inventory.AddToBag(normalized)
        if not added then
            return false, "背包已满"
        end
    end
    return true, ""
end

-- 查找运行时物品实例的归属。装备/分解/强化必须只接受当前背包或装备栏
-- 中的对象，避免旧 UI 闭包或外部构造的同形 table 直接修改玩家经济状态。
---@param item table|nil
---@return string|nil, number|string|nil locationType/locationKey
FindOwnedItem = function(item)
    if type(item) ~= "table" then return nil, nil end
    for index, bagItem in ipairs(playerData.bag) do
        if bagItem == item then
            return "bag", index
        end
    end
    for slotKey, equippedItem in pairs(playerData.equipped) do
        if equippedItem == item then
            return "equipped", slotKey
        end
    end
    return nil, nil
end

--- 判断物品是否仍在当前玩家的背包或装备栏。
---@param item table|nil
---@return boolean
function Inventory.IsOwnedItem(item)
    local locationType = FindOwnedItem(item)
    return locationType ~= nil
end

-- ============================================================================
-- 掉落判定（只计算掉什么，不添加到背包/金币）
-- ============================================================================
function Inventory.RollDrop(enemyName, playerClassId)
    local dropTable = DROP_TABLES[enemyName]
    if not dropTable then return nil, 0 end
    -- 掉落是运行时经济入口，职业上下文缺失时直接拒绝，避免旧调用
    -- 把完整模板池当成玩家可用掉落池。
    if not IsKnownClassId(playerClassId) then
        print("[Inventory] RollDrop refused: missing or invalid player class")
        return nil, 0
    end

    -- 金币必掉，但按统一经济倍率折算；至少保留 1 金，避免低级怪
    -- 因取整完全没有金币反馈。
    local rawGold = math.random(dropTable.goldMin, dropTable.goldMax)
    local gold = Inventory.GetGoldDropAmount(rawGold)

    -- 物品掉落判定
    local droppedItem = nil
    -- 先过滤当前职业不能使用的装备，再按剩余权重抽样。不能在抽中后才
    -- 丢弃，否则会让玩家看到无效掉落，且不同职业的有效掉落率会被稀释。
    local eligibleEntries = {}
    local totalWeight = 0
    for _, entry in ipairs(dropTable.items or {}) do
        local weight = tonumber(entry.weight)
        local tmpl = ITEM_BY_ID[entry.id]
        if tmpl and IsFiniteNumber(weight) and weight > 0
            and IsItemCompatibleWithClass(tmpl, playerClassId) then
            eligibleEntries[#eligibleEntries + 1] = { template = tmpl, weight = weight }
            totalWeight = totalWeight + weight
        end
    end

    if totalWeight > 0 and math.random() < (tonumber(dropTable.dropChance) or 0) then
        local roll = math.random() * totalWeight
        local acc = 0
        for _, entry in ipairs(eligibleEntries) do
            acc = acc + entry.weight
            if roll <= acc then
                droppedItem = Inventory.CreateItem(entry.template.id, 0)
                break
            end
        end
    end

    return droppedItem, gold
end

-- ============================================================================
-- 保留旧接口兼容（即时处理掉落 — 不再使用）
-- ============================================================================
function Inventory.ProcessDrop(enemyName, playerClassId)
    local item, gold = Inventory.RollDrop(enemyName, playerClassId)
    Inventory.AddGold(gold)
    if item then
        Inventory.PickupItem(item, playerClassId)
    end
    return item, gold
end

-- ============================================================================
-- 获取装备信息字符串
-- ============================================================================
function Inventory.GetEquipSummary()
    local parts = {}
    for slotName, slot in pairs(SLOT) do
        local item = playerData.equipped[slot]
        if item then
            table.insert(parts, slotName .. ": " .. item.name)
        end
    end
    return table.concat(parts, " | ")
end

-- ============================================================================
-- 卸下装备到背包
-- ============================================================================
function Inventory.UnequipSlot(slotKey)
    if not SLOT_NAMES[slotKey] then return false, "装备槽位无效" end
    local item = playerData.equipped[slotKey]
    if not item then return false, "该槽位没有装备" end
    if #playerData.bag >= MAX_BAG_SLOTS then
        print("[Inventory] Bag full, cannot unequip")
        return false, "背包已满"
    end
    table.insert(playerData.bag, item)
    playerData.equipped[slotKey] = nil
    Inventory.RecalcBonus()
    print("[Inventory] Unequipped: " .. item.name .. " from " .. (SLOT_NAMES[slotKey] or slotKey))
    return true, "", item
end

-- ============================================================================
-- 判断物品是否可以装备到指定槽位
-- ============================================================================
function Inventory.CanEquipToSlot(item, slotKey)
    if not item or not item.itemType then return false end
    local slots = TYPE_TO_SLOTS[item.itemType]
    if not slots then return false end
    for _, s in ipairs(slots) do
        if s == slotKey then return true end
    end
    return false
end

-- ============================================================================
-- 从背包直接装备到指定槽位
-- ============================================================================
function Inventory.EquipFromBag(bagIndex, slotKey, playerClassId)
    if type(bagIndex) ~= "number" or not IsFiniteNumber(bagIndex)
        or bagIndex % 1 ~= 0 or bagIndex < 1 or bagIndex > #playerData.bag then
        return false, "背包位置无效", nil
    end
    local item = playerData.bag[bagIndex]
    if not item then return false, "装备不存在", nil end
    if not Inventory.CanEquipToSlot(item, slotKey) then
        return false, "装备与目标槽位不匹配", slotKey
    end
    return Inventory.EquipItem(item, playerClassId, slotKey)
end

-- ============================================================================
-- 获取品质颜色
-- ============================================================================
function Inventory.GetRarityColor(rarityKey)
    local r = RARITY[rarityKey]
    return r and r.color or {200, 200, 200, 255}
end

-- ============================================================================
-- 获取品质名称
-- ============================================================================
function Inventory.GetRarityName(rarityKey)
    local r = RARITY[rarityKey]
    return r and r.name or "普通"
end

-- ============================================================================
-- 经济系统宿主 API（分解 / 锻造 / 强化）—— 封装 Enhance 纯逻辑 + playerData 状态
-- ============================================================================

--- 分解装备（回收）：装备基础价值与少量已投入强化金币返还。
---@param item table 被分解的装备
---@return boolean, table, string 成功与否 + {gold, enhanceRefund} + 原因
function Inventory.RecycleItem(item)
    if not item then return false, { gold = 0, enhanceRefund = 0 }, "无装备" end
    local locationType, locationKey = FindOwnedItem(item)
    if not locationType then
        return false, { gold = 0, enhanceRefund = 0 }, "装备已不存在或不属于当前角色"
    end
    if not IsCanonicalItem(item, nil) then
        return false, { gold = 0, enhanceRefund = 0 }, "装备数据异常"
    end
    local rawResult = Enhance.Recycle(item)
    local result = {
        gold = ClampInteger(rawResult and rawResult.gold, 0, MAX_RESOURCE, 0),
        enhanceRefund = ClampInteger(
            rawResult and rawResult.enhanceRefund, 0, MAX_RESOURCE, 0),
    }
    if result.gold <= 0 then
        return false, { gold = 0, enhanceRefund = 0 }, "该物品无法分解"
    end

    -- 先移除实例，再发放收益；这样同一个旧引用无法重复结算。
    if locationType == "bag" then
        table.remove(playerData.bag, locationKey --[[@as integer]])
    else
        playerData.equipped[locationKey] = nil
        Inventory.RecalcBonus()
    end
    local currentGold = ClampInteger(playerData.gold, 0, MAX_RESOURCE, 0)
    playerData.gold = math.min(MAX_RESOURCE, currentGold + result.gold)
    print(string.format("[Inventory] 分解 %s -> +%d金（强化返还%d）",
        item.name or "?", result.gold, result.enhanceRefund))
    return true, result, ""
end

--- 从装备槽直接销毁（分解用，不回包）
---@param slotKey string
---@return boolean
function Inventory.RemoveEquipped(slotKey)
    if not SLOT_NAMES[slotKey] then return false end
    if not playerData.equipped[slotKey] then return false end
    playerData.equipped[slotKey] = nil
    Inventory.RecalcBonus()
    return true
end

--- 从背包直接移除（分解用）
---@param bagIndex number
---@return boolean
function Inventory.RemoveBagItem(bagIndex)
    if type(bagIndex) ~= "number" or not IsFiniteNumber(bagIndex)
        or bagIndex % 1 ~= 0 or bagIndex < 1 or bagIndex > #playerData.bag then
        return false
    end
    if not playerData.bag[bagIndex] then return false end
    table.remove(playerData.bag, bagIndex)
    return true
end

--- 返回当前背包的锻造配方进度。材料按品质、部位和职业自动分组，
--- 每组优先选择未强化、属性较低的五件，避免玩家手动配错材料。
---@return table[]
function Inventory.GetForgeRecipes()
    local groups = {}
    local currentGold = ClampInteger(playerData.gold, 0, MAX_RESOURCE, 0)
    playerData.gold = currentGold

    for bagIndex, item in ipairs(playerData.bag) do
        if IsCanonicalItem(item, nil) then
            local itemType = GetItemType(item)
            local targetRarity = Enhance.GetNextRarity(item.rarity)
            if itemType and targetRarity then
                local classKey = item.classReq or "_"
                local key = item.rarity .. "|" .. itemType .. "|" .. classKey
                local group = groups[key]
                if not group then
                    group = {
                        key = key,
                        sourceRarity = item.rarity,
                        targetRarity = targetRarity,
                        itemType = itemType,
                        classReq = item.classReq,
                        entries = {},
                    }
                    groups[key] = group
                end
                table.insert(group.entries, { item = item, bagIndex = bagIndex })
            end
        end
    end

    local recipes = {}
    for _, group in pairs(groups) do
        table.sort(group.entries, SortForgeEntries)

        local targets = FindForgeTargetTemplates(
            group.itemType, group.targetRarity, group.classReq)
        local targetNames = {}
        local seenTargetNames = {}
        for _, template in ipairs(targets) do
            if not seenTargetNames[template.name] then
                seenTargetNames[template.name] = true
                table.insert(targetNames, template.name)
            end
        end
        table.sort(targetNames)

        local materials = {}
        local containsEnhanced = false
        for index = 1, math.min(Enhance.FORGE_MATERIAL_COUNT, #group.entries) do
            local material = group.entries[index].item
            table.insert(materials, material)
            if ClampInteger(material.enhance, 0, 12, 0) > 0 then
                containsEnhanced = true
            end
        end

        local count = #group.entries
        local cost = ClampInteger(
            Enhance.ForgeCost(group.targetRarity), 0, MAX_RESOURCE, 0)
        local targetAvailable = #targets > 0
        local hasMaterials = count >= Enhance.FORGE_MATERIAL_COUNT
        local hasGold = currentGold >= cost
        local canForge = targetAvailable and hasMaterials and hasGold and cost > 0
        local reason = ""
        if not targetAvailable then
            reason = "该部位暂无" .. Inventory.GetRarityName(group.targetRarity) .. "配方"
        elseif not hasMaterials then
            reason = "还差 " .. (Enhance.FORGE_MATERIAL_COUNT - count) .. " 件同组装备"
        elseif cost <= 0 then
            reason = "锻造费用异常"
        elseif not hasGold then
            reason = "金币不足，还差 " .. (cost - currentGold) .. " 金"
        end

        table.insert(recipes, {
            key = group.key,
            sourceRarity = group.sourceRarity,
            targetRarity = group.targetRarity,
            itemType = group.itemType,
            classReq = group.classReq,
            count = count,
            required = Enhance.FORGE_MATERIAL_COUNT,
            availableCrafts = math.floor(count / Enhance.FORGE_MATERIAL_COUNT),
            cost = cost,
            targetAvailable = targetAvailable,
            hasMaterials = hasMaterials,
            hasGold = hasGold,
            canForge = canForge,
            reason = reason,
            targetNames = targetNames,
            materials = materials,
            containsEnhanced = containsEnhanced,
        })
    end

    table.sort(recipes, function(a, b)
        local readyA = a.targetAvailable and a.hasMaterials
        local readyB = b.targetAvailable and b.hasMaterials
        if readyA ~= readyB then return readyA end
        if a.canForge ~= b.canForge then return a.canForge end

        local rarityA = RARITY_SORT_ORDER[a.sourceRarity] or 0
        local rarityB = RARITY_SORT_ORDER[b.sourceRarity] or 0
        if rarityA ~= rarityB then return rarityA > rarityB end

        local typeA = ITEM_TYPE_SORT_ORDER[a.itemType] or 99
        local typeB = ITEM_TYPE_SORT_ORDER[b.itemType] or 99
        if typeA ~= typeB then return typeA < typeB end
        return tostring(a.classReq or "") < tostring(b.classReq or "")
    end)

    return recipes
end

--- 锻造（五合一）：校验 + 扣金币 + 消耗五件材料，并把产物放回背包。
--- 产物为同部位的下一品质模板；第四个返回值为产物实例，旧调用只取前三个
--- 返回值时仍保持兼容。
---@param items table[] 五件材料
---@return boolean, string, string|nil, table|nil 成功/原因/目标品质 key/产物
function Inventory.ForgeItems(items)
    if type(items) ~= "table" or #items ~= Enhance.FORGE_MATERIAL_COUNT then
        return false, "需要" .. Enhance.FORGE_MATERIAL_COUNT .. "件锻造材料", nil
    end
    for _, material in ipairs(items) do
        if not IsCanonicalItem(material, nil) then
            return false, "锻造材料数据异常", nil
        end
    end
    local pick = Enhance.ForgePick(items)
    if not pick.ok then return false, pick.reason, nil end

    -- 材料必须是背包中五个不同的实例，避免重复传入同一对象只消耗一件
    -- 却仍判定锻造成功。
    local materialIndices = {}
    local usedIndices = {}
    for _, material in ipairs(items) do
        local foundIndex = nil
        for index, bagItem in ipairs(playerData.bag) do
            if not usedIndices[index] and bagItem == material then
                foundIndex = index
                break
            end
        end
        if not foundIndex then
            return false, "锻造材料必须来自背包", nil
        end
        usedIndices[foundIndex] = true
        table.insert(materialIndices, foundIndex)
    end

    local itemType = items[1].itemType or items[1].slot
    local preferredClass = items[1].classReq

    -- 目标部位没有对应品质模板时明确失败，不生成无法装备或无法出售的“空壳”装备。
    local candidates = FindForgeTargetTemplates(itemType, pick.targetRarity, preferredClass)
    if #candidates == 0 then
        return false, "该部位没有可锻造的目标品质装备", nil
    end

    local cost = ClampInteger(Enhance.ForgeCost(pick.targetRarity), 0, MAX_RESOURCE, 0)
    local currentGold = ClampInteger(playerData.gold, 0, MAX_RESOURCE, 0)
    playerData.gold = currentGold
    if cost <= 0 then return false, "锻造费用异常", nil end
    if currentGold < cost then return false, "金币不足", nil end

    local template = candidates[math.random(1, #candidates)]
    local resultItem = {}
    for key, value in pairs(template) do
        resultItem[key] = value
    end
    resultItem.enhance = 0
    -- 方案规定成品有 30% 概率附加 +1~+2，且仍受 +12 上限约束。
    if math.random() < 0.30 then
        resultItem.enhance = math.random(1, 2)
    end

    -- 倒序移除，避免前面材料被移除后导致后续索引漂移。
    table.sort(materialIndices, function(a, b) return a > b end)
    for _, index in ipairs(materialIndices) do
        table.remove(playerData.bag, index)
    end

    playerData.gold = currentGold - cost
    table.insert(playerData.bag, resultItem)
    print(string.format("[Inventory] 锻造成功 -> %s (%s，花费%d金)",
        pick.targetRarity, resultItem.name or "装备", cost))
    return true, "", pick.targetRarity, resultItem
end

--- 按配方描述自动选择五件合法材料并锻造。调用时会重新读取背包，
--- 因此 UI 刷新前留下的旧配方不会误消耗其它类别装备。
---@param recipe table GetForgeRecipes 返回的配方描述
---@return boolean, string, string|nil, table|nil
function Inventory.ForgeRecipe(recipe)
    if type(recipe) ~= "table" then
        return false, "锻造配方无效", nil, nil
    end

    local itemType = recipe.itemType
    local sourceRarity = recipe.sourceRarity
    local classReq = recipe.classReq
    if type(itemType) ~= "string" or type(sourceRarity) ~= "string"
        or not RARITY[sourceRarity] or not Enhance.GetNextRarity(sourceRarity) then
        return false, "锻造配方无效", nil, nil
    end

    local entries = {}
    for bagIndex, item in ipairs(playerData.bag) do
        if IsCanonicalItem(item, nil)
            and GetItemType(item) == itemType
            and item.rarity == sourceRarity
            and item.classReq == classReq then
            table.insert(entries, { item = item, bagIndex = bagIndex })
        end
    end
    table.sort(entries, SortForgeEntries)

    if #entries < Enhance.FORGE_MATERIAL_COUNT then
        return false, "材料数量不足，请刷新后重试", nil, nil
    end

    local materials = {}
    for index = 1, Enhance.FORGE_MATERIAL_COUNT do
        table.insert(materials, entries[index].item)
    end
    return Inventory.ForgeItems(materials)
end

--- 铁匠强化：只消耗金币，按成功率判定，失败可能掉级。
--- 保护强化额外消耗一颗保护石，失败时保持当前等级。
---@param item table 待强化装备
---@param useProtect boolean 是否使用保护石（失败不掉级）
---@return boolean, string, number, table|nil 成功/原因/最终强化等级/本次结果
function Inventory.EnhanceItem(item, useProtect)
    if not item then return false, "无装备", 0 end
    if not FindOwnedItem(item) then
        return false, "装备已不存在或不属于当前角色", 0
    end
    if not IsCanonicalItem(item, nil) then return false, "装备数据异常", 0 end
    local cur = ClampInteger(item.enhance, 0, 12, 0)
    item.enhance = cur
    if cur >= 12 then return false, "已达最高强化", cur end

    local nextLevel = cur + 1
    local cost = Enhance.EnhanceCost(nextLevel)
    local gold = ClampInteger(playerData.gold, 0, MAX_RESOURCE, 0)
    playerData.gold = gold
    if gold < cost.gold then return false, "金币不足", cur end
    useProtect = useProtect == true
    local failureLevel = Enhance.GetFailureLevel(cur, nextLevel)
    local canDowngrade = failureLevel < cur
    if useProtect and not canDowngrade then
        return false, "当前阶段失败不会掉级，无需使用保护石", cur
    end
    local protectStones = Inventory.GetProtectStones()
    if useProtect and protectStones <= 0 then
        return false, "保护石不足", cur
    end

    -- 确认资源充足后一次性扣除。无论成功或失败，本次铁匠服务费都不返还。
    playerData.gold = gold - cost.gold
    if useProtect then
        playerData.protectStones = protectStones - 1
    end

    local result = {
        previousLevel = cur,
        targetLevel = nextLevel,
        finalLevel = cur,
        goldSpent = cost.gold,
        successRate = cost.successRate,
        protected = useProtect,
        protectStoneSpent = useProtect and 1 or 0,
        failureLevel = failureLevel,
        canDowngrade = canDowngrade,
        downgraded = false,
    }

    -- 成功率判定
    if math.random() < cost.successRate then
        item.enhance = nextLevel
        result.finalLevel = nextLevel
        Inventory.RecalcBonus()
        return true, "", nextLevel, result
    end

    -- 失败：普通强化按阶段保底计算掉级；保护强化保持当前等级。
    if canDowngrade and not useProtect then
        item.enhance = failureLevel
        result.downgraded = item.enhance < cur
    end
    result.finalLevel = item.enhance or cur
    Inventory.RecalcBonus()
    return false, useProtect and "强化失败（保护石生效）" or "强化失败",
        result.finalLevel, result
end

Inventory.MAX_BAG_SLOTS = MAX_BAG_SLOTS

-- ============================================================================
-- 装备价值系统（统一：买入价 / 卖出价 / 强化价值加成）
--
-- 价值模型：
--   基础分 = atk*2 + def*1.5 + hp*0.3（沿用 ItemScore）
--   买入价 = floor(基础分 × 品质倍率 × 12)  —— 商人卖给玩家
--   卖出价 = floor(基础分 × 品质倍率 × 1.5) + 强化返还 —— 玩家卖给商人
--   卖出价约为买入价的 12.5%，只保留有限的装备回收价值。
-- ============================================================================

--- 装备买入价（商人出售给玩家的价格）
---@param item table 装备模板/实例
---@return number
function Inventory.GetItemPrice(item)
    if type(item) ~= "table" or type(item.id) ~= "string" then return 0 end
    local template = Inventory.GetItemTemplate(item.id)
    if not template then return 0 end
    local r = RARITY[template.rarity]
    local mult = r and r.mult or 1.0
    local score = ItemScore(template)
    if score < 0 then return 0 end
    return math.min(MAX_RESOURCE, math.max(20, math.floor(
        score * mult * Inventory.ECONOMY.itemBuyMultiplier)))
end

Inventory.PROTECT_STONE_PRICE = 800

--- 获取保护石数量。
function Inventory.GetProtectStones()
    playerData.protectStones = ClampInteger(playerData.protectStones, 0, MAX_RESOURCE, 0)
    return playerData.protectStones
end

--- 从商人购买一颗保护石。
---@return boolean, string
function Inventory.BuyProtectStone()
    if Inventory.GetProtectStones() >= MAX_RESOURCE then
        return false, "保护石已达上限"
    end
    if not Inventory.SpendGold(Inventory.PROTECT_STONE_PRICE) then
        return false, "金币不足"
    end
    playerData.protectStones = playerData.protectStones + 1
    return true, ""
end

--- 装备卖出价（玩家卖给商人的价格，含强化返还）
---@param item table 装备实例
---@return number
function Inventory.GetItemSellPrice(item)
    if type(item) ~= "table" or not IsCanonicalItem(item, nil) then return 0 end
    local template = Inventory.GetItemTemplate(item.id)
    local r = RARITY[template.rarity]
    local mult = r and r.mult or 1.0
    local score = ItemScore(template)
    if score < 0 then return 0 end
    local base = math.floor(score * mult * Inventory.ECONOMY.itemSellMultiplier)
    -- 强化返还：每级只返还少量金币，避免“强化后出售”成为刷钱路线。
    local enhanceBonus = ClampInteger(item.enhance, 0, 12, 0)
        * Inventory.ECONOMY.enhanceSellRefundPerLevel
    return math.min(MAX_RESOURCE, base + enhanceBonus)
end

--- 出售背包中的装备（移除 + 加金币）
---@param itemOrIndex table|number 装备实例或背包索引
---@return boolean, number|string 成功与否，返回卖出价或错误信息
function Inventory.SellItem(itemOrIndex)
    local bagIndex = nil
    local item = nil
    if type(itemOrIndex) == "table" then
        for index, bagItem in ipairs(playerData.bag) do
            if bagItem == itemOrIndex then
                bagIndex = index
                item = bagItem
                break
            end
        end
        if not bagIndex then return false, "装备已不存在或不属于当前角色" end
    else
        if type(itemOrIndex) ~= "number" or not IsFiniteNumber(itemOrIndex)
            or itemOrIndex % 1 ~= 0 or itemOrIndex < 1 or itemOrIndex > #playerData.bag then
            return false, "装备索引无效"
        end
        bagIndex = itemOrIndex
        item = playerData.bag[bagIndex]
    end
    if not item then return false, "装备不存在" end
    local price = Inventory.GetItemSellPrice(item)
    if price <= 0 then return false, "装备数据异常" end
    table.remove(playerData.bag, bagIndex)
    local currentGold = ClampInteger(playerData.gold, 0, MAX_RESOURCE, 0)
    playerData.gold = math.min(MAX_RESOURCE, currentGold + price)
    print(string.format("[Inventory] 出售 %s -> +%d金", item.name or "?", price))
    return true, price
end

--- 获取所有装备模板（供商人货架）
---@return table[] 装备模板数组
function Inventory.GetAllItemTemplates()
    return Inventory.GetCompatibleItemTemplates(nil)
end

return Inventory
