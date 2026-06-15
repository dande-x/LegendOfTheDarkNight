---@diagnostic disable: assign-type-mismatch
-- ============================================================================
-- PlayerAnim.lua — 真实3D人形模型 + 动画控制器系统
-- 使用 DefaultMale_Base 预制体（带骨骼）+ 资源库动画
-- 替代旧的基础几何体拼凑方案
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
local isUuidAnim_ = false     -- 当前是否为 UUID 动画
local activeModelScale_ = 1.0 -- 当前帧 modelNode 应使用的 scale（Play 时计算）




PlayerAnim.animState = animState
PlayerAnim.hitFeedback = hitFeedback

-- ============================================================================
-- 角色预制体和动画资源 UUID
-- ============================================================================
local CHARACTER_PREFAB = "uuid://DEkZaUTQvLlCdjdIzpnHa4n-"  -- DefaultMale_Base (标准男骨架)

-- DefaultMale_Base 专属动画（Bip001 骨骼体系）
-- 基础动画使用 DefaultMale 路径；战斗动画使用资源库"标准男"骨架动画（骨骼兼容）
local ANIM_PATHS = {
    -- 基础移动（DefaultMale 原生动画，100%兼容）
    idle       = "DefaultMale/Animations/DefaultMale_Idle.ani",
    walk       = "DefaultMale/Animations/DefaultMale_Walk.ani",
    move       = "DefaultMale/Animations/DefaultMale_Run.ani",
    jump_start = "DefaultMale/Animations/DefaultMale_JumpStart.ani",
    jump_air   = "DefaultMale/Animations/DefaultMale_JumpAir.ani",
    jump_land  = "DefaultMale/Animations/DefaultMale_JumpLanding.ani",
    -- 战斗待机（持武器）— 魔法导师待机姿态(标准男)
    combat_idle = "uuid://Cipz8bNT1q0Hk2NMNBgvzfH_",
    -- 近战攻击 — 杨戬(标准男): 突刺穿心(快)、斜劈重斩(重)
    melee_fast  = "uuid://Ai-SCaONHGJAnRCLZmoO2QJ8",  -- 杨戬 attack_01 突刺穿心 1.07s
    melee_heavy = "uuid://HFCMaTM1TqMyp12CL-treYHh",  -- 杨戬 attack_02 斜劈重斩 1.07s
    -- 施法攻击 — 魔法导师(标准男): 挥击(快)、法杖重砸(长)
    cast_quick  = "uuid://E3rZmUDaM9pq2-V2gj3pCyW4",  -- 魔法导师 attack_01 挥击 1.5s
    cast_long   = "uuid://Hs3_meWUZg22cD1e_0d-BCO6",  -- 魔法导师 skill_01 法杖重砸 1.5s
    -- 冲锋突刺 — 杨戬(标准男): 突刺重击
    dash_strike = "uuid://C1NO-SdM51lg1PCrBmXoiUWO",  -- 杨戬 attack_03 突刺重击 1.33s
    -- 死亡（暂用跳跃起手代替）
    die         = "DefaultMale/Animations/DefaultMale_JumpStart.ani",
}

