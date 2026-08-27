-- ============================================================================
-- ForgePanel.lua — 铁匠锻造台的自动选材配方卡
-- 不保存选择状态：材料分组、费用与可用性均由 Inventory 实时计算。
-- ============================================================================

local UI = require("urhox-libs/UI")
local Inventory = require("Inventory")

local ForgePanel = {}

local CLASS_NAMES = {
    warrior = "战士",
    mage = "法师",
    taoist = "道士",
}

local function Integer(value, fallback)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return fallback or 0
    end
    return math.floor(number)
end

local function FormatMaterial(item)
    local enhance = math.max(0, Integer(item and item.enhance, 0))
    return ((item and item.name) or "装备") .. (enhance > 0 and (" +" .. enhance) or "")
end

local function FormatMaterials(materials)
    local names = {}
    for _, item in ipairs(materials or {}) do
        table.insert(names, FormatMaterial(item))
    end
    if #names == 0 then return "暂无同组装备" end
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
        local reason = type(recipe.reason) == "string" and recipe.reason or ""
        return "暂无产物：" .. (reason ~= "" and reason or "该配方尚未开放")
    end
    local targetNames = type(recipe.targetNames) == "table" and recipe.targetNames or {}
    if #targetNames == 1 then
        return "获得 1 件：" .. targetNames[1]
    end
    if #targetNames > 1 then
        return "随机获得 1 件：" .. table.concat(targetNames, " / ")
    end
    return "获得 1 件：" .. Inventory.GetRarityName(recipe.targetRarity)
        .. Inventory.GetItemTypeName(recipe.itemType)
end

local function ShowToast(options, message)
    if options.showToast then
        options.showToast(message)
    else
        print("[ForgePanel] " .. message)
    end
end

local function NotifyGoldChanged(options)
    if options.onGoldChanged then
        options.onGoldChanged(Inventory.playerData.gold)
    end
end

local function Refresh(options)
    if options.onRefresh then options.onRefresh() end
end

local function RunRecipe(recipe, options)
    local ok, reason, targetRarity, resultItem = Inventory.ForgeRecipe(recipe)
    NotifyGoldChanged(options)
    if not ok then
        ShowToast(options, reason or "锻造失败")
        Refresh(options)
        return
    end

    local enhance = resultItem and math.max(0, Integer(resultItem.enhance, 0)) or 0
    local enhanceTag = enhance > 0 and (" +" .. enhance) or ""
    ShowToast(options, "锻造成功：[" .. Inventory.GetRarityName(targetRarity)
        .. "] " .. (resultItem and resultItem.name or "新装备") .. enhanceTag)
    if options.onSuccess then
        options.onSuccess(resultItem, targetRarity)
    end
    Refresh(options)
end

local function RequestForge(recipe, options)
    if not recipe.canForge then
        local reason = type(recipe.reason) == "string" and recipe.reason or ""
        ShowToast(options, reason ~= "" and reason or "当前配方不能锻造")
        return
    end

    if recipe.containsEnhanced then
        local required = math.max(1, Integer(recipe.required, 5))
        UI.Modal.Confirm {
            title = "确认使用强化材料",
            message = "本次会消耗背包中的 " .. required .. " 件材料：\n"
                .. FormatMaterials(recipe.materials)
                .. "\n其中包含强化过的装备；材料的强化等级不会继承到成品。已装备物品不会被消耗。是否继续？",
            confirmText = "消耗材料并锻造",
            cancelText = "返回检查",
            onConfirm = function() RunRecipe(recipe, options) end,
        }
        return
    end

    RunRecipe(recipe, options)
end

local function BuildRuleStep(number, text)
    return UI.Panel {
        width = "100%",
        flexDirection = "row",
        alignItems = "flex-start",
        gap = 8,
        children = {
            UI.Panel {
                width = 22, height = 22,
                flexShrink = 0,
                borderRadius = 11,
                backgroundColor = {92, 64, 28, 245},
                borderWidth = 1,
                borderColor = {202, 151, 68, 210},
                justifyContent = "center",
                alignItems = "center",
                children = {
                    UI.Label {
                        text = tostring(number),
                        fontSize = 11,
                        fontWeight = "bold",
                        fontColor = {255, 221, 142, 255},
                    },
                },
            },
            UI.Label {
                text = text,
                flex = 1,
                flexShrink = 1,
                fontSize = 10,
                lineHeight = 1.35,
                whiteSpace = "normal",
                wordBreak = "break-word",
                fontColor = {196, 190, 174, 220},
            },
        },
    }
