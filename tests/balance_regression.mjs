import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const balanceSource = read("scripts/Balance.lua");
const classSource = read("scripts/CharacterClass.lua");
const combatSource = read("scripts/Combat.lua");
const divineBeastSource = read("scripts/DivineBeast.lua");
const monsterSource = `${combatSource}\n${read("scripts/MonsterData.lua")}`;
const questSource = read("scripts/Quest.lua");
const mapSource = read("scripts/MapZone.lua");
const inventorySource = read("scripts/Inventory.lua");
const weaponSource = read("scripts/WeaponData.lua");
const enhanceSource = read("scripts/Enhance.lua");
const mainSource = read("scripts/main.lua");
const equipmentPanelSource = read("scripts/EquipmentPanel.lua");
const gameUISource = read("scripts/GameUI.lua");
const forgePanelSource = read("scripts/ForgePanel.lua");
const serviceScrollViewSource = read("scripts/ServiceScrollView.lua");
const npcSource = read("scripts/NPC.lua");
const equipmentSource = `${inventorySource}\n${weaponSource}`;

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function getSkillBlock(id) {
    const start = classSource.indexOf(`id = "${id}"`);
    check(start >= 0, `技能定义缺失: ${id}`);
    const end = classSource.indexOf("\n            },", start);
    check(end > start, `技能定义结构异常: ${id}`);
    return classSource.slice(start, end);
}

function roundDamage(raw, defense) {
    return Math.max(1, Math.floor(raw * 100 / (100 + Math.max(0, defense)) + 0.5));
}

const curves = {
    hp: (level) => 90 + 24 * level + 0.68 * level * level,
    atk: (level) => 12 + 2.8 * level + 0.04 * level * level,
    def: (level) => 2 + 1.35 * level + 0.015 * level * level,
    exp: (level) => 12 + 3 * level + 0.04 * level * level,
};

const tiers = {
    normal: { hp: 1, atk: 1, def: 1, exp: 1 },
    elite: { hp: 2.25, atk: 1.35, def: 1.15, exp: 1.6 },
    boss: { hp: 7.5, atk: 2.2, def: 1.25, exp: 4 },
};

const profiles = {
    deer: { hp: 0.90, atk: 0.90, def: 0.90 },
    toad: { hp: 0.92, atk: 0.92, def: 0.95 },
    cat: { hp: 0.88, atk: 1.06, def: 0.86 },
    wolf: { hp: 0.88, atk: 1.08, def: 0.85 },
    spider: { hp: 0.84, atk: 1.10, def: 0.82 },
    serpent: { hp: 0.88, atk: 1.08, def: 0.85 },
    antqueen: { hp: 0.95, atk: 1.10, def: 0.90 },
    boar: { hp: 1.08, atk: 1.05, def: 1.00 },
    orc: { hp: 1.08, atk: 1.05, def: 1.00 },
    golem: { hp: 1.18, atk: 0.95, def: 1.25 },
    qilin: { hp: 1.00, atk: 1.08, def: 1.05 },
    fire_dragon: { hp: 0.88, atk: 1.08, def: 0.85 },
};

function monsterStats(def) {
    const tier = tiers[def.tier];
    const profile = profiles[def.type] ?? { hp: 1, atk: 1, def: 1 };
    const timing = Math.max(0.60, Math.min(1.80, def.cd / 1.7));
    return {
        hp: Math.max(1, Math.floor(curves.hp(def.level) * profile.hp * tier.hp * (def.hpScale ?? 1) + 0.5)),
        atk: Math.max(1, Math.floor(curves.atk(def.level) * timing * profile.atk * tier.atk * (def.atkScale ?? 1) + 0.5)),
        def: Math.max(0, Math.floor(curves.def(def.level) * profile.def * tier.def * (def.defScale ?? 1) + 0.5)),
        exp: Math.max(1, Math.floor(curves.exp(def.level) * tier.exp * (def.expScale ?? 1) + 0.5)),
    };
}

