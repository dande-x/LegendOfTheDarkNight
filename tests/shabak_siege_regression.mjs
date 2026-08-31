import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const siege = read("scripts/ShabakSiege.lua");
const runtime = read("scripts/ShabakRuntime.lua");
const saveSystem = read("scripts/SaveSystem.lua");
const characterClass = read("scripts/CharacterClass.lua");
const gameUi = read("scripts/GameUI.lua");
const main = read("scripts/main.lua");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

// 地图与会话边界
check(siege.includes('ShabakSiege.MAP_ID = "map_sb"'), "缺少 map_sb 内部地图 ID");
check(siege.includes('ShabakSiege.MAP_NAME = "沙巴克城"'), "缺少沙巴克城可见名称");
check(siege.includes("minLevel = 50"), "沙巴克入口等级必须为 Lv.50");
check(siege.includes("deploymentDuration = 10")
    && siege.includes("timeLimit = 900")
    && siege.includes("throneDefenseDuration = 60"),
    "攻城倒计时/总时限/王座坚守时长不完整");
check(siege.includes("maxLives = 2"), "攻城必须保留两条玩家命数规则");
check(siege.includes("naturalSpawns = false")
    && siege.includes("normalNpcServices = false"),
    "沙巴克实例不应恢复自然刷怪或普通 NPC 服务");

// 队友与守军必须是实际三职业角色 descriptor，不能退化成怪物换皮。
check(siege.includes('faction = "ally"')
    && siege.includes('faction = "defender"')
    && siege.includes("actualCharacter = true")
    && siege.includes("isMonster = false"),
    "队友/守军缺少实际角色身份标记");
check(siege.includes("BuildCompanions")
    && siege.includes("BuildDefenderRoster")
    && siege.includes("GetPendingSpawns"),
    "队友或分阶段守军生成接口缺失");
check(siege.includes('canCaptureObjectives = false')
    && siege.includes('canBreakGate = false'),
    "队友不能被限制为独自完成攻城目标");
check(siege.includes("enabledDuringThrone == false")
    && siege.includes("reviveCompanions = false"),
    "王座防守阶段不应免费复起队友");

// 最终 60 秒必须是玩家本人站在王座区的坚守读条，不是进入阶段后自动获胜。
check(siege.includes("function Session:AdvanceThroneHold")
    && siege.includes("playerPresent == true and uncontested == true")
    && siege.includes("throneHoldProgress")
    && siege.includes("throne_hold_paused"),
    "王座阶段缺少玩家站点坚守/受争夺暂停规则");

// 守军等级地板、品阶浮动和临时装备约束。
check(siege.includes("math.max(ShabakSiege.CONFIG.minLevel, level + offset)")
    && siege.includes('tier == "elite"')
    && siege.includes('tier == "commander"'),
    "守军等级没有保持 Lv.50 地板或精英/统领浮动");
check(siege.includes('rarity == "RARE" and rarePool or commonPool')
    && siege.includes('enhance = 0')
    && siege.includes('temporary = true'),
    "守军装备没有锁定普通/稀有未强化临时装备");
check(siege.includes('canSummon = classId == "taoist" and tier == "commander"'),
    "道士召唤规则没有限制在统领层级");

// 攻城目标、补给、死亡和荣誉结算必须拥有可接入的纯逻辑 API。
for (const name of [
    "DamageGate", "BeginObjective", "AdvanceObjective", "CompleteObjective",
    "ClaimSupply", "UseFieldMedkit", "OnPlayerDeath", "CompleteRespawn",
    "Victory", "Defeat", "GetHonorPatch",
]) {
    check(siege.includes(`function Session:${name}`), `缺少会话接口: ${name}`);
}
check(siege.includes('shabakLord = true')
    && siege.includes('shabakWinsDelta = 1')
    && siege.includes('titlePermanent = true'),
    "胜利没有生成当前角色槽位的城主荣誉补丁");

