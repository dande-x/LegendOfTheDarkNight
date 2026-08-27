-- ============================================================================
-- ForgePanel.lua — 锻造页配方卡与一键锻造交互
-- 不保存选择状态：所有材料分组和可用性均由 Inventory 实时计算。
-- ============================================================================

local UI = require("urhox-libs/UI")
local Inventory = require("scripts.Inventory")

local ForgePanel = {}

local CLASS_NAMES = {
    warrior = "战士",
    mage = "法师",
    taoist = "道士",
}

local function FormatMaterial(item)
    local enhance = math.max(0, math.floor(tonumber(item.enhance) or 0))
    return (item.name or "装备") .. (enhance > 0 and (" +" .. enhance) or "")
end

local function FormatMaterials(materials)
    local names = {}
    for _, item in ipairs(materials or {}) do
        table.insert(names, FormatMaterial(item))
    end
    if #names == 0 then return "暂无材料" end
    return table.concat(names, "、")
end

local function GetRecipeTypeLabel(recipe)
    local typeName = Inventory.GetItemTypeName(recipe.itemType)
    if recipe.itemType == "weapon" then
        return (CLASS_NAMES[recipe.classReq] or "通用") .. typeName
    end
    return typeName
end

local function GetTargetText(recipe)
    if not recipe.targetAvailable then
        return recipe.reason
    end
    if #recipe.targetNames == 1 then
        return "产物：" .. recipe.targetNames[1]
    end
    if #recipe.targetNames > 1 then
        return "随机产物：" .. table.concat(recipe.targetNames, " / ")
    end
    return "产物：" .. Inventory.GetRarityName(recipe.targetRarity)
        .. Inventory.GetItemTypeName(recipe.itemType)
end

local function ShowToast(options, message)
    if options.showToast then
        options.showToast(message)
    else
        print("[ForgePanel] " .. message)
    end
end

local function Refresh(options)
    if options.onRefresh then options.onRefresh() end
end

local function RunRecipe(recipe, options)
    local ok, reason, targetRarity, resultItem = Inventory.ForgeRecipe(recipe)
    if not ok then
        ShowToast(options, reason or "锻造失败")
        Refresh(options)
        return
    end

    local enhance = resultItem and math.max(0, math.floor(tonumber(resultItem.enhance) or 0)) or 0
    local enhanceTag = enhance > 0 and (" +" .. enhance) or ""
    ShowToast(options, "锻造成功：[" .. Inventory.GetRarityName(targetRarity)
        .. "] " .. (resultItem and resultItem.name or "新装备") .. enhanceTag)
    Refresh(options)
end

local function RequestForge(recipe, options)
    if not recipe.canForge then return end

    if recipe.containsEnhanced then
        UI.Modal.Confirm {
            title = "确认消耗强化装备",
            message = "系统将优先消耗以下三件材料：\n"
                .. FormatMaterials(recipe.materials)
                .. "\n其中包含已强化装备，确定继续吗？",
            confirmText = "继续锻造",
            cancelText = "暂不锻造",
            onConfirm = function() RunRecipe(recipe, options) end,
        }
        return
    end

    RunRecipe(recipe, options)
end

local function BuildRecipeCard(recipe, options)
    local targetColor = Inventory.GetRarityColor(recipe.targetRarity)
    local ready = recipe.targetAvailable and recipe.hasMaterials
    local borderColor = recipe.canForge and {185, 137, 54, 220}
        or (ready and {120, 90, 45, 180} or {76, 70, 60, 145})
    local buttonText = recipe.canForge
        and ("立即锻造 · " .. recipe.cost .. " 金")
        or recipe.reason

    local cardChildren = {
        UI.Panel {
            width = "100%", flexDirection = "row",
            alignItems = "flex-start", gap = 8,
            children = {
                UI.Panel {
                    flex = 1, flexShrink = 1, alignItems = "flex-start", gap = 3,
                    children = {
                        UI.Label {
                            text = Inventory.GetRarityName(recipe.sourceRarity)
                                .. " " .. GetRecipeTypeLabel(recipe)
                                .. "  →  " .. Inventory.GetRarityName(recipe.targetRarity),
                            fontSize = 13, fontWeight = "bold",
                            fontColor = {targetColor[1], targetColor[2], targetColor[3], 245},
                            maxLines = 2,
                        },
                        UI.Label {
                            text = GetTargetText(recipe),
                            fontSize = 10,
                            fontColor = recipe.targetAvailable
                                and {196, 190, 172, 220} or {185, 120, 100, 220},
                            maxLines = 2,
                        },
                    },
                },
                UI.Panel {
                    minWidth = 54, height = 28,
                    backgroundColor = recipe.hasMaterials and {88, 66, 28, 235} or {42, 39, 34, 220},
                    borderRadius = 14, borderWidth = 1,
                    borderColor = recipe.hasMaterials and {205, 158, 66, 190} or {86, 80, 70, 150},
                    justifyContent = "center", alignItems = "center",
                    children = {
                        UI.Label {
                            text = recipe.count .. "/3",
                            fontSize = 12, fontWeight = "bold",
                            fontColor = recipe.hasMaterials and {255, 216, 122, 255}
                                or {180, 176, 164, 220},
                        },
                    },
                },
            },
        },
        UI.Label {
            text = (recipe.targetAvailable and "自动消耗：" or "背包持有：")
                .. FormatMaterials(recipe.materials),
            fontSize = 10,
            fontColor = {166, 162, 150, 205},
            maxLines = 2,
            marginTop = 5,
        },
    }

    if recipe.containsEnhanced and recipe.hasMaterials then
        table.insert(cardChildren, UI.Label {
            text = "含强化材料，执行前会再次确认",
            fontSize = 9,
            fontColor = {236, 154, 82, 230},
            marginTop = 3,
        })
    elseif recipe.availableCrafts > 1 then
        table.insert(cardChildren, UI.Label {
            text = "当前材料可连续锻造 " .. recipe.availableCrafts .. " 次",
            fontSize = 9,
            fontColor = {158, 174, 148, 205},
            marginTop = 3,
        })
    end

    table.insert(cardChildren, UI.Button {
        text = buttonText,
        width = "100%", minHeight = 40,
        marginTop = 8,
        variant = recipe.canForge and "primary" or "outline",
        disabled = not recipe.canForge,
        onClick = function() RequestForge(recipe, options) end,
    })

    return UI.Panel {
        width = "100%", flexShrink = 0,
        padding = 10,
        backgroundColor = recipe.canForge and {33, 27, 18, 242} or {24, 22, 19, 220},
        borderRadius = 8, borderWidth = recipe.canForge and 2 or 1,
        borderColor = borderColor,
        boxShadow = recipe.canForge and {
            { x = 0, y = 3, blur = 8, spread = 0, color = {0, 0, 0, 100} },
        } or nil,
        children = cardChildren,
    }
