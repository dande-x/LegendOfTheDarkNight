---@diagnostic disable: undefined-global, param-type-mismatch, assign-type-mismatch
-- ============================================================================
-- SaveSystem.lua — 暗夜传奇 本地存档系统
-- 支持最多 2 个角色槽位的存储、读取、删除
--
-- 本模块同时把完整的双槽位存档镜像到 TapTap Maker 的 clientCloud。
-- 本地 JSON 仍是离线/预览兜底；云端不可用时不会阻塞游戏。
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
local CLOUD_KEY = "night_legend_save_v1"
local CLOUD_SCHEMA_VERSION = 1
local MAX_TIMESTAMP = 9999999999
-- 仅限制损坏存档/异常浮点值；正常玩法等级不设上限。
local LEVEL_SANITY_LIMIT = Balance.LEVEL_SANITY_LIMIT
local MAX_RESOURCE = 1000000000

SaveSystem.MAX_SLOTS = MAX_SLOTS
SaveSystem.CLOUD_KEY = CLOUD_KEY

-- ============================================================================
-- 内部状态
-- ============================================================================
---@type table[] 存档槽位数组，最多 MAX_SLOTS 项
local slots = {}  -- { [1] = saveData | nil, [2] = saveData | nil }
-- 每个槽位独立维护最后一次修改时间，删除槽位时也保留 tombstone 时间戳，
-- 这样两个设备分别修改不同槽位时可以合并，删除操作也能跨设备生效。
local slotUpdatedAt = { [1] = 0, [2] = 0 }
local localUpdatedAt = 0

-- 云端读写状态。所有云端操作都是异步的，失败只降级到本地存档。
local cloudEnabled = false
local cloudReady = false
local cloudLoadInFlight = false
local cloudLoadWaiters = {}
local cloudSaveInFlight = false
local cloudSavePending = nil
local cloudSaveWaiters = {}
local lastCloudPayload = nil
local cloudStatus = "not_started"
local cloudLastError = nil

local function SafeCall(callback, ...)
    if type(callback) == "function" then
        pcall(callback, ...)
    end
end

local function GetMethod(object, name)
    if object == nil then return nil end
    local ok, method = pcall(function() return object[name] end)
    if not ok or type(method) ~= "function" then return nil end
    return method
end

local function GetClientCloud()
    -- clientCloud 只在 Standalone/Client 平台运行时注入；本地预览可能没有
    -- 该对象，或旧运行时只提供不完整的 clientScore 兼容对象。
    local ok, cloud = pcall(function() return clientCloud end)
    if not ok or cloud == nil then return nil end
    if not GetMethod(cloud, "BatchGet") or not GetMethod(cloud, "BatchSet") then
        return nil
    end
    return cloud
end

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

local function SafeTimestamp(value)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return 0
    end
    number = math.max(0, math.min(MAX_TIMESTAMP, number))
    return math.floor(number)
end

local function NextTimestamp()
    local now = SafeTimestamp(os.time())
    if now <= localUpdatedAt then
        now = math.min(MAX_TIMESTAMP, localUpdatedAt + 1)
    end
    localUpdatedAt = now
    return now
end

-- 只复制 JSON 可表达的基础值，避免把运行时对象/函数引用交给云端，
-- 同时避免云端回调返回的 table 被后续读档逻辑原地修改。
local function CloneSerializable(value, seen, depth)
    local valueType = type(value)
    if value == nil or valueType == "string" or valueType == "number"
        or valueType == "boolean" then
        return value
    end
    if valueType ~= "table" then return nil end
    depth = depth or 0
    if depth > 16 then return nil end
    seen = seen or {}
    if seen[value] then return nil end
    seen[value] = true

    local copy = {}
    for key, child in pairs(value) do
        local keyType = type(key)
        if keyType == "string" or keyType == "number" then
            local cloned = CloneSerializable(child, seen, depth + 1)
            if cloned ~= nil then
                copy[key] = cloned
            end
        end
    end
    seen[value] = nil
    return copy
end

local function IsCloudEmptyValue(value)
    return value == nil or value == false or value == cjson.null
end

local function ReadSlotField(container, index)
    if type(container) ~= "table" then return nil end
    local named = container["slot" .. tostring(index)]
    if named ~= nil then return named end
    return container[index]
end

