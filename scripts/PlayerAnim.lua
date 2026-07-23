---@diagnostic disable: assign-type-mismatch
-- ============================================================================
-- PlayerAnim.lua — 传奇风格3D角色动画系统（核心模块）
-- 职业独立模块: classes/Warrior.lua, classes/Mage.lua, classes/Taoist.lua
-- ============================================================================

local PlayerAnim = {}

-- 加载职业模块
local ClassModules = {
    warrior = require("classes.Warrior"),
    mage    = require("classes.Mage"),
    taoist  = require("classes.Taoist"),
}

-- ============================================================================
-- 状态管理
-- ============================================================================
local animState = {
    current = "idle",
    elapsed = 0,
    duration = 0,
    speed = 1.0,
    onComplete = nil,
}

local hitFeedback = {
    screenShake = 0,
    shakeIntensity = 0,
    hitPause = 0,
    flashTimer = 0,
}

local currentClassId = "warrior"
local currentModelStyle = "old"
local currentGender = "male"

---@type Node
local modelNode_ = nil
---@type AnimationController
local animCtrl_ = nil
---@type AnimatedModel
local animModel_ = nil
---@type Node
local playerNode_ = nil

local baseScale_ = 1.0
local baseFootOffset_ = 0.0
local TARGET_HEIGHT_ = 1.6

PlayerAnim.animState = animState
PlayerAnim.hitFeedback = hitFeedback

-- ============================================================================
-- 角色预制体和动画资源 UUID
-- ============================================================================
local CHARACTER_PREFAB = "Prefabs/LegendWarrior.prefab"

-- 新角色模型按性别和职业映射。当前男性职业共用男性基础模型；
-- 女性武士使用已穿戴武士装备的专用模型，女性法师和道士继续共用女性基础模型。
-- 旧模型路径保持原样，确保旧存档和原有职业外观逻辑不受影响。
local NEW_CHARACTER_PREFABS = {
    male = {
        warrior = "model/33542021dc2e421f80edbbaf04c9f4b5/Prefabs/rig-1-9fd97390-f993-4ec1-8e2f-95e79f6583d9.prefab",
        mage = "model/33542021dc2e421f80edbbaf04c9f4b5/Prefabs/rig-1-9fd97390-f993-4ec1-8e2f-95e79f6583d9.prefab",
        taoist = "model/33542021dc2e421f80edbbaf04c9f4b5/Prefabs/rig-1-9fd97390-f993-4ec1-8e2f-95e79f6583d9.prefab",
    },
    female = {
        warrior = "model/4e4dfbd1c5614236995be1033de34e24/Prefabs/rig-1-96b79026-4057-4dce-8f3d-70328dab0da9.prefab",
        mage = "model/3adc443e7a73436282b6f2349c1be7c4/Prefabs/rig-1-d76f31e6-a0c1-4d45-a3a7-c4de592bc3bf.prefab",
        taoist = "model/3adc443e7a73436282b6f2349c1be7c4/Prefabs/rig-1-d76f31e6-a0c1-4d45-a3a7-c4de592bc3bf.prefab",
    },
}

local function GetCharacterPrefab(classId, classMod, modelStyle, gender)
    if modelStyle == "new" then
        local genderSet = NEW_CHARACTER_PREFABS[gender or "male"]
            or NEW_CHARACTER_PREFABS.male
        return genderSet[classId] or genderSet.warrior
    end
    return classMod.prefab or CHARACTER_PREFAB
end

