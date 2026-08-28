import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const scriptDirs = ["scripts", "assets/scripts", ".shotproj/scripts"];
const files = [
    "Enhance.lua",
    "Inventory.lua",
    "EnhancePanel.lua",
    "EquipmentPanel.lua",
    "main.lua",
    "SaveSystem.lua",
];

function check(condition, message) {
    if (!condition) throw new Error(message);
}

const forbidden = [
    "protectStones",
    "GetProtectStones",
    "BuyProtectStone",
    "PROTECT_STONE_PRICE",
    "useProtect",
    "protectStoneSpent",
    "保护石",
    "保护强化",
    "GetFailureLevel",
    "dropOnFail",
    "failFloor",
];

for (const dir of scriptDirs) {
    for (const file of files) {
        const relative = path.join(dir, file);
        const source = fs.readFileSync(path.join(root, relative), "utf8");
        for (const marker of forbidden) {
            check(!source.includes(marker), `${relative} 仍包含已下线逻辑: ${marker}`);
        }
    }

    const enhance = fs.readFileSync(path.join(root, dir, "Enhance.lua"), "utf8");
    const inventory = fs.readFileSync(path.join(root, dir, "Inventory.lua"), "utf8");
    const save = fs.readFileSync(path.join(root, dir, "SaveSystem.lua"), "utf8");

    check(enhance.includes("function Enhance.EnhanceCost(level)"),
        `${dir}/Enhance.lua 缺少金币强化费用接口`);
    check(inventory.includes("function Inventory.EnhanceItem(item)"),
        `${dir}/Inventory.lua 强化接口仍不是纯金币单参数形式`);
    check(save.includes("saveData.enhanceStones")
        && save.includes("Inventory.LEGACY_ENHANCE_STONE_REFUND")
        && save.includes("saveData.enhanceStones = nil"),
        `${dir}/SaveSystem.lua 未保留旧强化石一次性金币迁移`);
}

console.log("protection_stone_removal_regression: PASS");
console.log("verified all script mirrors remove protection-stone display, purchase, enhancement, and persistence");
