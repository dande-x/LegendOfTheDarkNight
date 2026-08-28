---@diagnostic disable: undefined-field
-- ============================================================================
-- MapZone.lua - map definitions and host-facing transition helper
-- ============================================================================
-- This module deliberately owns only map data and engine-safe transition work.
-- main.lua remains responsible for rebuilding floor/decorations, clearing Combat,
-- refreshing UI, and persisting the selected map.

local MapZone = {}

-- 所有地图统一使用 6m 半边长的方形安全区（总尺寸 12m × 12m）。
-- 视觉边界、刷怪过滤、战斗保护和地图 UI 都通过该值保持一致。
MapZone.DEFAULT_SAFE_ZONE_RADIUS = 6

-- 所有地图共用 120m × 120m 的可玩区域。场景地面、刷怪边界与地图 UI
-- 统一读取这里，避免视觉地图与实际可走范围逐渐漂移。
MapZone.ARENA_SIZE = 120

MapZone.DEFS = {
    map_bq = {
        name = "比奇省 · 银杏山谷",
        minLevel = 1,
        maxLevel = 9,
        groundColor = Color(0.16, 0.24, 0.14, 1.0),
        fogColor = Color(0.26, 0.29, 0.34, 1.0),
        -- 比奇自然生态；任务只统计行为，不改动候选池或刷新权重。
        spawnPool = { "稻草人", "蛤蟆", "多钩猫", "钉耙猫", "鹿", "幽灵", "骷髅", "半兽人", "毒蜘蛛" },
        boss = "半兽勇士",
        spawnSettings = { initialCount = 10, maxEnemies = 24, interval = 1.10 },
        spawnPos = Vector3.ZERO,
        safeZoneRadius = 6,     -- 方形安全区半边长（不刷怪）
        teleportCost = 100,      -- 管家传送统一收取 100 金
        mapColor = { 40, 70, 42, 245 },
        landmarks = {
            { name = "荒村废墟", x = -30, z = -22 },
            { name = "毒蛛巢", x = 28, z = 22 },
            { name = "断桥", x = 15, z = 12 },
        },
    },
    map_mz = {
        name = "盟重土城",
        minLevel = 10,
        maxLevel = 24,
        groundColor = Color(0.38, 0.29, 0.16, 1.0),
        fogColor = Color(0.46, 0.39, 0.24, 1.0),
        -- 盟重自然生态；显式首领遭遇也通过 Combat 的统一生成入口创建。
        spawnPool = { "狼", "石魔", "红野猪", "黑野猪" },
        boss = "白野猪",
        spawnSettings = { initialCount = 12, maxEnemies = 28, interval = 0.95 },
        spawnPos = Vector3.ZERO,
        safeZoneRadius = 6,
        teleportCost = 100,
        mapColor = { 105, 76, 42, 245 },
        landmarks = {
            { name = "北城残垣", x = 0, z = 40 },
            { name = "石墓入口", x = 30, z = 20 },
            { name = "黄沙商路", x = -34, z = -9 },
        },
    },
    map_sc = {
        name = "水上城市",
        minLevel = 25,
        maxLevel = 34,
        groundColor = Color(0.06, 0.17, 0.31, 1.0),
        fogColor = Color(0.12, 0.42, 0.46, 1.0),
        -- 水城自然生态维持 25~34 级，不再临时补入指定任务怪。
        spawnPool = { "石像鬼", "海妖", "巨蜥" },
        boss = "蚁后",
        spawnSettings = { initialCount = 12, maxEnemies = 30, interval = 1.00 },
        spawnPos = Vector3.ZERO,
        safeZoneRadius = 6,
        teleportCost = 100,
        mapColor = { 20, 70, 88, 245 },
        landmarks = {
            { name = "灯塔", x = 0, z = 38 },
            { name = "西水道", x = -30, z = 0 },
            { name = "蚁穴入口", x = 30, z = -26 },
        },
    },
    map_wm = {
        name = "沃玛寺庙",
        minLevel = 35,
        maxLevel = 44,
        groundColor = Color(0.18, 0.22, 0.28, 1.0),
        fogColor = Color(0.31, 0.35, 0.40, 1.0),
        -- 沃玛自然生态；任务不会改变这里的怪物构成。
        spawnPool = { "岩甲兽", "黑鳞蟒", "深渊恶鬼" },
        boss = "沃玛教主",
        spawnSettings = { initialCount = 10, maxEnemies = 26, interval = 1.10 },
        spawnPos = Vector3.ZERO,
        safeZoneRadius = 6,
        teleportCost = 100,
        mapColor = { 58, 62, 72, 245 },
        landmarks = {
            { name = "封印祭坛", x = 0, z = 18 },
            { name = "石柱廊", x = -12, z = -22 },
            { name = "教主殿", x = 30, z = -28 },
        },
    },
    map_zm = {
        name = "火龙魔窟",
        minLevel = 45,
        maxLevel = 50,
        groundColor = Color(0.22, 0.08, 0.04, 1.0),
        fogColor = Color(0.18, 0.08, 0.22, 1.0),
        -- 祖玛卫士保留精英身份，由 Combat 以较低权重混入常规生态。
        spawnPool = { "熔岩巨兽", "魔龙幼崽", "祖玛卫士" },
        boss = { "牛魔王", "火龙王" },
        spawnSettings = { initialCount = 8, maxEnemies = 22, interval = 1.20 },
        spawnPos = Vector3.ZERO,
        safeZoneRadius = 6,
        teleportCost = 100,
        mapColor = { 82, 30, 24, 245 },
        landmarks = {
            { name = "熔岩池", x = -26, z = 22 },
            { name = "熔火龙巢", x = 0, z = -32 },
            { name = "深渊王座", x = 30, z = 26 },
        },
    },
}

