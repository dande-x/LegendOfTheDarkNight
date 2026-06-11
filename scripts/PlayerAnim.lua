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
    current = "idle",     -- idle | walk | melee | ranged | summon | hit | death
    elapsed = 0,
    duration = 0,
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

PlayerAnim.animState = animState
PlayerAnim.hitFeedback = hitFeedback

-- ============================================================================
-- 角色预制体和动画资源 UUID
-- ============================================================================
local CHARACTER_PREFAB = "uuid://DEkZaUTQvLlCdjdIzpnHa4n-"  -- DefaultMale_Base (标准男骨架)

-- 动画 UUID 引用（全部兼容"标准男"骨架）
local ANIM_UUIDS = {
    idle       = "uuid://G7yDSZdD2lEh3EdNzc0MGQkV",  -- 杨戬待机警戒 1.6s 可循环
    move       = "uuid://CLwWYfIHxVykOtlpDhB_-T2E",  -- 皇帝中速战斗奔跑 0.8s 可循环
    -- 武士攻击
    melee      = "uuid://HFCMaTM1TqMyp12CL-treYHh",  -- 斜劈重斩 1.07s
    melee_alt  = "uuid://Ai-SCaONHGJAnRCLZmoO2QJ8",  -- 突刺穿心 1.07s
    -- 法师/道士攻击
    ranged     = "uuid://Bt3J4RQwGIykpkw8NH1NGZEC",  -- 魔法导师重击 1.5s
    summon     = "uuid://HNZkaRcCKM51-9ZXmCoIfPot",  -- 能量推掌施法 2.0s
    -- 通用
    die        = "uuid://AUfu8YE3YF2txEtOpyr2CSci",  -- 受击倒地 2.6s
}

-- 动画时长（秒）
local ANIM_DURATIONS = {
    idle       = 1.6,
    move       = 0.8,
    melee      = 1.067,
    melee_alt  = 1.067,
    ranged     = 1.5,
    summon     = 2.0,
    die        = 2.6,
}

-- 动画是否循环
local ANIM_LOOPING = {
    idle  = true,
    move  = true,
}

-- 职业对应的铠甲贴图
local ARMOR_TEXTURES = {
    warrior = "image/tex_ink_warrior_armor_20260611120705.png",
    mage    = "image/tex_ink_mage_robe_20260611120705.png",
    taoist  = "image/tex_ink_taoist_robe_20260611120659.png",
}

-- 职业主色调（用于材质着色）
local CLASS_TINT = {
    warrior = Color(0.85, 0.25, 0.18, 1.0),  -- 朱红
    mage    = Color(0.20, 0.45, 0.82, 1.0),  -- 靛蓝
    taoist  = Color(0.25, 0.68, 0.45, 1.0),  -- 翡翠绿
}

-- ============================================================================
-- 创建角色（替代旧的 CreateSkeleton）
-- ============================================================================
function PlayerAnim.CreateSkeleton(playerNode, classId, color, colors)
    currentClassId = classId

    -- 清理旧模型
    if modelNode_ then
        modelNode_:Remove()
        modelNode_ = nil
        animCtrl_ = nil
        animModel_ = nil
    end

    -- 实例化3D人形预制体（从playerNode的scene获取）
    local parentScene = playerNode:GetScene()
    modelNode_ = parentScene:InstantiateXML(CHARACTER_PREFAB, Vector3.ZERO, Quaternion.IDENTITY, LOCAL)
    if not modelNode_ then
        print("[PlayerAnim] ERROR: Failed to instantiate character prefab!")
        return
    end
    modelNode_.name = "CharacterModel"
    modelNode_.parent = playerNode
    modelNode_.position = Vector3(0, 0, 0)
    modelNode_.rotation = Quaternion.IDENTITY

    -- 获取 AnimatedModel 组件
    animModel_ = modelNode_:GetComponent("AnimatedModel")
    if not animModel_ then
        -- 尝试从子节点获取
        animModel_ = modelNode_:GetComponent("AnimatedModel", true)
    end

    -- 创建 AnimationController
    animCtrl_ = modelNode_:GetOrCreateComponent("AnimationController")

    -- 应用职业材质（用水墨铠甲贴图覆盖默认材质）
    PlayerAnim._ApplyClassMaterial(classId, color)

    print("[PlayerAnim] Character created: " .. classId .. " (3D model with skeleton)")