end

local function BuildRecipeCard(recipe, options)
    local required = math.max(1, Integer(recipe.required, 5))
    local totalCount = math.max(0, Integer(recipe.count, 0))
    local selectedCount = math.min(totalCount, required)
    local availableCrafts = math.max(0, Integer(recipe.availableCrafts, 0))
    local targetColor = Inventory.GetRarityColor(recipe.targetRarity)
    local materialsReady = recipe.targetAvailable and recipe.hasMaterials
    local borderColor = recipe.canForge and {205, 151, 58, 230}
        or (materialsReady and {142, 98, 42, 190} or {76, 70, 60, 145})

    local progressText = "已找到 " .. selectedCount .. "/" .. required .. " 件材料"
    if totalCount > required then
        progressText = progressText .. " · 同组库存 " .. totalCount .. " 件"
    end

    local reason = type(recipe.reason) == "string" and recipe.reason or ""
    local statusText = recipe.canForge and "可以锻造"
        or (reason ~= "" and reason or "当前条件未满足")
    local statusColor = recipe.canForge and {143, 214, 126, 235}
        or materialsReady and {238, 170, 92, 235}
        or {180, 150, 120, 215}

    local cardChildren = {
        UI.Panel {
            width = "100%",
            flexDirection = "row",
            alignItems = "flex-start",
            gap = 8,
            children = {
                UI.Panel {
                    flex = 1,
                    flexShrink = 1,
                    alignItems = "flex-start",
                    gap = 3,
                    children = {
                        UI.Label {
                            text = Inventory.GetRarityName(recipe.sourceRarity)
                                .. " " .. GetRecipeTypeLabel(recipe)
                                .. "  →  " .. Inventory.GetRarityName(recipe.targetRarity),
                            fontSize = 13,
                            fontWeight = "bold",
                            fontColor = {targetColor[1], targetColor[2], targetColor[3], 245},
                            whiteSpace = "normal",
                            wordBreak = "break-word",
                            maxLines = 2,
                        },
                        UI.Label {
                            text = GetTargetText(recipe),
                            fontSize = 10,
                            lineHeight = 1.35,
                            whiteSpace = "normal",
                            wordBreak = "break-word",
                            fontColor = recipe.targetAvailable
                                and {206, 198, 180, 225} or {190, 122, 104, 225},
                            maxLines = 3,
                        },
                    },
                },
                UI.Panel {
                    minWidth = 76,
                    height = 30,
                    flexShrink = 0,
                    backgroundColor = recipe.hasMaterials and {88, 66, 28, 235}
                        or {42, 39, 34, 220},
                    borderRadius = 15,
                    borderWidth = 1,
                    borderColor = recipe.hasMaterials and {205, 158, 66, 190}
                        or {86, 80, 70, 150},
                    justifyContent = "center",
                    alignItems = "center",
                    children = {
                        UI.Label {
                            text = recipe.hasMaterials and (required .. "/" .. required .. " 已齐")
                                or (selectedCount .. "/" .. required),
                            fontSize = 11,
                            fontWeight = "bold",
                            fontColor = recipe.hasMaterials and {255, 216, 122, 255}
                                or {180, 176, 164, 220},
                        },
                    },
                },
            },
        },
        UI.Panel {
            width = "100%",
            marginTop = 7,
            padding = 8,
            gap = 4,
            backgroundColor = {15, 14, 12, 155},
            borderRadius = 6,
            children = {
                UI.Label {
                    text = progressText,
                    fontSize = 10,
                    fontWeight = "bold",
                    fontColor = recipe.hasMaterials and {235, 205, 132, 235}
                        or {176, 170, 154, 215},
                },
                UI.Label {
                    text = (recipe.hasMaterials and "将自动消耗：" or "背包中可用：")
                        .. FormatMaterials(recipe.materials),
                    fontSize = 9,
                    lineHeight = 1.35,
                    whiteSpace = "normal",
                    wordBreak = "break-word",
                    fontColor = {166, 162, 150, 205},
                    maxLines = 3,
                },
                recipe.targetAvailable and UI.Label {
                    text = "需要 " .. Integer(recipe.cost, 0) .. " 金币  →  获得 1 件",
                    fontSize = 10,
                    fontColor = {232, 196, 112, 230},
                } or nil,
            },
        },
        UI.Label {
            text = statusText,
            fontSize = 10,
            fontWeight = recipe.canForge and "bold" or "normal",
            fontColor = statusColor,
            marginTop = 6,
            whiteSpace = "normal",
            wordBreak = "break-word",
        },
    }

    if recipe.containsEnhanced and recipe.hasMaterials then
        table.insert(cardChildren, UI.Label {
            text = "注意：材料中有强化装备，强化等级不会继承；锻造前会再次确认。",
            fontSize = 9,
            fontColor = {240, 151, 79, 235},
            marginTop = 3,
            whiteSpace = "normal",
        })
    elseif availableCrafts > 1 then
        table.insert(cardChildren, UI.Label {
            text = "同组材料可锻造 " .. availableCrafts
                .. " 次；本次只锻造 1 件。",
            fontSize = 9,
            fontColor = {158, 185, 148, 215},
            marginTop = 3,
            whiteSpace = "normal",
        })
    end

    local buttonText = "暂不能锻造"
    if recipe.canForge then
        buttonText = "锻造 1 件 · " .. Integer(recipe.cost, 0) .. " 金币"
    elseif not recipe.targetAvailable then
        buttonText = "当前没有对应产物"
    elseif not recipe.hasMaterials then
        buttonText = "还差 " .. math.max(0, required - totalCount) .. " 件材料"
    elseif not recipe.hasGold then
        buttonText = "金币不足"
    end

    table.insert(cardChildren, UI.Button {
        text = buttonText,
        width = "100%",
        minHeight = 42,
        marginTop = 8,
        variant = recipe.canForge and "primary" or "outline",
        disabled = not recipe.canForge,
        fontSize = 12,
        onClick = function() RequestForge(recipe, options) end,
    })

    return UI.Panel {
        width = "100%",
        flexShrink = 0,
        padding = 11,
        backgroundColor = recipe.canForge and {33, 27, 18, 242} or {24, 22, 19, 220},
        borderRadius = 8,
        borderWidth = recipe.canForge and 2 or 1,
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
            fontSize = 13,
            fontWeight = "bold",
            fontColor = {226, 204, 145, 245},
        },
        UI.Label {
            text = subtitle,
            fontSize = 9,
            lineHeight = 1.35,
            whiteSpace = "normal",
            wordBreak = "break-word",
            fontColor = {145, 142, 134, 190},
            marginBottom = 4,
        },
    }
    for _, recipe in ipairs(recipes) do
        table.insert(children, BuildRecipeCard(recipe, options))
    end

    return UI.Panel {
        width = "100%",
        gap = 7,
        marginBottom = 12,
        children = children,
    }
