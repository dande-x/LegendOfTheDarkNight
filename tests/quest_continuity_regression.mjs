import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const questSource = read("scripts/Quest.lua");
const combatSource = read("scripts/Combat.lua");
const mainSource = read("scripts/main.lua");
const uiSource = read("scripts/GameUI.lua");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function questBlock(id) {
    const marker = `id = "${id}"`;
    const start = questSource.indexOf(marker);
    check(start >= 0, `缺少任务 ${id}`);
    const next = questSource.indexOf('\n        id = "q_', start + marker.length);
    return questSource.slice(start, next >= 0 ? next : questSource.indexOf("\n}", start));
}

const questIds = [
    "q_001", "q_002", "q_003", "q_004", "q_005", "q_006",
    "q_007", "q_008", "q_009", "q_010", "q_011", "q_012", "q_012b",
    "q_013", "q_014", "q_014b", "q_015", "q_016",
];
const allowedModes = new Set(["clear", "patrol", "survive", "encounter"]);
const modeCounts = new Map();

for (const id of questIds) {
    const block = questBlock(id);
    const mode = block.match(/mode = "([^"]+)"/)?.[1];
    const mapId = block.match(/mapId = "([^"]+)"/)?.[1];
    check(allowedModes.has(mode), `${id} 未使用统一任务模式`);
    check(/^map_(bq|mz|sc|wm|zm)$/.test(mapId ?? ""), `${id} 缺少内联 mapId`);
    check(/legacyCount = \d+/.test(block), `${id} 缺少旧进度迁移基数 legacyCount`);
    modeCounts.set(mode, (modeCounts.get(mode) ?? 0) + 1);
}

for (const mode of allowedModes) {
    check((modeCounts.get(mode) ?? 0) >= 2, `任务模式 ${mode} 分布过少`);
}
check(!questSource.includes("QUEST_MAPS"), "任务地图仍存在第二份 QUEST_MAPS 真源");
check(!/type = "(?:kill|boss)"/.test(questSource), "旧 kill/boss 任务类型仍在使用");

for (const id of ["q_004", "q_011"]) {
    const block = questBlock(id);
    check(/mode = "survive"/.test(block), `${id} 不是坚守任务`);
    check(/count = 30\b/.test(block), `${id} 坚守时间没有统一为 30 秒`);
}
check(/SURVIVE_DURATION\s*=\s*30/.test(questSource), "坚守时长常量不是 30 秒");

for (const api of [
    "Quest.Update", "Quest.OnKill", "Quest.GetObjectiveText",
    "Quest.GetObjectiveMarker", "Quest.GetEncounterRequest",
    "Quest.IsInsideObjective",
]) {
    check(questSource.includes(`function ${api}`), `缺少连续性接口 ${api}`);
}
check(/QUEST_SAVE_VERSION\s*=\s*3/.test(questSource), "任务存档未升级到 v3");
check(questSource.includes("modeState"), "任务存档未保存模式状态");
check(questSource.includes("legacyCount"), "旧击杀进度没有迁移入口");

// 跨地图任务完成后只建立“前往下一张地图”阶段；玩家手动进入目标图后
// 才清除等待标记并启动下一条任务，不能在任务开始回调里自动切图。
check(questSource.includes("function Quest.IsTravelPending"), "缺少跨地图等待状态查询");
check(questSource.includes("function Quest.GetTravelTargetMapId"), "缺少跨地图目标查询");
check(questSource.includes("function Quest.OnMapEntered"), "缺少手动进入目标地图的任务激活入口");
check(questSource.includes("state.travelMapId = crossedMap and next.mapId or nil"), "跨地图完成未建立等待状态");

check(!combatSource.includes('require("scripts.Quest")'), "Combat 仍反向依赖 Quest");
check(!combatSource.includes("questTarget"), "自然刷怪仍会注入任务怪物");
check(!combatSource.includes("TrySpawnQuestBoss"), "仍保留任务专用 Boss 刷新器");
check(combatSource.includes("function Combat.EnsureEncounter"), "缺少统一遭遇生成入口");
check(combatSource.includes("encounterId"), "遭遇实体没有唯一标识，可能重复生成");
for (const api of [
    "Combat.SpawnEnemyGroup", "Combat.SpawnQuestSignal",
    "Combat.SetQuestAreaEffect", "Combat.ClearQuestAreaEffect",
]) {
    check(combatSource.includes(`function ${api}`), `缺少任务演出接口 ${api}`);
}

check(mainSource.includes("Quest.Update(dt, Combat.currentMapId"), "主循环未更新任务区域/巡逻进度");
check(mainSource.includes("Combat.EnsureEncounter"), "主循环未恢复当前遭遇目标");
check(mainSource.includes("not isDead"), "任务更新没有显式接入存活状态");
check(mainSource.includes("Quest.onObjectiveReached"), "主流程未接入巡查到点回调");
check(mainSource.includes("Quest.onAreaStateChanged"), "主流程未接入坚守区域回调");
check(mainSource.includes("Quest.onSurviveWave"), "主流程未接入坚守波次回调");
check(mainSource.includes("UpdateQuestAreaEffect"), "主流程未同步坚守区域视觉状态");
check(mainSource.includes("Quest.OnMapEntered"), "主流程未在手动切图后激活下一地图任务");

const questStartStart = mainSource.indexOf("local function PresentQuestStart");
const questStartEnd = mainSource.indexOf("local function PresentQuestCompletion", questStartStart);
const questStartBlock = mainSource.slice(questStartStart, questStartEnd);
check(!questStartBlock.includes("QueueQuestMapSwitch"), "任务开始仍会自动传送到目标地图");

const loadStart = mainSource.indexOf("function LoadFromSave");
const loadEnd = mainSource.indexOf("function SaveCurrentGame", loadStart);
const loadBlock = mainSource.slice(loadStart, loadEnd);
check(!loadBlock.includes("pendingQuestMapId = targetMapId"), "读档仍会强制离开存档地图");

const deathStart = mainSource.indexOf("-- 死亡状态");
const deathEnd = mainSource.indexOf("-- 施法状态机更新", deathStart);
const deathBlock = mainSource.slice(deathStart, deathEnd);
check(deathBlock.includes("MapZone.GetDef(Combat.currentMapId"), "重生点未读取当前地图配置");
check(!deathBlock.includes("playerNode_.position = Vector3(0, 0, 0)"), "重生仍硬编码世界原点");

check(uiSource.includes("Quest.GetObjectiveText"), "任务栏未使用模式化目标文本");
check(uiSource.includes("Quest.GetObjectiveMarker"), "小地图未显示普通任务地点");
check(questSource.includes("前往下一张地图"), "跨地图等待阶段缺少明确任务目标文案");

console.log("quest_continuity_regression: PASS");
console.table(Object.fromEntries(modeCounts));
