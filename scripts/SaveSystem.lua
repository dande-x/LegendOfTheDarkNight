-- ============================================================================
-- SaveSystem.lua — 暗夜传奇 本地存档系统
-- 支持最多 2 个角色槽位的存储、读取、删除
-- ============================================================================

local SaveSystem = {}

local Quest = require("scripts.Quest")
local Balance = require("scripts.Balance")

-- ============================================================================
-- 常量
-- ============================================================================
local MAX_SLOTS = 2
local SAVE_DIR = "saves"
local SAVE_FILE = "saves/characters.json"
local SAVE_BACKUP_FILE = "saves/characters.backup.json"
-- 仅限制损坏存档/异常浮点值；正常玩法等级不设上限。
local LEVEL_SANITY_LIMIT = Balance.LEVEL_SANITY_LIMIT
local MAX_RESOURCE = 1000000000

SaveSystem.MAX_SLOTS = MAX_SLOTS

-- ============================================================================
-- 内部状态
-- ============================================================================
---@type table[] 存档槽位数组，最多 MAX_SLOTS 项
local slots = {}  -- { [1] = saveData | nil, [2] = saveData | nil }

-- JSON 是外部可修改的数据源，恢复前统一把数值归一化，避免 NaN、无穷大、
-- 小数和超大整数穿透到经验、经济或数组索引逻辑。
local function SafeInteger(value, minValue, maxValue, fallback)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return fallback
    end
    number = math.max(minValue, math.min(maxValue, number))
    return math.floor(number)
end

