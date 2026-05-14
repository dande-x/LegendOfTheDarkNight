-- ============================================================================
-- CharacterClass.lua — 传奇·山海 三职业数据定义
-- 武士 / 法师 / 道士 完整技能表 + 属性成长
-- ============================================================================

local CharacterClass = {}

-- ============================================================================
-- 中国风配色方案
-- ============================================================================
CharacterClass.Colors = {
    Ink       = Color(0.16, 0.16, 0.18, 1.0),   -- 墨色
    Vermilion = Color(0.75, 0.20, 0.15, 1.0),   -- 朱红 (武士)
    Azure     = Color(0.27, 0.55, 0.67, 1.0),   -- 青蓝 (法师)
    Jade      = Color(0.20, 0.60, 0.35, 1.0),   -- 翠绿 (道士)
    Gold      = Color(0.80, 0.68, 0.32, 1.0),   -- 鎏金
    Cream     = Color(0.92, 0.90, 0.85, 1.0),   -- 素白
    Floor     = Color(0.30, 0.30, 0.32, 1.0),   -- 青灰地面
    EnemyRed  = Color(0.65, 0.15, 0.15, 1.0),   -- 敌人红
    EnemyDark = Color(0.30, 0.10, 0.30, 1.0),   -- 敌人暗紫
    HpRed     = {220, 70, 60, 255},              -- UI 血条
    MpBlue    = {70, 140, 190, 255},             -- UI 蓝条
    ExpGold   = {210, 180, 80, 255},             -- UI 经验
}

-- ============================================================================
-- 技能类型常量
-- ============================================================================
local SKILL_TYPE = {
    PASSIVE   = "passive",   -- 被动
    MELEE     = "melee",     -- 近战单体
    RANGED    = "ranged",    -- 远程单体
    AOE       = "aoe",       -- 范围攻击
    BUFF      = "buff",      -- 增益/护盾
    HEAL      = "heal",      -- 治疗
    DOT       = "dot",       -- 持续伤害
    DASH      = "dash",      -- 位移
    SUMMON    = "summon",    -- 召唤
}
CharacterClass.SKILL_TYPE = SKILL_TYPE

-- ============================================================================
-- 基础属性成长 (每升一级增加)
-- ============================================================================
local BASE_GROWTH = {
    warrior = { hp = 35, mp = 8,  atk = 5, def = 4, speed = 3.5 },
    mage    = { hp = 18, mp = 25, atk = 7, def = 2, speed = 3.2 },
    taoist  = { hp = 25, mp = 18, atk = 4, def = 3, speed = 3.3 },
}

