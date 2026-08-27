-- ============================================================================
-- WeaponData.lua — 传奇经典三职业武器进阶链
-- 独立武器模板；由宿主合并到 Inventory.ITEM_TEMPLATES。
-- ============================================================================

local WeaponData = {}

-- 与 Inventory.SLOT.WEAPON 保持一致，避免此独立数据模块产生循环依赖。
local SLOT = {
    WEAPON = "weapon",
}

WeaponData.WEAPONS = {
    -- 武士
    { id = "sword_iron",   name = "乌木剑",   slot = SLOT.WEAPON, itemType = "weapon", rarity = "COMMON",    atk = 8,  def = 0, hp = 0,  classReq = "warrior" },
    { id = "sword_steel",  name = "八荒",     slot = SLOT.WEAPON, itemType = "weapon", rarity = "UNCOMMON",  atk = 15, def = 0, hp = 0,  classReq = "warrior" },
    { id = "sword_flame",  name = "炼狱",     slot = SLOT.WEAPON, itemType = "weapon", rarity = "RARE",      atk = 28, def = 0, hp = 0,  classReq = "warrior" },
    { id = "sword_jzy",    name = "井中月",   slot = SLOT.WEAPON, itemType = "weapon", rarity = "RARE",      atk = 22, def = 0, hp = 0,  classReq = "warrior" },
    { id = "sword_cjzz",   name = "裁决之杖", slot = SLOT.WEAPON, itemType = "weapon", rarity = "EPIC",      atk = 45, def = 0, hp = 0,  classReq = "warrior" },
    -- 屠龙是项目设定的唯一全职业通用传说武器；其它刀剑/法杖/道术武器均为职业专属。
    { id = "sword_dragon", name = "屠龙",     slot = SLOT.WEAPON, itemType = "weapon", rarity = "LEGENDARY", atk = 58, def = 2, hp = 50, classReq = nil },

    -- 法师
    { id = "staff_wood",    name = "乌木剑",   slot = SLOT.WEAPON, itemType = "weapon", rarity = "COMMON",    atk = 10, def = 0, hp = 0,  classReq = "mage" },
    { id = "staff_hs",      name = "海魂",     slot = SLOT.WEAPON, itemType = "weapon", rarity = "COMMON",    atk = 12, def = 0, hp = 0,  classReq = "mage" },
    { id = "staff_crystal", name = "偃月",     slot = SLOT.WEAPON, itemType = "weapon", rarity = "UNCOMMON",  atk = 18, def = 0, hp = 0,  classReq = "mage" },
    { id = "staff_thunder", name = "魔杖",     slot = SLOT.WEAPON, itemType = "weapon", rarity = "RARE",      atk = 32, def = 0, hp = 0,  classReq = "mage" },
    { id = "staff_arcane",  name = "骨玉权杖", slot = SLOT.WEAPON, itemType = "weapon", rarity = "EPIC",      atk = 50, def = 0, hp = 30, classReq = "mage" },
    { id = "staff_shfz",    name = "嗜魂法杖", slot = SLOT.WEAPON, itemType = "weapon", rarity = "LEGENDARY", atk = 62, def = 0, hp = 0,  classReq = "mage" },

    -- 道士
    { id = "bell_wm",    name = "乌木剑",   slot = SLOT.WEAPON, itemType = "weapon", rarity = "COMMON",    atk = 6,  def = 0, hp = 0,  classReq = "taoist" },
    { id = "bell_copper", name = "半月",     slot = SLOT.WEAPON, itemType = "weapon", rarity = "COMMON",    atk = 8,  def = 0, hp = 0,  classReq = "taoist" },
    { id = "bell_jade",   name = "降魔",     slot = SLOT.WEAPON, itemType = "weapon", rarity = "UNCOMMON",  atk = 14, def = 0, hp = 0,  classReq = "taoist" },
    { id = "bell_soul",   name = "无极棍",   slot = SLOT.WEAPON, itemType = "weapon", rarity = "RARE",      atk = 24, def = 2, hp = 20, classReq = "taoist" },
    { id = "bell_holy",   name = "龙纹剑",   slot = SLOT.WEAPON, itemType = "weapon", rarity = "EPIC",      atk = 40, def = 3, hp = 60, classReq = "taoist" },
    { id = "bell_xyjs",   name = "逍遥扇",   slot = SLOT.WEAPON, itemType = "weapon", rarity = "LEGENDARY", atk = 55, def = 0, hp = 0,  classReq = "taoist" },
}

return WeaponData
