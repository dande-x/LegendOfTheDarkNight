---@diagnostic disable: assign-type-mismatch
-- ============================================================================
-- PlayerAnim.lua — 程序化人形骨架 + 攻击动画系统
-- 基于关键帧插值，为近战/远程/召唤提供不同的攻击动作和打击感反馈
-- ============================================================================

local PlayerAnim = {}

-- ============================================================================
-- 骨架部件引用
-- ============================================================================
---@type table<string, Node>
local bones = {}
local animState = {
    current = "idle",     -- idle | walk | melee | ranged | summon | hit | death
    elapsed = 0,
    duration = 0,
    onComplete = nil,
}

-- 打击感系统
local hitFeedback = {
    screenShake = 0,        -- 屏幕震动剩余时间
    shakeIntensity = 0,     -- 震动强度
    hitPause = 0,           -- 顿帧时间
    flashTimer = 0,         -- 命中闪光
}

local currentClassId = "warrior"  -- 当前职业（CreateSkeleton 时设置）

PlayerAnim.bones = bones
PlayerAnim.animState = animState
PlayerAnim.hitFeedback = hitFeedback

-- ============================================================================
-- 人形骨架配置
-- 关键设计：bone 节点 scale 始终为 (1,1,1)，仅管理旋转+位置
--          视觉网格放在 bone 的子节点 "mesh" 中带独立 scale
-- ============================================================================
local BONE_DEFS = {
    -- 躯干
    pelvis   = { parent = nil,       pos = {0, 0.50, 0},   meshScale = {0.35, 0.22, 0.22}, model = "Box" },
    chest    = { parent = "pelvis",  pos = {0, 0.22, 0},   meshScale = {0.42, 0.32, 0.25}, model = "Box" },
    -- 头部
    neck     = { parent = "chest",   pos = {0, 0.20, 0},   meshScale = {0.08, 0.10, 0.08}, model = "Cylinder" },
    head     = { parent = "neck",    pos = {0, 0.15, 0},   meshScale = {0.26, 0.26, 0.26}, model = "Sphere" },
    -- 左臂（pivot 在肩膀处）
    lUpperArm = { parent = "chest",  pos = {-0.26, 0.10, 0}, meshScale = {0.09, 0.20, 0.09}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    lForeArm  = { parent = "lUpperArm", pos = {0, -0.22, 0}, meshScale = {0.07, 0.18, 0.07}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    lHand     = { parent = "lForeArm", pos = {0, -0.19, 0},  meshScale = {0.08, 0.05, 0.10}, model = "Box" },
    -- 右臂
    rUpperArm = { parent = "chest",  pos = {0.26, 0.10, 0},  meshScale = {0.09, 0.20, 0.09}, model = "Cylinder", meshOffset = {0, -0.10, 0} },
    rForeArm  = { parent = "rUpperArm", pos = {0, -0.22, 0}, meshScale = {0.07, 0.18, 0.07}, model = "Cylinder", meshOffset = {0, -0.09, 0} },
    rHand     = { parent = "rForeArm", pos = {0, -0.19, 0},  meshScale = {0.08, 0.05, 0.10}, model = "Box" },
    -- 左腿（pivot 在胯部）
    lThigh   = { parent = "pelvis", pos = {-0.11, -0.05, 0}, meshScale = {0.11, 0.24, 0.11}, model = "Cylinder", meshOffset = {0, -0.12, 0} },
    lShin    = { parent = "lThigh", pos = {0, -0.26, 0},     meshScale = {0.09, 0.22, 0.09}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    lFoot    = { parent = "lShin",  pos = {0, -0.24, 0.03},  meshScale = {0.09, 0.05, 0.15}, model = "Box" },
    -- 右腿
    rThigh   = { parent = "pelvis", pos = {0.11, -0.05, 0},  meshScale = {0.11, 0.24, 0.11}, model = "Cylinder", meshOffset = {0, -0.12, 0} },
    rShin    = { parent = "rThigh", pos = {0, -0.26, 0},     meshScale = {0.09, 0.22, 0.09}, model = "Cylinder", meshOffset = {0, -0.11, 0} },
    rFoot    = { parent = "rShin",  pos = {0, -0.24, 0.03},  meshScale = {0.09, 0.05, 0.15}, model = "Box" },
}

-- 构建顺序（确保父节点先创建）
local BUILD_ORDER = {
    "pelvis", "chest", "neck", "head",
    "lUpperArm", "lForeArm", "lHand",
    "rUpperArm", "rForeArm", "rHand",
    "lThigh", "lShin", "lFoot",
    "rThigh", "rShin", "rFoot",
}
-- 额外可动画的节点（不在 BONE_DEFS 中，但可被关键帧控制）
local EXTRA_ANIM_BONES = { "sword" }

-- ============================================================================
-- 创建人形骨架
-- ============================================================================
function PlayerAnim.CreateSkeleton(playerNode, classId, color, colors)
    currentClassId = classId

    -- 清空旧骨骼
    for _, name in ipairs(BUILD_ORDER) do
        bones[name] = nil
    end

    local skinColor = colors.Cream
    local armorColor = color

    for _, name in ipairs(BUILD_ORDER) do
        local def = BONE_DEFS[name]
        local parentNode = def.parent and bones[def.parent] or playerNode

        -- bone 节点：scale 始终 (1,1,1)，仅承载 position + rotation
        local boneNode = parentNode:CreateChild(name)
        boneNode.position = Vector3(def.pos[1], def.pos[2], def.pos[3])
        -- 不设 scale！默认 (1,1,1)

        -- mesh 子节点：承载视觉模型 + 独立 scale
        local meshNode = boneNode:CreateChild(name .. "_mesh")
        if def.meshOffset then
            meshNode.position = Vector3(def.meshOffset[1], def.meshOffset[2], def.meshOffset[3])
        end
        meshNode.scale = Vector3(def.meshScale[1], def.meshScale[2], def.meshScale[3])

        local model = meshNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/" .. def.model .. ".mdl"))

        -- 材质分配：头/手/脖子=肤色，其余=铠甲色
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))

        local isSkin = (name == "head" or name == "neck" or name == "lHand" or name == "rHand")
        local isLeg = (name == "lThigh" or name == "lShin" or name == "rThigh" or name == "rShin" or name == "lFoot" or name == "rFoot")

        if isSkin then
            mat:SetShaderParameter("MatDiffColor", Variant(skinColor))
            mat:SetShaderParameter("Roughness", Variant(0.7))
            mat:SetShaderParameter("Metallic", Variant(0.0))
        elseif isLeg then
            local legColor = Color(armorColor.r * 0.7, armorColor.g * 0.7, armorColor.b * 0.7, 1.0)
            mat:SetShaderParameter("MatDiffColor", Variant(legColor))
            mat:SetShaderParameter("Roughness", Variant(0.5))
            mat:SetShaderParameter("Metallic", Variant(0.3))
        else
            mat:SetShaderParameter("MatDiffColor", Variant(armorColor))
            mat:SetShaderParameter("Roughness", Variant(0.4))
            mat:SetShaderParameter("Metallic", Variant(0.4))
            if name == "chest" then
                mat:SetShaderParameter("MatEmissiveColor", Variant(Color(armorColor.r * 0.15, armorColor.g * 0.15, armorColor.b * 0.15)))
            end
        end

        model:SetMaterial(mat)
        model.castShadows = true
        bones[name] = boneNode
    end

    -- 添加职业特有装饰
    PlayerAnim._AddClassDecoration(playerNode, classId, colors)
end

-- ============================================================================
-- 职业装饰（武器/法杖/法器）
-- ============================================================================
function PlayerAnim._AddClassDecoration(playerNode, classId, colors)
    if classId == "warrior" then
        -- ================================================================
        -- 屠龙刀（扛在右肩上，参考传奇经典造型）
        -- 宽厚刀身 + 短柄 + 金色护手
        -- ================================================================
        local daoRoot = bones.rHand:CreateChild("DaoRoot")
        daoRoot.position = Vector3(0, -0.06, 0)
        daoRoot.rotation = Quaternion(30, 0, 0)  -- 刀身向后倾斜，扛肩时刀搭在肩后

        -- 刀柄（深棕色木柄，较短）
        local handle = daoRoot:CreateChild("DaoHandle")
        handle.position = Vector3(0, -0.05, 0)
        handle.scale = Vector3(0.04, 0.22, 0.035)
        local hModel = handle:CreateComponent("StaticModel")
        hModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local hMat = Material:new()
        hMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        hMat:SetShaderParameter("MatDiffColor", Variant(Color(0.30, 0.15, 0.05, 1.0)))
        hMat:SetShaderParameter("Roughness", Variant(0.85))
        hMat:SetShaderParameter("Metallic", Variant(0.05))
        hModel:SetMaterial(hMat)
        hModel.castShadows = true

        -- 柄尾环（金属圆环）
        local pommel = daoRoot:CreateChild("DaoPommel")
        pommel.position = Vector3(0, -0.17, 0)
        pommel.scale = Vector3(0.055, 0.025, 0.055)
        local pmModel = pommel:CreateComponent("StaticModel")
        pmModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local goldMat = Material:new()
        goldMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        goldMat:SetShaderParameter("MatDiffColor", Variant(Color(0.75, 0.55, 0.10, 1.0)))
        goldMat:SetShaderParameter("Roughness", Variant(0.25))
        goldMat:SetShaderParameter("Metallic", Variant(0.9))
        goldMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.12, 0.08, 0.0)))
        pmModel:SetMaterial(goldMat)
        pmModel.castShadows = true

        -- 护手（金色兽头横档，厚实）
        local guard = daoRoot:CreateChild("DaoGuard")
        guard.position = Vector3(0, 0.08, 0)
        guard.scale = Vector3(0.14, 0.04, 0.06)
        local gModel = guard:CreateComponent("StaticModel")
        gModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        gModel:SetMaterial(goldMat)
        gModel.castShadows = true

        -- 刀身主体（宽厚，屠龙刀特征：上宽下窄的梯形感）
        local bladeMat = Material:new()
        bladeMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        bladeMat:SetShaderParameter("MatDiffColor", Variant(Color(0.55, 0.53, 0.52, 1.0)))
        bladeMat:SetShaderParameter("Metallic", Variant(0.95))
        bladeMat:SetShaderParameter("Roughness", Variant(0.18))
        bladeMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.03, 0.02, 0.01)))

        -- 刀身下段（靠近护手，稍窄）
        local bladeLower = daoRoot:CreateChild("DaoBladeLower")
        bladeLower.position = Vector3(0, 0.34, 0)
        bladeLower.scale = Vector3(0.16, 0.44, 0.025)
        local blModel = bladeLower:CreateComponent("StaticModel")
        blModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        blModel:SetMaterial(bladeMat)
        blModel.castShadows = true

        -- 刀身上段（刀头最宽处，屠龙刀标志性宽刃）
        local bladeUpper = daoRoot:CreateChild("DaoBladeUpper")
        bladeUpper.position = Vector3(0.02, 0.78, 0)
        bladeUpper.scale = Vector3(0.24, 0.40, 0.028)
        local buModel = bladeUpper:CreateComponent("StaticModel")
        buModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        buModel:SetMaterial(bladeMat)
        buModel.castShadows = true

        -- 刀脊（厚背，深色钢）
        local spine = daoRoot:CreateChild("DaoSpine")
        spine.position = Vector3(-0.08, 0.58, 0)
        spine.scale = Vector3(0.03, 0.90, 0.035)
        local spModel = spine:CreateComponent("StaticModel")
        spModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local spineMat = Material:new()
        spineMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        spineMat:SetShaderParameter("MatDiffColor", Variant(Color(0.25, 0.22, 0.20, 1.0)))
        spineMat:SetShaderParameter("Metallic", Variant(0.8))
        spineMat:SetShaderParameter("Roughness", Variant(0.4))
        spModel:SetMaterial(spineMat)
        spModel.castShadows = true

        -- 刀刃（亮色开刃边缘）
        local edge = daoRoot:CreateChild("DaoEdge")
        edge.position = Vector3(0.10, 0.58, 0)
        edge.scale = Vector3(0.015, 0.85, 0.015)
        local eModel = edge:CreateComponent("StaticModel")
        eModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local edgeMat = Material:new()
        edgeMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        edgeMat:SetShaderParameter("MatDiffColor", Variant(Color(0.92, 0.90, 0.85, 1.0)))
        edgeMat:SetShaderParameter("Metallic", Variant(0.98))
        edgeMat:SetShaderParameter("Roughness", Variant(0.05))
        edgeMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.08, 0.06, 0.02)))
        eModel:SetMaterial(edgeMat)
        eModel.castShadows = true

        -- 刀头尖端（斜切）
        local tip = daoRoot:CreateChild("DaoTip")
        tip.position = Vector3(0.04, 1.02, 0)
        tip.rotation = Quaternion(0, 0, 15)
        tip.scale = Vector3(0.16, 0.08, 0.025)
        local tModel = tip:CreateComponent("StaticModel")
        tModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        tModel:SetMaterial(bladeMat)
        tModel.castShadows = true

        bones.sword = daoRoot

    elseif classId == "mage" then
        -- 右手持权杖：细长杖身 + 金属环箍 + 月牙托座 + 发光宝珠
        local staff = bones.rHand:CreateChild("Staff")
        staff.position = Vector3(0, -0.05, 0)
        staff.scale = Vector3(0.03, 0.9, 0.03)  -- 细长杖身
        local model = staff:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(Color(0.25, 0.15, 0.08, 1.0)))
        mat:SetShaderParameter("Roughness", Variant(0.45))
        mat:SetShaderParameter("Metallic", Variant(0.1))
        model:SetMaterial(mat)
        model.castShadows = true
        -- 杖身底部金属尖端
        local tip = staff:CreateChild("StaffTip")
        tip.position = Vector3(0, -0.5, 0)
        tip.scale = Vector3(1.2, 0.06, 1.2)
        local tipModel = tip:CreateComponent("StaticModel")
        tipModel:SetModel(cache:GetResource("Model", "Models/Cone.mdl"))
        local tipMat = Material:new()
        tipMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        tipMat:SetShaderParameter("MatDiffColor", Variant(Color(0.6, 0.55, 0.45, 1.0)))
        tipMat:SetShaderParameter("Metallic", Variant(0.7))
        tipMat:SetShaderParameter("Roughness", Variant(0.3))
        tipModel:SetMaterial(tipMat)
        -- 杖身中段金属环箍
        local ring = staff:CreateChild("StaffRing")
        ring.position = Vector3(0, 0.15, 0)
        ring.scale = Vector3(1.8, 0.08, 1.8)
        local ringModel = ring:CreateComponent("StaticModel")
        ringModel:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        local ringMat = Material:new()
        ringMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        ringMat:SetShaderParameter("MatDiffColor", Variant(Color(0.85, 0.72, 0.2, 1.0)))
        ringMat:SetShaderParameter("Metallic", Variant(0.9))
        ringMat:SetShaderParameter("Roughness", Variant(0.15))
        ringMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.15, 0.12, 0.02)))
        ringModel:SetMaterial(ringMat)
        -- 顶部第二环箍（权杖头部）
        local ring2 = staff:CreateChild("StaffRing2")
        ring2.position = Vector3(0, 0.42, 0)
        ring2.scale = Vector3(2.2, 0.08, 2.2)
        local ring2Model = ring2:CreateComponent("StaticModel")
        ring2Model:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        local ring2Mat = Material:new()
        ring2Mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        ring2Mat:SetShaderParameter("MatDiffColor", Variant(Color(0.85, 0.72, 0.2, 1.0)))
        ring2Mat:SetShaderParameter("Metallic", Variant(0.9))
        ring2Mat:SetShaderParameter("Roughness", Variant(0.15))
        ring2Mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.15, 0.12, 0.02)))
        ring2Model:SetMaterial(ring2Mat)
        -- 月牙形托座（用两个弧形 Torus 交叉模拟权杖头部笼框）
        local arc1 = staff:CreateChild("StaffArc1")
        arc1.position = Vector3(0, 0.48, 0)
        arc1.scale = Vector3(2.8, 3.5, 2.8)
        arc1.rotation = Quaternion(0, 0, 0)
        local arc1Model = arc1:CreateComponent("StaticModel")
        arc1Model:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        local arcMat = Material:new()
        arcMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        arcMat:SetShaderParameter("MatDiffColor", Variant(Color(0.75, 0.62, 0.18, 1.0)))
        arcMat:SetShaderParameter("Metallic", Variant(0.85))
        arcMat:SetShaderParameter("Roughness", Variant(0.2))
        arcMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.12, 0.10, 0.02)))
        arc1Model:SetMaterial(arcMat)
        -- 第二弧（90度旋转）
        local arc2 = staff:CreateChild("StaffArc2")
        arc2.position = Vector3(0, 0.48, 0)
        arc2.scale = Vector3(2.8, 3.5, 2.8)
        arc2.rotation = Quaternion(90, Vector3.UP)
        local arc2Model = arc2:CreateComponent("StaticModel")
        arc2Model:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        arc2Model:SetMaterial(arcMat)
        -- 中心发光宝珠（被笼框包裹）
        local orb = staff:CreateChild("StaffOrb")
        orb.position = Vector3(0, 0.48, 0)
        orb.scale = Vector3(2.0, 2.0, 2.0)
        local orbModel = orb:CreateComponent("StaticModel")
        orbModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local orbMat = Material:new()
        orbMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        orbMat:SetShaderParameter("MatDiffColor", Variant(Color(0.2, 0.5, 0.9, 1.0)))
        orbMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.5, 0.8, 1.5)))
        orbMat:SetShaderParameter("Metallic", Variant(0.0))
        orbMat:SetShaderParameter("Roughness", Variant(0.05))
        orbModel:SetMaterial(orbMat)
        bones.staff = staff

    elseif classId == "taoist" then
        -- 右手持拂尘（木柄 + 丝穗）
        local whiskHandle = bones.rHand:CreateChild("WhiskHandle")
        whiskHandle.position = Vector3(0, -0.05, 0)
        whiskHandle.scale = Vector3(0.035, 0.85, 0.035)  -- 细长木柄
        local handleModel = whiskHandle:CreateComponent("StaticModel")
        handleModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        local handleMat = Material:new()
        handleMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        handleMat:SetShaderParameter("MatDiffColor", Variant(Color(0.45, 0.3, 0.15, 1.0)))
        handleMat:SetShaderParameter("Roughness", Variant(0.6))
        handleMat:SetShaderParameter("Metallic", Variant(0.05))
        handleModel:SetMaterial(handleMat)
        handleModel.castShadows = true
        -- 柄顶金属环
        local topRing = whiskHandle:CreateChild("TopRing")
        topRing.position = Vector3(0, 0.48, 0)
        topRing.scale = Vector3(2.0, 0.15, 2.0)
        local topRingModel = topRing:CreateComponent("StaticModel")
        topRingModel:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        local topRingMat = Material:new()
        topRingMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        topRingMat:SetShaderParameter("MatDiffColor", Variant(colors.Gold))
        topRingMat:SetShaderParameter("Metallic", Variant(0.85))
        topRingMat:SetShaderParameter("Roughness", Variant(0.2))
        topRingMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.3, 0.25, 0.05)))
        topRingModel:SetMaterial(topRingMat)
        -- 丝穗（用拉长的球体模拟飘逸感）
        local tassel = whiskHandle:CreateChild("Tassel")
        tassel.position = Vector3(0, 0.55, 0)
        tassel.scale = Vector3(1.8, 3.5, 1.8)  -- 椭圆形丝穗
        local tasselModel = tassel:CreateComponent("StaticModel")
        tasselModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local tasselMat = Material:new()
        tasselMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
        tasselMat:SetShaderParameter("MatDiffColor", Variant(Color(0.95, 0.95, 0.92, 0.7)))
        tasselMat:SetShaderParameter("Roughness", Variant(0.9))
        tasselMat:SetShaderParameter("Metallic", Variant(0.0))
        tasselMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.15, 0.2, 0.1)))
        tasselModel:SetMaterial(tasselMat)
        bones.whisk = whiskHandle
    end