// 防止以后又在某个入口恢复成绝对减法，或让三套结算重新漂移。
check(!combatSource.includes("e.atk - player.def * 0.5"), "玩家入伤又退回绝对减法");
check((combatSource.match(/Balance\.CalculateDamage/g) ?? []).length >= 2,
    "Combat 未统一接入 Balance.CalculateDamage");
check(divineBeastSource.includes("Balance.CalculateDamage"),
    "神兽受伤未接入统一防御公式");
check(classSource.includes('def = 1.8') && classSource.includes('def = 1.0')
    && classSource.includes('def = 1.4'), "三职业防御成长常量漂移");
check(classSource.includes('id = "w_thrust", name = "刺杀剑术"')
    && classSource.includes('desc = "隔敌人一个身位攻击，可以凌空斩出白色剑气，大幅穿透其防御。"'),
    "武士刺杀剑术描述没有同步为玩家可理解的攻击说明");
const warriorThrust = getSkillBlock("w_thrust");
const warriorEarthsplit = getSkillBlock("w_earthsplit");
const warriorCharge = getSkillBlock("w_charge");
const warriorShield = getSkillBlock("w_shield");
const warriorFire = getSkillBlock("w_fire");
check(warriorThrust.includes("unlockLevel = 10"), "刺杀剑术未改为 10 级解锁");
check(warriorEarthsplit.includes('name = "地裂斩"')
    && warriorEarthsplit.includes("type = SKILL_TYPE.AOE")
    && warriorEarthsplit.includes("unlockLevel = 20")
    && warriorEarthsplit.includes("isGroundWave = true")
    && warriorEarthsplit.includes('animationType = "buff"'),
    "地裂斩未完整接入 20 级直线地面 AOE 与重劈动作");
check(warriorCharge.includes("unlockLevel = 25"), "野蛮冲撞未改为 25 级解锁");
check(warriorShield.includes("unlockLevel = 30"), "真气护盾未改为 30 级解锁");
check(warriorFire.includes("unlockLevel = 35"), "烈火剑法未改为 35 级解锁");
check(combatSource.includes("if skill.isGroundWave then")
    && combatSource.includes("function Combat.SpawnEarthRiftWave")
    && combatSource.includes("groundWave = true")
    && combatSource.includes("not p.hitEnemies[e]"),
    "地裂斩没有形成可穿透多个敌人且单目标只命中一次的移动 AOE");
check((mainSource.match(/PlayerAnim\.PlaySkill\(skill\.animationType or skill\.type\)/g) ?? []).length === 2,
    "地裂斩的重劈动作没有覆盖瞬发与前摇两条施法路径");
check(gameUISource.includes('w_earthsplit = "裂"'), "地裂斩缺少技能面板的图标降级显示");
check((mapSource.match(/spawnSettings =/g) ?? []).length === 5, "五张地图未全部设置独立刷怪密度");

// 神兽等级只允许改变名字颜色；模型必须始终恢复 prefab 自带材质。
check(divineBeastSource.includes("return LEVEL_COLORS[beast.level]"),
    "神兽等级颜色未用于名字显示");
check(!divineBeastSource.includes("UpdateLevelMaterial"),
    "神兽等级又开始修改模型材质");
const beastModelMaterialSection = divineBeastSource.slice(
    divineBeastSource.indexOf("local function CreateBeastModel"),
    divineBeastSource.indexOf("-- 获取等级颜色"));
check(!beastModelMaterialSection.includes("LEVEL_COLORS"),
    "神兽模型材质错误读取了等级颜色");
check(divineBeastSource.includes("if unchanged then return false end"),
    "神兽仍在每帧重复折算主人属性和生命比例");

const taoistPassiveBlock = classSource.slice(
    classSource.indexOf("taoist = {", classSource.indexOf("PASSIVE_MODIFIERS")),
    classSource.indexOf("},", classSource.indexOf("taoist = {", classSource.indexOf("PASSIVE_MODIFIERS"))) + 2);
check(!taoistPassiveBlock.includes("experienceMultiplier"),
    "道士经验加成回归，主线等级会再次提前溢出");
check(combatSource.includes("math.floor(player.maxHP * shieldPct / 100 + 0.5)"),
    "护盾值未整数化，可能重新产生小数生命与 0 点飘字");