-- ============================================================================
-- 职业定义
-- ============================================================================
CharacterClass.Classes = {

    -- ================================================================
    -- 武士
    -- ================================================================
    warrior = {
        name = "武士",
        desc = "近战物理输出，前排突破",
        color = "Vermilion",
        resource = "气力",
        baseHP = 200, baseMP = 60, baseATK = 18, baseDEF = 15,
        growth = BASE_GROWTH.warrior,
        moveSpeed = 3.5,

        passive = {
            name = "铁骨",
            desc = "生命上限 +20%，受击减伤概率",
        },

        skills = {
            -- 1. 基本剑术 (普攻)
            {
                id = "w_basic", name = "基本剑术", type = SKILL_TYPE.MELEE,
                desc = "入门剑法，招式朴素，练就扎实根基",
                slot = 1, cooldown = 0, manaCost = 0,
                unlockLevels = {7, 13, 19},
                damage = {100, 120, 150},
                range = 1.5,
            },
            -- 2. 攻杀剑术
            {
                id = "w_power", name = "攻杀剑术", type = SKILL_TYPE.MELEE,
                desc = "运气丹田，内力灌注刀刃，瞬间爆发数倍之力",
                slot = 2, cooldown = 8, manaCost = 10,
                unlockLevels = {22, 25, 29},
                damage = {250, 320, 420},
                range = 1.8,
            },
            -- 3. 刺杀剑术
            {
                id = "w_thrust", name = "刺杀剑术", type = SKILL_TYPE.RANGED,
                desc = "驭刀意为剑光，斩伤数丈外敌人",
                slot = 3, cooldown = 6, manaCost = 12,
                unlockLevels = {28, 32, 36},
                damage = {180, 240, 320},
                range = 4.0,
            },
            -- 4. 半月弯刀
            {
                id = "w_crescent", name = "半月弯刀", type = SKILL_TYPE.AOE,
                desc = "斩出新月弧光，横扫邻近群敌",
                slot = 4, cooldown = 10, manaCost = 18,
                unlockLevels = {32, 36, 41},
                damage = {200, 260, 340},
                range = 2.5, aoeAngle = 180,
            },
            -- 5. 野蛮冲撞
            {
                id = "w_charge", name = "野蛮冲撞", type = SKILL_TYPE.DASH,
                desc = "剑术步法合一，力如奔牛冲向敌人",
                slot = 5, cooldown = 12, manaCost = 15,
                unlockLevels = {33, 38, 44},
                damage = {150, 200, 260},
                range = 5.0,
            },
            -- 6. 烈火剑法 (终极技)
            {
                id = "w_fire", name = "烈火剑法", type = SKILL_TYPE.MELEE,
                desc = "内功吸纳天地之火，灌注刀刃，焰如怒龙",
                slot = 6, cooldown = 25, manaCost = 25,
                unlockLevels = {38, 42, 47},
                damage = {450, 570, 680},
                range = 2.0, isUltimate = true,
            },
            -- 7. 真气护盾 (可替换装配)
            {
                id = "w_shield", name = "真气护盾", type = SKILL_TYPE.BUFF,
                desc = "运真气凝结护壁，吞噬外来攻击之力",
                slot = 0, cooldown = 18, manaCost = 20,
                unlockLevels = {40, 44, 48},
                damage = {0, 0, 0},
                shieldPercent = {30, 40, 50},
                duration = {5, 5, 6},
                range = 0,
            },
        },
    },

    -- ================================================================
    -- 法师
    -- ================================================================
    mage = {
        name = "法师",
        desc = "远程法术输出，范围清场",
        color = "Azure",
        resource = "灵力",
        baseHP = 120, baseMP = 150, baseATK = 22, baseDEF = 8,
        growth = BASE_GROWTH.mage,
        moveSpeed = 3.2,

        passive = {
            name = "灵慧",
            desc = "法术伤害 +25%，灵力回复 +15%",
        },

        skills = {
            -- 1. 火球术 (普攻)
            {
                id = "m_fireball", name = "火球术", type = SKILL_TYPE.RANGED,
                desc = "以咒语化内力为火球，万法之基",
                slot = 1, cooldown = 0, manaCost = 0,
                unlockLevels = {7, 13, 19},
                damage = {90, 110, 140},
                range = 6.0, projectileSpeed = 12,
            },
            -- 2. 地狱火
            {
                id = "m_hellfire", name = "地狱火", type = SKILL_TYPE.AOE,
                desc = "直线喷射烈焰，灼烧一列敌人",
                slot = 2, cooldown = 7, manaCost = 15,
                unlockLevels = {18, 24, 31},
                damage = {160, 200, 260},
                range = 5.0, maxTargets = {3, 4, 5},
            },
            -- 3. 雷电术
            {
                id = "m_thunder", name = "雷电术", type = SKILL_TYPE.RANGED,
                desc = "引下天雷，威力巨大但施法较慢",
                slot = 3, cooldown = 9, manaCost = 18,
                unlockLevels = {19, 23, 28},
                damage = {220, 290, 360},
                range = 7.0, castTime = 0.8,
            },
            -- 4. 爆裂火焰
            {
                id = "m_explosion", name = "爆裂火焰", type = SKILL_TYPE.AOE,
                desc = "瞬间高温爆发，3x3 范围炸裂",
                slot = 4, cooldown = 10, manaCost = 22,
                unlockLevels = {25, 30, 36},
                damage = {200, 260, 340},
                range = 6.0, aoeRadius = 3.0,
            },
            -- 5. 火墙
            {
                id = "m_firewall", name = "火墙", type = SKILL_TYPE.DOT,
                desc = "点燃不灭之火，烈焰如怨念般不息",
                slot = 5, cooldown = 14, manaCost = 20,
                unlockLevels = {27, 33, 39},
                damage = {60, 80, 100}, -- 每秒伤害
                duration = {5, 7, 9},
                range = 6.0, aoeRadius = 2.0,
            },
            -- 6. 冰咆哮 (终极技)
            {
                id = "m_blizzard", name = "冰咆哮", type = SKILL_TYPE.AOE,
                desc = "召唤冰雪暴风，刺骨寒意冻裂金铁",
                slot = 6, cooldown = 28, manaCost = 35,
                unlockLevels = {40, 44, 48},
                damage = {350, 480, 580},
                range = 6.0, aoeRadius = 3.5, isUltimate = true,
            },
            -- 7. 魔法盾 (可替换装配)
            {
                id = "m_shield", name = "魔法盾", type = SKILL_TYPE.BUFF,
                desc = "纯粹魔力凝成护盾，保命之本",
                slot = 0, cooldown = 30, manaCost = 30,
                unlockLevels = {35, 40, 45},
                damage = {0, 0, 0},
                shieldPercent = {20, 30, 40},
                duration = {15, 20, 25},
                range = 0,
            },
        },
    },

    -- ================================================================
    -- 道士
    -- ================================================================
    taoist = {
        name = "道士",
        desc = "召唤/治疗/持续消耗 混合型",
        color = "Jade",
        resource = "道行",
        baseHP = 160, baseMP = 120, baseATK = 14, baseDEF = 12,
        growth = BASE_GROWTH.taoist,
        moveSpeed = 3.3,

        passive = {
            name = "通灵",
            desc = "召唤兽持续 +20%，治疗效果 +15%",
        },

        skills = {
            -- 1. 治愈术 (普攻/基础治疗)
            {
                id = "t_heal", name = "治愈术", type = SKILL_TYPE.HEAL,
                desc = "引天地灵气修补伤损",
                slot = 1, cooldown = 6, manaCost = 8,
                unlockLevels = {7, 13, 19},
                healPercent = {15, 22, 30},
                range = 0,
            },
            -- 2. 施毒术
            {
                id = "t_poison", name = "施毒术", type = SKILL_TYPE.DOT,
                desc = "将毒理升华为道法，降防蚕食体力",
                slot = 2, cooldown = 8, manaCost = 10,
                unlockLevels = {16, 20, 25},
                damage = {40, 55, 70}, -- 每秒
                duration = {6, 6, 8},
                defReduce = {15, 25, 35},
                range = 5.0,
            },
            -- 3. 灵魂火符
            {
                id = "t_talisman", name = "灵魂火符", type = SKILL_TYPE.RANGED,
                desc = "投掷爆发护身符，远距引诱消耗",
                slot = 3, cooldown = 3, manaCost = 5,
                unlockLevels = {21, 25, 29},
                damage = {120, 160, 200},
                range = 6.0, projectileSpeed = 10,
            },
            -- 4. 召唤神兽
            {
                id = "t_summon", name = "召唤神兽", type = SKILL_TYPE.SUMMON,
                desc = "精神力打通灵界，唤神兽相助",
                slot = 4, cooldown = 20, manaCost = 25,
                unlockLevels = {22, 27, 33},
                damage = {80, 110, 150}, -- 神兽攻击力
                duration = {30, 40, 50},
                range = 2.0,
            },
            -- 5. 群体治疗术
            {
                id = "t_groupheal", name = "群体治疗", type = SKILL_TYPE.HEAL,
                desc = "同时治愈多人，消耗极大",
                slot = 5, cooldown = 22, manaCost = 30,
                unlockLevels = {36, 40, 45},
                healPercent = {12, 18, 25},
                range = 0, aoeRadius = 5.0,
            },
            -- 6. 圣兽降临 (终极技)
            {
                id = "t_holyBeast", name = "圣兽降临", type = SKILL_TYPE.SUMMON,
                desc = "唤出圣兽，满阶化身麒麟圣灵",
                slot = 6, cooldown = 40, manaCost = 40,
                unlockLevels = {40, 44, 48},
                damage = {160, 220, 300},
                duration = {25, 35, 45},
                range = 2.0, isUltimate = true,
            },
            -- 7. 道力盾 (可替换装配)
            {
                id = "t_shield", name = "道力盾", type = SKILL_TYPE.BUFF,
                desc = "真气凝结护体之膜，源自魔法盾改良",
                slot = 0, cooldown = 20, manaCost = 18,
                unlockLevels = {40, 44, 48},
                damage = {0, 0, 0},
                shieldPercent = {25, 35, 45},
                duration = {5, 6, 7},
                range = 0,
            },
        },
    },
}

