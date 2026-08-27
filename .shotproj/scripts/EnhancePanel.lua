-- ============================================================================
-- EnhancePanel.lua — 铁匠强化页
--
-- 强化只能从铁匠入口发起。面板把“选装备 → 看预览 → 确认风险 → 结算结果”
-- 收在同一条流程里，不再让玩家在角色面板里寻找强化石或猜测失败结果。
-- ============================================================================

local UI = require("urhox-libs/UI")
local Inventory = require("Inventory")
local ServiceScrollView = require("ServiceScrollView")

local EnhancePanel = {}

local SLOT_ORDER = {
    Inventory.SLOT.HELMET,
    Inventory.SLOT.ARMOR,
    Inventory.SLOT.WEAPON,
    Inventory.SLOT.NECKLACE,
    Inventory.SLOT.BRACELET1,
    Inventory.SLOT.BRACELET2,
    Inventory.SLOT.RING1,
    Inventory.SLOT.RING2,
    Inventory.SLOT.BELT,
    Inventory.SLOT.BOOTS,
}

local STAT_DEFS = {
    { key = "atk", label = "攻击", color = {255, 112, 92, 245} },
    { key = "def", label = "防御", color = {100, 188, 255, 245} },
    { key = "hp",  label = "生命", color = {104, 222, 124, 245} },
}

local function Integer(value, fallback)
    local number = tonumber(value)
    if not number or number ~= number or number == math.huge or number == -math.huge then
        return fallback or 0
    end
    return math.floor(number)
end

local function ClampLevel(item)
    return math.max(0, math.min(12, Integer(item and item.enhance, 0)))
end

local function FormatItemName(item)
    if not item then return "未选择装备" end
    local level = ClampLevel(item)
    return (item.name or "装备") .. (level > 0 and (" +" .. level) or "")
end

local function FormatPercent(rate)
    return tostring(math.floor((tonumber(rate) or 0) * 100 + 0.5)) .. "%"
end

local function ShowToast(options, message)
    if options.showToast then
        options.showToast(message)
    else
        print("[EnhancePanel] " .. tostring(message))
    end
end

local function IsUsableByPlayer(item, player)
    if type(item) ~= "table" then return false end
    if not Inventory.IsOwnedItem(item) then return false end
    if item.classReq and player and item.classReq ~= player.classId then
        return false
    end
    return Inventory.GetItemStats(item) ~= nil
end

local function BuildOwnedEntries(player)
    local inv = Inventory.playerData
    local entries = {}
    local seen = {}

    -- 已穿戴装备优先，玩家打开铁匠时先看到当前战力核心装备。
    for _, slotKey in ipairs(SLOT_ORDER) do
        local item = inv.equipped[slotKey]
        if IsUsableByPlayer(item, player) and not seen[item] then
            seen[item] = true
            table.insert(entries, {
                item = item,
                equipped = true,
                location = Inventory.SLOT_NAMES[slotKey] or slotKey,
                order = #entries + 1,
            })
        end
    end

    local bagEntries = {}
    for bagIndex, item in ipairs(inv.bag) do
        if IsUsableByPlayer(item, player) and not seen[item] then
            seen[item] = true
            table.insert(bagEntries, {
                item = item,
                equipped = false,
                location = "第" .. bagIndex .. "格",
                bagIndex = bagIndex,
            })
        end
    end

    table.sort(bagEntries, function(a, b)
        local ar = Inventory.RARITY[a.item.rarity]
        local br = Inventory.RARITY[b.item.rarity]
        local at = ar and ar.mult or 0
        local bt = br and br.mult or 0
        if at ~= bt then return at > bt end
        local al = ClampLevel(a.item)
        local bl = ClampLevel(b.item)
        if al ~= bl then return al > bl end
        return tostring(a.item.name or "") < tostring(b.item.name or "")
    end)
    for _, entry in ipairs(bagEntries) do
        table.insert(entries, entry)
    end
    return entries
end

