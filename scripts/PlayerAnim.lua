---@diagnostic disable: assign-type-mismatch
-- ============================================================================
-- PlayerAnim.lua — 传奇风格3D角色动画系统
-- 使用 LegendWarrior 模型（Tripo Rig 骨骼）+ 资源库 UUID 动画
-- ============================================================================

local PlayerAnim = {}

-- ============================================================================
-- 状态管理
-- ============================================================================
local animState = {
    current = "idle",     -- 当前动画key
    elapsed = 0,
    duration = 0,
    speed = 1.0,          -- 当前播放速度（用于顿帧恢复）
    onComplete = nil,
}

-- 打击感系统
local hitFeedback = {
    screenShake = 0,
    shakeIntensity = 0,
    hitPause = 0,
    flashTimer = 0,
}

local currentClassId = "warrior"

---@type Node
local modelNode_ = nil
---@type AnimationController
local animCtrl_ = nil
---@type AnimatedModel
local animModel_ = nil
---@type Node
local playerNode_ = nil  -- 引用玩家节点，用于每帧同步位置

local baseScale_ = 1.0        -- CreateSkeleton 中计算的基础 scale 值
local baseFootOffset_ = 0.0   -- CreateSkeleton 中计算的脚底偏移
local TARGET_HEIGHT_ = 1.6    -- 目标角色高度（米）

PlayerAnim.animState = animState
PlayerAnim.hitFeedback = hitFeedback

-- ============================================================================
-- 角色预制体和动画资源 UUID
-- ============================================================================
-- LegendWarrior: Tripo Rig 骨骼（Root→Hip→Pelvis→L/R limbs），无 0.01 缩放问题
local CHARACTER_PREFAB = "Prefabs/LegendWarrior.prefab"

-- 全部使用资源库 UUID 动画（标准男骨架，引擎自动重定向到 Tripo Rig）
local ANIM_PATHS = {
    -- 基础移动
    idle       = "uuid://GikiEX04hbY9D5ALGNz051Zh",  -- 枪骑士战斗待机 1.33s loop
    move       = "uuid://F-afGUmbZwlJu4crZmqR_4kR",  -- 枪骑士中速推进跑 1.0s loop
    walk       = "uuid://F-afGUmbZwlJu4crZmqR_4kR",  -- 同 move
    charge     = "uuid://CTyqSX1Y6TCSZnO1QexmJKeY",  -- 枪骑士高速冲刺 0.53s loop
    -- 战斗待机
    combat_idle = "uuid://GikiEX04hbY9D5ALGNz051Zh",  -- 同 idle（战斗待机）
    -- 近战攻击 — 杨戬(标准男): 突刺穿心(快)、斜劈重斩(重)
    melee_fast  = "uuid://Ai-SCaONHGJAnRCLZmoO2QJ8",  -- 杨戬 attack_01 突刺穿心 1.07s
    melee_heavy = "uuid://HFCMaTM1TqMyp12CL-treYHh",  -- 杨戬 attack_02 斜劈重斩 1.07s
    -- 施法攻击 — 魔法导师(标准男): 挥击(快)、法杖重砸(长)
    cast_quick  = "uuid://E3rZmUDaM9pq2-V2gj3pCyW4",  -- 魔法导师 attack_01 挥击 1.5s
    cast_long   = "uuid://Hs3_meWUZg22cD1e_0d-BCO6",  -- 魔法导师 skill_01 法杖重砸 1.5s
    -- 冲锋突刺 — 杨戬(标准男): 突刺重击
    dash_strike = "uuid://C1NO-SdM51lg1PCrBmXoiUWO",  -- 杨戬 attack_03 突刺重击 1.33s
    -- 技能
    skill_01    = "uuid://EUvBwU0-VB_KCvzQldvwX1gF",  -- 杨戬重劈起手 1.07s
    -- 跳跃（复用 idle 动画过渡）
    jump_start  = "uuid://GikiEX04hbY9D5ALGNz051Zh",
    jump_air    = "uuid://GikiEX04hbY9D5ALGNz051Zh",
    jump_land   = "uuid://GikiEX04hbY9D5ALGNz051Zh",
    -- 死亡（暂用技能动画代替）
    die         = "uuid://EUvBwU0-VB_KCvzQldvwX1gF",
}