end

-- ============================================================================
-- 动画关键帧数据
-- ============================================================================
-- 关键帧格式: { time, boneName, rotX, rotY, rotZ }（欧拉角，度数）
local ANIMS = {}

-- 待机呼吸动画
ANIMS.idle = {
    duration = 2.0,
    looping = true,
    keyframes = {
        -- 轻微呼吸：胸部微微起伏
        { 0.0,  "chest",     0, 0, 0 },
        { 1.0,  "chest",     -2, 0, 0 },
        { 2.0,  "chest",     0, 0, 0 },
        -- 手臂自然下垂微摆
        { 0.0,  "lUpperArm", 0, 0, 5 },
        { 1.0,  "lUpperArm", 0, 0, 3 },
        { 2.0,  "lUpperArm", 0, 0, 5 },
        { 0.0,  "rUpperArm", 0, 0, -5 },
        { 1.0,  "rUpperArm", 0, 0, -3 },
        { 2.0,  "rUpperArm", 0, 0, -5 },
    },
}

-- 行走动画
ANIMS.walk = {
    duration = 0.6,
    looping = true,
    keyframes = {
        -- 腿部交替迈步
        { 0.0,  "lThigh",    25, 0, 0 },
        { 0.3,  "lThigh",    -25, 0, 0 },
        { 0.6,  "lThigh",    25, 0, 0 },
        { 0.0,  "rThigh",    -25, 0, 0 },
        { 0.3,  "rThigh",    25, 0, 0 },
        { 0.6,  "rThigh",    -25, 0, 0 },
        -- 小腿跟随弯曲
        { 0.0,  "lShin",     -10, 0, 0 },
        { 0.15, "lShin",     -35, 0, 0 },
        { 0.3,  "lShin",     -10, 0, 0 },
        { 0.45, "lShin",     -5, 0, 0 },
        { 0.6,  "lShin",     -10, 0, 0 },
        { 0.0,  "rShin",     -5, 0, 0 },
        { 0.15, "rShin",     -10, 0, 0 },
        { 0.3,  "rShin",     -10, 0, 0 },
        { 0.45, "rShin",     -35, 0, 0 },
        { 0.6,  "rShin",     -5, 0, 0 },
        -- 手臂摆动
        { 0.0,  "lUpperArm", -20, 0, 5 },
        { 0.3,  "lUpperArm", 20, 0, 5 },
        { 0.6,  "lUpperArm", -20, 0, 5 },
        { 0.0,  "rUpperArm", 20, 0, -5 },
        { 0.3,  "rUpperArm", -20, 0, -5 },
        { 0.6,  "rUpperArm", 20, 0, -5 },
        -- 躯干微倾
        { 0.0,  "chest",     -3, 0, -2 },
        { 0.3,  "chest",     -3, 0, 2 },
        { 0.6,  "chest",     -3, 0, -2 },
    },
}

