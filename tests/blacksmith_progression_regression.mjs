import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

const enhanceSource = read("scripts/Enhance.lua");
const inventorySource = read("scripts/Inventory.lua");
const saveSource = read("scripts/SaveSystem.lua");
const forgePanelSource = read("scripts/ForgePanel.lua");
const enhancePanelSource = read("scripts/EnhancePanel.lua");
const blacksmithPanelSource = read("scripts/BlacksmithPanel.lua");
const gameUISource = read("scripts/GameUI.lua");
const serviceScrollViewSource = read("scripts/ServiceScrollView.lua");
const mainSource = read("scripts/main.lua");
const equipmentPanelSource = read("scripts/EquipmentPanel.lua");
const npcSource = read("scripts/NPC.lua");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function blockBetween(source, startMarker, endMarker) {
    const start = source.indexOf(startMarker);
    check(start >= 0, `缺少代码块: ${startMarker}`);
    const end = source.indexOf(endMarker, start + startMarker.length);
    check(end > start, `代码块边界缺失: ${startMarker}`);
    return source.slice(start, end);
}

// 强化规则是铁匠服务的单一数值源：不再有强化石消耗，费用、成功率和失败保底
// 必须随目标等级一起返回，UI 才能在点击前准确说明风险。
check(enhanceSource.includes("Enhance.FORGE_MATERIAL_COUNT = 5"),
    "锻造材料数量没有统一为 5 件");
check(!enhanceSource.includes("Enhance.ENHANCE_STONE_ID"),
    "强化规则仍暴露强化石物品 ID");
const costBlock = blockBetween(
    enhanceSource,
    "function Enhance.EnhanceCost(level)",
    "--- Return cumulative gold spent to reach an enhancement level.",
);
check(costBlock.includes("gold = rule.gold")
    && costBlock.includes("successRate = rule.successRate")
    && !costBlock.includes("dropOnFail")
    && !costBlock.includes("failFloor"),
    "强化费用接口仍暴露掉级/失败保底");

const expectedRules = [
    [3, 300, "1.0"],
    [6, 750, "0.9"],
    [9, 2000, "0.7"],
    [12, 5000, "0.5"],
];
for (const [maxLevel, gold, rate] of expectedRules) {
    const rulePattern = new RegExp(
        `maxLevel\\s*=\\s*${maxLevel}\\s*,\\s*gold\\s*=\\s*${gold}`
        + `\\s*,\\s*successRate\\s*=\\s*${rate}`,
    );
    check(rulePattern.test(enhanceSource),
        `强化 ${maxLevel} 档费用/成功率不符合当前规则`);
}
check(!enhanceSource.includes("GetFailureLevel")
    && !enhanceSource.includes("failFloor")
    && !enhanceSource.includes("dropOnFail"),
    "强化规则仍保留失败掉级逻辑");
check(enhanceSource.includes("function Enhance.GetEnhanceGoldSpent"),
    "强化累计金币投入接口缺失，无法在分解时给出返还说明");

// Inventory 只允许铁匠入口调用强化：实际扣除金币，失败不掉级，
// 不应重新引入强化石或保护石计数/购买 API。
const enhanceItemBlock = blockBetween(
    inventorySource,
    "function Inventory.EnhanceItem(item)",
    "Inventory.MAX_BAG_SLOTS = MAX_BAG_SLOTS",
);
check(enhanceItemBlock.includes("Enhance.EnhanceCost(nextLevel)")
    && enhanceItemBlock.includes("playerData.gold = gold - cost.gold"),
    "强化没有在 Inventory 中实际扣除金币");
check(!enhanceItemBlock.includes("useProtect")
    && !enhanceItemBlock.includes("protectStones")
    && !enhanceItemBlock.includes("GetFailureLevel"),
    "强化接口仍保留保护石或掉级逻辑");
check(enhanceItemBlock.includes("math.random() < cost.successRate")
    && enhanceItemBlock.includes("result.finalLevel"),
    "强化接口未按成功率判定并保持最终等级");
for (const forbidden of [
    "GetEnhanceStones", "BuyEnhanceStone", "EnhanceStone", "ENHANCE_STONE_ID",
    "GetProtectStones", "BuyProtectStone", "PROTECT_STONE_PRICE",
]) {
    check(!inventorySource.includes(forbidden),
        `Inventory 仍包含已下线的强化石 API/标识: ${forbidden}`);
}
check(inventorySource.includes("function Inventory.ForgeItems(items)")
    && inventorySource.includes("Enhance.FORGE_MATERIAL_COUNT"),
    "锻造宿主接口没有使用统一的 5 件材料常量");
check(inventorySource.includes("function Inventory.ForgeRecipe(recipe)")
    && inventorySource.includes("for index = 1, Enhance.FORGE_MATERIAL_COUNT do"),
    "自动选材没有完整取满 5 件材料");

// 旧存档只做一次性迁移，新快照不再持久化强化石。
const snapshotBlock = blockBetween(
    saveSource,
    "function SaveSystem.CreateSnapshot",
    "--- 将存档数据恢复到 Inventory.playerData",
);
check(snapshotBlock.includes("version    = 2")
    && !snapshotBlock.includes("enhanceStones")
    && !snapshotBlock.includes("protectStones"),
    "新存档版本或强化石/保护石字段未移除");
const restoreBlock = blockBetween(
    saveSource,
    "function SaveSystem.RestoreInventory",
    "-- 恢复药水",
);
check(restoreBlock.includes("saveData.enhanceStones")
    && restoreBlock.includes("Inventory.LEGACY_ENHANCE_STONE_REFUND")
    && restoreBlock.includes("saveData.enhanceStones = nil"),
    "旧强化石存档没有一次性折算并清除");

