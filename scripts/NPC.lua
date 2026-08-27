-- ============================================================================
-- NPC.lua — 安全区 NPC 系统（管家传送 + 商人商店 + 铁匠锻造）
--
-- 每张地图出生点（安全区）放置三个 NPC：
--   1. 管家（Steward）：花费金币传送到其他地图
--   2. 商人（Merchant）：买卖药水
--   3. 铁匠（Blacksmith）：自动选材锻造装备
--
-- NPC 使用程序化几何搭建（立柱 + 球头 + 不同配色区分身份），
-- 站在安全区内，玩家靠近后点击交互。
-- ============================================================================

local NPC = {}

local MapZone = require("scripts.MapZone")

-- 所有 NPC 的出生点偏移集中在这里，主场景和小地图都通过本模块读取，
-- 避免增加角色后出现“实体位置”和“地图标记”不一致。
NPC.OFFSETS = {
    steward = Vector3(2.5, 0, 2.5),
    merchant = Vector3(-2.5, 0, 2.5),
    blacksmith = Vector3(0, 0, -3.5),
}

NPC.NAMES = {
    steward = "管家",
    merchant = "商人",
    blacksmith = "铁匠",
}

NPC.INTERACTION_LABELS = {
    steward = "与管家交谈（传送）",
    merchant = "与商人交谈（商店）",
    blacksmith = "与铁匠交谈（锻造）",
}

--- 返回 NPC 在指定安全区中的世界坐标。
---@param kind string
---@param spawnPos Vector3|nil
---@return Vector3
function NPC.GetWorldPosition(kind, spawnPos)
    local center = spawnPos or Vector3.ZERO
    return center + (NPC.OFFSETS[kind] or Vector3.ZERO)
end

---@param kind string
---@return string
function NPC.GetName(kind)
    return NPC.NAMES[kind] or "NPC"
end

---@param kind string
---@return string
function NPC.GetInteractionLabel(kind)
    return NPC.INTERACTION_LABELS[kind] or "交谈"
end

-- ============================================================================
-- NPC 定义
-- ============================================================================

--- 在父节点下创建一个人形 NPC（程序化几何）
---@param parentNode Node
---@param name string
---@param bodyColor Color 身体配色
---@param headColor Color 头部配色
---@return Node
local function BuildHumanoid(parentNode, name, bodyColor, headColor)
    local root = parentNode:CreateChild(name)

    local function makeMat(color)
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(color))
        mat:SetShaderParameter("Roughness", Variant(0.6))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        return mat
    end

    local bodyMat = makeMat(bodyColor)
    local headMat = makeMat(headColor)

    -- 身体（立柱）
    local body = root:CreateChild("Body")
    body.position = Vector3(0, 0.7, 0)
    body.scale = Vector3(0.35, 0.7, 0.25)
    local bodyModel = body:CreateComponent("StaticModel")
    bodyModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    bodyModel:SetMaterial(bodyMat)
    bodyModel.castShadows = true

    -- 头部（球）
    local head = root:CreateChild("Head")
    head.position = Vector3(0, 1.45, 0)
    head.scale = Vector3(0.28, 0.28, 0.28)
    local headModel = head:CreateComponent("StaticModel")
    headModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
    headModel:SetMaterial(headMat)
    headModel.castShadows = true

    -- 碰撞体（静态，玩家碰撞层）
    local rbody = root:CreateComponent("RigidBody")
    rbody.mass = 0
    rbody.collisionLayer = 1  -- 地形层（静态障碍）
    rbody.collisionMask = 2   -- 与玩家碰撞
    local shape = root:CreateComponent("CollisionShape")
    shape:SetCapsule(0.35, 1.6, Vector3(0, 0.8, 0))

    return root
end

--- 在 NPC 头顶放置固定屏幕尺寸的身份名称，远处也能分辨服务类型。
---@param root Node
---@param text string
---@param color Color
local function AddNameplate(root, text, color)
    local labelNode = root:CreateChild("Nameplate")
    labelNode.position = Vector3(0, 2.05, 0)
    local label = labelNode:CreateComponent("Text3D")
    label:SetFont("Fonts/MiSans-Regular.ttf", 16)
    label:SetText(text)
    label:SetColor(color)
    label:SetAlignment(HA_CENTER, VA_CENTER)
    label:SetTextAlignment(HA_CENTER)
    label:SetTextEffect(TE_SHADOW)
    label:SetEffectColor(Color(0, 0, 0, 0.9))
    label:SetEffectShadowOffset(IntVector2(1, 1))
    label:SetFaceCameraMode(FC_ROTATE_XYZ)
    label:SetFixedScreenSize(true)
