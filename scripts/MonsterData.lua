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

-- 新增怪物定义。字段与 Combat.ENEMY_DEFS 的定义项保持一致。
MonsterData.NEW_ENEMIES = {
    {
        name = "蛤蟆", monsterType = "scarecrow",
        level = 2, hp = 100, atk = 9, def = 3,
        speed = 2.4, chaseRange = 7, attackRange = 1.5, attackCD = 1.8,
        exp = 38, scale = 0.9, tier = "normal",
    },
    {
        name = "多钩猫", monsterType = "deer",
        level = 3, hp = 115, atk = 11, def = 4,
        speed = 3.0, chaseRange = 8, attackRange = 1.5, attackCD = 1.6,
        exp = 45, scale = 0.95, tier = "normal",
    },
    {
        name = "钉耙猫", monsterType = "deer",
        level = 4, hp = 130, atk = 13, def = 5,
        speed = 3.1, chaseRange = 8, attackRange = 1.5, attackCD = 1.5,
        exp = 52, scale = 0.95, tier = "normal",
    },
    {
        name = "半兽勇士", monsterType = "orc",
        level = 9, hp = 280, atk = 22, def = 9,
        speed = 2.2, chaseRange = 9, attackRange = 1.5, attackCD = 2.0,
        exp = 110, scale = 1.2, tier = "elite",
    },
    {
        name = "白野猪", monsterType = "orc",
        level = 20, hp = 1800, atk = 40, def = 18,
        speed = 1.5, chaseRange = 12, attackRange = 1.8, attackCD = 2.8,
        exp = 900, scale = 2.2, tier = "boss",
    },
}

-- 补充掉落表。key 使用 Combat 改名后的经典怪物名。
MonsterData.DROP_TABLES = {
    ["蛤蟆"] = {
        goldMin = 6, goldMax = 16, dropChance = 0.35,
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
        goldMin = 8, goldMax = 20, dropChance = 0.38,
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
        goldMin = 10, goldMax = 24, dropChance = 0.40,
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
        goldMin = 35, goldMax = 80, dropChance = 0.50,
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
        goldMin = 140, goldMax = 280, dropChance = 0.70,
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
    ["狼"] = {
        goldMin = 45, goldMax = 100, dropChance = 0.52,
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
        goldMin = 70, goldMax = 145, dropChance = 0.55,
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
    ["蚁后"] = {
        goldMin = 100, goldMax = 190, dropChance = 0.60,
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
        goldMin = 135, goldMax = 250, dropChance = 0.65,
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
        goldMin = 200, goldMax = 360, dropChance = 0.68,
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
        goldMin = 240, goldMax = 420, dropChance = 0.70,
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
        goldMin = 300, goldMax = 500, dropChance = 0.72,
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
        goldMin = 380, goldMax = 650, dropChance = 0.75,
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
        goldMin = 450, goldMax = 750, dropChance = 0.78,
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
        goldMin = 800, goldMax = 1300, dropChance = 0.85,
        items = {
            { id = "armor_heaven", weight = 14 },
            { id = "helm_heaven", weight = 14 },
            { id = "boots_wind", weight = 14 },
        },
    },
    ["牛魔王"] = {
        goldMin = 1200, goldMax = 2000, dropChance = 0.90,
        items = {
            { id = "armor_heaven", weight = 14 },
            { id = "helm_heaven", weight = 14 },
            { id = "boots_wind", weight = 14 },
        },
    },
}

return MonsterData
