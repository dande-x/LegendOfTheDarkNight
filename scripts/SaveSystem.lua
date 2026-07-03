-- ============================================================================
-- SaveSystem.lua — 暗夜传奇 本地存档系统
-- 支持最多 2 个角色槽位的存储、读取、删除
-- ============================================================================

local SaveSystem = {}

-- ============================================================================
-- 常量
-- ============================================================================
local MAX_SLOTS = 2
local SAVE_DIR = "saves"
local SAVE_FILE = "saves/characters.json"

SaveSystem.MAX_SLOTS = MAX_SLOTS

-- ============================================================================
-- 内部状态
-- ============================================================================
---@type table[] 存档槽位数组，最多 MAX_SLOTS 项
local slots = {}  -- { [1] = saveData | nil, [2] = saveData | nil }

-- ============================================================================
-- 序列化辅助：将装备 table 转为可 JSON 化的格式
-- ============================================================================
local function SerializeItem(item)
    if not item then return nil end
    return {
        id       = item.id,
        name     = item.name,
        slot     = item.slot,
        itemType = item.itemType,
        rarity   = item.rarity,
        atk      = item.atk,
        def      = item.def,
        hp       = item.hp,
        classReq = item.classReq,
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
    for i, item in ipairs(bag) do
        result[i] = SerializeItem(item)
    end
    return result
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
    local now = os.time()
    return {
        -- 元信息
        version    = 1,
        createdAt  = now,
        updatedAt  = now,

        -- 角色基础
        classId    = player.classId,
        className  = player.className,
        level      = player.level,
        exp        = player.exp,
        expToNext  = player.expToNext,

        -- 战斗属性（存储当前值，加载时会重算）
        hp         = player.hp,
        mp         = player.mp,

        -- 装备与背包
        equipped   = SerializeEquipped(inventoryData.equipped),
        bag        = SerializeBag(inventoryData.bag),
        gold       = inventoryData.gold or 0,
        potions    = inventoryData.potions and {
            hp = inventoryData.potions.hp or 0,
            mp = inventoryData.potions.mp or 0,
        } or { hp = 5, mp = 3 },

        -- 统计
        killCount  = killCount or 0,
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

    local jsonStr = cjson.encode(data)
    local file = File(SAVE_FILE, FILE_WRITE)
    if not file:IsOpen() then
        print("[SaveSystem] ERROR: Cannot open file for writing: " .. SAVE_FILE)
        return false
    end
    file:WriteString(jsonStr)
    file:Close()
    print("[SaveSystem] Saved to disk (" .. #jsonStr .. " bytes)")
    return true
end

--- 从磁盘读取所有槽位
---@return boolean success
function SaveSystem.ReadFromDisk()
    slots = {}

    if not fileSystem:FileExists(SAVE_FILE) then
        print("[SaveSystem] No save file found, starting fresh")
        return true
    end

    local file = File(SAVE_FILE, FILE_READ)
    if not file:IsOpen() then
        print("[SaveSystem] ERROR: Cannot open file for reading: " .. SAVE_FILE)
        return false
    end
    local jsonStr = file:ReadString()
    file:Close()

    if not jsonStr or #jsonStr == 0 then
        print("[SaveSystem] Empty save file, starting fresh")
        return true
    end

    local ok, data = pcall(cjson.decode, jsonStr)
    if not ok or type(data) ~= "table" then
        print("[SaveSystem] ERROR: Corrupted save file, starting fresh")
        return true
    end

    -- 解析槽位
    if data.slots then
        for i = 1, MAX_SLOTS do
            local s = data.slots[i]
            if s and type(s) == "table" and s.classId then
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
    if slotIndex < 1 or slotIndex > MAX_SLOTS then return nil end
    return slots[slotIndex]
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
    if slotIndex < 1 or slotIndex > MAX_SLOTS then
        print("[SaveSystem] ERROR: Invalid slot index " .. tostring(slotIndex))
        return false
    end

    -- 更新时间戳
    saveData.updatedAt = os.time()

    -- 保留原始创建时间
    local existing = slots[slotIndex]
    if existing and existing.createdAt then
        saveData.createdAt = existing.createdAt
    end

    slots[slotIndex] = saveData
    return SaveSystem.WriteToDisk()
end

--- 删除指定槽位
---@param slotIndex number 1 或 2
---@return boolean success
function SaveSystem.DeleteSlot(slotIndex)
    if slotIndex < 1 or slotIndex > MAX_SLOTS then
        print("[SaveSystem] ERROR: Invalid slot index " .. tostring(slotIndex))
        return false
    end
    if not slots[slotIndex] then
        print("[SaveSystem] Slot " .. slotIndex .. " already empty")
        return true
    end

    local name = slots[slotIndex].className or "???"
    local level = slots[slotIndex].level or 1
    slots[slotIndex] = nil
    print("[SaveSystem] Deleted slot " .. slotIndex .. " (" .. name .. " Lv." .. level .. ")")
    return SaveSystem.WriteToDisk()
end

-- ============================================================================
-- 恢复存档到游戏运行时
-- ============================================================================

--- 将存档数据恢复到 Inventory.playerData
---@param saveData table 存档数据
---@param inventoryData table Inventory.playerData 引用
function SaveSystem.RestoreInventory(saveData, inventoryData)
    -- 恢复金币
    inventoryData.gold = saveData.gold or 0

    -- 恢复药水
    inventoryData.potions = saveData.potions or { hp = 5, mp = 3 }

    -- 恢复装备栏
    inventoryData.equipped = {}
    if saveData.equipped then
        for slotKey, item in pairs(saveData.equipped) do
            if item and type(item) == "table" and item.id then
                inventoryData.equipped[slotKey] = item
            end
        end
    end

    -- 恢复背包
    inventoryData.bag = {}
    if saveData.bag then
        for i, item in ipairs(saveData.bag) do
            if item and type(item) == "table" and item.id then
                table.insert(inventoryData.bag, item)
            end
        end
    end

    -- 重新计算装备加成
    local Inventory = require("scripts.Inventory")
    Inventory.RecalcBonus()

    print("[SaveSystem] Inventory restored: gold=" .. inventoryData.gold
        .. " bag=" .. #inventoryData.bag .. " items")
end

--- 将存档数据恢复到 player 运行时对象
---@param saveData table 存档数据
---@param player table CharacterClass.CreatePlayer 创建的对象
function SaveSystem.RestorePlayer(saveData, player)
    player.level    = saveData.level or 1
    player.exp      = saveData.exp or 0
    player.expToNext = saveData.expToNext or (50 + player.level * 60)

    -- 恢复 HP/MP（限制在上限内）
    local CharacterClass = require("scripts.CharacterClass")
    local classDef = CharacterClass.Classes[player.classId]
    local g = classDef.growth

    local Inventory = require("scripts.Inventory")
    local bonusHP = Inventory.playerData.bonusHP or 0

    player.maxHP = classDef.baseHP + g.hp * (player.level - 1) + bonusHP
    player.maxMP = classDef.baseMP + g.mp * (player.level - 1)
    player.atk   = classDef.baseATK + g.atk * (player.level - 1) + (Inventory.playerData.bonusAtk or 0)
    player.def   = classDef.baseDEF + g.def * (player.level - 1) + (Inventory.playerData.bonusDef or 0)

    player.hp = math.min(saveData.hp or player.maxHP, player.maxHP)
    player.mp = math.min(saveData.mp or player.maxMP, player.maxMP)

    -- 恢复已解锁技能到装备栏：按解锁等级从低到高放入低位槽
    CharacterClass.RebuildEquippedSkills(player, false)

    print("[SaveSystem] Player restored: " .. player.className .. " Lv." .. player.level)
end

-- ============================================================================
-- 辅助：格式化时间戳为可读字符串
-- ============================================================================
function SaveSystem.FormatTime(timestamp)
    if not timestamp or timestamp <= 0 then return "未知" end
    return os.date("%m/%d %H:%M", timestamp)
end

-- ============================================================================
-- 初始化：启动时自动加载存档
-- ============================================================================
function SaveSystem.Init()
    SaveSystem.ReadFromDisk()
    print("[SaveSystem] Init complete, " .. SaveSystem.GetUsedSlotCount() .. "/" .. MAX_SLOTS .. " slots used")
end

return SaveSystem