end

-- ============================================================================
-- 运行时状态
-- ============================================================================
local npcs = {}   -- { {node, kind, mapId} }
local sceneRef = nil

--- 在指定地图生成安全区 NPC
---@param scene Scene
---@param mapId string
---@param spawnPos Vector3
function NPC.SpawnForMap(scene, mapId, spawnPos)
    NPC.Clear()
    sceneRef = scene

    -- 管家（金色，站在出生点右前方）
    local steward = BuildHumanoid(scene, "NPC_Steward", Color(0.5, 0.42, 0.2, 1.0), Color(0.75, 0.65, 0.4, 1.0))
    steward.position = NPC.GetWorldPosition("steward", spawnPos)
    AddNameplate(steward, NPC.GetName("steward"), Color(0.95, 0.78, 0.35, 1.0))
    table.insert(npcs, { node = steward, kind = "steward", mapId = mapId })

    -- 商人（蓝色，站在出生点左前方）
    local merchant = BuildHumanoid(scene, "NPC_Merchant", Color(0.2, 0.32, 0.5, 1.0), Color(0.45, 0.55, 0.75, 1.0))
    merchant.position = NPC.GetWorldPosition("merchant", spawnPos)
    AddNameplate(merchant, NPC.GetName("merchant"), Color(0.45, 0.75, 1.0, 1.0))
    table.insert(npcs, { node = merchant, kind = "merchant", mapId = mapId })

    -- 铁匠（深灰身体 + 炉火色头部，站在出生点后方）
    local blacksmith = BuildHumanoid(scene, "NPC_Blacksmith", Color(0.28, 0.3, 0.34, 1.0), Color(0.9, 0.32, 0.12, 1.0))
    blacksmith.position = NPC.GetWorldPosition("blacksmith", spawnPos)
    AddNameplate(blacksmith, NPC.GetName("blacksmith"), Color(1.0, 0.48, 0.18, 1.0))
    table.insert(npcs, { node = blacksmith, kind = "blacksmith", mapId = mapId })

    print("[NPC] Spawned steward + merchant + blacksmith at map " .. mapId)
end

--- 清理所有 NPC
function NPC.Clear()
    for _, n in ipairs(npcs) do
        if n.node then n.node:Remove() end
    end
    npcs = {}
end

--- 查询玩家附近是否有可交互 NPC（返回 kind, mapId, distance）
---@param playerPos Vector3
---@param maxDist number
---@return string|nil, string|nil, number|nil
function NPC.FindNearby(playerPos, maxDist)
    maxDist = maxDist or 2.5
    local best = nil
    local bestDist = maxDist
    for _, n in ipairs(npcs) do
        if n.node then
            local d = (n.node.position - playerPos):Length()
            if d <= bestDist then
                bestDist = d
                best = n
            end
        end
    end
    if best then
        return best.kind, best.mapId, bestDist
    end
    return nil, nil, nil
end

--- 获取所有地图传送选项（供管家对话面板使用）
---@param currentMapId string
---@param playerLevel number|nil 当前角色等级；传入后会标记未达等级的地图
---@return table[] {id, name, cost, current}
function NPC.GetTeleportOptions(currentMapId, playerLevel)
    local options = {}
    local currentCost = MapZone.GetTeleportCost(currentMapId)
    for mapId, def in pairs(MapZone.DEFS) do
        if mapId ~= currentMapId then
            local requiredLevel = def.minLevel or 1
            local level = tonumber(playerLevel)
            local locked = level ~= nil and level < requiredLevel
            table.insert(options, {
                id = mapId,
                name = def.name,
                minLevel = def.minLevel,
                maxLevel = def.maxLevel,
                cost = currentCost,  -- 从当前图传送出去的费用统一
                locked = locked,
                lockReason = locked and ("需要 Lv." .. requiredLevel) or nil,
                current = false,
            })
        end
    end
    -- 按 minLevel 排序
    table.sort(options, function(a, b) return a.minLevel < b.minLevel end)
    return options
end

return NPC
