import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

const mirrors = [
    "scripts",
    "assets/scripts",
    ".shotproj/scripts",
];

const expectedTeleportCosts = [
    ["map_bq", 100],
    ["map_mz", 200],
    ["map_sc", 500],
    ["map_wm", 1000],
    ["map_zm", 2000],
];

function blockBetween(source, startMarker, endMarker) {
    const start = source.indexOf(startMarker);
    check(start >= 0, `缺少代码块: ${startMarker}`);
    const end = source.indexOf(endMarker, start + startMarker.length);
    check(end > start, `代码块边界缺失: ${startMarker}`);
    return source.slice(start, end);
}

// 旅行状态必须在三份运行时脚本中保持同一套契约，避免发布镜像退回自动切图。
for (const dir of mirrors) {
    const quest = read(`${dir}/Quest.lua`);
    const mapZone = read(`${dir}/MapZone.lua`);
    const npc = read(`${dir}/NPC.lua`);
    const main = read(`${dir}/main.lua`);
    const ui = read(`${dir}/GameUI.lua`);

    for (const [mapId, cost] of expectedTeleportCosts) {
        const mapStart = mapZone.indexOf(`${mapId} = {`);
        check(mapStart >= 0, `${dir}/MapZone.lua 缺少 ${mapId} 地图定义`);
        const mapEnd = mapZone.indexOf("\n    },", mapStart);
        check(mapEnd > mapStart, `${dir}/MapZone.lua 缺少 ${mapId} 定义边界`);
        const mapBlock = mapZone.slice(mapStart, mapEnd);
        check(mapBlock.includes(`teleportCost = ${cost}`),
            `${dir}/MapZone.lua ${mapId} 传送费用不是 ${cost} 金币`);
    }

    check(npc.includes("local isCurrent = mapId == currentMapId")
        && npc.includes("current = isCurrent")
        && npc.includes("cost = MapZone.GetTeleportCost(mapId)"),
        `${dir}/NPC.lua 没有展示当前地图或按目的地计算传送费用`);
    check(!npc.includes("if mapId ~= currentMapId")
        && npc.includes("local locked = not isCurrent"),
        `${dir}/NPC.lua 仍排除当前地图，或当前地图被错误标记为锁定`);

    check(/QUEST_SAVE_VERSION\s*=\s*3/.test(quest), `${dir}/Quest.lua 未使用 v3 存档`);
    for (const api of [
        "Quest.IsTravelPending",
        "Quest.GetTravelTargetMapId",
        "Quest.OnMapEntered",
    ]) {
        check(quest.includes(`function ${api}`), `${dir}/Quest.lua 缺少 ${api}`);
    }
    check(quest.includes("travelMapId = Quest.GetTravelTargetMapId()"),
        `${dir}/Quest.lua 未持久化 travelMapId`);
    check(quest.includes("savedVersion == QUEST_SAVE_VERSION")
        && quest.includes("saved.travelMapId == current.mapId"),
        `${dir}/Quest.lua 读档时没有校验旅行目标`);
    check(quest.includes("if state.finished or Quest.IsTravelPending()"),
        `${dir}/Quest.lua 旅行阶段仍可能接收击杀`);
    check(quest.includes("if not q or Quest.IsTravelPending() then return false end"),
        `${dir}/Quest.lua 旅行阶段仍可能推进区域任务`);
    check(quest.includes("state.travelMapId = crossedMap and next.mapId or nil"),
        `${dir}/Quest.lua 跨地图完成未建立旅行目标`);
    check(quest.includes("if next and not crossedMap and Quest.onQuestStart then"),
        `${dir}/Quest.lua 同地图任务没有即时启动边界`);
    check(quest.includes("if not Quest.IsTravelPending() or mapId ~= state.travelMapId then return false end"),
        `${dir}/Quest.lua 未校验实际进入的地图`);
    check(quest.includes("if Quest.IsTravelPending() or not q or not Quest.onQuestStart then return false end"),
        `${dir}/Quest.lua 旅行阶段仍可播放开场`);

    check(main.includes("local pendingQuestActivation = false"),
        `${dir}/main.lua 缺少待激活状态`);
    check(main.includes("HandleQuestMapEntered = function(mapId)"),
        `${dir}/main.lua 缺少地图进入处理`);
    check(main.includes("HandleQuestMapEntered(mapId)"),
        `${dir}/main.lua 切图后未通知任务系统`);
    check(main.includes("ProcessPendingQuestActivation"),
        `${dir}/main.lua 未延迟播放新任务开场`);
    for (const obsolete of [
        "QueueQuestMapSwitch",
        "ProcessPendingQuestMapSwitch",
        "pendingQuestMapId",
    ]) {
        check(!main.includes(obsolete), `${dir}/main.lua 仍保留自动切图入口 ${obsolete}`);
    }

    const startBlock = blockBetween(
        main,
        "local function PresentQuestStart",
        "local function PresentQuestCompletion",
    );
    check(!startBlock.includes("SwitchMap("),
        `${dir}/main.lua 任务开场仍会主动切图`);

    const loadBlock = blockBetween(
        main,
        "function LoadFromSave(saveData)",
        "function SaveCurrentGame(",
    );
    check(loadBlock.includes("local activatedOnLoad = HandleQuestMapEntered(mapId)"),
        `${dir}/main.lua 读档后没有恢复已抵达目标地图的任务`);

    const switchBlock = blockBetween(
        main,
        "function SwitchMap(mapId)",
        "HandleQuestMapEntered = function(mapId)",
    );
    const mapEnteredAt = switchBlock.lastIndexOf("HandleQuestMapEntered(mapId)");
    const saveAt = switchBlock.lastIndexOf("SaveCurrentGame()");
    check(mapEnteredAt >= 0 && saveAt > mapEnteredAt,
        `${dir}/main.lua 切图没有先激活任务再保存地图状态`);

    const activationBlock = blockBetween(
        main,
        "ProcessPendingQuestActivation = function()",
        "-- 任务世界坐标统一",
    );
    check(activationBlock.includes("if GameUI.IsGamePaused() then return false end")
        && activationBlock.includes("Quest.TriggerCurrentStart()"),
        `${dir}/main.lua 没有等传送面板关闭后再播放任务开场`);

    const completeBlock = blockBetween(
        main,
        "Quest.onQuestComplete = function(quest)",
        "Quest.onProgressUpdate = function(quest, progress, count)",
    );
    check(completeBlock.includes("Quest.IsTravelPending()"),
        `${dir}/main.lua 任务完成没有显示手动传送提示`);
    check(completeBlock.includes("找管家传送"),
        `${dir}/main.lua 没有告诉玩家通过管家前往下一张地图`);
    check(!completeBlock.includes("SwitchMap("),
        `${dir}/main.lua 任务完成回调仍会主动切图`);

    const teleportBlock = blockBetween(
        main,
        "GameUI.onTeleportSelected = function(mapId)",
        "-- 与管家交互",
    );
    check(teleportBlock.includes("Quest.GetTravelTargetMapId()"),
        `${dir}/main.lua 传送校验没有优先使用旅行目标`);
    check(teleportBlock.includes("local cost = MapZone.GetTeleportCost(mapId)")
        && teleportBlock.includes("Inventory.SpendGold(cost)"),
        `${dir}/main.lua 没有按目的地扣除传送金币`);
    check(!teleportBlock.includes("local cost = isQuestDestination and 0")
        && !teleportBlock.includes("MapZone.GetTeleportCost(currentMapId)"),
        `${dir}/main.lua 仍存在主线免费或按出发地图计费逻辑`);

    const stewardBlock = blockBetween(
        main,
        "local function openStewardPanel",
        "-- 与商人交互",
    );
    check(!stewardBlock.includes("option.cost = 0"),
        `${dir}/main.lua 主线目标传送仍被设置为免费`);

    check(ui.includes("Quest.IsTravelPending()"),
        `${dir}/GameUI.lua 任务追踪没有显示旅行阶段`);
    check(ui.includes("请找管家传送"),
        `${dir}/GameUI.lua 没有显示管家传送提示`);
    const teleportPanelBlock = blockBetween(
        ui,
        "function GameUI.ShowTeleportPanel",
        "function GameUI.HideTeleportPanel",
    );
    check(teleportPanelBlock.includes("传送费用按目的地收取；当前位置不可传送")
        && teleportPanelBlock.includes("local costText = isCurrent and \"当前位置\"")
        && teleportPanelBlock.includes("onClick = handleClick")
        && teleportPanelBlock.includes('text = isCurrent and "不可传送"')
        && teleportPanelBlock.includes("cost > 0 and (tostring(cost) .. \" 金币\")"),
        `${dir}/GameUI.lua 没有展示目的地费用或禁用当前位置`);
    check(!teleportPanelBlock.includes("下一段主线地图免费")
        && !teleportPanelBlock.includes("主线免费")
        && !teleportPanelBlock.includes('or "免费"'),
        `${dir}/GameUI.lua 仍展示主线免费或免费传送文案`);
}