check(combatSource.includes("local requestedHeal = math.max(1"),
    "技能治疗量未整数化");
check(mainSource.includes("hpCfg.healRatio * 100") && mainSource.includes("mpCfg.healRatio * 100"),
    "商店药水说明未读取实际恢复配置");
check(inventorySource.includes("Inventory.POTION_BUY_PRICE = 100"),
    "药水商店价格不再是统一的 100 金币");
check((inventorySource.match(/price = Inventory\.POTION_BUY_PRICE/g) ?? []).length === 2,
    "血药和蓝药没有共用统一商店价格");
check(mainSource.includes('Inventory.BuyPotionFromMerchant("hp")')
    && mainSource.includes('Inventory.BuyPotionFromMerchant("mp")'),
    "安全区商人没有承接两种药水购买");
check(!mainSource.includes("Inventory.BuyPotion("),
    "仍存在绕过商人的旧药水购买调用");
check(!equipmentPanelSource.includes("BuyPotion")
    && equipmentPanelSource.includes("仅可在安全区商人处购买"),
    "背包重新出现药水购买入口或缺少商人购买提示");
const itemDetailStart = equipmentPanelSource.indexOf("local function ShowItemDetail");
const itemDetailEnd = equipmentPanelSource.indexOf("function EquipmentPanel.BuildEquipTab", itemDetailStart);
check(itemDetailStart >= 0 && itemDetailEnd > itemDetailStart,
    "装备详情入口结构缺失，无法验证背包操作边界");
const itemDetailSource = equipmentPanelSource.slice(itemDetailStart, itemDetailEnd);
check(itemDetailSource.includes('or ("出售可得 " .. sellPrice .. " 金 · 请前往安全区商人")')
    && itemDetailSource.includes('text = "分解穿戴中装备"')
    && itemDetailSource.includes("if sourceSlot then"),
    "装备详情没有区分背包出售与已穿戴分解操作");
check(!itemDetailSource.includes('or "分解装备"')
    && !itemDetailSource.includes('text = "分解装备"'),
    "背包装备详情仍暴露分解装备按钮");
const skillDescriptionStart = gameUISource.indexOf('text = skill.desc or ""');
const skillDescriptionEnd = gameUISource.indexOf("UI.Label {", skillDescriptionStart + 1);
const skillDescriptionSource = gameUISource.slice(skillDescriptionStart, skillDescriptionEnd);
check(skillDescriptionStart >= 0
    && skillDescriptionSource.includes('whiteSpace = "normal"')
    && skillDescriptionSource.includes('wordBreak = "break-word"'),
    "技能描述没有启用中文换行，长说明可能被挤压");
check(mainSource.includes('elseif kind == "blacksmith" then')
    && mainSource.includes("GameUI.ShowBlacksmithPanel(player_)"),
    "铁匠 NPC 没有承接锻造/强化入口");
check(!equipmentPanelSource.includes("ForgeRecipe")
    && !equipmentPanelSource.includes("ForgeItems"),
    "角色/背包面板重新出现直接锻造逻辑");
check(!equipmentPanelSource.includes("Inventory.EnhanceItem")
    && equipmentPanelSource.includes("前往安全区铁匠"),
    "角色/背包面板重新出现直接强化入口");
check(forgePanelSource.includes("5 件同品质同部位")
    && forgePanelSource.includes("锻造 1 件 · "),
    "锻造台没有清楚说明材料、次数与费用");
check(serviceScrollViewSource.includes("UI.ScrollView")
    && serviceScrollViewSource.includes("UI.CancelPointer")
    && serviceScrollViewSource.includes("state.isDragging")
    && serviceScrollViewSource.includes("scrollbarInteractive = true")
    && serviceScrollViewSource.includes("bounces = false"),
    "服务区滚动容器没有接管拖动、滚动条或边界状态");
check(gameUISource.includes("ServiceScrollView.Build")
    && gameUISource.includes('local ServiceScrollView = require("scripts.ServiceScrollView")'),
    "商店面板没有使用服务区滚动容器");
