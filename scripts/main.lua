-- ============================================================================
-- main.lua — 传奇·山海 主入口
-- 俯视角 ARPG: 场景搭建 + 相机跟随 + 角色移动 + 系统集成
-- ============================================================================

local UI = require("urhox-libs/UI")
local CharacterClass = require("scripts.CharacterClass")
local GameUI = require("scripts.GameUI")
local Combat = require("scripts.Combat")
require "urhox-libs.UI.GameHUD"

-- ============================================================================
-- 全局状态
-- ============================================================================
---@type Scene
local scene_ = nil
---@type Node
local cameraNode_ = nil
---@type Node
local playerNode_ = nil
local player_ = nil   -- CharacterClass.CreatePlayer 返回的实例

local C = CharacterClass.Colors

-- 俯视角相机参数
local CAM_OFFSET = Vector3(0, 18, -10)   -- 相机相对玩家偏移
local CAM_PITCH = 60                       -- 俯视角度
local CAM_FOV = 50

-- 药瓶系统
local hpPotionCD = 0
local mpPotionCD = 0
local HP_POTION_CD = 8   -- 药瓶冷却秒
local MP_POTION_CD = 8

-- 玩家死亡
local deathTimer = 0
local isDead = false

-- ============================================================================
-- 引擎入口
-- ============================================================================
function Start()
    graphics.windowTitle = "贪玩渣渣灰"

    GameUI.InitUI()
    GameUI.InitNanoVG()
    CreateScene()
    SetupCamera()

    -- 先显示角色选择界面
    GameUI.ShowClassSelect(function(classId)
        OnClassSelected(classId)
    end)

    SubscribeToEvent("Update", "HandleUpdate")
    print("=== 贪玩渣渣灰 Started ===")
end

function Stop()
    UI.Shutdown()
end

-- ============================================================================
-- 场景
-- ============================================================================
function CreateScene()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    -- 光照
    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Dusk.xml")
    local lightGroup = scene_:CreateChild("LightGroup")
    lightGroup:LoadXML(lightGroupFile:GetRoot())

    -- 地面 (大平面)
    CreateFloor()

    -- 场景装饰
    CreateSceneDecorations()

    print("[main] Scene created")
end

function CreateFloor()
    -- 主地面
    local floorNode = scene_:CreateChild("Floor")
    floorNode.position = Vector3(0, -0.25, 0)
    floorNode.scale = Vector3(120, 0.5, 120)
    local floorModel = floorNode:CreateComponent("StaticModel")
    floorModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))

    local floorMat = Material:new()
    floorMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    floorMat:SetShaderParameter("MatDiffColor", Variant(C.Floor))
    floorMat:SetShaderParameter("MatSpecColor", Variant(Color(0.2, 0.2, 0.2, 1.0)))
    floorMat:SetShaderParameter("Metallic", Variant(0.0))
    floorMat:SetShaderParameter("Roughness", Variant(0.85))
    floorModel:SetMaterial(floorMat)
    floorModel.castShadows = false
end

