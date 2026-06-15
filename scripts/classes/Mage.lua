-- ============================================================================
-- Mage.lua — 法师职业：木质法杖（弯曲顶端+宝珠）+ 传奇法袍
-- ============================================================================
local G = require("classes.GeomUtils")

local WEAPON_SCALE = 1.16

local Mage = {}

-- 武器挂载配置（手握杖身中间位置）
Mage.weapon = {
    name = "法杖",
    bone = "R_Hand",
    offset = Vector3(0.0, -0.38, 0.0),   -- 向下偏移，使手握在杖身中段
    rotation = Quaternion(0, 0, 90),
    scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
}

-- 职业材质：传奇法袍（深紫色布料质感，低金属高粗糙）
Mage.material = {
    technique = "Techniques/PBR/PBRDiff.xml",
    useTexture = true,
    diffColor = Color(0.40, 0.25, 0.75, 1.0),   -- 深紫色法袍
    roughness = 0.75,                             -- 布料质感（高粗糙度）
    metallic = 0.05,                              -- 几乎无金属光泽
    emissive = Color(0.03, 0.01, 0.08),           -- 微弱紫色魔力光泽
}

-- 技能动画映射
Mage.skillAnims = {
    melee  = { anim = "staff_slam",  speed = 1.5, duration = 0.45 },
    ranged = { anim = "cast_heavy",  speed = 1.3, duration = 0.50 },
    aoe    = { anim = "cast_long",   speed = 1.0, duration = 0.80 },
    dash   = { anim = "dash_strike", speed = 2.0, duration = 0.30 },
    buff   = { anim = "cast_quick",  speed = 0.8, duration = 1.00 },
    heal   = { anim = "cast_quick",  speed = 0.7, duration = 1.10 },
    dot    = { anim = "cast_heavy",  speed = 1.5, duration = 0.45 },
    summon = { anim = "cast_long",   speed = 0.6, duration = 1.50 },
}

-- 武器构建：木质法杖 — 深棕木杖身 + 顶部弯曲 + 发光宝珠
function Mage.buildWeapon(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local staffLen  = 1.10     -- 杖身总长
    local staffR    = 0.018    -- 杖身半径
    local segments  = 8
    local orbR      = 0.04     -- 顶部宝珠半径

    -- ===== 底端：略粗的根部（树根感） =====
    G.addCylinder(geom, 0, 0.04, 0, staffR * 1.6, 0.08, segments)

    -- ===== 主杖身：从底到弯曲起点 =====
    local straightLen = staffLen * 0.78   -- 直线段长度
    G.addCylinder(geom, 0, 0.08 + straightLen / 2, 0, staffR, straightLen, segments)

    -- ===== 顶端弯曲段：用多段偏移圆柱模拟弧形弯曲 =====
    local curveSegments = 5
    local curveStartY = 0.08 + straightLen
    local curveRadius = 0.15   -- 弯曲弧度半径
    local curveAngleTotal = math.rad(120)  -- 总弯曲角度

    local prevX, prevY = 0, curveStartY
    for i = 1, curveSegments do
        local t = i / curveSegments
        local angle = curveAngleTotal * t
        -- 弧线：从垂直向前方弯曲
        local cx = math.sin(angle) * curveRadius
        local cy = curveStartY + (1 - math.cos(angle)) * curveRadius
        local segH = math.sqrt((cx - prevX)^2 + (cy - prevY)^2)
        local midX = (prevX + cx) / 2
        local midY = (prevY + cy) / 2
        -- 逐渐变细
        local r = staffR * (1.0 - t * 0.35)
        G.addCylinder(geom, midX, midY, 0, r, segH, segments)
        prevX, prevY = cx, cy
    end

    -- ===== 弯曲末端的宝珠 =====
    local orbX = prevX
    local orbY = prevY + orbR * 0.5
    G.addDiamond(geom, orbX, orbY, 0, orbR, orbR * 1.3, segments)

    -- ===== 杖身中段装饰环（握持位置标记） =====
    local gripY = 0.08 + straightLen * 0.45
    G.addCylinder(geom, 0, gripY, 0, staffR * 1.5, 0.02, segments)
    G.addCylinder(geom, 0, gripY + 0.035, 0, staffR * 1.3, 0.015, segments)

    geom:Commit()

    -- 木质材质：深棕色，粗糙，无金属感
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.35, 0.20, 0.08, 1.0)))  -- 深棕木色
    mat:SetShaderParameter("Roughness", Variant(0.70))    -- 木头粗糙
    mat:SetShaderParameter("Metallic", Variant(0.05))     -- 几乎无金属
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.02, 0.08, 0.04)))  -- 微弱绿光（宝珠映射）
    geom:SetMaterial(mat)
end

return Mage
