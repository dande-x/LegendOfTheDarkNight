---@diagnostic disable: undefined-field, undefined-global
-- ============================================================================
-- ShabakRuntime.lua — 沙巴克攻城战场景适配层
--
-- 将 ShabakSiege 的纯规则会话落到 UrhoX 场景：三职业守军、两名支援
-- 队友、据点读条、前线补给与王座坚守。它不复用 PlayerAnim 的全局单例，
-- 每个角色都各自实例化 prefab 与 AnimationController，避免覆盖玩家动画。
-- ============================================================================

local PlayerAnim = require("scripts.PlayerAnim")
local MapZone = require("MapZone")

local ShabakRuntime = {}
local Runtime = {}
Runtime.__index = Runtime

local TARGET_HEIGHT = 1.60
-- 与玩家/普通敌人的胶囊体保持同一尺度，避免实际角色模型与战斗
-- 距离判定不一致。根节点负责物理，预制体只负责视觉和动画。
local ACTOR_COLLISION_DIAMETER = 0.50
local ACTOR_COLLISION_HEIGHT = 1.40
local CAPTURE_RADIUS = 3.8
local CONTEST_RADIUS = 8.0
local SUPPLY_RADIUS = 3.4
local DEFENDER_LEASH = 22.0

local ANIMS = {
    idle = "uuid://GikiEX04hbY9D5ALGNz051Zh",
    move = "uuid://F-afGUmbZwlJu4crZmqR_4kR",
    warrior = "uuid://Ai-SCaONHGJAnRCLZmoO2QJ8",
    mage = "uuid://E3rZmUDaM9pq2-V2gj3pCyW4",
    taoist = "uuid://Hs3_meWUZg22cD1e_0d-BCO6",
    die = "uuid://EUvBwU0-VB_KCvzQldvwX1gF",
}

local CLASS_COLORS = {
    warrior = Color(0.75, 0.20, 0.15, 1.0),
    mage = Color(0.27, 0.55, 0.67, 1.0),
    taoist = Color(0.20, 0.60, 0.35, 1.0),
}

local OBJECTIVE_POSITIONS = {
    south_gate = Vector3(0, 0, -38),
    east_flag = Vector3(25, 0, -17),
    west_flag = Vector3(-25, 0, -17),
    inner_flag = Vector3(0, 0, 4),
    palace_seal = Vector3(0, 0, 28),
    throne = Vector3(0, 0, 38),
}

local RALLY_POSITIONS = {
    entry = Vector3(0, 0, -50),
    south_gate = Vector3(0, 0, -31),
    east_flag = Vector3(22, 0, -22),
    west_flag = Vector3(-22, 0, -22),
    inner_flag = Vector3(0, 0, -2),
    palace_gate = Vector3(0, 0, 20),
    throne = Vector3(0, 0, 34),
}

local SUPPLY_POSITIONS = {
    south_gate = Vector3(-5.5, 0, -30),
    inner_flag = Vector3(4.6, 0, 10),
    palace_seal = Vector3(-5.2, 0, 24),
}

local DEFENDER_SPAWNS = {
    south_gate = {
        Vector3(-7, 0, -31), Vector3(7, 0, -31), Vector3(-3, 0, -28),
        Vector3(3, 0, -28), Vector3(-11, 0, -34), Vector3(11, 0, -34),
    },
    east_flag = {
        Vector3(20, 0, -12), Vector3(29, 0, -12), Vector3(21, 0, -22),
        Vector3(30, 0, -22),
    },
    west_flag = {
        Vector3(-20, 0, -12), Vector3(-29, 0, -12), Vector3(-21, 0, -22),
        Vector3(-30, 0, -22),
    },
    inner_flag = {
        Vector3(-6, 0, 9), Vector3(6, 0, 9), Vector3(-8, 0, 2), Vector3(8, 0, 2),
    },
    palace_seal = {
        Vector3(-7, 0, 23), Vector3(7, 0, 23), Vector3(-5, 0, 30), Vector3(5, 0, 30),
    },
    throne = {
        Vector3(-7, 0, 31), Vector3(7, 0, 31), Vector3(-8, 0, 39), Vector3(8, 0, 39),
        Vector3(-3, 0, 43), Vector3(3, 0, 43), Vector3(-11, 0, 35), Vector3(11, 0, 35),
    },
}

local function Clamp(value, minValue, maxValue)
    return math.max(minValue, math.min(maxValue, tonumber(value) or minValue))
end

local function HorizontalDistance(a, b)
    if not a or not b then return math.huge end
    local dx = a.x - b.x
    local dz = a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end

local function HorizontalDirection(fromPos, toPos)
    if not fromPos or not toPos then return Vector3.ZERO, 0 end
    local direction = Vector3(toPos.x - fromPos.x, 0, toPos.z - fromPos.z)
    local length = direction:Length()
    if length <= 0.001 then return Vector3.ZERO, 0 end
    return direction / length, length
end

local function ObjectivePosition(id)
    return OBJECTIVE_POSITIONS[id] or Vector3.ZERO
end

local function CreateColorMaterial(color, emissive)
    local material = Material:new()
    material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    material:SetShaderParameter("MatDiffColor", Variant(color))
    material:SetShaderParameter("Roughness", Variant(0.52))
    material:SetShaderParameter("Metallic", Variant(0.12))
    if emissive then material:SetShaderParameter("MatEmissiveColor", Variant(emissive)) end
    return material
end

local function SetModelMaterial(node, material)
    if not node or not material then return end
    local model = node:GetComponent("StaticModel") or node:GetComponent("StaticModel", true)
    if model then model:SetMaterial(material) end