-- 技能动画映射：根据技能类型和职业返回 {animKey, speed, duration}
local SKILL_ANIM_MAP = {
    -- 武士：近战为主，快速挥砍
    warrior = {
        melee  = { anim = "melee_fast",  speed = 1.8, duration = 0.35 },
        ranged = { anim = "melee_fast",  speed = 1.2, duration = 0.50 },
        aoe    = { anim = "melee_heavy", speed = 0.8, duration = 0.70 },
        dash   = { anim = "dash_strike", speed = 2.0, duration = 0.30 },
        buff   = { anim = "cast_long",   speed = 1.5, duration = 0.60 },
        heal   = { anim = "cast_long",   speed = 1.2, duration = 0.80 },
        dot    = { anim = "melee_fast",  speed = 1.5, duration = 0.40 },
        summon = { anim = "cast_long",   speed = 1.0, duration = 1.20 },
    },
    -- 法师：远程施法为主，较慢但华丽
    mage = {
        melee  = { anim = "melee_fast",  speed = 1.5, duration = 0.40 },
        ranged = { anim = "cast_quick",  speed = 1.4, duration = 0.45 },
        aoe    = { anim = "cast_long",   speed = 1.0, duration = 0.80 },
        dash   = { anim = "dash_strike", speed = 2.0, duration = 0.30 },
        buff   = { anim = "cast_long",   speed = 0.8, duration = 1.00 },
        heal   = { anim = "cast_long",   speed = 0.8, duration = 1.00 },
        dot    = { anim = "cast_quick",  speed = 1.2, duration = 0.55 },
        summon = { anim = "cast_long",   speed = 0.7, duration = 1.50 },
    },
    -- 道士：辅助/召唤为主，动作平缓
    taoist = {
        melee  = { anim = "melee_fast",  speed = 1.3, duration = 0.45 },
        ranged = { anim = "cast_quick",  speed = 1.5, duration = 0.40 },
        aoe    = { anim = "cast_long",   speed = 1.0, duration = 0.80 },
        dash   = { anim = "dash_strike", speed = 1.8, duration = 0.35 },
        buff   = { anim = "cast_long",   speed = 0.9, duration = 1.00 },
        heal   = { anim = "cast_long",   speed = 0.7, duration = 1.20 },
        dot    = { anim = "cast_quick",  speed = 1.3, duration = 0.50 },
        summon = { anim = "cast_long",   speed = 0.6, duration = 1.80 },
    },
}

-- 动画时长（基础时长，与资源库动画实际时长对齐；技能使用时由 SKILL_ANIM_MAP 覆盖）
local ANIM_DURATIONS = {
    idle        = 1.33,
    walk        = 1.0,
    move        = 1.0,
    charge      = 0.53,
    jump_start  = 0.3,
    jump_air    = 1.0,
    jump_land   = 0.5,
    combat_idle = 1.33,
    melee_fast  = 1.07,
    melee_heavy = 1.07,
    cast_quick  = 1.5,
    cast_long   = 1.5,
    dash_strike = 1.33,
    skill_01    = 1.07,
    die         = 1.07,
}

-- 动画是否循环
local ANIM_LOOPING = {
    idle  = true,
    walk  = true,
    move  = true,
    charge = true,
    combat_idle = true,
}

-- ============================================================================
-- 职业外观材质（武士保留原贴图铠甲，法师/道士染色覆盖）
-- ============================================================================

-- 原始贴图 UUID（导入时生成的漫反射贴图）
local ORIGINAL_TEXTURE_UUID = "uuid://ARGvkYnzrbbOxkjh2N68upmG"

