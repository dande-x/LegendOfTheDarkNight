-- ============================================================================
-- NPC.lua — 安全区 NPC 系统（管家传送 + 商人商店 + 铁匠锻造/强化）
--
-- 每张地图出生点（安全区）放置三个 NPC：
--   1. 管家（Steward）：花费金币传送到其他地图
--   2. 商人（Merchant）：买卖药水
--   3. 铁匠（Blacksmith）：自动选材锻造装备，并提供金币强化
--
-- NPC 使用统一的白袍兜帽人形，并用腰带、胸章与随身物件区分身份，
-- 站在安全区内面向出生点，玩家靠近后点击交互。
-- ============================================================================

local NPC = {}

local MapZone = require("scripts.MapZone")
local G = require("classes.GeomUtils")

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
    -- 交互按钮保留动作与服务，省略已经由头顶名牌表达的 NPC 身份，
    -- 避免完整句式在小屏上拥挤，同时让按钮仍然以明确动词开头。
    steward = "交谈 · 传送",
    merchant = "交谈 · 商店",
    blacksmith = "锻造 · 强化",
}

local ROLE_STYLES = {
    steward = {
        accent = Color(0.76, 0.56, 0.16, 1.0),
        emissive = Color(0.055, 0.028, 0.003, 1.0),
        nameColor = Color(0.95, 0.78, 0.35, 1.0),
    },
    merchant = {
        accent = Color(0.18, 0.48, 0.78, 1.0),
        emissive = Color(0.008, 0.035, 0.085, 1.0),
        nameColor = Color(0.45, 0.75, 1.0, 1.0),
    },
    blacksmith = {
        accent = Color(0.82, 0.27, 0.075, 1.0),
        emissive = Color(0.10, 0.018, 0.002, 1.0),
        nameColor = Color(1.0, 0.48, 0.18, 1.0),
    },
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

local function MakeMaterial(color, roughness, metallic, emissive)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.72))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    if emissive then
        mat:SetShaderParameter("MatEmissiveColor", Variant(emissive))
    end
    return mat
end

local function AddModelPart(parent, name, modelPath, material, position, scale, rotation)
    local node = parent:CreateChild(name)
    node.position = position or Vector3.ZERO
    node.scale = scale or Vector3(1, 1, 1)
    node.rotation = rotation or Quaternion.IDENTITY

    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", modelPath))
    model:SetMaterial(material)
    model.castShadows = true
    return node
end

local function AddTaperedPart(parent, name, material, position,
        radiusBottom, radiusTop, height, segments, rotation)
    local node = parent:CreateChild(name)
    node.position = position or Vector3.ZERO
    node.rotation = rotation or Quaternion.IDENTITY

    local geom = node:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)
    G.addTapered(geom, 0, 0, 0, radiusBottom, radiusTop, height, segments or 16)
    geom:Commit()
    geom:SetMaterial(material)
    geom.castShadows = true
    return node
end

local function AddRoleAccessory(root, kind, materials)
    if kind == "steward" then
        -- 金色权杖与头顶印记，远处也能和商人区分。
        AddModelPart(root, "StewardStaff", "Models/Cylinder.mdl", materials.leather,
            Vector3(0.57, 0.77, 0.04), Vector3(0.055, 1.24, 0.055),
            Quaternion(0, 0, -6))
        AddModelPart(root, "StewardStaffSeal", "Models/Sphere.mdl", materials.accent,
            Vector3(0.64, 1.39, 0.04), Vector3(0.18, 0.18, 0.18))
    elseif kind == "merchant" then
        -- 斜挎带和钱袋，明确表达买卖服务。
        AddModelPart(root, "MerchantSatchelStrap", "Models/Box.mdl", materials.leather,
            Vector3(-0.06, 1.16, 0.285), Vector3(0.055, 0.76, 0.045),
            Quaternion(0, 0, -28))
        AddModelPart(root, "MerchantCoinPouch", "Models/Sphere.mdl", materials.accent,
            Vector3(-0.33, 0.72, 0.24), Vector3(0.28, 0.31, 0.17))
        AddModelPart(root, "MerchantPouchClasp", "Models/Sphere.mdl", materials.gold,
            Vector3(-0.33, 0.78, 0.335), Vector3(0.075, 0.075, 0.045))
    elseif kind == "blacksmith" then
        -- 侧握铁锤；锤头用深金属，中心保留炉火橙标识。
        local hammerRotation = Quaternion(0, 0, -18)
        AddModelPart(root, "BlacksmithHammerHandle", "Models/Box.mdl", materials.leather,
            Vector3(0.49, 0.80, 0.07), Vector3(0.065, 0.72, 0.065), hammerRotation)
        AddModelPart(root, "BlacksmithHammerHead", "Models/Box.mdl", materials.metal,
            Vector3(0.60, 1.13, 0.07), Vector3(0.34, 0.16, 0.20), hammerRotation)
        AddModelPart(root, "BlacksmithEmber", "Models/Sphere.mdl", materials.accent,
            Vector3(0.60, 1.13, 0.18), Vector3(0.11, 0.08, 0.045), hammerRotation)
    end
end