local ANIM_PATHS = {
    -- 基础移动
    idle       = "uuid://GikiEX04hbY9D5ALGNz051Zh",  -- 枪骑士战斗待机 1.33s loop
    move       = "uuid://F-afGUmbZwlJu4crZmqR_4kR",  -- 枪骑士中速推进跑 1.0s loop
    walk       = "uuid://F-afGUmbZwlJu4crZmqR_4kR",
    charge     = "uuid://CTyqSX1Y6TCSZnO1QexmJKeY",  -- 枪骑士高速冲刺 0.53s loop
    combat_idle = "uuid://GikiEX04hbY9D5ALGNz051Zh",
    -- 近战攻击 — 杨戬(标准男)
    melee_fast  = "uuid://Ai-SCaONHGJAnRCLZmoO2QJ8",  -- 突刺穿心 1.07s
    melee_heavy = "uuid://HFCMaTM1TqMyp12CL-treYHh",  -- 斜劈重斩 1.07s
    -- 大刀横扫 — 孙悟空(标准男)
    sweep_l     = "uuid://BzVkoQzPfkBeIJ_SyLQNwXpI",  -- 横扫千军(右→左) 1.33s
    sweep_r     = "uuid://D-C1MUEUyoUVTkEJmbeUro0h",  -- 横扫千军(左→右) 1.33s
    spin_strike = "uuid://GOoyyZiJ_QmP1e_y3jqnYMrI",  -- 回旋劈击 1.67s
    -- 施法攻击 — 魔法导师(标准男)
    cast_quick  = "uuid://E3rZmUDaM9pq2-V2gj3pCyW4",  -- 挥击 1.5s
    cast_long   = "uuid://Hs3_meWUZg22cD1e_0d-BCO6",  -- 法杖重砸 1.5s
    cast_heavy  = "uuid://Bt3J4RQwGIykpkw8NH1NGZEC",  -- 重击 1.5s
    -- 法杖猛砸 — 森林守护者(标准男)
    staff_slam  = "uuid://AG7o2TcvrluLScFMCJltgkkF",  -- 法杖猛砸 1.37s
    -- 冲锋突刺 — 杨戬(标准男)
    dash_strike = "uuid://C1NO-SdM51lg1PCrBmXoiUWO",  -- 突刺重击 1.33s
    -- 技能/跳跃/死亡
    skill_01    = "uuid://EUvBwU0-VB_KCvzQldvwX1gF",  -- 重劈起手 1.07s
    jump_start  = "uuid://GikiEX04hbY9D5ALGNz051Zh",
    jump_air    = "uuid://GikiEX04hbY9D5ALGNz051Zh",
    jump_land   = "uuid://GikiEX04hbY9D5ALGNz051Zh",
    die         = "uuid://EUvBwU0-VB_KCvzQldvwX1gF",
}

local ANIM_SETS = {
    male = ANIM_PATHS,
}

local currentAnimPaths = ANIM_SETS.male

local function SelectAnimSet(classId, classMod)
    local setName = classMod.animSet or "male"
    currentAnimPaths = ANIM_SETS[setName] or ANIM_SETS.male
    print(string.format("[PlayerAnim] Animation set selected: %s -> %s", tostring(classId), setName))
end

local function GetCurrentAnimPaths()
    return currentAnimPaths or ANIM_PATHS
end

local function ResolvePlayedAnimName(animName)
    local classMod = ClassModules[currentClassId] or ClassModules.warrior

    if currentModelStyle == "new"
        and animName == "idle"
        and classMod.poseAnims
        and classMod.poseAnims.hold then
        return classMod.poseAnims.hold
    end

    return animName
end

-- 动画时长
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
    sweep_l     = 1.33,
    sweep_r     = 1.33,
    spin_strike = 1.67,
    cast_quick  = 1.5,
    cast_long   = 1.5,
    cast_heavy  = 1.5,
    staff_slam  = 1.37,
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
-- 职业外观材质
-- ============================================================================
local ORIGINAL_TEXTURE_UUID = "uuid://ARGvkYnzrbbOxkjh2N68upmG"

local function ApplyClassMaterial(classId, modelStyle)
    if not animModel_ then return end

    local classMod = ClassModules[classId] or ClassModules.warrior
    local config = classMod.material

    -- 新模型保留自身 PBR 材质，避免职业贴图覆盖基础体型；旧模型沿用原逻辑。
    if modelStyle == "new" then
        print(string.format("[PlayerAnim] New model keeps base PBR material: %s", classId))
        return
    end

    -- 如果职业使用独立模型且不覆盖材质，保留模型自带贴图
    if classMod.prefab and not config.useTexture then
        print(string.format("[PlayerAnim] Class '%s' uses own prefab material, skipping override", classId))
        return
    end

    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", config.technique))

    if config.useTexture then
        mat:SetTexture(TU_DIFFUSE, cache:GetResource("Texture2D", ORIGINAL_TEXTURE_UUID))
    end

    mat:SetShaderParameter("MatDiffColor", Variant(config.diffColor))
    mat:SetShaderParameter("Roughness", Variant(config.roughness))
    mat:SetShaderParameter("Metallic", Variant(config.metallic))
    mat:SetShaderParameter("MatEmissiveColor", Variant(config.emissive))

    local numGeom = animModel_:GetNumGeometries()
    for i = 0, numGeom - 1 do
        animModel_:SetMaterial(i, mat)
    end

    print(string.format("[PlayerAnim] Class material applied: %s", classId))
end

-- ============================================================================
-- 武器系统
-- ============================================================================
---@type Node
local weaponNode_ = nil

local LEGACY_MALE_MODEL_HEIGHTS = {
    warrior = 1.85,
    mage = 1.80,
    taoist = 1.85,
}

local function GetWeaponScaleCompensation(classId)
    if currentModelStyle == "new" and baseScale_ > 0 then
        -- 新男女模型原始高度约 1m，归一化到 TARGET_HEIGHT_ 后会同步放大武器和握点偏移。
        -- 按对应男性旧职业模型的原始高度反向补偿，复刻旧模型的武器世界尺寸与掌心位置。
        local legacyHeight = LEGACY_MALE_MODEL_HEIGHTS[classId]
        if legacyHeight then
            local legacyModelScale = TARGET_HEIGHT_ / legacyHeight
            return legacyModelScale / baseScale_
        end
    end
    return 1.0