function CreateSceneDecorations()
    -- 散落的石头
    local stoneColor = Color(0.25, 0.23, 0.22, 1.0)
    local stonePositions = {
        Vector3(8, 0, 12), Vector3(-15, 0, 8), Vector3(20, 0, -5),
        Vector3(-10, 0, -18), Vector3(5, 0, -25), Vector3(-22, 0, 15),
        Vector3(30, 0, 10), Vector3(-5, 0, 30), Vector3(18, 0, 22),
    }

    for i, pos in ipairs(stonePositions) do
        local s = 0.5 + math.random() * 1.5
        local stoneNode = scene_:CreateChild("Stone_" .. i)
        stoneNode.position = pos
        stoneNode.scale = Vector3(s, s * 0.5, s)
        stoneNode.rotation = Quaternion(math.random() * 360, Vector3.UP)
        local model = stoneNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))

        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(stoneColor))
        mat:SetShaderParameter("MatSpecColor", Variant(Color(0.2, 0.2, 0.2, 1.0)))
        mat:SetShaderParameter("Metallic", Variant(0.0))
        mat:SetShaderParameter("Roughness", Variant(0.9))
        model:SetMaterial(mat)
        model.castShadows = true
    end

    -- 柱子 (类似传奇的场景元素)
    local pillarPositions = {
        Vector3(15, 0, 15), Vector3(-15, 0, 15),
        Vector3(15, 0, -15), Vector3(-15, 0, -15),
    }
    for i, pos in ipairs(pillarPositions) do
        local pillarNode = scene_:CreateChild("Pillar_" .. i)
        pillarNode.position = pos
        pillarNode.scale = Vector3(0.6, 3.0, 0.6)
        pillarNode.position = Vector3(pos.x, 1.5, pos.z)
        local model = pillarNode:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))

        local mat = Material:new()
        mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        mat:SetShaderParameter("MatDiffColor", Variant(Color(0.35, 0.28, 0.22, 1.0)))
        mat:SetShaderParameter("MatSpecColor", Variant(Color(0.3, 0.3, 0.3, 1.0)))
        mat:SetShaderParameter("Metallic", Variant(0.1))
        mat:SetShaderParameter("Roughness", Variant(0.7))
        model:SetMaterial(mat)
        model.castShadows = true
    end
end

-- ============================================================================
-- 相机
-- ============================================================================
function SetupCamera()
    cameraNode_ = scene_:CreateChild("Camera")
    cameraNode_.position = CAM_OFFSET

    local camera = cameraNode_:CreateComponent("Camera")
    camera.nearClip = 0.5
    camera.farClip = 200.0
    camera.fov = CAM_FOV

    -- 俯视角旋转
    cameraNode_.rotation = Quaternion(CAM_PITCH, Vector3.RIGHT)

    local viewport = Viewport:new(scene_, camera)
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true
end

function UpdateCamera(dt)
    if not playerNode_ then return end
    -- 平滑跟随玩家
    local targetPos = playerNode_.position + CAM_OFFSET
    local currentPos = cameraNode_.position
    local lerpSpeed = 5.0
    cameraNode_.position = currentPos + (targetPos - currentPos) * math.min(1.0, lerpSpeed * dt)
end

-- ============================================================================
-- 角色选择回调
-- ============================================================================
function OnClassSelected(classId)
    print("[main] Selected class: " .. classId)

    -- 创建角色数据
    player_ = CharacterClass.CreatePlayer(classId, 7)

    -- 创建角色节点
    CreatePlayerNode(classId)

    -- 初始化 HUD
    GameUI.ShowGameHUD(player_)

    -- 绑定技能按钮回调
    GameUI.onSkillPressed = function(slot, skill)
        if isDead then return end
        local ok, result = Combat.CastSkill(scene_, player_, playerNode_, slot)
        if not ok then
            print("[main] Skill failed: " .. result)
        end
    end

    -- 绑定药瓶回调
    GameUI.onUseHpPotion = function()
        if isDead or hpPotionCD > 0 then return end
        local heal = player_.maxHP * 0.3
        player_.hp = math.min(player_.maxHP, player_.hp + heal)
        hpPotionCD = HP_POTION_CD
        GameUI.AddFloatingText("+" .. math.floor(heal), playerNode_.position, {100, 255, 100, 255})
        print("[main] Used HP potion, healed " .. math.floor(heal))
    end

    GameUI.onUseMpPotion = function()
        if isDead or mpPotionCD > 0 then return end
        local restore = player_.maxMP * 0.4
        player_.mp = math.min(player_.maxMP, player_.mp + restore)
        mpPotionCD = MP_POTION_CD
        GameUI.AddFloatingText("+" .. math.floor(restore), playerNode_.position, {100, 180, 255, 255})
        print("[main] Used MP potion, restored " .. math.floor(restore))
    end

    -- 战斗回调
    Combat.onDamageDealt = function(dmg, isCrit, worldPos)
        local color = isCrit and {255, 220, 50, 255} or {255, 255, 255, 255}
        local text = isCrit and (math.floor(dmg) .. "!") or tostring(math.floor(dmg))
        GameUI.AddFloatingText(text, worldPos, color)
    end

    Combat.onEnemyAttack = function(enemy, dmg, playerPos)
        GameUI.AddFloatingText("-" .. math.floor(dmg), playerPos, {255, 80, 60, 255})
    end

    Combat.onPlayerHeal = function(amount, pos)
        GameUI.AddFloatingText("+" .. math.floor(amount), pos, {100, 255, 130, 255})
    end

    -- 初始刷几只怪
    for i = 1, 4 do
        Combat.SpawnEnemy(scene_, playerNode_.position, player_.level)
    end

    -- 启动开门过渡动画
    GameUI.StartDoorOpen()

    print("[main] Game started with " .. CharacterClass.Classes[classId].name)