local function FindSelected(entries, requested)
    if requested then
        for _, entry in ipairs(entries) do
            if entry.item == requested then
                return entry.item
            end
        end
    end
    return entries[1] and entries[1].item or nil
end

local function PromoteSelectedEntry(entries, selectedItem)
    if not selectedItem or not entries[1] or entries[1].item == selectedItem then
        return
    end
    for index, entry in ipairs(entries) do
        if entry.item == selectedItem then
            table.remove(entries, index)
            table.insert(entries, 1, entry)
            return
        end
    end
end

local function CloneAtLevel(item, level)
    local preview = {}
    if type(item) == "table" then
        for key, value in pairs(item) do
            preview[key] = value
        end
    end
    preview.enhance = level
    return preview
end

local function BuildStatPreview(item, nextLevel)
    local currentStats = Inventory.GetItemStats(item)
    local nextStats = Inventory.GetItemStats(CloneAtLevel(item, nextLevel))
    local rows = {}
    if not currentStats or not nextStats then return rows end

    for _, def in ipairs(STAT_DEFS) do
        local current = Integer(currentStats[def.key])
        local nextValue = Integer(nextStats[def.key])
        local delta = nextValue - current
        table.insert(rows, UI.Panel {
            width = "100%",
            minHeight = 28,
            flexDirection = "row",
            alignItems = "center",
            gap = 7,
            children = {
                UI.Label {
                    text = def.label,
                    width = 42,
                    fontSize = 11,
                    fontColor = {174, 168, 154, 220},
                },
                UI.Label {
                    text = tostring(current),
                    width = 48,
                    fontSize = 12,
                    textAlign = "right",
                    fontColor = def.color,
                    fontWeight = "bold",
                },
                UI.Label {
                    text = "→",
                    width = 18,
                    fontSize = 12,
                    textAlign = "center",
                    fontColor = {184, 174, 150, 210},
                },
                UI.Label {
                    text = tostring(nextValue),
                    width = 48,
                    fontSize = 12,
                    textAlign = "right",
                    fontColor = {146, 226, 156, 245},
                    fontWeight = "bold",
                },
                UI.Label {
                    text = delta > 0 and ("+" .. delta) or tostring(delta),
                    flex = 1,
                    fontSize = 10,
                    textAlign = "right",
                    fontColor = delta > 0 and {146, 226, 156, 235} or {174, 168, 154, 180},
                },
            },
        })
    end
    return rows
end

local function BuildItemRow(entry, selectedItem, options)
    local item = entry.item
    local selected = item == selectedItem
    local rarityColor = Inventory.GetRarityColor(item.rarity)
    local level = ClampLevel(item)
    local locationText = entry.equipped and "已穿戴" or "背包"
    local stats = Inventory.GetItemStats(item)
    local brief = stats and ("攻" .. Integer(stats.atk) .. "  防" .. Integer(stats.def)
        .. "  血" .. Integer(stats.hp)) or "属性异常"

    return UI.Button {
        text = "",
        width = "100%",
        minHeight = 58,
        flexShrink = 0,
        paddingHorizontal = 9,
        paddingVertical = 7,
        backgroundColor = selected and {66, 48, 22, 245} or {27, 24, 20, 225},
        borderRadius = 7,
        borderWidth = selected and 1.5 or 1,
        borderColor = selected
            and {224, 166, 70, 235}
            or {76, 70, 60, 145},
        alignItems = "flex-start",
        onClick = function()
            if options.onSelect then options.onSelect(item) end
        end,
        children = {
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                gap = 7,
                children = {
                    UI.Label {
                        text = (item.name or "装备") .. (level > 0 and (" +" .. level) or ""),
                        flex = 1,
                        flexShrink = 1,
                        fontSize = 12,
                        fontWeight = "bold",
                        fontColor = {rarityColor[1], rarityColor[2], rarityColor[3], 245},
                        whiteSpace = "normal",
                        wordBreak = "break-word",
                    },
                    UI.Label {
                        text = selected and "当前" or locationText,
                        width = 42,
                        fontSize = 9,
                        textAlign = "right",
                        fontColor = selected and {255, 214, 124, 245} or {156, 150, 138, 190},
                    },
                },
            },
            UI.Label {
                text = brief,
                width = "100%",
                fontSize = 9,
                fontColor = {174, 168, 154, 200},
                marginTop = 3,
            },
        },
    }