-- ========================= 近战攻击：大弧度劈砍（从扛刀位起手） =========================
-- 起始姿态 = 扛刀姿态（rUpperArm: -20,0,-55  rForeArm: -70,0,0  sword: 30,0,0）
-- 大圆弧轨迹：从右肩后方 → 举过头顶 → 向前下方劈出 → 到身前最低点
ANIMS.melee = {
    duration = 0.60,
    looping = false,
    keyframes = {
        -- ===== 起手=扛刀姿态（0s）：从当前扛肩位置直接开始 =====
        { 0.0,   "chest",     0, -5, 0 },
        { 0.0,   "rUpperArm", -20, 15, -55 },        -- 扛刀姿态：臂外展，Y旋转让刀尖朝内
        { 0.0,   "rForeArm",  -70, 0, 0 },          -- 扛刀姿态：弯肘
        { 0.0,   "sword",     30, 0, 0 },            -- 扛肩角度

        -- ===== 举刀蓄力（0 ~ 0.15s）：从肩上举到头顶后方，刀还没翻 =====
        { 0.15,  "chest",     -10, -15, 0 },        -- 身体右后转蓄力
        { 0.15,  "rUpperArm", -140, 0, -15 },       -- 手臂高举到头顶偏后
        { 0.15,  "rForeArm",  -40, 0, 0 },          -- 前臂弯曲，刀在头后方
        { 0.15,  "sword",     30, 45, 0 },           -- 开始转刃（一半）

        -- ===== 大弧劈下（0.15 ~ 0.32s）：从头顶向前下方全力劈出 =====
        { 0.32,  "chest",     15, 12, 0 },           -- 身体大幅前倾送力
        { 0.32,  "rUpperArm", -35, 8, -5 },          -- 手臂劈到前下方（大弧度）
        { 0.32,  "rForeArm",  -5, 0, 0 },            -- 前臂完全伸直
        { 0.32,  "sword",     210, 90, 0 },           -- 刀完全翻转+刀刃朝前

        -- ===== 劈到最低点（0.32 ~ 0.42s）：刀尖到达最前最低，惯性延伸 =====
        { 0.42,  "chest",     12, 8, 0 },            -- 保持前倾
        { 0.42,  "rUpperArm", -20, 5, -3 },          -- 手臂继续向下延伸
        { 0.42,  "rForeArm",  -2, 0, 0 },
        { 0.42,  "sword",     230, 90, 0 },           -- 劈到底，刀尖指向地面前方

        -- ===== 收刀回肩（0.42 ~ 0.60s）：回到扛刀姿态 =====
        { 0.60,  "chest",     0, -5, 0 },
        { 0.60,  "rUpperArm", -20, 15, -55 },         -- 回到扛刀姿态（臂外展，刀尖朝内）
        { 0.60,  "rForeArm",  -70, 0, 0 },           -- 回到扛刀弯肘
        { 0.60,  "sword",     30, 0, 0 },             -- 回到扛肩角度

        -- ===== 左臂配合：张开保持平衡 =====
        { 0.0,   "lUpperArm", 0, 0, 5 },
        { 0.15,  "lUpperArm", -30, 25, 15 },        -- 蓄力时后张
        { 0.32,  "lUpperArm", 15, -20, -8 },        -- 劈砍时前摆平衡
        { 0.42,  "lUpperArm", 10, -12, -5 },
        { 0.60,  "lUpperArm", 0, 0, 5 },
        { 0.0,   "lForeArm",  0, 0, 0 },
        { 0.15,  "lForeArm",  -35, 0, 0 },
        { 0.32,  "lForeArm",  -10, 0, 0 },
        { 0.60,  "lForeArm",  0, 0, 0 },

        -- ===== 步伐配合：大步前跨 =====
        { 0.0,   "lThigh",    0, 0, 0 },
        { 0.15,  "lThigh",    -12, 0, 0 },          -- 后撤蓄力
        { 0.32,  "lThigh",    30, 0, 0 },           -- 前跨送力
        { 0.60,  "lThigh",    0, 0, 0 },
        { 0.0,   "rThigh",    0, 0, 0 },
        { 0.15,  "rThigh",    8, 0, 0 },
        { 0.32,  "rThigh",    -15, 0, 0 },          -- 后蹬
        { 0.60,  "rThigh",    0, 0, 0 },

        -- ===== 骨盆配合 =====
        { 0.0,   "pelvis",    0, 0, 0 },
        { 0.15,  "pelvis",    -5, -5, 0 },          -- 蓄力后仰
        { 0.32,  "pelvis",    8, 5, 0 },            -- 前倾送力
        { 0.60,  "pelvis",    0, 0, 0 },
    },
}

