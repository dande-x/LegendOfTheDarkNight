-- =============================================================================
-- 动画单元测试：验证攻击动画表现正常
-- 测试项：
--   1. 角色可见性（worldBoundingBox 合理尺寸）
--   2. Bip001 scale 在任何动画下稳定为 0.01
--   3. 攻击动画时子骨骼（UpperArm 等）有旋转变化（非静止）
--   4. modelNode scale 稳定不跳变
-- 用法：构建入口设为 test_anim.lua，预览后看控制台输出 [PASS]/[FAIL]
-- =============================================================================

require "LuaScripts/Utilities/Sample"

local PlayerAnim = require("scripts.PlayerAnim")

---@type Scene
local scene_ = nil
---@type Node
local playerNode_ = nil

-- 测试状态
local testPhase = "init"        -- init → idle_check → attack_start → attack_check → done
local phaseTimer = 0.0
local frameCount = 0
local results = {}              -- { {name, pass, detail}, ... }

-- 骨骼采样数据
local bip001Scales = {}         -- 收集多帧 Bip001 scale
local upperArmRotations = {}    -- 收集多帧 UpperArm rotation（检测运动）
local modelScales = {}          -- 收集多帧 modelNode scale

-- ---------- 工具函数 ----------

local function addResult(name, pass, detail)
    table.insert(results, { name = name, pass = pass, detail = detail or "" })
    local tag = pass and "[PASS]" or "[FAIL]"
    print(string.format("%s %s %s", tag, name, detail or ""))
end

