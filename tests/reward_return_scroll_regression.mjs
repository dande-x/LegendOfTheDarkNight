import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const files = {
    canonical: {
        ui: "scripts/GameUI.lua",
        main: "scripts/main.lua",
        character: "scripts/CharacterClass.lua",
        save: "scripts/SaveSystem.lua",
    },
    assets: {
        ui: "assets/scripts/GameUI.lua",
        main: "assets/scripts/main.lua",
        character: "assets/scripts/CharacterClass.lua",
        save: "assets/scripts/SaveSystem.lua",
    },
    shotproj: {
        ui: ".shotproj/scripts/GameUI.lua",
        main: ".shotproj/scripts/main.lua",
        character: ".shotproj/scripts/CharacterClass.lua",
        save: ".shotproj/scripts/SaveSystem.lua",
    },
};

const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const check = (condition, message) => {
    if (!condition) throw new Error(message);
};

function functionBlock(source, marker) {
    const start = source.indexOf(`function ${marker}(`);
    check(start >= 0, `无法定位函数 ${marker}`);
    const nextFunction = source.indexOf("\nfunction ", start + marker.length + 10);
    const nextLocal = source.indexOf("\nlocal function ", start + marker.length + 10);
    const ends = [nextFunction, nextLocal].filter((index) => index >= 0);
    return source.slice(start, ends.length ? Math.min(...ends) : source.length);
}

for (const [name, paths] of Object.entries(files)) {
    const ui = read(paths.ui);
    const main = read(paths.main);
    const character = read(paths.character);
    const save = read(paths.save);
    const systemPanel = functionBlock(ui, "GameUI.ShowSystemPanel");
    const callbacks = functionBlock(main, "SetupGameCallbacks");

    check(ui.includes("GameUI.onRewardAdRequested"), `${name}: GameUI 缺少广告请求回调接口`);
    check(ui.includes("GameUI.onUseReturnScroll"), `${name}: GameUI 缺少使用回城卷轴回调接口`);
    check(ui.includes("function GameUI.ShowSupportAuthorDialog"), `${name}: 缺少鼓励作者弹窗`);
    check(ui.includes("function GameUI.ShowRewardAdResult"), `${name}: 缺少广告结果弹窗`);
    check(ui.includes("祝大家玩的开心，如果喜欢这个游戏，可观看广告鼓励一下作者，非常感谢，观看广告完成有小奖励。"),
        `${name}: 广告说明文案不完整`);
    check(ui.includes('confirmText = "观看广告"'), `${name}: 弹窗缺少观看广告按钮`);
    check(systemPanel.includes('text = "使用回城卷轴"'), `${name}: 系统设置缺少使用回城卷轴按钮`);
    check(systemPanel.includes("returnScrollPanel"), `${name}: 使用回城卷轴入口没有加入系统面板`);
    check(systemPanel.includes("visible = returnScrollUnlocked"),
        `${name}: 未解锁时没有隐藏使用回城卷轴入口`);
    check(ui.includes("panel:SetVisible(unlocked)"),
        `${name}: 广告解锁后没有恢复使用回城卷轴入口显示`);
    check(systemPanel.includes('text = "鼓励作者"'), `${name}: 系统菜单缺少鼓励作者入口`);
    check(systemPanel.indexOf('text = "鼓励作者"') > systemPanel.indexOf("if GameUI.debugMode then"),
        `${name}: 鼓励作者没有放在系统菜单最后的调试区之后`);
    check(!systemPanel.includes("一键回城") && !systemPanel.includes('text = "回城"'),
        `${name}: 系统面板仍显示旧的回城名称`);

    check(callbacks.includes("ShowRewardVideoAd"), `${name}: 没有调用激励视频 SDK`);
    check(callbacks.includes("result.success == true"), `${name}: 广告奖励没有严格使用 success=true`);
    check(callbacks.includes("callbackFired") && callbacks.includes("completed"),
        `${name}: 广告回调缺少同步/异步一次性完成保护`);
    check(callbacks.includes("accepted == false"), `${name}: 没有处理 SDK 请求未受理`);
    check(callbacks.includes("returnScrollUnlocked = true"), `${name}: 广告成功没有解锁使用回城卷轴`);
    check(callbacks.includes("Inventory.AddGold(1)"),
        `${name}: 使用回城卷轴解锁后再次观看广告没有奖励 1 枚金币`);
    check(callbacks.includes("获取了 1 枚金币和作者的感恩。"),
        `${name}: 再次观看广告后的金币奖励弹窗文案不正确`);
    check(callbacks.includes("Combat.CancelPlayerHostileEffects()")
        && callbacks.includes("Combat.CancelDash()"),
        `${name}: 使用回城卷轴没有清理敌对效果和冲刺状态`);
    check(callbacks.includes("mapDef.spawnPos") && callbacks.includes("SetLinearVelocity(Vector3.ZERO)"),
        `${name}: 使用回城卷轴没有返回安全区出生点或清零速度`);
    check(callbacks.includes('GameUI.ShowToast("已使用回城卷轴，返回安全区"'),
        `${name}: 使用回城卷轴成功提示文案不正确`);
    const returnBlockStart = callbacks.indexOf("GameUI.onUseReturnScroll = function()");
    check(returnBlockStart >= 0, `${name}: 缺少使用回城卷轴实现`);
    const returnBlockEnd = callbacks.indexOf("\n    -- Debug 等级调整回调", returnBlockStart);
    const returnBlock = callbacks.slice(
        returnBlockStart,
        returnBlockEnd >= 0 ? returnBlockEnd : callbacks.length,
    );
    check(!returnBlock.includes("SwitchMap("), `${name}: 使用回城卷轴不应切换地图`);

    check(character.includes("returnScrollUnlocked = false"), `${name}: 新角色没有初始化奖励状态`);
    check(save.includes("returnScrollUnlocked = player.returnScrollUnlocked == true"),
        `${name}: 快照没有保存使用回城卷轴解锁状态`);
    check(save.includes("player.returnScrollUnlocked = saveData.returnScrollUnlocked == true"),
        `${name}: 读档没有恢复使用回城卷轴解锁状态`);
}