-- 职业材质配置
-- 所有职业都使用原始贴图（贴图中皮肤和服装已经分开绘制）
-- 通过 MatDiffColor 乘法染色来改变服装色调，皮肤区域因为贴图本身是肤色所以会保持自然
local CLASS_MATERIAL_CONFIG = {
    -- 武士：保留原始铠甲贴图，增加金属质感
    warrior = {
        technique = "Techniques/PBR/PBRDiff.xml",
        texture = ORIGINAL_TEXTURE_UUID,
        diffColor = Color(1.0, 0.95, 0.9, 1.0),   -- 原色，略微暖色调
        roughness = 0.28,
        metallic = 0.75,
        emissive = Color(0.02, 0.01, 0.0),
    },
    -- 法师：原始贴图 + 蓝紫色调染色
    mage = {
        technique = "Techniques/PBR/PBRDiff.xml",
        texture = ORIGINAL_TEXTURE_UUID,
        diffColor = Color(0.55, 0.55, 1.3, 1.0),  -- 蓝紫色调（乘法：压暖色提蓝色）
        roughness = 0.35,
        metallic = 0.20,
        emissive = Color(0.02, 0.03, 0.12),        -- 淡蓝色能量发光
    },
    -- 道士：原始贴图 + 翠绿色调染色
    taoist = {
        technique = "Techniques/PBR/PBRDiff.xml",
        texture = ORIGINAL_TEXTURE_UUID,
        diffColor = Color(0.6, 1.2, 0.6, 1.0),    -- 绿色调（乘法：压红蓝提绿色）
        roughness = 0.32,
        metallic = 0.25,
        emissive = Color(0.02, 0.06, 0.03),        -- 淡绿色灵力光泽
    },
}

--- 应用职业材质到角色模型
local function ApplyClassMaterial(classId)
    if not animModel_ then return end

    local config = CLASS_MATERIAL_CONFIG[classId]
    if not config then
        config = CLASS_MATERIAL_CONFIG.warrior
    end

    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", config.technique))

    -- 设置贴图（武士有贴图，法师/道士纯色）
    if config.texture then
        mat:SetTexture(TU_DIFFUSE, cache:GetResource("Texture2D", config.texture))
    end

    mat:SetShaderParameter("MatDiffColor", Variant(config.diffColor))
    mat:SetShaderParameter("Roughness", Variant(config.roughness))
    mat:SetShaderParameter("Metallic", Variant(config.metallic))
    mat:SetShaderParameter("MatEmissiveColor", Variant(config.emissive))

    -- 应用到所有材质槽位
    local numGeom = animModel_:GetNumGeometries()
    for i = 0, numGeom - 1 do
        animModel_:SetMaterial(i, mat)
    end

    print(string.format("[PlayerAnim] Class material applied: %s (technique=%s)", classId, config.technique))
end

-- ============================================================================
-- 武器系统：程序化生成并挂载到骨骼
-- ============================================================================
---@type Node
local weaponNode_ = nil

-- 武器配置（各职业不同）
-- LegendWarrior 模型 Root scale=1，modelNode scale≈0.865
-- 武器挂在骨骼上继承 modelNode 的缩放（约 0.865）
-- 因此武器需要放大 1/0.865≈1.16 倍来补偿
local WEAPON_SCALE = 1.16

local WEAPON_CONFIG = {
    warrior = {
        name = "朱雀赤剑",
        bone = "R_Hand",
        offset = Vector3(0.0, 0.08, 0.02),
        rotation = Quaternion(0, 0, -90),
        scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
        buildFunc = "BuildSword",
    },
    mage = {
        name = "玄冰法杖",
        bone = "R_Hand",
        offset = Vector3(0.0, 0.10, 0.0),
        rotation = Quaternion(0, 0, -90),
        scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
        buildFunc = "BuildStaff",
    },
    taoist = {
        name = "翠灵符剑",
        bone = "R_Hand",
        offset = Vector3(0.0, 0.06, 0.02),
        rotation = Quaternion(0, 0, -90),
        scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
        buildFunc = "BuildTalisman",
    },
}

-- ============================================================================
-- 武器构建函数（CustomGeometry 程序化生成）
-- ============================================================================