local function ReadSlotTimestamp(container, index)
    return SafeTimestamp(ReadSlotField(container, index))
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
        if slot ~= nil and slot ~= false and slot ~= cjson.null
            and not SaveSystem.IsLoadable(slot) then
            return nil, "invalid_slot_" .. tostring(i)
        end
    end
    return data, nil
end

local function GetDocumentUpdatedAt(data)
    if type(data) ~= "table" then return 0 end
    local timestamp = SafeTimestamp(data.updatedAt)
    local metadata = data.slotUpdatedAt or data.slotTimestamps
    for i = 1, MAX_SLOTS do
        local slot = data.slots and data.slots[i]
        if SaveSystem.IsLoadable(slot) then
            timestamp = math.max(timestamp, SafeTimestamp(slot.updatedAt))
        end
        timestamp = math.max(timestamp, ReadSlotTimestamp(metadata, i))
    end
    return timestamp
end

--- 将所有槽位写入磁盘
---@param timestampOverride number|nil 用于把云端合并结果按原时间戳落盘
---@return boolean success
function SaveSystem.WriteToDisk(timestampOverride)
    EnsureSaveDir()

    local previousUpdatedAt = localUpdatedAt
    local writeTimestamp = SafeTimestamp(timestampOverride)
    if writeTimestamp <= 0 then
        writeTimestamp = NextTimestamp()
    else
        localUpdatedAt = math.max(localUpdatedAt, writeTimestamp)
    end

    local data = {
        version = 1,
        updatedAt = writeTimestamp,
        slots = {},
        slotUpdatedAt = {},
    }
    for i = 1, MAX_SLOTS do
        data.slots[i] = slots[i] or cjson.null
        data.slotUpdatedAt["slot" .. tostring(i)] = SafeTimestamp(slotUpdatedAt[i])
    end

    local encoded, jsonStr = pcall(cjson.encode, data)
    if not encoded or type(jsonStr) ~= "string" then
        localUpdatedAt = previousUpdatedAt
        print("[SaveSystem] ERROR: Failed to encode save data")
        return false
    end

    -- 只用“可正常解码”的主存档刷新备份。若主文件已经损坏，绝不能把
    -- 损坏内容覆盖掉最后一个可恢复副本。
    if fileSystem:FileExists(SAVE_FILE) then
        local currentDocument = ReadSaveDocument(SAVE_FILE)
        if currentDocument then
            if not fileSystem:Copy(SAVE_FILE, SAVE_BACKUP_FILE) then
                localUpdatedAt = previousUpdatedAt
                print("[SaveSystem] ERROR: Cannot refresh save backup")
                return false
            end
        else
            print("[SaveSystem] WARNING: Primary save is invalid; preserving existing backup")
        end
    end

    local file = File(SAVE_FILE, FILE_WRITE)
    if not file:IsOpen() then
        localUpdatedAt = previousUpdatedAt
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
        localUpdatedAt = previousUpdatedAt
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
    slotUpdatedAt = { [1] = 0, [2] = 0 }
    localUpdatedAt = 0

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
        local documentTimestamp = GetDocumentUpdatedAt(data)
        local metadata = data.slotUpdatedAt or data.slotTimestamps
        for i = 1, MAX_SLOTS do
            local s = data.slots[i]
            if SaveSystem.IsLoadable(s) then
                slots[i] = s
            else
                slots[i] = nil
            end
            local timestamp = ReadSlotTimestamp(metadata, i)
            if timestamp <= 0 and SaveSystem.IsLoadable(s) then
                timestamp = SafeTimestamp(s.updatedAt)
            end
            -- 旧版文件没有 slotUpdatedAt；非空槽位至少继承文档时间，
            -- 让首次云同步仍能正确判断本地版本新旧。
            if timestamp <= 0 and SaveSystem.IsLoadable(s) then
                timestamp = documentTimestamp
            end
            slotUpdatedAt[i] = timestamp
        end
        localUpdatedAt = documentTimestamp
    end

    print("[SaveSystem] Loaded from disk, " .. SaveSystem.GetUsedSlotCount() .. " character(s)")
    return true
end

-- ============================================================================
-- 平台云存档（clientCloud）
-- ============================================================================

