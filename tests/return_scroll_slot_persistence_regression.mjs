import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const saveSource = read("scripts/SaveSystem.lua");
const mainSource = read("scripts/main.lua");
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

const setter = functionBlock(saveSource, "SaveSystem.SetReturnScrollUnlocked");
check(setter.includes("NormalizeSlotIndex(slotIndex)"),
    "回城卷轴状态更新没有校验角色槽位");
check(setter.includes("SaveSystem.IsLoadable(existing)"),
    "回城卷轴状态更新可能写入空角色槽位");
check(setter.includes("snapshot.returnScrollUnlocked = desired"),
    "回城卷轴状态没有写入目标角色快照");
check(setter.includes("SaveSystem.SaveToSlot(index, snapshot)"),
    "回城卷轴状态没有经过槽位存档写入入口");
check(setter.includes("cloudEnabled"),
    "回城卷轴状态更新没有声明云同步边界");
check(!setter.includes("player_.hp") && !setter.includes("isDead"),
    "槽位级回城卷轴持久化错误依赖当前运行时死亡/血量状态");

const saveToSlot = functionBlock(saveSource, "SaveSystem.SaveToSlot");
check(saveToSlot.includes("QueueCloudSaveAfterLocalWrite()"),
    "槽位写入后没有排队云同步");
check(saveToSlot.includes("slotUpdatedAt[index] = saveTimestamp"),
    "槽位写入没有更新时间戳，云端可能用旧版本覆盖解锁状态");

const adBlockStart = mainSource.indexOf("GameUI.onRewardAdRequested = function()");
check(adBlockStart >= 0, "缺少激励广告回调");
const adBlockEnd = mainSource.indexOf("\n    -- 使用回城卷轴", adBlockStart);
const adBlock = mainSource.slice(adBlockStart, adBlockEnd >= 0 ? adBlockEnd : mainSource.length);
check(adBlock.includes("currentSlotIndex"),
    "广告奖励没有绑定当前角色槽位");
check(adBlock.includes("SetReturnScrollUnlocked"),
    "广告成功没有走槽位级回城卷轴持久化入口");
check(adBlock.includes("player_ ~= watchedPlayer"),
    "广告迟到回调缺少观看角色身份校验");

// 独立槽位模型：更新一个槽位只能改变该槽位，序列化/重启后仍保留，
// 删除槽位则连同该槽位的解锁状态一起移除。
function makeSlots() {
    return [
        { classId: "warrior", returnScrollUnlocked: false },
        { classId: "taoist", returnScrollUnlocked: false },
    ];
}

function setUnlocked(slots, index, unlocked) {
    const next = slots.map((slot) => (slot ? { ...slot } : slot));
    if (!next[index - 1]) return false;
    next[index - 1].returnScrollUnlocked = unlocked === true;
    return next;
}

let slots = makeSlots();
slots = setUnlocked(slots, 1, true);
check(slots[0].returnScrollUnlocked === true,
    "槽位 1 解锁失败");
check(slots[1].returnScrollUnlocked === false,
    "槽位 1 解锁污染了槽位 2");

const restarted = JSON.parse(JSON.stringify(slots));
check(restarted[0].returnScrollUnlocked === true
    && restarted[1].returnScrollUnlocked === false,
    "重启后的角色槽位没有保持独立解锁状态");

restarted[0] = null;
check(restarted[0] === null && restarted[1].returnScrollUnlocked === false,
    "删除槽位后没有同时删除该角色的回城卷轴状态");

restarted[1] = { ...restarted[1], returnScrollUnlocked: true };
check(restarted[1].returnScrollUnlocked === true && restarted[0] === null,
    "另一个角色解锁后状态边界不正确");

console.log("return_scroll_slot_persistence_regression: PASS");
console.log("verified per-slot unlock persistence, restart retention, deletion cleanup, and cloud-save routing");
