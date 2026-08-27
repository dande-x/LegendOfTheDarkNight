import fs from "node:fs";
import path from "node:path";

const root = process.cwd();
const read = (file) => fs.readFileSync(path.join(root, file), "utf8");

const inventorySource = read("scripts/Inventory.lua");
const monsterSource = read("scripts/MonsterData.lua");
const weaponSource = read("scripts/WeaponData.lua");
const mainSource = read("scripts/main.lua");
const equipmentPanelSource = read("scripts/EquipmentPanel.lua");
const forgeSource = read("scripts/Enhance.lua");
const saveSource = read("scripts/SaveSystem.lua");

function check(condition, message) {
    if (!condition) throw new Error(message);
}

// 只为回归测试提取 Lua 表；不执行项目脚本，避免把引擎 API 引入 Node。
function matchingBrace(source, openIndex) {
    let depth = 0;
    let quote = null;
    let escaped = false;
    for (let index = openIndex; index < source.length; index += 1) {
        const char = source[index];
        if (quote) {
            if (escaped) {
                escaped = false;
            } else if (char === "\\") {
                escaped = true;
            } else if (char === quote) {
                quote = null;
            }
            continue;
        }
        if (char === "\"" || char === "'") {
            quote = char;
            continue;
        }
        if (char === "-" && source[index + 1] === "-") {
            const lineEnd = source.indexOf("\n", index + 2);
            index = lineEnd >= 0 ? lineEnd : source.length;
            continue;
        }
        if (char === "{") depth += 1;
        if (char === "}" && --depth === 0) return index;
    }
    return -1;
}

function parseNamedTables(source, marker) {
    const markerIndex = source.indexOf(marker);
    check(markerIndex >= 0, `缺少掉落表根节点: ${marker}`);
    const rootOpen = source.indexOf("{", markerIndex);
    const rootEnd = matchingBrace(source, rootOpen);
    check(rootOpen >= 0 && rootEnd >= 0, `${marker} 表结构无法解析`);

    const body = source.slice(rootOpen + 1, rootEnd);
    const tables = new Map();
    const tablePattern = /\["([^"]+)"\]\s*=\s*\{/g;
    let match;
    while ((match = tablePattern.exec(body))) {
        const relativeOpen = match.index + match[0].lastIndexOf("{");
        const tableOpen = rootOpen + 1 + relativeOpen;
        const tableEnd = matchingBrace(source, tableOpen);
        check(tableEnd >= 0, `掉落表 ${match[1]} 结构无法解析`);
        const tableBlock = source.slice(tableOpen, tableEnd + 1);

        const alias = tableBlock.match(/\bitems\s*=\s*([A-Za-z_][A-Za-z0-9_]*)/);
        if (alias) {
            tables.set(match[1], { alias: alias[1], ids: [] });
            continue;
        }

        const itemsMarker = tableBlock.match(/\bitems\s*=\s*\{/);
        check(itemsMarker, `掉落表 ${match[1]} 缺少 items`);
        const itemsOpen = tableOpen + itemsMarker.index + itemsMarker[0].lastIndexOf("{");
        const itemsEnd = matchingBrace(source, itemsOpen);
        check(itemsEnd >= 0, `掉落表 ${match[1]} 的 items 结构无法解析`);
        const itemsBlock = source.slice(itemsOpen, itemsEnd + 1);
        const ids = [...itemsBlock.matchAll(/\bid\s*=\s*"([^"]+)"/g)].map((item) => item[1]);
        tables.set(match[1], { ids });
    }
    return tables;
}