-- ========================= 远程攻击：蓄力施法 =========================
ANIMS.ranged = {
    duration = 0.55,
    looping = false,
    keyframes = {
        -- 双手抬起蓄力（0 ~ 0.2s）
        { 0.0,   "chest",     0, 0, 0 },
        { 0.2,   "chest",     -8, 0, 0 },      -- 微微后仰
        { 0.0,   "rUpperArm", 0, 0, -5 },
        { 0.2,   "rUpperArm", -80, 10, -10 },  -- 右臂抬至面前
        { 0.0,   "rForeArm",  0, 0, 0 },
        { 0.2,   "rForeArm",  -70, 0, 0 },     -- 蓄力姿势
        { 0.0,   "lUpperArm", 0, 0, 5 },
        { 0.2,   "lUpperArm", -70, -10, 10 },  -- 左臂辅助
        { 0.0,   "lForeArm",  0, 0, 0 },
        { 0.2,   "lForeArm",  -60, 0, 0 },
        -- 推出释放（0.2 ~ 0.35s）— 爆发感
        { 0.35,  "chest",     12, 0, 0 },       -- 前推
        { 0.35,  "rUpperArm", -50, 30, 0 },     -- 右臂推出
        { 0.35,  "rForeArm",  -10, 0, 0 },      -- 伸直
        { 0.35,  "lUpperArm", -40, -30, 0 },    -- 左臂推出
        { 0.35,  "lForeArm",  -10, 0, 0 },
        -- 后坐力（0.35 ~ 0.45s）
        { 0.45,  "chest",     -5, 0, 0 },       -- 后仰反冲
        { 0.45,  "rUpperArm", -30, 20, -5 },
        { 0.45,  "rForeArm",  -20, 0, 0 },
        { 0.45,  "lUpperArm", -20, -15, 5 },
        { 0.45,  "lForeArm",  -15, 0, 0 },
        -- 恢复（0.45 ~ 0.55s）
        { 0.55,  "chest",     0, 0, 0 },
        { 0.55,  "rUpperArm", 0, 0, -5 },
        { 0.55,  "rForeArm",  0, 0, 0 },
        { 0.55,  "lUpperArm", 0, 0, 5 },
        { 0.55,  "lForeArm",  0, 0, 0 },
    },
}