end

local function SafeRemove(node)
    if node then pcall(function() node:Remove() end) end
end

local function SetComponentEnabled(component, enabled)
    if not component then return false end
    local ok = pcall(function() component:SetEnabled(enabled == true) end)
    return ok
end

local function SetLinearVelocity(component, velocity)
    if not component or not velocity then return false end
    local ok = pcall(function() component:SetLinearVelocity(velocity) end)
    return ok
end

local function ClearActorControls(actor)
    local character = actor and actor.character
    local controls = character and character.controls
    if not controls then return end
    -- CharacterComponent owns the actual KCC movement. Clear every directional
    -- bit before setting a new target so a previous frame cannot keep pushing a
    -- downed or idle actor.
    local movementButtons = CTRL_FORWARD | CTRL_BACK | CTRL_LEFT | CTRL_RIGHT
        | CTRL_RUN | CTRL_JUMP
    pcall(function() controls:Set(movementButtons, false) end)
end

function Runtime:_Emit(eventType, payload)
    if self.options and type(self.options.onEvent) == "function" then
        local event = { type = eventType }
        if type(payload) == "table" then
            for key, value in pairs(payload) do event[key] = value end
        end
        pcall(self.options.onEvent, event)
    end
end

function Runtime:_Play(actor, animation, loop)
    if not actor or not actor.animCtrl then return end
    if actor.animation == animation and (loop == nil or actor.animationLoop == loop) then return end
    local path = ANIMS[animation] or ANIMS.idle
    if not path then return end
    actor.animCtrl:PlayExclusive(path, 0, loop == true, 0.12)
    actor.animation = animation
    actor.animationLoop = loop == true
end

function Runtime:_Face(actor, direction)
    if not actor or not actor.node or not direction or direction:Length() <= 0.001 then return end
    actor.node.rotation = Quaternion(math.deg(math.atan2(direction.x, direction.z)), Vector3.UP)
end

function Runtime:_SetActorMoveInput(actor, direction, moving)
    local character = actor and actor.character
    local controls = character and character.controls
    if not controls then return false end

    ClearActorControls(actor)
    if not moving or not direction or direction:Length() <= 0.001 then
        return true
    end

    local flat = Vector3(direction.x, 0, direction.z)
    if flat:Length() <= 0.001 then return true end
    flat = flat:Normalized()
    controls.yaw = math.deg(math.atan2(flat.x, flat.z))
    controls.pitch = 0
    pcall(function() controls:Set(CTRL_FORWARD, true) end)
    return true
end

function Runtime:_WarpActor(actor, position)
    if not actor or not actor.node or not position then return false end
    local warped = false
    if actor.kinematicController then
        local ok = pcall(function()
            actor.kinematicController:Warp(position)
        end)
        warped = ok
    end
    -- Warp is the canonical KCC teleport path. The direct position fallback is
    -- only for a partially constructed actor in a degraded asset/runtime path;
    -- normal actors always have a KCC from _CreateActorPhysics.
    if not warped then
        local ok = pcall(function() actor.node.position = position end)
        warped = ok
    end
    SetLinearVelocity(actor.kinematicController, Vector3.ZERO)
    SetLinearVelocity(actor.rigidBody, Vector3.ZERO)
    return warped
end

function Runtime:_SetActorPhysicalActive(actor, active, position)
    if not actor or not actor.node then return false end
    if active then
        -- Re-enable the node first; component enabled state is independent and
        -- must be restored explicitly after a deep node disable.
        pcall(function() actor.node:SetDeepEnabled(true) end)
        SetComponentEnabled(actor.rigidBody, true)
        SetComponentEnabled(actor.collisionShape, true)
        SetComponentEnabled(actor.kinematicController, true)
        SetComponentEnabled(actor.character, true)
        if actor.rigidBody then
            pcall(function() actor.rigidBody.active = true end)
        end
        if position then self:_WarpActor(actor, position) end
        return true
    end

    ClearActorControls(actor)
    SetLinearVelocity(actor.kinematicController, Vector3.ZERO)
    SetLinearVelocity(actor.rigidBody, Vector3.ZERO)
    -- Disable the physics components as well as the visual subtree. This keeps
    -- downed companions from blocking the player or receiving collision events.
    SetComponentEnabled(actor.character, false)
    SetComponentEnabled(actor.kinematicController, false)
    SetComponentEnabled(actor.collisionShape, false)
    SetComponentEnabled(actor.rigidBody, false)
    if actor.rigidBody then
        pcall(function() actor.rigidBody.active = false end)
    end
    pcall(function() actor.node:SetDeepEnabled(false) end)
    return true
end

function Runtime:_Move(actor, direction, speed, dt)
    if not actor or not actor.node or not actor.character then return end
    if actor.combatEnemy and (actor.combatEnemy.state == "down"
            or actor.combatEnemy.state == "dead"
            or actor.combatEnemy.state == "dying") then
        ClearActorControls(actor)
        return
    end
    if not direction or direction:Length() <= 0.001 or speed <= 0 then
        self:_SetActorMoveInput(actor, nil, false)
        if actor.attackVisualTimer and actor.attackVisualTimer > 0 then return end
        self:_Play(actor, "idle", true)
        return
    end

    local moveSpeed = math.max(0, tonumber(speed) or 0)
    local moveTime = math.max(0, tonumber(dt) or 0)
    local nextPosition = actor.node.position
        + direction:Normalized() * moveSpeed * moveTime
    local clamped = MapZone.ClampToArena(nextPosition, 1.2)
    local moveDirection = direction:Normalized()
    if clamped then
        local boundedDirection, boundedDistance = HorizontalDirection(
            actor.node.position, clamped)
        if boundedDistance <= 0.001 then
            self:_SetActorMoveInput(actor, nil, false)
            if not actor.attackVisualTimer or actor.attackVisualTimer <= 0 then
                self:_Play(actor, "idle", true)
            end
            return
        end
        moveDirection = boundedDirection
    end
    self:_SetActorMoveInput(actor, moveDirection, true)
    self:_Face(actor, moveDirection)
    if not actor.attackVisualTimer or actor.attackVisualTimer <= 0 then
        self:_Play(actor, "move", true)
    end
