-- ============================================================================
-- Mage.lua — 法师职业：大型木质法杖 + 新男性模型骨骼跟随法袍
-- ============================================================================
local G = require("classes.GeomUtils")
local Outfit = require("classes.OutfitUtils")

local WEAPON_SCALE = 1.16

local Mage = {}

Mage.animSet = "male"
Mage.poseAnims = {
    hold = "combat_idle",
    attack = "staff_slam",
}

Mage.weapon = {
    name = "法杖",
    bone = "R_Hand",
    offset = Vector3(0.0, 0.06, 0.0),
    rotation = Quaternion(0, 0, 90),
    scale = Vector3(WEAPON_SCALE, WEAPON_SCALE, WEAPON_SCALE),
}

-- 仅供旧模型分支使用；新男性模型继续使用独立基础人体。
Mage.prefab = "Prefabs/MageRobe.prefab"

Mage.material = {
    technique = "Techniques/PBR/PBRDiff.xml",
    useTexture = false,
    diffColor = Color(1.0, 1.0, 1.0, 1.0),
    roughness = 0.70,
    metallic = 0.0,
    emissive = Color(0.0, 0.0, 0.0),
}

Mage.skillAnims = {
    melee  = { anim = "staff_slam",  speed = 1.5, duration = 0.45 },
    ranged = { anim = "cast_heavy",  speed = 1.3, duration = 0.50 },
    aoe    = { anim = "cast_long",   speed = 1.0, duration = 0.80 },
    dash   = { anim = "dash_strike", speed = 2.0, duration = 0.30 },
    buff   = { anim = "cast_quick",  speed = 0.8, duration = 1.00 },
    heal   = { anim = "cast_quick",  speed = 0.7, duration = 1.10 },
    dot    = { anim = "cast_heavy",  speed = 1.5, duration = 0.45 },
    summon = { anim = "cast_long",   speed = 0.6, duration = 1.50 },
}

-- 法杖建模（以 Y=0 为掌心握持中心）
function Mage.buildWeapon(weaponNode)
    local geom = weaponNode:CreateComponent("CustomGeometry")
    geom:BeginGeometry(0, TRIANGLE_LIST)
    local seg = 12
    local gripR, shaftR = 0.020, 0.017
    local bottomLen, topLen, bottomR = 0.40, 0.68, 0.022
    local tipH = 0.05
    G.addTapered(geom, 0, -bottomLen - tipH/2, 0, 0.005, bottomR, tipH, seg)
    G.addTapered(geom, 0, -bottomLen/2, 0, bottomR, gripR, bottomLen, seg)
    local wR = gripR * 1.4
    for _, y in ipairs({-0.020, -0.008, 0.004, 0.016, 0.028}) do
        G.addCylinder(geom, 0, y, 0, wR, 0.009, seg)
    end
    G.addTapered(geom, 0, topLen / 2, 0, gripR, shaftR * 0.80, topLen, seg)
    local topY = topLen + 0.01
    G.addSphere(geom, 0, topY, 0, shaftR * 1.6, 6, seg)
    local seatY = topY + 0.02
    G.addCylinder(geom, 0, seatY + 0.015, 0, shaftR * 0.96, 0.03, seg)
    local orbR = 0.065
    G.addSphere(geom, 0, seatY + 0.045 + orbR, 0, orbR, 10, seg)
    geom:Commit()

    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.40, 0.24, 0.12, 1.0)))
    mat:SetShaderParameter("Roughness", Variant(0.68))
    mat:SetShaderParameter("Metallic", Variant(0.05))
    mat:SetShaderParameter("MatEmissiveColor", Variant(Color(0.8, 0.85, 1.0)))
    geom:SetMaterial(mat)
end

-- 新男性法师：服装部件挂在新模型对应骨骼，而不是挂在根节点。
function Mage.buildOutfit(modelNode, animModel)
    local skeleton = animModel and animModel:GetSkeleton()
    if not skeleton then return end

    local frame = Outfit.GetFrame(animModel.boundingBox)
    local robe = Outfit.MakeMaterial(Color(0.10, 0.035, 0.16, 1.0), 0.72, 0.02, Color(0.015, 0.0, 0.025))
    local trim = Outfit.MakeMaterial(Color(0.55, 0.10, 0.08, 1.0), 0.42, 0.18, Color(0.035, 0.005, 0.0))
    local gold = Outfit.MakeMaterial(Color(0.62, 0.40, 0.10, 1.0), 0.28, 0.72, Color(0.05, 0.02, 0.0))

    Outfit.BoxOnBone(skeleton, "Spine02", "MageRobeChest", robe, Vector3(0, 0, frame.torsoDepth * 0.10),
        Vector3(frame.torsoWidth * 0.52, frame.height * 0.15, frame.torsoDepth * 0.52))
    Outfit.BoxOnBone(skeleton, "Spine01", "MageRobeWaist", robe, Vector3(0, -frame.height * 0.05, 0),
        Vector3(frame.torsoWidth * 0.56, frame.height * 0.11, frame.torsoDepth * 0.56))
    Outfit.BoxOnBone(skeleton, "Spine01", "MageRobeTrim", trim, Vector3(0, frame.height * 0.04, frame.torsoDepth * 0.56),
        Vector3(frame.torsoWidth * 0.48, frame.height * 0.018, frame.torsoDepth * 0.06))
    Outfit.BoxOnBone(skeleton, "Pelvis", "MageRobeSkirt", robe, Vector3(0, -frame.height * 0.05, 0),
        Vector3(frame.torsoWidth * 0.64, frame.height * 0.13, frame.torsoDepth * 0.64))
    Outfit.BoxOnBone(skeleton, "Pelvis", "MageRobeBelt", gold, Vector3(0, frame.height * 0.07, frame.torsoDepth * 0.62),
        Vector3(frame.torsoWidth * 0.65, frame.height * 0.018, frame.torsoDepth * 0.055))

    for _, side in ipairs({"L", "R"}) do
        Outfit.CylinderOnBone(skeleton, side .. "_Forearm", "MageCuff_" .. side, trim,
            Vector3.ZERO, frame.limbWidth * 1.15, frame.height * 0.12, 10)
        Outfit.BoxOnBone(skeleton, side .. "_Upperarm", "MageSleeve_" .. side, robe, Vector3.ZERO,
            Vector3(frame.limbWidth * 1.35, frame.height * 0.14, frame.limbDepth * 1.35))
        Outfit.BoxOnBone(skeleton, side .. "_Thigh", "MageLegWrap_" .. side, robe,
            Vector3(0, -frame.height * 0.03, 0),
            Vector3(frame.limbWidth * 1.35, frame.height * 0.14, frame.limbDepth * 1.35))
    end
end

return Mage
