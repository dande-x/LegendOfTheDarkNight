-- ============================================================================
-- MonsterData.lua — 怪物系统分支数据，供 Combat / Inventory 集成
-- ============================================================================

local MonsterData = {}

-- Combat.ENEMY_DEFS 的显示名替换映射。
MonsterData.NAME_MAP = {
    ["幽灵鹿"] = "鹿",
    ["蜘蛛"] = "毒蜘蛛",
    ["狼人"] = "狼",
    ["暗影蛛后"] = "蚁后",
    ["山岳巨人"] = "沃玛教主",
    ["九幽骨龙"] = "火龙王",
    ["炎魔领主"] = "牛魔王",
}

-- 新增怪物定义。运行时战斗属性由 Balance.lua 按 level / tier / monsterType
-- 派生；旧 hp/atk/def/exp 字段仅作历史数据兼容，不再参与结算。
MonsterData.NEW_ENEMIES = {
    {
        name = "蛤蟆", monsterType = "toad",
        level = 2, hp = 100, atk = 9, def = 3,
        speed = 2.4, chaseRange = 7, attackRange = 1.5, attackCD = 1.8,
        exp = 38, scale = 0.9, tier = "normal",
    },
    {
        name = "多钩猫", monsterType = "cat",
        level = 3, hp = 115, atk = 11, def = 4,
        speed = 3.0, chaseRange = 8, attackRange = 1.5, attackCD = 1.6,
        exp = 45, scale = 0.95, tier = "normal",
    },
    {
        name = "钉耙猫", monsterType = "cat",
        level = 4, hp = 130, atk = 13, def = 5,
        speed = 3.1, chaseRange = 8, attackRange = 1.5, attackCD = 1.5,
        exp = 52, scale = 0.95, tier = "normal",
    },
    {
        name = "半兽勇士", monsterType = "orc",
        -- 第一幕守关 Boss。原先标成 elite，Combat 的守关刷怪逻辑只接受
        -- boss tier，导致 q_006 永远无法生成目标。当前约 2900 HP，
        -- 作为第一幕高潮但不拖成持久战。
        level = 9, hp = 300, atk = 24, def = 10,
        speed = 2.2, chaseRange = 9, attackRange = 1.5, attackCD = 2.0,
        exp = 120, scale = 1.5, tier = "boss",
    },
    {
        name = "白野猪", monsterType = "boar",
        -- 第二幕 Boss：当前约 6800 HP。此前 1800 × 5 反而比后续
        -- 多个 Boss 更耐打，导致第二幕节奏异常陡峭。
        level = 20, hp = 640, atk = 32, def = 14,
        speed = 1.5, chaseRange = 12, attackRange = 1.8, attackCD = 2.8,
        exp = 300, scale = 2.2, tier = "boss",
    },
    {
        name = "红野猪", monsterType = "boar",
        level = 18, hp = 520, atk = 34, def = 15,
        speed = 2.1, chaseRange = 10, attackRange = 1.6, attackCD = 1.9,
        exp = 240, scale = 1.35, tier = "normal",
    },
    {
        name = "黑野猪", monsterType = "boar",
        level = 22, hp = 640, atk = 39, def = 18,
        speed = 2.2, chaseRange = 11, attackRange = 1.6, attackCD = 1.8,
        exp = 300, scale = 1.45, tier = "normal",
    },
    -- === 25~50 区间补齐（同类物种进阶变体，合理复用骨架）===
    {
        name = "石像鬼", monsterType = "golem",
        level = 26, hp = 620, atk = 40, def = 20,
        speed = 1.8, chaseRange = 9, attackRange = 1.5, attackCD = 2.2,
        exp = 320, scale = 1.5, tier = "normal",
    },
    {
        name = "海妖", monsterType = "serpent",
        level = 30, hp = 720, atk = 46, def = 16,
        speed = 2.6, chaseRange = 13, attackRange = 1.5, attackCD = 1.7,
        exp = 400, scale = 1.7, tier = "normal",
    },
    {
        name = "巨蜥", monsterType = "serpent",
        level = 33, hp = 840, atk = 50, def = 19,
        speed = 2.4, chaseRange = 12, attackRange = 1.5, attackCD = 1.6,
        exp = 480, scale = 1.9, tier = "normal",
    },
    {
        name = "岩甲兽", monsterType = "golem",
        level = 37, hp = 1020, atk = 58, def = 24,
        speed = 1.6, chaseRange = 9, attackRange = 1.5, attackCD = 2.0,
        exp = 620, scale = 1.7, tier = "normal",
    },
    {
        name = "黑鳞蟒", monsterType = "serpent",
        level = 40, hp = 1150, atk = 64, def = 20,
        speed = 2.7, chaseRange = 14, attackRange = 1.5, attackCD = 1.5,
        exp = 720, scale = 2.1, tier = "normal",
    },
    {
        name = "深渊恶鬼", monsterType = "orc",
        level = 43, hp = 1300, atk = 70, def = 26,
        speed = 2.3, chaseRange = 13, attackRange = 1.5, attackCD = 1.4,
        exp = 850, scale = 1.4, tier = "normal",
    },
    {
        name = "熔岩巨兽", monsterType = "golem",
        level = 46, hp = 1500, atk = 76, def = 30,
        speed = 1.7, chaseRange = 10, attackRange = 1.6, attackCD = 1.9,
        exp = 1000, scale = 1.9, tier = "normal",
    },
    {
        name = "魔龙幼崽", monsterType = "serpent",
        level = 48, hp = 1700, atk = 82, def = 28,
        speed = 2.8, chaseRange = 15, attackRange = 1.6, attackCD = 1.6,
        exp = 1200, scale = 2.2, tier = "normal",
    },
    {
        name = "祖玛卫士", monsterType = "orc",
        level = 50, hp = 2000, atk = 88, def = 32,
        speed = 2.2, chaseRange = 13, attackRange = 1.6, attackCD = 1.5,
        exp = 1400, scale = 1.5, tier = "elite",
    },
}

