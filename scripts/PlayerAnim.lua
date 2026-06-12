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

-- DefaultMale_Base 专属动画（Bip001 骨骼体系，路径引用）
-- 这些动画与 DefaultMale_Base 模型骨骼完全匹配
local ANIM_PATHS = {
    idle       = "DefaultMale/Animations/DefaultMale_Idle.ani",
    walk       = "DefaultMale/Animations/DefaultMale_Walk.ani",
    move       = "DefaultMale/Animations/DefaultMale_Run.ani",
    jump_start = "DefaultMale/Animations/DefaultMale_JumpStart.ani",
    jump_air   = "DefaultMale/Animations/DefaultMale_JumpAir.ani",
    jump_land  = "DefaultMale/Animations/DefaultMale_JumpLanding.ani",
    -- 战斗动画（使用 Rifle 系列临时替代）
    melee      = "DefaultMale/Animations/DefaultMale_RifleShoot.ani",
    melee_alt  = "DefaultMale/Animations/DefaultMale_RifleShoot.ani",
    ranged     = "DefaultMale/Animations/DefaultMale_RifleShoot.ani",
    summon     = "DefaultMale/Animations/DefaultMale_RifleReload.ani",
    die        = "DefaultMale/Animations/DefaultMale_JumpStart.ani",  -- 暂无死亡动画，用跳跃起手代替
}

-- 动画时长（秒）
local ANIM_DURATIONS = {
    idle       = 2.0,
    walk       = 1.0,
    move       = 0.8,
    jump_start = 0.3,
    jump_air   = 1.0,
    jump_land  = 0.5,
    melee      = 0.5,
    melee_alt  = 0.5,
    ranged     = 0.5,
    summon     = 1.5,
    die        = 1.0,
}

-- 动画是否循环
local ANIM_LOOPING = {
    idle  = true,
    walk  = true,
    move  = true,
    jump_air = true,
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
                    modelNode_.scale = Vector3(s, s, s)
                    local footOffset = -minY * s
                    modelNode_.position = Vector3(0, footOffset, 0)
                    print("[PlayerAnim] Applied scale=" .. string.format("%.5f", s)
                        .. " footOffset=" .. string.format("%.5f", footOffset))
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
function PlayerAnim.Play(animName, onComplete)
    local animPath = ANIM_PATHS[animName]
    if not animPath then
        -- 尝试映射别名
        if animName == "walk" then animPath = ANIM_PATHS.walk or ANIM_PATHS.move
        elseif animName == "hit" then animPath = ANIM_PATHS.melee
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
    animCtrl_:PlayExclusive(animPath, 0, isLoop, 0.2)
    animCtrl_:SetSpeed(animPath, 1.0)
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
        -- 恢复动画速度
        if animCtrl_ and ANIM_PATHS[animState.current] then
            animCtrl_:SetSpeed(ANIM_PATHS[animState.current], 1.0)
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

function PlayerAnim.GetAnimModel()
    return animModel_
end

function PlayerAnim.GetAnimController()
    return animCtrl_
end

return PlayerAnim