const blacksmithPanelSource = read("scripts/BlacksmithPanel.lua");
const enhancePanelSource = read("scripts/EnhancePanel.lua");
check(blacksmithPanelSource.includes("ServiceScrollView.Build")
    && enhancePanelSource.includes("ServiceScrollView.Build"),
    "锻造 / 强化页面没有使用服务区滚动容器");
check(npcSource.includes("BuildHoodedHumanoid")
    && npcSource.includes("WhiteRobeLower")
    && npcSource.includes("0.34, 0.22, 1.22")
    && npcSource.includes("PointedHat")
    && npcSource.includes("Models/Cone.mdl")
    && npcSource.includes("HatBrim")
    && npcSource.includes("HoodFaceShadow"),
    "安全区 NPC 又退回占位模型或缺少白袍尖帽轮廓");
check(npcSource.includes("StewardStaff")
    && npcSource.includes("MerchantCoinPouch")
    && npcSource.includes("BlacksmithHammerHead"),
    "白袍 NPC 缺少管家、商人、铁匠的职业辨识物件");
check((npcSource.match(/spawnHoodedNPC\("/g) ?? []).length === 3
    && npcSource.includes("shape:SetCapsule(0.35, 1.6"),
    "三名安全区 NPC 未全部使用新模型，或碰撞范围发生漂移");

// 这些字符串让测试与 Lua 单一数值源绑定；修改曲线时必须同步更新验收矩阵。
for (const formula of [
    "90 + 24 * level + 0.68 * level * level",
    "12 + 2.8 * level + 0.04 * level * level",
    "2 + 1.35 * level + 0.015 * level * level",
    "12 + 3 * level + 0.04 * level * level",
]) {
    check(balanceSource.includes(formula), `Balance.lua 曲线与回归模型不一致: ${formula}`);
}

function questBlock(id) {
    const marker = `id = "${id}"`;
    const start = questSource.indexOf(marker);
    check(start >= 0, `缺少任务 ${id}`);
    const next = questSource.indexOf('\n        id = "q_', start + marker.length);
    return questSource.slice(start, next >= 0 ? next : questSource.length);
}

function parseQuest(id) {
    const block = questBlock(id);
    const mode = block.match(/mode = "([^"]+)"/)?.[1]
        ?? block.match(/type = "([^"]+)"/)?.[1];
    const mapId = block.match(/mapId = "([^"]+)"/)?.[1];
    const target = block.match(/target = "([^"]+)"/)?.[1];
    const count = Number(block.match(/count = (\d+)/)?.[1]);
    const legacyCount = Number(block.match(/legacyCount = (\d+)/)?.[1] ?? count);
    const reward = Number(block.match(/rewardExp = (\d+)/)?.[1]);
    check(mode && Number.isFinite(count) && Number.isFinite(legacyCount)
        && Number.isFinite(reward), `任务 ${id} 数值无法解析`);
    check(target || !["kill", "boss", "encounter"].includes(mode),
        `任务 ${id} 的 ${mode} 模式缺少目标`);
    check(target || mapId, `任务 ${id} 缺少地图与目标，无法估算推进经验`);
    return { id, mode, mapId, target, count, legacyCount, reward };
}

function monsterBlock(name) {
    const marker = `name = "${name}"`;
    const starts = [];
    let cursor = monsterSource.indexOf(marker);
    while (cursor >= 0) {
        starts.push(cursor);
        cursor = monsterSource.indexOf(marker, cursor + marker.length);
    }
    check(starts.length > 0, `缺少怪物 ${name}`);
    for (const start of starts) {
        const end = monsterSource.indexOf("\n    },", start);
        const block = monsterSource.slice(start, end >= 0 ? end : start + 1000);
        if (/level = \d+/.test(block) && /tier = "(normal|elite|boss)"/.test(block)) return block;
    }
    throw new Error(`怪物 ${name} 定义无法解析`);
}