end

function Runtime:_CreateActorModel(actor)
    local node = actor.node
    if not node or not self.scene then return end
    local prefabPath = PlayerAnim.GetPrefabPath(actor.classId,
        self.player and self.player.modelStyle or "old", "male")
    local prefabFile = cache:GetFile(prefabPath)
    if prefabFile then
        local prefabNode = self.scene:InstantiateXML(prefabFile, Vector3.ZERO,
            Quaternion.IDENTITY, LOCAL)
        prefabFile:Close()
        if prefabNode then
            prefabNode.parent = node
            prefabNode.name = "CharacterModel"
            actor.modelNode = prefabNode
            local animated = prefabNode:GetComponent("AnimatedModel")
                or prefabNode:GetComponent("AnimatedModel", true)
            if animated then
                local bounds = animated.boundingBox
                local height = bounds.size.y
                if height > 0 then
                    local scale = TARGET_HEIGHT / height
                    prefabNode.scale = Vector3(scale, scale, scale)
                    prefabNode.position = Vector3(0, -bounds.min.y * scale, 0)
                end
                actor.animCtrl = prefabNode:GetComponent("AnimationController")
                    or prefabNode:GetComponent("AnimationController", true)
                if not actor.animCtrl then actor.animCtrl = prefabNode:CreateComponent("AnimationController") end
                self:_Play(actor, "idle", true)
                return
            end
        end
    end

    -- 预制体缺失时仍维持可战斗的职业角色实体，避免一张资源图异常导致
    -- 攻城会话卡死。正常 Maker 资源树会走上面的 AnimatedModel 路径。
    local fallback = node:CreateChild("FallbackCharacter")
    fallback.position = Vector3(0, 0.8, 0)
    fallback.scale = Vector3(0.48, 1.6, 0.48)
    local model = fallback:CreateComponent("StaticModel")
    model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
    model:SetMaterial(CreateColorMaterial(CLASS_COLORS[actor.classId]
        or Color(0.72, 0.72, 0.72, 1.0)))
    actor.modelNode = fallback
end

-- 守军与支援队友都是真实角色节点，不能只创建视觉模型；没有统一的
-- 胶囊碰撞体时，角色会穿过城墙、彼此重叠，也无法被玩家/守军正确阻挡。
function Runtime:_CreateActorPhysics(actor)
    if not actor or not actor.node then return false end
    local body = actor.node:CreateComponent("RigidBody")
    -- RigidBody 只负责碰撞事件；KCC/CharacterComponent 负责真实移动。
    -- 这样守军不会出现动态刚体“挂墙”或被速度写入推飞的问题。
    body:SetCollisionLayerAndMask(CollisionLayerCharacter, CollisionMaskCharacter)
    body:SetMass(1.0)
    body:SetLinearFactor(Vector3.ZERO)
    body:SetAngularFactor(Vector3.ZERO)
    body:SetCollisionEventMode(COLLISION_ALWAYS)
    body:SetUseGravity(false)
    local shape = actor.node:CreateComponent("CollisionShape")
    shape:SetCapsule(ACTOR_COLLISION_DIAMETER, ACTOR_COLLISION_HEIGHT,
        Vector3(0, ACTOR_COLLISION_HEIGHT * 0.5, 0))
    -- The shape must exist before KCC is created; otherwise the controller is a
    -- silent no-op in UrhoX.
    local kinematicController = actor.node:CreateComponent("KinematicCharacterController")
    kinematicController:SetCollisionLayerAndMask(CollisionLayerKinematic, CollisionMaskKinematic)
    kinematicController:SetStepHeight(0.25)
    kinematicController:SetMaxSlope(45.0)
    local character = actor.node:CreateComponent("CharacterComponent")
    character:SetAirControlFactor(0.0)
    character:SetWalkSpeed(actor.speed or 3.0)
    character:SetRunSpeed(actor.speed or 3.0)
    character:SetEnableWalkMode(true)
    character.autoRotateToMoveDir = false
    character.rotationSpeed = 720.0
    actor.rigidBody = body
    actor.collisionShape = shape
    actor.kinematicController = kinematicController
    actor.character = character
    ClearActorControls(actor)
    return true
end

