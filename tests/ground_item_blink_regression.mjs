import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const source = fs.readFileSync(path.join(root, "scripts/Combat.lua"), "utf8");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function blockBetween(startMarker, endMarker) {
    const start = source.indexOf(startMarker);
    check(start >= 0, `缺少代码块: ${startMarker}`);
    const end = source.indexOf(endMarker, start + startMarker.length);
    check(end > start, `代码块边界缺失: ${startMarker}`);
    return source.slice(start, end);
}

const delay = Number(source.match(/local ITEM_PICKUP_DELAY = ([0-9.]+)/)?.[1]);
const interval = Number(source.match(/local ITEM_BLINK_INTERVAL = ([0-9.]+)/)?.[1]);
check(Number.isFinite(delay) && delay > 0, "装备拾取延迟必须是正数");
check(Number.isFinite(interval) && interval > 0 && interval < delay,
    "装备闪烁间隔应小于拾取延迟");

const blinkBlock = blockBetween(
    "local function UpdateGroundItemBlink",
    "local function ReserveGroundEquipmentSlot",
);
check(blinkBlock.includes("if canPickup then"),
    "闪烁状态没有接收可拾取状态");
check(blinkBlock.includes("groundItem.node:SetDeepEnabled(true)"),
    "装备达到可拾取状态后没有恢复完整可见");
check(blinkBlock.includes("groundItem.node:SetDeepEnabled(groundItem.blinkVisible)"),
    "装备闪烁没有递归切换整棵掉落物节点树");
check(blinkBlock.includes("groundItem.blinkTimer / ITEM_BLINK_INTERVAL"),
    "装备闪烁没有按时间步推进");
check(blinkBlock.includes("groundItem.blinkActive = false"),
    "装备达到可拾取状态后没有停止闪烁");

const spawnBlock = blockBetween(
    "function Combat.SpawnGroundItem",
    "--- 更新地面物品（金币磁吸 + 装备靠近拾取）",
);
for (const field of ["blinkTimer = 0", "blinkVisible = true", "blinkActive = true"]) {
    check(spawnBlock.includes(field), `新装备掉落缺少闪烁初始状态: ${field}`);
}

const updateBlock = blockBetween(
    "function Combat.UpdateGroundItems",
    "-- ============================================================================\n-- 工具函数",
);
const itemBranchStart = updateBlock.indexOf('elseif g.type == "item"');
check(itemBranchStart >= 0, "缺少装备地面物品更新分支");
const itemBlock = updateBlock.slice(itemBranchStart);
const goldBlock = updateBlock.slice(0, itemBranchStart);
check(!goldBlock.includes("UpdateGroundItemBlink"),
    "金币掉落不应复用装备闪烁逻辑");
check(itemBlock.includes("local canPickup = not g.falling and g.pickupDelayTimer >= ITEM_PICKUP_DELAY"),
    "闪烁结束条件没有与实际可拾取条件绑定");
check(itemBlock.indexOf("UpdateGroundItemBlink(g, dt, canPickup)")
    < itemBlock.indexOf("if canPickup"),
    "装备应先更新闪烁状态，再执行拾取回调");
check(itemBlock.includes("g.pickupRetryTimer <= 0 and dist < ITEM_PICKUP_DIST"),
    "装备闪烁改动不应放宽原有拾取距离/重试条件");

// 用与 Lua 相同的状态转移做一个小型行为探针，覆盖“延迟内闪烁、延迟后常亮”。
function advance(state, dt, canPickup) {
    if (canPickup) {
        state.blinkActive = false;
        state.blinkTimer = 0;
        state.blinkVisible = true;
        return;
    }
    state.blinkActive = true;
    state.blinkTimer += Math.max(0, dt);
    const toggles = Math.floor(state.blinkTimer / interval);
    if (toggles <= 0) return;
    state.blinkTimer -= toggles * interval;
    if (toggles % 2 === 1) state.blinkVisible = !state.blinkVisible;
}

const state = { blinkActive: true, blinkTimer: 0, blinkVisible: true };
advance(state, interval, false);
check(state.blinkVisible === false && state.blinkActive === true,
    "装备在不可拾取阶段没有按间隔隐藏");
advance(state, interval, false);
check(state.blinkVisible === true, "装备闪烁没有恢复显示");
advance(state, 0.01, true);
check(state.blinkVisible === true && state.blinkActive === false && state.blinkTimer === 0,
    "装备可拾取后没有保持常亮并停止计时");

console.log("ground_item_blink_regression: PASS");
console.log(`checked pickup delay ${delay}s and blink interval ${interval}s`);
