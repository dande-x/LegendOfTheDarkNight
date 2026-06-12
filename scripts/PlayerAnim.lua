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
                -- 修复：Root 骨骼有 scale=0.01（FBX cm→m 转换），但 MDL 的逆绑定矩阵
                -- 是基于 Root scale=1.0 计算的。运行时 Root=0.01 导致蒙皮错配放大 100x。
                -- 解决方案：将 Root scale 重置为 1.0，让蒙皮正确工作。
                local rootChild = modelNode_:GetChild("Root")
                if rootChild then
                    local origScale = rootChild.scale.x
                    print("[PlayerAnim] Root bone original scale=" .. string.format("%.4f", origScale))
                    if math.abs(origScale - 0.01) < 0.001 then
                        rootChild.scale = Vector3(1.0, 1.0, 1.0)
                        print("[PlayerAnim] Root bone scale reset to 1.0 (was 0.01)")
                    end
                end

                -- Root scale 已重置为 1.0，蒙皮渲染高度 = bb.height * modelScale
                -- 所以 modelScale = targetHeight / bb.height
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
local animDiagCounter_ = 0

function PlayerAnim.Update(dt, isMoving)
    -- modelNode_ 是 playerNode_ 的子节点，自动继承位置/旋转，无需手动同步

    -- 诊断：每 120 帧检查 worldBoundingBox（仅日志，不修改 scale）
    animDiagCounter_ = animDiagCounter_ + 1
    if animModel_ and animDiagCounter_ % 120 == 1 then
        local wbb = animModel_.worldBoundingBox
        local wbbSize = wbb.size
        local ws = modelNode_.worldScale
        print(string.format("[DIAG-Model] scale=(%.5f) wBBox.h=%.2f",
            ws.x, wbbSize.y))
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

function PlayerAnim.GetAnimModel()
    return animModel_
end

function PlayerAnim.GetAnimController()
    return animCtrl_
end

return PlayerAnim