--- 构建剑：朱红色金属长剑
local function BuildSword(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local bladeLen = 0.7
    local bladeW   = 0.04
    local bladeT   = 0.008
    local handleLen = 0.15
    local handleW   = 0.02
    local guardW    = 0.08
    local guardT    = 0.015

    local function addQuad(p1, p2, p3, p4, normal)
        geom:DefineVertex(p1) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,0))
        geom:DefineVertex(p2) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,0))
        geom:DefineVertex(p3) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,1))
        geom:DefineVertex(p1) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,0))
        geom:DefineVertex(p3) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,1))
        geom:DefineVertex(p4) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,1))
    end

    local function addBox(cx, cy, cz, hx, hy, hz)
        local x0, x1 = cx - hx, cx + hx
        local y0, y1 = cy - hy, cy + hy
        local z0, z1 = cz - hz, cz + hz
        addQuad(Vector3(x0,y0,z1), Vector3(x1,y0,z1), Vector3(x1,y1,z1), Vector3(x0,y1,z1), Vector3(0,0,1))
        addQuad(Vector3(x1,y0,z0), Vector3(x0,y0,z0), Vector3(x0,y1,z0), Vector3(x1,y1,z0), Vector3(0,0,-1))
        addQuad(Vector3(x0,y0,z0), Vector3(x0,y0,z1), Vector3(x0,y1,z1), Vector3(x0,y1,z0), Vector3(-1,0,0))
        addQuad(Vector3(x1,y0,z1), Vector3(x1,y0,z0), Vector3(x1,y1,z0), Vector3(x1,y1,z1), Vector3(1,0,0))
        addQuad(Vector3(x0,y1,z1), Vector3(x1,y1,z1), Vector3(x1,y1,z0), Vector3(x0,y1,z0), Vector3(0,1,0))
        addQuad(Vector3(x0,y0,z0), Vector3(x1,y0,z0), Vector3(x1,y0,z1), Vector3(x0,y0,z1), Vector3(0,-1,0))
    end

    -- 剑柄
    addBox(0, -handleLen/2, 0, handleW/2, handleLen/2, handleW/2)
    -- 护手
    addBox(0, 0, 0, guardW/2, guardT/2, guardT/2)
    -- 剑刃
    addBox(0, bladeLen/2, 0, bladeW/2, bladeLen/2, bladeT/2)

    geom:Commit()

    -- PBR 材质：朱红金属
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.72, 0.18, 0.12, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.18))
    mat:SetShaderParameter("Metallic", Variant(0.92))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.15, 0.03, 0.02)))
    geom:SetMaterial(mat)
end