-- ========================= 召唤：双手抬起法阵 =========================
ANIMS.summon = {
    duration = 0.7,
    looping = false,
    keyframes = {
        -- 双手慢慢上抬（0 ~ 0.3s）
        { 0.0,   "chest",     0, 0, 0 },
        { 0.3,   "chest",     -12, 0, 0 },     -- 后仰仰望天空
        { 0.0,   "rUpperArm", 0, 0, -5 },
        { 0.3,   "rUpperArm", -140, 30, -20 }, -- 右臂高举
        { 0.0,   "rForeArm",  0, 0, 0 },
        { 0.3,   "rForeArm",  -30, 0, 0 },
        { 0.0,   "lUpperArm", 0, 0, 5 },
        { 0.3,   "lUpperArm", -140, -30, 20 }, -- 左臂高举
        { 0.0,   "lForeArm",  0, 0, 0 },
        { 0.3,   "lForeArm",  -30, 0, 0 },
        -- 顶峰保持+震动（0.3 ~ 0.5s）
        { 0.35,  "chest",     -14, 2, 0 },
        { 0.40,  "chest",     -12, -2, 0 },
        { 0.45,  "chest",     -14, 1, 0 },
        { 0.50,  "chest",     -12, 0, 0 },
        { 0.50,  "rUpperArm", -135, 28, -18 },
        { 0.50,  "lUpperArm", -135, -28, 18 },
        -- 猛然下压释放（0.5 ~ 0.6s）
        { 0.6,   "chest",     15, 0, 0 },      -- 前倾下压
        { 0.6,   "rUpperArm", -30, 40, -30 },  -- 双手下压到两侧
        { 0.6,   "rForeArm",  -10, 0, 0 },
        { 0.6,   "lUpperArm", -30, -40, 30 },
        { 0.6,   "lForeArm",  -10, 0, 0 },
        -- 恢复（0.6 ~ 0.7s）
        { 0.7,   "chest",     0, 0, 0 },
        { 0.7,   "rUpperArm", 0, 0, -5 },
        { 0.7,   "rForeArm",  0, 0, 0 },
        { 0.7,   "lUpperArm", 0, 0, 5 },
        { 0.7,   "lForeArm",  0, 0, 0 },
    },
}