local currentMapId = "map_bq"

---@param mapId string
---@return table|nil
function MapZone.GetDef(mapId)
    return MapZone.DEFS[mapId]
end

---@param mapId string
---@return table|nil
function MapZone.GetPool(mapId)
    local mapDef = MapZone.GetDef(mapId)
    return mapDef and mapDef.spawnPool or nil
end

---@param mapId string
---@return table {initialCount:number,maxEnemies:number,interval:number}
function MapZone.GetSpawnSettings(mapId)
    local mapDef = MapZone.GetDef(mapId)
    local settings = mapDef and mapDef.spawnSettings or nil
    return {
        initialCount = settings and settings.initialCount or 10,
        maxEnemies = settings and settings.maxEnemies or 24,
        interval = settings and settings.interval or 1.10,
    }
end

---@return string
function MapZone.GetCurrentMapId()
    return currentMapId
end

--- 设置当前地图。地图状态由 Combat.SetMap 与该辅助函数共同维护，避免
--- CreateFloor/安全区、刷怪和存档各自读取到不同地图。
---@param mapId string
---@return boolean
function MapZone.SetCurrentMap(mapId)
    if not MapZone.GetDef(mapId) then return false end
    currentMapId = mapId
    return true
end

--- 判断角色是否达到地图进入等级。NPC 手动传送据此锁定地图；
--- 剧情自动传送由宿主直接切图，不经过该门槛。
---@param mapId string
---@param playerLevel number|nil
---@return boolean
function MapZone.IsLevelAllowed(mapId, playerLevel)
    local mapDef = MapZone.GetDef(mapId)
    if not mapDef then return false end
    if playerLevel == nil then return true end
    return (tonumber(playerLevel) or 1) >= (mapDef.minLevel or 1)
end

---@param mapId string
---@return string
function MapZone.GetLevelRequirement(mapId)
    local mapDef = MapZone.GetDef(mapId)
    if not mapDef or not mapDef.minLevel then return "" end
    return "需要 Lv." .. tostring(mapDef.minLevel)
end

---@param mapId string
---@param bossName string
---@return boolean
function MapZone.HasBoss(mapId, bossName)
    local mapDef = MapZone.GetDef(mapId)
    if not mapDef then return false end

    if type(mapDef.boss) == "string" then
        return mapDef.boss == bossName
    end

    for _, name in ipairs(mapDef.boss) do
        if name == bossName then return true end
    end
    return false
end

--- 方形安全区半边长（沿 X/Z 轴；安全区内不刷怪）
---@param mapId string
---@return number
function MapZone.GetSafeZoneRadius(mapId)
    local mapDef = MapZone.GetDef(mapId)
    return mapDef and (mapDef.safeZoneRadius or MapZone.DEFAULT_SAFE_ZONE_RADIUS)
        or MapZone.DEFAULT_SAFE_ZONE_RADIUS
end

--- 判断世界坐标是否位于地图可玩边界内。
---@param position Vector3|nil
---@param padding number|nil 与地面边缘保留的内缩距离
---@return boolean
function MapZone.IsInsideArena(position, padding)
    if not position then return false end
    local half = math.max(0, MapZone.ARENA_SIZE * 0.5 - (padding or 0))
    return math.abs(position.x) <= half and math.abs(position.z) <= half
end

--- 将世界坐标限制在地图可玩边界内。
---@param position Vector3|nil
---@param padding number|nil 与地面边缘保留的内缩距离
---@return Vector3|nil, boolean 是否发生了限制
function MapZone.ClampToArena(position, padding)
    if not position then return nil, false end
    local half = math.max(0, MapZone.ARENA_SIZE * 0.5 - (padding or 0))
    local x = math.max(-half, math.min(half, position.x))
    local z = math.max(-half, math.min(half, position.z))
    return Vector3(x, position.y, z), x ~= position.x or z ~= position.z
end

--- 从指定地图传送出去的费用
---@param mapId string
---@return number
function MapZone.GetTeleportCost(mapId)
    local mapDef = MapZone.GetDef(mapId)
    return mapDef and (mapDef.teleportCost or 0) or 0
end

---@param mapId string
---@param scene Scene|nil
---@param playerNode Node|nil
---@return boolean, table|string
function MapZone.SwitchTo(mapId, scene, playerNode)
    local mapDef = MapZone.GetDef(mapId)
    if not mapDef then
        return false, "Unknown map id: " .. tostring(mapId)
    end

    MapZone.SetCurrentMap(mapId)

    -- Host integration step 1: call Combat.Clear() before this helper to remove
    -- monsters and ground loot belonging to the previous map.
    -- Host integration step 2: rebuild the floor and decorations with
    -- main.CreateFloor(mapDef.groundColor) and map-specific decoration helpers.

    if scene then
        -- main.lua creates the Zone under LightGroup. Recursive lookup updates it
        -- without coupling this module to main.lua's local lightGroup variable.
        local zone = scene:GetComponent("Zone", true)
        if zone then
            zone.fogColor = mapDef.fogColor
        end
    end

    if playerNode then
        playerNode.position = mapDef.spawnPos
    end

    -- Host integration step 3: refresh the map/teleport UI and call the map-aware
    -- Combat spawner with mapId. Only spawn mapDef.boss while Quest's active target
    -- matches it; use HasBoss for map_zm's two Boss definitions.
    -- Host integration step 4: persist currentMapId in SaveSystem.CreateSnapshot
    -- and invoke this helper after loading a saved mapId.
    return true, mapDef
end

return MapZone
