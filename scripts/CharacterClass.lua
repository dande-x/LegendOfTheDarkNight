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
-- 设计目标: Lv1 普攻需要 3-5 下杀普通怪, 高级技能 2-3 下杀同级怪
-- ============================================================================
local BASE_GROWTH = {
    warrior = { hp = 40, mp = 8,  atk = 6, def = 4, speed = 3.5 },
    mage    = { hp = 22, mp = 25, atk = 8, def = 2, speed = 3.2 },
    taoist  = { hp = 30, mp = 18, atk = 5, def = 3, speed = 3.3 },
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
            {
                id = "w_basic", name = "基本剑术", type = SKILL_TYPE.MELEE,
                desc = "入门剑法，招式朴素，练就扎实根基",
                slot = 1, cooldown = 0, manaCost = 0,
                unlockLevel = 1,
                damage = 120,  -- ATK倍率120%
                range = 2.2, castTime = 0.35,
            },
            {
                id = "w_thrust", name = "刺杀剑术", type = SKILL_TYPE.RANGED,
                desc = "驭刀意为剑光，斩伤数丈外敌人",
                slot = 2, cooldown = 4, manaCost = 18,
                unlockLevel = 3,
                damage = 200,  -- ATK倍率200%
                range = 4.0,
            },
            {
                id = "w_crescent", name = "半月弯刀", type = SKILL_TYPE.MELEE,
                desc = "斩出新月弧光，横扫面前半月范围群敌",
                slot = 3, cooldown = 6, manaCost = 25,
                unlockLevel = 7,
                damage = 180,  -- ATK倍率180% (AOE所以略低)
                range = 3.0, aoeAngle = 180,
            },
            {
                id = "w_charge", name = "野蛮冲撞", type = SKILL_TYPE.DASH,
                desc = "剑术步法合一，力如奔牛冲向敌人",
                slot = 4, cooldown = 6, manaCost = 22,
                unlockLevel = 10,
                damage = 160,  -- ATK倍率160%
                range = 5.0,
            },
            {
                id = "w_fire", name = "烈火剑法", type = SKILL_TYPE.MELEE,
                desc = "内功吸纳天地之火，灌注刀刃，焰如怒龙",
                slot = 5, cooldown = 8, manaCost = 40,
                unlockLevel = 14,
                damage = 350,  -- ATK倍率350% (大招)
                range = 2.8, castTime = 0.35,
            },
            {
                id = "w_shield", name = "真气护盾", type = SKILL_TYPE.BUFF,
                desc = "运真气凝结护壁，吞噬外来攻击之力",
                slot = 6, cooldown = 7, manaCost = 30,
                unlockLevel = 12,
                shieldPercent = 50,
                duration = 6,
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
            {
                id = "m_fireball", name = "火球术", type = SKILL_TYPE.RANGED,
                desc = "以咒语化内力为火球，万法之基",
                slot = 1, cooldown = 0, manaCost = 0,
                unlockLevel = 1,
                damage = 110,  -- ATK倍率110%
                range = 6.0, projectileSpeed = 12, castTime = 0.45,
            },

            {
                id = "m_thunder", name = "雷电术", type = SKILL_TYPE.RANGED,
                desc = "引下天雷，威力巨大但施法较慢",
                slot = 3, cooldown = 5, manaCost = 28,
                unlockLevel = 5,
                damage = 250,  -- ATK倍率250% (单体高伤)
                range = 7.0, castTime = 0.8,
            },
            {
                id = "m_explosion", name = "爆裂火焰", type = SKILL_TYPE.AOE,
                desc = "瞬间高温爆发，大范围炸裂",
                slot = 4, cooldown = 6, manaCost = 32,
                unlockLevel = 8,
                damage = 200,  -- ATK倍率200% (大范围AOE)
                range = 6.0, aoeRadius = 3.0, castTime = 0.50,
            },
            {
                id = "m_firewall", name = "火墙", type = SKILL_TYPE.DOT,
                desc = "点燃不灭之火，烈焰如怨念般不息",
                slot = 5, cooldown = 7, manaCost = 30,
                unlockLevel = 11,
                damage = 45, -- ATK倍率45%/秒 (DOT持续)
                duration = 5,
                range = 6.0, aoeRadius = 2.0, castTime = 0.55,
            },
            {
                id = "m_blizzard", name = "冰咆哮", type = SKILL_TYPE.AOE,
                desc = "召唤冰雪暴风，刺骨寒意冻裂金铁",
                slot = 6, cooldown = 8, manaCost = 50,
                unlockLevel = 14,
                damage = 320,  -- ATK倍率320% (大招AOE)
                range = 6.0, aoeRadius = 3.5, castTime = 1.0,
            },
            {
                id = "m_shield", name = "魔法盾", type = SKILL_TYPE.BUFF,
                desc = "纯粹魔力凝成护盾，保命之本",
                slot = 0, cooldown = 8, manaCost = 45,
                unlockLevel = 12,
                shieldPercent = 40,
                duration = 25,
                range = 0,
            },
        },
    },

    -- ================================================================
    -- 道士 (神兽流)
    -- ================================================================
    taoist = {
        name = "道士",
        desc = "驭兽仙师，召唤喷火神兽碾压群敌",
        color = "Jade",
        resource = "道行",
        baseHP = 160, baseMP = 130, baseATK = 12, baseDEF = 12,
        growth = BASE_GROWTH.taoist,
        moveSpeed = 3.3,

        passive = {
            name = "灵兽契约",
            desc = "神兽攻击力 +25%，经验获取 +20%",
        },

        skills = {
            -- 1. 灵魂火符 (普攻 — 远程基础输出)
            {
                id = "t_talisman", name = "灵魂火符", type = SKILL_TYPE.RANGED,
                desc = "投掷灵符远距消耗，道士的基本功",
                slot = 1, cooldown = 0, manaCost = 0,
                unlockLevel = 1,
                damage = 100,  -- ATK倍率100%
                range = 10.0, projectileSpeed = 12, castTime = 0.38,
            },
            -- 2. 召唤神兽 (核心技 — 永久召唤一只喷火神兽)
            {
                id = "t_divineBeast", name = "召唤神兽", type = SKILL_TYPE.SUMMON,
                desc = "召唤远古神兽为随从，喷火焚敌，永不消散",
                slot = 2, cooldown = 8, manaCost = 45,
                unlockLevel = 1,
                damage = 150,  -- 神兽基础ATK倍率150%
                duration = -1, -- -1 表示永久
                summonCount = 1,
                summonType = "divineBeast",
                range = 2.0, castTime = 0.60,
            },
            -- 3. 神兽狂暴 (BUFF — 强化神兽攻击力)
            {
                id = "t_beastRage", name = "神兽狂暴", type = SKILL_TYPE.BUFF,
                desc = "激发神兽潜能，攻击力与攻速大幅提升",
                slot = 3, cooldown = 7, manaCost = 30,
                unlockLevel = 4,
                buffMultiplier = 2.0,
                duration = 10,
                range = 0,
            },
            -- 4. 施毒术 (DOT — 减防+持续伤害)
            {
                id = "t_poison", name = "施毒术", type = SKILL_TYPE.DOT,
                desc = "以灵力化毒，侵蚀敌人防御与生命",
                slot = 4, cooldown = 5, manaCost = 22,
                unlockLevel = 6,
                damage = 50, -- ATK倍率50%/秒
                duration = 5,
                defReduce = 5,
                range = 6.0, castTime = 0.35,
            },
            -- 5. 治愈术 (回复生命)
            {
                id = "t_heal", name = "治愈术", type = SKILL_TYPE.HEAL,
                desc = "引天地灵气修补自身与神兽，道士自保之术",
                slot = 5, cooldown = 10, manaCost = 25,
                unlockLevel = 8,
                healPercent = 35,
                range = 0,
            },
            -- 6. 困魔咒 (群控困敌 + 减防)
            {
                id = "t_trapDemon", name = "困魔咒", type = SKILL_TYPE.AOE,
                desc = "布下法阵困锁妖魔，圈内之敌无法逃脱且防御降低30%",
                slot = 6, cooldown = 12, manaCost = 50,
                unlockLevel = 12,
                damage = 0,  -- 不造成伤害，纯控制
                range = 8.0, aoeRadius = 3.5, castTime = 0.80,
                isTrap = true,  -- 标记为困魔类技能
                trapDuration = 6.0,  -- 困住6秒
                trapDefReducePercent = 30,  -- 降低30%防御
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
        expToNext = 50 + level * 60,

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

    -- 默认装配已解锁的 slot>0 技能
    for _, skill in ipairs(classDef.skills) do
        if skill.slot >= 1 and skill.slot <= 6 and CharacterClass.IsSkillUnlocked(skill, player.level) then
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

--- 检查技能是否已解锁 (基于角色等级)
--- @return boolean 是否已解锁
function CharacterClass.IsSkillUnlocked(skill, playerLevel)
    if not skill or not skill.unlockLevel then return false end
    return playerLevel >= skill.unlockLevel
end

--- 检查技能是否可释放
function CharacterClass.CanCastSkill(player, skill)
    if not skill then return false, "无技能" end
    if not CharacterClass.IsSkillUnlocked(skill, player.level) then return false, "等级不足" end
    if player.cooldowns[skill.id] > 0 then return false, "冷却中" end
    if player.mp < skill.manaCost then return false, "灵力不足" end
    return true, ""
end

--- 升级
--- @return string[]|nil newlyUnlocked 本次升级新解锁的技能名列表
function CharacterClass.LevelUp(player)
    local classDef = CharacterClass.Classes[player.classId]
    local g = classDef.growth
    local prevLevel = player.level
    player.level = player.level + 1
    local Inventory = require("Inventory")
    local bonusHP = Inventory.playerData.bonusHP or 0
    player.maxHP = classDef.baseHP + g.hp * (player.level - 1) + bonusHP
    player.maxMP = classDef.baseMP + g.mp * (player.level - 1)
    player.atk   = classDef.baseATK + g.atk * (player.level - 1)
    player.def   = classDef.baseDEF + g.def * (player.level - 1)
    player.hp = player.maxHP
    player.mp = player.maxMP
    player.expToNext = 50 + player.level * 60
    print("[CharacterClass] " .. classDef.name .. " upgraded to Lv." .. player.level)

    -- 自动装备本次升级新解锁的技能
    local newlyUnlocked = {}
    for _, skill in ipairs(classDef.skills) do
        if skill.unlockLevel == player.level then
            -- 刚好在本级解锁
            table.insert(newlyUnlocked, skill.name)
            -- 自动装备到对应 slot（如果 slot 为空）
            if skill.slot >= 1 and skill.slot <= 6 and player.equippedSkills[skill.slot] == nil then
                player.equippedSkills[skill.slot] = skill
            end
        end
    end

    if #newlyUnlocked > 0 then
        print("[CharacterClass] 新解锁技能: " .. table.concat(newlyUnlocked, ", "))
    end
    return #newlyUnlocked > 0 and newlyUnlocked or nil
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