local function NormalizeCloudPayload(raw)
    if IsCloudEmptyValue(raw) then return nil, "missing" end
    if type(raw) ~= "table" then return nil, "invalid_payload" end

    local version = tonumber(raw.version or raw.schemaVersion or CLOUD_SCHEMA_VERSION)
    if not version or version ~= CLOUD_SCHEMA_VERSION then
        return nil, "unsupported_version"
    end

    local rawSlots = raw.slots
    if type(rawSlots) ~= "table" then return nil, "invalid_slots" end

    local payload = {
        version = CLOUD_SCHEMA_VERSION,
        updatedAt = SafeTimestamp(raw.updatedAt),
        slots = {},
        slotUpdatedAt = {},
    }
    local rawMetadata = raw.slotUpdatedAt or raw.slotTimestamps
    for i = 1, MAX_SLOTS do
        local key = "slot" .. tostring(i)
        local rawSlot = ReadSlotField(rawSlots, i)
        local timestamp = ReadSlotTimestamp(rawMetadata, i)
        if IsCloudEmptyValue(rawSlot) then
            -- 云端用 false 表示空槽，避免 JSON 数组洞在不同运行时被截断。
            payload.slots[key] = false
            payload.slotUpdatedAt[key] = timestamp
        elseif SaveSystem.IsLoadable(rawSlot) then
            local copied = CloneSerializable(rawSlot)
            if type(copied) ~= "table" then
                return nil, "invalid_slot_" .. tostring(i)
            end
            if timestamp <= 0 then timestamp = SafeTimestamp(rawSlot.updatedAt) end
            if timestamp <= 0 then timestamp = payload.updatedAt end
            payload.slots[key] = copied
            payload.slotUpdatedAt[key] = timestamp
        else
            return nil, "invalid_slot_" .. tostring(i)
        end
        payload.updatedAt = math.max(payload.updatedAt, payload.slotUpdatedAt[key])
    end
    return payload, nil
end

local function BuildCloudPayload()
    local payload = {
        version = CLOUD_SCHEMA_VERSION,
        updatedAt = localUpdatedAt,
        slots = {},
        slotUpdatedAt = {},
    }
    for i = 1, MAX_SLOTS do
        local key = "slot" .. tostring(i)
        local slot = slots[i]
        payload.slots[key] = slot and CloneSerializable(slot) or false
        payload.slotUpdatedAt[key] = SafeTimestamp(slotUpdatedAt[i])
        payload.updatedAt = math.max(payload.updatedAt, payload.slotUpdatedAt[key])
    end
    return payload
end

local function GetPayloadSlot(payload, index)
    if type(payload) ~= "table" then return nil end
    return ReadSlotField(payload.slots, index)
end

local function GetPayloadSlotTimestamp(payload, index)
    if type(payload) ~= "table" then return 0 end
    return ReadSlotTimestamp(payload.slotUpdatedAt or payload.slotTimestamps, index)
end

local function PayloadDataEqual(left, right)
    if type(left) ~= "table" or type(right) ~= "table" then return false end
    for i = 1, MAX_SLOTS do
        if GetPayloadSlotTimestamp(left, i) ~= GetPayloadSlotTimestamp(right, i) then
            return false
        end
        local leftSlot = GetPayloadSlot(left, i)
        local rightSlot = GetPayloadSlot(right, i)
        local leftEmpty = IsCloudEmptyValue(leftSlot)
        local rightEmpty = IsCloudEmptyValue(rightSlot)
        if leftEmpty ~= rightEmpty then return false end
        if not leftEmpty then
            local leftOk, leftJson = pcall(cjson.encode, leftSlot)
            local rightOk, rightJson = pcall(cjson.encode, rightSlot)
            if not leftOk or not rightOk or leftJson ~= rightJson then
                return false
            end
        end
    end
    return true
end

local function MergeCloudPayload(localPayload, cloudPayload)
    local merged = {
        version = CLOUD_SCHEMA_VERSION,
        updatedAt = math.max(
            SafeTimestamp(localPayload and localPayload.updatedAt),
            SafeTimestamp(cloudPayload and cloudPayload.updatedAt)),
        slots = {},
        slotUpdatedAt = {},
    }

    for i = 1, MAX_SLOTS do
        local localSlot = GetPayloadSlot(localPayload, i)
        local cloudSlot = GetPayloadSlot(cloudPayload, i)
        local localTimestamp = GetPayloadSlotTimestamp(localPayload, i)
        local cloudTimestamp = GetPayloadSlotTimestamp(cloudPayload, i)

        -- 时间戳相同表示同一版本；若内容因旧客户端差异而不同，优先采用
        -- 云端的明确结果，保证跨设备启动时行为稳定。
        local useCloud = cloudTimestamp >= localTimestamp
        local selectedSlot = useCloud and cloudSlot or localSlot
        local selectedTimestamp = useCloud and cloudTimestamp or localTimestamp
        merged.slots["slot" .. tostring(i)] = IsCloudEmptyValue(selectedSlot)
            and false or CloneSerializable(selectedSlot)
        merged.slotUpdatedAt["slot" .. tostring(i)] = selectedTimestamp
        merged.updatedAt = math.max(merged.updatedAt, selectedTimestamp)
    end
    return merged