-- 受击动画
ANIMS.hit = {
    duration = 0.25,
    looping = false,
    keyframes = {
        { 0.0,   "chest",     0, 0, 0 },
        { 0.08,  "chest",     -15, 8, 0 },     -- 猛然后仰
        { 0.15,  "chest",     -8, -5, 0 },     -- 反弹
        { 0.25,  "chest",     0, 0, 0 },
        { 0.0,   "rUpperArm", 0, 0, -5 },
        { 0.08,  "rUpperArm", 20, 0, -30 },    -- 手臂被甩开
        { 0.25,  "rUpperArm", 0, 0, -5 },
        { 0.0,   "lUpperArm", 0, 0, 5 },
        { 0.08,  "lUpperArm", 20, 0, 30 },
        { 0.25,  "lUpperArm", 0, 0, 5 },
    },
}

PlayerAnim.ANIMS = ANIMS

-- ============================================================================
-- 动画播放
-- ============================================================================
function PlayerAnim.Play(animName, onComplete)
    local anim = ANIMS[animName]
    if not anim then return end

    animState.current = animName
    animState.elapsed = 0
    animState.duration = anim.duration
    animState.onComplete = onComplete
end

function PlayerAnim.IsPlaying(name)
    if name then
        return animState.current == name
    end
    return animState.current ~= "idle" and animState.current ~= "walk"