-- 各等级带使用共享掉落池。RollDrop 只读这些数组，因此共享引用不会
-- 产生运行时状态污染，同时避免常规怪复制大段完全相同的装备列表。
local WATER_CITY_ITEMS = {
    { id = "sword_flame", weight = 12 }, { id = "staff_thunder", weight = 12 },
    { id = "bell_soul", weight = 12 }, { id = "armor_chain", weight = 14 },
    { id = "helm_golden", weight = 10 }, { id = "neck_amber", weight = 10 },
    { id = "brace_gold", weight = 10 }, { id = "ring_gold", weight = 10 },
    { id = "belt_chain", weight = 10 }, { id = "boots_iron", weight = 10 },
    { id = "sword_cjzz", weight = 2 }, { id = "staff_arcane", weight = 2 },
    { id = "bell_holy", weight = 2 },
}

local MENGZHONG_ITEMS = {
    { id = "sword_steel", weight = 12 }, { id = "staff_crystal", weight = 12 },
    { id = "bell_jade", weight = 12 }, { id = "armor_chain", weight = 14 },
    { id = "helm_golden", weight = 10 }, { id = "neck_amber", weight = 10 },
    { id = "brace_gold", weight = 10 }, { id = "ring_gold", weight = 10 },
    { id = "belt_chain", weight = 10 }, { id = "boots_iron", weight = 10 },
    { id = "sword_flame", weight = 3 }, { id = "staff_thunder", weight = 3 },
    { id = "bell_soul", weight = 3 },
}

local WOMAR_ITEMS = {
    { id = "sword_cjzz", weight = 12 }, { id = "staff_arcane", weight = 12 },
    { id = "bell_holy", weight = 12 }, { id = "armor_dragon", weight = 14 },
    { id = "helm_dragon", weight = 10 }, { id = "neck_dragon", weight = 10 },
    { id = "brace_dragon", weight = 10 }, { id = "ring_dragon", weight = 10 },
    { id = "belt_dragon", weight = 10 }, { id = "boots_dragon", weight = 10 },
    { id = "sword_dragon", weight = 1 }, { id = "staff_shfz", weight = 1 },
    { id = "bell_xyjs", weight = 1 }, { id = "armor_heaven", weight = 1 },
    { id = "helm_heaven", weight = 1 }, { id = "boots_wind", weight = 1 },
}

