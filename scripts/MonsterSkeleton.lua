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

-- 纹理贴图材质（国风水墨风）
local function CreateTexPBRMat(texPath, roughness, metallic, tint)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRMetallicRoughDiffNormalSpec.xml"))
    local tex = cache:GetResource("Texture2D", texPath)
    if tex then
        mat:SetTexture(TU_DIFFUSE, tex)
    end
    mat:SetShaderParameter("MatDiffColor", Variant(tint or Color(1.0, 1.0, 1.0, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.7))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    return mat
end

-- 怪物贴图映射表（国风水墨风纹理）
local MONSTER_TEXTURES = {
    deer      = "image/tex_ink_deer_20260611072330.png",
    scarecrow = "image/tex_ink_scarecrow_20260611072358.png",
    skeleton  = "image/tex_ink_skeleton_20260611072341.png",
    spider    = "image/tex_ink_spider_20260611072322.png",
    orc       = "image/tex_ink_orc_20260611072339.png",
}

-- 精细整模怪物映射：用于替换几何占位外观。
-- deer 先使用稳定可见的静态精细模型；失败的实验性四足 rig 不再接入游戏。
local MODEL_MONSTERS = {
    deer = {
        modelPath = "Meshes/Deer.mdl",
        materialPath = "Materials/Deer_00_tripo_material_a5521383-f99e-4428-ad84-9a42af4c67f7.xml",
        parentBone = nil,
        position = Vector3(0, 0.90, 0),
        scale = Vector3(0.75, 0.75, 0.75),
        hideProceduralBones = true,
    },
    scarecrow = {
        modelPath = "Meshes/Scarecrow.mdl",
        materialPath = "Materials/Scarecrow_00_tripo_material_e400aa55-aa4f-4418-b012-55dcbca19119.xml",
        parentBone = nil,
        position = Vector3(0, 0.90, 0),
        scale = Vector3(0.80, 0.80, 0.80),
        hideProceduralBones = true,
    },
    qilin = {
        modelPath = "Meshes/Qilin.mdl",
        materialPath = "Materials/Qilin_00_tripo_material_5c1ff8c2-9635-4910-924c-b2eca2720248.xml",
        parentBone = nil,
        position = Vector3(0, 0.75, 0),
        scale = Vector3(1.00, 1.00, 1.00),
    },
    qicheng_child = {
        modelPath = "uuid://CVcMGYMLqs_9uIbIf5pIVsaw",
        materialPath = "uuid://D5sC-fSeVJxxXl3QNDcZJMtF",
        position = Vector3.ZERO,
        targetHeight = 1.65,
        hideProceduralBones = true,
        modelAnim = "humanoid_fast",
    },
    mech_humanoid = {
        modelPath = "uuid://ARoaobEzRVktIvNfBEsDPWeQ",
        materialPaths = {
            "uuid://HGmRkQOrSpS8cu-K8FI-8msZ",
            "uuid://Gj7zUe5UOfnJv9QnKgg509CS",
            "uuid://FLvnwcKkp4zkPbadPyW1HjJN",
            "uuid://GFL9qXVIK62TKlaqTgBC_WpH",
            "uuid://GEo6ERJkWuWtd6uEwoFnwuZP",
            "uuid://GEHXGaxNHNk_ULpAcdUb_asm",
            "uuid://CzXTIebN83FSkQOWhRE31sVH",
        },
        position = Vector3.ZERO,
        targetHeight = 1.85,
        hideProceduralBones = true,
        modelAnim = "heavy_mech",
    },
}

local function CreateModelVisual(parentNode, bones, monsterType)
    local modelDef = MODEL_MONSTERS[monsterType]
    if not modelDef then return nil end

    local attachNode = modelDef.parentBone and bones[modelDef.parentBone] or parentNode
    local visualNode = attachNode:CreateChild(monsterType .. "_model")
    visualNode.position = modelDef.position or Vector3.ZERO
    visualNode.scale = modelDef.scale or Vector3(1, 1, 1)

    local model = cache:GetResource("Model", modelDef.modelPath)
    if not model then
        print("[MonsterSkeleton] Missing monster model: " .. modelDef.modelPath)
        return nil
    end

    local isAnimatedModel = modelDef.modelAnim ~= nil or modelDef.animated == true
    local modelComponent = nil
    if isAnimatedModel then
        modelComponent = visualNode:CreateComponent("AnimatedModel")
    else
        modelComponent = visualNode:CreateComponent("StaticModel")
    end
    modelComponent:SetModel(model)

    if modelDef.targetHeight then
        local bb = modelComponent.boundingBox
        local h = bb.size.y
        if h > 0 then
            local s = modelDef.targetHeight / h
            visualNode.scale = Vector3(s, s, s)
            visualNode.position = (modelDef.position or Vector3.ZERO) + Vector3(0, -bb.min.y * s, 0)
        end
    end

    if modelDef.materialPaths then
        for i, matPath in ipairs(modelDef.materialPaths) do
            local material = cache:GetResource("Material", matPath)
            if material then
                modelComponent:SetMaterial(i - 1, material)
            end
        end
    elseif modelDef.materialPath then
        local material = cache:GetResource("Material", modelDef.materialPath)
        if material then
            modelComponent:SetMaterial(material)
        else
            print("[MonsterSkeleton] Missing monster material: " .. modelDef.materialPath)
        end
    end

    modelComponent.castShadows = true

    local animCtrl = nil
    if isAnimatedModel then
        animCtrl = visualNode:GetComponent("AnimationController")
            or visualNode:GetComponent("AnimationController", true)
        if not animCtrl then
            animCtrl = visualNode:CreateComponent("AnimationController")
        end
    end

    print("[MonsterSkeleton] Loaded model monster: " .. monsterType .. " -> " .. modelDef.modelPath)
    return {
        node = visualNode,
        component = modelComponent,
        animCtrl = animCtrl,
        animated = isAnimatedModel,
        modelAnim = modelDef.modelAnim,
        currentAnim = nil,
        overlayTimer = 0,
        baseScale = visualNode.scale,
        basePosition = visualNode.position,
    }
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

-- 骷髅：极瘦人形，大头骨+明显关节球+肋骨框架+持剑手
local BONES_SKELETON = {
    pelvis   = { parent = nil,          pos = {0, 0.45, 0},    meshScale = {0.20, 0.08, 0.12}, model = "Box" },
    spine    = { parent = "pelvis",     pos = {0, 0.08, 0},    meshScale = {0.04, 0.16, 0.04}, model = "Cylinder", meshOffset = {0, 0.08, 0} },
    -- 肋骨（左右各2条横档）
    rib1L    = { parent = "spine",      pos = {-0.02, 0.14, 0}, meshScale = {0.12, 0.025, 0.06}, model = "Cylinder" },
    rib1R    = { parent = "spine",      pos = {0.02, 0.14, 0},  meshScale = {0.12, 0.025, 0.06}, model = "Cylinder" },
    rib2L    = { parent = "spine",      pos = {-0.02, 0.08, 0}, meshScale = {0.10, 0.025, 0.05}, model = "Cylinder" },
    rib2R    = { parent = "spine",      pos = {0.02, 0.08, 0},  meshScale = {0.10, 0.025, 0.05}, model = "Cylinder" },
    chest    = { parent = "spine",      pos = {0, 0.18, 0},    meshScale = {0.24, 0.06, 0.10}, model = "Box" },
    neck     = { parent = "chest",      pos = {0, 0.05, 0},    meshScale = {0.035, 0.07, 0.035}, model = "Cylinder", meshOffset = {0, 0.035, 0} },
    -- 大头骨（椭圆形更像骷髅）
    head     = { parent = "neck",       pos = {0, 0.09, 0},    meshScale = {0.20, 0.24, 0.20}, model = "Sphere" },
    -- 眼眶用两个小黑球表示（通过 colorOverride）
    eyeL     = { parent = "head",       pos = {-0.06, 0.02, 0.08}, meshScale = {0.04, 0.04, 0.03}, model = "Sphere", colorOverride = Color(0.1, 0.05, 0.05, 1.0) },
    eyeR     = { parent = "head",       pos = {0.06, 0.02, 0.08},  meshScale = {0.04, 0.04, 0.03}, model = "Sphere", colorOverride = Color(0.1, 0.05, 0.05, 1.0) },
    jaw      = { parent = "head",       pos = {0, -0.10, 0.05}, meshScale = {0.14, 0.06, 0.10}, model = "Box" },
    -- 左臂（极细+关节球）
    lShoulder = { parent = "chest",     pos = {-0.16, 0, 0},    meshScale = {0.06, 0.06, 0.06}, model = "Sphere" },
    lUpperArm = { parent = "lShoulder", pos = {0, -0.02, 0},    meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    lElbow    = { parent = "lUpperArm", pos = {0, -0.18, 0},    meshScale = {0.045, 0.045, 0.045}, model = "Sphere" },
    lForeArm  = { parent = "lElbow",    pos = {0, -0.02, 0},    meshScale = {0.025, 0.16, 0.025}, model = "Cylinder", meshOffset = {0, -0.08, 0} },
    lHand     = { parent = "lForeArm",  pos = {0, -0.16, 0},    meshScale = {0.05, 0.03, 0.06}, model = "Box" },
    -- 右臂（持武器）
    rShoulder = { parent = "chest",     pos = {0.16, 0, 0},     meshScale = {0.06, 0.06, 0.06}, model = "Sphere" },
    rUpperArm = { parent = "rShoulder", pos = {0, -0.02, 0},    meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    rElbow    = { parent = "rUpperArm", pos = {0, -0.18, 0},    meshScale = {0.045, 0.045, 0.045}, model = "Sphere" },
    rForeArm  = { parent = "rElbow",    pos = {0, -0.02, 0},    meshScale = {0.025, 0.16, 0.025}, model = "Cylinder", meshOffset = {0, -0.08, 0} },
    rHand     = { parent = "rForeArm",  pos = {0, -0.16, 0},    meshScale = {0.05, 0.03, 0.06}, model = "Box" },
    -- 右手持剑（细长刀刃）
    sword     = { parent = "rHand",     pos = {0, -0.02, 0},    meshScale = {0.02, 0.28, 0.005}, model = "Box", colorOverride = Color(0.6, 0.6, 0.7, 1.0) },
    -- 左腿（关节球）
    lHip      = { parent = "pelvis",    pos = {-0.08, -0.02, 0}, meshScale = {0.05, 0.05, 0.05}, model = "Sphere" },
    lThigh   = { parent = "lHip",       pos = {0, -0.02, 0},    meshScale = {0.035, 0.20, 0.035}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    lKnee    = { parent = "lThigh",     pos = {0, -0.20, 0},    meshScale = {0.045, 0.045, 0.045}, model = "Sphere" },
    lShin    = { parent = "lKnee",      pos = {0, -0.02, 0},    meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    lFoot    = { parent = "lShin",      pos = {0, -0.18, 0.02}, meshScale = {0.05, 0.025, 0.10}, model = "Box" },
    -- 右腿
    rHip      = { parent = "pelvis",    pos = {0.08, -0.02, 0},  meshScale = {0.05, 0.05, 0.05}, model = "Sphere" },
    rThigh   = { parent = "rHip",       pos = {0, -0.02, 0},    meshScale = {0.035, 0.20, 0.035}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    rKnee    = { parent = "rThigh",     pos = {0, -0.20, 0},    meshScale = {0.045, 0.045, 0.045}, model = "Sphere" },
    rShin    = { parent = "rKnee",      pos = {0, -0.02, 0},    meshScale = {0.03, 0.18, 0.03}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    rFoot    = { parent = "rShin",      pos = {0, -0.18, 0.02}, meshScale = {0.05, 0.025, 0.10}, model = "Box" },
}

-- 蜘蛛：小头胸(body) + 巨大圆腹(abdomen) + 8条细长腿
local BONES_SPIDER = {
    -- 头胸部（cephalothorax）— 较小扁平
    body     = { parent = nil,      pos = {0, 0.25, 0},     meshScale = {0.20, 0.12, 0.22}, model = "Sphere" },
    -- 头部 — 很小，紧贴头胸部前方
    head     = { parent = "body",   pos = {0, 0.02, 0.14},  meshScale = {0.10, 0.08, 0.10}, model = "Sphere" },
    -- 螯肢（两个小突起在头前方）
    fangL    = { parent = "head",   pos = {-0.04, -0.02, 0.06}, meshScale = {0.025, 0.05, 0.02}, model = "Cylinder" },
    fangR    = { parent = "head",   pos = {0.04, -0.02, 0.06},  meshScale = {0.025, 0.05, 0.02}, model = "Cylinder" },
    -- 腹部（abdomen）— 蜘蛛特征：非常大、圆鼓鼓的
    abdomen  = { parent = "body",   pos = {0, 0.02, -0.28}, meshScale = {0.34, 0.30, 0.40}, model = "Sphere" },
    -- 左侧4腿（从前到后，腿更长、更细）
    leg1LUp  = { parent = "body",   pos = {-0.12, 0.02, 0.10},  meshScale = {0.025, 0.22, 0.025}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg1LLo  = { parent = "leg1LUp", pos = {0, -0.22, 0},    meshScale = {0.02, 0.22, 0.02}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg2LUp  = { parent = "body",   pos = {-0.14, 0.02, 0.03},  meshScale = {0.025, 0.22, 0.025}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg2LLo  = { parent = "leg2LUp", pos = {0, -0.22, 0},    meshScale = {0.02, 0.22, 0.02}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg3LUp  = { parent = "body",   pos = {-0.14, 0.02, -0.04}, meshScale = {0.025, 0.22, 0.025}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg3LLo  = { parent = "leg3LUp", pos = {0, -0.22, 0},    meshScale = {0.02, 0.22, 0.02}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg4LUp  = { parent = "body",   pos = {-0.12, 0.02, -0.10}, meshScale = {0.025, 0.22, 0.025}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg4LLo  = { parent = "leg4LUp", pos = {0, -0.22, 0},    meshScale = {0.02, 0.22, 0.02}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    -- 右侧4腿
    leg1RUp  = { parent = "body",   pos = {0.12, 0.02, 0.10},   meshScale = {0.025, 0.22, 0.025}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg1RLo  = { parent = "leg1RUp", pos = {0, -0.22, 0},    meshScale = {0.02, 0.22, 0.02}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg2RUp  = { parent = "body",   pos = {0.14, 0.02, 0.03},   meshScale = {0.025, 0.22, 0.025}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg2RLo  = { parent = "leg2RUp", pos = {0, -0.22, 0},    meshScale = {0.02, 0.22, 0.02}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg3RUp  = { parent = "body",   pos = {0.14, 0.02, -0.04},  meshScale = {0.025, 0.22, 0.025}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg3RLo  = { parent = "leg3RUp", pos = {0, -0.22, 0},    meshScale = {0.02, 0.22, 0.02}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg4RUp  = { parent = "body",   pos = {0.12, 0.02, -0.10},  meshScale = {0.025, 0.22, 0.025}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    leg4RLo  = { parent = "leg4RUp", pos = {0, -0.22, 0},    meshScale = {0.02, 0.22, 0.02}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
}

-- 半兽人：驼背粗壮兽人，突出下颌+獠牙+耳朵+持棍棒，腿短臂长
local BONES_ORC = {
    pelvis   = { parent = nil,          pos = {0, 0.50, 0},    meshScale = {0.34, 0.16, 0.24}, model = "Box" },
    -- 驼背脊椎（前倾）
    spine    = { parent = "pelvis",     pos = {0, 0.12, -0.04}, meshScale = {0.14, 0.12, 0.16}, model = "Cylinder", meshOffset = {0, 0.06, 0} },
    chest    = { parent = "spine",      pos = {0, 0.14, -0.02}, meshScale = {0.44, 0.30, 0.30}, model = "Box" },
    -- 厚实的脖子
    neck     = { parent = "chest",      pos = {0, 0.14, 0.04},  meshScale = {0.14, 0.10, 0.14}, model = "Cylinder" },
    -- 扁平大头（更兽性）
    head     = { parent = "neck",       pos = {0, 0.10, 0.03},  meshScale = {0.26, 0.20, 0.24}, model = "Sphere" },
    -- 突出的大下巴
    jaw      = { parent = "head",       pos = {0, -0.10, 0.10}, meshScale = {0.20, 0.08, 0.14}, model = "Box" },
    -- 獠牙（两颗从下巴向上突出）
    tuskL    = { parent = "jaw",        pos = {-0.06, 0.06, 0.05}, meshScale = {0.025, 0.08, 0.025}, model = "Cylinder", colorOverride = Color(0.95, 0.92, 0.80, 1.0) },
    tuskR    = { parent = "jaw",        pos = {0.06, 0.06, 0.05},  meshScale = {0.025, 0.08, 0.025}, model = "Cylinder", colorOverride = Color(0.95, 0.92, 0.80, 1.0) },
    -- 尖耳朵
    earL     = { parent = "head",       pos = {-0.14, 0.05, 0},  meshScale = {0.04, 0.08, 0.06}, model = "Box" },
    earR     = { parent = "head",       pos = {0.14, 0.05, 0},   meshScale = {0.04, 0.08, 0.06}, model = "Box" },
    -- 小眼睛（红色凶光）
    eyeL     = { parent = "head",       pos = {-0.07, 0.04, 0.10}, meshScale = {0.035, 0.03, 0.02}, model = "Sphere", colorOverride = Color(0.8, 0.15, 0.05, 1.0) },
    eyeR     = { parent = "head",       pos = {0.07, 0.04, 0.10},  meshScale = {0.035, 0.03, 0.02}, model = "Sphere", colorOverride = Color(0.8, 0.15, 0.05, 1.0) },
    -- 左臂（极粗，长臂猿比例）
    lUpperArm = { parent = "chest",     pos = {-0.28, 0.10, 0}, meshScale = {0.12, 0.22, 0.12}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    lForeArm  = { parent = "lUpperArm", pos = {0, -0.22, 0},    meshScale = {0.10, 0.20, 0.10}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    lHand     = { parent = "lForeArm",  pos = {0, -0.20, 0},    meshScale = {0.12, 0.07, 0.12}, model = "Box" },
    -- 右臂（持棍棒）
    rUpperArm = { parent = "chest",     pos = {0.28, 0.10, 0},  meshScale = {0.12, 0.22, 0.12}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    rForeArm  = { parent = "rUpperArm", pos = {0, -0.22, 0},    meshScale = {0.10, 0.20, 0.10}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    rHand     = { parent = "rForeArm",  pos = {0, -0.20, 0},    meshScale = {0.12, 0.07, 0.12}, model = "Box" },
    -- 棍棒武器
    club      = { parent = "rHand",     pos = {0, -0.04, 0},    meshScale = {0.05, 0.35, 0.05}, model = "Cylinder", colorOverride = Color(0.35, 0.25, 0.15, 1.0) },
    clubHead  = { parent = "club",      pos = {0, -0.18, 0},    meshScale = {0.10, 0.10, 0.10}, model = "Sphere", colorOverride = Color(0.30, 0.22, 0.12, 1.0) },
    -- 左腿（短粗）
    lThigh   = { parent = "pelvis",     pos = {-0.13, -0.06, 0}, meshScale = {0.12, 0.18, 0.12}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    lShin    = { parent = "lThigh",     pos = {0, -0.18, 0},     meshScale = {0.10, 0.16, 0.10}, model = "Cylinder", meshOffset = {0, -0.08, 0} },
    lFoot    = { parent = "lShin",      pos = {0, -0.16, 0.04},  meshScale = {0.12, 0.05, 0.16}, model = "Box" },
    -- 右腿
    rThigh   = { parent = "pelvis",     pos = {0.13, -0.06, 0},  meshScale = {0.12, 0.18, 0.12}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    rShin    = { parent = "rThigh",     pos = {0, -0.18, 0},     meshScale = {0.10, 0.16, 0.10}, model = "Cylinder", meshOffset = {0, -0.08, 0} },
    rFoot    = { parent = "rShin",      pos = {0, -0.16, 0.04},  meshScale = {0.12, 0.05, 0.16}, model = "Box" },
}

-- 石魔/巨人：巨大人形，粗壮圆柱体躯干+巨大拳头+短腿
local BONES_GOLEM = {
    pelvis   = { parent = nil,          pos = {0, 0.70, 0},    meshScale = {0.50, 0.25, 0.40}, model = "Box" },
    spine    = { parent = "pelvis",     pos = {0, 0.18, 0},    meshScale = {0.22, 0.20, 0.22}, model = "Cylinder", meshOffset = {0, 0.10, 0} },
    chest    = { parent = "spine",      pos = {0, 0.22, 0},    meshScale = {0.65, 0.45, 0.50}, model = "Box" },
    neck     = { parent = "chest",      pos = {0, 0.22, 0.05}, meshScale = {0.18, 0.12, 0.18}, model = "Cylinder" },
    head     = { parent = "neck",       pos = {0, 0.12, 0.02}, meshScale = {0.34, 0.28, 0.30}, model = "Sphere" },
    -- 小眼睛（红色发光）
    eyeL     = { parent = "head",       pos = {-0.09, 0.04, 0.12}, meshScale = {0.05, 0.04, 0.03}, model = "Sphere", colorOverride = Color(0.9, 0.2, 0.05, 1.0) },
    eyeR     = { parent = "head",       pos = {0.09, 0.04, 0.12},  meshScale = {0.05, 0.04, 0.03}, model = "Sphere", colorOverride = Color(0.9, 0.2, 0.05, 1.0) },
    -- 左臂（极粗壮）
    lUpperArm = { parent = "chest",     pos = {-0.40, 0.12, 0}, meshScale = {0.16, 0.30, 0.16}, model = "Cylinder", meshOffset = {0, -0.15, 0} },
    lForeArm  = { parent = "lUpperArm", pos = {0, -0.30, 0},    meshScale = {0.14, 0.28, 0.14}, model = "Cylinder", meshOffset = {0, -0.14, 0} },
    lFist     = { parent = "lForeArm",  pos = {0, -0.28, 0},    meshScale = {0.20, 0.18, 0.20}, model = "Sphere" },
    -- 右臂
    rUpperArm = { parent = "chest",     pos = {0.40, 0.12, 0},  meshScale = {0.16, 0.30, 0.16}, model = "Cylinder", meshOffset = {0, -0.15, 0} },
    rForeArm  = { parent = "rUpperArm", pos = {0, -0.30, 0},    meshScale = {0.14, 0.28, 0.14}, model = "Cylinder", meshOffset = {0, -0.14, 0} },
    rFist     = { parent = "rForeArm",  pos = {0, -0.28, 0},    meshScale = {0.20, 0.18, 0.20}, model = "Sphere" },
    -- 肩甲（装饰性石块）
    lShoulder = { parent = "chest",     pos = {-0.38, 0.25, 0}, meshScale = {0.20, 0.12, 0.18}, model = "Box", colorOverride = Color(0.3, 0.3, 0.28, 1.0) },
    rShoulder = { parent = "chest",     pos = {0.38, 0.25, 0},  meshScale = {0.20, 0.12, 0.18}, model = "Box", colorOverride = Color(0.3, 0.3, 0.28, 1.0) },
    -- 短粗腿
    lThigh   = { parent = "pelvis",     pos = {-0.18, -0.10, 0}, meshScale = {0.16, 0.22, 0.16}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    lShin    = { parent = "lThigh",     pos = {0, -0.22, 0},     meshScale = {0.14, 0.20, 0.14}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    lFoot    = { parent = "lShin",      pos = {0, -0.20, 0.04},  meshScale = {0.18, 0.08, 0.22}, model = "Box" },
    rThigh   = { parent = "pelvis",     pos = {0.18, -0.10, 0},  meshScale = {0.16, 0.22, 0.16}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    rShin    = { parent = "rThigh",     pos = {0, -0.22, 0},     meshScale = {0.14, 0.20, 0.14}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    rFoot    = { parent = "rShin",      pos = {0, -0.20, 0.04},  meshScale = {0.18, 0.08, 0.22}, model = "Box" },
}

-- 巨蟒/骨龙：蛇形身体（多节连续圆柱），无腿，头部有角/獠牙
local BONES_SERPENT = {
    -- 身体分6段，模拟蛇形蜿蜒
    seg1     = { parent = nil,       pos = {0, 0.40, 0},     meshScale = {0.28, 0.25, 0.35}, model = "Sphere" },
    seg2     = { parent = "seg1",    pos = {0, 0.02, -0.30}, meshScale = {0.30, 0.28, 0.35}, model = "Sphere" },
    seg3     = { parent = "seg2",    pos = {0, 0.02, -0.30}, meshScale = {0.32, 0.30, 0.35}, model = "Sphere" },  -- 最粗段
    seg4     = { parent = "seg3",    pos = {0, 0, -0.30},    meshScale = {0.28, 0.26, 0.32}, model = "Sphere" },
    seg5     = { parent = "seg4",    pos = {0, -0.02, -0.28}, meshScale = {0.22, 0.22, 0.28}, model = "Sphere" },
    tail     = { parent = "seg5",    pos = {0, -0.02, -0.26}, meshScale = {0.14, 0.14, 0.30}, model = "Cylinder" },
    -- 颈部（从第一段向上抬起）
    neck     = { parent = "seg1",    pos = {0, 0.15, 0.20},  meshScale = {0.16, 0.25, 0.16}, model = "Cylinder", meshOffset = {0, 0.12, 0} },
    -- 头部（大且扁平的蛇头/龙头）
    head     = { parent = "neck",    pos = {0, 0.22, 0.08},  meshScale = {0.30, 0.18, 0.35}, model = "Box" },
    -- 上颌突起
    snout    = { parent = "head",    pos = {0, 0.02, 0.18},  meshScale = {0.18, 0.10, 0.14}, model = "Box" },
    -- 下颌
    jaw      = { parent = "head",    pos = {0, -0.10, 0.10}, meshScale = {0.22, 0.06, 0.20}, model = "Box" },
    -- 獠牙
    fangL    = { parent = "jaw",     pos = {-0.06, -0.02, 0.10}, meshScale = {0.025, 0.08, 0.025}, model = "Cylinder", colorOverride = Color(0.95, 0.92, 0.80, 1.0) },
    fangR    = { parent = "jaw",     pos = {0.06, -0.02, 0.10},  meshScale = {0.025, 0.08, 0.025}, model = "Cylinder", colorOverride = Color(0.95, 0.92, 0.80, 1.0) },
    -- 头顶双角
    hornL    = { parent = "head",    pos = {-0.10, 0.10, -0.04}, meshScale = {0.035, 0.16, 0.035}, model = "Cylinder", colorOverride = Color(0.25, 0.22, 0.20, 1.0) },
    hornR    = { parent = "head",    pos = {0.10, 0.10, -0.04},  meshScale = {0.035, 0.16, 0.035}, model = "Cylinder", colorOverride = Color(0.25, 0.22, 0.20, 1.0) },
    -- 眼睛（黄色凶光）
    eyeL     = { parent = "head",    pos = {-0.10, 0.05, 0.12}, meshScale = {0.05, 0.04, 0.03}, model = "Sphere", colorOverride = Color(0.95, 0.75, 0.1, 1.0) },
    eyeR     = { parent = "head",    pos = {0.10, 0.05, 0.12},  meshScale = {0.05, 0.04, 0.03}, model = "Sphere", colorOverride = Color(0.95, 0.75, 0.1, 1.0) },
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
    golem = {
        name = "石魔", bones = BONES_GOLEM,
        color = Color(0.40, 0.38, 0.35, 1.0),  -- 岩石灰
        scale = 1.0, heightOffset = 0,
    },
    serpent = {
        name = "巨蟒", bones = BONES_SERPENT,
        color = Color(0.25, 0.35, 0.20, 1.0),  -- 暗绿蛇皮
        scale = 1.0, heightOffset = 0,
    },
    qilin = {
        name = "麒麟", bones = BONES_DEER,
        color = Color(0.70, 0.55, 0.25, 1.0),  -- 金色神兽
        scale = 1.25, heightOffset = 0,
    },
    qicheng_child = {
        name = "奇城之子", bones = BONES_ORC,
        color = Color(0.35, 0.42, 0.50, 1.0),
        scale = 1.0, heightOffset = 0,
    },
    mech_humanoid = {
        name = "机械人形", bones = BONES_GOLEM,
        color = Color(0.38, 0.40, 0.42, 1.0),
        scale = 1.05, heightOffset = 0,
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
    move = { duration = 0.6, looping = true, keyframes = {
        -- 四足对角步态：左前+右后一组，右前+左后一组，避免整只怪物僵硬滑行
        { 0.0, "lFrontUp", 35, 0, 0 }, { 0.30, "lFrontUp", -30, 0, 0 }, { 0.60, "lFrontUp", 35, 0, 0 },
        { 0.0, "lFrontLo", -35, 0, 0 }, { 0.15, "lFrontLo", -55, 0, 0 }, { 0.30, "lFrontLo", -12, 0, 0 }, { 0.60, "lFrontLo", -35, 0, 0 },
        { 0.0, "rBackUp", 30, 0, 0 }, { 0.30, "rBackUp", -28, 0, 0 }, { 0.60, "rBackUp", 30, 0, 0 },
        { 0.0, "rBackLo", -32, 0, 0 }, { 0.15, "rBackLo", -50, 0, 0 }, { 0.30, "rBackLo", -12, 0, 0 }, { 0.60, "rBackLo", -32, 0, 0 },

        { 0.0, "rFrontUp", -30, 0, 0 }, { 0.30, "rFrontUp", 35, 0, 0 }, { 0.60, "rFrontUp", -30, 0, 0 },
        { 0.0, "rFrontLo", -12, 0, 0 }, { 0.30, "rFrontLo", -35, 0, 0 }, { 0.45, "rFrontLo", -55, 0, 0 }, { 0.60, "rFrontLo", -12, 0, 0 },
        { 0.0, "lBackUp", -28, 0, 0 }, { 0.30, "lBackUp", 30, 0, 0 }, { 0.60, "lBackUp", -28, 0, 0 },
        { 0.0, "lBackLo", -12, 0, 0 }, { 0.30, "lBackLo", -32, 0, 0 }, { 0.45, "lBackLo", -50, 0, 0 }, { 0.60, "lBackLo", -12, 0, 0 },

        -- 身体低幅上下/左右摆动，保持四足着地感
        { 0.0, "body", -2, 0, -2 }, { 0.30, "body", -4, 0, 2 }, { 0.60, "body", -2, 0, -2 },
        { 0.0, "neck", 6, 0, 0 }, { 0.30, "neck", 2, 0, 0 }, { 0.60, "neck", 6, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.30, "head", -3, 0, 0 }, { 0.60, "head", 0, 0, 0 },
    }},
    attack = { duration = 0.6, looping = false, keyframes = {
        -- 低头冲撞
        { 0.0, "neck", 10, 0, 0 }, { 0.15, "neck", -30, 0, 0 }, { 0.35, "neck", 40, 0, 0 }, { 0.6, "neck", 10, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.15, "head", 20, 0, 0 }, { 0.35, "head", -15, 0, 0 }, { 0.6, "head", 0, 0, 0 },
        { 0.0, "body", 0, 0, 0 }, { 0.2, "body", -15, 0, 0 }, { 0.4, "body", 10, 0, 0 }, { 0.6, "body", 0, 0, 0 },
    }},
    hit = { duration = 0.4, looping = false, keyframes = {
        { 0.0, "body", 0, 0, 0 }, { 0.06, "body", 20, 0, 12 }, { 0.15, "body", -10, 0, -8 }, { 0.28, "body", 5, 0, 3 }, { 0.4, "body", 0, 0, 0 },
        { 0.0, "neck", 10, 0, 0 }, { 0.06, "neck", 40, 5, 0 }, { 0.2, "neck", 5, -3, 0 }, { 0.4, "neck", 10, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.06, "head", 15, 10, 0 }, { 0.2, "head", -5, -5, 0 }, { 0.4, "head", 0, 0, 0 },
    }},
    death = { duration = 1.0, looping = false, keyframes = {
        { 0.0, "body", 0, 0, 0 }, { 0.3, "body", 10, 0, 40 }, { 0.7, "body", 15, 0, 80 }, { 1.0, "body", 20, 0, 90 },
        { 0.0, "neck", 10, 0, 0 }, { 0.5, "neck", 30, 0, 0 }, { 1.0, "neck", 45, 0, 0 },
        { 0.0, "lFrontUp", 0, 0, 0 }, { 0.5, "lFrontUp", -10, 0, 30 }, { 1.0, "lFrontUp", -20, 0, 50 },
        { 0.0, "rFrontUp", 0, 0, 0 }, { 0.5, "rFrontUp", 15, 0, -20 }, { 1.0, "rFrontUp", 20, 0, -40 },
    }},
}

-- 麒麟：四足神兽，复用鹿的对角步态，保持四肢着地移动
ANIMS.qilin = ANIMS.deer

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
    hit = { duration = 0.4, looping = false, keyframes = {
        { 0.0, "pole", 0, 0, 0 }, { 0.06, "pole", 18, 0, -15 }, { 0.15, "pole", -8, 0, 10 }, { 0.28, "pole", 3, 0, -3 }, { 0.4, "pole", 0, 0, 0 },
        { 0.0, "head", 0, 0, 5 }, { 0.06, "head", 10, 30, -15 }, { 0.15, "head", -5, -15, 8 }, { 0.4, "head", 0, 0, 5 },
        { 0.0, "lArm", 0, 0, 5 }, { 0.06, "lArm", 0, 0, 35 }, { 0.2, "lArm", 0, 0, -10 }, { 0.4, "lArm", 0, 0, 5 },
        { 0.0, "rArm", 0, 0, -5 }, { 0.06, "rArm", 0, 0, -35 }, { 0.2, "rArm", 0, 0, 10 }, { 0.4, "rArm", 0, 0, -5 },
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
    hit = { duration = 0.4, looping = false, keyframes = {
        { 0.0, "chest", 0, 0, 0 }, { 0.06, "chest", 22, 0, 10 }, { 0.15, "chest", -12, 0, -6 }, { 0.28, "chest", 5, 0, 2 }, { 0.4, "chest", 0, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.06, "head", 25, 15, 0 }, { 0.15, "head", -8, -8, 0 }, { 0.4, "head", 0, 0, 0 },
        { 0.0, "jaw", 0, 0, 0 }, { 0.06, "jaw", 18, 0, 0 }, { 0.2, "jaw", 10, 0, 0 }, { 0.4, "jaw", 0, 0, 0 },
        { 0.0, "lUpperArm", 0, 0, 8 }, { 0.06, "lUpperArm", 0, 0, 35 }, { 0.2, "lUpperArm", 0, 0, -5 }, { 0.4, "lUpperArm", 0, 0, 8 },
        { 0.0, "rUpperArm", 0, 0, -8 }, { 0.06, "rUpperArm", 0, 0, -35 }, { 0.2, "rUpperArm", 0, 0, 5 }, { 0.4, "rUpperArm", 0, 0, -8 },
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
    hit = { duration = 0.4, looping = false, keyframes = {
        { 0.0, "body", 0, 0, 0 }, { 0.06, "body", 18, 10, 8 }, { 0.15, "body", -8, -5, -4 }, { 0.28, "body", 3, 2, 2 }, { 0.4, "body", 0, 0, 0 },
        { 0.0, "abdomen", 0, 0, 0 }, { 0.06, "abdomen", -12, 0, 0 }, { 0.2, "abdomen", 5, 0, 0 }, { 0.4, "abdomen", 0, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.06, "head", 15, 12, 0 }, { 0.15, "head", -5, -5, 0 }, { 0.4, "head", 0, 0, 0 },
        { 0.0, "leg1LUp", 0, 0, -30 }, { 0.06, "leg1LUp", 20, 0, -50 }, { 0.2, "leg1LUp", -5, 0, -25 }, { 0.4, "leg1LUp", 0, 0, -30 },
        { 0.0, "leg1RUp", 0, 0, 30 }, { 0.06, "leg1RUp", 20, 0, 50 }, { 0.2, "leg1RUp", -5, 0, 25 }, { 0.4, "leg1RUp", 0, 0, 30 },
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
    hit = { duration = 0.4, looping = false, keyframes = {
        { 0.0, "chest", 0, 0, 0 }, { 0.06, "chest", 20, 0, 12 }, { 0.15, "chest", -10, 0, -6 }, { 0.28, "chest", 4, 0, 2 }, { 0.4, "chest", 0, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.06, "head", 18, 15, 0 }, { 0.15, "head", -6, -8, 0 }, { 0.4, "head", 0, 0, 0 },
        { 0.0, "jaw", 0, 0, 0 }, { 0.06, "jaw", 15, 0, 0 }, { 0.2, "jaw", 8, 0, 0 }, { 0.4, "jaw", 0, 0, 0 },
        { 0.0, "lUpperArm", 5, 0, 10 }, { 0.06, "lUpperArm", 5, 0, 40 }, { 0.2, "lUpperArm", 5, 0, -5 }, { 0.4, "lUpperArm", 5, 0, 10 },
        { 0.0, "rUpperArm", 5, 0, -10 }, { 0.06, "rUpperArm", 5, 0, -40 }, { 0.2, "rUpperArm", 5, 0, 5 }, { 0.4, "rUpperArm", 5, 0, -10 },
    }},
    death = { duration = 1.0, looping = false, keyframes = {
        { 0.0, "pelvis", 0, 0, 0 }, { 0.3, "pelvis", 10, 0, 8 }, { 0.6, "pelvis", 25, 0, 40 }, { 1.0, "pelvis", 35, 0, 85 },
        { 0.0, "chest", 0, 0, 0 }, { 0.3, "chest", 15, 0, 0 }, { 1.0, "chest", 30, 0, 5 },
        { 0.0, "lUpperArm", 5, 0, 10 }, { 0.5, "lUpperArm", 5, 0, 45 }, { 1.0, "lUpperArm", 5, 0, 65 },
        { 0.0, "rUpperArm", 5, 0, -10 }, { 0.5, "rUpperArm", 5, 0, -45 }, { 1.0, "rUpperArm", 5, 0, -65 },
    }},
}

-- ==================== 石魔/巨人 ====================
ANIMS.golem = {
    idle = { duration = 2.5, looping = true, keyframes = {
        -- 缓慢呼吸起伏
        { 0.0, "chest", -2, 0, 0 }, { 1.25, "chest", 3, 0, 0 }, { 2.5, "chest", -2, 0, 0 },
        -- 拳头微微握紧/放松
        { 0.0, "lUpperArm", 5, 0, 12 }, { 1.25, "lUpperArm", 5, 0, 8 }, { 2.5, "lUpperArm", 5, 0, 12 },
        { 0.0, "rUpperArm", 5, 0, -12 }, { 1.25, "rUpperArm", 5, 0, -8 }, { 2.5, "rUpperArm", 5, 0, -12 },
        -- 头微微偏转
        { 0.0, "head", 0, 0, 0 }, { 1.25, "head", 0, 5, 0 }, { 2.5, "head", 0, 0, 0 },
    }},
    move = { duration = 0.8, looping = true, keyframes = {
        -- 沉重缓慢的步伐
        { 0.0, "lThigh", 20, 0, 0 }, { 0.4, "lThigh", -18, 0, 0 }, { 0.8, "lThigh", 20, 0, 0 },
        { 0.0, "rThigh", -18, 0, 0 }, { 0.4, "rThigh", 20, 0, 0 }, { 0.8, "rThigh", -18, 0, 0 },
        { 0.0, "lShin", -8, 0, 0 }, { 0.2, "lShin", -25, 0, 0 }, { 0.4, "lShin", -5, 0, 0 }, { 0.8, "lShin", -8, 0, 0 },
        { 0.0, "rShin", -5, 0, 0 }, { 0.4, "rShin", -8, 0, 0 }, { 0.6, "rShin", -25, 0, 0 }, { 0.8, "rShin", -5, 0, 0 },
        -- 手臂摆动（沉重）
        { 0.0, "lUpperArm", -15, 0, 12 }, { 0.4, "lUpperArm", 15, 0, 12 }, { 0.8, "lUpperArm", -15, 0, 12 },
        { 0.0, "rUpperArm", 15, 0, -12 }, { 0.4, "rUpperArm", -15, 0, -12 }, { 0.8, "rUpperArm", 15, 0, -12 },
        -- 身体笨重晃动
        { 0.0, "chest", -4, 0, -3 }, { 0.4, "chest", -4, 0, 3 }, { 0.8, "chest", -4, 0, -3 },
        { 0.0, "pelvis", 0, 0, 2 }, { 0.4, "pelvis", 0, 0, -2 }, { 0.8, "pelvis", 0, 0, 2 },
    }},
    attack = { duration = 0.8, looping = false, keyframes = {
        -- 双拳砸地
        { 0.0, "chest", 0, 0, 0 }, { 0.2, "chest", -25, 0, 0 }, { 0.45, "chest", 30, 0, 0 }, { 0.8, "chest", 0, 0, 0 },
        { 0.0, "lUpperArm", 5, 0, 12 }, { 0.2, "lUpperArm", -120, 10, 20 }, { 0.45, "lUpperArm", 50, -5, 5 }, { 0.8, "lUpperArm", 5, 0, 12 },
        { 0.0, "rUpperArm", 5, 0, -12 }, { 0.2, "rUpperArm", -120, -10, -20 }, { 0.45, "rUpperArm", 50, 5, -5 }, { 0.8, "rUpperArm", 5, 0, -12 },
        { 0.0, "lForeArm", 0, 0, 0 }, { 0.2, "lForeArm", -70, 0, 0 }, { 0.45, "lForeArm", 15, 0, 0 }, { 0.8, "lForeArm", 0, 0, 0 },
        { 0.0, "rForeArm", 0, 0, 0 }, { 0.2, "rForeArm", -70, 0, 0 }, { 0.45, "rForeArm", 15, 0, 0 }, { 0.8, "rForeArm", 0, 0, 0 },
        -- 头向前压
        { 0.0, "head", 0, 0, 0 }, { 0.2, "head", 15, 0, 0 }, { 0.45, "head", -10, 0, 0 }, { 0.8, "head", 0, 0, 0 },
    }},
    hit = { duration = 0.5, looping = false, keyframes = {
        { 0.0, "chest", 0, 0, 0 }, { 0.08, "chest", 15, 0, 8 }, { 0.2, "chest", -8, 0, -5 }, { 0.35, "chest", 3, 0, 2 }, { 0.5, "chest", 0, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.08, "head", 20, 10, 0 }, { 0.2, "head", -5, -5, 0 }, { 0.5, "head", 0, 0, 0 },
        { 0.0, "lUpperArm", 5, 0, 12 }, { 0.08, "lUpperArm", 5, 0, 35 }, { 0.25, "lUpperArm", 5, 0, 0 }, { 0.5, "lUpperArm", 5, 0, 12 },
        { 0.0, "rUpperArm", 5, 0, -12 }, { 0.08, "rUpperArm", 5, 0, -35 }, { 0.25, "rUpperArm", 5, 0, 0 }, { 0.5, "rUpperArm", 5, 0, -12 },
        { 0.0, "pelvis", 0, 0, 0 }, { 0.08, "pelvis", 0, 0, 5 }, { 0.2, "pelvis", 0, 0, -3 }, { 0.5, "pelvis", 0, 0, 0 },
    }},
    death = { duration = 1.5, looping = false, keyframes = {
        -- 缓慢前倾倒下
        { 0.0, "pelvis", 0, 0, 0 }, { 0.5, "pelvis", 15, 0, 5 }, { 1.0, "pelvis", 35, 0, 15 }, { 1.5, "pelvis", 50, 0, 20 },
        { 0.0, "chest", 0, 0, 0 }, { 0.5, "chest", 20, 0, 0 }, { 1.0, "chest", 35, 0, 5 }, { 1.5, "chest", 45, 0, 8 },
        { 0.0, "lUpperArm", 5, 0, 12 }, { 0.6, "lUpperArm", 5, 0, 45 }, { 1.5, "lUpperArm", 5, 0, 70 },
        { 0.0, "rUpperArm", 5, 0, -12 }, { 0.6, "rUpperArm", 5, 0, -45 }, { 1.5, "rUpperArm", 5, 0, -70 },
        { 0.0, "head", 0, 0, 0 }, { 0.5, "head", 15, 0, 0 }, { 1.5, "head", 35, 10, 0 },
    }},
}

-- ==================== 巨蟒/骨龙 ====================
ANIMS.serpent = {
    idle = { duration = 3.0, looping = true, keyframes = {
        -- 蛇身蜿蜒呼吸
        { 0.0, "seg1", 0, 0, 0 }, { 1.5, "seg1", 0, 5, 0 }, { 3.0, "seg1", 0, 0, 0 },
        { 0.0, "seg2", 0, 0, 0 }, { 1.0, "seg2", 0, -8, 0 }, { 2.0, "seg2", 0, 8, 0 }, { 3.0, "seg2", 0, 0, 0 },
        { 0.0, "seg3", 0, 0, 0 }, { 1.5, "seg3", 0, 10, 0 }, { 3.0, "seg3", 0, 0, 0 },
        { 0.0, "seg4", 0, 0, 0 }, { 1.0, "seg4", 0, 8, 0 }, { 2.0, "seg4", 0, -6, 0 }, { 3.0, "seg4", 0, 0, 0 },
        { 0.0, "seg5", 0, 0, 0 }, { 1.5, "seg5", 0, -7, 0 }, { 3.0, "seg5", 0, 0, 0 },
        { 0.0, "tail", 0, 0, 0 }, { 1.0, "tail", 0, 10, 0 }, { 2.0, "tail", 0, -10, 0 }, { 3.0, "tail", 0, 0, 0 },
        -- 头部轻微摆动
        { 0.0, "neck", 0, 0, 0 }, { 1.5, "neck", -5, 3, 0 }, { 3.0, "neck", 0, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 1.0, "head", 0, -5, 0 }, { 2.0, "head", 0, 5, 0 }, { 3.0, "head", 0, 0, 0 },
        { 0.0, "jaw", 0, 0, 0 }, { 1.5, "jaw", 3, 0, 0 }, { 3.0, "jaw", 0, 0, 0 },
    }},
    move = { duration = 0.6, looping = true, keyframes = {
        -- 蛇形运动（S形波浪）
        { 0.0, "seg1", 0, -10, 0 }, { 0.3, "seg1", 0, 10, 0 }, { 0.6, "seg1", 0, -10, 0 },
        { 0.0, "seg2", 0, 12, 0 }, { 0.3, "seg2", 0, -12, 0 }, { 0.6, "seg2", 0, 12, 0 },
        { 0.0, "seg3", 0, -14, 0 }, { 0.3, "seg3", 0, 14, 0 }, { 0.6, "seg3", 0, -14, 0 },
        { 0.0, "seg4", 0, 12, 0 }, { 0.3, "seg4", 0, -12, 0 }, { 0.6, "seg4", 0, 12, 0 },
        { 0.0, "seg5", 0, -10, 0 }, { 0.3, "seg5", 0, 10, 0 }, { 0.6, "seg5", 0, -10, 0 },
        { 0.0, "tail", 0, 15, 0 }, { 0.3, "tail", 0, -15, 0 }, { 0.6, "tail", 0, 15, 0 },
        -- 头部追踪前进方向
        { 0.0, "neck", -5, 0, 0 }, { 0.3, "neck", -5, 0, 0 }, { 0.6, "neck", -5, 0, 0 },
        { 0.0, "head", 0, 5, 0 }, { 0.3, "head", 0, -5, 0 }, { 0.6, "head", 0, 5, 0 },
    }},
    attack = { duration = 0.6, looping = false, keyframes = {
        -- 蓄力 → 猛咬
        { 0.0, "neck", 0, 0, 0 }, { 0.15, "neck", 20, 0, 0 }, { 0.35, "neck", -35, 0, 0 }, { 0.6, "neck", 0, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.15, "head", 15, 0, 0 }, { 0.35, "head", -25, 0, 0 }, { 0.6, "head", 0, 0, 0 },
        { 0.0, "jaw", 0, 0, 0 }, { 0.15, "jaw", 20, 0, 0 }, { 0.30, "jaw", 20, 0, 0 }, { 0.40, "jaw", -5, 0, 0 }, { 0.6, "jaw", 0, 0, 0 },
        -- 身体前冲
        { 0.0, "seg1", 0, 0, 0 }, { 0.15, "seg1", 5, 0, 0 }, { 0.35, "seg1", -10, 0, 0 }, { 0.6, "seg1", 0, 0, 0 },
        { 0.0, "seg2", 0, 0, 0 }, { 0.2, "seg2", 0, 5, 0 }, { 0.4, "seg2", 0, -5, 0 }, { 0.6, "seg2", 0, 0, 0 },
    }},
    hit = { duration = 0.45, looping = false, keyframes = {
        { 0.0, "seg1", 0, 0, 0 }, { 0.06, "seg1", 12, 15, 5 }, { 0.15, "seg1", -6, -8, -3 }, { 0.3, "seg1", 3, 3, 1 }, { 0.45, "seg1", 0, 0, 0 },
        { 0.0, "seg2", 0, 0, 0 }, { 0.08, "seg2", 0, -12, 0 }, { 0.2, "seg2", 0, 6, 0 }, { 0.45, "seg2", 0, 0, 0 },
        { 0.0, "seg3", 0, 0, 0 }, { 0.10, "seg3", 0, 10, 0 }, { 0.25, "seg3", 0, -5, 0 }, { 0.45, "seg3", 0, 0, 0 },
        { 0.0, "neck", 0, 0, 0 }, { 0.06, "neck", 20, 0, 10 }, { 0.15, "neck", -8, 0, -5 }, { 0.45, "neck", 0, 0, 0 },
        { 0.0, "head", 0, 0, 0 }, { 0.06, "head", 10, 20, 0 }, { 0.15, "head", -5, -10, 0 }, { 0.45, "head", 0, 0, 0 },
        { 0.0, "jaw", 0, 0, 0 }, { 0.06, "jaw", 15, 0, 0 }, { 0.2, "jaw", 8, 0, 0 }, { 0.45, "jaw", 0, 0, 0 },
    }},
    death = { duration = 1.5, looping = false, keyframes = {
        -- 全身瘫软倒下
        { 0.0, "seg1", 0, 0, 0 }, { 0.5, "seg1", 15, 10, 0 }, { 1.0, "seg1", 30, 20, 10 }, { 1.5, "seg1", 40, 25, 15 },
        { 0.0, "seg2", 0, 0, 0 }, { 0.5, "seg2", 10, -15, 0 }, { 1.5, "seg2", 20, -30, 5 },
        { 0.0, "seg3", 0, 0, 0 }, { 0.5, "seg3", 8, 12, 0 }, { 1.5, "seg3", 15, 25, 0 },
        { 0.0, "seg4", 0, 0, 0 }, { 0.5, "seg4", 5, -10, 0 }, { 1.5, "seg4", 10, -20, 0 },
        { 0.0, "seg5", 0, 0, 0 }, { 0.5, "seg5", 5, 8, 0 }, { 1.5, "seg5", 8, 15, 0 },
        { 0.0, "neck", 0, 0, 0 }, { 0.4, "neck", 25, 0, 10 }, { 1.5, "neck", 50, 0, 20 },
        { 0.0, "head", 0, 0, 0 }, { 0.4, "head", 20, 0, 5 }, { 1.5, "head", 40, 0, 10 },
        { 0.0, "jaw", 0, 0, 0 }, { 0.5, "jaw", 15, 0, 0 }, { 1.5, "jaw", 25, 0, 0 },
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
    local useModelVisual = MODEL_MONSTERS[monsterType] ~= nil
    local hideProceduralBones = useModelVisual and MODEL_MONSTERS[monsterType].hideProceduralBones == true

    -- 如果有对应贴图，预创建纹理材质（避免每个骨骼重复创建）
    local texPath = MONSTER_TEXTURES[monsterType]
    local texMat = nil
    if texPath then
        texMat = CreateTexPBRMat(texPath, 0.7, 0.05)
    end

    for _, name in ipairs(buildOrder) do
        local def = boneDefs[name]
        local pNode = def.parent and bones[def.parent] or parentNode

        local boneNode = pNode:CreateChild(name)
        boneNode.position = Vector3(def.pos[1], def.pos[2], def.pos[3])

        if not hideProceduralBones then
            -- mesh 子节点
            local meshNode = boneNode:CreateChild(name .. "_mesh")
            if def.meshOffset then
                meshNode.position = Vector3(def.meshOffset[1], def.meshOffset[2], def.meshOffset[3])
            end
            meshNode.scale = Vector3(def.meshScale[1], def.meshScale[2], def.meshScale[3])

            local model = meshNode:CreateComponent("StaticModel")
            model:SetModel(cache:GetResource("Model", "Models/" .. def.model .. ".mdl"))

            -- 材质选择：有 colorOverride 的部位用纯色，否则用纹理贴图
            if def.colorOverride then
                model:SetMaterial(CreatePBRMat(def.colorOverride, 0.6, 0.1))
            elseif texMat then
                model:SetMaterial(texMat)
            else
                model:SetMaterial(CreatePBRMat(color, 0.6, 0.1))
            end
            model.castShadows = true
        end

        bones[name] = boneNode
    end

    local visual = nil
    if useModelVisual then
        visual = CreateModelVisual(parentNode, bones, monsterType)
    end

    return bones, buildOrder, visual
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

local REAL_DEER_BONES = {
    "L_Front_Upper", "L_Front_Lower", "R_Front_Upper", "R_Front_Lower",
    "L_Back_Upper", "L_Back_Lower", "R_Back_Upper", "R_Back_Lower",
}

local function SetRealBoneRotation(animData, boneName, rx, ry, rz)
    local node = animData.realBones and animData.realBones[boneName]
    if node then
        node.rotation = Quaternion(rx, ry, rz)
    end
end

local function CacheRealDeerBones(animData)
    if animData.realBonesCached then return end
    animData.realBonesCached = true
    animData.realBones = {}

    local component = animData.visual and animData.visual.component
    if not component then return end
    local skeleton = component:GetSkeleton()
    if not skeleton then return end

    local foundCount = 0
    for _, boneName in ipairs(REAL_DEER_BONES) do
        local bone = skeleton:GetBone(boneName)
        if bone and bone.node then
            animData.realBones[boneName] = bone.node
            foundCount = foundCount + 1
        end
    end
    print("[MonsterSkeleton] Deer real bones cached: " .. tostring(foundCount) .. "/" .. tostring(#REAL_DEER_BONES))
end

local function UpdateRealDeerAnimation(animData, dt, isMoving)
    CacheRealDeerBones(animData)
    if not animData.realBones then return end

    animData.realElapsed = (animData.realElapsed or 0) + dt
    local t = animData.realElapsed

    if animData.state == "death" or animData.state == "hit" or animData.state == "attack" then
        return
    end

    if isMoving then
        local phase = math.sin(t * 10.0)
        local opposite = -phase
        SetRealBoneRotation(animData, "L_Front_Upper", 6 * phase, 0, 0)
        SetRealBoneRotation(animData, "R_Back_Upper", 6 * phase, 0, 0)
        SetRealBoneRotation(animData, "R_Front_Upper", 6 * opposite, 0, 0)
        SetRealBoneRotation(animData, "L_Back_Upper", 6 * opposite, 0, 0)
        SetRealBoneRotation(animData, "L_Front_Lower", -14 * phase, 0, 0)
        SetRealBoneRotation(animData, "R_Back_Lower", -14 * phase, 0, 0)
        SetRealBoneRotation(animData, "R_Front_Lower", -14 * opposite, 0, 0)
        SetRealBoneRotation(animData, "L_Back_Lower", -14 * opposite, 0, 0)
    else
        SetRealBoneRotation(animData, "L_Front_Upper", 0, 0, 0)
        SetRealBoneRotation(animData, "R_Front_Upper", 0, 0, 0)
        SetRealBoneRotation(animData, "L_Back_Upper", 0, 0, 0)
        SetRealBoneRotation(animData, "R_Back_Upper", 0, 0, 0)
        SetRealBoneRotation(animData, "L_Front_Lower", 0, 0, 0)
        SetRealBoneRotation(animData, "R_Front_Lower", 0, 0, 0)
        SetRealBoneRotation(animData, "L_Back_Lower", 0, 0, 0)
        SetRealBoneRotation(animData, "R_Back_Lower", 0, 0, 0)
    end
end

local MODEL_ANIMS = {
    humanoid_fast = {
        idle = { path = "uuid://FBV7wR2EwuoH-ovToVA8vH90", duration = 2.0, loop = true, speed = 1.0 },
        walk = { path = "uuid://CLwWYfIHxVykOtlpDhB_-T2E", duration = 0.8, loop = true, speed = 0.65 },
        run = { path = "uuid://ERdI4cE9zRJ78VWiJNaKWtLD", duration = 0.8, loop = true, speed = 1.15 },
        attack = { path = "uuid://B5CeOfTwRtwDavJOk69BjU3L", duration = 0.966633, loop = false, speed = 1.0 },
        hit = { path = "uuid://G6J2ITmKfh0oy5_nnbweG8xK", duration = 0.8, loop = false, speed = 2.4 },
        death = { path = "uuid://Bp84GR3zHR88xE4zRCAL1uMc", duration = 2.3, loop = false, speed = 1.0 },
    },
    heavy_mech = {
        idle = { path = "uuid://Cipz8bNT1q0Hk2NMNBgvzfH_", duration = 2.0, loop = true, speed = 0.85 },
        walk = { path = "uuid://CjmPmQdzXxZYDG1F3vO1eLPD", duration = 0.866633, loop = true, speed = 0.75 },
        run = { path = "uuid://ERdI4cE9zRJ78VWiJNaKWtLD", duration = 0.8, loop = true, speed = 0.85 },
        attack = { path = "uuid://AG7o2TcvrluLScFMCJltgkkF", duration = 1.366633, loop = false, speed = 0.9 },
        hit = { path = "uuid://G6J2ITmKfh0oy5_nnbweG8xK", duration = 0.8, loop = false, speed = 1.8 },
        death = { path = "uuid://Dzln6b8wxqprljr5RErNXOqN", duration = 1.4, loop = false, speed = 0.9 },
    },
}

local function PlayModelAnim(visual, name)
    if not visual or not visual.animCtrl or not visual.modelAnim then return false end
    local set = MODEL_ANIMS[visual.modelAnim]
    local cfg = set and set[name]
    if not cfg then
        if not visual.missingAnimLogged then visual.missingAnimLogged = {} end
        if not visual.missingAnimLogged[name] then
            print("[MonsterSkeleton] Missing model anim: " .. tostring(visual.modelAnim) .. "." .. tostring(name))
            visual.missingAnimLogged[name] = true
        end
        return false
    end
    if visual.currentAnim == name then return true end

    visual.currentAnim = name
    visual.animCtrl:PlayExclusive(cfg.path, 0, cfg.loop, 0.12)
    visual.animCtrl:SetSpeed(cfg.path, cfg.speed or 1.0)
    return true
end

local function UpdateModelOverlay(visual, dt, animState, isMoving, monsterType, moveAnimName)
    if not visual then return end
    visual.elapsed = (visual.elapsed or 0) + dt

    local motionKey = animState .. ":" .. tostring(moveAnimName or "")
    if visual.motionKey ~= motionKey then
        visual.motionKey = motionKey
        visual.motionElapsed = 0
    end
    visual.motionElapsed = (visual.motionElapsed or 0) + dt

    if visual.baseScale then
        local t = visual.motionElapsed
        local sx = visual.baseScale.x
        local sy = visual.baseScale.y
        local sz = visual.baseScale.z
        local basePos = visual.basePosition or Vector3.ZERO
        local pos = basePos
        local rot = Quaternion.IDENTITY
        local scale = Vector3(sx, sy, sz)

        if animState == "death" then
            local cfg = MODEL_ANIMS[visual.modelAnim] and MODEL_ANIMS[visual.modelAnim].death
            local p = math.min(1.0, t / ((cfg and cfg.duration) or 1.0))
            pos = basePos + Vector3(0, -0.18 * p, -0.18 * p)
            if monsterType == "mech_humanoid" then
                rot = Quaternion(0, 0, 92 * p)
            else
                rot = Quaternion(18 * p, 0, 88 * p)
            end
        elseif animState == "attack" then
            local cfg = MODEL_ANIMS[visual.modelAnim] and MODEL_ANIMS[visual.modelAnim].attack
            local duration = (cfg and cfg.duration) or 1.0
            local p = math.min(1.0, t / duration)
            local thrust = math.sin(math.min(1.0, p) * math.pi)
            if monsterType == "mech_humanoid" then
                pos = basePos + Vector3(0, 0.03 * thrust, 0.20 * thrust)
                rot = Quaternion(-10 * thrust, 0, 0)
                scale = Vector3(sx * (1.0 + 0.05 * thrust), sy * (1.0 - 0.03 * thrust), sz * (1.0 + 0.08 * thrust))
            else
                pos = basePos + Vector3(0, 0.04 * thrust, 0.22 * thrust)
                rot = Quaternion(-14 * thrust, 0, 8 * math.sin(p * math.pi * 2.0))
            end
        elseif animState == "hit" then
            local shake = math.sin(t * 42.0) * math.max(0, 1.0 - t * 2.0)
            pos = basePos + Vector3(0.04 * shake, 0, 0)
            rot = Quaternion(0, 0, 8 * shake)
        elseif isMoving then
            if moveAnimName == "walk" then
                local step = math.sin(t * 7.0)
                pos = basePos + Vector3(0, math.abs(step) * 0.025, 0)
                rot = Quaternion(2.5 * step, 0, 3.0 * step)
            else
                local step = math.sin(t * 12.0)
                pos = basePos + Vector3(0, math.abs(step) * 0.045, 0)
                rot = Quaternion(5.0 * step, 0, 5.0 * step)
            end
        elseif monsterType == "mech_humanoid" then
            local pulse = 1.0 + math.sin(visual.elapsed * 7.0) * 0.015
            scale = Vector3(sx * pulse, sy, sz * pulse)
        end

        visual.node.position = pos
        visual.node.rotation = rot
        visual.node.scale = scale
    end

    if animState == "death" then
        PlayModelAnim(visual, "death")
    elseif animState == "attack" then
        PlayModelAnim(visual, "attack")
    elseif animState == "hit" then
        PlayModelAnim(visual, "hit")
    elseif isMoving then
        PlayModelAnim(visual, moveAnimName or "run")
    else
        PlayModelAnim(visual, "idle")
    end
end

--- 更新怪物动画
---@param animData table {type, state, elapsed, bones, buildOrder}
---@param dt number
---@param isMoving boolean
---@param moveAnimName string|nil
function MonsterSkeleton.UpdateAnimation(animData, dt, isMoving, moveAnimName)
    if animData.visual and animData.visual.animated then
        UpdateModelOverlay(animData.visual, dt, animData.state, isMoving, animData.type, moveAnimName)
    end

    if animData.visual and animData.visual.animated and animData.type == "deer" then
        UpdateRealDeerAnimation(animData, dt, isMoving)
    end

    local typeAnims = ANIMS[animData.type]
    if not typeAnims then
        if animData.state == "idle" and isMoving then
            animData.state = "move"
            animData.elapsed = 0
        elseif animData.state == "move" and not isMoving then
            animData.state = "idle"
            animData.elapsed = 0
        elseif animData.state ~= "idle" and animData.state ~= "move" then
            animData.elapsed = animData.elapsed + dt
            local duration = MonsterSkeleton.GetAnimDuration(animData.type, animData.state)
            if animData.elapsed >= duration then
                if animData.onComplete then
                    animData.onComplete()
                    animData.onComplete = nil
                end
                animData.state = isMoving and "move" or "idle"
                animData.elapsed = 0
            end
        end
        return
    end

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
    local modelDef = MODEL_MONSTERS[monsterType]
    if modelDef and modelDef.modelAnim then
        local set = MODEL_ANIMS[modelDef.modelAnim]
        local cfg = set and set[state]
        if cfg then return cfg.duration end
    end
    local typeAnims = ANIMS[monsterType]
    if not typeAnims or not typeAnims[state] then return 0.5 end
    return typeAnims[state].duration
end

return MonsterSkeleton
