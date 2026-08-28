import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

const mirrors = [
    "scripts",
    "assets/scripts",
    ".shotproj/scripts",
];

const expectedBoards = [
    ["level", "night_legend_level", "等级"],
    ["monster_kills", "night_legend_monster_kills", "消灭怪物"],
    ["gold", "night_legend_gold", "金币"],
];

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function blockBetween(source, startMarker, endMarker, label) {
    const start = source.indexOf(startMarker);
    check(start >= 0, `${label} 缺少代码块: ${startMarker}`);
    const end = source.indexOf(endMarker, start + startMarker.length);
    check(end > start, `${label} 代码块边界缺失: ${startMarker}`);
    return source.slice(start, end);
}

function sameScores(left, right) {
    return expectedBoards.every(([id]) => left[id] === right[id]);
}

function copyScores(scores) {
    return Object.fromEntries(expectedBoards.map(([id]) => [id, scores[id]]));
}

// Model the write queue contract: while a cloud write is pending, retain only
// the newest account snapshot and complete each physical write at most once.
function makeSyncQueueModel() {
    let inFlight = null;
    let queued = null;
    let lastSuccessful = null;
    const writes = [];

    function start(scores) {
        const snapshot = copyScores(scores);
        inFlight = { snapshot, completed: false };
        writes.push(snapshot);
    }

    return {
        sync(scores) {
            const snapshot = copyScores(scores);
            if (inFlight) {
                if (!sameScores(inFlight.snapshot, snapshot)) queued = snapshot;
                return;
            }
            if (lastSuccessful && sameScores(lastSuccessful, snapshot)) return;
            start(snapshot);
        },
        complete(success) {
            if (!inFlight || inFlight.completed) return;
            inFlight.completed = true;
            if (success) lastSuccessful = copyScores(inFlight.snapshot);
            inFlight = null;
            const next = queued;
            queued = null;
            if (next && (!lastSuccessful || !sameScores(lastSuccessful, next))) start(next);
        },
        writes,
    };
}

const syncModel = makeSyncQueueModel();
syncModel.sync({ level: 10, monster_kills: 20, gold: 300 });
syncModel.sync({ level: 11, monster_kills: 25, gold: 250 });
syncModel.sync({ level: 12, monster_kills: 31, gold: 180 });
check(syncModel.writes.length === 1, "并发同步没有合并等待中的写入");
syncModel.complete(true);
check(syncModel.writes.length === 2
    && sameScores(syncModel.writes[1], { level: 12, monster_kills: 31, gold: 180 }),
"并发同步没有保留最新账号快照");
syncModel.complete(true);
syncModel.complete(false);
check(syncModel.writes.length === 2, "同一次云写入被 error/timeout 重复完成");

function collectAccountScores(slots, currentSlotIndex, runtime) {
    const result = { level: 0, monster_kills: 0, gold: 0 };
    for (let index = 0; index < slots.length; index += 1) {
        const slotNumber = index + 1;
        const source = slotNumber === currentSlotIndex && runtime ? runtime : slots[index];
        if (!source) continue;
        result.level = Math.max(result.level, Math.max(0, Math.floor(source.level || 0)));
        result.monster_kills = Math.max(result.monster_kills,
            Math.max(0, Math.floor(source.killCount || 0)));
        result.gold = Math.max(result.gold, Math.max(0, Math.floor(source.gold || 0)));
    }
    return result;
}

const savedSlots = [
    { level: 30, killCount: 500, gold: 1000 },
    { level: 22, killCount: 900, gold: 3500 },
];
check(sameScores(collectAccountScores(savedSlots, null, null), {
    level: 30,
    monster_kills: 900,
    gold: 3500,
}), "两个角色槽位没有按榜单类别分别取最高值");
check(sameScores(collectAccountScores(savedSlots, 1, {
    level: 31,
    killCount: 1200,
    gold: 400,
}), {
    level: 31,
    monster_kills: 1200,
    gold: 3500,
}), "当前角色实时值没有替换该槽位的旧存档值");
check(sameScores(collectAccountScores([null, savedSlots[1]], null, null), {
    level: 22,
    monster_kills: 900,
    gold: 3500,
}), "删除最高角色后没有回落到剩余角色记录");

