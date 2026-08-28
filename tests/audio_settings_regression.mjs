import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const source = fs.readFileSync(path.join(root, "scripts/GameUI.lua"), "utf8");

const check = (condition, message) => {
    if (!condition) throw new Error(message);
};

const start = source.indexOf("function GameUI.ShowSystemPanel()");
const end = source.indexOf("function GameUI.HideSystemPanel()", start);
check(start >= 0 && end > start, "无法定位系统菜单代码块");

const systemPanel = source.slice(start, end);

check(
    !systemPanel.includes("local btn = UI.Button {")
        || !/local btn = UI\.Button \{[\s\S]*?onClick = function\(\)[\s\S]*?btn:Set(?:Text|Style)/.test(systemPanel),
    "系统菜单仍在局部变量初始化表达式中回引 btn，点击时会解析为 nil 全局变量"
);

const soundToggle = /SoundManager\.SetSoundEnabled\(newEnabled\)[\s\S]*?button:SetText\([\s\S]*?button:SetStyle \{/.test(systemPanel);
const musicToggle = /SoundManager\.SetMusicEnabled\(newEnabled\)[\s\S]*?button:SetText\([\s\S]*?button:SetStyle \{/.test(systemPanel);
check(soundToggle, "音效开关没有使用 Button onClick 回调传入的按钮实例");
check(musicToggle, "背景音乐开关没有使用 Button onClick 回调传入的按钮实例");

const buttonCallbacks = systemPanel.match(/onClick = function\(button\)/g) || [];
check(buttonCallbacks.length >= 2, "音效与背景音乐开关必须各自接收按钮实例");

check(
    systemPanel.includes('createVolumeRow("音效音量"')
        && systemPanel.includes('createVolumeRow("背景音乐音量"'),
    "系统菜单缺少音效或背景音乐音量滑块"
);

console.log("verified audio toggle callbacks use the Button instance and volume controls remain present");