end

local function ApplyCloudPayload(payload)
    if type(payload) ~= "table" then return false, "invalid_payload" end

    local previousSlots = slots
    local previousSlotUpdatedAt = slotUpdatedAt
    local previousLocalUpdatedAt = localUpdatedAt
    local nextSlots = {}
    local nextSlotUpdatedAt = { [1] = 0, [2] = 0 }
    for i = 1, MAX_SLOTS do
        local candidate = GetPayloadSlot(payload, i)
        if not IsCloudEmptyValue(candidate) then
            if not SaveSystem.IsLoadable(candidate) then
                return false, "invalid_slot_" .. tostring(i)
            end
            nextSlots[i] = CloneSerializable(candidate)
        end
        nextSlotUpdatedAt[i] = GetPayloadSlotTimestamp(payload, i)
    end

    slots = nextSlots
    slotUpdatedAt = nextSlotUpdatedAt
    localUpdatedAt = SafeTimestamp(payload.updatedAt)
    for i = 1, MAX_SLOTS do
        localUpdatedAt = math.max(localUpdatedAt, slotUpdatedAt[i])
    end
    if not SaveSystem.WriteToDisk(localUpdatedAt) then
        slots = previousSlots
        slotUpdatedAt = previousSlotUpdatedAt
        localUpdatedAt = previousLocalUpdatedAt
        return false, "local_write_failed"
    end
    return true, nil
end

local function MakeCloudResult(ok, code, reason, source, changed, skipped)
    return {
        ok = ok == true,
        code = code,
        reason = reason,
        source = source,
        changed = changed == true,
        skipped = skipped == true,
    }
end

local function NotifyCloudWaiters(waiters, result)
    for _, callback in ipairs(waiters or {}) do
        SafeCall(callback, result)
    end
end

local StartCloudSave

local function FinishCloudSave(success, code, reason, payload, waiters)
    cloudSaveInFlight = false
    if success then
        lastCloudPayload = CloneSerializable(payload)
        cloudStatus = "synced"
        cloudLastError = nil
    else
        cloudStatus = "error"
        cloudLastError = reason or code or "cloud_save_failed"
    end
    NotifyCloudWaiters(waiters, MakeCloudResult(
        success, code, reason, success and "cloud" or "local_only", false, false))

    -- 高频自动保存只保留最新快照，避免把旧状态排队写回云端。
    if cloudSavePending then
        local nextPayload = cloudSavePending
        local nextWaiters = cloudSaveWaiters
        cloudSavePending = nil
        cloudSaveWaiters = {}
        StartCloudSave(nextPayload, nextWaiters)
    end
end

StartCloudSave = function(payload, waiters)
    local cloud = GetClientCloud()
    if not cloud then
        NotifyCloudWaiters(waiters, MakeCloudResult(
            false, "unavailable", "平台云存档暂不可用", "local_only", false, false))
        return false
    end

    cloudSaveInFlight = true
    local completed = false
    local function finishOnce(success, code, reason)
        if completed then return end
        completed = true
        FinishCloudSave(success, code, reason, payload, waiters)
    end

    local ok, err = pcall(function()
        local batch = cloud:BatchSet()
        if not batch then error("BatchSet returned nil") end
        batch = batch:Set(CLOUD_KEY, payload)
        if not batch then error("Set returned nil") end
        batch:Save("暗夜传奇云存档", {
            ok = function()
                finishOnce(true)
            end,
            error = function(code, reason)
                finishOnce(false, tostring(code), reason or "平台云存档保存失败")
            end,
            timeout = function()
                finishOnce(false, "timeout", "平台云存档保存超时")
            end,
        })
    end)
    if not ok then
        finishOnce(false, "exception", tostring(err))
        return false
    end
    return true
