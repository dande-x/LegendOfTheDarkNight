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

local function ApplyClassMaterial(classId)
    if not animModel_ then return end

    local classMod = ClassModules[classId] or ClassModules.warrior
    local config = classMod.material

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
    weaponNode_.position = config.offset
    weaponNode_.rotation = config.rotation
    weaponNode_.scale = config.scale

    classMod.buildWeapon(weaponNode_)

    local ws = weaponNode_.worldScale
    print(string.format("[PlayerAnim] Weapon attached: %s → %s | worldScale=(%.4f,%.4f,%.4f)",
        config.name, config.bone, ws.x, ws.y, ws.z))
end

-- ============================================================================
-- 创建角色
-- ============================================================================
function PlayerAnim.CreateSkeleton(playerNode, classId, color, colors)
    print("[PlayerAnim] CreateSkeleton called: " .. tostring(classId))
    currentClassId = classId
    playerNode_ = playerNode

    if modelNode_ then
        modelNode_:Remove()
        modelNode_ = nil
        animCtrl_ = nil
        animModel_ = nil
    end

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

        if animCtrl_ and ANIM_PATHS.idle then
            animCtrl_:PlayExclusive(ANIM_PATHS.idle, 0, true, 0.0)
            animState.current = "idle"
        end

        ApplyClassMaterial(classId)
        AttachWeapon(classId)
    end

    print("[PlayerAnim] Character created: " .. classId)
end

-- ============================================================================
-- 动画播放
-- ============================================================================
function PlayerAnim.Play(animName, onComplete, opts)
    local animPath = ANIM_PATHS[animName]
    if not animPath then
        if animName == "hit" then animPath = ANIM_PATHS.melee_fast
        else return end
    end

    if not animCtrl_ then return end

    local speed = (opts and opts.speed) or 1.0
    local isLoop = ANIM_LOOPING[animName] or false
    local duration = (opts and opts.duration) or ANIM_DURATIONS[animName] or 1.0

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

function PlayerAnim.PlaySkill(skillType, onComplete)
    local classMod = ClassModules[currentClassId] or ClassModules.warrior
    local config = classMod.skillAnims[skillType] or classMod.skillAnims.melee

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
    if hitFeedback.hitPause > 0 then
        hitFeedback.hitPause = hitFeedback.hitPause - dt
        if animCtrl_ and ANIM_PATHS[animState.current] then
            animCtrl_:SetSpeed(ANIM_PATHS[animState.current], 0.0)
        end
        return
    else
        if animCtrl_ and ANIM_PATHS[animState.current] then
            animCtrl_:SetSpeed(ANIM_PATHS[animState.current], animState.speed or 1.0)
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