end

--- 构建铁匠专用、无需手动选材的锻造面板。
---@param options table { showToast?: function, onRefresh?: function, onGoldChanged?: function, onSuccess?: function }
---@return table
function ForgePanel.Build(options)
    options = options or {}
    local recipes = Inventory.GetForgeRecipes()
    local forgeableRecipes = {}
    local blockedRecipes = {}
    local progressRecipes = {}
    local unavailableRecipes = {}

    for _, recipe in ipairs(recipes) do
        if not recipe.targetAvailable then
            table.insert(unavailableRecipes, recipe)
        elseif recipe.canForge then
            table.insert(forgeableRecipes, recipe)
        elseif recipe.hasMaterials then
            table.insert(blockedRecipes, recipe)
        else
            table.insert(progressRecipes, recipe)
        end
    end

    local currentGold = math.max(0, Integer(Inventory.playerData.gold, 0))
    local children = {
        UI.Panel {
            width = "100%",
            padding = 11,
            gap = 9,
            backgroundColor = {30, 25, 17, 235},
            borderRadius = 8,
            borderWidth = 1,
            borderColor = {130, 91, 41, 180},
            children = {
                UI.Panel {
                    width = "100%",
                    flexDirection = "row",
                    justifyContent = "space-between",
                    alignItems = "flex-start",
                    gap = 10,
                    children = {
                        UI.Panel {
                            flex = 1,
                            flexShrink = 1,
                            alignItems = "flex-start",
                            children = {
                                UI.Label {
                                    text = "5 件同品质同部位  →  1 件更高品质",
                                    fontSize = 16,
                                    fontWeight = "bold",
                                    fontColor = {238, 205, 130, 250},
                                },
                                UI.Label {
                                    text = "选择下面的配方即可；铁匠会从背包自动挑选材料。武器还需同职业。",
                                    fontSize = 10,
                                    lineHeight = 1.35,
                                    whiteSpace = "normal",
                                    wordBreak = "break-word",
                                    fontColor = {188, 182, 166, 210},
                                    marginTop = 3,
                                },
                            },
                        },
                        UI.Panel {
                            flexShrink = 0,
                            paddingHorizontal = 9,
                            paddingVertical = 6,
                            backgroundColor = {63, 48, 22, 225},
                            borderRadius = 8,
                            borderWidth = 1,
                            borderColor = {178, 132, 53, 180},
                            children = {
                                UI.Label {
                                    text = "金币 " .. currentGold,
                                    fontSize = 11,
                                    fontWeight = "bold",
                                    fontColor = {244, 211, 112, 245},
                                },
                            },
                        },
                    },
                },
                UI.Panel {
                    width = "100%",
                    height = 1,
                    backgroundColor = {112, 82, 40, 125},
                },
                BuildRuleStep(1, "准备 5 件同品质、同部位的装备；武器还必须属于同一职业。"),
                BuildRuleStep(2, "铁匠优先消耗未强化、属性较低的背包装备；已装备物品不会被选中。"),
                BuildRuleStep(3, "每次消耗卡片所示金币并锻造 1 件；成品有 30% 概率自带 +1~+2 强化。"),
            },
        },
        UI.Panel {
            width = "100%",
            height = 1,
            backgroundColor = {92, 76, 45, 135},
            marginVertical = 9,
        },
    }

    if #recipes == 0 then
        table.insert(children, UI.Panel {
            width = "100%",
            minHeight = 130,
            justifyContent = "center",
            alignItems = "center",
            gap = 6,
            paddingHorizontal = 16,
            children = {
                UI.Label {
                    text = "还没有可用的锻造配方",
                    fontSize = 14,
                    fontWeight = "bold",
                    fontColor = {186, 181, 166, 220},
                },
                UI.Label {
                    text = "先获得普通至史诗品质的背包装备；同组材料出现后，铁匠会自动列出进度。",
                    fontSize = 10,
                    lineHeight = 1.4,
                    whiteSpace = "normal",
                    wordBreak = "break-word",
                    textAlign = "center",
                    fontColor = {142, 139, 130, 185},
                },
            },
        })
    else
        local forgeableSection = BuildSection(
            "现在可锻造",
            "点击按钮后，铁匠会自动选择并消耗卡片列出的 5 件装备。",
            forgeableRecipes,
            options)
        local blockedSection = BuildSection(
            "材料已齐 · 暂不能锻造",
            "通常是金币不足；卡片会直接显示原因。",
            blockedRecipes,
            options)
        local progressSection = BuildSection(
            "继续收集材料",
            "凑齐 5 件同组装备后，这张卡会自动移到“现在可锻造”。",
            progressRecipes,
            options)
        local unavailableSection = BuildSection(
            "暂不可锻造",
            "这些部位当前没有下一品质产物，铁匠不会消耗材料。",
            unavailableRecipes,
            options)
        if forgeableSection then table.insert(children, forgeableSection) end
        if blockedSection then table.insert(children, blockedSection) end
        if progressSection then table.insert(children, progressSection) end
        if unavailableSection then table.insert(children, unavailableSection) end
    end

    return UI.Panel {
        width = "100%",
        paddingBottom = 10,
        children = children,
    }
end

return ForgePanel