function parseMonster(name) {
    const block = monsterBlock(name);
    const number = (field, fallback) => {
        const value = block.match(new RegExp(`${field} = ([0-9.]+)`))?.[1];
        return value === undefined ? fallback : Number(value);
    };
    return {
        name,
        type: block.match(/monsterType = "([^"]+)"/)?.[1],
        level: number("level"),
        cd: number("attackCD", 1.7),
        tier: block.match(/tier = "(normal|elite|boss)"/)?.[1],
        hpScale: number("hpScale", 1),
        atkScale: number("atkScale", 1),
        defScale: number("defScale", 1),
        expScale: number("expScale", 1),
    };
}

function parseEquipmentItem(id) {
    const marker = `id = "${id}"`;
    let start = equipmentSource.indexOf(marker);
    while (start >= 0) {
        const end = equipmentSource.indexOf("}", start);
        const block = equipmentSource.slice(start, end >= 0 ? end + 1 : start + 500);
        const number = (field) => Number(block.match(new RegExp(`${field} = ([0-9.]+)`))?.[1]);
        const item = {
            id,
            rarity: block.match(/rarity = "([A-Z]+)"/)?.[1],
            atk: number("atk"),
            def: number("def"),
            hp: number("hp"),
        };
        if (item.rarity && [item.atk, item.def, item.hp].every(Number.isFinite)) return item;
        start = equipmentSource.indexOf(marker, start + marker.length);
    }
    throw new Error(`装备 ${id} 属性无法解析`);
}

function parseMapPool(mapId) {
    const marker = `${mapId} = {`;
    const start = mapSource.indexOf(marker);
    check(start >= 0, `缺少地图 ${mapId}`);
    const next = mapSource.indexOf("\n    map_", start + marker.length);
    const block = mapSource.slice(start, next >= 0 ? next : mapSource.length);
    const poolText = block.match(/spawnPool = \{([^}]+)\}/)?.[1];
    const pool = [...(poolText ?? "").matchAll(/"([^"]+)"/g)].map((match) => match[1]);
    check(pool.length > 0, `地图 ${mapId} 缺少自然怪物池`);
    return pool;
}

const enhanceRates = {
    def: Number(enhanceSource.match(/def = EnhancementBonus\(item\.def, ([0-9.]+), level\)/)?.[1]),
    hp: Number(enhanceSource.match(/hp = EnhancementBonus\(item\.hp, ([0-9.]+), level\)/)?.[1]),
};
check(Number.isFinite(enhanceRates.def) && Number.isFinite(enhanceRates.hp),
    "强化属性倍率无法解析");

function enhancementBonus(baseStat, rate, level) {
    if (baseStat <= 0 || level <= 0) return 0;
    return Math.max(1, Math.floor(baseStat * rate * level));
}

function equipmentTotals(ids, enhance = 0, expectedRarity) {
    return ids.map(parseEquipmentItem).reduce((total, item) => {
        if (expectedRarity) {
            check(item.rarity === expectedRarity,
                `${item.id} 应为 ${expectedRarity}，实际为 ${item.rarity}`);
        }
        total.def += item.def + enhancementBonus(item.def, enhanceRates.def, enhance);
        total.hp += item.hp + enhancementBonus(item.hp, enhanceRates.hp, enhance);
        return total;
    }, { def: 0, hp: 0 });
}

const questIds = [
    "q_001", "q_002", "q_003", "q_004", "q_005", "q_006",
    "q_007", "q_008", "q_009", "q_010", "q_011", "q_012", "q_012b",
    "q_013", "q_014", "q_014b", "q_015", "q_016",
];
const quests = questIds.map(parseQuest);
const monsters = new Map(quests.filter((quest) => quest.target)
    .map((quest) => [quest.target, parseMonster(quest.target)]));

const expToNext = (level) => Math.floor(75 + 38 * level + 1.6 * level * level);
let playerLevel = 1;
let playerExp = 0;
const checkpoints = new Map([
    ["q_006", 10], ["q_009", 25], ["q_012b", 35], ["q_014b", 45], ["q_016", 50],
]);

function addPlayerExp(amount) {
    playerExp += amount;
    while (playerLevel < 50 && playerExp >= expToNext(playerLevel)) {
        playerExp -= expToNext(playerLevel);
        playerLevel += 1;
    }
}

