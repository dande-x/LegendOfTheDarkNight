-- ============================================================================
-- Mage.lua — 法师职业：精致木质法杖（弯曲顶端+魔法宝珠）+ 传奇法袍
-- ============================================================================
local G = require("classes.GeomUtils")

local WEAPON_SCALE = 1.16

local Mage = {}

-- ========================================================================
-- 武器挂载配置
-- 几何体以 Y=0 为握持点，下半段向 -Y 延伸，上半段向 +Y 延伸
-- offset 只需微调手掌中心对齐
-- ========================================================================
Mage.weapon = {
    name = "法杖",
    bone = "R_Hand",
    offset = Vector3(0.0, 0.02, 0.0),
    rotation = Quaternion(0, 0, 90),
    scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
}

-- 职业材质：传奇法袍（深紫色布料质感，低金属高粗糙）
Mage.material = {
    technique = "Techniques/PBR/PBRDiff.xml",
    useTexture = true,
    diffColor = Color(0.40, 0.25, 0.75, 1.0),
    roughness = 0.75,
    metallic = 0.05,
    emissive = Color(0.03, 0.01, 0.08),
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

-- ========================================================================
-- 法杖建模（以 Y=0 为握持中心）
--
-- 结构设计示意：
--        ◆ 宝珠 (Y≈0.68)
--       / (弧形弯曲段 90°)
--      |  (Y≈0.50~0.68)
--      |
--      | 上杖身 (Y=0 ~ 0.50)  - 主体直杆，微微向上收细
--   ===|=== 握持装饰环 (Y=0)  ← 手握这里
--      |
--      | 下杖身 (Y=0 ~ -0.32) - 向下微微加粗
--      |
--     ╚╝ 底端金属尖 (Y≈-0.35)
-- ========================================================================
function Mage.buildWeapon(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local seg = 12   -- 圆周段数（更圆滑）

    -- ===== 尺寸参数 =====
    local gripR     = 0.016   -- 握持处半径
    local shaftR    = 0.014   -- 杖身主体半径
    local bottomLen = 0.32    -- 下半段长度
    local topLen    = 0.50    -- 上半段直杆长度
    local bottomR   = 0.018   -- 底端半径（稍粗）

    -- ===== 1. 底端金属尖（锥台） =====
    local tipH = 0.04
    local tipBot = -bottomLen - tipH
    G.addTapered(geom, 0, tipBot + tipH/2, 0, 0.004, bottomR, tipH, seg)

    -- ===== 2. 下杖身（从底端到握持点，微微锥形收细） =====
    G.addTapered(geom, 0, -bottomLen/2, 0, bottomR, gripR, bottomLen, seg)

    -- ===== 3. 握持区域装饰（三道环纹，标识手握位置） =====
    local wrapR = gripR * 1.45
    G.addCylinder(geom, 0, -0.015, 0, wrapR, 0.012, seg)
    G.addCylinder(geom, 0,  0.0,   0, wrapR * 1.05, 0.008, seg)
    G.addCylinder(geom, 0,  0.015, 0, wrapR, 0.012, seg)

    -- ===== 4. 上杖身（从握持点向上，微微收细） =====
    G.addTapered(geom, 0, topLen/2, 0, gripR, shaftR * 0.85, topLen, seg)

    -- ===== 5. 杖身顶端过渡节（稍粗的结节，仿木头结疤） =====
    local knotY = topLen + 0.015
    G.addSphere(geom, 0, knotY, 0, shaftR * 1.5, 6, seg)

    -- ===== 6. 弯曲段（优雅的90°弧形，8段平滑） =====
    local curveSegs   = 8
    local curveArc    = math.rad(90)   -- 90度弧
    local curveR      = 0.12           -- 弧线曲率半径
    local curveStartY = knotY + 0.015
    local curveStartR = shaftR * 0.80  -- 起始端粗细
    local curveEndR   = shaftR * 0.50  -- 末端细

    local prevX, prevY = 0, curveStartY
    for i = 1, curveSegs do
        local t = i / curveSegs
        local angle = curveArc * t
        local cx = math.sin(angle) * curveR
        local cy = curveStartY + (1 - math.cos(angle)) * curveR
        -- 段的中心和长度
        local midX = (prevX + cx) / 2
        local midY = (prevY + cy) / 2
        local segLen = math.sqrt((cx - prevX)^2 + (cy - prevY)^2)
        -- 从粗到细渐变
        local rBot = curveStartR * (1 - (i-1)/curveSegs) + curveEndR * ((i-1)/curveSegs)
        local rTop = curveStartR * (1 - t) + curveEndR * t
        G.addTapered(geom, midX, midY, 0, rBot, rTop, segLen, seg)
        prevX, prevY = cx, cy
    end

    -- ===== 7. 末端宝珠（发光球体） =====
    local orbR = 0.038
    local orbX = prevX
    local orbY = prevY + orbR * 0.8
    G.addSphere(geom, orbX, orbY, 0, orbR, 8, seg)

    -- ===== 8. 宝珠底座（小型托环连接弧段和球体） =====
    G.addTapered(geom, prevX, prevY + 0.005, 0, curveEndR * 1.2, orbR * 0.7, 0.015, seg)

    geom:Commit()

    -- === 木质材质：温暖深棕，自然木头感 ===
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.38, 0.22, 0.10, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.72))
    mat:SetShaderParameter("Metallic", Variant(0.04))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.01, 0.04, 0.02)))
    geom:SetMaterial(mat)
end

return Mage
