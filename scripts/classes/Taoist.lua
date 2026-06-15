-- ============================================================================
-- Taoist.lua — 道士职业：逍遥扇 + 轻灵飘逸动画
-- ============================================================================
local G = require("classes.GeomUtils")

local WEAPON_SCALE = 1.16

local Taoist = {}

-- 武器挂载配置（正手握持：Z轴翻转180°）
Taoist.weapon = {
    name = "逍遥扇",
    bone = "R_Hand",
    offset = Vector3(0.0, 0.06, 0.0),
    rotation = Quaternion(0, 0, 90),
    scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
}

-- 职业材质（翠绿色调染色）
Taoist.material = {
    technique = "Techniques/PBR/PBRDiff.xml",
    useTexture = true,
    diffColor = Color(0.6, 1.2, 0.6, 1.0),
    roughness = 0.32,
    metallic = 0.25,
    emissive = Color(0.02, 0.06, 0.03),
}

-- 技能动画映射（逍遥扇：轻灵扇击+施法辅助，动作飘逸）
Taoist.skillAnims = {
    melee  = { anim = "cast_quick",  speed = 1.8, duration = 0.38 },  -- 快速扇击(轻拍)
    ranged = { anim = "melee_fast",  speed = 1.5, duration = 0.40 },  -- 扇指前推
    aoe    = { anim = "cast_long",   speed = 1.0, duration = 0.80 },  -- 展扇大范围
    dash   = { anim = "dash_strike", speed = 1.8, duration = 0.35 },
    buff   = { anim = "cast_quick",  speed = 0.9, duration = 0.90 },  -- 轻摇扇面
    heal   = { anim = "cast_long",   speed = 0.7, duration = 1.20 },  -- 缓慢疗愈
    dot    = { anim = "cast_quick",  speed = 1.5, duration = 0.45 },  -- 连续扇击
    summon = { anim = "cast_long",   speed = 0.6, duration = 1.80 },  -- 召唤仪式
}

-- 武器构建：逍遥扇 — 展开折扇，翠绿扇面 + 金骨
function Taoist.buildWeapon(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local handleLen = 0.12
    local handleW   = 0.015
    local fanRadius = 0.35
    local fanAngle  = 120
    local fanT      = 0.004
    local segments  = 10
    local boneW     = 0.006

    -- 握柄
    G.addBox(geom, 0, -handleLen/2, 0, handleW/2, handleLen/2, handleW * 0.6)

    -- 扇面
    local startAngle = math.rad(-fanAngle / 2 + 90)
    local endAngle   = math.rad(fanAngle / 2 + 90)
    local stepAngle  = (endAngle - startAngle) / segments

    for i = 0, segments - 1 do
        local a0 = startAngle + i * stepAngle
        local a1 = startAngle + (i + 1) * stepAngle
        local innerR = 0.05
        local outerR = fanRadius

        local ix0 = math.cos(a0) * innerR
        local iy0 = math.sin(a0) * innerR
        local ix1 = math.cos(a1) * innerR
        local iy1 = math.sin(a1) * innerR
        local ox0 = math.cos(a0) * outerR
        local oy0 = math.sin(a0) * outerR
        local ox1 = math.cos(a1) * outerR
        local oy1 = math.sin(a1) * outerR

        -- 前面
        G.addQuad(geom,
            Vector3(ix0, iy0, fanT/2), Vector3(ix1, iy1, fanT/2),
            Vector3(ox1, oy1, fanT/2), Vector3(ox0, oy0, fanT/2),
            Vector3(0, 0, 1)
        )
        -- 背面
        G.addQuad(geom,
            Vector3(ix1, iy1, -fanT/2), Vector3(ix0, iy0, -fanT/2),
            Vector3(ox0, oy0, -fanT/2), Vector3(ox1, oy1, -fanT/2),
            Vector3(0, 0, -1)
        )
    end

    -- 扇骨
    for i = 0, segments, 2 do
        local a = startAngle + i * stepAngle
        local ox = math.cos(a) * fanRadius
        local oy = math.sin(a) * fanRadius
        local ix = math.cos(a) * 0.03
        local iy = math.sin(a) * 0.03
        local dx = ox - ix
        local dy = oy - iy
        local len = math.sqrt(dx*dx + dy*dy)
        local midX = (ix + ox) / 2
        local midY = (iy + oy) / 2
        G.addBox(geom, midX, midY, 0, boneW/2, len/2, fanT * 0.8)
    end

    geom:Commit()

    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.20, 0.65, 0.35, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.40))
    mat:SetShaderParameter("Metallic", Variant(0.30))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.05, 0.12, 0.06)))
    geom:SetMaterial(mat)
end

return Taoist