local function printSummary()
    print("\n========== 动画测试结果 ==========")
    local passCount = 0
    for _, r in ipairs(results) do
        local tag = r.pass and "✓" or "✗"
        print(string.format("  %s %s %s", tag, r.name, r.detail))
        if r.pass then passCount = passCount + 1 end
    end
    print(string.format("\n总计: %d/%d 通过", passCount, #results))
    if passCount == #results then
        print("[ALL PASS] 所有动画测试通过！")
    else
        print("[HAS FAILURES] 存在失败项，请检查!")
    end
    print("==================================\n")
end

-- ---------- 采样 ----------

local function sampleBones()
    local animModel = PlayerAnim.GetAnimModel()
    if not animModel then return end

    local skeleton = animModel:GetSkeleton()
    if not skeleton then return end

    -- Bip001 scale
    local bip001 = skeleton:GetBone("Bip001")
    if bip001 and bip001.node then
        table.insert(bip001Scales, {
            x = bip001.node.scale.x,
            y = bip001.node.scale.y,
            z = bip001.node.scale.z,
        })
    end

    -- UpperArm rotation（右上臂 — 挥剑动作核心骨骼）
    local armBone = skeleton:GetBone("Bip001 R UpperArm")
    if not armBone then
        armBone = skeleton:GetBone("Bip001 L UpperArm")
    end
    if armBone and armBone.node then
        local rot = armBone.node.rotation
        table.insert(upperArmRotations, {
            w = rot.w, x = rot.x, y = rot.y, z = rot.z,
        })
    end

    -- modelNode scale
    local modelNode = PlayerAnim.GetModelNode()
    if modelNode then
        table.insert(modelScales, {
            x = modelNode.scale.x,
            y = modelNode.scale.y,
            z = modelNode.scale.z,
        })
    end
end

-- ---------- 验证逻辑 ----------

local function checkVisibility(phase)
    local animModel = PlayerAnim.GetAnimModel()
    if not animModel then
        addResult(phase .. "-角色可见性", false, "AnimatedModel 为 nil")
        return
    end
    local wbb = animModel.worldBoundingBox
    local size = wbb.size
    -- 角色高约 1.6m，合理范围 0.5~5.0
    local h = size.y
    local modelNode = PlayerAnim.GetModelNode()
    local msStr = modelNode and string.format("modelScale=%.4f", modelNode.scale.x) or "?"
    if h >= 0.5 and h <= 5.0 then
        addResult(phase .. "-角色可见性", true,
            string.format("高度=%.2fm (%s)", h, msStr))
    else
        addResult(phase .. "-角色可见性", false,
            string.format("高度=%.2fm (异常! 期望0.5~5.0m, %s)", h, msStr))
    end
end

local function checkBip001Scale()
    if #bip001Scales == 0 then
        addResult("Bip001 scale 稳定性", false, "无采样数据")
        return
    end
    local allGood = true
    local maxDeviation = 0
    for _, s in ipairs(bip001Scales) do
        local dev = math.abs(s.x - 0.01) + math.abs(s.y - 0.01) + math.abs(s.z - 0.01)
        maxDeviation = math.max(maxDeviation, dev)
        if dev > 0.001 then  -- 允许微小浮点误差
            allGood = false
        end
    end
    if allGood then
        addResult("Bip001 scale 稳定性", true,
            string.format("全部为0.01 (采样%d帧, 最大偏差%.6f)", #bip001Scales, maxDeviation))
    else
        addResult("Bip001 scale 稳定性", false,
            string.format("存在非0.01值! 最大偏差=%.6f (采样%d帧)", maxDeviation, #bip001Scales))
    end
end

local function checkArmMotion()
    if #upperArmRotations < 5 then
        addResult("攻击骨骼运动", false,
            string.format("采样不足(仅%d帧，需≥5)", #upperArmRotations))
        return
    end
    -- 计算首尾旋转差异（四元数点积，1.0=完全相同）
    local first = upperArmRotations[1]
    local last = upperArmRotations[#upperArmRotations]
    local dot = first.w * last.w + first.x * last.x + first.y * last.y + first.z * last.z
    dot = math.abs(dot)  -- 四元数 q 和 -q 代表同一旋转

    -- 计算最大变化量（遍历相邻帧）
    local maxDelta = 0
    for i = 2, #upperArmRotations do
        local a = upperArmRotations[i - 1]
        local b = upperArmRotations[i]
        local d = math.abs(a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z)
        local delta = 1.0 - d
        maxDelta = math.max(maxDelta, delta)
    end

    -- 如果动画在播放，骨骼应有明显旋转变化
    if maxDelta > 0.001 then
        addResult("攻击骨骼运动", true,
            string.format("UpperArm 有旋转变化 (最大帧间delta=%.4f, 首尾dot=%.4f)", maxDelta, dot))
    else
        addResult("攻击骨骼运动", false,
            string.format("UpperArm 无运动! (最大帧间delta=%.6f) — 动画可能未播放或骨骼静止", maxDelta))
    end
end

local function checkModelScaleStability()
    if #modelScales < 5 then
        addResult("modelNode scale 稳定性", false,
            string.format("采样不足(仅%d帧)", #modelScales))
        return
    end
    local first = modelScales[1]
    local maxDev = 0
    for _, s in ipairs(modelScales) do
        local dev = math.abs(s.x - first.x) + math.abs(s.y - first.y) + math.abs(s.z - first.z)
        maxDev = math.max(maxDev, dev)
    end
    if maxDev < 0.01 then
        addResult("modelNode scale 稳定性", true,
            string.format("scale恒定=%.4f (最大偏差%.6f, 采样%d帧)", first.x, maxDev, #modelScales))
    else
        addResult("modelNode scale 稳定性", false,
            string.format("scale跳变! 初始=%.4f, 最大偏差=%.4f — 有缩放闪烁", first.x, maxDev))
    end
end

-- ---------- 场景搭建 ----------

function CreateScene()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    -- 物理（PlayerAnim 不需要，但保持兼容）
    local pw = scene_:CreateComponent("PhysicsWorld")
    pw.gravity = Vector3(0, -9.81, 0)

    -- 灯光
    local lightNode = scene_:CreateChild("DirectionalLight")
    lightNode.direction = Vector3(0.6, -1.0, 0.8)
    local light = lightNode:CreateComponent("Light")
    light.lightType = LIGHT_DIRECTIONAL
    light.brightness = 1.0

    -- 相机
    local camNode = scene_:CreateChild("Camera")
    camNode.position = Vector3(0, 1.5, -4)
    camNode:LookAt(Vector3(0, 1.0, 0))
    local camera = camNode:CreateComponent("Camera")
    camera.fov = 45.0

    renderer:SetViewport(0, Viewport:new(scene_, camera))

    -- 玩家节点
    playerNode_ = scene_:CreateChild("Player")
    playerNode_.position = Vector3(0, 0, 0)

    -- 创建角色动画
    PlayerAnim.CreateSkeleton(playerNode_, "warrior", Color(0.8, 0.2, 0.2))

    print("[TestAnim] Scene created, starting tests...")
end

-- ---------- 主循环 ----------

function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()
    phaseTimer = phaseTimer + dt
    frameCount = frameCount + 1

    PlayerAnim.Update(dt)

    -- 状态机驱动测试流程
    if testPhase == "init" then
        -- 等待 0.5 秒让 prefab 加载完成
        if phaseTimer > 0.5 then
            testPhase = "idle_check"
            phaseTimer = 0
            print("[TestAnim] Phase: idle_check")
        end

    elseif testPhase == "idle_check" then
        -- 在 idle 状态下采样几帧
        sampleBones()
        if phaseTimer > 0.5 then
            -- 检查 idle 状态可见性
            checkVisibility("idle")
            -- 触发攻击动画
            testPhase = "attack_start"
            phaseTimer = 0
            bip001Scales = {}
            upperArmRotations = {}
            modelScales = {}
            print("[TestAnim] Phase: attack_start — triggering melee_fast")
            PlayerAnim.PlaySkill("melee")
        end

    elseif testPhase == "attack_start" then
        -- 攻击动画播放中，采样骨骼数据
        sampleBones()
        if phaseTimer > 1.0 then
            -- 1 秒后先检查攻击中的可见性
            checkVisibility("attack")
            testPhase = "attack_check"
            phaseTimer = 0
            print("[TestAnim] Phase: attack_check — analyzing samples")
        end

    elseif testPhase == "attack_check" then
        checkBip001Scale()
        checkArmMotion()
        checkModelScaleStability()
        printSummary()
        testPhase = "done"

    elseif testPhase == "done" then
        -- 测试完成，保持场景运行方便视觉验证
    end
end

function HandlePostUpdate(eventType, eventData)
    PlayerAnim.PostUpdate()
end

-- ---------- 入口 ----------

function Start()
    CreateScene()
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")
end