// Small state model for the SDK contract: only the completion callback can
// grant the reward; false/no-callback and duplicate callbacks are failures or
// no-ops, never additional rewards.
function simulateRewardRequest({
    accepted,
    callbackResults = [],
    watchdog = false,
    unlockedBefore = false,
}) {
    let inFlight = true;
    let unlocked = unlockedBefore;
    let gold = 0;
    let rewardCount = 0;
    let resultCount = 0;
    let completed = false;

    const finish = (result) => {
        if (completed) return;
        completed = true;
        inFlight = false;
        resultCount += 1;
        if (result?.success === true) {
            if (unlocked) gold += 1;
            else unlocked = true;
            rewardCount += 1;
        }
    };

    for (const result of callbackResults) finish(result);
    if (accepted === false && inFlight) finish({ success: false, msg: "广告暂不可用" });
    if (watchdog && inFlight) finish({ success: false, msg: "广告响应超时" });
    return { inFlight, unlocked, gold, rewardCount, resultCount };
}

check(simulateRewardRequest({ accepted: true, callbackResults: [{ success: true }] }).unlocked,
    "success=true 没有解锁使用回城卷轴");
check(!simulateRewardRequest({ accepted: true, callbackResults: [{ success: false }] }).unlocked,
    "success=false 错误解锁了使用回城卷轴");
check(!simulateRewardRequest({ accepted: false }).unlocked,
    "请求未受理且无回调时错误解锁了使用回城卷轴");
check(simulateRewardRequest({
    accepted: true,
    unlockedBefore: true,
    callbackResults: [{ success: true }],
}).gold === 1,
    "已解锁后再次完整观看广告没有获得 1 枚金币");
check(simulateRewardRequest({
    accepted: true,
    unlockedBefore: false,
    callbackResults: [{ success: true }],
}).gold === 0,
    "首次完整观看广告不应同时发放重复金币奖励");
check(simulateRewardRequest({ accepted: true, watchdog: true }).resultCount === 1,
    "无回调 watchdog 没有结束广告请求");
const duplicate = simulateRewardRequest({
    accepted: true,
    callbackResults: [{ success: true }, { success: true }],
});
check(duplicate.rewardCount === 1 && duplicate.resultCount === 1,
    "重复成功回调导致重复发奖或重复提示");

console.log("reward_return_scroll_regression: PASS");
console.log("verified ad reward gating, persistent unlock state, safe-zone return, and all runtime mirrors");
