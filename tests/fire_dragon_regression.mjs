import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");
const combatSource = read("scripts/Combat.lua");
const skeletonSource = read("scripts/MonsterSkeleton.lua");
const balanceSource = read("scripts/Balance.lua");
const mainSource = read("scripts/main.lua");
const questSource = read("scripts/Quest.lua");
const mapSource = read("scripts/MapZone.lua");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

function definitionBlock(source, marker) {
    const start = source.indexOf(marker);
    check(start >= 0, `缺少定义: ${marker}`);
    const end = source.indexOf("\n    },", start);
    return source.slice(start, end >= 0 ? end + 7 : start + 1200);
}

const fireDragon = definitionBlock(combatSource, 'name = "火龙王"');
check(fireDragon.includes('monsterType = "fire_dragon"'), "火龙王仍未使用独立模型类型");
check(!fireDragon.includes('monsterType = "serpent"'), "火龙王又退回蛇形类型");
check(fireDragon.includes('attackMode = "fire_breath"'), "火龙王缺少火焰吐息模式");

const value = (field) => Number(fireDragon.match(new RegExp(`${field} = ([0-9.]+)`))?.[1]);
check(value("speed") >= 2.7, "火龙王移动速度不足，追击表现会像静止摆件");
check(value("chaseRange") === 16, "火龙王警戒范围未按约 1/3 缩短");
check(value("attackRange") >= 6 && value("attackRange") <= 9, "火焰吐息范围不合理");
check(value("attackCD") >= 2 && value("attackCD") <= 3, "火焰吐息间隔不合理");

check(skeletonSource.includes('fire_dragon = {\n        modelPath = "Meshes/Qilin.mdl"'),
    "火龙王未接入非蛇形精细模型");
check(/fire_dragon = \{[\s\S]*?bones = BONES_DEER/.test(skeletonSource),
    "火龙王骨架仍未脱离蛇形结构");
check(skeletonSource.includes("ANIMS.fire_dragon = ANIMS.deer"),
    "火龙王缺少移动、攻击、受击和死亡动画集");
check(skeletonSource.includes("CreateFireDragonAdornment"), "火龙王缺少翅翼与熔火外观增强");
check(skeletonSource.includes("UpdateFireDragonAdornment"), "火龙王外观增强没有动态更新");
check(balanceSource.includes("fire_dragon   ="), "火龙王更换类型后未绑定稳定数值轮廓");

check(combatSource.includes("attackMode = def.attackMode"), "敌人运行时未保存专属攻击模式");
check(combatSource.includes("function Combat.SpawnFireBreathVisual"), "缺少火焰吐息视觉");
check(combatSource.includes('if e.attackMode == "fire_breath" then'), "AI 未触发火焰吐息");
check(combatSource.includes("ApplyEnemyDamageToPlayer(e, player, playerPos)"),
    "火焰吐息未接入玩家实际受伤结算");
check(combatSource.includes("DivineBeast.TakeDamage"), "火龙王无法攻击神兽");

check(!mainSource.includes('CreateMapModel("DragonSlayerPlatform"'), "火龙出生点仍有碰撞平台");
check(!mainSource.includes('CreateMapModel("DragonSlayerPedestal"'), "火龙出生点仍有碰撞台座");
check(mainSource.includes("RandomOutsideDragonLair"), "随机熔岩石仍可能堵住火龙出生点");
check(mainSource.includes('CreateMapModel("DragonLair_Ring"'), "熔火龙巢缺少无碰撞场地标识");
check(mainSource.includes('"DragonLair_"'), "切图时不会清理熔火龙巢装饰");

const questBlock = definitionBlock(questSource, 'id = "q_015"');
check(questBlock.includes('name = "熔火龙巢"'), "火龙任务名称仍描述旧骨龙/台座");
check(questBlock.includes('encounter = { name = "熔火龙巢", x = 0, z = -32 }'),
    "火龙任务遭遇点与新场地未统一");
check(mapSource.includes('{ name = "熔火龙巢", x = 0, z = -32 }'),
    "地图地标与火龙任务目标不一致");

console.log("fire_dragon_regression: PASS");