--- 构建法杖：深蓝色水晶杖
local function BuildStaff(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local staffLen = 1.0
    local staffR   = 0.015
    local orbR     = 0.04
    local segments = 8

    local function addQuad(p1, p2, p3, p4, normal)
        geom:DefineVertex(p1) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,0))
        geom:DefineVertex(p2) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,0))
        geom:DefineVertex(p3) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,1))
        geom:DefineVertex(p1) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,0))
        geom:DefineVertex(p3) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,1))
        geom:DefineVertex(p4) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,1))
    end

    -- 杖身：八棱柱近似圆柱
    for i = 0, segments - 1 do
        local a0 = (i / segments) * math.pi * 2
        local a1 = ((i + 1) / segments) * math.pi * 2
        local x0, z0 = math.cos(a0) * staffR, math.sin(a0) * staffR
        local x1, z1 = math.cos(a1) * staffR, math.sin(a1) * staffR
        local nx = math.cos((a0 + a1) / 2)
        local nz = math.sin((a0 + a1) / 2)
        addQuad(
            Vector3(x0, 0, z0), Vector3(x1, 0, z1),
            Vector3(x1, staffLen, z1), Vector3(x0, staffLen, z0),
            Vector3(nx, 0, nz)
        )
    end

    -- 顶部水晶球
    local orbY = staffLen + orbR * 0.5
    for i = 0, segments - 1 do
        local a0 = (i / segments) * math.pi * 2
        local a1 = ((i + 1) / segments) * math.pi * 2
        local x0, z0 = math.cos(a0) * orbR, math.sin(a0) * orbR
        local x1, z1 = math.cos(a1) * orbR, math.sin(a1) * orbR
        -- 上锥
        geom:DefineVertex(Vector3(0, orbY + orbR, 0))
        geom:DefineNormal(Vector3(0, 1, 0))
        geom:DefineTexCoord(Vector2(0.5, 0))
        geom:DefineVertex(Vector3(x1, orbY, z1))
        geom:DefineNormal(Vector3(x1, 0.5, z1):Normalized())
        geom:DefineTexCoord(Vector2(1, 1))
        geom:DefineVertex(Vector3(x0, orbY, z0))
        geom:DefineNormal(Vector3(x0, 0.5, z0):Normalized())
        geom:DefineTexCoord(Vector2(0, 1))
        -- 下锥
        geom:DefineVertex(Vector3(0, orbY - orbR, 0))
        geom:DefineNormal(Vector3(0, -1, 0))
        geom:DefineTexCoord(Vector2(0.5, 1))
        geom:DefineVertex(Vector3(x0, orbY, z0))
        geom:DefineNormal(Vector3(x0, -0.5, z0):Normalized())
        geom:DefineTexCoord(Vector2(0, 0))
        geom:DefineVertex(Vector3(x1, orbY, z1))
        geom:DefineNormal(Vector3(x1, -0.5, z1):Normalized())
        geom:DefineTexCoord(Vector2(1, 0))
    end

    geom:Commit()

    -- PBR 材质：深蓝冰晶
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.12, 0.25, 0.60, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.12))
    mat:SetShaderParameter("Metallic", Variant(0.60))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.05, 0.10, 0.30)))
    geom:SetMaterial(mat)
end

--- 构建符剑：翠绿短剑
local function BuildTalisman(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    local bladeLen = 0.45
    local bladeW   = 0.05
    local bladeT   = 0.006
    local handleLen = 0.12
    local handleW   = 0.018

    local function addQuad(p1, p2, p3, p4, normal)
        geom:DefineVertex(p1) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,0))
        geom:DefineVertex(p2) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,0))
        geom:DefineVertex(p3) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,1))
        geom:DefineVertex(p1) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,0))
        geom:DefineVertex(p3) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,1))
        geom:DefineVertex(p4) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,1))
    end

    local function addBox(cx, cy, cz, hx, hy, hz)
        local x0, x1 = cx - hx, cx + hx
        local y0, y1 = cy - hy, cy + hy
        local z0, z1 = cz - hz, cz + hz
        addQuad(Vector3(x0,y0,z1), Vector3(x1,y0,z1), Vector3(x1,y1,z1), Vector3(x0,y1,z1), Vector3(0,0,1))
        addQuad(Vector3(x1,y0,z0), Vector3(x0,y0,z0), Vector3(x0,y1,z0), Vector3(x1,y1,z0), Vector3(0,0,-1))
        addQuad(Vector3(x0,y0,z0), Vector3(x0,y0,z1), Vector3(x0,y1,z1), Vector3(x0,y1,z0), Vector3(-1,0,0))
        addQuad(Vector3(x1,y0,z1), Vector3(x1,y0,z0), Vector3(x1,y1,z0), Vector3(x1,y1,z1), Vector3(1,0,0))
        addQuad(Vector3(x0,y1,z1), Vector3(x1,y1,z1), Vector3(x1,y1,z0), Vector3(x0,y1,z0), Vector3(0,1,0))
        addQuad(Vector3(x0,y0,z0), Vector3(x1,y0,z0), Vector3(x1,y0,z1), Vector3(x0,y0,z1), Vector3(0,-1,0))
    end

    -- 柄
    addBox(0, -handleLen/2, 0, handleW/2, handleLen/2, handleW/2)
    -- 剑刃
    addBox(0, bladeLen/2, 0, bladeW/2, bladeLen/2, bladeT/2)

    geom:Commit()

    -- PBR 材质：翠绿玉石质感
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.15, 0.55, 0.30, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.22))
    mat:SetShaderParameter("Metallic", Variant(0.50))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.08, 0.20, 0.10)))
    geom:SetMaterial(mat)