function experienceGain(baseExp, monsterLevel, tier) {
    const difference = playerLevel - monsterLevel;
    let multiplier = 1;
    if (tier === "normal") {
        if (difference >= 13) multiplier = 0.10;
        else if (difference >= 8) multiplier = 0.30;
        else if (difference >= 5) multiplier = 0.60;
        else if (monsterLevel - playerLevel >= 5) multiplier = 1.10;
    }
    return Math.max(1, Math.floor(baseExp * multiplier + 0.5));
}

function awardMonsterKill(name) {
    const def = parseMonster(name);
    const stats = monsterStats(def);
    addPlayerExp(experienceGain(stats.exp, def.level, def.tier));
}

function awardMapKills(mapId, count) {
    const pool = parseMapPool(mapId);
    for (let index = 0; index < count; index += 1) {
        awardMonsterKill(pool[index % pool.length]);
    }
}

for (const quest of quests) {
    if (quest.target) {
        for (let count = 0; count < quest.count; count += 1) awardMonsterKill(quest.target);
    } else if (quest.mode === "clear") {
        awardMapKills(quest.mapId, quest.count);
    } else if (quest.mode === "patrol") {
        // 跑图期间按每个地标约两只必经怪估算，不把巡逻重新变成刷怪任务。
        awardMapKills(quest.mapId, quest.count * 2);
    } else if (quest.mode === "survive") {
        // 守点按约 3 秒击败一只同期怪估算；任务计时本身仍是完成条件。
        awardMapKills(quest.mapId, Math.ceil(quest.count / 3));
    }
    addPlayerExp(quest.reward);
    if (checkpoints.has(quest.id)) {
        check(playerLevel === checkpoints.get(quest.id),
            `${quest.id} 结束等级应为 ${checkpoints.get(quest.id)}，实际为 ${playerLevel}`);
    }
}

const classes = {
    warrior: { hp0: 200, hpGrowth: 40, hpMultiplier: 1.2, def0: 15, defGrowth: 1.8 },
    mage: { hp0: 120, hpGrowth: 22, hpMultiplier: 1.0, def0: 8, defGrowth: 1.0 },
    taoist: { hp0: 160, hpGrowth: 30, hpMultiplier: 1.0, def0: 12, defGrowth: 1.4 },
};

const survivalRows = [];
for (const level of [1, 10, 25, 40, 50]) {
    const raw = curves.atk(level);
    const row = { level };
    for (const [classId, classDef] of Object.entries(classes)) {
        const hp = Math.floor((classDef.hp0 + classDef.hpGrowth * (level - 1)) * classDef.hpMultiplier);
        const defense = Math.floor(classDef.def0 + classDef.defGrowth * (level - 1));
        row[classId] = Math.ceil(hp / roundDamage(raw, defense));
    }
    check(row.warrior >= 16 && row.warrior <= 25, `Lv${level} 武士裸装承伤次数越界`);
    check(row.mage >= 7 && row.mage <= 12, `Lv${level} 法师裸装承伤次数越界`);
    check(row.taoist >= 10 && row.taoist <= 16, `Lv${level} 道士裸装承伤次数越界`);
    survivalRows.push(row);
}

// 使用真实装备模板验证品质与强化阶段，双手镯、双戒指都按实际槽位重复计入。
// 品质倍率只影响经济价值，战斗属性来自对应品质模板本身；强化加成必须逐件取整。
const equipmentStages = [
    { label: "裸装", rarity: null, enhance: 0, ids: [], hit: [160, 190], survival: [9, 12] },
    { label: "普通", rarity: "COMMON", enhance: 0, hit: [145, 175], survival: [10, 13], ids: [
        "bell_wm", "helm_iron", "armor_cloth", "neck_bone",
        "brace_iron", "brace_iron", "ring_copper", "ring_copper", "belt_cloth", "boots_cloth",
    ] },
    { label: "优秀", rarity: "UNCOMMON", enhance: 0, hit: [130, 160], survival: [11, 15], ids: [
        "bell_jade", "helm_bronze", "armor_leather", "neck_jade",
        "brace_silver", "brace_silver", "ring_silver", "ring_silver", "belt_leather", "boots_leather",
    ] },
    { label: "稀有", rarity: "RARE", enhance: 0, hit: [110, 140], survival: [14, 20], ids: [
        "bell_soul", "helm_golden", "armor_chain", "neck_amber",
        "brace_gold", "brace_gold", "ring_gold", "ring_gold", "belt_chain", "boots_iron",
    ] },
    { label: "史诗", rarity: "EPIC", enhance: 0, hit: [90, 120], survival: [20, 27], ids: [
        "bell_holy", "helm_dragon", "armor_dragon", "neck_dragon",
        "brace_dragon", "brace_dragon", "ring_dragon", "ring_dragon", "belt_dragon", "boots_dragon",
    ] },
    { label: "史诗+12", rarity: "EPIC", enhance: 12, hit: [75, 100], survival: [26, 34], ids: [
        "bell_holy", "helm_dragon", "armor_dragon", "neck_dragon",
        "brace_dragon", "brace_dragon", "ring_dragon", "ring_dragon", "belt_dragon", "boots_dragon",
    ] },
];

