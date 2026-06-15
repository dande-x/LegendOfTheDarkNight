-- ============================================================================
-- Mage.lua — 法师职业：骨玉权杖 + 施法猛砸动画
-- ============================================================================
local G = require("classes.GeomUtils")

local WEAPON_SCALE = 1.16

local Mage = {}

-- 武器挂载配置（正手握持：Z轴翻转180°）
Mage.weapon = {
    name = "骨玉权杖",
    bone = "R_Hand",
    offset = Vector3(0.0, 0.10, 0.0),
    rotation = Quaternion(180, 0, -90),
    scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
}

-- 职业材质（蓝紫色调染色）
Mage.material = {
    technique = "Techniques/PBR/PBRDiff.xml",
    useTexture = true,
    diffColor = Color(0.55, 0.55, 1.3, 1.0),
    roughness = 0.35,
    metallic = 0.20,
    emissive = Color(0.02, 0.03, 0.12),
}

-- 技能动画映射（骨玉权杖：权杖施法+猛砸，华丽而有力）
Mage.skillAnims = {
    melee  = { anim = "staff_slam",  speed = 1.5, duration = 0.45 },  -- 权杖猛砸
    ranged = { anim = "cast_heavy",  speed = 1.3, duration = 0.50 },  -- 蓄力重击
    aoe    = { anim = "cast_long",   speed = 1.0, duration = 0.80 },  -- 法杖重砸(大范围)
    dash   = { anim = "dash_strike", speed = 2.0, duration = 0.30 },
    buff   = { anim = "cast_quick",  speed = 0.8, duration = 1.00 },  -- 缓慢施法
    heal   = { anim = "cast_quick",  speed = 0.7, duration = 1.10 },  -- 温和施法
    dot    = { anim = "cast_heavy",  speed = 1.5, duration = 0.45 },  -- 快速释放
    summon = { anim = "cast_long",   speed = 0.6, duration = 1.50 },  -- 长时间施法
}

-- 武器构建：骨玉权杖 — 骨质杖身 + 玉色宝珠 + 骨爪
function Mage.buildWeapon(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local staffLen  = 1.05
    local staffR    = 0.016
    local orbR      = 0.045
    local clawLen   = 0.06
    local segments  = 8

    -- 底端握柄加粗
    G.addCylinder(geom, 0, 0.06, 0, staffR * 1.4, 0.12, segments)
    -- 杖身主体
    G.addCylinder(geom, 0, staffLen * 0.5, 0, staffR, staffLen * 0.85, segments)
    -- 顶端节环
    local ringY = staffLen * 0.85
    G.addCylinder(geom, 0, ringY, 0, staffR * 1.8, 0.025, segments)
    G.addCylinder(geom, 0, ringY + 0.04, 0, staffR * 1.5, 0.02, segments)
    -- 骨爪（3根）
    local orbY = staffLen + orbR * 0.3
    for i = 0, 2 do
        local angle = (i / 3) * math.pi * 2
        local cx = math.cos(angle) * staffR * 1.2
        local cz = math.sin(angle) * staffR * 1.2
        G.addBox(geom, cx * 1.5, ringY + 0.04 + clawLen/2, cz * 1.5, 0.008, clawLen/2, 0.008)
    end
    -- 翡翠宝珠
    G.addDiamond(geom, 0, orbY, 0, orbR, orbR * 1.2, segments)

    geom:Commit()

    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.85, 0.80, 0.65, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.25))
    mat:SetShaderParameter("Metallic", Variant(0.35))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.05, 0.25, 0.12)))
    geom:SetMaterial(mat)
end

return Mage