end

-- ============================================================================
-- 玩家角色节点 (几何体 + 颜色区分职业)
-- ============================================================================
function CreatePlayerNode(classId)
    local classDef = CharacterClass.Classes[classId]
    local color = C[classDef.color]

    playerNode_ = scene_:CreateChild("Player")
    playerNode_.position = Vector3(0, 0, 0)

    -- 身体 (圆柱)
    local bodyNode = playerNode_:CreateChild("Body")
    bodyNode.position = Vector3(0, 0.5, 0)
    bodyNode.scale = Vector3(0.5, 1.0, 0.5)
    local bodyModel = bodyNode:CreateComponent("StaticModel")
    bodyModel:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))

    local bodyMat = Material:new()
    bodyMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    bodyMat:SetShaderParameter("MatDiffColor", Variant(color))
    bodyMat:SetShaderParameter("MatSpecColor", Variant(Color(0.4, 0.4, 0.4, 1.0)))
    bodyMat:SetShaderParameter("Metallic", Variant(0.15))
    bodyMat:SetShaderParameter("Roughness", Variant(0.5))
    bodyModel:SetMaterial(bodyMat)
    bodyModel.castShadows = true

    -- 头部 (球体)
    local headNode = playerNode_:CreateChild("Head")
    headNode.position = Vector3(0, 1.2, 0)
    headNode.scale = Vector3(0.3, 0.3, 0.3)
    local headModel = headNode:CreateComponent("StaticModel")
    headModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))

    local headMat = Material:new()
    headMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    headMat:SetShaderParameter("MatDiffColor", Variant(C.Cream))
    headMat:SetShaderParameter("MatSpecColor", Variant(Color(0.3, 0.3, 0.3, 1.0)))
    headMat:SetShaderParameter("Metallic", Variant(0.0))
    headMat:SetShaderParameter("Roughness", Variant(0.6))
    headModel:SetMaterial(headMat)
    headModel.castShadows = true

    -- 职业标识 (肩膀上的锥体 - 武士朱红，法师放顶部帽子，道士背后)
    if classId == "warrior" then
        -- 武器(右手侧剑)
        local swordNode = playerNode_:CreateChild("Sword")
        swordNode.position = Vector3(0.5, 0.6, 0.2)
        swordNode.scale = Vector3(0.08, 0.6, 0.08)
        swordNode.rotation = Quaternion(30, Vector3.FORWARD)
        local swordModel = swordNode:CreateComponent("StaticModel")
        swordModel:SetModel(cache:GetResource("Model", "Models/Box.mdl"))
        local swordMat = Material:new()
        swordMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        swordMat:SetShaderParameter("MatDiffColor", Variant(Color(0.7, 0.7, 0.75, 1.0)))
        swordMat:SetShaderParameter("Metallic", Variant(0.9))
        swordMat:SetShaderParameter("Roughness", Variant(0.2))
        swordModel:SetMaterial(swordMat)
        swordModel.castShadows = true

    elseif classId == "mage" then
        -- 法杖(头顶发光球)
        local staffNode = playerNode_:CreateChild("Staff")
        staffNode.position = Vector3(0, 1.6, 0)
        staffNode.scale = Vector3(0.15, 0.15, 0.15)
        local staffModel = staffNode:CreateComponent("StaticModel")
        staffModel:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
        local staffMat = Material:new()
        staffMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        staffMat:SetShaderParameter("MatDiffColor", Variant(C.Azure))
        staffMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.3, 0.5, 0.8)))
        staffMat:SetShaderParameter("Metallic", Variant(0.0))
        staffMat:SetShaderParameter("Roughness", Variant(0.3))
        staffModel:SetMaterial(staffMat)

    elseif classId == "taoist" then
        -- 八卦(背后的圆环暗示)
        local bagua = playerNode_:CreateChild("Bagua")
        bagua.position = Vector3(0, 0.8, -0.3)
        bagua.scale = Vector3(0.5, 0.5, 0.05)
        bagua.rotation = Quaternion(90, Vector3.RIGHT)
        local baguaModel = bagua:CreateComponent("StaticModel")
        baguaModel:SetModel(cache:GetResource("Model", "Models/Torus.mdl"))
        local baguaMat = Material:new()
        baguaMat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
        baguaMat:SetShaderParameter("MatDiffColor", Variant(C.Gold))
        baguaMat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.5, 0.4, 0.2)))
        baguaMat:SetShaderParameter("Metallic", Variant(0.3))
        baguaMat:SetShaderParameter("Roughness", Variant(0.4))
        baguaModel:SetMaterial(baguaMat)
    end