-- 技能动画映射：根据技能类型和职业返回 {animKey, speed, duration}
local SKILL_ANIM_MAP = {
    -- 武士：近战为主，快速挥砍
    warrior = {
        melee  = { anim = "melee_fast",  speed = 1.8, duration = 0.35 },  -- 快速剑击
        ranged = { anim = "melee_fast",  speed = 1.2, duration = 0.50 },  -- 剑气
        aoe    = { anim = "melee_heavy", speed = 0.8, duration = 0.70 },  -- 半月弧光（慢而有力）
        dash   = { anim = "dash_strike", speed = 2.0, duration = 0.30 },  -- 冲锋
        buff   = { anim = "cast_long",   speed = 1.5, duration = 0.60 },  -- 护盾
        heal   = { anim = "cast_long",   speed = 1.2, duration = 0.80 },
        dot    = { anim = "melee_fast",  speed = 1.5, duration = 0.40 },
        summon = { anim = "cast_long",   speed = 1.0, duration = 1.20 },
    },
    -- 法师：远程施法为主，较慢但华丽
    mage = {
        melee  = { anim = "melee_fast",  speed = 1.5, duration = 0.40 },
        ranged = { anim = "cast_quick",  speed = 1.4, duration = 0.45 },  -- 火球
        aoe    = { anim = "cast_long",   speed = 1.0, duration = 0.80 },  -- 范围法术
        dash   = { anim = "dash_strike", speed = 2.0, duration = 0.30 },
        buff   = { anim = "cast_long",   speed = 0.8, duration = 1.00 },  -- 魔法盾
        heal   = { anim = "cast_long",   speed = 0.8, duration = 1.00 },
        dot    = { anim = "cast_quick",  speed = 1.2, duration = 0.55 },  -- 火墙
        summon = { anim = "cast_long",   speed = 0.7, duration = 1.50 },
    },
    -- 道士：辅助/召唤为主，动作平缓
    taoist = {
        melee  = { anim = "melee_fast",  speed = 1.3, duration = 0.45 },
        ranged = { anim = "cast_quick",  speed = 1.5, duration = 0.40 },  -- 符纸
        aoe    = { anim = "cast_long",   speed = 1.0, duration = 0.80 },
        dash   = { anim = "dash_strike", speed = 1.8, duration = 0.35 },
        buff   = { anim = "cast_long",   speed = 0.9, duration = 1.00 },  -- 增益
        heal   = { anim = "cast_long",   speed = 0.7, duration = 1.20 },  -- 治愈术
        dot    = { anim = "cast_quick",  speed = 1.3, duration = 0.50 },  -- 毒术
        summon = { anim = "cast_long",   speed = 0.6, duration = 1.80 },  -- 召唤神兽
    },
}

-- 动画时长（基础时长，与资源库动画实际时长对齐；技能使用时由 SKILL_ANIM_MAP 覆盖）
local ANIM_DURATIONS = {
    idle        = 2.0,
    walk        = 1.0,
    move        = 0.8,
    jump_start  = 0.3,
    jump_air    = 1.0,
    jump_land   = 0.5,
    combat_idle = 2.0,      -- 魔法导师待机 2.0s
    melee_fast  = 1.07,     -- 杨戬 attack_01 突刺穿心 1.07s
    melee_heavy = 1.07,     -- 杨戬 attack_02 斜劈重斩 1.07s
    cast_quick  = 1.5,      -- 魔法导师 attack_01 挥击 1.5s
    cast_long   = 1.5,      -- 魔法导师 skill_01 法杖重砸 1.5s
    dash_strike = 1.33,     -- 杨戬 attack_03 突刺重击 1.33s
    die         = 1.0,
}

-- 动画是否循环
local ANIM_LOOPING = {
    idle  = true,
    walk  = true,
    move  = true,
    jump_air = true,
    combat_idle = true,
}

-- ============================================================================
-- 武器系统：程序化生成并挂载到骨骼
-- ============================================================================
---@type Node
local weaponNode_ = nil

-- 武器配置（各职业不同）
-- ⚠️ 关键：Root骨骼scale=0.01, modelNode_.scale≈0.868
-- 武器挂在骨骼上继承累计缩放 0.01*0.868=0.00868
-- 因此武器需要放大 1/0.00868≈115 倍才能在世界空间中显示为正常尺寸
local WEAPON_SCALE = 115.0

local WEAPON_CONFIG = {
    warrior = {
        name = "朱雀赤剑",
        bone = "Bip001 R Hand",
        -- 偏移/旋转使剑柄在手心、剑刃向前上方（骨骼本地坐标，单位cm因为Root=0.01）
        offset = Vector3(0.0, 8.0, 2.0),
        rotation = Quaternion(0, 0, -90),
        scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
        buildFunc = "BuildSword",
    },
    mage = {
        name = "玄冰法杖",
        bone = "Bip001 R Hand",
        offset = Vector3(0.0, 10.0, 0.0),
        rotation = Quaternion(0, 0, -90),
        scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
        buildFunc = "BuildStaff",
    },
    taoist = {
        name = "翠灵符剑",
        bone = "Bip001 R Hand",
        offset = Vector3(0.0, 6.0, 2.0),
        rotation = Quaternion(0, 0, -90),
        scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
        buildFunc = "BuildTalisman",
    },
}

