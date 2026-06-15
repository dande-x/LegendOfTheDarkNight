-- ============================================================================
-- Taoist.lua — 道士职业：逍遥扇（白色+道纹）+ 传奇道袍
-- ============================================================================
local G = require("classes.GeomUtils")

local WEAPON_SCALE = 1.16

local Taoist = {}

-- ========================================================================
-- 武器挂载配置（掌心握持）
-- ========================================================================
Taoist.weapon = {
    name = "逍遥扇",
    bone = "R_Hand",
    offset = Vector3(0.0, 0.06, 0.0),
    rotation = Quaternion(0, 0, 90),
    scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
}

-- 职业材质：传奇道袍（淡青白色布料，低金属高粗糙，仙风道骨）
Taoist.material = {
    technique = "Techniques/PBR/PBRDiff.xml",
    useTexture = true,
    diffColor = Color(0.85, 0.95, 0.80, 1.0),   -- 淡青白色道袍
    roughness = 0.72,                             -- 布料质感
    metallic = 0.05,                              -- 无金属光泽
    emissive = Color(0.02, 0.04, 0.02),           -- 微弱灵气
}

-- 技能动画映射
Taoist.skillAnims = {
    melee  = { anim = "cast_quick",  speed = 1.8, duration = 0.38 },
    ranged = { anim = "melee_fast",  speed = 1.5, duration = 0.40 },
    aoe    = { anim = "cast_long",   speed = 1.0, duration = 0.80 },
    dash   = { anim = "dash_strike", speed = 1.8, duration = 0.35 },
    buff   = { anim = "cast_quick",  speed = 0.9, duration = 0.90 },
    heal   = { anim = "cast_long",   speed = 0.7, duration = 1.20 },
    dot    = { anim = "cast_quick",  speed = 1.5, duration = 0.45 },
    summon = { anim = "cast_long",   speed = 0.6, duration = 1.80 },
}