end

-- ============================================================================
-- 主循环
-- ============================================================================
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 角色选择阶段不更新游戏
    if not player_ then return end

    -- 死亡状态
    if isDead then
        deathTimer = deathTimer - dt
        if deathTimer <= 0 then
            -- 复活
            isDead = false
            player_.hp = player_.maxHP
            player_.mp = player_.maxMP
            playerNode_.position = Vector3(0, 0, 0)
            print("[main] Player revived")
        end
        UpdateCamera(dt)
        GameUI.UpdateHUD(player_, dt)
        return
    end

    -- 检查死亡
    if player_.hp <= 0 then
        isDead = true
        deathTimer = 3.0
        GameUI.AddFloatingText("阵亡!", playerNode_.position, {255, 50, 50, 255})
        print("[main] Player died, reviving in 3s")
    end

    -- 玩家移动
    UpdatePlayerMovement(dt)

    -- 更新冷却 & 药瓶CD
    CharacterClass.UpdateCooldowns(player_, dt)
    if hpPotionCD > 0 then hpPotionCD = math.max(0, hpPotionCD - dt) end
    if mpPotionCD > 0 then mpPotionCD = math.max(0, mpPotionCD - dt) end

    -- 战斗系统更新
    Combat.Update(scene_, dt, playerNode_, player_)

    -- 相机跟随
    UpdateCamera(dt)

    -- UI 更新
    GameUI.UpdateHUD(player_, dt)
    GameUI.UpdateKillCount(Combat.killCount)
end

-- ============================================================================
-- 玩家移动 (摇杆)
-- ============================================================================
function UpdatePlayerMovement(dt)
    if not playerNode_ or isDead then return end

    local joystick = GameUI.GetJoystick()
    if not joystick then return end

    local x, z = joystick:getMovement()

    -- 检测是否有移动输入
    if math.abs(x) < 0.01 and math.abs(z) < 0.01 then
        return
    end

    -- 计算移动方向
    local moveDir = Vector3(x, 0, z)
    moveDir = moveDir:Normalized()

    -- 移动
    local speed = player_.moveSpeed
    playerNode_.position = playerNode_.position + moveDir * speed * dt

    -- 转向移动方向
    local angle = math.atan2(moveDir.x, moveDir.z)
    playerNode_.rotation = Quaternion(math.deg(angle), Vector3.UP)
end