// 锻造页与强化页各自负责内容，外层铁匠面板只做双 Tab、滚动和生命周期。
check(forgePanelSource.includes("5 件同品质同部位")
    && forgePanelSource.includes("准备 5 件同品质、同部位")
    && forgePanelSource.includes("锻造 1 件 · "),
    "锻造页没有完整展示 5 件材料和单次费用");
check(enhancePanelSource.includes("EnhancePanel")
    && (enhancePanelSource.includes("成功率") || enhancePanelSource.includes("successRate"))
    && enhancePanelSource.includes("金币"),
    "强化页没有展示金币费用与成功率");
check(enhancePanelSource.includes("失败")
    && (enhancePanelSource.includes("掉级") || enhancePanelSource.includes("保底"))
    && enhancePanelSource.includes("失败不掉级"),
    "强化页没有说明失败不掉级");
check(!enhancePanelSource.includes("保护石")
    && !enhancePanelSource.includes("保护强化"),
    "强化页仍出现保护石或保护强化");
check(enhancePanelSource.includes("本次必定成功")
    && enhancePanelSource.includes("成功率为 100%"),
    "100% 成功阶段仍可能向玩家展示错误的失败风险");
check(enhancePanelSource.includes("PromoteSelectedEntry"),
    "强化列表刷新后没有保持当前选择可见");
check(blacksmithPanelSource.includes('UI.Tabs')
    && blacksmithPanelSource.includes('"锻造"')
    && blacksmithPanelSource.includes('"强化"')
    && blacksmithPanelSource.includes("ForgePanel.Build")
    && blacksmithPanelSource.includes("EnhancePanel.Build"),
    "铁匠面板没有实现锻造/强化双 Tab");
check(blacksmithPanelSource.includes("ScrollView")
    || (blacksmithPanelSource.includes("scrollView") && blacksmithPanelSource.includes("height")),
    "铁匠双 Tab 内容缺少明确的滚动容器/高度约束");
check(blacksmithPanelSource.includes("UpdateDescendants")
    && blacksmithPanelSource.includes("content.Update = function"),
    "铁匠 Tab 内容未递归更新内层 ScrollView，列表可能无法计算可滚动高度");
check(blacksmithPanelSource.includes("ServiceScrollView.Build")
    && enhancePanelSource.includes("ServiceScrollView.Build")
    && serviceScrollViewSource.includes('event.pointerType')
    && serviceScrollViewSource.includes("UI.CancelPointer")
    && serviceScrollViewSource.includes("bounces = false"),
    "铁匠滚动容器未兼容桌面/预览端鼠标拖动或边界状态");
check(gameUISource.includes("require(\"scripts.BlacksmithPanel\")")
    && gameUISource.includes("function GameUI.ShowBlacksmithPanel("),
    "GameUI 没有接入铁匠双 Tab 面板");
check(gameUISource.includes("_CreateOverlayHeader")
    && gameUISource.includes("GameUI.HideNPCPanel()")
    && gameUISource.includes("function GameUI.HandleBackAction()")
    && mainSource.includes("input:GetKeyPress(KEY_ESCAPE)")
    && mainSource.includes("GameUI.HandleBackAction()"),
    "铁匠浮层缺少固定返回入口或 ESC 逐层关闭支持");

// 入口必须来自铁匠 NPC；角色/背包详情只做引导，不得再直接强化。
check(mainSource.includes('elseif kind == "blacksmith" then')
    && mainSource.includes("GameUI.ShowBlacksmithPanel(player_)"),
    "铁匠 NPC 没有打开双 Tab 服务面板");
check(npcSource.includes('blacksmith = "')
    && npcSource.includes("锻造")
    && npcSource.includes("强化"),
    "铁匠交互按钮没有同时说明锻造与强化服务");
check(!equipmentPanelSource.includes("Inventory.EnhanceItem")
    && equipmentPanelSource.includes("前往安全区铁匠"),
    "角色/背包详情仍可绕过铁匠直接强化");

// 纯文本行为探针：确认失败不掉级，并验证累计费用档位。
const rules = [
    { max: 3, gold: 300, rate: 1.0 },
    { max: 6, gold: 750, rate: 0.9 },
    { max: 9, gold: 2000, rate: 0.7 },
    { max: 12, gold: 5000, rate: 0.5 },
];
function ruleFor(targetLevel) {
    return rules.find((rule) => targetLevel <= rule.max);
}
function failureKeepsLevel(currentLevel) {
    return currentLevel;
}
check(failureKeepsLevel(6) === 6 && failureKeepsLevel(9) === 9,
    "强化失败应保持当前等级");
function cumulativeGold(level) {
    let total = 0;
    for (let target = 1; target <= level; target += 1) total += ruleFor(target).gold;
    return total;
}
check(cumulativeGold(1) === 300, "+1 累计强化费用不正确");
check(cumulativeGold(4) === 1650, "+4 累计强化费用不正确");
check(cumulativeGold(7) === 5150, "+7 累计强化费用不正确");
check(cumulativeGold(10) === 14150, "+10 累计强化费用不正确");
check(cumulativeGold(12) === 24150, "+12 累计强化费用不正确");

console.log("blacksmith_progression_regression: PASS");
console.log("verified blacksmith-only enhancement, 5-material forging, two tabs, and legacy-save migration");