-- 职业 PBR 材质配置（纯色金属/玉石质感，不依赖贴图）
-- 每个部位(geometry slot)有不同的材质参数，模拟铠甲/布料/皮肤的层次
local CLASS_MATERIALS = {
    warrior = {
        -- 主体铠甲：暗红铜色金属
        body = { color = Color(0.55, 0.12, 0.08, 1.0), roughness = 0.25, metallic = 0.85,
                 emissive = Color(0.12, 0.02, 0.01) },
        -- 布料部分：深红丝绸
        cloth = { color = Color(0.40, 0.08, 0.05, 1.0), roughness = 0.65, metallic = 0.05,
                  emissive = Color(0.05, 0.01, 0.01) },
        -- 皮肤
        skin = { color = Color(0.72, 0.55, 0.42, 1.0), roughness = 0.55, metallic = 0.0,
                 emissive = Color(0.0, 0.0, 0.0) },
    },
    mage = {
        -- 主体法袍：深蓝丝绸带能量光泽
        body = { color = Color(0.08, 0.15, 0.52, 1.0), roughness = 0.35, metallic = 0.15,
                 emissive = Color(0.03, 0.06, 0.18) },
        -- 配饰：银色金属
        cloth = { color = Color(0.60, 0.62, 0.68, 1.0), roughness = 0.20, metallic = 0.90,
                  emissive = Color(0.02, 0.03, 0.08) },
        -- 皮肤
        skin = { color = Color(0.68, 0.52, 0.40, 1.0), roughness = 0.55, metallic = 0.0,
                 emissive = Color(0.0, 0.0, 0.0) },
    },
    taoist = {
        -- 主体道袍：翡翠绿玉石质感
        body = { color = Color(0.12, 0.42, 0.25, 1.0), roughness = 0.30, metallic = 0.20,
                 emissive = Color(0.02, 0.08, 0.04) },
        -- 配饰：暗金色
        cloth = { color = Color(0.55, 0.45, 0.15, 1.0), roughness = 0.28, metallic = 0.75,
                  emissive = Color(0.04, 0.03, 0.01) },
        -- 皮肤
        skin = { color = Color(0.70, 0.54, 0.41, 1.0), roughness = 0.55, metallic = 0.0,
                 emissive = Color(0.0, 0.0, 0.0) },
    },
}

-- ============================================================================
-- 武器构建函数（CustomGeometry 程序化生成）
-- ============================================================================

--- 构建剑：朱红色金属长剑
local function BuildSword(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    -- 剑的尺寸（本地坐标，Y=长度方向）
    local bladeLen = 0.7    -- 剑刃长度
    local bladeW   = 0.04   -- 剑刃宽度
    local bladeT   = 0.008  -- 剑刃厚度
    local handleLen = 0.15  -- 剑柄长度
    local handleW   = 0.02  -- 剑柄宽度
    local guardW    = 0.08  -- 护手宽度
    local guardT    = 0.015

    -- 辅助：添加一个 Box 面
    local function addQuad(p1, p2, p3, p4, normal)
        -- 三角形 1: p1, p2, p3
        geom:DefineVertex(p1) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,0))
        geom:DefineVertex(p2) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,0))
        geom:DefineVertex(p3) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,1))
        -- 三角形 2: p1, p3, p4
        geom:DefineVertex(p1) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,0))
        geom:DefineVertex(p3) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(1,1))
        geom:DefineVertex(p4) geom:DefineNormal(normal) geom:DefineTexCoord(Vector2(0,1))
    end

    -- 辅助：添加一个长方体（6面）
    local function addBox(cx, cy, cz, hx, hy, hz)
        local x0, x1 = cx - hx, cx + hx
        local y0, y1 = cy - hy, cy + hy
        local z0, z1 = cz - hz, cz + hz
        -- 前后左右上下
        addQuad(Vector3(x0,y0,z1), Vector3(x1,y0,z1), Vector3(x1,y1,z1), Vector3(x0,y1,z1), Vector3(0,0,1))
        addQuad(Vector3(x1,y0,z0), Vector3(x0,y0,z0), Vector3(x0,y1,z0), Vector3(x1,y1,z0), Vector3(0,0,-1))
        addQuad(Vector3(x0,y0,z0), Vector3(x0,y0,z1), Vector3(x0,y1,z1), Vector3(x0,y1,z0), Vector3(-1,0,0))
        addQuad(Vector3(x1,y0,z1), Vector3(x1,y0,z0), Vector3(x1,y1,z0), Vector3(x1,y1,z1), Vector3(1,0,0))
        addQuad(Vector3(x0,y1,z1), Vector3(x1,y1,z1), Vector3(x1,y1,z0), Vector3(x0,y1,z0), Vector3(0,1,0))
        addQuad(Vector3(x0,y0,z0), Vector3(x1,y0,z0), Vector3(x1,y0,z1), Vector3(x0,y0,z1), Vector3(0,-1,0))
    end

    -- 剑柄（暗色）
    addBox(0, -handleLen/2, 0, handleW/2, handleLen/2, handleW/2)
    -- 护手（金色区域）
    addBox(0, 0, 0, guardW/2, guardT/2, guardT/2)
    -- 剑刃（从护手向上延伸）
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

    local staffLen = 1.0   -- 杖身长度
    local staffR   = 0.015 -- 杖身半径
    local orbR     = 0.04  -- 顶部水晶球半径
    local segments = 8

    -- 辅助：添加面片
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

    -- 顶部水晶球：八棱体近似（上下锥体）
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

