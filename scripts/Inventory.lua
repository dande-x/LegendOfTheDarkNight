-- ============================================================================
-- Inventory.lua — 掉落 / 装备 / 背包 / 金币系统 (初版)
-- ============================================================================

local Inventory = {}

-- ============================================================================
-- 装备槽位
-- ============================================================================
local SLOT = {
    WEAPON   = "weapon",
    ARMOR    = "armor",
    RING     = "ring",
    NECKLACE = "necklace",
}
Inventory.SLOT = SLOT

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
    -- ======== 武器 ========
    { id = "sword_iron",    name = "铁剑",     slot = SLOT.WEAPON,   rarity = "COMMON",    atk = 8,  def = 0, hp = 0,  classReq = "warrior" },
    { id = "sword_steel",   name = "精钢剑",   slot = SLOT.WEAPON,   rarity = "UNCOMMON",  atk = 15, def = 0, hp = 0,  classReq = "warrior" },
    { id = "sword_flame",   name = "烈焰刀",   slot = SLOT.WEAPON,   rarity = "RARE",      atk = 28, def = 0, hp = 0,  classReq = "warrior" },
    { id = "sword_dragon",  name = "屠龙宝刀", slot = SLOT.WEAPON,   rarity = "EPIC",      atk = 45, def = 2, hp = 50, classReq = "warrior" },
    { id = "staff_wood",    name = "木杖",     slot = SLOT.WEAPON,   rarity = "COMMON",    atk = 10, def = 0, hp = 0,  classReq = "mage" },
    { id = "staff_crystal", name = "水晶杖",   slot = SLOT.WEAPON,   rarity = "UNCOMMON",  atk = 18, def = 0, hp = 0,  classReq = "mage" },
    { id = "staff_thunder", name = "雷霆法杖", slot = SLOT.WEAPON,   rarity = "RARE",      atk = 32, def = 0, hp = 0,  classReq = "mage" },
    { id = "staff_arcane",  name = "奥术权杖", slot = SLOT.WEAPON,   rarity = "EPIC",      atk = 50, def = 0, hp = 30, classReq = "mage" },
    { id = "bell_copper",   name = "铜铃",     slot = SLOT.WEAPON,   rarity = "COMMON",    atk = 6,  def = 0, hp = 0,  classReq = "taoist" },
    { id = "bell_jade",     name = "玉磬",     slot = SLOT.WEAPON,   rarity = "UNCOMMON",  atk = 12, def = 0, hp = 0,  classReq = "taoist" },
    { id = "bell_soul",     name = "招魂幡",   slot = SLOT.WEAPON,   rarity = "RARE",      atk = 22, def = 2, hp = 20, classReq = "taoist" },
    { id = "bell_holy",     name = "太虚法器", slot = SLOT.WEAPON,   rarity = "EPIC",      atk = 38, def = 3, hp = 60, classReq = "taoist" },

    -- ======== 防具 ========
    { id = "armor_cloth",   name = "布甲",     slot = SLOT.ARMOR,    rarity = "COMMON",    atk = 0,  def = 5,  hp = 20  },
    { id = "armor_leather", name = "皮甲",     slot = SLOT.ARMOR,    rarity = "UNCOMMON",  atk = 0,  def = 10, hp = 40  },
    { id = "armor_chain",   name = "锁子甲",   slot = SLOT.ARMOR,    rarity = "RARE",      atk = 0,  def = 18, hp = 80  },
    { id = "armor_dragon",  name = "龙鳞甲",   slot = SLOT.ARMOR,    rarity = "EPIC",      atk = 5,  def = 30, hp = 150 },
    { id = "armor_heaven",  name = "天衣",     slot = SLOT.ARMOR,    rarity = "LEGENDARY", atk = 10, def = 40, hp = 250 },

    -- ======== 戒指 ========
    { id = "ring_copper",   name = "铜戒",     slot = SLOT.RING,     rarity = "COMMON",    atk = 3,  def = 1, hp = 0  },
    { id = "ring_silver",   name = "银戒",     slot = SLOT.RING,     rarity = "UNCOMMON",  atk = 6,  def = 2, hp = 10 },
    { id = "ring_gold",     name = "金戒",     slot = SLOT.RING,     rarity = "RARE",      atk = 10, def = 4, hp = 25 },
    { id = "ring_dragon",   name = "龙纹戒",   slot = SLOT.RING,     rarity = "EPIC",      atk = 18, def = 6, hp = 50 },

    -- ======== 项链 ========
    { id = "neck_bone",     name = "骨链",     slot = SLOT.NECKLACE, rarity = "COMMON",    atk = 2,  def = 2, hp = 15  },
    { id = "neck_jade",     name = "玉佩",     slot = SLOT.NECKLACE, rarity = "UNCOMMON",  atk = 4,  def = 4, hp = 30  },
    { id = "neck_amber",    name = "琥珀坠",   slot = SLOT.NECKLACE, rarity = "RARE",      atk = 8,  def = 6, hp = 50  },
    { id = "neck_dragon",   name = "龙牙链",   slot = SLOT.NECKLACE, rarity = "EPIC",      atk = 15, def = 10, hp = 80 },
}

