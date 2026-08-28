import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

const mirrors = [
    "scripts",
    "assets/scripts",
    ".shotproj/scripts",
];

function check(condition, message) {
    if (!condition) throw new Error(message);
}

// The real progression is Lua, so this small model verifies the boundary
// behavior without requiring an UrhoX runtime in the regression environment.
function expToNext(level) {
    return Math.floor(75 + 38 * level + 1.6 * level * level);
}

function addExperience(player, amount) {
    player.exp += amount;
    while (player.exp >= player.expToNext) {
        player.exp -= player.expToNext;
        player.level += 1;
        player.expToNext = expToNext(player.level);
    }
}

function makeBootsClickSequence() {
    let count = 0;
    return (slot) => {
        if (slot !== "boots") {
            count = 0;
            return false;
        }
        count += 1;
        if (count < 5) return false;
        count = 0;
        return true;
    };
}

const player = { level: 50, exp: 0, expToNext: expToNext(50) };
addExperience(player, player.expToNext);
check(player.level === 51, "Lv.50 获得足够经验后没有升级到 Lv.51");
check(player.exp === 0 && player.expToNext === expToNext(51),
    "Lv.51 的经验状态没有正确重算");
addExperience(player, player.expToNext + expToNext(52));
check(player.level === 53, "Lv.51 之后无法继续连续升级");

const bootsClick = makeBootsClickSequence();
for (let click = 1; click <= 4; click += 1) {
    check(bootsClick("boots") === false, `鞋子第 ${click} 次点击提前触发 Debug`);
}
check(bootsClick("boots") === true, "鞋子第 5 次点击没有触发 Debug");
check(bootsClick("helmet") === false && bootsClick("boots") === false,
    "点击其他装备槽后没有清空鞋子点击计数");

for (const dir of mirrors) {
    const balance = read(`${dir}/Balance.lua`);
    const characterClass = read(`${dir}/CharacterClass.lua`);
    const saveSystem = read(`${dir}/SaveSystem.lua`);
    const combat = read(`${dir}/Combat.lua`);
    const gameUI = read(`${dir}/GameUI.lua`);
    const equipmentPanel = read(`${dir}/EquipmentPanel.lua`);
    const main = read(`${dir}/main.lua`);

    check(balance.includes("Balance.MAX_LEVEL = math.huge"),
        `${dir}/Balance.lua 仍把 MAX_LEVEL 设为有限值`);
    check(balance.includes("Balance.LEVEL_SANITY_LIMIT = MAX_VALUE"),
        `${dir}/Balance.lua 缺少损坏数据安全边界`);
    check(!balance.includes("Balance.MAX_LEVEL = 50"),
        `${dir}/Balance.lua 恢复了 Lv.50 硬上限`);

    check(characterClass.includes("while player.level < LEVEL_SANITY_LIMIT"),
        `${dir}/CharacterClass.lua 没有允许 Lv.50 之后继续升级`);
    check(!characterClass.includes("player.level > 50")
        && !characterClass.includes("player.level >= 50"),
        `${dir}/CharacterClass.lua 仍存在 Lv.50 升级拦截`);
    check(saveSystem.includes("local LEVEL_SANITY_LIMIT = Balance.LEVEL_SANITY_LIMIT")
        && !saveSystem.includes("MAX_PLAYER_LEVEL = 50"),
        `${dir}/SaveSystem.lua 仍按 Lv.50 截断存档`);
    check(combat.includes("Balance.LEVEL_SANITY_LIMIT"),
        `${dir}/Combat.lua 仍按 Lv.50 截断玩家等级`);

    // Five clicks are counted only for the boots slot; any other equipment
    // slot clears the sequence, and the fifth click is consumed by the hook.
    check(gameUI.includes("equipmentSlotDebugState = { clickCount = 0 }")
        && gameUI.includes("if slotKey ~= Inventory.SLOT.BOOTS then")
        && gameUI.includes("if equipmentSlotDebugState.clickCount < 5 then return false end")
        && gameUI.includes("GameUI.onDebugBootsSlotActivated"),
        `${dir}/GameUI.lua 缺少鞋子五连点击调试入口`);
    check(equipmentPanel.includes("onEquipmentSlotClick(capturedSlot) == true")
        && equipmentPanel.includes("onClick = handleCellClick"),
        `${dir}/EquipmentPanel.lua 没有让空鞋槽接收点击回调`);
    check(main.includes("GameUI.onDebugBootsSlotActivated = function()")
        && main.includes("math.max(CharacterClass.NormalizeLevel(player_.level), 50)"),
        `${dir}/main.lua 没有把鞋子五连击提升到至少 Lv.50`);

    check(gameUI.includes("local levelDigits = #tostring")
        && gameUI.includes("math.max(46, 27 + levelDigits * 9)"),
        `${dir}/GameUI.lua 的等级标签无法容纳高位数等级`);
}

console.log("level_progression_regression: PASS");
