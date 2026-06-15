-- ============================================================================
-- Mage.lua — 法师职业：大型木质法杖（顶部白光大宝珠）+ 传奇法袍
-- ============================================================================
local G = require("classes.GeomUtils")

local WEAPON_SCALE = 1.16

local Mage = {}

-- ========================================================================
-- 武器挂载配置
-- 几何体以 Y=0 为握持点（掌心位置）
-- offset 向手指方向微移，使杖身从掌心穿过而非手掌根部
-- ========================================================================
Mage.weapon = {
    name = "法杖",
    bone = "R_Hand",
    offset = Vector3(0.0, 0.06, 0.0),
    rotation = Quaternion(0, 0, 90),
    scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
}

-- 法师使用独立模型 prefab（布甲法袍+火红边饰）
Mage.prefab = "Prefabs/MageRobe.prefab"

-- 职业材质：使用模型自带贴图，不覆盖
Mage.material = {
    technique = "Techniques/PBR/PBRDiff.xml",
    useTexture = false,
    diffColor = Color(1.0, 1.0, 1.0, 1.0),
    roughness = 0.70,
    metallic = 0.0,
    emissive = Color(0.0, 0.0, 0.0),
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
-- 法杖建模（以 Y=0 为掌心握持中心）
--
-- 结构示意（更大尺寸，无弯曲，直杆顶宝珠）：
--
--        ★ 白光大宝珠 (Y≈0.78)     ← 发强白光
--       [爪形托座] (Y≈0.72)
--        |
--        | 上杖身 (Y=0 ~ 0.70)     ← 直杆，向上渐细
--    ====|==== 握持装饰区 (Y=0)     ← 掌心握这里
--        |
--        | 下杖身 (Y=0 ~ -0.40)    ← 向下微粗
--        |
--       ╚╝ 底端铁尖 (Y≈-0.44)
--
-- 总长约 1.22m，比之前大一号
-- ========================================================================
function Mage.buildWeapon(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local seg = 12   -- 圆周段数

    -- ===== 尺寸参数（加大） =====
    local gripR     = 0.020   -- 握持处半径
    local shaftR    = 0.017   -- 杖身主体半径
    local bottomLen = 0.40    -- 下半段长度
    local topLen    = 0.68    -- 上半段直杆长度
    local bottomR   = 0.022   -- 底端半径

    -- ===== 1. 底端铁尖（锥形） =====
    local tipH = 0.05
    G.addTapered(geom, 0, -bottomLen - tipH/2, 0, 0.005, bottomR, tipH, seg)

    -- ===== 2. 下杖身（底端到握持点，向上渐细） =====
    G.addTapered(geom, 0, -bottomLen/2, 0, bottomR, gripR, bottomLen, seg)

    -- ===== 3. 握持装饰区（皮革缠绕感 — 多道环纹） =====
    local wR = gripR * 1.4
    G.addCylinder(geom, 0, -0.020, 0, wR, 0.010, seg)
    G.addCylinder(geom, 0, -0.008, 0, wR * 1.05, 0.008, seg)
    G.addCylinder(geom, 0,  0.004, 0, wR * 1.08, 0.008, seg)
    G.addCylinder(geom, 0,  0.016, 0, wR * 1.05, 0.008, seg)
    G.addCylinder(geom, 0,  0.028, 0, wR, 0.010, seg)

    -- ===== 4. 上杖身（握持点向上，直杆渐细） =====
    G.addTapered(geom, 0, topLen / 2, 0, gripR, shaftR * 0.80, topLen, seg)

    -- ===== 5. 杖顶木结节（过渡到宝珠托座） =====
    local topY = topLen + 0.01
    G.addSphere(geom, 0, topY, 0, shaftR * 1.6, 6, seg)

    -- ===== 6. 宝珠托座（4爪形支撑，环抱宝珠底部） =====
    local seatY = topY + 0.02
    local seatR = shaftR * 1.2
    -- 中心柱连接
    G.addCylinder(geom, 0, seatY + 0.015, 0, seatR * 0.8, 0.03, seg)
    -- 4个爪（用小圆柱模拟，向外倾斜）
    local orbR = 0.065  -- 大宝珠半径
    local clawLen = 0.04
    for c = 0, 3 do
        local angle = (c / 4) * math.pi * 2
        local dx = math.cos(angle) * orbR * 0.5
        local dz = math.sin(angle) * orbR * 0.5
        local clawY = seatY + 0.035
        G.addCylinder(geom, dx, clawY, dz, 0.006, clawLen, 8)
    end

    -- ===== 7. 顶部大宝珠（白光发光球体） =====
    local orbY = seatY + 0.045 + orbR
    G.addSphere(geom, 0, orbY, 0, orbR, 10, seg)

    geom:Commit()

    -- === 材质：木质杖身 + 宝珠白光（统一材质，用 emissive 模拟发光） ===
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.40, 0.24, 0.12, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.68))
    mat:SetShaderParameter("Metallic", Variant(0.05))
    -- 白色发光（宝珠整体泛白光）
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.85, 1.0)))
    geom:SetMaterial(mat)
end

return Mage
