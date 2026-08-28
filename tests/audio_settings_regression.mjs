import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const source = fs.readFileSync(path.join(root, "scripts/GameUI.lua"), "utf8");
const soundManager = fs.readFileSync(path.join(root, "scripts/SoundManager.lua"), "utf8");
const main = fs.readFileSync(path.join(root, "scripts/main.lua"), "utf8");

const check = (condition, message) => {
    if (!condition) throw new Error(message);
};

const start = source.indexOf("function GameUI.ShowSystemPanel()");
const end = source.indexOf("function GameUI.HideSystemPanel()", start);
check(start >= 0 && end > start, "无法定位系统菜单代码块");

const systemPanel = source.slice(start, end);

check(systemPanel.includes("local function createAudioToggleRow"), "系统菜单缺少音频 Toggle 行构造器");
check((systemPanel.match(/UI\.Toggle \{/g) || []).length === 1,
    "音频开关构造器应使用一个可复用的原生 UI.Toggle");
check(systemPanel.includes('createAudioToggleRow("音效", SoundManager.IsSoundEnabled()'),
    "音效开关没有绑定当前音效状态");
check(systemPanel.includes('createAudioToggleRow("背景音乐", SoundManager.IsMusicEnabled()'),
    "背景音乐开关没有绑定当前音乐状态");
check(/onChange = function\(_, value\)[\s\S]*?onChange\(value\)/.test(systemPanel),
    "Toggle 没有把左右状态直接传给音频设置");
check(!systemPanel.includes('SoundManager.Play("click")'),
    "音频开关回调仍同步创建点击音效，可能阻塞视觉反馈");

check(
    systemPanel.includes('createVolumeRow("音效音量"')
        && systemPanel.includes('createVolumeRow("背景音乐音量"'),
    "系统菜单缺少音效或背景音乐音量滑块"
);

const soundSetter = soundManager.slice(
    soundManager.indexOf("function SoundManager.SetSoundEnabled"),
    soundManager.indexOf("function SoundManager.IsMusicEnabled"),
);
const musicSetter = soundManager.slice(
    soundManager.indexOf("function SoundManager.SetMusicEnabled"),
    soundManager.indexOf("function SoundManager.GetMusicGain"),
);
check(!soundSetter.includes("SaveSettings()") && !musicSetter.includes("SaveSettings()"),
    "音频开关仍在点击热路径同步写文件");
check(soundManager.includes("local function MarkSettingsDirty()")
    && soundManager.includes("SETTINGS_SAVE_DELAY")
    && /function SoundManager\.Update\(dt\)[\s\S]*?settingsSaveTimer[\s\S]*?SoundManager\.SaveSettings\(\)/.test(soundManager),
"音频设置没有通过 Update 做延迟持久化");
check(soundManager.includes("pendingMusicEnabled")
    && /function SoundManager\.Update\(dt\)[\s\S]*?SoundManager\.PlayMusic\(currentBgmKey\)/.test(soundManager),
"背景音乐恢复仍可能阻塞 Toggle 回调");
check(soundManager.includes("function SoundManager.FlushSettings()")
    && (main.match(/SoundManager\.FlushSettings\(\)/g) || []).length >= 3,
"退出、进入后台和终止时没有兜底保存音频设置");

console.log("verified audio toggles respond before deferred audio work and settings persistence");
