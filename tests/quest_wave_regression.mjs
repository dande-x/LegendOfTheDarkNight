import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const combatSource = read("scripts/Combat.lua");
const questSource = read("scripts/Quest.lua");
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

const roomBlock = functionBlock(
    combatSource,
    "local function MakeQuestGroupRoom(",
    ["\nfunction Combat.SpawnEnemyGroup("],
);
check(roomBlock.includes("#enemies + requestedCount - maxEnemies"),
    "任务敌群没有按请求数量预留地图容量");
check(roomBlock.includes('enemy.tier ~= "boss"')
    && roomBlock.includes("not enemy.encounterId"),
    "任务波次腾位可能误删 Boss 或显式遭遇实体");
check(roomBlock.includes('spawnSource == "natural"'),
    "任务波次没有优先回收普通自然怪");
check(roomBlock.includes("GetQuestGroupOwner(enemy.questGroupId) ~= activeQuestId"),
    "任务波次没有保护当前任务已经生成的敌群");
check(roomBlock.includes("if #candidates < slotsNeeded then return false, 0 end"),
    "容量不足时仍可能生成半组敌人");
check(roomBlock.includes("a.distanceSq > b.distanceSq"),
    "腾位没有优先选择远离目标区域的普通敌人");

const groupBlock = functionBlock(
    combatSource,
    "function Combat.SpawnEnemyGroup(",
    ["\nfunction Combat.TriggerDeath(", "\nlocal function FaceEnemyDir("],
);
const reserveAt = groupBlock.indexOf("MakeQuestGroupRoom(");
const spawnAt = groupBlock.indexOf("Combat.SpawnEnemy(");
check(reserveAt >= 0 && spawnAt > reserveAt,
    "任务敌群在预留完整容量前就开始创建实体");
check(groupBlock.includes("if spawned ~= count then")
    && groupBlock.includes("RemoveEnemyImmediately(enemy)"),
    "任务敌群创建异常时没有整组回滚");
check(groupBlock.includes("requested=%d actual=%d reclaimed=%d"),
    "任务敌群日志没有记录请求数、实刷数和腾位数");

const notifyBlock = functionBlock(
    questSource,
    "local function NotifySurviveWaves(",
    ["\nlocal function AdvanceCurrent("],
);
const callbackAt = notifyBlock.indexOf("pcall(Quest.onSurviveWave, q, index, q.area)");
const consumeAt = notifyBlock.indexOf("state.surviveWaveIndex = index");
check(callbackAt >= 0 && consumeAt > callbackAt,
    "坚守波次仍在实际处理前就被标记为已触发");
check(notifyBlock.includes("if handled == false then return false end"),
    "坚守波次失败后不会保留到下一帧重试");

const advanceBlock = functionBlock(
    questSource,
    "local function AdvanceCurrent(",
    ["\nfunction Quest.OnKill("],
);
check(advanceBlock.includes("surviveWavesReady = NotifySurviveWaves(q)"),
    "坚守推进没有接收波次实际处理结果");
check(advanceBlock.includes("Quest._CompleteCurrent()")
    && !advanceBlock.includes('if q.mode ~= "survive" or surviveWavesReady then'),
    "坚守波次失败不应阻塞已满足条件的任务完成");
check(notifyBlock.includes("pcall(Quest.onSurviveWave"),
    "坚守波次回调异常会阻断任务更新");

const waveBlock = functionBlock(
    mainSource,
    "Quest.onSurviveWave = function(",
    ["\n    Quest.onQuestStart = function("],
);
const actualSpawnAt = waveBlock.indexOf("Combat.SpawnEnemyGroup(");
const toastAt = waveBlock.indexOf("GameUI.ShowToast(waveLabel");
check(actualSpawnAt >= 0 && toastAt > actualSpawnAt,
    "“敌群来袭”提示仍早于实际刷怪");
check(waveBlock.includes("if spawned ~= requestedCount then return false end"),
    "实刷数量不足时没有向任务系统报告失败");
check(waveBlock.includes("return true"),
    "完整敌群生成后没有确认波次成功");

// 构建时 assets/scripts 会优先解析为 scripts.* 模块；两份发布镜像必须
// 保持和 canonical scripts/ 相同的坚守契约，否则运行时会重新出现 1/4
// 敌群和任务链卡住的问题。
for (const dir of ["assets/scripts", ".shotproj/scripts"]) {
    const mirrorCombat = read(`${dir}/Combat.lua`);
    const mirrorQuest = read(`${dir}/Quest.lua`);
    const mirrorMain = read(`${dir}/main.lua`);

    check(mirrorQuest.includes("local SURVIVE_DURATION = 30")
        && mirrorQuest.includes('id = "q_004"')
        && mirrorQuest.includes('id = "q_011"')
        && (mirrorQuest.match(/mode = "survive", mapId = "map_[^"]+", count = 30\b/g) ?? []).length === 2,
    `${dir}/Quest.lua 坚守时长没有统一为 30 秒`);

    check(mirrorCombat.includes("local function MakeQuestGroupRoom(")
        && mirrorCombat.includes("if #candidates < slotsNeeded then return false, 0 end")
        && mirrorCombat.includes("if spawned ~= count then")
        && mirrorCombat.includes("RemoveEnemyImmediately(enemy)"),
    `${dir}/Combat.lua 没有任务敌群完整容量保护`);

    const mirrorWaveBlock = functionBlock(
        mirrorMain,
        "Quest.onSurviveWave = function(",
        ["\n    Quest.onQuestStart = function("],
    );
    const mirrorActualSpawnAt = mirrorWaveBlock.indexOf("Combat.SpawnEnemyGroup(");
    const mirrorToastAt = mirrorWaveBlock.indexOf("GameUI.ShowToast(waveLabel");
    check(mirrorActualSpawnAt >= 0 && mirrorToastAt > mirrorActualSpawnAt
        && mirrorWaveBlock.includes("if spawned ~= requestedCount then return false end")
        && mirrorWaveBlock.includes("return true"),
    `${dir}/main.lua 坚守波次没有按实际刷怪结果确认成功`);
    check(mirrorMain.includes("Quest.SURVIVE_DURATION or 30")
        && mirrorMain.includes("最后 30 秒由"),
    `${dir}/main.lua 仍保留 50 秒坚守提示`);
}

console.log("quest_wave_regression: PASS");
console.log("verified canonical and release mirrors for capacity reservation, protected entities, actual-first UI, and retry semantics");