// 荣誉必须跨普通保存、读档和云端双槽位合并保留；地图 HUD 也要能容纳
// 沙巴克路线的六个地标。
check(characterClass.includes("shabakLord = false")
    && characterClass.includes("shabakWinCount = 0")
    && characterClass.includes("shabakBestTime = 0"),
    "角色运行时缺少沙巴克荣誉默认字段");
check(saveSystem.includes("shabakLord = player.shabakLord == true")
    && saveSystem.includes("shabakWinCount")
    && saveSystem.includes("shabakBestTime")
    && saveSystem.includes("MergePersistentHonors")
    && saveSystem.includes("player.shabakLord = saveData.shabakLord == true"),
    "存档系统没有持久化/合并沙巴克荣誉");
check(gameUi.includes("local MINI_MAP_LANDMARK_COUNT = 6")
    && gameUi.includes("for i = 1, MINI_MAP_LANDMARK_COUNT do"),
    "地图 UI 地标容量不足以显示沙巴克六点路线");

// 运行时必须创建独立的实际角色模型和 AnimationController，绝不能调用
// PlayerAnim 的全局单例 CreateSkeleton；守军/队友都要注册到 Combat 外部角色接口。
check(runtime.includes("PlayerAnim.GetPrefabPath")
    && runtime.includes("InstantiateXML")
    && runtime.includes("AnimationController")
    && runtime.includes("RegisterExternalEnemy")
    && runtime.includes("DealDamageToPlayer")
    && runtime.includes("DealDamageToExternal")
    && !runtime.includes("PlayerAnim.CreateSkeleton"),
    "沙巴克运行时没有形成独立三职业角色与 Combat 外部实体接线");
check(runtime.includes("UseFieldMedkit")
    && runtime.includes("ClaimSupply")
    && runtime.includes("ResetForRespawn")
    && runtime.includes("HandleSiegeSkillCast"),
    "运行时缺少补给、复活或城门技能目标接线");

check(gameUi.includes("function GameUI.ShowSiegeHUD")
    && gameUi.includes("function GameUI.UpdateSiegeHUD")
    && gameUi.includes("function GameUI.HideSiegeHUD")
    && gameUi.includes("onUseSiegeMedkit"),
    "攻城 HUD 或临时急救药按钮缺失");
check(main.includes("shabakSession_:OnPlayerDeath()")
    && main.includes("ResetForRespawn")
    && main.includes("ShowSiegeHUD"),
    "主循环没有接入攻城命数、集结点复活或 HUD");

// 会话进入 victory/defeat 后 IsShabakActive() 会变为 false；主循环仍须
// 在 map_sb 上执行荣誉合并、清场和返场，不能遗留待结算状态。
check(main.includes("shabakPendingResult_\n        and (shabakSession_ ~= nil or IsShabakMap(Combat.currentMapId))"),
    "攻城完成后主循环仍错误依赖 active 状态，结果无法收口");
check(runtime.includes("SetCollisionLayerAndMask(CollisionLayerCharacter, CollisionMaskCharacter)")
    && runtime.includes("SetCollisionLayerAndMask(CollisionLayerKinematic, CollisionMaskKinematic)")
    && runtime.includes("ACTOR_COLLISION_DIAMETER = 0.50")
    && runtime.includes("ACTOR_COLLISION_HEIGHT = 1.40")
    && runtime.includes("shape:SetCapsule(ACTOR_COLLISION_DIAMETER, ACTOR_COLLISION_HEIGHT"),
    "沙巴克实际角色缺少统一胶囊碰撞体与 KCC 配置");
check(runtime.includes("actor.node:SetDeepEnabled(false)")
    && runtime.includes("actor.node:SetDeepEnabled(true)"),
    "队友倒下/复起没有切换整棵角色节点可见性");
check(gameUi.includes("local isAlly = e.faction == \"ally\"")
    && gameUi.includes("【支援】")
    && gameUi.includes("nvgRGBA(64, 196, 108, 235)"),
    "友军血条没有使用绿色支援标识");
check(/map_sb[\s\S]*?teleportCost = 0/.test(read("scripts/MapZone.lua")),
    "沙巴克重复挑战入口应为免费传送");

console.log("shabak siege regression checks passed");
