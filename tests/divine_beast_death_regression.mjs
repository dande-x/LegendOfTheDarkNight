import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

const mirrors = [
    "scripts",
    "assets/scripts",
    ".shotproj/scripts",
];

function check(condition, message) {
    if (!condition) throw new Error(message);
}

const LEVEL_EXP = [0, 100, 250, 500, 900, 1500, 2500, 999999];

// Model the persisted growth portion of the real death/re-summon lifecycle.
function applyDeathPenalty(beast) {
    if (!beast.alive && !beast.node) return;
    const previousLevel = Math.max(1, Math.min(7, Math.floor(beast.level || 1)));
    beast.level = Math.max(1, previousLevel - 1);
    beast.exp = 0;
    beast.expToNext = LEVEL_EXP[beast.level];
    beast.alive = false;
    beast.node = null;
    beast.hp = 0;
}

function summon(beast) {
    if (!beast.summoned) {
        beast.summoned = true;
        beast.level = 1;
        beast.exp = 0;
        beast.expToNext = LEVEL_EXP[1];
    } else {
        beast.level = Math.max(1, Math.min(7, Math.floor(beast.level || 1)));
        beast.expToNext = LEVEL_EXP[beast.level];
        beast.exp = beast.level >= 7
            ? 0
            : Math.min(Math.max(0, Math.floor(beast.exp || 0)), beast.expToNext - 1);
    }
    beast.alive = true;
    beast.node = {};
}

const beast = {
    summoned: true,
    alive: true,
    node: {},
    level: 4,
    exp: 700,
    expToNext: LEVEL_EXP[4],
};

applyDeathPenalty(beast);
check(beast.level === 3, "Lv.4 神兽死亡后没有降低到 Lv.3");
check(beast.exp === 0 && beast.expToNext === LEVEL_EXP[3],
    "神兽死亡后经验或下一等级经验没有重置");

summon(beast);
check(beast.level === 3 && beast.exp === 0 && beast.alive,
    "神兽再次召唤没有沿用降级后的等级和 0 经验");

applyDeathPenalty(beast);
check(beast.level === 2, "神兽第二次死亡没有再次降低 1 级");
summon(beast);
applyDeathPenalty(beast);
check(beast.level === 1, "神兽降到 Lv.1 后死亡没有保持 Lv.1");
summon(beast);
applyDeathPenalty(beast);
check(beast.level === 1, "Lv.1 神兽死亡后发生了低于 Lv.1 的降级");

// A repeated Die call after the entity has already been cleared must not apply
// the penalty a second time.
applyDeathPenalty(beast);
check(beast.level === 1, "同一次死亡重复调用仍然重复扣级");

for (const dir of mirrors) {
    const source = read(`${dir}/DivineBeast.lua`);
    check(source.includes("if not beast.alive and not beast.node then return end"),
        `${dir}/DivineBeast.lua 缺少死亡幂等保护`);
    check(source.includes("beast.level = math.max(1, previousLevel - 1)"),
        `${dir}/DivineBeast.lua 没有按死亡降低 1 级`);
    check(source.includes("beast.exp = 0")
        && source.includes("beast.expToNext = LEVEL_EXP[beast.level]"),
        `${dir}/DivineBeast.lua 没有在死亡时清空经验`);
    check(!source.includes("等级、经验、属性和 summoned 标记保留到存档/下次召唤"),
        `${dir}/DivineBeast.lua 仍保留旧的死亡不扣级说明`);
    check(source.includes("if not beast.summoned then")
        && source.includes("-- 第一次召唤初始化成长；死亡后再次召唤必须保留死亡惩罚后的成长。"),
        `${dir}/DivineBeast.lua 的再次召唤生命周期说明缺失`);
}

console.log("divine_beast_death_regression: PASS");
