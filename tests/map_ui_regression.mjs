import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const check = (condition, message) => {
    if (!condition) throw new Error(message);
};

const mirrors = [
    "scripts",
    "assets/scripts",
    ".shotproj/scripts",
];

function blockBetween(source, startMarker, endMarker) {
    const start = source.indexOf(startMarker);
    check(start >= 0, `缺少代码块: ${startMarker}`);
    const end = source.indexOf(endMarker, start + startMarker.length);
    check(end > start, `代码块边界缺失: ${startMarker}`);
    return source.slice(start, end);
}

// 地图 UI 与主流程必须读取同一个根模块；否则 MapZone.currentMapId 会被
// 分成两个实例，切图成功后 HUD 仍会渲染默认 map_bq。
for (const dir of mirrors) {
    const ui = read(`${dir}/GameUI.lua`);
    const main = read(`${dir}/main.lua`);
    const save = read(`${dir}/SaveSystem.lua`);

    check(ui.includes('local MapZone = require("MapZone")'),
        `${dir}/GameUI.lua 未读取 canonical MapZone`);
    check(!ui.includes('local MapZone = require("scripts.MapZone")'),
        `${dir}/GameUI.lua 仍可能读取旧 MapZone 镜像`);
    check(ui.includes("MINI_MAP_LANDMARK_COUNT"),
        `${dir}/GameUI.lua 未创建固定小地图地标控件`);
    check(ui.includes("uiState.refs.miniMapLandmarks = miniLandmarkDots"),
        `${dir}/GameUI.lua 未保存小地图地标引用`);
    check(ui.includes("local function _FindMatchingLandmark"),
        `${dir}/GameUI.lua 未提供任务目标到地标的匹配逻辑`);
    check(ui.includes("markerForMap = marker and marker.mapId == mapId"),
        `${dir}/GameUI.lua 未按当前地图过滤任务地标`);
    check(ui.includes("landmarkDot:SetVisible(true)"),
        `${dir}/GameUI.lua 切图后未刷新地标可见性`);
    check(ui.includes("function GameUI.RefreshMap(mapId)"),
        `${dir}/GameUI.lua 缺少地图缓存失效入口`);
    check(ui.includes("landmarkRef.root:SetVisible(false)"),
        `${dir}/GameUI.lua 切图时未清理全图旧地标`);

    const switchBlock = blockBetween(
        main,
        "function SwitchMap(mapId)",
        "HandleQuestMapEntered = function(mapId)",
    );
    check(switchBlock.includes("GameUI.RefreshMap(mapId)"),
        `${dir}/main.lua 切图后未使地图 UI 缓存失效`);

    check(save.includes('mapId      = (require("Combat").currentMapId)'),
        `${dir}/SaveSystem.lua 未读取与主流程相同的 Combat 地图状态`);
    check(!save.includes('mapId      = (require("scripts.Combat").currentMapId)'),
        `${dir}/SaveSystem.lua 仍读取旧 Combat 镜像`);

    for (const screenshotEntry of ["_shot_class.lua", "_shot_slots.lua", "_shot_game.lua"]) {
        const shot = read(`${dir}/${screenshotEntry}`);
        check(shot.includes('local GameUI = require("GameUI")'),
            `${dir}/${screenshotEntry} 未使用 canonical GameUI`);
        check(!shot.includes('require("scripts.GameUI")'),
            `${dir}/${screenshotEntry} 仍可能加载旧 GameUI 镜像`);
        check(shot.includes('local SaveSystem = require("SaveSystem")'),
            `${dir}/${screenshotEntry} 未使用 canonical SaveSystem`);
        check(!shot.includes('require("scripts.SaveSystem")'),
            `${dir}/${screenshotEntry} 仍可能加载旧 SaveSystem 镜像`);
        check(shot.includes('require "main"'),
            `${dir}/${screenshotEntry} 未从 canonical main 入口启动`);
        check(!shot.includes('require "scripts.main"'),
            `${dir}/${screenshotEntry} 仍可能启动旧 main 镜像`);
    }
}

// 任务目标必须能落到 MapZone 的同名/同坐标地标；这些是巡逻、坚守和
// 显式遭遇共用的策划点，避免 UI 再维护第二套位置表。
const mapSource = read("scripts/MapZone.lua");
const questSource = read("scripts/Quest.lua");
const targetLandmarks = [
    ["荒村废墟", -30, -22],
    ["断桥", 15, 12],
    ["黄沙商路", -34, -9],
    ["北城残垣", 0, 40],
    ["石墓入口", 30, 20],
    ["灯塔", 0, 38],
    ["西水道", -30, 0],
    ["蚁穴入口", 30, -26],
    ["石柱廊", -12, -22],
    ["封印祭坛", 0, 18],
    ["教主殿", 30, -28],
    ["熔火龙巢", 0, -32],
    ["深渊王座", 30, 26],
];

for (const [name, x, z] of targetLandmarks) {
    const pair = `name = "${name}", x = ${x}, z = ${z}`;
    check(mapSource.includes(pair), `MapZone 缺少任务地标 ${name} (${x}, ${z})`);
    check(questSource.includes(pair), `Quest 缺少与地图一致的目标地标 ${name} (${x}, ${z})`);
}

console.log("map_ui_regression: PASS");
