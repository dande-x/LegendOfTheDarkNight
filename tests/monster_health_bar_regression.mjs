import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const check = (condition, message) => {
    if (!condition) throw new Error(message);
};

const mirrors = [
    "scripts/GameUI.lua",
    "assets/scripts/GameUI.lua",
    ".shotproj/scripts/GameUI.lua",
];

for (const file of mirrors) {
    const source = read(file);
    const start = source.indexOf("function GameUI._DrawEnemyHealthBars");
    const end = source.indexOf("function GameUI._DrawDivineBeastBar", start);
    check(start >= 0 && end > start, `${file} 缺少怪物血条绘制函数边界`);

    const healthBarBlock = source.slice(start, end);
    check(healthBarBlock.includes('local Combat = require("Combat")'),
        `${file} 的怪物血条没有读取 canonical Combat 模块`);
    check(!healthBarBlock.includes('require("scripts.Combat")'),
        `${file} 仍读取旧 Combat 镜像，敌人列表会与战斗系统分离`);
    check(healthBarBlock.includes("e.name")
        && healthBarBlock.includes("nvgText(ctx, sx, nameSy, nameText, nil)"),
        `${file} 缺少怪物名称绘制`);
    check(healthBarBlock.includes("e.hp")
        && healthBarBlock.includes("nvgRoundedRect(ctx, sx - barW / 2"),
        `${file} 缺少怪物血条绘制`);
}

console.log("monster_health_bar_regression: PASS");