const zumaGuard = monsterStats(parseMonster("祖玛卫士"));
const taoist50 = classes.taoist;
const equipmentRows = [];
let previousStageSurvival = 0;
for (const stage of equipmentStages) {
    const gear = equipmentTotals(stage.ids, stage.enhance, stage.rarity);
    const hp = Math.floor(taoist50.hp0 + taoist50.hpGrowth * 49 + gear.hp);
    const defense = Math.floor(taoist50.def0 + taoist50.defGrowth * 49 + gear.def);
    const hit = roundDamage(zumaGuard.atk, defense);
    const survival = Math.ceil(hp / hit);
    check(hit >= stage.hit[0] && hit <= stage.hit[1],
        `Lv50 道士${stage.label}被祖玛卫士命中 ${hit}，应在 ${stage.hit[0]}~${stage.hit[1]}`);
    check(survival >= stage.survival[0] && survival <= stage.survival[1],
        `Lv50 道士${stage.label}承伤 ${survival} 次，越出 ${stage.survival[0]}~${stage.survival[1]}`);
    check(survival > previousStageSurvival,
        `装备阶段 ${stage.label} 没有提高生存能力`);
    previousStageSurvival = survival;
    equipmentRows.push({ stage: stage.label, gearHP: gear.hp, gearDEF: gear.def, hp, defense, hit, survival });
}

const blackPython = monsterStats(parseMonster("黑鳞蟒"));
const epicGear = equipmentTotals(equipmentStages[4].ids, 0, "EPIC");
const taoist40Defense = Math.floor(12 + 1.4 * 39 + epicGear.def);
const blackPythonHit = roundDamage(blackPython.atk, taoist40Defense);
check(blackPythonHit >= 40, `Lv40 同期装备道士被黑鳞蟒命中仅 ${blackPythonHit}，威胁不足`);
check(blackPythonHit <= 120, `Lv40 同期装备道士被黑鳞蟒命中 ${blackPythonHit}，威胁过高`);

const bossNames = ["半兽勇士", "白野猪", "蚁后", "沃玛教主", "火龙王", "牛魔王"];
let previousBossHP = 0;
let previousBossDPS = 0;
const bossRows = [];
for (const name of bossNames) {
    const def = parseMonster(name);
    const stats = monsterStats(def);
    const rawDPS = stats.atk / def.cd;
    check(stats.hp > previousBossHP, `${name} 的生命曲线低于前一章节 Boss`);
    check(rawDPS >= previousBossDPS * 0.98, `${name} 的输出曲线低于前一章节 Boss`);
    previousBossHP = stats.hp;
    previousBossDPS = rawDPS;
    bossRows.push({ name, level: def.level, hp: stats.hp, atk: stats.atk, cd: def.cd, rawDPS: Math.round(rawDPS) });
}

console.log("balance_regression: PASS");
console.table(survivalRows);
console.table(equipmentRows);
console.log(`Lv40 道士（史诗套）被黑鳞蟒命中：${blackPythonHit}`);
console.table(bossRows);
console.log(`主线最终：Lv${playerLevel} ${Math.floor(playerExp)}/${expToNext(playerLevel)}`);
