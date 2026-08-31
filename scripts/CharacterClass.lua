-- ============================================================================
-- CharacterClass.lua — 暗夜传奇 三职业数据定义
-- 武士 / 法师 / 道士 完整技能表 + 属性成长
-- ============================================================================

local CharacterClass = {}
local Balance = require("scripts.Balance")

-- 兼容旧调用方；Balance.MAX_LEVEL 是 math.huge，仅作“不设玩法上限”的哨兵。
CharacterClass.MAX_LEVEL = Balance.MAX_LEVEL
local LEVEL_SANITY_LIMIT = Balance.LEVEL_SANITY_LIMIT

local function IsFiniteNumber(value)
    return type(value) == "number"
        and value == value
        and value ~= math.huge
        and value ~= -math.huge
end

function CharacterClass.NormalizeLevel(level)
    return Balance.NormalizeLevel(level)
end

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
    warrior = { hp = 40, mp = 8,  atk = 6, def = 1.8, speed = 3.5 },
    mage    = { hp = 22, mp = 25, atk = 8, def = 1.0, speed = 3.2 },
    taoist  = { hp = 30, mp = 18, atk = 5, def = 1.4, speed = 3.3 },
}

-- 职业被动运行时参数。此前这些内容只有 UI 描述，没有真正参与数值结算。
CharacterClass.PASSIVE_MODIFIERS = {
    warrior = {
        maxHPMultiplier = 1.20,
        damageReductionChance = 0.20,
        damageReductionMultiplier = 0.75,
    },
    mage = {
        spellDamageMultiplier = 1.20,
        mpRegenMultiplier = 1.15,
    },
    taoist = {
        divineBeastAttackMultiplier = 1.20,
        healingMultiplier = 1.10,
    },
}

-- 全职业共用统一升级曲线。职业差异只影响战斗，不再让道士提前十多级毕业；
-- Lv.50 之后继续沿用同一曲线。
function CharacterClass.GetExpToNext(level)
    return Balance.GetExpToNext(level)