end

--- 判断当前运行时是否提供完整的客户端云存档接口。
function SaveSystem.IsCloudAvailable()
    return GetClientCloud() ~= nil
end

--- 返回云存档状态快照，供启动流程和调试日志使用。
function SaveSystem.GetCloudStatus()
    return {
        enabled = cloudEnabled,
        ready = cloudReady,
        available = SaveSystem.IsCloudAvailable(),
        status = cloudStatus,
        error = cloudLastError,
        key = CLOUD_KEY,
    }
end

--- 将当前本地槽位快照写入平台云存档。返回值只表示请求是否成功发出；
--- 最终结果通过 callback(result) 返回，云端失败不会回滚本地存档。
---@param callback fun(result: table)|nil
function SaveSystem.SaveToCloud(callback)
    cloudEnabled = true
    local payload = BuildCloudPayload()
    if cloudLoadInFlight or cloudSaveInFlight then
        cloudSavePending = payload
        if type(callback) == "function" then table.insert(cloudSaveWaiters, callback) end
        return true
    end

    if lastCloudPayload and PayloadDataEqual(lastCloudPayload, payload) then
        SafeCall(callback, MakeCloudResult(true, nil, nil, "cloud", false, true))
        return true
    end
    return StartCloudSave(payload, type(callback) == "function" and { callback } or {})
end

local function QueueCloudSaveAfterLocalWrite()
    if not cloudEnabled then return end
    SaveSystem.SaveToCloud(function(result)
        if not result.ok then
            print("[SaveSystem] WARNING: Local save kept; cloud sync failed: "
                .. tostring(result.reason or result.code))
        end
    end)
end

