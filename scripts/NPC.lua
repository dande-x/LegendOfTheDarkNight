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

-- Resolve the canonical map definitions alongside this canonical NPC module;
-- the `scripts.` prefix can select the legacy assets/scripts mirror first.
local MapZone = require("MapZone")
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
        robe = Color(0.90, 0.87, 0.78, 1.0),
        robeShade = Color(0.64, 0.59, 0.46, 1.0),
    },
    merchant = {
        accent = Color(0.18, 0.48, 0.78, 1.0),
        emissive = Color(0.008, 0.035, 0.085, 1.0),
        nameColor = Color(0.45, 0.75, 1.0, 1.0),
        robe = Color(0.80, 0.84, 0.86, 1.0),
        robeShade = Color(0.42, 0.52, 0.60, 1.0),
    },
    blacksmith = {
        accent = Color(0.82, 0.27, 0.075, 1.0),
        emissive = Color(0.10, 0.018, 0.002, 1.0),
        nameColor = Color(1.0, 0.48, 0.18, 1.0),
        robe = Color(0.70, 0.68, 0.63, 1.0),
        robeShade = Color(0.31, 0.30, 0.29, 1.0),
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

-- NPC 交互特效使用独立透明材质，避免把半透明参数混进袍身等实体材质。
-- 统一走 PBRNoTextureAlpha，保证发光环和漂浮粒子在暗色地图中仍可读。
local function MakeEffectMaterial(color, alpha, emissiveScale)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(color.r, color.g, color.b, alpha or 0.32)))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(
        color.r * (emissiveScale or 1.0),
        color.g * (emissiveScale or 1.0),
        color.b * (emissiveScale or 1.0), 1.0)))
    mat:SetShaderParameter("Metallic", Variant(0.0))
    mat:SetShaderParameter("Roughness", Variant(0.18))
    return mat
end

local function AddModelPart(parent, name, modelPath, material, position, scale, rotation, castShadows)
    local node = parent:CreateChild(name)
    node.position = position or Vector3.ZERO
    node.scale = scale or Vector3(1, 1, 1)
    node.rotation = rotation or Quaternion.IDENTITY

    local model = node:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", modelPath))
    model:SetMaterial(material)
    model.castShadows = castShadows ~= false
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
    local parts = {}
    if kind == "steward" then
        -- 金色权杖与头顶印记，远处也能和商人区分。
        local staff = root:CreateChild("StewardStaff")
        parts.staff = staff
        -- 把摆动支点放在权杖底部；子部件改用相对坐标，避免绕
        -- visualRoot 原点旋转时整根权杖发生明显平移。
        local staffPivot = Vector3(0.57, 0.43, 0.04)
        staff.position = staffPivot
        AddModelPart(staff, "Shaft", "Models/Cylinder.mdl", materials.leather,
            Vector3(0, 0.34, 0), Vector3(0.055, 1.24, 0.055),
            Quaternion(0, 0, -6))
        AddModelPart(staff, "Seal", "Models/Sphere.mdl", materials.accent,
            Vector3(0.07, 0.96, 0), Vector3(0.18, 0.18, 0.18))
        AddModelPart(staff, "Tip", "Models/Cone.mdl", materials.gold,
            Vector3(0.07, 1.14, 0), Vector3(0.09, 0.14, 0.09))
    elseif kind == "merchant" then
        -- 斜挎带和钱袋，明确表达买卖服务。
        local satchel = root:CreateChild("MerchantSatchel")
        parts.satchel = satchel
        -- 钱袋以胸腹附近为摆动支点，保持配件整体位置稳定。
        local satchelPivot = Vector3(-0.20, 0.90, 0.24)
        satchel.position = satchelPivot
        AddModelPart(satchel, "MerchantSatchelStrap", "Models/Box.mdl", materials.leather,
            Vector3(0.14, 0.26, 0.045), Vector3(0.055, 0.76, 0.045),
            Quaternion(0, 0, -28))
        AddModelPart(satchel, "MerchantCoinPouch", "Models/Sphere.mdl", materials.accent,
            Vector3(-0.13, -0.18, 0), Vector3(0.28, 0.31, 0.17))
        AddModelPart(satchel, "MerchantPouchClasp", "Models/Sphere.mdl", materials.gold,
            Vector3(-0.13, -0.12, 0.095), Vector3(0.075, 0.075, 0.045))
        AddModelPart(satchel, "MerchantPouchTrim", "Models/Cylinder.mdl", materials.gold,
            Vector3(-0.13, -0.26, 0), Vector3(0.19, 0.028, 0.12))
    elseif kind == "blacksmith" then
        -- 侧握铁锤；锤头用深金属，中心保留炉火橙标识。
        local hammerRotation = Quaternion(0, 0, -18)
        local hammer = root:CreateChild("BlacksmithHammer")
        parts.hammer = hammer
        -- 以锤柄底部为支点做轻微待机摆动，避免整个锤子绕 NPC 原点漂移。
        local hammerPivot = Vector3(0.48, 0.43, 0.07)
        hammer.position = hammerPivot
        AddModelPart(hammer, "BlacksmithHammerHandle", "Models/Box.mdl", materials.leather,
            Vector3(0.01, 0.37, 0), Vector3(0.065, 0.72, 0.065), hammerRotation)
        AddModelPart(hammer, "BlacksmithHammerHead", "Models/Box.mdl", materials.metal,
            Vector3(0.12, 0.70, 0), Vector3(0.34, 0.16, 0.20), hammerRotation)
        AddModelPart(hammer, "BlacksmithEmber", "Models/Sphere.mdl", materials.accent,
            Vector3(0.12, 0.70, 0.11), Vector3(0.11, 0.08, 0.045), hammerRotation)
        AddModelPart(hammer, "BlacksmithHammerPommel", "Models/Sphere.mdl", materials.gold,
            Vector3(0, 0, 0), Vector3(0.10, 0.10, 0.10), hammerRotation)
    end
    return parts