--- 在父节点下创建白袍尖帽人形 NPC。所有身份共用轮廓，只改变服务标识。
---@param parentNode Node
---@param name string
---@param kind string
---@return Node
local function BuildHoodedHumanoid(parentNode, name, kind)
    local root = parentNode:CreateChild(name)
    local style = ROLE_STYLES[kind] or ROLE_STYLES.steward
    local materials = {
        robe = MakeMaterial(Color(0.88, 0.86, 0.80, 1.0), 0.82, 0.0),
        robeShade = MakeMaterial(Color(0.62, 0.62, 0.59, 1.0), 0.86, 0.0),
        hood = MakeMaterial(Color(0.94, 0.92, 0.86, 1.0), 0.78, 0.0),
        faceShadow = MakeMaterial(Color(0.018, 0.022, 0.028, 1.0), 0.94, 0.0),
        skin = MakeMaterial(Color(0.58, 0.42, 0.30, 1.0), 0.78, 0.0),
        leather = MakeMaterial(Color(0.16, 0.09, 0.045, 1.0), 0.72, 0.02),
        metal = MakeMaterial(Color(0.20, 0.21, 0.23, 1.0), 0.34, 0.72),
        gold = MakeMaterial(Color(0.72, 0.52, 0.14, 1.0), 0.30, 0.58,
            Color(0.035, 0.018, 0.002, 1.0)),
        accent = MakeMaterial(style.accent, 0.42, kind == "blacksmith" and 0.32 or 0.12,
            style.emissive),
    }

    -- 袍身：整体收窄并拉高，形成参考图中的细长人型比例。
    AddTaperedPart(root, "WhiteRobeLower", materials.robe, Vector3(0, 0.56, 0),
        0.34, 0.22, 1.22, 18)
    AddTaperedPart(root, "WhiteRobeTorso", materials.robe, Vector3(0, 1.18, 0),
        0.23, 0.19, 0.52, 18)
    AddModelPart(root, "RobeHem", "Models/Cylinder.mdl", materials.robeShade,
        Vector3(0, 0.11, 0), Vector3(0.66, 0.055, 0.54))
    AddModelPart(root, "RoleBelt", "Models/Cylinder.mdl", materials.accent,
        Vector3(0, 0.98, 0), Vector3(0.49, 0.075, 0.40))

    -- 窄袖向身体两侧自然下垂；袖口露出双手，强化人形识别。
    for _, side in ipairs({-1, 1}) do
        local sideName = side < 0 and "L" or "R"
        AddTaperedPart(root, "WhiteSleeve_" .. sideName, materials.robe,
            Vector3(side * 0.34, 1.25, 0), 0.13, 0.15, 0.56, 14,
            Quaternion(0, 0, side * 38))
        AddModelPart(root, "Hand_" .. sideName, "Models/Sphere.mdl", materials.skin,
            Vector3(side * 0.48, 1.04, 0.015), Vector3(0.12, 0.14, 0.11))
    end

    -- 披肩、尖帽与帽檐形成参考图中清晰的高尖头部剪影。
    AddTaperedPart(root, "HoodedCowl", materials.robeShade, Vector3(0, 1.57, -0.01),
        0.28, 0.21, 0.18, 18)
    AddModelPart(root, "HoodFaceShadow", "Models/Sphere.mdl", materials.faceShadow,
        Vector3(0, 1.68, 0.255), Vector3(0.29, 0.32, 0.08))
    AddModelPart(root, "PointedHat", "Models/Cone.mdl", materials.hood,
        Vector3(0, 2.04, -0.02), Vector3(0.36, 0.52, 0.36))
    AddModelPart(root, "HatBrim", "Models/Cylinder.mdl", materials.hood,
        Vector3(0, 1.80, -0.015), Vector3(0.52, 0.055, 0.41))
    AddModelPart(root, "HatBand", "Models/Cylinder.mdl", materials.robeShade,
        Vector3(0, 1.87, -0.02), Vector3(0.37, 0.045, 0.29))

    -- 袍下露出少量深色鞋面，避免模型像悬浮的圆锥。
    AddModelPart(root, "BootL", "Models/Box.mdl", materials.faceShadow,
        Vector3(-0.13, 0.085, 0.13), Vector3(0.16, 0.17, 0.28))
    AddModelPart(root, "BootR", "Models/Box.mdl", materials.faceShadow,
        Vector3(0.13, 0.085, 0.13), Vector3(0.16, 0.17, 0.28))

    AddModelPart(root, "RoleSeal", "Models/Sphere.mdl", materials.accent,
        Vector3(0, 1.30, 0.22), Vector3(0.13, 0.13, 0.055))
    AddRoleAccessory(root, kind, materials)

    -- 保持原有窄胶囊碰撞，尖帽和细长袍身只影响外观，不扩大阻路范围。
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
    labelNode.position = Vector3(0, 2.48, 0)
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

    local center = spawnPos or Vector3.ZERO
    local function spawnHoodedNPC(kind, nodeName)
        local npc = BuildHoodedHumanoid(scene, nodeName, kind)
        npc.position = NPC.GetWorldPosition(kind, center)
        npc:LookAt(Vector3(center.x, npc.position.y, center.z))
        AddNameplate(npc, NPC.GetName(kind), ROLE_STYLES[kind].nameColor)
        table.insert(npcs, { node = npc, kind = kind, mapId = mapId })
    end

    -- 三名 NPC 共用白袍尖帽轮廓，分别以权杖、钱袋、铁锤标识服务。
    spawnHoodedNPC("steward", "NPC_Steward")
    spawnHoodedNPC("merchant", "NPC_Merchant")
    spawnHoodedNPC("blacksmith", "NPC_Blacksmith")

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