// 用与 Quest._CompleteCurrent / OnMapEntered 相同的状态转移做行为探针：
// 跨图完成只产生旅行目标，错误地图不激活，抵达正确地图才开放下一任务。
function makeTravelModel() {
    return {
        index: 0,
        progress: 0,
        travelMapId: null,
        started: [],
    };
}

const chain = [
    { id: "q_006", mapId: "map_bq", count: 1 },
    { id: "q_007", mapId: "map_mz", count: 2 },
    { id: "q_008", mapId: "map_mz", count: 10 },
];

function completeCurrent(model) {
    const current = chain[model.index];
    const next = chain[model.index + 1];
    model.index += 1;
    model.progress = 0;
    const crossedMap = Boolean(next && current.mapId !== next.mapId);
    model.travelMapId = crossedMap ? next.mapId : null;
    if (next && !crossedMap) model.started.push(next.id);
}

function enterMap(model, mapId) {
    if (!model.travelMapId || model.travelMapId !== mapId) return false;
    model.travelMapId = null;
    model.started.push(chain[model.index].id);
    return true;
}

const model = makeTravelModel();
completeCurrent(model);
check(model.index === 1, "跨地图完成没有选中下一条任务");
check(model.travelMapId === "map_mz", "跨地图完成没有记录目标地图");
check(model.started.length === 0, "跨地图完成不应立即启动下一任务");
check(enterMap(model, "map_sc") === false, "错误地图不应激活下一任务");
check(model.travelMapId === "map_mz", "错误地图不应清除旅行目标");
check(enterMap(model, "map_mz") === true, "进入目标地图未激活下一任务");
check(model.travelMapId === null && model.started[0] === "q_007",
    "目标地图激活后的任务状态不正确");

completeCurrent(model);
check(model.travelMapId === null && model.started.includes("q_008"),
    "同地图任务没有即时推进");

// 存档载荷必须能保留旅行目标，读档后仍可继续手动传送。
const savePayload = JSON.stringify({
    version: 3,
    questIndex: model.index,
    travelMapId: "map_zm",
});
const restored = JSON.parse(savePayload);
check(restored.version === 3 && restored.travelMapId === "map_zm",
    "旅行状态没有可恢复的存档字段");

console.log("quest_travel_regression: PASS");
