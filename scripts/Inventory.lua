-- ============================================================================
-- Inventory.lua — 掉落 / 装备 / 背包 / 金币系统
-- 支持地面拾取: RollDrop 只生成掉落物，不自动添加
-- ============================================================================

local Inventory = {}

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

-- ============================================================================
-- 物品模板表
-- ============================================================================
local ITEM_TEMPLATES = {
    -- 武器（职业专属）
    { id = "sword_iron",    name = "铁剑",     slot = SLOT.WEAPON,   itemType = "weapon", rarity = "COMMON",    atk = 8,  def = 0, hp = 0,  classReq = "warrior" },
    { id = "sword_steel",   name = "精钢剑",   slot = SLOT.WEAPON,   itemType = "weapon", rarity = "UNCOMMON",  atk = 15, def = 0, hp = 0,  classReq = "warrior" },
    { id = "sword_flame",   name = "烈焰刀",   slot = SLOT.WEAPON,   itemType = "weapon", rarity = "RARE",      atk = 28, def = 0, hp = 0,  classReq = "warrior" },
    { id = "sword_dragon",  name = "屠龙宝刀", slot = SLOT.WEAPON,   itemType = "weapon", rarity = "EPIC",      atk = 45, def = 2, hp = 50, classReq = "warrior" },
    { id = "staff_wood",    name = "木杖",     slot = SLOT.WEAPON,   itemType = "weapon", rarity = "COMMON",    atk = 10, def = 0, hp = 0,  classReq = "mage" },
    { id = "staff_crystal", name = "水晶杖",   slot = SLOT.WEAPON,   itemType = "weapon", rarity = "UNCOMMON",  atk = 18, def = 0, hp = 0,  classReq = "mage" },
    { id = "staff_thunder", name = "雷霆法杖", slot = SLOT.WEAPON,   itemType = "weapon", rarity = "RARE",      atk = 32, def = 0, hp = 0,  classReq = "mage" },
    { id = "staff_arcane",  name = "奥术权杖", slot = SLOT.WEAPON,   itemType = "weapon", rarity = "EPIC",      atk = 50, def = 0, hp = 30, classReq = "mage" },
    { id = "bell_copper",   name = "铜铃",     slot = SLOT.WEAPON,   itemType = "weapon", rarity = "COMMON",    atk = 6,  def = 0, hp = 0,  classReq = "taoist" },
    { id = "bell_jade",     name = "玉磬",     slot = SLOT.WEAPON,   itemType = "weapon", rarity = "UNCOMMON",  atk = 12, def = 0, hp = 0,  classReq = "taoist" },
    { id = "bell_soul",     name = "招魂幡",   slot = SLOT.WEAPON,   itemType = "weapon", rarity = "RARE",      atk = 22, def = 2, hp = 20, classReq = "taoist" },
    { id = "bell_holy",     name = "太虚法器", slot = SLOT.WEAPON,   itemType = "weapon", rarity = "EPIC",      atk = 38, def = 3, hp = 60, classReq = "taoist" },
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

local ITEM_BY_ID = {}
for _, tmpl in ipairs(ITEM_TEMPLATES) do
    ITEM_BY_ID[tmpl.id] = tmpl
end

-- ============================================================================
-- 敌人掉落表
-- ============================================================================
local DROP_TABLES = {
    ["幽灵鹿"] = {
        goldMin = 5, goldMax = 15, dropChance = 0.35,
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
        goldMin = 8, goldMax = 20, dropChance = 0.40,
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
    ["骷髅"] = {
        goldMin = 15, goldMax = 35, dropChance = 0.40,
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
    ["蜘蛛"] = {
        goldMin = 20, goldMax = 45, dropChance = 0.45,
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
        goldMin = 30, goldMax = 70, dropChance = 0.50,
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

-- ============================================================================
-- 玩家背包状态
-- ============================================================================
local MAX_BAG_SLOTS = 20

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
}

Inventory.playerData = playerData

-- ============================================================================
-- 药水配置
-- ============================================================================
Inventory.POTION_CONFIG = {
    hp = { max = 10, price = 40, healRatio = 0.35, dropChance = 0.15, label = "血药" },
    mp = { max = 8,  price = 60, healRatio = 0.45, dropChance = 0.10, label = "蓝药" },
}

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
    if not playerData.potions then playerData.potions = { hp = 5, mp = 3 } --[[@as table<string,number>]] end
    if (playerData.potions[kind] or 0) <= 0 then return false end
    playerData.potions[kind] = playerData.potions[kind] - 1
    return true
end

--- 获取药水数量
---@param kind "hp"|"mp"
---@return number
function Inventory.GetPotionCount(kind)
    if not playerData.potions then playerData.potions = { hp = 5, mp = 3 } --[[@as table<string,number>]] end
    return playerData.potions[kind] or 0
end

--- 购买药水，扣金币，返回 true 表示成功
---@param kind "hp"|"mp"
---@return boolean, string
function Inventory.BuyPotion(kind)
    local cfg = Inventory.POTION_CONFIG[kind]
    if not cfg then return false, "无效类型" end
    if not playerData.potions then playerData.potions = { hp = 5, mp = 3 } --[[@as table<string,number>]] end
    if playerData.potions[kind] >= cfg.max then return false, "已满" end
    if playerData.gold < cfg.price then return false, "金币不足" end
    playerData.gold = playerData.gold - cfg.price
    playerData.potions[kind] = playerData.potions[kind] + 1
    return true, ""
end

--- 击杀掉落药水判定（在 RollDrop 之后额外调用）
function Inventory.RollPotionDrop()
    if not playerData.potions then playerData.potions = { hp = 5, mp = 3 } --[[@as table<string,number>]] end
    local dropped = {}
    for kind, cfg in pairs(Inventory.POTION_CONFIG) do
        if math.random() < cfg.dropChance and playerData.potions[kind] < cfg.max then
            playerData.potions[kind] = playerData.potions[kind] + 1
            table.insert(dropped, cfg.label)
        end
    end
    return dropped
end

-- ============================================================================
-- 装备评分
-- ============================================================================
local function ItemScore(item)
    if not item then return -1 end
    return item.atk * 2 + item.def * 1.5 + item.hp * 0.3
end

-- ============================================================================
-- 重新计算装备加成
-- ============================================================================
function Inventory.RecalcBonus()
    local atk, def, hp = 0, 0, 0
    for _, item in pairs(playerData.equipped) do
        if item then
            atk = atk + item.atk
            def = def + item.def
            hp  = hp  + item.hp
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

-- ============================================================================
-- 装备物品到指定槽位（可指定 targetSlot，不指定则自动选择）
-- ============================================================================
function Inventory.EquipItem(item, playerClassId, targetSlot)
    if not item then return false end
    if item.classReq and item.classReq ~= playerClassId then
        return false
    end

    local slot = targetSlot or FindBestSlot(item)
    if not slot then return false end

    local old = playerData.equipped[slot]

    if old then
        if #playerData.bag < MAX_BAG_SLOTS then
            table.insert(playerData.bag, old)
        end
    end

    playerData.equipped[slot] = item

    for i, bagItem in ipairs(playerData.bag) do
        if bagItem == item then
            table.remove(playerData.bag, i)
            break
        end
    end

    Inventory.RecalcBonus()
    print("[Inventory] Equipped: " .. item.name .. " → " .. (SLOT_NAMES[slot] or slot))
    return true
end

-- ============================================================================
-- 尝试自动装备（双槽位：有空槽直接装，否则与最弱的比较）
-- ============================================================================
function Inventory.TryAutoEquip(item, playerClassId)
    if not item then return false end
    if item.classReq and item.classReq ~= playerClassId then
        return false
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
    if #playerData.bag >= MAX_BAG_SLOTS then
        print("[Inventory] Bag full, discarding " .. item.name)
        return false
    end
    table.insert(playerData.bag, item)
    return true
end

-- ============================================================================
-- 添加金币
-- ============================================================================
function Inventory.AddGold(amount)
    playerData.gold = playerData.gold + amount
end

-- ============================================================================
-- 拾取物品（自动装备或放入背包）
-- ============================================================================
function Inventory.PickupItem(item, playerClassId)
    if not item then return false, "无物品" end
    local equipped = Inventory.TryAutoEquip(item, playerClassId)
    if not equipped then
        local added = Inventory.AddToBag(item)
        if not added then
            return false, "背包已满"
        end
    end
    return true, ""
end

-- ============================================================================
-- 掉落判定（只计算掉什么，不添加到背包/金币）
-- ============================================================================
function Inventory.RollDrop(enemyName)
    local dropTable = DROP_TABLES[enemyName]
    if not dropTable then return nil, 0 end

    -- 金币必掉
    local gold = math.random(dropTable.goldMin, dropTable.goldMax)

    -- 物品掉落判定
    local droppedItem = nil
    if math.random() < dropTable.dropChance then
        local totalWeight = 0
        for _, entry in ipairs(dropTable.items) do
            totalWeight = totalWeight + entry.weight
        end

        local roll = math.random() * totalWeight
        local acc = 0
        for _, entry in ipairs(dropTable.items) do
            acc = acc + entry.weight
            if roll <= acc then
                local tmpl = ITEM_BY_ID[entry.id]
                if tmpl then
                    droppedItem = {}
                    for k, v in pairs(tmpl) do
                        droppedItem[k] = v
                    end
                end
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
    local item, gold = Inventory.RollDrop(enemyName)
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
    local item = playerData.equipped[slotKey]
    if not item then return false end
    if #playerData.bag >= MAX_BAG_SLOTS then
        print("[Inventory] Bag full, cannot unequip")
        return false
    end
    table.insert(playerData.bag, item)
    playerData.equipped[slotKey] = nil
    Inventory.RecalcBonus()
    print("[Inventory] Unequipped: " .. item.name .. " from " .. (SLOT_NAMES[slotKey] or slotKey))
    return true
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
    local item = playerData.bag[bagIndex]
    if not item then return false end
    if not Inventory.CanEquipToSlot(item, slotKey) then return false end
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

Inventory.MAX_BAG_SLOTS = MAX_BAG_SLOTS

return Inventory
