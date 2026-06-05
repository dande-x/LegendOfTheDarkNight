-- ============================================================================
-- MonsterSkeleton.lua — 怪物程序化骨架 + 动画系统
-- 5种传奇风格怪物：鹿、稻草人、骷髅、蜘蛛、半兽人
-- 每种怪物有独立骨架结构和4套动画（idle/move/attack/hit/death）
-- ============================================================================

local MonsterSkeleton = {}

-- ============================================================================
-- 工具函数
-- ============================================================================
local function lerpAngle(a, b, t)
    return a + (b - a) * t
end

local function CreatePBRMat(color, roughness, metallic)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.6))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    return mat
end

-- ============================================================================
-- 骨架定义：5种怪物
-- 格式: { parent, pos={x,y,z}, meshScale={x,y,z}, model, meshOffset={x,y,z} }
-- ============================================================================

-- 鹿：四足动物，优雅的鹿角
local BONES_DEER = {
    body     = { parent = nil,       pos = {0, 0.55, 0},    meshScale = {0.30, 0.25, 0.60}, model = "Cylinder" },
    neck     = { parent = "body",    pos = {0, 0.10, 0.25}, meshScale = {0.10, 0.30, 0.10}, model = "Cylinder", meshOffset = {0, 0.15, 0} },
    head     = { parent = "neck",    pos = {0, 0.28, 0.05}, meshScale = {0.16, 0.14, 0.20}, model = "Sphere" },
    antlerL  = { parent = "head",    pos = {-0.08, 0.10, 0}, meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, 0.09, 0} },
    antlerR  = { parent = "head",    pos = {0.08, 0.10, 0},  meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, 0.09, 0} },
    tail     = { parent = "body",    pos = {0, 0.05, -0.30}, meshScale = {0.05, 0.05, 0.10}, model = "Cylinder" },
    -- 前腿
    lFrontUp = { parent = "body",    pos = {-0.12, -0.10, 0.20}, meshScale = {0.06, 0.22, 0.06}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    lFrontLo = { parent = "lFrontUp", pos = {0, -0.22, 0},       meshScale = {0.05, 0.20, 0.05}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    rFrontUp = { parent = "body",    pos = {0.12, -0.10, 0.20},  meshScale = {0.06, 0.22, 0.06}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    rFrontLo = { parent = "rFrontUp", pos = {0, -0.22, 0},       meshScale = {0.05, 0.20, 0.05}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    -- 后腿
    lBackUp  = { parent = "body",    pos = {-0.12, -0.10, -0.20}, meshScale = {0.07, 0.22, 0.07}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    lBackLo  = { parent = "lBackUp", pos = {0, -0.22, 0},         meshScale = {0.05, 0.20, 0.05}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    rBackUp  = { parent = "body",    pos = {0.12, -0.10, -0.20},  meshScale = {0.07, 0.22, 0.07}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    rBackLo  = { parent = "rBackUp", pos = {0, -0.22, 0},         meshScale = {0.05, 0.20, 0.05}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
}

-- 稻草人：十字形身体，悬挂的手臂，破烂的感觉
local BONES_SCARECROW = {
    pole     = { parent = nil,        pos = {0, 0.50, 0},    meshScale = {0.06, 1.00, 0.06}, model = "Cylinder" },
    crossbar = { parent = "pole",     pos = {0, 0.35, 0},    meshScale = {0.70, 0.05, 0.05}, model = "Box" },
    head     = { parent = "pole",     pos = {0, 0.55, 0},    meshScale = {0.22, 0.22, 0.22}, model = "Sphere" },
    hat      = { parent = "head",     pos = {0, 0.14, 0},    meshScale = {0.28, 0.08, 0.28}, model = "Cylinder" },
    -- 悬挂的手臂（从横杆下垂）
    lArm     = { parent = "crossbar", pos = {-0.30, -0.02, 0}, meshScale = {0.05, 0.28, 0.05}, model = "Cylinder", meshOffset = {0, -0.14, 0} },
    lHand    = { parent = "lArm",     pos = {0, -0.28, 0},     meshScale = {0.06, 0.06, 0.04}, model = "Sphere" },
    rArm     = { parent = "crossbar", pos = {0.30, -0.02, 0},  meshScale = {0.05, 0.28, 0.05}, model = "Cylinder", meshOffset = {0, -0.14, 0} },
    rHand    = { parent = "rArm",     pos = {0, -0.28, 0},     meshScale = {0.06, 0.06, 0.04}, model = "Sphere" },
    -- 身体（悬挂的布袋）
    torso    = { parent = "pole",     pos = {0, 0.05, 0},    meshScale = {0.25, 0.30, 0.15}, model = "Cylinder" },
}

-- 骷髅：人形但更瘦削，骨头外露
local BONES_SKELETON = {
    pelvis   = { parent = nil,          pos = {0, 0.45, 0},    meshScale = {0.22, 0.10, 0.14}, model = "Box" },
    spine    = { parent = "pelvis",     pos = {0, 0.12, 0},    meshScale = {0.06, 0.20, 0.06}, model = "Cylinder", meshOffset = {0, 0.10, 0} },
    chest    = { parent = "spine",      pos = {0, 0.20, 0},    meshScale = {0.28, 0.18, 0.12}, model = "Box" },
    neck     = { parent = "chest",      pos = {0, 0.10, 0},    meshScale = {0.04, 0.08, 0.04}, model = "Cylinder", meshOffset = {0, 0.04, 0} },
    head     = { parent = "neck",       pos = {0, 0.10, 0},    meshScale = {0.18, 0.20, 0.18}, model = "Sphere" },
    jaw      = { parent = "head",       pos = {0, -0.08, 0.06}, meshScale = {0.12, 0.05, 0.08}, model = "Box" },
    -- 左臂
    lUpperArm = { parent = "chest",     pos = {-0.18, 0.04, 0}, meshScale = {0.04, 0.18, 0.04}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    lForeArm  = { parent = "lUpperArm", pos = {0, -0.18, 0},    meshScale = {0.035, 0.16, 0.035}, model = "Cylinder", meshOffset = {0, -0.08, 0} },
    lHand     = { parent = "lForeArm",  pos = {0, -0.16, 0},    meshScale = {0.05, 0.04, 0.06}, model = "Box" },
    -- 右臂
    rUpperArm = { parent = "chest",     pos = {0.18, 0.04, 0},  meshScale = {0.04, 0.18, 0.04}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    rForeArm  = { parent = "rUpperArm", pos = {0, -0.18, 0},    meshScale = {0.035, 0.16, 0.035}, model = "Cylinder", meshOffset = {0, -0.08, 0} },
    rHand     = { parent = "rForeArm",  pos = {0, -0.16, 0},    meshScale = {0.05, 0.04, 0.06}, model = "Box" },
    -- 左腿
    lThigh   = { parent = "pelvis",     pos = {-0.08, -0.02, 0}, meshScale = {0.045, 0.20, 0.045}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    lShin    = { parent = "lThigh",     pos = {0, -0.20, 0},     meshScale = {0.04, 0.20, 0.04}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    lFoot    = { parent = "lShin",      pos = {0, -0.20, 0.02},  meshScale = {0.05, 0.03, 0.10}, model = "Box" },
    -- 右腿
    rThigh   = { parent = "pelvis",     pos = {0.08, -0.02, 0},  meshScale = {0.045, 0.20, 0.045}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    rShin    = { parent = "rThigh",     pos = {0, -0.20, 0},     meshScale = {0.04, 0.20, 0.04}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    rFoot    = { parent = "rShin",      pos = {0, -0.20, 0.02},  meshScale = {0.05, 0.03, 0.10}, model = "Box" },
}

-- 蜘蛛：中心体+8条腿
local BONES_SPIDER = {
    body     = { parent = nil,      pos = {0, 0.25, 0},     meshScale = {0.25, 0.15, 0.30}, model = "Sphere" },
    head     = { parent = "body",   pos = {0, 0.02, 0.22},  meshScale = {0.14, 0.12, 0.14}, model = "Sphere" },
    abdomen  = { parent = "body",   pos = {0, -0.02, -0.25}, meshScale = {0.22, 0.18, 0.28}, model = "Sphere" },
    -- 左侧4腿（从前到后）
    leg1LUp  = { parent = "body",   pos = {-0.15, 0, 0.15},  meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg1LLo  = { parent = "leg1LUp", pos = {0, -0.18, 0},    meshScale = {0.025, 0.18, 0.025}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg2LUp  = { parent = "body",   pos = {-0.18, 0, 0.05},  meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg2LLo  = { parent = "leg2LUp", pos = {0, -0.18, 0},    meshScale = {0.025, 0.18, 0.025}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg3LUp  = { parent = "body",   pos = {-0.18, 0, -0.05}, meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg3LLo  = { parent = "leg3LUp", pos = {0, -0.18, 0},    meshScale = {0.025, 0.18, 0.025}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg4LUp  = { parent = "body",   pos = {-0.15, 0, -0.15}, meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg4LLo  = { parent = "leg4LUp", pos = {0, -0.18, 0},    meshScale = {0.025, 0.18, 0.025}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    -- 右侧4腿
    leg1RUp  = { parent = "body",   pos = {0.15, 0, 0.15},   meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg1RLo  = { parent = "leg1RUp", pos = {0, -0.18, 0},    meshScale = {0.025, 0.18, 0.025}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg2RUp  = { parent = "body",   pos = {0.18, 0, 0.05},   meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg2RLo  = { parent = "leg2RUp", pos = {0, -0.18, 0},    meshScale = {0.025, 0.18, 0.025}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg3RUp  = { parent = "body",   pos = {0.18, 0, -0.05},  meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg3RLo  = { parent = "leg3RUp", pos = {0, -0.18, 0},    meshScale = {0.025, 0.18, 0.025}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg4RUp  = { parent = "body",   pos = {0.15, 0, -0.15},  meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    leg4RLo  = { parent = "leg4RUp", pos = {0, -0.18, 0},    meshScale = {0.025, 0.18, 0.025}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
}

-- 半兽人：粗壮人形，大头，壮硕身材
local BONES_ORC = {
    pelvis   = { parent = nil,          pos = {0, 0.55, 0},    meshScale = {0.32, 0.18, 0.22}, model = "Box" },
    chest    = { parent = "pelvis",     pos = {0, 0.20, 0},    meshScale = {0.40, 0.28, 0.26}, model = "Box" },
    neck     = { parent = "chest",      pos = {0, 0.16, 0},    meshScale = {0.12, 0.08, 0.12}, model = "Cylinder" },
    head     = { parent = "neck",       pos = {0, 0.12, 0},    meshScale = {0.24, 0.22, 0.22}, model = "Sphere" },
    jaw      = { parent = "head",       pos = {0, -0.08, 0.08}, meshScale = {0.16, 0.06, 0.10}, model = "Box" },
    -- 左臂（粗壮）
    lUpperArm = { parent = "chest",     pos = {-0.26, 0.08, 0}, meshScale = {0.10, 0.20, 0.10}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    lForeArm  = { parent = "lUpperArm", pos = {0, -0.20, 0},    meshScale = {0.09, 0.18, 0.09}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    lHand     = { parent = "lForeArm",  pos = {0, -0.18, 0},    meshScale = {0.10, 0.06, 0.10}, model = "Box" },
    -- 右臂
    rUpperArm = { parent = "chest",     pos = {0.26, 0.08, 0},  meshScale = {0.10, 0.20, 0.10}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    rForeArm  = { parent = "rUpperArm", pos = {0, -0.20, 0},    meshScale = {0.09, 0.18, 0.09}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    rHand     = { parent = "rForeArm",  pos = {0, -0.18, 0},    meshScale = {0.10, 0.06, 0.10}, model = "Box" },
    -- 左腿（短粗）
    lThigh   = { parent = "pelvis",     pos = {-0.12, -0.05, 0}, meshScale = {0.11, 0.20, 0.11}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    lShin    = { parent = "lThigh",     pos = {0, -0.20, 0},     meshScale = {0.09, 0.18, 0.09}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    lFoot    = { parent = "lShin",      pos = {0, -0.18, 0.03},  meshScale = {0.10, 0.05, 0.14}, model = "Box" },
    -- 右腿
    rThigh   = { parent = "pelvis",     pos = {0.12, -0.05, 0},  meshScale = {0.11, 0.20, 0.11}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    rShin    = { parent = "rThigh",     pos = {0, -0.20, 0},     meshScale = {0.09, 0.18, 0.09}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    rFoot    = { parent = "rShin",      pos = {0, -0.18, 0.03},  meshScale = {0.10, 0.05, 0.14}, model = "Box" },
}

-- ============================================================================
-- 怪物类型注册表
-- ============================================================================
MonsterSkeleton.TYPES = {
    deer = {
        name = "鹿",  bones = BONES_DEER,
        color = Color(0.55, 0.40, 0.25, 1.0),  -- 棕色
        scale = 0.9, heightOffset = 0,
    },
    scarecrow = {
        name = "稻草人", bones = BONES_SCARECROW,
        color = Color(0.50, 0.45, 0.20, 1.0),  -- 枯黄色
        scale = 1.0, heightOffset = 0,
    },
    skeleton = {
        name = "骷髅", bones = BONES_SKELETON,
        color = Color(0.85, 0.82, 0.70, 1.0),  -- 骨白色
        scale = 0.95, heightOffset = 0,
    },
    spider = {
        name = "蜘蛛", bones = BONES_SPIDER,
        color = Color(0.20, 0.18, 0.15, 1.0),  -- 深褐色
        scale = 0.85, heightOffset = 0,
    },
    orc = {
        name = "半兽人", bones = BONES_ORC,
        color = Color(0.35, 0.45, 0.25, 1.0),  -- 暗绿色
        scale = 1.1, heightOffset = 0,
    },
}

-- ============================================================================
-- 动画关键帧
-- 格式: { time, boneName, rotX, rotY, rotZ }
-- ============================================================================
local ANIMS = {}

-- ==================== 鹿 ====================
ANIMS.deer = {
    idle = { duration = 2.0, looping = true, keyframes = {
        { 0.0, "neck", 10, 0, 0 }, { 1.0, "neck", 15, 3, 0 }, { 2.0, "neck", 10, 0, 0 },
        { 0.0, "tail", -10, 0, 0 }, { 0.5, "tail", -10, 8, 0 }, { 1.0, "tail", -10, -8, 0 }, { 2.0, "tail", -10, 0, 0 },
    }},
    move = { duration = 0.5, looping = true, keyframes = {
        -- 前腿交替
        { 0.0, "lFrontUp", 30, 0, 0 }, { 0.25, "lFrontUp", -25, 0, 0 }, { 0.5, "lFrontUp", 30, 0, 0 },
        { 0.0, "rFrontUp", -25, 0, 0 }, { 0.25, "rFrontUp", 30, 0, 0 }, { 0.5, "rFrontUp", -25, 0, 0 },
        { 0.0, "lFrontLo", -20, 0, 0 }, { 0.125, "lFrontLo", -40, 0, 0 }, { 0.25, "lFrontLo", -10, 0, 0 }, { 0.5, "lFrontLo", -20, 0, 0 },
        { 0.0, "rFrontLo", -10, 0, 0 }, { 0.25, "rFrontLo", -20, 0, 0 }, { 0.375, "rFrontLo", -40, 0, 0 }, { 0.5, "rFrontLo", -10, 0, 0 },
        -- 后腿交替
        { 0.0, "lBackUp", -20, 0, 0 }, { 0.25, "lBackUp", 25, 0, 0 }, { 0.5, "lBackUp", -20, 0, 0 },
        { 0.0, "rBackUp", 25, 0, 0 }, { 0.25, "rBackUp", -20, 0, 0 }, { 0.5, "rBackUp", 25, 0, 0 },
        { 0.0, "lBackLo", -15, 0, 0 }, { 0.25, "lBackLo", -35, 0, 0 }, { 0.5, "lBackLo", -15, 0, 0 },
        { 0.0, "rBackLo", -35, 0, 0 }, { 0.25, "rBackLo", -15, 0, 0 }, { 0.5, "rBackLo", -35, 0, 0 },
        -- 颈部前倾
        { 0.0, "neck", 5, 0, 0 }, { 0.25, "neck", 0, 0, 0 }, { 0.5, "neck", 5, 0, 0 },
        { 0.0, "body", -3, 0, -2 }, { 0.25, "body", -3, 0, 2 }, { 0.5, "body", -3, 0, -2 },
    }},
    attack = { duration = 0.6, looping = false, keyframes = {
        -- 低头冲撞
        { 0.0, "neck", 10, 0, 0 }, { 0.15, "neck", -30, 0, 0 }, { 0.35, "neck", 40, 0, 0 }, { 0.6, "neck", 10, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.15, "head", 20, 0, 0 }, { 0.35, "head", -15, 0, 0 }, { 0.6, "head", 0, 0, 0 },
        { 0.0, "body", 0, 0, 0 }, { 0.2, "body", -15, 0, 0 }, { 0.4, "body", 10, 0, 0 }, { 0.6, "body", 0, 0, 0 },
    }},
    hit = { duration = 0.3, looping = false, keyframes = {
        { 0.0, "body", 0, 0, 0 }, { 0.08, "body", 10, 0, 5 }, { 0.2, "body", -5, 0, -3 }, { 0.3, "body", 0, 0, 0 },
        { 0.0, "neck", 10, 0, 0 }, { 0.08, "neck", 25, 0, 0 }, { 0.3, "neck", 10, 0, 0 },
    }},
    death = { duration = 1.0, looping = false, keyframes = {
        { 0.0, "body", 0, 0, 0 }, { 0.3, "body", 10, 0, 40 }, { 0.7, "body", 15, 0, 80 }, { 1.0, "body", 20, 0, 90 },
        { 0.0, "neck", 10, 0, 0 }, { 0.5, "neck", 30, 0, 0 }, { 1.0, "neck", 45, 0, 0 },
        { 0.0, "lFrontUp", 0, 0, 0 }, { 0.5, "lFrontUp", -10, 0, 30 }, { 1.0, "lFrontUp", -20, 0, 50 },
        { 0.0, "rFrontUp", 0, 0, 0 }, { 0.5, "rFrontUp", 15, 0, -20 }, { 1.0, "rFrontUp", 20, 0, -40 },
    }},
}

-- ==================== 稻草人 ====================
ANIMS.scarecrow = {
    idle = { duration = 2.5, looping = true, keyframes = {
        -- 风中摇摆
        { 0.0, "pole", 0, 0, -2 }, { 1.25, "pole", 0, 0, 2 }, { 2.5, "pole", 0, 0, -2 },
        { 0.0, "lArm", 0, 0, 5 }, { 0.8, "lArm", 0, 0, 15 }, { 1.6, "lArm", 0, 0, 5 }, { 2.5, "lArm", 0, 0, 5 },
        { 0.0, "rArm", 0, 0, -5 }, { 1.0, "rArm", 0, 0, -15 }, { 2.0, "rArm", 0, 0, -5 }, { 2.5, "rArm", 0, 0, -5 },
        { 0.0, "head", 0, 0, 5 }, { 1.25, "head", 0, 0, -5 }, { 2.5, "head", 0, 0, 5 },
    }},
    move = { duration = 0.6, looping = true, keyframes = {
        -- 诡异的漂浮/弹跳移动
        { 0.0, "pole", -5, 0, -3 }, { 0.15, "pole", 5, 0, 3 }, { 0.3, "pole", -5, 0, 3 }, { 0.45, "pole", 5, 0, -3 }, { 0.6, "pole", -5, 0, -3 },
        { 0.0, "lArm", 0, 0, 20 }, { 0.3, "lArm", 0, 0, -10 }, { 0.6, "lArm", 0, 0, 20 },
        { 0.0, "rArm", 0, 0, -20 }, { 0.3, "rArm", 0, 0, 10 }, { 0.6, "rArm", 0, 0, -20 },
        { 0.0, "head", 0, -15, 0 }, { 0.3, "head", 0, 15, 0 }, { 0.6, "head", 0, -15, 0 },
    }},
    attack = { duration = 0.5, looping = false, keyframes = {
        -- 手臂甩出攻击
        { 0.0, "lArm", 0, 0, 5 }, { 0.15, "lArm", -60, 0, -30 }, { 0.3, "lArm", 40, 0, 20 }, { 0.5, "lArm", 0, 0, 5 },
        { 0.0, "rArm", 0, 0, -5 }, { 0.15, "rArm", -60, 0, 30 }, { 0.3, "rArm", 40, 0, -20 }, { 0.5, "rArm", 0, 0, -5 },
        { 0.0, "pole", 0, 0, 0 }, { 0.15, "pole", -10, 0, 0 }, { 0.3, "pole", 15, 0, 0 }, { 0.5, "pole", 0, 0, 0 },
    }},
    hit = { duration = 0.3, looping = false, keyframes = {
        { 0.0, "pole", 0, 0, 0 }, { 0.08, "pole", 8, 0, -8 }, { 0.2, "pole", -4, 0, 4 }, { 0.3, "pole", 0, 0, 0 },
        { 0.0, "head", 0, 0, 5 }, { 0.1, "head", 0, 20, -10 }, { 0.3, "head", 0, 0, 5 },
    }},
    death = { duration = 1.2, looping = false, keyframes = {
        { 0.0, "pole", 0, 0, 0 }, { 0.4, "pole", 25, 0, 5 }, { 0.8, "pole", 60, 0, 10 }, { 1.2, "pole", 90, 0, 12 },
        { 0.0, "lArm", 0, 0, 5 }, { 0.6, "lArm", 0, 0, 40 }, { 1.2, "lArm", 0, 0, 60 },
        { 0.0, "rArm", 0, 0, -5 }, { 0.6, "rArm", 0, 0, -40 }, { 1.2, "rArm", 0, 0, -60 },
    }},
}

-- ==================== 骷髅 ====================
ANIMS.skeleton = {
    idle = { duration = 1.8, looping = true, keyframes = {
        { 0.0, "chest", -2, 0, 0 }, { 0.9, "chest", 2, 0, 0 }, { 1.8, "chest", -2, 0, 0 },
        { 0.0, "jaw", 0, 0, 0 }, { 0.6, "jaw", 5, 0, 0 }, { 1.2, "jaw", 0, 0, 0 }, { 1.8, "jaw", 0, 0, 0 },
        { 0.0, "lUpperArm", 0, 0, 8 }, { 0.9, "lUpperArm", 0, 0, 5 }, { 1.8, "lUpperArm", 0, 0, 8 },
        { 0.0, "rUpperArm", 0, 0, -8 }, { 0.9, "rUpperArm", 0, 0, -5 }, { 1.8, "rUpperArm", 0, 0, -8 },
    }},
    move = { duration = 0.55, looping = true, keyframes = {
        { 0.0, "lThigh", 30, 0, 0 }, { 0.275, "lThigh", -30, 0, 0 }, { 0.55, "lThigh", 30, 0, 0 },
        { 0.0, "rThigh", -30, 0, 0 }, { 0.275, "rThigh", 30, 0, 0 }, { 0.55, "rThigh", -30, 0, 0 },
        { 0.0, "lShin", -15, 0, 0 }, { 0.14, "lShin", -40, 0, 0 }, { 0.275, "lShin", -10, 0, 0 }, { 0.55, "lShin", -15, 0, 0 },
        { 0.0, "rShin", -10, 0, 0 }, { 0.275, "rShin", -15, 0, 0 }, { 0.41, "rShin", -40, 0, 0 }, { 0.55, "rShin", -10, 0, 0 },
        { 0.0, "lUpperArm", -25, 0, 8 }, { 0.275, "lUpperArm", 25, 0, 8 }, { 0.55, "lUpperArm", -25, 0, 8 },
        { 0.0, "rUpperArm", 25, 0, -8 }, { 0.275, "rUpperArm", -25, 0, -8 }, { 0.55, "rUpperArm", 25, 0, -8 },
        { 0.0, "chest", -3, 0, -2 }, { 0.275, "chest", -3, 0, 2 }, { 0.55, "chest", -3, 0, -2 },
    }},
    attack = { duration = 0.5, looping = false, keyframes = {
        { 0.0, "rUpperArm", 0, 0, -8 }, { 0.12, "rUpperArm", -110, -20, -15 }, { 0.28, "rUpperArm", 50, 30, 10 }, { 0.5, "rUpperArm", 0, 0, -8 },
        { 0.0, "rForeArm", 0, 0, 0 }, { 0.12, "rForeArm", -50, 0, 0 }, { 0.28, "rForeArm", 10, 0, 0 }, { 0.5, "rForeArm", 0, 0, 0 },
        { 0.0, "chest", 0, 0, 0 }, { 0.12, "chest", -5, -20, 0 }, { 0.28, "chest", 10, 25, 0 }, { 0.5, "chest", 0, 0, 0 },
        { 0.0, "jaw", 0, 0, 0 }, { 0.15, "jaw", 15, 0, 0 }, { 0.35, "jaw", 15, 0, 0 }, { 0.5, "jaw", 0, 0, 0 },
    }},
    hit = { duration = 0.3, looping = false, keyframes = {
        { 0.0, "chest", 0, 0, 0 }, { 0.08, "chest", 12, 0, 5 }, { 0.2, "chest", -5, 0, -2 }, { 0.3, "chest", 0, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.08, "head", 15, 10, 0 }, { 0.3, "head", 0, 0, 0 },
    }},
    death = { duration = 1.0, looping = false, keyframes = {
        { 0.0, "pelvis", 0, 0, 0 }, { 0.4, "pelvis", 15, 0, 10 }, { 0.7, "pelvis", 30, 0, 30 }, { 1.0, "pelvis", 40, 0, 80 },
        { 0.0, "chest", 0, 0, 0 }, { 0.3, "chest", 20, 0, 0 }, { 1.0, "chest", 35, 0, 0 },
        { 0.0, "lUpperArm", 0, 0, 8 }, { 0.5, "lUpperArm", 0, 0, 50 }, { 1.0, "lUpperArm", 0, 0, 70 },
        { 0.0, "rUpperArm", 0, 0, -8 }, { 0.5, "rUpperArm", 0, 0, -50 }, { 1.0, "rUpperArm", 0, 0, -70 },
        { 0.0, "head", 0, 0, 0 }, { 0.5, "head", 20, 0, 15 }, { 1.0, "head", 30, 0, 25 },
    }},
}

-- ==================== 蜘蛛 ====================
ANIMS.spider = {
    idle = { duration = 2.0, looping = true, keyframes = {
        { 0.0, "body", 0, 0, 0 }, { 1.0, "body", -2, 0, 0 }, { 2.0, "body", 0, 0, 0 },
        { 0.0, "abdomen", 0, 0, 0 }, { 1.0, "abdomen", 3, 0, 0 }, { 2.0, "abdomen", 0, 0, 0 },
    }},
    move = { duration = 0.4, looping = true, keyframes = {
        -- 8腿交替（简化：左1+右2+左3+右4 同组，另4腿反相）
        { 0.0, "leg1LUp", -15, 0, -30 }, { 0.2, "leg1LUp", 15, 0, -30 }, { 0.4, "leg1LUp", -15, 0, -30 },
        { 0.0, "leg2RUp", -15, 0, 30 }, { 0.2, "leg2RUp", 15, 0, 30 }, { 0.4, "leg2RUp", -15, 0, 30 },
        { 0.0, "leg3LUp", -15, 0, -30 }, { 0.2, "leg3LUp", 15, 0, -30 }, { 0.4, "leg3LUp", -15, 0, -30 },
        { 0.0, "leg4RUp", -15, 0, 30 }, { 0.2, "leg4RUp", 15, 0, 30 }, { 0.4, "leg4RUp", -15, 0, 30 },
        -- 反相组
        { 0.0, "leg1RUp", 15, 0, 30 }, { 0.2, "leg1RUp", -15, 0, 30 }, { 0.4, "leg1RUp", 15, 0, 30 },
        { 0.0, "leg2LUp", 15, 0, -30 }, { 0.2, "leg2LUp", -15, 0, -30 }, { 0.4, "leg2LUp", 15, 0, -30 },
        { 0.0, "leg3RUp", 15, 0, 30 }, { 0.2, "leg3RUp", -15, 0, 30 }, { 0.4, "leg3RUp", 15, 0, 30 },
        { 0.0, "leg4LUp", 15, 0, -30 }, { 0.2, "leg4LUp", -15, 0, -30 }, { 0.4, "leg4LUp", 15, 0, -30 },
        -- 身体轻微左右摇摆
        { 0.0, "body", 0, 0, -2 }, { 0.2, "body", 0, 0, 2 }, { 0.4, "body", 0, 0, -2 },
    }},
    attack = { duration = 0.4, looping = false, keyframes = {
        -- 前扑
        { 0.0, "body", 0, 0, 0 }, { 0.1, "body", -15, 0, 0 }, { 0.25, "body", 20, 0, 0 }, { 0.4, "body", 0, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.1, "head", 15, 0, 0 }, { 0.25, "head", -20, 0, 0 }, { 0.4, "head", 0, 0, 0 },
        { 0.0, "leg1LUp", 0, 0, -30 }, { 0.15, "leg1LUp", -40, 0, -50 }, { 0.4, "leg1LUp", 0, 0, -30 },
        { 0.0, "leg1RUp", 0, 0, 30 }, { 0.15, "leg1RUp", -40, 0, 50 }, { 0.4, "leg1RUp", 0, 0, 30 },
    }},
    hit = { duration = 0.25, looping = false, keyframes = {
        { 0.0, "body", 0, 0, 0 }, { 0.06, "body", 8, 5, 0 }, { 0.15, "body", -3, -3, 0 }, { 0.25, "body", 0, 0, 0 },
    }},
    death = { duration = 1.2, looping = false, keyframes = {
        -- 翻转倒下
        { 0.0, "body", 0, 0, 0 }, { 0.4, "body", 20, 0, 0 }, { 0.8, "body", 160, 0, 10 }, { 1.2, "body", 180, 0, 10 },
        { 0.0, "leg1LUp", 0, 0, -30 }, { 0.6, "leg1LUp", 30, 0, -60 }, { 1.2, "leg1LUp", 50, 0, -80 },
        { 0.0, "leg1RUp", 0, 0, 30 }, { 0.6, "leg1RUp", 30, 0, 60 }, { 1.2, "leg1RUp", 50, 0, 80 },
        { 0.0, "leg2LUp", 0, 0, -30 }, { 0.6, "leg2LUp", 25, 0, -55 }, { 1.2, "leg2LUp", 45, 0, -75 },
        { 0.0, "leg2RUp", 0, 0, 30 }, { 0.6, "leg2RUp", 25, 0, 55 }, { 1.2, "leg2RUp", 45, 0, 75 },
    }},
}

-- ==================== 半兽人 ====================
ANIMS.orc = {
    idle = { duration = 2.0, looping = true, keyframes = {
        { 0.0, "chest", -2, 0, 0 }, { 1.0, "chest", 2, 0, 0 }, { 2.0, "chest", -2, 0, 0 },
        { 0.0, "lUpperArm", 5, 0, 10 }, { 1.0, "lUpperArm", 5, 0, 7 }, { 2.0, "lUpperArm", 5, 0, 10 },
        { 0.0, "rUpperArm", 5, 0, -10 }, { 1.0, "rUpperArm", 5, 0, -7 }, { 2.0, "rUpperArm", 5, 0, -10 },
        { 0.0, "jaw", 0, 0, 0 }, { 0.8, "jaw", 3, 0, 0 }, { 1.6, "jaw", 0, 0, 0 }, { 2.0, "jaw", 0, 0, 0 },
    }},
    move = { duration = 0.6, looping = true, keyframes = {
        { 0.0, "lThigh", 28, 0, 0 }, { 0.3, "lThigh", -28, 0, 0 }, { 0.6, "lThigh", 28, 0, 0 },
        { 0.0, "rThigh", -28, 0, 0 }, { 0.3, "rThigh", 28, 0, 0 }, { 0.6, "rThigh", -28, 0, 0 },
        { 0.0, "lShin", -10, 0, 0 }, { 0.15, "lShin", -35, 0, 0 }, { 0.3, "lShin", -5, 0, 0 }, { 0.6, "lShin", -10, 0, 0 },
        { 0.0, "rShin", -5, 0, 0 }, { 0.3, "rShin", -10, 0, 0 }, { 0.45, "rShin", -35, 0, 0 }, { 0.6, "rShin", -5, 0, 0 },
        { 0.0, "lUpperArm", -20, 0, 10 }, { 0.3, "lUpperArm", 20, 0, 10 }, { 0.6, "lUpperArm", -20, 0, 10 },
        { 0.0, "rUpperArm", 20, 0, -10 }, { 0.3, "rUpperArm", -20, 0, -10 }, { 0.6, "rUpperArm", 20, 0, -10 },
        { 0.0, "chest", -5, 0, -3 }, { 0.3, "chest", -5, 0, 3 }, { 0.6, "chest", -5, 0, -3 },
    }},
    attack = { duration = 0.55, looping = false, keyframes = {
        -- 双手重击
        { 0.0, "chest", 0, 0, 0 }, { 0.15, "chest", -15, 0, 0 }, { 0.3, "chest", 20, 0, 0 }, { 0.55, "chest", 0, 0, 0 },
        { 0.0, "lUpperArm", 5, 0, 10 }, { 0.15, "lUpperArm", -100, 10, 20 }, { 0.3, "lUpperArm", 40, -5, 5 }, { 0.55, "lUpperArm", 5, 0, 10 },
        { 0.0, "rUpperArm", 5, 0, -10 }, { 0.15, "rUpperArm", -100, -10, -20 }, { 0.3, "rUpperArm", 40, 5, -5 }, { 0.55, "rUpperArm", 5, 0, -10 },
        { 0.0, "lForeArm", 0, 0, 0 }, { 0.15, "lForeArm", -60, 0, 0 }, { 0.3, "lForeArm", 10, 0, 0 }, { 0.55, "lForeArm", 0, 0, 0 },
        { 0.0, "rForeArm", 0, 0, 0 }, { 0.15, "rForeArm", -60, 0, 0 }, { 0.3, "rForeArm", 10, 0, 0 }, { 0.55, "rForeArm", 0, 0, 0 },
        { 0.0, "jaw", 0, 0, 0 }, { 0.2, "jaw", 12, 0, 0 }, { 0.4, "jaw", 12, 0, 0 }, { 0.55, "jaw", 0, 0, 0 },
    }},
    hit = { duration = 0.3, looping = false, keyframes = {
        { 0.0, "chest", 0, 0, 0 }, { 0.08, "chest", 12, 0, 6 }, { 0.2, "chest", -4, 0, -2 }, { 0.3, "chest", 0, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.08, "head", 10, 8, 0 }, { 0.3, "head", 0, 0, 0 },
    }},
    death = { duration = 1.0, looping = false, keyframes = {
        { 0.0, "pelvis", 0, 0, 0 }, { 0.3, "pelvis", 10, 0, 8 }, { 0.6, "pelvis", 25, 0, 40 }, { 1.0, "pelvis", 35, 0, 85 },
        { 0.0, "chest", 0, 0, 0 }, { 0.3, "chest", 15, 0, 0 }, { 1.0, "chest", 30, 0, 5 },
        { 0.0, "lUpperArm", 5, 0, 10 }, { 0.5, "lUpperArm", 5, 0, 45 }, { 1.0, "lUpperArm", 5, 0, 65 },
        { 0.0, "rUpperArm", 5, 0, -10 }, { 0.5, "rUpperArm", 5, 0, -45 }, { 1.0, "rUpperArm", 5, 0, -65 },
    }},
}

-- ============================================================================
-- 骨架构建
-- ============================================================================

--- 获取骨骼构建顺序（拓扑排序：先创建父节点）
local function getBuildOrder(boneDefs)
    local order = {}
    local added = {}
    local function addBone(name)
        if added[name] then return end
        local def = boneDefs[name]
        if def.parent and not added[def.parent] then
            addBone(def.parent)
        end
        table.insert(order, name)
        added[name] = true
    end
    for name, _ in pairs(boneDefs) do
        addBone(name)
    end
    return order
end

--- 创建怪物骨架，返回 bones 引用表和构建顺序
---@param parentNode Node
---@param monsterType string
---@return table bones, table buildOrder
function MonsterSkeleton.CreateSkeleton(parentNode, monsterType)
    local typeDef = MonsterSkeleton.TYPES[monsterType]
    if not typeDef then
        print("[MonsterSkeleton] Unknown type: " .. tostring(monsterType))
        return {}, {}
    end

    local boneDefs = typeDef.bones
    local color = typeDef.color
    local buildOrder = getBuildOrder(boneDefs)
    local bones = {}

    for _, name in ipairs(buildOrder) do
        local def = boneDefs[name]
        local pNode = def.parent and bones[def.parent] or parentNode

        local boneNode = pNode:CreateChild(name)
        boneNode.position = Vector3(def.pos[1], def.pos[2], def.pos[3])

        -- mesh 子节点
        local meshNode = boneNode:CreateChild(name .. "_mesh")
        if def.meshOffset then
            meshNode.position = Vector3(def.meshOffset[1], def.meshOffset[2], def.meshOffset[3])
        end
        meshNode.scale = Vector3(def.meshScale[1], def.meshScale[2], def.meshScale[3])

        local model = meshNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/" .. def.model .. ".mdl"))
        model:SetMaterial(CreatePBRMat(color, 0.6, 0.1))
        model.castShadows = true

        bones[name] = boneNode
    end

    return bones, buildOrder
end

-- ============================================================================
-- 动画播放
-- ============================================================================

--- 获取某骨骼在某时刻的旋转角度
local function getRotationAtTime(keyframes, boneName, t, duration, looping)
    local boneKFs = {}
    for _, kf in ipairs(keyframes) do
        if kf[2] == boneName then
            table.insert(boneKFs, kf)
        end
    end
    if #boneKFs == 0 then return nil end

    if looping then
        t = t % duration
    else
        t = math.min(t, duration)
    end

    local prevKF = boneKFs[1]
    local nextKF = boneKFs[#boneKFs]

    for i = 1, #boneKFs - 1 do
        if boneKFs[i][1] <= t and boneKFs[i + 1][1] >= t then
            prevKF = boneKFs[i]
            nextKF = boneKFs[i + 1]
            break
        end
    end

    local segDur = nextKF[1] - prevKF[1]
    local factor = 0
    if segDur > 0.001 then
        factor = (t - prevKF[1]) / segDur
    end
    factor = factor * factor * (3 - 2 * factor)  -- smooth step

    local rx = lerpAngle(prevKF[3], nextKF[3], factor)
    local ry = lerpAngle(prevKF[4], nextKF[4], factor)
    local rz = lerpAngle(prevKF[5], nextKF[5], factor)
    return rx, ry, rz
end

--- 更新怪物动画
---@param animData table {type, state, elapsed, bones, buildOrder}
---@param dt number
---@param isMoving boolean
function MonsterSkeleton.UpdateAnimation(animData, dt, isMoving)
    local typeAnims = ANIMS[animData.type]
    if not typeAnims then return end

    -- 自动切换 idle/move
    if animData.state == "idle" and isMoving then
        animData.state = "move"
        animData.elapsed = 0
    elseif animData.state == "move" and not isMoving then
        animData.state = "idle"
        animData.elapsed = 0
    end

    local anim = typeAnims[animData.state]
    if not anim then
        anim = typeAnims.idle
        if not anim then return end
    end

    animData.elapsed = animData.elapsed + dt

    -- 非循环动画结束 → 回到 idle
    if not anim.looping and animData.elapsed >= anim.duration then
        if animData.onComplete then
            animData.onComplete()
            animData.onComplete = nil
        end
        animData.state = isMoving and "move" or "idle"
        animData.elapsed = 0
        anim = typeAnims[animData.state]
    end

    -- 应用关键帧
    for _, boneName in ipairs(animData.buildOrder) do
        local node = animData.bones[boneName]
        if node then
            local rx, ry, rz = getRotationAtTime(anim.keyframes, boneName, animData.elapsed, anim.duration, anim.looping)
            if rx then
                node.rotation = Quaternion(rx, ry, rz)
            end
        end
    end
end

--- 播放指定动画（attack/hit/death）
function MonsterSkeleton.PlayAnim(animData, state, onComplete)
    animData.state = state
    animData.elapsed = 0
    animData.onComplete = onComplete
end

--- 获取动画时长
function MonsterSkeleton.GetAnimDuration(monsterType, state)
    local typeAnims = ANIMS[monsterType]
    if not typeAnims or not typeAnims[state] then return 0.5 end
    return typeAnims[state].duration
end

return MonsterSkeleton