end

local function AddRoleGarment(root, kind, materials)
    -- 用少量叠层几何打破“同一件白袍复制三份”的感觉；这些装饰都
    -- 位于碰撞胶囊内部，不改变 NPC 的阻路范围。
    if kind == "steward" then
        AddModelPart(root, "StewardMantle", "Models/Box.mdl", materials.robeShade,
            Vector3(0, 1.34, 0.18), Vector3(0.38, 0.18, 0.055), nil, false)
        AddModelPart(root, "StewardMantlePin", "Models/Sphere.mdl", materials.gold,
            Vector3(0, 1.34, 0.245), Vector3(0.09, 0.09, 0.045), nil, false)
    elseif kind == "merchant" then
        AddModelPart(root, "MerchantApron", "Models/Box.mdl", materials.robeShade,
            Vector3(0, 0.78, 0.245), Vector3(0.34, 0.44, 0.06), nil, false)
        AddModelPart(root, "MerchantApronPocket", "Models/Box.mdl", materials.accent,
            Vector3(0, 0.67, 0.315), Vector3(0.17, 0.13, 0.035), nil, false)
        AddModelPart(root, "MerchantApronPin", "Models/Sphere.mdl", materials.gold,
            Vector3(0, 1.06, 0.315), Vector3(0.075, 0.075, 0.045), nil, false)
    elseif kind == "blacksmith" then
        AddModelPart(root, "BlacksmithApron", "Models/Box.mdl", materials.leather,
            Vector3(0, 0.76, 0.245), Vector3(0.37, 0.48, 0.06), nil, false)
        AddModelPart(root, "BlacksmithApronPlate", "Models/Box.mdl", materials.metal,
            Vector3(0, 0.93, 0.315), Vector3(0.22, 0.16, 0.035), nil, false)
        AddModelPart(root, "BlacksmithApronRivet", "Models/Sphere.mdl", materials.accent,
            Vector3(0, 0.93, 0.36), Vector3(0.055, 0.055, 0.035), nil, false)
    end
end

local function AddEffectPart(parent, name, modelPath, material, position, scale, rotation)
    return AddModelPart(parent, name, modelPath, material, position, scale, rotation, false)
end