-- ============================================================================
-- 工具函数
-- ============================================================================

--- 创建角色实例
function CharacterClass.CreatePlayer(classId, level)
    local classDef = CharacterClass.Classes[classId]
    if not classDef then
        print("[CharacterClass] ERROR: unknown class " .. tostring(classId))
        return nil
    end

    level = level or 1
    local g = classDef.growth

    local player = {
        classId   = classId,
        className = classDef.name,
        level     = level,
        exp       = 0,
        expToNext = level * 100,

        maxHP  = classDef.baseHP + g.hp * (level - 1),
        maxMP  = classDef.baseMP + g.mp * (level - 1),
        hp     = 0, -- 后面赋满
        mp     = 0,
        atk    = classDef.baseATK + g.atk * (level - 1),
        def    = classDef.baseDEF + g.def * (level - 1),
        moveSpeed = classDef.moveSpeed,

        -- 技能冷却状态 (id → remaining cd)
        cooldowns = {},
        -- 当前装配的6技能 (slot 1-6)
        equippedSkills = {},

        -- 召唤兽相关
        summonNode = nil,
        summonTimer = 0,

        -- 护盾
        shieldHP = 0,
        shieldTimer = 0,

        -- buff/debuff
        buffs = {},
    }
    player.hp = player.maxHP
    player.mp = player.maxMP

    -- 默认装配前6个 slot>0 的技能
    for _, skill in ipairs(classDef.skills) do
        if skill.slot >= 1 and skill.slot <= 6 then
            player.equippedSkills[skill.slot] = skill
        end
    end

    -- 初始化冷却
    for _, skill in ipairs(classDef.skills) do
        player.cooldowns[skill.id] = 0
    end

    print("[CharacterClass] Created " .. classDef.name .. " Lv." .. level)
    return player