end

-- ============================================================================
-- 关键帧插值引擎
-- ============================================================================
local function lerpAngle(a, b, t)
    return a + (b - a) * t
end

local function getRotationAtTime(keyframes, boneName, t, duration, looping)
    -- 收集该骨骼的关键帧
    local boneKFs = {}
    for _, kf in ipairs(keyframes) do
        if kf[2] == boneName then
            table.insert(boneKFs, kf)
        end
    end
    if #boneKFs == 0 then return nil end

    -- 循环时间归一化
    if looping then
        t = t % duration
    else
        t = math.min(t, duration)
    end

    -- 找到前后关键帧
    local prevKF = boneKFs[1]
    local nextKF = boneKFs[#boneKFs]

    for i = 1, #boneKFs - 1 do
        if boneKFs[i][1] <= t and boneKFs[i + 1][1] >= t then
            prevKF = boneKFs[i]
            nextKF = boneKFs[i + 1]
            break
        elseif boneKFs[i][1] > t then
            -- t 在第一个关键帧之前
            prevKF = boneKFs[#boneKFs]  -- looping: 用最后一个
            nextKF = boneKFs[i]
            break
        end
    end

    -- 计算插值因子
    local segDur = nextKF[1] - prevKF[1]
    local factor = 0
    if segDur > 0.001 then
        factor = (t - prevKF[1]) / segDur
    end
    -- 平滑插值 (ease in-out)
    factor = factor * factor * (3 - 2 * factor)

    local rx = lerpAngle(prevKF[3], nextKF[3], factor)
    local ry = lerpAngle(prevKF[4], nextKF[4], factor)
    local rz = lerpAngle(prevKF[5], nextKF[5], factor)

    return rx, ry, rz
end

-- ============================================================================
-- 每帧更新
-- ============================================================================
function PlayerAnim.Update(dt, isMoving)
    -- 打击感顿帧
    if hitFeedback.hitPause > 0 then
        hitFeedback.hitPause = hitFeedback.hitPause - dt
        return  -- 冻结动画
    end

    -- 自动切换 idle/walk
    if animState.current == "idle" and isMoving then
        PlayerAnim.Play("walk")
    elseif animState.current == "walk" and not isMoving then
        PlayerAnim.Play("idle")
    end

    -- 更新时间
    local anim = ANIMS[animState.current]
    if not anim then return end

    animState.elapsed = animState.elapsed + dt

    -- 非循环动画结束
    if not anim.looping and animState.elapsed >= anim.duration then
        if animState.onComplete then
            animState.onComplete()
        end
        -- 回到 idle/walk
        if isMoving then
            PlayerAnim.Play("walk")
        else
            PlayerAnim.Play("idle")
        end
        anim = ANIMS[animState.current]
    end

    -- 应用关键帧到骨骼
    for _, boneName in ipairs(BUILD_ORDER) do
        local node = bones[boneName]
        if node then
            local rx, ry, rz = getRotationAtTime(anim.keyframes, boneName, animState.elapsed, anim.duration, anim.looping)
            if rx then
                node.rotation = Quaternion(rx, ry, rz)
            end
        end
    end
    -- 额外可动画节点（武器等，不在 BONE_DEFS 中）
    for _, boneName in ipairs(EXTRA_ANIM_BONES) do
        local node = bones[boneName]
        if node then
            local rx, ry, rz = getRotationAtTime(anim.keyframes, boneName, animState.elapsed, anim.duration, anim.looping)
            if rx then
                node.rotation = Quaternion(rx, ry, rz)
            end
        end
    end

    -- 武士扛刀姿态：idle/walk 时右手扛刀在肩上
    -- 参考传奇造型：右臂侧抬，前臂弯曲让手在右肩旁，刀身搭在肩上向后倾
    if currentClassId == "warrior" then
        local isResting = (animState.current == "idle" or animState.current == "walk")
        if isResting and bones.rUpperArm and bones.rForeArm then
            -- 获取关键帧的基础旋转（呼吸/行走的微动）
            local rx, ry, rz = getRotationAtTime(anim.keyframes, "rUpperArm", animState.elapsed, anim.duration, anim.looping)
            local baseUpper = Quaternion(rx or 0, ry or 0, rz or 0)
            -- 右上臂：向侧面抬起（外展）+ 略向前，像扛东西的自然姿态
            bones.rUpperArm.rotation = baseUpper * Quaternion(-20, 15, -55)
            -- 右前臂：适度弯曲，让手在肩头位置
            bones.rForeArm.rotation = Quaternion(-70, 0, 0)
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
    hitFeedback.hitPause = 0.04 * intensity   -- 顿帧 40ms
    -- 不再触发全屏闪白，仅保留震动和顿帧
end

-- 获取屏幕震动偏移（供相机使用）
function PlayerAnim.GetCameraShakeOffset()
    if hitFeedback.screenShake > 0 then
        local intensity = hitFeedback.shakeIntensity
        local t = hitFeedback.screenShake
        local decay = t / 0.12  -- 衰减
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
-- 攻击动画映射
-- ============================================================================
function PlayerAnim.GetAnimForSkillType(skillType)
    if skillType == "melee" then return "melee"
    elseif skillType == "ranged" then return "ranged"
    elseif skillType == "aoe" then return "melee"       -- AOE 用近战动作
    elseif skillType == "dot" then return "ranged"       -- DOT 用远程动作
    elseif skillType == "summon" then return "summon"
    elseif skillType == "buff" then return "summon"       -- Buff 用召唤动作
    elseif skillType == "heal" then return "summon"
    elseif skillType == "dash" then return "melee"
    end
    return "melee"
end

return PlayerAnim
