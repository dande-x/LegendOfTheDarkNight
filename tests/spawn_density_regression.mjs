import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const combatSource = read("scripts/Combat.lua");
const mainSource = read("scripts/main.lua");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function functionBlock(source, marker, nextMarkers) {
    const start = source.indexOf(marker);
    check(start >= 0, `缺少实现: ${marker}`);
    const candidates = nextMarkers
        .map((next) => source.indexOf(next, start + marker.length))
        .filter((index) => index >= 0);
    const end = candidates.length > 0 ? Math.min(...candidates) : source.length;
    return source.slice(start, end);
}

const localRadius = Number(combatSource.match(
    /local SPAWNER_LOCAL_DENSITY_RADIUS = ([0-9.]+)/)?.[1]);
const recycleDistance = Number(combatSource.match(
    /local SPAWNER_FAR_RECYCLE_DISTANCE = ([0-9.]+)/)?.[1]);
check(Number.isFinite(localRadius) && localRadius >= 30 && localRadius <= 38,
    "玩家附近密度半径不在合理范围");
check(Number.isFinite(recycleDistance) && recycleDistance >= localRadius + 6,
    "远怪回收距离没有留出镜头外缓冲");

const recyclableBlock = functionBlock(
    combatSource,
    "local function IsNaturalEnemyRecyclableForSpawner(",
    ["\nlocal function RecycleFarNaturalEnemyForSpawner("],
);
for (const protection of [
    'spawnSource == "natural"',
    'enemy.tier ~= "boss"',
    "not enemy.encounterId",
    "not enemy.questGroupId",
    'enemy.state == "patrol"',
    "enemy == lastPlayerTarget",
]) {
    check(recyclableBlock.includes(protection), `远怪回收缺少保护条件: ${protection}`);
}

const recycleBlock = functionBlock(
    combatSource,
    "local function RecycleFarNaturalEnemyForSpawner(",
    ["\nfunction Combat.UpdateSpawner("],
);
check(recycleBlock.includes("distanceSquared > farthestDistanceSquared")
    && recycleBlock.includes("RemoveEnemyImmediately(candidate)"),
"远怪回收没有选择最远实体并走无奖励移除入口");

const spawnerBlock = functionBlock(
    combatSource,
    "function Combat.UpdateSpawner(",
    ["\n-- ============================================================================\n-- 地面掉落物系统"],
);
check(spawnerBlock.includes("CountNearbyEnemiesForSpawner(playerNode.position)"),
    "自然刷怪器没有统计玩家附近密度");
check(spawnerBlock.includes("spawnSettings.initialCount")
    && spawnerBlock.includes("if nearbyCount >= localTarget then"),
"initialCount 没有成为玩家附近基础密度目标");
const recycleAt = spawnerBlock.indexOf("RecycleFarNaturalEnemyForSpawner(");
const spawnAt = spawnerBlock.indexOf("Combat.SpawnEnemy(");
check(recycleAt >= 0 && spawnAt > recycleAt,
    "全图满载时没有先回收远处自然怪再补到玩家附近");
check(spawnerBlock.includes("SPAWNER_EMPTY_INTERVAL_MULTIPLIER")
    && spawnerBlock.includes("BOSS_NEARBY_SPAWN_INTERVAL_MULTIPLIER"),
"附近空旷加速或 Boss 附近降频没有接入新刷怪器");

const patrolBlock = functionBlock(
    combatSource,
    'elseif e.state == "patrol" then',
    ['\n        elseif e.state == "chase" then'],
);
check(patrolBlock.includes("local patrolCenter = e.homePosition or pos"),
    "普通怪仍会以当前位置连续随机游走并漂离出生区域");

check(mainSource.includes('local Combat = require("Combat")'),
    "主入口仍可能加载 assets/scripts 的旧 Combat 镜像");
check(mainSource.includes('local MapZone = require("MapZone")'),
    "主入口仍可能加载 assets/scripts 的旧 MapZone 镜像");
check(combatSource.includes('local MapZone = require("MapZone")'),
    "Combat 内部仍可能加载旧 MapZone 镜像");

console.log("spawn_density_regression: PASS");
console.log({ localRadius, recycleDistance });
