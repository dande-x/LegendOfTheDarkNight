import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const combatSource = read("scripts/Combat.lua");
const monsterSource = read("scripts/MonsterData.lua");
const skeletonSource = read("scripts/MonsterSkeleton.lua");
const mainSource = read("scripts/main.lua");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function definitionBlock(name) {
    const marker = `name = "${name}"`;
    for (const source of [combatSource, monsterSource]) {
        const start = source.indexOf(marker);
        if (start < 0) continue;
        const end = source.indexOf("\n    },", start);
        check(end >= 0, `${name} 定义没有正常结束`);
        return source.slice(start, end + 7);
    }
    throw new Error(`缺少 Boss 定义: ${name}`);
}

function numberField(block, field) {
    const value = Number(block.match(new RegExp(`\\b${field}\\s*=\\s*(-?[0-9.]+)`))?.[1]);
    check(Number.isFinite(value), `缺少数值字段 ${field}`);
    return value;
}

function functionBlock(source, name, nextMarker = "\nfunction ") {
    const marker = `function ${name}(`;
    const start = source.indexOf(marker);
    check(start >= 0, `缺少函数 ${name}`);
    const end = source.indexOf(nextMarker, start + marker.length);
    return source.slice(start, end >= 0 ? end : source.length);
}

const bossGroups = {
    charge: ["半兽勇士", "白野猪"],
    ranged: ["蚁后", "火龙王"],
    slam: ["沃玛教主", "牛魔王"],
};
const expectedModes = new Map([
    ["半兽勇士", "charge"],
    ["白野猪", "charge"],
    ["蚁后", "venom_spit"],
    ["沃玛教主", "ground_slam"],
    ["火龙王", "fire_breath"],
    ["牛魔王", "ground_slam"],
]);
const expectedRanges = new Map([
    ["半兽勇士", { chase: 12.0, leash: 18.0 }],
    ["白野猪", { chase: 13.3, leash: 20.0 }],
    ["蚁后", { chase: 13.3, leash: 20.0 }],
    ["沃玛教主", { chase: 13.3, leash: 21.3 }],
    ["火龙王", { chase: 16.0, leash: 24.0 }],
    ["牛魔王", { chase: 14.7, leash: 24.0 }],
]);

for (const names of Object.values(bossGroups)) {
    check(names.length === 2, "三类 Boss 玩法没有保持均衡分配");
}

for (const [name, mode] of expectedModes) {
    const block = definitionBlock(name);
    check(block.includes('tier = "boss"'), `${name} 未标记为 Boss`);
    check(block.includes(`attackMode = "${mode}"`), `${name} 攻击模式应为 ${mode}`);
    check(numberField(block, "speed") >= 2.4, `${name} 移动速度过低`);
    const expected = expectedRanges.get(name);
    check(expected, `${name} 缺少新的距离基线`);
    check(numberField(block, "chaseRange") === expected.chase,
        `${name} 警戒范围未按约 1/3 缩短`);
    check(numberField(block, "leashRange") === expected.leash,
        `${name} 持续追踪/回位边界未按约 1/3 缩短`);
    check(numberField(block, "leashRange") > numberField(block, "chaseRange"),
        `${name} 脱战边界没有覆盖正常追击范围`);
    check(numberField(block, "guardRadius") >= 2, `${name} 缺少守点巡弋空间`);
}

const antQueen = definitionBlock("蚁后");
const bullKing = definitionBlock("牛魔王");
check(numberField(antQueen, "encounterOffsetZ") >= 5,
    "蚁后仍会生成在蚁穴碰撞体中心");
check(numberField(bullKing, "encounterOffsetZ") <= -5,
    "牛魔王仍会生成在深渊王座碰撞体中心");
check(mainSource.includes('CreateMapModel("AntNest"'), "蚁穴地标被意外删除");
check(mainSource.includes('CreateMapModel("AbyssThroneBase"'), "牛魔王王座地标被意外删除");

check(combatSource.includes('state = isBoss and "guard" or "patrol"'),
    "Boss 初始状态未进入守点");
for (const state of ["guard", "return", "chase", "attack"]) {
    check(combatSource.includes(`e.state == "${state}"`), `Boss 状态机缺少 ${state}`);
}
check(/enemy\.tier == "boss" and "return" or "patrol"/.test(combatSource),
    "Boss 失去目标后不会回位");
check(combatSource.includes('enemy.state == "guard" or enemy.state == "return"'),
    "守点或回位中的 Boss 受击后不会重新追击");
check(combatSource.includes("chaseTargetDist > e.chaseRange * 1.5"),
    "持续追踪阈值没有继续使用缩短后的警戒距离");

