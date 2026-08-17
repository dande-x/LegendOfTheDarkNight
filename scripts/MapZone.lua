---@diagnostic disable: undefined-field
-- ============================================================================
-- MapZone.lua - map definitions and host-facing transition helper
-- ============================================================================
-- This module deliberately owns only map data and engine-safe transition work.
-- main.lua remains responsible for rebuilding floor/decorations, clearing Combat,
-- refreshing UI, and persisting the selected map.

local MapZone = {}

MapZone.DEFS = {
    map_bq = {
        name = "比奇省 · 银杏山谷",
        minLevel = 1,
        maxLevel = 9,
        groundColor = Color(0.16, 0.24, 0.14, 1.0),
        fogColor = Color(0.26, 0.29, 0.34, 1.0),
        spawnPool = { "稻草人", "蛤蟆", "多钩猫", "钉耙猫", "鹿", "幽灵", "骷髅" },
        boss = "半兽勇士",
        spawnPos = Vector3.ZERO,
    },
    map_mz = {
        name = "盟重土城",
        minLevel = 10,
        maxLevel = 24,
        groundColor = Color(0.38, 0.29, 0.16, 1.0),
        fogColor = Color(0.46, 0.39, 0.24, 1.0),
        spawnPool = { "狼", "半兽人", "石魔", "毒蜘蛛", "骷髅" },
        boss = "白野猪",
        spawnPos = Vector3.ZERO,
    },
    map_sc = {
        name = "水上城市",
        minLevel = 25,
        maxLevel = 34,
        groundColor = Color(0.06, 0.17, 0.31, 1.0),
        fogColor = Color(0.12, 0.42, 0.46, 1.0),
        spawnPool = { "石像鬼", "海妖", "巨蜥" },
        boss = "蚁后",
        spawnPos = Vector3.ZERO,
    },
    map_wm = {
        name = "沃玛寺庙",
        minLevel = 35,
        maxLevel = 44,
        groundColor = Color(0.18, 0.22, 0.28, 1.0),
        fogColor = Color(0.31, 0.35, 0.40, 1.0),
        spawnPool = { "岩甲兽", "黑鳞蟒", "深渊恶鬼" },
        boss = "沃玛教主",
        spawnPos = Vector3.ZERO,
    },
    map_zm = {
        name = "祖玛寺庙",
        minLevel = 45,
        maxLevel = 50,
        groundColor = Color(0.22, 0.08, 0.04, 1.0),
        fogColor = Color(0.18, 0.08, 0.22, 1.0),
        spawnPool = { "熔岩巨兽", "魔龙幼崽" },
        boss = { "牛魔王", "火龙王" },
        spawnPos = Vector3.ZERO,
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

---@return string
function MapZone.GetCurrentMapId()
    return currentMapId
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

---@param mapId string
---@param scene Scene|nil
---@param playerNode Node|nil
---@return boolean, table|string
function MapZone.SwitchTo(mapId, scene, playerNode)
    local mapDef = MapZone.GetDef(mapId)
    if not mapDef then
        return false, "Unknown map id: " .. tostring(mapId)
    end

    currentMapId = mapId

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