function Runtime:_CreateActor(descriptor, position, isAlly)
    if not descriptor or not position then return nil end
    local node = self.root:CreateChild((isAlly and "ShabakAlly_" or "ShabakDefender_")
        .. tostring(descriptor.id))
    node.position = position

    -- descriptor.state belongs exclusively to the siege session (pending /
    -- active / retired / defeated, or active / down for companions). Combat
    -- has a separate lifecycle state on combatState, so a death animation or
    -- phase reset cannot corrupt session counters.
    local actor = descriptor
    actor.node = node
    actor.homePosition = position
    actor.combatState = isAlly and "active" or "guard"
    actor.speed = isAlly and 3.25 or 2.75
    actor.chaseRange = isAlly and 16 or DEFENDER_LEASH
    actor.attackCD = isAlly and (actor.classId == "mage" and 2.8 or 2.25)
        or (actor.classId == "warrior" and 1.85 or 2.35)
    actor.attackTimer = 0.5
    actor.attackDamageScale = isAlly and 0.0 or 0.72
    actor.healUses = 0
    -- 镜像会话中的队友生命周期，供阶段切换时识别 down -> active 的边界。
    actor._sessionCompanionState = isAlly and descriptor.state or nil
    actor._sessionCompanionPhase = self.session and self.session.phase or nil
    actor.externalPersistOnDeath = isAlly == true
    actor.updateAI = function(enemy, dt, playerNode, player, combat)
        self:_UpdateActorAI(actor, enemy, dt, playerNode, player, combat)
    end
    actor.onDeath = function(enemy)
        self:_OnActorDeath(actor, enemy)
    end
    actor.onReset = function(enemy)
        if actor.node and actor.kinematicController then
            self:_SetActorPhysicalActive(actor, true, actor.homePosition)
        elseif actor.node then
            actor.node.position = actor.homePosition
        end
        self:_Play(actor, "idle", true)
    end
    actor.onRemoved = function()
        actor.combatEnemy = nil
    end
    self:_CreateActorModel(actor)
    if not self:_CreateActorPhysics(actor) then
        SafeRemove(node)
        actor.node = nil
        self:_Emit("siege_runtime_error", { reason = "角色碰撞体创建失败" })
        return nil
    end

    local enemy, reason = self.combat.RegisterExternalEnemy(actor, {
        faction = actor.faction,
        classId = actor.classId,
        level = actor.level,
        maxHPMultiplier = actor.maxHPMultiplier,
        damageMultiplier = actor.damageMultiplier,
        attackRange = actor.attackRange,
        attackCD = actor.attackCD,
        attackDamageScale = actor.attackDamageScale,
        state = actor.combatState,
        homePosition = actor.homePosition,
        externalPersistOnDeath = actor.externalPersistOnDeath,
    })
    if not enemy then
        SafeRemove(node)
        actor.node = nil
        self:_Emit("siege_runtime_error", { reason = reason or "角色战斗注册失败" })
        return nil
    end
    actor.combatEnemy = enemy
    return actor
end

function Runtime:_SpawnCompanions()
    for index, descriptor in ipairs(self.session.companions or {}) do
        local side = index == 1 and -1 or 1
        local base = self.playerNode and self.playerNode.position or RALLY_POSITIONS.entry
        local position = base + Vector3(side * 1.5, 0, -1.2)
        local actor = self:_CreateActor(descriptor, position, true)
        if actor then self.companions[descriptor.id] = actor end
    end
end