end

local function BuildSection(title, subtitle, recipes, options)
    if #recipes == 0 then return nil end

    local children = {
        UI.Label {
            text = title,
            fontSize = 13, fontWeight = "bold",
            fontColor = {226, 204, 145, 245},
        },
        UI.Label {
            text = subtitle,
            fontSize = 9,
            fontColor = {145, 142, 134, 190},
            marginBottom = 4,
        },
    }
    for _, recipe in ipairs(recipes) do
        table.insert(children, BuildRecipeCard(recipe, options))
    end

    return UI.Panel {
        width = "100%", gap = 7, marginBottom = 10,
        children = children,
    }
end

--- 构建无手动选材的锻造面板。
---@param options table { showToast?: function, onRefresh?: function }
---@return table
function ForgePanel.Build(options)
    options = options or {}
    local recipes = Inventory.GetForgeRecipes()
    local readyRecipes = {}
    local progressRecipes = {}
    local unavailableRecipes = {}

    for _, recipe in ipairs(recipes) do
        if not recipe.targetAvailable then
            table.insert(unavailableRecipes, recipe)
        elseif recipe.hasMaterials then
            table.insert(readyRecipes, recipe)
        else
            table.insert(progressRecipes, recipe)
        end
    end

    local children = {
        UI.Panel {
            width = "100%", padding = 10,
            backgroundColor = {30, 25, 17, 235},
            borderRadius = 8, borderWidth = 1,
            borderColor = {112, 86, 44, 165},
            children = {
                UI.Panel {
                    width = "100%", flexDirection = "row",
                    justifyContent = "space-between", alignItems = "center",
                    children = {
                        UI.Label {
                            text = "一键锻造",
                            fontSize = 16, fontWeight = "bold",
                            fontColor = {238, 205, 130, 250},
                        },
                        UI.Label {
                            text = "金币 " .. math.max(0, math.floor(tonumber(Inventory.playerData.gold) or 0)),
                            fontSize = 12, fontWeight = "bold",
                            fontColor = {244, 211, 112, 245},
                        },
                    },
                },
                UI.Label {
                    text = "系统自动按品质、部位和职业分组，不会混用不兼容材料。",
                    fontSize = 10, fontColor = {194, 188, 172, 215},
                    marginTop = 5,
                },
                UI.Label {
                    text = "每次消耗 3 件；优先使用未强化、属性较低的背包装备。",
                    fontSize = 9, fontColor = {151, 148, 138, 190},
                    marginTop = 2,
                },
            },
        },
        UI.Panel {
            width = "100%", height = 1,
            backgroundColor = {92, 76, 45, 135}, marginVertical = 8,
        },
    }

    if #recipes == 0 then
        table.insert(children, UI.Panel {
            width = "100%", minHeight = 120,
            justifyContent = "center", alignItems = "center", gap = 5,
            children = {
                UI.Label {
                    text = "暂无可锻造装备",
                    fontSize = 14, fontWeight = "bold",
                    fontColor = {186, 181, 166, 220},
                },
                UI.Label {
                    text = "获得普通至史诗品质装备后，配方会自动出现在这里。",
                    fontSize = 10, textAlign = "center",
                    fontColor = {142, 139, 130, 185},
                },
            },
        })
    else
        local readySection = BuildSection(
            "可锻造", "材料齐全的配方优先显示", readyRecipes, options)
        local progressSection = BuildSection(
            "材料进度", "凑齐同组 3 件后即可直接锻造", progressRecipes, options)
        local unavailableSection = BuildSection(
            "暂未开放", "这些部位当前没有下一品质模板，不会允许误操作", unavailableRecipes, options)
        if readySection then table.insert(children, readySection) end
        if progressSection then table.insert(children, progressSection) end
        if unavailableSection then table.insert(children, unavailableSection) end
    end

    return UI.Panel {
        width = "100%",
        paddingBottom = 8,
        children = children,
    }
end

return ForgePanel