local function AddEffectRing(parent, name, material, position, scale)
    -- Torus 本体的薄轴是 Y（包围盒约 1.28 × 0.26 × 1.28），默认姿态
    -- 已经平放在地面上；不要额外绕 X 轴旋转，否则会变成竖直光环。
    return AddEffectPart(parent, name, "Models/Torus.mdl", material,
        position, scale, Quaternion.IDENTITY)
end

local function CreateRoleEffects(root, kind, style)
    local effectColor = style.accent
    local ringMaterial = MakeEffectMaterial(effectColor, 0.28,
        kind == "blacksmith" and 1.65 or 1.25)
    local softMaterial = MakeEffectMaterial(effectColor, 0.42,
        kind == "blacksmith" and 2.05 or 1.55)
    local effects = {
        phase = 0,
        ring = AddEffectRing(root, "ActivityRing", ringMaterial,
            Vector3(0, 0.075, 0), Vector3(0.66, 0.105, 0.66)),
        ringMaterial = ringMaterial,
        softMaterial = softMaterial,
    }

    -- 中央微光点让脚下环不至于只剩一条细线；尺寸很小，不遮挡地面。
    effects.core = AddEffectPart(root, "ActivityCore", "Models/Sphere.mdl", softMaterial,
        Vector3(0, 0.10, 0), Vector3(0.12, 0.035, 0.12))

    if kind == "steward" then
        local sigil = root:CreateChild("StewardSigil")
        sigil.position = Vector3(0, 1.92, 0.24)
        effects.sigil = sigil
        -- 头顶身份徽记朝向玩家，绕 X 轴立起。
        effects.sigilRing = AddEffectPart(sigil, "Ring", "Models/Torus.mdl", softMaterial,
            Vector3.ZERO, Vector3(0.22, 0.075, 0.22), Quaternion(90, 0, 0))
        effects.sigilGem = AddEffectPart(sigil, "Gem", "Models/Sphere.mdl", softMaterial,
            Vector3.ZERO, Vector3(0.085, 0.085, 0.085))
    elseif kind == "merchant" then
        local coinOrbit = root:CreateChild("MerchantCoinOrbit")
        effects.coinOrbit = coinOrbit
        effects.coins = {}
        for index = 1, 3 do
            local coin = AddEffectPart(coinOrbit, "Coin_" .. index, "Models/Cylinder.mdl",
                softMaterial, Vector3.ZERO, Vector3(0.095, 0.028, 0.095), Quaternion(90, 0, 0))
            table.insert(effects.coins, coin)
        end
    elseif kind == "blacksmith" then
        local sparks = root:CreateChild("BlacksmithSparks")
        effects.sparks = {}
        for index = 1, 4 do
            local spark = AddEffectPart(sparks, "Spark_" .. index, "Models/Sphere.mdl",
                softMaterial, Vector3.ZERO, Vector3(0.055, 0.075, 0.055))
            table.insert(effects.sparks, spark)
        end
        effects.sparkOrbit = sparks
    end
    return effects
end