function Runtime:_SpawnDefender(descriptor)
    if not descriptor or self.defenders[descriptor.id] then return false end
    local live = self.session:GetDefender(descriptor.id)
    if not live then return false end
    local zone = live.spawnZone or live.phase or "south_gate"
    local options = DEFENDER_SPAWNS[zone] or DEFENDER_SPAWNS.south_gate
    local index = (self.spawnSerial % #options) + 1
    self.spawnSerial = self.spawnSerial + 1
    local position = options[index]
    local spawned = self.session:MarkDefenderSpawned(live.id)
    if not spawned then return false end
    local actor = self:_CreateActor(live, position, false)
    if not actor then
        -- 注册失败不能让会话永久占用活跃名额；视为此名守军已撤离。
        self.session:MarkDefenderDefeated(live.id)
        return false
    end
    self.defenders[live.id] = actor
    return true
end

function Runtime:_OnActorDeath(actor)
    if not actor then return end
    self:_Play(actor, "die", false)
    if actor.faction == "ally" then
        -- 队友进入 down 后保留 descriptor 等待集结点复起，但隐藏整棵
        -- 视觉树并停止刚体，避免倒下队友继续挡路或被误读为活人。
        actor.combatState = "down"
        self:_SetActorPhysicalActive(actor, false)
        self.session:MarkCompanionDown(actor.id)
        return
    end
    if not actor.defeatNotified then
        actor.defeatNotified = true
        self.session:MarkDefenderDefeated(actor.id)
    end
end

function Runtime:_FindNearestDefender(position, maxDistance)
    local best, bestDistance = nil, maxDistance or math.huge
    for _, actor in pairs(self.defenders) do
        local enemy = actor.combatEnemy
        if actor.node and enemy and enemy.state ~= "dead" and enemy.state ~= "dying"
            and enemy.state ~= "down" and (enemy.hp or 0) > 0 then
            local distance = HorizontalDistance(position, actor.node.position)
            if distance < bestDistance then
                best, bestDistance = actor, distance
            end
        end
    end
    return best, bestDistance
end

function Runtime:_FindNearestCompanion(position, maxDistance)
    local best, bestDistance = nil, maxDistance or math.huge
    for _, actor in pairs(self.companions) do
        local enemy = actor.combatEnemy
        if actor.node and enemy and enemy.state ~= "down" and enemy.state ~= "dead"
            and enemy.state ~= "dying" and (enemy.hp or 0) > 0 then
            local distance = HorizontalDistance(position, actor.node.position)
            if distance < bestDistance then
                best, bestDistance = actor, distance
            end
        end
    end
    return best, bestDistance
end

function Runtime:_UpdateDefenderAI(actor, enemy, dt, playerNode, player, combat)
    if not actor.node or not playerNode or not player then return end
    if enemy.state == "down" or enemy.state == "dead" or enemy.state == "dying" then return end
    actor.attackVisualTimer = math.max(0, (actor.attackVisualTimer or 0) - dt)
    enemy.attackTimer = math.max(0, (enemy.attackTimer or 0) - dt)

    local targetNode = playerNode
    local targetActor = nil
    -- 少量武士会切向贴身的队友，让支援有拉仇恨价值；其余守军始终优先
    -- 压制玩家，因此队友不会替代玩家完成挑战。
    if actor.classId == "warrior" then
        local ally, allyDistance = self:_FindNearestCompanion(actor.node.position, 3.6)
        if ally and allyDistance <= 3.6 then
            targetNode, targetActor = ally.node, ally
        end
    end

    local direction, distance = HorizontalDirection(actor.node.position, targetNode.position)
    local desiredDistance = actor.classId == "warrior" and 1.6
        or (actor.classId == "mage" and 6.2 or 5.3)
    local attackRange = tonumber(enemy.attackRange) or actor.attackRange or desiredDistance
    local moveDirection = Vector3.ZERO
    if distance > DEFENDER_LEASH and actor.homePosition then
        moveDirection = HorizontalDirection(actor.node.position, actor.homePosition)
    elseif distance > desiredDistance + 0.45 then
        moveDirection = direction
    elseif actor.classId ~= "warrior" and distance < desiredDistance - 0.75 then
        moveDirection = direction * -1
    end
    self:_Move(actor, moveDirection, actor.speed or 2.75, dt)
    self:_Face(actor, direction)

    if distance <= attackRange and enemy.attackTimer <= 0 then
        if targetActor then
            combat.DealDamageToExternal(targetActor, enemy.atk, enemy, {
                canCrit = false, hitStunDuration = 0.12,
            })
        else
            combat.DealDamageToPlayer(enemy, player, playerNode.position)
        end
        enemy.attackTimer = enemy.attackCD or 2.0
        actor.attackVisualTimer = actor.classId == "warrior" and 0.45 or 0.62
        self:_Play(actor, actor.classId, false)
    end

    -- 守城道士只进行很低频的小治疗，保持三职业辨识，同时不会形成无限续航。
    actor.healTimer = math.max(0, (actor.healTimer or 0) - dt)
    if actor.classId == "taoist" and actor.healTimer <= 0 then
        local wounded, ratio = nil, 1.0
        for _, friend in pairs(self.defenders) do
            local friendEnemy = friend.combatEnemy
            if friendEnemy and friendEnemy.state ~= "dead" and friendEnemy.state ~= "dying"
                and friendEnemy.state ~= "down"
                and friendEnemy.maxHP and friendEnemy.maxHP > 0 then
                local health = friendEnemy.hp / friendEnemy.maxHP
                if health < ratio and HorizontalDistance(actor.node.position, friend.node.position) <= 7.0 then
                    wounded, ratio = friend, health
                end
            end
        end
        if wounded and ratio < 0.55 then
            combat.HealExternal(wounded, 0.045, nil, actor)
            actor.healTimer = 12.0
        else
            actor.healTimer = 2.5
        end
    end
end

function Runtime:_UpdateCompanionAI(actor, enemy, dt, playerNode, player, combat)
    if not actor.node or not playerNode or not player then return end
    if enemy.state == "down" or enemy.state == "dead" or enemy.state == "dying" then return end
    actor.attackVisualTimer = math.max(0, (actor.attackVisualTimer or 0) - dt)
    enemy.attackTimer = math.max(0, (enemy.attackTimer or 0) - dt)

    local target, targetDistance = self:_FindNearestDefender(actor.node.position, 12.0)
    if target and target.node then
        local direction, distance = HorizontalDirection(actor.node.position, target.node.position)
        local desired = actor.classId == "warrior" and 1.7
            or (actor.classId == "mage" and 6.0 or 5.0)
        local moveDirection = Vector3.ZERO
        if distance > desired + 0.35 then
            moveDirection = direction
        elseif actor.classId ~= "warrior" and distance < desired - 0.7 then
            moveDirection = direction * -1
        end
        self:_Move(actor, moveDirection, actor.speed or 3.2, dt)
        self:_Face(actor, direction)
        if distance <= (enemy.attackRange or actor.attackRange or desired)
            and enemy.attackTimer <= 0 then
            local baseDamage = (enemy.atk or 1) * Clamp(actor.damageShare, 0.08, 0.20)
            combat.DealDamage(target.combatEnemy or target, baseDamage, actor, {
                canCrit = false, hitStunDuration = 0.10,
            })
            enemy.attackTimer = enemy.attackCD or 2.5
            actor.attackVisualTimer = actor.classId == "warrior" and 0.42 or 0.58
            self:_Play(actor, actor.classId, false)
        end
    else
        local followOffset = actor.id:sub(-1) == "1" and -1.4 or 1.4
        local anchor = playerNode.position + Vector3(followOffset, 0, -1.6)
        local direction, distance = HorizontalDirection(actor.node.position, anchor)
        self:_Move(actor, distance > 1.1 and direction or Vector3.ZERO, actor.speed or 3.2, dt)
    end

    local policy = actor.healPolicy
    actor.healTimer = math.max(0, (actor.healTimer or 0) - dt)
    if policy and actor.healTimer <= 0 and actor.healUses < (policy.maxUses or 0)
        and player.maxHP and player.maxHP > 0
        and player.hp / player.maxHP <= (policy.triggerPlayerHpBelow or 0.45) then
        combat.HealPlayer(player, policy.healRatio or 0.06, nil)
        actor.healUses = actor.healUses + 1
        actor.healTimer = policy.cooldown or 15
        self:_Play(actor, "taoist", false)
    end
end

function Runtime:_UpdateActorAI(actor, enemy, dt, playerNode, player, combat)
    if self.destroyed or not actor then return end
    if actor.faction == "ally" then
        self:_UpdateCompanionAI(actor, enemy, dt, playerNode, player, combat)
    else
        self:_UpdateDefenderAI(actor, enemy, dt, playerNode, player, combat)
    end
end

function Runtime:_IsObjectiveContested(objectiveId)
    local position = ObjectivePosition(objectiveId)
    for _, actor in pairs(self.defenders) do
        local enemy = actor.combatEnemy
        if actor.node and enemy and enemy.state ~= "dead" and enemy.state ~= "dying"
            and enemy.state ~= "down" and (enemy.hp or 0) > 0
            and HorizontalDistance(actor.node.position, position) <= CONTEST_RADIUS then
            return true
        end
    end
    return false
end

function Runtime:_CurrentCaptureObjective()
    local phase = self.session.phase
    if phase == "street_flags" or phase == "flags" then
        local candidates = { "east_flag", "west_flag" }
        local nearest, nearestDistance = nil, math.huge
        for _, objectiveId in ipairs(candidates) do
            local objective = self.session:GetObjective(objectiveId)
            if objective and not objective.captured then
                local distance = self.playerNode and HorizontalDistance(
                    self.playerNode.position, ObjectivePosition(objectiveId)) or math.huge
                if distance < nearestDistance then
                    nearest, nearestDistance = objectiveId, distance
                end
            end
        end
        return nearest
    elseif phase == "inner_flag" then
        return "inner_flag"
    elseif phase == "throne" then
        return "throne"
    end
    return nil
end

function Runtime:_UpdateObjectives(dt)
    if not self.playerNode or not self.session:IsActive() then return end
    local phase = self.session.phase
    if phase == "throne_defense" then
        local present = HorizontalDistance(self.playerNode.position, ObjectivePosition("throne"))
            <= CAPTURE_RADIUS
        self.session:AdvanceThroneHold(dt, present, not self:_IsObjectiveContested("throne"))
        return
    end
    local objectiveId = self:_CurrentCaptureObjective()
    if not objectiveId then return end
    local near = HorizontalDistance(self.playerNode.position, ObjectivePosition(objectiveId))
        <= CAPTURE_RADIUS
    if near then
        self.session:AdvanceObjective(objectiveId, dt, not self:_IsObjectiveContested(objectiveId))
    elseif self.session.capturingObjective == objectiveId then
        self.session:CancelObjective(objectiveId, "out_of_area")
    end
end

function Runtime:_UpdateSupplies()
    if not self.playerNode then return end
    for checkpointId, position in pairs(SUPPLY_POSITIONS) do
        local supply = self.session.supplies and self.session.supplies[checkpointId]
        if supply and not supply.claimed
            and HorizontalDistance(self.playerNode.position, position) <= SUPPLY_RADIUS then
            local claimed = self.session:ClaimSupply(checkpointId)
            if claimed then
                local beacon = self.supplyNodes[checkpointId]
                SafeRemove(beacon)
                self.supplyNodes[checkpointId] = nil
            end
        end
    end
end

function Runtime:_SyncDefenderLifecycle()
    for defenderId, actor in pairs(self.defenders) do
        local descriptor = self.session:GetDefender(defenderId)
        if not descriptor or descriptor.state == "retired" then
            self.combat.UnregisterExternalEnemy(actor, { removeNode = true, reason = "phase_retired" })
            self.defenders[defenderId] = nil
        elseif descriptor.state == "defeated" then
            -- Combat keeps a defeated external actor in its death-animation
            -- window. Keep the runtime reference until that window is over so
            -- Destroy() can still unregister it if the session finishes on
            -- the same frame; otherwise a removed map node could leave a
            -- stale external enemy in Combat's target/update lists.
            local enemy = actor.combatEnemy
            if enemy and (enemy.state == "dying" or enemy.state == "down")
                and actor.node then
                -- Combat owns the final transition from dying -> dead. The
                -- next sync pass will remove the descriptor after onRemoved.
            else
                if enemy then
                    self.combat.UnregisterExternalEnemy(actor,
                        { removeNode = true, reason = "defeated_sync" })
                end
                self.defenders[defenderId] = nil
            end
        elseif not actor.combatEnemy or not actor.node then
            self.defenders[defenderId] = nil
        end
    end
end

-- Session 在阶段切换时只更新队友的逻辑状态；这里把“倒下 -> 下一集结点
-- 复起”落到真实 Combat 外部实体，避免 HUD 显示已复起但场景角色仍停在
-- down 状态。只在状态边界发生时重置，避免每帧把活队友血量刷回 50%。
function Runtime:_SyncCompanionLifecycle()
    local session = self.session
    if not session then return end
    local rallyPoint = session.latestRallyPoint or "entry"
    local rally = self:GetRallyPosition(rallyPoint)
    for companionId, actor in pairs(self.companions or {}) do
        local descriptor = nil
        for _, companion in ipairs(session.companions or {}) do
            if companion.id == companionId then
                descriptor = companion
                break
            end
        end
        if descriptor and actor.combatEnemy then
            local previousState = actor._sessionCompanionState
            local combatState = actor.combatEnemy.state
            local isRevive = descriptor.state == "active"
                and (previousState == "down" or combatState == "down")
            if isRevive then
                local hpRatio = Clamp(descriptor.hpRatio, 0.50, 1.0)
                local reset = self.combat.ResetExternalEnemy(actor, {
                    state = "active",
                    hpRatio = hpRatio,
                    disengage = false,
                    reason = "siege_phase_rally",
                })
                if reset then
                    local side = companionId:sub(-1) == "1" and -1 or 1
                    if actor.node then
                        -- 倒下表现会关闭整棵队友节点及四个物理组件；
                        -- 复起时按 KCC 规范重新启用并 Warp 到集结点。
                        self:_SetActorPhysicalActive(actor,
                            true, rally + Vector3(side * 1.5, 0, -1.4))
                    end
                    actor.attackVisualTimer = 0
                    actor.healTimer = 0
                    self:_Play(actor, "idle", true)
                    self:_Emit("companion_rallied", {
                        companionId = companionId,
                        rallyPoint = rallyPoint,
                        hpRatio = hpRatio,
                    })
                else
                    self:_Emit("siege_runtime_error", {
                        reason = "队友复起失败：" .. tostring(companionId),
                    })
                end
            end
            actor._sessionCompanionState = descriptor.state
            actor._sessionCompanionPhase = session.phase
        end
    end
end

function Runtime:_SpawnPendingDefenders(dt)
    self.spawnTimer = math.max(0, (self.spawnTimer or 0) - dt)
    if self.spawnTimer > 0 then return end
    local pending = self.session:GetPendingSpawns()
    if #pending <= 0 then return end
    if self:_SpawnDefender(pending[1]) then
        self.spawnTimer = self.session.phase == "throne_defense" and 0.72 or 0.9
    else
        self.spawnTimer = 0.3
    end
end

function Runtime:_SetObjectiveMaterial(nodeName, color, emissive)
    local node = self.scene:GetChild(nodeName, true)
    if node then SetModelMaterial(node, CreateColorMaterial(color, emissive)) end
end

function Runtime:_SyncObjectiveVisuals()
    local gate = self.session:GetObjective("south_gate")
    if gate and gate.destroyed and not self.visualState.gateDestroyed then
        local gateNode = self.scene:GetChild("ShabakGate", true)
        -- 门板带刚体；破门后完整移除，避免不可见碰撞继续挡住路线。
        SafeRemove(gateNode)
        for index = -4, 4 do
            local bar = self.scene:GetChild("ShabakGateBar_" .. tostring(index), true)
            SafeRemove(bar)
        end
        self.visualState.gateDestroyed = true
    end
    local captures = {
        east_flag = "ShabakFlag_east_flag",
        west_flag = "ShabakFlag_west_flag",
        inner_flag = "ShabakFlag_inner_flag",
        palace_seal = "ShabakSeal_palace_seal",
        throne = "ShabakThrone_Base",
    }
    for objectiveId, nodeName in pairs(captures) do
        local objective = self.session:GetObjective(objectiveId)
        local completed = objective and (objective.captured or objective.destroyed)
        if completed and not self.visualState[objectiveId] then
            self:_SetObjectiveMaterial(nodeName, Color(0.72, 0.56, 0.12, 1.0),
                Color(0.30, 0.18, 0.02, 1.0))
            if objectiveId == "palace_seal" then
                SafeRemove(self.scene:GetChild("ShabakSeal_palace_seal", true))
                SafeRemove(self.scene:GetChild("ShabakSeal_Core", true))
                -- 封印破碎后打开皇宫中央宫门；若只移除封印特效而保留
                -- 门板碰撞，玩家会被挡在王座区外，坚守阶段永远无法开始。
                SafeRemove(self.scene:GetChild("ShabakPalace_Gate", true))
                SafeRemove(self.scene:GetChild("ShabakPalace_GateTop", true))
            end
            self.visualState[objectiveId] = true
        end
    end
end

function Runtime:_CreateSupplyBeacons()
    for checkpointId, position in pairs(SUPPLY_POSITIONS) do
        local beacon = self.root:CreateChild("ShabakSupply_" .. checkpointId)
        beacon.position = position + Vector3(0, 0.65, 0)
        beacon.scale = Vector3(0.46, 1.3, 0.46)
        local model = beacon:CreateComponent("StaticModel")
        model:SetModel(cache:GetResource("Model", "Models/Cylinder.mdl"))
        model:SetMaterial(CreateColorMaterial(Color(0.22, 0.72, 0.36, 1.0),
            Color(0.06, 0.24, 0.08, 1.0)))
        model.castShadows = false
        self.supplyNodes[checkpointId] = beacon
    end
end

function Runtime:Init(scene, playerNode, player, session, options)
    if self.initialized then return true end
    self.scene = scene or self.scene
    self.playerNode = playerNode or self.playerNode
    self.player = player or self.player
    self.session = session or self.session
    self.options = options or self.options or {}
    self.combat = self.options.combat or self.combat
    if not self.scene or not self.playerNode or not self.session or not self.combat then
        return false, "沙巴克运行时缺少场景、玩家或战斗系统"
    end
    self.root = self.scene:CreateChild("ShabakRuntime")
    self.defenders = {}
    self.companions = {}
    self.supplyNodes = {}
    self.visualState = {}
    self.spawnSerial = 0
    self.spawnTimer = 0
    self.destroyed = false
    self._siegeSkillCallback = function(context)
        return self:HandleSiegeSkillCast(context)
    end
    self.combat.onSiegeSkillCastContext = self._siegeSkillCallback
    self:_CreateSupplyBeacons()
    self:_SpawnCompanions()
    self.initialized = true
    return true
end

function Runtime:Start(...)
    return self:Init(...)
end

function Runtime:GetRallyPosition(rallyPoint)
    return RALLY_POSITIONS[rallyPoint] or RALLY_POSITIONS.entry
end

function Runtime:HandleSiegeSkillCast(context)
    if self.destroyed or not context or not self.session:IsActive() then return false end
    if context.target then return false end
    local position = context.position or (context.playerNode and context.playerNode.position)
    local skill = context.skill or {}
    if not position or not context.player then return false end

    -- 城门/封印只接受真正的攻击技能。击退、困魔、冲撞、增益、治疗和
    -- 其它零伤害技能不能消耗一次施法就推进攻城目标，避免“控制技能拆门”。
    local skillType = skill.type
    local skillDamage = tonumber(skill.damage)
    if (skillType ~= "melee" and skillType ~= "ranged"
            and skillType ~= "aoe" and skillType ~= "dot")
        or not skillDamage or skillDamage <= 0
        or skill.isKnockback == true or skill.isTrap == true
        or skillType == "dash" then
        return false
    end
    local skillRange = math.max(1.8, tonumber(skill.range) or 1.8) + 0.75

    if self.session.phase == "south_gate"
        and HorizontalDistance(position, ObjectivePosition("south_gate")) <= skillRange then
        -- CastSkill 会先尝试选择普通守军，但范围边界、前方夹角或上一帧
        -- 目标失效时 context.target 可能为空。再次按实际角色位置确认，
        -- 避免玩家贴着守军放技能却被错误消费为城门伤害。
        if self:_FindNearestDefender(position, skillRange) then return false end
        local multiplier = skillDamage
        local damage = math.max(1, math.floor((tonumber(context.player.atk) or 1)
            * multiplier / 100 + 0.5))
        self.session:DamageGate(damage)
        return { handled = true, result = "南门受损" }
    end

    -- 皇宫封印是第二个可破坏目标。只在玩家贴近封印、且当前没有普通
    -- 守军目标时消费本次攻击，避免攻击守军时伤害穿透到封印。
    if self.session.phase == "palace_seal"
        and HorizontalDistance(position, ObjectivePosition("palace_seal")) <= skillRange then
        if self:_FindNearestDefender(position, skillRange) then return false end
        local multiplier = skillDamage
        local damage = math.max(1, math.floor((tonumber(context.player.atk) or 1)
            * multiplier / 100 + 0.5))
        self.session:DamagePalaceSeal(damage)
        return { handled = true, result = "封印受冲击" }
    end
    return false
end

function Runtime:UseFieldMedkit(player)
    local activePlayer = player or self.player
    local used, result = self.session:UseFieldMedkit(activePlayer)
    if not used then return false, result end
    if activePlayer and self.combat.HealPlayer then
        self.combat.HealPlayer(activePlayer, result.healRatio, nil)
    end
    self:_Emit("field_medkit_used", { remaining = result.remaining })
    return true, result
end

function Runtime:ResetForRespawn(plan, playerNode, player)
    if self.destroyed then return false end
    self.playerNode = playerNode or self.playerNode
    self.player = player or self.player
    for defenderId, actor in pairs(self.defenders) do
        local descriptor = self.session:GetDefender(defenderId)
        if descriptor and descriptor.state == "active" then
            self.combat.ResetExternalEnemy(actor, { state = "guard", reason = "siege_respawn" })
            if actor.node then self:_SetActorPhysicalActive(actor, true, actor.homePosition) end
            self:_Play(actor, "idle", true)
        end
    end
    for companionId, actor in pairs(self.companions) do
        local descriptor = nil
        for _, companion in ipairs(self.session.companions or {}) do
            if companion.id == companionId then descriptor = companion; break end
        end
        if descriptor and descriptor.state == "active" then
            self.combat.ResetExternalEnemy(actor, {
                state = "active",
                hpRatio = descriptor.hpRatio or 0.50,
                reason = "siege_respawn",
            })
            local rally = self:GetRallyPosition((plan and plan.rallyPoint) or "entry")
            local side = companionId:sub(-1) == "1" and -1 or 1
            if actor.node then
                self:_SetActorPhysicalActive(actor, true,
                    rally + Vector3(side * 1.5, 0, -1.4))
            end
            self:_Play(actor, "idle", true)
        end
    end
    return true
end

function Runtime:Update(dt, playerNode, player, session, scene)
    if self.destroyed or not self.initialized then return {} end
    self.playerNode = playerNode or self.playerNode
    self.player = player or self.player
    self.session = session or self.session
    self.scene = scene or self.scene
    local delta = Clamp(dt, 0, 0.25)
    self:_SyncDefenderLifecycle()
    self:_UpdateObjectives(delta)
    self:_SyncCompanionLifecycle()
    self:_UpdateSupplies()
    self:_SpawnPendingDefenders(delta)
    self:_SyncObjectiveVisuals()
    return {}
end

function Runtime:Destroy()
    if self.destroyed then return true end
    self.destroyed = true
    if self.combat and self.combat.onSiegeSkillCastContext == self._siegeSkillCallback then
        self.combat.onSiegeSkillCastContext = nil
    end
    for _, actor in pairs(self.defenders or {}) do
        self.combat.UnregisterExternalEnemy(actor, { removeNode = false, reason = "siege_destroy" })
    end
    for _, actor in pairs(self.companions or {}) do
        self.combat.UnregisterExternalEnemy(actor, { removeNode = false, reason = "siege_destroy" })
    end
    SafeRemove(self.root)
    self.defenders = {}
    self.companions = {}
    self.supplyNodes = {}
    return true
end

function ShabakRuntime.Create(scene, playerNode, player, session, options)
    return setmetatable({
        scene = scene,
        playerNode = playerNode,
        player = player,
        session = session,
        options = options or {},
        combat = options and options.combat or nil,
        initialized = false,
        destroyed = false,
    }, Runtime)
end

return ShabakRuntime
