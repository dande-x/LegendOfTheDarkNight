-- ============================================================================
-- main.lua — 传奇·山海 主入口
-- 俯视角 ARPG: 场景搭建 + 相机跟随 + 角色移动 + 施法系统 + 系统集成
-- ============================================================================

local UI = require("urhox-libs/UI")
local CharacterClass = require("scripts.CharacterClass")
local GameUI = require("scripts.GameUI")
local Combat = require("scripts.Combat")
local Inventory = require("scripts.Inventory")
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
local player_ = nil

local C = CharacterClass.Colors

-- 俯视角相机参数
local CAM_OFFSET = Vector3(0, 18, -10)
local CAM_PITCH = 60
local CAM_FOV = 50

-- 药瓶系统
local hpPotionCD = 0
local mpPotionCD = 0
local HP_POTION_CD = 8
local MP_POTION_CD = 8

-- 玩家死亡
local deathTimer = 0
local isDead = false

-- ============================================================================
-- 施法状态机
-- ============================================================================
local castState = {
    active = false,
    phase = "none",      -- "none" | "windup" | "recovery"
    skill = nil,
    slot = 0,
    elapsed = 0,
    windupDuration = 0,   -- 前摇时间
    recoveryDuration = 0, -- 后摇时间
}

-- 默认施法时间表（按技能类型），技能自身的 castTime 优先
local DEFAULT_CAST_TIMES = {
    [CharacterClass.SKILL_TYPE.MELEE]  = { windup = 0.20, recovery = 0.12 },
    [CharacterClass.SKILL_TYPE.RANGED] = { windup = 0.15, recovery = 0.10 },
    [CharacterClass.SKILL_TYPE.AOE]    = { windup = 0.35, recovery = 0.15 },
    [CharacterClass.SKILL_TYPE.DOT]    = { windup = 0.30, recovery = 0.12 },
    [CharacterClass.SKILL_TYPE.BUFF]   = { windup = 0.25, recovery = 0.10 },
    [CharacterClass.SKILL_TYPE.HEAL]   = { windup = 0.30, recovery = 0.10 },
    [CharacterClass.SKILL_TYPE.DASH]   = { windup = 0.08, recovery = 0.10 },
    [CharacterClass.SKILL_TYPE.SUMMON] = { windup = 0.40, recovery = 0.15 },
}

-- 法师蓄力视觉节点
local chargeGlowNode = nil

-- ============================================================================
-- 引擎入口
-- ============================================================================
function Start()
    graphics.windowTitle = "贪玩渣渣灰"

    GameUI.InitUI()
    GameUI.InitNanoVG()
    CreateScene()
    SetupCamera()

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

    local lightGroupFile = cache:GetResource("XMLFile", "LightGroup/Dusk.xml")
    local lightGroup = scene_:CreateChild("LightGroup")
    lightGroup:LoadXML(lightGroupFile:GetRoot())

    CreateFloor()
    CreateSceneDecorations()
    print("[main] Scene created")
end

function CreateFloor()
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

    cameraNode_.rotation = Quaternion(CAM_PITCH, Vector3.RIGHT)

    local viewport = Viewport:new(scene_, camera)
    renderer:SetViewport(0, viewport)
    renderer.hdrRendering = true

    -- 把相机引用传给 GameUI 用于世界→屏幕坐标转换
    GameUI.SetCamera(camera)
end