end

-- 武器构建函数表
local WEAPON_BUILDERS = {
    BuildSword = BuildSword,
    BuildStaff = BuildStaff,
    BuildTalisman = BuildTalisman,
}

--- 挂载武器到角色骨骼
local function AttachWeapon(classId)
    -- 移除旧武器
    if weaponNode_ then
        weaponNode_:Remove()
        weaponNode_ = nil
    end

    if not animModel_ then return end

    local config = WEAPON_CONFIG[classId]
    if not config then return end

    -- 获取骨骼节点
    local skeleton = animModel_:GetSkeleton()
    if not skeleton then
        print("[PlayerAnim] WARNING: No skeleton found")
        return
    end

    local bone = skeleton:GetBone(config.bone)
    if not bone then
        print("[PlayerAnim] WARNING: Bone '" .. config.bone .. "' not found")
        return
    end

    local boneNode = bone.node
    if not boneNode then
        print("[PlayerAnim] WARNING: Bone node is nil for '" .. config.bone .. "'")
        return
    end

    -- 在骨骼节点上创建武器子节点
    weaponNode_ = boneNode:CreateChild(config.name)
    weaponNode_.position = config.offset
    weaponNode_.rotation = config.rotation
    weaponNode_.scale = config.scale

    -- 调用对应的构建函数
    local builder = WEAPON_BUILDERS[config.buildFunc]
    if builder then
        builder(weaponNode_)
        local ws = weaponNode_.worldScale
        print(string.format("[PlayerAnim] Weapon attached: %s → %s | localScale=%.2f worldScale=(%.4f,%.4f,%.4f)",
            config.name, config.bone, config.scale.x, ws.x, ws.y, ws.z))
    else
        print("[PlayerAnim] WARNING: Unknown build func: " .. tostring(config.buildFunc))
    end
end

-- ============================================================================
-- 创建角色
-- LegendWarrior 模型：Tripo Rig 骨骼，Root scale=1，无缩放问题
-- ============================================================================
function PlayerAnim.CreateSkeleton(playerNode, classId, color, colors)
    print("[PlayerAnim] CreateSkeleton called: " .. tostring(classId))
    currentClassId = classId
    playerNode_ = playerNode

    -- 清理旧模型
    if modelNode_ then
        modelNode_:Remove()
        modelNode_ = nil
        animCtrl_ = nil
        animModel_ = nil
    end

    -- 加载预制体
    local ok, err = pcall(function()
        local parentScene = playerNode:GetScene()
        local prefabFile = cache:GetFile(CHARACTER_PREFAB)
        if not prefabFile then
            print("[PlayerAnim] ERROR: Cannot find prefab: " .. CHARACTER_PREFAB)
            return
        end

        local prefabNode = parentScene:InstantiateXML(prefabFile, Vector3.ZERO, Quaternion.IDENTITY, LOCAL)
        prefabFile:Close()

        if prefabNode then
            print("[PlayerAnim] Prefab instantiated: " .. prefabNode.name)

            -- reparent 为 playerNode 的子节点
            prefabNode.parent = playerNode
            prefabNode.name = "CharacterModel"
            modelNode_ = prefabNode

            -- 获取 AnimatedModel
            animModel_ = modelNode_:GetComponent("AnimatedModel")
            if not animModel_ then
                animModel_ = modelNode_:GetComponent("AnimatedModel", true)
            end

            if animModel_ then
                -- 模型 BBox: height=1.85m, 缩放到目标高度 1.6m
                local bb = animModel_.boundingBox
                local h = bb.size.y
                local minY = bb.min.y
                print(string.format("[PlayerAnim] BBox height=%.3f minY=%.3f", h, minY))

                if h > 0 then
                    local s = TARGET_HEIGHT_ / h
                    baseScale_ = s
                    baseFootOffset_ = -minY * s
                    modelNode_.scale = Vector3(s, s, s)
                    modelNode_.position = Vector3(0, baseFootOffset_, 0)
                    print(string.format("[PlayerAnim] Scale=%.4f footOffset=%.4f", baseScale_, baseFootOffset_))
                end
            else
                print("[PlayerAnim] WARNING: No AnimatedModel found in prefab!")
            end
        else
            print("[PlayerAnim] WARNING: InstantiateXML returned nil")
        end
    end)

    if not ok then
        print("[PlayerAnim] Prefab load error: " .. tostring(err))
    end

    -- 如果 AnimatedModel 没创建成功，用 Capsule 作为可视 fallback
    if not animModel_ then
        print("[PlayerAnim] Using fallback capsule model")
        modelNode_ = playerNode:CreateChild("CharacterModel")
        local staticModel = modelNode_:CreateComponent("StaticModel")
        staticModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(Color(0.55, 0.12, 0.08, 1.0)))
        mat:SetShaderParameter("Roughness", Variant(0.3))
        mat:SetShaderParameter("Metallic", Variant(0.7))
        staticModel:SetMaterial(mat)
        modelNode_.scale = Vector3(0.4, 1.6, 0.4)
        modelNode_.position = Vector3(0, 0.8, 0)
    else
        -- AnimationController
        animCtrl_ = modelNode_:GetComponent("AnimationController")
            or modelNode_:GetComponent("AnimationController", true)
        if not animCtrl_ then
            animCtrl_ = modelNode_:CreateComponent("AnimationController")
        end

        -- 播放 idle 动画
        if animCtrl_ and ANIM_PATHS.idle then
            animCtrl_:PlayExclusive(ANIM_PATHS.idle, 0, true, 0.0)
            animState.current = "idle"
            print("[PlayerAnim] Idle animation started: " .. ANIM_PATHS.idle)
        end

        -- 应用职业材质
        ApplyClassMaterial(classId)

        -- 挂载武器到手部骨骼
        AttachWeapon(classId)
    end

    print("[PlayerAnim] Character created: " .. classId)