function parseAliases(source) {
    const aliases = new Map();
    const aliasPattern = /\blocal\s+([A-Z][A-Z0-9_]*_ITEMS)\s*=\s*\{/g;
    let match;
    while ((match = aliasPattern.exec(source))) {
        const open = match.index + match[0].lastIndexOf("{");
        const end = matchingBrace(source, open);
        check(end >= 0, `共享掉落池 ${match[1]} 结构无法解析`);
        const block = source.slice(open, end + 1);
        aliases.set(match[1], [...block.matchAll(/\bid\s*=\s*"([^"]+)"/g)].map((item) => item[1]));
    }
    return aliases;
}

function parseWeaponTemplates(source) {
    const weapons = new Map();
    for (const line of source.split("\n")) {
        if (!line.includes('itemType = "weapon"')) continue;
        const id = line.match(/id\s*=\s*"([^"]+)"/)?.[1];
        const classReqMatch = line.match(/classReq\s*=\s*(nil|"([^"]+)")/);
        check(id && classReqMatch, `武器模板无法解析: ${line.trim()}`);
        weapons.set(id, classReqMatch[1] === "nil" ? null : classReqMatch[2]);
    }
    return weapons;
}

const weaponClasses = parseWeaponTemplates(weaponSource);
check(weaponClasses.size === 18, `三职业武器模板应为 18 件，实际 ${weaponClasses.size} 件`);

for (const [id, classReq] of weaponClasses) {
    if (id.startsWith("sword_")) {
        check(id === "sword_dragon" ? classReq === null : classReq === "warrior",
            `${id} 的职业限制不符合刀剑规则`);
    } else if (id.startsWith("staff_")) {
        check(classReq === "mage", `${id} 的职业限制不符合法杖规则`);
    } else if (id.startsWith("bell_")) {
        check(classReq === "taoist", `${id} 的职业限制不符合道术武器规则`);
    } else {
        throw new Error(`出现未归类的武器模板: ${id}`);
    }
}

const universalWeapons = [...weaponClasses].filter(([, classReq]) => classReq === null).map(([id]) => id);
check(universalWeapons.length === 1 && universalWeapons[0] === "sword_dragon",
    "除明确的屠龙通用例外外，不应有无职业限制的武器");

const allTemplateIds = new Set([
    ...[...inventorySource.matchAll(/\bid\s*=\s*"([^"]+)"/g)].map((item) => item[1]),
    ...weaponClasses.keys(),
]);
const rawDropIds = [
    ...inventorySource.matchAll(/\{\s*id\s*=\s*"([^"]+)"\s*,\s*weight\s*=\s*[0-9.]+/g),
    ...monsterSource.matchAll(/\{\s*id\s*=\s*"([^"]+)"\s*,\s*weight\s*=\s*[0-9.]+/g),
].map((item) => item[1]);
check(rawDropIds.length >= 250, `掉落配置数量异常，当前仅解析到 ${rawDropIds.length} 条`);
for (const id of rawDropIds) {
    check(allTemplateIds.has(id), `掉落表引用未知物品: ${id}`);
}

const aliases = parseAliases(monsterSource);
const dropTables = new Map([
    ...parseNamedTables(inventorySource, "local DROP_TABLES"),
    ...parseNamedTables(monsterSource, "MonsterData.DROP_TABLES"),
]);
check(dropTables.size >= 30, `掉落表数量异常，当前仅解析到 ${dropTables.size} 张`);

const classes = ["warrior", "mage", "taoist"];
const resolvedItems = (table) => table.alias ? (aliases.get(table.alias) ?? []) : table.ids;
for (const [monster, table] of dropTables) {
    const ids = resolvedItems(table);
    check(ids.length > 0, `${monster} 没有可解析的掉落项`);
    for (const classId of classes) {
        const eligible = ids.filter((id) => {
            const classReq = weaponClasses.get(id);
            return classReq === undefined || classReq === null || classReq === classId;
        });
        check(eligible.length > 0, `${monster} 对 ${classId} 过滤后掉落池为空`);

        for (const id of eligible) {
            const classReq = weaponClasses.get(id);
            check(classReq === undefined || classReq === null || classReq === classId,
                `${monster} 对 ${classId} 仍可能掉落异职业武器 ${id}`);
        }
    }
}

// 代码级断言：过滤必须发生在抽样前，且所有实际入口都传入职业。
const rollStart = inventorySource.indexOf("function Inventory.RollDrop(enemyName, playerClassId)");
const rollEnd = inventorySource.indexOf("function Inventory.ProcessDrop", rollStart);
const rollBlock = inventorySource.slice(rollStart, rollEnd);
check(rollStart >= 0 && rollEnd > rollStart, "RollDrop 职业参数或函数边界缺失");
check(rollBlock.includes("if not IsKnownClassId(playerClassId)"),
    "RollDrop 缺少缺失/非法职业的 fail-closed 保护");
const filterAt = rollBlock.indexOf("IsItemCompatibleWithClass(tmpl, playerClassId)");
const randomAt = rollBlock.indexOf("math.random() <");
check(filterAt >= 0 && randomAt > filterAt, "掉落抽样早于职业过滤，可能先抽中再丢弃异职业装备");
check(inventorySource.includes("function Inventory.ProcessDrop(enemyName, playerClassId)"),
    "ProcessDrop 未透传职业参数");
check(mainSource.includes("Inventory.RollDrop(enemyName, player_.classId)"),
    "敌人死亡回调未把当前职业传入 RollDrop");
check(mainSource.includes("Inventory.GetCompatibleItemTemplates(player.classId)"),
    "商店货架未复用统一职业过滤模板");

// 商店、装备、锻造和读档也必须使用同一套职业边界。
check(inventorySource.includes("function Inventory.BuyItem(itemId, playerClassId)"),
    "购买接口未接收职业参数");
check(inventorySource.includes("购买装备需要有效职业")
    && inventorySource.includes("该装备不适用于当前职业"),
    "购买接口缺少职业校验");
check(mainSource.includes("Inventory.BuyItem(itemCopy.id, player_.classId)"),
    "商店购买调用未传入当前职业");
check(inventorySource.includes("function Inventory.EquipItem(item, playerClassId, targetSlot)")
    && inventorySource.includes("装备需要有效职业"),
    "装备入口缺少职业上下文校验");
check(equipmentPanelSource.includes("local classMatches = not item.classReq or item.classReq == player.classId"),
    "装备详情面板未显示职业不匹配状态");
check(forgeSource.includes("不同职业武器不能混合锻造"),
    "锻造未阻止不同职业武器混合");
check(saveSource.includes("CreateItemFromSave(savedItem, slotKey, playerClassId)"),
    "装备栏读档未校验当前职业");

console.log("class_drop_regression: PASS");
console.log(`checked ${rawDropIds.length} drop entries across ${dropTables.size} monster tables`);
