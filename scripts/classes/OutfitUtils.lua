-- ============================================================================
-- OutfitUtils.lua — 新模型职业服装的程序化几何与材质辅助
-- ============================================================================
local G = require("classes.GeomUtils")

local OutfitUtils = {}

--- 根据实际模型包围盒计算服装比例，避免假设模型尺寸。
function OutfitUtils.GetFrame(bounds)
    local size = bounds.size
    local minY = bounds.min.y
    local height = math.max(size.y, 0.5)
    local width = math.max(size.x, height * 0.30)
    local depth = math.max(size.z, height * 0.18)

    return {
        minY = minY,
        height = height,
        width = width,
        depth = depth,
        torsoWidth = math.min(width * 0.56, height * 0.34),
        torsoDepth = math.min(depth * 0.62, height * 0.24),
        y = function(ratio)
            return minY + height * ratio
        end,
    }
end

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

--- 创建一个一次性 CustomGeometry 服装部件。
function OutfitUtils.Part(parent, name, material, build)
    local node = parent:CreateChild(name)
    local geom = node:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)
    build(geom)
    geom:Commit()
    geom:SetMaterial(material)
    return node
end

function OutfitUtils.Box(parent, name, material, cx, cy, cz, hx, hy, hz)
    return OutfitUtils.Part(parent, name, material, function(geom)
        G.addBox(geom, cx, cy, cz, hx, hy, hz)
    end)
end

function OutfitUtils.Tapered(parent, name, material, cx, cy, cz, radiusBot, radiusTop, height, segments)
    return OutfitUtils.Part(parent, name, material, function(geom)
        G.addTapered(geom, cx, cy, cz, radiusBot, radiusTop, height, segments or 12)
    end)
end

function OutfitUtils.Cylinder(parent, name, material, cx, cy, cz, radius, height, segments)
    return OutfitUtils.Part(parent, name, material, function(geom)
        G.addCylinder(geom, cx, cy, cz, radius, height, segments or 12)
    end)
end

function OutfitUtils.Sphere(parent, name, material, cx, cy, cz, radius, rings, segments)
    return OutfitUtils.Part(parent, name, material, function(geom)
        G.addSphere(geom, cx, cy, cz, radius, rings or 8, segments or 12)
    end)
end

return OutfitUtils