function UpdateCamera(dt)
    if not playerNode_ then return end
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

    player_ = CharacterClass.CreatePlayer(classId, 7)
    CreatePlayerNode(classId)
    GameUI.ShowGameHUD(player_)

    -- 绑定技能按钮回调（现在走施法状态机）
    GameUI.onSkillPressed = function(slot, skill)
        if isDead then return end
        if castState.active then return end  -- 施法中不可再按
        if GameUI.IsBagOpen() then return end -- 背包打开时不放技能

        if not skill then return end
        local canCast, reason = CharacterClass.CanCastSkill(player_, skill)
        if not canCast then
            print("[main] Skill blocked: " .. reason)
            return
        end

        -- 计算前摇/后摇时间
        local defaults = DEFAULT_CAST_TIMES[skill.type] or { windup = 0.2, recovery = 0.1 }
        local windup = skill.castTime or defaults.windup
        local recovery = defaults.recovery

        -- 法师职业额外增加蓄力时间
        if player_.classId == "mage" and windup < 0.3 and skill.manaCost > 0 then
            windup = 0.3
        end

        -- 自动瞄准：施法开始时转向最近敌人
        local target = Combat.FindNearestEnemy(playerNode_.position, skill.range or 5)
        if target then
            local dir = target.node.position - playerNode_.position
            dir.y = 0
            if dir:Length() > 0.1 then
                dir = dir:Normalized()
                local angle = math.atan2(dir.x, dir.z)
                playerNode_.rotation = Quaternion(math.deg(angle), Vector3.UP)
            end
        end

        -- 进入前摇
        castState.active = true
        castState.phase = "windup"
        castState.skill = skill
        castState.slot = slot
        castState.elapsed = 0
        castState.windupDuration = windup
        castState.recoveryDuration = recovery

        -- 显示施法条
        local isCharging = (player_.classId == "mage" and windup >= 0.3)
        GameUI.ShowCastBar(skill.name, isCharging)

        -- 法师蓄力视觉效果
        if isCharging and playerNode_ then
            ShowChargeGlow(true)
        end

        print("[main] Cast start: " .. skill.name .. " windup=" .. string.format("%.2f", windup))
    end

    -- 药瓶回调
    GameUI.onUseHpPotion = function()
        if isDead or hpPotionCD > 0 then return end
        if castState.active then return end
        local heal = player_.maxHP * 0.3
        player_.hp = math.min(player_.maxHP, player_.hp + heal)
        hpPotionCD = HP_POTION_CD
        GameUI.AddFloatingText("+" .. math.floor(heal), playerNode_.position, {100, 255, 100, 255})
        print("[main] Used HP potion, healed " .. math.floor(heal))
    end

    GameUI.onUseMpPotion = function()
        if isDead or mpPotionCD > 0 then return end
        if castState.active then return end
        local restore = player_.maxMP * 0.4
        player_.mp = math.min(player_.maxMP, player_.mp + restore)
        mpPotionCD = MP_POTION_CD
        GameUI.AddFloatingText("+" .. math.floor(restore), playerNode_.position, {100, 180, 255, 255})
        print("[main] Used MP potion, restored " .. math.floor(restore))
    end

    -- 返回主菜单回调
    GameUI.onMenuPressed = function()
        ReturnToMainMenu()
    end

    -- 背包切换回调
    GameUI.onBagToggle = function()
        if GameUI.IsBagOpen() then
            GameUI.HideBagPanel()
        else
            GameUI.ShowBagPanel(player_)
        end
    end

    -- 战斗回调
    Combat.onDamageDealt = function(dmg, isCrit, worldPos)
        local color = isCrit and {255, 220, 50, 255} or {255, 255, 255, 255}
        local text = isCrit and (math.floor(dmg) .. "!") or tostring(math.floor(dmg))
        GameUI.AddFloatingText(text, worldPos, color, isCrit)
    end

    Combat.onEnemyAttack = function(enemy, dmg, playerPos)
        GameUI.AddFloatingText("-" .. math.floor(dmg), playerPos, {255, 80, 60, 255})
    end

    Combat.onPlayerHeal = function(amount, pos)
        GameUI.AddFloatingText("+" .. math.floor(amount), pos, {100, 255, 130, 255})
    end

    -- 掉落系统
    Inventory.Init()
    Combat.onEnemyDeath = function(enemyName, deathPos, exp)
        local droppedItem, gold = Inventory.ProcessDrop(enemyName, player_.classId)
        if gold > 0 then
            GameUI.AddFloatingText("+" .. gold .. "金", deathPos + Vector3(0, 0.5, 0), {255, 215, 0, 255})
        end
        if droppedItem then
            local rarity = Inventory.RARITY[droppedItem.rarity]
            local color = rarity and rarity.color or {255, 255, 255, 255}
            GameUI.AddFloatingText(droppedItem.name, deathPos + Vector3(0, 1.0, 0), color)
        end
    end

    -- 初始刷怪
    for i = 1, 8 do
        Combat.SpawnEnemy(scene_, playerNode_.position, player_.level)
    end

    -- 开门动画
    GameUI.StartDoorOpen()
    print("[main] Game started with " .. CharacterClass.Classes[classId].name)
end

-- ============================================================================
-- 返回主菜单
-- ============================================================================
function ReturnToMainMenu()
    print("[main] Returning to main menu...")

    -- 清理施法状态
    castState.active = false
    castState.phase = "none"
    GameUI.HideCastBar()
    ShowChargeGlow(false)

    -- 关闭背包
    if GameUI.IsBagOpen() then
        GameUI.HideBagPanel()
    end

    -- 清理战斗实体
    Combat.Clear()

    -- 移除玩家节点
    if playerNode_ then
        playerNode_:Remove()
        playerNode_ = nil
    end

    -- 重置状态
    player_ = nil
    isDead = false
    deathTimer = 0
    hpPotionCD = 0
    mpPotionCD = 0

    -- 显示角色选择界面
    GameUI.ShowClassSelect(function(classId)
        OnClassSelected(classId)
    end)
end