end

-- ============================================================================
-- 动画播放
-- ============================================================================

--- 播放基础动画（idle/walk/move/jump等）或技能动画
--- @param animName string 动画键名（ANIM_PATHS中的key）
--- @param onComplete function|nil 非循环动画结束回调
--- @param opts table|nil {speed=1.0, duration=override}
function PlayerAnim.Play(animName, onComplete, opts)
    local animPath = ANIM_PATHS[animName]
    if not animPath then
        -- 尝试映射别名
        if animName == "hit" then animPath = ANIM_PATHS.melee_fast
        else return end
    end

    if not animCtrl_ then return end

    local speed = (opts and opts.speed) or 1.0
    local isLoop = ANIM_LOOPING[animName] or false
    local duration = (opts and opts.duration) or ANIM_DURATIONS[animName] or 1.0

    -- 如果是同一个循环动画已经在播放，不重复触发
    if animState.current == animName and isLoop then
        return
    end

    animState.current = animName
    animState.elapsed = 0
    animState.duration = duration
    animState.onComplete = onComplete
    animState.speed = speed

    animCtrl_:PlayExclusive(animPath, 0, isLoop, 0.15)
    animCtrl_:SetSpeed(animPath, speed)
end

--- 播放技能动画（根据职业+技能类型自动选择动画和参数）
--- @param skillType string 技能类型: melee/ranged/aoe/buff/heal/dot/dash/summon
--- @param onComplete function|nil 结束回调
function PlayerAnim.PlaySkill(skillType, onComplete)
    local classMap = SKILL_ANIM_MAP[currentClassId]
    if not classMap then
        classMap = SKILL_ANIM_MAP.warrior
    end

    local config = classMap[skillType]
    if not config then
        config = classMap.melee
    end

    PlayerAnim.Play(config.anim, onComplete, {
        speed = config.speed,
        duration = config.duration,
    })
end

function PlayerAnim.IsPlaying(name)
    if name then
        return animState.current == name
    end
    return animState.current ~= "idle" and animState.current ~= "walk" and animState.current ~= "move"
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