end

local function GetWeaponRotation(classId, config)
    if classId == "warrior"
        and currentModelStyle == "new"
        and currentGender == "female" then
        -- 女性新模型的 R_Hand 局部前后轴与男性旧模型相反，
        -- 仅翻转武器局部朝向，避免改动骨骼动画和男性旧模型。
        return Quaternion(0, 180, 0) * config.rotation
    end
    return config.rotation
end

local function AttachWeapon(classId)
    if weaponNode_ then
        weaponNode_:Remove()
        weaponNode_ = nil
    end

    if not animModel_ then return end

    local classMod = ClassModules[classId] or ClassModules.warrior
    local config = classMod.weapon

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

    weaponNode_ = boneNode:CreateChild(config.name)
    local scaleCompensation = GetWeaponScaleCompensation(classId)
    weaponNode_.position = config.offset * scaleCompensation
    weaponNode_.rotation = GetWeaponRotation(classId, config)
    weaponNode_.scale = config.scale * scaleCompensation

    classMod.buildWeapon(weaponNode_)

    local ws = weaponNode_.worldScale
    print(string.format("[PlayerAnim] Weapon attached: %s → %s | rotation=%s | scaleComp=%.4f | worldScale=(%.4f,%.4f,%.4f)",
        config.name, config.bone, weaponNode_.rotation:ToString(), scaleCompensation, ws.x, ws.y, ws.z))
end

function PlayerAnim.GetPrefabPath(classId, modelStyle, gender)
    local classMod = ClassModules[classId] or ClassModules.warrior
    return GetCharacterPrefab(classId, classMod, modelStyle, gender)
end

function PlayerAnim.CreateSkeleton(playerNode, classId, color, colors, modelStyle, gender)
    print("[PlayerAnim] CreateSkeleton called: " .. tostring(classId)
        .. " style=" .. tostring(modelStyle or "old")
        .. " gender=" .. tostring(gender or "male"))
    currentClassId = classId
    currentModelStyle = modelStyle or "old"
    currentGender = gender or "male"
    playerNode_ = playerNode

    local classMod = ClassModules[classId] or ClassModules.warrior
    SelectAnimSet(classId, classMod)

    if modelNode_ then
        modelNode_:Remove()
        modelNode_ = nil
        animCtrl_ = nil
        animModel_ = nil
    end

    local ok, err = pcall(function()
        local parentScene = playerNode:GetScene()
        -- 新模型按性别和职业选择，旧模型继续按职业选择。
        local prefabPath = GetCharacterPrefab(
            classId,
            classMod,
            modelStyle,
            gender
        )
        print("[PlayerAnim] Loading character prefab: " .. prefabPath)
        local prefabFile = cache:GetFile(prefabPath)
        if not prefabFile then
            print("[PlayerAnim] ERROR: Cannot find prefab: " .. prefabPath)
            return
        end

        local prefabNode = parentScene:InstantiateXML(prefabFile, Vector3.ZERO, Quaternion.IDENTITY, LOCAL)
        prefabFile:Close()

        if prefabNode then
            prefabNode.parent = playerNode
            prefabNode.name = "CharacterModel"
            modelNode_ = prefabNode

            animModel_ = modelNode_:GetComponent("AnimatedModel")
            if not animModel_ then
                animModel_ = modelNode_:GetComponent("AnimatedModel", true)
            end

            if animModel_ then
                local bb = animModel_.boundingBox
                local h = bb.size.y
                local minY = bb.min.y

                if h > 0 then
                    local s = TARGET_HEIGHT_ / h
                    baseScale_ = s
                    baseFootOffset_ = -minY * s
                    modelNode_.scale = Vector3(s, s, s)
                    modelNode_.position = Vector3(0, baseFootOffset_, 0)
                end
            else
                print("[PlayerAnim] WARNING: No AnimatedModel found in prefab!")
            end
        end
    end)

    if not ok then
        print("[PlayerAnim] Prefab load error: " .. tostring(err))
    end

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
        animCtrl_ = modelNode_:GetComponent("AnimationController")
            or modelNode_:GetComponent("AnimationController", true)
        if not animCtrl_ then
            animCtrl_ = modelNode_:CreateComponent("AnimationController")
        end

        local animPaths = GetCurrentAnimPaths()
        local holdAnimName = ResolvePlayedAnimName("idle")
        local holdAnimPath = animPaths[holdAnimName] or animPaths.idle
        if animCtrl_ and holdAnimPath then
            animCtrl_:PlayExclusive(holdAnimPath, 0, true, 0.0)
            animState.current = "idle"
        end

        print(string.format(
            "[PlayerAnim] Legacy male pose mapping: hold=%s attack=%s",
            tostring(classMod.poseAnims and classMod.poseAnims.hold or "idle"),
            tostring(classMod.poseAnims and classMod.poseAnims.attack or "skill mapping")
        ))

        ApplyClassMaterial(classId, modelStyle)
        AttachWeapon(classId)
    end

    print("[PlayerAnim] Character created: " .. classId)