end

-- ============================================================================
-- 职业材质覆盖
-- ============================================================================
function PlayerAnim._ApplyClassMaterial(classId, baseColor)
    if not animModel_ then return end

    local texPath = ARMOR_TEXTURES[classId]
    local tint = CLASS_TINT[classId] or baseColor

    ---@type Texture2D
    local armorTex = texPath and cache:GetResource("Texture2D", texPath) or nil

    -- 获取当前模型的材质数量
    local numMats = animModel_:GetNumGeometries()

    for i = 0, numMats - 1 do
        local mat = Material:new()

        if armorTex then
            -- 使用水墨风贴图材质
            mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRMetallicRoughDiffNormalSpec.xml"))
            mat:SetTexture(TU_DIFFUSE, armorTex)
            mat:SetShaderParameter("MatDiffColor", Variant(Color(tint.r * 1.2, tint.g * 1.2, tint.b * 1.2, 1.0)))
            mat:SetShaderParameter("Roughness", Variant(0.45))
            mat:SetShaderParameter("Metallic", Variant(0.3))
            -- 微发光边缘
            mat:SetShaderParameter("MatEmissiveColor", Variant(Color(tint.r * 0.06, tint.g * 0.06, tint.b * 0.06)))
        else
            -- 纯色 fallback
            mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
            mat:SetShaderParameter("MatDiffColor", Variant(tint))
            mat:SetShaderParameter("Roughness", Variant(0.5))
            mat:SetShaderParameter("Metallic", Variant(0.3))
        end

        animModel_:SetMaterial(i, mat)
    end
end

-- ============================================================================
-- 动画播放
-- ============================================================================
function PlayerAnim.Play(animName, onComplete)
    local uuid = ANIM_UUIDS[animName]
    if not uuid then
        -- 尝试映射别名
        if animName == "walk" then uuid = ANIM_UUIDS.move
        elseif animName == "hit" then uuid = ANIM_UUIDS.melee  -- 受击使用短攻击动画凑合
        else return end
    end

    if not animCtrl_ then return end

    local isLoop = ANIM_LOOPING[animName] or false
    local duration = ANIM_DURATIONS[animName] or 1.0

    -- 如果是同一个循环动画已经在播放，不重复触发
    if animState.current == animName and isLoop then
        return
    end

    animState.current = animName
    animState.elapsed = 0
    animState.duration = duration
    animState.onComplete = onComplete

    -- 使用 PlayExclusive 播放（自动淡出其他动画）
    animCtrl_:PlayExclusive(uuid, 0, isLoop, 0.2)
    animCtrl_:SetSpeed(uuid, 1.0)
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
        -- 暂停动画
        if animCtrl_ and ANIM_UUIDS[animState.current] then
            animCtrl_:SetSpeed(ANIM_UUIDS[animState.current], 0.0)
        end
        return
    else
        -- 恢复动画速度
        if animCtrl_ and ANIM_UUIDS[animState.current] then
            animCtrl_:SetSpeed(ANIM_UUIDS[animState.current], 1.0)
        end
    end

    -- 自动切换 idle/walk
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
        -- 回到 idle/walk
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
-- 攻击动画映射
-- ============================================================================
function PlayerAnim.GetAnimForSkillType(skillType)
    if skillType == "melee" then return "melee"
    elseif skillType == "ranged" then return "ranged"
    elseif skillType == "aoe" then return "melee"
    elseif skillType == "dot" then return "ranged"
    elseif skillType == "summon" then return "summon"
    elseif skillType == "buff" then return "summon"
    elseif skillType == "heal" then return "summon"
    elseif skillType == "dash" then return "melee"
    end
    return "melee"
end

-- ============================================================================
-- 获取模型节点（供外部挂载特效等使用）
-- ============================================================================
function PlayerAnim.GetModelNode()
    return modelNode_
end

function PlayerAnim.GetAnimController()
    return animCtrl_
end

return PlayerAnim