-- 构建 ID 索引
local ITEM_BY_ID = {}
for _, tmpl in ipairs(ITEM_TEMPLATES) do
    ITEM_BY_ID[tmpl.id] = tmpl
end

-- ============================================================================
-- 敌人掉落表 (enemyName → { gold, items:[{id, weight}] })
-- ============================================================================
local DROP_TABLES = {
    ["山贼"] = {
        goldMin = 5, goldMax = 15, dropChance = 0.35,
        items = {
            { id = "sword_iron",    weight = 30 },
            { id = "armor_cloth",   weight = 25 },
            { id = "ring_copper",   weight = 20 },
            { id = "neck_bone",     weight = 20 },
            { id = "bell_copper",   weight = 15 },
            { id = "staff_wood",    weight = 15 },
        },
    },
    ["野狼"] = {
        goldMin = 8, goldMax = 20, dropChance = 0.40,
        items = {
            { id = "armor_cloth",   weight = 20 },
            { id = "armor_leather", weight = 10 },
            { id = "ring_copper",   weight = 20 },
            { id = "neck_bone",     weight = 15 },
            { id = "ring_silver",   weight = 5  },
        },
    },
    ["蛇妖"] = {
        goldMin = 15, goldMax = 35, dropChance = 0.40,
        items = {
            { id = "sword_steel",   weight = 15 },
            { id = "staff_crystal", weight = 15 },
            { id = "bell_jade",     weight = 15 },
            { id = "armor_leather", weight = 18 },
            { id = "ring_silver",   weight = 12 },
            { id = "neck_jade",     weight = 12 },
            { id = "sword_flame",   weight = 3  },
        },
    },
    ["树妖"] = {
        goldMin = 20, goldMax = 45, dropChance = 0.45,
        items = {
            { id = "armor_leather", weight = 15 },
            { id = "armor_chain",   weight = 8  },
            { id = "ring_silver",   weight = 15 },
            { id = "neck_jade",     weight = 12 },
            { id = "ring_gold",     weight = 4  },
            { id = "neck_amber",    weight = 4  },
        },
    },
    ["石魔"] = {
        goldMin = 30, goldMax = 70, dropChance = 0.50,
        items = {
            { id = "sword_flame",   weight = 12 },
            { id = "staff_thunder", weight = 12 },
            { id = "bell_soul",     weight = 12 },
            { id = "armor_chain",   weight = 15 },
            { id = "ring_gold",     weight = 10 },
            { id = "neck_amber",    weight = 10 },
            { id = "sword_dragon",  weight = 2  },
            { id = "staff_arcane",  weight = 2  },
            { id = "bell_holy",     weight = 2  },
            { id = "armor_dragon",  weight = 2  },
            { id = "ring_dragon",   weight = 2  },
            { id = "neck_dragon",   weight = 2  },
            { id = "armor_heaven",  weight = 1  },
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
        [SLOT.WEAPON]   = nil,
        [SLOT.ARMOR]    = nil,
        [SLOT.RING]     = nil,
        [SLOT.NECKLACE] = nil,
    },
    bag = {},       -- 物品列表 (item template 引用)
    -- 装备加成缓存
    bonusAtk = 0,
    bonusDef = 0,
    bonusHP  = 0,
}

Inventory.playerData = playerData

-- ============================================================================
-- 初始化
-- ============================================================================
function Inventory.Init()
    playerData.gold = 0
    playerData.equipped = {
        [SLOT.WEAPON]   = nil,
        [SLOT.ARMOR]    = nil,
        [SLOT.RING]     = nil,
        [SLOT.NECKLACE] = nil,
    }
    playerData.bag = {}
    playerData.bonusAtk = 0
    playerData.bonusDef = 0
    playerData.bonusHP  = 0
    print("[Inventory] Initialized")
end

-- ============================================================================
-- 装备评分（用于自动装备比较）
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
-- 应用装备加成到角色
-- ============================================================================
function Inventory.ApplyBonus(player)
    if not player then return end
    -- 加成已包含在 bonusXxx 中，由 main.lua 叠加
end

-- ============================================================================
-- 装备物品（自动卸下旧装备到背包）
-- ============================================================================
function Inventory.EquipItem(item, playerClassId)
    if not item then return false end
    -- 检查职业限制
    if item.classReq and item.classReq ~= playerClassId then
        return false
    end

    local slot = item.slot
    local old = playerData.equipped[slot]

    -- 卸下旧装备到背包
    if old then
        if #playerData.bag < MAX_BAG_SLOTS then
            table.insert(playerData.bag, old)
        end
        -- 如果背包满了就丢弃旧的
    end

    playerData.equipped[slot] = item

    -- 从背包中移除新装备
    for i, bagItem in ipairs(playerData.bag) do
        if bagItem == item then
            table.remove(playerData.bag, i)
            break
        end
    end

    Inventory.RecalcBonus()
    print("[Inventory] Equipped: " .. item.name .. " (" .. RARITY[item.rarity].name .. ")")
    return true
end

-- ============================================================================
-- 尝试自动装备（如果比当前好）
-- ============================================================================
function Inventory.TryAutoEquip(item, playerClassId)
    if not item then return false end
    if item.classReq and item.classReq ~= playerClassId then
        return false
    end

    local slot = item.slot
    local current = playerData.equipped[slot]
    if ItemScore(item) > ItemScore(current) then
        return Inventory.EquipItem(item, playerClassId)
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
-- 处理敌人掉落
-- ============================================================================
function Inventory.ProcessDrop(enemyName, playerClassId)
    local dropTable = DROP_TABLES[enemyName]
    if not dropTable then return nil, 0 end

    -- 金币必掉
    local gold = math.random(dropTable.goldMin, dropTable.goldMax)
    playerData.gold = playerData.gold + gold

    -- 物品掉落判定
    local droppedItem = nil
    if math.random() < dropTable.dropChance then
        -- 加权随机选取物品
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
                    -- 创建物品实例 (浅拷贝)
                    droppedItem = {}
                    for k, v in pairs(tmpl) do
                        droppedItem[k] = v
                    end

                    -- 尝试自动装备
                    local equipped = Inventory.TryAutoEquip(droppedItem, playerClassId)
                    if not equipped then
                        Inventory.AddToBag(droppedItem)
                    end
                end
                break
            end
        end
    end

    return droppedItem, gold
end

-- ============================================================================
-- 获取装备信息字符串（简易显示）
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

return Inventory