const stuckRecovery = functionBlock(combatSource, "UpdateBossStuckRecovery");
check(stuckRecovery.includes("enemy.stuckRecoveries >= 3"), "Boss 卡位恢复缺少最终兜底");
check(stuckRecovery.includes("enemy.homePosition"), "Boss 卡位恢复不会回出生守点");
check((combatSource.match(/UpdateBossStuckRecovery\(/g) ?? []).length >= 2,
    "Boss 卡位恢复只有定义，没有接入每帧状态机");
check(combatSource.includes('rbody.collisionMask = isBoss and (1 | 2) or (1 | 2 | 4)'),
    "Boss 仍会被普通怪碰撞包围");

check(combatSource.includes('enemy.tier == "boss" and 0.08 or 0.25'),
    "Boss 受击硬直没有缩短");
check(combatSource.includes('local controlScale = e.tier == "boss" and 0.25 or 1.0'),
    "Boss 仍承受完整火环击退");
check(combatSource.includes('if e.tier ~= "boss" and e.trapCenter and e.trapRadius then'),
    "困魔仍会锁死 Boss 位置");
check((combatSource.match(/if e\.tier ~= "boss" then/g) ?? []).length >= 3,
    "Boss 仍可能被玩家冲撞持续拖拽或顶飞");

for (const mode of ["fire_breath", "venom_spit", "ground_slam", "charge"]) {
    check(combatSource.includes(`e.attackMode == "${mode}"`), `AI 未接入 ${mode} 攻击`);
}
const enemyDamage = functionBlock(combatSource, "Combat.SpawnFireBreathVisual", "\nlocal bossAttackMaterials");
check(enemyDamage.includes('CreateChild("BossAttackVisual")'), "火龙吐息未归入统一 Boss 视觉节点");
const damageHelperStart = combatSource.indexOf("local function ApplyEnemyDamageToPlayer");
const damageHelperEnd = combatSource.indexOf("\nend", damageHelperStart);
const damageHelper = combatSource.slice(damageHelperStart, damageHelperEnd + 4);
check(damageHelper.includes("player.shieldHP"), "Boss 攻击绕过了玩家护盾");
check(combatSource.includes("DivineBeast.TakeDamage"), "Boss 特殊攻击不能伤害神兽");

const updateVisuals = functionBlock(combatSource, "Combat.UpdateVisuals");
check(updateVisuals.includes('child.name == "BossAttackVisual"'),
    "Boss 攻击视觉不会按 removeTimer 正常回收");
const cancelHostile = functionBlock(combatSource, "Combat.CancelPlayerHostileEffects");
check(cancelHostile.includes("RemoveBossAttackVisuals"), "进入安全区不会清理 Boss 攻击视觉");
const clearCombat = functionBlock(combatSource, "Combat.Clear");
check(clearCombat.includes("RemoveBossAttackVisuals(combatScene)"),
    "传送清场不会删除残留 Boss 攻击视觉");

const deathStart = mainSource.indexOf("-- 检查死亡");
const deathEnd = mainSource.indexOf("-- 施法状态机更新", deathStart);
const deathBlock = mainSource.slice(deathStart, deathEnd);
check(deathBlock.includes("Combat.CancelPlayerHostileEffects()"),
    "阵亡当帧没有清理 Boss 攻击状态");
check((mainSource.match(/Combat\.CancelPlayerHostileEffects\(\)/g) ?? []).length >= 2,
    "重生没有再次确认敌对状态已清理");
const switchMap = functionBlock(mainSource, "SwitchMap");
check(switchMap.includes("Combat.Clear()"), "传送切图没有先清空旧 Boss 状态");

check(combatSource.includes("function Combat.EnsureEncounter"), "Boss 遭遇恢复入口缺失");
check(combatSource.includes("FindEncounterEnemy(request.id)"), "遭遇逐帧恢复会重复生成 Boss");
check(combatSource.includes("encounterId = request.id"), "Boss 实体没有遭遇单例标识");

// Boss 附近只降低自然刷怪频率；显式 Boss 遭遇和任务波次不应被拦截。
const bossSpawnRadius = Number(
    combatSource.match(/local BOSS_NEARBY_SPAWN_RADIUS = ([0-9.]+)/)?.[1]);
const bossSpawnMultiplier = Number(
    combatSource.match(/local BOSS_NEARBY_SPAWN_INTERVAL_MULTIPLIER = ([0-9.]+)/)?.[1]);
check(Number.isFinite(bossSpawnRadius) && bossSpawnRadius >= 16 && bossSpawnRadius <= 24,
    "Boss 周围刷怪抑制范围不在合理区间");
check(Number.isFinite(bossSpawnMultiplier) && bossSpawnMultiplier >= 2,
    "Boss 周围自然刷怪频率没有明显降低");
const spawnerBlock = functionBlock(combatSource, "Combat.UpdateSpawner");
check(spawnerBlock.includes("IsBossNearbyForSpawner(playerNode.position)")
    && spawnerBlock.includes("BOSS_NEARBY_SPAWN_INTERVAL_MULTIPLIER"),
    "自然刷怪器没有接入 Boss 周边频率抑制");
check(combatSource.includes("enemy.tier == \"boss\" and IsEnemyTargetable(enemy)"),
    "Boss 周边频率判断未排除已死亡或濒死 Boss");

const fireDragon = definitionBlock("火龙王");
check(fireDragon.includes('monsterType = "fire_dragon"'), "火龙王又退回蛇形模型类型");
check(skeletonSource.includes("CreateFireDragonAdornment"), "火龙王非蛇形外观增强被回退");
check(skeletonSource.includes("ANIMS.fire_dragon = ANIMS.deer"), "火龙王移动动画被回退");

console.log("boss_behavior_regression: PASS");
console.table(Object.fromEntries(
    [...expectedModes].map(([name, mode]) => [name, {
        mode,
        speed: numberField(definitionBlock(name), "speed"),
        chaseRange: numberField(definitionBlock(name), "chaseRange"),
    }]),
));
