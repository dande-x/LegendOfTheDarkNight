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
---@type Node
local playerNode_ = nil  -- 引用玩家节点，用于每帧同步位置

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
-- 创建角色（替代旧的 CreateSkeleton）
-- ============================================================================
function PlayerAnim.CreateSkeleton(playerNode, classId, color, colors)
    currentClassId = classId
    playerNode_ = playerNode

    -- 清理旧模型
    if modelNode_ then
        modelNode_:Remove()
        modelNode_ = nil
        animCtrl_ = nil
        animModel_ = nil
    end

    -- 实例化3D人形预制体（不做 reparent，避免父子变换链与物理引擎冲突）
    local parentScene = playerNode:GetScene()
    modelNode_ = parentScene:InstantiateXML(CHARACTER_PREFAB, playerNode.worldPosition, Quaternion.IDENTITY, LOCAL)
    if not modelNode_ then
        print("[PlayerAnim] ERROR: Failed to instantiate character prefab!")
        return
    end
    modelNode_.name = "CharacterModel"
    -- 不 reparent！保持为场景根节点，每帧手动同步位置/旋转

    -- 获取 AnimatedModel 组件
    animModel_ = modelNode_:GetComponent("AnimatedModel")
    if not animModel_ then
        -- 尝试从子节点获取
        animModel_ = modelNode_:GetComponent("AnimatedModel", true)
    end

    -- 根据实际 BoundingBox 自动缩放到合理高度（目标 1.6m）
    if animModel_ then
        local bb = animModel_.boundingBox
        local actualHeight = bb.size.y
        print("[PlayerAnim] Model bounding box height: " .. tostring(actualHeight))
        if actualHeight > 0 then
            local desiredHeight = 1.6  -- 目标角色高度（米）
            local scaleFactor = desiredHeight / actualHeight
            modelNode_.scale = Vector3(scaleFactor, scaleFactor, scaleFactor)
            print("[PlayerAnim] Auto-scale factor: " .. tostring(scaleFactor))
        end
    else
        modelNode_.scale = Vector3(0.01, 0.01, 0.01)  -- 安全 fallback
    end

    -- 创建 AnimationController
    animCtrl_ = modelNode_:GetOrCreateComponent("AnimationController")

    -- 应用职业材质
    PlayerAnim._ApplyClassMaterial(classId, color)

    print("[PlayerAnim] Character created: " .. classId .. " (3D model, scene-level node)")
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
    -- 同步模型位置/旋转到玩家节点（不使用 parent 继承，手动同步）
    if modelNode_ and playerNode_ then
        modelNode_.worldPosition = playerNode_.worldPosition
        modelNode_.worldRotation = playerNode_.worldRotation
    end

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