end

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
        moveSpeed = 4.55,

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
                range = 1.5, castTime = 0.35,  -- 基本剑术触及(挨着, 约1身位)
            },
            {
                id = "w_crescent", name = "半月弯刀", type = SKILL_TYPE.MELEE,
                desc = "斩出新月弧光，横扫面前半月范围群敌",
                slot = 2, cooldown = 4, manaCost = 25,
                unlockLevel = 6,
                damage = 130,  -- ATK倍率130% (AOE提前解锁，降低单次伤害)
                range = 3.0, aoeAngle = 270,
            },
            {
                id = "w_thrust", name = "刺杀剑术", type = SKILL_TYPE.PASSIVE,
                desc = "隔敌人一个身位攻击，可以凌空斩出白色剑气，大幅穿透其防御。",
                slot = 0, cooldown = 0, manaCost = 0,  -- 被动:随基本剑术触发,不占技能栏/不耗蓝
                unlockLevel = 10,
                damage = 200,  -- 补刀ATK倍率200% (增强/穿透系数见 Combat.lua 身位常量)
                range = 3.0,   -- 触及距离(隔一身位), 与 Combat.ASSASSIN_REACH 对应
            },
            {
                id = "w_earthsplit", name = "地裂斩", type = SKILL_TYPE.AOE,
                desc = "猛劈地面，向前掀起一道连续爆裂的地裂波，对直线范围内的群敌造成伤害",
                slot = 3, cooldown = 6.5, manaCost = 35,
                unlockLevel = 20,
                damage = 220,  -- ATK倍率220%；穿透式地面波可命中直线内多个目标
                range = 6.0, aoeRadius = 1.35,
                waveSpeed = 11.0, isGroundWave = true,
                castTime = 0.55, animationType = "buff", -- 重劈动作，而不是回旋 AOE 动作
            },
            {
                id = "w_charge", name = "野蛮冲撞", type = SKILL_TYPE.DASH,
                desc = "剑术步法合一，力如奔牛全力冲刺。沿途顶推前方之敌一同推进，于终点将其撞出至刺杀剑术触及之距，敌僵直约一秒难动",
                slot = 4, cooldown = 6, manaCost = 22,
                unlockLevel = 25,
                range = 5.0,    -- 冲刺距离(米)；本技能无直接伤害，靠顶推+硬直创造刺杀机会
            },
            {
                id = "w_shield", name = "真气护盾", type = SKILL_TYPE.BUFF,
                desc = "运真气凝结护壁，吞噬外来攻击之力",
                slot = 5, cooldown = 14, manaCost = 45,
                unlockLevel = 30,
                shieldPercent = 30,
                duration = 4,
                range = 0,
            },
            {
                id = "w_fire", name = "烈火剑法", type = SKILL_TYPE.MELEE,
                desc = "内功吸纳天地之火，灌注刀刃，焰如怒龙",
                slot = 6, cooldown = 8, manaCost = 40,
                unlockLevel = 35,
                damage = 420,  -- ATK倍率420% (大招，较原值提升20%)
                range = 2.8, castTime = 0.35,
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
        moveSpeed = 4.16,

        passive = {
            name = "灵慧",
            desc = "法术伤害 +20%，灵力回复 +15%",
        },

        skills = {
            {
                id = "m_fireball", name = "火球术", type = SKILL_TYPE.RANGED,
                desc = "以咒语化内力为火球，万法之基",
                slot = 1, cooldown = 0, manaCost = 0,
                unlockLevel = 1,
                damage = 110, -- 提高单发伤害，配合略长前摇维持前期总DPS
                range = 8.0, projectileSpeed = 12, castTime = 0.35,
            },

            {
                id = "m_thunder", name = "雷电术", type = SKILL_TYPE.RANGED,
                desc = "引下天雷，威力巨大但施法较慢",
                slot = 3, cooldown = 3.5, manaCost = 55,
                -- 法师主动技能解锁节奏与武士统一；跳过武士专属被动的 Lv.10 节点。
                unlockLevel = 25,
                damage = 250,  -- ATK倍率250% (单体高伤)
                range = 8.0, castTime = 0.45,
            },
            {
                id = "m_explosion", name = "抗拒火环", type = SKILL_TYPE.AOE,
                desc = "周身迸发烈焰火环，将逼近之敌尽数震退（无直接伤害）",
                slot = 4, cooldown = 4.0, manaCost = 60,
                unlockLevel = 15,
                isKnockback = true,        -- 纯击退技能，无直接伤害
                knockbackSpeed = 14,       -- 推开速度(米/秒)
                knockbackDuration = 0.4,   -- 击退持续时间(秒)，推开距离≈speed×duration
                range = 3.5, aoeRadius = 3.5, castTime = 0.25,
            },
            {
                id = "m_firewall", name = "火墙", type = SKILL_TYPE.DOT,
                desc = "点燃不灭之火，烈焰如怨念般不息",
                slot = 5, cooldown = 5.0, manaCost = 55,
                unlockLevel = 6,
                damage = 45, -- ATK倍率45%/秒 (DOT持续)
                duration = 5,
                range = 8.0, aoeRadius = 2.0, castTime = 0.30,
            },
            {
                id = "m_blizzard", name = "冰咆哮", type = SKILL_TYPE.AOE,
                desc = "召唤冰雪暴风，刺骨寒意冻裂金铁",
                slot = 6, cooldown = 5.5, manaCost = 90,
                unlockLevel = 35,
                damage = 320,  -- ATK倍率320% (大招AOE)
                range = 8.0, aoeRadius = 3.5, castTime = 0.55,
            },
            {
                id = "m_shield", name = "魔法盾", type = SKILL_TYPE.BUFF,
                desc = "纯粹魔力凝成护盾，保命之本",
                slot = 0, cooldown = 12, manaCost = 75,
                unlockLevel = 30,
                shieldPercent = 25,
                duration = 4,
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
        moveSpeed = 4.29,

        passive = {
            name = "灵兽契约",
            desc = "神兽攻击力 +20%，治愈效果 +10%",
        },

        skills = {
            -- 1. 灵魂火符 (普攻 — 远程基础输出)
            {
                id = "t_talisman", name = "灵魂火符", type = SKILL_TYPE.RANGED,
                desc = "投掷灵符远距消耗，道士的基本功",
                slot = 1, cooldown = 0, manaCost = 0,
                unlockLevel = 1,
                damage = 100,  -- ATK倍率100%
                range = 8.0, projectileSpeed = 12, castTime = 0.38,
            },
            -- 2. 召唤神兽 (核心技 — 永久召唤一只喷火神兽)
            {
                id = "t_divineBeast", name = "召唤神兽", type = SKILL_TYPE.SUMMON,
                desc = "召唤远古神兽为随从，喷火焚敌，永不消散",
                slot = 2, cooldown = 8, manaCost = 65,
                unlockLevel = 1,
                damage = Balance.DIVINE_BEAST_ATK_PERCENT,  -- 神兽基础ATK倍率
                duration = -1, -- -1 表示永久
                summonCount = 1,
                summonType = "divineBeast",
                range = 2.0, castTime = 0.60,
            },
            -- 3. 治愈术 (回复生命)
            {
                id = "t_heal", name = "治愈术", type = SKILL_TYPE.HEAL,
                desc = "引天地灵气修补自身与神兽，道士自保之术",
                slot = 3, cooldown = 12, manaCost = 60,
                unlockLevel = 8,
                healPercent = 25,
                range = 0,
            },
            -- 4. 施毒术 (瞬发群体中毒 — 圆形范围)
            {
                id = "t_poison", name = "施毒术", type = SKILL_TYPE.DOT,
                desc = "瞬间释放毒雾，使命中范围内妖魔中毒5秒",
                slot = 4, cooldown = 7, manaCost = 50,
                unlockLevel = 16,
                damage = 50, -- ATK倍率50%/秒
                duration = 5,
                defReduce = 5,
                range = 8.0, aoeRadius = 2.5, castTime = 0.0, instant = true,
            },
            -- 5. 神兽狂暴 (BUFF — 强化神兽攻击力)
            {
                id = "t_beastRage", name = "神兽狂暴", type = SKILL_TYPE.BUFF,
                desc = "激发神兽潜能，攻击力与攻速大幅提升",
                slot = 5, cooldown = 18, manaCost = 55,
                unlockLevel = 28,
                buffMultiplier = 1.6,
                duration = 7,
                range = 0,
            },
            -- 6. 困魔咒 (群控困敌 + 减防)
            {
                id = "t_trapDemon", name = "困魔咒", type = SKILL_TYPE.AOE,
                desc = "布下法阵困锁妖魔，圈内之敌无法逃脱且防御降低30%",
                slot = 6, cooldown = 12, manaCost = 70,
                unlockLevel = 40,
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
-- 职业被动与派生属性
-- ============================================================================

---@param playerOrClass table|string|nil
---@return table
function CharacterClass.GetPassiveModifiers(playerOrClass)
    local classId = playerOrClass
    if type(playerOrClass) == "table" then
        classId = playerOrClass.classId
    end
    return CharacterClass.PASSIVE_MODIFIERS[classId] or {}
end

---@param player table
---@param skill table|nil
---@return number
function CharacterClass.GetSkillDamageMultiplier(player, skill)
    local modifiers = CharacterClass.GetPassiveModifiers(player)
    if modifiers.spellDamageMultiplier and skill and skill.type ~= SKILL_TYPE.PASSIVE
        and (tonumber(skill.manaCost) or 0) > 0 then
        return modifiers.spellDamageMultiplier
    end
    return 1.0
end

---@param player table
---@return number
function CharacterClass.GetExperienceMultiplier(player)
    local modifiers = CharacterClass.GetPassiveModifiers(player)
    return modifiers.experienceMultiplier or 1.0
end

---@param player table
---@return number
function CharacterClass.GetHealingMultiplier(player)
    local modifiers = CharacterClass.GetPassiveModifiers(player)
    return modifiers.healingMultiplier or 1.0
end

---@param player table
---@return number
function CharacterClass.GetDivineBeastAttackMultiplier(player)
    local modifiers = CharacterClass.GetPassiveModifiers(player)
    return modifiers.divineBeastAttackMultiplier or 1.0
end

---@param player table
---@return number
function CharacterClass.GetMPRegenRate(player)
    local modifiers = CharacterClass.GetPassiveModifiers(player)
    return 1.25 * (modifiers.mpRegenMultiplier or 1.0)
end

---@param player table
---@return number
function CharacterClass.GetIncomingDamageMultiplier(player)
    local modifiers = CharacterClass.GetPassiveModifiers(player)
    return modifiers.damageReductionMultiplier or 1.0
end

---@param player table
---@return boolean
function CharacterClass.RollIncomingDamageReduction(player)
    local modifiers = CharacterClass.GetPassiveModifiers(player)
    local chance = modifiers.damageReductionChance or 0
    return chance > 0 and math.random() < chance
end

--- 根据等级与装备计算完整派生属性。宿主每帧刷新属性时应复用此函数，
--- 这样职业被动不会被基础属性重算覆盖。
---@param player table
---@param inventoryData table|nil
---@return table {maxHP:number,maxMP:number,atk:number,def:number,moveSpeed:number}
function CharacterClass.GetDerivedStats(player, inventoryData)
    local classDef = CharacterClass.Classes[player.classId]
    if not classDef then
        return { maxHP = player.maxHP or 1, maxMP = player.maxMP or 0, atk = player.atk or 0, def = player.def or 0, moveSpeed = player.moveSpeed or 0 }
    end

    local level = CharacterClass.NormalizeLevel(player.level)
    local growth = classDef.growth
    local inv = inventoryData or {}
    local modifiers = CharacterClass.GetPassiveModifiers(player)
    local hp = classDef.baseHP + growth.hp * (level - 1) + (tonumber(inv.bonusHP) or 0)

    return {
        maxHP = math.floor(hp * (modifiers.maxHPMultiplier or 1.0)),
        maxMP = classDef.baseMP + growth.mp * (level - 1),
        atk = classDef.baseATK + growth.atk * (level - 1) + (tonumber(inv.bonusAtk) or 0),
        def = math.floor(classDef.baseDEF + growth.def * (level - 1)
            + (tonumber(inv.bonusDef) or 0)),
        moveSpeed = classDef.moveSpeed,
    }
end

--- 将派生属性写回玩家对象。
---@param player table
---@param inventoryData table|nil
---@param refill boolean|nil 是否同时将 HP/MP 回满
---@return table
function CharacterClass.ApplyDerivedStats(player, inventoryData, refill)
    local stats = CharacterClass.GetDerivedStats(player, inventoryData)
    local oldHP = player.hp or stats.maxHP
    local oldMP = player.mp or stats.maxMP
    player.maxHP = stats.maxHP
    player.maxMP = stats.maxMP
    player.atk = stats.atk
    player.def = stats.def
    player.moveSpeed = stats.moveSpeed
    if refill then
        player.hp = stats.maxHP
        player.mp = stats.maxMP
    else
        player.hp = math.min(oldHP, stats.maxHP)
        player.mp = math.min(oldMP, stats.maxMP)
    end
    return stats
end

-- ============================================================================
-- 工具函数
-- ============================================================================

local function SkillSortLess(a, b)
    local la = a.unlockLevel or 999
    local lb = b.unlockLevel or 999
    if la ~= lb then return la < lb end
    local sa = a.slot or 999
    local sb = b.slot or 999
    if sa ~= sb then return sa < sb end
    return (a.id or "") < (b.id or "")
end

function CharacterClass.GetSkillsSortedByLevel(classId)
    local classDef = CharacterClass.Classes[classId]
    if not classDef then return {} end
    local skills = {}
    for _, skill in ipairs(classDef.skills) do
        table.insert(skills, skill)
    end
    table.sort(skills, SkillSortLess)
    return skills
end

function CharacterClass.GetActiveSkillsSortedByLevel(classId)
    local sorted = CharacterClass.GetSkillsSortedByLevel(classId)
    local active = {}
    for _, skill in ipairs(sorted) do
        if skill.type ~= SKILL_TYPE.PASSIVE then
            table.insert(active, skill)
        end
    end
    return active
end

function CharacterClass.RebuildEquippedSkills(player, includeLocked)
    player.equippedSkills = {}
    local activeSkills = CharacterClass.GetActiveSkillsSortedByLevel(player.classId)
    local slot = 1
    for _, skill in ipairs(activeSkills) do
        if slot > 6 then break end
        if includeLocked or CharacterClass.IsSkillUnlocked(skill, player.level) then
            player.equippedSkills[slot] = skill
            slot = slot + 1
        end
    end
end

--- 创建角色实例
function CharacterClass.CreatePlayer(classId, level, modelStyle, gender)
    local classDef = CharacterClass.Classes[classId]
    if not classDef then
        print("[CharacterClass] ERROR: unknown class " .. tostring(classId))
        return nil
    end

    level = CharacterClass.NormalizeLevel(level)
    local g = classDef.growth

    local player = {
        classId   = classId,
        className = classDef.name,
        modelStyle = modelStyle or "old",
        gender = gender or "male",
        -- 激励广告奖励：完整观看后永久解锁当前角色的使用回城卷轴。
        returnScrollUnlocked = false,
        level     = level,
        exp       = 0,
        expToNext = CharacterClass.GetExpToNext(level),

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
    -- 先应用职业被动（例如武士铁骨的生命上限），装备加成在宿主
    -- 初始化 Inventory 后再通过 ApplyDerivedStats 补齐。
    local initialStats = CharacterClass.GetDerivedStats(player, nil)
    player.maxHP = initialStats.maxHP
    player.maxMP = initialStats.maxMP
    player.atk = initialStats.atk
    player.def = initialStats.def
    player.hp = player.maxHP
    player.mp = player.maxMP

    -- 默认按解锁等级从低到高装配已解锁主动技能到低位槽
    CharacterClass.RebuildEquippedSkills(player, false)

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

--- 按 id 查找技能定义
--- @return table|nil
function CharacterClass.GetSkillById(classId, skillId)
    local classDef = CharacterClass.Classes[classId]
    if not classDef then return nil end
    for _, skill in ipairs(classDef.skills) do
        if skill.id == skillId then return skill end
    end
    return nil
end

--- 检查某被动/技能是否已为该角色解锁 (按 id)
--- @return table|nil skill 已解锁则返回技能定义, 否则 nil
function CharacterClass.GetUnlockedSkill(player, skillId)
    local skill = CharacterClass.GetSkillById(player.classId, skillId)
    if skill and CharacterClass.IsSkillUnlocked(skill, player.level) then
        return skill
    end
    return nil
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
    if type(player) ~= "table" then return nil end
    local classDef = CharacterClass.Classes[player.classId]
    if not classDef then return nil end
    player.level = CharacterClass.NormalizeLevel(player.level)
    -- 仅防止损坏存档在安全边界处继续自增；正常玩法不会触达此值。
    if player.level >= LEVEL_SANITY_LIMIT then
        player.exp = 0
        player.expToNext = CharacterClass.GetExpToNext(player.level)
        return nil
    end
    player.level = player.level + 1
    local Inventory = require("scripts.Inventory")
    CharacterClass.ApplyDerivedStats(player, Inventory.playerData, true)
    player.expToNext = CharacterClass.GetExpToNext(player.level)
    print("[CharacterClass] " .. classDef.name .. " upgraded to Lv." .. player.level)

    -- 自动装备本次升级新解锁的技能，并按解锁等级重排技能栏
    local newlyUnlocked = {}
    for _, skill in ipairs(CharacterClass.GetSkillsSortedByLevel(player.classId)) do
        if skill.unlockLevel == player.level then
            table.insert(newlyUnlocked, skill.name)
        end
    end
    CharacterClass.RebuildEquippedSkills(player, false)

    if #newlyUnlocked > 0 then
        print("[CharacterClass] 新解锁技能: " .. table.concat(newlyUnlocked, ", "))
    end
    return #newlyUnlocked > 0 and newlyUnlocked or nil
end

--- 统一处理经验获取与连续升级，Lv.50 之后仍可继续升级，避免击杀和任务奖励维护两套循环。
---@param player table
---@param amount number
---@return string[]|nil newlyUnlocked
function CharacterClass.AddExperience(player, amount)
    if type(player) ~= "table" then return nil end

    local gain = tonumber(amount)
    if not IsFiniteNumber(gain) or gain <= 0 then return nil end

    player.level = CharacterClass.NormalizeLevel(player.level)
    player.expToNext = tonumber(player.expToNext)
    if not IsFiniteNumber(player.expToNext) or player.expToNext < 1 then
        player.expToNext = CharacterClass.GetExpToNext(player.level)
    end

    local currentExp = tonumber(player.exp)
    if not IsFiniteNumber(currentExp) or currentExp < 0 then currentExp = 0 end
    player.exp = math.min(1000000000, currentExp + gain)

    local newlyUnlocked = {}
    while player.level < LEVEL_SANITY_LIMIT and player.exp >= player.expToNext do
        player.exp = player.exp - player.expToNext
        local names = CharacterClass.LevelUp(player)
        if names then
            for _, name in ipairs(names) do
                table.insert(newlyUnlocked, name)
            end
        end
    end

    if player.level >= LEVEL_SANITY_LIMIT then
        -- 与 LevelUp 的安全边界保持一致，避免坏数据反复触发升级循环。
        player.exp = 0
        player.expToNext = CharacterClass.GetExpToNext(player.level)
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
    local regenRate = CharacterClass.GetMPRegenRate(player) -- 法师被动额外 +15%
    player.mp = math.min(player.maxMP, player.mp + regenRate * dt)
end

return CharacterClass
