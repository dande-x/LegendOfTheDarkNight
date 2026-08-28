import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const files = [
    "scripts/CharacterClass.lua",
    "assets/scripts/CharacterClass.lua",
    ".shotproj/scripts/CharacterClass.lua",
];
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

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

function manaCost(source, id, label) {
    const block = skillBlock(source, id, label);
    const value = Number(block.match(/\bmanaCost\s*=\s*(\d+(?:\.\d+)?)/)?.[1]);
    check(Number.isFinite(value), `${label} 的 ${id} 缺少 manaCost`);
    return value;
}

const expected = {
    t_divineBeast: 65,
    t_heal: 60,
    t_poison: 50,
    t_beastRage: 55,
    t_trapDemon: 70,
};
const previous = {
    t_divineBeast: 60,
    t_heal: 45,
    t_poison: 42,
    t_beastRage: 45,
    t_trapDemon: 65,
};

const parsed = files.map((file) => {
    const source = read(file);
    const costs = Object.fromEntries(
        Object.keys(expected).map((id) => [id, manaCost(source, id, file)]),
    );
    check(manaCost(source, "t_talisman", file) === 0,
        `${file} 的灵魂火符应继续保持基础攻击零蓝耗`);
    return { file, costs };
});

const primary = parsed[0].costs;
for (const { file, costs } of parsed) {
    for (const [id, value] of Object.entries(expected)) {
        check(value === costs[id], `${file} 的 ${id} 蓝耗未同步为 ${value}`);
        check(value > previous[id], `${file} 的 ${id} 蓝耗没有提高`);
    }
}

for (const { file, costs } of parsed.slice(1)) {
    for (const id of Object.keys(expected)) {
        check(costs[id] === primary[id], `${file} 与主脚本的 ${id} 蓝耗不一致`);
    }
}

const relativeIncreases = Object.fromEntries(
    Object.keys(expected).map((id) => [id, (expected[id] - previous[id]) / previous[id]]),
);
check(relativeIncreases.t_heal > Math.max(
    ...Object.entries(relativeIncreases)
        .filter(([id]) => id !== "t_heal")
        .map(([, increase]) => increase),
), "治愈术应保持道士技能中最大的蓝耗增幅");

console.log("taoist_mana_balance_regression: PASS");
console.log(JSON.stringify({ costs: primary, relativeIncreases }));