function PlayerAnim.Update(dt, isMoving)
    -- 打击感顿帧
    if hitFeedback.hitPause > 0 then
        hitFeedback.hitPause = hitFeedback.hitPause - dt
        if animCtrl_ and ANIM_PATHS[animState.current] then
            animCtrl_:SetSpeed(ANIM_PATHS[animState.current], 0.0)
        end
        return
    else
        -- 恢复动画速度
        if animCtrl_ and ANIM_PATHS[animState.current] then
            animCtrl_:SetSpeed(ANIM_PATHS[animState.current], animState.speed or 1.0)
        end
    end

    -- 自动切换 idle/move
    if animState.current == "idle" and isMoving then
        PlayerAnim.Play("move")
    elseif (animState.current == "move" or animState.current == "walk") and not isMoving then
        PlayerAnim.Play("idle")
    end

    -- 更新时间
    animState.elapsed = animState.elapsed + dt

    -- 非循环动画结束检测
    local isLoop = ANIM_LOOPING[animState.current] or false
    if not isLoop and animState.elapsed >= animState.duration then
        if animState.onComplete then
            animState.onComplete()
        end
        -- 回到 idle/move
        if isMoving then
            PlayerAnim.Play("move")
        else
            PlayerAnim.Play("idle")
        end
    end

    -- 更新打击感反馈
    if hitFeedback.screenShake > 0 then
        hitFeedback.screenShake = hitFeedback.screenShake - dt
    end
    if hitFeedback.flashTimer > 0 then
        hitFeedback.flashTimer = hitFeedback.flashTimer - dt
    end
end

-- ============================================================================
-- 打击感触发
-- ============================================================================
function PlayerAnim.TriggerHitFeedback(intensity)
    intensity = intensity or 1.0
    hitFeedback.screenShake = 0.12 * intensity
    hitFeedback.shakeIntensity = 0.15 * intensity
    hitFeedback.hitPause = 0.04 * intensity
end

-- 获取屏幕震动偏移（供相机使用）
function PlayerAnim.GetCameraShakeOffset()
    if hitFeedback.screenShake > 0 then
        local intensity = hitFeedback.shakeIntensity
        local t = hitFeedback.screenShake
        local decay = t / 0.12
        local ox = (math.random() - 0.5) * 2 * intensity * decay
        local oy = (math.random() - 0.5) * 2 * intensity * decay
        return Vector3(ox, oy, 0)
    end
    return Vector3.ZERO
end

-- 是否显示命中闪光
function PlayerAnim.IsFlashing()
    return hitFeedback.flashTimer > 0
end

-- ============================================================================
-- 攻击动画映射（兼容旧接口 + 新 PlaySkill 接口）
-- ============================================================================

--- 获取技能对应的动画配置
--- @param skillType string
--- @return table {anim=string, speed=number, duration=number}
function PlayerAnim.GetSkillAnimConfig(skillType)
    local classMap = SKILL_ANIM_MAP[currentClassId] or SKILL_ANIM_MAP.warrior
    return classMap[skillType] or classMap.melee
end

--- 兼容旧接口：返回动画 key
function PlayerAnim.GetAnimForSkillType(skillType)
    local config = PlayerAnim.GetSkillAnimConfig(skillType)
    return config.anim
end

-- ============================================================================
-- 获取模型节点（供外部挂载特效等使用）
-- ============================================================================
function PlayerAnim.GetModelNode()
    return modelNode_
end

function PlayerAnim.GetAnimModel()
    return animModel_
end

function PlayerAnim.GetAnimController()
    return animCtrl_
end

-- ============================================================================
-- PostUpdate：简单维持 scale 和 position
-- LegendWarrior 模型无骨骼缩放问题，无需动态校正
-- ============================================================================
function PlayerAnim.PostUpdate()
    if not modelNode_ then return end
    -- 维持 scale 和 position（防止外部意外修改）
    modelNode_.scale = Vector3(baseScale_, baseScale_, baseScale_)
    modelNode_.position = Vector3(0, baseFootOffset_, 0)
end

return PlayerAnim
