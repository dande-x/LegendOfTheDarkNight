local models = {
    { name = "奇城之子", uuid = "uuid://CVcMGYMLqs_9uIbIf5pIVsaw" },
    { name = "机械人形", uuid = "uuid://ARoaobEzRVktIvNfBEsDPWeQ" },
}

local probeBones = {
    "Root", "Hip", "Waist", "Spine01", "Spine02", "NeckTwist01", "Head",
    "L_UpLeg", "L_Leg", "L_Foot", "R_UpLeg", "R_Leg", "R_Foot",
    "L_Shoulder", "L_Arm", "L_ForeArm", "L_Hand", "R_Shoulder", "R_Arm", "R_ForeArm", "R_Hand",
    "Bip001", "Bip001 Pelvis", "Bip001 Spine", "Bip001 L Thigh", "Bip001 R Thigh"
}

local function PrintSkeletonInfo(label, model)
    print("========== " .. label .. " ==========")
    if not model then
        print("MODEL_LOAD_FAILED")
        return
    end

    local skeleton = model:GetSkeleton()
    if not skeleton then
        print("NO_SKELETON_OBJECT")
        return
    end

    local numBones = skeleton:GetNumBones()
    print("BONE_COUNT=" .. tostring(numBones))
    local root = skeleton:GetRootBone()
    if root then
        print("ROOT_BONE=" .. tostring(root.name) .. " parent=" .. tostring(root.parentIndex))
    else
        print("ROOT_BONE=nil")
    end

    local maxList = math.min(numBones, 120)
    for i = 0, maxList - 1 do
        local bone = skeleton:GetBone(i)
        if bone then
            print(string.format("BONE[%d]=%s parent=%s animated=%s", i, tostring(bone.name), tostring(bone.parentIndex), tostring(bone.animated)))
        end
    end
    if numBones > maxList then
        print("BONE_LIST_TRUNCATED=" .. tostring(numBones - maxList))
    end

    print("-- probe standard bones --")
    for _, name in ipairs(probeBones) do
        local bone = skeleton:GetBone(name)
        if bone then
            print("HAS " .. name .. " parent=" .. tostring(bone.parentIndex) .. " animated=" .. tostring(bone.animated))
        end
    end
end

function Start()
    local ok, err = pcall(function()
        for _, item in ipairs(models) do
            local model = cache:GetResource("Model", item.uuid)
            PrintSkeletonInfo(item.name .. " " .. item.uuid, model)
        end
    end)
    if not ok then
        log:Write(LOG_ERROR, "[model-skeleton-probe] " .. tostring(err))
    end
    engine:Exit()
end