for (const dir of mirrors) {
    const leaderboard = read(`${dir}/PlatformLeaderboard.lua`);
    const leaderboardMeta = JSON.parse(read(`${dir}/PlatformLeaderboard.lua.meta`));
    const main = read(`${dir}/main.lua`);
    const ui = read(`${dir}/GameUI.lua`);
    const label = `${dir}/PlatformLeaderboard.lua`;

    check(leaderboardMeta.uuid === "46ee4c3c-91e5-4074-86e3-94c859beeb4d",
        `${label}.meta 的资源 UUID 与运行镜像不一致`);

    for (const [id, key, boardLabel] of expectedBoards) {
        check(leaderboard.includes(`id = "${id}"`)
            && leaderboard.includes(`key = "${key}"`)
            && leaderboard.includes(`label = "${boardLabel}"`),
        `${label} 缺少稳定榜单契约 ${id}/${key}`);
        check(leaderboard.includes(`batch:SetInt(board.key, scores[board.id])`),
            `${label} 没有通过 SetInt 写入整数榜单`);
    }

    check(leaderboard.includes("clientCloud")
        && leaderboard.includes("cloud:BatchSet()")
        && leaderboard.includes("batch:Save("),
    `${label} 没有使用 clientCloud BatchSet 保存三榜快照`);
    check(leaderboard.includes("cloud:GetRankList(board.key, 0, count")
        && leaderboard.includes("cloud:GetUserRank(userId, board.key")
        && leaderboard.includes("GetUserNickname {"),
    `${label} 缺少榜单、个人排名或昵称查询`);
    check(!leaderboard.includes("serverCloud"), `${label} 错用了服务端云变量`);
    check(!leaderboard.includes(":Set(")
        && !/nickname\s*[",']/.test(leaderboard)
        && !/player_name\s*[",']/.test(leaderboard),
    `${label} 把昵称或普通值写入了云变量`);
    check(leaderboard.includes("if not getClientCloud() then")
        && leaderboard.includes('"unavailable", "平台排行榜暂不可用"')
        && leaderboard.includes("return false"),
    `${label} 缺少平台不可用时的静默降级`);
    check(leaderboard.includes("local completed = false")
        && leaderboard.includes("if completed then return end")
        && leaderboard.includes("completed = true"),
    `${label} 缺少异步回调单次完成保护`);
    check(leaderboard.includes("queuedScores = normalized")
        && leaderboard.includes("queuedWaiters")
        && leaderboard.includes("flushQueuedSync()")
        && leaderboard.includes("lastSuccessfulScores"),
    `${label} 缺少最新快照队列或重复写入抑制`);
    check(leaderboard.includes("local TOP_COUNT = 20"), `${label} 前榜数量不是 20`);

    check(/require\("(?:scripts\.)?PlatformLeaderboard"\)/.test(main),
        `${dir}/main.lua 没有加载排行榜模块`);
    const collectBlock = blockBetween(main,
        "local function CollectAccountLeaderboardScores()",
        "local function SyncAccountLeaderboard", `${dir}/main.lua`);
    check(collectBlock.includes("for slotIndex = 1, slotCount do")
        && collectBlock.includes("SaveSystem.GetSlot(slotIndex)")
        && collectBlock.includes("slotIndex == currentSlotIndex and player_ ~= nil")
        && collectBlock.includes("Combat.GetKillCount()")
        && collectBlock.includes("Inventory.playerData.gold")
        && collectBlock.includes("MergeLeaderboardScores(scores, source)"),
    `${dir}/main.lua 没有以当前实时值替换当前槽位并聚合两个槽位`);
    const mergeBlock = blockBetween(main,
        "local function MergeLeaderboardScores(scores, source)",
        "local function CollectAccountLeaderboardScores", `${dir}/main.lua`);
    check(mergeBlock.match(/math\.max/g)?.length >= 3,
        `${dir}/main.lua 三项账号记录没有分别取最大值`);

    const startBlock = blockBetween(main, "function Start()", "function Stop()", `${dir}/main.lua`);
    check(/SaveSystem\.Init\(\)[\s\S]*SyncAccountLeaderboard\(\)/.test(startBlock),
        `${dir}/main.lua 启动读取存档后没有同步排行榜`);
    const slotScreenBlock = blockBetween(main,
        "function ShowSaveSlotScreen()",
        "function LoadFromSave(saveData)", `${dir}/main.lua`);
    check(/SaveSystem\.DeleteSlot\(slotIndex\)[\s\S]*if deleted then[\s\S]*SyncAccountLeaderboard\(\)/
        .test(slotScreenBlock), `${dir}/main.lua 删除角色成功后没有同步排行榜`);
    const loadBlock = blockBetween(main,
        "function LoadFromSave(saveData)",
        "function SaveCurrentGame(", `${dir}/main.lua`);
    check(loadBlock.includes("SyncAccountLeaderboard()"),
        `${dir}/main.lua 成功读档后没有同步排行榜`);
    const saveBlock = blockBetween(main,
        "function SaveCurrentGame(",
        "-- ============================================================================\n-- 地图切换", `${dir}/main.lua`);
    check(/if ok then[\s\S]*SyncAccountLeaderboard\(\)/.test(saveBlock),
        `${dir}/main.lua 成功保存后没有同步排行榜`);
    const createBlock = blockBetween(main,
        "function OnClassSelected(classId, modelStyle, gender)",
        "-- ============================================================================\n-- 返回主菜单", `${dir}/main.lua`);
    check(/if saved then[\s\S]*SyncAccountLeaderboard\(\)/.test(createBlock),
        `${dir}/main.lua 成功创建角色后没有同步排行榜`);
    const fetchBlock = blockBetween(main,
        "local function LoadPlatformLeaderboardBoard(boardId, callback)",
        "-- ============================================================================\n-- 引擎入口", `${dir}/main.lua`);
    check(fetchBlock.includes("SyncAccountLeaderboard({")
        && fetchBlock.includes("PlatformLeaderboard.Fetch(")
        && fetchBlock.indexOf("SyncAccountLeaderboard({") < fetchBlock.lastIndexOf("fetchBoard()"),
    `${dir}/main.lua 打开榜单前没有先同步当前记录`);
    check(main.includes("GameUI.onLeaderboardPressed = function()")
        && main.includes("GameUI.ShowLeaderboardPanel({")
        && main.includes("loadBoard = LoadPlatformLeaderboardBoard"),
    `${dir}/main.lua 没有绑定排行榜入口`);

    const leaderboardUiBlock = blockBetween(ui,
        "function GameUI.ShowLeaderboardPanel(options, boardId)",
        "function GameUI.HideLeaderboardPanel()", `${dir}/GameUI.lua`);
    for (const [id, , boardLabel] of expectedBoards) {
        check(ui.includes(`id = "${id}"`) && ui.includes(`label = "${boardLabel}"`),
            `${dir}/GameUI.lua 缺少 ${boardLabel} Tab`);
    }
    check(ui.includes('text = "排行榜"')
        && ui.includes("GameUI.onLeaderboardPressed"),
    `${dir}/GameUI.lua 系统菜单缺少排行榜入口`);
    check(leaderboardUiBlock.includes('_CreateOverlayHeader("平台排行榜"')
        && (leaderboardUiBlock.includes('backText = "X"') || ui.includes('options.backText or "X"')),
    `${dir}/GameUI.lua 排行榜缺少固定 X 关闭入口`);
    check(leaderboardUiBlock.includes('id = "leaderboardOverlay"')
        && leaderboardUiBlock.includes("onClick = function() GameUI.HideLeaderboardPanel() end")
        && leaderboardUiBlock.includes("onClick = function() end"),
    `${dir}/GameUI.lua 排行榜遮罩关闭或内容区防误关行为缺失`);
    check(ui.includes("if uiState.leaderboardOpen then\n        GameUI.HideLeaderboardPanel()")
        && main.includes("input:GetKeyPress(KEY_ESCAPE) and GameUI.HandleBackAction()"),
    `${dir} 排行榜没有接入 ESC/Android 返回键逐层关闭`);
    check(ui.includes("rank == 1") && ui.includes("rank == 2") && ui.includes("rank == 3")
        && ui.includes("我的排名："),
    `${dir}/GameUI.lua 缺少前三名配色或个人排名显示`);
}

console.log("platform_leaderboard_regression: PASS");
