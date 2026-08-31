import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const scriptDirs = ["scripts", "assets/scripts", ".shotproj/scripts"];

function read(file) {
    return fs.readFileSync(path.join(root, file), "utf8");
}

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

const expected = {
    m_fireball: { range: 8.0 },
    m_thunder: { range: 8.0 },
    t_talisman: { range: 8.0 },
    m_firewall: { range: 8.0, aoeRadius: 2.0, duration: 5.0 },
    m_blizzard: { range: 8.0, aoeRadius: 3.5 },
    t_poison: { range: 8.0, aoeRadius: 2.5, duration: 5.0 },
    t_trapDemon: { range: 8.0, aoeRadius: 3.5, trapDuration: 6.0 },
    w_earthsplit: { range: 6.0, aoeRadius: 1.35 },
};

for (const dir of scriptDirs) {
    const file = `${dir}/CharacterClass.lua`;
    const source = read(file);
    for (const [skillId, fields] of Object.entries(expected)) {
        const block = skillBlock(source, skillId, file);
        for (const [field, expectedValue] of Object.entries(fields)) {
            check(numberField(block, field, `${file}:${skillId}`) === expectedValue,
                `${file} 的 ${skillId}.${field} 应为 ${expectedValue}`);
        }
    }
}

for (const dir of scriptDirs) {
    const file = `${dir}/Combat.lua`;
    const source = read(file);
    check(source.includes("tonumber(skill.range) or 6.0) - startOffset"),
        `${file} 的地裂斩波程缺省值未同步为 6m`);
}

const combatSource = read("scripts/Combat.lua");
check(combatSource.includes("local center = playerPos + playerDir * 4"),
    "火墙无目标落点不再保持前方 4m");
check(combatSource.includes("center = playerPos + playerDir * (radius * 0.5)"),
    "冰咆哮/困魔咒无目标落点不再按半径一半前置");
check(combatSource.includes("math.min(skill.range or 6.0, 4.0)"),
    "施毒术无目标落点不再保持前方 4m");
check(combatSource.includes("math.abs(localX) <= zone.halfW"
    + " and math.abs(localZ) <= zone.halfL"),
    "火墙矩形区域判定缺失");
check(combatSource.includes("local halfW = radius")
    && combatSource.includes("local halfL = radius * 1.5"),
    "火墙矩形尺寸未保持宽 4m × 长 6m 的换算规则");

console.log("skill_range_regression: PASS");
console.log(JSON.stringify(expected));
