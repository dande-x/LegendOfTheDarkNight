import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const check = (condition, message) => {
    if (!condition) throw new Error(message);
};

function blockBetween(source, startMarker, endMarker) {
    const start = source.indexOf(startMarker);
    check(start >= 0, `缺少代码块: ${startMarker}`);
    const end = source.indexOf(endMarker, start + startMarker.length);
    check(end > start, `代码块边界缺失: ${startMarker}`);
    return source.slice(start, end);
}

const mapSource = read("scripts/MapZone.lua");
const combatSource = read("scripts/Combat.lua");
const monsterSource = read("scripts/MonsterData.lua");
const balanceSource = read("scripts/Balance.lua");
const skeletonSource = read("scripts/MonsterSkeleton.lua");
const inventorySource = read("scripts/Inventory.lua");

const waterCityBlock = blockBetween(mapSource, "    map_sc = {", "    map_wm = {");
check(waterCityBlock.includes('spawnPool = { "石像鬼", "海妖", "八爪鱼", "海螺幽灵" }'),
    "水上城市刷怪池没有使用四种预期敌人");
check(!waterCityBlock.includes("赤焰魔"), "水上城市仍会刷新赤焰魔");

for (const [name, monsterType] of [
    ["八爪鱼", "octopus"],
    ["海螺幽灵", "conch_ghost"],
]) {
    check(monsterSource.includes(`name = "${name}", monsterType = "${monsterType}"`),
        `MonsterData 缺少 ${name} 的敌人定义`);
    check(monsterSource.includes(`["${name}"] = {`),
        `MonsterData 缺少 ${name} 的掉落表`);
    check(balanceSource.includes(`${monsterType}`),
        `Balance 缺少 ${name} 的物种数值配置`);
    check(skeletonSource.includes(`${monsterType} = {`),
        `MonsterSkeleton 缺少 ${name} 的骨架注册`);
    check(skeletonSource.includes(`ANIMS.${monsterType} = ANIMS.`),
        `MonsterSkeleton 缺少 ${name} 的动画注册`);
}

check(!combatSource.includes('name = "赤焰魔"'), "Combat 仍保留赤焰魔定义");
for (const moduleName of ["Balance", "MonsterSkeleton", "MonsterData", "MapZone"]) {
    check(combatSource.includes(`require("${moduleName}")`),
        `Combat 没有读取 canonical ${moduleName}`);
}
check(inventorySource.includes('local MonsterData = require("MonsterData")'),
    "Inventory 没有读取 canonical MonsterData，新海怪可能无法掉落");

check(skeletonSource.includes("Techniques/PBR/PBRNoTextureAlpha.xml"),
    "海螺幽灵缺少透明 PBR 材质");

console.log("water_city_enemy_regression: PASS");