local ZUMA_ITEMS = {
    { id = "sword_cjzz", weight = 10 }, { id = "staff_arcane", weight = 10 },
    { id = "bell_holy", weight = 10 }, { id = "armor_dragon", weight = 12 },
    { id = "helm_dragon", weight = 10 }, { id = "neck_dragon", weight = 10 },
    { id = "brace_dragon", weight = 10 }, { id = "ring_dragon", weight = 10 },
    { id = "belt_dragon", weight = 10 }, { id = "boots_dragon", weight = 10 },
    { id = "sword_dragon", weight = 3 }, { id = "staff_shfz", weight = 3 },
    { id = "bell_xyjs", weight = 3 }, { id = "armor_heaven", weight = 3 },
    { id = "helm_heaven", weight = 3 }, { id = "boots_wind", weight = 3 },
}

-- 补充掉落表。key 使用 Combat 改名后的经典怪物名。
MonsterData.DROP_TABLES = {
    ["蛤蟆"] = {
        goldMin = 4, goldMax = 10, dropChance = 0.18,
        items = {
            { id = "sword_iron", weight = 14 },
            { id = "staff_wood", weight = 14 },
            { id = "bell_copper", weight = 14 },
            { id = "armor_cloth", weight = 18 },
            { id = "helm_iron", weight = 16 },
            { id = "ring_copper", weight = 16 },
            { id = "neck_bone", weight = 12 },
            { id = "brace_iron", weight = 12 },
            { id = "belt_cloth", weight = 12 },
            { id = "boots_cloth", weight = 12 },
        },
    },
    ["多钩猫"] = {
        goldMin = 5, goldMax = 13, dropChance = 0.20,
        items = {
            { id = "sword_iron", weight = 14 },
            { id = "staff_wood", weight = 14 },
            { id = "bell_copper", weight = 14 },
            { id = "armor_cloth", weight = 16 },
            { id = "helm_iron", weight = 16 },
            { id = "ring_copper", weight = 16 },
            { id = "neck_bone", weight = 12 },
            { id = "brace_iron", weight = 12 },
            { id = "belt_cloth", weight = 12 },
            { id = "boots_cloth", weight = 12 },
        },
    },
    ["钉耙猫"] = {
        goldMin = 6, goldMax = 16, dropChance = 0.22,
        items = {
            { id = "sword_iron", weight = 12 },
            { id = "staff_wood", weight = 12 },
            { id = "bell_copper", weight = 12 },
            { id = "armor_cloth", weight = 14 },
            { id = "helm_iron", weight = 15 },
            { id = "ring_copper", weight = 15 },
            { id = "neck_bone", weight = 12 },
            { id = "brace_iron", weight = 12 },
            { id = "belt_cloth", weight = 12 },
            { id = "boots_cloth", weight = 12 },
            { id = "helm_bronze", weight = 4 },
            { id = "ring_silver", weight = 4 },
        },
    },
    ["半兽勇士"] = {
        goldMin = 23, goldMax = 52, dropChance = 0.35,
        items = {
            { id = "sword_steel", weight = 14 },
            { id = "armor_leather", weight = 16 },
            { id = "brace_silver", weight = 14 },
            { id = "staff_crystal", weight = 12 },
            { id = "bell_jade", weight = 12 },
            { id = "ring_silver", weight = 12 },
            { id = "neck_jade", weight = 10 },
            { id = "helm_bronze", weight = 10 },
            { id = "belt_leather", weight = 10 },
            { id = "boots_leather", weight = 10 },
        },
    },
    ["白野猪"] = {
        goldMin = 91, goldMax = 182, dropChance = 0.45,
        items = {
            { id = "sword_flame", weight = 14 },
            { id = "armor_chain", weight = 16 },
            { id = "ring_gold", weight = 14 },
            { id = "staff_thunder", weight = 12 },
            { id = "bell_soul", weight = 12 },
            { id = "helm_golden", weight = 10 },
            { id = "neck_amber", weight = 10 },
            { id = "brace_gold", weight = 10 },
            { id = "belt_chain", weight = 10 },
            { id = "boots_iron", weight = 10 },
        },
    },
    ["红野猪"] = {
        goldMin = 59, goldMax = 114, dropChance = 0.30,
        items = MENGZHONG_ITEMS,
    },
    ["黑野猪"] = {
        goldMin = 75, goldMax = 143, dropChance = 0.32,
        items = MENGZHONG_ITEMS,
    },
    ["狼"] = {
        goldMin = 29, goldMax = 65, dropChance = 0.28,
        items = {
            { id = "sword_steel", weight = 14 },
            { id = "armor_leather", weight = 16 },
            { id = "ring_silver", weight = 14 },
            { id = "staff_crystal", weight = 12 },
            { id = "bell_jade", weight = 12 },
            { id = "helm_bronze", weight = 10 },
            { id = "brace_silver", weight = 10 },
            { id = "belt_leather", weight = 10 },
            { id = "boots_leather", weight = 10 },
        },
    },
    ["石魔"] = {
        goldMin = 46, goldMax = 94, dropChance = 0.30,
        items = {
            { id = "armor_chain", weight = 16 },
            { id = "helm_golden", weight = 14 },
            { id = "belt_chain", weight = 14 },
            { id = "sword_flame", weight = 12 },
            { id = "staff_thunder", weight = 12 },
            { id = "bell_soul", weight = 12 },
            { id = "ring_gold", weight = 10 },
            { id = "neck_amber", weight = 10 },
            { id = "brace_gold", weight = 10 },
            { id = "boots_iron", weight = 10 },
        },
    },
    ["石像鬼"] = {
        goldMin = 104, goldMax = 182, dropChance = 0.31,
        items = WATER_CITY_ITEMS,
    },
    ["海妖"] = {
        goldMin = 117, goldMax = 208, dropChance = 0.33,
        items = WATER_CITY_ITEMS,
    },
    ["巨蜥"] = {
        goldMin = 136, goldMax = 234, dropChance = 0.35,
        items = WATER_CITY_ITEMS,
    },
    ["岩甲兽"] = {
        goldMin = 169, goldMax = 286, dropChance = 0.36,
        items = WOMAR_ITEMS,
    },
    ["黑鳞蟒"] = {
        goldMin = 195, goldMax = 325, dropChance = 0.38,
        items = WOMAR_ITEMS,
    },
    ["深渊恶鬼"] = {
        goldMin = 221, goldMax = 364, dropChance = 0.40,
        items = WOMAR_ITEMS,
    },
    ["熔岩巨兽"] = {
        goldMin = 273, goldMax = 442, dropChance = 0.42,
        items = ZUMA_ITEMS,
    },
    ["魔龙幼崽"] = {
        goldMin = 325, goldMax = 533, dropChance = 0.45,
        items = ZUMA_ITEMS,
    },
    ["祖玛卫士"] = {
        goldMin = 423, goldMax = 650, dropChance = 0.50,
        items = ZUMA_ITEMS,
    },
    ["蚁后"] = {
        goldMin = 65, goldMax = 123, dropChance = 0.40,
        items = {
            { id = "armor_chain", weight = 16 },
            { id = "neck_amber", weight = 14 },
            { id = "boots_iron", weight = 14 },
            { id = "sword_flame", weight = 12 },
            { id = "staff_thunder", weight = 12 },
            { id = "bell_soul", weight = 12 },
            { id = "ring_gold", weight = 10 },
            { id = "helm_golden", weight = 10 },
            { id = "brace_gold", weight = 10 },
            { id = "belt_chain", weight = 10 },
        },
    },
    ["骷髅将军"] = {
        goldMin = 88, goldMax = 162, dropChance = 0.42,
        items = {
            { id = "sword_flame", weight = 14 },
            { id = "staff_thunder", weight = 14 },
            { id = "bell_soul", weight = 14 },
            { id = "ring_gold", weight = 14 },
            { id = "armor_chain", weight = 12 },
            { id = "helm_golden", weight = 10 },
            { id = "neck_amber", weight = 10 },
            { id = "brace_gold", weight = 10 },
            { id = "belt_chain", weight = 10 },
            { id = "boots_iron", weight = 10 },
        },
    },
    ["赤焰魔"] = {
        goldMin = 130, goldMax = 234, dropChance = 0.44,
        items = {
            { id = "sword_dragon", weight = 14 },
            { id = "armor_dragon", weight = 16 },
            { id = "neck_dragon", weight = 14 },
            { id = "staff_arcane", weight = 12 },
            { id = "bell_holy", weight = 12 },
            { id = "ring_dragon", weight = 10 },
            { id = "helm_dragon", weight = 10 },
            { id = "brace_dragon", weight = 10 },
            { id = "belt_dragon", weight = 10 },
            { id = "boots_dragon", weight = 10 },
        },
    },
    ["巨蟒"] = {
        goldMin = 156, goldMax = 273, dropChance = 0.46,
        items = {
            { id = "staff_arcane", weight = 14 },
            { id = "bell_holy", weight = 14 },
            { id = "brace_dragon", weight = 14 },
            { id = "sword_dragon", weight = 12 },
            { id = "armor_dragon", weight = 12 },
            { id = "neck_dragon", weight = 12 },
            { id = "ring_dragon", weight = 10 },
            { id = "helm_dragon", weight = 10 },
            { id = "belt_dragon", weight = 10 },
            { id = "boots_dragon", weight = 10 },
        },
    },
    ["噬魂兽"] = {
        goldMin = 195, goldMax = 325, dropChance = 0.48,
        items = {
            { id = "ring_dragon", weight = 14 },
            { id = "helm_dragon", weight = 14 },
            { id = "belt_dragon", weight = 14 },
            { id = "sword_dragon", weight = 12 },
            { id = "staff_arcane", weight = 12 },
            { id = "bell_holy", weight = 12 },
            { id = "armor_dragon", weight = 12 },
            { id = "neck_dragon", weight = 10 },
            { id = "brace_dragon", weight = 10 },
            { id = "boots_dragon", weight = 10 },
        },
    },
    ["麒麟"] = {
        goldMin = 247, goldMax = 422, dropChance = 0.50,
        items = {
            { id = "boots_wind", weight = 14 },
            { id = "armor_heaven", weight = 12 },
            { id = "helm_heaven", weight = 12 },
            { id = "sword_dragon", weight = 12 },
            { id = "staff_arcane", weight = 12 },
            { id = "bell_holy", weight = 12 },
            { id = "ring_dragon", weight = 10 },
            { id = "neck_dragon", weight = 10 },
            { id = "brace_dragon", weight = 10 },
            { id = "belt_dragon", weight = 10 },
        },
    },
    ["沃玛教主"] = {
        goldMin = 293, goldMax = 488, dropChance = 0.55,
        items = {
            { id = "armor_heaven", weight = 14 },
            { id = "helm_heaven", weight = 14 },
            { id = "boots_wind", weight = 14 },
            { id = "sword_dragon", weight = 12 },
            { id = "staff_arcane", weight = 12 },
            { id = "bell_holy", weight = 12 },
            { id = "ring_dragon", weight = 10 },
            { id = "neck_dragon", weight = 10 },
            { id = "brace_dragon", weight = 10 },
            { id = "belt_dragon", weight = 10 },
        },
    },
    ["火龙王"] = {
        goldMin = 520, goldMax = 845, dropChance = 0.60,
        items = {
            { id = "armor_heaven", weight = 14 },
            { id = "helm_heaven", weight = 14 },
            { id = "boots_wind", weight = 14 },
        },
    },
    ["牛魔王"] = {
        goldMin = 780, goldMax = 1300, dropChance = 0.65,
        items = {
            { id = "armor_heaven", weight = 14 },
            { id = "helm_heaven", weight = 14 },
            { id = "boots_wind", weight = 14 },
        },
    },
}

return MonsterData