--- 在父节点下创建白袍尖帽人形 NPC。所有身份共用轮廓，只改变服务标识。
---@param parentNode Node
---@param name string
---@param kind string
---@return table
local function BuildHoodedHumanoid(parentNode, name, kind)
    local root = parentNode:CreateChild(name)
    -- 碰撞体留在 root；所有可见模型放进独立 Visual 节点，待机动画不会
    -- 让安全区服务 NPC 的静态碰撞体跟着上下抖动。
    local visualRoot = root:CreateChild("Visual")
    local style = ROLE_STYLES[kind] or ROLE_STYLES.steward
    local materials = {
        robe = MakeMaterial(style.robe or Color(0.88, 0.86, 0.80, 1.0), 0.82, 0.0),
        robeShade = MakeMaterial(style.robeShade or Color(0.62, 0.62, 0.59, 1.0), 0.86, 0.0),
        hood = MakeMaterial(style.hood or Color(0.94, 0.92, 0.86, 1.0), 0.78, 0.0),
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
    AddTaperedPart(visualRoot, "WhiteRobeLower", materials.robe, Vector3(0, 0.56, 0),
        0.34, 0.22, 1.22, 18)
    AddTaperedPart(visualRoot, "WhiteRobeTorso", materials.robe, Vector3(0, 1.18, 0),
        0.23, 0.19, 0.52, 18)
    AddModelPart(visualRoot, "RobeHem", "Models/Cylinder.mdl", materials.robeShade,
        Vector3(0, 0.11, 0), Vector3(0.66, 0.055, 0.54))
    AddModelPart(visualRoot, "RoleBelt", "Models/Cylinder.mdl", materials.accent,
        Vector3(0, 0.98, 0), Vector3(0.49, 0.075, 0.40))

    -- 窄袖向身体两侧自然下垂；袖口露出双手，强化人形识别。
    for _, side in ipairs({-1, 1}) do
        local sideName = side < 0 and "L" or "R"
        AddTaperedPart(visualRoot, "WhiteSleeve_" .. sideName, materials.robe,
            Vector3(side * 0.34, 1.25, 0), 0.13, 0.15, 0.56, 14,
            Quaternion(0, 0, side * 38))
        AddModelPart(visualRoot, "Hand_" .. sideName, "Models/Sphere.mdl", materials.skin,
            Vector3(side * 0.48, 1.04, 0.015), Vector3(0.12, 0.14, 0.11))
    end

    -- 披肩、尖帽与帽檐形成参考图中清晰的高尖头部剪影。
    AddTaperedPart(visualRoot, "HoodedCowl", materials.robeShade, Vector3(0, 1.57, -0.01),
        0.28, 0.21, 0.18, 18)
    AddModelPart(visualRoot, "HoodFaceShadow", "Models/Sphere.mdl", materials.faceShadow,
        Vector3(0, 1.68, 0.255), Vector3(0.29, 0.32, 0.08))
    AddModelPart(visualRoot, "PointedHat", "Models/Cone.mdl", materials.hood,
        Vector3(0, 2.04, -0.02), Vector3(0.36, 0.52, 0.36))
    AddModelPart(visualRoot, "HatBrim", "Models/Cylinder.mdl", materials.hood,
        Vector3(0, 1.80, -0.015), Vector3(0.52, 0.055, 0.41))
    AddModelPart(visualRoot, "HatBand", "Models/Cylinder.mdl", materials.robeShade,
        Vector3(0, 1.87, -0.02), Vector3(0.37, 0.045, 0.29))

    -- 袍下露出少量深色鞋面，避免模型像悬浮的圆锥。
    AddModelPart(visualRoot, "BootL", "Models/Box.mdl", materials.faceShadow,
        Vector3(-0.13, 0.085, 0.13), Vector3(0.16, 0.17, 0.28))
    AddModelPart(visualRoot, "BootR", "Models/Box.mdl", materials.faceShadow,
        Vector3(0.13, 0.085, 0.13), Vector3(0.16, 0.17, 0.28))

    AddModelPart(visualRoot, "RoleSeal", "Models/Sphere.mdl", materials.accent,
        Vector3(0, 1.30, 0.22), Vector3(0.13, 0.13, 0.055))
    local accessoryParts = AddRoleAccessory(visualRoot, kind, materials)
    AddRoleGarment(visualRoot, kind, materials)

    -- 帽尖再加一颗很小的角色色宝石，增强远处轮廓识别；不使用动态灯，
    -- 避免安全区三名 NPC 在低端设备上产生额外逐像素光照开销。
    local hatTip = AddModelPart(visualRoot, "HatTipGem", "Models/Sphere.mdl", materials.accent,
        Vector3(0, 2.31, -0.02), Vector3(0.065, 0.065, 0.065), nil, false)

    -- 保持原有窄胶囊碰撞，尖帽和细长袍身只影响外观，不扩大阻路范围。
    local rbody = root:CreateComponent("RigidBody")
    rbody.mass = 0
    rbody.collisionLayer = 1  -- 地形层（静态障碍）
    rbody.collisionMask = 2   -- 与玩家碰撞
    local shape = root:CreateComponent("CollisionShape")
    shape:SetCapsule(0.35, 1.6, Vector3(0, 0.8, 0))

    return {
        root = root,
        visualRoot = visualRoot,
        style = style,
        materials = materials,
        accessoryParts = accessoryParts,
        hatTip = hatTip,
    }
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
local npcs = {}   -- { {node, kind, mapId, basePosition, baseRotation, phase, effects} }
local sceneRef = nil

---@param node Node|nil
---@return boolean
local function IsNodeAlive(node)
    return node ~= nil and node:GetID() ~= 0
end

--- 在指定地图生成安全区 NPC
---@param scene Scene
---@param mapId string
---@param spawnPos Vector3
function NPC.SpawnForMap(scene, mapId, spawnPos)
    NPC.Clear()
    sceneRef = scene

    local center = spawnPos or Vector3.ZERO
    local function spawnHoodedNPC(kind, nodeName)
        local visual = BuildHoodedHumanoid(scene, nodeName, kind)
        local npc = visual.root
        npc.position = NPC.GetWorldPosition(kind, center)
        npc:LookAt(Vector3(center.x, npc.position.y, center.z))
        AddNameplate(visual.visualRoot, NPC.GetName(kind), ROLE_STYLES[kind].nameColor)
        visual.effects = CreateRoleEffects(visual.visualRoot, kind, ROLE_STYLES[kind])
        table.insert(npcs, {
            node = npc,
            kind = kind,
            mapId = mapId,
            phase = kind == "merchant" and 1.15 or kind == "blacksmith" and 2.40 or 0.35,
            basePosition = Vector3(npc.position.x, npc.position.y, npc.position.z),
            baseRotation = npc.rotation,
            visual = visual,
            effects = visual.effects,
        })
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
        if IsNodeAlive(n.node) then n.node:Remove() end
    end
    npcs = {}
    sceneRef = nil
end

--- 更新安全区 NPC 的轻量待机动画与身份特效。
---
--- 动画只改已有节点的 transform / 材质参数，不创建或销毁运行时对象，
--- 因此切图和长时间挂机时不会持续增加节点数量。
---@param dt number
function NPC.Update(dt)
    dt = tonumber(dt) or 0
    if dt <= 0 then return end
    -- 真机卡顿恢复时避免一次性跳动过大，视觉上仍保持连续。
    dt = math.min(dt, 0.10)

    for _, entry in ipairs(npcs) do
        local node = entry.node
        local effects = entry.effects
        local visualRoot = entry.visual and entry.visual.visualRoot
        if IsNodeAlive(node) and IsNodeAlive(visualRoot) and effects then
            entry.phase = entry.phase + dt
            local t = entry.phase
            local style = entry.visual and entry.visual.style or ROLE_STYLES[entry.kind]

            -- 细微呼吸起伏：幅度小于 2cm，不影响交互距离和碰撞。
            local bob = math.sin(t * 1.65) * 0.018
            visualRoot.position = Vector3(0, bob, 0)
            local sway = math.sin(t * 1.15 + 0.4) * 1.2
            visualRoot.rotation = Quaternion(sway, Vector3.UP)

            local pulse = 1.0 + math.sin(t * 3.0 + 0.5) * 0.10
            if effects.ring then
                effects.ring.scale = Vector3(0.66 * pulse, 0.105, 0.66 * pulse)
                -- Torus 的薄轴是 Y，默认姿态就是贴地环；这里只绕 Y 轴
                -- 旋转，避免把脚下标识误转成立环。
                effects.ring.rotation = Quaternion(
                    t * (entry.kind == "blacksmith" and 42 or 28), Vector3.UP)
            end
            if effects.core then
                local coreScale = 0.12 * (0.92 + math.sin(t * 3.0) * 0.10)
                effects.core.scale = Vector3(coreScale, 0.035, coreScale)
            end
            if effects.ringMaterial and style then
                effects.ringMaterial:SetShaderParameter("MatDiffColor",
                    Variant(Color(style.accent.r, style.accent.g, style.accent.b,
                        0.22 + pulse * 0.06)))
            end

            if entry.kind == "steward" then
                local sigil = effects.sigil
                if sigil then
                    sigil.position = Vector3(0, 1.92 + math.sin(t * 1.9) * 0.055, 0.24)
                    sigil.rotation = Quaternion(t * 34, Vector3.UP)
                end
                if effects.sigilRing then
                    effects.sigilRing.rotation = Quaternion(90, 0, 0)
                        * Quaternion(-t * 58, Vector3.UP)
                    local s = 0.22 * (0.94 + math.sin(t * 3.8) * 0.08)
                    effects.sigilRing.scale = Vector3(s, 0.075, s)
                end
                if effects.sigilGem then
                    local s = 0.085 * (0.88 + math.sin(t * 3.8) * 0.14)
                    effects.sigilGem.scale = Vector3(s, s, s)
                end
                local staff = entry.visual and entry.visual.accessoryParts
                    and entry.visual.accessoryParts.staff
                if staff then
                    staff.rotation = Quaternion(math.sin(t * 1.55) * 3.0, Vector3.RIGHT)
                end
            elseif entry.kind == "merchant" then
                local satchel = entry.visual and entry.visual.accessoryParts
                    and entry.visual.accessoryParts.satchel
                if satchel then
                    satchel.rotation = Quaternion(math.sin(t * 1.45) * 3.5, Vector3.FORWARD)
                end
                -- 金币位置本身已经按角度推进；轨道父节点保持静止，避免
                --“位置角度 + 父节点旋转”叠加成过快且偏心的双重轨道。
                for index, coin in ipairs(effects.coins or {}) do
                    local angle = t * 1.75 + (index - 1) * (math.pi * 2 / 3)
                    local radius = 0.40 + math.sin(t * 2.1 + index) * 0.018
                    coin.position = Vector3(
                        math.cos(angle) * radius,
                        1.14 + math.sin(t * 2.4 + index * 0.7) * 0.07,
                        0.24 + math.sin(angle) * radius * 0.38)
                    coin.rotation = Quaternion(90, 0, 0)
                        * Quaternion(-t * 90 + index * 35, Vector3.UP)
                    local coinScale = 0.095 * (0.90 + math.sin(t * 3.2 + index) * 0.10)
                    coin.scale = Vector3(coinScale, 0.028, coinScale)
                end
            elseif entry.kind == "blacksmith" then
                local hammer = entry.visual and entry.visual.accessoryParts
                    and entry.visual.accessoryParts.hammer
                if hammer then
                    hammer.rotation = Quaternion(math.sin(t * 1.8) * 4.0, Vector3.RIGHT)
                end
                if effects.sparkOrbit then
                    effects.sparkOrbit.rotation = Quaternion(math.sin(t * 0.9) * 5.0, Vector3.UP)
                end
                for index, spark in ipairs(effects.sparks or {}) do
                    local rise = (t * 0.72 + (index - 1) * 0.23) % 1.0
                    local angle = t * 2.2 + index * 1.57
                    local spread = 0.11 + rise * 0.11
                    spark.position = Vector3(
                        0.54 + math.cos(angle) * spread,
                        1.15 + rise * 0.64,
                        0.16 + math.sin(angle) * spread * 0.65)
                    local sparkScale = 0.055 * (1.0 - rise * 0.42)
                    spark.scale = Vector3(sparkScale, sparkScale * 1.35, sparkScale)
                end
            end
        end
    end
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
        if IsNodeAlive(n.node) then
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
    local level = tonumber(playerLevel)
    for mapId, def in pairs(MapZone.DEFS) do
        local requiredLevel = def.minLevel or 1
        local isCurrent = mapId == currentMapId
        local locked = not isCurrent and level ~= nil and level < requiredLevel
        table.insert(options, {
            id = mapId,
            name = def.name,
            minLevel = def.minLevel,
            maxLevel = def.maxLevel,
            cost = MapZone.GetTeleportCost(mapId),  -- 按目的地地图收取费用
            locked = locked,
            lockReason = locked and ("需要 Lv." .. requiredLevel) or nil,
            current = isCurrent,
        })
    end
    -- 按 minLevel 排序
    table.sort(options, function(a, b) return a.minLevel < b.minLevel end)
    return options
end

return NPC
