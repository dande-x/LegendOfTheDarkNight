-- ============================================================================
-- Warrior.lua — 武士职业：屠龙刀 + 大刀横扫动画
-- ============================================================================
local G = require("classes.GeomUtils")

local WEAPON_SCALE = 1.16

local Warrior = {}

-- 武器挂载配置
Warrior.weapon = {
    name = "屠龙刀",
    bone = "R_Hand",
    offset = Vector3(0.0, 0.10, 0.02),
    rotation = Quaternion(0, 0, -90),
    scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
}

-- 职业材质（保留原始铠甲贴图，增加金属质感）
Warrior.material = {
    technique = "Techniques/PBR/PBRDiff.xml",
    useTexture = true,
    diffColor = Color(1.0, 0.95, 0.9, 1.0),
    roughness = 0.28,
    metallic = 0.75,
    emissive = Color(0.02, 0.01, 0.0),
}

-- 技能动画映射（屠龙刀：大刀横扫为主，大范围霸道攻击）
Warrior.skillAnims = {
    melee  = { anim = "sweep_l",     speed = 1.6, duration = 0.45 },  -- 横扫千军(右→左)
    ranged = { anim = "sweep_r",     speed = 1.4, duration = 0.50 },  -- 横扫千军(左→右)
    aoe    = { anim = "spin_strike", speed = 1.0, duration = 0.85 },  -- 回旋劈击(大范围)
    dash   = { anim = "dash_strike", speed = 2.0, duration = 0.30 },  -- 突刺重击
    buff   = { anim = "melee_heavy", speed = 1.2, duration = 0.55 },  -- 斜劈蓄力
    heal   = { anim = "cast_long",   speed = 1.2, duration = 0.80 },
    dot    = { anim = "sweep_l",     speed = 1.8, duration = 0.38 },  -- 快速横扫
    summon = { anim = "spin_strike", speed = 0.7, duration = 1.30 },  -- 慢速回旋蓄力
}

-- 武器构建：屠龙刀 — 宽刃单刀，金柄红缨，霸气侧漏
function Warrior.buildWeapon(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local bladeLen   = 0.75
    local bladeW     = 0.08
    local bladeT     = 0.012
    local handleLen  = 0.20
    local handleW    = 0.025
    local guardW     = 0.12
    local guardT     = 0.02
    local guardH     = 0.03
    local spineW     = 0.02

    -- 刀柄
    G.addBox(geom, 0, -handleLen/2, 0, handleW/2, handleLen/2, handleW/2)
    -- 刀格
    G.addBox(geom, 0, 0, 0, guardW/2, guardH/2, guardT/2)
    -- 刀身主体
    local bladeBaseY = guardH/2
    G.addBox(geom, 0, bladeBaseY + bladeLen/2, 0, bladeW/2, bladeLen/2, bladeT/2)
    -- 刀脊
    G.addBox(geom, -bladeW/2 + spineW/2, bladeBaseY + bladeLen/2, 0, spineW/2, bladeLen/2, bladeT * 0.8)
    -- 刀尖
    local tipY = bladeBaseY + bladeLen
    local tipLen = 0.08
    G.addBox(geom, 0.01, tipY + tipLen/2, 0, bladeW * 0.3, tipLen/2, bladeT * 0.4)

    geom:Commit()

    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.75, 0.55, 0.15, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.15))
    mat:SetShaderParameter("Metallic", Variant(0.95))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.20, 0.05, 0.02)))
    geom:SetMaterial(mat)
end

return Warrior