end

local function BuildEmptyState()
    return UI.Panel {
        width = "100%",
        minHeight = 150,
        justifyContent = "center",
        alignItems = "center",
        gap = 7,
        padding = 18,
        children = {
            UI.Label {
                text = "暂无可强化装备",
                fontSize = 15,
                fontWeight = "bold",
                fontColor = {216, 207, 186, 230},
            },
            UI.Label {
                text = "只有当前职业可使用的装备会显示在这里。\n先在野外拾取装备，再回安全区找铁匠。",
                fontSize = 10,
                lineHeight = 1.45,
                textAlign = "center",
                whiteSpace = "normal",
                wordBreak = "break-word",
                fontColor = {154, 149, 138, 195},
            },
        },
    }
end

local function BuildSelectedDetails(selectedItem, selectedEntry, options)
    if not selectedItem then return BuildEmptyState() end

    local currentLevel = ClampLevel(selectedItem)
    local nextLevel = currentLevel + 1
    local cost = Inventory.Enhance.EnhanceCost(nextLevel)
    local failureLevel = Inventory.Enhance.GetFailureLevel(currentLevel, nextLevel)
    local failureDrops = failureLevel < currentLevel
    local guaranteedSuccess = (tonumber(cost.successRate) or 0) >= 1
    local gold = math.max(0, Integer(Inventory.playerData.gold, 0))
    local protectStones = Inventory.GetProtectStones()
    local rarityColor = Inventory.GetRarityColor(selectedItem.rarity)
    local statRows = BuildStatPreview(selectedItem, nextLevel)

    local infoChildren = {
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
                    children = {
                        UI.Label {
                            text = FormatItemName(selectedItem),
                            fontSize = 17,
                            fontWeight = "bold",
                            fontColor = {rarityColor[1], rarityColor[2], rarityColor[3], 255},
                            whiteSpace = "normal",
                            wordBreak = "break-word",
                        },
                        UI.Label {
                            text = (selectedEntry and selectedEntry.equipped and "已穿戴 · " or "背包 · ")
                                .. ((selectedEntry and selectedEntry.location) or "当前角色")
                                .. " · " .. Inventory.GetItemTypeName(selectedItem.itemType or selectedItem.slot),
                            fontSize = 10,
                            fontColor = {170, 164, 150, 205},
                            marginTop = 4,
                        },
                    },
                },
                UI.Panel {
                    flexShrink = 0,
                    minWidth = 68,
                    paddingHorizontal = 8,
                    paddingVertical = 6,
                    backgroundColor = {64, 46, 21, 235},
                    borderRadius = 7,
                    borderWidth = 1,
                    borderColor = {180, 132, 52, 180},
                    alignItems = "center",
                    children = {
                        UI.Label {
                            text = currentLevel >= 12 and "MAX" or ("+" .. currentLevel .. " → +" .. nextLevel),
                            fontSize = 11,
                            fontWeight = "bold",
                            fontColor = {255, 214, 124, 245},
                        },
                    },
                },
            },
        },
        UI.Panel {
            width = "100%",
            height = 1,
            backgroundColor = {112, 86, 45, 130},
            marginVertical = 8,
        },
    }

    if currentLevel >= 12 then
        table.insert(infoChildren, UI.Panel {
            width = "100%",
            padding = 10,
            backgroundColor = {30, 48, 31, 210},
            borderRadius = 7,
            borderWidth = 1,
            borderColor = {92, 168, 105, 180},
            children = {
                UI.Label {
                    text = "已达到 +12 强化上限",
                    fontSize = 12,
                    fontWeight = "bold",
                    fontColor = {144, 224, 152, 245},
                },
                UI.Label {
                    text = "这件装备不再消耗强化费用；可以继续使用、出售或分解。",
                    fontSize = 10,
                    fontColor = {174, 198, 176, 210},
                    marginTop = 4,
                },
            },
        })
        return UI.Panel {
            width = "100%",
            padding = 10,
            backgroundColor = {31, 25, 17, 238},
            borderRadius = 8,
            borderWidth = 1,
            borderColor = {122, 88, 38, 180},
            gap = 7,
            children = infoChildren,
        }
    end

    table.insert(infoChildren, UI.Label {
        text = "属性预览 · 当前 → 强化后",
        fontSize = 11,
        fontWeight = "bold",
        fontColor = {220, 201, 157, 235},
    })
    table.insert(infoChildren, UI.Panel {
        width = "100%",
        padding = 8,
        backgroundColor = {17, 15, 12, 180},
        borderRadius = 6,
        gap = 2,
        children = statRows,
    })

    local riskText
    local riskColor
    local riskBackground
    local riskBorder
    if guaranteedSuccess then
        riskText = "本次必定成功，不会失败或掉级；完成后提升至 +" .. nextLevel .. "。"
        riskColor = {150, 222, 158, 240}
        riskBackground = {27, 50, 30, 205}
        riskBorder = {78, 145, 88, 180}
    elseif failureDrops then
        riskText = "失败结果：本次会降至 +" .. failureLevel .. "（服务费不返还）"
        riskColor = {244, 146, 96, 240}
        riskBackground = {55, 29, 20, 205}
        riskBorder = {144, 73, 48, 170}
    else
        riskText = "失败结果：等级保持 +" .. currentLevel .. "（阶段保底，不会掉级）"
        riskColor = {166, 205, 153, 230}
        riskBackground = {29, 47, 30, 200}
        riskBorder = {82, 136, 88, 170}
    end
    table.insert(infoChildren, UI.Panel {
        width = "100%",
        padding = 8,
        backgroundColor = riskBackground,
        borderRadius = 6,
        borderWidth = 1,
        borderColor = riskBorder,
        gap = 3,
        children = {
            UI.Label {
                text = "费用 " .. cost.gold .. " 金币 · 成功率 " .. FormatPercent(cost.successRate),
                fontSize = 11,
                fontWeight = "bold",
                fontColor = {245, 208, 124, 240},
            },
            UI.Label {
                text = riskText,
                fontSize = 10,
                lineHeight = 1.3,
                whiteSpace = "normal",
                wordBreak = "break-word",
                fontColor = riskColor,
            },
        },
    })

    if failureDrops then
        table.insert(infoChildren, UI.Label {
            text = protectStones > 0
                and ("保护石 " .. protectStones .. " 颗 · 可让失败时保持 +" .. currentLevel)
                or "暂无保护石 · 可在商人处购买；保护石只在会掉级的阶段生效",
            width = "100%",
            fontSize = 10,
            lineHeight = 1.3,
            whiteSpace = "normal",
            wordBreak = "break-word",
            fontColor = protectStones > 0 and {148, 201, 238, 225} or {168, 158, 142, 195},
            marginTop = 1,
        })
    end

    local function NotifyGold()
        if options.onGoldChanged then
            options.onGoldChanged(Inventory.playerData.gold)
        end
    end

    local function FinishEnhance(useProtect)
        local ok, message, finalLevel, result = Inventory.EnhanceItem(selectedItem, useProtect)
        NotifyGold()
        if result and options.applyDerivedStats then options.applyDerivedStats() end

        result = result or {}
        local currentText = "+" .. currentLevel
        local finalText = "+" .. Integer(finalLevel, currentLevel)
        if ok then
            ShowToast(options, "强化成功：" .. (selectedItem.name or "装备") .. " " .. finalText
                .. " · 花费 " .. Integer(result.goldSpent, cost.gold) .. " 金币")
        elseif result.downgraded then
            ShowToast(options, "强化失败：等级由 " .. currentText .. " 降至 " .. finalText
                .. " · 花费 " .. Integer(result.goldSpent, cost.gold) .. " 金币")
        elseif result.protected then
            ShowToast(options, "强化失败：保护石生效，等级保持 " .. currentText
                .. " · 花费 " .. Integer(result.goldSpent, cost.gold) .. " 金币")
        elseif result.goldSpent then
            ShowToast(options, "强化失败：等级保持 " .. currentText
                .. " · 花费 " .. Integer(result.goldSpent, cost.gold) .. " 金币")
        else
            ShowToast(options, message or "强化失败")
        end
        if options.onSuccess and ok then options.onSuccess(selectedItem, result) end
        if options.onRefresh then options.onRefresh() end
    end

    local function RequestEnhance(useProtect)
        if gold < cost.gold then
            ShowToast(options, "金币不足，还需要 " .. (cost.gold - gold) .. " 金币")
            return
        end
        if useProtect and protectStones <= 0 then
            ShowToast(options, "保护石不足，请先到商人处购买")
            return
        end
        if useProtect and not failureDrops then
            ShowToast(options, "当前阶段失败不会掉级，无需消耗保护石")
            return
        end

        if not useProtect and failureDrops then
            UI.Modal.Confirm {
                title = "确认高风险强化",
                message = "强化到 +" .. nextLevel .. " 需要 " .. cost.gold .. " 金币，成功率 "
                    .. FormatPercent(cost.successRate) .. "。失败后会降至 +" .. failureLevel
                    .. "，服务费不返还。确定继续吗？",
                confirmText = "确认强化",
                cancelText = "再看一眼",
                onConfirm = function() FinishEnhance(false) end,
            }
            return
        end
        FinishEnhance(useProtect)
    end

    local actionLabel = guaranteedSuccess and "必成强化"
        or (failureDrops and "普通强化" or "稳级强化")
    table.insert(infoChildren, UI.Button {
        text = gold >= cost.gold
            and (actionLabel .. " · " .. cost.gold .. " 金币")
            or ("金币不足 · 需要 " .. cost.gold .. " 金币"),
        width = "100%",
        minHeight = 42,
        marginTop = 2,
        variant = gold >= cost.gold and "primary" or "outline",
        disabled = gold < cost.gold,
        fontSize = 12,
        onClick = function() RequestEnhance(false) end,
    })

    if failureDrops then
        local protectEnabled = protectStones > 0 and gold >= cost.gold
        table.insert(infoChildren, UI.Button {
            text = protectStones > 0
                and ("保护强化 · 消耗 1 保护石 + " .. cost.gold .. " 金币")
                or "保护强化 · 先购买保护石",
            width = "100%",
            minHeight = 38,
            marginTop = 1,
            variant = "outline",
            disabled = not protectEnabled,
            fontSize = 11,
            onClick = function() RequestEnhance(true) end,
        })
    else
        table.insert(infoChildren, UI.Label {
            text = guaranteedSuccess
                and "本次成功率为 100%，无需使用保护石。"
                or "失败时会保持当前等级，无需使用保护石。",
            width = "100%",
            fontSize = 9,
            lineHeight = 1.3,
            whiteSpace = "normal",
            wordBreak = "break-word",
            fontColor = {158, 188, 148, 205},
            marginTop = 2,
        })
    end

    return UI.Panel {
        width = "100%",
        padding = 10,
        backgroundColor = {31, 25, 17, 238},
        borderRadius = 8,
        borderWidth = 1,
        borderColor = {122, 88, 38, 180},
        gap = 7,
        children = infoChildren,
    }
