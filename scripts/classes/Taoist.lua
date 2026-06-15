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

    -- === 道纹装饰线（扇面中部弧线，用窄条暗色带模拟简单花纹） ===
    -- 中环弧（约60%半径处）
    local patternR = fanRadius * 0.62
    local patternW = 0.004
    for i = 0, segments - 1 do
        local a0 = startAngle + i * stepAngle
        local a1 = startAngle + (i + 1) * stepAngle
        local px0 = math.cos(a0) * patternR
        local py0 = math.sin(a0) * patternR
        local px1 = math.cos(a1) * patternR
        local py1 = math.sin(a1) * patternR
        local qx0 = math.cos(a0) * (patternR + patternW)
        local qy0 = math.sin(a0) * (patternR + patternW)
        local qx1 = math.cos(a1) * (patternR + patternW)
        local qy1 = math.sin(a1) * (patternR + patternW)
        -- 在正面略前方绘制（避免Z-fighting）
        G.addQuad(fanGeom,
            Vector3(px0, py0, fanT/2 + 0.001), Vector3(px1, py1, fanT/2 + 0.001),
            Vector3(qx1, qy1, fanT/2 + 0.001), Vector3(qx0, qy0, fanT/2 + 0.001),
            Vector3(0, 0, 1)
        )
    end

    -- 外环弧（约85%半径处）
    local outerPatR = fanRadius * 0.85
    for i = 0, segments - 1 do
        local a0 = startAngle + i * stepAngle
        local a1 = startAngle + (i + 1) * stepAngle
        local px0 = math.cos(a0) * outerPatR
        local py0 = math.sin(a0) * outerPatR
        local px1 = math.cos(a1) * outerPatR
        local py1 = math.sin(a1) * outerPatR
        local qx0 = math.cos(a0) * (outerPatR + patternW * 0.8)
        local qy0 = math.sin(a0) * (outerPatR + patternW * 0.8)
        local qx1 = math.cos(a1) * (outerPatR + patternW * 0.8)
        local qy1 = math.sin(a1) * (outerPatR + patternW * 0.8)
        G.addQuad(fanGeom,
            Vector3(px0, py0, fanT/2 + 0.001), Vector3(px1, py1, fanT/2 + 0.001),
            Vector3(qx1, qy1, fanT/2 + 0.001), Vector3(qx0, qy0, fanT/2 + 0.001),
            Vector3(0, 0, 1)
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

    local boneW = 0.005   -- 扇骨宽
    local boneT = fanT * 1.2

    -- 扇骨（每隔2段一根，共8根）
    for i = 0, segments, 2 do
        local a = startAngle + i * stepAngle
        local cosA = math.cos(a)
        local sinA = math.sin(a)
        local ix = cosA * 0.03
        local iy = sinA * 0.03
        local ox = cosA * (fanRadius - 0.01)
        local oy = sinA * (fanRadius - 0.01)
        local dx = ox - ix
        local dy = oy - iy
        local len = math.sqrt(dx*dx + dy*dy)
        local midX = (ix + ox) / 2
        local midY = (iy + oy) / 2
        G.addBox(boneGeom, midX, midY, 0, boneW/2, len/2, boneT)
    end

    -- 两侧边骨（首尾两根加粗）
    for _, idx in ipairs({0, segments}) do
        local a = startAngle + idx * stepAngle
        local cosA = math.cos(a)
        local sinA = math.sin(a)
        local ix = cosA * 0.02
        local iy = sinA * 0.02
        local ox = cosA * fanRadius
        local oy = sinA * fanRadius
        local dx = ox - ix
        local dy = oy - iy
        local len = math.sqrt(dx*dx + dy*dy)
        local midX = (ix + ox) / 2
        local midY = (iy + oy) / 2
        G.addBox(boneGeom, midX, midY, 0, boneW * 0.8, len/2, boneT * 1.5)
    end

    -- 扇面外缘弧条（连接所有扇骨顶端）
    for i = 0, segments - 1 do
        local a0 = startAngle + i * stepAngle
        local a1 = startAngle + (i + 1) * stepAngle
        local r1 = fanRadius - 0.008
        local r2 = fanRadius + 0.002
        local px0 = math.cos(a0) * r1
        local py0 = math.sin(a0) * r1
        local px1 = math.cos(a1) * r1
        local py1 = math.sin(a1) * r1
        local qx0 = math.cos(a0) * r2
        local qy0 = math.sin(a0) * r2
        local qx1 = math.cos(a1) * r2
        local qy1 = math.sin(a1) * r2
        G.addQuad(boneGeom,
            Vector3(px0, py0, 0), Vector3(px1, py1, 0),
            Vector3(qx1, qy1, 0), Vector3(qx0, qy0, 0),
            Vector3(0, 0, 1)
        )
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