local function NormalizeSlotIndex(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return nil
    end
    if number % 1 ~= 0 or number < 1 or number > MAX_SLOTS then return nil end
    number = math.floor(number)
    return number
end

local function GetCharacterClass(classId)
    local CharacterClass = require("scripts.CharacterClass")
    if type(classId) ~= "string" then return nil end
    return CharacterClass.Classes[classId]
end

--- 返回可用于创建角色的合法职业 ID；非法存档返回 nil。
---@param classId any
---@return string|nil
function SaveSystem.NormalizeClassId(classId)
    return GetCharacterClass(classId) and classId or nil
end

--- 判断一个槽位是否至少具备可创建角色的核心字段。
---@param saveData any
---@return boolean
function SaveSystem.IsLoadable(saveData)
    return type(saveData) == "table"
        and SaveSystem.NormalizeClassId(saveData.classId) ~= nil
end

local function NormalizeGender(gender)
    return gender == "female" and "female" or "male"
end

local function NormalizeModelStyle(modelStyle, gender)
    if modelStyle == "new" or modelStyle == "old" then
        return modelStyle
    end
    -- 当前创建流程中女性使用新模型、男性使用旧模型；坏存档按该兼容规则回退。
    return gender == "female" and "new" or "old"
end

-- ============================================================================
-- 序列化辅助：将装备 table 转为可 JSON 化的格式
-- ============================================================================
local function SerializeItem(item)
    if type(item) ~= "table" or type(item.id) ~= "string" then return nil end
    return {
        id       = item.id,
        -- 名称/属性仅用于兼容旧文件和调试；恢复时以本地模板为准。
        name     = type(item.name) == "string" and item.name or nil,
        slot     = type(item.slot) == "string" and item.slot or nil,
        itemType = type(item.itemType) == "string" and item.itemType or nil,
        rarity   = type(item.rarity) == "string" and item.rarity or nil,
        atk      = SafeInteger(item.atk, 0, MAX_RESOURCE, 0),
        def      = SafeInteger(item.def, 0, MAX_RESOURCE, 0),
        hp       = SafeInteger(item.hp, 0, MAX_RESOURCE, 0),
        classReq = type(item.classReq) == "string" and item.classReq or nil,
        enhance  = SafeInteger(item.enhance, 0, 12, 0),
    }
end

local function SerializeEquipped(equipped)
    if not equipped then return {} end
    local result = {}
    for slotKey, item in pairs(equipped) do
        result[slotKey] = SerializeItem(item)
    end
    return result
end

local function SerializeBag(bag)
    if not bag then return {} end
    local result = {}
    -- 不要把无效实例写成数组中的 null：Lua 的 ipairs/部分 JSON
    -- 解码器会在第一个洞处停止，导致后续合法物品读档时全部丢失。
    -- 只把能被序列化的实例连续写入结果数组。
    for _, item in ipairs(bag) do
        local serialized = SerializeItem(item)
        if serialized then
            table.insert(result, serialized)
        end
    end
    return result
end

local function GetSortedArrayIndices(value)
    local indices = {}
    if type(value) ~= "table" then return indices end

    for key in pairs(value) do
        -- JSON 数组索引应为有限正整数；忽略字典键和异常数值键。
        if type(key) == "number"
            and key == key
            and key ~= math.huge
            and key ~= -math.huge
            and key >= 1
            -- 先限制范围，再调用 math.floor；避免极大的浮点键在
            -- Lua 5.4 中触发“number has no integer representation”。
            and key <= 1000000
            and key == math.floor(key) then
            table.insert(indices, key)
        end
    end
    table.sort(indices)
    return indices
end

-- ============================================================================
-- 创建存档数据快照（从当前游戏状态提取）
-- ============================================================================

--- 从玩家运行时数据创建存档快照
---@param player table 玩家运行时数据（CharacterClass.CreatePlayer 创建的）
---@param inventoryData table Inventory.playerData
---@param killCount number 击杀数
---@return table saveData
function SaveSystem.CreateSnapshot(player, inventoryData, killCount)
    if type(player) ~= "table" or type(inventoryData) ~= "table"
        or not SaveSystem.IsLoadable({ classId = player.classId }) then
        print("[SaveSystem] ERROR: Cannot snapshot invalid player/inventory")
        return nil
    end
    local now = os.time()
    return {
        -- 元信息
        version    = 2,
        createdAt  = now,
        updatedAt  = now,

        -- 角色基础
        classId    = player.classId,
        className  = player.className,
        modelStyle = player.modelStyle or "old",
        gender     = player.gender or "male",
        level      = SafeInteger(player.level, 1, LEVEL_SANITY_LIMIT, 1),
        exp        = SafeInteger(player.exp, 0, MAX_RESOURCE, 0),
        expToNext  = SafeInteger(player.expToNext, 1, MAX_RESOURCE, 1),

        -- 战斗属性（存储当前值，加载时会重算）
        hp         = SafeInteger(player.hp, 0, MAX_RESOURCE, 0),
        mp         = SafeInteger(player.mp, 0, MAX_RESOURCE, 0),

        -- 装备与背包
        equipped   = SerializeEquipped(inventoryData.equipped),
        bag        = SerializeBag(inventoryData.bag),
        gold       = SafeInteger(inventoryData.gold, 0, MAX_RESOURCE, 0),
        potions    = inventoryData.potions and {
            hp = SafeInteger(inventoryData.potions.hp, 0, MAX_RESOURCE, 0),
            mp = SafeInteger(inventoryData.potions.mp, 0, MAX_RESOURCE, 0),
        } or { hp = 5, mp = 3 },

        -- 统计
        killCount  = SafeInteger(killCount, 0, MAX_RESOURCE, 0),

        -- 主线任务进度
        quest      = Quest.GetState(),

        -- 所在地图
        mapId      = (require("scripts.Combat").currentMapId) or "map_bq",

        -- 神兽是当前角色会话内的临时成长，不写入角色存档。
        -- 旧版本存档即使仍含 divineBeast 字段，读档也会忽略；下一次
        -- 保存会用当前快照覆盖槽位，从而自然移除旧字段。
    }
end

-- ============================================================================
-- 文件 I/O
-- ============================================================================

--- 确保存档目录存在
local function EnsureSaveDir()
    if not fileSystem:DirExists(SAVE_DIR) then
        fileSystem:CreateDir(SAVE_DIR)
    end
end

--- 读取并验证一个存档文档。JSON、slots 结构及非空角色槽都有效时才返回数据。
---@param path string
---@return table|nil, string|nil
local function ReadSaveDocument(path)
    if not fileSystem:FileExists(path) then return nil, "missing" end

    local file = File(path, FILE_READ)
    if not file:IsOpen() then return nil, "open_failed" end
    local jsonStr = file:ReadString()
    file:Close()

    if not jsonStr or #jsonStr == 0 then return nil, "empty" end
    local ok, data = pcall(cjson.decode, jsonStr)
    if not ok or type(data) ~= "table" then return nil, "invalid_json" end
    if type(data.slots) ~= "table" then return nil, "invalid_slots" end

    -- 备份只能由“可实际载入”的主存档刷新。只检查顶层 slots 会把
    -- { slots = { { classId = "已删除职业" } } } 这类语义损坏文件当成
    -- 有效文档，随后覆盖掉最后一个好备份。空槽仍以 cjson.null 表示。
    for i = 1, MAX_SLOTS do
        local slot = data.slots[i]
        if slot ~= nil and slot ~= cjson.null and not SaveSystem.IsLoadable(slot) then
            return nil, "invalid_slot_" .. tostring(i)
        end
    end
    return data, nil
end

--- 将所有槽位写入磁盘
---@return boolean success
function SaveSystem.WriteToDisk()
    EnsureSaveDir()

    local data = {
        version = 1,
        slots = {},
    }
    for i = 1, MAX_SLOTS do
        data.slots[i] = slots[i] or cjson.null
    end

    local encoded, jsonStr = pcall(cjson.encode, data)
    if not encoded or type(jsonStr) ~= "string" then
        print("[SaveSystem] ERROR: Failed to encode save data")
        return false
    end

    -- 只用“可正常解码”的主存档刷新备份。若主文件已经损坏，绝不能把
    -- 损坏内容覆盖掉最后一个可恢复副本。
    if fileSystem:FileExists(SAVE_FILE) then
        local currentDocument = ReadSaveDocument(SAVE_FILE)
        if currentDocument then
            if not fileSystem:Copy(SAVE_FILE, SAVE_BACKUP_FILE) then
                print("[SaveSystem] ERROR: Cannot refresh save backup")
                return false
            end
        else
            print("[SaveSystem] WARNING: Primary save is invalid; preserving existing backup")
        end
    end

    local file = File(SAVE_FILE, FILE_WRITE)
    if not file:IsOpen() then
        print("[SaveSystem] ERROR: Cannot open file for writing: " .. SAVE_FILE)
        return false
    end
    file:WriteString(jsonStr)
    file:Close()

    -- 写后立即回读验证；若截断或编码落盘异常，恢复上一个有效备份。
    local verified, verifyReason = ReadSaveDocument(SAVE_FILE)
    if not verified then
        print("[SaveSystem] ERROR: Save verification failed: " .. tostring(verifyReason))
        if fileSystem:FileExists(SAVE_BACKUP_FILE)
            and fileSystem:Copy(SAVE_BACKUP_FILE, SAVE_FILE) then
            print("[SaveSystem] Restored previous save from backup")
        end
        return false
    end

    -- 首次成功保存时还没有“上一版主存档”可供预写备份；此处补建一个
    -- 已验证副本。已有有效备份继续保留为上一版本，不把滚动备份变成镜像。
    local backupDocument = ReadSaveDocument(SAVE_BACKUP_FILE)
    if not backupDocument and not fileSystem:Copy(SAVE_FILE, SAVE_BACKUP_FILE) then
        -- 主存档已经写入并通过回读校验，备份创建失败只降级容灾能力，
        -- 不能返回 false 让调用方回滚内存而磁盘仍保留新版本。
        print("[SaveSystem] WARNING: Save succeeded but initial backup could not be created")
    end
    print("[SaveSystem] Saved to disk (" .. #jsonStr .. " bytes)")
    return true
end

--- 从磁盘读取所有槽位
---@return boolean success
function SaveSystem.ReadFromDisk()
    slots = {}

    local primaryExists = fileSystem:FileExists(SAVE_FILE)
    local backupExists = fileSystem:FileExists(SAVE_BACKUP_FILE)
    if not primaryExists and not backupExists then
        print("[SaveSystem] No save file found, starting fresh")
        return true
    end

    local data, primaryError = ReadSaveDocument(SAVE_FILE)
    if not data then
        local backupData, backupError = ReadSaveDocument(SAVE_BACKUP_FILE)
        if not backupData then
            print("[SaveSystem] ERROR: Primary and backup saves are unreadable: primary="
                .. tostring(primaryError) .. " backup=" .. tostring(backupError))
            return false
        end

        data = backupData
        print("[SaveSystem] WARNING: Recovered save data from backup (primary="
            .. tostring(primaryError) .. ")")
        if not fileSystem:Copy(SAVE_BACKUP_FILE, SAVE_FILE) then
            print("[SaveSystem] WARNING: Backup loaded but primary file could not be restored")
        end
    end

    -- 解析槽位
    if type(data.slots) == "table" then
        for i = 1, MAX_SLOTS do
            local s = data.slots[i]
            if SaveSystem.IsLoadable(s) then
                slots[i] = s
            else
                slots[i] = nil
            end
        end
    end

    print("[SaveSystem] Loaded from disk, " .. SaveSystem.GetUsedSlotCount() .. " character(s)")
    return true
end

-- ============================================================================
-- 槽位操作
-- ============================================================================

--- 获取指定槽位的存档数据（nil 表示空槽）
---@param slotIndex number 1 或 2
---@return table|nil
function SaveSystem.GetSlot(slotIndex)
    local index = NormalizeSlotIndex(slotIndex)
    if not index then return nil end
    return slots[index]
end

--- 获取所有槽位（包含 nil）
---@return table[]
function SaveSystem.GetAllSlots()
    local result = {}
    for i = 1, MAX_SLOTS do
        result[i] = slots[i]
    end
    return result
end

--- 获取已使用的槽位数
---@return number
function SaveSystem.GetUsedSlotCount()
    local count = 0
    for i = 1, MAX_SLOTS do
        if slots[i] then count = count + 1 end
    end
    return count
end

--- 查找第一个空槽位索引，没有则返回 nil
---@return number|nil
function SaveSystem.FindEmptySlot()
    for i = 1, MAX_SLOTS do
        if not slots[i] then return i end
    end
    return nil
end

--- 保存到指定槽位（覆盖现有数据）
---@param slotIndex number 1 或 2
---@param saveData table CreateSnapshot 返回的数据
---@return boolean success
function SaveSystem.SaveToSlot(slotIndex, saveData)
    local index = NormalizeSlotIndex(slotIndex)
    if not index then
        print("[SaveSystem] ERROR: Invalid slot index " .. tostring(slotIndex))
        return false
    end
    if not SaveSystem.IsLoadable(saveData) then
        print("[SaveSystem] ERROR: Refusing to save invalid character data")
        return false
    end

    -- 更新时间戳
    saveData.updatedAt = os.time()

    -- 保留原始创建时间
    local existing = slots[index]
    if existing and existing.createdAt then
        saveData.createdAt = existing.createdAt
    end

    local previous = slots[index]
    slots[index] = saveData
    if not SaveSystem.WriteToDisk() then
        slots[index] = previous
        return false
    end
    return true
end

--- 删除指定槽位
---@param slotIndex number 1 或 2
---@return boolean success
function SaveSystem.DeleteSlot(slotIndex)
    local index = NormalizeSlotIndex(slotIndex)
    if not index then
        print("[SaveSystem] ERROR: Invalid slot index " .. tostring(slotIndex))
        return false
    end
    if not slots[index] then
        print("[SaveSystem] Slot " .. index .. " already empty")
        return true
    end

    local classId = SaveSystem.NormalizeClassId(slots[index].classId)
    local classDef = classId and GetCharacterClass(classId) or nil
    local name = classDef and classDef.name or tostring(slots[index].className or "???")
    local level = SafeInteger(slots[index].level, 1, LEVEL_SANITY_LIMIT, 1)
    local previous = slots[index]
    slots[index] = nil
    print("[SaveSystem] Deleted slot " .. index .. " (" .. name .. " Lv." .. level .. ")")
    if not SaveSystem.WriteToDisk() then
        slots[index] = previous
        print("[SaveSystem] ERROR: Delete was rolled back because disk write failed")
        return false
    end
    return true
end

-- ============================================================================
-- 恢复存档到游戏运行时
-- ============================================================================

--- 将存档数据恢复到 Inventory.playerData
---@param saveData table 存档数据
---@param inventoryData table Inventory.playerData 引用
function SaveSystem.RestoreInventory(saveData, inventoryData)
    if type(saveData) ~= "table" or type(inventoryData) ~= "table" then
        print("[SaveSystem] ERROR: Invalid inventory restore arguments")
        return false
    end

    local Inventory = require("scripts.Inventory")
    local playerClassId = SaveSystem.NormalizeClassId(saveData.classId)
    if not playerClassId then
        print("[SaveSystem] ERROR: Cannot restore inventory for unknown class")
        return false
    end

    -- 恢复金币。旧版强化石已经退出系统，按原商店价一次性折算为金币；
    -- LoadFromSave 会在完整恢复成功后立即保存新版快照，防止重复折算。
    inventoryData.gold = SafeInteger(saveData.gold, 0, MAX_RESOURCE, 0)
    local legacyEnhanceStones = SafeInteger(
        saveData.enhanceStones, 0, MAX_RESOURCE, 0)
    local legacyRefund = math.min(
        MAX_RESOURCE - inventoryData.gold,
        legacyEnhanceStones * Inventory.LEGACY_ENHANCE_STONE_REFUND)
    inventoryData.gold = inventoryData.gold + legacyRefund
    saveData.enhanceStones = nil


    -- 恢复药水
    local savedPotions = type(saveData.potions) == "table" and saveData.potions or {}
    inventoryData.potions = {
        hp = SafeInteger(savedPotions.hp, 0, Inventory.POTION_CONFIG.hp.max, 5),
        mp = SafeInteger(savedPotions.mp, 0, Inventory.POTION_CONFIG.mp.max, 3),
    }

    -- 恢复装备栏
    inventoryData.equipped = {}
    local restoredEquipped = 0
    if type(saveData.equipped) == "table" then
        for slotKey, savedItem in pairs(saveData.equipped) do
            local item = Inventory.CreateItemFromSave(savedItem, slotKey, playerClassId)
            if item then
                inventoryData.equipped[slotKey] = item
                restoredEquipped = restoredEquipped + 1
            else
                print("[SaveSystem] Dropped invalid equipped item in slot " .. tostring(slotKey))
            end
        end
    end

    -- 恢复背包
    inventoryData.bag = {}
    local droppedBagItems = 0
    if type(saveData.bag) == "table" then
        -- 不使用 ipairs：兼容旧版/手工修改后带 null 洞的 JSON 数组，
        -- 让洞后的合法物品仍能恢复；最终仍严格限制在背包容量内。
        local bagIndices = GetSortedArrayIndices(saveData.bag)
        for _, index in ipairs(bagIndices) do
            local savedItem = saveData.bag[index]
            if #inventoryData.bag >= Inventory.MAX_BAG_SLOTS then
                droppedBagItems = droppedBagItems + 1
            else
                -- 背包允许保存其它职业的装备，玩家可以之后出售或分解；
                -- 只有装备栏恢复才强制校验职业要求。
                local item = Inventory.CreateItemFromSave(savedItem, nil, nil)
                if item then
                    table.insert(inventoryData.bag, item)
                else
                    droppedBagItems = droppedBagItems + 1
                end
            end
        end
    end

    -- 重新计算装备加成
    Inventory.RecalcBonus()

    print("[SaveSystem] Inventory restored: gold=" .. inventoryData.gold
        .. " legacyEnhanceRefund=" .. legacyRefund
        .. " equipped=" .. restoredEquipped
        .. " bag=" .. #inventoryData.bag .. " items"
        .. (droppedBagItems > 0 and (" dropped=" .. droppedBagItems) or ""))
    return true, legacyRefund
end

--- 将存档数据恢复到 player 运行时对象
---@param saveData table 存档数据
---@param player table CharacterClass.CreatePlayer 创建的对象
function SaveSystem.RestorePlayer(saveData, player)
    if type(saveData) ~= "table" or type(player) ~= "table" then
        print("[SaveSystem] ERROR: Invalid player restore arguments")
        return false
    end

    -- 恢复 HP/MP（限制在上限内）
    local CharacterClass = require("scripts.CharacterClass")
    local savedClassId = SaveSystem.NormalizeClassId(saveData.classId)
    if not savedClassId or savedClassId ~= player.classId then
        print("[SaveSystem] ERROR: Save/player class mismatch")
        return false
    end
    local classDef = CharacterClass.Classes[player.classId]
    if not classDef then
        print("[SaveSystem] ERROR: Cannot restore unknown class " .. tostring(player.classId))
        return false
    end

    local level = SafeInteger(saveData.level, 1, LEVEL_SANITY_LIMIT, 1)
    player.level = level
    player.expToNext = CharacterClass.GetExpToNext(level)
    player.exp = SafeInteger(saveData.exp, 0, math.max(0, player.expToNext - 1), 0)

    local Inventory = require("scripts.Inventory")
    -- 统一走 CharacterClass 的派生属性入口，避免读档时漏掉职业被动
    -- （例如武士生命上限、装备攻击/防御加成）。
    CharacterClass.ApplyDerivedStats(player, Inventory.playerData, false)

    player.hp = SafeInteger(saveData.hp, 0, math.floor(player.maxHP or 0), math.floor(player.maxHP or 0))
    player.mp = SafeInteger(saveData.mp, 0, math.floor(player.maxMP or 0), math.floor(player.maxMP or 0))

    -- 恢复已解锁技能到装备栏：按解锁等级从低到高放入低位槽
    CharacterClass.RebuildEquippedSkills(player, false)

    player.className = classDef.name
    player.gender = NormalizeGender(saveData.gender)
    player.modelStyle = NormalizeModelStyle(saveData.modelStyle, player.gender)
    print("[SaveSystem] Player restored: " .. tostring(player.className) .. " Lv." .. player.level)
    return true
end

-- ============================================================================
-- 辅助：格式化时间戳为可读字符串
-- ============================================================================
function SaveSystem.FormatTime(timestamp)
    local value = tonumber(timestamp)
    if not value or value ~= value or value == math.huge or value <= 0 then return "未知" end
    return os.date("%m/%d %H:%M", math.floor(value))
end

-- ============================================================================
-- 初始化：启动时自动加载存档
-- ============================================================================
function SaveSystem.Init()
    SaveSystem.ReadFromDisk()
    print("[SaveSystem] Init complete, " .. SaveSystem.GetUsedSlotCount() .. "/" .. MAX_SLOTS .. " slots used")
end

return SaveSystem