end

--- 构建强化页。所有状态从 Inventory 实时读取，避免旧面板闭包覆盖最新数据。
---@param options table {
---   player, selectedItem?, onSelect?, onRefresh?, onGoldChanged?,
---   showToast?, applyDerivedStats?, onSuccess?
--- }
---@return table
function EnhancePanel.Build(options)
    options = options or {}
    local player = options.player or {}
    local entries = BuildOwnedEntries(player)
    local selectedItem = FindSelected(entries, options.selectedItem)
    -- 重建面板会重置滚动位置；把当前选择提到顶部，避免点选深处装备后
    -- 刷新回列表开头却看不到自己刚选中的物品。
    PromoteSelectedEntry(entries, selectedItem)
    local selectedEntry = nil
    for _, entry in ipairs(entries) do
        if entry.item == selectedItem then
            selectedEntry = entry
            break
        end
    end

    local currentGold = math.max(0, Integer(Inventory.playerData.gold, 0))
    local header = UI.Panel {
        width = "100%",
        flexShrink = 0,
        padding = 10,
        backgroundColor = {30, 25, 17, 235},
        borderRadius = 8,
        borderWidth = 1,
        borderColor = {130, 91, 41, 180},
        gap = 5,
        children = {
            UI.Panel {
                width = "100%",
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                gap = 8,
                children = {
                    UI.Label {
                        text = "铁匠强化 · 只收金币",
                        flex = 1,
                        flexShrink = 1,
                        fontSize = 15,
                        fontWeight = "bold",
                        fontColor = {238, 205, 130, 250},
                    },
                    UI.Label {
                        text = "金币 " .. currentGold,
                        fontSize = 11,
                        fontWeight = "bold",
                        fontColor = {244, 211, 112, 245},
                    },
                },
            },
            UI.Label {
                text = "选择装备后，先查看下一等级属性、成功率和失败规则，再决定强化方式。",
                width = "100%",
                fontSize = 10,
                lineHeight = 1.35,
                whiteSpace = "normal",
                wordBreak = "break-word",
                fontColor = {188, 182, 166, 210},
            },
        },
    }

    local body
    if #entries == 0 then
        body = UI.Panel {
            width = "100%",
            flexGrow = 1,
            flexBasis = 0,
            justifyContent = "center",
            children = { BuildEmptyState() },
        }
    else
        local itemRows = {}
        for _, entry in ipairs(entries) do
            table.insert(itemRows, BuildItemRow(entry, selectedItem, options))
        end
        body = UI.Panel {
            width = "100%",
            flexGrow = 1,
            flexBasis = 0,
            minHeight = 0,
            flexDirection = "row",
            alignItems = "stretch",
            gap = 8,
            children = {
                UI.Panel {
                    width = "38%",
                    minWidth = 150,
                    maxWidth = 205,
                    flexShrink = 0,
                    height = "100%",
                    gap = 5,
                    children = {
                        UI.Label {
                            text = "选择装备 · 当前选择置顶",
                            width = "100%",
                            flexShrink = 0,
                            fontSize = 10,
                            fontWeight = "bold",
                            fontColor = {220, 201, 157, 235},
                        },
                        ServiceScrollView.Build {
                            width = "100%",
                            flexGrow = 1,
                            flexBasis = 0,
                            showScrollbar = true,
                            children = {
                                UI.Panel {
                                    width = "100%",
                                    gap = 5,
                                    paddingBottom = 6,
                                    children = itemRows,
                                },
                            },
                        },
                    },
                },
                ServiceScrollView.Build {
                    flex = 1,
                    height = "100%",
                    showScrollbar = true,
                    children = {
                        UI.Panel {
                            width = "100%",
                            paddingBottom = 8,
                            children = {
                                BuildSelectedDetails(selectedItem, selectedEntry, options),
                            },
                        },
                    },
                },
            },
        }
    end

    -- 选中项失效时让宿主同步到新的首选项；仅在有变化时回调，避免刷新递归。
    if options.onSelectionResolved and selectedItem ~= options.selectedItem then
        options.onSelectionResolved(selectedItem)
    end

    return UI.Panel {
        width = "100%",
        height = "100%",
        overflow = "hidden",
        children = {
            header,
            UI.Panel {
                width = "100%",
                height = 1,
                flexShrink = 0,
                backgroundColor = {92, 76, 45, 135},
                marginVertical = 8,
            },
            body,
        },
    }
end

return EnhancePanel
