-- ============================================================================
-- Warrior.lua — 武士职业：屠龙刀 + 大刀横扫动画
-- ============================================================================
local G = require("classes.GeomUtils")

local WEAPON_SCALE = 1.55

local Warrior = {}

-- 武士是男角色，动作必须使用独立男版动作集，不能跟女角色共用。
Warrior.animSet = "male"

-- 武器挂载配置（正手持刀：刀刃朝前，刀尖朝上）
Warrior.weapon = {
    name = "屠龙刀",
    bone = "R_Hand",
    offset = Vector3(0.0, 0.10, 0.02),
    rotation = Quaternion(90, 0, 0),
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

-- 武器构建：屠龙刀 — 传奇风格宽刃大刀，寒银刃+暗金护手+血红刀柄
function Warrior.buildWeapon(weaponNode)
    -- ========================================
    -- 刀柄（血红木+金丝缠绕）
    -- ========================================
    local handleNode = weaponNode:CreateChild("Handle")
    local handleLen  = 0.26
    local handleW    = 0.028

    local handleGeom = handleNode:CreateComponent("CustomGeometry")
    handleGeom:BeginGeometry(0, TRIANGLE_LIST)
    G.addBox(handleGeom, 0, -handleLen/2, 0, handleW/2, handleLen/2, handleW/2)
    -- 柄底金属环
    G.addBox(handleGeom, 0, -handleLen + 0.015, 0, handleW * 0.7, 0.015, handleW * 0.7)
    handleGeom:Commit()

    local handleMat = Material:new()
    handleMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    handleMat:SetShaderParameter("MatDiffColor", Variant(Color(0.45, 0.08, 0.05, 1.0)))  -- 暗血红
    handleMat:SetShaderParameter("Roughness", Variant(0.55))
    handleMat:SetShaderParameter("Metallic", Variant(0.2))
    handleMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.08, 0.01, 0.0)))
    handleGeom:SetMaterial(handleMat)

    -- ========================================
    -- 刀格/护手（暗金色，宽大厚实）
    -- ========================================
    local guardNode = weaponNode:CreateChild("Guard")
    local guardW    = 0.16
    local guardH    = 0.04
    local guardT    = 0.025

    local guardGeom = guardNode:CreateComponent("CustomGeometry")
    guardGeom:BeginGeometry(0, TRIANGLE_LIST)
    G.addBox(guardGeom, 0, 0, 0, guardW/2, guardH/2, guardT/2)
    -- 护手两端装饰突起
    G.addBox(guardGeom, -guardW/2 + 0.015, 0, 0, 0.015, guardH * 0.7, guardT * 0.6)
    G.addBox(guardGeom,  guardW/2 - 0.015, 0, 0, 0.015, guardH * 0.7, guardT * 0.6)
    guardGeom:Commit()

    local guardMat = Material:new()
    guardMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    guardMat:SetShaderParameter("MatDiffColor", Variant(Color(0.55, 0.40, 0.10, 1.0)))  -- 暗金色
    guardMat:SetShaderParameter("Roughness", Variant(0.25))
    guardMat:SetShaderParameter("Metallic", Variant(0.90))
    guardMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.12, 0.08, 0.0)))
    guardGeom:SetMaterial(guardMat)

    -- ========================================
    -- 刀身（寒银色，加宽加长，传奇质感）
    -- ========================================
    local bladeNode = weaponNode:CreateChild("Blade")
    local bladeLen  = 0.95     -- 加长刀身
    local bladeW    = 0.11     -- 加宽
    local bladeT    = 0.014
    local spineW    = 0.025
    local bladeBaseY = guardH/2

    local bladeGeom = bladeNode:CreateComponent("CustomGeometry")
    bladeGeom:BeginGeometry(0, TRIANGLE_LIST)
    -- 主刀身
    G.addBox(bladeGeom, 0, bladeBaseY + bladeLen/2, 0, bladeW/2, bladeLen/2, bladeT/2)
    -- 刀脊（厚实的背脊，增加立体感）
    G.addBox(bladeGeom, -bladeW/2 + spineW/2, bladeBaseY + bladeLen/2, 0, spineW/2, bladeLen/2, bladeT * 1.0)
    -- 刀尖（斜切三角，上宽下窄）
    local tipY = bladeBaseY + bladeLen
    local tipLen = 0.12
    G.addBox(bladeGeom, 0.015, tipY + tipLen/2, 0, bladeW * 0.28, tipLen/2, bladeT * 0.35)
    -- 刀刃血槽（中部凹痕装饰）
    G.addBox(bladeGeom, 0.01, bladeBaseY + bladeLen * 0.35, 0, bladeW * 0.15, bladeLen * 0.3, bladeT * 0.3)
    bladeGeom:Commit()

    local bladeMat = Material:new()
    bladeMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    bladeMat:SetShaderParameter("MatDiffColor", Variant(Color(0.82, 0.84, 0.88, 1.0)))  -- 寒银色
    bladeMat:SetShaderParameter("Roughness", Variant(0.10))
    bladeMat:SetShaderParameter("Metallic", Variant(0.98))
    bladeMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.06, 0.08, 0.12)))  -- 微冷光泽
    bladeGeom:SetMaterial(bladeMat)
end

return Warrior