-- ============================================================================
-- 法师蓄力发光效果
-- ============================================================================
function ShowChargeGlow(show)
    if show then
        if not chargeGlowNode and playerNode_ then
            chargeGlowNode = playerNode_:CreateChild("ChargeGlow")
            chargeGlowNode.position = Vector3(0, 0.8, 0)
            chargeGlowNode.scale = Vector3(0.8, 0.8, 0.8)
            local model = chargeGlowNode:CreateComponent("StaticModel")
            model:SetModel(cache:GetResource("Model", "Models/Sphere.mdl"))
            local mat = Material:new()
            mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
            mat:SetShaderParameter("MatDiffColor", Variant(Color(0.2, 0.4, 0.8, 0.3)))
            mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.3, 0.5, 1.0)))
            mat:SetShaderParameter("Metallic", Variant(0.0))
            mat:SetShaderParameter("Roughness", Variant(0.2))
            model:SetMaterial(mat)
            model.castShadows = false
        end
    else
        if chargeGlowNode then
            chargeGlowNode:Remove()
            chargeGlowNode = nil
        end
    end
end

-- ============================================================================
-- 施法状态机更新
-- ============================================================================
function UpdateCastState(dt)
    if not castState.active then return end

    castState.elapsed = castState.elapsed + dt

    if castState.phase == "windup" then
        local progress = castState.elapsed / castState.windupDuration
        GameUI.UpdateCastBar(math.min(1, progress))

        -- 法师蓄力脉冲效果
        if chargeGlowNode then
            local pulse = 0.7 + 0.3 * math.sin(castState.elapsed * 12)
            chargeGlowNode.scale = Vector3(pulse, pulse, pulse)
        end

        if castState.elapsed >= castState.windupDuration then
            -- 前摇结束 → 释放技能
            GameUI.HideCastBar()
            ShowChargeGlow(false)

            local ok, result = Combat.CastSkill(scene_, player_, playerNode_, castState.slot)
            if not ok then
                print("[main] Cast failed after windup: " .. result)
            end

            -- 进入后摇
            castState.phase = "recovery"
            castState.elapsed = 0
        end

    elseif castState.phase == "recovery" then
        if castState.elapsed >= castState.recoveryDuration then
            -- 后摇结束
            castState.active = false
            castState.phase = "none"
        end
    end
end

-- ============================================================================
-- 玩家角色节点
-- ============================================================================
function CreatePlayerNode(classId)
    local classDef = CharacterClass.Classes[classId]
    local color = C[classDef.color]

    playerNode_ = scene_:CreateChild("Player")
    playerNode_.position = Vector3(0, 0, 0)

    -- 身体
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

    -- 头部
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

    if classId == "warrior" then
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

    if not player_ then return end

    -- 死亡状态
    if isDead then
        deathTimer = deathTimer - dt
        if deathTimer <= 0 then
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
        -- 打断施法
        castState.active = false
        castState.phase = "none"
        GameUI.HideCastBar()
        ShowChargeGlow(false)
        GameUI.AddFloatingText("阵亡!", playerNode_.position, {255, 50, 50, 255})
        print("[main] Player died, reviving in 3s")
    end

    -- 施法状态机更新
    UpdateCastState(dt)

    -- 玩家移动（施法前摇期间不能移动）
    if not castState.active or castState.phase == "recovery" then
        UpdatePlayerMovement(dt)
    end

    -- 更新冷却 & 药瓶CD
    CharacterClass.UpdateCooldowns(player_, dt)
    if hpPotionCD > 0 then hpPotionCD = math.max(0, hpPotionCD - dt) end
    if mpPotionCD > 0 then mpPotionCD = math.max(0, mpPotionCD - dt) end

    -- 装备加成应用
    local inv = Inventory.playerData
    local classDef = CharacterClass.Classes[player_.classId]
    local g = classDef.growth
    player_.atk = classDef.baseATK + g.atk * (player_.level - 1) + inv.bonusAtk
    player_.def = classDef.baseDEF + g.def * (player_.level - 1) + inv.bonusDef
    player_.maxHP = classDef.baseHP + g.hp * (player_.level - 1) + inv.bonusHP
    if player_.hp > player_.maxHP then player_.hp = player_.maxHP end

    -- 战斗系统更新
    Combat.Update(scene_, dt, playerNode_, player_)

    -- 相机跟随
    UpdateCamera(dt)

    -- UI 更新
    GameUI.UpdateHUD(player_, dt)
    GameUI.UpdateKillCount(Combat.killCount)
    GameUI.UpdateGold(inv.gold)
end

-- ============================================================================
-- 玩家移动 (摇杆)
-- ============================================================================
function UpdatePlayerMovement(dt)
    if not playerNode_ or isDead then return end

    local joystick = GameUI.GetJoystick()
    if not joystick then return end

    local x, z = joystick:getMovement()

    if math.abs(x) < 0.01 and math.abs(z) < 0.01 then
        return
    end

    local moveDir = Vector3(x, 0, z)
    moveDir = moveDir:Normalized()

    local speed = player_.moveSpeed
    playerNode_.position = playerNode_.position + moveDir * speed * dt

    local angle = math.atan2(moveDir.x, moveDir.z)
    playerNode_.rotation = Quaternion(math.deg(angle), Vector3.UP)
end
