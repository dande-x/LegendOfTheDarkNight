import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const mainSource = read("scripts/main.lua");
const combatSource = read("scripts/Combat.lua");
const inventorySource = read("scripts/Inventory.lua");
const uiSource = read("scripts/GameUI.lua");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function functionBlock(source, name) {
    const marker = `function ${name}(`;
    const start = source.indexOf(marker);
    check(start >= 0, `缺少函数 ${name}`);
    const nextFunction = source.indexOf("\nfunction ", start + marker.length);
    const nextLocalFunction = source.indexOf("\nlocal function ", start + marker.length);
    const candidates = [nextFunction, nextLocalFunction].filter((index) => index >= 0);
    const end = candidates.length > 0 ? Math.min(...candidates) : source.length;
    return source.slice(start, end);
}

check(/deathGoldLossRatio\s*=\s*0\.10/.test(inventorySource),
    "死亡金币损失比例不是当前金币的 10%");
const penaltyBlock = functionBlock(inventorySource, "Inventory.ApplyDeathPenalty");
check(penaltyBlock.includes("math.floor(current * ratio)"),
    "死亡金币损失没有向下取整");
check(penaltyBlock.includes("playerData.gold = current - lost"),
    "死亡惩罚没有实际扣除金币");

for (const api of [
    "GameUI.ShowDeathMark",
    "GameUI.ShowDeathLossDialog",
    "GameUI.HideDeathPresentation",
]) {
    check(uiSource.includes(`function ${api}`), `缺少死亡 UI 接口 ${api}`);
}
const deathDialog = functionBlock(uiSource, "GameUI.ShowDeathLossDialog");
check(deathDialog.includes('text = "复活"') && deathDialog.includes("onClick = ConfirmRevive"),
    "死亡结算没有通过明确的复活按钮继续");
check(deathDialog.includes("closeOnOverlay = false")
    && deathDialog.includes("closeOnEscape = false")
    && deathDialog.includes("showCloseButton = false"),
    "死亡结算仍可被遮罩、ESC 或关闭按钮跳过");
check(deathDialog.includes("经验、装备、任务进度均保留"),
    "死亡结算没有说明保留内容");
check(uiSource.includes("if uiState.deathMarkRoot or uiState.deathLossModal then\n        nvgEndFrame"),
    "死亡 UI 出现时底层 NanoVG HUD 仍可能覆盖演出");

const resetBlock = functionBlock(combatSource, "Combat.ResetLivingEnemiesForPlayerRevive");
check(resetBlock.includes('enemy.state ~= "dead"')
    && resetBlock.includes('enemy.state ~= "dying"'),
    "复活重置可能重新拉起已死亡或正在死亡的敌人");
check(resetBlock.includes("enemy.hp = enemy.maxHP"),
    "复活后没有为存活敌人补满血量");
for (const residue of [
    "enemy.dotTimer = 0",
    "enemy.defReduction = 0",
    "enemy.trapTimer = nil",
    "enemy.hitStunTimer = 0",
    "body:SetLinearVelocity(Vector3.ZERO)",
]) {
    check(resetBlock.includes(residue), `敌人复活重置遗漏残留状态: ${residue}`);
}

const reviveBlock = functionBlock(mainSource, "RevivePlayer");
check(reviveBlock.includes("Combat.CancelPlayerHostileEffects()"),
    "复活前没有再次清理敌对攻击效果");
check(reviveBlock.includes("Combat.ResetLivingEnemiesForPlayerRevive()"),
    "复活流程没有调用存活敌人满血重置");
check(reviveBlock.includes("player_.hp = player_.maxHP")
    && reviveBlock.includes("player_.mp = player_.maxMP"),
    "角色复活没有恢复满血满蓝");
check(reviveBlock.includes("currentMap and currentMap.spawnPos"),
    "角色复活没有使用当前地图出生点");
check(reviveBlock.indexOf("isDead = false") < reviveBlock.indexOf("SaveCurrentGame()"),
    "复活存档发生在死亡状态清除之前");

const deathState = mainSource.slice(
    mainSource.indexOf("-- 死亡状态"),
    mainSource.indexOf("-- 施法状态机更新", mainSource.indexOf("-- 死亡状态")),
);
check(deathState.includes('deathPhase == "mark"')
    && deathState.includes("GameUI.ShowDeathLossDialog")
    && deathState.includes("GameUI.ShowDeathMark(DEATH_MARK_DURATION)"),
    "死亡演出没有按“死字 → 结算弹窗”推进");
check(deathState.indexOf("-- 死亡状态") < deathState.indexOf("GameUI.IsGamePaused()"),
    "死亡状态机位于通用暂停判断之后，可能被冻结");
check(!mainSource.includes("deathTimer = 3.0"),
    "仍保留旧的 3 秒自动复活逻辑");
check(!mainSource.includes('GameUI.AddFloatingText("阵亡!"'),
    "仍使用旧的世界空间阵亡飘字");

const saveBlock = functionBlock(mainSource, "SaveCurrentGame");
check(saveBlock.includes("if isDead or (tonumber(player_.hp) or 0) <= 0 then"),
    "存档入口没有阻止写入死亡快照");
check(mainSource.includes("currentSlotIndex and not isDead")
    && mainSource.includes("复活完成后立即存档"),
    "自动存档没有显式避开死亡结算阶段");

console.log("death_flow_regression: PASS");
console.log("verified death mark, loss settlement, explicit revive, and living-enemy full heal");