--- 构建符剑：翠绿短剑 + 发光符文效果
local function BuildTalisman(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)

    -- 符剑比战士剑短，但更宽
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

    -- PBR 材质：翠绿玉石质感 + 发光
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
        -- 诊断：确认世界缩放
        local ws = weaponNode_.worldScale
        print(string.format("[PlayerAnim] Weapon attached: %s → %s | localScale=%.1f worldScale=(%.4f,%.4f,%.4f)",
            config.name, config.bone, config.scale.x, ws.x, ws.y, ws.z))
    else
        print("[PlayerAnim] WARNING: Unknown build func: " .. tostring(config.buildFunc))
    end
end

-- ============================================================================
-- 创建角色（替代旧的 CreateSkeleton）
-- 核心：保留预制体完整骨骼层级，reparent 为 playerNode 子节点
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

    -- 尝试加载预制体（保留完整骨骼层级）
    local ok, err = pcall(function()
        local parentScene = playerNode:GetScene()
        -- InstantiateXML 会在场景根创建完整节点树（含骨骼子节点）
        local prefabNode = parentScene:InstantiateXML(CHARACTER_PREFAB, Vector3.ZERO, Quaternion.IDENTITY, LOCAL)
        if prefabNode then
            print("[PlayerAnim] Prefab instantiated, inspecting structure...")
            -- 打印预制体节点结构（诊断）
            print("[PlayerAnim] PrefabRoot: name=" .. prefabNode.name
                .. " pos=" .. tostring(prefabNode.position)
                .. " scale=" .. tostring(prefabNode.scale)
                .. " numChildren=" .. tostring(prefabNode.numChildren))
            for i = 0, prefabNode.numChildren - 1 do
                local child = prefabNode:GetChild(i)
                local hasModel = child:GetComponent("AnimatedModel") ~= nil
                print("[PlayerAnim]   child[" .. i .. "]: name=" .. child.name
                    .. " pos=" .. tostring(child.position)
                    .. " scale=" .. tostring(child.scale)
                    .. " hasAnimModel=" .. tostring(hasModel)
                    .. " numChildren=" .. tostring(child.numChildren))
            end

            -- 关键：reparent 为 playerNode 的子节点（保留所有子节点=骨骼）
            prefabNode.parent = playerNode
            prefabNode.name = "CharacterModel"
            modelNode_ = prefabNode

            -- 获取 AnimatedModel（可能在本节点或第一层子节点）
            animModel_ = modelNode_:GetComponent("AnimatedModel")
            if not animModel_ then
                -- 尝试递归查找
                animModel_ = modelNode_:GetComponent("AnimatedModel", true)
            end

            if animModel_ then
                -- Root 骨骼的 0.01 缩放是 FBX cm→m 转换，不要修改它！
                -- 逆绑定矩阵基于 Root=0.01 计算，蒙皮依赖此值正确工作。
                -- scale = targetHeight / boundingBox.height 即可（动画稳定后 worldBBox ≈ 1.6m）
                local bb = animModel_.boundingBox
                local h = bb.size.y
                local minY = bb.min.y
                print("[PlayerAnim] BBox height=" .. string.format("%.3f", h) .. " minY=" .. string.format("%.3f", minY))

                if h > 0 then
                    local TARGET_HEIGHT = 1.6
                    local s = TARGET_HEIGHT / h
                    baseScale_ = s
                    baseFootOffset_ = -minY * s
                    modelNode_.scale = Vector3(s, s, s)
                    modelNode_.position = Vector3(0, baseFootOffset_, 0)
                    print("[PlayerAnim] Applied baseScale=" .. string.format("%.5f", baseScale_)
                        .. " footOffset=" .. string.format("%.5f", baseFootOffset_))
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
        local tint = CLASS_MATERIALS[classId] and CLASS_MATERIALS[classId].body.color
            or Color(0.5, 0.5, 0.5, 1.0)
        mat:SetShaderParameter("MatDiffColor", Variant(tint))
        mat:SetShaderParameter("Roughness", Variant(0.3))
        mat:SetShaderParameter("Metallic", Variant(0.7))
        staticModel:SetMaterial(mat)
        modelNode_.scale = Vector3(0.4, 1.6, 0.4)
        modelNode_.position = Vector3(0, 0.8, 0)
    else
        -- UUID 动画将 Bip001.scale 从 0.01 设为 1.0，
        -- 配合 InverseBind(100x) 导致蒙皮膨胀 100 倍。
        -- 解决方案：在 Play() 中根据动画类型直接设置 modelNode_.scale，
        -- 不尝试读写骨骼（引擎蒙皮系统不允许 Lua 层干预骨骼 transform）。
        activeModelScale_ = baseScale_
        print("[PlayerAnim] Using direct modelNode scale compensation (no bone manipulation)")

        -- AnimationController（预制体中可能已存在，或新建）
        animCtrl_ = modelNode_:GetComponent("AnimationController")
            or modelNode_:GetComponent("AnimationController", true)
        if not animCtrl_ then
            animCtrl_ = modelNode_:CreateComponent("AnimationController")
        end
        -- 播放 idle 动画（使用 DefaultMale 专属动画，骨骼完全匹配）
        if animCtrl_ and ANIM_PATHS.idle then
            animCtrl_:PlayExclusive(ANIM_PATHS.idle, 0, true, 0.0)
            animState.current = "idle"
            print("[PlayerAnim] Idle animation started: " .. ANIM_PATHS.idle)
        end

        -- 应用职业材质
        PlayerAnim._ApplyClassMaterial(classId, color)

        -- 挂载武器到手部骨骼
        AttachWeapon(classId)
    end

    print("[PlayerAnim] Character created: " .. classId)
end

-- ============================================================================
-- 职业材质覆盖（纯 PBR，光滑金属/丝绸/玉石质感）
-- ============================================================================
function PlayerAnim._ApplyClassMaterial(classId, baseColor)
    if not animModel_ then return end

    local classMats = CLASS_MATERIALS[classId]
    if not classMats then
        classMats = CLASS_MATERIALS.warrior  -- fallback
    end

    local numMats = animModel_:GetNumGeometries()
    local pbrTech = cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")

    -- DefaultMale_Base 有 6 个材质槽位：
    -- 0=头发, 1=身体/衣服主体, 2=裤子/下装, 3=鞋子, 4=皮肤/面部, 5=饰品
    -- 按槽位分配：body(铠甲主体), cloth(布料), skin(皮肤)
    local slotMapping = {
        [0] = "body",   -- 头发 → 用铠甲色（像头盔）
        [1] = "body",   -- 衣服主体 → 铠甲
        [2] = "cloth",  -- 裤子 → 布料
        [3] = "body",   -- 鞋子 → 铠甲
        [4] = "skin",   -- 皮肤
        [5] = "cloth",  -- 饰品 → 配饰
    }

    for i = 0, numMats - 1 do
        local mat = Material:new()
        mat:SetTechnique(0, pbrTech)

        -- 根据槽位选择材质参数
        local slotType = slotMapping[i] or "body"
        local params = classMats[slotType]

        mat:SetShaderParameter("MatDiffColor", Variant(params.color))
        mat:SetShaderParameter("Roughness", Variant(params.roughness))
        mat:SetShaderParameter("Metallic", Variant(params.metallic))
        mat:SetShaderParameter("MatEmissiveColor", Variant(params.emissive))

        animModel_:SetMaterial(i, mat)
    end
end

-- ============================================================================
-- 动画播放
-- ============================================================================

--- 播放基础动画（idle/walk/move/jump等）或技能动画
--- @param animName string 动画键名（ANIM_PATHS中的key）或 "skill" 特殊类型
--- @param onComplete function|nil 非循环动画结束回调
--- @param opts table|nil {speed=1.0, duration=override}
function PlayerAnim.Play(animName, onComplete, opts)
    local animPath = ANIM_PATHS[animName]
    if not animPath then
        -- 尝试映射别名
        if animName == "walk" then animPath = ANIM_PATHS.walk or ANIM_PATHS.move
        elseif animName == "hit" then animPath = ANIM_PATHS.melee_fast
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
    animState.speed = speed  -- 记录当前速度（用于顿帧恢复）

    -- 检测动画类型并设置 modelNode scale 补偿
    -- UUID 动画将 Bip001.scale 设为 1.0（而非 native 的 0.01），
    -- InverseBind 中有 100x 放大，导致蒙皮膨胀 100 倍。
    -- 解决：UUID 动画时 modelNode.scale 缩小 100 倍抵消。
    local wasUuid = isUuidAnim_
    isUuidAnim_ = (animPath:find("uuid://") ~= nil)

    if isUuidAnim_ then
        activeModelScale_ = baseScale_ / 100.0
    else
        activeModelScale_ = baseScale_
    end
    -- 立即应用（不等 PostUpdate，避免一帧闪烁）
    if modelNode_ then
        modelNode_.scale = Vector3(activeModelScale_, activeModelScale_, activeModelScale_)
    end

    -- fadeTime=0：避免交叉淡入淡出时骨骼 pose 跳帧
    animCtrl_:PlayExclusive(animPath, 0, isLoop, 0.0)
    animCtrl_:SetSpeed(animPath, speed)

    if wasUuid ~= isUuidAnim_ then
        print(string.format("[PlayerAnim] Scale switch: uuid=%s → modelScale=%.5f",
            tostring(isUuidAnim_), activeModelScale_))
    end
end

--- 播放技能动画（根据职业+技能类型自动选择动画和参数）
--- @param skillType string 技能类型: melee/ranged/aoe/buff/heal/dot/dash/summon
--- @param onComplete function|nil 结束回调
function PlayerAnim.PlaySkill(skillType, onComplete)
    local classMap = SKILL_ANIM_MAP[currentClassId]
    if not classMap then
        classMap = SKILL_ANIM_MAP.warrior  -- fallback
    end

    local config = classMap[skillType]
    if not config then
        config = classMap.melee  -- fallback
    end

    -- 使用 SKILL_ANIM_MAP 中配置的 animKey、speed、duration
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
local animDiagCounter_ = 0

function PlayerAnim.Update(dt, isMoving)
    -- modelNode_ 是 playerNode_ 的子节点，自动继承位置/旋转，无需手动同步

    -- 诊断：每 180 帧输出 worldBBox
    animDiagCounter_ = animDiagCounter_ + 1
    if animModel_ and animDiagCounter_ % 180 == 1 then
        local wbb = animModel_.worldBoundingBox
        local wbbSize = wbb.size
        local ws = modelNode_.worldScale
        print(string.format("[DIAG] worldScale=(%.5f) wBBox sz(%.2f, %.2f, %.2f) state=%s",
            ws.x, wbbSize.x, wbbSize.y, wbbSize.z, animState.current))
    end

    -- 打击感顿帧
    if hitFeedback.hitPause > 0 then
        hitFeedback.hitPause = hitFeedback.hitPause - dt
        -- 暂停动画
        if animCtrl_ and ANIM_PATHS[animState.current] then
            animCtrl_:SetSpeed(ANIM_PATHS[animState.current], 0.0)
        end
        return
    else
        -- 恢复动画速度（使用记录的 speed，而非固定 1.0）
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

--- 获取技能对应的动画配置（新接口，推荐使用 PlaySkill 代替）
--- @param skillType string
--- @return table {anim=string, speed=number, duration=number}
function PlayerAnim.GetSkillAnimConfig(skillType)
    local classMap = SKILL_ANIM_MAP[currentClassId] or SKILL_ANIM_MAP.warrior
    return classMap[skillType] or classMap.melee
end

--- 兼容旧接口：返回动画 key（现在返回 SKILL_ANIM_MAP 中的 anim 字段）
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
-- PostUpdate：维持 modelNode 的 scale 和 position
-- 时序：E_UPDATE → AnimCtrl 更新骨骼 → E_POSTUPDATE(此函数) → RenderUpdate(蒙皮)
--
-- 不再尝试读写骨骼 transform（引擎蒙皮系统不允许 Lua 干预）。
-- Play() 已根据动画类型（UUID vs native）计算好 activeModelScale_，
-- 此处只需每帧维持该值，防止其他系统意外覆盖。
-- ============================================================================
function PlayerAnim.PostUpdate()
    if not modelNode_ then return end
    modelNode_.scale = Vector3(activeModelScale_, activeModelScale_, activeModelScale_)
    modelNode_.position = Vector3(0, baseFootOffset_, 0)
end

return PlayerAnim
