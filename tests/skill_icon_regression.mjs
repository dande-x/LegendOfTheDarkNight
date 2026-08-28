import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const check = (condition, message) => {
    if (!condition) throw new Error(message);
};

const iconPath = "assets/image/icon_w_earthsplit_20260827_round.png";
const iconMetaPath = `${iconPath}.meta`;
check(fs.existsSync(path.join(root, iconPath)), "地裂斩 icon 资源缺失");
check(fs.existsSync(path.join(root, iconMetaPath)), "地裂斩 icon meta 资源缺失");

const gameUIFiles = [
    "scripts/GameUI.lua",
    "assets/scripts/GameUI.lua",
    ".shotproj/scripts/GameUI.lua",
];
for (const file of gameUIFiles) {
    const source = read(file);
    check(
        source.includes('w_earthsplit = "image/icon_w_earthsplit_20260827_round.png"'),
        `${file} 缺少地裂斩 icon 映射`
    );
}

const entryFiles = [
    "scripts/main.lua",
    "assets/scripts/main.lua",
    ".shotproj/scripts/main.lua",
];
for (const file of entryFiles) {
    const source = read(file);
    check(source.includes('local GameUI = require("GameUI")'), `${file} 未加载 canonical GameUI`);
    check(!source.includes('local GameUI = require("scripts.GameUI")'), `${file} 仍加载旧 GameUI 镜像`);
}

console.log("verified canonical GameUI loading and earthsplit icon mapping across all runtime mirrors");