end

--- 获取技能当前等级 (基于角色等级)
function CharacterClass.GetSkillLevel(skill, playerLevel)
    local lvl = 0
    for i, reqLv in ipairs(skill.unlockLevels) do
        if playerLevel >= reqLv then
            lvl = i
        end
    end
    return lvl
end

--- 检查技能是否可释放
function CharacterClass.CanCastSkill(player, skill)
    if not skill then return false, "无技能" end
    local slvl = CharacterClass.GetSkillLevel(skill, player.level)
    if slvl == 0 then return false, "等级不足" end
    if player.cooldowns[skill.id] > 0 then return false, "冷却中" end
    if player.mp < skill.manaCost then return false, "灵力不足" end
    return true, ""
end

--- 升级
function CharacterClass.LevelUp(player)
    local classDef = CharacterClass.Classes[player.classId]
    local g = classDef.growth
    player.level = player.level + 1
    player.maxHP = classDef.baseHP + g.hp * (player.level - 1)
    player.maxMP = classDef.baseMP + g.mp * (player.level - 1)
    player.atk   = classDef.baseATK + g.atk * (player.level - 1)
    player.def   = classDef.baseDEF + g.def * (player.level - 1)
    player.hp = player.maxHP
    player.mp = player.maxMP
    player.expToNext = player.level * 100
    print("[CharacterClass] " .. classDef.name .. " upgraded to Lv." .. player.level)
end

--- 更新冷却
function CharacterClass.UpdateCooldowns(player, dt)
    for id, cd in pairs(player.cooldowns) do
        if cd > 0 then
            player.cooldowns[id] = math.max(0, cd - dt)
        end
    end
    -- 护盾衰减
    if player.shieldTimer > 0 then
        player.shieldTimer = player.shieldTimer - dt
        if player.shieldTimer <= 0 then
            player.shieldHP = 0
        end
    end
    -- MP 自然恢复
    local regenRate = 2 -- 每秒恢复
    player.mp = math.min(player.maxMP, player.mp + regenRate * dt)
end

return CharacterClass