--- 启动时从平台云存档读取并与本地双槽位按槽位时间戳合并。
--- 云端不可用、超时或数据损坏时保留本地存档并继续离线运行。
---@param callback fun(result: table)|nil
function SaveSystem.LoadFromCloud(callback)
    cloudEnabled = true
    if cloudReady then
        SafeCall(callback, MakeCloudResult(true, nil, nil, "already_ready", false, true))
        return true
    end
    if type(callback) == "function" then table.insert(cloudLoadWaiters, callback) end
    if cloudLoadInFlight then return true end

    local cloud = GetClientCloud()
    if not cloud then
        cloudStatus = "unavailable"
        cloudLastError = "平台云存档暂不可用"
        cloudReady = true
        local waiters = cloudLoadWaiters
        cloudLoadWaiters = {}
        NotifyCloudWaiters(waiters, MakeCloudResult(
            false, "unavailable", cloudLastError, "local_only", false, false))
        return false
    end

    cloudLoadInFlight = true
    local completed = false
    local function complete(result)
        if completed then return end
        completed = true
        cloudLoadInFlight = false
        cloudReady = true
        if result.ok then
            cloudStatus = "synced"
            cloudLastError = nil
        elseif result.code ~= "invalid_cloud" then
            cloudStatus = "error"
            cloudLastError = result.reason or result.code
        else
            cloudStatus = "invalid"
            cloudLastError = result.reason
        end

        -- 若读云期间发生了本地保存，以当前内存状态重建最新 pending payload，
        -- 不把读云开始前的旧快照覆盖回云端。
        if cloudSavePending then cloudSavePending = BuildCloudPayload() end
        local waiters = cloudLoadWaiters
        cloudLoadWaiters = {}
        NotifyCloudWaiters(waiters, result)

        if cloudSavePending and not cloudSaveInFlight then
            local pendingPayload = cloudSavePending
            local pendingWaiters = cloudSaveWaiters
            cloudSavePending = nil
            cloudSaveWaiters = {}
            StartCloudSave(pendingPayload, pendingWaiters)
        end
    end

    local localPayload = BuildCloudPayload()
    local ok, err = pcall(function()
        local batch = cloud:BatchGet()
        if not batch then error("BatchGet returned nil") end
        batch = batch:Key(CLOUD_KEY)
        if not batch then error("Key returned nil") end
        batch:Fetch({
            ok = function(values)
                local raw = type(values) == "table" and values[CLOUD_KEY] or nil
                if IsCloudEmptyValue(raw) then
                    -- 首次运行或云端尚无此 key：把本地（可能为空）初始化到云端。
                    StartCloudSave(localPayload, {
                        function(saveResult)
                            if saveResult.ok then
                                complete(MakeCloudResult(true, nil, nil,
                                    "local_uploaded", true, false))
                            else
                                complete(MakeCloudResult(false, saveResult.code,
                                    saveResult.reason, "local_only", false, false))
                            end
                        end,
                    })
                    return
                end

                local cloudPayload, reason = NormalizeCloudPayload(raw)
                if not cloudPayload then
                    complete(MakeCloudResult(false, "invalid_cloud",
                        "云存档数据无效（" .. tostring(reason) .. "）",
                        "local_only", false, false))
                    return
                end

                local mergedPayload = MergeCloudPayload(localPayload, cloudPayload)
                local localChanged = not PayloadDataEqual(localPayload, mergedPayload)
                if localChanged then
                    local applied, applyReason = ApplyCloudPayload(mergedPayload)
                    if not applied then
                        complete(MakeCloudResult(false, "local_write_failed",
                            "云存档已读取，但本地落盘失败（" .. tostring(applyReason) .. "）",
                            "local_only", false, false))
                        return
                    end
                end

                local cloudChanged = not PayloadDataEqual(cloudPayload, mergedPayload)
                if cloudChanged then
                    StartCloudSave(mergedPayload, {
                        function(saveResult)
                            if saveResult.ok then
                                complete(MakeCloudResult(true, nil, nil,
                                    "merged", localChanged, false))
                            else
                                complete(MakeCloudResult(false, saveResult.code,
                                    saveResult.reason, "merged_local", localChanged, false))
                            end
                        end,
                    })
                else
                    complete(MakeCloudResult(true, nil, nil,
                        "cloud", localChanged, false))
                end
            end,
            error = function(code, reason)
                complete(MakeCloudResult(false, tostring(code),
                    reason or "平台云存档读取失败", "local_only", false, false))
            end,
            timeout = function()
                complete(MakeCloudResult(false, "timeout",
                    "平台云存档读取超时", "local_only", false, false))
            end,
        })
    end)
    if not ok then
        complete(MakeCloudResult(false, "exception", tostring(err), "local_only", false, false))
        return false
    end
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

    -- 更新时间戳；使用单调时间保证同一秒内连续保存也能在多设备合并时
    -- 保持明确的新旧顺序。
    local previousUpdatedAt = localUpdatedAt
    local saveTimestamp = NextTimestamp()
    saveData.updatedAt = saveTimestamp

    -- 保留原始创建时间
    local existing = slots[index]
    if existing and existing.createdAt then
        saveData.createdAt = existing.createdAt
    end

    local previous = slots[index]
    local previousSlotTimestamp = slotUpdatedAt[index]
    slots[index] = saveData
    slotUpdatedAt[index] = saveTimestamp
    if not SaveSystem.WriteToDisk(saveTimestamp) then
        slots[index] = previous
        slotUpdatedAt[index] = previousSlotTimestamp
        localUpdatedAt = previousUpdatedAt
        return false
    end
    QueueCloudSaveAfterLocalWrite()
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
    local previousSlotTimestamp = slotUpdatedAt[index]
    local previousUpdatedAt = localUpdatedAt
    slots[index] = nil
    slotUpdatedAt[index] = NextTimestamp()
    print("[SaveSystem] Deleted slot " .. index .. " (" .. name .. " Lv." .. level .. ")")
    if not SaveSystem.WriteToDisk(slotUpdatedAt[index]) then
        slots[index] = previous
        slotUpdatedAt[index] = previousSlotTimestamp
        localUpdatedAt = previousUpdatedAt
        print("[SaveSystem] ERROR: Delete was rolled back because disk write failed")
        return false
    end
    QueueCloudSaveAfterLocalWrite()
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
    -- 运行时重启时清空上一局的云同步状态；本地槽位会在下面重新读取。
    cloudEnabled = false
    cloudReady = false
    cloudLoadInFlight = false
    cloudLoadWaiters = {}
    cloudSaveInFlight = false
    cloudSavePending = nil
    cloudSaveWaiters = {}
    lastCloudPayload = nil
    cloudStatus = "not_started"
    cloudLastError = nil
    SaveSystem.ReadFromDisk()
    print("[SaveSystem] Init complete, " .. SaveSystem.GetUsedSlotCount() .. "/" .. MAX_SLOTS .. " slots used")
end

return SaveSystem
