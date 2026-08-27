-- ============================================================================
-- OutfitUtils.lua — 新男性模型的骨骼跟随职业服装辅助
--
-- 服装不是挂在 CharacterModel 根节点上的静态几何，而是分别挂到身体骨骼。
-- 这样胸甲、肩甲、护腕、护腿等部件会随对应骨骼的动作移动，避免整套衣服
-- 在攻击和跑步时脱离身体。真正的基础人体仍然使用新模型 prefab。
-- ============================================================================
local G = require("classes.GeomUtils")

local OutfitUtils = {}

function OutfitUtils.MakeMaterial(color, roughness, metallic, emissive)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Roughness", Variant(roughness or 0.75))
    mat:SetShaderParameter("Metallic", Variant(metallic or 0.0))
    if emissive then
        mat:SetShaderParameter("MatEmissiveColor", Variant(emissive))
    end
    return mat
end

--- 根据当前新男性模型的包围盒计算服装的基础比例。
function OutfitUtils.GetFrame(bounds)
    local size = bounds.size
    local height = math.max(size.y, 0.5)
    local bodyWidth = math.max(size.x, height * 0.22)
    local bodyDepth = math.max(size.z, height * 0.14)

    return {
        height = height,
        torsoWidth = math.min(bodyWidth * 0.72, height * 0.30),
        torsoDepth = math.min(bodyDepth * 0.82, height * 0.20),
        limbWidth = math.max(height * 0.055, bodyWidth * 0.16),
        limbDepth = math.max(height * 0.045, bodyDepth * 0.24),
    }
end

--- 在指定骨骼下创建一件会随骨骼运动的服装部件。
function OutfitUtils.PartOnBone(skeleton, boneName, name, material, build, position, rotation, scale)
    local bone = skeleton:GetBone(boneName)
    if not bone or not bone.node then
        print(string.format("[Outfit] WARNING: bone '%s' not found for '%s'", boneName, name))
        return nil
    end

    local node = bone.node:CreateChild(name)
    node.position = position or Vector3.ZERO
    node.rotation = rotation or Quaternion.IDENTITY
    node.scale = scale or Vector3(1, 1, 1)

    local geom = node:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)
    local ok, err = pcall(function()
        build(geom)
        geom:Commit()
        geom:SetMaterial(material)
    end)

    if not ok then
        print(string.format("[Outfit] ERROR: failed to build '%s' on '%s': %s", name, boneName, tostring(err)))
        node:Remove()
        return nil
    end

    return node
end

function OutfitUtils.BoxOnBone(skeleton, boneName, name, material, position, halfExtents, rotation)
    return OutfitUtils.PartOnBone(skeleton, boneName, name, material, function(geom)
        G.addBox(geom, 0, 0, 0, halfExtents.x, halfExtents.y, halfExtents.z)
    end, position, rotation)
end

function OutfitUtils.CylinderOnBone(skeleton, boneName, name, material, position, radius, height, segments, rotation)
    return OutfitUtils.PartOnBone(skeleton, boneName, name, material, function(geom)
        G.addCylinder(geom, 0, 0, 0, radius, height, segments or 12)
    end, position, rotation)
end

function OutfitUtils.TaperedOnBone(skeleton, boneName, name, material, position, radiusBot, radiusTop, height, segments, rotation)
    return OutfitUtils.PartOnBone(skeleton, boneName, name, material, function(geom)
        G.addTapered(geom, 0, 0, 0, radiusBot, radiusTop, height, segments or 12)
    end, position, rotation)
end

return OutfitUtils
