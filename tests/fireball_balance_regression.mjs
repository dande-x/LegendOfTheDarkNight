import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

const classSource = read("scripts/CharacterClass.lua");
const balanceSource = read("scripts/Balance.lua");
const mainSource = read("scripts/main.lua");
const divineBeastSource = read("scripts/DivineBeast.lua");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function skillBlock(source, id, label) {
    const start = source.indexOf(`id = "${id}"`);
    check(start >= 0, `${label} 缺少技能 ${id}`);
    const end = source.indexOf("\n            },", start);
    check(end > start, `${label} 的技能 ${id} 结构异常`);
    return source.slice(start, end);
}

function numberField(block, field, label) {
    const match = block.match(new RegExp(`\\b${field}\\s*=\\s*(\\d+(?:\\.\\d+)?)`));
    const value = Number(match?.[1]);
    check(Number.isFinite(value), `${label} 缺少数值字段 ${field}`);
    return value;
}

function classBaseAttack(classId) {
    const classesStart = classSource.indexOf("CharacterClass.Classes =");
    const start = classSource.indexOf(`\n    ${classId} = {`, classesStart);
    const skillsStart = classSource.indexOf("\n        skills = {", start);
    check(start >= 0 && skillsStart > start, `无法读取职业定义: ${classId}`);
    return numberField(classSource.slice(start, skillsStart), "baseATK", classId);
}

function castRecovery(typeName) {
    const pattern = new RegExp(
        `\\[CharacterClass\\.SKILL_TYPE\\.${typeName}\\]\\s*=\\s*`
        + `\\{\\s*windup\\s*=\\s*\\d+(?:\\.\\d+)?\\s*,\\s*recovery\\s*=\\s*(\\d+(?:\\.\\d+)?)`,
    );
    const value = Number(mainSource.match(pattern)?.[1]);
    check(Number.isFinite(value), `无法读取 ${typeName} 技能后摇`);
    return value;
}

function roundedDamage(raw, defense) {
    return Math.max(1, Math.floor(raw * 100 / (100 + Math.max(0, defense)) + 0.5));
}

const fireball = skillBlock(classSource, "m_fireball", "scripts/CharacterClass.lua");
const warriorBasic = skillBlock(classSource, "w_basic", "scripts/CharacterClass.lua");
const taoistTalisman = skillBlock(classSource, "t_talisman", "scripts/CharacterClass.lua");

const fireballDamage = numberField(fireball, "damage", "火球术");
const fireballCastTime = numberField(fireball, "castTime", "火球术");
check(fireballDamage === 110, "火球术单发倍率应为 110%");
check(fireballCastTime === 0.35, "火球术前摇应为 0.35 秒");

for (const file of ["assets/scripts/CharacterClass.lua", ".shotproj/scripts/CharacterClass.lua"]) {
    const mirrored = skillBlock(read(file), "m_fireball", file);
    check(numberField(mirrored, "damage", file) === fireballDamage
        && numberField(mirrored, "castTime", file) === fireballCastTime,
        `${file} 的火球术数值未与主脚本同步`);
}

const rangedRecovery = castRecovery("RANGED");
const meleeRecovery = castRecovery("MELEE");
const mageAttack = classBaseAttack("mage");
const warriorAttack = classBaseAttack("warrior");
const taoistAttack = classBaseAttack("taoist");

const warriorDamage = numberField(warriorBasic, "damage", "基本剑术");
const warriorCastTime = numberField(warriorBasic, "castTime", "基本剑术");
const talismanDamage = numberField(taoistTalisman, "damage", "灵魂火符");
const talismanCastTime = numberField(taoistTalisman, "castTime", "灵魂火符");

const mageDPS = mageAttack * fireballDamage / 100 / (fireballCastTime + rangedRecovery);
const warriorDPS = warriorAttack * warriorDamage / 100 / (warriorCastTime + meleeRecovery);

const beastPercent = Number(
    balanceSource.match(/DIVINE_BEAST_ATK_PERCENT\s*=\s*(\d+(?:\.\d+)?)/)?.[1],
);
const beastPassive = Number(
    classSource.match(/divineBeastAttackMultiplier\s*=\s*(\d+(?:\.\d+)?)/)?.[1],
);
const beastAttackCD = Number(
    divineBeastSource.match(/baseAttackCD\s*=\s*(\d+(?:\.\d+)?)/)?.[1],
);
check(Number.isFinite(beastPercent) && Number.isFinite(beastPassive)
    && Number.isFinite(beastAttackCD), "无法读取 Lv1 神兽 DPS 参数");
const beastAttack = Math.floor(taoistAttack * beastPercent / 100 * beastPassive + 0.5);
const taoistDPS = taoistAttack * talismanDamage / 100 / (talismanCastTime + rangedRecovery)
    + beastAttack / beastAttackCD;

check(mageDPS >= warriorDPS && mageDPS <= warriorDPS * 1.20,
    "火球术前期 DPS 已偏离武士基本剑术的合理区间");
check(mageDPS > taoistDPS,
    "纯输出法师的火球术不应低于道士火符与 Lv1 神兽的合计 DPS");

const fireballFrequency = 1 / (fireballCastTime + rangedRecovery);
check(fireballFrequency >= 1.8 && fireballFrequency < 2.0,
    "火球术攻击频率应略低于每秒 2 次，同时保持响应性");

const deerHP = Math.floor((90 + 24 * 1 + 0.68 * 1 * 1) * 0.90 + 0.5);
const deerDefense = Math.floor((2 + 1.35 * 1 + 0.015 * 1 * 1) * 0.90 + 0.5);
const fireballHit = roundedDamage(mageAttack * fireballDamage / 100, deerDefense);
const deerHits = Math.ceil(deerHP / fireballHit);
check(deerHits === 5, "Lv1 火球术应约 5 发击杀初期鹿");

console.log("fireball_balance_regression: PASS");
console.log(JSON.stringify({
    mageDPS: Number(mageDPS.toFixed(1)),
    warriorDPS: Number(warriorDPS.toFixed(1)),
    taoistDPS: Number(taoistDPS.toFixed(1)),
    fireballFrequency: Number(fireballFrequency.toFixed(2)),
    fireballHit,
    deerHits,
}));