end

-- ============================================================================
-- 动画播放
-- ============================================================================
function PlayerAnim.Play(animName, onComplete, opts)
    local animPaths = GetCurrentAnimPaths()
    local stateName = animName
    local playedAnimName = ResolvePlayedAnimName(stateName)
    local animPath = animPaths[playedAnimName]
    if not animPath then
        if stateName == "hit" then animPath = animPaths.melee_fast
        else return end
    end

    if not animCtrl_ then return end

    local speed = (opts and opts.speed) or 1.0
    local isLoop = ANIM_LOOPING[stateName] or false
    local duration = (opts and opts.duration) or ANIM_DURATIONS[stateName] or 1.0

    if animState.current == stateName and isLoop then
        return
    end

    animState.current = stateName
    animState.elapsed = 0
    animState.duration = duration
    animState.onComplete = onComplete
    animState.speed = speed

    animCtrl_:PlayExclusive(animPath, 0, isLoop, 0.15)
    animCtrl_:SetSpeed(animPath, speed)
end

function PlayerAnim.PlaySkill(skillType, onComplete)
    local classMod = ClassModules[currentClassId] or ClassModules.warrior
    local config = classMod.skillAnims[skillType] or classMod.skillAnims.melee
    local animName = config.anim

    -- 所有新模型复用对应男性旧职业的普通攻击动作；旧模型保持原职业逻辑。
    if currentModelStyle == "new"
        and classMod.poseAnims
        and skillType == "melee" then
        animName = classMod.poseAnims.attack
    end

    PlayerAnim.Play(animName, onComplete, {
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
    local animPaths = GetCurrentAnimPaths()
    local playedAnimName = ResolvePlayedAnimName(animState.current)
    local currentAnimPath = animPaths[playedAnimName]

    if hitFeedback.hitPause > 0 then
        hitFeedback.hitPause = hitFeedback.hitPause - dt
        if animCtrl_ and currentAnimPath then
            animCtrl_:SetSpeed(currentAnimPath, 0.0)
        end
        return
    else
        if animCtrl_ and currentAnimPath then
            animCtrl_:SetSpeed(currentAnimPath, animState.speed or 1.0)
        end
    end

    if animState.current == "idle" and isMoving then
        PlayerAnim.Play("move")
    elseif (animState.current == "move" or animState.current == "walk") and not isMoving then
        PlayerAnim.Play("idle")
    end

    animState.elapsed = animState.elapsed + dt

    local isLoop = ANIM_LOOPING[animState.current] or false
    if not isLoop and animState.elapsed >= animState.duration then
        if animState.onComplete then
            animState.onComplete()
        end
        if isMoving then
            PlayerAnim.Play("move")
        else
            PlayerAnim.Play("idle")
        end
    end

    if hitFeedback.screenShake > 0 then
        hitFeedback.screenShake = hitFeedback.screenShake - dt
    end
    if hitFeedback.flashTimer > 0 then
        hitFeedback.flashTimer = hitFeedback.flashTimer - dt
    end
end

-- ============================================================================
-- 打击感
-- ============================================================================
function PlayerAnim.TriggerHitFeedback(intensity)
    intensity = intensity or 1.0
    hitFeedback.screenShake = 0.12 * intensity
    hitFeedback.shakeIntensity = 0.15 * intensity
    hitFeedback.hitPause = 0.04 * intensity
end

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

function PlayerAnim.IsFlashing()
    return hitFeedback.flashTimer > 0
end

-- ============================================================================
-- 兼容接口
-- ============================================================================
function PlayerAnim.GetSkillAnimConfig(skillType)
    local classMod = ClassModules[currentClassId] or ClassModules.warrior
    return classMod.skillAnims[skillType] or classMod.skillAnims.melee
end

function PlayerAnim.GetAnimForSkillType(skillType)
    local config = PlayerAnim.GetSkillAnimConfig(skillType)
    return config.anim
end

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
-- PostUpdate
-- ============================================================================
function PlayerAnim.PostUpdate()
    if not modelNode_ then return end
    modelNode_.scale = Vector3(baseScale_, baseScale_, baseScale_)
    modelNode_.position = Vector3(0, baseFootOffset_, 0)
end

return PlayerAnim