-- ========================================================================
-- 逍遥扇建模（白色扇面 + 深色扇骨 + 道纹装饰线）
--
-- 结构示意：
--          ╭─────╮
--        ╱ 白色扇面  ╲      ← 14段扇面，更圆滑
--       ╱  (道纹暗花)  ╲
--      ╱________________╲
--           ||  ||          ← 握柄（深木+金属环）
--           ||  ||
--            ╘╛             ← 柄尾坠饰
-- ========================================================================
function Taoist.buildWeapon(weaponNode)
    -- 使用两个子节点，分别赋不同材质：扇面白色、扇骨深色
    local fanNode = weaponNode:CreateChild("FanSurface")
    local boneNode = weaponNode:CreateChild("FanBones")

    -- =============== 扇面（白色主体） ===============
    local fanGeom = fanNode:CreateComponent("CustomGeometry")
    fanGeom:BeginGeometry(0, TRIANGLE_LIST)

    local fanRadius = 0.38         -- 扇面半径（稍大）
    local fanAngle  = 125          -- 展开角度
    local fanT      = 0.003        -- 扇面厚度
    local segments  = 14           -- 扇面分段（更圆滑）
    local innerR    = 0.05         -- 内圈起始

    local startAngle = math.rad(-fanAngle / 2 + 90)
    local endAngle   = math.rad(fanAngle / 2 + 90)
    local stepAngle  = (endAngle - startAngle) / segments

    for i = 0, segments - 1 do
        local a0 = startAngle + i * stepAngle
        local a1 = startAngle + (i + 1) * stepAngle

        local ix0 = math.cos(a0) * innerR
        local iy0 = math.sin(a0) * innerR
        local ix1 = math.cos(a1) * innerR
        local iy1 = math.sin(a1) * innerR
        local ox0 = math.cos(a0) * fanRadius
        local oy0 = math.sin(a0) * fanRadius
        local ox1 = math.cos(a1) * fanRadius
        local oy1 = math.sin(a1) * fanRadius

        -- 正面
        G.addQuad(fanGeom,
            Vector3(ix0, iy0, fanT/2), Vector3(ix1, iy1, fanT/2),
            Vector3(ox1, oy1, fanT/2), Vector3(ox0, oy0, fanT/2),
            Vector3(0, 0, 1)
        )
        -- 背面
        G.addQuad(fanGeom,
            Vector3(ix1, iy1, -fanT/2), Vector3(ix0, iy0, -fanT/2),
            Vector3(ox0, oy0, -fanT/2), Vector3(ox1, oy1, -fanT/2),
            Vector3(0, 0, -1)
        )
    end

    fanGeom:Commit()

    -- 扇面材质：白色丝绸质感，微微泛暖
    local fanMat = Material:new()
    fanMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    fanMat:SetShaderParameter("MatDiffColor", Variant(Color(0.95, 0.93, 0.88, 1.0)))  -- 温暖象牙白
    fanMat:SetShaderParameter("Roughness", Variant(0.55))   -- 丝绸般光泽
    fanMat:SetShaderParameter("Metallic", Variant(0.02))
    fanMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.03, 0.03, 0.02)))
    fanGeom:SetMaterial(fanMat)

    -- =============== 扇骨 + 握柄（深色檀木+金属） ===============
    local boneGeom = boneNode:CreateComponent("CustomGeometry")
    boneGeom:BeginGeometry(0, TRIANGLE_LIST)

    local boneW = 0.005   -- 扇骨宽度（沿切线方向的半宽）
    local boneT = fanT * 1.3

    -- 扇骨（每隔2段一根）— 用 Quad 沿径向正确放置
    for i = 0, segments, 2 do
        local a = startAngle + i * stepAngle
        local cosA = math.cos(a)
        local sinA = math.sin(a)
        -- 内端和外端（严格在扇面范围内）
        local rInner = innerR + 0.01
        local rOuter = fanRadius - 0.015
        -- 径向方向的两侧偏移（垂直于径向，即切线方向）
        local perpX = -sinA * boneW
        local perpY = cosA * boneW
        -- 4个顶点：内左、内右、外右、外左
        local p1 = Vector3(cosA * rInner - perpX, sinA * rInner - perpY, 0)
        local p2 = Vector3(cosA * rInner + perpX, sinA * rInner + perpY, 0)
        local p3 = Vector3(cosA * rOuter + perpX, sinA * rOuter + perpY, 0)
        local p4 = Vector3(cosA * rOuter - perpX, sinA * rOuter - perpY, 0)
        G.addQuad(boneGeom, p1, p2, p3, p4, Vector3(0, 0, 1))
        -- 背面
        G.addQuad(boneGeom, p2, p1, p4, p3, Vector3(0, 0, -1))
    end

    -- 两侧边骨（首尾加粗，同样沿径向）
    for _, idx in ipairs({0, segments}) do
        local a = startAngle + idx * stepAngle
        local cosA = math.cos(a)
        local sinA = math.sin(a)
        local rInner = 0.02
        local rOuter = fanRadius - 0.005
        local edgeW = boneW * 1.5
        local perpX = -sinA * edgeW
        local perpY = cosA * edgeW
        local p1 = Vector3(cosA * rInner - perpX, sinA * rInner - perpY, 0)
        local p2 = Vector3(cosA * rInner + perpX, sinA * rInner + perpY, 0)
        local p3 = Vector3(cosA * rOuter + perpX, sinA * rOuter + perpY, 0)
        local p4 = Vector3(cosA * rOuter - perpX, sinA * rOuter - perpY, 0)
        G.addQuad(boneGeom, p1, p2, p3, p4, Vector3(0, 0, 1))
        G.addQuad(boneGeom, p2, p1, p4, p3, Vector3(0, 0, -1))
    end

    -- === 握柄（深色木质） ===
    local handleLen = 0.14
    local handleR   = 0.012
    -- 主柄身
    G.addCylinder(boneGeom, 0, -handleLen/2, 0, handleR, handleLen, 10)
    -- 上金属环（扇面与柄连接处）
    G.addCylinder(boneGeom, 0, 0.005, 0, handleR * 1.5, 0.012, 10)
    -- 下金属环
    G.addCylinder(boneGeom, 0, -handleLen + 0.005, 0, handleR * 1.4, 0.010, 10)
    -- 柄尾坠（小球）
    G.addSphere(boneGeom, 0, -handleLen - 0.015, 0, 0.010, 6, 10)

    boneGeom:Commit()

    -- 扇骨材质：深檀木色 + 微金属光泽（金属环）
    local boneMat = Material:new()
    boneMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    boneMat:SetShaderParameter("MatDiffColor", Variant(Color(0.18, 0.10, 0.05, 1.0)))  -- 深檀木
    boneMat:SetShaderParameter("Roughness", Variant(0.45))
    boneMat:SetShaderParameter("Metallic", Variant(0.20))   -- 带点金属感（环和边框）
    boneMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.01, 0.01, 0.0)))
    boneGeom:SetMaterial(boneMat)
end

return Taoist
